SET ROLE roomscan_owner;

CREATE FUNCTION roomscan.request_principal_id()
RETURNS uuid
LANGUAGE sql
STABLE
PARALLEL SAFE
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $function$
  SELECT NULLIF(current_setting('app.principal_id', true), '')::uuid
$function$;

CREATE FUNCTION roomscan.request_tenant_id()
RETURNS uuid
LANGUAGE sql
STABLE
PARALLEL SAFE
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $function$
  SELECT NULLIF(current_setting('app.tenant_id', true), '')::uuid
$function$;

CREATE FUNCTION roomscan.request_authorization_version()
RETURNS bigint
LANGUAGE sql
STABLE
PARALLEL SAFE
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $function$
  SELECT NULLIF(current_setting('app.authorization_version', true), '')::bigint
$function$;

CREATE TABLE roomscan.workspaces (
  id uuid PRIMARY KEY,
  slug text NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9][a-z0-9-]{2,62}$'),
  display_name text NOT NULL CHECK (length(display_name) BETWEEN 1 AND 160),
  state text NOT NULL DEFAULT 'active' CHECK (state IN ('active', 'read_only', 'suspended', 'deleted')),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE roomscan.memberships (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE CASCADE,
  principal_id uuid NOT NULL REFERENCES roomscan.principals(id) ON DELETE CASCADE,
  role text NOT NULL CHECK (role IN ('owner', 'admin', 'editor', 'viewer')),
  state text NOT NULL DEFAULT 'active' CHECK (state IN ('invited', 'active', 'removed')),
  authorization_version bigint NOT NULL DEFAULT 1 CHECK (authorization_version > 0),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (workspace_id, principal_id)
);

CREATE TABLE roomscan.invitations (
  id uuid NOT NULL,
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE CASCADE,
  token_hash bytea NOT NULL CHECK (octet_length(token_hash) = 32),
  invited_email text,
  invited_role text NOT NULL CHECK (invited_role IN ('admin', 'editor', 'viewer')),
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz,
  consumed_by_principal_id uuid REFERENCES roomscan.principals(id),
  created_by_principal_id uuid NOT NULL REFERENCES roomscan.principals(id),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (workspace_id, id),
  UNIQUE (token_hash),
  CHECK ((consumed_at IS NULL) = (consumed_by_principal_id IS NULL))
);

CREATE TABLE roomscan.projects (
  id uuid NOT NULL,
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE CASCADE,
  slug text NOT NULL CHECK (slug ~ '^[a-z0-9][a-z0-9-]{1,62}$'),
  title text NOT NULL CHECK (length(title) BETWEEN 1 AND 240),
  state text NOT NULL DEFAULT 'active' CHECK (state IN ('active', 'archived', 'deleted')),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (workspace_id, id),
  UNIQUE (workspace_id, slug)
);

CREATE TABLE roomscan.subscription_states (
  workspace_id uuid PRIMARY KEY REFERENCES roomscan.workspaces(id) ON DELETE CASCADE,
  plan_key text NOT NULL DEFAULT 'none',
  status text NOT NULL DEFAULT 'inactive' CHECK (status IN ('inactive', 'trialing', 'active', 'past_due', 'canceled', 'read_only_grace')),
  current_period_end timestamptz,
  reconciliation_generation bigint NOT NULL DEFAULT 0 CHECK (reconciliation_generation >= 0),
  source_observed_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE roomscan.audit_states (
  workspace_id uuid PRIMARY KEY REFERENCES roomscan.workspaces(id) ON DELETE CASCADE,
  next_sequence bigint NOT NULL DEFAULT 1 CHECK (next_sequence > 0),
  last_exported_sequence bigint NOT NULL DEFAULT 0 CHECK (last_exported_sequence >= 0),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CHECK (last_exported_sequence < next_sequence)
);

CREATE TABLE roomscan.audit_events (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE CASCADE,
  sequence bigint NOT NULL CHECK (sequence > 0),
  actor_principal_id uuid REFERENCES roomscan.principals(id) ON DELETE SET NULL,
  action text NOT NULL CHECK (length(action) BETWEEN 1 AND 160),
  subject_kind text NOT NULL CHECK (length(subject_kind) BETWEEN 1 AND 80),
  subject_id text NOT NULL CHECK (length(subject_id) BETWEEN 1 AND 512),
  occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (workspace_id, sequence)
);

CREATE TABLE roomscan.operational_flags (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE CASCADE,
  flag_key text NOT NULL CHECK (flag_key ~ '^[a-z][a-z0-9_.-]{1,127}$'),
  enabled boolean NOT NULL,
  reason text,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (workspace_id, flag_key)
);

CREATE FUNCTION roomscan.has_authorized_tenant(candidate_workspace_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
PARALLEL SAFE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
  SELECT CASE
    -- This non-mutating RLS predicate handles an invalid NULL candidate by
    -- returning literal false rather than raising from a policy evaluation.
    WHEN candidate_workspace_id IS NULL THEN false
    ELSE candidate_workspace_id = roomscan.request_tenant_id()
      AND roomscan.request_principal_id() IS NOT NULL
      AND roomscan.request_authorization_version() IS NOT NULL
      AND EXISTS (
        SELECT 1
        FROM roomscan.memberships AS membership
        WHERE membership.workspace_id = candidate_workspace_id
          AND membership.principal_id = roomscan.request_principal_id()
          AND membership.state = 'active'
          AND membership.authorization_version = roomscan.request_authorization_version()
      )
  END
$function$;

CREATE FUNCTION roomscan.enforce_membership_invariants()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  removing_owner boolean;
  another_owner_exists boolean;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.role IS DISTINCT FROM OLD.role OR NEW.state IS DISTINCT FROM OLD.state THEN
      NEW.authorization_version := OLD.authorization_version + 1;
    ELSE
      NEW.authorization_version := OLD.authorization_version;
    END IF;
    NEW.updated_at := clock_timestamp();
    removing_owner := OLD.role = 'owner' AND OLD.state = 'active'
      AND (NEW.role <> 'owner' OR NEW.state <> 'active');
  ELSE
    removing_owner := OLD.role = 'owner' AND OLD.state = 'active';
  END IF;

  IF removing_owner THEN
    PERFORM 1
    FROM roomscan.workspaces
    WHERE id = OLD.workspace_id
    FOR UPDATE;

    SELECT EXISTS (
      SELECT 1
      FROM roomscan.memberships AS candidate
      WHERE candidate.workspace_id = OLD.workspace_id
        AND candidate.principal_id <> OLD.principal_id
        AND candidate.role = 'owner'
        AND candidate.state = 'active'
    )
    INTO another_owner_exists;

    IF NOT another_owner_exists THEN
      RAISE EXCEPTION USING
        ERRCODE = 'P0001',
        MESSAGE = 'LAST_OWNER_REQUIRED';
    END IF;
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END
$function$;

CREATE TRIGGER memberships_enforce_invariants
BEFORE UPDATE OR DELETE ON roomscan.memberships
FOR EACH ROW EXECUTE FUNCTION roomscan.enforce_membership_invariants();

ALTER TABLE roomscan.workspaces ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.workspaces FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.memberships FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.invitations ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.invitations FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.projects FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.subscription_states ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.subscription_states FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.audit_states ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.audit_states FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.audit_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.audit_events FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.operational_flags ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.operational_flags FORCE ROW LEVEL SECURITY;

CREATE POLICY workspaces_tenant_isolation ON roomscan.workspaces
FOR ALL TO PUBLIC
USING (roomscan.has_authorized_tenant(id))
WITH CHECK (roomscan.has_authorized_tenant(id));

CREATE POLICY memberships_tenant_write ON roomscan.memberships
FOR ALL TO PUBLIC
USING (roomscan.has_authorized_tenant(workspace_id))
WITH CHECK (roomscan.has_authorized_tenant(workspace_id));

CREATE POLICY memberships_self_list ON roomscan.memberships
FOR SELECT TO PUBLIC
USING (
  principal_id = roomscan.request_principal_id()
  AND state = 'active'
);

CREATE POLICY invitations_tenant_isolation ON roomscan.invitations
FOR ALL TO PUBLIC
USING (roomscan.has_authorized_tenant(workspace_id))
WITH CHECK (roomscan.has_authorized_tenant(workspace_id));

CREATE POLICY projects_tenant_isolation ON roomscan.projects
FOR ALL TO PUBLIC
USING (roomscan.has_authorized_tenant(workspace_id))
WITH CHECK (roomscan.has_authorized_tenant(workspace_id));

CREATE POLICY subscription_states_tenant_isolation ON roomscan.subscription_states
FOR ALL TO PUBLIC
USING (roomscan.has_authorized_tenant(workspace_id))
WITH CHECK (roomscan.has_authorized_tenant(workspace_id));

CREATE POLICY audit_states_tenant_isolation ON roomscan.audit_states
FOR ALL TO PUBLIC
USING (roomscan.has_authorized_tenant(workspace_id))
WITH CHECK (roomscan.has_authorized_tenant(workspace_id));

CREATE POLICY audit_events_tenant_isolation ON roomscan.audit_events
FOR ALL TO PUBLIC
USING (roomscan.has_authorized_tenant(workspace_id))
WITH CHECK (roomscan.has_authorized_tenant(workspace_id));

CREATE POLICY operational_flags_tenant_isolation ON roomscan.operational_flags
FOR ALL TO PUBLIC
USING (roomscan.has_authorized_tenant(workspace_id))
WITH CHECK (roomscan.has_authorized_tenant(workspace_id));

CREATE FUNCTION roomscan.consume_invitation(
  invitation_token_hash bytea
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  accepted_workspace_id uuid;
  accepted_role text;
  accepting_principal_id uuid := roomscan.request_principal_id();
BEGIN
  IF accepting_principal_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHENTICATED_PRINCIPAL_REQUIRED';
  END IF;
  IF invitation_token_hash IS NULL OR octet_length(invitation_token_hash) <> 32 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVITATION_TOKEN_HASH_LENGTH';
  END IF;

  UPDATE roomscan.invitations
  SET consumed_at = clock_timestamp(),
      consumed_by_principal_id = accepting_principal_id
  WHERE token_hash = invitation_token_hash
    AND expires_at > clock_timestamp()
    AND consumed_at IS NULL
  RETURNING workspace_id, invited_role
  INTO accepted_workspace_id, accepted_role;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  INSERT INTO roomscan.memberships (
    workspace_id,
    principal_id,
    role,
    state
  ) VALUES (
    accepted_workspace_id,
    accepting_principal_id,
    accepted_role,
    'active'
  )
  ON CONFLICT (workspace_id, principal_id) DO NOTHING;

  RETURN true;
END
$function$;

REVOKE ALL ON ALL TABLES IN SCHEMA roomscan FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA roomscan FROM PUBLIC;

GRANT SELECT, INSERT, UPDATE, DELETE ON roomscan.workspaces TO roomscan_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON roomscan.memberships TO roomscan_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON roomscan.invitations TO roomscan_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON roomscan.projects TO roomscan_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON roomscan.subscription_states TO roomscan_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON roomscan.audit_states TO roomscan_app;
GRANT SELECT, INSERT ON roomscan.audit_events TO roomscan_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON roomscan.operational_flags TO roomscan_app;

GRANT EXECUTE ON FUNCTION roomscan.request_principal_id() TO roomscan_app, roomscan_policy;
GRANT EXECUTE ON FUNCTION roomscan.request_tenant_id() TO roomscan_app, roomscan_policy;
GRANT EXECUTE ON FUNCTION roomscan.request_authorization_version() TO roomscan_app, roomscan_policy;
GRANT EXECUTE ON FUNCTION roomscan.enforce_membership_invariants() TO roomscan_app;
GRANT EXECUTE ON FUNCTION roomscan.consume_invitation(bytea) TO roomscan_app;

RESET ROLE;

ALTER FUNCTION roomscan.has_authorized_tenant(uuid) OWNER TO roomscan_policy;
REVOKE ALL ON FUNCTION roomscan.has_authorized_tenant(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION roomscan.has_authorized_tenant(uuid) TO roomscan_app, roomscan_owner;
GRANT SELECT ON roomscan.memberships TO roomscan_policy;

ALTER FUNCTION roomscan.consume_invitation(bytea) OWNER TO roomscan_policy;
REVOKE ALL ON FUNCTION roomscan.consume_invitation(bytea) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION roomscan.consume_invitation(bytea) TO roomscan_app;
GRANT SELECT, UPDATE ON roomscan.invitations TO roomscan_policy;
GRANT SELECT, INSERT ON roomscan.memberships TO roomscan_policy;

COMMENT ON FUNCTION roomscan.has_authorized_tenant(uuid) IS
  'Reviewed SECURITY DEFINER RLS helper: fixed search_path, boolean-only result, membership SELECT only, NOLOGIN owner, PUBLIC execute revoked.';

COMMENT ON FUNCTION roomscan.consume_invitation(bytea) IS
  'Reviewed SECURITY DEFINER capability: fixed search_path, 32-byte token hash, authenticated principal only, atomic unconsumed/expiry guard, NOLOGIN owner, PUBLIC execute revoked.';
