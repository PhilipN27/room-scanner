import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import test from "node:test";

import { ProjectSyncObjectAdapter, type ProjectSyncObjectProvider, type ProjectSyncObjectVersion } from "../src/adapters/s3-project-sync.js";
import { PROJECT_SYNC_MAX_ARCHIVE_BYTES } from "../src/contracts/project-sync.js";
import { ProjectSyncValidationWorker } from "../src/sync/project-sync-worker.js";

const fixtureRoot = resolve(process.cwd(), "../RoomScanCore/Tests/RoomScanCoreTests/Fixtures/ProfessionalSync");

test("worker reaps before a targetless claim and never accepts a client-selected upload", async () => {
  const events: string[] = [];
  const worker = new ProjectSyncValidationWorker({
    clock: { now: () => new Date("2030-01-01T00:00:00.000Z") },
    store: {
      reapExpired: async () => { events.push("reap"); return 1; },
      claimNext: async () => { events.push("claim"); return undefined; },
      release: async () => { throw new Error("not called"); },
      reject: async () => { throw new Error("not called"); },
      finalize: async () => { throw new Error("not called"); },
    },
    objects: {} as never,
  });

  assert.deepEqual(await worker.runOnce(), { status: "idle", reaped: 1 });
  assert.deepEqual(events, ["reap", "claim"]);
  assert.equal("runUpload" in (worker as unknown as Record<string, unknown>), false);
});

test("adapter rejects a 64 MiB plus one immutable upload before it reaches a provider", async () => {
  let presignCalls = 0;
  const provider: ProjectSyncObjectProvider = {
    presignImmutablePut: async () => { presignCalls += 1; throw new Error("must not run"); },
    headCurrent: async () => { throw new Error("unused"); },
    readExact: async () => { throw new Error("unused"); },
    copyImmutable: async () => { throw new Error("unused"); },
    presignExactDownload: async () => { throw new Error("unused"); },
  };
  await assert.rejects(
    new ProjectSyncObjectAdapter(provider).presignImmutableUpload({
      workspaceInternalId: "33333333-3333-4333-8333-333333333333",
      logicalKey: `professional-sync/quarantine/working/upl_${"a".repeat(16)}.zip`,
      byteCount: PROJECT_SYNC_MAX_ARCHIVE_BYTES + 1,
      checksumSha256: createHash("sha256").update("cap-plus-one").digest("base64"),
    }),
    (error: unknown) => (error as { readonly code?: unknown }).code === "invalid_project_sync_storage_key",
  );
  assert.equal(presignCalls, 0);
});

test("worker recovers an active immutable copy made before finalization and persists its exact opaque versions", async () => {
  const archive = await fixture("working-set-v1.zip.base64");
  const descriptor = JSON.parse(Buffer.from(await fixture("working-set-v1.descriptor.base64")).toString("utf8")) as {
    readonly projectID: string; readonly headRevisionID: string; readonly archiveSHA256: string; readonly archiveByteCount: number;
  };
  const manifestSha256 = (await readFile(resolve(fixtureRoot, "working-set-v1.manifest-sha256.txt"), "utf8")).trim();
  const events: string[] = [];
  const quarantineVersion = "3/L4kqtJlcpXroDTDmJ+3DcjkqQq2jAY+8/dK";
  const activeVersion = "3/L4active+copy/with/slashes";
  const checksum = createHash("sha256").update(archive).digest("base64");
  const provider: ProjectSyncObjectProvider = {
    presignImmutablePut: async () => { throw new Error("unused"); },
    headCurrent: async ({ physicalKey }) => {
      if (physicalKey.includes("/quarantine/")) {
        events.push("head-quarantine");
        return { versionId: quarantineVersion, contentLength: archive.byteLength, contentType: "application/zip" as const, checksumSha256: checksum };
      }
      events.push("head-active");
      return { versionId: activeVersion, contentLength: archive.byteLength, contentType: "application/zip" as const, checksumSha256: checksum };
    },
    readExact: async ({ physicalKey, versionId }) => {
      events.push(physicalKey.includes("/quarantine/") ? "read-quarantine" : "read-active");
      assert.equal(versionId, physicalKey.includes("/quarantine/") ? quarantineVersion : activeVersion);
      return object(versionId, archive, checksum);
    },
    copyImmutable: async (input) => {
      events.push("copy");
      assert.equal(input.ifNoneMatch, "*");
      // Simulates a worker crash after successful immutable copy but before
      // the finalizer CAS. A retry must prove and reuse this exact active
      // version, never overwrite or spin on the precondition failure.
      throw new Error("PreconditionFailed");
    },
    presignExactDownload: async () => ({ url: "https://download.example/object" }),
  };
  let finalized: { readonly quarantineVersionId: string; readonly activeVersionId: string } | undefined;
  const worker = new ProjectSyncValidationWorker({
    clock: { now: () => new Date("2030-01-01T00:00:00.000Z") },
    objects: new ProjectSyncObjectAdapter(provider),
    store: {
      reapExpired: async () => { events.push("reap"); return 0; },
      claimNext: async () => {
        events.push("claim");
        return {
          workspaceInternalId: "33333333-3333-4333-8333-333333333333", uploadInternalId: "44444444-4444-4444-8444-444444444444", leaseId: `wkl_${"a".repeat(16)}`,
          operation: "append_revision", quarantineLogicalKey: `professional-sync/quarantine/working/upl_${"a".repeat(16)}.zip`, activeLogicalKey: `professional-sync/active/working/rev_${"b".repeat(16)}.zip`,
          projectSourceId: descriptor.projectID, candidateRevisionSourceId: descriptor.headRevisionID,
          workingManifestSha256: manifestSha256, workingSha256: descriptor.archiveSHA256, workingByteCount: descriptor.archiveByteCount,
        };
      },
      release: async () => { throw new Error("not called"); },
      reject: async () => { throw new Error("not called"); },
      finalize: async (_claim, _now, versions) => { events.push("finalize"); finalized = versions; return "canonical"; },
    },
  });

  assert.deepEqual(await worker.runOnce(), { status: "finalized", reaped: 0, outcome: "canonical" });
  assert.deepEqual(finalized, { quarantineVersionId: quarantineVersion, activeVersionId: activeVersion });
  assert.deepEqual(events, ["reap", "claim", "head-quarantine", "read-quarantine", "read-quarantine", "copy", "head-active", "read-active", "finalize"]);
});

test("existing active key with different immutable bytes is rejected instead of silently replacing it", async () => {
  const source = Buffer.from("source archive", "utf8");
  const changed = Buffer.from("other archive!", "utf8");
  const sourceChecksum = createHash("sha256").update(source).digest("base64");
  const changedChecksum = createHash("sha256").update(changed).digest("base64");
  const provider: ProjectSyncObjectProvider = {
    presignImmutablePut: async () => { throw new Error("unused"); },
    headCurrent: async ({ physicalKey }) => physicalKey.includes("/quarantine/")
      ? { versionId: "q+version/1", contentLength: source.byteLength, contentType: "application/zip" as const, checksumSha256: sourceChecksum }
      : { versionId: "a+version/1", contentLength: changed.byteLength, contentType: "application/zip" as const, checksumSha256: changedChecksum },
    readExact: async ({ physicalKey, versionId }) => physicalKey.includes("/quarantine/") ? object(versionId, source, sourceChecksum) : object(versionId, changed, changedChecksum),
    copyImmutable: async () => { throw new Error("PreconditionFailed"); },
    presignExactDownload: async () => ({ url: "https://download.example/object" }),
  };
  const adapter = new ProjectSyncObjectAdapter(provider);
  await assert.rejects(
    adapter.promoteAndVerify({
      workspaceInternalId: "33333333-3333-4333-8333-333333333333",
      quarantineLogicalKey: `professional-sync/quarantine/working/upl_${"a".repeat(16)}.zip`,
      quarantineVersionId: "q+version/1",
      activeLogicalKey: `professional-sync/active/working/rev_${"b".repeat(16)}.zip`,
    }),
    (error: unknown) => (error as { readonly code?: unknown }).code === "provider_mismatch",
  );
});

test("promotion rejects a provider that substitutes a different quarantine version for an exact read", async () => {
  const bytes = Buffer.from("exact quarantine archive", "utf8");
  const checksum = createHash("sha256").update(bytes).digest("base64");
  const provider: ProjectSyncObjectProvider = {
    presignImmutablePut: async () => { throw new Error("unused"); },
    headCurrent: async () => ({ versionId: "q+version/1", contentLength: bytes.byteLength, contentType: "application/zip" as const, checksumSha256: checksum }),
    readExact: async ({ physicalKey, versionId }) => physicalKey.includes("/quarantine/")
      ? object("provider-substituted-version", bytes, checksum)
      : object(versionId, bytes, checksum),
    copyImmutable: async () => ({ versionId: "active+version/1" }),
    presignExactDownload: async () => ({ url: "https://download.example/object" }),
  };
  await assert.rejects(
    new ProjectSyncObjectAdapter(provider).promoteAndVerify({
      workspaceInternalId: "33333333-3333-4333-8333-333333333333",
      quarantineLogicalKey: `professional-sync/quarantine/working/upl_${"a".repeat(16)}.zip`,
      quarantineVersionId: "q+version/1",
      activeLogicalKey: `professional-sync/active/working/rev_${"b".repeat(16)}.zip`,
    }),
    (error: unknown) => (error as { readonly code?: unknown }).code === "provider_mismatch",
  );
});

test("adapter pairs working quarantine only with working active and raw quarantine only with raw active", async () => {
  const bytes = Buffer.from("tier-pair archive", "utf8");
  const checksum = createHash("sha256").update(bytes).digest("base64");
  let providerReads = 0;
  const provider: ProjectSyncObjectProvider = {
    presignImmutablePut: async () => { throw new Error("unused"); },
    headCurrent: async () => { throw new Error("unused"); },
    readExact: async ({ versionId }) => { providerReads += 1; return object(versionId, bytes, checksum); },
    copyImmutable: async () => ({ versionId: "active+raw/version" }),
    presignExactDownload: async () => ({ url: "https://download.example/object" }),
  };
  const adapter = new ProjectSyncObjectAdapter(provider);
  const workspaceInternalId = "33333333-3333-4333-8333-333333333333";
  const workingQuarantine = `professional-sync/quarantine/working/upl_${"a".repeat(16)}.zip`;
  const rawQuarantine = `professional-sync/quarantine/raw/upl_${"c".repeat(16)}.zip`;
  const workingActive = `professional-sync/active/working/rev_${"b".repeat(16)}.zip`;
  const rawActive = `professional-sync/active/raw/upl_${"c".repeat(16)}.zip`;

  await assert.rejects(
    adapter.promoteAndVerify({ workspaceInternalId, quarantineLogicalKey: workingQuarantine, quarantineVersionId: "q+working/version", activeLogicalKey: rawActive }),
    (error: unknown) => (error as { readonly code?: unknown }).code === "invalid_project_sync_storage_key",
  );
  await assert.rejects(
    adapter.promoteAndVerify({ workspaceInternalId, quarantineLogicalKey: rawQuarantine, quarantineVersionId: "q+raw/version", activeLogicalKey: workingActive }),
    (error: unknown) => (error as { readonly code?: unknown }).code === "invalid_project_sync_storage_key",
  );
  assert.equal(providerReads, 0, "cross-tier claims fail before any provider read/copy");

  const promoted = await adapter.promoteAndVerify({ workspaceInternalId, quarantineLogicalKey: rawQuarantine, quarantineVersionId: "q+raw/version", activeLogicalKey: rawActive });
  assert.equal(promoted.activeVersionId, "active+raw/version");
  assert.equal(providerReads, 2, "the valid raw-to-raw pair reads exact source and active versions");
  const workingPromoted = await adapter.promoteAndVerify({ workspaceInternalId, quarantineLogicalKey: workingQuarantine, quarantineVersionId: "q+working/version", activeLogicalKey: workingActive });
  assert.equal(workingPromoted.activeVersionId, "active+raw/version");
  assert.equal(providerReads, 4, "the valid working-to-working pair uses the same exact-version flow");
});

test("interrupted upload releases its lease and a later targetless worker retry validates the real Core fixture", async () => {
  const archive = await fixture("working-set-v1.zip.base64");
  const descriptor = JSON.parse(Buffer.from(await fixture("working-set-v1.descriptor.base64")).toString("utf8")) as {
    readonly projectID: string; readonly headRevisionID: string; readonly archiveSHA256: string; readonly archiveByteCount: number;
  };
  const manifestSha256 = (await readFile(resolve(fixtureRoot, "working-set-v1.manifest-sha256.txt"), "utf8")).trim();
  const claim = {
    workspaceInternalId: "33333333-3333-4333-8333-333333333333", uploadInternalId: "44444444-4444-4444-8444-444444444444", leaseId: `wkl_${"a".repeat(16)}`,
    operation: "append_revision" as const, quarantineLogicalKey: `professional-sync/quarantine/working/upl_${"a".repeat(16)}.zip`, activeLogicalKey: `professional-sync/active/working/rev_${"b".repeat(16)}.zip`,
    projectSourceId: descriptor.projectID, candidateRevisionSourceId: descriptor.headRevisionID,
    workingManifestSha256: manifestSha256, workingSha256: descriptor.archiveSHA256, workingByteCount: descriptor.archiveByteCount,
  };
  const events: string[] = [];
  let attempt = 0;
  const objects = {
    readCurrentQuarantine: async () => {
      attempt += 1;
      events.push(`read-${attempt}`);
      if (attempt === 1) throw new Error("synthetic interrupted provider read");
      return object("q+retry/version", archive, createHash("sha256").update(archive).digest("base64"));
    },
    promoteAndVerify: async () => {
      events.push("promote");
      return { quarantineVersionId: "q+retry/version", activeVersionId: "a+retry/version", bytes: Uint8Array.from(archive), checksumSha256: createHash("sha256").update(archive).digest("base64") };
    },
  } as unknown as ProjectSyncObjectAdapter;
  const worker = new ProjectSyncValidationWorker({
    clock: { now: () => new Date("2030-01-01T00:00:00.000Z") },
    objects,
    store: {
      reapExpired: async () => { events.push(`reap-${attempt}`); return attempt === 0 ? 1 : 0; },
      claimNext: async () => { events.push(`claim-${attempt}`); return claim; },
      release: async () => { events.push("release"); },
      reject: async () => { throw new Error("not called"); },
      finalize: async () => { events.push("finalize"); return "canonical"; },
    },
  });

  assert.deepEqual(await worker.runOnce(), { status: "retry", reaped: 1 });
  assert.deepEqual(await worker.runOnce(), { status: "finalized", reaped: 0, outcome: "canonical" });
  assert.deepEqual(events, ["reap-0", "claim-0", "read-1", "release", "reap-1", "claim-1", "read-2", "promote", "finalize"]);
});

async function fixture(name: string): Promise<Uint8Array> {
  return Buffer.from((await readFile(resolve(fixtureRoot, name), "utf8")).trim(), "base64");
}
function object(versionId: string, bytes: Uint8Array, checksumSha256: string): ProjectSyncObjectVersion {
  return { versionId, bytes: Uint8Array.from(bytes), contentType: "application/zip", checksumSha256 };
}
