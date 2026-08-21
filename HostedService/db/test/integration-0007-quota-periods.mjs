import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { appPoolConfig, hash32, ids, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const cluster = await startPostgresCluster();
const bootstrapPool = new Pool(cluster.bootstrapConfig);
let apiPool;

async function expectCode(work, code) {
  await assert.rejects(work, (error) => error?.code === code);
}

async function setFlag(scope, workspaceId, flag, auditSuffix) {
  return (await bootstrapPool.query(
    `SELECT * FROM roomscan.set_operational_flag(
       $1, $2::uuid, $3, true, NULL, 'quota integration',
       $4, '2026-08-19T12:00:00.000Z'::timestamptz
     )`,
    [scope, workspaceId, flag, `ofaud_${auditSuffix}`],
  )).rows[0];
}

try {
  await applyMigrations({ pool: bootstrapPool });
  await seedCoreFixtures(bootstrapPool);
  const now = new Date('2026-08-19T12:00:00.000Z');

  const tableRows = (await bootstrapPool.query(
    `SELECT c.relname, c.relrowsecurity, c.relforcerowsecurity
       FROM pg_class AS c JOIN pg_namespace AS n ON n.oid = c.relnamespace
      WHERE n.nspname = 'roomscan' AND c.relname = ANY($1::text[])
      ORDER BY c.relname`,
    [[
      'quota_ledger_v2', 'quota_policy_versions_v2',
      'quota_reconciliations_v2', 'quota_reservations_v2', 'quota_usage_v2',
    ]],
  )).rows;
  assert.deepEqual(tableRows, [
    'quota_ledger_v2', 'quota_policy_versions_v2', 'quota_reconciliations_v2',
    'quota_reservations_v2', 'quota_usage_v2',
  ].map((relname) => ({ relname, relrowsecurity: true, relforcerowsecurity: true })));

  await bootstrapPool.query('SET ROLE roomscan_operator');
  await setFlag('global', null, 'hosted_operations_enabled', 'quota_global_hosted');
  await setFlag('workspace', ids.workspaceA, 'hosted_operations_enabled', 'quota_workspace_hosted');
  await setFlag('global', null, 'publication_enabled', 'quota_global_publication');
  await setFlag('workspace', ids.workspaceA, 'publication_enabled', 'quota_workspace_publication');
  await bootstrapPool.query(
    `SELECT * FROM roomscan.set_workspace_publishing_policy(
       $1, true, NULL, 'quota integration', 'ofaud_quota_publishpolicy', $2
     )`,
    [ids.workspaceA, now],
  );
  const activated = (await bootstrapPool.query(
    `SELECT * FROM roomscan.activate_quota_policy_v2(
       $1, 1, 'roomscan-quota-policy-v1', 'test-only',
       'roomscan-period-v1:test-period-a',
       1, 2, 1, 2, 3, 80, 1, 1, $2
     )`,
    [ids.workspaceA, now],
  )).rows[0];
  assert.deepEqual(activated, { policy_version: '1', authoritative_active_member_count: '2' });
  await bootstrapPool.query('RESET ROLE');

  const memberUsage = (await bootstrapPool.query(
    `SELECT used, reserved, period_key FROM roomscan.quota_usage_v2
      WHERE workspace_id = $1 AND metric = 'member_count'`,
    [ids.workspaceA],
  )).rows[0];
  assert.deepEqual(memberUsage, {
    used: '2', reserved: '0', period_key: 'roomscan-period-v1:lifetime',
  });

  const familyId = '63000000-0000-4000-8000-000000000072';
  const accessHash = hash32('quota-0007-owner-a');
  await bootstrapPool.query(
    `INSERT INTO roomscan.auth_session_families (
       id, public_id, principal_id, authentication_epoch, authenticated_at,
       last_used_at, inactivity_expires_at, absolute_expires_at, policy_version,
       workspace_id, role, authorization_version, state, created_at
     ) VALUES ($1, 'fam_quota0007ownera', $2, 0, $3::timestamptz, $3::timestamptz,
       $3::timestamptz + interval '1 day', $3::timestamptz + interval '7 days', 'session-v1',
       $4, 'owner', 1, 'active', $3::timestamptz)`,
    [familyId, ids.principalA, now, ids.workspaceA],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.auth_access_tokens (
       id, family_id, token_hash, expires_at, principal_id,
       authentication_epoch, authenticated_at, issued_at,
       workspace_id, role, authorization_version, state, created_at
     ) VALUES (gen_random_uuid(), $1, $2, $3::timestamptz + interval '1 hour', $4,
       0, $3::timestamptz, $3::timestamptz, $5, 'owner', 1, 'active', $3::timestamptz)`,
    [familyId, accessHash, now, ids.principalA, ids.workspaceA],
  );
  apiPool = new Pool({
    ...appPoolConfig(cluster, 4), user: 'roomscan_api_runtime',
    application_name: 'rss-0007-quota-periods',
  });

  const reserveArgs = [
    accessHash, now, 'project_count', 'roomscan-period-v1:lifetime',
    'project.create', null, null, 1, 'project-key', 1,
    new Date(now.getTime() + 30_000), 1, 1, null, null,
  ];
  const reserveSql = `SELECT * FROM roomscan.reserve_quota_v2(
    $1::bytea, $2::timestamptz, $3::roomscan.quota_metric, $4, $5,
    $6, $7, $8::bigint, $9, $10::bigint, $11::timestamptz,
    $12::bigint, $13::bigint, $14::bigint, $15::bigint
  )`;
  const first = (await apiPool.query(reserveSql, reserveArgs)).rows[0];
  assert.equal(first.state, 'reserved');
  assert.equal(first.workspace_id, ids.workspaceA);
  assert.deepEqual((await apiPool.query(reserveSql, reserveArgs)).rows[0], first);
  await expectCode(
    () => apiPool.query(reserveSql, [...reserveArgs.slice(0, 8), 'project-key', 1,
      new Date(now.getTime() + 31_000), ...reserveArgs.slice(11)]),
    'P0001',
  );
  await expectCode(
    () => apiPool.query(reserveSql, [...reserveArgs.slice(0, 8), 'second-key', ...reserveArgs.slice(9)]),
    'P0001',
  );

  const finalized = (await apiPool.query(
    `SELECT * FROM roomscan.finalize_quota_v2(
       $1, $2, 'roomscan-period-v1:lifetime', 'project-key', 1,
       1, 1, NULL, NULL
     )`,
    [accessHash, new Date(now.getTime() + 1_000)],
  )).rows[0];
  assert.equal(finalized.state, 'finalized');

  const raceResults = await Promise.allSettled([
    apiPool.query(reserveSql, [
      accessHash, now, 'working_bytes', 'roomscan-period-v1:lifetime',
      'project.revise', 'project', ids.projectA, 1, 'race-a', 1,
      new Date(now.getTime() + 30_000), 1, 1, null, null,
    ]),
    apiPool.query(reserveSql, [
      accessHash, now, 'working_bytes', 'roomscan-period-v1:lifetime',
      'project.revise', 'project', ids.projectA, 1, 'race-b', 1,
      new Date(now.getTime() + 30_000), 1, 1, null, null,
    ]),
  ]);
  assert.equal(raceResults.filter(({ status }) => status === 'fulfilled').length, 1);
  assert.equal(raceResults.filter(({ status }) => status === 'rejected').length, 1);

  await bootstrapPool.query('SET ROLE roomscan_operator');
  const reconciled = (await bootstrapPool.query(
    `SELECT * FROM roomscan.reconcile_quota_v2(
       $1, 'project_count', 'roomscan-period-v1:lifetime', 1, 0,
       1, 1, $2
     )`,
    [ids.workspaceA, new Date(now.getTime() + 2_000)],
  )).rows[0];
  assert.deepEqual(reconciled, { applied: true, used: '0', reconciliation_generation: '1' });
  const retry = (await bootstrapPool.query(
    `SELECT * FROM roomscan.reconcile_quota_v2(
       $1, 'project_count', 'roomscan-period-v1:lifetime', 1, 0,
       1, 1, $2
     )`,
    [ids.workspaceA, new Date(now.getTime() + 2_000)],
  )).rows[0];
  assert.deepEqual(retry, reconciled);
  await expectCode(
    () => bootstrapPool.query(
      `SELECT * FROM roomscan.reconcile_quota_v2(
         $1, 'project_count', 'roomscan-period-v1:lifetime', 1, 1,
         1, 1, $2
       )`,
      [ids.workspaceA, new Date(now.getTime() + 2_000)],
    ),
    'P0001',
  );
  await bootstrapPool.query('RESET ROLE');

  assert.equal(Number((await bootstrapPool.query(
    `SELECT count(*)::integer AS count FROM roomscan.quota_ledger_v2
      WHERE workspace_id = $1`,
    [ids.workspaceA],
  )).rows[0].count) >= 4, true);

  for (const role of [
    'roomscan_api_runtime', 'roomscan_authorizer_runtime',
    'roomscan_auth_challenge_runtime', 'roomscan_stripe_ingress_runtime',
    'roomscan_stripe_reconciliation_runtime', 'roomscan_audit_export_runtime',
    'roomscan_email_delivery_runtime',
  ]) {
    for (const table of [
      'quota_policy_versions_v2', 'quota_usage_v2', 'quota_reservations_v2',
      'quota_ledger_v2', 'quota_reconciliations_v2',
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
    'INTEGRATION_0007_QUOTA_PERIODS_SUMMARY forced_rls_tables=5 activation_controls=2 '
      + 'reservation_controls=6 concurrency_winners=1 reconciliation_controls=3 '
      + 'protected_acl_pairs=35 history_controls=1 status=pass',
  );
} finally {
  if (apiPool) await apiPool.end();
  await bootstrapPool.end();
  const cleanup = await cluster.stop();
  console.log(`PG_CLEANUP ${JSON.stringify(cleanup)}`);
}
