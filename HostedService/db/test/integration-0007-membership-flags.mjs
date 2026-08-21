import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { appPoolConfig, hash32, ids, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const cluster = await startPostgresCluster();
const bootstrapPool = new Pool(cluster.bootstrapConfig);
let apiPool;

try {
  await applyMigrations({ pool: bootstrapPool });
  await seedCoreFixtures(bootstrapPool);

  const tableSecurity = (await bootstrapPool.query(
    `SELECT c.relname, c.relrowsecurity, c.relforcerowsecurity
       FROM pg_class AS c
       JOIN pg_namespace AS n ON n.oid = c.relnamespace
      WHERE n.nspname = 'roomscan'
        AND c.relname = ANY($1::text[])
      ORDER BY c.relname`,
    [[
      'global_operational_flags', 'member_slots', 'operational_flag_audit_events',
      'workspace_operational_flags', 'workspace_publishing_policies',
    ]],
  )).rows;
  assert.deepEqual(tableSecurity, [
    { relname: 'global_operational_flags', relrowsecurity: false, relforcerowsecurity: false },
    { relname: 'member_slots', relrowsecurity: true, relforcerowsecurity: true },
    { relname: 'operational_flag_audit_events', relrowsecurity: false, relforcerowsecurity: false },
    { relname: 'workspace_operational_flags', relrowsecurity: true, relforcerowsecurity: true },
    { relname: 'workspace_publishing_policies', relrowsecurity: true, relforcerowsecurity: true },
  ]);

  const invitationColumns = (await bootstrapPool.query(
    `SELECT column_name, is_nullable
       FROM information_schema.columns
      WHERE table_schema = 'roomscan' AND table_name = 'invitations'
        AND column_name = ANY($1::text[])
      ORDER BY column_name`,
    [['public_id', 'revoked_at', 'state', 'updated_at', 'version']],
  )).rows;
  assert.deepEqual(invitationColumns, [
    { column_name: 'public_id', is_nullable: 'NO' },
    { column_name: 'revoked_at', is_nullable: 'YES' },
    { column_name: 'state', is_nullable: 'NO' },
    { column_name: 'updated_at', is_nullable: 'NO' },
    { column_name: 'version', is_nullable: 'NO' },
  ]);

  const auditColumns = (await bootstrapPool.query(
    `SELECT column_name, is_nullable
       FROM information_schema.columns
      WHERE table_schema = 'roomscan' AND table_name = 'audit_events'
        AND column_name = ANY($1::text[])
      ORDER BY column_name`,
    [['authorization_version', 'event_id']],
  )).rows;
  assert.deepEqual(auditColumns, [
    { column_name: 'authorization_version', is_nullable: 'YES' },
    { column_name: 'event_id', is_nullable: 'NO' },
  ]);

  assert.equal(Number((await bootstrapPool.query(
    `SELECT count(*)::integer AS count FROM roomscan.member_slots`,
  )).rows[0].count), 3, 'every active fixture membership must own exactly one slot');
  assert.equal(Number((await bootstrapPool.query(
    `SELECT count(*)::integer AS count
       FROM roomscan.memberships AS membership
       LEFT JOIN roomscan.member_slots AS slot
         ON slot.workspace_id = membership.workspace_id
        AND slot.principal_id = membership.principal_id
      WHERE membership.state = 'active' AND slot.principal_id IS NULL`,
  )).rows[0].count), 0);

  assert.equal(Number((await bootstrapPool.query(
    `SELECT count(*)::integer AS count FROM roomscan.global_operational_flags`,
  )).rows[0].count), 0, 'no global flag is enabled or created by default');
  assert.equal(Number((await bootstrapPool.query(
    `SELECT count(*)::integer AS count FROM roomscan.workspace_operational_flags`,
  )).rows[0].count), 0, 'no workspace flag is enabled or created by default');
  assert.equal(Number((await bootstrapPool.query(
    `SELECT count(*)::integer AS count FROM roomscan.workspace_publishing_policies`,
  )).rows[0].count), 0, 'no publishing policy is enabled or created by default');

  await bootstrapPool.query('SET ROLE roomscan_operator');
  const globalFlag = (await bootstrapPool.query(
    `SELECT * FROM roomscan.set_operational_flag(
       'global', NULL, 'hosted_operations_enabled', true, NULL,
       'test enable', 'ofaud_abcdefghijklmnop', $1::timestamptz
     )`,
    ['2026-08-19T12:00:00.000Z'],
  )).rows[0];
  assert.deepEqual(globalFlag, { enabled: true, version: '1' });
  const signInFlag = (await bootstrapPool.query(
    `SELECT * FROM roomscan.set_operational_flag(
       'global', NULL, 'professional_sign_in_enabled', true, NULL,
       'test enable', 'ofaud_signinabcdefghijkl', $1::timestamptz
     )`,
    ['2026-08-19T12:00:00.000Z'],
  )).rows[0];
  assert.deepEqual(signInFlag, { enabled: true, version: '1' });
  const workspaceFlag = (await bootstrapPool.query(
    `SELECT * FROM roomscan.set_operational_flag(
       'workspace', $1::uuid, 'hosted_operations_enabled', true, NULL,
       'test enable', 'ofaud_qrstuvwxyzabcdef', $2::timestamptz
     )`,
    [ids.workspaceA, '2026-08-19T12:00:00.000Z'],
  )).rows[0];
  assert.deepEqual(workspaceFlag, { enabled: true, version: '1' });
  await bootstrapPool.query('RESET ROLE');

  const now = new Date('2026-08-19T12:00:00.000Z');
  const familyId = '63000000-0000-4000-8000-000000000071';
  const accessHash = hash32('bootstrap-0007-access');
  await bootstrapPool.query(
    `INSERT INTO roomscan.auth_session_families (
       id, public_id, principal_id, authentication_epoch, authenticated_at,
       last_used_at, inactivity_expires_at, absolute_expires_at, policy_version,
       state, created_at
     ) VALUES ($1, 'fam_bootstrap0007', $2, 0, $3::timestamptz, $3::timestamptz,
       $3::timestamptz + interval '1 day', $3::timestamptz + interval '7 days',
       'session-v1', 'active', $3::timestamptz)`,
    [familyId, ids.principalInvitee, now],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.auth_access_tokens (
       id, family_id, token_hash, expires_at, principal_id,
       authentication_epoch, authenticated_at, issued_at, state, created_at
     ) VALUES (gen_random_uuid(), $1, $2, $3::timestamptz + interval '1 hour', $4,
       0, $3::timestamptz, $3::timestamptz, 'active', $3::timestamptz)`,
    [familyId, accessHash, now, ids.principalInvitee],
  );
  apiPool = new Pool({
    ...appPoolConfig(cluster, 2), user: 'roomscan_api_runtime',
    application_name: 'rss-0007-membership-flags',
  });
  const bootstrapped = (await apiPool.query(
    `SELECT * FROM roomscan.bootstrap_workspace_v2(
       $1::bytea, $2::timestamptz, 'workspace-c', 'Workspace C',
       'aud_bootstrapworkspace0007'
     )`,
    [accessHash, now],
  )).rows[0];
  assert.equal(bootstrapped.principal_canonical_id.startsWith('prn_'), true);
  assert.equal(bootstrapped.family_public_id, 'fam_bootstrap0007');
  assert.equal(bootstrapped.authorization_version, '1');
  assert.equal(Number((await bootstrapPool.query(
    `SELECT count(*)::integer AS count FROM roomscan.member_slots
      WHERE workspace_id = $1 AND principal_id = $2`,
    [bootstrapped.workspace_id, ids.principalInvitee],
  )).rows[0].count), 1);
  assert.deepEqual((await bootstrapPool.query(
    `SELECT workspace_id, role, authorization_version
       FROM roomscan.auth_session_families WHERE id = $1`, [familyId],
  )).rows[0], {
    workspace_id: bootstrapped.workspace_id, role: 'owner', authorization_version: '1',
  });
  assert.deepEqual((await bootstrapPool.query(
    `SELECT workspace_id, role, authorization_version
       FROM roomscan.auth_access_tokens WHERE token_hash = $1`, [accessHash],
  )).rows[0], {
    workspace_id: bootstrapped.workspace_id, role: 'owner', authorization_version: '1',
  });
  assert.equal(Number((await bootstrapPool.query(
    `SELECT count(*)::integer AS count FROM roomscan.audit_events
      WHERE workspace_id = $1 AND event_id = 'aud_bootstrapworkspace0007'`,
    [bootstrapped.workspace_id],
  )).rows[0].count), 1);

  for (const role of [
    'roomscan_api_runtime', 'roomscan_authorizer_runtime',
    'roomscan_auth_challenge_runtime', 'roomscan_stripe_ingress_runtime',
    'roomscan_stripe_reconciliation_runtime', 'roomscan_audit_export_runtime',
    'roomscan_email_delivery_runtime',
  ]) {
    for (const table of [
      'invitations', 'memberships', 'member_slots', 'audit_events',
      'global_operational_flags', 'workspace_operational_flags',
      'workspace_publishing_policies', 'operational_flag_audit_events',
    ]) {
      const row = (await bootstrapPool.query(
        `SELECT has_table_privilege($1, 'roomscan.' || $2, 'INSERT') AS i,
                has_table_privilege($1, 'roomscan.' || $2, 'UPDATE') AS u,
                has_table_privilege($1, 'roomscan.' || $2, 'DELETE') AS d,
                has_table_privilege($1, 'roomscan.' || $2, 'TRUNCATE') AS t`,
        [role, table],
      )).rows[0];
      assert.deepEqual(row, { i: false, u: false, d: false, t: false });
    }
  }

  console.log(
    'INTEGRATION_0007_MEMBERSHIP_FLAGS_SUMMARY schema_checks=12 '
      + 'slot_seed_controls=2 default_off_controls=3 operator_transitions=3 '
      + 'bootstrap_atomic_controls=7 protected_acl_pairs=56 status=pass',
  );
} finally {
  if (apiPool) await apiPool.end();
  await bootstrapPool.end();
  const cleanup = await cluster.stop();
  console.log(`PG_CLEANUP ${JSON.stringify(cleanup)}`);
}
