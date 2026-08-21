import assert from 'node:assert/strict';
import { appendFile, cp, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { accepted0006MigrationsDir } from './accepted-0006-migrations.mjs';
import {
  TenantContextError,
  withPrincipalTransaction,
  withTenantTransaction,
} from '../runtime.mjs';
import { appPoolConfig, hash32, ids, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const migrationsDir = accepted0006MigrationsDir;
const tenantTables = [
  ['workspaces', 'id'],
  ['memberships', 'workspace_id'],
  ['invitations', 'workspace_id'],
  ['projects', 'workspace_id'],
  ['subscription_states', 'workspace_id'],
  ['quota_policy_versions', 'workspace_id'],
  ['quota_usage', 'workspace_id'],
  ['quota_reservations', 'workspace_id'],
  ['quota_ledger', 'workspace_id'],
  ['audit_states', 'workspace_id'],
  ['audit_events', 'workspace_id'],
  ['operational_flags', 'workspace_id'],
  ['stripe_event_receipts', 'workspace_id'],
  ['stripe_reconciliation_generations', 'workspace_id'],
];
const directlyMutableTables = new Set(['projects']);
const securityDefinerAllowlist = [
  'activate_quota_policy',
  'apply_stripe_reconciliation',
  'bootstrap_workspace',
  'bump_principal_authentication_epoch',
  'cancel_magic_delivery',
  'claim_apple_attempt_and_code',
  'claim_apple_bridge_proof',
  'claim_apple_nonce',
  'claim_candidate_identity_proof',
  'claim_external_identity',
  'claim_magic_delivery',
  'claim_magic_link',
  'claim_refresh_rotation',
  'claim_security_notification',
  'claim_verified_auth_receipt',
  'complete_magic_delivery',
  'complete_security_notification',
  'consume_invitation',
  'finalize_quota',
  'has_authorized_tenant',
  'record_stripe_event',
  'release_external_identity',
  'release_magic_delivery',
  'release_quota',
  'release_security_notification',
  'reserve_quota',
  'resolve_access_context',
  'revoke_access_token',
  'revoke_principal_session_families',
  'revoke_session_family',
  'supersede_magic_link',
  'supersede_magic_link_siblings',
  'update_session_family_activity',
  'validate_magic_delivery',
];
const exactAppRoutineAcl = [
  'roomscan.activate_quota_policy(bigint,bigint,bigint,bigint,bigint,bigint,integer)',
  'roomscan.apply_stripe_reconciliation(bigint,timestamp with time zone,text,text,timestamp with time zone)',
  'roomscan.bootstrap_workspace(text,text)',
  'roomscan.bump_principal_authentication_epoch(uuid)',
  'roomscan.cancel_magic_delivery(text,text,text,timestamp with time zone)',
  'roomscan.claim_apple_attempt_and_code(text,bytea,text,bytea,timestamp with time zone)',
  'roomscan.claim_apple_bridge_proof(bytea,text,text,text,text,timestamp with time zone)',
  'roomscan.claim_apple_nonce(bytea,timestamp with time zone)',
  'roomscan.claim_candidate_identity_proof(bytea,text,uuid,uuid,timestamp with time zone)',
  'roomscan.claim_external_identity(text,text,uuid,timestamp with time zone)',
  'roomscan.claim_magic_delivery(text,text,timestamp with time zone,timestamp with time zone)',
  'roomscan.claim_magic_link(text,bytea,text,timestamp with time zone)',
  'roomscan.claim_refresh_rotation(bytea,bytea,timestamp with time zone)',
  'roomscan.claim_security_notification(text,text,timestamp with time zone,timestamp with time zone)',
  'roomscan.claim_verified_auth_receipt(bytea,text,text,uuid,uuid,timestamp with time zone)',
  'roomscan.complete_magic_delivery(text,text,timestamp with time zone)',
  'roomscan.complete_security_notification(text,text,timestamp with time zone)',
  'roomscan.consume_invitation(bytea)',
  'roomscan.finalize_quota(text,bigint)',
  'roomscan.has_authorized_tenant(uuid)',
  'roomscan.lock_magic_policy_scope(text,bytea)',
  'roomscan.record_stripe_event(text,text,bytea,boolean,timestamp with time zone)',
  'roomscan.release_external_identity(text,text,uuid)',
  'roomscan.release_magic_delivery(text,text,timestamp with time zone)',
  'roomscan.release_quota(text)',
  'roomscan.release_security_notification(text,text)',
  'roomscan.request_principal_id()',
  'roomscan.reserve_quota(roomscan.quota_metric,bigint,text)',
  'roomscan.resolve_access_context(bytea,timestamp with time zone)',
  'roomscan.revoke_access_token(bytea,timestamp with time zone)',
  'roomscan.revoke_principal_session_families(uuid,uuid,timestamp with time zone,text)',
  'roomscan.revoke_session_family(uuid,timestamp with time zone,text)',
  'roomscan.supersede_magic_link(text,timestamp with time zone)',
  'roomscan.supersede_magic_link_siblings(text,timestamp with time zone)',
  'roomscan.update_session_family_activity(uuid,timestamp with time zone,timestamp with time zone)',
  'roomscan.validate_magic_delivery(text,text,timestamp with time zone)',
];

const contextA = {
  principalId: ids.principalA,
  requestedWorkspaceId: ids.workspaceA,
  expectedAuthorizationVersion: 1,
};
const contextB = {
  principalId: ids.principalB,
  requestedWorkspaceId: ids.workspaceB,
  expectedAuthorizationVersion: 1,
};

const tests = [];
function test(name, operation) {
  tests.push({ name, operation });
}

async function seedBoundaryFixtures(pool) {
  await pool.query(
    `INSERT INTO roomscan.quota_policy_versions (
       workspace_id, version, project_limit, member_limit, working_byte_limit,
       raw_byte_limit, portal_byte_limit, warning_threshold_percent, is_active
     ) VALUES
       ($1, 900, 100, 100, 100, 100, 100, 80, true),
       ($2, 900, 100, 100, 100, 100, 100, 80, true)`,
    [ids.workspaceA, ids.workspaceB],
  );
  await pool.query(
    `INSERT INTO roomscan.quota_usage (
       workspace_id, metric, policy_version, used, reserved, limit_value, warning_threshold_percent
     ) VALUES
       ($1, 'project_count', 900, 0, 1, 100, 80),
       ($2, 'project_count', 900, 0, 1, 100, 80)`,
    [ids.workspaceA, ids.workspaceB],
  );
  await pool.query(
    `INSERT INTO roomscan.quota_reservations (
       workspace_id, idempotency_key, metric, requested_amount, state, policy_version
     ) VALUES
       ($1, 'fixture-a', 'project_count', 1, 'reserved', 900),
       ($2, 'fixture-b', 'project_count', 1, 'reserved', 900)`,
    [ids.workspaceA, ids.workspaceB],
  );
  await pool.query(
    `INSERT INTO roomscan.quota_ledger (
       workspace_id, idempotency_key, action, metric, delta_used, delta_reserved, policy_version
     ) VALUES
       ($1, 'fixture-a', 'reserve', 'project_count', 0, 1, 900),
       ($2, 'fixture-b', 'reserve', 'project_count', 0, 1, 900)`,
    [ids.workspaceA, ids.workspaceB],
  );
  await pool.query(
    `INSERT INTO roomscan.stripe_event_receipts (
       workspace_id, provider_account_id, event_id, payload_sha256, signature_verified, provider_occurred_at
     ) VALUES
       ($1, 'acct_fixture_a', 'evt_fixture_a', $3, true, '2026-08-18T10:00:00Z'),
       ($2, 'acct_fixture_b', 'evt_fixture_b', $4, true, '2026-08-18T10:00:00Z')`,
    [ids.workspaceA, ids.workspaceB, hash32('stripe-a'), hash32('stripe-b')],
  );
  await pool.query(
    `INSERT INTO roomscan.stripe_reconciliation_generations (
       workspace_id, generation, source_observed_at, subscription_status, plan_key, applied
     ) VALUES
       ($1, 900, '2026-08-18T10:00:00Z', 'active', 'fixture', false),
       ($2, 900, '2026-08-18T10:00:00Z', 'active', 'fixture', false)`,
    [ids.workspaceA, ids.workspaceB],
  );
}

async function inTenant(pool, context, operation) {
  return await withTenantTransaction(pool, context, operation);
}

async function readContext(client) {
  return (await client.query(
    `SELECT
       NULLIF(current_setting('app.principal_id', true), '') AS principal_id,
       NULLIF(current_setting('app.tenant_id', true), '') AS tenant_id,
       NULLIF(current_setting('app.authorization_version', true), '') AS authorization_version`,
  )).rows[0];
}

async function assertNoContext(client) {
  assert.deepEqual(await readContext(client), {
    principal_id: null,
    tenant_id: null,
    authorization_version: null,
  });
}

test('forward migrations are idempotent and checksum-locked', async ({ bootstrapPool }) => {
  const second = await applyMigrations({ pool: bootstrapPool, migrationsDir });
  assert.equal(second.applied.length, 0);
  assert.equal(second.skipped.length, 6);

  const orderRoot = await mkdtemp(path.join(tmpdir(), 'rss-migration-order-'));
  const orderDir = path.join(orderRoot, 'migrations');
  try {
    await cp(migrationsDir, orderDir, { recursive: true });
    await writeFile(path.join(orderDir, '0000_late_backfill.up.sql'), 'SELECT 1;\n');
    await assert.rejects(
      () => applyMigrations({ pool: bootstrapPool, migrationsDir: orderDir }),
      (error) => error?.code === 'MIGRATION_ORDER_VIOLATION',
    );
  } finally {
    await rm(orderRoot, { recursive: true, force: true });
  }

  const copyRoot = await mkdtemp(path.join(tmpdir(), 'rss-migration-copy-'));
  const copyDir = path.join(copyRoot, 'migrations');
  try {
    await cp(migrationsDir, copyDir, { recursive: true });
    await appendFile(path.join(copyDir, '0001_roles_and_global.up.sql'), '\n-- checksum mutation\n');
    await assert.rejects(
      () => applyMigrations({ pool: bootstrapPool, migrationsDir: copyDir }),
      (error) => error?.code === 'MIGRATION_CHECKSUM_MISMATCH',
    );
  } finally {
    await rm(copyRoot, { recursive: true, force: true });
  }
});

test('catalog proves role separation, ownership, forced RLS, policies, and grants', async ({ bootstrapPool, evidence }) => {
  const roleRows = (await bootstrapPool.query(
    `SELECT rolname, rolcanlogin, rolsuper, rolbypassrls, rolinherit
     FROM pg_roles
     WHERE rolname IN ('roomscan_owner', 'roomscan_policy', 'roomscan_app')
     ORDER BY rolname`,
  )).rows;
  assert.deepEqual(roleRows, [
    { rolname: 'roomscan_app', rolcanlogin: true, rolsuper: false, rolbypassrls: false, rolinherit: false },
    { rolname: 'roomscan_owner', rolcanlogin: false, rolsuper: false, rolbypassrls: false, rolinherit: false },
    { rolname: 'roomscan_policy', rolcanlogin: false, rolsuper: false, rolbypassrls: true, rolinherit: false },
  ]);

  const membership = (await bootstrapPool.query(
    `SELECT
       pg_has_role('roomscan_app', 'roomscan_owner', 'member') AS app_is_owner_member,
       pg_has_role('roomscan_app', 'roomscan_policy', 'member') AS app_is_policy_member,
       pg_has_role('roomscan_app', 'roomscan_owner', 'set') AS app_can_set_owner,
       pg_has_role('roomscan_app', 'roomscan_policy', 'set') AS app_can_set_policy`,
  )).rows[0];
  assert.deepEqual(membership, {
    app_is_owner_member: false,
    app_is_policy_member: false,
    app_can_set_owner: false,
    app_can_set_policy: false,
  });
  const reservedMembershipEdges = (await bootstrapPool.query(
    `SELECT member.rolname AS member, granted.rolname AS granted
     FROM pg_auth_members AS edge
     JOIN pg_roles AS member ON member.oid=edge.member
     JOIN pg_roles AS granted ON granted.oid=edge.roleid
     WHERE member.rolname=ANY($1::text[]) OR granted.rolname=ANY($1::text[])
     ORDER BY member.rolname, granted.rolname`,
    [['roomscan_app', 'roomscan_owner', 'roomscan_policy']],
  )).rows;
  assert.deepEqual(reservedMembershipEdges, []);

  const catalogRows = (await bootstrapPool.query(
    `SELECT c.relname, owner.rolname AS owner, c.relrowsecurity, c.relforcerowsecurity
     FROM pg_class AS c
     JOIN pg_namespace AS n ON n.oid = c.relnamespace
     JOIN pg_roles AS owner ON owner.oid = c.relowner
     WHERE n.nspname = 'roomscan'
       AND c.relkind = 'r'
       AND c.relname = ANY($1::text[])
     ORDER BY c.relname`,
    [tenantTables.map(([table]) => table)],
  )).rows;
  assert.equal(catalogRows.length, tenantTables.length);
  for (const row of catalogRows) {
    assert.equal(row.owner, 'roomscan_owner');
    assert.equal(row.relrowsecurity, true);
    assert.equal(row.relforcerowsecurity, true);
  }

  const policyRows = (await bootstrapPool.query(
    `SELECT tablename, policyname, cmd, roles, qual, with_check
     FROM pg_policies
     WHERE schemaname = 'roomscan'
     ORDER BY tablename, policyname`,
  )).rows;
  for (const [table] of tenantTables) {
    assert.ok(
      policyRows.some((row) => row.tablename === table && row.qual && row.with_check),
      `${table} lacks an explicit USING/WITH CHECK policy`,
    );
  }
  const expectedPolicyRows = tenantTables.map(([tablename, tenantColumn]) => ({
    tablename,
    policyname: tablename === 'memberships' ? 'memberships_tenant_write' : `${tablename}_tenant_isolation`,
    cmd: 'ALL',
    roles: '{public}',
    qual: `roomscan.has_authorized_tenant(${tenantColumn})`,
    with_check: `roomscan.has_authorized_tenant(${tenantColumn})`,
  }));
  expectedPolicyRows.splice(expectedPolicyRows.findIndex(({ tablename }) => tablename === 'memberships') + 1, 0, {
    tablename: 'memberships',
    policyname: 'memberships_self_list',
    cmd: 'SELECT',
    roles: '{public}',
    qual: "((principal_id = roomscan.request_principal_id()) AND (state = 'active'::text))",
    with_check: null,
  });
  expectedPolicyRows.sort((a, b) => a.tablename.localeCompare(b.tablename) || a.policyname.localeCompare(b.policyname));
  assert.deepEqual(policyRows, expectedPolicyRows);

  const appOwnedObjects = (await bootstrapPool.query(
    `SELECT count(*)::int AS count
     FROM pg_class AS c
     JOIN pg_roles AS owner ON owner.oid = c.relowner
     JOIN pg_namespace AS n ON n.oid = c.relnamespace
     WHERE n.nspname = 'roomscan' AND owner.rolname = 'roomscan_app'`,
  )).rows[0].count;
  assert.equal(appOwnedObjects, 0);

  const publicGrants = (await bootstrapPool.query(
    `SELECT count(*)::int AS count
     FROM information_schema.role_table_grants
     WHERE table_schema = 'roomscan' AND grantee = 'PUBLIC'`,
  )).rows[0].count;
  assert.equal(publicGrants, 0);
  assert.equal(
    (await bootstrapPool.query(
      `SELECT has_table_privilege('roomscan_app', 'public.roomscan_schema_migrations', 'SELECT') AS allowed`,
    )).rows[0].allowed,
    false,
  );

  const appTableAcl = (await bootstrapPool.query(
    `SELECT relation_name,
       has_table_privilege('roomscan_app', 'roomscan.'||relation_name, 'SELECT') AS can_select,
       has_table_privilege('roomscan_app', 'roomscan.'||relation_name, 'INSERT') AS can_insert,
       has_table_privilege('roomscan_app', 'roomscan.'||relation_name, 'UPDATE') AS can_update,
       has_table_privilege('roomscan_app', 'roomscan.'||relation_name, 'DELETE') AS can_delete,
       has_table_privilege('roomscan_app', 'roomscan.'||relation_name, 'TRUNCATE') AS can_truncate
     FROM unnest($1::text[]) AS relation_name ORDER BY relation_name`,
    [tenantTables.map(([table]) => table)],
  )).rows;
  assert.deepEqual(appTableAcl, tenantTables.map(([relation_name]) => ({
    relation_name,
    can_select: true,
    can_insert: directlyMutableTables.has(relation_name),
    can_update: directlyMutableTables.has(relation_name),
    can_delete: directlyMutableTables.has(relation_name),
    can_truncate: false,
  })).sort((a, b) => a.relation_name.localeCompare(b.relation_name)));
  const explicitColumnAcls = (await bootstrapPool.query(
    `SELECT c.relname, a.attname, a.attacl::text
     FROM pg_attribute AS a JOIN pg_class AS c ON c.oid=a.attrelid
     JOIN pg_namespace AS n ON n.oid=c.relnamespace
     WHERE n.nspname='roomscan' AND c.relkind='r' AND a.attnum>0
       AND a.attacl IS NOT NULL AND c.relname = ANY($1::text[])
     ORDER BY c.relname, a.attname`,
    [tenantTables.map(([table]) => table)],
  )).rows;
  assert.deepEqual(explicitColumnAcls, []);

  const durableGrantRows = (await bootstrapPool.query(
    `SELECT relation_name,
            has_table_privilege('roomscan_app', 'roomscan.' || relation_name, 'DELETE') AS can_delete,
            has_table_privilege('roomscan_app', 'roomscan.' || relation_name, 'TRUNCATE') AS can_truncate
     FROM unnest(ARRAY[
       'audit_events',
       'quota_ledger',
       'stripe_event_receipts',
       'stripe_reconciliation_generations'
     ]) AS relation_name
     ORDER BY relation_name`,
  )).rows;
  assert.ok(durableGrantRows.every((row) => !row.can_delete && !row.can_truncate));
  assert.equal(
    (await bootstrapPool.query(
      `SELECT has_table_privilege('roomscan_app', 'roomscan.audit_events', 'UPDATE') AS allowed`,
    )).rows[0].allowed,
    false,
  );

  const definers = (await bootstrapPool.query(
    `SELECT p.proname, owner.rolname AS owner, p.prosecdef, p.proconfig,
            obj_description(p.oid, 'pg_proc') AS review,
            p.prosrc ~* '\\mEXECUTE\\M' AS has_dynamic_sql
     FROM pg_proc AS p
     JOIN pg_namespace AS n ON n.oid = p.pronamespace
     JOIN pg_roles AS owner ON owner.oid = p.proowner
     WHERE n.nspname = 'roomscan' AND p.prosecdef
     ORDER BY p.proname`,
  )).rows;
  assert.deepEqual(definers.map(({ proname }) => proname), securityDefinerAllowlist);
  for (const reviewedFunction of definers) {
    assert.equal(reviewedFunction.owner, 'roomscan_policy');
    assert.deepEqual(reviewedFunction.proconfig, ['search_path=pg_catalog, pg_temp']);
    assert.match(reviewedFunction.review, /Reviewed SECURITY DEFINER/u);
    assert.equal(reviewedFunction.has_dynamic_sql, false);
  }

  const routineAcl = (await bootstrapPool.query(
    `SELECT p.oid::regprocedure::text AS routine, owner.rolname AS owner,
       p.prosecdef, p.proconfig, obj_description(p.oid, 'pg_proc') AS review,
       has_function_privilege('roomscan_app', p.oid, 'EXECUTE') AS app_execute,
       COALESCE((SELECT bool_or(acl.grantee=0 AND acl.privilege_type='EXECUTE')
         FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) AS acl), false) AS public_execute
     FROM pg_proc AS p JOIN pg_namespace AS n ON n.oid=p.pronamespace
     JOIN pg_roles AS owner ON owner.oid=p.proowner
     WHERE n.nspname='roomscan' ORDER BY routine`,
  )).rows;
  assert.deepEqual(
    routineAcl.filter(({ app_execute }) => app_execute).map(({ routine }) => routine),
    exactAppRoutineAcl,
  );
  assert.ok(routineAcl.every(({ public_execute }) => !public_execute));
  for (const routine of routineAcl) {
    assert.deepEqual(routine.proconfig, ['search_path=pg_catalog, pg_temp']);
    assert.equal(routine.owner, routine.prosecdef ? 'roomscan_policy' : 'roomscan_owner');
    assert.match(routine.review, /^(Reviewed|Bounded|Internal)/u);
  }

  const policyRoleAcl = (await bootstrapPool.query(
    `SELECT table_name, privilege_type
     FROM information_schema.role_table_grants
     WHERE table_schema='roomscan' AND grantee='roomscan_policy'
     ORDER BY table_name, privilege_type`,
  )).rows;
  const exactPolicyAcl = {
    apple_auth_attempts: ['SELECT', 'UPDATE'],
    apple_bridge_proofs: ['SELECT', 'UPDATE'],
    apple_code_receipts: ['DELETE', 'INSERT', 'SELECT'],
    apple_nonce_receipts: ['INSERT', 'SELECT'],
    audit_events: ['INSERT'], audit_states: ['INSERT'], invitations: ['SELECT', 'UPDATE'],
    auth_access_tokens: ['SELECT', 'UPDATE'],
    auth_refresh_tokens: ['SELECT', 'UPDATE'],
    auth_session_families: ['SELECT', 'UPDATE'],
    candidate_identity_proofs: ['SELECT', 'UPDATE'],
    external_identities: ['DELETE', 'INSERT', 'SELECT'],
    magic_link_delivery_outbox: ['SELECT', 'UPDATE'],
    magic_links: ['SELECT', 'UPDATE'],
    memberships: ['INSERT', 'SELECT', 'UPDATE'], principals: ['SELECT', 'UPDATE'],
    quota_ledger: ['INSERT'], quota_policy_versions: ['INSERT', 'SELECT', 'UPDATE'],
    quota_reservations: ['INSERT', 'SELECT', 'UPDATE'], quota_usage: ['INSERT', 'SELECT', 'UPDATE'],
    security_notification_outbox: ['SELECT', 'UPDATE'],
    stripe_event_receipts: ['INSERT', 'SELECT'],
    stripe_reconciliation_generations: ['INSERT', 'SELECT', 'UPDATE'],
    subscription_states: ['INSERT', 'SELECT', 'UPDATE'],
    verified_authentication_receipts: ['SELECT', 'UPDATE'],
    workspaces: ['INSERT', 'SELECT', 'UPDATE'],
  };
  assert.deepEqual(policyRoleAcl, Object.entries(exactPolicyAcl).flatMap(
    ([table_name, privileges]) => privileges.map((privilege_type) => ({ table_name, privilege_type })),
  ).sort((a, b) => a.table_name.localeCompare(b.table_name)
    || a.privilege_type.localeCompare(b.privilege_type)));

  evidence.catalog = {
    roleRows,
    membership,
    catalogRows,
    policyRows,
    definers,
    publicGrants,
    durableGrantRows,
    appTableAcl,
    routineAcl,
    policyRoleAcl,
    reservedMembershipEdges,
    explicitColumnAcls,
  };
});

for (const [table, tenantColumn] of tenantTables) {
  test(`${table}: same-tenant SELECT control and cross-tenant SELECT denial`, async ({ appPool }) => {
    const result = await inTenant(appPool, contextA, async (client) => {
      const same = (await client.query(
        `SELECT count(*)::int AS count FROM roomscan.${table} WHERE ${tenantColumn} = $1`,
        [ids.workspaceA],
      )).rows[0].count;
      const cross = (await client.query(
        `SELECT count(*)::int AS count FROM roomscan.${table} WHERE ${tenantColumn} = $1`,
        [ids.workspaceB],
      )).rows[0].count;
      return { same, cross };
    });
    assert.ok(result.same > 0, `${table} positive control did not reach a same-tenant row`);
    assert.equal(result.cross, 0);
  });
}

for (const [table, tenantColumn] of tenantTables.filter(([name]) => !directlyMutableTables.has(name))) {
  test(`${table}: direct INSERT/UPDATE/DELETE/TRUNCATE are denied for same and cross tenant`, async ({ appPool }) => {
    for (const candidateWorkspace of [ids.workspaceA, ids.workspaceB]) {
      const statements = [
        `INSERT INTO roomscan.${table} (${tenantColumn}) VALUES ($1)`,
        `UPDATE roomscan.${table} SET ${tenantColumn}=${tenantColumn} WHERE ${tenantColumn}=$1`,
        `DELETE FROM roomscan.${table} WHERE ${tenantColumn}=$1`,
        `TRUNCATE roomscan.${table}`,
      ];
      for (const statement of statements) {
        await assert.rejects(
          () => inTenant(appPool, contextA, (client) => client.query(statement, statement.includes('$1') ? [candidateWorkspace] : [])),
          (error) => error?.code === '42501',
        );
      }
    }
  });
}

test('projects: direct TRUNCATE is denied under valid same-tenant context', async ({ appPool }) => {
  await assert.rejects(
    () => inTenant(appPool, contextA, (client) => client.query('TRUNCATE roomscan.projects')),
    (error) => error?.code === '42501',
  );
});

test('cross-tenant INSERT is denied after a same-tenant INSERT control', async ({ appPool }) => {
  const projectId = '30000000-0000-4000-8000-000000000010';
  await inTenant(appPool, contextA, (client) => client.query(
    `INSERT INTO roomscan.projects (workspace_id, id, slug, title)
     VALUES ($1, $2, 'insert-positive', 'Insert positive')`,
    [ids.workspaceA, projectId],
  ));
  await assert.rejects(
    () => inTenant(appPool, contextA, (client) => client.query(
      `INSERT INTO roomscan.projects (workspace_id, id, slug, title)
       VALUES ($1, $2, 'insert-cross', 'Insert cross')`,
      [ids.workspaceB, projectId],
    )),
    (error) => error?.code === '42501',
  );
});

test('cross-tenant UPDATE is invisible after a same-tenant UPDATE control', async ({ appPool }) => {
  const same = await inTenant(appPool, contextA, (client) => client.query(
    `UPDATE roomscan.projects SET title = 'Updated A'
     WHERE workspace_id = $1 AND id = $2`,
    [ids.workspaceA, ids.projectA],
  ));
  const cross = await inTenant(appPool, contextA, (client) => client.query(
    `UPDATE roomscan.projects SET title = 'Leaked update'
     WHERE workspace_id = $1 AND id = $2`,
    [ids.workspaceB, ids.projectB],
  ));
  assert.equal(same.rowCount, 1);
  assert.equal(cross.rowCount, 0);
});

test('project WITH CHECK rejects moving a visible tenant-A row into tenant B', async ({ appPool }) => {
  await assert.rejects(
    () => inTenant(appPool, contextA, (client) => client.query(
      `UPDATE roomscan.projects SET workspace_id=$1 WHERE workspace_id=$2 AND id=$3`,
      [ids.workspaceB, ids.workspaceA, ids.projectA],
    )),
    (error) => error?.code === '42501',
  );
  assert.equal(await inTenant(appPool, contextA, async (client) => (
    await client.query('SELECT count(*)::int AS count FROM roomscan.projects WHERE workspace_id=$1 AND id=$2', [ids.workspaceA, ids.projectA])
  ).rows[0].count), 1);
});

test('cross-tenant DELETE is invisible after a same-tenant DELETE control', async ({ appPool }) => {
  const same = await inTenant(appPool, contextA, (client) => client.query(
    `DELETE FROM roomscan.projects
     WHERE workspace_id = $1 AND slug = 'insert-positive'`,
    [ids.workspaceA],
  ));
  const cross = await inTenant(appPool, contextA, (client) => client.query(
    `DELETE FROM roomscan.projects WHERE workspace_id = $1 AND id = $2`,
    [ids.workspaceB, ids.projectB],
  ));
  assert.equal(same.rowCount, 1);
  assert.equal(cross.rowCount, 0);
});

test('tenant-scoped uniqueness does not expose another tenant project identifier or slug', async ({ appPool }) => {
  await inTenant(appPool, contextA, (client) => client.query(
    `INSERT INTO roomscan.projects (workspace_id, id, slug, title)
     VALUES ($1, $2, 'project-b', 'Tenant-scoped duplicate identifiers')`,
    [ids.workspaceA, ids.projectB],
  ));
  const count = await inTenant(appPool, contextA, async (client) => (
    await client.query('SELECT count(*)::int AS count FROM roomscan.projects WHERE id = $1', [ids.projectB])
  ).rows[0].count);
  assert.equal(count, 1);
});

test('quota ledger rejects direct app writes and its composite FK does not resolve another tenant reservation key', async ({ appPool, bootstrapPool }) => {
  await assert.rejects(() => inTenant(appPool, contextA, (client) => client.query(
    `INSERT INTO roomscan.quota_ledger (
      workspace_id, idempotency_key, action, metric, delta_used, delta_reserved, policy_version
    ) VALUES ($1, 'fixture-a', 'release', 'project_count', 0, -1, 900)`,
    [ids.workspaceA],
  )), (error) => error?.code === '42501');
  await bootstrapPool.query(
    `INSERT INTO roomscan.quota_ledger (
      workspace_id, idempotency_key, action, metric, delta_used, delta_reserved, policy_version
    ) VALUES ($1, 'fixture-a', 'release', 'project_count', 0, -1, 900)`,
    [ids.workspaceA],
  );
  await assert.rejects(
    () => bootstrapPool.query(
      `INSERT INTO roomscan.quota_ledger (
        workspace_id, idempotency_key, action, metric, delta_used, delta_reserved, policy_version
      ) VALUES ($1, 'fixture-b', 'release', 'project_count', 0, -1, 900)`,
      [ids.workspaceA],
    ),
    (error) => error?.code === '23503',
  );
});

test('membership self-list resolves only the authenticated principal without tenant context', async ({ appPool }) => {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await client.query("SELECT set_config('app.principal_id', $1, true)", [ids.principalA]);
    const rows = (await client.query(
      'SELECT workspace_id, principal_id FROM roomscan.memberships ORDER BY workspace_id',
    )).rows;
    assert.deepEqual(rows, [{ workspace_id: ids.workspaceA, principal_id: ids.principalA }]);
    await client.query('ROLLBACK');
  } finally {
    client.release();
  }
});

test('missing, empty, partial, malformed, and forged context fail closed', async ({ appPool }) => {
  const client = await appPool.connect();
  try {
    assert.equal((await client.query('SELECT count(*)::int AS count FROM roomscan.projects')).rows[0].count, 0);

    await client.query('BEGIN');
    await client.query("SELECT set_config('app.principal_id', $1, true)", [ids.principalA]);
    assert.equal((await client.query('SELECT count(*)::int AS count FROM roomscan.projects')).rows[0].count, 0);
    await client.query("SELECT set_config('app.tenant_id', '', true)");
    await client.query("SELECT set_config('app.authorization_version', '', true)");
    assert.equal((await client.query('SELECT count(*)::int AS count FROM roomscan.projects')).rows[0].count, 0);
    await client.query("SELECT set_config('app.tenant_id', $1, true)", [ids.workspaceB]);
    await client.query("SELECT set_config('app.authorization_version', '1', true)");
    assert.equal((await client.query('SELECT count(*)::int AS count FROM roomscan.projects')).rows[0].count, 0);
    await client.query("SELECT set_config('app.tenant_id', 'not-a-uuid', true)");
    await assert.rejects(() => client.query('SELECT count(*) FROM roomscan.projects'), (error) => error?.code === '22P02');
    await client.query('ROLLBACK');
  } finally {
    client.release();
  }
});

test('tenant writes require tenant context even when principal self-list context exists', async ({ appPool }) => {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await client.query("SELECT set_config('app.principal_id', $1, true)", [ids.principalA]);
    await assert.rejects(
      () => client.query(
        `INSERT INTO roomscan.projects (workspace_id, id, slug, title)
         VALUES ($1, '30000000-0000-4000-8000-000000000011', 'no-tenant', 'No tenant')`,
        [ids.workspaceA],
      ),
      (error) => error?.code === '42501',
    );
    await client.query('ROLLBACK');
  } finally {
    client.release();
  }
});

test('server resolution rejects cross-tenant ID substitution and caller-authored context keys', async ({ appPool }) => {
  await assert.rejects(
    () => inTenant(appPool, { ...contextA, requestedWorkspaceId: ids.workspaceB }, async () => undefined),
    (error) => error instanceof TenantContextError && error.code === 'ACTIVE_MEMBERSHIP_REQUIRED',
  );
  await assert.rejects(
    () => inTenant(appPool, { ...contextA, tenantId: ids.workspaceB }, async () => undefined),
    (error) => error instanceof TenantContextError && error.code === 'CALLER_CONTEXT_REJECTED',
  );
});

test('A/B/no-context interleaving reuses one connection without context retention', async ({ cluster }) => {
  const reusePool = new Pool(appPoolConfig(cluster, 1));
  try {
    const a = await inTenant(reusePool, contextA, async (client) => ({
      pid: (await client.query('SELECT pg_backend_pid() AS pid')).rows[0].pid,
      workspaces: (await client.query(
        'SELECT DISTINCT workspace_id FROM roomscan.projects ORDER BY workspace_id',
      )).rows.map((row) => row.workspace_id),
    }));
    const b = await inTenant(reusePool, contextB, async (client) => ({
      pid: (await client.query('SELECT pg_backend_pid() AS pid')).rows[0].pid,
      workspaces: (await client.query(
        'SELECT DISTINCT workspace_id FROM roomscan.projects ORDER BY workspace_id',
      )).rows.map((row) => row.workspace_id),
    }));
    const client = await reusePool.connect();
    try {
      const noContextPid = (await client.query('SELECT pg_backend_pid() AS pid')).rows[0].pid;
      assert.equal(a.pid, b.pid);
      assert.equal(b.pid, noContextPid);
      assert.deepEqual(a.workspaces, [ids.workspaceA]);
      assert.deepEqual(b.workspaces, [ids.workspaceB]);
      assert.equal((await client.query('SELECT count(*)::int AS count FROM roomscan.projects')).rows[0].count, 0);
      await assertNoContext(client);
    } finally {
      client.release();
    }
  } finally {
    await reusePool.end();
  }
});

test('commit, explicit rollback, and thrown errors clear transaction-local context', async ({ cluster }) => {
  const reusePool = new Pool(appPoolConfig(cluster, 1));
  try {
    await inTenant(reusePool, contextA, async (client) => {
      assert.equal((await readContext(client)).tenant_id, ids.workspaceA);
    });
    let client = await reusePool.connect();
    try {
      await assertNoContext(client);
      await client.query('BEGIN');
      await client.query("SELECT set_config('app.principal_id', $1, true)", [ids.principalA]);
      await client.query("SELECT set_config('app.tenant_id', $1, true)", [ids.workspaceA]);
      await client.query("SELECT set_config('app.authorization_version', '1', true)");
      await client.query('ROLLBACK');
      await assertNoContext(client);
    } finally {
      client.release();
    }

    await assert.rejects(
      () => inTenant(reusePool, contextA, async () => {
        throw new Error('SENTINEL_THROWN_OPERATION');
      }),
      /SENTINEL_THROWN_OPERATION/u,
    );
    client = await reusePool.connect();
    try {
      await assertNoContext(client);
    } finally {
      client.release();
    }
  } finally {
    await reusePool.end();
  }
});

test('savepoint rollback restores tenant context and final commit clears it', async ({ cluster }) => {
  const reusePool = new Pool(appPoolConfig(cluster, 1));
  try {
    await inTenant(reusePool, contextA, async (client) => {
      await client.query('SAVEPOINT tenant_probe');
      await client.query("SELECT set_config('app.tenant_id', $1, true)", [ids.workspaceB]);
      await client.query('ROLLBACK TO SAVEPOINT tenant_probe');
      assert.equal((await readContext(client)).tenant_id, ids.workspaceA);
      assert.ok((await client.query('SELECT count(*)::int AS count FROM roomscan.projects')).rows[0].count > 0);
    });
    const client = await reusePool.connect();
    try {
      await assertNoContext(client);
    } finally {
      client.release();
    }
  } finally {
    await reusePool.end();
  }
});

test('parallel requests remain isolated and release context on every pooled connection', async ({ cluster }) => {
  const parallelPool = new Pool(appPoolConfig(cluster, 4));
  try {
    const outcomes = await Promise.all(
      Array.from({ length: 8 }, (_, index) => {
        const context = index % 2 === 0 ? contextA : contextB;
        const expectedWorkspace = index % 2 === 0 ? ids.workspaceA : ids.workspaceB;
        return inTenant(parallelPool, context, async (client) => {
          await client.query('SELECT pg_sleep(0.01)');
          const workspaces = (await client.query(
            'SELECT DISTINCT workspace_id FROM roomscan.projects ORDER BY workspace_id',
          )).rows.map((row) => row.workspace_id);
          assert.deepEqual(workspaces, [expectedWorkspace]);
          return (await client.query('SELECT pg_backend_pid() AS pid')).rows[0].pid;
        });
      }),
    );
    assert.ok(new Set(outcomes).size >= 2, 'parallel control did not exercise multiple pooled connections');
    const clients = await Promise.all(Array.from({ length: 4 }, () => parallelPool.connect()));
    try {
      await Promise.all(clients.map(assertNoContext));
    } finally {
      clients.forEach((client) => client.release());
    }
  } finally {
    await parallelPool.end();
  }
});

test('forced RLS applies to the tenant-table owner with a same-tenant control', async ({ bootstrapPool }) => {
  const client = await bootstrapPool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL ROLE roomscan_owner');
    await client.query("SELECT set_config('app.principal_id', $1, true)", [ids.principalA]);
    await client.query("SELECT set_config('app.tenant_id', $1, true)", [ids.workspaceA]);
    await client.query("SELECT set_config('app.authorization_version', '1', true)");
    const same = (await client.query(
      'SELECT count(*)::int AS count FROM roomscan.projects WHERE workspace_id = $1',
      [ids.workspaceA],
    )).rows[0].count;
    const cross = (await client.query(
      'SELECT count(*)::int AS count FROM roomscan.projects WHERE workspace_id = $1',
      [ids.workspaceB],
    )).rows[0].count;
    assert.ok(same > 0);
    assert.equal(cross, 0);
    await client.query('ROLLBACK');
  } finally {
    client.release();
  }
});

test('invitation hash length is enforced and a 32-byte positive control succeeds', async ({ appPool, bootstrapPool }) => {
  await assert.rejects(
    () => bootstrapPool.query(
      `INSERT INTO roomscan.invitations (
        workspace_id, id, token_hash, invited_role, expires_at, created_by_principal_id
      ) VALUES ($1, '40000000-0000-4000-8000-000000000010', $2, 'viewer', clock_timestamp() + interval '1 hour', $3)`,
      [ids.workspaceA, Buffer.from('short'), ids.principalA],
    ),
    (error) => error?.code === '23514',
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.invitations (
      workspace_id, id, token_hash, invited_role, expires_at, created_by_principal_id
    ) VALUES ($1, '40000000-0000-4000-8000-000000000010', $2, 'viewer', clock_timestamp() + interval '1 hour', $3)`,
    [ids.workspaceA, hash32('positive-control'), ids.principalA],
  );
});

test('expired invitation is durably denied under authenticated-principal-only context', async ({ appPool, bootstrapPool }) => {
  await bootstrapPool.query(
    `INSERT INTO roomscan.invitations (
      workspace_id, id, token_hash, invited_role, expires_at, created_by_principal_id
    ) VALUES ($1, '40000000-0000-4000-8000-000000000011', $2, 'viewer', clock_timestamp() - interval '1 second', $3)`,
    [ids.workspaceA, hash32('expired-invitation'), ids.principalA],
  );
  const accepted = await withPrincipalTransaction(
    appPool,
    { principalId: ids.principalInvitee },
    async (client) => (
      await client.query('SELECT roomscan.consume_invitation($1) AS accepted', [hash32('expired-invitation')])
    ).rows[0].accepted,
  );
  assert.equal(accepted, false);
});

test('invitation concurrent acceptance and replay yield exactly one winner', async ({ appPool }) => {
  const calls = await Promise.all([
    withPrincipalTransaction(appPool, { principalId: ids.principalInvitee }, async (client) => (
      await client.query('SELECT roomscan.consume_invitation($1) AS accepted', [
        hash32('invitation-a'),
      ])
    ).rows[0].accepted),
    withPrincipalTransaction(appPool, { principalId: ids.principalInvitee }, async (client) => (
      await client.query('SELECT roomscan.consume_invitation($1) AS accepted', [
        hash32('invitation-a'),
      ])
    ).rows[0].accepted),
  ]);
  assert.deepEqual(calls.sort(), [false, true]);
  const replay = await withPrincipalTransaction(appPool, { principalId: ids.principalInvitee }, async (client) => (
    await client.query('SELECT roomscan.consume_invitation($1) AS accepted', [
      hash32('invitation-a'),
    ])
  ).rows[0].accepted);
  assert.equal(replay, false);
  const membershipCount = await inTenant(appPool, contextA, async (client) => (
    await client.query(
      'SELECT count(*)::int AS count FROM roomscan.memberships WHERE principal_id = $1',
      [ids.principalInvitee],
    )
  ).rows[0].count);
  assert.equal(membershipCount, 1);
});

test('competing principals race one invitation with exactly one durable membership winner', async ({ appPool, bootstrapPool }) => {
  await bootstrapPool.query(
    `INSERT INTO roomscan.invitations (
      workspace_id, id, token_hash, invited_role, expires_at, created_by_principal_id
    ) VALUES ($1, '40000000-0000-4000-8000-000000000012', $2, 'viewer', clock_timestamp() + interval '1 hour', $3)`,
    [ids.workspaceB, hash32('competing-invitation'), ids.principalB],
  );
  const candidates = [ids.principalA, ids.principalExtraOwner];
  const outcomes = await Promise.all(candidates.map((principalId) => withPrincipalTransaction(
    appPool,
    { principalId },
    async (client) => (
      await client.query('SELECT roomscan.consume_invitation($1) AS accepted', [hash32('competing-invitation')])
    ).rows[0].accepted,
  )));
  assert.deepEqual(outcomes.sort(), [false, true]);
  const winners = (await bootstrapPool.query(
    `SELECT principal_id FROM roomscan.memberships
     WHERE workspace_id = $1 AND principal_id = ANY($2::uuid[]) ORDER BY principal_id`,
    [ids.workspaceB, candidates],
  )).rows;
  assert.equal(winners.length, 1);
});

test('last owner cannot be demoted or removed', async ({ bootstrapPool }) => {
  await assert.rejects(
    () => bootstrapPool.query(
      `UPDATE roomscan.memberships SET role = 'admin'
       WHERE workspace_id = $1 AND principal_id = $2`,
      [ids.workspaceB, ids.principalB],
    ),
    (error) => error?.code === 'P0001' && error?.message === 'LAST_OWNER_REQUIRED',
  );
  await assert.rejects(
    () => bootstrapPool.query(
      'DELETE FROM roomscan.memberships WHERE workspace_id = $1 AND principal_id = $2',
      [ids.workspaceB, ids.principalB],
    ),
    (error) => error?.code === 'P0001' && error?.message === 'LAST_OWNER_REQUIRED',
  );
});

test('concurrent owner demotions serialize and preserve exactly one owner', async ({ bootstrapPool }) => {
  const workspaceC = '20000000-0000-4000-8000-000000000003';
  await bootstrapPool.query(
    `INSERT INTO roomscan.workspaces (id, slug, display_name)
     VALUES ($1, 'workspace-c', 'Workspace C')`,
    [workspaceC],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.memberships (workspace_id, principal_id, role, state)
     VALUES ($1, $2, 'owner', 'active'), ($1, $3, 'owner', 'active')`,
    [workspaceC, ids.principalA, ids.principalExtraOwner],
  );
  const outcomes = await Promise.allSettled([
    bootstrapPool.query(
      `UPDATE roomscan.memberships SET role = 'admin'
       WHERE workspace_id = $1 AND principal_id = $2`,
      [workspaceC, ids.principalA],
    ),
    bootstrapPool.query(
      `UPDATE roomscan.memberships SET role = 'admin'
       WHERE workspace_id = $1 AND principal_id = $2`,
      [workspaceC, ids.principalExtraOwner],
    ),
  ]);
  assert.equal(outcomes.filter(({ status }) => status === 'fulfilled').length, 1);
  assert.equal(
    outcomes.filter(({ status, reason }) => (
      status === 'rejected' && reason?.code === 'P0001' && reason?.message === 'LAST_OWNER_REQUIRED'
    )).length,
    1,
  );
  const owners = (await bootstrapPool.query(
    `SELECT count(*)::int AS count
     FROM roomscan.memberships
     WHERE workspace_id = $1 AND role = 'owner' AND state = 'active'`,
    [workspaceC],
  )).rows[0].count;
  assert.equal(owners, 1);
});

test('role change advances authorization version and stale context is denied', async ({ appPool, bootstrapPool }) => {
  assert.ok(await inTenant(appPool, {
    principalId: ids.principalMember,
    requestedWorkspaceId: ids.workspaceA,
    expectedAuthorizationVersion: 1,
  }, async (client) => (await client.query('SELECT count(*)::int AS count FROM roomscan.projects')).rows[0].count));

  await bootstrapPool.query(
    `UPDATE roomscan.memberships SET role = 'viewer'
     WHERE workspace_id = $1 AND principal_id = $2`,
    [ids.workspaceA, ids.principalMember],
  );
  await assert.rejects(
    () => inTenant(appPool, {
      principalId: ids.principalMember,
      requestedWorkspaceId: ids.workspaceA,
      expectedAuthorizationVersion: 1,
    }, async () => undefined),
    (error) => error instanceof TenantContextError && error.code === 'STALE_AUTHORIZATION',
  );
  assert.ok(await inTenant(appPool, {
    principalId: ids.principalMember,
    requestedWorkspaceId: ids.workspaceA,
    expectedAuthorizationVersion: 2,
  }, async (client) => (await client.query('SELECT count(*)::int AS count FROM roomscan.projects')).rows[0].count));
});

test('removed membership immediately loses resolution and RLS access', async ({ appPool, bootstrapPool }) => {
  await bootstrapPool.query(
    `UPDATE roomscan.memberships SET state = 'removed'
     WHERE workspace_id = $1 AND principal_id = $2`,
    [ids.workspaceA, ids.principalMember],
  );
  await assert.rejects(
    () => inTenant(appPool, {
      principalId: ids.principalMember,
      requestedWorkspaceId: ids.workspaceA,
      expectedAuthorizationVersion: 2,
    }, async () => undefined),
    (error) => error instanceof TenantContextError && error.code === 'ACTIVE_MEMBERSHIP_REQUIRED',
  );
});

const cluster = await startPostgresCluster();
const bootstrapPool = new Pool(cluster.bootstrapConfig);
let appPool;
const evidence = {};
let passed = 0;
const failures = [];

try {
  const migrationResult = await applyMigrations({ pool: bootstrapPool, migrationsDir });
  assert.equal(migrationResult.applied.length, 6);
  await seedCoreFixtures(bootstrapPool);
  await seedBoundaryFixtures(bootstrapPool);
  appPool = new Pool(appPoolConfig(cluster, 8));

  for (const { name, operation } of tests) {
    try {
      await operation({ cluster, bootstrapPool, appPool, evidence });
      passed += 1;
      console.log(`PASS ${name}`);
    } catch (error) {
      failures.push({ name, error });
      console.error(`FAIL ${name}: ${error?.stack ?? error}`);
    }
  }
} finally {
  await appPool?.end();
  await bootstrapPool.end();
  evidence.cleanup = await cluster.stop();
}

console.log(`CATALOG_EVIDENCE ${JSON.stringify(evidence.catalog)}`);
console.log(`PROCESS_CLEANUP_EVIDENCE ${JSON.stringify(evidence.cleanup)}`);
console.log(`TEST_SUMMARY passed=${passed} failed=${failures.length} total=${tests.length}`);

if (failures.length > 0) {
  process.exitCode = 1;
}
