import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import vm from "node:vm";

import {
  createSlice4RouteApplications,
  createSlice4RouteHandlers,
  createSlice4StripeIngressApplication,
  createSlice4StripeReconciliationWorker,
} from "../src/composition/runtime.js";
import { SLICE4_ROUTE_MANIFEST } from "../src/contracts/route-manifest.js";
import type { DataApiClient } from "../src/adapters/data-api.js";
import type { HttpApiV2Response } from "../src/http/http-api-v2.js";

const ok: HttpApiV2Response = { statusCode: 200, headers: { "cache-control": "no-store", "content-type": "application/json" }, body: "{}" };

test("service runtime produces exactly the sealed route handlers from a provider-neutral application port", async () => {
  const calls: string[] = [];
  const application = Object.fromEntries(SLICE4_ROUTE_MANIFEST.map((route) => [route.id, async () => { calls.push(route.id); return ok; }]));
  const handlers = createSlice4RouteHandlers(application);
  assert.deepEqual(Object.keys(handlers).sort(), SLICE4_ROUTE_MANIFEST.map((route) => route.id).sort());
  assert.equal((await handlers["health.get"]!({ routeId: "health.get", pathParameters: {}, serverDerived: {}, rawEnvelope: {} })).statusCode, 200);
  assert.deepEqual(calls, ["health.get"]);
});

test("concrete route application keeps magic enumeration uniform, scanner-safe, and maps Apple/session/workspace reads without private IDs", async () => {
  const calls: Array<Readonly<Record<string, unknown>>> = [];
  const application = createSlice4RouteApplications({
    magic: {
      request: async (input) => { calls.push({ kind: "magic.request", ...input }); throw new Error("directory unavailable"); },
      requestCandidate: async (input) => { calls.push({ kind: "magic.candidate.request", ...input }); return { completionId: "m".repeat(43), expiresAt: "2030-01-01T00:05:00.000Z" }; },
      consume: async (input) => { calls.push({ kind: "magic.consume", ...input }); return { status: "confirmed", transferCode: "ABCDEFGH", expiresAt: "2030-01-01T00:05:00.000Z" } as const; },
      redeem: async (input) => { calls.push({ kind: "magic.redeem", ...input }); return { status: "pending" } as const; },
    },
    apple: {
      begin: async (input) => { calls.push({ kind: "apple.begin", ...input }); return { attemptId: "apple_attempt_0007", state: "s".repeat(43), nonce: "n".repeat(43), expiresAtMs: 1_893_456_300_000 }; },
      beginCandidate: async (input) => { calls.push({ kind: "apple.candidate", ...input }); return { attemptId: "apple_candidate_0007", state: "c".repeat(43), nonce: "o".repeat(43), expiresAtMs: 1_893_456_300_000 }; },
      finish: async (input) => { calls.push({ kind: "apple.finish", ...input }); return { status: "authenticated", principalCanonicalId: "prn_abcdefghijklmnopqrstuv", familyPublicId: "fam_abcdefghijklmnop", accessToken: "b".repeat(43), refreshToken: "q".repeat(43), accessExpiresAtMs: 1_893_456_300_000 }; },
    },
    sessions: {
      refresh: async (input) => { calls.push({ kind: "session.refresh", ...input }); return { accessToken: "z".repeat(43), refreshToken: "y".repeat(43), accessExpiresAtMs: 1_893_456_300_000 }; },
      logout: async (input) => { calls.push({ kind: "session.logout", ...input }); },
    },
    workspace: {
      bootstrap: async (input) => { calls.push({ kind: "workspace.bootstrap", ...input }); return { slug: input.slug, displayName: input.displayName, principalCanonicalId: input.context.principalPublicId, familyPublicId: "fam_abcdefghijklmnop", role: "owner", authorizationVersion: 1 } as const; },
      activate: async (input) => { calls.push({ kind: "workspace.activate", ...input }); return { slug: input.slug, principalCanonicalId: input.context.principalPublicId, familyPublicId: "fam_abcdefghijklmnop", role: "owner", authorizationVersion: 1 } as const; },
      read: async (input) => { calls.push({ kind: "workspace.read", ...input }); return { slug: "current-room", displayName: "Current room", principalCanonicalId: input.context.principalPublicId, role: "owner", authorizationVersion: 1 }; },
      membership: async (input) => { calls.push({ kind: "membership.read", ...input }); return [{ principalCanonicalId: input.context.principalPublicId, role: "owner", state: "active", authorizationVersion: 1 }]; },
      subscription: async (input) => { calls.push({ kind: "subscription.read", ...input }); return { status: "active", planKey: "test-only", generation: 1 }; },
      quota: async (input) => { calls.push({ kind: "quota.read", ...input }); return input.metrics.map((metric) => ({ metric, used: 0, reserved: 0, limit: 3, warning: false, overLimit: false })); },
    },
    identity: { mutate: async (input) => { calls.push({ kind: "identity.mutate", ...input }); return { status: input.purpose === "link-identity" ? "linked" : "unlinked", authenticationEpoch: 1 } as const; } },
    stripe: { handle: async () => ok },
  });
  const publicRequest = { rawEnvelope: {}, pathParameters: {}, serverDerived: { sourceIp: "198.51.100.24" }, routeId: "magic.request", body: { email: "person@example.com", purpose: "sign-in", codeChallenge: "c".repeat(43) } } as const;
  assert.equal((await application["magic.request"]!(publicRequest)).statusCode, 202);
  const scanner = await application["magic.confirm"]!({ rawEnvelope: {}, pathParameters: { selector: "secret-selector" }, serverDerived: {}, routeId: "magic.confirm" });
  assert.equal(scanner.body.includes("secret-selector"), false);
  assert.match(scanner.headers["content-security-policy"] ?? "", /connect-src 'self'/u);
  const consume = await application["magic.consume"]!({ rawEnvelope: {}, pathParameters: {}, serverDerived: { clickingDeviceId: "apigw:req-1" }, routeId: "magic.consume", body: { selector: "selector-12345678", secret: "x".repeat(43), purpose: "sign-in" } });
  assert.equal(consume.statusCode, 202);
  const context = { principalPublicId: "prn_abcdefghijklmnopqrstuv", transactionMarker: Symbol("route"), repositories: { contract: "roomscan-transaction-repositories-v1" as const, transactionMarker: Symbol("bundle") } };
  assert.equal((await application["apple.candidate.begin"]!({ rawEnvelope: {}, pathParameters: {}, serverDerived: {}, routeId: "apple.candidate.begin", body: { codeChallenge: "c".repeat(43), purpose: "link-identity" } }, context)).statusCode, 200);
  assert.equal((await application["apple.finish"]!({ rawEnvelope: {}, pathParameters: {}, serverDerived: {}, executionLane: "apple-api-exchange-cognito-challenge-session", routeId: "apple.finish", body: { attemptId: "apple_attempt_0007", state: "s".repeat(43), code: "code", codeVerifier: "v".repeat(43) } })).statusCode, 200);
  assert.equal((await application["session.refresh"]!({ rawEnvelope: {}, pathParameters: {}, serverDerived: {}, executionLane: "session-refresh-hash-rotation", routeId: "session.refresh", body: { refreshToken: "r".repeat(43) } })).statusCode, 200);
  assert.equal((await application["workspace.get"]!({ rawEnvelope: {}, pathParameters: {}, serverDerived: {}, routeId: "workspace.get" }, context)).body.includes("11111111-"), false);
  assert.equal((await application["quota.get"]!({ rawEnvelope: {}, pathParameters: {}, serverDerived: { quotaMetrics: ["project_count", "member_count", "working_bytes", "raw_bytes", "portal_bytes"] }, routeId: "quota.get" }, context)).statusCode, 200);
  assert.equal((await application["workspace.bootstrap"]!({ rawEnvelope: {}, pathParameters: {}, serverDerived: {}, routeId: "workspace.bootstrap", body: { slug: "current-room", displayName: "Current room" } }, context)).statusCode, 200);
  assert.equal((await application["workspace.activate"]!({ rawEnvelope: {}, pathParameters: {}, serverDerived: {}, routeId: "workspace.activate", body: { slug: "current-room" } }, context)).statusCode, 200);
  assert.equal((await application["identity.mutate"]!({ rawEnvelope: {}, pathParameters: {}, serverDerived: {}, routeId: "identity.mutate", body: { purpose: "link-identity", candidateIssuer: "apple", verifiedAuthenticationReceiptToken: "v".repeat(43), confirmed: true } }, context)).statusCode, 200);
  assert.equal(calls.find((call) => call.kind === "magic.request")?.sourceIp, "198.51.100.24");
  assert.equal(calls.find((call) => call.kind === "magic.consume")?.clickingDeviceId, "apigw:req-1");
});

test("magic browser confirmation returns a transfer code but never an app session or verified-auth receipt", async () => {
  const accessToken = "a".repeat(43);
  const refreshToken = "r".repeat(43);
  const receiptToken = "v".repeat(43);
  const application = createSlice4RouteApplications({
    magic: {
      request: async () => ({ completionId: "m".repeat(43), expiresAt: "2030-01-01T00:05:00.000Z" }),
      requestCandidate: async () => ({ completionId: "m".repeat(43), expiresAt: "2030-01-01T00:05:00.000Z" }),
      consume: async () => ({ status: "confirmed", transferCode: "ABCDEFGH", expiresAt: "2030-01-01T00:05:00.000Z" } as const),
      redeem: async () => ({ status: "pending" } as const),
    },
    apple: {
      begin: async () => ({ attemptId: "apple_attempt_0007", state: "s".repeat(43), nonce: "n".repeat(43), expiresAtMs: 1_893_456_300_000 }),
      beginCandidate: async () => ({ attemptId: "apple_candidate_0007", state: "c".repeat(43), nonce: "o".repeat(43), expiresAtMs: 1_893_456_300_000 }),
      finish: async () => ({ status: "verified-auth-receipt", receiptToken, expiresAtMs: 1_893_456_300_000 }),
    },
    sessions: { refresh: async () => ({ accessToken, refreshToken, accessExpiresAtMs: 1_893_456_300_000 }), logout: async () => undefined },
    workspace: {
      bootstrap: async (input) => ({ slug: input.slug, displayName: input.displayName, principalCanonicalId: "prn_current_principal", familyPublicId: "fam_abcdefghijklmnop", role: "owner" as const, authorizationVersion: 1 }),
      activate: async (input) => ({ slug: input.slug, principalCanonicalId: "prn_current_principal", familyPublicId: "fam_abcdefghijklmnop", role: "owner" as const, authorizationVersion: 1 }),
      read: async () => ({ slug: "current-room", displayName: "Current room", principalCanonicalId: "prn_current_principal", role: "owner", authorizationVersion: 1 }),
      membership: async () => [], subscription: async () => undefined, quota: async () => [],
    },
    identity: { mutate: async () => ({ status: "linked" as const, authenticationEpoch: 1 }) },
    stripe: { handle: async () => ok },
  });

  const response = await application["magic.consume"]!({
    rawEnvelope: {}, pathParameters: {}, serverDerived: { clickingDeviceId: "apigw:browser-click-1" }, routeId: "magic.consume",
    body: { selector: "selector-12345678", secret: "x".repeat(43), purpose: "sign-in" },
  });

  assert.equal(response.statusCode, 202);
  assert.deepEqual(JSON.parse(response.body), { confirmed: true, transferCode: "ABCDEFGH", expiresAt: "2030-01-01T00:05:00.000Z" });
  assert.equal(response.body.includes(accessToken), false);
  assert.equal(response.body.includes(refreshToken), false);
  assert.equal(response.body.includes(receiptToken), false);
  assert.equal(response.body.includes("selector-12345678"), false);
});

test("scanner confirmation cannot consume until a person deliberately submits the static form", async () => {
  const application = createSlice4RouteApplications({
    magic: {
      request: async () => ({ completionId: "m".repeat(43), expiresAt: "2030-01-01T00:05:00.000Z" }),
      requestCandidate: async () => ({ completionId: "m".repeat(43), expiresAt: "2030-01-01T00:05:00.000Z" }),
      consume: async () => ({ status: "rejected" } as const),
      redeem: async () => ({ status: "pending" } as const),
    },
    apple: {
      begin: async () => ({ attemptId: "apple_attempt_0007", state: "s".repeat(43), nonce: "n".repeat(43), expiresAtMs: 1_893_456_300_000 }),
      beginCandidate: async () => ({ attemptId: "apple_candidate_0007", state: "c".repeat(43), nonce: "o".repeat(43), expiresAtMs: 1_893_456_300_000 }),
      finish: async () => ({ status: "verified-auth-receipt", receiptToken: "r".repeat(43), expiresAtMs: 1_893_456_300_000 }),
    },
    sessions: { refresh: async () => ({ accessToken: "a".repeat(43), refreshToken: "b".repeat(43), accessExpiresAtMs: 1_893_456_300_000 }), logout: async () => undefined },
    workspace: {
      bootstrap: async (input) => ({ slug: input.slug, displayName: input.displayName, principalCanonicalId: "prn_current_principal", familyPublicId: "fam_abcdefghijklmnop", role: "owner" as const, authorizationVersion: 1 }),
      activate: async (input) => ({ slug: input.slug, principalCanonicalId: "prn_current_principal", familyPublicId: "fam_abcdefghijklmnop", role: "owner" as const, authorizationVersion: 1 }),
      read: async () => ({ slug: "current-room", displayName: "Current room", principalCanonicalId: "prn_current_principal", role: "owner", authorizationVersion: 1 }),
      membership: async () => [], subscription: async () => undefined, quota: async () => [],
    },
    identity: { mutate: async () => ({ status: "linked" as const, authenticationEpoch: 1 }) },
    stripe: { handle: async () => ok },
  });
  const secret = "s".repeat(43);
  const purpose = "link-identity";
  const scanner = await application["magic.confirm"]!({ rawEnvelope: {}, pathParameters: { selector: "secret-selector" }, serverDerived: {}, routeId: "magic.confirm" });
  assert.match(scanner.body, /<form id="magic-link-confirm">/u);
  assert.equal(scanner.body.includes(secret), false);
  assert.equal(scanner.body.includes(`#secret=${secret}&purpose=${purpose}`), false);
  const script = /<script>([\s\S]+)<\/script>/u.exec(scanner.body)?.[1];
  assert.notEqual(script, undefined);
  const expectedScriptHash = createHash("sha256").update(script!, "utf8").digest("base64");
  assert.match(scanner.headers["content-security-policy"] ?? "", new RegExp(`script-src 'sha256-${expectedScriptHash.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&")}'`, "u"));
  const posts: Array<readonly [unknown, unknown]> = [];
  const historyPaths: string[] = [];
  let submit: ((event: { readonly isTrusted?: boolean; preventDefault(): void }) => Promise<void>) | undefined;
  const button = {
    disabled: false,
    setAttribute: (name: string) => { if (name === "disabled") button.disabled = true; },
    removeAttribute: (name: string) => { if (name === "disabled") button.disabled = false; },
  };
  const result = { textContent: "" };
  const sandbox = {
    URLSearchParams,
    window: {
      location: { hash: `#secret=${secret}&purpose=${purpose}`, pathname: "/auth/magic-link/selector-12345678" },
      history: { replaceState: (_state: unknown, _title: string, path: string) => { historyPaths.push(path); } },
    },
    document: {
      getElementById: (id: string) => id === "magic-link-confirm"
        ? { addEventListener: (_name: string, handler: (event: { readonly isTrusted?: boolean; preventDefault(): void }) => Promise<void>) => { submit = handler; } }
        : id === "magic-link-submit" ? button : id === "magic-link-result" ? result : null,
    },
    fetch: async (url: unknown, init: unknown) => { posts.push([url, init]); return { ok: true, json: async () => ({ confirmed: true, transferCode: "ABCDEFGH", expiresAt: "2030-01-01T00:05:00.000Z" }) }; },
  };
  new vm.Script(script!).runInNewContext(sandbox);
  assert.equal(posts.length, 0, "scanner JavaScript must not consume a link merely by loading the confirmation page");
  assert.deepEqual(historyPaths, ["/auth/magic-link/confirm"]);
  assert.equal(historyPaths.join("|").includes(secret), false);
  assert.equal(historyPaths.join("|").includes(purpose), false);
  assert.notEqual(submit, undefined);
  await submit!({ isTrusted: false, preventDefault: () => undefined });
  assert.equal(posts.length, 0, "synthetic submission cannot consume a link");
  await submit!({ isTrusted: true, preventDefault: () => undefined });
  assert.equal(posts.length, 1);
  assert.equal(posts[0]?.[0], "/auth/magic-link/consume");
  assert.deepEqual(JSON.parse((posts[0]?.[1] as { readonly body: string }).body), { selector: "selector-12345678", secret, purpose });
  assert.equal(button.disabled, true);
  assert.equal(result.textContent, "Enter this code only in the RoomScan Studio app that requested this email: ABCD-EFGH");
});

test("Stripe ingress application wires the authoritative webhook handler to the ingress-only durable repository", async () => {
  let tx = 0;
  const calls: string[] = [];
  const client: DataApiClient = {
    begin: async () => ({ transactionId: `tx-${++tx}` }),
    execute: async (input) => {
      calls.push(input.sql);
      if (input.sql.includes("accept_provider_audit_event")) return { rows: [{ accepted: true }] };
      return { rows: [{ status: "accepted", workspace_id: "11111111-1111-4111-8111-111111111111", generation: 1 }] };
    },
    commit: async () => { calls.push("commit"); }, rollback: async () => { calls.push("rollback"); },
  };
  const body = JSON.stringify({ object: "event", id: "evt_000007", type: "customer.subscription.updated", created: 1_893_456_000, data: { object: { id: "sub_serverowned0007", object: "subscription", customer: "cus_serverowned0007" } } });
  const secret = "stripe-test-secret";
  const signature = await signed(body, secret, 1_893_456_000);
  const application = createSlice4StripeIngressApplication({ client, signingSecret: secret, defaultStripeAccountId: "acct_serverowned0007", toleranceMs: 1_000, clock: { nowMs: () => 1_893_456_000_000 }, logger: { write: () => undefined } });
  const response = await application.handle({ body, isBase64Encoded: false, headers: { "stripe-signature": signature, "content-type": "application/json" } });
  assert.equal(response.statusCode, 200);
  assert.equal(calls.filter((sql) => sql.includes("accept_provider_audit_event")).length, 1);
  assert.equal(calls.at(-1), "commit");
});

test("Stripe reconciliation worker fetches authoritative state outside its role-bound database transactions", async () => {
  let tx = 0;
  const order: string[] = [];
  const client: DataApiClient = {
    begin: async () => ({ transactionId: `tx-${++tx}` }),
    execute: async (input) => {
      order.push(input.sql.includes("claim_stripe_reconciliation_v2") ? "claim" : input.sql.includes("complete_stripe_reconciliation_v2") ? "complete" : "sql");
      if (input.sql.includes("claim_stripe_reconciliation_v2")) return { rows: [{ workspace_id: "11111111-1111-4111-8111-111111111111", account_mode: "platform", provider_account_id: "acct_serverowned0007", billing_customer_id: "cus_serverowned0007", subscription_id: "sub_serverowned0007", generation: 1, lease_id: "01010101010101010101010101010101", last_event_type: null, last_object_id: null, hosted_global_version: 5, hosted_workspace_version: 7 }] };
      if (input.sql.includes("complete_stripe_reconciliation_v2")) return { rows: [{ status: "applied", needs_another_generation: false }] };
      return { rows: [] };
    }, commit: async () => { order.push("commit"); }, rollback: async () => { order.push("rollback"); },
  };
  const worker = createSlice4StripeReconciliationWorker({
    client, clock: { nowMs: () => 1_893_456_000_000 }, random: { bytes: () => Buffer.alloc(16, 1) }, leaseMs: 60_000,
    currentSubscriptions: { fetchCurrent: async () => { order.push("fetch"); return { status: "current", snapshot: { observedAtMs: 1_893_456_000_000, status: "active", planKey: "test-only" } } as const; } },
  });
  assert.deepEqual(await worker.runOnce(), { status: "applied", generation: 1, needsAnotherGeneration: false });
  assert.ok(order.indexOf("claim") < order.indexOf("fetch"));
  assert.ok(order.indexOf("fetch") < order.indexOf("complete"));
});

async function signed(body: string, secret: string, timestamp: number): Promise<string> {
  const { createHmac } = await import("node:crypto");
  return `t=${timestamp},v1=${createHmac("sha256", secret).update(String(timestamp)).update(".").update(body).digest("hex")}`;
}
