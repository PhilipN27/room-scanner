import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { appPoolConfig, ids, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const cluster = await startPostgresCluster();
const bootstrapPool = new Pool(cluster.bootstrapConfig);
let appPool;

try {
  await applyMigrations({ pool: bootstrapPool });
  await seedCoreFixtures(bootstrapPool);
  appPool = new Pool(appPoolConfig(cluster, 1));
  const { withTenantTransaction } = await import('../runtime.mjs');
  const rows = await withTenantTransaction(
    appPool,
    {
      principalId: ids.principalA,
      requestedWorkspaceId: ids.workspaceA,
      expectedAuthorizationVersion: 1,
    },
    async (client) => (await client.query('SELECT id FROM roomscan.projects ORDER BY id')).rows,
  );
  assert.deepEqual(rows, [{ id: ids.projectA }]);
} finally {
  await appPool?.end();
  await bootstrapPool.end();
  const cleanup = await cluster.stop();
  console.error(`CLEANUP ${JSON.stringify(cleanup)}`);
}
