import assert from "node:assert/strict";
import test from "node:test";

import type { DataApiClient, SqlResult } from "../src/adapters/data-api.js";
import { DataApiProjectSyncWorkerStore, ProjectSyncWorkerStoreError } from "../src/persistence/project-sync-worker-store.js";

const workspaceId = "33333333-3333-4333-8333-333333333333";
const uploadId = "44444444-4444-4444-8444-444444444444";
const digest = Buffer.alloc(32, 0x5a);

test("worker-only store maps the corrected claim source bindings and preserves opaque S3 versions", async () => {
  const client = new WorkerDataApiFake();
  const store = new DataApiProjectSyncWorkerStore({ client });
  const claim = await store.claimNext(new Date("2030-01-01T00:00:00.000Z"));
  assert.deepEqual(claim, {
    workspaceInternalId: workspaceId,
    uploadInternalId: uploadId,
    leaseId: `wkl_${"a".repeat(16)}`,
    operation: "append_revision",
    quarantineLogicalKey: `professional-sync/quarantine/working/upl_${"a".repeat(16)}.zip`,
    activeLogicalKey: `professional-sync/active/working/rev_${"b".repeat(16)}.zip`,
    projectSourceId: "project-001",
    candidateRevisionSourceId: "revision-002",
    workingManifestSha256: digest.toString("hex"),
    workingSha256: digest.toString("hex"),
    workingByteCount: 4096,
  });
  const outcome = await store.finalize(claim!, new Date("2030-01-01T00:00:01.000Z"), {
    quarantineVersionId: "3/L4kqtJlcpXroDTDmJ+3DcjkqQq2jAY+8/dK",
    activeVersionId: "3/L4active+copy/with/slashes",
  });
  assert.equal(outcome, "canonical");
  const statements = client.calls.map((call) => call.sql);
  assert.match(statements[0] ?? "", /claim_next_project_validation_v1\(\(:authoritative_time\)::timestamptz\)/u);
  assert.match(statements[1] ?? "", /finalize_project_upload_v1\(\(:upload_id\)::uuid/u);
  const finalize = client.calls[1]!;
  assert.deepEqual(finalize.parameters?.map((parameter) => parameter.value), [
    { kind: "string", value: uploadId, typeHint: "UUID" },
    { kind: "string", value: `wkl_${"a".repeat(16)}` },
    { kind: "string", value: "2030-01-01T00:00:01.000Z" },
    { kind: "string", value: "3/L4kqtJlcpXroDTDmJ+3DcjkqQq2jAY+8/dK" },
    { kind: "string", value: "3/L4active+copy/with/slashes" },
  ]);
  assert.equal(JSON.stringify(client.calls).includes("project_public_id"), false, "worker does not substitute a public ID for Core source bindings");
});

test("worker-only store rejects an old claim shape instead of falling back from server public IDs", async () => {
  const client = new WorkerDataApiFake({ project_source_project_id: undefined, archive_source_revision_id: undefined, source_project_id: "public-looking-fallback" } as never);
  const store = new DataApiProjectSyncWorkerStore({ client });
  await assert.rejects(
    store.claimNext(new Date("2030-01-01T00:00:00.000Z")),
    (error: unknown) => error instanceof ProjectSyncWorkerStoreError && error.code === "invalid_result",
  );
});

class WorkerDataApiFake implements DataApiClient {
  readonly calls: Array<{ readonly sql: string; readonly parameters?: readonly import("../src/adapters/data-api.js").SqlParameter[] }> = [];
  #counter = 0;
  constructor(private readonly overrides: Readonly<Record<string, unknown>> = {}) {}
  async begin(): Promise<{ readonly transactionId: string }> { return { transactionId: `worker-tx-${this.#counter++}` }; }
  async execute(input: Parameters<DataApiClient["execute"]>[0]): Promise<SqlResult> {
    this.calls.push({ sql: input.sql, ...(input.parameters === undefined ? {} : { parameters: input.parameters }) });
    if (input.sql.includes("claim_next_project_validation_v1")) return { rows: [{
      workspace_id: workspaceId, upload_id: uploadId, lease_id: `wkl_${"a".repeat(16)}`,
      operation: "append_revision", quarantine_key: `professional-sync/quarantine/working/upl_${"a".repeat(16)}.zip`, active_object_key: `professional-sync/active/working/rev_${"b".repeat(16)}.zip`,
      project_source_project_id: "project-001", archive_source_revision_id: "revision-002",
      working_manifest_digest: Uint8Array.from(digest), working_digest: Uint8Array.from(digest), working_bytes: 4096,
      raw_manifest_digest: null, raw_digest: null, raw_bytes: null, raw_review_digest: null,
      ...this.overrides,
    }] };
    if (input.sql.includes("finalize_project_upload_v1")) return { rows: [{ status: "canonical" }] };
    return { rows: [{ reaped_count: 0 }] };
  }
  async commit(): Promise<void> {}
  async rollback(): Promise<void> {}
}
