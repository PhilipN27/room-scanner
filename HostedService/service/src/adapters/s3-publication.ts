import {
  PUBLICATION_MAX_ARCHIVE_BYTES,
  PUBLICATION_MAX_ASSET_BYTES,
  PUBLICATION_MAX_NESTED_AI_READY_BYTES,
  PUBLICATION_MAX_PRESENTATION_BYTES,
  PUBLICATION_MAX_PROTECTED_CHUNK_BYTES,
} from "../publication/contracts.js";
import type { PublicationArchiveReader } from "../publication/archive-validator.js";

const ALLOCATION = /^pua_[A-Za-z0-9_-]{16,128}$/u;
const ASSET = /^ast_[A-Za-z0-9_-]{16,128}$/u;
const SHA256_BASE64 = /^[A-Za-z0-9+/]{43}=$/u;

export class PublicationStorageError extends Error {
  constructor(readonly code: "invalid_publication_storage_key" | "provider_mismatch" | "provider_unavailable") {
    super(code);
    this.name = "PublicationStorageError";
  }
}

export interface PublicationPresignedPut {
  readonly url: string;
  readonly headers: Readonly<Record<string, string>>;
}

/** A deliberately narrow provider port.  The service never requests a
 * browser-readable provider URL: portal bytes travel through live database
 * authorization and an exact-version range read instead. */
export interface PublicationObjectProvider {
  presignImmutablePut(input: {
    readonly physicalKey: string;
    readonly contentLength: number;
    readonly checksumSha256: string;
    readonly contentType: "application/zip";
    readonly expiresInSeconds: 300;
    readonly ifNoneMatch: "*";
  }): Promise<PublicationPresignedPut>;
  headCurrent(input: { readonly physicalKey: string }): Promise<Readonly<{
    readonly versionId: string;
    readonly contentLength: number;
    readonly contentType: PublicationContentType;
    readonly checksumSha256: string;
  }>>;
  readRangeExact(input: { readonly physicalKey: string; readonly versionId: string; readonly offset: number; readonly length: number }): Promise<Uint8Array>;
  putImmutable(input: { readonly physicalKey: string; readonly bytes: Uint8Array; readonly contentType: PublicationContentType; readonly ifNoneMatch: "*" }): Promise<Readonly<{ readonly versionId: string }>>;
}

export type PublicationContentType = "application/json" | "image/png" | "image/jpeg" | "application/pdf" | "application/zip";
/** Internal promoted class, carried only from the revalidated worker-derived
 * ledger. It lets the storage boundary retain each public size/content-type
 * ceiling instead of treating every ZIP as an AI package. */
export type PublicationActiveDerivativeKind = "presentation" | "web_geometry" | "web_texture" | "selected_image" | "floor_plan" | "approved_concept" | "floor_plan_pdf" | "gallery_zip" | "ai_ready_package";

export interface PublicationQuarantineObject {
  readonly versionId: string;
  readonly byteCount: number;
  readonly reader: PublicationArchiveReader;
}

/** Maps only a database-issued `pua_` logical key to the exact 0009 object
 * namespace. Allocation IDs are unguessable opaque capability references;
 * workspace isolation is enforced by the database reducers before this
 * adapter is reached, not by a caller-selected storage prefix. */
export function mapPublicationQuarantineStorageKey(input: { readonly allocationPublicID: string }): string {
  if (!ALLOCATION.test(input.allocationPublicID)) throw storageFail("invalid_publication_storage_key");
  return `server/published/quarantine/v1/${input.allocationPublicID}.zip`;
}

export function mapPublicationActiveStorageKey(input: { readonly allocationPublicID: string; readonly assetPublicID: string }): string {
  if (!ALLOCATION.test(input.allocationPublicID) || !ASSET.test(input.assetPublicID)) throw storageFail("invalid_publication_storage_key");
  return `server/published/active/v1/${input.allocationPublicID}/${input.assetPublicID}.bin`;
}

export class PublicationObjectAdapter {
  constructor(private readonly provider: PublicationObjectProvider) {
    if (provider === null || typeof provider !== "object" || typeof provider.presignImmutablePut !== "function"
      || typeof provider.headCurrent !== "function" || typeof provider.readRangeExact !== "function" || typeof provider.putImmutable !== "function") {
      throw storageFail("provider_unavailable");
    }
  }

  async presignQuarantineUpload(input: { readonly allocationPublicID: string; readonly byteCount: number; readonly archiveSHA256: string }): Promise<PublicationPresignedPut> {
    if (!Number.isSafeInteger(input.byteCount) || input.byteCount < 1 || input.byteCount > PUBLICATION_MAX_ARCHIVE_BYTES || !/^[a-f0-9]{64}$/u.test(input.archiveSHA256)) throw storageFail("invalid_publication_storage_key");
    const physicalKey = mapPublicationQuarantineStorageKey(input);
    let result: PublicationPresignedPut;
    try {
      result = await this.provider.presignImmutablePut({ physicalKey, contentLength: input.byteCount, checksumSha256: Buffer.from(input.archiveSHA256, "hex").toString("base64"), contentType: "application/zip", expiresInSeconds: 300, ifNoneMatch: "*" });
    } catch { throw storageFail("provider_unavailable"); }
    validatePut(result, input.byteCount, Buffer.from(input.archiveSHA256, "hex").toString("base64"));
    return Object.freeze({ url: result.url, headers: Object.freeze({ ...result.headers }) });
  }

  /** Captures a provider version once, then every archive validator `read`
   * requests that same version in bounded ranges. */
  async openExactQuarantine(input: { readonly allocationPublicID: string; readonly expectedVersion: string; readonly expectedByteCount: number; readonly expectedSHA256: string }): Promise<PublicationQuarantineObject> {
    if (!validVersion(input.expectedVersion) || !Number.isSafeInteger(input.expectedByteCount) || input.expectedByteCount < 1 || input.expectedByteCount > PUBLICATION_MAX_ARCHIVE_BYTES || !/^[a-f0-9]{64}$/u.test(input.expectedSHA256)) throw storageFail("invalid_publication_storage_key");
    const physicalKey = mapPublicationQuarantineStorageKey(input);
    let head: Awaited<ReturnType<PublicationObjectProvider["headCurrent"]>>;
    try { head = await this.provider.headCurrent({ physicalKey }); } catch { throw storageFail("provider_unavailable"); }
    if (!validVersion(head.versionId) || head.versionId !== input.expectedVersion || head.contentLength !== input.expectedByteCount || head.contentType !== "application/zip" || !SHA256_BASE64.test(head.checksumSha256) || Buffer.from(head.checksumSha256, "base64").toString("hex") !== input.expectedSHA256) throw storageFail("provider_mismatch");
    const reader: PublicationArchiveReader = Object.freeze({
      byteLength: head.contentLength,
      read: async (offset: number, length: number): Promise<Uint8Array> => {
        // A worker may materialize one independently bounded nested AI package
        // (512 MiB maximum) or a 32 MiB visual derivative. Public portal
        // delivery remains capped at four MiB in `readAuthorizedActiveRange`.
        if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(length) || offset < 0 || length < 0 || length > PUBLICATION_MAX_NESTED_AI_READY_BYTES || offset + length > head.contentLength) throw storageFail("invalid_publication_storage_key");
        try {
          const bytes = await this.provider.readRangeExact({ physicalKey, versionId: head.versionId, offset, length });
          if (!(bytes instanceof Uint8Array) || bytes.byteLength !== length) throw storageFail("provider_mismatch");
          return Uint8Array.from(bytes);
        } catch (error) {
          if (error instanceof PublicationStorageError) throw error;
          throw storageFail("provider_unavailable");
        }
      },
    });
    return Object.freeze({ versionId: head.versionId, byteCount: head.contentLength, reader });
  }

  /** The worker captures the provider's immutable current version only after
   * `publication_complete_v2` has transitioned a targetless allocation into a
   * claimed validation job. The API write role never calls this method. */
  async captureCurrentQuarantine(input: { readonly allocationPublicID: string; readonly expectedByteCount: number; readonly expectedSHA256: string }): Promise<string> {
    if (!Number.isSafeInteger(input.expectedByteCount) || input.expectedByteCount < 1 || input.expectedByteCount > PUBLICATION_MAX_ARCHIVE_BYTES || !/^[a-f0-9]{64}$/u.test(input.expectedSHA256)) throw storageFail("invalid_publication_storage_key");
    const physicalKey = mapPublicationQuarantineStorageKey(input);
    let head: Awaited<ReturnType<PublicationObjectProvider["headCurrent"]>>;
    try { head = await this.provider.headCurrent({ physicalKey }); } catch { throw storageFail("provider_unavailable"); }
    if (!validVersion(head.versionId) || head.contentLength !== input.expectedByteCount || head.contentType !== "application/zip" || !SHA256_BASE64.test(head.checksumSha256) || Buffer.from(head.checksumSha256, "base64").toString("hex") !== input.expectedSHA256) throw storageFail("provider_mismatch");
    return head.versionId;
  }

  async putActiveDerivative(input: { readonly allocationPublicID: string; readonly assetPublicID: string; readonly kind: PublicationActiveDerivativeKind; readonly bytes: Uint8Array; readonly contentType: PublicationContentType }): Promise<Readonly<{ readonly objectKey: string; readonly objectVersion: string }>> {
    // The worker is the only caller, but enforce its public derivative bounds
    // again at the provider boundary. A future caller cannot turn a JSON
    // presentation/geometry object or raster/PDF into a 512 MiB active blob;
    // only the closed nested AI-ready ZIP class needs that larger ceiling.
    const contract = activeDerivativeContract(input.kind);
    if (!(input.bytes instanceof Uint8Array) || input.bytes.byteLength < 1 || input.bytes.byteLength > contract.maximum || !contract.contentTypes.includes(input.contentType)) throw storageFail("invalid_publication_storage_key");
    const physicalKey = mapPublicationActiveStorageKey(input);
    let result: Readonly<{ readonly versionId: string }>;
    try {
      result = await this.provider.putImmutable({ physicalKey, bytes: Uint8Array.from(input.bytes), contentType: input.contentType, ifNoneMatch: "*" });
    } catch {
      // A retry may follow a worker crash after the immutable promotion but
      // before DB finalization. Reuse only an already-present byte-identical
      // derivative at the deterministic key; a substituted object fails.
      return this.#verifyActiveDerivative(physicalKey, input.bytes, input.contentType);
    }
    if (!validVersion(result.versionId)) throw storageFail("provider_mismatch");
    return this.#verifyActiveDerivative(physicalKey, input.bytes, input.contentType, result.versionId);
  }

  /** Called only after `portal_authorize_asset_v1` has returned an exact
   * object version.  The database finalizer must still run before these bytes
   * are emitted; this adapter never produces a URL. */
  async readAuthorizedActiveRange(input: { readonly objectKey: string; readonly objectVersion: string; readonly offset: number; readonly byteCount: number }): Promise<Uint8Array> {
    if (!activePhysicalKey(input.objectKey) || !validVersion(input.objectVersion) || !Number.isSafeInteger(input.offset) || !Number.isSafeInteger(input.byteCount) || input.offset < 0 || input.byteCount < 1 || input.byteCount > PUBLICATION_MAX_PROTECTED_CHUNK_BYTES) throw storageFail("invalid_publication_storage_key");
    try {
      const bytes = await this.provider.readRangeExact({ physicalKey: input.objectKey, versionId: input.objectVersion, offset: input.offset, length: input.byteCount });
      if (!(bytes instanceof Uint8Array) || bytes.byteLength !== input.byteCount) throw storageFail("provider_mismatch");
      return Uint8Array.from(bytes);
    } catch (error) {
      if (error instanceof PublicationStorageError) throw error;
      throw storageFail("provider_unavailable");
    }
  }

  async #verifyActiveDerivative(physicalKey: string, expected: Uint8Array, expectedContentType: PublicationContentType, expectedVersion?: string): Promise<Readonly<{ readonly objectKey: string; readonly objectVersion: string }>> {
    let head: Awaited<ReturnType<PublicationObjectProvider["headCurrent"]>>;
    try { head = await this.provider.headCurrent({ physicalKey }); } catch { throw storageFail("provider_unavailable"); }
    if (!validVersion(head.versionId) || (expectedVersion !== undefined && head.versionId !== expectedVersion) || head.contentLength !== expected.byteLength || head.contentType !== expectedContentType) throw storageFail("provider_mismatch");
    let verified: Uint8Array;
    try { verified = await this.provider.readRangeExact({ physicalKey, versionId: head.versionId, offset: 0, length: expected.byteLength }); } catch { throw storageFail("provider_unavailable"); }
    if (!(verified instanceof Uint8Array) || verified.byteLength !== expected.byteLength || !Buffer.from(verified).equals(Buffer.from(expected))) throw storageFail("provider_mismatch");
    return Object.freeze({ objectKey: physicalKey, objectVersion: head.versionId });
  }
}

function validatePut(value: PublicationPresignedPut, length: number, checksum: string): void {
  let url: URL; try { url = new URL(value.url); } catch { throw storageFail("provider_mismatch"); }
  if (url.protocol !== "https:" || url.username || url.password) throw storageFail("provider_mismatch");
  const normalized = new Map<string, string>();
  for (const [name, header] of Object.entries(value.headers)) { const key = name.toLowerCase(); if (normalized.has(key) || typeof header !== "string") throw storageFail("provider_mismatch"); normalized.set(key, header); }
  const required = new Map<string, string>([["content-length", String(length)], ["content-type", "application/zip"], ["x-amz-checksum-sha256", checksum], ["if-none-match", "*"]]);
  if (normalized.size !== required.size || [...required].some(([name, header]) => normalized.get(name) !== header)) throw storageFail("provider_mismatch");
}
function validVersion(value: unknown): value is string { return typeof value === "string" && Buffer.byteLength(value, "utf8") >= 1 && Buffer.byteLength(value, "utf8") <= 1_024 && !/[\u0000-\u001f\u007f-\u009f]/u.test(value); }
function activePhysicalKey(value: unknown): value is string { return typeof value === "string" && /^server\/published\/active\/v1\/pua_[A-Za-z0-9_-]{16,128}\/ast_[A-Za-z0-9_-]{16,128}\.bin$/u.test(value); }
function activeDerivativeContract(kind: unknown): Readonly<{ readonly contentTypes: readonly PublicationContentType[]; readonly maximum: number }> {
  switch (kind) {
  case "presentation":
  case "web_geometry": return Object.freeze({ contentTypes: ["application/json"] as const, maximum: PUBLICATION_MAX_PRESENTATION_BYTES });
  case "web_texture":
  case "selected_image":
  case "floor_plan":
  case "approved_concept": return Object.freeze({ contentTypes: ["image/png", "image/jpeg"] as const, maximum: PUBLICATION_MAX_ASSET_BYTES });
  case "floor_plan_pdf": return Object.freeze({ contentTypes: ["application/pdf"] as const, maximum: PUBLICATION_MAX_ASSET_BYTES });
  case "gallery_zip": return Object.freeze({ contentTypes: ["application/zip"] as const, maximum: PUBLICATION_MAX_ASSET_BYTES });
  case "ai_ready_package": return Object.freeze({ contentTypes: ["application/zip"] as const, maximum: PUBLICATION_MAX_NESTED_AI_READY_BYTES });
  default: throw storageFail("invalid_publication_storage_key");
  }
}
function storageFail(code: PublicationStorageError["code"]): never { throw new PublicationStorageError(code); }
