import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const cluster = await startPostgresCluster();
const pool = new Pool(cluster.bootstrapConfig);

const runtimeRoles = [
  'roomscan_api_runtime',
  'roomscan_audit_export_runtime',
  'roomscan_auth_challenge_runtime',
  'roomscan_authorizer_runtime',
  'roomscan_email_delivery_runtime',
  'roomscan_stripe_ingress_runtime',
  'roomscan_stripe_reconciliation_runtime',
];
const privilegeRoles = [...runtimeRoles, 'roomscan_operator', 'roomscan_app'];

function catalogDigest(value) {
  return createHash('sha256').update(JSON.stringify(value)).digest('hex');
}

try {
  await applyMigrations({ pool });

  const executeRows = (await pool.query(
    `SELECT role_name, routine
       FROM unnest($1::text[]) AS requested(role_name)
       CROSS JOIN LATERAL (
         SELECT format('%I.%I(%s)', namespace.nspname, procedure.proname,
                       oidvectortypes(procedure.proargtypes)) AS routine
           FROM pg_proc AS procedure
           JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
          WHERE namespace.nspname = 'roomscan'
            AND has_function_privilege(requested.role_name, procedure.oid, 'EXECUTE')
       ) AS executable
      ORDER BY role_name, routine`,
    [privilegeRoles],
  )).rows;
  const executeByRole = Object.fromEntries(privilegeRoles.map((role) => [
    role,
    executeRows.filter(({ role_name }) => role_name === role).map(({ routine }) => routine),
  ]));

  const definerRows = (await pool.query(
    `SELECT format('%I.%I(%s)', namespace.nspname, procedure.proname,
                   oidvectortypes(procedure.proargtypes)) AS routine,
            owner.rolname AS owner,
            procedure.proconfig,
            obj_description(procedure.oid, 'pg_proc') AS review,
            has_function_privilege('public', procedure.oid, 'EXECUTE') AS public_execute,
            procedure.prosrc ~* '(execute[[:space:]]+format|execute[[:space:]]+[^;]+using)' AS dynamic_sql
       FROM pg_proc AS procedure
       JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
       JOIN pg_roles AS owner ON owner.oid = procedure.proowner
      WHERE namespace.nspname = 'roomscan' AND procedure.prosecdef
      ORDER BY routine`,
  )).rows;

  const policyAcl = (await pool.query(
    `SELECT table_name, privilege_type
       FROM information_schema.role_table_grants
      WHERE table_schema = 'roomscan' AND grantee = 'roomscan_policy'
      ORDER BY table_name, privilege_type`,
  )).rows.map(({ table_name, privilege_type }) => `${table_name}:${privilege_type}`);

  const resultRows = (await pool.query(
    `SELECT DISTINCT format('%I.%I(%s)', namespace.nspname, procedure.proname,
                            oidvectortypes(procedure.proargtypes)) AS routine,
            pg_get_function_result(procedure.oid) AS result
       FROM pg_proc AS procedure
       JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
      WHERE namespace.nspname = 'roomscan'
        AND EXISTS (
          SELECT 1 FROM unnest($1::text[]) AS requested(role_name)
           WHERE has_function_privilege(requested.role_name, procedure.oid, 'EXECUTE')
        )
      ORDER BY routine`,
    [privilegeRoles],
  )).rows;

  const digests = {
    execute: catalogDigest(executeByRole),
    definers: catalogDigest(definerRows.map(({ routine }) => routine)),
    policyAcl: catalogDigest(policyAcl),
    results: catalogDigest(resultRows),
  };

  console.log(`INTEGRATION_0007_CATALOG_PROBE ${JSON.stringify({
    executeByRole,
    definers: definerRows.map(({ routine }) => routine),
    policyAcl,
    results: resultRows,
    digests,
    missingReviews: definerRows.filter(({ review }) =>
      typeof review !== 'string' || review.length === 0).map(({ routine }) => routine),
  })}`);

  assert.deepEqual(digests, {
    execute: '7dceb4e0fe441696faade84e15529416a90caded152afa9248513315e3b00c0a',
    definers: '2469f83f3a96664b2ebaf81230a1cb7951a58031d40b4067c36e9dd4459dd847',
    policyAcl: '327c8b918b823eb8372f18db139ea6d042db08a97b1cb2497054efb3a6a150c9',
    results: 'e921620f4988688e682870cf7110d96bc7adb5720a91e28143f380edb017971b',
  });

  assert.equal(definerRows.every(({ owner }) => owner === 'roomscan_policy'), true);
  assert.equal(definerRows.every(({ proconfig }) =>
    JSON.stringify(proconfig) === JSON.stringify(['search_path=pg_catalog, pg_temp'])), true);
  assert.equal(definerRows.every(({ public_execute }) => public_execute === false), true);
  assert.equal(definerRows.every(({ review }) => typeof review === 'string' && review.length > 0), true);
  assert.equal(definerRows.every(({ dynamic_sql }) => dynamic_sql === false), true);

  const membershipEdges = (await pool.query(
    `SELECT granted.rolname AS granted_role, member.rolname AS member_role
       FROM pg_auth_members AS edge
       JOIN pg_roles AS granted ON granted.oid = edge.roleid
       JOIN pg_roles AS member ON member.oid = edge.member
      WHERE granted.rolname LIKE 'roomscan_%' OR member.rolname LIKE 'roomscan_%'
      ORDER BY granted_role, member_role`,
  )).rows;
  assert.deepEqual(membershipEdges, []);

  const directRuntimePrivileges = Number((await pool.query(
    `SELECT count(*)::integer AS count
       FROM information_schema.role_table_grants
      WHERE table_schema = 'roomscan' AND grantee = ANY($1::text[])
        AND privilege_type IN ('SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')`,
    [runtimeRoles],
  )).rows[0].count);
  assert.equal(directRuntimePrivileges, 0);

  const stripeStorageCatalog = (await pool.query(
    `SELECT relation.relname AS table_name,
            owner.rolname AS owner,
            relation.relrowsecurity AS rls,
            relation.relforcerowsecurity AS forced_rls,
            constraint_record.contype AS constraint_type,
            pg_get_constraintdef(constraint_record.oid) AS definition
       FROM pg_class AS relation
       JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
       JOIN pg_roles AS owner ON owner.oid = relation.relowner
       LEFT JOIN pg_constraint AS constraint_record
         ON constraint_record.conrelid = relation.oid
      WHERE namespace.nspname = 'roomscan'
        AND relation.relname IN ('stripe_provider_accounts', 'stripe_billing_bindings')
      ORDER BY table_name, constraint_type, definition`,
  )).rows;
  assert.equal(stripeStorageCatalog.every(({ owner }) => owner === 'roomscan_owner'), true);
  const providerAccountRows = stripeStorageCatalog.filter(
    ({ table_name: tableName }) => tableName === 'stripe_provider_accounts',
  );
  assert.equal(providerAccountRows.every(({ rls, forced_rls: forcedRls }) =>
    rls === false && forcedRls === false), true);
  assert.equal(providerAccountRows.some(({ definition }) =>
    definition === 'PRIMARY KEY (provider_account_id)'), true);
  assert.equal(providerAccountRows.some(({ definition }) =>
    definition === 'UNIQUE (provider_account_id, account_mode)'), true);
  const bindingRows = stripeStorageCatalog.filter(
    ({ table_name: tableName }) => tableName === 'stripe_billing_bindings',
  );
  assert.equal(bindingRows.every(({ rls, forced_rls: forcedRls }) =>
    rls === true && forcedRls === true), true);
  assert.equal(bindingRows.some(({ definition }) =>
    definition === 'FOREIGN KEY (provider_account_id, account_mode) REFERENCES roomscan.stripe_provider_accounts(provider_account_id, account_mode) ON DELETE RESTRICT'), true);

  console.log(
    `INTEGRATION_0007_CATALOG_SUMMARY runtime_roles=${runtimeRoles.length} `
      + `routine_acl_roles=${privilegeRoles.length} definers=${definerRows.length} `
      + `policy_acl_entries=${policyAcl.length} membership_edges=0 `
      + 'stripe_account_registry_constraints=3 status=pass',
  );
} finally {
  await pool.end();
  const cleanup = await cluster.stop();
  console.log(`PG_CLEANUP ${JSON.stringify(cleanup)}`);
}
