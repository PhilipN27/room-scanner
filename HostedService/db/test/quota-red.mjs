import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { accepted0006MigrationsDir } from './accepted-0006-migrations.mjs';
import { withTenantTransaction } from '../runtime.mjs';
import { appPoolConfig, ids, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const cluster = await startPostgresCluster();
const bootstrapPool = new Pool(cluster.bootstrapConfig);
let appPool;

const context = {
  principalId: ids.principalA,
  requestedWorkspaceId: ids.workspaceA,
  expectedAuthorizationVersion: 1,
};

async function inTenant(operation) {
  return await withTenantTransaction(appPool, context, operation);
}

async function expectQuotaExceeded(operation) {
  await assert.rejects(operation, (error) => error?.code === 'P0001' && error?.message === 'QUOTA_EXCEEDED');
}

try {
  await applyMigrations({ pool: bootstrapPool, migrationsDir: accepted0006MigrationsDir });
  await seedCoreFixtures(bootstrapPool);
  appPool = new Pool(appPoolConfig(cluster, 6));

  await inTenant(async (client) => {
    await client.query(
      `SELECT * FROM roomscan.activate_quota_policy(
        1, 2, 2, 10, 10, 10, 80
      )`,
    );
  });

  for (const [metric, limit] of [
    ['project_count', 2],
    ['member_count', 2],
    ['working_bytes', 10],
    ['raw_bytes', 10],
    ['portal_bytes', 10],
  ]) {
    const key = `boundary-${metric}`;
    const first = await inTenant(async (client) => (
      await client.query('SELECT * FROM roomscan.reserve_quota($1, $2, $3)', [metric, limit, key])
    ).rows[0]);
    assert.equal(first.reservation_state, 'reserved');
    await expectQuotaExceeded(() => inTenant((client) => (
      client.query('SELECT * FROM roomscan.reserve_quota($1, 1, $2)', [metric, `over-${metric}`])
    )));
    const released = await inTenant(async (client) => (
      await client.query('SELECT * FROM roomscan.release_quota($1)', [key])
    ).rows[0]);
    const releaseRetry = await inTenant(async (client) => (
      await client.query('SELECT * FROM roomscan.release_quota($1)', [key])
    ).rows[0]);
    assert.deepEqual(releaseRetry, released);
  }

  const reserved = await inTenant(async (client) => (
    await client.query(
      "SELECT * FROM roomscan.reserve_quota('working_bytes', 5, 'finalize-working')",
    )
  ).rows[0]);
  const reservedRetry = await inTenant(async (client) => (
    await client.query(
      "SELECT * FROM roomscan.reserve_quota('working_bytes', 5, 'finalize-working')",
    )
  ).rows[0]);
  assert.deepEqual(reservedRetry, reserved);

  const finalized = await inTenant(async (client) => (
    await client.query("SELECT * FROM roomscan.finalize_quota('finalize-working', 4)")
  ).rows[0]);
  const finalizedRetry = await inTenant(async (client) => (
    await client.query("SELECT * FROM roomscan.finalize_quota('finalize-working', 4)")
  ).rows[0]);
  assert.deepEqual(finalizedRetry, finalized);
  assert.equal(finalized.reservation_state, 'finalized');
  await assert.rejects(
    () => inTenant((client) => client.query("SELECT * FROM roomscan.release_quota('finalize-working')")),
    (error) => error?.code === 'P0001' && error?.message === 'QUOTA_RESERVATION_FINALIZED',
  );
  await assert.rejects(
    () => inTenant((client) => client.query(
      "SELECT * FROM roomscan.reserve_quota('working_bytes', 6, 'finalize-working')",
    )),
    (error) => error?.code === 'P0001' && error?.message === 'IDEMPOTENCY_KEY_REUSED',
  );
  await inTenant((client) => client.query(
    "SELECT * FROM roomscan.reserve_quota('raw_bytes', 1, 'release-then-finalize')",
  ));
  await inTenant((client) => client.query("SELECT * FROM roomscan.release_quota('release-then-finalize')"));
  await assert.rejects(
    () => inTenant((client) => client.query(
      "SELECT * FROM roomscan.finalize_quota('release-then-finalize', 1)",
    )),
    (error) => error?.code === 'P0001' && error?.message === 'QUOTA_RESERVATION_RELEASED',
  );
  await assert.rejects(
    () => inTenant((client) => client.query("SELECT * FROM roomscan.release_quota('missing-release')")),
    (error) => error?.code === 'P0001' && error?.message === 'QUOTA_RESERVATION_NOT_FOUND',
  );

  await inTenant(async (client) => {
    await client.query(
      "SELECT * FROM roomscan.reserve_quota('portal_bytes', 9, 'portal-used')",
    );
    await client.query("SELECT * FROM roomscan.finalize_quota('portal-used', 9)");
  });
  const race = await Promise.allSettled([
    inTenant((client) => client.query(
      "SELECT * FROM roomscan.reserve_quota('portal_bytes', 1, 'portal-race-a')",
    )),
    inTenant((client) => client.query(
      "SELECT * FROM roomscan.reserve_quota('portal_bytes', 1, 'portal-race-b')",
    )),
  ]);
  assert.equal(race.filter(({ status }) => status === 'fulfilled').length, 1);
  assert.equal(
    race.filter(({ status, reason }) => status === 'rejected' && reason?.message === 'QUOTA_EXCEEDED').length,
    1,
  );

  await inTenant((client) => client.query(
    'SELECT * FROM roomscan.activate_quota_policy(2, 2, 2, 3, 10, 10, 75)',
  ));
  const warning = await inTenant(async (client) => (
    await client.query(
      "SELECT used, reserved, limit_value, warning_state, over_limit FROM roomscan.quota_usage WHERE metric = 'working_bytes'",
    )
  ).rows[0]);
  assert.deepEqual(warning, {
    used: '4',
    reserved: '0',
    limit_value: '3',
    warning_state: true,
    over_limit: true,
  });
  assert.equal(
    await inTenant(async (client) => (
      await client.query('SELECT count(*)::int AS count FROM roomscan.projects')
    ).rows[0].count),
    1,
  );
  await expectQuotaExceeded(() => inTenant((client) => client.query(
    "SELECT * FROM roomscan.reserve_quota('working_bytes', 1, 'downgrade-denied')",
  )));
  console.log('QUOTA_TEST_SUMMARY metrics=5 release_retry=true terminal_edges=true race=true status=pass');
} finally {
  await appPool?.end();
  await bootstrapPool.end();
  const cleanup = await cluster.stop();
  console.error(`CLEANUP ${JSON.stringify(cleanup)}`);
}
