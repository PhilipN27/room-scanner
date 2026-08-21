-- Slice 4 runtime-lane, policy, billing, and quota integration. Forward-only.
-- 0001-0006 remain checksum-immutable.  No runtime password or credential is
-- created here; attaching/rotating each LOGIN secret is an operator live gate.

-- Reserved runtime names fail closed if a dirty catalog already contains one.
CREATE ROLE roomscan_api_runtime
  LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
CREATE ROLE roomscan_authorizer_runtime
  LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
CREATE ROLE roomscan_auth_challenge_runtime
  LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
CREATE ROLE roomscan_stripe_ingress_runtime
  LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
CREATE ROLE roomscan_stripe_reconciliation_runtime
  LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
CREATE ROLE roomscan_audit_export_runtime
  LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
CREATE ROLE roomscan_email_delivery_runtime
  LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
CREATE ROLE roomscan_operator
  NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;

ALTER ROLE roomscan_app
  NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;

REVOKE roomscan_owner, roomscan_policy, roomscan_app FROM roomscan_api_runtime;
REVOKE roomscan_owner, roomscan_policy, roomscan_app FROM roomscan_authorizer_runtime;
REVOKE roomscan_owner, roomscan_policy, roomscan_app FROM roomscan_auth_challenge_runtime;
REVOKE roomscan_owner, roomscan_policy, roomscan_app FROM roomscan_stripe_ingress_runtime;
REVOKE roomscan_owner, roomscan_policy, roomscan_app FROM roomscan_stripe_reconciliation_runtime;
REVOKE roomscan_owner, roomscan_policy, roomscan_app FROM roomscan_audit_export_runtime;
REVOKE roomscan_owner, roomscan_policy, roomscan_app FROM roomscan_email_delivery_runtime;
REVOKE roomscan_owner, roomscan_policy FROM roomscan_operator;

GRANT USAGE ON SCHEMA roomscan TO roomscan_api_runtime,
  roomscan_authorizer_runtime, roomscan_auth_challenge_runtime,
  roomscan_stripe_ingress_runtime, roomscan_stripe_reconciliation_runtime,
  roomscan_audit_export_runtime, roomscan_email_delivery_runtime,
  roomscan_operator;

-- 0006 temporarily staged broad read/column-create privileges on roomscan_app.
-- Quarantine them before any runtime LOGIN secret may be attached.
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA roomscan FROM roomscan_app;
REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA roomscan FROM roomscan_app;
REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA roomscan FROM roomscan_app;
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA roomscan FROM
  roomscan_api_runtime, roomscan_authorizer_runtime,
  roomscan_auth_challenge_runtime, roomscan_stripe_ingress_runtime,
  roomscan_stripe_reconciliation_runtime, roomscan_audit_export_runtime,
  roomscan_email_delivery_runtime;
REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA roomscan FROM
  roomscan_api_runtime, roomscan_authorizer_runtime,
  roomscan_auth_challenge_runtime, roomscan_stripe_ingress_runtime,
  roomscan_stripe_reconciliation_runtime, roomscan_audit_export_runtime,
  roomscan_email_delivery_runtime;
REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA roomscan FROM
  roomscan_api_runtime, roomscan_authorizer_runtime,
  roomscan_auth_challenge_runtime, roomscan_stripe_ingress_runtime,
  roomscan_stripe_reconciliation_runtime, roomscan_audit_export_runtime,
  roomscan_email_delivery_runtime;

SET ROLE roomscan_owner;

CREATE TABLE roomscan.provider_audit_outbox (
  id text PRIMARY KEY CHECK (
    length(id) BETWEEN 16 AND 128 AND id ~ '^paud_[A-Za-z0-9_-]+$'
  ),
  provider_lane text NOT NULL CHECK (
    provider_lane IN ('email', 'stripe')
  ),
  event_code text NOT NULL CHECK (
    event_code IN (
      'email.delivery.accepted', 'email.delivery.failed',
      'stripe.webhook.accepted', 'stripe.webhook.duplicate'
    )
  ),
  CONSTRAINT provider_audit_outbox_lane_event_match CHECK (
    (provider_lane = 'email' AND event_code IN (
      'email.delivery.accepted', 'email.delivery.failed'
    ))
    OR (provider_lane = 'stripe' AND event_code IN (
      'stripe.webhook.accepted', 'stripe.webhook.duplicate'
    ))
  ),
  bounded_reference text NOT NULL CHECK (
    length(bounded_reference) BETWEEN 1 AND 128
    AND bounded_reference ~ '^[A-Za-z0-9._:-]+$'
  ),
  occurred_at timestamptz NOT NULL,
  state text NOT NULL DEFAULT 'pending' CHECK (
    state IN ('pending', 'leased', 'delivered')
  ),
  lease_id text CHECK (
    lease_id IS NULL OR (
      length(lease_id) BETWEEN 1 AND 128 AND lease_id ~ '^[A-Za-z0-9_-]+$'
    )
  ),
  lease_expires_at timestamptz,
  delivered_at timestamptz,
  delivery_attempts integer NOT NULL DEFAULT 0 CHECK (delivery_attempts >= 0),
  CHECK (
    (state = 'pending' AND lease_id IS NULL AND lease_expires_at IS NULL AND delivered_at IS NULL)
    OR (state = 'leased' AND lease_id IS NOT NULL AND lease_expires_at IS NOT NULL AND delivered_at IS NULL)
    OR (state = 'delivered' AND lease_id IS NULL AND lease_expires_at IS NULL AND delivered_at IS NOT NULL)
  )
);
CREATE INDEX provider_audit_outbox_available
  ON roomscan.provider_audit_outbox (state, lease_expires_at, occurred_at, id);

CREATE FUNCTION roomscan.claim_next_magic_delivery(
  requested_lease_id text,
  claimed_at_time timestamptz,
  requested_lease_expires_at timestamptz
)
RETURNS SETOF roomscan.magic_link_delivery_outbox
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  candidate_id text;
BEGIN
  IF requested_lease_id IS NULL OR claimed_at_time IS NULL
    OR requested_lease_expires_at IS NULL
    OR length(requested_lease_id) NOT BETWEEN 1 AND 128
    OR requested_lease_id !~ '^[A-Za-z0-9_-]+$'
    OR requested_lease_expires_at <= claimed_at_time THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023', MESSAGE = 'INVALID_MAGIC_DELIVERY_LEASE';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM roomscan.global_operational_flags AS sign_in_flag
    WHERE sign_in_flag.flag_key = 'professional_sign_in_enabled'
      AND sign_in_flag.enabled IS TRUE
      AND sign_in_flag.version > 0
  ) THEN
    RETURN;
  END IF;

  -- Select one deterministic server-owned target. SKIP LOCKED lets parallel
  -- workers make progress without admitting two winners for the same row.
  SELECT delivery.id INTO candidate_id
  FROM roomscan.magic_link_delivery_outbox AS delivery
  WHERE delivery.state = 'pending'
     OR (delivery.state = 'leased'
       AND delivery.lease_expires_at <= claimed_at_time)
  ORDER BY delivery.created_at, delivery.id
  FOR UPDATE OF delivery SKIP LOCKED
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  RETURN QUERY
  UPDATE roomscan.magic_link_delivery_outbox AS delivery
  SET state = CASE
        WHEN delivery.expires_at <= claimed_at_time THEN 'expired'
        ELSE 'leased'
      END,
      lease_id = CASE
        WHEN delivery.expires_at <= claimed_at_time THEN NULL
        ELSE requested_lease_id
      END,
      lease_expires_at = CASE
        WHEN delivery.expires_at <= claimed_at_time THEN NULL
        ELSE LEAST(requested_lease_expires_at, delivery.expires_at)
      END,
      delivery_attempts = CASE
        WHEN delivery.expires_at <= claimed_at_time
          THEN delivery.delivery_attempts
        ELSE delivery.delivery_attempts + 1
      END,
      delivered_at = NULL,
      cancelled_at = CASE
        WHEN delivery.expires_at <= claimed_at_time THEN claimed_at_time
        ELSE NULL
      END,
      cancellation_reason = CASE
        WHEN delivery.expires_at <= claimed_at_time THEN 'expired'
        ELSE NULL
      END
  WHERE delivery.id = candidate_id
  RETURNING delivery.*;
END
$function$;

-- The accepted 0006 validator is replaced forward-only before any email
-- runtime credential exists. The owner remains roomscan_policy.
RESET ROLE;
CREATE OR REPLACE FUNCTION roomscan.validate_magic_delivery(
  requested_id text,
  requested_lease_id text,
  checked_at_time timestamptz
)
RETURNS SETOF roomscan.magic_link_delivery_outbox
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  IF requested_id IS NULL OR requested_lease_id IS NULL
    OR checked_at_time IS NULL
    OR length(requested_id) NOT BETWEEN 16 AND 128
    OR length(requested_lease_id) NOT BETWEEN 1 AND 128 THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023', MESSAGE = 'INVALID_MAGIC_DELIVERY_LEASE';
  END IF;

  RETURN QUERY
  UPDATE roomscan.magic_link_delivery_outbox AS delivery
  SET state = 'expired', lease_id = NULL, lease_expires_at = NULL,
      cancelled_at = checked_at_time, cancellation_reason = 'expired'
  FROM roomscan.magic_links AS link
  WHERE delivery.id = requested_id
    AND delivery.selector = link.selector
    AND delivery.state = 'leased'
    AND delivery.lease_id = requested_lease_id
    AND (delivery.expires_at <= checked_at_time
      OR link.expires_at <= checked_at_time)
  RETURNING delivery.*;
  IF FOUND THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT delivery.*
  FROM roomscan.magic_link_delivery_outbox AS delivery
  JOIN roomscan.magic_links AS link ON link.selector = delivery.selector
  JOIN roomscan.global_operational_flags AS sign_in_flag
    ON sign_in_flag.flag_key = 'professional_sign_in_enabled'
   AND sign_in_flag.enabled IS TRUE
   AND sign_in_flag.version > 0
  WHERE delivery.id = requested_id
    AND delivery.state = 'leased'
    AND delivery.lease_id = requested_lease_id
    AND delivery.lease_expires_at > checked_at_time
    AND delivery.expires_at > checked_at_time
    AND link.state = 'active'
    AND link.expires_at > checked_at_time;
END
$function$;
SET ROLE roomscan_owner;

CREATE FUNCTION roomscan.logout_from_access(
  access_token_hash bytea,
  revoked_at_time timestamptz,
  reason_code text
)
RETURNS TABLE (
  status text,
  principal_id uuid,
  principal_canonical_id text,
  family_id uuid,
  family_public_id text
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  target_access roomscan.auth_access_tokens%ROWTYPE;
  target_family roomscan.auth_session_families%ROWTYPE;
  canonical text;
BEGIN
  IF access_token_hash IS NULL OR revoked_at_time IS NULL OR reason_code IS NULL
    OR octet_length(access_token_hash) <> 32
    OR reason_code NOT IN ('logout', 'logout_all', 'membership_changed', 'identity_changed') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_ACCESS_LOGOUT';
  END IF;

  SELECT access.* INTO target_access
  FROM roomscan.auth_access_tokens AS access
  WHERE access.token_hash = access_token_hash
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'unavailable'::text, NULL::uuid, NULL::text, NULL::uuid, NULL::text;
    RETURN;
  END IF;

  SELECT family.* INTO target_family
  FROM roomscan.auth_session_families AS family
  WHERE family.id = target_access.family_id
  FOR UPDATE;
  SELECT principal.canonical_id INTO canonical
  FROM roomscan.principals AS principal
  WHERE principal.id = target_access.principal_id;

  IF target_family.state = 'active' THEN
    UPDATE roomscan.auth_session_families AS family
    SET state = 'revoked', revoked_at = revoked_at_time, revoke_reason = reason_code
    WHERE family.id = target_family.id AND family.state = 'active';
    UPDATE roomscan.auth_access_tokens AS access
    SET state = 'revoked', revoked_at = revoked_at_time
    WHERE access.family_id = target_family.id AND access.state = 'active';
    RETURN QUERY SELECT 'revoked'::text, target_access.principal_id, canonical,
      target_family.id, target_family.public_id;
  ELSE
    RETURN QUERY SELECT 'already_revoked'::text, target_access.principal_id, canonical,
      target_family.id, target_family.public_id;
  END IF;
END
$function$;

CREATE FUNCTION roomscan.touch_session_from_access(
  access_token_hash bytea,
  authoritative_time timestamptz,
  last_used_at_time timestamptz,
  inactivity_expires_at_time timestamptz
)
RETURNS TABLE (
  status text,
  principal_id uuid,
  principal_canonical_id text,
  family_id uuid,
  family_public_id text,
  last_used_at timestamptz,
  inactivity_expires_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  context_row record;
  updated_family roomscan.auth_session_families%ROWTYPE;
BEGIN
  IF access_token_hash IS NULL OR authoritative_time IS NULL
    OR last_used_at_time IS NULL OR inactivity_expires_at_time IS NULL
    OR octet_length(access_token_hash) <> 32
    OR last_used_at_time > authoritative_time
    OR last_used_at_time >= inactivity_expires_at_time THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_SESSION_TOUCH';
  END IF;

  SELECT * INTO context_row
  FROM roomscan.resolve_access_context(access_token_hash, authoritative_time);
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'unavailable'::text, NULL::uuid, NULL::text, NULL::uuid,
      NULL::text, NULL::timestamptz, NULL::timestamptz;
    RETURN;
  END IF;

  UPDATE roomscan.auth_session_families AS family
  SET last_used_at = last_used_at_time,
      inactivity_expires_at = inactivity_expires_at_time
  WHERE family.id = context_row.family_id
    AND family.state = 'active'
    AND last_used_at_time >= family.last_used_at
    AND inactivity_expires_at_time <= family.absolute_expires_at
  RETURNING family.* INTO updated_family;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'stale'::text, context_row.principal_id,
      context_row.canonical_principal_id, context_row.family_id,
      context_row.family_public_id, NULL::timestamptz, NULL::timestamptz;
    RETURN;
  END IF;
  RETURN QUERY SELECT 'updated'::text, context_row.principal_id,
    context_row.canonical_principal_id, updated_family.id,
    updated_family.public_id, updated_family.last_used_at,
    updated_family.inactivity_expires_at;
END
$function$;

CREATE FUNCTION roomscan.consume_apple_bridge_and_issue_session(
  bridge_proof_hash bytea,
  requested_family_public_id text,
  access_token_hash bytea,
  refresh_token_hash bytea,
  authenticated_at_time timestamptz,
  issued_at_time timestamptz,
  access_expires_at_time timestamptz,
  inactivity_expires_at_time timestamptz,
  absolute_expires_at_time timestamptz,
  requested_policy_version text
)
RETURNS TABLE (
  status text,
  principal_id uuid,
  principal_canonical_id text,
  family_id uuid,
  family_public_id text,
  authentication_epoch bigint,
  authenticated_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  proof roomscan.apple_bridge_proofs%ROWTYPE;
  target_principal_id uuid;
  target_canonical_id text;
  target_epoch bigint;
  target_workspace_id uuid;
  target_role text;
  target_authorization_version bigint;
  active_membership_count integer;
  new_family_id uuid := gen_random_uuid();
  claimed_identity_principal_id uuid;
BEGIN
  IF bridge_proof_hash IS NULL OR requested_family_public_id IS NULL
    OR access_token_hash IS NULL OR refresh_token_hash IS NULL
    OR authenticated_at_time IS NULL OR issued_at_time IS NULL
    OR access_expires_at_time IS NULL OR inactivity_expires_at_time IS NULL
    OR absolute_expires_at_time IS NULL OR requested_policy_version IS NULL
    OR octet_length(bridge_proof_hash) <> 32
    OR octet_length(access_token_hash) <> 32
    OR octet_length(refresh_token_hash) <> 32
    OR length(requested_family_public_id) NOT BETWEEN 16 AND 128
    OR requested_family_public_id !~ '^[A-Za-z0-9_-]+$'
    OR length(requested_policy_version) NOT BETWEEN 1 AND 64
    OR authenticated_at_time > issued_at_time
    OR issued_at_time >= access_expires_at_time
    OR issued_at_time >= inactivity_expires_at_time
    OR inactivity_expires_at_time > absolute_expires_at_time THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_APPLE_SESSION_ISSUANCE';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM roomscan.global_operational_flags AS flag
    WHERE flag.flag_key = 'professional_sign_in_enabled'
      AND flag.enabled IS TRUE
      AND flag.version > 0
  ) THEN
    RETURN QUERY SELECT 'professional_sign_in_disabled'::text,
      NULL::uuid, NULL::text, NULL::uuid, NULL::text,
      NULL::bigint, NULL::timestamptz;
    RETURN;
  END IF;

  SELECT candidate.* INTO proof
  FROM roomscan.apple_bridge_proofs AS candidate
  WHERE candidate.token_hash = bridge_proof_hash
  FOR UPDATE;
  IF NOT FOUND OR proof.state <> 'active' OR proof.expires_at <= issued_at_time
    OR proof.purpose <> 'sign-in' THEN
    RETURN QUERY SELECT 'unavailable'::text, NULL::uuid, NULL::text, NULL::uuid,
      NULL::text, NULL::bigint, NULL::timestamptz;
    RETURN;
  END IF;

  BEGIN
  -- Use the same issuer/subject arbitration key and order as explicit
  -- identity mutation. Distinct valid proofs may proceed serially, while a
  -- stale RR/SERIALIZABLE snapshot receives a controlled whole-tx retry.
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    proof.issuer || E'\\000' || proof.subject, 7621846213719043
  ));

  SELECT identity.principal_id, principal.canonical_id,
         principal.authentication_epoch
  INTO target_principal_id, target_canonical_id, target_epoch
  FROM roomscan.external_identities AS identity
  JOIN roomscan.principals AS principal ON principal.id = identity.principal_id
  WHERE identity.issuer = proof.issuer AND identity.subject = proof.subject
    AND principal.state = 'active'
  FOR UPDATE OF principal;

  IF target_principal_id IS NULL THEN
    target_principal_id := gen_random_uuid();
    target_canonical_id := 'prn_' || replace(gen_random_uuid()::text, '-', '');
    target_epoch := 0;
    INSERT INTO roomscan.principals (
      id, canonical_id, authentication_epoch, created_at, updated_at
    ) VALUES (
      target_principal_id, target_canonical_id, target_epoch,
      issued_at_time, issued_at_time
    );
    BEGIN
      INSERT INTO roomscan.external_identities AS claimed_identity (
        id, principal_id, issuer, subject, linked_at, created_at
      ) VALUES (
        gen_random_uuid(), target_principal_id, proof.issuer, proof.subject,
        authenticated_at_time, issued_at_time
      )
      ON CONFLICT (issuer, subject) DO NOTHING
      RETURNING claimed_identity.principal_id INTO claimed_identity_principal_id;
    EXCEPTION WHEN serialization_failure THEN
      RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'APPLE_IDENTITY_RETRY_REQUIRED';
    END;
    IF claimed_identity_principal_id IS NULL THEN
      RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'APPLE_IDENTITY_RETRY_REQUIRED';
    END IF;
  END IF;
  EXCEPTION WHEN serialization_failure THEN
    RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'APPLE_IDENTITY_RETRY_REQUIRED';
  END;

  PERFORM 1
  FROM roomscan.memberships AS membership
  WHERE membership.principal_id = target_principal_id
    AND membership.state = 'active'
  FOR SHARE;
  SELECT count(*)::integer INTO active_membership_count
  FROM roomscan.memberships AS membership
  WHERE membership.principal_id = target_principal_id
    AND membership.state = 'active';
  IF active_membership_count = 1 THEN
    SELECT membership.workspace_id, membership.role,
      membership.authorization_version
    INTO target_workspace_id, target_role, target_authorization_version
    FROM roomscan.memberships AS membership
    WHERE membership.principal_id = target_principal_id
      AND membership.state = 'active';
  END IF;

  INSERT INTO roomscan.auth_session_families (
    id, public_id, principal_id, authentication_epoch, authenticated_at,
    last_used_at, inactivity_expires_at, absolute_expires_at, policy_version,
    workspace_id, role, authorization_version, state, created_at
  ) VALUES (
    new_family_id, requested_family_public_id, target_principal_id,
    target_epoch, authenticated_at_time, issued_at_time,
    inactivity_expires_at_time, absolute_expires_at_time,
    requested_policy_version, target_workspace_id, target_role,
    target_authorization_version, 'active', issued_at_time
  );
  INSERT INTO roomscan.auth_access_tokens (
    id, family_id, token_hash, expires_at, principal_id,
    authentication_epoch, authenticated_at, issued_at,
    workspace_id, role, authorization_version, state, created_at
  ) VALUES (
    gen_random_uuid(), new_family_id, access_token_hash,
    access_expires_at_time, target_principal_id, target_epoch,
    authenticated_at_time, issued_at_time, target_workspace_id, target_role,
    target_authorization_version, 'active', issued_at_time
  );
  INSERT INTO roomscan.auth_refresh_tokens (token_hash, family_id, issued_at)
  VALUES (refresh_token_hash, new_family_id, issued_at_time);
  UPDATE roomscan.apple_bridge_proofs AS candidate
  SET state = 'consumed', consumed_at = issued_at_time
  WHERE candidate.token_hash = bridge_proof_hash AND candidate.state = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'APPLE_BRIDGE_CONSUME_RACE';
  END IF;

  RETURN QUERY SELECT 'issued'::text, target_principal_id,
    target_canonical_id, new_family_id, requested_family_public_id,
    target_epoch, authenticated_at_time;
END
$function$;

CREATE FUNCTION roomscan.accept_provider_audit_event(
  requested_id text,
  requested_provider_lane text,
  requested_event_code text,
  requested_bounded_reference text,
  occurred_at_time timestamptz
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  existing roomscan.provider_audit_outbox%ROWTYPE;
  inserted roomscan.provider_audit_outbox%ROWTYPE;
BEGIN
  IF requested_id IS NULL OR requested_provider_lane IS NULL
    OR requested_event_code IS NULL OR requested_bounded_reference IS NULL
    OR occurred_at_time IS NULL
    OR length(requested_id) NOT BETWEEN 16 AND 128
    OR requested_id !~ '^paud_[A-Za-z0-9_-]+$'
    OR requested_provider_lane NOT IN ('email', 'stripe')
    OR requested_event_code NOT IN (
      'email.delivery.accepted', 'email.delivery.failed',
      'stripe.webhook.accepted', 'stripe.webhook.duplicate'
    )
    OR length(requested_bounded_reference) NOT BETWEEN 1 AND 128
    OR requested_bounded_reference !~ '^[A-Za-z0-9._:-]+$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROVIDER_AUDIT_EVENT';
  END IF;

  IF session_user = 'roomscan_stripe_ingress_runtime' THEN
    IF requested_provider_lane IS DISTINCT FROM 'stripe'
      OR requested_event_code NOT IN (
        'stripe.webhook.accepted', 'stripe.webhook.duplicate'
      ) THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROVIDER_AUDIT_EVENT';
    END IF;
  ELSIF session_user = 'roomscan_email_delivery_runtime' THEN
    IF requested_provider_lane IS DISTINCT FROM 'email'
      OR requested_event_code NOT IN (
        'email.delivery.accepted', 'email.delivery.failed'
      ) THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROVIDER_AUDIT_EVENT';
    END IF;
  ELSE
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROVIDER_AUDIT_LANE_DENIED';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('provider-audit:' || requested_id, 7621846213719047)
  );
  -- The unique index, rather than snapshot visibility, arbitrates the ID.
  -- A conflicting row that is outside an RR/SERIALIZABLE snapshot is a
  -- controlled retry, never an incidental 23505 or an ambiguous duplicate.
  BEGIN
    INSERT INTO roomscan.provider_audit_outbox (
      id, provider_lane, event_code, bounded_reference, occurred_at
    ) VALUES (
      requested_id, requested_provider_lane, requested_event_code,
      requested_bounded_reference, occurred_at_time
    )
    ON CONFLICT (id) DO NOTHING
    RETURNING * INTO inserted;
  EXCEPTION WHEN serialization_failure THEN
    RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'PROVIDER_AUDIT_RETRY_REQUIRED';
  END;
  IF inserted.id IS NOT NULL THEN
    RETURN true;
  END IF;

  SELECT event.* INTO existing
  FROM roomscan.provider_audit_outbox AS event
  WHERE event.id = requested_id;
  IF FOUND THEN
    IF existing.provider_lane IS DISTINCT FROM requested_provider_lane
      OR existing.event_code IS DISTINCT FROM requested_event_code
      OR existing.bounded_reference IS DISTINCT FROM requested_bounded_reference THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROVIDER_AUDIT_ID_REUSED';
    END IF;
    RETURN false;
  END IF;
  RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'PROVIDER_AUDIT_RETRY_REQUIRED';
END
$function$;

CREATE FUNCTION roomscan.claim_provider_audit_event(
  requested_lease_id text,
  claimed_at_time timestamptz,
  requested_lease_expires_at timestamptz
)
RETURNS SETOF roomscan.provider_audit_outbox
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  IF requested_lease_id IS NULL OR claimed_at_time IS NULL
    OR requested_lease_expires_at IS NULL
    OR length(requested_lease_id) NOT BETWEEN 1 AND 128
    OR requested_lease_expires_at <= claimed_at_time THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROVIDER_AUDIT_LEASE';
  END IF;
  RETURN QUERY
  UPDATE roomscan.provider_audit_outbox AS outbox
  SET state = 'leased', lease_id = requested_lease_id,
      lease_expires_at = requested_lease_expires_at,
      delivery_attempts = outbox.delivery_attempts + 1
  WHERE outbox.id = (
    SELECT candidate.id
    FROM roomscan.provider_audit_outbox AS candidate
    WHERE candidate.state = 'pending'
      OR (candidate.state = 'leased' AND candidate.lease_expires_at <= claimed_at_time)
    ORDER BY candidate.occurred_at, candidate.id
    FOR UPDATE SKIP LOCKED LIMIT 1
  )
  RETURNING outbox.*;
END
$function$;

CREATE FUNCTION roomscan.complete_provider_audit_event(
  requested_id text,
  requested_lease_id text,
  delivered_at_time timestamptz
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  IF requested_id IS NULL OR requested_lease_id IS NULL OR delivered_at_time IS NULL
    OR length(requested_id) NOT BETWEEN 16 AND 128
    OR length(requested_lease_id) NOT BETWEEN 1 AND 128 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROVIDER_AUDIT_COMPLETION';
  END IF;
  UPDATE roomscan.provider_audit_outbox AS outbox
  SET state = 'delivered', lease_id = NULL, lease_expires_at = NULL,
      delivered_at = delivered_at_time
  WHERE outbox.id = requested_id AND outbox.state = 'leased'
    AND outbox.lease_id = requested_lease_id
    AND outbox.lease_expires_at > delivered_at_time;
  RETURN FOUND;
END
$function$;

CREATE FUNCTION roomscan.release_provider_audit_event(
  requested_id text,
  requested_lease_id text,
  released_at_time timestamptz
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  IF requested_id IS NULL OR requested_lease_id IS NULL OR released_at_time IS NULL
    OR length(requested_id) NOT BETWEEN 16 AND 128
    OR length(requested_lease_id) NOT BETWEEN 1 AND 128 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PROVIDER_AUDIT_RELEASE';
  END IF;
  UPDATE roomscan.provider_audit_outbox AS outbox
  SET state = 'pending', lease_id = NULL, lease_expires_at = NULL
  WHERE outbox.id = requested_id AND outbox.state = 'leased'
    AND outbox.lease_id = requested_lease_id
    AND outbox.lease_expires_at > released_at_time;
  RETURN FOUND;
END
$function$;

RESET ROLE;

-- Section B: versioned membership, default-off operational state, and the
-- publication policy boundary.
SET ROLE roomscan_owner;

ALTER TABLE roomscan.workspaces
  ADD COLUMN bootstrap_family_id uuid;
CREATE UNIQUE INDEX workspaces_bootstrap_family_unique
  ON roomscan.workspaces (bootstrap_family_id)
  WHERE bootstrap_family_id IS NOT NULL;

ALTER TABLE roomscan.invitations
  ADD COLUMN public_id text NOT NULL DEFAULT (
    'inv_' || encode(gen_random_bytes(16), 'hex')
  ),
  ADD COLUMN state text NOT NULL DEFAULT 'active',
  ADD COLUMN version bigint NOT NULL DEFAULT 1,
  ADD COLUMN revoked_at timestamptz,
  ADD COLUMN updated_at timestamptz NOT NULL DEFAULT clock_timestamp();
UPDATE roomscan.invitations
SET state = CASE WHEN consumed_at IS NULL THEN 'active' ELSE 'consumed' END;
ALTER TABLE roomscan.invitations
  ADD CONSTRAINT invitations_public_id_format CHECK (
    public_id ~ '^inv_[A-Za-z0-9_-]{16,128}$'
  ),
  ADD CONSTRAINT invitations_public_id_unique UNIQUE (public_id),
  ADD CONSTRAINT invitations_version_positive CHECK (version > 0),
  ADD CONSTRAINT invitations_v2_state CHECK (
    (state = 'active' AND consumed_at IS NULL AND consumed_by_principal_id IS NULL AND revoked_at IS NULL)
    OR (state = 'consumed' AND consumed_at IS NOT NULL AND consumed_by_principal_id IS NOT NULL AND revoked_at IS NULL)
    OR (state = 'revoked' AND consumed_at IS NULL AND consumed_by_principal_id IS NULL AND revoked_at IS NOT NULL)
  );

ALTER TABLE roomscan.audit_events
  ADD COLUMN event_id text NOT NULL DEFAULT (
    'aud_' || encode(gen_random_bytes(16), 'hex')
  ),
  ADD COLUMN authorization_version bigint;
ALTER TABLE roomscan.audit_events
  ADD CONSTRAINT audit_events_event_id_format CHECK (
    event_id ~ '^aud_[A-Za-z0-9_-]{16,128}$'
  ),
  ADD CONSTRAINT audit_events_event_id_unique UNIQUE (event_id),
  ADD CONSTRAINT audit_events_authz_positive CHECK (
    authorization_version IS NULL OR authorization_version > 0
  );

CREATE TABLE roomscan.member_slots (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE CASCADE,
  principal_id uuid NOT NULL REFERENCES roomscan.principals(id) ON DELETE CASCADE,
  acquired_at timestamptz NOT NULL,
  PRIMARY KEY (workspace_id, principal_id),
  FOREIGN KEY (workspace_id, principal_id)
    REFERENCES roomscan.memberships(workspace_id, principal_id) ON DELETE CASCADE
);
ALTER TABLE roomscan.member_slots ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.member_slots FORCE ROW LEVEL SECURITY;
CREATE POLICY member_slots_tenant_isolation ON roomscan.member_slots
  FOR ALL TO PUBLIC
  USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));
INSERT INTO roomscan.member_slots (workspace_id, principal_id, acquired_at)
SELECT membership.workspace_id, membership.principal_id, membership.updated_at
FROM roomscan.memberships AS membership
WHERE membership.state = 'active';

CREATE TABLE roomscan.global_operational_flags (
  flag_key text PRIMARY KEY CHECK (
    flag_key IN (
      'professional_sign_in_enabled',
      'hosted_operations_enabled',
      'publication_enabled'
    )
  ),
  enabled boolean NOT NULL,
  version bigint NOT NULL CHECK (version > 0),
  reason text NOT NULL CHECK (length(reason) BETWEEN 1 AND 256),
  updated_at timestamptz NOT NULL
);

CREATE TABLE roomscan.workspace_operational_flags (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE CASCADE,
  flag_key text NOT NULL CHECK (
    flag_key IN (
      'professional_sign_in_enabled',
      'hosted_operations_enabled',
      'publication_enabled'
    )
  ),
  enabled boolean NOT NULL,
  version bigint NOT NULL CHECK (version > 0),
  reason text NOT NULL CHECK (length(reason) BETWEEN 1 AND 256),
  updated_at timestamptz NOT NULL,
  PRIMARY KEY (workspace_id, flag_key)
);
ALTER TABLE roomscan.workspace_operational_flags ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.workspace_operational_flags FORCE ROW LEVEL SECURITY;
CREATE POLICY workspace_operational_flags_tenant_isolation
  ON roomscan.workspace_operational_flags
  FOR ALL TO PUBLIC
  USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));

CREATE TABLE roomscan.workspace_publishing_policies (
  workspace_id uuid PRIMARY KEY REFERENCES roomscan.workspaces(id) ON DELETE CASCADE,
  editor_publishing_allowed boolean NOT NULL,
  version bigint NOT NULL CHECK (version > 0),
  updated_at timestamptz NOT NULL
);
ALTER TABLE roomscan.workspace_publishing_policies ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.workspace_publishing_policies FORCE ROW LEVEL SECURITY;
CREATE POLICY workspace_publishing_policies_tenant_isolation
  ON roomscan.workspace_publishing_policies
  FOR ALL TO PUBLIC
  USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));

CREATE TABLE roomscan.operational_flag_audit_events (
  id text PRIMARY KEY CHECK (
    length(id) BETWEEN 16 AND 128 AND id ~ '^ofaud_[A-Za-z0-9_-]+$'
  ),
  scope_kind text NOT NULL CHECK (scope_kind IN ('global', 'workspace', 'publishing-policy')),
  workspace_id uuid REFERENCES roomscan.workspaces(id) ON DELETE RESTRICT,
  flag_key text NOT NULL CHECK (length(flag_key) BETWEEN 1 AND 128),
  enabled boolean NOT NULL,
  version bigint NOT NULL CHECK (version > 0),
  reason text NOT NULL CHECK (length(reason) BETWEEN 1 AND 256),
  occurred_at timestamptz NOT NULL,
  CHECK (
    (scope_kind = 'global' AND workspace_id IS NULL)
    OR (scope_kind IN ('workspace', 'publishing-policy') AND workspace_id IS NOT NULL)
  )
);

CREATE FUNCTION roomscan.sync_active_member_slot()
RETURNS trigger
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  IF TG_OP <> 'DELETE' AND NEW.state = 'active' THEN
    INSERT INTO roomscan.member_slots (workspace_id, principal_id, acquired_at)
    VALUES (NEW.workspace_id, NEW.principal_id, NEW.updated_at)
    ON CONFLICT (workspace_id, principal_id) DO NOTHING;
  ELSE
    DELETE FROM roomscan.member_slots AS slot
    WHERE slot.workspace_id = OLD.workspace_id
      AND slot.principal_id = OLD.principal_id;
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END
$function$;
CREATE TRIGGER memberships_sync_active_slot
AFTER INSERT OR UPDATE OF state OR DELETE ON roomscan.memberships
FOR EACH ROW EXECUTE FUNCTION roomscan.sync_active_member_slot();

CREATE FUNCTION roomscan.set_operational_flag(
  requested_scope_kind text,
  requested_workspace_id uuid,
  requested_flag_key text,
  requested_enabled boolean,
  expected_version bigint,
  requested_reason text,
  requested_audit_id text,
  occurred_at_time timestamptz
)
RETURNS TABLE (enabled boolean, version bigint)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  current_version bigint;
  next_version bigint;
BEGIN
  IF requested_scope_kind IS NULL OR requested_flag_key IS NULL
    OR requested_enabled IS NULL OR requested_reason IS NULL
    OR requested_audit_id IS NULL OR occurred_at_time IS NULL
    OR requested_scope_kind NOT IN ('global', 'workspace')
    OR requested_flag_key NOT IN (
      'professional_sign_in_enabled', 'hosted_operations_enabled', 'publication_enabled'
    )
    OR length(requested_reason) NOT BETWEEN 1 AND 256
    OR length(requested_audit_id) NOT BETWEEN 16 AND 128
    OR requested_audit_id !~ '^ofaud_[A-Za-z0-9_-]+$'
    OR (requested_scope_kind = 'global' AND requested_workspace_id IS NOT NULL)
    OR (requested_scope_kind = 'workspace' AND requested_workspace_id IS NULL)
    OR (expected_version IS NOT NULL AND expected_version < 1) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_OPERATIONAL_FLAG_MUTATION';
  END IF;

  IF requested_scope_kind = 'global' THEN
    SELECT flag.version INTO current_version
    FROM roomscan.global_operational_flags AS flag
    WHERE flag.flag_key = requested_flag_key
    FOR UPDATE;
    IF FOUND IS DISTINCT FROM (expected_version IS NOT NULL) THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'OPERATIONAL_FLAG_VERSION_CONFLICT';
    END IF;
    IF current_version IS NOT NULL AND current_version IS DISTINCT FROM expected_version THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'OPERATIONAL_FLAG_VERSION_CONFLICT';
    END IF;
    next_version := COALESCE(current_version, 0) + 1;
    INSERT INTO roomscan.global_operational_flags (
      flag_key, enabled, version, reason, updated_at
    ) VALUES (
      requested_flag_key, requested_enabled, next_version,
      requested_reason, occurred_at_time
    ) ON CONFLICT (flag_key) DO UPDATE
      SET enabled = EXCLUDED.enabled, version = EXCLUDED.version,
          reason = EXCLUDED.reason, updated_at = EXCLUDED.updated_at;
  ELSE
    PERFORM 1 FROM roomscan.workspaces WHERE id = requested_workspace_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'UNKNOWN_WORKSPACE';
    END IF;
    SELECT flag.version INTO current_version
    FROM roomscan.workspace_operational_flags AS flag
    WHERE flag.workspace_id = requested_workspace_id
      AND flag.flag_key = requested_flag_key
    FOR UPDATE;
    IF FOUND IS DISTINCT FROM (expected_version IS NOT NULL) THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'OPERATIONAL_FLAG_VERSION_CONFLICT';
    END IF;
    IF current_version IS NOT NULL AND current_version IS DISTINCT FROM expected_version THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'OPERATIONAL_FLAG_VERSION_CONFLICT';
    END IF;
    next_version := COALESCE(current_version, 0) + 1;
    INSERT INTO roomscan.workspace_operational_flags (
      workspace_id, flag_key, enabled, version, reason, updated_at
    ) VALUES (
      requested_workspace_id, requested_flag_key, requested_enabled,
      next_version, requested_reason, occurred_at_time
    ) ON CONFLICT (workspace_id, flag_key) DO UPDATE
      SET enabled = EXCLUDED.enabled, version = EXCLUDED.version,
          reason = EXCLUDED.reason, updated_at = EXCLUDED.updated_at;
  END IF;

  INSERT INTO roomscan.operational_flag_audit_events (
    id, scope_kind, workspace_id, flag_key, enabled, version, reason, occurred_at
  ) VALUES (
    requested_audit_id, requested_scope_kind, requested_workspace_id,
    requested_flag_key, requested_enabled, next_version,
    requested_reason, occurred_at_time
  );
  RETURN QUERY SELECT requested_enabled, next_version;
END
$function$;

CREATE FUNCTION roomscan.set_workspace_publishing_policy(
  requested_workspace_id uuid,
  requested_editor_publishing_allowed boolean,
  expected_version bigint,
  requested_reason text,
  requested_audit_id text,
  occurred_at_time timestamptz
)
RETURNS TABLE (editor_publishing_allowed boolean, version bigint)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  current_version bigint;
  next_version bigint;
BEGIN
  IF requested_workspace_id IS NULL OR requested_editor_publishing_allowed IS NULL
    OR requested_reason IS NULL OR requested_audit_id IS NULL OR occurred_at_time IS NULL
    OR length(requested_reason) NOT BETWEEN 1 AND 256
    OR length(requested_audit_id) NOT BETWEEN 16 AND 128
    OR requested_audit_id !~ '^ofaud_[A-Za-z0-9_-]+$'
    OR (expected_version IS NOT NULL AND expected_version < 1) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PUBLISHING_POLICY_MUTATION';
  END IF;
  PERFORM 1 FROM roomscan.workspaces WHERE id = requested_workspace_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'UNKNOWN_WORKSPACE';
  END IF;
  SELECT policy.version INTO current_version
  FROM roomscan.workspace_publishing_policies AS policy
  WHERE policy.workspace_id = requested_workspace_id
  FOR UPDATE;
  IF FOUND IS DISTINCT FROM (expected_version IS NOT NULL)
    OR (current_version IS NOT NULL AND current_version IS DISTINCT FROM expected_version) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PUBLISHING_POLICY_VERSION_CONFLICT';
  END IF;
  next_version := COALESCE(current_version, 0) + 1;
  INSERT INTO roomscan.workspace_publishing_policies (
    workspace_id, editor_publishing_allowed, version, updated_at
  ) VALUES (
    requested_workspace_id, requested_editor_publishing_allowed,
    next_version, occurred_at_time
  ) ON CONFLICT (workspace_id) DO UPDATE
    SET editor_publishing_allowed = EXCLUDED.editor_publishing_allowed,
        version = EXCLUDED.version, updated_at = EXCLUDED.updated_at;
  INSERT INTO roomscan.operational_flag_audit_events (
    id, scope_kind, workspace_id, flag_key, enabled, version, reason, occurred_at
  ) VALUES (
    requested_audit_id, 'publishing-policy', requested_workspace_id,
    'editor_publishing_allowed', requested_editor_publishing_allowed,
    next_version, requested_reason, occurred_at_time
  );
  RETURN QUERY SELECT requested_editor_publishing_allowed, next_version;
END
$function$;

CREATE FUNCTION roomscan.read_global_operational_flag(requested_flag_key text)
RETURNS TABLE (enabled boolean, version bigint)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
  SELECT flag.enabled, flag.version
  FROM roomscan.global_operational_flags AS flag
  WHERE requested_flag_key IN (
      'professional_sign_in_enabled', 'hosted_operations_enabled', 'publication_enabled'
    )
    AND flag.flag_key = requested_flag_key
$function$;

CREATE FUNCTION roomscan.read_workspace_operational_flag(
  access_token_hash bytea,
  authoritative_time timestamptz,
  requested_flag_key text
)
RETURNS TABLE (workspace_id uuid, enabled boolean, version bigint)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  context_row record;
BEGIN
  IF access_token_hash IS NULL OR authoritative_time IS NULL OR requested_flag_key IS NULL
    OR octet_length(access_token_hash) <> 32
    OR requested_flag_key NOT IN (
      'professional_sign_in_enabled', 'hosted_operations_enabled', 'publication_enabled'
    ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_WORKSPACE_FLAG_READ';
  END IF;
  SELECT * INTO context_row
  FROM roomscan.resolve_access_context(access_token_hash, authoritative_time);
  IF NOT FOUND OR context_row.workspace_id IS NULL THEN RETURN; END IF;
  RETURN QUERY
  SELECT context_row.workspace_id, flag.enabled, flag.version
  FROM roomscan.workspace_operational_flags AS flag
  WHERE flag.workspace_id = context_row.workspace_id
    AND flag.flag_key = requested_flag_key;
END
$function$;

CREATE FUNCTION roomscan.bootstrap_workspace_v2(
  access_token_hash bytea,
  authoritative_time timestamptz,
  requested_slug text,
  requested_display_name text,
  requested_audit_event_id text
)
RETURNS TABLE (
  workspace_id uuid,
  membership_id uuid,
  principal_id uuid,
  principal_canonical_id text,
  family_id uuid,
  family_public_id text,
  authorization_version bigint
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  context_row record;
  created_workspace_id uuid := gen_random_uuid();
  created_membership_id uuid := gen_random_uuid();
  replay_workspace_id uuid;
  replay_membership_id uuid;
BEGIN
  IF access_token_hash IS NULL OR authoritative_time IS NULL
    OR requested_slug IS NULL OR requested_display_name IS NULL
    OR requested_audit_event_id IS NULL OR octet_length(access_token_hash) <> 32
    OR requested_slug !~ '^[a-z0-9][a-z0-9-]{2,62}$'
    OR length(requested_display_name) NOT BETWEEN 1 AND 160
    OR requested_audit_event_id !~ '^aud_[A-Za-z0-9_-]{16,128}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_WORKSPACE_BOOTSTRAP_V2';
  END IF;

  PERFORM 1 FROM roomscan.global_operational_flags AS flag
  WHERE flag.flag_key = 'professional_sign_in_enabled'
    AND flag.enabled IS TRUE AND flag.version > 0
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROFESSIONAL_SIGN_IN_DISABLED';
  END IF;
  PERFORM 1 FROM roomscan.global_operational_flags AS flag
  WHERE flag.flag_key = 'hosted_operations_enabled'
    AND flag.enabled IS TRUE AND flag.version > 0
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'HOSTED_OPERATIONS_DISABLED';
  END IF;

  -- The principal lock serializes bootstrap attempts from different session
  -- families. The access/family locks make exact replay and scoping atomic.
  PERFORM 1
  FROM roomscan.auth_access_tokens AS access
  JOIN roomscan.auth_session_families AS family ON family.id = access.family_id
  JOIN roomscan.principals AS principal ON principal.id = family.principal_id
  WHERE access.token_hash = access_token_hash
    AND access.state = 'active' AND family.state = 'active'
    AND principal.state = 'active'
  FOR UPDATE OF access, family, principal;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'UNSCOPED_ACCESS_REQUIRED';
  END IF;

  SELECT * INTO context_row
  FROM roomscan.resolve_access_context(access_token_hash, authoritative_time);
  IF NOT FOUND OR context_row.recent_authentication IS DISTINCT FROM true THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'UNSCOPED_ACCESS_REQUIRED';
  END IF;

  IF context_row.workspace_id IS NOT NULL THEN
    SELECT workspace.id, membership.id
      INTO replay_workspace_id, replay_membership_id
    FROM roomscan.workspaces AS workspace
    JOIN roomscan.memberships AS membership
      ON membership.workspace_id = workspace.id
     AND membership.principal_id = context_row.principal_id
    JOIN roomscan.audit_events AS audit
      ON audit.workspace_id = workspace.id
     AND audit.event_id = requested_audit_event_id
    WHERE workspace.id = context_row.workspace_id
      AND workspace.bootstrap_family_id = context_row.family_id
      AND workspace.slug = requested_slug
      AND workspace.display_name = requested_display_name
      AND membership.state = 'active' AND membership.role = 'owner'
      AND membership.authorization_version = context_row.authorization_version
      AND audit.actor_principal_id = context_row.principal_id
      AND audit.action = 'workspace.created'
      AND audit.subject_kind = 'workspace'
      AND audit.subject_id = workspace.id::text;
    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'WORKSPACE_ALREADY_SCOPED';
    END IF;
    RETURN QUERY SELECT replay_workspace_id, replay_membership_id,
      context_row.principal_id, context_row.canonical_principal_id,
      context_row.family_id, context_row.family_public_id,
      context_row.authorization_version;
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM roomscan.memberships AS membership
    WHERE membership.principal_id = context_row.principal_id
      AND membership.state IN ('active', 'invited')
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'EXISTING_MEMBERSHIP_REQUIRES_ACTIVATION';
  END IF;

  INSERT INTO roomscan.workspaces (
    id, slug, display_name, bootstrap_family_id, created_at, updated_at
  ) VALUES (
    created_workspace_id, requested_slug, requested_display_name,
    context_row.family_id, authoritative_time, authoritative_time
  );
  INSERT INTO roomscan.memberships (
    id, workspace_id, principal_id, role, state, authorization_version,
    created_at, updated_at
  ) VALUES (
    created_membership_id, created_workspace_id, context_row.principal_id,
    'owner', 'active', 1, authoritative_time, authoritative_time
  );
  IF NOT EXISTS (
    SELECT 1 FROM roomscan.member_slots AS slot
    WHERE slot.workspace_id = created_workspace_id
      AND slot.principal_id = context_row.principal_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'OWNER_SLOT_REQUIRED';
  END IF;
  INSERT INTO roomscan.audit_states (workspace_id, next_sequence, updated_at)
  VALUES (created_workspace_id, 2, authoritative_time);
  INSERT INTO roomscan.audit_events (
    workspace_id, sequence, event_id, actor_principal_id, action,
    subject_kind, subject_id, authorization_version, occurred_at
  ) VALUES (
    created_workspace_id, 1, requested_audit_event_id,
    context_row.principal_id, 'workspace.created', 'workspace',
    created_workspace_id::text, 1, authoritative_time
  );

  UPDATE roomscan.auth_session_families AS family
  SET workspace_id = created_workspace_id, role = 'owner',
      authorization_version = 1, last_used_at = authoritative_time
  WHERE family.id = context_row.family_id AND family.state = 'active'
    AND family.workspace_id IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'WORKSPACE_BOOTSTRAP_FAMILY_RACE';
  END IF;
  UPDATE roomscan.auth_access_tokens AS access
  SET workspace_id = created_workspace_id, role = 'owner',
      authorization_version = 1
  WHERE access.family_id = context_row.family_id AND access.state = 'active';
  PERFORM 1 FROM roomscan.auth_access_tokens AS access
  WHERE access.token_hash = access_token_hash AND access.state = 'active'
    AND access.workspace_id = created_workspace_id
    AND access.role = 'owner' AND access.authorization_version = 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'WORKSPACE_BOOTSTRAP_ACCESS_RACE';
  END IF;
  RETURN QUERY SELECT created_workspace_id, created_membership_id,
    context_row.principal_id, context_row.canonical_principal_id,
    context_row.family_id, context_row.family_public_id, 1::bigint;
END
$function$;

CREATE FUNCTION roomscan.scope_session_workspace_v2(
  access_token_hash bytea,
  authoritative_time timestamptz,
  requested_workspace_slug text
)
RETURNS TABLE (
  workspace_id uuid,
  workspace_slug text,
  principal_id uuid,
  principal_canonical_id text,
  family_id uuid,
  family_public_id text,
  role text,
  authorization_version bigint
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record; membership_row record;
BEGIN
  IF access_token_hash IS NULL OR authoritative_time IS NULL
    OR requested_workspace_slug IS NULL OR octet_length(access_token_hash) <> 32
    OR requested_workspace_slug !~ '^[a-z0-9][a-z0-9-]{2,62}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_SESSION_WORKSPACE_SCOPE';
  END IF;
  PERFORM 1 FROM roomscan.global_operational_flags AS flag
  WHERE flag.flag_key = 'professional_sign_in_enabled'
    AND flag.enabled IS TRUE AND flag.version > 0
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROFESSIONAL_SIGN_IN_DISABLED';
  END IF;
  PERFORM 1 FROM roomscan.global_operational_flags AS flag
  WHERE flag.flag_key = 'hosted_operations_enabled'
    AND flag.enabled IS TRUE AND flag.version > 0
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'HOSTED_OPERATIONS_DISABLED';
  END IF;
  PERFORM 1
  FROM roomscan.auth_access_tokens AS access
  JOIN roomscan.auth_session_families AS family ON family.id = access.family_id
  JOIN roomscan.principals AS principal ON principal.id = family.principal_id
  WHERE access.token_hash = access_token_hash
    AND access.state = 'active' AND family.state = 'active'
    AND principal.state = 'active'
  FOR UPDATE OF access, family, principal;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'SESSION_SCOPE_UNAVAILABLE';
  END IF;
  SELECT * INTO context_row
  FROM roomscan.resolve_access_context(access_token_hash, authoritative_time);
  IF NOT FOUND OR context_row.recent_authentication IS DISTINCT FROM true THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'RECENT_AUTHENTICATION_REQUIRED';
  END IF;

  SELECT workspace.id AS workspace_id, workspace.slug,
    membership.role, membership.authorization_version
    INTO membership_row
  FROM roomscan.workspaces AS workspace
  JOIN roomscan.memberships AS membership
    ON membership.workspace_id = workspace.id
   AND membership.principal_id = context_row.principal_id
  JOIN roomscan.workspace_operational_flags AS hosted_flag
    ON hosted_flag.workspace_id = workspace.id
   AND hosted_flag.flag_key = 'hosted_operations_enabled'
   AND hosted_flag.enabled IS TRUE AND hosted_flag.version > 0
  WHERE workspace.slug = requested_workspace_slug
    AND membership.state = 'active'
  FOR UPDATE OF membership;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'SESSION_SCOPE_UNAVAILABLE';
  END IF;

  IF context_row.workspace_id IS NOT NULL THEN
    IF context_row.workspace_id IS DISTINCT FROM membership_row.workspace_id
      OR context_row.role IS DISTINCT FROM membership_row.role
      OR context_row.authorization_version IS DISTINCT FROM membership_row.authorization_version THEN
      RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'SESSION_ALREADY_SCOPED';
    END IF;
    RETURN QUERY SELECT membership_row.workspace_id, membership_row.slug,
      context_row.principal_id, context_row.canonical_principal_id,
      context_row.family_id, context_row.family_public_id,
      membership_row.role, membership_row.authorization_version;
    RETURN;
  END IF;

  UPDATE roomscan.auth_session_families AS family
  SET workspace_id = membership_row.workspace_id, role = membership_row.role,
      authorization_version = membership_row.authorization_version,
      last_used_at = authoritative_time
  WHERE family.id = context_row.family_id AND family.state = 'active'
    AND family.workspace_id IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'SESSION_SCOPE_FAMILY_RACE';
  END IF;
  UPDATE roomscan.auth_access_tokens AS access
  SET workspace_id = membership_row.workspace_id, role = membership_row.role,
      authorization_version = membership_row.authorization_version
  WHERE access.family_id = context_row.family_id AND access.state = 'active';
  PERFORM 1 FROM roomscan.auth_access_tokens AS access
  WHERE access.token_hash = access_token_hash AND access.state = 'active'
    AND access.workspace_id = membership_row.workspace_id
    AND access.role = membership_row.role
    AND access.authorization_version = membership_row.authorization_version;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'SESSION_SCOPE_ACCESS_RACE';
  END IF;
  RETURN QUERY SELECT membership_row.workspace_id, membership_row.slug,
    context_row.principal_id, context_row.canonical_principal_id,
    context_row.family_id, context_row.family_public_id,
    membership_row.role, membership_row.authorization_version;
END
$function$;

RESET ROLE;

ALTER FUNCTION roomscan.sync_active_member_slot() OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.set_operational_flag(text, uuid, text, boolean, bigint, text, text, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.set_workspace_publishing_policy(uuid, boolean, bigint, text, text, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.read_global_operational_flag(text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.read_workspace_operational_flag(bytea, timestamptz, text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.bootstrap_workspace_v2(bytea, timestamptz, text, text, text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.scope_session_workspace_v2(bytea, timestamptz, text) OWNER TO roomscan_policy;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA roomscan FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA roomscan FROM PUBLIC;
GRANT SELECT, INSERT, DELETE ON roomscan.member_slots TO roomscan_policy;
GRANT SELECT, INSERT, UPDATE ON roomscan.global_operational_flags,
  roomscan.workspace_operational_flags,
  roomscan.workspace_publishing_policies TO roomscan_policy;
GRANT INSERT ON roomscan.operational_flag_audit_events TO roomscan_policy;
GRANT SELECT, INSERT, UPDATE ON roomscan.workspaces, roomscan.memberships,
  roomscan.audit_states, roomscan.audit_events TO roomscan_policy;

GRANT EXECUTE ON FUNCTION
  roomscan.set_operational_flag(text, uuid, text, boolean, bigint, text, text, timestamptz),
  roomscan.set_workspace_publishing_policy(uuid, boolean, bigint, text, text, timestamptz)
  TO roomscan_operator;
GRANT EXECUTE ON FUNCTION roomscan.read_global_operational_flag(text)
  TO roomscan_authorizer_runtime, roomscan_auth_challenge_runtime,
     roomscan_api_runtime;
GRANT EXECUTE ON FUNCTION
  roomscan.read_workspace_operational_flag(bytea, timestamptz, text),
  roomscan.bootstrap_workspace_v2(bytea, timestamptz, text, text, text),
  roomscan.scope_session_workspace_v2(bytea, timestamptz, text)
  TO roomscan_api_runtime;

COMMENT ON FUNCTION roomscan.set_operational_flag(text, uuid, text, boolean, bigint, text, text, timestamptz) IS
  'Audited operator-only CAS. It is deliberately not gated by the flag it restores; NOLOGIN operator holder; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.bootstrap_workspace_v2(bytea, timestamptz, text, text, text) IS
  'Recent unscoped access-digest-derived first-workspace reducer: global sign-in/hosted gates, one-workspace invariant, server IDs, Owner, family/access scope, slot and bounded audit commit atomically; exact same-family replay only; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.scope_session_workspace_v2(bytea, timestamptz, text) IS
  'Recent access plus public slug derives one current active membership and literal-true global/workspace hosted gates, then atomically scopes the family and active access rows; no caller UUID or rescope; fixed search_path; PUBLIC revoked.';

RESET ROLE;

ALTER FUNCTION roomscan.logout_from_access(bytea, timestamptz, text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.touch_session_from_access(bytea, timestamptz, timestamptz, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.consume_apple_bridge_and_issue_session(
  bytea, text, bytea, bytea, timestamptz, timestamptz, timestamptz,
  timestamptz, timestamptz, text
) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.accept_provider_audit_event(text, text, text, text, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.claim_provider_audit_event(text, timestamptz, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.complete_provider_audit_event(text, text, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.release_provider_audit_event(text, text, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.claim_next_magic_delivery(text, timestamptz, timestamptz) OWNER TO roomscan_policy;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA roomscan FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA roomscan FROM PUBLIC;

GRANT SELECT, UPDATE ON roomscan.auth_access_tokens,
  roomscan.auth_session_families, roomscan.auth_refresh_tokens,
  roomscan.apple_bridge_proofs, roomscan.principals TO roomscan_policy;
GRANT SELECT, INSERT ON roomscan.external_identities,
  roomscan.auth_session_families, roomscan.auth_access_tokens,
  roomscan.auth_refresh_tokens, roomscan.principals,
  roomscan.provider_audit_outbox TO roomscan_policy;
GRANT UPDATE ON roomscan.provider_audit_outbox TO roomscan_policy;

GRANT EXECUTE ON FUNCTION roomscan.resolve_access_context(bytea, timestamptz)
  TO roomscan_authorizer_runtime, roomscan_api_runtime;
GRANT EXECUTE ON FUNCTION
  roomscan.logout_from_access(bytea, timestamptz, text),
  roomscan.touch_session_from_access(bytea, timestamptz, timestamptz, timestamptz)
  TO roomscan_api_runtime;
GRANT EXECUTE ON FUNCTION roomscan.consume_apple_bridge_and_issue_session(
  bytea, text, bytea, bytea, timestamptz, timestamptz, timestamptz,
  timestamptz, timestamptz, text
) TO roomscan_auth_challenge_runtime;
REVOKE EXECUTE ON FUNCTION roomscan.accept_provider_audit_event(text, text, text, text, timestamptz)
  FROM roomscan_api_runtime, roomscan_authorizer_runtime,
    roomscan_auth_challenge_runtime, roomscan_stripe_ingress_runtime,
    roomscan_stripe_reconciliation_runtime, roomscan_audit_export_runtime,
    roomscan_email_delivery_runtime, roomscan_operator, roomscan_app;
GRANT EXECUTE ON FUNCTION roomscan.accept_provider_audit_event(text, text, text, text, timestamptz)
  TO roomscan_stripe_ingress_runtime, roomscan_email_delivery_runtime;
GRANT EXECUTE ON FUNCTION
  roomscan.claim_provider_audit_event(text, timestamptz, timestamptz),
  roomscan.complete_provider_audit_event(text, text, timestamptz),
  roomscan.release_provider_audit_event(text, text, timestamptz)
  TO roomscan_audit_export_runtime;

-- Existing hash/proof-only challenge transitions are retained only in the
-- challenge lane. Raw UUID-target transitions remain revoked from all LOGINs.
GRANT EXECUTE ON FUNCTION
  roomscan.claim_refresh_rotation(bytea, bytea, timestamptz),
  roomscan.claim_magic_link(text, bytea, text, timestamptz),
  roomscan.supersede_magic_link(text, timestamptz),
  roomscan.supersede_magic_link_siblings(text, timestamptz),
  roomscan.claim_apple_attempt_and_code(text, bytea, text, bytea, timestamptz),
  roomscan.claim_apple_nonce(bytea, timestamptz),
  roomscan.claim_apple_bridge_proof(bytea, text, text, text, text, timestamptz),
  roomscan.claim_security_notification(text, text, timestamptz, timestamptz),
  roomscan.complete_security_notification(text, text, timestamptz),
  roomscan.release_security_notification(text, text)
  TO roomscan_auth_challenge_runtime;

COMMENT ON FUNCTION roomscan.claim_next_magic_delivery(text, timestamptz, timestamptz) IS
  'Email-delivery worker-only server-selected oldest pending or expired-lease magic delivery claim; literal-true positive-version professional sign-in gate, one bounded row, SKIP LOCKED, expired-row cleanup, no caller outbox target; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.validate_magic_delivery(text, text, timestamptz) IS
  'Email-delivery worker pre-send authorization: exact unexpired lease and outbox, active unexpired magic link, literal-true positive-version professional sign-in gate; expired records close durably; fixed search_path; PUBLIC revoked.';

COMMENT ON FUNCTION roomscan.logout_from_access(bytea, timestamptz, text) IS
  'Reviewed access-digest-derived logout. Returns internal UUID plus canonical/public IDs; no caller principal/family target; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.touch_session_from_access(bytea, timestamptz, timestamptz, timestamptz) IS
  'Reviewed access-digest-derived activity update. Returns internal UUID plus canonical/public IDs; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.consume_apple_bridge_and_issue_session(
  bytea, text, bytea, bytea, timestamptz, timestamptz, timestamptz,
  timestamptz, timestamptz, text
) IS
  'Reviewed one-time Apple/Cognito bridge consumer. Principal ownership is app-derived from issuer/subject; creates an unscoped family and returns internal UUID plus canonical/public IDs; fixed search_path; PUBLIC revoked.';
COMMENT ON TABLE roomscan.provider_audit_outbox IS
  'Privacy-bounded durable provider audit delivery state. Never stores tokens, provider bodies, email addresses, URLs, or arbitrary request content.';

RESET ROLE;

-- Section C: period-aware quotas. Accepted legacy rows are retained but are
-- explicitly deactivated; only schema-versioned v2 state is operator-usable.
SET ROLE roomscan_owner;

UPDATE roomscan.quota_policy_versions SET is_active = false WHERE is_active;

CREATE TABLE roomscan.quota_policy_versions_v2 (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE CASCADE,
  version bigint NOT NULL CHECK (version > 0),
  schema_version text NOT NULL CHECK (schema_version = 'roomscan-quota-policy-v1'),
  classification text NOT NULL CHECK (classification IN ('test-only', 'operator-approved')),
  portal_period_key text NOT NULL CHECK (
    length(portal_period_key) BETWEEN 1 AND 128
    AND portal_period_key ~ '^roomscan-period-v1:[A-Za-z0-9._:-]+$'
    AND portal_period_key <> 'roomscan-period-v1:lifetime'
  ),
  project_limit bigint NOT NULL CHECK (project_limit >= 0),
  member_limit bigint NOT NULL CHECK (member_limit >= 0),
  working_byte_limit bigint NOT NULL CHECK (working_byte_limit >= 0),
  raw_byte_limit bigint NOT NULL CHECK (raw_byte_limit >= 0),
  portal_byte_limit bigint NOT NULL CHECK (portal_byte_limit >= 0),
  warning_threshold_percent smallint NOT NULL CHECK (warning_threshold_percent BETWEEN 1 AND 100),
  is_active boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL,
  PRIMARY KEY (workspace_id, version)
);
CREATE UNIQUE INDEX quota_policy_v2_one_active
  ON roomscan.quota_policy_versions_v2 (workspace_id) WHERE is_active;

CREATE TABLE roomscan.quota_usage_v2 (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE CASCADE,
  metric roomscan.quota_metric NOT NULL,
  period_key text NOT NULL CHECK (
    length(period_key) BETWEEN 1 AND 128
    AND period_key ~ '^roomscan-period-v1:[A-Za-z0-9._:-]+$'
  ),
  policy_version bigint NOT NULL,
  used bigint NOT NULL DEFAULT 0 CHECK (used >= 0),
  reserved bigint NOT NULL DEFAULT 0 CHECK (reserved >= 0),
  limit_value bigint NOT NULL CHECK (limit_value >= 0),
  warning_threshold_percent smallint NOT NULL CHECK (warning_threshold_percent BETWEEN 1 AND 100),
  reconciliation_generation bigint NOT NULL DEFAULT 0 CHECK (reconciliation_generation >= 0),
  updated_at timestamptz NOT NULL,
  PRIMARY KEY (workspace_id, metric, period_key),
  FOREIGN KEY (workspace_id, policy_version)
    REFERENCES roomscan.quota_policy_versions_v2(workspace_id, version)
);

CREATE TABLE roomscan.quota_reservations_v2 (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE CASCADE,
  period_key text NOT NULL CHECK (
    length(period_key) BETWEEN 1 AND 128
    AND period_key ~ '^roomscan-period-v1:[A-Za-z0-9._:-]+$'
  ),
  idempotency_key text NOT NULL CHECK (length(idempotency_key) BETWEEN 1 AND 200),
  metric roomscan.quota_metric NOT NULL CHECK (metric <> 'member_count'),
  authorization_action text NOT NULL CHECK (
    authorization_action IN ('project.create', 'project.revise', 'raw_archive.allocate', 'publication.create')
  ),
  resource_kind text CHECK (
    resource_kind IS NULL OR (
      length(resource_kind) BETWEEN 1 AND 64 AND resource_kind ~ '^[a-z][a-z0-9_.-]+$'
    )
  ),
  resource_id text CHECK (resource_id IS NULL OR length(resource_id) BETWEEN 1 AND 512),
  requested_amount bigint NOT NULL CHECK (requested_amount > 0),
  policy_version bigint NOT NULL,
  expires_at timestamptz NOT NULL,
  state roomscan.quota_reservation_state NOT NULL DEFAULT 'reserved',
  finalized_amount bigint CHECK (finalized_amount >= 0),
  finalized_at timestamptz,
  released_at timestamptz,
  release_reason text CHECK (release_reason IS NULL OR release_reason IN ('released', 'expired')),
  created_at timestamptz NOT NULL,
  PRIMARY KEY (workspace_id, period_key, idempotency_key),
  FOREIGN KEY (workspace_id, metric, period_key)
    REFERENCES roomscan.quota_usage_v2(workspace_id, metric, period_key),
  FOREIGN KEY (workspace_id, policy_version)
    REFERENCES roomscan.quota_policy_versions_v2(workspace_id, version),
  CHECK ((resource_kind IS NULL) = (resource_id IS NULL)),
  CHECK (created_at < expires_at),
  CHECK (
    (state = 'reserved' AND finalized_amount IS NULL AND finalized_at IS NULL
      AND released_at IS NULL AND release_reason IS NULL)
    OR (state = 'finalized' AND finalized_amount IS NOT NULL AND finalized_at IS NOT NULL
      AND released_at IS NULL AND release_reason IS NULL)
    OR (state = 'released' AND finalized_amount IS NULL AND finalized_at IS NULL
      AND released_at IS NOT NULL AND release_reason IS NOT NULL)
  )
);

CREATE TABLE roomscan.quota_ledger_v2 (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE CASCADE,
  period_key text NOT NULL,
  idempotency_key text NOT NULL,
  action text NOT NULL CHECK (action IN ('reserve', 'finalize', 'release', 'expire', 'reconcile')),
  metric roomscan.quota_metric NOT NULL,
  delta_used bigint NOT NULL,
  delta_reserved bigint NOT NULL,
  policy_version bigint NOT NULL,
  reconciliation_generation bigint,
  recorded_at timestamptz NOT NULL,
  PRIMARY KEY (workspace_id, period_key, idempotency_key, action),
  FOREIGN KEY (workspace_id, policy_version)
    REFERENCES roomscan.quota_policy_versions_v2(workspace_id, version),
  CHECK (delta_used <> 0 OR delta_reserved <> 0 OR action = 'reconcile'),
  CHECK ((action = 'reconcile') = (reconciliation_generation IS NOT NULL))
);

CREATE TABLE roomscan.quota_reconciliations_v2 (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE CASCADE,
  metric roomscan.quota_metric NOT NULL,
  period_key text NOT NULL,
  generation bigint NOT NULL CHECK (generation > 0),
  authoritative_used bigint NOT NULL CHECK (authoritative_used >= 0),
  recorded_at timestamptz NOT NULL,
  PRIMARY KEY (workspace_id, metric, period_key, generation),
  FOREIGN KEY (workspace_id, metric, period_key)
    REFERENCES roomscan.quota_usage_v2(workspace_id, metric, period_key)
);

ALTER TABLE roomscan.quota_policy_versions_v2 ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.quota_policy_versions_v2 FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.quota_usage_v2 ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.quota_usage_v2 FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.quota_reservations_v2 ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.quota_reservations_v2 FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.quota_ledger_v2 ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.quota_ledger_v2 FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.quota_reconciliations_v2 ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.quota_reconciliations_v2 FORCE ROW LEVEL SECURITY;

CREATE POLICY quota_policy_versions_v2_tenant_isolation ON roomscan.quota_policy_versions_v2
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));
CREATE POLICY quota_usage_v2_tenant_isolation ON roomscan.quota_usage_v2
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));
CREATE POLICY quota_reservations_v2_tenant_isolation ON roomscan.quota_reservations_v2
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));
CREATE POLICY quota_ledger_v2_tenant_isolation ON roomscan.quota_ledger_v2
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));
CREATE POLICY quota_reconciliations_v2_tenant_isolation ON roomscan.quota_reconciliations_v2
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));

CREATE FUNCTION roomscan.hosted_mutation_grant_matches(
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
      'project.create', 'project.revise', 'raw_archive.allocate',
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

CREATE FUNCTION roomscan.activate_quota_policy_v2(
  requested_workspace_id uuid,
  requested_version bigint,
  requested_schema_version text,
  requested_classification text,
  requested_portal_period_key text,
  requested_project_limit bigint,
  requested_member_limit bigint,
  requested_working_byte_limit bigint,
  requested_raw_byte_limit bigint,
  requested_portal_byte_limit bigint,
  requested_warning_threshold_percent integer,
  hosted_global_version bigint,
  hosted_workspace_version bigint,
  activated_at_time timestamptz
)
RETURNS TABLE (policy_version bigint, authoritative_active_member_count bigint)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  current_version bigint;
  active_count bigint;
BEGIN
  IF requested_workspace_id IS NULL OR requested_version IS NULL
    OR requested_schema_version IS NULL OR requested_classification IS NULL
    OR requested_portal_period_key IS NULL OR requested_project_limit IS NULL
    OR requested_member_limit IS NULL OR requested_working_byte_limit IS NULL
    OR requested_raw_byte_limit IS NULL OR requested_portal_byte_limit IS NULL
    OR requested_warning_threshold_percent IS NULL OR hosted_global_version IS NULL
    OR hosted_workspace_version IS NULL OR activated_at_time IS NULL
    OR requested_version < 1 OR requested_schema_version <> 'roomscan-quota-policy-v1'
    OR requested_classification NOT IN ('test-only', 'operator-approved')
    OR length(requested_portal_period_key) NOT BETWEEN 1 AND 128
    OR requested_portal_period_key !~ '^roomscan-period-v1:[A-Za-z0-9._:-]+$'
    OR requested_portal_period_key = 'roomscan-period-v1:lifetime'
    OR requested_project_limit < 0 OR requested_member_limit < 0
    OR requested_working_byte_limit < 0 OR requested_raw_byte_limit < 0
    OR requested_portal_byte_limit < 0
    OR requested_warning_threshold_percent NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_QUOTA_POLICY_V2';
  END IF;
  IF NOT roomscan.hosted_mutation_grant_matches(
    requested_workspace_id, 'system.quota_policy.change',
    hosted_global_version, hosted_workspace_version, NULL, NULL
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'HOSTED_GRANT_REJECTED';
  END IF;
  PERFORM 1 FROM roomscan.workspaces WHERE id = requested_workspace_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'UNKNOWN_WORKSPACE';
  END IF;
  SELECT policy.version INTO current_version
  FROM roomscan.quota_policy_versions_v2 AS policy
  WHERE policy.workspace_id = requested_workspace_id AND policy.is_active
  FOR UPDATE;
  IF current_version IS NOT NULL AND requested_version <= current_version THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'QUOTA_POLICY_VERSION_NOT_FORWARD';
  END IF;
  SELECT count(*)::bigint INTO active_count
  FROM roomscan.member_slots AS slot
  WHERE slot.workspace_id = requested_workspace_id;
  IF active_count < 1 THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'ACTIVE_MEMBER_SLOT_REQUIRED';
  END IF;

  UPDATE roomscan.quota_policy_versions_v2
  SET is_active = false
  WHERE workspace_id = requested_workspace_id AND is_active;
  INSERT INTO roomscan.quota_policy_versions_v2 (
    workspace_id, version, schema_version, classification, portal_period_key,
    project_limit, member_limit, working_byte_limit, raw_byte_limit,
    portal_byte_limit, warning_threshold_percent, is_active, created_at
  ) VALUES (
    requested_workspace_id, requested_version, requested_schema_version,
    requested_classification, requested_portal_period_key,
    requested_project_limit, requested_member_limit,
    requested_working_byte_limit, requested_raw_byte_limit,
    requested_portal_byte_limit, requested_warning_threshold_percent,
    true, activated_at_time
  );

  INSERT INTO roomscan.quota_usage_v2 (
    workspace_id, metric, period_key, policy_version, used, reserved,
    limit_value, warning_threshold_percent, updated_at
  ) VALUES
    (requested_workspace_id, 'project_count', 'roomscan-period-v1:lifetime', requested_version, 0, 0, requested_project_limit, requested_warning_threshold_percent, activated_at_time),
    (requested_workspace_id, 'member_count', 'roomscan-period-v1:lifetime', requested_version, active_count, 0, requested_member_limit, requested_warning_threshold_percent, activated_at_time),
    (requested_workspace_id, 'working_bytes', 'roomscan-period-v1:lifetime', requested_version, 0, 0, requested_working_byte_limit, requested_warning_threshold_percent, activated_at_time),
    (requested_workspace_id, 'raw_bytes', 'roomscan-period-v1:lifetime', requested_version, 0, 0, requested_raw_byte_limit, requested_warning_threshold_percent, activated_at_time),
    (requested_workspace_id, 'portal_bytes', requested_portal_period_key, requested_version, 0, 0, requested_portal_byte_limit, requested_warning_threshold_percent, activated_at_time)
  ON CONFLICT (workspace_id, metric, period_key) DO UPDATE
  SET policy_version = EXCLUDED.policy_version,
      used = CASE WHEN EXCLUDED.metric = 'member_count' THEN EXCLUDED.used ELSE roomscan.quota_usage_v2.used END,
      reserved = CASE WHEN EXCLUDED.metric = 'member_count' THEN 0 ELSE roomscan.quota_usage_v2.reserved END,
      limit_value = EXCLUDED.limit_value,
      warning_threshold_percent = EXCLUDED.warning_threshold_percent,
      updated_at = EXCLUDED.updated_at;

  RETURN QUERY SELECT requested_version, active_count;
END
$function$;

CREATE FUNCTION roomscan.quota_snapshot_v2(
  access_token_hash bytea,
  authoritative_time timestamptz,
  requested_metric roomscan.quota_metric,
  requested_period_key text
)
RETURNS SETOF roomscan.quota_usage_v2
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
BEGIN
  IF access_token_hash IS NULL OR authoritative_time IS NULL
    OR requested_metric IS NULL OR requested_period_key IS NULL
    OR octet_length(access_token_hash) <> 32
    OR length(requested_period_key) NOT BETWEEN 1 AND 128 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_QUOTA_SNAPSHOT_V2';
  END IF;
  SELECT * INTO context_row FROM roomscan.resolve_access_context(access_token_hash, authoritative_time);
  IF NOT FOUND OR context_row.workspace_id IS NULL THEN RETURN; END IF;
  RETURN QUERY SELECT usage.* FROM roomscan.quota_usage_v2 AS usage
  WHERE usage.workspace_id = context_row.workspace_id
    AND usage.metric = requested_metric AND usage.period_key = requested_period_key;
END
$function$;

CREATE FUNCTION roomscan.reserve_quota_v2(
  access_token_hash bytea,
  authoritative_time timestamptz,
  requested_metric roomscan.quota_metric,
  requested_period_key text,
  requested_authorization_action text,
  requested_resource_kind text,
  requested_resource_id text,
  amount_to_reserve bigint,
  request_key text,
  requested_policy_version bigint,
  requested_expires_at timestamptz,
  hosted_global_version bigint,
  hosted_workspace_version bigint,
  publication_global_version bigint,
  publication_workspace_version bigint
)
RETURNS SETOF roomscan.quota_reservations_v2
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  context_row record;
  active_policy roomscan.quota_policy_versions_v2%ROWTYPE;
  existing roomscan.quota_reservations_v2%ROWTYPE;
BEGIN
  IF access_token_hash IS NULL OR authoritative_time IS NULL
    OR requested_metric IS NULL OR requested_period_key IS NULL
    OR requested_authorization_action IS NULL OR amount_to_reserve IS NULL
    OR request_key IS NULL OR requested_policy_version IS NULL
    OR requested_expires_at IS NULL OR hosted_global_version IS NULL
    OR hosted_workspace_version IS NULL OR octet_length(access_token_hash) <> 32
    OR requested_metric = 'member_count' OR amount_to_reserve <= 0
    OR length(requested_period_key) NOT BETWEEN 1 AND 128
    OR length(request_key) NOT BETWEEN 1 AND 200
    OR requested_expires_at <= authoritative_time
    OR (requested_resource_kind IS NULL) IS DISTINCT FROM (requested_resource_id IS NULL)
    OR (requested_resource_kind IS NOT NULL AND (
      length(requested_resource_kind) NOT BETWEEN 1 AND 64
      OR length(requested_resource_id) NOT BETWEEN 1 AND 512
    ))
    OR requested_authorization_action IS DISTINCT FROM (CASE requested_metric
      WHEN 'project_count' THEN 'project.create'
      WHEN 'working_bytes' THEN 'project.revise'
      WHEN 'raw_bytes' THEN 'raw_archive.allocate'
      WHEN 'portal_bytes' THEN 'publication.create'
      ELSE NULL END) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_QUOTA_RESERVATION_V2';
  END IF;
  SELECT * INTO context_row FROM roomscan.resolve_access_context(access_token_hash, authoritative_time);
  IF NOT FOUND OR context_row.workspace_id IS NULL
    OR context_row.role NOT IN ('owner', 'admin', 'editor') THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'QUOTA_AUTHORIZATION_REQUIRED';
  END IF;
  IF requested_authorization_action = 'publication.create'
    AND (context_row.recent_authentication IS DISTINCT FROM true
      OR (context_row.role = 'editor' AND NOT EXISTS (
        SELECT 1 FROM roomscan.workspace_publishing_policies AS policy
        WHERE policy.workspace_id = context_row.workspace_id
          AND policy.editor_publishing_allowed IS TRUE
      ))) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PUBLICATION_AUTHORIZATION_REQUIRED';
  END IF;
  IF NOT roomscan.hosted_mutation_grant_matches(
    context_row.workspace_id, requested_authorization_action,
    hosted_global_version, hosted_workspace_version,
    publication_global_version, publication_workspace_version
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'HOSTED_GRANT_REJECTED';
  END IF;
  IF requested_resource_kind = 'project' AND NOT EXISTS (
    SELECT 1 FROM roomscan.projects AS project
    WHERE project.workspace_id = context_row.workspace_id
      AND project.id::text = requested_resource_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'RESOURCE_TENANT_MISMATCH';
  END IF;

  SELECT policy.* INTO active_policy
  FROM roomscan.quota_policy_versions_v2 AS policy
  WHERE policy.workspace_id = context_row.workspace_id AND policy.is_active
  FOR UPDATE;
  IF NOT FOUND OR active_policy.version IS DISTINCT FROM requested_policy_version
    OR requested_period_key IS DISTINCT FROM (CASE WHEN requested_metric = 'portal_bytes'
      THEN active_policy.portal_period_key ELSE 'roomscan-period-v1:lifetime' END) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'QUOTA_POLICY_MISMATCH';
  END IF;

  SELECT reservation.* INTO existing
  FROM roomscan.quota_reservations_v2 AS reservation
  WHERE reservation.workspace_id = context_row.workspace_id
    AND reservation.period_key = requested_period_key
    AND reservation.idempotency_key = request_key
  FOR UPDATE;
  IF FOUND THEN
    IF existing.metric IS DISTINCT FROM requested_metric
      OR existing.authorization_action IS DISTINCT FROM requested_authorization_action
      OR existing.resource_kind IS DISTINCT FROM requested_resource_kind
      OR existing.resource_id IS DISTINCT FROM requested_resource_id
      OR existing.requested_amount IS DISTINCT FROM amount_to_reserve
      OR existing.policy_version IS DISTINCT FROM requested_policy_version
      OR existing.expires_at IS DISTINCT FROM requested_expires_at THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'IDEMPOTENCY_KEY_REUSED';
    END IF;
    RETURN NEXT existing; RETURN;
  END IF;

  UPDATE roomscan.quota_usage_v2 AS usage
  SET reserved = usage.reserved + amount_to_reserve,
      updated_at = authoritative_time
  WHERE usage.workspace_id = context_row.workspace_id
    AND usage.metric = requested_metric AND usage.period_key = requested_period_key
    AND usage.policy_version = requested_policy_version
    AND usage.used + usage.reserved + amount_to_reserve <= usage.limit_value;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'QUOTA_EXCEEDED';
  END IF;
  INSERT INTO roomscan.quota_reservations_v2 (
    workspace_id, period_key, idempotency_key, metric, authorization_action,
    resource_kind, resource_id, requested_amount, policy_version, expires_at,
    state, created_at
  ) VALUES (
    context_row.workspace_id, requested_period_key, request_key,
    requested_metric, requested_authorization_action, requested_resource_kind,
    requested_resource_id, amount_to_reserve, requested_policy_version,
    requested_expires_at, 'reserved', authoritative_time
  ) RETURNING * INTO existing;
  INSERT INTO roomscan.quota_ledger_v2 (
    workspace_id, period_key, idempotency_key, action, metric,
    delta_used, delta_reserved, policy_version, recorded_at
  ) VALUES (
    context_row.workspace_id, requested_period_key, request_key, 'reserve',
    requested_metric, 0, amount_to_reserve, requested_policy_version,
    authoritative_time
  );
  RETURN NEXT existing;
END
$function$;

CREATE FUNCTION roomscan.finalize_quota_v2(
  access_token_hash bytea,
  authoritative_time timestamptz,
  requested_period_key text,
  request_key text,
  amount_actually_used bigint,
  hosted_global_version bigint,
  hosted_workspace_version bigint,
  publication_global_version bigint,
  publication_workspace_version bigint
)
RETURNS SETOF roomscan.quota_reservations_v2
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record; reservation roomscan.quota_reservations_v2%ROWTYPE;
BEGIN
  IF access_token_hash IS NULL OR authoritative_time IS NULL
    OR requested_period_key IS NULL OR request_key IS NULL
    OR amount_actually_used IS NULL OR hosted_global_version IS NULL
    OR hosted_workspace_version IS NULL OR octet_length(access_token_hash) <> 32
    OR length(requested_period_key) NOT BETWEEN 1 AND 128
    OR length(request_key) NOT BETWEEN 1 AND 200 OR amount_actually_used < 0 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_QUOTA_FINALIZATION_V2';
  END IF;
  SELECT * INTO context_row FROM roomscan.resolve_access_context(access_token_hash, authoritative_time);
  IF NOT FOUND OR context_row.workspace_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'QUOTA_AUTHORIZATION_REQUIRED';
  END IF;
  SELECT existing.* INTO reservation FROM roomscan.quota_reservations_v2 AS existing
  WHERE existing.workspace_id = context_row.workspace_id
    AND existing.period_key = requested_period_key
    AND existing.idempotency_key = request_key FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'QUOTA_RESERVATION_NOT_FOUND'; END IF;
  IF NOT roomscan.hosted_mutation_grant_matches(
    context_row.workspace_id, reservation.authorization_action,
    hosted_global_version, hosted_workspace_version,
    publication_global_version, publication_workspace_version
  ) THEN RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'HOSTED_GRANT_REJECTED'; END IF;
  IF reservation.state = 'finalized' THEN
    IF reservation.finalized_amount IS DISTINCT FROM amount_actually_used THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'IDEMPOTENCY_KEY_REUSED';
    END IF;
    RETURN NEXT reservation; RETURN;
  END IF;
  IF reservation.state = 'released' THEN RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'QUOTA_RESERVATION_RELEASED'; END IF;
  IF amount_actually_used > reservation.requested_amount OR reservation.expires_at <= authoritative_time THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'QUOTA_RESERVATION_EXPIRED_OR_AMOUNT';
  END IF;
  UPDATE roomscan.quota_usage_v2 AS usage
  SET used = usage.used + amount_actually_used,
      reserved = usage.reserved - reservation.requested_amount,
      updated_at = authoritative_time
  WHERE usage.workspace_id = context_row.workspace_id
    AND usage.metric = reservation.metric AND usage.period_key = reservation.period_key;
  UPDATE roomscan.quota_reservations_v2 AS target
  SET state = 'finalized', finalized_amount = amount_actually_used,
      finalized_at = authoritative_time
  WHERE target.workspace_id = context_row.workspace_id
    AND target.period_key = requested_period_key
    AND target.idempotency_key = request_key
  RETURNING target.* INTO reservation;
  INSERT INTO roomscan.quota_ledger_v2 (
    workspace_id, period_key, idempotency_key, action, metric,
    delta_used, delta_reserved, policy_version, recorded_at
  ) VALUES (
    context_row.workspace_id, requested_period_key, request_key, 'finalize',
    reservation.metric, amount_actually_used, -reservation.requested_amount,
    reservation.policy_version, authoritative_time
  );
  RETURN NEXT reservation;
END
$function$;

CREATE FUNCTION roomscan.release_quota_v2(
  access_token_hash bytea,
  authoritative_time timestamptz,
  requested_period_key text,
  request_key text,
  requested_reason text,
  hosted_global_version bigint,
  hosted_workspace_version bigint,
  publication_global_version bigint,
  publication_workspace_version bigint
)
RETURNS SETOF roomscan.quota_reservations_v2
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record; reservation roomscan.quota_reservations_v2%ROWTYPE;
BEGIN
  IF access_token_hash IS NULL OR authoritative_time IS NULL
    OR requested_period_key IS NULL OR request_key IS NULL OR requested_reason IS NULL
    OR hosted_global_version IS NULL OR hosted_workspace_version IS NULL
    OR octet_length(access_token_hash) <> 32
    OR length(requested_period_key) NOT BETWEEN 1 AND 128
    OR length(request_key) NOT BETWEEN 1 AND 200
    OR requested_reason NOT IN ('released', 'expired') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_QUOTA_RELEASE_V2';
  END IF;
  SELECT * INTO context_row FROM roomscan.resolve_access_context(access_token_hash, authoritative_time);
  IF NOT FOUND OR context_row.workspace_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'QUOTA_AUTHORIZATION_REQUIRED';
  END IF;
  SELECT existing.* INTO reservation FROM roomscan.quota_reservations_v2 AS existing
  WHERE existing.workspace_id = context_row.workspace_id
    AND existing.period_key = requested_period_key
    AND existing.idempotency_key = request_key FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'QUOTA_RESERVATION_NOT_FOUND'; END IF;
  IF NOT roomscan.hosted_mutation_grant_matches(
    context_row.workspace_id, reservation.authorization_action,
    hosted_global_version, hosted_workspace_version,
    publication_global_version, publication_workspace_version
  ) THEN RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'HOSTED_GRANT_REJECTED'; END IF;
  IF reservation.state = 'released' THEN
    IF reservation.release_reason IS DISTINCT FROM requested_reason THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'IDEMPOTENCY_KEY_REUSED';
    END IF;
    RETURN NEXT reservation; RETURN;
  END IF;
  IF reservation.state = 'finalized' THEN RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'QUOTA_RESERVATION_FINALIZED'; END IF;
  IF requested_reason = 'expired' AND reservation.expires_at > authoritative_time THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'QUOTA_RESERVATION_NOT_EXPIRED';
  END IF;
  UPDATE roomscan.quota_usage_v2 AS usage
  SET reserved = usage.reserved - reservation.requested_amount,
      updated_at = authoritative_time
  WHERE usage.workspace_id = context_row.workspace_id
    AND usage.metric = reservation.metric AND usage.period_key = reservation.period_key;
  UPDATE roomscan.quota_reservations_v2 AS target
  SET state = 'released', released_at = authoritative_time,
      release_reason = requested_reason
  WHERE target.workspace_id = context_row.workspace_id
    AND target.period_key = requested_period_key
    AND target.idempotency_key = request_key
  RETURNING target.* INTO reservation;
  INSERT INTO roomscan.quota_ledger_v2 (
    workspace_id, period_key, idempotency_key, action, metric,
    delta_used, delta_reserved, policy_version, recorded_at
  ) VALUES (
    context_row.workspace_id, requested_period_key, request_key,
    CASE WHEN requested_reason = 'expired' THEN 'expire' ELSE 'release' END,
    reservation.metric, 0, -reservation.requested_amount,
    reservation.policy_version, authoritative_time
  );
  RETURN NEXT reservation;
END
$function$;

CREATE FUNCTION roomscan.reconcile_quota_v2(
  requested_workspace_id uuid,
  requested_metric roomscan.quota_metric,
  requested_period_key text,
  requested_generation bigint,
  requested_authoritative_used bigint,
  hosted_global_version bigint,
  hosted_workspace_version bigint,
  reconciled_at_time timestamptz
)
RETURNS TABLE (applied boolean, used bigint, reconciliation_generation bigint)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE existing roomscan.quota_reconciliations_v2%ROWTYPE;
DECLARE usage_row roomscan.quota_usage_v2%ROWTYPE;
DECLARE prior_used bigint;
BEGIN
  IF requested_workspace_id IS NULL OR requested_metric IS NULL
    OR requested_period_key IS NULL OR requested_generation IS NULL
    OR requested_authoritative_used IS NULL OR hosted_global_version IS NULL
    OR hosted_workspace_version IS NULL OR reconciled_at_time IS NULL
    OR requested_generation < 1 OR requested_authoritative_used < 0
    OR length(requested_period_key) NOT BETWEEN 1 AND 128 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_QUOTA_RECONCILIATION_V2';
  END IF;
  IF NOT roomscan.hosted_mutation_grant_matches(
    requested_workspace_id, 'system.quota_policy.change',
    hosted_global_version, hosted_workspace_version, NULL, NULL
  ) THEN RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'HOSTED_GRANT_REJECTED'; END IF;
  SELECT usage.* INTO usage_row FROM roomscan.quota_usage_v2 AS usage
  WHERE usage.workspace_id = requested_workspace_id
    AND usage.metric = requested_metric AND usage.period_key = requested_period_key
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'QUOTA_USAGE_NOT_FOUND'; END IF;
  SELECT journal.* INTO existing FROM roomscan.quota_reconciliations_v2 AS journal
  WHERE journal.workspace_id = requested_workspace_id
    AND journal.metric = requested_metric AND journal.period_key = requested_period_key
    AND journal.generation = requested_generation FOR UPDATE;
  IF FOUND THEN
    IF existing.authoritative_used IS DISTINCT FROM requested_authoritative_used THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'RECONCILIATION_GENERATION_REUSED';
    END IF;
    RETURN QUERY SELECT true, usage_row.used, usage_row.reconciliation_generation; RETURN;
  END IF;
  IF requested_generation < usage_row.reconciliation_generation THEN
    RETURN QUERY SELECT false, usage_row.used, usage_row.reconciliation_generation; RETURN;
  END IF;
  prior_used := usage_row.used;
  INSERT INTO roomscan.quota_reconciliations_v2 (
    workspace_id, metric, period_key, generation, authoritative_used, recorded_at
  ) VALUES (
    requested_workspace_id, requested_metric, requested_period_key,
    requested_generation, requested_authoritative_used, reconciled_at_time
  );
  UPDATE roomscan.quota_usage_v2 AS usage
  SET used = requested_authoritative_used,
      reconciliation_generation = requested_generation,
      updated_at = reconciled_at_time
  WHERE usage.workspace_id = requested_workspace_id
    AND usage.metric = requested_metric AND usage.period_key = requested_period_key
  RETURNING usage.* INTO usage_row;
  INSERT INTO roomscan.quota_ledger_v2 (
    workspace_id, period_key, idempotency_key, action, metric,
    delta_used, delta_reserved, policy_version,
    reconciliation_generation, recorded_at
  ) VALUES (
    requested_workspace_id, requested_period_key,
    'reconcile:' || requested_metric::text || ':' || requested_generation::text,
    'reconcile', requested_metric, requested_authoritative_used - prior_used, 0,
    usage_row.policy_version, requested_generation, reconciled_at_time
  );
  RETURN QUERY SELECT true, usage_row.used, usage_row.reconciliation_generation;
END
$function$;

RESET ROLE;

ALTER FUNCTION roomscan.hosted_mutation_grant_matches(uuid, text, bigint, bigint, bigint, bigint) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.activate_quota_policy_v2(uuid, bigint, text, text, text, bigint, bigint, bigint, bigint, bigint, integer, bigint, bigint, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.quota_snapshot_v2(bytea, timestamptz, roomscan.quota_metric, text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.reserve_quota_v2(bytea, timestamptz, roomscan.quota_metric, text, text, text, text, bigint, text, bigint, timestamptz, bigint, bigint, bigint, bigint) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.finalize_quota_v2(bytea, timestamptz, text, text, bigint, bigint, bigint, bigint, bigint) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.release_quota_v2(bytea, timestamptz, text, text, text, bigint, bigint, bigint, bigint) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.reconcile_quota_v2(uuid, roomscan.quota_metric, text, bigint, bigint, bigint, bigint, timestamptz) OWNER TO roomscan_policy;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA roomscan FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA roomscan FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE ON roomscan.quota_policy_versions_v2,
  roomscan.quota_usage_v2, roomscan.quota_reservations_v2,
  roomscan.quota_reconciliations_v2 TO roomscan_policy;
GRANT SELECT, INSERT ON roomscan.quota_ledger_v2 TO roomscan_policy;
GRANT SELECT ON roomscan.projects TO roomscan_policy;
GRANT EXECUTE ON FUNCTION
  roomscan.activate_quota_policy_v2(uuid, bigint, text, text, text, bigint, bigint, bigint, bigint, bigint, integer, bigint, bigint, timestamptz),
  roomscan.reconcile_quota_v2(uuid, roomscan.quota_metric, text, bigint, bigint, bigint, bigint, timestamptz)
  TO roomscan_operator;
GRANT EXECUTE ON FUNCTION
  roomscan.quota_snapshot_v2(bytea, timestamptz, roomscan.quota_metric, text),
  roomscan.reserve_quota_v2(bytea, timestamptz, roomscan.quota_metric, text, text, text, text, bigint, text, bigint, timestamptz, bigint, bigint, bigint, bigint),
  roomscan.finalize_quota_v2(bytea, timestamptz, text, text, bigint, bigint, bigint, bigint, bigint),
  roomscan.release_quota_v2(bytea, timestamptz, text, text, text, bigint, bigint, bigint, bigint)
  TO roomscan_api_runtime;

COMMENT ON FUNCTION roomscan.reserve_quota_v2(bytea, timestamptz, roomscan.quota_metric, text, text, text, text, bigint, text, bigint, timestamptz, bigint, bigint, bigint, bigint) IS
  'Session-derived workspace, fixed metric/action/resource/period and versioned literal-true hosted/publication grant; exact retry; no deletion; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.reconcile_quota_v2(uuid, roomscan.quota_metric, text, bigint, bigint, bigint, bigint, timestamptz) IS
  'NOLOGIN operator reconciliation with durable exact-generation history; stale ignore and newer increase/decrease; fixed search_path; PUBLIC revoked.';

RESET ROLE;

-- Section D: provider-account-derived Stripe receipts and one durable dirty
-- reconciliation outbox per workspace. Ingestion never applies event deltas.
SET ROLE roomscan_owner;

CREATE TABLE roomscan.stripe_provider_accounts (
  provider_account_id text PRIMARY KEY
    CHECK (provider_account_id ~ '^acct_[A-Za-z0-9]{6,255}$'),
  account_mode text NOT NULL CHECK (account_mode IN ('platform', 'connected')),
  UNIQUE (provider_account_id, account_mode)
);

CREATE TABLE roomscan.stripe_billing_bindings (
  workspace_id uuid PRIMARY KEY REFERENCES roomscan.workspaces(id) ON DELETE RESTRICT,
  account_mode text NOT NULL CHECK (account_mode IN ('platform', 'connected')),
  provider_account_id text NOT NULL CHECK (provider_account_id ~ '^acct_[A-Za-z0-9]{6,255}$'),
  billing_customer_id text NOT NULL CHECK (billing_customer_id ~ '^cus_[A-Za-z0-9]{6,255}$'),
  subscription_id text NOT NULL CHECK (subscription_id ~ '^sub_[A-Za-z0-9]{6,255}$'),
  bound_at timestamptz NOT NULL,
  UNIQUE (provider_account_id, billing_customer_id),
  UNIQUE (provider_account_id, subscription_id),
  UNIQUE (provider_account_id, billing_customer_id, subscription_id),
  UNIQUE (provider_account_id, account_mode, billing_customer_id, subscription_id),
  FOREIGN KEY (provider_account_id, account_mode)
    REFERENCES roomscan.stripe_provider_accounts(provider_account_id, account_mode)
    ON DELETE RESTRICT
);
CREATE UNIQUE INDEX stripe_connected_account_one_workspace
  ON roomscan.stripe_billing_bindings (provider_account_id)
  WHERE account_mode = 'connected';

CREATE TABLE roomscan.stripe_event_receipts_v2 (
  account_mode text NOT NULL CHECK (account_mode IN ('platform', 'connected')),
  provider_account_id text NOT NULL CHECK (provider_account_id ~ '^acct_[A-Za-z0-9]{6,255}$'),
  billing_customer_id text NOT NULL CHECK (billing_customer_id ~ '^cus_[A-Za-z0-9]{6,255}$'),
  subscription_id text NOT NULL CHECK (subscription_id ~ '^sub_[A-Za-z0-9]{6,255}$'),
  event_id text NOT NULL CHECK (event_id ~ '^evt_[A-Za-z0-9]{6,255}$'),
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE RESTRICT,
  event_type text NOT NULL CHECK (length(event_type) BETWEEN 1 AND 255),
  object_id text NOT NULL CHECK (length(object_id) BETWEEN 1 AND 255),
  payload_sha256 bytea NOT NULL CHECK (octet_length(payload_sha256) = 32),
  provider_occurred_at timestamptz NOT NULL,
  received_at timestamptz NOT NULL,
  PRIMARY KEY (provider_account_id, event_id),
  FOREIGN KEY (provider_account_id, account_mode, billing_customer_id, subscription_id)
    REFERENCES roomscan.stripe_billing_bindings(
      provider_account_id, account_mode, billing_customer_id, subscription_id
    ) ON DELETE RESTRICT
);

CREATE TABLE roomscan.stripe_reconciliation_outbox (
  workspace_id uuid PRIMARY KEY REFERENCES roomscan.workspaces(id) ON DELETE RESTRICT,
  account_mode text NOT NULL CHECK (account_mode IN ('platform', 'connected')),
  provider_account_id text NOT NULL CHECK (provider_account_id ~ '^acct_[A-Za-z0-9]{6,255}$'),
  billing_customer_id text NOT NULL CHECK (billing_customer_id ~ '^cus_[A-Za-z0-9]{6,255}$'),
  subscription_id text NOT NULL CHECK (subscription_id ~ '^sub_[A-Za-z0-9]{6,255}$'),
  desired_generation bigint NOT NULL DEFAULT 0 CHECK (desired_generation >= 0),
  applied_generation bigint NOT NULL DEFAULT 0 CHECK (applied_generation >= 0),
  last_event_type text CHECK (last_event_type IS NULL OR length(last_event_type) BETWEEN 1 AND 255),
  last_object_id text CHECK (last_object_id IS NULL OR length(last_object_id) BETWEEN 1 AND 255),
  lease_id text CHECK (
    lease_id IS NULL OR (
      length(lease_id) BETWEEN 1 AND 128 AND lease_id ~ '^[A-Za-z0-9_-]+$'
    )
  ),
  lease_generation bigint CHECK (lease_generation IS NULL OR lease_generation > 0),
  lease_expires_at timestamptz,
  updated_at timestamptz NOT NULL,
  CHECK (applied_generation <= desired_generation),
  CHECK (
    (lease_id IS NULL AND lease_generation IS NULL AND lease_expires_at IS NULL)
    OR (lease_id IS NOT NULL AND lease_generation IS NOT NULL AND lease_expires_at IS NOT NULL)
  ),
  FOREIGN KEY (provider_account_id, account_mode, billing_customer_id, subscription_id)
    REFERENCES roomscan.stripe_billing_bindings(
      provider_account_id, account_mode, billing_customer_id, subscription_id
    ) ON DELETE RESTRICT
);
CREATE UNIQUE INDEX stripe_reconciliation_outbox_lease_unique
  ON roomscan.stripe_reconciliation_outbox (lease_id) WHERE lease_id IS NOT NULL;

ALTER TABLE roomscan.stripe_billing_bindings ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.stripe_billing_bindings FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.stripe_event_receipts_v2 ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.stripe_event_receipts_v2 FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.stripe_reconciliation_outbox ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.stripe_reconciliation_outbox FORCE ROW LEVEL SECURITY;
CREATE POLICY stripe_billing_bindings_tenant_isolation ON roomscan.stripe_billing_bindings
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));
CREATE POLICY stripe_event_receipts_v2_tenant_isolation ON roomscan.stripe_event_receipts_v2
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));
CREATE POLICY stripe_reconciliation_outbox_tenant_isolation ON roomscan.stripe_reconciliation_outbox
  FOR ALL TO PUBLIC USING (roomscan.has_authorized_tenant(workspace_id))
  WITH CHECK (roomscan.has_authorized_tenant(workspace_id));

CREATE FUNCTION roomscan.bind_stripe_account(
  requested_workspace_id uuid,
  requested_account_mode text,
  requested_provider_account_id text,
  requested_billing_customer_id text,
  requested_subscription_id text,
  bound_at_time timestamptz
)
RETURNS text
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  existing roomscan.stripe_billing_bindings%ROWTYPE;
  authoritative_account_mode text;
  inserted_workspace_id uuid;
BEGIN
  IF requested_workspace_id IS NULL OR requested_account_mode IS NULL
    OR requested_provider_account_id IS NULL OR requested_billing_customer_id IS NULL
    OR requested_subscription_id IS NULL OR bound_at_time IS NULL
    OR requested_account_mode NOT IN ('platform', 'connected')
    OR requested_provider_account_id !~ '^acct_[A-Za-z0-9]{6,255}$'
    OR requested_billing_customer_id !~ '^cus_[A-Za-z0-9]{6,255}$'
    OR requested_subscription_id !~ '^sub_[A-Za-z0-9]{6,255}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_STRIPE_ACCOUNT_BINDING';
  END IF;
  -- Platform accounts may carry many exact workspace customer/subscription
  -- scopes, but a connected account is exclusive in both directions.  Lock
  -- the server-owned provider account before inspecting either mode so
  -- concurrent platform/connected attempts cannot both commit.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'stripe-binding:' || requested_provider_account_id,
      7621846213719048
    )
  );
  PERFORM 1 FROM roomscan.workspaces WHERE id = requested_workspace_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'UNKNOWN_WORKSPACE'; END IF;

  -- This global parent row is the storage-enforced provider-account mode
  -- invariant. ON CONFLICT arbitrates against rows outside an RR/SERIALIZABLE
  -- snapshot; a stale snapshot must retry rather than infer that no row exists.
  BEGIN
    INSERT INTO roomscan.stripe_provider_accounts (
      provider_account_id, account_mode
    ) VALUES (
      requested_provider_account_id, requested_account_mode
    )
    ON CONFLICT (provider_account_id) DO NOTHING
    RETURNING account_mode INTO authoritative_account_mode;
  EXCEPTION WHEN serialization_failure THEN
    RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'STRIPE_BINDING_RETRY_REQUIRED';
  END;
  IF authoritative_account_mode IS NULL THEN
    SELECT account.account_mode INTO authoritative_account_mode
    FROM roomscan.stripe_provider_accounts AS account
    WHERE account.provider_account_id = requested_provider_account_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'STRIPE_BINDING_RETRY_REQUIRED';
    END IF;
  END IF;
  IF authoritative_account_mode IS DISTINCT FROM requested_account_mode THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'STRIPE_BINDING_CONFLICT';
  END IF;

  SELECT mapping.* INTO existing
  FROM roomscan.stripe_billing_bindings AS mapping
  WHERE mapping.workspace_id = requested_workspace_id
     OR (mapping.provider_account_id = requested_provider_account_id
       AND (mapping.billing_customer_id = requested_billing_customer_id
         OR mapping.subscription_id = requested_subscription_id
         OR mapping.account_mode = 'connected'
         OR requested_account_mode = 'connected'))
  ORDER BY (mapping.workspace_id = requested_workspace_id) DESC
  LIMIT 1
  FOR UPDATE;
  IF FOUND THEN
    IF existing.workspace_id IS DISTINCT FROM requested_workspace_id
      OR existing.account_mode IS DISTINCT FROM requested_account_mode
      OR existing.provider_account_id IS DISTINCT FROM requested_provider_account_id
      OR existing.billing_customer_id IS DISTINCT FROM requested_billing_customer_id
      OR existing.subscription_id IS DISTINCT FROM requested_subscription_id THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'STRIPE_BINDING_CONFLICT';
    END IF;
    RETURN 'existing';
  END IF;
  BEGIN
    INSERT INTO roomscan.stripe_billing_bindings (
    workspace_id, account_mode, provider_account_id,
    billing_customer_id, subscription_id, bound_at
    ) VALUES (
      requested_workspace_id, requested_account_mode, requested_provider_account_id,
      requested_billing_customer_id, requested_subscription_id, bound_at_time
    )
    ON CONFLICT DO NOTHING
    RETURNING workspace_id INTO inserted_workspace_id;
  EXCEPTION WHEN serialization_failure THEN
    RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'STRIPE_BINDING_RETRY_REQUIRED';
  END;
  IF inserted_workspace_id IS NULL THEN
    SELECT mapping.* INTO existing
    FROM roomscan.stripe_billing_bindings AS mapping
    WHERE mapping.workspace_id = requested_workspace_id
       OR (mapping.provider_account_id = requested_provider_account_id
         AND (mapping.billing_customer_id = requested_billing_customer_id
           OR mapping.subscription_id = requested_subscription_id
           OR mapping.account_mode = 'connected'
           OR requested_account_mode = 'connected'))
    ORDER BY (mapping.workspace_id = requested_workspace_id) DESC
    LIMIT 1;
    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'STRIPE_BINDING_RETRY_REQUIRED';
    END IF;
    IF existing.workspace_id IS DISTINCT FROM requested_workspace_id
      OR existing.account_mode IS DISTINCT FROM requested_account_mode
      OR existing.provider_account_id IS DISTINCT FROM requested_provider_account_id
      OR existing.billing_customer_id IS DISTINCT FROM requested_billing_customer_id
      OR existing.subscription_id IS DISTINCT FROM requested_subscription_id THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'STRIPE_BINDING_CONFLICT';
    END IF;
    RETURN 'existing';
  END IF;
  INSERT INTO roomscan.stripe_reconciliation_outbox (
    workspace_id, account_mode, provider_account_id, billing_customer_id,
    subscription_id, desired_generation, applied_generation, updated_at
  ) VALUES (
    requested_workspace_id, requested_account_mode, requested_provider_account_id,
    requested_billing_customer_id, requested_subscription_id, 0, 0, bound_at_time
  );
  RETURN 'bound';
END
$function$;

CREATE FUNCTION roomscan.accept_stripe_event_v2(
  requested_account_mode text,
  requested_provider_account_id text,
  requested_billing_customer_id text,
  requested_subscription_id text,
  requested_event_id text,
  requested_event_type text,
  requested_object_id text,
  requested_payload_sha256 bytea,
  requested_provider_occurred_at timestamptz,
  requested_received_at timestamptz
)
RETURNS TABLE (status text, workspace_id uuid, generation bigint)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  target_workspace_id uuid;
  existing roomscan.stripe_event_receipts_v2%ROWTYPE;
  inserted_workspace_id uuid;
  next_generation bigint;
BEGIN
  IF requested_account_mode IS NULL OR requested_provider_account_id IS NULL
    OR requested_billing_customer_id IS NULL OR requested_subscription_id IS NULL
    OR requested_event_id IS NULL
    OR requested_event_type IS NULL OR requested_object_id IS NULL
    OR requested_payload_sha256 IS NULL OR requested_provider_occurred_at IS NULL
    OR requested_received_at IS NULL
    OR requested_account_mode NOT IN ('platform', 'connected')
    OR requested_provider_account_id !~ '^acct_[A-Za-z0-9]{6,255}$'
    OR requested_billing_customer_id !~ '^cus_[A-Za-z0-9]{6,255}$'
    OR requested_subscription_id !~ '^sub_[A-Za-z0-9]{6,255}$'
    OR requested_event_id !~ '^evt_[A-Za-z0-9]{6,255}$'
    OR length(requested_event_type) NOT BETWEEN 1 AND 255
    OR length(requested_object_id) NOT BETWEEN 1 AND 255
    OR requested_object_id IS DISTINCT FROM requested_subscription_id
    OR requested_event_type NOT IN (
      'customer.subscription.created',
      'customer.subscription.deleted',
      'customer.subscription.paused',
      'customer.subscription.resumed',
      'customer.subscription.trial_will_end',
      'customer.subscription.updated'
    )
    OR octet_length(requested_payload_sha256) <> 32 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_STRIPE_EVENT_V2';
  END IF;
  -- Receipt identity is account-global even when one platform account is
  -- bound to multiple workspaces. Serialize that exact key before taking a
  -- workspace outbox lock so concurrent cross-binding reuse is classified as
  -- an explicit retry conflict, never an incidental unique-key exception.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      requested_provider_account_id || E'\\x1f' || requested_event_id,
      0
    )
  );
  SELECT mapping.workspace_id INTO target_workspace_id
  FROM roomscan.stripe_billing_bindings AS mapping
  WHERE mapping.account_mode = requested_account_mode
    AND mapping.provider_account_id = requested_provider_account_id
    AND mapping.billing_customer_id = requested_billing_customer_id
    AND mapping.subscription_id = requested_subscription_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'STRIPE_ACCOUNT_UNMAPPED';
  END IF;
  -- Unique receipt storage arbitrates before the mutable workspace outbox.
  -- That order makes exact/conflicting retries deterministic even when an
  -- RR/SERIALIZABLE caller's snapshot predates the winning receipt.
  BEGIN
    INSERT INTO roomscan.stripe_event_receipts_v2 AS inserted_receipt (
      account_mode, provider_account_id, billing_customer_id, subscription_id,
      event_id, workspace_id, event_type, object_id, payload_sha256,
      provider_occurred_at, received_at
    ) VALUES (
      requested_account_mode, requested_provider_account_id,
      requested_billing_customer_id, requested_subscription_id,
      requested_event_id, target_workspace_id, requested_event_type,
      requested_object_id, requested_payload_sha256,
      requested_provider_occurred_at, requested_received_at
    )
    ON CONFLICT (provider_account_id, event_id) DO NOTHING
    RETURNING inserted_receipt.workspace_id INTO inserted_workspace_id;
  EXCEPTION WHEN serialization_failure THEN
    RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'STRIPE_EVENT_RETRY_REQUIRED';
  END;
  IF inserted_workspace_id IS NULL THEN
    SELECT receipt.* INTO existing
    FROM roomscan.stripe_event_receipts_v2 AS receipt
    WHERE receipt.provider_account_id = requested_provider_account_id
      AND receipt.event_id = requested_event_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'STRIPE_EVENT_RETRY_REQUIRED';
    END IF;
    IF existing.workspace_id IS DISTINCT FROM target_workspace_id
      OR existing.account_mode IS DISTINCT FROM requested_account_mode
      OR existing.billing_customer_id IS DISTINCT FROM requested_billing_customer_id
      OR existing.subscription_id IS DISTINCT FROM requested_subscription_id
      OR existing.event_type IS DISTINCT FROM requested_event_type
      OR existing.object_id IS DISTINCT FROM requested_object_id
      OR existing.payload_sha256 IS DISTINCT FROM requested_payload_sha256
      OR existing.provider_occurred_at IS DISTINCT FROM requested_provider_occurred_at THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'STRIPE_EVENT_KEY_REUSED';
    END IF;
    SELECT outbox.desired_generation INTO next_generation
    FROM roomscan.stripe_reconciliation_outbox AS outbox
    WHERE outbox.workspace_id = target_workspace_id;
    RETURN QUERY SELECT 'duplicate'::text, target_workspace_id, next_generation;
    RETURN;
  END IF;
  BEGIN
    PERFORM 1 FROM roomscan.stripe_reconciliation_outbox AS outbox
    WHERE outbox.workspace_id = target_workspace_id FOR UPDATE;
    UPDATE roomscan.stripe_reconciliation_outbox AS outbox
    SET desired_generation = outbox.desired_generation + 1,
        last_event_type = requested_event_type,
        last_object_id = requested_object_id,
        updated_at = requested_received_at
    WHERE outbox.workspace_id = target_workspace_id
    RETURNING outbox.desired_generation INTO next_generation;
  EXCEPTION WHEN serialization_failure THEN
    RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'STRIPE_EVENT_RETRY_REQUIRED';
  END;
  RETURN QUERY SELECT 'accepted'::text, target_workspace_id, next_generation;
END
$function$;

CREATE FUNCTION roomscan.claim_stripe_reconciliation_v2(
  requested_lease_id text,
  claimed_at_time timestamptz,
  requested_lease_expires_at timestamptz
)
RETURNS TABLE (
  workspace_id uuid,
  account_mode text,
  provider_account_id text,
  billing_customer_id text,
  subscription_id text,
  generation bigint,
  lease_id text,
  last_event_type text,
  last_object_id text,
  hosted_global_version bigint,
  hosted_workspace_version bigint
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  IF requested_lease_id IS NULL OR claimed_at_time IS NULL
    OR requested_lease_expires_at IS NULL
    OR length(requested_lease_id) NOT BETWEEN 1 AND 128
    OR requested_lease_id !~ '^[A-Za-z0-9_-]+$'
    OR requested_lease_expires_at <= claimed_at_time THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_STRIPE_RECONCILIATION_LEASE';
  END IF;
  RETURN QUERY
  WITH candidate AS (
    SELECT candidate_outbox.workspace_id,
      global_flag.version AS global_version,
      workspace_flag.version AS workspace_version
    FROM roomscan.stripe_reconciliation_outbox AS candidate_outbox
    JOIN roomscan.global_operational_flags AS global_flag
      ON global_flag.flag_key = 'hosted_operations_enabled'
     AND global_flag.enabled IS TRUE
     AND global_flag.version > 0
    JOIN roomscan.workspace_operational_flags AS workspace_flag
      ON workspace_flag.workspace_id = candidate_outbox.workspace_id
     AND workspace_flag.flag_key = 'hosted_operations_enabled'
     AND workspace_flag.enabled IS TRUE
     AND workspace_flag.version > 0
    WHERE candidate_outbox.desired_generation > candidate_outbox.applied_generation
      AND (candidate_outbox.lease_id IS NULL
        OR candidate_outbox.lease_expires_at <= claimed_at_time)
    ORDER BY candidate_outbox.updated_at, candidate_outbox.workspace_id
    FOR UPDATE OF candidate_outbox SKIP LOCKED
    LIMIT 1
  )
  UPDATE roomscan.stripe_reconciliation_outbox AS outbox
  SET lease_id = requested_lease_id,
      lease_generation = outbox.desired_generation,
      lease_expires_at = requested_lease_expires_at,
      updated_at = claimed_at_time
  FROM candidate
  WHERE outbox.workspace_id = candidate.workspace_id
  RETURNING outbox.workspace_id, outbox.account_mode,
    outbox.provider_account_id, outbox.billing_customer_id,
    outbox.subscription_id,
    outbox.lease_generation, outbox.lease_id,
    outbox.last_event_type, outbox.last_object_id,
    candidate.global_version, candidate.workspace_version;
END
$function$;

CREATE FUNCTION roomscan.release_stripe_reconciliation_v2(
  requested_lease_id text,
  requested_account_mode text,
  requested_provider_account_id text,
  requested_billing_customer_id text,
  requested_subscription_id text,
  requested_generation bigint,
  released_at_time timestamptz
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  IF requested_lease_id IS NULL OR requested_account_mode IS NULL
    OR requested_provider_account_id IS NULL OR requested_billing_customer_id IS NULL
    OR requested_subscription_id IS NULL
    OR requested_generation IS NULL OR released_at_time IS NULL
    OR length(requested_lease_id) NOT BETWEEN 1 AND 128
    OR requested_account_mode NOT IN ('platform', 'connected')
    OR requested_provider_account_id !~ '^acct_[A-Za-z0-9]{6,255}$'
    OR requested_billing_customer_id !~ '^cus_[A-Za-z0-9]{6,255}$'
    OR requested_subscription_id !~ '^sub_[A-Za-z0-9]{6,255}$'
    OR requested_generation < 1 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_STRIPE_RECONCILIATION_RELEASE';
  END IF;
  UPDATE roomscan.stripe_reconciliation_outbox AS outbox
  SET lease_id = NULL, lease_generation = NULL, lease_expires_at = NULL,
      updated_at = released_at_time
  WHERE outbox.account_mode = requested_account_mode
    AND outbox.provider_account_id = requested_provider_account_id
    AND outbox.billing_customer_id = requested_billing_customer_id
    AND outbox.subscription_id = requested_subscription_id
    AND outbox.lease_id = requested_lease_id
    AND outbox.lease_generation = requested_generation
    AND outbox.lease_expires_at > released_at_time;
  RETURN FOUND;
END
$function$;

CREATE FUNCTION roomscan.complete_stripe_reconciliation_v2(
  requested_lease_id text,
  requested_account_mode text,
  requested_provider_account_id text,
  requested_billing_customer_id text,
  requested_subscription_id text,
  requested_generation bigint,
  requested_source_observed_at timestamptz,
  requested_subscription_status text,
  requested_plan_key text,
  requested_current_period_end timestamptz,
  applied_at_time timestamptz,
  hosted_global_version bigint,
  hosted_workspace_version bigint
)
RETURNS TABLE (status text, needs_another_generation boolean)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE outbox roomscan.stripe_reconciliation_outbox%ROWTYPE;
DECLARE current_state roomscan.subscription_states%ROWTYPE;
BEGIN
  -- current_period_end is explicitly optional and compared/persisted NULL-safely.
  IF requested_lease_id IS NULL OR requested_account_mode IS NULL
    OR requested_provider_account_id IS NULL OR requested_billing_customer_id IS NULL
    OR requested_subscription_id IS NULL
    OR requested_generation IS NULL OR requested_source_observed_at IS NULL
    OR requested_subscription_status IS NULL OR requested_plan_key IS NULL
    OR applied_at_time IS NULL OR hosted_global_version IS NULL
    OR hosted_workspace_version IS NULL
    OR length(requested_lease_id) NOT BETWEEN 1 AND 128
    OR requested_account_mode NOT IN ('platform', 'connected')
    OR requested_provider_account_id !~ '^acct_[A-Za-z0-9]{6,255}$'
    OR requested_billing_customer_id !~ '^cus_[A-Za-z0-9]{6,255}$'
    OR requested_subscription_id !~ '^sub_[A-Za-z0-9]{6,255}$'
    OR requested_generation < 1
    OR requested_subscription_status NOT IN (
      'inactive', 'trialing', 'active', 'past_due', 'canceled', 'read_only_grace'
    ) OR length(requested_plan_key) NOT BETWEEN 1 AND 128 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_STRIPE_RECONCILIATION_COMPLETION';
  END IF;
  SELECT candidate.* INTO outbox
  FROM roomscan.stripe_reconciliation_outbox AS candidate
  WHERE candidate.account_mode = requested_account_mode
    AND candidate.provider_account_id = requested_provider_account_id
    AND candidate.billing_customer_id = requested_billing_customer_id
    AND candidate.subscription_id = requested_subscription_id
  FOR UPDATE;
  IF NOT FOUND OR outbox.lease_id IS DISTINCT FROM requested_lease_id
    OR outbox.lease_generation IS DISTINCT FROM requested_generation
    OR outbox.lease_expires_at <= applied_at_time THEN
    RETURN QUERY SELECT 'stale_claim'::text, true; RETURN;
  END IF;
  IF NOT roomscan.hosted_mutation_grant_matches(
    outbox.workspace_id, 'system.stripe.reconcile',
    hosted_global_version, hosted_workspace_version, NULL, NULL
  ) THEN
    UPDATE roomscan.stripe_reconciliation_outbox AS target
    SET lease_id = NULL, lease_generation = NULL, lease_expires_at = NULL,
        updated_at = applied_at_time
    WHERE target.workspace_id = outbox.workspace_id;
    RETURN QUERY SELECT 'hosted_gate_rejected'::text, true; RETURN;
  END IF;
  SELECT state.* INTO current_state
  FROM roomscan.subscription_states AS state
  WHERE state.workspace_id = outbox.workspace_id FOR UPDATE;
  IF FOUND AND current_state.source_observed_at IS NOT NULL
    AND current_state.source_observed_at > requested_source_observed_at THEN
    UPDATE roomscan.stripe_reconciliation_outbox AS target
    SET lease_id = NULL, lease_generation = NULL, lease_expires_at = NULL,
        updated_at = applied_at_time
    WHERE target.workspace_id = outbox.workspace_id;
    RETURN QUERY SELECT 'stale_claim'::text,
      (outbox.desired_generation > outbox.applied_generation); RETURN;
  END IF;

  INSERT INTO roomscan.stripe_reconciliation_generations (
    workspace_id, generation, source_observed_at, subscription_status,
    plan_key, current_period_end, applied, recorded_at
  ) VALUES (
    outbox.workspace_id, requested_generation, requested_source_observed_at,
    requested_subscription_status, requested_plan_key,
    requested_current_period_end, true, applied_at_time
  ) ON CONFLICT (workspace_id, generation) DO NOTHING;
  IF NOT FOUND THEN
    PERFORM 1 FROM roomscan.stripe_reconciliation_generations AS generation
    WHERE generation.workspace_id = outbox.workspace_id
      AND generation.generation = requested_generation
      AND generation.source_observed_at IS NOT DISTINCT FROM requested_source_observed_at
      AND generation.subscription_status IS NOT DISTINCT FROM requested_subscription_status
      AND generation.plan_key IS NOT DISTINCT FROM requested_plan_key
      AND generation.current_period_end IS NOT DISTINCT FROM requested_current_period_end
      AND generation.applied IS TRUE;
    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'STRIPE_RECONCILIATION_GENERATION_REUSED';
    END IF;
  END IF;
  INSERT INTO roomscan.subscription_states (
    workspace_id, plan_key, status, current_period_end,
    reconciliation_generation, source_observed_at, updated_at
  ) VALUES (
    outbox.workspace_id, requested_plan_key, requested_subscription_status,
    requested_current_period_end, requested_generation,
    requested_source_observed_at, applied_at_time
  ) ON CONFLICT (workspace_id) DO UPDATE
  SET plan_key = EXCLUDED.plan_key, status = EXCLUDED.status,
      current_period_end = EXCLUDED.current_period_end,
      reconciliation_generation = EXCLUDED.reconciliation_generation,
      source_observed_at = EXCLUDED.source_observed_at,
      updated_at = EXCLUDED.updated_at;
  UPDATE roomscan.stripe_reconciliation_outbox AS target
  SET applied_generation = requested_generation,
      lease_id = NULL, lease_generation = NULL, lease_expires_at = NULL,
      updated_at = applied_at_time
  WHERE target.workspace_id = outbox.workspace_id;
  RETURN QUERY SELECT 'applied'::text,
    (outbox.desired_generation > requested_generation);
END
$function$;

RESET ROLE;

ALTER FUNCTION roomscan.bind_stripe_account(uuid, text, text, text, text, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.accept_stripe_event_v2(text, text, text, text, text, text, text, bytea, timestamptz, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.claim_stripe_reconciliation_v2(text, timestamptz, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.release_stripe_reconciliation_v2(text, text, text, text, text, bigint, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.complete_stripe_reconciliation_v2(text, text, text, text, text, bigint, timestamptz, text, text, timestamptz, timestamptz, bigint, bigint) OWNER TO roomscan_policy;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA roomscan FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA roomscan FROM PUBLIC;
GRANT SELECT, INSERT ON roomscan.stripe_provider_accounts TO roomscan_policy;
GRANT SELECT, INSERT, UPDATE ON roomscan.stripe_billing_bindings TO roomscan_policy;
GRANT SELECT, INSERT ON roomscan.stripe_event_receipts_v2 TO roomscan_policy;
GRANT SELECT, INSERT, UPDATE ON roomscan.stripe_reconciliation_outbox,
  roomscan.subscription_states, roomscan.stripe_reconciliation_generations
  TO roomscan_policy;
GRANT EXECUTE ON FUNCTION roomscan.bind_stripe_account(uuid, text, text, text, text, timestamptz)
  TO roomscan_operator;
GRANT EXECUTE ON FUNCTION roomscan.accept_stripe_event_v2(text, text, text, text, text, text, text, bytea, timestamptz, timestamptz)
  TO roomscan_stripe_ingress_runtime;
GRANT EXECUTE ON FUNCTION
  roomscan.claim_stripe_reconciliation_v2(text, timestamptz, timestamptz),
  roomscan.release_stripe_reconciliation_v2(text, text, text, text, text, bigint, timestamptz),
  roomscan.complete_stripe_reconciliation_v2(text, text, text, text, text, bigint, timestamptz, text, text, timestamptz, timestamptz, bigint, bigint)
  TO roomscan_stripe_reconciliation_runtime;

COMMENT ON FUNCTION roomscan.accept_stripe_event_v2(text, text, text, text, text, text, text, bytea, timestamptz, timestamptz) IS
  'Server-bound account-mode/account/customer/subscription durable receipt and dirty generation. Supported subscription events only; exact signed scope/metadata/digest/timestamp retry; no workspace input or account-only fallback; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.complete_stripe_reconciliation_v2(text, text, text, text, text, bigint, timestamptz, text, text, timestamptz, timestamptz, bigint, bigint) IS
  'Exact unexpired lease plus original versioned literal-true hosted grant; whole current snapshot only; event-during-fetch retained; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.claim_stripe_reconciliation_v2(text, timestamptz, timestamptz) IS
  'Stripe worker-only server-selected dirty workspace claim; literal-true positive-version global/workspace hosted flags are returned as immutable claim authority for completion recheck; SKIP LOCKED, no caller workspace; fixed search_path; PUBLIC revoked.';

RESET ROLE;

-- Section B composite reducers (declared after quota storage so member slots
-- and member_count move atomically).
SET ROLE roomscan_owner;

CREATE FUNCTION roomscan.append_workspace_audit_v2(
  requested_workspace_id uuid,
  requested_event_id text,
  requested_actor_principal_id uuid,
  requested_action text,
  requested_subject_kind text,
  requested_subject_id text,
  requested_authorization_version bigint,
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
  IF requested_workspace_id IS NULL OR requested_event_id IS NULL
    OR requested_actor_principal_id IS NULL OR requested_action IS NULL
    OR requested_subject_kind IS NULL OR requested_subject_id IS NULL
    OR occurred_at_time IS NULL
    OR requested_event_id !~ '^aud_[A-Za-z0-9_-]{16,128}$'
    OR requested_action NOT IN (
      'membership.invited', 'membership.invitation_revoked',
      'membership.invitation_accepted', 'membership.role_changed',
      'membership.removed'
    )
    OR length(requested_subject_kind) NOT BETWEEN 1 AND 80
    OR length(requested_subject_id) NOT BETWEEN 1 AND 512
    OR (requested_authorization_version IS NOT NULL
      AND requested_authorization_version < 1) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_MEMBERSHIP_AUDIT';
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
    requested_workspace_id, next_value, requested_event_id,
    requested_actor_principal_id, requested_action,
    requested_subject_kind, requested_subject_id,
    requested_authorization_version, occurred_at_time
  );
  RETURN next_value;
END
$function$;

CREATE FUNCTION roomscan.create_invitation_v2(
  access_token_hash bytea,
  authoritative_time timestamptz,
  requested_public_id text,
  requested_token_hash bytea,
  requested_invited_email text,
  requested_role text,
  requested_expires_at timestamptz,
  hosted_global_version bigint,
  hosted_workspace_version bigint,
  requested_audit_event_id text
)
RETURNS SETOF roomscan.invitations
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record; created roomscan.invitations%ROWTYPE;
DECLARE required_action text;
BEGIN
  -- invited_email is optional; NULL represents an Apple relay or out-of-band
  -- delivery identity. It is never used to link a canonical principal.
  IF access_token_hash IS NULL OR authoritative_time IS NULL
    OR requested_public_id IS NULL OR requested_token_hash IS NULL
    OR requested_role IS NULL OR requested_expires_at IS NULL
    OR hosted_global_version IS NULL OR hosted_workspace_version IS NULL
    OR requested_audit_event_id IS NULL
    OR octet_length(access_token_hash) <> 32 OR octet_length(requested_token_hash) <> 32
    OR requested_public_id !~ '^inv_[A-Za-z0-9_-]{16,128}$'
    OR requested_role NOT IN ('admin', 'editor', 'viewer')
    OR requested_expires_at <= authoritative_time
    OR (requested_invited_email IS NOT NULL
      AND length(requested_invited_email) NOT BETWEEN 3 AND 320)
    OR requested_audit_event_id !~ '^aud_[A-Za-z0-9_-]{16,128}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_INVITATION_CREATE_V2';
  END IF;
  SELECT * INTO context_row FROM roomscan.resolve_access_context(access_token_hash, authoritative_time);
  IF NOT FOUND OR context_row.workspace_id IS NULL
    OR context_row.recent_authentication IS DISTINCT FROM true
    OR context_row.role NOT IN ('owner', 'admin')
    OR (requested_role = 'admin' AND context_row.role <> 'owner') THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'MEMBER_INVITE_AUTHORIZATION_REQUIRED';
  END IF;
  required_action := 'member.invite.' || requested_role;
  IF NOT roomscan.hosted_mutation_grant_matches(
    context_row.workspace_id, required_action,
    hosted_global_version, hosted_workspace_version, NULL, NULL
  ) THEN RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'HOSTED_GRANT_REJECTED'; END IF;
  INSERT INTO roomscan.invitations (
    id, public_id, workspace_id, token_hash, invited_email, invited_role,
    expires_at, created_by_principal_id, created_at, updated_at, state, version
  ) VALUES (
    gen_random_uuid(), requested_public_id, context_row.workspace_id,
    requested_token_hash, requested_invited_email, requested_role,
    requested_expires_at, context_row.principal_id, authoritative_time,
    authoritative_time, 'active', 1
  ) RETURNING * INTO created;
  PERFORM roomscan.append_workspace_audit_v2(
    context_row.workspace_id, requested_audit_event_id,
    context_row.principal_id, 'membership.invited', 'invitation',
    requested_public_id, NULL, authoritative_time
  );
  RETURN NEXT created;
END
$function$;

CREATE FUNCTION roomscan.read_invitation_by_token(
  access_token_hash bytea,
  authoritative_time timestamptz,
  requested_token_hash bytea
)
RETURNS SETOF roomscan.invitations
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
BEGIN
  IF access_token_hash IS NULL OR authoritative_time IS NULL
    OR requested_token_hash IS NULL OR octet_length(access_token_hash) <> 32
    OR octet_length(requested_token_hash) <> 32 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_INVITATION_LOOKUP_V2';
  END IF;
  SELECT * INTO context_row FROM roomscan.resolve_access_context(access_token_hash, authoritative_time);
  IF NOT FOUND THEN RETURN; END IF;
  RETURN QUERY SELECT invitation.* FROM roomscan.invitations AS invitation
  WHERE invitation.token_hash = requested_token_hash
    AND invitation.state = 'active' AND invitation.expires_at > authoritative_time;
END
$function$;

CREATE FUNCTION roomscan.accept_invitation_v2(
  access_token_hash bytea,
  authoritative_time timestamptz,
  requested_token_hash bytea,
  expected_invitation_version bigint,
  hosted_global_version bigint,
  hosted_workspace_version bigint,
  requested_audit_event_id text
)
RETURNS TABLE (
  status text,
  workspace_id uuid,
  principal_id uuid,
  principal_canonical_id text,
  family_id uuid,
  family_public_id text,
  role text,
  authorization_version bigint,
  invitation_version bigint
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record; invitation roomscan.invitations%ROWTYPE;
DECLARE membership roomscan.memberships%ROWTYPE; usage roomscan.quota_usage_v2%ROWTYPE;
DECLARE next_authz bigint;
BEGIN
  IF access_token_hash IS NULL OR authoritative_time IS NULL
    OR requested_token_hash IS NULL OR expected_invitation_version IS NULL
    OR hosted_global_version IS NULL OR hosted_workspace_version IS NULL
    OR requested_audit_event_id IS NULL
    OR octet_length(access_token_hash) <> 32 OR octet_length(requested_token_hash) <> 32
    OR expected_invitation_version < 1
    OR requested_audit_event_id !~ '^aud_[A-Za-z0-9_-]{16,128}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_INVITATION_ACCEPT_V2';
  END IF;
  SELECT * INTO context_row FROM roomscan.resolve_access_context(access_token_hash, authoritative_time);
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHENTICATED_PRINCIPAL_REQUIRED'; END IF;
  SELECT candidate.* INTO invitation FROM roomscan.invitations AS candidate
  WHERE candidate.token_hash = requested_token_hash FOR UPDATE;
  IF NOT FOUND OR invitation.state <> 'active'
    OR invitation.version IS DISTINCT FROM expected_invitation_version
    OR invitation.expires_at <= authoritative_time THEN
    RETURN QUERY SELECT 'unavailable'::text, NULL::uuid, context_row.principal_id,
      context_row.canonical_principal_id, context_row.family_id,
      context_row.family_public_id, NULL::text, NULL::bigint, NULL::bigint;
    RETURN;
  END IF;
  IF NOT roomscan.hosted_mutation_grant_matches(
    invitation.workspace_id, 'member.invite.' || invitation.invited_role,
    hosted_global_version, hosted_workspace_version, NULL, NULL
  ) THEN RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'HOSTED_GRANT_REJECTED'; END IF;
  BEGIN
    PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
      'invitation-membership:' || invitation.workspace_id::text || ':'
        || context_row.principal_id::text,
      7621846213719049
    ));
    SELECT current.* INTO membership FROM roomscan.memberships AS current
    WHERE current.workspace_id = invitation.workspace_id
      AND current.principal_id = context_row.principal_id FOR UPDATE;
    IF FOUND AND membership.state = 'active' THEN
      RETURN QUERY SELECT 'already_member'::text, invitation.workspace_id,
        context_row.principal_id, context_row.canonical_principal_id,
        context_row.family_id, context_row.family_public_id,
        membership.role, membership.authorization_version, invitation.version;
      RETURN;
    END IF;
    IF EXISTS (
      SELECT 1 FROM roomscan.member_slots AS slot
      WHERE slot.workspace_id = invitation.workspace_id
        AND slot.principal_id = context_row.principal_id
    ) THEN RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'MEMBER_SLOT_STATE_MISMATCH'; END IF;

    IF membership.workspace_id IS NULL THEN
      INSERT INTO roomscan.memberships AS inserted_membership (
        id, workspace_id, principal_id, role, state, authorization_version,
        created_at, updated_at
      ) VALUES (
        gen_random_uuid(), invitation.workspace_id, context_row.principal_id,
        invitation.invited_role, 'active', 1, authoritative_time, authoritative_time
      )
      ON CONFLICT ON CONSTRAINT memberships_pkey DO NOTHING
      RETURNING inserted_membership.authorization_version INTO next_authz;
      IF next_authz IS NULL THEN
        SELECT current.* INTO membership FROM roomscan.memberships AS current
        WHERE current.workspace_id = invitation.workspace_id
          AND current.principal_id = context_row.principal_id;
        IF NOT FOUND THEN
          RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'INVITATION_ACCEPT_RETRY_REQUIRED';
        END IF;
        IF membership.state = 'active' THEN
          RETURN QUERY SELECT 'already_member'::text, invitation.workspace_id,
            context_row.principal_id, context_row.canonical_principal_id,
            context_row.family_id, context_row.family_public_id,
            membership.role, membership.authorization_version, invitation.version;
          RETURN;
        END IF;
        RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'MEMBERSHIP_STATE_CHANGED';
      END IF;
    ELSE
      UPDATE roomscan.memberships AS target
      SET role = invitation.invited_role, state = 'active', updated_at = authoritative_time
      WHERE target.workspace_id = invitation.workspace_id
        AND target.principal_id = context_row.principal_id
        AND target.state IN ('invited', 'removed')
      RETURNING target.authorization_version INTO next_authz;
      IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'MEMBERSHIP_STATE_CHANGED'; END IF;
    END IF;
  EXCEPTION WHEN serialization_failure THEN
    RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'INVITATION_ACCEPT_RETRY_REQUIRED';
  END;

  SELECT current.* INTO usage FROM roomscan.quota_usage_v2 AS current
  WHERE current.workspace_id = invitation.workspace_id
    AND current.metric = 'member_count'
    AND current.period_key = 'roomscan-period-v1:lifetime' FOR UPDATE;
  IF NOT FOUND OR usage.used + 1 > usage.limit_value THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'MEMBER_QUOTA_EXCEEDED';
  END IF;
  UPDATE roomscan.quota_usage_v2 AS target
  SET used = target.used + 1, updated_at = authoritative_time
  WHERE target.workspace_id = invitation.workspace_id
    AND target.metric = 'member_count'
    AND target.period_key = 'roomscan-period-v1:lifetime';
  UPDATE roomscan.invitations AS target
  SET state = 'consumed', version = target.version + 1,
      consumed_at = authoritative_time,
      consumed_by_principal_id = context_row.principal_id,
      updated_at = authoritative_time
  WHERE target.workspace_id = invitation.workspace_id AND target.id = invitation.id
    AND target.state = 'active' AND target.version = expected_invitation_version
  RETURNING target.version INTO invitation.version;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'INVITATION_CONSUME_RACE'; END IF;
  UPDATE roomscan.auth_session_families AS family
  SET state = 'revoked', revoked_at = authoritative_time,
      revoke_reason = 'membership_changed'
  WHERE family.principal_id = context_row.principal_id
    AND family.workspace_id = invitation.workspace_id AND family.state = 'active';
  PERFORM roomscan.append_workspace_audit_v2(
    invitation.workspace_id, requested_audit_event_id,
    context_row.principal_id, 'membership.invitation_accepted',
    'invitation', invitation.public_id, next_authz, authoritative_time
  );
  RETURN QUERY SELECT 'accepted'::text, invitation.workspace_id,
    context_row.principal_id, context_row.canonical_principal_id,
    context_row.family_id, context_row.family_public_id,
    invitation.invited_role, next_authz, invitation.version;
END
$function$;

CREATE FUNCTION roomscan.mutate_membership_v2(
  access_token_hash bytea,
  authoritative_time timestamptz,
  target_principal_canonical_id text,
  expected_authorization_version bigint,
  expected_role text,
  expected_state text,
  requested_role text,
  requested_state text,
  hosted_global_version bigint,
  hosted_workspace_version bigint,
  requested_audit_event_id text
)
RETURNS TABLE (
  workspace_id uuid,
  principal_id uuid,
  principal_canonical_id text,
  role text,
  state text,
  authorization_version bigint
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record; target roomscan.memberships%ROWTYPE;
DECLARE target_principal_id uuid; result_row roomscan.memberships%ROWTYPE;
DECLARE action_name text; slot_transition integer := 0; usage roomscan.quota_usage_v2%ROWTYPE;
BEGIN
  IF access_token_hash IS NULL OR authoritative_time IS NULL
    OR target_principal_canonical_id IS NULL OR expected_authorization_version IS NULL
    OR expected_role IS NULL OR expected_state IS NULL OR requested_role IS NULL
    OR requested_state IS NULL OR hosted_global_version IS NULL
    OR hosted_workspace_version IS NULL OR requested_audit_event_id IS NULL
    OR octet_length(access_token_hash) <> 32
    OR target_principal_canonical_id !~ '^prn_[A-Za-z0-9_-]{22,64}$'
    OR expected_authorization_version < 1
    OR expected_role NOT IN ('owner', 'admin', 'editor', 'viewer')
    OR requested_role NOT IN ('owner', 'admin', 'editor', 'viewer')
    OR expected_state NOT IN ('invited', 'active', 'removed')
    OR requested_state NOT IN ('invited', 'active', 'removed')
    OR requested_audit_event_id !~ '^aud_[A-Za-z0-9_-]{16,128}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_MEMBERSHIP_MUTATION_V2';
  END IF;
  SELECT * INTO context_row FROM roomscan.resolve_access_context(access_token_hash, authoritative_time);
  IF NOT FOUND OR context_row.workspace_id IS NULL
    OR context_row.recent_authentication IS DISTINCT FROM true
    OR context_row.role NOT IN ('owner', 'admin') THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'MEMBERSHIP_AUTHORIZATION_REQUIRED';
  END IF;
  PERFORM 1 FROM roomscan.workspaces WHERE id = context_row.workspace_id FOR UPDATE;
  SELECT principal.id INTO target_principal_id FROM roomscan.principals AS principal
  WHERE principal.canonical_id = target_principal_canonical_id AND principal.state = 'active';
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'MEMBERSHIP_NOT_FOUND'; END IF;
  SELECT membership.* INTO target FROM roomscan.memberships AS membership
  WHERE membership.workspace_id = context_row.workspace_id
    AND membership.principal_id = target_principal_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'MEMBERSHIP_NOT_FOUND'; END IF;
  IF target.authorization_version IS DISTINCT FROM expected_authorization_version
    OR target.role IS DISTINCT FROM expected_role OR target.state IS DISTINCT FROM expected_state THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'STALE_MEMBERSHIP';
  END IF;
  IF context_row.role = 'admin' AND (
    target.role NOT IN ('editor', 'viewer') OR requested_role NOT IN ('editor', 'viewer')
  ) THEN RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'MEMBERSHIP_ROLE_FORBIDDEN'; END IF;
  action_name := CASE WHEN requested_state = 'removed'
    THEN 'member.remove.' || target.role ELSE 'member.change.' || requested_role END;
  IF NOT roomscan.hosted_mutation_grant_matches(
    context_row.workspace_id, action_name,
    hosted_global_version, hosted_workspace_version, NULL, NULL
  ) THEN RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'HOSTED_GRANT_REJECTED'; END IF;
  IF target.role = 'owner' AND target.state = 'active'
    AND (requested_role <> 'owner' OR requested_state <> 'active')
    AND NOT EXISTS (
      SELECT 1 FROM roomscan.memberships AS owner_candidate
      WHERE owner_candidate.workspace_id = context_row.workspace_id
        AND owner_candidate.principal_id <> target_principal_id
        AND owner_candidate.role = 'owner' AND owner_candidate.state = 'active'
    ) THEN RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'LAST_OWNER_REQUIRED'; END IF;

  IF target.state = 'active' AND requested_state <> 'active' THEN slot_transition := -1;
  ELSIF target.state <> 'active' AND requested_state = 'active' THEN slot_transition := 1;
  END IF;
  IF slot_transition <> 0 THEN
    SELECT current.* INTO usage FROM roomscan.quota_usage_v2 AS current
    WHERE current.workspace_id = context_row.workspace_id
      AND current.metric = 'member_count'
      AND current.period_key = 'roomscan-period-v1:lifetime' FOR UPDATE;
    IF NOT FOUND OR (slot_transition = 1 AND usage.used + 1 > usage.limit_value) THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'MEMBER_QUOTA_EXCEEDED';
    END IF;
  END IF;
  UPDATE roomscan.memberships AS membership
  SET role = requested_role, state = requested_state, updated_at = authoritative_time
  WHERE membership.workspace_id = context_row.workspace_id
    AND membership.principal_id = target_principal_id
    AND membership.authorization_version = expected_authorization_version
    AND membership.role = expected_role AND membership.state = expected_state
  RETURNING membership.* INTO result_row;
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'STALE_MEMBERSHIP'; END IF;
  IF slot_transition <> 0 THEN
    UPDATE roomscan.quota_usage_v2 AS current
    SET used = current.used + slot_transition, updated_at = authoritative_time
    WHERE current.workspace_id = context_row.workspace_id
      AND current.metric = 'member_count'
      AND current.period_key = 'roomscan-period-v1:lifetime';
  END IF;
  UPDATE roomscan.auth_session_families AS family
  SET state = 'revoked', revoked_at = authoritative_time,
      revoke_reason = 'membership_changed'
  WHERE family.principal_id = target_principal_id
    AND family.workspace_id = context_row.workspace_id AND family.state = 'active';
  PERFORM roomscan.append_workspace_audit_v2(
    context_row.workspace_id, requested_audit_event_id,
    context_row.principal_id,
    CASE WHEN requested_state = 'removed' THEN 'membership.removed'
      ELSE 'membership.role_changed' END,
    'membership', target_principal_canonical_id,
    result_row.authorization_version, authoritative_time
  );
  RETURN QUERY SELECT result_row.workspace_id, result_row.principal_id,
    target_principal_canonical_id, result_row.role, result_row.state,
    result_row.authorization_version;
END
$function$;

RESET ROLE;

ALTER FUNCTION roomscan.append_workspace_audit_v2(uuid, text, uuid, text, text, text, bigint, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.create_invitation_v2(bytea, timestamptz, text, bytea, text, text, timestamptz, bigint, bigint, text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.read_invitation_by_token(bytea, timestamptz, bytea) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.accept_invitation_v2(bytea, timestamptz, bytea, bigint, bigint, bigint, text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.mutate_membership_v2(bytea, timestamptz, text, bigint, text, text, text, text, bigint, bigint, text) OWNER TO roomscan_policy;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA roomscan FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA roomscan FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE ON roomscan.invitations, roomscan.memberships,
  roomscan.audit_states, roomscan.audit_events TO roomscan_policy;
GRANT SELECT, UPDATE ON roomscan.auth_session_families TO roomscan_policy;
GRANT EXECUTE ON FUNCTION
  roomscan.create_invitation_v2(bytea, timestamptz, text, bytea, text, text, timestamptz, bigint, bigint, text),
  roomscan.read_invitation_by_token(bytea, timestamptz, bytea),
  roomscan.accept_invitation_v2(bytea, timestamptz, bytea, bigint, bigint, bigint, text),
  roomscan.mutate_membership_v2(bytea, timestamptz, text, bigint, text, text, text, text, bigint, bigint, text)
  TO roomscan_api_runtime;

COMMENT ON FUNCTION roomscan.accept_invitation_v2(bytea, timestamptz, bytea, bigint, bigint, bigint, text) IS
  'Access-principal plus invitation-digest-derived workspace; CAS, literal-true grant, member slot/quota, membership, scoped-session invalidation and audit commit atomically; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.mutate_membership_v2(bytea, timestamptz, text, bigint, text, text, text, text, bigint, bigint, text) IS
  'Session-derived actor/workspace and canonical target membership; current role matrix, CAS, serialized last Owner, member slot/quota, session invalidation and audit commit atomically; fixed search_path; PUBLIC revoked.';

RESET ROLE;

-- Refresh rotation is one storage transition: a replay commits family
-- revocation and returns a bounded status for the adapter to surface only
-- after commit.
SET ROLE roomscan_owner;
CREATE FUNCTION roomscan.rotate_session_from_refresh(
  current_refresh_token_hash bytea,
  next_refresh_token_hash bytea,
  next_access_token_hash bytea,
  rotated_at_time timestamptz,
  next_access_expires_at timestamptz,
  next_inactivity_expires_at timestamptz
)
RETURNS TABLE (
  status text,
  principal_id uuid,
  principal_canonical_id text,
  family_id uuid,
  family_public_id text,
  authentication_epoch bigint,
  workspace_id uuid,
  role text,
  authorization_version bigint,
  access_expires_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE current_refresh roomscan.auth_refresh_tokens%ROWTYPE;
DECLARE family roomscan.auth_session_families%ROWTYPE;
DECLARE canonical text; principal_epoch bigint; principal_state text;
BEGIN
  IF current_refresh_token_hash IS NULL OR next_refresh_token_hash IS NULL
    OR next_access_token_hash IS NULL OR rotated_at_time IS NULL
    OR next_access_expires_at IS NULL OR next_inactivity_expires_at IS NULL
    OR octet_length(current_refresh_token_hash) <> 32
    OR octet_length(next_refresh_token_hash) <> 32
    OR octet_length(next_access_token_hash) <> 32
    OR current_refresh_token_hash = next_refresh_token_hash
    OR current_refresh_token_hash = next_access_token_hash
    OR next_refresh_token_hash = next_access_token_hash
    OR next_access_expires_at <= rotated_at_time
    OR next_inactivity_expires_at <= rotated_at_time THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_REFRESH_ROTATION_V2';
  END IF;
  SELECT token.* INTO current_refresh FROM roomscan.auth_refresh_tokens AS token
  WHERE token.token_hash = current_refresh_token_hash FOR UPDATE;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'unavailable'::text, NULL::uuid, NULL::text,
      NULL::uuid, NULL::text, NULL::bigint, NULL::uuid, NULL::text,
      NULL::bigint, NULL::timestamptz;
    RETURN;
  END IF;
  SELECT candidate.* INTO family FROM roomscan.auth_session_families AS candidate
  WHERE candidate.id = current_refresh.family_id FOR UPDATE;
  SELECT principal.canonical_id, principal.authentication_epoch, principal.state
  INTO canonical, principal_epoch, principal_state
  FROM roomscan.principals AS principal WHERE principal.id = family.principal_id FOR UPDATE;
  IF current_refresh.state = 'rotated' THEN
    UPDATE roomscan.auth_session_families AS target
    SET state = 'revoked', revoked_at = rotated_at_time,
        revoke_reason = 'refresh_reuse'
    WHERE target.id = family.id AND target.state = 'active';
    UPDATE roomscan.auth_access_tokens AS access
    SET state = 'revoked', revoked_at = rotated_at_time
    WHERE access.family_id = family.id AND access.state = 'active';
    RETURN QUERY SELECT 'replay_revoked'::text, family.principal_id,
      canonical, family.id, family.public_id, family.authentication_epoch,
      family.workspace_id, family.role, family.authorization_version,
      NULL::timestamptz;
    RETURN;
  END IF;
  IF family.state <> 'active' OR family.inactivity_expires_at <= rotated_at_time
    OR family.absolute_expires_at <= rotated_at_time
    OR next_inactivity_expires_at > family.absolute_expires_at
    OR next_access_expires_at > family.absolute_expires_at
    OR principal_state <> 'active'
    OR principal_epoch IS DISTINCT FROM family.authentication_epoch THEN
    RETURN QUERY SELECT 'unavailable'::text, family.principal_id,
      canonical, family.id, family.public_id, family.authentication_epoch,
      family.workspace_id, family.role, family.authorization_version,
      NULL::timestamptz;
    RETURN;
  END IF;
  INSERT INTO roomscan.auth_refresh_tokens (token_hash, family_id, issued_at)
  VALUES (next_refresh_token_hash, family.id, rotated_at_time);
  UPDATE roomscan.auth_refresh_tokens AS token
  SET state = 'rotated', child_token_hash = next_refresh_token_hash,
      rotated_at = rotated_at_time
  WHERE token.token_hash = current_refresh_token_hash AND token.state = 'active';
  IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'REFRESH_ROTATION_RACE'; END IF;
  INSERT INTO roomscan.auth_access_tokens (
    id, family_id, token_hash, expires_at, principal_id,
    authentication_epoch, authenticated_at, issued_at,
    workspace_id, role, authorization_version, state, created_at
  ) VALUES (
    gen_random_uuid(), family.id, next_access_token_hash,
    next_access_expires_at, family.principal_id, family.authentication_epoch,
    family.authenticated_at, rotated_at_time, family.workspace_id,
    family.role, family.authorization_version, 'active', rotated_at_time
  );
  UPDATE roomscan.auth_session_families AS target
  SET last_used_at = rotated_at_time,
      inactivity_expires_at = next_inactivity_expires_at
  WHERE target.id = family.id AND target.state = 'active';
  RETURN QUERY SELECT 'rotated'::text, family.principal_id,
    canonical, family.id, family.public_id, family.authentication_epoch,
    family.workspace_id, family.role, family.authorization_version,
    next_access_expires_at;
END
$function$;
RESET ROLE;
ALTER FUNCTION roomscan.rotate_session_from_refresh(bytea, bytea, bytea, timestamptz, timestamptz, timestamptz) OWNER TO roomscan_policy;
REVOKE ALL ON FUNCTION roomscan.rotate_session_from_refresh(bytea, bytea, bytea, timestamptz, timestamptz, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION roomscan.rotate_session_from_refresh(bytea, bytea, bytea, timestamptz, timestamptz, timestamptz)
  TO roomscan_api_runtime;
COMMENT ON FUNCTION roomscan.rotate_session_from_refresh(bytea, bytea, bytea, timestamptz, timestamptz, timestamptz) IS
  'API-lane refresh-digest-derived atomic child refresh/access issuance; replay commits whole-family revocation and returns internal UUID plus canonical/public IDs; Cognito challenge lane has no EXECUTE; fixed search_path; PUBLIC revoked.';

RESET ROLE;

-- Task 1 production adapter composites.  These replace the remaining raw
-- principal/family mutation ports with access-, receipt-, proof-, and
-- challenge-derived capabilities.  No function accepts a caller workspace.
SET ROLE roomscan_owner;

ALTER TABLE roomscan.apple_auth_attempts
  ADD COLUMN result_recorded_at timestamptz,
  ADD CONSTRAINT apple_auth_attempt_result_order CHECK (
    result_recorded_at IS NULL OR (
      state = 'claimed'
      AND claimed_at IS NOT NULL
      AND result_recorded_at >= claimed_at
    )
  );

CREATE FUNCTION roomscan.logout_all_from_access(
  access_token_hash bytea,
  authoritative_time timestamptz
)
RETURNS TABLE (
  status text,
  principal_id uuid,
  principal_canonical_id text,
  authentication_epoch bigint,
  revoked_family_count integer
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  context_row record;
  next_epoch bigint;
  revoked_count integer;
BEGIN
  IF access_token_hash IS NULL OR authoritative_time IS NULL
    OR octet_length(access_token_hash) <> 32 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_LOGOUT_ALL_INPUT';
  END IF;
  SELECT * INTO context_row
  FROM roomscan.resolve_access_context(access_token_hash, authoritative_time);
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'unavailable'::text, NULL::uuid, NULL::text,
      NULL::bigint, 0::integer;
    RETURN;
  END IF;

  UPDATE roomscan.principals AS principal
  SET authentication_epoch = principal.authentication_epoch + 1,
      updated_at = authoritative_time
  WHERE principal.id = context_row.principal_id AND principal.state = 'active'
  RETURNING principal.authentication_epoch INTO next_epoch;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'unavailable'::text, context_row.principal_id,
      context_row.canonical_principal_id, NULL::bigint, 0::integer;
    RETURN;
  END IF;

  UPDATE roomscan.auth_session_families AS family
  SET state = 'revoked', revoked_at = authoritative_time,
      revoke_reason = 'logout_all'
  WHERE family.principal_id = context_row.principal_id
    AND family.state = 'active';
  GET DIAGNOSTICS revoked_count = ROW_COUNT;
  UPDATE roomscan.auth_access_tokens AS access
  SET state = 'revoked', revoked_at = authoritative_time
  WHERE access.principal_id = context_row.principal_id
    AND access.state = 'active';

  RETURN QUERY SELECT 'revoked'::text, context_row.principal_id,
    context_row.canonical_principal_id, next_epoch, revoked_count;
END
$function$;

CREATE FUNCTION roomscan.mint_candidate_identity_proof_v2(
  access_token_hash bytea,
  authoritative_time timestamptz,
  verified_receipt_hash bytea,
  expected_issuer text,
  expected_purpose text,
  requested_candidate_proof_hash bytea,
  requested_expires_at timestamptz,
  requested_policy_version text
)
RETURNS TABLE (
  status text,
  principal_id uuid,
  principal_canonical_id text,
  family_id uuid,
  family_public_id text,
  proof_expires_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  context_row record;
  receipt roomscan.verified_authentication_receipts%ROWTYPE;
BEGIN
  IF access_token_hash IS NULL OR authoritative_time IS NULL
    OR verified_receipt_hash IS NULL OR expected_issuer IS NULL
    OR expected_purpose IS NULL OR requested_candidate_proof_hash IS NULL
    OR requested_expires_at IS NULL OR requested_policy_version IS NULL
    OR octet_length(access_token_hash) <> 32
    OR octet_length(verified_receipt_hash) <> 32
    OR octet_length(requested_candidate_proof_hash) <> 32
    OR length(expected_issuer) NOT BETWEEN 1 AND 512
    OR expected_purpose NOT IN ('link-identity', 'unlink-identity')
    OR requested_expires_at <= authoritative_time
    OR requested_expires_at > authoritative_time + interval '5 minutes'
    OR length(requested_policy_version) NOT BETWEEN 1 AND 64 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_CANDIDATE_PROOF_MINT';
  END IF;

  PERFORM 1 FROM roomscan.global_operational_flags AS flag
  WHERE flag.flag_key = 'professional_sign_in_enabled'
    AND flag.enabled IS TRUE AND flag.version > 0
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROFESSIONAL_SIGN_IN_DISABLED';
  END IF;

  SELECT * INTO context_row
  FROM roomscan.resolve_access_context(access_token_hash, authoritative_time);
  IF NOT FOUND OR context_row.recent_authentication IS DISTINCT FROM true THEN
    RETURN QUERY SELECT 'recent_auth_required'::text, NULL::uuid, NULL::text,
      NULL::uuid, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;

  SELECT candidate.* INTO receipt
  FROM roomscan.verified_authentication_receipts AS candidate
  WHERE candidate.token_hash = verified_receipt_hash
  FOR UPDATE;
  IF NOT FOUND OR receipt.state <> 'active'
    OR receipt.expires_at <= authoritative_time
    OR receipt.issuer IS DISTINCT FROM expected_issuer
    OR receipt.purpose IS DISTINCT FROM expected_purpose
    OR receipt.initiating_principal_id IS DISTINCT FROM context_row.principal_id
    OR receipt.initiating_family_id IS DISTINCT FROM context_row.family_id
    OR receipt.authenticated_at > authoritative_time
    OR authoritative_time - receipt.authenticated_at > interval '5 minutes' THEN
    RETURN QUERY SELECT 'unavailable'::text, context_row.principal_id,
      context_row.canonical_principal_id, context_row.family_id,
      context_row.family_public_id, NULL::timestamptz;
    RETURN;
  END IF;

  INSERT INTO roomscan.candidate_identity_proofs (
    token_hash, issuer, subject, purpose, initiating_principal_id,
    initiating_family_id, authenticated_at, issued_at, expires_at,
    policy_version
  ) VALUES (
    requested_candidate_proof_hash, receipt.issuer, receipt.subject,
    receipt.purpose, context_row.principal_id, context_row.family_id,
    receipt.authenticated_at, authoritative_time, requested_expires_at,
    requested_policy_version
  );
  UPDATE roomscan.verified_authentication_receipts AS candidate
  SET state = 'consumed', consumed_at = authoritative_time
  WHERE candidate.token_hash = verified_receipt_hash
    AND candidate.state = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'VERIFIED_RECEIPT_CONSUME_RACE';
  END IF;
  RETURN QUERY SELECT 'minted'::text, context_row.principal_id,
    context_row.canonical_principal_id, context_row.family_id,
    context_row.family_public_id, requested_expires_at;
END
$function$;

CREATE FUNCTION roomscan.mutate_identity_v2(
  access_token_hash bytea,
  authoritative_time timestamptz,
  candidate_proof_hash bytea,
  requested_purpose text,
  deliberate_confirmation boolean,
  requested_audit_id text,
  requested_notification_id text,
  requested_identity_reference text,
  requested_policy_version text
)
RETURNS TABLE (
  status text,
  principal_id uuid,
  principal_canonical_id text,
  family_id uuid,
  family_public_id text,
  authentication_epoch bigint
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  context_row record;
  proof roomscan.candidate_identity_proofs%ROWTYPE;
  owner_id uuid;
  claimed_owner_id uuid;
  identity_count integer;
  next_epoch bigint;
  event_code text;
BEGIN
  IF access_token_hash IS NULL OR authoritative_time IS NULL
    OR candidate_proof_hash IS NULL OR requested_purpose IS NULL
    OR deliberate_confirmation IS NULL OR requested_audit_id IS NULL
    OR requested_notification_id IS NULL OR requested_identity_reference IS NULL
    OR requested_policy_version IS NULL
    OR octet_length(access_token_hash) <> 32
    OR octet_length(candidate_proof_hash) <> 32
    OR requested_purpose NOT IN ('link-identity', 'unlink-identity')
    OR deliberate_confirmation IS DISTINCT FROM true
    OR length(requested_audit_id) NOT BETWEEN 16 AND 128
    OR requested_audit_id !~ '^aud_[A-Za-z0-9_-]+$'
    OR length(requested_notification_id) NOT BETWEEN 16 AND 128
    OR requested_notification_id !~ '^[A-Za-z0-9_-]+$'
    OR length(requested_identity_reference) NOT BETWEEN 16 AND 128
    OR requested_identity_reference !~ '^id_[A-Za-z0-9_-]+$'
    OR length(requested_policy_version) NOT BETWEEN 1 AND 64 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_IDENTITY_MUTATION';
  END IF;
  PERFORM 1 FROM roomscan.global_operational_flags AS flag
  WHERE flag.flag_key = 'professional_sign_in_enabled'
    AND flag.enabled IS TRUE AND flag.version > 0
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'PROFESSIONAL_SIGN_IN_DISABLED';
  END IF;
  SELECT * INTO context_row
  FROM roomscan.resolve_access_context(access_token_hash, authoritative_time);
  IF NOT FOUND OR context_row.recent_authentication IS DISTINCT FROM true THEN
    RETURN QUERY SELECT 'recent_auth_required'::text, NULL::uuid, NULL::text,
      NULL::uuid, NULL::text, NULL::bigint;
    RETURN;
  END IF;

  SELECT principal.id INTO owner_id
  FROM roomscan.principals AS principal
  WHERE principal.id = context_row.principal_id AND principal.state = 'active'
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'principal_unavailable'::text, context_row.principal_id,
      context_row.canonical_principal_id, context_row.family_id,
      context_row.family_public_id, NULL::bigint;
    RETURN;
  END IF;

  SELECT candidate.* INTO proof
  FROM roomscan.candidate_identity_proofs AS candidate
  WHERE candidate.token_hash = candidate_proof_hash
  FOR UPDATE;
  IF NOT FOUND OR proof.state <> 'active'
    OR proof.expires_at <= authoritative_time
    OR proof.purpose IS DISTINCT FROM requested_purpose
    OR proof.initiating_principal_id IS DISTINCT FROM context_row.principal_id
    OR proof.initiating_family_id IS DISTINCT FROM context_row.family_id
    OR proof.authenticated_at > authoritative_time
    OR authoritative_time - proof.authenticated_at > interval '5 minutes' THEN
    RETURN QUERY SELECT 'proof_unavailable'::text, context_row.principal_id,
      context_row.canonical_principal_id, context_row.family_id,
      context_row.family_public_id, NULL::bigint;
    RETURN;
  END IF;

  BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(
    proof.issuer || E'\\000' || proof.subject, 7621846213719043
  ));
  SELECT identity.principal_id INTO owner_id
  FROM roomscan.external_identities AS identity
  WHERE identity.issuer = proof.issuer AND identity.subject = proof.subject;

  IF requested_purpose = 'link-identity' THEN
    IF owner_id = context_row.principal_id THEN
      RETURN QUERY SELECT 'already_linked'::text, context_row.principal_id,
        context_row.canonical_principal_id, context_row.family_id,
        context_row.family_public_id, NULL::bigint;
      RETURN;
    ELSIF owner_id IS NOT NULL THEN
      RETURN QUERY SELECT 'candidate_owned'::text, context_row.principal_id,
        context_row.canonical_principal_id, context_row.family_id,
        context_row.family_public_id, NULL::bigint;
      RETURN;
    END IF;
    INSERT INTO roomscan.external_identities AS inserted_identity (
      id, principal_id, issuer, subject, linked_at, created_at
    ) VALUES (
      gen_random_uuid(), context_row.principal_id, proof.issuer, proof.subject,
      authoritative_time, authoritative_time
    )
    ON CONFLICT (issuer, subject) DO NOTHING
    RETURNING inserted_identity.principal_id INTO claimed_owner_id;
    IF claimed_owner_id IS NULL THEN
      SELECT identity.principal_id INTO owner_id
      FROM roomscan.external_identities AS identity
      WHERE identity.issuer = proof.issuer AND identity.subject = proof.subject;
      IF NOT FOUND THEN
        RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'IDENTITY_MUTATION_RETRY_REQUIRED';
      ELSIF owner_id = context_row.principal_id THEN
        RETURN QUERY SELECT 'already_linked'::text, context_row.principal_id,
          context_row.canonical_principal_id, context_row.family_id,
          context_row.family_public_id, NULL::bigint;
        RETURN;
      ELSE
        RETURN QUERY SELECT 'candidate_owned'::text, context_row.principal_id,
          context_row.canonical_principal_id, context_row.family_id,
          context_row.family_public_id, NULL::bigint;
        RETURN;
      END IF;
    END IF;
    event_code := 'identity.linked';
  ELSE
    IF owner_id IS NULL THEN
      RETURN QUERY SELECT 'not_linked'::text, context_row.principal_id,
        context_row.canonical_principal_id, context_row.family_id,
        context_row.family_public_id, NULL::bigint;
      RETURN;
    ELSIF owner_id <> context_row.principal_id THEN
      RETURN QUERY SELECT 'candidate_owned'::text, context_row.principal_id,
        context_row.canonical_principal_id, context_row.family_id,
        context_row.family_public_id, NULL::bigint;
      RETURN;
    END IF;
    SELECT count(*)::integer INTO identity_count
    FROM roomscan.external_identities AS identity
    WHERE identity.principal_id = context_row.principal_id;
    IF identity_count <= 1 THEN
      RETURN QUERY SELECT 'final_auth_method'::text, context_row.principal_id,
        context_row.canonical_principal_id, context_row.family_id,
        context_row.family_public_id, NULL::bigint;
      RETURN;
    END IF;
    DELETE FROM roomscan.external_identities AS identity
    WHERE identity.issuer = proof.issuer AND identity.subject = proof.subject
      AND identity.principal_id = context_row.principal_id;
    event_code := 'identity.unlinked';
  END IF;
  EXCEPTION WHEN serialization_failure THEN
    RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'IDENTITY_MUTATION_RETRY_REQUIRED';
  END;

  UPDATE roomscan.candidate_identity_proofs AS candidate
  SET state = 'consumed', consumed_at = authoritative_time
  WHERE candidate.token_hash = candidate_proof_hash
    AND candidate.state = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'CANDIDATE_PROOF_CONSUME_RACE';
  END IF;
  UPDATE roomscan.principals AS principal
  SET authentication_epoch = principal.authentication_epoch + 1,
      updated_at = authoritative_time
  WHERE principal.id = context_row.principal_id AND principal.state = 'active'
  RETURNING principal.authentication_epoch INTO next_epoch;
  UPDATE roomscan.auth_session_families AS family
  SET state = 'revoked', revoked_at = authoritative_time,
      revoke_reason = 'identity_changed'
  WHERE family.principal_id = context_row.principal_id
    AND family.id <> context_row.family_id AND family.state = 'active';
  UPDATE roomscan.auth_access_tokens AS access
  SET state = 'revoked', revoked_at = authoritative_time
  WHERE access.principal_id = context_row.principal_id
    AND access.family_id <> context_row.family_id AND access.state = 'active';
  INSERT INTO roomscan.identity_audit_events (
    id, event_code, principal_id, authentication_epoch,
    identity_reference, created_at, policy_version
  ) VALUES (
    requested_audit_id, event_code, context_row.principal_id, next_epoch,
    requested_identity_reference, authoritative_time, requested_policy_version
  );
  INSERT INTO roomscan.security_notification_outbox (
    id, event_code, principal_id, identity_reference, created_at, policy_version
  ) VALUES (
    requested_notification_id, event_code, context_row.principal_id,
    requested_identity_reference, authoritative_time, requested_policy_version
  );
  RETURN QUERY SELECT CASE WHEN requested_purpose = 'link-identity'
      THEN 'linked'::text ELSE 'unlinked'::text END,
    context_row.principal_id, context_row.canonical_principal_id,
    context_row.family_id, context_row.family_public_id, next_epoch;
END
$function$;

-- Cross-device magic completion keeps the email-bearing scanner page outside
-- the session boundary. The app retains a PKCE verifier plus opaque completion
-- ID; PostgreSQL stores only keyed digests/challenges and redeemed hash
-- references. A separately derived 40-bit transfer code prevents login CSRF
-- when somebody other than the requesting app follows the email link.
CREATE TABLE roomscan.magic_completion_handoffs (
  completion_id_hash bytea PRIMARY KEY CHECK (octet_length(completion_id_hash) = 32),
  selector text NOT NULL UNIQUE REFERENCES roomscan.magic_links(selector) ON DELETE RESTRICT,
  code_challenge text NOT NULL CHECK (
    length(code_challenge) = 43 AND code_challenge ~ '^[A-Za-z0-9_-]{43}$'
  ),
  purpose text NOT NULL CHECK (
    purpose IN ('sign-in', 'reauthenticate', 'link-identity', 'unlink-identity')
  ),
  state text NOT NULL DEFAULT 'pending' CHECK (
    state IN ('pending', 'confirmed', 'redeemed', 'expired', 'locked')
  ),
  transfer_code_digest bytea CHECK (
    transfer_code_digest IS NULL OR octet_length(transfer_code_digest) = 32
  ),
  failed_attempts integer NOT NULL DEFAULT 0 CHECK (failed_attempts >= 0),
  max_failed_attempts integer NOT NULL CHECK (max_failed_attempts BETWEEN 1 AND 10),
  network_failure_window_seconds integer NOT NULL CHECK (
    network_failure_window_seconds BETWEEN 1 AND 86400
  ),
  max_network_failures integer NOT NULL CHECK (max_network_failures BETWEEN 1 AND 100),
  issued_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  confirmed_at timestamptz,
  redeemed_at timestamptz,
  redeemed_family_id uuid UNIQUE REFERENCES roomscan.auth_session_families(id) ON DELETE RESTRICT,
  redeemed_receipt_hash bytea UNIQUE REFERENCES roomscan.verified_authentication_receipts(token_hash)
    ON DELETE RESTRICT,
  CHECK (issued_at < expires_at),
  CHECK (failed_attempts <= max_failed_attempts),
  CHECK (
    (state = 'pending' AND transfer_code_digest IS NULL
      AND confirmed_at IS NULL AND redeemed_at IS NULL
      AND redeemed_family_id IS NULL AND redeemed_receipt_hash IS NULL)
    OR (state = 'confirmed' AND transfer_code_digest IS NOT NULL
      AND confirmed_at IS NOT NULL AND redeemed_at IS NULL
      AND redeemed_family_id IS NULL AND redeemed_receipt_hash IS NULL)
    OR (state = 'redeemed' AND transfer_code_digest IS NOT NULL
      AND confirmed_at IS NOT NULL AND redeemed_at IS NOT NULL
      AND (
        (purpose IN ('sign-in', 'reauthenticate')
          AND redeemed_family_id IS NOT NULL AND redeemed_receipt_hash IS NULL)
        OR (purpose IN ('link-identity', 'unlink-identity')
          AND redeemed_family_id IS NULL AND redeemed_receipt_hash IS NOT NULL)
      ))
    OR (state = 'expired' AND redeemed_at IS NULL
      AND redeemed_family_id IS NULL AND redeemed_receipt_hash IS NULL)
    OR (state = 'locked' AND transfer_code_digest IS NOT NULL
      AND confirmed_at IS NOT NULL AND redeemed_at IS NULL
      AND redeemed_family_id IS NULL AND redeemed_receipt_hash IS NULL
      AND failed_attempts = max_failed_attempts)
  )
);
CREATE INDEX magic_completion_handoffs_expiry
  ON roomscan.magic_completion_handoffs (state, expires_at, selector);

CREATE TABLE roomscan.magic_completion_redeem_failures (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  completion_id_hash bytea NOT NULL
    REFERENCES roomscan.magic_completion_handoffs(completion_id_hash) ON DELETE RESTRICT,
  network_hash bytea NOT NULL CHECK (octet_length(network_hash) = 32),
  occurred_at timestamptz NOT NULL
);
CREATE INDEX magic_completion_redeem_failures_network
  ON roomscan.magic_completion_redeem_failures (network_hash, occurred_at);
CREATE INDEX magic_completion_redeem_failures_completion
  ON roomscan.magic_completion_redeem_failures (completion_id_hash, occurred_at);

CREATE FUNCTION roomscan.issue_magic_challenge_v2(
  initiating_access_token_hash bytea,
  authoritative_time timestamptz,
  requested_selector text,
  requested_secret_digest bytea,
  requested_purpose text,
  requested_delivery_identity text,
  requested_address_hash bytea,
  requested_network_hash bytea,
  requested_expires_at timestamptz,
  requested_policy_version text,
  requested_outbox_id text,
  requested_key_id text,
  requested_iv bytea,
  requested_ciphertext bytea,
  requested_authentication_tag bytea,
  cooldown_seconds integer,
  max_active_links integer,
  address_window_seconds integer,
  max_address_window integer,
  address_day_seconds integer,
  max_address_day integer,
  network_window_seconds integer,
  max_network_window integer
)
RETURNS TABLE (status text, selector text, expires_at timestamptz)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  context_row record;
  initiating_principal_id uuid;
  initiating_canonical_id text;
  initiating_family_id uuid;
  initiating_family_public_id text;
  initiating_authenticated_at timestamptz;
  recent_count integer;
  daily_count integer;
  active_count integer;
  previous_issued_at timestamptz;
BEGIN
  IF authoritative_time IS NULL OR requested_selector IS NULL
    OR requested_secret_digest IS NULL OR requested_purpose IS NULL
    OR requested_delivery_identity IS NULL OR requested_address_hash IS NULL
    OR requested_network_hash IS NULL OR requested_expires_at IS NULL
    OR requested_policy_version IS NULL OR requested_outbox_id IS NULL
    OR requested_key_id IS NULL OR requested_iv IS NULL
    OR requested_ciphertext IS NULL OR requested_authentication_tag IS NULL
    OR cooldown_seconds IS NULL OR max_active_links IS NULL
    OR address_window_seconds IS NULL OR max_address_window IS NULL
    OR address_day_seconds IS NULL OR max_address_day IS NULL
    OR network_window_seconds IS NULL OR max_network_window IS NULL
    OR length(requested_selector) <> 22
    OR requested_selector !~ '^[A-Za-z0-9_-]+$'
    OR octet_length(requested_secret_digest) <> 32
    OR requested_purpose NOT IN ('sign-in', 'reauthenticate', 'link-identity', 'unlink-identity')
    OR length(requested_delivery_identity) NOT BETWEEN 3 AND 320
    OR octet_length(requested_address_hash) <> 32
    OR octet_length(requested_network_hash) <> 32
    OR requested_expires_at <= authoritative_time
    OR requested_expires_at > authoritative_time + interval '15 minutes'
    OR length(requested_policy_version) NOT BETWEEN 1 AND 64
    OR length(requested_outbox_id) NOT BETWEEN 16 AND 128
    OR requested_outbox_id !~ '^[A-Za-z0-9_-]+$'
    OR length(requested_key_id) NOT BETWEEN 1 AND 64
    OR requested_key_id !~ '^[A-Za-z0-9._-]+$'
    OR octet_length(requested_iv) <> 12
    OR octet_length(requested_ciphertext) <> 32
    OR octet_length(requested_authentication_tag) <> 16
    OR cooldown_seconds NOT BETWEEN 0 AND 3600
    OR max_active_links NOT BETWEEN 1 AND 10
    OR address_window_seconds NOT BETWEEN 1 AND 86400
    OR max_address_window NOT BETWEEN 1 AND 100
    OR address_day_seconds NOT BETWEEN 1 AND 172800
    OR max_address_day NOT BETWEEN 1 AND 1000
    OR network_window_seconds NOT BETWEEN 1 AND 86400
    OR max_network_window NOT BETWEEN 1 AND 1000
    OR (requested_purpose IN ('sign-in', 'reauthenticate')
      AND initiating_access_token_hash IS NOT NULL)
    OR (requested_purpose IN ('link-identity', 'unlink-identity')
      AND (initiating_access_token_hash IS NULL
        OR octet_length(initiating_access_token_hash) <> 32)) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_MAGIC_CHALLENGE_ISSUANCE';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM roomscan.global_operational_flags AS flag
    WHERE flag.flag_key = 'professional_sign_in_enabled'
      AND flag.enabled IS TRUE AND flag.version > 0
  ) THEN
    RETURN QUERY SELECT 'professional_sign_in_disabled'::text,
      NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  IF initiating_access_token_hash IS NOT NULL THEN
    SELECT * INTO context_row
    FROM roomscan.resolve_access_context(initiating_access_token_hash, authoritative_time);
    IF NOT FOUND OR context_row.recent_authentication IS DISTINCT FROM true THEN
      RETURN QUERY SELECT 'recent_auth_required'::text,
        NULL::text, NULL::timestamptz;
      RETURN;
    END IF;
    initiating_principal_id := context_row.principal_id;
    initiating_canonical_id := context_row.canonical_principal_id;
    initiating_family_id := context_row.family_id;
    initiating_family_public_id := context_row.family_public_id;
    initiating_authenticated_at := context_row.authenticated_at;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(
    'network-request:' || encode(requested_network_hash, 'hex'), 7621846213719044
  ));
  SELECT count(*)::integer INTO recent_count
  FROM roomscan.magic_link_rate_events AS event
  WHERE event.kind = 'request' AND event.subject_hash = requested_network_hash
    AND event.occurred_at >= authoritative_time
      - make_interval(secs => network_window_seconds);
  INSERT INTO roomscan.magic_link_rate_events (kind, subject_hash, occurred_at)
  VALUES ('request', requested_network_hash, authoritative_time);
  IF recent_count >= max_network_window THEN
    RETURN QUERY SELECT 'network_rate_limited'::text,
      NULL::text, NULL::timestamptz;
    RETURN;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(
    'address-delivery:' || encode(requested_address_hash, 'hex'), 7621846213719044
  ));
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'active-identity:' || encode(requested_address_hash, 'hex') || ':'
      || requested_purpose, 7621846213719044
  ));
  SELECT count(*)::integer INTO recent_count
  FROM roomscan.magic_link_rate_events AS event
  WHERE event.kind = 'delivery' AND event.subject_hash = requested_address_hash
    AND event.occurred_at >= authoritative_time
      - make_interval(secs => address_window_seconds);
  SELECT count(*)::integer INTO daily_count
  FROM roomscan.magic_link_rate_events AS event
  WHERE event.kind = 'delivery' AND event.subject_hash = requested_address_hash
    AND event.occurred_at >= authoritative_time
      - make_interval(secs => address_day_seconds);
  IF recent_count >= max_address_window OR daily_count >= max_address_day THEN
    RETURN QUERY SELECT 'address_rate_limited'::text,
      NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  SELECT max(link.issued_at) INTO previous_issued_at
  FROM roomscan.magic_links AS link
  WHERE link.normalized_delivery_identity = requested_delivery_identity
    AND link.purpose = requested_purpose;
  IF previous_issued_at IS NOT NULL
    AND previous_issued_at + make_interval(secs => cooldown_seconds) > authoritative_time THEN
    RETURN QUERY SELECT 'cooldown'::text, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  UPDATE roomscan.magic_links AS link
  SET state = 'superseded', superseded_at = authoritative_time
  WHERE link.normalized_delivery_identity = requested_delivery_identity
    AND link.purpose = requested_purpose AND link.state = 'active'
    AND link.expires_at <= authoritative_time;
  SELECT count(*)::integer INTO active_count
  FROM roomscan.magic_links AS link
  WHERE link.normalized_delivery_identity = requested_delivery_identity
    AND link.purpose = requested_purpose AND link.state = 'active'
    AND link.expires_at > authoritative_time;
  IF active_count >= max_active_links THEN
    WITH oldest AS (
      SELECT link.selector FROM roomscan.magic_links AS link
      WHERE link.normalized_delivery_identity = requested_delivery_identity
        AND link.purpose = requested_purpose AND link.state = 'active'
        AND link.expires_at > authoritative_time
      ORDER BY link.issued_at, link.selector
      LIMIT active_count - max_active_links + 1
    )
    UPDATE roomscan.magic_links AS link
    SET state = 'superseded', superseded_at = authoritative_time
    FROM oldest WHERE link.selector = oldest.selector;
  END IF;

  INSERT INTO roomscan.magic_links (
    selector, secret_digest, purpose, normalized_delivery_identity,
    address_hash, network_hash, issued_at, expires_at, policy_version,
    initiating_principal_id, initiating_family_id,
    initiating_authenticated_at
  ) VALUES (
    requested_selector, requested_secret_digest, requested_purpose,
    requested_delivery_identity, requested_address_hash, requested_network_hash,
    authoritative_time, requested_expires_at, requested_policy_version,
    initiating_principal_id, initiating_family_id, initiating_authenticated_at
  );
  INSERT INTO roomscan.magic_link_rate_events (kind, subject_hash, occurred_at)
  VALUES ('delivery', requested_address_hash, authoritative_time);
  INSERT INTO roomscan.magic_link_delivery_outbox (
    id, selector, normalized_delivery_identity, purpose, envelope_version,
    key_id, iv, ciphertext, authentication_tag, created_at, expires_at,
    policy_version
  ) VALUES (
    requested_outbox_id, requested_selector, requested_delivery_identity,
    requested_purpose, 'aes-256-gcm-v1', requested_key_id, requested_iv,
    requested_ciphertext, requested_authentication_tag, authoritative_time,
    requested_expires_at, requested_policy_version
  );
  RETURN QUERY SELECT 'issued'::text, requested_selector, requested_expires_at;
END
$function$;

CREATE FUNCTION roomscan.consume_magic_challenge_v2(
  requested_selector text,
  requested_secret_digest bytea,
  expected_purpose text,
  authoritative_time timestamptz,
  requested_receipt_hash bytea,
  requested_receipt_expires_at timestamptz,
  requested_family_public_id text,
  requested_access_token_hash bytea,
  requested_refresh_token_hash bytea,
  requested_access_expires_at timestamptz,
  requested_inactivity_expires_at timestamptz,
  requested_absolute_expires_at timestamptz,
  requested_session_policy_version text
)
RETURNS TABLE (
  status text,
  purpose text,
  principal_id uuid,
  principal_canonical_id text,
  family_id uuid,
  family_public_id text,
  authentication_epoch bigint,
  receipt_expires_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  link roomscan.magic_links%ROWTYPE;
  target_principal_id uuid;
  target_canonical_id text;
  target_epoch bigint;
  new_family_id uuid;
BEGIN
  IF requested_selector IS NULL OR requested_secret_digest IS NULL
    OR authoritative_time IS NULL OR length(requested_selector) <> 22
    OR requested_selector !~ '^[A-Za-z0-9_-]+$'
    OR octet_length(requested_secret_digest) <> 32
    OR (expected_purpose IS NOT NULL AND expected_purpose NOT IN (
      'sign-in', 'reauthenticate', 'link-identity', 'unlink-identity'
    )) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_MAGIC_CHALLENGE_CONSUMPTION';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM roomscan.global_operational_flags AS flag
    WHERE flag.flag_key = 'professional_sign_in_enabled'
      AND flag.enabled IS TRUE AND flag.version > 0
  ) THEN
    RETURN QUERY SELECT 'professional_sign_in_disabled'::text, NULL::text,
      NULL::uuid, NULL::text, NULL::uuid, NULL::text,
      NULL::bigint, NULL::timestamptz;
    RETURN;
  END IF;

  SELECT candidate.* INTO link
  FROM roomscan.magic_links AS candidate
  WHERE candidate.selector = requested_selector
    AND candidate.secret_digest = requested_secret_digest
    AND (expected_purpose IS NULL OR candidate.purpose = expected_purpose)
    AND candidate.state = 'active' AND candidate.expires_at > authoritative_time
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'unavailable'::text, NULL::text, NULL::uuid,
      NULL::text, NULL::uuid, NULL::text, NULL::bigint, NULL::timestamptz;
    RETURN;
  END IF;

  IF link.purpose IN ('link-identity', 'unlink-identity') THEN
    IF requested_receipt_hash IS NULL OR requested_receipt_expires_at IS NULL
      OR octet_length(requested_receipt_hash) <> 32
      OR requested_receipt_expires_at <= authoritative_time
      OR requested_receipt_expires_at > authoritative_time + interval '2 minutes'
      OR requested_family_public_id IS NOT NULL
      OR requested_access_token_hash IS NOT NULL
      OR requested_refresh_token_hash IS NOT NULL
      OR requested_access_expires_at IS NOT NULL
      OR requested_inactivity_expires_at IS NOT NULL
      OR requested_absolute_expires_at IS NOT NULL
      OR requested_session_policy_version IS NOT NULL THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_MAGIC_RECEIPT_BRANCH';
    END IF;
    INSERT INTO roomscan.verified_authentication_receipts (
      token_hash, issuer, subject, purpose, initiating_principal_id,
      initiating_family_id, authenticated_at, issued_at, expires_at,
      policy_version
    ) VALUES (
      requested_receipt_hash, 'email', link.normalized_delivery_identity,
      link.purpose, link.initiating_principal_id, link.initiating_family_id,
      authoritative_time, authoritative_time, requested_receipt_expires_at,
      link.policy_version
    );
    target_principal_id := link.initiating_principal_id;
    SELECT principal.canonical_id INTO target_canonical_id
    FROM roomscan.principals AS principal
    WHERE principal.id = target_principal_id;
  ELSE
    IF requested_receipt_hash IS NOT NULL OR requested_receipt_expires_at IS NOT NULL
      OR requested_family_public_id IS NULL OR requested_access_token_hash IS NULL
      OR requested_refresh_token_hash IS NULL OR requested_access_expires_at IS NULL
      OR requested_inactivity_expires_at IS NULL OR requested_absolute_expires_at IS NULL
      OR requested_session_policy_version IS NULL
      OR length(requested_family_public_id) NOT BETWEEN 16 AND 128
      OR requested_family_public_id !~ '^[A-Za-z0-9_-]+$'
      OR octet_length(requested_access_token_hash) <> 32
      OR octet_length(requested_refresh_token_hash) <> 32
      OR requested_access_token_hash = requested_refresh_token_hash
      OR requested_access_expires_at <= authoritative_time
      OR requested_inactivity_expires_at <= authoritative_time
      OR requested_absolute_expires_at < requested_inactivity_expires_at
      OR requested_access_expires_at > requested_absolute_expires_at
      OR length(requested_session_policy_version) NOT BETWEEN 1 AND 64 THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_MAGIC_SESSION_BRANCH';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(
      'email:' || link.normalized_delivery_identity, 7621846213719045
    ));
    SELECT identity.principal_id, principal.canonical_id,
           principal.authentication_epoch
    INTO target_principal_id, target_canonical_id, target_epoch
    FROM roomscan.external_identities AS identity
    JOIN roomscan.principals AS principal ON principal.id = identity.principal_id
    WHERE identity.issuer = 'email'
      AND identity.subject = link.normalized_delivery_identity
      AND principal.state = 'active'
    FOR UPDATE OF principal;
    IF target_principal_id IS NULL THEN
      target_principal_id := gen_random_uuid();
      target_canonical_id := 'prn_' || replace(gen_random_uuid()::text, '-', '');
      target_epoch := 0;
      -- Deliberately do not match or populate principals.normalized_email here:
      -- canonical ownership comes only from the exact external identity.
      INSERT INTO roomscan.principals (
        id, canonical_id, authentication_epoch, created_at, updated_at
      ) VALUES (
        target_principal_id, target_canonical_id, target_epoch,
        authoritative_time, authoritative_time
      );
      INSERT INTO roomscan.external_identities (
        id, principal_id, issuer, subject, linked_at, created_at
      ) VALUES (
        gen_random_uuid(), target_principal_id, 'email',
        link.normalized_delivery_identity, authoritative_time, authoritative_time
      );
    END IF;
    new_family_id := gen_random_uuid();
    INSERT INTO roomscan.auth_session_families (
      id, public_id, principal_id, authentication_epoch, authenticated_at,
      last_used_at, inactivity_expires_at, absolute_expires_at,
      policy_version, state, created_at
    ) VALUES (
      new_family_id, requested_family_public_id, target_principal_id,
      target_epoch, authoritative_time, authoritative_time,
      requested_inactivity_expires_at, requested_absolute_expires_at,
      requested_session_policy_version, 'active', authoritative_time
    );
    INSERT INTO roomscan.auth_access_tokens (
      id, family_id, token_hash, expires_at, principal_id,
      authentication_epoch, authenticated_at, issued_at, state, created_at
    ) VALUES (
      gen_random_uuid(), new_family_id, requested_access_token_hash,
      requested_access_expires_at, target_principal_id, target_epoch,
      authoritative_time, authoritative_time, 'active', authoritative_time
    );
    INSERT INTO roomscan.auth_refresh_tokens (token_hash, family_id, issued_at)
    VALUES (requested_refresh_token_hash, new_family_id, authoritative_time);
  END IF;

  UPDATE roomscan.magic_links AS candidate
  SET state = 'consumed', consumed_at = authoritative_time
  WHERE candidate.selector = link.selector AND candidate.state = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'MAGIC_CHALLENGE_CONSUME_RACE';
  END IF;
  UPDATE roomscan.magic_links AS sibling
  SET state = 'superseded', superseded_at = authoritative_time
  WHERE sibling.normalized_delivery_identity = link.normalized_delivery_identity
    AND sibling.purpose = link.purpose AND sibling.selector <> link.selector
    AND sibling.state = 'active';
  RETURN QUERY SELECT CASE WHEN link.purpose IN ('link-identity', 'unlink-identity')
      THEN 'receipt_issued'::text ELSE 'session_issued'::text END,
    link.purpose, target_principal_id, target_canonical_id,
    new_family_id, requested_family_public_id, target_epoch,
    requested_receipt_expires_at;
END
$function$;

CREATE FUNCTION roomscan.issue_magic_challenge_v3(
  initiating_access_token_hash bytea,
  authoritative_time timestamptz,
  requested_selector text,
  requested_secret_digest bytea,
  requested_completion_id_hash bytea,
  requested_code_challenge text,
  requested_purpose text,
  requested_delivery_identity text,
  requested_address_hash bytea,
  requested_network_hash bytea,
  requested_expires_at timestamptz,
  requested_policy_version text,
  requested_outbox_id text,
  requested_key_id text,
  requested_iv bytea,
  requested_ciphertext bytea,
  requested_authentication_tag bytea,
  cooldown_seconds integer,
  max_active_links integer,
  address_window_seconds integer,
  max_address_window integer,
  address_day_seconds integer,
  max_address_day integer,
  network_window_seconds integer,
  max_network_window integer,
  max_completion_failures integer,
  redeem_network_window_seconds integer,
  max_redeem_network_failures integer
)
RETURNS TABLE (status text, selector text, expires_at timestamptz)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE issued record;
BEGIN
  IF authoritative_time IS NULL OR requested_selector IS NULL
    OR requested_secret_digest IS NULL OR requested_completion_id_hash IS NULL
    OR requested_code_challenge IS NULL OR requested_purpose IS NULL
    OR requested_delivery_identity IS NULL OR requested_address_hash IS NULL
    OR requested_network_hash IS NULL OR requested_expires_at IS NULL
    OR requested_policy_version IS NULL OR requested_outbox_id IS NULL
    OR requested_key_id IS NULL OR requested_iv IS NULL
    OR requested_ciphertext IS NULL OR requested_authentication_tag IS NULL
    OR cooldown_seconds IS NULL OR max_active_links IS NULL
    OR address_window_seconds IS NULL OR max_address_window IS NULL
    OR address_day_seconds IS NULL OR max_address_day IS NULL
    OR network_window_seconds IS NULL OR max_network_window IS NULL
    OR max_completion_failures IS NULL OR redeem_network_window_seconds IS NULL
    OR max_redeem_network_failures IS NULL
    OR octet_length(requested_completion_id_hash) <> 32
    OR length(requested_code_challenge) <> 43
    OR requested_code_challenge !~ '^[A-Za-z0-9_-]{43}$'
    OR max_completion_failures NOT BETWEEN 1 AND 10
    OR redeem_network_window_seconds NOT BETWEEN 1 AND 86400
    OR max_redeem_network_failures NOT BETWEEN 1 AND 100
    OR (requested_purpose IN ('sign-in', 'reauthenticate')
      AND initiating_access_token_hash IS NOT NULL)
    OR (requested_purpose IN ('link-identity', 'unlink-identity')
      AND initiating_access_token_hash IS NULL) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_MAGIC_CHALLENGE_V3_ISSUANCE';
  END IF;

  SELECT * INTO issued
  FROM roomscan.issue_magic_challenge_v2(
    initiating_access_token_hash, authoritative_time, requested_selector,
    requested_secret_digest, requested_purpose, requested_delivery_identity,
    requested_address_hash, requested_network_hash, requested_expires_at,
    requested_policy_version, requested_outbox_id, requested_key_id,
    requested_iv, requested_ciphertext, requested_authentication_tag,
    cooldown_seconds, max_active_links, address_window_seconds,
    max_address_window, address_day_seconds, max_address_day,
    network_window_seconds, max_network_window
  );
  IF issued.status IS DISTINCT FROM 'issued' THEN
    RETURN QUERY SELECT issued.status, issued.selector, issued.expires_at;
    RETURN;
  END IF;

  UPDATE roomscan.magic_completion_handoffs AS handoff
  SET state = 'expired'
  FROM roomscan.magic_links AS link
  WHERE handoff.selector = link.selector AND handoff.state = 'pending'
    AND link.state = 'superseded';
  INSERT INTO roomscan.magic_completion_handoffs (
    completion_id_hash, selector, code_challenge, purpose,
    max_failed_attempts, network_failure_window_seconds,
    max_network_failures, issued_at, expires_at
  ) VALUES (
    requested_completion_id_hash, requested_selector,
    requested_code_challenge, requested_purpose,
    max_completion_failures, redeem_network_window_seconds,
    max_redeem_network_failures, authoritative_time, requested_expires_at
  );
  RETURN QUERY SELECT issued.status, issued.selector, issued.expires_at;
END
$function$;

CREATE FUNCTION roomscan.consume_magic_challenge_v3(
  requested_selector text,
  requested_secret_digest bytea,
  expected_purpose text,
  authoritative_time timestamptz,
  requested_transfer_code_digest bytea
)
RETURNS TABLE (
  status text,
  purpose text,
  confirmed_at timestamptz,
  expires_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  link roomscan.magic_links%ROWTYPE;
  handoff roomscan.magic_completion_handoffs%ROWTYPE;
BEGIN
  IF requested_selector IS NULL OR requested_secret_digest IS NULL
    OR expected_purpose IS NULL OR authoritative_time IS NULL
    OR requested_transfer_code_digest IS NULL
    OR length(requested_selector) <> 22
    OR requested_selector !~ '^[A-Za-z0-9_-]+$'
    OR octet_length(requested_secret_digest) <> 32
    OR octet_length(requested_transfer_code_digest) <> 32
    OR expected_purpose NOT IN (
      'sign-in', 'reauthenticate', 'link-identity', 'unlink-identity'
    ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_MAGIC_CHALLENGE_V3_CONFIRMATION';
  END IF;
  PERFORM 1 FROM roomscan.global_operational_flags AS flag
  WHERE flag.flag_key = 'professional_sign_in_enabled'
    AND flag.enabled IS TRUE AND flag.version > 0
  FOR SHARE;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'professional_sign_in_disabled'::text,
      NULL::text, NULL::timestamptz, NULL::timestamptz;
    RETURN;
  END IF;

  SELECT candidate.* INTO link
  FROM roomscan.magic_links AS candidate
  WHERE candidate.selector = requested_selector
    AND candidate.secret_digest = requested_secret_digest
    AND candidate.purpose = expected_purpose
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'unavailable'::text, NULL::text,
      NULL::timestamptz, NULL::timestamptz;
    RETURN;
  END IF;
  SELECT candidate.* INTO handoff
  FROM roomscan.magic_completion_handoffs AS candidate
  WHERE candidate.selector = link.selector
  FOR UPDATE;
  IF NOT FOUND OR handoff.purpose IS DISTINCT FROM expected_purpose THEN
    RETURN QUERY SELECT 'unavailable'::text, NULL::text,
      NULL::timestamptz, NULL::timestamptz;
    RETURN;
  END IF;
  IF handoff.expires_at <= authoritative_time THEN
    UPDATE roomscan.magic_completion_handoffs AS candidate
    SET state = 'expired'
    WHERE candidate.completion_id_hash = handoff.completion_id_hash
      AND candidate.state IN ('pending', 'confirmed');
    UPDATE roomscan.magic_links AS candidate
    SET state = 'superseded', superseded_at = authoritative_time
    WHERE candidate.selector = link.selector AND candidate.state = 'active';
    RETURN QUERY SELECT 'unavailable'::text, NULL::text,
      NULL::timestamptz, NULL::timestamptz;
    RETURN;
  END IF;
  IF handoff.state = 'confirmed' AND link.state = 'consumed'
    AND handoff.transfer_code_digest IS NOT DISTINCT FROM requested_transfer_code_digest THEN
    RETURN QUERY SELECT 'already_confirmed'::text, handoff.purpose,
      handoff.confirmed_at, handoff.expires_at;
    RETURN;
  END IF;
  IF handoff.state <> 'pending' OR link.state <> 'active' THEN
    RETURN QUERY SELECT 'unavailable'::text, NULL::text,
      NULL::timestamptz, NULL::timestamptz;
    RETURN;
  END IF;

  UPDATE roomscan.magic_links AS candidate
  SET state = 'consumed', consumed_at = authoritative_time
  WHERE candidate.selector = link.selector AND candidate.state = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'MAGIC_V3_CONFIRMATION_RACE';
  END IF;
  UPDATE roomscan.magic_completion_handoffs AS candidate
  SET state = 'confirmed', transfer_code_digest = requested_transfer_code_digest,
      confirmed_at = authoritative_time
  WHERE candidate.completion_id_hash = handoff.completion_id_hash
    AND candidate.state = 'pending';
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'MAGIC_V3_HANDOFF_CONFIRMATION_RACE';
  END IF;
  UPDATE roomscan.magic_links AS sibling
  SET state = 'superseded', superseded_at = authoritative_time
  WHERE sibling.normalized_delivery_identity = link.normalized_delivery_identity
    AND sibling.purpose = link.purpose AND sibling.selector <> link.selector
    AND sibling.state = 'active';
  UPDATE roomscan.magic_completion_handoffs AS sibling_handoff
  SET state = 'expired'
  FROM roomscan.magic_links AS sibling_link
  WHERE sibling_handoff.selector = sibling_link.selector
    AND sibling_handoff.state = 'pending'
    AND sibling_link.normalized_delivery_identity = link.normalized_delivery_identity
    AND sibling_link.purpose = link.purpose
    AND sibling_link.selector <> link.selector
    AND sibling_link.state = 'superseded'
    AND sibling_link.superseded_at = authoritative_time;
  RETURN QUERY SELECT 'confirmed'::text, link.purpose,
    authoritative_time, handoff.expires_at;
END
$function$;

CREATE FUNCTION roomscan.redeem_magic_completion_v3(
  requested_completion_id_hash bytea,
  requested_code_challenge text,
  requested_transfer_code_digest bytea,
  expected_purpose text,
  requested_network_hash bytea,
  authoritative_time timestamptz,
  requested_receipt_hash bytea,
  requested_receipt_expires_at timestamptz,
  requested_family_public_id text,
  requested_access_token_hash bytea,
  requested_refresh_token_hash bytea,
  requested_access_expires_at timestamptz,
  requested_inactivity_expires_at timestamptz,
  requested_absolute_expires_at timestamptz,
  requested_session_policy_version text
)
RETURNS TABLE (
  status text,
  purpose text,
  principal_id uuid,
  principal_canonical_id text,
  family_id uuid,
  family_public_id text,
  authentication_epoch bigint,
  workspace_id uuid,
  role text,
  authorization_version bigint,
  access_expires_at timestamptz,
  receipt_expires_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  handoff roomscan.magic_completion_handoffs%ROWTYPE;
  link roomscan.magic_links%ROWTYPE;
  target_principal_id uuid;
  target_canonical_id text;
  target_epoch bigint;
  target_family_id uuid;
  target_family_public_id text;
  target_workspace_id uuid;
  target_role text;
  target_authorization_version bigint;
  target_access_expires_at timestamptz;
  target_receipt_expires_at timestamptz;
  active_membership_count integer;
  network_failure_count integer;
  failed_state text;
BEGIN
  IF requested_completion_id_hash IS NULL OR requested_code_challenge IS NULL
    OR requested_transfer_code_digest IS NULL OR expected_purpose IS NULL
    OR requested_network_hash IS NULL OR authoritative_time IS NULL
    OR octet_length(requested_completion_id_hash) <> 32
    OR length(requested_code_challenge) <> 43
    OR requested_code_challenge !~ '^[A-Za-z0-9_-]{43}$'
    OR octet_length(requested_transfer_code_digest) <> 32
    OR octet_length(requested_network_hash) <> 32
    OR expected_purpose NOT IN (
      'sign-in', 'reauthenticate', 'link-identity', 'unlink-identity'
    )
    OR (expected_purpose IN ('link-identity', 'unlink-identity') AND (
      requested_receipt_hash IS NULL OR requested_receipt_expires_at IS NULL
      OR octet_length(requested_receipt_hash) <> 32
      OR requested_receipt_expires_at <= authoritative_time
      OR requested_receipt_expires_at > authoritative_time + interval '2 minutes'
      OR requested_family_public_id IS NOT NULL
      OR requested_access_token_hash IS NOT NULL
      OR requested_refresh_token_hash IS NOT NULL
      OR requested_access_expires_at IS NOT NULL
      OR requested_inactivity_expires_at IS NOT NULL
      OR requested_absolute_expires_at IS NOT NULL
      OR requested_session_policy_version IS NOT NULL
    ))
    OR (expected_purpose IN ('sign-in', 'reauthenticate') AND (
      requested_receipt_hash IS NOT NULL OR requested_receipt_expires_at IS NOT NULL
      OR requested_family_public_id IS NULL OR requested_access_token_hash IS NULL
      OR requested_refresh_token_hash IS NULL OR requested_access_expires_at IS NULL
      OR requested_inactivity_expires_at IS NULL OR requested_absolute_expires_at IS NULL
      OR requested_session_policy_version IS NULL
      OR length(requested_family_public_id) NOT BETWEEN 16 AND 128
      OR requested_family_public_id !~ '^[A-Za-z0-9_-]+$'
      OR octet_length(requested_access_token_hash) <> 32
      OR octet_length(requested_refresh_token_hash) <> 32
      OR requested_access_token_hash = requested_refresh_token_hash
      OR requested_access_expires_at <= authoritative_time
      OR requested_inactivity_expires_at <= authoritative_time
      OR requested_absolute_expires_at < requested_inactivity_expires_at
      OR requested_access_expires_at > requested_absolute_expires_at
      OR length(requested_session_policy_version) NOT BETWEEN 1 AND 64
    )) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_MAGIC_COMPLETION_V3_REDEMPTION';
  END IF;
  PERFORM 1 FROM roomscan.global_operational_flags AS flag
  WHERE flag.flag_key = 'professional_sign_in_enabled'
    AND flag.enabled IS TRUE AND flag.version > 0
  FOR SHARE;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'professional_sign_in_disabled'::text,
      NULL::text, NULL::uuid, NULL::text, NULL::uuid, NULL::text,
      NULL::bigint, NULL::uuid, NULL::text, NULL::bigint,
      NULL::timestamptz, NULL::timestamptz;
    RETURN;
  END IF;

  SELECT candidate.* INTO handoff
  FROM roomscan.magic_completion_handoffs AS candidate
  WHERE candidate.completion_id_hash = requested_completion_id_hash
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'unavailable'::text,
      NULL::text, NULL::uuid, NULL::text, NULL::uuid, NULL::text,
      NULL::bigint, NULL::uuid, NULL::text, NULL::bigint,
      NULL::timestamptz, NULL::timestamptz;
    RETURN;
  END IF;
  SELECT candidate.* INTO link
  FROM roomscan.magic_links AS candidate
  WHERE candidate.selector = handoff.selector;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'MAGIC_V3_LINK_INVARIANT';
  END IF;

  IF handoff.expires_at <= authoritative_time THEN
    UPDATE roomscan.magic_completion_handoffs AS candidate
    SET state = 'expired'
    WHERE candidate.completion_id_hash = handoff.completion_id_hash
      AND candidate.state IN ('pending', 'confirmed');
    RETURN QUERY SELECT 'unavailable'::text,
      NULL::text, NULL::uuid, NULL::text, NULL::uuid, NULL::text,
      NULL::bigint, NULL::uuid, NULL::text, NULL::bigint,
      NULL::timestamptz, NULL::timestamptz;
    RETURN;
  END IF;

  IF handoff.state = 'redeemed' THEN
    IF handoff.purpose IS DISTINCT FROM expected_purpose
      OR handoff.code_challenge IS DISTINCT FROM requested_code_challenge
      OR handoff.transfer_code_digest IS DISTINCT FROM requested_transfer_code_digest THEN
      RETURN QUERY SELECT 'unavailable'::text,
        NULL::text, NULL::uuid, NULL::text, NULL::uuid, NULL::text,
        NULL::bigint, NULL::uuid, NULL::text, NULL::bigint,
        NULL::timestamptz, NULL::timestamptz;
      RETURN;
    END IF;
    IF handoff.purpose IN ('sign-in', 'reauthenticate') THEN
      SELECT principal.id, principal.canonical_id,
        principal.authentication_epoch, family.id, family.public_id,
        family.workspace_id, family.role, family.authorization_version,
        access.expires_at
      INTO target_principal_id, target_canonical_id, target_epoch,
        target_family_id, target_family_public_id, target_workspace_id,
        target_role, target_authorization_version, target_access_expires_at
      FROM roomscan.auth_session_families AS family
      JOIN roomscan.principals AS principal ON principal.id = family.principal_id
      JOIN roomscan.auth_access_tokens AS access
        ON access.family_id = family.id
       AND access.token_hash = requested_access_token_hash
      JOIN roomscan.auth_refresh_tokens AS refresh
        ON refresh.family_id = family.id
       AND refresh.token_hash = requested_refresh_token_hash
      WHERE family.id = handoff.redeemed_family_id
        AND family.public_id IS NOT DISTINCT FROM requested_family_public_id
        AND family.policy_version IS NOT DISTINCT FROM requested_session_policy_version
        AND family.state = 'active' AND access.state = 'active'
        AND refresh.state = 'active' AND principal.state = 'active'
        AND family.authentication_epoch = principal.authentication_epoch
        AND access.authentication_epoch = principal.authentication_epoch
        AND family.inactivity_expires_at > authoritative_time
        AND family.absolute_expires_at > authoritative_time
        AND access.expires_at > authoritative_time
        AND refresh.issued_at <= authoritative_time
        AND access.workspace_id IS NOT DISTINCT FROM family.workspace_id
        AND access.role IS NOT DISTINCT FROM family.role
        AND access.authorization_version IS NOT DISTINCT FROM family.authorization_version
        AND (
          family.workspace_id IS NULL
          OR EXISTS (
            SELECT 1
            FROM roomscan.memberships AS membership
            WHERE membership.workspace_id = family.workspace_id
              AND membership.principal_id = family.principal_id
              AND membership.state = 'active'
              AND membership.role = family.role
              AND membership.authorization_version = family.authorization_version
          )
        );
      IF NOT FOUND THEN
        RETURN QUERY SELECT 'unavailable'::text,
          NULL::text, NULL::uuid, NULL::text, NULL::uuid, NULL::text,
          NULL::bigint, NULL::uuid, NULL::text, NULL::bigint,
          NULL::timestamptz, NULL::timestamptz;
        RETURN;
      END IF;
      RETURN QUERY SELECT 'session_replayed'::text, handoff.purpose,
        target_principal_id, target_canonical_id, target_family_id,
        target_family_public_id, target_epoch, target_workspace_id,
        target_role, target_authorization_version, target_access_expires_at,
        NULL::timestamptz;
      RETURN;
    END IF;

    SELECT principal.id, principal.canonical_id,
      principal.authentication_epoch, family.id, family.public_id,
      receipt.expires_at
    INTO target_principal_id, target_canonical_id, target_epoch,
      target_family_id, target_family_public_id, target_receipt_expires_at
    FROM roomscan.verified_authentication_receipts AS receipt
    JOIN roomscan.auth_session_families AS family
      ON family.id = receipt.initiating_family_id
    JOIN roomscan.principals AS principal
      ON principal.id = receipt.initiating_principal_id
    WHERE receipt.token_hash = handoff.redeemed_receipt_hash
      AND receipt.token_hash = requested_receipt_hash
      AND receipt.purpose = expected_purpose AND receipt.issuer = 'email'
      AND receipt.state = 'active' AND family.state = 'active'
      AND principal.state = 'active'
      AND family.principal_id = principal.id
      AND family.authentication_epoch = principal.authentication_epoch
      AND receipt.expires_at > authoritative_time
      AND family.inactivity_expires_at > authoritative_time
      AND family.absolute_expires_at > authoritative_time
      AND (
        family.workspace_id IS NULL
        OR EXISTS (
          SELECT 1
          FROM roomscan.memberships AS membership
          WHERE membership.workspace_id = family.workspace_id
            AND membership.principal_id = family.principal_id
            AND membership.state = 'active'
            AND membership.role = family.role
            AND membership.authorization_version = family.authorization_version
        )
      );
    IF NOT FOUND THEN
      RETURN QUERY SELECT 'unavailable'::text,
        NULL::text, NULL::uuid, NULL::text, NULL::uuid, NULL::text,
        NULL::bigint, NULL::uuid, NULL::text, NULL::bigint,
        NULL::timestamptz, NULL::timestamptz;
      RETURN;
    END IF;
    RETURN QUERY SELECT 'receipt_replayed'::text, handoff.purpose,
      target_principal_id, target_canonical_id, target_family_id,
      target_family_public_id, target_epoch, NULL::uuid, NULL::text,
      NULL::bigint, NULL::timestamptz, target_receipt_expires_at;
    RETURN;
  END IF;

  IF handoff.state = 'pending' THEN
    RETURN QUERY SELECT 'pending_confirmation'::text, handoff.purpose,
      NULL::uuid, NULL::text, NULL::uuid, NULL::text,
      NULL::bigint, NULL::uuid, NULL::text, NULL::bigint,
      NULL::timestamptz, NULL::timestamptz;
    RETURN;
  END IF;
  IF handoff.state = 'locked' THEN
    RETURN QUERY SELECT 'rate_limited'::text, handoff.purpose,
      NULL::uuid, NULL::text, NULL::uuid, NULL::text,
      NULL::bigint, NULL::uuid, NULL::text, NULL::bigint,
      NULL::timestamptz, NULL::timestamptz;
    RETURN;
  END IF;
  IF handoff.state <> 'confirmed' OR link.state <> 'consumed' THEN
    RETURN QUERY SELECT 'unavailable'::text,
      NULL::text, NULL::uuid, NULL::text, NULL::uuid, NULL::text,
      NULL::bigint, NULL::uuid, NULL::text, NULL::bigint,
      NULL::timestamptz, NULL::timestamptz;
    RETURN;
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'magic-redeem-network:'
      || pg_catalog.encode(requested_network_hash, 'hex'),
    7621846213719046
  ));
  SELECT count(*)::integer INTO network_failure_count
  FROM roomscan.magic_completion_redeem_failures AS failure
  WHERE failure.network_hash = requested_network_hash
    AND failure.occurred_at >= authoritative_time
      - pg_catalog.make_interval(secs => handoff.network_failure_window_seconds);
  IF network_failure_count >= handoff.max_network_failures THEN
    RETURN QUERY SELECT 'rate_limited'::text, handoff.purpose,
      NULL::uuid, NULL::text, NULL::uuid, NULL::text,
      NULL::bigint, NULL::uuid, NULL::text, NULL::bigint,
      NULL::timestamptz, NULL::timestamptz;
    RETURN;
  END IF;
  IF handoff.purpose IS DISTINCT FROM expected_purpose
    OR handoff.code_challenge IS DISTINCT FROM requested_code_challenge
    OR handoff.transfer_code_digest IS DISTINCT FROM requested_transfer_code_digest THEN
    INSERT INTO roomscan.magic_completion_redeem_failures (
      completion_id_hash, network_hash, occurred_at
    ) VALUES (
      handoff.completion_id_hash, requested_network_hash, authoritative_time
    );
    UPDATE roomscan.magic_completion_handoffs AS candidate
    SET failed_attempts = candidate.failed_attempts + 1,
        state = CASE
          WHEN candidate.failed_attempts + 1 >= candidate.max_failed_attempts
            THEN 'locked' ELSE 'confirmed' END
    WHERE candidate.completion_id_hash = handoff.completion_id_hash
      AND candidate.state = 'confirmed'
    RETURNING candidate.state INTO failed_state;
    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'MAGIC_V3_FAILURE_COUNT_RACE';
    END IF;
    RETURN QUERY SELECT CASE WHEN failed_state = 'locked'
        THEN 'rate_limited'::text ELSE 'unavailable'::text END,
      handoff.purpose, NULL::uuid, NULL::text, NULL::uuid, NULL::text,
      NULL::bigint, NULL::uuid, NULL::text, NULL::bigint,
      NULL::timestamptz, NULL::timestamptz;
    RETURN;
  END IF;

  IF handoff.purpose IN ('link-identity', 'unlink-identity') THEN
    SELECT principal.id, principal.canonical_id,
      principal.authentication_epoch, family.id, family.public_id
    INTO target_principal_id, target_canonical_id, target_epoch,
      target_family_id, target_family_public_id
    FROM roomscan.auth_session_families AS family
    JOIN roomscan.principals AS principal ON principal.id = family.principal_id
    WHERE family.id = link.initiating_family_id
      AND principal.id = link.initiating_principal_id
      AND family.state = 'active' AND principal.state = 'active'
      AND family.authentication_epoch = principal.authentication_epoch
      AND family.inactivity_expires_at > authoritative_time
      AND family.absolute_expires_at > authoritative_time
      AND link.initiating_authenticated_at <= authoritative_time
      AND link.initiating_authenticated_at >= authoritative_time - interval '5 minutes'
    FOR UPDATE OF family, principal;
    IF NOT FOUND THEN
      RETURN QUERY SELECT 'unavailable'::text,
        NULL::text, NULL::uuid, NULL::text, NULL::uuid, NULL::text,
        NULL::bigint, NULL::uuid, NULL::text, NULL::bigint,
        NULL::timestamptz, NULL::timestamptz;
      RETURN;
    END IF;
    INSERT INTO roomscan.verified_authentication_receipts (
      token_hash, issuer, subject, purpose, initiating_principal_id,
      initiating_family_id, authenticated_at, issued_at, expires_at,
      policy_version
    ) VALUES (
      requested_receipt_hash, 'email', link.normalized_delivery_identity,
      link.purpose, target_principal_id, target_family_id,
      handoff.confirmed_at, authoritative_time, requested_receipt_expires_at,
      link.policy_version
    );
    UPDATE roomscan.magic_completion_handoffs AS candidate
    SET state = 'redeemed', redeemed_at = authoritative_time,
        redeemed_receipt_hash = requested_receipt_hash
    WHERE candidate.completion_id_hash = handoff.completion_id_hash
      AND candidate.state = 'confirmed';
    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'MAGIC_V3_REDEEM_RACE';
    END IF;
    RETURN QUERY SELECT 'receipt_issued'::text, handoff.purpose,
      target_principal_id, target_canonical_id, target_family_id,
      target_family_public_id, target_epoch, NULL::uuid, NULL::text,
      NULL::bigint, NULL::timestamptz, requested_receipt_expires_at;
    RETURN;
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'email:' || link.normalized_delivery_identity, 7621846213719045
  ));
  SELECT identity.principal_id INTO target_principal_id
  FROM roomscan.external_identities AS identity
  WHERE identity.issuer = 'email'
    AND identity.subject = link.normalized_delivery_identity;
  IF FOUND THEN
    SELECT principal.canonical_id, principal.authentication_epoch
      INTO target_canonical_id, target_epoch
    FROM roomscan.principals AS principal
    WHERE principal.id = target_principal_id AND principal.state = 'active'
    FOR UPDATE;
    IF NOT FOUND THEN
      RETURN QUERY SELECT 'unavailable'::text,
        NULL::text, NULL::uuid, NULL::text, NULL::uuid, NULL::text,
        NULL::bigint, NULL::uuid, NULL::text, NULL::bigint,
        NULL::timestamptz, NULL::timestamptz;
      RETURN;
    END IF;
  ELSE
    target_principal_id := gen_random_uuid();
    target_canonical_id := 'prn_' || pg_catalog.replace(gen_random_uuid()::text, '-', '');
    target_epoch := 0;
    INSERT INTO roomscan.principals (
      id, canonical_id, authentication_epoch, created_at, updated_at
    ) VALUES (
      target_principal_id, target_canonical_id, target_epoch,
      authoritative_time, authoritative_time
    );
    INSERT INTO roomscan.external_identities (
      id, principal_id, issuer, subject, linked_at, created_at
    ) VALUES (
      gen_random_uuid(), target_principal_id, 'email',
      link.normalized_delivery_identity, handoff.confirmed_at, authoritative_time
    );
  END IF;

  PERFORM 1 FROM roomscan.memberships AS membership
  WHERE membership.principal_id = target_principal_id
    AND membership.state = 'active'
  FOR SHARE;
  SELECT count(*)::integer INTO active_membership_count
  FROM roomscan.memberships AS membership
  WHERE membership.principal_id = target_principal_id
    AND membership.state = 'active';
  IF active_membership_count = 1 THEN
    SELECT membership.workspace_id, membership.role,
      membership.authorization_version
    INTO target_workspace_id, target_role, target_authorization_version
    FROM roomscan.memberships AS membership
    WHERE membership.principal_id = target_principal_id
      AND membership.state = 'active';
  END IF;

  target_family_id := gen_random_uuid();
  INSERT INTO roomscan.auth_session_families (
    id, public_id, principal_id, authentication_epoch, authenticated_at,
    last_used_at, inactivity_expires_at, absolute_expires_at,
    policy_version, workspace_id, role, authorization_version,
    state, created_at
  ) VALUES (
    target_family_id, requested_family_public_id, target_principal_id,
    target_epoch, handoff.confirmed_at, authoritative_time,
    requested_inactivity_expires_at, requested_absolute_expires_at,
    requested_session_policy_version, target_workspace_id, target_role,
    target_authorization_version, 'active', authoritative_time
  );
  INSERT INTO roomscan.auth_access_tokens (
    id, family_id, token_hash, expires_at, principal_id,
    authentication_epoch, authenticated_at, issued_at, workspace_id,
    role, authorization_version, state, created_at
  ) VALUES (
    gen_random_uuid(), target_family_id, requested_access_token_hash,
    requested_access_expires_at, target_principal_id, target_epoch,
    handoff.confirmed_at, authoritative_time, target_workspace_id,
    target_role, target_authorization_version, 'active', authoritative_time
  );
  INSERT INTO roomscan.auth_refresh_tokens (token_hash, family_id, issued_at)
  VALUES (requested_refresh_token_hash, target_family_id, authoritative_time);
  UPDATE roomscan.magic_completion_handoffs AS candidate
  SET state = 'redeemed', redeemed_at = authoritative_time,
      redeemed_family_id = target_family_id
  WHERE candidate.completion_id_hash = handoff.completion_id_hash
    AND candidate.state = 'confirmed';
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'MAGIC_V3_REDEEM_RACE';
  END IF;
  RETURN QUERY SELECT 'session_issued'::text, handoff.purpose,
    target_principal_id, target_canonical_id, target_family_id,
    requested_family_public_id, target_epoch, target_workspace_id,
    target_role, target_authorization_version, requested_access_expires_at,
    NULL::timestamptz;
END
$function$;

CREATE FUNCTION roomscan.create_apple_attempt_v2(
  initiating_access_token_hash bytea,
  authoritative_time timestamptz,
  requested_attempt_id text,
  requested_state_hash bytea,
  requested_nonce_hash bytea,
  requested_code_challenge text,
  requested_client_id text,
  requested_redirect_uri text,
  requested_expires_at timestamptz,
  requested_policy_version text,
  requested_purpose text
)
RETURNS TABLE (
  status text,
  attempt_id text,
  purpose text,
  principal_id uuid,
  principal_canonical_id text,
  family_id uuid,
  family_public_id text
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  context_row record;
  initiating_principal_id uuid;
  initiating_canonical_id text;
  initiating_family_id uuid;
  initiating_family_public_id text;
  initiating_authenticated_at timestamptz;
BEGIN
  IF authoritative_time IS NULL OR requested_attempt_id IS NULL
    OR requested_state_hash IS NULL OR requested_nonce_hash IS NULL
    OR requested_code_challenge IS NULL OR requested_client_id IS NULL
    OR requested_redirect_uri IS NULL OR requested_expires_at IS NULL
    OR requested_policy_version IS NULL OR requested_purpose IS NULL
    OR length(requested_attempt_id) NOT BETWEEN 16 AND 128
    OR requested_attempt_id !~ '^[A-Za-z0-9_-]+$'
    OR octet_length(requested_state_hash) <> 32
    OR octet_length(requested_nonce_hash) <> 32
    OR length(requested_code_challenge) <> 43
    OR requested_code_challenge !~ '^[A-Za-z0-9_-]+$'
    OR length(requested_client_id) NOT BETWEEN 1 AND 256
    OR length(requested_redirect_uri) NOT BETWEEN 1 AND 2048
    OR requested_redirect_uri NOT LIKE 'https://%'
    OR requested_expires_at <= authoritative_time
    OR requested_expires_at > authoritative_time + interval '10 minutes'
    OR length(requested_policy_version) NOT BETWEEN 1 AND 64
    OR requested_purpose NOT IN ('sign-in', 'link-identity', 'unlink-identity')
    OR (requested_purpose = 'sign-in' AND initiating_access_token_hash IS NOT NULL)
    OR (requested_purpose IN ('link-identity', 'unlink-identity') AND (
      initiating_access_token_hash IS NULL
      OR octet_length(initiating_access_token_hash) <> 32
    )) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_APPLE_ATTEMPT_CREATION';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM roomscan.global_operational_flags AS flag
    WHERE flag.flag_key = 'professional_sign_in_enabled'
      AND flag.enabled IS TRUE AND flag.version > 0
  ) THEN
    RETURN QUERY SELECT 'professional_sign_in_disabled'::text, NULL::text,
      NULL::text, NULL::uuid, NULL::text, NULL::uuid, NULL::text;
    RETURN;
  END IF;
  IF initiating_access_token_hash IS NOT NULL THEN
    SELECT * INTO context_row FROM roomscan.resolve_access_context(
      initiating_access_token_hash, authoritative_time
    );
    IF NOT FOUND OR context_row.recent_authentication IS DISTINCT FROM true THEN
      RETURN QUERY SELECT 'recent_auth_required'::text, NULL::text,
        NULL::text, NULL::uuid, NULL::text, NULL::uuid, NULL::text;
      RETURN;
    END IF;
    initiating_principal_id := context_row.principal_id;
    initiating_canonical_id := context_row.canonical_principal_id;
    initiating_family_id := context_row.family_id;
    initiating_family_public_id := context_row.family_public_id;
    initiating_authenticated_at := context_row.authenticated_at;
  END IF;
  INSERT INTO roomscan.apple_auth_attempts (
    id, state_hash, nonce_hash, code_challenge, expected_client_id,
    redirect_uri, created_at, expires_at, policy_version, purpose,
    initiating_principal_id, initiating_family_id,
    initiating_authenticated_at
  ) VALUES (
    requested_attempt_id, requested_state_hash, requested_nonce_hash,
    requested_code_challenge, requested_client_id, requested_redirect_uri,
    authoritative_time, requested_expires_at, requested_policy_version,
    requested_purpose, initiating_principal_id, initiating_family_id,
    initiating_authenticated_at
  );
  RETURN QUERY SELECT 'created'::text, requested_attempt_id,
    requested_purpose, initiating_principal_id,
    initiating_canonical_id, initiating_family_id,
    initiating_family_public_id;
END
$function$;

CREATE FUNCTION roomscan.accept_apple_verified_result_v2(
  requested_attempt_id text,
  verified_issuer text,
  verified_subject text,
  requested_bridge_proof_hash bytea,
  requested_receipt_hash bytea,
  authoritative_time timestamptz,
  requested_expires_at timestamptz,
  requested_policy_version text
)
RETURNS TABLE (
  status text,
  attempt_id text,
  purpose text,
  principal_id uuid,
  family_id uuid,
  expires_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE attempt roomscan.apple_auth_attempts%ROWTYPE;
BEGIN
  IF requested_attempt_id IS NULL OR verified_issuer IS NULL
    OR verified_subject IS NULL OR authoritative_time IS NULL
    OR requested_expires_at IS NULL OR requested_policy_version IS NULL
    OR length(requested_attempt_id) NOT BETWEEN 16 AND 128
    OR verified_issuer <> 'https://appleid.apple.com'
    OR length(verified_subject) NOT BETWEEN 1 AND 512
    OR requested_expires_at <= authoritative_time
    OR requested_expires_at > authoritative_time + interval '2 minutes'
    OR length(requested_policy_version) NOT BETWEEN 1 AND 64 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_APPLE_VERIFIED_RESULT';
  END IF;
  SELECT candidate.* INTO attempt
  FROM roomscan.apple_auth_attempts AS candidate
  WHERE candidate.id = requested_attempt_id
  FOR UPDATE;
  IF NOT FOUND OR attempt.state <> 'claimed'
    OR attempt.expires_at <= authoritative_time
    OR attempt.policy_version IS DISTINCT FROM requested_policy_version
    OR attempt.result_recorded_at IS NOT NULL THEN
    RETURN QUERY SELECT 'unavailable'::text, requested_attempt_id,
      NULL::text, NULL::uuid, NULL::uuid, NULL::timestamptz;
    RETURN;
  END IF;
  IF attempt.purpose = 'sign-in' THEN
    IF requested_bridge_proof_hash IS NULL OR requested_receipt_hash IS NOT NULL
      OR octet_length(requested_bridge_proof_hash) <> 32 THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_APPLE_BRIDGE_RESULT';
    END IF;
  ELSE
    IF requested_receipt_hash IS NULL OR requested_bridge_proof_hash IS NOT NULL
      OR octet_length(requested_receipt_hash) <> 32
      OR attempt.initiating_principal_id IS NULL
      OR attempt.initiating_family_id IS NULL THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_APPLE_RECEIPT_RESULT';
    END IF;
  END IF;

  UPDATE roomscan.apple_auth_attempts AS target
  SET result_recorded_at = authoritative_time
  WHERE target.id = attempt.id AND target.result_recorded_at IS NULL;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'unavailable'::text, requested_attempt_id,
      NULL::text, NULL::uuid, NULL::uuid, NULL::timestamptz;
    RETURN;
  END IF;

  IF attempt.purpose = 'sign-in' THEN
    INSERT INTO roomscan.apple_bridge_proofs (
      token_hash, issuer, subject, attempt_id, purpose,
      issued_at, expires_at, policy_version
    ) VALUES (
      requested_bridge_proof_hash, verified_issuer, verified_subject,
      attempt.id, 'sign-in', authoritative_time, requested_expires_at,
      requested_policy_version
    );
    RETURN QUERY SELECT 'bridge_created'::text, attempt.id, attempt.purpose,
      NULL::uuid, NULL::uuid, requested_expires_at;
  ELSE
    INSERT INTO roomscan.verified_authentication_receipts (
      token_hash, issuer, subject, purpose, initiating_principal_id,
      initiating_family_id, authenticated_at, issued_at, expires_at,
      policy_version
    ) VALUES (
      requested_receipt_hash, verified_issuer, verified_subject,
      attempt.purpose, attempt.initiating_principal_id,
      attempt.initiating_family_id, authoritative_time, authoritative_time,
      requested_expires_at, requested_policy_version
    );
    RETURN QUERY SELECT 'receipt_created'::text, attempt.id, attempt.purpose,
      attempt.initiating_principal_id, attempt.initiating_family_id,
      requested_expires_at;
  END IF;
END
$function$;

RESET ROLE;

ALTER FUNCTION roomscan.logout_all_from_access(bytea, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.mint_candidate_identity_proof_v2(bytea, timestamptz, bytea, text, text, bytea, timestamptz, text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.mutate_identity_v2(bytea, timestamptz, bytea, text, boolean, text, text, text, text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.issue_magic_challenge_v2(bytea, timestamptz, text, bytea, text, text, bytea, bytea, timestamptz, text, text, text, bytea, bytea, bytea, integer, integer, integer, integer, integer, integer, integer, integer) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.consume_magic_challenge_v2(text, bytea, text, timestamptz, bytea, timestamptz, text, bytea, bytea, timestamptz, timestamptz, timestamptz, text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.issue_magic_challenge_v3(bytea, timestamptz, text, bytea, bytea, text, text, text, bytea, bytea, timestamptz, text, text, text, bytea, bytea, bytea, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.consume_magic_challenge_v3(text, bytea, text, timestamptz, bytea) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.redeem_magic_completion_v3(bytea, text, bytea, text, bytea, timestamptz, bytea, timestamptz, text, bytea, bytea, timestamptz, timestamptz, timestamptz, text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.create_apple_attempt_v2(bytea, timestamptz, text, bytea, bytea, text, text, text, timestamptz, text, text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.accept_apple_verified_result_v2(text, text, text, bytea, bytea, timestamptz, timestamptz, text) OWNER TO roomscan_policy;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA roomscan FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA roomscan FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE ON roomscan.magic_links,
  roomscan.magic_link_delivery_outbox, roomscan.apple_auth_attempts,
  roomscan.apple_bridge_proofs, roomscan.verified_authentication_receipts,
  roomscan.candidate_identity_proofs, roomscan.principals,
  roomscan.auth_session_families, roomscan.auth_access_tokens,
  roomscan.auth_refresh_tokens, roomscan.security_notification_outbox,
  roomscan.magic_completion_handoffs
  TO roomscan_policy;
GRANT SELECT, INSERT ON roomscan.magic_link_rate_events,
  roomscan.identity_audit_events, roomscan.magic_completion_redeem_failures
  TO roomscan_policy;
GRANT SELECT, INSERT, DELETE ON roomscan.external_identities TO roomscan_policy;

-- Apple begin/finish is the API lane. Cognito receives only the one-time
-- app-owned bridge consumer; it cannot initiate or finish direct Apple auth.
REVOKE EXECUTE ON FUNCTION
  roomscan.issue_magic_challenge_v2(bytea, timestamptz, text, bytea, text, text, bytea, bytea, timestamptz, text, text, text, bytea, bytea, bytea, integer, integer, integer, integer, integer, integer, integer, integer),
  roomscan.consume_magic_challenge_v2(text, bytea, text, timestamptz, bytea, timestamptz, text, bytea, bytea, timestamptz, timestamptz, timestamptz, text)
  FROM roomscan_api_runtime, roomscan_authorizer_runtime,
    roomscan_auth_challenge_runtime, roomscan_stripe_ingress_runtime,
    roomscan_stripe_reconciliation_runtime, roomscan_audit_export_runtime,
    roomscan_email_delivery_runtime, roomscan_operator, roomscan_app;
REVOKE EXECUTE ON FUNCTION
  roomscan.claim_refresh_rotation(bytea, bytea, timestamptz),
  roomscan.claim_magic_link(text, bytea, text, timestamptz),
  roomscan.supersede_magic_link(text, timestamptz),
  roomscan.supersede_magic_link_siblings(text, timestamptz),
  roomscan.claim_magic_delivery(text, text, timestamptz, timestamptz),
  roomscan.validate_magic_delivery(text, text, timestamptz),
  roomscan.complete_magic_delivery(text, text, timestamptz),
  roomscan.cancel_magic_delivery(text, text, text, timestamptz),
  roomscan.release_magic_delivery(text, text, timestamptz),
  roomscan.claim_apple_attempt_and_code(text, bytea, text, bytea, timestamptz),
  roomscan.claim_apple_nonce(bytea, timestamptz),
  roomscan.claim_apple_bridge_proof(bytea, text, text, text, text, timestamptz),
  roomscan.claim_security_notification(text, text, timestamptz, timestamptz),
  roomscan.complete_security_notification(text, text, timestamptz),
  roomscan.release_security_notification(text, text)
  FROM roomscan_auth_challenge_runtime;

-- Sealed email delivery is isolated from API and Cognito challenge execution.
-- The worker may address a known SQS wake by outbox ID or recover the oldest
-- available row without choosing a target; it receives no direct table grant.
REVOKE EXECUTE ON FUNCTION
  roomscan.claim_magic_delivery(text, text, timestamptz, timestamptz),
  roomscan.claim_next_magic_delivery(text, timestamptz, timestamptz),
  roomscan.validate_magic_delivery(text, text, timestamptz),
  roomscan.complete_magic_delivery(text, text, timestamptz),
  roomscan.cancel_magic_delivery(text, text, text, timestamptz),
  roomscan.release_magic_delivery(text, text, timestamptz)
  FROM roomscan_api_runtime, roomscan_authorizer_runtime,
    roomscan_auth_challenge_runtime, roomscan_stripe_ingress_runtime,
    roomscan_stripe_reconciliation_runtime, roomscan_audit_export_runtime,
    roomscan_email_delivery_runtime, roomscan_operator, roomscan_app;
GRANT EXECUTE ON FUNCTION
  roomscan.claim_magic_delivery(text, text, timestamptz, timestamptz),
  roomscan.claim_next_magic_delivery(text, timestamptz, timestamptz),
  roomscan.validate_magic_delivery(text, text, timestamptz),
  roomscan.complete_magic_delivery(text, text, timestamptz),
  roomscan.cancel_magic_delivery(text, text, text, timestamptz),
  roomscan.release_magic_delivery(text, text, timestamptz)
  TO roomscan_email_delivery_runtime;

GRANT EXECUTE ON FUNCTION
  roomscan.logout_all_from_access(bytea, timestamptz),
  roomscan.mint_candidate_identity_proof_v2(bytea, timestamptz, bytea, text, text, bytea, timestamptz, text),
  roomscan.mutate_identity_v2(bytea, timestamptz, bytea, text, boolean, text, text, text, text),
  roomscan.issue_magic_challenge_v3(bytea, timestamptz, text, bytea, bytea, text, text, text, bytea, bytea, timestamptz, text, text, text, bytea, bytea, bytea, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer),
  roomscan.consume_magic_challenge_v3(text, bytea, text, timestamptz, bytea),
  roomscan.redeem_magic_completion_v3(bytea, text, bytea, text, bytea, timestamptz, bytea, timestamptz, text, bytea, bytea, timestamptz, timestamptz, timestamptz, text),
  roomscan.create_apple_attempt_v2(bytea, timestamptz, text, bytea, bytea, text, text, text, timestamptz, text, text),
  roomscan.accept_apple_verified_result_v2(text, text, text, bytea, bytea, timestamptz, timestamptz, text),
  roomscan.claim_apple_attempt_and_code(text, bytea, text, bytea, timestamptz),
  roomscan.claim_apple_nonce(bytea, timestamptz)
  TO roomscan_api_runtime;

COMMENT ON FUNCTION roomscan.logout_all_from_access(bytea, timestamptz) IS
  'Access-digest-derived logout-all: increments only the authenticated principal epoch and revokes only that principal families/access rows; fixed search_path; PUBLIC revoked; API lane.';
COMMENT ON FUNCTION roomscan.mint_candidate_identity_proof_v2(bytea, timestamptz, bytea, text, text, bytea, timestamptz, text) IS
  'Recent access plus independently verified receipt-derived candidate proof. No caller principal/family/tenant target; receipt claim and proof insertion are atomic; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.mutate_identity_v2(bytea, timestamptz, bytea, text, boolean, text, text, text, text) IS
  'Recent access plus candidate-proof-derived explicit link/unlink. Unique ownership, final-auth-method, epoch, family revocation, bounded global audit and notification outbox commit atomically; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.issue_magic_challenge_v2(bytea, timestamptz, text, bytea, text, text, bytea, bytea, timestamptz, text, text, text, bytea, bytea, bytea, integer, integer, integer, integer, integer, integer, integer, integer) IS
  'Scanner-safe magic issuance persistence: hash-only bearer material, sealed envelope, transaction locks, bounded rate policy, supersession, optional recent access binding for identity purposes, default-off sign-in flag; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.consume_magic_challenge_v2(text, bytea, text, timestamptz, bytea, timestamptz, text, bytea, bytea, timestamptz, timestamptz, timestamptz, text) IS
  'Legacy internal-only direct consume retained for forward migration history; no LOGIN role can execute it after v3; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.issue_magic_challenge_v3(bytea, timestamptz, text, bytea, bytea, text, text, text, bytea, bytea, timestamptz, text, text, text, bytea, bytea, bytea, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer) IS
  'API-only cross-device issuance: existing scanner-safe link/outbox plus keyed completion digest, S256 challenge, bounded redemption policy; no raw completion/verifier/code/token; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.consume_magic_challenge_v3(text, bytea, text, timestamptz, bytea) IS
  'API scanner confirmation only: exact selector/secret/purpose marks a transfer-code-digest-bound handoff confirmed and supersedes siblings; creates and returns no session or receipt; exact retry; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.redeem_magic_completion_v3(bytea, text, bytea, text, bytea, timestamptz, bytea, timestamptz, text, bytea, bytea, timestamptz, timestamptz, timestamptz, text) IS
  'API app redemption: keyed completion plus S256 plus transfer-code digest; network hash is failure-rate bucket only; bounded durable failures; server-derived principal and at-most-one active membership scope; atomic session/receipt issuance and exact lost-response replay; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.create_apple_attempt_v2(bytea, timestamptz, text, bytea, bytea, text, text, text, timestamptz, text, text) IS
  'API-lane Apple begin persistence. Sign-in is unscoped; identity purposes bind a recent access-derived principal/family; default-off flag; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.accept_apple_verified_result_v2(text, text, text, bytea, bytea, timestamptz, timestamptz, text) IS
  'API-lane post-exchange result persistence for literal Apple issuer: the claimed attempt determines bridge-versus-receipt purpose and principal binding; no caller principal; fixed search_path; PUBLIC revoked.';

RESET ROLE;

SET ROLE roomscan_owner;
CREATE FUNCTION roomscan.revoke_invitation_v2(
  access_token_hash bytea,
  authoritative_time timestamptz,
  requested_public_id text,
  expected_version bigint,
  hosted_global_version bigint,
  hosted_workspace_version bigint,
  requested_audit_event_id text
)
RETURNS TABLE (status text, public_id text, state text, version bigint)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  context_row record;
  invitation roomscan.invitations%ROWTYPE;
  required_action text;
BEGIN
  IF access_token_hash IS NULL OR authoritative_time IS NULL
    OR requested_public_id IS NULL OR expected_version IS NULL
    OR hosted_global_version IS NULL OR hosted_workspace_version IS NULL
    OR requested_audit_event_id IS NULL
    OR octet_length(access_token_hash) <> 32
    OR requested_public_id !~ '^inv_[A-Za-z0-9_-]{16,128}$'
    OR expected_version < 1
    OR requested_audit_event_id !~ '^aud_[A-Za-z0-9_-]{16,128}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_INVITATION_REVOCATION';
  END IF;
  SELECT * INTO context_row
  FROM roomscan.resolve_access_context(access_token_hash, authoritative_time);
  IF NOT FOUND OR context_row.workspace_id IS NULL
    OR context_row.recent_authentication IS DISTINCT FROM true
    OR context_row.role NOT IN ('owner', 'admin') THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'INVITATION_REVOCATION_AUTHORIZATION_REQUIRED';
  END IF;
  SELECT candidate.* INTO invitation
  FROM roomscan.invitations AS candidate
  WHERE candidate.workspace_id = context_row.workspace_id
    AND candidate.public_id = requested_public_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'unavailable'::text, NULL::text, NULL::text, NULL::bigint;
    RETURN;
  END IF;
  IF invitation.invited_role = 'admin' AND context_row.role <> 'owner' THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'INVITATION_REVOCATION_AUTHORIZATION_REQUIRED';
  END IF;
  required_action := 'member.revoke.' || invitation.invited_role;
  IF required_action = 'member.revoke.admin' THEN
    -- The current service matrix intentionally models admin invitation
    -- revocation as the Owner-only member.change.admin sensitive action.
    required_action := 'member.change.admin';
  END IF;
  IF NOT roomscan.hosted_mutation_grant_matches(
    context_row.workspace_id, required_action,
    hosted_global_version, hosted_workspace_version, NULL, NULL
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'HOSTED_GRANT_REJECTED';
  END IF;
  IF invitation.state <> 'active' OR invitation.version <> expected_version THEN
    RETURN QUERY SELECT 'stale'::text, invitation.public_id,
      invitation.state, invitation.version;
    RETURN;
  END IF;
  UPDATE roomscan.invitations AS candidate
  SET state = 'revoked', revoked_at = authoritative_time,
      updated_at = authoritative_time, version = candidate.version + 1
  WHERE candidate.id = invitation.id AND candidate.state = 'active'
    AND candidate.version = expected_version
  RETURNING candidate.* INTO invitation;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'INVITATION_REVOCATION_RACE';
  END IF;
  PERFORM roomscan.append_workspace_audit_v2(
    context_row.workspace_id, requested_audit_event_id,
    context_row.principal_id, 'membership.invitation_revoked',
    'invitation', invitation.public_id, NULL, authoritative_time
  );
  RETURN QUERY SELECT 'revoked'::text, invitation.public_id,
    invitation.state, invitation.version;
END
$function$;
RESET ROLE;
ALTER FUNCTION roomscan.revoke_invitation_v2(bytea, timestamptz, text, bigint, bigint, bigint, text) OWNER TO roomscan_policy;
REVOKE ALL ON FUNCTION roomscan.revoke_invitation_v2(bytea, timestamptz, text, bigint, bigint, bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION roomscan.revoke_invitation_v2(bytea, timestamptz, text, bigint, bigint, bigint, text)
  TO roomscan_api_runtime;
COMMENT ON FUNCTION roomscan.revoke_invitation_v2(bytea, timestamptz, text, bigint, bigint, bigint, text) IS
  'Session-derived workspace and current actor; public invitation ID plus CAS/versioned literal-true hosted grant; active-to-revoked transition and bounded audit are atomic; fixed search_path; PUBLIC revoked.';

RESET ROLE;

SET ROLE roomscan_owner;

CREATE FUNCTION roomscan.read_workspace_authorization_state(
  access_token_hash bytea,
  authoritative_time timestamptz
)
RETURNS TABLE (
  principal_id uuid,
  principal_canonical_id text,
  family_id uuid,
  family_public_id text,
  workspace_id uuid,
  role text,
  authorization_version bigint,
  authentication_epoch bigint,
  authenticated_at timestamptz,
  recent_authentication boolean,
  professional_sign_in_global_enabled boolean,
  professional_sign_in_global_version bigint,
  hosted_global_enabled boolean,
  hosted_global_version bigint,
  hosted_workspace_enabled boolean,
  hosted_workspace_version bigint,
  publication_global_enabled boolean,
  publication_global_version bigint,
  publication_workspace_enabled boolean,
  publication_workspace_version bigint,
  editor_publishing_allowed boolean,
  editor_publishing_policy_version bigint,
  workspace_slug text,
  workspace_display_name text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
BEGIN
  IF access_token_hash IS NULL OR authoritative_time IS NULL
    OR octet_length(access_token_hash) <> 32 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_AUTHORIZATION_STATE_INPUT';
  END IF;
  SELECT * INTO context_row
  FROM roomscan.resolve_access_context(access_token_hash, authoritative_time);
  IF NOT FOUND OR context_row.workspace_id IS NULL THEN
    RETURN;
  END IF;
  RETURN QUERY
  SELECT context_row.principal_id, context_row.canonical_principal_id,
    context_row.family_id, context_row.family_public_id,
    context_row.workspace_id, context_row.role,
    context_row.authorization_version, context_row.authentication_epoch,
    context_row.authenticated_at, context_row.recent_authentication,
    COALESCE(signin_global.enabled IS TRUE, false),
    COALESCE(signin_global.version, 0::bigint),
    COALESCE(hosted_global.enabled IS TRUE, false),
    COALESCE(hosted_global.version, 0::bigint),
    COALESCE(hosted_workspace.enabled IS TRUE, false),
    COALESCE(hosted_workspace.version, 0::bigint),
    COALESCE(publication_global.enabled IS TRUE, false),
    COALESCE(publication_global.version, 0::bigint),
    COALESCE(publication_workspace.enabled IS TRUE, false),
    COALESCE(publication_workspace.version, 0::bigint),
    COALESCE(publishing_policy.editor_publishing_allowed IS TRUE, false),
    COALESCE(publishing_policy.version, 0::bigint),
    current_workspace.slug, current_workspace.display_name
  FROM roomscan.workspaces AS current_workspace
  LEFT JOIN roomscan.global_operational_flags AS signin_global
    ON signin_global.flag_key = 'professional_sign_in_enabled'
  LEFT JOIN roomscan.global_operational_flags AS hosted_global
    ON hosted_global.flag_key = 'hosted_operations_enabled'
  LEFT JOIN roomscan.workspace_operational_flags AS hosted_workspace
    ON hosted_workspace.workspace_id = context_row.workspace_id
   AND hosted_workspace.flag_key = 'hosted_operations_enabled'
  LEFT JOIN roomscan.global_operational_flags AS publication_global
    ON publication_global.flag_key = 'publication_enabled'
  LEFT JOIN roomscan.workspace_operational_flags AS publication_workspace
    ON publication_workspace.workspace_id = context_row.workspace_id
   AND publication_workspace.flag_key = 'publication_enabled'
  LEFT JOIN roomscan.workspace_publishing_policies AS publishing_policy
    ON publishing_policy.workspace_id = context_row.workspace_id
  WHERE current_workspace.id = context_row.workspace_id;
END
$function$;

CREATE FUNCTION roomscan.read_current_subscription_v2(
  access_token_hash bytea,
  authoritative_time timestamptz
)
RETURNS TABLE (
  workspace_id uuid,
  provider_account_id text,
  reconciliation_generation bigint,
  status text,
  plan_key text,
  current_period_end timestamptz,
  source_observed_at timestamptz,
  applied_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE context_row record;
BEGIN
  IF access_token_hash IS NULL OR authoritative_time IS NULL
    OR octet_length(access_token_hash) <> 32 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_SUBSCRIPTION_READ_INPUT';
  END IF;
  SELECT * INTO context_row
  FROM roomscan.resolve_access_context(access_token_hash, authoritative_time);
  IF NOT FOUND OR context_row.workspace_id IS NULL THEN
    RETURN;
  END IF;
  RETURN QUERY
  SELECT subscription.workspace_id, account.provider_account_id,
    subscription.reconciliation_generation, subscription.status,
    subscription.plan_key, subscription.current_period_end,
    subscription.source_observed_at, subscription.updated_at
  FROM roomscan.subscription_states AS subscription
  JOIN roomscan.stripe_billing_bindings AS account
    ON account.workspace_id = subscription.workspace_id
  WHERE subscription.workspace_id = context_row.workspace_id;
END
$function$;

CREATE FUNCTION roomscan.read_quota_overview_v2(
  access_token_hash bytea,
  authoritative_time timestamptz
)
RETURNS SETOF roomscan.quota_usage_v2
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  context_row record;
  active_policy record;
  returned_rows integer;
BEGIN
  IF access_token_hash IS NULL OR authoritative_time IS NULL
    OR octet_length(access_token_hash) <> 32 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_QUOTA_OVERVIEW_INPUT';
  END IF;

  SELECT * INTO context_row
  FROM roomscan.resolve_access_context(access_token_hash, authoritative_time);
  IF NOT FOUND OR context_row.principal_id IS NULL
    OR context_row.canonical_principal_id IS NULL
    OR context_row.workspace_id IS NULL
    OR context_row.authorization_version IS NULL THEN
    RETURN;
  END IF;

  -- Only server-derived resolver values establish tenant context. These are
  -- transaction-local and disappear on COMMIT/ROLLBACK, including pooled use.
  PERFORM pg_catalog.set_config(
    'app.principal_id', context_row.principal_id::text, true
  );
  PERFORM pg_catalog.set_config(
    'app.tenant_id', context_row.workspace_id::text, true
  );
  PERFORM pg_catalog.set_config(
    'app.authorization_version', context_row.authorization_version::text, true
  );

  IF NOT EXISTS (
    SELECT 1 FROM roomscan.global_operational_flags AS global_flag
    WHERE global_flag.flag_key = 'hosted_operations_enabled'
      AND global_flag.enabled IS TRUE
  ) OR NOT EXISTS (
    SELECT 1 FROM roomscan.workspace_operational_flags AS workspace_flag
    WHERE workspace_flag.workspace_id = context_row.workspace_id
      AND workspace_flag.flag_key = 'hosted_operations_enabled'
      AND workspace_flag.enabled IS TRUE
  ) THEN
    RETURN;
  END IF;

  SELECT policy.version, policy.portal_period_key
    INTO active_policy
  FROM roomscan.quota_policy_versions_v2 AS policy
  WHERE policy.workspace_id = context_row.workspace_id
    AND policy.is_active IS TRUE;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT usage.*
  FROM roomscan.quota_usage_v2 AS usage
  WHERE usage.workspace_id = context_row.workspace_id
    AND usage.policy_version = active_policy.version
    AND (
      (usage.metric IN (
        'project_count'::roomscan.quota_metric,
        'member_count'::roomscan.quota_metric,
        'working_bytes'::roomscan.quota_metric,
        'raw_bytes'::roomscan.quota_metric
      ) AND usage.period_key = 'roomscan-period-v1:lifetime')
      OR (usage.metric = 'portal_bytes'::roomscan.quota_metric
        AND usage.period_key = active_policy.portal_period_key)
    )
  ORDER BY CASE usage.metric
    WHEN 'project_count'::roomscan.quota_metric THEN 1
    WHEN 'member_count'::roomscan.quota_metric THEN 2
    WHEN 'working_bytes'::roomscan.quota_metric THEN 3
    WHEN 'raw_bytes'::roomscan.quota_metric THEN 4
    WHEN 'portal_bytes'::roomscan.quota_metric THEN 5
    ELSE 6
  END;
  GET DIAGNOSTICS returned_rows = ROW_COUNT;
  IF returned_rows <> 5 THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'QUOTA_OVERVIEW_INCOMPLETE';
  END IF;
END
$function$;

CREATE FUNCTION roomscan.read_workspace_audit_batch(
  requested_workspace_id uuid,
  after_sequence bigint,
  requested_limit integer
)
RETURNS TABLE (
  workspace_id uuid,
  sequence bigint,
  event_id text,
  actor_principal_canonical_id text,
  action text,
  subject_kind text,
  subject_id text,
  authorization_version bigint,
  occurred_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  IF requested_workspace_id IS NULL OR after_sequence IS NULL
    OR requested_limit IS NULL OR after_sequence < 0
    OR requested_limit NOT BETWEEN 1 AND 1000 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_AUDIT_EXPORT_READ';
  END IF;
  RETURN QUERY
  SELECT event.workspace_id, event.sequence, event.event_id,
    principal.canonical_id, event.action, event.subject_kind,
    event.subject_id, event.authorization_version, event.occurred_at
  FROM roomscan.audit_events AS event
  LEFT JOIN roomscan.principals AS principal
    ON principal.id = event.actor_principal_id
  WHERE event.workspace_id = requested_workspace_id
    AND event.sequence > after_sequence
  ORDER BY event.sequence
  LIMIT requested_limit;
END
$function$;

CREATE FUNCTION roomscan.mark_workspace_audit_exported(
  requested_workspace_id uuid,
  expected_last_exported_sequence bigint,
  requested_through_sequence bigint,
  authoritative_time timestamptz
)
RETURNS TABLE (
  status text,
  workspace_id uuid,
  last_exported_sequence bigint,
  next_sequence bigint
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  audit_state roomscan.audit_states%ROWTYPE;
  max_sequence bigint;
BEGIN
  IF requested_workspace_id IS NULL OR expected_last_exported_sequence IS NULL
    OR requested_through_sequence IS NULL OR authoritative_time IS NULL
    OR expected_last_exported_sequence < 0 OR requested_through_sequence < 0
    OR requested_through_sequence < expected_last_exported_sequence THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_AUDIT_EXPORT_MARK';
  END IF;
  SELECT state.* INTO audit_state
  FROM roomscan.audit_states AS state
  WHERE state.workspace_id = requested_workspace_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'unavailable'::text, requested_workspace_id,
      NULL::bigint, NULL::bigint;
    RETURN;
  END IF;
  SELECT COALESCE(max(event.sequence), 0) INTO max_sequence
  FROM roomscan.audit_events AS event
  WHERE event.workspace_id = requested_workspace_id;
  IF audit_state.last_exported_sequence <> expected_last_exported_sequence
    OR requested_through_sequence > max_sequence THEN
    RETURN QUERY SELECT 'stale'::text, requested_workspace_id,
      audit_state.last_exported_sequence,
      GREATEST(audit_state.next_sequence, max_sequence + 1);
    RETURN;
  END IF;
  UPDATE roomscan.audit_states AS state
  SET last_exported_sequence = requested_through_sequence,
      next_sequence = GREATEST(state.next_sequence, max_sequence + 1),
      updated_at = authoritative_time
  WHERE state.workspace_id = requested_workspace_id
    AND state.last_exported_sequence = expected_last_exported_sequence
  RETURNING state.* INTO audit_state;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'AUDIT_EXPORT_MARK_RACE';
  END IF;
  RETURN QUERY SELECT 'marked'::text, audit_state.workspace_id,
    audit_state.last_exported_sequence, audit_state.next_sequence;
END
$function$;

RESET ROLE;
ALTER FUNCTION roomscan.read_workspace_authorization_state(bytea, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.read_current_subscription_v2(bytea, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.read_quota_overview_v2(bytea, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.read_workspace_audit_batch(uuid, bigint, integer) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.mark_workspace_audit_exported(uuid, bigint, bigint, timestamptz) OWNER TO roomscan_policy;
REVOKE ALL ON FUNCTION roomscan.read_quota_overview_v2(bytea, timestamptz) FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA roomscan FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA roomscan FROM PUBLIC;
GRANT SELECT ON roomscan.global_operational_flags,
  roomscan.workspace_operational_flags, roomscan.workspace_publishing_policies,
  roomscan.subscription_states, roomscan.stripe_billing_bindings,
  roomscan.audit_states, roomscan.audit_events, roomscan.principals
  TO roomscan_policy;
GRANT UPDATE ON roomscan.audit_states TO roomscan_policy;
GRANT EXECUTE ON FUNCTION roomscan.read_workspace_authorization_state(bytea, timestamptz)
  TO roomscan_api_runtime, roomscan_authorizer_runtime;
GRANT EXECUTE ON FUNCTION roomscan.read_current_subscription_v2(bytea, timestamptz)
  TO roomscan_api_runtime;
GRANT EXECUTE ON FUNCTION roomscan.read_quota_overview_v2(bytea, timestamptz)
  TO roomscan_api_runtime;
GRANT EXECUTE ON FUNCTION
  roomscan.read_workspace_audit_batch(uuid, bigint, integer),
  roomscan.mark_workspace_audit_exported(uuid, bigint, bigint, timestamptz)
  TO roomscan_audit_export_runtime;
COMMENT ON FUNCTION roomscan.read_workspace_authorization_state(bytea, timestamptz) IS
  'Access-digest-derived current membership, server-owned workspace slug/display name, plus exact default-off global/workspace hosted/publication flag and editor-publishing versions. No caller workspace; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.read_current_subscription_v2(bytea, timestamptz) IS
  'Access-digest-derived current whole subscription snapshot with server-owned provider account mapping. No caller workspace; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.read_quota_overview_v2(bytea, timestamptz) IS
  'API-only access-digest-derived current workspace quota overview; transaction-local server context, literal-true hosted flags, four lifetime metrics and active-policy portal period; exactly five rows or fail closed; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.read_workspace_audit_batch(uuid, bigint, integer) IS
  'Audit-export worker-only bounded ordered batch. Raw workspace target is confined to the dedicated system worker lane; no API/authorizer/challenge EXECUTE; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.mark_workspace_audit_exported(uuid, bigint, bigint, timestamptz) IS
  'Audit-export worker-only monotonic CAS marker; retains all audit rows and reconciles next sequence without deletion; fixed search_path; PUBLIC revoked.';

COMMENT ON FUNCTION roomscan.accept_provider_audit_event(text, text, text, text, timestamptz) IS
  'Session-user-bound Stripe-ingress/email-delivery provider audit acceptance; exact stable-metadata retry ignores occurred-at while conflicting ID reuse raises; bounded identifiers only, no token/body/email/URL fields; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.claim_provider_audit_event(text, timestamptz, timestamptz) IS
  'Audit-export worker one-winner provider-audit lease claim with expired-lease recovery; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.complete_provider_audit_event(text, text, timestamptz) IS
  'Audit-export worker exact unexpired provider-audit lease completion; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.release_provider_audit_event(text, text, timestamptz) IS
  'Audit-export worker exact unexpired provider-audit lease release; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.sync_active_member_slot() IS
  'Internal SECURITY DEFINER trigger maintaining one active-membership slot row; no runtime EXECUTE; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.set_workspace_publishing_policy(uuid, boolean, bigint, text, text, timestamptz) IS
  'NOLOGIN operator-only audited editor-publishing CAS; literal Boolean and positive version state; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.read_global_operational_flag(text) IS
  'Bounded exact-key default-off global operational flag reader; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.read_workspace_operational_flag(bytea, timestamptz, text) IS
  'Access-digest-derived exact-key default-off workspace operational flag reader; no caller workspace; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.hosted_mutation_grant_matches(uuid, text, bigint, bigint, bigint, bigint) IS
  'Internal reviewed literal-true exact-version hosted/publication grant predicate; no runtime EXECUTE; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.activate_quota_policy_v2(uuid, bigint, text, text, text, bigint, bigint, bigint, bigint, bigint, integer, bigint, bigint, timestamptz) IS
  'NOLOGIN operator-only forward quota-policy activation; version/classification/period validated and member usage seeded from authoritative slots; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.quota_snapshot_v2(bytea, timestamptz, roomscan.quota_metric, text) IS
  'Access-digest-derived exact period/metric quota snapshot; no caller workspace; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.finalize_quota_v2(bytea, timestamptz, text, text, bigint, bigint, bigint, bigint, bigint) IS
  'Access-derived exact reservation finalize with original action/resource/period/grant binding and exact retry; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.release_quota_v2(bytea, timestamptz, text, text, text, bigint, bigint, bigint, bigint) IS
  'Access-derived exact reservation release with bounded reason, original grant, terminal-state retry safety and no deletion; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.bind_stripe_account(uuid, text, text, text, text, timestamptz) IS
  'NOLOGIN operator-only server-owned account-mode/account/customer/subscription/workspace binding; platform accounts may hold many exact workspace scopes only when no connected binding exists, while connected mode is symmetrically exclusive per provider account under an advisory transaction lock; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.claim_stripe_reconciliation_v2(text, timestamptz, timestamptz) IS
  'Stripe reconciliation worker one-winner dirty-workspace claim with server-owned account mapping and bounded lease; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.release_stripe_reconciliation_v2(text, text, text, text, text, bigint, timestamptz) IS
  'Stripe reconciliation worker exact lease/account-mode/account/customer/subscription/generation release; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.append_workspace_audit_v2(uuid, text, uuid, text, text, text, bigint, timestamptz) IS
  'Internal bounded monotonic workspace audit append used only inside reviewed membership composites; no runtime EXECUTE; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.create_invitation_v2(bytea, timestamptz, text, bytea, text, text, timestamptz, bigint, bigint, text) IS
  'Access-derived current actor/workspace invitation creation with hash-only token, hosted grant, role matrix and atomic audit; optional invited email never links identity; fixed search_path; PUBLIC revoked.';
COMMENT ON FUNCTION roomscan.read_invitation_by_token(bytea, timestamptz, bytea) IS
  'Access-principal plus invitation-token-hash lookup; workspace is token/server derived and no caller workspace is accepted; fixed search_path; PUBLIC revoked.';

RESET ROLE;
