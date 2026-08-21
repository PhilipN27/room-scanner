import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { appPoolConfig, hash32, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const cluster = await startPostgresCluster();
const bootstrap = new Pool(cluster.bootstrapConfig);
let api;
const now = new Date('2026-08-19T23:40:00.000Z');
const principalPairs = [
  ['10000000-0000-4000-8000-000000000021', '10000000-0000-4000-8000-000000000022'],
  ['10000000-0000-4000-8000-000000000023', '10000000-0000-4000-8000-000000000024'],
  ['10000000-0000-4000-8000-000000000025', '10000000-0000-4000-8000-000000000026'],
];
let familySequence = 960;

async function seedPrincipalAccess(principalId, suffix, marker) {
  const familyId = `65000000-0000-4000-8000-${String(familySequence).padStart(12, '0')}`;
  familySequence += 1;
  const accessHash = hash32(`identity-mutation-access-${suffix}-${marker}`);
  await bootstrap.query(
    `INSERT INTO roomscan.principals(id, normalized_email)
     VALUES ($1, $2)`,
    [principalId, `${suffix}-${marker}@example.invalid`],
  );
  await bootstrap.query(
    `INSERT INTO roomscan.auth_session_families (
       id, public_id, principal_id, authentication_epoch, authenticated_at,
       last_used_at, inactivity_expires_at, absolute_expires_at, policy_version,
       state, created_at
     ) VALUES (
       $1, $2, $3, 0, $4, $4, $4::timestamptz + interval '1 day',
       $4::timestamptz + interval '7 days', 'session-v1', 'active', $4
     )`,
    [familyId, `fam_identity_${suffix}_${marker}_0007`, principalId, now],
  );
  await bootstrap.query(
    `INSERT INTO roomscan.auth_access_tokens (
       id, family_id, token_hash, expires_at, principal_id,
       authentication_epoch, authenticated_at, issued_at, state, created_at
     ) VALUES (
       gen_random_uuid(), $1, $2, $3::timestamptz + interval '1 hour',
       $4, 0, $3, $3, 'active', $3
     )`,
    [familyId, accessHash, now, principalId],
  );
  const proofHash = hash32(`identity-mutation-proof-${suffix}-${marker}`);
  await bootstrap.query(
    `INSERT INTO roomscan.candidate_identity_proofs (
       token_hash, issuer, subject, purpose, initiating_principal_id,
       initiating_family_id, authenticated_at, issued_at, expires_at,
       policy_version
     ) VALUES (
       $1, 'https://appleid.apple.com', $2, 'link-identity', $3, $4,
       $5, $5, $5::timestamptz + interval '5 minutes', 'identity-v1'
     )`,
    [proofHash, `identity-mutation-target-${suffix}-0007`,
      principalId, familyId, now],
  );
  return { principalId, familyId, accessHash, proofHash };
}

async function waitForIdentityArbitration(applicationName, settled) {
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
  assert.fail(`timed out waiting for identity mutation arbitration ${applicationName}`);
}

function mutateArgs(candidate, suffix, marker) {
  return [
    candidate.accessHash, now, candidate.proofHash, 'link-identity', true,
    `aud_identity_race_${suffix}_${marker}_0007`,
    `notification_identity_race_${suffix}_${marker}_0007`,
    `id_identity_race_${suffix}_0007`, 'identity-v1',
  ];
}

try {
  await applyMigrations({ pool: bootstrap });
  await seedCoreFixtures(bootstrap);
  await bootstrap.query('SET ROLE roomscan_operator');
  await bootstrap.query(
    `SELECT * FROM roomscan.set_operational_flag(
       'global', NULL, 'professional_sign_in_enabled', true, NULL,
       'identity mutation race test', 'ofaud_identity_mutation_race_0007', $1
     )`,
    [now],
  );
  await bootstrap.query('RESET ROLE');
  api = new Pool({
    ...appPoolConfig(cluster, 8), user: 'roomscan_api_runtime', max: 8,
    application_name: 'rss-0007-identity-mutation-races',
  });
  const mutateSql = `SELECT * FROM roomscan.mutate_identity_v2(
    $1, $2, $3, $4, $5, $6, $7, $8, $9
  )`;

  const observedWaits = [];
  for (let index = 0; index < 3; index += 1) {
    const [isolation, suffix] = [
      ['READ COMMITTED', 'rc'],
      ['REPEATABLE READ', 'rr'],
      ['SERIALIZABLE', 'ser'],
    ][index];
    const candidates = await Promise.all([
      seedPrincipalAccess(principalPairs[index][0], suffix, 'a'),
      seedPrincipalAccess(principalPairs[index][1], suffix, 'b'),
    ]);
    const [writer, waiter] = await Promise.all([api.connect(), api.connect()]);
    const waiterName = `rss-identity-mutation-${suffix}`;
    let waiterSettled = false;
    let waiterOutcome;
    let linked;
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
      linked = (await writer.query(mutateSql, mutateArgs(candidates[0], suffix, 'a'))).rows[0];
      assert.equal(linked.status, 'linked');
      const waiterPromise = waiter.query(
        mutateSql, mutateArgs(candidates[1], suffix, 'b'),
      ).then((value) => ({ value }), (error) => ({ error }))
        .finally(() => { waiterSettled = true; });
      observedWaits.push(await waitForIdentityArbitration(waiterName, () => waiterSettled));
      await writer.query('COMMIT');
      waiterOutcome = await waiterPromise;
      if (isolation === 'READ COMMITTED') {
        assert.equal(waiterOutcome.value?.rows[0].status, 'candidate_owned');
        await waiter.query('COMMIT');
      } else {
        assert.equal(waiterOutcome.error?.code, '40001');
        assert.equal(waiterOutcome.error?.message, 'IDENTITY_MUTATION_RETRY_REQUIRED');
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
      const retried = (await api.query(
        mutateSql, mutateArgs(candidates[1], suffix, 'b'),
      )).rows[0];
      assert.equal(retried.status, 'candidate_owned');
    }
    assert.deepEqual((await bootstrap.query(
      `SELECT principal_id FROM roomscan.external_identities
        WHERE issuer = 'https://appleid.apple.com' AND subject = $1`,
      [`identity-mutation-target-${suffix}-0007`],
    )).rows, [{ principal_id: candidates[0].principalId }]);
    assert.deepEqual((await bootstrap.query(
      `SELECT token_hash = $1 AS winner, state
         FROM roomscan.candidate_identity_proofs
        WHERE token_hash = ANY($2::bytea[])
        ORDER BY token_hash`,
      [candidates[0].proofHash, candidates.map(({ proofHash }) => proofHash)],
    )).rows.map(({ winner, state }) => ({ winner, state }))
      .sort((a, b) => Number(b.winner) - Number(a.winner)), [
      { winner: true, state: 'consumed' },
      { winner: false, state: 'active' },
    ]);
    assert.equal((await bootstrap.query(
      `SELECT count(*)::integer AS count FROM roomscan.identity_audit_events
        WHERE id IN ($1, $2)`,
      [`aud_identity_race_${suffix}_a_0007`, `aud_identity_race_${suffix}_b_0007`],
    )).rows[0].count, 1);
    assert.equal((await bootstrap.query(
      `SELECT count(*)::integer AS count FROM roomscan.security_notification_outbox
        WHERE id IN ($1, $2)`,
      [`notification_identity_race_${suffix}_a_0007`,
        `notification_identity_race_${suffix}_b_0007`],
    )).rows[0].count, 1);
  }

  assert.deepEqual(observedWaits, ['advisory', 'advisory', 'advisory']);
  console.log(
    'INTEGRATION_0007_IDENTITY_MUTATION_RACES_SUMMARY isolation_levels=3 '
      + 'principals=6 independent_proofs=6 linked=3 candidate_owned=3 '
      + 'controlled_retries=2 fresh_retry_controls=2 winner_audits=3 '
      + 'loser_proofs_active=3 raw_23505=0 status=pass',
  );
} finally {
  if (api) await api.end();
  await bootstrap.end();
  const cleanup = await cluster.stop();
  console.log(`PG_CLEANUP ${JSON.stringify(cleanup)}`);
}
