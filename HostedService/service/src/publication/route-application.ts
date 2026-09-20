import {
  SLICE5_ROUTE_MANIFEST,
  SLICE6_ROUTE_MANIFEST,
  assertSealedSlice6Manifest,
  type Slice6Route,
} from "../contracts/route-manifest.js";
import type { ApiGatewayV2Request } from "../handlers/factory.js";
import type { HttpApiV2Response } from "../http/http-api-v2.js";
import { rawHttpApiV2Body } from "../http/http-api-v2.js";
import {
  PublicationContractError,
  parseSlice6CredentialEnvelope,
  parseSlice6FeedbackEnvelope,
  parseSlice6RoutePayload,
  type Slice6LinkCreateRequest,
  type Slice6LinkUpdateRequest,
  type Slice6PageRequest,
  type Slice6PortalAssetRequest,
  type Slice6PropertyUpsertRequest,
  type Slice6SnapshotCompletionRequest,
  type PublicationAllocationRequest,
} from "./contracts.js";
import {
  PublicationCapabilityError,
  PublicationSecretHasher,
  credentialForPublication,
  portalLinkHash,
  portalSessionForPublication,
  type PublicationCapabilityService,
} from "./capabilities.js";
import { createSlice6PortalDocument, type Slice6PortalDocument, type Slice6PortalDocumentAssets } from "./portal-document.js";

const JSON_HEADERS = Object.freeze({ "cache-control": "no-store", "content-type": "application/json" });
const MAX_RESPONSE_BYTES = 1_048_576;
const PORTAL_ORIGIN = "https://portal.roomscanstudio.invalid";

interface Slice6PublicationRouteBaseDependencies {
  readonly publication: PublicationCapabilityService;
  readonly secretHasher: PublicationSecretHasher;
  /** A future deployed platform origin is injected by composition. The local
   * synthetic default deliberately cannot be mistaken for a custom domain. */
  readonly portalOrigin?: string;
}

export interface Slice6PublicationRouteDependencies extends Slice6PublicationRouteBaseDependencies {
  /** The exact frozen Slice 5 implementation. Slice 6 never re-normalizes,
   * reparses, or authorizes one of its inherited 29 routes. */
  readonly legacy: (request: ApiGatewayV2Request) => Promise<HttpApiV2Response>;
  /** Immutable built CSS/JS bytes supplied by trusted composition only. */
  readonly portalDocument: Slice6PortalDocumentAssets;
}
export interface Slice6PrivateApiPublicationRouteDependencies extends Slice6PublicationRouteBaseDependencies {
  readonly legacy: (request: ApiGatewayV2Request) => Promise<HttpApiV2Response>;
}
export interface Slice6PortalDeliveryRouteDependencies extends Slice6PublicationRouteBaseDependencies {
  readonly portalDocument: Slice6PortalDocumentAssets;
}

export type Slice6PublicationRouteRoot = "all" | "private-api" | "portal-delivery";

/** Shared route implementation retained for focused service tests. Production
 * composition must select one of the two bounded roots below. */
export function createSlice6PublicationHandler(input: Slice6PublicationRouteDependencies): (request: ApiGatewayV2Request) => Promise<HttpApiV2Response> {
  return createSlice6PublicationScopedHandler(input, "all");
}

/** PrivateApi owns inherited Slice 4/5 and professional metadata/mutation
 * routes. It cannot reach the public portal or either byte-delivery path. */
export function createSlice6PrivateApiPublicationHandler(input: Slice6PrivateApiPublicationRouteDependencies): (request: ApiGatewayV2Request) => Promise<HttpApiV2Response> {
  return createSlice6PublicationScopedHandler(input, "private-api");
}

/** PortalDelivery owns only the inert shell, portal capability routes, and the
 * professional-cookie byte stream. It never delegates an inherited route. */
export function createSlice6PortalDeliveryPublicationHandler(input: Slice6PortalDeliveryRouteDependencies): (request: ApiGatewayV2Request) => Promise<HttpApiV2Response> {
  return createSlice6PublicationScopedHandler({
    ...input,
    legacy: async () => error(404),
  }, "portal-delivery");
}

function createSlice6PublicationScopedHandler(input: Slice6PrivateApiPublicationRouteDependencies & Readonly<{ readonly portalDocument?: Slice6PortalDocumentAssets }>, root: Slice6PublicationRouteRoot): (request: ApiGatewayV2Request) => Promise<HttpApiV2Response> {
  if (input === null || typeof input !== "object" || typeof input.legacy !== "function" || input.publication === null || typeof input.publication !== "object" || !(input.secretHasher instanceof PublicationSecretHasher) || (input.portalOrigin !== undefined && !validOrigin(input.portalOrigin))) throw new Error("invalid_slice6_publication_composition");
  let portalDocument: Slice6PortalDocument | undefined;
  if (root !== "private-api") {
    try { portalDocument = createSlice6PortalDocument(input.portalDocument!); } catch { throw new Error("invalid_slice6_publication_composition"); }
  }
  assertSealedSlice6Manifest(); assertSlice6RouteRootClosure(); const publication = input.publication; const hasher = input.secretHasher; const origin = input.portalOrigin ?? PORTAL_ORIGIN;
  const slice6Routes = SLICE6_ROUTE_MANIFEST.slice(SLICE5_ROUTE_MANIFEST.length) as readonly Slice6Route[];
  const routes = new Map<string, Slice6Route>(slice6Routes.map((route) => [`${route.method} ${route.pathTemplate}`, route] as const));
  return async (request) => {
    const method = request.requestContext?.http?.method; const path = request.rawPath;
    const legacyRoute = (method === "GET" || method === "POST") && typeof path === "string" ? legacyRouteFor(method, path) : undefined;
    if (legacyRoute !== undefined) {
      if (!routeAllowedAtRoot(root, legacyRoute.id)) return error(404);
      // The frozen entrypoints reject every cookie. Enforcing that before the
      // delegate also prevents a test double or future legacy wrapper from
      // accidentally receiving portal/professional capability material.
      if (request.cookies !== undefined || /^RoomScan-Link\s/u.test(uniqueHeader(request.headers, "authorization") ?? "")) return error(400);
      return input.legacy(request);
    }
    try {
      if (request.version !== "2.0" || request.rawQueryString !== "" || (request.queryStringParameters !== undefined && request.queryStringParameters !== null) || !validHeaders(request.headers)) return error(400);
      if ((method !== "GET" && method !== "POST") || typeof path !== "string" || path.length > 512) return error(400);
      const route = routes.get(`${method} ${path}`); if (route === undefined) return error(404);
      if (!routeAllowedAtRoot(root, route.id)) return error(404);
      if (route.id === "portal.shell.get") {
        if (portalDocument === undefined) return error(404);
        return portalShell(request, portalDocument);
      }
      const payload = requestPayload(request, route);
      return await dispatch(route, request, payload, publication, hasher, origin);
    } catch (caught) {
      if (caught instanceof PublicationContractError) return caught.code === "credential_confusion" ? errorResponse(401) : error(400);
      if (caught instanceof PublicationCapabilityError) return caught.code === "forbidden" ? error(403) : error(503);
      return error(503);
    }
  };
}

async function dispatch(route: Slice6Route, request: ApiGatewayV2Request, payload: unknown, service: PublicationCapabilityService, hasher: PublicationSecretHasher, portalOrigin: string): Promise<HttpApiV2Response> {
  const headers = request.headers;
  const envelope = (required: Parameters<typeof parseSlice6CredentialEnvelope>[0]["required"]) => parseSlice6CredentialEnvelope({ required, ...(headers === undefined ? {} : { headers }), ...(request.cookies === undefined ? {} : { cookies: request.cookies }) });
  const professional = (): ReturnType<typeof credentialForPublication> => credentialForPublication(envelope("professional"), hasher);
  const browserCSRF = (credential: ReturnType<typeof credentialForPublication>): void => {
    if (!credential.browser) return;
    const raw = envelope("professional").secret;
    const supplied = uniqueHeader(headers, "x-roomscan-csrf"); const expected = Buffer.from(hasher.hash("professional-csrf", raw)).toString("base64url");
    if (supplied === undefined || supplied !== expected) throw new PublicationContractError("credential_confusion");
  };
  switch (route.id) {
  case "professional.session.exchange": {
    const appEnvelope = envelope("professional_exchange"); if (appEnvelope.kind !== "app_bearer") throw new PublicationContractError("credential_confusion");
    const credential = credentialForPublication(appEnvelope, hasher); const issued = await service.issueProfessionalSession(credential.hash); const csrfToken = Buffer.from(hasher.hash("professional-csrf", issued.cookieSecret)).toString("base64url");
    return json(200, { expiresAt: issued.expiresAt, csrfToken, ...issued.bootstrap }, professionalCookies(issued.cookieSecret));
  }
  case "professional.session.logout": { const credential = professional(); browserCSRF(credential); await service.revokeProfessionalSession(credential); return json(200, { revoked: true }, expiredProfessionalCookies()); }
  case "professional.properties.list": {
    const credential = professional();
    const items = await service.listProperties(credential, payload as Slice6PageRequest);
    const roomCandidates = await service.listRoomCandidates(credential);
    return json(200, { items, roomCandidates });
  }
  case "professional.properties.upsert": { const credential = professional(); browserCSRF(credential); return json(200, await service.upsertProperty(credential, payload as Slice6PropertyUpsertRequest)); }
  case "professional.concepts.list": return json(200, { items: await service.listConcepts(professional(), payload as Readonly<{ readonly projectID: string } & Slice6PageRequest>) });
  case "professional.members.list": return json(200, { items: await service.listMembers(professional(), payload as Slice6PageRequest) });
  case "publication.snapshot.allocate": { const credential = professional(); browserCSRF(credential); return json(202, await service.allocateSnapshot(credential, payload as PublicationAllocationRequest)); }
  case "publication.snapshot.complete": { const credential = professional(); browserCSRF(credential); return json(202, await service.completeSnapshot(credential, payload as Slice6SnapshotCompletionRequest)); }
  case "publication.snapshot.status": { const item = await service.snapshotStatus(professional(), (payload as { readonly allocationID: string }).allocationID); return item === undefined ? error(404) : json(200, item); }
  case "publication.snapshot.list": return json(200, { items: await service.listSnapshots(professional(), payload as Slice6PageRequest) });
  case "publication.link.create": { const credential = professional(); browserCSRF(credential); return json(200, await service.createLink(credential, payload as Slice6LinkCreateRequest)); }
  case "publication.link.update": { const credential = professional(); browserCSRF(credential); return json(200, await service.updateLink(credential, payload as Slice6LinkUpdateRequest)); }
  case "publication.link.revoke": { const credential = professional(); browserCSRF(credential); return json(200, await service.revokeLink(credential, payload as Readonly<{ readonly linkID: string; readonly expectedGeneration: number }>)); }
  case "publication.link.list": return json(200, { items: await service.listLinks(professional(), payload as Readonly<{ readonly snapshotID?: string } & Slice6PageRequest>) });
  case "publication.feedback.list": return json(200, { items: await service.listFeedback(professional(), payload as Readonly<{ readonly linkID?: string; readonly snapshotID?: string } & Slice6PageRequest>) });
  case "publication.access-history.list": return json(200, { items: await service.listAccessHistory(professional(), payload as Readonly<{ readonly linkID?: string } & Slice6PageRequest>) });
  case "publication.downloads.list": return json(200, { items: await service.listDownloads(professional(), (payload as { readonly snapshotID: string }).snapshotID) });
  case "publication.asset.read": {
    const professionalEnvelope = envelope("professional");
    if (professionalEnvelope.kind !== "professional_cookie") throw new PublicationContractError("credential_confusion");
    const delivery = await service.deliverProfessionalAsset(credentialForPublication(professionalEnvelope, hasher), payload as Readonly<{ readonly assetID: string; readonly offset: number; readonly byteCount: number; readonly requestID: string }>);
    return binaryDelivery(delivery);
  }
  case "portal.link.exchange": {
    const portalEnvelope = envelope("portal_link"); const result = await service.exchangePortalLink(portalLinkHash(portalEnvelope.secret, hasher), clientFamily(request), hasher.hash("network-risk", sourceRisk(request)));
    // Same public shape prevents existence/expiry/PIN state from becoming a
    // link oracle. A cookie is issued only for the already-authorized state.
    return json(200, { status: result.status === "active" ? "active" : result.status === "pin_required" ? "pin_required" : "unavailable" }, portalExchangeCookies(result, portalEnvelope.stalePortalCookieNames ?? []));
  }
  case "portal.pin.verify": {
    requireSameOrigin(request, portalOrigin); const pendingEnvelope = envelope("portal_pending_pin"); const result = await service.verifyPortalPIN(portalSessionForPublication(pendingEnvelope.secret, hasher), (payload as { readonly pin: string }).pin);
    return json(200, { status: result.status === "verified" ? "active" : "unavailable" }, result.status === "verified" ? [portalCookie(pendingEnvelope.secret), expiredCookie("roomscan_portal_pending", "/portal")] : []);
  }
  case "portal.snapshot.get": return json(200, await service.portalSnapshot(portalSessionForPublication(envelope("portal_session").secret, hasher)));
  case "portal.asset.read": {
    const session = portalSessionForPublication(envelope("portal_session").secret, hasher); const delivery = await service.deliverPortalAsset(session, payload as Slice6PortalAssetRequest);
    return binaryDelivery(delivery);
  }
  case "portal.feedback.verification.request": { const session = portalSessionForPublication(envelope("portal_session").secret, hasher); await service.requestFeedbackVerification(session, payload as import("./contracts.js").Slice6FeedbackVerificationRequest); return json(200, { status: "accepted" }); }
  case "portal.feedback.verification.consume": { const session = portalSessionForPublication(envelope("portal_session").secret, hasher); const result = await service.consumeFeedbackVerification(session, (payload as { readonly verificationCode: string }).verificationCode); return json(200, { status: result.feedbackCookieSecret === undefined ? "unavailable" : "verified" }, result.feedbackCookieSecret === undefined ? [] : [feedbackCookie(result.feedbackCookieSecret)]); }
  case "portal.feedback.create": { const feedback = parseSlice6FeedbackEnvelope({ ...(headers === undefined ? {} : { headers }), ...(request.cookies === undefined ? {} : { cookies: request.cookies }) }); const result = await service.createFeedback({ portalSessionHash: portalSessionForPublication(feedback.portalSessionSecret, hasher).hash, feedbackTokenHash: hasher.hash("feedback-token", feedback.feedbackCapabilitySecret) }, payload as Readonly<{ readonly action: "comment" | "approve" | "request_changes"; readonly comment?: string; readonly requestID: string }>); return json(200, result, [expiredCookie("roomscan_feedback", "/portal")]); }
  default: return error(404);
  }
}

function requestPayload(request: ApiGatewayV2Request, route: Slice6Route): unknown {
  const raw = rawHttpApiV2Body(request);
  // `rawHttpApiV2Body` uses `undefined` for both an absent body and an
  // invalid base64 envelope. Slice 6's no-body routes must distinguish those
  // cases, otherwise malformed bytes could bypass the closed-body contract.
  if (route.request.body === "none") { if (raw !== undefined || malformedEncodedBody(request, raw)) throw new PublicationContractError("invalid_request"); return undefined; }
  if (raw === undefined || raw.byteLength < 2 || raw.byteLength > route.request.maximumBytes || uniqueHeader(request.headers, "content-type") !== "application/json") throw new PublicationContractError("invalid_request");
  return parseSlice6RoutePayload(route.id, raw);
}
function legacyRouteFor(method: "GET" | "POST", path: string): (typeof SLICE5_ROUTE_MANIFEST)[number] | undefined {
  return SLICE5_ROUTE_MANIFEST.find((route) => {
    if (route.method !== method) return false;
    if (!route.pathTemplate.includes(":")) return route.pathTemplate === path;
    const expression = route.pathTemplate.split("/").map((part) => part === ":selector" ? "[A-Za-z0-9_-]{16,128}" : part.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&")).join("/");
    return new RegExp(`^${expression}$`, "u").test(path);
  });
}
const PRIVATE_API_ROUTE_IDS = new Set<string>([
  "health.get", "magic.request", "magic.candidate.request", "magic.confirm",
  "magic.consume", "magic.completion.redeem", "apple.begin", "apple.candidate.begin",
  "apple.finish", "session.refresh", "session.logout", "workspace.bootstrap",
  "workspace.activate", "workspace.get", "membership.get", "subscription.get",
  "quota.get", "identity.mutate", "project.migration.allocate",
  "project.revision.allocate", "project.upload.complete", "project.upload.status",
  "project.recovery.allocate", "project.edit-lease.acquire", "project.edit-lease.renew",
  "project.edit-lease.release", "project.raw-archive.configure", "project.raw-archive.allocate",
  "professional.session.exchange", "professional.session.logout", "professional.properties.list",
  "professional.properties.upsert", "professional.concepts.list", "professional.members.list",
  "publication.snapshot.allocate", "publication.snapshot.complete", "publication.snapshot.status",
  "publication.snapshot.list", "publication.link.create", "publication.link.update",
  "publication.link.revoke", "publication.link.list", "publication.feedback.list",
  "publication.access-history.list", "publication.downloads.list",
]);
const PORTAL_DELIVERY_ROUTE_IDS = new Set<string>([
  "portal.shell.get",
  "publication.asset.read",
  "portal.link.exchange",
  "portal.pin.verify",
  "portal.snapshot.get",
  "portal.asset.read",
  "portal.feedback.verification.request",
  "portal.feedback.verification.consume",
  "portal.feedback.create",
]);
const STRIPE_ROUTE_IDS = new Set<string>(["stripe.webhook"]);
export const SLICE6_ROUTE_ROOT_COUNTS = Object.freeze({ privateApi: 45, portalDelivery: 9, stripe: 1 });
export type Slice6InfrastructureRouteRoot = "private-api" | "portal-delivery" | "stripe";
/** Canonical infrastructure assignment. CDK consumes this closed mapping
 * instead of reconstructing the trust boundary from path prefixes. */
export function slice6RouteRootFor(routeID: string): Slice6InfrastructureRouteRoot {
  if (PRIVATE_API_ROUTE_IDS.has(routeID)) return "private-api";
  if (PORTAL_DELIVERY_ROUTE_IDS.has(routeID)) return "portal-delivery";
  if (STRIPE_ROUTE_IDS.has(routeID)) return "stripe";
  throw new Error("invalid_slice6_route_root_closure");
}
export function assertSlice6RouteRootClosure(): void {
  const roots = [PRIVATE_API_ROUTE_IDS, PORTAL_DELIVERY_ROUTE_IDS, STRIPE_ROUTE_IDS] as const;
  if (PRIVATE_API_ROUTE_IDS.size !== SLICE6_ROUTE_ROOT_COUNTS.privateApi
    || PORTAL_DELIVERY_ROUTE_IDS.size !== SLICE6_ROUTE_ROOT_COUNTS.portalDelivery
    || STRIPE_ROUTE_IDS.size !== SLICE6_ROUTE_ROOT_COUNTS.stripe) {
    throw new Error("invalid_slice6_route_root_closure");
  }
  const routeIDs = new Set(SLICE6_ROUTE_MANIFEST.map((route) => route.id));
  for (const routeID of routeIDs) {
    if (roots.filter((root) => root.has(routeID)).length !== 1) throw new Error("invalid_slice6_route_root_closure");
  }
  if (Array.from(roots).some((root) => Array.from(root).some((routeID) => !routeIDs.has(routeID)))) throw new Error("invalid_slice6_route_root_closure");
}
function routeAllowedAtRoot(root: Slice6PublicationRouteRoot, routeID: string): boolean {
  if (root === "all") return true;
  return slice6RouteRootFor(routeID) === root;
}
function portalShell(request: ApiGatewayV2Request, document: Slice6PortalDocument): HttpApiV2Response { const raw = rawHttpApiV2Body(request); if (raw !== undefined || malformedEncodedBody(request, raw)) return error(400); return Object.freeze({ statusCode: 200, headers: document.headers, body: document.html }); }
function binaryDelivery(delivery: Readonly<{ readonly bytes: Uint8Array; readonly contentType: string; readonly attachment: boolean; readonly range: Readonly<{ readonly offset: number; readonly byteCount: number; readonly totalBytes: number }> }>): HttpApiV2Response {
  const offset = delivery.range.offset;
  const end = offset + delivery.range.byteCount - 1;
  return Object.freeze({ statusCode: offset === 0 && delivery.range.byteCount === delivery.range.totalBytes ? 200 : 206, headers: Object.freeze({ "cache-control": "no-store", "content-type": delivery.contentType, "content-range": `bytes ${offset}-${end}/${delivery.range.totalBytes}`, "accept-ranges": "bytes", ...(delivery.attachment ? { "content-disposition": "attachment" } : {}) }), body: Buffer.from(delivery.bytes).toString("base64"), isBase64Encoded: true });
}
function malformedEncodedBody(request: ApiGatewayV2Request, decoded: Uint8Array | undefined): boolean { return request.isBase64Encoded === true && typeof request.body === "string" && decoded === undefined; }
function requireSameOrigin(request: ApiGatewayV2Request, origin: string): void { const requestOrigin = uniqueHeader(request.headers, "origin"); const fetchSite = uniqueHeader(request.headers, "sec-fetch-site"); if (requestOrigin !== origin || (fetchSite !== "same-origin" && fetchSite !== "same-site")) throw new PublicationContractError("credential_confusion"); }
function clientFamily(request: ApiGatewayV2Request): "desktop" | "mobile" | "tablet" | "unknown" { const mobile = uniqueHeader(request.headers, "sec-ch-ua-mobile"); const userAgent = uniqueHeader(request.headers, "user-agent") ?? ""; if (mobile === "?1") return /ipad|tablet/iu.test(userAgent) ? "tablet" : "mobile"; if (/ipad|tablet/iu.test(userAgent)) return "tablet"; if (userAgent.length === 0) return "unknown"; return "desktop"; }
function sourceRisk(request: ApiGatewayV2Request): string { const ip = request.requestContext?.http?.sourceIp; return typeof ip === "string" && ip.length <= 64 ? ip : "unknown"; }
function professionalCookies(value: string): readonly string[] { return Object.freeze([cookie("roomscan_professional", value, "/professional", 28_800), cookie("roomscan_professional", value, "/publications", 28_800)]); }
function expiredProfessionalCookies(): readonly string[] { return Object.freeze([expiredCookie("roomscan_professional", "/professional"), expiredCookie("roomscan_professional", "/publications")]); }
function portalCookie(value: string): string { return cookie("roomscan_portal", value, "/portal", 1_800); }
function pendingPortalCookie(value: string): string { return cookie("roomscan_portal_pending", value, "/portal", 1_800); }
function feedbackCookie(value: string): string { return cookie("roomscan_feedback", value, "/portal", 900); }
function portalExchangeCookies(result: Readonly<{ readonly status: "active" | "pin_required" | "unavailable" | "killed"; readonly cookieSecret?: string }>, staleNames: readonly ("roomscan_portal" | "roomscan_portal_pending" | "roomscan_feedback")[]): readonly string[] {
  const stale = new Set(staleNames);
  const expire = (name: "roomscan_portal" | "roomscan_portal_pending" | "roomscan_feedback") => expiredCookie(name, "/portal");
  if (result.status === "active" && result.cookieSecret !== undefined) {
    return Object.freeze([portalCookie(result.cookieSecret), ...(["roomscan_portal_pending", "roomscan_feedback"] as const).filter((name) => stale.has(name)).map(expire)]);
  }
  if (result.status === "pin_required" && result.cookieSecret !== undefined) {
    return Object.freeze([pendingPortalCookie(result.cookieSecret), ...(["roomscan_portal", "roomscan_feedback"] as const).filter((name) => stale.has(name)).map(expire)]);
  }
  return Object.freeze((["roomscan_portal", "roomscan_portal_pending", "roomscan_feedback"] as const).filter((name) => stale.has(name)).map(expire));
}
function expiredCookie(name: string, path: string): string { return `${name}=; Path=${path}; Max-Age=0; HttpOnly; Secure; SameSite=Strict`; }
function cookie(name: string, value: string, path: string, maxAge: number): string { if (!/^[A-Za-z0-9_-]{43}$/u.test(value)) throw new PublicationContractError("credential_confusion"); return `${name}=${value}; Path=${path}; Max-Age=${maxAge}; HttpOnly; Secure; SameSite=Strict`; }
function json(statusCode: number, value: unknown, cookies: readonly string[] = []): HttpApiV2Response { const body = JSON.stringify(value); if (Buffer.byteLength(body, "utf8") > MAX_RESPONSE_BYTES) return error(503); if (!Array.isArray(cookies) || cookies.length > 3) return error(503); return Object.freeze({ statusCode, headers: JSON_HEADERS, body, ...(cookies.length === 0 ? {} : { cookies: Object.freeze([...cookies]) }) }); }
function error(statusCode: 400 | 401 | 403 | 404 | 503): HttpApiV2Response { return errorResponse(statusCode); }
function errorResponse(statusCode: 400 | 401 | 403 | 404 | 503): HttpApiV2Response { const code = statusCode === 401 ? "unauthenticated" : statusCode === 403 ? "forbidden" : statusCode === 404 ? "not_found" : statusCode === 503 ? "unavailable" : "invalid_request"; return Object.freeze({ statusCode, headers: JSON_HEADERS, body: JSON.stringify({ error: { code } }) }); }
function validHeaders(headers: ApiGatewayV2Request["headers"]): boolean { if (headers === undefined) return true; const entries = Object.entries(headers); if (entries.length > 32) return false; let bytes = 0; const names = new Set<string>(); for (const [name, value] of entries) { if (!/^[!#$%&'*+.^_`|~0-9A-Za-z-]{1,128}$/u.test(name) || typeof value !== "string" || value.length > 8_192 || names.has(name.toLowerCase())) return false; names.add(name.toLowerCase()); bytes += Buffer.byteLength(name, "utf8") + Buffer.byteLength(value, "utf8"); } return bytes <= 16_384; }
function uniqueHeader(headers: ApiGatewayV2Request["headers"], name: string): string | undefined { if (headers === undefined) return undefined; const matches = Object.entries(headers).filter(([key]) => key.toLowerCase() === name); if (matches.length !== 1) return undefined; const value = matches[0]?.[1]; return typeof value === "string" && value.length > 0 ? value : undefined; }
function validOrigin(value: string): boolean { try { const parsed = new URL(value); return parsed.protocol === "https:" && parsed.pathname === "/" && !parsed.username && !parsed.password && parsed.search === "" && parsed.hash === ""; } catch { return false; } }
