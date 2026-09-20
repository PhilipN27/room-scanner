import { createHmac, randomBytes, scrypt as nodeScrypt } from "node:crypto";

import type { DataApiClient, SqlCell, SqlResult, SqlStatement } from "../adapters/data-api.js";
import { PublicationObjectAdapter } from "../adapters/s3-publication.js";
import { DataApiCapabilityTransactionRunner } from "../persistence/transaction-runner.js";
import type { CapabilitySqlUnit } from "../persistence/capabilities.js";
import {
  canonicalJson,
  type PublicationAllocationRequest,
  type PublicationCredentialKind,
  type Slice6LinkCreateRequest,
  type Slice6LinkUpdateRequest,
  type Slice6PageRequest,
  type Slice6PortalAssetRequest,
  type Slice6PropertyUpsertRequest,
  type Slice6SnapshotCompletionRequest,
  type Slice6FeedbackVerificationRequest,
} from "./contracts.js";
import {
  PublicationFeedbackEnvelopeError,
  type PublicationFeedbackDeliveryWakePort,
  type PublicationFeedbackEnvelopeSealer,
} from "./feedback-service.js";
import type { PublicationAuditAction, PublicationAuditResult, PublicationPrivacyAuditPort } from "./privacy-audit.js";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;

export class PublicationCapabilityError extends Error {
  constructor(readonly code: "invalid_input" | "invalid_result" | "unavailable" | "forbidden") { super(code); this.name = "PublicationCapabilityError"; }
}

export interface PublicationClock { now(): Date; }
export interface PublicationValidationWakePort { notifyPublicationValidationWake(): Promise<void>; }

export interface PublicationCredential {
  readonly kind: "app_bearer" | "web_session";
  readonly hash: Uint8Array;
  readonly browser: boolean;
}
export interface PortalSessionCredential { readonly hash: Uint8Array; }
export interface FeedbackCredential { readonly portalSessionHash: Uint8Array; readonly feedbackTokenHash: Uint8Array; }

export interface PublicationPortalAssetDelivery {
  readonly bytes: Uint8Array;
  readonly contentType: "application/json" | "image/png" | "image/jpeg" | "application/pdf" | "application/zip";
  readonly attachment: boolean;
  readonly range: Readonly<{ readonly offset: number; readonly byteCount: number; readonly totalBytes: number }>;
}

/** Narrow app-facing capability surface.  No method accepts an internal ID,
 * object key/version, tenant, flag epoch, role, time, quota, PIN hash, or
 * feedback row identifier from HTTP. */
export interface PublicationCapabilityService {
  issueProfessionalSession(appBearerHash: Uint8Array): Promise<Readonly<{ readonly cookieSecret: string; readonly expiresAt: string; readonly bootstrap: Readonly<Record<string, unknown>> }>>;
  revokeProfessionalSession(credential: PublicationCredential): Promise<void>;
  listProperties(credential: PublicationCredential, page: Slice6PageRequest): Promise<readonly Readonly<Record<string, unknown>>[]>;
  listRoomCandidates(credential: PublicationCredential): Promise<readonly Readonly<Record<string, unknown>>[]>;
  upsertProperty(credential: PublicationCredential, input: Slice6PropertyUpsertRequest): Promise<Readonly<Record<string, unknown>>>;
  listConcepts(credential: PublicationCredential, input: Readonly<{ readonly projectID: string } & Slice6PageRequest>): Promise<readonly Readonly<Record<string, unknown>>[]>;
  listMembers(credential: PublicationCredential, page: Slice6PageRequest): Promise<readonly Readonly<Record<string, unknown>>[]>;
  allocateSnapshot(credential: PublicationCredential, input: PublicationAllocationRequest): Promise<Readonly<Record<string, unknown>>>;
  completeSnapshot(credential: PublicationCredential, input: Slice6SnapshotCompletionRequest): Promise<Readonly<Record<string, unknown>>>;
  snapshotStatus(credential: PublicationCredential, allocationID: string): Promise<Readonly<Record<string, unknown>> | undefined>;
  listSnapshots(credential: PublicationCredential, page: Slice6PageRequest): Promise<readonly Readonly<Record<string, unknown>>[]>;
  createLink(credential: PublicationCredential, input: Slice6LinkCreateRequest): Promise<Readonly<Record<string, unknown>>>;
  updateLink(credential: PublicationCredential, input: Slice6LinkUpdateRequest): Promise<Readonly<Record<string, unknown>>>;
  revokeLink(credential: PublicationCredential, input: Readonly<{ readonly linkID: string; readonly expectedGeneration: number }>): Promise<Readonly<Record<string, unknown>>>;
  listLinks(credential: PublicationCredential, input: Readonly<{ readonly snapshotID?: string } & Slice6PageRequest>): Promise<readonly Readonly<Record<string, unknown>>[]>;
  listFeedback(credential: PublicationCredential, input: Readonly<{ readonly linkID?: string; readonly snapshotID?: string } & Slice6PageRequest>): Promise<readonly Readonly<Record<string, unknown>>[]>;
  listAccessHistory(credential: PublicationCredential, input: Readonly<{ readonly linkID?: string } & Slice6PageRequest>): Promise<readonly Readonly<Record<string, unknown>>[]>;
  listDownloads(credential: PublicationCredential, snapshotID: string): Promise<readonly Readonly<Record<string, unknown>>[]>;
  exchangePortalLink(linkTokenHash: Uint8Array, clientFamily: "desktop" | "mobile" | "tablet" | "unknown", networkRiskDigest: Uint8Array): Promise<Readonly<{ readonly status: "active" | "pin_required" | "unavailable" | "killed"; readonly cookieSecret?: string }>>;
  verifyPortalPIN(session: PortalSessionCredential, pin: string): Promise<Readonly<{ readonly status: "verified" | "denied" | "cooldown" | "unavailable" }>>;
  portalSnapshot(session: PortalSessionCredential): Promise<Readonly<Record<string, unknown>>>;
  deliverPortalAsset(session: PortalSessionCredential, input: Slice6PortalAssetRequest): Promise<PublicationPortalAssetDelivery>;
  deliverProfessionalAsset(credential: PublicationCredential, input: Readonly<{ readonly assetID: string; readonly offset: number; readonly byteCount: number; readonly requestID: string }>): Promise<PublicationPortalAssetDelivery>;
  requestFeedbackVerification(session: PortalSessionCredential, input: Slice6FeedbackVerificationRequest): Promise<void>;
  consumeFeedbackVerification(session: PortalSessionCredential, verificationCode: string): Promise<Readonly<{ readonly feedbackCookieSecret?: string }>>;
  createFeedback(credential: FeedbackCredential, input: Readonly<{ readonly action: "comment" | "approve" | "request_changes"; readonly comment?: string; readonly requestID: string }>): Promise<Readonly<Record<string, unknown>>>;
}

/** Converts a raw credential only at the API edge.  HMAC keeps every database
 * comparison fixed width and avoids storing/linking bearer material directly. */
export class PublicationSecretHasher {
  readonly #key: Uint8Array;
  constructor(key: Uint8Array) { if (!(key instanceof Uint8Array) || key.byteLength < 32) throw new PublicationCapabilityError("invalid_input"); this.#key = Uint8Array.from(key); }
  hash(label: string, value: string): Uint8Array {
    if (typeof label !== "string" || !/^[a-z0-9_-]{1,64}$/u.test(label) || typeof value !== "string" || value.length < 1 || value.length > 4_096) throw new PublicationCapabilityError("invalid_input");
    return createHmac("sha256", this.#key).update("roomscan-publication-v1\0", "utf8").update(label, "utf8").update("\0", "utf8").update(value, "utf8").digest();
  }
  /** App bearers predate Slice 6 and are looked up by the existing raw
   * access-token HMAC. Do not add a publication label here: that would create
   * a different digest and strand legitimate iOS clients. */
  accessTokenHash(value: string): Uint8Array {
    if (typeof value !== "string" || !/^[A-Za-z0-9._~-]{32,4096}$/u.test(value)) throw new PublicationCapabilityError("invalid_input");
    return createHmac("sha256", this.#key).update(value, "utf8").digest();
  }
  /** A HMAC-derived opaque capability is deterministic only for an exact
   * server-scoped idempotent operation. The raw value is never persisted. */
  deriveSecret(label: string, value: string): string { return Buffer.from(this.hash(label, value)).toString("base64url"); }
  secret(): string { return randomBytes(32).toString("base64url"); }
}

export function credentialForPublication(envelope: { readonly kind: PublicationCredentialKind; readonly secret: string }, hasher: PublicationSecretHasher): PublicationCredential {
  if (envelope.kind === "app_bearer") return Object.freeze({ kind: "app_bearer", hash: hasher.accessTokenHash(envelope.secret), browser: false });
  if (envelope.kind === "professional_cookie") return Object.freeze({ kind: "web_session", hash: hasher.hash("professional-session", envelope.secret), browser: true });
  throw new PublicationCapabilityError("invalid_input");
}
export function portalSessionForPublication(secret: string, hasher: PublicationSecretHasher): PortalSessionCredential { return Object.freeze({ hash: hasher.hash("portal-session", secret) }); }
export function portalLinkHash(secret: string, hasher: PublicationSecretHasher): Uint8Array { return hasher.hash("portal-link", secret); }

/** The Data API service is the actual capability boundary.  It has a separate
 * publication transaction runner, does not use the frozen route normalizer,
 * and makes a database reducer call for every live portal operation. */
export class DataApiPublicationCapabilityService implements PublicationCapabilityService {
  readonly #transactions: DataApiCapabilityTransactionRunner<CapabilitySqlUnit>;
  readonly #clock: PublicationClock;
  readonly #hasher: PublicationSecretHasher;
  readonly #storage: PublicationObjectAdapter;
  readonly #wake: PublicationValidationWakePort;
  readonly #feedbackEnvelopeSealer: PublicationFeedbackEnvelopeSealer;
  readonly #feedbackWake: PublicationFeedbackDeliveryWakePort;
  readonly #portalOrigin: string;
  readonly #audit: PublicationPrivacyAuditPort | undefined;

  constructor(input: { readonly client: DataApiClient; readonly clock: PublicationClock; readonly hasher: PublicationSecretHasher; readonly storage: PublicationObjectAdapter; readonly validationWake: PublicationValidationWakePort; readonly feedbackEnvelopeSealer: PublicationFeedbackEnvelopeSealer; readonly feedbackDeliveryWake: PublicationFeedbackDeliveryWakePort; readonly portalOrigin?: string; readonly publicationAudit?: PublicationPrivacyAuditPort }) {
    if (input === null || typeof input !== "object" || input.client === null || typeof input.client !== "object" || input.clock === null || typeof input.clock.now !== "function" || !(input.hasher instanceof PublicationSecretHasher) || !(input.storage instanceof PublicationObjectAdapter) || input.validationWake === null || typeof input.validationWake.notifyPublicationValidationWake !== "function" || input.feedbackEnvelopeSealer === null || typeof input.feedbackEnvelopeSealer !== "object" || typeof input.feedbackEnvelopeSealer.seal !== "function" || input.feedbackDeliveryWake === null || typeof input.feedbackDeliveryWake !== "object" || typeof input.feedbackDeliveryWake.notifyFeedbackDeliveryWake !== "function" || (input.portalOrigin !== undefined && !validPortalOrigin(input.portalOrigin)) || (input.publicationAudit !== undefined && (input.publicationAudit === null || typeof input.publicationAudit.record !== "function"))) throw new PublicationCapabilityError("invalid_input");
    this.#transactions = new DataApiCapabilityTransactionRunner(input.client, (unit) => unit); this.#clock = input.clock; this.#hasher = input.hasher; this.#storage = input.storage; this.#wake = input.validationWake; this.#feedbackEnvelopeSealer = input.feedbackEnvelopeSealer; this.#feedbackWake = input.feedbackDeliveryWake; this.#portalOrigin = input.portalOrigin ?? "https://portal.roomscanstudio.invalid"; this.#audit = input.publicationAudit;
  }

  async issueProfessionalSession(appBearerHash: Uint8Array): Promise<Readonly<{ readonly cookieSecret: string; readonly expiresAt: string; readonly bootstrap: Readonly<Record<string, unknown>> }>> {
    const now = this.#now(); requireHash(appBearerHash); const secret = this.#hasher.secret(); const sessionHash = this.#hasher.hash("professional-session", secret);
    const result = await this.#run(async (unit) => {
      const context = one(await unit.execute(statement(RESOLVE_APP_WORKSPACE_SQL, [blob("access_token_hash", appBearerHash), timestamp("authoritative_time", now)])));
      const workspaceID = uuidCell(context.workspace_id);
      const issue = one(await unit.execute(statement(ISSUE_PROFESSIONAL_SESSION_SQL, [blob("access_token_hash", appBearerHash), timestamp("authoritative_time", now), blob("session_hash", sessionHash), uuid("workspace_id", workspaceID)])));
      const bootstrap = one(await unit.execute(statement(PROFESSIONAL_BOOTSTRAP_SQL, [text("credential_kind", "web_session"), blob("credential_hash", sessionHash), timestamp("authoritative_time", now)])));
      // `professional_session_bootstrap_v1` intentionally owns only billing
      // state. Resolve the current member through the new browser capability
      // in the same transaction instead of accepting a role claim from the
      // native bearer or widening the frozen bootstrap reducer.
      const members = await unit.execute(statement(MEMBERS_SQL, [text("credential_kind", "web_session"), blob("credential_hash", sessionHash), timestamp("authoritative_time", now), integer("limit", 100), nil("cursor")]));
      const current = members.rows.map(memberResponse).filter((member) => member.current);
      if (current.length !== 1 || current[0] === undefined) throw new PublicationCapabilityError("invalid_result");
      return Object.freeze({ expiresAt: timestampCell(issue.expires_at), bootstrap: bootstrapResponse(bootstrap, current[0]) });
    });
    return Object.freeze({ cookieSecret: secret, expiresAt: result.expiresAt, bootstrap: result.bootstrap });
  }

  async revokeProfessionalSession(credential: PublicationCredential): Promise<void> { if (credential.kind !== "web_session") throw new PublicationCapabilityError("forbidden"); const now = this.#now(); await this.#query(PROFESSIONAL_REVOKE_SQL, [blob("session_hash", credential.hash), timestamp("authoritative_time", now)]); }
  async listProperties(credential: PublicationCredential, page: Slice6PageRequest): Promise<readonly Readonly<Record<string, unknown>>[]> { return this.#list(PROPERTIES_SQL, credential, page, (row) => Object.freeze({ propertyID: idCell(row.property_public_id, "prop_"), title: stringCell(row.title, 180), version: positiveCell(row.curation_version), roomCount: nonNegativeCell(row.room_count), rooms: jsonCell(row.room_curation) })); }
  async listRoomCandidates(credential: PublicationCredential): Promise<readonly Readonly<Record<string, unknown>>[]> { return this.#list(ROOM_CANDIDATES_SQL, credential, { limit: 100 }, (row) => Object.freeze({ projectID: idCell(row.project_public_id, "prj_"), title: stringCell(row.title, 180) })); }
  async listConcepts(credential: PublicationCredential, input: Readonly<{ readonly projectID: string } & Slice6PageRequest>): Promise<readonly Readonly<Record<string, unknown>>[]> { const now = this.#now(); return this.#rows(CONCEPTS_SQL, [credentialKind(credential), blob("credential_hash", credential.hash), timestamp("authoritative_time", now), text("project_public_id", input.projectID), nullableInteger("limit", input.limit), nullableText("cursor", input.cursor)], (row) => Object.freeze({ snapshotID: idCell(row.snapshot_public_id, "snp_"), assetID: idCell(row.concept_asset_public_id, "ast_"), contentType: contentTypeCell(row.content_type), byteCount: positiveCell(row.asset_bytes), publishedAt: timestampCell(row.published_at) })); }
  async listMembers(credential: PublicationCredential, page: Slice6PageRequest): Promise<readonly Readonly<Record<string, unknown>>[]> { return this.#list(MEMBERS_SQL, credential, page, memberResponse); }
  async upsertProperty(credential: PublicationCredential, input: Slice6PropertyUpsertRequest): Promise<Readonly<Record<string, unknown>>> {
    const now = this.#now(); const expected = input.expectedVersion ?? 0;
    const rooms = input.rooms.map((room) => ({ publicRoomKey: room.roomKey, projectPublicID: room.projectID }));
    const createDigest = input.propertyID === undefined
      ? this.#hasher.hash("property-create-idempotency", propertyCreateIdentity(credential, input.createIdempotencyKey!))
      : undefined;
    const row = await this.#one(PROPERTY_UPSERT_SQL, [credentialKind(credential), blob("credential_hash", credential.hash), timestamp("authoritative_time", now), nullableText("property_public_id", input.propertyID), integer("expected_version", expected), nullableBlob("create_idempotency_digest", createDigest), text("title", input.title), json("rooms", rooms)]);
    return Object.freeze({ status: enumCell(row.status, ["created", "updated", "existing"]), propertyID: idCell(row.property_public_id, "prop_"), version: positiveCell(row.curation_version), roomCount: nonNegativeCell(row.room_count) });
  }
  async allocateSnapshot(credential: PublicationCredential, input: PublicationAllocationRequest): Promise<Readonly<Record<string, unknown>>> {
    const now = this.#now(); const result = await this.#run(async (unit) => Object.freeze({ row: one(await unit.execute(statement(ALLOCATE_SQL, allocationParameters(credential, now, input, this.#hasher)))) }));
    const allocationID = idCell(result.row.allocation_public_id, "pua_"); const status = enumCell(result.row.status, ["allocated", "existing"]); const response: Record<string, unknown> = { status, allocationID, allocationExpiresAt: timestampCell(result.row.allocation_expires_at) };
    // A retry of an existing allocation gets a fresh constrained upload grant;
    // it never changes its immutable source/selection/archive identity.
    const upload = await this.#storage.presignQuarantineUpload({ allocationPublicID: allocationID, byteCount: input.archiveByteCount, archiveSHA256: input.archiveSHA256 });
    response.upload = Object.freeze({ url: upload.url, headers: upload.headers }); return Object.freeze(response);
  }
  async completeSnapshot(credential: PublicationCredential, input: Slice6SnapshotCompletionRequest): Promise<Readonly<Record<string, unknown>>> {
    const now = this.#now(); const row = await this.#one(COMPLETE_SQL, [credentialKind(credential), blob("credential_hash", credential.hash), timestamp("authoritative_time", now), text("allocation_public_id", input.allocationID), digest("archive_digest", input.archiveSHA256), digest("archive_manifest_digest", input.archiveManifestSHA256), integer("archive_bytes", input.archiveByteCount)]);
    if (row.status !== "validation_pending" && row.status !== "existing") throw new PublicationCapabilityError("invalid_result");
    try { await this.#wake.notifyPublicationValidationWake(); } catch { /* durable pending state is targetless-tick recoverable */ }
    this.#record("publication.snapshot.complete", "accepted");
    return Object.freeze({ status: row.status, allocationID: idCell(row.allocation_public_id, "pua_") });
  }
  async snapshotStatus(credential: PublicationCredential, allocationID: string): Promise<Readonly<Record<string, unknown>> | undefined> { const now = this.#now(); const rows = await this.#query(ALLOCATION_STATUS_SQL, [credentialKind(credential), blob("credential_hash", credential.hash), timestamp("authoritative_time", now), text("allocation_public_id", allocationID)]); return rows.rows.length === 0 ? undefined : allocationResponse(one(rows)); }
  async listSnapshots(credential: PublicationCredential, page: Slice6PageRequest): Promise<readonly Readonly<Record<string, unknown>>[]> { return this.#list(ALLOCATIONS_SQL, credential, page, allocationResponse); }
  async createLink(credential: PublicationCredential, input: Slice6LinkCreateRequest): Promise<Readonly<Record<string, unknown>>> { const now = this.#now(); const token = this.#hasher.deriveSecret("portal-link-capability", linkCreateIdentity(credential, input)); const pinState = await pinParameters(input.pin); const row = await this.#one(CREATE_LINK_SQL, [credentialKind(credential), blob("credential_hash", credential.hash), timestamp("authoritative_time", now), text("snapshot_public_id", input.snapshotID), blob("token_hash", this.#hasher.hash("portal-link", token)), nullableTimestamp("expires_at", input.expiresAt), nullableBlob("pin_salt", pinState?.salt), nullableBlob("pin_verifier", pinState?.verifier), text("ai_policy", input.aiPolicy), text("feedback_policy", input.feedbackPolicy), blob("idempotency_digest", this.#hasher.hash("link-idempotency", input.idempotencyKey))]);
    const response: Record<string, unknown> = { status: enumCell(row.status, ["created", "existing"]), linkID: idCell(row.link_public_id, "lnk_"), generation: positiveCell(row.generation), expiresAt: timestampCell(row.expires_at), pinRequired: booleanCell(row.pin_required) };
    if (credential.browser) response.shareURL = shareURL(this.#portalOrigin, token); this.#record("publication.link.create", "accepted"); return Object.freeze(response);
  }
  async updateLink(credential: PublicationCredential, input: Slice6LinkUpdateRequest): Promise<Readonly<Record<string, unknown>>> { const now = this.#now(); const token = this.#hasher.secret(); const pinState = await pinParameters(input.pin); const expiry = input.expiresAt ?? new Date(now.getTime() + 30 * 24 * 60 * 60 * 1000).toISOString(); const row = await this.#one(UPDATE_LINK_SQL, [credentialKind(credential), blob("credential_hash", credential.hash), timestamp("authoritative_time", now), text("link_public_id", input.linkID), blob("token_hash", this.#hasher.hash("portal-link", token)), timestampText("expires_at", expiry), nullableBlob("pin_salt", pinState?.salt), nullableBlob("pin_verifier", pinState?.verifier), text("ai_policy", input.aiPolicy), text("feedback_policy", input.feedbackPolicy), integer("expected_generation", input.expectedGeneration)]); const response: Record<string, unknown> = { status: enumCell(row.status, ["updated"]), linkID: idCell(row.link_public_id, "lnk_"), generation: positiveCell(row.generation), expiresAt: timestampCell(row.expires_at) }; if (credential.browser) response.shareURL = shareURL(this.#portalOrigin, token); this.#record("publication.link.update", "accepted"); return Object.freeze(response); }
  async revokeLink(credential: PublicationCredential, input: Readonly<{ readonly linkID: string; readonly expectedGeneration: number }>): Promise<Readonly<Record<string, unknown>>> { const row = await this.#one(REVOKE_LINK_SQL, [credentialKind(credential), blob("credential_hash", credential.hash), timestamp("authoritative_time", this.#now()), text("link_public_id", input.linkID), integer("expected_generation", input.expectedGeneration)]); this.#record("publication.link.revoke", "accepted"); return Object.freeze({ status: enumCell(row.status, ["revoked", "already_revoked"]), linkID: idCell(row.link_public_id, "lnk_"), generation: positiveCell(row.generation) }); }
  async listLinks(credential: PublicationCredential, input: Readonly<{ readonly snapshotID?: string } & Slice6PageRequest>): Promise<readonly Readonly<Record<string, unknown>>[]> { const now = this.#now(); return this.#rows(LINKS_SQL, [credentialKind(credential), blob("credential_hash", credential.hash), timestamp("authoritative_time", now), nullableText("snapshot_public_id", input.snapshotID), nullableInteger("limit", input.limit), nullableText("cursor", input.cursor)], (row) => Object.freeze({ linkID: idCell(row.link_public_id, "lnk_"), snapshotID: idCell(row.snapshot_public_id, "snp_"), generation: positiveCell(row.generation), state: enumCell(row.state, ["active", "revoked"]), expiresAt: timestampCell(row.expires_at), pinRequired: booleanCell(row.pin_required), aiEnabled: booleanCell(row.ai_enabled), feedbackEnabled: booleanCell(row.feedback_enabled), feedbackCount: nonNegativeCell(row.feedback_count), feedbackCountCapped: booleanCell(row.feedback_count_capped), ...(row.latest_feedback_kind === null ? {} : { latestFeedbackAction: enumCell(row.latest_feedback_kind, ["comment", "approve", "request_changes"] as const) }), ...(row.latest_feedback_at === null ? {} : { latestFeedbackAt: timestampCell(row.latest_feedback_at) }) })); }
  async listFeedback(credential: PublicationCredential, input: Readonly<{ readonly linkID?: string; readonly snapshotID?: string } & Slice6PageRequest>): Promise<readonly Readonly<Record<string, unknown>>[]> { const now = this.#now(); return this.#rows(FEEDBACK_LIST_SQL, [credentialKind(credential), blob("credential_hash", credential.hash), timestamp("authoritative_time", now), nullableText("link_public_id", input.linkID), nullableText("snapshot_public_id", input.snapshotID), nullableInteger("limit", input.limit), nullableText("cursor", input.cursor)], (row) => Object.freeze({ feedbackID: boundedString(row.feedback_reference, 80), linkID: idCell(row.link_public_id, "lnk_"), snapshotID: idCell(row.snapshot_public_id, "snp_"), action: enumCell(row.feedback_kind, ["comment", "approve", "request_changes"]), comment: nullableBoundedString(row.comment, 4_000), displayName: boundedString(row.display_label, 120), occurredAt: timestampCell(row.occurred_at) })); }
  async listAccessHistory(credential: PublicationCredential, input: Readonly<{ readonly linkID?: string } & Slice6PageRequest>): Promise<readonly Readonly<Record<string, unknown>>[]> { const now = this.#now(); return this.#rows(ACCESS_HISTORY_SQL, [credentialKind(credential), blob("credential_hash", credential.hash), timestamp("authoritative_time", now), nullableText("link_public_id", input.linkID), nullableInteger("limit", input.limit), nullableText("cursor", input.cursor)], (row) => Object.freeze({ eventID: boundedString(row.event_reference, 80), linkID: idCell(row.link_public_id, "lnk_"), snapshotID: idCell(row.snapshot_public_id, "snp_"), action: boundedString(row.action, 32), outcome: boundedString(row.outcome, 32), occurredHour: timestampCell(row.occurred_hour), clientFamily: enumCell(row.client_family, ["desktop", "mobile", "tablet", "unknown"]) })); }
  async listDownloads(credential: PublicationCredential, snapshotID: string): Promise<readonly Readonly<Record<string, unknown>>[]> { const now = this.#now(); return this.#rows(DOWNLOADS_SQL, [credentialKind(credential), blob("credential_hash", credential.hash), timestamp("authoritative_time", now), text("snapshot_public_id", snapshotID), integer("limit", 100), nil("cursor")], (row) => Object.freeze({ snapshotID: idCell(row.snapshot_public_id, "snp_"), assetID: idCell(row.asset_public_id, "ast_"), kind: enumCell(row.download_kind, ["floor_plan_pdf", "gallery_zip", "ai_ready_package"]), contentType: contentTypeCell(row.content_type), byteCount: positiveCell(row.asset_bytes) })); }
  async exchangePortalLink(linkTokenHash: Uint8Array, clientFamily: "desktop" | "mobile" | "tablet" | "unknown", networkRiskDigest: Uint8Array): Promise<Readonly<{ readonly status: "active" | "pin_required" | "unavailable" | "killed"; readonly cookieSecret?: string }>> { requireHash(linkTokenHash); requireHash(networkRiskDigest); const secret = this.#hasher.secret(); const row = await this.#one(PORTAL_EXCHANGE_SQL, [blob("token_hash", linkTokenHash), timestamp("authoritative_time", this.#now()), blob("session_hash", this.#hasher.hash("portal-session", secret)), text("client_family", clientFamily), blob("network_risk_digest", networkRiskDigest)]); const status = enumCell(row.status, ["active", "pin_required", "unavailable", "killed"] as const); this.#record("publication.portal.exchange", status === "active" || status === "pin_required" ? "accepted" : "rejected"); return Object.freeze({ status, ...((status === "active" || status === "pin_required") ? { cookieSecret: secret } : {}) }); }
  async verifyPortalPIN(session: PortalSessionCredential, pin: string): Promise<Readonly<{ readonly status: "verified" | "denied" | "cooldown" | "unavailable" }>> { requireHash(session.hash); const now = this.#now(); const parameters = await this.#query(PIN_PARAMETERS_SQL, [blob("session_hash", session.hash), timestamp("authoritative_time", now)]); if (parameters.rows.length === 0) { this.#record("publication.portal.pin", "unavailable"); return Object.freeze({ status: "unavailable" as const }); } const param = one(parameters); const salt = bytesCell(param.pin_salt, 16, 64); const N = positiveCell(param.scrypt_n); const r = positiveCell(param.scrypt_r); const p = positiveCell(param.scrypt_p); const keyLength = positiveCell(param.key_length); if (N !== 16_384 || r !== 8 || p !== 1 || keyLength !== 32) throw new PublicationCapabilityError("invalid_result"); const verifier = await scryptPIN(pin, salt); const row = await this.#one(PIN_VERIFY_SQL, [blob("session_hash", session.hash), timestamp("authoritative_time", now), blob("pin_verifier", verifier)]); const status = enumCell(row.status, ["verified", "denied", "cooldown", "unavailable"] as const); this.#record("publication.portal.pin", status === "verified" ? "accepted" : status === "unavailable" ? "unavailable" : "rejected"); return Object.freeze({ status }); }
  async portalSnapshot(session: PortalSessionCredential): Promise<Readonly<Record<string, unknown>>> {
    requireHash(session.hash);
    const now = this.#now();
    const snapshot = await this.#one(PORTAL_SNAPSHOT_SQL, [blob("session_hash", session.hash), timestamp("authoritative_time", now)]);
    // The kind is a single immutable DB fact. Room snapshots never touch the
    // property curation reducer: their deliberately empty list is an explicit
    // public statement that no cross-room relationship is being asserted.
    const kind = enumCell(snapshot.publication_kind, ["room", "property"] as const);
    const presentation = await this.#one(PORTAL_PRESENTATION_SQL, [blob("session_hash", session.hash), timestamp("authoritative_time", now)]);
    const rooms = kind === "property"
      ? await this.#query(PORTAL_ROOMS_SQL, [blob("session_hash", session.hash), timestamp("authoritative_time", now)])
      : undefined;
    this.#record("publication.portal.snapshot", "accepted");
    return Object.freeze({
      snapshotID: idCell(snapshot.snapshot_public_id, "snp_"),
      kind,
      presentation: Object.freeze({
        assetID: idCell(presentation.asset_public_id, "ast_"),
        contentType: contentTypeCell(presentation.content_type),
        byteCount: positiveCell(presentation.asset_bytes),
      }),
      rooms: Object.freeze(rooms?.rows.map((row) => Object.freeze({
        roomKey: boundedString(row.room_key, 128),
        roomOrder: positiveCell(row.room_order),
      })) ?? []),
      feedbackEnabled: booleanCell(snapshot.feedback_enabled),
      aiReadyPackageEnabled: booleanCell(snapshot.ai_enabled),
    });
  }
  async deliverPortalAsset(session: PortalSessionCredential, input: Slice6PortalAssetRequest): Promise<PublicationPortalAssetDelivery> {
    requireHash(session.hash);
    const now = this.#now();
    const requestDigest = this.#hasher.hash("portal-request", input.requestID);
    const authorization = input.assetID === undefined
      ? await this.#one(PORTAL_DOWNLOAD_AUTHORIZE_SQL, [
        blob("session_hash", session.hash), timestamp("authoritative_time", now), text("download_kind", input.downloadKind!),
        blob("request_digest", requestDigest), integer("byte_offset", input.offset), integer("byte_length", input.byteCount),
      ])
      : await this.#one(PORTAL_ASSET_AUTHORIZE_SQL, [
        blob("session_hash", session.hash), timestamp("authoritative_time", now), text("asset_public_id", input.assetID),
        blob("request_digest", requestDigest), integer("byte_offset", input.offset), integer("byte_length", input.byteCount),
      ]);
    const prepared = deliveryBinding(authorization);
    const bytes = await this.#storage.readAuthorizedActiveRange({
      objectKey: prepared.objectKey,
      objectVersion: prepared.objectVersion,
      offset: prepared.offset,
      byteCount: prepared.byteCount,
    });
    // The second reducer is deliberately after the exact versioned read.
    // It rechecks revocation, expiry, flag state, range identity, and quota
    // accounting while the bytes remain private in this stack frame.
    const finalized = await this.#one(PORTAL_ASSET_FINALIZE_SQL, [
      blob("session_hash", session.hash), timestamp("authoritative_time", this.#now()), text("asset_public_id", prepared.assetID),
      blob("request_digest", requestDigest), integer("byte_offset", prepared.offset), integer("byte_length", prepared.byteCount),
      text("object_version", prepared.objectVersion),
    ]);
    const final = deliveryBinding(finalized);
    if (final.assetID !== prepared.assetID || final.objectVersion !== prepared.objectVersion || final.offset !== prepared.offset || final.byteCount !== prepared.byteCount) throw new PublicationCapabilityError("invalid_result");
    this.#record("publication.portal.asset", "delivered", bytes.byteLength);
    return Object.freeze({
      bytes,
      contentType: prepared.contentType,
      attachment: prepared.contentType === "application/pdf" || prepared.contentType === "application/zip",
      range: Object.freeze({ offset: prepared.offset, byteCount: prepared.byteCount, totalBytes: prepared.totalBytes }),
    });
  }
  /** This is deliberately distinct from the portal-link path: only the
   * PortalDelivery runtime can compose it, and only a professional cookie is
   * accepted by its corresponding DB reducers. */
  async deliverProfessionalAsset(credential: PublicationCredential, input: Readonly<{ readonly assetID: string; readonly offset: number; readonly byteCount: number; readonly requestID: string }>): Promise<PublicationPortalAssetDelivery> {
    if (credential.kind !== "web_session" || credential.browser !== true) throw new PublicationCapabilityError("forbidden");
    requireHash(credential.hash);
    const request = professionalAssetRequest(input);
    const requestDigest = this.#hasher.hash("professional-asset-request", professionalAssetRequestIdentity(credential, request.requestID));
    const prepared = deliveryBinding(await this.#one(PROFESSIONAL_ASSET_AUTHORIZE_SQL, [
      blob("session_hash", credential.hash), timestamp("authoritative_time", this.#now()), text("asset_public_id", request.assetID),
      blob("request_digest", requestDigest), integer("byte_offset", request.offset), integer("byte_length", request.byteCount),
    ]));
    const bytes = await this.#storage.readAuthorizedActiveRange({
      objectKey: prepared.objectKey,
      objectVersion: prepared.objectVersion,
      offset: prepared.offset,
      byteCount: prepared.byteCount,
    });
    const finalized = deliveryBinding(await this.#one(PROFESSIONAL_ASSET_FINALIZE_SQL, [
      blob("session_hash", credential.hash), timestamp("authoritative_time", this.#now()), text("asset_public_id", prepared.assetID),
      blob("request_digest", requestDigest), integer("byte_offset", prepared.offset), integer("byte_length", prepared.byteCount),
      text("object_version", prepared.objectVersion),
    ]));
    if (finalized.assetID !== prepared.assetID || finalized.objectVersion !== prepared.objectVersion
      || finalized.offset !== prepared.offset || finalized.byteCount !== prepared.byteCount
      || finalized.totalBytes !== prepared.totalBytes || finalized.contentType !== prepared.contentType) {
      throw new PublicationCapabilityError("invalid_result");
    }
    return Object.freeze({
      bytes,
      contentType: prepared.contentType,
      attachment: prepared.contentType === "application/pdf" || prepared.contentType === "application/zip",
      range: Object.freeze({ offset: prepared.offset, byteCount: prepared.byteCount, totalBytes: prepared.totalBytes }),
    });
  }
  async requestFeedbackVerification(session: PortalSessionCredential, input: Slice6FeedbackVerificationRequest): Promise<void> {
    requireHash(session.hash);
    if (input === null || typeof input !== "object" || typeof input.email !== "string" || typeof input.requestID !== "string") throw new PublicationCapabilityError("invalid_input");
    const now = this.#now();
    const challenge = this.#hasher.secret();
    const token = this.#hasher.secret();
    let envelope: ReturnType<PublicationFeedbackEnvelopeSealer["seal"]>;
    try {
      envelope = this.#feedbackEnvelopeSealer.seal(Object.freeze({ email: input.email, verificationCode: `${challenge}.${token}` }));
    } catch (error) {
      if (error instanceof PublicationFeedbackEnvelopeError && error.code === "invalid_input") throw new PublicationCapabilityError("invalid_input");
      throw new PublicationCapabilityError("unavailable");
    }
    const row = await this.#one(FEEDBACK_REQUEST_V3_SQL, [
      blob("session_hash", session.hash), timestamp("authoritative_time", now),
      blob("challenge_hash", this.#hasher.hash("feedback-challenge", challenge)),
      blob("verification_token_hash", this.#hasher.hash("feedback-token", token)),
      blob("verified_email_digest", this.#hasher.hash("verified-email", input.email)),
      text("key_id", envelope.keyID), blob("iv", envelope.iv), feedbackCiphertext("ciphertext", envelope.ciphertext),
      blob("authentication_tag", envelope.authenticationTag), blob("feedback_request_digest", this.#hasher.hash("feedback-request", input.requestID)),
    ]);
    const status = enumCell(row.status, ["issued", "existing", "cooldown"] as const);
    if (status === "issued" || status === "existing") {
      if (row.challenge_id === null || row.expires_at === null || row.retry_after !== null) throw new PublicationCapabilityError("invalid_result");
      uuidCell(row.challenge_id);
      timestampCell(row.expires_at);
    } else if (row.challenge_id !== null || row.expires_at !== null || row.retry_after === null) {
      throw new PublicationCapabilityError("invalid_result");
    } else {
      timestampCell(row.retry_after);
    }
    try { await this.#feedbackWake.notifyFeedbackDeliveryWake(); } catch { /* the committed targetless outbox is recovered by the email lane tick */ }
  }
  async consumeFeedbackVerification(session: PortalSessionCredential, verificationCode: string): Promise<Readonly<{ readonly feedbackCookieSecret?: string }>> { requireHash(session.hash); const [challenge, token] = parseVerificationCode(verificationCode); const row = await this.#one(FEEDBACK_CONSUME_SQL, [blob("session_hash", session.hash), blob("challenge_hash", this.#hasher.hash("feedback-challenge", challenge)), timestamp("authoritative_time", this.#now()), blob("verification_token_hash", this.#hasher.hash("feedback-token", token))]); return Object.freeze({ ...(row.status === "verified" ? { feedbackCookieSecret: token } : {}) }); }
  async createFeedback(credential: FeedbackCredential, input: Readonly<{ readonly action: "comment" | "approve" | "request_changes"; readonly comment?: string; readonly requestID: string }>): Promise<Readonly<Record<string, unknown>>> { const result = await this.#feedback().create(credential, input); this.#record("publication.feedback.create", "accepted"); return result; }

  #feedback(): PublicationFeedbackCapabilityRepository { return new PublicationFeedbackCapabilityRepository({ query: async (sql, parameters) => this.#query(sql, parameters), now: () => this.#now(), hasher: this.#hasher }); }
  async #list(sql: string, credential: PublicationCredential, page: Slice6PageRequest, mapper: (row: Readonly<Record<string, SqlCell>>) => Readonly<Record<string, unknown>>): Promise<readonly Readonly<Record<string, unknown>>[]> { return this.#rows(sql, [credentialKind(credential), blob("credential_hash", credential.hash), timestamp("authoritative_time", this.#now()), nullableInteger("limit", page.limit), nullableText("cursor", page.cursor)], mapper); }
  async #one(sql: string, parameters: SqlStatement["parameters"]): Promise<Readonly<Record<string, SqlCell>>> { return one(await this.#query(sql, parameters)); }
  async #rows(sql: string, parameters: SqlStatement["parameters"], mapper: (row: Readonly<Record<string, SqlCell>>) => Readonly<Record<string, unknown>>): Promise<readonly Readonly<Record<string, unknown>>[]> { const result = await this.#query(sql, parameters); return Object.freeze(result.rows.map(mapper)); }
  async #query(sql: string, parameters: SqlStatement["parameters"]): Promise<SqlResult> { return this.#run((unit) => unit.execute(statement(sql, parameters))); }
  async #run<T>(work: (unit: CapabilitySqlUnit) => Promise<T>): Promise<T> { try { return await this.#transactions.run(work); } catch (error) { if (error instanceof PublicationCapabilityError) throw error; throw new PublicationCapabilityError("unavailable"); } }
  #now(): Date { const now = this.#clock.now(); if (!(now instanceof Date) || !Number.isFinite(now.getTime())) throw new PublicationCapabilityError("unavailable"); return new Date(now.getTime()); }
  #record(action: PublicationAuditAction, result: PublicationAuditResult, bytes?: number): void { try { this.#audit?.record(Object.freeze({ action, result, ...(bytes === undefined ? {} : { bytes }) })); } catch { /* telemetry is never permitted to echo or block protected bytes */ } }
}

/** This repository deliberately receives only a small query closure. It has
 * no project, revision, concept, membership, or arbitrary Data API mutation
 * capability, making a feedback route unable to invoke project truth paths by
 * construction as well as by database grants. */
export class PublicationFeedbackCapabilityRepository {
  readonly #query: (sql: string, parameters: SqlStatement["parameters"]) => Promise<SqlResult>;
  readonly #now: () => Date;
  readonly #hasher: PublicationSecretHasher;
  constructor(input: { readonly query: (sql: string, parameters: SqlStatement["parameters"]) => Promise<SqlResult>; readonly now: () => Date; readonly hasher: PublicationSecretHasher }) { if (input === null || typeof input !== "object" || typeof input.query !== "function" || typeof input.now !== "function" || !(input.hasher instanceof PublicationSecretHasher)) throw new PublicationCapabilityError("invalid_input"); this.#query = input.query; this.#now = input.now; this.#hasher = input.hasher; }
  async create(credential: FeedbackCredential, input: Readonly<{ readonly action: "comment" | "approve" | "request_changes"; readonly comment?: string; readonly requestID: string }>): Promise<Readonly<Record<string, unknown>>> { requireHash(credential.portalSessionHash); requireHash(credential.feedbackTokenHash); const result = await this.#query(FEEDBACK_CREATE_SQL, [blob("session_hash", credential.portalSessionHash), timestamp("authoritative_time", this.#now()), blob("verification_token_hash", credential.feedbackTokenHash), text("feedback_kind", input.action), nullableText("comment", input.comment), blob("request_digest", this.#hasher.hash("feedback-request", input.requestID))]); const row = one(result); return Object.freeze({ status: enumCell(row.status, ["recorded"]), feedbackID: uuidCell(row.feedback_id), displayName: boundedString(row.display_label, 120) }); }
}

function allocationParameters(credential: PublicationCredential, now: Date, input: PublicationAllocationRequest, hasher: PublicationSecretHasher): SqlStatement["parameters"] { return [credentialKind(credential), blob("credential_hash", credential.hash), timestamp("authoritative_time", now), text("project_public_id", input.projectID), text("source_revision_public_id", input.sourceRevisionID), digest("source_revision_digest", input.sourceRevisionDigest), digest("source_manifest_digest", input.sourceManifestDigest), digest("selection_digest", input.selectionManifestSHA256), digest("approval_digest", input.approvalSHA256), text("disclosure_status", input.disclosureStatus), text("publication_kind", input.publicationKind), nullableText("property_public_id", input.propertyID), json("source_bindings", input.sourceBindings), digest("source_bindings_digest", input.sourceBindingsSHA256), digest("archive_manifest_digest", input.archiveManifestSHA256), digest("archive_digest", input.archiveSHA256), integer("archive_bytes", input.archiveByteCount), blob("idempotency_digest", hasher.hash("publication-allocation-idempotency", allocationCreateIdentity(credential, input)))]; }
function allocationCreateIdentity(credential: PublicationCredential, input: PublicationAllocationRequest): string {
  requireHash(credential.hash);
  return `${credential.kind}\u0000${Buffer.from(credential.hash).toString("base64url")}\u0000${input.projectID}\u0000${input.idempotencyKey}`;
}
function propertyCreateIdentity(credential: PublicationCredential, idempotencyKey: string): string {
  requireHash(credential.hash);
  if (typeof idempotencyKey !== "string" || idempotencyKey.length < 16 || idempotencyKey.length > 128) throw new PublicationCapabilityError("invalid_input");
  return `${credential.kind}\u0000${Buffer.from(credential.hash).toString("base64url")}\u0000${idempotencyKey}`;
}
function linkCreateIdentity(credential: PublicationCredential, input: Slice6LinkCreateRequest): string {
  requireHash(credential.hash);
  return `${credential.kind}\u0000${Buffer.from(credential.hash).toString("base64url")}\u0000${input.snapshotID}\u0000${input.idempotencyKey}`;
}
function professionalAssetRequestIdentity(credential: PublicationCredential, requestID: string): string {
  requireHash(credential.hash);
  if (credential.kind !== "web_session" || credential.browser !== true || typeof requestID !== "string" || !/^[A-Za-z0-9._~-]{16,128}$/u.test(requestID)) throw new PublicationCapabilityError("invalid_input");
  return `${credential.kind}\u0000${Buffer.from(credential.hash).toString("base64url")}\u0000${requestID}`;
}
async function pinParameters(value: string | undefined): Promise<Readonly<{ readonly salt: Uint8Array; readonly verifier: Uint8Array }> | undefined> { if (value === undefined) return undefined; const salt = randomBytes(16); return Object.freeze({ salt, verifier: await scryptPIN(value, salt) }); }
async function scryptPIN(pin: string, salt: Uint8Array): Promise<Uint8Array> { if (!/^[0-9]{6}$/u.test(pin) || !(salt instanceof Uint8Array) || salt.byteLength < 16 || salt.byteLength > 64) throw new PublicationCapabilityError("invalid_input"); try { return Uint8Array.from(await new Promise<Buffer>((resolve, reject) => nodeScrypt(pin, salt, 32, { N: 16_384, r: 8, p: 1, maxmem: 64 * 1024 * 1024 }, (error, key) => error === null ? resolve(key) : reject(error)))); } catch { throw new PublicationCapabilityError("unavailable"); } }
function parseVerificationCode(value: string): readonly [string, string] { const match = /^([A-Za-z0-9_-]{43})\.([A-Za-z0-9_-]{43})$/u.exec(value); if (match?.[1] === undefined || match[2] === undefined) throw new PublicationCapabilityError("invalid_input"); return [match[1], match[2]]; }
function shareURL(origin: string, secret: string): string { return `${origin}/p#${secret}`; }
function validPortalOrigin(value: string): boolean { try { const parsed = new URL(value); return parsed.protocol === "https:" && parsed.pathname === "/" && !parsed.username && !parsed.password && parsed.search === "" && parsed.hash === ""; } catch { return false; } }
function deliveryBinding(row: Readonly<Record<string, SqlCell>>): Readonly<{ readonly assetID: string; readonly objectKey: string; readonly objectVersion: string; readonly contentType: "application/json" | "image/png" | "image/jpeg" | "application/pdf" | "application/zip"; readonly totalBytes: number; readonly offset: number; readonly byteCount: number }> { return Object.freeze({ assetID: idCell(row.asset_public_id, "ast_"), objectKey: objectKeyCell(row.object_key), objectVersion: boundedString(row.object_version, 1_024), contentType: contentTypeCell(row.content_type), totalBytes: positiveCell(row.asset_bytes), offset: nonNegativeCell(row.byte_offset), byteCount: positiveCell(row.byte_length) }); }
function professionalAssetRequest(value: unknown): Readonly<{ readonly assetID: string; readonly offset: number; readonly byteCount: number; readonly requestID: string }> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new PublicationCapabilityError("invalid_input");
  const input = value as Record<string, unknown>;
  const offset = input.offset;
  const byteCount = input.byteCount;
  if (typeof input.assetID !== "string" || !/^ast_[A-Za-z0-9_-]{16,128}$/u.test(input.assetID)
    || typeof offset !== "number" || !Number.isSafeInteger(offset) || offset < 0 || offset > 805_306_368
    || typeof byteCount !== "number" || !Number.isSafeInteger(byteCount) || byteCount < 1 || byteCount > 4_194_304
    || typeof input.requestID !== "string" || !/^[A-Za-z0-9._~-]{16,128}$/u.test(input.requestID)) {
    throw new PublicationCapabilityError("invalid_input");
  }
  return Object.freeze({ assetID: input.assetID, offset, byteCount, requestID: input.requestID });
}
function allocationResponse(row: Readonly<Record<string, SqlCell>>): Readonly<Record<string, unknown>> { return Object.freeze({ allocationID: idCell(row.allocation_public_id, "pua_"), status: enumCell(row.allocation_state, ["allocated", "validation_pending", "validating", "published", "rejected"]), kind: enumCell(row.publication_kind, ["room", "property"]), projectID: idCell(row.project_public_id, "prj_"), sourceRevisionID: idCell(row.source_revision_public_id, "rev_"), ...(row.property_public_id === null ? {} : { propertyID: idCell(row.property_public_id, "prop_") }), ...(row.snapshot_public_id === null ? {} : { snapshotID: idCell(row.snapshot_public_id, "snp_") }), ...(row.rejection_code === null ? {} : { rejectionCode: boundedString(row.rejection_code, 64) }), createdAt: timestampCell(row.created_at), updatedAt: timestampCell(row.updated_at), expiresAt: timestampCell(row.expires_at) }); }
/** Membership display values are deliberately pseudonymous. The database
 * exposes `mem_...` references, never email, legal name, or raw principal ID;
 * rendering that bounded reference also fulfils the web's role-management
 * affordance without creating an identity disclosure path. */
function memberResponse(row: Readonly<Record<string, SqlCell>>): Readonly<{ readonly memberID: string; readonly displayName: string; readonly role: "owner" | "admin" | "editor" | "viewer"; readonly state: "active" | "invited" | "suspended"; readonly current: boolean }> {
  const memberID = boundedString(row.member_reference, 80);
  return Object.freeze({ memberID, displayName: memberID, role: enumCell(row.role, ["owner", "admin", "editor", "viewer"] as const), state: enumCell(row.state, ["active", "invited", "suspended"] as const), current: booleanCell(row.is_current_principal) });
}
function bootstrapResponse(row: Readonly<Record<string, SqlCell>>, membership: Readonly<{ readonly memberID: string; readonly displayName: string; readonly role: "owner" | "admin" | "editor" | "viewer"; readonly state: "active" | "invited" | "suspended"; readonly current: boolean }>): Readonly<Record<string, unknown>> { return Object.freeze({ membership: Object.freeze({ memberID: membership.memberID, displayName: membership.displayName, role: membership.role, state: membership.state }), subscription: Object.freeze({ plan: boundedString(row.plan_key, 80), status: boundedString(row.subscription_status, 80), currentPeriodEnd: nullableTimestampCell(row.current_period_end) }), quota: Object.freeze({ policyVersion: positiveCell(row.quota_policy_version), portalPeriod: boundedString(row.portal_period_key, 128), used: nonNegativeCell(row.portal_bytes_used), reserved: nonNegativeCell(row.portal_bytes_reserved), limit: nonNegativeCell(row.portal_bytes_limit) }) }); }
function statement(sql: string, parameters: SqlStatement["parameters"]): SqlStatement { return parameters === undefined ? { sql } : { sql, parameters }; }
function one(result: SqlResult): Readonly<Record<string, SqlCell>> { if (result.rows.length !== 1 || result.rows[0] === undefined) throw new PublicationCapabilityError("invalid_result"); return result.rows[0]; }
function requireHash(value: Uint8Array): void { if (!(value instanceof Uint8Array) || value.byteLength !== 32) throw new PublicationCapabilityError("invalid_input"); }
function credentialKind(value: PublicationCredential) { requireHash(value.hash); if (value.kind !== "app_bearer" && value.kind !== "web_session") throw new PublicationCapabilityError("invalid_input"); return text("credential_kind", value.kind); }
function blob(name: string, value: Uint8Array) { requireHashOrBytes(value); return { name, value: { kind: "blob" as const, bytes: Uint8Array.from(value) } }; }
function requireHashOrBytes(value: Uint8Array): void { if (!(value instanceof Uint8Array) || value.byteLength < 1 || value.byteLength > 64) throw new PublicationCapabilityError("invalid_input"); }
/** v3 feedback ciphertext is an intentionally separate transport class. The
 * generic `blob` helper stays narrow for hashes, salts, and tags. */
function feedbackCiphertext(name: string, value: Uint8Array) { if (!(value instanceof Uint8Array) || value.byteLength < 1 || value.byteLength > 4_096) throw new PublicationCapabilityError("invalid_input"); return { name, value: { kind: "blob" as const, bytes: Uint8Array.from(value) } }; }
function text(name: string, value: string) { return { name, value: { kind: "string" as const, value } }; }
function uuid(name: string, value: string) { return { name, value: { kind: "string" as const, value, typeHint: "UUID" as const } }; }
function integer(name: string, value: number) { if (!Number.isSafeInteger(value)) throw new PublicationCapabilityError("invalid_input"); return { name, value: { kind: "long" as const, value } }; }
function timestamp(name: string, value: Date) { return { name, value: { kind: "string" as const, value: value.toISOString() } }; }
function timestampText(name: string, value: string) { if (!Number.isSafeInteger(Date.parse(value))) throw new PublicationCapabilityError("invalid_input"); return text(name, value); }
function digest(name: string, value: string) { if (!/^[a-f0-9]{64}$/u.test(value)) throw new PublicationCapabilityError("invalid_input"); return blob(name, Buffer.from(value, "hex")); }
function json(name: string, value: unknown) { return text(name, canonicalJson(value)); }
function nil(name: string) { return { name, value: { kind: "null" as const } }; }
function nullableText(name: string, value: string | undefined) { return value === undefined ? nil(name) : text(name, value); }
function nullableInteger(name: string, value: number | undefined) { return value === undefined ? nil(name) : integer(name, value); }
function nullableTimestamp(name: string, value: string | undefined) { return value === undefined ? nil(name) : timestampText(name, value); }
function nullableBlob(name: string, value: Uint8Array | undefined) { return value === undefined ? nil(name) : blob(name, value); }
function uuidCell(value: SqlCell | undefined): string { if (typeof value !== "string" || !UUID.test(value)) throw new PublicationCapabilityError("invalid_result"); return value; }
function idCell(value: SqlCell | undefined, prefix: string): string { if (typeof value !== "string" || !new RegExp(`^${prefix}[A-Za-z0-9_-]{16,128}$`, "u").test(value)) throw new PublicationCapabilityError("invalid_result"); return value; }
function stringCell(value: SqlCell | undefined, maximum: number): string { if (typeof value !== "string" || value.length < 1 || value.length > maximum) throw new PublicationCapabilityError("invalid_result"); return value; }
function boundedString(value: SqlCell | undefined, maximum: number): string { return stringCell(value, maximum); }
function nullableBoundedString(value: SqlCell | undefined, maximum: number): string | undefined { return value === null ? undefined : boundedString(value, maximum); }
function timestampCell(value: SqlCell | undefined): string { if (typeof value !== "string" || !Number.isSafeInteger(Date.parse(value))) throw new PublicationCapabilityError("invalid_result"); return value; }
function nullableTimestampCell(value: SqlCell | undefined): string | undefined { return value === null ? undefined : timestampCell(value); }
function positiveCell(value: SqlCell | undefined): number { if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 1) throw new PublicationCapabilityError("invalid_result"); return value; }
function nonNegativeCell(value: SqlCell | undefined): number { if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) throw new PublicationCapabilityError("invalid_result"); return value; }
function booleanCell(value: SqlCell | undefined): boolean { if (typeof value !== "boolean") throw new PublicationCapabilityError("invalid_result"); return value; }
function bytesCell(value: SqlCell | undefined, minimum: number, maximum: number): Uint8Array { if (!(value instanceof Uint8Array) || value.byteLength < minimum || value.byteLength > maximum) throw new PublicationCapabilityError("invalid_result"); return Uint8Array.from(value); }
function jsonCell(value: SqlCell | undefined): unknown { if (typeof value !== "string") throw new PublicationCapabilityError("invalid_result"); try { return JSON.parse(value); } catch { throw new PublicationCapabilityError("invalid_result"); } }
function enumCell<T extends readonly string[]>(value: SqlCell | undefined, allowed: T): T[number] { if (typeof value !== "string" || !allowed.includes(value)) throw new PublicationCapabilityError("invalid_result"); return value as T[number]; }
function contentTypeCell(value: SqlCell | undefined): "application/json" | "image/png" | "image/jpeg" | "application/pdf" | "application/zip" { return enumCell(value, ["application/json", "image/png", "image/jpeg", "application/pdf", "application/zip"] as const); }
function objectKeyCell(value: SqlCell | undefined): string { if (typeof value !== "string" || !/^server\/published\/active\/v1\/pua_[A-Za-z0-9_-]{16,128}\/ast_[A-Za-z0-9_-]{16,128}\.bin$/u.test(value)) throw new PublicationCapabilityError("invalid_result"); return value; }

const RESOLVE_APP_WORKSPACE_SQL = "SELECT workspace_id FROM roomscan.resolve_access_context(:access_token_hash, (:authoritative_time)::timestamptz)";
const ISSUE_PROFESSIONAL_SESSION_SQL = "SELECT * FROM roomscan.professional_session_issue_v1(:access_token_hash, (:authoritative_time)::timestamptz, :session_hash, (:workspace_id)::uuid)";
const PROFESSIONAL_REVOKE_SQL = "SELECT roomscan.professional_session_revoke_v1(:session_hash, (:authoritative_time)::timestamptz)";
const PROFESSIONAL_BOOTSTRAP_SQL = "SELECT * FROM roomscan.professional_session_bootstrap_v1(:credential_kind, :credential_hash, (:authoritative_time)::timestamptz)";
const PROPERTIES_SQL = "SELECT * FROM roomscan.professional_list_properties_v1(:credential_kind, :credential_hash, (:authoritative_time)::timestamptz, :limit, :cursor)";
const ROOM_CANDIDATES_SQL = "SELECT * FROM roomscan.publication_list_room_candidates_v1(:credential_kind, :credential_hash, (:authoritative_time)::timestamptz, :limit, :cursor)";
const PROPERTY_UPSERT_SQL = "SELECT * FROM roomscan.publication_upsert_property_v2(:credential_kind, :credential_hash, (:authoritative_time)::timestamptz, :property_public_id, :expected_version, :create_idempotency_digest, :title, (:rooms)::jsonb)";
const CONCEPTS_SQL = "SELECT * FROM roomscan.professional_list_concepts_v1(:credential_kind, :credential_hash, (:authoritative_time)::timestamptz, :project_public_id, :limit, :cursor)";
const MEMBERS_SQL = "SELECT * FROM roomscan.professional_list_members_v1(:credential_kind, :credential_hash, (:authoritative_time)::timestamptz, :limit, :cursor)";
const PUBLICATION_ACCESS_SQL = "SELECT * FROM roomscan.publication_resolve_api_access_v1(:credential_kind, :credential_hash, (:authoritative_time)::timestamptz, (:workspace_id)::uuid, :action)";
const ALLOCATE_SQL = "SELECT * FROM roomscan.publication_allocate_v1(:credential_kind, :credential_hash, (:authoritative_time)::timestamptz, :project_public_id, :source_revision_public_id, :source_revision_digest, :source_manifest_digest, :selection_digest, :approval_digest, :disclosure_status, :publication_kind, :property_public_id, (:source_bindings)::jsonb, :source_bindings_digest, :archive_manifest_digest, :archive_digest, :archive_bytes, :idempotency_digest)";
const COMPLETE_SQL = "SELECT * FROM roomscan.publication_complete_v2(:credential_kind, :credential_hash, (:authoritative_time)::timestamptz, :allocation_public_id, :archive_digest, :archive_manifest_digest, :archive_bytes)";
const ALLOCATION_STATUS_SQL = "SELECT * FROM roomscan.publication_allocation_status_v1(:credential_kind, :credential_hash, (:authoritative_time)::timestamptz, :allocation_public_id)";
const ALLOCATIONS_SQL = "SELECT * FROM roomscan.publication_list_allocations_v1(:credential_kind, :credential_hash, (:authoritative_time)::timestamptz, :limit, :cursor)";
const CREATE_LINK_SQL = "SELECT * FROM roomscan.publication_create_link_v1(:credential_kind, :credential_hash, (:authoritative_time)::timestamptz, :snapshot_public_id, :token_hash, (:expires_at)::timestamptz, :pin_salt, :pin_verifier, :ai_policy, :feedback_policy, :idempotency_digest)";
const UPDATE_LINK_SQL = "SELECT * FROM roomscan.publication_update_link_v1(:credential_kind, :credential_hash, (:authoritative_time)::timestamptz, :link_public_id, :token_hash, (:expires_at)::timestamptz, :pin_salt, :pin_verifier, :ai_policy, :feedback_policy, :expected_generation)";
const REVOKE_LINK_SQL = "SELECT * FROM roomscan.publication_revoke_link_v1(:credential_kind, :credential_hash, (:authoritative_time)::timestamptz, :link_public_id, :expected_generation)";
const LINKS_SQL = "SELECT * FROM roomscan.publication_list_links_v2(:credential_kind, :credential_hash, (:authoritative_time)::timestamptz, :snapshot_public_id, :limit, :cursor)";
const FEEDBACK_LIST_SQL = "SELECT * FROM roomscan.publication_list_feedback_v1(:credential_kind, :credential_hash, (:authoritative_time)::timestamptz, :link_public_id, :snapshot_public_id, :limit, :cursor)";
const ACCESS_HISTORY_SQL = "SELECT * FROM roomscan.publication_list_access_history_v1(:credential_kind, :credential_hash, (:authoritative_time)::timestamptz, :link_public_id, :limit, :cursor)";
const DOWNLOADS_SQL = "SELECT * FROM roomscan.publication_list_downloads_v1(:credential_kind, :credential_hash, (:authoritative_time)::timestamptz, :snapshot_public_id, :limit, :cursor)";
const PORTAL_EXCHANGE_SQL = "SELECT * FROM roomscan.portal_exchange_link_v1(:token_hash, (:authoritative_time)::timestamptz, :session_hash, :client_family, :network_risk_digest)";
const PIN_PARAMETERS_SQL = "SELECT * FROM roomscan.portal_pin_parameters_v1(:session_hash, (:authoritative_time)::timestamptz)";
const PIN_VERIFY_SQL = "SELECT * FROM roomscan.portal_verify_pin_v1(:session_hash, (:authoritative_time)::timestamptz, :pin_verifier)";
const PORTAL_SNAPSHOT_SQL = "SELECT * FROM roomscan.portal_get_snapshot_v2(:session_hash, (:authoritative_time)::timestamptz)";
const PORTAL_PRESENTATION_SQL = "SELECT * FROM roomscan.portal_lookup_presentation_asset_v1(:session_hash, (:authoritative_time)::timestamptz)";
const PORTAL_ROOMS_SQL = "SELECT * FROM roomscan.portal_list_property_rooms_v1(:session_hash, (:authoritative_time)::timestamptz)";
const PORTAL_ASSET_AUTHORIZE_SQL = "SELECT * FROM roomscan.portal_authorize_asset_v1(:session_hash, (:authoritative_time)::timestamptz, :asset_public_id, :request_digest, :byte_offset, :byte_length)";
const PORTAL_DOWNLOAD_AUTHORIZE_SQL = "SELECT * FROM roomscan.portal_authorize_download_v1(:session_hash, (:authoritative_time)::timestamptz, :download_kind, :request_digest, :byte_offset, :byte_length)";
const PORTAL_ASSET_FINALIZE_SQL = "SELECT * FROM roomscan.portal_finalize_asset_delivery_v1(:session_hash, (:authoritative_time)::timestamptz, :asset_public_id, :request_digest, :byte_offset, :byte_length, :object_version)";
const PROFESSIONAL_ASSET_AUTHORIZE_SQL = "SELECT * FROM roomscan.portal_authorize_professional_asset_v1(:session_hash, (:authoritative_time)::timestamptz, :asset_public_id, :request_digest, :byte_offset, :byte_length)";
const PROFESSIONAL_ASSET_FINALIZE_SQL = "SELECT * FROM roomscan.portal_finalize_professional_asset_delivery_v1(:session_hash, (:authoritative_time)::timestamptz, :asset_public_id, :request_digest, :byte_offset, :byte_length, :object_version)";
const FEEDBACK_REQUEST_V3_SQL = "SELECT * FROM roomscan.portal_request_feedback_verification_v3(:session_hash, (:authoritative_time)::timestamptz, :challenge_hash, :verification_token_hash, :verified_email_digest, :key_id, :iv, :ciphertext, :authentication_tag, :feedback_request_digest)";
const FEEDBACK_CONSUME_SQL = "SELECT * FROM roomscan.portal_consume_feedback_verification_v1(:session_hash, :challenge_hash, (:authoritative_time)::timestamptz, :verification_token_hash)";
const FEEDBACK_CREATE_SQL = "SELECT * FROM roomscan.portal_create_feedback_v1(:session_hash, (:authoritative_time)::timestamptz, :verification_token_hash, :feedback_kind, :comment, :request_digest)";
