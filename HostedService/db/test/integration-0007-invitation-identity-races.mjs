import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { appPoolConfig, hash32, ids, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const cluster = await startPostgresCluster();
const bootstrap = new Pool(cluster.bootstrapConfig);
let api;
const now = new Date('2026-08-19T23:20:00.000Z');
const targetPrincipals = [
  '10000000-0000-4000-8000-000000000008',
  '10000000-0000-4000-8000-000000000009',
  '10000000-0000-4000-8000-000000000010',
];
let familySequence = 920;

async function insertAccess(principalId, publicId, marker, scope) {
  const familyId = `65000000-0000-4000-8000-${String(familySequence).padStart(12, '0')}`;
  familySequence += 1;
  const accessHash = hash32(`invitation-race-access-${marker}`);
  await bootstrap.query(
    `INSERT INTO roomscan.auth_session_families (
       id, public_id, principal_id, authentication_epoch, authenticated_at,
       last_used_at, inactivity_expires_at, absolute_expires_at, policy_version,
       workspace_id, role, authorization_version, state, created_at
     ) VALUES (
       $1, $2, $3, 0, $4, $4, $4::timestamptz + interval '1 day',
       $4::timestamptz + interval '7 days', 'session-v1', $5, $6, $7,
       'active', $4
     )`,
    [familyId, publicId, principalId, now, scope?.workspaceId ?? null,
      scope?.role ?? null, scope?.authorizationVersion ?? null],
  );
  await bootstrap.query(
    `INSERT INTO roomscan.auth_access_tokens (
       id, family_id, token_hash, expires_at, principal_id,
       authentication_epoch, authenticated_at, issued_at,
       workspace_id, role, authorization_version, state, created_at
     ) VALUES (
       gen_random_uuid(), $1, $2, $3::timestamptz + interval '1 hour', $4,
       0, $3, $3, $5, $6, $7, 'active', $3
     )`,
    [familyId, accessHash, now, principalId, scope?.workspaceId ?? null,
      scope?.role ?? null, scope?.authorizationVersion ?? null],
  );
  return accessHash;
}

async function waitForMembershipArbitration(applicationName, settled) {
  const deadline = Date.now() + 2_000;
  while (Date.now() < deadline) {
    const rows = (await bootstrap.query(
      `SELECT wait_event
         FROM pg_catalog.pg_stat_activity
        WHERE application_name = $1 AND wait_event_type = 'Lock'`,
      [applicationName],
    )).rows;
    if (rows.length === 1) return rows[0].wait_event;
    if (settled()) return 'settled-without-lock';
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.fail(`timed out waiting for invitation membership arbitration ${applicationName}`);
}

try {
  await applyMigrations({ pool: bootstrap });
  await seedCoreFixtures(bootstrap);
  await bootstrap.query(
    `INSERT INTO roomscan.principals(id, normalized_email)
     SELECT principal_id, 'invitation-race-' || ordinal_position::text || '@example.invalid'
       FROM unnest($1::uuid[]) WITH ORDINALITY AS requested(principal_id, ordinal_position)`,
    [targetPrincipals],
  );
  await bootstrap.query('SET ROLE roomscan_operator');
  for (const [scope, workspace, auditId] of [
    ['global', null, 'ofaud_invitation_race_global_0007'],
    ['workspace', ids.workspaceA, 'ofaud_invitation_race_workspace_0007'],
  ]) {
    await bootstrap.query(
      `SELECT * FROM roomscan.set_operational_flag(
         $1, $2::uuid, 'hosted_operations_enabled', true, NULL,
         'invitation identity race test', $3, $4
       )`,
      [scope, workspace, auditId, now],
    );
  }
  await bootstrap.query(
    `SELECT * FROM roomscan.activate_quota_policy_v2(
       $1, 1, 'roomscan-quota-policy-v1', 'test-only',
       'roomscan-period-v1:invitation-race', 100, 100, 100, 100, 100,
       80, 1, 1, $2
     )`,
    [ids.workspaceA, now],
  );
  await bootstrap.query('RESET ROLE');

  const actorAccess = await insertAccess(
    ids.principalA, 'fam_invitation_race_actor_0007', 'actor',
    { workspaceId: ids.workspaceA, role: 'owner', authorizationVersion: 1 },
  );
  const targetAccesses = [];
  for (let index = 0; index < targetPrincipals.length; index += 1) {
    targetAccesses.push(await insertAccess(
      targetPrincipals[index], `fam_invitation_race_target_${index}_0007`,
      `target-${index}`, undefined,
    ));
  }
  api = new Pool({
    ...appPoolConfig(cluster, 8), user: 'roomscan_api_runtime', max: 8,
    application_name: 'rss-0007-invitation-identity-races',
  });
  const createSql = `SELECT * FROM roomscan.create_invitation_v2(
    $1, $2, $3, $4, $5, 'editor', $6, 1, 1, $7
  )`;
  const acceptSql = `SELECT * FROM roomscan.accept_invitation_v2(
    $1, $2, $3, 1, 1, 1, $4
  )`;

  const observedWaits = [];
  for (let index = 0; index < 3; index += 1) {
    const [isolation, suffix] = [
      ['READ COMMITTED', 'rc'],
      ['REPEATABLE READ', 'rr'],
      ['SERIALIZABLE', 'ser'],
    ][index];
    const tokenHashes = [
      hash32(`invitation-race-${suffix}-a`),
      hash32(`invitation-race-${suffix}-b`),
    ];
    for (let invitationIndex = 0; invitationIndex < 2; invitationIndex += 1) {
      const marker = invitationIndex === 0 ? 'a' : 'b';
      assert.equal((await api.query(createSql, [
        actorAccess, now, `inv_identity_race_${suffix}_${marker}_0007`, tokenHashes[invitationIndex],
        `target-${suffix}@example.invalid`, new Date(now.getTime() + 60_000),
        `aud_invite_race_${suffix}_${marker}_0007`,
      ])).rows[0].state, 'active');
    }
    const usageBefore = Number((await bootstrap.query(
      `SELECT used FROM roomscan.quota_usage_v2
        WHERE workspace_id = $1 AND metric = 'member_count'
          AND period_key = 'roomscan-period-v1:lifetime'`,
      [ids.workspaceA],
    )).rows[0].used);

    const [writer, waiter] = await Promise.all([api.connect(), api.connect()]);
    const waiterName = `rss-invitation-membership-${suffix}`;
    let waiterSettled = false;
    let waiterOutcome;
    let winner;
    try {
      await waiter.query(
        `SELECT pg_catalog.set_config('application_name', $1, false)`,
        [waiterName],
      );
      await Promise.all([writer, waiter].map((client) => client.query(
        `BEGIN ISOLATION LEVEL ${isolation}`,
      )));
      const snapshots = await Promise.all([writer, waiter].map((client) => client.query(
        `SELECT pg_catalog.txid_current_snapshot()::text AS snapshot`,
      )));
      assert.equal(snapshots.every(({ rows }) => rows[0].snapshot.length > 0), true);

      winner = (await writer.query(acceptSql, [
        targetAccesses[index], now, tokenHashes[0],
        `aud_accept_race_${suffix}_a_0007`,
      ])).rows[0];
      assert.equal(winner.status, 'accepted');
      const waiterPromise = waiter.query(acceptSql, [
        targetAccesses[index], now, tokenHashes[1],
        `aud_accept_race_${suffix}_b_0007`,
      ]).then((value) => ({ value }), (error) => ({ error }))
        .finally(() => { waiterSettled = true; });
      observedWaits.push(await waitForMembershipArbitration(waiterName, () => waiterSettled));
      await writer.query('COMMIT');
      waiterOutcome = await waiterPromise;
      if (isolation === 'READ COMMITTED') {
        assert.equal(waiterOutcome.value?.rows[0].status, 'already_member');
        await waiter.query('COMMIT');
      } else {
        assert.equal(waiterOutcome.error?.code, '40001');
        assert.equal(waiterOutcome.error?.message, 'INVITATION_ACCEPT_RETRY_REQUIRED');
        assert.notEqual(waiterOutcome.error?.code, '23505');
        await waiter.query('ROLLBACK');
      }
    } finally {
      await writer.query('ROLLBACK').catch(() => undefined);
      await waiter.query('ROLLBACK').catch(() => undefined);
      writer.release();
      waiter.release();
    }

    if (isolation !== 'READ COMMITTED') {
      const retried = (await api.query(acceptSql, [
        targetAccesses[index], now, tokenHashes[1],
        `aud_accept_race_${suffix}_b_0007`,
      ])).rows[0];
      assert.equal(retried.status, 'already_member');
    }
    assert.equal((await bootstrap.query(
      `SELECT count(*)::integer AS count
         FROM roomscan.memberships
        WHERE workspace_id = $1 AND principal_id = $2 AND state = 'active'`,
      [ids.workspaceA, targetPrincipals[index]],
    )).rows[0].count, 1);
    assert.equal((await bootstrap.query(
      `SELECT count(*)::integer AS count
         FROM roomscan.member_slots
        WHERE workspace_id = $1 AND principal_id = $2`,
      [ids.workspaceA, targetPrincipals[index]],
    )).rows[0].count, 1);
    assert.equal(Number((await bootstrap.query(
      `SELECT used FROM roomscan.quota_usage_v2
        WHERE workspace_id = $1 AND metric = 'member_count'
          AND period_key = 'roomscan-period-v1:lifetime'`,
      [ids.workspaceA],
    )).rows[0].used), usageBefore + 1);
    assert.equal((await bootstrap.query(
      `SELECT state FROM roomscan.invitations WHERE token_hash = $1`,
      [tokenHashes[1]],
    )).rows[0].state, 'active');
  }

  assert.deepEqual(observedWaits, ['advisory', 'advisory', 'advisory']);
  console.log(
    'INTEGRATION_0007_INVITATION_IDENTITY_RACES_SUMMARY isolation_levels=3 '
      + 'distinct_invitations=6 accepted=3 already_member=3 controlled_retries=2 '
      + 'fresh_retry_controls=2 membership_rows=3 slot_rows=3 quota_increments=3 '
      + 'losing_invitations_active=3 raw_23505=0 status=pass',
  );
} finally {
  if (api) await api.end();
  await bootstrap.end();
  const cleanup = await cluster.stop();
  console.log(`PG_CLEANUP ${JSON.stringify(cleanup)}`);
}
