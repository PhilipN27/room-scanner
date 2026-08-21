-- Slice 4 hosted authentication persistence. This migration is forward-only:
-- applied ledgers are never rewritten and no caller-supplied workspace is an
-- authentication input.
SET ROLE roomscan_owner;

ALTER TABLE roomscan.principals
  ADD COLUMN canonical_id text NOT NULL
    DEFAULT ('prn_' || encode(gen_random_bytes(16), 'hex')),
  ADD COLUMN authentication_epoch bigint NOT NULL DEFAULT 0;
ALTER TABLE roomscan.principals
  ADD CONSTRAINT principals_canonical_id_format CHECK (
    canonical_id ~ '^prn_[A-Za-z0-9_-]{22,64}$'
  ),
  ADD CONSTRAINT principals_normalized_email_length CHECK (
    normalized_email IS NULL OR length(normalized_email) BETWEEN 3 AND 320
  ),
  ADD CONSTRAINT principals_authentication_epoch_nonnegative CHECK (
    authentication_epoch >= 0
  ),
  ADD CONSTRAINT principals_canonical_id_unique UNIQUE (canonical_id);

ALTER TABLE roomscan.external_identities RENAME COLUMN provider TO issuer;
ALTER TABLE roomscan.external_identities RENAME COLUMN provider_subject TO subject;
ALTER TABLE roomscan.external_identities RENAME COLUMN verified_at TO linked_at;
UPDATE roomscan.external_identities
SET linked_at = created_at
WHERE linked_at IS NULL;
ALTER TABLE roomscan.external_identities
  ALTER COLUMN linked_at SET NOT NULL,
  DROP CONSTRAINT external_identities_provider_check,
  ADD CONSTRAINT external_identities_issuer_length CHECK (
    length(issuer) BETWEEN 1 AND 512
  );

ALTER TABLE roomscan.auth_session_families
  ADD COLUMN public_id text,
  ADD COLUMN authentication_epoch bigint,
  ADD COLUMN authenticated_at timestamptz,
  ADD COLUMN last_used_at timestamptz,
  ADD COLUMN inactivity_expires_at timestamptz,
  ADD COLUMN absolute_expires_at timestamptz,
  ADD COLUMN policy_version text,
  ADD COLUMN workspace_id uuid REFERENCES roomscan.workspaces(id) ON DELETE CASCADE,
  ADD COLUMN role text,
  ADD COLUMN authorization_version bigint,
  ADD COLUMN state text;
UPDATE roomscan.auth_session_families AS family
SET public_id = 'fam_' || replace(family.id::text, '-', ''),
    authentication_epoch = principal.authentication_epoch,
    authenticated_at = family.created_at,
    last_used_at = family.created_at,
    inactivity_expires_at = family.created_at + interval '7 days',
    absolute_expires_at = family.created_at + interval '30 days',
    policy_version = 'legacy-session-v0',
    state = CASE WHEN family.revoked_at IS NULL THEN 'active' ELSE 'revoked' END,
    revoke_reason = CASE
      WHEN family.revoked_at IS NULL THEN NULL
      ELSE COALESCE(NULLIF(family.revoke_reason, ''), 'legacy_revocation')
    END
FROM roomscan.principals AS principal
WHERE principal.id = family.principal_id;
ALTER TABLE roomscan.auth_session_families
  ALTER COLUMN public_id SET NOT NULL,
  ALTER COLUMN authentication_epoch SET NOT NULL,
  ALTER COLUMN authenticated_at SET NOT NULL,
  ALTER COLUMN last_used_at SET NOT NULL,
  ALTER COLUMN inactivity_expires_at SET NOT NULL,
  ALTER COLUMN absolute_expires_at SET NOT NULL,
  ALTER COLUMN policy_version SET NOT NULL,
  ALTER COLUMN state SET NOT NULL,
  ALTER COLUMN state SET DEFAULT 'active',
  ADD CONSTRAINT auth_session_families_public_id_format CHECK (
    public_id ~ '^[A-Za-z0-9_-]{16,128}$'
  ),
  ADD CONSTRAINT auth_session_families_public_id_unique UNIQUE (public_id),
  ADD CONSTRAINT auth_session_families_epoch_nonnegative CHECK (
    authentication_epoch >= 0
  ),
  ADD CONSTRAINT auth_session_families_time_bounds CHECK (
    authenticated_at <= created_at
    AND created_at <= last_used_at
    AND last_used_at < inactivity_expires_at
    AND inactivity_expires_at <= absolute_expires_at
  ),
  ADD CONSTRAINT auth_session_families_policy_length CHECK (
    length(policy_version) BETWEEN 1 AND 64
  ),
  ADD CONSTRAINT auth_session_families_role CHECK (
    role IS NULL OR role IN ('owner', 'admin', 'editor', 'viewer')
  ),
  ADD CONSTRAINT auth_session_families_scope_complete CHECK (
    (workspace_id IS NULL AND role IS NULL AND authorization_version IS NULL)
    OR (
      workspace_id IS NOT NULL
      AND role IS NOT NULL
      AND authorization_version IS NOT NULL
      AND authorization_version > 0
    )
  ),
  ADD CONSTRAINT auth_session_families_state CHECK (
    (state = 'active' AND revoked_at IS NULL AND revoke_reason IS NULL)
    OR (
      state = 'revoked'
      AND revoked_at IS NOT NULL
      AND length(revoke_reason) BETWEEN 1 AND 128
    )
  );

ALTER TABLE roomscan.auth_sessions RENAME TO auth_access_tokens;
ALTER TABLE roomscan.auth_access_tokens
  ADD COLUMN principal_id uuid REFERENCES roomscan.principals(id) ON DELETE CASCADE,
  ADD COLUMN authentication_epoch bigint,
  ADD COLUMN authenticated_at timestamptz,
  ADD COLUMN issued_at timestamptz,
  ADD COLUMN workspace_id uuid REFERENCES roomscan.workspaces(id) ON DELETE CASCADE,
  ADD COLUMN role text,
  ADD COLUMN authorization_version bigint,
  ADD COLUMN state text;
UPDATE roomscan.auth_access_tokens AS access
SET principal_id = family.principal_id,
    authentication_epoch = family.authentication_epoch,
    authenticated_at = family.authenticated_at,
    issued_at = access.created_at,
    workspace_id = family.workspace_id,
    role = family.role,
    authorization_version = family.authorization_version,
    state = CASE WHEN access.revoked_at IS NULL THEN 'active' ELSE 'revoked' END
FROM roomscan.auth_session_families AS family
WHERE family.id = access.family_id;
ALTER TABLE roomscan.auth_access_tokens
  ALTER COLUMN principal_id SET NOT NULL,
  ALTER COLUMN authentication_epoch SET NOT NULL,
  ALTER COLUMN authenticated_at SET NOT NULL,
  ALTER COLUMN issued_at SET NOT NULL,
  ALTER COLUMN state SET NOT NULL,
  ALTER COLUMN state SET DEFAULT 'active',
  ADD CONSTRAINT auth_access_tokens_epoch_nonnegative CHECK (
    authentication_epoch >= 0
  ),
  ADD CONSTRAINT auth_access_tokens_time_bounds CHECK (
    authenticated_at <= issued_at AND issued_at < expires_at
  ),
  ADD CONSTRAINT auth_access_tokens_role CHECK (
    role IS NULL OR role IN ('owner', 'admin', 'editor', 'viewer')
  ),
  ADD CONSTRAINT auth_access_tokens_scope_complete CHECK (
    (workspace_id IS NULL AND role IS NULL AND authorization_version IS NULL)
    OR (
      workspace_id IS NOT NULL
      AND role IS NOT NULL
      AND authorization_version IS NOT NULL
      AND authorization_version > 0
    )
  ),
  ADD CONSTRAINT auth_access_tokens_state CHECK (
    (state = 'active' AND revoked_at IS NULL)
    OR (state = 'revoked' AND revoked_at IS NOT NULL)
  );

CREATE TABLE roomscan.auth_refresh_tokens (
  token_hash bytea PRIMARY KEY CHECK (octet_length(token_hash) = 32),
  family_id uuid NOT NULL REFERENCES roomscan.auth_session_families(id) ON DELETE CASCADE,
  issued_at timestamptz NOT NULL,
  state text NOT NULL DEFAULT 'active' CHECK (state IN ('active', 'rotated')),
  child_token_hash bytea UNIQUE CHECK (
    child_token_hash IS NULL OR octet_length(child_token_hash) = 32
  ),
  rotated_at timestamptz,
  CHECK (
    (state = 'active' AND child_token_hash IS NULL AND rotated_at IS NULL)
    OR (state = 'rotated' AND child_token_hash IS NOT NULL AND rotated_at IS NOT NULL)
  ),
  FOREIGN KEY (child_token_hash) REFERENCES roomscan.auth_refresh_tokens(token_hash)
    DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE roomscan.magic_links (
  selector text PRIMARY KEY CHECK (
    length(selector) = 22 AND selector ~ '^[A-Za-z0-9_-]+$'
  ),
  secret_digest bytea NOT NULL CHECK (octet_length(secret_digest) = 32),
  purpose text NOT NULL CHECK (
    purpose IN ('sign-in', 'reauthenticate', 'link-identity', 'unlink-identity')
  ),
  normalized_delivery_identity text NOT NULL CHECK (
    length(normalized_delivery_identity) BETWEEN 3 AND 320
  ),
  address_hash bytea NOT NULL CHECK (octet_length(address_hash) = 32),
  network_hash bytea NOT NULL CHECK (octet_length(network_hash) = 32),
  issued_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  policy_version text NOT NULL CHECK (length(policy_version) BETWEEN 1 AND 64),
  initiating_principal_id uuid REFERENCES roomscan.principals(id),
  initiating_family_id uuid REFERENCES roomscan.auth_session_families(id),
  initiating_authenticated_at timestamptz,
  state text NOT NULL DEFAULT 'active' CHECK (
    state IN ('active', 'consumed', 'superseded')
  ),
  consumed_at timestamptz,
  superseded_at timestamptz,
  CHECK (issued_at < expires_at),
  CHECK (
    (purpose IN ('link-identity', 'unlink-identity')
      AND initiating_principal_id IS NOT NULL
      AND initiating_family_id IS NOT NULL
      AND initiating_authenticated_at IS NOT NULL)
    OR (purpose IN ('sign-in', 'reauthenticate')
      AND initiating_principal_id IS NULL
      AND initiating_family_id IS NULL
      AND initiating_authenticated_at IS NULL)
  ),
  CHECK (
    (state = 'active' AND consumed_at IS NULL AND superseded_at IS NULL)
    OR (state = 'consumed' AND consumed_at IS NOT NULL AND superseded_at IS NULL)
    OR (state = 'superseded' AND consumed_at IS NULL AND superseded_at IS NOT NULL)
  )
);
CREATE INDEX magic_links_active_identity_purpose
ON roomscan.magic_links (
  normalized_delivery_identity, purpose, issued_at, selector
) WHERE state = 'active';

CREATE TABLE roomscan.magic_link_rate_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind text NOT NULL CHECK (kind IN ('request', 'delivery')),
  subject_hash bytea NOT NULL CHECK (octet_length(subject_hash) = 32),
  occurred_at timestamptz NOT NULL
);
CREATE INDEX magic_link_rate_events_lookup
ON roomscan.magic_link_rate_events (kind, subject_hash, occurred_at);

CREATE TABLE roomscan.magic_link_delivery_outbox (
  id text PRIMARY KEY CHECK (
    length(id) BETWEEN 16 AND 128 AND id ~ '^[A-Za-z0-9_-]+$'
  ),
  selector text NOT NULL UNIQUE REFERENCES roomscan.magic_links(selector) ON DELETE CASCADE,
  normalized_delivery_identity text NOT NULL CHECK (
    length(normalized_delivery_identity) BETWEEN 3 AND 320
  ),
  purpose text NOT NULL CHECK (
    purpose IN ('sign-in', 'reauthenticate', 'link-identity', 'unlink-identity')
  ),
  envelope_version text NOT NULL CHECK (envelope_version = 'aes-256-gcm-v1'),
  key_id text NOT NULL CHECK (
    length(key_id) BETWEEN 1 AND 64 AND key_id ~ '^[A-Za-z0-9._-]+$'
  ),
  iv bytea NOT NULL CHECK (octet_length(iv) = 12),
  ciphertext bytea NOT NULL CHECK (octet_length(ciphertext) = 32),
  authentication_tag bytea NOT NULL CHECK (octet_length(authentication_tag) = 16),
  created_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  policy_version text NOT NULL CHECK (length(policy_version) BETWEEN 1 AND 64),
  state text NOT NULL DEFAULT 'pending' CHECK (
    state IN ('pending', 'leased', 'delivered', 'expired', 'cancelled')
  ),
  delivery_attempts integer NOT NULL DEFAULT 0 CHECK (delivery_attempts >= 0),
  lease_id text CHECK (
    lease_id IS NULL OR (length(lease_id) BETWEEN 1 AND 128 AND lease_id ~ '^[A-Za-z0-9_-]+$')
  ),
  lease_expires_at timestamptz,
  delivered_at timestamptz,
  cancelled_at timestamptz,
  cancellation_reason text CHECK (
    cancellation_reason IS NULL
    OR cancellation_reason IN ('expired', 'unknown_key', 'tampered_envelope')
  ),
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
      AND cancellation_reason IN ('unknown_key', 'tampered_envelope'))
  )
);
CREATE INDEX magic_link_delivery_available
ON roomscan.magic_link_delivery_outbox (state, lease_expires_at, created_at, id);

CREATE TABLE roomscan.apple_auth_attempts (
  id text PRIMARY KEY CHECK (
    length(id) BETWEEN 16 AND 128 AND id ~ '^[A-Za-z0-9_-]+$'
  ),
  state_hash bytea NOT NULL UNIQUE CHECK (octet_length(state_hash) = 32),
  nonce_hash bytea NOT NULL CHECK (octet_length(nonce_hash) = 32),
  code_challenge text NOT NULL CHECK (
    length(code_challenge) = 43 AND code_challenge ~ '^[A-Za-z0-9_-]+$'
  ),
  expected_client_id text NOT NULL CHECK (length(expected_client_id) BETWEEN 1 AND 256),
  redirect_uri text NOT NULL CHECK (
    length(redirect_uri) BETWEEN 1 AND 2048 AND redirect_uri LIKE 'https://%'
  ),
  created_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  policy_version text NOT NULL CHECK (length(policy_version) BETWEEN 1 AND 64),
  purpose text NOT NULL CHECK (
    purpose IN ('sign-in', 'link-identity', 'unlink-identity')
  ),
  initiating_principal_id uuid REFERENCES roomscan.principals(id),
  initiating_family_id uuid REFERENCES roomscan.auth_session_families(id),
  initiating_authenticated_at timestamptz,
  state text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'claimed')),
  claimed_at timestamptz,
  CHECK (created_at < expires_at),
  CHECK (
    (purpose IN ('link-identity', 'unlink-identity')
      AND initiating_principal_id IS NOT NULL
      AND initiating_family_id IS NOT NULL
      AND initiating_authenticated_at IS NOT NULL)
    OR (purpose = 'sign-in'
      AND initiating_principal_id IS NULL
      AND initiating_family_id IS NULL
      AND initiating_authenticated_at IS NULL)
  ),
  CHECK (
    (state = 'pending' AND claimed_at IS NULL)
    OR (state = 'claimed' AND claimed_at IS NOT NULL)
  )
);

CREATE TABLE roomscan.apple_code_receipts (
  code_hash bytea PRIMARY KEY CHECK (octet_length(code_hash) = 32),
  attempt_id text NOT NULL REFERENCES roomscan.apple_auth_attempts(id) ON DELETE CASCADE,
  claimed_at timestamptz NOT NULL
);

CREATE TABLE roomscan.apple_nonce_receipts (
  nonce_hash bytea PRIMARY KEY CHECK (octet_length(nonce_hash) = 32),
  claimed_at timestamptz NOT NULL
);

CREATE TABLE roomscan.apple_bridge_proofs (
  token_hash bytea PRIMARY KEY CHECK (octet_length(token_hash) = 32),
  issuer text NOT NULL CHECK (length(issuer) BETWEEN 1 AND 512),
  subject text NOT NULL CHECK (length(subject) BETWEEN 1 AND 512),
  attempt_id text NOT NULL REFERENCES roomscan.apple_auth_attempts(id) ON DELETE CASCADE,
  purpose text NOT NULL CHECK (purpose = 'sign-in'),
  issued_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  policy_version text NOT NULL CHECK (length(policy_version) BETWEEN 1 AND 64),
  state text NOT NULL DEFAULT 'active' CHECK (state IN ('active', 'consumed')),
  consumed_at timestamptz,
  CHECK (issued_at < expires_at),
  CHECK (
    (state = 'active' AND consumed_at IS NULL)
    OR (state = 'consumed' AND consumed_at IS NOT NULL)
  )
);

CREATE TABLE roomscan.verified_authentication_receipts (
  token_hash bytea PRIMARY KEY CHECK (octet_length(token_hash) = 32),
  issuer text NOT NULL CHECK (length(issuer) BETWEEN 1 AND 512),
  subject text NOT NULL CHECK (length(subject) BETWEEN 1 AND 512),
  purpose text NOT NULL CHECK (purpose IN ('link-identity', 'unlink-identity')),
  initiating_principal_id uuid NOT NULL REFERENCES roomscan.principals(id),
  initiating_family_id uuid NOT NULL REFERENCES roomscan.auth_session_families(id),
  authenticated_at timestamptz NOT NULL,
  issued_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  policy_version text NOT NULL CHECK (length(policy_version) BETWEEN 1 AND 64),
  state text NOT NULL DEFAULT 'active' CHECK (state IN ('active', 'consumed')),
  consumed_at timestamptz,
  CHECK (authenticated_at <= issued_at AND issued_at < expires_at),
  CHECK (
    (state = 'active' AND consumed_at IS NULL)
    OR (state = 'consumed' AND consumed_at IS NOT NULL)
  )
);

CREATE TABLE roomscan.candidate_identity_proofs (
  token_hash bytea PRIMARY KEY CHECK (octet_length(token_hash) = 32),
  issuer text NOT NULL CHECK (length(issuer) BETWEEN 1 AND 512),
  subject text NOT NULL CHECK (length(subject) BETWEEN 1 AND 512),
  purpose text NOT NULL CHECK (purpose IN ('link-identity', 'unlink-identity')),
  initiating_principal_id uuid NOT NULL REFERENCES roomscan.principals(id),
  initiating_family_id uuid NOT NULL REFERENCES roomscan.auth_session_families(id),
  authenticated_at timestamptz NOT NULL,
  issued_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  policy_version text NOT NULL CHECK (length(policy_version) BETWEEN 1 AND 64),
  state text NOT NULL DEFAULT 'active' CHECK (state IN ('active', 'consumed')),
  consumed_at timestamptz,
  CHECK (authenticated_at <= issued_at AND issued_at < expires_at),
  CHECK (
    (state = 'active' AND consumed_at IS NULL)
    OR (state = 'consumed' AND consumed_at IS NOT NULL)
  )
);

CREATE TABLE roomscan.identity_audit_events (
  id text PRIMARY KEY CHECK (
    length(id) BETWEEN 16 AND 128 AND id ~ '^[A-Za-z0-9_-]+$'
  ),
  event_code text NOT NULL CHECK (event_code IN ('identity.linked', 'identity.unlinked')),
  principal_id uuid NOT NULL REFERENCES roomscan.principals(id),
  authentication_epoch bigint NOT NULL CHECK (authentication_epoch >= 0),
  identity_reference text NOT NULL CHECK (
    length(identity_reference) BETWEEN 16 AND 128
    AND identity_reference ~ '^id_[A-Za-z0-9_-]+$'
  ),
  created_at timestamptz NOT NULL,
  policy_version text NOT NULL CHECK (length(policy_version) BETWEEN 1 AND 64)
);

CREATE TABLE roomscan.security_notification_outbox (
  id text PRIMARY KEY CHECK (
    length(id) BETWEEN 16 AND 128 AND id ~ '^[A-Za-z0-9_-]+$'
  ),
  event_code text NOT NULL CHECK (event_code IN ('identity.linked', 'identity.unlinked')),
  principal_id uuid NOT NULL REFERENCES roomscan.principals(id),
  identity_reference text NOT NULL CHECK (
    length(identity_reference) BETWEEN 16 AND 128
    AND identity_reference ~ '^id_[A-Za-z0-9_-]+$'
  ),
  created_at timestamptz NOT NULL,
  policy_version text NOT NULL CHECK (length(policy_version) BETWEEN 1 AND 64),
  state text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'leased', 'delivered')),
  delivery_attempts integer NOT NULL DEFAULT 0 CHECK (delivery_attempts >= 0),
  lease_id text CHECK (
    lease_id IS NULL OR (length(lease_id) BETWEEN 1 AND 128 AND lease_id ~ '^[A-Za-z0-9_-]+$')
  ),
  lease_expires_at timestamptz,
  delivered_at timestamptz,
  CHECK (
    (state = 'pending' AND lease_id IS NULL AND lease_expires_at IS NULL AND delivered_at IS NULL)
    OR (state = 'leased' AND lease_id IS NOT NULL AND lease_expires_at IS NOT NULL AND delivered_at IS NULL)
    OR (state = 'delivered' AND lease_id IS NULL AND lease_expires_at IS NULL AND delivered_at IS NOT NULL)
  )
);
CREATE INDEX security_notification_available
ON roomscan.security_notification_outbox (state, lease_expires_at, created_at, id);

CREATE FUNCTION roomscan.resolve_access_context(
  access_token_hash bytea,
  authoritative_now timestamptz
)
RETURNS TABLE (
  principal_id uuid,
  canonical_principal_id text,
  family_id uuid,
  family_public_id text,
  workspace_id uuid,
  role text,
  authorization_version bigint,
  authentication_epoch bigint,
  authenticated_at timestamptz,
  recent_authentication boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  IF access_token_hash IS NULL
    OR octet_length(access_token_hash) <> 32
    OR authoritative_now IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_ACCESS_CONTEXT_INPUT';
  END IF;

  RETURN QUERY
  SELECT principal.id,
         principal.canonical_id,
         family.id,
         family.public_id,
         access.workspace_id,
         access.role,
         access.authorization_version,
         access.authentication_epoch,
         access.authenticated_at,
         access.authenticated_at <= authoritative_now
           AND access.authenticated_at >= authoritative_now - interval '5 minutes'
  FROM roomscan.auth_access_tokens AS access
  JOIN roomscan.auth_session_families AS family
    ON family.id = access.family_id
  JOIN roomscan.principals AS principal
    ON principal.id = access.principal_id
  LEFT JOIN roomscan.memberships AS membership
    ON membership.workspace_id = access.workspace_id
   AND membership.principal_id = access.principal_id
  WHERE access.token_hash = access_token_hash
    AND access.state = 'active'
    AND access.revoked_at IS NULL
    AND access.expires_at > authoritative_now
    AND family.state = 'active'
    AND family.revoked_at IS NULL
    AND family.inactivity_expires_at > authoritative_now
    AND family.absolute_expires_at > authoritative_now
    AND family.principal_id = access.principal_id
    AND family.authentication_epoch = access.authentication_epoch
    AND principal.state = 'active'
    AND principal.authentication_epoch = access.authentication_epoch
    AND family.workspace_id IS NOT DISTINCT FROM access.workspace_id
    AND family.role IS NOT DISTINCT FROM access.role
    AND family.authorization_version IS NOT DISTINCT FROM access.authorization_version
    AND (
      (access.workspace_id IS NULL
        AND access.role IS NULL
        AND access.authorization_version IS NULL)
      OR (access.workspace_id IS NOT NULL
        AND membership.state = 'active'
        AND membership.role = access.role
        AND membership.authorization_version = access.authorization_version)
    );
END
$function$;

RESET ROLE;
ALTER FUNCTION roomscan.resolve_access_context(bytea, timestamptz) OWNER TO roomscan_policy;
REVOKE ALL ON FUNCTION roomscan.resolve_access_context(bytea, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION roomscan.resolve_access_context(bytea, timestamptz) TO roomscan_app;

REVOKE ALL ON roomscan.principals, roomscan.external_identities,
  roomscan.auth_session_families, roomscan.auth_access_tokens,
  roomscan.auth_refresh_tokens, roomscan.auth_attempts, roomscan.provider_receipts,
  roomscan.magic_links, roomscan.magic_link_rate_events,
  roomscan.magic_link_delivery_outbox, roomscan.apple_auth_attempts,
  roomscan.apple_code_receipts, roomscan.apple_nonce_receipts,
  roomscan.apple_bridge_proofs, roomscan.verified_authentication_receipts,
  roomscan.candidate_identity_proofs, roomscan.identity_audit_events,
  roomscan.security_notification_outbox
FROM roomscan_app;

GRANT SELECT ON roomscan.principals, roomscan.external_identities,
  roomscan.auth_session_families, roomscan.auth_access_tokens,
  roomscan.auth_refresh_tokens, roomscan.magic_links,
  roomscan.magic_link_rate_events, roomscan.magic_link_delivery_outbox,
  roomscan.apple_auth_attempts, roomscan.apple_bridge_proofs,
  roomscan.verified_authentication_receipts,
  roomscan.candidate_identity_proofs, roomscan.identity_audit_events,
  roomscan.security_notification_outbox
TO roomscan_app;

GRANT INSERT (id, canonical_id, created_at, updated_at)
  ON roomscan.principals TO roomscan_app;
GRANT INSERT (
  id, public_id, principal_id, authentication_epoch, authenticated_at,
  created_at, last_used_at, inactivity_expires_at, absolute_expires_at,
  policy_version, workspace_id, role, authorization_version
) ON roomscan.auth_session_families TO roomscan_app;
GRANT INSERT (
  id, family_id, token_hash, expires_at, created_at, principal_id,
  authentication_epoch, authenticated_at, issued_at, workspace_id, role,
  authorization_version
) ON roomscan.auth_access_tokens TO roomscan_app;
GRANT INSERT (token_hash, family_id, issued_at)
  ON roomscan.auth_refresh_tokens TO roomscan_app;
GRANT INSERT (
  selector, secret_digest, purpose, normalized_delivery_identity,
  address_hash, network_hash, issued_at, expires_at, policy_version,
  initiating_principal_id, initiating_family_id, initiating_authenticated_at
) ON roomscan.magic_links TO roomscan_app;
GRANT INSERT (kind, subject_hash, occurred_at)
  ON roomscan.magic_link_rate_events TO roomscan_app;
GRANT INSERT (
  id, selector, normalized_delivery_identity, purpose, envelope_version,
  key_id, iv, ciphertext, authentication_tag, created_at, expires_at,
  policy_version
) ON roomscan.magic_link_delivery_outbox TO roomscan_app;
GRANT INSERT (
  id, state_hash, nonce_hash, code_challenge, expected_client_id,
  redirect_uri, created_at, expires_at, policy_version, purpose,
  initiating_principal_id, initiating_family_id, initiating_authenticated_at
) ON roomscan.apple_auth_attempts TO roomscan_app;
GRANT INSERT (
  token_hash, issuer, subject, attempt_id, purpose, issued_at, expires_at,
  policy_version
) ON roomscan.apple_bridge_proofs TO roomscan_app;
GRANT INSERT (
  token_hash, issuer, subject, purpose, initiating_principal_id,
  initiating_family_id, authenticated_at, issued_at, expires_at,
  policy_version
) ON roomscan.verified_authentication_receipts TO roomscan_app;
GRANT INSERT (
  token_hash, issuer, subject, purpose, initiating_principal_id,
  initiating_family_id, authenticated_at, issued_at, expires_at,
  policy_version
) ON roomscan.candidate_identity_proofs TO roomscan_app;
GRANT INSERT (
  id, event_code, principal_id, authentication_epoch, identity_reference,
  created_at, policy_version
) ON roomscan.identity_audit_events TO roomscan_app;
GRANT INSERT (
  id, event_code, principal_id, identity_reference, created_at, policy_version
) ON roomscan.security_notification_outbox TO roomscan_app;

REVOKE ALL ON roomscan.auth_access_tokens, roomscan.auth_session_families
FROM roomscan_policy;
GRANT SELECT ON roomscan.auth_access_tokens, roomscan.auth_session_families,
  roomscan.principals TO roomscan_policy;
-- Preserve the accepted 0005 invitation/bootstrap reducer privileges exactly;
-- the auth resolver itself uses only SELECT, but those older reviewed
-- capabilities still require membership creation/reactivation.
GRANT SELECT, INSERT, UPDATE ON roomscan.memberships TO roomscan_policy;

COMMENT ON FUNCTION roomscan.resolve_access_context(bytea, timestamptz) IS
  'Reviewed SECURITY DEFINER authentication resolver: access-token hash and authoritative time only; server-derived principal, family, tenant, membership version, and recent-authentication context; fixed search_path; PUBLIC execute revoked.';

SET ROLE roomscan_owner;

CREATE FUNCTION roomscan.claim_refresh_rotation(
  current_token_hash bytea,
  next_token_hash bytea,
  rotated_at_time timestamptz
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  IF current_token_hash IS NULL
    OR next_token_hash IS NULL
    OR rotated_at_time IS NULL
    OR octet_length(current_token_hash) <> 32
    OR octet_length(next_token_hash) <> 32
    OR current_token_hash = next_token_hash THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_REFRESH_ROTATION';
  END IF;

  UPDATE roomscan.auth_refresh_tokens AS refresh
  SET state = 'rotated',
      child_token_hash = next_token_hash,
      rotated_at = rotated_at_time
  FROM roomscan.auth_session_families AS family,
       roomscan.principals AS principal
  WHERE refresh.token_hash = current_token_hash
    AND refresh.state = 'active'
    AND family.id = refresh.family_id
    AND family.state = 'active'
    AND family.inactivity_expires_at > rotated_at_time
    AND family.absolute_expires_at > rotated_at_time
    AND principal.id = family.principal_id
    AND principal.state = 'active'
    AND principal.authentication_epoch = family.authentication_epoch
    AND (
      (family.workspace_id IS NULL
        AND family.role IS NULL
        AND family.authorization_version IS NULL)
      OR (family.workspace_id IS NOT NULL AND EXISTS (
        SELECT 1
        FROM roomscan.memberships AS membership
        WHERE membership.workspace_id = family.workspace_id
          AND membership.principal_id = family.principal_id
          AND membership.state = 'active'
          AND membership.role = family.role
          AND membership.authorization_version = family.authorization_version
      ))
    );
  RETURN FOUND;
END
$function$;

CREATE FUNCTION roomscan.revoke_session_family(
  target_family_id uuid,
  revoked_at_time timestamptz,
  reason_code text
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  IF target_family_id IS NULL
    OR revoked_at_time IS NULL
    OR reason_code IS NULL
    OR reason_code NOT IN (
      'refresh_reuse', 'expired', 'stale_principal', 'logout', 'logout_all',
      'identity_changed', 'manual'
    ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_SESSION_REVOCATION';
  END IF;

  UPDATE roomscan.auth_session_families
  SET state = 'revoked',
      revoked_at = revoked_at_time,
      revoke_reason = reason_code
  WHERE id = target_family_id
    AND state = 'active';
  RETURN FOUND;
END
$function$;

CREATE FUNCTION roomscan.claim_magic_link(
  requested_selector text,
  requested_secret_digest bytea,
  expected_purpose text,
  claimed_at_time timestamptz
)
RETURNS SETOF roomscan.magic_links
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  IF requested_selector IS NULL
    OR requested_secret_digest IS NULL
    OR claimed_at_time IS NULL
    OR length(requested_selector) <> 22
    OR requested_selector !~ '^[A-Za-z0-9_-]+$'
    OR octet_length(requested_secret_digest) <> 32
    OR (expected_purpose IS NOT NULL AND expected_purpose NOT IN (
      'sign-in', 'reauthenticate', 'link-identity', 'unlink-identity'
    )) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_MAGIC_LINK_CLAIM';
  END IF;

  RETURN QUERY
  UPDATE roomscan.magic_links AS link
  SET state = 'consumed', consumed_at = claimed_at_time
  WHERE link.selector = requested_selector
    AND link.secret_digest = requested_secret_digest
    AND link.state = 'active'
    AND link.expires_at > claimed_at_time
    AND (expected_purpose IS NULL OR link.purpose = expected_purpose)
  RETURNING link.*;
END
$function$;

CREATE FUNCTION roomscan.supersede_magic_link(
  requested_selector text,
  superseded_at_time timestamptz
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  IF requested_selector IS NULL
    OR superseded_at_time IS NULL
    OR length(requested_selector) <> 22
    OR requested_selector !~ '^[A-Za-z0-9_-]+$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_MAGIC_LINK_SUPERSESSION';
  END IF;
  UPDATE roomscan.magic_links
  SET state = 'superseded', superseded_at = superseded_at_time
  WHERE selector = requested_selector AND state = 'active';
  RETURN FOUND;
END
$function$;

CREATE FUNCTION roomscan.supersede_magic_link_siblings(
  retained_selector text,
  superseded_at_time timestamptz
)
RETURNS integer
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  changed integer;
BEGIN
  IF retained_selector IS NULL
    OR superseded_at_time IS NULL
    OR length(retained_selector) <> 22
    OR retained_selector !~ '^[A-Za-z0-9_-]+$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_MAGIC_LINK_SUPERSESSION';
  END IF;

  WITH retained AS (
    SELECT normalized_delivery_identity, purpose
    FROM roomscan.magic_links
    WHERE selector = retained_selector
  )
  UPDATE roomscan.magic_links AS sibling
  SET state = 'superseded', superseded_at = superseded_at_time
  FROM retained
  WHERE sibling.selector <> retained_selector
    AND sibling.normalized_delivery_identity = retained.normalized_delivery_identity
    AND sibling.purpose = retained.purpose
    AND sibling.state = 'active';
  GET DIAGNOSTICS changed = ROW_COUNT;
  RETURN changed;
END
$function$;

CREATE FUNCTION roomscan.claim_magic_delivery(
  requested_id text,
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
BEGIN
  IF requested_id IS NULL
    OR requested_lease_id IS NULL
    OR claimed_at_time IS NULL
    OR requested_lease_expires_at IS NULL
    OR length(requested_id) NOT BETWEEN 16 AND 128
    OR requested_id !~ '^[A-Za-z0-9_-]+$'
    OR length(requested_lease_id) NOT BETWEEN 1 AND 128
    OR requested_lease_id !~ '^[A-Za-z0-9_-]+$'
    OR requested_lease_expires_at <= claimed_at_time THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_MAGIC_DELIVERY_LEASE';
  END IF;

  RETURN QUERY
  UPDATE roomscan.magic_link_delivery_outbox AS delivery
  SET state = 'expired',
      lease_id = NULL,
      lease_expires_at = NULL,
      cancelled_at = claimed_at_time,
      cancellation_reason = 'expired'
  WHERE delivery.id = requested_id
    AND delivery.state IN ('pending', 'leased')
    AND delivery.expires_at <= claimed_at_time
  RETURNING delivery.*;
  IF FOUND THEN
    RETURN;
  END IF;

  RETURN QUERY
  UPDATE roomscan.magic_link_delivery_outbox AS delivery
  SET state = 'leased',
      lease_id = requested_lease_id,
      lease_expires_at = LEAST(requested_lease_expires_at, delivery.expires_at),
      delivery_attempts = delivery.delivery_attempts + 1
  WHERE delivery.id = requested_id
    AND delivery.expires_at > claimed_at_time
    AND (
      delivery.state = 'pending'
      OR (delivery.state = 'leased' AND delivery.lease_expires_at <= claimed_at_time)
    )
  RETURNING delivery.*;
END
$function$;

CREATE FUNCTION roomscan.validate_magic_delivery(
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
  IF requested_id IS NULL
    OR requested_lease_id IS NULL
    OR checked_at_time IS NULL
    OR length(requested_id) NOT BETWEEN 16 AND 128
    OR length(requested_lease_id) NOT BETWEEN 1 AND 128 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_MAGIC_DELIVERY_LEASE';
  END IF;

  RETURN QUERY
  UPDATE roomscan.magic_link_delivery_outbox AS delivery
  SET state = 'expired',
      lease_id = NULL,
      lease_expires_at = NULL,
      cancelled_at = checked_at_time,
      cancellation_reason = 'expired'
  WHERE delivery.id = requested_id
    AND delivery.state = 'leased'
    AND delivery.lease_id = requested_lease_id
    AND delivery.expires_at <= checked_at_time
  RETURNING delivery.*;
  IF FOUND THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT delivery.*
  FROM roomscan.magic_link_delivery_outbox AS delivery
  WHERE delivery.id = requested_id
    AND delivery.state = 'leased'
    AND delivery.lease_id = requested_lease_id
    AND delivery.lease_expires_at > checked_at_time
    AND delivery.expires_at > checked_at_time;
END
$function$;

CREATE FUNCTION roomscan.complete_magic_delivery(
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
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_MAGIC_DELIVERY_LEASE';
  END IF;
  UPDATE roomscan.magic_link_delivery_outbox
  SET state = 'delivered',
      lease_id = NULL,
      lease_expires_at = NULL,
      delivered_at = delivered_at_time
  WHERE id = requested_id
    AND state = 'leased'
    AND lease_id = requested_lease_id
    AND lease_expires_at > delivered_at_time;
  RETURN FOUND;
END
$function$;

CREATE FUNCTION roomscan.claim_apple_attempt_and_code(
  requested_attempt_id text,
  requested_state_hash bytea,
  requested_code_challenge text,
  requested_code_hash bytea,
  claimed_at_time timestamptz
)
RETURNS TABLE (
  status text,
  attempt_id text,
  attempt_state_hash bytea,
  attempt_nonce_hash bytea,
  attempt_code_challenge text,
  expected_client_id text,
  redirect_uri text,
  created_at timestamptz,
  expires_at timestamptz,
  policy_version text,
  purpose text,
  initiating_principal_id uuid,
  initiating_family_id uuid,
  initiating_authenticated_at timestamptz,
  claimed_at timestamptz
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  claimed roomscan.apple_auth_attempts%ROWTYPE;
  code_inserted boolean;
BEGIN
  IF requested_attempt_id IS NULL
    OR requested_state_hash IS NULL
    OR requested_code_challenge IS NULL
    OR requested_code_hash IS NULL
    OR claimed_at_time IS NULL
    OR length(requested_attempt_id) NOT BETWEEN 16 AND 128
    OR octet_length(requested_state_hash) <> 32
    OR length(requested_code_challenge) <> 43
    OR requested_code_challenge !~ '^[A-Za-z0-9_-]+$'
    OR octet_length(requested_code_hash) <> 32 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_APPLE_ATTEMPT_CLAIM';
  END IF;

  SELECT attempt.*
  INTO claimed
  FROM roomscan.apple_auth_attempts AS attempt
  WHERE attempt.id = requested_attempt_id
    AND attempt.state = 'pending'
    AND attempt.state_hash = requested_state_hash
    AND attempt.code_challenge = requested_code_challenge
    AND attempt.expires_at > claimed_at_time
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN QUERY SELECT
      CASE WHEN EXISTS (
        SELECT 1 FROM roomscan.apple_code_receipts AS receipt
        WHERE receipt.code_hash = requested_code_hash
      ) THEN 'replayed_code'::text ELSE 'invalid_attempt'::text END,
      NULL::text, NULL::bytea,
      NULL::bytea, NULL::text, NULL::text, NULL::text, NULL::timestamptz,
      NULL::timestamptz, NULL::text, NULL::text, NULL::uuid, NULL::uuid,
      NULL::timestamptz, NULL::timestamptz;
    RETURN;
  END IF;

  INSERT INTO roomscan.apple_code_receipts (code_hash, attempt_id, claimed_at)
  VALUES (requested_code_hash, requested_attempt_id, claimed_at_time)
  ON CONFLICT (code_hash) DO NOTHING
  RETURNING true INTO code_inserted;
  IF NOT COALESCE(code_inserted, false) THEN
    RETURN QUERY SELECT 'replayed_code'::text, NULL::text, NULL::bytea,
      NULL::bytea, NULL::text, NULL::text, NULL::text, NULL::timestamptz,
      NULL::timestamptz, NULL::text, NULL::text, NULL::uuid, NULL::uuid,
      NULL::timestamptz, NULL::timestamptz;
    RETURN;
  END IF;

  UPDATE roomscan.apple_auth_attempts AS attempt
  SET state = 'claimed', claimed_at = claimed_at_time
  WHERE attempt.id = requested_attempt_id
    AND attempt.state = 'pending'
  RETURNING attempt.* INTO claimed;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'APPLE_ATTEMPT_STATE_CHANGED';
  END IF;

  RETURN QUERY SELECT 'claimed'::text, claimed.id, claimed.state_hash,
    claimed.nonce_hash, claimed.code_challenge, claimed.expected_client_id,
    claimed.redirect_uri, claimed.created_at, claimed.expires_at,
    claimed.policy_version, claimed.purpose, claimed.initiating_principal_id,
    claimed.initiating_family_id, claimed.initiating_authenticated_at,
    claimed.claimed_at;
END
$function$;

CREATE FUNCTION roomscan.claim_apple_nonce(
  requested_nonce_hash bytea,
  claimed_at_time timestamptz
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  inserted boolean;
BEGIN
  IF requested_nonce_hash IS NULL OR claimed_at_time IS NULL
    OR octet_length(requested_nonce_hash) <> 32 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_APPLE_NONCE_CLAIM';
  END IF;
  INSERT INTO roomscan.apple_nonce_receipts (nonce_hash, claimed_at)
  VALUES (requested_nonce_hash, claimed_at_time)
  ON CONFLICT (nonce_hash) DO NOTHING
  RETURNING true INTO inserted;
  RETURN COALESCE(inserted, false);
END
$function$;

CREATE FUNCTION roomscan.claim_apple_bridge_proof(
  requested_token_hash bytea,
  expected_issuer text,
  expected_subject text,
  expected_attempt_id text,
  expected_purpose text,
  claimed_at_time timestamptz
)
RETURNS SETOF roomscan.apple_bridge_proofs
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  IF requested_token_hash IS NULL OR expected_issuer IS NULL
    OR expected_subject IS NULL OR expected_attempt_id IS NULL
    OR expected_purpose IS NULL OR claimed_at_time IS NULL
    OR octet_length(requested_token_hash) <> 32
    OR length(expected_issuer) NOT BETWEEN 1 AND 512
    OR length(expected_subject) NOT BETWEEN 1 AND 512
    OR length(expected_attempt_id) NOT BETWEEN 16 AND 128
    OR expected_purpose <> 'sign-in' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_APPLE_BRIDGE_CLAIM';
  END IF;
  RETURN QUERY
  UPDATE roomscan.apple_bridge_proofs AS proof
  SET state = 'consumed', consumed_at = claimed_at_time
  WHERE proof.token_hash = requested_token_hash
    AND proof.issuer = expected_issuer
    AND proof.subject = expected_subject
    AND proof.attempt_id = expected_attempt_id
    AND proof.purpose = expected_purpose
    AND proof.state = 'active'
    AND proof.expires_at > claimed_at_time
  RETURNING proof.*;
END
$function$;

CREATE FUNCTION roomscan.claim_verified_auth_receipt(
  requested_token_hash bytea,
  expected_issuer text,
  expected_purpose text,
  expected_principal_id uuid,
  expected_family_id uuid,
  claimed_at_time timestamptz
)
RETURNS SETOF roomscan.verified_authentication_receipts
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  IF requested_token_hash IS NULL OR expected_issuer IS NULL
    OR expected_purpose IS NULL OR expected_principal_id IS NULL
    OR expected_family_id IS NULL OR claimed_at_time IS NULL
    OR octet_length(requested_token_hash) <> 32
    OR length(expected_issuer) NOT BETWEEN 1 AND 512
    OR expected_purpose NOT IN ('link-identity', 'unlink-identity') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_VERIFIED_AUTH_RECEIPT_CLAIM';
  END IF;
  RETURN QUERY
  UPDATE roomscan.verified_authentication_receipts AS receipt
  SET state = 'consumed', consumed_at = claimed_at_time
  WHERE receipt.token_hash = requested_token_hash
    AND receipt.issuer = expected_issuer
    AND receipt.purpose = expected_purpose
    AND receipt.initiating_principal_id = expected_principal_id
    AND receipt.initiating_family_id = expected_family_id
    AND receipt.state = 'active'
    AND receipt.expires_at > claimed_at_time
  RETURNING receipt.*;
END
$function$;

CREATE FUNCTION roomscan.claim_candidate_identity_proof(
  requested_token_hash bytea,
  expected_purpose text,
  expected_principal_id uuid,
  expected_family_id uuid,
  claimed_at_time timestamptz
)
RETURNS SETOF roomscan.candidate_identity_proofs
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  IF requested_token_hash IS NULL OR expected_purpose IS NULL
    OR expected_principal_id IS NULL OR expected_family_id IS NULL
    OR claimed_at_time IS NULL OR octet_length(requested_token_hash) <> 32
    OR expected_purpose NOT IN ('link-identity', 'unlink-identity') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_CANDIDATE_PROOF_CLAIM';
  END IF;
  RETURN QUERY
  UPDATE roomscan.candidate_identity_proofs AS proof
  SET state = 'consumed', consumed_at = claimed_at_time
  WHERE proof.token_hash = requested_token_hash
    AND proof.purpose = expected_purpose
    AND proof.initiating_principal_id = expected_principal_id
    AND proof.initiating_family_id = expected_family_id
    AND proof.state = 'active'
    AND proof.expires_at > claimed_at_time
  RETURNING proof.*;
END
$function$;

RESET ROLE;

ALTER FUNCTION roomscan.claim_refresh_rotation(bytea, bytea, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.revoke_session_family(uuid, timestamptz, text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.claim_magic_link(text, bytea, text, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.supersede_magic_link(text, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.supersede_magic_link_siblings(text, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.claim_magic_delivery(text, text, timestamptz, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.validate_magic_delivery(text, text, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.complete_magic_delivery(text, text, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.claim_apple_attempt_and_code(text, bytea, text, bytea, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.claim_apple_nonce(bytea, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.claim_apple_bridge_proof(bytea, text, text, text, text, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.claim_verified_auth_receipt(bytea, text, text, uuid, uuid, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.claim_candidate_identity_proof(bytea, text, uuid, uuid, timestamptz) OWNER TO roomscan_policy;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA roomscan FROM PUBLIC;
GRANT EXECUTE ON FUNCTION roomscan.claim_refresh_rotation(bytea, bytea, timestamptz),
  roomscan.revoke_session_family(uuid, timestamptz, text),
  roomscan.claim_magic_link(text, bytea, text, timestamptz),
  roomscan.supersede_magic_link(text, timestamptz),
  roomscan.supersede_magic_link_siblings(text, timestamptz),
  roomscan.claim_magic_delivery(text, text, timestamptz, timestamptz),
  roomscan.validate_magic_delivery(text, text, timestamptz),
  roomscan.complete_magic_delivery(text, text, timestamptz),
  roomscan.claim_apple_attempt_and_code(text, bytea, text, bytea, timestamptz),
  roomscan.claim_apple_nonce(bytea, timestamptz),
  roomscan.claim_apple_bridge_proof(bytea, text, text, text, text, timestamptz),
  roomscan.claim_verified_auth_receipt(bytea, text, text, uuid, uuid, timestamptz),
  roomscan.claim_candidate_identity_proof(bytea, text, uuid, uuid, timestamptz)
TO roomscan_app;

GRANT SELECT, UPDATE ON roomscan.auth_refresh_tokens,
  roomscan.auth_session_families, roomscan.magic_links,
  roomscan.magic_link_delivery_outbox, roomscan.apple_auth_attempts,
  roomscan.apple_bridge_proofs, roomscan.verified_authentication_receipts,
  roomscan.candidate_identity_proofs TO roomscan_policy;
GRANT SELECT, INSERT, DELETE ON roomscan.apple_code_receipts TO roomscan_policy;
GRANT SELECT, INSERT ON roomscan.apple_nonce_receipts TO roomscan_policy;

COMMENT ON FUNCTION roomscan.claim_refresh_rotation(bytea, bytea, timestamptz) IS
  'Reviewed SECURITY DEFINER authentication transition: one-winner active refresh rotation with hash-only bounded inputs; fixed search_path; PUBLIC execute revoked.';
COMMENT ON FUNCTION roomscan.revoke_session_family(uuid, timestamptz, text) IS
  'Reviewed SECURITY DEFINER authentication transition: bounded allowlisted family revocation; fixed search_path; PUBLIC execute revoked.';
COMMENT ON FUNCTION roomscan.claim_magic_link(text, bytea, text, timestamptz) IS
  'Reviewed SECURITY DEFINER authentication transition: one-winner active unexpired magic-link claim using selector and digest only; fixed search_path; PUBLIC execute revoked.';
COMMENT ON FUNCTION roomscan.supersede_magic_link(text, timestamptz) IS
  'Reviewed SECURITY DEFINER authentication transition: bounded active-link supersession; fixed search_path; PUBLIC execute revoked.';
COMMENT ON FUNCTION roomscan.supersede_magic_link_siblings(text, timestamptz) IS
  'Reviewed SECURITY DEFINER authentication transition: server-record-derived sibling supersession; fixed search_path; PUBLIC execute revoked.';
COMMENT ON FUNCTION roomscan.claim_magic_delivery(text, text, timestamptz, timestamptz) IS
  'Reviewed SECURITY DEFINER outbox transition: one-winner pending or expired-lease magic delivery claim; fixed search_path; PUBLIC execute revoked.';
COMMENT ON FUNCTION roomscan.validate_magic_delivery(text, text, timestamptz) IS
  'Reviewed SECURITY DEFINER outbox transition: lease-bound authoritative pre-send expiry check; fixed search_path; PUBLIC execute revoked.';
COMMENT ON FUNCTION roomscan.complete_magic_delivery(text, text, timestamptz) IS
  'Reviewed SECURITY DEFINER outbox transition: lease-bound magic delivery completion; fixed search_path; PUBLIC execute revoked.';
COMMENT ON FUNCTION roomscan.claim_apple_attempt_and_code(text, bytea, text, bytea, timestamptz) IS
  'Reviewed SECURITY DEFINER authentication transition: atomic one-winner Apple attempt and code-digest claim; fixed search_path; PUBLIC execute revoked.';
COMMENT ON FUNCTION roomscan.claim_apple_nonce(bytea, timestamptz) IS
  'Reviewed SECURITY DEFINER authentication transition: atomic one-winner Apple nonce-digest receipt; fixed search_path; PUBLIC execute revoked.';
COMMENT ON FUNCTION roomscan.claim_apple_bridge_proof(bytea, text, text, text, text, timestamptz) IS
  'Reviewed SECURITY DEFINER authentication transition: exact-bound one-winner Apple bridge-proof claim; fixed search_path; PUBLIC execute revoked.';
COMMENT ON FUNCTION roomscan.claim_verified_auth_receipt(bytea, text, text, uuid, uuid, timestamptz) IS
  'Reviewed SECURITY DEFINER authentication transition: exact-bound one-winner verified-auth receipt claim; fixed search_path; PUBLIC execute revoked.';
COMMENT ON FUNCTION roomscan.claim_candidate_identity_proof(bytea, text, uuid, uuid, timestamptz) IS
  'Reviewed SECURITY DEFINER authentication transition: exact-bound one-winner candidate identity proof claim; fixed search_path; PUBLIC execute revoked.';

RESET ROLE;

SET ROLE roomscan_owner;

CREATE FUNCTION roomscan.claim_external_identity(
  expected_issuer text,
  expected_subject text,
  target_principal_id uuid,
  linked_at_time timestamptz
)
RETURNS TABLE (status text, identity_id uuid, principal_id uuid)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  inserted_identity_id uuid;
  existing_identity_id uuid;
  existing_principal_id uuid;
BEGIN
  IF expected_issuer IS NULL
    OR expected_subject IS NULL
    OR target_principal_id IS NULL
    OR linked_at_time IS NULL
    OR length(expected_issuer) NOT BETWEEN 1 AND 512
    OR length(expected_subject) NOT BETWEEN 1 AND 512
    OR btrim(expected_issuer) = ''
    OR btrim(expected_subject) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_IDENTITY_CLAIM';
  END IF;

  -- Every ownership change for a principal serializes on its canonical row.
  -- A losing create transaction can therefore roll its provisional principal
  -- back without leaving an orphan.
  PERFORM 1
  FROM roomscan.principals AS principal
  WHERE principal.id = target_principal_id
    AND principal.state = 'active'
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'invalid_principal'::text, NULL::uuid, NULL::uuid;
    RETURN;
  END IF;

  INSERT INTO roomscan.external_identities (
    id, principal_id, issuer, subject, linked_at
  ) VALUES (
    gen_random_uuid(), target_principal_id, expected_issuer, expected_subject,
    linked_at_time
  )
  ON CONFLICT (issuer, subject) DO NOTHING
  RETURNING id INTO inserted_identity_id;

  IF inserted_identity_id IS NOT NULL THEN
    RETURN QUERY SELECT 'created'::text, inserted_identity_id, target_principal_id;
    RETURN;
  END IF;

  SELECT identity.id, identity.principal_id
  INTO existing_identity_id, existing_principal_id
  FROM roomscan.external_identities AS identity
  WHERE identity.issuer = expected_issuer
    AND identity.subject = expected_subject;

  RETURN QUERY SELECT
    CASE
      WHEN existing_principal_id = target_principal_id THEN 'existing'::text
      ELSE 'owned'::text
    END,
    existing_identity_id,
    existing_principal_id;
END
$function$;

CREATE FUNCTION roomscan.release_external_identity(
  expected_issuer text,
  expected_subject text,
  expected_principal_id uuid
)
RETURNS TABLE (status text)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  owner_principal_id uuid;
  identity_count integer;
BEGIN
  IF expected_issuer IS NULL
    OR expected_subject IS NULL
    OR expected_principal_id IS NULL
    OR length(expected_issuer) NOT BETWEEN 1 AND 512
    OR length(expected_subject) NOT BETWEEN 1 AND 512
    OR btrim(expected_issuer) = ''
    OR btrim(expected_subject) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_IDENTITY_RELEASE';
  END IF;

  PERFORM 1
  FROM roomscan.principals AS principal
  WHERE principal.id = expected_principal_id
    AND principal.state = 'active'
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'not_linked'::text;
    RETURN;
  END IF;

  -- claim_external_identity uses the same principal lock, so this principal's
  -- identity set and final-method count cannot change concurrently.

  SELECT identity.principal_id
  INTO owner_principal_id
  FROM roomscan.external_identities AS identity
  WHERE identity.issuer = expected_issuer
    AND identity.subject = expected_subject;
  IF owner_principal_id IS NULL THEN
    RETURN QUERY SELECT 'not_linked'::text;
    RETURN;
  END IF;
  IF owner_principal_id IS DISTINCT FROM expected_principal_id THEN
    RETURN QUERY SELECT 'candidate_owned'::text;
    RETURN;
  END IF;

  SELECT count(*)::integer
  INTO identity_count
  FROM roomscan.external_identities AS identity
  WHERE identity.principal_id = expected_principal_id;
  IF identity_count <= 1 THEN
    RETURN QUERY SELECT 'final_auth_method'::text;
    RETURN;
  END IF;

  DELETE FROM roomscan.external_identities AS identity
  WHERE identity.issuer = expected_issuer
    AND identity.subject = expected_subject
    AND identity.principal_id = expected_principal_id;
  IF NOT FOUND THEN
    RETURN QUERY SELECT 'not_linked'::text;
    RETURN;
  END IF;
  RETURN QUERY SELECT 'released'::text;
END
$function$;

CREATE FUNCTION roomscan.bump_principal_authentication_epoch(
  target_principal_id uuid
)
RETURNS bigint
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  next_epoch bigint;
BEGIN
  IF target_principal_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_PRINCIPAL_EPOCH_BUMP';
  END IF;
  UPDATE roomscan.principals AS principal
  SET authentication_epoch = principal.authentication_epoch + 1,
      updated_at = clock_timestamp()
  WHERE principal.id = target_principal_id
    AND principal.state = 'active'
  RETURNING principal.authentication_epoch INTO next_epoch;
  RETURN next_epoch;
END
$function$;

CREATE FUNCTION roomscan.revoke_principal_session_families(
  target_principal_id uuid,
  except_family_id uuid,
  revoked_at_time timestamptz,
  reason_code text
)
RETURNS integer
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  changed integer;
BEGIN
  IF target_principal_id IS NULL
    OR revoked_at_time IS NULL
    OR reason_code IS NULL
    OR reason_code NOT IN ('logout_all', 'identity_changed', 'manual') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_SESSION_FAMILY_REVOCATION';
  END IF;

  -- except_family_id is deliberately optional: NULL means revoke every family.
  UPDATE roomscan.auth_session_families AS family
  SET state = 'revoked', revoked_at = revoked_at_time, revoke_reason = reason_code
  WHERE family.principal_id = target_principal_id
    AND family.id IS DISTINCT FROM except_family_id
    AND family.state = 'active';
  GET DIAGNOSTICS changed = ROW_COUNT;
  RETURN changed;
END
$function$;

CREATE FUNCTION roomscan.revoke_access_token(
  target_token_hash bytea,
  revoked_at_time timestamptz
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  IF target_token_hash IS NULL
    OR revoked_at_time IS NULL
    OR octet_length(target_token_hash) <> 32 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_ACCESS_REVOCATION';
  END IF;
  UPDATE roomscan.auth_access_tokens AS access
  SET state = 'revoked', revoked_at = revoked_at_time
  WHERE access.token_hash = target_token_hash
    AND access.state = 'active';
  RETURN FOUND;
END
$function$;

CREATE FUNCTION roomscan.update_session_family_activity(
  target_family_id uuid,
  last_used_at_time timestamptz,
  inactivity_expires_at_time timestamptz
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  IF target_family_id IS NULL
    OR last_used_at_time IS NULL
    OR inactivity_expires_at_time IS NULL
    OR last_used_at_time >= inactivity_expires_at_time THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_SESSION_ACTIVITY';
  END IF;
  UPDATE roomscan.auth_session_families AS family
  SET last_used_at = last_used_at_time,
      inactivity_expires_at = inactivity_expires_at_time
  WHERE family.id = target_family_id
    AND family.state = 'active'
    AND last_used_at_time >= family.last_used_at
    AND inactivity_expires_at_time <= family.absolute_expires_at;
  RETURN FOUND;
END
$function$;

CREATE FUNCTION roomscan.cancel_magic_delivery(
  requested_id text,
  requested_lease_id text,
  reason_code text,
  cancelled_at_time timestamptz
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  IF requested_id IS NULL OR requested_lease_id IS NULL
    OR reason_code IS NULL OR cancelled_at_time IS NULL
    OR length(requested_id) NOT BETWEEN 16 AND 128
    OR length(requested_lease_id) NOT BETWEEN 1 AND 128
    OR reason_code NOT IN ('unknown_key', 'tampered_envelope') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_MAGIC_DELIVERY_CANCELLATION';
  END IF;
  UPDATE roomscan.magic_link_delivery_outbox AS delivery
  SET state = 'cancelled', lease_id = NULL, lease_expires_at = NULL,
      cancelled_at = cancelled_at_time, cancellation_reason = reason_code
  WHERE delivery.id = requested_id
    AND delivery.state = 'leased'
    AND delivery.lease_id = requested_lease_id
    AND delivery.lease_expires_at > cancelled_at_time;
  RETURN FOUND;
END
$function$;

CREATE FUNCTION roomscan.release_magic_delivery(
  requested_id text,
  requested_lease_id text,
  released_at_time timestamptz
)
RETURNS text
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  result_state text;
BEGIN
  IF requested_id IS NULL OR requested_lease_id IS NULL OR released_at_time IS NULL
    OR length(requested_id) NOT BETWEEN 16 AND 128
    OR length(requested_lease_id) NOT BETWEEN 1 AND 128 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_MAGIC_DELIVERY_RELEASE';
  END IF;

  UPDATE roomscan.magic_link_delivery_outbox AS delivery
  SET state = CASE WHEN delivery.expires_at <= released_at_time THEN 'expired' ELSE 'pending' END,
      lease_id = NULL,
      lease_expires_at = NULL,
      cancelled_at = CASE WHEN delivery.expires_at <= released_at_time THEN released_at_time ELSE NULL END,
      cancellation_reason = CASE WHEN delivery.expires_at <= released_at_time THEN 'expired' ELSE NULL END
  WHERE delivery.id = requested_id
    AND delivery.state = 'leased'
    AND delivery.lease_id = requested_lease_id
    AND (
      delivery.expires_at <= released_at_time
      OR delivery.lease_expires_at > released_at_time
    )
  RETURNING delivery.state INTO result_state;

  RETURN CASE
    WHEN result_state = 'pending' THEN 'released'
    WHEN result_state = 'expired' THEN 'expired'
    ELSE 'unavailable'
  END;
END
$function$;

CREATE FUNCTION roomscan.claim_security_notification(
  requested_id text,
  requested_lease_id text,
  claimed_at_time timestamptz,
  requested_lease_expires_at timestamptz
)
RETURNS SETOF roomscan.security_notification_outbox
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  IF requested_id IS NULL OR requested_lease_id IS NULL
    OR claimed_at_time IS NULL OR requested_lease_expires_at IS NULL
    OR length(requested_id) NOT BETWEEN 16 AND 128
    OR length(requested_lease_id) NOT BETWEEN 1 AND 128
    OR requested_lease_expires_at <= claimed_at_time THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_SECURITY_NOTIFICATION_LEASE';
  END IF;
  RETURN QUERY
  UPDATE roomscan.security_notification_outbox AS notification
  SET state = 'leased',
      lease_id = requested_lease_id,
      lease_expires_at = requested_lease_expires_at,
      delivery_attempts = notification.delivery_attempts + 1
  WHERE notification.id = requested_id
    AND (
      notification.state = 'pending'
      OR (
        notification.state = 'leased'
        AND notification.lease_expires_at <= claimed_at_time
      )
    )
  RETURNING notification.*;
END
$function$;

CREATE FUNCTION roomscan.complete_security_notification(
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
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_SECURITY_NOTIFICATION_COMPLETION';
  END IF;
  UPDATE roomscan.security_notification_outbox AS notification
  SET state = 'delivered', lease_id = NULL, lease_expires_at = NULL,
      delivered_at = delivered_at_time
  WHERE notification.id = requested_id
    AND notification.state = 'leased'
    AND notification.lease_id = requested_lease_id
    AND notification.lease_expires_at > delivered_at_time;
  RETURN FOUND;
END
$function$;

CREATE FUNCTION roomscan.release_security_notification(
  requested_id text,
  requested_lease_id text
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  IF requested_id IS NULL OR requested_lease_id IS NULL
    OR length(requested_id) NOT BETWEEN 16 AND 128
    OR length(requested_lease_id) NOT BETWEEN 1 AND 128 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_SECURITY_NOTIFICATION_RELEASE';
  END IF;
  UPDATE roomscan.security_notification_outbox AS notification
  SET state = 'pending', lease_id = NULL, lease_expires_at = NULL
  WHERE notification.id = requested_id
    AND notification.state = 'leased'
    AND notification.lease_id = requested_lease_id;
  RETURN FOUND;
END
$function$;

RESET ROLE;

ALTER FUNCTION roomscan.claim_external_identity(text, text, uuid, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.release_external_identity(text, text, uuid) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.bump_principal_authentication_epoch(uuid) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.revoke_principal_session_families(uuid, uuid, timestamptz, text) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.revoke_access_token(bytea, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.update_session_family_activity(uuid, timestamptz, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.cancel_magic_delivery(text, text, text, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.release_magic_delivery(text, text, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.claim_security_notification(text, text, timestamptz, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.complete_security_notification(text, text, timestamptz) OWNER TO roomscan_policy;
ALTER FUNCTION roomscan.release_security_notification(text, text) OWNER TO roomscan_policy;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA roomscan FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  roomscan.claim_external_identity(text, text, uuid, timestamptz),
  roomscan.release_external_identity(text, text, uuid),
  roomscan.bump_principal_authentication_epoch(uuid),
  roomscan.revoke_principal_session_families(uuid, uuid, timestamptz, text),
  roomscan.revoke_access_token(bytea, timestamptz),
  roomscan.update_session_family_activity(uuid, timestamptz, timestamptz),
  roomscan.cancel_magic_delivery(text, text, text, timestamptz),
  roomscan.release_magic_delivery(text, text, timestamptz),
  roomscan.claim_security_notification(text, text, timestamptz, timestamptz),
  roomscan.complete_security_notification(text, text, timestamptz),
  roomscan.release_security_notification(text, text)
TO roomscan_app;

GRANT SELECT, INSERT, DELETE ON roomscan.external_identities TO roomscan_policy;
GRANT SELECT, UPDATE ON roomscan.principals, roomscan.auth_access_tokens,
  roomscan.auth_session_families, roomscan.magic_link_delivery_outbox,
  roomscan.security_notification_outbox TO roomscan_policy;

COMMENT ON FUNCTION roomscan.claim_external_identity(text, text, uuid, timestamptz) IS
  'Reviewed SECURITY DEFINER identity transition: serialized unique issuer/subject ownership for an active canonical principal; fixed search_path; PUBLIC execute revoked.';
COMMENT ON FUNCTION roomscan.release_external_identity(text, text, uuid) IS
  'Reviewed SECURITY DEFINER identity transition: serialized exact-owner unlink with storage-enforced final-auth-method protection; fixed search_path; PUBLIC execute revoked.';
COMMENT ON FUNCTION roomscan.bump_principal_authentication_epoch(uuid) IS
  'Reviewed SECURITY DEFINER session transition: increments one active canonical principal authentication epoch; fixed search_path; PUBLIC execute revoked.';
COMMENT ON FUNCTION roomscan.revoke_principal_session_families(uuid, uuid, timestamptz, text) IS
  'Reviewed SECURITY DEFINER session transition: revokes active families for one principal; optional except-family UUID is the only nullable argument; fixed search_path; PUBLIC execute revoked.';
COMMENT ON FUNCTION roomscan.revoke_access_token(bytea, timestamptz) IS
  'Reviewed SECURITY DEFINER session transition: revokes one active access-token digest; fixed search_path; PUBLIC execute revoked.';
COMMENT ON FUNCTION roomscan.update_session_family_activity(uuid, timestamptz, timestamptz) IS
  'Reviewed SECURITY DEFINER session transition: monotonic bounded activity and inactivity expiry update for one active family; fixed search_path; PUBLIC execute revoked.';
COMMENT ON FUNCTION roomscan.cancel_magic_delivery(text, text, text, timestamptz) IS
  'Reviewed SECURITY DEFINER outbox transition: current-lease bounded magic delivery cancellation; fixed search_path; PUBLIC execute revoked.';
COMMENT ON FUNCTION roomscan.release_magic_delivery(text, text, timestamptz) IS
  'Reviewed SECURITY DEFINER outbox transition: current-lease magic delivery release or authoritative link expiry; fixed search_path; PUBLIC execute revoked.';
COMMENT ON FUNCTION roomscan.claim_security_notification(text, text, timestamptz, timestamptz) IS
  'Reviewed SECURITY DEFINER outbox transition: one-winner pending or expired-lease notification claim; fixed search_path; PUBLIC execute revoked.';
COMMENT ON FUNCTION roomscan.complete_security_notification(text, text, timestamptz) IS
  'Reviewed SECURITY DEFINER outbox transition: unexpired current-lease notification completion; fixed search_path; PUBLIC execute revoked.';
COMMENT ON FUNCTION roomscan.release_security_notification(text, text) IS
  'Reviewed SECURITY DEFINER outbox transition: exact current-lease notification release; fixed search_path; PUBLIC execute revoked.';

RESET ROLE;

SET ROLE roomscan_owner;

CREATE FUNCTION roomscan.lock_magic_policy_scope(
  scope_kind text,
  subject_hash bytea
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  IF scope_kind IS NULL OR subject_hash IS NULL
    OR scope_kind NOT IN ('network-request', 'address-delivery', 'active-identity')
    OR octet_length(subject_hash) <> 32 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_MAGIC_POLICY_SCOPE';
  END IF;
  PERFORM pg_advisory_xact_lock(
    hashtextextended(scope_kind || ':' || encode(subject_hash, 'hex'), 7621846213719042)
  );
  RETURN true;
END
$function$;

RESET ROLE;
REVOKE ALL ON FUNCTION roomscan.lock_magic_policy_scope(text, bytea) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION roomscan.lock_magic_policy_scope(text, bytea) TO roomscan_app;
COMMENT ON FUNCTION roomscan.lock_magic_policy_scope(text, bytea) IS
  'Bounded SECURITY INVOKER transaction coordination capability: hash-only magic-link network, address, or active-identity scope; fixed search_path; caller must hold the surrounding issuance transaction.';
