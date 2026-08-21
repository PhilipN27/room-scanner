SET ROLE roomscan_owner;

CREATE TABLE roomscan.stripe_event_receipts (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE CASCADE,
  provider_account_id text NOT NULL CHECK (length(provider_account_id) BETWEEN 1 AND 255),
  event_id text NOT NULL CHECK (length(event_id) BETWEEN 1 AND 255),
  payload_sha256 bytea NOT NULL CHECK (octet_length(payload_sha256) = 32),
  signature_verified boolean NOT NULL CHECK (signature_verified),
  provider_occurred_at timestamptz NOT NULL,
  received_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (provider_account_id, event_id)
);

CREATE TABLE roomscan.stripe_reconciliation_generations (
  workspace_id uuid NOT NULL REFERENCES roomscan.workspaces(id) ON DELETE CASCADE,
  generation bigint NOT NULL CHECK (generation > 0),
  source_observed_at timestamptz NOT NULL,
  subscription_status text NOT NULL CHECK (
    subscription_status IN ('inactive', 'trialing', 'active', 'past_due', 'canceled', 'read_only_grace')
  ),
  plan_key text NOT NULL CHECK (length(plan_key) BETWEEN 1 AND 128),
  current_period_end timestamptz,
  applied boolean NOT NULL DEFAULT false,
  recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (workspace_id, generation)
);

ALTER TABLE roomscan.stripe_event_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.stripe_event_receipts FORCE ROW LEVEL SECURITY;
ALTER TABLE roomscan.stripe_reconciliation_generations ENABLE ROW LEVEL SECURITY;
ALTER TABLE roomscan.stripe_reconciliation_generations FORCE ROW LEVEL SECURITY;

CREATE POLICY stripe_event_receipts_tenant_isolation ON roomscan.stripe_event_receipts
FOR ALL TO PUBLIC
USING (roomscan.has_authorized_tenant(workspace_id))
WITH CHECK (roomscan.has_authorized_tenant(workspace_id));

CREATE POLICY stripe_reconciliation_generations_tenant_isolation
ON roomscan.stripe_reconciliation_generations
FOR ALL TO PUBLIC
USING (roomscan.has_authorized_tenant(workspace_id))
WITH CHECK (roomscan.has_authorized_tenant(workspace_id));

CREATE FUNCTION roomscan.record_stripe_event(
  stripe_account_id text,
  stripe_event_id text,
  event_payload_sha256 bytea,
  signature_is_verified boolean,
  event_occurred_at timestamptz
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  tenant_id uuid := roomscan.request_tenant_id();
  inserted boolean;
  existing roomscan.stripe_event_receipts%ROWTYPE;
BEGIN
  IF NOT roomscan.has_authorized_tenant(tenant_id) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHORIZED_TENANT_CONTEXT_REQUIRED';
  END IF;
  IF stripe_account_id IS NULL
    OR stripe_event_id IS NULL
    OR event_payload_sha256 IS NULL
    OR event_occurred_at IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_STRIPE_RECEIPT';
  END IF;
  IF signature_is_verified IS DISTINCT FROM true THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'STRIPE_SIGNATURE_UNVERIFIED';
  END IF;
  IF octet_length(event_payload_sha256) <> 32
    OR length(stripe_account_id) NOT BETWEEN 1 AND 255
    OR length(stripe_event_id) NOT BETWEEN 1 AND 255 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_STRIPE_RECEIPT';
  END IF;

  INSERT INTO roomscan.stripe_event_receipts (
    workspace_id,
    provider_account_id,
    event_id,
    payload_sha256,
    signature_verified,
    provider_occurred_at
  ) VALUES (
    tenant_id,
    stripe_account_id,
    stripe_event_id,
    event_payload_sha256,
    true,
    event_occurred_at
  )
  ON CONFLICT (provider_account_id, event_id) DO NOTHING
  RETURNING true INTO inserted;

  IF inserted THEN
    RETURN true;
  END IF;

  SELECT receipt.*
  INTO existing
  FROM roomscan.stripe_event_receipts AS receipt
  WHERE receipt.provider_account_id = stripe_account_id
    AND receipt.event_id = stripe_event_id;

  IF NOT FOUND
    OR existing.workspace_id IS DISTINCT FROM tenant_id
    OR existing.payload_sha256 IS DISTINCT FROM event_payload_sha256
    OR existing.provider_occurred_at IS DISTINCT FROM event_occurred_at THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'STRIPE_EVENT_KEY_REUSED';
  END IF;

  RETURN false;
END
$function$;

CREATE FUNCTION roomscan.apply_stripe_reconciliation(
  new_generation bigint,
  authoritative_observed_at timestamptz,
  authoritative_status text,
  authoritative_plan_key text,
  authoritative_period_end timestamptz
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  tenant_id uuid := roomscan.request_tenant_id();
  existing roomscan.stripe_reconciliation_generations%ROWTYPE;
  was_applied boolean := false;
BEGIN
  IF NOT roomscan.has_authorized_tenant(tenant_id) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'AUTHORIZED_TENANT_CONTEXT_REQUIRED';
  END IF;
  -- authoritative_period_end is optional; NULL is a valid exact snapshot value
  -- for plans without a provider period end and is compared NULL-safely below.
  IF new_generation IS NULL
    OR authoritative_observed_at IS NULL
    OR authoritative_status IS NULL
    OR authoritative_plan_key IS NULL
    OR new_generation < 1
    OR authoritative_status NOT IN ('inactive', 'trialing', 'active', 'past_due', 'canceled', 'read_only_grace')
    OR length(authoritative_plan_key) NOT BETWEEN 1 AND 128 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'INVALID_STRIPE_RECONCILIATION';
  END IF;

  -- Serialize reconciliation generations per workspace so concurrent retries
  -- observe the durable row written by the winner instead of racing its PK.
  PERFORM 1
  FROM roomscan.workspaces
  WHERE id = tenant_id
  FOR UPDATE;

  SELECT reconciliation.*
  INTO existing
  FROM roomscan.stripe_reconciliation_generations AS reconciliation
  WHERE reconciliation.workspace_id = tenant_id
    AND reconciliation.generation = new_generation
  FOR UPDATE;

  IF FOUND THEN
    IF existing.source_observed_at IS DISTINCT FROM authoritative_observed_at
      OR existing.subscription_status IS DISTINCT FROM authoritative_status
      OR existing.plan_key IS DISTINCT FROM authoritative_plan_key
      OR existing.current_period_end IS DISTINCT FROM authoritative_period_end THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'RECONCILIATION_GENERATION_REUSED';
    END IF;
    RETURN existing.applied;
  END IF;

  INSERT INTO roomscan.stripe_reconciliation_generations (
    workspace_id,
    generation,
    source_observed_at,
    subscription_status,
    plan_key,
    current_period_end
  ) VALUES (
    tenant_id,
    new_generation,
    authoritative_observed_at,
    authoritative_status,
    authoritative_plan_key,
    authoritative_period_end
  );

  INSERT INTO roomscan.subscription_states (
    workspace_id,
    plan_key,
    status,
    current_period_end,
    reconciliation_generation,
    source_observed_at,
    updated_at
  ) VALUES (
    tenant_id,
    authoritative_plan_key,
    authoritative_status,
    authoritative_period_end,
    new_generation,
    authoritative_observed_at,
    clock_timestamp()
  )
  ON CONFLICT (workspace_id) DO UPDATE
  SET plan_key = EXCLUDED.plan_key,
      status = EXCLUDED.status,
      current_period_end = EXCLUDED.current_period_end,
      reconciliation_generation = EXCLUDED.reconciliation_generation,
      source_observed_at = EXCLUDED.source_observed_at,
      updated_at = clock_timestamp()
  WHERE roomscan.subscription_states.reconciliation_generation < EXCLUDED.reconciliation_generation
    AND (
      roomscan.subscription_states.source_observed_at IS NULL
      OR roomscan.subscription_states.source_observed_at <= EXCLUDED.source_observed_at
    )
  RETURNING true INTO was_applied;

  IF was_applied THEN
    UPDATE roomscan.stripe_reconciliation_generations
    SET applied = true
    WHERE workspace_id = tenant_id
      AND generation = new_generation;
  END IF;

  RETURN COALESCE(was_applied, false);
END
$function$;

REVOKE ALL ON ALL TABLES IN SCHEMA roomscan FROM PUBLIC;
REVOKE ALL ON FUNCTION roomscan.record_stripe_event(text, text, bytea, boolean, timestamptz)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION roomscan.apply_stripe_reconciliation(bigint, timestamptz, text, text, timestamptz)
  FROM PUBLIC;

GRANT SELECT, INSERT ON roomscan.stripe_event_receipts TO roomscan_app;
GRANT SELECT, INSERT ON roomscan.stripe_reconciliation_generations TO roomscan_app;
GRANT UPDATE (applied) ON roomscan.stripe_reconciliation_generations TO roomscan_app;

GRANT EXECUTE ON FUNCTION roomscan.record_stripe_event(text, text, bytea, boolean, timestamptz)
  TO roomscan_app;
GRANT EXECUTE ON FUNCTION roomscan.apply_stripe_reconciliation(bigint, timestamptz, text, text, timestamptz)
  TO roomscan_app;

RESET ROLE;
