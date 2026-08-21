import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { cp, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { appPoolConfig, hash32, ids, seedCoreFixtures } from './fixtures.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const productionMigrationsDir = fileURLToPath(new URL('../migrations/', import.meta.url));
const migrationName = '0007_policy_billing_integration.up.sql';
const now = new Date('2026-08-19T12:00:00.000Z');
let sequence = 700;

function replaceOnce(source, before, after, label) {
  assert.equal(source.split(before).length - 1, 1, `${label} mutation anchor drifted`);
  return source.replace(before, after);
}

function mutateFunction(source, functionName, transform) {
  let start = source.indexOf(`CREATE FUNCTION roomscan.${functionName}(`);
  if (start === -1) {
    start = source.indexOf(`CREATE OR REPLACE FUNCTION roomscan.${functionName}(`);
  }
  assert.notEqual(start, -1, `${functionName} definition is missing`);
  const terminator = '\n$function$;';
  const end = source.indexOf(terminator, start);
  assert.notEqual(end, -1, `${functionName} definition terminator is missing`);
  const boundary = end + terminator.length;
  const original = source.slice(start, boundary);
  const mutated = transform(original);
  assert.notEqual(mutated, original, `${functionName} mutation made no change`);
  return `${source.slice(0, start)}${mutated}${source.slice(boundary)}`;
}

async function prepareMutation(transform, additionalMutations = []) {
  const root = await mkdtemp(path.join(tmpdir(), 'rss-0007-mutation-'));
  const migrationsDir = path.join(root, 'migrations');
  await cp(productionMigrationsDir, migrationsDir, { recursive: true });
  const target = path.join(migrationsDir, migrationName);
  const source = await readFile(target, 'utf8');
  const mutated = transform(source);
  assert.notEqual(mutated, source, '0007 mutation made no change');
  await writeFile(target, mutated);
  for (const additional of additionalMutations) {
    const additionalTarget = path.join(migrationsDir, additional.file);
    const additionalSource = await readFile(additionalTarget, 'utf8');
    const additionalMutated = replaceOnce(
      additionalSource,
      additional.before,
      additional.after,
      additional.label,
    );
    await writeFile(additionalTarget, additionalMutated);
  }
  return { root, migrationsDir };
}

async function runOracle(migrationsDir, oracle) {
  const cluster = await startPostgresCluster();
  const bootstrapPool = new Pool(cluster.bootstrapConfig);
  let cleanup;
  let thrown;
  try {
    await applyMigrations({ pool: bootstrapPool, migrationsDir });
    await seedCoreFixtures(bootstrapPool);
    await oracle({ cluster, bootstrapPool });
  } catch (error) {
    thrown = error;
  } finally {
    await bootstrapPool.end();
    cleanup = await cluster.stop();
  }
  if (thrown) {
    thrown.cleanupEvidence = cleanup;
    throw thrown;
  }
  return cleanup;
}

async function expectDatabaseError(work, code, message) {
  let caught;
  try {
    await work();
  } catch (error) {
    caught = error;
  }
  assert.ok(caught, `expected SQLSTATE ${code}`);
  assert.equal(caught.code, code);
  if (message !== undefined) assert.equal(caught.message, message);
}

async function withRole(pool, role, work) {
  await pool.query(`SET ROLE ${role}`);
  try {
    return await work();
  } finally {
    await pool.query('RESET ROLE');
  }
}

async function setHostedFlags(pool, workspaceId, enabled = true) {
  await withRole(pool, 'roomscan_operator', async () => {
    await pool.query(
      `SELECT * FROM roomscan.set_operational_flag(
         'global', NULL, 'hosted_operations_enabled', $1, NULL,
         'mutation oracle', $2, $3
       )`,
      [enabled, `ofaud_mut_global_${sequence++}`, now],
    );
    await pool.query(
      `SELECT * FROM roomscan.set_operational_flag(
         'workspace', $1, 'hosted_operations_enabled', $2, NULL,
         'mutation oracle', $3, $4
       )`,
      [workspaceId, enabled, `ofaud_mut_workspace_${sequence++}`, now],
    );
  });
}

async function setProfessionalSignInFlag(
  pool,
  enabled,
  expectedVersion = null,
  occurredAt = now,
) {
  await withRole(pool, 'roomscan_operator', async () => {
    await pool.query(
      `SELECT * FROM roomscan.set_operational_flag(
         'global', NULL, 'professional_sign_in_enabled', $1, $2,
         'mutation oracle', $3, $4
       )`,
      [enabled, expectedVersion, `ofaud_mut_email_signin_${sequence++}`, occurredAt],
    );
  });
}

async function insertAccess(pool, {
  principalId = ids.principalA,
  workspaceId = ids.workspaceA,
  role = 'owner',
  label,
}) {
  const familyId = `67000000-0000-4000-8000-${String(sequence++).padStart(12, '0')}`;
  const familyPublicId = `fam_mutation_${label}_${sequence++}`;
  const accessHash = hash32(`access-mutation-${label}`);
  await pool.query(
    `INSERT INTO roomscan.auth_session_families (
       id, public_id, principal_id, authentication_epoch, authenticated_at,
       last_used_at, inactivity_expires_at, absolute_expires_at, policy_version,
       workspace_id, role, authorization_version, state, created_at
     ) SELECT $1, $2, principal.id, principal.authentication_epoch, $3, $3,
       $3::timestamptz + interval '1 day', $3::timestamptz + interval '7 days',
       'session-v1', $4, $5, membership.authorization_version, 'active', $3
       FROM roomscan.principals AS principal
       JOIN roomscan.memberships AS membership
         ON membership.principal_id = principal.id AND membership.workspace_id = $4
      WHERE principal.id = $6 AND membership.state = 'active'`,
    [familyId, familyPublicId, now, workspaceId, role, principalId],
  );
  await pool.query(
    `INSERT INTO roomscan.auth_access_tokens (
       id, family_id, token_hash, expires_at, principal_id,
       authentication_epoch, authenticated_at, issued_at,
       workspace_id, role, authorization_version, state, created_at
     ) SELECT gen_random_uuid(), family.id, $1, $2::timestamptz + interval '1 hour',
       family.principal_id, family.authentication_epoch, family.authenticated_at,
       $2, family.workspace_id, family.role, family.authorization_version,
       'active', $2 FROM roomscan.auth_session_families AS family
      WHERE family.id = $3`,
    [accessHash, now, familyId],
  );
  return { accessHash, familyId, familyPublicId };
}

async function insertUnscopedAccess(pool, { principalId, label }) {
  const familyId = `67500000-0000-4000-8000-${String(sequence++).padStart(12, '0')}`;
  const familyPublicId = `fam_mutation_unscoped_${label}_${sequence++}`;
  const accessHash = hash32(`access-mutation-unscoped-${label}`);
  await pool.query(
    `INSERT INTO roomscan.auth_session_families (
       id, public_id, principal_id, authentication_epoch, authenticated_at,
       last_used_at, inactivity_expires_at, absolute_expires_at, policy_version,
       state, created_at
     ) SELECT $1, $2, principal.id, principal.authentication_epoch, $3, $3,
       $3::timestamptz + interval '1 day', $3::timestamptz + interval '7 days',
       'session-v1', 'active', $3
       FROM roomscan.principals AS principal WHERE principal.id = $4`,
    [familyId, familyPublicId, now, principalId],
  );
  await pool.query(
    `INSERT INTO roomscan.auth_access_tokens (
       id, family_id, token_hash, expires_at, principal_id,
       authentication_epoch, authenticated_at, issued_at, state, created_at
     ) SELECT gen_random_uuid(), family.id, $1, $2::timestamptz + interval '1 hour',
       family.principal_id, family.authentication_epoch, family.authenticated_at,
       $2, 'active', $2 FROM roomscan.auth_session_families AS family
      WHERE family.id = $3`,
    [accessHash, now, familyId],
  );
  return { accessHash, familyId, familyPublicId };
}

async function waitForMutationLock(pool, applicationName) {
  const deadline = Date.now() + 1_500;
  while (Date.now() < deadline) {
    const rows = (await pool.query(
      `SELECT wait_event FROM pg_catalog.pg_stat_activity
        WHERE application_name = $1 AND wait_event_type = 'Lock'`,
      [applicationName],
    )).rows;
    if (rows.length === 1) return rows[0].wait_event;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.fail(`timed out waiting for mutation lock ${applicationName}`);
}

async function activateQuota(pool, workspaceId = ids.workspaceA) {
  await withRole(pool, 'roomscan_operator', async () => {
    await pool.query(
      `SELECT * FROM roomscan.activate_quota_policy_v2(
         $1, 1, 'roomscan-quota-policy-v1', 'test-only',
         'roomscan-period-v1:test-a', 10, 10, 100, 100, 100, 80, 1, 1, $2
       )`,
      [workspaceId, now],
    );
  });
}

async function quotaOverviewRows(apiPool, accessHash) {
  return (await apiPool.query(
    `SELECT * FROM roomscan.read_quota_overview_v2(
       $1::bytea, $2::timestamptz
     )`,
    [accessHash, now],
  )).rows;
}

async function quotaOverviewPeriodOracle({ cluster, bootstrapPool }) {
  await setHostedFlags(bootstrapPool, ids.workspaceA, true);
  await activateQuota(bootstrapPool);
  const { accessHash } = await insertAccess(bootstrapPool, {
    label: `quota_overview_period_${sequence++}`,
  });
  const apiPool = new Pool({
    ...appPoolConfig(cluster, 1), user: 'roomscan_api_runtime', max: 1,
  });
  try {
    let rows;
    try {
      rows = await quotaOverviewRows(apiPool, accessHash);
    } catch (error) {
      assert.fail(`quota overview must return its five authoritative rows: ${error.code}`);
    }
    assert.equal(rows.length, 5, 'quota overview returned a partial metric set');
    const portal = rows.find(({ metric }) => metric === 'portal_bytes');
    assert.equal(portal?.period_key, 'roomscan-period-v1:test-a',
      'quota overview ignored the active portal period');
  } finally {
    await apiPool.end();
  }
}

async function quotaOverviewHostedFlagOracle({ cluster, bootstrapPool }) {
  await setHostedFlags(bootstrapPool, ids.workspaceA, true);
  await activateQuota(bootstrapPool);
  const { accessHash } = await insertAccess(bootstrapPool, {
    label: `quota_overview_flag_${sequence++}`,
  });
  await withRole(bootstrapPool, 'roomscan_operator', async () => {
    await bootstrapPool.query(
      `SELECT * FROM roomscan.set_operational_flag(
         'global', NULL, 'hosted_operations_enabled', false, 1,
         'quota overview mutation oracle', $1, $2
       )`,
      [`ofaud_mut_overview_global_off_${sequence++}`, new Date(now.getTime() + 1_000)],
    );
    await bootstrapPool.query(
      `SELECT * FROM roomscan.set_operational_flag(
         'workspace', $1, 'hosted_operations_enabled', false, 1,
         'quota overview mutation oracle', $2, $3
       )`,
      [ids.workspaceA, `ofaud_mut_overview_workspace_off_${sequence++}`,
        new Date(now.getTime() + 1_001)],
    );
  });
  const apiPool = new Pool({
    ...appPoolConfig(cluster, 1), user: 'roomscan_api_runtime', max: 1,
  });
  try {
    assert.equal((await quotaOverviewRows(apiPool, accessHash)).length, 0,
      'quota overview bypassed a literal-false hosted flag');
  } finally {
    await apiPool.end();
  }
}

async function emailDeliveryLaneOracle({ bootstrapPool }) {
  const routine = 'roomscan.claim_next_magic_delivery(text,timestamp with time zone,timestamp with time zone)';
  assert.equal((await bootstrapPool.query(
    `SELECT has_function_privilege(
       'roomscan_email_delivery_runtime', $1, 'EXECUTE'
     ) AS allowed`, [routine],
  )).rows[0].allowed, true, 'email worker lacks claim-next capability');
  for (const role of ['roomscan_api_runtime', 'roomscan_auth_challenge_runtime']) {
    assert.equal((await bootstrapPool.query(
      `SELECT has_function_privilege($1, $2, 'EXECUTE') AS allowed`,
      [role, routine],
    )).rows[0].allowed, false, `${role} gained email claim-next execution`);
  }
  assert.equal(Number((await bootstrapPool.query(
    `SELECT count(*)::integer AS count
       FROM information_schema.role_table_grants
      WHERE table_schema = 'roomscan'
        AND grantee = 'roomscan_email_delivery_runtime'
        AND privilege_type IN ('SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')`,
  )).rows[0].count), 0, 'email worker gained direct table privileges');
}

async function insertEmailMutationDelivery(pool, index) {
  const selector = String(index).padStart(22, 'M');
  const id = `magic_email_mutation_${index}`;
  const createdAt = new Date(now.getTime() - (3 - index) * 1_000);
  await pool.query(
    `INSERT INTO roomscan.magic_links (
       selector, secret_digest, purpose, normalized_delivery_identity,
       address_hash, network_hash, issued_at, expires_at, policy_version
     ) VALUES ($1, $2, 'sign-in', $3, $4, $5, $6,
       $6::timestamptz + interval '10 minutes', 'magic-link-v1')`,
    [selector, hash32(`email-mutation-secret-${index}`),
      `email-mutation-${index}@example.invalid`,
      hash32(`email-mutation-address-${index}`),
      hash32(`email-mutation-network-${index}`), createdAt],
  );
  await pool.query(
    `INSERT INTO roomscan.magic_link_delivery_outbox (
       id, selector, normalized_delivery_identity, purpose, envelope_version,
       key_id, iv, ciphertext, authentication_tag, created_at, expires_at,
       policy_version
     ) VALUES ($1, $2, $3, 'sign-in', 'aes-256-gcm-v1', 'mutation-key-v1',
       $4, $5, $6, $7, $7::timestamptz + interval '10 minutes',
       'magic-link-v1')`,
    [id, selector, `email-mutation-${index}@example.invalid`,
      Buffer.alloc(12, index), Buffer.alloc(32, index + 1),
      Buffer.alloc(16, index + 2), createdAt],
  );
  return id;
}

async function emailClaimNextSkipLockedOracle({ cluster, bootstrapPool }) {
  await setProfessionalSignInFlag(bootstrapPool, true);
  const firstId = await insertEmailMutationDelivery(bootstrapPool, 1);
  const secondId = await insertEmailMutationDelivery(bootstrapPool, 2);
  const emailPool = new Pool({
    ...appPoolConfig(cluster, 2), user: 'roomscan_email_delivery_runtime', max: 2,
  });
  const first = await emailPool.connect();
  const second = await emailPool.connect();
  let firstBegan = false;
  let secondBegan = false;
  try {
    await first.query('BEGIN');
    firstBegan = true;
    await second.query('BEGIN');
    secondBegan = true;
    await second.query(`SET LOCAL statement_timeout = '750ms'`);
    const firstClaim = (await first.query(
      `SELECT id FROM roomscan.claim_next_magic_delivery($1, $2, $3)`,
      ['email_mutation_lease_1', now, new Date(now.getTime() + 30_000)],
    )).rows[0];
    assert.equal(firstClaim.id, firstId, 'first email worker did not claim oldest row');
    let secondClaim;
    try {
      secondClaim = (await second.query(
        `SELECT id FROM roomscan.claim_next_magic_delivery($1, $2, $3)`,
        ['email_mutation_lease_2', now, new Date(now.getTime() + 30_000)],
      )).rows[0];
    } catch (error) {
      assert.fail(`parallel claim-next did not skip the locked oldest row: ${error.code}`);
    }
    assert.equal(secondClaim.id, secondId,
      'parallel email worker did not claim the next unlocked row');
    await second.query('COMMIT');
    secondBegan = false;
    await first.query('COMMIT');
    firstBegan = false;
  } finally {
    if (secondBegan) await second.query('ROLLBACK').catch(() => undefined);
    if (firstBegan) await first.query('ROLLBACK').catch(() => undefined);
    second.release();
    first.release();
    await emailPool.end();
  }
}

async function emailClaimNextSignInGateOracle({ cluster, bootstrapPool }) {
  await setProfessionalSignInFlag(bootstrapPool, false);
  await insertEmailMutationDelivery(bootstrapPool, 3);
  const emailPool = new Pool({
    ...appPoolConfig(cluster, 1), user: 'roomscan_email_delivery_runtime', max: 1,
  });
  try {
    assert.equal((await emailPool.query(
      `SELECT count(*)::integer AS count
         FROM roomscan.claim_next_magic_delivery($1, $2, $3)`,
      ['email_gate_mutation_lease', now, new Date(now.getTime() + 30_000)],
    )).rows[0].count, 0, 'disabled professional sign-in authorized email recovery');
  } finally {
    await emailPool.end();
  }
}

async function emailValidateSignInGateOracle({ cluster, bootstrapPool }) {
  await setProfessionalSignInFlag(bootstrapPool, true);
  const id = await insertEmailMutationDelivery(bootstrapPool, 4);
  const emailPool = new Pool({
    ...appPoolConfig(cluster, 1), user: 'roomscan_email_delivery_runtime', max: 1,
  });
  try {
    const claimed = (await emailPool.query(
      `SELECT * FROM roomscan.claim_magic_delivery($1, $2, $3, $4)`,
      [id, 'email_validate_gate_lease', now, new Date(now.getTime() + 30_000)],
    )).rows[0];
    await setProfessionalSignInFlag(
      bootstrapPool, false, 1, new Date(now.getTime() + 1),
    );
    assert.equal((await emailPool.query(
      `SELECT count(*)::integer AS count
         FROM roomscan.validate_magic_delivery($1, $2, $3)`,
      [id, claimed.lease_id, new Date(now.getTime() + 2)],
    )).rows[0].count, 0, 'disable-between-claim-and-send remained sendable');
  } finally {
    await emailPool.end();
  }
}

async function emailValidateLinkStateOracle({ cluster, bootstrapPool }) {
  await setProfessionalSignInFlag(bootstrapPool, true);
  const id = await insertEmailMutationDelivery(bootstrapPool, 5);
  const emailPool = new Pool({
    ...appPoolConfig(cluster, 1), user: 'roomscan_email_delivery_runtime', max: 1,
  });
  try {
    const claimed = (await emailPool.query(
      `SELECT * FROM roomscan.claim_magic_delivery($1, $2, $3, $4)`,
      [id, 'email_validate_link_lease', now, new Date(now.getTime() + 30_000)],
    )).rows[0];
    await bootstrapPool.query(
      `UPDATE roomscan.magic_links AS link
          SET state = 'consumed', consumed_at = $2
         FROM roomscan.magic_link_delivery_outbox AS delivery
        WHERE delivery.id = $1 AND link.selector = delivery.selector`,
      [id, new Date(now.getTime() + 1)],
    );
    assert.equal((await emailPool.query(
      `SELECT count(*)::integer AS count
         FROM roomscan.validate_magic_delivery($1, $2, $3)`,
      [id, claimed.lease_id, new Date(now.getTime() + 2)],
    )).rows[0].count, 0, 'consumed magic link remained sendable');
  } finally {
    await emailPool.end();
  }
}

async function workspaceReadScopeOracle({ cluster, bootstrapPool }) {
  const { accessHash } = await insertAccess(bootstrapPool, {
    label: `workspace_read_${sequence++}`,
  });
  const apiPool = new Pool({
    ...appPoolConfig(cluster, 1), user: 'roomscan_api_runtime', max: 1,
  });
  try {
    const result = await apiPool.query(
      `SELECT workspace_id, workspace_slug, workspace_display_name
         FROM roomscan.read_workspace_authorization_state($1, $2)`,
      [accessHash, now],
    );
    assert.equal(result.rowCount, 1, 'workspace read returned another tenant');
    assert.deepEqual(result.rows[0], {
      workspace_id: ids.workspaceA,
      workspace_slug: 'workspace-a',
      workspace_display_name: 'Workspace A',
    });
  } finally {
    await apiPool.end();
  }
}

async function stripeClaimHostedGateOracle({ cluster, bootstrapPool }) {
  await setHostedFlags(bootstrapPool, ids.workspaceA, true);
  const scopeSuffix = `mutationgate${sequence++}`;
  const account = `acct_${scopeSuffix}`;
  const customer = `cus_${scopeSuffix}`;
  const subscription = `sub_${scopeSuffix}`;
  await withRole(bootstrapPool, 'roomscan_operator', async () => {
    await bootstrapPool.query(
      `SELECT roomscan.bind_stripe_account($1, 'platform', $2, $3, $4, $5)`,
      [ids.workspaceA, account, customer, subscription, now],
    );
  });
  const ingressPool = new Pool({
    ...appPoolConfig(cluster, 1), user: 'roomscan_stripe_ingress_runtime', max: 1,
  });
  const reconciliationPool = new Pool({
    ...appPoolConfig(cluster, 1), user: 'roomscan_stripe_reconciliation_runtime', max: 1,
  });
  try {
    await ingressPool.query(
      `SELECT * FROM roomscan.accept_stripe_event_v2(
         'platform', $1, $2, $3, $4, 'customer.subscription.updated', $3,
         $5, $6, $6
       )`,
      [account, customer, subscription, `evt_mutationgate${sequence++}`,
        hash32('stripe-claim-gate-mutation'), now],
    );
    await withRole(bootstrapPool, 'roomscan_operator', async () => {
      await bootstrapPool.query(
        `SELECT * FROM roomscan.set_operational_flag(
           'global', NULL, 'hosted_operations_enabled', false, 1,
           'mutation oracle', $1, $2
         )`,
        [`ofaud_mut_stripe_claim_global_${sequence++}`, new Date(now.getTime() + 1)],
      );
      await bootstrapPool.query(
        `SELECT * FROM roomscan.set_operational_flag(
           'workspace', $1, 'hosted_operations_enabled', false, 1,
           'mutation oracle', $2, $3
         )`,
        [ids.workspaceA, `ofaud_mut_stripe_claim_workspace_${sequence++}`,
          new Date(now.getTime() + 2)],
      );
    });
    assert.equal((await reconciliationPool.query(
      `SELECT count(*)::integer AS count
         FROM roomscan.claim_stripe_reconciliation_v2($1, $2, $3)`,
      ['stripe_claim_gate_lease', new Date(now.getTime() + 3),
        new Date(now.getTime() + 30_003)],
    )).rows[0].count, 0, 'disabled hosted flags authorized Stripe reconciliation claim');
  } finally {
    await reconciliationPool.end();
    await ingressPool.end();
  }
}

async function loginRoleOracle({ bootstrapPool }) {
  assert.equal((await bootstrapPool.query(
    `SELECT rolcanlogin FROM pg_roles WHERE rolname = 'roomscan_app'`,
  )).rows[0].rolcanlogin, false, 'shared roomscan_app regained LOGIN');
}

async function rawTargetOracle({ cluster, bootstrapPool }) {
  const apiPool = new Pool({ ...appPoolConfig(cluster, 2), user: 'roomscan_api_runtime' });
  try {
    const before = (await bootstrapPool.query(
      `SELECT authentication_epoch FROM roomscan.principals WHERE id = $1`, [ids.principalB],
    )).rows[0].authentication_epoch;
    await expectDatabaseError(
      () => apiPool.query('SELECT roomscan.bump_principal_authentication_epoch($1)', [ids.principalB]),
      '42501',
    );
    assert.equal((await bootstrapPool.query(
      `SELECT authentication_epoch FROM roomscan.principals WHERE id = $1`, [ids.principalB],
    )).rows[0].authentication_epoch, before, 'cross-principal UUID changed another principal');
  } finally {
    await apiPool.end();
  }
}

async function directDmlOracle({ cluster, bootstrapPool }) {
  const apiPool = new Pool({ ...appPoolConfig(cluster, 2), user: 'roomscan_api_runtime' });
  try {
    await expectDatabaseError(
      () => apiPool.query(
        `UPDATE roomscan.principals SET authentication_epoch = authentication_epoch + 1
          WHERE id = $1`, [ids.principalB],
      ),
      '42501',
    );
    assert.equal((await bootstrapPool.query(
      `SELECT authentication_epoch FROM roomscan.principals WHERE id = $1`, [ids.principalB],
    )).rows[0].authentication_epoch, '0');
  } finally {
    await apiPool.end();
  }
}

async function searchPathOracle({ bootstrapPool }) {
  const config = (await bootstrapPool.query(
    `SELECT proconfig FROM pg_proc AS procedure
       JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
      WHERE namespace.nspname = 'roomscan'
        AND procedure.proname = 'rotate_session_from_refresh'`,
  )).rows[0].proconfig;
  assert.deepEqual(config, ['search_path=pg_catalog, pg_temp']);
}

async function publicExecuteOracle({ bootstrapPool }) {
  assert.equal((await bootstrapPool.query(
    `SELECT has_function_privilege(
       'public',
       'roomscan.rotate_session_from_refresh(bytea,bytea,bytea,timestamp with time zone,timestamp with time zone,timestamp with time zone)',
       'EXECUTE'
     ) AS allowed`,
  )).rows[0].allowed, false, 'PUBLIC can execute refresh rotation');
}

async function forceRlsOracle({ bootstrapPool }) {
  assert.equal((await bootstrapPool.query(
    `SELECT relforcerowsecurity FROM pg_class AS relation
       JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
      WHERE namespace.nspname = 'roomscan' AND relation.relname = 'member_slots'`,
  )).rows[0].relforcerowsecurity, true, 'member_slots is not FORCE RLS');
}

async function refreshLaneOracle({ cluster, bootstrapPool }) {
  assert.equal((await bootstrapPool.query(
    `SELECT has_function_privilege(
       'roomscan_auth_challenge_runtime',
       'roomscan.rotate_session_from_refresh(bytea,bytea,bytea,timestamp with time zone,timestamp with time zone,timestamp with time zone)',
       'EXECUTE'
     ) AS allowed`,
  )).rows[0].allowed, false, 'Cognito challenge lane can rotate API refresh tokens');
  const challengePool = new Pool({
    ...appPoolConfig(cluster, 1), user: 'roomscan_auth_challenge_runtime',
  });
  try {
    await expectDatabaseError(
      () => challengePool.query(
        `SELECT * FROM roomscan.rotate_session_from_refresh(
           NULL, NULL, NULL, NULL, NULL, NULL
         )`,
      ),
      '42501',
    );
  } finally {
    await challengePool.end();
  }
}

async function nullGuardOracle({ cluster }) {
  const apiPool = new Pool({ ...appPoolConfig(cluster, 1), user: 'roomscan_api_runtime' });
  try {
    await expectDatabaseError(
      () => apiPool.query('SELECT * FROM roomscan.logout_all_from_access(NULL, $1)', [now]),
      '22023',
      'INVALID_LOGOUT_ALL_INPUT',
    );
  } finally {
    await apiPool.end();
  }
}

async function lastOwnerOracle({ cluster, bootstrapPool }) {
  await setHostedFlags(bootstrapPool, ids.workspaceA);
  const { accessHash } = await insertAccess(bootstrapPool, { label: 'last_owner' });
  const canonicalId = (await bootstrapPool.query(
    `SELECT canonical_id FROM roomscan.principals WHERE id = $1`, [ids.principalA],
  )).rows[0].canonical_id;
  const apiPool = new Pool({ ...appPoolConfig(cluster, 2), user: 'roomscan_api_runtime' });
  try {
    await expectDatabaseError(
      () => apiPool.query(
        `SELECT * FROM roomscan.mutate_membership_v2(
           $1, $2, $3, 1, 'owner', 'active', 'viewer', 'active',
           1, 1, 'aud_mutation_last_owner_07'
         )`,
        [accessHash, now, canonicalId],
      ),
      'P0001',
      'LAST_OWNER_REQUIRED',
    );
    assert.equal(Number((await bootstrapPool.query(
      `SELECT count(*)::integer AS count FROM roomscan.memberships
        WHERE workspace_id = $1 AND role = 'owner' AND state = 'active'`,
      [ids.workspaceA],
    )).rows[0].count), 1);
  } finally {
    await apiPool.end();
  }
}

async function flagLiteralTrueOracle({ bootstrapPool }) {
  await setHostedFlags(bootstrapPool, ids.workspaceA, false);
  assert.equal((await bootstrapPool.query(
    `SELECT roomscan.hosted_mutation_grant_matches(
       $1, 'project.create', 1, 1, NULL, NULL
     ) AS allowed`, [ids.workspaceA],
  )).rows[0].allowed, false, 'disabled hosted flags authorized a mutation');
}

async function flagVersionOracle({ bootstrapPool }) {
  await setHostedFlags(bootstrapPool, ids.workspaceA, true);
  assert.equal((await bootstrapPool.query(
    `SELECT roomscan.hosted_mutation_grant_matches(
       $1, 'project.create', 2, 2, NULL, NULL
     ) AS allowed`, [ids.workspaceA],
  )).rows[0].allowed, false, 'stale/nonexistent flag versions authorized a mutation');
  assert.equal((await bootstrapPool.query(
    `SELECT roomscan.hosted_mutation_grant_matches(
       $1, 'project.create', 1, 1, NULL, NULL
     ) AS allowed`, [ids.workspaceA],
  )).rows[0].allowed, true, 'exact current flag versions positive control failed');
}

async function periodIdentityOracle({ cluster, bootstrapPool }) {
  await setHostedFlags(bootstrapPool, ids.workspaceA);
  await activateQuota(bootstrapPool);
  const { accessHash } = await insertAccess(bootstrapPool, { label: 'period_identity' });
  const apiPool = new Pool({ ...appPoolConfig(cluster, 2), user: 'roomscan_api_runtime' });
  try {
    await expectDatabaseError(
      () => apiPool.query(
        `SELECT * FROM roomscan.reserve_quota_v2(
           $1, $2, 'project_count', 'roomscan-period-v1:test-a',
           'project.create', NULL, NULL, 1, 'period-mutation', 1,
           $2::timestamptz + interval '1 minute', 1, 1, NULL, NULL
         )`,
        [accessHash, now],
      ),
      'P0001',
      'QUOTA_POLICY_MISMATCH',
    );
  } finally {
    await apiPool.end();
  }
}

async function reservationExpiryOracle({ cluster, bootstrapPool }) {
  await setHostedFlags(bootstrapPool, ids.workspaceA);
  await activateQuota(bootstrapPool);
  const { accessHash } = await insertAccess(bootstrapPool, { label: 'reservation_expiry' });
  const apiPool = new Pool({ ...appPoolConfig(cluster, 2), user: 'roomscan_api_runtime' });
  try {
    await apiPool.query(
      `SELECT * FROM roomscan.reserve_quota_v2(
         $1, $2, 'project_count', 'roomscan-period-v1:lifetime',
         'project.create', NULL, NULL, 1, 'expiry-mutation', 1,
         $2::timestamptz + interval '1 second', 1, 1, NULL, NULL
       )`,
      [accessHash, now],
    );
    await expectDatabaseError(
      () => apiPool.query(
        `SELECT * FROM roomscan.finalize_quota_v2(
           $1, $2::timestamptz + interval '2 seconds',
           'roomscan-period-v1:lifetime', 'expiry-mutation', 1,
           1, 1, NULL, NULL
         )`,
        [accessHash, now],
      ),
      'P0001',
      'QUOTA_RESERVATION_EXPIRED_OR_AMOUNT',
    );
    assert.equal((await bootstrapPool.query(
      `SELECT state FROM roomscan.quota_reservations_v2
        WHERE workspace_id = $1 AND idempotency_key = 'expiry-mutation'`,
      [ids.workspaceA],
    )).rows[0].state, 'reserved');
  } finally {
    await apiPool.end();
  }
}

async function defaultOffSignInOracle({ cluster, bootstrapPool }) {
  const apiPool = new Pool({ ...appPoolConfig(cluster, 1), user: 'roomscan_api_runtime' });
  try {
    const row = (await apiPool.query(
      `SELECT * FROM roomscan.issue_magic_challenge_v3(
         NULL, $1, $2, $3, $4, $5, 'sign-in', 'mutant@example.invalid', $6, $7,
         $1::timestamptz + interval '10 minutes', 'magic-v3',
         'mdl_mutation_default_off_07', 'key-v1', $8, $9, $10,
         60, 2, 900, 3, 86400, 10, 900, 20, 3, 900, 10
       )`,
      [now, 'M'.repeat(22), hash32('default-off-secret'),
        hash32('default-off-completion'), 'A'.repeat(43),
        hash32('default-off-address'), hash32('default-off-network'),
        Buffer.alloc(12, 1), Buffer.alloc(32, 2), Buffer.alloc(16, 3)],
    )).rows[0];
    assert.equal(row.status, 'professional_sign_in_disabled');
    assert.equal(Number((await bootstrapPool.query(
      `SELECT count(*)::integer AS count FROM roomscan.magic_links`,
    )).rows[0].count), 0);
  } finally {
    await apiPool.end();
  }
}

async function setupStripe(cluster, bootstrapPool, label) {
  await setHostedFlags(bootstrapPool, ids.workspaceA);
  const canonicalSuffix = label.replaceAll('_', '');
  const account = `acct_${canonicalSuffix}`;
  const customer = `cus_${canonicalSuffix}`;
  const subscription = `sub_${canonicalSuffix}`;
  const eventId = `evt_${canonicalSuffix}`;
  await withRole(bootstrapPool, 'roomscan_operator', async () => {
    await bootstrapPool.query(
      `SELECT roomscan.bind_stripe_account($1, 'platform', $2, $3, $4, $5)`,
      [ids.workspaceA, account, customer, subscription, now],
    );
  });
  const ingressPool = new Pool({
    ...appPoolConfig(cluster, 1), user: 'roomscan_stripe_ingress_runtime',
  });
  const reconcilePool = new Pool({
    ...appPoolConfig(cluster, 1), user: 'roomscan_stripe_reconciliation_runtime',
  });
  try {
    await ingressPool.query(
      `SELECT * FROM roomscan.accept_stripe_event_v2(
         'platform', $1, $2, $3, $4, 'customer.subscription.updated', $3,
         $5, $6::timestamptz - interval '1 second', $6
       )`,
      [account, customer, subscription, eventId, hash32(`stripe-${label}`), now],
    );
    const claim = (await reconcilePool.query(
      `SELECT * FROM roomscan.claim_stripe_reconciliation_v2(
         $1, $2, $2::timestamptz + interval '1 minute'
       )`,
      [`lease_${label}`, now],
    )).rows[0];
    assert.ok(claim);
    return {
      ingressPool, reconcilePool, claim, account, customer, subscription, eventId,
    };
  } catch (error) {
    await ingressPool.end();
    await reconcilePool.end();
    throw error;
  }
}

async function stripeEventIdFunctionGuardOracle({ cluster, bootstrapPool }) {
  await setHostedFlags(bootstrapPool, ids.workspaceA);
  await withRole(bootstrapPool, 'roomscan_operator', async () => {
    await bootstrapPool.query(
      `SELECT roomscan.bind_stripe_account(
         $1, 'platform', 'acct_eventguard', 'cus_eventguard',
         'sub_eventguard', $2
       )`,
      [ids.workspaceA, now],
    );
  });
  const ingressPool = new Pool({
    ...appPoolConfig(cluster, 1), user: 'roomscan_stripe_ingress_runtime', max: 1,
  });
  try {
    await expectDatabaseError(
      () => ingressPool.query(
        `SELECT * FROM roomscan.accept_stripe_event_v2(
           'platform', 'acct_eventguard', 'cus_eventguard', 'sub_eventguard',
           'event_lookalike', 'customer.subscription.updated', 'sub_eventguard',
           $1, $2, $2
         )`,
        [hash32('stripe-event-id-function-guard'), now],
      ),
      '22023',
      'INVALID_STRIPE_EVENT_V2',
    );
  } finally {
    await ingressPool.end();
  }
}

async function stripeEventIdStorageConstraintOracle({ bootstrapPool }) {
  await withRole(bootstrapPool, 'roomscan_operator', async () => {
    await bootstrapPool.query(
      `SELECT roomscan.bind_stripe_account(
         $1, 'platform', 'acct_eventstore', 'cus_eventstore',
         'sub_eventstore', $2
       )`,
      [ids.workspaceA, now],
    );
  });
  await bootstrapPool.query('BEGIN');
  try {
    await bootstrapPool.query('SET LOCAL ROLE roomscan_policy');
    await bootstrapPool.query(
      `SELECT set_config('app.principal_id', $1, true),
              set_config('app.tenant_id', $2, true),
              set_config('app.authorization_version', '1', true)`,
      [ids.principalA, ids.workspaceA],
    );
    await expectDatabaseError(
      () => bootstrapPool.query(
        `INSERT INTO roomscan.stripe_event_receipts_v2 (
           account_mode, provider_account_id, billing_customer_id,
           subscription_id, event_id, workspace_id, event_type, object_id,
           payload_sha256, provider_occurred_at, received_at
         ) VALUES (
           'platform', 'acct_eventstore', 'cus_eventstore', 'sub_eventstore',
           'event_lookalike', $1, 'customer.subscription.updated',
           'sub_eventstore', $2, $3, $3
         )`,
        [ids.workspaceA, hash32('stripe-event-id-storage-guard'), now],
      ),
      '23514',
    );
  } finally {
    await bootstrapPool.query('ROLLBACK');
  }
}

async function stripeLeaseOracle({ cluster, bootstrapPool }) {
  const setup = await setupStripe(cluster, bootstrapPool, 'lease_mutation');
  try {
    const result = (await setup.reconcilePool.query(
      `SELECT * FROM roomscan.complete_stripe_reconciliation_v2(
         'forged_lease', $1, $2, $3, $4, $5, $6,
         'active', 'test-plan', NULL, $7, 1, 1
       )`,
      [setup.claim.account_mode, setup.claim.provider_account_id,
        setup.claim.billing_customer_id, setup.claim.subscription_id,
        setup.claim.generation, new Date(now.getTime() - 500),
        new Date(now.getTime() + 1_000)],
    )).rows[0];
    assert.deepEqual(result, { status: 'stale_claim', needs_another_generation: true });
  } finally {
    await setup.ingressPool.end();
    await setup.reconcilePool.end();
  }
}

async function stripeReceivedAtRetryOracle({ cluster, bootstrapPool }) {
  const label = 'received_time_mutation';
  const setup = await setupStripe(cluster, bootstrapPool, label);
  try {
    let retry;
    await assert.doesNotReject(async () => {
      retry = (await setup.ingressPool.query(
        `SELECT * FROM roomscan.accept_stripe_event_v2(
           'platform', $1, $2, $3, $4, 'customer.subscription.updated', $3,
           $5, $6::timestamptz - interval '1 second',
           $6::timestamptz + interval '1 second'
         )`,
        [setup.account, setup.customer, setup.subscription, setup.eventId,
          hash32(`stripe-${label}`), now],
      )).rows[0];
    }, 'an exact Stripe retry with a later server receive time was rejected');
    assert.deepEqual(retry, {
      status: 'duplicate', workspace_id: ids.workspaceA, generation: '1',
    });
    assert.equal((await bootstrapPool.query(
      `SELECT received_at FROM roomscan.stripe_event_receipts_v2
        WHERE provider_account_id = $1 AND event_id = $2`,
      [setup.account, setup.eventId],
    )).rows[0].received_at.toISOString(), now.toISOString());
  } finally {
    await setup.ingressPool.end();
    await setup.reconcilePool.end();
  }
}

async function stripeOriginalGrantOracle({ cluster, bootstrapPool }) {
  const setup = await setupStripe(cluster, bootstrapPool, 'grant_mutation');
  try {
    await withRole(bootstrapPool, 'roomscan_operator', async () => {
      await bootstrapPool.query(
        `SELECT * FROM roomscan.set_operational_flag(
           'global', NULL, 'hosted_operations_enabled', false, 1,
           'mutation freeze', $1, $2
         )`,
        [`ofaud_mut_stripe_freeze_${sequence++}`, new Date(now.getTime() + 100)],
      );
      await bootstrapPool.query(
        `SELECT * FROM roomscan.set_operational_flag(
           'global', NULL, 'hosted_operations_enabled', true, 2,
           'mutation resume', $1, $2
         )`,
        [`ofaud_mut_stripe_resume_${sequence++}`, new Date(now.getTime() + 200)],
      );
    });
    const result = (await setup.reconcilePool.query(
      `SELECT * FROM roomscan.complete_stripe_reconciliation_v2(
         $1, $2, $3, $4, $5, $6, $7,
         'past_due', 'mutated-plan', NULL, $8, 1, 1
       )`,
      [setup.claim.lease_id, setup.claim.account_mode, setup.claim.provider_account_id,
        setup.claim.billing_customer_id, setup.claim.subscription_id,
        setup.claim.generation, new Date(now.getTime() - 500),
        new Date(now.getTime() + 1_000)],
    )).rows[0];
    assert.deepEqual(result, { status: 'hosted_gate_rejected', needs_another_generation: true });
    assert.equal((await bootstrapPool.query(
      `SELECT plan_key FROM roomscan.subscription_states WHERE workspace_id = $1`,
      [ids.workspaceA],
    )).rows[0].plan_key, 'starter');
  } finally {
    await setup.ingressPool.end();
    await setup.reconcilePool.end();
  }
}

async function appleResultReplayOracle({ cluster, bootstrapPool }) {
  await withRole(bootstrapPool, 'roomscan_operator', async () => {
    await bootstrapPool.query(
      `SELECT * FROM roomscan.set_operational_flag(
         'global', NULL, 'professional_sign_in_enabled', true, NULL,
         'mutation oracle', $1, $2
       )`,
      [`ofaud_mut_apple_${sequence++}`, now],
    );
  });
  await bootstrapPool.query(
    `INSERT INTO roomscan.apple_auth_attempts (
       id, state_hash, nonce_hash, code_challenge, expected_client_id,
       redirect_uri, created_at, expires_at, policy_version, purpose,
       state, claimed_at
     ) VALUES (
       'apple_mutation_attempt_07', $1, $2,
       'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', 'com.roomscan.test',
       'https://example.invalid/apple/callback', $3,
       $3::timestamptz + interval '5 minutes', 'apple-v1', 'sign-in',
       'claimed', $3
     )`,
    [hash32('apple-mutation-state'), hash32('apple-mutation-nonce'), now],
  );
  const apiPool = new Pool({ ...appPoolConfig(cluster, 2), user: 'roomscan_api_runtime' });
  try {
    const accept = (proofHash) => apiPool.query(
      `SELECT * FROM roomscan.accept_apple_verified_result_v2(
         'apple_mutation_attempt_07', 'https://appleid.apple.com',
         'apple-mutation-subject', $1, NULL, $2,
         $2::timestamptz + interval '1 minute', 'apple-v1'
       )`,
      [proofHash, new Date(now.getTime() + 1_000)],
    );
    assert.equal((await accept(hash32('apple-mutation-proof-a'))).rows[0].status, 'bridge_created');
    assert.equal((await accept(hash32('apple-mutation-proof-b'))).rows[0].status, 'unavailable');
    assert.equal(Number((await bootstrapPool.query(
      `SELECT count(*)::integer AS count FROM roomscan.apple_bridge_proofs
        WHERE attempt_id = 'apple_mutation_attempt_07'`,
    )).rows[0].count), 1);
  } finally {
    await apiPool.end();
  }
}

function magicV3S256(verifier) {
  return createHash('sha256').update(verifier).digest('base64url');
}

async function issueMagicV3(apiPool, label, {
  purpose = 'sign-in', accessHash = null,
  expiresAt = new Date(now.getTime() + 10 * 60_000),
  maxCompletionFailures = 5, maxNetworkFailures = 10,
} = {}) {
  const suffix = String(sequence++).padStart(19, '0');
  const selector = `V3M${suffix}`;
  const verifier = `verifier-${label}-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789`;
  const flow = {
    selector,
    purpose,
    secretDigest: hash32(`magic-v3-secret-${label}`),
    completionHash: hash32(`magic-v3-completion-${label}`),
    codeChallenge: magicV3S256(verifier),
    transferDigest: hash32(`magic-v3-transfer-${label}`),
    expiresAt,
  };
  const result = (await apiPool.query(
    `SELECT * FROM roomscan.issue_magic_challenge_v3(
       $1::bytea, $2::timestamptz, $3, $4::bytea, $5::bytea, $6,
       $7, $8, $9::bytea, $10::bytea, $11::timestamptz,
       'magic-v3', $12, 'magic-key-v3', $13::bytea, $14::bytea, $15::bytea,
       0, 2, 900, 3, 86400, 10, 900, 20, $16, 900, $17
     )`,
    [accessHash, now, selector, flow.secretDigest, flow.completionHash,
      flow.codeChallenge, purpose, `${label}@example.invalid`,
      hash32(`magic-v3-address-${label}`), hash32(`magic-v3-issue-network-${label}`),
      expiresAt, `mdl_mut_magicv3_${label}_${suffix}`, Buffer.alloc(12, 1),
      Buffer.alloc(32, 2), Buffer.alloc(16, 3), maxCompletionFailures,
      maxNetworkFailures],
  )).rows[0];
  assert.equal(result.status, 'issued');
  const confirmed = (await apiPool.query(
    `SELECT * FROM roomscan.consume_magic_challenge_v3(
       $1, $2::bytea, $3, $4::timestamptz, $5::bytea
     )`,
    [selector, flow.secretDigest, purpose, new Date(now.getTime() + 1_000),
      flow.transferDigest],
  )).rows[0];
  assert.equal(confirmed.status, 'confirmed');
  return flow;
}

function magicV3SessionMaterial(label, at) {
  return {
    receiptHash: null,
    receiptExpiresAt: null,
    familyPublicId: `fam_mut_magicv3_${label}`,
    accessHash: hash32(`magic-v3-access-${label}`),
    refreshHash: hash32(`magic-v3-refresh-${label}`),
    accessExpiresAt: new Date(at.getTime() + 5 * 60_000),
    inactivityExpiresAt: new Date(at.getTime() + 7 * 86400_000),
    absoluteExpiresAt: new Date(at.getTime() + 30 * 86400_000),
    sessionPolicyVersion: 'session-v3',
  };
}

function magicV3ReceiptMaterial(label, at) {
  return {
    receiptHash: hash32(`magic-v3-receipt-${label}`),
    receiptExpiresAt: new Date(at.getTime() + 2 * 60_000),
    familyPublicId: null,
    accessHash: null,
    refreshHash: null,
    accessExpiresAt: null,
    inactivityExpiresAt: null,
    absoluteExpiresAt: null,
    sessionPolicyVersion: null,
  };
}

async function redeemMagicV3(apiPool, flow, material, {
  at, networkHash = hash32('magic-v3-mutation-network'),
  transferDigest = flow.transferDigest,
} = {}) {
  return (await apiPool.query(
    `SELECT * FROM roomscan.redeem_magic_completion_v3(
       $1::bytea, $2, $3::bytea, $4, $5::bytea, $6::timestamptz,
       $7::bytea, $8::timestamptz, $9, $10::bytea, $11::bytea,
       $12::timestamptz, $13::timestamptz, $14::timestamptz, $15
     )`,
    [flow.completionHash, flow.codeChallenge, transferDigest, flow.purpose,
      networkHash, at, material.receiptHash, material.receiptExpiresAt,
      material.familyPublicId, material.accessHash, material.refreshHash,
      material.accessExpiresAt, material.inactivityExpiresAt,
      material.absoluteExpiresAt, material.sessionPolicyVersion],
  )).rows[0];
}

async function magicReplayExpiryOracle({ cluster, bootstrapPool }) {
  await setProfessionalSignInFlag(bootstrapPool, true);
  const apiPool = new Pool({
    ...appPoolConfig(cluster, 2), user: 'roomscan_api_runtime', max: 2,
  });
  try {
    const flow = await issueMagicV3(apiPool, 'replay-expiry', {
      expiresAt: new Date(now.getTime() + 30_000),
    });
    const issuedAt = new Date(now.getTime() + 2_000);
    const material = magicV3SessionMaterial('replay-expiry', issuedAt);
    assert.equal((await redeemMagicV3(apiPool, flow, material, {
      at: issuedAt,
    })).status, 'session_issued');
    const replayAt = new Date(now.getTime() + 31_000);
    assert.equal((await redeemMagicV3(
      apiPool, flow, magicV3SessionMaterial('replay-expiry', replayAt),
      { at: replayAt },
    )).status, 'unavailable', 'expired redeemed handoff replayed session metadata');
  } finally {
    await apiPool.end();
  }
}

async function magicSessionStatelessReplayOracle({ cluster, bootstrapPool }) {
  await setProfessionalSignInFlag(bootstrapPool, true);
  const apiPool = new Pool({
    ...appPoolConfig(cluster, 2), user: 'roomscan_api_runtime', max: 2,
  });
  try {
    const flow = await issueMagicV3(apiPool, 'session-stateless-retry');
    const issuedAt = new Date(now.getTime() + 2_000);
    const issued = await redeemMagicV3(
      apiPool, flow, magicV3SessionMaterial('session-stateless-retry', issuedAt),
      { at: issuedAt },
    );
    assert.equal(issued.status, 'session_issued');
    const replayAt = new Date(now.getTime() + 3_000);
    const replay = await redeemMagicV3(
      apiPool, flow, magicV3SessionMaterial('session-stateless-retry', replayAt),
      { at: replayAt },
    );
    assert.equal(replay.status, 'session_replayed',
      'stateless session retry depended on recomputed expiries');
    assert.equal(replay.access_expires_at.toISOString(), issued.access_expires_at.toISOString());
  } finally {
    await apiPool.end();
  }
}

async function magicFamilyReplayValidityOracle({ cluster, bootstrapPool }) {
  await setProfessionalSignInFlag(bootstrapPool, true);
  const apiPool = new Pool({
    ...appPoolConfig(cluster, 2), user: 'roomscan_api_runtime', max: 2,
  });
  try {
    const flow = await issueMagicV3(apiPool, 'family-expiry-replay');
    const issuedAt = new Date(now.getTime() + 2_000);
    const material = {
      ...magicV3SessionMaterial('family-expiry-replay', issuedAt),
      inactivityExpiresAt: new Date(now.getTime() + 3_000),
    };
    assert.equal((await redeemMagicV3(apiPool, flow, material, {
      at: issuedAt,
    })).status, 'session_issued');
    const replayAt = new Date(now.getTime() + 4_000);
    assert.equal((await redeemMagicV3(
      apiPool, flow, magicV3SessionMaterial('family-expiry-replay', replayAt),
      { at: replayAt },
    )).status, 'unavailable', 'expired family replayed session metadata');
  } finally {
    await apiPool.end();
  }
}

async function magicReceiptStatelessReplayOracle({ cluster, bootstrapPool }) {
  await setProfessionalSignInFlag(bootstrapPool, true);
  const initiating = await insertAccess(bootstrapPool, {
    label: `magic-receipt-stateless-${sequence++}`,
  });
  const apiPool = new Pool({
    ...appPoolConfig(cluster, 2), user: 'roomscan_api_runtime', max: 2,
  });
  try {
    const flow = await issueMagicV3(apiPool, 'receipt-stateless-retry', {
      purpose: 'link-identity', accessHash: initiating.accessHash,
    });
    const issuedAt = new Date(now.getTime() + 2_000);
    const issued = await redeemMagicV3(
      apiPool, flow, magicV3ReceiptMaterial('receipt-stateless-retry', issuedAt),
      { at: issuedAt },
    );
    assert.equal(issued.status, 'receipt_issued');
    const replayAt = new Date(now.getTime() + 3_000);
    const replay = await redeemMagicV3(
      apiPool, flow, magicV3ReceiptMaterial('receipt-stateless-retry', replayAt),
      { at: replayAt },
    );
    assert.equal(replay.status, 'receipt_replayed',
      'stateless receipt retry depended on recomputed expiry');
    assert.equal(replay.receipt_expires_at.toISOString(), issued.receipt_expires_at.toISOString());
  } finally {
    await apiPool.end();
  }
}

async function magicReceiptReplayValidityOracle({ cluster, bootstrapPool }) {
  await setProfessionalSignInFlag(bootstrapPool, true);
  const initiating = await insertAccess(bootstrapPool, {
    label: `magic-receipt-expiry-${sequence++}`,
  });
  const apiPool = new Pool({
    ...appPoolConfig(cluster, 2), user: 'roomscan_api_runtime', max: 2,
  });
  try {
    const flow = await issueMagicV3(apiPool, 'receipt-expiry-replay', {
      purpose: 'link-identity', accessHash: initiating.accessHash,
    });
    const issuedAt = new Date(now.getTime() + 2_000);
    const material = {
      ...magicV3ReceiptMaterial('receipt-expiry-replay', issuedAt),
      receiptExpiresAt: new Date(now.getTime() + 3_000),
    };
    assert.equal((await redeemMagicV3(apiPool, flow, material, {
      at: issuedAt,
    })).status, 'receipt_issued');
    const replayAt = new Date(now.getTime() + 4_000);
    assert.equal((await redeemMagicV3(
      apiPool, flow, magicV3ReceiptMaterial('receipt-expiry-replay', replayAt),
      { at: replayAt },
    )).status, 'unavailable', 'expired receipt replayed receipt metadata');
  } finally {
    await apiPool.end();
  }
}

async function magicNetworkFailureSerializationOracle({ cluster, bootstrapPool }) {
  await setProfessionalSignInFlag(bootstrapPool, true);
  const apiPool = new Pool({
    ...appPoolConfig(cluster, 2), user: 'roomscan_api_runtime', max: 2,
    application_name: 'rss-0007-mutation-magic-network',
  });
  const blocker = await bootstrapPool.connect();
  const networkHash = hash32('magic-v3-mutation-shared-network');
  let attempts = [];
  let results = [];
  try {
    const first = await issueMagicV3(apiPool, 'network-serialization-one', {
      maxNetworkFailures: 1,
    });
    const second = await issueMagicV3(apiPool, 'network-serialization-two', {
      maxNetworkFailures: 1,
    });
    await blocker.query(
      `SELECT pg_catalog.pg_advisory_lock(pg_catalog.hashtextextended(
         'magic-redeem-network:' || pg_catalog.encode($1::bytea, 'hex'),
         7621846213719046
       ))`,
      [networkHash],
    );
    attempts = [
      redeemMagicV3(apiPool, first, magicV3SessionMaterial('network-one', now), {
        at: new Date(now.getTime() + 2_000), networkHash,
        transferDigest: hash32('magic-v3-wrong-network-one'),
      }),
      redeemMagicV3(apiPool, second, magicV3SessionMaterial('network-two', now), {
        at: new Date(now.getTime() + 2_000), networkHash,
        transferDigest: hash32('magic-v3-wrong-network-two'),
      }),
    ];
    const deadline = Date.now() + 1_500;
    let waiters = 0;
    while (Date.now() < deadline && waiters < 2) {
      waiters = Number((await bootstrapPool.query(
        `SELECT count(*)::integer AS count
           FROM pg_catalog.pg_stat_activity
          WHERE application_name = 'rss-0007-mutation-magic-network'
            AND wait_event_type = 'Lock' AND wait_event = 'advisory'`,
      )).rows[0].count);
      if (waiters < 2) await new Promise((resolve) => setTimeout(resolve, 10));
    }
    assert.equal(waiters, 2, 'concurrent network failures were not serialized');
  } finally {
    await blocker.query(
      `SELECT pg_catalog.pg_advisory_unlock(pg_catalog.hashtextextended(
         'magic-redeem-network:' || pg_catalog.encode($1::bytea, 'hex'),
         7621846213719046
       ))`,
      [networkHash],
    ).catch(() => undefined);
    if (attempts.length > 0) results = await Promise.all(attempts);
    blocker.release();
    await apiPool.end();
  }
  assert.deepEqual(results.map(({ status }) => status).sort(), [
    'rate_limited', 'unavailable',
  ]);
  assert.equal(Number((await bootstrapPool.query(
    `SELECT count(*)::integer AS count
       FROM roomscan.magic_completion_redeem_failures
      WHERE network_hash = $1`,
    [networkHash],
  )).rows[0].count), 1);
}

async function emailDeliveryAuditOutcomeOracle({ cluster, bootstrapPool }) {
  const emailPool = new Pool({
    ...appPoolConfig(cluster, 1), user: 'roomscan_email_delivery_runtime', max: 1,
  });
  try {
    await assert.doesNotReject(
      () => emailPool.query(
        `SELECT roomscan.accept_provider_audit_event(
           'paud_mut_emaildeliveryok', 'email', 'email.delivery.accepted',
           'magic-delivery-mutant-ok', $1
         )`, [now],
      ),
      'email delivery acceptance could not be represented in provider audit',
    );
    await assert.doesNotReject(
      () => emailPool.query(
        `SELECT roomscan.accept_provider_audit_event(
           'paud_mut_emaildeliveryfail', 'email', 'email.delivery.failed',
           'magic-delivery-mutant-failed', $1
         )`, [new Date(now.getTime() + 1)],
      ),
      'email delivery failure could not be represented in provider audit',
    );
    assert.deepEqual((await bootstrapPool.query(
      `SELECT event_code FROM roomscan.provider_audit_outbox
        WHERE id IN ('paud_mut_emaildeliveryok', 'paud_mut_emaildeliveryfail')
        ORDER BY event_code`,
    )).rows.map(({ event_code: eventCode }) => eventCode), [
      'email.delivery.accepted', 'email.delivery.failed',
    ]);
  } finally {
    await emailPool.end();
  }
}

async function stripeBindingSymmetryOracle({ bootstrapPool }) {
  const operator = await bootstrapPool.connect();
  const workspaceOne = '69000000-0000-4000-8000-000000000001';
  const workspaceTwo = '69000000-0000-4000-8000-000000000002';
  try {
    await operator.query(
      `INSERT INTO roomscan.workspaces(id, slug, display_name) VALUES
         ($1, 'mutation-stripe-one', 'Mutation Stripe One'),
         ($2, 'mutation-stripe-two', 'Mutation Stripe Two')`,
      [workspaceOne, workspaceTwo],
    );
    await operator.query('SET ROLE roomscan_operator');
    assert.equal((await operator.query(
      `SELECT roomscan.bind_stripe_account(
         $1, 'connected', 'acct_mutSymmetry', 'cus_mutSymmetry1',
         'sub_mutSymmetry1', $2
       ) AS status`, [workspaceOne, now],
    )).rows[0].status, 'bound');
    await expectDatabaseError(
      () => operator.query(
        `SELECT roomscan.bind_stripe_account(
           $1, 'platform', 'acct_mutSymmetry', 'cus_mutSymmetry2',
           'sub_mutSymmetry2', $2
         )`, [workspaceTwo, now],
      ),
      'P0001', 'STRIPE_BINDING_CONFLICT',
    );
  } finally {
    await operator.query('RESET ROLE').catch(() => undefined);
    operator.release();
  }
}

async function stripeBindingSerializationOracle({ bootstrapPool }) {
  const workspaceOne = '69000000-0000-4000-8000-000000000003';
  const workspaceTwo = '69000000-0000-4000-8000-000000000004';
  const providerAccountId = 'acct_mutBindingRace';
  await bootstrapPool.query(
    `INSERT INTO roomscan.workspaces(id, slug, display_name) VALUES
       ($1, 'mutation-stripe-three', 'Mutation Stripe Three'),
       ($2, 'mutation-stripe-four', 'Mutation Stripe Four')`,
    [workspaceOne, workspaceTwo],
  );
  const blocker = await bootstrapPool.connect();
  const clients = await Promise.all([bootstrapPool.connect(), bootstrapPool.connect()]);
  let pending = [];
  let results = [];
  let waiters = 0;
  try {
    await blocker.query(
      `SELECT pg_catalog.pg_advisory_lock(pg_catalog.hashtextextended(
         'stripe-binding:' || $1, 7621846213719048
       ))`, [providerAccountId],
    );
    await Promise.all(clients.map(async (client, index) => {
      await client.query(`SET application_name = 'rss-0007-mutation-stripe-binding'`);
      await client.query('SET ROLE roomscan_operator');
      return index;
    }));
    pending = [
      clients[0].query(
        `SELECT roomscan.bind_stripe_account(
           $1, 'platform', $2, 'cus_mutBindingA', 'sub_mutBindingA', $3
         )`, [workspaceOne, providerAccountId, now],
      ),
      clients[1].query(
        `SELECT roomscan.bind_stripe_account(
           $1, 'connected', $2, 'cus_mutBindingB', 'sub_mutBindingB', $3
         )`, [workspaceTwo, providerAccountId, now],
      ),
    ];
    const deadline = Date.now() + 1_500;
    while (Date.now() < deadline && waiters < 2) {
      waiters = Number((await bootstrapPool.query(
        `SELECT count(*)::integer AS count
           FROM pg_catalog.pg_stat_activity
          WHERE application_name = 'rss-0007-mutation-stripe-binding'
            AND wait_event_type = 'Lock' AND wait_event = 'advisory'`,
      )).rows[0].count);
      if (waiters < 2) await new Promise((resolve) => setTimeout(resolve, 10));
    }
  } finally {
    await blocker.query(
      `SELECT pg_catalog.pg_advisory_unlock(pg_catalog.hashtextextended(
         'stripe-binding:' || $1, 7621846213719048
       ))`, [providerAccountId],
    ).catch(() => undefined);
    if (pending.length > 0) results = await Promise.allSettled(pending);
    blocker.release();
    for (const client of clients) {
      await client.query('RESET ROLE').catch(() => undefined);
      client.release();
    }
  }
  assert.equal(waiters, 2, 'competing binding calls were not serialized');
  assert.equal(results.filter(({ status }) => status === 'fulfilled').length, 1);
  const loser = results.find(({ status }) => status === 'rejected');
  assert.equal(loser?.reason?.code, 'P0001');
  assert.equal(loser?.reason?.message, 'STRIPE_BINDING_CONFLICT');
}

async function providerAuditLaneConflictOracle({ cluster }) {
  const stripePool = new Pool({
    ...appPoolConfig(cluster, 2), user: 'roomscan_stripe_ingress_runtime', max: 2,
  });
  const emailPool = new Pool({
    ...appPoolConfig(cluster, 2), user: 'roomscan_email_delivery_runtime', max: 2,
  });
  const apiPool = new Pool({
    ...appPoolConfig(cluster, 1), user: 'roomscan_api_runtime', max: 1,
  });
  const acceptSql = `SELECT roomscan.accept_provider_audit_event(
    $1, $2, $3, $4, $5
  ) AS inserted`;
  try {
    assert.equal((await stripePool.query(acceptSql, [
      'paud_mut_stripeaudit07', 'stripe', 'stripe.webhook.accepted',
      'evt_mutprovideraudit07', now,
    ])).rows[0].inserted, true);
    let exactRetry;
    await assert.doesNotReject(async () => {
      exactRetry = (await stripePool.query(acceptSql, [
        'paud_mut_stripeaudit07', 'stripe', 'stripe.webhook.accepted',
        'evt_mutprovideraudit07', new Date(now.getTime() + 1_000),
      ])).rows[0];
    }, 'provider-audit exact retry incorrectly depended on occurred-at');
    assert.equal(exactRetry.inserted, false);
    await expectDatabaseError(
      () => stripePool.query(acceptSql, [
        'paud_mut_stripeaudit07', 'stripe', 'stripe.webhook.accepted',
        'evt_mutprovideraudit08', now,
      ]),
      'P0001', 'PROVIDER_AUDIT_ID_REUSED',
    );
    await expectDatabaseError(
      () => emailPool.query(acceptSql, [
        'paud_mut_emailcross007', 'stripe', 'stripe.webhook.accepted',
        'evt_mutemailcross007', now,
      ]),
      '22023', 'INVALID_PROVIDER_AUDIT_EVENT',
    );
    await expectDatabaseError(
      () => apiPool.query(acceptSql, [
        'paud_mut_apidenied0007', 'email', 'email.delivery.accepted',
        'magic-mut-api-denied', now,
      ]),
      '42501',
    );
  } finally {
    await Promise.all([stripePool.end(), emailPool.end(), apiPool.end()]);
  }
}

async function stripeProviderModeStorageOracle({ bootstrapPool }) {
  await bootstrapPool.query(
    `INSERT INTO roomscan.stripe_provider_accounts(provider_account_id, account_mode)
     VALUES ('acct_mutStorageMode', 'platform')`,
  );
  await expectDatabaseError(
    () => bootstrapPool.query(
      `INSERT INTO roomscan.stripe_billing_bindings(
         workspace_id, account_mode, provider_account_id,
         billing_customer_id, subscription_id, bound_at
       ) VALUES (
         $1, 'connected', 'acct_mutStorageMode',
         'cus_mutStorageMode', 'sub_mutStorageMode', $2
       )`,
      [ids.workspaceA, now],
    ),
    '23503',
  );
}

async function providerAuditIsolationOracle({ cluster, bootstrapPool }) {
  const pool = new Pool({
    ...appPoolConfig(cluster, 2), user: 'roomscan_stripe_ingress_runtime', max: 2,
  });
  const [writer, waiter] = await Promise.all([pool.connect(), pool.connect()]);
  const acceptSql = `SELECT roomscan.accept_provider_audit_event(
    'paud_mut_isolation_0007', 'stripe', 'stripe.webhook.accepted',
    'evt_mutIsolation0007', $1
  ) AS inserted`;
  try {
    await waiter.query(
      `SELECT pg_catalog.set_config('application_name', 'rss-mut-provider-audit', false)`,
    );
    await Promise.all([writer, waiter].map((client) =>
      client.query('BEGIN ISOLATION LEVEL REPEATABLE READ')));
    await Promise.all([writer, waiter].map((client) =>
      client.query('SELECT pg_catalog.txid_current_snapshot()')));
    assert.equal((await writer.query(acceptSql, [now])).rows[0].inserted, true);
    const pending = waiter.query(acceptSql, [new Date(now.getTime() + 1_000)])
      .then((value) => ({ value }), (error) => ({ error }));
    assert.equal(await waitForMutationLock(bootstrapPool, 'rss-mut-provider-audit'), 'advisory');
    await writer.query('COMMIT');
    const outcome = await pending;
    assert.equal(outcome.error?.code, '40001');
    assert.equal(outcome.error?.message, 'PROVIDER_AUDIT_RETRY_REQUIRED');
    await waiter.query('ROLLBACK');
    assert.equal((await writer.query(acceptSql, [
      new Date(now.getTime() + 2_000),
    ])).rows[0].inserted, false);
  } finally {
    await writer.query('ROLLBACK').catch(() => undefined);
    await waiter.query('ROLLBACK').catch(() => undefined);
    writer.release();
    waiter.release();
    await pool.end();
  }
}

async function stripeReceiptIsolationOracle({ cluster, bootstrapPool }) {
  await withRole(bootstrapPool, 'roomscan_operator', async () => {
    await bootstrapPool.query(
      `SELECT roomscan.bind_stripe_account(
         $1, 'platform', 'acct_mutReceiptIso', 'cus_mutReceiptIso',
         'sub_mutReceiptIso', $2
       )`,
      [ids.workspaceA, now],
    );
  });
  const pool = new Pool({
    ...appPoolConfig(cluster, 2), user: 'roomscan_stripe_ingress_runtime', max: 2,
  });
  const [writer, waiter] = await Promise.all([pool.connect(), pool.connect()]);
  const args = [
    'platform', 'acct_mutReceiptIso', 'cus_mutReceiptIso', 'sub_mutReceiptIso',
    'evt_mutReceiptIso', 'customer.subscription.updated', 'sub_mutReceiptIso',
    hash32('mut-receipt-isolation'), now, now,
  ];
  const acceptSql = `SELECT * FROM roomscan.accept_stripe_event_v2(
    $1, $2, $3, $4, $5, $6, $7, $8, $9, $10
  )`;
  try {
    await waiter.query(
      `SELECT pg_catalog.set_config('application_name', 'rss-mut-stripe-receipt', false)`,
    );
    await Promise.all([writer, waiter].map((client) =>
      client.query('BEGIN ISOLATION LEVEL REPEATABLE READ')));
    await Promise.all([writer, waiter].map((client) =>
      client.query('SELECT pg_catalog.txid_current_snapshot()')));
    assert.equal((await writer.query(acceptSql, args)).rows[0].status, 'accepted');
    const pending = waiter.query(acceptSql, [
      ...args.slice(0, 9), new Date(now.getTime() + 1_000),
    ]).then((value) => ({ value }), (error) => ({ error }));
    assert.equal(await waitForMutationLock(bootstrapPool, 'rss-mut-stripe-receipt'), 'advisory');
    await writer.query('COMMIT');
    const outcome = await pending;
    assert.equal(outcome.error?.code, '40001');
    assert.equal(outcome.error?.message, 'STRIPE_EVENT_RETRY_REQUIRED');
    await waiter.query('ROLLBACK');
    assert.equal((await writer.query(acceptSql, [
      ...args.slice(0, 9), new Date(now.getTime() + 2_000),
    ])).rows[0].status, 'duplicate');
  } finally {
    await writer.query('ROLLBACK').catch(() => undefined);
    await waiter.query('ROLLBACK').catch(() => undefined);
    writer.release();
    waiter.release();
    await pool.end();
  }
}

async function appleIdentityIsolationOracle({ cluster, bootstrapPool }) {
  await setProfessionalSignInFlag(bootstrapPool, true);
  const proofs = [hash32('mut-apple-identity-a'), hash32('mut-apple-identity-b')];
  for (let index = 0; index < 2; index += 1) {
    const marker = index === 0 ? 'a' : 'b';
    const attemptId = `apple_mut_identity_${marker}_0007`;
    await bootstrapPool.query(
      `INSERT INTO roomscan.apple_auth_attempts (
         id, state_hash, nonce_hash, code_challenge, expected_client_id,
         redirect_uri, created_at, expires_at, policy_version, purpose,
         state, claimed_at
       ) VALUES (
         $1, $2, $3, 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
         'com.roomscan.test', 'https://example.invalid/apple/callback',
         $4, $4::timestamptz + interval '5 minutes', 'apple-v1', 'sign-in',
         'claimed', $4
       )`,
      [attemptId, hash32(`mut-apple-state-${marker}`),
        hash32(`mut-apple-nonce-${marker}`), now],
    );
    await bootstrapPool.query(
      `INSERT INTO roomscan.apple_bridge_proofs (
         token_hash, issuer, subject, attempt_id, purpose,
         issued_at, expires_at, policy_version
       ) VALUES (
         $1, 'https://appleid.apple.com', 'mut-apple-shared-subject-0007',
         $2, 'sign-in', $3, $3::timestamptz + interval '5 minutes', 'apple-v1'
       )`,
      [proofs[index], attemptId, now],
    );
  }
  const pool = new Pool({
    ...appPoolConfig(cluster, 2), user: 'roomscan_auth_challenge_runtime', max: 2,
  });
  const [writer, waiter] = await Promise.all([pool.connect(), pool.connect()]);
  const issueSql = `SELECT * FROM roomscan.consume_apple_bridge_and_issue_session(
    $1, $2, $3, $4, $5, $5, $6, $7, $8, 'session-v1'
  )`;
  const args = (index) => [
    proofs[index], `fam_mut_apple_identity_${index}_0007`,
    hash32(`mut-apple-access-${index}`), hash32(`mut-apple-refresh-${index}`), now,
    new Date(now.getTime() + 60_000), new Date(now.getTime() + 300_000),
    new Date(now.getTime() + 600_000),
  ];
  let winner;
  try {
    await waiter.query(
      `SELECT pg_catalog.set_config('application_name', 'rss-mut-apple-identity', false)`,
    );
    await Promise.all([writer, waiter].map((client) =>
      client.query('BEGIN ISOLATION LEVEL REPEATABLE READ')));
    await Promise.all([writer, waiter].map((client) =>
      client.query('SELECT pg_catalog.txid_current_snapshot()')));
    winner = (await writer.query(issueSql, args(0))).rows[0];
    assert.equal(winner.status, 'issued');
    const pending = waiter.query(issueSql, args(1))
      .then((value) => ({ value }), (error) => ({ error }));
    assert.equal(await waitForMutationLock(bootstrapPool, 'rss-mut-apple-identity'), 'advisory');
    await writer.query('COMMIT');
    const outcome = await pending;
    assert.equal(outcome.error?.code, '40001');
    assert.equal(outcome.error?.message, 'APPLE_IDENTITY_RETRY_REQUIRED');
    await waiter.query('ROLLBACK');
    const retried = (await writer.query(issueSql, args(1))).rows[0];
    assert.equal(retried.status, 'issued');
    assert.equal(retried.principal_id, winner.principal_id);
  } finally {
    await writer.query('ROLLBACK').catch(() => undefined);
    await waiter.query('ROLLBACK').catch(() => undefined);
    writer.release();
    waiter.release();
    await pool.end();
  }
}

async function invitationIdentityIsolationOracle({ cluster, bootstrapPool }) {
  const targetPrincipal = '69000000-0000-4000-8000-000000000010';
  await bootstrapPool.query(
    `INSERT INTO roomscan.principals(id, normalized_email)
     VALUES ($1, 'mut-invitation-target@example.invalid')`,
    [targetPrincipal],
  );
  await setHostedFlags(bootstrapPool, ids.workspaceA, true);
  await activateQuota(bootstrapPool);
  const actor = await insertAccess(bootstrapPool, { label: 'invitation-race-actor' });
  const target = await insertUnscopedAccess(bootstrapPool, {
    principalId: targetPrincipal, label: 'invitation-race-target',
  });
  const pool = new Pool({
    ...appPoolConfig(cluster, 4), user: 'roomscan_api_runtime', max: 4,
  });
  const tokens = [hash32('mut-invitation-a'), hash32('mut-invitation-b')];
  const createSql = `SELECT * FROM roomscan.create_invitation_v2(
    $1, $2, $3, $4, 'mut-invitation@example.invalid', 'editor',
    $5, 1, 1, $6
  )`;
  for (let index = 0; index < 2; index += 1) {
    const marker = index === 0 ? 'a' : 'b';
    assert.equal((await pool.query(createSql, [
      actor.accessHash, now, `inv_mut_identity_race_${marker}_0007`, tokens[index],
      new Date(now.getTime() + 60_000), `aud_mut_invite_race_${marker}_0007`,
    ])).rows[0].state, 'active');
  }
  const acceptSql = `SELECT * FROM roomscan.accept_invitation_v2(
    $1, $2, $3, 1, 1, 1, $4
  )`;
  const [writer, waiter] = await Promise.all([pool.connect(), pool.connect()]);
  try {
    await waiter.query(
      `SELECT pg_catalog.set_config('application_name', 'rss-mut-invitation-identity', false)`,
    );
    await Promise.all([writer, waiter].map((client) =>
      client.query('BEGIN ISOLATION LEVEL REPEATABLE READ')));
    await Promise.all([writer, waiter].map((client) =>
      client.query('SELECT pg_catalog.txid_current_snapshot()')));
    assert.equal((await writer.query(acceptSql, [
      target.accessHash, now, tokens[0], 'aud_mut_accept_race_a_0007',
    ])).rows[0].status, 'accepted');
    const pending = waiter.query(acceptSql, [
      target.accessHash, now, tokens[1], 'aud_mut_accept_race_b_0007',
    ]).then((value) => ({ value }), (error) => ({ error }));
    assert.equal(await waitForMutationLock(
      bootstrapPool, 'rss-mut-invitation-identity',
    ), 'advisory');
    await writer.query('COMMIT');
    const outcome = await pending;
    assert.equal(outcome.error?.code, '40001');
    assert.equal(outcome.error?.message, 'INVITATION_ACCEPT_RETRY_REQUIRED');
    await waiter.query('ROLLBACK');
    assert.equal((await writer.query(acceptSql, [
      target.accessHash, now, tokens[1], 'aud_mut_accept_race_b_0007',
    ])).rows[0].status, 'already_member');
    assert.equal((await bootstrapPool.query(
      `SELECT state FROM roomscan.invitations WHERE token_hash = $1`,
      [tokens[1]],
    )).rows[0].state, 'active');
  } finally {
    await writer.query('ROLLBACK').catch(() => undefined);
    await waiter.query('ROLLBACK').catch(() => undefined);
    writer.release();
    waiter.release();
    await pool.end();
  }
}

async function identityMutationIsolationOracle({ cluster, bootstrapPool }) {
  const principals = [
    '69000000-0000-4000-8000-000000000021',
    '69000000-0000-4000-8000-000000000022',
  ];
  await bootstrapPool.query(
    `INSERT INTO roomscan.principals(id, normalized_email)
     VALUES ($1, 'mut-identity-a@example.invalid'),
            ($2, 'mut-identity-b@example.invalid')`,
    principals,
  );
  await setProfessionalSignInFlag(bootstrapPool, true);
  const candidates = [];
  for (let index = 0; index < 2; index += 1) {
    const access = await insertUnscopedAccess(bootstrapPool, {
      principalId: principals[index], label: `identity-race-${index}`,
    });
    const proofHash = hash32(`mut-identity-proof-${index}`);
    await bootstrapPool.query(
      `INSERT INTO roomscan.candidate_identity_proofs (
         token_hash, issuer, subject, purpose, initiating_principal_id,
         initiating_family_id, authenticated_at, issued_at, expires_at,
         policy_version
       ) VALUES (
         $1, 'https://appleid.apple.com', 'mut-shared-identity-0007',
         'link-identity', $2, $3, $4, $4,
         $4::timestamptz + interval '5 minutes', 'identity-v1'
       )`,
      [proofHash, principals[index], access.familyId, now],
    );
    candidates.push({ ...access, proofHash, principalId: principals[index] });
  }
  const pool = new Pool({
    ...appPoolConfig(cluster, 4), user: 'roomscan_api_runtime', max: 4,
  });
  const mutateSql = `SELECT * FROM roomscan.mutate_identity_v2(
    $1, $2, $3, 'link-identity', true, $4, $5,
    'id_mut_identity_race_0007', 'identity-v1'
  )`;
  const args = (index) => [
    candidates[index].accessHash, now, candidates[index].proofHash,
    `aud_mut_identity_race_${index}_0007`,
    `notification_mut_identity_race_${index}_0007`,
  ];
  const [writer, waiter] = await Promise.all([pool.connect(), pool.connect()]);
  try {
    await waiter.query(
      `SELECT pg_catalog.set_config('application_name', 'rss-mut-identity-mutation', false)`,
    );
    await Promise.all([writer, waiter].map((client) =>
      client.query('BEGIN ISOLATION LEVEL REPEATABLE READ')));
    await Promise.all([writer, waiter].map((client) =>
      client.query('SELECT pg_catalog.txid_current_snapshot()')));
    assert.equal((await writer.query(mutateSql, args(0))).rows[0].status, 'linked');
    const pending = waiter.query(mutateSql, args(1))
      .then((value) => ({ value }), (error) => ({ error }));
    assert.equal(await waitForMutationLock(
      bootstrapPool, 'rss-mut-identity-mutation',
    ), 'advisory');
    await writer.query('COMMIT');
    const outcome = await pending;
    assert.equal(outcome.error?.code, '40001');
    assert.equal(outcome.error?.message, 'IDENTITY_MUTATION_RETRY_REQUIRED');
    await waiter.query('ROLLBACK');
    assert.equal((await writer.query(mutateSql, args(1))).rows[0].status, 'candidate_owned');
    assert.equal((await bootstrapPool.query(
      `SELECT state FROM roomscan.candidate_identity_proofs WHERE token_hash = $1`,
      [candidates[1].proofHash],
    )).rows[0].state, 'active');
  } finally {
    await writer.query('ROLLBACK').catch(() => undefined);
    await waiter.query('ROLLBACK').catch(() => undefined);
    writer.release();
    waiter.release();
    await pool.end();
  }
}

const mutations = [
  {
    name: 'shared roomscan_app LOGIN re-enabled',
    transform: (source) => replaceOnce(
      source,
      `ALTER ROLE roomscan_app
  NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;`,
      `ALTER ROLE roomscan_app
  LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;`,
      'roomscan_app LOGIN',
    ),
    oracle: loginRoleOracle,
  },
  {
    name: 'raw principal UUID capability granted to API',
    transform: (source) => `${source}\nGRANT EXECUTE ON FUNCTION roomscan.bump_principal_authentication_epoch(uuid) TO roomscan_api_runtime;\n`,
    oracle: rawTargetOracle,
  },
  {
    name: 'direct principal UPDATE granted to API',
    transform: (source) => `${source}\nGRANT SELECT, UPDATE ON roomscan.principals TO roomscan_api_runtime;\n`,
    oracle: directDmlOracle,
  },
  {
    name: 'refresh reducer fixed search_path removed',
    transform: (source) => mutateFunction(source, 'rotate_session_from_refresh', (block) => replaceOnce(
      block,
      'SET search_path = pg_catalog, pg_temp\n',
      '',
      'refresh search_path',
    )),
    oracle: searchPathOracle,
  },
  {
    name: 'refresh reducer granted to PUBLIC',
    transform: (source) => `${source}\nGRANT EXECUTE ON FUNCTION roomscan.rotate_session_from_refresh(bytea, bytea, bytea, timestamptz, timestamptz, timestamptz) TO PUBLIC;\n`,
    oracle: publicExecuteOracle,
  },
  {
    name: 'member_slots FORCE RLS removed',
    transform: (source) => replaceOnce(
      source,
      'ALTER TABLE roomscan.member_slots FORCE ROW LEVEL SECURITY;',
      '-- MUTANT: member_slots FORCE ROW LEVEL SECURITY removed',
      'member_slots FORCE RLS',
    ),
    oracle: forceRlsOracle,
  },
  {
    name: 'refresh reducer granted to Cognito challenge lane',
    transform: (source) => `${source}\nGRANT EXECUTE ON FUNCTION roomscan.rotate_session_from_refresh(bytea, bytea, bytea, timestamptz, timestamptz, timestamptz) TO roomscan_auth_challenge_runtime;\n`,
    oracle: refreshLaneOracle,
  },
  {
    name: 'required access-digest NULL guard removed',
    transform: (source) => mutateFunction(source, 'logout_all_from_access', (block) => replaceOnce(
      block,
      '  IF access_token_hash IS NULL OR authoritative_time IS NULL\n',
      '  IF authoritative_time IS NULL -- MUTANT: access hash NULL guard removed\n',
      'logout-all NULL guard',
    )),
    oracle: nullGuardOracle,
  },
  {
    name: 'last Owner guard neutralized',
    transform: (source) => mutateFunction(source, 'mutate_membership_v2', (block) => replaceOnce(
      block,
      `    AND NOT EXISTS (
      SELECT 1 FROM roomscan.memberships AS owner_candidate
      WHERE owner_candidate.workspace_id = context_row.workspace_id
        AND owner_candidate.principal_id <> target_principal_id
        AND owner_candidate.role = 'owner' AND owner_candidate.state = 'active'
    ) THEN RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'LAST_OWNER_REQUIRED'; END IF;`,
      `    AND false -- MUTANT: last Owner guard neutralized
    THEN RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'LAST_OWNER_REQUIRED'; END IF;`,
      'last Owner guard',
    )),
    additionalMutations: [{
      file: '0002_tenant_core.up.sql',
      before: '  IF removing_owner THEN\n',
      after: '  IF false THEN -- MUTANT: trigger last Owner guard neutralized\n',
      label: 'trigger last Owner guard',
    }],
    oracle: lastOwnerOracle,
  },
  {
    name: 'hosted flag literal-TRUE checks removed',
    transform: (source) => mutateFunction(source, 'hosted_mutation_grant_matches', (block) => {
      const anchor = '        AND global_flag.enabled IS TRUE\n';
      const workspaceAnchor = '        AND workspace_flag.enabled IS TRUE\n';
      assert.equal(block.split(anchor).length - 1, 2, 'global literal-TRUE anchors drifted');
      assert.equal(block.split(workspaceAnchor).length - 1, 2, 'workspace literal-TRUE anchors drifted');
      return block.replaceAll(anchor, '').replaceAll(workspaceAnchor, '');
    }),
    oracle: flagLiteralTrueOracle,
  },
  {
    name: 'hosted flag version checks removed',
    transform: (source) => mutateFunction(source, 'hosted_mutation_grant_matches', (block) => {
      const globalAnchor = '        AND global_flag.version = hosted_global_version\n';
      const workspaceAnchor = '        AND workspace_flag.version = hosted_workspace_version\n';
      assert.equal(block.split(globalAnchor).length - 1, 1, 'hosted global version anchor drifted');
      assert.equal(block.split(workspaceAnchor).length - 1, 1, 'hosted workspace version anchor drifted');
      return block.replace(globalAnchor, '').replace(workspaceAnchor, '');
    }),
    oracle: flagVersionOracle,
  },
  {
    name: 'quota period identity check removed',
    transform: (source) => mutateFunction(source, 'reserve_quota_v2', (block) => replaceOnce(
      block,
      `    OR requested_period_key IS DISTINCT FROM (CASE WHEN requested_metric = 'portal_bytes'
      THEN active_policy.portal_period_key ELSE 'roomscan-period-v1:lifetime' END) THEN`,
      '    OR false THEN -- MUTANT: quota period identity ignored',
      'quota period identity',
    )),
    oracle: periodIdentityOracle,
  },
  {
    name: 'quota overview active portal period replaced with lifetime',
    transform: (source) => mutateFunction(source, 'read_quota_overview_v2', (block) => replaceOnce(
      block,
      '        AND usage.period_key = active_policy.portal_period_key)',
      `        AND usage.period_key = 'roomscan-period-v1:lifetime')
        -- MUTANT: active portal period ignored`,
      'quota overview active portal period',
    )),
    oracle: quotaOverviewPeriodOracle,
  },
  {
    name: 'quota overview literal-TRUE hosted guards removed',
    transform: (source) => mutateFunction(source, 'read_quota_overview_v2', (block) => {
      let mutated = replaceOnce(
        block,
        "      AND global_flag.enabled IS TRUE\n",
        '      -- MUTANT: global literal-TRUE guard removed\n',
        'quota overview global literal-TRUE guard',
      );
      mutated = replaceOnce(
        mutated,
        "      AND workspace_flag.enabled IS TRUE\n",
        '      -- MUTANT: workspace literal-TRUE guard removed\n',
        'quota overview workspace literal-TRUE guard',
      );
      return mutated;
    }),
    oracle: quotaOverviewHostedFlagOracle,
  },
  {
    name: 'email claim-next capability granted to API lane',
    transform: (source) => `${source}\nGRANT EXECUTE ON FUNCTION roomscan.claim_next_magic_delivery(text, timestamptz, timestamptz) TO roomscan_api_runtime;\n`,
    oracle: emailDeliveryLaneOracle,
  },
  {
    name: 'email claim-next SKIP LOCKED removed',
    transform: (source) => mutateFunction(source, 'claim_next_magic_delivery', (block) => replaceOnce(
      block,
      '  FOR UPDATE OF delivery SKIP LOCKED\n',
      '  FOR UPDATE OF delivery -- MUTANT: SKIP LOCKED removed\n',
      'email claim-next SKIP LOCKED',
    )),
    oracle: emailClaimNextSkipLockedOracle,
  },
  {
    name: 'email claim-next professional sign-in gate removed',
    transform: (source) => mutateFunction(source, 'claim_next_magic_delivery', (block) => replaceOnce(
      block,
      '      AND sign_in_flag.enabled IS TRUE\n',
      '      -- MUTANT: professional sign-in literal-TRUE gate removed\n',
      'email claim-next sign-in gate',
    )),
    oracle: emailClaimNextSignInGateOracle,
  },
  {
    name: 'email pre-send professional sign-in gate removed',
    transform: (source) => mutateFunction(source, 'validate_magic_delivery', (block) => replaceOnce(
      block,
      '   AND sign_in_flag.enabled IS TRUE\n',
      '   -- MUTANT: pre-send sign-in gate removed\n',
      'email validate sign-in gate',
    )),
    oracle: emailValidateSignInGateOracle,
  },
  {
    name: 'email pre-send active-link guard removed',
    transform: (source) => mutateFunction(source, 'validate_magic_delivery', (block) => replaceOnce(
      block,
      "    AND link.state = 'active'\n",
      '    -- MUTANT: active-link guard removed\n',
      'email validate link-state guard',
    )),
    oracle: emailValidateLinkStateOracle,
  },
  {
    name: 'workspace read server-derived scope removed',
    transform: (source) => mutateFunction(source, 'read_workspace_authorization_state', (block) => replaceOnce(
      block,
      '  WHERE current_workspace.id = context_row.workspace_id;\n',
      '  WHERE true; -- MUTANT: server-derived workspace scope removed\n',
      'workspace read scope',
    )),
    oracle: workspaceReadScopeOracle,
  },
  {
    name: 'Stripe claim literal-TRUE hosted gates removed',
    transform: (source) => mutateFunction(source, 'claim_stripe_reconciliation_v2', (block) => {
      let mutated = replaceOnce(
        block,
        '     AND global_flag.enabled IS TRUE\n',
        '     -- MUTANT: Stripe global hosted gate removed\n',
        'Stripe claim global hosted gate',
      );
      mutated = replaceOnce(
        mutated,
        '     AND workspace_flag.enabled IS TRUE\n',
        '     -- MUTANT: Stripe workspace hosted gate removed\n',
        'Stripe claim workspace hosted gate',
      );
      return mutated;
    }),
    oracle: stripeClaimHostedGateOracle,
  },
  {
    name: 'quota reservation expiry check removed',
    transform: (source) => mutateFunction(source, 'finalize_quota_v2', (block) => replaceOnce(
      block,
      '  IF amount_actually_used > reservation.requested_amount OR reservation.expires_at <= authoritative_time THEN',
      '  IF amount_actually_used > reservation.requested_amount THEN -- MUTANT: expiry ignored',
      'quota reservation expiry',
    )),
    oracle: reservationExpiryOracle,
  },
  {
    name: 'professional sign-in default-off guard removed',
    transform: (source) => mutateFunction(source, 'issue_magic_challenge_v2', (block) => replaceOnce(
      block,
      '  IF NOT EXISTS (\n',
      '  IF false AND NOT EXISTS ( -- MUTANT: default-off guard disabled\n',
      'magic default-off guard',
    )),
    oracle: defaultOffSignInOracle,
  },
  {
    name: 'Stripe lease ownership check removed',
    transform: (source) => mutateFunction(source, 'complete_stripe_reconciliation_v2', (block) => replaceOnce(
      block,
      '  IF NOT FOUND OR outbox.lease_id IS DISTINCT FROM requested_lease_id\n',
      '  IF NOT FOUND OR false -- MUTANT: lease identity ignored\n',
      'Stripe lease ownership',
    )),
    oracle: stripeLeaseOracle,
  },
  {
    name: 'Stripe retry identity incorrectly includes server receive time',
    transform: (source) => mutateFunction(source, 'accept_stripe_event_v2', (block) => replaceOnce(
      block,
      '      OR existing.provider_occurred_at IS DISTINCT FROM requested_provider_occurred_at THEN\n',
      `      OR existing.provider_occurred_at IS DISTINCT FROM requested_provider_occurred_at
      OR existing.received_at IS DISTINCT FROM requested_received_at THEN
`,
      'Stripe server receive-time retry identity',
    )),
    oracle: stripeReceivedAtRetryOracle,
  },
  {
    name: 'Stripe event ID function canonical guard removed',
    transform: (source) => mutateFunction(source, 'accept_stripe_event_v2', (block) => replaceOnce(
      block,
      "    OR requested_event_id !~ '^evt_[A-Za-z0-9]{6,255}$'\n",
      '    OR length(requested_event_id) NOT BETWEEN 1 AND 255 -- MUTANT: canonical evt_ guard removed\n',
      'Stripe event ID function canonical guard',
    )),
    oracle: stripeEventIdFunctionGuardOracle,
  },
  {
    name: 'Stripe event ID storage canonical constraint removed',
    transform: (source) => replaceOnce(
      source,
      "  event_id text NOT NULL CHECK (event_id ~ '^evt_[A-Za-z0-9]{6,255}$'),\n",
      '  event_id text NOT NULL CHECK (length(event_id) BETWEEN 1 AND 255), -- MUTANT: canonical evt_ storage constraint removed\n',
      'Stripe event ID storage canonical constraint',
    ),
    oracle: stripeEventIdStorageConstraintOracle,
  },
  {
    name: 'Stripe original hosted grant check removed',
    transform: (source) => mutateFunction(source, 'complete_stripe_reconciliation_v2', (block) => replaceOnce(
      block,
      '  IF NOT roomscan.hosted_mutation_grant_matches(\n',
      '  IF false AND roomscan.hosted_mutation_grant_matches( -- MUTANT: original grant ignored\n',
      'Stripe original grant',
    )),
    oracle: stripeOriginalGrantOracle,
  },
  {
    name: 'Apple verified-result one-winner marker removed',
    transform: (source) => mutateFunction(source, 'accept_apple_verified_result_v2', (block) => {
      let mutated = replaceOnce(
        block,
        '    OR attempt.result_recorded_at IS NOT NULL THEN\n',
        '    OR false THEN -- MUTANT: recorded result accepted again\n',
        'Apple result precheck',
      );
      mutated = replaceOnce(
        mutated,
        '  WHERE target.id = attempt.id AND target.result_recorded_at IS NULL;\n',
        '  WHERE target.id = attempt.id; -- MUTANT: result marker CAS removed\n',
        'Apple result marker CAS',
      );
      return mutated;
    }),
    oracle: appleResultReplayOracle,
  },
  {
    name: 'magic v3 redeemed replay handoff expiry guard removed',
    transform: (source) => mutateFunction(source, 'redeem_magic_completion_v3', (block) => replaceOnce(
      block,
      '  IF handoff.expires_at <= authoritative_time THEN\n',
      '  IF false THEN -- MUTANT: redeemed handoff replay expiry ignored\n',
      'magic v3 replay handoff expiry',
    )),
    oracle: magicReplayExpiryOracle,
  },
  {
    name: 'magic v3 stateless session replay requires recomputed expiries',
    transform: (source) => mutateFunction(source, 'redeem_magic_completion_v3', (block) => replaceOnce(
      block,
      '        AND family.policy_version IS NOT DISTINCT FROM requested_session_policy_version\n',
      `        AND family.policy_version IS NOT DISTINCT FROM requested_session_policy_version
        AND family.inactivity_expires_at IS NOT DISTINCT FROM requested_inactivity_expires_at
        AND access.expires_at IS NOT DISTINCT FROM requested_access_expires_at
        -- MUTANT: stateless retry depends on recomputed timestamps
`,
      'magic v3 session replay timestamp identity',
    )),
    oracle: magicSessionStatelessReplayOracle,
  },
  {
    name: 'magic v3 stateless receipt replay requires recomputed expiry',
    transform: (source) => mutateFunction(source, 'redeem_magic_completion_v3', (block) => replaceOnce(
      block,
      "      AND receipt.purpose = expected_purpose AND receipt.issuer = 'email'\n",
      `      AND receipt.purpose = expected_purpose AND receipt.issuer = 'email'
      AND receipt.expires_at IS NOT DISTINCT FROM requested_receipt_expires_at
      -- MUTANT: stateless receipt retry depends on recomputed expiry
`,
      'magic v3 receipt replay timestamp identity',
    )),
    oracle: magicReceiptStatelessReplayOracle,
  },
  {
    name: 'magic v3 session family effective expiry guard removed',
    transform: (source) => mutateFunction(source, 'redeem_magic_completion_v3', (block) => {
      const anchor = '        AND family.inactivity_expires_at > authoritative_time\n';
      assert.equal(block.split(anchor).length - 1, 1,
        'magic v3 family expiry anchors drifted');
      return block.replace(anchor,
        '        -- MUTANT: session family effective expiry ignored\n');
    }),
    oracle: magicFamilyReplayValidityOracle,
  },
  {
    name: 'magic v3 receipt effective expiry guard removed',
    transform: (source) => mutateFunction(source, 'redeem_magic_completion_v3', (block) => replaceOnce(
      block,
      '      AND receipt.expires_at > authoritative_time\n',
      '      -- MUTANT: receipt effective expiry ignored\n',
      'magic v3 receipt effective expiry',
    )),
    oracle: magicReceiptReplayValidityOracle,
  },
  {
    name: 'magic v3 network failure advisory serialization removed',
    transform: (source) => mutateFunction(source, 'redeem_magic_completion_v3', (block) => replaceOnce(
      block,
      `  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'magic-redeem-network:'
      || pg_catalog.encode(requested_network_hash, 'hex'),
    7621846213719046
  ));
`,
      '  -- MUTANT: network failure count and insert are not serialized\n',
      'magic v3 network advisory lock',
    )),
    oracle: magicNetworkFailureSerializationOracle,
  },
  {
    name: 'email provider-audit delivery outcomes removed',
    transform: (source) => mutateFunction(source, 'accept_provider_audit_event', (block) => {
      const anchor = "      'email.delivery.accepted', 'email.delivery.failed',\n";
      assert.equal(block.split(anchor).length - 1, 1,
        'email delivery audit outcome anchors drifted');
      return block.replace(anchor,
        '      -- MUTANT: email delivery outcome events removed\n');
    }),
    oracle: emailDeliveryAuditOutcomeOracle,
  },
  {
    name: 'Stripe provider-account mode composite foreign key removed',
    transform: (source) => replaceOnce(
      source,
      `  FOREIGN KEY (provider_account_id, account_mode)
    REFERENCES roomscan.stripe_provider_accounts(provider_account_id, account_mode)
    ON DELETE RESTRICT
`,
      '  CHECK (true) -- MUTANT: provider account mode registry is not storage-enforced\n',
      'Stripe provider-account mode composite foreign key',
    ),
    oracle: stripeProviderModeStorageOracle,
  },
  {
    name: 'Stripe provider-account conflict-aware insert removed',
    transform: (source) => mutateFunction(source, 'bind_stripe_account', (block) => replaceOnce(
      block,
      '    ON CONFLICT (provider_account_id) DO NOTHING\n',
      '    -- MUTANT: provider-account uniqueness leaks through plain INSERT\n',
      'Stripe provider-account conflict-aware insert',
    )),
    oracle: stripeBindingSerializationOracle,
  },
  {
    name: 'provider audit API lane grant and session binding widened',
    transform: (source) => {
      let mutated = mutateFunction(source, 'accept_provider_audit_event', (block) => replaceOnce(
        block,
        "  ELSIF session_user = 'roomscan_email_delivery_runtime' THEN\n",
        "  ELSIF session_user IN ('roomscan_email_delivery_runtime', 'roomscan_api_runtime') THEN\n",
        'provider audit session-user lane guard',
      ));
      mutated = replaceOnce(
        mutated,
        `GRANT EXECUTE ON FUNCTION roomscan.accept_provider_audit_event(text, text, text, text, timestamptz)
  TO roomscan_stripe_ingress_runtime, roomscan_email_delivery_runtime;
`,
        `GRANT EXECUTE ON FUNCTION roomscan.accept_provider_audit_event(text, text, text, text, timestamptz)
  TO roomscan_stripe_ingress_runtime, roomscan_email_delivery_runtime, roomscan_api_runtime;
`,
        'provider audit exact runtime grants',
      );
      return mutated;
    },
    oracle: providerAuditLaneConflictOracle,
  },
  {
    name: 'provider audit conflicting stable metadata accepted as duplicate',
    transform: (source) => mutateFunction(source, 'accept_provider_audit_event', (block) => replaceOnce(
      block,
      `    IF existing.provider_lane IS DISTINCT FROM requested_provider_lane
      OR existing.event_code IS DISTINCT FROM requested_event_code
      OR existing.bounded_reference IS DISTINCT FROM requested_bounded_reference THEN
      RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'PROVIDER_AUDIT_ID_REUSED';
    END IF;
`,
      '    -- MUTANT: conflicting stable metadata is hidden as an exact duplicate\n',
      'provider audit stable metadata conflict',
    )),
    oracle: providerAuditLaneConflictOracle,
  },
  {
    name: 'provider audit occurred-at incorrectly becomes retry identity',
    transform: (source) => mutateFunction(source, 'accept_provider_audit_event', (block) => replaceOnce(
      block,
      '      OR existing.bounded_reference IS DISTINCT FROM requested_bounded_reference THEN\n',
      `      OR existing.bounded_reference IS DISTINCT FROM requested_bounded_reference
      OR existing.occurred_at IS DISTINCT FROM occurred_at_time THEN
`,
      'provider audit occurred-at exclusion',
    )),
    oracle: providerAuditLaneConflictOracle,
  },
  {
    name: 'provider audit conflict-aware insert removed',
    transform: (source) => mutateFunction(source, 'accept_provider_audit_event', (block) => replaceOnce(
      block,
      '    ON CONFLICT (id) DO NOTHING\n',
      '    -- MUTANT: stale-snapshot retry leaks through plain INSERT\n',
      'provider audit conflict-aware insert',
    )),
    oracle: providerAuditIsolationOracle,
  },
  {
    name: 'Stripe receipt conflict-aware insert removed',
    transform: (source) => mutateFunction(source, 'accept_stripe_event_v2', (block) => replaceOnce(
      block,
      '    ON CONFLICT (provider_account_id, event_id) DO NOTHING\n',
      '    -- MUTANT: stale-snapshot receipt retry leaks through plain INSERT\n',
      'Stripe receipt conflict-aware insert',
    )),
    oracle: stripeReceiptIsolationOracle,
  },
  {
    name: 'Apple identity conflict-aware insert removed',
    transform: (source) => mutateFunction(source, 'consume_apple_bridge_and_issue_session', (block) => replaceOnce(
      block,
      '      ON CONFLICT (issuer, subject) DO NOTHING\n',
      '      -- MUTANT: distinct Apple proofs leak identity uniqueness\n',
      'Apple identity conflict-aware insert',
    )),
    oracle: appleIdentityIsolationOracle,
  },
  {
    name: 'invitation membership conflict-aware insert removed',
    transform: (source) => mutateFunction(source, 'accept_invitation_v2', (block) => replaceOnce(
      block,
      '      ON CONFLICT ON CONSTRAINT memberships_pkey DO NOTHING\n',
      '      -- MUTANT: distinct invitations leak membership uniqueness\n',
      'invitation membership conflict-aware insert',
    )),
    oracle: invitationIdentityIsolationOracle,
  },
  {
    name: 'identity mutation conflict-aware insert removed',
    transform: (source) => mutateFunction(source, 'mutate_identity_v2', (block) => replaceOnce(
      block,
      '    ON CONFLICT (issuer, subject) DO NOTHING\n',
      '    -- MUTANT: competing identity links leak uniqueness\n',
      'identity mutation conflict-aware insert',
    )),
    oracle: identityMutationIsolationOracle,
  },
];

let detected = 0;
let restored = 0;
const cleanupEvidence = [];

for (const mutation of mutations) {
  const prepared = await prepareMutation(mutation.transform, mutation.additionalMutations);
  try {
    let caught;
    try {
      await runOracle(prepared.migrationsDir, mutation.oracle);
    } catch (error) {
      caught = error;
      cleanupEvidence.push({ phase: 'mutant', name: mutation.name, ...error.cleanupEvidence });
    }
    assert.ok(caught, `${mutation.name} unexpectedly passed its focused oracle`);
    assert.equal(caught.code, 'ERR_ASSERTION', `${mutation.name} failed outside its intended oracle`);
    detected += 1;
    console.log(`MUTATION_0007_RED ${mutation.name}: ${caught.message}`);

    const cleanup = await runOracle(productionMigrationsDir, mutation.oracle);
    cleanupEvidence.push({ phase: 'restored', name: mutation.name, ...cleanup });
    restored += 1;
    console.log(`MUTATION_0007_RESTORE_GREEN ${mutation.name}`);
  } finally {
    await rm(prepared.root, { recursive: true, force: true });
  }
}

console.log(`MUTATION_0007_SUMMARY detected=${detected} restored=${restored} total=${mutations.length}`);
console.log(`MUTATION_0007_PROCESS_CLEANUP ${JSON.stringify(cleanupEvidence)}`);
