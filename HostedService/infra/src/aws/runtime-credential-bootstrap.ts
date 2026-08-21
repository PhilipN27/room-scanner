import {
  createHash,
  createHmac,
  pbkdf2Sync,
} from "node:crypto";

import type { DataApiClientPort } from "./runtime-clients.js";

export const RUNTIME_DATABASE_ROLES = Object.freeze([
  "roomscan_api_runtime",
  "roomscan_authorizer_runtime",
  "roomscan_auth_challenge_runtime",
  "roomscan_stripe_ingress_runtime",
  "roomscan_stripe_reconciliation_runtime",
  "roomscan_audit_export_runtime",
  "roomscan_email_delivery_runtime",
] as const);

export type RuntimeDatabaseRole = typeof RUNTIME_DATABASE_ROLES[number];

export interface RuntimeCredentialSecretReader {
  read(input: Readonly<{ readonly secretArn: string; readonly expectedUsername: RuntimeDatabaseRole }>): Promise<string>;
}

export interface ExpectedMigrationLedgerRow {
  readonly version: string;
  readonly name: string;
  readonly checksumSha256: string;
}

export class RuntimeCredentialBootstrapError extends Error {
  constructor(readonly code: "invalid_configuration" | "bootstrap_failed") {
    super(code);
    this.name = "RuntimeCredentialBootstrapError";
  }
}

/**
 * Owner-credential-only post-migration initializer. Password text is never
 * placed in SQL: the operator derives PostgreSQL's salted SCRAM verifier and
 * disables server statement/duration logging transaction-locally before any
 * ALTER ROLE. RDS Data API CloudTrail redacts SQL and database fields; an
 * authorized live rehearsal remains required before first runtime secret use.
 */
export async function initializeRuntimeRoleCredentials(input: Readonly<{
  readonly ownerClient: DataApiClientPort;
  readonly secretReader: RuntimeCredentialSecretReader;
  readonly secretArns: Readonly<Record<RuntimeDatabaseRole, string>>;
  readonly expectedMigrations: readonly ExpectedMigrationLedgerRow[];
  readonly randomBytes: (length: number) => Uint8Array;
}>): Promise<void> {
  assertConfiguration(input);
  let transactionId: string | undefined;
  let committed = false;
  try {
    transactionId = (await input.ownerClient.begin()).transactionId;
    await input.ownerClient.execute({
      transactionId,
      sql: "SET LOCAL log_statement = 'none'",
    });
    await input.ownerClient.execute({
      transactionId,
      sql: "SET LOCAL log_min_duration_statement = '-1'",
    });
    const ledger = await input.ownerClient.execute({
      transactionId,
      sql: "SELECT version, name, checksum_sha256 FROM public.roomscan_schema_migrations ORDER BY version",
    });
    assertExactLedger(ledger.rows, input.expectedMigrations);

    const credentials: Array<Readonly<{ role: RuntimeDatabaseRole; verifier: string }>> = [];
    for (const role of RUNTIME_DATABASE_ROLES) {
      const password = await input.secretReader.read({
        secretArn: input.secretArns[role],
        expectedUsername: role,
      });
      const salt = input.randomBytes(16);
      if (!(salt instanceof Uint8Array) || salt.length !== 16) {
        throw new RuntimeCredentialBootstrapError("bootstrap_failed");
      }
      credentials.push(Object.freeze({ role, verifier: scramSha256Verifier(password, salt) }));
    }

    for (const credential of credentials) {
      // `role` is selected only from the frozen compile-time allowlist and the
      // verifier grammar cannot contain a quote, semicolon, or whitespace.
      await input.ownerClient.execute({
        transactionId,
        sql: `ALTER ROLE ${credential.role} PASSWORD '${credential.verifier}'`,
      });
    }
    await input.ownerClient.commit(transactionId);
    committed = true;
  } catch {
    if (transactionId !== undefined && !committed) {
      try { await input.ownerClient.rollback(transactionId); } catch { /* fail closed; original outcome remains opaque */ }
    }
    throw new RuntimeCredentialBootstrapError("bootstrap_failed");
  }
}

export function scramSha256Verifier(password: string, salt: Uint8Array): string {
  if (!passwordValue(password) || !(salt instanceof Uint8Array) || salt.length !== 16) {
    throw new RuntimeCredentialBootstrapError("invalid_configuration");
  }
  const iterations = 4_096;
  const saltedPassword = pbkdf2Sync(password, salt, iterations, 32, "sha256");
  const clientKey = createHmac("sha256", saltedPassword).update("Client Key").digest();
  const storedKey = createHash("sha256").update(clientKey).digest();
  const serverKey = createHmac("sha256", saltedPassword).update("Server Key").digest();
  return `SCRAM-SHA-256$${iterations}:${Buffer.from(salt).toString("base64")}$${storedKey.toString("base64")}:${serverKey.toString("base64")}`;
}

function assertConfiguration(input: Parameters<typeof initializeRuntimeRoleCredentials>[0]): void {
  if (input === null || typeof input !== "object"
    || input.ownerClient === null || typeof input.ownerClient !== "object"
    || typeof input.ownerClient.begin !== "function" || typeof input.ownerClient.execute !== "function"
    || typeof input.ownerClient.commit !== "function" || typeof input.ownerClient.rollback !== "function"
    || input.secretReader === null || typeof input.secretReader !== "object" || typeof input.secretReader.read !== "function"
    || typeof input.randomBytes !== "function"
    || input.secretArns === null || typeof input.secretArns !== "object"
    || !Array.isArray(input.expectedMigrations) || input.expectedMigrations.length !== 7) {
    throw new RuntimeCredentialBootstrapError("invalid_configuration");
  }
  const secretKeys = Object.keys(input.secretArns).sort();
  const expectedRoles = [...RUNTIME_DATABASE_ROLES].sort();
  if (secretKeys.length !== expectedRoles.length || secretKeys.some((key, index) => key !== expectedRoles[index])) {
    throw new RuntimeCredentialBootstrapError("invalid_configuration");
  }
  for (const [index, migration] of input.expectedMigrations.entries()) {
    const expectedVersion = String(index + 1).padStart(4, "0");
    if (migration?.version !== expectedVersion || !/^[a-z0-9_]{1,128}$/u.test(migration.name)
      || !/^[a-f0-9]{64}$/u.test(migration.checksumSha256)) {
      throw new RuntimeCredentialBootstrapError("invalid_configuration");
    }
  }
  for (const role of RUNTIME_DATABASE_ROLES) {
    if (!secretArn(input.secretArns[role])) throw new RuntimeCredentialBootstrapError("invalid_configuration");
  }
}

function assertExactLedger(
  actual: readonly Readonly<Record<string, string | number | boolean | Uint8Array | null>>[],
  expected: readonly ExpectedMigrationLedgerRow[],
): void {
  if (actual.length !== expected.length) throw new RuntimeCredentialBootstrapError("bootstrap_failed");
  for (const [index, row] of actual.entries()) {
    const wanted = expected[index];
    if (wanted === undefined || row.version !== wanted.version || row.name !== wanted.name
      || row.checksum_sha256 !== wanted.checksumSha256) {
      throw new RuntimeCredentialBootstrapError("bootstrap_failed");
    }
  }
}

function passwordValue(value: unknown): value is string {
  return typeof value === "string" && value.length >= 32 && value.length <= 1_024
    && !/[\u0000\r\n]/u.test(value);
}

function secretArn(value: unknown): value is string {
  return typeof value === "string"
    && /^arn:aws:secretsmanager:us-east-1:\d{12}:secret:[A-Za-z0-9/_+=.@-]{1,512}$/u.test(value);
}
