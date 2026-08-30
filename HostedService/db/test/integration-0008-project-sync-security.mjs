import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { appPoolConfig, hash32, ids, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const cluster = await startPostgresCluster();
const bootstrapPool = new Pool(cluster.bootstrapConfig);
let apiPool;
let workerPool;

const now = new Date('2026-08-28T13:00:00.000Z');
const digest = (label) => hash32(`slice5-project-sync-security:${label}`);
const roleNames = ['roomscan_api_runtime', 'roomscan_project_sync_runtime'];
const protectedTables = [
  'professional_projects',
  'project_uploads',
  'project_revisions',
  'project_raw_archives',
  'project_edit_leases',
];
const workerRoutines = [
  'roomscan.reap_expired_project_upload_v1(timestamp with time zone)',
  'roomscan.claim_next_project_validation_v1(timestamp with time zone)',
  'roomscan.release_project_upload_v1(uuid,text,timestamp with time zone)',
  'roomscan.reject_project_upload_v1(uuid,text,timestamp with time zone,text)',
  'roomscan.finalize_project_upload_v1(uuid,text,timestamp with time zone,text,text)',
];
const workerClaimRoutine = 'roomscan.claim_next_project_validation_v1(timestamp with time zone)';
const recoveryStorageRoutine =
  'roomscan.resolve_project_recovery_storage_v1(bytea,timestamp with time zone,text,text)';
const publicRoutines = [
  'roomscan.allocate_project_migration_v1(bytea,timestamp with time zone,text,text,bytea,bytea,bigint,bytea,bigint,bigint,bigint)',
  'roomscan.allocate_project_revision_v1(bytea,timestamp with time zone,text,text,text,text,bytea,bytea,bigint,bytea,bigint,bigint,bigint)',
  'roomscan.complete_project_upload_v1(bytea,timestamp with time zone,text)',
  'roomscan.read_project_upload_status_v1(bytea,timestamp with time zone,text)',
  'roomscan.allocate_project_recovery_v1(bytea,timestamp with time zone,text,text)',
  recoveryStorageRoutine,
  'roomscan.configure_project_raw_archive_v1(bytea,timestamp with time zone,text,bytea,bigint,bigint)',
  'roomscan.allocate_project_raw_archive_v1(bytea,timestamp with time zone,text,text,bytea,bytea,bigint,bytea,bytea,bigint,bigint,bigint)',
  'roomscan.acquire_project_edit_lease_v1(bytea,timestamp with time zone,text,bytea,bytea,bytea,bigint,bigint)',
  'roomscan.renew_project_edit_lease_v1(bytea,timestamp with time zone,text,bytea,bigint,bigint)',
  'roomscan.release_project_edit_lease_v1(bytea,timestamp with time zone,text,bytea,bigint,bigint)',
];

async function withOperator(work) {
  await bootstrapPool.query('SET ROLE roomscan_operator');
  try {
    return await work();
  } finally {
    await bootstrapPool.query('RESET ROLE');
  }
}

async function enableWorkspace(workspaceId, label, setGlobal = false) {
  await withOperator(async () => {
    const global = setGlobal ? (await bootstrapPool.query(
      `SELECT * FROM roomscan.set_operational_flag(
         'global', NULL::uuid, 'hosted_operations_enabled', true, NULL,
         'slice 5 security integration', $1, $2::timestamptz
       )`,
      [`ofaud_slice5_${label}_global`, now],
    )).rows[0] : { version: 1 };
    const workspace = (await bootstrapPool.query(
      `SELECT * FROM roomscan.set_operational_flag(
         'workspace', $1::uuid, 'hosted_operations_enabled', true, NULL,
         'slice 5 security integration', $2, $3::timestamptz
       )`,
      [workspaceId, `ofaud_slice5_${label}_workspace`, now],
    )).rows[0];
    await bootstrapPool.query(
      `SELECT * FROM roomscan.activate_quota_policy_v2(
         $1::uuid, 1, 'roomscan-quota-policy-v1', 'test-only',
         'roomscan-period-v1:security-' || $2, 20, 20, 2000000, 2000000, 2000000,
         80, $3::bigint, $4::bigint, $5::timestamptz
       )`,
      [workspaceId, label, global.version, workspace.version, now],
    );
  });
}

async function insertAccess({ principalId, workspaceId, role, label, suffix }) {
  const membership = (await bootstrapPool.query(
    `SELECT authorization_version FROM roomscan.memberships
      WHERE workspace_id = $1::uuid AND principal_id = $2::uuid`,
    [workspaceId, principalId],
  )).rows[0];
  const familyId = `6a000000-0000-4000-8000-${suffix}`;
  const access = digest(`access:${label}`);
  await bootstrapPool.query(
    `INSERT INTO roomscan.auth_session_families (
       id, public_id, principal_id, authentication_epoch, authenticated_at,
       last_used_at, inactivity_expires_at, absolute_expires_at, policy_version,
       workspace_id, role, authorization_version, state, created_at
     ) VALUES (
       $1::uuid, $2, $3::uuid, 0, $4::timestamptz, $4::timestamptz,
       $4::timestamptz + interval '1 day', $4::timestamptz + interval '7 days',
       'session-v1', $5::uuid, $6, $7::bigint, 'active', $4::timestamptz
     )`,
    [familyId, `fam_slice5_security_${label}`, principalId, now, workspaceId, role, membership.authorization_version],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.auth_access_tokens (
       id, family_id, token_hash, expires_at, principal_id, authentication_epoch,
       authenticated_at, issued_at, workspace_id, role, authorization_version, state, created_at
     ) VALUES (
       gen_random_uuid(), $1::uuid, $2::bytea, $3::timestamptz + interval '1 day',
       $4::uuid, 0, $3::timestamptz, $3::timestamptz, $5::uuid, $6,
       $7::bigint, 'active', $3::timestamptz
     )`,
    [familyId, access, now, principalId, workspaceId, role, membership.authorization_version],
  );
  return access;
}

async function allocateMigration(access, label, source) {
  return (await apiPool.query(
    `SELECT * FROM roomscan.allocate_project_migration_v1(
       $1::bytea, $2::timestamptz, $3::text, $4::text, $5::bytea, $6::bytea,
       88::bigint, $7::bytea, 1::bigint, 1::bigint, 1::bigint
     )`,
    [
      access, now, source, `${source}_revision`, digest(`${label}:manifest`),
      digest(`${label}:archive`), digest(`${label}:idempotency`),
    ],
  )).rows[0];
}

async function durableCounts() {
  const result = {};
  for (const table of protectedTables) {
    result[table] = (await bootstrapPool.query(
      `SELECT count(*)::integer AS count FROM roomscan.${table}`,
    )).rows[0].count;
  }
  return result;
}

try {
  const applied = await applyMigrations({
    pool: bootstrapPool,
    ...(process.env.ROOMSCAN_TEST_MIGRATIONS_DIR
      ? { migrationsDir: process.env.ROOMSCAN_TEST_MIGRATIONS_DIR }
      : {}),
  });
  assert.equal(applied.applied.at(-1)?.version, '0008', 'security coverage needs the 0008 migration');
  await seedCoreFixtures(bootstrapPool);
  await enableWorkspace(ids.workspaceA, 'a', true);
  await enableWorkspace(ids.workspaceB, 'b');
  const accessA = await insertAccess({
    principalId: ids.principalA, workspaceId: ids.workspaceA, role: 'owner',
    label: 'a', suffix: '000000000301',
  });
  const accessB = await insertAccess({
    principalId: ids.principalB, workspaceId: ids.workspaceB, role: 'owner',
    label: 'b', suffix: '000000000302',
  });
  apiPool = new Pool({
    ...appPoolConfig(cluster, 2), user: 'roomscan_api_runtime', max: 2,
    application_name: 'rss-0008-security-api',
  });
  workerPool = new Pool({
    ...appPoolConfig(cluster, 2), user: 'roomscan_project_sync_runtime', max: 2,
    application_name: 'rss-0008-security-worker',
  });

  const roleRows = (await bootstrapPool.query(
    `SELECT rolname, rolcanlogin, rolinherit, rolsuper, rolcreatedb,
            rolcreaterole, rolreplication, rolbypassrls
       FROM pg_roles WHERE rolname = ANY($1::text[]) ORDER BY rolname`,
    [['roomscan_api_runtime', 'roomscan_project_sync_runtime']],
  )).rows;
  assert.deepEqual(roleRows, [
    {
      rolname: 'roomscan_api_runtime', rolcanlogin: true, rolinherit: false,
      rolsuper: false, rolcreatedb: false, rolcreaterole: false,
      rolreplication: false, rolbypassrls: false,
    },
    {
      rolname: 'roomscan_project_sync_runtime', rolcanlogin: true, rolinherit: false,
      rolsuper: false, rolcreatedb: false, rolcreaterole: false,
      rolreplication: false, rolbypassrls: false,
    },
  ]);
  assert.equal((await bootstrapPool.query(
    `SELECT count(*)::integer AS count
       FROM pg_auth_members membership
       JOIN pg_roles member ON member.oid = membership.member
       JOIN pg_roles granted ON granted.oid = membership.roleid
      WHERE member.rolname = 'roomscan_project_sync_runtime'
        AND granted.rolname IN ('roomscan_owner', 'roomscan_policy', 'roomscan_app')`,
  )).rows[0].count, 0, 'worker runtime role must not inherit privileged roles');

  const workerClaimCatalog = (await bootstrapPool.query(
    `SELECT pg_get_function_result(procedure.oid) AS result
       FROM pg_proc AS procedure
      WHERE procedure.oid = to_regprocedure($1)`,
    [workerClaimRoutine],
  )).rows;
  assert.equal(workerClaimCatalog.length, 1, 'worker claim reducer must retain its exact signature');
  assert.match(workerClaimCatalog[0].result,
    /project_source_project_id text, archive_source_revision_id text\)$/u,
    'worker claim output must expose only the exact source-binding column names required by the worker decoder');

  const recoveryStorageCatalog = (await bootstrapPool.query(
    `SELECT procedure.oid::regprocedure::text AS routine,
            owner.rolname AS owner,
            procedure.proconfig,
            obj_description(procedure.oid, 'pg_proc') AS review,
            has_function_privilege('public', procedure.oid, 'EXECUTE') AS public_execute
       FROM pg_proc AS procedure
       JOIN pg_roles AS owner ON owner.oid = procedure.proowner
      WHERE procedure.oid = to_regprocedure($1)`,
    [recoveryStorageRoutine],
  )).rows;
  assert.equal(recoveryStorageCatalog.length, 1,
    'trusted recovery storage resolver must exist as an exact DB capability');
  assert.deepEqual(recoveryStorageCatalog[0], {
    routine: recoveryStorageRoutine,
    owner: 'roomscan_policy',
    proconfig: ['search_path=pg_catalog, pg_temp'],
    review: 'Slice 5 trusted post-commit recovery storage resolver. It re-derives access tenant and membership, returns only the exact persisted logical working binding for an authorized canonical or stale revision, and is not a public HTTP result, PUBLIC revoked.',
    public_execute: false,
  });

  for (const table of protectedTables) {
    const rls = (await bootstrapPool.query(
      `SELECT relrowsecurity, relforcerowsecurity
         FROM pg_class WHERE oid = ('roomscan.' || $1)::regclass`,
      [table],
    )).rows[0];
    assert.deepEqual(rls, { relrowsecurity: true, relforcerowsecurity: true }, `${table} must FORCE RLS`);
    for (const role of roleNames) {
      const privileges = (await bootstrapPool.query(
        `SELECT has_table_privilege($1, 'roomscan.' || $2, 'SELECT') AS select_allowed,
                has_table_privilege($1, 'roomscan.' || $2, 'INSERT') AS insert_allowed,
                has_table_privilege($1, 'roomscan.' || $2, 'UPDATE') AS update_allowed,
                has_table_privilege($1, 'roomscan.' || $2, 'DELETE') AS delete_allowed`,
        [role, table],
      )).rows[0];
      assert.deepEqual(privileges, {
        select_allowed: false, insert_allowed: false, update_allowed: false, delete_allowed: false,
      }, `${role} must not receive direct roomscan.${table} access`);
    }
  }

  for (const routine of workerRoutines) {
    assert.equal((await bootstrapPool.query(
      `SELECT has_function_privilege('roomscan_project_sync_runtime', $1, 'EXECUTE') AS allowed`,
      [routine],
    )).rows[0].allowed, true, `${routine} must be available to worker runtime`);
    assert.equal((await bootstrapPool.query(
      `SELECT has_function_privilege('roomscan_api_runtime', $1, 'EXECUTE') AS allowed`,
      [routine],
    )).rows[0].allowed, false, `${routine} must not be available to API runtime`);
  }
  for (const routine of publicRoutines) {
    assert.equal((await bootstrapPool.query(
      `SELECT has_function_privilege('roomscan_api_runtime', $1, 'EXECUTE') AS allowed`,
      [routine],
    )).rows[0].allowed, true, `${routine} must be available to API runtime`);
    assert.equal((await bootstrapPool.query(
      `SELECT has_function_privilege('roomscan_project_sync_runtime', $1, 'EXECUTE') AS allowed`,
      [routine],
    )).rows[0].allowed, false, `${routine} must not be available to worker runtime`);
  }
  assert.equal((await bootstrapPool.query(
    `SELECT has_function_privilege('roomscan_project_sync_runtime', $1, 'EXECUTE') AS allowed`,
    [recoveryStorageRoutine],
  )).rows[0].allowed, false, 'trusted recovery storage resolver must not be a worker capability');

  const beforeNull = await durableCounts();
  await assert.rejects(
    () => apiPool.query(
      `SELECT * FROM roomscan.allocate_project_migration_v1(
         NULL::bytea, $1::timestamptz, 'source_null', 'revision_null',
         $2::bytea, $3::bytea, 88::bigint, $4::bytea, 1::bigint, 1::bigint, 1::bigint
       )`,
      [now, digest('null-manifest'), digest('null-archive'), digest('null-idempotency')],
    ),
    (error) => error?.code === '22023' && error?.message === 'INVALID_PROJECT_SYNC_MIGRATION_INPUT',
  );
  await assert.rejects(
    () => apiPool.query(
      `SELECT * FROM roomscan.resolve_project_recovery_storage_v1(
         NULL::bytea, $1::timestamptz, 'prj_aaaaaaaaaaaaaaaa', NULL::text
       )`,
      [now],
    ),
    (error) => error?.code === '22023' && error?.message === 'INVALID_PROJECT_SYNC_RECOVERY_STORAGE_INPUT',
  );
  assert.deepEqual(await durableCounts(), beforeNull, 'null access argument changed durable state');
  await assert.rejects(
    () => apiPool.query(
      'SELECT * FROM roomscan.complete_project_upload_v1($1::bytea, NULL::timestamptz, $2::text)',
      [accessA, 'upl_not_real'],
    ),
    (error) => error?.code === '22023' && error?.message === 'INVALID_PROJECT_SYNC_COMPLETION_INPUT',
  );

  const allocationA = await allocateMigration(accessA, 'a', 'source_security_a');
  const allocationB = await allocateMigration(accessB, 'b', 'source_security_b');
  assert.equal((await apiPool.query(
    'SELECT * FROM roomscan.read_project_upload_status_v1($1::bytea, $2::timestamptz, $3::text)',
    [accessA, now, allocationA.upload_public_id],
  )).rows[0].upload_public_id, allocationA.upload_public_id, 'same-tenant status control must work');
  assert.equal((await apiPool.query(
    'SELECT * FROM roomscan.read_project_upload_status_v1($1::bytea, $2::timestamptz, $3::text)',
    [accessA, now, allocationB.upload_public_id],
  )).rows.length, 0, 'cross-tenant upload status must be absent');
  await assert.rejects(
    () => apiPool.query(
      `SELECT * FROM roomscan.allocate_project_revision_v1(
         $1::bytea, $2::timestamptz, $3::text, 'rev_aaaaaaaaaaaaaaaa', 'source_fake',
         'source_append', $4::bytea, $5::bytea, 99::bigint, $6::bytea,
         1::bigint, 1::bigint, 1::bigint
       )`,
      [accessB, now, allocationA.project_public_id, digest('cross-manifest'), digest('cross-archive'), digest('cross-idempotency')],
    ),
    (error) => error?.code === '42501' && error?.message === 'PROJECT_SYNC_PROJECT_NOT_FOUND',
  );
  assert.equal((await apiPool.query(
    `SELECT * FROM roomscan.allocate_project_recovery_v1(
       $1::bytea, $2::timestamptz, $3::text, NULL::text
     )`,
    [accessB, now, allocationA.project_public_id],
  )).rows.length, 0, 'cross-tenant recovery must be absent');

  await assert.rejects(
    () => apiPool.query('SELECT * FROM roomscan.claim_next_project_validation_v1($1::timestamptz)', [now]),
    (error) => error?.code === '42501',
  );
  await assert.rejects(
    () => workerPool.query(
      `SELECT * FROM roomscan.allocate_project_migration_v1(
         $1::bytea, $2::timestamptz, 'source_worker', 'revision_worker',
         $3::bytea, $4::bytea, 88::bigint, $5::bytea, 1::bigint, 1::bigint, 1::bigint
       )`,
      [accessA, now, digest('worker-manifest'), digest('worker-archive'), digest('worker-idempotency')],
    ),
    (error) => error?.code === '42501',
  );
  await assert.rejects(
    () => apiPool.query('SELECT * FROM roomscan.project_uploads'),
    (error) => error?.code === '42501',
  );

  const allocationFields = Object.keys(allocationA);
  for (const forbidden of [
    'id', 'project_id', 'upload_id', 'candidate_revision_id', 'quarantine_key',
    'active_object_key', 'quarantine_version', 'active_object_version',
    'working_object_version', 'object_version', 'project_source_project_id',
    'archive_source_revision_id',
  ]) {
    assert.equal(allocationFields.includes(forbidden), false, `allocation leaked ${forbidden}`);
  }
  const auditSubjects = (await bootstrapPool.query(
    `SELECT subject_kind, subject_id FROM roomscan.audit_events
      WHERE action LIKE 'project_sync.%' ORDER BY sequence`,
  )).rows;
  assert.equal(auditSubjects.every(({ subject_kind, subject_id }) => (
    (subject_kind === 'project_sync.upload' && /^upl_[A-Za-z0-9_-]{16,128}$/u.test(subject_id))
    || (subject_kind === 'project_sync.project' && /^prj_[A-Za-z0-9_-]{16,128}$/u.test(subject_id))
  )), true, 'project-sync audit subjects must contain only bounded public project or upload identifiers');

  console.log(
    `INTEGRATION_0008_PROJECT_SYNC_SECURITY_SUMMARY roles=${roleNames.length} `
      + `forced_rls_tables=${protectedTables.length} worker_acl_controls=${workerRoutines.length} `
      + `api_acl_controls=${publicRoutines.length} cross_tenant_denials=3 same_tenant_controls=1 `
      + 'null_controls=3 direct_table_controls=1 public_identifier_controls=12 worker_claim_catalog_controls=2 '
      + 'recovery_storage_catalog_controls=5 status=pass',
  );
} finally {
  await Promise.all([apiPool?.end(), workerPool?.end()]);
  await bootstrapPool.end();
  console.log(`PG_CLEANUP ${JSON.stringify(await cluster.stop())}`);
}
