import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import test from "node:test";

import {
  DataApiRouteApplicationError,
  createSlice4DataApiApiHandler,
  createSlice4DataApiRouteApplications,
} from "../src/composition/data-api-route-application.js";
import type { DataApiClient, SqlParameter } from "../src/adapters/data-api.js";

const PRINCIPAL = `prn_${"a".repeat(22)}`;

test("Data API route composition fails closed when a required role-bound API dependency is absent", () => {
  assert.throws(
    () => createSlice4DataApiRouteApplications({} as never),
    (error: unknown) => error instanceof DataApiRouteApplicationError && error.code === "invalid_composition",
  );
});

test("public v3 magic issue response is byte-identical for issued, unknown, throttled, disabled, and repository-error outcomes", async () => {
  const outcomes = [
    "issued",
    "address_rate_limited",
    "network_rate_limited",
    "professional_sign_in_disabled",
    "throw",
  ] as const;
  const bodies: string[] = [];
  for (const outcome of outcomes) {
    const handler = publicMagicShapeHandler(outcome);
    const response = await handler(request("POST", "/auth/magic-link/request", {
      email: "same@example.com", purpose: "sign-in", codeChallenge: "c".repeat(43),
    }, { sourceIp: "198.51.100.24" }));
    assert.equal(response.statusCode, 202);
    bodies.push(response.body);
  }
  assert.equal(new Set(bodies).size, 1, "a public caller must not distinguish issuance, policy, rate, or persistence outcomes by JSON shape or byte length");
  assert.deepEqual(JSON.parse(bodies[0]!), {
    accepted: true,
    completionId: Buffer.alloc(32, 7).toString("base64url"),
    expiresAt: "2030-01-01T00:05:00.000Z",
  });
});

test("public v3 magic issue performs one targetless best-effort wake after every syntactically valid outcome", async () => {
  const outcomes = [
    "issued",
    "address_rate_limited",
    "network_rate_limited",
    "professional_sign_in_disabled",
    "throw",
  ] as const;
  const wakeCounts: number[] = [];
  for (const outcome of outcomes) {
    let wakes = 0;
    const handler = publicMagicShapeHandler(outcome, async () => { wakes += 1; });
    const response = await handler(request("POST", "/auth/magic-link/request", {
      email: "same@example.com", purpose: "sign-in", codeChallenge: "c".repeat(43),
    }, { sourceIp: "198.51.100.24" }));
    assert.equal(response.statusCode, 202);
    wakeCounts.push(wakes);
  }
  assert.deepEqual(wakeCounts, [1, 1, 1, 1, 1]);

  let invalidWakeCount = 0;
  const invalidHandler = publicMagicShapeHandler("issued", async () => { invalidWakeCount += 1; });
  assert.equal((await invalidHandler(request("POST", "/auth/magic-link/request", {
    email: "same@example.com", purpose: "sign-in", codeChallenge: "c".repeat(42),
  }, { sourceIp: "198.51.100.24" }))).statusCode, 400);
  assert.equal(invalidWakeCount, 0, "schema-invalid input must be rejected before the public issuance port or wake side effect");
});

test("concrete Data API factory owns all sealed HTTP routes, app auth, v3 magic handoff, same-UoW protected paths, and post-commit magic wake", async () => {
  const now = Date.UTC(2030, 0, 1);
  const apiCalls: Array<Readonly<{ readonly transactionId: string; readonly sql: string; readonly parameters: readonly SqlParameter[] }>> = [];
  const ordering: string[] = [];
  let transaction = 0;
  const createdAttempts = new Map<string, Readonly<{ readonly nonce: Uint8Array; readonly purpose: string }>>();
  let issuedAccessDigest: Uint8Array | undefined;
  let issuedFamilyPublicId: string | undefined;
  const publicApple = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const appleJwk = publicApple.publicKey.export({ format: "jwk" });
  const appleClient = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const applePem = appleClient.privateKey.export({ format: "pem", type: "pkcs8" }).toString();
  let appleNonce = "";
  const current = workspaceState();
  const client: DataApiClient = {
    begin: async () => ({ transactionId: `route-${++transaction}` }),
    execute: async (input) => {
      apiCalls.push({ transactionId: input.transactionId, sql: input.sql, parameters: input.parameters ?? [] });
      if (input.sql.includes("resolve_access_context")) {
        const access = blobParameter(input.parameters, "access_token_hash");
        return { rows: [issuedAccessDigest !== undefined && Buffer.from(access).equals(Buffer.from(issuedAccessDigest))
          ? resolvedAccess(issuedFamilyPublicId)
          : resolvedAccess()] };
      }
      if (input.sql.includes("set_config")) return { rows: [] };
      if (input.sql.includes("read_workspace_authorization_state")) return { rows: [current] };
      if (input.sql.includes("issue_magic_challenge_v3")) {
        const selector = stringParameter(input.parameters, "selector");
        return { rows: [{ status: "issued", selector, expires_at: new Date(now + 300_000).toISOString() }] };
      }
      if (input.sql.includes("consume_magic_challenge_v3")) return { rows: [{ status: "confirmed", purpose: stringParameter(input.parameters, "expected_purpose"), confirmed_at: new Date(now).toISOString(), expires_at: new Date(now + 300_000).toISOString() }] };
      if (input.sql.includes("redeem_magic_completion_v3")) return { rows: [magicCompletionSessionRow(now)] };
      if (input.sql.includes("create_apple_attempt_v2")) {
        const attemptId = stringParameter(input.parameters, "attempt_id");
        const purpose = stringParameter(input.parameters, "purpose");
        createdAttempts.set(attemptId, Object.freeze({ nonce: blobParameter(input.parameters, "nonce_hash"), purpose }));
        return { rows: [{ status: "created", attempt_id: attemptId, purpose }] };
      }
      if (input.sql.includes("claim_apple_attempt_and_code")) {
        const attemptId = stringParameter(input.parameters, "attempt_id");
        const attempted = createdAttempts.get(attemptId);
        if (attempted === undefined) throw new Error("unknown Apple attempt");
        return { rows: [appleClaimRow(attemptId, attempted.nonce, attempted.purpose, now)] };
      }
      if (input.sql.includes("claim_apple_nonce")) return { rows: [{ claimed: true }] };
      if (input.sql.includes("accept_apple_verified_result_v2")) return { rows: [{ status: "bridge_created", attempt_id: stringParameter(input.parameters, "attempt_id"), purpose: "sign-in", principal_id: null, family_id: null, expires_at: new Date(now + 60_000).toISOString() }] };
      if (input.sql.includes("rotate_session_from_refresh")) return { rows: [rotatedSessionRow(now)] };
      if (input.sql.includes("logout_from_access")) return { rows: [logoutRow()] };
      if (input.sql.includes("bootstrap_workspace_v2")) return { rows: [bootstrapWorkspaceRow()] };
      if (input.sql.includes("scope_session_workspace_v2")) return { rows: [scopeSessionRow()] };
      if (input.sql.includes("mint_candidate_identity_proof_v2")) return { rows: [candidateProofRow(now)] };
      if (input.sql.includes("mutate_identity_v2")) return { rows: [identityMutationRow()] };
      if (input.sql.includes("read_current_subscription_v2")) return { rows: [subscriptionRow(now)] };
      if (input.sql.includes("read_quota_overview_v2")) return { rows: quotaRows(now) };
      throw new Error(`unexpected SQL: ${input.sql}`);
    },
    commit: async (transactionId) => { ordering.push(`commit:${transactionId}`); },
    rollback: async () => { ordering.push("rollback"); },
  };
  const handler = createSlice4DataApiApiHandler({
    apiClient: client,
    clock: { nowMs: () => now },
    random: incrementingRandom(),
    keys: keys(),
    magic: {
      version: "magic-v1", ttlMs: 300_000, verifiedAuthenticationReceiptTtlMs: 60_000, keyId: "magic-v1", sealingKey: Buffer.alloc(32, 4),
      maxCompletionFailures: 5, redeemNetworkWindowSeconds: 60, maxRedeemNetworkFailures: 10,
      ratePolicy: { cooldownSeconds: 1, maxActiveLinks: 1, addressWindowSeconds: 60, maxAddressWindow: 1, addressDaySeconds: 86_400, maxAddressDay: 1, networkWindowSeconds: 60, maxNetworkWindow: 1 },
    },
    sessions: { version: "session-v1", accessTtlMs: 300_000, refreshInactivityTtlMs: 86_400_000, refreshAbsoluteTtlMs: 2_592_000_000 },
    identity: { version: "identity-v1", candidateProofTtlMs: 60_000 },
    apple: {
      version: "apple-v1", clientId: "com.roomscan.test", redirectUri: "https://app.roomscan.example/auth/apple/callback", attemptTtlMs: 300_000, bridgeProofTtlMs: 60_000, verifiedAuthenticationReceiptTtlMs: 60_000,
      transport: {
        request: async () => ({ status: 200, headers: { "content-type": "application/json" }, body: Buffer.from(JSON.stringify({ id_token: signedAppleIdToken(publicApple.privateKey, appleNonce, now) })) }),
      },
      privateKeySecrets: { read: async () => applePem }, privateKeySecretName: "apple-p8", teamId: "TEAM123456", keyId: "KEY1234567", clientSecretLifetimeSeconds: 300,
      exchangeTimeoutMs: 1_000, exchangeMaxResponseBytes: 4_096,
      jwks: { fetch: async () => [{ ...appleJwk, kid: "apple-key", use: "sig", alg: "RS256" }] }, jwksCacheTtlMs: 60_000, clockSkewMs: 30_000, maxTokenAgeMs: 300_000,
      cognito: {
        adminAuthenticate: async (input) => {
          issuedAccessDigest = Buffer.from(input.challenge.accessTokenHash, "base64url");
          issuedFamilyPublicId = input.challenge.familyPublicId;
          ordering.push("cognito");
          return { outcome: "authenticated" as const };
        },
        adminLink: async () => undefined,
      },
    },
    stripe: { handle: async () => ({ statusCode: 200, headers: { "cache-control": "no-store", "content-type": "application/json" }, body: "{}" }) },
    magicDeliveryWake: { notify: async () => { ordering.push("magic-wake"); } },
  });

  const responses = new Map<string, number>();
  responses.set("health", (await handler(request("GET", "/health"))).statusCode);
  const appleBegin = await handler(request("POST", "/auth/apple/begin", { codeChallenge: "c".repeat(43) }));
  responses.set("apple.begin", appleBegin.statusCode);
  appleNonce = (JSON.parse(appleBegin.body) as { nonce: string }).nonce;
  const beginPayload = JSON.parse(appleBegin.body) as { attemptId: string; state: string };
  const magicRequest = await handler(request("POST", "/auth/magic-link/request", { email: "relay@privaterelay.appleid.com", purpose: "sign-in", codeChallenge: "c".repeat(43) }, { sourceIp: "198.51.100.24" }));
  responses.set("magic.request", magicRequest.statusCode);
  responses.set("magic.confirm", (await handler(request("GET", "/auth/magic-link/AAAAAAAAAAAAAAAAAAAAAA"))).statusCode);
  const magicConsume = await handler(request("POST", "/auth/magic-link/consume", { selector: "AAAAAAAAAAAAAAAAAAAAAA", secret: "s".repeat(43), purpose: "sign-in" }, { requestId: "scanner-1" }));
  responses.set("magic.consume", magicConsume.statusCode);
  const completionId = (JSON.parse(magicRequest.body) as { completionId: string }).completionId;
  const transferCode = (JSON.parse(magicConsume.body) as { transferCode: string }).transferCode;
  assert.match(completionId, /^[A-Za-z0-9_-]{43}$/u, magicRequest.body);
  assert.equal(Buffer.from(completionId, "base64url").toString("base64url"), completionId, magicRequest.body);
  assert.match(transferCode, /^[0-9A-HJKMNP-TV-Z]{8}$/u, magicConsume.body);
  const magicRedeem = await handler(request("POST", "/auth/magic-link/completion/redeem", { completionId, codeVerifier: "c".repeat(43), purpose: "sign-in", transferCode }, { sourceIp: "198.51.100.24" }));
  assert.equal(magicRedeem.statusCode, 200, `${magicRedeem.body} ${apiCalls.map((call) => call.sql.match(/roomscan\.([a-z_]+)/u)?.[1] ?? call.sql.slice(0, 24)).join(",")}`);
  responses.set("magic.redeem", magicRedeem.statusCode);
  const magicCandidate = await handler(request("POST", "/auth/magic-link/candidate/request", { email: "candidate@example.com", purpose: "link-identity", codeChallenge: "A".repeat(43) }, { sourceIp: "198.51.100.24", authorization: bearerToken() }));
  assert.equal(magicCandidate.statusCode, 202, magicCandidate.body);
  responses.set("magic.candidate.request", magicCandidate.statusCode);
  responses.set("apple.candidate.begin", (await handler(request("POST", "/auth/apple/candidate/begin", { codeChallenge: "d".repeat(43), purpose: "link-identity" }, { authorization: bearerToken() }))).statusCode);
  const appleFinish = await handler(request("POST", "/auth/apple/finish", { attemptId: beginPayload.attemptId, state: beginPayload.state, code: "provider-code", codeVerifier: "v".repeat(43) }));
  assert.equal(appleFinish.statusCode, 200, JSON.stringify(apiCalls.map((call) => call.sql.match(/roomscan\.([a-z_]+)/u)?.[1] ?? call.sql.slice(0, 24))));
  responses.set("apple.finish", appleFinish.statusCode);
  responses.set("session.refresh", (await handler(request("POST", "/auth/session/refresh", { refreshToken: bearerToken() }))).statusCode);
  responses.set("stripe.webhook", (await handler(rawRequest("/billing/stripe/webhook", "{}"))).statusCode);
  responses.set("session.logout", (await handler(request("POST", "/auth/session/logout", undefined, { authorization: bearerToken() }))).statusCode);
  const bootstrap = await handler(request("POST", "/workspace/bootstrap", { slug: "new-room", displayName: "New room" }, { authorization: bearerToken() }));
  assert.equal(bootstrap.statusCode, 200, bootstrap.body);
  responses.set("workspace.bootstrap", bootstrap.statusCode);
  const activate = await handler(request("POST", "/workspace/activate", { slug: "current-room" }, { authorization: bearerToken() }));
  assert.ok(apiCalls.some((call) => call.sql.includes("scope_session_workspace_v2")), JSON.stringify(apiCalls.map((call) => call.sql)));
  assert.equal(activate.statusCode, 200, `${activate.body} ${apiCalls.map((call) => call.sql.match(/roomscan\.([a-z_]+)/u)?.[1] ?? call.sql.slice(0, 24)).join(",")}`);
  responses.set("workspace.activate", activate.statusCode);
  const workspace = await handler(request("GET", "/workspace", undefined, { authorization: bearerToken() }));
  responses.set("workspace.get", workspace.statusCode);
  responses.set("membership.get", (await handler(request("GET", "/membership", undefined, { authorization: bearerToken() }))).statusCode);
  responses.set("subscription.get", (await handler(request("GET", "/subscription", undefined, { authorization: bearerToken() }))).statusCode);
  responses.set("quota.get", (await handler(request("GET", "/quota", undefined, { authorization: bearerToken() }))).statusCode);
  const identityMutation = await handler(request("POST", "/identity/mutate", { purpose: "link-identity", candidateIssuer: "apple", verifiedAuthenticationReceiptToken: "w".repeat(43), confirmed: true }, { authorization: bearerToken() }));
  assert.equal(identityMutation.statusCode, 200, identityMutation.body);
  responses.set("identity.mutate", identityMutation.statusCode);

  assert.deepEqual([...responses.values()], [200, 200, 202, 200, 202, 200, 202, 200, 200, 200, 200, 200, 200, 200, 200, 200, 200, 200, 200]);
  const workspaceBody = JSON.parse(workspace.body) as Record<string, unknown>;
  assert.deepEqual(workspaceBody, { slug: "current-room", displayName: "Current room", principalCanonicalId: PRINCIPAL, role: "owner", authorizationVersion: 4 });
  assert.equal(workspace.body.includes("33333333-"), false);
  const nonceCall = apiCalls.find((call) => call.sql.includes("claim_apple_nonce"));
  const acceptedCall = apiCalls.find((call) => call.sql.includes("accept_apple_verified_result_v2"));
  assert.equal(nonceCall?.transactionId, acceptedCall?.transactionId);
  assert.equal(apiCalls.some((call) => call.sql.includes("read_quota_overview_v2") && call.parameters.some((parameter) => parameter.name === "workspace_id" || parameter.name === "period_key")), false);
  const magicIssueIndex = apiCalls.findIndex((call) => call.sql.includes("issue_magic_challenge_v3"));
  assert.ok(magicIssueIndex >= 0);
  assert.equal(apiCalls.some((call) => call.sql.includes("issue_magic_challenge_v2") || call.sql.includes("consume_magic_challenge_v2")), false, "production HTTP composition must not retain a revoked v2 magic capability path");
  assert.ok(ordering.indexOf("magic-wake") > ordering.indexOf(`commit:${apiCalls[magicIssueIndex]!.transactionId}`));
  assert.ok(ordering.includes("cognito"));
});

function publicMagicShapeHandler(
  outcome: "issued" | "address_rate_limited" | "network_rate_limited" | "professional_sign_in_disabled" | "throw",
  notify?: () => Promise<void>,
) {
  const now = Date.UTC(2030, 0, 1);
  return createSlice4DataApiApiHandler({
    apiClient: {
      begin: async () => ({ transactionId: "public-magic-shape" }),
      execute: async (input) => {
        if (!input.sql.includes("issue_magic_challenge_v3")) throw new Error("unexpected SQL");
        if (outcome === "throw") throw new Error("repository unavailable");
        if (outcome === "issued") return { rows: [{ status: "issued", selector: stringParameter(input.parameters, "selector"), expires_at: "2030-01-01T00:05:00.000Z" }] };
        return { rows: [{ status: outcome, selector: null, expires_at: null }] };
      },
      commit: async () => undefined,
      rollback: async () => undefined,
    },
    clock: { nowMs: () => now },
    random: { bytes: (length) => Buffer.alloc(length, 7) },
    keys: keys(),
    magic: {
      version: "magic-v3", ttlMs: 300_000, verifiedAuthenticationReceiptTtlMs: 60_000, keyId: "magic-v3", sealingKey: Buffer.alloc(32, 4),
      maxCompletionFailures: 5, redeemNetworkWindowSeconds: 60, maxRedeemNetworkFailures: 10,
      ratePolicy: { cooldownSeconds: 1, maxActiveLinks: 1, addressWindowSeconds: 60, maxAddressWindow: 1, addressDaySeconds: 86_400, maxAddressDay: 1, networkWindowSeconds: 60, maxNetworkWindow: 1 },
    },
    sessions: { version: "session-v1", accessTtlMs: 300_000, refreshInactivityTtlMs: 86_400_000, refreshAbsoluteTtlMs: 2_592_000_000 },
    identity: { version: "identity-v1", candidateProofTtlMs: 60_000 },
    apple: {
      version: "apple-v1", clientId: "com.roomscan.test", redirectUri: "https://app.roomscan.example/auth/apple/callback", attemptTtlMs: 300_000, bridgeProofTtlMs: 60_000, verifiedAuthenticationReceiptTtlMs: 60_000,
      transport: { request: async () => ({ status: 500, headers: {}, body: Buffer.alloc(0) }) }, privateKeySecrets: { read: async () => "" }, privateKeySecretName: "apple-p8",
      teamId: "TEAM123456", keyId: "KEY1234567", clientSecretLifetimeSeconds: 300, exchangeTimeoutMs: 1_000, exchangeMaxResponseBytes: 4_096,
      jwks: { fetch: async () => [] }, jwksCacheTtlMs: 60_000, clockSkewMs: 30_000, maxTokenAgeMs: 300_000,
      cognito: { adminAuthenticate: async () => ({ outcome: "authenticated" as const }), adminLink: async () => undefined },
    },
    stripe: { handle: async () => ({ statusCode: 200, headers: { "cache-control": "no-store", "content-type": "application/json" }, body: "{}" }) },
    ...(notify === undefined ? {} : { magicDeliveryWake: { notify } }),
  });
}

function request(method: "GET" | "POST", rawPath: string, body?: Readonly<Record<string, unknown>>, input: { readonly sourceIp?: string; readonly requestId?: string; readonly authorization?: string } = {}) {
  const encoded = body === undefined ? undefined : JSON.stringify(body);
  return {
    version: "2.0", rawPath, rawQueryString: "", headers: {
      ...(encoded === undefined ? {} : { "content-type": "application/json" }),
      ...(input.authorization === undefined ? {} : { authorization: `Bearer ${input.authorization}` }),
    }, ...(encoded === undefined ? {} : { body: encoded, isBase64Encoded: false }),
    requestContext: { ...(input.requestId === undefined ? {} : { requestId: input.requestId }), http: { method, ...(input.sourceIp === undefined ? {} : { sourceIp: input.sourceIp }) } },
  };
}

function rawRequest(rawPath: string, body: string) {
  return { version: "2.0", rawPath, rawQueryString: "", headers: { "content-type": "application/json" }, body, isBase64Encoded: false, requestContext: { http: { method: "POST" } } };
}

function keys() {
  return { accessTokenHmacKey: Buffer.alloc(32, 1), refreshTokenHmacKey: Buffer.alloc(32, 2), magicTokenHmacKey: Buffer.alloc(32, 3), magicAddressHmacKey: Buffer.alloc(32, 4), magicNetworkHmacKey: Buffer.alloc(32, 5), appleStateHmacKey: Buffer.alloc(32, 6), appleCodeHmacKey: Buffer.alloc(32, 7), appleBridgeProofHmacKey: Buffer.alloc(32, 8), verifiedAuthenticationReceiptHmacKey: Buffer.alloc(32, 9) } as const;
}

function incrementingRandom() { let value = 10; return { bytes: (length: number) => Buffer.alloc(length, value++) }; }
function bearerToken(): string { return Buffer.alloc(32, 3).toString("base64url"); }
function stringParameter(parameters: readonly SqlParameter[] | undefined, name: string): string { const value = parameters?.find((parameter) => parameter.name === name)?.value; if (value?.kind !== "string") throw new Error(`missing ${name}`); return value.value; }
function blobParameter(parameters: readonly SqlParameter[] | undefined, name: string): Uint8Array { const value = parameters?.find((parameter) => parameter.name === name)?.value; if (value?.kind !== "blob") throw new Error(`missing ${name}`); return Uint8Array.from(value.bytes); }
function resolvedAccess(familyPublicId = "fam_current_session") { return { principal_id: "11111111-1111-4111-8111-111111111111", canonical_principal_id: PRINCIPAL, family_id: "22222222-2222-4222-8222-222222222222", family_public_id: familyPublicId, workspace_id: "33333333-3333-4333-8333-333333333333", role: "owner", authorization_version: 4, authentication_epoch: 0, authenticated_at: "2030-01-01T00:00:00.000Z", recent_authentication: true }; }
function workspaceState() { return { principal_id: "11111111-1111-4111-8111-111111111111", principal_canonical_id: PRINCIPAL, family_id: "22222222-2222-4222-8222-222222222222", family_public_id: "fam_current_session", workspace_id: "33333333-3333-4333-8333-333333333333", workspace_slug: "current-room", workspace_display_name: "Current room", role: "owner", authorization_version: 4, authentication_epoch: 0, authenticated_at: "2030-01-01T00:00:00.000Z", recent_authentication: true, professional_sign_in_global_enabled: true, professional_sign_in_global_version: 1, hosted_global_enabled: true, hosted_global_version: 2, hosted_workspace_enabled: true, hosted_workspace_version: 3, publication_global_enabled: false, publication_global_version: 1, publication_workspace_enabled: false, publication_workspace_version: 1, editor_publishing_allowed: false, editor_publishing_policy_version: 0 }; }
function magicCompletionSessionRow(now: number) { return { status: "session_issued", purpose: "sign-in", principal_id: "11111111-1111-4111-8111-111111111111", principal_canonical_id: PRINCIPAL, family_id: "22222222-2222-4222-8222-222222222222", family_public_id: "fam_current_session", authentication_epoch: 0, workspace_id: null, role: null, authorization_version: null, access_expires_at: new Date(now + 300_000).toISOString(), receipt_expires_at: null }; }
function bootstrapWorkspaceRow() { return { workspace_id: "33333333-3333-4333-8333-333333333333", membership_id: "44444444-4444-4444-8444-444444444444", principal_id: "11111111-1111-4111-8111-111111111111", principal_canonical_id: PRINCIPAL, family_id: "22222222-2222-4222-8222-222222222222", family_public_id: "fam_current_session", authorization_version: 4 }; }
function scopeSessionRow() { return { workspace_id: "33333333-3333-4333-8333-333333333333", workspace_slug: "current-room", principal_id: "11111111-1111-4111-8111-111111111111", principal_canonical_id: PRINCIPAL, family_id: "22222222-2222-4222-8222-222222222222", family_public_id: "fam_current_session", role: "owner", authorization_version: 4 }; }
function candidateProofRow(now: number) { return { status: "minted", principal_id: "11111111-1111-4111-8111-111111111111", principal_canonical_id: PRINCIPAL, family_id: "22222222-2222-4222-8222-222222222222", family_public_id: "fam_current_session", proof_expires_at: new Date(now + 60_000).toISOString() }; }
function identityMutationRow() { return { status: "linked", principal_id: "11111111-1111-4111-8111-111111111111", principal_canonical_id: PRINCIPAL, family_id: "22222222-2222-4222-8222-222222222222", family_public_id: "fam_current_session", authentication_epoch: 1 }; }
function appleClaimRow(attemptId: string, nonce: Uint8Array, purpose: string, now: number) { return { status: "claimed", attempt_id: attemptId, attempt_state_hash: Buffer.alloc(32, 1), attempt_nonce_hash: nonce, attempt_code_challenge: "c".repeat(43), expected_client_id: "com.roomscan.test", redirect_uri: "https://app.roomscan.example/auth/apple/callback", created_at: new Date(now).toISOString(), expires_at: new Date(now + 300_000).toISOString(), policy_version: "apple-v1", purpose, initiating_principal_id: purpose === "sign-in" ? null : "11111111-1111-4111-8111-111111111111", initiating_family_id: purpose === "sign-in" ? null : "22222222-2222-4222-8222-222222222222", initiating_authenticated_at: purpose === "sign-in" ? null : new Date(now).toISOString(), claimed_at: new Date(now).toISOString() }; }
function rotatedSessionRow(now: number) { return { status: "rotated", principal_id: "11111111-1111-4111-8111-111111111111", principal_canonical_id: PRINCIPAL, family_id: "22222222-2222-4222-8222-222222222222", family_public_id: "fam_current_session", authentication_epoch: 0, workspace_id: null, role: null, authorization_version: null, access_expires_at: new Date(now + 300_000).toISOString() }; }
function logoutRow() { return { status: "revoked", principal_id: "11111111-1111-4111-8111-111111111111", principal_canonical_id: PRINCIPAL, family_id: "22222222-2222-4222-8222-222222222222", family_public_id: "fam_current_session" }; }
function subscriptionRow(now: number) { return { workspace_id: "33333333-3333-4333-8333-333333333333", provider_account_id: "acct_server_owned", reconciliation_generation: 1, status: "active", plan_key: "test-only", current_period_end: null, source_observed_at: new Date(now).toISOString(), applied_at: new Date(now).toISOString() }; }
function quotaRows(now: number) { return (["project_count", "member_count", "working_bytes", "raw_bytes", "portal_bytes"] as const).map((metric) => ({ workspace_id: "33333333-3333-4333-8333-333333333333", metric, period_key: metric === "portal_bytes" ? "roomscan-period-v1:2030-01" : "roomscan-period-v1:lifetime", policy_version: 1, used: 0, reserved: 0, limit_value: 10, warning_threshold_percent: 80, reconciliation_generation: 0, updated_at: new Date(now).toISOString() })); }
function signedAppleIdToken(privateKey: ReturnType<typeof generateKeyPairSync>["privateKey"], nonce: string, now: number): string { const header = Buffer.from(JSON.stringify({ alg: "RS256", kid: "apple-key", typ: "JWT" })).toString("base64url"); const payload = Buffer.from(JSON.stringify({ iss: "https://appleid.apple.com", aud: "com.roomscan.test", sub: "apple-subject", nonce, iat: Math.floor(now / 1_000), exp: Math.floor((now + 60_000) / 1_000) })).toString("base64url"); const input = `${header}.${payload}`; return `${input}.${sign("RSA-SHA256", Buffer.from(input), privateKey).toString("base64url")}`; }
