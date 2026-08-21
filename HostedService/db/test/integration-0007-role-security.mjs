import assert from 'node:assert/strict';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const runtimeRoles = [
  'roomscan_api_runtime',
  'roomscan_audit_export_runtime',
  'roomscan_auth_challenge_runtime',
  'roomscan_authorizer_runtime',
  'roomscan_email_delivery_runtime',
  'roomscan_stripe_ingress_runtime',
  'roomscan_stripe_reconciliation_runtime',
];
const rawTargetRoutines = [
  'roomscan.bump_principal_authentication_epoch(uuid)',
  'roomscan.claim_external_identity(text,text,uuid,timestamp with time zone)',
  'roomscan.release_external_identity(text,text,uuid)',
  'roomscan.revoke_principal_session_families(uuid,uuid,timestamp with time zone,text)',
  'roomscan.revoke_session_family(uuid,timestamp with time zone,text)',
  'roomscan.update_session_family_activity(uuid,timestamp with time zone,timestamp with time zone)',
];
const protectedGlobalTables = [
  'principals',
  'external_identities',
  'auth_session_families',
  'auth_access_tokens',
  'auth_refresh_tokens',
];

const cluster = await startPostgresCluster();
const bootstrapPool = new Pool(cluster.bootstrapConfig);

try {
  const applied = await applyMigrations({ pool: bootstrapPool });
  assert.equal(applied.applied.at(-1)?.version, '0007', 'forward 0007 migration must be applied');

  const roleRows = (await bootstrapPool.query(
    `SELECT rolname, rolcanlogin, rolinherit, rolsuper, rolcreatedb,
            rolcreaterole, rolreplication, rolbypassrls
       FROM pg_roles
      WHERE rolname = ANY($1::text[])
      ORDER BY rolname`,
    [runtimeRoles],
  )).rows;
  assert.deepEqual(roleRows, runtimeRoles.map((rolname) => ({
    rolname,
    rolcanlogin: true,
    rolinherit: false,
    rolsuper: false,
    rolcreatedb: false,
    rolcreaterole: false,
    rolreplication: false,
    rolbypassrls: false,
  })));
  assert.equal((await bootstrapPool.query(
    `SELECT rolcanlogin FROM pg_roles WHERE rolname = 'roomscan_app'`,
  )).rows[0]?.rolcanlogin, false);

  const forbiddenMembershipEdges = Number((await bootstrapPool.query(
    `SELECT count(*)::integer AS count
       FROM pg_auth_members AS membership
       JOIN pg_roles AS granted ON granted.oid = membership.roleid
       JOIN pg_roles AS member ON member.oid = membership.member
      WHERE member.rolname = ANY($1::text[])
        AND granted.rolname IN ('roomscan_owner', 'roomscan_policy', 'roomscan_app')`,
    [runtimeRoles],
  )).rows[0].count);
  assert.equal(forbiddenMembershipEdges, 0);

  for (const role of runtimeRoles) {
    for (const table of protectedGlobalTables) {
      const privileges = (await bootstrapPool.query(
        `SELECT has_table_privilege($1, 'roomscan.' || $2, 'SELECT') AS can_select,
                has_table_privilege($1, 'roomscan.' || $2, 'INSERT') AS can_insert,
                has_table_privilege($1, 'roomscan.' || $2, 'UPDATE') AS can_update,
                has_table_privilege($1, 'roomscan.' || $2, 'DELETE') AS can_delete,
                has_table_privilege($1, 'roomscan.' || $2, 'TRUNCATE') AS can_truncate`,
        [role, table],
      )).rows[0];
      assert.deepEqual(privileges, {
        can_select: false,
        can_insert: false,
        can_update: false,
        can_delete: false,
        can_truncate: false,
      }, `${role} must not receive direct access to roomscan.${table}`);
    }
    for (const routine of rawTargetRoutines) {
      assert.equal((await bootstrapPool.query(
        `SELECT has_function_privilege($1, $2, 'EXECUTE') AS allowed`,
        [role, routine],
      )).rows[0].allowed, false, `${role} can execute raw-target ${routine}`);
    }
  }

  const expectedExec = {
    roomscan_api_runtime: [
      'roomscan.logout_from_access(bytea,timestamp with time zone,text)',
      'roomscan.touch_session_from_access(bytea,timestamp with time zone,timestamp with time zone,timestamp with time zone)',
    ],
    roomscan_authorizer_runtime: [
      'roomscan.resolve_access_context(bytea,timestamp with time zone)',
    ],
  };
  for (const [role, routines] of Object.entries(expectedExec)) {
    for (const routine of routines) {
      assert.equal((await bootstrapPool.query(
        `SELECT has_function_privilege($1, $2, 'EXECUTE') AS allowed`,
        [role, routine],
      )).rows[0].allowed, true, `${role} lacks ${routine}`);
    }
  }

  console.log(
    `INTEGRATION_0007_ROLE_SECURITY_SUMMARY runtime_roles=${runtimeRoles.length} `
      + `protected_table_role_pairs=${runtimeRoles.length * protectedGlobalTables.length} `
      + `raw_target_denials=${runtimeRoles.length * rawTargetRoutines.length} status=pass`,
  );
} finally {
  await bootstrapPool.end();
  const cleanup = await cluster.stop();
  console.log(`PG_CLEANUP ${JSON.stringify(cleanup)}`);
}
