-- Slice 5 immutable professional project synchronization.  This migration is
-- deliberately additive: it stages all untrusted bytes before a targetless
-- worker validates and promotes an immutable revision.  It never rewrites a
-- hosted head or deletes an immutable branch/object row.  The operational
-- 64 MiB ceiling below applies only to these new hosted-sync records; it does
-- not rewrite or invalidate historical local, backup, or guest packages.

-- A dedicated worker credential is a LOGIN role because the Data API binds a
-- managed secret to a real database principal.  It has no role memberships and
-- receives only the server-selected worker reducers below.
CREATE ROLE roomscan_project_sync_runtime
  LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
REVOKE roomscan_owner, roomscan_policy, roomscan_app FROM roomscan_project_sync_runtime;
GRANT USAGE ON SCHEMA roomscan TO roomscan_project_sync_runtime;

SET ROLE roomscan_owner;

CREATE TABLE roomscan.professional_projects (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE RESTRICT,
  project_id uuid NOT NULL,
  public_id text NOT NULL CHECK (
    public_id ~ '^prj_[A-Za-z0-9_-]{16,128}$'
  ),
  source_project_id text NOT NULL CHECK (
    length(source_project_id) BETWEEN 1 AND 128
    AND source_project_id ~ '^[A-Za-z0-9_-]+$'
  ),
  head_revision_id uuid,
  raw_archive_enabled boolean NOT NULL DEFAULT false,
  raw_review_digest bytea,
  raw_reviewed_at timestamptz,
  version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (workspace_id, project_id),
  UNIQUE (public_id),
  UNIQUE (workspace_id, public_id),
  UNIQUE (workspace_id, source_project_id),
  FOREIGN KEY (workspace_id, project_id)
    REFERENCES roomscan.projects(workspace_id, id) ON DELETE RESTRICT,
  CHECK (
    (raw_archive_enabled IS FALSE AND raw_review_digest IS NULL AND raw_reviewed_at IS NULL)
    OR (raw_archive_enabled IS TRUE AND octet_length(raw_review_digest) = 32
      AND raw_reviewed_at IS NOT NULL)
  )
);

CREATE TABLE roomscan.project_revisions (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE RESTRICT,
  id uuid NOT NULL,
  public_id text NOT NULL CHECK (
    public_id ~ '^rev_[A-Za-z0-9_-]{16,128}$'
  ),
  project_id uuid NOT NULL,
  parent_revision_id uuid,
  source_revision_id text NOT NULL CHECK (
    length(source_revision_id) BETWEEN 1 AND 128
    AND source_revision_id ~ '^[A-Za-z0-9_-]+$'
  ),
  branch_state text NOT NULL CHECK (branch_state IN ('canonical', 'stale')),
  working_object_key text NOT NULL CHECK (
    working_object_key ~ '^professional-sync/active/working/rev_[A-Za-z0-9_-]{16,128}[.]zip$'
  ),
  working_object_version text NOT NULL CHECK (
    octet_length(working_object_version) BETWEEN 1 AND 1024
    AND working_object_version !~ '[[:cntrl:]]'
  ),
  working_digest bytea NOT NULL CHECK (octet_length(working_digest) = 32),
  working_bytes bigint NOT NULL CHECK (working_bytes > 0 AND working_bytes <= 67108864),
  working_manifest_digest bytea NOT NULL CHECK (octet_length(working_manifest_digest) = 32),
  created_at timestamptz NOT NULL,
  PRIMARY KEY (workspace_id, id),
  UNIQUE (public_id),
  UNIQUE (workspace_id, public_id),
  UNIQUE (workspace_id, project_id, source_revision_id),
  FOREIGN KEY (workspace_id, project_id)
    REFERENCES roomscan.professional_projects(workspace_id, project_id) ON DELETE RESTRICT,
  FOREIGN KEY (workspace_id, parent_revision_id)
    REFERENCES roomscan.project_revisions(workspace_id, id) ON DELETE RESTRICT,
  CHECK (working_object_key = 'professional-sync/active/working/' || public_id || '.zip')
);

ALTER TABLE roomscan.professional_projects
  ADD CONSTRAINT professional_projects_head_revision_fk
  FOREIGN KEY (workspace_id, head_revision_id)
  REFERENCES roomscan.project_revisions(workspace_id, id) ON DELETE RESTRICT;

CREATE TABLE roomscan.project_uploads (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE RESTRICT,
  id uuid NOT NULL,
  public_id text NOT NULL CHECK (
    public_id ~ '^upl_[A-Za-z0-9_-]{16,128}$'
  ),
  project_id uuid,
  project_public_id text NOT NULL CHECK (
    project_public_id ~ '^prj_[A-Za-z0-9_-]{16,128}$'
  ),
  source_project_id text CHECK (
    source_project_id IS NULL OR (
      length(source_project_id) BETWEEN 1 AND 128
      AND source_project_id ~ '^[A-Za-z0-9_-]+$'
    )
  ),
  operation text NOT NULL CHECK (
    operation IN ('create_initial_head', 'append_revision', 'attach_raw_archive')
  ),
  idempotency_digest bytea NOT NULL CHECK (octet_length(idempotency_digest) = 32),
  proposed_revision_id text CHECK (
    proposed_revision_id IS NULL OR (
      length(proposed_revision_id) BETWEEN 1 AND 128
      AND proposed_revision_id ~ '^[A-Za-z0-9_-]+$'
    )
  ),
  proposed_revision_public_id text CHECK (
    proposed_revision_public_id IS NULL OR (
      proposed_revision_public_id ~ '^rev_[A-Za-z0-9_-]{16,128}$'
    )
  ),
  target_revision_id uuid,
  expected_head_revision_id uuid,
  expected_head_source_revision_id text CHECK (
    expected_head_source_revision_id IS NULL OR (
      length(expected_head_source_revision_id) BETWEEN 1 AND 128
      AND expected_head_source_revision_id ~ '^[A-Za-z0-9_-]+$'
    )
  ),
  working_manifest_digest bytea CHECK (
    working_manifest_digest IS NULL OR octet_length(working_manifest_digest) = 32
  ),
  working_digest bytea CHECK (
    working_digest IS NULL OR octet_length(working_digest) = 32
  ),
  working_bytes bigint CHECK (working_bytes IS NULL OR (working_bytes > 0 AND working_bytes <= 67108864)),
  raw_manifest_digest bytea CHECK (
    raw_manifest_digest IS NULL OR octet_length(raw_manifest_digest) = 32
  ),
  raw_digest bytea CHECK (
    raw_digest IS NULL OR octet_length(raw_digest) = 32
  ),
  raw_bytes bigint CHECK (raw_bytes IS NULL OR (raw_bytes > 0 AND raw_bytes <= 67108864)),
  raw_review_digest bytea CHECK (
    raw_review_digest IS NULL OR octet_length(raw_review_digest) = 32
  ),
  state text NOT NULL DEFAULT 'allocated' CHECK (
    state IN ('allocated', 'validation_pending', 'validating', 'canonical', 'stale', 'attached', 'rejected')
  ),
  quarantine_key text NOT NULL CHECK (
    quarantine_key ~ '^professional-sync/quarantine/(working|raw)/upl_[A-Za-z0-9_-]{16,128}[.]zip$'
  ),
  quarantine_version text CHECK (
    quarantine_version IS NULL OR (
      octet_length(quarantine_version) BETWEEN 1 AND 1024
      AND quarantine_version !~ '[[:cntrl:]]'
    )
  ),
  active_object_key text NOT NULL CHECK (
    active_object_key ~ '^professional-sync/active/(working|raw)/(rev_|upl_)[A-Za-z0-9_-]{16,128}[.]zip$'
  ),
  active_object_version text CHECK (
    active_object_version IS NULL OR (
      octet_length(active_object_version) BETWEEN 1 AND 1024
      AND active_object_version !~ '[[:cntrl:]]'
    )
  ),
  lease_id text CHECK (
    lease_id IS NULL OR (
      lease_id ~ '^wkl_[A-Za-z0-9_-]{16,128}$'
    )
  ),
  lease_expires_at timestamptz,
  validation_attempts integer NOT NULL DEFAULT 0 CHECK (validation_attempts >= 0),
  rejection_code text CHECK (
    rejection_code IS NULL OR rejection_code IN (
      'allocation_expired', 'invalid_archive', 'provider_missing', 'provider_mismatch', 'duplicate_revision'
    )
  ),
  allocation_expires_at timestamptz NOT NULL,
  quota_policy_version bigint NOT NULL CHECK (quota_policy_version > 0),
  hosted_global_version bigint NOT NULL CHECK (hosted_global_version > 0),
  hosted_workspace_version bigint NOT NULL CHECK (hosted_workspace_version > 0),
  created_by_principal_id uuid NOT NULL REFERENCES roomscan.principals(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  PRIMARY KEY (workspace_id, id),
  UNIQUE (public_id),
  UNIQUE (workspace_id, public_id),
  UNIQUE (workspace_id, created_by_principal_id, operation, idempotency_digest),
  FOREIGN KEY (workspace_id, project_id)
    REFERENCES roomscan.professional_projects(workspace_id, project_id) ON DELETE RESTRICT,
  FOREIGN KEY (workspace_id, expected_head_revision_id)
    REFERENCES roomscan.project_revisions(workspace_id, id) ON DELETE RESTRICT,
  CHECK (created_at < allocation_expires_at),
  CHECK (
    (operation = 'create_initial_head'
      AND source_project_id IS NOT NULL
      AND (project_id IS NULL OR state IN ('canonical', 'stale'))
      AND proposed_revision_id IS NOT NULL
      AND proposed_revision_public_id IS NOT NULL
      AND target_revision_id IS NOT NULL
      AND expected_head_revision_id IS NULL
      AND expected_head_source_revision_id IS NULL
      AND working_manifest_digest IS NOT NULL
      AND working_digest IS NOT NULL
      AND working_bytes IS NOT NULL
      AND raw_manifest_digest IS NULL
      AND raw_digest IS NULL
      AND raw_bytes IS NULL
      AND raw_review_digest IS NULL
      AND quarantine_key = 'professional-sync/quarantine/working/' || public_id || '.zip'
      AND active_object_key = 'professional-sync/active/working/' || proposed_revision_public_id || '.zip')
    OR (operation = 'append_revision'
      AND source_project_id IS NULL
      AND project_id IS NOT NULL
      AND proposed_revision_id IS NOT NULL
      AND proposed_revision_public_id IS NOT NULL
      AND target_revision_id IS NOT NULL
      AND expected_head_revision_id IS NOT NULL
      AND expected_head_source_revision_id IS NOT NULL
      AND working_manifest_digest IS NOT NULL
      AND working_digest IS NOT NULL
      AND working_bytes IS NOT NULL
      AND raw_manifest_digest IS NULL
      AND raw_digest IS NULL
      AND raw_bytes IS NULL
      AND raw_review_digest IS NULL
      AND quarantine_key = 'professional-sync/quarantine/working/' || public_id || '.zip'
      AND active_object_key = 'professional-sync/active/working/' || proposed_revision_public_id || '.zip')
    OR (operation = 'attach_raw_archive'
      AND source_project_id IS NULL
      AND project_id IS NOT NULL
      AND proposed_revision_id IS NULL
      AND proposed_revision_public_id IS NULL
      AND target_revision_id IS NOT NULL
      AND expected_head_revision_id IS NULL
      AND expected_head_source_revision_id IS NULL
      AND working_manifest_digest IS NULL
      AND working_digest IS NULL
      AND working_bytes IS NULL
      AND raw_manifest_digest IS NOT NULL
      AND raw_digest IS NOT NULL
      AND raw_bytes IS NOT NULL
      AND raw_review_digest IS NOT NULL
      AND quarantine_key = 'professional-sync/quarantine/raw/' || public_id || '.zip'
      AND active_object_key = 'professional-sync/active/raw/' || public_id || '.zip')
  ),
  CHECK (
    (state = 'allocated'
      AND lease_id IS NULL AND lease_expires_at IS NULL
      AND quarantine_version IS NULL AND active_object_version IS NULL
      AND rejection_code IS NULL)
    OR (state = 'validation_pending'
      AND lease_id IS NULL AND lease_expires_at IS NULL
      AND quarantine_version IS NULL AND active_object_version IS NULL
      AND rejection_code IS NULL)
    OR (state = 'validating'
      AND lease_id IS NOT NULL AND lease_expires_at IS NOT NULL
      AND quarantine_version IS NULL AND active_object_version IS NULL
      AND rejection_code IS NULL)
    OR (state IN ('canonical', 'stale', 'attached')
      AND lease_id IS NULL AND lease_expires_at IS NULL
      AND quarantine_version IS NOT NULL AND active_object_version IS NOT NULL
      AND rejection_code IS NULL)
    OR (state = 'rejected'
      AND lease_id IS NULL AND lease_expires_at IS NULL
      AND quarantine_version IS NULL AND active_object_version IS NULL
      AND rejection_code IS NOT NULL)
  ),
  CHECK (
    operation <> 'create_initial_head'
    OR state IN ('allocated', 'validation_pending', 'validating', 'rejected')
    OR project_id IS NOT NULL
  )
);

CREATE UNIQUE INDEX project_uploads_initial_source_active_once
  ON roomscan.project_uploads (workspace_id, source_project_id)
  WHERE operation = 'create_initial_head' AND state <> 'rejected';
CREATE UNIQUE INDEX project_uploads_source_revision_active_once
  ON roomscan.project_uploads (workspace_id, project_id, proposed_revision_id)
  WHERE operation IN ('create_initial_head', 'append_revision') AND state <> 'rejected';
CREATE UNIQUE INDEX project_uploads_raw_target_nonterminal_once
  ON roomscan.project_uploads (workspace_id, target_revision_id)
  WHERE operation = 'attach_raw_archive'
    AND state IN ('allocated', 'validation_pending', 'validating');
CREATE INDEX project_uploads_validation_ready
  ON roomscan.project_uploads (created_at, id)
  WHERE state = 'validation_pending';
CREATE INDEX project_uploads_validation_lease_reclaim
  ON roomscan.project_uploads (lease_expires_at, created_at, id)
  WHERE state = 'validating';
CREATE INDEX project_uploads_allocated_expiry
  ON roomscan.project_uploads (allocation_expires_at, created_at, id)
  WHERE state = 'allocated';
CREATE INDEX project_revisions_project_branch
  ON roomscan.project_revisions (workspace_id, project_id, branch_state, created_at);

CREATE TABLE roomscan.project_raw_archives (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE RESTRICT,
  revision_id uuid NOT NULL,
  object_key text NOT NULL CHECK (
    object_key ~ '^professional-sync/active/raw/upl_[A-Za-z0-9_-]{16,128}[.]zip$'
  ),
  object_version text NOT NULL CHECK (
    octet_length(object_version) BETWEEN 1 AND 1024
    AND object_version !~ '[[:cntrl:]]'
  ),
  manifest_digest bytea NOT NULL CHECK (octet_length(manifest_digest) = 32),
  archive_digest bytea NOT NULL CHECK (octet_length(archive_digest) = 32),
  archive_bytes bigint NOT NULL CHECK (archive_bytes > 0 AND archive_bytes <= 67108864),
  review_digest bytea NOT NULL CHECK (octet_length(review_digest) = 32),
  created_at timestamptz NOT NULL,
  PRIMARY KEY (workspace_id, revision_id),
  UNIQUE (object_key),
  FOREIGN KEY (workspace_id, revision_id)
    REFERENCES roomscan.project_revisions(workspace_id, id) ON DELETE RESTRICT
);

CREATE TABLE roomscan.project_edit_leases (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE RESTRICT,
  project_id uuid NOT NULL,
  holder_principal_id uuid NOT NULL REFERENCES roomscan.principals(id) ON DELETE RESTRICT,
  holder_device_digest bytea NOT NULL CHECK (octet_length(holder_device_digest) = 32),
  request_digest bytea NOT NULL CHECK (octet_length(request_digest) = 32),
  token_digest bytea NOT NULL CHECK (octet_length(token_digest) = 32),
  generation bigint NOT NULL CHECK (generation > 0),
  expires_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  PRIMARY KEY (workspace_id, project_id),
  FOREIGN KEY (workspace_id, project_id)
    REFERENCES roomscan.professional_projects(workspace_id, project_id) ON DELETE RESTRICT,
  UNIQUE (workspace_id, project_id, token_digest)
);
CREATE INDEX project_edit_leases_expiry ON roomscan.project_edit_leases (expires_at);

ALTER TABLE roomscan.professional_projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.professional_projects FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.project_uploads ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.project_uploads FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.project_revisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.project_revisions FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.project_raw_archives ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.project_raw_archives FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.project_edit_leases ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.project_edit_leases FORCE ROW LEVEL SECURITY;

CREATE POLICY professional_projects_tenant_isolation ON roomscan.professional_projects
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));
CREATE POLICY project_uploads_tenant_isolation ON roomscan.project_uploads
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));
CREATE POLICY project_revisions_tenant_isolation ON roomscan.project_revisions
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));
CREATE POLICY project_raw_archives_tenant_isolation ON roomscan.project_raw_archives
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));
CREATE POLICY project_edit_leases_tenant_isolation ON roomscan.project_edit_leases
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));

-- Add the one Slice 5 configuration action without weakening the existing
-- literal-true, versioned hosted-operation grant predicate.
-- The prior migration deliberately assigned this routine to roomscan_policy,
-- so leave roomscan_owner before replacing it; the migration executor is the
-- superuser/operator that owns the staged upgrade transaction.
RESET ROLE;
CREATE OR REPLACE FUNCTION roomscan.hosted_mutation_grant_matches(
  target_workspace_id uuid,
  requested_action text,
  hosted_global_version bigint,
  hosted_workspace_version bigint,
  publication_global_version bigint,
  publication_workspace_version bigint
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
  SELECT target_workspace_id IS NOT NULL
    AND requested_action IS NOT NULL
    AND hosted_global_version IS NOT NULL
    AND hosted_workspace_version IS NOT NULL
    AND requested_action IN (
      'member.invite.viewer', 'member.invite.editor', 'member.invite.admin',
      'member.revoke.viewer', 'member.revoke.editor',
      'member.change.viewer', 'member.change.editor', 'member.change.admin',
      'member.change.owner', 'member.remove.viewer', 'member.remove.editor',
      'member.remove.admin', 'member.remove.owner', 'member.add.owner',
      'project.create', 'project.revise', 'raw_archive.configure', 'raw_archive.allocate',
      'publication.create', 'publication.update', 'publication.revoke',
      'system.quota_policy.change', 'system.stripe.reconcile'
    )
    AND EXISTS (
      SELECT 1 FROM roomscan.global_operational_flags AS global_flag
      WHERE global_flag.flag_key = 'hosted_operations_enabled'
        AND global_flag.enabled IS TRUE
        AND global_flag.version = hosted_global_version
    )
    AND EXISTS (
      SELECT 1 FROM roomscan.workspace_operational_flags AS workspace_flag
      WHERE workspace_flag.workspace_id = target_workspace_id
        AND workspace_flag.flag_key = 'hosted_operations_enabled'
        AND workspace_flag.enabled IS TRUE
        AND workspace_flag.version = hosted_workspace_version
    )
    AND CASE WHEN requested_action IN (
      'publication.create', 'publication.update', 'publication.revoke'
    ) THEN publication_global_version IS NOT NULL
      AND publication_workspace_version IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM roomscan.global_operational_flags AS global_flag
        WHERE global_flag.flag_key = 'publication_enabled'
          AND global_flag.enabled IS TRUE
          AND global_flag.version = publication_global_version
      )
      AND EXISTS (
        SELECT 1 FROM roomscan.workspace_operational_flags AS workspace_flag
        WHERE workspace_flag.workspace_id = target_workspace_id
          AND workspace_flag.flag_key = 'publication_enabled'
          AND workspace_flag.enabled IS TRUE
          AND workspace_flag.version = publication_workspace_version
      )
    ELSE publication_global_version IS NULL
      AND publication_workspace_version IS NULL
    END
$function$;

SET ROLE roomscan_owner;

-- Internal helpers below all use policy-owned SECURITY DEFINER routines with a
-- fixed search path.  They are never granted to a LOGIN role directly.
CREATE FUNCTION roomscan.project_sync_resolve_access_v1(
  access_token_hash bytea,
  authoritative_time timestamptz,
  allowed_roles text[],
  recent_authentication_required boolean
)
RETURNS TABLE (
  principal_id uuid,
  workspace_id uuid,
  role text,
  authorization_version bigint,
  recent_authentication boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
BEGIN
  SELECT * INTO context_row
  FROM roomscan.resolve_access_context(access_token_hash, authoritative_time);
  IF NOT FOUND OR context_row.principal_id IS NULL OR context_row.workspace_id IS NULL
    OR context_row.role IS NULL OR context_row.role <> ALL(allowed_roles)
    OR (recent_authentication_required IS TRUE AND context_row.recent_authentication IS DISTINCT FROM true) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROJECT_SYNC_AUTHORIZATION_REQUIRED';
  END IF;
  RETURN QUERY SELECT context_row.principal_id, context_row.workspace_id,
    context_row.role, context_row.authorization_version, context_row.recent_authentication;
END
$function$;

CREATE FUNCTION roomscan.project_sync_require_grant_v1(
  requested_workspace_id uuid,
  requested_action text,
  requested_global_version bigint,
  requested_workspace_version bigint
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  IF requested_workspace_id IS NULL OR requested_action IS NULL
    OR requested_global_version IS NULL OR requested_workspace_version IS NULL
    OR requested_global_version < 1 OR requested_workspace_version < 1 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROJECT_SYNC_GRANT';
  END IF;
  IF NOT roomscan.hosted_mutation_grant_matches(
    requested_workspace_id, requested_action, requested_global_version,
    requested_workspace_version, NULL, NULL
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'HOSTED_GRANT_REJECTED';
  END IF;
END
$function$;

CREATE FUNCTION roomscan.project_sync_quota_key_v1(
  upload_public_id text,
  suffix text
)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $function$
  SELECT 'project-sync:' || upload_public_id || ':' || suffix
$function$;

CREATE FUNCTION roomscan.project_sync_append_audit_v1(
  requested_workspace_id uuid,
  requested_actor_principal_id uuid,
  requested_action text,
  requested_subject_id text,
  occurred_at_time timestamptz
)
RETURNS bigint
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE next_value bigint; max_existing bigint;
BEGIN
  IF requested_workspace_id IS NULL OR requested_actor_principal_id IS NULL
    OR requested_action IS NULL OR requested_subject_id IS NULL OR occurred_at_time IS NULL
    OR requested_action NOT IN (
      'project_sync.migration_allocated', 'project_sync.revision_allocated',
      'project_sync.raw_allocated', 'project_sync.upload_completed',
      'project_sync.upload_canonical', 'project_sync.upload_stale',
      'project_sync.raw_attached', 'project_sync.upload_rejected',
      'project_sync.raw_configured', 'project_sync.lease_acquired',
      'project_sync.lease_released'
    )
    OR (
      requested_action IN (
        'project_sync.raw_configured', 'project_sync.lease_acquired',
        'project_sync.lease_released'
      ) AND requested_subject_id !~ '^prj_[A-Za-z0-9_-]{16,128}$'
    )
    OR (
      requested_action NOT IN (
        'project_sync.raw_configured', 'project_sync.lease_acquired',
        'project_sync.lease_released'
      ) AND requested_subject_id !~ '^upl_[A-Za-z0-9_-]{16,128}$'
    ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROJECT_SYNC_AUDIT';
  END IF;
  SELECT state.next_sequence INTO next_value
  FROM roomscan.audit_states AS state
  WHERE state.workspace_id = requested_workspace_id FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO roomscan.audit_states (workspace_id, next_sequence, updated_at)
    VALUES (requested_workspace_id, 1, occurred_at_time);
    next_value := 1;
  END IF;
  SELECT COALESCE(max(event.sequence), 0) INTO max_existing
  FROM roomscan.audit_events AS event
  WHERE event.workspace_id = requested_workspace_id;
  next_value := GREATEST(next_value, max_existing + 1);
  UPDATE roomscan.audit_states AS state
  SET next_sequence = next_value + 1, updated_at = occurred_at_time
  WHERE state.workspace_id = requested_workspace_id;
  INSERT INTO roomscan.audit_events (
    workspace_id, sequence, event_id, actor_principal_id, action,
    subject_kind, subject_id, authorization_version, occurred_at
  ) VALUES (
    requested_workspace_id, next_value,
    'aud_ps_' || replace(gen_random_uuid()::text, '-', ''), requested_actor_principal_id,
    requested_action,
    CASE WHEN requested_subject_id LIKE 'prj_%' THEN 'project_sync.project'
      ELSE 'project_sync.upload' END,
    requested_subject_id, NULL, occurred_at_time
  );
  RETURN next_value;
END
$function$;

CREATE FUNCTION roomscan.project_sync_release_quota_v1(
  requested_workspace_id uuid,
  requested_upload_public_id text,
  requested_suffix text,
  requested_quota_amount bigint,
  requested_reason text,
  authoritative_time timestamptz
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE reservation roomscan.quota_reservations_v2%ROWTYPE;
DECLARE ledger_action text;
BEGIN
  IF requested_workspace_id IS NULL OR requested_upload_public_id IS NULL
    OR requested_suffix NOT IN ('project-count', 'working', 'raw')
    OR requested_quota_amount IS NULL OR requested_quota_amount <= 0
    OR requested_reason NOT IN ('expired', 'rejected') OR authoritative_time IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROJECT_SYNC_WORKER_QUOTA_RELEASE';
  END IF;
  PERFORM roomscan.project_sync_require_worker_v1();
  SELECT * INTO reservation
  FROM roomscan.quota_reservations_v2 AS candidate
  WHERE candidate.workspace_id = requested_workspace_id
    AND candidate.period_key = 'roomscan-period-v1:lifetime'
    AND candidate.idempotency_key = roomscan.project_sync_quota_key_v1(requested_upload_public_id, requested_suffix)
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROJECT_SYNC_QUOTA_RESERVATION_NOT_FOUND';
  END IF;
  IF reservation.requested_amount IS DISTINCT FROM requested_quota_amount
    OR reservation.resource_kind IS DISTINCT FROM 'project_sync_upload'
    OR reservation.resource_id IS DISTINCT FROM requested_upload_public_id THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROJECT_SYNC_QUOTA_BINDING_MISMATCH';
  END IF;
  IF reservation.state = 'released' THEN
    RETURN;
  END IF;
  IF reservation.state = 'finalized' THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROJECT_SYNC_QUOTA_ALREADY_FINALIZED';
  END IF;
  UPDATE roomscan.quota_usage_v2 AS usage
  SET reserved = usage.reserved - reservation.requested_amount,
      updated_at = authoritative_time
  WHERE usage.workspace_id = requested_workspace_id
    AND usage.metric = reservation.metric
    AND usage.period_key = reservation.period_key;
  ledger_action := CASE WHEN requested_reason = 'expired' THEN 'expire' ELSE 'release' END;
  UPDATE roomscan.quota_reservations_v2 AS target
  SET state = 'released', released_at = authoritative_time,
      release_reason = CASE WHEN requested_reason = 'expired' THEN 'expired' ELSE 'released' END
  WHERE target.workspace_id = requested_workspace_id
    AND target.period_key = reservation.period_key
    AND target.idempotency_key = reservation.idempotency_key;
  INSERT INTO roomscan.quota_ledger_v2 (
    workspace_id, period_key, idempotency_key, action, metric,
    delta_used, delta_reserved, policy_version, recorded_at
  ) VALUES (
    requested_workspace_id, reservation.period_key, reservation.idempotency_key,
    ledger_action, reservation.metric, 0, -reservation.requested_amount,
    reservation.policy_version, authoritative_time
  );
END
$function$;

CREATE FUNCTION roomscan.project_sync_finalize_quota_v1(
  requested_workspace_id uuid,
  requested_upload_public_id text,
  requested_suffix text,
  requested_quota_amount bigint,
  authoritative_time timestamptz
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE reservation roomscan.quota_reservations_v2%ROWTYPE;
BEGIN
  IF requested_workspace_id IS NULL OR requested_upload_public_id IS NULL
    OR requested_suffix NOT IN ('project-count', 'working', 'raw')
    OR requested_quota_amount IS NULL OR requested_quota_amount <= 0 OR authoritative_time IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROJECT_SYNC_WORKER_QUOTA_FINALIZE';
  END IF;
  PERFORM roomscan.project_sync_require_worker_v1();
  SELECT * INTO reservation
  FROM roomscan.quota_reservations_v2 AS candidate
  WHERE candidate.workspace_id = requested_workspace_id
    AND candidate.period_key = 'roomscan-period-v1:lifetime'
    AND candidate.idempotency_key = roomscan.project_sync_quota_key_v1(requested_upload_public_id, requested_suffix)
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROJECT_SYNC_QUOTA_RESERVATION_NOT_FOUND';
  END IF;
  IF reservation.requested_amount IS DISTINCT FROM requested_quota_amount
    OR reservation.resource_kind IS DISTINCT FROM 'project_sync_upload'
    OR reservation.resource_id IS DISTINCT FROM requested_upload_public_id THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROJECT_SYNC_QUOTA_BINDING_MISMATCH';
  END IF;
  IF reservation.state = 'finalized' THEN
    IF reservation.finalized_amount IS DISTINCT FROM requested_quota_amount THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROJECT_SYNC_QUOTA_FINALIZATION_REUSED';
    END IF;
    RETURN;
  END IF;
  IF reservation.state = 'released' THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROJECT_SYNC_QUOTA_RELEASED';
  END IF;
  UPDATE roomscan.quota_usage_v2 AS usage
  SET used = usage.used + requested_quota_amount,
      reserved = usage.reserved - reservation.requested_amount,
      updated_at = authoritative_time
  WHERE usage.workspace_id = requested_workspace_id
    AND usage.metric = reservation.metric
    AND usage.period_key = reservation.period_key;
  UPDATE roomscan.quota_reservations_v2 AS target
  SET state = 'finalized', finalized_amount = requested_quota_amount,
      finalized_at = authoritative_time
  WHERE target.workspace_id = requested_workspace_id
    AND target.period_key = reservation.period_key
    AND target.idempotency_key = reservation.idempotency_key;
  INSERT INTO roomscan.quota_ledger_v2 (
    workspace_id, period_key, idempotency_key, action, metric,
    delta_used, delta_reserved, policy_version, recorded_at
  ) VALUES (
    requested_workspace_id, reservation.period_key, reservation.idempotency_key,
    'finalize', reservation.metric, requested_quota_amount, -reservation.requested_amount,
    reservation.policy_version, authoritative_time
  );
END
$function$;

CREATE FUNCTION roomscan.project_sync_release_upload_quotas_v1(
  upload_row roomscan.project_uploads,
  requested_reason text,
  authoritative_time timestamptz
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  IF upload_row.operation = 'create_initial_head' THEN
    PERFORM roomscan.project_sync_release_quota_v1(
      upload_row.workspace_id, upload_row.public_id, 'project-count', 1, requested_reason, authoritative_time
    );
    PERFORM roomscan.project_sync_release_quota_v1(
      upload_row.workspace_id, upload_row.public_id, 'working', upload_row.working_bytes, requested_reason, authoritative_time
    );
  ELSIF upload_row.operation = 'append_revision' THEN
    PERFORM roomscan.project_sync_release_quota_v1(
      upload_row.workspace_id, upload_row.public_id, 'working', upload_row.working_bytes, requested_reason, authoritative_time
    );
  ELSIF upload_row.operation = 'attach_raw_archive' THEN
    PERFORM roomscan.project_sync_release_quota_v1(
      upload_row.workspace_id, upload_row.public_id, 'raw', upload_row.raw_bytes, requested_reason, authoritative_time
    );
  ELSE
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROJECT_SYNC_UNKNOWN_OPERATION';
  END IF;
END
$function$;

CREATE FUNCTION roomscan.project_sync_finalize_upload_quotas_v1(
  upload_row roomscan.project_uploads,
  authoritative_time timestamptz
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  IF upload_row.operation = 'create_initial_head' THEN
    PERFORM roomscan.project_sync_finalize_quota_v1(
      upload_row.workspace_id, upload_row.public_id, 'project-count', 1, authoritative_time
    );
    PERFORM roomscan.project_sync_finalize_quota_v1(
      upload_row.workspace_id, upload_row.public_id, 'working', upload_row.working_bytes, authoritative_time
    );
  ELSIF upload_row.operation = 'append_revision' THEN
    PERFORM roomscan.project_sync_finalize_quota_v1(
      upload_row.workspace_id, upload_row.public_id, 'working', upload_row.working_bytes, authoritative_time
    );
  ELSIF upload_row.operation = 'attach_raw_archive' THEN
    PERFORM roomscan.project_sync_finalize_quota_v1(
      upload_row.workspace_id, upload_row.public_id, 'raw', upload_row.raw_bytes, authoritative_time
    );
  ELSE
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROJECT_SYNC_UNKNOWN_OPERATION';
  END IF;
END
$function$;

CREATE FUNCTION roomscan.project_sync_current_head_public_id_v1(
  requested_workspace_id uuid,
  requested_project_id uuid
)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
  SELECT revision.public_id
  FROM roomscan.professional_projects AS project
  LEFT JOIN roomscan.project_revisions AS revision
    ON revision.workspace_id = project.workspace_id
   AND revision.id = project.head_revision_id
  WHERE project.workspace_id = requested_workspace_id
    AND project.project_id = requested_project_id
$function$;

CREATE FUNCTION roomscan.allocate_project_migration_v1(
  access_token_hash bytea,
  authoritative_time timestamptz,
  requested_source_project_id text,
  requested_proposed_revision_id text,
  requested_working_manifest_digest bytea,
  requested_working_digest bytea,
  requested_working_bytes bigint,
  requested_idempotency_digest bytea,
  requested_policy_version bigint,
  requested_global_version bigint,
  requested_workspace_version bigint
)
RETURNS TABLE (
  status text,
  project_public_id text,
  upload_public_id text,
  candidate_revision_public_id text,
  working_manifest_digest bytea,
  working_digest bytea,
  working_bytes bigint,
  allocation_expires_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE existing roomscan.project_uploads%ROWTYPE;
DECLARE created_upload_id uuid := gen_random_uuid();
DECLARE created_project_public_id text := 'prj_' || replace(gen_random_uuid()::text, '-', '');
DECLARE created_upload_public_id text := 'upl_' || replace(gen_random_uuid()::text, '-', '');
DECLARE created_revision_public_id text := 'rev_' || replace(gen_random_uuid()::text, '-', '');
DECLARE created_revision_id uuid := gen_random_uuid();
DECLARE expires_at_time timestamptz;
BEGIN
  IF access_token_hash IS NULL OR authoritative_time IS NULL
    OR requested_source_project_id IS NULL OR requested_proposed_revision_id IS NULL
    OR requested_working_manifest_digest IS NULL OR requested_working_digest IS NULL
    OR requested_working_bytes IS NULL OR requested_idempotency_digest IS NULL
    OR requested_policy_version IS NULL OR requested_global_version IS NULL
    OR requested_workspace_version IS NULL
    OR octet_length(access_token_hash) <> 32
    OR requested_source_project_id !~ '^[A-Za-z0-9_-]{1,128}$'
    OR requested_proposed_revision_id !~ '^[A-Za-z0-9_-]{1,128}$'
    OR octet_length(requested_working_manifest_digest) <> 32
    OR octet_length(requested_working_digest) <> 32
    OR octet_length(requested_idempotency_digest) <> 32
    OR requested_working_bytes <= 0 OR requested_working_bytes > 67108864 OR requested_policy_version < 1
    OR requested_global_version < 1 OR requested_workspace_version < 1 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROJECT_SYNC_MIGRATION_INPUT';
  END IF;
  SELECT * INTO context_row FROM roomscan.project_sync_resolve_access_v1(
    access_token_hash, authoritative_time, ARRAY['owner', 'admin', 'editor']::text[], false
  );
  SELECT * INTO existing FROM roomscan.project_uploads AS upload
  WHERE upload.workspace_id = context_row.workspace_id
    AND upload.created_by_principal_id = context_row.principal_id
    AND upload.operation = 'create_initial_head'
    AND upload.idempotency_digest = requested_idempotency_digest
  FOR UPDATE;
  IF FOUND THEN
    IF existing.source_project_id IS DISTINCT FROM requested_source_project_id
      OR existing.proposed_revision_id IS DISTINCT FROM requested_proposed_revision_id
      OR existing.working_manifest_digest IS DISTINCT FROM requested_working_manifest_digest
      OR existing.working_digest IS DISTINCT FROM requested_working_digest
      OR existing.working_bytes IS DISTINCT FROM requested_working_bytes
      OR existing.quota_policy_version IS DISTINCT FROM requested_policy_version
      OR existing.hosted_global_version IS DISTINCT FROM requested_global_version
      OR existing.hosted_workspace_version IS DISTINCT FROM requested_workspace_version THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROJECT_SYNC_IDEMPOTENCY_REUSED';
    END IF;
    RETURN QUERY SELECT existing.state, existing.project_public_id, existing.public_id,
      existing.proposed_revision_public_id, existing.working_manifest_digest,
      existing.working_digest, existing.working_bytes, existing.allocation_expires_at;
    RETURN;
  END IF;
  PERFORM roomscan.project_sync_require_grant_v1(
    context_row.workspace_id, 'project.create', requested_global_version, requested_workspace_version
  );
  -- Serialize one source-project migration in a workspace before quota rows
  -- are reserved.  Rejected tombstones deliberately do not hold this lock.
  PERFORM pg_advisory_xact_lock(hashtextextended(
    context_row.workspace_id::text || ':' || requested_source_project_id, 0
  ));
  IF EXISTS (
    SELECT 1 FROM roomscan.professional_projects AS project
    WHERE project.workspace_id = context_row.workspace_id
      AND project.source_project_id = requested_source_project_id
  ) OR EXISTS (
    SELECT 1 FROM roomscan.project_uploads AS upload
    WHERE upload.workspace_id = context_row.workspace_id
      AND upload.operation = 'create_initial_head'
      AND upload.source_project_id = requested_source_project_id
      AND upload.state <> 'rejected'
  ) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'SOURCE_PROJECT_SYNC_ALREADY_EXISTS';
  END IF;
  expires_at_time := authoritative_time + interval '300 seconds';
  PERFORM 1 FROM roomscan.reserve_quota_v2(
    access_token_hash, authoritative_time, 'project_count'::roomscan.quota_metric,
    'roomscan-period-v1:lifetime', 'project.create', 'project_sync_upload',
    created_upload_public_id, 1,
    roomscan.project_sync_quota_key_v1(created_upload_public_id, 'project-count'),
    requested_policy_version, expires_at_time, requested_global_version,
    requested_workspace_version, NULL, NULL
  );
  PERFORM 1 FROM roomscan.reserve_quota_v2(
    access_token_hash, authoritative_time, 'working_bytes'::roomscan.quota_metric,
    'roomscan-period-v1:lifetime', 'project.revise', 'project_sync_upload',
    created_upload_public_id, requested_working_bytes,
    roomscan.project_sync_quota_key_v1(created_upload_public_id, 'working'),
    requested_policy_version, expires_at_time, requested_global_version,
    requested_workspace_version, NULL, NULL
  );
  INSERT INTO roomscan.project_uploads (
    workspace_id, id, public_id, project_id, project_public_id, source_project_id,
    operation, idempotency_digest, proposed_revision_id, proposed_revision_public_id,
    target_revision_id, expected_head_revision_id, expected_head_source_revision_id,
    working_manifest_digest, working_digest, working_bytes, state, quarantine_key,
    active_object_key, allocation_expires_at, quota_policy_version,
    hosted_global_version, hosted_workspace_version, created_by_principal_id,
    created_at, updated_at
  ) VALUES (
    context_row.workspace_id, created_upload_id, created_upload_public_id, NULL,
    created_project_public_id, requested_source_project_id, 'create_initial_head',
    requested_idempotency_digest, requested_proposed_revision_id, created_revision_public_id,
    created_revision_id, NULL, NULL, requested_working_manifest_digest,
    requested_working_digest, requested_working_bytes, 'allocated',
    'professional-sync/quarantine/working/' || created_upload_public_id || '.zip',
    'professional-sync/active/working/' || created_revision_public_id || '.zip',
    expires_at_time, requested_policy_version, requested_global_version,
    requested_workspace_version, context_row.principal_id, authoritative_time, authoritative_time
  ) RETURNING * INTO existing;
  PERFORM roomscan.project_sync_append_audit_v1(
    context_row.workspace_id, context_row.principal_id,
    'project_sync.migration_allocated', existing.public_id, authoritative_time
  );
  RETURN QUERY SELECT existing.state, existing.project_public_id, existing.public_id,
    existing.proposed_revision_public_id, existing.working_manifest_digest,
    existing.working_digest, existing.working_bytes, existing.allocation_expires_at;
END
$function$;

CREATE FUNCTION roomscan.allocate_project_revision_v1(
  access_token_hash bytea,
  authoritative_time timestamptz,
  requested_project_public_id text,
  requested_expected_head_public_id text,
  requested_expected_head_source_revision_id text,
  requested_proposed_revision_id text,
  requested_working_manifest_digest bytea,
  requested_working_digest bytea,
  requested_working_bytes bigint,
  requested_idempotency_digest bytea,
  requested_policy_version bigint,
  requested_global_version bigint,
  requested_workspace_version bigint
)
RETURNS TABLE (
  status text,
  project_public_id text,
  upload_public_id text,
  candidate_revision_public_id text,
  working_manifest_digest bytea,
  working_digest bytea,
  working_bytes bigint,
  allocation_expires_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE existing roomscan.project_uploads%ROWTYPE;
DECLARE target_project roomscan.professional_projects%ROWTYPE;
DECLARE expected_head roomscan.project_revisions%ROWTYPE;
DECLARE created_upload_id uuid := gen_random_uuid();
DECLARE created_upload_public_id text := 'upl_' || replace(gen_random_uuid()::text, '-', '');
DECLARE created_revision_public_id text := 'rev_' || replace(gen_random_uuid()::text, '-', '');
DECLARE created_revision_id uuid := gen_random_uuid();
DECLARE expires_at_time timestamptz;
BEGIN
  IF access_token_hash IS NULL OR authoritative_time IS NULL
    OR requested_project_public_id IS NULL OR requested_expected_head_public_id IS NULL
    OR requested_expected_head_source_revision_id IS NULL OR requested_proposed_revision_id IS NULL
    OR requested_working_manifest_digest IS NULL OR requested_working_digest IS NULL
    OR requested_working_bytes IS NULL OR requested_idempotency_digest IS NULL
    OR requested_policy_version IS NULL OR requested_global_version IS NULL
    OR requested_workspace_version IS NULL
    OR octet_length(access_token_hash) <> 32
    OR requested_project_public_id !~ '^prj_[A-Za-z0-9_-]{16,128}$'
    OR requested_expected_head_public_id !~ '^rev_[A-Za-z0-9_-]{16,128}$'
    OR requested_expected_head_source_revision_id !~ '^[A-Za-z0-9_-]{1,128}$'
    OR requested_proposed_revision_id !~ '^[A-Za-z0-9_-]{1,128}$'
    OR octet_length(requested_working_manifest_digest) <> 32
    OR octet_length(requested_working_digest) <> 32
    OR octet_length(requested_idempotency_digest) <> 32
    OR requested_working_bytes <= 0 OR requested_working_bytes > 67108864 OR requested_policy_version < 1
    OR requested_global_version < 1 OR requested_workspace_version < 1 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROJECT_SYNC_REVISION_INPUT';
  END IF;
  SELECT * INTO context_row FROM roomscan.project_sync_resolve_access_v1(
    access_token_hash, authoritative_time, ARRAY['owner', 'admin', 'editor']::text[], false
  );
  SELECT * INTO existing FROM roomscan.project_uploads AS upload
  WHERE upload.workspace_id = context_row.workspace_id
    AND upload.created_by_principal_id = context_row.principal_id
    AND upload.operation = 'append_revision'
    AND upload.idempotency_digest = requested_idempotency_digest
  FOR UPDATE;
  IF FOUND THEN
    IF existing.project_public_id IS DISTINCT FROM requested_project_public_id
      OR existing.expected_head_source_revision_id IS DISTINCT FROM requested_expected_head_source_revision_id
      OR existing.proposed_revision_id IS DISTINCT FROM requested_proposed_revision_id
      OR existing.working_manifest_digest IS DISTINCT FROM requested_working_manifest_digest
      OR existing.working_digest IS DISTINCT FROM requested_working_digest
      OR existing.working_bytes IS DISTINCT FROM requested_working_bytes
      OR existing.quota_policy_version IS DISTINCT FROM requested_policy_version
      OR existing.hosted_global_version IS DISTINCT FROM requested_global_version
      OR existing.hosted_workspace_version IS DISTINCT FROM requested_workspace_version
      OR NOT EXISTS (
        SELECT 1 FROM roomscan.project_revisions AS revision
        WHERE revision.workspace_id = existing.workspace_id
          AND revision.id = existing.expected_head_revision_id
          AND revision.public_id = requested_expected_head_public_id
      ) THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROJECT_SYNC_IDEMPOTENCY_REUSED';
    END IF;
    RETURN QUERY SELECT existing.state, existing.project_public_id, existing.public_id,
      existing.proposed_revision_public_id, existing.working_manifest_digest,
      existing.working_digest, existing.working_bytes, existing.allocation_expires_at;
    RETURN;
  END IF;
  PERFORM roomscan.project_sync_require_grant_v1(
    context_row.workspace_id, 'project.revise', requested_global_version, requested_workspace_version
  );
  SELECT * INTO target_project
  FROM roomscan.professional_projects AS project
  WHERE project.workspace_id = context_row.workspace_id
    AND project.public_id = requested_project_public_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROJECT_SYNC_PROJECT_NOT_FOUND';
  END IF;
  SELECT * INTO expected_head
  FROM roomscan.project_revisions AS revision
  WHERE revision.workspace_id = context_row.workspace_id
    AND revision.id = target_project.head_revision_id
    AND revision.public_id = requested_expected_head_public_id
  FOR KEY SHARE;
  IF NOT FOUND OR expected_head.source_revision_id IS DISTINCT FROM requested_expected_head_source_revision_id THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROJECT_SYNC_EXPECTED_HEAD_STALE';
  END IF;
  IF EXISTS (
    SELECT 1 FROM roomscan.project_revisions AS revision
    WHERE revision.workspace_id = context_row.workspace_id
      AND revision.project_id = target_project.project_id
      AND revision.source_revision_id = requested_proposed_revision_id
  ) OR EXISTS (
    SELECT 1 FROM roomscan.project_uploads AS upload
    WHERE upload.workspace_id = context_row.workspace_id
      AND upload.project_id = target_project.project_id
      AND upload.proposed_revision_id = requested_proposed_revision_id
      AND upload.operation = 'append_revision'
      AND upload.state <> 'rejected'
  ) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROJECT_SYNC_SOURCE_REVISION_EXISTS';
  END IF;
  expires_at_time := authoritative_time + interval '300 seconds';
  PERFORM 1 FROM roomscan.reserve_quota_v2(
    access_token_hash, authoritative_time, 'working_bytes'::roomscan.quota_metric,
    'roomscan-period-v1:lifetime', 'project.revise', 'project_sync_upload',
    created_upload_public_id, requested_working_bytes,
    roomscan.project_sync_quota_key_v1(created_upload_public_id, 'working'),
    requested_policy_version, expires_at_time, requested_global_version,
    requested_workspace_version, NULL, NULL
  );
  INSERT INTO roomscan.project_uploads (
    workspace_id, id, public_id, project_id, project_public_id, source_project_id,
    operation, idempotency_digest, proposed_revision_id, proposed_revision_public_id,
    target_revision_id, expected_head_revision_id, expected_head_source_revision_id,
    working_manifest_digest, working_digest, working_bytes, state, quarantine_key,
    active_object_key, allocation_expires_at, quota_policy_version,
    hosted_global_version, hosted_workspace_version, created_by_principal_id,
    created_at, updated_at
  ) VALUES (
    context_row.workspace_id, created_upload_id, created_upload_public_id,
    target_project.project_id, target_project.public_id, NULL, 'append_revision',
    requested_idempotency_digest, requested_proposed_revision_id, created_revision_public_id,
    created_revision_id, expected_head.id, requested_expected_head_source_revision_id,
    requested_working_manifest_digest, requested_working_digest, requested_working_bytes,
    'allocated', 'professional-sync/quarantine/working/' || created_upload_public_id || '.zip',
    'professional-sync/active/working/' || created_revision_public_id || '.zip',
    expires_at_time, requested_policy_version, requested_global_version,
    requested_workspace_version, context_row.principal_id, authoritative_time, authoritative_time
  ) RETURNING * INTO existing;
  PERFORM roomscan.project_sync_append_audit_v1(
    context_row.workspace_id, context_row.principal_id,
    'project_sync.revision_allocated', existing.public_id, authoritative_time
  );
  RETURN QUERY SELECT existing.state, existing.project_public_id, existing.public_id,
    existing.proposed_revision_public_id, existing.working_manifest_digest,
    existing.working_digest, existing.working_bytes, existing.allocation_expires_at;
END
$function$;

CREATE FUNCTION roomscan.configure_project_raw_archive_v1(
  access_token_hash bytea,
  authoritative_time timestamptz,
  requested_project_public_id text,
  requested_review_digest bytea,
  requested_global_version bigint,
  requested_workspace_version bigint
)
RETURNS TABLE (
  project_public_id text,
  raw_archive_enabled boolean,
  raw_reviewed_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE target_project roomscan.professional_projects%ROWTYPE;
BEGIN
  IF access_token_hash IS NULL OR authoritative_time IS NULL
    OR requested_project_public_id IS NULL OR requested_review_digest IS NULL
    OR requested_global_version IS NULL OR requested_workspace_version IS NULL
    OR octet_length(access_token_hash) <> 32
    OR requested_project_public_id !~ '^prj_[A-Za-z0-9_-]{16,128}$'
    OR octet_length(requested_review_digest) <> 32
    OR requested_global_version < 1 OR requested_workspace_version < 1 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROJECT_SYNC_RAW_CONFIGURATION_INPUT';
  END IF;
  SELECT * INTO context_row FROM roomscan.project_sync_resolve_access_v1(
    access_token_hash, authoritative_time, ARRAY['owner']::text[], true
  );
  PERFORM roomscan.project_sync_require_grant_v1(
    context_row.workspace_id, 'raw_archive.configure', requested_global_version, requested_workspace_version
  );
  SELECT * INTO target_project
  FROM roomscan.professional_projects AS project
  WHERE project.workspace_id = context_row.workspace_id
    AND project.public_id = requested_project_public_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROJECT_SYNC_PROJECT_NOT_FOUND';
  END IF;
  IF target_project.raw_archive_enabled IS FALSE
    OR target_project.raw_review_digest IS DISTINCT FROM requested_review_digest THEN
    UPDATE roomscan.professional_projects AS project
    SET raw_archive_enabled = true, raw_review_digest = requested_review_digest,
        raw_reviewed_at = authoritative_time, version = project.version + 1,
        updated_at = authoritative_time
    WHERE project.workspace_id = target_project.workspace_id
      AND project.project_id = target_project.project_id
    RETURNING * INTO target_project;
    PERFORM roomscan.project_sync_append_audit_v1(
      context_row.workspace_id, context_row.principal_id,
      'project_sync.raw_configured', target_project.public_id, authoritative_time
    );
  END IF;
  RETURN QUERY SELECT target_project.public_id, target_project.raw_archive_enabled,
    target_project.raw_reviewed_at;
END
$function$;

CREATE FUNCTION roomscan.allocate_project_raw_archive_v1(
  access_token_hash bytea,
  authoritative_time timestamptz,
  requested_project_public_id text,
  requested_revision_public_id text,
  requested_raw_manifest_digest bytea,
  requested_raw_digest bytea,
  requested_raw_bytes bigint,
  requested_review_digest bytea,
  requested_idempotency_digest bytea,
  requested_policy_version bigint,
  requested_global_version bigint,
  requested_workspace_version bigint
)
RETURNS TABLE (
  status text,
  project_public_id text,
  upload_public_id text,
  target_revision_public_id text,
  raw_manifest_digest bytea,
  raw_digest bytea,
  raw_bytes bigint,
  allocation_expires_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE existing roomscan.project_uploads%ROWTYPE;
DECLARE target_project roomscan.professional_projects%ROWTYPE;
DECLARE target_revision roomscan.project_revisions%ROWTYPE;
DECLARE created_upload_id uuid := gen_random_uuid();
DECLARE created_upload_public_id text := 'upl_' || replace(gen_random_uuid()::text, '-', '');
DECLARE expires_at_time timestamptz;
BEGIN
  IF access_token_hash IS NULL OR authoritative_time IS NULL
    OR requested_project_public_id IS NULL OR requested_revision_public_id IS NULL
    OR requested_raw_manifest_digest IS NULL OR requested_raw_digest IS NULL
    OR requested_raw_bytes IS NULL OR requested_review_digest IS NULL
    OR requested_idempotency_digest IS NULL OR requested_policy_version IS NULL
    OR requested_global_version IS NULL OR requested_workspace_version IS NULL
    OR octet_length(access_token_hash) <> 32
    OR requested_project_public_id !~ '^prj_[A-Za-z0-9_-]{16,128}$'
    OR requested_revision_public_id !~ '^rev_[A-Za-z0-9_-]{16,128}$'
    OR octet_length(requested_raw_manifest_digest) <> 32
    OR octet_length(requested_raw_digest) <> 32
    OR octet_length(requested_review_digest) <> 32
    OR octet_length(requested_idempotency_digest) <> 32
    OR requested_raw_bytes <= 0 OR requested_raw_bytes > 67108864 OR requested_policy_version < 1
    OR requested_global_version < 1 OR requested_workspace_version < 1 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROJECT_SYNC_RAW_ALLOCATION_INPUT';
  END IF;
  SELECT * INTO context_row FROM roomscan.project_sync_resolve_access_v1(
    access_token_hash, authoritative_time, ARRAY['owner', 'admin', 'editor']::text[], false
  );
  SELECT * INTO existing FROM roomscan.project_uploads AS upload
  WHERE upload.workspace_id = context_row.workspace_id
    AND upload.created_by_principal_id = context_row.principal_id
    AND upload.operation = 'attach_raw_archive'
    AND upload.idempotency_digest = requested_idempotency_digest
  FOR UPDATE;
  IF FOUND THEN
    IF existing.project_public_id IS DISTINCT FROM requested_project_public_id
      OR existing.raw_manifest_digest IS DISTINCT FROM requested_raw_manifest_digest
      OR existing.raw_digest IS DISTINCT FROM requested_raw_digest
      OR existing.raw_bytes IS DISTINCT FROM requested_raw_bytes
      OR existing.raw_review_digest IS DISTINCT FROM requested_review_digest
      OR existing.quota_policy_version IS DISTINCT FROM requested_policy_version
      OR existing.hosted_global_version IS DISTINCT FROM requested_global_version
      OR existing.hosted_workspace_version IS DISTINCT FROM requested_workspace_version
      OR NOT EXISTS (
        SELECT 1 FROM roomscan.project_revisions AS revision
        WHERE revision.workspace_id = existing.workspace_id
          AND revision.id = existing.target_revision_id
          AND revision.public_id = requested_revision_public_id
      ) THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROJECT_SYNC_IDEMPOTENCY_REUSED';
    END IF;
    RETURN QUERY SELECT existing.state, existing.project_public_id, existing.public_id,
      requested_revision_public_id, existing.raw_manifest_digest, existing.raw_digest,
      existing.raw_bytes, existing.allocation_expires_at;
    RETURN;
  END IF;
  PERFORM roomscan.project_sync_require_grant_v1(
    context_row.workspace_id, 'raw_archive.allocate', requested_global_version, requested_workspace_version
  );
  SELECT * INTO target_project FROM roomscan.professional_projects AS project
  WHERE project.workspace_id = context_row.workspace_id
    AND project.public_id = requested_project_public_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROJECT_SYNC_PROJECT_NOT_FOUND';
  END IF;
  IF target_project.raw_archive_enabled IS DISTINCT FROM true
    OR target_project.raw_review_digest IS DISTINCT FROM requested_review_digest THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROJECT_SYNC_RAW_REVIEW_REQUIRED';
  END IF;
  SELECT * INTO target_revision FROM roomscan.project_revisions AS revision
  WHERE revision.workspace_id = context_row.workspace_id
    AND revision.project_id = target_project.project_id
    AND revision.public_id = requested_revision_public_id
    AND revision.branch_state IN ('canonical', 'stale')
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROJECT_SYNC_REVISION_NOT_FOUND';
  END IF;
  IF EXISTS (
    SELECT 1 FROM roomscan.project_uploads AS upload
    WHERE upload.workspace_id = context_row.workspace_id
      AND upload.operation = 'attach_raw_archive'
      AND upload.target_revision_id = target_revision.id
      AND upload.state IN ('allocated', 'validation_pending', 'validating')
  ) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'RAW_ARCHIVE_UPLOAD_IN_PROGRESS';
  END IF;
  IF EXISTS (
    SELECT 1 FROM roomscan.project_raw_archives AS archive
    WHERE archive.workspace_id = context_row.workspace_id
      AND archive.revision_id = target_revision.id
  ) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'RAW_ARCHIVE_ALREADY_ATTACHED';
  END IF;
  expires_at_time := authoritative_time + interval '300 seconds';
  PERFORM 1 FROM roomscan.reserve_quota_v2(
    access_token_hash, authoritative_time, 'raw_bytes'::roomscan.quota_metric,
    'roomscan-period-v1:lifetime', 'raw_archive.allocate', 'project_sync_upload',
    created_upload_public_id, requested_raw_bytes,
    roomscan.project_sync_quota_key_v1(created_upload_public_id, 'raw'),
    requested_policy_version, expires_at_time, requested_global_version,
    requested_workspace_version, NULL, NULL
  );
  INSERT INTO roomscan.project_uploads (
    workspace_id, id, public_id, project_id, project_public_id, source_project_id,
    operation, idempotency_digest, proposed_revision_id, proposed_revision_public_id,
    target_revision_id, expected_head_revision_id, expected_head_source_revision_id,
    raw_manifest_digest, raw_digest, raw_bytes, raw_review_digest, state,
    quarantine_key, active_object_key, allocation_expires_at, quota_policy_version,
    hosted_global_version, hosted_workspace_version, created_by_principal_id,
    created_at, updated_at
  ) VALUES (
    context_row.workspace_id, created_upload_id, created_upload_public_id,
    target_project.project_id, target_project.public_id, NULL, 'attach_raw_archive',
    requested_idempotency_digest, NULL, NULL, target_revision.id, NULL, NULL,
    requested_raw_manifest_digest, requested_raw_digest, requested_raw_bytes,
    requested_review_digest, 'allocated',
    'professional-sync/quarantine/raw/' || created_upload_public_id || '.zip',
    'professional-sync/active/raw/' || created_upload_public_id || '.zip',
    expires_at_time, requested_policy_version, requested_global_version,
    requested_workspace_version, context_row.principal_id, authoritative_time, authoritative_time
  ) RETURNING * INTO existing;
  PERFORM roomscan.project_sync_append_audit_v1(
    context_row.workspace_id, context_row.principal_id,
    'project_sync.raw_allocated', existing.public_id, authoritative_time
  );
  RETURN QUERY SELECT existing.state, existing.project_public_id, existing.public_id,
    target_revision.public_id, existing.raw_manifest_digest, existing.raw_digest,
    existing.raw_bytes, existing.allocation_expires_at;
END
$function$;

CREATE FUNCTION roomscan.project_sync_public_upload_status_v1(
  requested_workspace_id uuid,
  requested_upload_public_id text
)
RETURNS TABLE (
  status text,
  project_public_id text,
  upload_public_id text,
  candidate_revision_public_id text,
  current_hosted_head_revision_public_id text,
  working_digest bytea,
  working_bytes bigint,
  raw_digest bytea,
  raw_bytes bigint,
  allocation_expires_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
  SELECT upload.state, upload.project_public_id, upload.public_id,
    COALESCE(upload.proposed_revision_public_id, target_revision.public_id),
    roomscan.project_sync_current_head_public_id_v1(upload.workspace_id, upload.project_id),
    upload.working_digest, upload.working_bytes, upload.raw_digest, upload.raw_bytes,
    upload.allocation_expires_at
  FROM roomscan.project_uploads AS upload
  LEFT JOIN roomscan.project_revisions AS target_revision
    ON target_revision.workspace_id = upload.workspace_id
   AND target_revision.id = upload.target_revision_id
  WHERE upload.workspace_id = requested_workspace_id
    AND upload.public_id = requested_upload_public_id
$function$;

CREATE FUNCTION roomscan.complete_project_upload_v1(
  access_token_hash bytea,
  authoritative_time timestamptz,
  requested_upload_public_id text
)
RETURNS TABLE (
  status text,
  project_public_id text,
  upload_public_id text,
  candidate_revision_public_id text,
  current_hosted_head_revision_public_id text,
  working_digest bytea,
  working_bytes bigint,
  raw_digest bytea,
  raw_bytes bigint,
  allocation_expires_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE target_upload roomscan.project_uploads%ROWTYPE;
DECLARE required_action text;
BEGIN
  IF access_token_hash IS NULL OR authoritative_time IS NULL OR requested_upload_public_id IS NULL
    OR octet_length(access_token_hash) <> 32
    OR requested_upload_public_id !~ '^upl_[A-Za-z0-9_-]{16,128}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROJECT_SYNC_COMPLETION_INPUT';
  END IF;
  SELECT * INTO context_row FROM roomscan.project_sync_resolve_access_v1(
    access_token_hash, authoritative_time, ARRAY['owner', 'admin', 'editor']::text[], false
  );
  SELECT * INTO target_upload FROM roomscan.project_uploads AS upload
  WHERE upload.workspace_id = context_row.workspace_id
    AND upload.public_id = requested_upload_public_id
  FOR UPDATE;
  IF NOT FOUND OR target_upload.created_by_principal_id IS DISTINCT FROM context_row.principal_id THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROJECT_SYNC_UPLOAD_NOT_FOUND';
  END IF;
  required_action := CASE target_upload.operation
    WHEN 'create_initial_head' THEN 'project.create'
    WHEN 'append_revision' THEN 'project.revise'
    WHEN 'attach_raw_archive' THEN 'raw_archive.allocate'
    ELSE NULL
  END;
  PERFORM roomscan.project_sync_require_grant_v1(
    context_row.workspace_id, required_action,
    target_upload.hosted_global_version, target_upload.hosted_workspace_version
  );
  IF target_upload.state = 'allocated' THEN
    IF target_upload.allocation_expires_at <= authoritative_time THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROJECT_SYNC_ALLOCATION_EXPIRED';
    END IF;
    UPDATE roomscan.project_uploads AS upload
    SET state = 'validation_pending', updated_at = authoritative_time
    WHERE upload.workspace_id = target_upload.workspace_id
      AND upload.id = target_upload.id
      AND upload.state = 'allocated'
    RETURNING * INTO target_upload;
    PERFORM roomscan.project_sync_append_audit_v1(
      context_row.workspace_id, context_row.principal_id,
      'project_sync.upload_completed', target_upload.public_id, authoritative_time
    );
  END IF;
  RETURN QUERY SELECT * FROM roomscan.project_sync_public_upload_status_v1(
    target_upload.workspace_id, target_upload.public_id
  );
END
$function$;

CREATE FUNCTION roomscan.read_project_upload_status_v1(
  access_token_hash bytea,
  authoritative_time timestamptz,
  requested_upload_public_id text
)
RETURNS TABLE (
  status text,
  project_public_id text,
  upload_public_id text,
  candidate_revision_public_id text,
  current_hosted_head_revision_public_id text,
  working_digest bytea,
  working_bytes bigint,
  raw_digest bytea,
  raw_bytes bigint,
  allocation_expires_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
BEGIN
  IF access_token_hash IS NULL OR authoritative_time IS NULL OR requested_upload_public_id IS NULL
    OR octet_length(access_token_hash) <> 32
    OR requested_upload_public_id !~ '^upl_[A-Za-z0-9_-]{16,128}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROJECT_SYNC_STATUS_INPUT';
  END IF;
  SELECT * INTO context_row FROM roomscan.project_sync_resolve_access_v1(
    access_token_hash, authoritative_time, ARRAY['owner', 'admin', 'editor', 'viewer']::text[], false
  );
  RETURN QUERY SELECT * FROM roomscan.project_sync_public_upload_status_v1(
    context_row.workspace_id, requested_upload_public_id
  );
END
$function$;

CREATE FUNCTION roomscan.allocate_project_recovery_v1(
  access_token_hash bytea,
  authoritative_time timestamptz,
  requested_project_public_id text,
  requested_revision_public_id text
)
RETURNS TABLE (
  project_public_id text,
  target_revision_public_id text,
  branch_state text,
  working_manifest_digest bytea,
  working_digest bytea,
  working_bytes bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE target_project roomscan.professional_projects%ROWTYPE;
BEGIN
  IF access_token_hash IS NULL OR authoritative_time IS NULL OR requested_project_public_id IS NULL
    OR octet_length(access_token_hash) <> 32
    OR requested_project_public_id !~ '^prj_[A-Za-z0-9_-]{16,128}$'
    OR (requested_revision_public_id IS NOT NULL
      AND requested_revision_public_id !~ '^rev_[A-Za-z0-9_-]{16,128}$') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROJECT_SYNC_RECOVERY_INPUT';
  END IF;
  SELECT * INTO context_row FROM roomscan.project_sync_resolve_access_v1(
    access_token_hash, authoritative_time, ARRAY['owner', 'admin', 'editor', 'viewer']::text[], false
  );
  SELECT * INTO target_project FROM roomscan.professional_projects AS project
  WHERE project.workspace_id = context_row.workspace_id
    AND project.public_id = requested_project_public_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;
  RETURN QUERY
  SELECT target_project.public_id, revision.public_id, revision.branch_state,
    revision.working_manifest_digest, revision.working_digest, revision.working_bytes
  FROM roomscan.project_revisions AS revision
  WHERE revision.workspace_id = target_project.workspace_id
    AND revision.project_id = target_project.project_id
    AND revision.branch_state IN ('canonical', 'stale')
    AND (
      (requested_revision_public_id IS NULL AND revision.id = target_project.head_revision_id)
      OR revision.public_id = requested_revision_public_id
    );
END
$function$;

CREATE FUNCTION roomscan.resolve_project_recovery_storage_v1(
  access_token_hash bytea,
  authoritative_time timestamptz,
  requested_project_public_id text,
  requested_revision_public_id text
)
RETURNS TABLE (
  project_public_id text,
  target_revision_public_id text,
  branch_state text,
  working_object_key text,
  working_object_version text,
  working_manifest_digest bytea,
  working_digest bytea,
  working_bytes bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE target_project roomscan.professional_projects%ROWTYPE;
BEGIN
  IF access_token_hash IS NULL OR authoritative_time IS NULL OR requested_project_public_id IS NULL
    OR octet_length(access_token_hash) <> 32
    OR requested_project_public_id !~ '^prj_[A-Za-z0-9_-]{16,128}$'
    OR (requested_revision_public_id IS NOT NULL
      AND requested_revision_public_id !~ '^rev_[A-Za-z0-9_-]{16,128}$') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROJECT_SYNC_RECOVERY_STORAGE_INPUT';
  END IF;
  SELECT * INTO context_row FROM roomscan.project_sync_resolve_access_v1(
    access_token_hash, authoritative_time, ARRAY['owner', 'admin', 'editor', 'viewer']::text[], false
  );
  SELECT * INTO target_project FROM roomscan.professional_projects AS project
  WHERE project.workspace_id = context_row.workspace_id
    AND project.public_id = requested_project_public_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;
  RETURN QUERY
  SELECT target_project.public_id, revision.public_id, revision.branch_state,
    revision.working_object_key, revision.working_object_version,
    revision.working_manifest_digest, revision.working_digest, revision.working_bytes
  FROM roomscan.project_revisions AS revision
  WHERE revision.workspace_id = target_project.workspace_id
    AND revision.project_id = target_project.project_id
    AND revision.branch_state IN ('canonical', 'stale')
    AND (
      (requested_revision_public_id IS NULL AND revision.id = target_project.head_revision_id)
      OR revision.public_id = requested_revision_public_id
    );
END
$function$;

CREATE FUNCTION roomscan.acquire_project_edit_lease_v1(
  access_token_hash bytea,
  authoritative_time timestamptz,
  requested_project_public_id text,
  requested_device_digest bytea,
  requested_request_digest bytea,
  requested_token_digest bytea,
  requested_global_version bigint,
  requested_workspace_version bigint
)
RETURNS TABLE (status text, expires_at timestamptz)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE target_project roomscan.professional_projects%ROWTYPE;
DECLARE existing roomscan.project_edit_leases%ROWTYPE;
DECLARE next_expiry timestamptz := authoritative_time + interval '900 seconds';
BEGIN
  IF access_token_hash IS NULL OR authoritative_time IS NULL
    OR requested_project_public_id IS NULL OR requested_device_digest IS NULL
    OR requested_request_digest IS NULL OR requested_token_digest IS NULL
    OR requested_global_version IS NULL OR requested_workspace_version IS NULL
    OR octet_length(access_token_hash) <> 32
    OR requested_project_public_id !~ '^prj_[A-Za-z0-9_-]{16,128}$'
    OR octet_length(requested_device_digest) <> 32
    OR octet_length(requested_request_digest) <> 32
    OR octet_length(requested_token_digest) <> 32
    OR requested_global_version < 1 OR requested_workspace_version < 1 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROJECT_EDIT_LEASE_ACQUIRE_INPUT';
  END IF;
  SELECT * INTO context_row FROM roomscan.project_sync_resolve_access_v1(
    access_token_hash, authoritative_time, ARRAY['owner', 'admin', 'editor']::text[], false
  );
  PERFORM roomscan.project_sync_require_grant_v1(
    context_row.workspace_id, 'project.revise', requested_global_version, requested_workspace_version
  );
  SELECT * INTO target_project FROM roomscan.professional_projects AS project
  WHERE project.workspace_id = context_row.workspace_id
    AND project.public_id = requested_project_public_id
  FOR KEY SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROJECT_SYNC_PROJECT_NOT_FOUND';
  END IF;
  SELECT * INTO existing FROM roomscan.project_edit_leases AS lease
  WHERE lease.workspace_id = target_project.workspace_id
    AND lease.project_id = target_project.project_id
  FOR UPDATE;
  IF FOUND AND existing.expires_at > authoritative_time THEN
    IF existing.holder_principal_id = context_row.principal_id
      AND existing.holder_device_digest IS NOT DISTINCT FROM requested_device_digest
      AND existing.request_digest IS NOT DISTINCT FROM requested_request_digest
      AND existing.token_digest IS NOT DISTINCT FROM requested_token_digest THEN
      RETURN QUERY SELECT 'acquired'::text, existing.expires_at;
    ELSE
      RETURN QUERY SELECT 'held'::text, existing.expires_at;
    END IF;
    RETURN;
  END IF;
  IF FOUND THEN
    UPDATE roomscan.project_edit_leases AS lease
    SET holder_principal_id = context_row.principal_id,
        holder_device_digest = requested_device_digest,
        request_digest = requested_request_digest,
        token_digest = requested_token_digest,
        generation = lease.generation + 1,
        expires_at = next_expiry,
        updated_at = authoritative_time
    WHERE lease.workspace_id = existing.workspace_id AND lease.project_id = existing.project_id;
  ELSE
    INSERT INTO roomscan.project_edit_leases (
      workspace_id, project_id, holder_principal_id, holder_device_digest,
      request_digest, token_digest, generation, expires_at, updated_at
    ) VALUES (
      target_project.workspace_id, target_project.project_id, context_row.principal_id,
      requested_device_digest, requested_request_digest, requested_token_digest,
      1, next_expiry, authoritative_time
    );
  END IF;
  PERFORM roomscan.project_sync_append_audit_v1(
    context_row.workspace_id, context_row.principal_id,
    'project_sync.lease_acquired', target_project.public_id, authoritative_time
  );
  RETURN QUERY SELECT 'acquired'::text, next_expiry;
END
$function$;

CREATE FUNCTION roomscan.renew_project_edit_lease_v1(
  access_token_hash bytea,
  authoritative_time timestamptz,
  requested_project_public_id text,
  requested_token_digest bytea,
  requested_global_version bigint,
  requested_workspace_version bigint
)
RETURNS TABLE (status text, expires_at timestamptz)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE target_project roomscan.professional_projects%ROWTYPE;
DECLARE next_expiry timestamptz := authoritative_time + interval '900 seconds';
BEGIN
  IF access_token_hash IS NULL OR authoritative_time IS NULL OR requested_project_public_id IS NULL
    OR requested_token_digest IS NULL OR requested_global_version IS NULL
    OR requested_workspace_version IS NULL OR octet_length(access_token_hash) <> 32
    OR requested_project_public_id !~ '^prj_[A-Za-z0-9_-]{16,128}$'
    OR octet_length(requested_token_digest) <> 32
    OR requested_global_version < 1 OR requested_workspace_version < 1 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROJECT_EDIT_LEASE_RENEW_INPUT';
  END IF;
  SELECT * INTO context_row FROM roomscan.project_sync_resolve_access_v1(
    access_token_hash, authoritative_time, ARRAY['owner', 'admin', 'editor']::text[], false
  );
  PERFORM roomscan.project_sync_require_grant_v1(
    context_row.workspace_id, 'project.revise', requested_global_version, requested_workspace_version
  );
  SELECT * INTO target_project FROM roomscan.professional_projects AS project
  WHERE project.workspace_id = context_row.workspace_id AND project.public_id = requested_project_public_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROJECT_SYNC_PROJECT_NOT_FOUND';
  END IF;
  UPDATE roomscan.project_edit_leases AS lease
  SET expires_at = next_expiry, updated_at = authoritative_time
  WHERE lease.workspace_id = target_project.workspace_id
    AND lease.project_id = target_project.project_id
    AND lease.holder_principal_id = context_row.principal_id
    AND lease.token_digest IS NOT DISTINCT FROM requested_token_digest
    AND lease.expires_at > authoritative_time;
  IF FOUND THEN
    RETURN QUERY SELECT 'renewed'::text, next_expiry;
  ELSE
    RETURN QUERY SELECT 'unavailable'::text, NULL::timestamptz;
  END IF;
END
$function$;

CREATE FUNCTION roomscan.release_project_edit_lease_v1(
  access_token_hash bytea,
  authoritative_time timestamptz,
  requested_project_public_id text,
  requested_token_digest bytea,
  requested_global_version bigint,
  requested_workspace_version bigint
)
RETURNS TABLE (status text, expires_at timestamptz)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE target_project roomscan.professional_projects%ROWTYPE;
BEGIN
  IF access_token_hash IS NULL OR authoritative_time IS NULL OR requested_project_public_id IS NULL
    OR requested_token_digest IS NULL OR requested_global_version IS NULL
    OR requested_workspace_version IS NULL OR octet_length(access_token_hash) <> 32
    OR requested_project_public_id !~ '^prj_[A-Za-z0-9_-]{16,128}$'
    OR octet_length(requested_token_digest) <> 32
    OR requested_global_version < 1 OR requested_workspace_version < 1 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROJECT_EDIT_LEASE_RELEASE_INPUT';
  END IF;
  SELECT * INTO context_row FROM roomscan.project_sync_resolve_access_v1(
    access_token_hash, authoritative_time, ARRAY['owner', 'admin', 'editor']::text[], false
  );
  PERFORM roomscan.project_sync_require_grant_v1(
    context_row.workspace_id, 'project.revise', requested_global_version, requested_workspace_version
  );
  SELECT * INTO target_project FROM roomscan.professional_projects AS project
  WHERE project.workspace_id = context_row.workspace_id AND project.public_id = requested_project_public_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROJECT_SYNC_PROJECT_NOT_FOUND';
  END IF;
  UPDATE roomscan.project_edit_leases AS lease
  SET expires_at = authoritative_time, updated_at = authoritative_time
  WHERE lease.workspace_id = target_project.workspace_id
    AND lease.project_id = target_project.project_id
    AND lease.holder_principal_id = context_row.principal_id
    AND lease.token_digest IS NOT DISTINCT FROM requested_token_digest
    AND lease.expires_at > authoritative_time;
  IF FOUND THEN
    PERFORM roomscan.project_sync_append_audit_v1(
      context_row.workspace_id, context_row.principal_id,
      'project_sync.lease_released', target_project.public_id, authoritative_time
    );
    RETURN QUERY SELECT 'released'::text, authoritative_time;
  ELSE
    RETURN QUERY SELECT 'unavailable'::text, NULL::timestamptz;
  END IF;
END
$function$;

CREATE FUNCTION roomscan.project_sync_require_worker_v1()
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  IF session_user <> 'roomscan_project_sync_runtime' THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROJECT_SYNC_WORKER_REQUIRED';
  END IF;
END
$function$;

CREATE FUNCTION roomscan.reap_expired_project_upload_v1(
  authoritative_time timestamptz
)
RETURNS TABLE (reaped_count bigint)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE target_upload roomscan.project_uploads%ROWTYPE;
DECLARE total bigint := 0;
BEGIN
  IF authoritative_time IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROJECT_SYNC_REAP_INPUT';
  END IF;
  PERFORM roomscan.project_sync_require_worker_v1();
  FOR target_upload IN
    SELECT * FROM roomscan.project_uploads AS upload
    WHERE upload.state = 'allocated'
      AND upload.allocation_expires_at <= authoritative_time
    ORDER BY upload.allocation_expires_at, upload.created_at, upload.id
    FOR UPDATE SKIP LOCKED
  LOOP
    PERFORM roomscan.project_sync_release_upload_quotas_v1(
      target_upload, 'expired', authoritative_time
    );
    UPDATE roomscan.project_uploads AS upload
    SET state = 'rejected', rejection_code = 'allocation_expired',
        updated_at = authoritative_time
    WHERE upload.workspace_id = target_upload.workspace_id AND upload.id = target_upload.id;
    PERFORM roomscan.project_sync_append_audit_v1(
      target_upload.workspace_id, target_upload.created_by_principal_id,
      'project_sync.upload_rejected', target_upload.public_id, authoritative_time
    );
    total := total + 1;
  END LOOP;
  RETURN QUERY SELECT total;
END
$function$;

CREATE FUNCTION roomscan.claim_next_project_validation_v1(
  authoritative_time timestamptz
)
RETURNS TABLE (
  workspace_id uuid,
  upload_id uuid,
  lease_id text,
  operation text,
  project_id uuid,
  project_public_id text,
  source_project_id text,
  candidate_revision_id uuid,
  candidate_revision_public_id text,
  target_revision_id uuid,
  expected_head_revision_id uuid,
  expected_head_source_revision_id text,
  working_manifest_digest bytea,
  working_digest bytea,
  working_bytes bigint,
  raw_manifest_digest bytea,
  raw_digest bytea,
  raw_bytes bigint,
  raw_review_digest bytea,
  quarantine_key text,
  active_object_key text,
  project_source_project_id text,
  archive_source_revision_id text
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE target_upload roomscan.project_uploads%ROWTYPE;
DECLARE target_project roomscan.professional_projects%ROWTYPE;
DECLARE target_revision roomscan.project_revisions%ROWTYPE;
DECLARE next_lease_id text := 'wkl_' || replace(gen_random_uuid()::text, '-', '');
DECLARE next_lease_expiry timestamptz;
DECLARE resolved_project_source_project_id text;
DECLARE resolved_archive_source_revision_id text;
BEGIN
  IF authoritative_time IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROJECT_SYNC_CLAIM_INPUT';
  END IF;
  PERFORM roomscan.project_sync_require_worker_v1();
  next_lease_expiry := authoritative_time + interval '900 seconds';
  SELECT * INTO target_upload
  FROM roomscan.project_uploads AS upload
  WHERE upload.state = 'validation_pending'
    OR (upload.state = 'validating' AND upload.lease_expires_at <= authoritative_time)
  ORDER BY upload.created_at, upload.id
  FOR UPDATE SKIP LOCKED
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN;
  END IF;
  IF target_upload.operation = 'create_initial_head' THEN
    -- Initial allocation intentionally has no professional-project shell yet.
    -- Its staged source is immutable and becomes the authoritative project
    -- source in this same upload's successful finalization.
    IF target_upload.project_id IS NOT NULL
      OR target_upload.source_project_id IS NULL
      OR target_upload.proposed_revision_id IS NULL
      OR target_upload.target_revision_id IS NULL THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROJECT_SYNC_CLAIM_SOURCE_BINDING_INVALID';
    END IF;
    PERFORM 1
    FROM roomscan.professional_projects AS project
    WHERE project.workspace_id = target_upload.workspace_id
      AND (project.public_id = target_upload.project_public_id
        OR project.source_project_id = target_upload.source_project_id)
    FOR KEY SHARE;
    IF FOUND THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROJECT_SYNC_CLAIM_SOURCE_BINDING_INVALID';
    END IF;
    resolved_project_source_project_id := target_upload.source_project_id;
    resolved_archive_source_revision_id := target_upload.proposed_revision_id;
  ELSIF target_upload.operation IN ('append_revision', 'attach_raw_archive') THEN
    SELECT * INTO target_project
    FROM roomscan.professional_projects AS project
    WHERE project.workspace_id = target_upload.workspace_id
      AND project.project_id = target_upload.project_id
      AND project.public_id = target_upload.project_public_id
    FOR KEY SHARE;
    IF NOT FOUND OR target_project.source_project_id IS NULL THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROJECT_SYNC_CLAIM_SOURCE_BINDING_INVALID';
    END IF;
    resolved_project_source_project_id := target_project.source_project_id;
    IF target_upload.operation = 'append_revision' THEN
      IF target_upload.source_project_id IS NOT NULL
        OR target_upload.proposed_revision_id IS NULL
        OR target_upload.target_revision_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROJECT_SYNC_CLAIM_SOURCE_BINDING_INVALID';
      END IF;
      resolved_archive_source_revision_id := target_upload.proposed_revision_id;
    ELSE
      SELECT * INTO target_revision
      FROM roomscan.project_revisions AS revision
      WHERE revision.workspace_id = target_upload.workspace_id
        AND revision.id = target_upload.target_revision_id
        AND revision.project_id = target_project.project_id
      FOR KEY SHARE;
      IF NOT FOUND OR target_revision.source_revision_id IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROJECT_SYNC_CLAIM_SOURCE_BINDING_INVALID';
      END IF;
      resolved_archive_source_revision_id := target_revision.source_revision_id;
    END IF;
  ELSE
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROJECT_SYNC_CLAIM_SOURCE_BINDING_INVALID';
  END IF;
  UPDATE roomscan.project_uploads AS upload
  SET state = 'validating', lease_id = next_lease_id,
      lease_expires_at = next_lease_expiry,
      validation_attempts = upload.validation_attempts + 1,
      updated_at = authoritative_time
  WHERE upload.workspace_id = target_upload.workspace_id AND upload.id = target_upload.id
  RETURNING * INTO target_upload;
  RETURN QUERY SELECT target_upload.workspace_id, target_upload.id, target_upload.lease_id,
    target_upload.operation, target_upload.project_id, target_upload.project_public_id,
    target_upload.source_project_id, target_upload.target_revision_id,
    target_upload.proposed_revision_public_id, target_upload.target_revision_id,
    target_upload.expected_head_revision_id, target_upload.expected_head_source_revision_id,
    target_upload.working_manifest_digest, target_upload.working_digest,
    target_upload.working_bytes, target_upload.raw_manifest_digest,
    target_upload.raw_digest, target_upload.raw_bytes, target_upload.raw_review_digest,
    target_upload.quarantine_key, target_upload.active_object_key,
    resolved_project_source_project_id, resolved_archive_source_revision_id;
END
$function$;

CREATE FUNCTION roomscan.release_project_upload_v1(
  requested_upload_id uuid,
  requested_lease_id text,
  authoritative_time timestamptz
)
RETURNS TABLE (status text)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE target_upload roomscan.project_uploads%ROWTYPE;
BEGIN
  IF requested_upload_id IS NULL OR requested_lease_id IS NULL OR authoritative_time IS NULL
    OR requested_lease_id !~ '^wkl_[A-Za-z0-9_-]{16,128}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROJECT_SYNC_RELEASE_INPUT';
  END IF;
  PERFORM roomscan.project_sync_require_worker_v1();
  SELECT * INTO target_upload FROM roomscan.project_uploads AS upload
  WHERE upload.id = requested_upload_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'unavailable'::text;
    RETURN;
  END IF;
  IF target_upload.state = 'validating'
    AND target_upload.lease_id IS NOT DISTINCT FROM requested_lease_id
    AND target_upload.lease_expires_at > authoritative_time THEN
    UPDATE roomscan.project_uploads AS upload
    SET state = 'validation_pending', lease_id = NULL, lease_expires_at = NULL,
        updated_at = authoritative_time
    WHERE upload.workspace_id = target_upload.workspace_id AND upload.id = target_upload.id;
    RETURN QUERY SELECT 'validation_pending'::text;
  ELSE
    RETURN QUERY SELECT 'unavailable'::text;
  END IF;
END
$function$;

CREATE FUNCTION roomscan.reject_project_upload_v1(
  requested_upload_id uuid,
  requested_lease_id text,
  authoritative_time timestamptz,
  requested_rejection_code text
)
RETURNS TABLE (
  status text,
  project_public_id text,
  upload_public_id text,
  candidate_revision_public_id text,
  current_hosted_head_revision_public_id text,
  working_digest bytea,
  working_bytes bigint,
  raw_digest bytea,
  raw_bytes bigint,
  allocation_expires_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE target_upload roomscan.project_uploads%ROWTYPE;
BEGIN
  IF requested_upload_id IS NULL OR requested_lease_id IS NULL OR authoritative_time IS NULL
    OR requested_rejection_code NOT IN ('invalid_archive', 'provider_missing', 'provider_mismatch', 'duplicate_revision')
    OR requested_lease_id !~ '^wkl_[A-Za-z0-9_-]{16,128}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROJECT_SYNC_REJECTION_INPUT';
  END IF;
  PERFORM roomscan.project_sync_require_worker_v1();
  SELECT * INTO target_upload FROM roomscan.project_uploads AS upload
  WHERE upload.id = requested_upload_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROJECT_SYNC_UPLOAD_NOT_FOUND';
  END IF;
  IF target_upload.state IN ('canonical', 'stale', 'attached', 'rejected') THEN
    RETURN QUERY SELECT * FROM roomscan.project_sync_public_upload_status_v1(
      target_upload.workspace_id, target_upload.public_id
    );
    RETURN;
  END IF;
  IF target_upload.state <> 'validating'
    OR target_upload.lease_id IS DISTINCT FROM requested_lease_id
    OR target_upload.lease_expires_at <= authoritative_time THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROJECT_SYNC_VALIDATION_LEASE_REQUIRED';
  END IF;
  PERFORM roomscan.project_sync_release_upload_quotas_v1(
    target_upload, 'rejected', authoritative_time
  );
  UPDATE roomscan.project_uploads AS upload
  SET state = 'rejected', lease_id = NULL, lease_expires_at = NULL,
      rejection_code = requested_rejection_code, updated_at = authoritative_time
  WHERE upload.workspace_id = target_upload.workspace_id AND upload.id = target_upload.id
  RETURNING * INTO target_upload;
  PERFORM roomscan.project_sync_append_audit_v1(
    target_upload.workspace_id, target_upload.created_by_principal_id,
    'project_sync.upload_rejected', target_upload.public_id, authoritative_time
  );
  RETURN QUERY SELECT * FROM roomscan.project_sync_public_upload_status_v1(
    target_upload.workspace_id, target_upload.public_id
  );
END
$function$;

CREATE FUNCTION roomscan.finalize_project_upload_v1(
  requested_upload_id uuid,
  requested_lease_id text,
  authoritative_time timestamptz,
  requested_quarantine_version text,
  requested_active_object_version text
)
RETURNS TABLE (
  status text,
  project_public_id text,
  upload_public_id text,
  candidate_revision_public_id text,
  current_hosted_head_revision_public_id text,
  working_digest bytea,
  working_bytes bigint,
  raw_digest bytea,
  raw_bytes bigint,
  allocation_expires_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE target_upload roomscan.project_uploads%ROWTYPE;
DECLARE target_project roomscan.professional_projects%ROWTYPE;
DECLARE created_project_id uuid;
DECLARE canonical_won boolean := false;
DECLARE terminal_state text;
DECLARE current_head_public_id text;
BEGIN
  IF requested_upload_id IS NULL OR requested_lease_id IS NULL OR authoritative_time IS NULL
    OR requested_quarantine_version IS NULL OR requested_active_object_version IS NULL
    OR requested_lease_id !~ '^wkl_[A-Za-z0-9_-]{16,128}$'
    OR octet_length(requested_quarantine_version) NOT BETWEEN 1 AND 1024
    OR octet_length(requested_active_object_version) NOT BETWEEN 1 AND 1024
    OR requested_quarantine_version ~ '[[:cntrl:]]'
    OR requested_active_object_version ~ '[[:cntrl:]]' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROJECT_SYNC_FINALIZATION_INPUT';
  END IF;
  PERFORM roomscan.project_sync_require_worker_v1();
  SELECT * INTO target_upload FROM roomscan.project_uploads AS upload
  WHERE upload.id = requested_upload_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROJECT_SYNC_UPLOAD_NOT_FOUND';
  END IF;
  IF target_upload.state IN ('canonical', 'stale', 'attached', 'rejected') THEN
    RETURN QUERY SELECT * FROM roomscan.project_sync_public_upload_status_v1(
      target_upload.workspace_id, target_upload.public_id
    );
    RETURN;
  END IF;
  IF target_upload.state <> 'validating'
    OR target_upload.lease_id IS DISTINCT FROM requested_lease_id
    OR target_upload.lease_expires_at <= authoritative_time THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROJECT_SYNC_VALIDATION_LEASE_REQUIRED';
  END IF;

  IF target_upload.operation = 'create_initial_head' THEN
    created_project_id := gen_random_uuid();
    INSERT INTO roomscan.projects (
      workspace_id, id, slug, title, state, created_at, updated_at
    ) VALUES (
      target_upload.workspace_id, created_project_id,
      'sync-' || substr(target_upload.project_public_id, 5),
      'Professional project', 'active', authoritative_time, authoritative_time
    );
    INSERT INTO roomscan.professional_projects (
      workspace_id, project_id, public_id, source_project_id, head_revision_id,
      raw_archive_enabled, raw_review_digest, raw_reviewed_at, version, created_at, updated_at
    ) VALUES (
      target_upload.workspace_id, created_project_id, target_upload.project_public_id,
      target_upload.source_project_id, NULL, false, NULL, NULL, 1,
      authoritative_time, authoritative_time
    ) RETURNING * INTO target_project;
    INSERT INTO roomscan.project_revisions (
      workspace_id, id, public_id, project_id, parent_revision_id, source_revision_id,
      branch_state, working_object_key, working_object_version, working_digest,
      working_bytes, working_manifest_digest, created_at
    ) VALUES (
      target_upload.workspace_id, target_upload.target_revision_id,
      target_upload.proposed_revision_public_id, created_project_id, NULL,
      target_upload.proposed_revision_id, 'stale', target_upload.active_object_key,
      requested_active_object_version, target_upload.working_digest,
      target_upload.working_bytes, target_upload.working_manifest_digest, authoritative_time
    );
    UPDATE roomscan.professional_projects AS project
    SET head_revision_id = target_upload.target_revision_id,
        updated_at = authoritative_time
    WHERE project.workspace_id = target_upload.workspace_id
      AND project.project_id = created_project_id
      AND project.head_revision_id IS NULL;
    canonical_won := FOUND;
    terminal_state := CASE WHEN canonical_won THEN 'canonical' ELSE 'stale' END;
    UPDATE roomscan.project_revisions AS revision
    SET branch_state = terminal_state
    WHERE revision.workspace_id = target_upload.workspace_id
      AND revision.id = target_upload.target_revision_id;
    PERFORM roomscan.project_sync_finalize_upload_quotas_v1(target_upload, authoritative_time);
    UPDATE roomscan.project_uploads AS upload
    SET project_id = created_project_id, state = terminal_state,
        quarantine_version = requested_quarantine_version,
        active_object_version = requested_active_object_version,
        lease_id = NULL, lease_expires_at = NULL, updated_at = authoritative_time
    WHERE upload.workspace_id = target_upload.workspace_id AND upload.id = target_upload.id
    RETURNING * INTO target_upload;
  ELSIF target_upload.operation = 'append_revision' THEN
    INSERT INTO roomscan.project_revisions (
      workspace_id, id, public_id, project_id, parent_revision_id, source_revision_id,
      branch_state, working_object_key, working_object_version, working_digest,
      working_bytes, working_manifest_digest, created_at
    ) VALUES (
      target_upload.workspace_id, target_upload.target_revision_id,
      target_upload.proposed_revision_public_id, target_upload.project_id,
      target_upload.expected_head_revision_id, target_upload.proposed_revision_id,
      'stale', target_upload.active_object_key, requested_active_object_version,
      target_upload.working_digest, target_upload.working_bytes,
      target_upload.working_manifest_digest, authoritative_time
    );
    -- The expected-head predicate is the sole canonical-head authority.  A
    -- concurrent winner changes the head; this candidate remains immutable and
    -- visible as stale rather than being overwritten or merged.
    UPDATE roomscan.professional_projects AS project
    SET head_revision_id = target_upload.target_revision_id,
        updated_at = authoritative_time, version = project.version + 1
    WHERE project.workspace_id = target_upload.workspace_id
      AND project.project_id = target_upload.project_id
      AND project.head_revision_id IS NOT DISTINCT FROM target_upload.expected_head_revision_id;
    canonical_won := FOUND;
    terminal_state := CASE WHEN canonical_won THEN 'canonical' ELSE 'stale' END;
    UPDATE roomscan.project_revisions AS revision
    SET branch_state = terminal_state
    WHERE revision.workspace_id = target_upload.workspace_id
      AND revision.id = target_upload.target_revision_id;
    PERFORM roomscan.project_sync_finalize_upload_quotas_v1(target_upload, authoritative_time);
    UPDATE roomscan.project_uploads AS upload
    SET state = terminal_state, quarantine_version = requested_quarantine_version,
        active_object_version = requested_active_object_version,
        lease_id = NULL, lease_expires_at = NULL, updated_at = authoritative_time
    WHERE upload.workspace_id = target_upload.workspace_id AND upload.id = target_upload.id
    RETURNING * INTO target_upload;
  ELSIF target_upload.operation = 'attach_raw_archive' THEN
    INSERT INTO roomscan.project_raw_archives (
      workspace_id, revision_id, object_key, object_version, manifest_digest,
      archive_digest, archive_bytes, review_digest, created_at
    ) VALUES (
      target_upload.workspace_id, target_upload.target_revision_id,
      target_upload.active_object_key, requested_active_object_version,
      target_upload.raw_manifest_digest, target_upload.raw_digest,
      target_upload.raw_bytes, target_upload.raw_review_digest, authoritative_time
    );
    PERFORM roomscan.project_sync_finalize_upload_quotas_v1(target_upload, authoritative_time);
    terminal_state := 'attached';
    UPDATE roomscan.project_uploads AS upload
    SET state = terminal_state, quarantine_version = requested_quarantine_version,
        active_object_version = requested_active_object_version,
        lease_id = NULL, lease_expires_at = NULL, updated_at = authoritative_time
    WHERE upload.workspace_id = target_upload.workspace_id AND upload.id = target_upload.id
    RETURNING * INTO target_upload;
  ELSE
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROJECT_SYNC_UNKNOWN_OPERATION';
  END IF;
  current_head_public_id := roomscan.project_sync_current_head_public_id_v1(
    target_upload.workspace_id, target_upload.project_id
  );
  PERFORM roomscan.project_sync_append_audit_v1(
    target_upload.workspace_id, target_upload.created_by_principal_id,
    CASE
      WHEN terminal_state = 'canonical' THEN 'project_sync.upload_canonical'
      WHEN terminal_state = 'stale' THEN 'project_sync.upload_stale'
      ELSE 'project_sync.raw_attached'
    END,
    target_upload.public_id, authoritative_time
  );
  RETURN QUERY SELECT * FROM roomscan.project_sync_public_upload_status_v1(
    target_upload.workspace_id, target_upload.public_id
  );
END
$function$;

RESET ROLE;

ALTER FUNCTION roomscan.hosted_mutation_grant_matches(uuid, text, bigint, bigint, bigint, bigint)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.project_sync_resolve_access_v1(bytea, timestamptz, text[], boolean)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.project_sync_require_grant_v1(uuid, text, bigint, bigint)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.project_sync_quota_key_v1(text, text)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.project_sync_append_audit_v1(uuid, uuid, text, text, timestamptz)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.project_sync_release_quota_v1(uuid, text, text, bigint, text, timestamptz)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.project_sync_finalize_quota_v1(uuid, text, text, bigint, timestamptz)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.project_sync_release_upload_quotas_v1(roomscan.project_uploads, text, timestamptz)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.project_sync_finalize_upload_quotas_v1(roomscan.project_uploads, timestamptz)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.project_sync_current_head_public_id_v1(uuid, uuid)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.allocate_project_migration_v1(bytea, timestamptz, text, text, bytea, bytea, bigint, bytea, bigint, bigint, bigint)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.allocate_project_revision_v1(bytea, timestamptz, text, text, text, text, bytea, bytea, bigint, bytea, bigint, bigint, bigint)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.configure_project_raw_archive_v1(bytea, timestamptz, text, bytea, bigint, bigint)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.allocate_project_raw_archive_v1(bytea, timestamptz, text, text, bytea, bytea, bigint, bytea, bytea, bigint, bigint, bigint)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.project_sync_public_upload_status_v1(uuid, text)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.complete_project_upload_v1(bytea, timestamptz, text)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.read_project_upload_status_v1(bytea, timestamptz, text)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.allocate_project_recovery_v1(bytea, timestamptz, text, text)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.resolve_project_recovery_storage_v1(bytea, timestamptz, text, text)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.acquire_project_edit_lease_v1(bytea, timestamptz, text, bytea, bytea, bytea, bigint, bigint)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.renew_project_edit_lease_v1(bytea, timestamptz, text, bytea, bigint, bigint)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.release_project_edit_lease_v1(bytea, timestamptz, text, bytea, bigint, bigint)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.project_sync_require_worker_v1()
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.reap_expired_project_upload_v1(timestamptz)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.claim_next_project_validation_v1(timestamptz)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.release_project_upload_v1(uuid, text, timestamptz)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.reject_project_upload_v1(uuid, text, timestamptz, text)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.finalize_project_upload_v1(uuid, text, timestamptz, text, text)
  OWNER TO roomscan_policy;

REVOKE ALL ON ALL TABLES IN SCHEMA roomscan FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA roomscan FROM PUBLIC;
REVOKE ALL ON roomscan.professional_projects, roomscan.project_uploads,
  roomscan.project_revisions, roomscan.project_raw_archives,
  roomscan.project_edit_leases FROM roomscan_api_runtime, roomscan_project_sync_runtime;

-- The policy owner is the sole definer used by Slice 5 reducers.  These are
-- narrow table privileges; LOGIN roles retain no direct relation access.
GRANT SELECT, INSERT, UPDATE ON roomscan.professional_projects,
  roomscan.project_uploads, roomscan.project_revisions,
  roomscan.project_raw_archives, roomscan.project_edit_leases TO roomscan_policy;
GRANT SELECT, INSERT ON roomscan.projects TO roomscan_policy;
GRANT SELECT, INSERT, UPDATE ON roomscan.quota_usage_v2,
  roomscan.quota_reservations_v2 TO roomscan_policy;
GRANT SELECT, INSERT ON roomscan.quota_ledger_v2 TO roomscan_policy;
GRANT SELECT, INSERT, UPDATE ON roomscan.audit_states TO roomscan_policy;
GRANT SELECT, INSERT ON roomscan.audit_events TO roomscan_policy;
GRANT SELECT ON roomscan.global_operational_flags,
  roomscan.workspace_operational_flags, roomscan.projects TO roomscan_policy;

GRANT EXECUTE ON FUNCTION
  roomscan.allocate_project_migration_v1(bytea, timestamptz, text, text, bytea, bytea, bigint, bytea, bigint, bigint, bigint),
  roomscan.allocate_project_revision_v1(bytea, timestamptz, text, text, text, text, bytea, bytea, bigint, bytea, bigint, bigint, bigint),
  roomscan.complete_project_upload_v1(bytea, timestamptz, text),
  roomscan.read_project_upload_status_v1(bytea, timestamptz, text),
  roomscan.allocate_project_recovery_v1(bytea, timestamptz, text, text),
  roomscan.resolve_project_recovery_storage_v1(bytea, timestamptz, text, text),
  roomscan.configure_project_raw_archive_v1(bytea, timestamptz, text, bytea, bigint, bigint),
  roomscan.allocate_project_raw_archive_v1(bytea, timestamptz, text, text, bytea, bytea, bigint, bytea, bytea, bigint, bigint, bigint),
  roomscan.acquire_project_edit_lease_v1(bytea, timestamptz, text, bytea, bytea, bytea, bigint, bigint),
  roomscan.renew_project_edit_lease_v1(bytea, timestamptz, text, bytea, bigint, bigint),
  roomscan.release_project_edit_lease_v1(bytea, timestamptz, text, bytea, bigint, bigint)
TO roomscan_api_runtime;

GRANT EXECUTE ON FUNCTION
  roomscan.reap_expired_project_upload_v1(timestamptz),
  roomscan.claim_next_project_validation_v1(timestamptz),
  roomscan.release_project_upload_v1(uuid, text, timestamptz),
  roomscan.reject_project_upload_v1(uuid, text, timestamptz, text),
  roomscan.finalize_project_upload_v1(uuid, text, timestamptz, text, text)
TO roomscan_project_sync_runtime;

COMMENT ON FUNCTION roomscan.allocate_project_migration_v1(bytea, timestamptz, text, text, bytea, bytea, bigint, bytea, bigint, bigint, bigint) IS
  'Slice 5 access-derived initial-project allocation: server-minted opaque IDs and immutable keys, v2 project-count plus working-byte reservation, no generic/professional project shell before validator finalization, exact retry, PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.allocate_project_revision_v1(bytea, timestamptz, text, text, text, text, bytea, bytea, bigint, bytea, bigint, bigint, bigint) IS
  'Slice 5 access-derived immutable append allocation: current hosted head/source binding is checked at allocation and stored for one later CAS; it never mutates a head, PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.complete_project_upload_v1(bytea, timestamptz, text) IS
  'Slice 5 opaque upload completion: only allocated-to-validation_pending, no caller object key/version/tenant/head/validator input, exact retry, PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.claim_next_project_validation_v1(timestamptz) IS
  'Slice 5 worker-only targetless oldest eligible validation claim with SKIP LOCKED, a 900-second server-time lease, and locked authoritative project/revision source bindings; allocated uploads are never claimed, PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.finalize_project_upload_v1(uuid, text, timestamptz, text, text) IS
  'Slice 5 worker-only immutable promotion finalizer: one expected-head CAS yields canonical or retained stale branch; raw attachment never moves the head; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.reap_expired_project_upload_v1(timestamptz) IS
  'Slice 5 worker-only allocated-upload expiry reaper: releases durable v2 reservations and retains a rejected idempotency tombstone; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.configure_project_raw_archive_v1(bytea, timestamptz, text, bytea, bigint, bigint) IS
  'Slice 5 recent-owner raw-archive review configuration. The digest is bounded evidence only; raw bytes remain a separate attachment tier, PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.acquire_project_edit_lease_v1(bytea, timestamptz, text, bytea, bytea, bytea, bigint, bigint) IS
  'Slice 5 advisory one-editor lease with caller-held unguessable token digest, exact retry, and a fixed 900-second server-time expiry. It grants no CAS authority, PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.project_sync_resolve_access_v1(bytea, timestamptz, text[], boolean) IS
  'Slice 5 internal access-token resolver. It derives the authoritative workspace and role from the token and can require recent authentication; callers cannot supply a tenant, PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.project_sync_require_grant_v1(uuid, text, bigint, bigint) IS
  'Slice 5 internal hosted-operation flag/version guard. It accepts only the narrow project-sync actions and delegates to the policy-owned grant predicate, PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.project_sync_append_audit_v1(uuid, uuid, text, text, timestamptz) IS
  'Slice 5 internal audit append that stores bounded public upload subjects only; it never records object keys, UUIDs, or storage versions, PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.project_sync_release_quota_v1(uuid, text, text, bigint, text, timestamptz) IS
  'Slice 5 internal worker quota-release helper for targetless validation cleanup. It is policy-owned and not an access-token reducer, PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.project_sync_finalize_quota_v1(uuid, text, text, bigint, timestamptz) IS
  'Slice 5 internal worker quota-finalization helper for targetless validator promotion. It is policy-owned and not an access-token reducer, PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.project_sync_release_upload_quotas_v1(roomscan.project_uploads, text, timestamptz) IS
  'Slice 5 internal dual-reservation release helper for rejected, expired, or stale project uploads, PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.project_sync_finalize_upload_quotas_v1(roomscan.project_uploads, timestamptz) IS
  'Slice 5 internal dual-reservation finalization helper for promoted project uploads, PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.project_sync_current_head_public_id_v1(uuid, uuid) IS
  'Slice 5 internal public-head projection. It resolves only an opaque revision ID and never exposes storage metadata, PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.allocate_project_raw_archive_v1(bytea, timestamptz, text, text, bytea, bytea, bigint, bytea, bytea, bigint, bigint, bigint) IS
  'Slice 5 reviewed raw-archive allocation. It is separate from working revision head promotion and returns only opaque IDs, digests, sizes, and expiry, PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.project_sync_public_upload_status_v1(uuid, text) IS
  'Slice 5 internal status projection for an upload. It omits internal UUIDs, object keys, and storage versions, PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.read_project_upload_status_v1(bytea, timestamptz, text) IS
  'Slice 5 access-token-scoped upload-status reader returning only opaque IDs, digests, sizes, state, and expiry, PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.allocate_project_recovery_v1(bytea, timestamptz, text, text) IS
  'Slice 5 stateless access-token-scoped recovery projection. It selects an immutable branch without staging or mutating a live project, PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.resolve_project_recovery_storage_v1(bytea, timestamptz, text, text) IS
  'Slice 5 trusted post-commit recovery storage resolver. It re-derives access tenant and membership, returns only the exact persisted logical working binding for an authorized canonical or stale revision, and is not a public HTTP result, PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.renew_project_edit_lease_v1(bytea, timestamptz, text, bytea, bigint, bigint) IS
  'Slice 5 advisory lease renewal. It requires the existing token digest and renews for exactly 900 seconds of server time, PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.release_project_edit_lease_v1(bytea, timestamptz, text, bytea, bigint, bigint) IS
  'Slice 5 advisory lease release. It requires the token digest, changes no revision head, and exposes no storage metadata, PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.project_sync_require_worker_v1() IS
  'Slice 5 internal worker-lane gate requiring the dedicated non-inheriting project-sync runtime login role, PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.release_project_upload_v1(uuid, text, timestamptz) IS
  'Slice 5 worker-only upload release that clears a validation lease without changing immutable candidate content or a project head, PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.reject_project_upload_v1(uuid, text, timestamptz, text) IS
  'Slice 5 worker-only rejection that retains the immutable allocation tombstone and releases reservations without deleting local or hosted branches, PUBLIC revoked.';

RESET ROLE;
