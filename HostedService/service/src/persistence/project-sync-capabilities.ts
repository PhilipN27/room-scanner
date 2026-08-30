import { createHmac } from "node:crypto";

import { isHostedMutationAction, permissionFor } from "../authorization/policy.js";
import type {
  ProjectSyncAllocation,
  ProjectSyncLease,
  ProjectSyncMigrationAllocateInput,
  ProjectSyncRawArchiveAllocateInput,
  ProjectSyncRawArchiveConfiguration,
  ProjectSyncRawArchiveConfigureInput,
  ProjectSyncRecovery,
  ProjectSyncRevisionAllocateInput,
  ProjectSyncStatus,
  ProjectSyncUploadStatus,
} from "../contracts/project-sync.js";
import type { RouteAuthorization } from "../contracts/route-manifest.js";
import {
  createSlice5PostCommitResult,
  requireSlice5PostCommitEffect,
  OperationDeniedError,
  type AuthorizedOperationContext,
  type Slice5PostCommitResult,
  type Slice5SameTransactionOperationPort,
} from "../handlers/factory.js";
import {
  ProjectSyncObjectAdapter,
  projectSyncLogicalActiveKeyForRawUpload,
  projectSyncLogicalActiveKeyForWorkingRevision,
  projectSyncLogicalKeyForAllocation,
} from "../adapters/s3-project-sync.js";
import {
  DataApiTransactionError,
  DataApiTransactionExecutor,
  type DataApiClient,
  type SqlCell,
  type SqlResult,
  type SqlStatement,
  type SqlUnitOfWork,
} from "../adapters/data-api.js";
import { DataApiCapabilityRepository, type CapabilitySqlUnit, type WorkspaceAuthorizationState } from "./capabilities.js";
import type { TransactionBoundRepositoryBundle } from "../contracts/transaction-bound-repositories.js";

export class ProjectSyncCapabilityError extends Error {
  constructor(readonly code: "invalid_input" | "invalid_result" | "unavailable") {
    super(code);
    this.name = "ProjectSyncCapabilityError";
  }
}

export interface ProjectSyncValidationWakePort {
  /** The payload is fixed by the adapter/runtime; callers never supply an
   * upload ID, object key, tenant, or worker target. */
  notifyValidationWake(): Promise<void>;
}

export interface ProjectSyncPreparedResponse<T> {
  toPostCommitResult(): Slice5PostCommitResult<T>;
}

/** Opaque extension of the generic transaction bundle. Handlers must pass the
 * transaction marker back to `requireProjectSyncRepositories`; neither SQL nor
 * the internal recovery storage resolver is exposed on the public object. */
export interface ProjectSyncCapabilityRepositoryBundle extends TransactionBoundRepositoryBundle {
  readonly projectSync: DataApiProjectSyncCapabilityRepository;
}

export function requireProjectSyncRepositories(value: TransactionBoundRepositoryBundle, marker: symbol): ProjectSyncCapabilityRepositoryBundle {
  if (value === null || typeof value !== "object" || value.contract !== "roomscan-transaction-repositories-v1"
    || value.transactionMarker !== marker || !("projectSync" in value)
    || !(value.projectSync instanceof DataApiProjectSyncCapabilityRepository)) {
    throw new ProjectSyncCapabilityError("unavailable");
  }
  return value as ProjectSyncCapabilityRepositoryBundle;
}

interface ProjectSyncRepositoryDependencies {
  readonly unit: CapabilitySqlUnit;
  readonly accessTokenDigest: Uint8Array;
  readonly now: Date;
  readonly workspaceInternalId: string;
  readonly storage: ProjectSyncObjectAdapter;
  readonly validationWake: ProjectSyncValidationWakePort;
  readonly leaseHmacKey: Uint8Array;
}

/** API-role-only reducer facade. SQL strings and storage bindings stay inside
 * this capability; route applications receive only `ProjectSyncPreparedResponse`
 * and public response models. */
export class DataApiProjectSyncCapabilityRepository {
  readonly #unit: CapabilitySqlUnit;
  readonly #accessTokenDigest: Uint8Array;
  readonly #now: Date;
  readonly #workspaceInternalId: string;
  readonly #storage: ProjectSyncObjectAdapter;
  readonly #validationWake: ProjectSyncValidationWakePort;
  readonly #leaseHmacKey: Uint8Array;

  constructor(input: ProjectSyncRepositoryDependencies) {
    if (input === null || typeof input !== "object" || input.unit === null || typeof input.unit.execute !== "function"
      || !(input.accessTokenDigest instanceof Uint8Array) || input.accessTokenDigest.length !== 32
      || !(input.now instanceof Date) || !Number.isFinite(input.now.getTime()) || !uuid(input.workspaceInternalId)
      || !(input.storage instanceof ProjectSyncObjectAdapter) || input.validationWake === null || typeof input.validationWake !== "object" || typeof input.validationWake.notifyValidationWake !== "function"
      || !(input.leaseHmacKey instanceof Uint8Array) || input.leaseHmacKey.length < 32) {
      throw new ProjectSyncCapabilityError("invalid_input");
    }
    this.#unit = input.unit;
    this.#accessTokenDigest = Uint8Array.from(input.accessTokenDigest);
    this.#now = new Date(input.now.getTime());
    this.#workspaceInternalId = input.workspaceInternalId;
    this.#storage = input.storage;
    this.#validationWake = input.validationWake;
    this.#leaseHmacKey = Uint8Array.from(input.leaseHmacKey);
  }

  async allocateMigration(input: ProjectSyncMigrationAllocateInput): Promise<ProjectSyncPreparedResponse<ProjectSyncAllocation>> {
    const valid = validMigrationInput(input); if (!valid) throw new ProjectSyncCapabilityError("invalid_input");
    const row = one(await this.#execute(ALLOCATE_MIGRATION_SQL, [
      blob("access_token_hash", this.#accessTokenDigest), timestamp("authoritative_time", this.#now),
      text("source_project_id", input.sourceProjectID), text("proposed_revision_id", input.proposedRevisionID),
      digest("working_manifest_digest", input.workingSetManifestSHA256), digest("working_digest", input.archiveSHA256), integer("working_bytes", input.archiveByteCount),
      digest("idempotency_digest", digestOfOpaque(input.idempotencyKey)), integer("policy_version", input.quotaPolicyVersion), integer("global_version", input.hostedGlobalVersion), integer("workspace_version", input.hostedWorkspaceVersion),
    ]));
    const allocation = decodeWorkingAllocation(row);
    const logicalKey = projectSyncLogicalKeyForAllocation({ tier: "working", uploadId: allocation.uploadID });
    return this.#preparedUpload(allocation, logicalKey);
  }

  async allocateRevision(input: ProjectSyncRevisionAllocateInput): Promise<ProjectSyncPreparedResponse<ProjectSyncAllocation>> {
    const valid = validRevisionInput(input); if (!valid) throw new ProjectSyncCapabilityError("invalid_input");
    const row = one(await this.#execute(ALLOCATE_REVISION_SQL, [
      blob("access_token_hash", this.#accessTokenDigest), timestamp("authoritative_time", this.#now),
      text("project_public_id", input.projectID), text("expected_head_public_id", input.expectedHostedHeadRevisionID), text("expected_head_source_revision_id", input.expectedHeadRevisionID), text("proposed_revision_id", input.proposedRevisionID),
      digest("working_manifest_digest", input.workingSetManifestSHA256), digest("working_digest", input.archiveSHA256), integer("working_bytes", input.archiveByteCount),
      digest("idempotency_digest", digestOfOpaque(input.idempotencyKey)), integer("policy_version", input.quotaPolicyVersion), integer("global_version", input.hostedGlobalVersion), integer("workspace_version", input.hostedWorkspaceVersion),
    ]));
    const allocation = decodeWorkingAllocation(row);
    const logicalKey = projectSyncLogicalKeyForAllocation({ tier: "working", uploadId: allocation.uploadID });
    return this.#preparedUpload(allocation, logicalKey);
  }

  async allocateRawArchive(input: ProjectSyncRawArchiveAllocateInput): Promise<ProjectSyncPreparedResponse<ProjectSyncAllocation>> {
    if (!validRawAllocationInput(input)) throw new ProjectSyncCapabilityError("invalid_input");
    const row = one(await this.#execute(ALLOCATE_RAW_SQL, [
      blob("access_token_hash", this.#accessTokenDigest), timestamp("authoritative_time", this.#now), text("project_public_id", input.projectID), text("revision_public_id", input.revisionID),
      digest("raw_manifest_digest", input.rawManifestSHA256), digest("raw_digest", input.archiveSHA256), integer("raw_bytes", input.archiveByteCount), digest("review_digest", input.reviewSHA256), digest("idempotency_digest", digestOfOpaque(input.idempotencyKey)),
      integer("policy_version", input.quotaPolicyVersion), integer("global_version", input.hostedGlobalVersion), integer("workspace_version", input.hostedWorkspaceVersion),
    ]));
    const allocation = decodeRawAllocation(row);
    const logicalKey = projectSyncLogicalKeyForAllocation({ tier: "raw", uploadId: allocation.uploadID });
    return this.#preparedUpload(allocation, logicalKey);
  }

  async completeUpload(uploadID: string): Promise<ProjectSyncPreparedResponse<ProjectSyncUploadStatus>> {
    if (!uploadId(uploadID)) throw new ProjectSyncCapabilityError("invalid_input");
    const status = decodeUploadStatus(one(await this.#execute(COMPLETE_UPLOAD_SQL, [blob("access_token_hash", this.#accessTokenDigest), timestamp("authoritative_time", this.#now), text("upload_public_id", uploadID)])));
    return prepared(() => status, async () => this.#validationWake.notifyValidationWake());
  }

  async uploadStatus(uploadID: string): Promise<ProjectSyncPreparedResponse<ProjectSyncUploadStatus>> {
    if (!uploadId(uploadID)) throw new ProjectSyncCapabilityError("invalid_input");
    const status = decodeUploadStatus(one(await this.#execute(READ_UPLOAD_STATUS_SQL, [blob("access_token_hash", this.#accessTokenDigest), timestamp("authoritative_time", this.#now), text("upload_public_id", uploadID)])));
    return prepared(() => status);
  }

  /** SQL's internal resolver result remains in this method's closure. The
   * handler sees only a prepared public recovery response and never a logical
   * key/version/provider binding. Both reducers independently re-derive scope. */
  async allocateRecovery(input: { readonly projectID: string; readonly revisionID?: string }): Promise<ProjectSyncPreparedResponse<ProjectSyncRecovery>> {
    if (!projectId(input.projectID) || (input.revisionID !== undefined && !revisionId(input.revisionID))) throw new ProjectSyncCapabilityError("invalid_input");
    const parameters = [blob("access_token_hash", this.#accessTokenDigest), timestamp("authoritative_time", this.#now), text("project_public_id", input.projectID), optionalText("revision_public_id", input.revisionID)];
    const publicRow = one(await this.#execute(ALLOCATE_RECOVERY_SQL, parameters));
    const internalRow = one(await this.#execute(RESOLVE_RECOVERY_STORAGE_SQL, parameters));
    const publicRecovery = decodeRecoveryProjection(publicRow);
    const internal = decodeRecoveryStorageBinding(internalRow);
    if (publicRecovery.projectID !== internal.projectID || publicRecovery.revisionID !== internal.revisionID || publicRecovery.branchState !== internal.branchState
      || publicRecovery.workingSetManifestSHA256 !== internal.workingSetManifestSHA256 || publicRecovery.archiveSHA256 !== internal.archiveSHA256 || publicRecovery.archiveByteCount !== internal.archiveByteCount) {
      throw new ProjectSyncCapabilityError("invalid_result");
    }
    let downloadURL: string | undefined;
    return prepared(
      () => {
        if (downloadURL === undefined) throw new ProjectSyncCapabilityError("unavailable");
        return Object.freeze({ ...publicRecovery, downloadURL });
      },
      async () => {
        // The exact persisted version is the only storage target; no logical
        // key is re-derived for recovery and nothing reaches a log/response.
        downloadURL = await this.#storage.presignExactDownload({ workspaceInternalId: this.#workspaceInternalId, logicalKey: internal.logicalKey, versionId: internal.versionId });
      },
    );
  }

  async configureRawArchive(input: ProjectSyncRawArchiveConfigureInput): Promise<ProjectSyncPreparedResponse<ProjectSyncRawArchiveConfiguration>> {
    if (!validRawConfigureInput(input)) throw new ProjectSyncCapabilityError("invalid_input");
    const row = one(await this.#execute(CONFIGURE_RAW_SQL, [blob("access_token_hash", this.#accessTokenDigest), timestamp("authoritative_time", this.#now), text("project_public_id", input.projectID), digest("review_digest", input.reviewSHA256), integer("global_version", input.hostedGlobalVersion), integer("workspace_version", input.hostedWorkspaceVersion)]));
    const reviewedAt = timestampCell(row.raw_reviewed_at);
    if (row.project_public_id !== input.projectID || row.raw_archive_enabled !== true) throw new ProjectSyncCapabilityError("invalid_result");
    return prepared(() => Object.freeze({ projectID: input.projectID, rawArchiveEnabled: true, reviewedAt }));
  }

  async acquireLease(input: { readonly projectID: string; readonly deviceID: string; readonly requestID: string; readonly leaseToken: string; readonly hostedGlobalVersion: number; readonly hostedWorkspaceVersion: number }): Promise<ProjectSyncPreparedResponse<ProjectSyncLease>> {
    if (!projectId(input.projectID) || !opaque(input.deviceID, 16) || !opaque(input.requestID, 16) || !opaque(input.leaseToken, 32) || !positiveVersion(input.hostedGlobalVersion) || !positiveVersion(input.hostedWorkspaceVersion)) throw new ProjectSyncCapabilityError("invalid_input");
    const row = one(await this.#execute(ACQUIRE_LEASE_SQL, [blob("access_token_hash", this.#accessTokenDigest), timestamp("authoritative_time", this.#now), text("project_public_id", input.projectID), blob("device_digest", leaseDigest(this.#leaseHmacKey, "device", input.deviceID)), blob("request_digest", leaseDigest(this.#leaseHmacKey, "request", input.requestID)), blob("token_digest", leaseDigest(this.#leaseHmacKey, "token", input.leaseToken)), integer("global_version", input.hostedGlobalVersion), integer("workspace_version", input.hostedWorkspaceVersion)]));
    return prepared(() => decodeLease(row));
  }

  async renewLease(input: { readonly projectID: string; readonly leaseToken: string; readonly hostedGlobalVersion: number; readonly hostedWorkspaceVersion: number }): Promise<ProjectSyncPreparedResponse<ProjectSyncLease>> {
    if (!projectId(input.projectID) || !opaque(input.leaseToken, 32) || !positiveVersion(input.hostedGlobalVersion) || !positiveVersion(input.hostedWorkspaceVersion)) throw new ProjectSyncCapabilityError("invalid_input");
    const row = one(await this.#execute(RENEW_LEASE_SQL, [blob("access_token_hash", this.#accessTokenDigest), timestamp("authoritative_time", this.#now), text("project_public_id", input.projectID), blob("token_digest", leaseDigest(this.#leaseHmacKey, "token", input.leaseToken)), integer("global_version", input.hostedGlobalVersion), integer("workspace_version", input.hostedWorkspaceVersion)]));
    return prepared(() => decodeLease(row));
  }

  async releaseLease(input: { readonly projectID: string; readonly leaseToken: string; readonly hostedGlobalVersion: number; readonly hostedWorkspaceVersion: number }): Promise<ProjectSyncPreparedResponse<ProjectSyncLease>> {
    if (!projectId(input.projectID) || !opaque(input.leaseToken, 32) || !positiveVersion(input.hostedGlobalVersion) || !positiveVersion(input.hostedWorkspaceVersion)) throw new ProjectSyncCapabilityError("invalid_input");
    const row = one(await this.#execute(RELEASE_LEASE_SQL, [blob("access_token_hash", this.#accessTokenDigest), timestamp("authoritative_time", this.#now), text("project_public_id", input.projectID), blob("token_digest", leaseDigest(this.#leaseHmacKey, "token", input.leaseToken)), integer("global_version", input.hostedGlobalVersion), integer("workspace_version", input.hostedWorkspaceVersion)]));
    return prepared(() => decodeLease(row));
  }

  #preparedUpload(allocation: Omit<ProjectSyncAllocation, "uploadURL" | "uploadHeaders">, logicalKey: string): ProjectSyncPreparedResponse<ProjectSyncAllocation> {
    let signed: Readonly<{ readonly url: string; readonly headers: Readonly<Record<string, string>> }> | undefined;
    return prepared(
      () => {
        if (signed === undefined) throw new ProjectSyncCapabilityError("unavailable");
        return Object.freeze({ ...allocation, uploadURL: signed.url, uploadHeaders: signed.headers });
      },
      async () => {
        signed = await this.#storage.presignImmutableUpload({ workspaceInternalId: this.#workspaceInternalId, logicalKey, byteCount: allocation.archiveByteCount, checksumSha256: Buffer.from(allocation.archiveSHA256, "hex").toString("base64") });
      },
    );
  }

  async #execute(sql: string, parameters: readonly { readonly name: string; readonly value: SqlStatement["parameters"] extends readonly (infer P)[] | undefined ? P extends { readonly value: infer V } ? V : never : never }[]): Promise<SqlResult> {
    try { return await this.#unit.execute({ sql, parameters }); } catch { throw new ProjectSyncCapabilityError("unavailable"); }
  }
}

export interface DataApiProjectSyncOperationPortDependencies {
  readonly client?: DataApiClient;
  readonly transactions?: DataApiTransactionExecutor;
  readonly accessTokenHmacKey: Uint8Array;
  readonly leaseHmacKey: Uint8Array;
  readonly clock: { now(): Date };
  readonly storage: ProjectSyncObjectAdapter;
  readonly validationWake: ProjectSyncValidationWakePort;
}

/** Separate from the frozen Slice 4 operation port. Hosted writes check the
 * two write flags; `private.download` only rechecks live membership/resource
 * authorization so rollback can still recover immutable branches. */
export class DataApiProjectSyncOperationPort implements Slice5SameTransactionOperationPort {
  readonly #transactions: DataApiTransactionExecutor;
  readonly #accessTokenHmacKey: Uint8Array;
  readonly #leaseHmacKey: Uint8Array;
  readonly #clock: { now(): Date };
  readonly #storage: ProjectSyncObjectAdapter;
  readonly #validationWake: ProjectSyncValidationWakePort;

  constructor(input: DataApiProjectSyncOperationPortDependencies) {
    if (input === null || typeof input !== "object" || !(input.accessTokenHmacKey instanceof Uint8Array) || input.accessTokenHmacKey.length < 32
      || !(input.leaseHmacKey instanceof Uint8Array) || input.leaseHmacKey.length < 32 || input.clock === null || typeof input.clock.now !== "function"
      || !(input.storage instanceof ProjectSyncObjectAdapter) || input.validationWake === null || typeof input.validationWake !== "object" || typeof input.validationWake.notifyValidationWake !== "function"
      || (input.transactions === undefined && input.client === undefined) || (input.transactions !== undefined && input.client !== undefined)) {
      throw new ProjectSyncCapabilityError("invalid_input");
    }
    this.#transactions = input.transactions ?? new DataApiTransactionExecutor(input.client!, { authorize: async () => false });
    this.#accessTokenHmacKey = Uint8Array.from(input.accessTokenHmacKey); this.#leaseHmacKey = Uint8Array.from(input.leaseHmacKey); this.#clock = input.clock; this.#storage = input.storage; this.#validationWake = input.validationWake;
  }

  async run<T>(input: { readonly accessToken: string; readonly authorization: Exclude<RouteAuthorization, { readonly kind: "public" }> }, operation: (context: AuthorizedOperationContext) => Promise<Slice5PostCommitResult<T>>): Promise<T> {
    if (!opaque(input.accessToken, 32) || typeof operation !== "function") throw new OperationDeniedError();
    const now = this.#clock.now(); if (!(now instanceof Date) || !Number.isFinite(now.getTime())) throw new OperationDeniedError();
    const accessTokenDigest = createHmac("sha256", this.#accessTokenHmacKey).update(input.accessToken).digest();
    let result: Slice5PostCommitResult<T>;
    try {
      result = await this.#transactions.accessTransaction(accessTokenDigest, now, async (unit) => {
        const api = new DataApiCapabilityRepository({ execute: unit.execute }, { accessTokenDigest });
        const current = await api.readWorkspaceAuthorizationState({ authoritativeNowMs: now.getTime() });
        assertProjectSyncAuthorization(unit, input.authorization, current);
        const marker = Symbol("roomscan-project-sync-capability-transaction");
        const repository = new DataApiProjectSyncCapabilityRepository({ unit: { execute: unit.execute }, accessTokenDigest, now, workspaceInternalId: unit.context.workspaceInternalId!, storage: this.#storage, validationWake: this.#validationWake, leaseHmacKey: this.#leaseHmacKey });
        const repositories: ProjectSyncCapabilityRepositoryBundle = Object.freeze({ contract: "roomscan-transaction-repositories-v1", transactionMarker: marker, projectSync: repository });
        return operation(Object.freeze({ principalPublicId: unit.context.principalPublicId, transactionMarker: marker, repositories }));
      });
    } catch (error) {
      if (error instanceof OperationDeniedError) throw error;
      if (error instanceof DataApiTransactionError && error.code === "invalid_access") throw new OperationDeniedError();
      throw error;
    }
    // The Data API commit has completed. Only now may a provider interaction
    // occur; a failure leaves durable allocation/pending state retryable.
    const effect = requireSlice5PostCommitEffect(result);
    await effect();
    return result.publicResult();
  }
}

function assertProjectSyncAuthorization(unit: SqlUnitOfWork, authorization: Exclude<RouteAuthorization, { readonly kind: "public" }>, current: WorkspaceAuthorizationState | undefined): void {
  if (authorization.kind !== "workspace" || unit.context.workspaceInternalId === undefined || unit.context.role === undefined || unit.context.authorizationVersion === undefined || current === undefined
    || current.workspaceInternalId !== unit.context.workspaceInternalId || current.principalInternalId !== unit.context.principalInternalId || current.principalCanonicalId !== unit.context.principalPublicId
    || current.familyInternalId !== unit.context.familyInternalId || current.familyPublicId !== unit.context.familyPublicId || current.role !== unit.context.role
    || current.authorizationVersion !== unit.context.authorizationVersion || current.authenticationEpoch !== unit.context.authenticationEpoch
    || current.authenticatedAtMs !== parseTimestampMilliseconds(unit.context.authenticatedAt) || current.recentAuthentication !== unit.context.recentAuthentication) {
    throw new DataApiTransactionError("invalid_access");
  }
  const permission = permissionFor(current.role, authorization.action);
  if (!permission.allowed || (permission.requiresRecentAuthentication && current.recentAuthentication !== true)) throw new DataApiTransactionError("invalid_access");
  if (isHostedMutationAction(authorization.action) && (current.hosted.global.enabled !== true || current.hosted.workspace.enabled !== true)) throw new DataApiTransactionError("invalid_access");
}

function parseTimestampMilliseconds(value: unknown): number {
  if (typeof value !== "string") throw new DataApiTransactionError("invalid_access");
  const milliseconds = Date.parse(value);
  if (!Number.isSafeInteger(milliseconds)) throw new DataApiTransactionError("invalid_access");
  return milliseconds;
}

function prepared<T>(publicResult: () => T, effect: () => Promise<void> = async () => undefined): ProjectSyncPreparedResponse<T> {
  return Object.freeze({ toPostCommitResult: () => createSlice5PostCommitResult(publicResult, effect) });
}

function decodeWorkingAllocation(row: Readonly<Record<string, SqlCell>>): Omit<ProjectSyncAllocation, "uploadURL" | "uploadHeaders"> { const status = databaseStatus(row.status); const projectID = projectIdValue(row.project_public_id); const uploadID = uploadIdValue(row.upload_public_id); const candidate = nullableRevisionId(row.candidate_revision_public_id); const archiveSHA256 = digestHex(row.working_digest); const archiveByteCount = positiveCell(row.working_bytes); const allocationExpiresAt = timestampCell(row.allocation_expires_at); return Object.freeze({ status, projectID, uploadID, ...(candidate === undefined ? {} : { candidateRevisionID: candidate }), archiveSHA256, archiveByteCount, allocationExpiresAt }); }
function decodeRawAllocation(row: Readonly<Record<string, SqlCell>>): Omit<ProjectSyncAllocation, "uploadURL" | "uploadHeaders"> { const status = databaseStatus(row.status); const projectID = projectIdValue(row.project_public_id); const uploadID = uploadIdValue(row.upload_public_id); const candidate = nullableRevisionId(row.target_revision_public_id); const archiveSHA256 = digestHex(row.raw_digest); const archiveByteCount = positiveCell(row.raw_bytes); const allocationExpiresAt = timestampCell(row.allocation_expires_at); return Object.freeze({ status, projectID, uploadID, ...(candidate === undefined ? {} : { candidateRevisionID: candidate }), archiveSHA256, archiveByteCount, allocationExpiresAt }); }
function decodeUploadStatus(row: Readonly<Record<string, SqlCell>>): ProjectSyncUploadStatus { const status = databaseStatus(row.status); const projectID = projectIdValue(row.project_public_id); const uploadID = uploadIdValue(row.upload_public_id); const candidate = nullableRevisionId(row.candidate_revision_public_id); const head = nullableRevisionId(row.current_hosted_head_revision_public_id); const raw = row.raw_digest instanceof Uint8Array; const archiveSHA256 = digestHex(raw ? row.raw_digest : row.working_digest); const archiveByteCount = positiveCell(raw ? row.raw_bytes : row.working_bytes); const allocationExpiresAt = timestampCell(row.allocation_expires_at); return Object.freeze({ status, projectID, uploadID, ...(candidate === undefined ? {} : { candidateRevisionID: candidate }), ...(head === undefined ? {} : { currentHostedHeadRevisionID: head }), archiveSHA256, archiveByteCount, allocationExpiresAt }); }
function decodeRecoveryProjection(row: Readonly<Record<string, SqlCell>>): Omit<ProjectSyncRecovery, "downloadURL"> { const projectID = projectIdValue(row.project_public_id); const revisionID = revisionIdValue(row.target_revision_public_id); const branchState = row.branch_state === "canonical" || row.branch_state === "stale" ? row.branch_state : invalidResult(); return Object.freeze({ projectID, revisionID, branchState, workingSetManifestSHA256: digestHex(row.working_manifest_digest), archiveSHA256: digestHex(row.working_digest), archiveByteCount: positiveCell(row.working_bytes) }); }
function decodeRecoveryStorageBinding(row: Readonly<Record<string, SqlCell>>): Readonly<{ readonly projectID: string; readonly revisionID: string; readonly branchState: "canonical" | "stale"; readonly logicalKey: string; readonly versionId: string; readonly workingSetManifestSHA256: string; readonly archiveSHA256: string; readonly archiveByteCount: number }> { const projectID = projectIdValue(row.project_public_id); const revisionID = revisionIdValue(row.target_revision_public_id); const branchState = row.branch_state === "canonical" || row.branch_state === "stale" ? row.branch_state : invalidResult(); if (typeof row.working_object_key !== "string" || typeof row.working_object_version !== "string") throw new ProjectSyncCapabilityError("invalid_result"); return Object.freeze({ projectID, revisionID, branchState, logicalKey: row.working_object_key, versionId: row.working_object_version, workingSetManifestSHA256: digestHex(row.working_manifest_digest), archiveSHA256: digestHex(row.working_digest), archiveByteCount: positiveCell(row.working_bytes) }); }
function decodeLease(row: Readonly<Record<string, SqlCell>>): ProjectSyncLease { const status = row.status; if (status !== "acquired" && status !== "held" && status !== "renewed" && status !== "released" && status !== "unavailable") throw new ProjectSyncCapabilityError("invalid_result"); const expiresAt = row.expires_at === null ? undefined : timestampCell(row.expires_at); return Object.freeze({ status, ...(expiresAt === undefined ? {} : { expiresAt }) }); }

function one(result: SqlResult): Readonly<Record<string, SqlCell>> { if (result.rows.length !== 1 || result.rows[0] === undefined) throw new ProjectSyncCapabilityError("invalid_result"); return result.rows[0]; }
function databaseStatus(value: unknown): ProjectSyncStatus { if (value === "allocated") return "allocated"; if (value === "validation_pending") return "validationPending"; if (value === "validating") return "validating"; if (value === "canonical" || value === "stale" || value === "rejected" || value === "attached") return value; throw new ProjectSyncCapabilityError("invalid_result"); }
function digestHex(value: unknown): string { if (!(value instanceof Uint8Array) || value.byteLength !== 32) throw new ProjectSyncCapabilityError("invalid_result"); return Buffer.from(value).toString("hex"); }
function positiveCell(value: unknown): number { if (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0) throw new ProjectSyncCapabilityError("invalid_result"); return value; }
function timestampCell(value: unknown): string { if (!timestampString(value)) throw new ProjectSyncCapabilityError("invalid_result"); return value; }
function timestampString(value: unknown): value is string { return typeof value === "string" && value.length <= 64 && Number.isFinite(Date.parse(value)); }
function projectIdValue(value: unknown): string { if (!projectId(value)) throw new ProjectSyncCapabilityError("invalid_result"); return value; }
function revisionIdValue(value: unknown): string { if (!revisionId(value)) throw new ProjectSyncCapabilityError("invalid_result"); return value; }
function uploadIdValue(value: unknown): string { if (!uploadId(value)) throw new ProjectSyncCapabilityError("invalid_result"); return value; }
function nullableRevisionId(value: unknown): string | undefined { if (value === null) return undefined; return revisionIdValue(value); }
function invalidResult(): never { throw new ProjectSyncCapabilityError("invalid_result"); }

function blob(name: string, bytes: Uint8Array) { return { name, value: { kind: "blob" as const, bytes: Uint8Array.from(bytes) } }; }
function text(name: string, value: string) { return { name, value: { kind: "string" as const, value } }; }
function optionalText(name: string, value: string | undefined) { return value === undefined ? { name, value: { kind: "null" as const } } : text(name, value); }
function timestamp(name: string, value: Date) { return { name, value: { kind: "string" as const, value: value.toISOString() } }; }
function integer(name: string, value: number) { return { name, value: { kind: "long" as const, value } }; }
function digest(name: string, value: string) { return blob(name, Buffer.from(value, "hex")); }
function digestOfOpaque(value: string): string { return createHmac("sha256", "roomscan-project-sync-idempotency-v1").update(value).digest("hex"); }
function leaseDigest(key: Uint8Array, label: string, value: string): Uint8Array { return createHmac("sha256", key).update("roomscan-project-sync-lease-v1\0", "utf8").update(label, "utf8").update("\0", "utf8").update(value, "utf8").digest(); }

const IDENTIFIER = /^[A-Za-z0-9_-]{1,128}$/u; const DIGEST = /^[a-f0-9]{64}$/u;
function opaque(value: unknown, minimum: number): value is string { return typeof value === "string" && value.length >= minimum && value.length <= 4096 && /^[A-Za-z0-9._~-]+$/u.test(value); }
function projectId(value: unknown): value is string { return typeof value === "string" && /^prj_[A-Za-z0-9_-]{16,128}$/u.test(value); }
function revisionId(value: unknown): value is string { return typeof value === "string" && /^rev_[A-Za-z0-9_-]{16,128}$/u.test(value); }
function uploadId(value: unknown): value is string { return typeof value === "string" && /^upl_[A-Za-z0-9_-]{16,128}$/u.test(value); }
function uuid(value: unknown): value is string { return typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu.test(value); }
function positiveVersion(value: unknown): value is number { return typeof value === "number" && Number.isSafeInteger(value) && value >= 1; }
function validMigrationInput(value: ProjectSyncMigrationAllocateInput): boolean { return IDENTIFIER.test(value.sourceProjectID) && IDENTIFIER.test(value.proposedRevisionID) && digestInput(value.workingSetManifestSHA256) && digestInput(value.archiveSHA256) && validCommon(value); }
function validRevisionInput(value: ProjectSyncRevisionAllocateInput): boolean { return projectId(value.projectID) && revisionId(value.expectedHostedHeadRevisionID) && IDENTIFIER.test(value.expectedHeadRevisionID) && IDENTIFIER.test(value.proposedRevisionID) && value.expectedHeadRevisionID !== value.proposedRevisionID && digestInput(value.workingSetManifestSHA256) && digestInput(value.archiveSHA256) && validCommon(value); }
function validRawAllocationInput(value: ProjectSyncRawArchiveAllocateInput): boolean { return projectId(value.projectID) && revisionId(value.revisionID) && digestInput(value.rawManifestSHA256) && digestInput(value.archiveSHA256) && digestInput(value.reviewSHA256) && typeof value.idempotencyKey === "string" && opaque(value.idempotencyKey, 16) && Number.isSafeInteger(value.archiveByteCount) && value.archiveByteCount > 0 && positiveVersion(value.quotaPolicyVersion) && positiveVersion(value.hostedGlobalVersion) && positiveVersion(value.hostedWorkspaceVersion); }
function validRawConfigureInput(value: ProjectSyncRawArchiveConfigureInput): boolean { return projectId(value.projectID) && digestInput(value.reviewSHA256) && positiveVersion(value.hostedGlobalVersion) && positiveVersion(value.hostedWorkspaceVersion); }
function validCommon(value: { readonly archiveByteCount: number; readonly idempotencyKey: string; readonly quotaPolicyVersion: number; readonly hostedGlobalVersion: number; readonly hostedWorkspaceVersion: number }): boolean { return Number.isSafeInteger(value.archiveByteCount) && value.archiveByteCount > 0 && opaque(value.idempotencyKey, 16) && positiveVersion(value.quotaPolicyVersion) && positiveVersion(value.hostedGlobalVersion) && positiveVersion(value.hostedWorkspaceVersion); }
function digestInput(value: unknown): value is string { return typeof value === "string" && DIGEST.test(value); }

const ALLOCATE_MIGRATION_SQL = "SELECT * FROM roomscan.allocate_project_migration_v1(:access_token_hash, (:authoritative_time)::timestamptz, :source_project_id, :proposed_revision_id, :working_manifest_digest, :working_digest, :working_bytes, :idempotency_digest, :policy_version, :global_version, :workspace_version)";
const ALLOCATE_REVISION_SQL = "SELECT * FROM roomscan.allocate_project_revision_v1(:access_token_hash, (:authoritative_time)::timestamptz, :project_public_id, :expected_head_public_id, :expected_head_source_revision_id, :proposed_revision_id, :working_manifest_digest, :working_digest, :working_bytes, :idempotency_digest, :policy_version, :global_version, :workspace_version)";
const ALLOCATE_RAW_SQL = "SELECT * FROM roomscan.allocate_project_raw_archive_v1(:access_token_hash, (:authoritative_time)::timestamptz, :project_public_id, :revision_public_id, :raw_manifest_digest, :raw_digest, :raw_bytes, :review_digest, :idempotency_digest, :policy_version, :global_version, :workspace_version)";
const COMPLETE_UPLOAD_SQL = "SELECT * FROM roomscan.complete_project_upload_v1(:access_token_hash, (:authoritative_time)::timestamptz, :upload_public_id)";
const READ_UPLOAD_STATUS_SQL = "SELECT * FROM roomscan.read_project_upload_status_v1(:access_token_hash, (:authoritative_time)::timestamptz, :upload_public_id)";
const ALLOCATE_RECOVERY_SQL = "SELECT * FROM roomscan.allocate_project_recovery_v1(:access_token_hash, (:authoritative_time)::timestamptz, :project_public_id, :revision_public_id)";
const RESOLVE_RECOVERY_STORAGE_SQL = "SELECT * FROM roomscan.resolve_project_recovery_storage_v1(:access_token_hash, (:authoritative_time)::timestamptz, :project_public_id, :revision_public_id)";
const CONFIGURE_RAW_SQL = "SELECT * FROM roomscan.configure_project_raw_archive_v1(:access_token_hash, (:authoritative_time)::timestamptz, :project_public_id, :review_digest, :global_version, :workspace_version)";
const ACQUIRE_LEASE_SQL = "SELECT * FROM roomscan.acquire_project_edit_lease_v1(:access_token_hash, (:authoritative_time)::timestamptz, :project_public_id, :device_digest, :request_digest, :token_digest, :global_version, :workspace_version)";
const RENEW_LEASE_SQL = "SELECT * FROM roomscan.renew_project_edit_lease_v1(:access_token_hash, (:authoritative_time)::timestamptz, :project_public_id, :token_digest, :global_version, :workspace_version)";
const RELEASE_LEASE_SQL = "SELECT * FROM roomscan.release_project_edit_lease_v1(:access_token_hash, (:authoritative_time)::timestamptz, :project_public_id, :token_digest, :global_version, :workspace_version)";
