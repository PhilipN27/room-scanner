import { createHash } from "node:crypto";

import { PROJECT_SYNC_MAX_ARCHIVE_BYTES } from "../contracts/project-sync.js";

/** Logical keys are persisted by PostgreSQL. They are never provider keys;
 * each provider call must map them through this strict server-owned boundary. */
const WORKING_QUARANTINE = /^professional-sync\/quarantine\/working\/(upl_[A-Za-z0-9_-]{16,128})\.zip$/u;
const RAW_QUARANTINE = /^professional-sync\/quarantine\/raw\/(upl_[A-Za-z0-9_-]{16,128})\.zip$/u;
const WORKING_ACTIVE = /^professional-sync\/active\/working\/(rev_[A-Za-z0-9_-]{16,128})\.zip$/u;
const RAW_ACTIVE = /^professional-sync\/active\/raw\/(upl_[A-Za-z0-9_-]{16,128})\.zip$/u;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;
const SHA256_BASE64 = /^[A-Za-z0-9+/]{43}=$/u;

export type ProjectSyncLogicalStorageKind = "quarantine-working" | "quarantine-raw" | "active-working" | "active-raw";

export interface ProjectSyncPhysicalStorageBinding {
  readonly workspaceInternalId: string;
  readonly logicalKey: string;
}

export class ProjectSyncStorageError extends Error {
  constructor(readonly code: "invalid_project_sync_storage_key" | "provider_mismatch" | "provider_unavailable") {
    super(code);
    this.name = "ProjectSyncStorageError";
  }
}

/** No raw workspace UUID appears in an S3 key. The one-way server marker is
 * stable enough for policy prefixing and is always recomputed, never trusted
 * from a caller or database logical key. */
export function mapProjectSyncLogicalStorageKey(input: ProjectSyncPhysicalStorageBinding): string {
  if (input === null || typeof input !== "object" || !UUID.test(input.workspaceInternalId)) throw storageFail("invalid_project_sync_storage_key");
  const kind = logicalKind(input.logicalKey);
  const tenant = createHash("sha256").update(input.workspaceInternalId, "utf8").digest("hex").slice(0, 24);
  const prefix = kind.startsWith("quarantine") ? "server/quarantine/v1" : "server/active/v1";
  return `${prefix}/${tenant}/${input.logicalKey}`;
}

export function projectSyncLogicalKeyForAllocation(input: { readonly tier: "working" | "raw"; readonly uploadId: string }): string {
  if (!/^upl_[A-Za-z0-9_-]{16,128}$/u.test(input.uploadId)) throw storageFail("invalid_project_sync_storage_key");
  return `professional-sync/quarantine/${input.tier}/${input.uploadId}.zip`;
}

export function projectSyncLogicalActiveKeyForWorkingRevision(revisionId: string): string {
  if (!/^rev_[A-Za-z0-9_-]{16,128}$/u.test(revisionId)) throw storageFail("invalid_project_sync_storage_key");
  return `professional-sync/active/working/${revisionId}.zip`;
}

export function projectSyncLogicalActiveKeyForRawUpload(uploadId: string): string {
  if (!/^upl_[A-Za-z0-9_-]{16,128}$/u.test(uploadId)) throw storageFail("invalid_project_sync_storage_key");
  return `professional-sync/active/raw/${uploadId}.zip`;
}

export interface ProjectSyncObjectVersion {
  readonly versionId: string;
  readonly bytes: Uint8Array;
  readonly contentType: "application/zip";
  readonly checksumSha256: string;
}

export interface ProjectSyncPresignedPut {
  readonly url: string;
  readonly headers: Readonly<Record<string, string>>;
}

export interface ProjectSyncObjectProvider {
  presignImmutablePut(input: { readonly physicalKey: string; readonly contentLength: number; readonly checksumSha256: string; readonly contentType: "application/zip"; readonly expiresInSeconds: 300; readonly ifNoneMatch: "*" }): Promise<ProjectSyncPresignedPut>;
  /** HEAD is only used by the server worker to capture an exact immutable
   * quarantine version before it reads/validates it. */
  headCurrent(input: { readonly physicalKey: string }): Promise<Readonly<{ readonly versionId: string; readonly contentLength: number; readonly contentType: "application/zip"; readonly checksumSha256: string }>>;
  readExact(input: { readonly physicalKey: string; readonly versionId: string }): Promise<ProjectSyncObjectVersion>;
  copyImmutable(input: { readonly sourcePhysicalKey: string; readonly sourceVersionId: string; readonly destinationPhysicalKey: string; readonly ifNoneMatch: "*" }): Promise<Readonly<{ readonly versionId: string }>>;
  presignExactDownload(input: { readonly physicalKey: string; readonly versionId: string; readonly expiresInSeconds: 300 }): Promise<Readonly<{ readonly url: string }>>;
}

/** Trusted composition/worker adapter. Route handlers never receive this type,
 * a logical key, a physical key, an object version, or the provider port. */
export class ProjectSyncObjectAdapter {
  constructor(private readonly provider: ProjectSyncObjectProvider) {
    if (provider === null || typeof provider !== "object" || typeof provider.presignImmutablePut !== "function"
      || typeof provider.headCurrent !== "function" || typeof provider.readExact !== "function" || typeof provider.copyImmutable !== "function" || typeof provider.presignExactDownload !== "function") {
      throw storageFail("provider_unavailable");
    }
  }

  async presignImmutableUpload(input: ProjectSyncPhysicalStorageBinding & { readonly byteCount: number; readonly checksumSha256: string }): Promise<ProjectSyncPresignedPut> {
    const physicalKey = mapProjectSyncLogicalStorageKey(input);
    if (!logicalKind(input.logicalKey).startsWith("quarantine") || !Number.isSafeInteger(input.byteCount) || input.byteCount <= 0 || input.byteCount > PROJECT_SYNC_MAX_ARCHIVE_BYTES
      || !SHA256_BASE64.test(input.checksumSha256)) throw storageFail("invalid_project_sync_storage_key");
    let put: ProjectSyncPresignedPut;
    try {
      put = await this.provider.presignImmutablePut({ physicalKey, contentLength: input.byteCount, checksumSha256: input.checksumSha256, contentType: "application/zip", expiresInSeconds: 300, ifNoneMatch: "*" });
    } catch { throw storageFail("provider_unavailable"); }
    validatePresignedPut(put, input.byteCount, input.checksumSha256);
    return Object.freeze({ url: put.url, headers: Object.freeze({ ...put.headers }) });
  }

  async promoteAndVerify(input: { readonly workspaceInternalId: string; readonly quarantineLogicalKey: string; readonly quarantineVersionId: string; readonly activeLogicalKey: string }): Promise<Readonly<{ readonly quarantineVersionId: string; readonly activeVersionId: string; readonly bytes: Uint8Array; readonly checksumSha256: string }>> {
    const quarantinePhysical = mapProjectSyncLogicalStorageKey({ workspaceInternalId: input.workspaceInternalId, logicalKey: input.quarantineLogicalKey });
    const activePhysical = mapProjectSyncLogicalStorageKey({ workspaceInternalId: input.workspaceInternalId, logicalKey: input.activeLogicalKey });
    const quarantineKind = logicalKind(input.quarantineLogicalKey);
    const activeKind = logicalKind(input.activeLogicalKey);
    if (!validPromotionPair(quarantineKind, activeKind) || !versionId(input.quarantineVersionId)) throw storageFail("invalid_project_sync_storage_key");
    let source: ProjectSyncObjectVersion;
    let active: ProjectSyncObjectVersion;
    let activeVersionId: string;
    try {
      source = await this.provider.readExact({ physicalKey: quarantinePhysical, versionId: input.quarantineVersionId });
      validateObject(source);
      if (source.versionId !== input.quarantineVersionId) throw storageFail("provider_mismatch");
      try {
        const copied = await this.provider.copyImmutable({ sourcePhysicalKey: quarantinePhysical, sourceVersionId: input.quarantineVersionId, destinationPhysicalKey: activePhysical, ifNoneMatch: "*" });
        if (!versionId(copied.versionId)) throw storageFail("provider_mismatch");
        activeVersionId = copied.versionId;
      } catch (copyError) {
        if (copyError instanceof ProjectSyncStorageError) throw copyError;
        // The unique active object may already have been created by a worker
        // which crashed after the immutable copy and before PostgreSQL CAS.
        // Recover only when that exact active version proves identical to the
        // claimed quarantine version; a different immutable object is a
        // durable conflict, never a reason to overwrite or spin forever.
        let existing;
        try {
          existing = await this.provider.headCurrent({ physicalKey: activePhysical });
        } catch {
          throw storageFail("provider_unavailable");
        }
        if (!versionId(existing.versionId) || !Number.isSafeInteger(existing.contentLength) || existing.contentLength <= 0
          || existing.contentType !== "application/zip" || !SHA256_BASE64.test(existing.checksumSha256)) {
          throw storageFail("provider_mismatch");
        }
        activeVersionId = existing.versionId;
      }
      active = await this.provider.readExact({ physicalKey: activePhysical, versionId: activeVersionId });
      validateObject(active);
    } catch (error) {
      if (error instanceof ProjectSyncStorageError) throw error;
      throw storageFail("provider_unavailable");
    }
    if (active.versionId !== activeVersionId || !sameObject(source, active)) throw storageFail("provider_mismatch");
    // The exact active version was just re-read and checksum-validated. Keep
    // that bounded provider buffer rather than cloning a whole archive again.
    return Object.freeze({ quarantineVersionId: source.versionId, activeVersionId: active.versionId, bytes: active.bytes, checksumSha256: active.checksumSha256 });
  }

  async readExact(input: ProjectSyncPhysicalStorageBinding & { readonly versionId: string }): Promise<ProjectSyncObjectVersion> {
    const physicalKey = mapProjectSyncLogicalStorageKey(input);
    if (!versionId(input.versionId)) throw storageFail("invalid_project_sync_storage_key");
    try {
      const value = await this.provider.readExact({ physicalKey, versionId: input.versionId });
      validateObject(value); if (value.versionId !== input.versionId) throw storageFail("provider_mismatch");
      return Object.freeze({ ...value, bytes: value.bytes });
    } catch (error) {
      if (error instanceof ProjectSyncStorageError) throw error;
      throw storageFail("provider_unavailable");
    }
  }

  async readCurrentQuarantine(input: ProjectSyncPhysicalStorageBinding): Promise<ProjectSyncObjectVersion> {
    const physicalKey = mapProjectSyncLogicalStorageKey(input);
    if (!logicalKind(input.logicalKey).startsWith("quarantine")) throw storageFail("invalid_project_sync_storage_key");
    try {
      const head = await this.provider.headCurrent({ physicalKey });
      if (!versionId(head.versionId) || !Number.isSafeInteger(head.contentLength) || head.contentLength <= 0 || head.contentType !== "application/zip" || !SHA256_BASE64.test(head.checksumSha256)) throw storageFail("provider_mismatch");
      const object = await this.provider.readExact({ physicalKey, versionId: head.versionId });
      validateObject(object);
      if (object.versionId !== head.versionId || object.bytes.byteLength !== head.contentLength || object.checksumSha256 !== head.checksumSha256) throw storageFail("provider_mismatch");
      return Object.freeze({ ...object, bytes: object.bytes });
    } catch (error) {
      if (error instanceof ProjectSyncStorageError) throw error;
      throw storageFail("provider_unavailable");
    }
  }

  async presignExactDownload(input: ProjectSyncPhysicalStorageBinding & { readonly versionId: string }): Promise<string> {
    const physicalKey = mapProjectSyncLogicalStorageKey(input);
    if (!logicalKind(input.logicalKey).startsWith("active") || !versionId(input.versionId)) throw storageFail("invalid_project_sync_storage_key");
    try {
      const signed = await this.provider.presignExactDownload({ physicalKey, versionId: input.versionId, expiresInSeconds: 300 });
      const url = new URL(signed.url); if (url.protocol !== "https:" || url.username || url.password) throw storageFail("provider_mismatch");
      return signed.url;
    } catch (error) {
      if (error instanceof ProjectSyncStorageError) throw error;
      throw storageFail("provider_unavailable");
    }
  }
}

function logicalKind(value: unknown): ProjectSyncLogicalStorageKind {
  if (typeof value !== "string" || value.includes("..") || value.includes("\\") || value.length > 512) throw storageFail("invalid_project_sync_storage_key");
  if (WORKING_QUARANTINE.test(value)) return "quarantine-working";
  if (RAW_QUARANTINE.test(value)) return "quarantine-raw";
  if (WORKING_ACTIVE.test(value)) return "active-working";
  if (RAW_ACTIVE.test(value)) return "active-raw";
  throw storageFail("invalid_project_sync_storage_key");
}

/** A raw review attachment can never land on a working-revision namespace,
 * and a working revision can never land on a raw attachment namespace. This
 * independent adapter guard survives a malformed worker claim or DB bug. */
function validPromotionPair(quarantine: ProjectSyncLogicalStorageKind, active: ProjectSyncLogicalStorageKind): boolean {
  return (quarantine === "quarantine-working" && active === "active-working")
    || (quarantine === "quarantine-raw" && active === "active-raw");
}

function validatePresignedPut(value: ProjectSyncPresignedPut, byteCount: number, checksumSha256: string): void {
  let url: URL; try { url = new URL(value.url); } catch { throw storageFail("provider_mismatch"); }
  if (url.protocol !== "https:" || url.username || url.password) throw storageFail("provider_mismatch");
  const headers = new Map<string, string>();
  for (const [name, header] of Object.entries(value.headers)) { const normalized = name.toLowerCase(); if (headers.has(normalized)) throw storageFail("provider_mismatch"); headers.set(normalized, header); }
  const expected = new Map<string, string>([["content-length", String(byteCount)], ["content-type", "application/zip"], ["x-amz-checksum-sha256", checksumSha256], ["if-none-match", "*"]]);
  if (headers.size !== expected.size || [...expected].some(([name, header]) => headers.get(name) !== header)) throw storageFail("provider_mismatch");
}

function validateObject(value: ProjectSyncObjectVersion): void {
  if (value === null || typeof value !== "object" || !versionId(value.versionId) || !(value.bytes instanceof Uint8Array)
    || value.bytes.byteLength > PROJECT_SYNC_MAX_ARCHIVE_BYTES || value.contentType !== "application/zip" || !SHA256_BASE64.test(value.checksumSha256)) throw storageFail("provider_mismatch");
  const actual = createHash("sha256").update(value.bytes).digest("base64");
  if (actual !== value.checksumSha256) throw storageFail("provider_mismatch");
}
function sameObject(left: ProjectSyncObjectVersion, right: ProjectSyncObjectVersion): boolean {
  if (left.bytes.byteLength !== right.bytes.byteLength || left.checksumSha256 !== right.checksumSha256) return false;
  for (let index = 0; index < left.bytes.byteLength; index += 1) {
    if (left.bytes[index] !== right.bytes[index]) return false;
  }
  return true;
}
/** S3 VersionId is opaque provider data, not a grammar owned by RoomScan. It
 * may contain `+` and `/`; accept a bounded scalar UTF-8 string and never
 * parse/derive its semantics. */
function versionId(value: unknown): value is string {
  return typeof value === "string" && Buffer.byteLength(value, "utf8") >= 1 && Buffer.byteLength(value, "utf8") <= 1_024
    && !/[\u0000-\u001f\u007f-\u009f]/u.test(value) && !/[\ud800-\udfff]/u.test(value);
}
function storageFail(code: ProjectSyncStorageError["code"]): ProjectSyncStorageError { return new ProjectSyncStorageError(code); }
