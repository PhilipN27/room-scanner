import { SLICE4_ROUTE_MANIFEST, SLICE4_ROUTE_SET_VERSION, SLICE5_ROUTE_MANIFEST, SLICE5_ROUTE_SET_VERSION, SLICE6_ROUTE_MANIFEST, SLICE6_ROUTE_SET_VERSION, type FieldRule, type SealedRoute, type Slice6Route } from "./route-manifest.js";

function operation(route: SealedRoute): Readonly<Record<string, unknown>> {
  const body = route.request.body === "none" ? {} : {
    requestBody: {
      required: true,
      content: {
        "application/json": {
          schema: route.request.body === "json"
            ? objectSchema(route.request.fields ?? {})
            : { type: "string", maxLength: route.request.maximumBytes },
        },
      },
    },
  };
  const successContent = route.responseKind === "scanner-html" ? { "text/html": { schema: { type: "string" } } } : { "application/json": { schema: { $ref: "#/components/schemas/Success" } } };
  return { operationId: route.id.replaceAll(".", "_"), security: route.authorization.kind === "public" ? [] : [{ opaqueBearer: [] }], ...body, responses: { "200": { description: "Success", content: successContent }, "400": { $ref: "#/components/responses/InvalidRequest" }, "401": { $ref: "#/components/responses/Unauthenticated" }, "403": { $ref: "#/components/responses/Forbidden" }, "500": { $ref: "#/components/responses/Failure" } } };
}
function objectSchema(fields: Readonly<Record<string, FieldRule>>): Readonly<Record<string, unknown>> {
  return {
    type: "object",
    additionalProperties: false,
    required: Object.entries(fields).filter(([, rule]) => rule.required).map(([name]) => name),
    properties: Object.fromEntries(Object.entries(fields).map(([name, rule]) => [name,
      rule.type === "string"
        ? { type: "string", minLength: rule.minLength, maxLength: rule.maxLength, ...(rule.enum === undefined ? {} : { enum: rule.enum }), ...(rule.pattern === undefined ? {} : { pattern: rule.pattern }) }
        : rule.type === "integer"
          ? { type: "integer", minimum: rule.minimum, maximum: rule.maximum }
          : { type: "boolean", ...(rule.literal === undefined ? {} : { const: rule.literal }) },
    ])),
  };
}
const paths: Record<string, Record<string, unknown>> = {};
for (const route of SLICE4_ROUTE_MANIFEST) { const path = route.pathTemplate.replace(":selector", "{selector}"); const item = paths[path] ?? {}; item[route.method.toLowerCase()] = operation(route); if (route.pathTemplate.includes(":selector")) item.parameters = [{ name: "selector", in: "path", required: true, schema: { type: "string", minLength: 16, maxLength: 128, pattern: "^[A-Za-z0-9_-]+$" } }]; paths[path] = item; }
const errorSchema = { type: "object", additionalProperties: false, required: ["error"], properties: { error: { type: "object", additionalProperties: false, required: ["code"], properties: { code: { type: "string", enum: ["invalid_request", "unauthenticated", "forbidden", "not_found", "unavailable"] } } } } };
const errorResponse = (description: string) => ({ description, content: { "application/json": { schema: { $ref: "#/components/schemas/Error" } } } });
export const SLICE4_OPENAPI = deepFreeze({ openapi: "3.1.0", info: { title: "RoomScanStudio Professional Service", version: SLICE4_ROUTE_SET_VERSION }, paths, components: { securitySchemes: { opaqueBearer: { type: "http", scheme: "bearer", bearerFormat: "app-owned-opaque" } }, schemas: { Success: { type: "object", additionalProperties: true }, Error: errorSchema }, responses: { InvalidRequest: errorResponse("Invalid request"), Unauthenticated: errorResponse("Unauthenticated"), Forbidden: errorResponse("Forbidden"), Failure: errorResponse("Unavailable") } } });
const slice5Paths: Record<string, Record<string, unknown>> = {};
for (const route of SLICE5_ROUTE_MANIFEST) { const path = route.pathTemplate.replace(":selector", "{selector}"); const item = slice5Paths[path] ?? {}; item[route.method.toLowerCase()] = operation(route); if (route.pathTemplate.includes(":selector")) item.parameters = [{ name: "selector", in: "path", required: true, schema: { type: "string", minLength: 16, maxLength: 128, pattern: "^[A-Za-z0-9_-]+$" } }]; slice5Paths[path] = item; }
export const SLICE5_OPENAPI = deepFreeze({ openapi: "3.1.0", info: { title: "RoomScanStudio Professional Project Sync Service", version: SLICE5_ROUTE_SET_VERSION }, paths: slice5Paths, components: { securitySchemes: { opaqueBearer: { type: "http", scheme: "bearer", bearerFormat: "app-owned-opaque" } }, schemas: { Success: { type: "object", additionalProperties: true }, Error: errorSchema }, responses: { InvalidRequest: errorResponse("Invalid request"), Unauthenticated: errorResponse("Unauthenticated"), Forbidden: errorResponse("Forbidden"), Failure: errorResponse("Unavailable") } } });

const SLICE6_ROUTE_IDS = new Set(SLICE6_ROUTE_MANIFEST.slice(SLICE5_ROUTE_MANIFEST.length).map((route) => route.id));
function isSlice6Route(route: SealedRoute | Slice6Route): route is Slice6Route { return SLICE6_ROUTE_IDS.has(route.id); }
function slice6Operation(route: Slice6Route): Readonly<Record<string, unknown>> {
  const requestBody = route.request.body === "none" ? {} : { requestBody: { required: true, content: { "application/json": { schema: slice6RequestSchema(route.id) } } } };
  const responseContent = route.responseKind === "portal-html"
    ? { "text/html": { schema: { type: "string", maxLength: 1_048_576 } } }
    : route.responseKind === "binary"
      ? Object.fromEntries(["application/json", "image/png", "image/jpeg", "application/pdf", "application/zip"].map((contentType) => [contentType, { schema: { $ref: "#/components/schemas/BinaryChunk" } }]))
      : { "application/json": { schema: slice6ResponseSchema(route.id) } };
  const successStatus = route.id === "publication.snapshot.allocate" || route.id === "publication.snapshot.complete" ? "202" : "200";
  const parameters = slice6Parameters(route);
  return {
    operationId: route.id.replaceAll(".", "_"),
    security: slice6Security(route),
    ...requestBody,
    ...(parameters.length === 0 ? {} : { parameters }),
    responses: {
      [successStatus]: { description: "Success", content: responseContent },
      ...(route.responseKind === "binary" ? { "206": { description: "Partial content", content: responseContent } } : {}),
      "400": { $ref: "#/components/responses/InvalidRequest" },
      "401": { $ref: "#/components/responses/Unauthenticated" },
      "403": { $ref: "#/components/responses/Forbidden" },
      "404": { $ref: "#/components/responses/NotFound" },
      "503": { $ref: "#/components/responses/Failure" },
    },
  };
}
function slice6Security(route: Slice6Route): readonly Readonly<Record<string, readonly never[]>>[] {
  const kind = route.authorization.kind;
  if (kind === "public") return [];
  if (kind === "app-bearer") return [{ opaqueBearer: [] }];
  if (kind === "professional") return route.authorization.csrf ? [{ opaqueBearer: [] }, { professionalCookie: [], csrfHeader: [] }] : [{ opaqueBearer: [] }, { professionalCookie: [] }];
  if (kind === "professional-cookie") return [{ professionalCookie: [] }];
  if (kind === "portal-link") return [{ portalLink: [] }];
  if (kind === "portal-pending-pin") return [{ portalPendingPIN: [] }];
  if (kind === "portal-session") return [{ portalSession: [] }];
  return [{ portalSession: [], feedbackCapability: [] }];
}
function slice6Parameters(route: Slice6Route): readonly Readonly<Record<string, unknown>>[] {
  if (route.id === "portal.pin.verify") return Object.freeze([
    Object.freeze({ name: "origin", in: "header", required: true, schema: { type: "string", format: "uri", pattern: "^https://" }, description: "Must exactly equal the deployment's first-party portal origin; requests are same-origin only." }),
    Object.freeze({ name: "sec-fetch-site", in: "header", required: true, schema: { type: "string", enum: ["same-origin", "same-site"] } }),
  ]);
  return Object.freeze([]);
}
function slice6RequestSchema(routeID: string): Readonly<Record<string, unknown>> {
  const schema = SLICE6_REQUEST_SCHEMAS[routeID];
  if (schema === undefined) throw new Error(`missing_slice6_openapi_schema:${routeID}`);
  return schema;
}
const id = (prefix: string) => ({ type: "string", minLength: 20, maxLength: 132, pattern: `^${prefix}[A-Za-z0-9_-]+$` });
const digest64 = { type: "string", minLength: 64, maxLength: 64, pattern: "^[a-f0-9]{64}$" };
const canonicalTime = { type: "string", format: "date-time", pattern: "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(?:\\.\\d{3})?Z$" };
const opaque = (minimum: number, maximum: number) => ({ type: "string", minLength: minimum, maxLength: maximum, pattern: "^[A-Za-z0-9_-]+$" });
const closed = (properties: Readonly<Record<string, unknown>>, required: readonly string[]) => ({ type: "object", additionalProperties: false, required, properties });
const pageProperties = { cursor: opaque(16, 512), limit: { type: "integer", minimum: 1, maximum: 100 } };
const policy = { type: "string", enum: ["enabled", "disabled"] };
const sourceBinding = closed({ publicRoomKey: { type: "string", minLength: 1, maxLength: 128, pattern: "^[A-Za-z0-9_.-]+$" }, projectPublicID: id("prj_"), revisionPublicID: id("rev_"), projectID: opaque(1, 128), revisionID: opaque(1, 128), coordinateSpaceEpochID: { type: "string", minLength: 1, maxLength: 128, pattern: "^[A-Za-z0-9_.-]+$" }, packageSchemaVersion: { type: "string", enum: ["room-scan-project-v1", "room-scan-project-v2"] }, semanticSHA256: digest64, revisionManifestSHA256: digest64 }, ["publicRoomKey", "projectPublicID", "revisionPublicID", "projectID", "revisionID", "coordinateSpaceEpochID", "packageSchemaVersion", "semanticSHA256", "revisionManifestSHA256"]);
const propertyRoom = closed({ roomKey: { type: "string", minLength: 1, maxLength: 128, pattern: "^[A-Za-z0-9_.-]+$" }, roomOrder: { type: "integer", minimum: 1, maximum: 64 }, projectID: id("prj_") }, ["roomKey", "roomOrder", "projectID"]);
const SLICE6_REQUEST_SCHEMAS: Readonly<Record<string, Readonly<Record<string, unknown>>>> = Object.freeze({
  "professional.properties.list": closed({ ...pageProperties, limit: { type: "integer", minimum: 1, maximum: 20 } }, []),
  "professional.properties.upsert": closed({ propertyID: id("prop_"), expectedVersion: { type: "integer", minimum: 1 }, createIdempotencyKey: opaque(16, 128), title: { type: "string", minLength: 1, maxLength: 180 }, rooms: { type: "array", maxItems: 64, items: propertyRoom } }, ["title", "rooms"]),
  "professional.concepts.list": closed({ projectID: id("prj_"), ...pageProperties }, ["projectID"]),
  "professional.members.list": closed(pageProperties, []),
  "publication.snapshot.allocate": closed({ publicationKind: { type: "string", enum: ["room", "property"] }, projectID: id("prj_"), sourceRevisionID: id("rev_"), sourceRevisionDigest: digest64, sourceManifestDigest: digest64, sourceBindings: { type: "array", minItems: 1, maxItems: 64, items: sourceBinding }, sourceBindingsSHA256: digest64, selectionManifestSHA256: digest64, approvalSHA256: digest64, disclosureStatus: { const: "approved" }, propertyID: id("prop_"), archiveManifestSHA256: digest64, archiveSHA256: digest64, archiveByteCount: { type: "integer", minimum: 1, maximum: 805_306_368 }, idempotencyKey: opaque(16, 128) }, ["publicationKind", "projectID", "sourceRevisionID", "sourceRevisionDigest", "sourceManifestDigest", "sourceBindings", "sourceBindingsSHA256", "selectionManifestSHA256", "approvalSHA256", "disclosureStatus", "archiveManifestSHA256", "archiveSHA256", "archiveByteCount", "idempotencyKey"]),
  "publication.snapshot.complete": closed({ allocationID: id("pua_"), archiveSHA256: digest64, archiveManifestSHA256: digest64, archiveByteCount: { type: "integer", minimum: 1, maximum: 805_306_368 } }, ["allocationID", "archiveSHA256", "archiveManifestSHA256", "archiveByteCount"]),
  "publication.snapshot.status": closed({ allocationID: id("pua_") }, ["allocationID"]),
  "publication.snapshot.list": closed(pageProperties, []),
  "publication.link.create": closed({ snapshotID: id("snp_"), expiresAt: canonicalTime, pin: { type: "string", minLength: 6, maxLength: 6, pattern: "^[0-9]{6}$" }, aiPolicy: policy, feedbackPolicy: policy, idempotencyKey: opaque(16, 128) }, ["snapshotID", "aiPolicy", "feedbackPolicy", "idempotencyKey"]),
  "publication.link.update": closed({ linkID: id("lnk_"), expectedGeneration: { type: "integer", minimum: 1 }, expiresAt: canonicalTime, pin: { type: "string", minLength: 6, maxLength: 6, pattern: "^[0-9]{6}$" }, aiPolicy: policy, feedbackPolicy: policy }, ["linkID", "expectedGeneration", "aiPolicy", "feedbackPolicy"]),
  "publication.link.revoke": closed({ linkID: id("lnk_"), expectedGeneration: { type: "integer", minimum: 1 } }, ["linkID", "expectedGeneration"]),
  "publication.link.list": closed({ snapshotID: id("snp_"), ...pageProperties }, []),
  "publication.feedback.list": closed({ linkID: id("lnk_"), snapshotID: id("snp_"), cursor: opaque(16, 512), limit: { type: "integer", minimum: 1, maximum: 20 } }, []),
  "publication.access-history.list": closed({ linkID: id("lnk_"), ...pageProperties }, []),
  "publication.downloads.list": closed({ snapshotID: id("snp_") }, ["snapshotID"]),
  "publication.asset.read": closed({ assetID: id("ast_"), offset: { type: "integer", minimum: 0, maximum: 805_306_368 }, byteCount: { type: "integer", minimum: 1, maximum: 4_194_304 }, requestID: opaque(16, 128) }, ["assetID", "offset", "byteCount", "requestID"]),
  "portal.pin.verify": closed({ pin: { type: "string", minLength: 6, maxLength: 6, pattern: "^[0-9]{6}$" } }, ["pin"]),
  "portal.asset.read": closed({ assetID: id("ast_"), downloadKind: { type: "string", enum: ["floor_plan_pdf", "gallery_zip", "ai_ready_package"] }, offset: { type: "integer", minimum: 0, maximum: 805_306_368 }, byteCount: { type: "integer", minimum: 1, maximum: 4_194_304 }, requestID: opaque(16, 128) }, ["offset", "byteCount", "requestID"]),
  "portal.feedback.verification.request": closed({ email: { type: "string", minLength: 3, maxLength: 320, format: "email" }, requestID: opaque(16, 128) }, ["email", "requestID"]),
  "portal.feedback.verification.consume": closed({ verificationCode: { type: "string", minLength: 87, maxLength: 87, pattern: "^[A-Za-z0-9_-]{43}\\.[A-Za-z0-9_-]{43}$" } }, ["verificationCode"]),
  "portal.feedback.create": closed({ action: { type: "string", enum: ["comment", "approve", "request_changes"] }, comment: { type: "string", minLength: 1, maxLength: 4_000 }, requestID: opaque(16, 128) }, ["action", "requestID"]),
});

// Slice 6 responses are separate from the frozen legacy `Success` catch-all.
// Every response below is portal/public-safe: no database UUID, token/hash,
// object key/version, raw package fact, email, IP, or free-form audit value is
// documented. The API emits the same closed shapes at its route boundary.
const publicContentType = { type: "string", enum: ["application/json", "image/png", "image/jpeg", "application/pdf", "application/zip"] };
const memberSummary = closed({ memberID: { type: "string", minLength: 4, maxLength: 80, pattern: "^mem_[0-9a-f]{64}$" }, displayName: { type: "string", minLength: 4, maxLength: 80 }, role: { type: "string", enum: ["owner", "admin", "editor", "viewer"] }, state: { type: "string", enum: ["active", "invited", "suspended"] }, current: { type: "boolean" } }, ["memberID", "displayName", "role", "state", "current"]);
const bootstrapMembership = closed({ memberID: { type: "string", minLength: 4, maxLength: 80, pattern: "^mem_[0-9a-f]{64}$" }, displayName: { type: "string", minLength: 4, maxLength: 80 }, role: { type: "string", enum: ["owner", "admin", "editor", "viewer"] }, state: { type: "string", enum: ["active", "invited", "suspended"] } }, ["memberID", "displayName", "role", "state"]);
const subscriptionSummary = closed({ plan: { type: "string", minLength: 1, maxLength: 80 }, status: { type: "string", minLength: 1, maxLength: 80 }, currentPeriodEnd: canonicalTime }, ["plan", "status"]);
const quotaSummary = closed({ policyVersion: { type: "integer", minimum: 1 }, portalPeriod: { type: "string", minLength: 1, maxLength: 128 }, used: { type: "integer", minimum: 0 }, reserved: { type: "integer", minimum: 0 }, limit: { type: "integer", minimum: 0 } }, ["policyVersion", "portalPeriod", "used", "reserved", "limit"]);
const propertyRoomSummary = closed({ roomKey: { type: "string", minLength: 1, maxLength: 128 }, roomOrder: { type: "integer", minimum: 1, maximum: 64 }, projectID: id("prj_") }, ["roomKey", "roomOrder", "projectID"]);
const propertySummary = closed({ propertyID: id("prop_"), title: { type: "string", minLength: 1, maxLength: 180 }, version: { type: "integer", minimum: 1 }, roomCount: { type: "integer", minimum: 0, maximum: 64 }, rooms: { type: "array", maxItems: 64, items: propertyRoomSummary } }, ["propertyID", "title", "version", "roomCount", "rooms"]);
const assetSummary = closed({ assetID: id("ast_"), contentType: publicContentType, byteCount: { type: "integer", minimum: 1, maximum: 536_870_912 } }, ["assetID", "contentType", "byteCount"]);
const allocationSummary = closed({ allocationID: id("pua_"), status: { type: "string", enum: ["allocated", "validation_pending", "validating", "published", "rejected"] }, kind: { type: "string", enum: ["room", "property"] }, projectID: id("prj_"), sourceRevisionID: id("rev_"), propertyID: id("prop_"), snapshotID: id("snp_"), rejectionCode: { type: "string", minLength: 1, maxLength: 64 }, createdAt: canonicalTime, updatedAt: canonicalTime, expiresAt: canonicalTime }, ["allocationID", "status", "kind", "projectID", "sourceRevisionID", "createdAt", "updatedAt", "expiresAt"]);
const linkSummary = closed({ linkID: id("lnk_"), snapshotID: id("snp_"), generation: { type: "integer", minimum: 1 }, state: { type: "string", enum: ["active", "revoked"] }, expiresAt: canonicalTime, pinRequired: { type: "boolean" }, aiEnabled: { type: "boolean" }, feedbackEnabled: { type: "boolean" }, feedbackCount: { type: "integer", minimum: 0, maximum: 10_000 }, feedbackCountCapped: { type: "boolean" }, latestFeedbackAction: { type: "string", enum: ["comment", "approve", "request_changes"] }, latestFeedbackAt: canonicalTime }, ["linkID", "snapshotID", "generation", "state", "expiresAt", "pinRequired", "aiEnabled", "feedbackEnabled", "feedbackCount", "feedbackCountCapped"]);
const feedbackSummary = closed({ feedbackID: { type: "string", minLength: 1, maxLength: 80 }, linkID: id("lnk_"), snapshotID: id("snp_"), action: { type: "string", enum: ["comment", "approve", "request_changes"] }, comment: { type: "string", minLength: 1, maxLength: 4_000 }, displayName: { type: "string", minLength: 1, maxLength: 120 }, occurredAt: canonicalTime }, ["feedbackID", "linkID", "snapshotID", "action", "displayName", "occurredAt"]);
const accessHistorySummary = closed({ eventID: { type: "string", minLength: 1, maxLength: 80 }, linkID: id("lnk_"), snapshotID: id("snp_"), action: { type: "string", minLength: 1, maxLength: 32 }, outcome: { type: "string", minLength: 1, maxLength: 32 }, occurredHour: canonicalTime, clientFamily: { type: "string", enum: ["desktop", "mobile", "tablet", "unknown"] } }, ["eventID", "linkID", "snapshotID", "action", "outcome", "occurredHour", "clientFamily"]);
const downloadSummary = closed({ snapshotID: id("snp_"), assetID: id("ast_"), kind: { type: "string", enum: ["floor_plan_pdf", "gallery_zip", "ai_ready_package"] }, contentType: publicContentType, byteCount: { type: "integer", minimum: 1, maximum: 536_870_912 } }, ["assetID", "byteCount", "contentType", "kind", "snapshotID"]);
const portalRoom = closed({ roomKey: { type: "string", minLength: 1, maxLength: 128 }, roomOrder: { type: "integer", minimum: 1, maximum: 64 } }, ["roomKey", "roomOrder"]);
const portalPresentation = closed({ assetID: id("ast_"), contentType: { type: "string", const: "application/json" }, byteCount: { type: "integer", minimum: 1, maximum: 8_388_608 } }, ["assetID", "contentType", "byteCount"]);
const uploadGrant = closed({ url: { type: "string", format: "uri", pattern: "^https://" }, headers: { type: "object", additionalProperties: { type: "string", maxLength: 8_192 } } }, ["url", "headers"]);

function slice6ResponseSchema(routeID: string): Readonly<Record<string, unknown>> {
  switch (routeID) {
  case "professional.session.exchange": return closed({ expiresAt: canonicalTime, csrfToken: opaque(43, 43), membership: bootstrapMembership, subscription: subscriptionSummary, quota: quotaSummary }, ["csrfToken", "expiresAt", "membership", "quota", "subscription"]);
  case "professional.session.logout": return closed({ revoked: { const: true } }, ["revoked"]);
  case "professional.properties.list": return closed({ items: { type: "array", maxItems: 20, items: propertySummary }, roomCandidates: { type: "array", maxItems: 100, items: closed({ projectID: id("prj_"), title: { type: "string", minLength: 1, maxLength: 180 } }, ["projectID", "title"]) } }, ["items", "roomCandidates"]);
  case "professional.properties.upsert": return closed({ status: { type: "string", enum: ["created", "updated", "existing"] }, propertyID: id("prop_"), version: { type: "integer", minimum: 1 }, roomCount: { type: "integer", minimum: 0, maximum: 64 } }, ["status", "propertyID", "version", "roomCount"]);
  case "professional.concepts.list": return closed({ items: { type: "array", maxItems: 20, items: closed({ snapshotID: id("snp_"), assetID: id("ast_"), contentType: publicContentType, byteCount: { type: "integer", minimum: 1, maximum: 32_000_000 }, publishedAt: canonicalTime }, ["snapshotID", "assetID", "contentType", "byteCount", "publishedAt"]) } }, ["items"]);
  case "professional.members.list": return closed({ items: { type: "array", maxItems: 100, items: memberSummary } }, ["items"]);
  case "publication.snapshot.allocate": return closed({ status: { type: "string", enum: ["allocated", "existing"] }, allocationID: id("pua_"), allocationExpiresAt: canonicalTime, upload: uploadGrant }, ["status", "allocationID", "allocationExpiresAt", "upload"]);
  case "publication.snapshot.complete": return closed({ status: { type: "string", enum: ["validation_pending", "existing"] }, allocationID: id("pua_") }, ["status", "allocationID"]);
  case "publication.snapshot.status": return allocationSummary;
  case "publication.snapshot.list": return closed({ items: { type: "array", maxItems: 100, items: allocationSummary } }, ["items"]);
  case "publication.link.create": return closed({ status: { type: "string", enum: ["created", "existing"] }, linkID: id("lnk_"), generation: { type: "integer", minimum: 1 }, expiresAt: canonicalTime, pinRequired: { type: "boolean" }, shareURL: { type: "string", format: "uri", pattern: "^https://[^#]+#[A-Za-z0-9_-]{43}$" } }, ["status", "linkID", "generation", "expiresAt", "pinRequired"]);
  case "publication.link.update": return closed({ status: { type: "string", const: "updated" }, linkID: id("lnk_"), generation: { type: "integer", minimum: 1 }, expiresAt: canonicalTime, shareURL: { type: "string", format: "uri", pattern: "^https://[^#]+#[A-Za-z0-9_-]{43}$" } }, ["status", "linkID", "generation", "expiresAt"]);
  case "publication.link.revoke": return closed({ status: { type: "string", enum: ["revoked", "already_revoked"] }, linkID: id("lnk_"), generation: { type: "integer", minimum: 1 } }, ["status", "linkID", "generation"]);
  case "publication.link.list": return closed({ items: { type: "array", maxItems: 100, items: linkSummary } }, ["items"]);
  case "publication.feedback.list": return closed({ items: { type: "array", maxItems: 20, items: feedbackSummary } }, ["items"]);
  case "publication.access-history.list": return closed({ items: { type: "array", maxItems: 100, items: accessHistorySummary } }, ["items"]);
  case "publication.downloads.list": return closed({ items: { type: "array", maxItems: 100, items: downloadSummary } }, ["items"]);
  case "publication.asset.read": throw new Error("binary publication asset response has no JSON schema");
  case "portal.link.exchange": return closed({ status: { type: "string", enum: ["active", "pin_required", "unavailable"] } }, ["status"]);
  case "portal.pin.verify": return closed({ status: { type: "string", enum: ["active", "unavailable"] } }, ["status"]);
  case "portal.snapshot.get": return closed({ snapshotID: id("snp_"), kind: { type: "string", enum: ["room", "property"] }, presentation: portalPresentation, rooms: { type: "array", minItems: 0, maxItems: 64, items: portalRoom }, feedbackEnabled: { type: "boolean" }, aiReadyPackageEnabled: { type: "boolean" } }, ["aiReadyPackageEnabled", "feedbackEnabled", "kind", "presentation", "rooms", "snapshotID"]);
  case "portal.feedback.verification.request": return closed({ status: { type: "string", const: "accepted" } }, ["status"]);
  case "portal.feedback.verification.consume": return closed({ status: { type: "string", enum: ["verified", "unavailable"] } }, ["status"]);
  case "portal.feedback.create": return closed({ status: { type: "string", const: "recorded" }, feedbackID: { type: "string", format: "uuid" }, displayName: { type: "string", minLength: 1, maxLength: 120 } }, ["status", "feedbackID", "displayName"]);
  default: throw new Error(`missing_slice6_openapi_response_schema:${routeID}`);
  }
}
/** Slice 6 is a wholly separate browser/portal vocabulary. Its closed schemas
 * intentionally do not reuse the old flat scalar normalizer, even though its
 * first 29 OpenAPI paths remain source-compatible with Slice 5. */
const slice6Paths: Record<string, Record<string, unknown>> = {};
for (const route of SLICE6_ROUTE_MANIFEST) {
  const path = route.pathTemplate.replace(":selector", "{selector}");
  const item = slice6Paths[path] ?? {};
  item[route.method.toLowerCase()] = isSlice6Route(route) ? slice6Operation(route) : operation(route);
  if (route.pathTemplate.includes(":selector")) item.parameters = [{ name: "selector", in: "path", required: true, schema: { type: "string", minLength: 16, maxLength: 128, pattern: "^[A-Za-z0-9_-]+$" } }];
  slice6Paths[path] = item;
}
export const SLICE6_OPENAPI = deepFreeze({
  openapi: "3.1.0",
  info: { title: "RoomScanStudio Published Presentation Service", version: SLICE6_ROUTE_SET_VERSION },
  paths: slice6Paths,
  components: {
    securitySchemes: {
      opaqueBearer: { type: "http", scheme: "bearer", bearerFormat: "app-owned-opaque" },
      professionalCookie: { type: "apiKey", in: "cookie", name: "roomscan_professional" },
      csrfHeader: { type: "apiKey", in: "header", name: "x-roomscan-csrf", description: "Required together with professionalCookie on browser mutation routes; native opaque bearer alternatives do not use it." },
      portalLink: { type: "apiKey", in: "header", name: "Authorization", description: "Exact credential syntax: RoomScan-Link <43-character base64url secret>." },
      portalPendingPIN: { type: "apiKey", in: "cookie", name: "roomscan_portal_pending" },
      portalSession: { type: "apiKey", in: "cookie", name: "roomscan_portal" },
      feedbackCapability: { type: "apiKey", in: "cookie", name: "roomscan_feedback" },
    },
    schemas: {
      BinaryChunk: { type: "string", format: "binary", maxLength: 4_194_304 },
      Error: errorSchema,
    },
    responses: { InvalidRequest: errorResponse("Invalid request"), Unauthenticated: errorResponse("Unauthenticated"), Forbidden: errorResponse("Forbidden"), Failure: errorResponse("Unavailable") },
  },
});
function deepFreeze<T>(value: T): T { if (typeof value === "object" && value !== null && !Object.isFrozen(value)) { for (const child of Object.values(value as Record<string, unknown>)) deepFreeze(child); Object.freeze(value); } return value; }
