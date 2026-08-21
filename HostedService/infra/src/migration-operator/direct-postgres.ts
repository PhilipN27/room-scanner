import {
  RUNTIME_DATABASE_ROLES,
  scramSha256Verifier,
  type ExpectedMigrationLedgerRow,
  type RuntimeCredentialSecretReader,
  type RuntimeDatabaseRole,
} from "../aws/runtime-credential-bootstrap.js";

export interface DirectPostgresQueryResult {
  readonly rows: readonly Readonly<Record<string, unknown>>[];
}

/** Minimal direct-PostgreSQL seam. It intentionally excludes arbitrary SQL,
 * pool construction, telemetry, and request-body handling. */
export interface DirectPostgresClient {
  query(sql: string): Promise<DirectPostgresQueryResult>;
  release(error?: Error): void;
}

export interface DirectPostgresPool {
  connect(): Promise<DirectPostgresClient>;
  end(): Promise<void>;
}

export class DirectPostgresCredentialBootstrapError extends Error {
  constructor(readonly code: "invalid_configuration" | "bootstrap_failed") {
    super(code);
    this.name = "DirectPostgresCredentialBootstrapError";
  }
}

/**
 * Applies the password verifier only after `applyMigrations` has committed.
 * Secrets are read before the database transaction begins: the platform ADR
 * prohibits external/provider calls while a database transaction is open.
 *
 * The only generated SQL is an ALTER for a compile-time allowlisted role and a
 * derived SCRAM verifier. Plaintext secrets and raw migration SQL never cross
 * this helper's error or logging surface.
 */
export async function initializeRuntimeRoleCredentialsWithPostgres(input: Readonly<{
  readonly pool: DirectPostgresPool;
  readonly secretReader: RuntimeCredentialSecretReader;
  readonly secretArns: Readonly<Record<RuntimeDatabaseRole, string>>;
  readonly expectedMigrations: readonly ExpectedMigrationLedgerRow[];
  readonly randomBytes: (length: number) => Uint8Array;
}>): Promise<void> {
  assertConfiguration(input);

  const credentials = await collectCredentials(input);
  let client: DirectPostgresClient | undefined;
  let transactionOpen = false;
  let released = false;
  try {
    client = await input.pool.connect();
    await client.query("BEGIN");
    transactionOpen = true;
    await client.query("SET LOCAL log_statement = 'none'");
    await client.query("SET LOCAL log_min_duration_statement = '-1'");
    const ledger = await client.query(
      "SELECT version, name, checksum_sha256 FROM public.roomscan_schema_migrations ORDER BY version",
    );
    assertExactLedger(ledger.rows, input.expectedMigrations);

    for (const credential of credentials) {
      // Role names come only from RUNTIME_DATABASE_ROLES. SCRAM verifier grammar
      // excludes quotes, separators, whitespace, and the plaintext password.
      await client.query(`ALTER ROLE ${credential.role} PASSWORD '${credential.verifier}'`);
    }
    await client.query("COMMIT");
    transactionOpen = false;
  } catch {
    if (client !== undefined) {
      if (transactionOpen) {
        try { await client.query("ROLLBACK"); } catch { /* the client is evicted below */ }
      }
      // Any failed bootstrap is conservatively treated as uncertain. Releasing
      // with an error prevents node-postgres from returning it to a pool.
      client.release(new DirectPostgresCredentialBootstrapError("bootstrap_failed"));
      released = true;
    }
    throw new DirectPostgresCredentialBootstrapError("bootstrap_failed");
  } finally {
    if (client !== undefined && !released) client.release();
  }
}

async function collectCredentials(input: Parameters<typeof initializeRuntimeRoleCredentialsWithPostgres>[0]): Promise<readonly Readonly<{
  readonly role: RuntimeDatabaseRole;
  readonly verifier: string;
}>[]> {
  const credentials: Array<Readonly<{ role: RuntimeDatabaseRole; verifier: string }>> = [];
  try {
    for (const role of RUNTIME_DATABASE_ROLES) {
      const password = await input.secretReader.read({
        secretArn: input.secretArns[role],
        expectedUsername: role,
      });
      const salt = input.randomBytes(16);
      if (!(salt instanceof Uint8Array) || salt.length !== 16) {
        throw new DirectPostgresCredentialBootstrapError("bootstrap_failed");
      }
      credentials.push(Object.freeze({ role, verifier: scramSha256Verifier(password, salt) }));
    }
  } catch {
    throw new DirectPostgresCredentialBootstrapError("bootstrap_failed");
  }
  return Object.freeze(credentials);
}

function assertConfiguration(input: Parameters<typeof initializeRuntimeRoleCredentialsWithPostgres>[0]): void {
  if (input === null || typeof input !== "object"
    || input.pool === null || typeof input.pool !== "object"
    || typeof input.pool.connect !== "function" || typeof input.pool.end !== "function"
    || input.secretReader === null || typeof input.secretReader !== "object" || typeof input.secretReader.read !== "function"
    || typeof input.randomBytes !== "function"
    || input.secretArns === null || typeof input.secretArns !== "object"
    || !Array.isArray(input.expectedMigrations) || input.expectedMigrations.length !== 7) {
    throw new DirectPostgresCredentialBootstrapError("invalid_configuration");
  }
  const keys = Object.keys(input.secretArns).sort();
  const roles = [...RUNTIME_DATABASE_ROLES].sort();
  if (keys.length !== roles.length || keys.some((key, index) => key !== roles[index])) {
    throw new DirectPostgresCredentialBootstrapError("invalid_configuration");
  }
  for (const [index, migration] of input.expectedMigrations.entries()) {
    if (migration?.version !== String(index + 1).padStart(4, "0")
      || !/^\d{4}_[a-z0-9_]+\.up\.sql$/u.test(migration.name)
      || !/^[a-f0-9]{64}$/u.test(migration.checksumSha256)
      || !secretArn(input.secretArns[RUNTIME_DATABASE_ROLES[index]!])) {
      throw new DirectPostgresCredentialBootstrapError("invalid_configuration");
    }
  }
}

function assertExactLedger(
  actual: readonly Readonly<Record<string, unknown>>[],
  expected: readonly ExpectedMigrationLedgerRow[],
): void {
  if (actual.length !== expected.length) throw new DirectPostgresCredentialBootstrapError("bootstrap_failed");
  for (const [index, row] of actual.entries()) {
    const wanted = expected[index];
    if (wanted === undefined || row.version !== wanted.version || row.name !== wanted.name
      || row.checksum_sha256 !== wanted.checksumSha256) {
      throw new DirectPostgresCredentialBootstrapError("bootstrap_failed");
    }
  }
}

function secretArn(value: unknown): value is string {
  return typeof value === "string"
    && /^arn:aws:secretsmanager:us-east-1:\d{12}:secret:[A-Za-z0-9/_+=.@-]{1,512}$/u.test(value);
}
