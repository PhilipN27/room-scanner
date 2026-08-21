import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { cp, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import { applyMigrations } from '../migrate.mjs';
import { startPostgresCluster } from './pg-cluster.mjs';

const { Pool } = pg;
const advisoryLockId = '7621846213719041';
const migrationsDir = fileURLToPath(new URL('../migrations/', import.meta.url));
const migratePath = fileURLToPath(new URL('../migrate.mjs', import.meta.url));

async function expectedLedgerRows() {
  const names = (await readdir(migrationsDir))
    .filter((name) => /^\d{4}_[a-z0-9_]+\.up\.sql$/u.test(name))
    .sort();
  return await Promise.all(names.map(async (name) => {
    const sql = await readFile(path.join(migrationsDir, name));
    return {
      version: name.slice(0, 4),
      name,
      checksum_sha256: createHash('sha256').update(sql).digest('hex'),
    };
  }));
}

async function waitForAdvisoryWaiters(client, applicationNames) {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    const count = (await client.query(
      `SELECT count(*)::int AS count
       FROM pg_stat_activity
       WHERE application_name = ANY($1::text[])
         AND wait_event_type = 'Lock'
         AND lower(wait_event) = 'advisory'`,
      [applicationNames],
    )).rows[0].count;
    if (count === applicationNames.length) {
      return count;
    }
    await delay(25);
  }
  throw new Error(`Timed out waiting for ${applicationNames.length} migration advisory-lock waiters`);
}

async function runConcurrentFreshDatabaseProof() {
  const cluster = await startPostgresCluster();
  const barrierPool = new Pool({ ...cluster.bootstrapConfig, max: 1, application_name: 'rss-migration-barrier' });
  const runnerAPool = new Pool({ ...cluster.bootstrapConfig, max: 1, application_name: 'rss-migration-runner-a' });
  const runnerBPool = new Pool({ ...cluster.bootstrapConfig, max: 1, application_name: 'rss-migration-runner-b' });
  let barrierClient;
  let barrierHeld = false;
  let pending = [];
  let waiterCount = 0;

  try {
    const migrateSource = await readFile(migratePath, 'utf8');
    const connectIndex = migrateSource.indexOf('await pool.connect()');
    const lockIndex = migrateSource.indexOf('pg_advisory_lock');
    const discoveryIndex = migrateSource.indexOf('await loadMigrations');
    const ledgerDdlIndex = migrateSource.indexOf('CREATE TABLE IF NOT EXISTS public.roomscan_schema_migrations');
    assert.ok(connectIndex >= 0 && lockIndex > connectIndex, 'migration runner must check out a dedicated client before locking');
    assert.ok(discoveryIndex > lockIndex, 'migration discovery must occur only after the session lock');
    assert.ok(ledgerDdlIndex > lockIndex, 'migration ledger DDL must occur only after the session lock');

    barrierClient = await barrierPool.connect();
    await barrierClient.query('SELECT pg_advisory_lock($1::bigint)', [advisoryLockId]);
    barrierHeld = true;

    pending = [
      applyMigrations({ pool: runnerAPool }),
      applyMigrations({ pool: runnerBPool }),
    ];
    waiterCount = await waitForAdvisoryWaiters(barrierClient, [
      'rss-migration-runner-a',
      'rss-migration-runner-b',
    ]);

    const beforeRelease = (await barrierClient.query(
      "SELECT to_regclass('public.roomscan_schema_migrations')::text AS relation",
    )).rows[0].relation;
    assert.equal(beforeRelease, null, 'a blocked runner performed ledger DDL before acquiring the lock');

    await barrierClient.query('SELECT pg_advisory_unlock($1::bigint) AS unlocked', [advisoryLockId]);
    barrierHeld = false;
    const results = await Promise.all(pending);
    pending = [];

    const expectedRows = await expectedLedgerRows();
    assert.deepEqual(
      results.map(({ applied }) => applied.length).sort((a, b) => a - b),
      [0, expectedRows.length],
    );
    assert.deepEqual(
      results.map(({ skipped }) => skipped.length).sort((a, b) => a - b),
      [0, expectedRows.length],
    );
    const appliedNames = results.flatMap(({ applied }) => applied.map(({ name }) => name)).sort();
    assert.deepEqual(appliedNames, expectedRows.map(({ name }) => name));

    const ledgerRows = (await barrierClient.query(
      `SELECT version, name, checksum_sha256
       FROM public.roomscan_schema_migrations ORDER BY version`,
    )).rows;
    assert.deepEqual(ledgerRows, expectedRows);
    const observer = results.find(({ applied }) => applied.length === 0);
    assert.deepEqual(
      observer.skipped.map(({ version, name, checksum }) => ({ version, name, checksum_sha256: checksum })),
      expectedRows,
    );

    for (const pool of [runnerAPool, runnerBPool]) {
      const retained = (await pool.query(
        'SELECT pg_advisory_unlock($1::bigint) AS unlocked',
        [advisoryLockId],
      )).rows[0].unlocked;
      assert.equal(retained, false, 'a successful runner returned a pooled session with the lock retained');
    }

    return { waiterCount, cleanup: null };
  } finally {
    if (barrierHeld) {
      await barrierClient?.query('SELECT pg_advisory_unlock($1::bigint)', [advisoryLockId]).catch(() => undefined);
    }
    if (pending.length > 0) {
      await Promise.allSettled(pending);
    }
    barrierClient?.release();
    await Promise.all([runnerAPool.end(), runnerBPool.end(), barrierPool.end()]);
    const cleanup = await cluster.stop();
    console.error(`MIGRATION_CONCURRENCY_CLEANUP ${JSON.stringify(cleanup)}`);
  }
}

async function runErrorUnlockRetryProof() {
  const cluster = await startPostgresCluster();
  const pool = new Pool({ ...cluster.bootstrapConfig, max: 1, application_name: 'rss-migration-error-retry' });
  const badRoot = await mkdtemp(path.join(tmpdir(), 'rss-migration-error-'));
  const badDir = path.join(badRoot, 'migrations');

  try {
    await cp(migrationsDir, badDir, { recursive: true });
    await writeFile(path.join(badDir, '9999_forbidden.down.sql'), 'SELECT 1;\n');
    await assert.rejects(
      () => applyMigrations({ pool, migrationsDir: badDir }),
      /Forward-only migration directory contains forbidden files/u,
    );
    assert.equal(
      (await pool.query("SELECT to_regclass('public.roomscan_schema_migrations')::text AS relation")).rows[0].relation,
      null,
      'a rejected discovery decision must not create the ledger',
    );
    assert.equal(
      (await pool.query('SELECT pg_advisory_unlock($1::bigint) AS unlocked', [advisoryLockId])).rows[0].unlocked,
      false,
      'the error path returned a pooled session with the lock retained',
    );

    const retry = await applyMigrations({ pool });
    assert.equal(retry.applied.length, (await expectedLedgerRows()).length);
    assert.equal(retry.skipped.length, 0);
    assert.equal(
      (await pool.query('SELECT pg_advisory_unlock($1::bigint) AS unlocked', [advisoryLockId])).rows[0].unlocked,
      false,
      'the retry success path returned a pooled session with the lock retained',
    );
  } finally {
    await rm(badRoot, { recursive: true, force: true });
    await pool.end();
    const cleanup = await cluster.stop();
    console.error(`MIGRATION_ERROR_RETRY_CLEANUP ${JSON.stringify(cleanup)}`);
  }
}

const concurrency = await runConcurrentFreshDatabaseProof();
await runErrorUnlockRetryProof();
console.log(`MIGRATION_CONCURRENCY_TEST_SUMMARY runners=2 migrations=${(await expectedLedgerRows()).length} barrier_waiters=${concurrency.waiterCount} discovery_error_retry=true pooled_lock_retention=false status=pass`);
