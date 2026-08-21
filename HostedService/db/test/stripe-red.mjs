import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { accepted0006MigrationsDir } from './accepted-0006-migrations.mjs';
import { withTenantTransaction } from '../runtime.mjs';
import { appPoolConfig, hash32, ids, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const cluster = await startPostgresCluster();
const bootstrapPool = new Pool(cluster.bootstrapConfig);
let appPool;

const context = {
  principalId: ids.principalA,
  requestedWorkspaceId: ids.workspaceA,
  expectedAuthorizationVersion: 1,
};
const contextB = {
  principalId: ids.principalB,
  requestedWorkspaceId: ids.workspaceB,
  expectedAuthorizationVersion: 1,
};

async function inTenant(operation) {
  return await withTenantTransaction(appPool, context, operation);
}

async function inWorkspace(contextValue, operation) {
  return await withTenantTransaction(appPool, contextValue, operation);
}

try {
  await applyMigrations({ pool: bootstrapPool, migrationsDir: accepted0006MigrationsDir });
  await seedCoreFixtures(bootstrapPool);
  appPool = new Pool(appPoolConfig(cluster, 4));

  await assert.rejects(
    () => inTenant((client) => client.query(
      `SELECT roomscan.record_stripe_event($1, $2, $3, NULL, $4::timestamptz) AS inserted`,
      ['acct_a', 'evt_null_signature', hash32('null-signature'), '2026-08-18T09:59:00Z'],
    )),
    (error) => error?.code === 'P0001' && error?.message === 'STRIPE_SIGNATURE_UNVERIFIED',
    'a nullable signature decision must fail closed unless it is literal SQL TRUE',
  );
  await assert.rejects(
    () => inTenant((client) => client.query(
      `SELECT roomscan.record_stripe_event($1, $2, $3, false, $4::timestamptz) AS inserted`,
      ['acct_a', 'evt_forged', hash32('forged'), '2026-08-18T10:00:00Z'],
    )),
    (error) => error?.code === 'P0001' && error?.message === 'STRIPE_SIGNATURE_UNVERIFIED',
  );
  assert.equal(
    await inTenant(async (client) => (
      await client.query('SELECT count(*)::int AS count FROM roomscan.stripe_event_receipts')
    ).rows[0].count),
    0,
  );

  const inserted = await inTenant(async (client) => (
    await client.query(
      `SELECT roomscan.record_stripe_event($1, $2, $3, true, $4::timestamptz) AS inserted`,
      ['acct_a', 'evt_new', hash32('new'), '2026-08-18T11:00:00Z'],
    )
  ).rows[0].inserted);
  const duplicate = await inTenant(async (client) => (
    await client.query(
      `SELECT roomscan.record_stripe_event($1, $2, $3, true, $4::timestamptz) AS inserted`,
      ['acct_a', 'evt_new', hash32('new'), '2026-08-18T11:00:00Z'],
    )
  ).rows[0].inserted);
  assert.equal(inserted, true);
  assert.equal(duplicate, false);
  const durableReceipt = await inTenant(async (client) => (
    await client.query(
      `SELECT provider_account_id, event_id, encode(payload_sha256, 'hex') AS payload_sha256,
              signature_verified, provider_occurred_at
       FROM roomscan.stripe_event_receipts
       WHERE provider_account_id = $1 AND event_id = $2`,
      ['acct_a', 'evt_new'],
    )
  ).rows[0]);
  assert.deepEqual(durableReceipt, {
    provider_account_id: 'acct_a',
    event_id: 'evt_new',
    payload_sha256: hash32('new').toString('hex'),
    signature_verified: true,
    provider_occurred_at: new Date('2026-08-18T11:00:00Z'),
  });
  await assert.rejects(
    () => inTenant((client) => client.query(
      `SELECT roomscan.record_stripe_event($1, $2, $3, true, $4::timestamptz)`,
      ['acct_a', 'evt_new', hash32('conflicting-duplicate'), '2026-08-18T11:00:00Z'],
    )),
    (error) => error?.code === 'P0001' && error?.message === 'STRIPE_EVENT_KEY_REUSED',
  );
  await assert.rejects(
    () => inTenant((client) => client.query(
      `SELECT roomscan.record_stripe_event($1, $2, $3, true, $4::timestamptz)`,
      ['acct_a', 'evt_new', hash32('new'), '2026-08-18T11:00:01Z'],
    )),
    (error) => error?.code === 'P0001' && error?.message === 'STRIPE_EVENT_KEY_REUSED',
  );

  const receiptRace = await Promise.all([
    inTenant(async (client) => (await client.query(
      `SELECT roomscan.record_stripe_event($1,$2,$3,true,$4::timestamptz) AS inserted`,
      ['acct_a', 'evt_concurrent', hash32('concurrent'), '2026-08-18T11:30:00Z'],
    )).rows[0].inserted),
    inTenant(async (client) => (await client.query(
      `SELECT roomscan.record_stripe_event($1,$2,$3,true,$4::timestamptz) AS inserted`,
      ['acct_a', 'evt_concurrent', hash32('concurrent'), '2026-08-18T11:30:00Z'],
    )).rows[0].inserted),
  ]);
  assert.deepEqual(receiptRace.sort(), [false, true]);

  await inTenant((client) => client.query(
    `SELECT roomscan.record_stripe_event($1,$2,$3,true,$4::timestamptz)`,
    ['acct_shared', 'evt_shared', hash32('shared'), '2026-08-18T11:45:00Z'],
  ));
  await assert.rejects(
    () => inWorkspace(contextB, (client) => client.query(
      `SELECT roomscan.record_stripe_event($1,$2,$3,true,$4::timestamptz)`,
      ['acct_shared', 'evt_shared', hash32('shared'), '2026-08-18T11:45:00Z'],
    )),
    (error) => error?.code === 'P0001' && error?.message === 'STRIPE_EVENT_KEY_REUSED',
  );
  assert.equal(await inWorkspace(contextB, async (client) => (await client.query(
    `SELECT roomscan.record_stripe_event($1,$2,$3,true,$4::timestamptz) AS inserted`,
    ['acct_b', 'evt_b', hash32('tenant-b'), '2026-08-18T11:50:00Z'],
  )).rows[0].inserted), true);

  await inTenant((client) => client.query(
    `SELECT roomscan.record_stripe_event($1, $2, $3, true, $4::timestamptz)`,
    ['acct_a', 'evt_old', hash32('old'), '2026-08-17T11:00:00Z'],
  ));
  const beforeReconciliation = await inTenant(async (client) => (
    await client.query(
      `SELECT plan_key, status, reconciliation_generation
       FROM roomscan.subscription_states`,
    )
  ).rows[0]);
  assert.deepEqual(beforeReconciliation, {
    plan_key: 'starter',
    status: 'active',
    reconciliation_generation: '0',
  });

  const applied = await inTenant(async (client) => (
    await client.query(
      `SELECT roomscan.apply_stripe_reconciliation(
        2, $1::timestamptz, 'active', 'professional', $2::timestamptz
      ) AS applied`,
      ['2026-08-18T12:00:00Z', '2026-09-18T12:00:00Z'],
    )
  ).rows[0].applied);
  const retry = await inTenant(async (client) => (
    await client.query(
      `SELECT roomscan.apply_stripe_reconciliation(
        2, $1::timestamptz, 'active', 'professional', $2::timestamptz
      ) AS applied`,
      ['2026-08-18T12:00:00Z', '2026-09-18T12:00:00Z'],
    )
  ).rows[0].applied);
  assert.equal(applied, true);
  assert.equal(retry, true);

  const staleGeneration = await inTenant(async (client) => (
    await client.query(
      `SELECT roomscan.apply_stripe_reconciliation(
        1, $1::timestamptz, 'canceled', 'none', NULL
      ) AS applied`,
      ['2026-08-18T13:00:00Z'],
    )
  ).rows[0].applied);
  const staleSnapshot = await inTenant(async (client) => (
    await client.query(
      `SELECT roomscan.apply_stripe_reconciliation(
        3, $1::timestamptz, 'canceled', 'none', NULL
      ) AS applied`,
      ['2026-08-18T11:59:59Z'],
    )
  ).rows[0].applied);
  assert.equal(staleGeneration, false);
  assert.equal(staleSnapshot, false);

  const state = await inTenant(async (client) => (
    await client.query(
      `SELECT plan_key, status, reconciliation_generation, source_observed_at
       FROM roomscan.subscription_states`,
    )
  ).rows[0]);
  assert.equal(state.plan_key, 'professional');
  assert.equal(state.status, 'active');
  assert.equal(state.reconciliation_generation, '2');
  assert.equal(new Date(state.source_observed_at).toISOString(), '2026-08-18T12:00:00.000Z');

  await assert.rejects(
    () => inTenant((client) => client.query(
      `SELECT roomscan.apply_stripe_reconciliation(
        2, $1::timestamptz, 'canceled', 'none', NULL
      )`,
      ['2026-08-18T12:00:00Z'],
    )),
    (error) => error?.code === 'P0001' && error?.message === 'RECONCILIATION_GENERATION_REUSED',
  );

  await inTenant((client) => client.query(
    `SELECT roomscan.apply_stripe_reconciliation(
      4, $1::timestamptz, 'read_only_grace', 'none', $2::timestamptz
    )`,
    ['2026-08-18T14:00:00Z', '2026-09-17T14:00:00Z'],
  ));

  await bootstrapPool.query(`
    CREATE FUNCTION public.test_delay_stripe_reconciliation_insert()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $function$
    BEGIN
      PERFORM pg_sleep(0.1);
      RETURN NEW;
    END
    $function$;
    CREATE TRIGGER test_delay_stripe_reconciliation_insert
    BEFORE INSERT ON roomscan.stripe_reconciliation_generations
    FOR EACH ROW EXECUTE FUNCTION public.test_delay_stripe_reconciliation_insert()
  `);
  const concurrentRetry = await Promise.allSettled([
    inTenant((client) => client.query(
      `SELECT roomscan.apply_stripe_reconciliation(
        5, $1::timestamptz, 'active', 'professional', $2::timestamptz
      ) AS applied`,
      ['2026-08-18T15:00:00Z', '2026-09-18T15:00:00Z'],
    )),
    inTenant((client) => client.query(
      `SELECT roomscan.apply_stripe_reconciliation(
        5, $1::timestamptz, 'active', 'professional', $2::timestamptz
      ) AS applied`,
      ['2026-08-18T15:00:00Z', '2026-09-18T15:00:00Z'],
    )),
  ]);
  assert.equal(
    concurrentRetry.filter(({ status }) => status === 'fulfilled').length,
    2,
    'concurrent retry of one reconciliation generation must be idempotent',
  );
  assert.ok(concurrentRetry.every(
    ({ status, value }) => status === 'fulfilled' && value.rows[0].applied === true,
  ));
  assert.equal(
    await inTenant(async (client) => (
      await client.query('SELECT count(*)::int AS count FROM roomscan.projects')
    ).rows[0].count),
    1,
  );
  assert.equal(
    await inTenant(async (client) => (
      await client.query('SELECT count(*)::int AS count FROM roomscan.stripe_event_receipts')
    ).rows[0].count),
    4,
  );
  assert.equal(await inWorkspace(contextB, async (client) => (
    await client.query('SELECT count(*)::int AS count FROM roomscan.stripe_event_receipts')
  ).rows[0].count), 1);
  console.log('STRIPE_TEST_SUMMARY null_signature=true forged=true durable_receipt=true duplicate=true conflicts=true cross_tenant=true receipt_race=true reconciliation_retry=true status=pass');
} finally {
  await appPool?.end();
  await bootstrapPool.end();
  const cleanup = await cluster.stop();
  console.error(`CLEANUP ${JSON.stringify(cleanup)}`);
}
