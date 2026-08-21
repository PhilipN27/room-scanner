import assert from 'node:assert/strict';
import { setTimeout as delay } from 'node:timers/promises';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { accepted0006MigrationsDir } from './accepted-0006-migrations.mjs';
import { appPoolConfig, hash32 } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const now = new Date('2026-08-19T12:00:00.000Z');

async function waitForAdvisoryWaiter(observer, applicationName) {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    const count = (await observer.query(
      `SELECT count(*)::int AS count
       FROM pg_stat_activity
       WHERE application_name = $1
         AND wait_event_type = 'Lock'
         AND lower(wait_event) = 'advisory'`,
      [applicationName],
    )).rows[0].count;
    if (count >= 1) return count;
    await delay(10);
  }
  throw new Error('timed out waiting for the magic-policy advisory lock');
}

const cluster = await startPostgresCluster();
const bootstrapPool = new Pool(cluster.bootstrapConfig);
let appPool;
let clientA;
let clientB;

try {
  await applyMigrations({ pool: bootstrapPool, migrationsDir: accepted0006MigrationsDir });
  appPool = new Pool({
    ...appPoolConfig(cluster, 2),
    application_name: 'rss-auth-magic-policy-lock',
  });
  clientA = await appPool.connect();
  clientB = await appPool.connect();

  const addressHash = hash32('magic-policy-address');
  await clientA.query('BEGIN');
  await clientB.query('BEGIN');
  assert.equal((await clientA.query(
    `SELECT roomscan.lock_magic_policy_scope('address-delivery', $1) AS locked`,
    [addressHash],
  )).rows[0].locked, true);
  const firstCount = (await clientA.query(
    `SELECT count(*)::int AS count FROM roomscan.magic_link_rate_events
     WHERE kind = 'delivery' AND subject_hash = $1 AND occurred_at >= $2`,
    [addressHash, new Date(now.getTime() - 1)],
  )).rows[0].count;
  assert.equal(firstCount, 0);

  const secondLock = clientB.query(
    `SELECT roomscan.lock_magic_policy_scope('address-delivery', $1) AS locked`,
    [addressHash],
  );
  const waiterCount = await waitForAdvisoryWaiter(
    bootstrapPool,
    'rss-auth-magic-policy-lock',
  );
  await clientA.query(
    `INSERT INTO roomscan.magic_link_rate_events (kind, subject_hash, occurred_at)
     VALUES ('delivery', $1, $2)`,
    [addressHash, now],
  );
  await clientA.query('COMMIT');
  assert.equal((await secondLock).rows[0].locked, true);
  const secondCount = (await clientB.query(
    `SELECT count(*)::int AS count FROM roomscan.magic_link_rate_events
     WHERE kind = 'delivery' AND subject_hash = $1 AND occurred_at >= $2`,
    [addressHash, new Date(now.getTime() - 1)],
  )).rows[0].count;
  assert.equal(secondCount, 1, 'the second issuance did not observe the first committed rate event');
  await clientB.query(
    `INSERT INTO roomscan.magic_link_rate_events (kind, subject_hash, occurred_at)
     VALUES ('delivery', $1, $2)`,
    [addressHash, new Date(now.getTime() + 1)],
  );
  await clientB.query('COMMIT');
  assert.equal((await bootstrapPool.query(
    `SELECT count(*)::int AS count FROM roomscan.magic_link_rate_events
     WHERE kind = 'delivery' AND subject_hash = $1`,
    [addressHash],
  )).rows[0].count, 2);

  const identityHash = hash32('magic-policy-active-identity');
  await clientA.query('BEGIN');
  await clientB.query('BEGIN');
  await clientA.query(
    `SELECT roomscan.lock_magic_policy_scope('active-identity', $1)`,
    [identityHash],
  );
  const rollbackWaiter = clientB.query(
    `SELECT roomscan.lock_magic_policy_scope('active-identity', $1) AS locked`,
    [identityHash],
  );
  await waitForAdvisoryWaiter(bootstrapPool, 'rss-auth-magic-policy-lock');
  await clientA.query('ROLLBACK');
  assert.equal((await rollbackWaiter).rows[0].locked, true);
  await clientB.query('ROLLBACK');

  clientA.release();
  clientA = undefined;
  clientB.release();
  clientB = undefined;
  const retainedLocks = (await bootstrapPool.query(
    `SELECT count(*)::int AS count
     FROM pg_locks AS lock
     JOIN pg_stat_activity AS activity ON activity.pid = lock.pid
     WHERE lock.locktype = 'advisory'
       AND activity.application_name = 'rss-auth-magic-policy-lock'`,
  )).rows[0].count;
  assert.equal(retainedLocks, 0);

  console.log(`AUTH_MAGIC_POLICY_LOCK_SUMMARY same_scope_serialized=true first_count=${firstCount} second_count=${secondCount} barrier_waiters=${waiterCount} rollback_releases=true pooled_lock_retention=false status=pass`);
} finally {
  if (clientA) {
    await clientA.query('ROLLBACK').catch(() => undefined);
    clientA.release();
  }
  if (clientB) {
    await clientB.query('ROLLBACK').catch(() => undefined);
    clientB.release();
  }
  await appPool?.end();
  await bootstrapPool.end();
  console.error(`AUTH_MAGIC_POLICY_LOCK_CLEANUP ${JSON.stringify(await cluster.stop())}`);
}
