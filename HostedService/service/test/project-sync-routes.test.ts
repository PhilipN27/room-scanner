import assert from "node:assert/strict";
import test from "node:test";

import { SLICE4_ROUTE_MANIFEST, SLICE4_ROUTE_SET_VERSION, SLICE5_ROUTE_MANIFEST, SLICE5_ROUTE_SET_VERSION } from "../src/contracts/route-manifest.js";
import { SLICE5_OPENAPI } from "../src/contracts/openapi.js";
import { PROJECT_SYNC_VALIDATION_WAKE_QUEUE } from "../src/contracts/project-sync.js";
import { mapProjectSyncLogicalStorageKey } from "../src/adapters/s3-project-sync.js";
import {
  createSlice5HandlerEntrypoint,
  createSlice5PostCommitResult,
  requireSlice5PostCommitEffect,
  type ApiGatewayV2Request,
  type AuthorizedOperationContext,
  type RouteHandler,
  type Slice5RouteHandler,
} from "../src/handlers/factory.js";

test("Slice 5 adds exactly ten sealed routes without changing frozen Slice 4 v3", () => {
  assert.equal(SLICE4_ROUTE_SET_VERSION, "roomscan-slice4-routes-v3");
  assert.equal(SLICE4_ROUTE_MANIFEST.length, 19);
  assert.equal(SLICE5_ROUTE_SET_VERSION, "roomscan-slice5-routes-v1");
  assert.equal(SLICE5_ROUTE_MANIFEST.length, 29);
  assert.deepEqual(
    SLICE5_ROUTE_MANIFEST.slice(19).map((route) => `${route.method} ${route.pathTemplate} ${route.id}`),
    [
      "POST /projects/migration/allocate project.migration.allocate",
      "POST /projects/revisions/allocate project.revision.allocate",
      "POST /projects/uploads/complete project.upload.complete",
      "POST /projects/uploads/status project.upload.status",
      "POST /projects/recovery/allocate project.recovery.allocate",
      "POST /projects/edit-lease/acquire project.edit-lease.acquire",
      "POST /projects/edit-lease/renew project.edit-lease.renew",
      "POST /projects/edit-lease/release project.edit-lease.release",
      "POST /projects/raw-archive/configure project.raw-archive.configure",
      "POST /projects/raw-archive/allocate project.raw-archive.allocate",
    ],
  );
  assert.equal(Object.keys(SLICE5_OPENAPI.paths).length, 29);
  assert.equal(PROJECT_SYNC_VALIDATION_WAKE_QUEUE, "roomscan-project-validation-wake-v1");
});

test("all hosted archive allocation routes cap a single immutable archive at 64 MiB", () => {
  const byID = new Map(SLICE5_ROUTE_MANIFEST.map((route) => [route.id, route]));
  for (const id of [
    "project.migration.allocate",
    "project.revision.allocate",
    "project.raw-archive.allocate",
  ]) {
    const field = byID.get(id)?.request.fields?.archiveByteCount;
    assert.equal(field?.type, "integer", `${id} must validate archiveByteCount as an integer`);
    assert.equal(field?.minimum, 1, `${id} must reject an empty archive`);
    assert.equal(field?.maximum, 67_108_864, `${id} must reject a 64 MiB + 1 archive before allocation`);
  }
});

test("storage mapping accepts only the persisted logical grammar and binds physical keys to one server workspace", () => {
  const mapped = mapProjectSyncLogicalStorageKey({
    workspaceInternalId: "33333333-3333-4333-8333-333333333333",
    logicalKey: `professional-sync/quarantine/working/upl_${"a".repeat(22)}.zip`,
  });
  assert.match(mapped, /^server\/quarantine\/v1\/[a-f0-9]{24}\/professional-sync\/quarantine\/working\/upl_a{22}\.zip$/u);
  assert.throws(
    () => mapProjectSyncLogicalStorageKey({
      workspaceInternalId: "33333333-3333-4333-8333-333333333333",
      logicalKey: "professional-sync/quarantine/working/../../escape.zip",
    }),
    /invalid_project_sync_storage_key/u,
  );
  assert.notEqual(mapped, mapProjectSyncLogicalStorageKey({
    workspaceInternalId: "44444444-4444-4444-8444-444444444444",
    logicalKey: `professional-sync/quarantine/working/upl_${"a".repeat(22)}.zip`,
  }));
  assert.notEqual(mapped, mapProjectSyncLogicalStorageKey({
    workspaceInternalId: "33333333-3333-4333-8333-333333333333",
    logicalKey: `professional-sync/quarantine/working/upl_${"b".repeat(22)}.zip`,
  }), "distinct server-minted logical keys cannot collide physically");
});

test("Slice 5 entrypoint delegates frozen public/protected routes and runs only sync effects after commit", async () => {
  const events: string[] = [];
  const marker = Symbol("test");
  const context: AuthorizedOperationContext = {
    principalPublicId: "principal-public",
    transactionMarker: marker,
    repositories: { contract: "roomscan-transaction-repositories-v1", transactionMarker: marker },
  };
  const legacyHandlers = Object.fromEntries(SLICE4_ROUTE_MANIFEST.map((route) => [route.id, async () => response(200, { legacy: route.id })])) as Readonly<Record<string, RouteHandler>>;
  const syncHandlers = Object.fromEntries(SLICE5_ROUTE_MANIFEST.slice(SLICE4_ROUTE_MANIFEST.length).map((route) => [route.id, async () => createSlice5PostCommitResult(
    () => { events.push("sync-response"); return response(route.id === "project.upload.complete" ? 202 : 200, { sync: route.id }); },
    async () => { events.push("sync-effect"); },
  )])) as Readonly<Record<string, Slice5RouteHandler>>;
  const handler = createSlice5HandlerEntrypoint({
    legacy: {
      handlers: legacyHandlers,
      operations: {
        run: async (_input, operation) => {
          events.push("legacy-transaction");
          return operation(context);
        },
      },
    },
    handlers: syncHandlers,
    operations: {
      run: async (_input, operation) => {
        events.push("sync-transaction");
        const result = await operation(context);
        events.push("sync-commit");
        await requireSlice5PostCommitEffect(result)();
        return result.publicResult();
      },
    },
  });

  assert.equal((await handler(request("GET", "/health"))).statusCode, 200, "public Slice 4 health is not put behind Slice 5 auth/effects");
  assert.equal((await handler(request("GET", "/workspace", undefined, { authorization: `Bearer ${"a".repeat(32)}` }))).statusCode, 200, "protected Slice 4 read retains its legacy same-UoW path");
  const sync = await handler(request("POST", "/projects/uploads/complete", JSON.stringify({ uploadID: `upl_${"a".repeat(16)}` }), { authorization: `Bearer ${"a".repeat(32)}`, "content-type": "application/json" }));
  assert.equal(sync.statusCode, 202);
  assert.deepEqual(events, ["legacy-transaction", "sync-transaction", "sync-commit", "sync-effect", "sync-response"]);
});

test("Slice 5 effect capability is nominal rather than a caller-forgeable boolean", async () => {
  const marker = Symbol("test");
  const context: AuthorizedOperationContext = { principalPublicId: "principal-public", transactionMarker: marker, repositories: { contract: "roomscan-transaction-repositories-v1", transactionMarker: marker } };
  const legacyHandlers = Object.fromEntries(SLICE4_ROUTE_MANIFEST.map((route) => [route.id, async () => response(200, { legacy: route.id })])) as Readonly<Record<string, RouteHandler>>;
  const forgedHandlers = Object.fromEntries(SLICE5_ROUTE_MANIFEST.slice(SLICE4_ROUTE_MANIFEST.length).map((route) => [route.id, async () => ({ publicResult: () => response(200, { sync: route.id }) })])) as unknown as Readonly<Record<string, Slice5RouteHandler>>;
  const handler = createSlice5HandlerEntrypoint({
    legacy: { handlers: legacyHandlers, operations: { run: async (_input, operation) => operation(context) } },
    handlers: forgedHandlers,
    operations: { run: async (_input, operation) => {
      const result = await operation(context);
      await requireSlice5PostCommitEffect(result)();
      return result.publicResult();
    } },
  });
  const result = await handler(request("POST", "/projects/uploads/status", JSON.stringify({ uploadID: `upl_${"a".repeat(16)}` }), { authorization: `Bearer ${"a".repeat(32)}`, "content-type": "application/json" }));
  assert.equal(result.statusCode, 500);
});

function request(method: "GET" | "POST", rawPath: string, body?: string, headers?: Readonly<Record<string, string>>): ApiGatewayV2Request {
  return { version: "2.0", rawPath, rawQueryString: "", ...(body === undefined ? {} : { body }), ...(headers === undefined ? {} : { headers }), requestContext: { http: { method } } };
}
function response(statusCode: number, body: unknown) { return { statusCode, headers: { "cache-control": "no-store", "content-type": "application/json" }, body: JSON.stringify(body) }; }
