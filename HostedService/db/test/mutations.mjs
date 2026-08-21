import assert from 'node:assert/strict';
import { cp, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { accepted0006MigrationsDir } from './accepted-0006-migrations.mjs';
import { appPoolConfig, hash32, ids, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const productionMigrationsDir = accepted0006MigrationsDir;
const productionMigrationRunnerPath = fileURLToPath(new URL('../migrate.mjs', import.meta.url));
const productionRuntimePath = fileURLToPath(new URL('../runtime.mjs', import.meta.url));
const migrationAdvisoryLockId = '7621846213719041';
const contextA = {
  principalId: ids.principalA,
  requestedWorkspaceId: ids.workspaceA,
  expectedAuthorizationVersion: 1,
};

async function mutateCopiedFile(sourceDir, relativeFile, before, after) {
  const root = await mkdtemp(path.join(tmpdir(), 'rss-mutation-'));
  const copyDir = path.join(root, 'migrations');
  await cp(sourceDir, copyDir, { recursive: true });
  const target = path.join(copyDir, relativeFile);
  const contents = await readFile(target, 'utf8');
  const occurrences = contents.split(before).length - 1;
  assert.equal(occurrences, 1, `mutation anchor must occur exactly once in ${relativeFile}`);
  await writeFile(target, contents.replace(before, after));
  return { root, migrationsDir: copyDir };
}

async function mutatedRuntime() {
  const root = await mkdtemp(path.join(tmpdir(), 'rss-runtime-mutation-'));
  const target = path.join(root, 'runtime.mjs');
  const contents = await readFile(productionRuntimePath, 'utf8');
  const occurrences = contents.split(', true)').length - 1;
  assert.equal(occurrences, 10, 'transaction-local set_config anchor count changed');
  await writeFile(target, contents.replaceAll(', true)', ', false)'));
  return { root, runtimePath: target };
}

async function mutatedRollbackRuntime() {
  const root = await mkdtemp(path.join(tmpdir(), 'rss-runtime-mutation-'));
  const target = path.join(root, 'runtime.mjs');
  const contents = await readFile(productionRuntimePath, 'utf8');
  const anchor = '  client.release(rollbackFailure);';
  assert.equal(contents.split(anchor).length - 1, 1, 'rollback eviction mutation anchor changed');
  await writeFile(
    target,
    contents.replace(anchor, '  client.release(); // MUTANT: uncertain transaction returned to pool'),
  );
  return { root, runtimePath: target };
}

async function mutatedMigrationRunner() {
  const root = await mkdtemp(path.join(tmpdir(), 'rss-migration-runner-mutation-'));
  const target = path.join(root, 'migrate.mjs');
  const contents = await readFile(productionMigrationRunnerPath, 'utf8');
  const lockBlock = `    await client.query('SELECT pg_advisory_lock($1::bigint)', [ADVISORY_LOCK_ID.toString()]);
    lockAcquired = true;

`;
  const revokeAnchor = "    await client.query('REVOKE ALL ON public.roomscan_schema_migrations FROM PUBLIC');\n";
  assert.equal(contents.split(lockBlock).length - 1, 1, 'migration lock mutation anchor changed');
  assert.equal(contents.split(revokeAnchor).length - 1, 1, 'migration ledger mutation anchor changed');
  const mutated = contents
    .replace(lockBlock, '')
    .replace(revokeAnchor, `${revokeAnchor}${lockBlock}`);
  await writeFile(target, mutated);
  return { root, migrationRunnerPath: target };
}

async function runOracle({
  migrationsDir = productionMigrationsDir,
  runtimePath = productionRuntimePath,
  mutateDatabase,
  oracle,
}) {
  const cluster = await startPostgresCluster();
  const bootstrapPool = new Pool(cluster.bootstrapConfig);
  let appPool;
  let thrown;
  let cleanup;

  try {
    await applyMigrations({ pool: bootstrapPool, migrationsDir });
    await seedCoreFixtures(bootstrapPool);
    await mutateDatabase?.(bootstrapPool);
    appPool = new Pool(appPoolConfig(cluster, 6));
    const runtime = await import(`${pathToFileURL(runtimePath).href}?run=${Date.now()}-${Math.random()}`);
    await oracle({ cluster, bootstrapPool, appPool, runtime });
  } catch (error) {
    thrown = error;
  } finally {
    await appPool?.end();
    await bootstrapPool.end();
    cleanup = await cluster.stop();
  }

  if (thrown) {
    thrown.cleanupEvidence = cleanup;
    throw thrown;
  }
  return cleanup;
}

async function ownerForceOracle({ bootstrapPool }) {
  const client = await bootstrapPool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL ROLE roomscan_owner');
    await client.query("SELECT set_config('app.principal_id', $1, true)", [ids.principalA]);
    await client.query("SELECT set_config('app.tenant_id', $1, true)", [ids.workspaceA]);
    await client.query("SELECT set_config('app.authorization_version', '1', true)");
    const same = (await client.query(
      'SELECT count(*)::int AS count FROM roomscan.projects WHERE workspace_id = $1',
      [ids.workspaceA],
    )).rows[0].count;
    const cross = (await client.query(
      'SELECT count(*)::int AS count FROM roomscan.projects WHERE workspace_id = $1',
      [ids.workspaceB],
    )).rows[0].count;
    assert.equal(same, 1, 'owner same-tenant positive control failed');
    assert.equal(cross, 0, 'tenant-table owner leaked a cross-tenant project');
    await client.query('ROLLBACK');
  } finally {
    client.release();
  }
}

async function appIsolationOracle({ appPool, runtime }) {
  const counts = await runtime.withTenantTransaction(appPool, contextA, async (client) => ({
    same: (await client.query(
      'SELECT count(*)::int AS count FROM roomscan.projects WHERE workspace_id = $1',
      [ids.workspaceA],
    )).rows[0].count,
    cross: (await client.query(
      'SELECT count(*)::int AS count FROM roomscan.projects WHERE workspace_id = $1',
      [ids.workspaceB],
    )).rows[0].count,
  }));
  assert.equal(counts.same, 1, 'application same-tenant positive control failed');
  assert.equal(counts.cross, 0, 'application role leaked a cross-tenant project');
}

async function transactionLocalOracle({ cluster, runtime }) {
  const pool = new Pool(appPoolConfig(cluster, 1));
  try {
    await runtime.withTenantTransaction(pool, contextA, async (client) => {
      assert.equal((await client.query('SELECT count(*)::int AS count FROM roomscan.projects')).rows[0].count, 1);
    });
    const client = await pool.connect();
    try {
      assert.equal(
        (await client.query('SELECT count(*)::int AS count FROM roomscan.projects')).rows[0].count,
        0,
        'reused connection retained authoritative tenant context',
      );
    } finally {
      client.release();
    }
  } finally {
    await pool.end();
  }
}

async function rollbackQuarantineOracle({ runtime }) {
  const operationError = new Error('OPERATION_SENTINEL:mutation');
  const rollbackError = new Error('ROLLBACK_SENTINEL:mutation');
  const releaseArguments = [];
  const client = {
    async query(text) {
      if (text === 'ROLLBACK') {
        throw rollbackError;
      }
      return { rows: [] };
    },
    release(...args) {
      releaseArguments.push(args);
    },
  };
  let surfaced;
  try {
    await runtime.withPrincipalTransaction(
      { async connect() { return client; } },
      { principalId: ids.principalA },
      async () => { throw operationError; },
    );
  } catch (error) {
    surfaced = error;
  }
  assert.equal(surfaced, operationError, 'rollback quarantine replaced the operation error');
  assert.deepEqual(
    releaseArguments,
    [[rollbackError]],
    'failed rollback did not evict the uncertain pooled connection',
  );
}

async function quotaConcurrencyOracle({ appPool, runtime }) {
  await runtime.withTenantTransaction(appPool, contextA, (client) => client.query(
    'SELECT roomscan.activate_quota_policy(1, 1, 10, 10, 10, 10, 80)',
  ));
  const results = await Promise.allSettled([
    runtime.withTenantTransaction(appPool, contextA, (client) => client.query(
      "SELECT * FROM roomscan.reserve_quota('project_count', 1, 'race-a')",
    )),
    runtime.withTenantTransaction(appPool, contextA, (client) => client.query(
      "SELECT * FROM roomscan.reserve_quota('project_count', 1, 'race-b')",
    )),
  ]);
  assert.equal(
    results.filter(({ status }) => status === 'fulfilled').length,
    1,
    'one-unit-left race admitted more than one reservation',
  );
  assert.equal(
    results.filter(({ status, reason }) => status === 'rejected' && reason?.message === 'QUOTA_EXCEEDED').length,
    1,
    'one-unit-left race did not produce one quota denial',
  );
  const usage = await runtime.withTenantTransaction(appPool, contextA, async (client) => (
    await client.query(
      "SELECT used, reserved, limit_value FROM roomscan.quota_usage WHERE metric = 'project_count'",
    )
  ).rows[0]);
  assert.ok(Number(usage.used) + Number(usage.reserved) <= Number(usage.limit_value));
}

async function invitationAtomicOracle({ appPool, runtime }) {
  const results = await Promise.all([
    runtime.withPrincipalTransaction(appPool, { principalId: ids.principalExtraOwner }, async (client) => (
      await client.query('SELECT roomscan.consume_invitation($1) AS accepted', [
        hash32('invitation-a'),
      ])
    ).rows[0].accepted),
    runtime.withPrincipalTransaction(appPool, { principalId: ids.principalInvitee }, async (client) => (
      await client.query('SELECT roomscan.consume_invitation($1) AS accepted', [
        hash32('invitation-a'),
      ])
    ).rows[0].accepted),
  ]);
  assert.deepEqual(results.sort(), [false, true], 'invitation replay/concurrency produced multiple winners');
}

async function stripeSignatureOracle({ appPool, runtime }) {
  await assert.rejects(
    () => runtime.withTenantTransaction(appPool, contextA, (client) => client.query(
      `SELECT roomscan.record_stripe_event(
        'acct_mutation', 'evt_null_signature', $1, NULL, '2026-08-18T10:00:00Z'
      )`,
      [hash32('null-signature-mutation')],
    )),
    (error) => error?.code === 'P0001' && error?.message === 'STRIPE_SIGNATURE_UNVERIFIED',
    'NULL Stripe verification input bypassed the literal-TRUE guard',
  );
  assert.equal(await runtime.withTenantTransaction(appPool, contextA, async (client) => (
    await client.query('SELECT count(*)::int AS count FROM roomscan.stripe_event_receipts')
  ).rows[0].count), 0, 'rejected NULL signature left a durable receipt');
}

async function nullableReducerRetryOracle({ appPool, runtime }) {
  await runtime.withTenantTransaction(appPool, contextA, (client) => client.query(
    'SELECT roomscan.activate_quota_policy(1, 100, 100, 100, 100, 100, 80)',
  ));
  await runtime.withTenantTransaction(appPool, contextA, (client) => client.query(
    "SELECT * FROM roomscan.reserve_quota('project_count', 5, 'nullable-retry-mutation')",
  ));
  const before = await runtime.withTenantTransaction(appPool, contextA, async (client) => ({
    reservation: (await client.query(
      `SELECT metric, requested_amount, state, finalized_amount
       FROM roomscan.quota_reservations WHERE idempotency_key='nullable-retry-mutation'`,
    )).rows,
    usage: (await client.query(
      "SELECT used, reserved FROM roomscan.quota_usage WHERE metric='project_count'",
    )).rows,
    ledger: (await client.query(
      `SELECT action, metric, delta_used, delta_reserved
       FROM roomscan.quota_ledger WHERE idempotency_key='nullable-retry-mutation' ORDER BY action`,
    )).rows,
  }));
  await assert.rejects(
    () => runtime.withTenantTransaction(appPool, contextA, (client) => client.query(
      "SELECT * FROM roomscan.reserve_quota(NULL::roomscan.quota_metric, 5, 'nullable-retry-mutation')",
    )),
    (error) => error?.code === '22023' && error?.message === 'INVALID_QUOTA_RESERVATION',
    'NULL retry input bypassed the required-argument guard and exact comparison',
  );
  const after = await runtime.withTenantTransaction(appPool, contextA, async (client) => ({
    reservation: (await client.query(
      `SELECT metric, requested_amount, state, finalized_amount
       FROM roomscan.quota_reservations WHERE idempotency_key='nullable-retry-mutation'`,
    )).rows,
    usage: (await client.query(
      "SELECT used, reserved FROM roomscan.quota_usage WHERE metric='project_count'",
    )).rows,
    ledger: (await client.query(
      `SELECT action, metric, delta_used, delta_reserved
       FROM roomscan.quota_ledger WHERE idempotency_key='nullable-retry-mutation' ORDER BY action`,
    )).rows,
  }));
  assert.deepEqual(after, before, 'rejected nullable retry changed quota state');
}

async function authResolverMembershipOracle({ bootstrapPool, appPool }) {
  const now = new Date('2026-08-19T12:00:00.000Z');
  const familyId = '65000000-0000-4000-8000-000000000001';
  const accessHash = hash32('resolver-membership-mutation');
  await bootstrapPool.query(
    `INSERT INTO roomscan.auth_session_families (
       id, public_id, principal_id, authentication_epoch, authenticated_at,
       created_at, last_used_at, inactivity_expires_at, absolute_expires_at,
       policy_version, workspace_id, role, authorization_version
     ) VALUES ($1, 'family_resolver_mutant_01', $2, 0, $3, $3, $3,
       $3::timestamptz + interval '7 days',
       $3::timestamptz + interval '30 days', 'session-v1', $4, 'owner', 1)`,
    [familyId, ids.principalA, now, ids.workspaceA],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.auth_access_tokens (
       id, family_id, token_hash, expires_at, created_at, principal_id,
       authentication_epoch, authenticated_at, issued_at, workspace_id, role,
       authorization_version
     ) VALUES ('76000000-0000-4000-8000-000000000001', $1, $2,
       $3::timestamptz + interval '5 minutes', $3, $4, 0, $3, $3, $5,
       'owner', 1)`,
    [familyId, accessHash, now, ids.principalA, ids.workspaceA],
  );
  assert.equal((await appPool.query(
    `SELECT count(*)::int AS count FROM roomscan.resolve_access_context($1, $2)`,
    [accessHash, now],
  )).rows[0].count, 1, 'resolver same-membership positive control failed');
  await bootstrapPool.query(
    `INSERT INTO roomscan.memberships (workspace_id, principal_id, role, state)
     VALUES ($1, $2, 'owner', 'active')`,
    [ids.workspaceA, ids.principalExtraOwner],
  );
  await bootstrapPool.query(
    `UPDATE roomscan.memberships SET role = 'viewer'
     WHERE workspace_id = $1 AND principal_id = $2`,
    [ids.workspaceA, ids.principalA],
  );
  assert.equal((await appPool.query(
    `SELECT count(*)::int AS count FROM roomscan.resolve_access_context($1, $2)`,
    [accessHash, now],
  )).rows[0].count, 0, 'resolver accepted stale cached role/authorization version');
}

async function authNullGuardOracle({ appPool }) {
  await assert.rejects(
    () => appPool.query(
      `SELECT roomscan.claim_refresh_rotation(
         NULL::bytea, $1::bytea, $2::timestamptz
       )`,
      [hash32('auth-null-mutation-next'), new Date('2026-08-19T12:00:00.000Z')],
    ),
    (error) => error?.code === '22023' && error?.message === 'INVALID_REFRESH_ROTATION',
    'NULL refresh digest bypassed the fail-closed required-argument guard',
  );
}

async function notificationLeaseOracle({ appPool }) {
  const now = new Date('2026-08-19T12:00:00.000Z');
  await appPool.query(
    `INSERT INTO roomscan.security_notification_outbox (
       id, event_code, principal_id, identity_reference, created_at,
       policy_version
     ) VALUES ('notification_mutation_01', 'identity.linked', $1,
       'id_MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM', $2,
       'identity-link-v2')`,
    [ids.principalA, now],
  );
  assert.equal((await appPool.query(
    `SELECT lease_id FROM roomscan.claim_security_notification(
       'notification_mutation_01', 'notification_mutation_lease', $1, $2
     )`,
    [now, new Date(now.getTime() + 30_000)],
  )).rows[0].lease_id, 'notification_mutation_lease');
  assert.equal((await appPool.query(
    `SELECT roomscan.complete_security_notification(
       'notification_mutation_01', 'forged_lease', $1
     ) AS completed`,
    [new Date(now.getTime() + 1)],
  )).rows[0].completed, false, 'a forged notification lease completed durable work');
}

async function magicPolicyLockOracle({ bootstrapPool }) {
  const source = (await bootstrapPool.query(
    `SELECT p.prosrc
     FROM pg_proc AS p
     JOIN pg_namespace AS n ON n.oid = p.pronamespace
     WHERE n.nspname = 'roomscan' AND p.proname = 'lock_magic_policy_scope'`,
  )).rows[0]?.prosrc;
  assert.match(
    source ?? '',
    /pg_advisory_xact_lock/u,
    'magic issuance scope capability stopped acquiring a transaction lock',
  );
}

async function waitForMigrationWaiter(client, applicationName) {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    const count = (await client.query(
      `SELECT count(*)::int AS count
       FROM pg_stat_activity
       WHERE application_name = $1
         AND wait_event_type = 'Lock'
         AND lower(wait_event) = 'advisory'`,
      [applicationName],
    )).rows[0].count;
    if (count === 1) {
      return;
    }
    await delay(25);
  }
  throw new Error('Timed out waiting for mutated migration runner at the advisory-lock barrier');
}

async function migrationLockOracle(migrationRunnerPath) {
  const cluster = await startPostgresCluster();
  const barrierPool = new Pool({
    ...cluster.bootstrapConfig,
    max: 1,
    application_name: 'rss-migration-mutation-barrier',
  });
  const runnerPool = new Pool({
    ...cluster.bootstrapConfig,
    max: 1,
    application_name: 'rss-migration-mutation-runner',
  });
  let barrierClient;
  let barrierHeld = false;
  let pending;
  let thrown;
  let cleanup;

  try {
    const runner = await import(`${pathToFileURL(migrationRunnerPath).href}?mutation=${Date.now()}-${Math.random()}`);
    barrierClient = await barrierPool.connect();
    await barrierClient.query('SELECT pg_advisory_lock($1::bigint)', [migrationAdvisoryLockId]);
    barrierHeld = true;
    pending = runner.applyMigrations({ pool: runnerPool, migrationsDir: productionMigrationsDir });
    await waitForMigrationWaiter(barrierClient, 'rss-migration-mutation-runner');
    assert.equal(
      (await barrierClient.query(
        "SELECT to_regclass('public.roomscan_schema_migrations')::text AS relation",
      )).rows[0].relation,
      null,
      'migration ledger DDL ran before the session advisory lock',
    );
    await barrierClient.query('SELECT pg_advisory_unlock($1::bigint)', [migrationAdvisoryLockId]);
    barrierHeld = false;
    assert.equal((await pending).applied.length, 6);
    pending = undefined;
  } catch (error) {
    thrown = error;
  } finally {
    if (barrierHeld) {
      await barrierClient?.query(
        'SELECT pg_advisory_unlock($1::bigint)',
        [migrationAdvisoryLockId],
      ).catch(() => undefined);
    }
    await pending?.catch(() => undefined);
    barrierClient?.release();
    await Promise.all([runnerPool.end(), barrierPool.end()]);
    cleanup = await cluster.stop();
  }

  if (thrown) {
    thrown.cleanupEvidence = cleanup;
    throw thrown;
  }
  return cleanup;
}

const mutationCases = [
  {
    name: 'FORCE ROW LEVEL SECURITY removed',
    async prepare() {
      return await mutateCopiedFile(
        productionMigrationsDir,
        '0002_tenant_core.up.sql',
        'ALTER TABLE roomscan.projects FORCE ROW LEVEL SECURITY;',
        '-- MUTANT: FORCE ROW LEVEL SECURITY removed from projects',
      );
    },
    oracle: ownerForceOracle,
  },
  {
    name: 'tenant policy weakened to USING (true)',
    async prepare() {
      return await mutateCopiedFile(
        productionMigrationsDir,
        '0002_tenant_core.up.sql',
        `CREATE POLICY projects_tenant_isolation ON roomscan.projects
FOR ALL TO PUBLIC
USING (roomscan.has_authorized_tenant(workspace_id))
WITH CHECK (roomscan.has_authorized_tenant(workspace_id));`,
        `CREATE POLICY projects_tenant_isolation ON roomscan.projects
FOR ALL TO PUBLIC
USING (true)
WITH CHECK (roomscan.has_authorized_tenant(workspace_id));`,
      );
    },
    oracle: appIsolationOracle,
  },
  {
    name: 'runtime role granted BYPASSRLS',
    async mutateDatabase(pool) {
      await pool.query('ALTER ROLE roomscan_app BYPASSRLS');
    },
    oracle: appIsolationOracle,
  },
  {
    name: 'transaction-local context changed to session-local',
    async prepare() {
      return await mutatedRuntime();
    },
    oracle: transactionLocalOracle,
  },
  {
    name: 'failed rollback eviction argument removed',
    prepare: mutatedRollbackRuntime,
    oracle: rollbackQuarantineOracle,
  },
  {
    name: 'migration advisory lock moved after ledger DDL',
    prepare: mutatedMigrationRunner,
    async runPrepared(prepared) {
      return await migrationLockOracle(prepared.migrationRunnerPath);
    },
    async runRestored() {
      return await migrationLockOracle(productionMigrationRunnerPath);
    },
  },
  {
    name: 'Stripe literal-TRUE signature guard weakened',
    async prepare() {
      return await mutateCopiedFile(
        productionMigrationsDir,
        '0004_stripe.up.sql',
        '  IF signature_is_verified IS DISTINCT FROM true THEN',
        '  IF NOT signature_is_verified THEN -- MUTANT: SQL NULL bypasses this guard',
      );
    },
    oracle: stripeSignatureOracle,
  },
  {
    name: 'nullable reducer guard and exact comparison weakened',
    async prepare() {
      const prepared = await mutateCopiedFile(
        productionMigrationsDir,
        '0003_quota.up.sql',
        `  IF requested_metric IS NULL
    OR amount_to_reserve IS NULL`,
        `  IF amount_to_reserve IS NULL -- MUTANT: required metric NULL guard removed`,
      );
      const target = path.join(prepared.migrationsDir, '0003_quota.up.sql');
      const contents = await readFile(target, 'utf8');
      const nullSafeComparison = 'existing_reservation.metric IS DISTINCT FROM requested_metric';
      assert.equal(contents.split(nullSafeComparison).length - 1, 2);
      await writeFile(target, contents.replaceAll(
        nullSafeComparison,
        'existing_reservation.metric <> requested_metric',
      ));
      return prepared;
    },
    oracle: nullableReducerRetryOracle,
  },
  {
    name: 'quota conditional predicate removed',
    async prepare() {
      return await mutateCopiedFile(
        productionMigrationsDir,
        '0003_quota.up.sql',
        '    AND usage.used + usage.reserved + amount_to_reserve <= usage.limit_value;',
        '    AND true; -- MUTANT: quota limit predicate removed',
      );
    },
    oracle: quotaConcurrencyOracle,
  },
  {
    name: 'invitation atomic consume guard removed',
    async prepare() {
      const prepared = await mutateCopiedFile(
        productionMigrationsDir,
        '0005_hardened_reducers.up.sql',
        `    AND invitation.expires_at > clock_timestamp()
    AND invitation.consumed_at IS NULL
  FOR UPDATE;`,
        `    AND invitation.expires_at > clock_timestamp()
    AND true -- MUTANT: invitation read guard removed
  FOR UPDATE;`,
      );
      const target = path.join(prepared.migrationsDir, '0005_hardened_reducers.up.sql');
      const contents = await readFile(target, 'utf8');
      const finalGuard = `    AND id = accepted_invitation_id
    AND consumed_at IS NULL;`;
      assert.equal(contents.split(finalGuard).length - 1, 1);
      await writeFile(target, contents.replace(
        finalGuard,
        `    AND id = accepted_invitation_id
    AND true; -- MUTANT: final consume guard removed`,
      ));
      return prepared;
    },
    oracle: invitationAtomicOracle,
  },
  {
    name: 'access resolver membership cache validation removed',
    async prepare() {
      return await mutateCopiedFile(
        productionMigrationsDir,
        '0006_auth_persistence.up.sql',
        `        AND membership.state = 'active'
        AND membership.role = access.role
        AND membership.authorization_version = access.authorization_version)`,
        `        AND membership.state = 'active'
        AND true) -- MUTANT: cached role/version validation removed`,
      );
    },
    oracle: authResolverMembershipOracle,
  },
  {
    name: 'auth required-argument NULL guard removed',
    async prepare() {
      return await mutateCopiedFile(
        productionMigrationsDir,
        '0006_auth_persistence.up.sql',
        `  IF current_token_hash IS NULL
    OR next_token_hash IS NULL`,
        `  IF next_token_hash IS NULL -- MUTANT: current digest NULL guard removed`,
      );
    },
    oracle: authNullGuardOracle,
  },
  {
    name: 'security-notification lease ownership guard removed',
    async prepare() {
      return await mutateCopiedFile(
        productionMigrationsDir,
        '0006_auth_persistence.up.sql',
        `    AND notification.state = 'leased'
    AND notification.lease_id = requested_lease_id
    AND notification.lease_expires_at > delivered_at_time;`,
        `    AND notification.state = 'leased'
    AND true; -- MUTANT: lease identity and expiry guards removed`,
      );
    },
    oracle: notificationLeaseOracle,
  },
  {
    name: 'magic policy transaction lock neutralized',
    async prepare() {
      return await mutateCopiedFile(
        productionMigrationsDir,
        '0006_auth_persistence.up.sql',
        `  PERFORM pg_advisory_xact_lock(
    hashtextextended(scope_kind || ':' || encode(subject_hash, 'hex'), 7621846213719042)
  );`,
        `  PERFORM true; -- MUTANT: magic issuance scope no longer serialized`,
      );
    },
    oracle: magicPolicyLockOracle,
  },
];

let detected = 0;
let restored = 0;
const cleanupEvidence = [];

for (const mutation of mutationCases) {
  const prepared = await mutation.prepare?.();
  try {
    let caught;
    try {
      if (mutation.runPrepared) {
        await mutation.runPrepared(prepared);
      } else {
        await runOracle({
          migrationsDir: prepared?.migrationsDir,
          runtimePath: prepared?.runtimePath,
          mutateDatabase: mutation.mutateDatabase,
          oracle: mutation.oracle,
        });
      }
    } catch (error) {
      caught = error;
      cleanupEvidence.push({ phase: 'mutant', name: mutation.name, ...error.cleanupEvidence });
    }
    assert.ok(caught, `${mutation.name} unexpectedly passed its focused oracle`);
    assert.equal(caught.code, 'ERR_ASSERTION', `${mutation.name} failed for infrastructure rather than its invariant`);
    detected += 1;
    console.log(`MUTATION_RED ${mutation.name}: ${caught.message}`);

    const cleanup = mutation.runRestored
      ? await mutation.runRestored()
      : await runOracle({ oracle: mutation.oracle });
    cleanupEvidence.push({ phase: 'restored', name: mutation.name, ...cleanup });
    restored += 1;
    console.log(`RESTORE_GREEN ${mutation.name}`);
  } finally {
    if (prepared?.root) {
      await rm(prepared.root, { recursive: true, force: true });
    }
  }
}

console.log(`MUTATION_SUMMARY detected=${detected} restored=${restored} total=${mutationCases.length}`);
console.log(`MUTATION_PROCESS_CLEANUP ${JSON.stringify(cleanupEvidence)}`);
