import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { accepted0006MigrationsDir } from './accepted-0006-migrations.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const expectedAuthTables = [
  'apple_auth_attempts',
  'apple_bridge_proofs',
  'apple_code_receipts',
  'apple_nonce_receipts',
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
];

const cluster = await startPostgresCluster();
const pool = new Pool(cluster.bootstrapConfig);

try {
  const migrated = await applyMigrations({ pool, migrationsDir: accepted0006MigrationsDir });
  assert.equal(migrated.applied.length, 6, 'the forward-only auth migration is missing');

  const tables = (await pool.query(
    `SELECT c.relname
     FROM pg_class AS c
     JOIN pg_namespace AS n ON n.oid = c.relnamespace
     WHERE n.nspname = 'roomscan'
       AND c.relkind = 'r'
       AND c.relname = ANY($1::text[])
     ORDER BY c.relname`,
    [expectedAuthTables],
  )).rows.map(({ relname }) => relname);
  assert.deepEqual(tables, expectedAuthTables);

  const resolver = (await pool.query(
    `SELECT p.oid::regprocedure::text AS routine,
            owner.rolname AS owner,
            p.prosecdef,
            p.proconfig,
            p.pronargs,
            has_function_privilege('roomscan_app', p.oid, 'EXECUTE') AS app_execute,
            COALESCE((
              SELECT bool_or(acl.grantee = 0 AND acl.privilege_type = 'EXECUTE')
              FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) AS acl
            ), false) AS public_execute,
            obj_description(p.oid, 'pg_proc') AS review
     FROM pg_proc AS p
     JOIN pg_namespace AS n ON n.oid = p.pronamespace
     JOIN pg_roles AS owner ON owner.oid = p.proowner
     WHERE n.nspname = 'roomscan'
       AND p.proname = 'resolve_access_context'`,
  )).rows;
  assert.deepEqual(resolver, [{
    routine: 'roomscan.resolve_access_context(bytea,timestamp with time zone)',
    owner: 'roomscan_policy',
    prosecdef: true,
    proconfig: ['search_path=pg_catalog, pg_temp'],
    pronargs: 2,
    app_execute: true,
    public_execute: false,
    review: 'Reviewed SECURITY DEFINER authentication resolver: access-token hash and authoritative time only; server-derived principal, family, tenant, membership version, and recent-authentication context; fixed search_path; PUBLIC execute revoked.',
  }]);

  const principalColumns = (await pool.query(
    `SELECT column_name, data_type, is_nullable
     FROM information_schema.columns
     WHERE table_schema = 'roomscan'
       AND table_name = 'principals'
       AND column_name IN ('canonical_id', 'authentication_epoch')
     ORDER BY column_name`,
  )).rows;
  assert.deepEqual(principalColumns, [
    { column_name: 'authentication_epoch', data_type: 'bigint', is_nullable: 'NO' },
    { column_name: 'canonical_id', data_type: 'text', is_nullable: 'NO' },
  ]);

  const bypass = (await pool.query(
    `SELECT rolname, rolbypassrls, rolinherit
     FROM pg_roles
     WHERE rolname = 'roomscan_app'`,
  )).rows[0];
  assert.deepEqual(bypass, { rolname: 'roomscan_app', rolbypassrls: false, rolinherit: false });

  console.log(`AUTH_SCHEMA_SUMMARY migrations=${migrated.applied.length} auth_tables=${tables.length} resolver_args=2 app_bypassrls=false status=pass`);
} finally {
  await pool.end();
  console.error(`AUTH_SCHEMA_CLEANUP ${JSON.stringify(await cluster.stop())}`);
}
