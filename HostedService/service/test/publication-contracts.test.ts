import assert from "node:assert/strict";
import { createHash, createHmac } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import test from "node:test";

import {
  PUBLICATION_SELECTION_SCHEMA_VERSION,
  PublicationContractError,
  canonicalJson,
  canonicalJsonSHA256,
  isCanonicalTimestamp,
  parsePublicationAllocationRequest,
  parseSlice6RoutePayload,
  parseSlice6CredentialEnvelope,
  sha256Bytes,
  strictCanonicalJson,
} from "../src/publication/contracts.js";
import { PublicationSecretHasher, credentialForPublication } from "../src/publication/capabilities.js";
import {
  PublicationArchiveValidationError,
  validatePublicationArchive,
} from "../src/publication/archive-validator.js";

const HEX_A = "a".repeat(64);
const HEX_B = "b".repeat(64);
const HEX_C = "c".repeat(64);
const APP_BEARER = Buffer.alloc(32, 0x11).toString("base64url");
const PORTAL_COOKIE = Buffer.alloc(32, 0x22).toString("base64url");
const LINK_SECRET = Buffer.alloc(32, 0x33).toString("base64url");
const LEGACY_NATIVE_BEARER = "n".repeat(32);

test("professional property paging matches the live database twenty-property bound", () => {
  assert.deepEqual(parseSlice6RoutePayload("professional.properties.list", Buffer.from("{}")), { limit: 20 });
  assert.deepEqual(parseSlice6RoutePayload("professional.properties.list", Buffer.from(canonicalJson({ limit: 20 }))), { limit: 20 });
  assert.throws(() => parseSlice6RoutePayload("professional.properties.list", Buffer.from(canonicalJson({ limit: 21 }))), PublicationContractError);
});

test("publication allocation DTO is closed, binds the ordered Core source set, and never accepts server authority", () => {
  const parsed = parsePublicationAllocationRequest(validRoomAllocation());
  assert.equal(parsed.publicationKind, "room");
  assert.equal(parsed.sourceBindings.length, 1);
  assert.equal(parsed.sourceBindings[0]?.publicRoomKey, "room-living");

  assert.throws(
    () => parsePublicationAllocationRequest({ ...validRoomAllocation(), snapshotID: `snp_${"a".repeat(16)}` }),
    (error: unknown) => error instanceof PublicationContractError && error.code === "invalid_request",
    "a client must not mint a snapshot before validation/finalization",
  );
  assert.throws(
    () => parsePublicationAllocationRequest({ ...validRoomAllocation(), hostedGlobalVersion: 1 }),
    (error: unknown) => error instanceof PublicationContractError && error.code === "invalid_request",
    "operational flag/quota/version facts are derived inside the DB authorization transaction",
  );
  assert.throws(
    () => parsePublicationAllocationRequest({
      ...validRoomAllocation(),
      sourceBindings: [{ ...validRoomAllocation().sourceBindings[0]!, semanticSHA256: HEX_C }],
    }),
    (error: unknown) => error instanceof PublicationContractError && error.code === "binding_mismatch",
    "the named aggregate binding digest must cover every source-binding field",
  );
});

test("Slice 6 credentials are one unambiguous family and portal grants never become professional credentials", () => {
  const professional = parseSlice6CredentialEnvelope({
    required: "professional",
    headers: { authorization: `Bearer ${APP_BEARER}` },
    cookies: [],
  });
  assert.equal(professional.kind, "app_bearer");

  const link = parseSlice6CredentialEnvelope({
    required: "portal_link",
    headers: { authorization: `RoomScan-Link ${LINK_SECRET}` },
    cookies: [],
  });
  assert.equal(link.kind, "portal_link");

  assert.throws(
    () => parseSlice6CredentialEnvelope({
      required: "professional",
      headers: { authorization: `Bearer ${APP_BEARER}` },
      cookies: [`roomscan_portal=${PORTAL_COOKIE}`],
    }),
    (error: unknown) => error instanceof PublicationContractError && error.code === "credential_confusion",
  );
  assert.throws(
    () => parseSlice6CredentialEnvelope({
      required: "professional",
      headers: { authorization: `RoomScan-Link ${LINK_SECRET}` },
      cookies: [],
    }),
    (error: unknown) => error instanceof PublicationContractError && error.code === "credential_confusion",
  );
});

test("a new RoomScan-Link exchange discards only stale portal-cookie ambient bytes", () => {
  const staleCanary = "stale-portal-token-canary:never-parse-or-hash";
  const link = parseSlice6CredentialEnvelope({
    required: "portal_link",
    headers: { authorization: `RoomScan-Link ${LINK_SECRET}` },
    cookies: [
      `roomscan_portal=${staleCanary}`,
      `roomscan_portal_pending=${staleCanary}`,
      `roomscan_feedback=${staleCanary}`,
    ],
  });
  const inspected = link as typeof link & { readonly stalePortalCookieNames?: readonly string[] };
  assert.deepEqual(Object.keys(inspected).sort(), ["kind", "secret", "stalePortalCookieNames"]);
  assert.deepEqual(inspected.stalePortalCookieNames, ["roomscan_portal", "roomscan_portal_pending", "roomscan_feedback"]);
  assert.equal(JSON.stringify(link).includes(staleCanary), false, "discarded stale values cannot reach a service, log, or persistence boundary through the parsed envelope");
  assert.throws(
    () => parseSlice6CredentialEnvelope({
      required: "portal_link",
      headers: { authorization: `RoomScan-Link ${LINK_SECRET}` },
      cookies: [`roomscan_professional=${staleCanary}`],
    }),
    (error: unknown) => error instanceof PublicationContractError && error.code === "credential_confusion",
    "professional cookie confusion remains denied even when its ambient value is malformed",
  );
  assert.throws(
    () => parseSlice6CredentialEnvelope({
      required: "portal_link",
      headers: { authorization: `RoomScan-Link ${LINK_SECRET}` },
      cookies: [`roomscan_portal=${staleCanary}`, `unrelated_cookie=${staleCanary}`],
    }),
    (error: unknown) => error instanceof PublicationContractError && error.code === "credential_confusion",
    "a fresh link exchange fails closed rather than silently carrying unrelated ambient cookie state",
  );
  assert.throws(
    () => parseSlice6CredentialEnvelope({
      required: "portal_link",
      headers: { authorization: `RoomScan-Link ${LINK_SECRET}` },
      cookies: [`roomscan_portal=${staleCanary}`, `roomscan_portal=${staleCanary}`],
    }),
    (error: unknown) => error instanceof PublicationContractError && error.code === "credential_confusion",
    "duplicate ambient portal cookie names cannot be collapsed into an ambiguous credential exchange",
  );
  assert.throws(
    () => parseSlice6CredentialEnvelope({
      required: "portal_link",
      headers: { authorization: `Bearer ${LEGACY_NATIVE_BEARER}` },
      cookies: [`roomscan_portal=${staleCanary}`],
    }),
    (error: unknown) => error instanceof PublicationContractError && error.code === "credential_confusion",
    "an app bearer cannot be repurposed as a public link exchange",
  );
});

test("native app bearer hashing is byte-compatible with the frozen hosted access-token resolver", () => {
  const key = Buffer.alloc(32, 0x44);
  const envelope = parseSlice6CredentialEnvelope({ required: "professional", headers: { authorization: `Bearer ${LEGACY_NATIVE_BEARER}` } });
  assert.equal(envelope.kind, "app_bearer", "the existing 32-character app bearer grammar remains accepted");
  const credential = credentialForPublication(envelope, new PublicationSecretHasher(key));
  assert.deepEqual(Buffer.from(credential.hash), createHmac("sha256", key).update(LEGACY_NATIVE_BEARER).digest(), "publication reducers receive the exact pre-Slice-6 access-token HMAC");
});

test("property creation accepts only a separate create idempotency key and never a client prop_ identifier", () => {
  const create = parseSlice6RoutePayload("professional.properties.upsert", Buffer.from(canonicalJson({
    createIdempotencyKey: "property-create-request-001",
    rooms: [],
    title: "Independent rooms",
  }), "utf8")) as Readonly<Record<string, unknown>>;
  assert.deepEqual(create, {
    createIdempotencyKey: "property-create-request-001",
    rooms: [],
    title: "Independent rooms",
  });
  assert.throws(
    () => parseSlice6RoutePayload("professional.properties.upsert", Buffer.from(canonicalJson({
      createIdempotencyKey: "property-create-request-001",
      expectedVersion: 1,
      propertyID: `prop_${"p".repeat(16)}`,
      rooms: [],
      title: "Wrong create shape",
    }), "utf8")),
    (error: unknown) => error instanceof PublicationContractError && error.code === "invalid_request",
    "an update cannot smuggle a create key or choose a server-generated property ID",
  );
});

test("canonical JSON rejects a lone surrogate while preserving a valid non-BMP Unicode scalar", () => {
  assert.equal(canonicalJson({ label: "room \ud83d\ude80" }), "{\"label\":\"room 🚀\"}");
  assert.deepEqual(
    strictCanonicalJson(Buffer.from("{\"label\":\"room 🚀\"}", "utf8")),
    { label: "room 🚀" },
  );
  assert.throws(
    () => strictCanonicalJson(Buffer.from("{\"label\":\"\\ud800\"}", "utf8")),
    (error: unknown) => error instanceof PublicationContractError && error.code === "invalid_canonical_json",
    "a parsed lone high surrogate must never cross the canonical JSON boundary",
  );
  assert.equal(isCanonicalTimestamp("2026-08-16T16:00:00Z"), true, "Core canonical Date output omits zero milliseconds");
  assert.equal(isCanonicalTimestamp("2026-08-16T16:00:00.123Z"), true);
  assert.equal(isCanonicalTimestamp("2026-08-16T16:00:00.12Z"), false);
});

test("publication archive validator consumes exact Core room/property fixtures, preserves independent-room order, and detects a real archive-byte mutation", async () => {
  const roomFixture = loadFixture("room-v2-ai-ready");
  const room = await validatePublicationArchive({
    reader: byteReader(roomFixture.archive),
    expected: roomFixture.expected,
  });
  assert.equal(room.snapshotKind, "room");
  assert.equal(room.sourceBindingsSHA256, roomFixture.expected.sourceBindingsSHA256);
  assert.equal(room.assets.length, roomFixture.expected.ledger.length);

  const propertyFixture = loadFixture("property-v1");
  const property = await validatePublicationArchive({
    reader: byteReader(propertyFixture.archive),
    expected: propertyFixture.expected,
  });
  assert.equal(property.snapshotKind, "property");
  assert.deepEqual(property.sourceBindings.map((binding) => binding.publicRoomKey), ["room-living", "room-kitchen"]);
  assert.deepEqual(property.independentRoomKeys, ["room-living", "room-kitchen"]);
  assert.equal(property.presentationText.includes("coordinates"), true, "the required independent-room disclaimer is public text, not a spatial claim field");
  assert.equal(property.presentationText.includes("sharedOrigin"), false);

  const mutated = Uint8Array.from(roomFixture.archive);
  mutated[0] = (mutated[0] ?? 0) ^ 0x01;
  await assert.rejects(
    () => validatePublicationArchive({ reader: byteReader(mutated), expected: roomFixture.expected }),
    (error: unknown) => error instanceof PublicationArchiveValidationError && error.code === "archive_digest",
    "the exact archive identity guard must see a one-byte change in the checked Core bytes",
  );
});

test("archive digest reads permit protected four-mebibyte chunks without widening central-directory limits", async () => {
  for (const byteCount of [1_048_577, 4_194_304]) {
    const archive = storedZip([{ path: "payload.bin", bytes: new Uint8Array(byteCount - 120) }]);
    assert.equal(archive.byteLength, byteCount, "the positive control reaches the archive-digest read boundary exactly");
    await assert.rejects(
      () => validatePublicationArchive({ reader: byteReader(archive), expected: bareArchiveExpectation(archive) }),
      (error: unknown) => error instanceof PublicationArchiveValidationError && error.code === "manifest",
      `a valid ${byteCount}-byte stored archive passes archive hashing and reaches the manifest closure`,
    );
  }

  const exact = storedZip([{ path: "payload.bin", bytes: new Uint8Array(4_194_304 - 120) }]);
  await assert.rejects(
    () => validatePublicationArchive({
      reader: {
        byteLength: exact.byteLength,
        read: async () => { throw new Error("injected-reader-failure"); },
      },
      expected: bareArchiveExpectation(exact),
    }),
    (error: unknown) => error instanceof PublicationArchiveValidationError && error.code === "archive_digest",
    "the injected provider-read failure is observed inside the protected archive digest path",
  );
  let oversizedRead = false;
  await assert.rejects(
    () => validatePublicationArchive({
      reader: {
        byteLength: 805_306_369,
        read: async () => { oversizedRead = true; return new Uint8Array(); },
      },
      expected: { ...bareArchiveExpectation(exact), archive: { byteCount: 805_306_369, sha256: "a".repeat(64) } },
    }),
    (error: unknown) => error instanceof PublicationArchiveValidationError && error.code === "archive_size",
    "archive-size protection remains ahead of every reader call",
  );
  assert.equal(oversizedRead, false, "the oversize control proves the reader ceiling was not weakened while allowing a four-mebibyte digest chunk");
});

test("publication archive closure reaches an injected raw artifact after its archive identity is recomputed", async () => {
  const fixture = loadFixture("room-v2-ai-ready");
  const rebuilt = storedZip(readStoredEntries(fixture.archive));
  const rebuiltExpected = { ...fixture.expected, archive: archiveIdentity(rebuilt) };
  await assert.doesNotReject(
    () => validatePublicationArchive({ reader: byteReader(rebuilt), expected: rebuiltExpected }),
    "positive control proves the probe reaches past a newly computed archive identity into the real allowlist path",
  );

  for (const injectedEntry of [
    "assets/raw-rgb.bin", "assets/raw-depth.bin", "assets/confidence-map.bin", "diagnostics/solver.json",
    "maps/world-map.bin", "notes/private-note.txt", "history/revision-history.json", "assets/renamed-private.zip",
    "assets/portal-polyglot.svg", "assets/rendered-page.html",
  ]) {
    const injected = storedZip([
      ...readStoredEntries(fixture.archive),
      { path: injectedEntry, bytes: Uint8Array.of(0x50, 0x4b, 0x03, 0x04, 0x3c, 0x3e) },
    ]);
    await assert.rejects(
      () => validatePublicationArchive({ reader: byteReader(injected), expected: { ...fixture.expected, archive: archiveIdentity(injected) } }),
      (error: unknown) => error instanceof PublicationArchiveValidationError && error.code === "zip_closure",
      `${injectedEntry} is rejected by the empty publication allowlist rather than only by an old archive digest`,
    );
  }
});

test("publication presentation closure rejects forbidden working-material fields after manifest, selection, approval, and archive identities are all recomputed", async () => {
  const fixture = loadFixture("room-v2-ai-ready");
  for (const key of ["rawRGB", "rawFrames", "depth", "confidence", "diagnostics", "worldMap", "privateNotes", "preciseGPS", "gps", "revisionHistory", "coordinates", "alignment", "connectivity", "reconstruction"] as const) {
    const mutated = rewritePresentationFixture(fixture, key);
    await assert.rejects(
      () => validatePublicationArchive({ reader: byteReader(mutated.archive), expected: mutated.expected }),
      (error: unknown) => error instanceof PublicationArchiveValidationError && error.code === "presentation",
      `${key} reaches the presentation allowlist after every upstream immutable identity is recomputed`,
    );
  }
});

test("archive source and approval expectations are independent immutable guards", async () => {
  const fixture = loadFixture("room-v2-ai-ready");
  await assert.rejects(
    () => validatePublicationArchive({ reader: byteReader(fixture.archive), expected: { ...fixture.expected, sourceBindingsSHA256: "e".repeat(64) } }),
    (error: unknown) => error instanceof PublicationArchiveValidationError && error.code === "binding",
    "the allocation's exact source revision binding must match the archive even when all bytes are otherwise valid",
  );
  await assert.rejects(
    () => validatePublicationArchive({ reader: byteReader(fixture.archive), expected: { ...fixture.expected, approvalSHA256: "f".repeat(64) } }),
    (error: unknown) => error instanceof PublicationArchiveValidationError && error.code === "approval",
    "the approval is separately bound to the exact source/selection identity",
  );
});

function validRoomAllocation() {
  return {
    publicationKind: "room",
    projectID: `prj_${"a".repeat(16)}`,
    sourceRevisionID: `rev_${"b".repeat(16)}`,
    sourceRevisionDigest: HEX_A,
    sourceManifestDigest: HEX_B,
    sourceBindings: [{
      publicRoomKey: "room-living",
      projectPublicID: `prj_${"a".repeat(16)}`,
      revisionPublicID: `rev_${"b".repeat(16)}`,
      projectID: "project-001",
      revisionID: "revision-001",
      coordinateSpaceEpochID: "epoch-001",
      packageSchemaVersion: "room-scan-project-v2",
      semanticSHA256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      revisionManifestSHA256: "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210",
    }],
    sourceBindingsSHA256: "898fe6d5e561e4aa1488b9d6f403780212490d03205600e26179673defb77644",
    selectionManifestSHA256: "18cfdc5719db5ca1d6e104a6814d4e2e2d6c59a656dfffb0ed0bfd89a4243db9",
    approvalSHA256: "959d0b584b09e5e291956ce468f9f2fde91dfb9d3fc6b6b1d71b088554d568ba",
    disclosureStatus: "approved",
    archiveManifestSHA256: "1a511c79f9fceea44b9703d11897e3560c355caa4231398af5f23eb2815e7928",
    archiveSHA256: "0ef9305334beebc6c9ff1fd8fbebdb253a15211cb98bdc0c2496c1772c1f51fe",
    archiveByteCount: 18_322,
    idempotencyKey: "publication-idempotency-001",
  } as const;
}

function loadFixture(name: string): {
  readonly archive: Uint8Array;
  readonly expected: {
    readonly archive: { readonly byteCount: number; readonly sha256: string };
    readonly publicationManifest: { readonly byteCount: number; readonly sha256: string };
    readonly presentation: { readonly byteCount: number; readonly sha256: string };
    readonly sourceBindingsSHA256: string;
    readonly selectionManifestSHA256: string;
    readonly approvalSHA256: string;
    readonly ledger: readonly { readonly path: string; readonly byteCount: number; readonly sha256: string; readonly mediaType: string }[];
  };
} {
  const root = resolve(process.cwd(), "fixtures", "publication");
  const expectations = JSON.parse(readFileSync(resolve(root, "expectations.json"), "utf8")) as {
    readonly fixtures: readonly { readonly name: string; readonly archive: { readonly byteCount: number; readonly sha256: string }; readonly publicationManifest: { readonly byteCount: number; readonly sha256: string }; readonly presentation: { readonly byteCount: number; readonly sha256: string }; readonly sourceBindingsSHA256: string; readonly selectionManifestSHA256: string; readonly approvalSHA256: string; readonly ledger: readonly { readonly path: string; readonly byteCount: number; readonly sha256: string; readonly mediaType: string }[] }[];
  };
  const expected = expectations.fixtures.find((candidate) => candidate.name === name);
  assert.notEqual(expected, undefined, `missing frozen expectation for ${name}`);
  return Object.freeze({
    archive: Uint8Array.from(Buffer.from(readFileSync(resolve(root, `${name}.zip.base64`), "utf8").trim(), "base64")),
    expected: expected!,
  });
}

function byteReader(bytes: Uint8Array) {
  return Object.freeze({
    byteLength: bytes.byteLength,
    read: async (offset: number, length: number) => Uint8Array.from(bytes.subarray(offset, offset + length)),
  });
}

function archiveIdentity(bytes: Uint8Array): { readonly byteCount: number; readonly sha256: string } {
  return Object.freeze({ byteCount: bytes.byteLength, sha256: createHash("sha256").update(bytes).digest("hex") });
}

function bareArchiveExpectation(archive: Uint8Array) {
  return Object.freeze({
    archive: archiveIdentity(archive),
    publicationManifest: Object.freeze({ byteCount: 2, sha256: "a".repeat(64) }),
    presentation: Object.freeze({ byteCount: 2, sha256: "b".repeat(64) }),
    sourceBindingsSHA256: "c".repeat(64),
    selectionManifestSHA256: "d".repeat(64),
    approvalSHA256: "e".repeat(64),
    ledger: Object.freeze([]),
  });
}

function rewritePresentationFixture(fixture: ReturnType<typeof loadFixture>, forbiddenKey: string): Readonly<{ readonly archive: Uint8Array; readonly expected: typeof fixture.expected }> {
  const entries = readStoredEntries(fixture.archive).map((entry) => ({ ...entry, bytes: Uint8Array.from(entry.bytes) }));
  const index = new Map(entries.map((entry, position) => [entry.path, position]));
  const presentationIndex = index.get("presentation.json"); const manifestIndex = index.get("publication-manifest.json");
  assert.notEqual(presentationIndex, undefined); assert.notEqual(manifestIndex, undefined);
  const presentation = JSON.parse(Buffer.from(entries[presentationIndex!]!.bytes).toString("utf8")) as Record<string, unknown>;
  presentation[forbiddenKey] = { injectedCanary: true };
  const presentationBytes = Uint8Array.from(Buffer.from(canonicalJson(presentation), "utf8"));
  const manifest = JSON.parse(Buffer.from(entries[manifestIndex!]!.bytes).toString("utf8")) as Record<string, unknown>;
  manifest.presentationSHA256 = sha256Bytes(presentationBytes);
  manifest.selectionManifestSHA256 = canonicalJsonSHA256({
    schemaVersion: PUBLICATION_SELECTION_SCHEMA_VERSION,
    presentationSHA256: manifest.presentationSHA256,
    assets: manifest.assets,
  });
  const approval = manifest.approval as Record<string, unknown>;
  approval.selectionManifestSHA256 = manifest.selectionManifestSHA256;
  const manifestBytes = Uint8Array.from(Buffer.from(canonicalJson(manifest), "utf8"));
  entries[presentationIndex!] = { path: "presentation.json", bytes: presentationBytes };
  entries[manifestIndex!] = { path: "publication-manifest.json", bytes: manifestBytes };
  const archive = storedZip(entries);
  return Object.freeze({
    archive,
    expected: Object.freeze({
      ...fixture.expected,
      archive: archiveIdentity(archive),
      publicationManifest: Object.freeze({ byteCount: manifestBytes.byteLength, sha256: sha256Bytes(manifestBytes) }),
      presentation: Object.freeze({ byteCount: presentationBytes.byteLength, sha256: sha256Bytes(presentationBytes) }),
      selectionManifestSHA256: manifest.selectionManifestSHA256 as string,
      approvalSHA256: canonicalJsonSHA256(approval),
    }),
  });
}

function readStoredEntries(bytes: Uint8Array): readonly { readonly path: string; readonly bytes: Uint8Array }[] {
  const entries: { path: string; bytes: Uint8Array }[] = [];
  let offset = 0;
  while (offset + 30 <= bytes.byteLength && le32(bytes, offset) === 0x0403_4b50) {
    const flags = le16(bytes, offset + 6); const method = le16(bytes, offset + 8); const compressed = le32(bytes, offset + 18); const uncompressed = le32(bytes, offset + 22); const nameLength = le16(bytes, offset + 26); const extraLength = le16(bytes, offset + 28);
    const dataOffset = offset + 30 + nameLength + extraLength;
    assert.equal(flags, 0x0800, "frozen Core fixture uses explicit UTF-8 stored ZIP entries");
    assert.equal(method, 0);
    assert.equal(compressed, uncompressed);
    assert.ok(dataOffset + compressed <= bytes.byteLength);
    entries.push({ path: Buffer.from(bytes.subarray(offset + 30, offset + 30 + nameLength)).toString("utf8"), bytes: Uint8Array.from(bytes.subarray(dataOffset, dataOffset + compressed)) });
    offset = dataOffset + compressed;
  }
  assert.ok(entries.length > 2, "positive control extracted the actual Core fixture's stored entries");
  return Object.freeze(entries);
}

function storedZip(entries: readonly { readonly path: string; readonly bytes: Uint8Array }[]): Uint8Array {
  const locals: Uint8Array[] = []; const central: Uint8Array[] = []; let offset = 0;
  for (const entry of entries) {
    const name = Buffer.from(entry.path, "utf8"); const bytes = entry.bytes; const crc = crc32(bytes);
    const local = new Uint8Array(30 + name.byteLength + bytes.byteLength);
    put32(local, 0, 0x0403_4b50); put16(local, 4, 20); put16(local, 6, 0x0800); put16(local, 8, 0); put32(local, 14, crc); put32(local, 18, bytes.byteLength); put32(local, 22, bytes.byteLength); put16(local, 26, name.byteLength); put16(local, 28, 0); local.set(name, 30); local.set(bytes, 30 + name.byteLength); locals.push(local);
    const directory = new Uint8Array(46 + name.byteLength);
    put32(directory, 0, 0x0201_4b50); put16(directory, 4, 0x0314); put16(directory, 6, 20); put16(directory, 8, 0x0800); put16(directory, 10, 0); put32(directory, 16, crc); put32(directory, 20, bytes.byteLength); put32(directory, 24, bytes.byteLength); put16(directory, 28, name.byteLength); put16(directory, 30, 0); put16(directory, 32, 0); put16(directory, 34, 0); put32(directory, 38, 0); put32(directory, 42, offset); directory.set(name, 46); central.push(directory); offset += local.byteLength;
  }
  const centralOffset = offset; const centralBytes = join([...locals, ...central]).byteLength - centralOffset; const end = new Uint8Array(22);
  put32(end, 0, 0x0605_4b50); put16(end, 8, entries.length); put16(end, 10, entries.length); put32(end, 12, centralBytes); put32(end, 16, centralOffset);
  return join([...locals, ...central, end]);
}

function join(parts: readonly Uint8Array[]): Uint8Array { const output = new Uint8Array(parts.reduce((length, part) => length + part.byteLength, 0)); let offset = 0; for (const part of parts) { output.set(part, offset); offset += part.byteLength; } return output; }
function le16(bytes: Uint8Array, offset: number): number { return (bytes[offset] ?? 0) | ((bytes[offset + 1] ?? 0) << 8); }
function le32(bytes: Uint8Array, offset: number): number { return ((bytes[offset] ?? 0) | ((bytes[offset + 1] ?? 0) << 8) | ((bytes[offset + 2] ?? 0) << 16) | ((bytes[offset + 3] ?? 0) << 24)) >>> 0; }
function put16(bytes: Uint8Array, offset: number, value: number): void { bytes[offset] = value & 0xff; bytes[offset + 1] = (value >>> 8) & 0xff; }
function put32(bytes: Uint8Array, offset: number, value: number): void { bytes[offset] = value & 0xff; bytes[offset + 1] = (value >>> 8) & 0xff; bytes[offset + 2] = (value >>> 16) & 0xff; bytes[offset + 3] = (value >>> 24) & 0xff; }
const CRC_TABLE = Array.from({ length: 256 }, (_, index) => { let value = index; for (let bit = 0; bit < 8; bit += 1) value = (value & 1) === 1 ? (value >>> 1) ^ 0xedb8_8320 : value >>> 1; return value >>> 0; });
function crc32(bytes: Uint8Array): number { let value = 0xffff_ffff; for (const byte of bytes) value = (value >>> 8) ^ (CRC_TABLE[(value ^ byte) & 0xff] ?? 0); return (value ^ 0xffff_ffff) >>> 0; }
