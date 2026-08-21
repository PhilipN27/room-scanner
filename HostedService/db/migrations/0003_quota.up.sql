SET ROLE roomscan_owner;

CREATE TYPE roomscan.quota_metric AS ENUM (
  'project_count',
  'member_count',
  'working_bytes',
  'raw_bytes',
  'portal_bytes'
);

CREATE TYPE roomscan.quota_reservation_state AS ENUM (
  'reserved',
  'finalized',
  'released'
);

CREATE TABLE roomscan.quota_policy_versions (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE CASCADE,
  version bigint NOT NULL CHECK (version > 0),
  project_limit bigint NOT NULL CHECK (project_limit >= 0),
  member_limit bigint NOT NULL CHECK (member_limit >= 0),
  working_byte_limit bigint NOT NULL CHECK (working_byte_limit >= 0),
  raw_byte_limit bigint NOT NULL CHECK (raw_byte_limit >= 0),
  portal_byte_limit bigint NOT NULL CHECK (portal_byte_limit >= 0),
  warning_threshold_percent smallint NOT NULL CHECK (warning_threshold_percent BETWEEN 1 AND 100),
  is_active boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (workspace_id, version)
);

CREATE UNIQUE INDEX quota_policy_one_active_per_workspace
ON roomscan.quota_policy_versions (workspace_id)
WHERE is_active;

CREATE TABLE roomscan.quota_usage (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE CASCADE,
  metric roomscan.quota_metric NOT NULL,
  policy_version bigint NOT NULL,
  used bigint NOT NULL DEFAULT 0 CHECK (used >= 0),
  reserved bigint NOT NULL DEFAULT 0 CHECK (reserved >= 0),
  limit_value bigint NOT NULL CHECK (limit_value >= 0),
  warning_threshold_percent smallint NOT NULL CHECK (warning_threshold_percent BETWEEN 1 AND 100),
  warning_state boolean GENERATED ALWAYS AS (
    limit_value = 0
    OR ((used + reserved)::numeric * 100) >= (limit_value::numeric * warning_threshold_percent)
  ) STORED,
  over_limit boolean GENERATED ALWAYS AS (used + reserved > limit_value) STORED,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (workspace_id, metric),
  FOREIGN KEY (workspace_id, policy_version)
    REFERENCES roomscan.quota_policy_versions(workspace_id, version)
);

CREATE TABLE roomscan.quota_reservations (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE CASCADE,
  idempotency_key text NOT NULL CHECK (length(idempotency_key) BETWEEN 1 AND 200),
  metric roomscan.quota_metric NOT NULL,
  requested_amount bigint NOT NULL CHECK (requested_amount > 0),
  finalized_amount bigint CHECK (finalized_amount >= 0),
  state roomscan.quota_reservation_state NOT NULL DEFAULT 'reserved',
  policy_version bigint NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  finalized_at timestamptz,
  released_at timestamptz,
  PRIMARY KEY (workspace_id, idempotency_key),
  FOREIGN KEY (workspace_id, policy_version)
    REFERENCES roomscan.quota_policy_versions(workspace_id, version),
  CHECK (
    (state = 'reserved' AND finalized_amount IS NULL AND finalized_at IS NULL AND released_at IS NULL)
    OR (state = 'finalized' AND finalized_amount IS NOT NULL AND finalized_at IS NOT NULL AND released_at IS NULL)
    OR (state = 'released' AND finalized_amount IS NULL AND finalized_at IS NULL AND released_at IS NOT NULL)
  )
);

CREATE TABLE roomscan.quota_ledger (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE CASCADE,
  idempotency_key text NOT NULL,
  action text NOT NULL CHECK (action IN ('reserve', 'finalize', 'release')),
  metric roomscan.quota_metric NOT NULL,
  delta_used bigint NOT NULL,
  delta_reserved bigint NOT NULL,
  policy_version bigint NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (workspace_id, idempotency_key, action),
  FOREIGN KEY (workspace_id, idempotency_key)
    REFERENCES roomscan.quota_reservations(workspace_id, idempotency_key),
  FOREIGN KEY (workspace_id, policy_version)
    REFERENCES roomscan.quota_policy_versions(workspace_id, version),
  CHECK (delta_used <> 0 OR delta_reserved <> 0)
);

ALTER TABLE roomscan.quota_policy_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.quota_policy_versions FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.quota_usage ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.quota_usage FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.quota_reservations ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.quota_reservations FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.quota_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.quota_ledger FORCE ROW LEVEL SECURITY;

CREATE POLICY quota_policy_versions_tenant_isolation ON roomscan.quota_policy_versions
FOR ALL TO PUBLIC
USING (roomscan.has_authorized_tenant(workspace_id))
WITH CHECK (roomscan.has_authorized_tenant(workspace_id));

CREATE POLICY quota_usage_tenant_isolation ON roomscan.quota_usage
FOR ALL TO PUBLIC
USING (roomscan.has_authorized_tenant(workspace_id))
WITH CHECK (roomscan.has_authorized_tenant(workspace_id));

CREATE POLICY quota_reservations_tenant_isolation ON roomscan.quota_reservations
FOR ALL TO PUBLIC
USING (roomscan.has_authorized_tenant(workspace_id))
WITH CHECK (roomscan.has_authorized_tenant(workspace_id));

CREATE POLICY quota_ledger_tenant_isolation ON roomscan.quota_ledger
FOR ALL TO PUBLIC
USING (roomscan.has_authorized_tenant(workspace_id))
WITH CHECK (roomscan.has_authorized_tenant(workspace_id));

CREATE FUNCTION roomscan.activate_quota_policy(
  new_version bigint,
  new_project_limit bigint,
  new_member_limit bigint,
  new_working_byte_limit bigint,
  new_raw_byte_limit bigint,
  new_portal_byte_limit bigint,
  new_warning_threshold_percent integer
)
RETURNS bigint
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  tenant_id uuid := roomscan.request_tenant_id();
  current_version bigint;
BEGIN
  IF NOT roomscan.has_authorized_tenant(tenant_id) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHORIZED_TENANT_CONTEXT_REQUIRED';
  END IF;
  IF new_version IS NULL
    OR new_project_limit IS NULL
    OR new_member_limit IS NULL
    OR new_working_byte_limit IS NULL
    OR new_raw_byte_limit IS NULL
    OR new_portal_byte_limit IS NULL
    OR new_warning_threshold_percent IS NULL
    OR new_version < 1
    OR new_project_limit < 0
    OR new_member_limit < 0
    OR new_working_byte_limit < 0
    OR new_raw_byte_limit < 0
    OR new_portal_byte_limit < 0
    OR new_warning_threshold_percent NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_QUOTA_POLICY';
  END IF;

  SELECT max(version)
  INTO current_version
  FROM roomscan.quota_policy_versions
  WHERE workspace_id = tenant_id;

  IF current_version IS NOT NULL AND new_version <= current_version THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'QUOTA_POLICY_VERSION_NOT_FORWARD';
  END IF;

  UPDATE roomscan.quota_policy_versions
  SET is_active = false
  WHERE workspace_id = tenant_id
    AND is_active;

  INSERT INTO roomscan.quota_policy_versions (
    workspace_id,
    version,
    project_limit,
    member_limit,
    working_byte_limit,
    raw_byte_limit,
    portal_byte_limit,
    warning_threshold_percent,
    is_active
  ) VALUES (
    tenant_id,
    new_version,
    new_project_limit,
    new_member_limit,
    new_working_byte_limit,
    new_raw_byte_limit,
    new_portal_byte_limit,
    new_warning_threshold_percent,
    true
  );

  INSERT INTO roomscan.quota_usage (
    workspace_id,
    metric,
    policy_version,
    limit_value,
    warning_threshold_percent
  ) VALUES
    (tenant_id, 'project_count', new_version, new_project_limit, new_warning_threshold_percent),
    (tenant_id, 'member_count', new_version, new_member_limit, new_warning_threshold_percent),
    (tenant_id, 'working_bytes', new_version, new_working_byte_limit, new_warning_threshold_percent),
    (tenant_id, 'raw_bytes', new_version, new_raw_byte_limit, new_warning_threshold_percent),
    (tenant_id, 'portal_bytes', new_version, new_portal_byte_limit, new_warning_threshold_percent)
  ON CONFLICT (workspace_id, metric) DO UPDATE
  SET policy_version = EXCLUDED.policy_version,
      limit_value = EXCLUDED.limit_value,
      warning_threshold_percent = EXCLUDED.warning_threshold_percent,
      updated_at = clock_timestamp();

  RETURN new_version;
END
$function$;

CREATE FUNCTION roomscan.reserve_quota(
  requested_metric roomscan.quota_metric,
  amount_to_reserve bigint,
  request_key text
)
RETURNS TABLE (
  reservation_state text,
  reservation_amount bigint,
  finalized_amount bigint
)
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  tenant_id uuid := roomscan.request_tenant_id();
  existing_reservation roomscan.quota_reservations%ROWTYPE;
  active_policy_version bigint;
BEGIN
  IF NOT roomscan.has_authorized_tenant(tenant_id) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHORIZED_TENANT_CONTEXT_REQUIRED';
  END IF;
  IF requested_metric IS NULL
    OR amount_to_reserve IS NULL
    OR request_key IS NULL
    OR amount_to_reserve <= 0
    OR length(request_key) NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_QUOTA_RESERVATION';
  END IF;

  SELECT reservation.*
  INTO existing_reservation
  FROM roomscan.quota_reservations AS reservation
  WHERE reservation.workspace_id = tenant_id
    AND reservation.idempotency_key = request_key
  FOR UPDATE;

  IF FOUND THEN
    IF existing_reservation.metric IS DISTINCT FROM requested_metric
      OR existing_reservation.requested_amount IS DISTINCT FROM amount_to_reserve THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'IDEMPOTENCY_KEY_REUSED';
    END IF;
    RETURN QUERY SELECT
      existing_reservation.state::text,
      existing_reservation.requested_amount,
      existing_reservation.finalized_amount;
    RETURN;
  END IF;

  SELECT usage.policy_version
  INTO active_policy_version
  FROM roomscan.quota_usage AS usage
  WHERE usage.workspace_id = tenant_id
    AND usage.metric = requested_metric
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'QUOTA_POLICY_MISSING';
  END IF;

  INSERT INTO roomscan.quota_reservations (
    workspace_id,
    idempotency_key,
    metric,
    requested_amount,
    policy_version
  ) VALUES (
    tenant_id,
    request_key,
    requested_metric,
    amount_to_reserve,
    active_policy_version
  )
  ON CONFLICT (workspace_id, idempotency_key) DO NOTHING
  RETURNING * INTO existing_reservation;

  IF NOT FOUND THEN
    SELECT reservation.*
    INTO existing_reservation
    FROM roomscan.quota_reservations AS reservation
    WHERE reservation.workspace_id = tenant_id
      AND reservation.idempotency_key = request_key
    FOR UPDATE;
    IF existing_reservation.metric IS DISTINCT FROM requested_metric
      OR existing_reservation.requested_amount IS DISTINCT FROM amount_to_reserve THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'IDEMPOTENCY_KEY_REUSED';
    END IF;
    RETURN QUERY SELECT
      existing_reservation.state::text,
      existing_reservation.requested_amount,
      existing_reservation.finalized_amount;
    RETURN;
  END IF;

  UPDATE roomscan.quota_usage AS usage
  SET reserved = usage.reserved + amount_to_reserve,
      updated_at = clock_timestamp()
  WHERE usage.workspace_id = tenant_id
    AND usage.metric = requested_metric
    AND usage.used + usage.reserved + amount_to_reserve <= usage.limit_value;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'QUOTA_EXCEEDED';
  END IF;

  INSERT INTO roomscan.quota_ledger (
    workspace_id,
    idempotency_key,
    action,
    metric,
    delta_used,
    delta_reserved,
    policy_version
  ) VALUES (
    tenant_id,
    request_key,
    'reserve',
    requested_metric,
    0,
    amount_to_reserve,
    active_policy_version
  );

  RETURN QUERY SELECT 'reserved'::text, amount_to_reserve, NULL::bigint;
END
$function$;

CREATE FUNCTION roomscan.finalize_quota(
  request_key text,
  amount_actually_used bigint
)
RETURNS TABLE (
  reservation_state text,
  reservation_amount bigint,
  finalized_amount bigint
)
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  tenant_id uuid := roomscan.request_tenant_id();
  reservation roomscan.quota_reservations%ROWTYPE;
BEGIN
  IF NOT roomscan.has_authorized_tenant(tenant_id) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHORIZED_TENANT_CONTEXT_REQUIRED';
  END IF;
  IF request_key IS NULL
    OR amount_actually_used IS NULL
    OR length(request_key) NOT BETWEEN 1 AND 200
    OR amount_actually_used < 0 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_QUOTA_FINALIZATION';
  END IF;

  SELECT existing.*
  INTO reservation
  FROM roomscan.quota_reservations AS existing
  WHERE existing.workspace_id = tenant_id
    AND existing.idempotency_key = request_key
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'QUOTA_RESERVATION_NOT_FOUND';
  END IF;
  IF reservation.state = 'finalized' THEN
    IF reservation.finalized_amount IS DISTINCT FROM amount_actually_used THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'IDEMPOTENCY_KEY_REUSED';
    END IF;
    RETURN QUERY SELECT reservation.state::text, reservation.requested_amount, reservation.finalized_amount;
    RETURN;
  END IF;
  IF reservation.state = 'released' THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'QUOTA_RESERVATION_RELEASED';
  END IF;
  IF amount_actually_used > reservation.requested_amount THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_QUOTA_FINALIZATION';
  END IF;

  UPDATE roomscan.quota_usage AS usage
  SET used = usage.used + amount_actually_used,
      reserved = usage.reserved - reservation.requested_amount,
      updated_at = clock_timestamp()
  WHERE usage.workspace_id = tenant_id
    AND usage.metric = reservation.metric;

  UPDATE roomscan.quota_reservations
  SET state = 'finalized',
      finalized_amount = amount_actually_used,
      finalized_at = clock_timestamp()
  WHERE workspace_id = tenant_id
    AND idempotency_key = request_key;

  INSERT INTO roomscan.quota_ledger (
    workspace_id,
    idempotency_key,
    action,
    metric,
    delta_used,
    delta_reserved,
    policy_version
  ) VALUES (
    tenant_id,
    request_key,
    'finalize',
    reservation.metric,
    amount_actually_used,
    -reservation.requested_amount,
    reservation.policy_version
  );

  RETURN QUERY SELECT 'finalized'::text, reservation.requested_amount, amount_actually_used;
END
$function$;

CREATE FUNCTION roomscan.release_quota(request_key text)
RETURNS TABLE (
  reservation_state text,
  reservation_amount bigint,
  finalized_amount bigint
)
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  tenant_id uuid := roomscan.request_tenant_id();
  reservation roomscan.quota_reservations%ROWTYPE;
BEGIN
  IF NOT roomscan.has_authorized_tenant(tenant_id) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHORIZED_TENANT_CONTEXT_REQUIRED';
  END IF;
  IF request_key IS NULL OR length(request_key) NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_QUOTA_RELEASE';
  END IF;

  SELECT existing.*
  INTO reservation
  FROM roomscan.quota_reservations AS existing
  WHERE existing.workspace_id = tenant_id
    AND existing.idempotency_key = request_key
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'QUOTA_RESERVATION_NOT_FOUND';
  END IF;
  IF reservation.state = 'released' THEN
    RETURN QUERY SELECT reservation.state::text, reservation.requested_amount, reservation.finalized_amount;
    RETURN;
  END IF;
  IF reservation.state = 'finalized' THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'QUOTA_RESERVATION_FINALIZED';
  END IF;

  UPDATE roomscan.quota_usage AS usage
  SET reserved = usage.reserved - reservation.requested_amount,
      updated_at = clock_timestamp()
  WHERE usage.workspace_id = tenant_id
    AND usage.metric = reservation.metric;

  UPDATE roomscan.quota_reservations
  SET state = 'released',
      released_at = clock_timestamp()
  WHERE workspace_id = tenant_id
    AND idempotency_key = request_key;

  INSERT INTO roomscan.quota_ledger (
    workspace_id,
    idempotency_key,
    action,
    metric,
    delta_used,
    delta_reserved,
    policy_version
  ) VALUES (
    tenant_id,
    request_key,
    'release',
    reservation.metric,
    0,
    -reservation.requested_amount,
    reservation.policy_version
  );

  RETURN QUERY SELECT 'released'::text, reservation.requested_amount, NULL::bigint;
END
$function$;

REVOKE ALL ON ALL TABLES IN SCHEMA roomscan FROM PUBLIC;
REVOKE ALL ON FUNCTION roomscan.activate_quota_policy(bigint, bigint, bigint, bigint, bigint, bigint, integer)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION roomscan.reserve_quota(roomscan.quota_metric, bigint, text)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION roomscan.finalize_quota(text, bigint)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION roomscan.release_quota(text)
  FROM PUBLIC;

GRANT SELECT, INSERT, UPDATE, DELETE ON roomscan.quota_policy_versions TO roomscan_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON roomscan.quota_usage TO roomscan_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON roomscan.quota_reservations TO roomscan_app;
GRANT SELECT, INSERT ON roomscan.quota_ledger TO roomscan_app;

GRANT EXECUTE ON FUNCTION roomscan.activate_quota_policy(bigint, bigint, bigint, bigint, bigint, bigint, integer)
  TO roomscan_app;
GRANT EXECUTE ON FUNCTION roomscan.reserve_quota(roomscan.quota_metric, bigint, text)
  TO roomscan_app;
GRANT EXECUTE ON FUNCTION roomscan.finalize_quota(text, bigint)
  TO roomscan_app;
GRANT EXECUTE ON FUNCTION roomscan.release_quota(text)
  TO roomscan_app;

RESET ROLE;
