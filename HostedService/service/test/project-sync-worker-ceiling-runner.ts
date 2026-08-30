import { createHash } from "node:crypto";

import {
  ProjectSyncObjectAdapter,
  type ProjectSyncObjectProvider,
} from "../src/adapters/s3-project-sync.js";
import { PROJECT_SYNC_MAX_ARCHIVE_BYTES } from "../src/contracts/project-sync.js";
import {
  ProjectSyncValidationWorker,
  type ProjectSyncWorkerClaim,
  type ProjectSyncWorkerStore,
} from "../src/sync/project-sync-worker.js";
import { createExactWorkingArchiveFixture } from "./support/project-sync-ceiling-fixture.js";

const workspaceInternalId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const quarantineLogicalKey = "professional-sync/quarantine/working/upl_abcdefghijklmnop.zip";
const activeLogicalKey = "professional-sync/active/working/rev_abcdefghijklmnop.zip";

class ExactInMemoryProvider implements ProjectSyncObjectProvider {
  #active = false;
  #archive: Uint8Array;
  #archiveChecksum: string;
  constructor(archive: Uint8Array, archiveChecksum: string) {
    this.#archive = archive;
    this.#archiveChecksum = archiveChecksum;
  }

  replace(archive: Uint8Array, archiveChecksum: string): void {
    this.#active = false;
    this.#archive = archive;
    this.#archiveChecksum = archiveChecksum;
  }

  async presignImmutablePut(): Promise<never> { throw new Error("unexpected_presign"); }

  async headCurrent(input: { readonly physicalKey: string }): Promise<Readonly<{
    readonly versionId: string;
    readonly contentLength: number;
    readonly contentType: "application/zip";
    readonly checksumSha256: string;
  }>> {
    return this.object(input.physicalKey, this.#active ? "active+/exact" : "quarantine+/exact");
  }

  async readExact(input: { readonly physicalKey: string; readonly versionId: string }): Promise<Readonly<{
    readonly versionId: string;
    readonly bytes: Uint8Array;
    readonly contentType: "application/zip";
    readonly checksumSha256: string;
  }>> {
    const expected = input.physicalKey.includes("/active/") ? "active+/exact" : "quarantine+/exact";
    if (input.versionId !== expected) throw new Error("wrong_exact_version");
    return Object.freeze({ ...this.object(input.physicalKey, expected), bytes: this.#archive });
  }

  async copyImmutable(input: { readonly sourcePhysicalKey: string; readonly sourceVersionId: string; readonly destinationPhysicalKey: string; readonly ifNoneMatch: "*" }): Promise<Readonly<{ readonly versionId: string }>> {
    if (!input.sourcePhysicalKey.includes("/quarantine/") || !input.destinationPhysicalKey.includes("/active/")
      || input.sourceVersionId !== "quarantine+/exact" || input.ifNoneMatch !== "*") throw new Error("invalid_copy");
    this.#active = true;
    return Object.freeze({ versionId: "active+/exact" });
  }

  async presignExactDownload(): Promise<never> { throw new Error("unexpected_download"); }

  private object(_physicalKey: string, versionId: string): Readonly<{
    readonly versionId: string;
    readonly contentLength: number;
    readonly contentType: "application/zip";
    readonly checksumSha256: string;
  }> {
    return Object.freeze({ versionId, contentLength: this.#archive.byteLength, contentType: "application/zip", checksumSha256: this.#archiveChecksum });
  }
}

class SequencedStore implements ProjectSyncWorkerStore {
  readonly rejected: string[] = [];
  readonly finalized: string[] = [];
  constructor(private readonly claims: ProjectSyncWorkerClaim[]) {}
  async reapExpired(): Promise<number> { return 0; }
  async claimNext(): Promise<ProjectSyncWorkerClaim | undefined> { return this.claims.shift(); }
  async release(): Promise<void> { throw new Error("unexpected_release"); }
  async reject(claim: Pick<ProjectSyncWorkerClaim, "uploadInternalId" | "leaseId">): Promise<void> { this.rejected.push(claim.uploadInternalId); }
  async finalize(claim: Pick<ProjectSyncWorkerClaim, "uploadInternalId" | "leaseId">): Promise<"canonical"> { this.finalized.push(claim.uploadInternalId); return "canonical"; }
}

function invalidClaim(): ProjectSyncWorkerClaim {
  return Object.freeze({
    workspaceInternalId,
    uploadInternalId: "upload-invalid",
    leaseId: "lease-invalid",
    operation: "append_revision",
    quarantineLogicalKey,
    activeLogicalKey,
    workingManifestSha256: "0".repeat(64),
    workingSha256: "0".repeat(64),
    workingByteCount: 1,
    projectSourceId: "project-001",
    candidateRevisionSourceId: "revision-001",
  });
}

function validClaim(workingManifestSha256: string, archiveSha256: string): ProjectSyncWorkerClaim {
  return Object.freeze({
    workspaceInternalId,
    uploadInternalId: "upload-valid",
    leaseId: "lease-valid",
    operation: "append_revision",
    quarantineLogicalKey,
    activeLogicalKey,
    workingManifestSha256,
    workingSha256: archiveSha256,
    workingByteCount: PROJECT_SYNC_MAX_ARCHIVE_BYTES,
    projectSourceId: "project-001",
    candidateRevisionSourceId: "revision-001",
  });
}

async function run(): Promise<void> {
  const fixture = await createExactWorkingArchiveFixture();
  if (fixture.archive.byteLength !== PROJECT_SYNC_MAX_ARCHIVE_BYTES) throw new Error("project_sync_ceiling_fixture_not_exact");
  const checksum = createHash("sha256").update(fixture.archive).digest("base64");
  const invalidArchive = Uint8Array.of(0);
  const provider = new ExactInMemoryProvider(
    invalidArchive,
    createHash("sha256").update(invalidArchive).digest("base64"),
  );
  const store = new SequencedStore([
    invalidClaim(),
    validClaim(fixture.workingManifestSha256, fixture.archiveSha256),
  ]);
  const worker = new ProjectSyncValidationWorker({
    clock: { now: () => new Date("2026-08-29T12:00:00.000Z") },
    store,
    objects: new ProjectSyncObjectAdapter(provider),
  });

  // Isolate worker RSS from transient fixture-construction arrays before the
  // real targetless run. The child is invoked with --expose-gc by its oracle.
  const maybeGc = (globalThis as typeof globalThis & { gc?: () => void }).gc;
  maybeGc?.();
  const before = process.hrtime.bigint();
  const first = await worker.runOnce();
  provider.replace(fixture.archive, checksum);
  const second = await worker.runOnce();
  const elapsedMs = Number(process.hrtime.bigint() - before) / 1_000_000;
  // Node exposes maxRSS in KiB for this runtime; normalize explicitly so the
  // test compares it to the Lambda's byte-valued memory configuration.
  const peakRssBytes = process.resourceUsage().maxRSS * 1024;
  process.stdout.write(`${JSON.stringify({
    archiveBytes: fixture.archive.byteLength,
    elapsedMs,
    peakRssBytes,
    first,
    second,
    rejected: store.rejected,
    finalized: store.finalized,
  })}\n`);
}

await run();
