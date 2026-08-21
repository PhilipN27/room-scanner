import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { accepted0006MigrationsDir } from './accepted-0006-migrations.mjs';
import { TenantContextError, withTenantTransaction } from '../runtime.mjs';
import { appPoolConfig, hash32, ids, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const cluster = await startPostgresCluster();
const bootstrapPool = new Pool(cluster.bootstrapConfig);
let appPool;
const contexts = [
  { principalId: ids.principalA, requestedWorkspaceId: ids.workspaceA, expectedAuthorizationVersion: 1 },
  { principalId: ids.principalB, requestedWorkspaceId: ids.workspaceB, expectedAuthorizationVersion: 1 },
];

const missingContextCalls = [
  "SELECT roomscan.activate_quota_policy(1,10,10,10,10,10,80)",
  "SELECT * FROM roomscan.reserve_quota('project_count',1,'missing')",
  "SELECT * FROM roomscan.finalize_quota('missing',1)",
  "SELECT * FROM roomscan.release_quota('missing')",
  `SELECT roomscan.record_stripe_event('acct','evt',decode(repeat('00',32),'hex'),true,clock_timestamp())`,
  "SELECT roomscan.apply_stripe_reconciliation(1,clock_timestamp(),'active','test',NULL)",
];

try {
  await applyMigrations({ pool: bootstrapPool, migrationsDir: accepted0006MigrationsDir });
  await seedCoreFixtures(bootstrapPool);
  appPool = new Pool(appPoolConfig(cluster, 4));

  for (const statement of missingContextCalls) {
    await assert.rejects(
      () => appPool.query(statement),
      (error) => error?.code === '42501' && error?.message === 'AUTHORIZED_TENANT_CONTEXT_REQUIRED',
    );
  }
  assert.equal((await appPool.query(
    'SELECT roomscan.has_authorized_tenant($1) AS authorized', [ids.workspaceA],
  )).rows[0].authorized, false);

  for (const [index, context] of contexts.entries()) {
    await withTenantTransaction(appPool, context, async (client) => {
      await client.query('SELECT roomscan.activate_quota_policy(1,10,10,10,10,10,80)');
      await client.query(
        "SELECT * FROM roomscan.reserve_quota('project_count',2,$1)", [`ctx-${index}-finalize`],
      );
      await client.query('SELECT * FROM roomscan.finalize_quota($1,1)', [`ctx-${index}-finalize`]);
      await client.query(
        "SELECT * FROM roomscan.reserve_quota('raw_bytes',1,$1)", [`ctx-${index}-release`],
      );
      await client.query('SELECT * FROM roomscan.release_quota($1)', [`ctx-${index}-release`]);
      await client.query(
        `SELECT roomscan.record_stripe_event($1,$2,$3,true,$4::timestamptz)`,
        [`acct_ctx_${index}`, `evt_ctx_${index}`, hash32(`ctx-${index}`), '2026-08-18T16:00:00Z'],
      );
      await client.query(
        `SELECT roomscan.apply_stripe_reconciliation(1,$1::timestamptz,'active','test',NULL)`,
        ['2026-08-18T16:00:00Z'],
      );
      assert.equal((await client.query(
        'SELECT roomscan.has_authorized_tenant($1) AS authorized', [context.requestedWorkspaceId],
      )).rows[0].authorized, true);
    });
  }

  for (const statement of missingContextCalls) {
    await assert.rejects(
      () => withTenantTransaction(appPool, {
        principalId: ids.principalA,
        requestedWorkspaceId: ids.workspaceA,
        expectedAuthorizationVersion: 99,
      }, (client) => client.query(statement)),
      (error) => error instanceof TenantContextError && error.code === 'STALE_AUTHORIZATION',
    );
    await assert.rejects(
      () => withTenantTransaction(appPool, {
        principalId: ids.principalA,
        requestedWorkspaceId: ids.workspaceB,
        expectedAuthorizationVersion: 1,
      }, (client) => client.query(statement)),
      (error) => error instanceof TenantContextError && error.code === 'ACTIVE_MEMBERSHIP_REQUIRED',
    );
    await assert.rejects(
      () => withTenantTransaction(appPool, {
        principalId: ids.principalA,
        requestedWorkspaceId: ids.workspaceA,
        expectedAuthorizationVersion: 1,
        tenantId: ids.workspaceB,
      }, (client) => client.query(statement)),
      (error) => error instanceof TenantContextError && error.code === 'CALLER_CONTEXT_REJECTED',
    );
  }
  console.log(`REDUCER_CONTEXT_SUMMARY reducers=${missingContextCalls.length + 1} tenants=2 missing=true stale=true wrong=true forged=true status=pass`);
} finally {
  await appPool?.end();
  await bootstrapPool.end();
  console.error(`CLEANUP ${JSON.stringify(await cluster.stop())}`);
}
