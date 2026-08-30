import {
  ProjectSyncStorageError,
  type ProjectSyncObjectAdapter,
} from "../adapters/s3-project-sync.js";
import {
  ProjectSyncArchiveValidationError,
  validateProjectSyncArchive,
} from "./archive-validator.js";

export type ProjectSyncWorkerOperation = "create_initial_head" | "append_revision" | "attach_raw_archive";

/** This is a worker-only claim from PostgreSQL. No HTTP or queue payload names
 * one of these values; claim selection is targetless and server ordered. */
export interface ProjectSyncWorkerClaim {
  readonly workspaceInternalId: string;
  readonly uploadInternalId: string;
  readonly leaseId: string;
  readonly operation: ProjectSyncWorkerOperation;
  readonly quarantineLogicalKey: string;
  readonly activeLogicalKey: string;
  readonly workingManifestSha256?: string;
  readonly workingSha256?: string;
  readonly workingByteCount?: number;
  readonly rawManifestSha256?: string;
  readonly rawSha256?: string;
  readonly rawByteCount?: number;
  readonly rawReviewSha256?: string;
  readonly projectSourceId?: string;
  readonly candidateRevisionSourceId?: string;
}

export interface ProjectSyncWorkerStore {
  reapExpired(authoritativeNow: Date): Promise<number>;
  claimNext(authoritativeNow: Date): Promise<ProjectSyncWorkerClaim | undefined>;
  release(claim: Pick<ProjectSyncWorkerClaim, "uploadInternalId" | "leaseId">, authoritativeNow: Date): Promise<void>;
  reject(claim: Pick<ProjectSyncWorkerClaim, "uploadInternalId" | "leaseId">, authoritativeNow: Date, reason: "invalid_archive" | "provider_missing" | "provider_mismatch" | "duplicate_revision"): Promise<void>;
  finalize(claim: Pick<ProjectSyncWorkerClaim, "uploadInternalId" | "leaseId">, authoritativeNow: Date, versions: { readonly quarantineVersionId: string; readonly activeVersionId: string }): Promise<"canonical" | "stale" | "attached" | "rejected">;
}

export type ProjectSyncWorkerOutcome =
  | Readonly<{ readonly status: "idle"; readonly reaped: number }>
  | Readonly<{ readonly status: "finalized"; readonly reaped: number; readonly outcome: "canonical" | "stale" | "attached" | "rejected" }>
  | Readonly<{ readonly status: "rejected"; readonly reaped: number; readonly reason: "invalid_archive" | "provider_missing" | "provider_mismatch" | "duplicate_revision" }>
  | Readonly<{ readonly status: "retry"; readonly reaped: number }>;

export class ProjectSyncValidationWorker {
  constructor(private readonly dependencies: { readonly clock: { now(): Date }; readonly store: ProjectSyncWorkerStore; readonly objects: ProjectSyncObjectAdapter }) {
    if (dependencies === null || typeof dependencies !== "object" || dependencies.clock === null || typeof dependencies.clock.now !== "function"
      || dependencies.store === null || typeof dependencies.store.reapExpired !== "function" || typeof dependencies.store.claimNext !== "function"
      || typeof dependencies.store.release !== "function" || typeof dependencies.store.reject !== "function" || typeof dependencies.store.finalize !== "function") {
      throw new Error("invalid_project_sync_worker");
    }
  }

  /** Runs one targetless unit. An EventBridge tick or generic SQS wake can call
   * this safely; neither ever carries an upload/key/provider target. */
  async runOnce(): Promise<ProjectSyncWorkerOutcome> {
    const now = this.dependencies.clock.now();
    if (!(now instanceof Date) || !Number.isFinite(now.getTime())) throw new Error("invalid_project_sync_worker_clock");
    const reaped = await this.dependencies.store.reapExpired(now);
    const claim = await this.dependencies.store.claimNext(now);
    if (claim === undefined) return Object.freeze({ status: "idle", reaped });
    try {
      const quarantineVersionId = await (async () => {
        const quarantine = await this.dependencies.objects.readCurrentQuarantine({ workspaceInternalId: claim.workspaceInternalId, logicalKey: claim.quarantineLogicalKey });
        validateClaimArchive(claim, quarantine.bytes);
        return quarantine.versionId;
      })();
      const promoted = await this.dependencies.objects.promoteAndVerify({ workspaceInternalId: claim.workspaceInternalId, quarantineLogicalKey: claim.quarantineLogicalKey, quarantineVersionId, activeLogicalKey: claim.activeLogicalKey });
      // Promotion is not a validation bypass: inspect the exact active version
      // again before a database finalizer is allowed to move a hosted head.
      validateClaimArchive(claim, promoted.bytes);
      const outcome = await this.dependencies.store.finalize(claim, now, { quarantineVersionId: promoted.quarantineVersionId, activeVersionId: promoted.activeVersionId });
      return Object.freeze({ status: "finalized", reaped, outcome });
    } catch (error) {
      const rejection = rejectionFor(error);
      if (rejection !== undefined) {
        await this.dependencies.store.reject(claim, now, rejection);
        return Object.freeze({ status: "rejected", reaped, reason: rejection });
      }
      // Provider outage / transient Data API error leaves the durable pending
      // upload recoverable. The lease release permits the next targetless tick.
      try { await this.dependencies.store.release(claim, now); } catch { /* queue retry is still safe */ }
      return Object.freeze({ status: "retry", reaped });
    }
  }
}

function validateClaimArchive(claim: ProjectSyncWorkerClaim, archive: Uint8Array): void {
  if (claim.operation === "attach_raw_archive") {
    if (claim.rawManifestSha256 === undefined || claim.rawSha256 === undefined || claim.rawByteCount === undefined || claim.rawReviewSha256 === undefined || claim.projectSourceId === undefined || claim.candidateRevisionSourceId === undefined) throw new Error("invalid_project_sync_worker_claim");
    validateProjectSyncArchive({ tier: "raw", archive, expected: { projectId: claim.projectSourceId, sourceRevisionId: claim.candidateRevisionSourceId, manifestSha256: claim.rawManifestSha256, reviewSha256: claim.rawReviewSha256, sha256: claim.rawSha256, byteCount: claim.rawByteCount } });
    return;
  }
  if (claim.workingManifestSha256 === undefined || claim.workingSha256 === undefined || claim.workingByteCount === undefined || claim.projectSourceId === undefined || claim.candidateRevisionSourceId === undefined) throw new Error("invalid_project_sync_worker_claim");
  validateProjectSyncArchive({ tier: "working", archive, expected: { projectId: claim.projectSourceId, sourceRevisionId: claim.candidateRevisionSourceId, manifestSha256: claim.workingManifestSha256, sha256: claim.workingSha256, byteCount: claim.workingByteCount } });
}

function rejectionFor(error: unknown): "invalid_archive" | "provider_missing" | "provider_mismatch" | "duplicate_revision" | undefined {
  if (error instanceof ProjectSyncArchiveValidationError) return "invalid_archive";
  if (error instanceof ProjectSyncStorageError) return error.code === "provider_mismatch" || error.code === "invalid_project_sync_storage_key" ? "provider_mismatch" : "provider_missing";
  return undefined;
}
