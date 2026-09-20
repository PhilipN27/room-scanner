import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { appPoolConfig, hash32, ids, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const cluster = await startPostgresCluster();
const bootstrapPool = new Pool(cluster.bootstrapConfig);
let apiPoolA;
let apiPoolB;
let workerPoolA;
let workerPoolB;

const now = new Date('2026-08-28T12:00:00.000Z');
const globalHostedVersion = 1;
const workspaceHostedVersion = 1;
const quotaPolicyVersion = 1;
const projectSyncMaxArchiveBytes = 67_108_864;

const digest = (label) => hash32(`slice5-project-sync:${label}`);
const asNumber = (value) => Number(value);
const opaqueS3Version = '3/L4kqtJlcpXroDTDmJ+3DcjkqQq2jAY+8/dK';
const opaqueS3VersionAtByteLimit = `${opaqueS3Version}${'x'.repeat(1024 - Buffer.byteLength(opaqueS3Version, 'utf8'))}`;
const oversizedS3Version = `${opaqueS3Version}${'x'.repeat(1025 - Buffer.byteLength(opaqueS3Version, 'utf8'))}`;
const multibyteOversizedS3Version = '😀'.repeat(257);
const controlledS3Version = `${opaqueS3Version}\ncontrol`;
assert.equal(Buffer.byteLength(opaqueS3VersionAtByteLimit, 'utf8'), 1024);
assert.equal(Buffer.byteLength(oversizedS3Version, 'utf8'), 1025);
assert.equal(Buffer.byteLength(multibyteOversizedS3Version, 'utf8'), 1028);

async function withOperator(work) {
  await bootstrapPool.query('SET ROLE roomscan_operator');
  try {
    return await work();
  } finally {
    await bootstrapPool.query('RESET ROLE');
  }
}

async function setHostedFlags(workspaceId, label, setGlobal = false) {
  await withOperator(async () => {
    if (setGlobal) {
      await bootstrapPool.query(
        `SELECT * FROM roomscan.set_operational_flag(
           'global', NULL::uuid, 'hosted_operations_enabled', true, NULL,
           'slice 5 project-sync integration', $1, $2::timestamptz
         )`,
        [`ofaud_${label}_global`, now],
      );
    }
    await bootstrapPool.query(
      `SELECT * FROM roomscan.set_operational_flag(
         'workspace', $1::uuid, 'hosted_operations_enabled', true, NULL,
         'slice 5 project-sync integration', $2, $3::timestamptz
       )`,
      [workspaceId, `ofaud_${label}_workspace`, now],
    );
  });
}

async function activateQuotaPolicy(workspaceId) {
  await withOperator(() => bootstrapPool.query(
    `SELECT * FROM roomscan.activate_quota_policy_v2(
       $1::uuid, $2::bigint, 'roomscan-quota-policy-v1', 'test-only',
       'roomscan-period-v1:slice5', 20, 20, 2000000, 2000000, 2000000,
       80, $3::bigint, $4::bigint, $5::timestamptz
     )`,
    [workspaceId, quotaPolicyVersion, globalHostedVersion, workspaceHostedVersion, now],
  ));
}

async function activateLargeProjectSyncQuotaPolicy(workspaceId) {
  await withOperator(() => bootstrapPool.query(
    `SELECT * FROM roomscan.activate_quota_policy_v2(
       $1::uuid, 2::bigint, 'roomscan-quota-policy-v1', 'test-only',
       'roomscan-period-v1:slice5-large', 20, 20, 300000000, 300000000, 2000000,
       80, $2::bigint, $3::bigint, $4::timestamptz
     )`,
    [workspaceId, globalHostedVersion, workspaceHostedVersion, now],
  ));
}

async function insertAccess({ principalId, workspaceId, role, label, familySuffix }) {
  const membership = (await bootstrapPool.query(
    `SELECT authorization_version FROM roomscan.memberships
      WHERE workspace_id = $1::uuid AND principal_id = $2::uuid`,
    [workspaceId, principalId],
  )).rows[0];
  const familyId = `69000000-0000-4000-8000-${familySuffix}`;
  const accessHash = digest(`access:${label}`);
  await bootstrapPool.query(
    `INSERT INTO roomscan.auth_session_families (
       id, public_id, principal_id, authentication_epoch, authenticated_at,
       last_used_at, inactivity_expires_at, absolute_expires_at,
       policy_version, workspace_id, role, authorization_version, state, created_at
     ) VALUES (
       $1::uuid, $2, $3::uuid, 0, $4::timestamptz, $4::timestamptz,
       $4::timestamptz + interval '1 day', $4::timestamptz + interval '7 days',
       'session-v1', $5::uuid, $6, $7::bigint, 'active', $4::timestamptz
     )`,
    [familyId, `fam_slice5_${label}`, principalId, now, workspaceId, role, membership.authorization_version],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.auth_access_tokens (
       id, family_id, token_hash, expires_at, principal_id, authentication_epoch,
       authenticated_at, issued_at, workspace_id, role, authorization_version,
       state, created_at
     ) VALUES (
       gen_random_uuid(), $1::uuid, $2::bytea, $3::timestamptz + interval '1 day',
       $4::uuid, 0, $3::timestamptz, $3::timestamptz, $5::uuid, $6,
       $7::bigint, 'active', $3::timestamptz
     )`,
    [familyId, accessHash, now, principalId, workspaceId, role, membership.authorization_version],
  );
  return accessHash;
}

function migrationArgs({
  access,
  sourceProjectId,
  proposedRevisionId,
  label,
  bytes = 101,
  policyVersion = quotaPolicyVersion,
}) {
  return [
    access,
    now,
    sourceProjectId,
    proposedRevisionId,
    digest(`${label}:manifest`),
    digest(`${label}:archive`),
    bytes,
    digest(`${label}:idempotency`),
    policyVersion,
    globalHostedVersion,
    workspaceHostedVersion,
  ];
}

async function allocateMigration(pool, input) {
  return (await pool.query(
    `SELECT * FROM roomscan.allocate_project_migration_v1(
       $1::bytea, $2::timestamptz, $3::text, $4::text, $5::bytea, $6::bytea,
       $7::bigint, $8::bytea, $9::bigint, $10::bigint, $11::bigint
     )`,
    migrationArgs(input),
  )).rows[0];
}

async function allocateAppend(pool, {
  access,
  projectPublicId,
  expectedHeadPublicId,
  expectedHeadSourceRevisionId,
  proposedRevisionId,
  label,
  bytes = 111,
  policyVersion = quotaPolicyVersion,
}) {
  return (await pool.query(
    `SELECT * FROM roomscan.allocate_project_revision_v1(
       $1::bytea, $2::timestamptz, $3::text, $4::text, $5::text, $6::text,
       $7::bytea, $8::bytea, $9::bigint, $10::bytea, $11::bigint,
       $12::bigint, $13::bigint
     )`,
    [
      access, now, projectPublicId, expectedHeadPublicId, expectedHeadSourceRevisionId,
      proposedRevisionId, digest(`${label}:manifest`), digest(`${label}:archive`), bytes,
      digest(`${label}:idempotency`), policyVersion, globalHostedVersion, workspaceHostedVersion,
    ],
  )).rows[0];
}

async function complete(pool, access, uploadPublicId, at = now) {
  return (await pool.query(
    'SELECT * FROM roomscan.complete_project_upload_v1($1::bytea, $2::timestamptz, $3::text)',
    [access, at, uploadPublicId],
  )).rows[0];
}

async function status(pool, access, uploadPublicId, at = now) {
  return (await pool.query(
    'SELECT * FROM roomscan.read_project_upload_status_v1($1::bytea, $2::timestamptz, $3::text)',
    [access, at, uploadPublicId],
  )).rows[0];
}

async function claim(workerPool, at = now) {
  return (await workerPool.query(
    'SELECT * FROM roomscan.claim_next_project_validation_v1($1::timestamptz)', [at],
  )).rows[0];
}

async function finalize(workerPool, claimRow, label, at = now, versions = {
  quarantineVersion: `qv_${label}`,
  activeObjectVersion: `av_${label}`,
}) {
  return (await workerPool.query(
    `SELECT * FROM roomscan.finalize_project_upload_v1(
       $1::uuid, $2::text, $3::timestamptz, $4::text, $5::text
     )`,
    [claimRow.upload_id, claimRow.lease_id, at, versions.quarantineVersion, versions.activeObjectVersion],
  )).rows[0];
}

async function release(workerPool, claimRow, at = now) {
  return (await workerPool.query(
    'SELECT * FROM roomscan.release_project_upload_v1($1::uuid, $2::text, $3::timestamptz)',
    [claimRow.upload_id, claimRow.lease_id, at],
  )).rows[0];
}

async function reject(workerPool, claimRow, at = now) {
  return (await workerPool.query(
    `SELECT * FROM roomscan.reject_project_upload_v1(
       $1::uuid, $2::text, $3::timestamptz, 'invalid_archive'
     )`,
    [claimRow.upload_id, claimRow.lease_id, at],
  )).rows[0];
}

async function configureRaw(pool, access, projectPublicId, reviewDigest) {
  return (await pool.query(
    `SELECT * FROM roomscan.configure_project_raw_archive_v1(
       $1::bytea, $2::timestamptz, $3::text, $4::bytea, $5::bigint, $6::bigint
     )`,
    [access, now, projectPublicId, reviewDigest, globalHostedVersion, workspaceHostedVersion],
  )).rows[0];
}

async function allocateRaw(pool, {
  access,
  projectPublicId,
  revisionPublicId,
  reviewDigest,
  label,
  bytes = 77,
  policyVersion = quotaPolicyVersion,
}) {
  return (await pool.query(
    `SELECT * FROM roomscan.allocate_project_raw_archive_v1(
       $1::bytea, $2::timestamptz, $3::text, $4::text, $5::bytea, $6::bytea,
       $7::bigint, $8::bytea, $9::bytea, $10::bigint, $11::bigint, $12::bigint
     )`,
    [
      access, now, projectPublicId, revisionPublicId, digest(`${label}:manifest`),
      digest(`${label}:archive`), bytes, reviewDigest, digest(`${label}:idempotency`),
      policyVersion, globalHostedVersion, workspaceHostedVersion,
    ],
  )).rows[0];
}

async function resolveRecoveryStorage(pool, {
  access,
  projectPublicId,
  revisionPublicId = null,
  at = now,
}) {
  return (await pool.query(
    `SELECT * FROM roomscan.resolve_project_recovery_storage_v1(
       $1::bytea, $2::timestamptz, $3::text, $4::text
     )`,
    [access, at, projectPublicId, revisionPublicId],
  )).rows;
}

async function acquireLease(pool, {
  access,
  projectPublicId,
  deviceLabel,
  requestLabel,
  tokenLabel,
  at = now,
}) {
  return (await pool.query(
    `SELECT * FROM roomscan.acquire_project_edit_lease_v1(
       $1::bytea, $2::timestamptz, $3::text, $4::bytea, $5::bytea, $6::bytea,
       $7::bigint, $8::bigint
     )`,
    [
      access, at, projectPublicId, digest(deviceLabel), digest(requestLabel), digest(tokenLabel),
      globalHostedVersion, workspaceHostedVersion,
    ],
  )).rows[0];
}

async function renewLease(pool, { access, projectPublicId, tokenLabel, at = now }) {
  return (await pool.query(
    `SELECT * FROM roomscan.renew_project_edit_lease_v1(
       $1::bytea, $2::timestamptz, $3::text, $4::bytea, $5::bigint, $6::bigint
     )`,
    [access, at, projectPublicId, digest(tokenLabel), globalHostedVersion, workspaceHostedVersion],
  )).rows[0];
}

async function releaseLease(pool, { access, projectPublicId, tokenLabel, at = now }) {
  return (await pool.query(
    `SELECT * FROM roomscan.release_project_edit_lease_v1(
       $1::bytea, $2::timestamptz, $3::text, $4::bytea, $5::bigint, $6::bigint
     )`,
    [access, at, projectPublicId, digest(tokenLabel), globalHostedVersion, workspaceHostedVersion],
  )).rows[0];
}

async function quota(workspaceId, metric) {
  return (await bootstrapPool.query(
    `SELECT used, reserved FROM roomscan.quota_usage_v2
      WHERE workspace_id = $1::uuid AND metric = $2::roomscan.quota_metric
        AND period_key = 'roomscan-period-v1:lifetime'`,
    [workspaceId, metric],
  )).rows[0];
}

function assertPublicOnly(result, allowedFields) {
  assert.deepEqual(Object.keys(result).sort(), [...allowedFields].sort());
  for (const forbidden of [
    'id', 'upload_id', 'project_id', 'revision_id', 'quarantine_key',
    'active_object_key', 'object_version', 'working_object_key', 'working_object_version',
    'quarantine_version', 'active_object_version', 'project_source_project_id',
    'archive_source_revision_id',
  ]) {
    assert.equal(Object.hasOwn(result, forbidden), false, `public reducer leaked ${forbidden}`);
  }
}

try {
  const applied = await applyMigrations({
    pool: bootstrapPool,
    ...(process.env.ROOMSCAN_TEST_MIGRATIONS_DIR
      ? { migrationsDir: process.env.ROOMSCAN_TEST_MIGRATIONS_DIR }
      : {}),
  });
  assert.equal(applied.applied.at(-1)?.version, '0009', 'forward 0009 publication migration must preserve the 0008 project-sync contract');
  await seedCoreFixtures(bootstrapPool);
  await setHostedFlags(ids.workspaceA, 'slice5a', true);
  await setHostedFlags(ids.workspaceB, 'slice5b');
  await activateQuotaPolicy(ids.workspaceA);
  await activateQuotaPolicy(ids.workspaceB);
  await activateLargeProjectSyncQuotaPolicy(ids.workspaceB);

  const accessOwnerA = await insertAccess({
    principalId: ids.principalA, workspaceId: ids.workspaceA, role: 'owner',
    label: 'owner_a', familySuffix: '000000000201',
  });
  const accessEditorA = await insertAccess({
    principalId: ids.principalMember, workspaceId: ids.workspaceA, role: 'editor',
    label: 'editor_a', familySuffix: '000000000202',
  });
  const accessOwnerB = await insertAccess({
    principalId: ids.principalB, workspaceId: ids.workspaceB, role: 'owner',
    label: 'owner_b', familySuffix: '000000000203',
  });

  apiPoolA = new Pool({
    ...appPoolConfig(cluster, 2), user: 'roomscan_api_runtime', max: 2,
    application_name: 'rss-0008-client-a',
  });
  apiPoolB = new Pool({
    ...appPoolConfig(cluster, 2), user: 'roomscan_api_runtime', max: 2,
    application_name: 'rss-0008-client-b',
  });
  workerPoolA = new Pool({
    ...appPoolConfig(cluster, 2), user: 'roomscan_project_sync_runtime', max: 2,
    application_name: 'rss-0008-worker-a',
  });
  workerPoolB = new Pool({
    ...appPoolConfig(cluster, 2), user: 'roomscan_project_sync_runtime', max: 2,
    application_name: 'rss-0008-worker-b',
  });

  // A migration is staged and quota-reserved, but cannot create a hosted shell
  // until the targetless validator finalizes it.
  const initialInput = {
    access: accessOwnerA,
    sourceProjectId: 'source_project_alpha',
    proposedRevisionId: 'source_revision_initial',
    label: 'initial',
    bytes: 101,
  };
  const initial = await allocateMigration(apiPoolA, initialInput);
  assertPublicOnly(initial, [
    'status', 'project_public_id', 'upload_public_id', 'candidate_revision_public_id',
    'working_manifest_digest', 'working_digest', 'working_bytes', 'allocation_expires_at',
  ]);
  assert.equal(initial.status, 'allocated');
  assert.match(initial.project_public_id, /^prj_[A-Za-z0-9_-]{16,128}$/u);
  assert.match(initial.upload_public_id, /^upl_[A-Za-z0-9_-]{16,128}$/u);
  assert.match(initial.candidate_revision_public_id, /^rev_[A-Za-z0-9_-]{16,128}$/u);
  assert.equal(asNumber(initial.working_bytes), 101);
  assert.equal((await bootstrapPool.query(
    'SELECT count(*)::integer AS count FROM roomscan.projects',
  )).rows[0].count, 2, 'allocation must not create a generic project shell');
  assert.equal((await bootstrapPool.query(
    'SELECT count(*)::integer AS count FROM roomscan.professional_projects',
  )).rows[0].count, 0, 'allocation must not create a professional project shell');
  assert.deepEqual(
    await allocateMigration(apiPoolA, initialInput),
    initial,
    'exact migration retry must return the original opaque allocation',
  );
  await assert.rejects(
    () => allocateMigration(apiPoolA, { ...initialInput, bytes: 102 }),
    (error) => error?.code === 'P0001' && error?.message === 'PROJECT_SYNC_IDEMPOTENCY_REUSED',
  );
  assert.deepEqual(await quota(ids.workspaceA, 'project_count'), { used: '0', reserved: '1' });
  assert.deepEqual(await quota(ids.workspaceA, 'working_bytes'), { used: '0', reserved: '101' });

  assert.equal(await claim(workerPoolA), undefined, 'allocated bytes must be unclaimable');
  assert.equal((await complete(apiPoolA, accessOwnerA, initial.upload_public_id)).status, 'validation_pending');
  const initialClaim = await claim(workerPoolA);
  assert.ok(initialClaim?.upload_id, 'completed allocation must be targetlessly claimable');
  assert.equal(initialClaim.quarantine_key.includes(initial.upload_public_id), true);
  assert.equal(initialClaim.project_source_project_id, initialInput.sourceProjectId,
    'initial claims must retain the immutable staged source that becomes the professional project source');
  assert.equal(initialClaim.archive_source_revision_id, initialInput.proposedRevisionId,
    'initial claims must give the validator the immutable candidate source revision');
  const initialVersions = {
    quarantineVersion: opaqueS3VersionAtByteLimit,
    activeObjectVersion: opaqueS3Version,
  };
  const initialFinal = await finalize(workerPoolA, initialClaim, 'initial', now, initialVersions);
  assert.equal(initialFinal.status, 'canonical');
  assert.equal(initialFinal.current_hosted_head_revision_public_id, initial.candidate_revision_public_id);
  assertPublicOnly(await status(apiPoolA, accessOwnerA, initial.upload_public_id), [
    'status', 'project_public_id', 'upload_public_id', 'candidate_revision_public_id',
    'current_hosted_head_revision_public_id', 'working_digest', 'working_bytes',
    'raw_digest', 'raw_bytes', 'allocation_expires_at',
  ]);
  assert.deepEqual(await quota(ids.workspaceA, 'project_count'), { used: '1', reserved: '0' });
  assert.deepEqual(await quota(ids.workspaceA, 'working_bytes'), { used: '101', reserved: '0' });
  assert.equal((await bootstrapPool.query(
    `SELECT count(*)::integer AS count FROM roomscan.professional_projects
      WHERE public_id = $1`, [initial.project_public_id],
  )).rows[0].count, 1);
  assert.equal((await bootstrapPool.query(
    `SELECT source_project_id FROM roomscan.professional_projects
      WHERE workspace_id = $1::uuid AND public_id = $2`,
    [ids.workspaceA, initial.project_public_id],
  )).rows[0].source_project_id, initialClaim.project_source_project_id,
  'initial staged source must become the authoritative professional project source at finalization');
  assert.deepEqual((await bootstrapPool.query(
    `SELECT upload.quarantine_version, upload.active_object_version,
            revision.working_object_version
       FROM roomscan.project_uploads AS upload
       JOIN roomscan.project_revisions AS revision
         ON revision.workspace_id = upload.workspace_id
        AND revision.id = upload.target_revision_id
      WHERE upload.workspace_id = $1::uuid AND upload.public_id = $2`,
    [ids.workspaceA, initial.upload_public_id],
  )).rows[0], {
    quarantine_version: opaqueS3VersionAtByteLimit,
    active_object_version: opaqueS3Version,
    working_object_version: opaqueS3Version,
  }, 'working promotion must preserve exact opaque provider VersionIds containing plus and slash');

  // The service, provider, and database share one operational archive ceiling.
  // Workspace B has a deliberately larger test-only quota so this asserts the
  // admission boundary itself rather than a quota-side rejection.
  const capMigration = await allocateMigration(apiPoolB, {
    access: accessOwnerB,
    sourceProjectId: 'source_project_64mib',
    proposedRevisionId: 'source_revision_64mib_initial',
    label: '64mib-migration',
    bytes: projectSyncMaxArchiveBytes,
    policyVersion: 2,
  });
  assert.equal(asNumber(capMigration.working_bytes), projectSyncMaxArchiveBytes,
    'exactly 64 MiB is accepted by the migration allocator');
  await complete(apiPoolB, accessOwnerB, capMigration.upload_public_id);
  const capMigrationClaim = await claim(workerPoolB);
  assert.ok(capMigrationClaim, 'the 64 MiB migration remains claimable');
  assert.equal((await finalize(workerPoolB, capMigrationClaim, '64mib-migration')).status, 'canonical');

  const capAppend = await allocateAppend(apiPoolB, {
    access: accessOwnerB,
    projectPublicId: capMigration.project_public_id,
    expectedHeadPublicId: capMigration.candidate_revision_public_id,
    expectedHeadSourceRevisionId: 'source_revision_64mib_initial',
    proposedRevisionId: 'source_revision_64mib_append',
    label: '64mib-append',
    bytes: projectSyncMaxArchiveBytes,
    policyVersion: 2,
  });
  assert.equal(asNumber(capAppend.working_bytes), projectSyncMaxArchiveBytes,
    'exactly 64 MiB is accepted by the immutable append allocator');

  const capRawReview = digest('64mib-raw-review');
  await configureRaw(apiPoolB, accessOwnerB, capMigration.project_public_id, capRawReview);
  const capRaw = await allocateRaw(apiPoolB, {
    access: accessOwnerB,
    projectPublicId: capMigration.project_public_id,
    revisionPublicId: capMigration.candidate_revision_public_id,
    reviewDigest: capRawReview,
    label: '64mib-raw',
    bytes: projectSyncMaxArchiveBytes,
    policyVersion: 2,
  });
  assert.equal(asNumber(capRaw.raw_bytes), projectSyncMaxArchiveBytes,
    'exactly 64 MiB is accepted by the raw-archive allocator');
  await complete(apiPoolB, accessOwnerB, capRaw.upload_public_id);
  assert.equal((await status(apiPoolB, accessOwnerB, capRaw.upload_public_id)).candidate_revision_public_id,
    capMigration.candidate_revision_public_id,
    'raw upload status exposes the persisted target revision public ID');
  const capRawClaim = await claim(workerPoolB);
  assert.ok(capRawClaim, 'the 64 MiB raw archive remains claimable');
  assert.equal((await finalize(workerPoolB, capRawClaim, '64mib-raw')).status, 'attached');
  await complete(apiPoolB, accessOwnerB, capAppend.upload_public_id);
  const capAppendClaim = await claim(workerPoolB);
  assert.ok(capAppendClaim, 'the 64 MiB append remains claimable');
  assert.equal((await finalize(workerPoolB, capAppendClaim, '64mib-append')).status, 'canonical');

  await assert.rejects(
    () => allocateMigration(apiPoolB, {
      access: accessOwnerB, sourceProjectId: 'source_project_64mib_over',
      proposedRevisionId: 'source_revision_64mib_over', label: '64mib-migration-over',
      bytes: projectSyncMaxArchiveBytes + 1, policyVersion: 2,
    }),
    (error) => error?.code === '22023' && error?.message === 'INVALID_PROJECT_SYNC_MIGRATION_INPUT',
    '64 MiB + 1 must fail before migration quota reservation',
  );
  await assert.rejects(
    () => allocateAppend(apiPoolB, {
      access: accessOwnerB, projectPublicId: capMigration.project_public_id,
      expectedHeadPublicId: capMigration.candidate_revision_public_id,
      expectedHeadSourceRevisionId: 'source_revision_64mib_initial',
      proposedRevisionId: 'source_revision_64mib_append_over', label: '64mib-append-over',
      bytes: projectSyncMaxArchiveBytes + 1, policyVersion: 2,
    }),
    (error) => error?.code === '22023' && error?.message === 'INVALID_PROJECT_SYNC_REVISION_INPUT',
    '64 MiB + 1 must fail before append quota reservation',
  );
  await assert.rejects(
    () => allocateRaw(apiPoolB, {
      access: accessOwnerB, projectPublicId: capMigration.project_public_id,
      revisionPublicId: capMigration.candidate_revision_public_id,
      reviewDigest: capRawReview, label: '64mib-raw-over',
      bytes: projectSyncMaxArchiveBytes + 1, policyVersion: 2,
    }),
    (error) => error?.code === '22023' && error?.message === 'INVALID_PROJECT_SYNC_RAW_ALLOCATION_INPUT',
    '64 MiB + 1 must fail before raw quota reservation',
  );
  for (const write of [
    {
      statement: `UPDATE roomscan.project_revisions SET working_bytes = $1
                   WHERE workspace_id = $2::uuid AND public_id = $3`,
      values: [projectSyncMaxArchiveBytes + 1, ids.workspaceB, capMigration.candidate_revision_public_id],
    },
    {
      statement: `UPDATE roomscan.project_uploads SET working_bytes = $1
                   WHERE workspace_id = $2::uuid AND public_id = $3`,
      values: [projectSyncMaxArchiveBytes + 1, ids.workspaceB, capAppend.upload_public_id],
    },
    {
      statement: `UPDATE roomscan.project_uploads SET raw_bytes = $1
                   WHERE workspace_id = $2::uuid AND public_id = $3`,
      values: [projectSyncMaxArchiveBytes + 1, ids.workspaceB, capRaw.upload_public_id],
    },
    {
      statement: `UPDATE roomscan.project_raw_archives SET archive_bytes = $1
                   WHERE workspace_id = $2::uuid AND revision_id = (
                     SELECT id FROM roomscan.project_revisions
                     WHERE workspace_id = $2::uuid AND public_id = $3
                   )`,
      values: [projectSyncMaxArchiveBytes + 1, ids.workspaceB, capMigration.candidate_revision_public_id],
    },
  ]) {
    await assert.rejects(
      () => bootstrapPool.query(write.statement, write.values),
      (error) => error?.code === '23514',
      'persistent project-sync archive records must enforce the same 64 MiB ceiling',
    );
  }

  // A worker must never validate a descriptor against a caller-supplied or
  // mismatched project binding.  The targetless claim locks the upload, then
  // fails closed if its public project binding does not resolve to the same
  // authoritative professional-project row.
  const inconsistentBinding = await allocateAppend(apiPoolA, {
    access: accessOwnerA,
    projectPublicId: initial.project_public_id,
    expectedHeadPublicId: initial.candidate_revision_public_id,
    expectedHeadSourceRevisionId: initialInput.proposedRevisionId,
    proposedRevisionId: 'source_revision_inconsistent_binding',
    label: 'inconsistent-binding',
  });
  await complete(apiPoolA, accessOwnerA, inconsistentBinding.upload_public_id);
  await bootstrapPool.query(
    `UPDATE roomscan.project_uploads
        SET project_public_id = $1
      WHERE workspace_id = $2::uuid AND public_id = $3`,
    [`prj_${'z'.repeat(16)}`, ids.workspaceA, inconsistentBinding.upload_public_id],
  );
  await assert.rejects(
    () => claim(workerPoolA),
    (error) => error?.code === 'P0001' && error?.message === 'PROJECT_SYNC_CLAIM_SOURCE_BINDING_INVALID',
    'a mismatched uploaded project binding must fail closed before the worker receives source identifiers',
  );
  assert.deepEqual((await bootstrapPool.query(
    `SELECT state, lease_id, lease_expires_at
       FROM roomscan.project_uploads
      WHERE workspace_id = $1::uuid AND public_id = $2`,
    [ids.workspaceA, inconsistentBinding.upload_public_id],
  )).rows[0], {
    state: 'validation_pending', lease_id: null, lease_expires_at: null,
  }, 'a rejected claim transaction must not lease or mutate an inconsistent upload');
  await bootstrapPool.query(
    `UPDATE roomscan.project_uploads
        SET project_public_id = $1
      WHERE workspace_id = $2::uuid AND public_id = $3`,
    [initial.project_public_id, ids.workspaceA, inconsistentBinding.upload_public_id],
  );
  const repairedBindingClaim = await claim(workerPoolA);
  assert.equal(repairedBindingClaim.project_source_project_id, initialInput.sourceProjectId,
    'a repaired append claim must derive project source from the authoritative professional project');
  assert.equal(repairedBindingClaim.archive_source_revision_id, 'source_revision_inconsistent_binding',
    'a repaired append claim must retain its immutable candidate source revision');
  assert.equal((await reject(workerPoolA, repairedBindingClaim)).status, 'rejected');

  // Provider VersionIds are opaque S3 text, bounded by UTF-8 bytes rather
  // than an invented character alphabet or character count.  Finalization
  // rejects byte-over-limit and control values before it can mutate a claim.
  const versionInputGuard = await allocateAppend(apiPoolA, {
    access: accessOwnerA,
    projectPublicId: initial.project_public_id,
    expectedHeadPublicId: initial.candidate_revision_public_id,
    expectedHeadSourceRevisionId: initialInput.proposedRevisionId,
    proposedRevisionId: 'source_revision_version_input_guard',
    label: 'version-input-guard',
  });
  await complete(apiPoolA, accessOwnerA, versionInputGuard.upload_public_id);
  const versionInputGuardClaim = await claim(workerPoolA);
  for (const invalidVersion of [oversizedS3Version, multibyteOversizedS3Version, controlledS3Version]) {
    await assert.rejects(
      () => finalize(workerPoolA, versionInputGuardClaim, 'version-input-guard', now, {
        quarantineVersion: invalidVersion,
        activeObjectVersion: opaqueS3Version,
      }),
      (error) => error?.code === '22023' && error?.message === 'INVALID_PROJECT_SYNC_FINALIZATION_INPUT',
      'worker finalization must reject invalid opaque provider VersionId input before promotion',
    );
  }
  assert.deepEqual((await bootstrapPool.query(
    `SELECT state, quarantine_version, active_object_version
       FROM roomscan.project_uploads
      WHERE workspace_id = $1::uuid AND public_id = $2`,
    [ids.workspaceA, versionInputGuard.upload_public_id],
  )).rows[0], {
    state: 'validating', quarantine_version: null, active_object_version: null,
  }, 'invalid finalizer VersionIds must leave the claimed upload unpromoted');
  assert.equal((await reject(workerPoolA, versionInputGuardClaim)).status, 'rejected');

  // Two independently authenticated logical clients start from exactly the
  // same hosted head.  Targetless workers finalize concurrently: one CAS wins
  // and the other immutable revision remains a stale, recoverable branch.
  const appendA = await allocateAppend(apiPoolA, {
    access: accessOwnerA,
    projectPublicId: initial.project_public_id,
    expectedHeadPublicId: initial.candidate_revision_public_id,
    expectedHeadSourceRevisionId: initialInput.proposedRevisionId,
    proposedRevisionId: 'source_revision_client_a',
    label: 'append-a',
    bytes: 111,
  });
  const appendB = await allocateAppend(apiPoolB, {
    access: accessEditorA,
    projectPublicId: initial.project_public_id,
    expectedHeadPublicId: initial.candidate_revision_public_id,
    expectedHeadSourceRevisionId: initialInput.proposedRevisionId,
    proposedRevisionId: 'source_revision_client_b',
    label: 'append-b',
    bytes: 112,
  });
  assert.equal(appendA.status, 'allocated');
  assert.equal(appendB.status, 'allocated');
  await complete(apiPoolA, accessOwnerA, appendA.upload_public_id);
  await complete(apiPoolB, accessEditorA, appendB.upload_public_id);
  const claimA = await claim(workerPoolA);
  const claimB = await claim(workerPoolB);
  assert.notEqual(claimA.upload_id, claimB.upload_id, 'targetless claims must select two distinct completed uploads');
  const appendSourceByCandidatePublicId = new Map([
    [appendA.candidate_revision_public_id, 'source_revision_client_a'],
    [appendB.candidate_revision_public_id, 'source_revision_client_b'],
  ]);
  for (const appendClaim of [claimA, claimB]) {
    assert.equal(appendClaim.project_source_project_id, initialInput.sourceProjectId,
      'append claims must derive the professional project source instead of a public ID');
    assert.equal(appendClaim.archive_source_revision_id,
      appendSourceByCandidatePublicId.get(appendClaim.candidate_revision_public_id),
      'append claims must retain their immutable candidate source revision');
  }
  const finalizations = await Promise.all([
    finalize(workerPoolA, claimA, 'append-a'),
    finalize(workerPoolB, claimB, 'append-b'),
  ]);
  const canonical = finalizations.find((row) => row.status === 'canonical');
  const stale = finalizations.find((row) => row.status === 'stale');
  assert.ok(canonical, 'one expected-head append must become canonical');
  assert.ok(stale, 'the stale expected-head append must be retained as stale');
  assert.equal(canonical.current_hosted_head_revision_public_id, canonical.candidate_revision_public_id);
  assert.equal(stale.current_hosted_head_revision_public_id, canonical.candidate_revision_public_id);
  const branchRows = (await bootstrapPool.query(
    `SELECT public_id, branch_state
       FROM roomscan.project_revisions
      WHERE workspace_id = $1::uuid
      ORDER BY public_id`,
    [ids.workspaceA],
  )).rows;
  assert.equal(branchRows.filter(({ branch_state }) => branch_state === 'canonical').length, 2);
  assert.equal(branchRows.filter(({ branch_state }) => branch_state === 'stale').length, 1);
  assert.equal(branchRows.some(({ public_id }) => public_id === stale.candidate_revision_public_id), true);
  const staleRecovery = (await apiPoolB.query(
    `SELECT * FROM roomscan.allocate_project_recovery_v1(
       $1::bytea, $2::timestamptz, $3::text, $4::text
     )`,
    [accessEditorA, now, initial.project_public_id, stale.candidate_revision_public_id],
  )).rows[0];
  assertPublicOnly(staleRecovery, [
    'project_public_id', 'target_revision_public_id', 'branch_state',
    'working_manifest_digest', 'working_digest', 'working_bytes',
  ]);
  assert.equal(staleRecovery.branch_state, 'stale');
  assert.equal(staleRecovery.target_revision_public_id, stale.candidate_revision_public_id);

  // Two independently authenticated clients race to attach reviewed raw bytes
  // to the same branch.  Only one nonterminal row may reserve quota; the other
  // gets a deterministic conflict before reservation and cannot later collide
  // with the raw-archive primary key during finalization.
  const rawReview = digest('raw-review');
  const rawConfig = await configureRaw(apiPoolA, accessOwnerA, initial.project_public_id, rawReview);
  assert.equal(rawConfig.raw_archive_enabled, true);
  const inconsistentRawBinding = await allocateRaw(apiPoolA, {
    access: accessOwnerA,
    projectPublicId: initial.project_public_id,
    revisionPublicId: stale.candidate_revision_public_id,
    reviewDigest: rawReview,
    label: 'inconsistent-raw-binding',
  });
  await complete(apiPoolA, accessOwnerA, inconsistentRawBinding.upload_public_id);
  await bootstrapPool.query(
    `UPDATE roomscan.project_uploads
        SET target_revision_id = '77777777-7777-4777-8777-777777777777'::uuid
      WHERE workspace_id = $1::uuid AND public_id = $2`,
    [ids.workspaceA, inconsistentRawBinding.upload_public_id],
  );
  await assert.rejects(
    () => claim(workerPoolA),
    (error) => error?.code === 'P0001' && error?.message === 'PROJECT_SYNC_CLAIM_SOURCE_BINDING_INVALID',
    'a raw claim with a non-authoritative target revision binding must fail closed',
  );
  await bootstrapPool.query(
    `UPDATE roomscan.project_uploads AS upload
        SET target_revision_id = revision.id
       FROM roomscan.project_revisions AS revision
      WHERE upload.workspace_id = $1::uuid
        AND upload.public_id = $2
        AND revision.workspace_id = upload.workspace_id
        AND revision.public_id = $3`,
    [ids.workspaceA, inconsistentRawBinding.upload_public_id, stale.candidate_revision_public_id],
  );
  const repairedRawBindingClaim = await claim(workerPoolA);
  assert.equal(repairedRawBindingClaim.project_source_project_id, initialInput.sourceProjectId,
    'a repaired raw claim must derive the authoritative professional project source');
  assert.equal(repairedRawBindingClaim.archive_source_revision_id,
    appendSourceByCandidatePublicId.get(stale.candidate_revision_public_id),
    'a repaired raw claim must derive the target revision source rather than a public ID');
  assert.equal((await reject(workerPoolA, repairedRawBindingClaim)).status, 'rejected');
  const rawRaceInputs = [
    { pool: apiPoolA, access: accessOwnerA, label: 'raw-race-a' },
    { pool: apiPoolB, access: accessEditorA, label: 'raw-race-b' },
  ];
  const rawRaceResults = await Promise.allSettled(rawRaceInputs.map((input) => allocateRaw(input.pool, {
    access: input.access,
    projectPublicId: initial.project_public_id,
    revisionPublicId: stale.candidate_revision_public_id,
    reviewDigest: rawReview,
    label: input.label,
    bytes: 79,
  })));
  const rawRaceWins = rawRaceResults.filter(({ status: resultStatus }) => resultStatus === 'fulfilled');
  const rawRaceLosses = rawRaceResults.filter(({ status: resultStatus }) => resultStatus === 'rejected');
  assert.equal(rawRaceWins.length, 1, 'one same-target raw allocation must win');
  assert.equal(rawRaceLosses.length, 1, 'one same-target raw allocation must be rejected');
  assert.equal(rawRaceLosses[0].reason?.code, 'P0001');
  assert.equal(rawRaceLosses[0].reason?.message, 'RAW_ARCHIVE_UPLOAD_IN_PROGRESS');
  assert.deepEqual(await quota(ids.workspaceA, 'raw_bytes'), { used: '0', reserved: '79' },
    'a losing same-target raw allocation must not strand a second reservation');
  const rawRaceWinnerIndex = rawRaceResults.findIndex(({ status: resultStatus }) => resultStatus === 'fulfilled');
  const rawRaceWinner = rawRaceInputs[rawRaceWinnerIndex];
  const rawRace = rawRaceResults[rawRaceWinnerIndex].value;
  await assert.rejects(
    () => bootstrapPool.query(
      `INSERT INTO roomscan.project_uploads (
         workspace_id, id, public_id, project_id, project_public_id, source_project_id,
         operation, idempotency_digest, proposed_revision_id, proposed_revision_public_id,
         target_revision_id, expected_head_revision_id, expected_head_source_revision_id,
         raw_manifest_digest, raw_digest, raw_bytes, raw_review_digest, state,
         quarantine_key, active_object_key, allocation_expires_at, quota_policy_version,
         hosted_global_version, hosted_workspace_version, created_by_principal_id,
         created_at, updated_at
       )
       SELECT workspace_id, gen_random_uuid(), 'upl_rawtargetconstraint0001', project_id,
              project_public_id, source_project_id, operation, $2::bytea,
              proposed_revision_id, proposed_revision_public_id, target_revision_id,
              expected_head_revision_id, expected_head_source_revision_id,
              raw_manifest_digest, raw_digest, raw_bytes, raw_review_digest, state,
              'professional-sync/quarantine/raw/upl_rawtargetconstraint0001.zip',
              'professional-sync/active/raw/upl_rawtargetconstraint0001.zip',
              allocation_expires_at, quota_policy_version, hosted_global_version,
              hosted_workspace_version, created_by_principal_id, created_at, updated_at
         FROM roomscan.project_uploads
        WHERE workspace_id = $1::uuid AND public_id = $3`,
      [ids.workspaceA, digest('raw-target-constraint-clone'), rawRace.upload_public_id],
    ),
    (error) => error?.code === '23505',
    'the database must reject a second nonterminal raw row for the same target revision',
  );
  await complete(rawRaceWinner.pool, rawRaceWinner.access, rawRace.upload_public_id);
  const rawRaceClaim = await claim(workerPoolA);
  assert.equal(rawRaceClaim.upload_id, (await bootstrapPool.query(
    `SELECT id FROM roomscan.project_uploads
      WHERE workspace_id = $1::uuid AND public_id = $2`,
    [ids.workspaceA, rawRace.upload_public_id],
  )).rows[0].id);
  assert.equal(rawRaceClaim.project_source_project_id, initialInput.sourceProjectId,
    'raw claims must derive the authoritative professional project source');
  assert.equal(rawRaceClaim.archive_source_revision_id,
    appendSourceByCandidatePublicId.get(stale.candidate_revision_public_id),
    'raw claims must join the targeted immutable revision source rather than use a public ID');
  const rawRaceVersions = {
    quarantineVersion: opaqueS3Version,
    activeObjectVersion: opaqueS3VersionAtByteLimit,
  };
  const rawRaceFinal = await finalize(workerPoolA, rawRaceClaim, 'raw-race', now, rawRaceVersions);
  assert.equal(rawRaceFinal.status, 'attached');
  assert.equal(rawRaceFinal.current_hosted_head_revision_public_id, canonical.candidate_revision_public_id,
    'a raced raw attachment must not move the working head');
  assert.equal((await bootstrapPool.query(
    `SELECT count(*)::integer AS count FROM roomscan.project_raw_archives AS archive
      JOIN roomscan.project_revisions AS revision
        ON revision.workspace_id = archive.workspace_id AND revision.id = archive.revision_id
     WHERE archive.workspace_id = $1::uuid AND revision.public_id = $2`,
    [ids.workspaceA, stale.candidate_revision_public_id],
  )).rows[0].count, 1, 'the sole raced allocation must finalize without a raw primary-key collision');
  assert.deepEqual((await bootstrapPool.query(
    `SELECT upload.quarantine_version, upload.active_object_version,
            archive.object_version
       FROM roomscan.project_uploads AS upload
       JOIN roomscan.project_raw_archives AS archive
         ON archive.workspace_id = upload.workspace_id
        AND archive.revision_id = upload.target_revision_id
      WHERE upload.workspace_id = $1::uuid AND upload.public_id = $2`,
    [ids.workspaceA, rawRace.upload_public_id],
  )).rows[0], {
    quarantine_version: opaqueS3Version,
    active_object_version: opaqueS3VersionAtByteLimit,
    object_version: opaqueS3VersionAtByteLimit,
  }, 'raw promotion must preserve exact opaque provider VersionIds containing plus and slash');
  const invalidStoredVersionWrites = [
    {
      label: 'working revision VersionId',
      statement: `UPDATE roomscan.project_revisions
                    SET working_object_version = $1
                  WHERE workspace_id = $2::uuid AND public_id = $3`,
      values: [oversizedS3Version, ids.workspaceA, initial.candidate_revision_public_id],
    },
    {
      label: 'working revision control VersionId',
      statement: `UPDATE roomscan.project_revisions
                    SET working_object_version = $1
                  WHERE workspace_id = $2::uuid AND public_id = $3`,
      values: [controlledS3Version, ids.workspaceA, initial.candidate_revision_public_id],
    },
    {
      label: 'quarantine upload VersionId',
      statement: `UPDATE roomscan.project_uploads
                    SET quarantine_version = $1
                  WHERE workspace_id = $2::uuid AND public_id = $3`,
      values: [oversizedS3Version, ids.workspaceA, initial.upload_public_id],
    },
    {
      label: 'active upload VersionId',
      statement: `UPDATE roomscan.project_uploads
                    SET active_object_version = $1
                  WHERE workspace_id = $2::uuid AND public_id = $3`,
      values: [multibyteOversizedS3Version, ids.workspaceA, rawRace.upload_public_id],
    },
    {
      label: 'raw archive VersionId',
      statement: `UPDATE roomscan.project_raw_archives
                    SET object_version = $1
                  WHERE workspace_id = $2::uuid AND revision_id = (
                    SELECT target_revision_id FROM roomscan.project_uploads
                     WHERE workspace_id = $2::uuid AND public_id = $3
                  )`,
      values: [multibyteOversizedS3Version, ids.workspaceA, rawRace.upload_public_id],
    },
  ];
  for (const invalidWrite of invalidStoredVersionWrites) {
    await assert.rejects(
      () => bootstrapPool.query(invalidWrite.statement, invalidWrite.values),
      (error) => error?.code === '23514',
      `${invalidWrite.label} must enforce the 1024-byte opaque provider VersionId boundary`,
    );
  }
  assert.deepEqual(await quota(ids.workspaceA, 'raw_bytes'), { used: '79', reserved: '0' });
  const rawRejected = await allocateRaw(apiPoolA, {
    access: accessOwnerA,
    projectPublicId: initial.project_public_id,
    revisionPublicId: canonical.candidate_revision_public_id,
    reviewDigest: rawReview,
    label: 'raw-rejected',
    bytes: 81,
  });
  await complete(apiPoolA, accessOwnerA, rawRejected.upload_public_id);
  const rawRejectedClaim = await claim(workerPoolA);
  assert.equal((await reject(workerPoolA, rawRejectedClaim)).status, 'rejected');
  assert.deepEqual(await quota(ids.workspaceA, 'raw_bytes'), { used: '79', reserved: '0' },
    'rejected raw allocation must release its sole reservation');
  const rawCorrected = await allocateRaw(apiPoolA, {
    access: accessOwnerA,
    projectPublicId: initial.project_public_id,
    revisionPublicId: canonical.candidate_revision_public_id,
    reviewDigest: rawReview,
    label: 'raw-corrected',
    bytes: 83,
  });
  assert.equal(rawCorrected.status, 'allocated', 'a corrected raw attempt is allowed only after rejection');
  await complete(apiPoolA, accessOwnerA, rawCorrected.upload_public_id);
  const rawCorrectedClaim = await claim(workerPoolA);
  const rawFinal = await finalize(workerPoolA, rawCorrectedClaim, 'raw-corrected');
  assert.equal(rawFinal.status, 'attached');
  assert.equal(rawFinal.current_hosted_head_revision_public_id, canonical.candidate_revision_public_id);
  assert.equal((await bootstrapPool.query(
    `SELECT count(*)::integer AS count FROM roomscan.project_raw_archives AS archive
      JOIN roomscan.project_revisions AS revision
        ON revision.workspace_id = archive.workspace_id AND revision.id = archive.revision_id
     WHERE archive.workspace_id = $1::uuid AND revision.public_id = $2`,
    [ids.workspaceA, canonical.candidate_revision_public_id],
  )).rows[0].count, 1, 'the corrected raw attachment must finalize without a raw primary-key collision');
  assert.deepEqual(await quota(ids.workspaceA, 'raw_bytes'), { used: '162', reserved: '0' });

  // Recovery signing needs a separate trusted projection after the authorized
  // transaction.  It returns the exact persisted logical storage binding,
  // while the public recovery reducer remains metadata-only.
  const staleStorageRows = await resolveRecoveryStorage(apiPoolB, {
    access: accessEditorA,
    projectPublicId: initial.project_public_id,
    revisionPublicId: stale.candidate_revision_public_id,
  });
  assert.equal(staleStorageRows.length, 1, 'same-tenant recovery storage resolution must find the stale branch');
  const persistedStaleStorage = (await bootstrapPool.query(
    `SELECT project.public_id AS project_public_id,
            revision.public_id AS target_revision_public_id,
            revision.branch_state,
            revision.working_object_key,
            revision.working_object_version,
            revision.working_manifest_digest,
            revision.working_digest,
            revision.working_bytes
       FROM roomscan.professional_projects AS project
       JOIN roomscan.project_revisions AS revision
         ON revision.workspace_id = project.workspace_id
        AND revision.project_id = project.project_id
      WHERE project.workspace_id = $1::uuid
        AND project.public_id = $2
        AND revision.public_id = $3`,
    [ids.workspaceA, initial.project_public_id, stale.candidate_revision_public_id],
  )).rows[0];
  assert.deepEqual(staleStorageRows[0], persistedStaleStorage,
    'trusted recovery storage resolution must return the exact immutable persisted binding');
  assert.equal(staleStorageRows[0].working_object_version.startsWith('av_append-'), true,
    'trusted recovery storage resolution must preserve the promoted object version');
  const canonicalStorageRows = await resolveRecoveryStorage(apiPoolA, {
    access: accessOwnerA,
    projectPublicId: initial.project_public_id,
  });
  assert.deepEqual(canonicalStorageRows.map(({ target_revision_public_id, branch_state }) => ({
    target_revision_public_id, branch_state,
  })), [{
    target_revision_public_id: canonical.candidate_revision_public_id,
    branch_state: 'canonical',
  }], 'default recovery storage resolution must select only the current canonical branch');
  assert.equal((await resolveRecoveryStorage(apiPoolB, {
    access: accessOwnerB,
    projectPublicId: initial.project_public_id,
    revisionPublicId: stale.candidate_revision_public_id,
  })).length, 0, 'cross-tenant recovery storage resolution must be absent');

  // Bounded leases are advisory: only their exact token digest may renew or
  // release, and an expired holder is safely replaced at server time.
  const leaseA = await acquireLease(apiPoolA, {
    access: accessOwnerA, projectPublicId: initial.project_public_id,
    deviceLabel: 'device-a', requestLabel: 'request-a', tokenLabel: 'token-a',
  });
  assert.equal(leaseA.status, 'acquired');
  assert.equal(asNumber(new Date(leaseA.expires_at) - now), 900_000);
  assert.equal((await acquireLease(apiPoolB, {
    access: accessEditorA, projectPublicId: initial.project_public_id,
    deviceLabel: 'device-b', requestLabel: 'request-b', tokenLabel: 'token-b',
  })).status, 'held');
  assert.equal((await renewLease(apiPoolA, {
    access: accessOwnerA, projectPublicId: initial.project_public_id, tokenLabel: 'token-a',
  })).status, 'renewed');
  const takeoverTime = new Date(now.getTime() + 901_000);
  const leaseB = await acquireLease(apiPoolB, {
    access: accessEditorA, projectPublicId: initial.project_public_id,
    deviceLabel: 'device-b', requestLabel: 'request-b', tokenLabel: 'token-b', at: takeoverTime,
  });
  assert.equal(leaseB.status, 'acquired');
  assert.equal((await releaseLease(apiPoolA, {
    access: accessOwnerA, projectPublicId: initial.project_public_id,
    tokenLabel: 'token-a', at: takeoverTime,
  })).status, 'unavailable');
  assert.equal((await releaseLease(apiPoolB, {
    access: accessEditorA, projectPublicId: initial.project_public_id,
    tokenLabel: 'token-b', at: takeoverTime,
  })).status, 'released');
  const projectAuditSubjects = (await bootstrapPool.query(
    `SELECT action, subject_kind, subject_id FROM roomscan.audit_events
      WHERE action IN (
        'project_sync.raw_configured', 'project_sync.lease_acquired',
        'project_sync.lease_released'
      ) AND workspace_id = $1::uuid ORDER BY sequence`,
    [ids.workspaceA],
  )).rows;
  assert.deepEqual(projectAuditSubjects.map(({ action }) => action), [
    'project_sync.raw_configured', 'project_sync.lease_acquired',
    'project_sync.lease_acquired', 'project_sync.lease_released',
  ]);
  assert.equal(projectAuditSubjects.every(({ subject_kind, subject_id }) => (
    subject_kind === 'project_sync.project' && subject_id === initial.project_public_id
  )), true, 'project configuration and advisory lease audits must retain only the bounded public project ID');

  // Reaping acts only on incomplete allocations.  It releases both initial
  // reservations and leaves a tombstone without creating a project shell.
  const expired = await allocateMigration(apiPoolA, {
    access: accessOwnerA,
    sourceProjectId: 'source_project_expired',
    proposedRevisionId: 'source_revision_expired',
    label: 'expired',
    bytes: 91,
  });
  assert.equal(await claim(workerPoolA), undefined, 'second allocated upload must remain unclaimable');
  const reaped = (await workerPoolA.query(
    'SELECT * FROM roomscan.reap_expired_project_upload_v1($1::timestamptz)',
    [new Date(now.getTime() + 301_000)],
  )).rows[0];
  assert.equal(asNumber(reaped.reaped_count), 1);
  assert.equal((await status(apiPoolA, accessOwnerA, expired.upload_public_id, new Date(now.getTime() + 301_000))).status, 'rejected');
  assert.equal((await bootstrapPool.query(
    `SELECT count(*)::integer AS count FROM roomscan.professional_projects
      WHERE public_id = $1`, [expired.project_public_id],
  )).rows[0].count, 0, 'expired initial allocation must not create a professional shell');
  assert.deepEqual(await quota(ids.workspaceA, 'project_count'), { used: '1', reserved: '0' });

  // A crashed validator lease is reclaimable after 900 seconds, while a normal
  // release simply returns the durable row to validation_pending.
  const reclaim = await allocateAppend(apiPoolA, {
    access: accessOwnerA,
    projectPublicId: initial.project_public_id,
    expectedHeadPublicId: canonical.candidate_revision_public_id,
    expectedHeadSourceRevisionId: canonical.candidate_revision_public_id === appendA.candidate_revision_public_id
      ? 'source_revision_client_a' : 'source_revision_client_b',
    proposedRevisionId: 'source_revision_reclaim',
    label: 'reclaim',
  });
  await complete(apiPoolA, accessOwnerA, reclaim.upload_public_id);
  const reclaimFirst = await claim(workerPoolA);
  assert.equal(await claim(workerPoolB, new Date(now.getTime() + 1_000)), undefined);
  const reclaimSecond = await claim(workerPoolB, new Date(now.getTime() + 901_000));
  assert.equal(reclaimSecond.upload_id, reclaimFirst.upload_id);
  assert.notEqual(reclaimSecond.lease_id, reclaimFirst.lease_id);
  assert.equal((await release(workerPoolB, reclaimSecond, new Date(now.getTime() + 901_001))).status, 'validation_pending');

  console.log(
    'INTEGRATION_0008_PROJECT_SYNC_SUMMARY logical_clients=2 canonical_appends=1 '
      + 'stale_appends=1 preserved_branches=2 initial_shell_before_validation=0 '
      + 'exact_retry_controls=1 changed_declaration_controls=1 raw_head_moves=0 '
      + 'raw_target_race_controls=1 raw_target_constraint_controls=1 raw_corrected_attempts=1 '
      + 'recovery_storage_controls=4 source_binding_controls=8 lease_seconds=900 audit_controls=4 '
      + 'reaped_allocations=1 reclaim_controls=2 status=pass',
  );
} finally {
  await Promise.all([
    apiPoolA?.end(), apiPoolB?.end(), workerPoolA?.end(), workerPoolB?.end(),
  ]);
  await bootstrapPool.end();
  console.log(`PG_CLEANUP ${JSON.stringify(await cluster.stop())}`);
}
