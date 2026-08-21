import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const migrationPath = fileURLToPath(new URL(
  '../migrations/0007_policy_billing_integration.up.sql', import.meta.url,
));
const migrationSql = await readFile(migrationPath, 'utf8');

const mutationNames = [
  'accept_apple_verified_result_v2',
  'accept_invitation_v2',
  'accept_provider_audit_event',
  'accept_stripe_event_v2',
  'activate_quota_policy_v2',
  'append_workspace_audit_v2',
  'bind_stripe_account',
  'bootstrap_workspace_v2',
  'claim_provider_audit_event',
  'claim_stripe_reconciliation_v2',
  'complete_provider_audit_event',
  'complete_stripe_reconciliation_v2',
  'consume_apple_bridge_and_issue_session',
  'consume_magic_challenge_v2',
  'consume_magic_challenge_v3',
  'create_apple_attempt_v2',
  'create_invitation_v2',
  'finalize_quota_v2',
  'issue_magic_challenge_v2',
  'issue_magic_challenge_v3',
  'logout_all_from_access',
  'logout_from_access',
  'mark_workspace_audit_exported',
  'mint_candidate_identity_proof_v2',
  'mutate_identity_v2',
  'mutate_membership_v2',
  'reconcile_quota_v2',
  'redeem_magic_completion_v3',
  'release_provider_audit_event',
  'release_quota_v2',
  'release_stripe_reconciliation_v2',
  'reserve_quota_v2',
  'revoke_invitation_v2',
  'rotate_session_from_refresh',
  'scope_session_workspace_v2',
  'set_operational_flag',
  'set_workspace_publishing_policy',
  'touch_session_from_access',
].sort();

// These are the complete reviewed nullable inputs. Every other mutation input
// must have an explicit fail-closed IS NULL guard in the function body.
const optionalArguments = new Map([
  ['append_workspace_audit_v2', new Set(['requested_authorization_version'])],
  ['complete_stripe_reconciliation_v2', new Set(['requested_current_period_end'])],
  ['create_invitation_v2', new Set(['requested_invited_email'])],
  ['finalize_quota_v2', new Set(['publication_global_version', 'publication_workspace_version'])],
  ['release_quota_v2', new Set(['publication_global_version', 'publication_workspace_version'])],
  ['reserve_quota_v2', new Set(['publication_global_version', 'publication_workspace_version'])],
  ['set_operational_flag', new Set(['expected_version'])],
  ['set_workspace_publishing_policy', new Set(['expected_version'])],
]);

function parseMutationDefinitions(sql) {
  const definitions = new Map();
  const pattern = /CREATE FUNCTION roomscan\.([a-z0-9_]+)\(([\s\S]*?)\)\nRETURNS[\s\S]*?\nAS \$function\$\n([\s\S]*?)\n\$function\$;/gu;
  for (const match of sql.matchAll(pattern)) {
    const [, name, argumentsSql, body] = match;
    if (!mutationNames.includes(name)) continue;
    const argumentsList = argumentsSql.split('\n')
      .map((line) => line.trim().replace(/,$/u, ''))
      .filter(Boolean)
      .map((line) => {
        const argument = line.match(/^([a-z][a-z0-9_]*)\s+(.+)$/u);
        assert.ok(argument, `could not parse ${name} argument: ${line}`);
        return { name: argument[1], type: argument[2] };
      });
    assert.equal(definitions.has(name), false, `duplicate mutation definition: ${name}`);
    definitions.set(name, { argumentsList, body });
  }
  return definitions;
}

const definitions = parseMutationDefinitions(migrationSql);
assert.deepEqual([...definitions.keys()].sort(), mutationNames);
let requiredArgumentGuards = 0;
let optionalArgumentClassifications = 0;
for (const name of mutationNames) {
  const definition = definitions.get(name);
  const optional = optionalArguments.get(name) ?? new Set();
  for (const argument of definition.argumentsList) {
    if (optional.has(argument.name)) {
      optionalArgumentClassifications += 1;
      continue;
    }
    assert.match(
      definition.body,
      new RegExp(`\\b${argument.name}\\s+IS\\s+NULL\\b`, 'u'),
      `${name}.${argument.name} is required but lacks an explicit NULL guard`,
    );
    requiredArgumentGuards += 1;
  }
  assert.deepEqual(
    [...optional].sort(),
    definition.argumentsList
      .map(({ name: argumentName }) => argumentName)
      .filter((argumentName) => optional.has(argumentName))
      .sort(),
    `${name} optional-argument classification drifted`,
  );
}

// Exact-retry and proof matching must be NULL-safe. Ordinary inequality is
// still allowed for non-null enum/length/range checks, but never for these
// nullable or idempotent comparisons.
for (const requiredAnchor of [
  'existing.metric IS DISTINCT FROM requested_metric',
  'existing.requested_amount IS DISTINCT FROM amount_to_reserve',
  'reservation.finalized_amount IS DISTINCT FROM amount_actually_used',
  'reservation.release_reason IS DISTINCT FROM requested_reason',
  'existing.payload_sha256 IS DISTINCT FROM requested_payload_sha256',
  'existing.provider_occurred_at IS DISTINCT FROM requested_provider_occurred_at',
  'generation.current_period_end IS NOT DISTINCT FROM requested_current_period_end',
  'attempt.policy_version IS DISTINCT FROM requested_policy_version',
]) {
  assert.equal(migrationSql.includes(requiredAnchor), true, `missing NULL-safe comparison: ${requiredAnchor}`);
}

const cluster = await startPostgresCluster();
const pool = new Pool(cluster.bootstrapConfig);

async function durableFingerprint() {
  const tableNames = (await pool.query(
    `SELECT table_name
       FROM information_schema.tables
      WHERE table_schema = 'roomscan' AND table_type = 'BASE TABLE'
      ORDER BY table_name`,
  )).rows.map(({ table_name }) => table_name);
  const rows = [];
  for (const tableName of tableNames) {
    rows.push((await pool.query(
      `SELECT $1::text AS table_name, count(*)::integer AS row_count,
              md5(COALESCE(string_agg(to_jsonb(durable_row)::text, E'\\n'
                ORDER BY to_jsonb(durable_row)::text), '')) AS digest
         FROM roomscan.${tableName} AS durable_row`,
      [tableName],
    )).rows[0]);
  }
  return rows;
}

try {
  await applyMigrations({ pool });
  const before = await durableFingerprint();
  const catalogRows = (await pool.query(
    `SELECT procedure.proname,
            oidvectortypes(procedure.proargtypes) AS identity_types
       FROM pg_proc AS procedure
       JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
      WHERE namespace.nspname = 'roomscan'
        AND procedure.proname = ANY($1::text[])
      ORDER BY procedure.proname`,
    [mutationNames],
  )).rows;
  assert.deepEqual(catalogRows.map(({ proname }) => proname), mutationNames);

  let runtimeAllNullRejections = 0;
  for (const { proname, identity_types: identityTypes } of catalogRows) {
    const casts = identityTypes.length === 0
      ? []
      : identityTypes.split(', ').map((type) => `NULL::${type}`);
    await assert.rejects(
      () => pool.query(`SELECT * FROM roomscan.${proname}(${casts.join(', ')})`),
      (error) => error?.code === '22023',
      `${proname} did not reject its malformed all-NULL invocation with SQLSTATE 22023`,
    );
    runtimeAllNullRejections += 1;
  }
  assert.deepEqual(await durableFingerprint(), before, 'NULL rejections changed durable state');

  console.log(
    `INTEGRATION_0007_NULL_CONTRACTS_SUMMARY mutation_functions=${mutationNames.length} `
      + `required_argument_guards=${requiredArgumentGuards} `
      + `optional_argument_classifications=${optionalArgumentClassifications} `
      + `runtime_all_null_rejections=${runtimeAllNullRejections} durable_changes=0 status=pass`,
  );
} finally {
  await pool.end();
  const cleanup = await cluster.stop();
  console.log(`PG_CLEANUP ${JSON.stringify(cleanup)}`);
}
