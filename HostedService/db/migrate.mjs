import { createHash } from 'node:crypto';
import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const DEFAULT_MIGRATIONS_DIR = fileURLToPath(new URL('./migrations/', import.meta.url));
const MIGRATION_NAME = /^(\d{4})_[a-z0-9_]+\.up\.sql$/u;
const ADVISORY_LOCK_ID = 7_621_846_213_719_041n;

function sha256(contents) {
  return createHash('sha256').update(contents).digest('hex');
}

async function loadMigrations(migrationsDir) {
  const names = await readdir(migrationsDir);
  const forbidden = names.filter((name) => name.endsWith('.down.sql') || /reset/iu.test(name));
  if (forbidden.length > 0) {
    throw new Error(`Forward-only migration directory contains forbidden files: ${forbidden.join(', ')}`);
  }

  const migrations = [];
  for (const name of names.sort()) {
    const match = name.match(MIGRATION_NAME);
    if (!match) {
      if (name.endsWith('.sql')) {
        throw new Error(`Unexpected SQL migration filename: ${name}`);
      }
      continue;
    }
    const sql = await readFile(path.join(migrationsDir, name), 'utf8');
    migrations.push({ version: match[1], name, sql, checksum: sha256(sql) });
  }

  if (migrations.length === 0) {
    throw new Error(`No forward migrations found in ${migrationsDir}`);
  }
  const versions = migrations.map(({ version }) => version);
  if (new Set(versions).size !== versions.length) {
    throw new Error(`Duplicate migration version: ${versions.join(', ')}`);
  }
  return migrations;
}

export async function applyMigrations({ pool, migrationsDir = DEFAULT_MIGRATIONS_DIR }) {
  if (!pool || typeof pool.connect !== 'function') {
    throw new TypeError('applyMigrations requires a PostgreSQL pool');
  }

  const client = await pool.connect();
  const applied = [];
  const skipped = [];
  let lockAcquired = false;
  let operationError;

  try {
    // This is deliberately a session lock on one checked-out client. It must
    // precede migration-directory discovery and every ledger query/DDL so two
    // cold starts cannot make decisions from different snapshots.
    await client.query('SELECT pg_advisory_lock($1::bigint)', [ADVISORY_LOCK_ID.toString()]);
    lockAcquired = true;

    const migrations = await loadMigrations(migrationsDir);
    await client.query(`
      CREATE TABLE IF NOT EXISTS public.roomscan_schema_migrations (
        version text PRIMARY KEY,
        name text NOT NULL UNIQUE,
        checksum_sha256 text NOT NULL CHECK (checksum_sha256 ~ '^[0-9a-f]{64}$'),
        applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
      )
    `);
    await client.query('REVOKE ALL ON public.roomscan_schema_migrations FROM PUBLIC');

    const { rows: existingRows } = await client.query(
      'SELECT version, name, checksum_sha256 FROM public.roomscan_schema_migrations ORDER BY version',
    );
    const existingByVersion = new Map(existingRows.map((row) => [row.version, row]));

    const migrationByVersion = new Map(migrations.map((migration) => [migration.version, migration]));
    for (const existing of existingRows) {
      const migration = migrationByVersion.get(existing.version);
      if (!migration) {
        const error = new Error(
          `Applied migration ${existing.version} is absent from the forward migration directory`,
        );
        error.code = 'MIGRATION_ORDER_VIOLATION';
        throw error;
      }
      if (existing.name !== migration.name || existing.checksum_sha256 !== migration.checksum) {
        const error = new Error(
          `Migration checksum mismatch for ${migration.version}: database=${existing.checksum_sha256} file=${migration.checksum}`,
        );
        error.code = 'MIGRATION_CHECKSUM_MISMATCH';
        throw error;
      }
    }

    let pendingVersionSeen = false;
    for (const migration of migrations) {
      if (existingByVersion.has(migration.version)) {
        if (pendingVersionSeen) {
          const error = new Error(
            `Migration ${migration.version} is already applied after an unapplied earlier version`,
          );
          error.code = 'MIGRATION_ORDER_VIOLATION';
          throw error;
        }
      } else {
        pendingVersionSeen = true;
      }
    }

    for (const migration of migrations) {
      const existing = existingByVersion.get(migration.version);
      if (existing) {
        skipped.push({ ...migration, sql: undefined });
        continue;
      }

      await client.query('BEGIN');
      try {
        await client.query(migration.sql);
        await client.query(
          `INSERT INTO public.roomscan_schema_migrations (version, name, checksum_sha256)
           VALUES ($1, $2, $3)`,
          [migration.version, migration.name, migration.checksum],
        );
        await client.query('COMMIT');
        applied.push({ ...migration, sql: undefined });
      } catch (error) {
        await client.query('ROLLBACK');
        error.message = `Migration ${migration.name} failed: ${error.message}`;
        throw error;
      }
    }
  } catch (error) {
    operationError = error;
    throw error;
  } finally {
    let releaseError;
    if (lockAcquired) {
      try {
        const { rows } = await client.query(
          'SELECT pg_advisory_unlock($1::bigint) AS unlocked',
          [ADVISORY_LOCK_ID.toString()],
        );
        if (rows[0]?.unlocked !== true) {
          releaseError = new Error('Migration advisory lock was not held by its dedicated client');
          releaseError.code = 'MIGRATION_LOCK_LOST';
        }
      } catch (error) {
        releaseError = error;
      }
    }

    // Passing the cleanup error evicts an uncertain session from pg.Pool. If a
    // migration already failed, preserve that primary error while still
    // ensuring the client is released and cannot retain a session lock.
    client.release(releaseError);
    if (releaseError && !operationError) {
      throw releaseError;
    }
  }

  return { applied, skipped };
}
