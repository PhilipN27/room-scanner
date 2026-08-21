import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile as readUtf8File } from "node:fs/promises";
import { resolve } from "node:path";
import test from "node:test";

import { SecretsManagerClient } from "@aws-sdk/client-secrets-manager";
import { Pool } from "pg";

type LedgerRow = Readonly<{
  readonly version: string;
  readonly name: string;
  readonly checksumSha256: string;
}>;

type RuntimeRole =
  | "roomscan_api_runtime"
  | "roomscan_authorizer_runtime"
  | "roomscan_auth_challenge_runtime"
  | "roomscan_stripe_ingress_runtime"
  | "roomscan_stripe_reconciliation_runtime"
  | "roomscan_audit_export_runtime"
  | "roomscan_email_delivery_runtime";

type RuntimeSecretArns = Readonly<Record<RuntimeRole, string>>;

interface QueryResult {
  readonly rows: readonly Readonly<Record<string, string>>[];
}

interface PgClient {
  query(sql: string): Promise<QueryResult>;
  release(error?: Error): void;
}

interface PgPool {
  connect(): Promise<PgClient>;
  end(): Promise<void>;
}

interface OperatorConfiguration {
  readonly host: string;
  readonly port: number;
  readonly database: string;
  readonly ownerSecretArn: string;
  readonly migrationsPath: string;
  readonly caBundlePath: string;
  readonly caBundleSha256: string;
  readonly expectedMigrations: readonly LedgerRow[];
  readonly runtimeRoleSecretArns: RuntimeSecretArns;
}

interface PoolConfiguration {
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

interface OperatorDependencies {
  readonly readFile: (path: string) => Promise<string>;
  readonly readOwnerSecret: (input: Readonly<{ readonly secretArn: string }>) => Promise<Readonly<{
    readonly username: string;
    readonly password: string;
  }>>;
  readonly readRuntimeSecret: (input: Readonly<{
    readonly secretArn: string;
    readonly expectedUsername: RuntimeRole;
  }>) => Promise<string>;
  readonly createPool: (configuration: PoolConfiguration) => PgPool;
  readonly applyMigrations: (input: Readonly<{ readonly pool: PgPool; readonly migrationsDir: string }>) => Promise<unknown>;
  readonly randomBytes: (length: number) => Uint8Array;
}

interface OperatorModule {
  createMigrationOperator(input: Readonly<{
    readonly configuration: OperatorConfiguration;
    readonly dependencies: OperatorDependencies;
  }>): (event: unknown) => Promise<Readonly<{
    readonly statusCode: number;
    readonly headers: Readonly<Record<string, string>>;
    readonly body: string;
  }>>;
  createMigrationOperatorEntrypoint(input: Readonly<{
    readonly environment: NodeJS.ProcessEnv;
    readonly dependencies: Readonly<{
      readonly readManifestBytes: (path: string) => Promise<Uint8Array>;
      readonly readAssetText: (path: string) => Promise<string>;
      readonly loadMigrationRunner: (path: string, checksumSha256: string) => Promise<OperatorDependencies["applyMigrations"]>;
      readonly createProviderDependencies: (
        configuration: Omit<OperatorConfiguration, "expectedMigrations">,
      ) => Omit<OperatorDependencies, "applyMigrations">;
    }>;
  }>): (event: unknown) => Promise<Readonly<{
    readonly statusCode: number;
    readonly headers: Readonly<Record<string, string>>;
    readonly body: string;
  }>>;
}

let subjectModule: Promise<OperatorModule> | undefined;

function loadSubject(): Promise<OperatorModule> {
  subjectModule ??= import("../src/functions/migration-operator.js") as Promise<OperatorModule>;
  return subjectModule;
}

const ROLES: readonly RuntimeRole[] = [
  "roomscan_api_runtime",
  "roomscan_authorizer_runtime",
  "roomscan_auth_challenge_runtime",
  "roomscan_stripe_ingress_runtime",
  "roomscan_stripe_reconciliation_runtime",
  "roomscan_audit_export_runtime",
  "roomscan_email_delivery_runtime",
];
const CA = `-----BEGIN CERTIFICATE-----\n${"a".repeat(128)}\n-----END CERTIFICATE-----\n`;
const CA_HASH = createHash("sha256").update(CA).digest("hex");
const PINNED_CA = await readUtf8File(resolve("assets/rds-global-bundle-2026-08-19.pem"), "utf8");
const MIGRATION_NAMES = Object.freeze([
  "0001_roles_and_global.up.sql",
  "0002_tenant_core.up.sql",
  "0003_quota.up.sql",
  "0004_stripe.up.sql",
  "0005_hardened_reducers.up.sql",
  "0006_auth_persistence.up.sql",
  "0007_policy_billing_integration.up.sql",
] as const);
const RAW_MIGRATIONS = Object.freeze(Object.fromEntries(await Promise.all(MIGRATION_NAMES.map(async (name) => [
  name,
  await readUtf8File(resolve(process.cwd(), "../db/migrations", name), "utf8"),
]))) as Record<typeof MIGRATION_NAMES[number], string>);
const RAW_MIGRATION_RUNNER = await readUtf8File(resolve(process.cwd(), "../db/migrate.mjs"), "utf8");
const SOURCE_LEDGER: readonly LedgerRow[] = MIGRATION_NAMES.map((name, index) => Object.freeze({
  version: String(index + 1).padStart(4, "0"),
  name,
  checksumSha256: createHash("sha256").update(RAW_MIGRATIONS[name]).digest("hex"),
}));
const MIGRATION_MANIFEST = JSON.parse(await readUtf8File(
  resolve(process.cwd(), "assets/migration-manifest.json"),
  "utf8",
)) as Readonly<{
  readonly schema: string;
  readonly migrationRunner: Readonly<{ readonly name: string; readonly checksumSha256: string }>;
  readonly migrations: readonly LedgerRow[];
}>;
const LEDGER = MIGRATION_MANIFEST.migrations;
const MIGRATION_MANIFEST_BYTES = Buffer.from(await readUtf8File(
  resolve(process.cwd(), "assets/migration-manifest.json"),
  "utf8",
));
const MIGRATION_MANIFEST_SHA256 = createHash("sha256").update(MIGRATION_MANIFEST_BYTES).digest("hex");
const RUNTIME_SECRET_ARNS = Object.freeze(Object.fromEntries(ROLES.map((role) => [
  role,
  `arn:aws:secretsmanager:us-east-1:111111111111:secret:${role}-AbCdEf`,
])) as RuntimeSecretArns);

test("migration operator module import makes no Secrets Manager or PostgreSQL connection call", async () => {
  const secretsPrototype = SecretsManagerClient.prototype as unknown as { send: (...args: unknown[]) => unknown };
  const poolPrototype = Pool.prototype as unknown as { connect: (...args: unknown[]) => unknown };
  const originalSend = secretsPrototype.send;
  const originalConnect = poolPrototype.connect;
  let providerCalls = 0;
  secretsPrototype.send = () => {
    providerCalls += 1;
    throw new Error("provider call during module import");
  };
  poolPrototype.connect = () => {
    providerCalls += 1;
    throw new Error("PostgreSQL connection during module import");
  };
  try {
    await import(new URL("../src/functions/migration-operator.js", import.meta.url).href + `?module-import=${Date.now()}`);
  } finally {
    secretsPrototype.send = originalSend;
    poolPrototype.connect = originalConnect;
  }
  assert.equal(providerCalls, 0);
});

test("generated migration manifest is an exact ordered digest of the source 0001–0007 migration bytes", () => {
  assert.deepEqual(MIGRATION_MANIFEST, {
    schema: "roomscan-forward-migration-manifest-v1",
    migrationRunner: {
      name: "migrate.mjs",
      checksumSha256: createHash("sha256").update(RAW_MIGRATION_RUNNER).digest("hex"),
    },
    migrations: SOURCE_LEDGER,
  });
});

test("a tampered pinned manifest fails before runner import or any provider dependency construction", async () => {
  const subject = await loadSubject();
  let runnerLoads = 0;
  let providerConstructions = 0;
  const entrypoint = subject.createMigrationOperatorEntrypoint({
    environment: {
      DB_HOST: "roomscan-dev.cluster-abcdefghijkl.us-east-1.rds.amazonaws.com",
      DB_PORT: "5432",
      DB_NAME: "roomscan",
      DB_OWNER_SECRET_ARN: "arn:aws:secretsmanager:us-east-1:111111111111:secret:roomscan-owner-AbCdEf",
      MIGRATIONS_PATH: "/var/task/migration-assets/migrations",
      RDS_CA_BUNDLE_PATH: "/var/task/migration-assets/rds-global-bundle.pem",
      MIGRATION_RUNNER_PATH: "/var/task/migration-assets/migrate.mjs",
      MIGRATION_MANIFEST_PATH: "/var/task/migration-assets/migration-manifest.json",
      MIGRATION_MANIFEST_SHA256,
      RUNTIME_ROLE_SECRET_ARNS_JSON: JSON.stringify(RUNTIME_SECRET_ARNS),
    },
    dependencies: {
      readManifestBytes: async () => Buffer.concat([MIGRATION_MANIFEST_BYTES, Buffer.from("tampered")]),
      readAssetText: async () => { throw new Error("assets must not load after a bad manifest"); },
      loadMigrationRunner: async () => {
        runnerLoads += 1;
        throw new Error("runner must not load");
      },
      createProviderDependencies: () => {
        providerConstructions += 1;
        throw new Error("provider must not construct");
      },
    },
  });

  await assert.rejects(entrypoint(undefined), /migration_operator_failed/u);
  assert.equal(runnerLoads, 0);
  assert.equal(providerConstructions, 0);
});

test("tampered runner, each migration, or pinned CA fails before any provider dependency construction", async () => {
  const subject = await loadSubject();
  const cases = ["runner", ...MIGRATION_NAMES, "ca"] as const;
  for (const tampered of cases) {
    let providerConstructions = 0;
    const entrypoint = subject.createMigrationOperatorEntrypoint({
      environment: {
        DB_HOST: "roomscan-dev.cluster-abcdefghijkl.us-east-1.rds.amazonaws.com",
        DB_PORT: "5432",
        DB_NAME: "roomscan",
        DB_OWNER_SECRET_ARN: "arn:aws:secretsmanager:us-east-1:111111111111:secret:roomscan-owner-AbCdEf",
        MIGRATIONS_PATH: "/var/task/migration-assets/migrations",
        RDS_CA_BUNDLE_PATH: "/var/task/migration-assets/rds-global-bundle.pem",
        MIGRATION_RUNNER_PATH: "/var/task/migration-assets/migrate.mjs",
        MIGRATION_MANIFEST_PATH: "/var/task/migration-assets/migration-manifest.json",
        MIGRATION_MANIFEST_SHA256,
        RUNTIME_ROLE_SECRET_ARNS_JSON: JSON.stringify(RUNTIME_SECRET_ARNS),
      },
      dependencies: {
        readManifestBytes: async () => MIGRATION_MANIFEST_BYTES,
        readAssetText: async (path) => {
          if (path.endsWith("rds-global-bundle.pem")) return tampered === "ca" ? `${PINNED_CA}tampered` : PINNED_CA;
          const name = path.split("/").at(-1);
          if (name !== undefined && name in RAW_MIGRATIONS) {
            const source = RAW_MIGRATIONS[name as keyof typeof RAW_MIGRATIONS];
            return tampered === name ? `${source}\n-- tampered` : source;
          }
          throw new Error("unexpected asset");
        },
        loadMigrationRunner: async () => {
          if (tampered === "runner") throw new Error("runner checksum mismatch");
          return async () => undefined;
        },
        createProviderDependencies: () => {
          providerConstructions += 1;
          throw new Error("provider must not construct");
        },
      },
    });

    await assert.rejects(entrypoint(undefined), /migration_operator_failed/u, tampered);
    assert.equal(providerConstructions, 0, tampered);
  }
});

class RecordingClient implements PgClient {
  readonly sql: string[] = [];
  readonly releaseErrors: Error[] = [];
  failAlterAt: number | undefined;
  #alterCount = 0;

  async query(sql: string): Promise<QueryResult> {
    this.sql.push(sql);
    if (sql.startsWith("ALTER ROLE") && this.failAlterAt === this.#alterCount++) {
      throw new Error("provider error includes operator-secret-value");
    }
    if (sql.startsWith("SELECT version, name, checksum_sha256")) {
      return {
        rows: LEDGER.map((row) => ({
          version: row.version,
          name: row.name,
          checksum_sha256: row.checksumSha256,
        })),
      };
    }
    return { rows: [] };
  }

  release(error?: Error): void {
    if (error !== undefined) this.releaseErrors.push(error);
  }
}

class RecordingPool implements PgPool {
  readonly client = new RecordingClient();
  connectCount = 0;
  endCount = 0;

  constructor(private readonly events?: string[]) {}

  async connect(): Promise<PgClient> {
    this.connectCount += 1;
    this.events?.push("connect");
    return this.client;
  }

  async end(): Promise<void> {
    this.endCount += 1;
    this.events?.push("end");
  }
}

function configuration(overrides: Partial<OperatorConfiguration> = {}): OperatorConfiguration {
  return Object.freeze({
    host: "roomscan-dev.cluster-abcdefghijkl.us-east-1.rds.amazonaws.com",
    port: 5432,
    database: "roomscan",
    ownerSecretArn: "arn:aws:secretsmanager:us-east-1:111111111111:secret:roomscan-owner-AbCdEf",
    migrationsPath: "/var/task/migrations",
    caBundlePath: "/var/task/assets/rds-global-bundle.pem",
    caBundleSha256: CA_HASH,
    expectedMigrations: LEDGER,
    runtimeRoleSecretArns: RUNTIME_SECRET_ARNS,
    ...overrides,
  });
}

function dependencies(pool: RecordingPool, events: string[], overrides: Partial<OperatorDependencies> = {}): OperatorDependencies {
  return {
    readFile: async (path) => {
      events.push(`ca:${path}`);
      if (path === "/var/task/assets/rds-global-bundle.pem") return CA;
      const name = path.split("/").at(-1);
      if (name !== undefined && name in RAW_MIGRATIONS) return RAW_MIGRATIONS[name as keyof typeof RAW_MIGRATIONS];
      throw new Error("unexpected asset path");
    },
    readOwnerSecret: async ({ secretArn }) => {
      events.push(`owner:${secretArn}`);
      return Object.freeze({ username: "roomscan_cluster_admin", password: "owner-secret-value-" + "x".repeat(48) });
    },
    readRuntimeSecret: async ({ secretArn, expectedUsername }) => {
      events.push(`runtime:${expectedUsername}:${secretArn}`);
      return `runtime-secret-${expectedUsername}-${"x".repeat(48)}`;
    },
    createPool: (input) => {
      events.push("pool");
      assert.deepEqual(input, {
        host: "roomscan-dev.cluster-abcdefghijkl.us-east-1.rds.amazonaws.com",
        port: 5432,
        database: "roomscan",
        user: "roomscan_cluster_admin",
        password: "owner-secret-value-" + "x".repeat(48),
        max: 1,
        min: 0,
        maxUses: 1,
        connectionTimeoutMillis: 10_000,
        ssl: {
          ca: CA,
          rejectUnauthorized: true,
          servername: "roomscan-dev.cluster-abcdefghijkl.us-east-1.rds.amazonaws.com",
          minVersion: "TLSv1.2",
        },
      });
      return pool;
    },
    applyMigrations: async ({ pool: actualPool, migrationsDir }) => {
      events.push(`migrate:${migrationsDir}`);
      assert.equal(actualPool, pool);
    },
    randomBytes: (length) => Uint8Array.from({ length }, (_, index) => index + 1),
    ...overrides,
  };
}

test("migration operator applies the exact raw migration runner before owner-only seven-role credential initialization", async () => {
  const subject = await loadSubject();
  const events: string[] = [];
  const pool = new RecordingPool(events);
  const operator = subject.createMigrationOperator({
    configuration: configuration(),
    dependencies: dependencies(pool, events),
  });

  const response = await operator({ ignored: "caller-input-is-never-used" });

  assert.equal(response.statusCode, 204);
  assert.equal(response.body, "");
  assert.deepEqual(response.headers, { "cache-control": "no-store" });
  assert.ok(events.indexOf("migrate:/var/task/migrations") < events.indexOf("runtime:roomscan_api_runtime:arn:aws:secretsmanager:us-east-1:111111111111:secret:roomscan_api_runtime-AbCdEf"));
  assert.ok(events.filter((event) => event.startsWith("runtime:")).every((event) => events.indexOf(event) < events.indexOf("connect")));
  assert.equal(pool.connectCount, 1);
  assert.equal(pool.endCount, 1);
  assert.deepEqual(pool.client.sql.slice(0, 4), [
    "BEGIN",
    "SET LOCAL log_statement = 'none'",
    "SET LOCAL log_min_duration_statement = '-1'",
    "SELECT version, name, checksum_sha256 FROM public.roomscan_schema_migrations ORDER BY version",
  ]);
  const alters = pool.client.sql.filter((sql) => sql.startsWith("ALTER ROLE"));
  assert.equal(alters.length, 7);
  assert.deepEqual(alters.map((sql) => sql.match(/^ALTER ROLE ([a-z_]+) PASSWORD /u)?.[1]), ROLES);
  assert.equal(pool.client.sql.at(-1), "COMMIT");
  assert.doesNotMatch(JSON.stringify(pool.client.sql), /runtime-secret|owner-secret/u);
});

test("tampered raw migration assets stop before owner-secret retrieval, connection, or credential rotation", async () => {
  const subject = await loadSubject();
  const events: string[] = [];
  const pool = new RecordingPool(events);
  const operator = subject.createMigrationOperator({
    configuration: configuration(),
    dependencies: dependencies(pool, events, {
      readFile: async (path) => {
        events.push(`asset:${path}`);
        if (path === "/var/task/assets/rds-global-bundle.pem") return CA;
        const name = path.split("/").at(-1);
        if (name === "0007_policy_billing_integration.up.sql") {
          return `${RAW_MIGRATIONS[name]}\n-- unsafe mutation`;
        }
        if (name !== undefined && name in RAW_MIGRATIONS) return RAW_MIGRATIONS[name as keyof typeof RAW_MIGRATIONS];
        throw new Error("unexpected asset path");
      },
    }),
  });

  await assert.rejects(operator(undefined), /migration_operator_failed/u);
  assert.equal(events.some((event) => event.startsWith("owner:") || event === "pool" || event.startsWith("migrate:")), false);
  assert.equal(pool.connectCount, 0);
  assert.equal(pool.endCount, 0);
});

test("checksum mismatch prevents credential initialization, closes the one-shot pool, and redacts provider detail", async () => {
  const subject = await loadSubject();
  const events: string[] = [];
  const pool = new RecordingPool();
  const operator = subject.createMigrationOperator({
    configuration: configuration(),
    dependencies: dependencies(pool, events, {
      applyMigrations: async () => {
        throw new Error("MIGRATION_CHECKSUM_MISMATCH operator-secret-value");
      },
    }),
  });

  await assert.rejects(
    operator(undefined),
    (error: Error) => error.message === "migration_operator_failed" && !error.message.includes("operator-secret"),
  );
  assert.equal(events.some((event) => event.startsWith("runtime:")), false);
  assert.equal(pool.connectCount, 0);
  assert.equal(pool.endCount, 1);
});

test("uncertain credential initialization rolls back, evicts the checked-out connection, closes the pool, and emits no secret", async () => {
  const subject = await loadSubject();
  const events: string[] = [];
  const pool = new RecordingPool();
  pool.client.failAlterAt = 3;
  const consoleEvents: unknown[][] = [];
  const consoleMethods = ["debug", "error", "info", "log", "warn"] as const;
  const originalConsole = Object.fromEntries(consoleMethods.map((method) => [method, console[method]])) as
    Readonly<Record<typeof consoleMethods[number], (...args: unknown[]) => void>>;
  for (const method of consoleMethods) {
    console[method] = (...args: unknown[]) => { consoleEvents.push(args); };
  }
  try {
    const operator = subject.createMigrationOperator({
      configuration: configuration(),
      dependencies: dependencies(pool, events),
    });
    await assert.rejects(
      operator(undefined),
      (error: Error) => error.message === "migration_operator_failed" && !error.message.includes("operator-secret"),
    );
  } finally {
    for (const method of consoleMethods) console[method] = originalConsole[method];
  }
  assert.equal(pool.client.sql.includes("ROLLBACK"), true);
  assert.equal(pool.client.sql.includes("COMMIT"), false);
  assert.equal(pool.client.releaseErrors.length, 1);
  assert.equal(pool.endCount, 1);
  assert.doesNotMatch(JSON.stringify(consoleEvents), /secret|ALTER ROLE|MIGRATION_CHECKSUM/u);
});

test("configuration accepts only the exact ordered ledger and seven fixed runtime lanes before any secret or provider work", async () => {
  const subject = await loadSubject();
  const pool = new RecordingPool();
  const events: string[] = [];
  const wrongLedger = [...LEDGER];
  [wrongLedger[0], wrongLedger[1]] = [wrongLedger[1]!, wrongLedger[0]!];
  assert.throws(
    () => subject.createMigrationOperator({
      configuration: configuration({ expectedMigrations: wrongLedger }),
      dependencies: dependencies(pool, events),
    }),
    /migration_operator_configuration_invalid/u,
  );
  const missingRoleSecrets = { ...RUNTIME_SECRET_ARNS } as Record<string, string>;
  delete missingRoleSecrets.roomscan_email_delivery_runtime;
  assert.throws(
    () => subject.createMigrationOperator({
      configuration: configuration({ runtimeRoleSecretArns: missingRoleSecrets as RuntimeSecretArns }),
      dependencies: dependencies(pool, events),
    }),
    /migration_operator_configuration_invalid/u,
  );
  assert.deepEqual(events, []);
  assert.equal(pool.connectCount, 0);
  assert.equal(pool.endCount, 0);
});
