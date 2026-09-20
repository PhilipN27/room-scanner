import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";

import type { DataApiClient, SqlResult } from "../src/adapters/data-api.js";
import { PublicationObjectAdapter, type PublicationObjectProvider } from "../src/adapters/s3-publication.js";
import {
  createSlice6DataApiPublicationHandler,
  createSlice6DataApiPortalDeliveryHandler,
  createSlice6PublicationWorker,
  Slice6PublicationCompositionError,
} from "../src/composition/publication-application.js";
import { createSlice6FeedbackDeliveryWorker } from "../src/composition/runtime.js";
import type { ApiGatewayV2Request } from "../src/handlers/factory.js";
import { DataApiPublicationFeedbackDeliveryWorker } from "../src/persistence/publication-feedback-delivery.js";

const ARCHIVE = Uint8Array.from([0x50, 0x4b, 0x05, 0x06, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);

test("Slice 6 production composition wires only narrow provider, Data API, clock, wake, and frozen legacy ports", async () => {
  const client = new IdleDataApiClient();
  const storage = new PublicationObjectAdapter(provider(ARCHIVE));
  const legacy = async (_request: ApiGatewayV2Request) => ({
    statusCode: 200,
    headers: { "cache-control": "no-store", "content-type": "application/json" },
    body: JSON.stringify({ legacy: true }),
  });
  const dependencies = {
    legacy,
    client,
    clock: { now: () => new Date("2030-01-01T00:00:00.000Z") },
    accessTokenHmacKey: Buffer.alloc(32, 0x51),
    storage,
    validationWake: { notifyPublicationValidationWake: async () => undefined },
    feedbackEnvelopeSealer: { seal: () => ({ keyID: "feedback-v1", iv: Buffer.alloc(12, 1), ciphertext: Buffer.alloc(32, 2), authenticationTag: Buffer.alloc(16, 3) }) },
    feedbackDeliveryWake: { notifyFeedbackDeliveryWake: async () => undefined },
    portalOrigin: "https://app.roomscanstudio.test",
    portalDocument: safePortalDocument(),
  } as const;

  const handler = createSlice6DataApiPublicationHandler(dependencies);
  assert.deepEqual(await handler({ version: "2.0", rawPath: "/health", rawQueryString: "", requestContext: { http: { method: "GET" } } }), await legacy({ version: "2.0", rawPath: "/health", rawQueryString: "", requestContext: { http: { method: "GET" } } }));

  const worker = createSlice6PublicationWorker(dependencies);
  assert.deepEqual(await worker.runOnce(), { status: "idle" }, "the worker receives a targetless claim source; no request can select a tenant or object key");
  assert.equal(client.statements.length, 1);
  assert.match(client.statements[0]?.sql ?? "", /publication_claim_job_v1/u);
});

test("production Slice 6 compositions select disjoint PrivateApi and PortalDelivery entrypoints instead of the all-routes test helper", async () => {
  const storage = new PublicationObjectAdapter(provider(ARCHIVE));
  const dependencies = {
    legacy: async (_request: ApiGatewayV2Request) => ({ statusCode: 200, headers: { "cache-control": "no-store", "content-type": "application/json" }, body: "{}" }),
    client: new IdleDataApiClient(),
    clock: { now: () => new Date("2030-01-01T00:00:00.000Z") },
    accessTokenHmacKey: Buffer.alloc(32, 0x59),
    storage,
    validationWake: { notifyPublicationValidationWake: async () => undefined },
    feedbackEnvelopeSealer: { seal: () => ({ keyID: "feedback-v1", iv: Buffer.alloc(12, 1), ciphertext: Buffer.alloc(32, 2), authenticationTag: Buffer.alloc(16, 3) }) },
    feedbackDeliveryWake: { notifyFeedbackDeliveryWake: async () => undefined },
    portalDocument: safePortalDocument(),
  } as const;
  const privateApi = createSlice6DataApiPublicationHandler(dependencies);
  const portalDelivery = createSlice6DataApiPortalDeliveryHandler({
    client: dependencies.client,
    clock: dependencies.clock,
    accessTokenHmacKey: dependencies.accessTokenHmacKey,
    storage: dependencies.storage,
    validationWake: dependencies.validationWake,
    feedbackEnvelopeSealer: dependencies.feedbackEnvelopeSealer,
    feedbackDeliveryWake: dependencies.feedbackDeliveryWake,
    portalDocument: dependencies.portalDocument,
  });

  assert.equal((await privateApi({ version: "2.0", rawPath: "/p", rawQueryString: "", requestContext: { http: { method: "GET" } } })).statusCode, 404);
  assert.equal((await portalDelivery({ version: "2.0", rawPath: "/p", rawQueryString: "", requestContext: { http: { method: "GET" } } })).statusCode, 200);
  assert.equal((await portalDelivery({ version: "2.0", rawPath: "/health", rawQueryString: "", requestContext: { http: { method: "GET" } } })).statusCode, 404);
});

test("private API omits portal assets while PortalDelivery fails closed when its static document seam is absent or unsafe", () => {
  const dependencies = {
    legacy: async (_request: ApiGatewayV2Request) => ({ statusCode: 200, headers: { "cache-control": "no-store", "content-type": "application/json" }, body: "{}" }),
    client: new IdleDataApiClient(),
    clock: { now: () => new Date("2030-01-01T00:00:00.000Z") },
    accessTokenHmacKey: Buffer.alloc(32, 0x55),
    storage: new PublicationObjectAdapter(provider(ARCHIVE)),
    validationWake: { notifyPublicationValidationWake: async () => undefined },
    feedbackEnvelopeSealer: { seal: () => ({ keyID: "feedback-v1", iv: Buffer.alloc(12, 1), ciphertext: Buffer.alloc(32, 2), authenticationTag: Buffer.alloc(16, 3) }) },
    feedbackDeliveryWake: { notifyFeedbackDeliveryWake: async () => undefined },
  } as const;
  assert.doesNotThrow(
    () => createSlice6DataApiPublicationHandler(dependencies),
    "the private API root carries no static portal bytes",
  );
  assert.throws(
    () => createSlice6DataApiPortalDeliveryHandler(dependencies as unknown as Parameters<typeof createSlice6DataApiPortalDeliveryHandler>[0]),
    (error: unknown) => error instanceof Slice6PublicationCompositionError && error.code === "invalid_composition",
    "PortalDelivery cannot silently fall back to an embedded fragment shell when build assets are missing",
  );
  assert.throws(
    () => createSlice6DataApiPortalDeliveryHandler({ ...dependencies, portalDocument: { stylesheet: Uint8Array.of(0xff), script: Uint8Array.from(Buffer.from("import('https://evil.example/module.js')", "utf8")) } }),
    (error: unknown) => error instanceof Slice6PublicationCompositionError && error.code === "invalid_composition",
    "the seam validates fatal UTF-8 and rejects network imports before route creation",
  );
});

test("Slice 6 feedback delivery composition exposes only the isolated email worker ports", () => {
  const worker = createSlice6FeedbackDeliveryWorker({
    client: new IdleDataApiClient(),
    clock: { nowMs: () => Date.UTC(2030, 0, 1) },
    random: { bytes: (length) => Buffer.alloc(length, 0x5a) },
    decryptionKeys: { resolve: async () => Buffer.alloc(32, 0x6a) },
    delivery: { send: async () => undefined },
    leaseMs: 60_000,
  });
  assert.equal(worker instanceof DataApiPublicationFeedbackDeliveryWorker, true, "the portal/API composition cannot substitute an arbitrary post-commit feedback callback for the email-runtime worker");
});

class IdleDataApiClient implements DataApiClient {
  readonly statements: Array<Parameters<DataApiClient["execute"]>[0]> = [];
  async begin(): Promise<{ readonly transactionId: string }> { return { transactionId: "publication-composition" }; }
  async commit(): Promise<void> { /* claim reads have no material side effect */ }
  async rollback(): Promise<void> { /* claim reads have no material side effect */ }
  async execute(input: Parameters<DataApiClient["execute"]>[0]): Promise<SqlResult> { this.statements.push(input); return { rows: [] }; }
}

function provider(bytes: Uint8Array): PublicationObjectProvider {
  const checksumSha256 = createHash("sha256").update(bytes).digest("base64");
  return {
    presignImmutablePut: async () => ({ url: "https://upload.roomscanstudio.test/publication", headers: { "content-length": String(bytes.byteLength), "content-type": "application/zip", "x-amz-checksum-sha256": checksumSha256, "if-none-match": "*" } }),
    headCurrent: async () => ({ versionId: "v1", contentLength: bytes.byteLength, contentType: "application/zip", checksumSha256 }),
    readRangeExact: async ({ offset, length }) => Uint8Array.from(bytes.subarray(offset, offset + length)),
    putImmutable: async () => ({ versionId: "v1" }),
  };
}

function safePortalDocument() {
  return Object.freeze({
    stylesheet: Uint8Array.from(Buffer.from(":root{color-scheme:light}", "utf8")),
    script: Uint8Array.from(Buffer.from("\"use strict\";(()=>{history.replaceState(null,\"\",\"/p\");})();", "utf8")),
  });
}
