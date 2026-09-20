import type { DataApiClient, SqlCell, SqlResult, SqlStatement } from "../adapters/data-api.js";
import { DataApiCapabilityTransactionRunner } from "./transaction-runner.js";
import type { CapabilitySqlUnit } from "./capabilities.js";

export type PublicationWorkerRejection = "allocation_expired" | "source_changed" | "approval_changed" | "invalid_archive" | "publication_disabled" | "quota_unavailable";
export interface PublicationWorkerClaim {
  readonly allocationInternalID: string;
  readonly allocationPublicID: string;
  readonly leaseID: string;
  readonly sourceBindingsSHA256: string;
  readonly selectionManifestSHA256: string;
  readonly approvalSHA256: string;
  readonly archiveSHA256: string;
  readonly archiveManifestSHA256: string;
  readonly archiveByteCount: number;
  readonly quarantineKey: string;
}
/** Only the worker-side binding reducer can add this provider version. A
 * targetless claim intentionally has no storage identity to validate. */
export interface PublicationWorkerBoundQuarantine {
  readonly allocationPublicID: string;
  readonly quarantineKey: string;
  readonly quarantineVersion: string;
  readonly archiveSHA256: string;
  readonly archiveManifestSHA256: string;
  readonly archiveByteCount: number;
}
export interface PublicationWorkerStore {
  claimNext(authoritativeTime: Date): Promise<PublicationWorkerClaim | undefined>;
  bindQuarantineVersion(claim: Pick<PublicationWorkerClaim, "allocationInternalID" | "leaseID">, authoritativeTime: Date, quarantineVersion: string): Promise<PublicationWorkerBoundQuarantine>;
  reject(claim: Pick<PublicationWorkerClaim, "allocationInternalID" | "leaseID">, authoritativeTime: Date, code: PublicationWorkerRejection): Promise<void>;
  finalize(claim: Pick<PublicationWorkerClaim, "allocationInternalID" | "leaseID">, authoritativeTime: Date, input: { readonly activeObjectVersion: string; readonly presentationSHA256: string; readonly sourceBindingsSHA256: string; readonly presentationByteCount: number; readonly assets: readonly Readonly<{ readonly assetID: string; readonly kind: string; readonly objectKey: string; readonly objectVersion: string; readonly contentType: string; readonly sha256: string; readonly byteCount: number; readonly downloadKind?: string }>[] }): Promise<Readonly<{ readonly status: "published" | "existing"; readonly snapshotID: string }>>;
}

export class PublicationWorkerStoreError extends Error {
  constructor(readonly code: "invalid_input" | "invalid_result" | "unavailable") { super(code); this.name = "PublicationWorkerStoreError"; }
}

/** Worker-only persistence. This constructor accepts a role-bound Data API
 * client but no HTTP credential, route request, storage key, tenant, or
 * arbitrary SQL. Every claim is selected server-side by 0009. */
export class DataApiPublicationWorkerStore implements PublicationWorkerStore {
  readonly #transactions: DataApiCapabilityTransactionRunner<CapabilitySqlUnit>;
  constructor(input: { readonly client: DataApiClient }) {
    if (input === null || typeof input !== "object" || input.client === null || typeof input.client !== "object" || typeof input.client.begin !== "function" || typeof input.client.execute !== "function" || typeof input.client.commit !== "function" || typeof input.client.rollback !== "function") throw new PublicationWorkerStoreError("invalid_input");
    this.#transactions = new DataApiCapabilityTransactionRunner(input.client, (unit) => unit);
  }
  async claimNext(authoritativeTime: Date): Promise<PublicationWorkerClaim | undefined> {
    const result = await this.#query(CLAIM_SQL, [timestamp("authoritative_time", authoritativeTime)]);
    if (result.rows.length === 0) return undefined;
    const row = one(result); if (row.status !== "validating") return undefined;
    if (row.quarantine_version !== null) throw new PublicationWorkerStoreError("invalid_result");
    return Object.freeze({ allocationInternalID: uuidCell(row.allocation_id), allocationPublicID: publicID(row.allocation_public_id, "pua_"), leaseID: leaseID(row.lease_id), sourceBindingsSHA256: digestCell(row.source_bindings_digest), selectionManifestSHA256: digestCell(row.selection_digest), approvalSHA256: digestCell(row.approval_digest), archiveSHA256: digestCell(row.archive_digest), archiveManifestSHA256: digestCell(row.archive_manifest_digest), archiveByteCount: positiveCell(row.archive_bytes), quarantineKey: quarantineKey(row.quarantine_key) });
  }
  async bindQuarantineVersion(claim: Pick<PublicationWorkerClaim, "allocationInternalID" | "leaseID">, authoritativeTime: Date, quarantineVersion: string): Promise<PublicationWorkerBoundQuarantine> {
    const row = one(await this.#query(BIND_QUARANTINE_SQL, [uuid("allocation_id", claim.allocationInternalID), text("lease_id", leaseID(claim.leaseID)), timestamp("authoritative_time", authoritativeTime), text("quarantine_version", version(quarantineVersion))]));
    if (row.status !== "bound" && row.status !== "existing") throw new PublicationWorkerStoreError("invalid_result");
    return Object.freeze({
      allocationPublicID: publicID(row.allocation_public_id, "pua_"),
      quarantineKey: quarantineKey(row.quarantine_key),
      quarantineVersion: versionCell(row.quarantine_version),
      archiveSHA256: digestCell(row.archive_digest),
      archiveManifestSHA256: digestCell(row.archive_manifest_digest),
      archiveByteCount: positiveCell(row.archive_bytes),
    });
  }
  async reject(claim: Pick<PublicationWorkerClaim, "allocationInternalID" | "leaseID">, authoritativeTime: Date, code: PublicationWorkerRejection): Promise<void> {
    const row = one(await this.#query(REJECT_SQL, [uuid("allocation_id", claim.allocationInternalID), text("lease_id", leaseID(claim.leaseID)), timestamp("authoritative_time", authoritativeTime), text("rejection_code", rejection(code))]));
    if (row.status !== "rejected" && row.status !== "existing") throw new PublicationWorkerStoreError("invalid_result");
  }
  async finalize(claim: Pick<PublicationWorkerClaim, "allocationInternalID" | "leaseID">, authoritativeTime: Date, input: { readonly activeObjectVersion: string; readonly presentationSHA256: string; readonly sourceBindingsSHA256: string; readonly presentationByteCount: number; readonly assets: readonly Readonly<{ readonly assetID: string; readonly kind: string; readonly objectKey: string; readonly objectVersion: string; readonly contentType: string; readonly sha256: string; readonly byteCount: number; readonly downloadKind?: string }>[] }): Promise<Readonly<{ readonly status: "published" | "existing"; readonly snapshotID: string }>> {
    if (!Array.isArray(input.assets) || input.assets.length < 1 || input.assets.length > 256) throw new PublicationWorkerStoreError("invalid_input");
    const assets = input.assets.map((asset) => ({ asset_id: asset.assetID, kind: asset.kind, object_key: asset.objectKey, object_version: asset.objectVersion, content_type: asset.contentType, digest_hex: asset.sha256, bytes: asset.byteCount, download_kind: asset.downloadKind ?? null }));
    const row = one(await this.#query(FINALIZE_SQL, [uuid("allocation_id", claim.allocationInternalID), text("lease_id", leaseID(claim.leaseID)), timestamp("authoritative_time", authoritativeTime), text("active_object_version", version(input.activeObjectVersion)), digest("presentation_digest", input.presentationSHA256), digest("source_bindings_digest", input.sourceBindingsSHA256), integer("presentation_bytes", input.presentationByteCount), json("assets", assets)]));
    const status = row.status === "published" || row.status === "existing" ? row.status : invalidResult(); return Object.freeze({ status, snapshotID: publicID(row.snapshot_public_id, "snp_") });
  }
  async #query(sql: string, parameters: SqlStatement["parameters"]): Promise<SqlResult> { try { return await this.#transactions.run((unit) => unit.execute(parameters === undefined ? { sql } : { sql, parameters })); } catch (error) { if (error instanceof PublicationWorkerStoreError) throw error; throw new PublicationWorkerStoreError("unavailable"); } }
}

function one(result: SqlResult): Readonly<Record<string, SqlCell>> { if (result.rows.length !== 1 || result.rows[0] === undefined) throw new PublicationWorkerStoreError("invalid_result"); return result.rows[0]; }
function uuidCell(value: SqlCell | undefined): string { if (typeof value !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu.test(value)) throw new PublicationWorkerStoreError("invalid_result"); return value; }
function publicID(value: SqlCell | undefined, prefix: string): string { if (typeof value !== "string" || !new RegExp(`^${prefix}[A-Za-z0-9_-]{16,128}$`, "u").test(value)) throw new PublicationWorkerStoreError("invalid_result"); return value; }
function leaseID(value: unknown): string { if (typeof value !== "string" || !/^pwl_[A-Za-z0-9_-]{16,128}$/u.test(value)) throw new PublicationWorkerStoreError("invalid_input"); return value; }
function digestCell(value: SqlCell | undefined): string { if (!(value instanceof Uint8Array) || value.byteLength !== 32) throw new PublicationWorkerStoreError("invalid_result"); return Buffer.from(value).toString("hex"); }
function positiveCell(value: SqlCell | undefined): number { if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 1) throw new PublicationWorkerStoreError("invalid_result"); return value; }
function quarantineKey(value: SqlCell | undefined): string { if (typeof value !== "string" || !/^server\/published\/quarantine\/v1\/pua_[A-Za-z0-9_-]{16,128}\.zip$/u.test(value)) throw new PublicationWorkerStoreError("invalid_result"); return value; }
function version(value: unknown): string { if (typeof value !== "string" || Buffer.byteLength(value, "utf8") < 1 || Buffer.byteLength(value, "utf8") > 1_024 || /[\u0000-\u001f\u007f-\u009f]/u.test(value)) throw new PublicationWorkerStoreError("invalid_input"); return value; }
function versionCell(value: SqlCell | undefined): string { if (typeof value !== "string" || Buffer.byteLength(value, "utf8") < 1 || Buffer.byteLength(value, "utf8") > 1_024 || /[\u0000-\u001f\u007f-\u009f]/u.test(value)) throw new PublicationWorkerStoreError("invalid_result"); return value; }
function rejection(value: PublicationWorkerRejection): PublicationWorkerRejection { if (value === "allocation_expired" || value === "source_changed" || value === "approval_changed" || value === "invalid_archive" || value === "publication_disabled" || value === "quota_unavailable") return value; throw new PublicationWorkerStoreError("invalid_input"); }
function invalidResult(): never { throw new PublicationWorkerStoreError("invalid_result"); }
function blob(name: string, bytes: Uint8Array) { return { name, value: { kind: "blob" as const, bytes: Uint8Array.from(bytes) } }; }
function text(name: string, value: string) { return { name, value: { kind: "string" as const, value } }; }
function uuid(name: string, value: string) { return { name, value: { kind: "string" as const, value, typeHint: "UUID" as const } }; }
function integer(name: string, value: number) { if (!Number.isSafeInteger(value) || value < 1) throw new PublicationWorkerStoreError("invalid_input"); return { name, value: { kind: "long" as const, value } }; }
function timestamp(name: string, value: Date) { if (!(value instanceof Date) || !Number.isFinite(value.getTime())) throw new PublicationWorkerStoreError("invalid_input"); return { name, value: { kind: "string" as const, value: value.toISOString() } }; }
function digest(name: string, value: string) { if (!/^[a-f0-9]{64}$/u.test(value)) throw new PublicationWorkerStoreError("invalid_input"); return blob(name, Buffer.from(value, "hex")); }
function json(name: string, value: unknown) { return text(name, JSON.stringify(value)); }

const CLAIM_SQL = "SELECT * FROM roomscan.publication_claim_job_v1((:authoritative_time)::timestamptz)";
const BIND_QUARANTINE_SQL = "SELECT * FROM roomscan.publication_bind_quarantine_version_v1((:allocation_id)::uuid, :lease_id, (:authoritative_time)::timestamptz, :quarantine_version)";
const REJECT_SQL = "SELECT * FROM roomscan.publication_reject_v1((:allocation_id)::uuid, :lease_id, (:authoritative_time)::timestamptz, :rejection_code)";
const FINALIZE_SQL = "SELECT * FROM roomscan.publication_finalize_v1((:allocation_id)::uuid, :lease_id, (:authoritative_time)::timestamptz, :active_object_version, :presentation_digest, :source_bindings_digest, :presentation_bytes, (:assets)::jsonb)";
