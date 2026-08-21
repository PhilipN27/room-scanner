import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { appPoolConfig, hash32, ids, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const cluster = await startPostgresCluster();
const bootstrapPool = new Pool(cluster.bootstrapConfig);
let apiPool;
let challengePool;

const now = new Date('2026-08-19T14:00:00.000Z');
let familySequence = 200;

async function expectCode(work, code) {
  await assert.rejects(work, (error) => error?.code === code);
}

async function insertAccess(principalId, publicId, tokenLabel) {
  const familyId = `66000000-0000-4000-8000-${String(familySequence).padStart(12, '0')}`;
  familySequence += 1;
  const accessHash = hash32(tokenLabel);
  await bootstrapPool.query(
    `INSERT INTO roomscan.auth_session_families (
       id, public_id, principal_id, authentication_epoch, authenticated_at,
       last_used_at, inactivity_expires_at, absolute_expires_at,
       policy_version, state, created_at
     ) SELECT $1, $2, principal.id, principal.authentication_epoch,
       $3::timestamptz, $3::timestamptz, $3::timestamptz + interval '1 day',
       $3::timestamptz + interval '7 days', 'session-v1', 'active', $3::timestamptz
       FROM roomscan.principals AS principal WHERE principal.id = $4`,
    [familyId, publicId, now, principalId],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.auth_access_tokens (
       id, family_id, token_hash, expires_at, principal_id,
       authentication_epoch, authenticated_at, issued_at, state, created_at
     ) SELECT gen_random_uuid(), $1, $2, $3::timestamptz + interval '1 hour',
       principal.id, principal.authentication_epoch, $3::timestamptz,
       $3::timestamptz, 'active', $3::timestamptz
       FROM roomscan.principals AS principal WHERE principal.id = $4`,
    [familyId, accessHash, now, principalId],
  );
  return { familyId, accessHash };
}

try {
  await applyMigrations({ pool: bootstrapPool });
  await seedCoreFixtures(bootstrapPool);

  const expectedCapabilities = [
    'accept_apple_verified_result_v2',
    'consume_magic_challenge_v3',
    'create_apple_attempt_v2',
    'issue_magic_challenge_v3',
    'logout_all_from_access',
    'mint_candidate_identity_proof_v2',
    'mutate_identity_v2',
    'redeem_magic_completion_v3',
  ];
  const discovered = (await bootstrapPool.query(
    `SELECT DISTINCT routine_name
       FROM information_schema.routines
      WHERE routine_schema = 'roomscan' AND routine_name = ANY($1::text[])
      ORDER BY routine_name`,
    [expectedCapabilities],
  )).rows.map(({ routine_name }) => routine_name);
  assert.deepEqual(discovered, expectedCapabilities);

  await bootstrapPool.query(
    `INSERT INTO roomscan.external_identities (id, principal_id, issuer, subject, linked_at)
     VALUES
       (gen_random_uuid(), $1, 'https://appleid.apple.com', 'principal-a-base', $3),
       (gen_random_uuid(), $2, 'https://appleid.apple.com', 'principal-b-base', $3)`,
    [ids.principalA, ids.principalB, now],
  );
  const accessA = await insertAccess(ids.principalA, 'fam_identitya0000007', 'identity-access-a');
  const otherA = await insertAccess(ids.principalA, 'fam_identityaother07', 'identity-access-a-other');
  const accessB = await insertAccess(ids.principalB, 'fam_identityb0000007', 'identity-access-b');

  await bootstrapPool.query('SET ROLE roomscan_operator');
  await bootstrapPool.query(
    `SELECT * FROM roomscan.set_operational_flag(
       'global', NULL, 'professional_sign_in_enabled', true, NULL,
       'auth composite test', 'ofaud_authcomposite07', $1
     )`, [now],
  );
  await bootstrapPool.query('RESET ROLE');

  apiPool = new Pool({
    ...appPoolConfig(cluster, 8), user: 'roomscan_api_runtime',
    application_name: 'rss-0007-auth-composites-api',
  });
  challengePool = new Pool({
    ...appPoolConfig(cluster, 4), user: 'roomscan_auth_challenge_runtime',
    application_name: 'rss-0007-auth-composites-challenge',
  });

  const receiptHash = hash32('verified-receipt-a');
  await bootstrapPool.query(
    `INSERT INTO roomscan.verified_authentication_receipts (
       token_hash, issuer, subject, purpose, initiating_principal_id,
       initiating_family_id, authenticated_at, issued_at, expires_at,
       policy_version
     ) VALUES ($1, 'email', 'candidate-a@example.invalid', 'link-identity',
       $2, $3, $4, $4, $4::timestamptz + interval '2 minutes', 'identity-link-v2')`,
    [receiptHash, ids.principalA, accessA.familyId, now],
  );
  const proofHash = hash32('candidate-proof-a');
  const minted = (await apiPool.query(
    `SELECT * FROM roomscan.mint_candidate_identity_proof_v2(
       $1, $2, $3, 'email', 'link-identity', $4,
       $2::timestamptz + interval '4 minutes', 'identity-link-v2'
     )`,
    [accessA.accessHash, now, receiptHash, proofHash],
  )).rows[0];
  assert.equal(minted.status, 'minted');
  assert.equal(minted.principal_canonical_id.startsWith('prn_'), true);
  assert.equal((await bootstrapPool.query(
    `SELECT state FROM roomscan.verified_authentication_receipts WHERE token_hash = $1`,
    [receiptHash],
  )).rows[0].state, 'consumed');

  const linked = (await apiPool.query(
    `SELECT * FROM roomscan.mutate_identity_v2(
       $1, $2, $3, 'link-identity', true,
       'aud_identitylinked0007', 'ntf_identitylinked0007',
       'id_identitylinked0007', 'identity-link-v2'
     )`,
    [accessA.accessHash, new Date(now.getTime() + 1_000), proofHash],
  )).rows[0];
  assert.equal(linked.status, 'linked');
  assert.equal(linked.authentication_epoch, '1');
  assert.equal((await bootstrapPool.query(
    `SELECT principal_id FROM roomscan.external_identities
      WHERE issuer = 'email' AND subject = 'candidate-a@example.invalid'`,
  )).rows[0].principal_id, ids.principalA);
  assert.equal((await bootstrapPool.query(
    `SELECT state FROM roomscan.auth_session_families WHERE id = $1`, [otherA.familyId],
  )).rows[0].state, 'revoked');
  assert.equal(Number((await bootstrapPool.query(
    `SELECT count(*)::integer AS count FROM roomscan.identity_audit_events
      WHERE id = 'aud_identitylinked0007'`,
  )).rows[0].count), 1);
  assert.equal(Number((await bootstrapPool.query(
    `SELECT count(*)::integer AS count FROM roomscan.security_notification_outbox
      WHERE id = 'ntf_identitylinked0007'`,
  )).rows[0].count), 1);

  const proofB = hash32('candidate-proof-b-owned');
  await bootstrapPool.query(
    `INSERT INTO roomscan.candidate_identity_proofs (
       token_hash, issuer, subject, purpose, initiating_principal_id,
       initiating_family_id, authenticated_at, issued_at, expires_at,
       policy_version
     ) VALUES ($1, 'email', 'candidate-a@example.invalid', 'link-identity',
       $2, $3, $4, $4, $4::timestamptz + interval '4 minutes', 'identity-link-v2')`,
    [proofB, ids.principalB, accessB.familyId, now],
  );
  const owned = (await apiPool.query(
    `SELECT * FROM roomscan.mutate_identity_v2(
       $1, $2, $3, 'link-identity', true,
       'aud_ownedcandidate0007', 'ntf_ownedcandidate0007',
       'id_ownedcandidate0007', 'identity-link-v2'
     )`,
    [accessB.accessHash, new Date(now.getTime() + 1_500), proofB],
  )).rows[0];
  assert.equal(owned.status, 'candidate_owned');
  assert.equal((await bootstrapPool.query(
    `SELECT state FROM roomscan.candidate_identity_proofs WHERE token_hash = $1`, [proofB],
  )).rows[0].state, 'active');

  const finalMethodProof = hash32('candidate-proof-b-final-method');
  const notLinkedProof = hash32('candidate-proof-b-not-linked');
  await bootstrapPool.query(
    `INSERT INTO roomscan.candidate_identity_proofs (
       token_hash, issuer, subject, purpose, initiating_principal_id,
       initiating_family_id, authenticated_at, issued_at, expires_at,
       policy_version
     ) VALUES
       ($1, 'https://appleid.apple.com', 'principal-b-base', 'unlink-identity',
        $3, $4, $5, $5, $5::timestamptz + interval '4 minutes', 'identity-link-v2'),
       ($2, 'email', 'not-linked@example.invalid', 'unlink-identity',
        $3, $4, $5, $5, $5::timestamptz + interval '4 minutes', 'identity-link-v2')`,
    [finalMethodProof, notLinkedProof, ids.principalB, accessB.familyId, now],
  );
  const finalMethod = (await apiPool.query(
    `SELECT * FROM roomscan.mutate_identity_v2(
       $1, $2, $3, 'unlink-identity', true,
       'aud_finalmethod0007', 'ntf_finalmethod0007',
       'id_finalmethod00007', 'identity-link-v2'
     )`,
    [accessB.accessHash, new Date(now.getTime() + 1_600), finalMethodProof],
  )).rows[0];
  assert.equal(finalMethod.status, 'final_auth_method');
  assert.equal(finalMethod.principal_canonical_id.startsWith('prn_'), true);
  assert.equal(finalMethod.authentication_epoch, null);
  assert.equal((await bootstrapPool.query(
    `SELECT state FROM roomscan.candidate_identity_proofs WHERE token_hash = $1`,
    [finalMethodProof],
  )).rows[0].state, 'active');
  assert.equal(Number((await bootstrapPool.query(
    `SELECT count(*)::integer AS count FROM roomscan.external_identities
      WHERE principal_id = $1`, [ids.principalB],
  )).rows[0].count), 1);
  const notLinked = (await apiPool.query(
    `SELECT * FROM roomscan.mutate_identity_v2(
       $1, $2, $3, 'unlink-identity', true,
       'aud_notlinked000007', 'ntf_notlinked000007',
       'id_notlinked0000007', 'identity-link-v2'
     )`,
    [accessB.accessHash, new Date(now.getTime() + 1_700), notLinkedProof],
  )).rows[0];
  assert.equal(notLinked.status, 'not_linked');
  assert.equal(notLinked.authentication_epoch, null);
  assert.equal((await bootstrapPool.query(
    `SELECT state FROM roomscan.candidate_identity_proofs WHERE token_hash = $1`,
    [notLinkedProof],
  )).rows[0].state, 'active');

  const rollbackProof = hash32('candidate-proof-b-rollback');
  await bootstrapPool.query(
    `INSERT INTO roomscan.candidate_identity_proofs (
       token_hash, issuer, subject, purpose, initiating_principal_id,
       initiating_family_id, authenticated_at, issued_at, expires_at,
       policy_version
     ) VALUES ($1, 'email', 'rollback-b@example.invalid', 'link-identity',
       $2, $3, $4, $4, $4::timestamptz + interval '4 minutes', 'identity-link-v2')`,
    [rollbackProof, ids.principalB, accessB.familyId, now],
  );
  await assert.rejects(
    () => apiPool.query(
      `SELECT * FROM roomscan.mutate_identity_v2(
         $1, $2, $3, 'link-identity', true,
         'aud_identitylinked0007', 'ntf_identityrollback07',
         'id_identityrollback07', 'identity-link-v2'
       )`,
      [accessB.accessHash, new Date(now.getTime() + 2_000), rollbackProof],
    ),
    (error) => error?.code === '23505',
  );
  assert.equal(Number((await bootstrapPool.query(
    `SELECT count(*)::integer AS count FROM roomscan.external_identities
      WHERE issuer = 'email' AND subject = 'rollback-b@example.invalid'`,
  )).rows[0].count), 0);
  assert.equal((await bootstrapPool.query(
    `SELECT state FROM roomscan.candidate_identity_proofs WHERE token_hash = $1`,
    [rollbackProof],
  )).rows[0].state, 'active');
  assert.equal((await bootstrapPool.query(
    `SELECT authentication_epoch FROM roomscan.principals WHERE id = $1`, [ids.principalB],
  )).rows[0].authentication_epoch, '0');

  const disabledProof = hash32('candidate-proof-disable-race');
  await bootstrapPool.query(
    `INSERT INTO roomscan.candidate_identity_proofs (
       token_hash, issuer, subject, purpose, initiating_principal_id,
       initiating_family_id, authenticated_at, issued_at, expires_at,
       policy_version
     ) VALUES ($1, 'email', 'disabled-race@example.invalid', 'link-identity',
       $2, $3, $4, $4, $4::timestamptz + interval '4 minutes', 'identity-link-v2')`,
    [disabledProof, ids.principalB, accessB.familyId, now],
  );
  const disabledReceipt = hash32('verified-receipt-disabled-mint');
  await bootstrapPool.query(
    `INSERT INTO roomscan.verified_authentication_receipts (
       token_hash, issuer, subject, purpose, initiating_principal_id,
       initiating_family_id, authenticated_at, issued_at, expires_at,
       policy_version
     ) VALUES ($1, 'email', 'disabled-mint@example.invalid', 'link-identity',
       $2, $3, $4, $4, $4::timestamptz + interval '2 minutes', 'identity-link-v2')`,
    [disabledReceipt, ids.principalB, accessB.familyId, now],
  );
  await bootstrapPool.query('SET ROLE roomscan_operator');
  await bootstrapPool.query(
    `SELECT * FROM roomscan.set_operational_flag(
       'global', NULL, 'professional_sign_in_enabled', false, 1,
       'identity disable race', 'ofaud_identitydisable07', $1
     )`, [new Date(now.getTime() + 2_500)],
  );
  await bootstrapPool.query('RESET ROLE');
  await expectCode(
    () => apiPool.query(
      `SELECT * FROM roomscan.mutate_identity_v2(
         $1, $2, $3, 'link-identity', true,
         'aud_identitydisabled07', 'ntf_identitydisabled07',
         'id_identitydisabled07', 'identity-link-v2'
       )`, [accessB.accessHash, new Date(now.getTime() + 2_600), disabledProof],
    ),
    '42501',
  );
  await expectCode(
    () => apiPool.query(
      `SELECT * FROM roomscan.mint_candidate_identity_proof_v2(
         $1, $2, $3, 'email', 'link-identity', $4,
         $2::timestamptz + interval '1 minute', 'identity-link-v2'
       )`, [accessB.accessHash, new Date(now.getTime() + 2_700), disabledReceipt,
        hash32('disabled-mint-proof')],
    ),
    '42501',
  );
  assert.equal((await bootstrapPool.query(
    `SELECT state FROM roomscan.candidate_identity_proofs WHERE token_hash = $1`,
    [disabledProof],
  )).rows[0].state, 'active');
  assert.equal((await bootstrapPool.query(
    `SELECT state FROM roomscan.verified_authentication_receipts WHERE token_hash = $1`,
    [disabledReceipt],
  )).rows[0].state, 'active');

  const logout = (await apiPool.query(
    `SELECT * FROM roomscan.logout_all_from_access($1, $2)`,
    [accessB.accessHash, new Date(now.getTime() + 3_000)],
  )).rows[0];
  assert.equal(logout.status, 'revoked');
  assert.equal(logout.principal_id, ids.principalB);
  assert.equal(logout.authentication_epoch, '1');

  await bootstrapPool.query('SET ROLE roomscan_operator');
  await bootstrapPool.query(
    `SELECT * FROM roomscan.set_operational_flag(
       'global', NULL, 'professional_sign_in_enabled', true, 2,
       'identity test resume', 'ofaud_identityresume007', $1
     )`, [new Date(now.getTime() + 3_100)],
  );
  await bootstrapPool.query('RESET ROLE');

  const magicSecret = hash32('magic-secret-v3');
  const magicCompletion = hash32('magic-completion-v3');
  const magicTransfer = hash32('magic-transfer-v3');
  const magicChallenge = 'A'.repeat(43);
  const magicIssue = (await apiPool.query(
    `SELECT * FROM roomscan.issue_magic_challenge_v3(
       NULL, $1, 'magicselector000000007', $2, $3, $4, 'sign-in',
       'new-signin@example.invalid', $5, $6,
       $1::timestamptz + interval '10 minutes', 'magic-link-v1',
       'mdl_magiccomposite0007', 'magic-key-v1', $7, $8, $9,
       60, 2, 900, 3, 86400, 10, 900, 20, 3, 900, 10
     )`,
    [now, magicSecret, magicCompletion, magicChallenge,
      hash32('magic-address'), hash32('magic-network'),
      Buffer.alloc(12, 1), Buffer.alloc(32, 2), Buffer.alloc(16, 3)],
  )).rows[0];
  assert.equal(magicIssue.status, 'issued');
  const magicConsumed = (await apiPool.query(
    `SELECT * FROM roomscan.consume_magic_challenge_v3(
       'magicselector000000007', $1, 'sign-in', $2, $3
     )`,
    [magicSecret, new Date(now.getTime() + 3_000), magicTransfer],
  )).rows[0];
  assert.equal(magicConsumed.status, 'confirmed');
  const magicIssued = (await apiPool.query(
    `SELECT * FROM roomscan.redeem_magic_completion_v3(
       $1, $2, $3, 'sign-in', $4, $5,
       NULL, NULL, 'fam_magicsignin0007', $6, $7,
       $5::timestamptz + interval '5 minutes',
       $5::timestamptz + interval '7 days',
       $5::timestamptz + interval '30 days', 'session-v1'
     )`,
    [magicCompletion, magicChallenge, magicTransfer, hash32('magic-redeem-network'),
      new Date(now.getTime() + 4_000), hash32('magic-access-v3'),
      hash32('magic-refresh-v3')],
  )).rows[0];
  assert.equal(magicIssued.status, 'session_issued');
  assert.equal(magicIssued.principal_canonical_id.startsWith('prn_'), true);
  const magicReplay = (await apiPool.query(
    `SELECT * FROM roomscan.redeem_magic_completion_v3(
       $1, $2, $3, 'sign-in', $4, $5,
       NULL, NULL, 'fam_magicreplay00007', $6, $7,
       $5::timestamptz + interval '5 minutes',
       $5::timestamptz + interval '7 days',
       $5::timestamptz + interval '30 days', 'session-v1'
     )`,
    [magicCompletion, magicChallenge, magicTransfer, hash32('magic-redeem-network'),
      new Date(now.getTime() + 5_000), hash32('magic-replay-access'),
      hash32('magic-replay-refresh')],
  )).rows[0];
  assert.equal(magicReplay.status, 'unavailable');

  const appleAttempt = (await apiPool.query(
    `SELECT * FROM roomscan.create_apple_attempt_v2(
       NULL, $1, 'apple_attempt_composite07', $2, $3,
       'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
       'com.roomscan.test', 'https://example.invalid/apple/callback',
       $1::timestamptz + interval '5 minutes', 'apple-v1', 'sign-in'
     )`,
    [now, hash32('apple-state-composite'), hash32('apple-nonce-composite')],
  )).rows[0];
  assert.equal(appleAttempt.status, 'created');
  const appleClaim = (await apiPool.query(
    `SELECT status FROM roomscan.claim_apple_attempt_and_code(
       'apple_attempt_composite07', $1,
       'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', $2, $3
     )`,
    [hash32('apple-state-composite'), hash32('apple-code-composite'),
      new Date(now.getTime() + 1_000)],
  )).rows[0];
  assert.equal(appleClaim.status, 'claimed');
  assert.equal((await apiPool.query(
    `SELECT roomscan.claim_apple_nonce($1, $2) AS claimed`,
    [hash32('apple-nonce-composite'), new Date(now.getTime() + 1_500)],
  )).rows[0].claimed, true);
  const appleBridgeHash = hash32('apple-bridge-composite');
  const acceptedApple = (await apiPool.query(
    `SELECT * FROM roomscan.accept_apple_verified_result_v2(
       'apple_attempt_composite07', 'https://appleid.apple.com',
       'apple-subject-composite', $1, NULL, $2,
       $2::timestamptz + interval '1 minute', 'apple-v1'
     )`,
    [appleBridgeHash, new Date(now.getTime() + 2_000)],
  )).rows[0];
  assert.equal(acceptedApple.status, 'bridge_created');

  const replayedAppleResult = (await apiPool.query(
    `SELECT * FROM roomscan.accept_apple_verified_result_v2(
       'apple_attempt_composite07', 'https://appleid.apple.com',
       'apple-subject-composite', $1, NULL, $2,
       $2::timestamptz + interval '1 minute', 'apple-v1'
     )`,
    [hash32('apple-bridge-composite-replay'), new Date(now.getTime() + 2_500)],
  )).rows[0];
  assert.equal(replayedAppleResult.status, 'unavailable');
  assert.equal(Number((await bootstrapPool.query(
    `SELECT count(*)::integer AS count FROM roomscan.apple_bridge_proofs
      WHERE attempt_id = 'apple_attempt_composite07'`,
  )).rows[0].count), 1);

  const racingAppleAttempt = (await apiPool.query(
    `SELECT * FROM roomscan.create_apple_attempt_v2(
       NULL, $1, 'apple_attempt_result_race07', $2, $3,
       'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
       'com.roomscan.test', 'https://example.invalid/apple/callback',
       $1::timestamptz + interval '5 minutes', 'apple-v1', 'sign-in'
     )`,
    [now, hash32('apple-state-result-race'), hash32('apple-nonce-result-race')],
  )).rows[0];
  assert.equal(racingAppleAttempt.status, 'created');
  assert.equal((await apiPool.query(
    `SELECT status FROM roomscan.claim_apple_attempt_and_code(
       'apple_attempt_result_race07', $1,
       'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB', $2, $3
     )`,
    [hash32('apple-state-result-race'), hash32('apple-code-result-race'),
      new Date(now.getTime() + 1_000)],
  )).rows[0].status, 'claimed');
  assert.equal((await apiPool.query(
    `SELECT roomscan.claim_apple_nonce($1, $2) AS claimed`,
    [hash32('apple-nonce-result-race'), new Date(now.getTime() + 1_500)],
  )).rows[0].claimed, true);
  const appleResultRace = await Promise.all([
    apiPool.query(
      `SELECT * FROM roomscan.accept_apple_verified_result_v2(
         'apple_attempt_result_race07', 'https://appleid.apple.com',
         'apple-subject-result-race', $1, NULL, $2,
         $2::timestamptz + interval '1 minute', 'apple-v1'
       )`,
      [hash32('apple-result-race-proof-a'), new Date(now.getTime() + 2_000)],
    ),
    apiPool.query(
      `SELECT * FROM roomscan.accept_apple_verified_result_v2(
         'apple_attempt_result_race07', 'https://appleid.apple.com',
         'apple-subject-result-race', $1, NULL, $2,
         $2::timestamptz + interval '1 minute', 'apple-v1'
       )`,
      [hash32('apple-result-race-proof-b'), new Date(now.getTime() + 2_000)],
    ),
  ]);
  const appleResultStatuses = appleResultRace.flatMap(({ rows }) => rows.map(({ status }) => status));
  assert.equal(appleResultStatuses.filter((status) => status === 'bridge_created').length, 1);
  assert.equal(appleResultStatuses.filter((status) => status === 'unavailable').length, 1);
  assert.equal(Number((await bootstrapPool.query(
    `SELECT count(*)::integer AS count FROM roomscan.apple_bridge_proofs
      WHERE attempt_id = 'apple_attempt_result_race07'`,
  )).rows[0].count), 1);
  await assert.rejects(
    () => apiPool.query(
      `SELECT * FROM roomscan.consume_apple_bridge_and_issue_session(
         $1, 'fam_wrongapplelane07', $2, $3, $4, $4,
         $4::timestamptz + interval '5 minutes',
         $4::timestamptz + interval '7 days',
         $4::timestamptz + interval '30 days', 'session-v1'
       )`,
      [appleBridgeHash, hash32('wrong-apple-access'), hash32('wrong-apple-refresh'),
        new Date(now.getTime() + 3_000)],
    ),
    (error) => error?.code === '42501',
  );
  const appleSession = (await challengePool.query(
    `SELECT * FROM roomscan.consume_apple_bridge_and_issue_session(
       $1, 'fam_applecomposite07', $2, $3, $4, $4,
       $4::timestamptz + interval '5 minutes',
       $4::timestamptz + interval '7 days',
       $4::timestamptz + interval '30 days', 'session-v1'
     )`,
    [appleBridgeHash, hash32('apple-composite-access'), hash32('apple-composite-refresh'),
      new Date(now.getTime() + 3_000)],
  )).rows[0];
  assert.equal(appleSession.status, 'issued');

  const rawCanaries = [
    'identity-access-a',
    'candidate-proof-a',
    'magic-secret-v2',
    'apple-code-composite',
    'apple-nonce-composite',
    'apple-bridge-composite',
  ];
  const detectRawCanaries = (value) => rawCanaries.filter((canary) => value.includes(canary));
  assert.deepEqual(
    detectRawCanaries(`positive-detector-control:${rawCanaries[0]}`),
    [rawCanaries[0]],
  );
  const tableNames = (await bootstrapPool.query(
    `SELECT table_name FROM information_schema.tables
      WHERE table_schema = 'roomscan' AND table_type = 'BASE TABLE'
      ORDER BY table_name`,
  )).rows.map(({ table_name }) => table_name);
  const persistedRows = [];
  for (const tableName of tableNames) {
    persistedRows.push((await bootstrapPool.query(
      `SELECT COALESCE(jsonb_agg(to_jsonb(durable_row)), '[]'::jsonb) AS rows
         FROM roomscan.${tableName} AS durable_row`,
    )).rows[0].rows);
  }
  assert.deepEqual(detectRawCanaries(JSON.stringify(persistedRows)), []);

  console.log(
    'INTEGRATION_0007_AUTH_COMPOSITES_SUMMARY capabilities=8 mint_controls=3 '
      + 'identity_controls=17 identity_denial_status_controls=8 rollback_controls=4 logout_controls=3 '
      + 'magic_controls=5 apple_controls=16 apple_result_race_winners=1 '
      + 'apple_result_race_losers=1 lane_denials=2 raw_canaries=6 '
      + 'positive_detector_controls=1 status=pass',
  );
} finally {
  if (apiPool) await apiPool.end();
  if (challengePool) await challengePool.end();
  await bootstrapPool.end();
  const cleanup = await cluster.stop();
  console.log(`PG_CLEANUP ${JSON.stringify(cleanup)}`);
}
