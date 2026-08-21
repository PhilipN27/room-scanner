import { createHash } from "node:crypto";

import type { HttpApiV2Envelope, HttpApiV2Response } from "../http/http-api-v2.js";
import type { AuthorizedOperationContext, NormalizedRouteRequest, RouteHandler } from "../handlers/factory.js";
import type { QuotaMetric } from "../quota/quota-v2-service.js";

/** Narrow, service-domain operations for the sealed HTTP routes. These are
 * intentionally not route handlers: the factory below owns all HTTP shape,
 * scanner safety, exact public/protected hand-off, and response redaction. */
export type Slice4MagicPurpose = "sign-in" | "reauthenticate" | "link-identity" | "unlink-identity";
export type Slice4IdentityPurpose = Extract<Slice4MagicPurpose, "link-identity" | "unlink-identity">;
export interface MagicCompletionIssueHttpResult {
  readonly completionId: string;
  readonly expiresAt: string;
}
export interface Slice4MagicRoutePort {
  request(input: { readonly email: string; readonly purpose: "sign-in" | "reauthenticate"; readonly codeChallenge: string; readonly sourceIp: string }): Promise<MagicCompletionIssueHttpResult>;
  requestCandidate(input: { readonly context: AuthorizedOperationContext; readonly email: string; readonly purpose: Slice4IdentityPurpose; readonly codeChallenge: string; readonly sourceIp: string }): Promise<MagicCompletionIssueHttpResult>;
  consume(input: { readonly selector: string; readonly secret: string; readonly purpose: Slice4MagicPurpose; readonly clickingDeviceId: string }): Promise<
    | Readonly<{ readonly status: "confirmed"; readonly transferCode: string; readonly expiresAt: string }>
    | Readonly<{ readonly status: "rejected" }>
  >;
  redeem(input: { readonly completionId: string; readonly codeVerifier: string; readonly purpose: Slice4MagicPurpose; readonly transferCode: string; readonly sourceIp: string }): Promise<
    | Readonly<{ readonly status: "pending" }>
    | Readonly<{ readonly status: "authenticated"; readonly principalCanonicalId: string; readonly familyPublicId: string; readonly accessToken: string; readonly refreshToken: string; readonly accessExpiresAt: string }>
    | Readonly<{ readonly status: "verified-auth-receipt"; readonly principalCanonicalId: string; readonly verifiedAuthenticationReceiptToken: string; readonly receiptExpiresAt: string }>
    | Readonly<{ readonly status: "rejected" }>
  >;
}

export interface Slice4AppleRoutePort {
  begin(input: { readonly codeChallenge: string }): Promise<AppleBeginHttpResult>;
  beginCandidate(input: { readonly context: AuthorizedOperationContext; readonly codeChallenge: string; readonly purpose: "link-identity" | "unlink-identity" }): Promise<AppleBeginHttpResult>;
  finish(input: { readonly attemptId: string; readonly state: string; readonly code: string; readonly codeVerifier: string }): Promise<
    | Readonly<{ readonly status: "authenticated"; readonly principalCanonicalId: string; readonly familyPublicId: string; readonly accessToken: string; readonly refreshToken: string; readonly accessExpiresAtMs: number }>
    | Readonly<{ readonly status: "verified-auth-receipt"; readonly receiptToken: string; readonly expiresAtMs: number }>
  >;
}
export interface AppleBeginHttpResult { readonly attemptId: string; readonly state: string; readonly nonce: string; readonly expiresAtMs: number; }

export interface Slice4SessionRoutePort {
  refresh(input: { readonly refreshToken: string }): Promise<{ readonly accessToken: string; readonly refreshToken: string; readonly accessExpiresAtMs: number }>;
  logout(input: { readonly context: AuthorizedOperationContext }): Promise<void>;
}

export interface Slice4WorkspaceReadRoutePort {
  bootstrap(input: { readonly context: AuthorizedOperationContext; readonly slug: string; readonly displayName: string }): Promise<Readonly<{ readonly slug: string; readonly displayName: string; readonly principalCanonicalId: string; readonly familyPublicId: string; readonly role: "owner"; readonly authorizationVersion: number }>>;
  activate(input: { readonly context: AuthorizedOperationContext; readonly slug: string }): Promise<Readonly<{ readonly slug: string; readonly principalCanonicalId: string; readonly familyPublicId: string; readonly role: "owner" | "admin" | "editor" | "viewer"; readonly authorizationVersion: number }>>;
  read(input: { readonly context: AuthorizedOperationContext }): Promise<Readonly<{ readonly slug: string; readonly displayName: string; readonly principalCanonicalId: string; readonly role: "owner" | "admin" | "editor" | "viewer"; readonly authorizationVersion: number }>>;
  membership(input: { readonly context: AuthorizedOperationContext }): Promise<readonly Readonly<{ readonly principalCanonicalId: string; readonly role: "owner" | "admin" | "editor" | "viewer"; readonly state: "active"; readonly authorizationVersion: number }>[] >;
  subscription(input: { readonly context: AuthorizedOperationContext }): Promise<Readonly<{ readonly status: "inactive" | "trialing" | "active" | "past_due" | "canceled" | "read_only_grace"; readonly planKey: string; readonly generation: number; readonly currentPeriodEndMs?: number }> | undefined>;
  quota(input: { readonly context: AuthorizedOperationContext; readonly metrics: readonly QuotaMetric[] }): Promise<readonly Readonly<{ readonly metric: QuotaMetric; readonly used: number; readonly reserved: number; readonly limit: number; readonly warning: boolean; readonly overLimit: boolean }>[] >;
}

export interface Slice4IdentityRoutePort {
  mutate(input: {
    readonly context: AuthorizedOperationContext;
    readonly purpose: Slice4IdentityPurpose;
    readonly candidateIssuer: "apple" | "email";
    readonly verifiedAuthenticationReceiptToken: string;
    readonly confirmed: true;
  }): Promise<Readonly<{ readonly status: "linked" | "unlinked"; readonly authenticationEpoch: number }>>;
}

export interface Slice4StripeRoutePort {
  handle(envelope: HttpApiV2Envelope): Promise<HttpApiV2Response>;
}

export interface Slice4RouteApplicationDependencies {
  readonly magic: Slice4MagicRoutePort;
  readonly apple: Slice4AppleRoutePort;
  readonly sessions: Slice4SessionRoutePort;
  readonly workspace: Slice4WorkspaceReadRoutePort;
  readonly identity: Slice4IdentityRoutePort;
  readonly stripe: Slice4StripeRoutePort;
}

/**
 * Produces every route in the frozen manifest from typed domain ports. It is
 * deliberate that infrastructure cannot author a map, choose a path, or add a
 * handler; it supplies AWS transports/role-bound clients only to the concrete
 * domain-port composition that sits beneath this factory.
 */
export function createSlice4RouteApplications(input: Slice4RouteApplicationDependencies): Readonly<Record<string, RouteHandler>> {
  assertDependencies(input);
  const handlers: Record<string, RouteHandler> = {
    "health.get": async () => json(200, { status: "ok" }),
    "magic.request": async (request) => magicRequest(input.magic, request),
    "magic.candidate.request": async (request, context) => magicCandidateRequest(input.magic, request, context),
    "magic.confirm": async () => scannerHtml(),
    "magic.consume": async (request) => magicConsume(input.magic, request),
    "magic.completion.redeem": async (request) => magicRedeem(input.magic, request),
    "apple.begin": async (request) => appleBegin(input.apple, request),
    "apple.candidate.begin": async (request, context) => appleCandidateBegin(input.apple, request, context),
    "apple.finish": async (request) => appleFinish(input.apple, request),
    "session.refresh": async (request) => sessionRefresh(input.sessions, request),
    "stripe.webhook": async (request) => input.stripe.handle(request.rawEnvelope),
    "session.logout": async (_request, context) => logout(input.sessions, context),
    "workspace.bootstrap": async (request, context) => workspaceBootstrap(input.workspace, request, context),
    "workspace.activate": async (request, context) => workspaceActivate(input.workspace, request, context),
    "workspace.get": async (_request, context) => workspaceGet(input.workspace, context),
    "membership.get": async (_request, context) => membershipGet(input.workspace, context),
    "subscription.get": async (_request, context) => subscriptionGet(input.workspace, context),
    "quota.get": async (request, context) => quotaGet(input.workspace, request, context),
    "identity.mutate": async (request, context) => identityMutate(input.identity, request, context),
  };
  return Object.freeze(handlers);
}

const JSON_HEADERS = Object.freeze({ "cache-control": "no-store", "content-type": "application/json" });
/* The fragment is never interpolated into HTML. Loading this static page is
 * deliberately inert: a mail scanner may execute JavaScript, but it cannot
 * cause the one-time POST without a literal person-initiated form submit.
 * The exact script hash below keeps CSP strict without `unsafe-inline`. */
const SCANNER_CONFIRMATION_SCRIPT = `"use strict";
(() => {
  const fragment = new URLSearchParams(window.location.hash.startsWith("#") ? window.location.hash.slice(1) : "");
  const fragmentSecret = fragment.get("secret") ?? "";
  const purpose = fragment.get("purpose") ?? "";
  const selector = window.location.pathname.split("/").filter(Boolean).at(-1) ?? "";
  window.history.replaceState(null, "", "/auth/magic-link/confirm");
  const form = document.getElementById("magic-link-confirm");
  const button = document.getElementById("magic-link-submit");
  const validSecret = /^[A-Za-z0-9_-]{43}$/.test(fragmentSecret);
  const validPurpose = purpose === "sign-in" || purpose === "reauthenticate" || purpose === "link-identity" || purpose === "unlink-identity";
  if (form === null || button === null || !validSecret || !validPurpose) return;
  form.addEventListener("submit", async (event) => {
    if (event.isTrusted !== true) return;
    event.preventDefault();
    button.setAttribute("disabled", "");
    try {
      const response = await fetch("/auth/magic-link/consume", {
        method: "POST",
        credentials: "omit",
        referrerPolicy: "no-referrer",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ selector, secret: fragmentSecret, purpose }),
      });
      if (!response.ok) throw new Error("confirmation_failed");
      const payload = await response.json();
      if (payload === null || typeof payload !== "object" || payload.confirmed !== true || !/^[0-9A-HJKMNP-TV-Z]{8}$/.test(payload.transferCode ?? "")) throw new Error("confirmation_failed");
      const result = document.getElementById("magic-link-result");
      if (result !== null) result.textContent = "Enter this code only in the RoomScan Studio app that requested this email: " + payload.transferCode.slice(0, 4) + "-" + payload.transferCode.slice(4);
    } catch {
      button.removeAttribute("disabled");
    }
  });
})();`;
const SCANNER_CONFIRMATION_SCRIPT_HASH = createHash("sha256").update(SCANNER_CONFIRMATION_SCRIPT).digest("base64");
const SCANNER_CSP = `default-src 'none'; script-src 'sha256-${SCANNER_CONFIRMATION_SCRIPT_HASH}'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`;
const SCANNER_HTML = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="referrer" content="no-referrer"><title>Continue sign in</title></head><body><main><h1>Continue</h1><p>Confirm to continue in RoomScan Studio.</p><form id="magic-link-confirm"><button id="magic-link-submit" type="submit">Continue</button></form><p id="magic-link-result" aria-live="polite"></p></main><script>${SCANNER_CONFIRMATION_SCRIPT}</script></body></html>`;

async function magicRequest(port: Slice4MagicRoutePort, request: NormalizedRouteRequest): Promise<HttpApiV2Response> {
  const body = record(request.body); const email = string(body?.email); const purpose = publicPurpose(body?.purpose); const codeChallenge = string(body?.codeChallenge); const sourceIp = string(request.serverDerived.sourceIp);
  // The public response remains indistinguishable for malformed/disabled/
  // throttled/unavailable identities. The handler deliberately swallows the
  // domain result after route validation has accepted the body shape.
  if (email !== undefined && purpose !== undefined && codeChallenge !== undefined && sourceIp !== undefined) {
    try {
      const result = await port.request({ email, purpose, codeChallenge, sourceIp });
      if (validCompletionIssue(result)) return json(202, { accepted: true, completionId: result.completionId, expiresAt: result.expiresAt });
    } catch { /* anti-enumeration response remains accepted */ }
  }
  return json(202, { accepted: true });
}

async function magicCandidateRequest(port: Slice4MagicRoutePort, request: NormalizedRouteRequest, context: AuthorizedOperationContext | undefined): Promise<HttpApiV2Response> {
  const body = record(request.body); const email = string(body?.email); const purpose = identityPurpose(body?.purpose); const codeChallenge = string(body?.codeChallenge); const sourceIp = string(request.serverDerived.sourceIp);
  if (context === undefined || email === undefined || purpose === undefined || codeChallenge === undefined || sourceIp === undefined) return forbidden();
  try {
    const result = await port.requestCandidate({ context, email, purpose, codeChallenge, sourceIp });
    return validCompletionIssue(result) ? json(202, { accepted: true, completionId: result.completionId, expiresAt: result.expiresAt }) : unavailable();
  } catch { return unavailable(); }
}

async function magicConsume(port: Slice4MagicRoutePort, request: NormalizedRouteRequest): Promise<HttpApiV2Response> {
  const body = record(request.body); const selector = string(body?.selector); const secret = string(body?.secret); const purpose = allMagicPurpose(body?.purpose); const clickingDeviceId = string(request.serverDerived.clickingDeviceId);
  if (selector === undefined || secret === undefined || purpose === undefined || clickingDeviceId === undefined) return invalid();
  try {
    const result = await port.consume({ selector, secret, purpose, clickingDeviceId });
    if (result.status === "confirmed" && transferCode(result.transferCode) && canonicalTimestamp(result.expiresAt)) {
      return json(202, { confirmed: true, transferCode: result.transferCode, expiresAt: result.expiresAt });
    }
  } catch { /* indistinguishable failed confirmation */ }
  return invalid();
}

async function magicRedeem(port: Slice4MagicRoutePort, request: NormalizedRouteRequest): Promise<HttpApiV2Response> {
  const body = record(request.body); const completionId = string(body?.completionId); const codeVerifier = string(body?.codeVerifier); const purpose = allMagicPurpose(body?.purpose); const transferCodeValue = string(body?.transferCode); const sourceIp = string(request.serverDerived.sourceIp);
  if (completionId === undefined || codeVerifier === undefined || purpose === undefined || transferCodeValue === undefined || sourceIp === undefined) return invalid();
  try {
    const result = await port.redeem({ completionId, codeVerifier, purpose, transferCode: transferCodeValue, sourceIp });
    if (result.status === "pending") return json(202, { pending: true });
    if (result.status === "authenticated" && bounded(result.principalCanonicalId, 1, 128) && bounded(result.familyPublicId, 16, 128)
      && opaque(result.accessToken) && opaque(result.refreshToken) && result.accessToken !== result.refreshToken && canonicalTimestamp(result.accessExpiresAt)) {
      return json(200, { principalCanonicalId: result.principalCanonicalId, familyPublicId: result.familyPublicId, accessToken: result.accessToken, refreshToken: result.refreshToken, accessExpiresAt: result.accessExpiresAt });
    }
    if (result.status === "verified-auth-receipt" && bounded(result.principalCanonicalId, 1, 128) && opaque(result.verifiedAuthenticationReceiptToken) && canonicalTimestamp(result.receiptExpiresAt)) {
      return json(200, { principalCanonicalId: result.principalCanonicalId, verifiedAuthenticationReceiptToken: result.verifiedAuthenticationReceiptToken, receiptExpiresAt: result.receiptExpiresAt });
    }
  } catch { /* reject malformed/replayed completion uniformly */ }
  return invalid();
}

async function appleBegin(port: Slice4AppleRoutePort, request: NormalizedRouteRequest): Promise<HttpApiV2Response> {
  const codeChallenge = string(record(request.body)?.codeChallenge);
  if (codeChallenge === undefined) return invalid();
  try { return appleBeginResponse(await port.begin({ codeChallenge })); } catch { return unavailable(); }
}

async function appleCandidateBegin(port: Slice4AppleRoutePort, request: NormalizedRouteRequest, context: AuthorizedOperationContext | undefined): Promise<HttpApiV2Response> {
  const body = record(request.body); const codeChallenge = string(body?.codeChallenge); const purpose = identityPurpose(body?.purpose);
  if (context === undefined || codeChallenge === undefined || purpose === undefined) return forbidden();
  try { return appleBeginResponse(await port.beginCandidate({ context, codeChallenge, purpose })); } catch { return unavailable(); }
}

async function appleFinish(port: Slice4AppleRoutePort, request: NormalizedRouteRequest): Promise<HttpApiV2Response> {
  const body = record(request.body); const attemptId = string(body?.attemptId); const state = string(body?.state); const code = string(body?.code); const codeVerifier = string(body?.codeVerifier);
  if (request.executionLane !== "apple-api-exchange-cognito-challenge-session" || attemptId === undefined || state === undefined || code === undefined || codeVerifier === undefined) return invalid();
  try {
    const result = await port.finish({ attemptId, state, code, codeVerifier });
    if (result.status === "authenticated") return json(200, { principalCanonicalId: result.principalCanonicalId, familyPublicId: result.familyPublicId, accessToken: result.accessToken, refreshToken: result.refreshToken, accessExpiresAtMs: result.accessExpiresAtMs });
    return json(200, { verifiedAuthenticationReceiptToken: result.receiptToken, expiresAtMs: result.expiresAtMs });
  } catch { return invalid(); }
}

async function sessionRefresh(port: Slice4SessionRoutePort, request: NormalizedRouteRequest): Promise<HttpApiV2Response> {
  const refreshToken = string(record(request.body)?.refreshToken);
  if (request.executionLane !== "session-refresh-hash-rotation" || refreshToken === undefined) return invalid();
  try { return json(200, await port.refresh({ refreshToken })); } catch { return invalid(); }
}

async function logout(port: Slice4SessionRoutePort, context: AuthorizedOperationContext | undefined): Promise<HttpApiV2Response> {
  if (context === undefined) return forbidden();
  try { await port.logout({ context }); return json(200, { revoked: true }); } catch { return unavailable(); }
}

async function workspaceBootstrap(port: Slice4WorkspaceReadRoutePort, request: NormalizedRouteRequest, context: AuthorizedOperationContext | undefined): Promise<HttpApiV2Response> {
  const body = record(request.body); const slug = string(body?.slug); const displayName = string(body?.displayName);
  if (context === undefined || slug === undefined || displayName === undefined) return forbidden();
  try { return json(200, await port.bootstrap({ context, slug, displayName })); } catch { return unavailable(); }
}

async function workspaceActivate(port: Slice4WorkspaceReadRoutePort, request: NormalizedRouteRequest, context: AuthorizedOperationContext | undefined): Promise<HttpApiV2Response> {
  const slug = string(record(request.body)?.slug);
  if (context === undefined || slug === undefined) return forbidden();
  try { return json(200, await port.activate({ context, slug })); } catch { return unavailable(); }
}

async function workspaceGet(port: Slice4WorkspaceReadRoutePort, context: AuthorizedOperationContext | undefined): Promise<HttpApiV2Response> {
  if (context === undefined) return forbidden();
  try { return json(200, await port.read({ context })); } catch { return unavailable(); }
}

async function membershipGet(port: Slice4WorkspaceReadRoutePort, context: AuthorizedOperationContext | undefined): Promise<HttpApiV2Response> {
  if (context === undefined) return forbidden();
  try { return json(200, { members: await port.membership({ context }) }); } catch { return unavailable(); }
}

async function subscriptionGet(port: Slice4WorkspaceReadRoutePort, context: AuthorizedOperationContext | undefined): Promise<HttpApiV2Response> {
  if (context === undefined) return forbidden();
  try { const subscription = await port.subscription({ context }); return subscription === undefined ? json(200, { status: "inactive" }) : json(200, subscription); } catch { return unavailable(); }
}

async function quotaGet(port: Slice4WorkspaceReadRoutePort, request: NormalizedRouteRequest, context: AuthorizedOperationContext | undefined): Promise<HttpApiV2Response> {
  if (context === undefined || request.serverDerived.quotaMetrics === undefined || !validMetricList(request.serverDerived.quotaMetrics)) return forbidden();
  try { return json(200, { metrics: await port.quota({ context, metrics: request.serverDerived.quotaMetrics }) }); } catch { return unavailable(); }
}

async function identityMutate(port: Slice4IdentityRoutePort, request: NormalizedRouteRequest, context: AuthorizedOperationContext | undefined): Promise<HttpApiV2Response> {
  const body = record(request.body); const purpose = identityPurpose(body?.purpose); const candidateIssuer = body?.candidateIssuer === "apple" || body?.candidateIssuer === "email" ? body.candidateIssuer : undefined; const receipt = string(body?.verifiedAuthenticationReceiptToken);
  if (context === undefined || purpose === undefined || candidateIssuer === undefined || receipt === undefined || body?.confirmed !== true) return forbidden();
  try { return json(200, await port.mutate({ context, purpose, candidateIssuer, verifiedAuthenticationReceiptToken: receipt, confirmed: true })); } catch { return unavailable(); }
}

function appleBeginResponse(result: AppleBeginHttpResult): HttpApiV2Response {
  if (!bounded(result.attemptId, 16, 128) || !opaque(result.state) || !opaque(result.nonce) || !positiveTimestamp(result.expiresAtMs)) return unavailable();
  return json(200, result);
}
function validCompletionIssue(result: MagicCompletionIssueHttpResult): boolean { return opaque(result.completionId) && canonicalTimestamp(result.expiresAt); }
function scannerHtml(): HttpApiV2Response { return Object.freeze({ statusCode: 200, headers: Object.freeze({ "cache-control": "no-store", "content-security-policy": SCANNER_CSP, "content-type": "text/html; charset=utf-8", "referrer-policy": "no-referrer" }), body: SCANNER_HTML }); }
function json(statusCode: number, value: unknown): HttpApiV2Response { return Object.freeze({ statusCode, headers: JSON_HEADERS, body: JSON.stringify(value) }); }
function invalid(): HttpApiV2Response { return json(400, { error: { code: "invalid_request" } }); }
function forbidden(): HttpApiV2Response { return json(403, { error: { code: "forbidden" } }); }
function unavailable(): HttpApiV2Response { return json(503, { error: { code: "unavailable" } }); }
function record(value: unknown): Readonly<Record<string, unknown>> | undefined { return value !== null && typeof value === "object" && !Array.isArray(value) ? value as Readonly<Record<string, unknown>> : undefined; }
function string(value: unknown): string | undefined { return typeof value === "string" ? value : undefined; }
function publicPurpose(value: unknown): "sign-in" | "reauthenticate" | undefined { return value === "sign-in" || value === "reauthenticate" ? value : undefined; }
function allMagicPurpose(value: unknown): "sign-in" | "reauthenticate" | "link-identity" | "unlink-identity" | undefined { return publicPurpose(value) ?? identityPurpose(value); }
function identityPurpose(value: unknown): "link-identity" | "unlink-identity" | undefined { return value === "link-identity" || value === "unlink-identity" ? value : undefined; }
function bounded(value: unknown, min: number, max: number): value is string { return typeof value === "string" && value.length >= min && value.length <= max; }
function opaque(value: unknown): value is string { if (typeof value !== "string" || !/^[A-Za-z0-9_-]{43}$/u.test(value)) return false; const decoded = Buffer.from(value, "base64url"); return decoded.length === 32 && decoded.toString("base64url") === value; }
function transferCode(value: unknown): value is string { return typeof value === "string" && /^[0-9A-HJKMNP-TV-Z]{8}$/u.test(value); }
function canonicalTimestamp(value: unknown): value is string { if (typeof value !== "string") return false; const parsed = new Date(value); return Number.isSafeInteger(parsed.getTime()) && parsed.toISOString() === value; }
function positiveTimestamp(value: unknown): value is number { return typeof value === "number" && Number.isSafeInteger(value) && value > 0; }
function validMetricList(value: readonly QuotaMetric[]): boolean { return value.length === 5 && new Set(value).size === 5 && value.includes("project_count") && value.includes("member_count") && value.includes("working_bytes") && value.includes("raw_bytes") && value.includes("portal_bytes"); }
function assertDependencies(input: Slice4RouteApplicationDependencies): void {
  if (input === null || typeof input !== "object" || input.magic === null || input.apple === null || input.sessions === null || input.workspace === null || input.identity === null || input.stripe === null
    || typeof input.magic.request !== "function" || typeof input.magic.requestCandidate !== "function" || typeof input.magic.consume !== "function" || typeof input.magic.redeem !== "function" || typeof input.apple.begin !== "function" || typeof input.apple.beginCandidate !== "function" || typeof input.apple.finish !== "function"
    || typeof input.sessions.refresh !== "function" || typeof input.sessions.logout !== "function" || typeof input.workspace.bootstrap !== "function" || typeof input.workspace.activate !== "function" || typeof input.workspace.read !== "function" || typeof input.workspace.membership !== "function" || typeof input.workspace.subscription !== "function" || typeof input.workspace.quota !== "function" || typeof input.identity.mutate !== "function" || typeof input.stripe.handle !== "function") {
    throw new Error("invalid_slice4_route_application");
  }
}
