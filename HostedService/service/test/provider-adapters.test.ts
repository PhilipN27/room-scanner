import assert from "node:assert/strict";
import test from "node:test";
import { AppleCodeExchangeHttpAdapter, APPLE_TOKEN_URL } from "../src/adapters/apple-exchange.js";
import * as cognitoAdapters from "../src/adapters/cognito-custom-auth.js";
import { CognitoCustomChallengeAdapter, CognitoServerBridge, type BoundCustomChallenge, type CreateAuthChallengeEvent, type DefineAuthChallengeEvent, type VerifyAuthChallengeEvent } from "../src/adapters/cognito-custom-auth.js";
import { DataApiTransactionExecutor, DataApiTransactionError, type DataApiClient, type SqlResult } from "../src/adapters/data-api.js";
import { deriveAuthorizedQuarantineScope, QuarantineAllocationService } from "../src/adapters/s3-quarantine.js";
import { SesDeliveryAdapter, type AuditOutboxLeasePort } from "../src/adapters/ses-delivery.js";
import { AllowlistAuditAdapter } from "../src/adapters/allowlist-audit.js";
import { findCanaryLeaks } from "../privacy-logger.js";

const principalId = "11111111-1111-4111-8111-111111111111"; const familyId = "22222222-2222-4222-8222-222222222222"; const workspaceId = "33333333-3333-4333-8333-333333333333";
const scopedRow = { principal_id: principalId, canonical_principal_id: "principal-public", family_id: familyId, family_public_id: "family-public", workspace_id: workspaceId, role: "owner", authorization_version: 7, authentication_epoch: 2, authenticated_at: "2030-01-01T00:00:00.000Z", recent_authentication: true } as const;
class DataFake implements DataApiClient { readonly calls: Array<{ op: string; input?: unknown }> = []; readonly ids: string[] = ["tx-1"]; result: SqlResult = { rows: [scopedRow] }; failSql?: string; async begin() { const transactionId = this.ids.shift() ?? "tx-new"; this.calls.push({ op: "begin", input: transactionId }); return { transactionId }; } async execute(input: Parameters<DataApiClient["execute"]>[0]) { this.calls.push({ op: "execute", input }); if (input.sql === this.failSql) throw new Error("provider"); return input.sql.includes("resolve_access_context") ? this.result : { rows: [] }; } async commit(id: string) { this.calls.push({ op: "commit", input: id }); } async rollback(id: string) { this.calls.push({ op: "rollback", input: id }); } }
const systemAuthorizer = { authorize: async ({ capability }: { capability: unknown }) => capability === "minted" };
const clearRequestContextSql = "SELECT set_config('app.principal_id', '', true), set_config('app.tenant_id', '', true), set_config('app.authorization_version', '', true)";

test("Data API clears inherited request context before access resolution and system SQL", async () => {
  const accessClient = new DataFake();
  await new DataApiTransactionExecutor(accessClient, systemAuthorizer)
    .accessTransaction(new Uint8Array(32), new Date(0), async (unit) => unit.execute({ sql: "SELECT access_work" }));
  const accessStatements = accessClient.calls
    .filter((call) => call.op === "execute")
    .map((call) => call.input as Parameters<DataApiClient["execute"]>[0]);
  assert.equal(accessStatements[0]?.sql, clearRequestContextSql);
  assert.equal(accessStatements[0]?.parameters, undefined);
  assert.match(accessStatements[1]?.sql ?? "", /roomscan\.resolve_access_context/u);
  assert.equal(accessStatements.at(-1)?.sql, "SELECT access_work");

  const systemClient = new DataFake();
  await new DataApiTransactionExecutor(systemClient, systemAuthorizer)
    .systemTransaction("minted", "system.audit.write", async (unit) => unit.execute({ sql: "SELECT system_work" }));
  const systemStatements = systemClient.calls
    .filter((call) => call.op === "execute")
    .map((call) => call.input as Parameters<DataApiClient["execute"]>[0]);
  assert.deepEqual(systemStatements.map((statement) => statement.sql), [clearRequestContextSql, "SELECT system_work"]);
  assert.equal(systemStatements[0]?.parameters, undefined);
});
test("Data API rolls back without access resolution or system work when request-context clearing fails", async () => {
  for (const kind of ["access", "system"] as const) {
    const client = new DataFake();
    client.failSql = clearRequestContextSql;
    const executor = new DataApiTransactionExecutor(client, systemAuthorizer);
    let workCalled = false;
    const transaction = kind === "access"
      ? executor.accessTransaction(new Uint8Array(32), new Date(0), async () => { workCalled = true; })
      : executor.systemTransaction("minted", "system.audit.write", async () => { workCalled = true; });
    await assert.rejects(transaction, { code: "transaction_failed" });
    assert.equal(workCalled, false);
    assert.deepEqual(client.calls.map((call) => call.op), ["begin", "execute", "rollback"]);
    assert.equal((client.calls[1]?.input as Parameters<DataApiClient["execute"]>[0]).sql, clearRequestContextSql);
  }
});
test("Data API sends an offset-independent ISO string and explicitly casts it to timestamptz", async () => { const client = new DataFake(); const executor = new DataApiTransactionExecutor(client, systemAuthorizer); const digest = Uint8Array.from({ length: 32 }, (_, i) => i); let seenWorkspace: string | undefined; await executor.accessTransaction(digest, new Date("2029-12-31T19:00:00-05:00"), async (unit) => { seenWorkspace = unit.context.workspaceInternalId; await unit.execute({ sql: "SELECT 1" }); }); assert.equal(seenWorkspace, workspaceId); const resolve = client.calls.find((x) => x.op === "execute" && (x.input as Parameters<DataApiClient["execute"]>[0]).sql.includes("resolve_access_context"))?.input as Parameters<DataApiClient["execute"]>[0]; assert.equal(resolve.sql.includes("workspace_id"), true); assert.equal(resolve.sql.includes("tenant_id"), false); assert.match(resolve.sql, /\(:authoritative_now\)::timestamptz/u); assert.deepEqual(resolve.parameters?.[0]?.value, { kind: "blob", bytes: digest }); assert.deepEqual(resolve.parameters?.[1]?.value, { kind: "string", value: "2030-01-01T00:00:00.000Z" }); assert.deepEqual(client.calls.map((x) => x.op), ["begin", "execute", "execute", "execute", "execute", "execute", "execute", "commit"]); });
test("Data API accepts an unscoped session and transaction-locally shadows all three GUCs", async () => { const client = new DataFake(); client.result = { rows: [{ ...scopedRow, workspace_id: null, role: null, authorization_version: null }] }; const executor = new DataApiTransactionExecutor(client, systemAuthorizer); const context = await executor.accessTransaction(new Uint8Array(32), new Date(0), async (unit) => unit.context); assert.equal((context as unknown as { workspaceInternalId?: string }).workspaceInternalId, undefined); const settings = client.calls.filter((x) => x.op === "execute").slice(2).map((x) => x.input as Parameters<DataApiClient["execute"]>[0]); assert.equal(settings.length, 3); assert.deepEqual(settings.map((x) => x.parameters?.[0]?.value), [{ kind: "string", value: principalId, typeHint: "UUID" }, { kind: "string", value: "" }, { kind: "string", value: "" }]); });
test("Data API accepts authentication epoch zero but rejects negative and unsafe epochs", async () => {
  const zeroClient = new DataFake();
  zeroClient.result = { rows: [{ ...scopedRow, authentication_epoch: 0 }] };
  const zeroContext = await new DataApiTransactionExecutor(zeroClient, systemAuthorizer)
    .accessTransaction(new Uint8Array(32), new Date(0), async (unit) => unit.context);
  assert.equal(zeroContext.authenticationEpoch, 0);

  for (const authenticationEpoch of [-1, Number.MAX_SAFE_INTEGER + 1]) {
    const invalidClient = new DataFake();
    invalidClient.result = { rows: [{ ...scopedRow, authentication_epoch: authenticationEpoch }] };
    await assert.rejects(
      new DataApiTransactionExecutor(invalidClient, systemAuthorizer)
        .accessTransaction(new Uint8Array(32), new Date(0), async () => undefined),
      { code: "invalid_access" },
    );
    assert.equal(invalidClient.calls.at(-1)?.op, "rollback");
  }

  const zeroAuthorizationClient = new DataFake();
  zeroAuthorizationClient.result = { rows: [{ ...scopedRow, authentication_epoch: 0, authorization_version: 0 }] };
  await assert.rejects(
    new DataApiTransactionExecutor(zeroAuthorizationClient, systemAuthorizer)
      .accessTransaction(new Uint8Array(32), new Date(0), async () => undefined),
    { code: "invalid_access" },
  );
  assert.equal(zeroAuthorizationClient.calls.at(-1)?.op, "rollback");
});
test("Data API rejects malformed/missing context and rolls back", async () => { const client = new DataFake(); client.result = { rows: [] }; const executor = new DataApiTransactionExecutor(client, systemAuthorizer); await assert.rejects(executor.accessTransaction(new Uint8Array(32), new Date(0), async () => undefined), (error: unknown) => error instanceof DataApiTransactionError && error.code === "invalid_access"); assert.equal(client.calls.at(-1)?.op, "rollback"); });
test("Data API rejects and cleans up a sequentially reused just-begun transaction ID", async () => { const client = new DataFake(); client.ids.push("tx-1"); const executor = new DataApiTransactionExecutor(client, systemAuthorizer); await executor.accessTransaction(new Uint8Array(32), new Date(0), async () => undefined); await assert.rejects(executor.accessTransaction(new Uint8Array(32), new Date(0), async () => undefined), { code: "duplicate_transaction" }); assert.equal(client.calls.filter((x) => x.op === "rollback").length, 1); });
test("Data API rejects concurrently reused provider transaction IDs without rolling back the owner", async () => { const client = new DataFake(); client.ids.push("tx-1"); const executor = new DataApiTransactionExecutor(client, systemAuthorizer); let release!: () => void; const gate = new Promise<void>((resolve) => { release = resolve; }); const owner = executor.accessTransaction(new Uint8Array(32), new Date(0), async () => gate); await new Promise<void>((resolve) => setImmediate(resolve)); await assert.rejects(executor.accessTransaction(new Uint8Array(32), new Date(0), async () => undefined), { code: "duplicate_transaction" }); assert.equal(client.calls.filter((x) => x.op === "rollback").length, 0); release(); await owner; });
test("Data API transaction-ID reuse state stays fixed-size under stress and remembers the oldest ID", async () => {
  let sequence = 0;
  let forcedId: string | undefined;
  const rollbacks: string[] = [];
  const client: DataApiClient = {
    begin: async () => ({ transactionId: forcedId ?? `tx-stress-${sequence++}` }),
    execute: async () => ({ rows: [] }),
    commit: async () => undefined,
    rollback: async (transactionId) => { rollbacks.push(transactionId); },
  };
  const executor = new DataApiTransactionExecutor(client, systemAuthorizer);
  const internals = executor as unknown as {
    readonly seenTransactionIds?: Set<string>;
    readonly transactionIdReuseLedger?: { readonly byteLength: number };
  };
  const expectedFixedBytes = 1_048_576;

  for (let index = 0; index < 20_000; index++) {
    await executor.systemTransaction("minted", "system.audit.write", async () => undefined);
  }

  assert.equal(internals.seenTransactionIds instanceof Set, false, "executor must not retain an unbounded exact-ID Set");
  assert.equal(internals.transactionIdReuseLedger?.byteLength, expectedFixedBytes);
  forcedId = "tx-stress-0";
  await assert.rejects(
    executor.systemTransaction("minted", "system.audit.write", async () => undefined),
    { code: "duplicate_transaction" },
  );
  assert.deepEqual(rollbacks, ["tx-stress-0"]);
  assert.equal(internals.transactionIdReuseLedger?.byteLength, expectedFixedBytes);
});
test("system transaction requires the Task5-compatible system authorizer and exposes SQL only", async () => { const client = new DataFake(); const executor = new DataApiTransactionExecutor(client, systemAuthorizer); await assert.rejects(executor.systemTransaction("forged", "system.audit.write", async () => undefined), { code: "invalid_system_capability" }); await executor.systemTransaction("minted", "system.audit.write", async (unit) => { assert.deepEqual(Object.keys(unit), ["execute"]); await unit.execute({ sql: "SELECT 1" }); }); assert.equal(client.calls.some((x) => JSON.stringify(x).includes("app.system_capability_id")), false); });
test("Data API serializes concurrently requested statements and exposes explicit internal/public identity names", async () => { let active = 0; let maximum = 0; const order: string[] = []; const client: DataApiClient = { begin: async () => ({ transactionId: "tx-serialized" }), execute: async (input) => { active++; maximum = Math.max(maximum, active); order.push(`start:${input.sql}`); await new Promise<void>((resolve) => setImmediate(resolve)); order.push(`end:${input.sql}`); active--; return { rows: input.sql.includes("resolve_access_context") ? [scopedRow] : [] }; }, commit: async () => undefined, rollback: async () => undefined }; const executor = new DataApiTransactionExecutor(client, systemAuthorizer); const context = await executor.accessTransaction(new Uint8Array(32), new Date(0), async (unit) => { await Promise.all([unit.execute({ sql: "SELECT first" }), unit.execute({ sql: "SELECT second" })]); return unit.context; }); assert.equal(maximum, 1); assert.ok(order.indexOf("end:SELECT first") < order.indexOf("start:SELECT second")); assert.deepEqual({ principalInternalId: (context as unknown as Record<string, unknown>).principalInternalId, principalPublicId: (context as unknown as Record<string, unknown>).principalPublicId, familyInternalId: (context as unknown as Record<string, unknown>).familyInternalId, familyPublicId: context.familyPublicId }, { principalInternalId: principalId, principalPublicId: "principal-public", familyInternalId: familyId, familyPublicId: "family-public" }); assert.equal("principalId" in context, false); assert.equal("canonicalPrincipalId" in context, false); });
test("Data API poisons and rolls back a transaction even when a caller catches an undefined provider rejection", async () => { const calls: string[] = []; const client: DataApiClient = { begin: async () => ({ transactionId: "tx-undefined-rejection" }), execute: async (input) => { if (input.sql.includes("resolve_access_context")) return { rows: [scopedRow] }; if (input.sql === "SELECT rejected") return Promise.reject(undefined); return { rows: [] }; }, commit: async () => { calls.push("commit"); }, rollback: async () => { calls.push("rollback"); } }; const executor = new DataApiTransactionExecutor(client, systemAuthorizer); await assert.rejects(executor.accessTransaction(new Uint8Array(32), new Date(0), async (unit) => { await unit.execute({ sql: "SELECT rejected" }).catch(() => undefined); })); assert.deepEqual(calls, ["rollback"]); });

test("Apple exchange emits exact official form keys and bounded transport controls", async () => { let seen: Parameters<NonNullable<ConstructorParameters<typeof AppleCodeExchangeHttpAdapter>[0]["transport"]>["request"]>[0] | undefined; const adapter = appleAdapter(async (input) => { seen = input; return appleSuccess(); }); assert.equal((await adapter.exchange({ code: "code", codeVerifier: "v".repeat(43), clientId: "client", redirectUri: "https://rooms.example/callback" })).idToken, "header.payload.signature"); assert.equal(seen?.url, APPLE_TOKEN_URL); assert.deepEqual([...new URLSearchParams(Buffer.from(seen!.body).toString()).keys()].sort(), ["client_id", "client_secret", "code", "grant_type", "redirect_uri"]); assert.equal(seen?.followRedirects, false); });
test("Apple exchange fails closed for timeout/secret/error/size/content-type/fatal UTF-8", async () => { const cases = [async () => { throw new Error("timeout"); }, async () => ({ status: 302, headers: { "content-type": "application/json" }, body: new Uint8Array() }), async () => ({ status: 200, headers: { "content-type": "text/html" }, body: Buffer.from("{}") }), async () => ({ status: 200, headers: { "content-type": "application/json" }, body: new Uint8Array([0xff]) }), async () => ({ status: 200, headers: { "content-type": "application/json" }, body: Buffer.alloc(2049) })]; for (const transport of cases) await assert.rejects(appleAdapter(transport).exchange({ code: "code", codeVerifier: "v".repeat(43), clientId: "client", redirectUri: "https://rooms.example/callback" }), { code: "exchange_failed" }); const brokenSecret = new AppleCodeExchangeHttpAdapter({ transport: { request: async () => appleSuccess() }, secrets: { read: async () => { throw new Error("secret"); } }, clientSecretName: "apple/client", timeoutMs: 1000, maxResponseBytes: 2048 }); await assert.rejects(brokenSecret.exchange({ code: "code", codeVerifier: "v".repeat(43), clientId: "client", redirectUri: "https://rooms.example/callback" }), { code: "exchange_failed" }); });

test("Cognito exact Define/Create/Verify shapes preserve proof binding and synthetic nondisclosure", async () => { const known = challenge(false); const synthetic = challenge(true); let deliveries = 0; const adapter = new CognitoCustomChallengeAdapter({ createKnown: async () => { deliveries++; return known; }, createSyntheticWithoutDelivery: async () => synthetic, verify: async (input) => !input.synthetic && input.attemptId === "attempt" && input.purpose === "sign-in" && input.proof === "proof" }); const knownCreated = await adapter.create(createEvent(false)); const syntheticCreated = await adapter.create(createEvent(true)); assert.equal(deliveries, 1); assert.deepEqual(Object.keys(knownCreated.response.publicChallengeParameters ?? {}), Object.keys(syntheticCreated.response.publicChallengeParameters ?? {})); const verified = await adapter.verify(verifyEvent(knownCreated.response.privateChallengeParameters!, "answer")); assert.equal(verified.response.answerCorrect, true); assert.equal("failAuthentication" in verified.response, false); const exhausted = adapter.define(defineEvent([{ challengeName: "CUSTOM_CHALLENGE", challengeResult: false }, { challengeName: "CUSTOM_CHALLENGE", challengeResult: false }, { challengeName: "CUSTOM_CHALLENGE", challengeResult: false }])); assert.equal(exhausted.response.failAuthentication, true); });
test("Apple API bridge mints app tokens, waits for challenge issuance, discards Cognito tokens, then resolves its own access hash", async () => {
  type Challenge = {
    readonly kind: "roomscan-apple-session-v1";
    readonly attemptId: string;
    readonly purpose: "sign-in";
    readonly bridgeProof: string;
    readonly familyPublicId: string;
    readonly accessTokenHash: string;
    readonly refreshTokenHash: string;
    readonly authenticatedAt: string;
    readonly issuedAt: string;
    readonly accessExpiresAt: string;
    readonly inactivityExpiresAt: string;
    readonly absoluteExpiresAt: string;
    readonly policyVersion: string;
  };
  const ChallengeBridge = (cognitoAdapters as unknown as {
    CognitoAuthChallengeBridge?: new (sessions: unknown) => {
      consumeAndIssue(challenge: Challenge): Promise<{ readonly principalCanonicalId: string; readonly familyPublicId: string }>;
    };
  }).CognitoAuthChallengeBridge;
  assert.equal(typeof ChallengeBridge, "function");
  const order: string[] = [];
  let consumed = false;
  const challengeBridge = new ChallengeBridge!({
    consumeAppleBridgeAndIssueSession: async (input: { readonly familyPublicId: string; readonly accessTokenHash: Uint8Array; readonly refreshTokenHash: Uint8Array }) => {
      order.push("challenge-issue");
      assert.equal(input.familyPublicId, "fam_server_generated_1");
      assert.deepEqual(Buffer.from(input.accessTokenHash), Buffer.alloc(32, 0xa1));
      assert.deepEqual(Buffer.from(input.refreshTokenHash), Buffer.alloc(32, 0xb2));
      if (consumed) return { status: "unavailable" as const };
      consumed = true;
      return {
        status: "issued" as const,
        principalInternalId: "11111111-1111-4111-8111-111111111111",
        principalCanonicalId: "prn_app_owned",
        familyInternalId: "22222222-2222-4222-8222-222222222222",
        familyPublicId: "fam_server_generated_1",
        authenticationEpoch: 4,
        authenticatedAt: "2030-01-01T00:00:00.000Z",
      };
    },
  });
  const rawAccess = Buffer.alloc(32, 0xc3).toString("base64url");
  const rawRefresh = Buffer.alloc(32, 0xd4).toString("base64url");
  const material = {
    familyPublicId: "fam_server_generated_1",
    accessToken: rawAccess,
    accessTokenHash: Buffer.alloc(32, 0xa1),
    refreshToken: rawRefresh,
    refreshTokenHash: Buffer.alloc(32, 0xb2),
    authenticatedAt: new Date("2030-01-01T00:00:00.000Z"),
    issuedAt: new Date("2030-01-01T00:00:01.000Z"),
    accessExpiresAt: new Date("2030-01-01T00:05:01.000Z"),
    inactivityExpiresAt: new Date("2030-01-08T00:00:01.000Z"),
    absoluteExpiresAt: new Date("2030-01-31T00:00:01.000Z"),
    policyVersion: "session-v1",
  };
  let resolverCalls = 0;
  const Bridge = CognitoServerBridge as unknown as new (dependencies: unknown) => {
    authenticate(input: { readonly issuer: string; readonly subject: string; readonly internalProof: string; readonly attemptId: string; readonly purpose: "sign-in" }): Promise<unknown>;
  };
  const bridge = new Bridge({
    sessionMaterials: { mint: async () => { order.push("mint"); return material; } },
    admin: {
      adminAuthenticate: async (input: { readonly challenge: Challenge }) => {
        order.push("admin");
        await challengeBridge.consumeAndIssue(input.challenge);
        order.push("admin-success");
        return { outcome: "authenticated", accessToken: "cognito-must-not-escape" };
      },
      adminLink: async () => undefined,
    },
    issuedSessions: {
      resolveIssuedAccess: async (input: { readonly accessTokenHash: Uint8Array }) => {
        order.push("resolve"); resolverCalls++;
        assert.deepEqual(Buffer.from(input.accessTokenHash), Buffer.from(material.accessTokenHash));
        return { principalCanonicalId: "prn_app_owned", familyPublicId: material.familyPublicId };
      },
    },
    clock: { now: () => new Date("2030-01-01T00:00:02.000Z") },
  });
  const input = { issuer: "https://appleid.apple.com", subject: "apple-subject", internalProof: Buffer.alloc(32, 9).toString("base64url"), attemptId: "attempt-12345678", purpose: "sign-in" as const };
  const issued = await bridge.authenticate(input);
  assert.deepEqual(issued, {
    principalCanonicalId: "prn_app_owned",
    familyPublicId: material.familyPublicId,
    accessToken: rawAccess,
    refreshToken: rawRefresh,
    accessExpiresAt: material.accessExpiresAt.toISOString(),
    refreshInactivityExpiresAt: material.inactivityExpiresAt.toISOString(),
    refreshAbsoluteExpiresAt: material.absoluteExpiresAt.toISOString(),
  });
  assert.deepEqual(order, ["mint", "admin", "challenge-issue", "admin-success", "resolve"]);
  assert.equal(resolverCalls, 1);
  assert.doesNotMatch(JSON.stringify(issued), /cognito-must-not-escape/u);
  await assert.rejects(bridge.authenticate(input), { code: "invalid_bridge_proof" });
  assert.equal(resolverCalls, 1, "replayed bridge proof must fail in challenge lane before API resolution");
});

test("auth-challenge session issuance is atomic and rejects a replay before a second app session", async () => {
  const Bridge = (cognitoAdapters as unknown as {
    CognitoAuthChallengeBridge: new (sessions: unknown) => { consumeAndIssue(input: unknown): Promise<unknown> };
  }).CognitoAuthChallengeBridge;
  let calls = 0;
  const bridge = new Bridge({
    consumeAppleBridgeAndIssueSession: async () => {
      calls++;
      if (calls > 1) return { status: "unavailable" as const };
      return { status: "issued" as const, principalInternalId: principalId, principalCanonicalId: "prn_app_owned", familyInternalId: familyId, familyPublicId: "fam_server_generated_1", authenticationEpoch: 4, authenticatedAt: "2030-01-01T00:00:00.000Z" };
    },
  });
  const challengeInput = {
    kind: "roomscan-apple-session-v1", attemptId: "attempt-12345678", purpose: "sign-in",
    bridgeProof: Buffer.alloc(32, 9).toString("base64url"), familyPublicId: "fam_server_generated_1",
    accessTokenHash: Buffer.alloc(32, 0xa1).toString("base64url"), refreshTokenHash: Buffer.alloc(32, 0xb2).toString("base64url"),
    authenticatedAt: "2030-01-01T00:00:00.000Z", issuedAt: "2030-01-01T00:00:01.000Z",
    accessExpiresAt: "2030-01-01T00:05:01.000Z", inactivityExpiresAt: "2030-01-08T00:00:01.000Z",
    absoluteExpiresAt: "2030-01-31T00:00:01.000Z", policyVersion: "session-v1",
  };
  await assert.rejects(bridge.consumeAndIssue({ ...challengeInput, familyPublicId: "fam.invalid.metadata" }), { code: "invalid_bridge_proof" });
  assert.equal(calls, 0, "malformed server exchange metadata must not reach session issuance");
  assert.deepEqual(await bridge.consumeAndIssue(challengeInput), { principalCanonicalId: "prn_app_owned", familyPublicId: "fam_server_generated_1" });
  await assert.rejects(bridge.consumeAndIssue(challengeInput), { code: "invalid_bridge_proof" });
  assert.equal(calls, 2);
});

test("S3 accepts only branded authorized scope and exact signed PUT headers", async () => { const scope = deriveAuthorizedQuarantineScope({ principalId: "p", familyId: "f", workspaceId: "workspace-a", role: "owner", authorizationVersion: 1 }); let input: Parameters<ConstructorParameters<typeof QuarantineAllocationService>[0]["presigner"]["presignPut"]>[0] | undefined; const service = new QuarantineAllocationService({ random: { bytes: () => Buffer.alloc(32, 7) }, presigner: { presignPut: async (value) => { input = value; return put(value); } }, maxBytes: 100, maxLifetimeSeconds: 300 }); const result = await service.allocate(scope, { contentLength: 10, checksumSha256: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", contentType: "application/zip" }); assert.match(result.key, /^server\/quarantine\/v1\/[a-f0-9]{24}\//); assert.equal(input?.ifNoneMatch, "*"); const substitutionProbe = new QuarantineAllocationService({ random: { bytes: () => Buffer.alloc(32, 8) }, presigner: { presignPut: async (value) => put(value) }, maxBytes: 100, maxLifetimeSeconds: 300 }); await assert.rejects(substitutionProbe.allocate({ workspaceId: "workspace-b" } as never, { contentLength: 10, checksumSha256: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", contentType: "application/zip" }), /allocation_rejected/); });
test("S3 rejects random collision and broader/incomplete presigner authority", async () => { const scope = deriveAuthorizedQuarantineScope({ principalId: "p", familyId: "f", workspaceId: "workspace-a", role: "owner", authorizationVersion: 1 }); const service = new QuarantineAllocationService({ random: { bytes: () => Buffer.alloc(32, 1) }, presigner: { presignPut: async (value) => put(value) }, maxBytes: 100, maxLifetimeSeconds: 300 }); const request = { contentLength: 10, checksumSha256: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", contentType: "application/zip" as const }; await service.allocate(scope, request); await assert.rejects(service.allocate(scope, request), /allocation_rejected/); });
test("S3 rejects a presigner result with missing or broader signed headers", async () => { const scope = deriveAuthorizedQuarantineScope({ principalId: "p", familyId: "f", workspaceId: "workspace-a", role: "owner", authorizationVersion: 1 }); const service = new QuarantineAllocationService({ random: { bytes: () => Buffer.alloc(32, 9) }, presigner: { presignPut: async (value) => ({ ...put(value), headers: { ...put(value).headers, "x-amz-delete": "true" } }) }, maxBytes: 100, maxLifetimeSeconds: 300 }); await assert.rejects(service.allocate(scope, { contentLength: 10, checksumSha256: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", contentType: "application/zip" }), /allocation_rejected/); });

test("SES binds sender identity/config and audit lease acceptance precedes provider", async () => { const order: string[] = []; let sent: unknown; const audit = auditFake(order); const adapter = sesAdapter({ send: async (input) => { order.push("provider"); sent = input; } }, audit); await adapter.send({ destination: "person@example.com", templateName: "magic", templateData: { link: "opaque" }, idempotencyKey: "outbox-1", purpose: "magic_link" }); assert.deepEqual(order, ["accept", "claim", "provider", "complete"]); assert.equal((sent as { fromEmailAddressIdentityArn: string }).fromEmailAddressIdentityArn, "arn:aws:ses:us-east-1:123456789012:identity/example.com"); assert.doesNotMatch(JSON.stringify(audit.events), /person@example|opaque/); });
test("SES provider failure releases the audit lease and never records destination/payload", async () => { const order: string[] = []; const audit = auditFake(order); const adapter = sesAdapter({ send: async () => { order.push("provider"); throw new Error("provider"); } }, audit); await assert.rejects(adapter.send({ destination: "person@example.com", templateName: "magic", templateData: { link: "secret-token" }, idempotencyKey: "outbox-2", purpose: "magic_link" })); assert.deepEqual(order, ["accept", "claim", "provider", "release"]); assert.doesNotMatch(JSON.stringify(audit.events), /person@example|secret-token/); });
test("SES audit-lease failure prevents provider delivery", async () => { let providerCalls = 0; const audit = auditFake([]); audit.accept = async () => { throw new Error("audit"); }; const adapter = sesAdapter({ send: async () => { providerCalls++; } }, audit); await assert.rejects(adapter.send({ destination: "person@example.com", templateName: "magic", templateData: {}, idempotencyKey: "outbox-3", purpose: "magic_link" })); assert.equal(providerCalls, 0); });
test("allowlist audit rejects forged actions/results/fields and canary detector has a positive control", () => { const events: unknown[] = []; const audit = new AllowlistAuditAdapter({ write: (event) => { events.push(event); } }, { bytes: (length) => Buffer.alloc(length, 1) }, Buffer.alloc(32, 2), Buffer.alloc(32, 3)); audit.write({ action: "provider.adapter", result: "accepted" }); assert.throws(() => audit.write({ action: "free.text secret@example.com" as never, result: "accepted" })); assert.throws(() => audit.write({ action: "provider.adapter", result: "free text" as never })); assert.throws(() => audit.write({ action: "provider.adapter", result: "accepted", arbitrary: "secret@example.com" } as never)); assert.deepEqual(findCanaryLeaks(events, ["secret@example.com"]), []); assert.deepEqual(findCanaryLeaks({ unsafe: "secret@example.com" }, ["secret@example.com"]), ["$.unsafe"]); });
test("allowlist audit surfaces durable sink failure", () => { const audit = new AllowlistAuditAdapter({ write: () => { throw new Error("sink"); } }, { bytes: (length) => Buffer.alloc(length, 1) }, Buffer.alloc(32, 2), Buffer.alloc(32, 3)); assert.throws(() => audit.write({ action: "provider.adapter", result: "failed" }), /sink/); });

function appleSuccess() { return { status: 200, headers: { "content-type": "application/json" }, body: Buffer.from('{"id_token":"header.payload.signature"}') }; }
function appleAdapter(request: (input: Parameters<ConstructorParameters<typeof AppleCodeExchangeHttpAdapter>[0]["transport"]["request"]>[0]) => Promise<{ status: number; headers: Readonly<Record<string, string>>; body: Uint8Array }>) { return new AppleCodeExchangeHttpAdapter({ transport: { request }, secrets: { read: async () => "client-secret-long-enough" }, clientSecretName: "apple/client", timeoutMs: 1000, maxResponseBytes: 2048 }); }
function challenge(synthetic: boolean): BoundCustomChallenge { return { attemptId: "attempt", purpose: "sign-in", selector: "selector", proof: "proof", synthetic }; }
function createEvent(userNotFound: boolean): CreateAuthChallengeEvent { return { triggerSource: "CreateAuthChallenge_Authentication", request: { challengeName: "CUSTOM_CHALLENGE", userNotFound }, response: {} }; }
function verifyEvent(privateChallengeParameters: Readonly<Record<string, string>>, challengeAnswer: string): VerifyAuthChallengeEvent { return { triggerSource: "VerifyAuthChallengeResponse_Authentication", request: { privateChallengeParameters, challengeAnswer }, response: { answerCorrect: false } }; }
function defineEvent(session: readonly { challengeName?: string; challengeResult?: boolean }[]): DefineAuthChallengeEvent { return { triggerSource: "DefineAuthChallenge_Authentication", request: { session }, response: { issueTokens: false, failAuthentication: false } }; }
function put(input: { key: string; contentLength: number; checksumSha256: string; contentType: string }) { return { url: `https://upload.example/${input.key}`, headers: { "content-length": String(input.contentLength), "content-type": input.contentType, "x-amz-checksum-sha256": input.checksumSha256, "if-none-match": "*", "x-amz-meta-roomscan-upload-kind": "quarantine-v1" } }; }
function auditFake(order: string[]): AuditOutboxLeasePort & { events: unknown[] } { const events: unknown[] = []; return { events, accept: async (input) => { order.push("accept"); events.push(input); }, claim: async (input) => { order.push("claim"); events.push(input); return { id: "audit-1", idempotencyKey: input.idempotencyKey, action: "email.delivery", result: "pending", leaseId: input.leaseId }; }, complete: async (input) => { order.push("complete"); events.push(input); return true; }, release: async (input) => { order.push("release"); events.push(input); return true; } }; }
function sesAdapter(client: { send(input: Parameters<ConstructorParameters<typeof SesDeliveryAdapter>[0]["client"]["send"]>[0]): Promise<void> }, auditOutbox: AuditOutboxLeasePort) { return new SesDeliveryAdapter({ client, fromEmailAddress: "no-reply@example.com", fromEmailAddressIdentityArn: "arn:aws:ses:us-east-1:123456789012:identity/example.com", configurationSetName: "roomscan-transactional", auditOutbox, clock: { nowMs: () => 10 }, random: { bytes: () => Buffer.alloc(16, 1) }, leaseMs: 1000 }); }
