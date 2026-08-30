import { TextDecoder } from "node:util";
import { isIP } from "node:net";
import { rawHttpApiV2Body, type HttpApiV2Envelope, type HttpApiV2Response } from "../http/http-api-v2.js";
import { assertSealedManifest, assertSealedSlice5Manifest, routeKey, SLICE4_ROUTE_MANIFEST, SLICE5_ROUTE_MANIFEST, type RouteAuthorization, type RouteExecutionLane, type SealedRoute } from "../contracts/route-manifest.js";
import type { QuotaMetric } from "../quota/quota-v2-service.js";
import type { TransactionBoundRepositoryBundle } from "../contracts/transaction-bound-repositories.js";

export interface ApiGatewayV2Request extends HttpApiV2Envelope { readonly version?: string; readonly rawPath?: string; readonly rawQueryString?: string; readonly queryStringParameters?: Readonly<Record<string, string>> | null; readonly cookies?: readonly string[]; readonly requestContext?: { readonly requestId?: string; readonly http?: { readonly method?: string; readonly sourceIp?: string } }; }
export interface ServerDerivedRouteInputs { readonly sourceIp?: string; readonly clickingDeviceId?: string; readonly quotaMetrics?: readonly QuotaMetric[]; }
export interface NormalizedRouteRequest { readonly routeId: string; readonly pathParameters: Readonly<Record<string, string>>; readonly body?: unknown; readonly serverDerived: ServerDerivedRouteInputs; readonly executionLane?: RouteExecutionLane; readonly rawEnvelope: ApiGatewayV2Request; }
export interface AuthorizedOperationContext { readonly principalPublicId: string; readonly transactionMarker: symbol; readonly repositories: TransactionBoundRepositoryBundle; }
export class OperationDeniedError extends Error { constructor() { super("operation_denied"); this.name = "OperationDeniedError"; } }
export interface SameTransactionOperationPort {
  /** Must resolve the opaque session, membership/resource/role/flag state and
   * execute `operation` inside the same persistence transaction. */
  run<T>(input: { readonly accessToken: string; readonly authorization: Exclude<RouteAuthorization, { readonly kind: "public" }> }, operation: (context: AuthorizedOperationContext) => Promise<T>): Promise<T>;
}
export type RouteHandler = (request: NormalizedRouteRequest, context?: AuthorizedOperationContext) => Promise<HttpApiV2Response>;
export interface Slice4HandlerDependencies { readonly handlers: Readonly<Record<string, RouteHandler>>; readonly operations: SameTransactionOperationPort; }
declare const slice5PostCommitBrand: unique symbol;
/** Only trusted composition creates this opaque result. The operation port
 * commits before it runs the effect and returns the public result to HTTP. */
export interface Slice5PostCommitResult<T> { readonly publicResult: () => T; readonly [slice5PostCommitBrand]: true; }
export type Slice5RouteHandler = (request: NormalizedRouteRequest, context?: AuthorizedOperationContext) => Promise<Slice5PostCommitResult<HttpApiV2Response>>;
export interface Slice5SameTransactionOperationPort {
  run<T>(input: { readonly accessToken: string; readonly authorization: Exclude<RouteAuthorization, { readonly kind: "public" }> }, operation: (context: AuthorizedOperationContext) => Promise<Slice5PostCommitResult<T>>): Promise<T>;
}
export interface Slice5HandlerDependencies {
  /** The frozen Slice 4 entrypoint remains the sole implementation of the
   * legacy 19 route semantics, including public auth and its same-UoW port. */
  readonly legacy: Slice4HandlerDependencies;
  /** Exactly the ten project-sync handlers, never a replacement map for the
   * inherited Slice 4 routes. */
  readonly handlers: Readonly<Record<string, Slice5RouteHandler>>;
  readonly operations: Slice5SameTransactionOperationPort;
}

const slice5Results = new WeakSet<object>();
const slice5Effects = new WeakMap<object, () => Promise<void>>();
/** Trusted composition can attach one provider effect. It is held outside the
 * returned object so a handler/client cannot enumerate or serialize it. */
export function createSlice5PostCommitResult<T>(publicResult: () => T, postCommitEffect: () => Promise<void> = async () => undefined): Slice5PostCommitResult<T> {
  if (typeof publicResult !== "function" || typeof postCommitEffect !== "function") throw new Error("invalid_post_commit_result");
  const result = Object.freeze({ publicResult }) as Slice5PostCommitResult<T>;
  slice5Results.add(result as object); slice5Effects.set(result as object, postCommitEffect);
  return result;
}
/** The capability port uses this after the transaction commits. It is not an
 * HTTP surface; lookalikes fail closed even if they reproduce the type shape. */
export function requireSlice5PostCommitEffect<T>(value: Slice5PostCommitResult<T>): () => Promise<void> {
  if (!slice5Results.has(value as object)) throw new Error("invalid_post_commit_result");
  const effect = slice5Effects.get(value as object); if (effect === undefined) throw new Error("invalid_post_commit_result");
  return effect;
}

const MAX_HEADER_COUNT = 32; const MAX_HEADER_BYTES = 16_384; const MAX_RESPONSE_BYTES = 1_048_576;
const JSON_HEADERS = Object.freeze({ "content-type": "application/json", "cache-control": "no-store" });

export function createSlice4HandlerEntrypoint(dependencies: Slice4HandlerDependencies): (request: ApiGatewayV2Request) => Promise<HttpApiV2Response> {
  assertSealedManifest(); assertExactHandlers(dependencies.handlers, SLICE4_ROUTE_MANIFEST);
  return createSlice4SealedEntrypoint(SLICE4_ROUTE_MANIFEST, dependencies.handlers, dependencies.operations);
}

/** Slice 5 is intentionally a separate entrypoint. Calling it cannot add a
 * route to the Slice 4 v3 matcher, and its post-commit operation port is the
 * only path for provider effects such as presigning or a generic queue wake. */
export function createSlice5HandlerEntrypoint(dependencies: Slice5HandlerDependencies): (request: ApiGatewayV2Request) => Promise<HttpApiV2Response> {
  assertSealedSlice5Manifest(); assertExactHandlers(dependencies.handlers, SLICE5_ROUTE_MANIFEST.slice(SLICE4_ROUTE_MANIFEST.length));
  const legacy = createSlice4HandlerEntrypoint(dependencies.legacy);
  const projectSync = createSlice5ProjectSyncEntrypoint(SLICE5_ROUTE_MANIFEST.slice(SLICE4_ROUTE_MANIFEST.length), dependencies.handlers, dependencies.operations);
  return async (request) => isSlice4RouteRequest(request) ? legacy(request) : projectSync(request);
}

function createSlice4SealedEntrypoint(
  manifest: readonly SealedRoute[],
  handlers: Readonly<Record<string, RouteHandler>>,
  operations: SameTransactionOperationPort,
): (request: ApiGatewayV2Request) => Promise<HttpApiV2Response> {
  return async (request) => {
    try {
      if (request.version !== "2.0" || request.cookies !== undefined || request.rawQueryString !== "" || (request.queryStringParameters !== undefined && request.queryStringParameters !== null) || !validHeaders(request.headers)) return error(400);
      const method = request.requestContext?.http?.method; const path = request.rawPath; if ((method !== "GET" && method !== "POST") || typeof path !== "string" || path.length > 512) return error(400);
      const match = matchRoute(manifest, method, path); if (match === undefined) return error(404);
      const normalized = normalizeRequest(request, match.route, match.pathParameters); if (normalized === undefined) return error(400);
      const handler = handlers[match.route.id]!;
      let response: HttpApiV2Response;
      if (match.route.authorization.kind === "public") response = await handler(normalized);
      else {
        const token = bearer(request.headers); if (token === undefined) return error(401);
        try { response = await operations.run({ accessToken: token, authorization: match.route.authorization }, (context) => handler(normalized, context)); } catch (caught) { return caught instanceof OperationDeniedError ? error(403) : error(500); }
      }
      return validateResponse(response, match.route, match.pathParameters.selector);
    } catch { return error(500); }
  };
}

function createSlice5ProjectSyncEntrypoint(
  manifest: readonly SealedRoute[],
  handlers: Readonly<Record<string, Slice5RouteHandler>>,
  operations: Slice5SameTransactionOperationPort,
): (request: ApiGatewayV2Request) => Promise<HttpApiV2Response> {
  return async (request) => {
    try {
      if (request.version !== "2.0" || request.cookies !== undefined || request.rawQueryString !== "" || (request.queryStringParameters !== undefined && request.queryStringParameters !== null) || !validHeaders(request.headers)) return error(400);
      const method = request.requestContext?.http?.method; const path = request.rawPath; if ((method !== "GET" && method !== "POST") || typeof path !== "string" || path.length > 512) return error(400);
      const match = matchRoute(manifest, method, path); if (match === undefined) return error(404);
      const normalized = normalizeRequest(request, match.route, match.pathParameters); if (normalized === undefined) return error(400);
      if (match.route.authorization.kind === "public") return error(500);
      const token = bearer(request.headers); if (token === undefined) return error(401);
      const handler = handlers[match.route.id]!;
      let response: HttpApiV2Response;
      try { response = await operations.run({ accessToken: token, authorization: match.route.authorization }, (context) => handler(normalized, context)); } catch (caught) { return caught instanceof OperationDeniedError ? error(403) : error(500); }
      return validateResponse(response, match.route, match.pathParameters.selector);
    } catch { return error(500); }
  };
}

function isSlice4RouteRequest(request: ApiGatewayV2Request): boolean {
  const method = request.requestContext?.http?.method; const path = request.rawPath;
  return (method === "GET" || method === "POST") && typeof path === "string" && matchRoute(SLICE4_ROUTE_MANIFEST, method, path) !== undefined;
}
function assertExactHandlers(handlers: Readonly<Record<string, unknown>>, manifest: readonly SealedRoute[]): void { const expected = new Set(manifest.map((route) => route.id)); const actual = Object.keys(handlers); if (actual.length !== expected.size || actual.some((id) => !expected.has(id))) throw new Error("handler_manifest_mismatch"); }
function matchRoute(manifest: readonly SealedRoute[], method: "GET" | "POST", path: string): { readonly route: SealedRoute; readonly pathParameters: Readonly<Record<string, string>> } | undefined {
  for (const route of manifest) { if (route.method !== method) continue; if (!route.pathTemplate.includes(":")) { if (route.pathTemplate === path) return { route, pathParameters: Object.freeze({}) }; continue; } const escaped = route.pathTemplate.split("/").map((part) => part === ":selector" ? "([A-Za-z0-9_-]{16,128})" : part.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("/"); const match = new RegExp(`^${escaped}$`, "u").exec(path); if (match?.[1] !== undefined) return { route, pathParameters: Object.freeze({ selector: match[1] }) }; } return undefined;
}
function normalizeRequest(envelope: ApiGatewayV2Request, route: SealedRoute, pathParameters: Readonly<Record<string, string>>): NormalizedRouteRequest | undefined {
  const serverDerived = deriveServerInputs(envelope, route); if (serverDerived === undefined) return undefined;
  const executionLane = route.executionLane === undefined ? {} : { executionLane: route.executionLane };
  const raw = rawHttpApiV2Body(envelope); if (route.request.body === "none") { if (raw !== undefined) return undefined; return Object.freeze({ routeId: route.id, pathParameters, serverDerived, ...executionLane, rawEnvelope: envelope }); }
  if (raw === undefined || raw.length === 0 || raw.length > route.request.maximumBytes) return undefined;
  if (route.request.body === "raw") { if (uniqueHeader(envelope.headers, "content-type") !== route.request.contentType) return undefined; return Object.freeze({ routeId: route.id, pathParameters, body: Uint8Array.from(raw), serverDerived, ...executionLane, rawEnvelope: envelope }); }
  if (uniqueHeader(envelope.headers, "content-type") !== "application/json") return undefined;
  let text: string; try { text = new TextDecoder("utf-8", { fatal: true }).decode(raw); } catch { return undefined; }
  if (hasDuplicateJsonObjectKeys(text)) return undefined; let parsed: unknown; try { parsed = JSON.parse(text); } catch { return undefined; }
  if (!validateJsonBody(parsed, route)) return undefined; return Object.freeze({ routeId: route.id, pathParameters, body: parsed, serverDerived, ...executionLane, rawEnvelope: envelope });
}
function deriveServerInputs(envelope: ApiGatewayV2Request, route: SealedRoute): ServerDerivedRouteInputs | undefined { const sourceIp = route.trustedInputs?.sourceIp === "api-gateway-v2" ? envelope.requestContext?.http?.sourceIp : undefined; if (route.trustedInputs?.sourceIp === "api-gateway-v2" && (typeof sourceIp !== "string" || sourceIp.length > 64 || isIP(sourceIp) === 0)) return undefined; const requestId = route.trustedInputs?.clickingDeviceId === "api-gateway-v2-request-id" ? envelope.requestContext?.requestId : undefined; if (route.trustedInputs?.clickingDeviceId === "api-gateway-v2-request-id" && (typeof requestId !== "string" || !/^[A-Za-z0-9._~=-]{1,128}$/u.test(requestId))) return undefined; const clickingDeviceId = requestId === undefined ? undefined : `apigw:${requestId}`; return Object.freeze({ ...(sourceIp === undefined ? {} : { sourceIp }), ...(clickingDeviceId === undefined ? {} : { clickingDeviceId }), ...(route.trustedInputs?.quotaMetrics === undefined ? {} : { quotaMetrics: route.trustedInputs.quotaMetrics }) }); }
function validateJsonBody(value: unknown, route: SealedRoute): boolean {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return false;
  const fields = route.request.fields ?? {};
  const record = value as Record<string, unknown>;
  if (Object.keys(record).some((key) => fields[key] === undefined)) return false;
  for (const [name, rule] of Object.entries(fields)) {
    const field = record[name];
    if (field === undefined) {
      if (rule.required) return false;
      continue;
    }
    if (rule.type === "string") {
      if (typeof field !== "string" || field.length < rule.minLength || field.length > rule.maxLength
        || (rule.enum !== undefined && !rule.enum.includes(field))
        || (rule.pattern !== undefined && !new RegExp(rule.pattern, "u").test(field))) return false;
      continue;
    }
    if (rule.type === "integer") {
      if (typeof field !== "number" || !Number.isSafeInteger(field) || field < rule.minimum || field > rule.maximum) return false;
      continue;
    }
    if (typeof field !== "boolean" || (rule.literal !== undefined && field !== rule.literal)) return false;
  }
  return true;
}
function validHeaders(headers: ApiGatewayV2Request["headers"]): boolean { if (headers === undefined) return true; const entries = Object.entries(headers); if (entries.length > MAX_HEADER_COUNT) return false; const names = new Set<string>(); let bytes = 0; for (const [name, value] of entries) { if (!/^[!#$%&'*+.^_`|~0-9A-Za-z-]{1,128}$/.test(name) || typeof value !== "string" || value.length > 8_192) return false; const lower = name.toLowerCase(); if (names.has(lower)) return false; names.add(lower); bytes += name.length + value.length; } return bytes <= MAX_HEADER_BYTES; }
function uniqueHeader(headers: ApiGatewayV2Request["headers"], name: string): string | undefined { if (headers === undefined) return undefined; const entry = Object.entries(headers).find(([candidate]) => candidate.toLowerCase() === name); return entry?.[1]; }
function bearer(headers: ApiGatewayV2Request["headers"]): string | undefined { const match = /^Bearer ([A-Za-z0-9._~-]{32,4096})$/.exec(uniqueHeader(headers, "authorization") ?? ""); return match?.[1]; }
function validateResponse(response: HttpApiV2Response, route: SealedRoute, selector?: string): HttpApiV2Response { if (!Number.isInteger(response.statusCode) || response.statusCode < 100 || response.statusCode > 599 || Buffer.byteLength(response.body) > MAX_RESPONSE_BYTES || !validHeaders(response.headers)) return error(500); if (route.responseKind === "scanner-html") { if (response.statusCode !== 200 || response.headers["cache-control"] !== "no-store" || response.headers["referrer-policy"] !== "no-referrer" || response.headers["content-security-policy"] === undefined || !response.headers["content-type"]?.startsWith("text/html") || (selector !== undefined && response.body.includes(selector))) return error(500); return response; } if (response.headers["cache-control"] !== "no-store" || response.headers["content-type"] !== "application/json") return error(500); return response; }
function error(statusCode: number): HttpApiV2Response { const code = statusCode === 401 ? "unauthenticated" : statusCode === 403 ? "forbidden" : statusCode === 404 ? "not_found" : statusCode === 500 ? "unavailable" : "invalid_request"; return { statusCode, headers: JSON_HEADERS, body: JSON.stringify({ error: { code } }) }; }

/** Lexical JSON walk with decoded member-name comparison. This catches both
 * literal duplicates and escaped aliases such as `"email"`/`"e\u006dail"`. */
export function hasDuplicateJsonObjectKeys(source: string): boolean {
  let index = 0; const whitespace = () => { while (/\s/u.test(source[index] ?? "")) index++; };
  const stringToken = (): string | undefined => { if (source[index] !== '"') return undefined; const start = index++; while (index < source.length) { const char = source[index++]; if (char === '"') { try { return JSON.parse(source.slice(start, index)) as string; } catch { return undefined; } } if (char === "\\") index++; } return undefined; };
  const value = (): boolean => { whitespace(); if (source[index] === "{") return object(); if (source[index] === "[") { index++; whitespace(); if (source[index] === "]") { index++; return true; } while (value()) { whitespace(); if (source[index] === "]") { index++; return true; } if (source[index++] !== ",") return false; } return false; } if (source[index] === '"') return stringToken() !== undefined; const match = /^(?:true|false|null|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?)/u.exec(source.slice(index)); if (match === null) return false; index += match[0].length; return true; };
  let duplicate = false; const object = (): boolean => { if (source[index++] !== "{") return false; const keys = new Set<string>(); whitespace(); if (source[index] === "}") { index++; return true; } while (true) { whitespace(); const key = stringToken(); if (key === undefined) return false; if (keys.has(key)) duplicate = true; keys.add(key); whitespace(); if (source[index++] !== ":" || !value()) return false; whitespace(); if (source[index] === "}") { index++; return true; } if (source[index++] !== ",") return false; } };
  const valid = value(); whitespace(); return !valid || index !== source.length || duplicate;
}
export { routeKey };
