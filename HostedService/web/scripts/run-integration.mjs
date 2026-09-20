import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { validatePublicationArchive, derivePublicationAssets } from "../../dist/service/src/publication/index.js";
import { createSlice6PortalDocument } from "../../dist/service/src/publication/portal-document.js";

const webRoot = resolve(fileURLToPath(new URL("..", import.meta.url)));
const hostedRoot = resolve(webRoot, "..");
const [stylesheet, script, manifestSource, fixtureSource, expectationSource] = await Promise.all([
  readFile(resolve(webRoot, "dist/portal.css")),
  readFile(resolve(webRoot, "dist/portal.js")),
  readFile(resolve(webRoot, "dist/asset-manifest.json"), "utf8"),
  readFile(resolve(hostedRoot, "fixtures/publication/property-v1.zip.base64"), "utf8"),
  readFile(resolve(hostedRoot, "fixtures/publication/expectations.json"), "utf8"),
]);

const manifest = JSON.parse(manifestSource);
assert.equal(manifest.schemaVersion, "roomscan-published-web-assets-v1");
assert.deepEqual(manifest.assets.map((asset) => asset.path), ["portal.css", "portal.js"]);
for (const [asset, bytes] of [[manifest.assets[0], stylesheet], [manifest.assets[1], script]]) {
  assert.equal(asset.byteCount, bytes.byteLength);
  assert.equal(asset.sha256, sha256(bytes));
}

const document = createSlice6PortalDocument({ stylesheet, script });
assert.equal(document.html.includes(stylesheet.toString("utf8")), true);
assert.equal(document.html.includes(script.toString("utf8")), true);
assert.equal(document.headers["cache-control"], "no-store");
assert.match(document.headers["content-security-policy"] ?? "", /require-trusted-types-for 'script'/u);

const fixtureBytes = Uint8Array.from(Buffer.from(fixtureSource.trim(), "base64"));
const expectations = JSON.parse(expectationSource);
const expected = expectations.fixtures.find((candidate) => candidate.name === "property-v1");
assert.notEqual(expected, undefined);
const reader = Object.freeze({
  byteLength: fixtureBytes.byteLength,
  read: async (offset, length) => Uint8Array.from(fixtureBytes.subarray(offset, offset + length)),
});
const archive = await validatePublicationArchive({ reader, expected });
assert.equal(archive.snapshotKind, "property");
assert.equal(archive.independentRoomKeys.length, 2);
const derived = await derivePublicationAssets({ reader, archive, allocationPublicID: `pua_${"e".repeat(16)}` });
const presentation = derived.find((asset) => asset.kind === "presentation");
assert.notEqual(presentation, undefined);
const promoted = JSON.parse(Buffer.from(presentation.bytes).toString("utf8"));
assert.equal(promoted.contractKind, "publishedPropertySnapshot");
assert.equal(promoted.rooms.length, 2);
assert.equal(promoted.independentRoomNotice, "Rooms are presented independently; they do not share coordinates, alignment, connectivity, or reconstruction.");
assert.equal(derived.some((asset) => asset.kind === "floor_plan_pdf"), true);
assert.equal(derived.some((asset) => asset.kind === "gallery_zip"), true);
assert.equal(derived.every((asset) => /^ast_[A-Za-z0-9_-]{43}$/u.test(asset.assetPublicID)), true);

console.log(JSON.stringify({
  status: "passed",
  webAssets: manifest.assets.length,
  documentBytes: Buffer.byteLength(document.html, "utf8"),
  snapshotKind: archive.snapshotKind,
  rooms: archive.independentRoomKeys.length,
  derivatives: derived.length,
}));

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}
