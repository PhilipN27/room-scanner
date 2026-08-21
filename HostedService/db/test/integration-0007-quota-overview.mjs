import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { appPoolConfig, hash32, ids, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const cluster = await startPostgresCluster();
const bootstrapPool = new Pool(cluster.bootstrapConfig);
let apiPool;
let nonApiPool;
const now = new Date('2026-08-19T18:00:00.000Z');
const lifetime = 'roomscan-period-v1:lifetime';

async function withOperator(work) {
  await bootstrapPool.query('SET ROLE roomscan_operator');
  try {
    return await work();
  } finally {
    await bootstrapPool.query('RESET ROLE');
  }
}

async function setFlag(scope, workspaceId, enabled, expectedVersion, auditId) {
  return withOperator(async () => (await bootstrapPool.query(
    `SELECT * FROM roomscan.set_operational_flag(
       $1, $2::uuid, 'hosted_operations_enabled', $3, $4,
       'quota overview integration', $5, $6
     )`,
    [scope, workspaceId, enabled, expectedVersion, auditId, now],
  )).rows[0]);
}

async function activatePolicy(workspaceId, portalPeriod, version, limits) {
  return withOperator(async () => bootstrapPool.query(
    `SELECT * FROM roomscan.activate_quota_policy_v2(
       $1, $2, 'roomscan-quota-policy-v1', 'test-only', $3,
       $4, $5, $6, $7, $8, 80, 1, 1, $9
     )`,
    [workspaceId, version, portalPeriod, ...limits, now],
  ));
}

async function insertAccess({ principalId, workspaceId, role, label, familySuffix }) {
  const membership = (await bootstrapPool.query(
    `SELECT authorization_version FROM roomscan.memberships
      WHERE principal_id = $1 AND workspace_id = $2`,
    [principalId, workspaceId],
  )).rows[0];
  const familyId = `68000000-0000-4000-8000-${familySuffix}`;
  const digest = hash32(`quota-overview-${label}`);
  await bootstrapPool.query(
    `INSERT INTO roomscan.auth_session_families (
       id, public_id, principal_id, authentication_epoch, authenticated_at,
       last_used_at, inactivity_expires_at, absolute_expires_at,
       policy_version, workspace_id, role, authorization_version,
       state, created_at
     ) VALUES ($1, $2, $3, 0, $4, $4, $4::timestamptz + interval '1 day',
       $4::timestamptz + interval '7 days', 'session-v1', $5, $6, $7,
       'active', $4)`,
    [familyId, `fam_quota_overview_${label}`, principalId, now, workspaceId, role,
      membership.authorization_version],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.auth_access_tokens (
       id, family_id, token_hash, expires_at, principal_id,
       authentication_epoch, authenticated_at, issued_at, workspace_id,
       role, authorization_version, state, created_at
     ) VALUES (gen_random_uuid(), $1, $2, $3::timestamptz + interval '1 hour',
       $4, 0, $3, $3, $5, $6, $7, 'active', $3)`,
    [familyId, digest, now, principalId, workspaceId, role, membership.authorization_version],
  );
  return digest;
}

async function overview(accessHash) {
  return (await apiPool.query(
    'SELECT * FROM roomscan.read_quota_overview_v2($1::bytea, $2::timestamptz)',
    [accessHash, now],
  )).rows;
}

function assertWorkspaceOverview(rows, workspaceId, portalPeriod, expectedUsedBase) {
  assert.equal(rows.length, 5);
  assert.deepEqual(rows.map(({ metric }) => metric), [
    'project_count', 'member_count', 'working_bytes', 'raw_bytes', 'portal_bytes',
  ]);
  assert.equal(rows.every(({ workspace_id }) => workspace_id === workspaceId), true);
  assert.deepEqual(rows.map(({ period_key }) => period_key), [
    lifetime, lifetime, lifetime, lifetime, portalPeriod,
  ]);
  assert.deepEqual(rows.map(({ used }) => Number(used)), [
    expectedUsedBase, expectedUsedBase + 1, expectedUsedBase + 2,
    expectedUsedBase + 3, expectedUsedBase + 4,
  ]);
  assert.equal(rows.every(({ policy_version }) => policy_version === '1'), true);
  assert.equal(rows.every(({ warning_threshold_percent }) => warning_threshold_percent === 80), true);
}

try {
  await applyMigrations({ pool: bootstrapPool });
  await seedCoreFixtures(bootstrapPool);

  await setFlag('global', null, true, null, 'ofaud_overview_global_on');
  await setFlag('workspace', ids.workspaceA, true, null, 'ofaud_overview_a_on');
  await setFlag('workspace', ids.workspaceB, true, null, 'ofaud_overview_b_on');
  const portalA = 'roomscan-period-v1:portal-a';
  const portalB = 'roomscan-period-v1:portal-b';
  await activatePolicy(ids.workspaceA, portalA, 1, [10, 11, 12, 13, 14]);
  await activatePolicy(ids.workspaceB, portalB, 1, [20, 21, 22, 23, 24]);

  for (const [workspaceId, base] of [[ids.workspaceA, 100], [ids.workspaceB, 200]]) {
    await bootstrapPool.query(
      `UPDATE roomscan.quota_usage_v2 AS usage
          SET used = values.used, reserved = values.reserved
         FROM (VALUES
           ('project_count'::roomscan.quota_metric, $2::bigint, 1::bigint),
           ('member_count'::roomscan.quota_metric, ($2 + 1)::bigint, 0::bigint),
           ('working_bytes'::roomscan.quota_metric, ($2 + 2)::bigint, 2::bigint),
           ('raw_bytes'::roomscan.quota_metric, ($2 + 3)::bigint, 3::bigint),
           ('portal_bytes'::roomscan.quota_metric, ($2 + 4)::bigint, 4::bigint)
         ) AS values(metric, used, reserved)
       WHERE usage.workspace_id = $1 AND usage.metric = values.metric`,
      [workspaceId, base],
    );
  }

  const accessA = await insertAccess({
    principalId: ids.principalA, workspaceId: ids.workspaceA, role: 'owner',
    label: 'owner_a', familySuffix: '000000000101',
  });
  const accessB = await insertAccess({
    principalId: ids.principalB, workspaceId: ids.workspaceB, role: 'owner',
    label: 'owner_b', familySuffix: '000000000102',
  });
  const accessMember = await insertAccess({
    principalId: ids.principalMember, workspaceId: ids.workspaceA, role: 'editor',
    label: 'member_a', familySuffix: '000000000103',
  });

  apiPool = new Pool({
    ...appPoolConfig(cluster, 1), user: 'roomscan_api_runtime', max: 1,
    application_name: 'rss-0007-quota-overview',
  });

  assertWorkspaceOverview(await overview(accessA), ids.workspaceA, portalA, 100);
  assertWorkspaceOverview(await overview(accessB), ids.workspaceB, portalB, 200);
  assertWorkspaceOverview(await overview(accessMember), ids.workspaceA, portalA, 100);

  // Caller-supplied session GUCs cannot substitute workspace B for token A.
  const forged = await apiPool.connect();
  try {
    await forged.query('BEGIN');
    await forged.query(
      `SELECT set_config('app.principal_id', $1, true),
              set_config('app.tenant_id', $2, true),
              set_config('app.authorization_version', '1', true)`,
      [ids.principalB, ids.workspaceB],
    );
    const rows = (await forged.query(
      'SELECT * FROM roomscan.read_quota_overview_v2($1, $2)', [accessA, now],
    )).rows;
    assertWorkspaceOverview(rows, ids.workspaceA, portalA, 100);
    await forged.query('COMMIT');
  } finally {
    forged.release();
  }

  // A/B/unknown reuse on one pooled connection cannot retain prior scope.
  assertWorkspaceOverview(await overview(accessB), ids.workspaceB, portalB, 200);
  assert.equal((await overview(hash32('quota-overview-unknown'))).length, 0);
  const settings = (await apiPool.query(
    `SELECT NULLIF(current_setting('app.principal_id', true), '') AS principal,
            NULLIF(current_setting('app.tenant_id', true), '') AS tenant,
            NULLIF(current_setting('app.authorization_version', true), '') AS version`,
  )).rows[0];
  assert.deepEqual(settings, { principal: null, tenant: null, version: null });
  assertWorkspaceOverview(await overview(accessA), ids.workspaceA, portalA, 100);

  // Stale cached role and removed membership invalidate the member session.
  await bootstrapPool.query(
    `UPDATE roomscan.memberships SET role = 'viewer'
      WHERE workspace_id = $1 AND principal_id = $2`,
    [ids.workspaceA, ids.principalMember],
  );
  assert.equal((await overview(accessMember)).length, 0);
  await bootstrapPool.query(
    `UPDATE roomscan.memberships SET role = 'editor'
      WHERE workspace_id = $1 AND principal_id = $2`,
    [ids.workspaceA, ids.principalMember],
  );
  const refreshedMember = await insertAccess({
    principalId: ids.principalMember, workspaceId: ids.workspaceA, role: 'editor',
    label: 'member_a_refreshed', familySuffix: '000000000104',
  });
  assertWorkspaceOverview(await overview(refreshedMember), ids.workspaceA, portalA, 100);
  await bootstrapPool.query(
    `UPDATE roomscan.memberships SET state = 'removed'
      WHERE workspace_id = $1 AND principal_id = $2`,
    [ids.workspaceA, ids.principalMember],
  );
  assert.equal((await overview(refreshedMember)).length, 0);

  // Workspace and global hosted switches deny reads fail closed.
  await setFlag('workspace', ids.workspaceA, false, 1, 'ofaud_overview_a_off');
  assert.equal((await overview(accessA)).length, 0);
  await setFlag('workspace', ids.workspaceA, true, 2, 'ofaud_overview_a_reon');
  assertWorkspaceOverview(await overview(accessA), ids.workspaceA, portalA, 100);
  await setFlag('global', null, false, 1, 'ofaud_overview_global_off');
  assert.equal((await overview(accessA)).length, 0);
  assert.equal((await overview(accessB)).length, 0);
  await setFlag('global', null, true, 2, 'ofaud_overview_global_reon');

  // Missing one of five authoritative rows is an error, never a partial view.
  await bootstrapPool.query(
    `DELETE FROM roomscan.quota_usage_v2
      WHERE workspace_id = $1 AND metric = 'working_bytes'`,
    [ids.workspaceB],
  );
  await assert.rejects(
    () => overview(accessB),
    (error) => error?.code === 'P0001' && error?.message === 'QUOTA_OVERVIEW_INCOMPLETE',
  );

  const durableBeforeInvalid = (await bootstrapPool.query(
    'SELECT count(*)::integer AS count FROM roomscan.quota_usage_v2',
  )).rows[0].count;
  for (const [hash, time] of [[null, now], [Buffer.alloc(31), now], [accessA, null]]) {
    await assert.rejects(
      () => apiPool.query(
        'SELECT * FROM roomscan.read_quota_overview_v2($1::bytea, $2::timestamptz)',
        [hash, time],
      ),
      (error) => error?.code === '22023' && error?.message === 'INVALID_QUOTA_OVERVIEW_INPUT',
    );
  }
  assert.equal((await bootstrapPool.query(
    'SELECT count(*)::integer AS count FROM roomscan.quota_usage_v2',
  )).rows[0].count, durableBeforeInvalid);

  const routine = (await bootstrapPool.query(
    `SELECT owner.rolname AS owner, procedure.prosecdef, procedure.provolatile,
            procedure.proconfig, pg_get_function_arguments(procedure.oid) AS arguments,
            pg_get_function_result(procedure.oid) AS result,
            obj_description(procedure.oid, 'pg_proc') AS review,
            has_function_privilege('public', procedure.oid, 'EXECUTE') AS public_execute
       FROM pg_proc AS procedure
       JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
       JOIN pg_roles AS owner ON owner.oid = procedure.proowner
      WHERE namespace.nspname = 'roomscan'
        AND procedure.proname = 'read_quota_overview_v2'`,
  )).rows[0];
  assert.deepEqual(routine, {
    owner: 'roomscan_policy',
    prosecdef: true,
    provolatile: 'v',
    proconfig: ['search_path=pg_catalog, pg_temp'],
    arguments: 'access_token_hash bytea, authoritative_time timestamp with time zone',
    result: 'SETOF roomscan.quota_usage_v2',
    review: 'API-only access-digest-derived current workspace quota overview; transaction-local server context, literal-true hosted flags, four lifetime metrics and active-policy portal period; exactly five rows or fail closed; fixed search_path; PUBLIC revoked.',
    public_execute: false,
  });
  for (const [role, allowed] of [
    ['roomscan_api_runtime', true],
    ['roomscan_authorizer_runtime', false],
    ['roomscan_auth_challenge_runtime', false],
    ['roomscan_stripe_ingress_runtime', false],
    ['roomscan_stripe_reconciliation_runtime', false],
    ['roomscan_audit_export_runtime', false],
    ['roomscan_email_delivery_runtime', false],
    ['roomscan_app', false],
    ['roomscan_operator', false],
  ]) {
    assert.equal((await bootstrapPool.query(
      `SELECT has_function_privilege(
         $1, 'roomscan.read_quota_overview_v2(bytea,timestamp with time zone)', 'EXECUTE'
       ) AS allowed`,
      [role],
    )).rows[0].allowed, allowed, role);
  }

  nonApiPool = new Pool({
    ...appPoolConfig(cluster, 1), user: 'roomscan_authorizer_runtime', max: 1,
  });
  await assert.rejects(
    () => nonApiPool.query(
      'SELECT * FROM roomscan.read_quota_overview_v2($1, $2)', [accessA, now],
    ),
    (error) => error?.code === '42501',
  );
  await assert.rejects(
    () => apiPool.query(
      'SELECT * FROM roomscan.read_quota_overview_v2($1, $2, $3)',
      [accessA, now, ids.workspaceB],
    ),
    (error) => error?.code === '42883',
  );

  console.log(
    'INTEGRATION_0007_QUOTA_OVERVIEW_SUMMARY same_tenant_controls=3 '
      + 'cross_tenant_controls=7 pool_leak_controls=7 stale_removed_controls=4 '
      + 'flag_controls=6 exact_metric_controls=15 incomplete_controls=1 '
      + 'null_controls=4 catalog_controls=16 lane_acl_controls=9 durable_changes=0 status=pass',
  );
} finally {
  if (nonApiPool) await nonApiPool.end();
  if (apiPool) await apiPool.end();
  await bootstrapPool.end();
  const cleanup = await cluster.stop();
  console.log(`PG_CLEANUP ${JSON.stringify(cleanup)}`);
}
