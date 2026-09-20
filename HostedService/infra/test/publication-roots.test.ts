import assert from "node:assert/strict";
import test from "node:test";

import { PublicationObjectAdapter, type PublicationObjectProvider } from "roomscan-studio-hosted-service/adapters";

import {
  createPortalDeliveryRoot,
  type PortalDeliveryRootDependencies,
} from "../src/functions/portal-delivery.js";
import {
  createPublicationValidationRoot,
  PUBLICATION_VALIDATION_RECOVERY_BODY,
} from "../src/functions/publication-validation.js";
import { LambdaRuntimeConfigurationError } from "../src/functions/runtime-support.js";

const ACCOUNT = "111111111111";
const secret = (name: string) => `arn:aws:secretsmanager:us-east-1:${ACCOUNT}:secret:${name}-AbCdEf`;
const SAFE_PORTAL_DOCUMENT = Object.freeze({
  stylesheet: Uint8Array.from(Buffer.from(":root{color-scheme:light}#roomscan-portal{min-height:100vh}", "utf8")),
  script: Uint8Array.from(Buffer.from("\"use strict\";history.replaceState(null,\"\",\"/p\");", "utf8")),
});

function portalEnvironment(extra: Readonly<NodeJS.ProcessEnv> = {}): NodeJS.ProcessEnv {
  return {
    ROOMSCAN_STAGE: "dev",
    ROOMSCAN_REGION: "us-east-1",
    DB_CLUSTER_ARN: `arn:aws:rds:us-east-1:${ACCOUNT}:cluster:roomscan-dev`,
    ROOMSCAN_DB_ROLE_SECRET_ARN: secret("portal-role"),
    ROOMSCAN_DB_RUNTIME_ROLE: "roomscan_portal_runtime",
    ACCESS_TOKEN_HMAC_SECRET_ARN: secret("access-token"),
    PUBLICATION_FEEDBACK_ENVELOPE_SECRET_ARN: secret("feedback-envelope"),
    PUBLICATION_FEEDBACK_KEY_ID: "publication-feedback-v1",
    PUBLISHED_BUCKET_NAME: "roomscan-dev-published-111111111111",
    MAGIC_DELIVERY_QUEUE_URL: `https://sqs.us-east-1.amazonaws.com/${ACCOUNT}/roomscan-dev-email-delivery`,
    PORTAL_ORIGIN: "https://api.example.invalid",
    ...extra,
  };
}

function workerEnvironment(extra: Readonly<NodeJS.ProcessEnv> = {}): NodeJS.ProcessEnv {
  return {
    ROOMSCAN_STAGE: "dev",
    ROOMSCAN_REGION: "us-east-1",
    DB_CLUSTER_ARN: `arn:aws:rds:us-east-1:${ACCOUNT}:cluster:roomscan-dev`,
    ROOMSCAN_DB_ROLE_SECRET_ARN: secret("publication-worker-role"),
    ROOMSCAN_DB_RUNTIME_ROLE: "roomscan_publication_worker",
    PUBLISHED_BUCKET_NAME: "roomscan-dev-published-111111111111",
    ...extra,
  };
}

function client() {
  return {
    begin: async () => ({ transactionId: "tx_1" }),
    execute: async () => ({ rows: [] }),
    commit: async () => undefined,
    rollback: async () => undefined,
  };
}

function inertStorage(): PublicationObjectAdapter {
  const provider: PublicationObjectProvider = {
    presignImmutablePut: async () => ({ url: "https://example.invalid/upload", headers: {} }),
    headCurrent: async () => { throw new Error("not used"); },
    readRangeExact: async () => { throw new Error("not used"); },
    putImmutable: async () => { throw new Error("not used"); },
  };
  return new PublicationObjectAdapter(provider);
}

test("PortalDelivery constructs only its portal DB/secret/storage/wake capabilities and cannot delegate a private route", async () => {
  const secretReads: Array<readonly [string, string]> = [];
  const dependencies: PortalDeliveryRootDependencies = {
    dataClient: client,
    readSecret: async (arn, field) => {
      secretReads.push([arn, field]);
      return "k".repeat(64);
    },
    storage: inertStorage,
    feedbackWake: () => ({ notifyFeedbackDeliveryWake: async () => undefined }),
    portalDocument: SAFE_PORTAL_DOCUMENT,
  };
  const root = await createPortalDeliveryRoot(portalEnvironment(), dependencies);
  assert.equal((await root({
    version: "2.0", rawPath: "/p", rawQueryString: "", headers: {}, requestContext: { http: { method: "GET" } },
  })).statusCode, 200);
  assert.equal((await root({
    version: "2.0", rawPath: "/health", rawQueryString: "", headers: {}, requestContext: { http: { method: "GET" } },
  })).statusCode, 404);
  assert.deepEqual(secretReads, [
    [secret("access-token"), "key"],
    [secret("feedback-envelope"), "key"],
  ]);

  await assert.rejects(
    createPortalDeliveryRoot(portalEnvironment({ ROOMSCAN_DB_RUNTIME_ROLE: "roomscan_api_runtime" }), dependencies),
    (error: unknown) => error instanceof LambdaRuntimeConfigurationError && error.code === "invalid_configuration",
  );
});

test("publication validation accepts only fixed targetless wakes and maps retries without exposing a selector", async () => {
  let runs = 0;
  const root = await createPublicationValidationRoot(workerEnvironment(), {
    dataClient: client,
    worker: () => ({
      runOnce: async () => {
        runs += 1;
        return runs === 1 ? { status: "retry" as const } : { status: "idle" as const };
      },
    }),
  });
  assert.deepEqual(await root({ Records: [
    { messageId: "retry", body: JSON.stringify({ kind: "publication-validation-wake-v1" }) },
    { messageId: "idle", body: PUBLICATION_VALIDATION_RECOVERY_BODY },
    { messageId: "attacker", body: JSON.stringify({ kind: "publication-validation-wake-v1", allocationID: "pua_attacker_selected" }) },
  ] }), {
    batchItemFailures: [{ itemIdentifier: "retry" }, { itemIdentifier: "attacker" }],
  });
  assert.equal(runs, 2, "malformed queue payload never reaches the targetless worker claim");
});
