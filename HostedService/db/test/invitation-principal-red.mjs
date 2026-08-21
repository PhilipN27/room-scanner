import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { accepted0006MigrationsDir } from './accepted-0006-migrations.mjs';
import * as runtime from '../runtime.mjs';
import { appPoolConfig, hash32, ids, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const cluster = await startPostgresCluster();
const bootstrapPool = new Pool(cluster.bootstrapConfig);
let appPool;

try {
  await applyMigrations({ pool: bootstrapPool, migrationsDir: accepted0006MigrationsDir });
  await seedCoreFixtures(bootstrapPool);
  appPool = new Pool(appPoolConfig(cluster, 2));
  assert.equal(typeof runtime.withPrincipalTransaction, 'function');
  const accepted = await runtime.withPrincipalTransaction(
    appPool,
    { principalId: ids.principalInvitee },
    async (client) => (
      await client.query('SELECT roomscan.consume_invitation($1) AS accepted', [hash32('invitation-a')])
    ).rows[0].accepted,
  );
  assert.equal(accepted, true);
  console.log('INVITATION_PRINCIPAL_TEST_SUMMARY cases=1 status=pass');
} finally {
  await appPool?.end();
  await bootstrapPool.end();
  const cleanup = await cluster.stop();
  console.error(`CLEANUP ${JSON.stringify(cleanup)}`);
}
