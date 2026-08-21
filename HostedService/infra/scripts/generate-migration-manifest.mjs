import { createHash } from "node:crypto";
import { mkdir, readFile, readdir, rename, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const infrastructureRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const migrationsDirectory = resolve(infrastructureRoot, "../db/migrations");
const migrationRunnerPath = resolve(infrastructureRoot, "../db/migrate.mjs");
const manifestPath = resolve(infrastructureRoot, "assets/migration-manifest.json");
const MIGRATION_NAME = /^(\d{4})_[a-z0-9_]+\.up\.sql$/u;
const EXPECTED_NAMES = Object.freeze([
  "0001_roles_and_global.up.sql",
  "0002_tenant_core.up.sql",
  "0003_quota.up.sql",
  "0004_stripe.up.sql",
  "0005_hardened_reducers.up.sql",
  "0006_auth_persistence.up.sql",
  "0007_policy_billing_integration.up.sql",
]);

const names = await readdir(migrationsDirectory);
const forbidden = names.filter((name) => name.endsWith(".down.sql") || /reset/iu.test(name));
if (forbidden.length > 0) {
  throw new Error(`forward-only migration directory contains forbidden files: ${forbidden.join(", ")}`);
}
const unexpectedSql = names.filter((name) => name.endsWith(".sql") && !MIGRATION_NAME.test(name));
if (unexpectedSql.length > 0) {
  throw new Error(`unexpected SQL migration filename: ${unexpectedSql.join(", ")}`);
}

const migrationNames = names.filter((name) => MIGRATION_NAME.test(name)).sort();
if (JSON.stringify(migrationNames) !== JSON.stringify(EXPECTED_NAMES)) {
  throw new Error("expected the exact ordered forward-only 0001-0007 migration set");
}

const migrations = await Promise.all(migrationNames.map(async (name) => Object.freeze({
  version: name.slice(0, 4),
  name,
  checksumSha256: createHash("sha256")
    .update(await readFile(resolve(migrationsDirectory, name)))
    .digest("hex"),
})));
const migrationRunner = Object.freeze({
  name: "migrate.mjs",
  checksumSha256: createHash("sha256")
    .update(await readFile(migrationRunnerPath))
    .digest("hex"),
});
const manifest = `${JSON.stringify({
  schema: "roomscan-forward-migration-manifest-v1",
  migrationRunner,
  migrations,
}, null, 2)}\n`;

await mkdir(dirname(manifestPath), { recursive: true });
let current;
try { current = await readFile(manifestPath, "utf8"); } catch { current = undefined; }
if (current !== manifest) {
  const temporaryPath = `${manifestPath}.${process.pid}.tmp`;
  await writeFile(temporaryPath, manifest, { encoding: "utf8", mode: 0o644 });
  await rename(temporaryPath, manifestPath);
}
process.stdout.write(`MIGRATION_MANIFEST ${JSON.stringify({
  path: "assets/migration-manifest.json",
  migrations: migrations.length,
  sha256: createHash("sha256").update(manifest).digest("hex"),
})}\n`);
