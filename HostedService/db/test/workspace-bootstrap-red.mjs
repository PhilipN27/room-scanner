import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { accepted0006MigrationsDir } from './accepted-0006-migrations.mjs';
import { withPrincipalTransaction } from '../runtime.mjs';
import { appPoolConfig, ids } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const cluster = await startPostgresCluster();
const bootstrapPool = new Pool(cluster.bootstrapConfig);
let appPool;

const bootstrapPrincipalA = ids.principalA;
const bootstrapPrincipalB = ids.principalB;
const nonexistentPrincipal = '10000000-0000-4000-8000-000000000099';

async function bootstrap(principalId, slug, displayName) {
  return await withPrincipalTransaction(appPool, { principalId }, async (client) => (
    await client.query(
      'SELECT * FROM roomscan.bootstrap_workspace($1, $2)',
      [slug, displayName],
    )
  ).rows[0]);
}

try {
  await applyMigrations({ pool: bootstrapPool, migrationsDir: accepted0006MigrationsDir });
  await bootstrapPool.query(
    `INSERT INTO roomscan.principals (id, normalized_email)
     VALUES ($1, 'bootstrap-a@example.invalid'), ($2, 'bootstrap-b@example.invalid')`,
    [bootstrapPrincipalA, bootstrapPrincipalB],
  );
  appPool = new Pool(appPoolConfig(cluster, 3));

  const created = await bootstrap(bootstrapPrincipalA, 'bootstrap-a', 'Bootstrap A');
  assert.match(created.workspace_id, /^[0-9a-f-]{36}$/u);
  assert.match(created.membership_id, /^[0-9a-f-]{36}$/u);
  assert.equal(created.authorization_version, '1');

  const durableBootstrap = (await bootstrapPool.query(
    `SELECT
       workspace.id AS workspace_id,
       membership.id AS membership_id,
       membership.principal_id,
       membership.role,
       membership.state,
       membership.authorization_version,
       audit_state.next_sequence,
       audit_event.sequence,
       audit_event.actor_principal_id,
       audit_event.action,
       audit_event.subject_kind,
       audit_event.subject_id
     FROM roomscan.workspaces AS workspace
     JOIN roomscan.memberships AS membership ON membership.workspace_id = workspace.id
     JOIN roomscan.audit_states AS audit_state ON audit_state.workspace_id = workspace.id
     JOIN roomscan.audit_events AS audit_event ON audit_event.workspace_id = workspace.id
     WHERE workspace.slug = 'bootstrap-a'`,
  )).rows;
  assert.deepEqual(durableBootstrap, [{
    workspace_id: created.workspace_id,
    membership_id: created.membership_id,
    principal_id: bootstrapPrincipalA,
    role: 'owner',
    state: 'active',
    authorization_version: '1',
    next_sequence: '2',
    sequence: '1',
    actor_principal_id: bootstrapPrincipalA,
    action: 'workspace.created',
    subject_kind: 'workspace',
    subject_id: created.workspace_id,
  }]);

  await assert.rejects(
    () => appPool.query("SELECT * FROM roomscan.bootstrap_workspace('missing', 'Missing')"),
    (error) => error?.code === '42501' && error?.message === 'AUTHENTICATED_PRINCIPAL_REQUIRED',
  );
  await assert.rejects(
    () => bootstrap(nonexistentPrincipal, 'forged-principal', 'Forged principal'),
    (error) => error?.code === '42501' && error?.message === 'ACTIVE_PRINCIPAL_REQUIRED',
  );

  const forgedContextClient = await appPool.connect();
  try {
    await forgedContextClient.query('BEGIN');
    await forgedContextClient.query("SELECT set_config('app.principal_id', $1, true)", [bootstrapPrincipalB]);
    await forgedContextClient.query(
      "SELECT set_config('app.tenant_id', $1, true), set_config('app.authorization_version', '999', true)",
      [created.workspace_id],
    );
    await assert.rejects(
      () => forgedContextClient.query("SELECT * FROM roomscan.bootstrap_workspace('forged-context', 'Forged context')"),
      (error) => error?.code === '42501' && error?.message === 'PRINCIPAL_ONLY_CONTEXT_REQUIRED',
    );
    await forgedContextClient.query('ROLLBACK');
  } finally {
    forgedContextClient.release();
  }

  await assert.rejects(
    () => bootstrap(bootstrapPrincipalB, 'bootstrap-a', 'Duplicate slug'),
    (error) => error?.code === '23505',
  );
  assert.equal((await bootstrapPool.query(
    `SELECT count(*)::int AS count
     FROM roomscan.memberships
     WHERE principal_id = $1`,
    [bootstrapPrincipalB],
  )).rows[0].count, 0, 'duplicate bootstrap must roll back its generated membership');

  await bootstrapPool.query(`
    CREATE FUNCTION public.test_fail_bootstrap_audit()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $function$
    BEGIN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'TEST_BOOTSTRAP_FAILPOINT';
    END
    $function$;
    CREATE TRIGGER test_fail_bootstrap_audit
    BEFORE INSERT ON roomscan.audit_events
    FOR EACH ROW EXECUTE FUNCTION public.test_fail_bootstrap_audit()
  `);
  await assert.rejects(
    () => bootstrap(bootstrapPrincipalB, 'rollback-probe', 'Rollback probe'),
    (error) => error?.code === 'P0001' && error?.message === 'TEST_BOOTSTRAP_FAILPOINT',
  );
  await bootstrapPool.query('DROP TRIGGER test_fail_bootstrap_audit ON roomscan.audit_events');
  await bootstrapPool.query('DROP FUNCTION public.test_fail_bootstrap_audit()');
  assert.deepEqual((await bootstrapPool.query(
    `SELECT
       (SELECT count(*)::int FROM roomscan.workspaces WHERE slug = 'rollback-probe') AS workspaces,
       (SELECT count(*)::int FROM roomscan.memberships WHERE principal_id = $1) AS memberships`,
    [bootstrapPrincipalB],
  )).rows[0], { workspaces: 0, memberships: 0 });

  await assert.rejects(
    () => withPrincipalTransaction(appPool, { principalId: bootstrapPrincipalA }, (client) => client.query(
      `INSERT INTO roomscan.workspaces (slug, display_name) VALUES ('direct-workspace', 'Direct workspace')`,
    )),
    (error) => error?.code === '42501',
  );
  await assert.rejects(
    () => withPrincipalTransaction(appPool, { principalId: bootstrapPrincipalA }, (client) => client.query(
      `INSERT INTO roomscan.memberships (workspace_id, principal_id, role, state)
       VALUES ($1, $2, 'owner', 'active')`,
      [created.workspace_id, bootstrapPrincipalB],
    )),
    (error) => error?.code === '42501',
  );

  console.log('WORKSPACE_BOOTSTRAP_TEST_SUMMARY cases=8 atomic=true server_ids=true status=pass');
} finally {
  await appPool?.end();
  await bootstrapPool.end();
  const cleanup = await cluster.stop();
  console.error(`CLEANUP ${JSON.stringify(cleanup)}`);
}
