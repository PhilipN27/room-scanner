import assert from "node:assert/strict";
import test from "node:test";

import { ProjectSyncObjectAdapter, type ProjectSyncObjectProvider } from "../src/adapters/s3-project-sync.js";
import type { DataApiClient, SqlResult } from "../src/adapters/data-api.js";
import { requireProjectSyncRepositories, DataApiProjectSyncOperationPort } from "../src/persistence/project-sync-capabilities.js";

const principalId = "11111111-1111-4111-8111-111111111111";
const familyId = "22222222-2222-4222-8222-222222222222";
const workspaceId = "33333333-3333-4333-8333-333333333333";
const access = "t".repeat(32);
const projectID = `prj_${"a".repeat(16)}`;
const revisionID = `rev_${"b".repeat(16)}`;
const uploadID = `upl_${"c".repeat(16)}`;
const digest = "a".repeat(64);

test("allocation reducer commits its durable allocation before the server-owned immutable presign", async () => {
  const events: string[] = [];
  const client = new ProjectSyncDataApiFake(events);
  const storage = storageAdapter(events);
  const port = new DataApiProjectSyncOperationPort({
    client, clock: { now: () => new Date("2030-01-01T00:00:00.000Z") }, accessTokenHmacKey: Buffer.alloc(32, 1), leaseHmacKey: Buffer.alloc(32, 2), storage,
    validationWake: { notifyValidationWake: async () => { events.push("wake"); } },
  });
  const result = await port.run({ accessToken: access, authorization: { kind: "workspace", action: "project.create", resourceResolver: "none" } }, async (context) => {
    const repository = requireProjectSyncRepositories(context.repositories, context.transactionMarker).projectSync;
    const prepared = await repository.allocateMigration({
      sourceProjectID: "project-001", proposedRevisionID: "revision-001", workingSetManifestSHA256: digest, archiveSHA256: digest, archiveByteCount: 1024,
      idempotencyKey: "idempotency-key-0001", quotaPolicyVersion: 1, hostedGlobalVersion: 1, hostedWorkspaceVersion: 1,
    });
    return prepared.toPostCommitResult();
  });
  assert.equal(result.uploadID, uploadID);
  assert.equal(result.uploadURL, "https://upload.example/immutable");
  assert.ok(events.indexOf("commit") < events.indexOf("presign"), "provider presign is strictly post-commit");
  assert.equal(events.includes("wake"), false);
  const allocationSql = client.statements.find((statement) => statement.sql.includes("allocate_project_migration_v1"));
  assert.match(allocationSql?.sql ?? "", /allocate_project_migration_v1/u);
  assert.equal(JSON.stringify(allocationSql).includes("professional-sync/"), false, "API reducer receives no logical/provider storage key");
});

test("completion commits validation_pending before targetless wake; a failed response recovers through status", async () => {
  const events: string[] = [];
  const client = new ProjectSyncDataApiFake(events);
  let wakeAttempts = 0;
  const port = new DataApiProjectSyncOperationPort({
    client, clock: { now: () => new Date("2030-01-01T00:00:00.000Z") }, accessTokenHmacKey: Buffer.alloc(32, 1), leaseHmacKey: Buffer.alloc(32, 2), storage: storageAdapter(events),
    validationWake: { notifyValidationWake: async () => { events.push("wake"); wakeAttempts += 1; throw new Error("synthetic queue outage"); } },
  });
  await assert.rejects(port.run({ accessToken: access, authorization: { kind: "workspace", action: "project.revise", resourceResolver: "upload" } }, async (context) => {
    const repository = requireProjectSyncRepositories(context.repositories, context.transactionMarker).projectSync;
    return (await repository.completeUpload(uploadID)).toPostCommitResult();
  }));
  assert.ok(events.indexOf("commit") < events.indexOf("wake"), "queue wake cannot precede durable validation_pending");
  assert.equal(wakeAttempts, 1);
  const recovered = await port.run({ accessToken: access, authorization: { kind: "workspace", action: "project.read", resourceResolver: "upload" } }, async (context) => {
    const repository = requireProjectSyncRepositories(context.repositories, context.transactionMarker).projectSync;
    return (await repository.uploadStatus(uploadID)).toPostCommitResult();
  });
  assert.equal(recovered.status, "validationPending", "the client learns committed completion through status after a response/wake failure");
});

test("recovery keeps working when hosted writes are disabled, but exact storage signing happens only after live authorization transaction commits", async () => {
  const events: string[] = [];
  const client = new ProjectSyncDataApiFake(events, { hostedEnabled: false });
  const port = new DataApiProjectSyncOperationPort({
    client, clock: { now: () => new Date("2030-01-01T00:00:00.000Z") }, accessTokenHmacKey: Buffer.alloc(32, 1), leaseHmacKey: Buffer.alloc(32, 2), storage: storageAdapter(events),
    validationWake: { notifyValidationWake: async () => { events.push("wake"); } },
  });
  const recovery = await port.run({ accessToken: access, authorization: { kind: "workspace", action: "private.download", resourceResolver: "revision" } }, async (context) => {
    const repository = requireProjectSyncRepositories(context.repositories, context.transactionMarker).projectSync;
    return (await repository.allocateRecovery({ projectID, revisionID })).toPostCommitResult();
  });
  assert.equal(recovery.downloadURL, "https://download.example/exact-version");
  assert.equal("logicalKey" in recovery, false);
  assert.equal("versionId" in recovery, false);
  assert.ok(events.indexOf("commit") < events.indexOf("download"));
  const resolver = client.statements.find((statement) => statement.sql.includes("resolve_project_recovery_storage_v1"));
  assert.ok(resolver, "internal resolver runs inside the API transaction");
});

class ProjectSyncDataApiFake implements DataApiClient {
  readonly statements: Array<{ readonly sql: string; readonly parameters?: readonly import("../src/adapters/data-api.js").SqlParameter[] }> = [];
  #nextTransaction = 0;
  constructor(private readonly events: string[], private readonly options: { readonly hostedEnabled?: boolean } = {}) {}
  async begin(): Promise<{ readonly transactionId: string }> { this.events.push("begin"); return { transactionId: `sync-tx-${this.#nextTransaction++}` }; }
  async execute(input: Parameters<DataApiClient["execute"]>[0]): Promise<SqlResult> {
    this.statements.push({ sql: input.sql, ...(input.parameters === undefined ? {} : { parameters: input.parameters }) });
    if (input.sql.includes("resolve_access_context")) return { rows: [accessContextRow()] };
    if (input.sql.includes("read_workspace_authorization_state")) return { rows: [workspaceStateRow(this.options.hostedEnabled ?? true)] };
    if (input.sql.includes("allocate_project_migration_v1")) return { rows: [uploadRow("allocated")] };
    if (input.sql.includes("complete_project_upload_v1") || input.sql.includes("read_project_upload_status_v1")) return { rows: [uploadRow("validation_pending")] };
    if (input.sql.includes("allocate_project_recovery_v1")) return { rows: [recoveryPublicRow()] };
    if (input.sql.includes("resolve_project_recovery_storage_v1")) return { rows: [recoveryStorageRow()] };
    return { rows: [] };
  }
  async commit(): Promise<void> { this.events.push("commit"); }
  async rollback(): Promise<void> {
    this.events.push("rollback");
  }
}

function storageAdapter(events: string[]): ProjectSyncObjectAdapter {
  const provider: ProjectSyncObjectProvider = {
    presignImmutablePut: async () => {
      events.push("presign");
      return { url: "https://upload.example/immutable", headers: { "content-length": "1024", "content-type": "application/zip", "x-amz-checksum-sha256": Buffer.from(digest, "hex").toString("base64"), "if-none-match": "*" } };
    },
    headCurrent: async () => ({ versionId: "v+1/opaque", contentLength: 1, contentType: "application/zip", checksumSha256: Buffer.alloc(32).toString("base64") }),
    readExact: async () => ({ versionId: "v+1/opaque", bytes: Uint8Array.of(0), contentType: "application/zip", checksumSha256: Buffer.alloc(32).toString("base64") }),
    copyImmutable: async () => ({ versionId: "v+1/opaque" }),
    presignExactDownload: async () => { events.push("download"); return { url: "https://download.example/exact-version" }; },
  };
  return new ProjectSyncObjectAdapter(provider);
}

function accessContextRow() {
  return { principal_id: principalId, canonical_principal_id: "principal-public", family_id: familyId, family_public_id: "family-public", workspace_id: workspaceId, role: "owner", authorization_version: 7, authentication_epoch: 2, authenticated_at: "2030-01-01T00:00:00.000Z", recent_authentication: true } as const;
}
function workspaceStateRow(hostedEnabled: boolean) {
  return {
    principal_id: principalId, principal_canonical_id: "principal-public", family_id: familyId, family_public_id: "family-public", workspace_id: workspaceId, workspace_slug: "workspace", workspace_display_name: "Workspace", role: "owner", authorization_version: 7, authentication_epoch: 2, authenticated_at: "2030-01-01T00:00:00.000Z", recent_authentication: true,
    professional_sign_in_global_enabled: true, professional_sign_in_global_version: 1,
    hosted_global_enabled: hostedEnabled, hosted_global_version: 1, hosted_workspace_enabled: hostedEnabled, hosted_workspace_version: 1,
    publication_global_enabled: false, publication_global_version: 1, publication_workspace_enabled: false, publication_workspace_version: 1, editor_publishing_allowed: false, editor_publishing_policy_version: 1,
  } as const;
}
function uploadRow(status: "allocated" | "validation_pending") {
  return { status, project_public_id: projectID, upload_public_id: uploadID, candidate_revision_public_id: revisionID, current_hosted_head_revision_public_id: revisionID, working_digest: Buffer.from(digest, "hex"), working_bytes: 1024, raw_digest: null, raw_bytes: null, allocation_expires_at: "2030-01-01T00:05:00.000Z" };
}
function recoveryPublicRow() {
  return { project_public_id: projectID, target_revision_public_id: revisionID, branch_state: "canonical", working_manifest_digest: Buffer.from(digest, "hex"), working_digest: Buffer.from(digest, "hex"), working_bytes: 1024 };
}
function recoveryStorageRow() {
  return { ...recoveryPublicRow(), working_object_key: `professional-sync/active/working/${revisionID}.zip`, working_object_version: "3/L4kqtJlcpXroDTDmJ+3DcjkqQq2jAY+8/dK" };
}
