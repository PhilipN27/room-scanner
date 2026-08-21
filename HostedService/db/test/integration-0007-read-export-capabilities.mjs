import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { appPoolConfig, hash32, ids, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const cluster = await startPostgresCluster();
const bootstrapPool = new Pool(cluster.bootstrapConfig);
let apiPool;
let authorizerPool;
let auditPool;
let challengePool;
const now = new Date('2026-08-19T15:00:00.000Z');

async function insertScopedAccess(principalId, workspaceId, role, version, publicId, label) {
  const familyId = label === 'read-a'
    ? '67000000-0000-4000-8000-000000000001'
    : '67000000-0000-4000-8000-000000000002';
  const digest = hash32(label);
  await bootstrapPool.query(
    `INSERT INTO roomscan.auth_session_families (
       id, public_id, principal_id, authentication_epoch, authenticated_at,
       last_used_at, inactivity_expires_at, absolute_expires_at,
       policy_version, workspace_id, role, authorization_version,
       state, created_at
     ) VALUES ($1, $2, $3, 0, $4, $4, $4::timestamptz + interval '1 day',
       $4::timestamptz + interval '7 days', 'session-v1', $5, $6, $7,
       'active', $4)`,
    [familyId, publicId, principalId, now, workspaceId, role, version],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.auth_access_tokens (
       id, family_id, token_hash, expires_at, principal_id,
       authentication_epoch, authenticated_at, issued_at, workspace_id,
       role, authorization_version, state, created_at
     ) VALUES (gen_random_uuid(), $1, $2, $3::timestamptz + interval '1 hour',
       $4, 0, $3, $3, $5, $6, $7, 'active', $3)`,
    [familyId, digest, now, principalId, workspaceId, role, version],
  );
  return digest;
}

try {
  await applyMigrations({ pool: bootstrapPool });
  await seedCoreFixtures(bootstrapPool);
  const accessA = await insertScopedAccess(
    ids.principalA, ids.workspaceA, 'owner', 1, 'fam_reada0000000007', 'read-a',
  );
  const accessB = await insertScopedAccess(
    ids.principalB, ids.workspaceB, 'owner', 1, 'fam_readb0000000007', 'read-b',
  );

  apiPool = new Pool({ ...appPoolConfig(cluster, 2), user: 'roomscan_api_runtime' });
  authorizerPool = new Pool({
    ...appPoolConfig(cluster, 1), user: 'roomscan_authorizer_runtime', max: 1,
  });
  auditPool = new Pool({ ...appPoolConfig(cluster, 2), user: 'roomscan_audit_export_runtime' });
  challengePool = new Pool({ ...appPoolConfig(cluster, 2), user: 'roomscan_auth_challenge_runtime' });

  const readAuthorizationSql =
    'SELECT * FROM roomscan.read_workspace_authorization_state($1, $2)';
  const defaultOffResult = await authorizerPool.query(readAuthorizationSql, [accessA, now]);
  assert.equal(defaultOffResult.rowCount, 1);
  const defaultOff = defaultOffResult.rows[0];
  assert.equal(defaultOff.workspace_id, ids.workspaceA);
  assert.equal(defaultOff.workspace_slug, 'workspace-a');
  assert.equal(defaultOff.workspace_display_name, 'Workspace A');
  assert.equal(defaultOff.hosted_global_enabled, false);
  assert.equal(defaultOff.hosted_workspace_enabled, false);
  assert.equal(defaultOff.publication_global_enabled, false);
  assert.equal(defaultOff.publication_workspace_enabled, false);
  assert.equal(defaultOff.editor_publishing_allowed, false);

  await bootstrapPool.query('SET ROLE roomscan_operator');
  for (const [scope, workspaceId, flag, auditId] of [
    ['global', null, 'hosted_operations_enabled', 'ofaud_readhostedglobal'],
    ['workspace', ids.workspaceA, 'hosted_operations_enabled', 'ofaud_readhostedtenant'],
    ['global', null, 'publication_enabled', 'ofaud_readpublicationglobal'],
    ['workspace', ids.workspaceA, 'publication_enabled', 'ofaud_readpublicationtenant'],
  ]) {
    await bootstrapPool.query(
      `SELECT * FROM roomscan.set_operational_flag(
         $1, $2::uuid, $3, true, NULL, 'read integration', $4, $5
       )`,
      [scope, workspaceId, flag, auditId, now],
    );
  }
  await bootstrapPool.query(
    `SELECT * FROM roomscan.set_workspace_publishing_policy(
       $1, true, NULL, 'read integration', 'ofaud_readeditorpublish', $2
     )`, [ids.workspaceA, now],
  );
  await bootstrapPool.query(
    `SELECT roomscan.bind_stripe_account(
       $1, 'platform', 'acct_readworkspaceA', 'cus_readworkspaceA',
       'sub_readworkspaceA', $2
     )`,
    [ids.workspaceA, now],
  );
  await bootstrapPool.query('RESET ROLE');

  const enabled = (await apiPool.query(readAuthorizationSql, [accessA, now])).rows[0];
  assert.equal(enabled.hosted_global_enabled, true);
  assert.equal(enabled.hosted_workspace_enabled, true);
  assert.equal(enabled.publication_global_enabled, true);
  assert.equal(enabled.publication_workspace_enabled, true);
  assert.equal(enabled.editor_publishing_allowed, true);
  assert.equal(enabled.principal_canonical_id.startsWith('prn_'), true);
  const bStateResult = await authorizerPool.query(readAuthorizationSql, [accessB, now]);
  assert.equal(bStateResult.rowCount, 1);
  const bState = bStateResult.rows[0];
  assert.equal(bState.workspace_id, ids.workspaceB);
  assert.equal(bState.workspace_slug, 'workspace-b');
  assert.equal(bState.workspace_display_name, 'Workspace B');
  assert.equal(bState.hosted_workspace_enabled, false);
  assert.equal((await authorizerPool.query(readAuthorizationSql, [hash32('unknown'), now])).rowCount, 0);
  const leakedContext = await authorizerPool.query(
    `SELECT current_setting('app.tenant_id', true) AS tenant,
            current_setting('app.principal_id', true) AS principal`,
  );
  assert.equal(leakedContext.rows[0].tenant, null);
  assert.equal(leakedContext.rows[0].principal, null);
  await assert.rejects(
    () => apiPool.query(
      `SELECT * FROM roomscan.read_workspace_authorization_state($1, $2, $3)`,
      [accessA, now, ids.workspaceB],
    ),
    (error) => error?.code === '42883',
  );

  const subscription = (await apiPool.query(
    `SELECT * FROM roomscan.read_current_subscription_v2($1, $2)`,
    [accessA, now],
  )).rows[0];
  assert.equal(subscription.workspace_id, ids.workspaceA);
  assert.equal(subscription.provider_account_id, 'acct_readworkspaceA');
  assert.equal(subscription.plan_key, 'starter');
  assert.equal(subscription.status, 'active');
  assert.equal('requested_workspace_id' in subscription, false);

  await assert.rejects(
    () => apiPool.query(
      `SELECT * FROM roomscan.read_workspace_audit_batch($1, 0, 10)`, [ids.workspaceB],
    ),
    (error) => error?.code === '42501',
  );
  const auditA = await auditPool.query(
    `SELECT * FROM roomscan.read_workspace_audit_batch($1, 0, 10)`, [ids.workspaceA],
  );
  assert.equal(auditA.rowCount >= 1, true);
  assert.equal(auditA.rows.every(({ workspace_id }) => workspace_id === ids.workspaceA), true);
  const marked = (await auditPool.query(
    `SELECT * FROM roomscan.mark_workspace_audit_exported($1, 0, 1, $2)`,
    [ids.workspaceA, now],
  )).rows[0];
  assert.equal(marked.status, 'marked');
  assert.equal(marked.last_exported_sequence, '1');
  const stale = (await auditPool.query(
    `SELECT * FROM roomscan.mark_workspace_audit_exported($1, 0, 1, $2)`,
    [ids.workspaceA, new Date(now.getTime() + 1_000)],
  )).rows[0];
  assert.equal(stale.status, 'stale');
  assert.equal((await bootstrapPool.query(
    `SELECT last_exported_sequence FROM roomscan.audit_states WHERE workspace_id = $1`,
    [ids.workspaceB],
  )).rows[0].last_exported_sequence, '0');

  for (const [role, routine, expected] of [
    ['roomscan_api_runtime', 'roomscan.read_workspace_authorization_state(bytea,timestamp with time zone)', true],
    ['roomscan_authorizer_runtime', 'roomscan.read_workspace_authorization_state(bytea,timestamp with time zone)', true],
    ['roomscan_auth_challenge_runtime', 'roomscan.read_workspace_authorization_state(bytea,timestamp with time zone)', false],
    ['roomscan_api_runtime', 'roomscan.read_current_subscription_v2(bytea,timestamp with time zone)', true],
    ['roomscan_audit_export_runtime', 'roomscan.read_workspace_audit_batch(uuid,bigint,integer)', true],
    ['roomscan_api_runtime', 'roomscan.read_workspace_audit_batch(uuid,bigint,integer)', false],
    ['roomscan_audit_export_runtime', 'roomscan.mark_workspace_audit_exported(uuid,bigint,bigint,timestamp with time zone)', true],
    ['roomscan_email_delivery_runtime', 'roomscan.read_workspace_audit_batch(uuid,bigint,integer)', false],
  ]) {
    assert.equal((await bootstrapPool.query(
      `SELECT has_function_privilege($1, $2, 'EXECUTE') AS allowed`, [role, routine],
    )).rows[0].allowed, expected, `${role} ${routine}`);
  }
  await assert.rejects(
    () => challengePool.query(readAuthorizationSql, [accessA, now]),
    (error) => error?.code === '42501',
  );

  console.log(
    'INTEGRATION_0007_READ_EXPORT_SUMMARY default_off_controls=5 enabled_controls=6 '
      + 'tenant_derivation_controls=15 subscription_controls=4 audit_export_controls=8 '
      + 'lane_acl_controls=9 pool_leak_controls=2 status=pass',
  );
} finally {
  if (apiPool) await apiPool.end();
  if (authorizerPool) await authorizerPool.end();
  if (auditPool) await auditPool.end();
  if (challengePool) await challengePool.end();
  await bootstrapPool.end();
  const cleanup = await cluster.stop();
  console.log(`PG_CLEANUP ${JSON.stringify(cleanup)}`);
}
