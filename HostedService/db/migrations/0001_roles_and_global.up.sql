-- Reserved roles are deliberately created without IF NOT EXISTS.  A first
-- migration against a catalog that already contains any one of these names
-- must fail closed rather than silently adopting a possibly attacker-owned
-- role or pre-existing membership edge.
CREATE ROLE roomscan_owner
  NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
CREATE ROLE roomscan_policy
  NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION BYPASSRLS;
CREATE ROLE roomscan_app
  LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;

ALTER ROLE roomscan_owner
  NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
ALTER ROLE roomscan_policy
  NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION BYPASSRLS;
ALTER ROLE roomscan_app
  LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;

REVOKE roomscan_owner FROM roomscan_app;
REVOKE roomscan_policy FROM roomscan_app;
REVOKE roomscan_owner FROM roomscan_policy;

CREATE SCHEMA roomscan AUTHORIZATION roomscan_owner;
REVOKE ALL ON SCHEMA roomscan FROM PUBLIC;
GRANT USAGE ON SCHEMA roomscan TO roomscan_app, roomscan_policy;

SET ROLE roomscan_owner;

CREATE TABLE roomscan.principals (
  id uuid PRIMARY KEY,
  normalized_email text UNIQUE,
  state text NOT NULL DEFAULT 'active' CHECK (state IN ('active', 'disabled', 'deleted')),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE roomscan.external_identities (
  id uuid PRIMARY KEY,
  principal_id uuid NOT NULL REFERENCES roomscan.principals(id) ON DELETE CASCADE,
  provider text NOT NULL CHECK (length(provider) BETWEEN 1 AND 64),
  provider_subject text NOT NULL CHECK (length(provider_subject) BETWEEN 1 AND 512),
  verified_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (provider, provider_subject)
);

CREATE TABLE roomscan.auth_session_families (
  id uuid PRIMARY KEY,
  principal_id uuid NOT NULL REFERENCES roomscan.principals(id) ON DELETE CASCADE,
  revoked_at timestamptz,
  revoke_reason text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE roomscan.auth_sessions (
  id uuid PRIMARY KEY,
  family_id uuid NOT NULL REFERENCES roomscan.auth_session_families(id) ON DELETE CASCADE,
  token_hash bytea NOT NULL UNIQUE CHECK (octet_length(token_hash) = 32),
  expires_at timestamptz NOT NULL,
  used_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE roomscan.auth_attempts (
  id uuid PRIMARY KEY,
  principal_id uuid REFERENCES roomscan.principals(id) ON DELETE SET NULL,
  purpose text NOT NULL CHECK (length(purpose) BETWEEN 1 AND 64),
  outcome text NOT NULL CHECK (outcome IN ('pending', 'accepted', 'rejected', 'expired')),
  attempted_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE roomscan.provider_receipts (
  provider text NOT NULL CHECK (length(provider) BETWEEN 1 AND 64),
  receipt_id text NOT NULL CHECK (length(receipt_id) BETWEEN 1 AND 512),
  payload_sha256 bytea NOT NULL CHECK (octet_length(payload_sha256) = 32),
  received_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (provider, receipt_id)
);

REVOKE ALL ON ALL TABLES IN SCHEMA roomscan FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE ON roomscan.principals TO roomscan_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON roomscan.external_identities TO roomscan_app;
GRANT SELECT, INSERT, UPDATE ON roomscan.auth_session_families TO roomscan_app;
GRANT SELECT, INSERT, UPDATE ON roomscan.auth_sessions TO roomscan_app;
GRANT SELECT, INSERT ON roomscan.auth_attempts TO roomscan_app;
GRANT SELECT, INSERT ON roomscan.provider_receipts TO roomscan_app;

RESET ROLE;

ALTER DEFAULT PRIVILEGES FOR ROLE roomscan_owner IN SCHEMA roomscan
  REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE roomscan_owner IN SCHEMA roomscan
  REVOKE ALL ON FUNCTIONS FROM PUBLIC;
