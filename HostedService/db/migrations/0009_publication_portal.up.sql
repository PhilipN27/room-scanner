-- Slice 6 immutable publication, portal, and feedback authority.  This
-- migration is forward-only.  Private Slice 5 project/revision records remain
-- the source of truth; the tables below contain only a separately approved
-- publication projection and its server-side delivery controls.
-- Every `authoritative_time` parameter below is a deterministic controlled
-- server-runtime clock seam for service/worker/portal reducers.  Function ACLs
-- deliberately grant no browser/native (`roomscan_app`) or PUBLIC direct SQL
-- path; Task 4 derives this value from its service clock.

CREATE ROLE roomscan_publication_worker
  LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
CREATE ROLE roomscan_portal_runtime
  LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;

REVOKE roomscan_owner, roomscan_policy, roomscan_app,
  roomscan_api_runtime, roomscan_project_sync_runtime
  FROM roomscan_publication_worker;
REVOKE roomscan_owner, roomscan_policy, roomscan_app,
  roomscan_api_runtime, roomscan_project_sync_runtime
  FROM roomscan_portal_runtime;
GRANT USAGE ON SCHEMA roomscan TO roomscan_publication_worker, roomscan_portal_runtime;

SET ROLE roomscan_owner;

-- Slice 6 property source bindings need a database-enforced relationship
-- between one hosted project and one hosted canonical revision. Slice 5
-- already owns these rows; this additive candidate key lets the publication
-- projection reference their same-tenant provenance without widening any
-- private-sync capability.
ALTER TABLE roomscan.project_revisions
  ADD CONSTRAINT project_revisions_workspace_revision_project_unique
  UNIQUE (workspace_id, id, project_id);

CREATE TABLE roomscan.publication_properties (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE RESTRICT,
  property_id uuid NOT NULL,
  public_id text NOT NULL CHECK (public_id ~ '^prop_[A-Za-z0-9_-]{16,128}$'),
  title text NOT NULL CHECK (length(title) BETWEEN 1 AND 180),
  created_by_principal_id uuid NOT NULL REFERENCES roomscan.principals(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  -- v2 property creation retries store only a server-HMAC'd opaque identity.
  -- The nullable shape preserves rows created by the compatibility v1 helper;
  -- the v2 API requires it on every new property.
  create_idempotency_digest bytea CHECK (
    create_idempotency_digest IS NULL OR octet_length(create_idempotency_digest) = 32
  ),
  version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
  PRIMARY KEY (workspace_id, property_id),
  UNIQUE (public_id),
  UNIQUE (workspace_id, public_id),
  UNIQUE (workspace_id, created_by_principal_id, create_idempotency_digest)
);

-- Property membership is mutable owner curation of independently hosted room
-- projects. It deliberately contains no transform, origin, adjacency,
-- connectivity, or reconstruction field. The exact canonical revisions are
-- captured later in publication_allocation_source_bindings at review time.
CREATE TABLE roomscan.publication_property_rooms (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE RESTRICT,
  property_id uuid NOT NULL,
  room_order integer NOT NULL CHECK (room_order > 0 AND room_order <= 1000),
  room_key text NOT NULL CHECK (
    length(room_key) BETWEEN 1 AND 128 AND room_key ~ '^[A-Za-z0-9_.-]+$'
  ),
  room_project_id uuid NOT NULL,
  room_project_public_id text NOT NULL CHECK (
    room_project_public_id ~ '^prj_[A-Za-z0-9_-]{16,128}$'
  ),
  added_at timestamptz NOT NULL,
  PRIMARY KEY (workspace_id, property_id, room_order),
  CONSTRAINT publication_property_rooms_room_key_unique
    UNIQUE (workspace_id, property_id, room_key),
  CONSTRAINT publication_property_rooms_project_unique
    UNIQUE (workspace_id, property_id, room_project_id),
  FOREIGN KEY (workspace_id, property_id)
    REFERENCES roomscan.publication_properties(workspace_id, property_id) ON DELETE RESTRICT,
  FOREIGN KEY (workspace_id, room_project_id)
    REFERENCES roomscan.professional_projects(workspace_id, project_id) ON DELETE RESTRICT
);

CREATE TABLE roomscan.publication_allocations (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE RESTRICT,
  allocation_id uuid NOT NULL,
  allocation_public_id text NOT NULL CHECK (
    allocation_public_id ~ '^pua_[A-Za-z0-9_-]{16,128}$'
  ),
  project_id uuid NOT NULL,
  source_revision_id uuid NOT NULL,
  source_revision_public_id text NOT NULL CHECK (
    length(source_revision_public_id) BETWEEN 1 AND 128
    AND source_revision_public_id ~ '^[A-Za-z0-9_-]+$'
  ),
  source_revision_digest bytea NOT NULL CHECK (octet_length(source_revision_digest) = 32),
  source_manifest_digest bytea NOT NULL CHECK (octet_length(source_manifest_digest) = 32),
  source_bindings_digest bytea NOT NULL CHECK (octet_length(source_bindings_digest) = 32),
  selection_digest bytea NOT NULL CHECK (octet_length(selection_digest) = 32),
  approval_digest bytea NOT NULL CHECK (octet_length(approval_digest) = 32),
  publication_kind text NOT NULL CHECK (publication_kind IN ('room', 'property')),
  property_id uuid,
  -- The server captures an exact ordered draft membership digest at allocation.
  -- It is rechecked before the immutable property snapshot is frozen.
  property_membership_digest bytea CHECK (
    property_membership_digest IS NULL OR octet_length(property_membership_digest) = 32
  ),
  property_curation_version bigint,
  archive_manifest_digest bytea NOT NULL CHECK (octet_length(archive_manifest_digest) = 32),
  archive_digest bytea NOT NULL CHECK (octet_length(archive_digest) = 32),
  archive_bytes bigint NOT NULL CHECK (archive_bytes > 0 AND archive_bytes <= 805306368),
  idempotency_digest bytea NOT NULL CHECK (octet_length(idempotency_digest) = 32),
  state text NOT NULL DEFAULT 'allocated' CHECK (
    state IN ('allocated', 'validation_pending', 'validating', 'published', 'rejected')
  ),
  quarantine_key text NOT NULL CHECK (
    quarantine_key ~ '^server/published/quarantine/v1/pua_[A-Za-z0-9_-]{16,128}[.]zip$'
  ),
  quarantine_version text CHECK (
    quarantine_version IS NULL OR (
      length(quarantine_version) BETWEEN 1 AND 1024
      AND quarantine_version !~ '[[:cntrl:]]'
    )
  ),
  active_object_version text CHECK (
    active_object_version IS NULL OR (
      length(active_object_version) BETWEEN 1 AND 1024
      AND active_object_version !~ '[[:cntrl:]]'
    )
  ),
  created_by_principal_id uuid NOT NULL REFERENCES roomscan.principals(id) ON DELETE RESTRICT,
  created_role text NOT NULL CHECK (created_role IN ('owner', 'admin', 'editor')),
  created_authorization_version bigint NOT NULL CHECK (created_authorization_version > 0),
  hosted_global_version bigint NOT NULL CHECK (hosted_global_version > 0),
  hosted_workspace_version bigint NOT NULL CHECK (hosted_workspace_version > 0),
  publication_global_version bigint NOT NULL CHECK (publication_global_version > 0),
  publication_workspace_version bigint NOT NULL CHECK (publication_workspace_version > 0),
  quota_policy_version bigint NOT NULL CHECK (quota_policy_version > 0),
  allocation_expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  PRIMARY KEY (workspace_id, allocation_id),
  UNIQUE (allocation_public_id),
  UNIQUE (workspace_id, allocation_public_id),
  UNIQUE (workspace_id, created_by_principal_id, idempotency_digest),
  FOREIGN KEY (workspace_id, project_id)
    REFERENCES roomscan.professional_projects(workspace_id, project_id) ON DELETE RESTRICT,
  FOREIGN KEY (workspace_id, source_revision_id)
    REFERENCES roomscan.project_revisions(workspace_id, id) ON DELETE RESTRICT,
  -- The root revision must belong to the root hosted project, not merely the
  -- same workspace.  The reducer repeats this check so corrupted rows fail
  -- closed before a worker can make an immutable snapshot public.
  FOREIGN KEY (workspace_id, source_revision_id, project_id)
    REFERENCES roomscan.project_revisions(workspace_id, id, project_id) ON DELETE RESTRICT,
  FOREIGN KEY (workspace_id, property_id)
    REFERENCES roomscan.publication_properties(workspace_id, property_id) ON DELETE RESTRICT,
  CHECK ((publication_kind = 'room') = (property_id IS NULL)),
  CHECK ((publication_kind = 'property') = (property_id IS NOT NULL)),
  CHECK ((publication_kind = 'property') = (property_membership_digest IS NOT NULL)),
  CHECK ((publication_kind = 'property') = (property_curation_version IS NOT NULL)),
  CHECK (created_at < allocation_expires_at),
  -- An allocated row has no uploaded object. Targetless API completion only
  -- queues validation; the claimed publication worker alone binds the exact
  -- version returned by the versioned quarantine bucket before validation.
  -- A terminal rejection is permitted before that bind so a killed/expired
  -- allocation does not need to invent a storage version.
  CHECK ((state = 'allocated'
    AND quarantine_version IS NULL AND active_object_version IS NULL)
    OR (state = 'validation_pending'
      AND quarantine_version IS NULL AND active_object_version IS NULL)
    OR (state IN ('validating', 'rejected')
      AND active_object_version IS NULL)
    OR (state = 'published'
      AND quarantine_version IS NOT NULL AND active_object_version IS NOT NULL))
);

-- These two rows are the server-only proof that a publication was reviewed
-- against one immutable source and one exact selected-artifact/manifest set.
CREATE TABLE roomscan.publication_sources (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE RESTRICT,
  source_id uuid NOT NULL,
  allocation_id uuid NOT NULL,
  source_revision_id uuid NOT NULL,
  source_revision_public_id text NOT NULL,
  source_revision_digest bytea NOT NULL CHECK (octet_length(source_revision_digest) = 32),
  source_manifest_digest bytea NOT NULL CHECK (octet_length(source_manifest_digest) = 32),
  source_bindings_digest bytea NOT NULL CHECK (octet_length(source_bindings_digest) = 32),
  selection_digest bytea NOT NULL CHECK (octet_length(selection_digest) = 32),
  property_membership_digest bytea CHECK (
    property_membership_digest IS NULL OR octet_length(property_membership_digest) = 32
  ),
  captured_at timestamptz NOT NULL,
  PRIMARY KEY (workspace_id, source_id),
  UNIQUE (workspace_id, allocation_id),
  FOREIGN KEY (workspace_id, allocation_id)
    REFERENCES roomscan.publication_allocations(workspace_id, allocation_id) ON DELETE RESTRICT,
  FOREIGN KEY (workspace_id, source_revision_id)
    REFERENCES roomscan.project_revisions(workspace_id, id) ON DELETE RESTRICT
);

CREATE TABLE roomscan.publication_approvals (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE RESTRICT,
  approval_id uuid NOT NULL,
  allocation_id uuid NOT NULL,
  source_revision_id uuid NOT NULL,
  source_revision_public_id text NOT NULL,
  source_revision_digest bytea NOT NULL CHECK (octet_length(source_revision_digest) = 32),
  source_manifest_digest bytea NOT NULL CHECK (octet_length(source_manifest_digest) = 32),
  source_bindings_digest bytea NOT NULL CHECK (octet_length(source_bindings_digest) = 32),
  selection_digest bytea NOT NULL CHECK (octet_length(selection_digest) = 32),
  approval_digest bytea NOT NULL CHECK (octet_length(approval_digest) = 32),
  property_membership_digest bytea CHECK (
    property_membership_digest IS NULL OR octet_length(property_membership_digest) = 32
  ),
  approved_by_principal_id uuid NOT NULL REFERENCES roomscan.principals(id) ON DELETE RESTRICT,
  approved_role text NOT NULL CHECK (approved_role IN ('owner', 'admin', 'editor')),
  approved_authorization_version bigint NOT NULL CHECK (approved_authorization_version > 0),
  disclosure_reviewed_at timestamptz NOT NULL,
  PRIMARY KEY (workspace_id, approval_id),
  UNIQUE (workspace_id, allocation_id),
  FOREIGN KEY (workspace_id, allocation_id)
    REFERENCES roomscan.publication_allocations(workspace_id, allocation_id) ON DELETE RESTRICT
);

CREATE TABLE roomscan.publication_jobs (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE RESTRICT,
  job_id uuid NOT NULL,
  allocation_id uuid NOT NULL,
  state text NOT NULL DEFAULT 'pending' CHECK (
    state IN ('pending', 'claimed', 'completed', 'rejected')
  ),
  lease_id text CHECK (
    lease_id IS NULL OR lease_id ~ '^pwl_[A-Za-z0-9_-]{16,128}$'
  ),
  lease_expires_at timestamptz,
  rejection_code text CHECK (
    rejection_code IS NULL OR rejection_code IN (
      'allocation_expired', 'source_changed', 'approval_changed',
      'invalid_archive', 'publication_disabled', 'quota_unavailable'
    )
  ),
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  PRIMARY KEY (workspace_id, job_id),
  UNIQUE (workspace_id, allocation_id),
  FOREIGN KEY (workspace_id, allocation_id)
    REFERENCES roomscan.publication_allocations(workspace_id, allocation_id) ON DELETE RESTRICT,
  CHECK ((state = 'pending' AND lease_id IS NULL AND lease_expires_at IS NULL AND rejection_code IS NULL)
    OR (state = 'claimed' AND lease_id IS NOT NULL AND lease_expires_at IS NOT NULL AND rejection_code IS NULL)
    OR (state = 'completed' AND lease_id IS NULL AND lease_expires_at IS NULL AND rejection_code IS NULL)
    OR (state = 'rejected' AND lease_id IS NULL AND lease_expires_at IS NULL AND rejection_code IS NOT NULL))
);

CREATE TABLE roomscan.publication_snapshots (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE RESTRICT,
  snapshot_id uuid NOT NULL,
  public_id text NOT NULL CHECK (public_id ~ '^snp_[A-Za-z0-9_-]{16,128}$'),
  allocation_id uuid NOT NULL,
  project_id uuid NOT NULL,
  source_revision_id uuid NOT NULL,
  source_revision_public_id text NOT NULL,
  source_revision_digest bytea NOT NULL CHECK (octet_length(source_revision_digest) = 32),
  source_manifest_digest bytea NOT NULL CHECK (octet_length(source_manifest_digest) = 32),
  source_bindings_digest bytea NOT NULL CHECK (octet_length(source_bindings_digest) = 32),
  selection_digest bytea NOT NULL CHECK (octet_length(selection_digest) = 32),
  approval_digest bytea NOT NULL CHECK (octet_length(approval_digest) = 32),
  archive_manifest_digest bytea NOT NULL CHECK (octet_length(archive_manifest_digest) = 32),
  archive_digest bytea NOT NULL CHECK (octet_length(archive_digest) = 32),
  archive_bytes bigint NOT NULL CHECK (archive_bytes > 0 AND archive_bytes <= 805306368),
  presentation_digest bytea NOT NULL CHECK (octet_length(presentation_digest) = 32),
  presentation_bytes bigint NOT NULL CHECK (presentation_bytes > 0 AND presentation_bytes <= 8388608),
  publication_kind text NOT NULL CHECK (publication_kind IN ('room', 'property')),
  property_id uuid,
  property_membership_digest bytea CHECK (
    property_membership_digest IS NULL OR octet_length(property_membership_digest) = 32
  ),
  published_at timestamptz NOT NULL,
  PRIMARY KEY (workspace_id, snapshot_id),
  UNIQUE (public_id),
  UNIQUE (workspace_id, public_id),
  UNIQUE (workspace_id, allocation_id),
  UNIQUE (workspace_id, snapshot_id, source_revision_id),
  FOREIGN KEY (workspace_id, allocation_id)
    REFERENCES roomscan.publication_allocations(workspace_id, allocation_id) ON DELETE RESTRICT,
  FOREIGN KEY (workspace_id, source_revision_id)
    REFERENCES roomscan.project_revisions(workspace_id, id) ON DELETE RESTRICT,
  FOREIGN KEY (workspace_id, source_revision_id, project_id)
    REFERENCES roomscan.project_revisions(workspace_id, id, project_id) ON DELETE RESTRICT,
  FOREIGN KEY (workspace_id, property_id)
    REFERENCES roomscan.publication_properties(workspace_id, property_id) ON DELETE RESTRICT,
  CHECK ((publication_kind = 'room') = (property_id IS NULL)),
  CHECK ((publication_kind = 'property') = (property_id IS NOT NULL)),
  CHECK ((publication_kind = 'property') = (property_membership_digest IS NOT NULL))
);

-- Draft curation remains mutable. A property presentation receives a frozen
-- multi-source copy only during finalization; portal navigation never reads
-- this draft table.
CREATE TABLE roomscan.publication_snapshot_rooms (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE RESTRICT,
  property_snapshot_id uuid NOT NULL,
  room_order integer NOT NULL CHECK (room_order > 0 AND room_order <= 1000),
  room_key text NOT NULL CHECK (
    length(room_key) BETWEEN 1 AND 128 AND room_key ~ '^[A-Za-z0-9_.-]+$'
  ),
  room_project_id uuid NOT NULL,
  room_project_public_id text NOT NULL CHECK (
    room_project_public_id ~ '^prj_[A-Za-z0-9_-]{16,128}$'
  ),
  source_revision_id uuid NOT NULL,
  source_revision_public_id text NOT NULL CHECK (
    source_revision_public_id ~ '^rev_[A-Za-z0-9_-]{16,128}$'
  ),
  source_revision_digest bytea NOT NULL CHECK (octet_length(source_revision_digest) = 32),
  source_manifest_digest bytea NOT NULL CHECK (octet_length(source_manifest_digest) = 32),
  frozen_at timestamptz NOT NULL,
  PRIMARY KEY (workspace_id, property_snapshot_id, room_order),
  UNIQUE (workspace_id, property_snapshot_id, room_key),
  UNIQUE (workspace_id, property_snapshot_id, room_project_id),
  FOREIGN KEY (workspace_id, property_snapshot_id)
    REFERENCES roomscan.publication_snapshots(workspace_id, snapshot_id) ON DELETE RESTRICT,
  FOREIGN KEY (workspace_id, room_project_id)
    REFERENCES roomscan.professional_projects(workspace_id, project_id) ON DELETE RESTRICT,
  -- Composite provenance means a frozen row cannot point at a revision from a
  -- different tenant or attach that revision to the wrong room project.
  FOREIGN KEY (workspace_id, source_revision_id, room_project_id)
    REFERENCES roomscan.project_revisions(
      workspace_id, id, project_id
    ) ON DELETE RESTRICT
);

-- The allocation captures the Core source-binding identity separately from
-- portal data. The aggregate digest remains opaque here because the worker
-- verifies Core's canonical JSON bytes; these rows prove that every binding
-- was same-tenant, current-canonical, and frozen before public finalization.
CREATE TABLE roomscan.publication_allocation_source_bindings (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE RESTRICT,
  allocation_id uuid NOT NULL,
  room_order integer NOT NULL CHECK (room_order > 0 AND room_order <= 64),
  public_room_key text NOT NULL CHECK (
    length(public_room_key) BETWEEN 1 AND 128
    AND public_room_key ~ '^[A-Za-z0-9_.-]+$'
  ),
  room_project_id uuid NOT NULL,
  room_project_public_id text NOT NULL CHECK (
    room_project_public_id ~ '^prj_[A-Za-z0-9_-]{16,128}$'
  ),
  source_revision_id uuid NOT NULL,
  source_revision_public_id text NOT NULL CHECK (
    source_revision_public_id ~ '^rev_[A-Za-z0-9_-]{16,128}$'
  ),
  local_project_id text NOT NULL CHECK (
    length(local_project_id) BETWEEN 1 AND 128
    AND local_project_id ~ '^[A-Za-z0-9_.-]+$'
  ),
  local_revision_id text NOT NULL CHECK (
    length(local_revision_id) BETWEEN 1 AND 128
    AND local_revision_id ~ '^[A-Za-z0-9_.-]+$'
  ),
  coordinate_space_epoch_id text NOT NULL CHECK (
    length(coordinate_space_epoch_id) BETWEEN 1 AND 128
    AND coordinate_space_epoch_id ~ '^[A-Za-z0-9_.-]+$'
  ),
  package_schema_version text NOT NULL CHECK (
    package_schema_version IN ('room-scan-project-v1', 'room-scan-project-v2')
  ),
  semantic_sha256 bytea NOT NULL CHECK (octet_length(semantic_sha256) = 32),
  revision_manifest_sha256 bytea NOT NULL CHECK (octet_length(revision_manifest_sha256) = 32),
  working_digest bytea NOT NULL CHECK (octet_length(working_digest) = 32),
  working_manifest_digest bytea NOT NULL CHECK (octet_length(working_manifest_digest) = 32),
  captured_at timestamptz NOT NULL,
  PRIMARY KEY (workspace_id, allocation_id, room_order),
  UNIQUE (workspace_id, allocation_id, public_room_key),
  UNIQUE (workspace_id, allocation_id, room_project_id),
  FOREIGN KEY (workspace_id, allocation_id)
    REFERENCES roomscan.publication_allocations(workspace_id, allocation_id) ON DELETE RESTRICT,
  FOREIGN KEY (workspace_id, room_project_id)
    REFERENCES roomscan.professional_projects(workspace_id, project_id) ON DELETE RESTRICT,
  FOREIGN KEY (workspace_id, source_revision_id, room_project_id)
    REFERENCES roomscan.project_revisions(workspace_id, id, project_id) ON DELETE RESTRICT
);

CREATE TABLE roomscan.publication_assets (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE RESTRICT,
  asset_id uuid NOT NULL,
  public_id text NOT NULL CHECK (public_id ~ '^ast_[A-Za-z0-9_-]{16,128}$'),
  snapshot_id uuid NOT NULL,
  asset_kind text NOT NULL CHECK (asset_kind IN (
    'presentation', 'web_geometry', 'web_texture', 'selected_image',
    'floor_plan', 'approved_concept', 'floor_plan_pdf', 'gallery_zip',
    'ai_ready_package'
  )),
  download_kind text CHECK (
    download_kind IS NULL OR download_kind IN ('floor_plan_pdf', 'gallery_zip', 'ai_ready_package')
  ),
  object_key text NOT NULL CHECK (
    length(object_key) BETWEEN 1 AND 1024
    AND object_key ~ '^server/published/active/v1/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+[.]bin$'
    AND object_key !~ '[.][.]'
  ),
  object_version text NOT NULL CHECK (
    length(object_version) BETWEEN 1 AND 1024 AND object_version !~ '[[:cntrl:]]'
  ),
  content_type text NOT NULL CHECK (
    content_type IN ('application/json', 'image/png', 'image/jpeg', 'application/pdf', 'application/zip')
  ),
  digest bytea NOT NULL CHECK (octet_length(digest) = 32),
  bytes bigint NOT NULL CHECK (
    bytes > 0 AND (
      (asset_kind IN ('presentation', 'web_geometry') AND bytes <= 8388608)
      OR (asset_kind = 'ai_ready_package' AND bytes <= 536870912)
      OR (asset_kind NOT IN ('presentation', 'web_geometry', 'ai_ready_package') AND bytes <= 33554432)
    )
  ),
  created_at timestamptz NOT NULL,
  PRIMARY KEY (workspace_id, asset_id),
  UNIQUE (public_id),
  UNIQUE (workspace_id, public_id),
  UNIQUE (workspace_id, snapshot_id, object_key),
  FOREIGN KEY (workspace_id, snapshot_id)
    REFERENCES roomscan.publication_snapshots(workspace_id, snapshot_id) ON DELETE RESTRICT,
  CHECK (
    (asset_kind = 'floor_plan_pdf' AND download_kind = 'floor_plan_pdf' AND content_type = 'application/pdf')
    OR (asset_kind = 'gallery_zip' AND download_kind = 'gallery_zip' AND content_type = 'application/zip')
    OR (asset_kind = 'ai_ready_package' AND download_kind = 'ai_ready_package' AND content_type = 'application/zip')
    OR (asset_kind NOT IN ('floor_plan_pdf', 'gallery_zip', 'ai_ready_package') AND download_kind IS NULL)
  )
);

CREATE TABLE roomscan.publication_links (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE RESTRICT,
  link_id uuid NOT NULL,
  public_id text NOT NULL CHECK (public_id ~ '^lnk_[A-Za-z0-9_-]{16,128}$'),
  snapshot_id uuid NOT NULL,
  token_hash bytea NOT NULL CHECK (octet_length(token_hash) = 32),
  generation bigint NOT NULL DEFAULT 1 CHECK (generation > 0),
  state text NOT NULL DEFAULT 'active' CHECK (state IN ('active', 'revoked')),
  expires_at timestamptz NOT NULL,
  -- Preserve the caller's semantic intent separately from the resolved
  -- timestamp. An omitted default can replay after the server clock advances;
  -- an explicit owner-chosen date must match exactly.
  expiry_intent text NOT NULL DEFAULT 'default_30_days' CHECK (
    expiry_intent IN ('default_30_days', 'explicit')
  ),
  pin_salt bytea CHECK (pin_salt IS NULL OR octet_length(pin_salt) BETWEEN 16 AND 64),
  pin_verifier bytea CHECK (pin_verifier IS NULL OR octet_length(pin_verifier) = 32),
  ai_enabled boolean NOT NULL DEFAULT false,
  feedback_enabled boolean NOT NULL DEFAULT true,
  idempotency_digest bytea NOT NULL CHECK (octet_length(idempotency_digest) = 32),
  hosted_global_version bigint NOT NULL CHECK (hosted_global_version > 0),
  hosted_workspace_version bigint NOT NULL CHECK (hosted_workspace_version > 0),
  publication_global_version bigint NOT NULL CHECK (publication_global_version > 0),
  publication_workspace_version bigint NOT NULL CHECK (publication_workspace_version > 0),
  created_by_principal_id uuid NOT NULL REFERENCES roomscan.principals(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  revoked_at timestamptz,
  PRIMARY KEY (workspace_id, link_id),
  UNIQUE (public_id),
  UNIQUE (workspace_id, public_id),
  UNIQUE (token_hash),
  UNIQUE (workspace_id, created_by_principal_id, idempotency_digest),
  FOREIGN KEY (workspace_id, snapshot_id)
    REFERENCES roomscan.publication_snapshots(workspace_id, snapshot_id) ON DELETE RESTRICT,
  CHECK ((pin_salt IS NULL) = (pin_verifier IS NULL)),
  CHECK ((state = 'active' AND revoked_at IS NULL) OR (state = 'revoked' AND revoked_at IS NOT NULL)),
  CHECK (expires_at > created_at)
);

CREATE TABLE roomscan.professional_web_sessions (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE RESTRICT,
  session_id uuid NOT NULL,
  session_hash bytea NOT NULL CHECK (octet_length(session_hash) = 32),
  principal_id uuid NOT NULL REFERENCES roomscan.principals(id) ON DELETE RESTRICT,
  authorization_version bigint NOT NULL CHECK (authorization_version > 0),
  authenticated_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  state text NOT NULL DEFAULT 'active' CHECK (state IN ('active', 'revoked')),
  created_at timestamptz NOT NULL,
  revoked_at timestamptz,
  PRIMARY KEY (workspace_id, session_id),
  UNIQUE (session_hash),
  CHECK ((state = 'active' AND revoked_at IS NULL) OR (state = 'revoked' AND revoked_at IS NOT NULL))
);

CREATE TABLE roomscan.portal_sessions (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE RESTRICT,
  session_id uuid NOT NULL,
  session_hash bytea NOT NULL CHECK (octet_length(session_hash) = 32),
  link_id uuid NOT NULL,
  link_generation bigint NOT NULL CHECK (link_generation > 0),
  snapshot_id uuid NOT NULL,
  hosted_global_version bigint NOT NULL CHECK (hosted_global_version > 0),
  hosted_workspace_version bigint NOT NULL CHECK (hosted_workspace_version > 0),
  publication_global_version bigint NOT NULL CHECK (publication_global_version > 0),
  publication_workspace_version bigint NOT NULL CHECK (publication_workspace_version > 0),
  pin_required boolean NOT NULL,
  pin_verified boolean NOT NULL DEFAULT false,
  client_family text NOT NULL CHECK (client_family IN ('desktop', 'mobile', 'tablet', 'unknown')),
  network_risk_digest bytea NOT NULL CHECK (octet_length(network_risk_digest) = 32),
  state text NOT NULL DEFAULT 'active' CHECK (state IN ('pin_required', 'active', 'revoked')),
  expires_at timestamptz NOT NULL,
  last_seen_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL,
  revoked_at timestamptz,
  PRIMARY KEY (workspace_id, session_id),
  UNIQUE (session_hash),
  FOREIGN KEY (workspace_id, link_id)
    REFERENCES roomscan.publication_links(workspace_id, link_id) ON DELETE RESTRICT,
  FOREIGN KEY (workspace_id, snapshot_id)
    REFERENCES roomscan.publication_snapshots(workspace_id, snapshot_id) ON DELETE RESTRICT,
  -- Rotation/revocation preserves the historical PIN fields while changing
  -- only terminal state. Active and PIN-required rows still have exact live
  -- invariants; a revoked row only needs its immutable revocation timestamp.
  CHECK (
    (state = 'pin_required' AND pin_required AND NOT pin_verified)
    OR (state = 'active' AND (NOT pin_required OR pin_verified) AND revoked_at IS NULL)
    OR (state = 'revoked' AND revoked_at IS NOT NULL)
  )
);

CREATE TABLE roomscan.portal_pin_throttles (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE RESTRICT,
  link_id uuid NOT NULL,
  link_generation bigint NOT NULL CHECK (link_generation > 0),
  window_started_at timestamptz,
  failed_attempts integer NOT NULL DEFAULT 0 CHECK (failed_attempts BETWEEN 0 AND 5),
  cooldown_until timestamptz,
  updated_at timestamptz NOT NULL,
  PRIMARY KEY (workspace_id, link_id, link_generation),
  FOREIGN KEY (workspace_id, link_id)
    REFERENCES roomscan.publication_links(workspace_id, link_id) ON DELETE RESTRICT,
  CHECK ((failed_attempts = 0 AND window_started_at IS NULL)
    OR (failed_attempts > 0 AND window_started_at IS NOT NULL)),
  CHECK (cooldown_until IS NULL OR window_started_at IS NOT NULL)
);

CREATE TABLE roomscan.portal_feedback_challenges (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE RESTRICT,
  challenge_id uuid NOT NULL,
  challenge_hash bytea NOT NULL CHECK (octet_length(challenge_hash) = 32),
  -- This is committed by the delivery service at issuance. Consumption only
  -- compares a presented hash and can never substitute a verifier.
  verification_token_hash bytea NOT NULL CHECK (octet_length(verification_token_hash) = 32),
  session_id uuid NOT NULL,
  link_id uuid NOT NULL,
  link_generation bigint NOT NULL CHECK (link_generation > 0),
  snapshot_id uuid NOT NULL,
  verified_email_digest bytea NOT NULL CHECK (octet_length(verified_email_digest) = 32),
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz,
  feedback_used_at timestamptz,
  created_at timestamptz NOT NULL,
  PRIMARY KEY (workspace_id, challenge_id),
  UNIQUE (challenge_hash),
  UNIQUE (verification_token_hash),
  FOREIGN KEY (workspace_id, session_id)
    REFERENCES roomscan.portal_sessions(workspace_id, session_id) ON DELETE RESTRICT,
  FOREIGN KEY (workspace_id, link_id)
    REFERENCES roomscan.publication_links(workspace_id, link_id) ON DELETE RESTRICT,
  FOREIGN KEY (workspace_id, snapshot_id)
    REFERENCES roomscan.publication_snapshots(workspace_id, snapshot_id) ON DELETE RESTRICT
);

-- Feedback verification delivery is a separate sealed outbox.  It has no
-- plaintext address/code columns: only the email-runtime role can receive the
-- bounded encrypted envelope through lifecycle reducers.  The exact portal
-- session/link-generation/snapshot tuple is repeated so every worker phase can
-- close over the original accountless scope without a bearer or email lookup.
CREATE TABLE roomscan.portal_feedback_delivery_outbox (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE RESTRICT,
  delivery_id text NOT NULL CHECK (
    delivery_id ~ '^pfd_[A-Za-z0-9_-]{16,128}$'
  ),
  challenge_id uuid NOT NULL,
  session_id uuid NOT NULL,
  link_id uuid NOT NULL,
  link_generation bigint NOT NULL CHECK (link_generation > 0),
  snapshot_id uuid NOT NULL,
  envelope_version text NOT NULL CHECK (envelope_version = 'aes-256-gcm-v1'),
  key_id text NOT NULL CHECK (
    length(key_id) BETWEEN 1 AND 64 AND key_id ~ '^[A-Za-z0-9._-]+$'
  ),
  iv bytea NOT NULL CHECK (octet_length(iv) = 12),
  ciphertext bytea NOT NULL CHECK (octet_length(ciphertext) BETWEEN 1 AND 4096),
  authentication_tag bytea NOT NULL CHECK (octet_length(authentication_tag) = 16),
  created_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  state text NOT NULL DEFAULT 'pending' CHECK (
    state IN ('pending', 'leased', 'delivered', 'expired', 'cancelled')
  ),
  delivery_attempts integer NOT NULL DEFAULT 0 CHECK (delivery_attempts >= 0 AND delivery_attempts <= 100),
  lease_id text CHECK (
    lease_id IS NULL OR (
      length(lease_id) BETWEEN 1 AND 128 AND lease_id ~ '^[A-Za-z0-9_-]+$'
    )
  ),
  lease_expires_at timestamptz,
  delivered_at timestamptz,
  cancelled_at timestamptz,
  cancellation_reason text CHECK (
    cancellation_reason IS NULL OR cancellation_reason IN (
      'expired', 'revoked', 'killed', 'disabled', 'unknown_key',
      'tampered_envelope'
    )
  ),
  PRIMARY KEY (workspace_id, delivery_id),
  UNIQUE (delivery_id),
  UNIQUE (workspace_id, challenge_id),
  FOREIGN KEY (workspace_id, challenge_id)
    REFERENCES roomscan.portal_feedback_challenges(workspace_id, challenge_id)
    ON DELETE RESTRICT,
  FOREIGN KEY (workspace_id, session_id)
    REFERENCES roomscan.portal_sessions(workspace_id, session_id) ON DELETE RESTRICT,
  FOREIGN KEY (workspace_id, link_id)
    REFERENCES roomscan.publication_links(workspace_id, link_id) ON DELETE RESTRICT,
  FOREIGN KEY (workspace_id, snapshot_id)
    REFERENCES roomscan.publication_snapshots(workspace_id, snapshot_id) ON DELETE RESTRICT,
  CHECK (created_at < expires_at),
  CHECK (
    (state = 'pending' AND lease_id IS NULL AND lease_expires_at IS NULL
      AND delivered_at IS NULL AND cancelled_at IS NULL AND cancellation_reason IS NULL)
    OR (state = 'leased' AND lease_id IS NOT NULL AND lease_expires_at IS NOT NULL
      AND delivered_at IS NULL AND cancelled_at IS NULL AND cancellation_reason IS NULL)
    OR (state = 'delivered' AND lease_id IS NULL AND lease_expires_at IS NULL
      AND delivered_at IS NOT NULL AND cancelled_at IS NULL AND cancellation_reason IS NULL)
    OR (state = 'expired' AND lease_id IS NULL AND lease_expires_at IS NULL
      AND delivered_at IS NULL AND cancelled_at IS NOT NULL AND cancellation_reason = 'expired')
    OR (state = 'cancelled' AND lease_id IS NULL AND lease_expires_at IS NULL
      AND delivered_at IS NULL AND cancelled_at IS NOT NULL
      AND cancellation_reason IN ('revoked', 'killed', 'disabled', 'unknown_key', 'tampered_envelope'))
  )
);

CREATE TABLE roomscan.publication_feedback (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE RESTRICT,
  feedback_id uuid NOT NULL,
  request_digest bytea NOT NULL CHECK (octet_length(request_digest) = 32),
  link_id uuid NOT NULL,
  link_generation bigint NOT NULL CHECK (link_generation > 0),
  snapshot_id uuid NOT NULL,
  kind text NOT NULL CHECK (kind IN ('comment', 'approve', 'request_changes')),
  comment text CHECK (comment IS NULL OR length(comment) BETWEEN 1 AND 10000),
  verified_email_digest bytea NOT NULL CHECK (octet_length(verified_email_digest) = 32),
  display_label text NOT NULL DEFAULT 'Verified client' CHECK (display_label = 'Verified client'),
  occurred_at timestamptz NOT NULL,
  PRIMARY KEY (workspace_id, feedback_id),
  UNIQUE (workspace_id, request_digest),
  FOREIGN KEY (workspace_id, link_id)
    REFERENCES roomscan.publication_links(workspace_id, link_id) ON DELETE RESTRICT,
  FOREIGN KEY (workspace_id, snapshot_id)
    REFERENCES roomscan.publication_snapshots(workspace_id, snapshot_id) ON DELETE RESTRICT,
  CHECK ((kind = 'comment' AND comment IS NOT NULL) OR (kind <> 'comment'))
);

CREATE TABLE roomscan.publication_access_events (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE RESTRICT,
  event_id uuid NOT NULL,
  link_id uuid NOT NULL,
  link_generation bigint NOT NULL CHECK (link_generation > 0),
  snapshot_id uuid NOT NULL,
  action text NOT NULL CHECK (action IN (
    'exchange', 'pin', 'snapshot', 'asset', 'download',
    'feedback_verification', 'feedback'
  )),
  outcome text NOT NULL CHECK (outcome IN ('allowed', 'denied', 'cooldown', 'expired', 'revoked', 'killed')),
  occurred_hour timestamptz NOT NULL CHECK (occurred_hour = date_trunc('hour', occurred_hour)),
  client_family text NOT NULL CHECK (client_family IN ('desktop', 'mobile', 'tablet', 'unknown')),
  network_risk_digest bytea NOT NULL CHECK (octet_length(network_risk_digest) = 32),
  logical_expires_at timestamptz NOT NULL,
  PRIMARY KEY (workspace_id, event_id),
  FOREIGN KEY (workspace_id, link_id)
    REFERENCES roomscan.publication_links(workspace_id, link_id) ON DELETE RESTRICT,
  FOREIGN KEY (workspace_id, snapshot_id)
    REFERENCES roomscan.publication_snapshots(workspace_id, snapshot_id) ON DELETE RESTRICT,
  CHECK (logical_expires_at = occurred_hour + interval '90 days')
);

CREATE TABLE roomscan.portal_delivery_receipts (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE RESTRICT,
  request_digest bytea NOT NULL CHECK (octet_length(request_digest) = 32),
  session_id uuid NOT NULL,
  link_id uuid NOT NULL,
  link_generation bigint NOT NULL CHECK (link_generation > 0),
  snapshot_id uuid NOT NULL,
  asset_id uuid NOT NULL,
  asset_object_version text NOT NULL CHECK (
    length(asset_object_version) BETWEEN 1 AND 1024 AND asset_object_version !~ '[[:cntrl:]]'
  ),
  byte_offset bigint NOT NULL CHECK (byte_offset >= 0),
  byte_length bigint NOT NULL CHECK (byte_length > 0 AND byte_length <= 4194304),
  delivered_bytes bigint NOT NULL CHECK (delivered_bytes > 0 AND delivered_bytes <= 4194304),
  delivered_at timestamptz NOT NULL,
  PRIMARY KEY (workspace_id, request_digest),
  FOREIGN KEY (workspace_id, session_id)
    REFERENCES roomscan.portal_sessions(workspace_id, session_id) ON DELETE RESTRICT,
  FOREIGN KEY (workspace_id, link_id)
    REFERENCES roomscan.publication_links(workspace_id, link_id) ON DELETE RESTRICT,
  FOREIGN KEY (workspace_id, snapshot_id)
    REFERENCES roomscan.publication_snapshots(workspace_id, snapshot_id) ON DELETE RESTRICT,
  FOREIGN KEY (workspace_id, asset_id)
    REFERENCES roomscan.publication_assets(workspace_id, asset_id) ON DELETE RESTRICT,
  CHECK (delivered_bytes = byte_length)
);

-- Authorization is intentionally distinct from charging. The portal service
-- reserves this exact immutable tuple before opening a versioned object; it
-- calls the final accounting reducer only after an exact successful read.
-- A failed storage read therefore has no receipt and records zero bytes.
CREATE TABLE roomscan.portal_asset_reservations (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE RESTRICT,
  request_digest bytea NOT NULL CHECK (octet_length(request_digest) = 32),
  session_id uuid NOT NULL,
  link_id uuid NOT NULL,
  link_generation bigint NOT NULL CHECK (link_generation > 0),
  snapshot_id uuid NOT NULL,
  asset_id uuid NOT NULL,
  asset_object_version text NOT NULL CHECK (
    length(asset_object_version) BETWEEN 1 AND 1024 AND asset_object_version !~ '[[:cntrl:]]'
  ),
  byte_offset bigint NOT NULL CHECK (byte_offset >= 0),
  byte_length bigint NOT NULL CHECK (byte_length > 0 AND byte_length <= 4194304),
  state text NOT NULL DEFAULT 'reserved' CHECK (state IN ('reserved', 'delivered')),
  created_at timestamptz NOT NULL,
  delivered_at timestamptz,
  PRIMARY KEY (workspace_id, request_digest),
  FOREIGN KEY (workspace_id, session_id)
    REFERENCES roomscan.portal_sessions(workspace_id, session_id) ON DELETE RESTRICT,
  FOREIGN KEY (workspace_id, link_id)
    REFERENCES roomscan.publication_links(workspace_id, link_id) ON DELETE RESTRICT,
  FOREIGN KEY (workspace_id, snapshot_id)
    REFERENCES roomscan.publication_snapshots(workspace_id, snapshot_id) ON DELETE RESTRICT,
  FOREIGN KEY (workspace_id, asset_id)
    REFERENCES roomscan.publication_assets(workspace_id, asset_id) ON DELETE RESTRICT,
  CHECK ((state = 'reserved' AND delivered_at IS NULL)
    OR (state = 'delivered' AND delivered_at IS NOT NULL))
);

CREATE INDEX publication_allocations_ready
  ON roomscan.publication_allocations (state, allocation_expires_at, created_at, allocation_id);
CREATE INDEX publication_jobs_ready
  ON roomscan.publication_jobs (state, lease_expires_at, created_at, job_id);
CREATE INDEX publication_links_snapshot
  ON roomscan.publication_links (workspace_id, snapshot_id, state);
CREATE UNIQUE INDEX publication_assets_one_download_kind
  ON roomscan.publication_assets (workspace_id, snapshot_id, download_kind)
  WHERE download_kind IS NOT NULL;
CREATE UNIQUE INDEX publication_assets_one_presentation
  ON roomscan.publication_assets (workspace_id, snapshot_id)
  WHERE asset_kind = 'presentation';
CREATE INDEX portal_sessions_expiry
  ON roomscan.portal_sessions (expires_at, state);
CREATE INDEX publication_access_events_expiry
  ON roomscan.publication_access_events (logical_expires_at, occurred_hour);
CREATE INDEX portal_feedback_delivery_available
  ON roomscan.portal_feedback_delivery_outbox (state, lease_expires_at, created_at, delivery_id);

ALTER TABLE roomscan.publication_properties ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.publication_properties FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.publication_property_rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.publication_property_rooms FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.publication_snapshot_rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.publication_snapshot_rooms FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.publication_allocation_source_bindings ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.publication_allocation_source_bindings FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.publication_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.publication_allocations FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.publication_sources ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.publication_sources FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.publication_approvals ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.publication_approvals FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.publication_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.publication_jobs FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.publication_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.publication_snapshots FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.publication_assets ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.publication_assets FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.publication_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.publication_links FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.professional_web_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.professional_web_sessions FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.portal_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.portal_sessions FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.portal_pin_throttles ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.portal_pin_throttles FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.portal_feedback_challenges ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.portal_feedback_challenges FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.publication_feedback ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.publication_feedback FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.publication_access_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.publication_access_events FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.portal_delivery_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.portal_delivery_receipts FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.portal_asset_reservations ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.portal_asset_reservations FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.portal_feedback_delivery_outbox ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.portal_feedback_delivery_outbox FORCE ROW LEVEL SECURITY;

CREATE POLICY publication_properties_tenant_isolation ON roomscan.publication_properties
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));
CREATE POLICY publication_property_rooms_tenant_isolation ON roomscan.publication_property_rooms
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));
CREATE POLICY publication_snapshot_rooms_tenant_isolation ON roomscan.publication_snapshot_rooms
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));
CREATE POLICY publication_allocation_source_bindings_tenant_isolation ON roomscan.publication_allocation_source_bindings
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));
CREATE POLICY publication_allocations_tenant_isolation ON roomscan.publication_allocations
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));
CREATE POLICY publication_sources_tenant_isolation ON roomscan.publication_sources
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));
CREATE POLICY publication_approvals_tenant_isolation ON roomscan.publication_approvals
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));
CREATE POLICY publication_jobs_tenant_isolation ON roomscan.publication_jobs
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));
CREATE POLICY publication_snapshots_tenant_isolation ON roomscan.publication_snapshots
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));
CREATE POLICY publication_assets_tenant_isolation ON roomscan.publication_assets
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));
CREATE POLICY publication_links_tenant_isolation ON roomscan.publication_links
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));
CREATE POLICY professional_web_sessions_tenant_isolation ON roomscan.professional_web_sessions
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));
CREATE POLICY portal_sessions_tenant_isolation ON roomscan.portal_sessions
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));
CREATE POLICY portal_pin_throttles_tenant_isolation ON roomscan.portal_pin_throttles
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));
CREATE POLICY portal_feedback_challenges_tenant_isolation ON roomscan.portal_feedback_challenges
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));
CREATE POLICY publication_feedback_tenant_isolation ON roomscan.publication_feedback
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));
CREATE POLICY publication_access_events_tenant_isolation ON roomscan.publication_access_events
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));
CREATE POLICY portal_delivery_receipts_tenant_isolation ON roomscan.portal_delivery_receipts
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));
CREATE POLICY portal_asset_reservations_tenant_isolation ON roomscan.portal_asset_reservations
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));
CREATE POLICY portal_feedback_delivery_outbox_tenant_isolation
  ON roomscan.portal_feedback_delivery_outbox
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));

CREATE FUNCTION roomscan.publication_immutable_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'IMMUTABLE_PUBLICATION_RECORD';
END
$function$;

CREATE FUNCTION roomscan.publication_snapshot_room_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE property_snapshot roomscan.publication_snapshots%ROWTYPE;
DECLARE room_project roomscan.professional_projects%ROWTYPE;
DECLARE room_revision roomscan.project_revisions%ROWTYPE;
DECLARE allocation_binding roomscan.publication_allocation_source_bindings%ROWTYPE;
BEGIN
  IF TG_OP <> 'INSERT' THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'IMMUTABLE_PUBLICATION_RECORD';
  END IF;
  SELECT snapshot.* INTO property_snapshot
  FROM roomscan.publication_snapshots AS snapshot
  WHERE snapshot.workspace_id = NEW.workspace_id
    AND snapshot.snapshot_id = NEW.property_snapshot_id;
  SELECT project.* INTO room_project
  FROM roomscan.professional_projects AS project
  WHERE project.workspace_id = NEW.workspace_id
    AND project.project_id = NEW.room_project_id;
  SELECT revision.* INTO room_revision
  FROM roomscan.project_revisions AS revision
  WHERE revision.workspace_id = NEW.workspace_id
    AND revision.id = NEW.source_revision_id
    AND revision.project_id = NEW.room_project_id;
  SELECT binding.* INTO allocation_binding
  FROM roomscan.publication_allocation_source_bindings AS binding
  WHERE binding.workspace_id = NEW.workspace_id
    AND binding.allocation_id = property_snapshot.allocation_id
    AND binding.room_order = NEW.room_order;
  IF property_snapshot.snapshot_id IS NULL OR room_project.project_id IS NULL
    OR room_revision.id IS NULL
    OR allocation_binding.allocation_id IS NULL
    OR property_snapshot.publication_kind <> 'property'
    OR room_project.public_id IS DISTINCT FROM NEW.room_project_public_id
    OR room_revision.public_id IS DISTINCT FROM NEW.source_revision_public_id
    OR room_revision.working_digest IS DISTINCT FROM NEW.source_revision_digest
    OR room_revision.working_manifest_digest IS DISTINCT FROM NEW.source_manifest_digest
    OR allocation_binding.public_room_key IS DISTINCT FROM NEW.room_key
    OR allocation_binding.room_project_id IS DISTINCT FROM NEW.room_project_id
    OR allocation_binding.room_project_public_id IS DISTINCT FROM NEW.room_project_public_id
    OR allocation_binding.source_revision_id IS DISTINCT FROM NEW.source_revision_id
    OR allocation_binding.source_revision_public_id IS DISTINCT FROM NEW.source_revision_public_id
    OR allocation_binding.working_digest IS DISTINCT FROM NEW.source_revision_digest
    OR allocation_binding.working_manifest_digest IS DISTINCT FROM NEW.source_manifest_digest THEN
    RAISE EXCEPTION USING ERRCODE = '23503', MESSAGE = 'INVALID_PROPERTY_SNAPSHOT_ROOM_PROVENANCE';
  END IF;
  RETURN NEW;
END
$function$;

CREATE FUNCTION roomscan.portal_request_feedback_verification_v1(
  requested_session_hash bytea,
  authoritative_time timestamptz,
  requested_challenge_hash bytea,
  requested_expected_verification_token_hash bytea,
  requested_verified_email_digest bytea
)
RETURNS TABLE (status text, challenge_id uuid, expires_at timestamptz)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE new_challenge_id uuid := gen_random_uuid();
DECLARE challenge_expiry timestamptz;
BEGIN
  IF requested_challenge_hash IS NULL OR requested_expected_verification_token_hash IS NULL
    OR requested_verified_email_digest IS NULL
    OR octet_length(requested_challenge_hash) <> 32
    OR octet_length(requested_expected_verification_token_hash) <> 32
    OR octet_length(requested_verified_email_digest) <> 32
    OR authoritative_time IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_FEEDBACK_VERIFICATION_REQUEST';
  END IF;
  SELECT context.* INTO context_row
  FROM roomscan.portal_session_context_v1(requested_session_hash, authoritative_time) AS context;
  IF context_row.feedback_enabled IS DISTINCT FROM true THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PORTAL_FEEDBACK_DISABLED';
  END IF;
  challenge_expiry := authoritative_time + interval '15 minutes';
  INSERT INTO roomscan.portal_feedback_challenges (
    workspace_id, challenge_id, challenge_hash, verification_token_hash, session_id, link_id,
    link_generation, snapshot_id, verified_email_digest, expires_at, created_at
  ) VALUES (
    context_row.workspace_id, new_challenge_id, requested_challenge_hash,
    requested_expected_verification_token_hash,
    context_row.session_id, context_row.link_id, context_row.link_generation,
    context_row.snapshot_id, requested_verified_email_digest, challenge_expiry,
    authoritative_time
  );
  PERFORM roomscan.publication_append_access_event_v1(
    context_row.workspace_id, context_row.link_id, context_row.link_generation,
    context_row.snapshot_id, 'feedback_verification', 'allowed', authoritative_time,
    context_row.client_family, context_row.network_risk_digest
  );
  RETURN QUERY SELECT 'issued'::text, new_challenge_id, challenge_expiry;
END
$function$;

-- Shared lifecycle predicate for the sealed email worker.  It deliberately
-- resolves only the repeated opaque scope and current flag epochs; plaintext
-- email/code remain inside the encrypted outbox envelope.
CREATE FUNCTION roomscan.publication_feedback_delivery_live_v2(
  requested_workspace_id uuid,
  requested_delivery_id text,
  checked_at_time timestamptz
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM roomscan.portal_feedback_delivery_outbox AS delivery
    JOIN roomscan.portal_feedback_challenges AS challenge
      ON challenge.workspace_id = delivery.workspace_id
      AND challenge.challenge_id = delivery.challenge_id
    JOIN roomscan.portal_sessions AS session
      ON session.workspace_id = delivery.workspace_id
      AND session.session_id = delivery.session_id
    JOIN roomscan.publication_links AS link
      ON link.workspace_id = delivery.workspace_id
      AND link.link_id = delivery.link_id
    JOIN roomscan.publication_snapshots AS snapshot
      ON snapshot.workspace_id = delivery.workspace_id
      AND snapshot.snapshot_id = delivery.snapshot_id
    JOIN roomscan.global_operational_flags AS hosted_global
      ON hosted_global.flag_key = 'hosted_operations_enabled'
    JOIN roomscan.global_operational_flags AS publication_global
      ON publication_global.flag_key = 'publication_enabled'
    JOIN roomscan.workspace_operational_flags AS hosted_workspace
      ON hosted_workspace.workspace_id = delivery.workspace_id
      AND hosted_workspace.flag_key = 'hosted_operations_enabled'
    JOIN roomscan.workspace_operational_flags AS publication_workspace
      ON publication_workspace.workspace_id = delivery.workspace_id
      AND publication_workspace.flag_key = 'publication_enabled'
    WHERE delivery.workspace_id = requested_workspace_id
      AND delivery.delivery_id = requested_delivery_id
      AND delivery.expires_at > checked_at_time
      AND challenge.expires_at > checked_at_time
      AND challenge.consumed_at IS NULL
      AND challenge.feedback_used_at IS NULL
      AND session.state = 'active'
      AND session.expires_at > checked_at_time
      AND session.link_id = delivery.link_id
      AND session.link_generation = delivery.link_generation
      AND session.snapshot_id = delivery.snapshot_id
      AND link.state = 'active'
      AND link.expires_at > checked_at_time
      AND link.generation = delivery.link_generation
      AND link.snapshot_id = delivery.snapshot_id
      AND link.feedback_enabled IS TRUE
      AND hosted_global.enabled IS TRUE
      AND hosted_global.version = session.hosted_global_version
      AND hosted_workspace.enabled IS TRUE
      AND hosted_workspace.version = session.hosted_workspace_version
      AND publication_global.enabled IS TRUE
      AND publication_global.version = session.publication_global_version
      AND publication_workspace.enabled IS TRUE
      AND publication_workspace.version = session.publication_workspace_version
  )
$function$;

CREATE FUNCTION roomscan.portal_request_feedback_verification_v2(
  requested_session_hash bytea,
  authoritative_time timestamptz,
  requested_challenge_hash bytea,
  requested_verification_token_hash bytea,
  requested_verified_email_digest bytea,
  requested_key_id text,
  requested_iv bytea,
  requested_ciphertext bytea,
  requested_authentication_tag bytea
)
RETURNS TABLE (status text, challenge_id uuid, expires_at timestamptz)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE new_challenge_id uuid := gen_random_uuid();
DECLARE new_delivery_id text := 'pfd_' || replace(gen_random_uuid()::text, '-', '');
DECLARE challenge_expiry timestamptz;
BEGIN
  PERFORM roomscan.publication_require_portal_v1();
  IF requested_session_hash IS NULL OR authoritative_time IS NULL
    OR requested_challenge_hash IS NULL OR requested_verification_token_hash IS NULL
    OR requested_verified_email_digest IS NULL OR requested_key_id IS NULL
    OR requested_iv IS NULL OR requested_ciphertext IS NULL
    OR requested_authentication_tag IS NULL
    OR octet_length(requested_session_hash) <> 32
    OR octet_length(requested_challenge_hash) <> 32
    OR octet_length(requested_verification_token_hash) <> 32
    OR octet_length(requested_verified_email_digest) <> 32
    OR length(requested_key_id) NOT BETWEEN 1 AND 64
    OR requested_key_id !~ '^[A-Za-z0-9._-]+$'
    OR octet_length(requested_iv) <> 12
    OR octet_length(requested_ciphertext) NOT BETWEEN 1 AND 4096
    OR octet_length(requested_authentication_tag) <> 16 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_FEEDBACK_VERIFICATION_REQUEST';
  END IF;
  SELECT context.* INTO context_row
  FROM roomscan.portal_session_context_v1(requested_session_hash, authoritative_time) AS context;
  IF context_row.feedback_enabled IS DISTINCT FROM true THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PORTAL_FEEDBACK_DISABLED';
  END IF;
  challenge_expiry := authoritative_time + interval '15 minutes';
  -- The challenge and its sealed delivery are one transaction.  If the
  -- outbox insert cannot be committed, this reducer cannot acknowledge an
  -- issued challenge.
  INSERT INTO roomscan.portal_feedback_challenges (
    workspace_id, challenge_id, challenge_hash, verification_token_hash,
    session_id, link_id, link_generation, snapshot_id, verified_email_digest,
    expires_at, created_at
  ) VALUES (
    context_row.workspace_id, new_challenge_id, requested_challenge_hash,
    requested_verification_token_hash, context_row.session_id, context_row.link_id,
    context_row.link_generation, context_row.snapshot_id,
    requested_verified_email_digest, challenge_expiry, authoritative_time
  );
  INSERT INTO roomscan.portal_feedback_delivery_outbox (
    workspace_id, delivery_id, challenge_id, session_id, link_id,
    link_generation, snapshot_id, envelope_version, key_id, iv, ciphertext,
    authentication_tag, created_at, expires_at
  ) VALUES (
    context_row.workspace_id, new_delivery_id, new_challenge_id,
    context_row.session_id, context_row.link_id, context_row.link_generation,
    context_row.snapshot_id, 'aes-256-gcm-v1', requested_key_id, requested_iv,
    requested_ciphertext, requested_authentication_tag, authoritative_time,
    challenge_expiry
  );
  PERFORM roomscan.publication_append_access_event_v1(
    context_row.workspace_id, context_row.link_id, context_row.link_generation,
    context_row.snapshot_id, 'feedback_verification', 'allowed', authoritative_time,
    context_row.client_family, context_row.network_risk_digest
  );
  RETURN QUERY SELECT 'issued'::text, new_challenge_id, challenge_expiry;
END
$function$;

CREATE FUNCTION roomscan.portal_consume_feedback_verification_v1(
  requested_session_hash bytea,
  requested_challenge_hash bytea,
  authoritative_time timestamptz,
  requested_verification_token_hash bytea
)
RETURNS TABLE (status text, challenge_id uuid, expires_at timestamptz)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE challenge roomscan.portal_feedback_challenges%ROWTYPE;
DECLARE context_row record;
BEGIN
  PERFORM roomscan.publication_require_portal_v1();
  IF requested_session_hash IS NULL OR requested_challenge_hash IS NULL OR authoritative_time IS NULL
    OR requested_verification_token_hash IS NULL
    OR octet_length(requested_session_hash) <> 32 OR octet_length(requested_challenge_hash) <> 32
    OR octet_length(requested_verification_token_hash) <> 32 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_FEEDBACK_VERIFICATION_CONSUME';
  END IF;
  SELECT context.* INTO context_row
  FROM roomscan.portal_session_context_v1(requested_session_hash, authoritative_time) AS context;
  IF context_row.feedback_enabled IS DISTINCT FROM true THEN
    RETURN QUERY SELECT 'unavailable'::text, NULL::uuid, NULL::timestamptz;
    RETURN;
  END IF;
  SELECT candidate.* INTO challenge
  FROM roomscan.portal_feedback_challenges AS candidate
  WHERE candidate.challenge_hash = requested_challenge_hash
    AND candidate.session_id = context_row.session_id
    AND candidate.workspace_id = context_row.workspace_id
    AND candidate.link_id = context_row.link_id
    AND candidate.link_generation = context_row.link_generation
    AND candidate.snapshot_id = context_row.snapshot_id
  FOR UPDATE;
  IF NOT FOUND OR challenge.consumed_at IS NOT NULL
    OR challenge.feedback_used_at IS NOT NULL
    OR challenge.expires_at <= authoritative_time
    OR challenge.verification_token_hash IS DISTINCT FROM requested_verification_token_hash
    -- A verification token is not usable until the sealed email worker has
    -- durably completed delivery.  This prevents a request-side caller from
    -- skipping the accountless verification transport entirely.
    OR NOT EXISTS (
      SELECT 1 FROM roomscan.portal_feedback_delivery_outbox AS delivery
      WHERE delivery.workspace_id = challenge.workspace_id
        AND delivery.challenge_id = challenge.challenge_id
        AND delivery.state = 'delivered'
    ) THEN
    RETURN QUERY SELECT 'unavailable'::text, NULL::uuid, NULL::timestamptz;
    RETURN;
  END IF;
  UPDATE roomscan.portal_feedback_challenges AS target
  SET consumed_at = authoritative_time
  WHERE target.workspace_id = challenge.workspace_id
    AND target.challenge_id = challenge.challenge_id;
  RETURN QUERY SELECT 'verified'::text, challenge.challenge_id, challenge.expires_at;
END
$function$;

CREATE FUNCTION roomscan.publication_require_feedback_scope_v1(
  requested_challenge_token_hash bytea,
  requested_session_id uuid,
  requested_workspace_id uuid,
  requested_link_id uuid,
  requested_link_generation bigint,
  requested_snapshot_id uuid,
  authoritative_time timestamptz
)
RETURNS TABLE (verified_email_digest bytea)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE challenge roomscan.portal_feedback_challenges%ROWTYPE;
BEGIN
  IF requested_challenge_token_hash IS NULL OR requested_session_id IS NULL
    OR requested_workspace_id IS NULL OR requested_link_id IS NULL
    OR requested_link_generation IS NULL OR requested_snapshot_id IS NULL
    OR authoritative_time IS NULL OR octet_length(requested_challenge_token_hash) <> 32 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_FEEDBACK_SCOPE';
  END IF;
  SELECT candidate.* INTO challenge
  FROM roomscan.portal_feedback_challenges AS candidate
  WHERE candidate.verification_token_hash = requested_challenge_token_hash
    AND candidate.session_id = requested_session_id
    AND candidate.workspace_id = requested_workspace_id
    AND candidate.link_id = requested_link_id
    AND candidate.link_generation = requested_link_generation
    AND candidate.snapshot_id = requested_snapshot_id
  FOR UPDATE;
  IF NOT FOUND OR challenge.consumed_at IS NULL
    OR challenge.feedback_used_at IS NOT NULL
    OR challenge.expires_at <= authoritative_time THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'FEEDBACK_VERIFICATION_REQUIRED';
  END IF;
  UPDATE roomscan.portal_feedback_challenges AS target
  SET feedback_used_at = authoritative_time
  WHERE target.workspace_id = challenge.workspace_id
    AND target.challenge_id = challenge.challenge_id
    AND target.feedback_used_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'FEEDBACK_VERIFICATION_REPLAYED';
  END IF;
  RETURN QUERY SELECT challenge.verified_email_digest;
END
$function$;

CREATE FUNCTION roomscan.portal_create_feedback_v1(
  requested_session_hash bytea,
  authoritative_time timestamptz,
  requested_verification_token_hash bytea,
  requested_feedback_kind text,
  requested_comment text,
  requested_request_digest bytea
)
RETURNS TABLE (status text, feedback_id uuid, display_label text)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE verified_email_digest bytea;
DECLARE new_feedback_id uuid := gen_random_uuid();
BEGIN
  IF authoritative_time IS NULL OR requested_verification_token_hash IS NULL
    OR requested_feedback_kind IS NULL OR requested_request_digest IS NULL
    OR octet_length(requested_verification_token_hash) <> 32
    OR octet_length(requested_request_digest) <> 32
    OR requested_feedback_kind NOT IN ('comment', 'approve', 'request_changes')
    OR (requested_feedback_kind = 'comment' AND requested_comment IS NULL)
    OR (requested_comment IS NOT NULL AND length(requested_comment) NOT BETWEEN 1 AND 10000) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_FEEDBACK';
  END IF;
  SELECT context.* INTO context_row
  FROM roomscan.portal_session_context_v1(requested_session_hash, authoritative_time) AS context;
  IF context_row.feedback_enabled IS DISTINCT FROM true THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PORTAL_FEEDBACK_DISABLED';
  END IF;
  SELECT scope.verified_email_digest INTO verified_email_digest
  FROM roomscan.publication_require_feedback_scope_v1(
    requested_verification_token_hash, context_row.session_id,
    context_row.workspace_id, context_row.link_id, context_row.link_generation,
    context_row.snapshot_id, authoritative_time
  ) AS scope;
  INSERT INTO roomscan.publication_feedback (
    workspace_id, feedback_id, request_digest, link_id, link_generation,
    snapshot_id, kind, comment, verified_email_digest, display_label, occurred_at
  ) VALUES (
    context_row.workspace_id, new_feedback_id, requested_request_digest,
    context_row.link_id, context_row.link_generation, context_row.snapshot_id,
    requested_feedback_kind, requested_comment, verified_email_digest,
    'Verified client', authoritative_time
  );
  PERFORM roomscan.publication_append_access_event_v1(
    context_row.workspace_id, context_row.link_id, context_row.link_generation,
    context_row.snapshot_id, 'feedback', 'allowed', authoritative_time,
    context_row.client_family, context_row.network_risk_digest
  );
  RETURN QUERY SELECT 'recorded'::text, new_feedback_id, 'Verified client'::text;
END
$function$;

CREATE FUNCTION roomscan.publication_require_feedback_delivery_runtime_v2()
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  IF session_user <> 'roomscan_email_delivery_runtime' THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'FEEDBACK_DELIVERY_RUNTIME_REQUIRED';
  END IF;
END
$function$;

CREATE FUNCTION roomscan.claim_next_feedback_delivery_v2(
  requested_lease_id text,
  claimed_at_time timestamptz,
  requested_lease_expires_at timestamptz
)
RETURNS SETOF roomscan.portal_feedback_delivery_outbox
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE candidate_id text;
BEGIN
  PERFORM roomscan.publication_require_feedback_delivery_runtime_v2();
  IF requested_lease_id IS NULL OR claimed_at_time IS NULL
    OR requested_lease_expires_at IS NULL
    OR length(requested_lease_id) NOT BETWEEN 1 AND 128
    OR requested_lease_id !~ '^[A-Za-z0-9_-]+$'
    OR requested_lease_expires_at <= claimed_at_time
    OR requested_lease_expires_at > claimed_at_time + interval '15 minutes' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_FEEDBACK_DELIVERY_LEASE';
  END IF;

  -- Expired envelopes are terminal.  A revoked link/session or a changed
  -- publication/hosted epoch is also terminal: re-enabling publication must
  -- never revive a challenge created under the old grant.
  UPDATE roomscan.portal_feedback_delivery_outbox AS delivery
  SET state = 'expired', lease_id = NULL, lease_expires_at = NULL,
      cancelled_at = claimed_at_time, cancellation_reason = 'expired'
  WHERE delivery.state IN ('pending', 'leased')
    AND delivery.expires_at <= claimed_at_time;
  UPDATE roomscan.portal_feedback_delivery_outbox AS delivery
  SET state = 'cancelled', lease_id = NULL, lease_expires_at = NULL,
      cancelled_at = claimed_at_time, cancellation_reason = 'disabled'
  WHERE delivery.state IN ('pending', 'leased')
    AND delivery.expires_at > claimed_at_time
    AND NOT roomscan.publication_feedback_delivery_live_v2(
      delivery.workspace_id, delivery.delivery_id, claimed_at_time
    );

  SELECT delivery.delivery_id INTO candidate_id
  FROM roomscan.portal_feedback_delivery_outbox AS delivery
  WHERE delivery.state IN ('pending', 'leased')
    AND delivery.expires_at > claimed_at_time
    AND (delivery.state = 'pending'
      OR delivery.lease_expires_at <= claimed_at_time)
    AND roomscan.publication_feedback_delivery_live_v2(
      delivery.workspace_id, delivery.delivery_id, claimed_at_time
    )
  ORDER BY delivery.created_at, delivery.delivery_id
  FOR UPDATE OF delivery SKIP LOCKED
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN;
  END IF;
  RETURN QUERY
  UPDATE roomscan.portal_feedback_delivery_outbox AS delivery
  SET state = 'leased', lease_id = requested_lease_id,
      lease_expires_at = LEAST(requested_lease_expires_at, delivery.expires_at),
      delivery_attempts = delivery.delivery_attempts + 1
  WHERE delivery.delivery_id = candidate_id
    AND delivery.state IN ('pending', 'leased')
    AND delivery.expires_at > claimed_at_time
    AND (delivery.state = 'pending'
      OR delivery.lease_expires_at <= claimed_at_time)
  RETURNING delivery.*;
END
$function$;

-- Keep the targetless spelling above as the canonical queue-wake capability,
-- while exposing the short lifecycle name used by worker adapters.
CREATE FUNCTION roomscan.claim_feedback_delivery_v2(
  requested_lease_id text,
  claimed_at_time timestamptz,
  requested_lease_expires_at timestamptz
)
RETURNS SETOF roomscan.portal_feedback_delivery_outbox
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  RETURN QUERY SELECT * FROM roomscan.claim_next_feedback_delivery_v2(
    requested_lease_id, claimed_at_time, requested_lease_expires_at
  );
END
$function$;

CREATE FUNCTION roomscan.validate_feedback_delivery_v2(
  requested_delivery_id text,
  requested_lease_id text,
  checked_at_time timestamptz
)
RETURNS SETOF roomscan.portal_feedback_delivery_outbox
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE delivery roomscan.portal_feedback_delivery_outbox%ROWTYPE;
BEGIN
  PERFORM roomscan.publication_require_feedback_delivery_runtime_v2();
  IF requested_delivery_id IS NULL OR requested_lease_id IS NULL
    OR checked_at_time IS NULL
    OR requested_delivery_id !~ '^pfd_[A-Za-z0-9_-]{16,128}$'
    OR length(requested_lease_id) NOT BETWEEN 1 AND 128
    OR requested_lease_id !~ '^[A-Za-z0-9_-]+$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_FEEDBACK_DELIVERY_LEASE';
  END IF;
  SELECT candidate.* INTO delivery
  FROM roomscan.portal_feedback_delivery_outbox AS candidate
  WHERE candidate.delivery_id = requested_delivery_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN;
  END IF;
  IF delivery.state = 'leased' AND delivery.lease_id = requested_lease_id
    AND delivery.expires_at <= checked_at_time THEN
    RETURN QUERY
    UPDATE roomscan.portal_feedback_delivery_outbox AS target
    SET state = 'expired', lease_id = NULL, lease_expires_at = NULL,
        cancelled_at = checked_at_time, cancellation_reason = 'expired'
    WHERE target.workspace_id = delivery.workspace_id
      AND target.delivery_id = delivery.delivery_id
      AND target.state = 'leased'
      AND target.lease_id = requested_lease_id
    RETURNING target.*;
    RETURN;
  END IF;
  IF delivery.state <> 'leased' OR delivery.lease_id IS DISTINCT FROM requested_lease_id
    OR delivery.lease_expires_at IS NULL
    OR delivery.lease_expires_at <= checked_at_time
    OR delivery.expires_at <= checked_at_time THEN
    RETURN;
  END IF;
  IF NOT roomscan.publication_feedback_delivery_live_v2(
    delivery.workspace_id, delivery.delivery_id, checked_at_time
  ) THEN
    RETURN QUERY
    UPDATE roomscan.portal_feedback_delivery_outbox AS target
    SET state = 'cancelled', lease_id = NULL, lease_expires_at = NULL,
        cancelled_at = checked_at_time, cancellation_reason = 'disabled'
    WHERE target.workspace_id = delivery.workspace_id
      AND target.delivery_id = delivery.delivery_id
      AND target.state = 'leased'
      AND target.lease_id = requested_lease_id
    RETURNING target.*;
    RETURN;
  END IF;
  RETURN QUERY SELECT delivery.*;
END
$function$;

CREATE FUNCTION roomscan.complete_feedback_delivery_v2(
  requested_delivery_id text,
  requested_lease_id text,
  delivered_at_time timestamptz
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE changed integer;
BEGIN
  PERFORM roomscan.publication_require_feedback_delivery_runtime_v2();
  IF requested_delivery_id IS NULL OR requested_lease_id IS NULL
    OR delivered_at_time IS NULL
    OR requested_delivery_id !~ '^pfd_[A-Za-z0-9_-]{16,128}$'
    OR length(requested_lease_id) NOT BETWEEN 1 AND 128
    OR requested_lease_id !~ '^[A-Za-z0-9_-]+$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_FEEDBACK_DELIVERY_LEASE';
  END IF;
  UPDATE roomscan.portal_feedback_delivery_outbox AS delivery
  SET state = 'delivered', lease_id = NULL, lease_expires_at = NULL,
      delivered_at = delivered_at_time
  WHERE delivery.delivery_id = requested_delivery_id
    AND delivery.state = 'leased'
    AND delivery.lease_id = requested_lease_id
    AND delivery.lease_expires_at > delivered_at_time
    AND delivery.expires_at > delivered_at_time
    AND roomscan.publication_feedback_delivery_live_v2(
      delivery.workspace_id, delivery.delivery_id, delivered_at_time
    );
  GET DIAGNOSTICS changed = ROW_COUNT;
  RETURN changed = 1;
END
$function$;

CREATE FUNCTION roomscan.cancel_feedback_delivery_v2(
  requested_delivery_id text,
  requested_lease_id text,
  requested_reason text,
  cancelled_at_time timestamptz
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE changed integer;
BEGIN
  PERFORM roomscan.publication_require_feedback_delivery_runtime_v2();
  IF requested_delivery_id IS NULL OR requested_lease_id IS NULL
    OR requested_reason IS NULL OR cancelled_at_time IS NULL
    OR requested_delivery_id !~ '^pfd_[A-Za-z0-9_-]{16,128}$'
    OR length(requested_lease_id) NOT BETWEEN 1 AND 128
    OR requested_lease_id !~ '^[A-Za-z0-9_-]+$'
    OR requested_reason NOT IN (
      'expired', 'revoked', 'killed', 'disabled', 'unknown_key',
      'tampered_envelope'
    ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_FEEDBACK_DELIVERY_CANCEL';
  END IF;
  UPDATE roomscan.portal_feedback_delivery_outbox AS delivery
  SET state = CASE WHEN requested_reason = 'expired' THEN 'expired' ELSE 'cancelled' END,
      lease_id = NULL, lease_expires_at = NULL, cancelled_at = cancelled_at_time,
      cancellation_reason = requested_reason
  WHERE delivery.delivery_id = requested_delivery_id
    AND delivery.state = 'leased'
    AND delivery.lease_id = requested_lease_id;
  GET DIAGNOSTICS changed = ROW_COUNT;
  RETURN changed = 1;
END
$function$;

CREATE FUNCTION roomscan.release_feedback_delivery_v2(
  requested_delivery_id text,
  requested_lease_id text,
  released_at_time timestamptz
)
RETURNS TABLE (status text)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE delivery roomscan.portal_feedback_delivery_outbox%ROWTYPE;
BEGIN
  PERFORM roomscan.publication_require_feedback_delivery_runtime_v2();
  IF requested_delivery_id IS NULL OR requested_lease_id IS NULL
    OR released_at_time IS NULL
    OR requested_delivery_id !~ '^pfd_[A-Za-z0-9_-]{16,128}$'
    OR length(requested_lease_id) NOT BETWEEN 1 AND 128
    OR requested_lease_id !~ '^[A-Za-z0-9_-]+$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_FEEDBACK_DELIVERY_LEASE';
  END IF;
  SELECT candidate.* INTO delivery
  FROM roomscan.portal_feedback_delivery_outbox AS candidate
  WHERE candidate.delivery_id = requested_delivery_id
    AND candidate.state = 'leased'
    AND candidate.lease_id = requested_lease_id
  FOR UPDATE;
  IF NOT FOUND OR delivery.lease_expires_at IS NULL
    OR delivery.lease_expires_at <= released_at_time THEN
    RETURN QUERY SELECT 'unavailable'::text;
    RETURN;
  END IF;
  IF delivery.expires_at <= released_at_time THEN
    UPDATE roomscan.portal_feedback_delivery_outbox AS target
    SET state = 'expired', lease_id = NULL, lease_expires_at = NULL,
        cancelled_at = released_at_time, cancellation_reason = 'expired'
    WHERE target.workspace_id = delivery.workspace_id
      AND target.delivery_id = delivery.delivery_id
      AND target.state = 'leased' AND target.lease_id = requested_lease_id;
    RETURN QUERY SELECT 'expired'::text;
    RETURN;
  END IF;
  UPDATE roomscan.portal_feedback_delivery_outbox AS target
  SET state = 'pending', lease_id = NULL, lease_expires_at = NULL
  WHERE target.workspace_id = delivery.workspace_id
    AND target.delivery_id = delivery.delivery_id
    AND target.state = 'leased' AND target.lease_id = requested_lease_id;
  RETURN QUERY SELECT CASE WHEN FOUND THEN 'released' ELSE 'unavailable' END::text;
END
$function$;

CREATE FUNCTION roomscan.portal_get_snapshot_v1(
  requested_session_hash bytea,
  authoritative_time timestamptz
)
RETURNS TABLE (
  status text,
  snapshot_id uuid,
  snapshot_public_id text,
  publication_kind text,
  property_id uuid,
  presentation_digest bytea,
  presentation_bytes bigint
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE snapshot_row roomscan.publication_snapshots%ROWTYPE;
BEGIN
  SELECT context.* INTO context_row
  FROM roomscan.portal_session_context_v1(requested_session_hash, authoritative_time) AS context;
  SELECT snapshot.* INTO snapshot_row
  FROM roomscan.publication_snapshots AS snapshot
  WHERE snapshot.workspace_id = context_row.workspace_id
    AND snapshot.snapshot_id = context_row.snapshot_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PORTAL_SNAPSHOT_NOT_FOUND';
  END IF;
  PERFORM roomscan.publication_append_access_event_v1(
    context_row.workspace_id, context_row.link_id, context_row.link_generation,
    context_row.snapshot_id, 'snapshot', 'allowed', authoritative_time,
    context_row.client_family, context_row.network_risk_digest
  );
  RETURN QUERY SELECT 'allowed'::text, snapshot_row.snapshot_id,
    snapshot_row.public_id, snapshot_row.publication_kind, snapshot_row.property_id,
    snapshot_row.presentation_digest, snapshot_row.presentation_bytes;
END
$function$;

CREATE FUNCTION roomscan.portal_list_property_rooms_v1(
  requested_session_hash bytea,
  authoritative_time timestamptz
)
RETURNS TABLE (room_key text, room_order integer)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
BEGIN
  SELECT context.* INTO context_row
  FROM roomscan.portal_session_context_v1(requested_session_hash, authoritative_time) AS context;
  IF NOT EXISTS (
    SELECT 1 FROM roomscan.publication_snapshots AS snapshot
    WHERE snapshot.workspace_id = context_row.workspace_id
      AND snapshot.snapshot_id = context_row.snapshot_id
      AND snapshot.publication_kind = 'property'
  ) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PORTAL_PROPERTY_NOT_FOUND';
  END IF;
  RETURN QUERY
  SELECT rooms.room_key, rooms.room_order
  FROM roomscan.publication_snapshot_rooms AS rooms
  WHERE rooms.workspace_id = context_row.workspace_id
    AND rooms.property_snapshot_id = context_row.snapshot_id
  ORDER BY rooms.room_order;
END
$function$;

CREATE FUNCTION roomscan.portal_authorize_asset_v1(
  requested_session_hash bytea,
  authoritative_time timestamptz,
  requested_asset_public_id text,
  requested_request_digest bytea,
  requested_byte_offset bigint,
  requested_byte_length bigint
)
RETURNS TABLE (
  status text,
  asset_public_id text,
  object_key text,
  object_version text,
  content_type text,
  asset_bytes bigint,
  byte_offset bigint,
  byte_length bigint,
  delivered_bytes bigint,
  already_accounted boolean
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE asset_row roomscan.publication_assets%ROWTYPE;
DECLARE reservation_row roomscan.portal_asset_reservations%ROWTYPE;
BEGIN
  IF requested_asset_public_id IS NULL OR requested_request_digest IS NULL
    OR requested_byte_offset IS NULL OR requested_byte_length IS NULL
    OR octet_length(requested_request_digest) <> 32
    OR requested_byte_offset < 0 OR requested_byte_length <= 0 OR requested_byte_length > 4194304 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PORTAL_ASSET_REQUEST';
  END IF;
  SELECT context.* INTO context_row
  FROM roomscan.portal_session_context_v1(requested_session_hash, authoritative_time) AS context;
  SELECT asset.* INTO asset_row
  FROM roomscan.publication_assets AS asset
  WHERE asset.workspace_id = context_row.workspace_id
    AND asset.public_id = requested_asset_public_id
    AND asset.snapshot_id = context_row.snapshot_id;
  -- `asset.bytes - requested_byte_length` avoids overflow and binds an exact
  -- byte range, rather than accepting a same-length request at another offset.
  IF NOT FOUND OR requested_byte_length > asset_row.bytes
    OR requested_byte_offset > asset_row.bytes - requested_byte_length THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PORTAL_ASSET_NOT_FOUND';
  END IF;
  IF (asset_row.asset_kind = 'ai_ready_package' OR asset_row.download_kind = 'ai_ready_package')
    AND context_row.ai_enabled IS DISTINCT FROM true THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PORTAL_AI_DOWNLOAD_DISABLED';
  END IF;
  -- Reserve the exact tuple before storage is opened. This intentionally does
  -- not touch portal_bytes: a failed exact-version object read must record no
  -- delivered bytes. The final reducer rechecks all live state and charges.
  PERFORM pg_advisory_xact_lock(
    hashtextextended(encode(requested_request_digest, 'hex'), 0)
  );
  SELECT reservation.* INTO reservation_row
  FROM roomscan.portal_asset_reservations AS reservation
  WHERE reservation.workspace_id = context_row.workspace_id
    AND reservation.request_digest = requested_request_digest
  FOR UPDATE;
  IF FOUND THEN
    IF reservation_row.session_id IS DISTINCT FROM context_row.session_id
      OR reservation_row.asset_id IS DISTINCT FROM asset_row.asset_id
      OR reservation_row.link_id IS DISTINCT FROM context_row.link_id
      OR reservation_row.link_generation IS DISTINCT FROM context_row.link_generation
      OR reservation_row.snapshot_id IS DISTINCT FROM context_row.snapshot_id
      OR reservation_row.asset_object_version IS DISTINCT FROM asset_row.object_version
      OR reservation_row.byte_offset IS DISTINCT FROM requested_byte_offset
      OR reservation_row.byte_length IS DISTINCT FROM requested_byte_length THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PORTAL_DELIVERY_IDEMPOTENCY_REUSED';
    END IF;
    RETURN QUERY SELECT 'allowed'::text, asset_row.public_id, asset_row.object_key,
      asset_row.object_version, asset_row.content_type, asset_row.bytes,
      requested_byte_offset, requested_byte_length,
      CASE WHEN reservation_row.state = 'delivered' THEN requested_byte_length ELSE 0 END,
      reservation_row.state = 'delivered';
    RETURN;
  END IF;
  INSERT INTO roomscan.portal_asset_reservations (
    workspace_id, request_digest, session_id, link_id, link_generation,
    snapshot_id, asset_id, asset_object_version, byte_offset, byte_length,
    state, created_at
  ) VALUES (
    context_row.workspace_id, requested_request_digest, context_row.session_id,
    context_row.link_id, context_row.link_generation, context_row.snapshot_id,
    asset_row.asset_id, asset_row.object_version, requested_byte_offset,
    requested_byte_length, 'reserved', authoritative_time
  );
  PERFORM roomscan.publication_append_access_event_v1(
    context_row.workspace_id, context_row.link_id, context_row.link_generation,
    context_row.snapshot_id, 'asset', 'allowed', authoritative_time,
    context_row.client_family, context_row.network_risk_digest
  );
  RETURN QUERY SELECT 'allowed'::text, asset_row.public_id, asset_row.object_key,
    asset_row.object_version, asset_row.content_type, asset_row.bytes,
    requested_byte_offset, requested_byte_length, 0::bigint, false;
END
$function$;

CREATE FUNCTION roomscan.portal_finalize_asset_delivery_v1(
  requested_session_hash bytea,
  authoritative_time timestamptz,
  requested_asset_public_id text,
  requested_request_digest bytea,
  requested_byte_offset bigint,
  requested_byte_length bigint,
  requested_object_version text
)
RETURNS TABLE (
  status text,
  asset_public_id text,
  object_key text,
  object_version text,
  content_type text,
  asset_bytes bigint,
  byte_offset bigint,
  byte_length bigint,
  delivered_bytes bigint,
  already_accounted boolean
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE asset_row roomscan.publication_assets%ROWTYPE;
DECLARE reservation_row roomscan.portal_asset_reservations%ROWTYPE;
DECLARE receipt_row roomscan.portal_delivery_receipts%ROWTYPE;
DECLARE usage_row roomscan.quota_usage_v2%ROWTYPE;
DECLARE quota_period_key text;
DECLARE policy_version bigint;
DECLARE quota_request_key text;
BEGIN
  IF requested_asset_public_id IS NULL OR requested_request_digest IS NULL
    OR requested_byte_offset IS NULL OR requested_byte_length IS NULL
    OR requested_object_version IS NULL
    OR octet_length(requested_request_digest) <> 32
    OR requested_byte_offset < 0 OR requested_byte_length <= 0
    OR requested_byte_length > 4194304
    OR length(requested_object_version) NOT BETWEEN 1 AND 1024
    OR requested_object_version ~ '[[:cntrl:]]' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PORTAL_ASSET_FINALIZATION';
  END IF;
  -- This live context check is deliberately repeated immediately before the
  -- service emits bytes, so a revoke or kill between read and finalization
  -- produces no charge and no valid delivery receipt.
  SELECT context.* INTO context_row
  FROM roomscan.portal_session_context_v1(requested_session_hash, authoritative_time) AS context;
  SELECT asset.* INTO asset_row
  FROM roomscan.publication_assets AS asset
  WHERE asset.workspace_id = context_row.workspace_id
    AND asset.public_id = requested_asset_public_id
    AND asset.snapshot_id = context_row.snapshot_id;
  IF NOT FOUND OR asset_row.object_version IS DISTINCT FROM requested_object_version
    OR requested_byte_length > asset_row.bytes
    OR requested_byte_offset > asset_row.bytes - requested_byte_length THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PORTAL_ASSET_NOT_FOUND';
  END IF;
  IF (asset_row.asset_kind = 'ai_ready_package' OR asset_row.download_kind = 'ai_ready_package')
    AND context_row.ai_enabled IS DISTINCT FROM true THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PORTAL_AI_DOWNLOAD_DISABLED';
  END IF;
  PERFORM pg_advisory_xact_lock(
    hashtextextended(encode(requested_request_digest, 'hex'), 0)
  );
  SELECT reservation.* INTO reservation_row
  FROM roomscan.portal_asset_reservations AS reservation
  WHERE reservation.workspace_id = context_row.workspace_id
    AND reservation.request_digest = requested_request_digest
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PORTAL_DELIVERY_RESERVATION_REQUIRED';
  END IF;
  IF reservation_row.session_id IS DISTINCT FROM context_row.session_id
    OR reservation_row.asset_id IS DISTINCT FROM asset_row.asset_id
    OR reservation_row.link_id IS DISTINCT FROM context_row.link_id
    OR reservation_row.link_generation IS DISTINCT FROM context_row.link_generation
    OR reservation_row.snapshot_id IS DISTINCT FROM context_row.snapshot_id
    OR reservation_row.asset_object_version IS DISTINCT FROM requested_object_version
    OR reservation_row.byte_offset IS DISTINCT FROM requested_byte_offset
    OR reservation_row.byte_length IS DISTINCT FROM requested_byte_length THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PORTAL_DELIVERY_IDEMPOTENCY_REUSED';
  END IF;
  IF reservation_row.state = 'delivered' THEN
    SELECT receipt.* INTO receipt_row
    FROM roomscan.portal_delivery_receipts AS receipt
    WHERE receipt.workspace_id = context_row.workspace_id
      AND receipt.request_digest = requested_request_digest;
    IF NOT FOUND OR receipt_row.asset_object_version IS DISTINCT FROM requested_object_version
      OR receipt_row.byte_offset IS DISTINCT FROM requested_byte_offset
      OR receipt_row.byte_length IS DISTINCT FROM requested_byte_length
      OR receipt_row.delivered_bytes IS DISTINCT FROM requested_byte_length THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PORTAL_DELIVERY_RECEIPT_INVALID';
    END IF;
    RETURN QUERY SELECT 'allowed'::text, asset_row.public_id, asset_row.object_key,
      asset_row.object_version, asset_row.content_type, asset_row.bytes,
      requested_byte_offset, requested_byte_length, requested_byte_length, true;
    RETURN;
  END IF;
  SELECT policy.version, policy.portal_period_key INTO policy_version, quota_period_key
  FROM roomscan.quota_policy_versions_v2 AS policy
  WHERE policy.workspace_id = context_row.workspace_id AND policy.is_active IS TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PORTAL_QUOTA_UNAVAILABLE';
  END IF;
  SELECT usage.* INTO usage_row
  FROM roomscan.quota_usage_v2 AS usage
  WHERE usage.workspace_id = context_row.workspace_id
    AND usage.metric = 'portal_bytes' AND usage.period_key = quota_period_key
  FOR UPDATE;
  IF NOT FOUND OR usage_row.used + usage_row.reserved + requested_byte_length > usage_row.limit_value THEN
    RAISE EXCEPTION USING ERRCODE = '42900', MESSAGE = 'PORTAL_QUOTA_EXCEEDED';
  END IF;
  UPDATE roomscan.quota_usage_v2 AS usage
  SET used = usage.used + requested_byte_length, updated_at = authoritative_time
  WHERE usage.workspace_id = context_row.workspace_id
    AND usage.metric = 'portal_bytes' AND usage.period_key = quota_period_key;
  quota_request_key := 'portal-delivery:' || encode(requested_request_digest, 'hex');
  INSERT INTO roomscan.quota_ledger_v2 (
    workspace_id, period_key, idempotency_key, action, metric,
    delta_used, delta_reserved, policy_version, recorded_at
  ) VALUES (
    context_row.workspace_id, quota_period_key, quota_request_key, 'finalize',
    'portal_bytes', requested_byte_length, 0, policy_version, authoritative_time
  );
  INSERT INTO roomscan.portal_delivery_receipts (
    workspace_id, request_digest, session_id, link_id, link_generation, snapshot_id,
    asset_id, asset_object_version, byte_offset, byte_length, delivered_bytes, delivered_at
  ) VALUES (
    context_row.workspace_id, requested_request_digest, context_row.session_id,
    context_row.link_id, context_row.link_generation, context_row.snapshot_id,
    asset_row.asset_id, requested_object_version, requested_byte_offset,
    requested_byte_length, requested_byte_length, authoritative_time
  );
  UPDATE roomscan.portal_asset_reservations AS reservation
  SET state = 'delivered', delivered_at = authoritative_time
  WHERE reservation.workspace_id = reservation_row.workspace_id
    AND reservation.request_digest = reservation_row.request_digest;
  PERFORM roomscan.publication_append_access_event_v1(
    context_row.workspace_id, context_row.link_id, context_row.link_generation,
    context_row.snapshot_id, 'asset', 'allowed', authoritative_time,
    context_row.client_family, context_row.network_risk_digest
  );
  RETURN QUERY SELECT 'allowed'::text, asset_row.public_id, asset_row.object_key,
    asset_row.object_version, asset_row.content_type, asset_row.bytes,
    requested_byte_offset, requested_byte_length, requested_byte_length, false;
END
$function$;

CREATE FUNCTION roomscan.portal_authorize_download_v1(
  requested_session_hash bytea,
  authoritative_time timestamptz,
  requested_download_kind text,
  requested_request_digest bytea,
  requested_byte_offset bigint,
  requested_byte_length bigint
)
RETURNS TABLE (
  status text,
  asset_public_id text,
  object_key text,
  object_version text,
  content_type text,
  asset_bytes bigint,
  byte_offset bigint,
  byte_length bigint,
  delivered_bytes bigint,
  already_accounted boolean
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE asset_public_id text;
BEGIN
  IF requested_download_kind IS NULL OR requested_download_kind NOT IN (
    'floor_plan_pdf', 'gallery_zip', 'ai_ready_package'
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PORTAL_DOWNLOAD';
  END IF;
  SELECT context.* INTO context_row
  FROM roomscan.portal_session_context_v1(requested_session_hash, authoritative_time) AS context;
  IF requested_download_kind = 'ai_ready_package'
    AND context_row.ai_enabled IS DISTINCT FROM true THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PORTAL_AI_DOWNLOAD_DISABLED';
  END IF;
  SELECT asset.public_id INTO asset_public_id
  FROM roomscan.publication_assets AS asset
  WHERE asset.workspace_id = context_row.workspace_id
    AND asset.snapshot_id = context_row.snapshot_id
    AND asset.download_kind = requested_download_kind
  ORDER BY asset.public_id
  LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PORTAL_DOWNLOAD_NOT_FOUND';
  END IF;
  RETURN QUERY SELECT * FROM roomscan.portal_authorize_asset_v1(
    requested_session_hash, authoritative_time, asset_public_id,
    requested_request_digest, requested_byte_offset, requested_byte_length
  );
END
$function$;

CREATE FUNCTION roomscan.publication_upsert_property_v1(
  requested_credential_kind text,
  requested_credential_hash bytea,
  authoritative_time timestamptz,
  requested_property_public_id text,
  requested_expected_version bigint,
  requested_title text,
  requested_rooms jsonb
)
RETURNS TABLE (
  status text,
  property_id uuid,
  property_public_id text,
  curation_version bigint,
  room_count integer
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE existing roomscan.publication_properties%ROWTYPE;
DECLARE new_property_id uuid := gen_random_uuid();
DECLARE created boolean := false;
BEGIN
  -- `authoritative_time` is a controlled server-runtime clock value.  The
  -- SECURITY DEFINER routine is executable only by roomscan_api_runtime; no
  -- browser/native database principal can choose a publication timestamp.
  IF requested_credential_kind IS NULL OR requested_credential_hash IS NULL OR authoritative_time IS NULL
    OR requested_property_public_id IS NULL OR requested_expected_version IS NULL
    OR requested_title IS NULL OR requested_rooms IS NULL
    OR octet_length(requested_credential_hash) <> 32
    OR requested_expected_version < 0
    OR length(requested_property_public_id) NOT BETWEEN 21 AND 134
    OR requested_property_public_id !~ '^prop_[A-Za-z0-9_-]{16,128}$'
    OR length(requested_title) NOT BETWEEN 1 AND 180
    OR jsonb_typeof(requested_rooms) <> 'array'
    OR jsonb_array_length(requested_rooms) > 64 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_PROPERTY';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(requested_rooms) AS item(value)
    WHERE jsonb_typeof(item.value) <> 'object'
      OR jsonb_typeof(item.value -> 'publicRoomKey') IS DISTINCT FROM 'string'
      OR jsonb_typeof(item.value -> 'projectPublicID') IS DISTINCT FROM 'string'
      OR EXISTS (
        SELECT 1 FROM jsonb_object_keys(item.value) AS key(name)
        WHERE key.name NOT IN ('publicRoomKey', 'projectPublicID')
      )
      OR item.value ->> 'publicRoomKey' !~ '^[A-Za-z0-9_.-]{1,128}$'
      OR item.value ->> 'projectPublicID' !~ '^prj_[A-Za-z0-9_-]{16,128}$'
  ) OR EXISTS (
    SELECT item.value ->> 'publicRoomKey'
    FROM jsonb_array_elements(requested_rooms) AS item(value)
    GROUP BY item.value ->> 'publicRoomKey' HAVING count(*) > 1
  ) OR EXISTS (
    SELECT item.value ->> 'projectPublicID'
    FROM jsonb_array_elements(requested_rooms) AS item(value)
    GROUP BY item.value ->> 'projectPublicID' HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_PROPERTY_ROOMS';
  END IF;
  SELECT context.* INTO context_row
  FROM roomscan.publication_resolve_api_access_v1(
    requested_credential_kind, requested_credential_hash, authoritative_time,
    NULL, 'project.revise'
  ) AS context;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PUBLICATION_AUTHORIZATION_REQUIRED';
  END IF;
  SELECT property.* INTO existing
  FROM roomscan.publication_properties AS property
  WHERE property.workspace_id = context_row.workspace_id
    AND property.public_id = requested_property_public_id
  FOR UPDATE;
  IF FOUND THEN
    IF requested_expected_version < 1
      OR existing.version IS DISTINCT FROM requested_expected_version THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_PROPERTY_VERSION_STALE';
    END IF;
    UPDATE roomscan.publication_properties AS property
    SET title = requested_title, version = property.version + 1,
        updated_at = authoritative_time
    WHERE property.workspace_id = context_row.workspace_id
      AND property.property_id = existing.property_id
    RETURNING property.* INTO existing;
  ELSE
    IF requested_expected_version <> 0 THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_PROPERTY_VERSION_STALE';
    END IF;
    INSERT INTO roomscan.publication_properties (
      workspace_id, property_id, public_id, title, created_by_principal_id,
      created_at, updated_at
    ) VALUES (
      context_row.workspace_id, new_property_id, requested_property_public_id,
      requested_title, context_row.principal_id, authoritative_time, authoritative_time
    ) RETURNING * INTO existing;
    created := true;
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(requested_rooms) AS item(value)
    LEFT JOIN roomscan.professional_projects AS project
      ON project.workspace_id = context_row.workspace_id
      AND project.public_id = item.value ->> 'projectPublicID'
    WHERE project.project_id IS NULL
  ) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_PROPERTY_ROOM_NOT_FOUND';
  END IF;
  DELETE FROM roomscan.publication_property_rooms AS rooms
  WHERE rooms.workspace_id = context_row.workspace_id
    AND rooms.property_id = existing.property_id;
  INSERT INTO roomscan.publication_property_rooms (
    workspace_id, property_id, room_order, room_key, room_project_id,
    room_project_public_id, added_at
  )
  SELECT context_row.workspace_id, existing.property_id, item.ordinality::integer,
    item.value ->> 'publicRoomKey', project.project_id, project.public_id,
    authoritative_time
  FROM jsonb_array_elements(requested_rooms) WITH ORDINALITY AS item(value, ordinality)
  JOIN roomscan.professional_projects AS project
    ON project.workspace_id = context_row.workspace_id
    AND project.public_id = item.value ->> 'projectPublicID'
  ORDER BY item.ordinality;
  RETURN QUERY SELECT CASE WHEN created THEN 'created' ELSE 'updated' END,
    existing.property_id, existing.public_id, existing.version,
    jsonb_array_length(requested_rooms);
END
$function$;

-- v2 separates crash-safe property creation from the first room's identity.
-- The service supplies a distinct server-HMAC digest for its stable local
-- property identity; the database generates the hosted prop_ ID only once.
CREATE FUNCTION roomscan.publication_upsert_property_v2(
  requested_credential_kind text,
  requested_credential_hash bytea,
  authoritative_time timestamptz,
  requested_property_public_id text,
  requested_expected_version bigint,
  requested_create_idempotency_digest bytea,
  requested_title text,
  requested_rooms jsonb
)
RETURNS TABLE (
  status text,
  property_id uuid,
  property_public_id text,
  curation_version bigint,
  room_count integer
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE existing roomscan.publication_properties%ROWTYPE;
DECLARE new_property_id uuid := gen_random_uuid();
DECLARE new_property_public_id text;
DECLARE existing_rooms jsonb;
DECLARE created boolean := false;
BEGIN
  IF requested_credential_kind IS NULL OR requested_credential_hash IS NULL
    OR authoritative_time IS NULL OR requested_expected_version IS NULL
    OR requested_title IS NULL OR requested_rooms IS NULL
    OR octet_length(requested_credential_hash) <> 32
    OR requested_expected_version < 0
    OR length(requested_title) NOT BETWEEN 1 AND 180
    OR jsonb_typeof(requested_rooms) <> 'array'
    OR jsonb_array_length(requested_rooms) > 64
    OR (requested_create_idempotency_digest IS NOT NULL
      AND octet_length(requested_create_idempotency_digest) <> 32)
    OR (requested_property_public_id IS NOT NULL AND (
      length(requested_property_public_id) NOT BETWEEN 21 AND 134
      OR requested_property_public_id !~ '^prop_[A-Za-z0-9_-]{16,128}$'
    )) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_PROPERTY';
  END IF;
  IF requested_property_public_id IS NULL
    AND (requested_expected_version <> 0 OR requested_create_idempotency_digest IS NULL) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_PROPERTY_CREATE';
  END IF;
  IF requested_property_public_id IS NOT NULL
    AND requested_expected_version = 0 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_PROPERTY_UPDATE';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(requested_rooms) AS item(value)
    WHERE jsonb_typeof(item.value) <> 'object'
      OR jsonb_typeof(item.value -> 'publicRoomKey') IS DISTINCT FROM 'string'
      OR jsonb_typeof(item.value -> 'projectPublicID') IS DISTINCT FROM 'string'
      OR EXISTS (
        SELECT 1 FROM jsonb_object_keys(item.value) AS key(name)
        WHERE key.name NOT IN ('publicRoomKey', 'projectPublicID')
      )
      OR item.value ->> 'publicRoomKey' !~ '^[A-Za-z0-9_.-]{1,128}$'
      OR item.value ->> 'projectPublicID' !~ '^prj_[A-Za-z0-9_-]{16,128}$'
  ) OR EXISTS (
    SELECT item.value ->> 'publicRoomKey'
    FROM jsonb_array_elements(requested_rooms) AS item(value)
    GROUP BY item.value ->> 'publicRoomKey' HAVING count(*) > 1
  ) OR EXISTS (
    SELECT item.value ->> 'projectPublicID'
    FROM jsonb_array_elements(requested_rooms) AS item(value)
    GROUP BY item.value ->> 'projectPublicID' HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_PROPERTY_ROOMS';
  END IF;
  SELECT context.* INTO context_row
  FROM roomscan.publication_resolve_api_access_v1(
    requested_credential_kind, requested_credential_hash, authoritative_time,
    NULL, 'project.revise'
  ) AS context;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PUBLICATION_AUTHORIZATION_REQUIRED';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(requested_rooms) AS item(value)
    LEFT JOIN roomscan.professional_projects AS project
      ON project.workspace_id = context_row.workspace_id
      AND project.public_id = item.value ->> 'projectPublicID'
    WHERE project.project_id IS NULL
  ) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_PROPERTY_ROOM_NOT_FOUND';
  END IF;

  IF requested_property_public_id IS NULL THEN
    -- The advisory key is only a concurrency serializer; no caller-controlled
    -- tenant or principal identity is trusted outside the resolved context.
    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
      'publication-property-create:' || context_row.workspace_id::text || ':'
        || context_row.principal_id::text || ':'
        || pg_catalog.encode(requested_create_idempotency_digest, 'hex'),
      7621846213719043
    ));
    SELECT property.* INTO existing
    FROM roomscan.publication_properties AS property
    WHERE property.workspace_id = context_row.workspace_id
      AND property.created_by_principal_id = context_row.principal_id
      AND property.create_idempotency_digest = requested_create_idempotency_digest
    FOR UPDATE;
    IF FOUND THEN
      SELECT COALESCE(pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'publicRoomKey', rooms.room_key,
          'projectPublicID', rooms.room_project_public_id
        ) ORDER BY rooms.room_order
      ), '[]'::jsonb) INTO existing_rooms
      FROM roomscan.publication_property_rooms AS rooms
      WHERE rooms.workspace_id = existing.workspace_id
        AND rooms.property_id = existing.property_id;
      IF existing.title IS DISTINCT FROM requested_title
        OR existing_rooms IS DISTINCT FROM requested_rooms THEN
        RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_PROPERTY_IDEMPOTENCY_CONFLICT';
      END IF;
      RETURN QUERY SELECT 'existing'::text, existing.property_id, existing.public_id,
        existing.version, jsonb_array_length(requested_rooms);
      RETURN;
    END IF;
    new_property_public_id := 'prop_' || replace(gen_random_uuid()::text, '-', '');
    INSERT INTO roomscan.publication_properties (
      workspace_id, property_id, public_id, title, created_by_principal_id,
      created_at, updated_at, create_idempotency_digest
    ) VALUES (
      context_row.workspace_id, new_property_id, new_property_public_id,
      requested_title, context_row.principal_id, authoritative_time,
      authoritative_time, requested_create_idempotency_digest
    ) RETURNING * INTO existing;
    created := true;
  ELSE
    SELECT property.* INTO existing
    FROM roomscan.publication_properties AS property
    WHERE property.workspace_id = context_row.workspace_id
      AND property.public_id = requested_property_public_id
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_PROPERTY_NOT_FOUND';
    END IF;
    IF existing.version IS DISTINCT FROM requested_expected_version THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_PROPERTY_VERSION_STALE';
    END IF;
    UPDATE roomscan.publication_properties AS property
    SET title = requested_title, version = property.version + 1,
        updated_at = authoritative_time
    WHERE property.workspace_id = existing.workspace_id
      AND property.property_id = existing.property_id
    RETURNING property.* INTO existing;
  END IF;

  DELETE FROM roomscan.publication_property_rooms AS rooms
  WHERE rooms.workspace_id = context_row.workspace_id
    AND rooms.property_id = existing.property_id;
  INSERT INTO roomscan.publication_property_rooms (
    workspace_id, property_id, room_order, room_key, room_project_id,
    room_project_public_id, added_at
  )
  SELECT context_row.workspace_id, existing.property_id, item.ordinality::integer,
    item.value ->> 'publicRoomKey', project.project_id, project.public_id,
    authoritative_time
  FROM jsonb_array_elements(requested_rooms) WITH ORDINALITY AS item(value, ordinality)
  JOIN roomscan.professional_projects AS project
    ON project.workspace_id = context_row.workspace_id
    AND project.public_id = item.value ->> 'projectPublicID'
  ORDER BY item.ordinality;
  RETURN QUERY SELECT CASE WHEN created THEN 'created' ELSE 'updated' END,
    existing.property_id, existing.public_id, existing.version,
    jsonb_array_length(requested_rooms);
END
$function$;

CREATE FUNCTION roomscan.publication_add_property_room_v1(
  requested_credential_kind text,
  requested_credential_hash bytea,
  authoritative_time timestamptz,
  requested_property_public_id text,
  requested_room_key text,
  requested_room_order integer,
  requested_room_project_public_id text
)
RETURNS TABLE (status text, property_public_id text, room_key text, room_order integer)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE property_row roomscan.publication_properties%ROWTYPE;
DECLARE room_project_row roomscan.professional_projects%ROWTYPE;
BEGIN
  IF requested_credential_kind IS NULL OR requested_credential_hash IS NULL OR authoritative_time IS NULL
    OR requested_property_public_id IS NULL OR requested_room_key IS NULL
    OR requested_room_order IS NULL OR requested_room_project_public_id IS NULL
    OR octet_length(requested_credential_hash) <> 32
    OR length(requested_property_public_id) NOT BETWEEN 21 AND 134
    OR length(requested_room_key) NOT BETWEEN 1 AND 128
    OR requested_room_key !~ '^[A-Za-z0-9_.-]+$'
    OR requested_room_order < 1 OR requested_room_order > 1000
    OR requested_room_project_public_id !~ '^prj_[A-Za-z0-9_-]{16,128}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_PROPERTY_ROOM';
  END IF;
  SELECT context.* INTO context_row
  FROM roomscan.publication_resolve_api_access_v1(
    requested_credential_kind, requested_credential_hash, authoritative_time,
    NULL, 'project.revise'
  ) AS context;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PUBLICATION_AUTHORIZATION_REQUIRED';
  END IF;
  SELECT property.* INTO property_row
  FROM roomscan.publication_properties AS property
  WHERE property.workspace_id = context_row.workspace_id
    AND property.public_id = requested_property_public_id
  FOR UPDATE;
  SELECT project.* INTO room_project_row
  FROM roomscan.professional_projects AS project
  WHERE project.workspace_id = context_row.workspace_id
    AND project.public_id = requested_room_project_public_id
  FOR SHARE;
  IF NOT FOUND OR property_row.property_id IS NULL OR room_project_row.project_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_PROPERTY_ROOM_NOT_FOUND';
  END IF;
  INSERT INTO roomscan.publication_property_rooms (
    workspace_id, property_id, room_order, room_key, room_project_id,
    room_project_public_id, added_at
  ) VALUES (
    context_row.workspace_id, property_row.property_id, requested_room_order,
    requested_room_key, room_project_row.project_id,
    room_project_row.public_id, authoritative_time
  )
  ON CONFLICT ON CONSTRAINT publication_property_rooms_room_key_unique DO UPDATE
    SET room_order = EXCLUDED.room_order, room_project_id = EXCLUDED.room_project_id,
        room_project_public_id = EXCLUDED.room_project_public_id,
        added_at = EXCLUDED.added_at;
  -- This version is captured with a property allocation and rechecked under
  -- the finalizer's lock. A draft change cannot silently alter a pending
  -- approved property presentation.
  UPDATE roomscan.publication_properties AS property
  SET version = property.version + 1, updated_at = authoritative_time
  WHERE property.workspace_id = property_row.workspace_id
    AND property.property_id = property_row.property_id;
  RETURN QUERY SELECT 'upserted'::text, requested_property_public_id,
    requested_room_key, requested_room_order;
END
$function$;

CREATE FUNCTION roomscan.publication_claim_job_v1(authoritative_time timestamptz)
RETURNS TABLE (
  status text,
  job_id uuid,
  allocation_id uuid,
  allocation_public_id text,
  lease_id text,
  lease_expires_at timestamptz,
  source_revision_public_id text,
  source_revision_digest bytea,
  source_manifest_digest bytea,
  source_bindings_digest bytea,
  selection_digest bytea,
  approval_digest bytea,
  archive_digest bytea,
  archive_manifest_digest bytea,
  archive_bytes bigint,
  quarantine_key text,
  quarantine_version text
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE job_row roomscan.publication_jobs%ROWTYPE;
DECLARE allocation roomscan.publication_allocations%ROWTYPE;
DECLARE new_lease_id text := 'pwl_' || replace(gen_random_uuid()::text, '-', '');
BEGIN
  PERFORM roomscan.publication_require_worker_v1();
  IF authoritative_time IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_CLAIM_TIME';
  END IF;
  SELECT job.* INTO job_row
  FROM roomscan.publication_jobs AS job
  WHERE (job.state = 'pending'
    OR (job.state = 'claimed' AND job.lease_expires_at <= authoritative_time))
  ORDER BY job.created_at, job.job_id
  FOR UPDATE SKIP LOCKED
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN;
  END IF;
  SELECT candidate.* INTO allocation
  FROM roomscan.publication_allocations AS candidate
  WHERE candidate.workspace_id = job_row.workspace_id
    AND candidate.allocation_id = job_row.allocation_id
  FOR UPDATE;
  IF allocation.allocation_expires_at <= authoritative_time THEN
    UPDATE roomscan.publication_jobs AS job
    SET state = 'rejected', rejection_code = 'allocation_expired',
        updated_at = authoritative_time, lease_id = NULL, lease_expires_at = NULL
    WHERE job.workspace_id = job_row.workspace_id AND job.job_id = job_row.job_id;
    UPDATE roomscan.publication_allocations AS target
    SET state = 'rejected', updated_at = authoritative_time
    WHERE target.workspace_id = allocation.workspace_id
      AND target.allocation_id = allocation.allocation_id;
    RETURN QUERY SELECT 'allocation_expired'::text, job_row.job_id,
      allocation.allocation_id, allocation.allocation_public_id, NULL::text,
      NULL::timestamptz, allocation.source_revision_public_id,
      allocation.source_revision_digest, allocation.source_manifest_digest,
      allocation.source_bindings_digest,
      allocation.selection_digest, allocation.approval_digest,
      allocation.archive_digest, allocation.archive_manifest_digest,
      allocation.archive_bytes, allocation.quarantine_key,
      allocation.quarantine_version;
    RETURN;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM roomscan.global_operational_flags AS hosted_global
    WHERE hosted_global.flag_key = 'hosted_operations_enabled'
      AND hosted_global.enabled IS TRUE
      AND hosted_global.version = allocation.hosted_global_version
  ) OR NOT EXISTS (
    SELECT 1 FROM roomscan.workspace_operational_flags AS hosted_workspace
    WHERE hosted_workspace.workspace_id = allocation.workspace_id
      AND hosted_workspace.flag_key = 'hosted_operations_enabled'
      AND hosted_workspace.enabled IS TRUE
      AND hosted_workspace.version = allocation.hosted_workspace_version
  ) OR NOT EXISTS (
    SELECT 1 FROM roomscan.global_operational_flags AS publication_global
    WHERE publication_global.flag_key = 'publication_enabled'
      AND publication_global.enabled IS TRUE
      AND publication_global.version = allocation.publication_global_version
  ) OR NOT EXISTS (
    SELECT 1 FROM roomscan.workspace_operational_flags AS publication_workspace
    WHERE publication_workspace.workspace_id = allocation.workspace_id
      AND publication_workspace.flag_key = 'publication_enabled'
      AND publication_workspace.enabled IS TRUE
      AND publication_workspace.version = allocation.publication_workspace_version
  ) THEN
    -- A killed epoch is terminal for this approved allocation. Leaving the
    -- pending row claimable would let the worker loop forever after a rollback
    -- barrier; a re-enable requires a new allocation under fresh epochs.
    UPDATE roomscan.publication_jobs AS job
    SET state = 'rejected', rejection_code = 'publication_disabled',
        lease_id = NULL, lease_expires_at = NULL, updated_at = authoritative_time
    WHERE job.workspace_id = job_row.workspace_id AND job.job_id = job_row.job_id;
    UPDATE roomscan.publication_allocations AS target
    SET state = 'rejected', updated_at = authoritative_time
    WHERE target.workspace_id = allocation.workspace_id
      AND target.allocation_id = allocation.allocation_id;
    RETURN QUERY SELECT 'publication_disabled'::text, job_row.job_id,
      allocation.allocation_id, allocation.allocation_public_id, NULL::text,
      NULL::timestamptz, allocation.source_revision_public_id,
      allocation.source_revision_digest, allocation.source_manifest_digest,
      allocation.source_bindings_digest,
      allocation.selection_digest, allocation.approval_digest,
      allocation.archive_digest, allocation.archive_manifest_digest,
      allocation.archive_bytes, allocation.quarantine_key,
      allocation.quarantine_version;
    RETURN;
  END IF;
  UPDATE roomscan.publication_jobs AS job
  SET state = 'claimed', lease_id = new_lease_id,
      lease_expires_at = authoritative_time + interval '15 minutes',
      updated_at = authoritative_time
  WHERE job.workspace_id = job_row.workspace_id AND job.job_id = job_row.job_id;
  UPDATE roomscan.publication_allocations AS target
  SET state = 'validating', updated_at = authoritative_time
  WHERE target.workspace_id = allocation.workspace_id
    AND target.allocation_id = allocation.allocation_id;
  RETURN QUERY SELECT 'validating'::text, job_row.job_id,
    allocation.allocation_id, allocation.allocation_public_id, new_lease_id,
    authoritative_time + interval '15 minutes', allocation.source_revision_public_id,
    allocation.source_revision_digest, allocation.source_manifest_digest,
    allocation.source_bindings_digest,
    allocation.selection_digest, allocation.approval_digest,
    allocation.archive_digest, allocation.archive_manifest_digest,
    allocation.archive_bytes, allocation.quarantine_key,
    allocation.quarantine_version;
END
$function$;

-- A worker that has already claimed an exact quarantine version must be able
-- to terminally reject it.  This prevents an invalid archive, source, or
-- approval failure from returning to the pending queue after a crash/retry.
CREATE FUNCTION roomscan.publication_reject_v1(
  requested_allocation_id uuid,
  requested_lease_id text,
  authoritative_time timestamptz,
  requested_rejection_code text
)
RETURNS TABLE (status text, allocation_public_id text, rejection_code text)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE allocation roomscan.publication_allocations%ROWTYPE;
DECLARE job_row roomscan.publication_jobs%ROWTYPE;
BEGIN
  PERFORM roomscan.publication_require_worker_v1();
  IF requested_allocation_id IS NULL OR requested_lease_id IS NULL
    OR authoritative_time IS NULL
    OR requested_rejection_code NOT IN (
      'allocation_expired', 'source_changed', 'approval_changed',
      'invalid_archive', 'publication_disabled', 'quota_unavailable'
    )
    OR length(requested_lease_id) NOT BETWEEN 20 AND 137
    OR requested_lease_id !~ '^pwl_[A-Za-z0-9_-]{16,128}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_REJECTION';
  END IF;
  SELECT target.* INTO allocation
  FROM roomscan.publication_allocations AS target
  WHERE target.allocation_id = requested_allocation_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_ALLOCATION_NOT_FOUND';
  END IF;
  SELECT target.* INTO job_row
  FROM roomscan.publication_jobs AS target
  WHERE target.workspace_id = allocation.workspace_id
    AND target.allocation_id = allocation.allocation_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_VALIDATION_LEASE_REQUIRED';
  END IF;
  IF job_row.state = 'rejected' AND allocation.state = 'rejected'
    AND job_row.rejection_code = requested_rejection_code THEN
    RETURN QUERY SELECT 'existing'::text, allocation.allocation_public_id,
      job_row.rejection_code;
    RETURN;
  END IF;
  IF allocation.state <> 'validating' OR job_row.state <> 'claimed'
    OR job_row.lease_id IS DISTINCT FROM requested_lease_id
    OR job_row.lease_expires_at <= authoritative_time THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_VALIDATION_LEASE_REQUIRED';
  END IF;
  UPDATE roomscan.publication_jobs AS target
  SET state = 'rejected', rejection_code = requested_rejection_code,
      lease_id = NULL, lease_expires_at = NULL, updated_at = authoritative_time
  WHERE target.workspace_id = job_row.workspace_id AND target.job_id = job_row.job_id;
  UPDATE roomscan.publication_allocations AS target
  SET state = 'rejected', updated_at = authoritative_time
  WHERE target.workspace_id = allocation.workspace_id
    AND target.allocation_id = allocation.allocation_id;
  RETURN QUERY SELECT 'rejected'::text, allocation.allocation_public_id,
    requested_rejection_code;
END
$function$;

CREATE FUNCTION roomscan.publication_validate_asset_manifest_v1(
  requested_assets jsonb
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  IF requested_assets IS NULL OR jsonb_typeof(requested_assets) <> 'array'
    OR jsonb_array_length(requested_assets) < 1
    OR jsonb_array_length(requested_assets) > 256 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_ASSET_MANIFEST';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(requested_assets) AS item(value)
    WHERE jsonb_typeof(item.value) <> 'object'
      OR NOT (item.value ? 'asset_id')
      OR NOT (item.value ? 'kind')
      OR NOT (item.value ? 'object_key')
      OR NOT (item.value ? 'object_version')
      OR NOT (item.value ? 'digest_hex')
      OR NOT (item.value ? 'bytes')
      OR NOT (item.value ? 'download_kind')
      OR EXISTS (
        SELECT 1 FROM jsonb_object_keys(item.value) AS key(name)
        WHERE key.name NOT IN (
          'asset_id', 'kind', 'object_key', 'object_version',
          'digest_hex', 'bytes', 'download_kind', 'content_type'
        )
      )
      OR item.value->>'asset_id' !~ '^ast_[A-Za-z0-9_-]{16,128}$'
      OR item.value->>'kind' NOT IN (
        'presentation', 'web_geometry', 'web_texture', 'selected_image',
        'floor_plan', 'approved_concept', 'floor_plan_pdf', 'gallery_zip',
        'ai_ready_package'
      )
      OR item.value->>'object_key' !~ '^server/published/active/v1/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+[.]bin$'
      OR item.value->>'object_key' ~ '[.][.]'
      OR length(item.value->>'object_version') NOT BETWEEN 1 AND 1024
      OR item.value->>'object_version' ~ '[[:cntrl:]]'
      OR item.value->>'digest_hex' !~ '^[0-9a-fA-F]{64}$'
      OR (item.value->>'bytes') !~ '^[0-9]+$'
      OR (item.value->>'bytes')::bigint <= 0
      OR (item.value->>'kind' IN ('presentation', 'web_geometry')
        AND (item.value->>'bytes')::bigint > 8388608)
      OR (item.value->>'kind' = 'ai_ready_package'
        AND (item.value->>'bytes')::bigint > 536870912)
      OR (item.value->>'kind' NOT IN ('presentation', 'web_geometry', 'ai_ready_package')
        AND (item.value->>'bytes')::bigint > 33554432)
      OR COALESCE(item.value->>'content_type',
          CASE WHEN item.value->>'kind' IN ('web_geometry', 'presentation')
            THEN 'application/json' ELSE 'image/png' END)
        NOT IN ('application/json', 'image/png', 'image/jpeg', 'application/pdf', 'application/zip')
      OR (item.value->>'download_kind') IS NOT NULL
        AND item.value->>'download_kind' NOT IN ('floor_plan_pdf', 'gallery_zip', 'ai_ready_package')
      OR (item.value->>'kind' = 'floor_plan_pdf'
        AND ((item.value->>'download_kind') IS DISTINCT FROM 'floor_plan_pdf'
          OR COALESCE(item.value->>'content_type', '') <> 'application/pdf'))
      OR (item.value->>'kind' = 'gallery_zip'
        AND ((item.value->>'download_kind') IS DISTINCT FROM 'gallery_zip'
          OR COALESCE(item.value->>'content_type', '') <> 'application/zip'))
      OR (item.value->>'kind' = 'ai_ready_package'
        AND ((item.value->>'download_kind') IS DISTINCT FROM 'ai_ready_package'
          OR COALESCE(item.value->>'content_type', '') <> 'application/zip'))
      OR (item.value->>'kind' NOT IN ('floor_plan_pdf', 'gallery_zip', 'ai_ready_package')
        AND (item.value->>'download_kind') IS NOT NULL)
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_ASSET_MANIFEST';
  END IF;
  IF EXISTS (
    SELECT item.value->>'asset_id'
    FROM jsonb_array_elements(requested_assets) AS item(value)
    GROUP BY item.value->>'asset_id'
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'DUPLICATE_PUBLICATION_ASSET';
  END IF;
  IF EXISTS (
    SELECT item.value->>'download_kind'
    FROM jsonb_array_elements(requested_assets) AS item(value)
    WHERE item.value->>'download_kind' IS NOT NULL
    GROUP BY item.value->>'download_kind'
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'DUPLICATE_PUBLICATION_DOWNLOAD_KIND';
  END IF;
END
$function$;

CREATE FUNCTION roomscan.publication_finalize_v1(
  requested_allocation_id uuid,
  requested_lease_id text,
  authoritative_time timestamptz,
  requested_active_object_version text,
  requested_presentation_digest bytea,
  requested_source_bindings_digest bytea,
  requested_presentation_bytes bigint,
  requested_assets jsonb
)
RETURNS TABLE (status text, snapshot_id uuid, snapshot_public_id text)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE allocation roomscan.publication_allocations%ROWTYPE;
DECLARE job_row roomscan.publication_jobs%ROWTYPE;
DECLARE source_row roomscan.publication_sources%ROWTYPE;
DECLARE approval_row roomscan.publication_approvals%ROWTYPE;
DECLARE revision_row roomscan.project_revisions%ROWTYPE;
DECLARE property_row roomscan.publication_properties%ROWTYPE;
DECLARE current_property_membership_digest bytea;
DECLARE existing_snapshot roomscan.publication_snapshots%ROWTYPE;
DECLARE allocation_binding roomscan.publication_allocation_source_bindings%ROWTYPE;
DECLARE binding_project roomscan.professional_projects%ROWTYPE;
DECLARE binding_revision roomscan.project_revisions%ROWTYPE;
DECLARE locked_source_project_id uuid;
DECLARE new_snapshot_id uuid := gen_random_uuid();
DECLARE new_snapshot_public_id text := 'snp_' || replace(gen_random_uuid()::text, '-', '');
DECLARE asset jsonb;
DECLARE content_type text;
DECLARE new_asset_id uuid;
BEGIN
  PERFORM roomscan.publication_require_worker_v1();
  IF requested_allocation_id IS NULL OR requested_lease_id IS NULL
    OR authoritative_time IS NULL OR requested_active_object_version IS NULL
    OR requested_presentation_digest IS NULL OR requested_source_bindings_digest IS NULL
    OR requested_presentation_bytes IS NULL
    OR requested_assets IS NULL
    OR octet_length(requested_presentation_digest) <> 32
    OR octet_length(requested_source_bindings_digest) <> 32
    OR length(requested_lease_id) NOT BETWEEN 20 AND 137
    OR requested_lease_id !~ '^pwl_[A-Za-z0-9_-]{16,128}$'
    OR length(requested_active_object_version) NOT BETWEEN 1 AND 1024
    OR requested_active_object_version ~ '[[:cntrl:]]'
    OR requested_presentation_bytes <= 0 OR requested_presentation_bytes > 8388608 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_FINALIZATION';
  END IF;
  PERFORM roomscan.publication_validate_asset_manifest_v1(requested_assets);
  -- The finalizer's presentation ledger row is the sole authoritative portal
  -- manifest. It must bind exactly to the worker-validated digest and byte
  -- count; otherwise a portal lookup could become ambiguous or detached from
  -- the immutable snapshot row.
  IF (SELECT count(*)
        FROM jsonb_array_elements(requested_assets) AS item(value)
       WHERE item.value ->> 'kind' = 'presentation') <> 1
    OR NOT EXISTS (
      SELECT 1
      FROM jsonb_array_elements(requested_assets) AS item(value)
      WHERE item.value ->> 'kind' = 'presentation'
        AND item.value ->> 'download_kind' IS NULL
        AND COALESCE(item.value ->> 'content_type', '') = 'application/json'
        AND decode(item.value ->> 'digest_hex', 'hex') = requested_presentation_digest
        AND (item.value ->> 'bytes')::bigint = requested_presentation_bytes
    ) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_PRESENTATION_ASSET_INVALID';
  END IF;
  SELECT snapshot.* INTO existing_snapshot
  FROM roomscan.publication_snapshots AS snapshot
  WHERE snapshot.allocation_id = requested_allocation_id;
  IF FOUND THEN
    RETURN QUERY SELECT 'existing'::text, existing_snapshot.snapshot_id,
      existing_snapshot.public_id;
    RETURN;
  END IF;
  SELECT target.* INTO allocation
  FROM roomscan.publication_allocations AS target
  WHERE target.allocation_id = requested_allocation_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_ALLOCATION_NOT_FOUND';
  END IF;
  -- A concurrent retry can pass the optimistic lookup above before the first
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
  END IF;
  SELECT target.* INTO job_row
  FROM roomscan.publication_jobs AS target
  WHERE target.workspace_id = allocation.workspace_id
    AND target.allocation_id = allocation.allocation_id
  FOR UPDATE;
  IF NOT FOUND OR allocation.state <> 'validating'
    OR job_row.state <> 'claimed'
    OR job_row.lease_id IS DISTINCT FROM requested_lease_id
    OR job_row.lease_expires_at <= authoritative_time THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_VALIDATION_LEASE_REQUIRED';
  END IF;
  PERFORM roomscan.publication_require_live_grant_v1(
    allocation.workspace_id, 'publication.create',
    allocation.hosted_global_version, allocation.hosted_workspace_version,
    allocation.publication_global_version, allocation.publication_workspace_version
  );
  PERFORM roomscan.publication_check_quota_policy_v1(
    allocation.workspace_id, allocation.quota_policy_version
  );
  -- A property approval is a single immutable decision across its root and
  -- every independently bound room source. Lock the complete distinct project
  -- set in project-ID order before reading any source truth: locking the root
  -- first and secondary sources later would leave a concurrent Slice 5 head
  -- append able to commit between a secondary validation and snapshot insert.
  FOR locked_source_project_id IN
    SELECT source_project_id
    FROM (
      SELECT allocation.project_id AS source_project_id
      UNION
      SELECT binding.room_project_id
      FROM roomscan.publication_allocation_source_bindings AS binding
      WHERE binding.workspace_id = allocation.workspace_id
        AND binding.allocation_id = allocation.allocation_id
    ) AS source_project_ids
    ORDER BY source_project_id
  LOOP
    PERFORM 1
    FROM roomscan.professional_projects AS project
    WHERE project.workspace_id = allocation.workspace_id
      AND project.project_id = locked_source_project_id
    FOR SHARE;
  END LOOP;
  PERFORM roomscan.publication_require_source_binding_v1(
    allocation.workspace_id, allocation.project_id, allocation.source_revision_id,
    allocation.source_revision_public_id, allocation.source_revision_digest,
    allocation.source_manifest_digest
  );
  SELECT source.* INTO source_row
  FROM roomscan.publication_sources AS source
  WHERE source.workspace_id = allocation.workspace_id
    AND source.allocation_id = allocation.allocation_id;
  SELECT approval.* INTO approval_row
  FROM roomscan.publication_approvals AS approval
  WHERE approval.workspace_id = allocation.workspace_id
    AND approval.allocation_id = allocation.allocation_id;
  IF NOT FOUND
    OR source_row.source_revision_id IS DISTINCT FROM allocation.source_revision_id
    OR source_row.source_revision_public_id IS DISTINCT FROM allocation.source_revision_public_id
    OR source_row.source_revision_digest IS DISTINCT FROM allocation.source_revision_digest
    OR source_row.source_manifest_digest IS DISTINCT FROM allocation.source_manifest_digest
    OR source_row.source_bindings_digest IS DISTINCT FROM allocation.source_bindings_digest
    OR source_row.selection_digest IS DISTINCT FROM allocation.selection_digest
    OR approval_row.source_revision_id IS DISTINCT FROM allocation.source_revision_id
    OR approval_row.source_revision_public_id IS DISTINCT FROM allocation.source_revision_public_id
    OR approval_row.source_revision_digest IS DISTINCT FROM allocation.source_revision_digest
    OR approval_row.source_manifest_digest IS DISTINCT FROM allocation.source_manifest_digest
    OR approval_row.source_bindings_digest IS DISTINCT FROM allocation.source_bindings_digest
    OR approval_row.selection_digest IS DISTINCT FROM allocation.selection_digest
    OR approval_row.approval_digest IS DISTINCT FROM allocation.approval_digest
    OR requested_source_bindings_digest IS DISTINCT FROM allocation.source_bindings_digest
    OR source_row.property_membership_digest IS DISTINCT FROM allocation.property_membership_digest
    OR approval_row.property_membership_digest IS DISTINCT FROM allocation.property_membership_digest THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_APPROVAL_BINDING_INVALID';
  END IF;
  IF allocation.publication_kind = 'property' THEN
    SELECT property.* INTO property_row
    FROM roomscan.publication_properties AS property
    WHERE property.workspace_id = allocation.workspace_id
      AND property.property_id = allocation.property_id
    FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_PROPERTY_NOT_FOUND';
    END IF;
    current_property_membership_digest := roomscan.publication_property_membership_digest_v1(
      allocation.workspace_id, property_row.property_id
    );
    IF property_row.version IS DISTINCT FROM allocation.property_curation_version
      OR current_property_membership_digest IS DISTINCT FROM allocation.property_membership_digest THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_PROPERTY_CURATOR_CHANGED';
    END IF;
  END IF;
  FOR allocation_binding IN
    SELECT binding.*
    FROM roomscan.publication_allocation_source_bindings AS binding
    WHERE binding.workspace_id = allocation.workspace_id
      AND binding.allocation_id = allocation.allocation_id
    ORDER BY binding.room_order
  LOOP
    SELECT project.* INTO binding_project
    FROM roomscan.professional_projects AS project
    WHERE project.workspace_id = allocation.workspace_id
      AND project.project_id = allocation_binding.room_project_id;
    SELECT revision.* INTO binding_revision
    FROM roomscan.project_revisions AS revision
    WHERE revision.workspace_id = allocation.workspace_id
      AND revision.id = allocation_binding.source_revision_id
      AND revision.project_id = allocation_binding.room_project_id;
    IF binding_project.project_id IS NULL OR binding_revision.id IS NULL
      OR binding_project.public_id IS DISTINCT FROM allocation_binding.room_project_public_id
      OR binding_project.source_project_id IS DISTINCT FROM allocation_binding.local_project_id
      OR binding_project.head_revision_id IS DISTINCT FROM binding_revision.id
      OR binding_revision.public_id IS DISTINCT FROM allocation_binding.source_revision_public_id
      OR binding_revision.source_revision_id IS DISTINCT FROM allocation_binding.local_revision_id
      OR binding_revision.branch_state IS DISTINCT FROM 'canonical'
      OR binding_revision.working_digest IS DISTINCT FROM allocation_binding.working_digest
      OR binding_revision.working_manifest_digest IS DISTINCT FROM allocation_binding.working_manifest_digest THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_SOURCE_CHANGED';
    END IF;
  END LOOP;
  SELECT revision.* INTO revision_row
  FROM roomscan.project_revisions AS revision
  WHERE revision.workspace_id = allocation.workspace_id
    AND revision.id = allocation.source_revision_id
    AND revision.project_id = allocation.project_id
    AND revision.public_id = allocation.source_revision_public_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_SOURCE_NOT_FOUND';
  END IF;
  IF allocation.archive_digest IS NULL OR allocation.archive_manifest_digest IS NULL
    OR allocation.quarantine_version IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_ARCHIVE_BINDING_INVALID';
  END IF;
  INSERT INTO roomscan.publication_snapshots (
    workspace_id, snapshot_id, public_id, allocation_id, project_id,
    source_revision_id, source_revision_public_id, source_revision_digest,
    source_manifest_digest, source_bindings_digest, selection_digest, approval_digest,
    archive_manifest_digest, archive_digest, archive_bytes,
    presentation_digest, presentation_bytes, publication_kind, property_id,
    property_membership_digest,
    published_at
  ) VALUES (
    allocation.workspace_id, new_snapshot_id, new_snapshot_public_id,
    allocation.allocation_id, allocation.project_id, allocation.source_revision_id,
    allocation.source_revision_public_id, allocation.source_revision_digest,
    allocation.source_manifest_digest, allocation.source_bindings_digest,
    allocation.selection_digest,
    allocation.approval_digest, allocation.archive_manifest_digest,
    allocation.archive_digest, allocation.archive_bytes,
    requested_presentation_digest, requested_presentation_bytes,
    allocation.publication_kind, allocation.property_id,
    allocation.property_membership_digest, authoritative_time
  );
  IF allocation.publication_kind = 'property' THEN
    INSERT INTO roomscan.publication_snapshot_rooms (
      workspace_id, property_snapshot_id, room_order, room_key,
      room_project_id, room_project_public_id, source_revision_id,
      source_revision_public_id, source_revision_digest, source_manifest_digest,
      frozen_at
    )
    SELECT binding.workspace_id, new_snapshot_id, binding.room_order,
      binding.public_room_key, binding.room_project_id,
      binding.room_project_public_id, binding.source_revision_id,
      binding.source_revision_public_id, binding.working_digest,
      binding.working_manifest_digest, authoritative_time
    FROM roomscan.publication_allocation_source_bindings AS binding
    WHERE binding.workspace_id = allocation.workspace_id
      AND binding.allocation_id = allocation.allocation_id
    ORDER BY binding.room_order;
  END IF;
  FOR asset IN SELECT value FROM jsonb_array_elements(requested_assets) AS item(value) LOOP
    new_asset_id := gen_random_uuid();
    content_type := COALESCE(asset->>'content_type',
      CASE WHEN asset->>'kind' IN ('web_geometry', 'presentation')
        THEN 'application/json' ELSE 'image/png' END);
    INSERT INTO roomscan.publication_assets (
      workspace_id, asset_id, public_id, snapshot_id, asset_kind,
      download_kind, object_key, object_version, content_type, digest,
      bytes, created_at
    ) VALUES (
      allocation.workspace_id, new_asset_id, asset->>'asset_id', new_snapshot_id,
      asset->>'kind', NULLIF(asset->>'download_kind', ''), asset->>'object_key',
      asset->>'object_version', content_type, decode(asset->>'digest_hex', 'hex'),
      (asset->>'bytes')::bigint, authoritative_time
    );
  END LOOP;
  UPDATE roomscan.publication_allocations AS target
  SET state = 'published', active_object_version = requested_active_object_version,
      updated_at = authoritative_time
  WHERE target.workspace_id = allocation.workspace_id
    AND target.allocation_id = allocation.allocation_id;
  UPDATE roomscan.publication_jobs AS target
  SET state = 'completed', lease_id = NULL, lease_expires_at = NULL,
      updated_at = authoritative_time
  WHERE target.workspace_id = allocation.workspace_id AND target.job_id = job_row.job_id;
RETURN QUERY SELECT 'published'::text, new_snapshot_id, new_snapshot_public_id;
END
$function$;

CREATE FUNCTION roomscan.professional_session_issue_v1(
  access_token_hash bytea,
  authoritative_time timestamptz,
  requested_session_hash bytea,
  requested_workspace_id uuid
)
RETURNS TABLE (status text, session_id uuid, expires_at timestamptz)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE new_session_id uuid := gen_random_uuid();
BEGIN
  IF session_user <> 'roomscan_api_runtime' THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROFESSIONAL_API_RUNTIME_REQUIRED';
  END IF;
  IF access_token_hash IS NULL OR authoritative_time IS NULL
    OR requested_session_hash IS NULL OR requested_workspace_id IS NULL
    OR octet_length(access_token_hash) <> 32 OR octet_length(requested_session_hash) <> 32 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROFESSIONAL_SESSION';
  END IF;
  SELECT context.* INTO context_row
  FROM roomscan.resolve_access_context(access_token_hash, authoritative_time) AS context;
  IF NOT FOUND OR context_row.workspace_id IS DISTINCT FROM requested_workspace_id
    OR context_row.principal_id IS NULL OR context_row.authorization_version IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROFESSIONAL_SESSION_AUTHORIZATION_REQUIRED';
  END IF;
  INSERT INTO roomscan.professional_web_sessions (
    workspace_id, session_id, session_hash, principal_id,
    authorization_version, authenticated_at, expires_at, state, created_at
  ) VALUES (
    requested_workspace_id, new_session_id, requested_session_hash,
    context_row.principal_id, context_row.authorization_version,
    context_row.authenticated_at, authoritative_time + interval '8 hours',
    'active', authoritative_time
  );
  RETURN QUERY SELECT 'issued'::text, new_session_id,
    authoritative_time + interval '8 hours';
END
$function$;

CREATE FUNCTION roomscan.professional_session_revoke_v1(
  requested_session_hash bytea,
  authoritative_time timestamptz
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  IF session_user <> 'roomscan_api_runtime' THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROFESSIONAL_API_RUNTIME_REQUIRED';
  END IF;
  IF requested_session_hash IS NULL OR authoritative_time IS NULL
    OR octet_length(requested_session_hash) <> 32 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROFESSIONAL_SESSION';
  END IF;
  UPDATE roomscan.professional_web_sessions AS session_row
  SET state = 'revoked', revoked_at = authoritative_time
  WHERE session_row.session_hash = requested_session_hash
    AND session_row.state = 'active';
  RETURN FOUND;
END
$function$;

-- A professional cookie is a distinct capability from the app bearer. This
-- resolver derives current tenant/role/flag truth from its hash on every use;
-- callers cannot smuggle stale role or flag versions through a browser value.
CREATE FUNCTION roomscan.professional_session_resolve_v1(
  requested_session_hash bytea,
  authoritative_time timestamptz,
  requested_action text
)
RETURNS TABLE (
  principal_id uuid,
  workspace_id uuid,
  role text,
  authorization_version bigint,
  recent_authentication boolean,
  hosted_global_version bigint,
  hosted_workspace_version bigint,
  publication_global_version bigint,
  publication_workspace_version bigint
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE session_row roomscan.professional_web_sessions%ROWTYPE;
DECLARE membership_role text;
DECLARE current_authorization_version bigint;
DECLARE principal_is_active boolean;
DECLARE editor_publishing_allowed boolean := false;
DECLARE hosted_global_enabled boolean;
DECLARE hosted_workspace_enabled boolean;
DECLARE publication_global_enabled boolean;
DECLARE publication_workspace_enabled boolean;
DECLARE current_hosted_global_version bigint;
DECLARE current_hosted_workspace_version bigint;
DECLARE current_publication_global_version bigint;
DECLARE current_publication_workspace_version bigint;
DECLARE is_recent boolean;
DECLARE needs_publication boolean;
BEGIN
  IF session_user <> 'roomscan_api_runtime' THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROFESSIONAL_API_RUNTIME_REQUIRED';
  END IF;
  IF requested_session_hash IS NULL OR authoritative_time IS NULL
    OR requested_action IS NULL OR octet_length(requested_session_hash) <> 32
    OR requested_action NOT IN (
      'project.read', 'project.revise', 'member.read', 'publication.record.read',
      'access_history.read', 'subscription.read', 'usage.read', 'limit.read',
      'publication.create', 'publication.update', 'publication.revoke'
    ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROFESSIONAL_SESSION_ACTION';
  END IF;
  SELECT session.* INTO session_row
  FROM roomscan.professional_web_sessions AS session
  WHERE session.session_hash = requested_session_hash
  FOR SHARE;
  IF NOT FOUND OR session_row.state <> 'active'
    OR session_row.expires_at <= authoritative_time THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROFESSIONAL_SESSION_UNAVAILABLE';
  END IF;
  SELECT membership.role, membership.authorization_version,
         (principal.state = 'active')
    INTO membership_role, current_authorization_version, principal_is_active
  FROM roomscan.memberships AS membership
  JOIN roomscan.principals AS principal ON principal.id = membership.principal_id
  WHERE membership.workspace_id = session_row.workspace_id
    AND membership.principal_id = session_row.principal_id
    AND membership.state = 'active';
  IF NOT FOUND OR principal_is_active IS DISTINCT FROM true
    OR current_authorization_version IS DISTINCT FROM session_row.authorization_version THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROFESSIONAL_SESSION_AUTHORIZATION_CHANGED';
  END IF;
  SELECT flag.enabled, flag.version INTO hosted_global_enabled, current_hosted_global_version
  FROM roomscan.global_operational_flags AS flag
  WHERE flag.flag_key = 'hosted_operations_enabled';
  SELECT flag.enabled, flag.version INTO hosted_workspace_enabled, current_hosted_workspace_version
  FROM roomscan.workspace_operational_flags AS flag
  WHERE flag.workspace_id = session_row.workspace_id
    AND flag.flag_key = 'hosted_operations_enabled';
  SELECT flag.enabled, flag.version INTO publication_global_enabled, current_publication_global_version
  FROM roomscan.global_operational_flags AS flag
  WHERE flag.flag_key = 'publication_enabled';
  SELECT flag.enabled, flag.version INTO publication_workspace_enabled, current_publication_workspace_version
  FROM roomscan.workspace_operational_flags AS flag
  WHERE flag.workspace_id = session_row.workspace_id
    AND flag.flag_key = 'publication_enabled';
  IF hosted_global_enabled IS DISTINCT FROM true
    OR hosted_workspace_enabled IS DISTINCT FROM true THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'HOSTED_OPERATIONS_DISABLED';
  END IF;
  needs_publication := requested_action IN (
    'publication.record.read', 'access_history.read',
    'publication.create', 'publication.update', 'publication.revoke'
  );
  IF needs_publication AND (
    publication_global_enabled IS DISTINCT FROM true
    OR publication_workspace_enabled IS DISTINCT FROM true
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PUBLICATION_DISABLED';
  END IF;
  is_recent := session_row.authenticated_at <= authoritative_time
    AND session_row.authenticated_at >= authoritative_time - interval '5 minutes';
  IF requested_action IN (
    'access_history.read', 'subscription.read', 'usage.read', 'limit.read'
  ) AND membership_role NOT IN ('owner', 'admin') THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROFESSIONAL_ACTION_DENIED';
  END IF;
  IF requested_action = 'project.revise'
    AND membership_role NOT IN ('owner', 'admin', 'editor') THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROFESSIONAL_ACTION_DENIED';
  END IF;
  IF requested_action IN ('publication.create', 'publication.update', 'publication.revoke') THEN
    IF membership_role NOT IN ('owner', 'admin', 'editor') OR is_recent IS DISTINCT FROM true THEN
      RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROFESSIONAL_ACTION_DENIED';
    END IF;
    SELECT policy.editor_publishing_allowed INTO editor_publishing_allowed
    FROM roomscan.workspace_publishing_policies AS policy
    WHERE policy.workspace_id = session_row.workspace_id;
    IF membership_role = 'editor' AND editor_publishing_allowed IS DISTINCT FROM true THEN
      RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'EDITOR_PUBLISHING_DISABLED';
    END IF;
    IF NOT roomscan.hosted_mutation_grant_matches(
      session_row.workspace_id, requested_action,
      current_hosted_global_version, current_hosted_workspace_version,
      current_publication_global_version, current_publication_workspace_version
    ) THEN
      RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROFESSIONAL_ACTION_DENIED';
    END IF;
  ELSIF requested_action = 'project.revise' THEN
    IF membership_role NOT IN ('owner', 'admin', 'editor') OR is_recent IS DISTINCT FROM true
      OR NOT roomscan.hosted_mutation_grant_matches(
        session_row.workspace_id, 'project.revise',
        current_hosted_global_version, current_hosted_workspace_version,
        NULL, NULL
      ) THEN
      RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROFESSIONAL_ACTION_DENIED';
    END IF;
  END IF;
  RETURN QUERY SELECT session_row.principal_id, session_row.workspace_id,
    membership_role, current_authorization_version, is_recent,
    current_hosted_global_version, current_hosted_workspace_version,
    current_publication_global_version, current_publication_workspace_version;
END
$function$;

CREATE FUNCTION roomscan.publication_create_link_v1(
  requested_credential_kind text,
  requested_credential_hash bytea,
  authoritative_time timestamptz,
  requested_snapshot_public_id text,
  requested_token_hash bytea,
  requested_expires_at timestamptz,
  requested_pin_salt bytea,
  requested_pin_verifier bytea,
  requested_ai_policy text,
  requested_feedback_policy text,
  requested_idempotency_digest bytea
)
RETURNS TABLE (
  status text,
  link_id uuid,
  link_public_id text,
  generation bigint,
  expires_at timestamptz,
  pin_required boolean
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE snapshot_row roomscan.publication_snapshots%ROWTYPE;
DECLARE existing roomscan.publication_links%ROWTYPE;
DECLARE new_link_id uuid := gen_random_uuid();
DECLARE new_public_id text := 'lnk_' || replace(gen_random_uuid()::text, '-', '');
DECLARE effective_expiry timestamptz;
DECLARE requested_expiry_intent text;
BEGIN
  IF requested_credential_kind IS NULL OR requested_credential_hash IS NULL OR authoritative_time IS NULL
    OR requested_snapshot_public_id IS NULL OR requested_token_hash IS NULL
    OR requested_ai_policy IS NULL OR requested_feedback_policy IS NULL
    OR requested_idempotency_digest IS NULL
    OR octet_length(requested_credential_hash) <> 32 OR octet_length(requested_token_hash) <> 32
    OR octet_length(requested_idempotency_digest) <> 32
    OR requested_ai_policy NOT IN ('enabled', 'disabled')
    OR requested_feedback_policy NOT IN ('enabled', 'disabled')
    OR (requested_pin_salt IS NULL) <> (requested_pin_verifier IS NULL)
    OR (requested_pin_salt IS NOT NULL AND octet_length(requested_pin_salt) NOT BETWEEN 16 AND 64)
    OR (requested_pin_verifier IS NOT NULL AND octet_length(requested_pin_verifier) <> 32) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_LINK';
  END IF;
  requested_expiry_intent := CASE
    WHEN requested_expires_at IS NULL THEN 'default_30_days' ELSE 'explicit'
  END;
  effective_expiry := COALESCE(requested_expires_at, authoritative_time + interval '30 days');
  SELECT snapshot.* INTO snapshot_row
  FROM roomscan.publication_snapshots AS snapshot
  WHERE snapshot.public_id = requested_snapshot_public_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_SNAPSHOT_NOT_FOUND';
  END IF;
  SELECT context.* INTO context_row
  FROM roomscan.publication_resolve_api_access_v1(
    requested_credential_kind, requested_credential_hash, authoritative_time,
    snapshot_row.workspace_id, 'publication.create'
  ) AS context;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PUBLICATION_AUTHORIZATION_REQUIRED';
  END IF;
  SELECT link.* INTO existing
  FROM roomscan.publication_links AS link
  WHERE link.workspace_id = snapshot_row.workspace_id
    AND link.created_by_principal_id = context_row.principal_id
    AND link.idempotency_digest = requested_idempotency_digest
  FOR UPDATE;
  IF FOUND THEN
    IF existing.snapshot_id IS DISTINCT FROM snapshot_row.snapshot_id
      OR existing.expiry_intent IS DISTINCT FROM requested_expiry_intent
      OR (requested_expiry_intent = 'explicit'
        AND existing.expires_at IS DISTINCT FROM effective_expiry)
      OR existing.ai_enabled IS DISTINCT FROM (requested_ai_policy = 'enabled')
      OR existing.feedback_enabled IS DISTINCT FROM (requested_feedback_policy = 'enabled')
      OR (existing.pin_salt IS NOT NULL) IS DISTINCT FROM (requested_pin_salt IS NOT NULL) THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_LINK_IDEMPOTENCY_REUSED';
    END IF;
    RETURN QUERY SELECT 'existing'::text, existing.link_id, existing.public_id,
      existing.generation, existing.expires_at, existing.pin_salt IS NOT NULL;
    RETURN;
  END IF;
  -- The expiry window governs only new publication.  A semantic retry can
  -- arrive after its immutable explicit expiry has become close or elapsed;
  -- it must return the original link rather than turn a lost response into a
  -- false conflict.  Existing/default intent remains separately checked.
  IF effective_expiry < authoritative_time + interval '1 hour'
    OR effective_expiry > authoritative_time + interval '365 days' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'PUBLICATION_LINK_EXPIRY_OUT_OF_RANGE';
  END IF;
  INSERT INTO roomscan.publication_links (
    workspace_id, link_id, public_id, snapshot_id, token_hash, generation,
    state, expires_at, expiry_intent, pin_salt, pin_verifier, ai_enabled, feedback_enabled,
    idempotency_digest,
    hosted_global_version, hosted_workspace_version,
    publication_global_version, publication_workspace_version,
    created_by_principal_id, created_at, updated_at
  ) VALUES (
    snapshot_row.workspace_id, new_link_id, new_public_id, snapshot_row.snapshot_id,
    requested_token_hash, 1, 'active', effective_expiry, requested_expiry_intent, requested_pin_salt,
    requested_pin_verifier, (requested_ai_policy = 'enabled'),
    (requested_feedback_policy = 'enabled'), requested_idempotency_digest,
    context_row.hosted_global_version, context_row.hosted_workspace_version,
    context_row.publication_global_version, context_row.publication_workspace_version,
    context_row.principal_id, authoritative_time, authoritative_time
  );
  RETURN QUERY SELECT 'created'::text, new_link_id, new_public_id, 1::bigint,
    effective_expiry, requested_pin_salt IS NOT NULL;
END
$function$;

CREATE FUNCTION roomscan.publication_update_link_v1(
  requested_credential_kind text,
  requested_credential_hash bytea,
  authoritative_time timestamptz,
  requested_link_public_id text,
  requested_token_hash bytea,
  requested_expires_at timestamptz,
  requested_pin_salt bytea,
  requested_pin_verifier bytea,
  requested_ai_policy text,
  requested_feedback_policy text,
  expected_generation bigint
)
RETURNS TABLE (status text, link_public_id text, generation bigint, expires_at timestamptz)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE link_row roomscan.publication_links%ROWTYPE;
DECLARE context_row record;
BEGIN
  IF requested_credential_kind IS NULL OR requested_credential_hash IS NULL OR authoritative_time IS NULL
    OR requested_link_public_id IS NULL OR requested_token_hash IS NULL
    OR requested_expires_at IS NULL OR requested_ai_policy IS NULL
    OR requested_feedback_policy IS NULL
    OR expected_generation IS NULL
    OR octet_length(requested_credential_hash) <> 32 OR octet_length(requested_token_hash) <> 32
    OR requested_ai_policy NOT IN ('enabled', 'disabled')
    OR requested_feedback_policy NOT IN ('enabled', 'disabled')
    OR expected_generation < 1
    OR (requested_pin_salt IS NULL) <> (requested_pin_verifier IS NULL)
    OR (requested_pin_salt IS NOT NULL AND octet_length(requested_pin_salt) NOT BETWEEN 16 AND 64)
    OR (requested_pin_verifier IS NOT NULL AND octet_length(requested_pin_verifier) <> 32)
    OR requested_expires_at < authoritative_time + interval '1 hour'
    OR requested_expires_at > authoritative_time + interval '365 days' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_LINK_UPDATE';
  END IF;
  SELECT candidate.* INTO link_row
  FROM roomscan.publication_links AS candidate
  WHERE candidate.public_id = requested_link_public_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_LINK_NOT_FOUND';
  END IF;
  SELECT context.* INTO context_row
  FROM roomscan.publication_resolve_api_access_v1(
    requested_credential_kind, requested_credential_hash, authoritative_time,
    link_row.workspace_id, 'publication.update'
  ) AS context;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PUBLICATION_AUTHORIZATION_REQUIRED';
  END IF;
  IF link_row.state <> 'active' OR link_row.generation IS DISTINCT FROM expected_generation THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_LINK_GENERATION_STALE';
  END IF;
  UPDATE roomscan.publication_links AS link
  SET token_hash = requested_token_hash, generation = link.generation + 1,
      expires_at = requested_expires_at, pin_salt = requested_pin_salt,
      pin_verifier = requested_pin_verifier, ai_enabled = (requested_ai_policy = 'enabled'),
      feedback_enabled = (requested_feedback_policy = 'enabled'),
      hosted_global_version = context_row.hosted_global_version,
      hosted_workspace_version = context_row.hosted_workspace_version,
      publication_global_version = context_row.publication_global_version,
      publication_workspace_version = context_row.publication_workspace_version,
      updated_at = authoritative_time
  WHERE link.workspace_id = link_row.workspace_id AND link.link_id = link_row.link_id;
  -- Rotation is an immediate session revocation event, not merely a future
  -- generation comparison.  The latter remains a defense in depth for any
  -- stale state that predates this reducer.
  UPDATE roomscan.portal_sessions AS session_row
  SET state = 'revoked', revoked_at = authoritative_time
  WHERE session_row.workspace_id = link_row.workspace_id
    AND session_row.link_id = link_row.link_id
    AND session_row.link_generation <= link_row.generation
    AND session_row.state IN ('active', 'pin_required');
  RETURN QUERY SELECT 'updated'::text, requested_link_public_id,
    link_row.generation + 1, requested_expires_at;
END
$function$;

CREATE FUNCTION roomscan.publication_reset_link_v1(
  requested_credential_kind text,
  requested_credential_hash bytea,
  authoritative_time timestamptz,
  requested_link_public_id text,
  requested_token_hash bytea,
  requested_expires_at timestamptz,
  requested_pin_salt bytea,
  requested_pin_verifier bytea,
  requested_ai_policy text,
  requested_feedback_policy text,
  expected_generation bigint
)
RETURNS TABLE (status text, link_public_id text, generation bigint, expires_at timestamptz)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  RETURN QUERY SELECT * FROM roomscan.publication_update_link_v1(
    requested_credential_kind, requested_credential_hash, authoritative_time,
    requested_link_public_id,
    requested_token_hash, requested_expires_at, requested_pin_salt,
    requested_pin_verifier, requested_ai_policy, requested_feedback_policy,
    expected_generation
  );
END
$function$;

CREATE FUNCTION roomscan.publication_revoke_link_v1(
  requested_credential_kind text,
  requested_credential_hash bytea,
  authoritative_time timestamptz,
  requested_link_public_id text,
  expected_generation bigint
)
RETURNS TABLE (status text, link_public_id text, generation bigint)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE link_row roomscan.publication_links%ROWTYPE;
DECLARE context_row record;
BEGIN
  IF requested_credential_kind IS NULL OR requested_credential_hash IS NULL OR authoritative_time IS NULL
    OR requested_link_public_id IS NULL OR expected_generation IS NULL
    OR octet_length(requested_credential_hash) <> 32 OR expected_generation < 1 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_LINK_REVOKE';
  END IF;
  SELECT candidate.* INTO link_row
  FROM roomscan.publication_links AS candidate
  WHERE candidate.public_id = requested_link_public_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_LINK_NOT_FOUND';
  END IF;
  SELECT context.* INTO context_row
  FROM roomscan.publication_resolve_api_access_v1(
    requested_credential_kind, requested_credential_hash, authoritative_time,
    link_row.workspace_id, 'publication.revoke'
  ) AS context;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PUBLICATION_AUTHORIZATION_REQUIRED';
  END IF;
  IF link_row.generation IS DISTINCT FROM expected_generation THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_LINK_GENERATION_STALE';
  END IF;
  IF link_row.state = 'revoked' THEN
    RETURN QUERY SELECT 'already_revoked'::text, link_row.public_id,
      link_row.generation;
    RETURN;
  END IF;
  UPDATE roomscan.publication_links AS link
  SET state = 'revoked', generation = link.generation + 1,
      revoked_at = authoritative_time, updated_at = authoritative_time
  WHERE link.workspace_id = link_row.workspace_id AND link.link_id = link_row.link_id;
RETURN QUERY SELECT 'revoked'::text, link_row.public_id,
    link_row.generation + 1;
END
$function$;

CREATE FUNCTION roomscan.portal_session_context_v1(
  requested_session_hash bytea,
  authoritative_time timestamptz
)
RETURNS TABLE (
  workspace_id uuid,
  session_id uuid,
  link_id uuid,
  link_generation bigint,
  snapshot_id uuid,
  snapshot_public_id text,
  ai_enabled boolean,
  feedback_enabled boolean,
  pin_required boolean,
  pin_verified boolean,
  client_family text,
  network_risk_digest bytea
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE session_row roomscan.portal_sessions%ROWTYPE;
DECLARE link_row roomscan.publication_links%ROWTYPE;
DECLARE snapshot_public text;
BEGIN
  PERFORM roomscan.publication_require_portal_v1();
  IF requested_session_hash IS NULL OR authoritative_time IS NULL
    OR octet_length(requested_session_hash) <> 32 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PORTAL_SESSION';
  END IF;
  SELECT session.* INTO session_row
  FROM roomscan.portal_sessions AS session
  WHERE session.session_hash = requested_session_hash
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PORTAL_ACCESS_DENIED';
  END IF;
  SELECT link.* INTO link_row
  FROM roomscan.publication_links AS link
  WHERE link.workspace_id = session_row.workspace_id
    AND link.link_id = session_row.link_id
  FOR SHARE;
  SELECT snapshot.public_id INTO snapshot_public
  FROM roomscan.publication_snapshots AS snapshot
  WHERE snapshot.workspace_id = session_row.workspace_id
    AND snapshot.snapshot_id = session_row.snapshot_id;
  IF NOT FOUND
    OR session_row.state <> 'active'
    OR session_row.expires_at <= authoritative_time
    OR link_row.state <> 'active'
    OR link_row.expires_at <= authoritative_time
    OR link_row.generation IS DISTINCT FROM session_row.link_generation
    OR link_row.snapshot_id IS DISTINCT FROM session_row.snapshot_id
    OR session_row.pin_required IS DISTINCT FROM (link_row.pin_salt IS NOT NULL)
    OR (session_row.pin_required AND session_row.pin_verified IS DISTINCT FROM true)
    OR NOT EXISTS (
      SELECT 1 FROM roomscan.global_operational_flags AS hosted_global
      WHERE hosted_global.flag_key = 'hosted_operations_enabled'
        AND hosted_global.enabled IS TRUE
        AND hosted_global.version = session_row.hosted_global_version
    )
    OR NOT EXISTS (
      SELECT 1 FROM roomscan.workspace_operational_flags AS hosted_workspace
      WHERE hosted_workspace.workspace_id = session_row.workspace_id
        AND hosted_workspace.flag_key = 'hosted_operations_enabled'
        AND hosted_workspace.enabled IS TRUE
        AND hosted_workspace.version = session_row.hosted_workspace_version
    )
    OR NOT EXISTS (
      SELECT 1 FROM roomscan.global_operational_flags AS publication_global
      WHERE publication_global.flag_key = 'publication_enabled'
        AND publication_global.enabled IS TRUE
        AND publication_global.version = session_row.publication_global_version
    )
    OR NOT EXISTS (
      SELECT 1 FROM roomscan.workspace_operational_flags AS publication_workspace
      WHERE publication_workspace.workspace_id = session_row.workspace_id
        AND publication_workspace.flag_key = 'publication_enabled'
        AND publication_workspace.enabled IS TRUE
        AND publication_workspace.version = session_row.publication_workspace_version
    ) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PORTAL_ACCESS_DENIED';
  END IF;
  UPDATE roomscan.portal_sessions AS session
  SET last_seen_at = authoritative_time
  WHERE session.workspace_id = session_row.workspace_id AND session.session_id = session_row.session_id;
  RETURN QUERY SELECT session_row.workspace_id, session_row.session_id,
    session_row.link_id, session_row.link_generation, session_row.snapshot_id,
    snapshot_public, link_row.ai_enabled, link_row.feedback_enabled,
    session_row.pin_required,
    session_row.pin_verified, session_row.client_family,
    session_row.network_risk_digest;
END
$function$;

CREATE FUNCTION roomscan.portal_exchange_link_v1(
  requested_token_hash bytea,
  authoritative_time timestamptz,
  requested_session_hash bytea,
  requested_client_family text,
  requested_network_risk_digest bytea
)
RETURNS TABLE (
  status text,
  session_id uuid,
  session_expires_at timestamptz,
  snapshot_public_id text,
  pin_required boolean
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE link_row roomscan.publication_links%ROWTYPE;
DECLARE snapshot_public text;
DECLARE new_session_id uuid := gen_random_uuid();
DECLARE session_expiry timestamptz;
DECLARE status_value text;
BEGIN
  PERFORM roomscan.publication_require_portal_v1();
  IF requested_token_hash IS NULL OR authoritative_time IS NULL
    OR requested_session_hash IS NULL OR requested_client_family IS NULL
    OR requested_network_risk_digest IS NULL
    OR octet_length(requested_token_hash) <> 32
    OR octet_length(requested_session_hash) <> 32
    OR octet_length(requested_network_risk_digest) <> 32
    OR requested_client_family NOT IN ('desktop', 'mobile', 'tablet', 'unknown') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PORTAL_LINK_EXCHANGE';
  END IF;
  SELECT link.* INTO link_row
  FROM roomscan.publication_links AS link
  WHERE link.token_hash = requested_token_hash
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'unavailable'::text, NULL::uuid, NULL::timestamptz,
      NULL::text, false;
    RETURN;
  END IF;
  SELECT snapshot.public_id INTO snapshot_public
  FROM roomscan.publication_snapshots AS snapshot
  WHERE snapshot.workspace_id = link_row.workspace_id
    AND snapshot.snapshot_id = link_row.snapshot_id;
  IF NOT FOUND OR link_row.state <> 'active' OR link_row.expires_at <= authoritative_time THEN
    RETURN QUERY SELECT 'unavailable'::text, NULL::uuid, NULL::timestamptz,
      NULL::text, false;
    RETURN;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM roomscan.global_operational_flags AS hosted_global
    WHERE hosted_global.flag_key = 'hosted_operations_enabled'
      AND hosted_global.enabled IS TRUE
      AND hosted_global.version = link_row.hosted_global_version
  ) OR NOT EXISTS (
    SELECT 1 FROM roomscan.workspace_operational_flags AS hosted_workspace
    WHERE hosted_workspace.workspace_id = link_row.workspace_id
      AND hosted_workspace.flag_key = 'hosted_operations_enabled'
      AND hosted_workspace.enabled IS TRUE
      AND hosted_workspace.version = link_row.hosted_workspace_version
  ) OR NOT EXISTS (
    SELECT 1 FROM roomscan.global_operational_flags AS publication_global
    WHERE publication_global.flag_key = 'publication_enabled'
      AND publication_global.enabled IS TRUE
      AND publication_global.version = link_row.publication_global_version
  ) OR NOT EXISTS (
    SELECT 1 FROM roomscan.workspace_operational_flags AS publication_workspace
    WHERE publication_workspace.workspace_id = link_row.workspace_id
      AND publication_workspace.flag_key = 'publication_enabled'
      AND publication_workspace.enabled IS TRUE
      AND publication_workspace.version = link_row.publication_workspace_version
  ) THEN
    RETURN QUERY SELECT 'killed'::text, NULL::uuid, NULL::timestamptz,
      NULL::text, false;
    RETURN;
  END IF;
  session_expiry := LEAST(link_row.expires_at, authoritative_time + interval '30 minutes');
  status_value := CASE WHEN link_row.pin_salt IS NULL THEN 'active' ELSE 'pin_required' END;
  INSERT INTO roomscan.portal_sessions (
    workspace_id, session_id, session_hash, link_id, link_generation,
    snapshot_id, hosted_global_version, hosted_workspace_version,
    publication_global_version, publication_workspace_version,
    pin_required, pin_verified, client_family, network_risk_digest,
    state, expires_at, last_seen_at, created_at
  ) VALUES (
    link_row.workspace_id, new_session_id, requested_session_hash,
    link_row.link_id, link_row.generation, link_row.snapshot_id,
    link_row.hosted_global_version, link_row.hosted_workspace_version,
    link_row.publication_global_version, link_row.publication_workspace_version,
    link_row.pin_salt IS NOT NULL, link_row.pin_salt IS NULL,
    requested_client_family, requested_network_risk_digest, status_value,
    session_expiry, authoritative_time, authoritative_time
  );
  PERFORM roomscan.publication_append_access_event_v1(
    link_row.workspace_id, link_row.link_id, link_row.generation,
    link_row.snapshot_id, 'exchange', 'allowed', authoritative_time,
    requested_client_family, requested_network_risk_digest
  );
  RETURN QUERY SELECT status_value, new_session_id, session_expiry,
    snapshot_public, link_row.pin_salt IS NOT NULL;
END
$function$;

-- The portal runtime obtains only public KDF parameters and a per-link salt
-- for a still-live PIN-pending session. The verifier remains link-private and
-- is never selected into this function's response surface.
CREATE FUNCTION roomscan.portal_pin_parameters_v1(
  requested_session_hash bytea,
  authoritative_time timestamptz
)
RETURNS TABLE (
  pin_salt bytea,
  scrypt_n integer,
  scrypt_r integer,
  scrypt_p integer,
  key_length integer
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE session_row roomscan.portal_sessions%ROWTYPE;
DECLARE link_salt bytea;
DECLARE link_state text;
DECLARE link_expires_at timestamptz;
DECLARE link_generation bigint;
DECLARE link_snapshot_id uuid;
BEGIN
  PERFORM roomscan.publication_require_portal_v1();
  IF requested_session_hash IS NULL OR authoritative_time IS NULL
    OR octet_length(requested_session_hash) <> 32 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PORTAL_PIN_PARAMETERS';
  END IF;
  SELECT session.* INTO session_row
  FROM roomscan.portal_sessions AS session
  WHERE session.session_hash = requested_session_hash
  FOR SHARE;
  IF NOT FOUND THEN
    RETURN;
  END IF;
  SELECT link.pin_salt, link.state, link.expires_at, link.generation, link.snapshot_id
    INTO link_salt, link_state, link_expires_at, link_generation, link_snapshot_id
  FROM roomscan.publication_links AS link
  WHERE link.workspace_id = session_row.workspace_id
    AND link.link_id = session_row.link_id
  FOR SHARE;
  IF NOT FOUND
    OR session_row.state <> 'pin_required'
    OR session_row.pin_required IS DISTINCT FROM true
    OR session_row.pin_verified IS DISTINCT FROM false
    OR session_row.expires_at <= authoritative_time
    OR link_state <> 'active'
    OR link_expires_at <= authoritative_time
    OR link_salt IS NULL
    OR link_generation IS DISTINCT FROM session_row.link_generation
    OR link_snapshot_id IS DISTINCT FROM session_row.snapshot_id
    OR NOT EXISTS (
      SELECT 1 FROM roomscan.global_operational_flags AS flag
      WHERE flag.flag_key = 'hosted_operations_enabled' AND flag.enabled IS TRUE
        AND flag.version = session_row.hosted_global_version
    ) OR NOT EXISTS (
      SELECT 1 FROM roomscan.workspace_operational_flags AS flag
      WHERE flag.workspace_id = session_row.workspace_id
        AND flag.flag_key = 'hosted_operations_enabled' AND flag.enabled IS TRUE
        AND flag.version = session_row.hosted_workspace_version
    ) OR NOT EXISTS (
      SELECT 1 FROM roomscan.global_operational_flags AS flag
      WHERE flag.flag_key = 'publication_enabled' AND flag.enabled IS TRUE
        AND flag.version = session_row.publication_global_version
    ) OR NOT EXISTS (
      SELECT 1 FROM roomscan.workspace_operational_flags AS flag
      WHERE flag.workspace_id = session_row.workspace_id
        AND flag.flag_key = 'publication_enabled' AND flag.enabled IS TRUE
        AND flag.version = session_row.publication_workspace_version
    ) THEN
    RETURN;
  END IF;
  RETURN QUERY SELECT link_salt, 16384::integer, 8::integer, 1::integer, 32::integer;
END
$function$;

CREATE FUNCTION roomscan.portal_pin_attempt_v1(
  requested_session_hash bytea,
  authoritative_time timestamptz,
  requested_pin_verifier bytea
)
RETURNS TABLE (status text, session_id uuid)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE session_row roomscan.portal_sessions%ROWTYPE;
DECLARE link_row roomscan.publication_links%ROWTYPE;
DECLARE throttle roomscan.portal_pin_throttles%ROWTYPE;
DECLARE is_correct boolean;
DECLARE new_failures integer;
DECLARE new_cooldown timestamptz;
BEGIN
  PERFORM roomscan.publication_require_portal_v1();
  IF requested_session_hash IS NULL OR authoritative_time IS NULL
    OR requested_pin_verifier IS NULL
    OR octet_length(requested_session_hash) <> 32
    OR octet_length(requested_pin_verifier) <> 32 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PORTAL_PIN';
  END IF;
  SELECT session.* INTO session_row
  FROM roomscan.portal_sessions AS session
  WHERE session.session_hash = requested_session_hash
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'unavailable'::text, NULL::uuid;
    RETURN;
  END IF;
  SELECT link.* INTO link_row
  FROM roomscan.publication_links AS link
  WHERE link.workspace_id = session_row.workspace_id AND link.link_id = session_row.link_id
  FOR SHARE;
  IF NOT FOUND OR session_row.state <> 'pin_required'
    OR session_row.expires_at <= authoritative_time OR link_row.state <> 'active'
    OR link_row.expires_at <= authoritative_time
    OR link_row.generation IS DISTINCT FROM session_row.link_generation
    OR link_row.snapshot_id IS DISTINCT FROM session_row.snapshot_id
    OR NOT EXISTS (
      SELECT 1 FROM roomscan.global_operational_flags AS flag
      WHERE flag.flag_key = 'hosted_operations_enabled' AND flag.enabled IS TRUE
        AND flag.version = session_row.hosted_global_version
    ) OR NOT EXISTS (
      SELECT 1 FROM roomscan.workspace_operational_flags AS flag
      WHERE flag.workspace_id = session_row.workspace_id
        AND flag.flag_key = 'hosted_operations_enabled' AND flag.enabled IS TRUE
        AND flag.version = session_row.hosted_workspace_version
    )
    OR NOT EXISTS (
      SELECT 1 FROM roomscan.global_operational_flags AS flag
      WHERE flag.flag_key = 'publication_enabled' AND flag.enabled IS TRUE
        AND flag.version = session_row.publication_global_version
    ) OR NOT EXISTS (
      SELECT 1 FROM roomscan.workspace_operational_flags AS flag
      WHERE flag.workspace_id = session_row.workspace_id
        AND flag.flag_key = 'publication_enabled' AND flag.enabled IS TRUE
        AND flag.version = session_row.publication_workspace_version
    ) THEN
    RETURN QUERY SELECT 'unavailable'::text, session_row.session_id;
    RETURN;
  END IF;
  SELECT state.* INTO throttle
  FROM roomscan.portal_pin_throttles AS state
  WHERE state.workspace_id = session_row.workspace_id
    AND state.link_id = session_row.link_id
    AND state.link_generation = session_row.link_generation
  FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO roomscan.portal_pin_throttles (
      workspace_id, link_id, link_generation, failed_attempts, updated_at
    ) VALUES (
      session_row.workspace_id, session_row.link_id, session_row.link_generation,
      0, authoritative_time
    ) RETURNING * INTO throttle;
  END IF;
  IF throttle.cooldown_until IS NOT NULL AND throttle.cooldown_until > authoritative_time THEN
    PERFORM roomscan.publication_append_access_event_v1(
      session_row.workspace_id, session_row.link_id, session_row.link_generation,
      session_row.snapshot_id, 'pin', 'cooldown', authoritative_time,
      session_row.client_family, session_row.network_risk_digest
    );
    RETURN QUERY SELECT 'cooldown'::text, session_row.session_id;
    RETURN;
  END IF;
  IF throttle.window_started_at IS NULL
    OR throttle.window_started_at + interval '15 minutes' <= authoritative_time THEN
    UPDATE roomscan.portal_pin_throttles AS state
    SET window_started_at = NULL, failed_attempts = 0,
        cooldown_until = NULL, updated_at = authoritative_time
    WHERE state.workspace_id = throttle.workspace_id
      AND state.link_id = throttle.link_id
      AND state.link_generation = throttle.link_generation;
    throttle.window_started_at := NULL;
    throttle.failed_attempts := 0;
    throttle.cooldown_until := NULL;
  END IF;
  is_correct := requested_pin_verifier = link_row.pin_verifier;
  IF is_correct THEN
    UPDATE roomscan.portal_sessions AS session
    SET pin_verified = true, state = 'active', last_seen_at = authoritative_time
    WHERE session.workspace_id = session_row.workspace_id
      AND session.session_id = session_row.session_id;
    UPDATE roomscan.portal_pin_throttles AS state
    SET failed_attempts = 0, window_started_at = NULL,
        cooldown_until = NULL, updated_at = authoritative_time
    WHERE state.workspace_id = throttle.workspace_id
      AND state.link_id = throttle.link_id
      AND state.link_generation = throttle.link_generation;
    PERFORM roomscan.publication_append_access_event_v1(
      session_row.workspace_id, session_row.link_id, session_row.link_generation,
      session_row.snapshot_id, 'pin', 'allowed', authoritative_time,
      session_row.client_family, session_row.network_risk_digest
    );
    RETURN QUERY SELECT 'verified'::text, session_row.session_id;
    RETURN;
  END IF;
  new_failures := LEAST(throttle.failed_attempts + 1, 5);
  new_cooldown := CASE WHEN new_failures >= 5
    THEN authoritative_time + interval '15 minutes' ELSE NULL END;
  UPDATE roomscan.portal_pin_throttles AS state
  SET failed_attempts = new_failures,
      window_started_at = COALESCE(state.window_started_at, authoritative_time),
      cooldown_until = new_cooldown, updated_at = authoritative_time
  WHERE state.workspace_id = throttle.workspace_id
    AND state.link_id = throttle.link_id
    AND state.link_generation = throttle.link_generation;
  PERFORM roomscan.publication_append_access_event_v1(
    session_row.workspace_id, session_row.link_id, session_row.link_generation,
    session_row.snapshot_id, 'pin',
    CASE WHEN new_cooldown IS NULL THEN 'denied' ELSE 'cooldown' END,
    authoritative_time, session_row.client_family, session_row.network_risk_digest
  );
  RETURN QUERY SELECT CASE WHEN new_cooldown IS NULL THEN 'denied' ELSE 'cooldown' END,
    session_row.session_id;
END
$function$;

CREATE FUNCTION roomscan.portal_verify_pin_v1(
  requested_session_hash bytea,
  authoritative_time timestamptz,
  requested_pin_verifier bytea
)
RETURNS TABLE (status text, session_id uuid)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  -- PIN verification deliberately delegates to the attempt reducer so every
  -- invocation rechecks both hosted and publication kill-switch epochs.
  RETURN QUERY SELECT * FROM roomscan.portal_pin_attempt_v1(
    requested_session_hash, authoritative_time, requested_pin_verifier
  );
END
$function$;

CREATE TRIGGER publication_sources_immutable
BEFORE UPDATE OR DELETE ON roomscan.publication_sources
FOR EACH ROW EXECUTE FUNCTION roomscan.publication_immutable_guard_v1();
CREATE TRIGGER publication_approvals_immutable
BEFORE UPDATE OR DELETE ON roomscan.publication_approvals
FOR EACH ROW EXECUTE FUNCTION roomscan.publication_immutable_guard_v1();
CREATE TRIGGER publication_snapshots_immutable
BEFORE UPDATE OR DELETE ON roomscan.publication_snapshots
FOR EACH ROW EXECUTE FUNCTION roomscan.publication_immutable_guard_v1();
CREATE TRIGGER publication_snapshot_rooms_immutable
BEFORE INSERT OR UPDATE OR DELETE ON roomscan.publication_snapshot_rooms
FOR EACH ROW EXECUTE FUNCTION roomscan.publication_snapshot_room_guard_v1();
CREATE TRIGGER publication_allocation_source_bindings_immutable
BEFORE UPDATE OR DELETE ON roomscan.publication_allocation_source_bindings
FOR EACH ROW EXECUTE FUNCTION roomscan.publication_immutable_guard_v1();
CREATE TRIGGER publication_assets_immutable
BEFORE UPDATE OR DELETE ON roomscan.publication_assets
FOR EACH ROW EXECUTE FUNCTION roomscan.publication_immutable_guard_v1();
CREATE TRIGGER publication_feedback_immutable
BEFORE UPDATE OR DELETE ON roomscan.publication_feedback
FOR EACH ROW EXECUTE FUNCTION roomscan.publication_immutable_guard_v1();
CREATE TRIGGER publication_access_events_immutable
BEFORE UPDATE OR DELETE ON roomscan.publication_access_events
FOR EACH ROW EXECUTE FUNCTION roomscan.publication_immutable_guard_v1();

RESET ROLE;

SET ROLE roomscan_owner;

CREATE FUNCTION roomscan.publication_require_worker_v1()
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  IF session_user <> 'roomscan_publication_worker' THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PUBLICATION_WORKER_REQUIRED';
  END IF;
END
$function$;

CREATE FUNCTION roomscan.publication_require_portal_v1()
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  IF session_user <> 'roomscan_portal_runtime' THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PORTAL_RUNTIME_REQUIRED';
  END IF;
END
$function$;

CREATE FUNCTION roomscan.publication_require_live_grant_v1(
  requested_workspace_id uuid,
  requested_action text,
  requested_hosted_global_version bigint,
  requested_hosted_workspace_version bigint,
  requested_publication_global_version bigint,
  requested_publication_workspace_version bigint
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE hosted_global_enabled boolean;
DECLARE hosted_global_version bigint;
DECLARE publication_global_enabled boolean;
DECLARE publication_global_version bigint;
DECLARE hosted_workspace_enabled boolean;
DECLARE hosted_workspace_version bigint;
DECLARE publication_workspace_enabled boolean;
DECLARE publication_workspace_version bigint;
BEGIN
  IF requested_workspace_id IS NULL OR requested_action IS NULL
    OR requested_hosted_global_version IS NULL
    OR requested_hosted_workspace_version IS NULL
    OR requested_publication_global_version IS NULL
    OR requested_publication_workspace_version IS NULL
    OR requested_hosted_global_version < 1
    OR requested_hosted_workspace_version < 1
    OR requested_publication_global_version < 1
    OR requested_publication_workspace_version < 1 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_GRANT';
  END IF;
  IF requested_action NOT IN ('publication.create', 'publication.update', 'publication.revoke') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_GRANT';
  END IF;
  -- Keep shared locks through the caller transaction.  In particular, the
  -- worker finalizer obtains this four-row barrier before inserting a snapshot,
  -- so a concurrent kill either commits first and denies publication or waits
  -- until the immutable publication transaction commits.
  SELECT flag.enabled, flag.version INTO hosted_global_enabled, hosted_global_version
  FROM roomscan.global_operational_flags AS flag
  WHERE flag.flag_key = 'hosted_operations_enabled'
  FOR SHARE;
  SELECT flag.enabled, flag.version INTO publication_global_enabled, publication_global_version
  FROM roomscan.global_operational_flags AS flag
  WHERE flag.flag_key = 'publication_enabled'
  FOR SHARE;
  SELECT flag.enabled, flag.version INTO hosted_workspace_enabled, hosted_workspace_version
  FROM roomscan.workspace_operational_flags AS flag
  WHERE flag.workspace_id = requested_workspace_id
    AND flag.flag_key = 'hosted_operations_enabled'
  FOR SHARE;
  SELECT flag.enabled, flag.version INTO publication_workspace_enabled, publication_workspace_version
  FROM roomscan.workspace_operational_flags AS flag
  WHERE flag.workspace_id = requested_workspace_id
    AND flag.flag_key = 'publication_enabled'
  FOR SHARE;
  IF hosted_global_enabled IS DISTINCT FROM true
    OR publication_global_enabled IS DISTINCT FROM true
    OR hosted_workspace_enabled IS DISTINCT FROM true
    OR publication_workspace_enabled IS DISTINCT FROM true
    OR hosted_global_version IS DISTINCT FROM requested_hosted_global_version
    OR hosted_workspace_version IS DISTINCT FROM requested_hosted_workspace_version
    OR publication_global_version IS DISTINCT FROM requested_publication_global_version
    OR publication_workspace_version IS DISTINCT FROM requested_publication_workspace_version THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PUBLICATION_GRANT_REJECTED';
  END IF;
END
$function$;

-- The only professional mutation credential seam.  A caller explicitly
-- identifies one capability class and supplies exactly one hash; all role,
-- recent-auth, live flag epoch, and quota-policy facts are looked up here in
-- the same transaction.  No browser or native caller can choose those values.
CREATE FUNCTION roomscan.publication_resolve_api_access_v1(
  requested_credential_kind text,
  requested_credential_hash bytea,
  authoritative_time timestamptz,
  requested_workspace_id uuid,
  requested_action text
)
RETURNS TABLE (
  principal_id uuid,
  workspace_id uuid,
  role text,
  authorization_version bigint,
  hosted_global_version bigint,
  hosted_workspace_version bigint,
  publication_global_version bigint,
  publication_workspace_version bigint,
  quota_policy_version bigint
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE bearer_context record;
DECLARE professional_context record;
DECLARE editor_allowed boolean := false;
DECLARE current_hosted_global_version bigint;
DECLARE current_hosted_workspace_version bigint;
DECLARE current_publication_global_version bigint;
DECLARE current_publication_workspace_version bigint;
DECLARE current_quota_policy_version bigint;
DECLARE resolved_principal_id uuid;
DECLARE resolved_workspace_id uuid;
DECLARE resolved_role text;
DECLARE resolved_authorization_version bigint;
BEGIN
  IF session_user <> 'roomscan_api_runtime' THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PUBLICATION_API_RUNTIME_REQUIRED';
  END IF;
  IF requested_credential_kind NOT IN ('app_bearer', 'web_session')
    OR requested_credential_hash IS NULL OR authoritative_time IS NULL
    OR requested_action NOT IN (
      'project.revise', 'publication.create', 'publication.update', 'publication.revoke'
    )
    OR octet_length(requested_credential_hash) <> 32 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_ACCESS';
  END IF;

  IF requested_credential_kind = 'app_bearer' THEN
    SELECT * INTO bearer_context
    FROM roomscan.resolve_access_context(requested_credential_hash, authoritative_time);
    IF NOT FOUND OR bearer_context.workspace_id IS NULL
      OR bearer_context.principal_id IS NULL OR bearer_context.role IS NULL
      OR bearer_context.authorization_version IS NULL
      OR bearer_context.recent_authentication IS DISTINCT FROM true
      OR bearer_context.role NOT IN ('owner', 'admin', 'editor') THEN
      RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PUBLICATION_AUTHORIZATION_REQUIRED';
    END IF;
    resolved_principal_id := bearer_context.principal_id;
    resolved_workspace_id := bearer_context.workspace_id;
    resolved_role := bearer_context.role;
    resolved_authorization_version := bearer_context.authorization_version;
  ELSE
    SELECT * INTO professional_context
    FROM roomscan.professional_session_resolve_v1(
      requested_credential_hash, authoritative_time, requested_action
    );
    IF NOT FOUND OR professional_context.workspace_id IS NULL THEN
      RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PUBLICATION_AUTHORIZATION_REQUIRED';
    END IF;
    resolved_principal_id := professional_context.principal_id;
    resolved_workspace_id := professional_context.workspace_id;
    resolved_role := professional_context.role;
    resolved_authorization_version := professional_context.authorization_version;
  END IF;

  SELECT flag.version INTO current_hosted_global_version
  FROM roomscan.global_operational_flags AS flag
  WHERE flag.flag_key = 'hosted_operations_enabled' AND flag.enabled IS TRUE;
  SELECT flag.version INTO current_hosted_workspace_version
  FROM roomscan.workspace_operational_flags AS flag
  WHERE flag.workspace_id = resolved_workspace_id
    AND flag.flag_key = 'hosted_operations_enabled' AND flag.enabled IS TRUE;
  IF requested_workspace_id IS NOT NULL
    AND resolved_workspace_id IS DISTINCT FROM requested_workspace_id THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PUBLICATION_AUTHORIZATION_REQUIRED';
  END IF;
  IF requested_action <> 'project.revise' THEN
    SELECT flag.version INTO current_publication_global_version
    FROM roomscan.global_operational_flags AS flag
    WHERE flag.flag_key = 'publication_enabled' AND flag.enabled IS TRUE;
    SELECT flag.version INTO current_publication_workspace_version
    FROM roomscan.workspace_operational_flags AS flag
    WHERE flag.workspace_id = resolved_workspace_id
      AND flag.flag_key = 'publication_enabled' AND flag.enabled IS TRUE;
  END IF;
  IF current_hosted_global_version IS NULL OR current_hosted_workspace_version IS NULL
    OR (requested_action <> 'project.revise' AND (
      current_publication_global_version IS NULL
      OR current_publication_workspace_version IS NULL
    )) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PUBLICATION_GRANT_REJECTED';
  END IF;
  SELECT policy.version INTO current_quota_policy_version
  FROM roomscan.quota_policy_versions_v2 AS policy
  WHERE policy.workspace_id = resolved_workspace_id AND policy.is_active IS TRUE;
  IF current_quota_policy_version IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PUBLICATION_QUOTA_POLICY_STALE';
  END IF;
  SELECT policy.editor_publishing_allowed INTO editor_allowed
  FROM roomscan.workspace_publishing_policies AS policy
  WHERE policy.workspace_id = resolved_workspace_id;
  -- Property curation is a private `project.revise` action.  The publication
  -- policy can restrict public publication controls, never the curator's
  -- ordinary hosted project workflow.
  IF requested_action IN ('publication.create', 'publication.update', 'publication.revoke')
    AND resolved_role = 'editor' AND editor_allowed IS DISTINCT FROM true THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'EDITOR_PUBLISHING_DISABLED';
  END IF;
  IF requested_action = 'project.revise' THEN
    IF NOT roomscan.hosted_mutation_grant_matches(
      resolved_workspace_id, requested_action,
      current_hosted_global_version, current_hosted_workspace_version,
      NULL, NULL
    ) THEN
      RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PUBLICATION_GRANT_REJECTED';
    END IF;
  ELSE
    PERFORM roomscan.publication_require_live_grant_v1(
      resolved_workspace_id, requested_action,
      current_hosted_global_version, current_hosted_workspace_version,
      current_publication_global_version, current_publication_workspace_version
    );
  END IF;
  RETURN QUERY SELECT resolved_principal_id, resolved_workspace_id,
    resolved_role, resolved_authorization_version,
    current_hosted_global_version, current_hosted_workspace_version,
    current_publication_global_version, current_publication_workspace_version,
    current_quota_policy_version;
END
$function$;

CREATE FUNCTION roomscan.publication_append_access_event_v1(
  requested_workspace_id uuid,
  requested_link_id uuid,
  requested_generation bigint,
  requested_snapshot_id uuid,
  requested_action text,
  requested_outcome text,
  occurred_at_time timestamptz,
  requested_client_family text,
  requested_network_risk_digest bytea
)
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE event_id uuid := gen_random_uuid();
DECLARE occurred_hour timestamptz;
BEGIN
  IF requested_workspace_id IS NULL OR requested_link_id IS NULL
    OR requested_generation IS NULL OR requested_snapshot_id IS NULL
    OR requested_action IS NULL OR requested_outcome IS NULL
    OR occurred_at_time IS NULL OR requested_client_family IS NULL
    OR requested_network_risk_digest IS NULL
    OR octet_length(requested_network_risk_digest) <> 32 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PORTAL_ACCESS_EVENT';
  END IF;
  IF requested_client_family NOT IN ('desktop', 'mobile', 'tablet', 'unknown')
    OR requested_action NOT IN (
      'exchange', 'pin', 'snapshot', 'asset', 'download',
      'feedback_verification', 'feedback'
    )
    OR requested_outcome NOT IN ('allowed', 'denied', 'cooldown', 'expired', 'revoked', 'killed') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PORTAL_ACCESS_EVENT';
  END IF;
  occurred_hour := date_trunc('hour', occurred_at_time);
  INSERT INTO roomscan.publication_access_events (
    workspace_id, event_id, link_id, link_generation, snapshot_id,
    action, outcome, occurred_hour, client_family, network_risk_digest,
    logical_expires_at
  ) VALUES (
    requested_workspace_id, event_id, requested_link_id, requested_generation,
    requested_snapshot_id, requested_action, requested_outcome, occurred_hour,
    requested_client_family, requested_network_risk_digest,
    occurred_hour + interval '90 days'
  );
  RETURN event_id;
END
$function$;

CREATE FUNCTION roomscan.publication_require_source_binding_v1(
  requested_workspace_id uuid,
  requested_project_id uuid,
  requested_source_revision_id uuid,
  requested_source_revision_public_id text,
  requested_source_revision_digest bytea,
  requested_source_manifest_digest bytea
)
RETURNS void
LANGUAGE plpgsql
 VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE project_row roomscan.professional_projects%ROWTYPE;
DECLARE revision_row roomscan.project_revisions%ROWTYPE;
BEGIN
  IF requested_workspace_id IS NULL OR requested_project_id IS NULL
    OR requested_source_revision_id IS NULL OR requested_source_revision_public_id IS NULL
    OR requested_source_revision_digest IS NULL OR requested_source_manifest_digest IS NULL
    OR octet_length(requested_source_revision_digest) <> 32
    OR octet_length(requested_source_manifest_digest) <> 32 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_SOURCE_BINDING';
  END IF;
  SELECT project.* INTO project_row
  FROM roomscan.professional_projects AS project
  WHERE project.workspace_id = requested_workspace_id
    AND project.project_id = requested_project_id
  FOR SHARE;
  SELECT revision.* INTO revision_row
  FROM roomscan.project_revisions AS revision
  WHERE revision.workspace_id = requested_workspace_id
    AND revision.id = requested_source_revision_id
    AND revision.project_id = requested_project_id
    AND revision.public_id = requested_source_revision_public_id;
  IF NOT FOUND
    OR project_row.head_revision_id IS DISTINCT FROM revision_row.id
    OR revision_row.branch_state IS DISTINCT FROM 'canonical'
    OR revision_row.working_digest IS DISTINCT FROM requested_source_revision_digest
    OR revision_row.working_manifest_digest IS DISTINCT FROM requested_source_manifest_digest THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_SOURCE_CHANGED';
  END IF;
END
$function$;

CREATE FUNCTION roomscan.publication_check_quota_policy_v1(
  requested_workspace_id uuid,
  requested_policy_version bigint
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  IF requested_workspace_id IS NULL OR requested_policy_version IS NULL
    OR requested_policy_version < 1 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_QUOTA_POLICY';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM roomscan.quota_policy_versions_v2 AS policy
    WHERE policy.workspace_id = requested_workspace_id
      AND policy.version = requested_policy_version
      AND policy.is_active IS TRUE
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PUBLICATION_QUOTA_POLICY_STALE';
  END IF;
END
$function$;

-- Canonical server-owned binding for mutable property curation. It contains
-- only ordered independent hosted room projects; exact current revisions are
-- separately captured into immutable allocation bindings at review time. No
-- spatial relationship is represented or implied.
CREATE FUNCTION roomscan.publication_property_membership_digest_v1(
  requested_workspace_id uuid,
  requested_property_id uuid
)
RETURNS bytea
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE canonical_members text;
BEGIN
  IF requested_workspace_id IS NULL OR requested_property_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROPERTY_MEMBERSHIP_BINDING';
  END IF;
  SELECT string_agg(
    rooms.room_order::text || ':' || rooms.room_key || ':'
      || rooms.room_project_id::text || ':' || rooms.room_project_public_id,
    E'\n' ORDER BY rooms.room_order, rooms.room_key, rooms.room_project_id
  ) INTO canonical_members
  FROM roomscan.publication_property_rooms AS rooms
  WHERE rooms.workspace_id = requested_workspace_id
    AND rooms.property_id = requested_property_id;
  IF canonical_members IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_PROPERTY_ROOMS_REQUIRED';
  END IF;
  -- pgcrypto is installed in the controlled public extension schema by the
  -- baseline migration; qualify it rather than widening this definer's path.
  RETURN public.digest(convert_to(canonical_members, 'UTF8'), 'sha256');
END
$function$;

CREATE FUNCTION roomscan.publication_allocate_v1(
  requested_credential_kind text,
  requested_credential_hash bytea,
  authoritative_time timestamptz,
  requested_project_public_id text,
  requested_source_revision_public_id text,
  requested_source_revision_digest bytea,
  requested_source_manifest_digest bytea,
  requested_selection_digest bytea,
  requested_approval_digest bytea,
  requested_disclosure_status text,
  requested_publication_kind text,
  requested_property_public_id text,
  requested_source_bindings jsonb,
  requested_source_bindings_digest bytea,
  requested_archive_manifest_digest bytea,
  requested_archive_digest bytea,
  requested_archive_bytes bigint,
  requested_idempotency_digest bytea
)
RETURNS TABLE (
  status text,
  allocation_id uuid,
  allocation_public_id text,
  allocation_expires_at timestamptz,
  source_revision_public_id text
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE project_row roomscan.professional_projects%ROWTYPE;
DECLARE revision_row roomscan.project_revisions%ROWTYPE;
DECLARE property_row roomscan.publication_properties%ROWTYPE;
DECLARE existing roomscan.publication_allocations%ROWTYPE;
DECLARE new_allocation_id uuid := gen_random_uuid();
DECLARE new_public_id text := 'pua_' || replace(gen_random_uuid()::text, '-', '');
DECLARE allocation_expiry timestamptz;
DECLARE property_membership_digest bytea;
DECLARE binding jsonb;
DECLARE binding_ordinality bigint;
DECLARE binding_project roomscan.professional_projects%ROWTYPE;
DECLARE binding_revision roomscan.project_revisions%ROWTYPE;
DECLARE binding_count integer;
BEGIN
  IF requested_credential_kind IS NULL OR requested_credential_hash IS NULL OR authoritative_time IS NULL
    OR requested_project_public_id IS NULL OR requested_source_revision_public_id IS NULL
    OR requested_source_revision_digest IS NULL OR requested_source_manifest_digest IS NULL
    OR requested_selection_digest IS NULL OR requested_approval_digest IS NULL
    OR requested_disclosure_status IS NULL
    OR requested_publication_kind IS NULL OR requested_source_bindings IS NULL
    OR requested_source_bindings_digest IS NULL
    OR requested_archive_manifest_digest IS NULL
    OR requested_archive_digest IS NULL OR requested_archive_bytes IS NULL
    OR requested_idempotency_digest IS NULL
    OR octet_length(requested_credential_hash) <> 32
    OR octet_length(requested_source_revision_digest) <> 32
    OR octet_length(requested_source_manifest_digest) <> 32
    OR octet_length(requested_selection_digest) <> 32
    OR octet_length(requested_approval_digest) <> 32
    OR octet_length(requested_source_bindings_digest) <> 32
    OR octet_length(requested_archive_manifest_digest) <> 32
    OR octet_length(requested_archive_digest) <> 32
    OR octet_length(requested_idempotency_digest) <> 32
    OR requested_archive_bytes <= 0 OR requested_archive_bytes > 805306368
    OR requested_disclosure_status NOT IN ('approved', 'rejected')
    OR requested_publication_kind NOT IN ('room', 'property')
    OR length(requested_project_public_id) NOT BETWEEN 1 AND 128
    OR length(requested_source_revision_public_id) NOT BETWEEN 1 AND 128
    OR (requested_publication_kind = 'property' AND requested_property_public_id IS NULL)
    OR (requested_publication_kind = 'room' AND requested_property_public_id IS NOT NULL) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_ALLOCATION';
  END IF;
  IF requested_disclosure_status <> 'approved' THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PUBLICATION_DISCLOSURE_REVIEW_REQUIRED';
  END IF;
  IF jsonb_typeof(requested_source_bindings) <> 'array' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_SOURCE_BINDINGS';
  END IF;
  binding_count := jsonb_array_length(requested_source_bindings);
  IF (requested_publication_kind = 'room' AND binding_count <> 1)
    OR (requested_publication_kind = 'property' AND (binding_count < 2 OR binding_count > 64)) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_SOURCE_BINDINGS';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(requested_source_bindings) AS item(value)
    WHERE jsonb_typeof(item.value) <> 'object'
      OR jsonb_typeof(item.value -> 'publicRoomKey') IS DISTINCT FROM 'string'
      OR jsonb_typeof(item.value -> 'projectPublicID') IS DISTINCT FROM 'string'
      OR jsonb_typeof(item.value -> 'revisionPublicID') IS DISTINCT FROM 'string'
      OR jsonb_typeof(item.value -> 'projectID') IS DISTINCT FROM 'string'
      OR jsonb_typeof(item.value -> 'revisionID') IS DISTINCT FROM 'string'
      OR jsonb_typeof(item.value -> 'coordinateSpaceEpochID') IS DISTINCT FROM 'string'
      OR jsonb_typeof(item.value -> 'packageSchemaVersion') IS DISTINCT FROM 'string'
      OR jsonb_typeof(item.value -> 'semanticSHA256') IS DISTINCT FROM 'string'
      OR jsonb_typeof(item.value -> 'revisionManifestSHA256') IS DISTINCT FROM 'string'
      OR EXISTS (
        SELECT 1 FROM jsonb_object_keys(item.value) AS key(name)
        WHERE key.name NOT IN (
          'publicRoomKey', 'projectPublicID', 'revisionPublicID', 'projectID',
          'revisionID', 'coordinateSpaceEpochID', 'packageSchemaVersion',
          'semanticSHA256', 'revisionManifestSHA256'
        )
      )
      OR item.value ->> 'publicRoomKey' !~ '^[A-Za-z0-9_.-]{1,128}$'
      OR item.value ->> 'projectPublicID' !~ '^prj_[A-Za-z0-9_-]{16,128}$'
      OR item.value ->> 'revisionPublicID' !~ '^rev_[A-Za-z0-9_-]{16,128}$'
      OR item.value ->> 'projectID' !~ '^[A-Za-z0-9_-]{1,128}$'
      OR item.value ->> 'revisionID' !~ '^[A-Za-z0-9_-]{1,128}$'
      OR item.value ->> 'coordinateSpaceEpochID' !~ '^[A-Za-z0-9_.-]{1,128}$'
      OR item.value ->> 'packageSchemaVersion' NOT IN ('room-scan-project-v1', 'room-scan-project-v2')
      OR item.value ->> 'semanticSHA256' !~ '^[0-9a-f]{64}$'
      OR item.value ->> 'revisionManifestSHA256' !~ '^[0-9a-f]{64}$'
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_SOURCE_BINDINGS';
  END IF;
  IF EXISTS (
    SELECT item.value ->> 'publicRoomKey'
    FROM jsonb_array_elements(requested_source_bindings) AS item(value)
    GROUP BY item.value ->> 'publicRoomKey'
    HAVING count(*) > 1
  ) OR EXISTS (
    SELECT item.value ->> 'projectPublicID'
    FROM jsonb_array_elements(requested_source_bindings) AS item(value)
    GROUP BY item.value ->> 'projectPublicID'
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'DUPLICATE_PUBLICATION_SOURCE_BINDING';
  END IF;

  SELECT context.* INTO context_row
  FROM roomscan.publication_resolve_api_access_v1(
    requested_credential_kind, requested_credential_hash, authoritative_time,
    NULL, 'publication.create'
  ) AS context;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PUBLICATION_AUTHORIZATION_REQUIRED';
  END IF;
  PERFORM roomscan.publication_check_quota_policy_v1(
    context_row.workspace_id, context_row.quota_policy_version
  );

  IF requested_project_public_id IS DISTINCT FROM requested_source_bindings -> 0 ->> 'projectPublicID'
    OR requested_source_revision_public_id IS DISTINCT FROM requested_source_bindings -> 0 ->> 'revisionPublicID' THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_SOURCE_BINDINGS_MISMATCH';
  END IF;
  SELECT project.* INTO project_row
  FROM roomscan.professional_projects AS project
  WHERE project.workspace_id = context_row.workspace_id
    AND project.public_id = requested_project_public_id;
  SELECT revision.* INTO revision_row
  FROM roomscan.project_revisions AS revision
  WHERE revision.workspace_id = context_row.workspace_id
    AND revision.project_id = project_row.project_id
    AND revision.public_id = requested_source_revision_public_id;
  IF project_row.project_id IS NULL OR revision_row.id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_SOURCE_NOT_FOUND';
  END IF;
  PERFORM roomscan.publication_require_source_binding_v1(
    context_row.workspace_id, project_row.project_id, revision_row.id,
    requested_source_revision_public_id, requested_source_revision_digest,
    requested_source_manifest_digest
  );
  FOR binding, binding_ordinality IN
    SELECT item.value, item.ordinality
    FROM jsonb_array_elements(requested_source_bindings) WITH ORDINALITY AS item(value, ordinality)
  LOOP
    SELECT project.* INTO binding_project
    FROM roomscan.professional_projects AS project
    WHERE project.workspace_id = context_row.workspace_id
      AND project.public_id = binding ->> 'projectPublicID';
    SELECT revision.* INTO binding_revision
    FROM roomscan.project_revisions AS revision
    WHERE revision.workspace_id = context_row.workspace_id
      AND revision.project_id = binding_project.project_id
      AND revision.public_id = binding ->> 'revisionPublicID';
    IF binding_project.project_id IS NULL OR binding_revision.id IS NULL
      OR binding_project.source_project_id IS DISTINCT FROM binding ->> 'projectID'
      OR binding_revision.source_revision_id IS DISTINCT FROM binding ->> 'revisionID'
      OR binding_project.head_revision_id IS DISTINCT FROM binding_revision.id
      OR binding_revision.branch_state IS DISTINCT FROM 'canonical' THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_SOURCE_CHANGED';
    END IF;
  END LOOP;
  IF requested_publication_kind = 'property' THEN
    SELECT property.* INTO property_row
    FROM roomscan.publication_properties AS property
    WHERE property.workspace_id = context_row.workspace_id
      AND property.public_id = requested_property_public_id
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_PROPERTY_NOT_FOUND';
    END IF;
    property_membership_digest := roomscan.publication_property_membership_digest_v1(
      context_row.workspace_id, property_row.property_id
    );
    IF EXISTS (
      WITH requested AS (
        SELECT item.ordinality::integer AS ordinal, item.value ->> 'publicRoomKey' AS room_key,
          item.value ->> 'projectPublicID' AS room_project_public_id
        FROM jsonb_array_elements(requested_source_bindings)
          WITH ORDINALITY AS item(value, ordinality)
      ), curated AS (
        SELECT row_number() OVER (ORDER BY rooms.room_order, rooms.room_key, rooms.room_project_id)::integer AS ordinal,
          rooms.room_key, rooms.room_project_public_id
        FROM roomscan.publication_property_rooms AS rooms
        WHERE rooms.workspace_id = context_row.workspace_id
          AND rooms.property_id = property_row.property_id
      )
      SELECT 1 FROM requested
      FULL OUTER JOIN curated USING (ordinal)
      WHERE requested.room_key IS DISTINCT FROM curated.room_key
        OR requested.room_project_public_id IS DISTINCT FROM curated.room_project_public_id
    ) THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_PROPERTY_BINDINGS_MISMATCH';
    END IF;
  END IF;

  SELECT allocation.* INTO existing
  FROM roomscan.publication_allocations AS allocation
  WHERE allocation.workspace_id = context_row.workspace_id
    AND allocation.created_by_principal_id = context_row.principal_id
    AND allocation.idempotency_digest = requested_idempotency_digest
  FOR UPDATE;
  IF FOUND THEN
    IF existing.project_id IS DISTINCT FROM project_row.project_id
      OR existing.source_revision_id IS DISTINCT FROM revision_row.id
      OR existing.source_revision_digest IS DISTINCT FROM requested_source_revision_digest
      OR existing.source_manifest_digest IS DISTINCT FROM requested_source_manifest_digest
      OR existing.source_bindings_digest IS DISTINCT FROM requested_source_bindings_digest
      OR existing.selection_digest IS DISTINCT FROM requested_selection_digest
      OR existing.approval_digest IS DISTINCT FROM requested_approval_digest
      OR existing.archive_manifest_digest IS DISTINCT FROM requested_archive_manifest_digest
      OR existing.archive_digest IS DISTINCT FROM requested_archive_digest
      OR existing.archive_bytes IS DISTINCT FROM requested_archive_bytes
      OR existing.publication_kind IS DISTINCT FROM requested_publication_kind
      OR existing.property_id IS DISTINCT FROM property_row.property_id
      OR existing.property_membership_digest IS DISTINCT FROM property_membership_digest
      OR existing.property_curation_version IS DISTINCT FROM property_row.version THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_IDEMPOTENCY_REUSED';
    END IF;
    RETURN QUERY SELECT 'existing'::text, existing.allocation_id,
      existing.allocation_public_id, existing.allocation_expires_at,
      existing.source_revision_public_id;
    RETURN;
  END IF;

  allocation_expiry := authoritative_time + interval '15 minutes';
  INSERT INTO roomscan.publication_allocations (
    workspace_id, allocation_id, allocation_public_id, project_id,
    source_revision_id, source_revision_public_id, source_revision_digest,
    source_manifest_digest, source_bindings_digest, selection_digest, approval_digest,
    publication_kind, property_id, property_membership_digest, property_curation_version,
    archive_manifest_digest, archive_digest,
    archive_bytes, idempotency_digest, state, quarantine_key,
    created_by_principal_id, created_role, created_authorization_version,
    hosted_global_version, hosted_workspace_version,
    publication_global_version, publication_workspace_version,
    quota_policy_version, allocation_expires_at, created_at, updated_at
  ) VALUES (
    context_row.workspace_id, new_allocation_id, new_public_id,
    project_row.project_id, revision_row.id, revision_row.public_id,
    requested_source_revision_digest, requested_source_manifest_digest,
    requested_source_bindings_digest,
    requested_selection_digest, requested_approval_digest,
    requested_publication_kind, property_row.property_id, property_membership_digest,
    property_row.version,
    requested_archive_manifest_digest, requested_archive_digest,
    requested_archive_bytes, requested_idempotency_digest, 'allocated',
    'server/published/quarantine/v1/' || new_public_id || '.zip',
    context_row.principal_id, context_row.role, context_row.authorization_version,
    context_row.hosted_global_version, context_row.hosted_workspace_version,
    context_row.publication_global_version, context_row.publication_workspace_version,
    context_row.quota_policy_version, allocation_expiry, authoritative_time,
    authoritative_time
  );
  INSERT INTO roomscan.publication_sources (
    workspace_id, source_id, allocation_id, source_revision_id,
    source_revision_public_id, source_revision_digest, source_manifest_digest,
    source_bindings_digest, selection_digest, property_membership_digest, captured_at
  ) VALUES (
    context_row.workspace_id, gen_random_uuid(), new_allocation_id, revision_row.id,
    revision_row.public_id, requested_source_revision_digest,
    requested_source_manifest_digest, requested_source_bindings_digest,
    requested_selection_digest, property_membership_digest,
    authoritative_time
  );
  INSERT INTO roomscan.publication_approvals (
    workspace_id, approval_id, allocation_id, source_revision_id,
    source_revision_public_id, source_revision_digest, source_manifest_digest,
    source_bindings_digest, selection_digest,
    approval_digest, property_membership_digest, approved_by_principal_id, approved_role,
    approved_authorization_version, disclosure_reviewed_at
  ) VALUES (
    context_row.workspace_id, gen_random_uuid(), new_allocation_id, revision_row.id,
    revision_row.public_id, requested_source_revision_digest, requested_source_manifest_digest,
    requested_source_bindings_digest, requested_selection_digest, requested_approval_digest, property_membership_digest,
    context_row.principal_id,
    context_row.role, context_row.authorization_version, authoritative_time
  );
  FOR binding, binding_ordinality IN
    SELECT item.value, item.ordinality
    FROM jsonb_array_elements(requested_source_bindings) WITH ORDINALITY AS item(value, ordinality)
  LOOP
    SELECT project.* INTO binding_project
    FROM roomscan.professional_projects AS project
    WHERE project.workspace_id = context_row.workspace_id
      AND project.public_id = binding ->> 'projectPublicID';
    SELECT revision.* INTO binding_revision
    FROM roomscan.project_revisions AS revision
    WHERE revision.workspace_id = context_row.workspace_id
      AND revision.project_id = binding_project.project_id
      AND revision.public_id = binding ->> 'revisionPublicID';
    INSERT INTO roomscan.publication_allocation_source_bindings (
      workspace_id, allocation_id, room_order, public_room_key,
      room_project_id, room_project_public_id, source_revision_id,
      source_revision_public_id, local_project_id, local_revision_id,
      coordinate_space_epoch_id, package_schema_version, semantic_sha256,
      revision_manifest_sha256, working_digest, working_manifest_digest, captured_at
    ) VALUES (
      context_row.workspace_id, new_allocation_id, binding_ordinality::integer,
      binding ->> 'publicRoomKey', binding_project.project_id,
      binding_project.public_id, binding_revision.id, binding_revision.public_id,
      binding ->> 'projectID', binding ->> 'revisionID',
      binding ->> 'coordinateSpaceEpochID', binding ->> 'packageSchemaVersion',
      decode(binding ->> 'semanticSHA256', 'hex'),
      decode(binding ->> 'revisionManifestSHA256', 'hex'),
      binding_revision.working_digest, binding_revision.working_manifest_digest,
      authoritative_time
    );
  END LOOP;
  RETURN QUERY SELECT 'allocated'::text, new_allocation_id, new_public_id,
    allocation_expiry, revision_row.public_id;
END
$function$;

CREATE FUNCTION roomscan.publication_complete_v1(
  requested_credential_kind text,
  requested_credential_hash bytea,
  authoritative_time timestamptz,
  requested_allocation_public_id text,
  requested_archive_digest bytea,
  requested_archive_manifest_digest bytea,
  requested_archive_bytes bigint,
  requested_quarantine_version text
)
RETURNS TABLE (status text, allocation_public_id text)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE allocation roomscan.publication_allocations%ROWTYPE;
DECLARE context_row record;
BEGIN
  IF requested_credential_kind IS NULL OR requested_credential_hash IS NULL OR authoritative_time IS NULL
    OR requested_allocation_public_id IS NULL OR requested_archive_digest IS NULL
    OR requested_archive_manifest_digest IS NULL OR requested_archive_bytes IS NULL
    OR requested_quarantine_version IS NULL
    OR octet_length(requested_credential_hash) <> 32
    OR octet_length(requested_archive_digest) <> 32
    OR octet_length(requested_archive_manifest_digest) <> 32
    OR requested_archive_bytes <= 0 OR requested_archive_bytes > 805306368
    OR length(requested_quarantine_version) NOT BETWEEN 1 AND 1024
    OR requested_quarantine_version ~ '[[:cntrl:]]' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_COMPLETION';
  END IF;
  SELECT candidate.* INTO allocation
  FROM roomscan.publication_allocations AS candidate
  WHERE candidate.allocation_public_id = requested_allocation_public_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_ALLOCATION_NOT_FOUND';
  END IF;
  SELECT context.* INTO context_row
  FROM roomscan.publication_resolve_api_access_v1(
    requested_credential_kind, requested_credential_hash, authoritative_time,
    allocation.workspace_id, 'publication.create'
  ) AS context;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PUBLICATION_AUTHORIZATION_REQUIRED';
  END IF;
  IF allocation.hosted_global_version IS DISTINCT FROM context_row.hosted_global_version
    OR allocation.hosted_workspace_version IS DISTINCT FROM context_row.hosted_workspace_version
    OR allocation.publication_global_version IS DISTINCT FROM context_row.publication_global_version
    OR allocation.publication_workspace_version IS DISTINCT FROM context_row.publication_workspace_version
    OR allocation.quota_policy_version IS DISTINCT FROM context_row.quota_policy_version THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PUBLICATION_GRANT_REJECTED';
  END IF;
  IF allocation.created_by_principal_id IS DISTINCT FROM context_row.principal_id THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PUBLICATION_ALLOCATION_OWNER_REQUIRED';
  END IF;
  IF allocation.archive_digest IS DISTINCT FROM requested_archive_digest
    OR allocation.archive_manifest_digest IS DISTINCT FROM requested_archive_manifest_digest
    OR allocation.archive_bytes IS DISTINCT FROM requested_archive_bytes
    OR (allocation.state <> 'allocated'
      AND allocation.quarantine_version IS DISTINCT FROM requested_quarantine_version) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_ARCHIVE_BINDING_MISMATCH';
  END IF;
  IF allocation.state = 'validation_pending' THEN
    RETURN QUERY SELECT 'existing'::text, allocation.allocation_public_id;
    RETURN;
  END IF;
  IF allocation.state <> 'allocated' OR allocation.allocation_expires_at <= authoritative_time THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_ALLOCATION_EXPIRED';
  END IF;
  UPDATE roomscan.publication_allocations
  SET state = 'validation_pending', quarantine_version = requested_quarantine_version,
      updated_at = authoritative_time
  WHERE workspace_id = allocation.workspace_id AND allocation_id = allocation.allocation_id;
  INSERT INTO roomscan.publication_jobs (
    workspace_id, job_id, allocation_id, state, created_at, updated_at
  ) VALUES (
    allocation.workspace_id, gen_random_uuid(), allocation.allocation_id,
    'pending', authoritative_time, authoritative_time
  );
RETURN QUERY SELECT 'validation_pending'::text, allocation.allocation_public_id;
END
$function$;

-- Professional reads are deliberately separate from the mutation resolver.
-- Each receives exactly one explicit app-bearer or professional-cookie hash
-- and resolves its current role/action before it touches a tenant row. The
-- result shapes are public/professional metadata; none exposes private package
-- locations, working digests, bearer/PIN state, portal sessions, verification
-- material, or storage object versions.
CREATE FUNCTION roomscan.professional_read_resolve_v1(
  requested_credential_kind text,
  requested_credential_hash bytea,
  authoritative_time timestamptz,
  requested_action text
)
RETURNS TABLE (
  principal_id uuid,
  workspace_id uuid,
  role text,
  authorization_version bigint
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE bearer_context record;
DECLARE session_context record;
DECLARE resolved_principal_id uuid;
DECLARE resolved_workspace_id uuid;
DECLARE resolved_role text;
DECLARE resolved_authorization_version bigint;
DECLARE hosted_global_enabled boolean;
DECLARE hosted_workspace_enabled boolean;
DECLARE publication_global_enabled boolean;
DECLARE publication_workspace_enabled boolean;
BEGIN
  IF session_user <> 'roomscan_api_runtime' THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROFESSIONAL_API_RUNTIME_REQUIRED';
  END IF;
  IF requested_credential_kind NOT IN ('app_bearer', 'web_session')
    OR requested_credential_hash IS NULL OR authoritative_time IS NULL
    OR octet_length(requested_credential_hash) <> 32
    OR requested_action NOT IN (
      'project.read', 'member.read', 'publication.record.read',
      'access_history.read', 'subscription.read', 'usage.read', 'limit.read'
    ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROFESSIONAL_READ_ACCESS';
  END IF;
  IF requested_credential_kind = 'app_bearer' THEN
    SELECT * INTO bearer_context
    FROM roomscan.resolve_access_context(requested_credential_hash, authoritative_time);
    IF NOT FOUND OR bearer_context.workspace_id IS NULL
      OR bearer_context.principal_id IS NULL
      OR bearer_context.role NOT IN ('owner', 'admin', 'editor', 'viewer')
      OR bearer_context.authorization_version IS NULL THEN
      RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROFESSIONAL_READ_AUTHORIZATION_REQUIRED';
    END IF;
    resolved_principal_id := bearer_context.principal_id;
    resolved_workspace_id := bearer_context.workspace_id;
    resolved_role := bearer_context.role;
    resolved_authorization_version := bearer_context.authorization_version;
    SELECT flag.enabled INTO hosted_global_enabled
    FROM roomscan.global_operational_flags AS flag
    WHERE flag.flag_key = 'hosted_operations_enabled';
    SELECT flag.enabled INTO hosted_workspace_enabled
    FROM roomscan.workspace_operational_flags AS flag
    WHERE flag.workspace_id = resolved_workspace_id
      AND flag.flag_key = 'hosted_operations_enabled';
    IF hosted_global_enabled IS DISTINCT FROM true
      OR hosted_workspace_enabled IS DISTINCT FROM true THEN
      RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'HOSTED_OPERATIONS_DISABLED';
    END IF;
    IF requested_action IN ('publication.record.read', 'access_history.read') THEN
      SELECT flag.enabled INTO publication_global_enabled
      FROM roomscan.global_operational_flags AS flag
      WHERE flag.flag_key = 'publication_enabled';
      SELECT flag.enabled INTO publication_workspace_enabled
      FROM roomscan.workspace_operational_flags AS flag
      WHERE flag.workspace_id = resolved_workspace_id
        AND flag.flag_key = 'publication_enabled';
      IF publication_global_enabled IS DISTINCT FROM true
        OR publication_workspace_enabled IS DISTINCT FROM true THEN
        RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PUBLICATION_DISABLED';
      END IF;
    END IF;
    IF requested_action IN (
      'access_history.read', 'subscription.read', 'usage.read', 'limit.read'
    ) AND resolved_role NOT IN ('owner', 'admin') THEN
      RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROFESSIONAL_ACTION_DENIED';
    END IF;
  ELSE
    SELECT * INTO session_context
    FROM roomscan.professional_session_resolve_v1(
      requested_credential_hash, authoritative_time, requested_action
    );
    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROFESSIONAL_READ_AUTHORIZATION_REQUIRED';
    END IF;
    resolved_principal_id := session_context.principal_id;
    resolved_workspace_id := session_context.workspace_id;
    resolved_role := session_context.role;
    resolved_authorization_version := session_context.authorization_version;
  END IF;
  RETURN QUERY SELECT resolved_principal_id, resolved_workspace_id,
    resolved_role, resolved_authorization_version;
END
$function$;

CREATE FUNCTION roomscan.professional_list_properties_v1(
  requested_credential_kind text,
  requested_credential_hash bytea,
  authoritative_time timestamptz,
  requested_limit integer,
  requested_cursor text
)
RETURNS TABLE (
  property_public_id text,
  title text,
  curation_version bigint,
  room_count integer,
  room_curation jsonb,
  updated_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE effective_limit integer;
BEGIN
  IF requested_limit IS NOT NULL AND requested_limit NOT BETWEEN 1 AND 20
    OR (requested_cursor IS NOT NULL
      AND requested_cursor !~ '^prop_[A-Za-z0-9_-]{16,128}$') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROFESSIONAL_READ_PAGE';
  END IF;
  effective_limit := COALESCE(requested_limit, 20);
  SELECT context.* INTO context_row
  FROM roomscan.professional_read_resolve_v1(
    requested_credential_kind, requested_credential_hash,
    authoritative_time, 'project.read'
  ) AS context;
  RETURN QUERY
  SELECT property.public_id, property.title, property.version,
    count(room.room_key)::integer,
    COALESCE(jsonb_agg(jsonb_build_object(
      'roomKey', room.room_key,
      'roomOrder', room.room_order,
      'projectID', room.room_project_public_id
    ) ORDER BY room.room_order) FILTER (WHERE room.room_key IS NOT NULL), '[]'::jsonb),
    property.updated_at
  FROM roomscan.publication_properties AS property
  LEFT JOIN roomscan.publication_property_rooms AS room
    ON room.workspace_id = property.workspace_id
    AND room.property_id = property.property_id
  WHERE property.workspace_id = context_row.workspace_id
    AND (requested_cursor IS NULL OR property.public_id > requested_cursor)
  GROUP BY property.public_id, property.title, property.version, property.updated_at
  ORDER BY property.public_id
  LIMIT effective_limit;
END
$function$;

-- A browser composing a property needs its bounded current room inventory,
-- independently from any property-page cursor.  This projection exposes only
-- an opaque professional project ID and a title constrained to the web
-- contract; it never exposes native/project UUIDs or revision/package facts.
CREATE FUNCTION roomscan.publication_list_room_candidates_v1(
  requested_credential_kind text,
  requested_credential_hash bytea,
  authoritative_time timestamptz,
  requested_limit integer,
  requested_cursor text
)
RETURNS TABLE (
  project_public_id text,
  title text
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE effective_limit integer;
BEGIN
  IF requested_limit IS NOT NULL AND requested_limit NOT BETWEEN 1 AND 100
    OR (requested_cursor IS NOT NULL
      AND requested_cursor !~ '^prj_[A-Za-z0-9_-]{16,128}$') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROFESSIONAL_READ_PAGE';
  END IF;
  effective_limit := COALESCE(requested_limit, 100);
  SELECT context.* INTO context_row
  FROM roomscan.professional_read_resolve_v1(
    requested_credential_kind, requested_credential_hash,
    authoritative_time, 'project.read'
  ) AS context;
  RETURN QUERY
  SELECT professional_project.public_id, LEFT(source_project.title, 180)
  FROM roomscan.professional_projects AS professional_project
  JOIN roomscan.projects AS source_project
    ON source_project.workspace_id = professional_project.workspace_id
    AND source_project.id = professional_project.project_id
  JOIN roomscan.project_revisions AS head_revision
    ON head_revision.workspace_id = professional_project.workspace_id
    AND head_revision.project_id = professional_project.project_id
    AND head_revision.id = professional_project.head_revision_id
  WHERE professional_project.workspace_id = context_row.workspace_id
    AND source_project.state <> 'deleted'
    AND head_revision.branch_state = 'canonical'
    AND (requested_cursor IS NULL OR professional_project.public_id > requested_cursor)
  ORDER BY professional_project.public_id
  LIMIT effective_limit;
END
$function$;

-- Hosted Slice 5 working archives contain concepts but are intentionally not
-- parsed for browser reads.  This list exposes only already-published,
-- allowlisted concept derivatives that an owner explicitly approved for a
-- presentation; unpublished concept working material remains private/native.
CREATE FUNCTION roomscan.professional_list_concepts_v1(
  requested_credential_kind text,
  requested_credential_hash bytea,
  authoritative_time timestamptz,
  requested_project_public_id text,
  requested_limit integer,
  requested_cursor text
)
RETURNS TABLE (
  snapshot_public_id text,
  concept_asset_public_id text,
  content_type text,
  asset_bytes bigint,
  asset_digest bytea,
  published_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE effective_limit integer;
BEGIN
  IF requested_project_public_id IS NULL
    OR requested_project_public_id !~ '^prj_[A-Za-z0-9_-]{16,128}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROFESSIONAL_PROJECT';
  END IF;
  IF requested_limit IS NOT NULL AND requested_limit NOT BETWEEN 1 AND 20
    OR (requested_cursor IS NOT NULL
      AND requested_cursor !~ '^ast_[A-Za-z0-9_-]{16,128}$') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROFESSIONAL_READ_PAGE';
  END IF;
  effective_limit := COALESCE(requested_limit, 20);
  SELECT context.* INTO context_row
  FROM roomscan.professional_read_resolve_v1(
    requested_credential_kind, requested_credential_hash,
    authoritative_time, 'project.read'
  ) AS context;
  RETURN QUERY
  SELECT snapshot.public_id, asset.public_id, asset.content_type,
    asset.bytes, asset.digest, snapshot.published_at
  FROM roomscan.publication_snapshots AS snapshot
  JOIN roomscan.professional_projects AS project
    ON project.workspace_id = snapshot.workspace_id
    AND project.project_id = snapshot.project_id
  JOIN roomscan.publication_assets AS asset
    ON asset.workspace_id = snapshot.workspace_id
    AND asset.snapshot_id = snapshot.snapshot_id
    AND asset.asset_kind = 'approved_concept'
  WHERE snapshot.workspace_id = context_row.workspace_id
    AND project.public_id = requested_project_public_id
    AND (requested_cursor IS NULL OR asset.public_id > requested_cursor)
  ORDER BY asset.public_id
  LIMIT effective_limit;
END
$function$;

CREATE FUNCTION roomscan.professional_list_members_v1(
  requested_credential_kind text,
  requested_credential_hash bytea,
  authoritative_time timestamptz,
  requested_limit integer,
  requested_cursor text
)
RETURNS TABLE (
  member_reference text,
  role text,
  state text,
  is_current_principal boolean,
  updated_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE effective_limit integer;
BEGIN
  IF requested_limit IS NOT NULL AND requested_limit NOT BETWEEN 1 AND 100
    OR (requested_cursor IS NOT NULL
      AND requested_cursor !~ '^mem_[0-9a-f]{64}$') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROFESSIONAL_READ_PAGE';
  END IF;
  effective_limit := COALESCE(requested_limit, 100);
  SELECT context.* INTO context_row
  FROM roomscan.professional_read_resolve_v1(
    requested_credential_kind, requested_credential_hash,
    authoritative_time, 'member.read'
  ) AS context;
  RETURN QUERY
  SELECT 'mem_' || encode(
      public.digest(convert_to(member.principal_id::text, 'UTF8'), 'sha256'), 'hex'
    ),
    member.role, member.state,
    member.principal_id = context_row.principal_id,
    member.updated_at
  FROM roomscan.memberships AS member
  WHERE member.workspace_id = context_row.workspace_id
    AND (requested_cursor IS NULL OR ('mem_' || encode(
      public.digest(convert_to(member.principal_id::text, 'UTF8'), 'sha256'), 'hex'
    )) > requested_cursor)
  ORDER BY 'mem_' || encode(
    public.digest(convert_to(member.principal_id::text, 'UTF8'), 'sha256'), 'hex'
  )
  LIMIT effective_limit;
END
$function$;

CREATE FUNCTION roomscan.publication_allocation_status_v1(
  requested_credential_kind text,
  requested_credential_hash bytea,
  authoritative_time timestamptz,
  requested_allocation_public_id text
)
RETURNS TABLE (
  allocation_public_id text,
  allocation_state text,
  publication_kind text,
  project_public_id text,
  source_revision_public_id text,
  property_public_id text,
  snapshot_public_id text,
  rejection_code text,
  created_at timestamptz,
  updated_at timestamptz,
  expires_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
BEGIN
  IF requested_allocation_public_id IS NULL
    OR requested_allocation_public_id !~ '^pua_[A-Za-z0-9_-]{16,128}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_ALLOCATION';
  END IF;
  SELECT context.* INTO context_row
  FROM roomscan.professional_read_resolve_v1(
    requested_credential_kind, requested_credential_hash,
    authoritative_time, 'publication.record.read'
  ) AS context;
  RETURN QUERY
  SELECT allocation.allocation_public_id, allocation.state, allocation.publication_kind,
    project.public_id, allocation.source_revision_public_id, property.public_id,
    snapshot.public_id, job.rejection_code, allocation.created_at,
    allocation.updated_at, allocation.allocation_expires_at
  FROM roomscan.publication_allocations AS allocation
  JOIN roomscan.professional_projects AS project
    ON project.workspace_id = allocation.workspace_id
    AND project.project_id = allocation.project_id
  LEFT JOIN roomscan.publication_properties AS property
    ON property.workspace_id = allocation.workspace_id
    AND property.property_id = allocation.property_id
  LEFT JOIN roomscan.publication_snapshots AS snapshot
    ON snapshot.workspace_id = allocation.workspace_id
    AND snapshot.allocation_id = allocation.allocation_id
  LEFT JOIN roomscan.publication_jobs AS job
    ON job.workspace_id = allocation.workspace_id
    AND job.allocation_id = allocation.allocation_id
  WHERE allocation.workspace_id = context_row.workspace_id
    AND allocation.allocation_public_id = requested_allocation_public_id;
END
$function$;

CREATE FUNCTION roomscan.publication_list_allocations_v1(
  requested_credential_kind text,
  requested_credential_hash bytea,
  authoritative_time timestamptz,
  requested_limit integer,
  requested_cursor text
)
RETURNS TABLE (
  allocation_public_id text,
  allocation_state text,
  publication_kind text,
  project_public_id text,
  source_revision_public_id text,
  property_public_id text,
  snapshot_public_id text,
  rejection_code text,
  created_at timestamptz,
  updated_at timestamptz,
  expires_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE effective_limit integer;
BEGIN
  IF requested_limit IS NOT NULL AND requested_limit NOT BETWEEN 1 AND 100
    OR (requested_cursor IS NOT NULL
      AND requested_cursor !~ '^pua_[A-Za-z0-9_-]{16,128}$') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROFESSIONAL_READ_PAGE';
  END IF;
  effective_limit := COALESCE(requested_limit, 100);
  SELECT context.* INTO context_row
  FROM roomscan.professional_read_resolve_v1(
    requested_credential_kind, requested_credential_hash,
    authoritative_time, 'publication.record.read'
  ) AS context;
  RETURN QUERY
  SELECT allocation.allocation_public_id, allocation.state, allocation.publication_kind,
    project.public_id, allocation.source_revision_public_id, property.public_id,
    snapshot.public_id, job.rejection_code, allocation.created_at,
    allocation.updated_at, allocation.allocation_expires_at
  FROM roomscan.publication_allocations AS allocation
  JOIN roomscan.professional_projects AS project
    ON project.workspace_id = allocation.workspace_id
    AND project.project_id = allocation.project_id
  LEFT JOIN roomscan.publication_properties AS property
    ON property.workspace_id = allocation.workspace_id
    AND property.property_id = allocation.property_id
  LEFT JOIN roomscan.publication_snapshots AS snapshot
    ON snapshot.workspace_id = allocation.workspace_id
    AND snapshot.allocation_id = allocation.allocation_id
  LEFT JOIN roomscan.publication_jobs AS job
    ON job.workspace_id = allocation.workspace_id
    AND job.allocation_id = allocation.allocation_id
  WHERE allocation.workspace_id = context_row.workspace_id
    AND (requested_cursor IS NULL OR allocation.allocation_public_id > requested_cursor)
  ORDER BY allocation.allocation_public_id
  LIMIT effective_limit;
END
$function$;

CREATE FUNCTION roomscan.publication_list_links_v1(
  requested_credential_kind text,
  requested_credential_hash bytea,
  authoritative_time timestamptz,
  requested_snapshot_public_id text,
  requested_limit integer,
  requested_cursor text
)
RETURNS TABLE (
  link_public_id text,
  snapshot_public_id text,
  generation bigint,
  state text,
  expires_at timestamptz,
  pin_required boolean,
  ai_enabled boolean,
  feedback_enabled boolean,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE effective_limit integer;
BEGIN
  IF requested_snapshot_public_id IS NOT NULL
    AND requested_snapshot_public_id !~ '^snp_[A-Za-z0-9_-]{16,128}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_SNAPSHOT';
  END IF;
  IF requested_limit IS NOT NULL AND requested_limit NOT BETWEEN 1 AND 100
    OR (requested_cursor IS NOT NULL
      AND requested_cursor !~ '^lnk_[A-Za-z0-9_-]{16,128}$') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROFESSIONAL_READ_PAGE';
  END IF;
  effective_limit := COALESCE(requested_limit, 100);
  SELECT context.* INTO context_row
  FROM roomscan.professional_read_resolve_v1(
    requested_credential_kind, requested_credential_hash,
    authoritative_time, 'publication.record.read'
  ) AS context;
  RETURN QUERY
  SELECT link.public_id, snapshot.public_id, link.generation, link.state,
    link.expires_at, link.pin_salt IS NOT NULL, link.ai_enabled,
    link.feedback_enabled, link.created_at, link.updated_at
  FROM roomscan.publication_links AS link
  JOIN roomscan.publication_snapshots AS snapshot
    ON snapshot.workspace_id = link.workspace_id
    AND snapshot.snapshot_id = link.snapshot_id
  WHERE link.workspace_id = context_row.workspace_id
    AND (requested_snapshot_public_id IS NULL OR snapshot.public_id = requested_snapshot_public_id)
    AND (requested_cursor IS NULL OR link.public_id > requested_cursor)
  ORDER BY link.public_id
  LIMIT effective_limit;
END
$function$;

CREATE FUNCTION roomscan.publication_list_feedback_v1(
  requested_credential_kind text,
  requested_credential_hash bytea,
  authoritative_time timestamptz,
  requested_link_public_id text,
  requested_snapshot_public_id text,
  requested_limit integer,
  requested_cursor text
)
RETURNS TABLE (
  feedback_reference text,
  link_public_id text,
  snapshot_public_id text,
  feedback_kind text,
  comment text,
  display_label text,
  occurred_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE effective_limit integer;
BEGIN
  IF (requested_link_public_id IS NOT NULL
      AND requested_link_public_id !~ '^lnk_[A-Za-z0-9_-]{16,128}$')
    OR (requested_snapshot_public_id IS NOT NULL
      AND requested_snapshot_public_id !~ '^snp_[A-Za-z0-9_-]{16,128}$') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_FEEDBACK_FILTER';
  END IF;
  IF requested_limit IS NOT NULL AND requested_limit NOT BETWEEN 1 AND 20
    OR (requested_cursor IS NOT NULL
      AND requested_cursor !~ '^fdb_[0-9a-f]{64}$') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROFESSIONAL_READ_PAGE';
  END IF;
  effective_limit := COALESCE(requested_limit, 20);
  SELECT context.* INTO context_row
  FROM roomscan.professional_read_resolve_v1(
    requested_credential_kind, requested_credential_hash,
    authoritative_time, 'publication.record.read'
  ) AS context;
  RETURN QUERY
  SELECT 'fdb_' || encode(
      public.digest(convert_to(feedback.feedback_id::text, 'UTF8'), 'sha256'), 'hex'
    ),
    link.public_id, snapshot.public_id, feedback.kind, feedback.comment,
    feedback.display_label, feedback.occurred_at
  FROM roomscan.publication_feedback AS feedback
  JOIN roomscan.publication_links AS link
    ON link.workspace_id = feedback.workspace_id
    AND link.link_id = feedback.link_id
  JOIN roomscan.publication_snapshots AS snapshot
    ON snapshot.workspace_id = feedback.workspace_id
    AND snapshot.snapshot_id = feedback.snapshot_id
  WHERE feedback.workspace_id = context_row.workspace_id
    AND (requested_link_public_id IS NULL OR link.public_id = requested_link_public_id)
    AND (requested_snapshot_public_id IS NULL OR snapshot.public_id = requested_snapshot_public_id)
    AND (requested_cursor IS NULL OR ('fdb_' || encode(
      public.digest(convert_to(feedback.feedback_id::text, 'UTF8'), 'sha256'), 'hex'
    )) > requested_cursor)
  ORDER BY 'fdb_' || encode(
    public.digest(convert_to(feedback.feedback_id::text, 'UTF8'), 'sha256'), 'hex'
  )
  LIMIT effective_limit;
END
$function$;

CREATE FUNCTION roomscan.publication_list_access_history_v1(
  requested_credential_kind text,
  requested_credential_hash bytea,
  authoritative_time timestamptz,
  requested_link_public_id text,
  requested_limit integer,
  requested_cursor text
)
RETURNS TABLE (
  event_reference text,
  link_public_id text,
  snapshot_public_id text,
  action text,
  outcome text,
  occurred_hour timestamptz,
  client_family text
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE effective_limit integer;
BEGIN
  IF requested_link_public_id IS NOT NULL
    AND requested_link_public_id !~ '^lnk_[A-Za-z0-9_-]{16,128}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_LINK';
  END IF;
  IF requested_limit IS NOT NULL AND requested_limit NOT BETWEEN 1 AND 100
    OR (requested_cursor IS NOT NULL
      AND requested_cursor !~ '^evh_[0-9a-f]{64}$') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROFESSIONAL_READ_PAGE';
  END IF;
  effective_limit := COALESCE(requested_limit, 100);
  SELECT context.* INTO context_row
  FROM roomscan.professional_read_resolve_v1(
    requested_credential_kind, requested_credential_hash,
    authoritative_time, 'access_history.read'
  ) AS context;
  RETURN QUERY
  SELECT 'evh_' || encode(
      public.digest(convert_to(event.event_id::text, 'UTF8'), 'sha256'), 'hex'
    ),
    link.public_id, snapshot.public_id, event.action, event.outcome,
    event.occurred_hour, event.client_family
  FROM roomscan.publication_access_events AS event
  JOIN roomscan.publication_links AS link
    ON link.workspace_id = event.workspace_id
    AND link.link_id = event.link_id
  JOIN roomscan.publication_snapshots AS snapshot
    ON snapshot.workspace_id = event.workspace_id
    AND snapshot.snapshot_id = event.snapshot_id
  WHERE event.workspace_id = context_row.workspace_id
    AND (requested_link_public_id IS NULL OR link.public_id = requested_link_public_id)
    AND (requested_cursor IS NULL OR ('evh_' || encode(
      public.digest(convert_to(event.event_id::text, 'UTF8'), 'sha256'), 'hex'
    )) > requested_cursor)
  ORDER BY 'evh_' || encode(
    public.digest(convert_to(event.event_id::text, 'UTF8'), 'sha256'), 'hex'
  )
  LIMIT effective_limit;
END
$function$;

CREATE FUNCTION roomscan.publication_list_downloads_v1(
  requested_credential_kind text,
  requested_credential_hash bytea,
  authoritative_time timestamptz,
  requested_snapshot_public_id text,
  requested_limit integer,
  requested_cursor text
)
RETURNS TABLE (
  snapshot_public_id text,
  asset_public_id text,
  download_kind text,
  content_type text,
  asset_bytes bigint,
  asset_digest bytea
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE effective_limit integer;
BEGIN
  IF requested_snapshot_public_id IS NOT NULL
    AND requested_snapshot_public_id !~ '^snp_[A-Za-z0-9_-]{16,128}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_SNAPSHOT';
  END IF;
  IF requested_limit IS NOT NULL AND requested_limit NOT BETWEEN 1 AND 100
    OR (requested_cursor IS NOT NULL
      AND requested_cursor !~ '^ast_[A-Za-z0-9_-]{16,128}$') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROFESSIONAL_READ_PAGE';
  END IF;
  effective_limit := COALESCE(requested_limit, 100);
  SELECT context.* INTO context_row
  FROM roomscan.professional_read_resolve_v1(
    requested_credential_kind, requested_credential_hash,
    authoritative_time, 'publication.record.read'
  ) AS context;
  RETURN QUERY
  SELECT snapshot.public_id, asset.public_id, asset.download_kind,
    asset.content_type, asset.bytes, asset.digest
  FROM roomscan.publication_assets AS asset
  JOIN roomscan.publication_snapshots AS snapshot
    ON snapshot.workspace_id = asset.workspace_id
    AND snapshot.snapshot_id = asset.snapshot_id
  WHERE asset.workspace_id = context_row.workspace_id
    AND asset.download_kind IS NOT NULL
    AND (requested_snapshot_public_id IS NULL OR snapshot.public_id = requested_snapshot_public_id)
    AND (requested_cursor IS NULL OR asset.public_id > requested_cursor)
  ORDER BY asset.public_id
  LIMIT effective_limit;
END
$function$;

-- This is metadata lookup only.  The next protected asset-range reducer is
-- still required to obtain the exact version-bound object read authorization.
CREATE FUNCTION roomscan.portal_lookup_presentation_asset_v1(
  requested_session_hash bytea,
  authoritative_time timestamptz
)
RETURNS TABLE (
  asset_public_id text,
  content_type text,
  asset_digest bytea,
  asset_bytes bigint
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
BEGIN
  SELECT context.* INTO context_row
  FROM roomscan.portal_session_context_v1(requested_session_hash, authoritative_time) AS context;
  RETURN QUERY
  SELECT asset.public_id, asset.content_type, asset.digest, asset.bytes
  FROM roomscan.publication_assets AS asset
  WHERE asset.workspace_id = context_row.workspace_id
    AND asset.snapshot_id = context_row.snapshot_id
    AND asset.asset_kind = 'presentation';
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PORTAL_PRESENTATION_NOT_FOUND';
  END IF;
END
$function$;

-- Billing stays read-only in Slice 6.  The bootstrap gives an authorized
-- owner/admin only the existing subscription and portal quota view needed by
-- the lightweight professional web, without creating any billing mutation.
CREATE FUNCTION roomscan.professional_session_bootstrap_v1(
  requested_credential_kind text,
  requested_credential_hash bytea,
  authoritative_time timestamptz
)
RETURNS TABLE (
  plan_key text,
  subscription_status text,
  current_period_end timestamptz,
  quota_policy_version bigint,
  portal_period_key text,
  portal_bytes_used bigint,
  portal_bytes_reserved bigint,
  portal_bytes_limit bigint
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
BEGIN
  SELECT context.* INTO context_row
  FROM roomscan.professional_read_resolve_v1(
    requested_credential_kind, requested_credential_hash,
    authoritative_time, 'subscription.read'
  ) AS context;
  PERFORM 1 FROM roomscan.professional_read_resolve_v1(
    requested_credential_kind, requested_credential_hash,
    authoritative_time, 'usage.read'
  );
  PERFORM 1 FROM roomscan.professional_read_resolve_v1(
    requested_credential_kind, requested_credential_hash,
    authoritative_time, 'limit.read'
  );
  RETURN QUERY
  SELECT subscription.plan_key, subscription.status, subscription.current_period_end,
    policy.version, policy.portal_period_key,
    COALESCE(usage.used, 0::bigint), COALESCE(usage.reserved, 0::bigint),
    COALESCE(usage.limit_value, 0::bigint)
  FROM roomscan.subscription_states AS subscription
  LEFT JOIN roomscan.quota_policy_versions_v2 AS policy
    ON policy.workspace_id = subscription.workspace_id AND policy.is_active IS TRUE
  LEFT JOIN roomscan.quota_usage_v2 AS usage
    ON usage.workspace_id = subscription.workspace_id
    AND usage.metric = 'portal_bytes'
    AND usage.period_key = policy.portal_period_key
  WHERE subscription.workspace_id = context_row.workspace_id;
END
$function$;

RESET ROLE;

ALTER FUNCTION roomscan.publication_immutable_guard_v1() OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.publication_snapshot_room_guard_v1() OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.publication_require_worker_v1() OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.publication_require_portal_v1() OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.publication_require_live_grant_v1(uuid, text, bigint, bigint, bigint, bigint) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.publication_resolve_api_access_v1(text, bytea, timestamptz, uuid, text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.publication_append_access_event_v1(uuid, uuid, bigint, uuid, text, text, timestamptz, text, bytea) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.publication_require_source_binding_v1(uuid, uuid, uuid, text, bytea, bytea) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.publication_check_quota_policy_v1(uuid, bigint) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.publication_property_membership_digest_v1(uuid, uuid) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.publication_allocate_v1(text, bytea, timestamptz, text, text, bytea, bytea, bytea, bytea, text, text, text, jsonb, bytea, bytea, bytea, bigint, bytea) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.publication_complete_v1(text, bytea, timestamptz, text, bytea, bytea, bigint, text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.professional_read_resolve_v1(text, bytea, timestamptz, text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.professional_list_properties_v1(text, bytea, timestamptz, integer, text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.publication_list_room_candidates_v1(text, bytea, timestamptz, integer, text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.professional_list_concepts_v1(text, bytea, timestamptz, text, integer, text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.professional_list_members_v1(text, bytea, timestamptz, integer, text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.publication_allocation_status_v1(text, bytea, timestamptz, text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.publication_list_allocations_v1(text, bytea, timestamptz, integer, text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.publication_list_links_v1(text, bytea, timestamptz, text, integer, text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.publication_list_feedback_v1(text, bytea, timestamptz, text, text, integer, text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.publication_list_access_history_v1(text, bytea, timestamptz, text, integer, text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.publication_list_downloads_v1(text, bytea, timestamptz, text, integer, text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.portal_lookup_presentation_asset_v1(bytea, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.professional_session_bootstrap_v1(text, bytea, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.publication_upsert_property_v1(text, bytea, timestamptz, text, bigint, text, jsonb) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.publication_add_property_room_v1(text, bytea, timestamptz, text, text, integer, text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.publication_claim_job_v1(timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.publication_reject_v1(uuid, text, timestamptz, text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.publication_validate_asset_manifest_v1(jsonb) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.publication_finalize_v1(uuid, text, timestamptz, text, bytea, bytea, bigint, jsonb) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.professional_session_issue_v1(bytea, timestamptz, bytea, uuid) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.professional_session_revoke_v1(bytea, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.professional_session_resolve_v1(bytea, timestamptz, text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.publication_create_link_v1(text, bytea, timestamptz, text, bytea, timestamptz, bytea, bytea, text, text, bytea) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.publication_update_link_v1(text, bytea, timestamptz, text, bytea, timestamptz, bytea, bytea, text, text, bigint) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.publication_reset_link_v1(text, bytea, timestamptz, text, bytea, timestamptz, bytea, bytea, text, text, bigint) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.publication_revoke_link_v1(text, bytea, timestamptz, text, bigint) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.portal_session_context_v1(bytea, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.portal_exchange_link_v1(bytea, timestamptz, bytea, text, bytea) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.portal_pin_parameters_v1(bytea, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.portal_pin_attempt_v1(bytea, timestamptz, bytea) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.portal_verify_pin_v1(bytea, timestamptz, bytea) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.portal_request_feedback_verification_v1(bytea, timestamptz, bytea, bytea, bytea) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.portal_consume_feedback_verification_v1(bytea, bytea, timestamptz, bytea) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.publication_require_feedback_scope_v1(bytea, uuid, uuid, uuid, bigint, uuid, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.portal_create_feedback_v1(bytea, timestamptz, bytea, text, text, bytea) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.portal_get_snapshot_v1(bytea, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.portal_list_property_rooms_v1(bytea, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.portal_authorize_asset_v1(bytea, timestamptz, text, bytea, bigint, bigint) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.portal_finalize_asset_delivery_v1(bytea, timestamptz, text, bytea, bigint, bigint, text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.portal_authorize_download_v1(bytea, timestamptz, text, bytea, bigint, bigint) OWNER TO roomscan_policy;

REVOKE ALL ON ALL TABLES IN SCHEMA roomscan FROM PUBLIC;
-- Keep the publication ACL closure additive: a migration-wide FUNCTION revoke
-- would silently overwrite ACL mutations to pre-0009 routines and mask their
-- compatibility oracles. Revoke only the routines introduced by this slice.
REVOKE ALL ON FUNCTION roomscan.publication_immutable_guard_v1(),
  roomscan.publication_snapshot_room_guard_v1(),
  roomscan.portal_request_feedback_verification_v1(bytea, timestamptz, bytea, bytea, bytea),
  roomscan.portal_consume_feedback_verification_v1(bytea, bytea, timestamptz, bytea),
  roomscan.publication_require_feedback_scope_v1(bytea, uuid, uuid, uuid, bigint, uuid, timestamptz),
  roomscan.portal_create_feedback_v1(bytea, timestamptz, bytea, text, text, bytea),
  roomscan.portal_get_snapshot_v1(bytea, timestamptz),
  roomscan.portal_list_property_rooms_v1(bytea, timestamptz),
  roomscan.portal_authorize_asset_v1(bytea, timestamptz, text, bytea, bigint, bigint),
  roomscan.portal_finalize_asset_delivery_v1(bytea, timestamptz, text, bytea, bigint, bigint, text),
  roomscan.portal_authorize_download_v1(bytea, timestamptz, text, bytea, bigint, bigint),
  roomscan.publication_upsert_property_v1(text, bytea, timestamptz, text, bigint, text, jsonb),
  roomscan.publication_add_property_room_v1(text, bytea, timestamptz, text, text, integer, text),
  roomscan.publication_claim_job_v1(timestamptz),
  roomscan.publication_reject_v1(uuid, text, timestamptz, text),
  roomscan.publication_validate_asset_manifest_v1(jsonb),
  roomscan.publication_finalize_v1(uuid, text, timestamptz, text, bytea, bytea, bigint, jsonb),
  roomscan.professional_session_issue_v1(bytea, timestamptz, bytea, uuid),
  roomscan.professional_session_revoke_v1(bytea, timestamptz),
  roomscan.professional_session_resolve_v1(bytea, timestamptz, text),
  roomscan.publication_create_link_v1(text, bytea, timestamptz, text, bytea, timestamptz, bytea, bytea, text, text, bytea),
  roomscan.publication_update_link_v1(text, bytea, timestamptz, text, bytea, timestamptz, bytea, bytea, text, text, bigint),
  roomscan.publication_reset_link_v1(text, bytea, timestamptz, text, bytea, timestamptz, bytea, bytea, text, text, bigint),
  roomscan.publication_revoke_link_v1(text, bytea, timestamptz, text, bigint),
  roomscan.portal_session_context_v1(bytea, timestamptz),
  roomscan.portal_exchange_link_v1(bytea, timestamptz, bytea, text, bytea),
  roomscan.portal_pin_parameters_v1(bytea, timestamptz),
  roomscan.portal_pin_attempt_v1(bytea, timestamptz, bytea),
  roomscan.portal_verify_pin_v1(bytea, timestamptz, bytea),
  roomscan.publication_require_worker_v1(),
  roomscan.publication_require_portal_v1(),
  roomscan.publication_require_live_grant_v1(uuid, text, bigint, bigint, bigint, bigint),
  roomscan.publication_resolve_api_access_v1(text, bytea, timestamptz, uuid, text),
  roomscan.publication_append_access_event_v1(uuid, uuid, bigint, uuid, text, text, timestamptz, text, bytea),
  roomscan.publication_require_source_binding_v1(uuid, uuid, uuid, text, bytea, bytea),
  roomscan.publication_check_quota_policy_v1(uuid, bigint),
  roomscan.publication_property_membership_digest_v1(uuid, uuid),
  roomscan.publication_allocate_v1(text, bytea, timestamptz, text, text, bytea, bytea, bytea, bytea, text, text, text, jsonb, bytea, bytea, bytea, bigint, bytea),
  roomscan.publication_complete_v1(text, bytea, timestamptz, text, bytea, bytea, bigint, text),
  roomscan.professional_read_resolve_v1(text, bytea, timestamptz, text),
  roomscan.professional_list_properties_v1(text, bytea, timestamptz, integer, text),
  roomscan.publication_list_room_candidates_v1(text, bytea, timestamptz, integer, text),
  roomscan.professional_list_concepts_v1(text, bytea, timestamptz, text, integer, text),
  roomscan.professional_list_members_v1(text, bytea, timestamptz, integer, text),
  roomscan.publication_allocation_status_v1(text, bytea, timestamptz, text),
  roomscan.publication_list_allocations_v1(text, bytea, timestamptz, integer, text),
  roomscan.publication_list_links_v1(text, bytea, timestamptz, text, integer, text),
  roomscan.publication_list_feedback_v1(text, bytea, timestamptz, text, text, integer, text),
  roomscan.publication_list_access_history_v1(text, bytea, timestamptz, text, integer, text),
  roomscan.publication_list_downloads_v1(text, bytea, timestamptz, text, integer, text),
  roomscan.portal_lookup_presentation_asset_v1(bytea, timestamptz),
  roomscan.professional_session_bootstrap_v1(text, bytea, timestamptz)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION roomscan.publication_list_room_candidates_v1(
  text, bytea, timestamptz, integer, text
) FROM roomscan_app, roomscan_portal_runtime, roomscan_publication_worker,
  roomscan_email_delivery_runtime;
REVOKE ALL ON roomscan.publication_properties, roomscan.publication_property_rooms,
  roomscan.publication_snapshot_rooms, roomscan.publication_allocation_source_bindings,
  roomscan.publication_allocations, roomscan.publication_sources,
  roomscan.publication_approvals, roomscan.publication_jobs,
  roomscan.publication_snapshots, roomscan.publication_assets,
  roomscan.publication_links, roomscan.professional_web_sessions,
  roomscan.portal_sessions, roomscan.portal_pin_throttles,
  roomscan.portal_feedback_challenges, roomscan.publication_feedback,
  roomscan.publication_access_events, roomscan.portal_delivery_receipts,
  roomscan.portal_asset_reservations
  FROM roomscan_api_runtime, roomscan_publication_worker, roomscan_portal_runtime;

GRANT SELECT, INSERT, UPDATE ON roomscan.publication_properties,
  roomscan.publication_property_rooms, roomscan.publication_allocations,
  roomscan.publication_jobs, roomscan.publication_links,
  roomscan.professional_web_sessions, roomscan.portal_sessions,
  roomscan.portal_pin_throttles, roomscan.portal_feedback_challenges,
  roomscan.portal_asset_reservations
  TO roomscan_policy;
GRANT DELETE ON roomscan.publication_property_rooms TO roomscan_policy;
GRANT SELECT, INSERT ON roomscan.publication_sources,
  roomscan.publication_approvals, roomscan.publication_snapshots,
  roomscan.publication_snapshot_rooms, roomscan.publication_allocation_source_bindings,
  roomscan.publication_assets, roomscan.publication_feedback,
  roomscan.publication_access_events, roomscan.portal_delivery_receipts
  TO roomscan_policy;
GRANT SELECT ON roomscan.publication_properties, roomscan.publication_property_rooms,
  roomscan.publication_snapshot_rooms, roomscan.publication_allocation_source_bindings,
  roomscan.publication_allocations, roomscan.publication_sources,
  roomscan.publication_approvals, roomscan.publication_jobs,
  roomscan.publication_snapshots, roomscan.publication_assets,
  roomscan.publication_links, roomscan.professional_web_sessions,
  roomscan.portal_sessions, roomscan.portal_pin_throttles,
  roomscan.portal_feedback_challenges, roomscan.publication_feedback,
  roomscan.publication_access_events, roomscan.portal_delivery_receipts
  TO roomscan_policy;

GRANT EXECUTE ON FUNCTION roomscan.publication_upsert_property_v1(text, bytea, timestamptz, text, bigint, text, jsonb),
  roomscan.publication_allocate_v1(text, bytea, timestamptz, text, text, bytea, bytea, bytea, bytea, text, text, text, jsonb, bytea, bytea, bytea, bigint, bytea),
  roomscan.publication_complete_v1(text, bytea, timestamptz, text, bytea, bytea, bigint, text),
  roomscan.publication_create_link_v1(text, bytea, timestamptz, text, bytea, timestamptz, bytea, bytea, text, text, bytea),
  roomscan.publication_update_link_v1(text, bytea, timestamptz, text, bytea, timestamptz, bytea, bytea, text, text, bigint),
  roomscan.publication_reset_link_v1(text, bytea, timestamptz, text, bytea, timestamptz, bytea, bytea, text, text, bigint),
  roomscan.publication_revoke_link_v1(text, bytea, timestamptz, text, bigint),
  roomscan.professional_session_issue_v1(bytea, timestamptz, bytea, uuid),
  roomscan.professional_session_revoke_v1(bytea, timestamptz),
  roomscan.professional_session_resolve_v1(bytea, timestamptz, text),
  roomscan.publication_resolve_api_access_v1(text, bytea, timestamptz, uuid, text),
  roomscan.professional_list_properties_v1(text, bytea, timestamptz, integer, text),
  roomscan.publication_list_room_candidates_v1(text, bytea, timestamptz, integer, text),
  roomscan.professional_list_concepts_v1(text, bytea, timestamptz, text, integer, text),
  roomscan.professional_list_members_v1(text, bytea, timestamptz, integer, text),
  roomscan.publication_allocation_status_v1(text, bytea, timestamptz, text),
  roomscan.publication_list_allocations_v1(text, bytea, timestamptz, integer, text),
  roomscan.publication_list_links_v1(text, bytea, timestamptz, text, integer, text),
  roomscan.publication_list_feedback_v1(text, bytea, timestamptz, text, text, integer, text),
  roomscan.publication_list_access_history_v1(text, bytea, timestamptz, text, integer, text),
  roomscan.publication_list_downloads_v1(text, bytea, timestamptz, text, integer, text),
  roomscan.professional_session_bootstrap_v1(text, bytea, timestamptz)
  TO roomscan_api_runtime;
GRANT EXECUTE ON FUNCTION roomscan.publication_claim_job_v1(timestamptz),
  roomscan.publication_reject_v1(uuid, text, timestamptz, text),
  roomscan.publication_finalize_v1(uuid, text, timestamptz, text, bytea, bytea, bigint, jsonb)
  TO roomscan_publication_worker;
GRANT EXECUTE ON FUNCTION roomscan.portal_exchange_link_v1(bytea, timestamptz, bytea, text, bytea),
  roomscan.portal_pin_parameters_v1(bytea, timestamptz),
  roomscan.portal_pin_attempt_v1(bytea, timestamptz, bytea),
  roomscan.portal_verify_pin_v1(bytea, timestamptz, bytea),
  roomscan.portal_get_snapshot_v1(bytea, timestamptz),
  roomscan.portal_list_property_rooms_v1(bytea, timestamptz),
  roomscan.portal_authorize_asset_v1(bytea, timestamptz, text, bytea, bigint, bigint),
  roomscan.portal_finalize_asset_delivery_v1(bytea, timestamptz, text, bytea, bigint, bigint, text),
  roomscan.portal_authorize_download_v1(bytea, timestamptz, text, bytea, bigint, bigint),
  roomscan.portal_lookup_presentation_asset_v1(bytea, timestamptz),
  roomscan.portal_request_feedback_verification_v1(bytea, timestamptz, bytea, bytea, bytea),
  roomscan.portal_consume_feedback_verification_v1(bytea, bytea, timestamptz, bytea),
  roomscan.portal_create_feedback_v1(bytea, timestamptz, bytea, text, text, bytea)
  TO roomscan_portal_runtime;

COMMENT ON FUNCTION roomscan.publication_allocate_v1(text, bytea, timestamptz, text, text, bytea, bytea, bytea, bytea, text, text, text, jsonb, bytea, bytea, bytea, bigint, bytea) IS
  'Slice 6 allocation derives role/recent-auth, quota policy, and four live flag versions from one app-bearer or professional-cookie capability. It binds one explicit approved disclosure decision, current canonical immutable source revision, and exact source/selection/approval/archive digests without serializing a private project.';
COMMENT ON FUNCTION roomscan.publication_finalize_v1(uuid, text, timestamptz, text, bytea, bytea, bigint, jsonb) IS
  'Slice 6 worker-only validate-stage-promote finalizer. Every source, approval, quota, and flag binding is rechecked under a lease before immutable snapshot/assets are inserted.';
COMMENT ON FUNCTION roomscan.portal_session_context_v1(bytea, timestamptz) IS
  'Slice 6 portal authorization rechecks state, expiry equality, link generation, snapshot, both hosted/publication flag versions, and PIN state for every protected request.';
COMMENT ON FUNCTION roomscan.portal_authorize_asset_v1(bytea, timestamptz, text, bytea, bigint, bigint) IS
  'Slice 6 protected asset reservation capability: every request reauthorizes live portal state and binds one exact bounded object-version byte range without charging a failed storage read.';
COMMENT ON FUNCTION roomscan.portal_finalize_asset_delivery_v1(bytea, timestamptz, text, bytea, bigint, bigint, text) IS
  'Slice 6 protected delivery finalizer: it reauthorizes live portal state immediately before service emission, then atomically records one exact version-bound byte range.';
COMMENT ON FUNCTION roomscan.portal_create_feedback_v1(bytea, timestamptz, bytea, text, text, bytea) IS
  'Slice 6 append-only verified feedback scoped to one active link generation and immutable snapshot. This capability has no project mutation path.';
COMMENT ON FUNCTION roomscan.publication_immutable_guard_v1() IS
  'Slice 6 immutable-record trigger guard. It always rejects update and delete attempts for approved publication records.';
COMMENT ON FUNCTION roomscan.publication_snapshot_room_guard_v1() IS
  'Slice 6 immutable property snapshot-room guard. It permits finalization-time insertion only when ordered same-tenant room provenance matches the frozen allocation binding.';
COMMENT ON FUNCTION roomscan.publication_append_access_event_v1(uuid, uuid, bigint, uuid, text, text, timestamptz, text, bytea) IS
  'Slice 6 privacy-minimized access-history append seam. It stores only bounded action/outcome/hour/client-family/risk-digest facts.';
COMMENT ON FUNCTION roomscan.publication_require_source_binding_v1(uuid, uuid, uuid, text, bytea, bytea) IS
  'Slice 6 exact immutable canonical source binding guard for a private professional project revision and its working/manifest digests.';
COMMENT ON FUNCTION roomscan.publication_check_quota_policy_v1(uuid, bigint) IS
  'Slice 6 portal-traffic quota policy epoch guard used before immutable publication work becomes public.';
COMMENT ON FUNCTION roomscan.publication_property_membership_digest_v1(uuid, uuid) IS
  'Slice 6 deterministic mutable property-curation digest. Allocation and finalization compare this exact ordered independent-room draft before it can become immutable.';
COMMENT ON FUNCTION roomscan.publication_complete_v1(text, bytea, timestamptz, text, bytea, bytea, bigint, text) IS
  'Slice 6 API-only archive completion reducer. It verifies allocation ownership, live grants, exact archive bytes/digests, and the versioned quarantine object version before validation.';
COMMENT ON FUNCTION roomscan.professional_read_resolve_v1(text, bytea, timestamptz, text) IS
  'Slice 6 internal professional-read resolver. It accepts one explicit app-bearer or professional-cookie hash and derives a live exact read grant without exposing either credential.';
COMMENT ON FUNCTION roomscan.professional_list_properties_v1(text, bytea, timestamptz, integer, text) IS
  'Slice 6 bounded app-bearer/professional-cookie property reader. It returns only room-key/order/project-ID curation metadata after a live project.read authorization check, never coordinates or topology.';
COMMENT ON FUNCTION roomscan.publication_list_room_candidates_v1(text, bytea, timestamptz, integer, text) IS
  'Slice 6 bounded API-only project.read room inventory. It returns only current canonical nondeleted professional project public IDs and titles truncated to 180 characters, never private IDs or revision/package material.';
COMMENT ON FUNCTION roomscan.professional_list_concepts_v1(text, bytea, timestamptz, text, integer, text) IS
  'Slice 6 bounded app-bearer/professional-cookie concept reader. It returns only allowlisted already-published approved concept derivatives, never a private working archive.';
COMMENT ON FUNCTION roomscan.professional_list_members_v1(text, bytea, timestamptz, integer, text) IS
  'Slice 6 bounded app-bearer/professional-cookie member/role reader. It returns opaque member references and roles without email or identity-provider fields.';
COMMENT ON FUNCTION roomscan.publication_allocation_status_v1(text, bytea, timestamptz, text) IS
  'Slice 6 bounded app-bearer/professional-cookie pua status reader. It returns allocation state without source digests, private IDs, or storage locations.';
COMMENT ON FUNCTION roomscan.publication_list_allocations_v1(text, bytea, timestamptz, integer, text) IS
  'Slice 6 bounded app-bearer/professional-cookie allocation list reader. It enforces publication.record.read against current hosted and publication flags.';
COMMENT ON FUNCTION roomscan.publication_list_links_v1(text, bytea, timestamptz, text, integer, text) IS
  'Slice 6 bounded app-bearer/professional-cookie portal-link status reader. It never returns bearer token hashes or PIN verifier material.';
COMMENT ON FUNCTION roomscan.publication_list_feedback_v1(text, bytea, timestamptz, text, text, integer, text) IS
  'Slice 6 bounded app-bearer/professional-cookie immutable feedback summary reader. It omits verification email and request digests.';
COMMENT ON FUNCTION roomscan.publication_list_access_history_v1(text, bytea, timestamptz, text, integer, text) IS
  'Slice 6 bounded owner/admin app-bearer/professional-cookie privacy-minimized access-history reader. It omits portal session and network-risk identifiers.';
COMMENT ON FUNCTION roomscan.publication_list_downloads_v1(text, bytea, timestamptz, text, integer, text) IS
  'Slice 6 bounded app-bearer/professional-cookie fallback and AI-ready download metadata reader. It does not grant object-key, version, or presign access.';
COMMENT ON FUNCTION roomscan.portal_lookup_presentation_asset_v1(bytea, timestamptz) IS
  'Slice 6 live portal presentation metadata lookup. Exact protected object-range authorization remains a separate per-request reducer.';
COMMENT ON FUNCTION roomscan.professional_session_bootstrap_v1(text, bytea, timestamptz) IS
  'Slice 6 owner/admin app-bearer/professional-cookie bootstrap for existing read-only subscription and portal quota facts; it has no billing mutation capability.';
COMMENT ON FUNCTION roomscan.publication_upsert_property_v1(text, bytea, timestamptz, text, bigint, text, jsonb) IS
  'Slice 6 atomic optimistic-CAS property curation reducer. Its server-runtime authoritative_time input is callable only by roomscan_api_runtime; it uses project.revise authorization to replace a bounded ordered independent-room draft with no transforms, topology, or reconstruction claims.';
COMMENT ON FUNCTION roomscan.publication_add_property_room_v1(text, bytea, timestamptz, text, text, integer, text) IS
  'Slice 6 ungranted compatibility helper. Professional property curation uses the atomic publication_upsert_property_v1 reducer so add/reorder/remove is one transaction.';
COMMENT ON FUNCTION roomscan.publication_claim_job_v1(timestamptz) IS
  'Slice 6 worker-only validation lease reducer. It claims only valid live publication work and returns bounded archive metadata.';
COMMENT ON FUNCTION roomscan.publication_reject_v1(uuid, text, timestamptz, text) IS
  'Slice 6 worker-only terminal rejection reducer. It requires the live exact validation lease and never returns a poisoned archive job to the pending queue.';
COMMENT ON FUNCTION roomscan.publication_validate_asset_manifest_v1(jsonb) IS
  'Slice 6 asset allowlist validator. It rejects unknown artifact fields, unsafe kinds, unbounded bytes, invalid object names, and duplicate public assets.';
COMMENT ON FUNCTION roomscan.publication_require_live_grant_v1(uuid, text, bigint, bigint, bigint, bigint) IS
  'Slice 6 hosted/publication kill-switch epoch guard shared by API allocation, link policy, and worker finalization reducers.';
COMMENT ON FUNCTION roomscan.publication_resolve_api_access_v1(text, bytea, timestamptz, uuid, text) IS
  'Slice 6 unified professional mutation resolver. It accepts exactly one explicit app-bearer or professional-cookie hash and derives current membership, recent-auth, role, quota policy, and live flag epochs internally.';
COMMENT ON FUNCTION roomscan.professional_session_issue_v1(bytea, timestamptz, bytea, uuid) IS
  'Slice 6 professional-web session issuer. It requires a hosted authenticated account context and does not affect guest or local workflows.';
COMMENT ON FUNCTION roomscan.professional_session_revoke_v1(bytea, timestamptz) IS
  'Slice 6 professional-web session revoker for a hashed session handle.';
COMMENT ON FUNCTION roomscan.professional_session_resolve_v1(bytea, timestamptz, text) IS
  'Slice 6 professional-cookie resolver. It derives current membership, role, recent-auth state, and live flag versions from a hashed cookie without an app-bearer fallback.';
COMMENT ON FUNCTION roomscan.publication_create_link_v1(text, bytea, timestamptz, text, bytea, timestamptz, bytea, bytea, text, text, bytea) IS
  'Slice 6 API-only portal-link creator. It stores only a bearer hash, bounded expiry, optional server PIN verifier material, and strict AI and feedback entitlements.';
COMMENT ON FUNCTION roomscan.publication_update_link_v1(text, bytea, timestamptz, text, bytea, timestamptz, bytea, bytea, text, text, bigint) IS
  'Slice 6 API-only portal-link policy update. It rotates generation and rebinds all protected-session checks.';
COMMENT ON FUNCTION roomscan.publication_reset_link_v1(text, bytea, timestamptz, text, bytea, timestamptz, bytea, bytea, text, text, bigint) IS
  'Slice 6 API-only portal-link rotation alias with the same exact update, expiry, PIN, and entitlement checks.';
COMMENT ON FUNCTION roomscan.publication_revoke_link_v1(text, bytea, timestamptz, text, bigint) IS
  'Slice 6 API-only immediate portal-link revocation reducer. Existing portal sessions and protected assets recheck this link state.';
COMMENT ON FUNCTION roomscan.portal_exchange_link_v1(bytea, timestamptz, bytea, text, bytea) IS
  'Slice 6 portal bearer-link exchange. It accepts only hashed bearer material and creates a short-lived session after live flag/state checks.';
COMMENT ON FUNCTION roomscan.portal_pin_parameters_v1(bytea, timestamptz) IS
  'Slice 6 portal-only PIN KDF seam. It returns only an active pin-required session salt and fixed scrypt parameters after current link, generation, expiry, and kill-switch checks.';
COMMENT ON FUNCTION roomscan.portal_pin_attempt_v1(bytea, timestamptz, bytea) IS
  'Slice 6 portal PIN reducer. It rechecks hosted/publication epochs and enforces the bounded five-failure fifteen-minute cooldown.';
COMMENT ON FUNCTION roomscan.portal_verify_pin_v1(bytea, timestamptz, bytea) IS
  'Slice 6 portal PIN verification alias that delegates to the guarded PIN-attempt reducer.';
COMMENT ON FUNCTION roomscan.portal_request_feedback_verification_v1(bytea, timestamptz, bytea, bytea, bytea) IS
  'Slice 6 verified-feedback challenge issuer commits a server-delivery token hash, email digest, and one live portal scope atomically.';
COMMENT ON FUNCTION roomscan.portal_consume_feedback_verification_v1(bytea, bytea, timestamptz, bytea) IS
  'Slice 6 one-time feedback token consumer rechecks the current live portal scope and only compares against the precommitted hash.';
COMMENT ON FUNCTION roomscan.publication_require_feedback_scope_v1(bytea, uuid, uuid, uuid, bigint, uuid, timestamptz) IS
  'Slice 6 feedback-scope guard binding a consumed verification token to exactly one session, tenant, link generation, and snapshot.';
COMMENT ON FUNCTION roomscan.portal_get_snapshot_v1(bytea, timestamptz) IS
  'Slice 6 protected snapshot reader. Every request rechecks session, link state, expiry, generation, flags, and PIN state.';
COMMENT ON FUNCTION roomscan.portal_list_property_rooms_v1(bytea, timestamptz) IS
  'Slice 6 protected property navigator. It returns ordered independent room snapshot references without spatial relationship claims.';
COMMENT ON FUNCTION roomscan.portal_authorize_download_v1(bytea, timestamptz, text, bytea, bigint, bigint) IS
  'Slice 6 protected bounded fallback/AI download capability. It reauthorizes the portal session and accounts an exact byte range.';

-- Named guards are kept as separate capability seams so mutation tests can
-- neutralize one protection at a time without changing the public reducers.
CREATE FUNCTION roomscan.publication_feedback_immutable_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'IMMUTABLE_PUBLICATION_FEEDBACK';
END
$function$;

CREATE FUNCTION roomscan.portal_require_active_session_v1(
  requested_session_hash bytea,
  authoritative_time timestamptz
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  PERFORM 1 FROM roomscan.portal_session_context_v1(
    requested_session_hash, authoritative_time
  );
END
$function$;

ALTER FUNCTION roomscan.publication_feedback_immutable_guard_v1() OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.portal_require_active_session_v1(bytea, timestamptz) OWNER TO roomscan_policy;
COMMENT ON FUNCTION roomscan.publication_feedback_immutable_guard_v1() IS
  'Slice 6 feedback-specific immutable trigger guard. Verified portal feedback is append-only and cannot mutate project truth.';
COMMENT ON FUNCTION roomscan.portal_require_active_session_v1(bytea, timestamptz) IS
  'Slice 6 internal portal-session guard that delegates to per-request live authorization.';
-- These two named internal guards are defined after the migration-wide
-- function revocation above. PostgreSQL grants PUBLIC EXECUTE by default at
-- creation time, so revoke it explicitly rather than exposing guard seams to
-- unrelated service runtimes.
REVOKE ALL ON FUNCTION roomscan.publication_feedback_immutable_guard_v1(),
  roomscan.portal_require_active_session_v1(bytea, timestamptz)
  FROM PUBLIC;
DROP TRIGGER publication_feedback_immutable ON roomscan.publication_feedback;
CREATE TRIGGER publication_feedback_immutable
BEFORE UPDATE OR DELETE ON roomscan.publication_feedback
FOR EACH ROW EXECUTE FUNCTION roomscan.publication_feedback_immutable_guard_v1();

-- Correction gate: the API can transition an approved allocation into the
-- validation queue, but it never receives or supplies an object version.  The
-- worker reads the isolated quarantine object only after targetless claim and
-- atomically binds that exact provider version under its validation lease.
SET ROLE roomscan_owner;

CREATE FUNCTION roomscan.publication_complete_v2(
  requested_credential_kind text,
  requested_credential_hash bytea,
  authoritative_time timestamptz,
  requested_allocation_public_id text,
  requested_archive_digest bytea,
  requested_archive_manifest_digest bytea,
  requested_archive_bytes bigint
)
RETURNS TABLE (status text, allocation_public_id text)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE allocation roomscan.publication_allocations%ROWTYPE;
DECLARE context_row record;
BEGIN
  IF requested_credential_kind IS NULL OR requested_credential_hash IS NULL
    OR authoritative_time IS NULL OR requested_allocation_public_id IS NULL
    OR requested_archive_digest IS NULL OR requested_archive_manifest_digest IS NULL
    OR requested_archive_bytes IS NULL
    OR octet_length(requested_credential_hash) <> 32
    OR octet_length(requested_archive_digest) <> 32
    OR octet_length(requested_archive_manifest_digest) <> 32
    OR requested_archive_bytes <= 0 OR requested_archive_bytes > 805306368 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_COMPLETION';
  END IF;
  SELECT candidate.* INTO allocation
  FROM roomscan.publication_allocations AS candidate
  WHERE candidate.allocation_public_id = requested_allocation_public_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_ALLOCATION_NOT_FOUND';
  END IF;
  SELECT context.* INTO context_row
  FROM roomscan.publication_resolve_api_access_v1(
    requested_credential_kind, requested_credential_hash, authoritative_time,
    allocation.workspace_id, 'publication.create'
  ) AS context;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PUBLICATION_AUTHORIZATION_REQUIRED';
  END IF;
  IF allocation.hosted_global_version IS DISTINCT FROM context_row.hosted_global_version
    OR allocation.hosted_workspace_version IS DISTINCT FROM context_row.hosted_workspace_version
    OR allocation.publication_global_version IS DISTINCT FROM context_row.publication_global_version
    OR allocation.publication_workspace_version IS DISTINCT FROM context_row.publication_workspace_version
    OR allocation.quota_policy_version IS DISTINCT FROM context_row.quota_policy_version THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PUBLICATION_GRANT_REJECTED';
  END IF;
  IF allocation.created_by_principal_id IS DISTINCT FROM context_row.principal_id THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PUBLICATION_ALLOCATION_OWNER_REQUIRED';
  END IF;
  IF allocation.archive_digest IS DISTINCT FROM requested_archive_digest
    OR allocation.archive_manifest_digest IS DISTINCT FROM requested_archive_manifest_digest
    OR allocation.archive_bytes IS DISTINCT FROM requested_archive_bytes THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_ARCHIVE_BINDING_MISMATCH';
  END IF;
  IF allocation.state = 'validation_pending' THEN
    RETURN QUERY SELECT 'existing'::text, allocation.allocation_public_id;
    RETURN;
  END IF;
  IF allocation.state <> 'allocated' OR allocation.allocation_expires_at <= authoritative_time THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_ALLOCATION_EXPIRED';
  END IF;
  UPDATE roomscan.publication_allocations AS target
  SET state = 'validation_pending', updated_at = authoritative_time
  WHERE target.workspace_id = allocation.workspace_id
    AND target.allocation_id = allocation.allocation_id
    AND target.state = 'allocated'
    AND target.quarantine_version IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_ALLOCATION_EXPIRED';
  END IF;
  INSERT INTO roomscan.publication_jobs (
    workspace_id, job_id, allocation_id, state, created_at, updated_at
  ) VALUES (
    allocation.workspace_id, gen_random_uuid(), allocation.allocation_id,
    'pending', authoritative_time, authoritative_time
  );
  RETURN QUERY SELECT 'validation_pending'::text, allocation.allocation_public_id;
END
$function$;

CREATE FUNCTION roomscan.publication_bind_quarantine_version_v1(
  requested_allocation_id uuid,
  requested_lease_id text,
  authoritative_time timestamptz,
  requested_quarantine_version text
)
RETURNS TABLE (
  status text,
  allocation_public_id text,
  quarantine_key text,
  quarantine_version text,
  archive_digest bytea,
  archive_manifest_digest bytea,
  archive_bytes bigint
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE allocation roomscan.publication_allocations%ROWTYPE;
DECLARE job_row roomscan.publication_jobs%ROWTYPE;
BEGIN
  PERFORM roomscan.publication_require_worker_v1();
  IF requested_allocation_id IS NULL OR requested_lease_id IS NULL
    OR authoritative_time IS NULL OR requested_quarantine_version IS NULL
    OR length(requested_lease_id) NOT BETWEEN 20 AND 137
    OR requested_lease_id !~ '^pwl_[A-Za-z0-9_-]{16,128}$'
    OR length(requested_quarantine_version) NOT BETWEEN 1 AND 1024
    OR requested_quarantine_version ~ '[[:cntrl:]]' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_QUARANTINE_BIND';
  END IF;
  SELECT candidate.* INTO allocation
  FROM roomscan.publication_allocations AS candidate
  WHERE candidate.allocation_id = requested_allocation_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_ALLOCATION_NOT_FOUND';
  END IF;
  SELECT candidate.* INTO job_row
  FROM roomscan.publication_jobs AS candidate
  WHERE candidate.workspace_id = allocation.workspace_id
    AND candidate.allocation_id = allocation.allocation_id
  FOR UPDATE;
  IF NOT FOUND OR allocation.state <> 'validating'
    OR job_row.state <> 'claimed'
    OR job_row.lease_id IS DISTINCT FROM requested_lease_id
    OR job_row.lease_expires_at <= authoritative_time THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_VALIDATION_LEASE_REQUIRED';
  END IF;
  IF allocation.allocation_expires_at <= authoritative_time THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_ALLOCATION_EXPIRED';
  END IF;
  -- Recheck the same live epochs and immutable source/quota bindings that
  -- finalization will later require.  Claim-time success is never enough:
  -- a kill, source head change, or policy transition between S3 HeadObject and
  -- exact-version binding must leave the allocation unbound.
  PERFORM roomscan.publication_require_live_grant_v1(
    allocation.workspace_id, 'publication.create',
    allocation.hosted_global_version, allocation.hosted_workspace_version,
    allocation.publication_global_version, allocation.publication_workspace_version
  );
  PERFORM roomscan.publication_check_quota_policy_v1(
    allocation.workspace_id, allocation.quota_policy_version
  );
  PERFORM roomscan.publication_require_source_binding_v1(
    allocation.workspace_id, allocation.project_id, allocation.source_revision_id,
    allocation.source_revision_public_id, allocation.source_revision_digest,
    allocation.source_manifest_digest
  );
  IF allocation.quarantine_version IS NOT NULL THEN
    IF allocation.quarantine_version IS DISTINCT FROM requested_quarantine_version THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_QUARANTINE_VERSION_MISMATCH';
    END IF;
    RETURN QUERY SELECT 'existing'::text, allocation.allocation_public_id,
      allocation.quarantine_key, allocation.quarantine_version,
      allocation.archive_digest, allocation.archive_manifest_digest,
      allocation.archive_bytes;
    RETURN;
  END IF;
  UPDATE roomscan.publication_allocations AS target
  SET quarantine_version = requested_quarantine_version,
      updated_at = authoritative_time
  WHERE target.workspace_id = allocation.workspace_id
    AND target.allocation_id = allocation.allocation_id
    AND target.state = 'validating'
    AND target.quarantine_version IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLICATION_QUARANTINE_VERSION_MISMATCH';
  END IF;
  RETURN QUERY SELECT 'bound'::text, allocation.allocation_public_id,
    allocation.quarantine_key, requested_quarantine_version,
    allocation.archive_digest, allocation.archive_manifest_digest,
    allocation.archive_bytes;
END
$function$;

RESET ROLE;

ALTER FUNCTION roomscan.publication_complete_v2(
  text, bytea, timestamptz, text, bytea, bytea, bigint
) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.publication_bind_quarantine_version_v1(
  uuid, text, timestamptz, text
) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.publication_upsert_property_v2(
  text, bytea, timestamptz, text, bigint, bytea, text, jsonb
) OWNER TO roomscan_policy;
REVOKE ALL ON FUNCTION roomscan.publication_complete_v2(
  text, bytea, timestamptz, text, bytea, bytea, bigint
), roomscan.publication_bind_quarantine_version_v1(uuid, text, timestamptz, text),
  roomscan.publication_upsert_property_v2(
    text, bytea, timestamptz, text, bigint, bytea, text, jsonb
  )
  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION roomscan.publication_complete_v1(
  text, bytea, timestamptz, text, bytea, bytea, bigint, text
) FROM roomscan_api_runtime;
REVOKE EXECUTE ON FUNCTION roomscan.publication_upsert_property_v1(
  text, bytea, timestamptz, text, bigint, text, jsonb
) FROM roomscan_api_runtime;
GRANT EXECUTE ON FUNCTION roomscan.publication_complete_v2(
  text, bytea, timestamptz, text, bytea, bytea, bigint
) TO roomscan_api_runtime;
GRANT EXECUTE ON FUNCTION roomscan.publication_upsert_property_v2(
  text, bytea, timestamptz, text, bigint, bytea, text, jsonb
) TO roomscan_api_runtime;
GRANT EXECUTE ON FUNCTION roomscan.publication_bind_quarantine_version_v1(
  uuid, text, timestamptz, text
) TO roomscan_publication_worker;

COMMENT ON FUNCTION roomscan.publication_complete_v2(
  text, bytea, timestamptz, text, bytea, bytea, bigint
) IS 'Slice 6 targetless API completion reducer. It queues validated archive identity but accepts no storage key/version; the worker captures and binds the quarantine version under its lease.';
COMMENT ON FUNCTION roomscan.publication_bind_quarantine_version_v1(
  uuid, text, timestamptz, text
) IS 'Slice 6 worker-only quarantine-version binding reducer. It atomically closes the claimed validation lease over the exact provider object version before archive validation.';
COMMENT ON FUNCTION roomscan.publication_upsert_property_v2(
  text, bytea, timestamptz, text, bigint, bytea, text, jsonb
) IS 'Slice 6 crash-safe property curation reducer. Create uses only a server-HMAC idempotency digest and generates prop_ once; exact retries return the existing draft without a version bump.';

-- Feedback issue throttling deliberately stores the already-present session
-- risk digest rather than an address, email, bearer, referrer, or plaintext
-- client identifier.  It bounds retry work for one live link generation
-- without creating a cross-link visitor profile.
SET ROLE roomscan_owner;

CREATE TABLE roomscan.portal_feedback_request_throttles (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE RESTRICT,
  link_id uuid NOT NULL,
  link_generation bigint NOT NULL CHECK (link_generation > 0),
  network_risk_digest bytea NOT NULL CHECK (octet_length(network_risk_digest) = 32),
  window_started_at timestamptz NOT NULL,
  issued_count integer NOT NULL CHECK (issued_count BETWEEN 1 AND 3),
  cooldown_until timestamptz,
  updated_at timestamptz NOT NULL,
  PRIMARY KEY (workspace_id, link_id, link_generation, network_risk_digest),
  FOREIGN KEY (workspace_id, link_id)
    REFERENCES roomscan.publication_links(workspace_id, link_id) ON DELETE RESTRICT,
  CHECK (cooldown_until IS NULL OR cooldown_until > window_started_at)
);

CREATE INDEX portal_feedback_request_throttles_expiry
  ON roomscan.portal_feedback_request_throttles (cooldown_until, updated_at);

-- A server-HMAC request identity makes a lost response replay safe without
-- retaining an address, plaintext code, portal bearer, or browser payload.
ALTER TABLE roomscan.portal_feedback_challenges
  ADD COLUMN feedback_request_digest bytea CHECK (
    feedback_request_digest IS NULL OR octet_length(feedback_request_digest) = 32
  );
CREATE UNIQUE INDEX portal_feedback_challenges_request_idempotency
  ON roomscan.portal_feedback_challenges (
    workspace_id, session_id, feedback_request_digest
  ) WHERE feedback_request_digest IS NOT NULL;

ALTER TABLE roomscan.portal_feedback_request_throttles ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.portal_feedback_request_throttles FORCE ROW LEVEL SECURITY;
CREATE POLICY portal_feedback_request_throttles_tenant_isolation
  ON roomscan.portal_feedback_request_throttles
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));

RESET ROLE;

REVOKE ALL ON roomscan.portal_feedback_request_throttles,
  roomscan.portal_feedback_delivery_outbox
  FROM PUBLIC, roomscan_api_runtime, roomscan_portal_runtime,
    roomscan_publication_worker, roomscan_email_delivery_runtime;
GRANT SELECT, INSERT, UPDATE ON roomscan.portal_feedback_request_throttles,
  roomscan.portal_feedback_delivery_outbox
  TO roomscan_policy;

-- v3 is intentionally additive: v2 returned a persistence row, which made it
-- too easy for an email adapter to accidentally receive portal/session/link
-- scope.  The v3 routines project only an envelope and its delivery lease.
SET ROLE roomscan_owner;

CREATE FUNCTION roomscan.portal_request_feedback_verification_v3(
  requested_session_hash bytea,
  authoritative_time timestamptz,
  requested_challenge_hash bytea,
  requested_verification_token_hash bytea,
  requested_verified_email_digest bytea,
  requested_key_id text,
  requested_iv bytea,
  requested_ciphertext bytea,
  requested_authentication_tag bytea,
  requested_feedback_request_digest bytea
)
RETURNS TABLE (
  status text,
  challenge_id uuid,
  expires_at timestamptz,
  retry_after timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE throttle roomscan.portal_feedback_request_throttles%ROWTYPE;
DECLARE new_challenge_id uuid := gen_random_uuid();
DECLARE new_delivery_id text := 'pfd_' || replace(gen_random_uuid()::text, '-', '');
DECLARE challenge_expiry timestamptz;
DECLARE cooldown_expiry timestamptz;
DECLARE existing_challenge roomscan.portal_feedback_challenges%ROWTYPE;
BEGIN
  PERFORM roomscan.publication_require_portal_v1();
  IF requested_session_hash IS NULL OR authoritative_time IS NULL
    OR requested_challenge_hash IS NULL OR requested_verification_token_hash IS NULL
    OR requested_verified_email_digest IS NULL OR requested_key_id IS NULL
    OR requested_iv IS NULL OR requested_ciphertext IS NULL
    OR requested_authentication_tag IS NULL OR requested_feedback_request_digest IS NULL
    OR octet_length(requested_session_hash) <> 32
    OR octet_length(requested_challenge_hash) <> 32
    OR octet_length(requested_verification_token_hash) <> 32
    OR octet_length(requested_verified_email_digest) <> 32
    OR octet_length(requested_feedback_request_digest) <> 32
    OR length(requested_key_id) NOT BETWEEN 1 AND 64
    OR requested_key_id !~ '^[A-Za-z0-9._-]+$'
    OR octet_length(requested_iv) <> 12
    OR octet_length(requested_ciphertext) NOT BETWEEN 1 AND 4096
    OR octet_length(requested_authentication_tag) <> 16 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_FEEDBACK_VERIFICATION_REQUEST';
  END IF;
  SELECT context.* INTO context_row
  FROM roomscan.portal_session_context_v1(requested_session_hash, authoritative_time) AS context;
  IF context_row.feedback_enabled IS DISTINCT FROM true THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PORTAL_FEEDBACK_DISABLED';
  END IF;

  -- A retry after a lost HTTP response never creates another envelope or
  -- sends another message.  New random delivery/code bytes are intentionally
  -- ignored on this semantic replay; changed verified-email scope is not.
  SELECT challenge.* INTO existing_challenge
  FROM roomscan.portal_feedback_challenges AS challenge
  WHERE challenge.workspace_id = context_row.workspace_id
    AND challenge.session_id = context_row.session_id
    AND challenge.feedback_request_digest = requested_feedback_request_digest
  FOR UPDATE;
  IF FOUND THEN
    IF existing_challenge.link_id IS DISTINCT FROM context_row.link_id
      OR existing_challenge.link_generation IS DISTINCT FROM context_row.link_generation
      OR existing_challenge.snapshot_id IS DISTINCT FROM context_row.snapshot_id
      OR existing_challenge.verified_email_digest IS DISTINCT FROM requested_verified_email_digest THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'FEEDBACK_REQUEST_IDEMPOTENCY_CONFLICT';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM roomscan.portal_feedback_delivery_outbox AS delivery
      WHERE delivery.workspace_id = existing_challenge.workspace_id
        AND delivery.challenge_id = existing_challenge.challenge_id
    ) THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'FEEDBACK_DELIVERY_INTEGRITY_REQUIRED';
    END IF;
    RETURN QUERY SELECT 'existing'::text, existing_challenge.challenge_id,
      existing_challenge.expires_at, NULL::timestamptz;
    RETURN;
  END IF;

  -- Serialise only this opaque link-generation/risk bucket.  A requester can
  -- never race three parallel issue calls into more than the bounded limit.
  PERFORM pg_advisory_xact_lock(hashtextextended(
    context_row.link_id::text || ':' || context_row.link_generation::text
      || ':' || encode(context_row.network_risk_digest, 'hex'), 0
  ));
  SELECT candidate.* INTO throttle
  FROM roomscan.portal_feedback_request_throttles AS candidate
  WHERE candidate.workspace_id = context_row.workspace_id
    AND candidate.link_id = context_row.link_id
    AND candidate.link_generation = context_row.link_generation
    AND candidate.network_risk_digest = context_row.network_risk_digest
  FOR UPDATE;
  IF FOUND AND throttle.cooldown_until IS NOT NULL
    AND throttle.cooldown_until > authoritative_time THEN
    PERFORM roomscan.publication_append_access_event_v1(
      context_row.workspace_id, context_row.link_id, context_row.link_generation,
      context_row.snapshot_id, 'feedback_verification', 'cooldown', authoritative_time,
      context_row.client_family, context_row.network_risk_digest
    );
    RETURN QUERY SELECT 'cooldown'::text, NULL::uuid, NULL::timestamptz,
      throttle.cooldown_until;
    RETURN;
  END IF;
  IF NOT FOUND THEN
    INSERT INTO roomscan.portal_feedback_request_throttles (
      workspace_id, link_id, link_generation, network_risk_digest,
      window_started_at, issued_count, cooldown_until, updated_at
    ) VALUES (
      context_row.workspace_id, context_row.link_id, context_row.link_generation,
      context_row.network_risk_digest, authoritative_time, 1, NULL, authoritative_time
    );
  ELSIF throttle.window_started_at <= authoritative_time - interval '15 minutes' THEN
    UPDATE roomscan.portal_feedback_request_throttles AS target
    SET window_started_at = authoritative_time, issued_count = 1,
        cooldown_until = NULL, updated_at = authoritative_time
    WHERE target.workspace_id = throttle.workspace_id
      AND target.link_id = throttle.link_id
      AND target.link_generation = throttle.link_generation
      AND target.network_risk_digest = throttle.network_risk_digest;
  ELSIF throttle.issued_count >= 3 THEN
    cooldown_expiry := authoritative_time + interval '15 minutes';
    UPDATE roomscan.portal_feedback_request_throttles AS target
    SET cooldown_until = cooldown_expiry, updated_at = authoritative_time
    WHERE target.workspace_id = throttle.workspace_id
      AND target.link_id = throttle.link_id
      AND target.link_generation = throttle.link_generation
      AND target.network_risk_digest = throttle.network_risk_digest;
    PERFORM roomscan.publication_append_access_event_v1(
      context_row.workspace_id, context_row.link_id, context_row.link_generation,
      context_row.snapshot_id, 'feedback_verification', 'cooldown', authoritative_time,
      context_row.client_family, context_row.network_risk_digest
    );
    RETURN QUERY SELECT 'cooldown'::text, NULL::uuid, NULL::timestamptz,
      cooldown_expiry;
    RETURN;
  ELSE
    UPDATE roomscan.portal_feedback_request_throttles AS target
    SET issued_count = target.issued_count + 1,
        cooldown_until = NULL, updated_at = authoritative_time
    WHERE target.workspace_id = throttle.workspace_id
      AND target.link_id = throttle.link_id
      AND target.link_generation = throttle.link_generation
      AND target.network_risk_digest = throttle.network_risk_digest;
  END IF;

  challenge_expiry := authoritative_time + interval '15 minutes';
  INSERT INTO roomscan.portal_feedback_challenges (
    workspace_id, challenge_id, challenge_hash, verification_token_hash,
    session_id, link_id, link_generation, snapshot_id, verified_email_digest,
    feedback_request_digest, expires_at, created_at
  ) VALUES (
    context_row.workspace_id, new_challenge_id, requested_challenge_hash,
    requested_verification_token_hash, context_row.session_id, context_row.link_id,
    context_row.link_generation, context_row.snapshot_id,
    requested_verified_email_digest, requested_feedback_request_digest,
    challenge_expiry, authoritative_time
  );
  INSERT INTO roomscan.portal_feedback_delivery_outbox (
    workspace_id, delivery_id, challenge_id, session_id, link_id,
    link_generation, snapshot_id, envelope_version, key_id, iv, ciphertext,
    authentication_tag, created_at, expires_at
  ) VALUES (
    context_row.workspace_id, new_delivery_id, new_challenge_id,
    context_row.session_id, context_row.link_id, context_row.link_generation,
    context_row.snapshot_id, 'aes-256-gcm-v1', requested_key_id, requested_iv,
    requested_ciphertext, requested_authentication_tag, authoritative_time,
    challenge_expiry
  );
  PERFORM roomscan.publication_append_access_event_v1(
    context_row.workspace_id, context_row.link_id, context_row.link_generation,
    context_row.snapshot_id, 'feedback_verification', 'allowed', authoritative_time,
    context_row.client_family, context_row.network_risk_digest
  );
  RETURN QUERY SELECT 'issued'::text, new_challenge_id, challenge_expiry,
    NULL::timestamptz;
END
$function$;

CREATE FUNCTION roomscan.claim_next_feedback_delivery_v3(
  requested_lease_id text,
  claimed_at_time timestamptz,
  requested_lease_expires_at timestamptz
)
RETURNS TABLE (
  status text,
  delivery_id text,
  lease_id text,
  lease_expires_at timestamptz,
  envelope_version text,
  key_id text,
  iv bytea,
  ciphertext bytea,
  authentication_tag bytea,
  expires_at timestamptz,
  delivery_attempts integer
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE candidate roomscan.portal_feedback_delivery_outbox%ROWTYPE;
BEGIN
  PERFORM roomscan.publication_require_feedback_delivery_runtime_v2();
  IF requested_lease_id IS NULL OR claimed_at_time IS NULL
    OR requested_lease_expires_at IS NULL
    OR length(requested_lease_id) NOT BETWEEN 1 AND 128
    OR requested_lease_id !~ '^[A-Za-z0-9_-]+$'
    OR requested_lease_expires_at <= claimed_at_time
    OR requested_lease_expires_at > claimed_at_time + interval '15 minutes' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_FEEDBACK_DELIVERY_LEASE';
  END IF;
  UPDATE roomscan.portal_feedback_delivery_outbox AS delivery
  SET state = 'expired', lease_id = NULL, lease_expires_at = NULL,
      cancelled_at = claimed_at_time, cancellation_reason = 'expired'
  WHERE delivery.state IN ('pending', 'leased')
    AND delivery.expires_at <= claimed_at_time;
  UPDATE roomscan.portal_feedback_delivery_outbox AS delivery
  SET state = 'cancelled', lease_id = NULL, lease_expires_at = NULL,
      cancelled_at = claimed_at_time, cancellation_reason = 'disabled'
  WHERE delivery.state IN ('pending', 'leased')
    AND delivery.expires_at > claimed_at_time
    AND NOT roomscan.publication_feedback_delivery_live_v2(
      delivery.workspace_id, delivery.delivery_id, claimed_at_time
    );
  SELECT delivery.* INTO candidate
  FROM roomscan.portal_feedback_delivery_outbox AS delivery
  WHERE delivery.state IN ('pending', 'leased')
    AND delivery.expires_at > claimed_at_time
    AND (delivery.state = 'pending' OR delivery.lease_expires_at <= claimed_at_time)
    AND roomscan.publication_feedback_delivery_live_v2(
      delivery.workspace_id, delivery.delivery_id, claimed_at_time
    )
  ORDER BY delivery.created_at, delivery.delivery_id
  FOR UPDATE OF delivery SKIP LOCKED
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN;
  END IF;
  UPDATE roomscan.portal_feedback_delivery_outbox AS delivery
  SET state = 'leased', lease_id = requested_lease_id,
      lease_expires_at = LEAST(requested_lease_expires_at, delivery.expires_at),
      delivery_attempts = delivery.delivery_attempts + 1
  WHERE delivery.workspace_id = candidate.workspace_id
    AND delivery.delivery_id = candidate.delivery_id
    AND delivery.state IN ('pending', 'leased')
    AND (delivery.state = 'pending' OR delivery.lease_expires_at <= claimed_at_time)
  RETURNING 'leased'::text, delivery.delivery_id, delivery.lease_id,
    delivery.lease_expires_at, delivery.envelope_version, delivery.key_id,
    delivery.iv, delivery.ciphertext, delivery.authentication_tag,
    delivery.expires_at, delivery.delivery_attempts
  INTO status, delivery_id, lease_id, lease_expires_at, envelope_version,
    key_id, iv, ciphertext, authentication_tag, expires_at, delivery_attempts;
  RETURN NEXT;
END
$function$;

CREATE FUNCTION roomscan.validate_feedback_delivery_v3(
  requested_delivery_id text,
  requested_lease_id text,
  checked_at_time timestamptz
)
RETURNS TABLE (
  status text,
  delivery_id text,
  lease_id text,
  lease_expires_at timestamptz,
  envelope_version text,
  key_id text,
  iv bytea,
  ciphertext bytea,
  authentication_tag bytea,
  expires_at timestamptz,
  delivery_attempts integer
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE delivery roomscan.portal_feedback_delivery_outbox%ROWTYPE;
BEGIN
  PERFORM roomscan.publication_require_feedback_delivery_runtime_v2();
  IF requested_delivery_id IS NULL OR requested_lease_id IS NULL
    OR checked_at_time IS NULL
    OR requested_delivery_id !~ '^pfd_[A-Za-z0-9_-]{16,128}$'
    OR length(requested_lease_id) NOT BETWEEN 1 AND 128
    OR requested_lease_id !~ '^[A-Za-z0-9_-]+$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_FEEDBACK_DELIVERY_LEASE';
  END IF;
  SELECT candidate.* INTO delivery
  FROM roomscan.portal_feedback_delivery_outbox AS candidate
  WHERE candidate.delivery_id = requested_delivery_id
  FOR UPDATE;
  IF NOT FOUND OR delivery.state <> 'leased'
    OR delivery.lease_id IS DISTINCT FROM requested_lease_id
    OR delivery.lease_expires_at IS NULL
    OR delivery.lease_expires_at <= checked_at_time THEN
    RETURN;
  END IF;
  IF delivery.expires_at <= checked_at_time THEN
    UPDATE roomscan.portal_feedback_delivery_outbox AS target
    SET state = 'expired', lease_id = NULL, lease_expires_at = NULL,
        cancelled_at = checked_at_time, cancellation_reason = 'expired'
    WHERE target.workspace_id = delivery.workspace_id
      AND target.delivery_id = delivery.delivery_id
      AND target.state = 'leased'
      AND target.lease_id = requested_lease_id;
    RETURN QUERY SELECT 'expired'::text, delivery.delivery_id, NULL::text,
      NULL::timestamptz, NULL::text, NULL::text, NULL::bytea, NULL::bytea,
      NULL::bytea, delivery.expires_at, delivery.delivery_attempts;
    RETURN;
  END IF;
  IF NOT roomscan.publication_feedback_delivery_live_v2(
    delivery.workspace_id, delivery.delivery_id, checked_at_time
  ) THEN
    UPDATE roomscan.portal_feedback_delivery_outbox AS target
    SET state = 'cancelled', lease_id = NULL, lease_expires_at = NULL,
        cancelled_at = checked_at_time, cancellation_reason = 'disabled'
    WHERE target.workspace_id = delivery.workspace_id
      AND target.delivery_id = delivery.delivery_id
      AND target.state = 'leased'
      AND target.lease_id = requested_lease_id;
    RETURN QUERY SELECT 'cancelled'::text, delivery.delivery_id, NULL::text,
      NULL::timestamptz, NULL::text, NULL::text, NULL::bytea, NULL::bytea,
      NULL::bytea, delivery.expires_at, delivery.delivery_attempts;
    RETURN;
  END IF;
  RETURN QUERY SELECT 'send'::text, delivery.delivery_id, delivery.lease_id,
    delivery.lease_expires_at, delivery.envelope_version, delivery.key_id,
    delivery.iv, delivery.ciphertext, delivery.authentication_tag,
    delivery.expires_at, delivery.delivery_attempts;
END
$function$;

CREATE FUNCTION roomscan.complete_feedback_delivery_v3(
  requested_delivery_id text,
  requested_lease_id text,
  delivered_at_time timestamptz
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE changed integer;
BEGIN
  PERFORM roomscan.publication_require_feedback_delivery_runtime_v2();
  IF requested_delivery_id IS NULL OR requested_lease_id IS NULL
    OR delivered_at_time IS NULL
    OR requested_delivery_id !~ '^pfd_[A-Za-z0-9_-]{16,128}$'
    OR length(requested_lease_id) NOT BETWEEN 1 AND 128
    OR requested_lease_id !~ '^[A-Za-z0-9_-]+$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_FEEDBACK_DELIVERY_LEASE';
  END IF;
  UPDATE roomscan.portal_feedback_delivery_outbox AS delivery
  SET state = 'delivered', lease_id = NULL, lease_expires_at = NULL,
      delivered_at = delivered_at_time
  WHERE delivery.delivery_id = requested_delivery_id
    AND delivery.state = 'leased'
    AND delivery.lease_id = requested_lease_id
    AND delivery.lease_expires_at > delivered_at_time
    AND delivery.expires_at > delivered_at_time
    AND roomscan.publication_feedback_delivery_live_v2(
      delivery.workspace_id, delivery.delivery_id, delivered_at_time
    );
  GET DIAGNOSTICS changed = ROW_COUNT;
  RETURN changed = 1;
END
$function$;

CREATE FUNCTION roomscan.cancel_feedback_delivery_v3(
  requested_delivery_id text,
  requested_lease_id text,
  requested_reason text,
  cancelled_at_time timestamptz
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE changed integer;
BEGIN
  PERFORM roomscan.publication_require_feedback_delivery_runtime_v2();
  IF requested_delivery_id IS NULL OR requested_lease_id IS NULL
    OR requested_reason IS NULL OR cancelled_at_time IS NULL
    OR requested_delivery_id !~ '^pfd_[A-Za-z0-9_-]{16,128}$'
    OR length(requested_lease_id) NOT BETWEEN 1 AND 128
    OR requested_lease_id !~ '^[A-Za-z0-9_-]+$'
    OR requested_reason NOT IN (
      'expired', 'revoked', 'killed', 'disabled', 'unknown_key',
      'tampered_envelope'
    ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_FEEDBACK_DELIVERY_CANCEL';
  END IF;
  UPDATE roomscan.portal_feedback_delivery_outbox AS delivery
  SET state = CASE WHEN requested_reason = 'expired' THEN 'expired' ELSE 'cancelled' END,
      lease_id = NULL, lease_expires_at = NULL, cancelled_at = cancelled_at_time,
      cancellation_reason = requested_reason
  WHERE delivery.delivery_id = requested_delivery_id
    AND delivery.state = 'leased'
    AND delivery.lease_id = requested_lease_id;
  GET DIAGNOSTICS changed = ROW_COUNT;
  RETURN changed = 1;
END
$function$;

CREATE FUNCTION roomscan.release_feedback_delivery_v3(
  requested_delivery_id text,
  requested_lease_id text,
  released_at_time timestamptz
)
RETURNS TABLE (status text)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE delivery roomscan.portal_feedback_delivery_outbox%ROWTYPE;
BEGIN
  PERFORM roomscan.publication_require_feedback_delivery_runtime_v2();
  IF requested_delivery_id IS NULL OR requested_lease_id IS NULL
    OR released_at_time IS NULL
    OR requested_delivery_id !~ '^pfd_[A-Za-z0-9_-]{16,128}$'
    OR length(requested_lease_id) NOT BETWEEN 1 AND 128
    OR requested_lease_id !~ '^[A-Za-z0-9_-]+$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_FEEDBACK_DELIVERY_LEASE';
  END IF;
  SELECT candidate.* INTO delivery
  FROM roomscan.portal_feedback_delivery_outbox AS candidate
  WHERE candidate.delivery_id = requested_delivery_id
    AND candidate.state = 'leased'
    AND candidate.lease_id = requested_lease_id
  FOR UPDATE;
  IF NOT FOUND OR delivery.lease_expires_at IS NULL
    OR delivery.lease_expires_at <= released_at_time THEN
    RETURN QUERY SELECT 'unavailable'::text;
    RETURN;
  END IF;
  IF delivery.expires_at <= released_at_time THEN
    UPDATE roomscan.portal_feedback_delivery_outbox AS target
    SET state = 'expired', lease_id = NULL, lease_expires_at = NULL,
        cancelled_at = released_at_time, cancellation_reason = 'expired'
    WHERE target.workspace_id = delivery.workspace_id
      AND target.delivery_id = delivery.delivery_id
      AND target.state = 'leased' AND target.lease_id = requested_lease_id;
    RETURN QUERY SELECT 'expired'::text;
    RETURN;
  END IF;
  UPDATE roomscan.portal_feedback_delivery_outbox AS target
  SET state = 'pending', lease_id = NULL, lease_expires_at = NULL
  WHERE target.workspace_id = delivery.workspace_id
    AND target.delivery_id = delivery.delivery_id
    AND target.state = 'leased' AND target.lease_id = requested_lease_id;
  RETURN QUERY SELECT CASE WHEN FOUND THEN 'released' ELSE 'unavailable' END::text;
END
$function$;

RESET ROLE;

ALTER FUNCTION roomscan.publication_require_feedback_delivery_runtime_v2()
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.portal_request_feedback_verification_v3(
  bytea, timestamptz, bytea, bytea, bytea, text, bytea, bytea, bytea, bytea
) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.portal_request_feedback_verification_v2(
  bytea, timestamptz, bytea, bytea, bytea, text, bytea, bytea, bytea
) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.claim_next_feedback_delivery_v2(text, timestamptz, timestamptz)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.claim_feedback_delivery_v2(text, timestamptz, timestamptz)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.validate_feedback_delivery_v2(text, text, timestamptz)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.complete_feedback_delivery_v2(text, text, timestamptz)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.cancel_feedback_delivery_v2(text, text, text, timestamptz)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.release_feedback_delivery_v2(text, text, timestamptz)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.claim_next_feedback_delivery_v3(text, timestamptz, timestamptz)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.validate_feedback_delivery_v3(text, text, timestamptz)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.complete_feedback_delivery_v3(text, text, timestamptz)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.cancel_feedback_delivery_v3(text, text, text, timestamptz)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.release_feedback_delivery_v3(text, text, timestamptz)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.publication_feedback_delivery_live_v2(uuid, text, timestamptz)
  OWNER TO roomscan_policy;

REVOKE ALL ON FUNCTION roomscan.portal_request_feedback_verification_v1(
  bytea, timestamptz, bytea, bytea, bytea
), roomscan.portal_request_feedback_verification_v2(
  bytea, timestamptz, bytea, bytea, bytea, text, bytea, bytea, bytea
), roomscan.portal_request_feedback_verification_v3(
  bytea, timestamptz, bytea, bytea, bytea, text, bytea, bytea, bytea, bytea
), roomscan.claim_next_feedback_delivery_v2(text, timestamptz, timestamptz),
  roomscan.claim_feedback_delivery_v2(text, timestamptz, timestamptz),
  roomscan.validate_feedback_delivery_v2(text, text, timestamptz),
  roomscan.complete_feedback_delivery_v2(text, text, timestamptz),
  roomscan.cancel_feedback_delivery_v2(text, text, text, timestamptz),
  roomscan.release_feedback_delivery_v2(text, text, timestamptz),
  roomscan.claim_next_feedback_delivery_v3(text, timestamptz, timestamptz),
  roomscan.validate_feedback_delivery_v3(text, text, timestamptz),
  roomscan.complete_feedback_delivery_v3(text, text, timestamptz),
  roomscan.cancel_feedback_delivery_v3(text, text, text, timestamptz),
  roomscan.release_feedback_delivery_v3(text, text, timestamptz),
  roomscan.publication_feedback_delivery_live_v2(uuid, text, timestamptz),
  roomscan.publication_require_feedback_delivery_runtime_v2()
  FROM PUBLIC, roomscan_api_runtime, roomscan_portal_runtime,
    roomscan_publication_worker, roomscan_email_delivery_runtime;
GRANT EXECUTE ON FUNCTION roomscan.portal_request_feedback_verification_v3(
  bytea, timestamptz, bytea, bytea, bytea, text, bytea, bytea, bytea, bytea
) TO roomscan_portal_runtime;
GRANT EXECUTE ON FUNCTION roomscan.claim_next_feedback_delivery_v3(text, timestamptz, timestamptz),
  roomscan.validate_feedback_delivery_v3(text, text, timestamptz),
  roomscan.complete_feedback_delivery_v3(text, text, timestamptz),
  roomscan.cancel_feedback_delivery_v3(text, text, text, timestamptz),
  roomscan.release_feedback_delivery_v3(text, text, timestamptz)
  TO roomscan_email_delivery_runtime;

COMMENT ON FUNCTION roomscan.portal_request_feedback_verification_v3(
  bytea, timestamptz, bytea, bytea, bytea, text, bytea, bytea, bytea, bytea
) IS 'Slice 6 portal-only verified-feedback issuer. It atomically writes one bounded encrypted delivery envelope, uses only a server-HMAC feedback request identity for lost-response replay, enforces three issues per opaque link-generation risk bucket per fifteen minutes, and returns no email, session, link, or envelope material.';
COMMENT ON FUNCTION roomscan.claim_next_feedback_delivery_v3(text, timestamptz, timestamptz)
  IS 'Slice 6 sealed email-runtime claim reducer. It projects only the leased encrypted envelope and no portal/session/link/snapshot or verified-email scope.';
COMMENT ON FUNCTION roomscan.validate_feedback_delivery_v3(text, text, timestamptz)
  IS 'Slice 6 sealed email-runtime pre-send guard. It rechecks expiry, revocation, kill switches, and exact link generation immediately before delivery.';

-- A separate additive professional projection keeps the original list wire
-- shape stable while giving the web shell one bounded, non-identifying
-- feedback status summary per link.  It never reads email digests, comments,
-- request identities, portal sessions, or delivery state into this response.
SET ROLE roomscan_owner;

CREATE INDEX publication_feedback_link_recent
  ON roomscan.publication_feedback (workspace_id, link_id, occurred_at DESC, feedback_id DESC);

CREATE FUNCTION roomscan.publication_list_links_v2(
  requested_credential_kind text,
  requested_credential_hash bytea,
  authoritative_time timestamptz,
  requested_snapshot_public_id text,
  requested_limit integer,
  requested_cursor text
)
RETURNS TABLE (
  link_public_id text,
  snapshot_public_id text,
  generation bigint,
  state text,
  expires_at timestamptz,
  pin_required boolean,
  ai_enabled boolean,
  feedback_enabled boolean,
  created_at timestamptz,
  updated_at timestamptz,
  feedback_count bigint,
  feedback_count_capped boolean,
  latest_feedback_kind text,
  latest_feedback_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE effective_limit integer;
BEGIN
  IF requested_snapshot_public_id IS NOT NULL
    AND requested_snapshot_public_id !~ '^snp_[A-Za-z0-9_-]{16,128}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLICATION_SNAPSHOT';
  END IF;
  IF requested_limit IS NOT NULL AND requested_limit NOT BETWEEN 1 AND 100
    OR (requested_cursor IS NOT NULL
      AND requested_cursor !~ '^lnk_[A-Za-z0-9_-]{16,128}$') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROFESSIONAL_READ_PAGE';
  END IF;
  effective_limit := COALESCE(requested_limit, 100);
  SELECT context.* INTO context_row
  FROM roomscan.professional_read_resolve_v1(
    requested_credential_kind, requested_credential_hash,
    authoritative_time, 'publication.record.read'
  ) AS context;
  RETURN QUERY
  SELECT link.public_id, snapshot.public_id, link.generation, link.state,
    link.expires_at, link.pin_salt IS NOT NULL, link.ai_enabled,
    link.feedback_enabled, link.created_at, link.updated_at,
    aggregate_row.feedback_count, aggregate_row.feedback_count_capped,
    aggregate_row.latest_feedback_kind, aggregate_row.latest_feedback_at
  FROM roomscan.publication_links AS link
  JOIN roomscan.publication_snapshots AS snapshot
    ON snapshot.workspace_id = link.workspace_id
    AND snapshot.snapshot_id = link.snapshot_id
  LEFT JOIN LATERAL (
    SELECT count(*)::bigint AS feedback_count,
      count(*) = 10000 AS feedback_count_capped,
      (array_agg(bounded.kind ORDER BY bounded.occurred_at DESC, bounded.feedback_id DESC))[1]
        AS latest_feedback_kind,
      max(bounded.occurred_at) AS latest_feedback_at
    FROM (
      SELECT feedback.feedback_id, feedback.kind, feedback.occurred_at
      FROM roomscan.publication_feedback AS feedback
      WHERE feedback.workspace_id = link.workspace_id
        AND feedback.link_id = link.link_id
      ORDER BY feedback.occurred_at DESC, feedback.feedback_id DESC
      LIMIT 10000
    ) AS bounded
  ) AS aggregate_row ON true
  WHERE link.workspace_id = context_row.workspace_id
    AND (requested_snapshot_public_id IS NULL OR snapshot.public_id = requested_snapshot_public_id)
    AND (requested_cursor IS NULL OR link.public_id > requested_cursor)
  ORDER BY link.public_id
  LIMIT effective_limit;
END
$function$;

RESET ROLE;
ALTER FUNCTION roomscan.publication_list_links_v2(text, bytea, timestamptz, text, integer, text)
  OWNER TO roomscan_policy;
REVOKE ALL ON FUNCTION roomscan.publication_list_links_v2(text, bytea, timestamptz, text, integer, text)
  FROM PUBLIC, roomscan_app, roomscan_portal_runtime, roomscan_publication_worker,
    roomscan_email_delivery_runtime;
GRANT EXECUTE ON FUNCTION roomscan.publication_list_links_v2(text, bytea, timestamptz, text, integer, text)
  TO roomscan_api_runtime;
COMMENT ON FUNCTION roomscan.publication_list_links_v2(text, bytea, timestamptz, text, integer, text)
  IS 'Slice 6 bounded professional portal-link reader with at-most-10000 immutable feedback aggregate rows per link. It returns only count/cap/latest action/time, never feedback comment, verified-email digest, portal session, delivery, bearer, or PIN verifier fields.';

-- Professional publication reads use a distinct hashed cookie scope.  They
-- cannot reuse a public-link session or its tables: the reservation and
-- receipt are keyed to the current member cookie and exact immutable asset
-- version, then charged only after PortalDelivery has read that version.
SET ROLE roomscan_owner;

CREATE TABLE roomscan.professional_asset_reservations (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE RESTRICT,
  request_digest bytea NOT NULL CHECK (octet_length(request_digest) = 32),
  professional_session_id uuid NOT NULL,
  snapshot_id uuid NOT NULL,
  asset_id uuid NOT NULL,
  asset_object_version text NOT NULL CHECK (
    length(asset_object_version) BETWEEN 1 AND 1024 AND asset_object_version !~ '[[:cntrl:]]'
  ),
  byte_offset bigint NOT NULL CHECK (byte_offset >= 0),
  byte_length bigint NOT NULL CHECK (byte_length > 0 AND byte_length <= 4194304),
  state text NOT NULL DEFAULT 'reserved' CHECK (state IN ('reserved', 'delivered')),
  created_at timestamptz NOT NULL,
  delivered_at timestamptz,
  PRIMARY KEY (workspace_id, request_digest),
  FOREIGN KEY (workspace_id, professional_session_id)
    REFERENCES roomscan.professional_web_sessions(workspace_id, session_id) ON DELETE RESTRICT,
  FOREIGN KEY (workspace_id, snapshot_id)
    REFERENCES roomscan.publication_snapshots(workspace_id, snapshot_id) ON DELETE RESTRICT,
  FOREIGN KEY (workspace_id, asset_id)
    REFERENCES roomscan.publication_assets(workspace_id, asset_id) ON DELETE RESTRICT,
  CHECK ((state = 'reserved' AND delivered_at IS NULL)
    OR (state = 'delivered' AND delivered_at IS NOT NULL))
);

CREATE TABLE roomscan.professional_asset_delivery_receipts (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE RESTRICT,
  request_digest bytea NOT NULL CHECK (octet_length(request_digest) = 32),
  professional_session_id uuid NOT NULL,
  snapshot_id uuid NOT NULL,
  asset_id uuid NOT NULL,
  asset_object_version text NOT NULL CHECK (
    length(asset_object_version) BETWEEN 1 AND 1024 AND asset_object_version !~ '[[:cntrl:]]'
  ),
  byte_offset bigint NOT NULL CHECK (byte_offset >= 0),
  byte_length bigint NOT NULL CHECK (byte_length > 0 AND byte_length <= 4194304),
  delivered_bytes bigint NOT NULL CHECK (delivered_bytes > 0 AND delivered_bytes <= 4194304),
  delivered_at timestamptz NOT NULL,
  PRIMARY KEY (workspace_id, request_digest),
  FOREIGN KEY (workspace_id, professional_session_id)
    REFERENCES roomscan.professional_web_sessions(workspace_id, session_id) ON DELETE RESTRICT,
  FOREIGN KEY (workspace_id, snapshot_id)
    REFERENCES roomscan.publication_snapshots(workspace_id, snapshot_id) ON DELETE RESTRICT,
  FOREIGN KEY (workspace_id, asset_id)
    REFERENCES roomscan.publication_assets(workspace_id, asset_id) ON DELETE RESTRICT,
  CHECK (delivered_bytes = byte_length)
);

CREATE INDEX professional_asset_reservations_session
  ON roomscan.professional_asset_reservations (workspace_id, professional_session_id, created_at);

ALTER TABLE roomscan.professional_asset_reservations ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.professional_asset_reservations FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.professional_asset_delivery_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.professional_asset_delivery_receipts FORCE ROW LEVEL SECURITY;
CREATE POLICY professional_asset_reservations_tenant_isolation
  ON roomscan.professional_asset_reservations
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));
CREATE POLICY professional_asset_delivery_receipts_tenant_isolation
  ON roomscan.professional_asset_delivery_receipts
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));

RESET ROLE;
REVOKE ALL ON roomscan.professional_asset_reservations,
  roomscan.professional_asset_delivery_receipts
  FROM PUBLIC, roomscan_api_runtime, roomscan_portal_runtime,
    roomscan_publication_worker, roomscan_email_delivery_runtime;
GRANT SELECT, INSERT, UPDATE ON roomscan.professional_asset_reservations,
  roomscan.professional_asset_delivery_receipts
  TO roomscan_policy;

SET ROLE roomscan_owner;

CREATE FUNCTION roomscan.professional_portal_asset_context_v1(
  requested_session_hash bytea,
  authoritative_time timestamptz
)
RETURNS TABLE (workspace_id uuid, professional_session_id uuid)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE session_row roomscan.professional_web_sessions%ROWTYPE;
DECLARE membership_role text;
DECLARE current_authorization_version bigint;
DECLARE principal_is_active boolean;
DECLARE hosted_global_enabled boolean;
DECLARE hosted_workspace_enabled boolean;
DECLARE publication_global_enabled boolean;
DECLARE publication_workspace_enabled boolean;
BEGIN
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
    OR session_row.expires_at <= authoritative_time THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROFESSIONAL_PORTAL_ACCESS_DENIED';
  END IF;
  SELECT membership.role, membership.authorization_version,
         principal.state = 'active'
    INTO membership_role, current_authorization_version, principal_is_active
  FROM roomscan.memberships AS membership
  JOIN roomscan.principals AS principal ON principal.id = membership.principal_id
  WHERE membership.workspace_id = session_row.workspace_id
    AND membership.principal_id = session_row.principal_id
    AND membership.state = 'active';
  IF NOT FOUND OR principal_is_active IS DISTINCT FROM true
    OR current_authorization_version IS DISTINCT FROM session_row.authorization_version
    OR membership_role NOT IN ('owner', 'admin', 'editor', 'viewer') THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROFESSIONAL_PORTAL_ACCESS_DENIED';
  END IF;
  SELECT flag.enabled INTO hosted_global_enabled
  FROM roomscan.global_operational_flags AS flag
  WHERE flag.flag_key = 'hosted_operations_enabled';
  SELECT flag.enabled INTO hosted_workspace_enabled
  FROM roomscan.workspace_operational_flags AS flag
  WHERE flag.workspace_id = session_row.workspace_id
    AND flag.flag_key = 'hosted_operations_enabled';
  SELECT flag.enabled INTO publication_global_enabled
  FROM roomscan.global_operational_flags AS flag
  WHERE flag.flag_key = 'publication_enabled';
  SELECT flag.enabled INTO publication_workspace_enabled
  FROM roomscan.workspace_operational_flags AS flag
  WHERE flag.workspace_id = session_row.workspace_id
    AND flag.flag_key = 'publication_enabled';
  IF hosted_global_enabled IS DISTINCT FROM true
    OR hosted_workspace_enabled IS DISTINCT FROM true
    OR publication_global_enabled IS DISTINCT FROM true
    OR publication_workspace_enabled IS DISTINCT FROM true THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROFESSIONAL_PORTAL_ACCESS_DENIED';
  END IF;
  RETURN QUERY SELECT session_row.workspace_id, session_row.session_id;
END
$function$;

CREATE FUNCTION roomscan.portal_authorize_professional_asset_v1(
  requested_session_hash bytea,
  authoritative_time timestamptz,
  requested_asset_public_id text,
  requested_request_digest bytea,
  requested_byte_offset bigint,
  requested_byte_length bigint
)
RETURNS TABLE (
  status text,
  asset_public_id text,
  object_key text,
  object_version text,
  content_type text,
  asset_bytes bigint,
  byte_offset bigint,
  byte_length bigint,
  delivered_bytes bigint,
  already_accounted boolean
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE asset_row roomscan.publication_assets%ROWTYPE;
DECLARE reservation_row roomscan.professional_asset_reservations%ROWTYPE;
BEGIN
  IF requested_asset_public_id IS NULL OR requested_request_digest IS NULL
    OR requested_byte_offset IS NULL OR requested_byte_length IS NULL
    OR octet_length(requested_request_digest) <> 32
    OR requested_byte_offset < 0 OR requested_byte_length <= 0
    OR requested_byte_length > 4194304 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROFESSIONAL_ASSET_REQUEST';
  END IF;
  SELECT context.* INTO context_row
  FROM roomscan.professional_portal_asset_context_v1(
    requested_session_hash, authoritative_time
  ) AS context;
  SELECT asset.* INTO asset_row
  FROM roomscan.publication_assets AS asset
  JOIN roomscan.publication_snapshots AS snapshot
    ON snapshot.workspace_id = asset.workspace_id
    AND snapshot.snapshot_id = asset.snapshot_id
  JOIN roomscan.publication_allocations AS allocation
    ON allocation.workspace_id = snapshot.workspace_id
    AND allocation.allocation_id = snapshot.allocation_id
  WHERE asset.workspace_id = context_row.workspace_id
    AND asset.public_id = requested_asset_public_id
    AND allocation.state = 'published'
    AND allocation.active_object_version IS NOT NULL;
  IF NOT FOUND OR requested_byte_length > asset_row.bytes
    OR requested_byte_offset > asset_row.bytes - requested_byte_length THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROFESSIONAL_PUBLICATION_ASSET_NOT_FOUND';
  END IF;
  PERFORM pg_advisory_xact_lock(
    hashtextextended(encode(requested_request_digest, 'hex'), 0)
  );
  SELECT reservation.* INTO reservation_row
  FROM roomscan.professional_asset_reservations AS reservation
  WHERE reservation.workspace_id = context_row.workspace_id
    AND reservation.request_digest = requested_request_digest
  FOR UPDATE;
  IF FOUND THEN
    IF reservation_row.professional_session_id IS DISTINCT FROM context_row.professional_session_id
      OR reservation_row.snapshot_id IS DISTINCT FROM asset_row.snapshot_id
      OR reservation_row.asset_id IS DISTINCT FROM asset_row.asset_id
      OR reservation_row.asset_object_version IS DISTINCT FROM asset_row.object_version
      OR reservation_row.byte_offset IS DISTINCT FROM requested_byte_offset
      OR reservation_row.byte_length IS DISTINCT FROM requested_byte_length THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROFESSIONAL_DELIVERY_IDEMPOTENCY_REUSED';
    END IF;
    RETURN QUERY SELECT 'allowed'::text, asset_row.public_id, asset_row.object_key,
      asset_row.object_version, asset_row.content_type, asset_row.bytes,
      requested_byte_offset, requested_byte_length,
      CASE WHEN reservation_row.state = 'delivered' THEN requested_byte_length ELSE 0 END,
      reservation_row.state = 'delivered';
    RETURN;
  END IF;
  INSERT INTO roomscan.professional_asset_reservations (
    workspace_id, request_digest, professional_session_id, snapshot_id,
    asset_id, asset_object_version, byte_offset, byte_length, state, created_at
  ) VALUES (
    context_row.workspace_id, requested_request_digest, context_row.professional_session_id,
    asset_row.snapshot_id, asset_row.asset_id, asset_row.object_version,
    requested_byte_offset, requested_byte_length, 'reserved', authoritative_time
  );
  RETURN QUERY SELECT 'allowed'::text, asset_row.public_id, asset_row.object_key,
    asset_row.object_version, asset_row.content_type, asset_row.bytes,
    requested_byte_offset, requested_byte_length, 0::bigint, false;
END
$function$;

CREATE FUNCTION roomscan.portal_finalize_professional_asset_delivery_v1(
  requested_session_hash bytea,
  authoritative_time timestamptz,
  requested_asset_public_id text,
  requested_request_digest bytea,
  requested_byte_offset bigint,
  requested_byte_length bigint,
  requested_object_version text
)
RETURNS TABLE (
  status text,
  asset_public_id text,
  object_key text,
  object_version text,
  content_type text,
  asset_bytes bigint,
  byte_offset bigint,
  byte_length bigint,
  delivered_bytes bigint,
  already_accounted boolean
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE asset_row roomscan.publication_assets%ROWTYPE;
DECLARE reservation_row roomscan.professional_asset_reservations%ROWTYPE;
DECLARE receipt_row roomscan.professional_asset_delivery_receipts%ROWTYPE;
DECLARE usage_row roomscan.quota_usage_v2%ROWTYPE;
DECLARE quota_period_key text;
DECLARE policy_version bigint;
DECLARE quota_request_key text;
BEGIN
  IF requested_asset_public_id IS NULL OR requested_request_digest IS NULL
    OR requested_byte_offset IS NULL OR requested_byte_length IS NULL
    OR requested_object_version IS NULL
    OR octet_length(requested_request_digest) <> 32
    OR requested_byte_offset < 0 OR requested_byte_length <= 0
    OR requested_byte_length > 4194304
    OR length(requested_object_version) NOT BETWEEN 1 AND 1024
    OR requested_object_version ~ '[[:cntrl:]]' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROFESSIONAL_ASSET_FINALIZATION';
  END IF;
  -- Re-evaluate the distinct professional cookie immediately before the
  -- delivery service emits bytes.  A revoked role/session or kill between
  -- authorization and storage read therefore produces no receipt or charge.
  SELECT context.* INTO context_row
  FROM roomscan.professional_portal_asset_context_v1(
    requested_session_hash, authoritative_time
  ) AS context;
  SELECT asset.* INTO asset_row
  FROM roomscan.publication_assets AS asset
  JOIN roomscan.publication_snapshots AS snapshot
    ON snapshot.workspace_id = asset.workspace_id
    AND snapshot.snapshot_id = asset.snapshot_id
  JOIN roomscan.publication_allocations AS allocation
    ON allocation.workspace_id = snapshot.workspace_id
    AND allocation.allocation_id = snapshot.allocation_id
  WHERE asset.workspace_id = context_row.workspace_id
    AND asset.public_id = requested_asset_public_id
    AND allocation.state = 'published'
    AND allocation.active_object_version IS NOT NULL;
  IF NOT FOUND OR asset_row.object_version IS DISTINCT FROM requested_object_version
    OR requested_byte_length > asset_row.bytes
    OR requested_byte_offset > asset_row.bytes - requested_byte_length THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROFESSIONAL_PUBLICATION_ASSET_NOT_FOUND';
  END IF;
  PERFORM pg_advisory_xact_lock(
    hashtextextended(encode(requested_request_digest, 'hex'), 0)
  );
  SELECT reservation.* INTO reservation_row
  FROM roomscan.professional_asset_reservations AS reservation
  WHERE reservation.workspace_id = context_row.workspace_id
    AND reservation.request_digest = requested_request_digest
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROFESSIONAL_DELIVERY_RESERVATION_REQUIRED';
  END IF;
  IF reservation_row.professional_session_id IS DISTINCT FROM context_row.professional_session_id
    OR reservation_row.snapshot_id IS DISTINCT FROM asset_row.snapshot_id
    OR reservation_row.asset_id IS DISTINCT FROM asset_row.asset_id
    OR reservation_row.asset_object_version IS DISTINCT FROM requested_object_version
    OR reservation_row.byte_offset IS DISTINCT FROM requested_byte_offset
    OR reservation_row.byte_length IS DISTINCT FROM requested_byte_length THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROFESSIONAL_DELIVERY_IDEMPOTENCY_REUSED';
  END IF;
  IF reservation_row.state = 'delivered' THEN
    SELECT receipt.* INTO receipt_row
    FROM roomscan.professional_asset_delivery_receipts AS receipt
    WHERE receipt.workspace_id = context_row.workspace_id
      AND receipt.request_digest = requested_request_digest;
    IF NOT FOUND OR receipt_row.asset_object_version IS DISTINCT FROM requested_object_version
      OR receipt_row.byte_offset IS DISTINCT FROM requested_byte_offset
      OR receipt_row.byte_length IS DISTINCT FROM requested_byte_length
      OR receipt_row.delivered_bytes IS DISTINCT FROM requested_byte_length THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROFESSIONAL_DELIVERY_RECEIPT_INVALID';
    END IF;
    RETURN QUERY SELECT 'allowed'::text, asset_row.public_id, asset_row.object_key,
      asset_row.object_version, asset_row.content_type, asset_row.bytes,
      requested_byte_offset, requested_byte_length, requested_byte_length, true;
    RETURN;
  END IF;
  SELECT policy.version, policy.portal_period_key INTO policy_version, quota_period_key
  FROM roomscan.quota_policy_versions_v2 AS policy
  WHERE policy.workspace_id = context_row.workspace_id AND policy.is_active IS TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PORTAL_QUOTA_UNAVAILABLE';
  END IF;
  SELECT usage.* INTO usage_row
  FROM roomscan.quota_usage_v2 AS usage
  WHERE usage.workspace_id = context_row.workspace_id
    AND usage.metric = 'portal_bytes' AND usage.period_key = quota_period_key
  FOR UPDATE;
  IF NOT FOUND OR usage_row.used + usage_row.reserved + requested_byte_length > usage_row.limit_value THEN
    RAISE EXCEPTION USING ERRCODE = '42900', MESSAGE = 'PORTAL_QUOTA_EXCEEDED';
  END IF;
  UPDATE roomscan.quota_usage_v2 AS usage
  SET used = usage.used + requested_byte_length, updated_at = authoritative_time
  WHERE usage.workspace_id = context_row.workspace_id
    AND usage.metric = 'portal_bytes' AND usage.period_key = quota_period_key;
  quota_request_key := 'professional-publication-delivery:' || encode(requested_request_digest, 'hex');
  INSERT INTO roomscan.quota_ledger_v2 (
    workspace_id, period_key, idempotency_key, action, metric,
    delta_used, delta_reserved, policy_version, recorded_at
  ) VALUES (
    context_row.workspace_id, quota_period_key, quota_request_key, 'finalize',
    'portal_bytes', requested_byte_length, 0, policy_version, authoritative_time
  );
  INSERT INTO roomscan.professional_asset_delivery_receipts (
    workspace_id, request_digest, professional_session_id, snapshot_id,
    asset_id, asset_object_version, byte_offset, byte_length, delivered_bytes,
    delivered_at
  ) VALUES (
    context_row.workspace_id, requested_request_digest, context_row.professional_session_id,
    asset_row.snapshot_id, asset_row.asset_id, requested_object_version,
    requested_byte_offset, requested_byte_length, requested_byte_length,
    authoritative_time
  );
  UPDATE roomscan.professional_asset_reservations AS reservation
  SET state = 'delivered', delivered_at = authoritative_time
  WHERE reservation.workspace_id = reservation_row.workspace_id
    AND reservation.request_digest = reservation_row.request_digest;
  RETURN QUERY SELECT 'allowed'::text, asset_row.public_id, asset_row.object_key,
    asset_row.object_version, asset_row.content_type, asset_row.bytes,
    requested_byte_offset, requested_byte_length, requested_byte_length, false;
END
$function$;

RESET ROLE;

ALTER FUNCTION roomscan.professional_portal_asset_context_v1(bytea, timestamptz)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.portal_authorize_professional_asset_v1(
  bytea, timestamptz, text, bytea, bigint, bigint
) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.portal_finalize_professional_asset_delivery_v1(
  bytea, timestamptz, text, bytea, bigint, bigint, text
) OWNER TO roomscan_policy;
REVOKE ALL ON FUNCTION roomscan.professional_portal_asset_context_v1(bytea, timestamptz),
  roomscan.portal_authorize_professional_asset_v1(
    bytea, timestamptz, text, bytea, bigint, bigint
  ), roomscan.portal_finalize_professional_asset_delivery_v1(
    bytea, timestamptz, text, bytea, bigint, bigint, text
  ) FROM PUBLIC, roomscan_app, roomscan_api_runtime,
    roomscan_publication_worker, roomscan_email_delivery_runtime;
GRANT EXECUTE ON FUNCTION roomscan.portal_authorize_professional_asset_v1(
  bytea, timestamptz, text, bytea, bigint, bigint
), roomscan.portal_finalize_professional_asset_delivery_v1(
  bytea, timestamptz, text, bytea, bigint, bigint, text
) TO roomscan_portal_runtime;
COMMENT ON FUNCTION roomscan.portal_authorize_professional_asset_v1(
  bytea, timestamptz, text, bytea, bigint, bigint
) IS 'Slice 6 portal-runtime-only professional cookie asset reservation. It rechecks active membership, tenant, hosted/publication flags, published allocation state, and one bounded exact asset-version range without directly reading private project truth.';
COMMENT ON FUNCTION roomscan.portal_finalize_professional_asset_delivery_v1(
  bytea, timestamptz, text, bytea, bigint, bigint, text
) IS 'Slice 6 portal-runtime-only professional cookie delivery finalizer. It repeats live professional authorization immediately before emission and atomically charges portal bytes and records one exact active asset-version range.';

-- Keep the frozen v1 snapshot projection stable for the existing native and
-- portal clients.  The browser renderer needs these two link-generation
-- capabilities at the same live authorization boundary as the presentation
-- itself, so expose them only through a new additive projection.
SET ROLE roomscan_owner;

CREATE FUNCTION roomscan.portal_get_snapshot_v2(
  requested_session_hash bytea,
  authoritative_time timestamptz
)
RETURNS TABLE (
  status text,
  snapshot_id uuid,
  snapshot_public_id text,
  publication_kind text,
  property_id uuid,
  presentation_digest bytea,
  presentation_bytes bigint,
  ai_enabled boolean,
  feedback_enabled boolean
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
DECLARE snapshot_row roomscan.publication_snapshots%ROWTYPE;
BEGIN
  SELECT context.* INTO context_row
  FROM roomscan.portal_session_context_v1(requested_session_hash, authoritative_time) AS context;
  SELECT snapshot.* INTO snapshot_row
  FROM roomscan.publication_snapshots AS snapshot
  WHERE snapshot.workspace_id = context_row.workspace_id
    AND snapshot.snapshot_id = context_row.snapshot_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PORTAL_SNAPSHOT_NOT_FOUND';
  END IF;
  PERFORM roomscan.publication_append_access_event_v1(
    context_row.workspace_id, context_row.link_id, context_row.link_generation,
    context_row.snapshot_id, 'snapshot', 'allowed', authoritative_time,
    context_row.client_family, context_row.network_risk_digest
  );
  RETURN QUERY SELECT 'allowed'::text, snapshot_row.snapshot_id,
    snapshot_row.public_id, snapshot_row.publication_kind, snapshot_row.property_id,
    snapshot_row.presentation_digest, snapshot_row.presentation_bytes,
    context_row.ai_enabled, context_row.feedback_enabled;
END
$function$;

RESET ROLE;

ALTER FUNCTION roomscan.portal_get_snapshot_v2(bytea, timestamptz)
  OWNER TO roomscan_policy;
REVOKE ALL ON FUNCTION roomscan.portal_get_snapshot_v2(bytea, timestamptz)
  FROM PUBLIC, roomscan_app, roomscan_api_runtime, roomscan_publication_worker,
    roomscan_email_delivery_runtime;
GRANT EXECUTE ON FUNCTION roomscan.portal_get_snapshot_v2(bytea, timestamptz)
  TO roomscan_portal_runtime;
COMMENT ON FUNCTION roomscan.portal_get_snapshot_v2(bytea, timestamptz) IS
  'Slice 6 additive portal snapshot projection. It rechecks the active link generation and live hosted/publication flags, then returns only the current link-scoped AI and feedback capabilities alongside the immutable presentation metadata.';

COMMENT ON FUNCTION roomscan.publication_feedback_delivery_live_v2(
  uuid, text, timestamptz
) IS 'Slice 6 sealed feedback-delivery liveness predicate. It checks only the opaque workspace and delivery scope against the current portal link generation and operational flags; it grants no runtime delivery capability.';
COMMENT ON FUNCTION roomscan.portal_request_feedback_verification_v2(
  bytea, timestamptz, bytea, bytea, bytea, text, bytea, bytea, bytea
) IS 'Superseded Slice 6 feedback verification issuer retained only for immutable migration compatibility. Portal and email runtimes have no EXECUTE grant; v3 is the sole live issuance reducer.';
COMMENT ON FUNCTION roomscan.claim_next_feedback_delivery_v2(
  text, timestamptz, timestamptz
) IS 'Superseded Slice 6 feedback-delivery claim reducer retained only for immutable migration compatibility. The email runtime has no EXECUTE grant; v3 is the sole live lifecycle.';
COMMENT ON FUNCTION roomscan.claim_feedback_delivery_v2(
  text, timestamptz, timestamptz
) IS 'Superseded Slice 6 feedback-delivery claim alias retained only for immutable migration compatibility. The email runtime has no EXECUTE grant; v3 is the sole live lifecycle.';
COMMENT ON FUNCTION roomscan.validate_feedback_delivery_v2(
  text, text, timestamptz
) IS 'Superseded Slice 6 feedback-delivery pre-send reducer retained only for immutable migration compatibility. The email runtime has no EXECUTE grant; v3 is the sole live lifecycle.';
COMMENT ON FUNCTION roomscan.complete_feedback_delivery_v2(
  text, text, timestamptz
) IS 'Superseded Slice 6 feedback-delivery completion reducer retained only for immutable migration compatibility. The email runtime has no EXECUTE grant; v3 is the sole live lifecycle.';
COMMENT ON FUNCTION roomscan.cancel_feedback_delivery_v2(
  text, text, text, timestamptz
) IS 'Superseded Slice 6 feedback-delivery cancellation reducer retained only for immutable migration compatibility. The email runtime has no EXECUTE grant; v3 is the sole live lifecycle.';
COMMENT ON FUNCTION roomscan.release_feedback_delivery_v2(
  text, text, timestamptz
) IS 'Superseded Slice 6 feedback-delivery release reducer retained only for immutable migration compatibility. The email runtime has no EXECUTE grant; v3 is the sole live lifecycle.';
COMMENT ON FUNCTION roomscan.complete_feedback_delivery_v3(
  text, text, timestamptz
) IS 'Slice 6 sealed email-runtime feedback-delivery completion reducer. It records one leased encrypted-envelope delivery only after the exact live portal scope remains valid.';
COMMENT ON FUNCTION roomscan.cancel_feedback_delivery_v3(
  text, text, text, timestamptz
) IS 'Slice 6 sealed email-runtime feedback-delivery cancellation reducer. It changes only a currently leased encrypted-envelope row with a bounded worker reason.';
COMMENT ON FUNCTION roomscan.release_feedback_delivery_v3(
  text, text, timestamptz
) IS 'Slice 6 sealed email-runtime feedback-delivery release reducer. It relinquishes only a currently leased encrypted-envelope row for bounded retry without portal mutation authority.';
COMMENT ON FUNCTION roomscan.professional_portal_asset_context_v1(
  bytea, timestamptz
) IS 'Slice 6 private portal-runtime professional-cookie context. It rechecks session, membership, tenant, and hosted/publication live flags without exposing project truth or direct storage access.';
