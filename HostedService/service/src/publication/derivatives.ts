import { createHash } from "node:crypto";

import {
  PUBLICATION_MAX_ASSET_BYTES,
  PUBLICATION_MAX_PRESENTATION_BYTES,
  canonicalJson,
  sha256Bytes,
} from "./contracts.js";
import {
  readValidatedPublicationArchiveEntry,
  type PublicationArchiveReader,
  type ValidatedPublicationArchive,
  type ValidatedPublicationAsset,
} from "./archive-validator.js";

export type PublicationPersistedAssetKind = "presentation" | "web_geometry" | "web_texture" | "selected_image" | "floor_plan" | "approved_concept" | "floor_plan_pdf" | "gallery_zip" | "ai_ready_package";
export type PublicationDownloadKind = "floor_plan_pdf" | "gallery_zip" | "ai_ready_package";

export interface DerivedPublicationAsset {
  readonly assetPublicID: string;
  readonly kind: PublicationPersistedAssetKind;
  readonly contentType: "application/json" | "image/png" | "image/jpeg" | "application/pdf" | "application/zip";
  readonly bytes: Uint8Array;
  readonly sha256: string;
  readonly downloadKind?: PublicationDownloadKind;
}

/** Derivatives start from the revalidated, empty-allowlist archive record;
 * they never inspect a private project archive or receive caller-authored
 * PDF/gallery input. */
export async function derivePublicationAssets(input: { readonly reader: PublicationArchiveReader; readonly archive: ValidatedPublicationArchive; readonly allocationPublicID: string }): Promise<readonly DerivedPublicationAsset[]> {
  if (!/^pua_[A-Za-z0-9_-]{16,128}$/u.test(input.allocationPublicID)) throw new PublicationDerivativeError("invalid_input");
  const output: DerivedPublicationAsset[] = [];
  const used = new Set<string>();
  const add = (asset: DerivedPublicationAsset): void => {
    const maximum = asset.kind === "ai_ready_package" ? 536_870_912 : asset.kind === "presentation" || asset.kind === "web_geometry" ? PUBLICATION_MAX_PRESENTATION_BYTES : PUBLICATION_MAX_ASSET_BYTES;
    if (used.has(asset.assetPublicID) || asset.bytes.byteLength < 1 || asset.bytes.byteLength > maximum || sha256Bytes(asset.bytes) !== asset.sha256) throw new PublicationDerivativeError("invalid_derivative");
    used.add(asset.assetPublicID); output.push(Object.freeze(asset));
  };

  // Core's allowlisted ledger uses deterministic archive-local asset names
  // (for example `geometry-001`). Those names are never portal capabilities.
  // The promoted presentation preserves exactly the validated public document
  // while replacing only its known asset-reference leaves with deterministic
  // service `ast_` IDs that are promoted below.
  const sourceAssetIDs = new Map(input.archive.assets.map((asset) => [asset.assetID, stableAssetID(input.allocationPublicID, `source:${asset.assetID}`)] as const));
  const presentation = Uint8Array.from(Buffer.from(rewritePresentationAssetReferences(input.archive.presentationText, sourceAssetIDs), "utf8"));
  if (presentation.byteLength < 1 || presentation.byteLength > PUBLICATION_MAX_PRESENTATION_BYTES) throw new PublicationDerivativeError("invalid_derivative");
  add({ assetPublicID: stableAssetID(input.allocationPublicID, "presentation"), kind: "presentation", contentType: "application/json", bytes: presentation, sha256: sha256Bytes(presentation) });

  const galleryEntries: Array<Readonly<{ readonly path: string; readonly bytes: Uint8Array }>> = [];
  for (const asset of input.archive.assets) {
    const bytes = await readValidatedPublicationArchiveEntry(input.reader, asset.relativePath, asset.assetClass === "aiReadyPackage" ? 536_870_912 : PUBLICATION_MAX_ASSET_BYTES);
    if (bytes.byteLength !== asset.byteCount || sha256Bytes(bytes) !== asset.sha256) throw new PublicationDerivativeError("invalid_derivative");
    const mapped = mapSourceAsset(input.allocationPublicID, asset, bytes);
    add(mapped);
    if (asset.assetClass === "selectedImage" || asset.assetClass === "approvedConcept" || asset.assetClass === "floorPlan") {
      galleryEntries.push(Object.freeze({ path: galleryPath(asset), bytes }));
    }
  }

  if (input.archive.downloads.floorPlanPDF) {
    const pdf = createPassivePDF(); validatePassivePDF(pdf);
    add({ assetPublicID: stableAssetID(input.allocationPublicID, "fallback-pdf"), kind: "floor_plan_pdf", downloadKind: "floor_plan_pdf", contentType: "application/pdf", bytes: pdf, sha256: sha256Bytes(pdf) });
  }
  if (input.archive.downloads.galleryZIP) {
    const gallery = createStoredGalleryZip(galleryEntries); validateDerivedGalleryZip(gallery, galleryEntries.map((entry) => entry.path));
    add({ assetPublicID: stableAssetID(input.allocationPublicID, "fallback-gallery"), kind: "gallery_zip", downloadKind: "gallery_zip", contentType: "application/zip", bytes: gallery, sha256: sha256Bytes(gallery) });
  }
  return Object.freeze(output);
}

export class PublicationDerivativeError extends Error {
  constructor(readonly code: "invalid_input" | "invalid_derivative") { super(code); this.name = "PublicationDerivativeError"; }
}

function mapSourceAsset(allocationID: string, asset: ValidatedPublicationAsset, bytes: Uint8Array): DerivedPublicationAsset {
  const source = asset.assetClass;
  const kind: PublicationPersistedAssetKind = source === "webGeometry" ? "web_geometry"
    : source === "webTexture" ? "web_texture"
      : source === "selectedImage" || source === "brandingLogo" ? "selected_image"
        : source === "floorPlan" ? "floor_plan"
          : source === "approvedConcept" ? "approved_concept" : "ai_ready_package";
  const contentType = source === "webGeometry" ? "application/json"
    : source === "aiReadyPackage" ? "application/zip"
      : asset.mediaType === "image/jpeg" ? "image/jpeg" : "image/png";
  const downloadKind = source === "aiReadyPackage" ? "ai_ready_package" as const : undefined;
  return Object.freeze({ assetPublicID: stableAssetID(allocationID, `source:${asset.assetID}`), kind, contentType, bytes: Uint8Array.from(bytes), sha256: asset.sha256, ...(downloadKind === undefined ? {} : { downloadKind }) });
}

function rewritePresentationAssetReferences(text: string, mappedAssetIDs: ReadonlyMap<string, string>): string {
  let parsed: unknown;
  try { parsed = JSON.parse(text); } catch { throw new PublicationDerivativeError("invalid_derivative"); }
  const rewrite = (value: unknown): unknown => {
    if (Array.isArray(value)) return value.map(rewrite);
    if (value === null || typeof value !== "object" || Object.getPrototypeOf(value) !== Object.prototype) return value;
    const output: Record<string, unknown> = {};
    for (const [key, child] of Object.entries(value as Readonly<Record<string, unknown>>)) {
      if (key.endsWith("AssetIDs")) {
        if (!Array.isArray(child)) throw new PublicationDerivativeError("invalid_derivative");
        output[key] = child.map((assetID) => remapAssetID(assetID, mappedAssetIDs));
      } else if (key.endsWith("AssetID")) {
        output[key] = remapAssetID(child, mappedAssetIDs);
      } else {
        output[key] = rewrite(child);
      }
    }
    return output;
  };
  try { return canonicalJson(rewrite(parsed)); } catch (error) { if (error instanceof PublicationDerivativeError) throw error; throw new PublicationDerivativeError("invalid_derivative"); }
}

function remapAssetID(value: unknown, mappedAssetIDs: ReadonlyMap<string, string>): string {
  if (typeof value !== "string") throw new PublicationDerivativeError("invalid_derivative");
  const mapped = mappedAssetIDs.get(value);
  if (mapped === undefined) throw new PublicationDerivativeError("invalid_derivative");
  return mapped;
}

/** Core asset identifiers are local package names, never service public IDs.
 * A deterministic one-way mapping makes worker retry safe without placing a
 * package identifier or UUID into a portal-visible object key. */
export function stableAssetID(allocationPublicID: string, sourceName: string): string {
  if (!/^pua_[A-Za-z0-9_-]{16,128}$/u.test(allocationPublicID) || typeof sourceName !== "string" || sourceName.length < 1 || sourceName.length > 256) throw new PublicationDerivativeError("invalid_input");
  return `ast_${createHash("sha256").update("roomscan-publication-asset-v1\u0000", "utf8").update(allocationPublicID, "utf8").update("\u0000", "utf8").update(sourceName, "utf8").digest("base64url")}`;
}

function galleryPath(asset: ValidatedPublicationAsset): string {
  const extension = asset.mediaType === "image/jpeg" ? "jpg" : "png";
  return `gallery/${asset.assetID}.${extension}`;
}

/** A fixed passive document has no caller-controlled PDF syntax, action,
 * attachment, URL, script, or form surface.  The rich interactive content is
 * deliberately the portal presentation, not a second parser target. */
function createPassivePDF(): Uint8Array {
  const content = "BT /F1 16 Tf 72 720 Td (RoomScanStudio published presentation) Tj 0 -28 Td /F1 11 Tf (Open this presentation in the RoomScanStudio portal.) Tj ET";
  const objects = [
    "1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj",
    "2 0 obj<</Type/Pages/Count 1/Kids[3 0 R]>>endobj",
    "3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]/Resources<</Font<</F1 4 0 R>>>>/Contents 5 0 R>>endobj",
    "4 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj",
    `5 0 obj<</Length ${Buffer.byteLength(content, "ascii")}>>stream\n${content}\nendstream\nendobj`,
  ];
  let output = "%PDF-1.4\n"; const offsets = [0];
  for (const object of objects) { offsets.push(Buffer.byteLength(output, "ascii")); output += `${object}\n`; }
  const xref = Buffer.byteLength(output, "ascii"); output += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n${offsets.slice(1).map((offset) => `${String(offset).padStart(10, "0")} 00000 n \n`).join("")}trailer<</Size ${objects.length + 1}/Root 1 0 R>>\nstartxref\n${xref}\n%%EOF\n`;
  return Uint8Array.from(Buffer.from(output, "ascii"));
}

export function validatePassivePDF(bytes: Uint8Array): void {
  if (!(bytes instanceof Uint8Array) || bytes.byteLength < 32 || bytes.byteLength > PUBLICATION_MAX_ASSET_BYTES) throw new PublicationDerivativeError("invalid_derivative");
  const text = Buffer.from(bytes).toString("latin1");
  if (!text.startsWith("%PDF-1.4\n") || !text.endsWith("%%EOF\n") || /\/(?:JavaScript|JS|OpenAction|AA|Launch|URI|GoTo(?:R|E)?|Named|SubmitForm|ResetForm|ImportData|EmbeddedFile|Filespec|RichMedia|Movie|Sound|XFA|AcroForm|Annot|Action)\b/u.test(text)) throw new PublicationDerivativeError("invalid_derivative");
}

function createStoredGalleryZip(entries: readonly Readonly<{ readonly path: string; readonly bytes: Uint8Array }>[]): Uint8Array {
  const unique = new Set<string>(); let offset = 0; const locals: Uint8Array[] = []; const centrals: Uint8Array[] = [];
  for (const entry of entries) {
    if (!/^gallery\/[A-Za-z0-9_.-]+\.(?:png|jpg)$/u.test(entry.path) || unique.has(entry.path) || !(entry.bytes instanceof Uint8Array)) throw new PublicationDerivativeError("invalid_derivative");
    unique.add(entry.path); const name = Buffer.from(entry.path, "utf8"); const checksum = crc32(entry.bytes);
    const local = new Uint8Array(30 + name.byteLength + entry.bytes.byteLength); write32(local, 0, 0x0403_4b50); write16(local, 4, 20); write16(local, 6, 0x0800); write16(local, 8, 0); write32(local, 14, checksum); write32(local, 18, entry.bytes.byteLength); write32(local, 22, entry.bytes.byteLength); write16(local, 26, name.byteLength); local.set(name, 30); local.set(entry.bytes, 30 + name.byteLength); locals.push(local);
    const central = new Uint8Array(46 + name.byteLength); write32(central, 0, 0x0201_4b50); write16(central, 4, 0x0314); write16(central, 6, 20); write16(central, 8, 0x0800); write16(central, 10, 0); write32(central, 16, checksum); write32(central, 20, entry.bytes.byteLength); write32(central, 24, entry.bytes.byteLength); write16(central, 28, name.byteLength); write32(central, 42, offset); central.set(name, 46); centrals.push(central); offset += local.byteLength;
  }
  const centralOffset = offset; const centralBytes = centrals.reduce((sum, value) => sum + value.byteLength, 0); const output = new Uint8Array(offset + centralBytes + 22); let write = 0; for (const local of locals) { output.set(local, write); write += local.byteLength; } for (const central of centrals) { output.set(central, write); write += central.byteLength; } write32(output, write, 0x0605_4b50); write16(output, write + 8, entries.length); write16(output, write + 10, entries.length); write32(output, write + 12, centralBytes); write32(output, write + 16, centralOffset); return output;
}

export function validateDerivedGalleryZip(bytes: Uint8Array, expectedPaths: readonly string[]): void {
  if (!(bytes instanceof Uint8Array) || bytes.byteLength < 22 || bytes.byteLength > PUBLICATION_MAX_ASSET_BYTES || new Set(expectedPaths).size !== expectedPaths.length) throw new PublicationDerivativeError("invalid_derivative");
  let eocd = -1; for (let index = bytes.byteLength - 22; index >= 0; index -= 1) if (le32(bytes, index) === 0x0605_4b50 && index + 22 + le16(bytes, index + 20) === bytes.byteLength) { eocd = index; break; }
  if (eocd < 0 || le16(bytes, eocd + 4) !== 0 || le16(bytes, eocd + 6) !== 0 || le16(bytes, eocd + 8) !== expectedPaths.length || le16(bytes, eocd + 10) !== expectedPaths.length || le16(bytes, eocd + 20) !== 0) throw new PublicationDerivativeError("invalid_derivative");
  const centralSize = le32(bytes, eocd + 12); const centralOffset = le32(bytes, eocd + 16); if (centralOffset + centralSize !== eocd) throw new PublicationDerivativeError("invalid_derivative");
  const paths: string[] = []; let cursor = centralOffset; let localEnd = 0;
  while (cursor < eocd) {
    if (cursor + 46 > eocd || le32(bytes, cursor) !== 0x0201_4b50 || le16(bytes, cursor + 8) !== 0x0800 || le16(bytes, cursor + 10) !== 0 || le16(bytes, cursor + 30) !== 0 || le16(bytes, cursor + 32) !== 0) throw new PublicationDerivativeError("invalid_derivative");
    const nameLength = le16(bytes, cursor + 28); const localOffset = le32(bytes, cursor + 42); const count = le32(bytes, cursor + 24); const checksum = le32(bytes, cursor + 16); const name = Buffer.from(bytes.subarray(cursor + 46, cursor + 46 + nameLength)).toString("utf8");
    if (!/^gallery\/[A-Za-z0-9_.-]+\.(?:png|jpg)$/u.test(name) || localOffset !== localEnd || localOffset + 30 > centralOffset || le32(bytes, localOffset) !== 0x0403_4b50 || le16(bytes, localOffset + 6) !== 0x0800 || le16(bytes, localOffset + 8) !== 0 || le32(bytes, localOffset + 18) !== count || le32(bytes, localOffset + 22) !== count || le16(bytes, localOffset + 28) !== 0) throw new PublicationDerivativeError("invalid_derivative");
    const localNameLength = le16(bytes, localOffset + 26); const localName = Buffer.from(bytes.subarray(localOffset + 30, localOffset + 30 + localNameLength)).toString("utf8"); const data = bytes.subarray(localOffset + 30 + localNameLength, localOffset + 30 + localNameLength + count);
    if (localName !== name || data.byteLength !== count || crc32(data) !== checksum) throw new PublicationDerivativeError("invalid_derivative");
    paths.push(name); localEnd = localOffset + 30 + localNameLength + count; cursor += 46 + nameLength;
  }
  if (cursor !== eocd || localEnd !== centralOffset || paths.join("\u0000") !== expectedPaths.join("\u0000")) throw new PublicationDerivativeError("invalid_derivative");
}

const CRC = Array.from({ length: 256 }, (_, index) => { let value = index; for (let bit = 0; bit < 8; bit += 1) value = (value & 1) === 1 ? (value >>> 1) ^ 0xedb8_8320 : value >>> 1; return value >>> 0; });
function crc32(bytes: Uint8Array): number { let value = 0xffff_ffff; for (const byte of bytes) value = (value >>> 8) ^ (CRC[(value ^ byte) & 0xff] ?? 0); return (value ^ 0xffff_ffff) >>> 0; }
function write16(bytes: Uint8Array, offset: number, value: number): void { bytes[offset] = value & 0xff; bytes[offset + 1] = (value >>> 8) & 0xff; }
function write32(bytes: Uint8Array, offset: number, value: number): void { bytes[offset] = value & 0xff; bytes[offset + 1] = (value >>> 8) & 0xff; bytes[offset + 2] = (value >>> 16) & 0xff; bytes[offset + 3] = (value >>> 24) & 0xff; }
function le16(bytes: Uint8Array, offset: number): number { return (bytes[offset] ?? 0) | ((bytes[offset + 1] ?? 0) << 8); }
function le32(bytes: Uint8Array, offset: number): number { return (((bytes[offset] ?? 0) | ((bytes[offset + 1] ?? 0) << 8) | ((bytes[offset + 2] ?? 0) << 16) | ((bytes[offset + 3] ?? 0) << 24)) >>> 0); }
