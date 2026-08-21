import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { accepted0006MigrationsDir } from './accepted-0006-migrations.mjs';
import { appPoolConfig, hash32, ids, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const now = new Date('2026-08-19T12:00:00.000Z');

async function concurrentTransactions(pool, operations) {
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
      const result = await operations[index](client);
      await client.query('COMMIT');
      began = false;
      return result;
    } catch (error) {
      if (began) await client.query('ROLLBACK').catch(() => undefined);
      throw error;
    } finally {
      client.release();
    }
  });
  await allReady;
  releaseGo();
  return await Promise.allSettled(pending);
}

async function insertFamily(pool, { id, publicId, principalId }) {
  await pool.query(
    `INSERT INTO roomscan.auth_session_families (
       id, public_id, principal_id, authentication_epoch, authenticated_at,
       created_at, last_used_at, inactivity_expires_at, absolute_expires_at,
       policy_version
     ) VALUES ($1, $2, $3, 0, $4, $4, $4,
       $4::timestamptz + interval '7 days',
       $4::timestamptz + interval '30 days', 'session-v1')`,
    [id, publicId, principalId, now],
  );
}

async function insertCandidateProof(pool, {
  tokenLabel,
  issuer,
  subject,
  principalId,
  familyId,
}) {
  await pool.query(
    `INSERT INTO roomscan.candidate_identity_proofs (
       token_hash, issuer, subject, purpose, initiating_principal_id,
       initiating_family_id, authenticated_at, issued_at, expires_at,
       policy_version
     ) VALUES ($1, $2, $3, 'link-identity', $4, $5, $6, $6,
       $6::timestamptz + interval '5 minutes', 'identity-link-v2')`,
    [hash32(tokenLabel), issuer, subject, principalId, familyId, now],
  );
}

async function identityMutation(client, {
  proofLabel,
  issuer,
  subject,
  principalId,
  currentFamilyId,
  auditId,
  notificationId,
  auditEventCode = 'identity.linked',
  notificationEventCode = 'identity.linked',
}) {
  const proof = (await client.query(
    `SELECT * FROM roomscan.claim_candidate_identity_proof(
       $1::bytea, 'link-identity', $2::uuid, $3::uuid, $4::timestamptz
     )`,
    [hash32(proofLabel), principalId, currentFamilyId, now],
  )).rows[0];
  assert.ok(proof);

  const identity = (await client.query(
    `SELECT * FROM roomscan.claim_external_identity(
       $1::text, $2::text, $3::uuid, $4::timestamptz
     )`,
    [issuer, subject, principalId, now],
  )).rows[0];
  assert.equal(identity.status, 'created');

  const epoch = Number((await client.query(
    `SELECT roomscan.bump_principal_authentication_epoch($1::uuid) AS epoch`,
    [principalId],
  )).rows[0].epoch);
  const revoked = Number((await client.query(
    `SELECT roomscan.revoke_principal_session_families(
       $1::uuid, $2::uuid, $3::timestamptz, 'identity_changed'
     ) AS revoked`,
    [principalId, currentFamilyId, now],
  )).rows[0].revoked);

  const identityReference = `id_${hash32(`${issuer}\u0000${subject}`).toString('base64url')}`;
  await client.query(
    `INSERT INTO roomscan.identity_audit_events (
       id, event_code, principal_id, authentication_epoch,
       identity_reference, created_at, policy_version
     ) VALUES ($1, $2, $3, $4, $5, $6, 'identity-link-v2')`,
    [auditId, auditEventCode, principalId, epoch, identityReference, now],
  );
  await client.query(
    `INSERT INTO roomscan.security_notification_outbox (
       id, event_code, principal_id, identity_reference, created_at,
       policy_version
     ) VALUES ($1, $2, $3, $4, $5, 'identity-link-v2')`,
    [notificationId, notificationEventCode, principalId, identityReference, now],
  );
  return { epoch, revoked };
}

const cluster = await startPostgresCluster();
const bootstrapPool = new Pool(cluster.bootstrapConfig);
let appPool;

try {
  await applyMigrations({ pool: bootstrapPool, migrationsDir: accepted0006MigrationsDir });
  await seedCoreFixtures(bootstrapPool);
  appPool = new Pool({ ...appPoolConfig(cluster, 16), application_name: 'rss-auth-identity-outbox' });

  assert.equal(
    (await appPool.query(
      `SELECT to_regprocedure(
         'roomscan.claim_external_identity(text,text,uuid,timestamp with time zone)'
       ) IS NOT NULL AS present`,
    )).rows[0].present,
    true,
    'the conditional identity ownership capability is missing',
  );

  const candidatePrincipals = [
    {
      internalId: '11000000-0000-4000-8000-000000000001',
      canonicalId: 'prn_AAAAAAAAAAAAAAAAAAAAAA',
    },
    {
      internalId: '11000000-0000-4000-8000-000000000002',
      canonicalId: 'prn_BBBBBBBBBBBBBBBBBBBBBB',
    },
  ];
  const ownershipRace = await concurrentTransactions(appPool, candidatePrincipals.map((candidate) => async (client) => {
    await client.query(
      `INSERT INTO roomscan.principals (
         id, canonical_id, created_at, updated_at
       ) VALUES ($1, $2, $3, $3)`,
      [candidate.internalId, candidate.canonicalId, now],
    );
    const row = (await client.query(
      `SELECT * FROM roomscan.claim_external_identity(
         'https://appleid.apple.com', 'shared-subject', $1::uuid, $2::timestamptz
       )`,
      [candidate.internalId, now],
    )).rows[0];
    if (row.status !== 'created') {
      throw new Error(`identity ownership lost:${row.status}`);
    }
    return candidate.internalId;
  }));
  assert.equal(ownershipRace.filter(({ status }) => status === 'fulfilled').length, 1);
  assert.equal(ownershipRace.filter(({ status }) => status === 'rejected').length, 1);
  const identityOwner = (await bootstrapPool.query(
    `SELECT principal_id FROM roomscan.external_identities
     WHERE issuer = 'https://appleid.apple.com' AND subject = 'shared-subject'`,
  )).rows[0].principal_id;
  assert.equal(candidatePrincipals.some(({ internalId }) => internalId === identityOwner), true);
  assert.equal(Number((await bootstrapPool.query(
    `SELECT count(*) AS count FROM roomscan.principals
     WHERE id = ANY($1::uuid[])`,
    [candidatePrincipals.map(({ internalId }) => internalId)],
  )).rows[0].count), 1, 'the losing principal creation must roll back');

  const currentFamilyId = '62000000-0000-4000-8000-000000000001';
  const otherFamilyId = '62000000-0000-4000-8000-000000000002';
  await insertFamily(bootstrapPool, {
    id: currentFamilyId,
    publicId: 'family_identity_current_01',
    principalId: ids.principalA,
  });
  await insertFamily(bootstrapPool, {
    id: otherFamilyId,
    publicId: 'family_identity_other_001',
    principalId: ids.principalA,
  });

  await insertCandidateProof(appPool, {
    tokenLabel: 'identity-success-proof',
    issuer: 'email',
    subject: 'linked@example.invalid',
    principalId: ids.principalA,
    familyId: currentFamilyId,
  });
  const successClient = await appPool.connect();
  try {
    await successClient.query('BEGIN');
    const success = await identityMutation(successClient, {
      proofLabel: 'identity-success-proof',
      issuer: 'email',
      subject: 'linked@example.invalid',
      principalId: ids.principalA,
      currentFamilyId,
      auditId: 'audit_identity_success_01',
      notificationId: 'notification_success_01',
    });
    assert.deepEqual(success, { epoch: 1, revoked: 1 });
    await successClient.query('COMMIT');
  } finally {
    successClient.release();
  }
  assert.equal((await bootstrapPool.query(
    `SELECT state FROM roomscan.auth_session_families WHERE id = $1`,
    [otherFamilyId],
  )).rows[0].state, 'revoked');
  assert.equal((await bootstrapPool.query(
    `SELECT authentication_epoch FROM roomscan.principals WHERE id = $1`,
    [ids.principalA],
  )).rows[0].authentication_epoch, '1');

  const rollbackCases = [
    {
      proofLabel: 'identity-audit-fail-proof',
      subject: 'audit-fail@example.invalid',
      auditId: 'audit_identity_failure_01',
      notificationId: 'notification_unused_01',
      auditEventCode: 'not.allowed',
    },
    {
      proofLabel: 'identity-outbox-fail-proof',
      subject: 'outbox-fail@example.invalid',
      auditId: 'audit_identity_failure_02',
      notificationId: 'notification_failure_01',
      notificationEventCode: 'not.allowed',
    },
  ];
  for (const rollbackCase of rollbackCases) {
    await insertCandidateProof(appPool, {
      tokenLabel: rollbackCase.proofLabel,
      issuer: 'email',
      subject: rollbackCase.subject,
      principalId: ids.principalA,
      familyId: currentFamilyId,
    });
    const epochBefore = (await bootstrapPool.query(
      `SELECT authentication_epoch FROM roomscan.principals WHERE id = $1`,
      [ids.principalA],
    )).rows[0].authentication_epoch;
    await assert.rejects(async () => {
      const client = await appPool.connect();
      try {
        await client.query('BEGIN');
        try {
          await identityMutation(client, {
            ...rollbackCase,
            issuer: 'email',
            principalId: ids.principalA,
            currentFamilyId,
          });
          await client.query('COMMIT');
        } catch (error) {
          await client.query('ROLLBACK');
          throw error;
        }
      } finally {
        client.release();
      }
    }, (error) => error?.code === '23514');
    assert.equal((await bootstrapPool.query(
      `SELECT state FROM roomscan.candidate_identity_proofs WHERE token_hash = $1`,
      [hash32(rollbackCase.proofLabel)],
    )).rows[0].state, 'active');
    assert.equal(Number((await bootstrapPool.query(
      `SELECT count(*) AS count FROM roomscan.external_identities
       WHERE issuer = 'email' AND subject = $1`,
      [rollbackCase.subject],
    )).rows[0].count), 0);
    assert.equal((await bootstrapPool.query(
      `SELECT authentication_epoch FROM roomscan.principals WHERE id = $1`,
      [ids.principalA],
    )).rows[0].authentication_epoch, epochBefore);
    assert.equal(Number((await bootstrapPool.query(
      `SELECT count(*) AS count FROM roomscan.identity_audit_events
       WHERE id = $1`,
      [rollbackCase.auditId],
    )).rows[0].count), 0);
    assert.equal(Number((await bootstrapPool.query(
      `SELECT count(*) AS count FROM roomscan.security_notification_outbox
       WHERE id = $1`,
      [rollbackCase.notificationId],
    )).rows[0].count), 0);
  }

  const notificationId = 'notification_success_01';
  const leases = ['notification_lease_alpha', 'notification_lease_bravo'];
  const notificationRace = await concurrentTransactions(appPool, leases.map((leaseId) => async (client) => (
    await client.query(
      `SELECT lease_id FROM roomscan.claim_security_notification(
         $1::text, $2::text, $3::timestamptz, $4::timestamptz
       )`,
      [notificationId, leaseId, now, new Date(now.getTime() + 30_000)],
    )
  ).rows[0]?.lease_id));
  const winningLease = notificationRace.find(({ status, value }) => status === 'fulfilled' && value)?.value;
  assert.ok(winningLease);
  assert.equal(notificationRace.filter(({ status, value }) => status === 'fulfilled' && value).length, 1);
  assert.equal((await appPool.query(
    `SELECT roomscan.complete_security_notification(
       $1, 'wrong_lease', $2::timestamptz
     ) AS completed`,
    [notificationId, new Date(now.getTime() + 1_000)],
  )).rows[0].completed, false);
  const replacementLease = 'notification_replacement_lease';
  assert.equal((await appPool.query(
    `SELECT lease_id FROM roomscan.claim_security_notification(
       $1, $2, $3::timestamptz, $4::timestamptz
     )`,
    [notificationId, replacementLease, new Date(now.getTime() + 30_001), new Date(now.getTime() + 60_000)],
  )).rows[0].lease_id, replacementLease);
  assert.equal((await appPool.query(
    `SELECT roomscan.complete_security_notification($1, $2, $3) AS completed`,
    [notificationId, winningLease, new Date(now.getTime() + 30_002)],
  )).rows[0].completed, false, 'a lost lease must not complete');
  assert.equal((await appPool.query(
    `SELECT roomscan.release_security_notification($1, $2) AS released`,
    [notificationId, replacementLease],
  )).rows[0].released, true);
  assert.equal((await appPool.query(
    `SELECT lease_id FROM roomscan.claim_security_notification(
       $1, 'notification_final_lease', $2::timestamptz, $3::timestamptz
     )`,
    [notificationId, new Date(now.getTime() + 30_003), new Date(now.getTime() + 60_003)],
  )).rows[0].lease_id, 'notification_final_lease');
  assert.equal((await appPool.query(
    `SELECT roomscan.complete_security_notification(
       $1, 'notification_final_lease', $2::timestamptz
     ) AS completed`,
    [notificationId, new Date(now.getTime() + 30_004)],
  )).rows[0].completed, true);

  await bootstrapPool.query(
    `INSERT INTO roomscan.external_identities (
       id, principal_id, issuer, subject, linked_at
     ) VALUES
       ('71000000-0000-4000-8000-000000000001', $1, 'email', 'baseline@example.invalid', $2),
       ('71000000-0000-4000-8000-000000000002', $1, 'email', 'second@example.invalid', $2)`,
    [ids.principalMember, now],
  );
  assert.equal((await appPool.query(
    `SELECT status FROM roomscan.release_external_identity(
       'email', 'second@example.invalid', $1::uuid
     )`,
    [ids.principalMember],
  )).rows[0].status, 'released');
  assert.equal((await appPool.query(
    `SELECT status FROM roomscan.release_external_identity(
       'email', 'baseline@example.invalid', $1::uuid
     )`,
    [ids.principalMember],
  )).rows[0].status, 'final_auth_method');

  const expiredFamily = '62000000-0000-4000-8000-000000000003';
  const staleFamily = '62000000-0000-4000-8000-000000000004';
  await insertFamily(bootstrapPool, {
    id: expiredFamily,
    publicId: 'family_expired_commit_01',
    principalId: ids.principalB,
  });
  await insertFamily(bootstrapPool, {
    id: staleFamily,
    publicId: 'family_stale_commit_0001',
    principalId: ids.principalB,
  });
  for (const [familyId, reason] of [[expiredFamily, 'expired'], [staleFamily, 'stale_principal']]) {
    const client = await appPool.connect();
    await assert.rejects(async () => {
      try {
        await client.query('BEGIN');
        assert.equal((await client.query(
          `SELECT roomscan.revoke_session_family($1, $2, $3) AS revoked`,
          [familyId, now, reason],
        )).rows[0].revoked, true);
        await client.query('COMMIT');
        throw new Error(`service rejection:${reason}`);
      } finally {
        client.release();
      }
    }, new RegExp(`service rejection:${reason}`));
    assert.equal((await bootstrapPool.query(
      `SELECT state, revoke_reason FROM roomscan.auth_session_families WHERE id = $1`,
      [familyId],
    )).rows[0].revoke_reason, reason);
  }

  console.log('AUTH_IDENTITY_OUTBOX_SUMMARY ownership_winners=1 orphan_rollback=true identity_atomic_success=true audit_rollback=true outbox_rollback=true notification_lease_winners=1 lost_lease=true lease_expiry=true release_retry=true last_identity_denied=true commit_before_error=2 status=pass');
} finally {
  await appPool?.end();
  await bootstrapPool.end();
  console.error(`AUTH_IDENTITY_OUTBOX_CLEANUP ${JSON.stringify(await cluster.stop())}`);
}
