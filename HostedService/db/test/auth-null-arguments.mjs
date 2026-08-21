import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { accepted0006MigrationsDir } from './accepted-0006-migrations.mjs';
import { appPoolConfig, hash32, ids, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const now = new Date('2026-08-19T12:00:00.000Z');
const familyId = '64000000-0000-4000-8000-000000000001';
const accessHash = hash32('null-existing-access');
const refreshHash = hash32('null-existing-refresh');
const magicSelector = 'NNNNNNNNNNNNNNNNNNNNNN';
const magicDigest = hash32('null-existing-magic');
const deliveryId = 'null_magic_delivery_01';
const appleAttemptId = 'null_apple_attempt_001';
const appleChallenge = 'R'.repeat(43);
const bridgeHash = hash32('null-existing-bridge');
const verifiedHash = hash32('null-existing-verified');
const candidateHash = hash32('null-existing-candidate');
const notificationId = 'null_notification_0001';

const authTables = [
  'apple_auth_attempts', 'apple_bridge_proofs', 'apple_code_receipts',
  'apple_nonce_receipts', 'auth_access_tokens', 'auth_refresh_tokens',
  'auth_session_families', 'candidate_identity_proofs', 'external_identities',
  'identity_audit_events', 'magic_link_delivery_outbox',
  'magic_link_rate_events', 'magic_links', 'principals',
  'security_notification_outbox', 'verified_authentication_receipts',
];

const definitions = [
  {
    name: 'resolve_access_context',
    types: ['bytea', 'timestamptz'],
    required: [0, 1],
    fresh: [hash32('null-missing-access'), now],
    existing: [accessHash, now],
  },
  {
    name: 'claim_refresh_rotation',
    types: ['bytea', 'bytea', 'timestamptz'],
    required: [0, 1, 2],
    fresh: [hash32('null-missing-refresh'), hash32('null-next-refresh-a'), now],
    existing: [refreshHash, hash32('null-next-refresh-b'), now],
  },
  {
    name: 'revoke_session_family',
    types: ['uuid', 'timestamptz', 'text'],
    required: [0, 1, 2],
    fresh: ['64000000-0000-4000-8000-000000000099', now, 'manual'],
    existing: [familyId, now, 'manual'],
  },
  {
    name: 'claim_magic_link',
    types: ['text', 'bytea', 'text', 'timestamptz'],
    required: [0, 1, 3],
    optional: [2],
    fresh: ['MMMMMMMMMMMMMMMMMMMMMM', hash32('null-missing-magic'), null, now],
    existing: [magicSelector, magicDigest, null, now],
  },
  {
    name: 'supersede_magic_link',
    types: ['text', 'timestamptz'],
    required: [0, 1],
    fresh: ['MMMMMMMMMMMMMMMMMMMMMM', now],
    existing: [magicSelector, now],
  },
  {
    name: 'supersede_magic_link_siblings',
    types: ['text', 'timestamptz'],
    required: [0, 1],
    fresh: ['MMMMMMMMMMMMMMMMMMMMMM', now],
    existing: [magicSelector, now],
  },
  {
    name: 'claim_magic_delivery',
    types: ['text', 'text', 'timestamptz', 'timestamptz'],
    required: [0, 1, 2, 3],
    fresh: ['missing_magic_delivery', 'null_lease_a', now, new Date(now.getTime() + 30_000)],
    existing: [deliveryId, 'null_lease_b', now, new Date(now.getTime() + 30_000)],
  },
  {
    name: 'validate_magic_delivery',
    types: ['text', 'text', 'timestamptz'],
    required: [0, 1, 2],
    fresh: ['missing_magic_delivery', 'null_lease_a', now],
    existing: [deliveryId, 'null_lease_b', now],
  },
  {
    name: 'complete_magic_delivery',
    types: ['text', 'text', 'timestamptz'],
    required: [0, 1, 2],
    fresh: ['missing_magic_delivery', 'null_lease_a', now],
    existing: [deliveryId, 'null_lease_b', now],
  },
  {
    name: 'claim_apple_attempt_and_code',
    types: ['text', 'bytea', 'text', 'bytea', 'timestamptz'],
    required: [0, 1, 2, 3, 4],
    fresh: ['missing_apple_attempt', hash32('null-missing-state'), appleChallenge, hash32('null-missing-code'), now],
    existing: [appleAttemptId, hash32('null-existing-state'), appleChallenge, hash32('null-existing-code'), now],
  },
  {
    name: 'claim_apple_nonce',
    types: ['bytea', 'timestamptz'],
    required: [0, 1],
    fresh: [hash32('null-missing-nonce'), now],
    existing: [hash32('null-existing-nonce'), now],
  },
  {
    name: 'claim_apple_bridge_proof',
    types: ['bytea', 'text', 'text', 'text', 'text', 'timestamptz'],
    required: [0, 1, 2, 3, 4, 5],
    fresh: [hash32('null-missing-bridge'), 'https://appleid.apple.com', 'missing-subject', 'missing_apple_attempt', 'sign-in', now],
    existing: [bridgeHash, 'https://appleid.apple.com', 'null-subject', appleAttemptId, 'sign-in', now],
  },
  {
    name: 'claim_verified_auth_receipt',
    types: ['bytea', 'text', 'text', 'uuid', 'uuid', 'timestamptz'],
    required: [0, 1, 2, 3, 4, 5],
    fresh: [hash32('null-missing-verified'), 'email', 'link-identity', ids.principalA, familyId, now],
    existing: [verifiedHash, 'email', 'link-identity', ids.principalA, familyId, now],
  },
  {
    name: 'claim_candidate_identity_proof',
    types: ['bytea', 'text', 'uuid', 'uuid', 'timestamptz'],
    required: [0, 1, 2, 3, 4],
    fresh: [hash32('null-missing-candidate'), 'link-identity', ids.principalA, familyId, now],
    existing: [candidateHash, 'link-identity', ids.principalA, familyId, now],
  },
  {
    name: 'claim_external_identity',
    types: ['text', 'text', 'uuid', 'timestamptz'],
    required: [0, 1, 2, 3],
    fresh: ['email', 'missing-identity@example.invalid', ids.principalA, now],
    existing: ['email', 'null-existing@example.invalid', ids.principalMember, now],
  },
  {
    name: 'release_external_identity',
    types: ['text', 'text', 'uuid'],
    required: [0, 1, 2],
    fresh: ['email', 'missing-identity@example.invalid', ids.principalA],
    existing: ['email', 'null-second@example.invalid', ids.principalMember],
  },
  {
    name: 'bump_principal_authentication_epoch',
    types: ['uuid'],
    required: [0],
    fresh: ['64000000-0000-4000-8000-000000000099'],
    existing: [ids.principalA],
  },
  {
    name: 'revoke_principal_session_families',
    types: ['uuid', 'uuid', 'timestamptz', 'text'],
    required: [0, 2, 3],
    optional: [1],
    fresh: ['64000000-0000-4000-8000-000000000099', null, now, 'logout_all'],
    existing: [ids.principalA, null, now, 'logout_all'],
  },
  {
    name: 'revoke_access_token',
    types: ['bytea', 'timestamptz'],
    required: [0, 1],
    fresh: [hash32('null-missing-access'), now],
    existing: [accessHash, now],
  },
  {
    name: 'update_session_family_activity',
    types: ['uuid', 'timestamptz', 'timestamptz'],
    required: [0, 1, 2],
    fresh: ['64000000-0000-4000-8000-000000000099', now, new Date(now.getTime() + 60_000)],
    existing: [familyId, now, new Date(now.getTime() + 60_000)],
  },
  {
    name: 'cancel_magic_delivery',
    types: ['text', 'text', 'text', 'timestamptz'],
    required: [0, 1, 2, 3],
    fresh: ['missing_magic_delivery', 'null_lease_a', 'unknown_key', now],
    existing: [deliveryId, 'null_lease_b', 'unknown_key', now],
  },
  {
    name: 'release_magic_delivery',
    types: ['text', 'text', 'timestamptz'],
    required: [0, 1, 2],
    fresh: ['missing_magic_delivery', 'null_lease_a', now],
    existing: [deliveryId, 'null_lease_b', now],
  },
  {
    name: 'claim_security_notification',
    types: ['text', 'text', 'timestamptz', 'timestamptz'],
    required: [0, 1, 2, 3],
    fresh: ['missing_notification_01', 'null_notification_lease_a', now, new Date(now.getTime() + 30_000)],
    existing: [notificationId, 'null_notification_lease_b', now, new Date(now.getTime() + 30_000)],
  },
  {
    name: 'complete_security_notification',
    types: ['text', 'text', 'timestamptz'],
    required: [0, 1, 2],
    fresh: ['missing_notification_01', 'null_notification_lease_a', now],
    existing: [notificationId, 'null_notification_lease_b', now],
  },
  {
    name: 'release_security_notification',
    types: ['text', 'text'],
    required: [0, 1],
    fresh: ['missing_notification_01', 'null_notification_lease_a'],
    existing: [notificationId, 'null_notification_lease_b'],
  },
  {
    name: 'lock_magic_policy_scope',
    types: ['text', 'bytea'],
    required: [0, 1],
    fresh: ['network-request', hash32('null-missing-policy-scope')],
    existing: ['address-delivery', hash32('null-existing-policy-scope')],
  },
];

async function fingerprint(pool) {
  const rows = [];
  for (const table of authTables) {
    rows.push((await pool.query(
      `SELECT $1::text AS table_name,
              count(*)::int AS row_count,
              md5(COALESCE(string_agg(to_jsonb(row_value)::text, E'\n'
                ORDER BY to_jsonb(row_value)::text), '')) AS digest
       FROM roomscan.${table} AS row_value`,
      [table],
    )).rows[0]);
  }
  return rows;
}

async function invoke(pool, definition, args) {
  const placeholders = definition.types.map((type, index) => `$${index + 1}::${type}`);
  return await pool.query(
    `SELECT * FROM roomscan.${definition.name}(${placeholders.join(', ')})`,
    args,
  );
}

const cluster = await startPostgresCluster();
const bootstrapPool = new Pool(cluster.bootstrapConfig);
let appPool;

try {
  await applyMigrations({ pool: bootstrapPool, migrationsDir: accepted0006MigrationsDir });
  await seedCoreFixtures(bootstrapPool);
  appPool = new Pool({ ...appPoolConfig(cluster, 8), application_name: 'rss-auth-null-arguments' });

  await bootstrapPool.query(
    `INSERT INTO roomscan.auth_session_families (
       id, public_id, principal_id, authentication_epoch, authenticated_at,
       created_at, last_used_at, inactivity_expires_at, absolute_expires_at,
       policy_version
     ) VALUES ($1, 'family_null_arguments_01', $2, 0, $3, $3, $3,
       $3::timestamptz + interval '7 days',
       $3::timestamptz + interval '30 days', 'session-v1')`,
    [familyId, ids.principalA, now],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.auth_access_tokens (
       id, family_id, token_hash, expires_at, created_at, principal_id,
       authentication_epoch, authenticated_at, issued_at
     ) VALUES ('74000000-0000-4000-8000-000000000001', $1, $2,
       $3::timestamptz + interval '5 minutes', $3, $4, 0, $3, $3)`,
    [familyId, accessHash, now, ids.principalA],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.auth_refresh_tokens (token_hash, family_id, issued_at)
     VALUES ($1, $2, $3)`,
    [refreshHash, familyId, now],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.magic_links (
       selector, secret_digest, purpose, normalized_delivery_identity,
       address_hash, network_hash, issued_at, expires_at, policy_version
     ) VALUES ($1, $2, 'sign-in', 'null-arguments@example.invalid', $3, $4,
       $5, $5::timestamptz + interval '10 minutes', 'magic-link-v1')`,
    [magicSelector, magicDigest, hash32('null-address'), hash32('null-network'), now],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.magic_link_delivery_outbox (
       id, selector, normalized_delivery_identity, purpose, envelope_version,
       key_id, iv, ciphertext, authentication_tag, created_at, expires_at,
       policy_version, state, lease_id, lease_expires_at
     ) VALUES ($1, $2, 'null-arguments@example.invalid', 'sign-in',
       'aes-256-gcm-v1', 'key-v1', $3, $4, $5, $6,
       $6::timestamptz + interval '10 minutes', 'magic-link-v1', 'leased',
       'null_lease_b', $6::timestamptz + interval '30 seconds')`,
    [deliveryId, magicSelector, Buffer.alloc(12, 31), Buffer.alloc(32, 32), Buffer.alloc(16, 33), now],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.apple_auth_attempts (
       id, state_hash, nonce_hash, code_challenge, expected_client_id,
       redirect_uri, created_at, expires_at, policy_version, purpose
     ) VALUES ($1, $2, $3, $4, 'com.roomscan.studio',
       'https://example.invalid/apple/callback', $5,
       $5::timestamptz + interval '5 minutes', 'apple-auth-v1', 'sign-in')`,
    [appleAttemptId, hash32('null-existing-state'), hash32('null-existing-nonce'), appleChallenge, now],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.apple_bridge_proofs (
       token_hash, issuer, subject, attempt_id, purpose, issued_at, expires_at,
       policy_version
     ) VALUES ($1, 'https://appleid.apple.com', 'null-subject', $2,
       'sign-in', $3, $3::timestamptz + interval '1 minute',
       'apple-auth-v1')`,
    [bridgeHash, appleAttemptId, now],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.apple_nonce_receipts (nonce_hash, claimed_at)
     VALUES ($1, $2)`,
    [hash32('null-existing-nonce'), now],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.verified_authentication_receipts (
       token_hash, issuer, subject, purpose, initiating_principal_id,
       initiating_family_id, authenticated_at, issued_at, expires_at,
       policy_version
     ) VALUES ($1, 'email', 'null-verified@example.invalid', 'link-identity',
       $2, $3, $4, $4, $4::timestamptz + interval '1 minute',
       'identity-link-v2')`,
    [verifiedHash, ids.principalA, familyId, now],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.candidate_identity_proofs (
       token_hash, issuer, subject, purpose, initiating_principal_id,
       initiating_family_id, authenticated_at, issued_at, expires_at,
       policy_version
     ) VALUES ($1, 'email', 'null-candidate@example.invalid', 'link-identity',
       $2, $3, $4, $4, $4::timestamptz + interval '5 minutes',
       'identity-link-v2')`,
    [candidateHash, ids.principalA, familyId, now],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.external_identities (
       id, principal_id, issuer, subject, linked_at
     ) VALUES
       ('75000000-0000-4000-8000-000000000001', $1, 'email',
        'null-existing@example.invalid', $2),
       ('75000000-0000-4000-8000-000000000002', $1, 'email',
        'null-second@example.invalid', $2)`,
    [ids.principalMember, now],
  );
  await bootstrapPool.query(
    `INSERT INTO roomscan.security_notification_outbox (
       id, event_code, principal_id, identity_reference, created_at,
       policy_version, state, lease_id, lease_expires_at
     ) VALUES ($1, 'identity.linked', $2,
       'id_NNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN', $3,
       'identity-link-v2', 'leased', 'null_notification_lease_b',
       $3::timestamptz + interval '30 seconds')`,
    [notificationId, ids.principalA, now],
  );

  const before = await fingerprint(bootstrapPool);
  let malformedCases = 0;
  for (const definition of definitions) {
    for (const branch of ['fresh', 'existing']) {
      for (const argumentIndex of definition.required) {
        const args = [...definition[branch]];
        args[argumentIndex] = null;
        await assert.rejects(
          () => invoke(appPool, definition, args),
          (error) => error?.code === '22023',
          `${definition.name} accepted NULL argument ${argumentIndex} on ${branch}`,
        );
        malformedCases += 1;
      }
    }
  }
  assert.deepEqual(await fingerprint(bootstrapPool), before);

  const routineSources = (await bootstrapPool.query(
    `SELECT p.proname, p.proargnames[1:p.pronargs] AS input_names, p.prosrc
     FROM pg_proc AS p
     JOIN pg_namespace AS n ON n.oid = p.pronamespace
     WHERE n.nspname = 'roomscan' AND p.proname = ANY($1::text[])
     ORDER BY p.proname`,
    [definitions.map(({ name }) => name)],
  )).rows;
  assert.equal(routineSources.length, definitions.length);
  for (const definition of definitions) {
    const source = routineSources.find(({ proname }) => proname === definition.name);
    assert.ok(source);
    for (const argumentIndex of definition.required) {
      const argumentName = source.input_names[argumentIndex];
      assert.ok(
        source.prosrc.includes(`${argumentName} IS NULL`),
        `${definition.name} lacks a literal fail-closed NULL guard for ${argumentName}`,
      );
    }
    assert.deepEqual(
      definition.optional ?? [],
      source.input_names.map((_, index) => index)
        .filter((index) => !definition.required.includes(index)),
      `${definition.name} has an undocumented optional argument`,
    );
  }

  assert.equal((await appPool.query(
    `SELECT count(*)::int AS count FROM roomscan.claim_magic_link(
       $1, $2, NULL::text, $3
     )`,
    [magicSelector, magicDigest, new Date(now.getTime() + 1)],
  )).rows[0].count, 1, 'the documented optional magic-link purpose must remain usable');
  assert.ok(Number((await appPool.query(
    `SELECT roomscan.revoke_principal_session_families(
       $1, NULL::uuid, $2, 'logout_all'
     ) AS count`,
    [ids.principalA, new Date(now.getTime() + 2)],
  )).rows[0].count) >= 1, 'NULL except-family must mean revoke all families');

  console.log(`AUTH_NULL_ARGUMENT_SUMMARY routines=${definitions.length} malformed_cases=${malformedCases} branches=2 durable_fingerprint_unchanged=true literal_guard_oracle=true optional_arguments=2 optional_controls=2 status=pass`);
} finally {
  await appPool?.end();
  await bootstrapPool.end();
  console.error(`AUTH_NULL_ARGUMENT_CLEANUP ${JSON.stringify(await cluster.stop())}`);
}
