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
  'roomscan_project_sync_runtime',
  'roomscan_stripe_ingress_runtime',
  'roomscan_stripe_reconciliation_runtime',
];
const privilegeRoles = [...runtimeRoles, 'roomscan_operator', 'roomscan_app'];
const slice6SecurityDefinerReviewRoutines = [
  'roomscan.cancel_feedback_delivery_v2(text, text, text, timestamp with time zone)',
  'roomscan.cancel_feedback_delivery_v3(text, text, text, timestamp with time zone)',
  'roomscan.claim_feedback_delivery_v2(text, timestamp with time zone, timestamp with time zone)',
  'roomscan.claim_next_feedback_delivery_v2(text, timestamp with time zone, timestamp with time zone)',
  'roomscan.claim_next_feedback_delivery_v3(text, timestamp with time zone, timestamp with time zone)',
  'roomscan.complete_feedback_delivery_v2(text, text, timestamp with time zone)',
  'roomscan.complete_feedback_delivery_v3(text, text, timestamp with time zone)',
  'roomscan.portal_authorize_professional_asset_v1(bytea, timestamp with time zone, text, bytea, bigint, bigint)',
  'roomscan.portal_finalize_professional_asset_delivery_v1(bytea, timestamp with time zone, text, bytea, bigint, bigint, text)',
  'roomscan.portal_request_feedback_verification_v2(bytea, timestamp with time zone, bytea, bytea, bytea, text, bytea, bytea, bytea)',
  'roomscan.portal_request_feedback_verification_v3(bytea, timestamp with time zone, bytea, bytea, bytea, text, bytea, bytea, bytea, bytea)',
  'roomscan.professional_portal_asset_context_v1(bytea, timestamp with time zone)',
  'roomscan.publication_feedback_delivery_live_v2(uuid, text, timestamp with time zone)',
  'roomscan.publication_list_room_candidates_v1(text, bytea, timestamp with time zone, integer, text)',
  'roomscan.release_feedback_delivery_v2(text, text, timestamp with time zone)',
  'roomscan.release_feedback_delivery_v3(text, text, timestamp with time zone)',
  'roomscan.validate_feedback_delivery_v2(text, text, timestamp with time zone)',
  'roomscan.validate_feedback_delivery_v3(text, text, timestamp with time zone)',
].sort();

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
    // Reviewed delta: one API-only room-candidate reader, with no policy/table
    // grants or other role execute changes; result is only public ID + title.
    execute: 'ea95813862d5fb9ac2ed0a8d6c330a7790bead7a20fd09aec95e845496a2182e',
    definers: 'e38b05d53afaa901e573de1f9aaa857ea08c9fd0c1448a02abdf4152969600ed',
    policyAcl: 'b9504936be780117f54de8e3bff46e54c0db7826508722ae3555ac41185bf95a',
    results: 'dea5b58f056eaebeecc844b032e3c62b9c0e5efc298dc4ded7c1192796c4af63',
  });

  assert.equal(definerRows.every(({ owner }) => owner === 'roomscan_policy'), true);
  assert.equal(definerRows.every(({ proconfig }) =>
    JSON.stringify(proconfig) === JSON.stringify(['search_path=pg_catalog, pg_temp'])), true);
  assert.equal(definerRows.every(({ public_execute }) => public_execute === false), true);
  assert.equal(definerRows.every(({ review }) => typeof review === 'string' && review.length > 0), true);
  assert.equal(definerRows.every(({ dynamic_sql }) => dynamic_sql === false), true);
  const reviewedSlice6Routines = definerRows
    .filter(({ routine }) => slice6SecurityDefinerReviewRoutines.includes(routine))
    .map(({ routine }) => routine)
    .sort();
  assert.deepEqual(reviewedSlice6Routines, slice6SecurityDefinerReviewRoutines);
  assert.equal(definerRows
    .filter(({ routine }) => slice6SecurityDefinerReviewRoutines.includes(routine))
    .every(({ review }) => typeof review === 'string' && review.length > 0), true);

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
      + 'stripe_account_registry_constraints=3 project_sync_worker_catalog=1 publication_portal_catalog=1 status=pass',
  );
} finally {
  await pool.end();
  const cleanup = await cluster.stop();
  console.log(`PG_CLEANUP ${JSON.stringify(cleanup)}`);
}
