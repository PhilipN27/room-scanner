import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { appPoolConfig, hash32, ids, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const cluster = await startPostgresCluster();
const bootstrapPool = new Pool(cluster.bootstrapConfig);
let apiPool;

const now = new Date('2026-08-19T12:00:00.000Z');
const principalSix = '10000000-0000-4000-8000-000000000006';
const principalSeven = '10000000-0000-4000-8000-000000000007';
let familySequence = 80;

async function insertAccess(principalId, publicId, accessValue, scope) {
  const familyId = `65000000-0000-4000-8000-${String(familySequence).padStart(12, '0')}`;
  familySequence += 1;
  const hash = hash32(accessValue);
  await bootstrapPool.query(
    `INSERT INTO roomscan.auth_session_families (
       id, public_id, principal_id, authentication_epoch, authenticated_at,
       last_used_at, inactivity_expires_at, absolute_expires_at, policy_version,
       workspace_id, role, authorization_version, state, created_at
     ) VALUES ($1, $2, $3, 0, $4::timestamptz, $4::timestamptz,
       $4::timestamptz + interval '1 day', $4::timestamptz + interval '7 days',
       'session-v1', $5::uuid, $6, $7::bigint, 'active', $4::timestamptz)`,
    [familyId, publicId, principalId, now, scope?.workspaceId ?? null,
      scope?.role ?? null, scope?.authorizationVersion ?? null],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.auth_access_tokens (
       id, family_id, token_hash, expires_at, principal_id,
       authentication_epoch, authenticated_at, issued_at,
       workspace_id, role, authorization_version, state, created_at
     ) VALUES (gen_random_uuid(), $1, $2, $3::timestamptz + interval '1 hour', $4,
       0, $3::timestamptz, $3::timestamptz, $5::uuid, $6, $7::bigint,
       'active', $3::timestamptz)`,
    [familyId, hash, now, principalId, scope?.workspaceId ?? null,
      scope?.role ?? null, scope?.authorizationVersion ?? null],
  );
  return hash;
}

async function expectCode(work, code) {
  await assert.rejects(work, (error) => error?.code === code);
}

try {
  await applyMigrations({ pool: bootstrapPool });
  await seedCoreFixtures(bootstrapPool);
  await bootstrapPool.query(
    `INSERT INTO roomscan.principals (id, normalized_email)
     VALUES ($1, 'six@example.invalid'), ($2, 'seven@example.invalid')`,
    [principalSix, principalSeven],
  );
  await bootstrapPool.query('SET ROLE roomscan_operator');
  for (const [scope, workspace, suffix] of [
    ['global', null, 'member_global_hosted'],
    ['workspace', ids.workspaceA, 'member_workspace_hosted'],
  ]) {
    await bootstrapPool.query(
      `SELECT * FROM roomscan.set_operational_flag(
        $1, $2::uuid, 'hosted_operations_enabled', true, NULL,
        'membership integration', $3, $4
      )`,
      [scope, workspace, `ofaud_${suffix}`, now],
    );
  }
  await bootstrapPool.query(
    `SELECT * FROM roomscan.activate_quota_policy_v2(
       $1, 1, 'roomscan-quota-policy-v1', 'test-only',
       'roomscan-period-v1:membership-test', 10, 3, 100, 100, 100,
       80, 1, 1, $2
     )`,
    [ids.workspaceA, now],
  );
  await bootstrapPool.query('RESET ROLE');

  const actorAccess = await insertAccess(ids.principalA, 'fam_memberactor0007', 'member-actor', {
    workspaceId: ids.workspaceA, role: 'owner', authorizationVersion: 1,
  });
  const sixAccess = await insertAccess(principalSix, 'fam_membersix000007', 'member-six');
  const sevenAccess = await insertAccess(principalSeven, 'fam_memberseven0007', 'member-seven');
  apiPool = new Pool({
    ...appPoolConfig(cluster, 6), user: 'roomscan_api_runtime',
    application_name: 'rss-0007-membership-composites',
  });

  const createSql = `SELECT * FROM roomscan.create_invitation_v2(
    $1::bytea, $2::timestamptz, $3, $4::bytea, $5, $6,
    $7::timestamptz, 1, 1, $8
  )`;
  const tokenSix = hash32('invitation-six');
  const tokenSeven = hash32('invitation-seven');
  const tokenRevoked = hash32('invitation-revoked');
  const invitationSix = (await apiPool.query(createSql, [
    actorAccess, now, 'inv_membersix00000001', tokenSix, 'six@example.invalid',
    'editor', new Date(now.getTime() + 60_000), 'aud_invitesix000000001',
  ])).rows[0];
  assert.equal(invitationSix.state, 'active');
  const invitationSeven = (await apiPool.query(createSql, [
    actorAccess, now, 'inv_memberseven000001', tokenSeven, 'seven@example.invalid',
    'editor', new Date(now.getTime() + 60_000), 'aud_inviteseven0000001',
  ])).rows[0];
  assert.equal(invitationSeven.version, '1');
  const invitationToRevoke = (await apiPool.query(createSql, [
    actorAccess, now, 'inv_memberrevoke00001', tokenRevoked,
    'revoked@example.invalid', 'viewer', new Date(now.getTime() + 60_000),
    'aud_inviterevokecreate1',
  ])).rows[0];
  assert.equal(invitationToRevoke.state, 'active');
  const revokedInvitation = (await apiPool.query(
    `SELECT * FROM roomscan.revoke_invitation_v2(
       $1, $2, 'inv_memberrevoke00001', 1, 1, 1,
       'aud_inviterevoked0001'
     )`,
    [actorAccess, new Date(now.getTime() + 500)],
  )).rows[0];
  assert.equal(revokedInvitation.status, 'revoked');
  assert.equal(revokedInvitation.version, '2');
  const revokeReplay = (await apiPool.query(
    `SELECT * FROM roomscan.revoke_invitation_v2(
       $1, $2, 'inv_memberrevoke00001', 1, 1, 1,
       'aud_inviterevokedreplay'
     )`,
    [actorAccess, new Date(now.getTime() + 750)],
  )).rows[0];
  assert.equal(revokeReplay.status, 'stale');
  assert.equal((await bootstrapPool.query(
    `SELECT state FROM roomscan.invitations WHERE token_hash = $1`, [tokenRevoked],
  )).rows[0].state, 'revoked');

  const lookup = (await apiPool.query(
    `SELECT * FROM roomscan.read_invitation_by_token($1, $2, $3)`,
    [sixAccess, now, tokenSix],
  )).rows[0];
  assert.equal(lookup.public_id, 'inv_membersix00000001');
  assert.equal(lookup.workspace_id, ids.workspaceA);

  const acceptSql = `SELECT * FROM roomscan.accept_invitation_v2(
    $1::bytea, $2::timestamptz, $3::bytea, 1, 1, 1, $4
  )`;
  const acceptRace = await Promise.allSettled([
    apiPool.query(acceptSql, [sixAccess, now, tokenSix, 'aud_acceptsix00000001']),
    apiPool.query(acceptSql, [sevenAccess, now, tokenSeven, 'aud_acceptseven000001']),
  ]);
  assert.equal(
    acceptRace.filter(({ status }) => status === 'fulfilled').length,
    1,
    JSON.stringify(acceptRace.map((result) => result.status === 'rejected'
      ? { status: result.status, code: result.reason?.code, message: result.reason?.message }
      : { status: result.status, rows: result.value.rows })),
  );
  assert.equal(acceptRace.filter(({ status }) => status === 'rejected').length, 1);
  const accepted = acceptRace.find(({ status }) => status === 'fulfilled').value.rows[0];
  assert.equal(accepted.status, 'accepted');
  assert.equal(accepted.authorization_version, '1');

  assert.equal(Number((await bootstrapPool.query(
    `SELECT count(*)::integer AS count FROM roomscan.member_slots WHERE workspace_id = $1`,
    [ids.workspaceA],
  )).rows[0].count), 3);
  assert.equal((await bootstrapPool.query(
    `SELECT used FROM roomscan.quota_usage_v2
      WHERE workspace_id = $1 AND metric = 'member_count'
        AND period_key = 'roomscan-period-v1:lifetime'`,
    [ids.workspaceA],
  )).rows[0].used, '3');
  const losingToken = accepted.principal_canonical_id
    === (await bootstrapPool.query(`SELECT canonical_id FROM roomscan.principals WHERE id = $1`, [principalSix])).rows[0].canonical_id
    ? tokenSeven : tokenSix;
  assert.equal((await bootstrapPool.query(
    `SELECT state FROM roomscan.invitations WHERE token_hash = $1`,
    [losingToken],
  )).rows[0].state, 'active', 'quota loser must not consume invitation');

  const acceptedPrincipalId = accepted.principal_canonical_id
    === (await bootstrapPool.query(`SELECT canonical_id FROM roomscan.principals WHERE id = $1`, [principalSix])).rows[0].canonical_id
    ? principalSix : principalSeven;
  const acceptedScopedAccess = await insertAccess(
    acceptedPrincipalId, 'fam_memberaccepted07', 'accepted-scoped', {
      workspaceId: ids.workspaceA, role: 'editor', authorizationVersion: 1,
    },
  );
  const targetCanonical = (await bootstrapPool.query(
    `SELECT canonical_id FROM roomscan.principals WHERE id = $1`, [acceptedPrincipalId],
  )).rows[0].canonical_id;
  const removed = (await apiPool.query(
    `SELECT * FROM roomscan.mutate_membership_v2(
       $1, $2, $3, 1, 'editor', 'active', 'editor', 'removed',
       1, 1, 'aud_removemember000001'
     )`,
    [actorAccess, new Date(now.getTime() + 2_000), targetCanonical],
  )).rows[0];
  assert.equal(removed.state, 'removed');
  assert.equal(removed.authorization_version, '2');
  assert.equal(Number((await bootstrapPool.query(
    `SELECT count(*)::integer AS count FROM roomscan.member_slots
      WHERE workspace_id = $1 AND principal_id = $2`,
    [ids.workspaceA, acceptedPrincipalId],
  )).rows[0].count), 0);
  assert.equal((await bootstrapPool.query(
    `SELECT state FROM roomscan.auth_session_families WHERE public_id = 'fam_memberaccepted07'`,
  )).rows[0].state, 'revoked');

  const ownerCanonical = (await bootstrapPool.query(
    `SELECT canonical_id FROM roomscan.principals WHERE id = $1`, [ids.principalA],
  )).rows[0].canonical_id;
  await expectCode(
    () => apiPool.query(
      `SELECT * FROM roomscan.mutate_membership_v2(
         $1, $2, $3, 1, 'owner', 'active', 'owner', 'removed',
         1, 1, 'aud_lastowner000000001'
       )`,
      [actorAccess, new Date(now.getTime() + 3_000), ownerCanonical],
    ),
    'P0001',
  );
  assert.equal((await bootstrapPool.query(
    `SELECT state FROM roomscan.memberships WHERE workspace_id = $1 AND principal_id = $2`,
    [ids.workspaceA, ids.principalA],
  )).rows[0].state, 'active');

  console.log(
    'INTEGRATION_0007_MEMBERSHIP_COMPOSITES_SUMMARY invitation_create=3 invitation_revoke_controls=5 '
      + 'hash_lookup=1 competing_slot_winners=1 competing_slot_losers=1 '
      + 'quota_slot_atomic_controls=4 removal_controls=4 last_owner_controls=2 status=pass',
  );
} finally {
  if (apiPool) await apiPool.end();
  await bootstrapPool.end();
  const cleanup = await cluster.stop();
  console.log(`PG_CLEANUP ${JSON.stringify(cleanup)}`);
}
