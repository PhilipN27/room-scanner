import assert from "node:assert/strict";
import test from "node:test";

import {
  initializeRuntimeRoleCredentials,
  RUNTIME_DATABASE_ROLES,
  scramSha256Verifier,
  type RuntimeCredentialSecretReader,
} from "../src/aws/runtime-credential-bootstrap.js";
import type { DataApiClientPort, SqlResult } from "../src/aws/runtime-clients.js";

const migrations = Object.freeze(Array.from({ length: 7 }, (_, index) => Object.freeze({
  version: String(index + 1).padStart(4, "0"),
  name: `migration_${index + 1}`,
  checksumSha256: String(index + 1).repeat(64).slice(0, 64),
})));
const secretArns = Object.freeze(Object.fromEntries(RUNTIME_DATABASE_ROLES.map((role) => [
  role,
  `arn:aws:secretsmanager:us-east-1:111111111111:secret:${role}-AbCdEf`,
])) as Record<typeof RUNTIME_DATABASE_ROLES[number], string>);

class FakeOwnerClient implements DataApiClientPort {
  readonly events: string[] = [];
  readonly sql: string[] = [];
  failAlterAt: number | undefined;
  #alterCount = 0;
  ledger: SqlResult = { rows: migrations.map((migration) => ({
    version: migration.version,
    name: migration.name,
    checksum_sha256: migration.checksumSha256,
  })) };
  async begin(): Promise<{ readonly transactionId: string }> { this.events.push("begin"); return { transactionId: "tx_bootstrap" }; }
  async execute(input: { readonly transactionId: string; readonly sql: string }): Promise<SqlResult> {
    assert.equal(input.transactionId, "tx_bootstrap");
    this.events.push(input.sql.startsWith("ALTER ROLE") ? "alter" : input.sql.startsWith("SELECT version") ? "ledger" : "guard");
    this.sql.push(input.sql);
    if (input.sql.startsWith("ALTER ROLE") && this.failAlterAt === this.#alterCount++) throw new Error("PROVIDER_SENTINEL");
    return input.sql.startsWith("SELECT version") ? this.ledger : { rows: [] };
  }
  async commit(transactionId: string): Promise<void> { assert.equal(transactionId, "tx_bootstrap"); this.events.push("commit"); }
  async rollback(transactionId: string): Promise<void> { assert.equal(transactionId, "tx_bootstrap"); this.events.push("rollback"); }
}

class FakeSecretReader implements RuntimeCredentialSecretReader {
  readonly events: string[] = [];
  wrongRole: typeof RUNTIME_DATABASE_ROLES[number] | undefined;
  async read(input: { readonly secretArn: string; readonly expectedUsername: typeof RUNTIME_DATABASE_ROLES[number] }): Promise<string> {
    assert.equal(input.secretArn, secretArns[input.expectedUsername]);
    this.events.push(input.expectedUsername);
    if (input.expectedUsername === this.wrongRole) throw new Error("SECRET_SENTINEL");
    return `Password-${input.expectedUsername}-` + "x".repeat(48);
  }
}

test("credential bootstrap proves exact ledger before reading secrets and commits seven allowlisted SCRAM rotations", async () => {
  const client = new FakeOwnerClient(); const secrets = new FakeSecretReader();
  let salt = 0;
  await initializeRuntimeRoleCredentials({
    ownerClient: client, secretReader: secrets, secretArns, expectedMigrations: migrations,
    randomBytes: (length) => Uint8Array.from({ length }, () => ++salt),
  });
  assert.deepEqual(client.events, ["begin", "guard", "guard", "ledger", ...RUNTIME_DATABASE_ROLES.map(() => "alter"), "commit"]);
  assert.deepEqual(secrets.events, RUNTIME_DATABASE_ROLES);
  assert.equal(client.sql[0], "SET LOCAL log_statement = 'none'");
  assert.equal(client.sql[1], "SET LOCAL log_min_duration_statement = '-1'");
  const alters = client.sql.filter((sql) => sql.startsWith("ALTER ROLE"));
  assert.equal(alters.length, 7);
  for (const [index, role] of RUNTIME_DATABASE_ROLES.entries()) {
    assert.match(alters[index]!, new RegExp(`^ALTER ROLE ${role} PASSWORD 'SCRAM-SHA-256\\$4096:`, "u"));
    assert.doesNotMatch(alters[index]!, /Password-/u);
  }
  assert.equal(JSON.stringify(client.events).includes("Password-"), false);
});

test("ledger mismatch and secret failure fail closed, rollback once, and expose no secret or provider error", async () => {
  const ledgerClient = new FakeOwnerClient(); const ledgerSecrets = new FakeSecretReader();
  ledgerClient.ledger = { rows: ledgerClient.ledger.rows.slice(0, 6) };
  await assert.rejects(
    initializeRuntimeRoleCredentials({ ownerClient: ledgerClient, secretReader: ledgerSecrets, secretArns, expectedMigrations: migrations, randomBytes: (n) => new Uint8Array(n) }),
    (error: Error) => error.message === "bootstrap_failed" && !error.message.includes("Password"),
  );
  assert.deepEqual(ledgerClient.events, ["begin", "guard", "guard", "ledger", "rollback"]);
  assert.deepEqual(ledgerSecrets.events, []);

  const secretClient = new FakeOwnerClient(); const failedSecrets = new FakeSecretReader();
  failedSecrets.wrongRole = "roomscan_stripe_ingress_runtime";
  await assert.rejects(
    initializeRuntimeRoleCredentials({ ownerClient: secretClient, secretReader: failedSecrets, secretArns, expectedMigrations: migrations, randomBytes: (n) => new Uint8Array(n) }),
    (error: Error) => error.message === "bootstrap_failed" && !error.message.includes("SECRET_SENTINEL"),
  );
  assert.equal(secretClient.events.includes("alter"), false);
  assert.deepEqual(secretClient.events.at(-1), "rollback");
});

test("an ALTER failure rolls back all rotations and the SCRAM oracle is deterministic without retaining plaintext", async () => {
  const client = new FakeOwnerClient(); const secrets = new FakeSecretReader(); client.failAlterAt = 3;
  await assert.rejects(
    initializeRuntimeRoleCredentials({ ownerClient: client, secretReader: secrets, secretArns, expectedMigrations: migrations, randomBytes: (n) => new Uint8Array(n).fill(7) }),
    (error: Error) => error.message === "bootstrap_failed" && !error.message.includes("PROVIDER_SENTINEL"),
  );
  assert.deepEqual(client.events.at(-1), "rollback");
  assert.equal(client.events.includes("commit"), false);
  const verifier = scramSha256Verifier("A-secure-generated-password-value-123", new Uint8Array(16).fill(9));
  assert.equal(verifier, scramSha256Verifier("A-secure-generated-password-value-123", new Uint8Array(16).fill(9)));
  assert.match(verifier, /^SCRAM-SHA-256\$4096:[A-Za-z0-9+/]+=*\$[A-Za-z0-9+/]+=*:[A-Za-z0-9+/]+=*$/u);
  assert.doesNotMatch(verifier, /secure-generated-password/u);
});
