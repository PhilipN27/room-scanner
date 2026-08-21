import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { appPoolConfig, hash32, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const cluster = await startPostgresCluster();
const bootstrap = new Pool(cluster.bootstrapConfig);
let challenge;
const now = new Date('2026-08-19T23:00:00.000Z');
const issueSql = `SELECT * FROM roomscan.consume_apple_bridge_and_issue_session(
  $1, $2, $3, $4, $5, $5, $6, $7, $8, 'session-v1'
)`;

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
  assert.fail(`timed out waiting for Apple identity arbitration ${applicationName}`);
}

async function seedProofPair(suffix, subject) {
  const proofHashes = [hash32(`apple-proof-${suffix}-a`), hash32(`apple-proof-${suffix}-b`)];
  for (let index = 0; index < 2; index += 1) {
    const marker = index === 0 ? 'a' : 'b';
    const attemptId = `apple_race_${suffix}_${marker}_0007`;
    await bootstrap.query(
      `INSERT INTO roomscan.apple_auth_attempts (
         id, state_hash, nonce_hash, code_challenge, expected_client_id,
         redirect_uri, created_at, expires_at, policy_version, purpose,
         state, claimed_at
       ) VALUES (
         $1, $2, $3, 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
         'com.roomscan.test', 'https://example.invalid/apple/callback',
         $4::timestamptz - interval '1 minute',
         $4::timestamptz + interval '5 minutes', 'apple-v1', 'sign-in',
         'claimed', $4
       )`,
      [attemptId, hash32(`apple-state-${suffix}-${marker}`),
        hash32(`apple-nonce-${suffix}-${marker}`), now],
    );
    await bootstrap.query(
      `INSERT INTO roomscan.apple_bridge_proofs (
         token_hash, issuer, subject, attempt_id, purpose,
         issued_at, expires_at, policy_version
       ) VALUES (
         $1, 'https://appleid.apple.com', $2, $3, 'sign-in',
         $4, $4::timestamptz + interval '5 minutes', 'apple-v1'
       )`,
      [proofHashes[index], subject, attemptId, now],
    );
  }
  return proofHashes;
}

function issueArgs(proofHash, suffix, marker) {
  return [
    proofHash, `fam_apple_${suffix}_${marker}_0007`,
    hash32(`apple-access-${suffix}-${marker}`),
    hash32(`apple-refresh-${suffix}-${marker}`), now,
    new Date(now.getTime() + 60_000),
    new Date(now.getTime() + 300_000),
    new Date(now.getTime() + 600_000),
  ];
}

try {
  await applyMigrations({ pool: bootstrap });
  await seedCoreFixtures(bootstrap);
  await bootstrap.query('SET ROLE roomscan_operator');
  await bootstrap.query(
    `SELECT * FROM roomscan.set_operational_flag(
       'global', NULL, 'professional_sign_in_enabled', true, NULL,
       'Apple identity race test', 'ofaud_apple_identity_race_0007', $1
     )`,
    [now],
  );
  await bootstrap.query('RESET ROLE');
  challenge = new Pool({
    ...appPoolConfig(cluster, 6), user: 'roomscan_auth_challenge_runtime', max: 6,
    application_name: 'rss-0007-apple-identity-races',
  });

  const observedWaits = [];
  for (const [isolation, suffix] of [
    ['READ COMMITTED', 'rc'],
    ['REPEATABLE READ', 'rr'],
    ['SERIALIZABLE', 'ser'],
  ]) {
    const subject = `apple-identity-race-${suffix}-0007`;
    const proofs = await seedProofPair(suffix, subject);
    const [writer, waiter] = await Promise.all([challenge.connect(), challenge.connect()]);
    const waiterName = `rss-apple-identity-${suffix}`;
    let waiterSettled = false;
    let waiterOutcome;
    let firstIssued;
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

      firstIssued = (await writer.query(issueSql, issueArgs(proofs[0], suffix, 'a'))).rows[0];
      assert.equal(firstIssued.status, 'issued');
      const waiterPromise = waiter.query(issueSql, issueArgs(proofs[1], suffix, 'b')).then(
        (value) => ({ value }),
        (error) => ({ error }),
      ).finally(() => { waiterSettled = true; });
      observedWaits.push(await waitForIdentityArbitration(waiterName, () => waiterSettled));
      await writer.query('COMMIT');
      waiterOutcome = await waiterPromise;

      if (isolation === 'READ COMMITTED') {
        assert.equal(waiterOutcome.value?.rows[0].status, 'issued');
        await waiter.query('COMMIT');
      } else {
        assert.equal(waiterOutcome.error?.code, '40001');
        assert.equal(waiterOutcome.error?.message, 'APPLE_IDENTITY_RETRY_REQUIRED');
        assert.notEqual(waiterOutcome.error?.code, '23505');
        await waiter.query('ROLLBACK');
      }
    } finally {
      await writer.query('ROLLBACK').catch(() => undefined);
      await waiter.query('ROLLBACK').catch(() => undefined);
      writer.release();
      waiter.release();
    }

    let secondIssued = waiterOutcome.value?.rows[0];
    if (isolation !== 'READ COMMITTED') {
      secondIssued = (await challenge.query(
        issueSql, issueArgs(proofs[1], suffix, 'b'),
      )).rows[0];
    }
    assert.equal(secondIssued.status, 'issued');
    assert.equal(secondIssued.principal_id, firstIssued.principal_id);
    assert.equal(secondIssued.principal_canonical_id, firstIssued.principal_canonical_id);
    assert.equal((await bootstrap.query(
      `SELECT count(*)::integer AS count
         FROM roomscan.external_identities
        WHERE issuer = 'https://appleid.apple.com' AND subject = $1`,
      [subject],
    )).rows[0].count, 1);
    assert.equal((await bootstrap.query(
      `SELECT count(*)::integer AS count
         FROM roomscan.auth_session_families
        WHERE principal_id = $1 AND public_id = ANY($2::text[])`,
      [firstIssued.principal_id, [
        `fam_apple_${suffix}_a_0007`, `fam_apple_${suffix}_b_0007`,
      ]],
    )).rows[0].count, 2);
  }

  assert.deepEqual(observedWaits, ['advisory', 'advisory', 'advisory']);
  console.log(
    'INTEGRATION_0007_APPLE_IDENTITY_RACES_SUMMARY isolation_levels=3 '
      + 'distinct_proofs=6 controlled_retries=2 fresh_retry_controls=2 '
      + 'identities=3 families=6 raw_23505=0 status=pass',
  );
} finally {
  if (challenge) await challenge.end();
  await bootstrap.end();
  const cleanup = await cluster.stop();
  console.log(`PG_CLEANUP ${JSON.stringify(cleanup)}`);
}
