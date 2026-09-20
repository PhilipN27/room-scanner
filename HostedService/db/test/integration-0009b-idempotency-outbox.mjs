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

const now = new Date('2026-08-31T14:00:00.000Z');
const digest = (label) => hash32(`slice6-correction:${label}`);

async function setOperationalFlag(scope, workspaceId, flagKey, enabled, auditId, at) {
  const existing = (await bootstrapPool.query(
    scope === 'global'
      ? `SELECT version FROM roomscan.global_operational_flags WHERE flag_key = $1::text`
      : `SELECT version FROM roomscan.workspace_operational_flags
          WHERE workspace_id = $1::uuid AND flag_key = $2::text`,
    scope === 'global' ? [flagKey] : [workspaceId, flagKey],
  )).rows[0];
  await bootstrapPool.query('SET ROLE roomscan_operator');
  try {
    await bootstrapPool.query(
      `SELECT * FROM roomscan.set_operational_flag(
         $1::text, $2::uuid, $3::text, $4::boolean, $5::bigint,
         'slice 6 correction test', $6::text, $7::timestamptz
       )`,
      [scope, workspaceId, flagKey, enabled, existing ? Number(existing.version) : null, auditId, at],
    );
  } finally {
    await bootstrapPool.query('RESET ROLE');
  }
}

async function enablePublicationFlags(at) {
  await setOperationalFlag('global', null, 'hosted_operations_enabled', true, 'ofaud_0009b_hosted_global', at);
  await setOperationalFlag('workspace', ids.workspaceA, 'hosted_operations_enabled', true, 'ofaud_0009b_hosted_workspace', at);
  await setOperationalFlag('global', null, 'publication_enabled', true, 'ofaud_0009b_publication_global', at);
  await setOperationalFlag('workspace', ids.workspaceA, 'publication_enabled', true, 'ofaud_0009b_publication_workspace', at);
}

async function currentPublicationVersions() {
  const rows = (await bootstrapPool.query(
    `SELECT 'hosted_global'::text AS name, version
       FROM roomscan.global_operational_flags
      WHERE flag_key = 'hosted_operations_enabled'
     UNION ALL
     SELECT 'hosted_workspace'::text, version
       FROM roomscan.workspace_operational_flags
      WHERE workspace_id = $1::uuid AND flag_key = 'hosted_operations_enabled'
     UNION ALL
     SELECT 'publication_global'::text, version
       FROM roomscan.global_operational_flags
      WHERE flag_key = 'publication_enabled'
     UNION ALL
     SELECT 'publication_workspace'::text, version
       FROM roomscan.workspace_operational_flags
      WHERE workspace_id = $1::uuid AND flag_key = 'publication_enabled'`,
    [ids.workspaceA],
  )).rows;
  assert.equal(rows.length, 4, 'test fixture must have all live publication flag epochs');
  return Object.fromEntries(rows.map(({ name, version }) => [name, Number(version)]));
}

async function activateQuota(at) {
  const versions = await currentPublicationVersions();
  await bootstrapPool.query('SET ROLE roomscan_operator');
  try {
    await bootstrapPool.query(
      `SELECT * FROM roomscan.activate_quota_policy_v2(
        $1::uuid, 1, 'roomscan-quota-policy-v1', 'test-only',
        'roomscan-period-v1:0009b', 10, 10, 1000000, 1000000, 1000000,
        80, $2::bigint, $3::bigint, $4::timestamptz
      )`,
      [ids.workspaceA, versions.hosted_global, versions.hosted_workspace, at],
    );
  } finally {
    await bootstrapPool.query('RESET ROLE');
  }
}

async function seedCanonicalPublicationSource(at) {
  const projectPublicID = 'prj_correctionproject0001';
  const revisionPublicID = 'rev_correctionrevision001';
  const revisionID = '61000000-0000-4000-8000-000000000001';
  const sourceDigest = digest('source-archive');
  const sourceManifestDigest = digest('source-manifest');
  await bootstrapPool.query(
    `INSERT INTO roomscan.professional_projects (
       workspace_id, project_id, public_id, source_project_id, head_revision_id,
       raw_archive_enabled, version, created_at, updated_at
     ) VALUES ($1::uuid, $2::uuid, $3::text, 'source-project-0009b', NULL,
       false, 1, $4::timestamptz, $4::timestamptz)`,
    [ids.workspaceA, ids.projectA, projectPublicID, at],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.project_revisions (
       workspace_id, id, public_id, project_id, source_revision_id,
       branch_state, working_object_key, working_object_version,
       working_digest, working_bytes, working_manifest_digest, created_at
     ) VALUES ($1::uuid, $2::uuid, $3::text, $4::uuid, 'source-revision-0009b',
       'canonical', 'professional-sync/active/working/' || $3 || '.zip', 'source-version-0009b',
       $5::bytea, 2048, $6::bytea, $7::timestamptz)`,
    [ids.workspaceA, revisionID, revisionPublicID, ids.projectA, sourceDigest, sourceManifestDigest, at],
  );
  await bootstrapPool.query(
    `UPDATE roomscan.professional_projects
        SET head_revision_id = $1::uuid, updated_at = $2::timestamptz
      WHERE workspace_id = $3::uuid AND project_id = $4::uuid`,
    [revisionID, at, ids.workspaceA, ids.projectA],
  );
  return { projectPublicID, revisionPublicID, revisionID, sourceDigest, sourceManifestDigest };
}

async function seedApiAccess(at) {
  const accessHash = digest('owner-access');
  const membership = (await bootstrapPool.query(
    `SELECT authorization_version FROM roomscan.memberships
      WHERE workspace_id = $1::uuid AND principal_id = $2::uuid AND state = 'active'`,
    [ids.workspaceA, ids.principalA],
  )).rows[0];
  assert.ok(membership, 'owner fixture must have active membership');
  await bootstrapPool.query(
    `WITH family AS (
       INSERT INTO roomscan.auth_session_families (
         id, public_id, principal_id, authentication_epoch, authenticated_at,
         last_used_at, inactivity_expires_at, absolute_expires_at, policy_version,
         workspace_id, role, authorization_version, state, created_at
       ) VALUES (
         '62000000-0000-4000-8000-000000000001', 'fam_correctionowner001', $1::uuid, 0,
         $2::timestamptz, $2::timestamptz, $2::timestamptz + interval '1 day',
         $2::timestamptz + interval '7 days', 'session-v1', $3::uuid, 'owner',
         $4::bigint, 'active', $2::timestamptz
       ) RETURNING id
     )
     INSERT INTO roomscan.auth_access_tokens (
       id, family_id, token_hash, expires_at, principal_id, authentication_epoch,
       authenticated_at, issued_at, workspace_id, role, authorization_version,
       state, created_at
     ) SELECT gen_random_uuid(), family.id, $5::bytea, $2::timestamptz + interval '1 day',
       $1::uuid, 0, $2::timestamptz, $2::timestamptz, $3::uuid, 'owner',
       $4::bigint, 'active', $2::timestamptz FROM family`,
    [ids.principalA, at, ids.workspaceA, membership.authorization_version, accessHash],
  );
  return accessHash;
}

async function seedConcurrentApiAccess(at) {
  const accessHash = digest('owner-access-concurrent');
  const membership = (await bootstrapPool.query(
    `SELECT authorization_version FROM roomscan.memberships
      WHERE workspace_id = $1::uuid AND principal_id = $2::uuid AND state = 'active'`,
    [ids.workspaceA, ids.principalA],
  )).rows[0];
  assert.ok(membership, 'owner fixture must have active membership for the second session');
  await bootstrapPool.query(
    `WITH family AS (
       INSERT INTO roomscan.auth_session_families (
         id, public_id, principal_id, authentication_epoch, authenticated_at,
         last_used_at, inactivity_expires_at, absolute_expires_at, policy_version,
         workspace_id, role, authorization_version, state, created_at
       ) VALUES (
         '62000000-0000-4000-8000-000000000002', 'fam_correctionowner002', $1::uuid, 0,
         $2::timestamptz, $2::timestamptz, $2::timestamptz + interval '1 day',
         $2::timestamptz + interval '7 days', 'session-v1', $3::uuid, 'owner',
         $4::bigint, 'active', $2::timestamptz
       ) RETURNING id
     )
     INSERT INTO roomscan.auth_access_tokens (
       id, family_id, token_hash, expires_at, principal_id, authentication_epoch,
       authenticated_at, issued_at, workspace_id, role, authorization_version,
       state, created_at
     ) SELECT gen_random_uuid(), family.id, $5::bytea, $2::timestamptz + interval '1 day',
       $1::uuid, 0, $2::timestamptz, $2::timestamptz, $3::uuid, 'owner',
       $4::bigint, 'active', $2::timestamptz FROM family`,
    [ids.principalA, at, ids.workspaceA, membership.authorization_version, accessHash],
  );
  return accessHash;
}

async function waitForPropertyRaceLock(applicationName) {
  let observed;
  for (let attempt = 0; attempt < 200; attempt += 1) {
    observed = (await bootstrapPool.query(
      `SELECT state, wait_event_type, wait_event
         FROM pg_stat_activity
        WHERE application_name = $1::text`,
      [applicationName],
    )).rows[0];
    if (observed?.state === 'active' && observed.wait_event_type === 'Lock') return observed;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  return observed;
}

async function insertAllocation({ source, versions, label, state = 'allocated', leaseId = null, at }) {
  const allocationID = label === 'completion' ? '63000000-0000-4000-8000-000000000001'
    : '63000000-0000-4000-8000-000000000002';
  const allocationPublicID = label === 'completion' ? 'pua_correctioncomplete1' : 'pua_correctionkillbind1';
  const archiveDigest = digest(`${label}:archive`);
  const archiveManifestDigest = digest(`${label}:manifest`);
  await bootstrapPool.query(
    `INSERT INTO roomscan.publication_allocations (
       workspace_id, allocation_id, allocation_public_id, project_id,
       source_revision_id, source_revision_public_id, source_revision_digest,
       source_manifest_digest, source_bindings_digest, selection_digest,
       approval_digest, publication_kind, property_id, property_membership_digest,
       property_curation_version, archive_manifest_digest, archive_digest,
       archive_bytes, idempotency_digest, state, quarantine_key, quarantine_version,
       active_object_version, created_by_principal_id, created_role,
       created_authorization_version, hosted_global_version, hosted_workspace_version,
       publication_global_version, publication_workspace_version, quota_policy_version,
       allocation_expires_at, created_at, updated_at
     ) VALUES (
       $1::uuid, $2::uuid, $3::text, $4::uuid, $5::uuid, $6::text, $7::bytea,
       $8::bytea, $9::bytea, $10::bytea, $11::bytea, 'room', NULL, NULL, NULL,
       $12::bytea, $13::bytea, 2048, $14::bytea, $15::text,
       'server/published/quarantine/v1/' || $3 || '.zip', NULL, NULL,
       $16::uuid, 'owner', $17::bigint, $18::bigint, $19::bigint,
       $20::bigint, $21::bigint, 1, $22::timestamptz + interval '1 hour',
       $22::timestamptz, $22::timestamptz
     )`,
    [
      ids.workspaceA, allocationID, allocationPublicID, ids.projectA, source.revisionID,
      source.revisionPublicID, source.sourceDigest, source.sourceManifestDigest,
      digest(`${label}:bindings`), digest(`${label}:selection`), digest(`${label}:approval`),
      archiveManifestDigest, archiveDigest, digest(`${label}:idempotency`), state,
      ids.principalA, 1, versions.hosted_global, versions.hosted_workspace,
      versions.publication_global, versions.publication_workspace, at,
    ],
  );
  if (state === 'validating') {
    await bootstrapPool.query(
      `INSERT INTO roomscan.publication_jobs (
         workspace_id, job_id, allocation_id, state, lease_id, lease_expires_at,
         created_at, updated_at
       ) VALUES ($1::uuid, gen_random_uuid(), $2::uuid, 'claimed', $3::text,
         $4::timestamptz + interval '15 minutes', $4::timestamptz, $4::timestamptz)`,
      [ids.workspaceA, allocationID, leaseId, at],
    );
  }
  return { allocationID, allocationPublicID, archiveDigest, archiveManifestDigest };
}

try {
  await applyMigrations({
    pool: bootstrapPool,
    ...(process.env.ROOMSCAN_TEST_MIGRATIONS_DIR
      ? { migrationsDir: process.env.ROOMSCAN_TEST_MIGRATIONS_DIR }
      : {}),
  });
  await seedCoreFixtures(bootstrapPool);

  // Red-first contract probes: the v2 property reducer and durable feedback
  // lane must exist before behavior tests can exercise the real authority.
  const propertyFunction = 'roomscan.publication_upsert_property_v2(text,bytea,timestamp with time zone,text,bigint,bytea,text,jsonb)';
  const outboxTable = (await bootstrapPool.query(
    `SELECT to_regclass('roomscan.portal_feedback_delivery_outbox')::text AS relation`,
  )).rows[0]?.relation;
  assert.equal(outboxTable, 'roomscan.portal_feedback_delivery_outbox',
    'durable feedback delivery outbox must be present');
  assert.equal((await bootstrapPool.query(
    `SELECT to_regprocedure($1)::text AS routine`, [propertyFunction],
  )).rows[0]?.routine, propertyFunction,
  'property v2 idempotent reducer must be present');

  // An API completion is deliberately targetless: it may queue an allocation,
  // but it cannot name or inspect an S3 object version.  The publication worker
  // binds that version only after it has claimed the job.  This is the first
  // end-to-end capability seam for the correction gate; a v1 completion with
  // a caller-supplied version cannot satisfy it.
  const targetlessCompletion =
    'roomscan.publication_complete_v2(text,bytea,timestamp with time zone,text,bytea,bytea,bigint)';
  const workerVersionBind =
    'roomscan.publication_bind_quarantine_version_v1(uuid,text,timestamp with time zone,text)';
  assert.equal((await bootstrapPool.query(
    `SELECT to_regprocedure($1)::text AS routine`, [targetlessCompletion],
  )).rows[0]?.routine, targetlessCompletion,
  'API completion must be targetless so the API remains S3-write-only');
  assert.equal((await bootstrapPool.query(
    `SELECT to_regprocedure($1)::text AS routine`, [workerVersionBind],
  )).rows[0]?.routine, workerVersionBind,
  'only the claimed worker must be able to bind the exact quarantine version');
  const completionPrivileges = (await bootstrapPool.query(
    `SELECT has_function_privilege('roomscan_api_runtime', $1, 'EXECUTE') AS api_v1,
            has_function_privilege('roomscan_api_runtime', $2, 'EXECUTE') AS api_v2,
            has_function_privilege('roomscan_publication_worker', $3, 'EXECUTE') AS worker_bind,
            has_function_privilege('roomscan_api_runtime', $3, 'EXECUTE') AS api_bind`,
    [
      'roomscan.publication_complete_v1(text,bytea,timestamp with time zone,text,bytea,bytea,bigint,text)',
      targetlessCompletion,
      workerVersionBind,
    ],
  )).rows[0];
  assert.deepEqual(completionPrivileges, {
    api_v1: false,
    api_v2: true,
    worker_bind: true,
    api_bind: false,
  }, 'completion/version binding must be split between API and worker capabilities');

  const propertyIdempotencyColumn = (await bootstrapPool.query(
    `SELECT column_name FROM information_schema.columns
      WHERE table_schema = 'roomscan'
        AND table_name = 'publication_properties'
        AND column_name = 'create_idempotency_digest'`,
  )).rows[0];
  assert.ok(propertyIdempotencyColumn, 'property create idempotency digest must be stored server-side');

  // v3 is intentionally a new, additive worker contract.  The original v2
  // exposed the full persistence row (including opaque portal scope); a
  // delivery worker only needs the bounded encrypted envelope below.
  const feedbackIssueV3 =
    'roomscan.portal_request_feedback_verification_v3(bytea,timestamp with time zone,bytea,bytea,bytea,text,bytea,bytea,bytea,bytea)';
  const lifecycle = ['claim_next_feedback_delivery_v3', 'validate_feedback_delivery_v3',
    'complete_feedback_delivery_v3', 'cancel_feedback_delivery_v3',
    'release_feedback_delivery_v3'];
  assert.equal((await bootstrapPool.query(
    `SELECT to_regprocedure($1)::text AS routine`, [feedbackIssueV3],
  )).rows[0]?.routine, feedbackIssueV3,
  'the portal must issue durable feedback through the privacy-minimized v3 contract');
  const lifecycleRows = (await bootstrapPool.query(
    `SELECT proname FROM pg_proc AS procedure
      JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
      WHERE namespace.nspname = 'roomscan' AND proname = ANY($1::text[])
      ORDER BY proname`, [lifecycle],
  )).rows;
  assert.deepEqual(lifecycleRows.map(({ proname }) => proname), [...lifecycle].sort(),
    'feedback outbox must expose the complete email-runtime lifecycle');

  // Keep a positive fixture reference in the focused oracle so future negative
  // probes cannot pass merely by failing before reaching the publication path.
  assert.equal(hash32('positive-control').byteLength, 32);
  assert.equal(ids.workspaceA.length, 36);

  await enablePublicationFlags(now);
  await activateQuota(now);
  const source = await seedCanonicalPublicationSource(now);
  const versions = await currentPublicationVersions();
  const accessHash = await seedApiAccess(now);
  const concurrentAccessHash = await seedConcurrentApiAccess(now);
  apiPool = new Pool({ ...appPoolConfig(cluster, 2), user: 'roomscan_api_runtime' });
  workerPool = new Pool({ ...appPoolConfig(cluster, 2), user: 'roomscan_publication_worker' });

  const createPropertyArguments = [
    'app_bearer', accessHash, now, null, 0, digest('property-create'),
    'Crash-safe property',
    JSON.stringify([{ publicRoomKey: 'room-correction', projectPublicID: source.projectPublicID }]),
  ];
  const createdProperty = (await apiPool.query(
    `SELECT * FROM roomscan.publication_upsert_property_v2(
       $1::text, $2::bytea, $3::timestamptz, $4::text, $5::bigint,
       $6::bytea, $7::text, $8::jsonb
     )`,
    createPropertyArguments,
  )).rows[0];
  assert.equal(createdProperty.status, 'created',
    'v2 must create a server-generated property from one stable idempotency digest');
  assert.match(createdProperty.property_public_id, /^prop_[A-Za-z0-9_-]{16,128}$/u,
    'v2 must generate, rather than trust, the hosted property public ID');
  const replayedProperty = (await apiPool.query(
    `SELECT * FROM roomscan.publication_upsert_property_v2(
       $1::text, $2::bytea, $3::timestamptz, $4::text, $5::bigint,
       $6::bytea, $7::text, $8::jsonb
     )`,
    [
      ...createPropertyArguments.slice(0, 2), new Date(now.getTime() + 1_000),
      ...createPropertyArguments.slice(3),
    ],
  )).rows[0];
  assert.deepEqual(
    {
      status: replayedProperty.status,
      property_id: replayedProperty.property_id,
      property_public_id: replayedProperty.property_public_id,
      curation_version: Number(replayedProperty.curation_version),
    },
    {
      status: 'existing',
      property_id: createdProperty.property_id,
      property_public_id: createdProperty.property_public_id,
      curation_version: 1,
    },
    'a lost create response must recover the same property without a version bump',
  );
  await assert.rejects(
    () => apiPool.query(
      `SELECT * FROM roomscan.publication_upsert_property_v2(
         $1::text, $2::bytea, $3::timestamptz, $4::text, $5::bigint,
         $6::bytea, $7::text, $8::jsonb
       )`,
      [
        ...createPropertyArguments.slice(0, 2), new Date(now.getTime() + 2_000),
        ...createPropertyArguments.slice(3, 6), 'Changed property title',
        createPropertyArguments[7],
      ],
    ),
    (error) => error?.code === 'P0001' && error?.message === 'PUBLICATION_PROPERTY_IDEMPOTENCY_CONFLICT',
    'the stable create key must conflict before changing title or room truth',
  );

  // Hold the first create transaction open after the reducer returns. The
  // second connection must block on the reducer's advisory serializer, then
  // observe the committed row and return the exact existing identity. Without
  // that serializer both calls can pass the pre-insert lookup and the loser
  // reaches a unique-constraint error rather than an idempotent replay.
  const concurrentPropertyArguments = [
    'app_bearer', accessHash, new Date(now.getTime() + 3_000), null, 0,
    digest('property-create-concurrent'), 'Concurrent crash-safe property',
    JSON.stringify([{ publicRoomKey: 'room-concurrent', projectPublicID: source.projectPublicID }]),
  ];
  const concurrentPropertySQL = `SELECT * FROM roomscan.publication_upsert_property_v2(
    $1::text, $2::bytea, $3::timestamptz, $4::text, $5::bigint,
    $6::bytea, $7::text, $8::jsonb
  )`;
  const [concurrentA, concurrentB] = await Promise.all([apiPool.connect(), apiPool.connect()]);
  let transactionAOpen = false;
  let transactionBOpen = false;
  let concurrentCreated;
  let concurrentExisting;
  try {
    await concurrentB.query(`SET application_name = 'slice6_property_race_b'`);
    await Promise.all([concurrentA.query('BEGIN'), concurrentB.query('BEGIN')]);
    transactionAOpen = true;
    transactionBOpen = true;
    concurrentCreated = (await concurrentA.query(
      concurrentPropertySQL, concurrentPropertyArguments,
    )).rows[0];
    const secondOutcomePromise = concurrentB.query(
      concurrentPropertySQL,
      [
        concurrentPropertyArguments[0], concurrentAccessHash,
        new Date(now.getTime() + 4_000),
        ...concurrentPropertyArguments.slice(3),
      ],
    ).then(
      (result) => ({ result }),
      (error) => ({ error }),
    );
    const blocked = await waitForPropertyRaceLock('slice6_property_race_b');
    assert.deepEqual(blocked, {
      state: 'active',
      wait_event_type: 'Lock',
      wait_event: 'advisory',
    }, 'the overlapping property create must block on its own advisory serializer before the first transaction commits');
    await concurrentA.query('COMMIT');
    transactionAOpen = false;
    const secondOutcome = await secondOutcomePromise;
    if ('error' in secondOutcome) throw secondOutcome.error;
    concurrentExisting = secondOutcome.result.rows[0];
    await concurrentB.query('COMMIT');
    transactionBOpen = false;
  } finally {
    if (transactionAOpen) await concurrentA.query('ROLLBACK').catch(() => undefined);
    if (transactionBOpen) await concurrentB.query('ROLLBACK').catch(() => undefined);
    concurrentA.release();
    concurrentB.release();
  }
  assert.deepEqual(
    [concurrentCreated, concurrentExisting].map((row) => ({
      status: row.status,
      property_id: row.property_id,
      property_public_id: row.property_public_id,
      curation_version: Number(row.curation_version),
      room_count: Number(row.room_count),
    })),
    [
      {
        status: 'created',
        property_id: concurrentCreated.property_id,
        property_public_id: concurrentCreated.property_public_id,
        curation_version: 1,
        room_count: 1,
      },
      {
        status: 'existing',
        property_id: concurrentCreated.property_id,
        property_public_id: concurrentCreated.property_public_id,
        curation_version: 1,
        room_count: 1,
      },
    ],
    'two overlapping same-digest creates must converge on one server property identity',
  );
  assert.equal(Number((await bootstrapPool.query(
    `SELECT count(*)::integer AS count
       FROM roomscan.publication_properties
      WHERE workspace_id = $1::uuid
        AND created_by_principal_id = $2::uuid
        AND create_idempotency_digest = $3::bytea`,
    [ids.workspaceA, ids.principalA, digest('property-create-concurrent')],
  )).rows[0].count), 1, 'the concurrent positive control must leave exactly one durable property row');

  const completionAllocation = await insertAllocation({
    source, versions, label: 'completion', at: now,
  });
  const completed = (await apiPool.query(
    `SELECT * FROM roomscan.publication_complete_v2(
       'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text,
       $4::bytea, $5::bytea, 2048::bigint
     )`,
    [
      accessHash, now, completionAllocation.allocationPublicID,
      completionAllocation.archiveDigest, completionAllocation.archiveManifestDigest,
    ],
  )).rows[0];
  assert.deepEqual(completed, {
    status: 'validation_pending', allocation_public_id: completionAllocation.allocationPublicID,
  }, 'targetless API completion must queue the exact archive identity without a provider version');
  const replayedCompletion = (await apiPool.query(
    `SELECT * FROM roomscan.publication_complete_v2(
       'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text,
       $4::bytea, $5::bytea, 2048::bigint
     )`,
    [
      accessHash, new Date(now.getTime() + 1_000), completionAllocation.allocationPublicID,
      completionAllocation.archiveDigest, completionAllocation.archiveManifestDigest,
    ],
  )).rows[0];
  assert.deepEqual(replayedCompletion, {
    status: 'existing', allocation_public_id: completionAllocation.allocationPublicID,
  }, 'a targetless completion replay must preserve one queued allocation');
  assert.deepEqual((await bootstrapPool.query(
    `SELECT allocation.quarantine_version, job.state, count(*) OVER ()::integer AS job_count
       FROM roomscan.publication_allocations AS allocation
       JOIN roomscan.publication_jobs AS job
         ON job.workspace_id = allocation.workspace_id
        AND job.allocation_id = allocation.allocation_id
      WHERE allocation.allocation_id = $1::uuid`,
    [completionAllocation.allocationID],
  )).rows[0], {
    quarantine_version: null,
    state: 'pending',
    job_count: 1,
  }, 'completion replay must retain one pending job and no API-supplied object version');
  const claimed = (await workerPool.query(
    `SELECT * FROM roomscan.publication_claim_job_v1($1::timestamptz)`, [now],
  )).rows[0];
  assert.equal(claimed.allocation_id, completionAllocation.allocationID,
    'targetless worker claim positive control must reach the queued allocation');
  assert.equal(claimed.quarantine_version, null,
    'claim must not invent a latest quarantine version before the worker reads storage');
  const bound = (await workerPool.query(
    `SELECT * FROM roomscan.publication_bind_quarantine_version_v1(
       $1::uuid, $2::text, $3::timestamptz, 'quarantine-version-positive'::text
     )`,
    [claimed.allocation_id, claimed.lease_id, now],
  )).rows[0];
  assert.equal(bound.status, 'bound',
    'a live worker lease must bind the exact provider version after targetless claim');
  assert.equal(bound.quarantine_version, 'quarantine-version-positive');

  const killLease = 'pwl_abcdefghijklmnop';
  const killedAllocation = await insertAllocation({
    source, versions, label: 'kill-bind', state: 'validating', leaseId: killLease, at: now,
  });
  const killAt = new Date(now.getTime() + 2_000);
  await setOperationalFlag(
    'global', null, 'publication_enabled', false, 'ofaud_0009b_bind_kill', killAt,
  );
  await assert.rejects(
    () => workerPool.query(
      `SELECT * FROM roomscan.publication_bind_quarantine_version_v1(
         $1::uuid, $2::text, $3::timestamptz, 'quarantine-version-killed'::text
       )`,
      [killedAllocation.allocationID, killLease, killAt],
    ),
    (error) => error?.code === '42501' && error?.message === 'PUBLICATION_GRANT_REJECTED',
    'a publication kill committed after claim but before bind must deny version binding',
  );
  assert.equal((await bootstrapPool.query(
    `SELECT quarantine_version FROM roomscan.publication_allocations
      WHERE allocation_id = $1::uuid`, [killedAllocation.allocationID],
  )).rows[0].quarantine_version, null,
  'a denied post-claim bind must leave quarantine_version NULL');
  console.log('INTEGRATION_0009B_IDEMPOTENCY_OUTBOX_SUMMARY targetless_completion=1 targetless_replay=1 pending_job_identity=1 live_worker_bind=1 post_claim_kill_denial=1 property_create_replay=1 property_create_race=1 feedback_v3_catalog=1 status=pass');
} finally {
  await workerPool?.end();
  await apiPool?.end();
  await bootstrapPool.end();
  const cleanup = await cluster.stop();
  console.log(`PG_CLEANUP ${JSON.stringify(cleanup)}`);
}
