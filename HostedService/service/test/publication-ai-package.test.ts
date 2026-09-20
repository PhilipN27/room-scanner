import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  PublicationArchiveValidationError,
  type AIReadyPackageBinding,
  type ValidatedPublicationSourceBinding,
  validateAIReadyPackage,
} from "../src/publication/archive-validator.js";
import { canonicalJson, canonicalJsonSHA256, sha256Bytes } from "../src/publication/contracts.js";

test("AI-ready package validator rejects a self-consistent raw-confidence plan rather than trusting a renamed private archive", async () => {
  const outer = Buffer.from(readFileSync("fixtures/publication/room-v2-ai-ready.zip.base64", "utf8").trim(), "base64");
  const outerManifest = JSON.parse(Buffer.from(storeEntry(outer, "publication-manifest.json")).toString("utf8")) as {
    readonly sourceBindings: readonly ValidatedPublicationSourceBinding[];
    readonly assets: readonly { readonly assetID: string; readonly aiReadyPackageBinding?: AIReadyPackageBinding }[];
  };
  const original = storeEntry(outer, "assets/ai-ready-001.zip");
  const manifest = JSON.parse(Buffer.from(storeEntry(original, "manifest.json")).toString("utf8")) as Record<string, unknown>;
  const rawClass = "rawConfidence";
  manifest.artifactPlan = (manifest.artifactPlan as Record<string, unknown>[]).map((slot) => ({ ...slot, artifactClass: slot.artifactClass === "canonicalView" ? rawClass : slot.artifactClass }));
  manifest.artifacts = (manifest.artifacts as Record<string, unknown>[]).map((artifact) => ({ ...artifact, artifactClass: artifact.artifactClass === "canonicalView" ? rawClass : artifact.artifactClass }));
  const artifactPlanSHA256 = canonicalJsonSHA256({
    schemaVersion: manifest.schemaVersion,
    contractKind: manifest.contractKind,
    profile: manifest.profile,
    sourceRevision: manifest.sourceRevision,
    slots: manifest.artifactPlan,
  });
  const selectionSHA256 = canonicalJsonSHA256(manifest.artifacts);
  manifest.artifactPlanSHA256 = artifactPlanSHA256; manifest.selectionSHA256 = selectionSHA256;
  const disclosure = manifest.disclosureReview as Record<string, unknown>;
  disclosure.reviewedArtifactPlanSHA256 = artifactPlanSHA256; disclosure.reviewedSelectionSHA256 = selectionSHA256;
  const rewrittenManifest = Buffer.from(canonicalJson(manifest), "utf8");
  assert.equal(rewrittenManifest.byteLength, storeEntry(original, "manifest.json").byteLength, "the mutation preserves ZIP entry lengths so the test reaches real manifest policy, not just a ZIP framing failure");
  const mutated = replaceStoredEntry(original, "manifest.json", rewrittenManifest);
  const originalBinding = outerManifest.assets.find((asset) => asset.assetID === "ai-ready-001")?.aiReadyPackageBinding;
  assert.notEqual(originalBinding, undefined, "positive control reaches the outer Core AI binding");
  const binding: AIReadyPackageBinding = {
    ...originalBinding!, manifestSHA256: sha256Bytes(rewrittenManifest), artifactPlanSHA256, selectionSHA256,
  };
  await assert.rejects(
    () => validateAIReadyPackage(byteReader(mutated), binding, outerManifest.sourceBindings),
    (error: unknown) => error instanceof PublicationArchiveValidationError && error.code === "ai_package",
    "recomputed manifest/selection/binding identities must not turn a raw class into an AI-ready package",
  );
});

function byteReader(bytes: Uint8Array) { return Object.freeze({ byteLength: bytes.byteLength, read: async (offset: number, length: number) => Uint8Array.from(bytes.subarray(offset, offset + length)) }); }
function storeEntry(bytes: Uint8Array, wanted: string): Uint8Array {
  let offset = 0;
  while (offset + 30 <= bytes.byteLength && le32(bytes, offset) === 0x0403_4b50) {
    const nameLength = le16(bytes, offset + 26); const extraLength = le16(bytes, offset + 28); const byteCount = le32(bytes, offset + 18); const dataOffset = offset + 30 + nameLength + extraLength;
    const name = Buffer.from(bytes.subarray(offset + 30, offset + 30 + nameLength)).toString("utf8");
    if (name === wanted) return Uint8Array.from(bytes.subarray(dataOffset, dataOffset + byteCount));
    offset = dataOffset + byteCount;
  }
  throw new Error(`missing stored entry ${wanted}`);
}
function replaceStoredEntry(input: Uint8Array, wanted: string, replacement: Uint8Array): Uint8Array {
  const bytes = Uint8Array.from(input); let offset = 0; let replaced = false;
  while (offset + 30 <= bytes.byteLength && le32(bytes, offset) === 0x0403_4b50) {
    const nameLength = le16(bytes, offset + 26); const extraLength = le16(bytes, offset + 28); const byteCount = le32(bytes, offset + 18); const dataOffset = offset + 30 + nameLength + extraLength;
    const name = Buffer.from(bytes.subarray(offset + 30, offset + 30 + nameLength)).toString("utf8");
    if (name === wanted) { assert.equal(replacement.byteLength, byteCount); bytes.set(replacement, dataOffset); write32(bytes, offset + 14, crc32(replacement)); replaced = true; break; }
    offset = dataOffset + byteCount;
  }
  assert.equal(replaced, true, "positive control replaces the intended nested manifest entry");
  const eocd = findEOCD(bytes); const central = le32(bytes, eocd + 16); let cursor = central; let updatedCentral = false;
  while (cursor + 46 <= eocd && le32(bytes, cursor) === 0x0201_4b50) {
    const nameLength = le16(bytes, cursor + 28); const extraLength = le16(bytes, cursor + 30); const commentLength = le16(bytes, cursor + 32); const name = Buffer.from(bytes.subarray(cursor + 46, cursor + 46 + nameLength)).toString("utf8");
    if (name === wanted) { write32(bytes, cursor + 16, crc32(replacement)); updatedCentral = true; break; }
    cursor += 46 + nameLength + extraLength + commentLength;
  }
  assert.equal(updatedCentral, true, "positive control reaches matching central-directory CRC");
  return bytes;
}
function findEOCD(bytes: Uint8Array): number { for (let offset = bytes.byteLength - 22; offset >= 0; offset -= 1) if (le32(bytes, offset) === 0x0605_4b50 && offset + 22 + le16(bytes, offset + 20) === bytes.byteLength) return offset; throw new Error("missing EOCD"); }
function le16(bytes: Uint8Array, offset: number): number { return (bytes[offset] ?? 0) | ((bytes[offset + 1] ?? 0) << 8); }
function le32(bytes: Uint8Array, offset: number): number { return (((bytes[offset] ?? 0) | ((bytes[offset + 1] ?? 0) << 8) | ((bytes[offset + 2] ?? 0) << 16) | ((bytes[offset + 3] ?? 0) << 24)) >>> 0); }
function write32(bytes: Uint8Array, offset: number, value: number): void { bytes[offset] = value & 0xff; bytes[offset + 1] = (value >>> 8) & 0xff; bytes[offset + 2] = (value >>> 16) & 0xff; bytes[offset + 3] = (value >>> 24) & 0xff; }
const CRC = Array.from({ length: 256 }, (_, index) => { let value = index; for (let bit = 0; bit < 8; bit += 1) value = (value & 1) === 1 ? (value >>> 1) ^ 0xedb8_8320 : value >>> 1; return value >>> 0; });
function crc32(bytes: Uint8Array): number { let value = 0xffff_ffff; for (const byte of bytes) value = (value >>> 8) ^ (CRC[(value ^ byte) & 0xff] ?? 0); return (value ^ 0xffff_ffff) >>> 0; }
