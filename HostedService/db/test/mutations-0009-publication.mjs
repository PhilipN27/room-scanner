import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { cp, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);
const dbRoot = fileURLToPath(new URL('../', import.meta.url));
const sourceMigrations = fileURLToPath(new URL('../migrations/', import.meta.url));
const publicationIntegration = fileURLToPath(new URL('./integration-0009-publication.mjs', import.meta.url));
const idempotencyOutboxIntegration = fileURLToPath(new URL('./integration-0009b-idempotency-outbox.mjs', import.meta.url));
const portalSecurityIntegration = fileURLToPath(new URL('./integration-0009-portal-security.mjs', import.meta.url));

async function runOracle(script, migrationsDir) {
  const environment = { ...process.env };
  delete environment.ROOMSCAN_TEST_MIGRATIONS_DIR;
  if (migrationsDir) {
    environment.ROOMSCAN_TEST_MIGRATIONS_DIR = migrationsDir;
  }
  return await execFileAsync(process.execPath, [script], {
    cwd: dbRoot,
    env: environment,
    maxBuffer: 4 * 1024 * 1024,
  });
}

async function expectGreen(label, script) {
  const { stdout } = await runOracle(script);
  assert.match(stdout, /status=pass/u, `${label} baseline did not pass`);
}

async function mutateAndProve({ label, script, needle, replacement, mutations, failure }) {
  const root = await mkdtemp(path.join(tmpdir(), `rss-0009-mutation-${label}-`));
  const migrationsDir = path.join(root, 'migrations');
  try {
    await cp(sourceMigrations, migrationsDir, { recursive: true });
    const migrationPath = path.join(migrationsDir, '0009_publication_portal.up.sql');
    const original = await readFile(migrationPath, 'utf8');
    let mutated = original;
    for (const edit of mutations ?? [{ needle, replacement }]) {
      const matches = mutated.split(edit.needle).length - 1;
      assert.equal(matches, 1, `${label} mutation target drifted or is no longer singular`);
      mutated = mutated.replace(edit.needle, edit.replacement);
    }
    await writeFile(migrationPath, mutated);
    await assert.rejects(
      () => runOracle(script, migrationsDir),
      (error) => {
        const output = `${error?.stdout ?? ''}\n${error?.stderr ?? ''}\n${error?.message ?? ''}`;
        return failure.test(output);
      },
      `${label} neutralization did not make its focused oracle fail`,
    );
    console.log(`MUTATION_0009_RED ${label}`);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
  // The working-tree migration is the restored guard. Re-run the same real
  // database oracle instead of treating source replacement as proof.
  await expectGreen(`${label} restored`, script);
  console.log(`MUTATION_0009_RESTORE_GREEN ${label}`);
}

await expectGreen('publication integration', publicationIntegration);
await expectGreen('targetless completion and bind integration', idempotencyOutboxIntegration);
await expectGreen('portal security integration', portalSecurityIntegration);

await mutateAndProve({
  label: 'source-binding',
  script: publicationIntegration,
  needle: `    OR revision_row.working_digest IS DISTINCT FROM requested_source_revision_digest
    OR revision_row.working_manifest_digest IS DISTINCT FROM requested_source_manifest_digest THEN`,
  replacement: `    OR false THEN`,
  failure: /allocation must bind the exact current source revision/u,
});

await mutateAndProve({
  label: 'approval-binding',
  script: publicationIntegration,
  needle: `    OR approval_row.approval_digest IS DISTINCT FROM allocation.approval_digest
    OR requested_source_bindings_digest IS DISTINCT FROM allocation.source_bindings_digest`,
  replacement: `    OR false
    OR requested_source_bindings_digest IS DISTINCT FROM allocation.source_bindings_digest`,
  failure: /finalization must fail closed when a persisted approval digest/u,
});

await mutateAndProve({
  label: 'revoked-session-generation',
  script: publicationIntegration,
  needle: `    OR link_row.state <> 'active'
    OR link_row.expires_at <= authoritative_time
    OR link_row.generation IS DISTINCT FROM session_row.link_generation`,
  replacement: `    OR false
    OR link_row.expires_at <= authoritative_time
    OR false`,
  failure: /(?:revoked active session must fail on next protected request|revocation between a successful exact-version storage reservation and final accounting must deny the same active session)/u,
});

await mutateAndProve({
  label: 'portal-snapshot-live-capabilities',
  script: publicationIntegration,
  needle: `  RETURN QUERY SELECT 'allowed'::text, snapshot_row.snapshot_id,
    snapshot_row.public_id, snapshot_row.publication_kind, snapshot_row.property_id,
    snapshot_row.presentation_digest, snapshot_row.presentation_bytes,
    context_row.ai_enabled, context_row.feedback_enabled;
END
$function$;`,
  replacement: `  RETURN QUERY SELECT 'allowed'::text, snapshot_row.snapshot_id,
    snapshot_row.public_id, snapshot_row.publication_kind, snapshot_row.property_id,
    snapshot_row.presentation_digest, snapshot_row.presentation_bytes,
    true, true;
END
$function$;`,
  failure: /the live portal snapshot projection must expose only the current link-scoped AI and feedback capabilities/u,
});

await mutateAndProve({
  label: 'professional-finalization-session-revoke',
  script: publicationIntegration,
  needle: `BEGIN
  PERFORM roomscan.publication_require_portal_v1();
  IF requested_session_hash IS NULL OR authoritative_time IS NULL
    OR octet_length(requested_session_hash) <> 32 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROFESSIONAL_PORTAL_SESSION';
  END IF;
  SELECT session.* INTO session_row
  FROM roomscan.professional_web_sessions AS session
  WHERE session.session_hash = requested_session_hash
  FOR SHARE;
  IF NOT FOUND OR session_row.state <> 'active'
    OR session_row.expires_at <= authoritative_time THEN`,
  replacement: `BEGIN
  PERFORM roomscan.publication_require_portal_v1();
  IF requested_session_hash IS NULL OR authoritative_time IS NULL
    OR octet_length(requested_session_hash) <> 32 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROFESSIONAL_PORTAL_SESSION';
  END IF;
  SELECT session.* INTO session_row
  FROM roomscan.professional_web_sessions AS session
  WHERE session.session_hash = requested_session_hash
  FOR SHARE;
  IF NOT FOUND
    OR session_row.expires_at <= authoritative_time THEN`,
  failure: /a professional-session revoke between asset authorization and finalization must deny emission/u,
});

await mutateAndProve({
  label: 'professional-exact-range',
  script: publicationIntegration,
  needle: `    IF reservation_row.professional_session_id IS DISTINCT FROM context_row.professional_session_id
      OR reservation_row.snapshot_id IS DISTINCT FROM asset_row.snapshot_id
      OR reservation_row.asset_id IS DISTINCT FROM asset_row.asset_id
      OR reservation_row.asset_object_version IS DISTINCT FROM asset_row.object_version
      OR reservation_row.byte_offset IS DISTINCT FROM requested_byte_offset
      OR reservation_row.byte_length IS DISTINCT FROM requested_byte_length THEN`,
  replacement: `    IF reservation_row.professional_session_id IS DISTINCT FROM context_row.professional_session_id
      OR reservation_row.snapshot_id IS DISTINCT FROM asset_row.snapshot_id
      OR reservation_row.asset_id IS DISTINCT FROM asset_row.asset_id
      OR reservation_row.asset_object_version IS DISTINCT FROM asset_row.object_version
      OR false
      OR false THEN`,
  failure: /a professional reservation digest must bind its exact requested range rather than permit a shifted replay/u,
});

await mutateAndProve({
  label: 'professional-exact-version',
  script: publicationIntegration,
  needle: `  IF NOT FOUND OR asset_row.object_version IS DISTINCT FROM requested_object_version
    OR requested_byte_length > asset_row.bytes
    OR requested_byte_offset > asset_row.bytes - requested_byte_length THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROFESSIONAL_PUBLICATION_ASSET_NOT_FOUND';
  END IF;`,
  replacement: `  IF NOT FOUND OR false
    OR requested_byte_length > asset_row.bytes
    OR requested_byte_offset > asset_row.bytes - requested_byte_length THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROFESSIONAL_PUBLICATION_ASSET_NOT_FOUND';
  END IF;`,
  failure: /professional finalization must require the active storage version that was reserved/u,
});

await mutateAndProve({
  label: 'professional-portal-quota',
  script: publicationIntegration,
  needle: `  IF NOT FOUND OR usage_row.used + usage_row.reserved + requested_byte_length > usage_row.limit_value THEN
    RAISE EXCEPTION USING ERRCODE = '42900', MESSAGE = 'PORTAL_QUOTA_EXCEEDED';
  END IF;
  UPDATE roomscan.quota_usage_v2 AS usage
  SET used = usage.used + requested_byte_length, updated_at = authoritative_time
  WHERE usage.workspace_id = context_row.workspace_id
    AND usage.metric = 'portal_bytes' AND usage.period_key = quota_period_key;
  quota_request_key := 'professional-publication-delivery:' || encode(requested_request_digest, 'hex');`,
  replacement: `  IF false THEN
    RAISE EXCEPTION USING ERRCODE = '42900', MESSAGE = 'PORTAL_QUOTA_EXCEEDED';
  END IF;
  UPDATE roomscan.quota_usage_v2 AS usage
  SET used = usage.used + requested_byte_length, updated_at = authoritative_time
  WHERE usage.workspace_id = context_row.workspace_id
    AND usage.metric = 'portal_bytes' AND usage.period_key = quota_period_key;
  quota_request_key := 'professional-publication-delivery:' || encode(requested_request_digest, 'hex');`,
  failure: /professional asset finalization must deny a range that exceeds the live portal-byte quota/u,
});

await mutateAndProve({
  label: 'targetless-api-completion',
  script: idempotencyOutboxIntegration,
  mutations: [{
    needle: `  SET state = 'validation_pending', updated_at = authoritative_time
  WHERE target.workspace_id = allocation.workspace_id`,
    replacement: `  SET state = 'validation_pending', quarantine_version = 'api-supplied-version',
      updated_at = authoritative_time
  WHERE target.workspace_id = allocation.workspace_id`,
  }, {
    needle: `    OR (state = 'validation_pending'
      AND quarantine_version IS NULL AND active_object_version IS NULL)`,
    replacement: `    OR (state = 'validation_pending'
      AND active_object_version IS NULL)`,
  }],
  failure: /completion replay must retain one pending job and no API-supplied object version/u,
});

await mutateAndProve({
  label: 'worker-live-quarantine-bind',
  script: idempotencyOutboxIntegration,
  needle: `  -- Recheck the same live epochs and immutable source/quota bindings that
  -- finalization will later require.  Claim-time success is never enough:
  -- a kill, source head change, or policy transition between S3 HeadObject and
  -- exact-version binding must leave the allocation unbound.
  PERFORM roomscan.publication_require_live_grant_v1(
    allocation.workspace_id, 'publication.create',
    allocation.hosted_global_version, allocation.hosted_workspace_version,
    allocation.publication_global_version, allocation.publication_workspace_version
  );`,
  replacement: `  -- Worker live publication-grant recheck deliberately neutralized by mutation harness.`,
  failure: /a publication kill committed after claim but before bind must deny version binding/u,
});

await mutateAndProve({
  label: 'link-expiry-intent-replay',
  script: publicationIntegration,
  needle: `      OR existing.expiry_intent IS DISTINCT FROM requested_expiry_intent
      OR (requested_expiry_intent = 'explicit'`,
  replacement: `      OR false
      OR (requested_expiry_intent = 'explicit'`,
  failure: /default and explicit expiry intent must remain distinct/u,
});

await mutateAndProve({
  label: 'link-replay-preserves-expiry',
  script: publicationIntegration,
  needle: `    RETURN QUERY SELECT 'existing'::text, existing.link_id, existing.public_id,
      existing.generation, existing.expires_at, existing.pin_salt IS NOT NULL;`,
  replacement: `    RETURN QUERY SELECT 'existing'::text, existing.link_id, existing.public_id,
      existing.generation, effective_expiry, existing.pin_salt IS NOT NULL;`,
  failure: /(?:an omitted-expiry retry must compare default intent|a late default-expiry replay must return the original immutable expiry)/u,
});

await mutateAndProve({
  label: 'feedback-v3-policy-owner',
  script: portalSecurityIntegration,
  needle: `ALTER FUNCTION roomscan.portal_request_feedback_verification_v3(
  bytea, timestamptz, bytea, bytea, bytea, text, bytea, bytea, bytea, bytea
) OWNER TO roomscan_policy;`,
  replacement: `ALTER FUNCTION roomscan.portal_request_feedback_verification_v3(
  bytea, timestamptz, bytea, bytea, bytea, text, bytea, bytea, bytea, bytea
) OWNER TO roomscan_owner;`,
  failure: /portal_request_feedback_verification_v3.*must run as the narrow policy owner/u,
});

await mutateAndProve({
  label: 'feedback-v3-portal-acl',
  script: portalSecurityIntegration,
  needle: `GRANT EXECUTE ON FUNCTION roomscan.portal_request_feedback_verification_v3(
  bytea, timestamptz, bytea, bytea, bytea, text, bytea, bytea, bytea, bytea
) TO roomscan_portal_runtime;`,
  replacement: `-- Feedback v3 portal grant deliberately neutralized by mutation harness.`,
  failure: /portal_request_feedback_verification_v3.*must be granted only to its approved Slice 6 runtime action/u,
});

await mutateAndProve({
  label: 'feedback-runtime-guard-acl',
  script: portalSecurityIntegration,
  needle: `  roomscan.publication_feedback_delivery_live_v2(uuid, text, timestamptz),
  roomscan.publication_require_feedback_delivery_runtime_v2()
  FROM PUBLIC, roomscan_api_runtime, roomscan_portal_runtime,`,
  replacement: `  roomscan.publication_feedback_delivery_live_v2(uuid, text, timestamptz)
  FROM PUBLIC, roomscan_api_runtime, roomscan_portal_runtime,`,
  failure: /publication_require_feedback_delivery_runtime_v2\(\).*internal guard/u,
});

await mutateAndProve({
  label: 'feedback-v3-live-validation',
  script: publicationIntegration,
  needle: `  IF NOT roomscan.publication_feedback_delivery_live_v2(
    delivery.workspace_id, delivery.delivery_id, checked_at_time
  ) THEN
    UPDATE roomscan.portal_feedback_delivery_outbox AS target
    SET state = 'cancelled', lease_id = NULL, lease_expires_at = NULL,`,
  replacement: `  IF false THEN
    UPDATE roomscan.portal_feedback_delivery_outbox AS target
    SET state = 'cancelled', lease_id = NULL, lease_expires_at = NULL,`,
  failure: /a kill committed after claim but before send must cancel the sealed delivery/u,
});

await mutateAndProve({
  label: 'feedback-v3-throttle',
  script: publicationIntegration,
  mutations: [{
    needle: `  ELSIF throttle.issued_count >= 3 THEN`,
    replacement: `  ELSIF throttle.issued_count >= 4 THEN`,
  }, {
    needle: `  issued_count integer NOT NULL CHECK (issued_count BETWEEN 1 AND 3),`,
    replacement: `  issued_count integer NOT NULL CHECK (issued_count BETWEEN 1 AND 4),`,
  }],
  failure: /the fourth feedback issue in one controlled fifteen-minute window must cool down/u,
});

await mutateAndProve({
  label: 'publication-kill-grant',
  script: publicationIntegration,
  needle: `  IF hosted_global_enabled IS DISTINCT FROM true
    OR publication_global_enabled IS DISTINCT FROM true
    OR hosted_workspace_enabled IS DISTINCT FROM true
    OR publication_workspace_enabled IS DISTINCT FROM true
    OR hosted_global_version IS DISTINCT FROM requested_hosted_global_version
    OR hosted_workspace_version IS DISTINCT FROM requested_hosted_workspace_version
    OR publication_global_version IS DISTINCT FROM requested_publication_global_version
    OR publication_workspace_version IS DISTINCT FROM requested_publication_workspace_version THEN`,
  replacement: `  IF false THEN`,
  failure: /a kill switch change during validation must deny immutable snapshot finalization/u,
});

await mutateAndProve({
  label: 'property-cas',
  script: publicationIntegration,
  needle: `    IF existing.version IS DISTINCT FROM requested_expected_version THEN`,
  replacement: `    IF false THEN`,
  failure: /a second session with a stale property version must fail closed/u,
});

await mutateAndProve({
  label: 'property-create-concurrency',
  script: idempotencyOutboxIntegration,
  needle: `    -- The advisory key is only a concurrency serializer; no caller-controlled
    -- tenant or principal identity is trusted outside the resolved context.
    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
      'publication-property-create:' || context_row.workspace_id::text || ':'
        || context_row.principal_id::text || ':'
        || pg_catalog.encode(requested_create_idempotency_digest, 'hex'),
      7621846213719043
    ));`,
  replacement: `    -- Property-create advisory serializer neutralized by mutation harness.`,
  failure: /(?:the overlapping property create must block on its own advisory serializer|duplicate key value violates unique constraint|two overlapping same-digest creates must converge)/u,
});

await mutateAndProve({
  label: 'editor-policy-scope',
  script: publicationIntegration,
  needle: `  IF requested_action IN ('publication.create', 'publication.update', 'publication.revoke')
    AND resolved_role = 'editor' AND editor_allowed IS DISTINCT FROM true THEN`,
  replacement: `  IF resolved_role = 'editor' AND editor_allowed IS DISTINCT FROM true THEN`,
  failure: /(?:EDITOR_PUBLISHING_DISABLED|an Editor app bearer with recent auth must curate while editor publishing is disabled)/u,
});

await mutateAndProve({
  label: 'root-project-identity',
  script: publicationIntegration,
  mutations: [{
    needle: `  -- The root revision must belong to the root hosted project, not merely the
  -- same workspace.  The reducer repeats this check so corrupted rows fail
  -- closed before a worker can make an immutable snapshot public.
  FOREIGN KEY (workspace_id, source_revision_id, project_id)
    REFERENCES roomscan.project_revisions(workspace_id, id, project_id) ON DELETE RESTRICT,`,
    replacement: `  -- root allocation composite FK neutralized by mutation harness`,
  }, {
    needle: `  FOREIGN KEY (workspace_id, source_revision_id, project_id)
    REFERENCES roomscan.project_revisions(workspace_id, id, project_id) ON DELETE RESTRICT,
  FOREIGN KEY (workspace_id, property_id)`,
    replacement: `  -- root snapshot composite FK neutralized by mutation harness
  FOREIGN KEY (workspace_id, property_id)`,
  }, {
    needle: `    AND revision.id = requested_source_revision_id
    AND revision.project_id = requested_project_id
    AND revision.public_id = requested_source_revision_public_id;`,
    replacement: `    AND revision.id = requested_source_revision_id
    AND revision.public_id = requested_source_revision_public_id;`,
  }, {
    needle: `  IF NOT FOUND
    OR project_row.head_revision_id IS DISTINCT FROM revision_row.id
    OR revision_row.branch_state IS DISTINCT FROM 'canonical'`,
    replacement: `  IF NOT FOUND
    OR false
    OR revision_row.branch_state IS DISTINCT FROM 'canonical'`,
  }, {
    needle: `  FROM roomscan.project_revisions AS revision
  WHERE revision.workspace_id = allocation.workspace_id
    AND revision.id = allocation.source_revision_id
    AND revision.project_id = allocation.project_id
    AND revision.public_id = allocation.source_revision_public_id;`,
    replacement: `  FROM roomscan.project_revisions AS revision
  WHERE revision.workspace_id = allocation.workspace_id
    AND revision.id = allocation.source_revision_id
    AND revision.public_id = allocation.source_revision_public_id;`,
  }],
  failure: /finalization must reject a root project that no longer owns the allocated source revision/u,
});

await mutateAndProve({
  label: 'source-public-identity',
  script: publicationIntegration,
  needle: `  IF NOT FOUND
    OR source_row.source_revision_id IS DISTINCT FROM allocation.source_revision_id
    OR source_row.source_revision_public_id IS DISTINCT FROM allocation.source_revision_public_id
    OR source_row.source_revision_digest IS DISTINCT FROM allocation.source_revision_digest`,
  replacement: `  IF NOT FOUND
    OR false
    OR false
    OR source_row.source_revision_digest IS DISTINCT FROM allocation.source_revision_digest`,
  failure: /finalization must compare the persisted source UUID and public revision ID to its allocation/u,
});

await mutateAndProve({
  label: 'approval-public-identity',
  script: publicationIntegration,
  needle: `    OR approval_row.source_revision_id IS DISTINCT FROM allocation.source_revision_id
    OR approval_row.source_revision_public_id IS DISTINCT FROM allocation.source_revision_public_id
    OR approval_row.source_revision_digest IS DISTINCT FROM allocation.source_revision_digest`,
  replacement: `    OR false
    OR false
    OR approval_row.source_revision_digest IS DISTINCT FROM allocation.source_revision_digest`,
  failure: /finalization must bind approval identity to the same exact immutable source revision/u,
});

await mutateAndProve({
  label: 'pin-snapshot-identity',
  script: publicationIntegration,
  needle: `  IF NOT FOUND OR session_row.state <> 'pin_required'
    OR session_row.expires_at <= authoritative_time OR link_row.state <> 'active'
    OR link_row.expires_at <= authoritative_time
    OR link_row.generation IS DISTINCT FROM session_row.link_generation
    OR link_row.snapshot_id IS DISTINCT FROM session_row.snapshot_id
    OR NOT EXISTS (`,
  replacement: `  IF NOT FOUND OR session_row.state <> 'pin_required'
    OR session_row.expires_at <= authoritative_time OR link_row.state <> 'active'
    OR link_row.expires_at <= authoritative_time
    OR link_row.generation IS DISTINCT FROM session_row.link_generation
    OR false
    OR NOT EXISTS (`,
  failure: /a PIN attempt must deny when its active link and portal session name different snapshots/u,
});

await mutateAndProve({
  label: 'rotation-session-revoke',
  script: publicationIntegration,
  needle: `  -- Rotation is an immediate session revocation event, not merely a future
  -- generation comparison.  The latter remains a defense in depth for any
  -- stale state that predates this reducer.
  UPDATE roomscan.portal_sessions AS session_row
  SET state = 'revoked', revoked_at = authoritative_time
  WHERE session_row.workspace_id = link_row.workspace_id
    AND session_row.link_id = link_row.link_id
    AND session_row.link_generation <= link_row.generation
    AND session_row.state IN ('active', 'pin_required');`,
  replacement: `  -- Session revocation deliberately neutralized by mutation harness.`,
  failure: /link rotation must atomically mark the prior active portal session revoked/u,
});

await mutateAndProve({
  label: 'concurrent-finalize-recheck',
  script: publicationIntegration,
  needle: `  -- A concurrent retry can pass the optimistic lookup above before the first
  -- worker inserts. Recheck after locking the allocation, before lease/state
  -- validation, so concurrent finalizers converge on one immutable snapshot.
  SELECT snapshot.* INTO existing_snapshot
  FROM roomscan.publication_snapshots AS snapshot
  WHERE snapshot.workspace_id = allocation.workspace_id
    AND snapshot.allocation_id = allocation.allocation_id;
  IF FOUND THEN
    RETURN QUERY SELECT 'existing'::text, existing_snapshot.snapshot_id,
      existing_snapshot.public_id;
    RETURN;
  END IF;`,
  replacement: `  -- Post-lock snapshot recheck deliberately neutralized by mutation harness.`,
  failure: /PUBLICATION_VALIDATION_LEASE_REQUIRED/u,
});

await mutateAndProve({
  label: 'finalize-flag-lock-barrier',
  script: publicationIntegration,
  needle: `  SELECT flag.enabled, flag.version INTO publication_global_enabled, publication_global_version
  FROM roomscan.global_operational_flags AS flag
  WHERE flag.flag_key = 'publication_enabled'
  FOR SHARE;`,
  replacement: `  SELECT flag.enabled, flag.version INTO publication_global_enabled, publication_global_version
  FROM roomscan.global_operational_flags AS flag
  WHERE flag.flag_key = 'publication_enabled';`,
  failure: /(?:the global publication kill must wait for the finalizer live-flag barrier|the finalizer must wait behind the uncommitted kill before it can decide the live grant)/u,
});

await mutateAndProve({
  label: 'finalize-source-lock-barrier',
  script: publicationIntegration,
  needle: `    PERFORM 1
    FROM roomscan.professional_projects AS project
    WHERE project.workspace_id = allocation.workspace_id
      AND project.project_id = locked_source_project_id
    FOR SHARE;`,
  replacement: `    PERFORM 1
    FROM roomscan.professional_projects AS project
    WHERE project.workspace_id = allocation.workspace_id
      AND project.project_id = locked_source_project_id
    FOR KEY SHARE;`,
  failure: /the Slice 5 secondary edit must wait for the finalizer source lock until immutable snapshot commit/u,
});

await mutateAndProve({
  label: 'pin-throttle',
  script: publicationIntegration,
  needle: `  new_failures := LEAST(throttle.failed_attempts + 1, 5);`,
  replacement: `  new_failures := 4;`,
  failure: /wrong PIN attempt 5 must enforce the bounded five-attempt throttle/u,
});

await mutateAndProve({
  label: 'forced-rls',
  script: portalSecurityIntegration,
  needle: `ALTER TABLE roomscan.publication_snapshots FORCE ROW LEVEL SECURITY;`,
  replacement: `-- FORCE ROW LEVEL SECURITY intentionally neutralized by mutation harness`,
  failure: /publication_snapshots must FORCE RLS/u,
});

await mutateAndProve({
  label: 'feedback-isolation',
  script: publicationIntegration,
  needle: `    AND candidate.session_id = requested_session_id
    AND candidate.workspace_id = requested_workspace_id
    AND candidate.link_id = requested_link_id
    AND candidate.link_generation = requested_link_generation
    AND candidate.snapshot_id = requested_snapshot_id`,
  replacement: `    AND true`,
  failure: /a verified feedback token must remain scoped to its exact portal link generation and session/u,
});

console.log('MUTATIONS_0009_PUBLICATION_SUMMARY source_binding=detected approval_binding=detected revoked_session_generation=detected portal_snapshot_live_capabilities=detected professional_finalization_session_revoke=detected professional_exact_range=detected professional_exact_version=detected professional_portal_quota=detected targetless_api_completion=detected worker_live_quarantine_bind=detected link_expiry_intent_replay=detected link_replay_preserves_expiry=detected feedback_v3_policy_owner=detected feedback_v3_portal_acl=detected feedback_runtime_guard_acl=detected feedback_v3_live_validation=detected feedback_v3_throttle=detected publication_kill_grant=detected property_cas=detected property_create_concurrency=detected editor_policy_scope=detected root_project_identity=detected source_public_identity=detected approval_public_identity=detected pin_snapshot_identity=detected rotation_session_revoke=detected concurrent_finalize_recheck=detected finalize_flag_lock_barrier=detected finalize_source_lock_barrier=detected pin_throttle=detected forced_rls=detected feedback_isolation=detected restored_controls=32 status=pass');
