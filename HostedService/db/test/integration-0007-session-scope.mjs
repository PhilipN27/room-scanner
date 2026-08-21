import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { appPoolConfig, hash32, ids, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const cluster = await startPostgresCluster();
const bootstrap = new Pool(cluster.bootstrapConfig);
let api;

async function expectCode(work, code) {
  await assert.rejects(work, (error) => error?.code === code);
}

try {
  await applyMigrations({ pool: bootstrap });
  await seedCoreFixtures(bootstrap);
  const now = new Date('2026-08-19T19:00:00.000Z');
  const principalFirst = '10000000-0000-4000-8000-000000000091';
  const principalRemoved = '10000000-0000-4000-8000-000000000092';
  await bootstrap.query(
    `INSERT INTO roomscan.principals(id, normalized_email)
     VALUES ($1, 'first@example.invalid'), ($2, 'removed@example.invalid')`,
    [principalFirst, principalRemoved],
  );

  const sessions = [
    ['69000000-0000-4000-8000-000000000001', 'fam_scope_first_0001', principalFirst, 'scope-first'],
    ['69000000-0000-4000-8000-000000000002', 'fam_scope_first_0002', principalFirst, 'scope-first-second'],
    ['69000000-0000-4000-8000-000000000003', 'fam_scope_member_001', ids.principalMember, 'scope-member'],
    ['69000000-0000-4000-8000-000000000004', 'fam_scope_removed_01', principalRemoved, 'scope-removed'],
    ['69000000-0000-4000-8000-000000000005', 'fam_scope_multi_0001', ids.principalExtraOwner, 'scope-multi'],
  ];
  for (const [familyId, publicId, principalId, tokenLabel] of sessions) {
    await bootstrap.query(
      `INSERT INTO roomscan.auth_session_families(
         id, public_id, principal_id, authentication_epoch, authenticated_at,
         last_used_at, inactivity_expires_at, absolute_expires_at, policy_version,
         state, created_at
       ) VALUES ($1, $2, $3, 0, $4::timestamptz, $4::timestamptz,
         $4::timestamptz + interval '1 day', $4::timestamptz + interval '7 days',
         'session-v1', 'active', $4::timestamptz)`,
      [familyId, publicId, principalId, now],
    );
    await bootstrap.query(
      `INSERT INTO roomscan.auth_access_tokens(
         id, family_id, token_hash, expires_at, principal_id,
         authentication_epoch, authenticated_at, issued_at, state, created_at
       ) VALUES (gen_random_uuid(), $1, $2, $3::timestamptz + interval '1 hour', $4,
         0, $3::timestamptz, $3::timestamptz, 'active', $3::timestamptz)`,
      [familyId, hash32(tokenLabel), now, principalId],
    );
  }

  await bootstrap.query(
    `INSERT INTO roomscan.memberships(
       id, workspace_id, principal_id, role, state, authorization_version, created_at, updated_at
     ) VALUES
       (gen_random_uuid(), $1, $2, 'viewer', 'removed', 2, $3, $3),
       (gen_random_uuid(), $1, $4, 'admin', 'active', 1, $3, $3),
       (gen_random_uuid(), $5, $4, 'viewer', 'active', 1, $3, $3)`,
    [ids.workspaceB, principalRemoved, now, ids.principalExtraOwner, ids.workspaceA],
  );

  await bootstrap.query('SET ROLE roomscan_operator');
  for (const [key, audit] of [
    ['professional_sign_in_enabled', 'ofaud_scope_global_signin'],
    ['hosted_operations_enabled', 'ofaud_scope_global_hosted'],
  ]) {
    await bootstrap.query(
      `SELECT * FROM roomscan.set_operational_flag(
        'global', NULL, $1, true, NULL, 'scope test', $2, $3
      )`, [key, audit, now],
    );
  }
  for (const [workspace, audit] of [
    [ids.workspaceA, 'ofaud_scope_workspace_a'],
    [ids.workspaceB, 'ofaud_scope_workspace_b'],
  ]) {
    await bootstrap.query(
      `SELECT * FROM roomscan.set_operational_flag(
        'workspace', $1, 'hosted_operations_enabled', true, NULL,
        'scope test', $2, $3
      )`, [workspace, audit, now],
    );
  }
  await bootstrap.query('RESET ROLE');

  api = new Pool({ ...appPoolConfig(cluster, 8), user: 'roomscan_api_runtime', application_name: 'rss-0007-session-scope' });
  const bootstrapSql = `SELECT * FROM roomscan.bootstrap_workspace_v2(
    $1::bytea, $2::timestamptz, $3, $4, $5
  )`;
  const firstArgs = [hash32('scope-first'), now, 'first-workspace', 'First Workspace', 'aud_scopebootstrapfirst01'];
  const created = (await api.query(bootstrapSql, firstArgs)).rows[0];
  assert.ok(created?.workspace_id);
  const replay = (await api.query(bootstrapSql, firstArgs)).rows[0];
  assert.deepEqual(replay, created);
  const scoped = (await bootstrap.query(
    `SELECT family.workspace_id AS family_workspace, family.role AS family_role,
            access.workspace_id AS access_workspace, access.role AS access_role,
            access.authorization_version AS access_version
       FROM roomscan.auth_session_families AS family
       JOIN roomscan.auth_access_tokens AS access ON access.family_id = family.id
      WHERE family.id = $1`, [sessions[0][0]],
  )).rows[0];
  assert.deepEqual(scoped, {
    family_workspace: created.workspace_id, family_role: 'owner',
    access_workspace: created.workspace_id, access_role: 'owner', access_version: '1',
  });
  await expectCode(() => api.query(bootstrapSql, [
    hash32('scope-first'), now, 'another-workspace', 'Another', 'aud_scopebootstrapother01',
  ]), '42501');
  await expectCode(() => api.query(bootstrapSql, [
    hash32('scope-first-second'), now, 'second-family', 'Second Family', 'aud_scopebootstrapsecond01',
  ]), '42501');

  const scopeSql = `SELECT * FROM roomscan.scope_session_workspace_v2(
    $1::bytea, $2::timestamptz, $3
  )`;
  const member = (await api.query(scopeSql, [hash32('scope-member'), now, 'workspace-a'])).rows[0];
  assert.equal(member.workspace_id, ids.workspaceA);
  assert.equal(member.workspace_slug, 'workspace-a');
  assert.equal(member.role, 'editor');
  assert.equal((await api.query(scopeSql, [hash32('scope-member'), now, 'workspace-a'])).rows[0].workspace_id, ids.workspaceA);
  await expectCode(() => api.query(scopeSql, [hash32('scope-member'), now, 'workspace-b']), '42501');
  await expectCode(() => api.query(scopeSql, [hash32('scope-removed'), now, 'workspace-b']), '42501');

  const race = await Promise.allSettled([
    api.query(scopeSql, [hash32('scope-multi'), now, 'workspace-a']),
    api.query(scopeSql, [hash32('scope-multi'), now, 'workspace-b']),
  ]);
  assert.equal(race.filter((result) => result.status === 'fulfilled').length, 1);
  assert.equal(race.filter((result) => result.status === 'rejected' && result.reason?.code === '42501').length, 1);
  const multiScope = (await bootstrap.query(
    `SELECT workspace_id FROM roomscan.auth_session_families WHERE id = $1`, [sessions[4][0]],
  )).rows[0].workspace_id;
  assert.ok(multiScope === ids.workspaceA || multiScope === ids.workspaceB);

  await bootstrap.query('SET ROLE roomscan_operator');
  await bootstrap.query(
    `SELECT * FROM roomscan.set_operational_flag(
      'global', NULL, 'professional_sign_in_enabled', false, 1,
      'disable control', 'ofaud_scope_disable_signin', $1
    )`, [new Date(now.getTime() + 1)],
  );
  await bootstrap.query('RESET ROLE');
  await expectCode(() => api.query(scopeSql, [hash32('scope-first-second'), now, 'first-workspace']), '42501');
  assert.equal((await api.query(`SELECT current_setting('app.tenant_id', true) AS tenant`)).rows[0].tenant ?? '', '');

  assert.equal((await bootstrap.query(
    `SELECT count(*)::int AS count FROM roomscan.workspaces
      WHERE slug IN ('first-workspace', 'another-workspace', 'second-family')`,
  )).rows[0].count, 1);
  console.log('INTEGRATION_0007_SESSION_SCOPE_SUMMARY bootstrap_create=1 replay=1 bootstrap_denials=2 family_access_scope=5 returning_member=2 cross_slug_denials=2 concurrent_scope=2 kill_switch_denials=1 pooled_context_clear=1 status=pass');
} finally {
  if (api) await api.end();
  await bootstrap.end();
  const cleanup = await cluster.stop();
  console.log(`PG_CLEANUP ${JSON.stringify(cleanup)}`);
}
