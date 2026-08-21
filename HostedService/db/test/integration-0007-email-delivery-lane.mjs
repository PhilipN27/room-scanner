import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { accepted0006MigrationsDir } from './accepted-0006-migrations.mjs';
import { appPoolConfig, hash32 } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const now = new Date('2026-08-19T20:00:00.000Z');
let cluster;
let bootstrapPool;
let emailPool;
let apiPool;
let challengePool;

const deliveryRoutines = [
  'roomscan.claim_magic_delivery(text,text,timestamp with time zone,timestamp with time zone)',
  'roomscan.claim_next_magic_delivery(text,timestamp with time zone,timestamp with time zone)',
  'roomscan.validate_magic_delivery(text,text,timestamp with time zone)',
  'roomscan.complete_magic_delivery(text,text,timestamp with time zone)',
  'roomscan.cancel_magic_delivery(text,text,text,timestamp with time zone)',
  'roomscan.release_magic_delivery(text,text,timestamp with time zone)',
];
const expectedEmailExecute = [
  'roomscan.accept_provider_audit_event(text, text, text, text, timestamp with time zone)',
  'roomscan.cancel_magic_delivery(text, text, text, timestamp with time zone)',
  'roomscan.claim_magic_delivery(text, text, timestamp with time zone, timestamp with time zone)',
  'roomscan.claim_next_magic_delivery(text, timestamp with time zone, timestamp with time zone)',
  'roomscan.complete_magic_delivery(text, text, timestamp with time zone)',
  'roomscan.release_magic_delivery(text, text, timestamp with time zone)',
  'roomscan.validate_magic_delivery(text, text, timestamp with time zone)',
];

let selectorSequence = 0;
async function insertDelivery({
  id,
  createdAt = now,
  expiresAt = new Date(now.getTime() + 600_000),
  identity = `${id}@example.invalid`,
}) {
  selectorSequence += 1;
  const selector = selectorSequence.toString(36).padStart(22, 'A');
  await bootstrapPool.query(
    `INSERT INTO roomscan.magic_links (
       selector, secret_digest, purpose, normalized_delivery_identity,
       address_hash, network_hash, issued_at, expires_at, policy_version
     ) VALUES ($1, $2, 'sign-in', $3, $4, $5, $6, $7, 'magic-link-v1')`,
    [selector, hash32(`secret-${id}`), identity, hash32(`address-${id}`),
      hash32(`network-${id}`), createdAt, expiresAt],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.magic_link_delivery_outbox (
       id, selector, normalized_delivery_identity, purpose, envelope_version,
       key_id, iv, ciphertext, authentication_tag, created_at, expires_at,
       policy_version
     ) VALUES ($1, $2, $3, 'sign-in', 'aes-256-gcm-v1', 'email-key-v1',
       $4, $5, $6, $7, $8, 'magic-link-v1')`,
    [id, selector, identity, Buffer.alloc(12, selectorSequence),
      Buffer.alloc(32, selectorSequence + 1), Buffer.alloc(16, selectorSequence + 2),
      createdAt, expiresAt],
  );
}

async function raceClaimNext(leaseIds, claimedAt, expiresAt) {
  const clients = await Promise.all(leaseIds.map(() => emailPool.connect()));
  let ready = 0;
  let releaseReady;
  let releaseGo;
  const allReady = new Promise((resolve) => { releaseReady = resolve; });
  const go = new Promise((resolve) => { releaseGo = resolve; });
  const pending = clients.map(async (client, index) => {
    let began = false;
    try {
      await client.query('BEGIN');
      began = true;
      ready += 1;
      if (ready === clients.length) releaseReady();
      await go;
      const rows = (await client.query(
        `SELECT id, state, lease_id FROM roomscan.claim_next_magic_delivery(
           $1, $2, $3
         )`,
        [leaseIds[index], claimedAt, expiresAt],
      )).rows;
      await client.query('COMMIT');
      began = false;
      return rows[0] ?? null;
    } catch (error) {
      if (began) await client.query('ROLLBACK').catch(() => undefined);
      throw error;
    } finally {
      client.release();
    }
  });
  await allReady;
  releaseGo();
  return Promise.all(pending);
}

async function claimTarget(id, leaseId, claimedAt, leaseExpiresAt) {
  return (await emailPool.query(
    `SELECT * FROM roomscan.claim_magic_delivery($1, $2, $3, $4)`,
    [id, leaseId, claimedAt, leaseExpiresAt],
  )).rows[0] ?? null;
}

async function setProfessionalSignIn(enabled, expectedVersion, suffix, occurredAt) {
  await bootstrapPool.query('SET ROLE roomscan_operator');
  try {
    return (await bootstrapPool.query(
      `SELECT * FROM roomscan.set_operational_flag(
         'global', NULL, 'professional_sign_in_enabled', $1, $2,
         'email delivery integration', $3, $4
       )`,
      [enabled, expectedVersion, `ofaud_email_signin_${suffix}`, occurredAt],
    )).rows[0];
  } finally {
    await bootstrapPool.query('RESET ROLE');
  }
}

async function proveDirtyRoleRejection() {
  const dirtyCluster = await startPostgresCluster();
  const dirtyPool = new Pool(dirtyCluster.bootstrapConfig);
  let cleanup;
  try {
    await applyMigrations({
      pool: dirtyPool, migrationsDir: accepted0006MigrationsDir,
    });
    await dirtyPool.query(
      `CREATE ROLE roomscan_email_delivery_runtime
         LOGIN INHERIT BYPASSRLS`,
    );
    await assert.rejects(
      () => applyMigrations({ pool: dirtyPool }),
      (error) => error?.code === '42710',
    );
    assert.equal(Number((await dirtyPool.query(
      `SELECT count(*)::integer AS count
         FROM roomscan_schema_migrations WHERE version = '0007'`,
    )).rows[0].count), 0);
    assert.deepEqual((await dirtyPool.query(
      `SELECT rolcanlogin, rolinherit, rolbypassrls
         FROM pg_roles WHERE rolname = 'roomscan_email_delivery_runtime'`,
    )).rows[0], {
      rolcanlogin: true, rolinherit: true, rolbypassrls: true,
    });
  } finally {
    await dirtyPool.end();
    cleanup = await dirtyCluster.stop();
  }
  return cleanup;
}

const dirtyRoleCleanup = await proveDirtyRoleRejection();
console.log(`EMAIL_DELIVERY_DIRTY_ROLE_CLEANUP ${JSON.stringify(dirtyRoleCleanup)}`);
cluster = await startPostgresCluster();
bootstrapPool = new Pool(cluster.bootstrapConfig);

try {
  await applyMigrations({ pool: bootstrapPool });

  await insertDelivery({
    id: 'magic_email_recovery_0001',
    createdAt: new Date(now.getTime() - 2_000),
  });

  emailPool = new Pool({
    ...appPoolConfig(cluster, 6), user: 'roomscan_email_delivery_runtime', max: 6,
    application_name: 'rss-0007-email-delivery',
  });
  apiPool = new Pool({
    ...appPoolConfig(cluster, 1), user: 'roomscan_api_runtime', max: 1,
  });
  challengePool = new Pool({
    ...appPoolConfig(cluster, 1), user: 'roomscan_auth_challenge_runtime', max: 1,
  });

  const role = (await bootstrapPool.query(
    `SELECT rolname, rolcanlogin, rolinherit, rolsuper, rolcreatedb,
            rolcreaterole, rolreplication, rolbypassrls
       FROM pg_roles WHERE rolname = 'roomscan_email_delivery_runtime'`,
  )).rows[0];
  assert.deepEqual(role, {
    rolname: 'roomscan_email_delivery_runtime', rolcanlogin: true,
    rolinherit: false, rolsuper: false, rolcreatedb: false,
    rolcreaterole: false, rolreplication: false, rolbypassrls: false,
  });

  const membershipEdges = Number((await bootstrapPool.query(
    `SELECT count(*)::integer AS count
       FROM pg_auth_members AS edge
       JOIN pg_roles AS granted ON granted.oid = edge.roleid
       JOIN pg_roles AS member ON member.oid = edge.member
      WHERE granted.rolname = 'roomscan_email_delivery_runtime'
         OR member.rolname = 'roomscan_email_delivery_runtime'`,
  )).rows[0].count);
  assert.equal(membershipEdges, 0);

  const emailExecute = (await bootstrapPool.query(
    `SELECT format('%I.%I(%s)', namespace.nspname, procedure.proname,
                   oidvectortypes(procedure.proargtypes)) AS routine
       FROM pg_proc AS procedure
       JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
      WHERE namespace.nspname = 'roomscan'
        AND has_function_privilege(
          'roomscan_email_delivery_runtime', procedure.oid, 'EXECUTE'
        )
      ORDER BY routine`,
  )).rows.map(({ routine }) => routine);
  assert.deepEqual(emailExecute, expectedEmailExecute);

  const directPrivileges = Number((await bootstrapPool.query(
    `SELECT count(*)::integer AS count
       FROM information_schema.role_table_grants
      WHERE table_schema = 'roomscan'
        AND grantee = 'roomscan_email_delivery_runtime'
        AND privilege_type IN ('SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')`,
  )).rows[0].count);
  assert.equal(directPrivileges, 0);

  for (const routine of deliveryRoutines) {
    for (const roleName of [
      'roomscan_api_runtime', 'roomscan_authorizer_runtime',
      'roomscan_auth_challenge_runtime', 'roomscan_stripe_ingress_runtime',
      'roomscan_stripe_reconciliation_runtime', 'roomscan_audit_export_runtime',
      'roomscan_operator', 'roomscan_app',
    ]) {
      assert.equal((await bootstrapPool.query(
        `SELECT has_function_privilege($1, $2, 'EXECUTE') AS allowed`,
        [roleName, routine],
      )).rows[0].allowed, false, `${roleName} can execute ${routine}`);
    }
  }

  await assert.rejects(
    () => apiPool.query(
      `SELECT * FROM roomscan.claim_magic_delivery(
         'magic_email_denied', 'api_lease', $1, $2
       )`, [now, new Date(now.getTime() + 30_000)],
    ),
    (error) => error?.code === '42501',
  );
  await assert.rejects(
    () => challengePool.query(
      `SELECT * FROM roomscan.claim_next_magic_delivery(
         'challenge_lease', $1, $2
       )`, [now, new Date(now.getTime() + 30_000)],
    ),
    (error) => error?.code === '42501',
  );

  // Missing and literal-false sign-in gates cannot authorize a provider send.
  assert.equal((await emailPool.query(
    `SELECT count(*)::integer AS count
       FROM roomscan.claim_next_magic_delivery($1, $2, $3)`,
    ['missing_flag_lease', now, new Date(now.getTime() + 30_000)],
  )).rows[0].count, 0);
  assert.deepEqual(await setProfessionalSignIn(true, null, 'enabled_1', now), {
    enabled: true, version: '1',
  });
  assert.deepEqual(await setProfessionalSignIn(
    false, 1, 'disabled_2', new Date(now.getTime() + 1),
  ), { enabled: false, version: '2' });
  assert.equal((await emailPool.query(
    `SELECT count(*)::integer AS count
       FROM roomscan.claim_next_magic_delivery($1, $2, $3)`,
    ['disabled_flag_lease', new Date(now.getTime() + 2),
      new Date(now.getTime() + 30_002)],
  )).rows[0].count, 0);
  assert.equal((await bootstrapPool.query(
    `SELECT state FROM roomscan.magic_link_delivery_outbox
      WHERE id = 'magic_email_recovery_0001'`,
  )).rows[0].state, 'pending');
  assert.deepEqual(await setProfessionalSignIn(
    true, 2, 'enabled_3', new Date(now.getTime() + 3),
  ), { enabled: true, version: '3' });

  // A wake can be lost entirely: recovery claims the oldest row without a
  // caller-selected outbox identifier once the server gate is enabled.
  const recovery = (await emailPool.query(
    `SELECT * FROM roomscan.claim_next_magic_delivery($1, $2, $3)`,
    ['recovery_lease_0001', now, new Date(now.getTime() + 30_000)],
  )).rows[0];
  assert.equal(recovery.id, 'magic_email_recovery_0001');
  assert.equal(recovery.state, 'leased');
  assert.equal(recovery.lease_id, 'recovery_lease_0001');
  assert.equal((await emailPool.query(
    `SELECT roomscan.complete_magic_delivery($1, $2, $3) AS completed`,
    [recovery.id, recovery.lease_id, new Date(now.getTime() + 1_000)],
  )).rows[0].completed, true);

  await insertDelivery({ id: 'magic_email_race_000001' });
  const race = await raceClaimNext(
    ['race_lease_alpha', 'race_lease_bravo'], now,
    new Date(now.getTime() + 30_000),
  );
  assert.equal(race.filter(Boolean).length, 1);
  assert.equal(race.filter((row) => row?.id === 'magic_email_race_000001').length, 1);
  const raceWinner = race.find(Boolean);
  assert.equal((await emailPool.query(
    `SELECT count(*)::integer AS count FROM roomscan.validate_magic_delivery(
       $1, $2, $3
     )`, [raceWinner.id, 'lost_race_lease', new Date(now.getTime() + 1_000)],
  )).rows[0].count, 0);
  assert.equal((await emailPool.query(
    `SELECT count(*)::integer AS count FROM roomscan.validate_magic_delivery(
       $1, $2, $3
     )`, [raceWinner.id, raceWinner.lease_id, new Date(now.getTime() + 1_000)],
  )).rows[0].count, 1);
  assert.equal((await emailPool.query(
    `SELECT roomscan.complete_magic_delivery($1, 'lost_race_lease', $2) AS completed`,
    [raceWinner.id, new Date(now.getTime() + 2_000)],
  )).rows[0].completed, false);
  assert.equal((await emailPool.query(
    `SELECT roomscan.complete_magic_delivery($1, $2, $3) AS completed`,
    [raceWinner.id, raceWinner.lease_id, new Date(now.getTime() + 2_000)],
  )).rows[0].completed, true);

  await insertDelivery({ id: 'magic_email_takeover_01' });
  assert.equal((await claimTarget(
    'magic_email_takeover_01', 'takeover_old', now,
    new Date(now.getTime() + 5_000),
  )).lease_id, 'takeover_old');
  const takeover = (await emailPool.query(
    `SELECT * FROM roomscan.claim_next_magic_delivery($1, $2, $3)`,
    ['takeover_new', new Date(now.getTime() + 5_001),
      new Date(now.getTime() + 35_001)],
  )).rows[0];
  assert.equal(takeover.id, 'magic_email_takeover_01');
  assert.equal(takeover.lease_id, 'takeover_new');
  assert.equal((await emailPool.query(
    `SELECT roomscan.complete_magic_delivery($1, 'takeover_old', $2) AS completed`,
    [takeover.id, new Date(now.getTime() + 6_000)],
  )).rows[0].completed, false);
  assert.equal((await emailPool.query(
    `SELECT roomscan.release_magic_delivery($1, $2, $3) AS status`,
    [takeover.id, takeover.lease_id, new Date(now.getTime() + 6_001)],
  )).rows[0].status, 'released');

  // Server-selected recovery cleans one expired row in deterministic order.
  await insertDelivery({
    id: 'magic_email_expired_001',
    createdAt: new Date(now.getTime() - 20_000),
    expiresAt: new Date(now.getTime() - 10_000),
  });
  const expired = (await emailPool.query(
    `SELECT * FROM roomscan.claim_next_magic_delivery($1, $2, $3)`,
    ['expired_cleanup', now, new Date(now.getTime() + 30_000)],
  )).rows[0];
  assert.equal(expired.id, 'magic_email_expired_001');
  assert.equal(expired.state, 'expired');
  assert.equal(expired.cancellation_reason, 'expired');

  await insertDelivery({
    id: 'magic_email_presend_001',
    expiresAt: new Date(now.getTime() + 10_000),
  });
  assert.equal((await claimTarget(
    'magic_email_presend_001', 'presend_lease',
    new Date(now.getTime() + 9_000), new Date(now.getTime() + 10_000),
  )).lease_id, 'presend_lease');
  const presend = (await emailPool.query(
    `SELECT state FROM roomscan.validate_magic_delivery($1, $2, $3)`,
    ['magic_email_presend_001', 'presend_lease', new Date(now.getTime() + 10_000)],
  )).rows[0];
  assert.deepEqual(presend, { state: 'expired' });
  assert.equal((await emailPool.query(
    `SELECT roomscan.complete_magic_delivery($1, $2, $3) AS completed`,
    ['magic_email_presend_001', 'presend_lease', new Date(now.getTime() + 10_001)],
  )).rows[0].completed, false);

  // Exact lease and bounded cancellation reason are required.
  const released = (await emailPool.query(
    `SELECT * FROM roomscan.claim_next_magic_delivery($1, $2, $3)`,
    ['release_lease_0001', new Date(now.getTime() + 7_000),
      new Date(now.getTime() + 37_000)],
  )).rows[0];
  assert.equal(released.id, 'magic_email_takeover_01');
  assert.equal((await emailPool.query(
    `SELECT roomscan.cancel_magic_delivery($1, 'wrong_lease', 'unknown_key', $2) AS cancelled`,
    [released.id, new Date(now.getTime() + 7_001)],
  )).rows[0].cancelled, false);
  assert.equal((await emailPool.query(
    `SELECT roomscan.cancel_magic_delivery($1, $2, 'tampered_envelope', $3) AS cancelled`,
    [released.id, released.lease_id, new Date(now.getTime() + 7_002)],
  )).rows[0].cancelled, true);

  assert.equal((await emailPool.query(
    `SELECT roomscan.accept_provider_audit_event(
       'paud_emailaccepted0007', 'email', 'email.delivery.accepted',
       'magic-email-recovery-0001', $1
     ) AS accepted`, [now],
  )).rows[0].accepted, true);
  assert.equal((await emailPool.query(
    `SELECT roomscan.accept_provider_audit_event(
       'paud_emailaccepted0007', 'email', 'email.delivery.accepted',
       'magic-email-recovery-0001', $1
     ) AS accepted`, [new Date(now.getTime() + 999)],
  )).rows[0].accepted, false);
  assert.equal((await emailPool.query(
    `SELECT roomscan.accept_provider_audit_event(
       'paud_emaildeliveryok07', 'email', 'email.delivery.accepted',
       'magic-email-delivered-0007', $1
     ) AS accepted`, [new Date(now.getTime() + 1)],
  )).rows[0].accepted, true);
  assert.equal((await emailPool.query(
    `SELECT roomscan.accept_provider_audit_event(
       'paud_emaildeliveryfail07', 'email', 'email.delivery.failed',
       'magic-email-failed-0007', $1
     ) AS accepted`, [new Date(now.getTime() + 2)],
  )).rows[0].accepted, true);
  assert.deepEqual((await bootstrapPool.query(
    `SELECT event_code FROM roomscan.provider_audit_outbox
      WHERE id IN ('paud_emaildeliveryok07', 'paud_emaildeliveryfail07')
      ORDER BY event_code`,
  )).rows.map(({ event_code: eventCode }) => eventCode), [
    'email.delivery.accepted', 'email.delivery.failed',
  ]);
  await assert.rejects(
    () => emailPool.query(
      `SELECT roomscan.accept_provider_audit_event(
         'paud_emailwronglane007', 'email', 'stripe.webhook.accepted',
         'magic-email-wrong-lane-0007', $1
       )`, [new Date(now.getTime() + 3)],
    ),
    (error) => error?.code === '22023'
      && error?.message === 'INVALID_PROVIDER_AUDIT_EVENT',
  );
  await assert.rejects(
    () => bootstrapPool.query(
      `INSERT INTO roomscan.provider_audit_outbox (
         id, provider_lane, event_code, bounded_reference, occurred_at
       ) VALUES (
         'paud_storagewronglane07', 'email', 'apple.exchange.accepted',
         'storage-wrong-lane-0007', $1
       )`, [new Date(now.getTime() + 4)],
    ),
    (error) => error?.code === '23514',
  );

  await insertDelivery({ id: 'magic_email_disable_mid_1' });
  const disableBetween = await claimTarget(
    'magic_email_disable_mid_1', 'disable_between_lease',
    new Date(now.getTime() + 8_000), new Date(now.getTime() + 38_000),
  );
  assert.equal(disableBetween.lease_id, 'disable_between_lease');
  assert.deepEqual(await setProfessionalSignIn(
    false, 3, 'disabled_4', new Date(now.getTime() + 8_001),
  ), { enabled: false, version: '4' });
  assert.equal((await emailPool.query(
    `SELECT count(*)::integer AS count
       FROM roomscan.validate_magic_delivery($1, $2, $3)`,
    [disableBetween.id, disableBetween.lease_id, new Date(now.getTime() + 8_002)],
  )).rows[0].count, 0);
  assert.equal((await emailPool.query(
    `SELECT roomscan.release_magic_delivery($1, $2, $3) AS status`,
    [disableBetween.id, disableBetween.lease_id, new Date(now.getTime() + 8_003)],
  )).rows[0].status, 'released');
  assert.deepEqual(await setProfessionalSignIn(
    true, 4, 'enabled_5', new Date(now.getTime() + 8_004),
  ), { enabled: true, version: '5' });

  for (const [id, state, stateColumn, stateTime, leaseId] of [
    ['magic_email_superseded_1', 'superseded', 'superseded_at',
      new Date(now.getTime() + 9_001), 'superseded_lease'],
    ['magic_email_consumed_0001', 'consumed', 'consumed_at',
      new Date(now.getTime() + 10_001), 'consumed_lease'],
  ]) {
    await insertDelivery({ id });
    const claimed = await claimTarget(
      id, leaseId, new Date(stateTime.getTime() - 1),
      new Date(stateTime.getTime() + 30_000),
    );
    await bootstrapPool.query(
      `UPDATE roomscan.magic_links AS link
          SET state = $2,
              consumed_at = CASE WHEN $3 = 'consumed_at' THEN $4::timestamptz ELSE NULL END,
              superseded_at = CASE WHEN $3 = 'superseded_at' THEN $4::timestamptz ELSE NULL END
         FROM roomscan.magic_link_delivery_outbox AS delivery
        WHERE delivery.id = $1 AND link.selector = delivery.selector`,
      [id, state, stateColumn, stateTime],
    );
    assert.equal((await emailPool.query(
      `SELECT count(*)::integer AS count
         FROM roomscan.validate_magic_delivery($1, $2, $3)`,
      [id, claimed.lease_id, new Date(stateTime.getTime() + 1)],
    )).rows[0].count, 0, state);
    assert.equal((await emailPool.query(
      `SELECT roomscan.release_magic_delivery($1, $2, $3) AS status`,
      [id, claimed.lease_id, new Date(stateTime.getTime() + 2)],
    )).rows[0].status, 'released');
  }

  const durableBeforeInvalid = (await bootstrapPool.query(
    `SELECT count(*)::integer AS count FROM roomscan.magic_link_delivery_outbox`,
  )).rows[0].count;
  for (const args of [
    [null, now, new Date(now.getTime() + 30_000)],
    ['null_claimed_at', null, new Date(now.getTime() + 30_000)],
    ['null_lease_expiry', now, null],
  ]) {
    await assert.rejects(
      () => emailPool.query(
        `SELECT * FROM roomscan.claim_next_magic_delivery($1, $2, $3)`, args,
      ),
      (error) => error?.code === '22023'
        && error?.message === 'INVALID_MAGIC_DELIVERY_LEASE',
    );
  }
  assert.equal((await bootstrapPool.query(
    `SELECT count(*)::integer AS count FROM roomscan.magic_link_delivery_outbox`,
  )).rows[0].count, durableBeforeInvalid);

  const routine = (await bootstrapPool.query(
    `SELECT owner.rolname AS owner, procedure.prosecdef, procedure.provolatile,
            procedure.proconfig,
            pg_get_function_arguments(procedure.oid) AS arguments,
            pg_get_function_result(procedure.oid) AS result,
            obj_description(procedure.oid, 'pg_proc') AS review,
            has_function_privilege('public', procedure.oid, 'EXECUTE') AS public_execute
       FROM pg_proc AS procedure
       JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
       JOIN pg_roles AS owner ON owner.oid = procedure.proowner
      WHERE namespace.nspname = 'roomscan'
        AND procedure.proname = 'claim_next_magic_delivery'`,
  )).rows[0];
  assert.deepEqual(routine, {
    owner: 'roomscan_policy', prosecdef: true, provolatile: 'v',
    proconfig: ['search_path=pg_catalog, pg_temp'],
    arguments: 'requested_lease_id text, claimed_at_time timestamp with time zone, requested_lease_expires_at timestamp with time zone',
    result: 'SETOF roomscan.magic_link_delivery_outbox',
    review: 'Email-delivery worker-only server-selected oldest pending or expired-lease magic delivery claim; literal-true positive-version professional sign-in gate, one bounded row, SKIP LOCKED, expired-row cleanup, no caller outbox target; fixed search_path; PUBLIC revoked.',
    public_execute: false,
  });

  const resultColumns = (await bootstrapPool.query(
    `SELECT column_name, data_type, udt_name
       FROM information_schema.columns
      WHERE table_schema = 'roomscan'
        AND table_name = 'magic_link_delivery_outbox'
      ORDER BY ordinal_position`,
  )).rows;
  assert.equal(resultColumns.length, 19);
  assert.deepEqual(resultColumns.map(({ column_name }) => column_name), [
    'id', 'selector', 'normalized_delivery_identity', 'purpose',
    'envelope_version', 'key_id', 'iv', 'ciphertext', 'authentication_tag',
    'created_at', 'expires_at', 'policy_version', 'state',
    'delivery_attempts', 'lease_id', 'lease_expires_at', 'delivered_at',
    'cancelled_at', 'cancellation_reason',
  ]);

  console.log(
    'INTEGRATION_0007_EMAIL_DELIVERY_SUMMARY dirty_role_rejected=1 role_controls=9 '
      + 'exact_execute_routines=7 exclusive_delivery_acl_pairs=48 runtime_denials=2 '
      + 'wake_loss_recovery=1 claim_next_race_winners=1 claim_next_race_losers=1 '
      + 'lease_validation_controls=4 lease_takeover_controls=4 '
      + 'expired_cleanup=1 presend_expiry_controls=3 release_cancel_controls=4 '
      + 'provider_audit_controls=7 sign_in_gate_controls=10 link_state_controls=6 '
      + 'null_controls=3 result_columns=19 '
      + 'direct_dml_privileges=0 status=pass',
  );
} finally {
  if (challengePool) await challengePool.end();
  if (apiPool) await apiPool.end();
  if (emailPool) await emailPool.end();
  if (bootstrapPool) await bootstrapPool.end();
  const cleanup = cluster ? await cluster.stop() : null;
  console.log(`PG_CLEANUP ${JSON.stringify(cleanup)}`);
}
