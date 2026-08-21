import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { appPoolConfig, hash32, ids, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const cluster = await startPostgresCluster();
const bootstrapPool = new Pool(cluster.bootstrapConfig);
let challengePool;
let apiPool;
let auditPool;
let stripePool;

try {
  await applyMigrations({ pool: bootstrapPool });
  await seedCoreFixtures(bootstrapPool);
  const now = new Date('2026-08-19T12:00:00.000Z');
  const proofHash = hash32('apple-bridge-proof-0007');
  await bootstrapPool.query(
    `INSERT INTO roomscan.apple_auth_attempts (
       id, state_hash, nonce_hash, code_challenge, expected_client_id,
       redirect_uri, created_at, expires_at, policy_version, purpose,
       state, claimed_at
     ) VALUES (
       'apple_attempt_auth0007', $1, $2,
       'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
       'com.roomscan.test', 'https://example.invalid/callback',
       $3::timestamptz - interval '1 minute', $3::timestamptz + interval '5 minutes',
       'apple-v1', 'sign-in', 'claimed', $3::timestamptz
     )`,
    [hash32('state-auth-0007'), hash32('nonce-auth-0007'), now],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.apple_bridge_proofs (
       token_hash, issuer, subject, attempt_id, purpose,
       issued_at, expires_at, policy_version
     ) VALUES ($1, 'https://appleid.apple.com', 'apple-subject-0007',
       'apple_attempt_auth0007', 'sign-in', $2,
       $2::timestamptz + interval '5 minutes', 'apple-v1')`,
    [proofHash, now],
  );
  const returningProofHash = hash32('apple-returning-bridge-proof-0007');
  await bootstrapPool.query(
    `INSERT INTO roomscan.external_identities (
       id, principal_id, issuer, subject, linked_at, created_at
     ) VALUES (
       gen_random_uuid(), $1, 'https://appleid.apple.com',
       'apple-returning-subject-0007', $2, $2
     )`,
    [ids.principalA, now],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.apple_auth_attempts (
       id, state_hash, nonce_hash, code_challenge, expected_client_id,
       redirect_uri, created_at, expires_at, policy_version, purpose,
       state, claimed_at
     ) VALUES (
       'apple_attempt_returning07', $1, $2,
       'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
       'com.roomscan.test', 'https://example.invalid/callback',
       $3::timestamptz - interval '1 minute', $3::timestamptz + interval '5 minutes',
       'apple-v1', 'sign-in', 'claimed', $3::timestamptz
     )`,
    [hash32('state-returning-0007'), hash32('nonce-returning-0007'), now],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.apple_bridge_proofs (
       token_hash, issuer, subject, attempt_id, purpose,
       issued_at, expires_at, policy_version
     ) VALUES ($1, 'https://appleid.apple.com', 'apple-returning-subject-0007',
       'apple_attempt_returning07', 'sign-in', $2,
       $2::timestamptz + interval '5 minutes', 'apple-v1')`,
    [returningProofHash, now],
  );

  challengePool = new Pool({
    ...appPoolConfig(cluster, 4), user: 'roomscan_auth_challenge_runtime',
    application_name: 'rss-0007-auth-challenge',
  });
  apiPool = new Pool({
    ...appPoolConfig(cluster, 4), user: 'roomscan_api_runtime',
    application_name: 'rss-0007-auth-api',
  });
  auditPool = new Pool({
    ...appPoolConfig(cluster, 2), user: 'roomscan_audit_export_runtime',
    application_name: 'rss-0007-provider-audit',
  });
  stripePool = new Pool({
    ...appPoolConfig(cluster, 2), user: 'roomscan_stripe_ingress_runtime',
    application_name: 'rss-0007-provider-audit-acceptance',
  });

  const issueSql = `SELECT * FROM roomscan.consume_apple_bridge_and_issue_session(
    $1, $2, $3, $4, $5, $5, $6, $7, $8, 'session-v1'
  )`;
  const accessHash = hash32('issued-access-0007');
  const refreshHash = hash32('issued-refresh-0007');
  const disabled = (await challengePool.query(issueSql, [
    proofHash, 'fam_appledisabled007', hash32('disabled-access'),
    hash32('disabled-refresh'), now, new Date(now.getTime() + 60_000),
    new Date(now.getTime() + 300_000), new Date(now.getTime() + 600_000),
  ])).rows[0];
  assert.equal(disabled.status, 'professional_sign_in_disabled');
  assert.equal((await bootstrapPool.query(
    `SELECT state FROM roomscan.apple_bridge_proofs WHERE token_hash = $1`,
    [proofHash],
  )).rows[0].state, 'active');
  await bootstrapPool.query('SET ROLE roomscan_operator');
  await bootstrapPool.query(
    `SELECT * FROM roomscan.set_operational_flag(
       'global', NULL, 'professional_sign_in_enabled', true, NULL,
       'auth capability test', 'ofaud_authsignin0007', $1
     )`,
    [now],
  );
  await bootstrapPool.query('RESET ROLE');
  const issueRace = await Promise.all([
    challengePool.query(issueSql, [
      proofHash, 'fam_appleissued0007', accessHash, refreshHash, now,
      new Date(now.getTime() + 60_000), new Date(now.getTime() + 300_000),
      new Date(now.getTime() + 600_000),
    ]),
    challengePool.query(issueSql, [
      proofHash, 'fam_appleloser00007', hash32('loser-access'), hash32('loser-refresh'), now,
      new Date(now.getTime() + 60_000), new Date(now.getTime() + 300_000),
      new Date(now.getTime() + 600_000),
    ]),
  ]);
  const issueRows = issueRace.flatMap(({ rows }) => rows);
  assert.equal(issueRows.filter(({ status }) => status === 'issued').length, 1);
  assert.equal(issueRows.filter(({ status }) => status === 'unavailable').length, 1);
  const issued = issueRows.find(({ status }) => status === 'issued');
  assert.equal(issued.principal_canonical_id.startsWith('prn_'), true);
  assert.equal(issued.family_public_id, 'fam_appleissued0007');
  assert.equal(Number((await bootstrapPool.query(
    `SELECT count(*)::integer AS count FROM roomscan.external_identities
      WHERE issuer = 'https://appleid.apple.com' AND subject = 'apple-subject-0007'`,
  )).rows[0].count), 1);

  const returningIssued = (await challengePool.query(issueSql, [
    returningProofHash, 'fam_applereturning007', hash32('returning-access-0007'),
    hash32('returning-refresh-0007'), now,
    new Date(now.getTime() + 60_000), new Date(now.getTime() + 300_000),
    new Date(now.getTime() + 600_000),
  ])).rows[0];
  assert.equal(returningIssued.status, 'issued');
  assert.deepEqual((await bootstrapPool.query(
    `SELECT family.workspace_id, family.role, family.authorization_version,
            access.workspace_id AS access_workspace_id,
            access.role AS access_role,
            access.authorization_version AS access_authorization_version
       FROM roomscan.auth_session_families AS family
       JOIN roomscan.auth_access_tokens AS access ON access.family_id = family.id
      WHERE family.id = $1`,
    [returningIssued.family_id],
  )).rows[0], {
    workspace_id: ids.workspaceA,
    role: 'owner',
    authorization_version: '1',
    access_workspace_id: ids.workspaceA,
    access_role: 'owner',
    access_authorization_version: '1',
  });

  const touched = (await apiPool.query(
    `SELECT * FROM roomscan.touch_session_from_access($1, $2, $2, $3)`,
    [accessHash, new Date(now.getTime() + 1_000), new Date(now.getTime() + 301_000)],
  )).rows[0];
  assert.equal(touched.status, 'updated');
  assert.equal(touched.principal_canonical_id, issued.principal_canonical_id);

  const nextRefresh = hash32('next-refresh-0007');
  const nextAccess = hash32('next-access-0007');
  const rotateSql = `SELECT * FROM roomscan.rotate_session_from_refresh(
    $1, $2, $3, $4, $5, $6
  )`;
  await assert.rejects(
    () => challengePool.query(rotateSql, [
      refreshHash, hash32('wrong-lane-refresh'), hash32('wrong-lane-access'),
      new Date(now.getTime() + 2_000), new Date(now.getTime() + 62_000),
      new Date(now.getTime() + 302_000),
    ]),
    (error) => error?.code === '42501',
  );
  const rotated = (await apiPool.query(rotateSql, [
    refreshHash, nextRefresh, nextAccess, new Date(now.getTime() + 2_000),
    new Date(now.getTime() + 62_000), new Date(now.getTime() + 302_000),
  ])).rows[0];
  assert.equal(rotated.status, 'rotated');
  assert.equal(rotated.family_public_id, issued.family_public_id);
  const replay = (await apiPool.query(rotateSql, [
    refreshHash, hash32('replay-refresh'), hash32('replay-access'),
    new Date(now.getTime() + 3_000), new Date(now.getTime() + 63_000),
    new Date(now.getTime() + 303_000),
  ])).rows[0];
  assert.equal(replay.status, 'replay_revoked');
  assert.equal((await bootstrapPool.query(
    `SELECT state FROM roomscan.auth_session_families WHERE public_id = $1`,
    [issued.family_public_id],
  )).rows[0].state, 'revoked');

  await assert.rejects(
    () => challengePool.query(
      `SELECT roomscan.accept_provider_audit_event(
         'paud_authdenied00007', 'apple', 'apple.exchange.accepted',
         'apple-attempt-0007', $1
       ) AS inserted`, [now],
    ),
    (error) => error?.code === '42501',
  );
  assert.equal((await stripePool.query(
    `SELECT roomscan.accept_provider_audit_event(
       'paud_stripeaccepted07', 'stripe', 'stripe.webhook.accepted',
       'evt_authcapability007', $1
     ) AS inserted`, [now],
  )).rows[0].inserted, true);
  const auditClaim = (await auditPool.query(
    `SELECT * FROM roomscan.claim_provider_audit_event(
       'audit_lease_0007', $1, $2
     )`, [now, new Date(now.getTime() + 30_000)],
  )).rows[0];
  assert.equal(auditClaim.id, 'paud_stripeaccepted07');
  assert.equal((await auditPool.query(
    `SELECT roomscan.complete_provider_audit_event($1, $2, $3) AS completed`,
    [auditClaim.id, auditClaim.lease_id, new Date(now.getTime() + 1_000)],
  )).rows[0].completed, true);

  for (const role of [
    'roomscan_api_runtime', 'roomscan_authorizer_runtime',
    'roomscan_auth_challenge_runtime', 'roomscan_stripe_ingress_runtime',
    'roomscan_stripe_reconciliation_runtime', 'roomscan_audit_export_runtime',
    'roomscan_email_delivery_runtime',
  ]) {
    const insertColumns = Number((await bootstrapPool.query(
      `SELECT count(*)::integer AS count
         FROM information_schema.column_privileges
        WHERE table_schema = 'roomscan' AND grantee = $1
          AND privilege_type IN ('INSERT', 'UPDATE', 'DELETE')`,
      [role],
    )).rows[0].count);
    assert.equal(insertColumns, 0, `${role} has direct mutation columns`);
  }

  console.log(
    'INTEGRATION_0007_AUTH_CAPABILITIES_SUMMARY apple_bridge_winners=1 '
      + 'apple_bridge_replays=1 default_off_controls=2 canonical_id_controls=3 activity_controls=2 '
      + 'refresh_rotation_controls=5 provider_audit_controls=4 direct_dml_roles=7 status=pass',
  );
} finally {
  if (challengePool) await challengePool.end();
  if (apiPool) await apiPool.end();
  if (auditPool) await auditPool.end();
  if (stripePool) await stripePool.end();
  await bootstrapPool.end();
  const cleanup = await cluster.stop();
  console.log(`PG_CLEANUP ${JSON.stringify(cleanup)}`);
}
