-- Slice 4 hardening: tenant state is mutated only through reviewed, bounded
-- capabilities. This migration is intentionally forward-only.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

SET ROLE roomscan_owner;

ALTER TABLE roomscan.memberships
  ADD COLUMN id uuid NOT NULL DEFAULT gen_random_uuid();
ALTER TABLE roomscan.memberships
  ADD CONSTRAINT memberships_id_unique UNIQUE (id);

CREATE FUNCTION roomscan.bootstrap_workspace(
  requested_slug text,
  requested_display_name text
)
RETURNS TABLE (
  workspace_id uuid,
  membership_id uuid,
  authorization_version bigint
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  authenticated_principal_id uuid := roomscan.request_principal_id();
  created_workspace_id uuid := gen_random_uuid();
  created_membership_id uuid := gen_random_uuid();
BEGIN
  IF authenticated_principal_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHENTICATED_PRINCIPAL_REQUIRED';
  END IF;
  IF roomscan.request_tenant_id() IS NOT NULL
    OR roomscan.request_authorization_version() IS NOT NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PRINCIPAL_ONLY_CONTEXT_REQUIRED';
  END IF;
  IF requested_slug IS NULL
    OR requested_display_name IS NULL
    OR requested_slug !~ '^[a-z0-9][a-z0-9-]{2,62}$'
    OR length(requested_display_name) NOT BETWEEN 1 AND 160 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_WORKSPACE_BOOTSTRAP';
  END IF;
  PERFORM 1
  FROM roomscan.principals AS principal
  WHERE principal.id = authenticated_principal_id
    AND principal.state = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'ACTIVE_PRINCIPAL_REQUIRED';
  END IF;

  INSERT INTO roomscan.workspaces (id, slug, display_name)
  VALUES (created_workspace_id, requested_slug, requested_display_name);
  INSERT INTO roomscan.memberships (id, workspace_id, principal_id, role, state)
  VALUES (created_membership_id, created_workspace_id, authenticated_principal_id, 'owner', 'active');
  INSERT INTO roomscan.audit_states (workspace_id, next_sequence)
  VALUES (created_workspace_id, 2);
  INSERT INTO roomscan.audit_events (
    workspace_id, sequence, actor_principal_id, action, subject_kind, subject_id
  ) VALUES (
    created_workspace_id, 1, authenticated_principal_id,
    'workspace.created', 'workspace', created_workspace_id::text
  );

  RETURN QUERY SELECT created_workspace_id, created_membership_id, 1::bigint;
END
$function$;

RESET ROLE;
CREATE OR REPLACE FUNCTION roomscan.consume_invitation(invitation_token_hash bytea)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  accepting_principal_id uuid := roomscan.request_principal_id();
  accepted_workspace_id uuid;
  accepted_invitation_id uuid;
  accepted_role text;
  existing_membership_state text;
BEGIN
  IF accepting_principal_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHENTICATED_PRINCIPAL_REQUIRED';
  END IF;
  IF invitation_token_hash IS NULL OR octet_length(invitation_token_hash) <> 32 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVITATION_TOKEN_HASH_LENGTH';
  END IF;

  SELECT invitation.workspace_id, invitation.id, invitation.invited_role
  INTO accepted_workspace_id, accepted_invitation_id, accepted_role
  FROM roomscan.invitations AS invitation
  WHERE invitation.token_hash = invitation_token_hash
    AND invitation.expires_at > clock_timestamp()
    AND invitation.consumed_at IS NULL
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  SELECT membership.state
  INTO existing_membership_state
  FROM roomscan.memberships AS membership
  WHERE membership.workspace_id = accepted_workspace_id
    AND membership.principal_id = accepting_principal_id
  FOR UPDATE;

  IF FOUND THEN
    -- An already-active member receives no new access. Leave the invitation
    -- unconsumed so a distinct intended principal can still use the token.
    IF existing_membership_state = 'active' THEN
      RETURN false;
    END IF;
    UPDATE roomscan.memberships
    SET role = accepted_role,
        state = 'active'
    WHERE workspace_id = accepted_workspace_id
      AND principal_id = accepting_principal_id
      AND state IN ('invited', 'removed');
    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'INVITATION_MEMBERSHIP_STATE_CHANGED';
    END IF;
  ELSE
    INSERT INTO roomscan.memberships (workspace_id, principal_id, role, state)
    VALUES (accepted_workspace_id, accepting_principal_id, accepted_role, 'active');
  END IF;

  UPDATE roomscan.invitations
  SET consumed_at = clock_timestamp(),
      consumed_by_principal_id = accepting_principal_id
  WHERE workspace_id = accepted_workspace_id
    AND id = accepted_invitation_id
    AND consumed_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'INVITATION_CONSUME_RACE';
  END IF;
  RETURN true;
END
$function$;

-- Exact reviewed SECURITY DEFINER allowlist. No app role receives direct DML
-- over billing, quota, audit, membership, invitation, or workspace state.
RESET ROLE;
ALTER FUNCTION roomscan.has_authorized_tenant(uuid) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.consume_invitation(bytea) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.bootstrap_workspace(text, text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.activate_quota_policy(bigint, bigint, bigint, bigint, bigint, bigint, integer)
  OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.reserve_quota(roomscan.quota_metric, bigint, text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.finalize_quota(text, bigint) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.release_quota(text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.record_stripe_event(text, text, bytea, boolean, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.apply_stripe_reconciliation(bigint, timestamptz, text, text, timestamptz)
  OWNER TO roomscan_policy;

ALTER FUNCTION roomscan.activate_quota_policy(bigint, bigint, bigint, bigint, bigint, bigint, integer)
  SECURITY DEFINER;
ALTER FUNCTION roomscan.reserve_quota(roomscan.quota_metric, bigint, text) SECURITY DEFINER;
ALTER FUNCTION roomscan.finalize_quota(text, bigint) SECURITY DEFINER;
ALTER FUNCTION roomscan.release_quota(text) SECURITY DEFINER;
ALTER FUNCTION roomscan.record_stripe_event(text, text, bytea, boolean, timestamptz) SECURITY DEFINER;
ALTER FUNCTION roomscan.apply_stripe_reconciliation(bigint, timestamptz, text, text, timestamptz)
  SECURITY DEFINER;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA roomscan FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION roomscan.request_tenant_id(),
  roomscan.request_authorization_version(), roomscan.enforce_membership_invariants()
FROM roomscan_app;
REVOKE ALL ON FUNCTION roomscan.has_authorized_tenant(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION roomscan.consume_invitation(bytea) FROM PUBLIC;
REVOKE ALL ON FUNCTION roomscan.bootstrap_workspace(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION roomscan.activate_quota_policy(bigint, bigint, bigint, bigint, bigint, bigint, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION roomscan.reserve_quota(roomscan.quota_metric, bigint, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION roomscan.finalize_quota(text, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION roomscan.release_quota(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION roomscan.record_stripe_event(text, text, bytea, boolean, timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION roomscan.apply_stripe_reconciliation(bigint, timestamptz, text, text, timestamptz) FROM PUBLIC;

REVOKE ALL ON roomscan.workspaces, roomscan.memberships, roomscan.invitations,
  roomscan.subscription_states, roomscan.audit_states, roomscan.audit_events,
  roomscan.operational_flags, roomscan.quota_policy_versions, roomscan.quota_usage,
  roomscan.quota_reservations, roomscan.quota_ledger, roomscan.stripe_event_receipts,
  roomscan.stripe_reconciliation_generations FROM roomscan_app;
REVOKE UPDATE (applied) ON roomscan.stripe_reconciliation_generations FROM roomscan_app;
GRANT SELECT ON roomscan.workspaces, roomscan.memberships, roomscan.invitations,
  roomscan.subscription_states, roomscan.audit_states, roomscan.audit_events,
  roomscan.operational_flags, roomscan.quota_policy_versions, roomscan.quota_usage,
  roomscan.quota_reservations, roomscan.quota_ledger, roomscan.stripe_event_receipts,
  roomscan.stripe_reconciliation_generations TO roomscan_app;

REVOKE ALL ON ALL TABLES IN SCHEMA roomscan FROM roomscan_policy;
GRANT SELECT ON roomscan.principals, roomscan.memberships, roomscan.workspaces,
  roomscan.invitations, roomscan.quota_policy_versions, roomscan.quota_usage,
  roomscan.quota_reservations, roomscan.subscription_states,
  roomscan.stripe_event_receipts, roomscan.stripe_reconciliation_generations
TO roomscan_policy;
GRANT INSERT ON roomscan.workspaces, roomscan.memberships, roomscan.audit_states,
  roomscan.audit_events, roomscan.quota_policy_versions, roomscan.quota_usage,
  roomscan.quota_reservations, roomscan.quota_ledger, roomscan.stripe_event_receipts,
  roomscan.stripe_reconciliation_generations, roomscan.subscription_states TO roomscan_policy;
GRANT UPDATE ON roomscan.workspaces, roomscan.invitations, roomscan.memberships, roomscan.quota_policy_versions,
  roomscan.quota_usage, roomscan.quota_reservations, roomscan.stripe_reconciliation_generations,
  roomscan.subscription_states TO roomscan_policy;

GRANT EXECUTE ON FUNCTION roomscan.has_authorized_tenant(uuid),
  roomscan.consume_invitation(bytea), roomscan.bootstrap_workspace(text, text),
  roomscan.activate_quota_policy(bigint, bigint, bigint, bigint, bigint, bigint, integer),
  roomscan.reserve_quota(roomscan.quota_metric, bigint, text),
  roomscan.finalize_quota(text, bigint), roomscan.release_quota(text),
  roomscan.record_stripe_event(text, text, bytea, boolean, timestamptz),
  roomscan.apply_stripe_reconciliation(bigint, timestamptz, text, text, timestamptz)
TO roomscan_app;

COMMENT ON FUNCTION roomscan.bootstrap_workspace(text, text) IS
  'Reviewed SECURITY DEFINER capability: fixed search_path, principal-only transaction context, server-generated IDs, bounded workspace/owner/audit creation, PUBLIC execute revoked.';
COMMENT ON FUNCTION roomscan.activate_quota_policy(bigint, bigint, bigint, bigint, bigint, bigint, integer) IS
  'Reviewed SECURITY DEFINER quota reducer: fixed search_path, bounded arguments/return, tenant context required, PUBLIC execute revoked.';
COMMENT ON FUNCTION roomscan.reserve_quota(roomscan.quota_metric, bigint, text) IS
  'Reviewed SECURITY DEFINER quota reducer: fixed search_path, bounded arguments/return, tenant context required, PUBLIC execute revoked.';
COMMENT ON FUNCTION roomscan.finalize_quota(text, bigint) IS
  'Reviewed SECURITY DEFINER quota reducer: fixed search_path, bounded arguments/return, tenant context required, PUBLIC execute revoked.';
COMMENT ON FUNCTION roomscan.release_quota(text) IS
  'Reviewed SECURITY DEFINER quota reducer: fixed search_path, bounded arguments/return, tenant context required, PUBLIC execute revoked.';
COMMENT ON FUNCTION roomscan.record_stripe_event(text, text, bytea, boolean, timestamptz) IS
  'Reviewed SECURITY DEFINER Stripe reducer: fixed search_path, bounded arguments/return, tenant context required, PUBLIC execute revoked.';
COMMENT ON FUNCTION roomscan.apply_stripe_reconciliation(bigint, timestamptz, text, text, timestamptz) IS
  'Reviewed SECURITY DEFINER Stripe reducer: fixed search_path, bounded arguments/return, tenant context required, PUBLIC execute revoked.';
COMMENT ON FUNCTION roomscan.request_principal_id() IS
  'Bounded SECURITY INVOKER context reader used by membership self-list RLS; returns only the transaction-local principal UUID.';
COMMENT ON FUNCTION roomscan.request_tenant_id() IS
  'Bounded SECURITY INVOKER context reader used internally by reviewed policy routines; returns only the transaction-local tenant UUID.';
COMMENT ON FUNCTION roomscan.request_authorization_version() IS
  'Bounded SECURITY INVOKER context reader used internally by reviewed policy routines; returns only the transaction-local authorization version.';
COMMENT ON FUNCTION roomscan.enforce_membership_invariants() IS
  'Internal SECURITY INVOKER trigger routine: fixed search_path, authorization-version advance and serialized last-Owner invariant; no direct app EXECUTE.';

RESET ROLE;
