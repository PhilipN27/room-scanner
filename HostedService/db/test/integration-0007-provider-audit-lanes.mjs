import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { appPoolConfig } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const cluster = await startPostgresCluster();
const bootstrap = new Pool(cluster.bootstrapConfig);
const runtimeRoles = [
  'roomscan_api_runtime',
  'roomscan_authorizer_runtime',
  'roomscan_auth_challenge_runtime',
  'roomscan_stripe_ingress_runtime',
  'roomscan_stripe_reconciliation_runtime',
  'roomscan_audit_export_runtime',
  'roomscan_email_delivery_runtime',
];
const pools = new Map();
const routine = 'roomscan.accept_provider_audit_event(text,text,text,text,timestamp with time zone)';
const acceptSql = `SELECT roomscan.accept_provider_audit_event(
  $1, $2, $3, $4, $5::timestamptz
) AS inserted`;
const now = new Date('2026-08-19T22:00:00.000Z');

async function expectDatabaseError(work, code, message) {
  await assert.rejects(work, (error) => error?.code === code
    && (message === undefined || error?.message === message));
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
  assert.fail(`timed out waiting for provider-audit advisory waiter ${applicationName}`);
}

try {
  await applyMigrations({ pool: bootstrap });
  for (const role of runtimeRoles) {
    pools.set(role, new Pool({
      ...appPoolConfig(cluster, 4), user: role, max: 4,
      application_name: `rss-0007-provider-audit-${role}`,
    }));
  }

  const executableRoles = [];
  for (const role of runtimeRoles) {
    const allowed = (await bootstrap.query(
      `SELECT has_function_privilege($1, $2, 'EXECUTE') AS allowed`,
      [role, routine],
    )).rows[0].allowed;
    if (allowed) executableRoles.push(role);
  }
  assert.deepEqual(executableRoles, [
    'roomscan_stripe_ingress_runtime', 'roomscan_email_delivery_runtime',
  ]);

  for (const role of runtimeRoles.filter((candidate) =>
    !executableRoles.includes(candidate))) {
    await expectDatabaseError(
      () => pools.get(role).query(acceptSql, [
        `paud_denied_${role.replaceAll('roomscan_', '').replaceAll('_runtime', '')}_0007`,
        'stripe', 'stripe.webhook.accepted', 'evt_denied0007', now,
      ]),
      '42501',
    );
  }

  const stripe = pools.get('roomscan_stripe_ingress_runtime');
  const email = pools.get('roomscan_email_delivery_runtime');
  assert.equal((await stripe.query(acceptSql, [
    'paud_stripeaccepted0007', 'stripe', 'stripe.webhook.accepted',
    'evt_provideraudit0007', now,
  ])).rows[0].inserted, true);
  assert.equal((await stripe.query(acceptSql, [
    'paud_stripeaccepted0007', 'stripe', 'stripe.webhook.accepted',
    'evt_provideraudit0007', new Date(now.getTime() + 1_000),
  ])).rows[0].inserted, false);
  assert.equal((await stripe.query(acceptSql, [
    'paud_stripeduplicate007', 'stripe', 'stripe.webhook.duplicate',
    'evt_provideraudit0007', new Date(now.getTime() + 2_000),
  ])).rows[0].inserted, true);

  assert.equal((await email.query(acceptSql, [
    'paud_emailaccepted0007', 'email', 'email.delivery.accepted',
    'magic-delivery-0007', now,
  ])).rows[0].inserted, true);
  assert.equal((await email.query(acceptSql, [
    'paud_emailfailed000007', 'email', 'email.delivery.failed',
    'magic-delivery-0007', new Date(now.getTime() + 1_000),
  ])).rows[0].inserted, true);

  for (const [pool, args] of [
    [stripe, ['paud_crosslanestripe07', 'email', 'email.delivery.accepted', 'cross-lane', now]],
    [stripe, ['paud_crosscodestripe07', 'stripe', 'stripe.reconciliation.applied', 'cross-code', now]],
    [email, ['paud_crosslaneemail007', 'stripe', 'stripe.webhook.accepted', 'cross-lane', now]],
    [email, ['paud_crosscodeemail007', 'email', 'email.challenge.accepted', 'cross-code', now]],
  ]) {
    await expectDatabaseError(
      () => pool.query(acceptSql, args),
      '22023', 'INVALID_PROVIDER_AUDIT_EVENT',
    );
  }

  for (const changedArgs of [
    ['paud_stripeaccepted0007', 'stripe', 'stripe.webhook.duplicate', 'evt_provideraudit0007', now],
    ['paud_stripeaccepted0007', 'stripe', 'stripe.webhook.accepted', 'evt_changed0007', now],
  ]) {
    await expectDatabaseError(
      () => stripe.query(acceptSql, changedArgs),
      'P0001', 'PROVIDER_AUDIT_ID_REUSED',
    );
  }

  const exactRace = await Promise.all(Array.from({ length: 4 }, (_, index) =>
    stripe.query(acceptSql, [
      'paud_striperaceexact07', 'stripe', 'stripe.webhook.accepted',
      'evt_raceexact0007', new Date(now.getTime() + index),
    ])));
  assert.equal(exactRace.filter(({ rows }) => rows[0].inserted).length, 1);
  assert.equal(exactRace.filter(({ rows }) => !rows[0].inserted).length, 3);

  const conflictRace = await Promise.allSettled([
    stripe.query(acceptSql, [
      'paud_striperaceconf07', 'stripe', 'stripe.webhook.accepted',
      'evt_raceconflictA', now,
    ]),
    stripe.query(acceptSql, [
      'paud_striperaceconf07', 'stripe', 'stripe.webhook.duplicate',
      'evt_raceconflictB', new Date(now.getTime() + 1),
    ]),
  ]);
  assert.equal(conflictRace.filter(({ status }) => status === 'fulfilled').length, 1);
  const conflictLoser = conflictRace.find(({ status }) => status === 'rejected');
  assert.equal(conflictLoser?.reason?.code, 'P0001');
  assert.equal(conflictLoser?.reason?.message, 'PROVIDER_AUDIT_ID_REUSED');

  const isolationOutcomes = [];
  for (const [isolation, retryKind, suffix] of [
    ['REPEATABLE READ', 'exact', 'rr_exact'],
    ['REPEATABLE READ', 'conflict', 'rr_conflict'],
    ['SERIALIZABLE', 'exact', 'serial_exact'],
    ['SERIALIZABLE', 'conflict', 'serial_conflict'],
  ]) {
    const eventId = `paud_iso_${suffix}_0007`;
    const firstArgs = [
      eventId, 'stripe', 'stripe.webhook.accepted',
      `evt_${suffix}0007`, now,
    ];
    const retryArgs = retryKind === 'exact'
      ? [...firstArgs.slice(0, 4), new Date(now.getTime() + 1_000)]
      : [
          eventId, 'stripe', 'stripe.webhook.duplicate',
          `evt_${suffix}changed`, new Date(now.getTime() + 1_000),
        ];
    const [writer, waiter] = await Promise.all([stripe.connect(), stripe.connect()]);
    const waiterName = `rss-provider-audit-${suffix}`;
    let waiterOutcome;
    try {
      await waiter.query(`SELECT pg_catalog.set_config('application_name', $1, false)`, [waiterName]);
      await Promise.all([
        writer.query(`BEGIN ISOLATION LEVEL ${isolation}`),
        waiter.query(`BEGIN ISOLATION LEVEL ${isolation}`),
      ]);
      const snapshots = await Promise.all([writer, waiter].map((client) => client.query(
        `SELECT pg_catalog.txid_current_snapshot()::text AS snapshot`,
      )));
      assert.equal(snapshots.every(({ rows }) => rows[0].snapshot.length > 0), true);
      assert.equal((await writer.query(acceptSql, firstArgs)).rows[0].inserted, true);

      const waiterPromise = waiter.query(acceptSql, retryArgs).then(
        (value) => ({ value }),
        (error) => ({ error }),
      );
      await waitForAdvisoryWaiter(waiterName);
      await writer.query('COMMIT');
      waiterOutcome = await waiterPromise;
      assert.equal(waiterOutcome.error?.code, '40001');
      assert.equal(waiterOutcome.error?.message, 'PROVIDER_AUDIT_RETRY_REQUIRED');
      assert.notEqual(waiterOutcome.error?.code, '23505');
      await waiter.query('ROLLBACK');
    } finally {
      await writer.query('ROLLBACK').catch(() => undefined);
      await waiter.query('ROLLBACK').catch(() => undefined);
      writer.release();
      waiter.release();
    }

    if (retryKind === 'exact') {
      assert.equal((await stripe.query(acceptSql, retryArgs)).rows[0].inserted, false);
    } else {
      await expectDatabaseError(
        () => stripe.query(acceptSql, retryArgs),
        'P0001', 'PROVIDER_AUDIT_ID_REUSED',
      );
    }
    isolationOutcomes.push(`${isolation}:${retryKind}:40001`);
  }
  assert.equal(isolationOutcomes.length, 4);

  for (const role of runtimeRoles) {
    await expectDatabaseError(
      () => pools.get(role).query(
        `INSERT INTO roomscan.provider_audit_outbox (
           id, provider_lane, event_code, bounded_reference, occurred_at
         ) VALUES (
           'paud_directdml0007', 'stripe', 'stripe.webhook.accepted',
           'evt_directdml0007', $1
         )`, [now],
      ),
      '42501',
    );
  }

  assert.deepEqual((await bootstrap.query(
    `SELECT id, provider_lane, event_code, bounded_reference, occurred_at
       FROM roomscan.provider_audit_outbox
      WHERE id = 'paud_stripeaccepted0007'`,
  )).rows[0], {
    id: 'paud_stripeaccepted0007', provider_lane: 'stripe',
    event_code: 'stripe.webhook.accepted', bounded_reference: 'evt_provideraudit0007',
    occurred_at: now,
  });

  console.log(
    'INTEGRATION_0007_PROVIDER_AUDIT_LANES_SUMMARY exact_execute_roles=2 '
      + 'execute_denials=5 lane_code_denials=4 stable_duplicates=1 conflicts=2 '
      + 'concurrent_exact_calls=4 concurrent_conflict_calls=2 direct_dml_denials=7 '
      + 'isolation_stale_snapshot_retries=4 fresh_retry_controls=4 '
      + 'durable_original_controls=5 status=pass',
  );
} finally {
  await Promise.all([...pools.values()].map((pool) => pool.end()));
  await bootstrap.end();
  const cleanup = await cluster.stop();
  console.log(`PG_CLEANUP ${JSON.stringify(cleanup)}`);
}
