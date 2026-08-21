import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { accepted0006MigrationsDir } from './accepted-0006-migrations.mjs';
import { withPrincipalTransaction } from '../runtime.mjs';
import { appPoolConfig, hash32, ids, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const cluster = await startPostgresCluster();
const bootstrapPool = new Pool(cluster.bootstrapConfig);
let appPool;
let checks = 0;
const freshSame = '10000000-0000-4000-8000-000000000010';
const freshCompeteA = '10000000-0000-4000-8000-000000000011';
const freshCompeteB = '10000000-0000-4000-8000-000000000012';
const freshRollback = '10000000-0000-4000-8000-000000000013';

async function consume(principalId, token) {
  return await withPrincipalTransaction(appPool, { principalId }, async (client) => (
    await client.query('SELECT roomscan.consume_invitation($1) AS accepted', [hash32(token)])
  ).rows[0].accepted);
}

async function invite(id, workspaceId, token, role = 'viewer', expired = false) {
  await bootstrapPool.query(
    `INSERT INTO roomscan.invitations (
      id, workspace_id, token_hash, invited_role, expires_at, created_by_principal_id
    ) VALUES ($1, $2, $3, $4, clock_timestamp() + $5::interval, $6)`,
    [id, workspaceId, hash32(token), role, expired ? '-1 second' : '1 hour', ids.principalA],
  );
}

try {
  await applyMigrations({ pool: bootstrapPool, migrationsDir: accepted0006MigrationsDir });
  await seedCoreFixtures(bootstrapPool);
  await bootstrapPool.query(
    `INSERT INTO roomscan.principals (id, normalized_email) VALUES
      ($1, 'same@example.invalid'), ($2, 'compete-a@example.invalid'),
      ($3, 'compete-b@example.invalid'), ($4, 'rollback@example.invalid')`,
    [freshSame, freshCompeteA, freshCompeteB, freshRollback],
  );
  appPool = new Pool(appPoolConfig(cluster, 6));

  assert.equal(await consume(ids.principalInvitee, 'invitation-a'), true); checks += 1;
  assert.equal(await consume(ids.principalInvitee, 'invitation-a'), false); checks += 1;
  assert.equal((await bootstrapPool.query(
    'SELECT count(*)::int AS count FROM roomscan.memberships WHERE workspace_id=$1 AND principal_id=$2',
    [ids.workspaceA, ids.principalInvitee],
  )).rows[0].count, 1); checks += 1;

  await invite('40000000-0000-4000-8000-000000000020', ids.workspaceA, 'already-active', 'admin');
  assert.equal(await consume(ids.principalA, 'already-active'), false); checks += 1;
  assert.equal((await bootstrapPool.query(
    `SELECT consumed_at IS NULL AS untouched FROM roomscan.invitations WHERE token_hash=$1`,
    [hash32('already-active')],
  )).rows[0].untouched, true); checks += 1;

  await bootstrapPool.query(
    `INSERT INTO roomscan.memberships (workspace_id, principal_id, role, state)
     VALUES ($1, $2, 'viewer', 'invited'), ($1, $3, 'viewer', 'removed')`,
    [ids.workspaceB, ids.principalExtraOwner, ids.principalMember],
  );
  await invite('40000000-0000-4000-8000-000000000021', ids.workspaceB, 'retained-invited', 'editor');
  await invite('40000000-0000-4000-8000-000000000022', ids.workspaceB, 'retained-removed', 'admin');
  assert.equal(await consume(ids.principalExtraOwner, 'retained-invited'), true); checks += 1;
  assert.equal(await consume(ids.principalMember, 'retained-removed'), true); checks += 1;
  const reactivated = (await bootstrapPool.query(
    `SELECT principal_id, role, state, authorization_version
     FROM roomscan.memberships WHERE workspace_id=$1 AND principal_id=ANY($2::uuid[])
     ORDER BY principal_id`,
    [ids.workspaceB, [ids.principalMember, ids.principalExtraOwner]],
  )).rows;
  assert.deepEqual(reactivated, [
    { principal_id: ids.principalMember, role: 'admin', state: 'active', authorization_version: '2' },
    { principal_id: ids.principalExtraOwner, role: 'editor', state: 'active', authorization_version: '2' },
  ]); checks += 1;

  await invite('40000000-0000-4000-8000-000000000023', ids.workspaceA, 'expired-state', 'viewer', true);
  assert.equal(await consume(freshSame, 'expired-state'), false); checks += 1;

  await invite('40000000-0000-4000-8000-000000000024', ids.workspaceA, 'same-race');
  const sameRace = await Promise.all([
    consume(freshSame, 'same-race'), consume(freshSame, 'same-race'),
  ]);
  assert.deepEqual(sameRace.sort(), [false, true]); checks += 1;

  await invite('40000000-0000-4000-8000-000000000025', ids.workspaceB, 'compete-race');
  const competeRace = await Promise.all([
    consume(freshCompeteA, 'compete-race'), consume(freshCompeteB, 'compete-race'),
  ]);
  assert.deepEqual(competeRace.sort(), [false, true]); checks += 1;
  assert.equal((await bootstrapPool.query(
    `SELECT count(*)::int AS count FROM roomscan.memberships
     WHERE workspace_id=$1 AND principal_id=ANY($2::uuid[])`,
    [ids.workspaceB, [freshCompeteA, freshCompeteB]],
  )).rows[0].count, 1); checks += 1;

  await invite('40000000-0000-4000-8000-000000000026', ids.workspaceA, 'rollback-failpoint');
  await bootstrapPool.query(`
    CREATE FUNCTION public.fail_invitation_consume() RETURNS trigger LANGUAGE plpgsql AS $f$
    BEGIN RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='TEST_INVITATION_FAILPOINT'; END $f$;
    CREATE TRIGGER fail_invitation_consume BEFORE UPDATE ON roomscan.invitations
    FOR EACH ROW EXECUTE FUNCTION public.fail_invitation_consume()
  `);
  await assert.rejects(
    () => consume(freshRollback, 'rollback-failpoint'),
    (error) => error?.code === 'P0001' && error?.message === 'TEST_INVITATION_FAILPOINT',
  ); checks += 1;
  await bootstrapPool.query('DROP TRIGGER fail_invitation_consume ON roomscan.invitations');
  await bootstrapPool.query('DROP FUNCTION public.fail_invitation_consume()');
  const rollback = (await bootstrapPool.query(
    `SELECT
      (SELECT count(*)::int FROM roomscan.memberships WHERE workspace_id=$1 AND principal_id=$2) AS memberships,
      (SELECT consumed_at IS NULL FROM roomscan.invitations WHERE token_hash=$3) AS token_unconsumed`,
    [ids.workspaceA, freshRollback, hash32('rollback-failpoint')],
  )).rows[0];
  assert.deepEqual(rollback, { memberships: 0, token_unconsumed: true }); checks += 1;

  console.log(`INVITATION_STATE_SUMMARY cases=9 checks=${checks} status=pass`);
} finally {
  await appPool?.end();
  await bootstrapPool.end();
  console.error(`CLEANUP ${JSON.stringify(await cluster.stop())}`);
}
