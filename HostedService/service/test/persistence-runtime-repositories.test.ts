import assert from "node:assert/strict";
import { createCipheriv } from "node:crypto";
import test from "node:test";

import {
  DataApiAppleChallengeSessionPort,
  DataApiMagicDeliveryWorker,
  DataApiProviderAuditExportWorker,
  DataApiStripeIngressBillingRepository,
  DataApiStripeReconciliationBillingRepository,
} from "../src/persistence/runtime-repositories.js";
import type { DataApiClient, SqlStatement } from "../src/adapters/data-api.js";

function clientFor(rows: (sql: string) => readonly Readonly<Record<string, string | number | boolean | Uint8Array | null>>[]): DataApiClient & { readonly calls: string[]; readonly statements: SqlStatement[] } {
  let serial = 0;
  const calls: string[] = [];
  const statements: SqlStatement[] = [];
  return {
    calls, statements,
    begin: async () => ({ transactionId: `tx-${++serial}` }),
    execute: async (input) => { calls.push(input.sql); statements.push(input); return { rows: rows(input.sql) }; },
    commit: async () => { calls.push("commit"); },
    rollback: async () => { calls.push("rollback"); },
  };
}

test("Stripe ingress billing wrapper atomically records the exact durable receipt and bounded provider-audit fact before success", async () => {
  const client = clientFor((sql) => {
    if (sql.includes("accept_stripe_event_v2")) return [{ status: "accepted", workspace_id: "11111111-1111-4111-8111-111111111111", generation: 1 }];
    if (sql.includes("accept_provider_audit_event")) return [{ accepted: true }];
    return [];
  });
  const repository = new DataApiStripeIngressBillingRepository(client);
  const result = await repository.transaction((transaction) => transaction.acceptVerifiedWebhook({
    accountMode: "platform", accountId: "acct_serverowned0007", customerId: "cus_serverowned0007", subscriptionId: "sub_serverowned0007",
    eventId: "evt_000007", eventType: "customer.subscription.updated", objectId: "sub_serverowned0007",
    payloadSha256: "a".repeat(64), providerOccurredAtMs: Date.UTC(2030, 0, 1), receivedAtMs: Date.UTC(2030, 0, 1, 0, 1),
  }));
  assert.deepEqual(result, { status: "accepted", workspaceId: "11111111-1111-4111-8111-111111111111", generation: 1 });
  assert.equal(client.calls.filter((call) => call.includes("accept_stripe_event_v2")).length, 1);
  assert.equal(client.calls.filter((call) => call.includes("accept_provider_audit_event")).length, 1);
  const audit = client.statements.find((statement) => statement.sql.includes("accept_provider_audit_event"));
  assert.deepEqual(audit?.parameters?.find((parameter) => parameter.name === "provider_lane")?.value, { kind: "string", value: "stripe" });
  assert.deepEqual(audit?.parameters?.find((parameter) => parameter.name === "event_code")?.value, { kind: "string", value: "stripe.webhook.accepted" });
  assert.equal(audit?.parameters?.some((parameter) => parameter.name === "workspace_id" || parameter.name === "customer_id"), false);
  assert.equal(client.calls.at(-1), "commit");
});

test("Stripe ingress rolls back the receipt when provider-audit metadata conflicts", async () => {
  let commits = 0;
  let rollbacks = 0;
  const client: DataApiClient = {
    begin: async () => ({ transactionId: "stripe-conflict" }),
    execute: async (statement) => {
      if (statement.sql.includes("accept_stripe_event_v2")) {
        return { rows: [{ status: "accepted", workspace_id: "11111111-1111-4111-8111-111111111111", generation: 1 }] };
      }
      if (statement.sql.includes("accept_provider_audit_event")) throw new Error("P0001 PROVIDER_AUDIT_ID_REUSED");
      return { rows: [] };
    },
    commit: async () => { commits += 1; },
    rollback: async () => { rollbacks += 1; },
  };
  const repository = new DataApiStripeIngressBillingRepository(client);
  await assert.rejects(repository.transaction((transaction) => transaction.acceptVerifiedWebhook({
    accountMode: "platform", accountId: "acct_serverowned0007", customerId: "cus_serverowned0007", subscriptionId: "sub_serverowned0007",
    eventId: "evt_000007", eventType: "customer.subscription.updated", objectId: "sub_serverowned0007",
    payloadSha256: "a".repeat(64), providerOccurredAtMs: Date.UTC(2030, 0, 1), receivedAtMs: Date.UTC(2030, 0, 1, 0, 1),
  })));
  assert.equal(commits, 0);
  assert.equal(rollbacks, 1);
});

test("Stripe ingress distinguishes accepted and duplicate audit facts while accepting only exact audit duplicates", async () => {
  let serial = 0;
  let receiptCalls = 0;
  const auditMetadata = new Map<string, string>();
  const auditFacts: Array<{ readonly id: string; readonly code: string; readonly reference: string; readonly occurredAt: string }> = [];
  const client: DataApiClient = {
    begin: async () => ({ transactionId: `stripe-audit-${++serial}` }),
    execute: async (statement) => {
      if (statement.sql.includes("accept_stripe_event_v2")) {
        receiptCalls += 1;
        return { rows: [{
          status: receiptCalls === 1 ? "accepted" : "duplicate",
          workspace_id: "11111111-1111-4111-8111-111111111111",
          generation: 1,
        }] };
      }
      if (statement.sql.includes("accept_provider_audit_event")) {
        const fact = auditFact(statement.parameters);
        const metadata = `${fact.code}\u0000${fact.reference}`;
        const prior = auditMetadata.get(fact.id);
        if (prior !== undefined && prior !== metadata) throw new Error("P0001 PROVIDER_AUDIT_ID_REUSED");
        if (prior === undefined) auditMetadata.set(fact.id, metadata);
        auditFacts.push(fact);
        return { rows: [{ accepted: prior === undefined }] };
      }
      return { rows: [] };
    },
    commit: async () => undefined,
    rollback: async () => undefined,
  };
  const repository = new DataApiStripeIngressBillingRepository(client);
  const accepted = {
    accountMode: "platform" as const,
    accountId: "acct_serverowned0007",
    customerId: "cus_serverowned0007",
    subscriptionId: "sub_serverowned0007",
    eventId: "evt_000007",
    eventType: "customer.subscription.updated",
    objectId: "sub_serverowned0007",
    payloadSha256: "a".repeat(64),
    providerOccurredAtMs: Date.UTC(2030, 0, 1),
    receivedAtMs: Date.UTC(2030, 0, 1, 0, 1),
  };

  assert.equal((await repository.transaction((transaction) => transaction.acceptVerifiedWebhook(accepted))).status, "accepted");
  assert.equal((await repository.transaction((transaction) => transaction.acceptVerifiedWebhook({ ...accepted, receivedAtMs: accepted.receivedAtMs + 1_000 }))).status, "duplicate");
  assert.equal((await repository.transaction((transaction) => transaction.acceptVerifiedWebhook({ ...accepted, receivedAtMs: accepted.receivedAtMs + 2_000 }))).status, "duplicate");

  assert.deepEqual(auditFacts.map((fact) => fact.code), ["stripe.webhook.accepted", "stripe.webhook.duplicate", "stripe.webhook.duplicate"]);
  assert.notEqual(auditFacts[0]?.id, auditFacts[1]?.id, "accepted and duplicate outcomes require distinct durable audit IDs");
  assert.equal(auditFacts[1]?.id, auditFacts[2]?.id, "same duplicate metadata is an exact idempotent audit retry");
  assert.equal(auditFacts[1]?.reference, auditFacts[2]?.reference);
});

test("reconciliation billing wrapper uses only frozen claim flag versions and ignores a caller grant", async () => {
  const client = clientFor((sql) => {
    if (sql.includes("claim_stripe_reconciliation_v2")) return [{
      workspace_id: "11111111-1111-4111-8111-111111111111", account_mode: "platform", provider_account_id: "acct_serverowned0007", billing_customer_id: "cus_serverowned0007", subscription_id: "sub_serverowned0007", generation: 1,
      lease_id: "lease_0007", last_event_type: null, last_object_id: null, hosted_global_version: 17, hosted_workspace_version: 19,
    }];
    if (sql.includes("complete_stripe_reconciliation_v2")) return [{ status: "applied", needs_another_generation: false }];
    return [];
  });
  const repository = new DataApiStripeReconciliationBillingRepository(client);
  const claim = await repository.transaction((transaction) => transaction.claimReconciliation("lease_0007", Date.UTC(2030, 0, 1), Date.UTC(2030, 0, 1, 0, 1)));
  assert.equal(claim?.workspaceId, "11111111-1111-4111-8111-111111111111");
  const result = await repository.transaction((transaction) => transaction.completeReconciliation({
    claim: claim!, snapshot: { observedAtMs: Date.UTC(2030, 0, 1), status: "active", planKey: "test-only" }, appliedAtMs: Date.UTC(2030, 0, 1, 0, 1),
    hostedGrant: { kind: "hosted-mutation-grant-v2", workspaceId: "caller-substituted-workspace", action: "system.stripe.reconcile", hostedGlobalFlagVersion: 3, hostedWorkspaceFlagVersion: 4 },
  }));
  assert.deepEqual(result, { status: "applied", needsAnotherGeneration: false });
  const completion = client.calls.find((call) => call.includes("complete_stripe_reconciliation_v2"));
  assert.ok(completion);
  assert.equal(completion?.includes("caller-substituted-workspace"), false);
  const completionParameters = client.statements.find((statement) => statement.sql.includes("complete_stripe_reconciliation_v2"))?.parameters ?? [];
  assert.deepEqual(
    completionParameters.filter((parameter) => parameter.name === "hosted_global_version" || parameter.name === "hosted_workspace_version"),
    [
      { name: "hosted_global_version", value: { kind: "long", value: 17 } },
      { name: "hosted_workspace_version", value: { kind: "long", value: 19 } },
    ],
  );
});

test("audit export worker commits a lease, calls a bounded delivery port outside SQL, then completes the durable record", async () => {
  const client = clientFor((sql) => {
    if (sql.includes("claim_provider_audit_event")) return [{
      id: "paud_abcdefghijklmnop", provider_lane: "stripe", event_code: "stripe.webhook.accepted", bounded_reference: "evt_0007",
      occurred_at: "2030-01-01T00:00:00.000Z", state: "leased", lease_id: "lease_AQEBAQEBAQEBAQEBAQEBAQ", lease_expires_at: "2030-01-01T00:01:00.000Z", delivered_at: null, delivery_attempts: 1,
    }];
    if (sql.includes("complete_provider_audit_event")) return [{ completed: true }];
    return [];
  });
  const order: string[] = [];
  const worker = new DataApiProviderAuditExportWorker({
    client,
    clock: { nowMs: () => Date.UTC(2030, 0, 1) },
    random: { bytes: () => Buffer.alloc(16, 1) },
    leaseMs: 60_000,
    delivery: { deliver: async (event) => { order.push(`deliver:${event.id}`); } },
  });
  assert.equal(await worker.handleRecord({ messageId: "audit-record-1" }), true);
  assert.deepEqual(order, ["deliver:paud_abcdefghijklmnop"]);
  assert.equal(client.calls.filter((call) => call === "commit").length, 2);
  assert.ok(client.calls.findIndex((call) => call.includes("claim_provider_audit_event")) < client.calls.findIndex((call) => call.includes("complete_provider_audit_event")));
});

test("Apple challenge session port is the only concrete factory that maps a raw bridge proof to the challenge-runtime capability", async () => {
  const client = clientFor((sql) => sql.includes("consume_apple_bridge_and_issue_session") ? [{
    status: "issued", principal_id: "11111111-1111-4111-8111-111111111111", principal_canonical_id: "prn_abcdefghijklmnopqrstuv",
    family_id: "22222222-2222-4222-8222-222222222222", family_public_id: "fam_abcdefghijklmnop", authentication_epoch: 0,
    authenticated_at: "2030-01-01T00:00:00.000Z",
  }] : []);
  const port = new DataApiAppleChallengeSessionPort({ client, bridgeProofHmacKey: Buffer.alloc(32, 7) });
  const result = await port.consumeAppleBridgeAndIssueSession({
    bridgeProof: Buffer.alloc(32, 1).toString("base64url"), familyPublicId: "fam_abcdefghijklmnop",
    accessTokenHash: Buffer.alloc(32, 2), refreshTokenHash: Buffer.alloc(32, 3),
    authenticatedAt: new Date("2030-01-01T00:00:00.000Z"), issuedAt: new Date("2030-01-01T00:00:00.000Z"),
    accessExpiresAt: new Date("2030-01-01T00:05:00.000Z"), inactivityExpiresAt: new Date("2030-01-08T00:00:00.000Z"), absoluteExpiresAt: new Date("2030-01-31T00:00:00.000Z"), policyVersion: "session-v1",
  });
  assert.equal(result.status, "issued");
  assert.equal(client.calls.filter((call) => call.includes("consume_apple_bridge_and_issue_session")).length, 1);
  assert.equal(client.calls.at(-1), "commit");
});

test("magic delivery claims durably, revalidates after key lookup, sends only fragment-scoped secret, then completes", async () => {
  const key = Buffer.alloc(32, 4);
  const secret = Buffer.alloc(32, 5);
  const iv = Buffer.alloc(12, 6);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  const ciphertext = Buffer.concat([cipher.update(secret), cipher.final()]);
  const authenticationTag = cipher.getAuthTag();
  const leaseId = `lease_${Buffer.alloc(16, 7).toString("base64url")}`;
  const row = {
    id: "mdl_abcdefghijklmnopqrstuv",
    selector: Buffer.alloc(16, 8).toString("base64url"),
    normalized_delivery_identity: "relay@privaterelay.appleid.com",
    purpose: "sign-in",
    envelope_version: "aes-256-gcm-v1",
    key_id: "magic-v1",
    iv,
    ciphertext,
    authentication_tag: authenticationTag,
    created_at: "2030-01-01T00:00:00.000Z",
    expires_at: "2030-01-01T00:05:00.000Z",
    policy_version: "magic-v1",
    state: "leased",
    delivery_attempts: 1,
    lease_id: leaseId,
    lease_expires_at: "2030-01-01T00:01:00.000Z",
    delivered_at: null,
    cancelled_at: null,
    cancellation_reason: null,
  };
  const calls: string[] = [];
  const auditParameters: SqlStatement["parameters"][] = [];
  let serial = 0;
  const client: DataApiClient = {
    begin: async () => ({ transactionId: `delivery-${++serial}` }),
    execute: async (input) => {
      calls.push(input.sql);
      if (input.sql.includes("claim_next_magic_delivery")) return { rows: [row] };
      if (input.sql.includes("validate_magic_delivery")) return { rows: [row] };
      if (input.sql.includes("accept_provider_audit_event")) { auditParameters.push(input.parameters); return { rows: [{ accepted: true }] }; }
      if (input.sql.includes("complete_magic_delivery")) return { rows: [{ completed: true }] };
      return { rows: [] };
    },
    commit: async () => { calls.push("commit"); },
    rollback: async () => { calls.push("rollback"); },
  };
  const sent: Array<Readonly<{
    readonly destination: string;
    readonly magicLinkUrl: string;
    readonly outboxId: string;
    readonly purpose: "sign-in" | "reauthenticate" | "link-identity" | "unlink-identity";
  }>> = [];
  const worker = new DataApiMagicDeliveryWorker({
    client,
    clock: { nowMs: () => Date.UTC(2030, 0, 1) },
    random: { bytes: () => Buffer.alloc(16, 7) },
    decryptionKeys: { resolve: async (keyId) => keyId === "magic-v1" ? key : undefined },
    delivery: { send: async (input) => { sent.push(input); } },
    publicBaseUrl: "https://app.roomscan.example",
    leaseMs: 60_000,
  });

  assert.equal(await worker.handleRecord({ messageId: "magic-tick-1" }), true);
  assert.equal(sent.length, 1);
  assert.equal(calls.filter((call) => call === "commit").length, 5);
  assert.ok(calls.findIndex((call) => call === "commit") < calls.findIndex((call) => call.includes("validate_magic_delivery")));
  const delivery = sent[0]!;
  assert.equal(delivery.destination, "relay@privaterelay.appleid.com");
  assert.equal(delivery.outboxId, "mdl_abcdefghijklmnopqrstuv");
  assert.match(delivery.magicLinkUrl, /^https:\/\/app\.roomscan\.example\/auth\/magic-link\/[A-Za-z0-9_-]{22}#secret=[A-Za-z0-9_-]{43}&purpose=sign-in$/u);
  assert.equal(delivery.magicLinkUrl.includes(secret.toString("base64url")), true);
  assert.equal(calls.join("\n").includes(secret.toString("base64url")), false);
  assert.deepEqual(auditParameters, [[
    { name: "id", value: { kind: "string", value: "paud_MPEi5lYKvryzC8C3-bAj7RSaMEnVnF78OHJft6N5Awg" } },
    { name: "provider_lane", value: { kind: "string", value: "email" } },
    { name: "event_code", value: { kind: "string", value: "email.delivery.accepted" } },
    { name: "bounded_reference", value: { kind: "string", value: "mdl_abcdefghijklmnopqrstuv" } },
    { name: "occurred_at", value: { kind: "string", value: "2030-01-01T00:00:00.000Z" } },
  ]]);
});

test("magic delivery records a bounded durable failed audit before releasing a provider-send failure", async () => {
  const key = Buffer.alloc(32, 4); const secret = Buffer.alloc(32, 5); const iv = Buffer.alloc(12, 6);
  const cipher = createCipheriv("aes-256-gcm", key, iv); const ciphertext = Buffer.concat([cipher.update(secret), cipher.final()]); const authenticationTag = cipher.getAuthTag();
  const row = {
    id: "mdl_abcdefghijklmnopqrstuv", selector: Buffer.alloc(16, 8).toString("base64url"), normalized_delivery_identity: "relay@privaterelay.appleid.com", purpose: "sign-in",
    envelope_version: "aes-256-gcm-v1", key_id: "magic-v1", iv, ciphertext, authentication_tag: authenticationTag,
    created_at: "2030-01-01T00:00:00.000Z", expires_at: "2030-01-01T00:05:00.000Z", policy_version: "magic-v1", state: "leased", delivery_attempts: 1,
    lease_id: `lease_${Buffer.alloc(16, 7).toString("base64url")}`, lease_expires_at: "2030-01-01T00:01:00.000Z", delivered_at: null, cancelled_at: null, cancellation_reason: null,
  };
  const calls: string[] = []; const auditCodes: string[] = []; let serial = 0;
  const client: DataApiClient = {
    begin: async () => ({ transactionId: `delivery-failed-${++serial}` }),
    execute: async (input) => {
      calls.push(input.sql);
      if (input.sql.includes("claim_next_magic_delivery") || input.sql.includes("validate_magic_delivery")) return { rows: [row] };
      if (input.sql.includes("accept_provider_audit_event")) { auditCodes.push(stringParameter(input.parameters, "event_code")); return { rows: [{ accepted: true }] }; }
      if (input.sql.includes("release_magic_delivery")) return { rows: [{ status: "released" }] };
      throw new Error("unexpected SQL");
    },
    commit: async () => { calls.push("commit"); }, rollback: async () => { calls.push("rollback"); },
  };
  const worker = new DataApiMagicDeliveryWorker({
    client, clock: { nowMs: () => Date.UTC(2030, 0, 1) }, random: { bytes: () => Buffer.alloc(16, 7) },
    decryptionKeys: { resolve: async () => key }, delivery: { send: async () => { throw new Error("SES unavailable"); } }, publicBaseUrl: "https://app.roomscan.example", leaseMs: 60_000,
  });
  assert.equal(await worker.handleRecord({ messageId: "magic-tick-failed" }), false);
  assert.deepEqual(auditCodes, ["email.delivery.failed"]);
  assert.ok(calls.findIndex((call) => call.includes("accept_provider_audit_event")) < calls.findIndex((call) => call.includes("release_magic_delivery")));
  assert.equal(calls.some((call) => call.includes("complete_magic_delivery")), false);
});

test("magic delivery distinguishes failed and later accepted attempts while exact audit retries stay idempotent", async () => {
  const key = Buffer.alloc(32, 4);
  const secret = Buffer.alloc(32, 5);
  const iv = Buffer.alloc(12, 6);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  const ciphertext = Buffer.concat([cipher.update(secret), cipher.final()]);
  const authenticationTag = cipher.getAuthTag();
  const leaseId = `lease_${Buffer.alloc(16, 7).toString("base64url")}`;
  const rowForAttempt = (deliveryAttempts: number) => ({
    id: "mdl_abcdefghijklmnopqrstuv",
    selector: Buffer.alloc(16, 8).toString("base64url"),
    normalized_delivery_identity: "relay@privaterelay.appleid.com",
    purpose: "sign-in",
    envelope_version: "aes-256-gcm-v1",
    key_id: "magic-v1",
    iv,
    ciphertext,
    authentication_tag: authenticationTag,
    created_at: "2030-01-01T00:00:00.000Z",
    expires_at: "2030-01-01T00:05:00.000Z",
    policy_version: "magic-v1",
    state: "leased",
    delivery_attempts: deliveryAttempts,
    lease_id: leaseId,
    lease_expires_at: "2030-01-01T00:01:00.000Z",
    delivered_at: null,
    cancelled_at: null,
    cancellation_reason: null,
  });
  let serial = 0;
  let attempt = 1;
  let sends = 0;
  const auditMetadata = new Map<string, string>();
  const auditFacts: Array<{ readonly id: string; readonly code: string; readonly reference: string; readonly occurredAt: string }> = [];
  const auditAccepted: boolean[] = [];
  const client: DataApiClient = {
    begin: async () => ({ transactionId: `email-audit-${++serial}` }),
    execute: async (statement) => {
      if (statement.sql.includes("claim_next_magic_delivery") || statement.sql.includes("validate_magic_delivery")) {
        return { rows: [rowForAttempt(attempt)] };
      }
      if (statement.sql.includes("accept_provider_audit_event")) {
        const fact = auditFact(statement.parameters);
        const metadata = `${fact.code}\u0000${fact.reference}`;
        const prior = auditMetadata.get(fact.id);
        if (prior !== undefined && prior !== metadata) throw new Error("P0001 PROVIDER_AUDIT_ID_REUSED");
        if (prior === undefined) auditMetadata.set(fact.id, metadata);
        const accepted = prior === undefined;
        auditAccepted.push(accepted);
        auditFacts.push(fact);
        return { rows: [{ accepted }] };
      }
      if (statement.sql.includes("release_magic_delivery")) return { rows: [{ status: "released" }] };
      if (statement.sql.includes("complete_magic_delivery")) return { rows: [{ completed: true }] };
      throw new Error("unexpected SQL");
    },
    commit: async () => undefined,
    rollback: async () => undefined,
  };
  const worker = new DataApiMagicDeliveryWorker({
    client,
    clock: { nowMs: () => Date.UTC(2030, 0, 1) },
    random: { bytes: () => Buffer.alloc(16, 7) },
    decryptionKeys: { resolve: async () => key },
    delivery: { send: async () => { if (sends++ === 0) throw new Error("SES unavailable"); } },
    publicBaseUrl: "https://app.roomscan.example",
    leaseMs: 60_000,
  });

  assert.equal(await worker.handleRecord({ messageId: "magic-retry-1" }), false);
  attempt = 2;
  assert.equal(await worker.handleRecord({ messageId: "magic-retry-2" }), true);
  assert.equal(await worker.handleRecord({ messageId: "magic-retry-3" }), true);

  assert.deepEqual(auditFacts.map((fact) => fact.code), ["email.delivery.failed", "email.delivery.accepted", "email.delivery.accepted"]);
  assert.notEqual(auditFacts[0]?.id, auditFacts[1]?.id, "failure and success require distinct audit IDs");
  assert.equal(auditFacts[1]?.id, auditFacts[2]?.id, "same attempt/outcome is an exact audit duplicate");
  assert.deepEqual(auditAccepted, [true, true, false]);
});

function stringParameter(parameters: SqlStatement["parameters"], name: string): string {
  const value = parameters?.find((parameter) => parameter.name === name)?.value;
  if (value?.kind !== "string") throw new Error(`missing ${name}`);
  return value.value;
}

function auditFact(parameters: SqlStatement["parameters"]): { readonly id: string; readonly code: string; readonly reference: string; readonly occurredAt: string } {
  return Object.freeze({
    id: stringParameter(parameters, "id"),
    code: stringParameter(parameters, "event_code"),
    reference: stringParameter(parameters, "bounded_reference"),
    occurredAt: stringParameter(parameters, "occurred_at"),
  });
}
