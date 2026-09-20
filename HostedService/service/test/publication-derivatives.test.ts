import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import test from "node:test";

import { validatePublicationArchive, type PublicationArchiveReader } from "../src/publication/archive-validator.js";
import { derivePublicationAssets, validatePassivePDF } from "../src/publication/derivatives.js";

const ROOT = resolve(process.cwd(), "fixtures", "publication");
const PUA = `pua_${"d".repeat(16)}`;

test("the active presentation rewrites only validated Core-local artifact references to immutable service ast_ IDs", async () => {
  const fixture = loadFixture("room-v2-ai-ready");
  const reader = memoryReader(fixture.archive);
  const archive = await validatePublicationArchive({ reader, expected: fixture.expected });
  const derivatives = await derivePublicationAssets({ reader, archive, allocationPublicID: PUA });
  const presentation = derivatives.find((asset) => asset.kind === "presentation");
  assert.notEqual(presentation, undefined);
  const document = JSON.parse(Buffer.from(presentation!.bytes).toString("utf8")) as unknown;
  const references = assetReferences(document);
  assert.ok(references.length > 0, "positive control reaches the real Core fixture's selected, concept, geometry, floor-plan, logo, and AI reference fields");
  assert.ok(references.every((reference) => /^ast_[A-Za-z0-9_-]{16,128}$/u.test(reference)), "portal JSON contains only service-issued immutable asset identifiers");
  assert.equal(JSON.stringify(document).includes("geometry-001"), false, "Core-local ledger names never leave the promoted portal presentation");
  assert.equal(JSON.stringify(document).includes("image-original"), false, "selected working-name canary is rewritten rather than exposed");
  const activeAssetIDs = new Set(derivatives.map((asset) => asset.assetPublicID));
  assert.ok(references.every((reference) => activeAssetIDs.has(reference)), "every presentation reference resolves to an actually promoted immutable object");
});

test("property portal promotion preserves the frozen independent-room order and disclaimer without inventing spatial continuity", async () => {
  const fixture = loadFixture("property-v1");
  const reader = memoryReader(fixture.archive);
  const archive = await validatePublicationArchive({ reader, expected: fixture.expected });
  const derivatives = await derivePublicationAssets({ reader, archive, allocationPublicID: `pua_${"e".repeat(16)}` });
  const presentation = derivatives.find((asset) => asset.kind === "presentation");
  assert.notEqual(presentation, undefined);
  const document = JSON.parse(Buffer.from(presentation!.bytes).toString("utf8")) as { readonly independentRoomNotice?: unknown; readonly rooms?: readonly { readonly roomKey?: unknown }[] };
  assert.equal(document.independentRoomNotice, "Rooms are presented independently; they do not share coordinates, alignment, connectivity, or reconstruction.");
  assert.deepEqual(document.rooms?.map((room) => room.roomKey), ["room-living", "room-kitchen"], "the portal preserves curation order rather than inferring a shared spatial graph");
  assert.equal(/sharedOrigin|connectivityGraph|alignmentTransform|globalCoordinates/iu.test(JSON.stringify(document)), false, "the property artifact contains no cross-room reconstruction claim");
  assert.ok(assetReferences(document).every((reference) => /^ast_[A-Za-z0-9_-]{16,128}$/u.test(reference)), "both independently curated rooms resolve only through active immutable assets");
});

test("static fallback PDF validation rejects action and attachment carriers", () => {
  const activePDF = Buffer.from("%PDF-1.4\n1 0 obj<</Type/Annot/A<</S/URI/URI(https://carrier.invalid)>>>>endobj\n%%EOF\n", "ascii");
  assert.throws(() => validatePassivePDF(activePDF), /invalid_derivative/u, "positive control puts an active URI action in an otherwise bounded PDF envelope");
});

function assetReferences(value: unknown): string[] {
  const output: string[] = [];
  const visit = (candidate: unknown): void => {
    if (Array.isArray(candidate)) { candidate.forEach(visit); return; }
    if (candidate === null || typeof candidate !== "object") return;
    for (const [key, child] of Object.entries(candidate as Record<string, unknown>)) {
      if ((key.endsWith("AssetID") || key.endsWith("AssetIDs")) && typeof child === "string") output.push(child);
      else if (key.endsWith("AssetIDs") && Array.isArray(child)) for (const id of child) if (typeof id === "string") output.push(id);
      visit(child);
    }
  };
  visit(value);
  return output;
}

function memoryReader(bytes: Uint8Array): PublicationArchiveReader {
  return Object.freeze({ byteLength: bytes.byteLength, read: async (offset: number, length: number) => Uint8Array.from(bytes.subarray(offset, offset + length)) });
}

interface FixtureExpectation {
  readonly archive: { readonly byteCount: number; readonly sha256: string };
  readonly publicationManifest: { readonly byteCount: number; readonly sha256: string };
  readonly presentation: { readonly byteCount: number; readonly sha256: string };
  readonly sourceBindingsSHA256: string;
  readonly selectionManifestSHA256: string;
  readonly approvalSHA256: string;
  readonly ledger: readonly { readonly path: string; readonly byteCount: number; readonly sha256: string; readonly mediaType: string }[];
}

function loadFixture(name: string): Readonly<{ readonly archive: Uint8Array; readonly expected: FixtureExpectation }> {
  const expectations = JSON.parse(readFileSync(resolve(ROOT, "expectations.json"), "utf8")) as { readonly fixtures: readonly Readonly<{ readonly name: string } & FixtureExpectation>[] };
  const expected = expectations.fixtures.find((fixture) => fixture.name === name);
  assert.notEqual(expected, undefined);
  return Object.freeze({ archive: Uint8Array.from(Buffer.from(readFileSync(resolve(ROOT, `${name}.zip.base64`), "utf8").trim(), "base64")), expected: expected! });
}
