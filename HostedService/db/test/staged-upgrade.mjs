import assert from 'node:assert/strict';
import { copyFile, mkdir, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { accepted0006MigrationsDir } from './accepted-0006-migrations.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const fullDir = accepted0006MigrationsDir;
const stageRoot = await mkdtemp(path.join(tmpdir(), 'rss-stage-'));
const stageDir = path.join(stageRoot, 'migrations');
const hardenedDir = path.join(stageRoot, 'hardened-migrations');
await mkdir(stageDir);
await mkdir(hardenedDir);
for (const name of [
  '0001_roles_and_global.up.sql',
  '0002_tenant_core.up.sql',
  '0003_quota.up.sql',
  '0004_stripe.up.sql',
]) {
  await copyFile(path.join(fullDir, name), path.join(stageDir, name));
  await copyFile(path.join(fullDir, name), path.join(hardenedDir, name));
}
await copyFile(
  path.join(fullDir, '0005_hardened_reducers.up.sql'),
  path.join(hardenedDir, '0005_hardened_reducers.up.sql'),
);

const cluster = await startPostgresCluster();
const pool = new Pool(cluster.bootstrapConfig);
const expectedLegacy = [
  'roomscan.activate_quota_policy(bigint,bigint,bigint,bigint,bigint,bigint,integer)',
  'roomscan.apply_stripe_reconciliation(bigint,timestamp with time zone,text,text,timestamp with time zone)',
  'roomscan.consume_invitation(bytea)',
  'roomscan.enforce_membership_invariants()',
  'roomscan.finalize_quota(text,bigint)',
  'roomscan.has_authorized_tenant(uuid)',
  'roomscan.record_stripe_event(text,text,bytea,boolean,timestamp with time zone)',
  'roomscan.release_quota(text)',
  'roomscan.request_authorization_version()',
  'roomscan.request_principal_id()',
  'roomscan.request_tenant_id()',
  'roomscan.reserve_quota(roomscan.quota_metric,bigint,text)',
];
const expectedHardened = [
  'roomscan.activate_quota_policy(bigint,bigint,bigint,bigint,bigint,bigint,integer)',
  'roomscan.apply_stripe_reconciliation(bigint,timestamp with time zone,text,text,timestamp with time zone)',
  'roomscan.bootstrap_workspace(text,text)',
  'roomscan.consume_invitation(bytea)',
  'roomscan.finalize_quota(text,bigint)',
  'roomscan.has_authorized_tenant(uuid)',
  'roomscan.record_stripe_event(text,text,bytea,boolean,timestamp with time zone)',
  'roomscan.release_quota(text)',
  'roomscan.request_principal_id()',
  'roomscan.reserve_quota(roomscan.quota_metric,bigint,text)',
];
const expectedAuth = [
  ...expectedHardened,
  'roomscan.bump_principal_authentication_epoch(uuid)',
  'roomscan.cancel_magic_delivery(text,text,text,timestamp with time zone)',
  'roomscan.claim_apple_attempt_and_code(text,bytea,text,bytea,timestamp with time zone)',
  'roomscan.claim_apple_bridge_proof(bytea,text,text,text,text,timestamp with time zone)',
  'roomscan.claim_apple_nonce(bytea,timestamp with time zone)',
  'roomscan.claim_candidate_identity_proof(bytea,text,uuid,uuid,timestamp with time zone)',
  'roomscan.claim_external_identity(text,text,uuid,timestamp with time zone)',
  'roomscan.claim_magic_delivery(text,text,timestamp with time zone,timestamp with time zone)',
  'roomscan.claim_magic_link(text,bytea,text,timestamp with time zone)',
  'roomscan.claim_refresh_rotation(bytea,bytea,timestamp with time zone)',
  'roomscan.claim_security_notification(text,text,timestamp with time zone,timestamp with time zone)',
  'roomscan.claim_verified_auth_receipt(bytea,text,text,uuid,uuid,timestamp with time zone)',
  'roomscan.complete_magic_delivery(text,text,timestamp with time zone)',
  'roomscan.complete_security_notification(text,text,timestamp with time zone)',
  'roomscan.lock_magic_policy_scope(text,bytea)',
  'roomscan.release_external_identity(text,text,uuid)',
  'roomscan.release_magic_delivery(text,text,timestamp with time zone)',
  'roomscan.release_security_notification(text,text)',
  'roomscan.resolve_access_context(bytea,timestamp with time zone)',
  'roomscan.revoke_access_token(bytea,timestamp with time zone)',
  'roomscan.revoke_principal_session_families(uuid,uuid,timestamp with time zone,text)',
  'roomscan.revoke_session_family(uuid,timestamp with time zone,text)',
  'roomscan.supersede_magic_link(text,timestamp with time zone)',
  'roomscan.supersede_magic_link_siblings(text,timestamp with time zone)',
  'roomscan.update_session_family_activity(uuid,timestamp with time zone,timestamp with time zone)',
  'roomscan.validate_magic_delivery(text,text,timestamp with time zone)',
].sort();

async function appExecutable() {
  return (await pool.query(
    `SELECT p.oid::regprocedure::text AS routine
     FROM pg_proc AS p JOIN pg_namespace AS n ON n.oid=p.pronamespace
     WHERE n.nspname='roomscan' AND has_function_privilege('roomscan_app', p.oid, 'EXECUTE')
     ORDER BY routine`,
  )).rows.map(({ routine }) => routine);
}

try {
  const legacy = await applyMigrations({ pool, migrationsDir: stageDir });
  assert.equal(legacy.applied.length, 4);
  assert.deepEqual(await appExecutable(), expectedLegacy);

  const hardened = await applyMigrations({ pool, migrationsDir: hardenedDir });
  assert.equal(hardened.applied.length, 1);
  assert.equal(hardened.applied[0].name, '0005_hardened_reducers.up.sql');
  assert.deepEqual(await appExecutable(), expectedHardened);
  assert.equal((await pool.query(
    `SELECT count(*)::int AS count FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='roomscan' AND p.proname IN
       ('enforce_membership_invariants','request_tenant_id','request_authorization_version')
       AND has_function_privilege('roomscan_app', p.oid, 'EXECUTE')`,
  )).rows[0].count, 0);

  const auth = await applyMigrations({ pool, migrationsDir: fullDir });
  assert.equal(auth.applied.length, 1);
  assert.equal(auth.applied[0].name, '0006_auth_persistence.up.sql');
  assert.deepEqual(await appExecutable(), expectedAuth);
  console.log(`STAGED_UPGRADE_SUMMARY legacy_migrations=4 hardened_migrations=1 auth_migrations=1 legacy_app_execute=12 hardened_app_execute=10 auth_app_execute=${expectedAuth.length} status=pass`);
} finally {
  await pool.end();
  console.error(`CLEANUP ${JSON.stringify(await cluster.stop())}`);
  await rm(stageRoot, { recursive: true, force: true });
}
