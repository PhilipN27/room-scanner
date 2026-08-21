import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { accepted0006MigrationsDir } from './accepted-0006-migrations.mjs';
import { withPrincipalTransaction, withTenantTransaction } from '../runtime.mjs';
import { appPoolConfig, hash32, ids, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const cluster = await startPostgresCluster();
const bootstrapPool = new Pool(cluster.bootstrapConfig);
let appPool;

const contextA = {
  principalId: ids.principalA,
  requestedWorkspaceId: ids.workspaceA,
  expectedAuthorizationVersion: 1,
};
const contextB = {
  principalId: ids.principalB,
  requestedWorkspaceId: ids.workspaceB,
  expectedAuthorizationVersion: 1,
};
const durableTables = [
  'workspaces',
  'memberships',
  'invitations',
  'projects',
  'subscription_states',
  'quota_policy_versions',
  'quota_usage',
  'quota_reservations',
  'quota_ledger',
  'audit_states',
  'audit_events',
  'operational_flags',
  'stripe_event_receipts',
  'stripe_reconciliation_generations',
];

let requiredNullCases = 0;
let exactRetryControls = 0;
let conflictControls = 0;
let crossTenantControls = 0;
let optionalNullControls = 0;

async function durableSnapshot() {
  const snapshot = {};
  for (const table of durableTables) {
    snapshot[table] = (await bootstrapPool.query(
      `SELECT COALESCE(
         jsonb_agg(to_jsonb(durable_row) ORDER BY to_jsonb(durable_row)::text),
         '[]'::jsonb
       ) AS rows
       FROM roomscan.${table} AS durable_row`,
    )).rows[0].rows;
  }
  return snapshot;
}

async function assertErrorWithoutMutation(name, operation, expectedCode, expectedMessage) {
  const before = await durableSnapshot();
  let caught;
  try {
    await operation();
  } catch (error) {
    caught = error;
  }
  const after = await durableSnapshot();
  assert.deepEqual(after, before, `${name} changed durable state`);
  assert.ok(caught, `${name} unexpectedly succeeded`);
  assert.equal(caught.code, expectedCode, `${name} returned the wrong SQLSTATE`);
  assert.equal(caught.message, expectedMessage, `${name} returned the wrong error`);
}

async function assertSuccessWithoutMutation(name, operation) {
  const before = await durableSnapshot();
  const result = await operation();
  const after = await durableSnapshot();
  assert.deepEqual(after, before, `${name} changed durable state on an exact retry`);
  return result;
}

async function tenantQuery(context, text, values = []) {
  return await withTenantTransaction(appPool, context, (client) => client.query(text, values));
}

async function principalQuery(text, values = []) {
  return await withPrincipalTransaction(appPool, { principalId: ids.principalA }, (client) => (
    client.query(text, values)
  ));
}

async function runRequiredNullCases({ reducer, argumentNames, branches, baseArgs, invoke, errorFor }) {
  for (const branch of branches) {
    for (let index = 0; index < argumentNames.length; index += 1) {
      const argument = argumentNames[index];
      const args = baseArgs(branch, argument);
      args[index] = null;
      const expected = errorFor(argument);
      await assertErrorWithoutMutation(
        `${reducer}.${argument}.${branch}`,
        () => invoke(args, branch),
        expected.code,
        expected.message,
      );
      requiredNullCases += 1;
    }
  }
}

try {
  await applyMigrations({ pool: bootstrapPool, migrationsDir: accepted0006MigrationsDir });
  await seedCoreFixtures(bootstrapPool);
  appPool = new Pool(appPoolConfig(cluster, 8));

  await runRequiredNullCases({
    reducer: 'bootstrap_workspace',
    argumentNames: ['requested_slug', 'requested_display_name'],
    branches: ['fresh', 'existing-state'],
    baseArgs: (branch, argument) => [
      argument === 'requested_display_name'
        ? (branch === 'existing-state' ? 'workspace-a' : 'null-display-fresh')
        : 'null-slug-fresh',
      'Null contract workspace',
    ],
    invoke: (args) => principalQuery(
      'SELECT * FROM roomscan.bootstrap_workspace($1::text, $2::text)',
      args,
    ),
    errorFor: () => ({ code: '22023', message: 'INVALID_WORKSPACE_BOOTSTRAP' }),
  });

  await runRequiredNullCases({
    reducer: 'consume_invitation',
    argumentNames: ['invitation_token_hash'],
    branches: ['fresh', 'existing-state'],
    baseArgs: () => [hash32('invitation-a')],
    invoke: (args) => principalQuery(
      'SELECT roomscan.consume_invitation($1::bytea)',
      args,
    ),
    errorFor: () => ({ code: '22023', message: 'INVITATION_TOKEN_HASH_LENGTH' }),
  });

  for (const branch of ['fresh', 'existing-state']) {
    const before = await durableSnapshot();
    const authorized = (await tenantQuery(
      contextA,
      'SELECT roomscan.has_authorized_tenant(NULL::uuid) AS authorized',
    )).rows[0].authorized;
    assert.equal(authorized, false, `has_authorized_tenant NULL ${branch} did not fail closed`);
    assert.deepEqual(await durableSnapshot(), before);
    requiredNullCases += 1;
  }

  const policyArgumentNames = [
    'new_version',
    'new_project_limit',
    'new_member_limit',
    'new_working_byte_limit',
    'new_raw_byte_limit',
    'new_portal_byte_limit',
    'new_warning_threshold_percent',
  ];
  const policySql = `SELECT roomscan.activate_quota_policy(
    $1::bigint, $2::bigint, $3::bigint, $4::bigint, $5::bigint, $6::bigint, $7::integer
  )`;
  await runRequiredNullCases({
    reducer: 'activate_quota_policy',
    argumentNames: policyArgumentNames,
    branches: ['fresh'],
    baseArgs: () => [1, 100, 100, 10_000, 10_000, 10_000, 80],
    invoke: (args) => tenantQuery(contextB, policySql, args),
    errorFor: () => ({ code: '22023', message: 'INVALID_QUOTA_POLICY' }),
  });

  await tenantQuery(contextA, policySql, [1, 100, 100, 10_000, 10_000, 10_000, 80]);
  await tenantQuery(contextB, policySql, [1, 100, 100, 10_000, 10_000, 10_000, 80]);

  await runRequiredNullCases({
    reducer: 'activate_quota_policy',
    argumentNames: policyArgumentNames,
    branches: ['existing-state'],
    baseArgs: () => [2, 200, 200, 20_000, 20_000, 20_000, 90],
    invoke: (args) => tenantQuery(contextA, policySql, args),
    errorFor: () => ({ code: '22023', message: 'INVALID_QUOTA_POLICY' }),
  });

  const reserveSql = `SELECT * FROM roomscan.reserve_quota(
    $1::roomscan.quota_metric, $2::bigint, $3::text
  )`;
  const finalizeSql = 'SELECT * FROM roomscan.finalize_quota($1::text, $2::bigint)';
  const releaseSql = 'SELECT * FROM roomscan.release_quota($1::text)';
  await tenantQuery(contextA, reserveSql, ['project_count', 5, 'null-existing-reserve']);
  await tenantQuery(contextA, reserveSql, ['project_count', 5, 'null-fresh-finalize']);
  await tenantQuery(contextA, reserveSql, ['project_count', 5, 'null-existing-finalize']);
  await tenantQuery(contextA, finalizeSql, ['null-existing-finalize', 3]);
  await tenantQuery(contextA, reserveSql, ['project_count', 5, 'null-fresh-release']);
  await tenantQuery(contextA, reserveSql, ['project_count', 5, 'null-existing-release']);
  await tenantQuery(contextA, releaseSql, ['null-existing-release']);

  await runRequiredNullCases({
    reducer: 'reserve_quota',
    argumentNames: ['requested_metric', 'amount_to_reserve', 'request_key'],
    branches: ['fresh', 'existing-idempotency'],
    baseArgs: (branch, argument) => [
      'project_count',
      5,
      branch === 'existing-idempotency'
        ? 'null-existing-reserve'
        : `null-fresh-reserve-${argument}`,
    ],
    invoke: (args) => tenantQuery(contextA, reserveSql, args),
    errorFor: () => ({ code: '22023', message: 'INVALID_QUOTA_RESERVATION' }),
  });

  await runRequiredNullCases({
    reducer: 'finalize_quota',
    argumentNames: ['request_key', 'amount_actually_used'],
    branches: ['fresh', 'existing-idempotency'],
    baseArgs: (branch) => [
      branch === 'existing-idempotency' ? 'null-existing-finalize' : 'null-fresh-finalize',
      3,
    ],
    invoke: (args) => tenantQuery(contextA, finalizeSql, args),
    errorFor: () => ({ code: '22023', message: 'INVALID_QUOTA_FINALIZATION' }),
  });

  await runRequiredNullCases({
    reducer: 'release_quota',
    argumentNames: ['request_key'],
    branches: ['fresh', 'existing-idempotency'],
    baseArgs: (branch) => [
      branch === 'existing-idempotency' ? 'null-existing-release' : 'null-fresh-release',
    ],
    invoke: (args) => tenantQuery(contextA, releaseSql, args),
    errorFor: () => ({ code: '22023', message: 'INVALID_QUOTA_RELEASE' }),
  });

  const stripeReceiptSql = `SELECT roomscan.record_stripe_event(
    $1::text, $2::text, $3::bytea, $4::boolean, $5::timestamptz
  ) AS inserted`;
  const receiptArgs = [
    'acct_null_contract',
    'evt_null_existing',
    hash32('null-contract-existing'),
    true,
    '2026-08-19T00:00:00Z',
  ];
  await tenantQuery(contextA, stripeReceiptSql, receiptArgs);
  await runRequiredNullCases({
    reducer: 'record_stripe_event',
    argumentNames: [
      'stripe_account_id',
      'stripe_event_id',
      'event_payload_sha256',
      'signature_is_verified',
      'event_occurred_at',
    ],
    branches: ['fresh', 'existing-idempotency'],
    baseArgs: (branch, argument) => branch === 'existing-idempotency'
      ? [...receiptArgs]
      : [
        'acct_null_contract',
        `evt_null_fresh_${argument}`,
        hash32(`null-contract-${argument}`),
        true,
        '2026-08-19T00:01:00Z',
      ],
    invoke: (args) => tenantQuery(contextA, stripeReceiptSql, args),
    errorFor: (argument) => argument === 'signature_is_verified'
      ? { code: 'P0001', message: 'STRIPE_SIGNATURE_UNVERIFIED' }
      : { code: '22023', message: 'INVALID_STRIPE_RECEIPT' },
  });

  const reconciliationSql = `SELECT roomscan.apply_stripe_reconciliation(
    $1::bigint, $2::timestamptz, $3::text, $4::text, $5::timestamptz
  ) AS applied`;
  const reconciliationArgs = [
    10,
    '2026-08-19T01:00:00Z',
    'active',
    'professional',
    '2026-09-19T01:00:00Z',
  ];
  await tenantQuery(contextA, reconciliationSql, reconciliationArgs);
  await runRequiredNullCases({
    reducer: 'apply_stripe_reconciliation',
    argumentNames: [
      'new_generation',
      'authoritative_observed_at',
      'authoritative_status',
      'authoritative_plan_key',
    ],
    branches: ['fresh', 'existing-idempotency'],
    baseArgs: (branch, argument) => branch === 'existing-idempotency'
      ? [...reconciliationArgs]
      : [
        20 + ['new_generation', 'authoritative_observed_at', 'authoritative_status', 'authoritative_plan_key'].indexOf(argument),
        '2026-08-19T02:00:00Z',
        'active',
        'professional',
        '2026-09-19T02:00:00Z',
      ],
    invoke: (args) => tenantQuery(contextA, reconciliationSql, args),
    errorFor: () => ({ code: '22023', message: 'INVALID_STRIPE_RECONCILIATION' }),
  });

  await assertSuccessWithoutMutation('reserve exact retry', () => (
    tenantQuery(contextA, reserveSql, ['project_count', 5, 'null-existing-reserve'])
  ));
  exactRetryControls += 1;
  await assertErrorWithoutMutation(
    'reserve conflicting non-null retry',
    () => tenantQuery(contextA, reserveSql, ['project_count', 6, 'null-existing-reserve']),
    'P0001',
    'IDEMPOTENCY_KEY_REUSED',
  );
  conflictControls += 1;

  await assertSuccessWithoutMutation('finalize exact retry', () => (
    tenantQuery(contextA, finalizeSql, ['null-existing-finalize', 3])
  ));
  exactRetryControls += 1;
  await assertErrorWithoutMutation(
    'finalize conflicting non-null retry',
    () => tenantQuery(contextA, finalizeSql, ['null-existing-finalize', 2]),
    'P0001',
    'IDEMPOTENCY_KEY_REUSED',
  );
  conflictControls += 1;

  await assertSuccessWithoutMutation('release exact retry', () => (
    tenantQuery(contextA, releaseSql, ['null-existing-release'])
  ));
  exactRetryControls += 1;
  await assertErrorWithoutMutation(
    'release conflicting terminal state',
    () => tenantQuery(contextA, releaseSql, ['null-existing-finalize']),
    'P0001',
    'QUOTA_RESERVATION_FINALIZED',
  );
  conflictControls += 1;

  await assertSuccessWithoutMutation('Stripe receipt exact retry', async () => {
    const result = await tenantQuery(contextA, stripeReceiptSql, receiptArgs);
    assert.equal(result.rows[0].inserted, false);
  });
  exactRetryControls += 1;
  await assertErrorWithoutMutation(
    'Stripe receipt conflicting non-null retry',
    () => tenantQuery(contextA, stripeReceiptSql, [
      receiptArgs[0], receiptArgs[1], hash32('conflicting-non-null'), true, receiptArgs[4],
    ]),
    'P0001',
    'STRIPE_EVENT_KEY_REUSED',
  );
  conflictControls += 1;

  await assertSuccessWithoutMutation('reconciliation exact retry', () => (
    tenantQuery(contextA, reconciliationSql, reconciliationArgs)
  ));
  exactRetryControls += 1;
  await assertErrorWithoutMutation(
    'reconciliation conflicting non-null retry',
    () => tenantQuery(contextA, reconciliationSql, [
      reconciliationArgs[0], reconciliationArgs[1], 'canceled', 'none', reconciliationArgs[4],
    ]),
    'P0001',
    'RECONCILIATION_GENERATION_REUSED',
  );
  conflictControls += 1;

  const optionalNullArgs = [30, '2026-08-19T03:00:00Z', 'canceled', 'none', null];
  assert.equal((await tenantQuery(contextA, reconciliationSql, optionalNullArgs)).rows[0].applied, true);
  optionalNullControls += 1;
  await assertSuccessWithoutMutation('optional period-end NULL exact retry', async () => {
    assert.equal((await tenantQuery(contextA, reconciliationSql, optionalNullArgs)).rows[0].applied, true);
  });
  optionalNullControls += 1;
  exactRetryControls += 1;
  await assertErrorWithoutMutation(
    'optional period-end NULL/non-NULL conflict',
    () => tenantQuery(contextA, reconciliationSql, [
      ...optionalNullArgs.slice(0, 4), '2026-09-19T03:00:00Z',
    ]),
    'P0001',
    'RECONCILIATION_GENERATION_REUSED',
  );
  optionalNullControls += 1;
  conflictControls += 1;
  assert.equal((await tenantQuery(contextA,
    `SELECT current_period_end IS NULL AS is_null
     FROM roomscan.stripe_reconciliation_generations WHERE generation = 30`,
  )).rows[0].is_null, true);

  const crossHelperBefore = await durableSnapshot();
  assert.equal((await tenantQuery(
    contextA,
    'SELECT roomscan.has_authorized_tenant($1::uuid) AS authorized',
    [ids.workspaceB],
  )).rows[0].authorized, false);
  assert.deepEqual(await durableSnapshot(), crossHelperBefore);
  crossTenantControls += 1;

  await assertErrorWithoutMutation(
    'cross-tenant Stripe receipt key conflict',
    () => tenantQuery(contextB, stripeReceiptSql, receiptArgs),
    'P0001',
    'STRIPE_EVENT_KEY_REUSED',
  );
  crossTenantControls += 1;

  await tenantQuery(contextB, reserveSql, ['project_count', 5, 'null-existing-reserve']);
  const scopedReservations = (await bootstrapPool.query(
    `SELECT workspace_id, count(*)::int AS count
     FROM roomscan.quota_reservations
     WHERE idempotency_key = 'null-existing-reserve'
     GROUP BY workspace_id ORDER BY workspace_id`,
  )).rows;
  assert.deepEqual(scopedReservations, [
    { workspace_id: ids.workspaceA, count: 1 },
    { workspace_id: ids.workspaceB, count: 1 },
  ]);
  crossTenantControls += 1;

  console.log(`REDUCER_NULL_ARGUMENT_SUMMARY required_null_cases=${requiredNullCases} durable_no_change=true exact_retries=${exactRetryControls} conflicts=${conflictControls} cross_tenant=${crossTenantControls} optional_null=${optionalNullControls} status=pass`);
} finally {
  await appPool?.end();
  await bootstrapPool.end();
  const cleanup = await cluster.stop();
  console.error(`CLEANUP ${JSON.stringify(cleanup)}`);
}
