import type { AuthorizationAction } from "../authorization/policy.js";
import { QUOTA_METRICS, type QuotaMetric } from "../quota/quota-v2-service.js";

export type StringFieldRule = Readonly<{
  readonly type: "string";
  readonly required: boolean;
  readonly minLength: number;
  readonly maxLength: number;
  readonly pattern?: string;
  readonly enum?: readonly string[];
}>;
/** Literal booleans stay a distinct sealed field type. This prevents a
 * stringly confirmation like `"true"` from reaching a destructive reducer. */
export type BooleanFieldRule = Readonly<{
  readonly type: "boolean";
  readonly required: boolean;
  readonly literal?: boolean;
}>;
export type FieldRule = StringFieldRule | BooleanFieldRule;
export type RequestSchema = Readonly<{ readonly body: "none" | "json" | "raw"; readonly maximumBytes: number; readonly contentType?: "application/json"; readonly fields?: Readonly<Record<string, FieldRule>> }>;
export type RouteAuthorization =
  | Readonly<{ readonly kind: "public" }>
  | Readonly<{ readonly kind: "session"; readonly requiresRecentAuthentication: boolean }>
  | Readonly<{ readonly kind: "workspace"; readonly action: AuthorizationAction; readonly resourceResolver: "none" | "current-membership" }>;
export type RouteExecutionLane = "apple-api-exchange-cognito-challenge-session" | "session-refresh-hash-rotation";
export interface TrustedRouteInputs { readonly sourceIp?: "api-gateway-v2"; readonly clickingDeviceId?: "api-gateway-v2-request-id"; readonly quotaMetrics?: readonly QuotaMetric[]; }
export interface SealedRoute { readonly id: string; readonly method: "GET" | "POST"; readonly pathTemplate: string; readonly authorization: RouteAuthorization; readonly request: RequestSchema; readonly trustedInputs?: TrustedRouteInputs; readonly executionLane?: RouteExecutionLane; readonly responseKind: "json" | "scanner-html"; }

const publicMagicPurpose = ["sign-in", "reauthenticate"] as const;
const allMagicPurpose = ["sign-in", "reauthenticate", "link-identity", "unlink-identity"] as const;
const identityMutationPurpose = ["link-identity", "unlink-identity"] as const;
const string = (required: boolean, minLength: number, maxLength: number, extra: Omit<Partial<StringFieldRule>, "type" | "required" | "minLength" | "maxLength"> = {}): StringFieldRule => deepFreeze({ type: "string", required, minLength, maxLength, ...extra });
const literalBoolean = (required: boolean, literal: boolean): BooleanFieldRule => deepFreeze({ type: "boolean", required, literal });
const none = deepFreeze({ body: "none", maximumBytes: 0 } as const);
const json = (fields: Readonly<Record<string, FieldRule>>, maximumBytes = 16_384): RequestSchema => deepFreeze({ body: "json", maximumBytes, fields });
const raw = deepFreeze({ body: "raw", maximumBytes: 1_048_576, contentType: "application/json" } as const);

const routes: SealedRoute[] = [
  { id: "health.get", method: "GET", pathTemplate: "/health", authorization: { kind: "public" }, request: none, responseKind: "json" },
  { id: "magic.request", method: "POST", pathTemplate: "/auth/magic-link/request", authorization: { kind: "public" }, request: json({ email: string(true, 3, 320), purpose: string(true, 1, 32, { enum: publicMagicPurpose }), codeChallenge: string(true, 43, 43, { pattern: "^[A-Za-z0-9_-]+$" }) }), trustedInputs: { sourceIp: "api-gateway-v2" }, responseKind: "json" },
  { id: "magic.candidate.request", method: "POST", pathTemplate: "/auth/magic-link/candidate/request", authorization: { kind: "session", requiresRecentAuthentication: true }, request: json({ email: string(true, 3, 320), purpose: string(true, 1, 32, { enum: identityMutationPurpose }), codeChallenge: string(true, 43, 43, { pattern: "^[A-Za-z0-9_-]+$" }) }), trustedInputs: { sourceIp: "api-gateway-v2" }, responseKind: "json" },
  { id: "magic.confirm", method: "GET", pathTemplate: "/auth/magic-link/:selector", authorization: { kind: "public" }, request: none, responseKind: "scanner-html" },
  { id: "magic.consume", method: "POST", pathTemplate: "/auth/magic-link/consume", authorization: { kind: "public" }, request: json({ selector: string(true, 16, 128, { pattern: "^[A-Za-z0-9_-]+$" }), secret: string(true, 32, 128, { pattern: "^[A-Za-z0-9_-]+$" }), purpose: string(true, 1, 32, { enum: allMagicPurpose }) }), trustedInputs: { clickingDeviceId: "api-gateway-v2-request-id" }, responseKind: "json" },
  { id: "magic.completion.redeem", method: "POST", pathTemplate: "/auth/magic-link/completion/redeem", authorization: { kind: "public" }, request: json({ completionId: string(true, 43, 43, { pattern: "^[A-Za-z0-9_-]+$" }), codeVerifier: string(true, 43, 43, { pattern: "^[A-Za-z0-9_-]+$" }), purpose: string(true, 1, 32, { enum: allMagicPurpose }), transferCode: string(true, 8, 8, { pattern: "^[0-9A-HJKMNP-TV-Z]{8}$" }) }), trustedInputs: { sourceIp: "api-gateway-v2" }, responseKind: "json" },
  { id: "apple.begin", method: "POST", pathTemplate: "/auth/apple/begin", authorization: { kind: "public" }, request: json({ codeChallenge: string(true, 43, 43, { pattern: "^[A-Za-z0-9_-]+$" }) }), responseKind: "json" },
  { id: "apple.candidate.begin", method: "POST", pathTemplate: "/auth/apple/candidate/begin", authorization: { kind: "session", requiresRecentAuthentication: true }, request: json({ codeChallenge: string(true, 43, 43, { pattern: "^[A-Za-z0-9_-]+$" }), purpose: string(true, 1, 32, { enum: identityMutationPurpose }) }), responseKind: "json" },
  { id: "apple.finish", method: "POST", pathTemplate: "/auth/apple/finish", authorization: { kind: "public" }, request: json({ attemptId: string(true, 16, 128, { pattern: "^[A-Za-z0-9_-]+$" }), state: string(true, 43, 43, { pattern: "^[A-Za-z0-9_-]+$" }), code: string(true, 1, 4096), codeVerifier: string(true, 43, 128, { pattern: "^[A-Za-z0-9._~-]+$" }) }), executionLane: "apple-api-exchange-cognito-challenge-session", responseKind: "json" },
  { id: "session.refresh", method: "POST", pathTemplate: "/auth/session/refresh", authorization: { kind: "public" }, request: json({ refreshToken: string(true, 32, 512) }), executionLane: "session-refresh-hash-rotation", responseKind: "json" },
  { id: "stripe.webhook", method: "POST", pathTemplate: "/billing/stripe/webhook", authorization: { kind: "public" }, request: raw, responseKind: "json" },
  { id: "session.logout", method: "POST", pathTemplate: "/auth/session/logout", authorization: { kind: "session", requiresRecentAuthentication: false }, request: none, responseKind: "json" },
  { id: "workspace.bootstrap", method: "POST", pathTemplate: "/workspace/bootstrap", authorization: { kind: "session", requiresRecentAuthentication: true }, request: json({ slug: string(true, 3, 63, { pattern: "^[a-z0-9][a-z0-9-]{2,62}$" }), displayName: string(true, 1, 160) }), responseKind: "json" },
  { id: "workspace.activate", method: "POST", pathTemplate: "/workspace/activate", authorization: { kind: "session", requiresRecentAuthentication: true }, request: json({ slug: string(true, 3, 63, { pattern: "^[a-z0-9][a-z0-9-]{2,62}$" }) }), responseKind: "json" },
  { id: "workspace.get", method: "GET", pathTemplate: "/workspace", authorization: { kind: "workspace", action: "workspace.read", resourceResolver: "none" }, request: none, responseKind: "json" },
  { id: "membership.get", method: "GET", pathTemplate: "/membership", authorization: { kind: "workspace", action: "member.read", resourceResolver: "current-membership" }, request: none, responseKind: "json" },
  { id: "subscription.get", method: "GET", pathTemplate: "/subscription", authorization: { kind: "workspace", action: "subscription.read", resourceResolver: "none" }, request: none, responseKind: "json" },
  { id: "quota.get", method: "GET", pathTemplate: "/quota", authorization: { kind: "workspace", action: "quota.warning.read", resourceResolver: "none" }, request: none, trustedInputs: { quotaMetrics: [...QUOTA_METRICS] }, responseKind: "json" },
  { id: "identity.mutate", method: "POST", pathTemplate: "/identity/mutate", authorization: { kind: "session", requiresRecentAuthentication: true }, request: json({ purpose: string(true, 1, 32, { enum: identityMutationPurpose }), candidateIssuer: string(true, 5, 5, { enum: ["apple", "email"] }), verifiedAuthenticationReceiptToken: string(true, 43, 43, { pattern: "^[A-Za-z0-9_-]+$" }), confirmed: literalBoolean(true, true) }), responseKind: "json" },
];

export const SLICE4_ROUTE_SET_VERSION = "roomscan-slice4-routes-v3" as const;
export const SLICE4_ROUTE_MANIFEST: readonly SealedRoute[] = deepFreeze(routes);
export function routeKey(route: Pick<SealedRoute, "method" | "pathTemplate">): string { return `${route.method} ${route.pathTemplate}`; }
export function assertSealedManifest(): void {
  const ids = new Set<string>(); const keys = new Set<string>();
  for (const route of SLICE4_ROUTE_MANIFEST) { if (ids.has(route.id) || keys.has(routeKey(route))) throw new Error("duplicate_route"); ids.add(route.id); keys.add(routeKey(route)); if (route.authorization.kind === "workspace" && route.authorization.action === "member.read" && route.authorization.resourceResolver === "none") throw new Error("unsealed_route"); if (route.id === "apple.finish" && route.executionLane !== "apple-api-exchange-cognito-challenge-session") throw new Error("unsealed_route"); if (route.id === "session.refresh" && route.executionLane !== "session-refresh-hash-rotation") throw new Error("unsealed_route"); }
  // Slice 4's public/protected boundary is intentionally finite. A later
  // slice must revise this explicit list rather than silently registering a
  // tenant-, identity-, or hosted-operation route through generic plumbing.
  if (SLICE4_ROUTE_MANIFEST.length !== 19) throw new Error("unsealed_route");
  const byId = new Map(SLICE4_ROUTE_MANIFEST.map((route) => [route.id, route]));
  const exact = (id: string): SealedRoute => { const route = byId.get(id); if (route === undefined) throw new Error("unsealed_route"); return route; };
  const magicRequest = exact("magic.request");
  const magicCandidate = exact("magic.candidate.request");
  const magicConsume = exact("magic.consume");
  const redemption = exact("magic.completion.redeem");
  const bootstrap = exact("workspace.bootstrap");
  const activate = exact("workspace.activate");
  const identity = exact("identity.mutate");
  if (magicRequest.authorization.kind !== "public" || magicRequest.trustedInputs?.sourceIp !== "api-gateway-v2" || !isExactS256(magicRequest.request.fields?.codeChallenge)
    || magicCandidate.authorization.kind !== "session" || magicCandidate.authorization.requiresRecentAuthentication !== true || magicCandidate.trustedInputs?.sourceIp !== "api-gateway-v2" || !isExactS256(magicCandidate.request.fields?.codeChallenge)
    || magicConsume.authorization.kind !== "public" || magicConsume.request.fields?.purpose?.required !== true
    || redemption.authorization.kind !== "public" || redemption.trustedInputs?.sourceIp !== "api-gateway-v2" || !isExactS256(redemption.request.fields?.completionId) || !isExactS256(redemption.request.fields?.codeVerifier)
    || bootstrap.authorization.kind !== "session" || bootstrap.authorization.requiresRecentAuthentication !== true
    || activate.authorization.kind !== "session" || activate.authorization.requiresRecentAuthentication !== true
    || identity.authorization.kind !== "session" || identity.authorization.requiresRecentAuthentication !== true || identity.request.fields?.confirmed?.type !== "boolean" || identity.request.fields.confirmed.literal !== true) {
    throw new Error("unsealed_route");
  }
}
function isExactS256(rule: FieldRule | undefined): rule is StringFieldRule { return rule?.type === "string" && rule.required === true && rule.minLength === 43 && rule.maxLength === 43 && rule.pattern === "^[A-Za-z0-9_-]+$"; }
function deepFreeze<T>(value: T): T { if (typeof value === "object" && value !== null && !Object.isFrozen(value)) { for (const child of Object.values(value as Record<string, unknown>)) deepFreeze(child); Object.freeze(value); } return value; }
