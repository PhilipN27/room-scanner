import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import test from "node:test";

import { PublicationObjectAdapter, mapPublicationQuarantineStorageKey, type PublicationContentType, type PublicationObjectProvider } from "../src/adapters/s3-publication.js";
import { PublicationWorkerStoreError, type PublicationWorkerClaim, type PublicationWorkerStore } from "../src/persistence/publication-worker-store.js";
import { PublicationValidationWorker } from "../src/publication/worker.js";

const ROOT = resolve(process.cwd(), "fixtures", "publication");
const PUA = `pua_${"w".repeat(16)}`;
const CLAIM_BASE = {
  allocationInternalID: "11111111-1111-4111-8111-111111111111",
  allocationPublicID: PUA,
  leaseID: `pwl_${"l".repeat(16)}`,
} as const;

test("targetless worker validates actual Core bytes, promotes only allowlisted derivatives, and reuses an interrupted immutable promotion", async () => {
  const fixture = loadFixture("room-v2-ai-ready");
  const objects = new InMemoryPublicationObjects(fixture.archive, fixture.expected.archive.sha256);
  const claim = claimFor(fixture.expected);
  const finalized: Array<Parameters<PublicationWorkerStore["finalize"]>[2]> = [];
  let attempts = 0;
  const store: PublicationWorkerStore = {
    claimNext: async () => attempts++ < 2 ? claim : undefined,
    bindQuarantineVersion: async (_claim, _time, quarantineVersion) => ({
      allocationPublicID: claim.allocationPublicID,
      quarantineKey: claim.quarantineKey,
      quarantineVersion,
      archiveSHA256: claim.archiveSHA256,
      archiveManifestSHA256: claim.archiveManifestSHA256,
      archiveByteCount: claim.archiveByteCount,
    }),
    reject: async () => { throw new Error("unexpected_rejection"); },
    finalize: async (_claim, _time, input) => {
      finalized.push(input);
      if (finalized.length === 1) throw unavailable();
      return { status: "published", snapshotID: `snp_${"s".repeat(16)}` };
    },
  };
  const worker = new PublicationValidationWorker({
    clock: { now: () => new Date("2030-01-01T00:00:00.000Z") },
    store,
    objects: new PublicationObjectAdapter(objects),
  });

  assert.deepEqual(await worker.runOnce(), { status: "retry" }, "a finalizer transport failure cannot turn into a guessed source rejection");
  assert.ok(objects.activePutAttempts > 0, "the first run reached real immutable derivative promotion");
  assert.deepEqual(await worker.runOnce(), { status: "published", allocationID: PUA, snapshotID: `snp_${"s".repeat(16)}` });
  assert.equal(finalized.length, 2);
  const assets = finalized.at(-1)!.assets;
  assert.ok(assets.some((asset) => asset.kind === "presentation"));
  assert.ok(assets.some((asset) => asset.kind === "floor_plan_pdf"), "the Core presentation explicitly enables the passive floor-plan fallback");
  assert.ok(assets.some((asset) => asset.kind === "gallery_zip"), "the Core presentation explicitly enables the static gallery fallback");
  assert.ok(assets.every((asset) => asset.objectKey.startsWith("server/published/active/v1/pua_")));
  assert.equal(JSON.stringify(assets).match(/raw|depth|confidence|world.?map|diagnostic|private.?note/iu), null, "only the validator's positive allowlist reaches finalization");
  assert.ok(objects.activeConflictReuse > 0, "retry used the immutable byte-identical derivative instead of overwriting a partial active object");
});

test("worker rejects an approval/source binding mismatch before any active derivative is written", async () => {
  const fixture = loadFixture("room-v2-ai-ready");
  const objects = new InMemoryPublicationObjects(fixture.archive, fixture.expected.archive.sha256);
  const claim = { ...claimFor(fixture.expected), approvalSHA256: "f".repeat(64) };
  const rejected: string[] = [];
  const worker = new PublicationValidationWorker({
    clock: { now: () => new Date("2030-01-01T00:00:00.000Z") },
    store: {
      claimNext: async () => claim,
      bindQuarantineVersion: async (_claim, _time, quarantineVersion) => ({
        allocationPublicID: claim.allocationPublicID,
        quarantineKey: claim.quarantineKey,
        quarantineVersion,
        archiveSHA256: claim.archiveSHA256,
        archiveManifestSHA256: claim.archiveManifestSHA256,
        archiveByteCount: claim.archiveByteCount,
      }),
      reject: async (_claim, _time, code) => { rejected.push(code); },
      finalize: async () => { throw new Error("must_not_finalize"); },
    },
    objects: new PublicationObjectAdapter(objects),
  });
  assert.deepEqual(await worker.runOnce(), { status: "rejected", allocationID: PUA, reason: "approval_changed" });
  assert.deepEqual(rejected, ["approval_changed"]);
  assert.equal(objects.activePutAttempts, 0, "the source/approval closure guard runs before promotion");
});

test("worker captures the quarantine head only after a targetless claim, binds that exact version under its lease, then opens the bound version", async () => {
  const fixture = loadFixture("room-v2-ai-ready");
  const events: string[] = [];
  const objects = new InMemoryPublicationObjects(fixture.archive, fixture.expected.archive.sha256, events);
  const claim = claimFor(fixture.expected);
  const store = {
    claimNext: async () => { events.push("claim"); return claim; },
    bindQuarantineVersion: async (input: { readonly allocationInternalID: string; readonly leaseID: string }, _time: Date, version: string) => {
      events.push(`bind:${version}`);
      assert.equal(input.allocationInternalID, CLAIM_BASE.allocationInternalID);
      assert.equal(input.leaseID, CLAIM_BASE.leaseID);
      return {
        allocationPublicID: claim.allocationPublicID,
        quarantineKey: claim.quarantineKey,
        quarantineVersion: version,
        archiveSHA256: claim.archiveSHA256,
        archiveManifestSHA256: claim.archiveManifestSHA256,
        archiveByteCount: claim.archiveByteCount,
      };
    },
    reject: async () => { throw new Error("unexpected_rejection"); },
    finalize: async () => ({ status: "published" as const, snapshotID: `snp_${"s".repeat(16)}` }),
  } as unknown as PublicationWorkerStore;
  const worker = new PublicationValidationWorker({
    clock: { now: () => new Date("2030-01-01T00:00:00.000Z") },
    store,
    objects: new PublicationObjectAdapter(objects),
  });

  assert.deepEqual(await worker.runOnce(), { status: "published", allocationID: PUA, snapshotID: `snp_${"s".repeat(16)}` });
  assert.deepEqual(events.slice(0, 4), ["claim", "head-quarantine", "bind:quarantine-version/one", "head-quarantine"], "the worker cannot validate a pre-claim version or bind before it has captured the current isolated object");
});

function claimFor(expected: FixtureExpectation): PublicationWorkerClaim {
  return {
    ...CLAIM_BASE,
    sourceBindingsSHA256: expected.sourceBindingsSHA256,
    selectionManifestSHA256: expected.selectionManifestSHA256,
    approvalSHA256: expected.approvalSHA256,
    archiveSHA256: expected.archive.sha256,
    archiveManifestSHA256: expected.publicationManifest.sha256,
    archiveByteCount: expected.archive.byteCount,
    quarantineKey: mapPublicationQuarantineStorageKey({ allocationPublicID: PUA }),
  };
}

interface FixtureExpectation {
  readonly archive: { readonly byteCount: number; readonly sha256: string };
  readonly publicationManifest: { readonly byteCount: number; readonly sha256: string };
  readonly sourceBindingsSHA256: string;
  readonly selectionManifestSHA256: string;
  readonly approvalSHA256: string;
}

function loadFixture(name: string): Readonly<{ readonly archive: Uint8Array; readonly expected: FixtureExpectation }> {
  const expectations = JSON.parse(readFileSync(resolve(ROOT, "expectations.json"), "utf8")) as { readonly fixtures: readonly Readonly<{ readonly name: string } & FixtureExpectation>[] };
  const expected = expectations.fixtures.find((fixture) => fixture.name === name);
  assert.notEqual(expected, undefined);
  return Object.freeze({ archive: Uint8Array.from(Buffer.from(readFileSync(resolve(ROOT, `${name}.zip.base64`), "utf8").trim(), "base64")), expected: expected! });
}

class InMemoryPublicationObjects implements PublicationObjectProvider {
  readonly #objects = new Map<string, Readonly<{ readonly bytes: Uint8Array; readonly versionId: string; readonly contentType: PublicationContentType }>>();
  activePutAttempts = 0;
  activeConflictReuse = 0;
  constructor(archive: Uint8Array, digest: string, private readonly events: string[] = []) {
    this.#objects.set(mapPublicationQuarantineStorageKey({ allocationPublicID: PUA }), Object.freeze({ bytes: Uint8Array.from(archive), versionId: "quarantine-version/one", contentType: "application/zip" }));
    assert.equal(createHash("sha256").update(archive).digest("hex"), digest, "positive control uses the exact Core archive bytes");
  }
  async presignImmutablePut(): Promise<never> { throw new Error("unused"); }
  async headCurrent({ physicalKey }: { readonly physicalKey: string }) {
    if (physicalKey.includes("/quarantine/")) this.events.push("head-quarantine");
    const object = this.#objects.get(physicalKey); if (object === undefined) throw new Error("not_found");
    return Object.freeze({ versionId: object.versionId, contentLength: object.bytes.byteLength, contentType: object.contentType, checksumSha256: createHash("sha256").update(object.bytes).digest("base64") });
  }
  async readRangeExact({ physicalKey, versionId, offset, length }: { readonly physicalKey: string; readonly versionId: string; readonly offset: number; readonly length: number }): Promise<Uint8Array> {
    const object = this.#objects.get(physicalKey); if (object === undefined || object.versionId !== versionId) throw new Error("not_found");
    return Uint8Array.from(object.bytes.subarray(offset, offset + length));
  }
  async putImmutable({ physicalKey, bytes, contentType }: { readonly physicalKey: string; readonly bytes: Uint8Array; readonly contentType: PublicationContentType; readonly ifNoneMatch: "*" }) {
    this.activePutAttempts += 1;
    if (this.#objects.has(physicalKey)) { this.activeConflictReuse += 1; throw new Error("precondition_failed"); }
    const versionId = `active-version-${this.activePutAttempts}`;
    this.#objects.set(physicalKey, Object.freeze({ bytes: Uint8Array.from(bytes), versionId, contentType }));
    return Object.freeze({ versionId });
  }
}

function unavailable(): PublicationWorkerStoreError { return new PublicationWorkerStoreError("unavailable"); }
