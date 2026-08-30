/** Public Slice 5 HTTP vocabulary.  These identifiers are opaque server/public
 * identifiers; internal UUIDs, logical object keys, provider versions and
 * presigned URL persistence are deliberately absent. */
export const PROJECT_SYNC_STATUS = [
  "allocated",
  "validationPending",
  "validating",
  "canonical",
  "stale",
  "rejected",
  "attached",
] as const;
export type ProjectSyncStatus = (typeof PROJECT_SYNC_STATUS)[number];

/** Infrastructure binds this fixed, targetless wake to SQS. The message has
 * no project/upload/object/provider coordinates; workers claim server order. */
export const PROJECT_SYNC_VALIDATION_WAKE_QUEUE = "roomscan-project-validation-wake-v1" as const;

/**
 * Hosted professional-sync archives are fully buffered at the package
 * validation boundary. This operational ceiling is intentionally separate
 * from local packages, CloudKit backup, and quota policy values.
 */
export const PROJECT_SYNC_MAX_ARCHIVE_BYTES = 67_108_864 as const;

export interface ProjectSyncUploadStatus {
  readonly status: ProjectSyncStatus;
  readonly projectID: string;
  readonly uploadID: string;
  readonly candidateRevisionID?: string;
  readonly currentHostedHeadRevisionID?: string;
  readonly archiveSHA256: string;
  readonly archiveByteCount: number;
  readonly allocationExpiresAt: string;
}

export interface ProjectSyncAllocation extends ProjectSyncUploadStatus {
  readonly uploadURL: string;
  readonly uploadHeaders: Readonly<Record<string, string>>;
}

export interface ProjectSyncRecovery {
  readonly projectID: string;
  readonly revisionID: string;
  readonly branchState: "canonical" | "stale";
  readonly workingSetManifestSHA256: string;
  readonly archiveSHA256: string;
  readonly archiveByteCount: number;
  readonly downloadURL: string;
}

export interface ProjectSyncLease {
  readonly status: "acquired" | "held" | "renewed" | "released" | "unavailable";
  readonly expiresAt?: string;
}

export interface ProjectSyncRawArchiveConfiguration {
  readonly projectID: string;
  readonly rawArchiveEnabled: true;
  readonly reviewedAt: string;
}

export interface ProjectSyncMigrationAllocateInput {
  readonly sourceProjectID: string;
  readonly proposedRevisionID: string;
  readonly workingSetManifestSHA256: string;
  readonly archiveSHA256: string;
  readonly archiveByteCount: number;
  readonly idempotencyKey: string;
  readonly quotaPolicyVersion: number;
  readonly hostedGlobalVersion: number;
  readonly hostedWorkspaceVersion: number;
}

export interface ProjectSyncRevisionAllocateInput extends Omit<ProjectSyncMigrationAllocateInput, "sourceProjectID"> {
  readonly projectID: string;
  readonly expectedHostedHeadRevisionID: string;
  readonly expectedHeadRevisionID: string;
}

export interface ProjectSyncRawArchiveAllocateInput {
  readonly projectID: string;
  readonly revisionID: string;
  readonly rawManifestSHA256: string;
  readonly archiveSHA256: string;
  readonly archiveByteCount: number;
  readonly reviewSHA256: string;
  readonly idempotencyKey: string;
  readonly quotaPolicyVersion: number;
  readonly hostedGlobalVersion: number;
  readonly hostedWorkspaceVersion: number;
}

export interface ProjectSyncRawArchiveConfigureInput {
  readonly projectID: string;
  readonly reviewSHA256: string;
  readonly hostedGlobalVersion: number;
  readonly hostedWorkspaceVersion: number;
}
