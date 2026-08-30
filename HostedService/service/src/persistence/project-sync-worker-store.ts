import type { DataApiClient, SqlCell, SqlResult, SqlStatement } from "../adapters/data-api.js";
import { DataApiCapabilityTransactionRunner } from "./transaction-runner.js";
import type {
  ProjectSyncWorkerClaim,
  ProjectSyncWorkerOperation,
  ProjectSyncWorkerStore,
} from "../sync/project-sync-worker.js";
import type { CapabilitySqlUnit } from "./capabilities.js";

/** Worker-only persistence facade. Infrastructure binds its client to the
 * `roomscan_project_sync_runtime` database role; this constructor accepts no
 * role name, access token, workspace, upload, key, or provider target from an
 * HTTP/queue caller. Each reducer is an independent short SQL transaction so
 * ZIP/provider work is always outside PostgreSQL locks. */
export class DataApiProjectSyncWorkerStore implements ProjectSyncWorkerStore {
  readonly #transactions: DataApiCapabilityTransactionRunner<CapabilitySqlUnit>;

  constructor(input: { readonly client: DataApiClient }) {
    if (input === null || typeof input !== "object" || input.client === null || typeof input.client !== "object"
      || typeof input.client.begin !== "function" || typeof input.client.execute !== "function"
      || typeof input.client.commit !== "function" || typeof input.client.rollback !== "function") {
      throw new ProjectSyncWorkerStoreError("invalid_input");
    }
    this.#transactions = new DataApiCapabilityTransactionRunner(input.client, (unit) => unit);
  }

  async reapExpired(authoritativeNow: Date): Promise<number> {
    const row = one(await this.#run(REAP_SQL, [timestamp("authoritative_time", authoritativeNow)]));
    return nonNegative(row.reaped_count);
  }

  async claimNext(authoritativeNow: Date): Promise<ProjectSyncWorkerClaim | undefined> {
    const result = await this.#run(CLAIM_SQL, [timestamp("authoritative_time", authoritativeNow)]);
    if (result.rows.length === 0) return undefined;
    return decodeClaim(one(result));
  }

  async release(claim: Pick<ProjectSyncWorkerClaim, "uploadInternalId" | "leaseId">, authoritativeNow: Date): Promise<void> {
    const row = one(await this.#run(RELEASE_SQL, [uuidParameter("upload_id", claim.uploadInternalId), text("lease_id", leaseId(claim.leaseId)), timestamp("authoritative_time", authoritativeNow)]));
    if (row.status !== "validation_pending" && row.status !== "unavailable") throw new ProjectSyncWorkerStoreError("invalid_result");
  }

  async reject(claim: Pick<ProjectSyncWorkerClaim, "uploadInternalId" | "leaseId">, authoritativeNow: Date, reason: "invalid_archive" | "provider_missing" | "provider_mismatch" | "duplicate_revision"): Promise<void> {
    const row = one(await this.#run(REJECT_SQL, [uuidParameter("upload_id", claim.uploadInternalId), text("lease_id", leaseId(claim.leaseId)), timestamp("authoritative_time", authoritativeNow), text("rejection_code", rejection(reason))]));
    if (status(row.status) === undefined) throw new ProjectSyncWorkerStoreError("invalid_result");
  }

  async finalize(claim: Pick<ProjectSyncWorkerClaim, "uploadInternalId" | "leaseId">, authoritativeNow: Date, versions: { readonly quarantineVersionId: string; readonly activeVersionId: string }): Promise<"canonical" | "stale" | "attached" | "rejected"> {
    const row = one(await this.#run(FINALIZE_SQL, [
      uuidParameter("upload_id", claim.uploadInternalId), text("lease_id", leaseId(claim.leaseId)), timestamp("authoritative_time", authoritativeNow),
      text("quarantine_version", opaqueVersion(versions.quarantineVersionId)), text("active_object_version", opaqueVersion(versions.activeVersionId)),
    ]));
    const value = status(row.status);
    if (value !== "canonical" && value !== "stale" && value !== "attached" && value !== "rejected") throw new ProjectSyncWorkerStoreError("invalid_result");
    return value;
  }

  async #run(sql: string, parameters: SqlStatement["parameters"]): Promise<SqlResult> {
    try {
      return await this.#transactions.run((unit) => unit.execute(parameters === undefined ? { sql } : { sql, parameters }));
    } catch (error) {
      if (error instanceof ProjectSyncWorkerStoreError) throw error;
      throw new ProjectSyncWorkerStoreError("unavailable");
    }
  }
}

export class ProjectSyncWorkerStoreError extends Error {
  constructor(readonly code: "invalid_input" | "invalid_result" | "unavailable") {
    super(code);
    this.name = "ProjectSyncWorkerStoreError";
  }
}

/** These are exact 0008 API signatures. The two source IDs are worker-only
 * output columns added to the claim return shape: `project_source_project_id`
 * (professional project source) and `archive_source_revision_id` (candidate
 * working revision or raw target revision source). They must never fall back
 * to server public IDs. */
const REAP_SQL = "SELECT * FROM roomscan.reap_expired_project_upload_v1((:authoritative_time)::timestamptz)";
const CLAIM_SQL = "SELECT * FROM roomscan.claim_next_project_validation_v1((:authoritative_time)::timestamptz)";
const RELEASE_SQL = "SELECT * FROM roomscan.release_project_upload_v1((:upload_id)::uuid, :lease_id, (:authoritative_time)::timestamptz)";
const REJECT_SQL = "SELECT * FROM roomscan.reject_project_upload_v1((:upload_id)::uuid, :lease_id, (:authoritative_time)::timestamptz, :rejection_code)";
const FINALIZE_SQL = "SELECT * FROM roomscan.finalize_project_upload_v1((:upload_id)::uuid, :lease_id, (:authoritative_time)::timestamptz, :quarantine_version, :active_object_version)";

function decodeClaim(row: Readonly<Record<string, SqlCell>>): ProjectSyncWorkerClaim {
  const operation = workerOperation(row.operation);
  const base = {
    workspaceInternalId: uuid(row.workspace_id),
    uploadInternalId: uuid(row.upload_id),
    leaseId: leaseId(row.lease_id),
    operation,
    quarantineLogicalKey: logicalKey(row.quarantine_key),
    activeLogicalKey: logicalKey(row.active_object_key),
    projectSourceId: sourceIdentifier(row.project_source_project_id),
    candidateRevisionSourceId: sourceIdentifier(row.archive_source_revision_id),
  } as const;
  if (operation === "attach_raw_archive") {
    if (row.working_manifest_digest !== null || row.working_digest !== null || row.working_bytes !== null) throw new ProjectSyncWorkerStoreError("invalid_result");
    return Object.freeze({
      ...base,
      rawManifestSha256: digest(row.raw_manifest_digest),
      rawSha256: digest(row.raw_digest),
      rawByteCount: positive(row.raw_bytes),
      rawReviewSha256: digest(row.raw_review_digest),
    });
  }
  if (row.raw_manifest_digest !== null || row.raw_digest !== null || row.raw_bytes !== null || row.raw_review_digest !== null) throw new ProjectSyncWorkerStoreError("invalid_result");
  return Object.freeze({
    ...base,
    workingManifestSha256: digest(row.working_manifest_digest),
    workingSha256: digest(row.working_digest),
    workingByteCount: positive(row.working_bytes),
  });
}

function one(result: SqlResult): Readonly<Record<string, SqlCell>> {
  if (result.rows.length !== 1 || result.rows[0] === undefined) throw new ProjectSyncWorkerStoreError("invalid_result");
  return result.rows[0];
}
function workerOperation(value: unknown): ProjectSyncWorkerOperation {
  if (value === "create_initial_head" || value === "append_revision" || value === "attach_raw_archive") return value;
  throw new ProjectSyncWorkerStoreError("invalid_result");
}
function status(value: unknown): "validation_pending" | "canonical" | "stale" | "attached" | "rejected" | "unavailable" | undefined {
  return value === "validation_pending" || value === "canonical" || value === "stale" || value === "attached" || value === "rejected" || value === "unavailable" ? value : undefined;
}
function uuid(value: unknown): string {
  if (typeof value !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu.test(value)) throw new ProjectSyncWorkerStoreError("invalid_result");
  return value;
}
function leaseId(value: unknown): string {
  if (typeof value !== "string" || !/^wkl_[A-Za-z0-9_-]{16,128}$/u.test(value)) throw new ProjectSyncWorkerStoreError("invalid_input");
  return value;
}
function sourceIdentifier(value: unknown): string {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]{1,128}$/u.test(value)) throw new ProjectSyncWorkerStoreError("invalid_result");
  return value;
}
function logicalKey(value: unknown): string {
  if (typeof value !== "string" || value.length > 512 || value.includes("..") || value.includes("\\")) throw new ProjectSyncWorkerStoreError("invalid_result");
  return value;
}
function digest(value: unknown): string {
  if (!(value instanceof Uint8Array) || value.byteLength !== 32) throw new ProjectSyncWorkerStoreError("invalid_result");
  return Buffer.from(value).toString("hex");
}
function positive(value: unknown): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0) throw new ProjectSyncWorkerStoreError("invalid_result");
  return value;
}
function nonNegative(value: unknown): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) throw new ProjectSyncWorkerStoreError("invalid_result");
  return value;
}
function opaqueVersion(value: unknown): string {
  if (typeof value !== "string" || Buffer.byteLength(value, "utf8") < 1 || Buffer.byteLength(value, "utf8") > 1_024
    || /[\u0000-\u001f\u007f-\u009f]/u.test(value) || /[\ud800-\udfff]/u.test(value)) {
    throw new ProjectSyncWorkerStoreError("invalid_input");
  }
  return value;
}
function rejection(value: unknown): "invalid_archive" | "provider_missing" | "provider_mismatch" | "duplicate_revision" {
  if (value === "invalid_archive" || value === "provider_missing" || value === "provider_mismatch" || value === "duplicate_revision") return value;
  throw new ProjectSyncWorkerStoreError("invalid_input");
}
function timestamp(name: string, value: Date) {
  if (!(value instanceof Date) || !Number.isFinite(value.getTime())) throw new ProjectSyncWorkerStoreError("invalid_input");
  return { name, value: { kind: "string" as const, value: value.toISOString() } };
}
function text(name: string, value: string) { return { name, value: { kind: "string" as const, value } }; }
function uuidParameter(name: string, value: unknown) { return { name, value: { kind: "string" as const, value: uuid(value), typeHint: "UUID" as const } }; }
