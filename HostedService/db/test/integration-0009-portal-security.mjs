import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { appPoolConfig, hash32, ids, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const cluster = await startPostgresCluster();
const bootstrapPool = new Pool(cluster.bootstrapConfig);
let portalPool;
let apiPool;

try {
  await applyMigrations({
    pool: bootstrapPool,
    ...(process.env.ROOMSCAN_TEST_MIGRATIONS_DIR
      ? { migrationsDir: process.env.ROOMSCAN_TEST_MIGRATIONS_DIR }
      : {}),
  });
  await seedCoreFixtures(bootstrapPool);

  const rlsRows = (await bootstrapPool.query(
    `SELECT c.relname, c.relrowsecurity, c.relforcerowsecurity
       FROM pg_class AS c JOIN pg_namespace AS n ON n.oid = c.relnamespace
      WHERE n.nspname = 'roomscan' AND c.relname = ANY($1::text[])
      ORDER BY c.relname`,
    [[
      'publication_properties', 'publication_property_rooms', 'publication_snapshot_rooms', 'publication_allocation_source_bindings', 'publication_allocations',
      'publication_sources', 'publication_approvals', 'publication_jobs',
      'publication_snapshots', 'publication_assets', 'publication_links',
      'portal_sessions', 'portal_pin_throttles', 'portal_feedback_challenges',
      'publication_feedback', 'publication_access_events', 'portal_delivery_receipts', 'portal_asset_reservations',
      'portal_feedback_delivery_outbox', 'portal_feedback_request_throttles',
      'professional_asset_reservations', 'professional_asset_delivery_receipts',
      'professional_web_sessions',
    ]],
  )).rows;
  assert.equal(rlsRows.length, 23, 'all Slice 6 portal tables must exist before RLS is evaluated');
  for (const {
    relname,
    relrowsecurity: enabled,
    relforcerowsecurity: forced,
  } of rlsRows) {
    assert.equal(enabled, true, `${relname} must enable RLS`);
    assert.equal(forced, true, `${relname} must FORCE RLS`);
  }

  const directTables = [
    'professional_projects', 'project_revisions', 'projects', 'memberships',
    'publication_properties', 'publication_property_rooms', 'publication_snapshot_rooms', 'publication_allocation_source_bindings', 'publication_allocations',
    'publication_sources', 'publication_approvals', 'publication_jobs',
    'publication_snapshots', 'publication_assets', 'publication_links',
    'professional_web_sessions', 'portal_sessions', 'portal_pin_throttles',
    'portal_feedback_challenges', 'publication_feedback', 'publication_access_events',
    'portal_delivery_receipts', 'portal_asset_reservations',
    'portal_feedback_delivery_outbox', 'portal_feedback_request_throttles',
    'professional_asset_reservations', 'professional_asset_delivery_receipts',
  ];
  for (const role of [
    'roomscan_api_runtime',
    'roomscan_portal_runtime',
    'roomscan_publication_worker',
    'roomscan_email_delivery_runtime',
  ]) {
    for (const table of directTables) {
      const privileges = (await bootstrapPool.query(
        `SELECT has_table_privilege($1, 'roomscan.' || $2, 'SELECT') AS can_select,
                has_table_privilege($1, 'roomscan.' || $2, 'INSERT') AS can_insert,
                has_table_privilege($1, 'roomscan.' || $2, 'UPDATE') AS can_update,
                has_table_privilege($1, 'roomscan.' || $2, 'DELETE') AS can_delete`,
        [role, table],
      )).rows[0];
      assert.deepEqual(privileges, { can_select: false, can_insert: false, can_update: false, can_delete: false }, `${role} direct table access`);
    }
  }

  const immutableTriggerRows = (await bootstrapPool.query(
    `SELECT c.relname
       FROM pg_class AS c JOIN pg_namespace AS n ON n.oid = c.relnamespace
      WHERE n.nspname = 'roomscan' AND c.relname = ANY($1::text[])
        AND EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgrelid = c.oid AND NOT t.tgisinternal)
      ORDER BY c.relname`,
    [[
      'publication_sources', 'publication_approvals', 'publication_snapshots',
      'publication_snapshot_rooms', 'publication_allocation_source_bindings',
      'publication_assets', 'publication_feedback', 'publication_access_events',
    ]],
  )).rows.map(({ relname: name }) => name);
  assert.deepEqual(immutableTriggerRows, [
    'publication_access_events', 'publication_allocation_source_bindings',
    'publication_approvals', 'publication_assets', 'publication_feedback',
    'publication_snapshot_rooms', 'publication_snapshots', 'publication_sources',
  ]);

  portalPool = new Pool({ ...appPoolConfig(cluster, 2), user: 'roomscan_portal_runtime' });
  apiPool = new Pool({ ...appPoolConfig(cluster, 2), user: 'roomscan_api_runtime' });
  await assert.rejects(
    () => portalPool.query('SELECT * FROM roomscan.publication_projects'),
    (error) => error?.code === '42P01',
  );
  await assert.rejects(
    () => portalPool.query('SELECT * FROM roomscan.projects'),
    (error) => error?.code === '42501' || error?.code === '42P01',
    'portal runtime must not read private project truth directly',
  );

  const publicationRoleMatrix = [
    ['roomscan.publication_upsert_property_v2(text,bytea,timestamp with time zone,text,bigint,bytea,text,jsonb)', 'api'],
    ['roomscan.publication_allocate_v1(text,bytea,timestamp with time zone,text,text,bytea,bytea,bytea,bytea,text,text,text,jsonb,bytea,bytea,bytea,bigint,bytea)', 'api'],
    ['roomscan.publication_complete_v2(text,bytea,timestamp with time zone,text,bytea,bytea,bigint)', 'api'],
    ['roomscan.publication_create_link_v1(text,bytea,timestamp with time zone,text,bytea,timestamp with time zone,bytea,bytea,text,text,bytea)', 'api'],
    ['roomscan.publication_update_link_v1(text,bytea,timestamp with time zone,text,bytea,timestamp with time zone,bytea,bytea,text,text,bigint)', 'api'],
    ['roomscan.publication_reset_link_v1(text,bytea,timestamp with time zone,text,bytea,timestamp with time zone,bytea,bytea,text,text,bigint)', 'api'],
    ['roomscan.publication_revoke_link_v1(text,bytea,timestamp with time zone,text,bigint)', 'api'],
    ['roomscan.professional_session_issue_v1(bytea,timestamp with time zone,bytea,uuid)', 'api'],
    ['roomscan.professional_session_revoke_v1(bytea,timestamp with time zone)', 'api'],
    ['roomscan.professional_session_resolve_v1(bytea,timestamp with time zone,text)', 'api'],
    ['roomscan.professional_list_properties_v1(text,bytea,timestamp with time zone,integer,text)', 'api'],
    ['roomscan.professional_list_concepts_v1(text,bytea,timestamp with time zone,text,integer,text)', 'api'],
    ['roomscan.professional_list_members_v1(text,bytea,timestamp with time zone,integer,text)', 'api'],
    ['roomscan.publication_allocation_status_v1(text,bytea,timestamp with time zone,text)', 'api'],
    ['roomscan.publication_list_allocations_v1(text,bytea,timestamp with time zone,integer,text)', 'api'],
    ['roomscan.publication_list_links_v1(text,bytea,timestamp with time zone,text,integer,text)', 'api'],
    ['roomscan.publication_list_links_v2(text,bytea,timestamp with time zone,text,integer,text)', 'api'],
    ['roomscan.publication_list_feedback_v1(text,bytea,timestamp with time zone,text,text,integer,text)', 'api'],
    ['roomscan.publication_list_access_history_v1(text,bytea,timestamp with time zone,text,integer,text)', 'api'],
    ['roomscan.publication_list_downloads_v1(text,bytea,timestamp with time zone,text,integer,text)', 'api'],
    ['roomscan.professional_session_bootstrap_v1(text,bytea,timestamp with time zone)', 'api'],
    ['roomscan.publication_claim_job_v1(timestamp with time zone)', 'worker'],
    ['roomscan.publication_bind_quarantine_version_v1(uuid,text,timestamp with time zone,text)', 'worker'],
    ['roomscan.publication_reject_v1(uuid,text,timestamp with time zone,text)', 'worker'],
    ['roomscan.publication_finalize_v1(uuid,text,timestamp with time zone,text,bytea,bytea,bigint,jsonb)', 'worker'],
    ['roomscan.portal_exchange_link_v1(bytea,timestamp with time zone,bytea,text,bytea)', 'portal'],
    ['roomscan.portal_pin_parameters_v1(bytea,timestamp with time zone)', 'portal'],
    ['roomscan.portal_pin_attempt_v1(bytea,timestamp with time zone,bytea)', 'portal'],
    ['roomscan.portal_verify_pin_v1(bytea,timestamp with time zone,bytea)', 'portal'],
    ['roomscan.portal_get_snapshot_v1(bytea,timestamp with time zone)', 'portal'],
    ['roomscan.portal_get_snapshot_v2(bytea,timestamp with time zone)', 'portal'],
    ['roomscan.portal_list_property_rooms_v1(bytea,timestamp with time zone)', 'portal'],
    ['roomscan.portal_lookup_presentation_asset_v1(bytea,timestamp with time zone)', 'portal'],
    ['roomscan.portal_authorize_asset_v1(bytea,timestamp with time zone,text,bytea,bigint,bigint)', 'portal'],
    ['roomscan.portal_finalize_asset_delivery_v1(bytea,timestamp with time zone,text,bytea,bigint,bigint,text)', 'portal'],
    ['roomscan.portal_authorize_download_v1(bytea,timestamp with time zone,text,bytea,bigint,bigint)', 'portal'],
    ['roomscan.portal_authorize_professional_asset_v1(bytea,timestamp with time zone,text,bytea,bigint,bigint)', 'portal'],
    ['roomscan.portal_finalize_professional_asset_delivery_v1(bytea,timestamp with time zone,text,bytea,bigint,bigint,text)', 'portal'],
    ['roomscan.portal_request_feedback_verification_v3(bytea,timestamp with time zone,bytea,bytea,bytea,text,bytea,bytea,bytea,bytea)', 'portal'],
    ['roomscan.portal_consume_feedback_verification_v1(bytea,bytea,timestamp with time zone,bytea)', 'portal'],
    ['roomscan.portal_create_feedback_v1(bytea,timestamp with time zone,bytea,text,text,bytea)', 'portal'],
    ['roomscan.claim_next_feedback_delivery_v3(text,timestamp with time zone,timestamp with time zone)', 'email'],
    ['roomscan.validate_feedback_delivery_v3(text,text,timestamp with time zone)', 'email'],
    ['roomscan.complete_feedback_delivery_v3(text,text,timestamp with time zone)', 'email'],
    ['roomscan.cancel_feedback_delivery_v3(text,text,text,timestamp with time zone)', 'email'],
    ['roomscan.release_feedback_delivery_v3(text,text,timestamp with time zone)', 'email'],
  ];
  for (const [routine, authorizedRuntime] of publicationRoleMatrix) {
    const privileges = (await bootstrapPool.query(
      `SELECT has_function_privilege('public', $1, 'EXECUTE') AS public_execute,
              has_function_privilege('roomscan_app', $1, 'EXECUTE') AS app_execute,
              has_function_privilege('roomscan_api_runtime', $1, 'EXECUTE') AS api_execute,
              has_function_privilege('roomscan_portal_runtime', $1, 'EXECUTE') AS portal_execute,
              has_function_privilege('roomscan_publication_worker', $1, 'EXECUTE') AS worker_execute,
              has_function_privilege('roomscan_email_delivery_runtime', $1, 'EXECUTE') AS email_execute`,
      [routine],
    )).rows[0];
    assert.deepEqual(privileges, {
      public_execute: false,
      app_execute: false,
      api_execute: authorizedRuntime === 'api',
      portal_execute: authorizedRuntime === 'portal',
      worker_execute: authorizedRuntime === 'worker',
      email_execute: authorizedRuntime === 'email',
    }, `${routine} must be granted only to its approved Slice 6 runtime action`);
  }

  const supersededRuntimeRoutines = [
    'roomscan.publication_upsert_property_v1(text,bytea,timestamp with time zone,text,bigint,text,jsonb)',
    'roomscan.publication_complete_v1(text,bytea,timestamp with time zone,text,bytea,bytea,bigint,text)',
    'roomscan.portal_request_feedback_verification_v1(bytea,timestamp with time zone,bytea,bytea,bytea)',
    'roomscan.portal_request_feedback_verification_v2(bytea,timestamp with time zone,bytea,bytea,bytea,text,bytea,bytea,bytea)',
    'roomscan.claim_next_feedback_delivery_v2(text,timestamp with time zone,timestamp with time zone)',
    'roomscan.claim_feedback_delivery_v2(text,timestamp with time zone,timestamp with time zone)',
    'roomscan.validate_feedback_delivery_v2(text,text,timestamp with time zone)',
    'roomscan.complete_feedback_delivery_v2(text,text,timestamp with time zone)',
    'roomscan.cancel_feedback_delivery_v2(text,text,text,timestamp with time zone)',
    'roomscan.release_feedback_delivery_v2(text,text,timestamp with time zone)',
  ];
  for (const routine of supersededRuntimeRoutines) {
    const privileges = (await bootstrapPool.query(
      `SELECT has_function_privilege('public', $1, 'EXECUTE') AS public_execute,
              has_function_privilege('roomscan_app', $1, 'EXECUTE') AS app_execute,
              has_function_privilege('roomscan_api_runtime', $1, 'EXECUTE') AS api_execute,
              has_function_privilege('roomscan_portal_runtime', $1, 'EXECUTE') AS portal_execute,
              has_function_privilege('roomscan_publication_worker', $1, 'EXECUTE') AS worker_execute,
              has_function_privilege('roomscan_email_delivery_runtime', $1, 'EXECUTE') AS email_execute`,
      [routine],
    )).rows[0];
    assert.deepEqual(privileges, {
      public_execute: false,
      app_execute: false,
      api_execute: false,
      portal_execute: false,
      worker_execute: false,
      email_execute: false,
    }, `${routine} is superseded and must not retain a runtime or PUBLIC capability`);
  }

  const v3DefinitionRows = (await bootstrapPool.query(
    `SELECT procedure.oid::regprocedure::text AS routine,
            owner_role.rolname AS owner,
            procedure.prosecdef AS security_definer,
            coalesce(array_to_string(procedure.proconfig, ','), '') AS configuration
       FROM pg_proc AS procedure
       JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
       JOIN pg_roles AS owner_role ON owner_role.oid = procedure.proowner
      WHERE namespace.nspname = 'roomscan'
        AND procedure.proname = ANY($1::text[])
      ORDER BY routine`,
    [[
      'portal_request_feedback_verification_v3',
      'claim_next_feedback_delivery_v3', 'validate_feedback_delivery_v3',
      'complete_feedback_delivery_v3', 'cancel_feedback_delivery_v3',
      'release_feedback_delivery_v3',
    ]],
  )).rows;
  assert.equal(v3DefinitionRows.length, 6,
    'the durable feedback v3 contract must expose exactly one portal issuer and five sealed email lifecycle reducers');
  for (const row of v3DefinitionRows) {
    assert.deepEqual(
      { owner: row.owner, security_definer: row.security_definer, fixed_search_path: row.configuration },
      { owner: 'roomscan_policy', security_definer: true, fixed_search_path: 'search_path=pg_catalog, pg_temp' },
      `${row.routine} must run as the narrow policy owner with a fixed search path`,
    );
  }

  const portalSnapshotV2Definition = (await bootstrapPool.query(
    `SELECT owner_role.rolname AS owner,
            procedure.prosecdef AS security_definer,
            coalesce(array_to_string(procedure.proconfig, ','), '') AS configuration
       FROM pg_proc AS procedure
       JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
       JOIN pg_roles AS owner_role ON owner_role.oid = procedure.proowner
      WHERE namespace.nspname = 'roomscan'
        AND procedure.oid = 'roomscan.portal_get_snapshot_v2(bytea,timestamp with time zone)'::regprocedure`,
  )).rows[0];
  assert.deepEqual(
    portalSnapshotV2Definition,
    { owner: 'roomscan_policy', security_definer: true, configuration: 'search_path=pg_catalog, pg_temp' },
    'the additive portal capabilities projection must retain the policy owner and fixed security-definer search path',
  );

  const controlledClockRoutines = (await bootstrapPool.query(
    `SELECT procedure.oid::regprocedure::text AS routine,
            has_function_privilege('public', procedure.oid, 'EXECUTE') AS public_execute,
            has_function_privilege('roomscan_app', procedure.oid, 'EXECUTE') AS app_execute,
            has_function_privilege('roomscan_api_runtime', procedure.oid, 'EXECUTE') AS api_execute,
            has_function_privilege('roomscan_portal_runtime', procedure.oid, 'EXECUTE') AS portal_execute,
            has_function_privilege('roomscan_publication_worker', procedure.oid, 'EXECUTE') AS worker_execute,
            has_function_privilege('roomscan_email_delivery_runtime', procedure.oid, 'EXECUTE') AS email_execute
       FROM pg_proc AS procedure
       JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
      WHERE namespace.nspname = 'roomscan'
        AND procedure.proname = ANY($1::text[])
        AND array_position(procedure.proargnames, 'authoritative_time') IS NOT NULL
      ORDER BY routine`,
    [[
      'publication_upsert_property_v2', 'publication_allocate_v1', 'publication_complete_v2',
      'publication_create_link_v1', 'publication_update_link_v1', 'publication_reset_link_v1',
      'publication_revoke_link_v1', 'professional_session_issue_v1',
      'professional_session_revoke_v1', 'professional_session_resolve_v1',
      'professional_list_properties_v1', 'professional_list_concepts_v1',
      'professional_list_members_v1', 'publication_allocation_status_v1',
      'publication_list_allocations_v1', 'publication_list_links_v1',
      'publication_list_links_v2',
      'publication_list_feedback_v1', 'publication_list_access_history_v1',
      'publication_list_downloads_v1', 'professional_session_bootstrap_v1',
      'publication_claim_job_v1', 'publication_bind_quarantine_version_v1',
      'publication_reject_v1', 'publication_finalize_v1',
      'portal_exchange_link_v1', 'portal_pin_parameters_v1', 'portal_pin_attempt_v1',
      'portal_verify_pin_v1', 'portal_get_snapshot_v1', 'portal_get_snapshot_v2',
      'portal_list_property_rooms_v1',
      'portal_lookup_presentation_asset_v1', 'portal_authorize_asset_v1',
      'portal_finalize_asset_delivery_v1', 'portal_authorize_download_v1',
      'portal_authorize_professional_asset_v1', 'portal_finalize_professional_asset_delivery_v1',
      'portal_request_feedback_verification_v3', 'portal_consume_feedback_verification_v1',
      'portal_create_feedback_v1',
    ]],
  )).rows;
  assert.equal(controlledClockRoutines.length, 41,
    'every Slice 6 runtime clock reducer must be catalogued for direct-execute ACL proof');
  for (const routine of controlledClockRoutines) {
    assert.equal(routine.public_execute, false,
      `${routine.routine} must not expose a PUBLIC client-controlled clock argument`);
    assert.equal(routine.app_execute, false,
      `${routine.routine} must not expose a browser/native roomscan_app clock argument`);
    assert.equal(
      Number(routine.api_execute) + Number(routine.portal_execute)
        + Number(routine.worker_execute) + Number(routine.email_execute),
      1,
      `${routine.routine} must accept authoritative_time only from one narrow service, worker, or portal runtime principal`,
    );
  }

  const internalGuardRoutines = [
    'roomscan.publication_feedback_immutable_guard_v1()',
    'roomscan.publication_require_feedback_delivery_runtime_v2()',
    'roomscan.portal_require_active_session_v1(bytea,timestamp with time zone)',
    'roomscan.professional_read_resolve_v1(text,bytea,timestamp with time zone,text)',
    'roomscan.professional_portal_asset_context_v1(bytea,timestamp with time zone)',
  ];
  for (const routine of internalGuardRoutines) {
    const privileges = (await bootstrapPool.query(
      `SELECT has_function_privilege('public', $1, 'EXECUTE') AS public_execute,
              has_function_privilege('roomscan_api_runtime', $1, 'EXECUTE') AS api_execute,
              has_function_privilege('roomscan_portal_runtime', $1, 'EXECUTE') AS portal_execute,
              has_function_privilege('roomscan_publication_worker', $1, 'EXECUTE') AS worker_execute,
              has_function_privilege('roomscan_email_delivery_runtime', $1, 'EXECUTE') AS email_execute`,
      [routine],
    )).rows[0];
    assert.deepEqual(privileges, {
      public_execute: false,
      api_execute: false,
      portal_execute: false,
      worker_execute: false,
      email_execute: false,
    }, `${routine} is an internal guard and must not gain a runtime/public execution capability`);
  }

  const projectMutationRoutines = (await bootstrapPool.query(
    `SELECT p.oid::regprocedure::text AS routine,
            has_function_privilege('public', p.oid, 'EXECUTE') AS public_execute,
            has_function_privilege('roomscan_portal_runtime', p.oid, 'EXECUTE') AS portal_execute
       FROM pg_proc AS p
       JOIN pg_namespace AS n ON n.oid = p.pronamespace
      WHERE n.nspname = 'roomscan'
        AND p.proname = ANY($1::text[])
      ORDER BY routine`,
    [[
      'allocate_project_migration_v1', 'allocate_project_revision_v1',
      'allocate_project_raw_archive_v1', 'complete_project_upload_v1',
      'allocate_project_recovery_v1', 'acquire_project_edit_lease_v1',
      'renew_project_edit_lease_v1', 'release_project_edit_lease_v1',
      'release_project_upload_v1', 'finalize_project_upload_v1',
    ]],
  )).rows;
  assert.equal(projectMutationRoutines.length, 10, 'project mutation capability catalog must expose all selected Slice 5 mutation routes');
  for (const { routine, public_execute: publicExecute, portal_execute: portalExecute } of projectMutationRoutines) {
    assert.equal(publicExecute, false, `${routine} must retain PUBLIC execute denial`);
    assert.equal(portalExecute, false, `${routine} must not be callable by accountless feedback/portal runtime`);
  }

  const publicProjectionColumns = (await bootstrapPool.query(
    `SELECT table_name, column_name
       FROM information_schema.columns
      WHERE table_schema = 'roomscan'
        AND table_name = ANY($1::text[])
      ORDER BY table_name, ordinal_position`,
    [[
      'publication_properties', 'publication_property_rooms', 'publication_snapshots',
      'publication_assets',
    ]],
  )).rows.map(({ table_name: tableName, column_name: columnName }) => `${tableName}.${columnName}`);
  const forbiddenProjectionField = /(?:raw(?:_|$)|rgb|depth|confidence|diagnostic|world_map|private_note|gps|revision_history)/u;
  assert.deepEqual(
    publicProjectionColumns.filter((field) => forbiddenProjectionField.test(field)),
    [],
    'portal projection schema must contain no raw capture, diagnostics, GPS, private note, or full-history field',
  );
  assert.deepEqual(
    [...publicProjectionColumns, 'publication_snapshots.raw_rgb_canary']
      .filter((field) => forbiddenProjectionField.test(field)),
    ['publication_snapshots.raw_rgb_canary'],
    'projection privacy probe must detect an injected forbidden snapshot field',
  );

  const accessHistoryColumns = (await bootstrapPool.query(
    `SELECT column_name FROM information_schema.columns
      WHERE table_schema = 'roomscan' AND table_name = 'publication_access_events'
      ORDER BY ordinal_position`,
  )).rows.map(({ column_name: columnName }) => columnName);
  const forbiddenAccessHistoryField = /(?:^|_)(?:ip|address|user_agent|token|url|email|content)(?:_|$)/u;
  assert.deepEqual(
    accessHistoryColumns.filter((field) => forbiddenAccessHistoryField.test(field)),
    [],
    'privacy-conscious portal access history must not persist identifiers, bearer material, referrers, or content',
  );
  assert.deepEqual(
    [...accessHistoryColumns, 'bearer_token_canary'].filter((field) => forbiddenAccessHistoryField.test(field)),
    ['bearer_token_canary'],
    'access-history privacy probe must detect an injected bearer-token canary',
  );

  console.log('INTEGRATION_0009_PORTAL_SECURITY_SUMMARY forced_rls=23 direct_runtime_denials=108 immutable_guards=8 role_action_matrix=46 superseded_runtime_denials=10 v3_policy_catalog=6 controlled_clock_acl=41 internal_guard_denials=25 project_mutation_portal_denials=10 public_execute_denials=46 projection_privacy_probes=2 access_history_privacy_probes=2 status=pass');
} finally {
  await apiPool?.end();
  await portalPool?.end();
  await bootstrapPool.end();
  const cleanup = await cluster.stop();
  console.log(`PG_CLEANUP ${JSON.stringify(cleanup)}`);
}
