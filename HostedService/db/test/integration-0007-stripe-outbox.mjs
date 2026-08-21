import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { appPoolConfig, hash32, ids, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const cluster = await startPostgresCluster();
const bootstrapPool = new Pool(cluster.bootstrapConfig);
let ingressPool;
let reconcilePool;

async function expectCode(work, code) {
  await assert.rejects(work, (error) => error?.code === code);
}

try {
  await applyMigrations({ pool: bootstrapPool });
  await seedCoreFixtures(bootstrapPool);
  const now = new Date('2026-08-19T12:00:00.000Z');

  const tables = (await bootstrapPool.query(
    `SELECT c.relname, c.relrowsecurity, c.relforcerowsecurity
       FROM pg_class AS c JOIN pg_namespace AS n ON n.oid = c.relnamespace
      WHERE n.nspname = 'roomscan' AND c.relname = ANY($1::text[])
      ORDER BY c.relname`,
    [['stripe_event_receipts_v2', 'stripe_billing_bindings', 'stripe_reconciliation_outbox']],
  )).rows;
  assert.deepEqual(tables, [
    'stripe_billing_bindings', 'stripe_event_receipts_v2', 'stripe_reconciliation_outbox',
  ].map((relname) => ({ relname, relrowsecurity: true, relforcerowsecurity: true })));
  assert.deepEqual((await bootstrapPool.query(
    `SELECT c.relname, c.relrowsecurity, c.relforcerowsecurity
       FROM pg_class AS c JOIN pg_namespace AS n ON n.oid = c.relnamespace
      WHERE n.nspname = 'roomscan' AND c.relname = 'stripe_provider_accounts'`,
  )).rows, [{
    relname: 'stripe_provider_accounts', relrowsecurity: false, relforcerowsecurity: false,
  }]);

  await bootstrapPool.query('SET ROLE roomscan_operator');
  for (const [scope, workspace, suffix] of [
    ['global', null, 'stripe_global_hosted'],
    ['workspace', ids.workspaceA, 'stripe_workspace_hosted'],
    ['workspace', ids.workspaceB, 'stripe_workspace_b'],
  ]) {
    await bootstrapPool.query(
      `SELECT * FROM roomscan.set_operational_flag(
         $1, $2::uuid, 'hosted_operations_enabled', true, NULL,
         'stripe integration', $3, $4
       )`,
      [scope, workspace, `ofaud_${suffix}`, now],
    );
  }
  assert.equal((await bootstrapPool.query(
    `SELECT roomscan.bind_stripe_account(
       $1, 'platform', 'acct_workspaceA', 'cus_workspaceA', 'sub_workspaceA', $2
     ) AS status`,
    [ids.workspaceA, now],
  )).rows[0].status, 'bound');
  assert.equal((await bootstrapPool.query(
    `SELECT roomscan.bind_stripe_account(
       $1, 'connected', 'acct_workspaceB', 'cus_workspaceB', 'sub_workspaceB', $2
     ) AS status`,
    [ids.workspaceB, now],
  )).rows[0].status, 'bound');
  await bootstrapPool.query('RESET ROLE');

  ingressPool = new Pool({
    ...appPoolConfig(cluster, 4), user: 'roomscan_stripe_ingress_runtime',
    application_name: 'rss-0007-stripe-ingress',
  });
  reconcilePool = new Pool({
    ...appPoolConfig(cluster, 4), user: 'roomscan_stripe_reconciliation_runtime',
    application_name: 'rss-0007-stripe-reconcile',
  });

  const acceptSql = `SELECT * FROM roomscan.accept_stripe_event_v2(
    $1, $2, $3, $4, $5, $6, $7, $8::bytea,
    $9::timestamptz, $10::timestamptz
  )`;
  const eventOne = [
    'platform', 'acct_workspaceA', 'cus_workspaceA', 'sub_workspaceA',
    'evt_event001', 'customer.subscription.updated', 'sub_workspaceA',
    hash32('stripe-event-one'), new Date(now.getTime() - 2_000), now,
  ];
  const accepted = (await ingressPool.query(acceptSql, eventOne)).rows[0];
  assert.deepEqual(accepted, { status: 'accepted', workspace_id: ids.workspaceA, generation: '1' });
  const laterRetryReceivedAt = new Date(now.getTime() + 1_000);
  const duplicate = (await ingressPool.query(acceptSql, [
    ...eventOne.slice(0, 9), laterRetryReceivedAt,
  ])).rows[0];
  assert.deepEqual(duplicate, { status: 'duplicate', workspace_id: ids.workspaceA, generation: '1' });
  assert.equal((await bootstrapPool.query(
    `SELECT received_at FROM roomscan.stripe_event_receipts_v2
      WHERE provider_account_id = $1 AND event_id = $2`,
    [eventOne[1], eventOne[4]],
  )).rows[0].received_at.toISOString(), now.toISOString(), 'exact retry rewrote original receipt time');
  await expectCode(
    () => ingressPool.query(acceptSql, [
      ...eventOne.slice(0, 7), hash32('conflicting-body'), ...eventOne.slice(8),
    ]),
    'P0001',
  );
  const acceptedB = (await ingressPool.query(acceptSql, [
    'connected', 'acct_workspaceB', 'cus_workspaceB', 'sub_workspaceB',
    'evt_event001', 'customer.subscription.updated', 'sub_workspaceB',
    hash32('stripe-event-b'), new Date(now.getTime() - 1_000), now,
  ])).rows[0];
  assert.equal(acceptedB.workspace_id, ids.workspaceB);

  await bootstrapPool.query('SET ROLE roomscan_operator');
  await bootstrapPool.query(
    `SELECT * FROM roomscan.set_operational_flag(
       'workspace', $1, 'hosted_operations_enabled', false, 1,
       'stripe claim disabled control', 'ofaud_stripe_b_disabled', $2
     )`, [ids.workspaceB, new Date(now.getTime() + 1)],
  );
  await bootstrapPool.query('RESET ROLE');

  const claimSql = `SELECT * FROM roomscan.claim_stripe_reconciliation_v2(
    $1, $2::timestamptz, $3::timestamptz
  )`;
  const claimRace = await Promise.all([
    reconcilePool.query(claimSql, ['lease_one', now, new Date(now.getTime() + 30_000)]),
    reconcilePool.query(claimSql, ['lease_two', now, new Date(now.getTime() + 30_000)]),
  ]);
  const claims = claimRace.flatMap(({ rows }) => rows);
  assert.equal(claims.length, 1, 'disabled workspace must not be leased');
  const claimA = claims.find(({ workspace_id }) => workspace_id === ids.workspaceA);
  assert.ok(claimA);
  assert.equal(claimA.hosted_global_version, '1');
  assert.equal(claimA.hosted_workspace_version, '1');

  await bootstrapPool.query('SET ROLE roomscan_operator');
  await bootstrapPool.query(
    `SELECT * FROM roomscan.set_operational_flag(
       'workspace', $1, 'hosted_operations_enabled', true, 2,
       'stripe claim resume control', 'ofaud_stripe_b_resumed', $2
     )`, [ids.workspaceB, new Date(now.getTime() + 2)],
  );
  await bootstrapPool.query('RESET ROLE');
  const claimB = (await reconcilePool.query(
    claimSql, ['lease_b_resumed', new Date(now.getTime() + 3),
      new Date(now.getTime() + 30_003)],
  )).rows[0];
  assert.equal(claimB.workspace_id, ids.workspaceB);
  assert.equal(claimB.hosted_global_version, '1');
  assert.equal(claimB.hosted_workspace_version, '3');
  assert.deepEqual((await reconcilePool.query(
    `SELECT * FROM roomscan.complete_stripe_reconciliation_v2(
       $1, $2, $3, $4, $5, $6, $7::timestamptz,
       'active', 'test-plan-b', NULL, $8::timestamptz, $9, $10
     )`, [
      claimB.lease_id, claimB.account_mode, claimB.provider_account_id,
      claimB.billing_customer_id, claimB.subscription_id, claimB.generation,
      now, new Date(now.getTime() + 4), claimB.hosted_global_version,
      claimB.hosted_workspace_version,
    ],
  )).rows[0], { status: 'applied', needs_another_generation: false });

  const secondEvent = (await ingressPool.query(acceptSql, [
    'platform', 'acct_workspaceA', 'cus_workspaceA', 'sub_workspaceA',
    'evt_event002', 'customer.subscription.updated', 'sub_workspaceA',
    hash32('stripe-event-two'), new Date(now.getTime() - 500),
    new Date(now.getTime() + 100),
  ])).rows[0];
  assert.equal(secondEvent.generation, '2');

  const completed = (await reconcilePool.query(
    `SELECT * FROM roomscan.complete_stripe_reconciliation_v2(
       $1, $2, $3, $4, $5, $6, $7::timestamptz,
       'active', 'test-plan', NULL, $8::timestamptz, $9, $10
     )`,
    [
      claimA.lease_id, claimA.account_mode, claimA.provider_account_id,
      claimA.billing_customer_id, claimA.subscription_id, claimA.generation,
      new Date(now.getTime() - 100), new Date(now.getTime() + 1_000),
      claimA.hosted_global_version, claimA.hosted_workspace_version,
    ],
  )).rows[0];
  assert.deepEqual(completed, { status: 'applied', needs_another_generation: true });

  const claimNext = (await reconcilePool.query(
    claimSql, ['lease_three', new Date(now.getTime() + 2_000), new Date(now.getTime() + 32_000)],
  )).rows.find(({ workspace_id }) => workspace_id === ids.workspaceA);
  assert.ok(claimNext);
  assert.equal(claimNext.hosted_global_version, '1');
  assert.equal(claimNext.hosted_workspace_version, '1');
  await bootstrapPool.query('SET ROLE roomscan_operator');
  await bootstrapPool.query(
    `SELECT * FROM roomscan.set_operational_flag(
       'global', NULL, 'hosted_operations_enabled', false, 1,
       'freeze', 'ofaud_stripe_freezeglobal', $1
     )`,
    [new Date(now.getTime() + 2_500)],
  );
  await bootstrapPool.query(
    `SELECT * FROM roomscan.set_operational_flag(
       'global', NULL, 'hosted_operations_enabled', true, 2,
       'resume', 'ofaud_stripe_resumeglobal', $1
     )`,
    [new Date(now.getTime() + 2_600)],
  );
  await bootstrapPool.query('RESET ROLE');
  const staleGrant = (await reconcilePool.query(
    `SELECT * FROM roomscan.complete_stripe_reconciliation_v2(
       $1, $2, $3, $4, $5, $6, $7::timestamptz,
       'past_due', 'test-plan', NULL, $8::timestamptz, 1, 1
     )`,
    [
      claimNext.lease_id, claimNext.account_mode, claimNext.provider_account_id,
      claimNext.billing_customer_id, claimNext.subscription_id, claimNext.generation,
      new Date(now.getTime() + 2_000), new Date(now.getTime() + 3_000),
    ],
  )).rows[0];
  assert.deepEqual(staleGrant, { status: 'hosted_gate_rejected', needs_another_generation: true });

  const subscription = (await bootstrapPool.query(
    `SELECT status, plan_key, reconciliation_generation FROM roomscan.subscription_states
      WHERE workspace_id = $1`,
    [ids.workspaceA],
  )).rows[0];
  assert.deepEqual(subscription, {
    status: 'active', plan_key: 'test-plan', reconciliation_generation: '1',
  });

  const exactOutbox = (await bootstrapPool.query(
    `SELECT desired_generation, applied_generation, lease_id
       FROM roomscan.stripe_reconciliation_outbox WHERE workspace_id = $1`,
    [ids.workspaceA],
  )).rows[0];
  assert.deepEqual(exactOutbox, {
    desired_generation: '2', applied_generation: '1', lease_id: null,
  });

  for (const role of [
    'roomscan_api_runtime', 'roomscan_authorizer_runtime',
    'roomscan_auth_challenge_runtime', 'roomscan_stripe_ingress_runtime',
    'roomscan_stripe_reconciliation_runtime', 'roomscan_audit_export_runtime',
    'roomscan_email_delivery_runtime',
  ]) {
    for (const table of [
      'stripe_provider_accounts', 'stripe_billing_bindings', 'stripe_event_receipts_v2',
      'stripe_reconciliation_outbox', 'subscription_states',
    ]) {
      const acl = (await bootstrapPool.query(
        `SELECT has_table_privilege($1, 'roomscan.' || $2, 'INSERT') AS i,
                has_table_privilege($1, 'roomscan.' || $2, 'UPDATE') AS u,
                has_table_privilege($1, 'roomscan.' || $2, 'DELETE') AS d,
                has_table_privilege($1, 'roomscan.' || $2, 'TRUNCATE') AS t`,
        [role, table],
      )).rows[0];
      assert.deepEqual(acl, { i: false, u: false, d: false, t: false });
    }
  }

  console.log(
    'INTEGRATION_0007_STRIPE_OUTBOX_SUMMARY forced_rls_tables=3 mapping_controls=3 '
      + 'receipt_controls=4 lease_claims=3 hosted_claim_controls=7 event_during_fetch=1 stale_grant_controls=2 '
      + 'later_retry_controls=2 protected_acl_pairs=28 status=pass',
  );
} finally {
  if (ingressPool) await ingressPool.end();
  if (reconcilePool) await reconcilePool.end();
  await bootstrapPool.end();
  const cleanup = await cluster.stop();
  console.log(`PG_CLEANUP ${JSON.stringify(cleanup)}`);
}
