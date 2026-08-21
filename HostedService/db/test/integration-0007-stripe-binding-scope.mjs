import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { appPoolConfig, hash32, ids, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const workspaceC = '20000000-0000-4000-8000-000000000003';
const workspaceD = '20000000-0000-4000-8000-000000000004';
const workspaceE = '20000000-0000-4000-8000-000000000005';
const workspaceF = '20000000-0000-4000-8000-000000000006';
const workspaceG = '20000000-0000-4000-8000-000000000007';
const isolationWorkspaces = [
  '20000000-0000-4000-8000-000000000008',
  '20000000-0000-4000-8000-000000000009',
  '20000000-0000-4000-8000-000000000010',
  '20000000-0000-4000-8000-000000000011',
  '20000000-0000-4000-8000-000000000012',
  '20000000-0000-4000-8000-000000000013',
  '20000000-0000-4000-8000-000000000014',
  '20000000-0000-4000-8000-000000000015',
];
const cluster = await startPostgresCluster();
const bootstrap = new Pool(cluster.bootstrapConfig);
let ingress;
let reconciler;

async function expectCode(work, code) {
  await assert.rejects(work, (error) => error?.code === code);
}

async function waitForAdvisoryWaiter(applicationName) {
  const deadline = Date.now() + 2_000;
  while (Date.now() < deadline) {
    const count = Number((await bootstrap.query(
      `SELECT count(*)::integer AS count
         FROM pg_catalog.pg_stat_activity
        WHERE application_name = $1
          AND wait_event_type = 'Lock'
          AND wait_event = 'advisory'`,
      [applicationName],
    )).rows[0].count);
    if (count === 1) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.fail(`timed out waiting for Stripe advisory waiter ${applicationName}`);
}

try {
  await applyMigrations({ pool: bootstrap });
  await seedCoreFixtures(bootstrap);
  const now = new Date('2026-08-19T18:00:00.000Z');
  const stripeIdConstraints = (await bootstrap.query(
    `SELECT c.relname AS table_name, pg_get_constraintdef(con.oid) AS definition
       FROM pg_constraint AS con
       JOIN pg_class AS c ON c.oid = con.conrelid
       JOIN pg_namespace AS n ON n.oid = c.relnamespace
      WHERE n.nspname = 'roomscan'
        AND c.relname = ANY($1::text[])
        AND con.contype = 'c'
        AND pg_get_constraintdef(con.oid) ~ '(acct_|cus_|sub_|evt_)'
      ORDER BY c.relname, definition`,
    [[
      'stripe_provider_accounts', 'stripe_billing_bindings',
      'stripe_event_receipts_v2',
      'stripe_reconciliation_outbox',
    ]],
  )).rows;
  await bootstrap.query(
    `INSERT INTO roomscan.workspaces(id, slug, display_name) VALUES
       ($1, 'workspace-c', 'Workspace C'),
       ($2, 'workspace-d', 'Workspace D'),
       ($3, 'workspace-e', 'Workspace E'),
       ($4, 'workspace-f', 'Workspace F'),
       ($5, 'workspace-g', 'Workspace G')`,
    [workspaceC, workspaceD, workspaceE, workspaceF, workspaceG],
  );
  await bootstrap.query(
    `INSERT INTO roomscan.workspaces(id, slug, display_name)
     SELECT workspace_id,
            'workspace-isolation-' || ordinal_position::text,
            'Workspace Isolation ' || ordinal_position::text
       FROM unnest($1::uuid[]) WITH ORDINALITY AS requested(workspace_id, ordinal_position)`,
    [isolationWorkspaces],
  );
  await bootstrap.query('SET ROLE roomscan_operator');
  for (const [scope, workspace, audit] of [
    ['global', null, 'ofaud_stripe_scope_global'],
    ['workspace', ids.workspaceA, 'ofaud_stripe_scope_a'],
    ['workspace', ids.workspaceB, 'ofaud_stripe_scope_b'],
    ['workspace', workspaceC, 'ofaud_stripe_scope_c'],
  ]) {
    await bootstrap.query(
      `SELECT * FROM roomscan.set_operational_flag(
         $1, $2::uuid, 'hosted_operations_enabled', true, NULL,
         'stripe binding scope test', $3, $4
       )`, [scope, workspace, audit, now],
    );
  }

  const bindSql = `SELECT roomscan.bind_stripe_account(
    $1::uuid, $2, $3, $4, $5, $6::timestamptz
  ) AS status`;
  async function runMixedModeSnapshotRace({
    isolation, firstMode, workspaceOffset, accountSuffix,
  }) {
    const clients = await Promise.all([bootstrap.connect(), bootstrap.connect()]);
    const account = `acct_iso${accountSuffix}`;
    const modes = [firstMode, firstMode === 'platform' ? 'connected' : 'platform'];
    try {
      await Promise.all(clients.map(async (client) => {
        await client.query('SET ROLE roomscan_operator');
        await client.query(`BEGIN ISOLATION LEVEL ${isolation}`);
      }));
      const snapshots = await Promise.all(clients.map((client) => client.query(
        `SELECT pg_catalog.txid_current_snapshot()::text AS snapshot`,
      )));
      assert.equal(snapshots.every(({ rows }) => rows[0].snapshot.length > 0), true);

      const firstArgs = [
        isolationWorkspaces[workspaceOffset], modes[0], account,
        `cus_iso${accountSuffix}A`, `sub_iso${accountSuffix}A`, now,
      ];
      const secondArgs = [
        isolationWorkspaces[workspaceOffset + 1], modes[1], account,
        `cus_iso${accountSuffix}B`, `sub_iso${accountSuffix}B`, now,
      ];
      assert.equal((await clients[0].query(bindSql, firstArgs)).rows[0].status, 'bound');
      await clients[0].query('COMMIT');

      let secondError;
      try {
        await clients[1].query(bindSql, secondArgs);
        await clients[1].query('COMMIT');
      } catch (error) {
        secondError = error;
        await clients[1].query('ROLLBACK').catch(() => undefined);
      }
      assert.ok(secondError, `${isolation} ${firstMode}-first mixed-mode bind unexpectedly committed`);
      assert.ok(
        secondError.code === '40001' || secondError.code === 'P0001',
        `${isolation} ${firstMode}-first mixed-mode bind leaked ${secondError.code}`,
      );
      assert.notEqual(secondError.code, '23505');
      assert.equal((await bootstrap.query(
        `SELECT count(*)::integer AS count
           FROM roomscan.stripe_billing_bindings
          WHERE provider_account_id = $1`,
        [account],
      )).rows[0].count, 1);
      assert.deepEqual((await bootstrap.query(
        `SELECT provider_account_id, account_mode
           FROM roomscan.stripe_provider_accounts
          WHERE provider_account_id = $1`,
        [account],
      )).rows, [{ provider_account_id: account, account_mode: firstMode }]);
      return secondError.code;
    } finally {
      for (const client of clients) {
        await client.query('ROLLBACK').catch(() => undefined);
        await client.query('RESET ROLE').catch(() => undefined);
        client.release();
      }
    }
  }
  assert.equal((await bootstrap.query(bindSql, [ids.workspaceA, 'platform', 'acct_platform', 'cus_workspaceA', 'sub_workspaceA', now])).rows[0].status, 'bound');
  assert.equal((await bootstrap.query(bindSql, [ids.workspaceB, 'platform', 'acct_platform', 'cus_workspaceB', 'sub_workspaceB', now])).rows[0].status, 'bound');
  assert.equal((await bootstrap.query(bindSql, [workspaceC, 'connected', 'acct_connectedC', 'cus_workspaceC', 'sub_workspaceC', now])).rows[0].status, 'bound');
  assert.equal((await bootstrap.query(bindSql, [ids.workspaceA, 'platform', 'acct_platform', 'cus_workspaceA', 'sub_workspaceA', new Date(now.getTime() + 1)])).rows[0].status, 'existing');
  await expectCode(() => bootstrap.query(bindSql, [ids.workspaceB, 'platform', 'acct_platform', 'cus_workspaceA', 'sub_workspaceA', now]), 'P0001');
  await expectCode(() => bootstrap.query(bindSql, [ids.workspaceA, 'platform', 'acct_platform', 'cus_other01', 'sub_other01', now]), 'P0001');
  await expectCode(() => bootstrap.query(bindSql, [ids.workspaceB, 'connected', 'acct_connectedC', 'cus_workspaceB2', 'sub_workspaceB2', now]), 'P0001');
  await expectCode(() => bootstrap.query(bindSql, [workspaceD, 'platform', 'acct_connectedC', 'cus_workspaceD', 'sub_workspaceD', now]), 'P0001');
  await expectCode(() => bootstrap.query(bindSql, [workspaceE, 'connected', 'acct_platform', 'cus_workspaceE', 'sub_workspaceE', now]), 'P0001');
  assert.equal((await bootstrap.query(bindSql, [workspaceC, 'connected', 'acct_connectedC', 'cus_workspaceC', 'sub_workspaceC', new Date(now.getTime() + 1)])).rows[0].status, 'existing');

  const raceClients = await Promise.all([bootstrap.connect(), bootstrap.connect()]);
  let raceReady = 0;
  let releaseRace;
  let releaseReady;
  const raceGo = new Promise((resolve) => { releaseRace = resolve; });
  const raceBarrier = new Promise((resolve) => { releaseReady = resolve; });
  const raceBindings = raceClients.map(async (client, index) => {
    try {
      await client.query('SET ROLE roomscan_operator');
      await client.query('BEGIN');
      raceReady += 1;
      if (raceReady === raceClients.length) releaseReady();
      await raceGo;
      const args = index === 0
        ? [workspaceF, 'platform', 'acct_symmetricRace', 'cus_symmetricF', 'sub_symmetricF', now]
        : [workspaceG, 'connected', 'acct_symmetricRace', 'cus_symmetricG', 'sub_symmetricG', now];
      const row = (await client.query(bindSql, args)).rows[0];
      await client.query('COMMIT');
      return row;
    } catch (error) {
      await client.query('ROLLBACK').catch(() => undefined);
      throw error;
    } finally {
      await client.query('RESET ROLE').catch(() => undefined);
      client.release();
    }
  });
  await raceBarrier;
  releaseRace();
  const bindingRace = await Promise.allSettled(raceBindings);
  assert.equal(bindingRace.filter(({ status }) => status === 'fulfilled').length, 1);
  const bindingRaceLoser = bindingRace.find(({ status }) => status === 'rejected');
  assert.equal(bindingRaceLoser?.reason?.code, 'P0001');
  assert.equal(bindingRaceLoser?.reason?.message, 'STRIPE_BINDING_CONFLICT');
  assert.equal((await bootstrap.query(
    `SELECT count(*)::integer AS count
       FROM roomscan.stripe_provider_accounts
      WHERE provider_account_id = 'acct_symmetricRace'`,
  )).rows[0].count, 1);

  const isolationRaceCodes = [];
  for (const [isolation, firstMode, workspaceOffset, accountSuffix] of [
    ['REPEATABLE READ', 'platform', 0, 'rrPlatform'],
    ['REPEATABLE READ', 'connected', 2, 'rrConnect'],
    ['SERIALIZABLE', 'platform', 4, 'serPlatform'],
    ['SERIALIZABLE', 'connected', 6, 'serConnect'],
  ]) {
    isolationRaceCodes.push(await runMixedModeSnapshotRace({
      isolation, firstMode, workspaceOffset, accountSuffix,
    }));
  }
  assert.equal(isolationRaceCodes.length, 4);

  await bootstrap.query('BEGIN');
  try {
    await bootstrap.query(
      `INSERT INTO roomscan.stripe_provider_accounts(provider_account_id, account_mode)
       VALUES ('acct_storageGuard', 'platform')`,
    );
    await expectCode(
      () => bootstrap.query(
        `INSERT INTO roomscan.stripe_billing_bindings(
           workspace_id, account_mode, provider_account_id,
           billing_customer_id, subscription_id, bound_at
         ) VALUES (
           $1, 'connected', 'acct_storageGuard',
           'cus_storageGuard', 'sub_storageGuard', $2
         )`,
        [workspaceD, now],
      ),
      '23503',
    );
  } finally {
    await bootstrap.query('ROLLBACK');
  }
  for (const [account, customer, subscription] of [
    ['acct_abcde', 'cus_abcdef', 'sub_abcdef'],
    ['acct_abcdef-', 'cus_abcdef', 'sub_abcdef'],
    ['acc_abcdef', 'cus_abcdef', 'sub_abcdef'],
    ['acct_abcdef', 'cus_abcde', 'sub_abcdef'],
    ['acct_abcdef', 'customer_abcdef', 'sub_abcdef'],
    ['acct_abcdef', 'cus_abcdef', 'sub_abcde'],
    ['acct_abcdef', 'cus_abcdef', 'subscription_abcdef'],
  ]) {
    await expectCode(
      () => bootstrap.query(bindSql, [ids.workspaceA, 'platform', account, customer, subscription, now]),
      '22023',
    );
  }
  await bootstrap.query('RESET ROLE');

  ingress = new Pool({ ...appPoolConfig(cluster, 8), user: 'roomscan_stripe_ingress_runtime', application_name: 'rss-0007-stripe-binding-ingress' });
  reconciler = new Pool({ ...appPoolConfig(cluster, 8), user: 'roomscan_stripe_reconciliation_runtime', application_name: 'rss-0007-stripe-binding-reconciler' });
  const acceptSql = `SELECT * FROM roomscan.accept_stripe_event_v2(
    $1, $2, $3, $4, $5, $6, $7, $8::bytea, $9::timestamptz, $10::timestamptz
  )`;
  const eventA = ['platform', 'acct_platform', 'cus_workspaceA', 'sub_workspaceA', 'evt_eventA1', 'customer.subscription.updated', 'sub_workspaceA', hash32('event-a'), new Date(now.getTime() - 2_000), now];
  const eventB = ['platform', 'acct_platform', 'cus_workspaceB', 'sub_workspaceB', 'evt_eventB1', 'customer.subscription.created', 'sub_workspaceB', hash32('event-b'), new Date(now.getTime() - 1_000), now];
  const eventC = ['connected', 'acct_connectedC', 'cus_workspaceC', 'sub_workspaceC', 'evt_eventC1', 'customer.subscription.deleted', 'sub_workspaceC', hash32('event-c'), new Date(now.getTime() - 500), now];
  assert.equal((await ingress.query(acceptSql, eventA)).rows[0].workspace_id, ids.workspaceA);
  assert.equal((await ingress.query(acceptSql, eventB)).rows[0].workspace_id, ids.workspaceB);
  assert.equal((await ingress.query(acceptSql, eventC)).rows[0].workspace_id, workspaceC);
  assert.equal((await ingress.query(acceptSql, [...eventA.slice(0, 9), new Date(now.getTime() + 1_000)])).rows[0].status, 'duplicate');

  async function runReceiptIsolationRace({ isolation, retryKind, suffix }) {
    const clients = await Promise.all([ingress.connect(), ingress.connect()]);
    const eventId = `evt_iso${suffix}`;
    const payload = hash32(`receipt-isolation-${suffix}`);
    const firstArgs = [
      'platform', 'acct_platform', 'cus_workspaceA', 'sub_workspaceA', eventId,
      'customer.subscription.updated', 'sub_workspaceA', payload,
      new Date(now.getTime() + 10_000), new Date(now.getTime() + 11_000),
    ];
    const retryArgs = retryKind === 'exact'
      ? [...firstArgs.slice(0, 9), new Date(now.getTime() + 12_000)]
      : [
          ...firstArgs.slice(0, 7), hash32(`receipt-isolation-${suffix}-changed`),
          firstArgs[8], new Date(now.getTime() + 12_000),
        ];
    const waiterName = `rss-stripe-receipt-${suffix}`;
    let waiterOutcome;
    try {
      await clients[1].query(
        `SELECT pg_catalog.set_config('application_name', $1, false)`,
        [waiterName],
      );
      await Promise.all(clients.map((client) => client.query(
        `BEGIN ISOLATION LEVEL ${isolation}`,
      )));
      const snapshots = await Promise.all(clients.map((client) => client.query(
        `SELECT pg_catalog.txid_current_snapshot()::text AS snapshot`,
      )));
      assert.equal(snapshots.every(({ rows }) => rows[0].snapshot.length > 0), true);
      assert.equal((await clients[0].query(acceptSql, firstArgs)).rows[0].status, 'accepted');
      const waiterPromise = clients[1].query(acceptSql, retryArgs).then(
        (value) => ({ value }),
        (error) => ({ error }),
      );
      await waitForAdvisoryWaiter(waiterName);
      await clients[0].query('COMMIT');
      waiterOutcome = await waiterPromise;

      if (isolation === 'READ COMMITTED' && retryKind === 'exact') {
        assert.equal(waiterOutcome.value?.rows[0].status, 'duplicate');
        await clients[1].query('COMMIT');
      } else if (isolation === 'READ COMMITTED') {
        assert.equal(waiterOutcome.error?.code, 'P0001');
        assert.equal(waiterOutcome.error?.message, 'STRIPE_EVENT_KEY_REUSED');
        await clients[1].query('ROLLBACK');
      } else {
        assert.equal(waiterOutcome.error?.code, '40001');
        assert.equal(waiterOutcome.error?.message, 'STRIPE_EVENT_RETRY_REQUIRED');
        assert.notEqual(waiterOutcome.error?.code, '23505');
        await clients[1].query('ROLLBACK');
      }
    } finally {
      for (const client of clients) {
        await client.query('ROLLBACK').catch(() => undefined);
        client.release();
      }
    }

    if (isolation !== 'READ COMMITTED') {
      if (retryKind === 'exact') {
        assert.equal((await ingress.query(acceptSql, retryArgs)).rows[0].status, 'duplicate');
      } else {
        await assert.rejects(
          () => ingress.query(acceptSql, retryArgs),
          (error) => error?.code === 'P0001' && error?.message === 'STRIPE_EVENT_KEY_REUSED',
        );
      }
    }
    assert.equal((await bootstrap.query(
      `SELECT count(*)::integer AS count
         FROM roomscan.stripe_event_receipts_v2
        WHERE provider_account_id = 'acct_platform' AND event_id = $1`,
      [eventId],
    )).rows[0].count, 1);
  }

  for (const [isolation, retryKind, suffix] of [
    ['READ COMMITTED', 'exact', 'rcExact07'],
    ['READ COMMITTED', 'conflict', 'rcConflict07'],
    ['REPEATABLE READ', 'exact', 'rrExact07'],
    ['REPEATABLE READ', 'conflict', 'rrConflict07'],
    ['SERIALIZABLE', 'exact', 'serExact07'],
    ['SERIALIZABLE', 'conflict', 'serConflict07'],
  ]) {
    await runReceiptIsolationRace({ isolation, retryKind, suffix });
  }

  for (const [malformed, code] of [
    [['platform', 'acct_platform', 'cus_missing01', 'sub_workspaceA', 'evt_bad001', 'customer.subscription.updated', 'sub_workspaceA'], '42501'],
    [['platform', 'acct_platform', 'cus_workspaceA', 'sub_workspaceB', 'evt_bad002', 'customer.subscription.updated', 'sub_workspaceB'], '42501'],
    [['connected', 'acct_platform', 'cus_workspaceA', 'sub_workspaceA', 'evt_bad003', 'customer.subscription.updated', 'sub_workspaceA'], '42501'],
    [['platform', 'acct_platform', 'cus_workspaceA', 'sub_workspaceA', 'evt_bad004', 'invoice.paid', 'sub_workspaceA'], '22023'],
    [['platform', 'acct_platform', 'cus_workspaceA', 'sub_workspaceA', 'evt_bad005', 'customer.subscription.updated', 'sub_other01'], '22023'],
    [['platform', 'acct_short-', 'cus_workspaceA', 'sub_workspaceA', 'evt_bad006', 'customer.subscription.updated', 'sub_workspaceA'], '22023'],
    [['platform', 'acct_platform', 'cus_bad-', 'sub_workspaceA', 'evt_bad007', 'customer.subscription.updated', 'sub_workspaceA'], '22023'],
    [['platform', 'acct_platform', 'cus_workspaceA', 'sub_bad-', 'evt_bad008', 'customer.subscription.updated', 'sub_bad-'], '22023'],
  ]) {
    await expectCode(() => ingress.query(acceptSql, [...malformed, hash32(`bad-${malformed[4]}`), now, now]), code);
  }

  for (const eventId of [
    'event_abcdef', 'EVT_abcdef', 'evt_abcde', 'evt_abcdef-', 'evt_abc/def',
  ]) {
    await expectCode(
      () => ingress.query(acceptSql, [
        'platform', 'acct_platform', 'cus_workspaceA', 'sub_workspaceA',
        eventId, 'customer.subscription.updated', 'sub_workspaceA',
        hash32(`malformed-event-id-${eventId}`), now, now,
      ]),
      '22023',
    );
  }

  assert.equal(stripeIdConstraints.length, 11);
  for (const tableName of [
    'stripe_provider_accounts', 'stripe_billing_bindings',
    'stripe_event_receipts_v2',
    'stripe_reconciliation_outbox',
  ]) {
    const definitions = stripeIdConstraints
      .filter((row) => row.table_name === tableName)
      .map((row) => row.definition).join('\n');
    assert.match(definitions, /\^acct_\[A-Za-z0-9\]\{6,255\}\$/u);
    if (tableName !== 'stripe_provider_accounts') {
      assert.match(definitions, /\^cus_\[A-Za-z0-9\]\{6,255\}\$/u);
      assert.match(definitions, /\^sub_\[A-Za-z0-9\]\{6,255\}\$/u);
    }
    if (tableName === 'stripe_event_receipts_v2') {
      assert.match(definitions, /\^evt_\[A-Za-z0-9\]\{6,255\}\$/u);
    }
  }

  const concurrent = await Promise.all(Array.from({ length: 6 }, () => ingress.query(acceptSql, [
    'platform', 'acct_platform', 'cus_workspaceA', 'sub_workspaceA', 'evt_eventA2',
    'customer.subscription.updated', 'sub_workspaceA', hash32('event-a2'), now, new Date(now.getTime() + 2_000),
  ])));
  assert.equal(concurrent.filter(({ rows }) => rows[0]?.status === 'accepted').length, 1);
  assert.equal(concurrent.filter(({ rows }) => rows[0]?.status === 'duplicate').length, 5);
  assert.equal((await bootstrap.query(
    `SELECT count(*)::int AS count FROM roomscan.stripe_event_receipts_v2
      WHERE provider_account_id = 'acct_platform' AND event_id = 'evt_eventA2'`,
  )).rows[0].count, 1);

  const conflictingEventId = 'evt_bindingrace';
  const conflictRace = await Promise.allSettled([
    ingress.query(acceptSql, [
      'platform', 'acct_platform', 'cus_workspaceA', 'sub_workspaceA', conflictingEventId,
      'customer.subscription.updated', 'sub_workspaceA', hash32('binding-race-a'), now,
      new Date(now.getTime() + 2_100),
    ]),
    ingress.query(acceptSql, [
      'platform', 'acct_platform', 'cus_workspaceB', 'sub_workspaceB', conflictingEventId,
      'customer.subscription.updated', 'sub_workspaceB', hash32('binding-race-b'), now,
      new Date(now.getTime() + 2_100),
    ]),
  ]);
  assert.equal(conflictRace.filter(({ status }) => status === 'fulfilled').length, 1);
  const conflictRejections = conflictRace.filter(({ status }) => status === 'rejected');
  assert.equal(conflictRejections.length, 1);
  assert.equal(conflictRejections[0].reason?.code, 'P0001');
  assert.equal(conflictRejections[0].reason?.message, 'STRIPE_EVENT_KEY_REUSED');
  assert.equal((await bootstrap.query(
    `SELECT count(*)::int AS count FROM roomscan.stripe_event_receipts_v2
      WHERE provider_account_id = 'acct_platform' AND event_id = $1`,
    [conflictingEventId],
  )).rows[0].count, 1);

  for (const [account, customer, subscription] of [
    ['acct_invalid-', 'cus_workspaceA', 'sub_workspaceA'],
    ['acct_platform', 'cus_invalid-', 'sub_workspaceA'],
    ['acct_platform', 'cus_workspaceA', 'sub_invalid-'],
  ]) {
    await expectCode(
      () => reconciler.query(
        `SELECT roomscan.release_stripe_reconciliation_v2(
           'scope_invalid_lease', $1, $2, $3, $4, 1, $5
         )`, ['platform', account, customer, subscription, now],
      ),
      '22023',
    );
    await expectCode(
      () => reconciler.query(
        `SELECT * FROM roomscan.complete_stripe_reconciliation_v2(
           'scope_invalid_lease', 'platform', $1, $2, $3, 1, $4,
           'active', 'test-only', NULL, $4, 1, 1
         )`, [account, customer, subscription, now],
      ),
      '22023',
    );
  }

  const claimSql = `SELECT * FROM roomscan.claim_stripe_reconciliation_v2($1, $2::timestamptz, $3::timestamptz)`;
  const claimed = [];
  for (let index = 0; index < 3; index += 1) {
    const row = (await reconciler.query(claimSql, [`scope_lease_${index}`, new Date(now.getTime() + 3_000), new Date(now.getTime() + 33_000)])).rows[0];
    assert.ok(row);
    claimed.push(row);
  }
  assert.equal(new Set(claimed.map((row) => row.workspace_id)).size, 3);
  for (const row of claimed) {
    assert.ok(row.account_mode === 'platform' || row.account_mode === 'connected');
    assert.match(row.provider_account_id, /^acct_/u);
    assert.match(row.billing_customer_id, /^cus_/u);
    assert.match(row.subscription_id, /^sub_/u);
    assert.equal(row.hosted_global_version, '1');
    assert.equal(row.hosted_workspace_version, '1');
  }
  const scopeA = claimed.find((row) => row.workspace_id === ids.workspaceA);
  const scopeB = claimed.find((row) => row.workspace_id === ids.workspaceB);
  assert.deepEqual([scopeA.account_mode, scopeA.provider_account_id, scopeA.billing_customer_id, scopeA.subscription_id], ['platform', 'acct_platform', 'cus_workspaceA', 'sub_workspaceA']);
  assert.deepEqual([scopeB.account_mode, scopeB.provider_account_id, scopeB.billing_customer_id, scopeB.subscription_id], ['platform', 'acct_platform', 'cus_workspaceB', 'sub_workspaceB']);

  console.log('INTEGRATION_0007_STRIPE_BINDING_SCOPE_SUMMARY schema_regex_constraints=11 platform_workspaces=2 connected_controls=2 binding_conflicts=5 symmetric_binding_race_calls=2 isolation_mixed_mode_races=4 direct_storage_mode_denials=1 canonical_id_denials=21 acceptance_denials=13 concurrent_exact_receipts=6 concurrent_conflicting_receipts=2 receipt_isolation_races=6 receipt_fresh_retry_controls=4 scoped_claims=3 status=pass');
} finally {
  if (ingress) await ingress.end();
  if (reconciler) await reconciler.end();
  await bootstrap.end();
  const cleanup = await cluster.stop();
  console.log(`PG_CLEANUP ${JSON.stringify(cleanup)}`);
}
