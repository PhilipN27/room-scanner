import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

import { PROJECT_SYNC_MAX_ARCHIVE_BYTES } from "../../src/contracts/project-sync.js";

interface StoredEntry {
  readonly path: string;
  readonly bytes: Uint8Array;
}

export interface ExactWorkingArchiveFixture {
  readonly archive: Uint8Array;
  readonly workingManifestSha256: string;
  readonly archiveSha256: string;
}

/**
 * Builds a valid exact-ceiling archive by starting from the real Core fixture,
 * extending its nested backup ledger with one benign package file, and then
 * rebuilding every affected content-addressed manifest. This is fixture
 * plumbing only; the worker still invokes the production validator.
 */
export async function createExactWorkingArchiveFixture(): Promise<ExactWorkingArchiveFixture> {
  const fixturePath = resolve(
    process.cwd(),
    "../RoomScanCore/Tests/RoomScanCoreTests/Fixtures/ProfessionalSync/working-set-v1.zip.base64",
  );
  const original = Buffer.from((await readFile(fixturePath, "utf8")).trim(), "base64");
  const outerBase = readStoredZip(original);
  const packageIndex = outerBase.findIndex((entry) => entry.path === "package-backup.zip");
  const manifestIndex = outerBase.findIndex((entry) => entry.path === "working-set-manifest.json");
  if (packageIndex < 0 || manifestIndex < 0) throw new Error("invalid_project_sync_ceiling_fixture");
  const originalManifest = parseJson(outerBase[manifestIndex]!.bytes);
  const nestedBase = readStoredZip(outerBase[packageIndex]!.bytes);
  const nestedManifestIndex = nestedBase.findIndex((entry) => entry.path === "backup-manifest.json");
  if (nestedManifestIndex < 0) throw new Error("invalid_project_sync_ceiling_fixture");
  const originalNestedManifest = parseJson(nestedBase[nestedManifestIndex]!.bytes);

  // ZIP/JSON metadata size is stable once all byte-count fields are eight
  // digits, so the small correction loop converges without guessing an input.
  let paddingByteCount = PROJECT_SYNC_MAX_ARCHIVE_BYTES - original.byteLength - 20_000;
  for (let attempt = 0; attempt < 8; attempt += 1) {
    if (!Number.isSafeInteger(paddingByteCount) || paddingByteCount < 1) {
      throw new Error("invalid_project_sync_ceiling_fixture");
    }
    const padding = Buffer.allocUnsafe(paddingByteCount).fill(0);
    const nestedManifest = structuredClone(originalNestedManifest) as Record<string, unknown>;
    const nestedEntries = nestedManifest.entries;
    if (!Array.isArray(nestedEntries)) throw new Error("invalid_project_sync_ceiling_fixture");
    nestedEntries.push({
      archivePath: "package/files/file-0009.bin",
      byteCount: padding.byteLength,
      mediaType: "application/octet-stream",
      packageRelativePath: "attachments/working-set-padding.bin",
      sha256Hex: sha256(padding),
    });
    const nestedManifestBytes = utf8(canonicalJson(nestedManifest));
    const nested = nestedBase.map((entry, index) => index === nestedManifestIndex
      ? { path: entry.path, bytes: nestedManifestBytes }
      : entry,
    );
    nested.push({ path: "package/files/file-0009.bin", bytes: padding });
    const nestedArchive = buildStoredZip(nested);

    const workingManifest = structuredClone(originalManifest) as Record<string, unknown>;
    const descriptor = workingManifest.packageDescriptor;
    const ledger = workingManifest.entries;
    if (!isRecord(descriptor) || !Array.isArray(ledger)) throw new Error("invalid_project_sync_ceiling_fixture");
    const nestedManifestDigest = sha256(nestedManifestBytes);
    descriptor.archiveByteCount = nestedArchive.byteLength;
    descriptor.archiveSHA256 = sha256(nestedArchive);
    descriptor.manifestSHA256 = nestedManifestDigest;
    descriptor.snapshotID = nestedManifestDigest;
    descriptor.fileCount = nestedEntries.length;
    descriptor.uncompressedByteCount = Number(descriptor.uncompressedByteCount) + padding.byteLength;
    const packageLedger = ledger.find((entry) => isRecord(entry) && entry.path === "package-backup.zip");
    if (!isRecord(packageLedger)) throw new Error("invalid_project_sync_ceiling_fixture");
    packageLedger.byteCount = nestedArchive.byteLength;
    packageLedger.sha256 = sha256(nestedArchive);
    const workingManifestBytes = utf8(canonicalJson(workingManifest));
    const outer = outerBase.map((entry, index) => {
      if (index === packageIndex) return { path: entry.path, bytes: nestedArchive };
      if (index === manifestIndex) return { path: entry.path, bytes: workingManifestBytes };
      return entry;
    });
    const archive = buildStoredZip(outer);
    const correction = PROJECT_SYNC_MAX_ARCHIVE_BYTES - archive.byteLength;
    if (correction === 0) {
      return Object.freeze({
        archive,
        workingManifestSha256: sha256(workingManifestBytes),
        archiveSha256: sha256(archive),
      });
    }
    paddingByteCount += correction;
  }
  throw new Error("project_sync_ceiling_fixture_did_not_converge");
}

function readStoredZip(input: Uint8Array): StoredEntry[] {
  const entries: StoredEntry[] = [];
  let offset = 0;
  while (offset + 30 <= input.byteLength && u32(input, offset) === 0x04034b50) {
    const flags = u16(input, offset + 6);
    const method = u16(input, offset + 8);
    const nameLength = u16(input, offset + 26);
    const extraLength = u16(input, offset + 28);
    const byteCount = u32(input, offset + 18);
    const bodyStart = offset + 30 + nameLength + extraLength;
    const bodyEnd = bodyStart + byteCount;
    if ((flags !== 0 && flags !== 0x0800) || method !== 0 || bodyEnd > input.byteLength) {
      throw new Error("invalid_project_sync_ceiling_fixture");
    }
    entries.push(Object.freeze({
      path: Buffer.from(input.buffer, input.byteOffset + offset + 30, nameLength).toString("utf8"),
      bytes: input.subarray(bodyStart, bodyEnd),
    }));
    offset = bodyEnd;
  }
  if (entries.length === 0) throw new Error("invalid_project_sync_ceiling_fixture");
  return entries;
}

function buildStoredZip(entries: readonly StoredEntry[]): Uint8Array {
  const locals: Buffer[] = [];
  const central: Buffer[] = [];
  const records: Array<Readonly<{ readonly name: Buffer; readonly bytes: Buffer; readonly crc: number; readonly offset: number }>> = [];
  let offset = 0;
  for (const entry of entries) {
    const name = Buffer.from(entry.path, "utf8");
    const bytes = Buffer.from(entry.bytes.buffer, entry.bytes.byteOffset, entry.bytes.byteLength);
    const crc = crc32(bytes);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(0, 6);
    local.writeUInt16LE(0, 8);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(bytes.byteLength, 18);
    local.writeUInt32LE(bytes.byteLength, 22);
    local.writeUInt16LE(name.byteLength, 26);
    locals.push(local, name, bytes);
    records.push(Object.freeze({ name, bytes, crc, offset }));
    offset += local.byteLength + name.byteLength + bytes.byteLength;
  }
  const centralOffset = offset;
  for (const record of records) {
    const header = Buffer.alloc(46);
    header.writeUInt32LE(0x02014b50, 0);
    header.writeUInt16LE(20, 4);
    header.writeUInt16LE(20, 6);
    header.writeUInt16LE(0, 8);
    header.writeUInt32LE(record.crc, 16);
    header.writeUInt32LE(record.bytes.byteLength, 20);
    header.writeUInt32LE(record.bytes.byteLength, 24);
    header.writeUInt16LE(record.name.byteLength, 28);
    header.writeUInt32LE(record.offset, 42);
    central.push(header, record.name);
    offset += header.byteLength + record.name.byteLength;
  }
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(entries.length, 8);
  eocd.writeUInt16LE(entries.length, 10);
  eocd.writeUInt32LE(offset - centralOffset, 12);
  eocd.writeUInt32LE(centralOffset, 16);
  return Buffer.concat([...locals, ...central, eocd]);
}

function canonicalJson(value: unknown): string {
  if (value === null || typeof value === "boolean" || typeof value === "number" || typeof value === "string") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (!isRecord(value)) throw new Error("invalid_project_sync_ceiling_fixture");
  return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(",")}}`;
}

function parseJson(bytes: Uint8Array): Record<string, unknown> {
  const value = JSON.parse(Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength).toString("utf8")) as unknown;
  if (!isRecord(value)) throw new Error("invalid_project_sync_ceiling_fixture");
  return value;
}

function utf8(value: string): Uint8Array { return Buffer.from(value, "utf8"); }
function sha256(bytes: Uint8Array): string { return createHash("sha256").update(bytes).digest("hex"); }
function u16(input: Uint8Array, offset: number): number { return input[offset]! | (input[offset + 1]! << 8); }
function u32(input: Uint8Array, offset: number): number { return (input[offset]! | (input[offset + 1]! << 8) | (input[offset + 2]! << 16) | (input[offset + 3]! << 24)) >>> 0; }
function isRecord(value: unknown): value is Record<string, unknown> { return value !== null && typeof value === "object" && !Array.isArray(value); }

// The ceiling oracle rebuilds a 64 MiB stored ZIP, potentially more than once
// while its metadata lengths converge. Match the production validator's
// table-driven CRC32 so fixture construction stays outside the worker's
// measured thirty-second envelope without changing any generated ZIP bytes.
const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let index = 0; index < table.length; index += 1) {
    let value = index;
    for (let bit = 0; bit < 8; bit += 1) value = (value & 1) === 1 ? (value >>> 1) ^ 0xedb88320 : value >>> 1;
    table[index] = value >>> 0;
  }
  return table;
})();

function crc32(bytes: Uint8Array): number {
  let value = 0xffffffff;
  for (const byte of bytes) value = (CRC_TABLE[(value ^ byte) & 0xff] ?? 0) ^ (value >>> 8);
  return (value ^ 0xffffffff) >>> 0;
}
