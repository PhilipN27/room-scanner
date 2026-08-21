import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import test from "node:test";
import { SLICE4_OPENAPI } from "../src/contracts/openapi.js";
import { SLICE4_ROUTE_MANIFEST, SLICE4_ROUTE_SET_VERSION, routeKey } from "../src/contracts/route-manifest.js";
import { createSlice4HandlerEntrypoint, hasDuplicateJsonObjectKeys, type ApiGatewayV2Request, type AuthorizedOperationContext, type RouteHandler, type SameTransactionOperationPort } from "../src/handlers/factory.js";
import { StripeWebhookHttpAdapter } from "../src/handlers/stripe-webhook.js";
import { DataApiTransactionExecutor, type DataApiClient } from "../src/adapters/data-api.js";
import { DataApiSameTransactionOperationPort } from "../src/adapters/operation-unit-of-work.js";

const json = (statusCode = 200) => ({ statusCode, headers: { "content-type": "application/json", "cache-control": "no-store" }, body: "{}" });
function handlers(scannerBody = "<!doctype html><p>Continue</p>"): Record<string, RouteHandler> { return Object.fromEntries(SLICE4_ROUTE_MANIFEST.map((route) => [route.id, async () => route.responseKind === "scanner-html" ? { statusCode: 200, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "content-security-policy": "default-src 'none'", "referrer-policy": "no-referrer" }, body: scannerBody } : json()])); }
class Operations implements SameTransactionOperationPort { calls: unknown[] = []; marker = Symbol("tx"); async run<T>(input: Parameters<SameTransactionOperationPort["run"]>[0], operation: (context: AuthorizedOperationContext) => Promise<T>): Promise<T> { this.calls.push(input); return operation({ principalPublicId: "principal-public", transactionMarker: this.marker, repositories: { contract: "roomscan-transaction-repositories-v1", transactionMarker: this.marker } }); } }
function request(method: string, path: string, body?: string, headers: Record<string, string> = {}): ApiGatewayV2Request { return { version: "2.0", rawPath: path, rawQueryString: "", requestContext: { http: { method } }, headers, ...(body === undefined ? {} : { body }) }; }
function protectedBody(routeId: string): string | undefined {
  if (routeId === "apple.candidate.begin") return JSON.stringify({ codeChallenge: "c".repeat(43), purpose: "link-identity" });
  if (routeId === "magic.candidate.request") return JSON.stringify({ email: "candidate@example.com", purpose: "link-identity", codeChallenge: "c".repeat(43) });
  if (routeId === "workspace.bootstrap") return JSON.stringify({ slug: "new-room", displayName: "New room" });
  if (routeId === "workspace.activate") return JSON.stringify({ slug: "current-room" });
  if (routeId === "identity.mutate") return JSON.stringify({ purpose: "link-identity", candidateIssuer: "apple", verifiedAuthenticationReceiptToken: "r".repeat(43), confirmed: true });
  return undefined;
}

test("canonical manifest is deeply immutable, unique, sealed, and exactly matches OpenAPI", () => { assert.equal(Object.isFrozen(SLICE4_ROUTE_MANIFEST), true); for (const route of SLICE4_ROUTE_MANIFEST) { assert.equal(Object.isFrozen(route), true); assert.equal(Object.isFrozen(route.authorization), true); assert.equal(Object.isFrozen(route.request), true); const path = route.pathTemplate.replace(":selector", "{selector}"); const operation = (SLICE4_OPENAPI.paths as Record<string, Record<string, unknown>>)[path]?.[route.method.toLowerCase()]; assert.ok(operation, routeKey(route)); } const openApiOperations = Object.values(SLICE4_OPENAPI.paths).reduce((count, item) => count + ["get", "post"].filter((method) => method in item).length, 0); assert.equal(openApiOperations, SLICE4_ROUTE_MANIFEST.length); assert.equal(SLICE4_ROUTE_MANIFEST.some((route) => route.pathTemplate.includes("workspaceId") || route.pathTemplate.includes("projects")), false); });
test("Apple route contract carries S256 challenge and keeps candidate begin behind recent bearer authentication", async () => {
  const signIn = SLICE4_ROUTE_MANIFEST.find((route) => route.id === "apple.begin");
  assert.deepEqual(signIn?.authorization, { kind: "public" });
  assert.deepEqual(Object.keys(signIn?.request.fields ?? {}), ["codeChallenge"]);
  assert.deepEqual(signIn?.request.fields?.codeChallenge, { type: "string", required: true, minLength: 43, maxLength: 43, pattern: "^[A-Za-z0-9_-]+$" });
  const candidate = SLICE4_ROUTE_MANIFEST.find((route) => route.id === "apple.candidate.begin");
  assert.deepEqual(candidate?.authorization, { kind: "session", requiresRecentAuthentication: true });
  const candidatePurpose = candidate?.request.fields?.purpose;
  assert.deepEqual(candidatePurpose?.type === "string" ? candidatePurpose.enum : undefined, ["link-identity", "unlink-identity"]);
  const operations = new Operations();
  const entry = createSlice4HandlerEntrypoint({ handlers: handlers(), operations });
  const challenge = "c".repeat(43);
  assert.equal((await entry(request("POST", "/auth/apple/begin", JSON.stringify({ purpose: "link-identity" }), { "content-type": "application/json" }))).statusCode, 400);
  assert.equal((await entry(request("POST", "/auth/apple/begin", JSON.stringify({ codeChallenge: challenge }), { "content-type": "application/json" }))).statusCode, 200);
  assert.equal((await entry(request("POST", "/auth/apple/candidate/begin", JSON.stringify({ codeChallenge: challenge, purpose: "link-identity" }), { "content-type": "application/json" }))).statusCode, 401);
  assert.equal((await entry(request("POST", "/auth/apple/candidate/begin", JSON.stringify({ codeChallenge: challenge, purpose: "link-identity" }), { "content-type": "application/json", authorization: `Bearer ${"a".repeat(32)}` }))).statusCode, 200);
});

test("v3 magic-link contract binds issue and redemption to an app-held verifier plus transfer code", () => {
  const byId = new Map(SLICE4_ROUTE_MANIFEST.map((route) => [route.id, route]));
  const publicRequest = byId.get("magic.request");
  const candidateRequest = byId.get("magic.candidate.request");
  const confirmation = byId.get("magic.consume");
  const redemption = byId.get("magic.completion.redeem");

  assert.equal(SLICE4_ROUTE_SET_VERSION, "roomscan-slice4-routes-v3");
  assert.deepEqual(publicRequest?.authorization, { kind: "public" });
  assert.deepEqual(publicRequest?.request.fields?.codeChallenge, { type: "string", required: true, minLength: 43, maxLength: 43, pattern: "^[A-Za-z0-9_-]+$" });
  assert.deepEqual(candidateRequest?.authorization, { kind: "session", requiresRecentAuthentication: true });
  const candidateMagicPurpose = candidateRequest?.request.fields?.purpose;
  assert.deepEqual(candidateMagicPurpose?.type === "string" ? candidateMagicPurpose.enum : undefined, ["link-identity", "unlink-identity"]);
  assert.deepEqual(candidateRequest?.request.fields?.codeChallenge, { type: "string", required: true, minLength: 43, maxLength: 43, pattern: "^[A-Za-z0-9_-]+$" });
  assert.equal(confirmation?.request.fields?.purpose?.required, true);
  assert.deepEqual(redemption?.authorization, { kind: "public" });
  assert.deepEqual(redemption?.trustedInputs, { sourceIp: "api-gateway-v2" });
  assert.deepEqual(redemption?.request.fields, {
    completionId: { type: "string", required: true, minLength: 43, maxLength: 43, pattern: "^[A-Za-z0-9_-]+$" },
    codeVerifier: { type: "string", required: true, minLength: 43, maxLength: 43, pattern: "^[A-Za-z0-9_-]+$" },
    purpose: { type: "string", required: true, minLength: 1, maxLength: 32, enum: ["sign-in", "reauthenticate", "link-identity", "unlink-identity"] },
    transferCode: { type: "string", required: true, minLength: 8, maxLength: 8, pattern: "^[0-9A-HJKMNP-TV-Z]{8}$" },
  });
});

test("workspace reachability and identity mutation routes accept no caller tenant IDs and require literal confirmation", () => {
  const byId = new Map(SLICE4_ROUTE_MANIFEST.map((route) => [route.id, route]));
  const bootstrap = byId.get("workspace.bootstrap");
  const activation = byId.get("workspace.activate");
  const mutation = byId.get("identity.mutate");

  assert.deepEqual(bootstrap?.authorization, { kind: "session", requiresRecentAuthentication: true });
  assert.deepEqual(bootstrap?.request.fields, {
    slug: { type: "string", required: true, minLength: 3, maxLength: 63, pattern: "^[a-z0-9][a-z0-9-]{2,62}$" },
    displayName: { type: "string", required: true, minLength: 1, maxLength: 160 },
  });
  assert.deepEqual(activation?.authorization, { kind: "session", requiresRecentAuthentication: true });
  assert.deepEqual(activation?.request.fields, {
    slug: { type: "string", required: true, minLength: 3, maxLength: 63, pattern: "^[a-z0-9][a-z0-9-]{2,62}$" },
  });
  assert.deepEqual(mutation?.authorization, { kind: "session", requiresRecentAuthentication: true });
  assert.deepEqual(mutation?.request.fields, {
    purpose: { type: "string", required: true, minLength: 1, maxLength: 32, enum: ["link-identity", "unlink-identity"] },
    candidateIssuer: { type: "string", required: true, minLength: 5, maxLength: 5, enum: ["apple", "email"] },
    verifiedAuthenticationReceiptToken: { type: "string", required: true, minLength: 43, maxLength: 43, pattern: "^[A-Za-z0-9_-]+$" },
    confirmed: { type: "boolean", required: true, literal: true },
  });
  for (const route of [bootstrap, activation, mutation]) {
    assert.equal(Object.keys(route?.request.fields ?? {}).some((field) => /workspace|tenant|principal|family|role/i.test(field)), false);
  }
});

test("identity mutation rejects false, null, string, missing, and duplicate confirmation before its protected handler", async () => {
  const map = handlers();
  let calls = 0;
  map["identity.mutate"] = async () => { calls++; return json(); };
  const entry = createSlice4HandlerEntrypoint({ handlers: map, operations: new Operations() });
  const base = { purpose: "link-identity", candidateIssuer: "apple", verifiedAuthenticationReceiptToken: "r".repeat(43) };
  const headers = { "content-type": "application/json", authorization: `Bearer ${"b".repeat(32)}` };
  assert.equal((await entry(request("POST", "/identity/mutate", JSON.stringify({ ...base, confirmed: true }), headers))).statusCode, 200);
  for (const value of [false, null, "true", undefined]) {
    const body = value === undefined ? JSON.stringify(base) : JSON.stringify({ ...base, confirmed: value });
    assert.equal((await entry(request("POST", "/identity/mutate", body, headers))).statusCode, 400);
  }
  assert.equal((await entry(request("POST", "/identity/mutate", `{${JSON.stringify("purpose")}:"link-identity","candidateIssuer":"apple","verifiedAuthenticationReceiptToken":"${"r".repeat(43)}","confirmed":true,"confirmed":false}`, headers))).statusCode, 400);
  assert.equal(calls, 1);
});

test("Apple finish and refresh handlers receive distinct challenge-session and hash-rotation execution lanes", async () => { const map = handlers(); const lanes = new Map<string, unknown>(); for (const id of ["apple.finish", "session.refresh"] as const) map[id] = async (normalized) => { lanes.set(id, (normalized as unknown as { executionLane?: unknown }).executionLane); return json(); }; const entry = createSlice4HandlerEntrypoint({ handlers: map, operations: new Operations() }); const challenge = "c".repeat(43); const appleBody = JSON.stringify({ attemptId: "attempt-12345678", state: "s".repeat(43), code: "apple-code", codeVerifier: challenge }); assert.equal((await entry(request("POST", "/auth/apple/finish", appleBody, { "content-type": "application/json" }))).statusCode, 200); assert.equal((await entry(request("POST", "/auth/session/refresh", JSON.stringify({ refreshToken: "r".repeat(32) }), { "content-type": "application/json" }))).statusCode, 200); assert.equal(lanes.get("apple.finish"), "apple-api-exchange-cognito-challenge-session"); assert.equal(lanes.get("session.refresh"), "session-refresh-hash-rotation"); });
test("factory rejects both missing and extra handlers", () => { const operations = new Operations(); const all = handlers(); const missing = { ...all }; delete missing[SLICE4_ROUTE_MANIFEST[0]!.id]; assert.throws(() => createSlice4HandlerEntrypoint({ handlers: missing, operations }), /handler_manifest_mismatch/); assert.throws(() => createSlice4HandlerEntrypoint({ handlers: { ...all, surprise: async () => json() }, operations }), /handler_manifest_mismatch/); });
test("entrypoint strictly matches API v2 method/path/query/header ambiguity", async () => { const entry = createSlice4HandlerEntrypoint({ handlers: handlers(), operations: new Operations() }); assert.equal((await entry({ ...request("GET", "/health"), version: "1.0" })).statusCode, 400); assert.equal((await entry({ ...request("GET", "/health"), rawQueryString: "x=1" })).statusCode, 400); assert.equal((await entry({ ...request("GET", "/health"), headers: { Authorization: "x", authorization: "y" } })).statusCode, 400); assert.equal((await entry(request("DELETE", "/health"))).statusCode, 400); assert.equal((await entry(request("GET", "/unknown"))).statusCode, 404); });
test("public routes do not call authorization while protected routes require bearer and run handler in its transaction", async () => { const operations = new Operations(); const map = handlers(); let handlerMarker: symbol | undefined; map["workspace.get"] = async (_request, context) => { handlerMarker = context?.transactionMarker; return json(); }; const entry = createSlice4HandlerEntrypoint({ handlers: map, operations }); assert.equal((await entry(request("GET", "/health"))).statusCode, 200); assert.equal(operations.calls.length, 0); assert.equal((await entry(request("GET", "/workspace"))).statusCode, 401); assert.equal((await entry(request("GET", "/workspace", undefined, { authorization: `Bearer ${"a".repeat(32)}` }))).statusCode, 200); assert.equal(handlerMarker, operations.marker); assert.deepEqual(operations.calls[0], { accessToken: "a".repeat(32), authorization: { kind: "workspace", action: "workspace.read", resourceResolver: "none" } }); });
test("every protected route maps its exact sealed authorization and resource resolver", async () => { const operations = new Operations(); const entry = createSlice4HandlerEntrypoint({ handlers: handlers(), operations }); for (const route of SLICE4_ROUTE_MANIFEST.filter((item) => item.authorization.kind !== "public")) { const path = route.pathTemplate.replace(":selector", "selector-12345678"); const body = protectedBody(route.id); const base = request(route.method, path, body, { authorization: `Bearer ${"b".repeat(32)}`, ...(body === undefined ? {} : { "content-type": "application/json" }) }); const input = route.trustedInputs?.sourceIp === "api-gateway-v2" ? { ...base, requestContext: { http: { method: route.method, sourceIp: "198.51.100.24" } } } : base; const response = await entry(input); assert.equal(response.statusCode, 200, route.id); assert.deepEqual((operations.calls.at(-1) as { authorization: unknown }).authorization, route.authorization); } });
test("scanner GET is bodyless, static, no-store/CSP/referrer protected and never interpolates selector", async () => { const entry = createSlice4HandlerEntrypoint({ handlers: handlers(), operations: new Operations() }); const selector = "selector-12345678"; const response = await entry(request("GET", `/auth/magic-link/${selector}`)); assert.equal(response.statusCode, 200); assert.equal(response.headers["cache-control"], "no-store"); assert.equal(response.headers["referrer-policy"], "no-referrer"); assert.equal(response.body.includes(selector), false); const unsafe = createSlice4HandlerEntrypoint({ handlers: handlers(`<p>${selector}</p>`), operations: new Operations() }); assert.equal((await unsafe(request("GET", `/auth/magic-link/${selector}`))).statusCode, 500); });
test("scanner-compatible magic POST derives clicking context from API Gateway and rejects client device identity", async () => { const map = handlers(); let clickingDeviceId: unknown; map["magic.consume"] = async (normalized) => { clickingDeviceId = (normalized as unknown as { serverDerived?: { clickingDeviceId?: unknown } }).serverDerived?.clickingDeviceId; return json(); }; const entry = createSlice4HandlerEntrypoint({ handlers: map, operations: new Operations() }); const good = JSON.stringify({ selector: "selector-12345678", secret: "s".repeat(32), purpose: "sign-in" }); const gatewayContext = { requestId: "gateway-request-123", http: { method: "POST" } } as unknown as NonNullable<ApiGatewayV2Request["requestContext"]>; const gatewayRequest = { ...request("POST", "/auth/magic-link/consume", good, { "content-type": "application/json" }), requestContext: gatewayContext }; assert.equal((await entry(gatewayRequest)).statusCode, 200); assert.equal(clickingDeviceId, "apigw:gateway-request-123"); assert.equal((await entry(request("POST", "/auth/magic-link/consume", good, { "content-type": "application/json" }))).statusCode, 400); assert.equal((await entry({ ...gatewayRequest, body: JSON.stringify({ selector: "selector-12345678", secret: "s".repeat(32), purpose: "sign-in", clickingDeviceId: "client-forged" }) })).statusCode, 400); assert.equal((await entry({ ...gatewayRequest, body: '{"selector":"selector-12345678","secret":"ssssssssssssssssssssssssssssssss","purpose":"sign-in","selector":"second-selector-1"}' })).statusCode, 400); assert.equal((await entry({ ...request("POST", "/auth/magic-link/consume", undefined, { "content-type": "application/json" }), requestContext: gatewayContext, body: Buffer.from([0xff]).toString("base64"), isBase64Encoded: true })).statusCode, 400); assert.equal(hasDuplicateJsonObjectKeys('{"a":1,"\u0061":2}'), true); });

test("Stripe raw route requires exact application/json while preserving the accepted bytes", async () => { const map = handlers(); const bodies: Uint8Array[] = []; map["stripe.webhook"] = async (normalized) => { bodies.push((normalized as { body: Uint8Array }).body); return json(); }; const entry = createSlice4HandlerEntrypoint({ handlers: map, operations: new Operations() }); const body = '{ "id": "evt_1" }'; assert.equal((await entry(request("POST", "/billing/stripe/webhook", body, { "content-type": "application/json", "stripe-signature": "sig" }))).statusCode, 200); assert.deepEqual(Buffer.from(bodies[0] ?? []), Buffer.from(body)); assert.equal((await entry(request("POST", "/billing/stripe/webhook", body, { "stripe-signature": "sig" }))).statusCode, 400); assert.equal((await entry(request("POST", "/billing/stripe/webhook", body, { "content-type": "application/json; charset=utf-8", "stripe-signature": "sig" }))).statusCode, 400); assert.equal((await entry(request("POST", "/billing/stripe/webhook", body, { "content-type": "text/plain", "stripe-signature": "sig" }))).statusCode, 400); assert.equal(bodies.length, 1); });
test("magic request derives network identity only from API Gateway sourceIp and quota GET binds all five metrics", async () => { const map = handlers(); let sourceIp: unknown; let quotaMetrics: unknown; map["magic.request"] = async (normalized) => { sourceIp = (normalized as unknown as { serverDerived?: { sourceIp?: unknown } }).serverDerived?.sourceIp; return json(); }; map["quota.get"] = async (normalized) => { quotaMetrics = (normalized as unknown as { serverDerived?: { quotaMetrics?: unknown } }).serverDerived?.quotaMetrics; return json(); }; const entry = createSlice4HandlerEntrypoint({ handlers: map, operations: new Operations() }); const magic = { ...request("POST", "/auth/magic-link/request", JSON.stringify({ email: "person@example.com", purpose: "sign-in", codeChallenge: "c".repeat(43) }), { "content-type": "application/json" }), requestContext: { http: { method: "POST", sourceIp: "198.51.100.24" } } }; assert.equal((await entry(magic)).statusCode, 200); assert.equal(sourceIp, "198.51.100.24"); assert.equal((await entry(request("POST", "/auth/magic-link/request", JSON.stringify({ email: "person@example.com", purpose: "sign-in", codeChallenge: "c".repeat(43) }), { "content-type": "application/json" }))).statusCode, 400); assert.equal((await entry({ ...magic, body: JSON.stringify({ email: "person@example.com", purpose: "sign-in", codeChallenge: "c".repeat(43), networkAddress: "203.0.113.1" }) })).statusCode, 400); assert.equal((await entry(request("GET", "/quota", undefined, { authorization: `Bearer ${"q".repeat(32)}` }))).statusCode, 200); assert.deepEqual(quotaMetrics, ["project_count", "member_count", "working_bytes", "raw_bytes", "portal_bytes"]); });
test("raw Stripe adapter forwards exact plain/base64 JSON envelopes only to accepted Task5 handler", async () => { const envelopes: unknown[] = []; const accepted = { handle: async (envelope: unknown) => { envelopes.push(envelope); return json(200); } }; const adapter = new StripeWebhookHttpAdapter(accepted as never); const plain = { body: "{\"id\":1}", isBase64Encoded: false, headers: { "content-type": "application/json", "stripe-signature": "sig" } }; const encoded = { body: Buffer.from("bytes").toString("base64"), isBase64Encoded: true, headers: { "content-type": "application/json", "stripe-signature": "sig" } }; assert.equal((await adapter.handle(plain)).statusCode, 200); assert.equal((await adapter.handle(encoded)).statusCode, 200); assert.strictEqual(envelopes[0], plain); assert.strictEqual(envelopes[1], encoded); assert.equal((await adapter.handle({ ...plain, headers: { "content-type": "text/plain", "stripe-signature": "sig" } })).statusCode, 400); assert.equal(envelopes.length, 2); });
test("concrete operation adapter uses the canonical SessionService digest and exposes only a transaction-bound repository bundle", async () => {
  const calls: string[] = [];
  let resolvedDigest: Uint8Array | undefined;
  let clearContextSql: string | undefined;
  const row = { principal_id: "11111111-1111-4111-8111-111111111111", canonical_principal_id: "principal", family_id: "22222222-2222-4222-8222-222222222222", family_public_id: "family", workspace_id: "33333333-3333-4333-8333-333333333333", role: "viewer", authorization_version: 1, authentication_epoch: 1, authenticated_at: "2030-01-01T00:00:00.000Z", recent_authentication: true };
  const client: DataApiClient = {
    begin: async () => { calls.push("begin"); return { transactionId: "tx-uow" }; },
    execute: async (input) => {
      const resolver = input.sql.includes("resolve_access_context");
      const clearsContext = input.sql.includes("set_config('app.principal_id', '', true)");
      if (clearsContext) clearContextSql = input.sql;
      calls.push(resolver ? "resolve" : clearsContext ? "clear-context" : input.sql.includes("set_config") ? "context" : "repository-sql");
      if (resolver) {
        const value = input.parameters?.find((parameter) => parameter.name === "access_token_hash")?.value;
        if (value?.kind === "blob") resolvedDigest = value.bytes;
      }
      return { rows: resolver ? [row] : [] };
    },
    commit: async () => { calls.push("commit"); },
    rollback: async () => { calls.push("rollback"); },
  };
  const transactions = new DataApiTransactionExecutor(client, { authorize: async () => false });
  const key = Buffer.alloc(32, 7);
  const token = Buffer.alloc(32, 0x61).toString("base64url");
  const repositoryBundles = { bind: ({ execute, transactionMarker }: { execute(statement: { sql: string }): Promise<unknown>; transactionMarker: symbol }) => Object.freeze({ contract: "roomscan-transaction-repositories-v1" as const, transactionMarker, probe: () => execute({ sql: "SELECT repository_mutation()" }) }) };
  const operations = new DataApiSameTransactionOperationPort({ transactions, clock: { now: () => new Date("2030-01-01T00:00:00Z") }, accessTokenHmacKey: key, repositoryBundles } as never);
  await operations.run({ accessToken: token, authorization: { kind: "workspace", action: "workspace.read", resourceResolver: "none" } }, async (context) => {
    const raw = context as unknown as { executeSql?: unknown; repositories?: { probe(): Promise<unknown> } };
    assert.equal("executeSql" in raw, false);
    await raw.repositories?.probe();
    return undefined;
  });
  assert.deepEqual(Buffer.from(resolvedDigest ?? []), createHmac("sha256", key).update(token).digest());
  assert.deepEqual(calls, ["begin", "clear-context", "resolve", "context", "context", "context", "repository-sql", "commit"]);
  assert.match(clearContextSql ?? "", /set_config\('app\.principal_id', '', true\)/u);
  assert.match(clearContextSql ?? "", /set_config\('app\.tenant_id', '', true\)/u);
  assert.match(clearContextSql ?? "", /set_config\('app\.authorization_version', '', true\)/u);
});
test("candidate Apple begin enforces recent server authentication while ordinary logout does not", async () => {
  const makeOperations = (recentAuthentication: boolean, transactionId: string) => {
    const row = { principal_id: "11111111-1111-4111-8111-111111111111", canonical_principal_id: "principal", family_id: "22222222-2222-4222-8222-222222222222", family_public_id: "family", workspace_id: null, role: null, authorization_version: null, authentication_epoch: 1, authenticated_at: "2030-01-01T00:00:00.000Z", recent_authentication: recentAuthentication };
    const client: DataApiClient = { begin: async () => ({ transactionId }), execute: async (input) => ({ rows: input.sql.includes("resolve_access_context") ? [row] : [] }), commit: async () => undefined, rollback: async () => undefined };
    return new DataApiSameTransactionOperationPort({ transactions: new DataApiTransactionExecutor(client, { authorize: async () => false }), clock: { now: () => new Date("2030-01-01T00:00:00Z") }, accessTokenHmacKey: Buffer.alloc(32, 7), repositoryBundles: { bind: ({ transactionMarker }: { transactionMarker: symbol }) => ({ contract: "roomscan-transaction-repositories-v1" as const, transactionMarker }) } } as never);
  };
  const token = Buffer.alloc(32, 0x62).toString("base64url");
  await assert.rejects(makeOperations(false, "tx-stale-recent").run({ accessToken: token, authorization: { kind: "session", requiresRecentAuthentication: true } }, async () => undefined), /operation_denied/);
  await makeOperations(false, "tx-logout").run({ accessToken: token, authorization: { kind: "session", requiresRecentAuthentication: false } }, async () => undefined);
  await makeOperations(true, "tx-fresh-recent").run({ accessToken: token, authorization: { kind: "session", requiresRecentAuthentication: true } }, async () => undefined);
});
