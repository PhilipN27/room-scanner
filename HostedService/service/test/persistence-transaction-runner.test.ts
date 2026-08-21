import assert from "node:assert/strict";
import test from "node:test";

import { DataApiCapabilityRepository } from "../src/persistence/capabilities.js";
import {
  CapabilityTransactionError,
  DataApiCapabilityTransactionRunner,
} from "../src/persistence/transaction-runner.js";
import type { DataApiClient } from "../src/adapters/data-api.js";

const digest = (byte: number) => Buffer.alloc(32, byte).toString("base64url");

test("public capability runner owns one transaction, joins nested repository work, and exposes no SQL callback", async () => {
  const events: string[] = [];
  const client: DataApiClient = {
    begin: async () => {
      events.push("begin");
      return { transactionId: "public-capability-1" };
    },
    execute: async (input) => {
      events.push(input.sql.includes("rotate_session_from_refresh") ? "rotate" : "other");
      return { rows: [{
        status: "rotated",
        principal_id: "11111111-1111-4111-8111-111111111111",
        principal_canonical_id: "prn_runner",
        family_id: "22222222-2222-4222-8222-222222222222",
        family_public_id: "fam_runner_000001",
        authentication_epoch: 0,
        workspace_id: null,
        role: null,
        authorization_version: null,
        access_expires_at: "2030-01-01T00:05:00.000Z",
      }] };
    },
    commit: async () => { events.push("commit"); },
    rollback: async () => { events.push("rollback"); },
  };
  const runner = new DataApiCapabilityTransactionRunner(client, (unit) => new DataApiCapabilityRepository(unit));
  const output = await runner.run((repository) => repository.transaction((outer) => outer.transaction((inner) => {
    assert.equal("execute" in (inner as unknown as Record<string, unknown>), false);
    return inner.rotateSessionFromRefresh({
      currentRefreshDigest: digest(1),
      nextRefreshDigest: digest(2),
      nextAccessDigest: digest(3),
      rotatedAtMs: Date.UTC(2030, 0, 1),
      nextAccessExpiresAtMs: Date.UTC(2030, 0, 1, 0, 5),
      nextInactivityExpiresAtMs: Date.UTC(2030, 0, 8),
    });
  })));
  assert.equal(output.status, "rotated");
  assert.deepEqual(events, ["begin", "rotate", "commit"]);
});

test("public capability runner rejects sequential provider transaction-id reuse before executing another capability", async () => {
  let beginCount = 0;
  let executions = 0;
  const client: DataApiClient = {
    begin: async () => ({ transactionId: beginCount++ === 0 ? "reused-runner-id" : "reused-runner-id" }),
    execute: async () => { executions += 1; return { rows: [] }; },
    commit: async () => undefined,
    rollback: async () => undefined,
  };
  const runner = new DataApiCapabilityTransactionRunner(client, (unit) => new DataApiCapabilityRepository(unit));
  await runner.run(async () => undefined);
  await assert.rejects(runner.run(async () => undefined), (error: unknown) =>
    error instanceof CapabilityTransactionError && error.code === "duplicate_transaction");
  assert.equal(executions, 0);
});

test("public capability runner keeps fixed replay memory under a fresh-ID stress run and still rejects the oldest provider ID", async () => {
  let beginCount = 0;
  let replayOldest = false;
  const client: DataApiClient = {
    begin: async () => ({ transactionId: replayOldest ? "bounded-runner-1" : `bounded-runner-${++beginCount}` }),
    execute: async () => ({ rows: [] }),
    commit: async () => undefined,
    rollback: async () => undefined,
  };
  const runner = new DataApiCapabilityTransactionRunner(client, (unit) => new DataApiCapabilityRepository(unit));

  // More than the old hard lifetime cap. A bounded bit ledger permits fresh
  // provider IDs while preserving replay memory; an evicting FIFO would later
  // accept the oldest ID below.
  for (let count = 0; count < 4_097; count += 1) {
    await runner.run(async () => undefined);
  }
  replayOldest = true;
  await assert.rejects(
    runner.run(async () => undefined),
    (error: unknown) => error instanceof CapabilityTransactionError && error.code === "duplicate_transaction",
  );
  assert.equal(beginCount, 4_097);
});

test("public capability runner rejects concurrently reused provider IDs without rolling back the owner", async () => {
  let beginCount = 0;
  let releaseBegins: (() => void) | undefined;
  const begun = new Promise<void>((resolve) => { releaseBegins = resolve; });
  let releaseOwner: (() => void) | undefined;
  const ownerHeld = new Promise<void>((resolve) => { releaseOwner = resolve; });
  let ownerEntered: (() => void) | undefined;
  const ownerActive = new Promise<void>((resolve) => { ownerEntered = resolve; });
  let rollbacks = 0;
  const client: DataApiClient = {
    begin: async () => {
      beginCount += 1;
      await begun;
      return { transactionId: "concurrent-reused-runner" };
    },
    execute: async () => ({ rows: [] }),
    commit: async () => undefined,
    rollback: async () => { rollbacks += 1; },
  };
  const runner = new DataApiCapabilityTransactionRunner(client, (unit) => new DataApiCapabilityRepository(unit));
  const first = runner.run(async () => {
    ownerEntered?.();
    await ownerHeld;
  });
  const second = runner.run(async () => undefined);
  await Promise.resolve();
  releaseBegins?.();
  await ownerActive;
  await assert.rejects(
    second,
    (error: unknown) => error instanceof CapabilityTransactionError && error.code === "duplicate_transaction",
  );
  assert.equal(beginCount, 2);
  assert.equal(rollbacks, 0);
  releaseOwner?.();
  await first;
});
