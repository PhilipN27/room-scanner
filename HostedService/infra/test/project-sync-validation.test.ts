import assert from "node:assert/strict";
import test from "node:test";

import { createProjectSyncValidationRoot } from "../src/functions/project-sync-validation.js";

const account = "111111111111";

function environment(): NodeJS.ProcessEnv {
  return {
    ROOMSCAN_DB_RUNTIME_ROLE: "roomscan_project_sync_runtime",
    PROJECT_SYNC_BUCKET_NAME: "roomscan-dev-project-sync-111111111111",
    DB_CLUSTER_ARN: `arn:aws:rds:us-east-1:${account}:cluster:roomscan-dev`,
    ROOMSCAN_DB_ROLE_SECRET_ARN: `arn:aws:secretsmanager:us-east-1:${account}:secret:roomscan-project-sync-AbCdEf`,
  };
}

function dataClient() {
  return {
    begin: async () => ({ transactionId: "tx_1" }),
    execute: async () => ({ rows: [] }),
    commit: async () => undefined,
    rollback: async () => undefined,
  };
}

test("project-sync worker accepts only fixed targetless wake bodies and reports retryable work to SQS", async () => {
  let runs = 0;
  let outcome:
    | Readonly<{ readonly status: "idle"; readonly reaped: number }>
    | Readonly<{ readonly status: "retry"; readonly reaped: number }> = { status: "idle", reaped: 0 };
  const root = await createProjectSyncValidationRoot(environment(), {
    dataClient,
    worker: () => ({
      runOnce: async () => {
        runs += 1;
        return outcome;
      },
    }),
  });

  assert.deepEqual(await root({
    Records: [{ messageId: "wake-1", body: "roomscan-project-validation-wake-v1" }],
  }), { batchItemFailures: [] });
  assert.equal(runs, 1);

  // EventBridge requires target input to be valid JSON, so its direct SQS
  // target delivers the JSON-encoded scalar emitted by RuleTargetInput.fromText.
  // It is still the one fixed, targetless wake—not a structured work selector.
  assert.deepEqual(await root({
    Records: [{ messageId: "wake-eventbridge-1", body: "\"roomscan-project-validation-wake-v1\"" }],
  }), { batchItemFailures: [] });
  assert.equal(runs, 2);

  outcome = { status: "retry", reaped: 0 };
  assert.deepEqual(await root({
    Records: [{ messageId: "wake-2", body: "roomscan-project-validation-wake-v1" }],
  }), { batchItemFailures: [{ itemIdentifier: "wake-2" }] });
  assert.equal(runs, 3);

  assert.deepEqual(await root({
    Records: [{ messageId: "wake-3", body: "{\"projectID\":\"prj_attacker_selected\"}" }],
  }), { batchItemFailures: [{ itemIdentifier: "wake-3" }] });
  assert.equal(runs, 3);
});
