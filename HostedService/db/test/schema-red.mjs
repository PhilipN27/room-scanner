import assert from 'node:assert/strict';
import pg from 'pg';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const cluster = await startPostgresCluster();
const pool = new Pool(cluster.bootstrapConfig);

try {
  const { rows } = await pool.query("SELECT to_regclass('roomscan.workspaces')::text AS relation");
  assert.equal(rows[0].relation, 'roomscan.workspaces', 'tenant schema migration must create workspaces');
} finally {
  await pool.end();
  const cleanup = await cluster.stop();
  console.error(`CLEANUP ${JSON.stringify(cleanup)}`);
}
