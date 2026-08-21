import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const reservedRoles = [
  ['roomscan_owner', 'NOLOGIN'],
  ['roomscan_policy', 'NOLOGIN'],
  ['roomscan_app', 'LOGIN'],
];
const cleanupEvidence = [];

for (const [reservedRole, loginMode] of reservedRoles) {
  const cluster = await startPostgresCluster();
  const bootstrapPool = new Pool(cluster.bootstrapConfig);
  try {
    await bootstrapPool.query(`CREATE ROLE dirty_catalog_attacker LOGIN`);
    await bootstrapPool.query(`CREATE ROLE ${reservedRole} ${loginMode}`);
    await bootstrapPool.query(`GRANT ${reservedRole} TO dirty_catalog_attacker`);

    await assert.rejects(
      () => applyMigrations({ pool: bootstrapPool }),
      (error) => (
        error?.code === '42710'
        && error?.message.includes(`role "${reservedRole}" already exists`)
      ),
      `first migration silently adopted the pre-existing ${reservedRole} role`,
    );

    const appliedCount = (await bootstrapPool.query(
      `SELECT count(*)::int AS count FROM public.roomscan_schema_migrations`,
    )).rows[0].count;
    assert.equal(appliedCount, 0, 'failed first migration must not be recorded');

    const attackerCanSetReservedRole = (await bootstrapPool.query(
      `SELECT pg_has_role('dirty_catalog_attacker', $1, 'MEMBER') AS can_set_role`,
      [reservedRole],
    )).rows[0].can_set_role;
    assert.equal(attackerCanSetReservedRole, true, 'dirty-cluster control did not create the attack edge');
  } finally {
    await bootstrapPool.end();
    cleanupEvidence.push({ reservedRole, ...(await cluster.stop()) });
  }
}

console.log('DIRTY_ROLE_TEST_SUMMARY cases=3 rejected=3 status=pass');
console.error(`DIRTY_ROLE_PROCESS_CLEANUP ${JSON.stringify(cleanupEvidence)}`);
