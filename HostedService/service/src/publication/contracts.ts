import { createHash } from "node:crypto";

/** The public publication vocabulary is deliberately separate from the frozen
 * Slice 4/5 normalizer. Nothing here is accepted by a legacy route. */
export const PUBLICATION_ARCHIVE_SCHEMA_VERSION = "roomscan-publication-archive-v1" as const;
export const PUBLICATION_SELECTION_SCHEMA_VERSION = "roomscan-publication-selection-manifest-v1" as const;
export const PUBLICATION_MAX_ARCHIVE_BYTES = 805_306_368 as const;
export const PUBLICATION_MAX_NESTED_AI_READY_BYTES = 536_870_912 as const;
export const PUBLICATION_MAX_ASSET_BYTES = 33_554_432 as const;
export const PUBLICATION_MAX_PRESENTATION_BYTES = 8_388_608 as const;
export const PUBLICATION_MAX_PROTECTED_CHUNK_BYTES = 4_194_304 as const;

export type PublicationKind = "room" | "property";
export type PublicationCredentialRequirement = "professional" | "professional_exchange" | "portal_link" | "portal_pending_pin" | "portal_session" | "feedback_capability";
export type PublicationCredentialKind = "app_bearer" | "professional_cookie" | "portal_link" | "portal_pending_pin" | "portal_session" | "feedback_capability";
export type Slice6StalePortalCookieName = "roomscan_portal" | "roomscan_portal_pending" | "roomscan_feedback";

export class PublicationContractError extends Error {
  constructor(readonly code: "invalid_request" | "binding_mismatch" | "credential_confusion" | "invalid_canonical_json") {
    super(code);
    this.name = "PublicationContractError";
  }
}

export interface PublicationSourceBinding {
  readonly publicRoomKey: string;
  readonly projectPublicID: string;
  readonly revisionPublicID: string;
  readonly projectID: string;
  readonly revisionID: string;
  readonly coordinateSpaceEpochID: string;
  readonly packageSchemaVersion: "room-scan-project-v1" | "room-scan-project-v2";
  readonly semanticSHA256: string;
  readonly revisionManifestSHA256: string;
}

export interface PublicationAllocationRequest {
  readonly publicationKind: PublicationKind;
  readonly projectID: string;
  readonly sourceRevisionID: string;
  readonly sourceRevisionDigest: string;
  readonly sourceManifestDigest: string;
  readonly sourceBindings: readonly PublicationSourceBinding[];
  readonly sourceBindingsSHA256: string;
  readonly selectionManifestSHA256: string;
  readonly approvalSHA256: string;
  readonly disclosureStatus: "approved";
  readonly propertyID?: string;
  readonly archiveManifestSHA256: string;
  readonly archiveSHA256: string;
  readonly archiveByteCount: number;
  readonly idempotencyKey: string;
}

export interface Slice6CredentialEnvelope {
  readonly kind: PublicationCredentialKind;
  /** The raw value remains in local request scope only. Callers hash it before
   * a persistence boundary and must never send this record to a logger. */
  readonly secret: string;
  /** Present only for a RoomScan-Link exchange. These names are safe cleanup
   * instructions; the stale cookie values are deliberately never parsed,
   * validated, hashed, logged, or supplied to a capability service. */
  readonly stalePortalCookieNames?: readonly Slice6StalePortalCookieName[];
}
export interface Slice6FeedbackEnvelope {
  readonly portalSessionSecret: string;
  readonly feedbackCapabilitySecret: string;
}

export type Slice6PageRequest = Readonly<{ readonly cursor?: string; readonly limit: number }>;
export type Slice6PropertyRoom = Readonly<{ readonly roomKey: string; readonly roomOrder: number; readonly projectID: string }>;
export type Slice6PropertyUpsertRequest = Readonly<{ readonly propertyID?: string; readonly expectedVersion?: number; readonly createIdempotencyKey?: string; readonly title: string; readonly rooms: readonly Slice6PropertyRoom[] }>;
export type Slice6SnapshotCompletionRequest = Readonly<{ readonly allocationID: string; readonly archiveSHA256: string; readonly archiveManifestSHA256: string; readonly archiveByteCount: number }>;
export type Slice6LinkPolicy = "enabled" | "disabled";
export type Slice6LinkCreateRequest = Readonly<{ readonly snapshotID: string; readonly expiresAt?: string; readonly pin?: string; readonly aiPolicy: Slice6LinkPolicy; readonly feedbackPolicy: Slice6LinkPolicy; readonly idempotencyKey: string }>;
export type Slice6LinkUpdateRequest = Readonly<{ readonly linkID: string; readonly expectedGeneration: number; readonly expiresAt?: string; readonly pin?: string; readonly aiPolicy: Slice6LinkPolicy; readonly feedbackPolicy: Slice6LinkPolicy }>;
export type Slice6PortalAssetRequest = Readonly<{ readonly assetID?: string; readonly downloadKind?: "floor_plan_pdf" | "gallery_zip" | "ai_ready_package"; readonly offset: number; readonly byteCount: number; readonly requestID: string }>;
export type Slice6FeedbackVerificationRequest = Readonly<{ readonly email: string; readonly requestID: string }>;
export type Slice6FeedbackKind = "comment" | "approve" | "request_changes";

/** Parses only UTF-8, sorted-key whitespace-free JSON.  Slice 6 deliberately
 * rejects alternative lexical representations so hashes, request identifiers,
 * and later audit records have one stable representation. */
export function parseSlice6CanonicalJson(bytes: Uint8Array, maximumBytes: number): Readonly<Record<string, unknown>> {
  if (!(bytes instanceof Uint8Array) || !Number.isSafeInteger(maximumBytes) || maximumBytes < 1 || bytes.byteLength < 2 || bytes.byteLength > maximumBytes) throw fail("invalid_request");
  const value = strictCanonicalJson(bytes);
  // Canonical decoding proves syntax and lexical identity only. Field closure
  // belongs to the route-specific parser below; applying an empty closure
  // here would reject every valid non-empty Slice 6 DTO before that parser
  // can enforce its actual approved vocabulary.
  return plainRecord(value);
}

/** The separate Slice 6 DTO vocabulary.  This intentionally has no relation
 * to the frozen flat Slice 4/5 request normalizer. */
export function parseSlice6RoutePayload(routeID: string, bytes: Uint8Array): unknown {
  const record = parseSlice6CanonicalJson(bytes, maximumBodyBytes(routeID));
  switch (routeID) {
  case "professional.properties.list": return parsePage(record, 20);
  case "professional.members.list":
  case "publication.snapshot.list":
    return parsePage(record, 100);
  case "professional.properties.upsert": return parsePropertyUpsert(record);
  case "professional.concepts.list": {
    closedRecord(record, ["projectID"], ["cursor", "limit"]);
    const page = parsePage({ cursor: record.cursor, limit: record.limit }, 20);
    return Object.freeze({ projectID: publicID(record.projectID, "prj_"), ...page });
  }
  case "publication.snapshot.allocate": return parsePublicationAllocationRequest(record);
  case "publication.snapshot.complete": return parseSnapshotCompletion(record);
  case "publication.snapshot.status": return Object.freeze({ allocationID: publicID(closedRecord(record, ["allocationID"]).allocationID, "pua_") });
  case "publication.link.create": return parseLinkCreate(record);
  case "publication.link.update": return parseLinkUpdate(record);
  case "publication.link.revoke": {
    const value = closedRecord(record, ["linkID", "expectedGeneration"]);
    return Object.freeze({ linkID: publicID(value.linkID, "lnk_"), expectedGeneration: positiveInteger(value.expectedGeneration, 1, Number.MAX_SAFE_INTEGER) });
  }
  case "publication.link.list": return parseLinkList(record);
  case "publication.feedback.list": return parseFeedbackList(record);
  case "publication.access-history.list": return parseAccessHistoryList(record);
  case "publication.downloads.list": return Object.freeze({ snapshotID: publicID(closedRecord(record, ["snapshotID"]).snapshotID, "snp_") });
  case "publication.asset.read": return parseProfessionalAsset(record);
  case "portal.pin.verify": return Object.freeze({ pin: pin(closedRecord(record, ["pin"]).pin) });
  case "portal.asset.read": return parsePortalAsset(record);
  case "portal.feedback.verification.request": return parseFeedbackVerificationRequest(record);
  case "portal.feedback.verification.consume": return Object.freeze({ verificationCode: verificationCode(closedRecord(record, ["verificationCode"]).verificationCode) });
  case "portal.feedback.create": return parseFeedbackCreate(record);
  default: throw fail("invalid_request");
  }
}

function maximumBodyBytes(routeID: string): number {
  switch (routeID) {
  case "professional.properties.upsert": return 32_768;
  case "publication.snapshot.allocate": return 131_072;
  case "publication.feedback.list": return 16_384;
  case "professional.properties.list":
  case "professional.concepts.list":
  case "professional.members.list":
  case "publication.snapshot.complete":
  case "publication.snapshot.status":
  case "publication.snapshot.list":
  case "publication.link.create":
  case "publication.link.update":
  case "publication.link.revoke":
  case "publication.link.list":
  case "publication.access-history.list":
  case "publication.downloads.list":
  case "publication.asset.read":
  case "portal.pin.verify":
  case "portal.asset.read":
  case "portal.feedback.verification.request":
  case "portal.feedback.verification.consume":
  case "portal.feedback.create": return 16_384;
  default: throw fail("invalid_request");
  }
}

function parsePage(value: Readonly<Record<string, unknown>>, maximumLimit: number): Slice6PageRequest {
  const record = closedRecord(value, [], ["cursor", "limit"]);
  const cursor = record.cursor === undefined ? undefined : opaqueIdentifier(record.cursor, 16, 512);
  const limit = record.limit === undefined ? maximumLimit : positiveInteger(record.limit, 1, maximumLimit);
  return Object.freeze({ ...(cursor === undefined ? {} : { cursor }), limit });
}

function parsePropertyUpsert(value: Readonly<Record<string, unknown>>): Slice6PropertyUpsertRequest {
  const record = closedRecord(value, ["title", "rooms"], ["propertyID", "expectedVersion", "createIdempotencyKey"]);
  const propertyID = optionalPublicID(record.propertyID, "prop_");
  const expectedVersion = record.expectedVersion === undefined ? undefined : positiveInteger(record.expectedVersion, 1, Number.MAX_SAFE_INTEGER);
  const createIdempotencyKey = record.createIdempotencyKey === undefined ? undefined : opaqueIdentifier(record.createIdempotencyKey, 16, 128);
  if ((propertyID === undefined) !== (expectedVersion === undefined)
    || (propertyID === undefined && createIdempotencyKey === undefined)
    || (propertyID !== undefined && createIdempotencyKey !== undefined)) throw fail("invalid_request");
  if (typeof record.title !== "string" || record.title.length < 1 || record.title.length > 180 || hasUnpairedSurrogate(record.title)) throw fail("invalid_request");
  if (!Array.isArray(record.rooms) || record.rooms.length > 64) throw fail("invalid_request");
  const keys = new Set<string>(); const orders = new Set<number>(); const projects = new Set<string>();
  const rooms = record.rooms.map((candidate) => {
    const room = closedRecord(candidate, ["roomKey", "roomOrder", "projectID"]);
    const roomKey = opaqueIdentifier(room.roomKey, 1, 128, /^[A-Za-z0-9_.-]+$/u);
    const roomOrder = positiveInteger(room.roomOrder, 1, 64);
    const projectID = publicID(room.projectID, "prj_");
    if (keys.has(roomKey) || orders.has(roomOrder) || projects.has(projectID)) throw fail("invalid_request");
    keys.add(roomKey); orders.add(roomOrder); projects.add(projectID);
    return Object.freeze({ roomKey, roomOrder, projectID });
  });
  rooms.sort((left, right) => left.roomOrder - right.roomOrder);
  if (rooms.some((room, index) => room.roomOrder !== index + 1)) throw fail("invalid_request");
  return Object.freeze({ ...(propertyID === undefined ? {} : { propertyID }), ...(expectedVersion === undefined ? {} : { expectedVersion }), ...(createIdempotencyKey === undefined ? {} : { createIdempotencyKey }), title: record.title, rooms: Object.freeze(rooms) });
}

function parseSnapshotCompletion(value: Readonly<Record<string, unknown>>): Slice6SnapshotCompletionRequest {
  const record = closedRecord(value, ["allocationID", "archiveSHA256", "archiveManifestSHA256", "archiveByteCount"]);
  return Object.freeze({ allocationID: publicID(record.allocationID, "pua_"), archiveSHA256: sha256(record.archiveSHA256), archiveManifestSHA256: sha256(record.archiveManifestSHA256), archiveByteCount: positiveInteger(record.archiveByteCount, 1, PUBLICATION_MAX_ARCHIVE_BYTES) });
}

function parseLinkCreate(value: Readonly<Record<string, unknown>>): Slice6LinkCreateRequest {
  const record = closedRecord(value, ["snapshotID", "aiPolicy", "feedbackPolicy", "idempotencyKey"], ["expiresAt", "pin"]);
  const expiresAt = optionalTimestamp(record.expiresAt);
  const maybePin = record.pin === undefined ? undefined : pin(record.pin);
  return Object.freeze({ snapshotID: publicID(record.snapshotID, "snp_"), ...(expiresAt === undefined ? {} : { expiresAt }), ...(maybePin === undefined ? {} : { pin: maybePin }), aiPolicy: linkPolicy(record.aiPolicy), feedbackPolicy: linkPolicy(record.feedbackPolicy), idempotencyKey: opaqueIdentifier(record.idempotencyKey, 16, 128) });
}

function parseLinkUpdate(value: Readonly<Record<string, unknown>>): Slice6LinkUpdateRequest {
  const record = closedRecord(value, ["linkID", "expectedGeneration", "aiPolicy", "feedbackPolicy"], ["expiresAt", "pin"]);
  const expiresAt = optionalTimestamp(record.expiresAt);
  const maybePin = record.pin === undefined ? undefined : pin(record.pin);
  return Object.freeze({ linkID: publicID(record.linkID, "lnk_"), expectedGeneration: positiveInteger(record.expectedGeneration, 1, Number.MAX_SAFE_INTEGER), ...(expiresAt === undefined ? {} : { expiresAt }), ...(maybePin === undefined ? {} : { pin: maybePin }), aiPolicy: linkPolicy(record.aiPolicy), feedbackPolicy: linkPolicy(record.feedbackPolicy) });
}

function parseFeedbackList(value: Readonly<Record<string, unknown>>): Readonly<{ readonly linkID?: string; readonly snapshotID?: string; readonly cursor?: string; readonly limit: number }> {
  const record = closedRecord(value, [], ["linkID", "snapshotID", "cursor", "limit"]);
  const linkID = optionalPublicID(record.linkID, "lnk_"); const snapshotID = optionalPublicID(record.snapshotID, "snp_");
  if (linkID === undefined && snapshotID === undefined) throw fail("invalid_request");
  const page = parsePage({ cursor: record.cursor, limit: record.limit }, 20);
  return Object.freeze({ ...(linkID === undefined ? {} : { linkID }), ...(snapshotID === undefined ? {} : { snapshotID }), ...page });
}

function parseLinkList(value: Readonly<Record<string, unknown>>): Readonly<{ readonly snapshotID?: string; readonly cursor?: string; readonly limit: number }> {
  const record = closedRecord(value, [], ["snapshotID", "cursor", "limit"]);
  const snapshotID = optionalPublicID(record.snapshotID, "snp_");
  const page = parsePage({ cursor: record.cursor, limit: record.limit }, 100);
  return Object.freeze({ ...(snapshotID === undefined ? {} : { snapshotID }), ...page });
}

function parseAccessHistoryList(value: Readonly<Record<string, unknown>>): Readonly<{ readonly linkID?: string; readonly cursor?: string; readonly limit: number }> {
  const record = closedRecord(value, [], ["linkID", "cursor", "limit"]);
  const linkID = optionalPublicID(record.linkID, "lnk_");
  const page = parsePage({ cursor: record.cursor, limit: record.limit }, 100);
  return Object.freeze({ ...(linkID === undefined ? {} : { linkID }), ...page });
}

function parsePortalAsset(value: Readonly<Record<string, unknown>>): Slice6PortalAssetRequest {
  const record = closedRecord(value, ["offset", "byteCount", "requestID"], ["assetID", "downloadKind"]);
  const assetID = record.assetID === undefined ? undefined : publicID(record.assetID, "ast_");
  const downloadKind = record.downloadKind === undefined ? undefined : enumValue(record.downloadKind, ["floor_plan_pdf", "gallery_zip", "ai_ready_package"] as const);
  if ((assetID === undefined) === (downloadKind === undefined)) throw fail("invalid_request");
  return Object.freeze({ ...(assetID === undefined ? {} : { assetID }), ...(downloadKind === undefined ? {} : { downloadKind }), offset: positiveInteger(record.offset, 0, PUBLICATION_MAX_ARCHIVE_BYTES), byteCount: positiveInteger(record.byteCount, 1, PUBLICATION_MAX_PROTECTED_CHUNK_BYTES), requestID: opaqueIdentifier(record.requestID, 16, 128) });
}

function parseProfessionalAsset(value: Readonly<Record<string, unknown>>): Readonly<{ readonly assetID: string; readonly offset: number; readonly byteCount: number; readonly requestID: string }> {
  const record = closedRecord(value, ["assetID", "offset", "byteCount", "requestID"]);
  return Object.freeze({
    assetID: publicID(record.assetID, "ast_"),
    offset: positiveInteger(record.offset, 0, PUBLICATION_MAX_ARCHIVE_BYTES),
    byteCount: positiveInteger(record.byteCount, 1, PUBLICATION_MAX_PROTECTED_CHUNK_BYTES),
    requestID: opaqueIdentifier(record.requestID, 16, 128),
  });
}

function parseFeedbackVerificationRequest(value: Readonly<Record<string, unknown>>): Slice6FeedbackVerificationRequest {
  const record = closedRecord(value, ["email", "requestID"]);
  return Object.freeze({ email: email(record.email), requestID: opaqueIdentifier(record.requestID, 16, 128) });
}

function parseFeedbackCreate(value: Readonly<Record<string, unknown>>): Readonly<{ readonly action: Slice6FeedbackKind; readonly comment?: string; readonly requestID: string }> {
  const record = closedRecord(value, ["action", "requestID"], ["comment"]);
  const action = enumValue(record.action, ["comment", "approve", "request_changes"] as const);
  const comment = record.comment;
  if (comment !== undefined && (typeof comment !== "string" || comment.length > 4_000 || hasUnpairedSurrogate(comment))) throw fail("invalid_request");
  if ((action === "comment" || action === "request_changes") && (typeof comment !== "string" || comment.length < 1)) throw fail("invalid_request");
  return Object.freeze({ action, ...(comment === undefined ? {} : { comment }), requestID: opaqueIdentifier(record.requestID, 16, 128) });
}

function optionalTimestamp(value: unknown): string | undefined { if (value === undefined) return undefined; if (!isCanonicalTimestamp(value)) throw fail("invalid_request"); return value; }
function linkPolicy(value: unknown): Slice6LinkPolicy { return enumValue(value, ["enabled", "disabled"] as const); }
function pin(value: unknown): string { if (typeof value !== "string" || !/^[0-9]{6}$/u.test(value)) throw fail("invalid_request"); return value; }
function email(value: unknown): string { if (typeof value !== "string" || value.length < 3 || value.length > 320 || /[\u0000-\u001f\u007f-\u009f]/u.test(value) || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/u.test(value)) throw fail("invalid_request"); return value; }
function verificationCode(value: unknown): string { const match = typeof value === "string" ? /^([A-Za-z0-9_-]{43})\.([A-Za-z0-9_-]{43})$/u.exec(value) : undefined; if (match?.[1] === undefined || match[2] === undefined || !opaqueSecret(match[1]) || !opaqueSecret(match[2])) throw fail("invalid_request"); return match[0]; }

export function parsePublicationAllocationRequest(value: unknown): PublicationAllocationRequest {
  const record = closedRecord(value, [
    "publicationKind", "projectID", "sourceRevisionID", "sourceRevisionDigest", "sourceManifestDigest",
    "sourceBindings", "sourceBindingsSHA256", "selectionManifestSHA256", "approvalSHA256",
    "disclosureStatus", "archiveManifestSHA256", "archiveSHA256", "archiveByteCount", "idempotencyKey",
  ], ["propertyID"]);
  const publicationKind = enumValue(record.publicationKind, ["room", "property"] as const);
  const projectID = publicID(record.projectID, "prj_");
  const sourceRevisionID = publicID(record.sourceRevisionID, "rev_");
  const sourceRevisionDigest = sha256(record.sourceRevisionDigest);
  const sourceManifestDigest = sha256(record.sourceManifestDigest);
  const sourceBindings = parseSourceBindings(record.sourceBindings, publicationKind);
  const sourceBindingsSHA256 = sha256(record.sourceBindingsSHA256);
  if (canonicalSourceBindingsSHA256(sourceBindings) !== sourceBindingsSHA256) throw fail("binding_mismatch");
  const selectionManifestSHA256 = sha256(record.selectionManifestSHA256);
  const approvalSHA256 = sha256(record.approvalSHA256);
  if (record.disclosureStatus !== "approved") throw fail("invalid_request");
  const propertyID = optionalPublicID(record.propertyID, "prop_");
  if ((publicationKind === "room") !== (propertyID === undefined)) throw fail("invalid_request");
  if (projectID !== sourceBindings[0]?.projectPublicID || sourceRevisionID !== sourceBindings[0]?.revisionPublicID) throw fail("binding_mismatch");
  const archiveManifestSHA256 = sha256(record.archiveManifestSHA256);
  const archiveSHA256 = sha256(record.archiveSHA256);
  const archiveByteCount = positiveInteger(record.archiveByteCount, 1, PUBLICATION_MAX_ARCHIVE_BYTES);
  const idempotencyKey = opaqueIdentifier(record.idempotencyKey, 16, 128);
  return Object.freeze({
    publicationKind, projectID, sourceRevisionID, sourceRevisionDigest, sourceManifestDigest,
    sourceBindings: Object.freeze(sourceBindings), sourceBindingsSHA256, selectionManifestSHA256,
    approvalSHA256, disclosureStatus: "approved", ...(propertyID === undefined ? {} : { propertyID }),
    archiveManifestSHA256, archiveSHA256, archiveByteCount, idempotencyKey,
  });
}

/** Exactly one credential family can enter a Slice 6 route. In particular,
 * app/browser professional credentials are never inferred from portal
 * cookies, and a link bearer is never accepted as an app bearer. */
export function parseSlice6CredentialEnvelope(input: {
  readonly required: PublicationCredentialRequirement;
  readonly headers?: Readonly<Record<string, string | undefined>>;
  readonly cookies?: readonly string[];
}): Slice6CredentialEnvelope {
  if (input === null || typeof input !== "object") throw fail("credential_confusion");
  const headers = normalizedHeaders(input.headers);
  // Link replacement deliberately happens before normal cookie decoding. A
  // link is authorized exclusively by its literal Authorization header; stale
  // /portal cookie bytes are ambient browser state to discard, not credentials.
  if (input.required === "portal_link") {
    const authorization = headers.get("authorization");
    const linkBearer = parseAuthorization(authorization, "RoomScan-Link");
    if (linkBearer === undefined || parseAuthorization(authorization, "Bearer") !== undefined) throw fail("credential_confusion");
    const stalePortalCookieNames = discardedPortalCookieNames(input.cookies);
    return Object.freeze({
      kind: "portal_link" as const,
      secret: linkBearer,
      ...(stalePortalCookieNames.length === 0 ? {} : { stalePortalCookieNames }),
    });
  }
  // A professional exchange is deliberately narrower than ordinary
  // professional credential parsing. A fresh frozen app bearer may replace
  // one ambient cookie scoped to /professional, but that cookie is never a
  // credential on this route: its name is inspected solely to reject mixed
  // families and its value never reaches a parsed envelope.
  if (input.required === "professional_exchange") {
    const authorization = headers.get("authorization");
    const appBearer = parseAuthorization(authorization, "Bearer");
    if (appBearer === undefined || parseAuthorization(authorization, "RoomScan-Link") !== undefined) throw fail("credential_confusion");
    discardableProfessionalExchangeCookie(input.cookies);
    return Object.freeze({ kind: "app_bearer" as const, secret: appBearer });
  }
  const cookies = normalizedCookies(input.cookies);
  const authorization = headers.get("authorization");
  const credentialCookies = [
    "roomscan_professional", "roomscan_portal", "roomscan_portal_pending", "roomscan_feedback",
  ].filter((name) => cookies.has(name));
  if (credentialCookies.length > 1) throw fail("credential_confusion");

  const appBearer = parseAuthorization(authorization, "Bearer");
  const linkBearer = parseAuthorization(authorization, "RoomScan-Link");
  if (authorization !== undefined && appBearer === undefined && linkBearer === undefined) throw fail("credential_confusion");
  if (appBearer !== undefined && linkBearer !== undefined) throw fail("credential_confusion");

  const only = (name: string): string => {
    if (authorization !== undefined || credentialCookies.length !== 1 || credentialCookies[0] !== name) throw fail("credential_confusion");
    const value = cookies.get(name);
    if (value === undefined || !opaqueSecret(value)) throw fail("credential_confusion");
    return value;
  };
  switch (input.required) {
  case "professional":
    if (appBearer !== undefined && credentialCookies.length === 0) return Object.freeze({ kind: "app_bearer", secret: appBearer });
    return Object.freeze({ kind: "professional_cookie", secret: only("roomscan_professional") });
  case "portal_pending_pin":
    return Object.freeze({ kind: "portal_pending_pin", secret: only("roomscan_portal_pending") });
  case "portal_session":
    return Object.freeze({ kind: "portal_session", secret: only("roomscan_portal") });
  case "feedback_capability":
    return Object.freeze({ kind: "feedback_capability", secret: only("roomscan_feedback") });
  }
}

/** Feedback creation is intentionally compound: the active portal session
 * scopes a link/generation/snapshot while a distinct one-time verification
 * capability proves verified feedback. No professional, pending-PIN, or
 * bearer credential can be mixed into this narrow pair. */
export function parseSlice6FeedbackEnvelope(input: { readonly headers?: Readonly<Record<string, string | undefined>>; readonly cookies?: readonly string[] }): Slice6FeedbackEnvelope {
  const headers = normalizedHeaders(input.headers); const cookies = normalizedCookies(input.cookies);
  if (headers.has("authorization") || cookies.size !== 2 || !cookies.has("roomscan_portal") || !cookies.has("roomscan_feedback")) throw fail("credential_confusion");
  const portalSessionSecret = cookies.get("roomscan_portal"); const feedbackCapabilitySecret = cookies.get("roomscan_feedback");
  if (portalSessionSecret === undefined || feedbackCapabilitySecret === undefined || !opaqueSecret(portalSessionSecret) || !opaqueSecret(feedbackCapabilitySecret)) throw fail("credential_confusion");
  return Object.freeze({ portalSessionSecret, feedbackCapabilitySecret });
}

/** Swift's Core fixtures use sorted-key, whitespace-free canonical JSON. All
 * identifiers/digests that are cross-checked here are ASCII, so the portable
 * recursive canonical encoder has one unambiguous representation. */
export function canonicalJson(value: unknown): string {
  return canonical(value);
}

export function canonicalJsonSHA256(value: unknown): string {
  return sha256Bytes(Buffer.from(canonicalJson(value), "utf8"));
}

export function canonicalSourceBindingsSHA256(bindings: readonly PublicationSourceBinding[]): string {
  const core = bindings.map((binding) => ({
    publicRoomKey: binding.publicRoomKey,
    sourceRevision: {
      coordinateSpaceEpochID: binding.coordinateSpaceEpochID,
      packageSchemaVersion: binding.packageSchemaVersion,
      projectID: binding.projectID,
      revisionID: binding.revisionID,
      revisionManifestSHA256: binding.revisionManifestSHA256,
      semanticSHA256: binding.semanticSHA256,
    },
  }));
  return canonicalJsonSHA256(core);
}

export function strictCanonicalJson(bytes: Uint8Array): unknown {
  let text: string;
  try { text = new TextDecoder("utf-8", { fatal: true }).decode(bytes); } catch { throw fail("invalid_canonical_json"); }
  if (hasDuplicateDecodedJsonKeys(text)) throw fail("invalid_canonical_json");
  let value: unknown;
  try { value = JSON.parse(text); } catch { throw fail("invalid_canonical_json"); }
  if (canonicalJson(value) !== text) throw fail("invalid_canonical_json");
  return value;
}

export function sha256Bytes(bytes: Uint8Array): string {
  return createHash("sha256").update(bytes).digest("hex");
}

export function isSHA256(value: unknown): value is string {
  return typeof value === "string" && /^[a-f0-9]{64}$/u.test(value);
}

export function isCanonicalTimestamp(value: unknown): value is string {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/u.test(value)) return false;
  const milliseconds = Date.parse(value);
  if (!Number.isSafeInteger(milliseconds)) return false;
  const normalized = new Date(milliseconds).toISOString();
  return value.includes(".") ? normalized === value : normalized === `${value.slice(0, -1)}.000Z`;
}

function parseSourceBindings(value: unknown, kind: PublicationKind): PublicationSourceBinding[] {
  if (!Array.isArray(value) || (kind === "room" && value.length !== 1) || (kind === "property" && (value.length < 2 || value.length > 64))) throw fail("invalid_request");
  const roomKeys = new Set<string>(); const projectIDs = new Set<string>();
  const bindings = value.map((candidate) => {
    const record = closedRecord(candidate, [
      "publicRoomKey", "projectPublicID", "revisionPublicID", "projectID", "revisionID",
      "coordinateSpaceEpochID", "packageSchemaVersion", "semanticSHA256", "revisionManifestSHA256",
    ]);
    const binding: PublicationSourceBinding = Object.freeze({
      publicRoomKey: opaqueIdentifier(record.publicRoomKey, 1, 128, /^[A-Za-z0-9_.-]+$/u),
      projectPublicID: publicID(record.projectPublicID, "prj_"),
      revisionPublicID: publicID(record.revisionPublicID, "rev_"),
      projectID: opaqueIdentifier(record.projectID, 1, 128),
      revisionID: opaqueIdentifier(record.revisionID, 1, 128),
      coordinateSpaceEpochID: opaqueIdentifier(record.coordinateSpaceEpochID, 1, 128, /^[A-Za-z0-9_.-]+$/u),
      packageSchemaVersion: enumValue(record.packageSchemaVersion, ["room-scan-project-v1", "room-scan-project-v2"] as const),
      semanticSHA256: sha256(record.semanticSHA256),
      revisionManifestSHA256: sha256(record.revisionManifestSHA256),
    });
    if (roomKeys.has(binding.publicRoomKey) || projectIDs.has(binding.projectPublicID)) throw fail("invalid_request");
    roomKeys.add(binding.publicRoomKey); projectIDs.add(binding.projectPublicID);
    return binding;
  });
  return bindings;
}

function closedRecord(value: unknown, required: readonly string[], optional: readonly string[] = []): Readonly<Record<string, unknown>> {
  const record = plainRecord(value);
  const allowed = new Set([...required, ...optional]);
  if (Object.keys(record).some((key) => !allowed.has(key)) || required.some((key) => record[key] === undefined)) throw fail("invalid_request");
  return record;
}
function plainRecord(value: unknown): Readonly<Record<string, unknown>> {
  if (value === null || typeof value !== "object" || Array.isArray(value) || Object.getPrototypeOf(value) !== Object.prototype) throw fail("invalid_request");
  return value as Readonly<Record<string, unknown>>;
}
function enumValue<T extends readonly string[]>(value: unknown, allowed: T): T[number] { if (typeof value !== "string" || !allowed.includes(value)) throw fail("invalid_request"); return value as T[number]; }
function sha256(value: unknown): string { if (!isSHA256(value)) throw fail("invalid_request"); return value; }
function publicID(value: unknown, prefix: string): string { if (typeof value !== "string" || !new RegExp(`^${prefix}[A-Za-z0-9_-]{16,128}$`, "u").test(value)) throw fail("invalid_request"); return value; }
function optionalPublicID(value: unknown, prefix: string): string | undefined { if (value === undefined) return undefined; return publicID(value, prefix); }
function opaqueIdentifier(value: unknown, minimum: number, maximum: number, grammar = /^[A-Za-z0-9_-]+$/u): string { if (typeof value !== "string" || value.length < minimum || value.length > maximum || !grammar.test(value)) throw fail("invalid_request"); return value; }
function positiveInteger(value: unknown, minimum: number, maximum: number): number { if (typeof value !== "number" || !Number.isSafeInteger(value) || value < minimum || value > maximum) throw fail("invalid_request"); return value; }
function fail(code: PublicationContractError["code"]): never { throw new PublicationContractError(code); }

function canonical(value: unknown): string {
  if (value === null) return "null";
  if (typeof value === "string") {
    if (hasUnpairedSurrogate(value)) throw fail("invalid_canonical_json");
    return JSON.stringify(value);
  }
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number") {
    if (!Number.isFinite(value) || !Number.isSafeInteger(value) && !Number.isFinite(value)) throw fail("invalid_canonical_json");
    const encoded = JSON.stringify(value);
    if (encoded === undefined) throw fail("invalid_canonical_json");
    return encoded;
  }
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (typeof value === "object" && Object.getPrototypeOf(value) === Object.prototype) {
    const record = value as Record<string, unknown>;
    return `{${Object.keys(record).sort().map((key) => `${canonical(key)}:${canonical(record[key])}`).join(",")}}`;
  }
  throw fail("invalid_canonical_json");
}

/** JavaScript strings are UTF-16. A high/low pair represents one valid
 * non-BMP scalar and must remain legal; only a lone half is not valid scalar
 * Unicode for the portable canonical JSON contract. */
function hasUnpairedSurrogate(value: string): boolean {
  for (let index = 0; index < value.length; index += 1) {
    const unit = value.charCodeAt(index);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (!(next >= 0xdc00 && next <= 0xdfff)) return true;
      index += 1;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return true;
    }
  }
  return false;
}

function normalizedHeaders(headers: Readonly<Record<string, string | undefined>> | undefined): ReadonlyMap<string, string> {
  if (headers === undefined) return new Map();
  if (headers === null || typeof headers !== "object") throw fail("credential_confusion");
  const normalized = new Map<string, string>();
  for (const [name, value] of Object.entries(headers)) {
    if (!/^[!#$%&'*+.^_`|~0-9A-Za-z-]{1,128}$/u.test(name) || typeof value !== "string" || value.length > 8_192) throw fail("credential_confusion");
    const lower = name.toLowerCase();
    if (normalized.has(lower)) throw fail("credential_confusion");
    normalized.set(lower, value);
  }
  return normalized;
}
function normalizedCookies(cookies: readonly string[] | undefined): ReadonlyMap<string, string> {
  if (cookies === undefined) return new Map();
  if (!Array.isArray(cookies) || cookies.length > 8) throw fail("credential_confusion");
  const output = new Map<string, string>();
  for (const item of cookies) {
    if (typeof item !== "string" || item.length > 8_192) throw fail("credential_confusion");
    const match = /^([A-Za-z0-9_-]{1,64})=([A-Za-z0-9_-]{1,512})$/u.exec(item);
    if (match?.[1] === undefined || match[2] === undefined || output.has(match[1])) throw fail("credential_confusion");
    output.set(match[1], match[2]);
  }
  return output;
}
function discardedPortalCookieNames(cookies: readonly string[] | undefined): readonly Slice6StalePortalCookieName[] {
  if (cookies === undefined) return Object.freeze([]);
  if (!Array.isArray(cookies) || cookies.length > 8) throw fail("credential_confusion");
  const stale = new Set<Slice6StalePortalCookieName>();
  for (const item of cookies) {
    if (typeof item !== "string" || item.length > 8_192) throw fail("credential_confusion");
    const separator = item.indexOf("=");
    // Only the cookie name is inspected. In particular, do not slice, decode,
    // validate, or retain the value after this structural separator check.
    const name = separator < 1 ? "" : item.slice(0, separator);
    if (!/^[A-Za-z0-9_-]{1,64}$/u.test(name)) throw fail("credential_confusion");
    if (name !== "roomscan_portal" && name !== "roomscan_portal_pending" && name !== "roomscan_feedback") throw fail("credential_confusion");
    if (stale.has(name)) throw fail("credential_confusion");
    stale.add(name);
  }
  const names: readonly Slice6StalePortalCookieName[] = ["roomscan_portal", "roomscan_portal_pending", "roomscan_feedback"];
  return Object.freeze(names.filter((name) => stale.has(name)));
}
function discardableProfessionalExchangeCookie(cookies: readonly string[] | undefined): void {
  if (cookies === undefined) return;
  if (!Array.isArray(cookies) || cookies.length > 1) throw fail("credential_confusion");
  for (const item of cookies) {
    if (typeof item !== "string" || item.length > 8_192) throw fail("credential_confusion");
    const separator = item.indexOf("=");
    // This exchange is intentionally value-blind. The stale browser cookie
    // is merely overwritten by the new server session and is never decoded,
    // validated, hashed, logged, or handed to a capability service.
    const name = separator < 1 ? "" : item.slice(0, separator);
    if (name !== "roomscan_professional") throw fail("credential_confusion");
  }
}
function parseAuthorization(value: string | undefined, scheme: "Bearer" | "RoomScan-Link"): string | undefined {
  if (value === undefined) return undefined;
  if (scheme === "Bearer") {
    // Keep the frozen app-bearer grammar byte-for-byte compatible. It is a
    // pre-existing opaque credential, not a new portal secret.
    return /^Bearer ([A-Za-z0-9._~-]{32,4096})$/u.exec(value)?.[1];
  }
  const match = /^RoomScan-Link ([A-Za-z0-9_-]{43})$/u.exec(value);
  return match?.[1] !== undefined && opaqueSecret(match[1]) ? match[1] : undefined;
}
function opaqueSecret(value: string): boolean {
  if (!/^[A-Za-z0-9_-]{43}$/u.test(value)) return false;
  const decoded = Buffer.from(value, "base64url");
  return decoded.byteLength === 32 && decoded.toString("base64url") === value;
}

/** Lexical duplicate-key detection compares decoded names, including escaped
 * aliases. This is intentionally separate from the frozen Slice 4/5 parser. */
function hasDuplicateDecodedJsonKeys(source: string): boolean {
  let index = 0;
  const whitespace = () => { while (/\s/u.test(source[index] ?? "")) index += 1; };
  const token = (): string | undefined => {
    if (source[index] !== "\"") return undefined;
    const start = index; index += 1; let escaped = false;
    while (index < source.length) {
      const character = source[index++]!;
      if (escaped) { escaped = false; continue; }
      if (character === "\\") { escaped = true; continue; }
      if (character === "\"") {
        try { return JSON.parse(source.slice(start, index)); } catch { return undefined; }
      }
      if (character.charCodeAt(0) < 0x20) return undefined;
    }
    return undefined;
  };
  const primitive = (): boolean => {
    whitespace();
    if (source[index] === "\"") return token() !== undefined;
    if (source[index] === "{") return object();
    if (source[index] === "[") return array();
    const match = /^(?:true|false|null|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)/u.exec(source.slice(index));
    if (match?.[0] === undefined) return false;
    index += match[0].length; return true;
  };
  const array = (): boolean => {
    if (source[index++] !== "[") return false; whitespace(); if (source[index] === "]") { index += 1; return true; }
    for (;;) { if (!primitive()) return false; whitespace(); if (source[index] === "]") { index += 1; return true; } if (source[index++] !== ",") return false; }
  };
  const object = (): boolean => {
    if (source[index++] !== "{") return false; whitespace(); if (source[index] === "}") { index += 1; return true; }
    const keys = new Set<string>();
    for (;;) {
      const key = token(); if (key === undefined || keys.has(key)) return false; keys.add(key); whitespace();
      if (source[index++] !== ":" || !primitive()) return false; whitespace();
      if (source[index] === "}") { index += 1; return true; } if (source[index++] !== ",") return false; whitespace();
    }
  };
  whitespace(); const valid = primitive(); whitespace();
  return !valid || index !== source.length;
}
