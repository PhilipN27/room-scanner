import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { accepted0006MigrationsDir } from './accepted-0006-migrations.mjs';
import * as runtime from '../runtime.mjs';
import { appPoolConfig, hash32, ids, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const authoritativeNow = new Date('2026-08-19T12:00:00.000Z');
const familyA = '60000000-0000-4000-8000-000000000001';
const familyB = '60000000-0000-4000-8000-000000000002';
const familyUnscoped = '60000000-0000-4000-8000-000000000003';
const accessA = '70000000-0000-4000-8000-000000000001';
const accessB = '70000000-0000-4000-8000-000000000002';
const accessUnscoped = '70000000-0000-4000-8000-000000000003';

const cluster = await startPostgresCluster();
const bootstrapPool = new Pool(cluster.bootstrapConfig);
let appPool;

async function currentContext(client) {
  return (await client.query(
    `SELECT NULLIF(current_setting('app.principal_id', true), '') AS principal_id,
            NULLIF(current_setting('app.tenant_id', true), '') AS tenant_id,
            NULLIF(current_setting('app.authorization_version', true), '') AS authorization_version`,
  )).rows[0];
}

try {
  assert.equal(
    typeof runtime.withResolvedAccessTransaction,
    'function',
    'the access-token-only transaction resolver is missing',
  );
  assert.equal(typeof runtime.AccessContextError, 'function');

  await applyMigrations({ pool: bootstrapPool, migrationsDir: accepted0006MigrationsDir });
  await seedCoreFixtures(bootstrapPool);
  await bootstrapPool.query(
    `INSERT INTO roomscan.auth_session_families (
       id, public_id, principal_id, authentication_epoch, authenticated_at,
       created_at, last_used_at, inactivity_expires_at, absolute_expires_at,
       policy_version, workspace_id, role, authorization_version
     ) VALUES
       ($1, 'family_access_a_0001', $4, 0, $7::timestamptz, $7::timestamptz, $7::timestamptz, $7::timestamptz + interval '7 days', $7::timestamptz + interval '30 days', 'session-v1', $5, 'owner', 1),
       ($2, 'family_access_b_0001', $6, 0, $7::timestamptz, $7::timestamptz, $7::timestamptz, $7::timestamptz + interval '7 days', $7::timestamptz + interval '30 days', 'session-v1', $8, 'owner', 1),
       ($3, 'family_unscoped_0001', $4, 0, $7::timestamptz, $7::timestamptz, $7::timestamptz, $7::timestamptz + interval '7 days', $7::timestamptz + interval '30 days', 'session-v1', NULL, NULL, NULL)`,
    [familyA, familyB, familyUnscoped, ids.principalA, ids.workspaceA, ids.principalB, authoritativeNow, ids.workspaceB],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.auth_access_tokens (
       id, family_id, token_hash, expires_at, created_at, principal_id,
       authentication_epoch, authenticated_at, issued_at, workspace_id, role,
       authorization_version
     ) VALUES
       ($1, $4, $7, $10::timestamptz + interval '5 minutes', $10::timestamptz, $5, 0, $10::timestamptz, $10::timestamptz, $6, 'owner', 1),
       ($2, $8, $9, $10::timestamptz + interval '5 minutes', $10::timestamptz, $11, 0, $10::timestamptz, $10::timestamptz, $12, 'owner', 1),
       ($3, $13, $14, $10::timestamptz + interval '5 minutes', $10::timestamptz, $5, 0, $10::timestamptz, $10::timestamptz, NULL, NULL, NULL)`,
    [
      accessA,
      accessB,
      accessUnscoped,
      familyA,
      ids.principalA,
      ids.workspaceA,
      hash32('access-a'),
      familyB,
      hash32('access-b'),
      authoritativeNow,
      ids.principalB,
      ids.workspaceB,
      familyUnscoped,
      hash32('access-unscoped'),
    ],
  );
  const scopedRefreshHash = hash32('refresh-scoped-a');
  await bootstrapPool.query(
    `INSERT INTO roomscan.auth_refresh_tokens (token_hash, family_id, issued_at)
     VALUES ($1, $2, $3)`,
    [scopedRefreshHash, familyA, authoritativeNow],
  );

  appPool = new Pool({ ...appPoolConfig(cluster, 1), application_name: 'rss-auth-resolver' });
  const contextA = await runtime.withResolvedAccessTransaction(
    appPool,
    { accessTokenHash: hash32('access-a'), authoritativeNow },
    async (client, resolved) => {
      assert.deepEqual(await currentContext(client), {
        principal_id: ids.principalA,
        tenant_id: ids.workspaceA,
        authorization_version: '1',
      });
      const visible = (await client.query(
        `SELECT workspace_id FROM roomscan.projects ORDER BY workspace_id`,
      )).rows;
      assert.deepEqual(visible, [{ workspace_id: ids.workspaceA }]);
      return resolved;
    },
  );
  assert.equal(contextA.principalId, ids.principalA);
  assert.equal(contextA.workspaceId, ids.workspaceA);
  assert.equal(contextA.familyId, familyA);
  assert.equal(contextA.role, 'owner');
  assert.equal(contextA.authorizationVersion, 1);
  assert.equal(contextA.recentAuthentication, true);
  assert.deepEqual(await currentContext(appPool), {
    principal_id: null,
    tenant_id: null,
    authorization_version: null,
  });

  const contextB = await runtime.withResolvedAccessTransaction(
    appPool,
    { accessTokenHash: hash32('access-b'), authoritativeNow },
    async (client, resolved) => {
      assert.deepEqual(await currentContext(client), {
        principal_id: ids.principalB,
        tenant_id: ids.workspaceB,
        authorization_version: '1',
      });
      assert.deepEqual((await client.query('SELECT workspace_id FROM roomscan.projects')).rows, [
        { workspace_id: ids.workspaceB },
      ]);
      return resolved;
    },
  );
  assert.equal(contextB.workspaceId, ids.workspaceB);

  const unscoped = await runtime.withResolvedAccessTransaction(
    appPool,
    { accessTokenHash: hash32('access-unscoped'), authoritativeNow },
    async (client, resolved) => {
      assert.deepEqual(await currentContext(client), {
        principal_id: ids.principalA,
        tenant_id: null,
        authorization_version: null,
      });
      assert.deepEqual((await client.query('SELECT workspace_id FROM roomscan.projects')).rows, []);
      return resolved;
    },
  );
  assert.equal(unscoped.workspaceId, undefined);

  let callbackReached = false;
  await assert.rejects(
    () => runtime.withResolvedAccessTransaction(
      appPool,
      { accessTokenHash: hash32('missing-access'), authoritativeNow },
      async () => {
        callbackReached = true;
      },
    ),
    (error) => error instanceof runtime.AccessContextError
      && error.code === 'AUTHENTICATION_REQUIRED',
  );
  assert.equal(callbackReached, false);
  assert.deepEqual(await currentContext(appPool), {
    principal_id: null,
    tenant_id: null,
    authorization_version: null,
  });

  await assert.rejects(
    () => runtime.withResolvedAccessTransaction(
      appPool,
      {
        accessTokenHash: hash32('access-a'),
        authoritativeNow,
        requestedWorkspaceId: ids.workspaceB,
      },
      async () => undefined,
    ),
    (error) => error instanceof runtime.AccessContextError
      && error.code === 'CALLER_CONTEXT_REJECTED',
  );

  await bootstrapPool.query(
    `INSERT INTO roomscan.memberships (workspace_id, principal_id, role, state)
     VALUES ($1, $2, 'owner', 'active')`,
    [ids.workspaceA, ids.principalExtraOwner],
  );
  await bootstrapPool.query(
    `UPDATE roomscan.memberships
     SET role = 'viewer'
     WHERE workspace_id = $1 AND principal_id = $2`,
    [ids.workspaceA, ids.principalA],
  );
  await assert.rejects(
    () => runtime.withResolvedAccessTransaction(
      appPool,
      { accessTokenHash: hash32('access-a'), authoritativeNow },
      async () => undefined,
    ),
    (error) => error instanceof runtime.AccessContextError
      && error.code === 'AUTHENTICATION_REQUIRED',
  );
  assert.equal((await appPool.query(
    `SELECT roomscan.claim_refresh_rotation($1, $2, $3) AS claimed`,
    [scopedRefreshHash, hash32('refresh-scoped-a-next'), authoritativeNow],
  )).rows[0].claimed, false);
  assert.equal((await bootstrapPool.query(
    `SELECT state FROM roomscan.auth_refresh_tokens WHERE token_hash = $1`,
    [scopedRefreshHash],
  )).rows[0].state, 'active');

  console.log('AUTH_RESOLVER_SUMMARY scoped_tenants=2 unscoped=true invalid=true stale_membership=true stale_membership_refresh_denied=true pooled_context_clear=true caller_workspace_rejected=true status=pass');
} finally {
  await appPool?.end();
  await bootstrapPool.end();
  console.error(`AUTH_RESOLVER_CLEANUP ${JSON.stringify(await cluster.stop())}`);
}
