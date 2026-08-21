import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const tenantCore = await readFile(new URL('../migrations/0002_tenant_core.up.sql', import.meta.url), 'utf8');
const quota = await readFile(new URL('../migrations/0003_quota.up.sql', import.meta.url), 'utf8');
const stripe = await readFile(new URL('../migrations/0004_stripe.up.sql', import.meta.url), 'utf8');
const hardened = await readFile(new URL('../migrations/0005_hardened_reducers.up.sql', import.meta.url), 'utf8');

const requiredNullContracts = [
  [tenantCore, 'candidate_workspace_id IS NULL'],
  [tenantCore, 'invitation_token_hash IS NULL'],
  [hardened, 'requested_slug IS NULL'],
  [hardened, 'requested_display_name IS NULL'],
  [hardened, 'invitation_token_hash IS NULL'],
  [quota, 'new_version IS NULL'],
  [quota, 'new_project_limit IS NULL'],
  [quota, 'new_member_limit IS NULL'],
  [quota, 'new_working_byte_limit IS NULL'],
  [quota, 'new_raw_byte_limit IS NULL'],
  [quota, 'new_portal_byte_limit IS NULL'],
  [quota, 'new_warning_threshold_percent IS NULL'],
  [quota, 'requested_metric IS NULL'],
  [quota, 'amount_to_reserve IS NULL'],
  [quota, 'request_key IS NULL'],
  [quota, 'amount_actually_used IS NULL'],
  [quota, 'request_key IS NULL'],
  [stripe, 'stripe_account_id IS NULL'],
  [stripe, 'stripe_event_id IS NULL'],
  [stripe, 'event_payload_sha256 IS NULL'],
  [stripe, 'signature_is_verified IS DISTINCT FROM true'],
  [stripe, 'event_occurred_at IS NULL'],
  [stripe, 'new_generation IS NULL'],
  [stripe, 'authoritative_observed_at IS NULL'],
  [stripe, 'authoritative_status IS NULL'],
  [stripe, 'authoritative_plan_key IS NULL'],
];

for (const [source, contract] of requiredNullContracts) {
  assert.ok(source.includes(contract), `missing required-argument fail-closed contract: ${contract}`);
}
assert.equal(
  quota.split('request_key IS NULL').length - 1,
  3,
  'reserve, finalize, and release must each reject a NULL request key',
);
assert.match(stripe, /authoritative_period_end is optional; NULL is a valid exact snapshot value/u);

const exactRetryComparisons = [
  [quota, 'existing_reservation.metric IS DISTINCT FROM requested_metric', 2],
  [quota, 'existing_reservation.requested_amount IS DISTINCT FROM amount_to_reserve', 2],
  [quota, 'reservation.finalized_amount IS DISTINCT FROM amount_actually_used', 1],
  [stripe, 'existing.workspace_id IS DISTINCT FROM tenant_id', 1],
  [stripe, 'existing.payload_sha256 IS DISTINCT FROM event_payload_sha256', 1],
  [stripe, 'existing.provider_occurred_at IS DISTINCT FROM event_occurred_at', 1],
  [stripe, 'existing.source_observed_at IS DISTINCT FROM authoritative_observed_at', 1],
  [stripe, 'existing.subscription_status IS DISTINCT FROM authoritative_status', 1],
  [stripe, 'existing.plan_key IS DISTINCT FROM authoritative_plan_key', 1],
  [stripe, 'existing.current_period_end IS DISTINCT FROM authoritative_period_end', 1],
];

let retryComparisonCount = 0;
for (const [source, comparison, expectedCount] of exactRetryComparisons) {
  const count = source.split(comparison).length - 1;
  assert.equal(count, expectedCount, `wrong NULL-safe retry comparison count: ${comparison}`);
  retryComparisonCount += count;
}

const forbiddenOrdinaryRetryComparisons = [
  /existing_reservation\.metric\s*<>/u,
  /existing_reservation\.requested_amount\s*<>/u,
  /reservation\.finalized_amount\s*<>/u,
  /existing\.(?:workspace_id|payload_sha256|provider_occurred_at|source_observed_at|subscription_status|plan_key|current_period_end)\s*<>/u,
];
for (const pattern of forbiddenOrdinaryRetryComparisons) {
  assert.doesNotMatch(`${quota}\n${stripe}`, pattern);
}

console.log(`REDUCER_SQL_CONTRACT_SUMMARY required_arguments=26 optional_arguments=1 null_safe_retry_comparisons=${retryComparisonCount} ordinary_nullable_retry_comparisons=0 status=pass`);
