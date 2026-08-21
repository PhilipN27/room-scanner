import { createHash, randomBytes } from "node:crypto";
import { readFile } from "node:fs/promises";
import { isAbsolute, join } from "node:path";
import { pathToFileURL } from "node:url";

import { GetSecretValueCommand, SecretsManagerClient } from "@aws-sdk/client-secrets-manager";
import { Pool, type PoolConfig } from "pg";

import {
  AwsRuntimeCredentialSecretReader,
} from "../aws/runtime-clients.js";
import {
  RUNTIME_DATABASE_ROLES,
  type ExpectedMigrationLedgerRow,
  type RuntimeCredentialSecretReader,
  type RuntimeDatabaseRole,
} from "../aws/runtime-credential-bootstrap.js";
import {
  initializeRuntimeRoleCredentialsWithPostgres,
  type DirectPostgresPool,
} from "../migration-operator/direct-postgres.js";

const PINNED_RDS_CA_BUNDLE_SHA256 = "e5bb2084ccf45087bda1c9bffdea0eb15ee67f0b91646106e466714f9de3c7e3";
const REQUIRED_MIGRATION_NAMES = Object.freeze([
  "0001_roles_and_global.up.sql",
  "0002_tenant_core.up.sql",
  "0003_quota.up.sql",
  "0004_stripe.up.sql",
  "0005_hardened_reducers.up.sql",
  "0006_auth_persistence.up.sql",
  "0007_policy_billing_integration.up.sql",
] as const);

export interface MigrationOperatorConfiguration {
  readonly host: string;
  readonly port: number;
  readonly database: "roomscan";
  readonly ownerSecretArn: string;
  readonly migrationsPath: string;
  readonly caBundlePath: string;
  readonly caBundleSha256: string;
  readonly expectedMigrations: readonly ExpectedMigrationLedgerRow[];
  readonly runtimeRoleSecretArns: Readonly<Record<RuntimeDatabaseRole, string>>;
}

export interface MigrationOperatorPoolConfiguration {
  readonly host: string;
  readonly port: number;
  readonly database: string;
  readonly user: string;
  readonly password: string;
  readonly max: number;
  readonly min: number;
  readonly maxUses: number;
  readonly connectionTimeoutMillis: number;
  readonly ssl: Readonly<{
    readonly ca: string;
    readonly rejectUnauthorized: true;
    readonly servername: string;
    readonly minVersion: "TLSv1.2";
  }>;
}

export interface MigrationOperatorDependencies {
  readonly readFile: (path: string) => Promise<string>;
  readonly readOwnerSecret: (input: Readonly<{ readonly secretArn: string }>) => Promise<Readonly<{
    readonly username: string;
    readonly password: string;
  }>>;
  readonly readRuntimeSecret: RuntimeCredentialSecretReader["read"];
  readonly createPool: (configuration: MigrationOperatorPoolConfiguration) => DirectPostgresPool;
  readonly applyMigrations: (input: Readonly<{
    readonly pool: DirectPostgresPool;
    readonly migrationsDir: string;
  }>) => Promise<unknown>;
  readonly randomBytes: (length: number) => Uint8Array;
}

export interface MigrationOperatorResponse {
  readonly statusCode: 204;
  readonly headers: Readonly<{ readonly "cache-control": "no-store" }>;
  readonly body: "";
}

interface MigrationManifest {
  readonly schema: "roomscan-forward-migration-manifest-v1";
  readonly migrationRunner: Readonly<{
    readonly name: "migrate.mjs";
    readonly checksumSha256: string;
  }>;
  readonly migrations: readonly ExpectedMigrationLedgerRow[];
}

export interface MigrationOperatorEntrypointDependencies {
  readonly readManifestBytes: (path: string) => Promise<Uint8Array>;
  readonly readAssetText: (path: string) => Promise<string>;
  readonly loadMigrationRunner: (
    path: string,
    expectedChecksumSha256: string,
  ) => Promise<MigrationOperatorDependencies["applyMigrations"]>;
  readonly createProviderDependencies: (
    configuration: Omit<MigrationOperatorConfiguration, "expectedMigrations">,
  ) => Omit<MigrationOperatorDependencies, "applyMigrations">;
}

export class MigrationOperatorError extends Error {
  constructor(readonly code: "migration_operator_configuration_invalid" | "migration_operator_failed") {
    super(code);
    this.name = "MigrationOperatorError";
  }
}

/**
 * One-shot owner boundary. Its event is deliberately ignored: invocation
 * payloads cannot select a database, migration, role, secret, or SQL text.
 */
export function createMigrationOperator(input: Readonly<{
  readonly configuration: MigrationOperatorConfiguration;
  readonly dependencies: MigrationOperatorDependencies;
}>): (event: unknown) => Promise<MigrationOperatorResponse> {
  assertConfiguration(input?.configuration);
  assertDependencies(input?.dependencies);
  const configuration = input.configuration;
  const dependencies = input.dependencies;

  return async (_event: unknown): Promise<MigrationOperatorResponse> => {
    let pool: DirectPostgresPool | undefined;
    let closed = false;
    try {
      await assertExactMigrationAssets(configuration, dependencies.readFile);
      const caBundle = await dependencies.readFile(configuration.caBundlePath);
      assertCaBundle(caBundle, configuration.caBundleSha256);
      const owner = await dependencies.readOwnerSecret({ secretArn: configuration.ownerSecretArn });
      assertOwnerSecret(owner);
      pool = dependencies.createPool(Object.freeze({
        host: configuration.host,
        port: configuration.port,
        database: configuration.database,
        user: owner.username,
        password: owner.password,
        max: 1,
        min: 0,
        maxUses: 1,
        connectionTimeoutMillis: 10_000,
        ssl: Object.freeze({
          ca: caBundle,
          rejectUnauthorized: true,
          servername: configuration.host,
          minVersion: "TLSv1.2",
        }),
      }));

      // This is the exact forward-only runner shipped beside the raw SQL asset.
      // It owns the advisory lock, ordered checksum ledger, per-migration
      // transaction, rollback, and connection-release semantics.
      await dependencies.applyMigrations({ pool, migrationsDir: configuration.migrationsPath });

      await initializeRuntimeRoleCredentialsWithPostgres({
        pool,
        secretReader: Object.freeze({ read: dependencies.readRuntimeSecret }),
        secretArns: configuration.runtimeRoleSecretArns,
        expectedMigrations: configuration.expectedMigrations,
        randomBytes: dependencies.randomBytes,
      });
      await pool.end();
      closed = true;
      return Object.freeze({
        statusCode: 204,
        headers: Object.freeze({ "cache-control": "no-store" }),
        body: "",
      });
    } catch {
      if (pool !== undefined && !closed) {
        try { await pool.end(); } catch { /* one-shot process remains fail-closed */ }
      }
      // Do not expose SQL, migration names, secret ARNs, passwords, or provider
      // diagnostics through Lambda's default error formatter/logging path.
      throw new MigrationOperatorError("migration_operator_failed");
    }
  };
}

export function createMigrationOperatorEntrypoint(input: Readonly<{
  readonly environment: NodeJS.ProcessEnv;
  readonly dependencies: MigrationOperatorEntrypointDependencies;
}>): (event: unknown) => Promise<MigrationOperatorResponse> {
  return async (event: unknown): Promise<MigrationOperatorResponse> => {
    try {
      const runtime = loadRuntimeConfiguration(input.environment);
      // Pin the complete manifest bytes first, then the exact runner named by
      // that manifest, before an AWS SDK client or PostgreSQL pool can exist.
      const manifest = await loadMigrationManifest(
        runtime.migrationManifestPath,
        runtime.migrationManifestSha256,
        input.dependencies.readManifestBytes,
      );
      const applyMigrations = await input.dependencies.loadMigrationRunner(
        runtime.migrationRunnerPath,
        manifest.migrationRunner.checksumSha256,
      );
      const verifiedConfiguration = Object.freeze({
        ...runtime.configuration,
        expectedMigrations: manifest.migrations,
      });
      await assertExactMigrationAssets(verifiedConfiguration, input.dependencies.readAssetText);
      const caBundle = await input.dependencies.readAssetText(verifiedConfiguration.caBundlePath);
      assertCaBundle(caBundle, verifiedConfiguration.caBundleSha256);
      const dependencies = input.dependencies.createProviderDependencies(runtime.configuration);
      return await createMigrationOperator({
        configuration: verifiedConfiguration,
        dependencies: Object.freeze({ ...dependencies, applyMigrations }),
      })(event);
    } catch {
      throw new MigrationOperatorError("migration_operator_failed");
    }
  };
}

/** No AWS client is constructed or invoked until this handler itself runs. */
export async function handler(event: unknown): Promise<MigrationOperatorResponse> {
  return createMigrationOperatorEntrypoint({
    environment: process.env,
    dependencies: {
      readManifestBytes: async (path) => readFile(path),
      readAssetText: async (path) => readFile(path, "utf8"),
      loadMigrationRunner: loadExactMigrationRunner,
      createProviderDependencies: productionDependencies,
    },
  })(event);
}

function productionDependencies(
  configuration: Pick<MigrationOperatorConfiguration, "runtimeRoleSecretArns">,
): Omit<MigrationOperatorDependencies, "applyMigrations"> {
  const secrets = new SecretsManagerClient({ region: "us-east-1" });
  const runtimeSecretReader = new AwsRuntimeCredentialSecretReader({
    sender: secrets,
    allowed: configuration.runtimeRoleSecretArns,
  });
  return Object.freeze({
    readFile: async (path) => readFile(path, "utf8"),
    readOwnerSecret: async ({ secretArn }) => readOwnerSecret(secrets, secretArn),
    readRuntimeSecret: (input) => runtimeSecretReader.read(input),
    createPool: (configuration) => new Pool(poolConfig(configuration)),
    randomBytes: (length) => Uint8Array.from(randomBytes(length)),
  });
}

function poolConfig(configuration: MigrationOperatorPoolConfiguration): PoolConfig {
  return {
    host: configuration.host,
    port: configuration.port,
    database: configuration.database,
    user: configuration.user,
    password: configuration.password,
    max: configuration.max,
    min: configuration.min,
    maxUses: configuration.maxUses,
    connectionTimeoutMillis: configuration.connectionTimeoutMillis,
    ssl: {
      ca: configuration.ssl.ca,
      rejectUnauthorized: configuration.ssl.rejectUnauthorized,
      servername: configuration.ssl.servername,
      minVersion: configuration.ssl.minVersion,
    },
  };
}

async function readOwnerSecret(
  client: SecretsManagerClient,
  secretArn: string,
): Promise<Readonly<{ readonly username: string; readonly password: string }>> {
  const response = await client.send(new GetSecretValueCommand({
    SecretId: secretArn,
    VersionStage: "AWSCURRENT",
  }));
  if (typeof response.SecretString !== "string" || response.SecretBinary !== undefined) {
    throw new MigrationOperatorError("migration_operator_failed");
  }
  let parsed: unknown;
  try { parsed = JSON.parse(response.SecretString) as unknown; } catch {
    throw new MigrationOperatorError("migration_operator_failed");
  }
  if (!record(parsed) || Object.keys(parsed).sort().join(",") !== "password,rotationReady,username"
    || parsed.username !== "roomscan_cluster_admin" || parsed.rotationReady !== true
    || !password(parsed.password)) {
    throw new MigrationOperatorError("migration_operator_failed");
  }
  return Object.freeze({ username: parsed.username, password: parsed.password });
}

async function loadExactMigrationRunner(
  path: string,
  expectedChecksumSha256: string,
): Promise<MigrationOperatorDependencies["applyMigrations"]> {
  let bytes: Buffer;
  try { bytes = await readFile(path); } catch {
    throw new MigrationOperatorError("migration_operator_failed");
  }
  if (!sha256(expectedChecksumSha256)
    || createHash("sha256").update(bytes).digest("hex") !== expectedChecksumSha256) {
    throw new MigrationOperatorError("migration_operator_failed");
  }
  let imported: unknown;
  try { imported = await import(pathToFileURL(path).href); } catch {
    throw new MigrationOperatorError("migration_operator_failed");
  }
  const moduleRecord = record(imported) ? imported : undefined;
  const candidate = moduleRecord?.applyMigrations;
  if (typeof candidate !== "function") throw new MigrationOperatorError("migration_operator_failed");
  return candidate as MigrationOperatorDependencies["applyMigrations"];
}

async function loadMigrationManifest(
  path: string,
  expectedChecksumSha256: string,
  loadBytes: (path: string) => Promise<Uint8Array>,
): Promise<MigrationManifest> {
  let bytes: Uint8Array;
  try { bytes = await loadBytes(path); } catch {
    throw new MigrationOperatorError("migration_operator_failed");
  }
  if (!sha256(expectedChecksumSha256) || bytes.byteLength < 1 || bytes.byteLength > 1_000_000
    || createHash("sha256").update(bytes).digest("hex") !== expectedChecksumSha256) {
    throw new MigrationOperatorError("migration_operator_failed");
  }
  let parsed: unknown;
  try { parsed = JSON.parse(Buffer.from(bytes).toString("utf8")) as unknown; } catch {
    throw new MigrationOperatorError("migration_operator_failed");
  }
  if (!record(parsed) || parsed.schema !== "roomscan-forward-migration-manifest-v1"
    || !migrationRunner(parsed.migrationRunner) || !expectedMigrations(parsed.migrations)) {
    throw new MigrationOperatorError("migration_operator_failed");
  }
  return Object.freeze({
    schema: "roomscan-forward-migration-manifest-v1",
    migrationRunner: Object.freeze({
      name: "migrate.mjs",
      checksumSha256: parsed.migrationRunner.checksumSha256 as string,
    }),
    migrations: Object.freeze(parsed.migrations.map((migration) => Object.freeze({
      version: migration.version as string,
      name: migration.name as string,
      checksumSha256: migration.checksumSha256 as string,
    }))),
  });
}

function loadRuntimeConfiguration(environment: NodeJS.ProcessEnv): Readonly<{
  readonly migrationRunnerPath: string;
  readonly migrationManifestPath: string;
  readonly migrationManifestSha256: string;
  readonly configuration: Omit<MigrationOperatorConfiguration, "expectedMigrations">;
}> {
  const runtimeRoleSecretArns = parseRuntimeRoleSecretArns(environment.RUNTIME_ROLE_SECRET_ARNS_JSON);
  const configuration: Omit<MigrationOperatorConfiguration, "expectedMigrations"> = Object.freeze({
    host: requiredEnvironment(environment, "DB_HOST", /^roomscan-[a-z0-9-]{1,48}\.cluster-[a-z0-9-]{8,64}\.us-east-1\.rds\.amazonaws\.com$/u, 256),
    port: requiredInteger(environment, "DB_PORT", 5432, 5432),
    database: requiredEnvironment(environment, "DB_NAME", /^roomscan$/u, 64) as "roomscan",
    ownerSecretArn: requiredEnvironment(environment, "DB_OWNER_SECRET_ARN", secretArnPattern, 640),
    migrationsPath: requiredAssetPath(environment, "MIGRATIONS_PATH"),
    caBundlePath: requiredAssetPath(environment, "RDS_CA_BUNDLE_PATH"),
    caBundleSha256: PINNED_RDS_CA_BUNDLE_SHA256,
    runtimeRoleSecretArns,
  });
  return Object.freeze({
    migrationRunnerPath: requiredAssetPath(environment, "MIGRATION_RUNNER_PATH"),
    migrationManifestPath: requiredAssetPath(environment, "MIGRATION_MANIFEST_PATH"),
    migrationManifestSha256: requiredEnvironment(environment, "MIGRATION_MANIFEST_SHA256", /^[a-f0-9]{64}$/u, 64),
    configuration,
  });
}

function assertConfiguration(value: unknown): asserts value is MigrationOperatorConfiguration {
  if (!record(value)
    || !databaseHost(value.host)
    || value.port !== 5432
    || value.database !== "roomscan"
    || !secretArnPattern.test(String(value.ownerSecretArn))
    || !assetPath(value.migrationsPath)
    || !assetPath(value.caBundlePath)
    || !sha256(value.caBundleSha256)
    || !expectedMigrations(value.expectedMigrations)
    || !runtimeRoleSecretArns(value.runtimeRoleSecretArns)) {
    throw new MigrationOperatorError("migration_operator_configuration_invalid");
  }
}

function assertDependencies(value: unknown): asserts value is MigrationOperatorDependencies {
  if (!record(value)
    || typeof value.readFile !== "function"
    || typeof value.readOwnerSecret !== "function"
    || typeof value.readRuntimeSecret !== "function"
    || typeof value.createPool !== "function"
    || typeof value.applyMigrations !== "function"
    || typeof value.randomBytes !== "function") {
    throw new MigrationOperatorError("migration_operator_configuration_invalid");
  }
}

function assertCaBundle(value: string, expectedHash: string): void {
  if (typeof value !== "string" || value.length < 128 || value.length > 1_000_000
    || !value.includes("-----BEGIN CERTIFICATE-----") || !value.includes("-----END CERTIFICATE-----")
    || createHash("sha256").update(value).digest("hex") !== expectedHash) {
    throw new MigrationOperatorError("migration_operator_failed");
  }
}

async function assertExactMigrationAssets(
  configuration: MigrationOperatorConfiguration,
  loadAsset: MigrationOperatorDependencies["readFile"],
): Promise<void> {
  for (const expected of configuration.expectedMigrations) {
    const contents = await loadAsset(join(configuration.migrationsPath, expected.name));
    if (createHash("sha256").update(contents).digest("hex") !== expected.checksumSha256) {
      throw new MigrationOperatorError("migration_operator_failed");
    }
  }
}

function assertOwnerSecret(value: unknown): asserts value is Readonly<{ readonly username: string; readonly password: string }> {
  if (!record(value) || value.username !== "roomscan_cluster_admin" || !password(value.password)) {
    throw new MigrationOperatorError("migration_operator_failed");
  }
}

function expectedMigrations(value: unknown): value is readonly ExpectedMigrationLedgerRow[] {
  return Array.isArray(value) && value.length === REQUIRED_MIGRATION_NAMES.length
    && value.every((migration, index) => record(migration)
      && migration.version === String(index + 1).padStart(4, "0")
      && migration.name === REQUIRED_MIGRATION_NAMES[index]
      && sha256(migration.checksumSha256));
}

function migrationRunner(value: unknown): value is Readonly<{
  readonly name: "migrate.mjs";
  readonly checksumSha256: string;
}> {
  return record(value) && value.name === "migrate.mjs" && sha256(value.checksumSha256);
}

function runtimeRoleSecretArns(value: unknown): value is Readonly<Record<RuntimeDatabaseRole, string>> {
  if (!record(value)) return false;
  const keys = Object.keys(value).sort();
  const expected = [...RUNTIME_DATABASE_ROLES].sort();
  return keys.length === expected.length
    && keys.every((key, index) => key === expected[index] && secretArnPattern.test(String(value[key])));
}

function parseRuntimeRoleSecretArns(source: string | undefined): Readonly<Record<RuntimeDatabaseRole, string>> {
  const parsed = parseJson(source);
  if (!runtimeRoleSecretArns(parsed)) throw new MigrationOperatorError("migration_operator_configuration_invalid");
  return Object.freeze({ ...parsed });
}

function parseJson(source: string | undefined): unknown {
  if (typeof source !== "string" || source.length === 0 || source.length > 16_384) {
    throw new MigrationOperatorError("migration_operator_configuration_invalid");
  }
  try { return JSON.parse(source) as unknown; } catch {
    throw new MigrationOperatorError("migration_operator_configuration_invalid");
  }
}

function requiredEnvironment(
  environment: NodeJS.ProcessEnv,
  name: string,
  pattern: RegExp,
  maximum: number,
): string {
  const value = environment[name];
  if (typeof value !== "string" || value.length === 0 || value.length > maximum
    || value !== value.trim() || !pattern.test(value)) {
    throw new MigrationOperatorError("migration_operator_configuration_invalid");
  }
  return value;
}

function requiredInteger(environment: NodeJS.ProcessEnv, name: string, minimum: number, maximum: number): number {
  const source = requiredEnvironment(environment, name, /^(?:0|[1-9][0-9]{0,15})$/u, 16);
  const value = Number(source);
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new MigrationOperatorError("migration_operator_configuration_invalid");
  }
  return value;
}

function requiredAssetPath(environment: NodeJS.ProcessEnv, name: string): string {
  const value = environment[name];
  if (!assetPath(value)) throw new MigrationOperatorError("migration_operator_configuration_invalid");
  return value;
}

function databaseHost(value: unknown): value is string {
  return typeof value === "string"
    && /^roomscan-[a-z0-9-]{1,48}\.cluster-[a-z0-9-]{8,64}\.us-east-1\.rds\.amazonaws\.com$/u.test(value);
}

function assetPath(value: unknown): value is string {
  return typeof value === "string" && value.length >= 10 && value.length <= 512
    && isAbsolute(value) && value.startsWith("/var/task/")
    && !value.includes("\u0000") && !value.split("/").includes("..");
}

function password(value: unknown): value is string {
  return typeof value === "string" && value.length >= 32 && value.length <= 1_024
    && !/[\u0000\r\n]/u.test(value);
}

function sha256(value: unknown): value is string {
  return typeof value === "string" && /^[a-f0-9]{64}$/u.test(value);
}

function record(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

const secretArnPattern = /^arn:aws:secretsmanager:us-east-1:\d{12}:secret:[A-Za-z0-9/_+=.@-]{1,512}$/u;
