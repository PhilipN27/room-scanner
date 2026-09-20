import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import test from "node:test";

import {
  ProjectSyncArchiveValidationError,
  containsForbiddenRawByteChunks,
  containsForbiddenRawBytes,
  validateProjectSyncArchive,
} from "../src/sync/archive-validator.js";
import { PROJECT_SYNC_MAX_ARCHIVE_BYTES } from "../src/contracts/project-sync.js";

const fixtureRoot = resolve(process.cwd(), "../RoomScanCore/Tests/RoomScanCoreTests/Fixtures/ProfessionalSync");

test("working-set validator accepts the real Core-generated raw-redacted fixture", async () => {
  const archive = await fixture("working-set-v1.zip.base64");
  const descriptor = JSON.parse(await fixtureText("working-set-v1.descriptor.base64")) as {
    readonly projectID: string;
    readonly headRevisionID: string;
    readonly archiveSHA256: string;
    readonly archiveByteCount: number;
  };
  const manifestSha256 = (await readFile(resolve(fixtureRoot, "working-set-v1.manifest-sha256.txt"), "utf8")).trim();

  const result = validateProjectSyncArchive({
    tier: "working",
    archive,
    expected: {
      projectId: descriptor.projectID,
      sourceRevisionId: descriptor.headRevisionID,
      manifestSha256,
      sha256: descriptor.archiveSHA256,
      byteCount: descriptor.archiveByteCount,
    },
  });

  assert.deepEqual(result, {
    tier: "working",
    projectId: "project-001",
    sourceRevisionId: "revision-001",
    coordinateSpaceEpochId: "epoch-001",
    sha256: descriptor.archiveSHA256,
    byteCount: descriptor.archiveByteCount,
  });
});

test("working-set validator binds exact Core Concept mapping adjustments after validating their transported Concept Set", async () => {
  const working = await fixture("working-set-v1.zip.base64");
  const descriptor = JSON.parse(await fixtureText("working-set-v1.descriptor.base64")) as {
    readonly projectID: string; readonly headRevisionID: string; readonly archiveSHA256: string; readonly archiveByteCount: number;
  };
  const original = {
    projectId: descriptor.projectID,
    sourceRevisionId: descriptor.headRevisionID,
    manifestSha256: "0".repeat(64),
    sha256: descriptor.archiveSHA256,
    byteCount: descriptor.archiveByteCount,
  };

  // Start with Core's actual working-set fixture, mutate its transported
  // Concept Set to the exact manual destination that Core recovery records,
  // remove now-unneeded automatic provenance, and rebuild the outer ledger.
  const adjusted = withValidCoreConceptMappingAdjustment(working);
  assert.equal(containsForbiddenRawBytes(adjusted), false, "the positive adjustment fixture reaches the manifest validator, not the raw marker detector");
  assert.equal(validateProjectSyncArchive({ tier: "working", archive: adjusted, expected: expectedForMutatedWorking(adjusted, original) }).tier, "working");

  const variants: Array<Readonly<{ readonly field: string; readonly archive: Uint8Array }>> = [
    {
      field: "closed adjustment object",
      archive: mutateWorkingManifest(adjusted, (manifest) => {
        const adjustment = firstConceptMappingAdjustment(manifest);
        adjustment.opaqueBase64 = "QUJDREVGR0hJSktMTU5PUA==";
      }),
    },
    {
      field: "orphan Concept Set binding",
      archive: mutateWorkingManifest(adjusted, (manifest) => { firstConceptMappingAdjustment(manifest).conceptSetID = "concept-set-404"; }),
    },
    {
      field: "substituted attachment binding",
      archive: mutateWorkingManifest(adjusted, (manifest) => { firstConceptMappingAdjustment(manifest).attachmentID = "attachment-404"; }),
    },
    {
      field: "transported mapping substitution",
      archive: mutateWorkingManifest(adjusted, (manifest) => { firstConceptMappingAdjustment(manifest).to = { status: "unmatched" }; }),
    },
    {
      field: "typed automatic source mapping",
      archive: mutateWorkingManifest(adjusted, (manifest) => { (firstConceptMappingAdjustment(manifest).from as Record<string, unknown>).cameraID = { opaque: "camera" }; }),
    },
    {
      field: "unique stable adjustment identity",
      archive: mutateWorkingManifest(adjusted, (manifest) => {
        const first = firstConceptMappingAdjustment(manifest);
        manifest.conceptMappingAdjustments = [first, structuredClone(first)];
      }),
    },
    {
      field: "typed complete package descriptor field",
      archive: mutateWorkingManifest(adjusted, (manifest) => { manifest.packageDescriptor.complete = { opaque: true }; }),
    },
  ];
  for (const { field, archive } of variants) {
    assert.equal(containsForbiddenRawBytes(archive), false, `${field} is a canonical, ledger-recomputed hostile archive rather than a marker probe`);
    assert.throws(
      () => validateProjectSyncArchive({ tier: "working", archive, expected: expectedForMutatedWorking(archive, original) }),
      (error: unknown) => error instanceof ProjectSyncArchiveValidationError && error.code === "invalid_manifest",
      field,
    );
  }
});

test("working-set validator detects an injected forbidden raw artifact while reviewed raw accepts its separate fixture", async () => {
  const working = await fixture("working-set-v1.zip.base64");
  const workingDescriptor = JSON.parse(await fixtureText("working-set-v1.descriptor.base64")) as {
    readonly projectID: string;
    readonly headRevisionID: string;
    readonly archiveSHA256: string;
    readonly archiveByteCount: number;
  };
  const raw = await fixture("reviewed-raw-v1.zip.base64");
  const rawDescriptor = JSON.parse(await fixtureText("reviewed-raw-v1.descriptor.base64")) as {
    readonly projectID: string;
    readonly revisionID: string;
    readonly archiveSHA256: string;
    readonly archiveByteCount: number;
    readonly review: unknown;
  };
  const rawManifestSha256 = (await readFile(resolve(fixtureRoot, "reviewed-raw-v1.manifest-sha256.txt"), "utf8")).trim();

  // This is a real Core archive rebuilt as a valid ZIP32/STORE file with a
  // closed outer ledger and an explicit raw entry. It is not a post-EOCD
  // marker, so the guard must reject hostile content rather than malformed
  // ZIP trailing bytes.
  const forbidden = withSelfConsistentForbiddenRawEntry(working);
  assert.equal(containsForbiddenRawBytes(forbidden), true, "positive control: the forbidden-artifact probe reaches the actual injected bytes");
  assert.throws(
    () => validateProjectSyncArchive({
      tier: "working",
      archive: forbidden,
      expected: expectedForMutatedWorking(forbidden, {
        projectId: workingDescriptor.projectID,
        sourceRevisionId: workingDescriptor.headRevisionID,
        manifestSha256: "0".repeat(64),
        sha256: workingDescriptor.archiveSHA256,
        byteCount: workingDescriptor.archiveByteCount,
      }),
    }),
    (error: unknown) => error instanceof ProjectSyncArchiveValidationError && error.code === "forbidden_raw_artifact",
  );

  const accepted = validateProjectSyncArchive({
    tier: "raw",
    archive: raw,
    expected: {
      projectId: rawDescriptor.projectID,
      sourceRevisionId: rawDescriptor.revisionID,
      manifestSha256: rawManifestSha256,
      reviewSha256: createHash("sha256").update(JSON.stringify(rawDescriptor.review)).digest("hex"),
      sha256: rawDescriptor.archiveSHA256,
      byteCount: rawDescriptor.archiveByteCount,
    },
  });
  assert.equal(accepted.tier, "raw");
  assert.equal(accepted.projectId, "project-001");
});

test("forbidden raw scanner is bounded and catches markers split across transport chunks", () => {
  const encoder = new TextEncoder();
  const marker = encoder.encode("prefix'raw/world-map/suffix");
  assert.equal(containsForbiddenRawByteChunks([
    marker.subarray(0, 8),
    marker.subarray(8, 16),
    marker.subarray(16),
  ]), true, "the injected raw marker crosses two chunk boundaries");
  assert.equal(containsForbiddenRawByteChunks([
    encoder.encode("safe working companion"),
    encoder.encode(" manifest"),
  ]), false);
  assert.equal(containsForbiddenRawByteChunks([
    encoder.encode("prefix raw/world-map but not a path literal"),
  ]), false, "an unquoted mid-stream substring is not a false-positive raw path");
  assert.equal(containsForbiddenRawByteChunks([
    encoder.encode("RAW/DEPTH at the beginning"),
  ]), true, "the start-of-stream positive control remains ASCII-case-insensitive");

  // This archive reaches the public validator with a deliberately wrong
  // expected digest; size rejection must win without copying or hashing it.
  const capPlusOne = new Uint8Array(PROJECT_SYNC_MAX_ARCHIVE_BYTES + 1);
  assert.throws(
    () => validateProjectSyncArchive({
      tier: "working",
      archive: capPlusOne,
      expected: {
        projectId: "project-001",
        sourceRevisionId: "revision-001",
        manifestSha256: "0".repeat(64),
        sha256: "0".repeat(64),
        byteCount: 1,
      },
    }),
    (error: unknown) => error instanceof ProjectSyncArchiveValidationError && error.code === "zip_structure",
  );
});

test("real Core companion schemas reject opaque fields in self-consistent archives", async () => {
  const working = await fixture("working-set-v1.zip.base64");
  const descriptor = JSON.parse(await fixtureText("working-set-v1.descriptor.base64")) as {
    readonly projectID: string; readonly headRevisionID: string; readonly archiveSHA256: string; readonly archiveByteCount: number;
  };
  const original = {
    projectId: descriptor.projectID,
    sourceRevisionId: descriptor.headRevisionID,
    manifestSha256: "0".repeat(64),
    sha256: descriptor.archiveSHA256,
    byteCount: descriptor.archiveByteCount,
  };
  const companions = [
    "companions/redesign.json",
    "companions/concept-sets/concept-set-001/manifest.json",
    "companions/concept-source-packages/ai-package-001/manifest.json",
  ] as const;
  for (const path of companions) {
    const document = JSON.parse(storedZipEntryText(working, path)) as Record<string, unknown>;
    // Deliberately opaque/base64-shaped input: it must not become an ignored
    // extension point merely because every digest and ledger claim is fresh.
    document.opaqueBase64 = "QUJDREVGR0hJSktMTU5PUA==";
    const hostile = mutateWorkingArchive(working, [{ path, bytes: Buffer.from(canonicalJson(document), "utf8") }]);
    assert.equal(containsForbiddenRawBytes(hostile), false, `${path} reaches the strict schema guard, not the raw detector`);
    assert.throws(
      () => validateProjectSyncArchive({ tier: "working", archive: hostile, expected: expectedForMutatedWorking(hostile, original) }),
      (error: unknown) => error instanceof ProjectSyncArchiveValidationError && error.code === "invalid_manifest",
      `${path} must reject an unknown opaque field after its Core ledger digest is updated`,
    );
  }
});

test("real Core companion typed fields reject object bypasses in self-consistent archives", async () => {
  const working = await fixture("working-set-v1.zip.base64");
  const descriptor = JSON.parse(await fixtureText("working-set-v1.descriptor.base64")) as {
    readonly projectID: string; readonly headRevisionID: string; readonly archiveSHA256: string; readonly archiveByteCount: number;
  };
  const original = {
    projectId: descriptor.projectID,
    sourceRevisionId: descriptor.headRevisionID,
    manifestSha256: "0".repeat(64),
    sha256: descriptor.archiveSHA256,
    byteCount: descriptor.archiveByteCount,
  };
  const mutate = (path: string, update: (document: Record<string, unknown>) => void): Uint8Array => {
    const document = JSON.parse(storedZipEntryText(working, path)) as Record<string, unknown>;
    update(document);
    return mutateWorkingArchive(working, [{ path, bytes: Buffer.from(canonicalJson(document), "utf8") }]);
  };
  const redesignPath = "companions/redesign.json";
  const conceptPath = "companions/concept-sets/concept-set-001/manifest.json";
  const provenancePath = "companions/concept-source-packages/ai-package-001/manifest.json";
  const hostile = [
    { field: "orientation.source", archive: mutate(redesignPath, (document) => { (document.orientation as Record<string, unknown>).source = { value: "confirmed" }; }) },
    { field: "redesignIntent.constraints.purpose[]", archive: mutate(redesignPath, (document) => {
      document.redesignIntent = {
        ...(document.redesignIntent as Record<string, unknown>),
        constraints: { purpose: [{ text: "object-not-text" }], style: [], householdNeeds: [], accessibility: [], circulation: [], materials: [], colors: [], referenceImageIDs: [], desiredObjects: [] },
      };
    }) },
    { field: "propertyMembership.roomProjectIDs[]", archive: mutate(redesignPath, (document) => { document.propertyMembership = { propertyID: "property-001", roomProjectIDs: [{ projectID: "project-001" }] }; }) },
    { field: "conceptSet.comments[]", archive: mutate(conceptPath, (document) => { document.comments = [{ text: "object-not-comment" }]; }) },
    { field: "disclosureReview.reviewedAt", archive: mutate(provenancePath, (document) => { ((document.disclosureReview as Record<string, unknown>).reviewedAt) = { instant: "2024-01-01T00:00:00Z" }; }) },
  ];

  for (const { field, archive } of hostile) {
    assert.equal(containsForbiddenRawBytes(archive), false, `${field} reaches the manifest validator, not the raw marker detector`);
    assert.throws(
      () => validateProjectSyncArchive({ tier: "working", archive, expected: expectedForMutatedWorking(archive, original) }),
      (error: unknown) => error instanceof ProjectSyncArchiveValidationError && error.code === "invalid_manifest",
      field,
    );
  }
});

test("real Core companion value grammar rejects scalar, enum, uniqueness, and source-provenance drift", async () => {
  const working = await fixture("working-set-v1.zip.base64");
  const descriptor = JSON.parse(await fixtureText("working-set-v1.descriptor.base64")) as {
    readonly projectID: string; readonly headRevisionID: string; readonly archiveSHA256: string; readonly archiveByteCount: number;
  };
  const original = {
    projectId: descriptor.projectID,
    sourceRevisionId: descriptor.headRevisionID,
    manifestSha256: "0".repeat(64),
    sha256: descriptor.archiveSHA256,
    byteCount: descriptor.archiveByteCount,
  };
  const mutate = (path: string, update: (document: Record<string, unknown>) => void): Uint8Array => {
    const document = JSON.parse(storedZipEntryText(working, path)) as Record<string, unknown>;
    update(document);
    return mutateWorkingArchive(working, [{ path, bytes: Buffer.from(canonicalJson(document), "utf8") }]);
  };
  const redesignPath = "companions/redesign.json";
  const conceptPath = "companions/concept-sets/concept-set-001/manifest.json";
  const provenancePath = "companions/concept-source-packages/ai-package-001/manifest.json";
  const hostile = [
    { field: "orientation.confidence finite unit interval", archive: mutate(redesignPath, (document) => { (document.orientation as Record<string, unknown>).confidence = "1"; }) },
    { field: "orientation canonical role order", archive: mutate(redesignPath, (document) => { (((document.orientation as Record<string, unknown>).canonicalCameras as Array<Record<string, unknown>>)[0]!).role = "viewer"; }) },
    { field: "constraint uniqueness", archive: mutate(redesignPath, (document) => {
      document.redesignIntent = { ...(document.redesignIntent as Record<string, unknown>), constraints: { purpose: ["same", "same"], style: [], householdNeeds: [], accessibility: [], circulation: [], materials: [], colors: [], referenceImageIDs: [], desiredObjects: [] } };
    }) },
    { field: "membership uniqueness", archive: mutate(redesignPath, (document) => { document.propertyMembership = { propertyID: "property-001", roomProjectIDs: ["project-001", "project-001"] }; }) },
    { field: "Concept portable source filename", archive: mutate(conceptPath, (document) => { (document.importProvenance as Record<string, unknown>).sourceFilename = "../escape.zip"; }) },
    { field: "Concept mapping camera requirement", archive: mutate(conceptPath, (document) => { const mapping = (((document.attachments as Array<Record<string, unknown>>)[0]!).mapping as Record<string, unknown>); mapping.status = "manual"; delete mapping.cameraID; }) },
    { field: "AI package artifact-plan class", archive: mutate(provenancePath, (document) => { ((document.artifactPlan as Array<Record<string, unknown>>)[0]!).artifactClass = "notAnArtifactClass"; }) },
    { field: "AI package included asset state", archive: mutate(provenancePath, (document) => { ((document.artifacts as Array<Record<string, unknown>>)[10]!).disposition = "included"; }) },
    { field: "AI disclosure review selection digest", archive: mutate(provenancePath, (document) => { (document.disclosureReview as Record<string, unknown>).reviewedSelectionSHA256 = { digest: "not-a-digest" }; }) },
  ];

  for (const { field, archive } of hostile) {
    assert.equal(containsForbiddenRawBytes(archive), false, `${field} is structurally valid ZIP/ledger input and does not use the raw marker detector`);
    assert.throws(
      () => validateProjectSyncArchive({ tier: "working", archive, expected: expectedForMutatedWorking(archive, original) }),
      (error: unknown) => error instanceof ProjectSyncArchiveValidationError && error.code === "invalid_manifest",
      field,
    );
  }
});

test("ZIP32 hostile cases reach parser, closure, and immutable source-binding guards", async () => {
  const working = await fixture("working-set-v1.zip.base64");
  const descriptor = JSON.parse(await fixtureText("working-set-v1.descriptor.base64")) as {
    readonly projectID: string; readonly headRevisionID: string; readonly archiveSHA256: string; readonly archiveByteCount: number;
  };
  const original = {
    projectId: descriptor.projectID,
    sourceRevisionId: descriptor.headRevisionID,
    manifestSha256: "0".repeat(64),
    sha256: descriptor.archiveSHA256,
    byteCount: descriptor.archiveByteCount,
  };
  const entries = readStoredZipEntries(working);
  const duplicateJson = replaceZipEntry(
    working,
    "working-set-manifest.json",
    Buffer.from(storedZipEntryText(working, "working-set-manifest.json").replace("{", "{\"schemaVersion\":\"roomscan-professional-working-set-manifest-v1\","), "utf8"),
  );
  const traversal = buildStoredZip([...entries, { path: "../escape.txt", bytes: Buffer.from("x", "utf8") }]);
  const caseCollision = buildStoredZip([...entries, { path: "COMPANIONS/redesign.json", bytes: Buffer.from("x", "utf8") }]);
  const symlink = buildStoredZip(entries.map((entry, index) => index === 0 ? { ...entry, externalAttributes: 0xa0000000 } : entry));
  const nonStore = buildStoredZip(entries.map((entry, index) => index === 0 ? { ...entry, compressionMethod: 8 } : entry));
  const crc = buildStoredZip(entries.map((entry, index) => index === 0 ? { ...entry, crc32Override: (crc32(entry.bytes) ^ 1) >>> 0 } : entry));
  const unlisted = buildStoredZip([...entries, { path: "companions/hidden.json", bytes: Buffer.from("{}", "utf8") }]);
  const redesign = JSON.parse(storedZipEntryText(working, "companions/redesign.json")) as { sourceRevision: Record<string, unknown> };
  redesign.sourceRevision.coordinateSpaceEpochID = "epoch-002";
  const wrongEpoch = mutateWorkingArchive(working, [{ path: "companions/redesign.json", bytes: Buffer.from(canonicalJson(redesign), "utf8") }]);
  const reject = (archive: Uint8Array, code: ProjectSyncArchiveValidationError["code"], expected = expectedForMutatedWorking(archive, original)): void => {
    assert.throws(
      () => validateProjectSyncArchive({ tier: "working", archive, expected }),
      (error: unknown) => error instanceof ProjectSyncArchiveValidationError && error.code === code,
    );
  };

  reject(duplicateJson, "invalid_json");
  reject(traversal, "unsafe_path");
  reject(caseCollision, "duplicate_entry");
  reject(symlink, "zip_structure");
  reject(nonStore, "zip_structure");
  reject(crc, "entry_digest");
  reject(unlisted, "entry_closure");
  reject(working, "binding_mismatch", { ...original, manifestSha256: (await readFile(resolve(fixtureRoot, "working-set-v1.manifest-sha256.txt"), "utf8")).trim(), sha256: sha256Hex(working), byteCount: working.byteLength, projectId: "project-002" });
  reject(working, "binding_mismatch", { ...original, manifestSha256: (await readFile(resolve(fixtureRoot, "working-set-v1.manifest-sha256.txt"), "utf8")).trim(), sha256: sha256Hex(working), byteCount: working.byteLength, sourceRevisionId: "revision-002" });
  reject(wrongEpoch, "binding_mismatch");
  reject(working, "digest_mismatch", { ...original, manifestSha256: (await readFile(resolve(fixtureRoot, "working-set-v1.manifest-sha256.txt"), "utf8")).trim(), sha256: sha256Hex(working), byteCount: working.byteLength + 1 });
});

test("validator binds persisted working/raw digests and rejects nested backup or reviewed-selection drift", async () => {
  const working = await fixture("working-set-v1.zip.base64");
  const workingDescriptor = JSON.parse(await fixtureText("working-set-v1.descriptor.base64")) as {
    readonly projectID: string;
    readonly headRevisionID: string;
    readonly archiveSHA256: string;
    readonly archiveByteCount: number;
  };
  const workingManifestSha256 = (await readFile(resolve(fixtureRoot, "working-set-v1.manifest-sha256.txt"), "utf8")).trim();
  const workingExpected = {
    projectId: workingDescriptor.projectID,
    sourceRevisionId: workingDescriptor.headRevisionID,
    manifestSha256: workingManifestSha256,
    sha256: workingDescriptor.archiveSHA256,
    byteCount: workingDescriptor.archiveByteCount,
  };

  assert.throws(
    () => validateProjectSyncArchive({ tier: "working", archive: working, expected: { ...workingExpected, manifestSha256: "b".repeat(64) } }),
    (error: unknown) => error instanceof ProjectSyncArchiveValidationError && error.code === "entry_digest",
    "the worker must use the exact persisted working_manifest_digest",
  );
  assert.throws(
    () => validateProjectSyncArchive({ tier: "working", archive: working, expected: { ...workingExpected, sourceRevisionId: "revision-002" } }),
    (error: unknown) => error instanceof ProjectSyncArchiveValidationError && error.code === "binding_mismatch",
    "the worker must bind the persisted Core source revision, not a server public ID",
  );

  const descriptorDrift = replaceStoredZipEntryText(
    working,
    "working-set-manifest.json",
    '"manifestSHA256":"a5644924e416b354aad74f3cab89bcc2f62eedb5d2ec5772fec9d18198e56000"',
    '"manifestSHA256":"f5644924e416b354aad74f3cab89bcc2f62eedb5d2ec5772fec9d18198e56000"',
  );
  assert.throws(
    () => validateProjectSyncArchive({ tier: "working", archive: descriptorDrift, expected: expectedForMutatedWorking(descriptorDrift, workingExpected) }),
    (error: unknown) => error instanceof ProjectSyncArchiveValidationError && error.code === "binding_mismatch",
    "a self-consistent outer ZIP digest cannot bypass the nested descriptor/backup-manifest binding",
  );

  const raw = await fixture("reviewed-raw-v1.zip.base64");
  const rawDescriptor = JSON.parse(await fixtureText("reviewed-raw-v1.descriptor.base64")) as {
    readonly projectID: string;
    readonly revisionID: string;
    readonly archiveSHA256: string;
    readonly archiveByteCount: number;
    readonly review: unknown;
  };
  const rawExpected = {
    projectId: rawDescriptor.projectID,
    sourceRevisionId: rawDescriptor.revisionID,
    manifestSha256: (await readFile(resolve(fixtureRoot, "reviewed-raw-v1.manifest-sha256.txt"), "utf8")).trim(),
    reviewSha256: createHash("sha256").update(JSON.stringify(rawDescriptor.review)).digest("hex"),
    sha256: rawDescriptor.archiveSHA256,
    byteCount: rawDescriptor.archiveByteCount,
  };
  assert.throws(
    () => validateProjectSyncArchive({ tier: "raw", archive: raw, expected: { ...rawExpected, reviewSha256: "c".repeat(64) } }),
    (error: unknown) => error instanceof ProjectSyncArchiveValidationError && error.code === "binding_mismatch",
    "the worker must use the exact persisted raw_review_digest",
  );

  const selectionDrift = replaceStoredZipEntryText(
    raw,
    "raw-archive-manifest.json",
    '"reviewedSelectionSHA256":"ecf2a2ab2e66a1a1b41bd1ff268efbd0bc4163c322a04065a8ee0494ab2eed85"',
    '"reviewedSelectionSHA256":"fcf2a2ab2e66a1a1b41bd1ff268efbd0bc4163c322a04065a8ee0494ab2eed85"',
  );
  const selectionManifest = JSON.parse(storedZipEntryText(selectionDrift, "raw-archive-manifest.json")) as { readonly review: unknown };
  assert.throws(
    () => validateProjectSyncArchive({
      tier: "raw",
      archive: selectionDrift,
      expected: {
        ...rawExpected,
        manifestSha256: sha256Hex(Buffer.from(storedZipEntryText(selectionDrift, "raw-archive-manifest.json"), "utf8")),
        reviewSha256: sha256Hex(Buffer.from(JSON.stringify(selectionManifest.review), "utf8")),
        sha256: sha256Hex(selectionDrift),
        byteCount: selectionDrift.byteLength,
      },
    }),
    (error: unknown) => error instanceof ProjectSyncArchiveValidationError && error.code === "binding_mismatch",
    "an accepted review digest cannot authorize a selection different from the raw manifest entries",
  );
});

async function fixture(name: string): Promise<Uint8Array> {
  return Buffer.from((await readFile(resolve(fixtureRoot, name), "utf8")).trim(), "base64");
}

async function fixtureText(name: string): Promise<string> {
  return Buffer.from(await fixture(name)).toString("utf8");
}

function expectedForMutatedWorking(
  archive: Uint8Array,
  original: { readonly projectId: string; readonly sourceRevisionId: string; readonly manifestSha256: string; readonly sha256: string; readonly byteCount: number },
) {
  return {
    ...original,
    manifestSha256: sha256Hex(Buffer.from(storedZipEntryText(archive, "working-set-manifest.json"), "utf8")),
    sha256: sha256Hex(archive),
    byteCount: archive.byteLength,
  };
}

/** Controlled mutation of a real Core ZIP32/STORE fixture. Rebuilding its
 * local records and central directory is intentionally test-only plumbing:
 * the production path always uses the service parser. */
function replaceStoredZipEntryText(archive: Uint8Array, entryName: string, before: string, after: string): Uint8Array {
  const body = Buffer.from(storedZipEntryText(archive, entryName), "utf8");
  const index = body.indexOf(before, "utf8");
  assert.notEqual(index, -1, `fixture ${entryName} includes mutation target`);
  return replaceZipEntry(archive, entryName, Buffer.concat([body.subarray(0, index), Buffer.from(after, "utf8"), body.subarray(index + Buffer.byteLength(before))]));
}

function storedZipEntryText(archive: Uint8Array, entryName: string): string {
  const input = Buffer.from(archive);
  let offset = 0;
  while (input.readUInt32LE(offset) === 0x04034b50) {
    const nameLength = input.readUInt16LE(offset + 26);
    const extraLength = input.readUInt16LE(offset + 28);
    const byteCount = input.readUInt32LE(offset + 18);
    const name = input.subarray(offset + 30, offset + 30 + nameLength).toString("utf8");
    const bodyOffset = offset + 30 + nameLength + extraLength;
    if (name === entryName) return input.subarray(bodyOffset, bodyOffset + byteCount).toString("utf8");
    offset = bodyOffset + byteCount;
  }
  assert.fail(`fixture includes ${entryName}`);
}

interface StoreZipEntry {
  readonly path: string;
  readonly bytes: Uint8Array;
  readonly compressionMethod?: number;
  readonly externalAttributes?: number;
  readonly crc32Override?: number;
}

interface WorkingEntryMutation {
  readonly path: string;
  readonly bytes?: Uint8Array;
  readonly newEntry?: Readonly<{ readonly kind: "raw"; readonly rawAssetClass: "rgb"; readonly mediaType: string }>;
  readonly remove?: boolean;
}

interface TestWorkingManifest {
  entries: Array<Record<string, unknown>>;
  conceptMappingAdjustments: Array<Record<string, unknown>>;
  packageDescriptor: Record<string, unknown>;
}

/** Adds a declared raw RGB object and updates the real outer Core ledger.
 * It is a valid ZIP and self-consistent digest/size manifest; the only
 * invalid property is exactly the working-tier raw payload policy. */
function withSelfConsistentForbiddenRawEntry(archive: Uint8Array): Uint8Array {
  return mutateWorkingArchive(archive, [{
    path: "raw/rgb-capture-bundle.bin",
    bytes: Buffer.from("RGB_CAPTURE_BUNDLE_FORBIDDEN", "utf8"),
    newEntry: { kind: "raw", rawAssetClass: "rgb", mediaType: "application/octet-stream" },
  }]);
}

/** A nonempty adjustment made exactly like Core recovery: the transported
 * Concept attachment changes from automatic to manual, retaining its camera.
 * Its automatic AI provenance is then omitted because Core requires exact
 * provenance closure only for automatic mappings. */
function withValidCoreConceptMappingAdjustment(archive: Uint8Array): Uint8Array {
  const conceptPath = "companions/concept-sets/concept-set-001/manifest.json";
  const concept = JSON.parse(storedZipEntryText(archive, conceptPath)) as Record<string, unknown>;
  const attachment = (concept.attachments as Array<Record<string, unknown>>)[0];
  assert.notEqual(attachment, undefined, "real Core fixture supplies the mapped Concept attachment");
  const originalMapping = attachment!.mapping as Record<string, unknown>;
  assert.equal(originalMapping.status, "automatic", "real Core fixture begins with an automatic Concept mapping");
  assert.equal(typeof originalMapping.cameraID, "string", "real Core fixture binds its automatic mapping to a camera");
  attachment!.mapping = { status: "manual", cameraID: originalMapping.cameraID };
  return mutateWorkingArchive(
    archive,
    [
      { path: conceptPath, bytes: Buffer.from(canonicalJson(concept), "utf8") },
      { path: "companions/concept-source-packages/ai-package-001/manifest.json", remove: true },
    ],
    (manifest) => {
      manifest.conceptMappingAdjustments = [{
        conceptSetID: "concept-set-001",
        attachmentID: "attachment-001",
        from: { status: "automatic", cameraID: originalMapping.cameraID },
        to: { status: "manual", cameraID: originalMapping.cameraID },
      }];
    },
  );
}

function firstConceptMappingAdjustment(manifest: TestWorkingManifest): Record<string, unknown> {
  const adjustment = manifest.conceptMappingAdjustments[0];
  assert.notEqual(adjustment, undefined, "working manifest has the expected adjustment");
  return adjustment!;
}

function mutateWorkingManifest(archive: Uint8Array, update: (manifest: TestWorkingManifest) => void): Uint8Array {
  return mutateWorkingArchive(archive, [], update);
}

function mutateWorkingArchive(
  archive: Uint8Array,
  mutations: readonly WorkingEntryMutation[],
  updateManifest?: (manifest: TestWorkingManifest) => void,
): Uint8Array {
  const entries = readStoredZipEntries(archive);
  const manifest = JSON.parse(storedZipEntryText(archive, "working-set-manifest.json")) as TestWorkingManifest;
  for (const mutation of mutations) {
    const entryIndex = entries.findIndex((entry) => entry.path === mutation.path);
    const ledgerIndex = manifest.entries.findIndex((entry) => entry.path === mutation.path);
    if (mutation.remove === true) {
      assert.equal(mutation.newEntry, undefined, "removed entry is not a new entry");
      assert.equal(mutation.bytes, undefined, "removed entry has no replacement bytes");
      assert.notEqual(entryIndex, -1, `fixture includes ${mutation.path}`);
      assert.notEqual(ledgerIndex, -1, `working ledger includes ${mutation.path}`);
      entries.splice(entryIndex, 1);
      manifest.entries.splice(ledgerIndex, 1);
    } else if (mutation.newEntry === undefined) {
      assert.notEqual(mutation.bytes, undefined, `replacement includes bytes for ${mutation.path}`);
      assert.notEqual(entryIndex, -1, `fixture includes ${mutation.path}`);
      assert.notEqual(ledgerIndex, -1, `working ledger includes ${mutation.path}`);
      manifest.entries[ledgerIndex]!.byteCount = mutation.bytes!.byteLength;
      manifest.entries[ledgerIndex]!.sha256 = sha256Hex(mutation.bytes!);
      entries[entryIndex] = { path: mutation.path, bytes: Uint8Array.from(mutation.bytes!) };
    } else {
      assert.notEqual(mutation.bytes, undefined, `new entry includes bytes for ${mutation.path}`);
      assert.equal(entryIndex, -1, `fixture does not already include ${mutation.path}`);
      assert.equal(ledgerIndex, -1, `working ledger does not already include ${mutation.path}`);
      manifest.entries.push({
        path: mutation.path,
        kind: { type: mutation.newEntry.kind, rawAssetClass: mutation.newEntry.rawAssetClass },
        mediaType: mutation.newEntry.mediaType,
        byteCount: mutation.bytes!.byteLength,
        sha256: sha256Hex(mutation.bytes!),
      });
      entries.push({ path: mutation.path, bytes: Uint8Array.from(mutation.bytes!) });
    }
  }
  updateManifest?.(manifest);
  manifest.entries.sort((left, right) => String(left.path).localeCompare(String(right.path), "en-US"));
  const manifestIndex = entries.findIndex((entry) => entry.path === "working-set-manifest.json");
  assert.notEqual(manifestIndex, -1, "fixture includes the working manifest");
  entries[manifestIndex] = { path: "working-set-manifest.json", bytes: Buffer.from(canonicalJson(manifest), "utf8") };
  return buildStoredZip(entries);
}

function replaceZipEntry(archive: Uint8Array, path: string, bytes: Uint8Array): Uint8Array {
  const entries = readStoredZipEntries(archive);
  const index = entries.findIndex((entry) => entry.path === path);
  assert.notEqual(index, -1, `fixture includes ${path}`);
  entries[index] = { path, bytes: Uint8Array.from(bytes) };
  return buildStoredZip(entries);
}

function readStoredZipEntries(archive: Uint8Array): StoreZipEntry[] {
  const input = Buffer.from(archive);
  const entries: StoreZipEntry[] = [];
  let offset = 0;
  while (offset + 30 <= input.byteLength && input.readUInt32LE(offset) === 0x04034b50) {
    const flags = input.readUInt16LE(offset + 6);
    const method = input.readUInt16LE(offset + 8);
    const nameLength = input.readUInt16LE(offset + 26);
    const extraLength = input.readUInt16LE(offset + 28);
    const byteCount = input.readUInt32LE(offset + 18);
    const bodyOffset = offset + 30 + nameLength + extraLength;
    const end = bodyOffset + byteCount;
    assert.ok((flags === 0 || flags === 0x0800) && method === 0 && end <= input.byteLength, "fixture is a readable ZIP32/STORE archive");
    entries.push({
      path: input.subarray(offset + 30, offset + 30 + nameLength).toString("utf8"),
      bytes: Uint8Array.from(input.subarray(bodyOffset, end)),
    });
    offset = end;
  }
  assert.ok(entries.length > 0, "fixture has local ZIP entries");
  return entries;
}

function buildStoredZip(entries: readonly StoreZipEntry[]): Uint8Array {
  const locals: Buffer[] = [];
  const central: Buffer[] = [];
  const records: Array<{ readonly entry: StoreZipEntry; readonly name: Buffer; readonly bytes: Buffer; readonly crc: number; readonly offset: number }> = [];
  let offset = 0;
  for (const entry of entries) {
    const name = Buffer.from(entry.path, "utf8");
    const bytes = Buffer.from(entry.bytes);
    const crc = entry.crc32Override ?? crc32(bytes);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(0, 6);
    local.writeUInt16LE(entry.compressionMethod ?? 0, 8);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(bytes.byteLength, 18);
    local.writeUInt32LE(bytes.byteLength, 22);
    local.writeUInt16LE(name.byteLength, 26);
    local.writeUInt16LE(0, 28);
    locals.push(local, name, bytes);
    records.push({ entry, name, bytes, crc, offset });
    offset += local.byteLength + name.byteLength + bytes.byteLength;
  }
  const centralOffset = offset;
  for (const record of records) {
    const header = Buffer.alloc(46);
    header.writeUInt32LE(0x02014b50, 0);
    header.writeUInt16LE(20, 4);
    header.writeUInt16LE(20, 6);
    header.writeUInt16LE(0, 8);
    header.writeUInt16LE(record.entry.compressionMethod ?? 0, 10);
    header.writeUInt32LE(record.crc, 16);
    header.writeUInt32LE(record.bytes.byteLength, 20);
    header.writeUInt32LE(record.bytes.byteLength, 24);
    header.writeUInt16LE(record.name.byteLength, 28);
    header.writeUInt16LE(0, 30);
    header.writeUInt16LE(0, 32);
    header.writeUInt16LE(0, 34);
    header.writeUInt32LE(record.entry.externalAttributes ?? 0, 38);
    header.writeUInt32LE(record.offset, 42);
    central.push(header, record.name);
    offset += header.byteLength + record.name.byteLength;
  }
  const centralBytes = offset - centralOffset;
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(entries.length, 8);
  eocd.writeUInt16LE(entries.length, 10);
  eocd.writeUInt32LE(centralBytes, 12);
  eocd.writeUInt32LE(centralOffset, 16);
  return Buffer.concat([...locals, ...central, eocd]);
}

function canonicalJson(value: unknown): string {
  if (value === null || typeof value === "boolean" || typeof value === "number" || typeof value === "string") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  assert.equal(typeof value, "object", "fixture mutation serializes only JSON values");
  const record = value as Readonly<Record<string, unknown>>;
  return `{${Object.keys(record).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(record[key])}`).join(",")}}`;
}

function sha256Hex(bytes: Uint8Array): string { return createHash("sha256").update(bytes).digest("hex"); }

function crc32(bytes: Uint8Array): number {
  let value = 0xffffffff;
  for (const byte of bytes) {
    value ^= byte;
    for (let bit = 0; bit < 8; bit += 1) value = (value >>> 1) ^ ((value & 1) === 0 ? 0 : 0xedb88320);
  }
  return (value ^ 0xffffffff) >>> 0;
}
