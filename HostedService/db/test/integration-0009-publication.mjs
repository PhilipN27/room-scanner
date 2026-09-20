import assert from 'node:assert/strict';
import { scryptSync } from 'node:crypto';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { appPoolConfig, hash32, ids, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const cluster = await startPostgresCluster();
const bootstrapPool = new Pool(cluster.bootstrapConfig);
let apiPool;
let workerPool;
let portalPool;
let emailPool;

const now = new Date('2026-08-30T12:00:00.000Z');
const digest = (label) => hash32(`slice6-publication:${label}`);
const pinScrypt = Object.freeze({ N: 16384, r: 8, p: 1, keyLength: 32 });
const derivePortalPin = (pin, salt) => scryptSync(pin, salt, pinScrypt.keyLength, {
  N: pinScrypt.N,
  r: pinScrypt.r,
  p: pinScrypt.p,
  maxmem: 64 * 1024 * 1024,
});

async function setFlag(scope, workspaceId, flagKey, auditId, enabled = true, at = now) {
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
         'slice 6 publication integration', $6::text, $7::timestamptz
       )`,
      [scope, workspaceId, flagKey, enabled, existing ? Number(existing.version) : null, auditId, at],
    );
  } finally {
    await bootstrapPool.query('RESET ROLE');
  }
}

async function setEditorPublishingAllowed(workspaceId, enabled, auditId, at = now) {
  const existing = (await bootstrapPool.query(
    `SELECT version FROM roomscan.workspace_publishing_policies
      WHERE workspace_id = $1::uuid`,
    [workspaceId],
  )).rows[0];
  await bootstrapPool.query('SET ROLE roomscan_operator');
  try {
    await bootstrapPool.query(
      `SELECT * FROM roomscan.set_workspace_publishing_policy(
         $1::uuid, $2::boolean, $3::bigint, 'Slice 6 editor policy oracle',
         $4::text, $5::timestamptz
       )`,
      [workspaceId, enabled, existing ? Number(existing.version) : null, auditId, at],
    );
  } finally {
    await bootstrapPool.query('RESET ROLE');
  }
}

async function seedCanonicalSource() {
  const revisionId = '51000000-0000-4000-8000-000000000001';
  const sourceRevisionId = 'source_revision_slice6_a';
  const revisionPublicId = 'rev_slice6canonical0001';
  const projectPublicId = 'prj_slice6project0001';
  const sourceProjectId = 'source_project_slice6_a';
  await bootstrapPool.query(
    `INSERT INTO roomscan.professional_projects (
       workspace_id, project_id, public_id, source_project_id, head_revision_id,
       raw_archive_enabled, version, created_at, updated_at
     ) VALUES ($1, $2, $3, $4, NULL,
       false, 1, $5, $5)`,
    [ids.workspaceA, ids.projectA, projectPublicId, sourceProjectId, now],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.project_revisions (
       workspace_id, id, public_id, project_id, source_revision_id,
       branch_state, working_object_key, working_object_version,
       working_digest, working_bytes, working_manifest_digest, created_at
     ) VALUES ($1, $2, $3, $4, $5, 'canonical',
       'professional-sync/active/working/' || $3 || '.zip', 'version-slice6',
       $6, 1234, $7, $8)`,
    [
      ids.workspaceA,
      revisionId,
      revisionPublicId,
      ids.projectA,
      sourceRevisionId,
      digest('source-archive'),
      digest('source-manifest'),
      now,
    ],
  );
  await bootstrapPool.query(
    `UPDATE roomscan.professional_projects
        SET head_revision_id = $1, updated_at = $2
      WHERE workspace_id = $3 AND project_id = $4`,
    [revisionId, now, ids.workspaceA, ids.projectA],
  );
  return {
    projectID: ids.projectA,
    projectPublicId,
    sourceProjectId,
    revisionId,
    revisionPublicId,
    sourceRevisionId,
    coordinateSpaceEpochID: 'epoch_slice6_a',
    packageSchemaVersion: 'room-scan-project-v2',
    semanticSHA256: digest('semantic-slice6-a').toString('hex'),
    revisionManifestSHA256: digest('revision-manifest-slice6-a').toString('hex'),
    sourceDigest: digest('source-archive'),
    sourceManifestDigest: digest('source-manifest'),
  };
}

async function seedCanonicalSourceA2() {
  const projectID = '30000000-0000-4000-8000-000000000003';
  const revisionId = '51000000-0000-4000-8000-000000000003';
  const projectPublicId = 'prj_slice6project0003';
  const revisionPublicId = 'rev_slice6canonical0003';
  const sourceProjectId = 'source_project_slice6_a2';
  const sourceRevisionId = 'source_revision_slice6_a2';
  await bootstrapPool.query(
    `INSERT INTO roomscan.projects (id, workspace_id, slug, title)
      VALUES ($1::uuid, $2::uuid, 'project-a2', 'Project A2')`,
    [projectID, ids.workspaceA],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.professional_projects (
       workspace_id, project_id, public_id, source_project_id, head_revision_id,
       raw_archive_enabled, version, created_at, updated_at
     ) VALUES ($1::uuid, $2::uuid, $3::text, $4::text, NULL,
       false, 1, $5::timestamptz, $5::timestamptz)`,
    [ids.workspaceA, projectID, projectPublicId, sourceProjectId, now],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.project_revisions (
       workspace_id, id, public_id, project_id, source_revision_id,
       branch_state, working_object_key, working_object_version,
       working_digest, working_bytes, working_manifest_digest, created_at
     ) VALUES ($1::uuid, $2::uuid, $3::text, $4::uuid, $5::text, 'canonical',
       'professional-sync/active/working/' || $3 || '.zip', 'version-slice6-a2',
       $6::bytea, 1234, $7::bytea, $8::timestamptz)`,
    [
      ids.workspaceA, revisionId, revisionPublicId, projectID, sourceRevisionId,
      digest('source-archive-a2'), digest('source-manifest-a2'), now,
    ],
  );
  await bootstrapPool.query(
    `UPDATE roomscan.professional_projects
        SET head_revision_id = $1::uuid, updated_at = $2::timestamptz
      WHERE workspace_id = $3::uuid AND project_id = $4::uuid`,
    [revisionId, now, ids.workspaceA, projectID],
  );
  return {
    projectID,
    projectPublicId,
    sourceProjectId,
    revisionId,
    revisionPublicId,
    sourceRevisionId,
    coordinateSpaceEpochID: 'epoch_slice6_a2',
    packageSchemaVersion: 'room-scan-project-v2',
    semanticSHA256: digest('semantic-slice6-a2').toString('hex'),
    revisionManifestSHA256: digest('revision-manifest-slice6-a2').toString('hex'),
    sourceDigest: digest('source-archive-a2'),
    sourceManifestDigest: digest('source-manifest-a2'),
  };
}

async function seedCanonicalSourceB() {
  const revisionId = '51000000-0000-4000-8000-000000000002';
  const sourceRevisionId = 'source_revision_slice6_b';
  const revisionPublicId = 'rev_slice6canonical0002';
  const projectPublicId = 'prj_slice6project0002';
  await bootstrapPool.query(
    `INSERT INTO roomscan.professional_projects (
       workspace_id, project_id, public_id, source_project_id, head_revision_id,
       raw_archive_enabled, version, created_at, updated_at
     ) VALUES ($1, $2, $3, 'source_project_slice6_b', NULL,
       false, 1, $4, $4)`,
    [ids.workspaceB, ids.projectB, projectPublicId, now],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.project_revisions (
       workspace_id, id, public_id, project_id, source_revision_id,
       branch_state, working_object_key, working_object_version,
       working_digest, working_bytes, working_manifest_digest, created_at
     ) VALUES ($1, $2, $3, $4, $5, 'canonical',
       'professional-sync/active/working/' || $3 || '.zip', 'version-slice6-b',
       $6, 1234, $7, $8)`,
    [
      ids.workspaceB, revisionId, revisionPublicId, ids.projectB, sourceRevisionId,
      digest('source-archive-b'), digest('source-manifest-b'), now,
    ],
  );
  await bootstrapPool.query(
    `UPDATE roomscan.professional_projects
        SET head_revision_id = $1, updated_at = $2
      WHERE workspace_id = $3 AND project_id = $4`,
    [revisionId, now, ids.workspaceB, ids.projectB],
  );
  return {
    projectID: ids.projectB,
    projectPublicId,
    sourceProjectId: 'source_project_slice6_b',
    revisionId,
    revisionPublicId,
    sourceRevisionId,
    coordinateSpaceEpochID: 'epoch_slice6_b',
    packageSchemaVersion: 'room-scan-project-v2',
    semanticSHA256: digest('semantic-slice6-b').toString('hex'),
    revisionManifestSHA256: digest('revision-manifest-slice6-b').toString('hex'),
    sourceDigest: digest('source-archive-b'),
    sourceManifestDigest: digest('source-manifest-b'),
  };
}

function sourceBinding(source, publicRoomKey) {
  return {
    publicRoomKey,
    projectPublicID: source.projectPublicId,
    revisionPublicID: source.revisionPublicId,
    projectID: source.sourceProjectId,
    revisionID: source.sourceRevisionId,
    coordinateSpaceEpochID: source.coordinateSpaceEpochID,
    packageSchemaVersion: source.packageSchemaVersion,
    semanticSHA256: source.semanticSHA256,
    revisionManifestSHA256: source.revisionManifestSHA256,
  };
}

async function seedAccess() {
  const familyId = '52000000-0000-4000-8000-000000000001';
  const accessHash = digest('owner-access');
  await bootstrapPool.query(
    `INSERT INTO roomscan.auth_session_families (
       id, public_id, principal_id, authentication_epoch, authenticated_at,
       last_used_at, inactivity_expires_at, absolute_expires_at, policy_version,
       workspace_id, role, authorization_version, state, created_at
     ) VALUES ($1, 'fam_slice6_owner', $2, 0, $3::timestamptz, $3::timestamptz,
       $3::timestamptz + interval '1 day', $3::timestamptz + interval '7 days',
       'session-v1', $4, 'owner', 1, 'active', $3::timestamptz)`,
    [familyId, ids.principalA, now, ids.workspaceA],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.auth_access_tokens (
       id, family_id, token_hash, expires_at, principal_id,
       authentication_epoch, authenticated_at, issued_at, workspace_id, role,
       authorization_version, state, created_at
     ) VALUES (gen_random_uuid(), $1, $2, $3::timestamptz + interval '1 day', $4,
       0, $3::timestamptz, $3::timestamptz, $5, 'owner', 1, 'active', $3::timestamptz)`,
    [familyId, accessHash, now, ids.principalA, ids.workspaceA],
  );
  return accessHash;
}

async function activateQuota(workspaceId = ids.workspaceA, periodKey = 'roomscan-period-v1:slice6') {
  const versions = await currentFlagVersions(workspaceId);
  await bootstrapPool.query('SET ROLE roomscan_operator');
  try {
    await bootstrapPool.query(
      `SELECT * FROM roomscan.activate_quota_policy_v2(
        $1::uuid, 1, 'roomscan-quota-policy-v1', 'test-only',
        $2::text, 10, 10, 1000000, 1000000, 1000000,
        80, $3::bigint, $4::bigint, $5::timestamptz
      )`,
      [workspaceId, periodKey, versions.hosted_global, versions.hosted_workspace, now],
    );
  } finally {
    await bootstrapPool.query('RESET ROLE');
  }
}

let freshAccessSequence = 0;
async function seedFreshAccess({
  label,
  at,
  workspaceId = ids.workspaceA,
  principalId = ids.principalA,
  role = 'owner',
}) {
  freshAccessSequence += 1;
  const membership = (await bootstrapPool.query(
    `SELECT authorization_version FROM roomscan.memberships
      WHERE workspace_id = $1::uuid AND principal_id = $2::uuid AND state = 'active'`,
    [workspaceId, principalId],
  )).rows[0];
  assert.ok(membership, `fixture must provide an active ${role} membership for ${label}`);
  const accessHash = digest(`fresh-access:${label}:${freshAccessSequence}`);
  await bootstrapPool.query(
    `WITH family AS (
       INSERT INTO roomscan.auth_session_families (
         id, public_id, principal_id, authentication_epoch, authenticated_at,
         last_used_at, inactivity_expires_at, absolute_expires_at, policy_version,
         workspace_id, role, authorization_version, state, created_at
       ) VALUES (
         gen_random_uuid(), $1, $2::uuid, 0, $3::timestamptz, $3::timestamptz,
         $3::timestamptz + interval '1 day', $3::timestamptz + interval '7 days',
         'session-v1', $4::uuid, $5, $6::bigint, 'active', $3::timestamptz
       ) RETURNING id
     )
     INSERT INTO roomscan.auth_access_tokens (
       id, family_id, token_hash, expires_at, principal_id, authentication_epoch,
       authenticated_at, issued_at, workspace_id, role, authorization_version,
       state, created_at
     ) SELECT
       gen_random_uuid(), family.id, $7::bytea, $3::timestamptz + interval '1 day',
       $2::uuid, 0, $3::timestamptz, $3::timestamptz, $4::uuid, $5,
       $6::bigint, 'active', $3::timestamptz
     FROM family`,
    [
      `fam_slice6_${label}_${freshAccessSequence}`,
      principalId,
      at,
      workspaceId,
      role,
      membership.authorization_version,
      accessHash,
    ],
  );
  return accessHash;
}

async function currentFlagVersions(workspaceId = ids.workspaceA) {
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
    [workspaceId],
  )).rows;
  assert.equal(rows.length, 4, 'fixture must have all hosted/publication global and workspace flags');
  return Object.fromEntries(rows.map(({ name, version }) => [name, Number(version)]));
}

function publicationAssetManifest(label) {
  const assetID = `ast_${label}asset0001`;
  const presentationAssetID = `ast_${label}presentation0001`;
  return [{
    asset_id: presentationAssetID,
    kind: 'presentation',
    object_key: `server/published/active/v1/snap_${label}/` + `${presentationAssetID}.bin`,
    object_version: `presentation-version-${label}`,
    content_type: 'application/json',
    digest_hex: digest(`${label}:presentation`).toString('hex'),
    bytes: 1024,
    download_kind: null,
  }, {
    asset_id: assetID,
    kind: 'floor_plan',
    object_key: `server/published/active/v1/snap_${label}/` + `${assetID}.bin`,
    object_version: `asset-version-${label}`,
    digest_hex: digest(`${label}:asset`).toString('hex'),
    bytes: 256,
    download_kind: null,
  }];
}

async function allocatePublication({
  access,
  credentialKind = 'app_bearer',
  at,
  projectPublicID,
  sourceRevisionPublicID,
  sourceDigest,
  sourceManifestDigest,
  label,
  publicationKind = 'room',
  propertyPublicID = null,
  disclosureStatus = 'approved',
  sourceBindings,
  sourceBindingsDigest = digest(`${label}:source-bindings`),
  versions,
}) {
  return (await apiPool.query(
    `SELECT * FROM roomscan.publication_allocate_v1(
      $1::text, $2::bytea, $3::timestamptz, $4::text, $5::text, $6::bytea,
      $7::bytea, $8::bytea, $9::bytea, $10::text, $11::text, $12::text,
      $13::jsonb, $14::bytea, $15::bytea, $16::bytea, 2048::bigint, $17::bytea
    )`,
    [
      credentialKind, access, at, projectPublicID, sourceRevisionPublicID, sourceDigest,
      sourceManifestDigest, digest(`${label}:selection`), digest(`${label}:approval`),
      disclosureStatus, publicationKind, propertyPublicID,
      JSON.stringify(sourceBindings), sourceBindingsDigest,
      digest(`${label}:archive-manifest`), digest(`${label}:archive`),
      digest(`${label}:idempotency`),
    ],
  )).rows[0];
}

// The curation reducer is deliberately versioned separately from publication
// approval.  Callers must supply the draft version they actually reviewed so a
// second browser/native writer cannot silently replace ordered room membership.
async function upsertPublicationProperty({
  access,
  credentialKind = 'app_bearer',
  at,
  propertyPublicID,
  expectedVersion,
  title,
  rooms,
  executor = apiPool,
}) {
  const isCreate = expectedVersion === 0;
  return (await executor.query(
    `SELECT * FROM roomscan.publication_upsert_property_v2(
      $1::text, $2::bytea, $3::timestamptz, $4::text, $5::bigint,
      $6::bytea, $7::text, $8::jsonb
    )`,
    [
      credentialKind, access, at, isCreate ? null : propertyPublicID, expectedVersion,
      isCreate ? digest(`property-create:${propertyPublicID}`) : null,
      title, JSON.stringify(rooms),
    ],
  )).rows[0];
}

async function completeAndClaimPublication({ access, at, allocation, label }) {
  const completed = (await apiPool.query(
    `SELECT * FROM roomscan.publication_complete_v2(
      'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text, $4::bytea,
      $5::bytea, 2048::bigint
    )`,
    [
      access, at, allocation.allocation_public_id, digest(`${label}:archive`),
      digest(`${label}:archive-manifest`),
    ],
  )).rows[0];
  assert.equal(completed.status, 'validation_pending', `${label} completion must enter validation`);
  for (let attempt = 0; attempt < 4; attempt += 1) {
    const claimed = (await workerPool.query(
      'SELECT * FROM roomscan.publication_claim_job_v1($1::timestamptz)', [at],
    )).rows[0];
    assert.ok(claimed, `${label} worker claim must return the next targetless job`);
    if (claimed.allocation_id === allocation.allocation_id) {
      assert.equal(claimed.status, 'validating', `${label} worker claim must be targetless and validating`);
      assert.equal(claimed.quarantine_version, null,
        `${label} worker claim must not invent a storage version before it reads quarantine`);
      const bound = (await workerPool.query(
        `SELECT * FROM roomscan.publication_bind_quarantine_version_v1(
          $1::uuid, $2::text, $3::timestamptz, $4::text
        )`,
        [
          claimed.allocation_id, claimed.lease_id, at,
          `quarantine-version-${label}`,
        ],
      )).rows[0];
      assert.equal(bound.status, 'bound',
        `${label} worker must atomically bind its exact quarantine object version under the live lease`);
      return { ...claimed, quarantine_version: bound.quarantine_version };
    }
    assert.ok(
      ['allocation_expired', 'publication_disabled'].includes(claimed.status),
      `${label} must not skip a live unrelated publication job`,
    );
  }
  assert.fail(`${label} worker did not reach the completed allocation after bounded stale-job cleanup`);
}

async function finalizePublication({
  claim, at, label, assets = publicationAssetManifest(label), executor = workerPool,
}) {
  return (await executor.query(
    `SELECT * FROM roomscan.publication_finalize_v1(
      $1::uuid, $2::text, $3::timestamptz, $4::text, $5::bytea, $6::bytea,
      1024::bigint, $7::jsonb
    )`,
    [
      claim.allocation_id, claim.lease_id, at, `active-${label}`,
      digest(`${label}:presentation`), claim.source_bindings_digest,
      JSON.stringify(assets),
    ],
  )).rows[0];
}

const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

async function waitForBlockedBackends(applicationNames, message) {
  for (let attempt = 0; attempt < 80; attempt += 1) {
    const blocked = (await bootstrapPool.query(
      `SELECT application_name
         FROM pg_stat_activity
        WHERE application_name = ANY($1::text[])
          AND wait_event_type = 'Lock'
        ORDER BY application_name`,
      [applicationNames],
    )).rows.map(({ application_name: name }) => name);
    if (blocked.length === applicationNames.length) {
      return;
    }
    await delay(25);
  }
  assert.fail(message);
}

async function labelBackend(client, applicationName) {
  await client.query(`SELECT set_config('application_name', $1::text, false)`, [applicationName]);
}

async function finalizePortalDelivery({ sessionHash, at, authorization, requestDigest }) {
  return (await portalPool.query(
    `SELECT * FROM roomscan.portal_finalize_asset_delivery_v1(
      $1::bytea, $2::timestamptz, $3::text, $4::bytea, $5::bigint,
      $6::bigint, $7::text
    )`,
    [
      sessionHash, at, authorization.asset_public_id, requestDigest,
      authorization.byte_offset, authorization.byte_length, authorization.object_version,
    ],
  )).rows[0];
}

async function requestFeedbackVerification({
  sessionHash,
  at,
  challengeHash,
  verificationTokenHash,
  verifiedEmailDigest,
  requestDigest,
  envelopeLabel,
}) {
  return (await portalPool.query(
    `SELECT * FROM roomscan.portal_request_feedback_verification_v3(
      $1::bytea, $2::timestamptz, $3::bytea, $4::bytea, $5::bytea,
      'test-feedback-key-v1'::text, $6::bytea, $7::bytea, $8::bytea, $9::bytea
    )`,
    [
      sessionHash, at, challengeHash, verificationTokenHash, verifiedEmailDigest,
      digest(`${envelopeLabel}:iv`).subarray(0, 12), digest(`${envelopeLabel}:ciphertext`),
      digest(`${envelopeLabel}:tag`).subarray(0, 16), requestDigest,
    ],
  )).rows[0];
}

async function finalizeProfessionalAsset({ sessionHash, at, authorization, requestDigest }) {
  return (await portalPool.query(
    `SELECT * FROM roomscan.portal_finalize_professional_asset_delivery_v1(
      $1::bytea, $2::timestamptz, $3::text, $4::bytea, $5::bigint,
      $6::bigint, $7::text
    )`,
    [
      sessionHash, at, authorization.asset_public_id, requestDigest,
      authorization.byte_offset, authorization.byte_length, authorization.object_version,
    ],
  )).rows[0];
}

try {
  await applyMigrations({
    pool: bootstrapPool,
    ...(process.env.ROOMSCAN_TEST_MIGRATIONS_DIR
      ? { migrationsDir: process.env.ROOMSCAN_TEST_MIGRATIONS_DIR }
      : {}),
  });
  await seedCoreFixtures(bootstrapPool);

  const aiPolicyArguments = (await bootstrapPool.query(
    `SELECT procedure.proname,
            procedure.proargnames[argument.ordinality] AS argument_name,
            argument.type_oid::regtype::text AS argument_type
       FROM pg_proc AS procedure
       JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
       CROSS JOIN LATERAL unnest(procedure.proargtypes::oid[])
         WITH ORDINALITY AS argument(type_oid, ordinality)
      WHERE namespace.nspname = 'roomscan'
        AND procedure.proname = ANY($1::text[])
        AND argument.ordinality = 9
      ORDER BY procedure.proname`,
    [[
      'publication_create_link_v1',
      'publication_reset_link_v1',
      'publication_update_link_v1',
    ]],
  )).rows;
  assert.deepEqual(aiPolicyArguments, [
    { proname: 'publication_create_link_v1', argument_name: 'requested_ai_policy', argument_type: 'text' },
    { proname: 'publication_reset_link_v1', argument_name: 'requested_ai_policy', argument_type: 'text' },
    { proname: 'publication_update_link_v1', argument_name: 'requested_ai_policy', argument_type: 'text' },
  ], 'AI package link policy must be an exact enabled/disabled text contract, never a nullable Boolean');
  const feedbackPolicyArguments = (await bootstrapPool.query(
    `SELECT procedure.proname,
            procedure.proargnames[argument.ordinality] AS argument_name,
            argument.type_oid::regtype::text AS argument_type
       FROM pg_proc AS procedure
       JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
       CROSS JOIN LATERAL unnest(procedure.proargtypes::oid[])
         WITH ORDINALITY AS argument(type_oid, ordinality)
      WHERE namespace.nspname = 'roomscan'
        AND procedure.proname = ANY($1::text[])
        AND argument.ordinality = 10
      ORDER BY procedure.proname`,
    [[
      'publication_create_link_v1',
      'publication_reset_link_v1',
      'publication_update_link_v1',
    ]],
  )).rows;
  assert.deepEqual(feedbackPolicyArguments, [
    { proname: 'publication_create_link_v1', argument_name: 'requested_feedback_policy', argument_type: 'text' },
    { proname: 'publication_reset_link_v1', argument_name: 'requested_feedback_policy', argument_type: 'text' },
    { proname: 'publication_update_link_v1', argument_name: 'requested_feedback_policy', argument_type: 'text' },
  ], 'feedback link policy must be an exact enabled/disabled text contract, never a nullable Boolean');

  const publicationCapabilityContract = (await bootstrapPool.query(
    `SELECT procedure.proname, procedure.proargnames
       FROM pg_proc AS procedure
       JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
      WHERE namespace.nspname = 'roomscan'
        AND procedure.proname = ANY($1::text[])
      ORDER BY procedure.proname`,
    [[
      'publication_create_link_v1',
      'publication_reset_link_v1',
      'publication_update_link_v1',
      'professional_session_resolve_v1',
      'portal_pin_parameters_v1',
    ]],
  )).rows;
  assert.equal(publicationCapabilityContract.length, 5,
    'Slice 6 must expose session-bound professional and portal PIN capability seams');
  for (const row of publicationCapabilityContract.filter((entry) => entry.proname.startsWith('publication_'))) {
    assert.ok(row.proargnames.includes('requested_feedback_policy'),
      `${row.proname} must accept an exact feedback entitlement policy`);
  }
  const feedbackEnabledColumn = (await bootstrapPool.query(
    `SELECT is_nullable, column_default
       FROM information_schema.columns
      WHERE table_schema = 'roomscan' AND table_name = 'publication_links'
        AND column_name = 'feedback_enabled'`,
  )).rows[0];
  assert.deepEqual(feedbackEnabledColumn, { is_nullable: 'NO', column_default: 'true' },
    'portal links must store a non-null live feedback entitlement');

  const propertyRoomCompositeConstraints = (await bootstrapPool.query(
    `SELECT constraints.constraint_name, pg_get_constraintdef(catalog.oid) AS definition
       FROM information_schema.table_constraints AS constraints
       JOIN pg_constraint AS catalog
         ON catalog.conname = constraints.constraint_name
       JOIN pg_namespace AS namespace ON namespace.oid = catalog.connamespace
      WHERE constraints.table_schema = 'roomscan'
        AND constraints.table_name = 'publication_property_rooms'
        AND constraints.constraint_type = 'FOREIGN KEY'
        AND namespace.nspname = 'roomscan'
      ORDER BY constraint_name`,
  )).rows;
  assert.ok(
    propertyRoomCompositeConstraints.some(({ definition }) => (
      definition.includes('(workspace_id, room_project_id)')
        && definition.includes('professional_projects(workspace_id, project_id)')
    )),
    'mutable property curation must bind every ordered room to one same-tenant hosted project',
  );
  const snapshotRoomCompositeConstraints = (await bootstrapPool.query(
    `SELECT pg_get_constraintdef(catalog.oid) AS definition
       FROM pg_constraint AS catalog
       JOIN pg_class AS relation ON relation.oid = catalog.conrelid
       JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
      WHERE namespace.nspname = 'roomscan'
        AND relation.relname = 'publication_snapshot_rooms'
        AND catalog.contype = 'f'`,
  )).rows;
  assert.ok(
    snapshotRoomCompositeConstraints.some(({ definition }) => (
      definition.includes('(workspace_id, source_revision_id, room_project_id)')
        && definition.includes('project_revisions(workspace_id, id, project_id)')
    )),
    'frozen property rows must bind the independently approved revision to its same-tenant hosted project',
  );
  const sourceBindingContract = (await bootstrapPool.query(
    `SELECT procedure.proargnames
       FROM pg_proc AS procedure
       JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
      WHERE namespace.nspname = 'roomscan'
        AND procedure.proname = 'publication_allocate_v1'`,
  )).rows[0];
  assert.deepEqual(
    sourceBindingContract?.proargnames?.slice(9, 16),
    [
      'requested_disclosure_status',
      'requested_publication_kind',
      'requested_property_public_id',
      'requested_source_bindings',
      'requested_source_bindings_digest',
      'requested_archive_manifest_digest',
      'requested_archive_digest',
    ],
    'allocation must carry a closed ordered Core source-binding list and its opaque canonical digest without moving disclosure approval',
  );
  const allocationBindingColumns = (await bootstrapPool.query(
    `SELECT column_name FROM information_schema.columns
      WHERE table_schema = 'roomscan'
        AND table_name = 'publication_allocation_source_bindings'
      ORDER BY ordinal_position`,
  )).rows.map(({ column_name: name }) => name);
  assert.deepEqual(allocationBindingColumns, [
    'workspace_id', 'allocation_id', 'room_order', 'public_room_key',
    'room_project_id', 'room_project_public_id', 'source_revision_id',
    'source_revision_public_id', 'local_project_id', 'local_revision_id',
    'coordinate_space_epoch_id', 'package_schema_version', 'semantic_sha256',
    'revision_manifest_sha256', 'working_digest', 'working_manifest_digest',
    'captured_at',
  ], 'immutable allocation bindings must retain only the reviewed Core identity plus server-derived current source digests');
  const publicationStorageChecks = (await bootstrapPool.query(
    `SELECT relation.relname, pg_get_constraintdef(con.oid) AS definition
       FROM pg_constraint AS con
       JOIN pg_class AS relation ON relation.oid = con.conrelid
       JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
      WHERE namespace.nspname = 'roomscan'
        AND relation.relname = ANY(ARRAY['publication_allocations', 'publication_assets'])
        AND con.contype = 'c'`,
  )).rows;
  assert.ok(
    publicationStorageChecks.some(({ relname, definition }) => (
      relname === 'publication_allocations'
        && definition.includes('server/published/quarantine/v1/')
    )),
    'publication quarantine rows must use the exact isolated server/published/quarantine/v1 prefix',
  );
  assert.ok(
    publicationStorageChecks.some(({ relname, definition }) => (
      relname === 'publication_assets'
        && definition.includes('server/published/active/v1/')
    )),
    'published immutable asset rows must use the exact isolated server/published/active/v1 prefix',
  );
  const downloadKindUniqueness = (await bootstrapPool.query(
    `SELECT indexdef FROM pg_indexes
      WHERE schemaname = 'roomscan' AND tablename = 'publication_assets'
        AND indexdef LIKE 'CREATE UNIQUE INDEX%'`,
  )).rows.map(({ indexdef }) => indexdef);
  assert.ok(
    downloadKindUniqueness.some((indexdef) => (
      indexdef.includes('(workspace_id, snapshot_id, download_kind)')
        && indexdef.includes('download_kind IS NOT NULL')
    )),
    'each immutable snapshot must expose at most one authoritative PDF/gallery/AI download kind',
  );

  const tables = (await bootstrapPool.query(
    `SELECT table_name FROM information_schema.tables
      WHERE table_schema = 'roomscan' AND table_name = ANY($1::text[])
      ORDER BY table_name`,
    [[
      'publication_properties', 'publication_property_rooms',
      'publication_snapshot_rooms', 'publication_allocation_source_bindings',
      'publication_allocations', 'publication_sources', 'publication_approvals',
      'publication_jobs', 'publication_snapshots', 'publication_assets',
      'publication_links', 'portal_sessions', 'portal_pin_throttles',
      'portal_feedback_challenges', 'publication_feedback',
      'publication_access_events', 'portal_asset_reservations', 'portal_delivery_receipts',
      'professional_web_sessions',
    ]],
  )).rows.map(({ table_name: tableName }) => tableName);
  assert.deepEqual(tables, [
    'portal_asset_reservations', 'portal_delivery_receipts', 'portal_feedback_challenges', 'portal_pin_throttles',
    'portal_sessions', 'professional_web_sessions', 'publication_access_events',
    'publication_allocation_source_bindings', 'publication_allocations',
    'publication_approvals', 'publication_assets',
    'publication_feedback', 'publication_jobs', 'publication_links',
    'publication_properties', 'publication_property_rooms', 'publication_snapshot_rooms', 'publication_snapshots',
    'publication_sources',
  ]);

  const roles = (await bootstrapPool.query(
    `SELECT rolname, rolcanlogin, rolinherit, rolsuper, rolbypassrls
       FROM pg_roles WHERE rolname = ANY($1::text[]) ORDER BY rolname`,
    [['roomscan_portal_runtime', 'roomscan_publication_worker']],
  )).rows;
  assert.deepEqual(roles, [
    { rolname: 'roomscan_portal_runtime', rolcanlogin: true, rolinherit: false, rolsuper: false, rolbypassrls: false },
    { rolname: 'roomscan_publication_worker', rolcanlogin: true, rolinherit: false, rolsuper: false, rolbypassrls: false },
  ]);

  await setFlag('global', null, 'hosted_operations_enabled', 'ofaud_s6hostedglobal');
  await setFlag('workspace', ids.workspaceA, 'hosted_operations_enabled', 'ofaud_s6hostedworkspace');
  await setFlag('global', null, 'publication_enabled', 'ofaud_s6publicationglobal');
  await setFlag('workspace', ids.workspaceA, 'publication_enabled', 'ofaud_s6publicationworkspace');
  await activateQuota();
  const source = await seedCanonicalSource();
  const sourceA2 = await seedCanonicalSourceA2();
  const accessHash = await seedAccess();
  const initialPublicationVersions = await currentFlagVersions();

  apiPool = new Pool({ ...appPoolConfig(cluster, 2), user: 'roomscan_api_runtime' });
  workerPool = new Pool({ ...appPoolConfig(cluster, 2), user: 'roomscan_publication_worker' });

  // RED-first Slice 6 review oracle: curation needs a real optimistic-CAS
  // argument, not only a best-effort locked replacement.  This inspects the
  // installed PostgreSQL routine, so an old 0009 cannot pass by test doubles.
  const propertyUpsertArguments = (await bootstrapPool.query(
    `SELECT procedure.proargnames
       FROM pg_proc AS procedure
       JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
      WHERE namespace.nspname = 'roomscan'
        AND procedure.proname = 'publication_upsert_property_v2'`,
  )).rows[0]?.proargnames;
  assert.deepEqual(propertyUpsertArguments?.slice(0, 8), [
    'requested_credential_kind', 'requested_credential_hash', 'authoritative_time',
    'requested_property_public_id', 'requested_expected_version',
    'requested_create_idempotency_digest', 'requested_title', 'requested_rooms',
  ], 'property curation must expose a stable create idempotency digest and explicit expected-version CAS argument');

  // A property draft remains a private project.revise workflow.  It must stay
  // usable by an Editor through both professional credentials when publication
  // controls are deliberately disabled for Editors; the same policy still
  // blocks a publication allocation.
  const editorPolicyAt = new Date(now.getTime() + 1000);
  await setEditorPublishingAllowed(
    ids.workspaceA, false, 'ofaud_s6_editor_policy_off', editorPolicyAt,
  );
  const editorAppAccess = await seedFreshAccess({
    label: 'editor-curation-app', at: editorPolicyAt,
    principalId: ids.principalMember, role: 'editor',
  });
  const editorWebBearer = await seedFreshAccess({
    label: 'editor-curation-web', at: editorPolicyAt,
    principalId: ids.principalMember, role: 'editor',
  });
  const editorWebSessionHash = digest('editor-curation-web-cookie');
  assert.equal((await apiPool.query(
    `SELECT * FROM roomscan.professional_session_issue_v1(
      $1::bytea, $2::timestamptz, $3::bytea, $4::uuid
    )`,
    [editorWebBearer, editorPolicyAt, editorWebSessionHash, ids.workspaceA],
  )).rows[0].status, 'issued', 'editor web-session positive control must be issued before the bearer is discarded');
  await bootstrapPool.query(
    `UPDATE roomscan.auth_access_tokens SET state = 'revoked', revoked_at = $2::timestamptz
      WHERE token_hash = $1::bytea`,
    [editorWebBearer, editorPolicyAt],
  );
  assert.equal((await upsertPublicationProperty({
    access: editorAppAccess, at: editorPolicyAt,
    propertyPublicID: 'prop_slice6editorapp0001', expectedVersion: 0,
    title: 'Editor app curation remains private',
    rooms: [{ publicRoomKey: 'room-001', projectPublicID: source.projectPublicId }],
  })).status, 'created',
  'an Editor app bearer with recent auth must curate while editor publishing is disabled');
  assert.equal((await upsertPublicationProperty({
    access: editorWebSessionHash, credentialKind: 'web_session', at: editorPolicyAt,
    propertyPublicID: 'prop_slice6editorweb0001', expectedVersion: 0,
    title: 'Editor web curation remains private',
    rooms: [{ publicRoomKey: 'room-001', projectPublicID: source.projectPublicId }],
  })).status, 'created',
  'an Editor professional cookie with recent auth must curate after its app bearer is discarded');
  await assert.rejects(
    () => allocatePublication({
      access: editorAppAccess, at: editorPolicyAt,
      projectPublicID: source.projectPublicId,
      sourceRevisionPublicID: source.revisionPublicId,
      sourceDigest: source.sourceDigest,
      sourceManifestDigest: source.sourceManifestDigest,
      sourceBindings: [sourceBinding(source, 'room-001')],
      label: 'editor-policy-publication-denied', versions: initialPublicationVersions,
    }),
    (error) => error?.code === '42501' && error?.message === 'EDITOR_PUBLISHING_DISABLED',
    'the same Editor must still be denied publication.create while editor publishing is disabled',
  );

  // Two distinct runtime connections carry the same reviewed version.  The
  // first writes a new immutable draft version; the stale writer must fail
  // before either its title or its ordered room list becomes visible.
  const casProperty = await upsertPublicationProperty({
    access: accessHash, at: editorPolicyAt,
    propertyPublicID: 'prop_slice6casdraft0001', expectedVersion: 0,
    title: 'CAS draft v1',
    rooms: [{ publicRoomKey: 'room-001', projectPublicID: source.projectPublicId }],
  });
  const casWriterA = await apiPool.connect();
  const casWriterB = await apiPool.connect();
  try {
    const casWinner = await upsertPublicationProperty({
      access: accessHash, at: new Date(editorPolicyAt.getTime() + 1),
      propertyPublicID: casProperty.property_public_id,
      expectedVersion: Number(casProperty.curation_version),
      title: 'CAS draft v2 winner',
      rooms: [{ publicRoomKey: 'room-001', projectPublicID: source.projectPublicId }],
      executor: casWriterA,
    });
    assert.equal(Number(casWinner.curation_version), Number(casProperty.curation_version) + 1,
      'the first property CAS writer must advance version exactly once');
    await assert.rejects(
      () => upsertPublicationProperty({
        access: accessHash, at: new Date(editorPolicyAt.getTime() + 2),
        propertyPublicID: casProperty.property_public_id,
        expectedVersion: Number(casProperty.curation_version),
        title: 'CAS stale writer must not persist',
        rooms: [{ publicRoomKey: 'room-002', projectPublicID: sourceA2.projectPublicId }],
        executor: casWriterB,
      }),
      (error) => error?.code === 'P0001' && error?.message === 'PUBLICATION_PROPERTY_VERSION_STALE',
      'a second session with a stale property version must fail closed',
    );
  } finally {
    casWriterA.release();
    casWriterB.release();
  }
  assert.deepEqual((await bootstrapPool.query(
    `SELECT property.title, property.version, rooms.room_key, rooms.room_project_public_id
       FROM roomscan.publication_properties AS property
       JOIN roomscan.publication_property_rooms AS rooms
         ON rooms.workspace_id = property.workspace_id AND rooms.property_id = property.property_id
      WHERE property.workspace_id = $1::uuid AND property.public_id = $2::text`,
    [ids.workspaceA, casProperty.property_public_id],
  )).rows, [{
    title: 'CAS draft v2 winner', version: '2', room_key: 'room-001',
    room_project_public_id: source.projectPublicId,
  }], 'a stale CAS writer must leave both title and exact ordered membership unchanged');

  const professionalCookieAccess = await seedFreshAccess({ label: 'professional-cookie', at: now });
  const professionalCookieHash = digest('professional-cookie');
  const professionalSession = (await apiPool.query(
    `SELECT * FROM roomscan.professional_session_issue_v1(
      $1::bytea, $2::timestamptz, $3::bytea, $4::uuid
    )`,
    [professionalCookieAccess, now, professionalCookieHash, ids.workspaceA],
  )).rows[0];
  assert.equal(professionalSession.status, 'issued');
  await bootstrapPool.query(
    `UPDATE roomscan.auth_access_tokens
        SET state = 'revoked', revoked_at = $2::timestamptz
      WHERE token_hash = $1::bytea`,
    [professionalCookieAccess, now],
  );
  const professionalRead = (await apiPool.query(
    `SELECT * FROM roomscan.professional_session_resolve_v1(
      $1::bytea, $2::timestamptz, 'publication.record.read'::text
    )`,
    [professionalCookieHash, now],
  )).rows[0];
  assert.equal(professionalRead.workspace_id, ids.workspaceA,
    'the professional cookie must resolve the current workspace after the original bearer is discarded');
  assert.equal(professionalRead.recent_authentication, true);
  const webSessionAllocation = await allocatePublication({
    access: professionalCookieHash, credentialKind: 'web_session', at: now,
    projectPublicID: source.projectPublicId,
    sourceRevisionPublicID: source.revisionPublicId,
    sourceDigest: source.sourceDigest,
    sourceManifestDigest: source.sourceManifestDigest,
    sourceBindings: [sourceBinding(source, 'room-001')],
    label: 'web-session-allocation', versions: initialPublicationVersions,
  });
  assert.equal(webSessionAllocation.status, 'allocated',
    'a professional cookie must authorize the same publication allocation after its app bearer is discarded');
  await assert.rejects(
    () => allocatePublication({
      access: accessHash, credentialKind: 'web_session', at: now,
      projectPublicID: source.projectPublicId,
      sourceRevisionPublicID: source.revisionPublicId,
      sourceDigest: source.sourceDigest,
      sourceManifestDigest: source.sourceManifestDigest,
      sourceBindings: [sourceBinding(source, 'room-001')],
      label: 'credential-kind-substitution-web', versions: initialPublicationVersions,
    }),
    (error) => error?.code === '42501',
    'an app bearer must not be structurally substitutable for a professional cookie capability',
  );
  await assert.rejects(
    () => allocatePublication({
      access: professionalCookieHash, credentialKind: 'app_bearer', at: now,
      projectPublicID: source.projectPublicId,
      sourceRevisionPublicID: source.revisionPublicId,
      sourceDigest: source.sourceDigest,
      sourceManifestDigest: source.sourceManifestDigest,
      sourceBindings: [sourceBinding(source, 'room-001')],
      label: 'credential-kind-substitution-bearer', versions: initialPublicationVersions,
    }),
    (error) => error?.code === '42501',
    'a professional cookie must not be structurally substitutable for an app bearer capability',
  );
  await assert.rejects(
    () => apiPool.query(
      `SELECT * FROM roomscan.professional_session_resolve_v1(
        $1::bytea, $2::timestamptz, 'publication.create'::text
      )`,
      [professionalCookieHash, new Date(now.getTime() + 5 * 60 * 1000 + 1)],
    ),
    (error) => error?.code === '42501' && error?.message === 'PROFESSIONAL_ACTION_DENIED',
    'sensitive publication actions through a professional cookie must recheck its recent authentication state',
  );
  assert.equal((await apiPool.query(
    'SELECT roomscan.professional_session_revoke_v1($1::bytea, $2::timestamptz) AS revoked',
    [professionalCookieHash, now],
  )).rows[0].revoked, true);
  await assert.rejects(
    () => allocatePublication({
      access: professionalCookieHash, credentialKind: 'web_session', at: now,
      projectPublicID: source.projectPublicId,
      sourceRevisionPublicID: source.revisionPublicId,
      sourceDigest: source.sourceDigest,
      sourceManifestDigest: source.sourceManifestDigest,
      sourceBindings: [sourceBinding(source, 'room-001')],
      label: 'revoked-web-session-allocation', versions: initialPublicationVersions,
    }),
    (error) => error?.code === '42501',
    'a revoked professional cookie must fail the same mutation without any bearer fallback',
  );
  await assert.rejects(
    () => allocatePublication({
      access: accessHash, at: now, projectPublicID: source.projectPublicId,
      sourceRevisionPublicID: source.revisionPublicId,
      sourceDigest: digest('source-archive-mismatched'),
      sourceManifestDigest: source.sourceManifestDigest,
      sourceBindings: [sourceBinding(source, 'room-001')],
      label: 'allocation-source-mismatch', versions: initialPublicationVersions,
    }),
    (error) => error?.code === 'P0001' && error?.message === 'PUBLICATION_SOURCE_CHANGED',
    'allocation must bind the exact current source revision and digest before it can reserve publication work',
  );
  await assert.rejects(
    () => allocatePublication({
      access: accessHash, at: now, projectPublicID: source.projectPublicId,
      sourceRevisionPublicID: source.revisionPublicId,
      sourceDigest: source.sourceDigest, sourceManifestDigest: source.sourceManifestDigest,
      sourceBindings: [sourceBinding(source, 'room-001')],
      label: 'allocation-disclosure-rejected', disclosureStatus: 'rejected',
      versions: initialPublicationVersions,
    }),
    (error) => error?.code === '42501' && error?.message === 'PUBLICATION_DISCLOSURE_REVIEW_REQUIRED',
    'a rejected disclosure review must fail closed before snapshot allocation',
  );
  const allocation = await allocatePublication({
    access: accessHash, at: now, projectPublicID: source.projectPublicId,
    sourceRevisionPublicID: source.revisionPublicId,
    sourceDigest: source.sourceDigest, sourceManifestDigest: source.sourceManifestDigest,
    sourceBindings: [sourceBinding(source, 'room-001')],
    label: 'allocation', versions: initialPublicationVersions,
  });
  assert.equal(allocation.status, 'allocated');

  const completed = (await apiPool.query(
    `SELECT * FROM roomscan.publication_complete_v2(
      'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text, $4::bytea,
      $5::bytea, $6::bigint
    )`,
    [
      accessHash, now, allocation.allocation_public_id,
      digest('allocation:archive'), digest('allocation:archive-manifest'), 2048,
    ],
  )).rows[0];
  assert.equal(completed.status, 'validation_pending');
  assert.equal((await apiPool.query(
    `SELECT * FROM roomscan.publication_complete_v2(
      'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text, $4::bytea,
      $5::bytea, $6::bigint
    )`,
    [
      accessHash, now, allocation.allocation_public_id,
      digest('allocation:archive'), digest('allocation:archive-manifest'), 2048,
    ],
  )).rows[0].status, 'existing',
  'a targetless completion retry must retain one pending job without requiring an S3 version');

  const claimed = (await workerPool.query(
    'SELECT * FROM roomscan.publication_claim_job_v1($1::timestamptz)', [now],
  )).rows[0];
  assert.equal(claimed.status, 'validating');
  assert.equal(claimed.quarantine_version, null,
    'API completion must not bind or receive a quarantine object version');
  const boundAllocation = (await workerPool.query(
    `SELECT * FROM roomscan.publication_bind_quarantine_version_v1(
      $1::uuid, $2::text, $3::timestamptz, 'quarantine-version-allocation'::text
    )`,
    [claimed.allocation_id, claimed.lease_id, now],
  )).rows[0];
  assert.equal(boundAllocation.status, 'bound');
  await assert.rejects(
    () => workerPool.query(
      `SELECT * FROM roomscan.publication_bind_quarantine_version_v1(
        $1::uuid, $2::text, $3::timestamptz, 'quarantine-version-substituted'::text
      )`,
      [claimed.allocation_id, claimed.lease_id, now],
    ),
    (error) => error?.code === 'P0001' && error?.message === 'PUBLICATION_QUARANTINE_VERSION_MISMATCH',
    'the worker bind must reject a second exact-version substitution under one validation lease',
  );

  await assert.rejects(
    () => workerPool.query(
      `SELECT * FROM roomscan.publication_finalize_v1(
        $1::uuid, $2::text, $3::timestamptz, $4::text, $5::bytea, $6::bytea,
        1024::bigint, $7::jsonb
      )`,
      [
        claimed.allocation_id, claimed.lease_id, now, 'active-missing-presentation',
        digest('presentation'), claimed.source_bindings_digest,
        JSON.stringify(publicationAssetManifest('missingpresentation0001').filter((asset) => asset.kind !== 'presentation')),
      ],
    ),
    (error) => error?.code === 'P0001' && error?.message === 'PUBLICATION_PRESENTATION_ASSET_INVALID',
    'finalization must reject a manifest that omits the one exact authoritative presentation asset',
  );

  const finalized = (await workerPool.query(
    `SELECT * FROM roomscan.publication_finalize_v1(
      $1::uuid, $2::text, $3::timestamptz, $4::text, $5::bytea, $6::bytea,
      $7::bigint, $8::jsonb
    )`,
    [
      claimed.allocation_id,
      claimed.lease_id,
      now,
      'active-slice6-version',
      digest('presentation'),
      claimed.source_bindings_digest,
      1024,
      JSON.stringify([{
        asset_id: 'ast_slice6presentation0001',
        kind: 'presentation',
        object_key: 'server/published/active/v1/snap_slice6snapshot0001/ast_slice6presentation0001.bin',
        object_version: 'presentation-version-1',
        content_type: 'application/json',
        digest_hex: digest('presentation').toString('hex'),
        bytes: 1024,
        download_kind: null,
      }, {
        asset_id: 'ast_slice6floorplan0001',
        kind: 'floor_plan',
        object_key: 'server/published/active/v1/snap_slice6snapshot0001/ast_slice6floorplan0001.bin',
        object_version: 'asset-version-1',
        digest_hex: digest('floorplan').toString('hex'),
        bytes: 512,
        download_kind: null,
      }, {
        asset_id: 'ast_slice6floorpdf0001',
        kind: 'floor_plan_pdf',
        object_key: 'server/published/active/v1/snap_slice6snapshot0001/ast_slice6floorpdf0001.bin',
        object_version: 'asset-version-1',
        content_type: 'application/pdf',
        digest_hex: digest('floorplan-pdf').toString('hex'),
        bytes: 256,
        download_kind: 'floor_plan_pdf',
      }, {
        asset_id: 'ast_slice6galleryzip0001',
        kind: 'gallery_zip',
        object_key: 'server/published/active/v1/snap_slice6snapshot0001/ast_slice6galleryzip0001.bin',
        object_version: 'asset-version-1',
        content_type: 'application/zip',
        digest_hex: digest('gallery-zip').toString('hex'),
        bytes: 256,
        download_kind: 'gallery_zip',
      }, {
        asset_id: 'ast_slice6aipackage0001',
        kind: 'ai_ready_package',
        object_key: 'server/published/active/v1/snap_slice6snapshot0001/ast_slice6aipackage0001.bin',
        object_version: 'asset-version-1',
        content_type: 'application/zip',
        digest_hex: digest('ai-ready-package').toString('hex'),
        bytes: 256,
        download_kind: 'ai_ready_package',
      }]),
    ],
  )).rows[0];
  assert.equal(finalized.status, 'published');
  assert.match(finalized.snapshot_public_id, /^snp_/u);
  assert.deepEqual((await bootstrapPool.query(
    `SELECT state, quarantine_key, quarantine_version, active_object_version
       FROM roomscan.publication_allocations
      WHERE allocation_id = $1::uuid`,
    [allocation.allocation_id],
  )).rows[0], {
    state: 'published',
    quarantine_key: `server/published/quarantine/v1/${allocation.allocation_public_id}.zip`,
    quarantine_version: 'quarantine-version-allocation',
    active_object_version: 'active-slice6-version',
  }, 'finalization must preserve the exact completed quarantine key/version and only add the independently promoted active version');
  await assert.rejects(
    () => bootstrapPool.query(
      'SELECT roomscan.publication_validate_asset_manifest_v1($1::jsonb)',
      [JSON.stringify([{
        asset_id: 'ast_slice6invalidai0001', kind: 'ai_ready_package',
        object_key: 'server/published/active/v1/snap_invalid/ast_slice6invalidai0001.bin',
        object_version: 'invalid-ai-version', content_type: 'application/zip',
        digest_hex: digest('invalid-ai-pair').toString('hex'), bytes: 256,
        download_kind: null,
      }])],
    ),
    (error) => error?.code === '22023' && error?.message === 'INVALID_PUBLICATION_ASSET_MANIFEST',
    'manifest validation must reject an AI-ready asset without its exact download-kind pairing',
  );
  await assert.rejects(
    () => bootstrapPool.query(
      'SELECT roomscan.publication_validate_asset_manifest_v1($1::jsonb)',
      [JSON.stringify([{
        asset_id: 'ast_slice6duplicatepdf0001', kind: 'floor_plan_pdf',
        object_key: 'server/published/active/v1/snap_duplicate/ast_slice6duplicatepdf0001.bin',
        object_version: 'duplicate-pdf-version-1', content_type: 'application/pdf',
        digest_hex: digest('duplicate-pdf-1').toString('hex'), bytes: 256,
        download_kind: 'floor_plan_pdf',
      }, {
        asset_id: 'ast_slice6duplicatepdf0002', kind: 'floor_plan_pdf',
        object_key: 'server/published/active/v1/snap_duplicate/ast_slice6duplicatepdf0002.bin',
        object_version: 'duplicate-pdf-version-2', content_type: 'application/pdf',
        digest_hex: digest('duplicate-pdf-2').toString('hex'), bytes: 256,
        download_kind: 'floor_plan_pdf',
      }])],
    ),
    (error) => error?.code === 'P0001' && error?.message === 'DUPLICATE_PUBLICATION_DOWNLOAD_KIND',
    'manifest validation must reject a second authoritative static-download kind before immutable asset insertion',
  );

  const snapshot = (await bootstrapPool.query(
    `SELECT source_revision_public_id, source_revision_digest, source_manifest_digest, source_bindings_digest,
            selection_digest, approval_digest
       FROM roomscan.publication_snapshots WHERE public_id = $1`,
    [finalized.snapshot_public_id],
  )).rows[0];
  assert.equal(snapshot.source_revision_public_id, source.revisionPublicId);
  assert.deepEqual(snapshot.source_revision_digest, source.sourceDigest);
  assert.deepEqual(snapshot.source_manifest_digest, source.sourceManifestDigest);
  assert.deepEqual(snapshot.source_bindings_digest, digest('allocation:source-bindings'));
  assert.deepEqual(snapshot.selection_digest, digest('allocation:selection'));
  assert.deepEqual(snapshot.approval_digest, digest('allocation:approval'));

  const rejectAccess = await seedFreshAccess({ label: 'worker-reject', at: now });
  const rejectAllocation = await allocatePublication({
    access: rejectAccess, at: now, projectPublicID: source.projectPublicId,
    sourceRevisionPublicID: source.revisionPublicId,
    sourceDigest: source.sourceDigest, sourceManifestDigest: source.sourceManifestDigest,
    sourceBindings: [sourceBinding(source, 'room-001')],
    label: 'worker-reject', versions: initialPublicationVersions,
  });
  const rejectClaim = await completeAndClaimPublication({
    access: rejectAccess, at: now, allocation: rejectAllocation, label: 'worker-reject',
  });
  await assert.rejects(
    () => apiPool.query(
      `SELECT * FROM roomscan.publication_reject_v1(
        $1::uuid, $2::text, $3::timestamptz, 'invalid_archive'::text
      )`,
      [rejectClaim.allocation_id, rejectClaim.lease_id, now],
    ),
    (error) => error?.code === '42501',
    'the API runtime must not acquire the worker-only terminal rejection capability',
  );
  await assert.rejects(
    () => workerPool.query(
      `SELECT * FROM roomscan.publication_reject_v1(
        $1::uuid, $2::text, $3::timestamptz, 'invalid_archive'::text
      )`,
      [rejectClaim.allocation_id, `pwl_${'a'.repeat(32)}`, now],
    ),
    (error) => error?.code === 'P0001' && error?.message === 'PUBLICATION_VALIDATION_LEASE_REQUIRED',
    'a worker rejection must bind the exact live lease and deny a substituted lease',
  );
  assert.equal((await workerPool.query(
    `SELECT * FROM roomscan.publication_reject_v1(
      $1::uuid, $2::text, $3::timestamptz, 'invalid_archive'::text
    )`,
    [rejectClaim.allocation_id, rejectClaim.lease_id, now],
  )).rows[0].status, 'rejected');
  assert.equal((await workerPool.query(
    `SELECT * FROM roomscan.publication_reject_v1(
      $1::uuid, $2::text, $3::timestamptz, 'invalid_archive'::text
    )`,
    [rejectClaim.allocation_id, rejectClaim.lease_id, now],
  )).rows[0].status, 'existing',
  'a same-result worker rejection retry must be idempotent rather than leaving a job claimable');
  assert.deepEqual((await bootstrapPool.query(
    `SELECT allocation.state AS allocation_state, job.state AS job_state, job.rejection_code
       FROM roomscan.publication_allocations AS allocation
       JOIN roomscan.publication_jobs AS job
         ON job.workspace_id = allocation.workspace_id AND job.allocation_id = allocation.allocation_id
      WHERE allocation.allocation_id = $1::uuid`,
    [rejectClaim.allocation_id],
  )).rows[0], {
    allocation_state: 'rejected', job_state: 'rejected', rejection_code: 'invalid_archive',
  }, 'a worker-rejected archive must enter an immutable terminal allocation/job state');

  const portalPinSalt = digest('pin-salt');
  const portalPinVerifier = derivePortalPin('123456', portalPinSalt);
  const link = (await apiPool.query(
    `SELECT * FROM roomscan.publication_create_link_v1(
      'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text, $4::bytea,
      $5::timestamptz, $6::bytea, $7::bytea, 'enabled'::text,
      'enabled'::text, $8::bytea
    )`,
    [
      accessHash,
      now,
      finalized.snapshot_public_id,
      digest('link-token'),
      null,
      portalPinSalt,
      portalPinVerifier,
      digest('link-idempotency'),
    ],
  )).rows[0];
  assert.equal(link.status, 'created');
  assert.equal(link.generation, '1');
  assert.equal(link.pin_required, true);
  assert.equal(
    new Date(link.expires_at).getTime(),
    now.getTime() + 30 * 24 * 60 * 60 * 1000,
    'omitted link expiry must be the exact controlled-clock 30-day default',
  );
  const semanticDefaultReplay = (await apiPool.query(
    `SELECT * FROM roomscan.publication_create_link_v1(
      'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text, $4::bytea,
      NULL::timestamptz, $5::bytea, $6::bytea, 'enabled'::text,
      'enabled'::text, $7::bytea
    )`,
    [
      accessHash, new Date(now.getTime() + 4 * 60 * 1000), finalized.snapshot_public_id,
      digest('link-token-retry-without-original-bearer'), digest('pin-salt-retry'),
      derivePortalPin('654321', digest('pin-salt-retry')),
      digest('link-idempotency'),
    ],
  )).rows[0];
  assert.deepEqual(
    {
      status: semanticDefaultReplay.status,
      link_id: semanticDefaultReplay.link_id,
      link_public_id: semanticDefaultReplay.link_public_id,
      generation: semanticDefaultReplay.generation,
      expires_at: new Date(semanticDefaultReplay.expires_at).toISOString(),
      pin_required: semanticDefaultReplay.pin_required,
    },
    {
      status: 'existing',
      link_id: link.link_id,
      link_public_id: link.link_public_id,
      generation: link.generation,
      expires_at: new Date(link.expires_at).toISOString(),
      pin_required: true,
    },
    'an omitted-expiry retry must compare default intent and PIN presence, never unrecoverable bearer/PIN verifier bytes',
  );
  const defaultReplayAfterExpiryAt = new Date(new Date(link.expires_at).getTime() + 1_000);
  const defaultReplayAfterExpiryAccess = await seedFreshAccess({
    label: 'default-link-replay-after-expiry', at: defaultReplayAfterExpiryAt,
  });
  const defaultReplayAfterExpiry = (await apiPool.query(
    `SELECT * FROM roomscan.publication_create_link_v1(
      'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text, $4::bytea,
      NULL::timestamptz, $5::bytea, $6::bytea, 'enabled'::text,
      'enabled'::text, $7::bytea
    )`,
    [
      defaultReplayAfterExpiryAccess, defaultReplayAfterExpiryAt,
      finalized.snapshot_public_id, digest('link-token-late-default-retry'),
      digest('pin-salt-late-default-retry'),
      derivePortalPin('654321', digest('pin-salt-late-default-retry')),
      digest('link-idempotency'),
    ],
  )).rows[0];
  assert.deepEqual(
    {
      status: defaultReplayAfterExpiry.status,
      link_id: defaultReplayAfterExpiry.link_id,
      link_public_id: defaultReplayAfterExpiry.link_public_id,
      generation: defaultReplayAfterExpiry.generation,
      expires_at: new Date(defaultReplayAfterExpiry.expires_at).toISOString(),
      pin_required: defaultReplayAfterExpiry.pin_required,
    },
    {
      status: 'existing',
      link_id: link.link_id,
      link_public_id: link.link_public_id,
      generation: link.generation,
      expires_at: new Date(link.expires_at).toISOString(),
      pin_required: true,
    },
    'a late default-expiry replay must return the original immutable expiry rather than recomputing thirty days from retry time',
  );
  const explicitExpiry = new Date(now.getTime() + 2 * 24 * 60 * 60 * 1000);
  const explicitLink = (await apiPool.query(
    `SELECT * FROM roomscan.publication_create_link_v1(
      'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text, $4::bytea,
      $5::timestamptz, NULL::bytea, NULL::bytea, 'disabled'::text,
      'enabled'::text, $6::bytea
    )`,
    [
      accessHash, now, finalized.snapshot_public_id, digest('explicit-link-token'),
      explicitExpiry, digest('explicit-link-idempotency'),
    ],
  )).rows[0];
  assert.equal(explicitLink.status, 'created');
  const semanticExplicitReplay = (await apiPool.query(
    `SELECT * FROM roomscan.publication_create_link_v1(
      'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text, $4::bytea,
      $5::timestamptz, NULL::bytea, NULL::bytea, 'disabled'::text,
      'enabled'::text, $6::bytea
    )`,
    [
      accessHash, new Date(now.getTime() + 4 * 60 * 1000), finalized.snapshot_public_id,
      digest('explicit-link-token-retry'), explicitExpiry,
      digest('explicit-link-idempotency'),
    ],
  )).rows[0];
  assert.equal(semanticExplicitReplay.status, 'existing',
    'an explicit-expiry retry must compare its exact chosen expiry while ignoring a regenerated bearer');
  const explicitReplayAfterExpiryAt = new Date(explicitExpiry.getTime() + 1_000);
  const explicitReplayAfterExpiryAccess = await seedFreshAccess({
    label: 'explicit-link-replay-after-expiry', at: explicitReplayAfterExpiryAt,
  });
  const explicitReplayAfterExpiry = (await apiPool.query(
    `SELECT * FROM roomscan.publication_create_link_v1(
      'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text, $4::bytea,
      $5::timestamptz, NULL::bytea, NULL::bytea, 'disabled'::text,
      'enabled'::text, $6::bytea
    )`,
    [
      explicitReplayAfterExpiryAccess, explicitReplayAfterExpiryAt,
      finalized.snapshot_public_id, digest('explicit-link-token-late-retry'), explicitExpiry,
      digest('explicit-link-idempotency'),
    ],
  )).rows[0];
  assert.deepEqual(
    {
      status: explicitReplayAfterExpiry.status,
      link_id: explicitReplayAfterExpiry.link_id,
      link_public_id: explicitReplayAfterExpiry.link_public_id,
      generation: explicitReplayAfterExpiry.generation,
      expires_at: new Date(explicitReplayAfterExpiry.expires_at).toISOString(),
      pin_required: explicitReplayAfterExpiry.pin_required,
    },
    {
      status: 'existing',
      link_id: explicitLink.link_id,
      link_public_id: explicitLink.link_public_id,
      generation: explicitLink.generation,
      expires_at: explicitExpiry.toISOString(),
      pin_required: false,
    },
    'an exact explicit-expiry replay after expiry must return the original immutable expiry rather than recomputing or extending it',
  );
  await assert.rejects(
    () => apiPool.query(
      `SELECT * FROM roomscan.publication_create_link_v1(
        'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text, $4::bytea,
        NULL::timestamptz, NULL::bytea, NULL::bytea, 'disabled'::text,
        'enabled'::text, $5::bytea
      )`,
      [
        accessHash, new Date(now.getTime() + 4 * 60 * 1000), finalized.snapshot_public_id,
        digest('explicit-link-token-default-confusion'), digest('explicit-link-idempotency'),
      ],
    ),
    (error) => error?.code === 'P0001' && error?.message === 'PUBLICATION_LINK_IDEMPOTENCY_REUSED',
    'default and explicit expiry intent must remain distinct even when their calendar times could otherwise converge',
  );

  portalPool = new Pool({ ...appPoolConfig(cluster, 2), user: 'roomscan_portal_runtime' });
  emailPool = new Pool({ ...appPoolConfig(cluster, 2), user: 'roomscan_email_delivery_runtime' });
  const portalSessionHash = digest('portal-session');
  const exchanged = (await portalPool.query(
    `SELECT * FROM roomscan.portal_exchange_link_v1(
      $1::bytea, $2::timestamptz, $3::bytea, 'mobile'::text, $4::bytea
    )`,
    [digest('link-token'), now, portalSessionHash, digest('network-risk')],
  )).rows[0];
  assert.equal(exchanged.status, 'pin_required');
  const expiryEquality = (await portalPool.query(
    `SELECT * FROM roomscan.portal_exchange_link_v1(
      $1::bytea, $2::timestamptz, $3::bytea, 'desktop'::text, $4::bytea
    )`,
    [
      digest('link-token'),
      new Date(now.getTime() + 30 * 24 * 60 * 60 * 1000),
      digest('portal-session-at-expiry'),
      digest('network-risk-expiry'),
    ],
  )).rows[0];
  assert.equal(expiryEquality.status, 'unavailable', 'link expiry equality must deny a new portal session');

  const limitedAccess = await seedFreshAccess({ label: 'limited-link', at: now });
  const limitedLink = (await apiPool.query(
    `SELECT * FROM roomscan.publication_create_link_v1(
      'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text, $4::bytea,
      $5::timestamptz, NULL::bytea, NULL::bytea, 'disabled'::text,
      'disabled'::text, $6::bytea
    )`,
    [
      limitedAccess, now, finalized.snapshot_public_id, digest('limited-link-token'),
      new Date(now.getTime() + 60 * 60 * 1000), digest('limited-link-idempotency'),
    ],
  )).rows[0];
  assert.equal(
    new Date(limitedLink.expires_at).getTime(), now.getTime() + 60 * 60 * 1000,
    'the exact one-hour lower expiry bound must be accepted',
  );
  const limitedSessionHash = digest('limited-link-session');
  assert.equal((await portalPool.query(
    `SELECT * FROM roomscan.portal_exchange_link_v1(
      $1::bytea, $2::timestamptz, $3::bytea, 'desktop'::text, $4::bytea
    )`,
    [digest('limited-link-token'), now, limitedSessionHash, digest('limited-link-risk')],
  )).rows[0].status, 'active');
  const limitedSnapshotCapabilities = (await portalPool.query(
    'SELECT * FROM roomscan.portal_get_snapshot_v2($1::bytea, $2::timestamptz)',
    [limitedSessionHash, now],
  )).rows[0];
  assert.deepEqual(
    {
      status: limitedSnapshotCapabilities.status,
      snapshot_public_id: limitedSnapshotCapabilities.snapshot_public_id,
      ai_enabled: limitedSnapshotCapabilities.ai_enabled,
      feedback_enabled: limitedSnapshotCapabilities.feedback_enabled,
    },
    {
      status: 'allowed',
      snapshot_public_id: finalized.snapshot_public_id,
      ai_enabled: false,
      feedback_enabled: false,
    },
    'the live portal snapshot projection must expose only the current link-scoped AI and feedback capabilities for the renderer',
  );
  await assert.rejects(
    () => portalPool.query(
      `SELECT * FROM roomscan.portal_authorize_asset_v1(
        $1::bytea, $2::timestamptz, 'ast_slice6aipackage0001'::text, $3::bytea,
        0::bigint, 64::bigint
      )`,
      [limitedSessionHash, now, digest('limited-ai-generic-asset')],
    ),
    (error) => error?.code === '42501' && error?.message === 'PORTAL_AI_DOWNLOAD_DISABLED',
    'the generic asset route must not bypass the per-link AI-ready entitlement',
  );
  await assert.rejects(
    () => portalPool.query(
      `SELECT * FROM roomscan.portal_authorize_download_v1(
        $1::bytea, $2::timestamptz, 'ai_ready_package'::text, $3::bytea, 0::bigint, 64::bigint
      )`,
      [limitedSessionHash, now, digest('limited-ai-download')],
    ),
    (error) => error?.code === '42501' && error?.message === 'PORTAL_AI_DOWNLOAD_DISABLED',
    'a disabled per-link AI package entitlement must deny the real AI package route',
  );
  await assert.rejects(
    () => requestFeedbackVerification({
      sessionHash: limitedSessionHash, at: now,
      challengeHash: digest('disabled-feedback-challenge'),
      verificationTokenHash: digest('disabled-feedback-token'),
      verifiedEmailDigest: digest('disabled-feedback-email'),
      requestDigest: digest('disabled-feedback-request'),
      envelopeLabel: 'disabled-feedback',
    }),
    (error) => error?.code === '42501' && error?.message === 'PORTAL_FEEDBACK_DISABLED',
    'a feedback-disabled link must reject verification before it can consume or issue a challenge',
  );
  assert.equal(Number((await bootstrapPool.query(
    `SELECT count(*)::integer AS count FROM roomscan.portal_feedback_challenges
      WHERE challenge_hash = $1::bytea`,
    [digest('disabled-feedback-challenge')],
  )).rows[0].count), 0,
  'a disabled feedback route must leave no challenge that could later be consumed');
  const resetAt = new Date(now.getTime() + 60 * 1000);
  const reset = (await apiPool.query(
    `SELECT * FROM roomscan.publication_reset_link_v1(
      'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text, $4::bytea,
      $5::timestamptz, $6::bytea, $7::bytea, 'disabled'::text,
      'enabled'::text, 1::bigint
    )`,
    [
      limitedAccess, resetAt, limitedLink.link_public_id, digest('limited-link-token-reset'),
      new Date(now.getTime() + 2 * 60 * 60 * 1000), digest('limited-pin-salt-reset'),
      digest('limited-pin-verifier-reset'),
    ],
  )).rows[0];
  assert.equal(reset.generation, '2', 'reset must rotate the link generation');
  await assert.rejects(
    () => portalPool.query(
      'SELECT * FROM roomscan.portal_get_snapshot_v1($1::bytea, $2::timestamptz)',
      [limitedSessionHash, resetAt],
    ),
    (error) => error?.code === '42501',
    'reset must immediately invalidate the old portal session generation',
  );
  assert.deepEqual((await bootstrapPool.query(
    `SELECT state, revoked_at IS NOT NULL AS revoked
       FROM roomscan.portal_sessions WHERE session_hash = $1::bytea`,
    [limitedSessionHash],
  )).rows, [{ state: 'revoked', revoked: true }],
  'link rotation must atomically mark the prior active portal session revoked, not only rely on a future generation comparison');
  await assert.rejects(
    () => portalPool.query(
      `SELECT * FROM roomscan.portal_authorize_asset_v1(
        $1::bytea, $2::timestamptz, 'ast_slice6floorplan0001'::text, $3::bytea,
        0::bigint, 64::bigint
      )`,
      [limitedSessionHash, resetAt, digest('limited-asset-after-reset')],
    ),
    (error) => error?.code === '42501',
    'a link reset must immediately deny a protected asset request from the already-authorized prior-generation session',
  );
  const resetSessionHash = digest('limited-link-reset-session');
  assert.equal((await portalPool.query(
    `SELECT * FROM roomscan.portal_exchange_link_v1(
      $1::bytea, $2::timestamptz, $3::bytea, 'desktop'::text, $4::bytea
    )`,
    [
      digest('limited-link-token-reset'), resetAt, resetSessionHash,
      digest('limited-link-reset-risk'),
    ],
  )).rows[0].status, 'pin_required', 'reset must rotate the optional PIN requirement with its link generation');
  assert.equal((await portalPool.query(
    'SELECT * FROM roomscan.portal_pin_parameters_v1($1::bytea, $2::timestamptz)',
    [resetSessionHash, new Date(resetAt.getTime() + 30 * 60 * 1000)],
  )).rowCount, 0, 'PIN KDF parameters must deny at portal-session expiry equality');

  const maxBoundAccess = await seedFreshAccess({ label: 'max-expiry-link', at: now });
  const maxBoundLink = (await apiPool.query(
    `SELECT * FROM roomscan.publication_create_link_v1(
      'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text, $4::bytea,
      $5::timestamptz, NULL::bytea, NULL::bytea, 'disabled'::text,
      'enabled'::text, $6::bytea
    )`,
    [
      maxBoundAccess, now, finalized.snapshot_public_id, digest('max-bound-link-token'),
      new Date(now.getTime() + 365 * 24 * 60 * 60 * 1000), digest('max-bound-link-idempotency'),
    ],
  )).rows[0];
  assert.equal(
    new Date(maxBoundLink.expires_at).getTime(), now.getTime() + 365 * 24 * 60 * 60 * 1000,
    'the exact 365-day upper expiry bound must be accepted',
  );
  for (const [label, expiresAt] of [
    ['below-one-hour', new Date(now.getTime() + 60 * 60 * 1000 - 1)],
    ['above-365-days', new Date(now.getTime() + 365 * 24 * 60 * 60 * 1000 + 1)],
  ]) {
    await assert.rejects(
      () => apiPool.query(
        `SELECT * FROM roomscan.publication_create_link_v1(
          'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text, $4::bytea,
          $5::timestamptz, NULL::bytea, NULL::bytea, 'disabled'::text,
          'enabled'::text, $6::bytea
        )`,
        [
          maxBoundAccess, now, finalized.snapshot_public_id, digest(`${label}-link-token`),
          expiresAt, digest(`${label}-link-idempotency`),
        ],
      ),
      (error) => error?.code === '22023' && error?.message === 'PUBLICATION_LINK_EXPIRY_OUT_OF_RANGE',
      `${label} expiry must fail closed`,
    );
  }
  for (const policy of [null, 'Enabled', 'disabled ']) {
    await assert.rejects(
      () => apiPool.query(
        `SELECT * FROM roomscan.publication_create_link_v1(
          'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text, $4::bytea,
          NULL::timestamptz, NULL::bytea, NULL::bytea, $5::text,
          'enabled'::text, $6::bytea
        )`,
        [
          maxBoundAccess, now, finalized.snapshot_public_id,
          digest(`invalid-ai-policy-token:${String(policy)}`), policy,
          digest(`invalid-ai-policy-idempotency:${String(policy)}`),
        ],
      ),
      (error) => error?.code === '22023' && error?.message === 'INVALID_PUBLICATION_LINK',
      `AI policy ${String(policy)} must not coerce to an enabled/disabled capability`,
    );
  }
  for (const policy of [null, 'Enabled', 'disabled ']) {
    await assert.rejects(
      () => apiPool.query(
        `SELECT * FROM roomscan.publication_create_link_v1(
          'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text, $4::bytea,
          NULL::timestamptz, NULL::bytea, NULL::bytea, 'disabled'::text,
          $5::text, $6::bytea
        )`,
        [
          maxBoundAccess, now, finalized.snapshot_public_id,
          digest(`invalid-feedback-policy-token:${String(policy)}`), policy,
          digest(`invalid-feedback-policy-idempotency:${String(policy)}`),
        ],
      ),
      (error) => error?.code === '22023' && error?.message === 'INVALID_PUBLICATION_LINK',
      `feedback policy ${String(policy)} must not coerce to an enabled/disabled capability`,
    );
  }
  const pinParameters = (await portalPool.query(
    'SELECT * FROM roomscan.portal_pin_parameters_v1($1::bytea, $2::timestamptz)',
    [portalSessionHash, now],
  )).rows[0];
  assert.deepEqual(Object.keys(pinParameters).sort(), [
    'key_length', 'pin_salt', 'scrypt_n', 'scrypt_p', 'scrypt_r',
  ], 'the portal PIN parameter seam must expose only salt and fixed KDF parameters');
  assert.deepEqual(pinParameters.pin_salt, portalPinSalt);
  assert.deepEqual(derivePortalPin('123456', pinParameters.pin_salt), portalPinVerifier,
    'the service can derive the exact six-ASCII-digit verifier from the portal-only KDF parameters');
  assert.deepEqual({
    scrypt_n: Number(pinParameters.scrypt_n),
    scrypt_r: Number(pinParameters.scrypt_r),
    scrypt_p: Number(pinParameters.scrypt_p),
    key_length: Number(pinParameters.key_length),
  }, {
    scrypt_n: pinScrypt.N,
    scrypt_r: pinScrypt.r,
    scrypt_p: pinScrypt.p,
    key_length: pinScrypt.keyLength,
  }, 'the PIN parameter seam must return fixed approved memory-hard scrypt values');
  for (let attempt = 1; attempt <= 5; attempt += 1) {
    const pin = (await portalPool.query(
      'SELECT * FROM roomscan.portal_pin_attempt_v1($1::bytea, $2::timestamptz, $3::bytea)',
      [portalSessionHash, now, digest(`wrong-pin-${attempt}`)],
    )).rows[0];
    assert.equal(
      pin.status,
      attempt === 5 ? 'cooldown' : 'denied',
      `wrong PIN attempt ${attempt} must enforce the bounded five-attempt throttle`,
    );
  }
  const cooling = (await portalPool.query(
    'SELECT * FROM roomscan.portal_pin_attempt_v1($1::bytea, $2::timestamptz, $3::bytea)',
    [portalSessionHash, new Date(now.getTime() + 15 * 60 * 1000 - 1), portalPinVerifier],
  )).rows[0];
  assert.equal(cooling.status, 'cooldown', 'five wrong PINs must retain a full fifteen-minute cooldown');
  const verified = (await portalPool.query(
    'SELECT * FROM roomscan.portal_verify_pin_v1($1::bytea, $2::timestamptz, $3::bytea)',
    [portalSessionHash, new Date(now.getTime() + 15 * 60 * 1000), portalPinVerifier],
  )).rows[0];
  assert.equal(verified.status, 'verified');
  assert.deepEqual((await bootstrapPool.query(
    `SELECT failed_attempts, window_started_at, cooldown_until
       FROM roomscan.portal_pin_throttles
      WHERE workspace_id = $1 AND link_id = $2 AND link_generation = 1`,
    [ids.workspaceA, link.link_id],
  )).rows[0], {
    failed_attempts: 0,
    window_started_at: null,
    cooldown_until: null,
  }, 'a correct PIN after cooldown expiry must reset the bounded per-link throttle state');

  const portalSnapshotCapabilities = (await portalPool.query(
    'SELECT * FROM roomscan.portal_get_snapshot_v2($1::bytea, $2::timestamptz)',
    [portalSessionHash, new Date(now.getTime() + 15 * 60 * 1000)],
  )).rows[0];
  assert.deepEqual(
    {
      status: portalSnapshotCapabilities.status,
      snapshot_public_id: portalSnapshotCapabilities.snapshot_public_id,
      ai_enabled: portalSnapshotCapabilities.ai_enabled,
      feedback_enabled: portalSnapshotCapabilities.feedback_enabled,
    },
    {
      status: 'allowed',
      snapshot_public_id: finalized.snapshot_public_id,
      ai_enabled: true,
      feedback_enabled: true,
    },
    'the same live snapshot projection must positively surface enabled AI and feedback capabilities after PIN verification',
  );
  const portalSnapshot = (await portalPool.query(
    'SELECT * FROM roomscan.portal_get_snapshot_v1($1::bytea, $2::timestamptz)',
    [portalSessionHash, new Date(now.getTime() + 15 * 60 * 1000)],
  )).rows[0];
  assert.equal(portalSnapshot.snapshot_public_id, finalized.snapshot_public_id);
  const delivered = (await portalPool.query(
    `SELECT * FROM roomscan.portal_authorize_asset_v1(
      $1::bytea, $2::timestamptz, 'ast_slice6floorplan0001'::text, $3::bytea, 0::bigint, 256::bigint
    )`,
    [portalSessionHash, new Date(now.getTime() + 15 * 60 * 1000), digest('asset-request')],
  )).rows[0];
  assert.equal(delivered.status, 'allowed');
  assert.equal(delivered.delivered_bytes, '0');
  assert.equal(delivered.already_accounted, false);
  assert.equal(Number((await bootstrapPool.query(
    `SELECT used FROM roomscan.quota_usage_v2
      WHERE workspace_id = $1 AND metric = 'portal_bytes' AND period_key = 'roomscan-period-v1:slice6'`,
    [ids.workspaceA],
  )).rows[0].used), 0,
  'an authorized reservation that represents a failed/unattempted exact-version read must record zero portal bytes');
  await assert.rejects(
    () => portalPool.query(
      `SELECT * FROM roomscan.portal_finalize_asset_delivery_v1(
        $1::bytea, $2::timestamptz, $3::text, $4::bytea, 0::bigint,
        256::bigint, 'wrong-object-version'::text
      )`,
      [
        portalSessionHash, new Date(now.getTime() + 15 * 60 * 1000),
        delivered.asset_public_id, digest('asset-request'),
      ],
    ),
    (error) => error?.code === 'P0001' && error?.message === 'PORTAL_ASSET_NOT_FOUND',
    'final accounting must bind the exact object version that was reserved before the storage read',
  );
  const deliveredFinal = await finalizePortalDelivery({
    sessionHash: portalSessionHash, at: new Date(now.getTime() + 15 * 60 * 1000),
    authorization: delivered, requestDigest: digest('asset-request'),
  });
  assert.equal(deliveredFinal.delivered_bytes, '256');
  assert.equal(deliveredFinal.already_accounted, false);
  assert.equal(Number((await bootstrapPool.query(
    `SELECT used FROM roomscan.quota_usage_v2
      WHERE workspace_id = $1 AND metric = 'portal_bytes' AND period_key = 'roomscan-period-v1:slice6'`,
    [ids.workspaceA],
  )).rows[0].used), 256,
  'only the post-read live finalizer may atomically account delivered portal bytes');
  const pdfDownload = (await portalPool.query(
    `SELECT * FROM roomscan.portal_authorize_download_v1(
      $1::bytea, $2::timestamptz, 'floor_plan_pdf'::text, $3::bytea, 0::bigint, 64::bigint
    )`,
    [portalSessionHash, new Date(now.getTime() + 15 * 60 * 1000), digest('floor-plan-pdf-download')],
  )).rows[0];
  assert.equal(pdfDownload.status, 'allowed');
  assert.equal(pdfDownload.content_type, 'application/pdf');
  assert.equal((await finalizePortalDelivery({
    sessionHash: portalSessionHash, at: new Date(now.getTime() + 15 * 60 * 1000),
    authorization: pdfDownload, requestDigest: digest('floor-plan-pdf-download'),
  })).delivered_bytes, '64');
  const galleryDownload = (await portalPool.query(
    `SELECT * FROM roomscan.portal_authorize_download_v1(
      $1::bytea, $2::timestamptz, 'gallery_zip'::text, $3::bytea, 0::bigint, 64::bigint
    )`,
    [portalSessionHash, new Date(now.getTime() + 15 * 60 * 1000), digest('gallery-zip-download')],
  )).rows[0];
  assert.equal(galleryDownload.status, 'allowed');
  assert.equal(galleryDownload.content_type, 'application/zip');
  assert.equal((await finalizePortalDelivery({
    sessionHash: portalSessionHash, at: new Date(now.getTime() + 15 * 60 * 1000),
    authorization: galleryDownload, requestDigest: digest('gallery-zip-download'),
  })).delivered_bytes, '64');
  const aiDownload = (await portalPool.query(
    `SELECT * FROM roomscan.portal_authorize_download_v1(
      $1::bytea, $2::timestamptz, 'ai_ready_package'::text, $3::bytea, 0::bigint, 128::bigint
    )`,
    [portalSessionHash, new Date(now.getTime() + 15 * 60 * 1000), digest('ai-ready-download')],
  )).rows[0];
  assert.equal(aiDownload.status, 'allowed');
  assert.equal(aiDownload.content_type, 'application/zip');
  assert.equal((await finalizePortalDelivery({
    sessionHash: portalSessionHash, at: new Date(now.getTime() + 15 * 60 * 1000),
    authorization: aiDownload, requestDigest: digest('ai-ready-download'),
  })).delivered_bytes, '128');
  assert.equal(Number((await bootstrapPool.query(
    `SELECT used FROM roomscan.quota_usage_v2
      WHERE workspace_id = $1 AND metric = 'portal_bytes' AND period_key = 'roomscan-period-v1:slice6'`,
    [ids.workspaceA],
  )).rows[0].used), 512, 'portal quota must account the exact aggregate protected bytes');
  const sameChunk = (await portalPool.query(
    `SELECT * FROM roomscan.portal_authorize_asset_v1(
      $1::bytea, $2::timestamptz, 'ast_slice6floorplan0001'::text, $3::bytea,
      0::bigint, 256::bigint
    )`,
    [portalSessionHash, new Date(now.getTime() + 15 * 60 * 1000), digest('asset-request')],
  )).rows[0];
  assert.equal(sameChunk.already_accounted, true, 'an exact idempotent range retry must charge portal bytes once');
  await assert.rejects(
    () => portalPool.query(
      `SELECT * FROM roomscan.portal_authorize_asset_v1(
        $1::bytea, $2::timestamptz, 'ast_slice6floorplan0001'::text, $3::bytea,
        1::bigint, 256::bigint
      )`,
      [portalSessionHash, new Date(now.getTime() + 15 * 60 * 1000), digest('asset-request')],
    ),
    (error) => error?.code === 'P0001' && error?.message === 'PORTAL_DELIVERY_IDEMPOTENCY_REUSED',
    'a delivery digest may not be replayed for an equal-length but different byte offset',
  );
  const secondChunk = (await portalPool.query(
    `SELECT * FROM roomscan.portal_authorize_asset_v1(
      $1::bytea, $2::timestamptz, 'ast_slice6floorplan0001'::text, $3::bytea,
      256::bigint, 256::bigint
    )`,
    [portalSessionHash, new Date(now.getTime() + 15 * 60 * 1000), digest('asset-request-offset-256')],
  )).rows[0];
  assert.equal(secondChunk.byte_offset, '256');
  assert.equal(secondChunk.byte_length, '256');
  assert.equal((await finalizePortalDelivery({
    sessionHash: portalSessionHash, at: new Date(now.getTime() + 15 * 60 * 1000),
    authorization: secondChunk, requestDigest: digest('asset-request-offset-256'),
  })).delivered_bytes, '256',
  'a distinct exact range and digest must finalize as a separate portal-byte delivery');
  const failedReadReservation = (await portalPool.query(
    `SELECT * FROM roomscan.portal_authorize_asset_v1(
      $1::bytea, $2::timestamptz, 'ast_slice6floorplan0001'::text, $3::bytea,
      0::bigint, 1::bigint
    )`,
    [portalSessionHash, new Date(now.getTime() + 15 * 60 * 1000), digest('asset-read-failed')],
  )).rows[0];
  assert.equal(failedReadReservation.delivered_bytes, '0');
  assert.equal(Number((await bootstrapPool.query(
    `SELECT used FROM roomscan.quota_usage_v2
      WHERE workspace_id = $1 AND metric = 'portal_bytes' AND period_key = 'roomscan-period-v1:slice6'`,
    [ids.workspaceA],
  )).rows[0].used), 768,
  'a storage-read failure represented by an unfinalized reservation must not charge bytes after prior successful chunks');
  await assert.rejects(
    () => portalPool.query(
      `SELECT * FROM roomscan.portal_authorize_asset_v1(
        $1::bytea, $2::timestamptz, 'ast_slice6floorplan0001'::text, $3::bytea,
        512::bigint, 1::bigint
      )`,
      [portalSessionHash, new Date(now.getTime() + 15 * 60 * 1000), digest('asset-request-overrun')],
    ),
    (error) => error?.code === 'P0001' && error?.message === 'PORTAL_ASSET_NOT_FOUND',
    'a positive out-of-bounds range probe must reach and reject the exact asset-size guard',
  );

  const feedbackIssueAt = new Date(now.getTime() + 15 * 60 * 1000);
  const feedbackRequestDigest = digest('feedback-request-idempotency');
  const challenge = await requestFeedbackVerification({
    sessionHash: portalSessionHash, at: feedbackIssueAt,
    challengeHash: digest('challenge'), verificationTokenHash: digest('verification-token'),
    verifiedEmailDigest: digest('verified-email'), requestDigest: feedbackRequestDigest,
    envelopeLabel: 'feedback-primary',
  });
  assert.equal(challenge.status, 'issued');
  const replayedChallenge = await requestFeedbackVerification({
    sessionHash: portalSessionHash, at: new Date(feedbackIssueAt.getTime() + 1_000),
    // A retry can have regenerated one-time values; the server-HMAC request
    // identity makes this a semantic replay, not a second email send.
    challengeHash: digest('challenge-retry'), verificationTokenHash: digest('verification-token-retry'),
    verifiedEmailDigest: digest('verified-email'), requestDigest: feedbackRequestDigest,
    envelopeLabel: 'feedback-primary-retry',
  });
  assert.deepEqual(
    {
      status: replayedChallenge.status,
      challenge_id: replayedChallenge.challenge_id,
      expires_at: new Date(replayedChallenge.expires_at).getTime(),
    },
    {
      status: 'existing',
      challenge_id: challenge.challenge_id,
      expires_at: new Date(challenge.expires_at).getTime(),
    },
    'a lost feedback-issue response must replay one challenge rather than queue a second email',
  );
  assert.equal(Number((await bootstrapPool.query(
    `SELECT count(*)::integer AS count FROM roomscan.portal_feedback_delivery_outbox
      WHERE challenge_id = $1::uuid`,
    [challenge.challenge_id],
  )).rows[0].count), 1,
  'feedback issue replay must retain exactly one sealed delivery envelope');
  await assert.rejects(
    () => requestFeedbackVerification({
      sessionHash: portalSessionHash, at: new Date(feedbackIssueAt.getTime() + 2_000),
      challengeHash: digest('challenge-conflict'), verificationTokenHash: digest('verification-token-conflict'),
      verifiedEmailDigest: digest('other-verified-email'), requestDigest: feedbackRequestDigest,
      envelopeLabel: 'feedback-primary-conflict',
    }),
    (error) => error?.code === 'P0001' && error?.message === 'FEEDBACK_REQUEST_IDEMPOTENCY_CONFLICT',
    'a reused feedback request digest with changed verified-email scope must not silently retarget email delivery',
  );
  const feedbackLease = 'feedback-primary-lease';
  const leasedFeedback = (await emailPool.query(
    `SELECT * FROM roomscan.claim_next_feedback_delivery_v3(
      $1::text, $2::timestamptz, $3::timestamptz
    )`,
    [feedbackLease, feedbackIssueAt, new Date(feedbackIssueAt.getTime() + 5 * 60 * 1000)],
  )).rows[0];
  assert.deepEqual(
    Object.keys(leasedFeedback).sort(),
    [
      'authentication_tag', 'ciphertext', 'delivery_attempts', 'delivery_id',
      'envelope_version', 'expires_at', 'iv', 'key_id', 'lease_expires_at',
      'lease_id', 'status',
    ],
    'the email runtime must receive only the explicit encrypted-envelope projection',
  );
  assert.equal(leasedFeedback.status, 'leased');
  assert.equal(leasedFeedback.delivery_id.startsWith('pfd_'), true);
  const preDeliveryConsume = (await portalPool.query(
    `SELECT * FROM roomscan.portal_consume_feedback_verification_v1(
      $1::bytea, $2::bytea, $3::timestamptz, $4::bytea
    )`,
    [portalSessionHash, digest('challenge'), new Date(feedbackIssueAt.getTime() + 1_000), digest('verification-token')],
  )).rows[0];
  assert.equal(preDeliveryConsume.status, 'unavailable',
    'a verification token must remain unusable before its sealed email delivery completes');
  const validatedFeedback = (await emailPool.query(
    `SELECT * FROM roomscan.validate_feedback_delivery_v3(
      $1::text, $2::text, $3::timestamptz
    )`,
    [leasedFeedback.delivery_id, feedbackLease, new Date(feedbackIssueAt.getTime() + 2_000)],
  )).rows[0];
  assert.equal(validatedFeedback.status, 'send',
    'the email worker pre-send check must preserve a live encrypted-envelope delivery');
  assert.equal((await emailPool.query(
    `SELECT roomscan.complete_feedback_delivery_v3($1::text, $2::text, $3::timestamptz) AS completed`,
    [leasedFeedback.delivery_id, feedbackLease, new Date(feedbackIssueAt.getTime() + 3_000)],
  )).rows[0].completed, true,
  'only the sealed email runtime can durably mark the issued verification delivery complete');
  const forgedConsume = (await portalPool.query(
    `SELECT * FROM roomscan.portal_consume_feedback_verification_v1(
      $1::bytea, $2::bytea, $3::timestamptz, $4::bytea
    )`,
    [portalSessionHash, digest('challenge'), new Date(now.getTime() + 16 * 60 * 1000), digest('forged-verification-token')],
  )).rows[0];
  assert.equal(forgedConsume.status, 'unavailable', 'a wrong feedback token must not become the verifier at consume time');
  const consumed = (await portalPool.query(
    `SELECT * FROM roomscan.portal_consume_feedback_verification_v1(
      $1::bytea, $2::bytea, $3::timestamptz, $4::bytea
    )`,
    [portalSessionHash, digest('challenge'), new Date(now.getTime() + 16 * 60 * 1000), digest('verification-token')],
  )).rows[0];
  assert.equal(consumed.status, 'verified');
  assert.deepEqual((await bootstrapPool.query(
    `SELECT verification_token_hash FROM roomscan.portal_feedback_challenges
      WHERE challenge_id = $1::uuid`,
    [challenge.challenge_id],
  )).rows[0].verification_token_hash, digest('verification-token'),
  'the issuance-committed verification hash must survive a wrong-token attempt unchanged');
  const feedback = (await portalPool.query(
    `SELECT * FROM roomscan.portal_create_feedback_v1(
      $1::bytea, $2::timestamptz, $3::bytea, 'comment'::text,
      'Looks good'::text, $4::bytea
    )`,
    [portalSessionHash, new Date(now.getTime() + 16 * 60 * 1000), digest('verification-token'), digest('feedback')],
  )).rows[0];
  assert.equal(feedback.status, 'recorded');
  assert.equal(feedback.display_label, 'Verified client');
  await assert.rejects(
    () => portalPool.query(
      `SELECT * FROM roomscan.portal_create_feedback_v1(
        $1::bytea, $2::timestamptz, $3::bytea, 'approve'::text, NULL::text, $4::bytea
      )`,
      [portalSessionHash, new Date(now.getTime() + 16 * 60 * 1000), digest('verification-token'), digest('feedback-replay')],
    ),
    (error) => error?.code === '42501',
    'feedback verification must be single-use',
  );

  const crossLinkAt = new Date(now.getTime() + 16 * 60 * 1000);
  const crossLinkAccess = await seedFreshAccess({ label: 'cross-link-feedback', at: crossLinkAt });
  const crossLink = (await apiPool.query(
    `SELECT * FROM roomscan.publication_create_link_v1(
      'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text, $4::bytea,
      NULL::timestamptz, NULL::bytea, NULL::bytea, 'disabled'::text,
      'enabled'::text, $5::bytea
    )`,
    [
      crossLinkAccess, crossLinkAt, finalized.snapshot_public_id,
      digest('cross-link-token'), digest('cross-link-idempotency'),
    ],
  )).rows[0];
  const crossLinkSessionHash = digest('cross-link-session');
  assert.equal((await portalPool.query(
    `SELECT * FROM roomscan.portal_exchange_link_v1(
      $1::bytea, $2::timestamptz, $3::bytea, 'tablet'::text, $4::bytea
    )`,
    [digest('cross-link-token'), crossLinkAt, crossLinkSessionHash, digest('cross-link-risk')],
  )).rows[0].status, 'active');
  const crossLinkChallenge = await requestFeedbackVerification({
    sessionHash: crossLinkSessionHash, at: crossLinkAt,
    challengeHash: digest('cross-link-challenge'),
    verificationTokenHash: digest('cross-link-verification-token'),
    verifiedEmailDigest: digest('cross-link-email'),
    requestDigest: digest('cross-link-feedback-request'),
    envelopeLabel: 'cross-link-feedback',
  });
  assert.equal(crossLinkChallenge.status, 'issued');
  const crossLinkLease = 'feedback-cross-link-lease';
  const crossLinkDelivery = (await emailPool.query(
    `SELECT * FROM roomscan.claim_next_feedback_delivery_v3($1::text, $2::timestamptz, $3::timestamptz)`,
    [crossLinkLease, crossLinkAt, new Date(crossLinkAt.getTime() + 5 * 60 * 1000)],
  )).rows[0];
  assert.equal(crossLinkDelivery.status, 'leased');
  assert.equal((await emailPool.query(
    `SELECT roomscan.complete_feedback_delivery_v3($1::text, $2::text, $3::timestamptz) AS completed`,
    [crossLinkDelivery.delivery_id, crossLinkLease, new Date(crossLinkAt.getTime() + 1_000)],
  )).rows[0].completed, true);
  assert.equal((await portalPool.query(
    `SELECT * FROM roomscan.portal_consume_feedback_verification_v1(
      $1::bytea, $2::bytea, $3::timestamptz, $4::bytea
    )`,
    [
      crossLinkSessionHash, digest('cross-link-challenge'), crossLinkAt,
      digest('cross-link-verification-token'),
    ],
  )).rows[0].status, 'verified');
  await assert.rejects(
    () => portalPool.query(
      `SELECT * FROM roomscan.portal_create_feedback_v1(
        $1::bytea, $2::timestamptz, $3::bytea, 'approve'::text, NULL::text, $4::bytea
      )`,
      [
        portalSessionHash, crossLinkAt, digest('cross-link-verification-token'),
        digest('cross-link-feedback-request'),
      ],
    ),
    (error) => error?.code === '42501' && error?.message === 'FEEDBACK_VERIFICATION_REQUIRED',
    'a verified feedback token must remain scoped to its exact portal link generation and session',
  );

  const revokeAt = new Date(now.getTime() + 17 * 60 * 1000);
  await assert.rejects(
    () => apiPool.query(
      `SELECT * FROM roomscan.publication_revoke_link_v1(
        'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text, 1::bigint
      )`,
      [accessHash, revokeAt, link.link_public_id],
    ),
    (error) => error?.code === '42501',
    'stale sensitive confirmation must not revoke a portal link',
  );
  const freshRevokeAccessHash = digest('owner-access-reconfirm-revoke');
  await bootstrapPool.query(
    `INSERT INTO roomscan.auth_access_tokens (
       id, family_id, token_hash, expires_at, principal_id,
       authentication_epoch, authenticated_at, issued_at, workspace_id, role,
       authorization_version, state, created_at
     ) VALUES (
       gen_random_uuid(), '52000000-0000-4000-8000-000000000001', $1,
       $2::timestamptz + interval '1 day', $3, 0, $2::timestamptz,
       $2::timestamptz, $4, 'owner', 1, 'active', $2::timestamptz
     )`,
    [freshRevokeAccessHash, revokeAt, ids.principalA, ids.workspaceA],
  );
  const revoked = (await apiPool.query(
    `SELECT * FROM roomscan.publication_revoke_link_v1(
      'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text, 1::bigint
    )`,
    [freshRevokeAccessHash, revokeAt, link.link_public_id],
  )).rows[0];
  assert.equal(revoked.status, 'revoked');
  await assert.rejects(
    () => finalizePortalDelivery({
      sessionHash: portalSessionHash, at: revokeAt,
      authorization: failedReadReservation, requestDigest: digest('asset-read-failed'),
    }),
    (error) => error?.code === '42501',
    'revocation between a successful exact-version storage reservation and final accounting must deny the same active session before any bytes are charged',
  );
  assert.equal(Number((await bootstrapPool.query(
    `SELECT used FROM roomscan.quota_usage_v2
      WHERE workspace_id = $1 AND metric = 'portal_bytes' AND period_key = 'roomscan-period-v1:slice6'`,
    [ids.workspaceA],
  )).rows[0].used), 768,
  'a revoked pre-emission reservation must remain a zero-byte failed delivery');
  await assert.rejects(
    () => portalPool.query(
      'SELECT * FROM roomscan.portal_get_snapshot_v2($1::bytea, $2::timestamptz)',
      [portalSessionHash, revokeAt],
    ),
    (error) => error?.code === '42501',
    'revoked active session must fail on next protected request',
  );
  await assert.rejects(
    () => portalPool.query(
      `SELECT * FROM roomscan.portal_authorize_asset_v1(
        $1::bytea, $2::timestamptz, 'ast_slice6floorplan0001'::text, $3::bytea, 0::bigint, 128::bigint
      )`,
      [portalSessionHash, revokeAt, digest('asset-after-revoke')],
    ),
    (error) => error?.code === '42501',
    'revoked active session must fail on asset request',
  );

  const killPreparedAt = new Date(now.getTime() + 20 * 60 * 1000);
  const preKillVersions = await currentFlagVersions();
  const killAccess = await seedFreshAccess({ label: 'kill-finalization', at: killPreparedAt });
  const killAllocation = await allocatePublication({
    access: killAccess,
    at: killPreparedAt,
    projectPublicID: source.projectPublicId,
    sourceRevisionPublicID: source.revisionPublicId,
    sourceDigest: source.sourceDigest,
    sourceManifestDigest: source.sourceManifestDigest,
    sourceBindings: [sourceBinding(source, 'room-001')],
    label: 'killfinalize0001',
    versions: preKillVersions,
  });
  const killClaim = await completeAndClaimPublication({
    access: killAccess,
    at: killPreparedAt,
    allocation: killAllocation,
    label: 'killfinalize0001',
  });
  const terminalKillAllocation = await allocatePublication({
    access: killAccess,
    at: killPreparedAt,
    projectPublicID: source.projectPublicId,
    sourceRevisionPublicID: source.revisionPublicId,
    sourceDigest: source.sourceDigest,
    sourceManifestDigest: source.sourceManifestDigest,
    sourceBindings: [sourceBinding(source, 'room-001')],
    label: 'killterminal0001',
    versions: preKillVersions,
  });
  assert.equal((await apiPool.query(
    `SELECT * FROM roomscan.publication_complete_v2(
      'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text, $4::bytea,
      $5::bytea, 2048::bigint
    )`,
    [
      killAccess, killPreparedAt, terminalKillAllocation.allocation_public_id,
      digest('killterminal0001:archive'), digest('killterminal0001:archive-manifest'),
    ],
  )).rows[0].status, 'validation_pending');
  const killActiveLink = (await apiPool.query(
    `SELECT * FROM roomscan.publication_create_link_v1(
      'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text, $4::bytea,
      NULL::timestamptz, NULL::bytea, NULL::bytea, 'disabled'::text,
      'enabled'::text, $5::bytea
    )`,
    [
      killAccess, killPreparedAt, finalized.snapshot_public_id,
      digest('kill-active-link-token'), digest('kill-active-link-idempotency'),
    ],
  )).rows[0];
  const killActiveSessionHash = digest('kill-active-session');
  assert.equal((await portalPool.query(
    `SELECT * FROM roomscan.portal_exchange_link_v1(
      $1::bytea, $2::timestamptz, $3::bytea, 'mobile'::text, $4::bytea
    )`,
    [
      digest('kill-active-link-token'), killPreparedAt, killActiveSessionHash,
      digest('kill-active-risk'),
    ],
  )).rows[0].status, 'active', 'an active portal session must exist before the kill switch transition');
  const killAt = new Date(now.getTime() + 21 * 60 * 1000);
  await setFlag(
    'global', null, 'publication_enabled', 'ofaud_s6publication_global_kill', false, killAt,
  );
  assert.equal((await workerPool.query(
    'SELECT * FROM roomscan.publication_claim_job_v1($1::timestamptz)', [killAt],
  )).rows[0].status, 'publication_disabled',
  'a worker must observe the kill switch before beginning pending validation');
  assert.deepEqual((await bootstrapPool.query(
    `SELECT allocation.state AS allocation_state, job.state AS job_state, job.rejection_code
       FROM roomscan.publication_allocations AS allocation
       JOIN roomscan.publication_jobs AS job
         ON job.workspace_id = allocation.workspace_id AND job.allocation_id = allocation.allocation_id
      WHERE allocation.allocation_id = $1::uuid`,
    [terminalKillAllocation.allocation_id],
  )).rows[0], {
    allocation_state: 'rejected', job_state: 'rejected', rejection_code: 'publication_disabled',
  }, 'a killed pending job must transition terminally instead of remaining claimable forever');
  await assert.rejects(
    () => finalizePublication({ claim: killClaim, at: killAt, label: 'killfinalize0001' }),
    (error) => error?.code === '42501' && error?.message === 'PUBLICATION_GRANT_REJECTED',
    'a kill switch change during validation must deny immutable snapshot finalization',
  );
  const blockedAccess = await seedFreshAccess({ label: 'kill-link-create', at: killAt });
  await assert.rejects(
    () => apiPool.query(
      `SELECT * FROM roomscan.publication_create_link_v1(
        'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text, $4::bytea,
        NULL::timestamptz, NULL::bytea, NULL::bytea, 'disabled'::text,
        'enabled'::text, $5::bytea
      )`,
      [
        blockedAccess, killAt, finalized.snapshot_public_id, digest('killed-link-token'),
        digest('killed-link-idempotency'),
      ],
    ),
    (error) => error?.code === '42501' && error?.message === 'PUBLICATION_GRANT_REJECTED',
    'the kill switch must deny new link authorization as well as finalization',
  );
  for (const [label, call] of [
    ['snapshot', () => portalPool.query(
      'SELECT * FROM roomscan.portal_get_snapshot_v2($1::bytea, $2::timestamptz)',
      [killActiveSessionHash, killAt],
    )],
    ['asset', () => portalPool.query(
      `SELECT * FROM roomscan.portal_authorize_asset_v1(
        $1::bytea, $2::timestamptz, 'ast_slice6floorplan0001'::text, $3::bytea, 0::bigint, 64::bigint
      )`,
      [killActiveSessionHash, killAt, digest('kill-active-asset')],
    )],
    ['download', () => portalPool.query(
      `SELECT * FROM roomscan.portal_authorize_download_v1(
        $1::bytea, $2::timestamptz, 'floor_plan_pdf'::text, $3::bytea, 0::bigint, 64::bigint
      )`,
      [killActiveSessionHash, killAt, digest('kill-active-download')],
    )],
    ['feedback', () => portalPool.query(
      `SELECT * FROM roomscan.portal_request_feedback_verification_v3(
        $1::bytea, $2::timestamptz, $3::bytea, $4::bytea, $5::bytea,
        'test-feedback-key-v1'::text, $6::bytea, $7::bytea, $8::bytea, $9::bytea
      )`,
      [
        killActiveSessionHash, killAt, digest('kill-active-challenge'), digest('kill-active-token'),
        digest('kill-active-email'), digest('kill-active-feedback:iv').subarray(0, 12),
        digest('kill-active-feedback:ciphertext'), digest('kill-active-feedback:tag').subarray(0, 16),
        digest('kill-active-feedback:request'),
      ],
    )],
  ]) {
    await assert.rejects(
      call,
      (error) => error?.code === '42501',
      `the kill switch must deny the active portal ${label} request`,
    );
  }
  const recoveryAccess = await seedFreshAccess({ label: 'private-recovery-after-kill', at: killAt });
  const recoveryRows = (await apiPool.query(
    `SELECT * FROM roomscan.resolve_project_recovery_storage_v1(
      $1::bytea, $2::timestamptz, 'prj_slice6project0001'::text, NULL::text
    )`,
    [recoveryAccess, killAt],
  )).rows;
  assert.equal(recoveryRows.length, 1, 'private Slice 5 recovery must remain usable while publication is killed');
  await setFlag(
    'global', null, 'publication_enabled', 'ofaud_s6publication_global_restore', true,
    new Date(now.getTime() + 22 * 60 * 1000),
  );

  const pinFlagCases = [
    ['hosted-global', 'global', null, 'hosted_operations_enabled'],
    ['hosted-workspace', 'workspace', ids.workspaceA, 'hosted_operations_enabled'],
    ['publication-global', 'global', null, 'publication_enabled'],
    ['publication-workspace', 'workspace', ids.workspaceA, 'publication_enabled'],
  ];
  for (const [index, [label, scope, workspaceID, flagKey]] of pinFlagCases.entries()) {
    const pinAt = new Date(now.getTime() + (30 + index * 2) * 60 * 1000);
    const flagVersions = await currentFlagVersions();
    const pinAccess = await seedFreshAccess({ label: `pin-${label}`, at: pinAt });
    const pinLink = (await apiPool.query(
      `SELECT * FROM roomscan.publication_create_link_v1(
        'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text, $4::bytea,
        NULL::timestamptz, $5::bytea, $6::bytea, 'disabled'::text,
        'enabled'::text, $7::bytea
      )`,
      [
        pinAccess, pinAt, finalized.snapshot_public_id, digest(`pin-${label}-token`),
        digest(`pin-${label}-salt`), digest(`pin-${label}-verifier`),
        digest(`pin-${label}-idempotency`),
      ],
    )).rows[0];
    const pinSessionHash = digest(`pin-${label}-session`);
    assert.equal((await portalPool.query(
      `SELECT * FROM roomscan.portal_exchange_link_v1(
        $1::bytea, $2::timestamptz, $3::bytea, 'mobile'::text, $4::bytea
      )`,
      [
        digest(`pin-${label}-token`), pinAt, pinSessionHash,
        digest(`pin-${label}-risk`),
      ],
    )).rows[0].status, 'pin_required', `${label} test must create a PIN-gated session`);
    const disabledAt = new Date(pinAt.getTime() + 1000);
    await setFlag(scope, workspaceID, flagKey, `ofaud_s6_pin_${label}_off`, false, disabledAt);
    const unavailablePinParameters = await portalPool.query(
      'SELECT * FROM roomscan.portal_pin_parameters_v1($1::bytea, $2::timestamptz)',
      [pinSessionHash, disabledAt],
    );
    assert.equal(unavailablePinParameters.rowCount, 0,
      `${label} kill switch must deny the portal-only PIN parameter seam before a verifier can be attempted`);
    const pinResult = (await portalPool.query(
      index % 2 === 0
        ? 'SELECT * FROM roomscan.portal_pin_attempt_v1($1::bytea, $2::timestamptz, $3::bytea)'
        : 'SELECT * FROM roomscan.portal_verify_pin_v1($1::bytea, $2::timestamptz, $3::bytea)',
      [pinSessionHash, disabledAt, digest(`pin-${label}-verifier`)],
    )).rows[0];
    assert.equal(
      pinResult.status,
      'unavailable',
      `${label} kill epoch must be rechecked before every PIN attempt/verify`,
    );
    await setFlag(
      scope, workspaceID, flagKey, `ofaud_s6_pin_${label}_restore`, true,
      new Date(disabledAt.getTime() + 1000),
    );
    assert.ok(pinLink.link_public_id, `${label} control must reach a real portal link before the flag denial`);
  }

  const propertyGuardAt = new Date(now.getTime() + 44 * 60 * 1000);
  const propertyGuardAccess = await seedFreshAccess({ label: 'property-publication-guard', at: propertyGuardAt });
  await setFlag(
    'workspace', ids.workspaceA, 'publication_enabled',
    'ofaud_s6_property_guard_off', false, propertyGuardAt,
  );
  const curationWhilePublicationDisabled = await upsertPublicationProperty({
    access: propertyGuardAccess, at: propertyGuardAt,
    propertyPublicID: 'prop_slice6guard000001', expectedVersion: 0,
    title: 'Curation stays a private professional action',
    rooms: [{ publicRoomKey: 'room-001', projectPublicID: source.projectPublicId }],
  });
  assert.equal(curationWhilePublicationDisabled.status, 'created',
    'property curation must use project.revise and remain available while the publication kill switch is active');
  await setFlag(
    'workspace', ids.workspaceA, 'publication_enabled',
    'ofaud_s6_property_guard_restore', true,
    new Date(propertyGuardAt.getTime() + 1000),
  );
  const propertyAt = new Date(now.getTime() + 45 * 60 * 1000);
  const propertyVersions = await currentFlagVersions();
  const propertyAccess = await seedFreshAccess({ label: 'property-presentation', at: propertyAt });
  await assert.rejects(
    () => upsertPublicationProperty({
      access: propertyAccess, at: propertyAt,
      propertyPublicID: 'prop_slice6duplicate0001', expectedVersion: 0,
      title: 'Duplicate draft',
      rooms: [
        { publicRoomKey: 'room-001', projectPublicID: source.projectPublicId },
        { publicRoomKey: 'room-001', projectPublicID: sourceA2.projectPublicId },
      ],
    }),
    (error) => error?.code === '22023' && error?.message === 'INVALID_PUBLICATION_PROPERTY_ROOMS',
    'atomic property curation must fail closed on duplicate ordered room keys',
  );
  await assert.rejects(
    () => upsertPublicationProperty({
      access: propertyAccess, at: propertyAt,
      propertyPublicID: 'prop_slice6titlelimit0001', expectedVersion: 0,
      title: 'x'.repeat(181), rooms: [],
    }),
    (error) => error?.code === '22023' && error?.message === 'INVALID_PUBLICATION_PROPERTY',
    'property curation must enforce the professional 180-character title boundary',
  );
  const removableDraft = await upsertPublicationProperty({
    access: propertyAccess, at: propertyAt,
    propertyPublicID: 'prop_slice6removable0001', expectedVersion: 0,
    title: 'Removable draft',
    rooms: [
      { publicRoomKey: 'room-001', projectPublicID: source.projectPublicId },
      { publicRoomKey: 'room-002', projectPublicID: sourceA2.projectPublicId },
    ],
  });
  const removedDraft = await upsertPublicationProperty({
    access: propertyAccess, at: propertyAt,
    propertyPublicID: removableDraft.property_public_id,
    expectedVersion: Number(removableDraft.curation_version),
    title: 'Removable draft',
    rooms: [{ publicRoomKey: 'room-002', projectPublicID: sourceA2.projectPublicId }],
  });
  assert.equal(removedDraft.room_count, 1,
    'one atomic property upsert must remove omitted rooms instead of retaining stale curation rows');
  assert.deepEqual((await bootstrapPool.query(
    `SELECT room_key, room_order FROM roomscan.publication_property_rooms
      WHERE workspace_id = $1::uuid AND property_id = $2::uuid ORDER BY room_order`,
    [ids.workspaceA, removableDraft.property_id],
  )).rows, [{ room_key: 'room-002', room_order: 1 }]);
  const property = await upsertPublicationProperty({
    access: propertyAccess, at: propertyAt,
    propertyPublicID: 'prop_slice6property0001', expectedVersion: 0,
    title: 'Independent room tour',
    rooms: [
      { publicRoomKey: 'room-001', projectPublicID: source.projectPublicId },
      { publicRoomKey: 'room-002', projectPublicID: sourceA2.projectPublicId },
    ],
  });
  assert.equal(property.status, 'created');
  assert.equal(property.room_count, 2, 'one atomic upsert must replace the complete ordered curation list');
  const propertyAllocation = await allocatePublication({
    access: propertyAccess,
    at: propertyAt,
    projectPublicID: source.projectPublicId,
    sourceRevisionPublicID: source.revisionPublicId,
    sourceDigest: source.sourceDigest,
    sourceManifestDigest: source.sourceManifestDigest,
    sourceBindings: [
      sourceBinding(source, 'room-001'),
      sourceBinding(sourceA2, 'room-002'),
    ],
    label: 'propertysnapshot0001',
    publicationKind: 'property',
    propertyPublicID: property.property_public_id,
    versions: propertyVersions,
  });
  const propertyClaim = await completeAndClaimPublication({
    access: propertyAccess,
    at: propertyAt,
    allocation: propertyAllocation,
    label: 'propertysnapshot0001',
  });
  const propertyFinalized = await finalizePublication({
    claim: propertyClaim,
    at: propertyAt,
    label: 'propertysnapshot0001',
  });
  assert.equal(propertyFinalized.status, 'published');
  const propertyPinSalt = digest('property-pin-salt');
  const propertyPinVerifier = derivePortalPin('123456', propertyPinSalt);
  const propertyPinLink = (await apiPool.query(
    `SELECT * FROM roomscan.publication_create_link_v1(
      'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text, $4::bytea,
      NULL::timestamptz, $5::bytea, $6::bytea, 'disabled'::text,
      'enabled'::text, $7::bytea
    )`,
    [
      propertyAccess, propertyAt, propertyFinalized.snapshot_public_id,
      digest('property-pin-link-token'), propertyPinSalt, propertyPinVerifier,
      digest('property-pin-link-idempotency'),
    ],
  )).rows[0];
  const propertyPinSessionHash = digest('property-pin-session');
  assert.equal((await portalPool.query(
    `SELECT * FROM roomscan.portal_exchange_link_v1(
      $1::bytea, $2::timestamptz, $3::bytea, 'tablet'::text, $4::bytea
    )`,
    [
      digest('property-pin-link-token'), propertyAt, propertyPinSessionHash,
      digest('property-pin-risk'),
    ],
  )).rows[0].status, 'pin_required',
  'PIN snapshot-binding positive control must create a real PIN-required portal session');
  const mismatchedPinSession = await bootstrapPool.query(
    `UPDATE roomscan.portal_sessions
        SET snapshot_id = $1::uuid
      WHERE session_hash = $2::bytea`,
    [finalized.snapshot_id, propertyPinSessionHash],
  );
  assert.equal(mismatchedPinSession.rowCount, 1,
    'PIN snapshot-binding probe must detach one mutable portal session from its live link snapshot');
  const mismatchedPinAttempt = (await portalPool.query(
    'SELECT * FROM roomscan.portal_pin_attempt_v1($1::bytea, $2::timestamptz, $3::bytea)',
    [propertyPinSessionHash, propertyAt, propertyPinVerifier],
  )).rows[0];
  assert.equal(mismatchedPinAttempt.status, 'unavailable',
    'a PIN attempt must deny when its active link and portal session name different snapshots');
  await bootstrapPool.query(
    `UPDATE roomscan.portal_sessions
        SET snapshot_id = $1::uuid
      WHERE session_hash = $2::bytea`,
    [propertyFinalized.snapshot_id, propertyPinSessionHash],
  );
  assert.equal((await portalPool.query(
    'SELECT * FROM roomscan.portal_pin_attempt_v1($1::bytea, $2::timestamptz, $3::bytea)',
    [propertyPinSessionHash, propertyAt, propertyPinVerifier],
  )).rows[0].status, 'verified',
  'the same correct PIN must work once the portal session is restored to its live link snapshot');
  assert.deepEqual((await bootstrapPool.query(
    `SELECT room_order, room_key, room_project_public_id, source_revision_public_id
       FROM roomscan.publication_snapshot_rooms
      WHERE workspace_id = $1::uuid AND property_snapshot_id = $2::uuid
      ORDER BY room_order`,
    [ids.workspaceA, propertyFinalized.snapshot_id],
  )).rows, [
    {
      room_order: 1, room_key: 'room-001',
      room_project_public_id: source.projectPublicId,
      source_revision_public_id: source.revisionPublicId,
    },
    {
      room_order: 2, room_key: 'room-002',
      room_project_public_id: sourceA2.projectPublicId,
      source_revision_public_id: sourceA2.revisionPublicId,
    },
  ], 'property finalization must freeze the exact independently source-bound approved room order');
  const propertyLink = (await apiPool.query(
    `SELECT * FROM roomscan.publication_create_link_v1(
      'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text, $4::bytea,
      NULL::timestamptz, NULL::bytea, NULL::bytea, 'disabled'::text,
      'enabled'::text, $5::bytea
    )`,
    [
      propertyAccess, propertyAt, propertyFinalized.snapshot_public_id,
      digest('property-link-token'), digest('property-link-idempotency'),
    ],
  )).rows[0];
  const propertySessionHash = digest('property-session');
  assert.equal((await portalPool.query(
    `SELECT * FROM roomscan.portal_exchange_link_v1(
      $1::bytea, $2::timestamptz, $3::bytea, 'tablet'::text, $4::bytea
    )`,
    [digest('property-link-token'), propertyAt, propertySessionHash, digest('property-risk')],
  )).rows[0].status, 'active');
  assert.equal((await portalPool.query(
    'SELECT * FROM roomscan.portal_get_snapshot_v1($1::bytea, $2::timestamptz)',
    [propertySessionHash, propertyAt],
  )).rows[0].publication_kind, 'property');
  const propertyRooms = (await portalPool.query(
    'SELECT * FROM roomscan.portal_list_property_rooms_v1($1::bytea, $2::timestamptz)',
    [propertySessionHash, propertyAt],
  )).rows;
  assert.deepEqual(propertyRooms, [
    { room_key: 'room-001', room_order: 1 },
    { room_key: 'room-002', room_order: 2 },
  ], 'property navigation must expose only frozen ordered independent room keys, never private source/revision identity');
  const propertyMutationAt = new Date(propertyAt.getTime() + 60 * 1000);
  const changedDraft = await upsertPublicationProperty({
    access: propertyAccess, at: propertyMutationAt,
    propertyPublicID: property.property_public_id,
    expectedVersion: Number(property.curation_version),
    title: 'Independent room tour',
    rooms: [
      { publicRoomKey: 'room-002', projectPublicID: sourceA2.projectPublicId },
      { publicRoomKey: 'room-001', projectPublicID: source.projectPublicId },
    ],
  });
  assert.equal(changedDraft.status, 'updated', 'the draft curation must atomically replace/reorder the complete list for the next property publication');
  assert.deepEqual((await portalPool.query(
    'SELECT * FROM roomscan.portal_list_property_rooms_v1($1::bytea, $2::timestamptz)',
    [propertySessionHash, propertyMutationAt],
  )).rows, [
    { room_key: 'room-001', room_order: 1 },
    { room_key: 'room-002', room_order: 2 },
  ], 'a post-finalization draft mutation must not change an existing property snapshot');
  const propertyAllocationTwo = await allocatePublication({
    access: propertyAccess, at: propertyMutationAt,
    projectPublicID: sourceA2.projectPublicId, sourceRevisionPublicID: sourceA2.revisionPublicId,
    sourceDigest: sourceA2.sourceDigest, sourceManifestDigest: sourceA2.sourceManifestDigest,
    sourceBindings: [
      sourceBinding(sourceA2, 'room-002'),
      sourceBinding(source, 'room-001'),
    ],
    label: 'propertysnapshot0002', publicationKind: 'property',
    propertyPublicID: property.property_public_id, versions: propertyVersions,
  });
  const propertyClaimTwo = await completeAndClaimPublication({
    access: propertyAccess, at: propertyMutationAt, allocation: propertyAllocationTwo,
    label: 'propertysnapshot0002',
  });
  const propertyFinalizedTwo = await finalizePublication({
    claim: propertyClaimTwo, at: propertyMutationAt, label: 'propertysnapshot0002',
  });
  assert.equal(propertyFinalizedTwo.status, 'published');
  const propertyLinkTwo = (await apiPool.query(
    `SELECT * FROM roomscan.publication_create_link_v1(
      'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text, $4::bytea,
      NULL::timestamptz, NULL::bytea, NULL::bytea, 'disabled'::text,
      'enabled'::text, $5::bytea
    )`,
    [
      propertyAccess, propertyMutationAt, propertyFinalizedTwo.snapshot_public_id,
      digest('property-link-token-two'), digest('property-link-idempotency-two'),
    ],
  )).rows[0];
  const propertySessionHashTwo = digest('property-session-two');
  assert.equal((await portalPool.query(
    `SELECT * FROM roomscan.portal_exchange_link_v1(
      $1::bytea, $2::timestamptz, $3::bytea, 'tablet'::text, $4::bytea
    )`,
    [digest('property-link-token-two'), propertyMutationAt, propertySessionHashTwo, digest('property-risk-two')],
  )).rows[0].status, 'active');
  assert.deepEqual((await portalPool.query(
    'SELECT * FROM roomscan.portal_list_property_rooms_v1($1::bytea, $2::timestamptz)',
    [propertySessionHashTwo, propertyMutationAt],
  )).rows, [
    { room_key: 'room-002', room_order: 1 },
    { room_key: 'room-001', room_order: 2 },
  ], 'a newly finalized property snapshot must freeze the newly approved mutable draft order');
  await assert.rejects(
    () => bootstrapPool.query(
      `UPDATE roomscan.publication_snapshot_rooms SET room_order = 3
        WHERE workspace_id = $1::uuid AND property_snapshot_id = $2::uuid`,
      [ids.workspaceA, propertyFinalized.snapshot_id],
    ),
    (error) => error?.code === '55000' && error?.message === 'IMMUTABLE_PUBLICATION_RECORD',
    'the frozen property membership positive control must reach the immutable trigger',
  );

  const propertyRoomColumns = (await bootstrapPool.query(
    `SELECT column_name FROM information_schema.columns
      WHERE table_schema = 'roomscan' AND table_name = 'publication_property_rooms'
      ORDER BY ordinal_position`,
  )).rows.map(({ column_name: name }) => name);
  const forbiddenSpatialTerms = /transform|origin|coordinate|alignment|connectivity|adjacency|reconstruction/u;
  assert.deepEqual(
    propertyRoomColumns.filter((name) => forbiddenSpatialTerms.test(name)),
    [],
    'property composition must not persist a shared-coordinate or reconstruction claim',
  );
  assert.deepEqual(
    [...propertyRoomColumns, 'shared_coordinate_canary'].filter((name) => forbiddenSpatialTerms.test(name)),
    ['shared_coordinate_canary'],
    'the independent-room schema probe must detect an injected spatial canary',
  );
  await bootstrapPool.query(
    'ALTER TABLE roomscan.publication_snapshot_rooms DISABLE TRIGGER publication_snapshot_rooms_immutable',
  );
  try {
    await assert.rejects(
      () => bootstrapPool.query(
      `UPDATE roomscan.publication_snapshot_rooms
          SET source_revision_id = $1::uuid
        WHERE workspace_id = $2::uuid
          AND property_snapshot_id = $3::uuid
          AND room_order = 1`,
      [sourceA2.revisionId, ids.workspaceA, propertyFinalized.snapshot_id],
      ),
      (error) => error?.code === '23503',
      'the frozen property-room composite FK must reject a same-workspace revision/project provenance mismatch',
    );
  } finally {
    await bootstrapPool.query(
      'ALTER TABLE roomscan.publication_snapshot_rooms ENABLE TRIGGER publication_snapshot_rooms_immutable',
    );
  }
  const crossTenantAt = new Date(now.getTime() + 46 * 60 * 1000);
  await setFlag(
    'workspace', ids.workspaceB, 'hosted_operations_enabled',
    'ofaud_s6_hosted_workspace_b', true, crossTenantAt,
  );
  await setFlag(
    'workspace', ids.workspaceB, 'publication_enabled',
    'ofaud_s6_publication_workspace_b', true, crossTenantAt,
  );
  await activateQuota(ids.workspaceB, 'roomscan-period-v1:slice6-b');
  const sourceB = await seedCanonicalSourceB();
  const tenantBVersions = await currentFlagVersions(ids.workspaceB);
  const tenantBAccess = await seedFreshAccess({
    label: 'tenant-b-publication',
    at: crossTenantAt,
    workspaceId: ids.workspaceB,
    principalId: ids.principalB,
  });
  await assert.rejects(
    () => allocatePublication({
      access: tenantBAccess,
      at: crossTenantAt,
      projectPublicID: 'prj_slice6project0001',
      sourceRevisionPublicID: source.revisionPublicId,
      sourceDigest: digest('source-archive'),
      sourceManifestDigest: digest('source-manifest'),
      sourceBindings: [sourceBinding(source, 'room-001')],
      label: 'crossTenantAllocate',
      versions: tenantBVersions,
    }),
    (error) => error?.code === 'P0001' && error?.message === 'PUBLICATION_SOURCE_NOT_FOUND',
    'a tenant B publication allocation must not resolve tenant A private project truth',
  );
  const tenantBAllocation = await allocatePublication({
    access: tenantBAccess,
    at: crossTenantAt,
    projectPublicID: sourceB.projectPublicId,
    sourceRevisionPublicID: sourceB.revisionPublicId,
    sourceDigest: sourceB.sourceDigest,
    sourceManifestDigest: sourceB.sourceManifestDigest,
    sourceBindings: [sourceBinding(sourceB, 'room-001')],
    label: 'tenantbsnapshot0001',
    versions: tenantBVersions,
  });
  const tenantBClaim = await completeAndClaimPublication({
    access: tenantBAccess,
    at: crossTenantAt,
    allocation: tenantBAllocation,
    label: 'tenantbsnapshot0001',
  });
  const tenantBSnapshot = await finalizePublication({
    claim: tenantBClaim,
    at: crossTenantAt,
    label: 'tenantbsnapshot0001',
  });
  const tenantBLink = (await apiPool.query(
    `SELECT * FROM roomscan.publication_create_link_v1(
      'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text, $4::bytea,
      NULL::timestamptz, NULL::bytea, NULL::bytea, 'disabled'::text,
      'enabled'::text, $5::bytea
    )`,
    [
      tenantBAccess, crossTenantAt, tenantBSnapshot.snapshot_public_id,
      digest('tenant-b-link-token'), digest('tenant-b-link-idempotency'),
    ],
  )).rows[0];
  const tenantBSessionHash = digest('tenant-b-session');
  assert.equal((await portalPool.query(
    `SELECT * FROM roomscan.portal_exchange_link_v1(
      $1::bytea, $2::timestamptz, $3::bytea, 'desktop'::text, $4::bytea
    )`,
    [digest('tenant-b-link-token'), crossTenantAt, tenantBSessionHash, digest('tenant-b-risk')],
  )).rows[0].status, 'active');
  await assert.rejects(
    () => apiPool.query(
      `SELECT * FROM roomscan.publication_create_link_v1(
        'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text, $4::bytea,
        NULL::timestamptz, NULL::bytea, NULL::bytea, 'disabled'::text,
        'enabled'::text, $5::bytea
      )`,
      [
        tenantBAccess, crossTenantAt, finalized.snapshot_public_id,
        digest('tenant-b-to-a-token'), digest('tenant-b-to-a-idempotency'),
      ],
    ),
    (error) => error?.code === '42501' && error?.message === 'PUBLICATION_AUTHORIZATION_REQUIRED',
    'tenant B must not create a link for tenant A immutable snapshot',
  );
  const tenantAVersions = await currentFlagVersions(ids.workspaceA);
  await assert.rejects(
    () => apiPool.query(
      `SELECT * FROM roomscan.publication_create_link_v1(
        'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text, $4::bytea,
        NULL::timestamptz, NULL::bytea, NULL::bytea, 'disabled'::text,
        'enabled'::text, $5::bytea
      )`,
      [
        propertyAccess, crossTenantAt, tenantBSnapshot.snapshot_public_id,
        digest('tenant-a-to-b-token'), digest('tenant-a-to-b-idempotency'),
      ],
    ),
    (error) => error?.code === '42501' && error?.message === 'PUBLICATION_AUTHORIZATION_REQUIRED',
    'tenant A must not create a link for tenant B immutable snapshot',
  );
  const tenantBChallenge = await requestFeedbackVerification({
    sessionHash: tenantBSessionHash, at: crossTenantAt,
    challengeHash: digest('tenant-b-feedback-challenge'),
    verificationTokenHash: digest('tenant-b-feedback-token'),
    verifiedEmailDigest: digest('tenant-b-feedback-email'),
    requestDigest: digest('tenant-b-feedback-request'),
    envelopeLabel: 'tenant-b-feedback',
  });
  assert.equal(tenantBChallenge.status, 'issued');
  const tenantBLease = 'feedback-tenant-b-lease';
  const tenantBDelivery = (await emailPool.query(
    `SELECT * FROM roomscan.claim_next_feedback_delivery_v3($1::text, $2::timestamptz, $3::timestamptz)`,
    [tenantBLease, crossTenantAt, new Date(crossTenantAt.getTime() + 5 * 60 * 1000)],
  )).rows[0];
  assert.equal(tenantBDelivery.status, 'leased');
  assert.equal((await emailPool.query(
    `SELECT roomscan.complete_feedback_delivery_v3($1::text, $2::text, $3::timestamptz) AS completed`,
    [tenantBDelivery.delivery_id, tenantBLease, new Date(crossTenantAt.getTime() + 1_000)],
  )).rows[0].completed, true);
  assert.equal((await portalPool.query(
    `SELECT * FROM roomscan.portal_consume_feedback_verification_v1(
      $1::bytea, $2::bytea, $3::timestamptz, $4::bytea
    )`,
    [
      tenantBSessionHash, digest('tenant-b-feedback-challenge'), crossTenantAt,
      digest('tenant-b-feedback-token'),
    ],
  )).rows[0].status, 'verified');
  await assert.rejects(
    () => portalPool.query(
      `SELECT * FROM roomscan.portal_create_feedback_v1(
        $1::bytea, $2::timestamptz, $3::bytea, 'approve'::text, NULL::text, $4::bytea
      )`,
      [
        propertySessionHash, crossTenantAt, digest('tenant-b-feedback-token'),
        digest('tenant-b-feedback-cross-tenant-request'),
      ],
    ),
    (error) => error?.code === '42501' && error?.message === 'FEEDBACK_VERIFICATION_REQUIRED',
    'tenant B feedback verification cannot cross into tenant A portal truth',
  );
  assert.ok(tenantBLink.link_public_id, 'tenant B positive control must create a same-tenant portal link');

  // The professional web shell only holds a hashed, distinct cookie after its
  // app bearer is discarded.  These reducer calls are intentionally written
  // before the read family exists: the first focused run must prove the
  // database lacks a raw-table-free capability for the fixed Slice 6 reads.
  const professionalReadAt = new Date(now.getTime() + 48 * 60 * 1000);
  const professionalReadAccess = await seedFreshAccess({
    label: 'professional-read-family', at: professionalReadAt,
  });
  const professionalReadSessionHash = digest('professional-read-family-cookie');
  assert.equal((await apiPool.query(
    `SELECT * FROM roomscan.professional_session_issue_v1(
      $1::bytea, $2::timestamptz, $3::bytea, $4::uuid
    )`,
    [professionalReadAccess, professionalReadAt, professionalReadSessionHash, ids.workspaceA],
  )).rows[0].status, 'issued');
  await bootstrapPool.query(
    `UPDATE roomscan.auth_access_tokens
        SET state = 'revoked', revoked_at = $2::timestamptz
      WHERE token_hash = $1::bytea`,
    [professionalReadAccess, professionalReadAt],
  );
  const professionalProperties = (await apiPool.query(
    `SELECT * FROM roomscan.professional_list_properties_v1(
      'web_session'::text, $1::bytea, $2::timestamptz, 20::integer, NULL::text
    )`,
    [professionalReadSessionHash, professionalReadAt],
  )).rows;
  assert.ok(professionalProperties.some((row) => row.property_public_id === property.property_public_id),
    'a same-tenant professional cookie must list bounded property curation after its original bearer is discarded');
  assert.ok(professionalProperties.every((row) => !Object.hasOwn(row, 'property_id') && !Object.hasOwn(row, 'room_project_id')),
    'professional property lists must return opaque public IDs and counts, never private project or property identifiers');
  const listedProperty = professionalProperties.find((row) => row.property_public_id === property.property_public_id);
  assert.deepEqual(listedProperty.room_curation, [
    { roomKey: 'room-002', roomOrder: 1, projectID: sourceA2.projectPublicId },
    { roomKey: 'room-001', roomOrder: 2, projectID: source.projectPublicId },
  ], 'professional properties list must round-trip bounded ordered curation for add/reorder/remove without a broad table query');
  assert.equal(/transform|origin|coordinate|alignment|connectivity|adjacency|reconstruction/u.test(
    JSON.stringify(listedProperty.room_curation),
  ), false, 'professional property curation rows must never claim cross-room spatial relationships');
  const professionalConceptAccess = await seedFreshAccess({
    label: 'professional-concept-list', at: professionalReadAt,
  });
  const professionalConceptAllocation = await allocatePublication({
    access: professionalConceptAccess, at: professionalReadAt,
    projectPublicID: source.projectPublicId,
    sourceRevisionPublicID: source.revisionPublicId,
    sourceDigest: source.sourceDigest,
    sourceManifestDigest: source.sourceManifestDigest,
    sourceBindings: [sourceBinding(source, 'room-001')],
    label: 'professionalconceptread', versions: await currentFlagVersions(),
  });
  const professionalConceptClaim = await completeAndClaimPublication({
    access: professionalConceptAccess, at: professionalReadAt,
    allocation: professionalConceptAllocation, label: 'professionalconceptread',
  });
  const professionalConceptSnapshot = await finalizePublication({
    claim: professionalConceptClaim, at: professionalReadAt,
    label: 'professionalconceptread',
    assets: [
      ...publicationAssetManifest('professionalconceptread'),
      {
        asset_id: 'ast_professionalconceptread0001', kind: 'approved_concept',
        object_key: 'server/published/active/v1/snap_professionalconceptread/ast_professionalconceptread0001.bin',
        object_version: 'professional-concept-version', content_type: 'image/jpeg',
        digest_hex: digest('professional-concept-raster').toString('hex'), bytes: 512,
        download_kind: null,
      },
      {
        asset_id: 'ast_professionalpdfread000001', kind: 'floor_plan_pdf',
        object_key: 'server/published/active/v1/snap_professionalconceptread/ast_professionalpdfread000001.bin',
        object_version: 'professional-pdf-version', content_type: 'application/pdf',
        digest_hex: digest('professional-fallback-pdf').toString('hex'), bytes: 768,
        download_kind: 'floor_plan_pdf',
      },
    ],
  });
  const professionalConcepts = (await apiPool.query(
    `SELECT * FROM roomscan.professional_list_concepts_v1(
      'web_session'::text, $1::bytea, $2::timestamptz, $3::text, 20::integer, NULL::text
    )`,
    [professionalReadSessionHash, professionalReadAt, source.projectPublicId],
  )).rows;
  assert.ok(professionalConcepts.some((row) => (
    row.snapshot_public_id === professionalConceptSnapshot.snapshot_public_id
      && row.concept_asset_public_id === 'ast_professionalconceptread0001'
  )), 'concept reads must surface only a same-tenant published approved derivative positive control');
  assert.ok(professionalConcepts.every((row) => !Object.hasOwn(row, 'object_key') && !Object.hasOwn(row, 'working_digest')),
    'concept reads must not leak private working archives or storage locations');
  const professionalMembers = (await apiPool.query(
    `SELECT * FROM roomscan.professional_list_members_v1(
      'web_session'::text, $1::bytea, $2::timestamptz, 100::integer, NULL::text
    )`,
    [professionalReadSessionHash, professionalReadAt],
  )).rows;
  assert.ok(professionalMembers.some((row) => row.role === 'owner'),
    'the professional role view must be session-bound and include a same-tenant owner control');
  assert.ok(professionalMembers.every((row) => !Object.hasOwn(row, 'normalized_email')),
    'member/role reads must not expose private email fields');
  const allocationStatus = (await apiPool.query(
    `SELECT * FROM roomscan.publication_allocation_status_v1(
      'web_session'::text, $1::bytea, $2::timestamptz, $3::text
    )`,
    [professionalReadSessionHash, professionalReadAt, webSessionAllocation.allocation_public_id],
  )).rows[0];
  assert.equal(allocationStatus.allocation_public_id, webSessionAllocation.allocation_public_id,
    'allocation status must use the opaque pua_ identifier rather than a snapshot or private UUID');
  const nativeAllocationStatus = (await apiPool.query(
    `SELECT * FROM roomscan.publication_allocation_status_v1(
      'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text
    )`,
    [accessHash, professionalReadAt, webSessionAllocation.allocation_public_id],
  )).rows[0];
  assert.equal(nativeAllocationStatus.allocation_public_id, webSessionAllocation.allocation_public_id,
    'native recovery must poll the same opaque pua_ allocation status with an app bearer after a web session is unavailable');
  const allocations = (await apiPool.query(
    `SELECT * FROM roomscan.publication_list_allocations_v1(
      'web_session'::text, $1::bytea, $2::timestamptz, 100::integer, NULL::text
    )`,
    [professionalReadSessionHash, professionalReadAt],
  )).rows;
  assert.ok(allocations.some((row) => row.allocation_public_id === webSessionAllocation.allocation_public_id),
    'publication record readers must list same-tenant allocation status without direct table grants');
  const professionalLinks = (await apiPool.query(
    `SELECT * FROM roomscan.publication_list_links_v1(
      'web_session'::text, $1::bytea, $2::timestamptz, $3::text, 100::integer, NULL::text
    )`,
    [professionalReadSessionHash, professionalReadAt, finalized.snapshot_public_id],
  )).rows;
  assert.ok(professionalLinks.some((row) => row.link_public_id === link.link_public_id),
    'publication record readers must list bounded portal link status without token hashes');
  assert.ok(professionalLinks.every((row) => !Object.hasOwn(row, 'token_hash') && !Object.hasOwn(row, 'pin_verifier')),
    'professional link lists must not disclose bearer/PIN verifier material');
  const professionalLinkAggregates = (await apiPool.query(
    `SELECT * FROM roomscan.publication_list_links_v2(
      'web_session'::text, $1::bytea, $2::timestamptz, $3::text, 100::integer, NULL::text
    )`,
    [professionalReadSessionHash, professionalReadAt, finalized.snapshot_public_id],
  )).rows;
  const mainLinkAggregate = professionalLinkAggregates.find(
    (row) => row.link_public_id === link.link_public_id,
  );
  assert.deepEqual(
    {
      feedback_count: Number(mainLinkAggregate.feedback_count),
      feedback_count_capped: mainLinkAggregate.feedback_count_capped,
      latest_feedback_kind: mainLinkAggregate.latest_feedback_kind,
      latest_feedback_at_present: mainLinkAggregate.latest_feedback_at !== null,
    },
    {
      feedback_count: 1,
      feedback_count_capped: false,
      latest_feedback_kind: 'comment',
      latest_feedback_at_present: true,
    },
    'the additive link aggregate must expose one bounded immutable feedback status positive control',
  );
  assert.ok(professionalLinkAggregates.every((row) => (
    Number(row.feedback_count) >= 0 && Number(row.feedback_count) <= 10000
      && !Object.hasOwn(row, 'comment') && !Object.hasOwn(row, 'verified_email_digest')
      && !Object.hasOwn(row, 'request_digest')
  )), 'link feedback aggregates must be bounded and omit comment, email, and request identity material');
  const professionalAssetRequestDigest = digest('professional-asset-request');
  const professionalAssetAuthorization = (await portalPool.query(
    `SELECT * FROM roomscan.portal_authorize_professional_asset_v1(
      $1::bytea, $2::timestamptz, 'ast_slice6floorplan0001'::text,
      $3::bytea, 0::bigint, 64::bigint
    )`,
    [professionalReadSessionHash, professionalReadAt, professionalAssetRequestDigest],
  )).rows[0];
  assert.deepEqual(
    {
      status: professionalAssetAuthorization.status,
      asset_public_id: professionalAssetAuthorization.asset_public_id,
      byte_offset: professionalAssetAuthorization.byte_offset,
      byte_length: professionalAssetAuthorization.byte_length,
      delivered_bytes: professionalAssetAuthorization.delivered_bytes,
      already_accounted: professionalAssetAuthorization.already_accounted,
    },
    {
      status: 'allowed', asset_public_id: 'ast_slice6floorplan0001',
      byte_offset: '0', byte_length: '64', delivered_bytes: '0', already_accounted: false,
    },
    'a live same-tenant professional cookie must reserve one bounded published asset range without a public portal link',
  );
  const professionalAssetFinalized = await finalizeProfessionalAsset({
    sessionHash: professionalReadSessionHash, at: professionalReadAt,
    authorization: professionalAssetAuthorization,
    requestDigest: professionalAssetRequestDigest,
  });
  assert.equal(professionalAssetFinalized.delivered_bytes, '64',
    'professional asset finalization must account only after one exact active-version read');
  const professionalAssetReplay = (await portalPool.query(
    `SELECT * FROM roomscan.portal_authorize_professional_asset_v1(
      $1::bytea, $2::timestamptz, 'ast_slice6floorplan0001'::text,
      $3::bytea, 0::bigint, 64::bigint
    )`,
    [professionalReadSessionHash, professionalReadAt, professionalAssetRequestDigest],
  )).rows[0];
  assert.deepEqual(
    {
      delivered_bytes: professionalAssetReplay.delivered_bytes,
      already_accounted: professionalAssetReplay.already_accounted,
      object_version: professionalAssetReplay.object_version,
    },
    {
      delivered_bytes: '64', already_accounted: true,
      object_version: professionalAssetAuthorization.object_version,
    },
    'a professional asset replay must bind the same session, range, and exact version without double charging',
  );

  // A professional asset reservation is not a grant to emit bytes: the
  // distinct cookie must be live again at finalization.  Use a fresh cookie so
  // this control cannot accidentally rely on the public-link session above.
  const professionalRevokeAt = new Date(professionalReadAt.getTime() + 1_000);
  const professionalRevokeAccess = await seedFreshAccess({
    label: 'professional-asset-revoke-between-phases', at: professionalRevokeAt,
  });
  const professionalRevokeSessionHash = digest('professional-asset-revoke-between-phases-cookie');
  assert.equal((await apiPool.query(
    `SELECT * FROM roomscan.professional_session_issue_v1(
      $1::bytea, $2::timestamptz, $3::bytea, $4::uuid
    )`,
    [
      professionalRevokeAccess, professionalRevokeAt,
      professionalRevokeSessionHash, ids.workspaceA,
    ],
  )).rows[0].status, 'issued',
  'a fresh professional-cookie positive control must be issued before its app bearer is discarded');
  await bootstrapPool.query(
    `UPDATE roomscan.auth_access_tokens
        SET state = 'revoked', revoked_at = $2::timestamptz
      WHERE token_hash = $1::bytea`,
    [professionalRevokeAccess, professionalRevokeAt],
  );
  const professionalRevokeDigest = digest('professional-asset-revoke-between-phases-request');
  const professionalRevokeAuthorization = (await portalPool.query(
    `SELECT * FROM roomscan.portal_authorize_professional_asset_v1(
      $1::bytea, $2::timestamptz, 'ast_slice6floorplan0001'::text,
      $3::bytea, 0::bigint, 64::bigint
    )`,
    [professionalRevokeSessionHash, professionalRevokeAt, professionalRevokeDigest],
  )).rows[0];
  const professionalRevokeUsageBefore = (await bootstrapPool.query(
    `SELECT used::text AS used
       FROM roomscan.quota_usage_v2
      WHERE workspace_id = $1::uuid
        AND metric = 'portal_bytes'
        AND period_key = 'roomscan-period-v1:slice6'`,
    [ids.workspaceA],
  )).rows[0];
  assert.equal((await apiPool.query(
    'SELECT roomscan.professional_session_revoke_v1($1::bytea, $2::timestamptz) AS revoked',
    [professionalRevokeSessionHash, new Date(professionalRevokeAt.getTime() + 1)],
  )).rows[0].revoked, true,
  'the professional-session revocation control must commit after reservation and before finalization');
  await assert.rejects(
    () => finalizeProfessionalAsset({
      sessionHash: professionalRevokeSessionHash,
      at: new Date(professionalRevokeAt.getTime() + 2),
      authorization: professionalRevokeAuthorization,
      requestDigest: professionalRevokeDigest,
    }),
    (error) => error?.code === '42501' && error?.message === 'PROFESSIONAL_PORTAL_ACCESS_DENIED',
    'a professional-session revoke between asset authorization and finalization must deny emission',
  );
  assert.equal(Number((await bootstrapPool.query(
    `SELECT count(*)::integer AS count
       FROM roomscan.professional_asset_delivery_receipts
      WHERE workspace_id = $1::uuid AND request_digest = $2::bytea`,
    [ids.workspaceA, professionalRevokeDigest],
  )).rows[0].count), 0,
  'a revoked professional finalization must leave no durable delivery receipt');
  assert.equal((await bootstrapPool.query(
    `SELECT used::text AS used
       FROM roomscan.quota_usage_v2
      WHERE workspace_id = $1::uuid
        AND metric = 'portal_bytes'
        AND period_key = 'roomscan-period-v1:slice6'`,
    [ids.workspaceA],
  )).rows[0].used, professionalRevokeUsageBefore.used,
  'a revoked professional finalization must leave portal-byte quota uncharged');

  const professionalRangeDigest = digest('professional-asset-exact-range-request');
  const professionalRangeAuthorization = (await portalPool.query(
    `SELECT * FROM roomscan.portal_authorize_professional_asset_v1(
      $1::bytea, $2::timestamptz, 'ast_slice6floorplan0001'::text,
      $3::bytea, 0::bigint, 64::bigint
    )`,
    [professionalReadSessionHash, professionalReadAt, professionalRangeDigest],
  )).rows[0];
  await assert.rejects(
    () => portalPool.query(
      `SELECT * FROM roomscan.portal_authorize_professional_asset_v1(
        $1::bytea, $2::timestamptz, 'ast_slice6floorplan0001'::text,
        $3::bytea, 64::bigint, 64::bigint
      )`,
      [professionalReadSessionHash, professionalReadAt, professionalRangeDigest],
    ),
    (error) => error?.code === 'P0001' && error?.message === 'PROFESSIONAL_DELIVERY_IDEMPOTENCY_REUSED',
    'a professional reservation digest must bind its exact requested range rather than permit a shifted replay',
  );
  const professionalRangeUsageBefore = (await bootstrapPool.query(
    `SELECT used::text AS used
       FROM roomscan.quota_usage_v2
      WHERE workspace_id = $1::uuid
        AND metric = 'portal_bytes'
        AND period_key = 'roomscan-period-v1:slice6'`,
    [ids.workspaceA],
  )).rows[0];
  await assert.rejects(
    () => portalPool.query(
      `SELECT * FROM roomscan.portal_finalize_professional_asset_delivery_v1(
        $1::bytea, $2::timestamptz, $3::text, $4::bytea, $5::bigint,
        $6::bigint, $7::text
      )`,
      [
        professionalReadSessionHash, professionalReadAt,
        professionalRangeAuthorization.asset_public_id, professionalRangeDigest,
        professionalRangeAuthorization.byte_offset, professionalRangeAuthorization.byte_length,
        `${professionalRangeAuthorization.object_version}-wrong`,
      ],
    ),
    (error) => error?.code === 'P0001' && error?.message === 'PROFESSIONAL_PUBLICATION_ASSET_NOT_FOUND',
    'professional finalization must require the active storage version that was reserved',
  );
  assert.equal(Number((await bootstrapPool.query(
    `SELECT count(*)::integer AS count
       FROM roomscan.professional_asset_delivery_receipts
      WHERE workspace_id = $1::uuid AND request_digest = $2::bytea`,
    [ids.workspaceA, professionalRangeDigest],
  )).rows[0].count), 0,
  'a wrong object version must leave no professional delivery receipt');
  assert.equal((await bootstrapPool.query(
    `SELECT used::text AS used
       FROM roomscan.quota_usage_v2
      WHERE workspace_id = $1::uuid
        AND metric = 'portal_bytes'
        AND period_key = 'roomscan-period-v1:slice6'`,
    [ids.workspaceA],
  )).rows[0].used, professionalRangeUsageBefore.used,
  'a wrong object version must fail before portal-byte quota is charged');

  const professionalQuotaDigest = digest('professional-asset-quota-request');
  const professionalQuotaAuthorization = (await portalPool.query(
    `SELECT * FROM roomscan.portal_authorize_professional_asset_v1(
      $1::bytea, $2::timestamptz, 'ast_slice6floorplan0001'::text,
      $3::bytea, 128::bigint, 64::bigint
    )`,
    [professionalReadSessionHash, professionalReadAt, professionalQuotaDigest],
  )).rows[0];
  const professionalQuotaBefore = (await bootstrapPool.query(
    `SELECT used::text AS used, reserved::text AS reserved, limit_value::text AS limit_value
       FROM roomscan.quota_usage_v2
      WHERE workspace_id = $1::uuid
        AND metric = 'portal_bytes'
        AND period_key = 'roomscan-period-v1:slice6'
      FOR UPDATE`,
    [ids.workspaceA],
  )).rows[0];
  await bootstrapPool.query(
    `UPDATE roomscan.quota_usage_v2
        SET limit_value = used + reserved + 63
      WHERE workspace_id = $1::uuid
        AND metric = 'portal_bytes'
        AND period_key = 'roomscan-period-v1:slice6'`,
    [ids.workspaceA],
  );
  try {
    await assert.rejects(
      () => finalizeProfessionalAsset({
        sessionHash: professionalReadSessionHash, at: professionalReadAt,
        authorization: professionalQuotaAuthorization,
        requestDigest: professionalQuotaDigest,
      }),
      (error) => error?.code === '42900' && error?.message === 'PORTAL_QUOTA_EXCEEDED',
      'professional asset finalization must deny a range that exceeds the live portal-byte quota',
    );
    assert.equal(Number((await bootstrapPool.query(
      `SELECT count(*)::integer AS count
         FROM roomscan.professional_asset_delivery_receipts
        WHERE workspace_id = $1::uuid AND request_digest = $2::bytea`,
      [ids.workspaceA, professionalQuotaDigest],
    )).rows[0].count), 0,
    'a quota-denied professional finalization must leave no durable receipt');
    assert.equal((await bootstrapPool.query(
      `SELECT used::text AS used
         FROM roomscan.quota_usage_v2
        WHERE workspace_id = $1::uuid
          AND metric = 'portal_bytes'
          AND period_key = 'roomscan-period-v1:slice6'`,
      [ids.workspaceA],
    )).rows[0].used, professionalQuotaBefore.used,
    'a quota-denied professional finalization must leave portal-byte usage unchanged');
  } finally {
    await bootstrapPool.query(
      `UPDATE roomscan.quota_usage_v2
          SET limit_value = $2::bigint
        WHERE workspace_id = $1::uuid
          AND metric = 'portal_bytes'
          AND period_key = 'roomscan-period-v1:slice6'`,
      [ids.workspaceA, professionalQuotaBefore.limit_value],
    );
  }
  await assert.rejects(
    () => portalPool.query(
      `SELECT * FROM roomscan.portal_authorize_professional_asset_v1(
        $1::bytea, $2::timestamptz, 'ast_slice6floorplan0001'::text,
        $3::bytea, 0::bigint, 64::bigint
      )`,
      [portalSessionHash, professionalReadAt, digest('portal-cookie-professional-confusion')],
    ),
    (error) => error?.code === '42501' && error?.message === 'PROFESSIONAL_PORTAL_ACCESS_DENIED',
    'a public portal session hash must not be structurally substitutable for a professional publication asset cookie',
  );
  await assert.rejects(
    () => portalPool.query(
      `SELECT * FROM roomscan.portal_authorize_professional_asset_v1(
        $1::bytea, $2::timestamptz, 'ast_slice6floorplan0001'::text,
        $3::bytea, 0::bigint, 64::bigint
      )`,
      [accessHash, professionalReadAt, digest('app-bearer-professional-confusion')],
    ),
    (error) => error?.code === '42501' && error?.message === 'PROFESSIONAL_PORTAL_ACCESS_DENIED',
    'an app bearer hash must not be structurally substitutable for a professional publication asset cookie',
  );
  const professionalFeedback = (await apiPool.query(
    `SELECT * FROM roomscan.publication_list_feedback_v1(
      'web_session'::text, $1::bytea, $2::timestamptz, NULL::text, $3::text, 20::integer, NULL::text
    )`,
    [professionalReadSessionHash, professionalReadAt, finalized.snapshot_public_id],
  )).rows;
  assert.ok(professionalFeedback.length > 0,
    'publication record readers must expose immutable same-tenant feedback summaries');
  assert.ok(professionalFeedback.every((row) => !Object.hasOwn(row, 'verified_email_digest')),
    'feedback lists must never expose verification email digests');
  await assert.rejects(
    () => apiPool.query(
      `SELECT * FROM roomscan.publication_list_feedback_v1(
        'web_session'::text, $1::bytea, $2::timestamptz, NULL::text, NULL::text, 21::integer, NULL::text
      )`,
      [professionalReadSessionHash, professionalReadAt],
    ),
    (error) => error?.code === '22023' && error?.message === 'INVALID_PROFESSIONAL_READ_PAGE',
    'feedback list must cap a comment-bearing page at twenty records before it can exceed the browser response budget',
  );
  await assert.rejects(
    () => apiPool.query(
      `SELECT * FROM roomscan.professional_list_concepts_v1(
        'web_session'::text, $1::bytea, $2::timestamptz, $3::text, 21::integer, NULL::text
      )`,
      [professionalReadSessionHash, professionalReadAt, source.projectPublicId],
    ),
    (error) => error?.code === '22023' && error?.message === 'INVALID_PROFESSIONAL_READ_PAGE',
    'concept list must cap its rendered derivative page at twenty records',
  );
  const professionalHistory = (await apiPool.query(
    `SELECT * FROM roomscan.publication_list_access_history_v1(
      'web_session'::text, $1::bytea, $2::timestamptz, $3::text, 100::integer, NULL::text
    )`,
    [professionalReadSessionHash, professionalReadAt, link.link_public_id],
  )).rows;
  assert.ok(professionalHistory.length > 0,
    'owner/admin access-history reads must receive privacy-minimized same-tenant events');
  assert.ok(professionalHistory.every((row) => !Object.hasOwn(row, 'network_risk_digest') && !Object.hasOwn(row, 'session_id')),
    'access history must omit session identifiers and risk digests');
  const professionalDownloads = (await apiPool.query(
    `SELECT * FROM roomscan.publication_list_downloads_v1(
      'web_session'::text, $1::bytea, $2::timestamptz, $3::text, 100::integer, NULL::text
    )`,
    [professionalReadSessionHash, professionalReadAt, professionalConceptSnapshot.snapshot_public_id],
  )).rows;
  assert.deepEqual(professionalDownloads.map((row) => row.download_kind), ['floor_plan_pdf'],
    'the bounded fallback download status reducer must return only published enabled static fallback metadata');
  assert.ok(professionalDownloads.every((row) => !Object.hasOwn(row, 'object_key') && !Object.hasOwn(row, 'object_version')),
    'download list rows must not become a storage read/presign capability');
  const professionalBootstrap = (await apiPool.query(
    `SELECT * FROM roomscan.professional_session_bootstrap_v1(
      'web_session'::text, $1::bytea, $2::timestamptz
    )`,
    [professionalReadSessionHash, professionalReadAt],
  )).rows[0];
  assert.equal(professionalBootstrap.plan_key, 'starter',
    'owner/admin professional bootstrap must surface the existing read-only subscription view');
  assert.ok(!Object.hasOwn(professionalBootstrap, 'workspace_id') && !Object.hasOwn(professionalBootstrap, 'billing_provider_id'),
    'professional billing bootstrap must remain privacy-bounded and provider-free');
  const presentationLookup = (await portalPool.query(
    'SELECT * FROM roomscan.portal_lookup_presentation_asset_v1($1::bytea, $2::timestamptz)',
    [propertySessionHashTwo, professionalReadAt],
  )).rows[0];
  assert.match(presentationLookup.asset_public_id, /^ast_/u,
    'an active portal session must resolve one authoritative presentation asset before exact-range authorization');
  assert.ok(!Object.hasOwn(presentationLookup, 'object_key') && !Object.hasOwn(presentationLookup, 'object_version'),
    'presentation lookup must not grant a storage key, version, or signed URL capability');
  await assert.rejects(
    () => apiPool.query(
      `SELECT * FROM roomscan.professional_list_properties_v1(
        'web_session'::text, $1::bytea, $2::timestamptz, 20::integer, NULL::text
      )`,
      [tenantBSessionHash, professionalReadAt],
    ),
    (error) => error?.code === '42501',
    'a portal session hash must not be structurally substitutable for a professional cookie read capability',
  );
  const editorReadAt = new Date(professionalReadAt.getTime() + 1000);
  const editorReadAccess = await seedFreshAccess({
    label: 'editor-access-history-denial', at: editorReadAt,
    principalId: ids.principalMember, role: 'editor',
  });
  const editorReadSessionHash = digest('editor-access-history-cookie');
  assert.equal((await apiPool.query(
    `SELECT * FROM roomscan.professional_session_issue_v1(
      $1::bytea, $2::timestamptz, $3::bytea, $4::uuid
    )`,
    [editorReadAccess, editorReadAt, editorReadSessionHash, ids.workspaceA],
  )).rows[0].status, 'issued');
  await assert.rejects(
    () => apiPool.query(
      `SELECT * FROM roomscan.publication_list_access_history_v1(
        'web_session'::text, $1::bytea, $2::timestamptz, NULL::text, 100::integer, NULL::text
      )`,
      [editorReadSessionHash, editorReadAt],
    ),
    (error) => error?.code === '42501' && error?.message === 'PROFESSIONAL_ACTION_DENIED',
    'the exact access_history.read role cell must deny an editor even with a valid professional cookie',
  );
  const tenantBProfessionalAccess = await seedFreshAccess({
    label: 'tenant-b-professional-read', at: editorReadAt,
    workspaceId: ids.workspaceB, principalId: ids.principalB,
  });
  const tenantBProfessionalSessionHash = digest('tenant-b-professional-read-cookie');
  assert.equal((await apiPool.query(
    `SELECT * FROM roomscan.professional_session_issue_v1(
      $1::bytea, $2::timestamptz, $3::bytea, $4::uuid
    )`,
    [tenantBProfessionalAccess, editorReadAt, tenantBProfessionalSessionHash, ids.workspaceB],
  )).rows[0].status, 'issued');
  assert.deepEqual((await apiPool.query(
    `SELECT * FROM roomscan.publication_allocation_status_v1(
      'web_session'::text, $1::bytea, $2::timestamptz, $3::text
    )`,
    [tenantBProfessionalSessionHash, editorReadAt, webSessionAllocation.allocation_public_id],
  )).rows, [], 'a tenant B professional cookie must be denied tenant A opaque allocation substitution');
  assert.deepEqual((await apiPool.query(
    `SELECT * FROM roomscan.professional_list_properties_v1(
      'web_session'::text, $1::bytea, $2::timestamptz, 20::integer, NULL::text
    )`,
    [tenantBProfessionalSessionHash, editorReadAt],
  )).rows, [], 'a tenant B professional property list must not reveal tenant A curation');

  // Room inventory is deliberately separate from a property page: the web
  // shell needs one bounded, opaque-ID list of current synced sources before
  // it composes a property draft.  A long project title proves the reducer,
  // rather than an incidental client truncation, keeps its browser contract.
  const roomCandidateLongTitle = 'Room candidate title '.repeat(10);
  await bootstrapPool.query(
    `UPDATE roomscan.projects
        SET title = $1::text
      WHERE workspace_id = $2::uuid AND id = $3::uuid`,
    [roomCandidateLongTitle, ids.workspaceA, sourceA2.projectID],
  );
  const roomCandidates = (await apiPool.query(
    `SELECT * FROM roomscan.publication_list_room_candidates_v1(
      'web_session'::text, $1::bytea, $2::timestamptz, 100::integer, NULL::text
    )`,
    [professionalReadSessionHash, editorReadAt],
  )).rows;
  assert.deepEqual(roomCandidates.map((row) => row.project_public_id), [
    source.projectPublicId,
    sourceA2.projectPublicId,
  ], 'a same-tenant professional cookie must list its two current canonical room sources in opaque-ID order');
  assert.deepEqual(Object.keys(roomCandidates[0]).sort(), ['project_public_id', 'title'],
    'room candidates must expose only a public project ID and browser-bounded title');
  assert.equal(roomCandidates[1].title, roomCandidateLongTitle.slice(0, 180),
    'room candidate projection must truncate a source title to the OpenAPI 180-character maximum');
  assert.ok(roomCandidates.every((row) => row.title.length >= 1 && row.title.length <= 180),
    'room candidate titles must remain nonempty and browser-bounded');
  const firstRoomCandidatePage = (await apiPool.query(
    `SELECT * FROM roomscan.publication_list_room_candidates_v1(
      'web_session'::text, $1::bytea, $2::timestamptz, 1::integer, NULL::text
    )`,
    [professionalReadSessionHash, editorReadAt],
  )).rows;
  const secondRoomCandidatePage = (await apiPool.query(
    `SELECT * FROM roomscan.publication_list_room_candidates_v1(
      'web_session'::text, $1::bytea, $2::timestamptz, 1::integer, $3::text
    )`,
    [professionalReadSessionHash, editorReadAt, firstRoomCandidatePage[0].project_public_id],
  )).rows;
  assert.deepEqual(firstRoomCandidatePage.map((row) => row.project_public_id), [source.projectPublicId],
    'room candidates must start an opaque-ID page at the lowest eligible project ID');
  assert.deepEqual(secondRoomCandidatePage.map((row) => row.project_public_id), [sourceA2.projectPublicId],
    'room candidates must resume strictly after the opaque project-ID cursor');
  await assert.rejects(
    () => apiPool.query(
      `SELECT * FROM roomscan.publication_list_room_candidates_v1(
        'web_session'::text, $1::bytea, $2::timestamptz, 101::integer, NULL::text
      )`,
      [professionalReadSessionHash, editorReadAt],
    ),
    (error) => error?.code === '22023' && error?.message === 'INVALID_PROFESSIONAL_READ_PAGE',
    'room candidates must cap an explicit browser inventory page at one hundred sources',
  );
  const tenantBRoomCandidates = (await apiPool.query(
    `SELECT * FROM roomscan.publication_list_room_candidates_v1(
      'web_session'::text, $1::bytea, $2::timestamptz, 100::integer, NULL::text
    )`,
    [tenantBProfessionalSessionHash, editorReadAt],
  )).rows;
  assert.deepEqual(tenantBRoomCandidates.map((row) => row.project_public_id), [sourceB.projectPublicId],
    'a tenant B professional cookie must receive only its own canonical room source, never tenant A inventory');
  await assert.rejects(
    () => portalPool.query(
      `SELECT * FROM roomscan.publication_list_room_candidates_v1(
        'web_session'::text, $1::bytea, $2::timestamptz, 100::integer, NULL::text
      )`,
      [professionalReadSessionHash, editorReadAt],
    ),
    (error) => error?.code === '42501',
    'the portal runtime must not invoke the API-only professional room inventory reducer',
  );
  await assert.rejects(
    () => workerPool.query(
      `SELECT * FROM roomscan.publication_list_room_candidates_v1(
        'web_session'::text, $1::bytea, $2::timestamptz, 100::integer, NULL::text
      )`,
      [professionalReadSessionHash, editorReadAt],
    ),
    (error) => error?.code === '42501',
    'the publication worker must not invoke the API-only professional room inventory reducer',
  );
  await assert.rejects(
    () => portalPool.query(
      `SELECT * FROM roomscan.portal_authorize_professional_asset_v1(
        $1::bytea, $2::timestamptz, 'ast_slice6floorplan0001'::text,
        $3::bytea, 0::bigint, 64::bigint
      )`,
      [tenantBProfessionalSessionHash, editorReadAt, digest('tenant-b-professional-asset-a')],
    ),
    (error) => error?.code === 'P0001' && error?.message === 'PROFESSIONAL_PUBLICATION_ASSET_NOT_FOUND',
    'a live tenant B professional cookie must still be denied tenant A published asset substitution',
  );

  // The normal reducer never permits this write: the test cluster deliberately
  // bypasses immutable triggers only to prove the worker detects persistent
  // corruption before a snapshot becomes public.  This is a positive control
  // for the source/selection/approval closure at finalization time.
  const bindingAt = new Date(now.getTime() + 50 * 60 * 1000);
  const bindingVersions = await currentFlagVersions();
  const bindingAccess = await seedFreshAccess({ label: 'approval-binding-corruption', at: bindingAt });
  const bindingAllocation = await allocatePublication({
    access: bindingAccess,
    at: bindingAt,
    projectPublicID: source.projectPublicId,
    sourceRevisionPublicID: source.revisionPublicId,
    sourceDigest: source.sourceDigest,
    sourceManifestDigest: source.sourceManifestDigest,
    sourceBindings: [sourceBinding(source, 'room-001')],
    label: 'approvalbinding0001',
    versions: bindingVersions,
  });
  const bindingClaim = await completeAndClaimPublication({
    access: bindingAccess,
    at: bindingAt,
    allocation: bindingAllocation,
    label: 'approvalbinding0001',
  });
  await bootstrapPool.query('SET session_replication_role = replica');
  try {
    const tampered = await bootstrapPool.query(
      `UPDATE roomscan.publication_approvals
          SET approval_digest = $1::bytea
        WHERE workspace_id = $2::uuid AND allocation_id = $3::uuid`,
      [digest('approvalbinding0001:tampered'), ids.workspaceA, bindingAllocation.allocation_id],
    );
    assert.equal(tampered.rowCount, 1, 'approval-binding corruption positive control must reach one immutable approval row');
  } finally {
    await bootstrapPool.query('SET session_replication_role = origin');
  }
  await assert.rejects(
    () => finalizePublication({ claim: bindingClaim, at: bindingAt, label: 'approvalbinding0001' }),
    (error) => error?.code === 'P0001' && error?.message === 'PUBLICATION_APPROVAL_BINDING_INVALID',
    'finalization must fail closed when a persisted approval digest no longer binds the exact allocated snapshot',
  );

  // These probes bypass immutable/FK enforcement only inside the disposable
  // test cluster.  They prove the finalizer itself closes root and exact
  // source/approval identity, rather than relying on the normal write path.
  const rootIdentityAt = new Date(bindingAt.getTime() + 1000);
  const rootIdentityAccess = await seedFreshAccess({ label: 'root-identity', at: rootIdentityAt });
  const rootIdentityAllocation = await allocatePublication({
    access: rootIdentityAccess, at: rootIdentityAt,
    projectPublicID: source.projectPublicId,
    sourceRevisionPublicID: source.revisionPublicId,
    sourceDigest: source.sourceDigest, sourceManifestDigest: source.sourceManifestDigest,
    sourceBindings: [sourceBinding(source, 'room-001')],
    label: 'rootidentity0001', versions: await currentFlagVersions(),
  });
  const rootIdentityClaim = await completeAndClaimPublication({
    access: rootIdentityAccess, at: rootIdentityAt,
    allocation: rootIdentityAllocation, label: 'rootidentity0001',
  });
  await bootstrapPool.query('SET session_replication_role = replica');
  try {
    const tampered = await bootstrapPool.query(
      `UPDATE roomscan.publication_allocations
          SET project_id = $1::uuid
        WHERE workspace_id = $2::uuid AND allocation_id = $3::uuid`,
      [sourceA2.projectID, ids.workspaceA, rootIdentityAllocation.allocation_id],
    );
    assert.equal(tampered.rowCount, 1,
      'root provenance positive control must detach one same-tenant project-A/revision-B allocation row');
  } finally {
    await bootstrapPool.query('SET session_replication_role = origin');
  }
  await assert.rejects(
    () => finalizePublication({ claim: rootIdentityClaim, at: rootIdentityAt, label: 'rootidentity0001' }),
    (error) => error?.code === 'P0001' && error?.message === 'PUBLICATION_SOURCE_CHANGED',
    'finalization must reject a root project that no longer owns the allocated source revision',
  );

  const sourceIdentityAt = new Date(rootIdentityAt.getTime() + 1000);
  const sourceIdentityAccess = await seedFreshAccess({ label: 'source-identity', at: sourceIdentityAt });
  const sourceIdentityAllocation = await allocatePublication({
    access: sourceIdentityAccess, at: sourceIdentityAt,
    projectPublicID: source.projectPublicId,
    sourceRevisionPublicID: source.revisionPublicId,
    sourceDigest: source.sourceDigest, sourceManifestDigest: source.sourceManifestDigest,
    sourceBindings: [sourceBinding(source, 'room-001')],
    label: 'sourceidentity0001', versions: await currentFlagVersions(),
  });
  const sourceIdentityClaim = await completeAndClaimPublication({
    access: sourceIdentityAccess, at: sourceIdentityAt,
    allocation: sourceIdentityAllocation, label: 'sourceidentity0001',
  });
  await bootstrapPool.query('SET session_replication_role = replica');
  try {
    const tampered = await bootstrapPool.query(
      `UPDATE roomscan.publication_sources
          SET source_revision_id = $1::uuid, source_revision_public_id = $2::text
        WHERE workspace_id = $3::uuid AND allocation_id = $4::uuid`,
      [sourceA2.revisionId, sourceA2.revisionPublicId, ids.workspaceA, sourceIdentityAllocation.allocation_id],
    );
    assert.equal(tampered.rowCount, 1,
      'source identity positive control must detach one persisted immutable source UUID/public-ID pair');
  } finally {
    await bootstrapPool.query('SET session_replication_role = origin');
  }
  await assert.rejects(
    () => finalizePublication({ claim: sourceIdentityClaim, at: sourceIdentityAt, label: 'sourceidentity0001' }),
    (error) => error?.code === 'P0001' && error?.message === 'PUBLICATION_APPROVAL_BINDING_INVALID',
    'finalization must compare the persisted source UUID and public revision ID to its allocation',
  );

  const approvalIdentityAt = new Date(sourceIdentityAt.getTime() + 1000);
  const approvalIdentityAccess = await seedFreshAccess({ label: 'approval-identity', at: approvalIdentityAt });
  const approvalIdentityAllocation = await allocatePublication({
    access: approvalIdentityAccess, at: approvalIdentityAt,
    projectPublicID: source.projectPublicId,
    sourceRevisionPublicID: source.revisionPublicId,
    sourceDigest: source.sourceDigest, sourceManifestDigest: source.sourceManifestDigest,
    sourceBindings: [sourceBinding(source, 'room-001')],
    label: 'approvalidentity0001', versions: await currentFlagVersions(),
  });
  const approvalIdentityClaim = await completeAndClaimPublication({
    access: approvalIdentityAccess, at: approvalIdentityAt,
    allocation: approvalIdentityAllocation, label: 'approvalidentity0001',
  });
  await bootstrapPool.query('SET session_replication_role = replica');
  try {
    const tampered = await bootstrapPool.query(
      `UPDATE roomscan.publication_approvals
          SET source_revision_id = $1::uuid, source_revision_public_id = $2::text
        WHERE workspace_id = $3::uuid AND allocation_id = $4::uuid`,
      [sourceA2.revisionId, sourceA2.revisionPublicId, ids.workspaceA, approvalIdentityAllocation.allocation_id],
    );
    assert.equal(tampered.rowCount, 1,
      'approval identity positive control must detach one persisted approval UUID/public-ID pair');
  } finally {
    await bootstrapPool.query('SET session_replication_role = origin');
  }
  await assert.rejects(
    () => finalizePublication({ claim: approvalIdentityClaim, at: approvalIdentityAt, label: 'approvalidentity0001' }),
    (error) => error?.code === 'P0001' && error?.message === 'PUBLICATION_APPROVAL_BINDING_INVALID',
    'finalization must bind approval identity to the same exact immutable source revision',
  );

  const identityPositiveAt = new Date(approvalIdentityAt.getTime() + 1000);
  const identityPositiveAccess = await seedFreshAccess({ label: 'identity-positive', at: identityPositiveAt });
  const identityPositiveAllocation = await allocatePublication({
    access: identityPositiveAccess, at: identityPositiveAt,
    projectPublicID: source.projectPublicId,
    sourceRevisionPublicID: source.revisionPublicId,
    sourceDigest: source.sourceDigest, sourceManifestDigest: source.sourceManifestDigest,
    sourceBindings: [sourceBinding(source, 'room-001')],
    label: 'identitypositive0001', versions: await currentFlagVersions(),
  });
  const identityPositiveClaim = await completeAndClaimPublication({
    access: identityPositiveAccess, at: identityPositiveAt,
    allocation: identityPositiveAllocation, label: 'identitypositive0001',
  });
  assert.equal((await finalizePublication({
    claim: identityPositiveClaim, at: identityPositiveAt, label: 'identitypositive0001',
  })).status, 'published', 'an untampered root/source/approval identity control must still finalize');

  // Both workers begin while a third session owns the allocation row.  This
  // forces them through the pre-lock snapshot lookup before one can publish,
  // exercising the post-lock immutable-snapshot recheck rather than relying
  // on scheduler luck.
  const concurrentFinalizeAt = new Date(identityPositiveAt.getTime() + 1000);
  const concurrentFinalizeAccess = await seedFreshAccess({
    label: 'concurrent-finalize', at: concurrentFinalizeAt,
  });
  const concurrentFinalizeAllocation = await allocatePublication({
    access: concurrentFinalizeAccess, at: concurrentFinalizeAt,
    projectPublicID: source.projectPublicId,
    sourceRevisionPublicID: source.revisionPublicId,
    sourceDigest: source.sourceDigest, sourceManifestDigest: source.sourceManifestDigest,
    sourceBindings: [sourceBinding(source, 'room-001')],
    label: 'concurrentfinalize0001', versions: await currentFlagVersions(),
  });
  const concurrentFinalizeClaim = await completeAndClaimPublication({
    access: concurrentFinalizeAccess, at: concurrentFinalizeAt,
    allocation: concurrentFinalizeAllocation, label: 'concurrentfinalize0001',
  });
  const allocationBarrier = await bootstrapPool.connect();
  const finalizeWorkerA = await workerPool.connect();
  const finalizeWorkerB = await workerPool.connect();
  let allocationBarrierOpen = false;
  try {
    await allocationBarrier.query('BEGIN');
    allocationBarrierOpen = true;
    await allocationBarrier.query(
      `SELECT 1 FROM roomscan.publication_allocations
        WHERE allocation_id = $1::uuid FOR UPDATE`,
      [concurrentFinalizeAllocation.allocation_id],
    );
    await labelBackend(finalizeWorkerA, 'slice6-finalize-retry-a');
    await labelBackend(finalizeWorkerB, 'slice6-finalize-retry-b');
    const finalizedByA = finalizePublication({
      claim: concurrentFinalizeClaim, at: concurrentFinalizeAt,
      label: 'concurrentfinalize0001', executor: finalizeWorkerA,
    });
    const finalizedByB = finalizePublication({
      claim: concurrentFinalizeClaim, at: concurrentFinalizeAt,
      label: 'concurrentfinalize0001', executor: finalizeWorkerB,
    });
    await waitForBlockedBackends(
      ['slice6-finalize-retry-a', 'slice6-finalize-retry-b'],
      'both finalizers must block on the same allocation row before publication is released',
    );
    await allocationBarrier.query('COMMIT');
    allocationBarrierOpen = false;
    const concurrentFinalizations = await Promise.all([finalizedByA, finalizedByB]);
    assert.equal(concurrentFinalizations[0].snapshot_id, concurrentFinalizations[1].snapshot_id,
      'concurrent finalization retries for one allocation must resolve to one immutable snapshot ID');
    assert.deepEqual(
      concurrentFinalizations.map(({ status }) => status).sort(),
      ['existing', 'published'],
      'one concurrent finalizer publishes and the locked retry returns the existing snapshot without a lease/state race',
    );
  } finally {
    if (allocationBarrierOpen) {
      await allocationBarrier.query('ROLLBACK');
    }
    allocationBarrier.release();
    finalizeWorkerA.release();
    finalizeWorkerB.release();
  }

  // Kill-first is a genuine two-session ordering: the operator owns the
  // publication flag update while the worker reaches the live-grant barrier.
  // When the kill commits first, no immutable snapshot may be created.
  const killFirstAt = new Date(concurrentFinalizeAt.getTime() + 1000);
  const killFirstAccess = await seedFreshAccess({ label: 'kill-first-finalize', at: killFirstAt });
  const killFirstAllocation = await allocatePublication({
    access: killFirstAccess, at: killFirstAt,
    projectPublicID: source.projectPublicId,
    sourceRevisionPublicID: source.revisionPublicId,
    sourceDigest: source.sourceDigest, sourceManifestDigest: source.sourceManifestDigest,
    sourceBindings: [sourceBinding(source, 'room-001')],
    label: 'killfirstfinalize0001', versions: await currentFlagVersions(),
  });
  const killFirstClaim = await completeAndClaimPublication({
    access: killFirstAccess, at: killFirstAt,
    allocation: killFirstAllocation, label: 'killfirstfinalize0001',
  });
  const killFirstOperator = await bootstrapPool.connect();
  const killFirstWorker = await workerPool.connect();
  let killFirstTransactionOpen = false;
  let killFirstOperatorRole = false;
  try {
    const publicationVersion = Number((await bootstrapPool.query(
      `SELECT version FROM roomscan.global_operational_flags
        WHERE flag_key = 'publication_enabled'`,
    )).rows[0].version);
    await labelBackend(killFirstOperator, 'slice6-kill-first-operator');
    await killFirstOperator.query('BEGIN');
    killFirstTransactionOpen = true;
    await killFirstOperator.query('SET ROLE roomscan_operator');
    killFirstOperatorRole = true;
    await killFirstOperator.query(
      `SELECT * FROM roomscan.set_operational_flag(
         'global'::text, NULL::uuid, 'publication_enabled'::text, false,
         $1::bigint, 'Slice 6 kill-first ordering',
         'ofaud_s6_kill_first_order'::text, $2::timestamptz
       )`,
      [publicationVersion, new Date(killFirstAt.getTime() + 1)],
    );
    await labelBackend(killFirstWorker, 'slice6-finalize-after-kill');
    const finalizationAfterKill = finalizePublication({
      claim: killFirstClaim, at: new Date(killFirstAt.getTime() + 1),
      label: 'killfirstfinalize0001', executor: killFirstWorker,
    });
    await waitForBlockedBackends(
      ['slice6-finalize-after-kill'],
      'the finalizer must wait behind the uncommitted kill before it can decide the live grant',
    );
    await killFirstOperator.query('COMMIT');
    killFirstTransactionOpen = false;
    await assert.rejects(
      () => finalizationAfterKill,
      (error) => error?.code === '42501' && error?.message === 'PUBLICATION_GRANT_REJECTED',
      'a kill that commits first must deny the waiting finalizer before any immutable snapshot is created',
    );
    assert.equal(Number((await bootstrapPool.query(
      `SELECT count(*)::integer AS count FROM roomscan.publication_snapshots
        WHERE allocation_id = $1::uuid`,
      [killFirstAllocation.allocation_id],
    )).rows[0].count), 0,
    'kill-first concurrency must leave no snapshot for the blocked allocation');
    await killFirstOperator.query('RESET ROLE');
    killFirstOperatorRole = false;
    await setFlag(
      'global', null, 'publication_enabled', 'ofaud_s6_kill_first_restore', true,
      new Date(killFirstAt.getTime() + 2),
    );
  } finally {
    if (killFirstTransactionOpen) {
      await killFirstOperator.query('ROLLBACK');
    }
    if (killFirstOperatorRole) {
      await killFirstOperator.query('RESET ROLE');
    }
    killFirstOperator.release();
    killFirstWorker.release();
  }

  // Finalize-first uses a temporary
  // trigger barrier after finalization acquires all four live flag row locks:
  // the kill must wait until the immutable snapshot transaction is ordered.
  const flagBarrierAt = new Date(killFirstAt.getTime() + 1000);
  const flagBarrierAccess = await seedFreshAccess({ label: 'flag-barrier-finalize', at: flagBarrierAt });
  const flagBarrierAllocation = await allocatePublication({
    access: flagBarrierAccess, at: flagBarrierAt,
    projectPublicID: source.projectPublicId,
    sourceRevisionPublicID: source.revisionPublicId,
    sourceDigest: source.sourceDigest, sourceManifestDigest: source.sourceManifestDigest,
    sourceBindings: [sourceBinding(source, 'room-001')],
    label: 'flagbarrierfinalize0001', versions: await currentFlagVersions(),
  });
  const flagBarrierClaim = await completeAndClaimPublication({
    access: flagBarrierAccess, at: flagBarrierAt,
    allocation: flagBarrierAllocation, label: 'flagbarrierfinalize0001',
  });
  const advisoryKey = 609006;
  const barrierHolder = await bootstrapPool.connect();
  const flagFinalizeWorker = await workerPool.connect();
  const flagOperator = await bootstrapPool.connect();
  let barrierHeld = false;
  let flagOperatorRole = false;
  try {
    await barrierHolder.query('SELECT pg_advisory_lock($1::bigint)', [advisoryKey]);
    barrierHeld = true;
    await bootstrapPool.query(
      `CREATE FUNCTION public.slice6_finalize_flag_barrier_v1()
       RETURNS trigger LANGUAGE plpgsql AS $barrier$
       BEGIN
         PERFORM pg_advisory_xact_lock(${advisoryKey}::bigint);
         RETURN NEW;
       END
       $barrier$`,
    );
    await bootstrapPool.query(
      `CREATE TRIGGER slice6_finalize_flag_barrier
         BEFORE INSERT ON roomscan.publication_snapshots
         FOR EACH ROW EXECUTE FUNCTION public.slice6_finalize_flag_barrier_v1()`,
    );
    await labelBackend(flagFinalizeWorker, 'slice6-finalize-flag-barrier');
    const flaggedFinalization = finalizePublication({
      claim: flagBarrierClaim, at: flagBarrierAt,
      label: 'flagbarrierfinalize0001', executor: flagFinalizeWorker,
    });
    await waitForBlockedBackends(
      ['slice6-finalize-flag-barrier'],
      'the finalizer must reach the post-grant snapshot insert barrier while holding live flag share locks',
    );
    const publicationGlobalVersion = Number((await bootstrapPool.query(
      `SELECT version FROM roomscan.global_operational_flags
        WHERE flag_key = 'publication_enabled'`,
    )).rows[0].version);
    await labelBackend(flagOperator, 'slice6-kill-after-finalize');
    await flagOperator.query('SET ROLE roomscan_operator');
    flagOperatorRole = true;
    const killAfterFinalization = flagOperator.query(
      `SELECT * FROM roomscan.set_operational_flag(
         'global'::text, NULL::uuid, 'publication_enabled'::text, false,
         $1::bigint, 'Slice 6 finalization lock ordering',
         'ofaud_s6_finalize_barrier_kill'::text, $2::timestamptz
       )`,
      [publicationGlobalVersion, new Date(flagBarrierAt.getTime() + 1)],
    );
    await waitForBlockedBackends(
      ['slice6-kill-after-finalize'],
      'the global publication kill must wait for the finalizer live-flag barrier',
    );
    await barrierHolder.query('SELECT pg_advisory_unlock($1::bigint)', [advisoryKey]);
    barrierHeld = false;
    const flaggedSnapshot = await flaggedFinalization;
    await killAfterFinalization;
    assert.equal(flaggedSnapshot.status, 'published',
      'a finalizer already holding the four-row live grant barrier must publish before the waiting kill commits');
    await assert.rejects(
      () => portalPool.query(
        'SELECT * FROM roomscan.portal_get_snapshot_v1($1::bytea, $2::timestamptz)',
        [propertyPinSessionHash, new Date(flagBarrierAt.getTime() + 2)],
      ),
      (error) => error?.code === '42501',
      'after the waiting kill commits every previously active portal session must fail its next protected request',
    );
    await assert.rejects(
      () => finalizeProfessionalAsset({
        sessionHash: professionalReadSessionHash,
        at: new Date(flagBarrierAt.getTime() + 2),
        authorization: professionalAssetAuthorization,
        requestDigest: professionalAssetRequestDigest,
      }),
      (error) => error?.code === '42501' && error?.message === 'PROFESSIONAL_PORTAL_ACCESS_DENIED',
      'the same kill switch must deny a professional-cookie exact asset finalization after a prior authorization',
    );
    await flagOperator.query('RESET ROLE');
    flagOperatorRole = false;
    await setFlag(
      'global', null, 'publication_enabled', 'ofaud_s6_finalize_barrier_restore', true,
      new Date(flagBarrierAt.getTime() + 3),
    );
  } finally {
    if (flagOperatorRole) {
      await flagOperator.query('RESET ROLE');
    }
    if (barrierHeld) {
      await barrierHolder.query('SELECT pg_advisory_unlock($1::bigint)', [advisoryKey]);
    }
    await bootstrapPool.query('DROP TRIGGER IF EXISTS slice6_finalize_flag_barrier ON roomscan.publication_snapshots');
    await bootstrapPool.query('DROP FUNCTION IF EXISTS public.slice6_finalize_flag_barrier_v1()');
    barrierHolder.release();
    flagFinalizeWorker.release();
    flagOperator.release();
  }

  // The sealed delivery worker must serialize concurrent claims and recheck a
  // live grant immediately before send.  These are distinct from portal
  // session tests: the worker sees only an encrypted envelope, never a portal
  // bearer, link token, or email digest.
  const feedbackLifecycleAt = new Date(flagBarrierAt.getTime() + 4_000);
  const createFeedbackLifecyclePortal = async (label, at) => {
    const access = await seedFreshAccess({ label: `feedback-lifecycle-${label}`, at });
    const linkRow = (await apiPool.query(
      `SELECT * FROM roomscan.publication_create_link_v1(
        'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text, $4::bytea,
        NULL::timestamptz, NULL::bytea, NULL::bytea, 'disabled'::text,
        'enabled'::text, $5::bytea
      )`,
      [
        access, at, finalized.snapshot_public_id, digest(`feedback-lifecycle-${label}:link-token`),
        digest(`feedback-lifecycle-${label}:link-request`),
      ],
    )).rows[0];
    const sessionHash = digest(`feedback-lifecycle-${label}:session`);
    assert.equal((await portalPool.query(
      `SELECT * FROM roomscan.portal_exchange_link_v1(
        $1::bytea, $2::timestamptz, $3::bytea, 'desktop'::text, $4::bytea
      )`,
      [
        digest(`feedback-lifecycle-${label}:link-token`), at, sessionHash,
        digest(`feedback-lifecycle-${label}:risk`),
      ],
    )).rows[0].status, 'active',
    `${label} feedback lifecycle needs a live same-tenant portal positive control`);
    return { access, linkRow, sessionHash };
  };
  const concurrentPortal = await createFeedbackLifecyclePortal('concurrent', feedbackLifecycleAt);
  const concurrentIssue = await requestFeedbackVerification({
    sessionHash: concurrentPortal.sessionHash, at: feedbackLifecycleAt,
    challengeHash: digest('feedback-lifecycle-concurrent:challenge'),
    verificationTokenHash: digest('feedback-lifecycle-concurrent:token'),
    verifiedEmailDigest: digest('feedback-lifecycle-concurrent:email'),
    requestDigest: digest('feedback-lifecycle-concurrent:request'),
    envelopeLabel: 'feedback-lifecycle-concurrent',
  });
  assert.equal(concurrentIssue.status, 'issued');
  const concurrentClaims = await Promise.all([
    emailPool.query(
      `SELECT * FROM roomscan.claim_next_feedback_delivery_v3($1::text, $2::timestamptz, $3::timestamptz)`,
      ['feedback-concurrent-lease-a', feedbackLifecycleAt, new Date(feedbackLifecycleAt.getTime() + 5 * 60 * 1000)],
    ).then(({ rows }) => rows[0] ?? null),
    emailPool.query(
      `SELECT * FROM roomscan.claim_next_feedback_delivery_v3($1::text, $2::timestamptz, $3::timestamptz)`,
      ['feedback-concurrent-lease-b', feedbackLifecycleAt, new Date(feedbackLifecycleAt.getTime() + 5 * 60 * 1000)],
    ).then(({ rows }) => rows[0] ?? null),
  ]);
  const concurrentClaim = concurrentClaims.find((row) => row !== null);
  assert.equal(concurrentClaims.filter((row) => row !== null).length, 1,
    'two concurrent sealed worker claims must lease one pending feedback delivery exactly once');
  assert.equal(concurrentClaim.status, 'leased');
  const feedbackKillAt = new Date(feedbackLifecycleAt.getTime() + 1_000);
  await setFlag(
    'global', null, 'publication_enabled', 'ofaud_s6_feedback_delivery_kill', false, feedbackKillAt,
  );
  const killedValidation = (await emailPool.query(
    `SELECT * FROM roomscan.validate_feedback_delivery_v3($1::text, $2::text, $3::timestamptz)`,
    [concurrentClaim.delivery_id, concurrentClaim.lease_id, feedbackKillAt],
  )).rows[0];
  assert.equal(killedValidation.status, 'cancelled',
    'a kill committed after claim but before send must cancel the sealed delivery without returning its envelope');
  assert.deepEqual(
    Object.keys(killedValidation).filter((key) => ['iv', 'ciphertext', 'authentication_tag'].includes(key)),
    ['iv', 'ciphertext', 'authentication_tag'],
    'the explicit terminal projection keeps fixed null fields rather than changing response shape');
  assert.equal(killedValidation.ciphertext, null,
    'a killed delivery validation must withhold encrypted email payload before send');
  await setFlag(
    'global', null, 'publication_enabled', 'ofaud_s6_feedback_delivery_restore', true,
    new Date(feedbackKillAt.getTime() + 1),
  );

  const revokedFeedbackAt = new Date(feedbackKillAt.getTime() + 2_000);
  const revokedPortal = await createFeedbackLifecyclePortal('revoked', revokedFeedbackAt);
  const revokedIssue = await requestFeedbackVerification({
    sessionHash: revokedPortal.sessionHash, at: revokedFeedbackAt,
    challengeHash: digest('feedback-lifecycle-revoked:challenge'),
    verificationTokenHash: digest('feedback-lifecycle-revoked:token'),
    verifiedEmailDigest: digest('feedback-lifecycle-revoked:email'),
    requestDigest: digest('feedback-lifecycle-revoked:request'),
    envelopeLabel: 'feedback-lifecycle-revoked',
  });
  assert.equal(revokedIssue.status, 'issued');
  const revokedClaim = (await emailPool.query(
    `SELECT * FROM roomscan.claim_next_feedback_delivery_v3($1::text, $2::timestamptz, $3::timestamptz)`,
    ['feedback-revoked-lease', revokedFeedbackAt, new Date(revokedFeedbackAt.getTime() + 5 * 60 * 1000)],
  )).rows[0];
  assert.equal(revokedClaim.status, 'leased');
  assert.equal((await apiPool.query(
    `SELECT * FROM roomscan.publication_revoke_link_v1(
      'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text, 1::bigint
    )`,
    [revokedPortal.access, new Date(revokedFeedbackAt.getTime() + 1), revokedPortal.linkRow.link_public_id],
  )).rows[0].status, 'revoked');
  const revokedValidation = (await emailPool.query(
    `SELECT * FROM roomscan.validate_feedback_delivery_v3($1::text, $2::text, $3::timestamptz)`,
    [revokedClaim.delivery_id, revokedClaim.lease_id, new Date(revokedFeedbackAt.getTime() + 2)],
  )).rows[0];
  assert.equal(revokedValidation.status, 'cancelled',
    'link revocation after claim but before send must immediately cancel the matching feedback delivery');

  const expiryFeedbackAt = new Date(revokedFeedbackAt.getTime() + 3_000);
  const expiryPortal = await createFeedbackLifecyclePortal('expiry', expiryFeedbackAt);
  const expiryIssue = await requestFeedbackVerification({
    sessionHash: expiryPortal.sessionHash, at: expiryFeedbackAt,
    challengeHash: digest('feedback-lifecycle-expiry:challenge'),
    verificationTokenHash: digest('feedback-lifecycle-expiry:token'),
    verifiedEmailDigest: digest('feedback-lifecycle-expiry:email'),
    requestDigest: digest('feedback-lifecycle-expiry:request'),
    envelopeLabel: 'feedback-lifecycle-expiry',
  });
  assert.equal(expiryIssue.status, 'issued');
  const expiryAt = new Date(expiryFeedbackAt.getTime() + 15 * 60 * 1000);
  assert.deepEqual((await emailPool.query(
    `SELECT * FROM roomscan.claim_next_feedback_delivery_v3($1::text, $2::timestamptz, $3::timestamptz)`,
    ['feedback-expiry-lease', expiryAt, new Date(expiryAt.getTime() + 5 * 60 * 1000)],
  )).rows, [], 'delivery expiry equality must deny a fresh email lease');
  assert.equal((await bootstrapPool.query(
    `SELECT state FROM roomscan.portal_feedback_delivery_outbox WHERE challenge_id = $1::uuid`,
    [expiryIssue.challenge_id],
  )).rows[0].state, 'expired',
  'an expired feedback envelope must transition terminally rather than remain claimable');

  // The same opaque link-generation/risk bucket permits exactly three issue
  // requests in fifteen minutes.  Equality is deliberately a reset boundary,
  // not an accidental fourth-request denial caused by a strict comparison.
  const throttleAt = new Date(flagBarrierAt.getTime() + 4_000);
  const throttleAccess = await seedFreshAccess({ label: 'feedback-throttle', at: throttleAt });
  const throttleLink = (await apiPool.query(
    `SELECT * FROM roomscan.publication_create_link_v1(
      'app_bearer'::text, $1::bytea, $2::timestamptz, $3::text, $4::bytea,
      NULL::timestamptz, NULL::bytea, NULL::bytea, 'disabled'::text,
      'enabled'::text, $5::bytea
    )`,
    [
      throttleAccess, throttleAt, finalized.snapshot_public_id,
      digest('feedback-throttle-link-token'), digest('feedback-throttle-link-request'),
    ],
  )).rows[0];
  const throttleSessionHash = digest('feedback-throttle-session');
  assert.equal((await portalPool.query(
    `SELECT * FROM roomscan.portal_exchange_link_v1(
      $1::bytea, $2::timestamptz, $3::bytea, 'desktop'::text, $4::bytea
    )`,
    [
      digest('feedback-throttle-link-token'), throttleAt, throttleSessionHash,
      digest('feedback-throttle-risk'),
    ],
  )).rows[0].status, 'active',
  'feedback throttle must start from a fresh live portal session after kill-switch epochs rotate');
  const throttleIssue = async (suffix, at) => requestFeedbackVerification({
    sessionHash: throttleSessionHash,
    at,
    challengeHash: digest(`feedback-throttle-${suffix}:challenge`),
    verificationTokenHash: digest(`feedback-throttle-${suffix}:token`),
    verifiedEmailDigest: digest('cross-link-email'),
    requestDigest: digest(`feedback-throttle-${suffix}:request`),
    envelopeLabel: `feedback-throttle-${suffix}`,
  });
  for (const suffix of ['one', 'two', 'three']) {
    const issued = await throttleIssue(suffix, throttleAt);
    assert.equal(issued.status, 'issued',
      `feedback throttle positive control ${suffix} must reach an allowed issue path`);
  }
  const throttled = await throttleIssue('four', new Date(throttleAt.getTime() + 1));
  assert.deepEqual(
    { status: throttled.status, hasChallenge: throttled.challenge_id !== null, hasExpiry: throttled.expires_at !== null },
    { status: 'cooldown', hasChallenge: false, hasExpiry: false },
    'the fourth feedback issue in one controlled fifteen-minute window must cool down without issuing mail scope',
  );
  const resetIssued = await throttleIssue('reset-equality', new Date(throttled.retry_after));
  assert.equal(resetIssued.status, 'issued',
    'feedback throttle equality at fifteen minutes must reset the bounded issue window');
  assert.equal(/email|token|ciphertext|network|session|link/u.test(JSON.stringify(throttled)), false,
    'feedback cooldown output must not echo email, token, envelope, network, session, or link material');

  // A property approval freezes multiple independent canonical sources. Every
  // source project stays locked from exact validation through immutable snapshot
  // insertion, so a Slice 5 append cannot commit between review and publication.
  const sourceLockProjectSyncPool = new Pool({
    ...appPoolConfig(cluster, 2), user: 'roomscan_project_sync_runtime', max: 2,
  });
  let sourceLockSeedSequence = 0;
  const seedSourceLockCanonical = async (label, suffix) => {
    sourceLockSeedSequence += 1;
    const decimalSuffix = String(suffix).padStart(12, '0');
    const publicSuffix = String(suffix).padStart(4, '0');
    const projectID = `73000000-0000-4000-8000-${decimalSuffix}`;
    const revisionId = `74000000-0000-4000-8000-${decimalSuffix}`;
    const projectPublicId = `prj_sourcelockproject${publicSuffix}`;
    const revisionPublicId = `rev_sourcelockrevision${publicSuffix}`;
    const sourceProjectId = `source_project_lock_${publicSuffix}`;
    const sourceRevisionId = `source_revision_lock_${publicSuffix}`;
    await bootstrapPool.query(
      `INSERT INTO roomscan.projects (id, workspace_id, slug, title)
       VALUES ($1::uuid, $2::uuid, $3::text, $4::text)`,
      [projectID, ids.workspaceA, `source-lock-${publicSuffix}`, `Source lock ${label}`],
    );
    await bootstrapPool.query(
      `INSERT INTO roomscan.professional_projects (
         workspace_id, project_id, public_id, source_project_id, head_revision_id,
         raw_archive_enabled, version, created_at, updated_at
       ) VALUES ($1::uuid, $2::uuid, $3::text, $4::text, NULL,
         false, 1, $5::timestamptz, $5::timestamptz)`,
      [ids.workspaceA, projectID, projectPublicId, sourceProjectId, now],
    );
    await bootstrapPool.query(
      `INSERT INTO roomscan.project_revisions (
         workspace_id, id, public_id, project_id, source_revision_id,
         branch_state, working_object_key, working_object_version,
         working_digest, working_bytes, working_manifest_digest, created_at
       ) VALUES ($1::uuid, $2::uuid, $3::text, $4::uuid, $5::text, 'canonical',
         'professional-sync/active/working/' || $3 || '.zip', $6::text,
         $7::bytea, 111::bigint, $8::bytea, $9::timestamptz)`,
      [
        ids.workspaceA, revisionId, revisionPublicId, projectID, sourceRevisionId,
        `source-lock-version-${publicSuffix}`, digest(`${label}:archive`),
        digest(`${label}:manifest`), now,
      ],
    );
    await bootstrapPool.query(
      `UPDATE roomscan.professional_projects
          SET head_revision_id = $1::uuid, updated_at = $2::timestamptz
        WHERE workspace_id = $3::uuid AND project_id = $4::uuid`,
      [revisionId, now, ids.workspaceA, projectID],
    );
    return {
      projectID,
      projectPublicId,
      sourceProjectId,
      revisionId,
      revisionPublicId,
      sourceRevisionId,
      coordinateSpaceEpochID: `epoch_source_lock_${publicSuffix}`,
      packageSchemaVersion: 'room-scan-project-v2',
      semanticSHA256: digest(`${label}:semantic`).toString('hex'),
      revisionManifestSHA256: digest(`${label}:revision-manifest`).toString('hex'),
      sourceDigest: digest(`${label}:archive`),
      sourceManifestDigest: digest(`${label}:manifest`),
    };
  };
  const createSourceLockPropertyPublication = async ({ label, at, sources }) => {
    const access = await seedFreshAccess({ label: `${label}-publication`, at });
    const rooms = sources.map((sourceRow, index) => ({
      source: sourceRow,
      publicRoomKey: `room-${String(index + 1).padStart(3, '0')}`,
    }));
    const property = await upsertPublicationProperty({
      access,
      at,
      propertyPublicID: `prop_sourcelock${label.replaceAll('-', '')}0001`,
      expectedVersion: 0,
      title: `Source-lock ${label}`,
      rooms: rooms.map(({ source: sourceRow, publicRoomKey }) => ({
        publicRoomKey,
        projectPublicID: sourceRow.projectPublicId,
      })),
    });
    assert.equal(property.status, 'created', `${label} property curation must be created before approval`);
    const root = rooms[0].source;
    const allocation = await allocatePublication({
      access,
      at,
      projectPublicID: root.projectPublicId,
      sourceRevisionPublicID: root.revisionPublicId,
      sourceDigest: root.sourceDigest,
      sourceManifestDigest: root.sourceManifestDigest,
      sourceBindings: rooms.map(({ source: sourceRow, publicRoomKey }) => sourceBinding(sourceRow, publicRoomKey)),
      label,
      publicationKind: 'property',
      propertyPublicID: property.property_public_id,
      versions: await currentFlagVersions(),
    });
    const claim = await completeAndClaimPublication({ access, at, allocation, label });
    return { access, property, allocation, claim, rooms };
  };
  const activeQuotaPolicyVersion = async () => {
    const row = (await bootstrapPool.query(
      `SELECT version FROM roomscan.quota_policy_versions_v2
        WHERE workspace_id = $1::uuid AND is_active IS TRUE`,
      [ids.workspaceA],
    )).rows[0];
    assert.ok(row, 'source-lock fixtures require an active quota policy');
    return Number(row.version);
  };
  const prepareSlice5Append = async ({ access, source: sourceRow, at, label }) => {
    const versions = await currentFlagVersions();
    const allocation = (await apiPool.query(
      `SELECT * FROM roomscan.allocate_project_revision_v1(
         $1::bytea, $2::timestamptz, $3::text, $4::text, $5::text, $6::text,
         $7::bytea, $8::bytea, 111::bigint, $9::bytea, $10::bigint,
         $11::bigint, $12::bigint
       )`,
      [
        access, at, sourceRow.projectPublicId, sourceRow.revisionPublicId,
        sourceRow.sourceRevisionId, `${sourceRow.sourceRevisionId}_${label}`,
        digest(`${label}:manifest`), digest(`${label}:archive`), digest(`${label}:idempotency`),
        await activeQuotaPolicyVersion(), versions.hosted_global, versions.hosted_workspace,
      ],
    )).rows[0];
    assert.equal(allocation.status, 'allocated', `${label} Slice 5 append must allocate`);
    const completed = (await apiPool.query(
      'SELECT * FROM roomscan.complete_project_upload_v1($1::bytea, $2::timestamptz, $3::text)',
      [access, at, allocation.upload_public_id],
    )).rows[0];
    assert.equal(completed.status, 'validation_pending', `${label} Slice 5 append must become claimable`);
    const claim = (await sourceLockProjectSyncPool.query(
      'SELECT * FROM roomscan.claim_next_project_validation_v1($1::timestamptz)',
      [at],
    )).rows[0];
    assert.ok(claim, `${label} Slice 5 append must receive a targetless worker claim`);
    assert.equal(claim.candidate_revision_public_id, allocation.candidate_revision_public_id,
      `${label} Slice 5 worker must finalize the staged secondary source`);
    return { allocation, claim };
  };
  const finalizeSlice5Append = async ({ claim, at, label, executor = sourceLockProjectSyncPool }) => {
    return (await executor.query(
      `SELECT * FROM roomscan.finalize_project_upload_v1(
         $1::uuid, $2::text, $3::timestamptz, $4::text, $5::text
       )`,
      [claim.upload_id, claim.lease_id, at, `qv_sourcelock_${label}`, `av_sourcelock_${label}`],
    )).rows[0];
  };
  const snapshotCount = async (allocationID) => Number((await bootstrapPool.query(
    `SELECT count(*)::integer AS count FROM roomscan.publication_snapshots
      WHERE allocation_id = $1::uuid`,
    [allocationID],
  )).rows[0].count);
  try {
    // Opposite approved room orders must still complete together: source locking
    // is by project ID, not mutable property-room order.
    const overlapAt = new Date(throttleAt.getTime() + 2_000);
    const overlapLow = await seedSourceLockCanonical('overlap-low', 501);
    const overlapHigh = await seedSourceLockCanonical('overlap-high', 502);
    const overlapFirst = await createSourceLockPropertyPublication({
      label: 'source-lock-overlap-first', at: overlapAt, sources: [overlapHigh, overlapLow],
    });
    const overlapSecond = await createSourceLockPropertyPublication({
      label: 'source-lock-overlap-second', at: overlapAt, sources: [overlapLow, overlapHigh],
    });
    const overlapAdvisoryKey = 609007;
    const overlapBarrierHolder = await bootstrapPool.connect();
    const overlapFinalizerA = await workerPool.connect();
    const overlapFinalizerB = await workerPool.connect();
    let overlapBarrierHeld = false;
    let overlapFinalizationA;
    let overlapFinalizationB;
    try {
      await overlapBarrierHolder.query('SELECT pg_advisory_lock($1::bigint)', [overlapAdvisoryKey]);
      overlapBarrierHeld = true;
      await bootstrapPool.query(
        `CREATE FUNCTION public.slice6_source_lock_overlap_barrier_v1()
         RETURNS trigger LANGUAGE plpgsql AS $barrier$
         BEGIN
           PERFORM pg_advisory_xact_lock(${overlapAdvisoryKey}::bigint);
           RETURN NEW;
         END
         $barrier$`,
      );
      await bootstrapPool.query(
        `CREATE TRIGGER slice6_source_lock_overlap_barrier
           BEFORE INSERT ON roomscan.publication_snapshots
           FOR EACH ROW EXECUTE FUNCTION public.slice6_source_lock_overlap_barrier_v1()`,
      );
      await labelBackend(overlapFinalizerA, 'slice6-source-lock-overlap-a');
      await labelBackend(overlapFinalizerB, 'slice6-source-lock-overlap-b');
      overlapFinalizationA = finalizePublication({
        claim: overlapFirst.claim, at: overlapAt, label: 'source-lock-overlap-first', executor: overlapFinalizerA,
      });
      overlapFinalizationB = finalizePublication({
        claim: overlapSecond.claim, at: overlapAt, label: 'source-lock-overlap-second', executor: overlapFinalizerB,
      });
      await waitForBlockedBackends(
        ['slice6-source-lock-overlap-a', 'slice6-source-lock-overlap-b'],
        'opposite room-order finalizers must both reach the snapshot barrier without a source-lock deadlock',
      );
      await overlapBarrierHolder.query('SELECT pg_advisory_unlock($1::bigint)', [overlapAdvisoryKey]);
      overlapBarrierHeld = false;
      const overlapResults = await Promise.all([overlapFinalizationA, overlapFinalizationB]);
      assert.deepEqual(overlapResults.map(({ status }) => status).sort(), ['published', 'published'],
        'overlapping properties with opposite approved room orders must not deadlock');
    } finally {
      if (overlapBarrierHeld) {
        await overlapBarrierHolder.query('SELECT pg_advisory_unlock($1::bigint)', [overlapAdvisoryKey]);
      }
      await Promise.allSettled([overlapFinalizationA, overlapFinalizationB].filter(Boolean));
      await bootstrapPool.query('DROP TRIGGER IF EXISTS slice6_source_lock_overlap_barrier ON roomscan.publication_snapshots');
      await bootstrapPool.query('DROP FUNCTION IF EXISTS public.slice6_source_lock_overlap_barrier_v1()');
      overlapBarrierHolder.release();
      overlapFinalizerA.release();
      overlapFinalizerB.release();
    }

    // A real Slice 5 secondary source edit that commits first invalidates the
    // review: finalization must return PUBLICATION_SOURCE_CHANGED with no snapshot.
    const changedFirstAt = new Date(overlapAt.getTime() + 1_000);
    const changedFirstRoot = await seedSourceLockCanonical('changed-first-root', 601);
    const changedFirstSecondary = await seedSourceLockCanonical('changed-first-secondary', 602);
    const changedFirstPublication = await createSourceLockPropertyPublication({
      label: 'source-lock-changed-first', at: changedFirstAt,
      sources: [changedFirstRoot, changedFirstSecondary],
    });
    const changedFirstAccess = await seedFreshAccess({ label: 'source-lock-changed-first-append', at: changedFirstAt });
    const changedFirstAppend = await prepareSlice5Append({
      access: changedFirstAccess, source: changedFirstSecondary, at: changedFirstAt,
      label: 'source-lock-changed-first',
    });
    const changedFirstResult = await finalizeSlice5Append({
      claim: changedFirstAppend.claim, at: changedFirstAt, label: 'source-lock-changed-first',
    });
    assert.equal(changedFirstResult.status, 'canonical',
      'the committed Slice 5 secondary edit control must move its canonical head before publication finalization');
    await assert.rejects(
      () => finalizePublication({
        claim: changedFirstPublication.claim, at: changedFirstAt, label: 'source-lock-changed-first',
      }),
      (error) => error?.code === 'P0001' && error?.message === 'PUBLICATION_SOURCE_CHANGED',
      'a secondary source edit that commits first must invalidate the reviewed publication binding',
    );
    assert.equal(await snapshotCount(changedFirstPublication.allocation.allocation_id), 0,
      'a source-changed finalization must leave no immutable snapshot');

    // The finalizer must hold the secondary project row through snapshot insert.
    // Its real Slice 5 canonical append waits, so release establishes commit order.
    const liveLockAt = new Date(changedFirstAt.getTime() + 1_000);
    const liveLockRoot = await seedSourceLockCanonical('live-root', 709);
    const liveLockSecondary = await seedSourceLockCanonical('live-secondary', 708);
    const liveLockPublication = await createSourceLockPropertyPublication({
      label: 'source-lock-live', at: liveLockAt, sources: [liveLockRoot, liveLockSecondary],
    });
    const liveLockAccess = await seedFreshAccess({ label: 'source-lock-live-append', at: liveLockAt });
    const liveLockAppend = await prepareSlice5Append({
      access: liveLockAccess, source: liveLockSecondary, at: liveLockAt, label: 'source-lock-live',
    });
    const liveLockAdvisoryKey = 609008;
    const liveLockBarrierHolder = await bootstrapPool.connect();
    const liveLockFinalizer = await workerPool.connect();
    const liveLockAppendWorker = await sourceLockProjectSyncPool.connect();
    let liveLockBarrierHeld = false;
    let liveLockFinalization;
    let liveLockAppendFinalization;
    try {
      await liveLockBarrierHolder.query('SELECT pg_advisory_lock($1::bigint)', [liveLockAdvisoryKey]);
      liveLockBarrierHeld = true;
      await bootstrapPool.query(
        `CREATE FUNCTION public.slice6_source_lock_snapshot_barrier_v1()
         RETURNS trigger LANGUAGE plpgsql AS $barrier$
         BEGIN
           PERFORM pg_advisory_xact_lock(${liveLockAdvisoryKey}::bigint);
           RETURN NEW;
         END
         $barrier$`,
      );
      await bootstrapPool.query(
        `CREATE TRIGGER slice6_source_lock_snapshot_barrier
           BEFORE INSERT ON roomscan.publication_snapshots
           FOR EACH ROW EXECUTE FUNCTION public.slice6_source_lock_snapshot_barrier_v1()`,
      );
      await labelBackend(liveLockFinalizer, 'slice6-source-lock-finalizer');
      await labelBackend(liveLockAppendWorker, 'slice6-source-lock-secondary-append');
      liveLockFinalization = finalizePublication({
        claim: liveLockPublication.claim, at: liveLockAt, label: 'source-lock-live', executor: liveLockFinalizer,
      });
      await waitForBlockedBackends(
        ['slice6-source-lock-finalizer'],
        'the finalizer must reach the post-validation snapshot barrier while it holds every source lock',
      );
      liveLockAppendFinalization = finalizeSlice5Append({
        claim: liveLockAppend.claim, at: liveLockAt, label: 'source-lock-live', executor: liveLockAppendWorker,
      });
      await waitForBlockedBackends(
        ['slice6-source-lock-secondary-append'],
        'the Slice 5 secondary edit must wait for the finalizer source lock until immutable snapshot commit',
      );
      await liveLockBarrierHolder.query('SELECT pg_advisory_unlock($1::bigint)', [liveLockAdvisoryKey]);
      liveLockBarrierHeld = false;
      const [liveLockSnapshot, liveLockEdit] = await Promise.all([
        liveLockFinalization,
        liveLockAppendFinalization,
      ]);
      assert.equal(liveLockSnapshot.status, 'published',
        'a finalizer holding the reviewed source locks must publish before the waiting canonical edit');
      assert.equal(liveLockEdit.status, 'canonical',
        'the waiting real Slice 5 append must commit after the immutable snapshot');
      const frozenSecondary = (await bootstrapPool.query(
        `SELECT source_revision_public_id
           FROM roomscan.publication_snapshot_rooms
          WHERE workspace_id = $1::uuid
            AND property_snapshot_id = $2::uuid
            AND room_project_id = $3::uuid`,
        [ids.workspaceA, liveLockSnapshot.snapshot_id, liveLockSecondary.projectID],
      )).rows[0];
      assert.deepEqual(frozenSecondary, { source_revision_public_id: liveLockSecondary.revisionPublicId },
        'the snapshot must freeze the exact approved secondary source that was current before the waiting append');
      assert.notEqual(liveLockEdit.candidate_revision_public_id, frozenSecondary.source_revision_public_id,
        'the post-snapshot Slice 5 append must be a distinct canonical source revision');
    } finally {
      if (liveLockBarrierHeld) {
        await liveLockBarrierHolder.query('SELECT pg_advisory_unlock($1::bigint)', [liveLockAdvisoryKey]);
      }
      await Promise.allSettled([liveLockFinalization, liveLockAppendFinalization].filter(Boolean));
      await bootstrapPool.query('DROP TRIGGER IF EXISTS slice6_source_lock_snapshot_barrier ON roomscan.publication_snapshots');
      await bootstrapPool.query('DROP FUNCTION IF EXISTS public.slice6_source_lock_snapshot_barrier_v1()');
      liveLockBarrierHolder.release();
      liveLockFinalizer.release();
      liveLockAppendWorker.release();
    }
  } finally {
    await sourceLockProjectSyncPool.end();
  }

  console.log('INTEGRATION_0009_PUBLICATION_SUMMARY schema=17 roles=3 allocations=13 completion_claim_finalization=7 concurrent_finalize=1 kill_linearization_orders=2 binding_controls=10 source_lock_controls=3 disclosure_rejection=1 property_navigation=1 property_cas=1 editor_policy_scope=3 root_source_approval_identity=4 pin_snapshot_binding=1 reset_session_asset_denial=1 cross_tenant_denials=4 link_controls=5 pin_attempts=5 pin_kill_epochs=4 protected_assets_downloads=4 portal_bytes=512 feedback_controls=11 feedback_throttle_controls=5 revoke_session_asset_denials=2 kill_controls=6 private_recovery_after_kill=1 status=pass');
} finally {
  await emailPool?.end();
  await portalPool?.end();
  await workerPool?.end();
  await apiPool?.end();
  await bootstrapPool.end();
  const cleanup = await cluster.stop();
  console.log(`PG_CLEANUP ${JSON.stringify(cleanup)}`);
}
