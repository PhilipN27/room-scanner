import assert from 'node:assert/strict';
import { copyFile, mkdir, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { accepted0006MigrationsDir } from './accepted-0006-migrations.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const fullDir = accepted0006MigrationsDir;
const currentMigrationsDir = fileURLToPath(new URL('../migrations/', import.meta.url));
const stageRoot = await mkdtemp(path.join(tmpdir(), 'rss-stage-'));
const stageDir = path.join(stageRoot, 'migrations');
const hardenedDir = path.join(stageRoot, 'hardened-migrations');
await mkdir(stageDir);
await mkdir(hardenedDir);
for (const name of [
  '0001_roles_and_global.up.sql',
  '0002_tenant_core.up.sql',
  '0003_quota.up.sql',
  '0004_stripe.up.sql',
]) {
  await copyFile(path.join(fullDir, name), path.join(stageDir, name));
  await copyFile(path.join(fullDir, name), path.join(hardenedDir, name));
}
await copyFile(
  path.join(fullDir, '0005_hardened_reducers.up.sql'),
  path.join(hardenedDir, '0005_hardened_reducers.up.sql'),
);

const cluster = await startPostgresCluster();
const pool = new Pool(cluster.bootstrapConfig);
const expectedLegacy = [
  'roomscan.activate_quota_policy(bigint,bigint,bigint,bigint,bigint,bigint,integer)',
  'roomscan.apply_stripe_reconciliation(bigint,timestamp with time zone,text,text,timestamp with time zone)',
  'roomscan.consume_invitation(bytea)',
  'roomscan.enforce_membership_invariants()',
  'roomscan.finalize_quota(text,bigint)',
  'roomscan.has_authorized_tenant(uuid)',
  'roomscan.record_stripe_event(text,text,bytea,boolean,timestamp with time zone)',
  'roomscan.release_quota(text)',
  'roomscan.request_authorization_version()',
  'roomscan.request_principal_id()',
  'roomscan.request_tenant_id()',
  'roomscan.reserve_quota(roomscan.quota_metric,bigint,text)',
];
const expectedHardened = [
  'roomscan.activate_quota_policy(bigint,bigint,bigint,bigint,bigint,bigint,integer)',
  'roomscan.apply_stripe_reconciliation(bigint,timestamp with time zone,text,text,timestamp with time zone)',
  'roomscan.bootstrap_workspace(text,text)',
  'roomscan.consume_invitation(bytea)',
  'roomscan.finalize_quota(text,bigint)',
  'roomscan.has_authorized_tenant(uuid)',
  'roomscan.record_stripe_event(text,text,bytea,boolean,timestamp with time zone)',
  'roomscan.release_quota(text)',
  'roomscan.request_principal_id()',
  'roomscan.reserve_quota(roomscan.quota_metric,bigint,text)',
];
const expectedAuth = [
  ...expectedHardened,
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
  'roomscan.lock_magic_policy_scope(text,bytea)',
  'roomscan.release_external_identity(text,text,uuid)',
  'roomscan.release_magic_delivery(text,text,timestamp with time zone)',
  'roomscan.release_security_notification(text,text)',
  'roomscan.resolve_access_context(bytea,timestamp with time zone)',
  'roomscan.revoke_access_token(bytea,timestamp with time zone)',
  'roomscan.revoke_principal_session_families(uuid,uuid,timestamp with time zone,text)',
  'roomscan.revoke_session_family(uuid,timestamp with time zone,text)',
  'roomscan.supersede_magic_link(text,timestamp with time zone)',
  'roomscan.supersede_magic_link_siblings(text,timestamp with time zone)',
  'roomscan.update_session_family_activity(uuid,timestamp with time zone,timestamp with time zone)',
  'roomscan.validate_magic_delivery(text,text,timestamp with time zone)',
].sort();

async function appExecutable() {
  return (await pool.query(
    `SELECT p.oid::regprocedure::text AS routine
     FROM pg_proc AS p JOIN pg_namespace AS n ON n.oid=p.pronamespace
     WHERE n.nspname='roomscan' AND has_function_privilege('roomscan_app', p.oid, 'EXECUTE')
     ORDER BY routine`,
  )).rows.map(({ routine }) => routine);
}

try {
  const legacy = await applyMigrations({ pool, migrationsDir: stageDir });
  assert.equal(legacy.applied.length, 4);
  assert.deepEqual(await appExecutable(), expectedLegacy);

  const hardened = await applyMigrations({ pool, migrationsDir: hardenedDir });
  assert.equal(hardened.applied.length, 1);
  assert.equal(hardened.applied[0].name, '0005_hardened_reducers.up.sql');
  assert.deepEqual(await appExecutable(), expectedHardened);
  assert.equal((await pool.query(
    `SELECT count(*)::int AS count FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='roomscan' AND p.proname IN
       ('enforce_membership_invariants','request_tenant_id','request_authorization_version')
       AND has_function_privilege('roomscan_app', p.oid, 'EXECUTE')`,
  )).rows[0].count, 0);

  const auth = await applyMigrations({ pool, migrationsDir: fullDir });
  assert.equal(auth.applied.length, 1);
  assert.equal(auth.applied[0].name, '0006_auth_persistence.up.sql');
  assert.deepEqual(await appExecutable(), expectedAuth);

  await copyFile(
    path.join(currentMigrationsDir, '0007_policy_billing_integration.up.sql'),
    path.join(fullDir, '0007_policy_billing_integration.up.sql'),
  );
  const policy = await applyMigrations({ pool, migrationsDir: fullDir });
  assert.equal(policy.applied.length, 1);
  assert.equal(policy.applied[0].name, '0007_policy_billing_integration.up.sql');

  await copyFile(
    path.join(currentMigrationsDir, '0008_professional_project_sync.up.sql'),
    path.join(fullDir, '0008_professional_project_sync.up.sql'),
  );
  const projectSync = await applyMigrations({ pool, migrationsDir: fullDir });
  assert.equal(projectSync.applied.length, 1);
  assert.equal(projectSync.applied[0].name, '0008_professional_project_sync.up.sql');
  assert.deepEqual((await pool.query(
    `SELECT rolcanlogin, rolinherit, rolsuper, rolbypassrls
       FROM pg_roles WHERE rolname = 'roomscan_project_sync_runtime'`,
  )).rows[0], {
    rolcanlogin: true,
    rolinherit: false,
    rolsuper: false,
    rolbypassrls: false,
  });
  assert.equal((await pool.query(
    `SELECT count(*)::integer AS count
       FROM pg_class
      WHERE oid = ANY(ARRAY[
        'roomscan.professional_projects'::regclass,
        'roomscan.project_uploads'::regclass,
        'roomscan.project_revisions'::regclass,
        'roomscan.project_raw_archives'::regclass,
        'roomscan.project_edit_leases'::regclass
      ]) AND relforcerowsecurity`,
  )).rows[0].count, 5);
  const recoveryStorageRoutine =
    'roomscan.resolve_project_recovery_storage_v1(bytea,timestamp with time zone,text,text)';
  const workerClaimRoutine =
    'roomscan.claim_next_project_validation_v1(timestamp with time zone)';
  assert.equal((await pool.query(
    `SELECT has_function_privilege('roomscan_api_runtime', $1, 'EXECUTE') AS allowed`,
    [recoveryStorageRoutine],
  )).rows[0].allowed, true, 'staged 0008 upgrade must grant recovery storage resolution only to API runtime');
  assert.equal((await pool.query(
    `SELECT has_function_privilege('roomscan_project_sync_runtime', $1, 'EXECUTE') AS allowed`,
    [recoveryStorageRoutine],
  )).rows[0].allowed, false, 'staged 0008 upgrade must not grant recovery storage resolution to worker runtime');
  assert.equal((await pool.query(
    `SELECT has_function_privilege('public', $1, 'EXECUTE') AS allowed`,
    [recoveryStorageRoutine],
  )).rows[0].allowed, false, 'staged 0008 upgrade must retain PUBLIC denial for recovery storage resolution');
  assert.deepEqual((await pool.query(
    `SELECT pg_get_function_result(procedure.oid) AS result,
            has_function_privilege('roomscan_project_sync_runtime', procedure.oid, 'EXECUTE') AS worker_execute,
            has_function_privilege('roomscan_api_runtime', procedure.oid, 'EXECUTE') AS api_execute,
            has_function_privilege('public', procedure.oid, 'EXECUTE') AS public_execute
       FROM pg_proc AS procedure
      WHERE procedure.oid = to_regprocedure($1)`,
    [workerClaimRoutine],
  )).rows[0], {
    result: 'TABLE(workspace_id uuid, upload_id uuid, lease_id text, operation text, project_id uuid, project_public_id text, source_project_id text, candidate_revision_id uuid, candidate_revision_public_id text, target_revision_id uuid, expected_head_revision_id uuid, expected_head_source_revision_id text, working_manifest_digest bytea, working_digest bytea, working_bytes bigint, raw_manifest_digest bytea, raw_digest bytea, raw_bytes bigint, raw_review_digest bytea, quarantine_key text, active_object_key text, project_source_project_id text, archive_source_revision_id text)',
    worker_execute: true,
    api_execute: false,
    public_execute: false,
  });

  await copyFile(
    path.join(currentMigrationsDir, '0009_publication_portal.up.sql'),
    path.join(fullDir, '0009_publication_portal.up.sql'),
  );
  const publication = await applyMigrations({ pool, migrationsDir: fullDir });
  assert.equal(publication.applied.length, 1);
  assert.equal(publication.applied[0].name, '0009_publication_portal.up.sql');
  assert.deepEqual((await pool.query(
    `SELECT rolname, rolcanlogin, rolinherit, rolsuper, rolbypassrls
       FROM pg_roles
      WHERE rolname = ANY($1::text[])
      ORDER BY rolname`,
    [['roomscan_portal_runtime', 'roomscan_publication_worker']],
  )).rows, [
    {
      rolname: 'roomscan_portal_runtime',
      rolcanlogin: true,
      rolinherit: false,
      rolsuper: false,
      rolbypassrls: false,
    },
    {
      rolname: 'roomscan_publication_worker',
      rolcanlogin: true,
      rolinherit: false,
      rolsuper: false,
      rolbypassrls: false,
    },
  ]);
  assert.equal((await pool.query(
    `SELECT count(*)::integer AS count
       FROM pg_class
      WHERE oid = ANY(ARRAY[
        'roomscan.publication_properties'::regclass,
        'roomscan.publication_property_rooms'::regclass,
        'roomscan.publication_snapshot_rooms'::regclass,
        'roomscan.publication_allocation_source_bindings'::regclass,
        'roomscan.publication_allocations'::regclass,
        'roomscan.publication_sources'::regclass,
        'roomscan.publication_approvals'::regclass,
        'roomscan.publication_jobs'::regclass,
        'roomscan.publication_snapshots'::regclass,
        'roomscan.publication_assets'::regclass,
        'roomscan.publication_links'::regclass,
        'roomscan.professional_web_sessions'::regclass,
        'roomscan.portal_sessions'::regclass,
        'roomscan.portal_pin_throttles'::regclass,
        'roomscan.portal_feedback_challenges'::regclass,
        'roomscan.publication_feedback'::regclass,
        'roomscan.publication_access_events'::regclass,
        'roomscan.portal_delivery_receipts'::regclass,
        'roomscan.portal_asset_reservations'::regclass,
        'roomscan.portal_feedback_delivery_outbox'::regclass,
        'roomscan.portal_feedback_request_throttles'::regclass,
        'roomscan.professional_asset_reservations'::regclass,
        'roomscan.professional_asset_delivery_receipts'::regclass
      ]) AND relforcerowsecurity`,
  )).rows[0].count, 23, 'staged 0009 upgrade must force RLS on every publication/portal table');
  const publicationAllocationRoutine =
    'roomscan.publication_allocate_v1(text,bytea,timestamp with time zone,text,text,bytea,bytea,bytea,bytea,text,text,text,jsonb,bytea,bytea,bytea,bigint,bytea)';
  const portalSnapshotRoutine =
    'roomscan.portal_get_snapshot_v1(bytea,timestamp with time zone)';
  const portalSnapshotCapabilitiesRoutine =
    'roomscan.portal_get_snapshot_v2(bytea,timestamp with time zone)';
  assert.deepEqual((await pool.query(
    `SELECT has_function_privilege('roomscan_api_runtime', $1, 'EXECUTE') AS api_execute,
            has_function_privilege('roomscan_publication_worker', $1, 'EXECUTE') AS worker_execute,
            has_function_privilege('roomscan_portal_runtime', $1, 'EXECUTE') AS portal_execute,
            has_function_privilege('public', $1, 'EXECUTE') AS public_execute`,
    [publicationAllocationRoutine],
  )).rows[0], {
    api_execute: true,
    worker_execute: false,
    portal_execute: false,
    public_execute: false,
  }, 'staged 0009 allocation must remain API-only');
  assert.deepEqual((await pool.query(
    `SELECT has_function_privilege('roomscan_api_runtime', $1, 'EXECUTE') AS api_execute,
            has_function_privilege('roomscan_publication_worker', $1, 'EXECUTE') AS worker_execute,
            has_function_privilege('roomscan_portal_runtime', $1, 'EXECUTE') AS portal_execute,
            has_function_privilege('public', $1, 'EXECUTE') AS public_execute`,
    [portalSnapshotRoutine],
  )).rows[0], {
    api_execute: false,
    worker_execute: false,
    portal_execute: true,
    public_execute: false,
  }, 'staged 0009 snapshot authorization must remain portal-runtime-only');
  assert.deepEqual((await pool.query(
    `SELECT has_function_privilege('roomscan_api_runtime', $1, 'EXECUTE') AS api_execute,
            has_function_privilege('roomscan_publication_worker', $1, 'EXECUTE') AS worker_execute,
            has_function_privilege('roomscan_portal_runtime', $1, 'EXECUTE') AS portal_execute,
            has_function_privilege('public', $1, 'EXECUTE') AS public_execute`,
    [portalSnapshotCapabilitiesRoutine],
  )).rows[0], {
    api_execute: false,
    worker_execute: false,
    portal_execute: true,
    public_execute: false,
  }, 'staged 0009 additive snapshot capabilities must remain portal-runtime-only');
  const propertyRoomComposite = (await pool.query(
    `SELECT pg_get_constraintdef(constraint_row.oid) AS definition
       FROM pg_constraint AS constraint_row
      WHERE constraint_row.conname = 'publication_property_rooms_workspace_id_room_project_id_fkey'
        AND constraint_row.conrelid = 'roomscan.publication_property_rooms'::regclass`,
  )).rows[0];
  assert.match(
    propertyRoomComposite.definition,
    /FOREIGN KEY \(workspace_id, room_project_id\).*professional_projects\(workspace_id, project_id\)/u,
    'staged 0009 upgrade must bind mutable property curation to a same-tenant hosted project',
  );
  const allocationBindingComposites = (await pool.query(
    `SELECT pg_get_constraintdef(constraint_row.oid) AS definition
       FROM pg_constraint AS constraint_row
      WHERE constraint_row.contype = 'f'
        AND constraint_row.conrelid = 'roomscan.publication_allocation_source_bindings'::regclass`,
  )).rows;
  assert.equal(
    allocationBindingComposites.some(({ definition }) =>
      /FOREIGN KEY \(workspace_id, source_revision_id, room_project_id\).*project_revisions\(workspace_id, id, project_id\)/u.test(definition)),
    true,
    'staged 0009 upgrade must retain exact same-tenant revision/project binding for every Core source-binding row',
  );
  const snapshotRoomComposites = (await pool.query(
    `SELECT pg_get_constraintdef(constraint_row.oid) AS definition
       FROM pg_constraint AS constraint_row
      WHERE constraint_row.contype = 'f'
        AND constraint_row.conrelid = 'roomscan.publication_snapshot_rooms'::regclass`,
  )).rows;
  assert.equal(
    snapshotRoomComposites.some(({ definition }) =>
      /FOREIGN KEY \(workspace_id, source_revision_id, room_project_id\).*project_revisions\(workspace_id, id, project_id\)/u.test(definition)),
    true,
    'staged 0009 upgrade must retain frozen property-room source provenance as a composite FK',
  );
  const presentationLookupRoutine =
    'roomscan.portal_lookup_presentation_asset_v1(bytea,timestamp with time zone)';
  assert.deepEqual((await pool.query(
    `SELECT has_function_privilege('roomscan_api_runtime', $1, 'EXECUTE') AS api_execute,
            has_function_privilege('roomscan_publication_worker', $1, 'EXECUTE') AS worker_execute,
            has_function_privilege('roomscan_portal_runtime', $1, 'EXECUTE') AS portal_execute,
            has_function_privilege('public', $1, 'EXECUTE') AS public_execute`,
    [presentationLookupRoutine],
  )).rows[0], {
    api_execute: false,
    worker_execute: false,
    portal_execute: true,
    public_execute: false,
  }, 'staged 0009 presentation lookup must remain a portal-runtime-only metadata capability');
  const targetlessCompletionRoutine =
    'roomscan.publication_complete_v2(text,bytea,timestamp with time zone,text,bytea,bytea,bigint)';
  const bindQuarantineRoutine =
    'roomscan.publication_bind_quarantine_version_v1(uuid,text,timestamp with time zone,text)';
  const feedbackIssueRoutine =
    'roomscan.portal_request_feedback_verification_v3(bytea,timestamp with time zone,bytea,bytea,bytea,text,bytea,bytea,bytea,bytea)';
  const professionalAssetRoutine =
    'roomscan.portal_authorize_professional_asset_v1(bytea,timestamp with time zone,text,bytea,bigint,bigint)';
  const stagedCapabilityRows = (await pool.query(
    `SELECT routine,
            has_function_privilege('roomscan_api_runtime', routine::regprocedure, 'EXECUTE') AS api_execute,
            has_function_privilege('roomscan_publication_worker', routine::regprocedure, 'EXECUTE') AS worker_execute,
            has_function_privilege('roomscan_portal_runtime', routine::regprocedure, 'EXECUTE') AS portal_execute,
            has_function_privilege('roomscan_email_delivery_runtime', routine::regprocedure, 'EXECUTE') AS email_execute,
            has_function_privilege('public', routine::regprocedure, 'EXECUTE') AS public_execute
       FROM unnest($1::text[]) AS capability(routine)
      ORDER BY routine`,
    [[targetlessCompletionRoutine, bindQuarantineRoutine, feedbackIssueRoutine, professionalAssetRoutine]],
  )).rows;
  assert.deepEqual(stagedCapabilityRows, [
    { routine: professionalAssetRoutine, api_execute: false, worker_execute: false, portal_execute: true, email_execute: false, public_execute: false },
    { routine: feedbackIssueRoutine, api_execute: false, worker_execute: false, portal_execute: true, email_execute: false, public_execute: false },
    { routine: bindQuarantineRoutine, api_execute: false, worker_execute: true, portal_execute: false, email_execute: false, public_execute: false },
    { routine: targetlessCompletionRoutine, api_execute: true, worker_execute: false, portal_execute: false, email_execute: false, public_execute: false },
  ], 'staged 0009 correction reducers must retain one narrow runtime capability each');
  console.log(`STAGED_UPGRADE_SUMMARY legacy_migrations=4 hardened_migrations=1 auth_migrations=1 policy_migrations=1 project_sync_migrations=1 publication_migrations=1 legacy_app_execute=12 hardened_app_execute=10 auth_app_execute=${expectedAuth.length} project_sync_forced_rls_tables=5 publication_forced_rls_tables=23 recovery_storage_acl_controls=3 worker_claim_controls=4 publication_acl_controls=16 property_composite_fk=3 status=pass`);
} finally {
  await pool.end();
  console.error(`CLEANUP ${JSON.stringify(await cluster.stop())}`);
  await rm(stageRoot, { recursive: true, force: true });
}
