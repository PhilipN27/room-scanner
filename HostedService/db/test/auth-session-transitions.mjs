import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { accepted0006MigrationsDir } from './accepted-0006-migrations.mjs';
import { appPoolConfig, hash32, ids, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const now = new Date('2026-08-19T12:00:00.000Z');
const families = [
  '66000000-0000-4000-8000-000000000001',
  '66000000-0000-4000-8000-000000000002',
  '66000000-0000-4000-8000-000000000003',
];
const accessHash = hash32('session-transition-access');

const cluster = await startPostgresCluster();
const bootstrapPool = new Pool(cluster.bootstrapConfig);
let appPool;

try {
  await applyMigrations({ pool: bootstrapPool, migrationsDir: accepted0006MigrationsDir });
  await seedCoreFixtures(bootstrapPool);
  appPool = new Pool({ ...appPoolConfig(cluster, 4), application_name: 'rss-auth-session-transitions' });

  await bootstrapPool.query(
    `INSERT INTO roomscan.auth_session_families (
       id, public_id, principal_id, authentication_epoch, authenticated_at,
       created_at, last_used_at, inactivity_expires_at, absolute_expires_at,
       policy_version
     ) VALUES
       ($1, 'family_transition_one_01', $4, 0, $5, $5, $5,
        $5::timestamptz + interval '7 days',
        $5::timestamptz + interval '30 days', 'session-v1'),
       ($2, 'family_transition_two_01', $4, 0, $5, $5, $5,
        $5::timestamptz + interval '7 days',
        $5::timestamptz + interval '30 days', 'session-v1'),
       ($3, 'family_transition_three', $4, 0, $5, $5, $5,
        $5::timestamptz + interval '7 days',
        $5::timestamptz + interval '30 days', 'session-v1')`,
    [...families, ids.principalA, now],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.auth_access_tokens (
       id, family_id, token_hash, expires_at, created_at, principal_id,
       authentication_epoch, authenticated_at, issued_at
     ) VALUES ('77000000-0000-4000-8000-000000000001', $1, $2,
       $3::timestamptz + interval '5 minutes', $3, $4, 0, $3, $3)`,
    [families[0], accessHash, now, ids.principalA],
  );

  const usedAt = new Date(now.getTime() + 1_000);
  const inactivityAt = new Date(now.getTime() + (7 * 24 * 60 * 60 * 1_000));
  assert.equal((await appPool.query(
    `SELECT roomscan.update_session_family_activity($1, $2, $3) AS updated`,
    [families[0], usedAt, inactivityAt],
  )).rows[0].updated, true);
  assert.equal((await appPool.query(
    `SELECT roomscan.update_session_family_activity($1, $2, $3) AS updated`,
    [families[0], usedAt, inactivityAt],
  )).rows[0].updated, true, 'an exact activity retry must be idempotent');
  assert.equal((await appPool.query(
    `SELECT roomscan.update_session_family_activity($1, $2, $3) AS updated`,
    [families[0], new Date(now.getTime() - 1), inactivityAt],
  )).rows[0].updated, false, 'activity time must not move backwards');
  assert.equal((await appPool.query(
    `SELECT roomscan.update_session_family_activity($1, $2, $3) AS updated`,
    [families[0], usedAt, new Date(now.getTime() + (31 * 24 * 60 * 60 * 1_000))],
  )).rows[0].updated, false, 'inactivity expiry must not exceed the absolute expiry');

  assert.equal((await appPool.query(
    `SELECT roomscan.revoke_access_token($1, $2) AS revoked`,
    [accessHash, new Date(now.getTime() + 2_000)],
  )).rows[0].revoked, true);
  assert.equal((await appPool.query(
    `SELECT roomscan.revoke_access_token($1, $2) AS revoked`,
    [accessHash, new Date(now.getTime() + 2_001)],
  )).rows[0].revoked, false);
  assert.deepEqual((await bootstrapPool.query(
    `SELECT state, revoked_at IS NOT NULL AS revoked
     FROM roomscan.auth_access_tokens WHERE token_hash = $1`,
    [accessHash],
  )).rows[0], { state: 'revoked', revoked: true });

  assert.equal((await appPool.query(
    `SELECT roomscan.revoke_session_family($1, $2, 'logout') AS revoked`,
    [families[0], new Date(now.getTime() + 3_000)],
  )).rows[0].revoked, true);
  assert.equal((await appPool.query(
    `SELECT roomscan.revoke_session_family($1, $2, 'logout') AS revoked`,
    [families[0], new Date(now.getTime() + 3_001)],
  )).rows[0].revoked, false);

  const transaction = await appPool.connect();
  try {
    await transaction.query('BEGIN');
    const nextEpoch = Number((await transaction.query(
      `SELECT roomscan.bump_principal_authentication_epoch($1) AS epoch`,
      [ids.principalA],
    )).rows[0].epoch);
    const revokedFamilies = Number((await transaction.query(
      `SELECT roomscan.revoke_principal_session_families(
         $1, NULL::uuid, $2, 'logout_all'
       ) AS count`,
      [ids.principalA, new Date(now.getTime() + 4_000)],
    )).rows[0].count);
    assert.equal(nextEpoch, 1);
    assert.equal(revokedFamilies, 2);
    await transaction.query('COMMIT');
  } finally {
    transaction.release();
  }
  assert.equal((await bootstrapPool.query(
    `SELECT authentication_epoch FROM roomscan.principals WHERE id = $1`,
    [ids.principalA],
  )).rows[0].authentication_epoch, '1');
  assert.deepEqual((await bootstrapPool.query(
    `SELECT state, revoke_reason FROM roomscan.auth_session_families
     WHERE id = ANY($1::uuid[]) ORDER BY id`,
    [families],
  )).rows, [
    { state: 'revoked', revoke_reason: 'logout' },
    { state: 'revoked', revoke_reason: 'logout_all' },
    { state: 'revoked', revoke_reason: 'logout_all' },
  ]);

  for (const table of [
    'auth_session_families',
    'auth_access_tokens',
    'auth_refresh_tokens',
  ]) {
    await assert.rejects(
      () => appPool.query(`UPDATE roomscan.${table} SET state = state`),
      (error) => error?.code === '42501',
    );
    await assert.rejects(
      () => appPool.query(`DELETE FROM roomscan.${table}`),
      (error) => error?.code === '42501',
    );
    await assert.rejects(
      () => appPool.query(`TRUNCATE roomscan.${table}`),
      (error) => error?.code === '42501',
    );
  }

  console.log('AUTH_SESSION_TRANSITION_SUMMARY activity_update=true exact_retry=true backward_denied=true absolute_bound=true access_revoke_retry=true family_logout_retry=true logout_all_epoch=1 logout_all_families=2 direct_mutation_denied=3x3 status=pass');
} finally {
  await appPool?.end();
  await bootstrapPool.end();
  console.error(`AUTH_SESSION_TRANSITION_CLEANUP ${JSON.stringify(await cluster.stop())}`);
}
