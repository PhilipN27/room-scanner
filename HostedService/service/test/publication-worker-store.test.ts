import assert from "node:assert/strict";
import test from "node:test";
import type { DataApiClient } from "../src/adapters/data-api.js";
import { DataApiPublicationWorkerStore } from "../src/persistence/publication-worker-store.js";

test("publication finalization encodes absent download kinds as JSON null, not a SQL-invalid empty string", async () => {
  let manifest: Array<Record<string, unknown>> | undefined;
  const client: DataApiClient = {
    begin: async () => ({ transactionId: "publication-worker-store-transaction" }),
    commit: async () => undefined,
    rollback: async () => undefined,
    execute: async ({ sql, parameters }) => {
      assert.match(sql, /publication_finalize_v1/u);
      const assets = parameters?.find((parameter) => parameter.name === "assets")?.value;
      assert.equal(assets?.kind, "string");
      if (assets?.kind === "string") manifest = JSON.parse(assets.value) as Array<Record<string, unknown>>;
      return { rows: [{ status: "published", snapshot_public_id: `snp_${"s".repeat(16)}` }] };
    },
  };
  const common = { assetID: `ast_${"a".repeat(16)}`, objectKey: "server/published/active/v1/allocation/asset.bin", objectVersion: "version-one", sha256: "a".repeat(64), byteCount: 10 };
  await new DataApiPublicationWorkerStore({ client }).finalize({ allocationInternalID: "11111111-1111-4111-8111-111111111111", leaseID: `pwl_${"l".repeat(16)}` }, new Date("2030-01-01T12:00:00.000Z"), {
    activeObjectVersion: "version-one", presentationSHA256: common.sha256, sourceBindingsSHA256: "b".repeat(64), presentationByteCount: 10,
    assets: [{ ...common, kind: "presentation", contentType: "application/json" }, { ...common, assetID: `ast_${"b".repeat(16)}`, kind: "floor_plan_pdf", contentType: "application/pdf", downloadKind: "floor_plan_pdf" }],
  });
  assert.ok(manifest);
  assert.equal(Object.hasOwn(manifest[0]!, "download_kind"), true, "the SQL closed schema requires the key");
  assert.equal(manifest[0]?.download_kind, null, "non-download derivatives must satisfy the live SQL manifest guard");
  assert.equal(manifest[1]?.download_kind, "floor_plan_pdf");
});
