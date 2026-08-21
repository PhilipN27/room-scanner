import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { accepted0006MigrationsDir } from './accepted-0006-migrations.mjs';
import { appPoolConfig, hash32, ids, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const now = new Date('2026-08-19T12:00:00.000Z');
const familyId = '61000000-0000-4000-8000-000000000001';
const parentRefreshHash = hash32('refresh-parent');

async function raceTransactions(pool, operations) {
  const clients = await Promise.all(operations.map(() => pool.connect()));
  let ready = 0;
  let releaseReady;
  let releaseGo;
  const allReady = new Promise((resolve) => { releaseReady = resolve; });
  const go = new Promise((resolve) => { releaseGo = resolve; });
  const pending = clients.map(async (client, index) => {
    let began = false;
    try {
      await client.query('BEGIN');
      began = true;
      ready += 1;
      if (ready === clients.length) releaseReady();
      await go;
      const value = await operations[index](client);
      await client.query('COMMIT');
      began = false;
      return value;
    } catch (error) {
      if (began) await client.query('ROLLBACK').catch(() => undefined);
      throw error;
    } finally {
      client.release();
    }
  });
  await allReady;
  releaseGo();
  return await Promise.all(pending);
}

const cluster = await startPostgresCluster();
const bootstrapPool = new Pool(cluster.bootstrapConfig);
let appPool;

try {
  await applyMigrations({ pool: bootstrapPool, migrationsDir: accepted0006MigrationsDir });
  await seedCoreFixtures(bootstrapPool);
  appPool = new Pool({ ...appPoolConfig(cluster, 16), application_name: 'rss-auth-claims' });

  await bootstrapPool.query(
    `INSERT INTO roomscan.auth_session_families (
       id, public_id, principal_id, authentication_epoch, authenticated_at,
       created_at, last_used_at, inactivity_expires_at, absolute_expires_at,
       policy_version, workspace_id, role, authorization_version
     ) VALUES (
       $1, 'family_refresh_0001', $2, 0, $3, $3, $3,
       $3::timestamptz + interval '7 days', $3::timestamptz + interval '30 days',
       'session-v1', $4, 'owner', 1
     )`,
    [familyId, ids.principalA, now, ids.workspaceA],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.auth_refresh_tokens (token_hash, family_id, issued_at)
     VALUES ($1, $2, $3)`,
    [parentRefreshHash, familyId, now],
  );

  const issuanceFailSelector = 'IIIIIIIIIIIIIIIIIIIIII';
  const issuanceClient = await appPool.connect();
  try {
    await issuanceClient.query('BEGIN');
    await assert.rejects(async () => {
      await issuanceClient.query(
        `INSERT INTO roomscan.magic_link_rate_events (kind, subject_hash, occurred_at)
         VALUES ('request', $1, $2)`,
        [hash32('issuance-fail-rate'), now],
      );
      await issuanceClient.query(
        `INSERT INTO roomscan.magic_links (
           selector, secret_digest, purpose, normalized_delivery_identity,
           address_hash, network_hash, issued_at, expires_at, policy_version
         ) VALUES ($1, $2, 'sign-in', 'issuance-fail@example.invalid', $3, $4,
           $5, $5::timestamptz + interval '10 minutes', 'magic-link-v1')`,
        [issuanceFailSelector, hash32('issuance-fail-secret'), hash32('issuance-fail-address'), hash32('issuance-fail-network'), now],
      );
      await issuanceClient.query(
        `INSERT INTO roomscan.magic_link_delivery_outbox (
           id, selector, normalized_delivery_identity, purpose,
           envelope_version, key_id, iv, ciphertext, authentication_tag,
           created_at, expires_at, policy_version
         ) VALUES ('magic_issuance_failure', $1, 'issuance-fail@example.invalid',
           'sign-in', 'aes-256-gcm-v1', 'key-v1', $2, $3, $4, $5,
           $5::timestamptz + interval '10 minutes', 'magic-link-v1')`,
        [issuanceFailSelector, Buffer.alloc(12, 41), Buffer.alloc(31, 42), Buffer.alloc(16, 43), now],
      );
    }, (error) => error?.code === '23514');
    await issuanceClient.query('ROLLBACK');
  } finally {
    issuanceClient.release();
  }
  assert.equal(Number((await bootstrapPool.query(
    `SELECT count(*) AS count FROM roomscan.magic_links WHERE selector = $1`,
    [issuanceFailSelector],
  )).rows[0].count), 0);
  assert.equal(Number((await bootstrapPool.query(
    `SELECT count(*) AS count FROM roomscan.magic_link_rate_events
     WHERE subject_hash = $1`,
    [hash32('issuance-fail-rate')],
  )).rows[0].count), 0);

  const childHashes = [hash32('refresh-child-a'), hash32('refresh-child-b')];
  const refreshRace = await raceTransactions(appPool, childHashes.map((childHash) => async (client) => {
    const claimed = (await client.query(
      `SELECT roomscan.claim_refresh_rotation($1::bytea, $2::bytea, $3::timestamptz) AS claimed`,
      [parentRefreshHash, childHash, now],
    )).rows[0].claimed;
    if (claimed) {
      await client.query(
        `INSERT INTO roomscan.auth_refresh_tokens (token_hash, family_id, issued_at)
         VALUES ($1, $2, $3)`,
        [childHash, familyId, now],
      );
    } else {
      await client.query(
        `SELECT roomscan.revoke_session_family($1::uuid, $2::timestamptz, 'refresh_reuse')`,
        [familyId, new Date(now.getTime() + 1)],
      );
    }
    return claimed;
  }));
  assert.equal(refreshRace.filter(Boolean).length, 1);
  const refreshState = (await bootstrapPool.query(
    `SELECT parent.state, encode(parent.child_token_hash, 'hex') AS child,
            family.state AS family_state, family.revoke_reason,
            count(child.*)::int AS child_count
     FROM roomscan.auth_refresh_tokens AS parent
     JOIN roomscan.auth_session_families AS family ON family.id = parent.family_id
     LEFT JOIN roomscan.auth_refresh_tokens AS child
       ON child.token_hash = parent.child_token_hash
     WHERE parent.token_hash = $1
     GROUP BY parent.state, parent.child_token_hash, family.state, family.revoke_reason`,
    [parentRefreshHash],
  )).rows[0];
  assert.equal(refreshState.state, 'rotated');
  assert.equal(refreshState.child_count, 1);
  assert.equal(refreshState.family_state, 'revoked');
  assert.equal(refreshState.revoke_reason, 'refresh_reuse');

  const magicSelector = 'AAAAAAAAAAAAAAAAAAAAAA';
  await appPool.query(
    `INSERT INTO roomscan.magic_links (
       selector, secret_digest, purpose, normalized_delivery_identity,
       address_hash, network_hash, issued_at, expires_at, policy_version
     ) VALUES ($1, $2, 'sign-in', 'user@example.invalid', $3, $4, $5,
       $5::timestamptz + interval '10 minutes', 'magic-link-v1')`,
    [magicSelector, hash32('magic-secret'), hash32('magic-address'), hash32('magic-network'), now],
  );
  const magicRace = await raceTransactions(appPool, [0, 1].map(() => async (client) => (
    await client.query(
      `SELECT selector FROM roomscan.claim_magic_link($1::text, $2::bytea, NULL::text, $3::timestamptz)`,
      [magicSelector, hash32('magic-secret'), new Date(now.getTime() + 1_000)],
    )
  ).rows.length));
  assert.deepEqual(magicRace.sort(), [0, 1]);
  assert.equal((await bootstrapPool.query(
    `SELECT state FROM roomscan.magic_links WHERE selector = $1`,
    [magicSelector],
  )).rows[0].state, 'consumed');

  const receiptRollbackSelector = 'JJJJJJJJJJJJJJJJJJJJJJ';
  await appPool.query(
    `INSERT INTO roomscan.magic_links (
       selector, secret_digest, purpose, normalized_delivery_identity,
       address_hash, network_hash, issued_at, expires_at, policy_version,
       initiating_principal_id, initiating_family_id,
       initiating_authenticated_at
     ) VALUES ($1, $2, 'link-identity', 'receipt-fail@example.invalid', $3,
       $4, $5, $5::timestamptz + interval '10 minutes', 'magic-link-v1',
       $6, $7, $5)`,
    [receiptRollbackSelector, hash32('receipt-fail-secret'), hash32('receipt-fail-address'), hash32('receipt-fail-network'), now, ids.principalA, familyId],
  );
  const receiptRollbackClient = await appPool.connect();
  try {
    await receiptRollbackClient.query('BEGIN');
    await assert.rejects(async () => {
      assert.equal((await receiptRollbackClient.query(
        `SELECT count(*)::int AS count FROM roomscan.claim_magic_link(
           $1, $2, 'link-identity', $3
         )`,
        [receiptRollbackSelector, hash32('receipt-fail-secret'), new Date(now.getTime() + 1)],
      )).rows[0].count, 1);
      await receiptRollbackClient.query(
        `INSERT INTO roomscan.verified_authentication_receipts (
           token_hash, issuer, subject, purpose, initiating_principal_id,
           initiating_family_id, authenticated_at, issued_at, expires_at,
           policy_version
         ) VALUES ($1, $2, 'receipt-fail@example.invalid', 'link-identity',
           $3, $4, $5, $5, $5::timestamptz + interval '1 minute',
           'magic-link-v1')`,
        [hash32('receipt-fail-token'), 'x'.repeat(513), ids.principalA, familyId, now],
      );
    }, (error) => error?.code === '23514');
    await receiptRollbackClient.query('ROLLBACK');
  } finally {
    receiptRollbackClient.release();
  }
  assert.equal((await bootstrapPool.query(
    `SELECT state FROM roomscan.magic_links WHERE selector = $1`,
    [receiptRollbackSelector],
  )).rows[0].state, 'active');

  const siblingSelectors = ['BBBBBBBBBBBBBBBBBBBBBB', 'CCCCCCCCCCCCCCCCCCCCCC'];
  await bootstrapPool.query(
    `INSERT INTO roomscan.magic_links (
       selector, secret_digest, purpose, normalized_delivery_identity,
       address_hash, network_hash, issued_at, expires_at, policy_version
     ) VALUES
       ($1, $3, 'reauthenticate', 'siblings@example.invalid', $4, $5, $6,
        $6::timestamptz + interval '10 minutes', 'magic-link-v1'),
       ($2, $3, 'reauthenticate', 'siblings@example.invalid', $4, $5,
        $6::timestamptz + interval '1 second', $6::timestamptz + interval '10 minutes',
        'magic-link-v1')`,
    [siblingSelectors[0], siblingSelectors[1], hash32('sibling-secret'), hash32('sibling-address'), hash32('sibling-network'), now],
  );
  assert.equal((await appPool.query(
    `SELECT roomscan.supersede_magic_link_siblings($1::text, $2::timestamptz) AS count`,
    [siblingSelectors[1], new Date(now.getTime() + 2_000)],
  )).rows[0].count, 1);

  const supersedeSelector = 'FFFFFFFFFFFFFFFFFFFFFF';
  await appPool.query(
    `INSERT INTO roomscan.magic_links (
       selector, secret_digest, purpose, normalized_delivery_identity,
       address_hash, network_hash, issued_at, expires_at, policy_version
     ) VALUES ($1, $2, 'sign-in', 'supersede@example.invalid', $3, $4, $5,
       $5::timestamptz + interval '10 minutes', 'magic-link-v1')`,
    [supersedeSelector, hash32('supersede-secret'), hash32('supersede-address'), hash32('supersede-network'), now],
  );
  const supersedeRace = await raceTransactions(appPool, [0, 1].map(() => async (client) => (
    await client.query(
      `SELECT roomscan.supersede_magic_link($1, $2) AS superseded`,
      [supersedeSelector, new Date(now.getTime() + 2_500)],
    )
  ).rows[0].superseded));
  assert.deepEqual(supersedeRace.sort(), [false, true]);

  const deliverySelector = 'DDDDDDDDDDDDDDDDDDDDDD';
  const deliveryId = 'magic_delivery_0001';
  await bootstrapPool.query(
    `INSERT INTO roomscan.magic_links (
       selector, secret_digest, purpose, normalized_delivery_identity,
       address_hash, network_hash, issued_at, expires_at, policy_version
     ) VALUES ($1, $2, 'sign-in', 'delivery@example.invalid', $3, $4, $5,
       $5::timestamptz + interval '10 minutes', 'magic-link-v1')`,
    [deliverySelector, hash32('delivery-secret'), hash32('delivery-address'), hash32('delivery-network'), now],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.magic_link_delivery_outbox (
       id, selector, normalized_delivery_identity, purpose, envelope_version,
       key_id, iv, ciphertext, authentication_tag, created_at, expires_at,
       policy_version
     ) VALUES ($1, $2, 'delivery@example.invalid', 'sign-in', 'aes-256-gcm-v1',
       'key-v1', $3, $4, $5, $6, $6::timestamptz + interval '10 minutes',
       'magic-link-v1')`,
    [
      deliveryId,
      deliverySelector,
      Buffer.alloc(12, 1),
      Buffer.alloc(32, 2),
      Buffer.alloc(16, 3),
      now,
    ],
  );
  const leaseIds = ['magic_lease_alpha', 'magic_lease_bravo'];
  const deliveryRace = await raceTransactions(appPool, leaseIds.map((leaseId) => async (client) => {
    const rows = (await client.query(
      `SELECT id, lease_id FROM roomscan.claim_magic_delivery(
         $1::text, $2::text, $3::timestamptz, $4::timestamptz
       )`,
      [deliveryId, leaseId, now, new Date(now.getTime() + 30_000)],
    )).rows;
    return rows[0]?.lease_id;
  }));
  const winningDeliveryLease = deliveryRace.find(Boolean);
  assert.equal(deliveryRace.filter(Boolean).length, 1);
  assert.equal((await appPool.query(
    `SELECT roomscan.complete_magic_delivery($1::text, $2::text, $3::timestamptz) AS completed`,
    [deliveryId, winningDeliveryLease, new Date(now.getTime() + 2_000)],
  )).rows[0].completed, true);

  const expiringSelector = 'EEEEEEEEEEEEEEEEEEEEEE';
  const expiringDeliveryId = 'magic_delivery_expiry';
  await bootstrapPool.query(
    `INSERT INTO roomscan.magic_links (
       selector, secret_digest, purpose, normalized_delivery_identity,
       address_hash, network_hash, issued_at, expires_at, policy_version
     ) VALUES ($1, $2, 'sign-in', 'expiry@example.invalid', $3, $4, $5,
       $5::timestamptz + interval '10 seconds', 'magic-link-v1')`,
    [expiringSelector, hash32('expiry-secret'), hash32('expiry-address'), hash32('expiry-network'), now],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.magic_link_delivery_outbox (
       id, selector, normalized_delivery_identity, purpose, envelope_version,
       key_id, iv, ciphertext, authentication_tag, created_at, expires_at,
       policy_version
     ) VALUES ($1, $2, 'expiry@example.invalid', 'sign-in', 'aes-256-gcm-v1',
       'key-v1', $3, $4, $5, $6, $6::timestamptz + interval '10 seconds',
       'magic-link-v1')`,
    [expiringDeliveryId, expiringSelector, Buffer.alloc(12, 4), Buffer.alloc(32, 5), Buffer.alloc(16, 6), now],
  );
  assert.equal((await appPool.query(
    `SELECT count(*)::int AS count FROM roomscan.claim_magic_delivery($1, 'expiry_lease', $2, $3)`,
    [expiringDeliveryId, new Date(now.getTime() + 9_000), new Date(now.getTime() + 10_000)],
  )).rows[0].count, 1);
  const preSend = (await appPool.query(
    `SELECT state FROM roomscan.validate_magic_delivery($1, 'expiry_lease', $2)`,
    [expiringDeliveryId, new Date(now.getTime() + 10_000)],
  )).rows[0];
  assert.deepEqual(preSend, { state: 'expired' });
  assert.equal((await appPool.query(
    `SELECT roomscan.complete_magic_delivery($1, 'expiry_lease', $2) AS completed`,
    [expiringDeliveryId, new Date(now.getTime() + 10_001)],
  )).rows[0].completed, false);

  const releasableSelector = 'GGGGGGGGGGGGGGGGGGGGGG';
  const releasableDeliveryId = 'magic_delivery_release';
  await bootstrapPool.query(
    `INSERT INTO roomscan.magic_links (
       selector, secret_digest, purpose, normalized_delivery_identity,
       address_hash, network_hash, issued_at, expires_at, policy_version
     ) VALUES ($1, $2, 'sign-in', 'release@example.invalid', $3, $4, $5,
       $5::timestamptz + interval '10 minutes', 'magic-link-v1')`,
    [releasableSelector, hash32('release-secret'), hash32('release-address'), hash32('release-network'), now],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.magic_link_delivery_outbox (
       id, selector, normalized_delivery_identity, purpose, envelope_version,
       key_id, iv, ciphertext, authentication_tag, created_at, expires_at,
       policy_version
     ) VALUES ($1, $2, 'release@example.invalid', 'sign-in', 'aes-256-gcm-v1',
       'key-v1', $3, $4, $5, $6, $6::timestamptz + interval '10 minutes',
       'magic-link-v1')`,
    [releasableDeliveryId, releasableSelector, Buffer.alloc(12, 7), Buffer.alloc(32, 8), Buffer.alloc(16, 9), now],
  );
  assert.equal((await appPool.query(
    `SELECT lease_id FROM roomscan.claim_magic_delivery($1, 'release_lease', $2, $3)`,
    [releasableDeliveryId, new Date(now.getTime() + 3_000), new Date(now.getTime() + 33_000)],
  )).rows[0].lease_id, 'release_lease');
  assert.equal((await appPool.query(
    `SELECT roomscan.release_magic_delivery($1, 'release_lease', $2) AS status`,
    [releasableDeliveryId, new Date(now.getTime() + 3_001)],
  )).rows[0].status, 'released');
  assert.equal((await appPool.query(
    `SELECT lease_id FROM roomscan.claim_magic_delivery($1, 'cancel_lease', $2, $3)`,
    [releasableDeliveryId, new Date(now.getTime() + 3_002), new Date(now.getTime() + 33_002)],
  )).rows[0].lease_id, 'cancel_lease');
  assert.equal((await appPool.query(
    `SELECT roomscan.cancel_magic_delivery(
       $1, 'lost_lease', 'unknown_key', $2
     ) AS cancelled`,
    [releasableDeliveryId, new Date(now.getTime() + 3_003)],
  )).rows[0].cancelled, false);
  assert.equal((await appPool.query(
    `SELECT roomscan.cancel_magic_delivery(
       $1, 'cancel_lease', 'unknown_key', $2
     ) AS cancelled`,
    [releasableDeliveryId, new Date(now.getTime() + 3_004)],
  )).rows[0].cancelled, true);

  const attemptId = 'apple_attempt_000001';
  const stateHash = hash32('apple-state');
  const nonceHash = hash32('apple-nonce');
  const codeHash = hash32('apple-code');
  const challenge = 'C'.repeat(43);
  await appPool.query(
    `INSERT INTO roomscan.apple_auth_attempts (
       id, state_hash, nonce_hash, code_challenge, expected_client_id,
       redirect_uri, created_at, expires_at, policy_version, purpose
     ) VALUES ($1, $2, $3, $4, 'com.roomscan.studio',
       'https://example.invalid/apple/callback', $5,
       $5::timestamptz + interval '5 minutes', 'apple-auth-v1', 'sign-in')`,
    [attemptId, stateHash, nonceHash, challenge, now],
  );
  const appleRace = await raceTransactions(appPool, [0, 1].map(() => async (client) => (
    await client.query(
      `SELECT status FROM roomscan.claim_apple_attempt_and_code(
         $1::text, $2::bytea, $3::text, $4::bytea, $5::timestamptz
       )`,
      [attemptId, stateHash, challenge, codeHash, new Date(now.getTime() + 1_000)],
    )
  ).rows[0].status));
  assert.deepEqual(appleRace.sort(), ['claimed', 'replayed_code']);
  const invalidAttemptResult = (await appPool.query(
    `SELECT status FROM roomscan.claim_apple_attempt_and_code(
       'apple_attempt_missing', $1, $2, $3, $4
     )`,
    [hash32('missing-state'), challenge, hash32('missing-code'), new Date(now.getTime() + 1_000)],
  )).rows[0].status;
  assert.equal(invalidAttemptResult, 'invalid_attempt');
  assert.equal(Number((await bootstrapPool.query(
    `SELECT count(*) AS count FROM roomscan.apple_code_receipts
     WHERE code_hash = $1`,
    [hash32('missing-code')],
  )).rows[0].count), 0);

  const crossAttemptIds = ['apple_attempt_cross_01', 'apple_attempt_cross_02'];
  await appPool.query(
    `INSERT INTO roomscan.apple_auth_attempts (
       id, state_hash, nonce_hash, code_challenge, expected_client_id,
       redirect_uri, created_at, expires_at, policy_version, purpose
     ) VALUES
       ($1, $3, $4, $5, 'com.roomscan.studio',
        'https://example.invalid/apple/callback', $6,
        $6::timestamptz + interval '5 minutes', 'apple-auth-v1', 'sign-in'),
       ($2, $7, $8, $5, 'com.roomscan.studio',
        'https://example.invalid/apple/callback', $6,
        $6::timestamptz + interval '5 minutes', 'apple-auth-v1', 'sign-in')`,
    [crossAttemptIds[0], crossAttemptIds[1], hash32('cross-state-a'), hash32('cross-nonce-a'), challenge, now, hash32('cross-state-b'), hash32('cross-nonce-b')],
  );
  const crossCodeHash = hash32('cross-attempt-code');
  const crossAttemptRace = await raceTransactions(appPool, [
    { attemptId: crossAttemptIds[0], stateHash: hash32('cross-state-a') },
    { attemptId: crossAttemptIds[1], stateHash: hash32('cross-state-b') },
  ].map(({ attemptId: currentAttemptId, stateHash: currentStateHash }) => async (client) => (
    await client.query(
      `SELECT status FROM roomscan.claim_apple_attempt_and_code($1, $2, $3, $4, $5)`,
      [currentAttemptId, currentStateHash, challenge, crossCodeHash, new Date(now.getTime() + 1_500)],
    )
  ).rows[0].status));
  assert.deepEqual(crossAttemptRace.sort(), ['claimed', 'replayed_code']);
  const nonceRace = await raceTransactions(appPool, [0, 1].map(() => async (client) => (
    await client.query(
      `SELECT roomscan.claim_apple_nonce($1::bytea, $2::timestamptz) AS claimed`,
      [nonceHash, new Date(now.getTime() + 2_000)],
    )
  ).rows[0].claimed));
  assert.deepEqual(nonceRace.sort(), [false, true]);

  await appPool.query(
    `INSERT INTO roomscan.apple_bridge_proofs (
       token_hash, issuer, subject, attempt_id, purpose, issued_at, expires_at,
       policy_version
     ) VALUES ($1, 'https://appleid.apple.com', 'apple-subject', $2, 'sign-in',
       $3, $3::timestamptz + interval '1 minute', 'apple-auth-v1')`,
    [hash32('bridge-proof'), attemptId, now],
  );
  const bridgeRace = await raceTransactions(appPool, [0, 1].map(() => async (client) => (
    await client.query(
      `SELECT token_hash FROM roomscan.claim_apple_bridge_proof(
         $1::bytea, 'https://appleid.apple.com', 'apple-subject', $2::text,
         'sign-in', $3::timestamptz
       )`,
      [hash32('bridge-proof'), attemptId, new Date(now.getTime() + 2_000)],
    )
  ).rows.length));
  assert.deepEqual(bridgeRace.sort(), [0, 1]);

  await appPool.query(
    `INSERT INTO roomscan.verified_authentication_receipts (
       token_hash, issuer, subject, purpose, initiating_principal_id,
       initiating_family_id, authenticated_at, issued_at, expires_at,
       policy_version
     ) VALUES ($1, 'email', 'candidate@example.invalid', 'link-identity', $2,
       $3, $4, $4, $4::timestamptz + interval '1 minute', 'identity-link-v2')`,
    [hash32('verified-receipt'), ids.principalA, familyId, now],
  );
  await appPool.query(
    `INSERT INTO roomscan.candidate_identity_proofs (
       token_hash, issuer, subject, purpose, initiating_principal_id,
       initiating_family_id, authenticated_at, issued_at, expires_at,
       policy_version
     ) VALUES ($1, 'email', 'candidate@example.invalid', 'link-identity', $2,
       $3, $4, $4, $4::timestamptz + interval '5 minutes', 'identity-link-v2')`,
    [hash32('candidate-proof'), ids.principalA, familyId, now],
  );
  const receiptRace = await raceTransactions(appPool, [0, 1].map(() => async (client) => (
    await client.query(
      `SELECT token_hash FROM roomscan.claim_verified_auth_receipt(
         $1::bytea, 'email', 'link-identity', $2::uuid, $3::uuid, $4::timestamptz
       )`,
      [hash32('verified-receipt'), ids.principalA, familyId, new Date(now.getTime() + 1_000)],
    )
  ).rows.length));
  assert.deepEqual(receiptRace.sort(), [0, 1]);
  const candidateRace = await raceTransactions(appPool, [0, 1].map(() => async (client) => (
    await client.query(
      `SELECT token_hash FROM roomscan.claim_candidate_identity_proof(
         $1::bytea, 'link-identity', $2::uuid, $3::uuid, $4::timestamptz
       )`,
      [hash32('candidate-proof'), ids.principalA, familyId, new Date(now.getTime() + 1_000)],
    )
  ).rows.length));
  assert.deepEqual(candidateRace.sort(), [0, 1]);

  for (const table of [
    'auth_session_families',
    'auth_access_tokens',
    'auth_refresh_tokens',
    'magic_links',
    'magic_link_delivery_outbox',
    'apple_auth_attempts',
    'apple_bridge_proofs',
    'verified_authentication_receipts',
    'candidate_identity_proofs',
  ]) {
    await assert.rejects(
      () => appPool.query(`UPDATE roomscan.${table} SET state = state`),
      (error) => error?.code === '42501',
    );
    await assert.rejects(
      () => appPool.query(`DELETE FROM roomscan.${table}`),
      (error) => error?.code === '42501',
    );
    await assert.rejects(
      () => appPool.query(`TRUNCATE roomscan.${table}`),
      (error) => error?.code === '42501',
    );
  }

  console.log('AUTH_CLAIMS_SUMMARY refresh_winners=1 durable_replay_revocation=true magic_issuance_rollback=true magic_winners=1 magic_receipt_rollback=true supersede_winners=1 delivery_winners=1 presend_expiry=true release_cancel=true apple_attempt_winners=1 cross_attempt_code_winners=1 invalid_attempt_receipt_free=true nonce_winners=1 bridge_winners=1 receipt_winners=1 candidate_winners=1 direct_mutation_denied=9x3 status=pass');
} finally {
  await appPool?.end();
  await bootstrapPool.end();
  console.error(`AUTH_CLAIMS_CLEANUP ${JSON.stringify(await cluster.stop())}`);
}
