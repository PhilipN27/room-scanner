import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { accepted0006MigrationsDir } from './accepted-0006-migrations.mjs';
import { appPoolConfig, hash32, ids, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const authTables = [
  'apple_auth_attempts',
  'apple_bridge_proofs',
  'apple_code_receipts',
  'apple_nonce_receipts',
  'auth_access_tokens',
  'auth_attempts',
  'auth_refresh_tokens',
  'auth_session_families',
  'candidate_identity_proofs',
  'external_identities',
  'identity_audit_events',
  'magic_link_delivery_outbox',
  'magic_link_rate_events',
  'magic_links',
  'principals',
  'provider_receipts',
  'security_notification_outbox',
  'verified_authentication_receipts',
];
const appSelectable = new Set([
  'apple_auth_attempts',
  'apple_bridge_proofs',
  'auth_access_tokens',
  'auth_refresh_tokens',
  'auth_session_families',
  'candidate_identity_proofs',
  'external_identities',
  'identity_audit_events',
  'magic_link_delivery_outbox',
  'magic_link_rate_events',
  'magic_links',
  'principals',
  'security_notification_outbox',
  'verified_authentication_receipts',
]);
const appInsertColumns = {
  apple_auth_attempts: [
    'code_challenge', 'created_at', 'expected_client_id', 'expires_at', 'id',
    'initiating_authenticated_at', 'initiating_family_id', 'initiating_principal_id',
    'nonce_hash', 'policy_version', 'purpose', 'redirect_uri', 'state_hash',
  ],
  apple_bridge_proofs: [
    'attempt_id', 'expires_at', 'issued_at', 'issuer', 'policy_version',
    'purpose', 'subject', 'token_hash',
  ],
  auth_access_tokens: [
    'authenticated_at', 'authentication_epoch', 'authorization_version',
    'created_at', 'expires_at', 'family_id', 'id', 'issued_at', 'principal_id',
    'role', 'token_hash', 'workspace_id',
  ],
  auth_refresh_tokens: ['family_id', 'issued_at', 'token_hash'],
  auth_session_families: [
    'absolute_expires_at', 'authenticated_at', 'authentication_epoch',
    'authorization_version', 'created_at', 'id', 'inactivity_expires_at',
    'last_used_at', 'policy_version', 'principal_id', 'public_id', 'role',
    'workspace_id',
  ],
  candidate_identity_proofs: [
    'authenticated_at', 'expires_at', 'initiating_family_id',
    'initiating_principal_id', 'issued_at', 'issuer', 'policy_version',
    'purpose', 'subject', 'token_hash',
  ],
  identity_audit_events: [
    'authentication_epoch', 'created_at', 'event_code', 'id',
    'identity_reference', 'policy_version', 'principal_id',
  ],
  magic_link_delivery_outbox: [
    'authentication_tag', 'ciphertext', 'created_at', 'envelope_version',
    'expires_at', 'id', 'iv', 'key_id', 'normalized_delivery_identity',
    'policy_version', 'purpose', 'selector',
  ],
  magic_link_rate_events: ['kind', 'occurred_at', 'subject_hash'],
  magic_links: [
    'address_hash', 'expires_at', 'initiating_authenticated_at',
    'initiating_family_id', 'initiating_principal_id', 'issued_at',
    'network_hash', 'normalized_delivery_identity', 'policy_version', 'purpose',
    'secret_digest', 'selector',
  ],
  principals: ['canonical_id', 'created_at', 'id', 'updated_at'],
  security_notification_outbox: [
    'created_at', 'event_code', 'id', 'identity_reference', 'policy_version',
    'principal_id',
  ],
  verified_authentication_receipts: [
    'authenticated_at', 'expires_at', 'initiating_family_id',
    'initiating_principal_id', 'issued_at', 'issuer', 'policy_version',
    'purpose', 'subject', 'token_hash',
  ],
};
const hashColumns = [
  ['apple_auth_attempts', 'state_hash'],
  ['apple_auth_attempts', 'nonce_hash'],
  ['apple_bridge_proofs', 'token_hash'],
  ['apple_code_receipts', 'code_hash'],
  ['apple_nonce_receipts', 'nonce_hash'],
  ['auth_access_tokens', 'token_hash'],
  ['auth_refresh_tokens', 'token_hash'],
  ['auth_refresh_tokens', 'child_token_hash'],
  ['candidate_identity_proofs', 'token_hash'],
  ['magic_link_rate_events', 'subject_hash'],
  ['magic_links', 'secret_digest'],
  ['magic_links', 'address_hash'],
  ['magic_links', 'network_hash'],
  ['verified_authentication_receipts', 'token_hash'],
];

function detectCanaries(rows, canaries) {
  const serialized = rows.map((row) => JSON.stringify(row)).join('\n');
  return canaries.filter((canary) => serialized.includes(canary));
}

const cluster = await startPostgresCluster();
const bootstrapPool = new Pool(cluster.bootstrapConfig);
let appPool;

try {
  await applyMigrations({ pool: bootstrapPool, migrationsDir: accepted0006MigrationsDir });
  await seedCoreFixtures(bootstrapPool);
  appPool = new Pool({ ...appPoolConfig(cluster, 4), application_name: 'rss-auth-catalog-secrets' });

  const tableCatalog = (await bootstrapPool.query(
    `SELECT c.relname, owner.rolname AS owner, c.relrowsecurity,
            c.relforcerowsecurity
     FROM pg_class AS c
     JOIN pg_namespace AS n ON n.oid = c.relnamespace
     JOIN pg_roles AS owner ON owner.oid = c.relowner
     WHERE n.nspname = 'roomscan' AND c.relkind = 'r'
       AND c.relname = ANY($1::text[])
     ORDER BY c.relname`,
    [authTables],
  )).rows;
  assert.deepEqual(tableCatalog, authTables.map((relname) => ({
    relname,
    owner: 'roomscan_owner',
    relrowsecurity: false,
    relforcerowsecurity: false,
  })));

  const appTableAcl = (await bootstrapPool.query(
    `SELECT relation_name,
            has_table_privilege('roomscan_app', 'roomscan.' || relation_name, 'SELECT') AS can_select,
            has_table_privilege('roomscan_app', 'roomscan.' || relation_name, 'INSERT') AS can_insert,
            has_table_privilege('roomscan_app', 'roomscan.' || relation_name, 'UPDATE') AS can_update,
            has_table_privilege('roomscan_app', 'roomscan.' || relation_name, 'DELETE') AS can_delete,
            has_table_privilege('roomscan_app', 'roomscan.' || relation_name, 'TRUNCATE') AS can_truncate
     FROM unnest($1::text[]) AS relation_name
     ORDER BY relation_name`,
    [authTables],
  )).rows;
  assert.deepEqual(appTableAcl, authTables.map((relation_name) => ({
    relation_name,
    can_select: appSelectable.has(relation_name),
    can_insert: false,
    can_update: false,
    can_delete: false,
    can_truncate: false,
  })));

  const appInsertAcl = (await bootstrapPool.query(
    `SELECT table_name, column_name
     FROM information_schema.column_privileges
     WHERE table_schema = 'roomscan' AND grantee = 'roomscan_app'
       AND privilege_type = 'INSERT'
       AND table_name = ANY($1::text[])
     ORDER BY table_name, column_name`,
    [authTables],
  )).rows;
  const expectedInsertAcl = Object.entries(appInsertColumns).flatMap(
    ([table_name, columns]) => columns.map((column_name) => ({ table_name, column_name })),
  ).sort((a, b) => a.table_name.localeCompare(b.table_name)
    || a.column_name.localeCompare(b.column_name));
  assert.deepEqual(appInsertAcl, expectedInsertAcl);

  const rawMutationColumnAcl = (await bootstrapPool.query(
    `SELECT table_name, column_name, privilege_type
     FROM information_schema.column_privileges
     WHERE table_schema = 'roomscan' AND grantee = 'roomscan_app'
       AND privilege_type IN ('UPDATE', 'DELETE')
       AND table_name = ANY($1::text[])
     ORDER BY table_name, column_name, privilege_type`,
    [authTables],
  )).rows;
  assert.deepEqual(rawMutationColumnAcl, []);

  const exactHashColumns = (await bootstrapPool.query(
    `SELECT table_name, column_name, data_type
     FROM information_schema.columns
     WHERE table_schema = 'roomscan'
       AND (table_name, column_name) IN (
         SELECT table_value, column_value
         FROM unnest($1::text[], $2::text[]) AS pair(table_value, column_value)
       )
     ORDER BY table_name, column_name`,
    [hashColumns.map(([table]) => table), hashColumns.map(([, column]) => column)],
  )).rows;
  assert.deepEqual(exactHashColumns, hashColumns.map(([table_name, column_name]) => ({
    table_name,
    column_name,
    data_type: 'bytea',
  })).sort((a, b) => a.table_name.localeCompare(b.table_name)
    || a.column_name.localeCompare(b.column_name)));

  const hashConstraintDefinitions = (await bootstrapPool.query(
    `SELECT c.relname AS table_name, pg_get_constraintdef(con.oid) AS definition
     FROM pg_constraint AS con
     JOIN pg_class AS c ON c.oid = con.conrelid
     JOIN pg_namespace AS n ON n.oid = c.relnamespace
     WHERE n.nspname = 'roomscan' AND con.contype = 'c'
       AND c.relname = ANY($1::text[])
     ORDER BY c.relname, con.conname`,
    [[...new Set(hashColumns.map(([table]) => table))]],
  )).rows;
  for (const [table, column] of hashColumns) {
    assert.ok(
      hashConstraintDefinitions.some(({ table_name, definition }) =>
        table_name === table
          && definition.includes(column)
          && definition.includes('octet_length')
          && (column === 'child_token_hash' || definition.includes('32'))),
      `${table}.${column} lacks a 32-byte storage constraint`,
    );
  }

  const boundedIdentityColumns = (await bootstrapPool.query(
    `SELECT c.relname AS table_name, con.conname,
            pg_get_constraintdef(con.oid) AS definition
     FROM pg_constraint AS con
     JOIN pg_class AS c ON c.oid = con.conrelid
     JOIN pg_namespace AS n ON n.oid = c.relnamespace
     WHERE n.nspname = 'roomscan' AND con.contype = 'c'
       AND con.conname IN (
         'principals_normalized_email_length',
         'principals_canonical_id_format',
         'external_identities_issuer_length'
       )
     ORDER BY con.conname`,
  )).rows;
  assert.equal(boundedIdentityColumns.length, 3);

  const now = new Date('2026-08-19T12:00:00.000Z');
  const familyId = '63000000-0000-4000-8000-000000000001';
  const rawCanaries = [
    'RAW_ACCESS_CANARY_ZYXWVUTSRQPONMLKJIHGFEDCBA987654',
    'RAW_REFRESH_CANARY_ZYXWVUTSRQPONMLKJIHGFEDCBA1234',
    'RAW_MAGIC_CANARY_ZYXWVUTSRQPONMLKJIHGFEDCBA567890',
    'RAW_APPLE_STATE_CANARY_ZYXWVUTSRQPONMLKJIHGFEDCBA',
    'RAW_APPLE_NONCE_CANARY_ZYXWVUTSRQPONMLKJIHGFEDCBA',
    'RAW_APPLE_CODE_CANARY_ZYXWVUTSRQPONMLKJIHGFEDCBAA',
    'RAW_BRIDGE_CANARY_ZYXWVUTSRQPONMLKJIHGFEDCBA98765',
    'RAW_VERIFIED_CANARY_ZYXWVUTSRQPONMLKJIHGFEDCBA123',
    'RAW_CANDIDATE_CANARY_ZYXWVUTSRQPONMLKJIHGFEDCBA45',
  ];
  await appPool.query(
    `INSERT INTO roomscan.auth_session_families (
       id, public_id, principal_id, authentication_epoch, authenticated_at,
       created_at, last_used_at, inactivity_expires_at, absolute_expires_at,
       policy_version
     ) VALUES ($1, 'family_secret_canary_01', $2, 0, $3, $3, $3,
       $3::timestamptz + interval '7 days',
       $3::timestamptz + interval '30 days', 'session-v1')`,
    [familyId, ids.principalA, now],
  );
  await appPool.query(
    `INSERT INTO roomscan.auth_access_tokens (
       id, family_id, token_hash, expires_at, created_at, principal_id,
       authentication_epoch, authenticated_at, issued_at
     ) VALUES ('73000000-0000-4000-8000-000000000001', $1, $2,
       $3::timestamptz + interval '5 minutes', $3, $4, 0, $3, $3)`,
    [familyId, hash32(rawCanaries[0]), now, ids.principalA],
  );
  await appPool.query(
    `INSERT INTO roomscan.auth_refresh_tokens (token_hash, family_id, issued_at)
     VALUES ($1, $2, $3)`,
    [hash32(rawCanaries[1]), familyId, now],
  );
  await appPool.query(
    `INSERT INTO roomscan.magic_links (
       selector, secret_digest, purpose, normalized_delivery_identity,
       address_hash, network_hash, issued_at, expires_at, policy_version
     ) VALUES ('HHHHHHHHHHHHHHHHHHHHHH', $1, 'sign-in',
       'secret-canary@example.invalid', $2, $3, $4,
       $4::timestamptz + interval '10 minutes', 'magic-link-v1')`,
    [hash32(rawCanaries[2]), hash32('secret-address'), hash32('secret-network'), now],
  );
  await appPool.query(
    `INSERT INTO roomscan.magic_link_delivery_outbox (
       id, selector, normalized_delivery_identity, purpose, envelope_version,
       key_id, iv, ciphertext, authentication_tag, created_at, expires_at,
       policy_version
     ) VALUES ('magic_secret_delivery_01', 'HHHHHHHHHHHHHHHHHHHHHH',
       'secret-canary@example.invalid', 'sign-in', 'aes-256-gcm-v1',
       'test-key-v1', $1, $2, $3, $4, $4::timestamptz + interval '10 minutes',
       'magic-link-v1')`,
    [Buffer.alloc(12, 21), Buffer.alloc(32, 22), Buffer.alloc(16, 23), now],
  );
  await appPool.query(
    `INSERT INTO roomscan.apple_auth_attempts (
       id, state_hash, nonce_hash, code_challenge, expected_client_id,
       redirect_uri, created_at, expires_at, policy_version, purpose
     ) VALUES ('apple_secret_attempt_01', $1, $2, $3,
       'com.roomscan.studio', 'https://example.invalid/apple/callback', $4,
       $4::timestamptz + interval '5 minutes', 'apple-auth-v1', 'sign-in')`,
    [hash32(rawCanaries[3]), hash32(rawCanaries[4]), 'Q'.repeat(43), now],
  );
  await appPool.query(
    `INSERT INTO roomscan.apple_bridge_proofs (
       token_hash, issuer, subject, attempt_id, purpose, issued_at, expires_at,
       policy_version
     ) VALUES ($1, 'https://appleid.apple.com', 'secret-subject',
       'apple_secret_attempt_01', 'sign-in', $2,
       $2::timestamptz + interval '1 minute', 'apple-auth-v1')`,
    [hash32(rawCanaries[6]), now],
  );
  await appPool.query(
    `INSERT INTO roomscan.verified_authentication_receipts (
       token_hash, issuer, subject, purpose, initiating_principal_id,
       initiating_family_id, authenticated_at, issued_at, expires_at,
       policy_version
     ) VALUES ($1, 'email', 'verified-secret@example.invalid', 'link-identity',
       $2, $3, $4, $4, $4::timestamptz + interval '1 minute',
       'identity-link-v2')`,
    [hash32(rawCanaries[7]), ids.principalA, familyId, now],
  );
  await appPool.query(
    `INSERT INTO roomscan.candidate_identity_proofs (
       token_hash, issuer, subject, purpose, initiating_principal_id,
       initiating_family_id, authenticated_at, issued_at, expires_at,
       policy_version
     ) VALUES ($1, 'email', 'candidate-secret@example.invalid', 'link-identity',
       $2, $3, $4, $4, $4::timestamptz + interval '5 minutes',
       'identity-link-v2')`,
    [hash32(rawCanaries[8]), ids.principalA, familyId, now],
  );
  assert.equal((await appPool.query(
    `SELECT status FROM roomscan.claim_apple_attempt_and_code(
       'apple_secret_attempt_01', $1, $2, $3, $4
     )`,
    [hash32(rawCanaries[3]), 'Q'.repeat(43), hash32(rawCanaries[5]), new Date(now.getTime() + 1)],
  )).rows[0].status, 'claimed');

  const productionRows = [];
  for (const table of authTables) {
    productionRows.push(...(await bootstrapPool.query(
      `SELECT $1::text AS source_table, to_jsonb(row_value) AS record
       FROM roomscan.${table} AS row_value`,
      [table],
    )).rows);
  }
  assert.deepEqual(detectCanaries(productionRows, rawCanaries), []);

  await bootstrapPool.query('CREATE TEMP TABLE raw_secret_detector_control (value text)');
  await bootstrapPool.query(
    'INSERT INTO raw_secret_detector_control (value) VALUES ($1)',
    [rawCanaries[0]],
  );
  const positiveControl = (await bootstrapPool.query(
    `SELECT to_jsonb(control) AS record FROM raw_secret_detector_control AS control`,
  )).rows;
  assert.deepEqual(detectCanaries(positiveControl, rawCanaries), [rawCanaries[0]]);

  console.log(`AUTH_CATALOG_SECRET_SUMMARY auth_tables=${authTables.length} app_select_tables=${appSelectable.size} column_insert_grants=${expectedInsertAcl.length} hash_columns=${hashColumns.length} bounded_identity_constraints=3 raw_canaries=${rawCanaries.length} detector_positive=1 direct_update_delete_truncate=false status=pass`);
} finally {
  await appPool?.end();
  await bootstrapPool.end();
  console.error(`AUTH_CATALOG_SECRET_CLEANUP ${JSON.stringify(await cluster.stop())}`);
}
