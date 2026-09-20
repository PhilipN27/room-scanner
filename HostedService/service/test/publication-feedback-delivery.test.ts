import assert from "node:assert/strict";
import test from "node:test";

import type { DataApiClient, SqlStatement } from "../src/adapters/data-api.js";
import { createSlice6FeedbackDeliverySqsHandler } from "../src/composition/production.js";
import { DataApiPublicationFeedbackDeliveryWorker } from "../src/persistence/publication-feedback-delivery.js";
import { AesGcmPublicationFeedbackEnvelopeSealer } from "../src/publication/feedback-service.js";

const NOW = Date.UTC(2030, 0, 1);
const EMAIL = "feedback-canary@example.test";
const CODE = `${Buffer.alloc(32, 0x41).toString("base64url")}.${Buffer.alloc(32, 0x42).toString("base64url")}`;
const KEY = Buffer.alloc(32, 0x43);

test("email runtime decrypts only a live v3 feedback envelope with fixed AAD, sends in bounded memory, then completes", async () => {
  const envelope = new AesGcmPublicationFeedbackEnvelopeSealer({
    keyID: "feedback-v1",
    key: KEY,
    random: { bytes: (length) => Buffer.alloc(length, 0x44) },
  }).seal({ email: EMAIL, verificationCode: CODE });
  assert.equal(Buffer.from(envelope.ciphertext).includes(Buffer.from(EMAIL, "utf8")), false, "the real ciphertext has no plaintext email canary");
  assert.equal(Buffer.from(envelope.ciphertext).includes(Buffer.from(CODE, "utf8")), false, "the real ciphertext has no plaintext verification-code canary");

  const client = feedbackDeliveryClient(envelope);
  const sent: Array<Readonly<{ readonly email: string; readonly verificationCode: string; readonly deliveryID: string }>> = [];
  const worker = new DataApiPublicationFeedbackDeliveryWorker({
    client,
    clock: { nowMs: () => NOW },
    random: { bytes: () => Buffer.alloc(16, 0x45) },
    decryptionKeys: { resolve: async (keyID) => keyID === "feedback-v1" ? KEY : undefined },
    delivery: { send: async (input) => { sent.push(input); } },
    leaseMs: 60_000,
  });

  assert.equal(await worker.handleRecord({ messageId: "feedback-tick-1" }), true);
  assert.deepEqual(sent, [{ email: EMAIL, verificationCode: CODE, deliveryID: "pfd_abcdefghijklmnop" }]);
  assert.equal(client.calls.filter((call) => call.includes("validate_feedback_delivery_v3")).length, 2, "the live DB reducer runs after key lookup and immediately before provider send");
  assert.equal(client.calls.some((call) => call.includes("complete_feedback_delivery_v3")), true);
  assert.equal(client.calls.findIndex((call) => call.includes("claim_next_feedback_delivery_v3")) < client.calls.findIndex((call) => call.includes("validate_feedback_delivery_v3")), true);
  assert.equal(JSON.stringify({ calls: client.calls, statements: client.statements }).includes(EMAIL), false, "the email worker never records plaintext email in its SQL-visible state");
  assert.equal(JSON.stringify({ calls: client.calls, statements: client.statements }).includes(CODE), false, "the verification code never enters SQL or worker-visible metadata");
});

test("email runtime cancels a tampered v3 envelope before provider send", async () => {
  const sealed = new AesGcmPublicationFeedbackEnvelopeSealer({
    keyID: "feedback-v1",
    key: KEY,
    random: { bytes: (length) => Buffer.alloc(length, 0x46) },
  }).seal({ email: EMAIL, verificationCode: CODE });
  const ciphertext = Uint8Array.from(sealed.ciphertext);
  ciphertext[0] = (ciphertext[0] ?? 0) ^ 0xff;
  const client = feedbackDeliveryClient({ ...sealed, ciphertext });
  let sends = 0;
  const worker = new DataApiPublicationFeedbackDeliveryWorker({
    client,
    clock: { nowMs: () => NOW },
    random: { bytes: () => Buffer.alloc(16, 0x47) },
    decryptionKeys: { resolve: async () => KEY },
    delivery: { send: async () => { sends += 1; } },
    leaseMs: 60_000,
  });

  assert.equal(await worker.handleRecord({ messageId: "feedback-tick-tampered" }), true);
  assert.equal(sends, 0, "tamper reaches the real AES-GCM authentication guard before SES authority is called");
  assert.equal(client.calls.some((call) => call.includes("cancel_feedback_delivery_v3")), true, "the bounded terminal cancellation reaches the v3 lifecycle reducer");
  assert.equal(client.calls.some((call) => call.includes("complete_feedback_delivery_v3")), false);
});

test("email runtime repeats the live v3 check immediately before provider send", async () => {
  const envelope = new AesGcmPublicationFeedbackEnvelopeSealer({
    keyID: "feedback-v1",
    key: KEY,
    random: { bytes: (length) => Buffer.alloc(length, 0x4a) },
  }).seal({ email: EMAIL, verificationCode: CODE });
  const client = feedbackDeliveryClient(envelope, "aes-256-gcm-v1", "cancelled");
  let sends = 0;
  const worker = new DataApiPublicationFeedbackDeliveryWorker({
    client,
    clock: { nowMs: () => NOW },
    random: { bytes: () => Buffer.alloc(16, 0x4b) },
    decryptionKeys: { resolve: async () => KEY },
    delivery: { send: async () => { sends += 1; } },
    leaseMs: 60_000,
  });

  assert.equal(await worker.handleRecord({ messageId: "feedback-revoked-before-send" }), true);
  assert.equal(client.calls.filter((call) => call.includes("validate_feedback_delivery_v3")).length, 2, "the oracle reaches both the post-claim and immediately-before-send live DB checks");
  assert.equal(sends, 0, "a revoke/kill/expiry transition between decryption and provider send cannot emit an email");
  assert.equal(client.calls.some((call) => call.includes("complete_feedback_delivery_v3")), false);
});

test("email runtime rejects an unrecognized feedback envelope version before key lookup or provider send", async () => {
  const envelope = new AesGcmPublicationFeedbackEnvelopeSealer({
    keyID: "feedback-v1",
    key: KEY,
    random: { bytes: (length) => Buffer.alloc(length, 0x48) },
  }).seal({ email: EMAIL, verificationCode: CODE });
  const client = feedbackDeliveryClient(envelope, "aes-256-gcm-v0");
  let keyLookups = 0;
  let sends = 0;
  const worker = new DataApiPublicationFeedbackDeliveryWorker({
    client,
    clock: { nowMs: () => NOW },
    random: { bytes: () => Buffer.alloc(16, 0x49) },
    decryptionKeys: { resolve: async () => { keyLookups += 1; return KEY; } },
    delivery: { send: async () => { sends += 1; } },
    leaseMs: 60_000,
  });

  assert.equal(await worker.handleRecord({ messageId: "feedback-unknown-envelope-version" }), false);
  assert.equal(keyLookups, 0, "an unknown version never reaches a potentially shared decryption key");
  assert.equal(sends, 0, "an unknown version never reaches SES authority");
  assert.equal(client.calls.some((call) => call.includes("validate_feedback_delivery_v3")), false);
});

test("feedback email lane accepts only targetless wake records and maps an unavailable worker record to a retry", async () => {
  const seen: Array<Readonly<{ readonly messageId: string }>> = [];
  const handler = createSlice6FeedbackDeliverySqsHandler({
    worker: {
      handleRecord: async (record) => {
        seen.push(record);
        return record.messageId !== "retry";
      },
    },
  });

  const result = await handler({
    Records: [
      { messageId: "feedback-wake-1", body: JSON.stringify({ email: EMAIL, code: CODE, deliveryID: "attacker-selected" }) },
      { messageId: "retry" },
      { messageId: "\u0000invalid" },
    ],
  });

  assert.deepEqual(seen, [{ messageId: "feedback-wake-1" }, { messageId: "retry" }], "the bounded handler discards queue body bytes; delivery selection stays inside the worker claim");
  assert.deepEqual(result, { batchItemFailures: [{ itemIdentifier: "retry" }] });
  assert.equal(JSON.stringify(result).includes(EMAIL), false, "the SQS response never reflects a queued plaintext canary");
});

function feedbackDeliveryClient(
  envelope: Readonly<{ readonly keyID: string; readonly iv: Uint8Array; readonly ciphertext: Uint8Array; readonly authenticationTag: Uint8Array }>,
  envelopeVersion = "aes-256-gcm-v1",
  secondValidationStatus?: "cancelled",
): DataApiClient & { readonly calls: string[]; readonly statements: SqlStatement[] } {
  let serial = 0;
  let validationCalls = 0;
  const calls: string[] = [];
  const statements: SqlStatement[] = [];
  const row = (leaseID: string) => Object.freeze({
    status: "leased",
    delivery_id: "pfd_abcdefghijklmnop",
    lease_id: leaseID,
    lease_expires_at: "2030-01-01T00:01:00.000Z",
    envelope_version: envelopeVersion,
    key_id: envelope.keyID,
    iv: Uint8Array.from(envelope.iv),
    ciphertext: Uint8Array.from(envelope.ciphertext),
    authentication_tag: Uint8Array.from(envelope.authenticationTag),
    expires_at: "2030-01-01T00:15:00.000Z",
    delivery_attempts: 1,
  });
  return {
    calls,
    statements,
    begin: async () => ({ transactionId: `feedback-delivery-${++serial}` }),
    commit: async () => { calls.push("commit"); },
    rollback: async () => { calls.push("rollback"); },
    execute: async (statement) => {
      calls.push(statement.sql);
      statements.push(statement);
      if (statement.sql.includes("claim_next_feedback_delivery_v3")) return { rows: [row(stringParameter(statement.parameters, "lease_id"))] };
      if (statement.sql.includes("validate_feedback_delivery_v3")) {
        validationCalls += 1;
        const leaseID = stringParameter(statement.parameters, "lease_id");
        if (validationCalls === 2 && secondValidationStatus !== undefined) return { rows: [{ ...row(leaseID), status: secondValidationStatus }] };
        return { rows: [{ ...row(leaseID), status: "send" }] };
      }
      if (statement.sql.includes("complete_feedback_delivery_v3")) return { rows: [{ completed: true }] };
      if (statement.sql.includes("cancel_feedback_delivery_v3")) return { rows: [{ cancelled: true }] };
      if (statement.sql.includes("release_feedback_delivery_v3")) return { rows: [{ status: "released" }] };
      throw new Error(`unexpected SQL: ${statement.sql}`);
    },
  };
}

function stringParameter(parameters: SqlStatement["parameters"], name: string): string {
  const value = parameters?.find((parameter) => parameter.name === name)?.value;
  if (value?.kind !== "string") throw new Error(`missing ${name}`);
  return value.value;
}
