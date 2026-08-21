import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { appPoolConfig, hash32, ids, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const cluster = await startPostgresCluster();
const bootstrap = new Pool(cluster.bootstrapConfig);
let api;
let sequence = 1;
const baseNow = new Date('2026-08-19T19:00:00.000Z');

function s256(verifier) {
  return createHash('sha256').update(verifier).digest('base64url');
}

async function setSignIn(enabled, at = baseNow) {
  const current = (await bootstrap.query(
    `SELECT version FROM roomscan.global_operational_flags
      WHERE flag_key = 'professional_sign_in_enabled'`,
  )).rows[0]?.version ?? null;
  await bootstrap.query('SET ROLE roomscan_operator');
  try {
    await bootstrap.query(
      `SELECT * FROM roomscan.set_operational_flag(
         'global', NULL, 'professional_sign_in_enabled', $1, $2,
         'magic v3 integration', $3, $4
       )`,
      [enabled, current, `ofaud_magicv3flag${String(sequence++).padStart(8, '0')}`, at],
    );
  } finally {
    await bootstrap.query('RESET ROLE');
  }
}

async function insertUnscopedAccess(principalId, label, authenticatedAt = baseNow) {
  const familyId = `69000000-0000-4000-8000-${String(sequence++).padStart(12, '0')}`;
  const familyPublicId = `fam_magicv3${label.replaceAll('-', '')}${String(sequence++).padStart(6, '0')}`;
  const accessHash = hash32(`magic-v3-access:${label}`);
  await bootstrap.query(
    `INSERT INTO roomscan.auth_session_families (
       id, public_id, principal_id, authentication_epoch, authenticated_at,
       last_used_at, inactivity_expires_at, absolute_expires_at,
       policy_version, state, created_at
     ) SELECT $1, $2, principal.id, principal.authentication_epoch,
       $3, $3, $3::timestamptz + interval '1 day',
       $3::timestamptz + interval '7 days', 'session-v3', 'active', $3
       FROM roomscan.principals AS principal WHERE principal.id = $4`,
    [familyId, familyPublicId, authenticatedAt, principalId],
  );
  await bootstrap.query(
    `INSERT INTO roomscan.auth_access_tokens (
       id, family_id, token_hash, expires_at, principal_id,
       authentication_epoch, authenticated_at, issued_at, state, created_at
     ) SELECT gen_random_uuid(), family.id, $1,
       $2::timestamptz + interval '1 hour', family.principal_id,
       family.authentication_epoch, family.authenticated_at, $2,
       'active', $2 FROM roomscan.auth_session_families AS family
       WHERE family.id = $3`,
    [accessHash, authenticatedAt, familyId],
  );
  return { familyId, familyPublicId, accessHash };
}

const issueSql = `SELECT * FROM roomscan.issue_magic_challenge_v3(
  $1::bytea, $2::timestamptz, $3, $4::bytea, $5::bytea, $6,
  $7, $8, $9::bytea, $10::bytea, $11::timestamptz,
  $12, $13, $14, $15::bytea, $16::bytea, $17::bytea,
  $18, $19, $20, $21, $22, $23, $24, $25, $26, $27, $28
)`;

async function issue(label, {
  purpose = 'sign-in', accessHash = null, identity = `${label}@example.invalid`,
  now = baseNow, expiresAt = new Date(now.getTime() + 10 * 60_000),
  maxCompletionFailures = 3, redeemNetworkWindowSeconds = 900,
  maxRedeemNetworkFailures = 10,
} = {}) {
  const index = String(sequence++).padStart(20, '0');
  const selector = `V3${index}`;
  const verifier = `verifier-${label}-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789`;
  const completionId = `completion-${label}-raw-canary`;
  const transferCode = `CODE${String(sequence++).padStart(4, '0')}`;
  const values = [
    accessHash, now, selector, hash32(`secret:${label}`),
    hash32(`completion-hmac:${completionId}`), s256(verifier), purpose, identity,
    hash32(`address:${label}`), hash32(`issue-network:${label}`), expiresAt,
    'magic-v3', `mdl_magicv3_${label}_${index}`, 'magic-key-v3',
    Buffer.alloc(12, sequence % 255), Buffer.alloc(32, (sequence + 1) % 255),
    Buffer.alloc(16, (sequence + 2) % 255),
    0, 2, 900, 3, 86400, 10, 900, 20,
    maxCompletionFailures, redeemNetworkWindowSeconds, maxRedeemNetworkFailures,
  ];
  const result = (await api.query(issueSql, values)).rows[0];
  return {
    label, purpose, selector, verifier, completionId, transferCode,
    secretDigest: values[3], completionHash: values[4], codeChallenge: values[5],
    transferDigest: hash32(`transfer-hmac:${transferCode}`),
    expiresAt, result,
  };
}

const confirmSql = `SELECT * FROM roomscan.consume_magic_challenge_v3(
  $1, $2::bytea, $3, $4::timestamptz, $5::bytea
)`;

async function confirm(flow, {
  purpose = flow.purpose, at = new Date(baseNow.getTime() + 1_000),
  transferDigest = flow.transferDigest,
} = {}) {
  return (await api.query(confirmSql, [
    flow.selector, flow.secretDigest, purpose, at, transferDigest,
  ])).rows[0];
}

function sessionMaterial(label, now = new Date(baseNow.getTime() + 2_000)) {
  return {
    receiptHash: null, receiptExpiresAt: null,
    familyPublicId: `fam_magicv3session${label.replaceAll('-', '')}0001`,
    accessHash: hash32(`v3-session-access:${label}`),
    refreshHash: hash32(`v3-session-refresh:${label}`),
    accessExpiresAt: new Date(now.getTime() + 5 * 60_000),
    inactivityExpiresAt: new Date(now.getTime() + 7 * 86400_000),
    absoluteExpiresAt: new Date(now.getTime() + 30 * 86400_000),
    sessionPolicyVersion: 'session-v3',
  };
}

function receiptMaterial(label, now = new Date(baseNow.getTime() + 2_000)) {
  return {
    receiptHash: hash32(`v3-receipt:${label}`),
    receiptExpiresAt: new Date(now.getTime() + 2 * 60_000),
    familyPublicId: null, accessHash: null, refreshHash: null,
    accessExpiresAt: null, inactivityExpiresAt: null, absoluteExpiresAt: null,
    sessionPolicyVersion: null,
  };
}

const redeemSql = `SELECT * FROM roomscan.redeem_magic_completion_v3(
  $1::bytea, $2, $3::bytea, $4, $5::bytea, $6::timestamptz,
  $7::bytea, $8::timestamptz, $9, $10::bytea, $11::bytea,
  $12::timestamptz, $13::timestamptz, $14::timestamptz, $15
)`;

async function redeem(flow, material, {
  codeChallenge = flow.codeChallenge, transferDigest = flow.transferDigest,
  purpose = flow.purpose, networkHash = hash32('redeem-network-default'),
  at = new Date(baseNow.getTime() + 2_000),
} = {}) {
  return (await api.query(redeemSql, [
    flow.completionHash, codeChallenge, transferDigest, purpose, networkHash, at,
    material.receiptHash, material.receiptExpiresAt, material.familyPublicId,
    material.accessHash, material.refreshHash, material.accessExpiresAt,
    material.inactivityExpiresAt, material.absoluteExpiresAt,
    material.sessionPolicyVersion,
  ])).rows[0];
}

async function waitForAdvisoryWaiters(expected, timeoutMs = 1_500) {
  const deadline = Date.now() + timeoutMs;
  let observed = 0;
  while (Date.now() < deadline) {
    const result = await bootstrap.query(
      `SELECT count(*)::integer AS count
         FROM pg_catalog.pg_stat_activity
        WHERE application_name = 'rss-0007-magic-completion-v3'
          AND wait_event_type = 'Lock'
          AND wait_event = 'advisory'`,
    );
    observed = Math.max(observed, Number(result.rows[0].count));
    if (observed >= expected) return observed;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  return observed;
}

try {
  await applyMigrations({ pool: bootstrap });
  await seedCoreFixtures(bootstrap);
  await setSignIn(true);
  api = new Pool({
    ...appPoolConfig(cluster, 12), user: 'roomscan_api_runtime', max: 12,
    application_name: 'rss-0007-magic-completion-v3',
  });

  const basic = await issue('basic');
  assert.deepEqual(basic.result, {
    status: 'issued', selector: basic.selector, expires_at: basic.expiresAt,
  });
  const basicMaterial = sessionMaterial('basic');
  assert.equal((await redeem(basic, basicMaterial)).status, 'pending_confirmation');
  const confirmed = await confirm(basic);
  assert.deepEqual(Object.keys(confirmed).sort(), [
    'confirmed_at', 'expires_at', 'purpose', 'status',
  ]);
  assert.equal(confirmed.status, 'confirmed');
  assert.equal((await confirm(basic)).status, 'already_confirmed');
  assert.equal((await confirm(basic, {
    transferDigest: hash32('changed-confirm-transfer'),
  })).status, 'unavailable');

  const blindClick = await redeem(basic, basicMaterial, {
    transferDigest: hash32('attacker-has-completion-and-verifier-not-code'),
  });
  assert.equal(blindClick.status, 'unavailable');
  assert.equal(Number((await bootstrap.query(
    `SELECT failed_attempts FROM roomscan.magic_completion_handoffs
      WHERE completion_id_hash = $1`, [basic.completionHash],
  )).rows[0].failed_attempts), 1);

  const issued = await redeem(basic, basicMaterial);
  assert.equal(issued.status, 'session_issued');
  assert.equal(issued.principal_canonical_id.startsWith('prn_'), true);
  assert.equal(issued.workspace_id, null);
  assert.equal(issued.access_expires_at.toISOString(), basicMaterial.accessExpiresAt.toISOString());
  assert.equal(issued.receipt_expires_at, null);
  const replay = await redeem(basic, basicMaterial, {
    at: new Date(baseNow.getTime() + 3_000),
  });
  assert.equal(replay.status, 'session_replayed');
  assert.equal(replay.family_id, issued.family_id);
  assert.equal(replay.access_expires_at.toISOString(), issued.access_expires_at.toISOString());
  const statelessReplayMaterial = sessionMaterial(
    'basic', new Date(baseNow.getTime() + 3_000),
  );
  const statelessReplay = await redeem(basic, statelessReplayMaterial, {
    at: new Date(baseNow.getTime() + 3_000),
  });
  assert.equal(statelessReplay.status, 'session_replayed');
  assert.equal(statelessReplay.access_expires_at.toISOString(), issued.access_expires_at.toISOString());
  assert.equal((await redeem(basic, {
    ...basicMaterial, accessHash: hash32('changed-replay-material'),
  })).status, 'unavailable');

  const expiredAccess = await issue('expired-access-replay');
  await confirm(expiredAccess);
  const expiredAccessMaterial = {
    ...sessionMaterial('expired-access-replay'),
    accessExpiresAt: new Date(baseNow.getTime() + 3_000),
  };
  assert.equal((await redeem(expiredAccess, expiredAccessMaterial)).status, 'session_issued');
  assert.equal((await redeem(
    expiredAccess,
    sessionMaterial('expired-access-replay', new Date(baseNow.getTime() + 4_000)),
    { at: new Date(baseNow.getTime() + 4_000) },
  )).status, 'unavailable');

  const expiredFamily = await issue('expired-family-replay');
  await confirm(expiredFamily);
  const expiredFamilyMaterial = {
    ...sessionMaterial('expired-family-replay'),
    inactivityExpiresAt: new Date(baseNow.getTime() + 3_000),
  };
  assert.equal((await redeem(expiredFamily, expiredFamilyMaterial)).status, 'session_issued');
  assert.equal((await redeem(
    expiredFamily,
    sessionMaterial('expired-family-replay', new Date(baseNow.getTime() + 4_000)),
    { at: new Date(baseNow.getTime() + 4_000) },
  )).status, 'unavailable');

  const loggedOutReplay = await issue('logged-out-replay');
  await confirm(loggedOutReplay);
  const loggedOutMaterial = sessionMaterial('logged-out-replay');
  assert.equal((await redeem(loggedOutReplay, loggedOutMaterial)).status, 'session_issued');
  assert.equal((await api.query(
    `SELECT status FROM roomscan.logout_all_from_access($1, $2)`,
    [loggedOutMaterial.accessHash, new Date(baseNow.getTime() + 3_000)],
  )).rows[0].status, 'revoked');
  assert.equal((await redeem(
    loggedOutReplay,
    sessionMaterial('logged-out-replay', new Date(baseNow.getTime() + 4_000)),
    { at: new Date(baseNow.getTime() + 4_000) },
  )).status, 'unavailable');

  const raceFlow = await issue('race');
  await confirm(raceFlow);
  const raceMaterial = sessionMaterial('race');
  const race = await Promise.all(Array.from({ length: 6 }, () =>
    redeem(raceFlow, raceMaterial, { networkHash: hash32('race-network') })));
  assert.equal(race.filter(({ status }) => status === 'session_issued').length, 1);
  assert.equal(race.filter(({ status }) => status === 'session_replayed').length, 5);
  assert.equal(new Set(race.map(({ family_id: familyId }) => familyId)).size, 1);

  const locked = await issue('locked', { maxCompletionFailures: 2 });
  await confirm(locked);
  const lockedMaterial = sessionMaterial('locked');
  assert.equal((await redeem(locked, lockedMaterial, {
    transferDigest: hash32('wrong-code-one'), networkHash: hash32('lock-network'),
  })).status, 'unavailable');
  assert.equal((await redeem(locked, lockedMaterial, {
    transferDigest: hash32('wrong-code-two'), networkHash: hash32('lock-network'),
  })).status, 'rate_limited');
  assert.equal((await redeem(locked, lockedMaterial, {
    networkHash: hash32('different-network-cannot-bypass-completion-lock'),
  })).status, 'rate_limited');

  const networkOne = await issue('network-one', {
    maxCompletionFailures: 5, maxRedeemNetworkFailures: 2,
  });
  const networkTwo = await issue('network-two', {
    maxCompletionFailures: 5, maxRedeemNetworkFailures: 2,
  });
  await confirm(networkOne);
  await confirm(networkTwo);
  const sharedNetwork = hash32('shared-failure-network');
  assert.equal((await redeem(networkOne, sessionMaterial('network-one'), {
    transferDigest: hash32('network-wrong-one'), networkHash: sharedNetwork,
  })).status, 'unavailable');
  assert.equal((await redeem(networkTwo, sessionMaterial('network-two'), {
    transferDigest: hash32('network-wrong-two'), networkHash: sharedNetwork,
  })).status, 'unavailable');
  assert.equal((await redeem(networkOne, sessionMaterial('network-one'), {
    transferDigest: hash32('network-wrong-three'), networkHash: sharedNetwork,
  })).status, 'rate_limited');

  const networkRaceOne = await issue('network-race-one', {
    maxCompletionFailures: 5, maxRedeemNetworkFailures: 1,
  });
  const networkRaceTwo = await issue('network-race-two', {
    maxCompletionFailures: 5, maxRedeemNetworkFailures: 1,
  });
  await confirm(networkRaceOne);
  await confirm(networkRaceTwo);
  const racedNetwork = hash32('shared-concurrent-failure-network');
  const blocker = await bootstrap.connect();
  let racedResults = [];
  let racedAttempts = [];
  try {
    await blocker.query(
      `SELECT pg_catalog.pg_advisory_lock(pg_catalog.hashtextextended(
         'magic-redeem-network:' || pg_catalog.encode($1::bytea, 'hex'),
         7621846213719046
       ))`,
      [racedNetwork],
    );
    racedAttempts = [
      redeem(networkRaceOne, sessionMaterial('network-race-one'), {
        transferDigest: hash32('network-race-wrong-one'), networkHash: racedNetwork,
      }),
      redeem(networkRaceTwo, sessionMaterial('network-race-two'), {
        transferDigest: hash32('network-race-wrong-two'), networkHash: racedNetwork,
      }),
    ];
    assert.equal(await waitForAdvisoryWaiters(2), 2);
  } finally {
    await blocker.query(
      `SELECT pg_catalog.pg_advisory_unlock(pg_catalog.hashtextextended(
         'magic-redeem-network:' || pg_catalog.encode($1::bytea, 'hex'),
         7621846213719046
       ))`,
      [racedNetwork],
    );
    if (racedAttempts.length > 0) racedResults = await Promise.all(racedAttempts);
    blocker.release();
  }
  assert.deepEqual(
    racedResults.map(({ status }) => status).sort(),
    ['rate_limited', 'unavailable'],
  );
  assert.equal(Number((await bootstrap.query(
    `SELECT count(*) AS count
       FROM roomscan.magic_completion_redeem_failures
      WHERE network_hash = $1`,
    [racedNetwork],
  )).rows[0].count), 1);

  const disabled = await issue('disabled');
  await confirm(disabled);
  await setSignIn(false, new Date(baseNow.getTime() + 4_000));
  assert.equal((await redeem(disabled, sessionMaterial('disabled'), {
    at: new Date(baseNow.getTime() + 5_000),
  })).status, 'professional_sign_in_disabled');
  assert.equal((await bootstrap.query(
    `SELECT state FROM roomscan.magic_completion_handoffs
      WHERE completion_id_hash = $1`, [disabled.completionHash],
  )).rows[0].state, 'confirmed');
  await setSignIn(true, new Date(baseNow.getTime() + 6_000));

  const scoped = await issue('returning', { identity: 'principal-a-v3@example.invalid' });
  await bootstrap.query(
    `INSERT INTO roomscan.external_identities (
       id, principal_id, issuer, subject, linked_at, created_at
     ) VALUES (gen_random_uuid(), $1, 'email', $2, $3, $3)`,
    [ids.principalA, 'principal-a-v3@example.invalid', baseNow],
  );
  await confirm(scoped);
  const scopedResult = await redeem(scoped, sessionMaterial('returning'));
  assert.equal(scopedResult.workspace_id, ids.workspaceA);
  assert.equal(scopedResult.role, 'owner');
  assert.equal(scopedResult.authorization_version, '1');
  await bootstrap.query(
    `INSERT INTO roomscan.memberships (
       id, workspace_id, principal_id, role, state,
       authorization_version, created_at, updated_at
     ) VALUES (
       '69000000-0000-4000-8000-000000000099', $1, $2,
       'owner', 'active', 1, $3, $3
     )`,
    [ids.workspaceA, ids.principalB, new Date(baseNow.getTime() + 2_500)],
  );
  const staleMembershipUpdate = await bootstrap.query(
    `UPDATE roomscan.memberships
        SET role = 'viewer'
      WHERE workspace_id = $1 AND principal_id = $2`,
    [ids.workspaceA, ids.principalA],
  );
  assert.equal(staleMembershipUpdate.rowCount, 1);
  assert.equal((await redeem(
    scoped,
    sessionMaterial('returning', new Date(baseNow.getTime() + 3_000)),
    { at: new Date(baseNow.getTime() + 3_000) },
  )).status, 'unavailable');

  const candidateAccess = await insertUnscopedAccess(ids.principalA, 'candidate');
  const candidate = await issue('candidate', {
    purpose: 'link-identity', accessHash: candidateAccess.accessHash,
    identity: 'candidate-v3@example.invalid',
  });
  await confirm(candidate);
  const candidateMaterial = receiptMaterial('candidate');
  const receipt = await redeem(candidate, candidateMaterial);
  assert.equal(receipt.status, 'receipt_issued');
  assert.equal(receipt.family_id, candidateAccess.familyId);
  assert.equal(receipt.access_expires_at, null);
  assert.equal(receipt.receipt_expires_at.toISOString(), candidateMaterial.receiptExpiresAt.toISOString());
  assert.equal((await redeem(candidate, candidateMaterial)).status, 'receipt_replayed');
  const statelessReceiptReplay = await redeem(
    candidate,
    receiptMaterial('candidate', new Date(baseNow.getTime() + 3_000)),
    { at: new Date(baseNow.getTime() + 3_000) },
  );
  assert.equal(statelessReceiptReplay.status, 'receipt_replayed');
  assert.equal(
    statelessReceiptReplay.receipt_expires_at.toISOString(),
    receipt.receipt_expires_at.toISOString(),
  );

  const expiredReceiptAccess = await insertUnscopedAccess(ids.principalA, 'expired-receipt');
  const expiredReceipt = await issue('expired-receipt', {
    purpose: 'unlink-identity', accessHash: expiredReceiptAccess.accessHash,
    identity: 'expired-receipt@example.invalid',
  });
  await confirm(expiredReceipt);
  const expiredReceiptMaterial = {
    ...receiptMaterial('expired-receipt'),
    receiptExpiresAt: new Date(baseNow.getTime() + 3_000),
  };
  assert.equal((await redeem(expiredReceipt, expiredReceiptMaterial)).status, 'receipt_issued');
  assert.equal((await redeem(
    expiredReceipt,
    receiptMaterial('expired-receipt', new Date(baseNow.getTime() + 4_000)),
    { at: new Date(baseNow.getTime() + 4_000) },
  )).status, 'unavailable');

  const revokedAccess = await insertUnscopedAccess(ids.principalB, 'revoked');
  const revoked = await issue('revoked', {
    purpose: 'unlink-identity', accessHash: revokedAccess.accessHash,
    identity: 'revoked-v3@example.invalid',
  });
  await confirm(revoked);
  assert.equal((await api.query(
    `SELECT status FROM roomscan.logout_all_from_access($1, $2)`,
    [revokedAccess.accessHash, new Date(baseNow.getTime() + 2_000)],
  )).rows[0].status, 'revoked');
  assert.equal((await redeem(revoked, receiptMaterial('revoked'), {
    at: new Date(baseNow.getTime() + 2_500),
  })).status, 'unavailable');

  const expired = await issue('expired', {
    expiresAt: new Date(baseNow.getTime() + 1_000),
  });
  assert.equal((await confirm(expired, {
    at: new Date(baseNow.getTime() + 1_001),
  })).status, 'unavailable');

  const expiredRedeemedSession = await issue('expired-redeemed-session', {
    expiresAt: new Date(baseNow.getTime() + 30_000),
  });
  await confirm(expiredRedeemedSession);
  const expiredSessionMaterial = sessionMaterial('expired-redeemed-session');
  assert.equal(
    (await redeem(expiredRedeemedSession, expiredSessionMaterial)).status,
    'session_issued',
  );
  assert.equal((await redeem(expiredRedeemedSession, sessionMaterial(
    'expired-redeemed-session', new Date(baseNow.getTime() + 31_000),
  ), { at: new Date(baseNow.getTime() + 31_000) })).status, 'unavailable');

  const expiryReceiptAccess = await insertUnscopedAccess(ids.principalB, 'expiry-receipt');
  const expiredRedeemedReceipt = await issue('expired-redeemed-receipt', {
    purpose: 'link-identity', accessHash: expiryReceiptAccess.accessHash,
    identity: 'expired-receipt-v3@example.invalid',
    expiresAt: new Date(baseNow.getTime() + 30_000),
  });
  await confirm(expiredRedeemedReceipt);
  const expiredRedeemedReceiptMaterial = receiptMaterial('expired-redeemed-receipt');
  assert.equal(
    (await redeem(expiredRedeemedReceipt, expiredRedeemedReceiptMaterial)).status,
    'receipt_issued',
  );
  assert.equal((await redeem(expiredRedeemedReceipt, receiptMaterial(
    'expired-redeemed-receipt', new Date(baseNow.getTime() + 31_000),
  ), { at: new Date(baseNow.getTime() + 31_000) })).status, 'unavailable');

  for (const role of [
    'roomscan_api_runtime', 'roomscan_authorizer_runtime',
    'roomscan_auth_challenge_runtime', 'roomscan_stripe_ingress_runtime',
    'roomscan_stripe_reconciliation_runtime', 'roomscan_audit_export_runtime',
    'roomscan_email_delivery_runtime',
  ]) {
    for (const table of ['magic_completion_handoffs', 'magic_completion_redeem_failures']) {
      assert.equal((await bootstrap.query(
        `SELECT has_table_privilege($1, 'roomscan.' || $2, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') AS allowed`,
        [role, table],
      )).rows[0].allowed, false);
    }
  }
  for (const routine of [
    'roomscan.issue_magic_challenge_v2(bytea,timestamp with time zone,text,bytea,text,text,bytea,bytea,timestamp with time zone,text,text,text,bytea,bytea,bytea,integer,integer,integer,integer,integer,integer,integer,integer)',
    'roomscan.consume_magic_challenge_v2(text,bytea,text,timestamp with time zone,bytea,timestamp with time zone,text,bytea,bytea,timestamp with time zone,timestamp with time zone,timestamp with time zone,text)',
  ]) {
    assert.equal((await bootstrap.query(
      `SELECT has_function_privilege('roomscan_api_runtime', $1, 'EXECUTE') AS allowed`,
      [routine],
    )).rows[0].allowed, false);
  }

  const rawCanaries = [
    basic.completionId, basic.verifier, basic.transferCode,
    'v3-session-access:basic', 'v3-session-refresh:basic',
  ];
  const tableRows = [];
  for (const tableName of ['magic_completion_handoffs', 'magic_completion_redeem_failures']) {
    tableRows.push((await bootstrap.query(
      `SELECT COALESCE(jsonb_agg(to_jsonb(row_value)), '[]'::jsonb) AS rows
         FROM roomscan.${tableName} AS row_value`,
    )).rows[0].rows);
  }
  const serialized = JSON.stringify(tableRows);
  assert.deepEqual(rawCanaries.filter((value) => serialized.includes(value)), []);

  console.log(
    'INTEGRATION_0007_MAGIC_COMPLETION_V3_SUMMARY issue_controls=3 confirm_controls=8 '
      + 'csrf_transfer_controls=3 session_issue_replay_controls=22 concurrent_redeems=6 '
      + 'completion_rate_controls=3 network_rate_controls=7 kill_switch_controls=3 '
      + 'returning_scope_controls=4 candidate_receipt_controls=8 revoked_epoch_controls=2 '
      + 'expiry_controls=5 direct_acl_pairs=14 v2_revocations=2 raw_canaries=5 status=pass',
  );
} finally {
  if (api) await api.end();
  await bootstrap.end();
  const cleanup = await cluster.stop();
  console.log(`PG_CLEANUP ${JSON.stringify(cleanup)}`);
}
