import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import test from "node:test";

import {
  BillingError,
  BillingReconciliationService,
  StripeWebhookHandler,
  StripeWebhookSignatureVerifier,
  type BillingRepository,
  type BillingTransaction,
  type ReconciliationClaim,
  type StripeEventReceipt,
  type StripeSubscriptionScope,
  type SubscriptionSnapshot,
  type SubscriptionState,
  type VerifiedWebhookAcceptance,
} from "../src/billing/stripe-billing.js";
import type { HttpApiV2Envelope } from "../src/http/http-api-v2.js";
import { WORKSPACE_ROLES } from "../src/authorization/policy.js";
import type { HostedMutationGrant } from "../src/operations/operational-flags.js";

const signingSecret = "whsec_test_fixture_not_production";
const nowMs = 1_900_000_000_000;
const stripeAccountId = "acct_roomscan0007";
const stripeCustomerId = "cus_roomscan0007";
const stripeSubscriptionId = "sub_roomscan0007";

interface OutboxState {
  readonly workspaceId: string;
  readonly accountMode: "platform" | "connected";
  readonly accountId: string;
  readonly customerId: string;
  readonly subscriptionId: string;
  desiredGeneration: number;
  appliedGeneration: number;
  lastEventType: string;
  lastObjectId: string;
  state: "pending" | "leased";
  leaseId?: string;
  leaseExpiresAtMs?: number;
}

interface BillingStateSnapshot {
  readonly receipts: StripeEventReceipt[];
  readonly outboxes: OutboxState[];
  readonly subscriptions: SubscriptionState[];
  readonly projects: Array<{ id: string; bytes: Uint8Array }>;
}

interface BillingGateState {
  enabled: boolean;
  globalVersion: number;
  workspaceVersion: number;
}

class MemoryBillingRepository implements BillingRepository, BillingTransaction {
  readonly accountWorkspaces = new Map([[
    stripeScopeKey({ accountMode: "platform", accountId: stripeAccountId, customerId: stripeCustomerId, subscriptionId: stripeSubscriptionId }),
    "workspace-a",
  ]]);
  readonly receipts = new Map<string, StripeEventReceipt>();
  readonly outboxes = new Map<string, OutboxState>();
  readonly subscriptions = new Map<string, SubscriptionState>();
  readonly projects = [{ id: "project-1", bytes: Uint8Array.from([9, 8, 7]) }];
  inTransaction = false;
  failAfterReceipt = false;
  acceptGate: Promise<void> | undefined;
  beforeComplete: (() => void) | undefined;
  readonly gate: BillingGateState = { enabled: true, globalVersion: 1, workspaceVersion: 1 };
  private tail: Promise<void> = Promise.resolve();

  async transaction<T>(work: (transaction: BillingTransaction) => Promise<T>): Promise<T> {
    let release!: () => void;
    const previous = this.tail;
    this.tail = new Promise<void>((resolve) => { release = resolve; });
    await previous;
    const snapshot = this.capture();
    this.inTransaction = true;
    try {
      return await work(this);
    } catch (error) {
      this.restore(snapshot);
      throw error;
    } finally {
      this.inTransaction = false;
      release();
    }
  }

  async acceptVerifiedWebhook(input: VerifiedWebhookAcceptance): Promise<{
    readonly status: "accepted" | "duplicate";
    readonly workspaceId: string;
    readonly generation: number;
  }> {
    if (this.acceptGate !== undefined) await this.acceptGate;
    const workspaceId = this.accountWorkspaces.get(stripeScopeKey(input));
    if (workspaceId === undefined) throw new BillingError("account_unmapped");
    const receiptKey = stripeReceiptKey(input);
    const mappedOutbox = this.outboxes.get(workspaceId);
    if (mappedOutbox !== undefined && !sameStripeScope(mappedOutbox, input)) {
      throw new BillingError("account_mapping_conflict");
    }
    const existing = this.receipts.get(receiptKey);
    if (existing !== undefined) {
      if (
        existing.workspaceId !== workspaceId ||
        existing.accountMode !== input.accountMode ||
        existing.accountId !== input.accountId ||
        existing.customerId !== input.customerId ||
        existing.subscriptionId !== input.subscriptionId ||
        existing.payloadSha256 !== input.payloadSha256 ||
        existing.providerOccurredAtMs !== input.providerOccurredAtMs ||
        existing.eventType !== input.eventType ||
        existing.objectId !== input.objectId
      ) throw new BillingError("receipt_conflict");
      const outbox = this.outboxes.get(workspaceId);
      return { status: "duplicate", workspaceId, generation: outbox?.desiredGeneration ?? 0 };
    }
    const receipt: StripeEventReceipt = {
      workspaceId,
      accountMode: input.accountMode,
      accountId: input.accountId,
      customerId: input.customerId,
      subscriptionId: input.subscriptionId,
      eventId: input.eventId,
      eventType: input.eventType,
      objectId: input.objectId,
      payloadSha256: input.payloadSha256,
      providerOccurredAtMs: input.providerOccurredAtMs,
      receivedAtMs: input.receivedAtMs,
    };
    this.receipts.set(receiptKey, receipt);
    const existingOutbox = this.outboxes.get(workspaceId);
    const desiredGeneration = (existingOutbox?.desiredGeneration ?? 0) + 1;
    this.outboxes.set(workspaceId, {
      workspaceId,
      accountMode: input.accountMode,
      accountId: input.accountId,
      customerId: input.customerId,
      subscriptionId: input.subscriptionId,
      desiredGeneration,
      appliedGeneration: existingOutbox?.appliedGeneration ?? 0,
      lastEventType: input.eventType,
      lastObjectId: input.objectId,
      state: existingOutbox?.state ?? "pending",
      ...(existingOutbox?.leaseId === undefined ? {} : { leaseId: existingOutbox.leaseId }),
      ...(existingOutbox?.leaseExpiresAtMs === undefined ? {} : { leaseExpiresAtMs: existingOutbox.leaseExpiresAtMs }),
    });
    if (this.failAfterReceipt) throw new Error("outbox unavailable");
    return { status: "accepted", workspaceId, generation: desiredGeneration };
  }

  async claimReconciliation(
    leaseId: string,
    now: number,
    leaseExpiresAtMs: number,
  ): Promise<ReconciliationClaim | undefined> {
    const outbox = [...this.outboxes.values()].find((candidate) =>
      candidate.desiredGeneration > candidate.appliedGeneration &&
      (candidate.state === "pending" || (candidate.leaseExpiresAtMs ?? 0) <= now)
    );
    if (outbox === undefined) return undefined;
    outbox.state = "leased";
    outbox.leaseId = leaseId;
    outbox.leaseExpiresAtMs = leaseExpiresAtMs;
    return {
      workspaceId: outbox.workspaceId,
      accountMode: outbox.accountMode,
      accountId: outbox.accountId,
      customerId: outbox.customerId,
      subscriptionId: outbox.subscriptionId,
      generation: outbox.desiredGeneration,
      leaseId,
      lastEventType: outbox.lastEventType,
      lastObjectId: outbox.lastObjectId,
    };
  }

  async completeReconciliation(input: {
    readonly claim: ReconciliationClaim;
    readonly snapshot: SubscriptionSnapshot;
    readonly appliedAtMs: number;
    readonly hostedGrant: HostedMutationGrant;
  }): Promise<
    | { readonly status: "applied"; readonly needsAnotherGeneration: boolean }
    | { readonly status: "stale_claim"; readonly needsAnotherGeneration: boolean }
    | { readonly status: "hosted_gate_rejected"; readonly needsAnotherGeneration: boolean }
  > {
    if (this.beforeComplete !== undefined) {
      const callback = this.beforeComplete;
      this.beforeComplete = undefined;
      callback();
    }
    const outbox = this.outboxes.get(input.claim.workspaceId);
    const needsAnotherGeneration = outbox !== undefined && outbox.desiredGeneration > outbox.appliedGeneration;
    if (
      !this.gate.enabled ||
      input.hostedGrant.kind !== "hosted-mutation-grant-v2" ||
      input.hostedGrant.workspaceId !== input.claim.workspaceId ||
      input.hostedGrant.action !== "system.stripe.reconcile" ||
      input.hostedGrant.hostedGlobalFlagVersion !== this.gate.globalVersion ||
      input.hostedGrant.hostedWorkspaceFlagVersion !== this.gate.workspaceVersion
    ) return { status: "hosted_gate_rejected", needsAnotherGeneration };
    if (
      outbox === undefined ||
      outbox.state !== "leased" ||
      outbox.leaseId !== input.claim.leaseId ||
      (outbox.leaseExpiresAtMs ?? 0) <= input.appliedAtMs ||
      input.claim.generation <= outbox.appliedGeneration
    ) return { status: "stale_claim", needsAnotherGeneration };
    const current = this.subscriptions.get(input.claim.workspaceId);
    if (
      current !== undefined &&
      current.sourceObservedAtMs > input.snapshot.observedAtMs
    ) {
      outbox.state = "pending";
      delete outbox.leaseId;
      delete outbox.leaseExpiresAtMs;
      return { status: "stale_claim", needsAnotherGeneration: true };
    }
    this.subscriptions.set(input.claim.workspaceId, {
      workspaceId: input.claim.workspaceId,
      accountId: input.claim.accountId,
      generation: input.claim.generation,
      status: input.snapshot.status,
      planKey: input.snapshot.planKey,
      sourceObservedAtMs: input.snapshot.observedAtMs,
      appliedAtMs: input.appliedAtMs,
      ...(input.snapshot.currentPeriodEndMs === undefined
        ? {}
        : { currentPeriodEndMs: input.snapshot.currentPeriodEndMs }),
    });
    outbox.appliedGeneration = input.claim.generation;
    const moreGenerations = outbox.desiredGeneration > input.claim.generation;
    outbox.state = "pending";
    delete outbox.leaseId;
    delete outbox.leaseExpiresAtMs;
    return { status: "applied", needsAnotherGeneration: moreGenerations };
  }

  async releaseReconciliation(claim: ReconciliationClaim, releasedAtMs: number): Promise<boolean> {
    const outbox = this.outboxes.get(claim.workspaceId);
    if (
      outbox?.state !== "leased" ||
      outbox.leaseId !== claim.leaseId ||
      (outbox.leaseExpiresAtMs ?? 0) <= releasedAtMs
    ) return false;
    outbox.state = "pending";
    delete outbox.leaseId;
    delete outbox.leaseExpiresAtMs;
    return true;
  }

  async currentSubscription(workspaceId: string): Promise<SubscriptionState | undefined> {
    return clone(this.subscriptions.get(workspaceId));
  }

  private capture(): BillingStateSnapshot {
    return {
      receipts: structuredClone([...this.receipts.values()]),
      outboxes: structuredClone([...this.outboxes.values()]),
      subscriptions: structuredClone([...this.subscriptions.values()]),
      projects: this.projects.map((project) => ({ id: project.id, bytes: new Uint8Array(project.bytes) })),
    };
  }

  private restore(snapshot: BillingStateSnapshot): void {
    this.receipts.clear();
    for (const receipt of snapshot.receipts) this.receipts.set(stripeReceiptKey(receipt), structuredClone(receipt));
    this.outboxes.clear();
    for (const outbox of snapshot.outboxes) this.outboxes.set(outbox.workspaceId, structuredClone(outbox));
    this.subscriptions.clear();
    for (const subscription of snapshot.subscriptions) this.subscriptions.set(subscription.workspaceId, structuredClone(subscription));
    this.projects.splice(0, this.projects.length, ...snapshot.projects.map((project) => ({ id: project.id, bytes: new Uint8Array(project.bytes) })));
  }
}

function clone<T>(value: T | undefined): T | undefined {
  return value === undefined ? undefined : structuredClone(value);
}

function stripeScopeKey(scope: StripeSubscriptionScope): string {
  return `${scope.accountMode}\u0000${scope.accountId}\u0000${scope.customerId}\u0000${scope.subscriptionId}`;
}

function stripeReceiptKey(receipt: Pick<StripeEventReceipt, "accountMode" | "accountId" | "customerId" | "subscriptionId" | "eventId">): string {
  return `${stripeScopeKey(receipt)}\u0000${receipt.eventId}`;
}

function sameStripeScope(left: StripeSubscriptionScope, right: StripeSubscriptionScope): boolean {
  return left.accountMode === right.accountMode && left.accountId === right.accountId
    && left.customerId === right.customerId && left.subscriptionId === right.subscriptionId;
}

function eventBody(input: {
  readonly id: string;
  readonly type: string;
  readonly objectId?: string;
  readonly created?: number;
  readonly account?: string;
  readonly customerId?: string;
  readonly statusCanary?: string;
}): string {
  return JSON.stringify({
    id: fixtureStripeEventId(input.id),
    object: "event",
    ...(input.account === undefined ? {} : { account: input.account }),
    type: input.type,
    created: input.created ?? Math.floor(nowMs / 1_000),
    data: {
      object: {
        id: input.objectId ?? stripeSubscriptionId,
        object: "subscription",
        customer: input.customerId ?? stripeCustomerId,
        status: input.statusCanary ?? "event_delta_must_not_apply",
      },
    },
  });
}

function fixtureStripeEventId(value: string): string {
  const suffix = (value.startsWith("evt_") ? value.slice(4) : value).replace(/[^A-Za-z0-9]/gu, "");
  return `evt_${suffix.padEnd(6, "0").slice(0, 255)}`;
}

function signature(body: Uint8Array | string, timestampSeconds = Math.floor(nowMs / 1_000)): string {
  const digest = createHmac("sha256", signingSecret)
    .update(String(timestampSeconds))
    .update(".")
    .update(body)
    .digest("hex");
  return `t=${timestampSeconds},v1=${digest}`;
}

function envelope(body: string, options: {
  readonly base64?: boolean;
  readonly signature?: string;
} = {}): HttpApiV2Envelope {
  return {
    body: options.base64 === true ? Buffer.from(body, "utf8").toString("base64") : body,
    isBase64Encoded: options.base64 === true,
    headers: options.signature === undefined
      ? {}
      : { "Stripe-Signature": options.signature },
  };
}

function webhookHarness(repository = new MemoryBillingRepository()): {
  readonly repository: MemoryBillingRepository;
  readonly handler: StripeWebhookHandler;
  readonly logs: Array<{ eventCode: string; result: string }>;
} {
  const logs: Array<{ eventCode: string; result: string }> = [];
  const handler = new StripeWebhookHandler({
    clock: { nowMs: () => nowMs },
    signatureVerifier: new StripeWebhookSignatureVerifier({
      signingSecret,
      clock: { nowMs: () => nowMs },
      toleranceMs: 5 * 60_000,
    }),
    repository,
    defaultStripeAccountId: stripeAccountId,
    logger: { write: (eventCode, fields) => { logs.push({ eventCode, result: fields.result }); } },
  });
  return { repository, handler, logs };
}

async function post(
  handler: StripeWebhookHandler,
  body: string,
  options: { readonly base64?: boolean; readonly signature?: string } = {},
) {
  return handler.handle(envelope(body, {
    ...options,
    signature: options.signature ?? signature(Buffer.from(body, "utf8")),
  }));
}

test("HTTP API v2 plain and base64 envelopes verify the exact bytes before JSON parsing", async () => {
  const { handler, repository } = webhookHarness();
  const plain = `{ "id":"evt_plain0007", "object":"event", "type":"customer.subscription.updated", "created":1900000000, "data":{"object":{"id":"${stripeSubscriptionId}","object":"subscription","customer":"${stripeCustomerId}"}} }`;
  assert.equal((await post(handler, plain)).statusCode, 200);
  const encoded = eventBody({ id: "evt_encoded", type: "customer.subscription.updated" });
  assert.equal((await post(handler, encoded, { base64: true })).statusCode, 200);
  assert.equal(repository.receipts.size, 2);

  const changedBytes = `${plain} `;
  const forged = await post(handler, changedBytes, { signature: signature(Buffer.from(plain, "utf8")) });
  assert.deepEqual(forged, {
    statusCode: 400,
    headers: { "cache-control": "no-store", "content-type": "application/json" },
    body: "{\"code\":\"invalid_webhook\"}",
  });
});

test("missing, forged, stale, malformed-base64, and valid-signature malformed bodies fail uniformly without logging body or signature", async () => {
  const { handler, logs } = webhookHarness();
  const canaryBody = eventBody({ id: "evt_secret_canary", type: "customer.subscription.updated" });
  const staleTimestamp = Math.floor((nowMs - 5 * 60_000 - 1) / 1_000);
  const cases: HttpApiV2Envelope[] = [
    envelope(canaryBody),
    envelope(canaryBody, { signature: `t=${Math.floor(nowMs / 1_000)},v1=${"0".repeat(64)}` }),
    envelope(canaryBody, { signature: signature(canaryBody, staleTimestamp) }),
    { body: "%%%not-base64%%%", isBase64Encoded: true, headers: { "stripe-signature": signature(canaryBody) } },
    envelope("{not-json", { signature: signature("{not-json") }),
  ];
  const responses = await Promise.all(cases.map(async (candidate) => handler.handle(candidate)));
  assert.equal(new Set(responses.map((response) => JSON.stringify(response))).size, 1);
  assert.equal(responses[0]?.statusCode, 400);
  const serializedLogs = JSON.stringify(logs);
  assert.equal(serializedLogs.includes("evt_secret_canary"), false);
  assert.equal(serializedLogs.includes("stripe-signature"), false);
  assert.equal(serializedLogs.includes("v1="), false);
});

test("a signed but unsupported Stripe event is acknowledged without a reconciliation mutation", async () => {
  const { handler, repository, logs } = webhookHarness();
  const unrelated = JSON.stringify({
    id: "evt_unrelated0007",
    object: "event",
    account: stripeAccountId,
    type: "invoice.payment_failed",
    created: Math.floor(nowMs / 1_000),
    data: { object: { id: "in_unrelated_0007", object: "invoice", customer: stripeCustomerId } },
  });

  const response = await post(handler, unrelated);

  assert.equal(response.statusCode, 200);
  assert.equal(repository.receipts.size, 0);
  assert.equal(repository.outboxes.size, 0);
  assert.deepEqual(logs, [{ eventCode: "stripe_webhook", result: "ignored" }]);
});

test("a signed supported subscription event with a noncanonical event ID is rejected before durable acceptance", async () => {
  const { handler, repository } = webhookHarness();
  const noncanonical = JSON.stringify({
    id: "evt_bad-id",
    object: "event",
    type: "customer.subscription.updated",
    created: Math.floor(nowMs / 1_000),
    data: { object: { id: stripeSubscriptionId, object: "subscription", customer: stripeCustomerId } },
  });

  assert.equal((await post(handler, noncanonical)).statusCode, 400);
  assert.equal(repository.receipts.size, 0);
  assert.equal(repository.outboxes.size, 0);
});

test("each signed Slice 4 subscription event type is accepted only as a durable reconciliation wake", async () => {
  const { handler, repository } = webhookHarness();
  const eventTypes = [
    "customer.subscription.created",
    "customer.subscription.deleted",
    "customer.subscription.paused",
    "customer.subscription.resumed",
    "customer.subscription.trial_will_end",
    "customer.subscription.updated",
  ] as const;
  for (const [index, type] of eventTypes.entries()) {
    const response = await post(handler, eventBody({ id: `evt_six_type_${index}`, type }));
    assert.equal(response.statusCode, 200, type);
  }
  assert.equal(repository.receipts.size, eventTypes.length);
  assert.equal(repository.outboxes.get("workspace-a")?.desiredGeneration, eventTypes.length);
  assert.equal(repository.subscriptions.size, 0, "webhook payload state never directly changes entitlement state");
});

test("signature verification fails closed on an invalid clock and rejects ambiguous duplicate headers", async () => {
  const body = eventBody({ id: "evt_clock", type: "customer.subscription.updated" });
  const raw = Buffer.from(body, "utf8");
  const invalidClock = new StripeWebhookSignatureVerifier({
    signingSecret,
    clock: { nowMs: () => Number.NaN },
    toleranceMs: 5 * 60_000,
  });
  assert.equal(invalidClock.verify(raw, signature(raw)), false);

  const { handler } = webhookHarness();
  const duplicateHeaders = await handler.handle({
    body,
    headers: {
      "Stripe-Signature": signature(raw),
      "stripe-signature": signature(raw),
    },
  });
  assert.equal(duplicateHeaders.statusCode, 400);
});

test("signature tolerance is inclusive at the exact boundary and any valid v1 among multiple candidates is accepted", () => {
  const body = Buffer.from(eventBody({ id: "evt_tolerance", type: "customer.subscription.updated" }), "utf8");
  const verifier = new StripeWebhookSignatureVerifier({
    signingSecret,
    clock: { nowMs: () => nowMs },
    toleranceMs: 5 * 60_000,
  });
  const exact = Math.floor((nowMs - 5 * 60_000) / 1_000);
  assert.equal(verifier.verify(body, signature(body, exact)), true);
  assert.equal(verifier.verify(body, signature(body, exact - 1)), false);
  assert.equal(verifier.verify(body, `t=${exact},v1=${"0".repeat(64)},${signature(body, exact).split(",")[1]}`), true);
});

test("durable receipt and outbox acceptance commits before success; duplicate and crash/retry are idempotent", async () => {
  const { handler, repository } = webhookHarness();
  let release!: () => void;
  repository.acceptGate = new Promise<void>((resolve) => { release = resolve; });
  let settled = false;
  const body = eventBody({ id: "evt_durable", type: "customer.subscription.updated" });
  const pending = post(handler, body).finally(() => { settled = true; });
  await new Promise<void>((resolve) => setImmediate(resolve));
  assert.equal(settled, false);
  release();
  assert.equal((await pending).statusCode, 200);
  repository.acceptGate = undefined;
  assert.equal(repository.receipts.size, 1);
  assert.equal(repository.outboxes.get("workspace-a")?.desiredGeneration, 1);
  assert.equal((await post(handler, body)).statusCode, 200);
  assert.equal(repository.receipts.size, 1);
  assert.equal(repository.outboxes.get("workspace-a")?.desiredGeneration, 1);

  const crashing = eventBody({ id: "evt_crash", type: "customer.subscription.updated" });
  repository.failAfterReceipt = true;
  assert.equal((await post(handler, crashing)).statusCode, 500);
  assert.equal([...repository.receipts.values()].some((receipt) => receipt.eventId === fixtureStripeEventId("evt_crash")), false);
  repository.failAfterReceipt = false;
  assert.equal((await post(handler, crashing)).statusCode, 200);
  assert.equal([...repository.receipts.values()].filter((receipt) => receipt.eventId === fixtureStripeEventId("evt_crash")).length, 1);

  const concurrent = eventBody({ id: "evt_concurrent_duplicate", type: "customer.subscription.updated" });
  const generationBefore = repository.outboxes.get("workspace-a")?.desiredGeneration;
  const concurrentResponses = await Promise.all([post(handler, concurrent), post(handler, concurrent)]);
  assert.deepEqual(concurrentResponses.map((response) => response.statusCode), [200, 200]);
  assert.equal([...repository.receipts.values()].filter((receipt) => receipt.eventId === fixtureStripeEventId("evt_concurrent_duplicate")).length, 1);
  assert.equal(repository.outboxes.get("workspace-a")?.desiredGeneration, (generationBefore ?? 0) + 1);
});

test("webhooks and semantic duplicates only mark reconciliation dirty and never apply event deltas", async () => {
  const { handler, repository } = webhookHarness();
  const first = eventBody({
    id: "evt_semantic_1",
    type: "customer.subscription.updated",
    objectId: stripeSubscriptionId,
    statusCanary: "canceled",
  });
  const second = eventBody({
    id: "evt_semantic_2",
    type: "customer.subscription.updated",
    objectId: stripeSubscriptionId,
    statusCanary: "active",
  });
  await post(handler, first);
  await post(handler, second);
  assert.equal(repository.receipts.size, 2);
  assert.equal(repository.subscriptions.size, 0);
  assert.equal(repository.outboxes.get("workspace-a")?.desiredGeneration, 2);
  assert.deepEqual(repository.projects, [{ id: "project-1", bytes: Uint8Array.from([9, 8, 7]) }]);
});

test("two Stripe accounts cannot silently share or replace one workspace mapping", async () => {
  const { handler, repository } = webhookHarness();
  repository.accountWorkspaces.set(stripeScopeKey({ accountMode: "connected", accountId: "acct_other0007", customerId: stripeCustomerId, subscriptionId: stripeSubscriptionId }), "workspace-a");
  assert.equal((await post(handler, eventBody({ id: "evt_primary_account", type: "customer.subscription.updated" }))).statusCode, 200);
  const conflicting = eventBody({ id: "evt_other_account", type: "customer.subscription.updated", account: "acct_other0007" });
  assert.equal((await post(handler, conflicting)).statusCode, 500);
  assert.equal(repository.outboxes.get("workspace-a")?.accountId, stripeAccountId);
  assert.equal([...repository.receipts.values()].some((receipt) => receipt.accountId === "acct_other0007"), false);
});

class CurrentSubscriptionSource {
  result: { readonly status: "current"; readonly snapshot: SubscriptionSnapshot } | { readonly status: "ambiguous" } = {
    status: "current",
    snapshot: {
      observedAtMs: nowMs,
      status: "active",
      planKey: "professional-test",
      currentPeriodEndMs: nowMs + 100_000,
    },
  };
  calls = 0;
  onFetch: (() => Promise<void>) | undefined;
  repository: MemoryBillingRepository | undefined;
  failure: Error | undefined;

  async fetchCurrent(_scope: StripeSubscriptionScope) {
    this.calls += 1;
    assert.equal(this.repository?.inTransaction, false, "provider fetch must be outside the DB transaction");
    if (this.onFetch !== undefined) await this.onFetch();
    if (this.failure !== undefined) throw this.failure;
    return structuredClone(this.result);
  }
}

function reconciliationHarness(repository: MemoryBillingRepository, source = new CurrentSubscriptionSource()) {
  source.repository = repository;
  const systemCapability = Symbol("stripe-reconciliation-system");
  const service = new BillingReconciliationService({
    clock: { nowMs: () => nowMs },
    random: { bytes: (length) => new Uint8Array(length).fill(4) },
    repository,
    currentSubscriptions: source,
    hostedGate: {
      hostedMutationGrant: async (workspaceId, action) => {
        if (!repository.gate.enabled) throw new Error("hosted disabled");
        return {
          kind: "hosted-mutation-grant-v2",
          workspaceId,
          action,
          hostedGlobalFlagVersion: repository.gate.globalVersion,
          hostedWorkspaceFlagVersion: repository.gate.workspaceVersion,
        } as const;
      },
    },
    systemAuthority: {
      capability: systemCapability,
      authorize: async ({ capability }) => capability === systemCapability,
    },
    leaseMs: 30_000,
  });
  return { service, source, gate: repository.gate, systemCapability };
}

test("reconciliation fetches current state outside the transaction and an event during fetch schedules another generation", async () => {
  const { handler, repository } = webhookHarness();
  await post(handler, eventBody({ id: "evt_before_fetch", type: "customer.subscription.created" }));
  const { service, source } = reconciliationHarness(repository);
  source.onFetch = async () => {
    source.onFetch = undefined;
    await post(handler, eventBody({ id: "evt_during_fetch", type: "customer.subscription.deleted" }));
  };
  const first = await service.runOnce();
  assert.deepEqual(first, { status: "applied", generation: 1, needsAnotherGeneration: true });
  assert.equal((await repository.currentSubscription("workspace-a"))?.generation, 1);
  const second = await service.runOnce();
  assert.deepEqual(second, { status: "applied", generation: 2, needsAnotherGeneration: false });
  assert.equal((await repository.currentSubscription("workspace-a"))?.status, "active");
});

test("ambiguous current-state fetch retries without entitlement mutation", async () => {
  const { handler, repository } = webhookHarness();
  await post(handler, eventBody({ id: "evt_ambiguous", type: "customer.subscription.updated" }));
  const { service, source } = reconciliationHarness(repository);
  source.result = { status: "ambiguous" };
  assert.deepEqual(await service.runOnce(), { status: "retry", reason: "ambiguous_current_state" });
  assert.equal(repository.subscriptions.size, 0);
  assert.equal(repository.outboxes.get("workspace-a")?.state, "pending");
});

test("provider fetch exceptions release the lease and retry without entitlement mutation", async () => {
  const { handler, repository } = webhookHarness();
  await post(handler, eventBody({ id: "evt_provider_exception", type: "customer.subscription.updated" }));
  const { service, source } = reconciliationHarness(repository);
  source.failure = new Error("provider unavailable");
  assert.deepEqual(await service.runOnce(), { status: "retry", reason: "current_state_unavailable" });
  assert.equal(repository.subscriptions.size, 0);
  assert.equal(repository.outboxes.get("workspace-a")?.state, "pending");
});

test("Stripe reconciliation rejects every workspace role as a system capability", async () => {
  for (const role of WORKSPACE_ROLES) {
    const repository = new MemoryBillingRepository();
    const source = new CurrentSubscriptionSource();
    const service = new BillingReconciliationService({
      clock: { nowMs: () => nowMs },
      random: { bytes: (length) => new Uint8Array(length).fill(5) },
      repository,
      currentSubscriptions: source,
      hostedGate: { hostedMutationGrant: async () => { throw new Error("must not reach gate"); } },
      systemAuthority: {
        capability: { role },
        authorize: async () => false,
      },
      leaseMs: 30_000,
    });
    await assert.rejects(service.runOnce(), (error: unknown) => error instanceof BillingError && error.code === "system_authorization_required");
  }
});

test("malformed and stale authoritative snapshots never replace newer entitlement state", async () => {
  const { handler, repository } = webhookHarness();
  await post(handler, eventBody({ id: "evt_initial", type: "customer.subscription.created" }));
  const first = reconciliationHarness(repository);
  assert.equal((await first.service.runOnce()).status, "applied");

  await post(handler, eventBody({ id: "evt_malformed_current", type: "customer.subscription.updated" }));
  const malformed = reconciliationHarness(repository);
  malformed.source.result = {
    status: "current",
    snapshot: {
      observedAtMs: nowMs,
      status: "event_delta_is_not_authoritative",
      planKey: "professional-test",
    },
  } as unknown as CurrentSubscriptionSource["result"];
  assert.deepEqual(await malformed.service.runOnce(), {
    status: "retry",
    reason: "ambiguous_current_state",
  });
  assert.equal(repository.subscriptions.get("workspace-a")?.status, "active");

  const stale = reconciliationHarness(repository);
  stale.source.result = {
    status: "current",
    snapshot: {
      observedAtMs: nowMs - 1,
      status: "canceled",
      planKey: "stale-plan",
    },
  };
  assert.deepEqual(await stale.service.runOnce(), { status: "retry", reason: "stale_claim" });
  assert.equal(repository.subscriptions.get("workspace-a")?.status, "active");
  assert.equal(repository.subscriptions.get("workspace-a")?.planKey, "professional-test");
});

test("a newer dirty generation can authoritatively decrease subscription entitlement", async () => {
  const { handler, repository } = webhookHarness();
  await post(handler, eventBody({ id: "evt_entitlement_active", type: "customer.subscription.created" }));
  const first = reconciliationHarness(repository);
  assert.equal((await first.service.runOnce()).status, "applied");
  assert.equal(repository.subscriptions.get("workspace-a")?.status, "active");

  await post(handler, eventBody({ id: "evt_entitlement_decrease", type: "customer.subscription.paused" }));
  const second = reconciliationHarness(repository);
  second.source.result = {
    status: "current",
    snapshot: { observedAtMs: nowMs + 1, status: "past_due", planKey: "professional-test" },
  };
  assert.deepEqual(await second.service.runOnce(), { status: "applied", generation: 2, needsAnotherGeneration: false });
  assert.equal(repository.subscriptions.get("workspace-a")?.status, "past_due");
});

test("arbitrary event-order permutations converge to the authoritative subscription and reject direct-delta semantics", async () => {
  const events = [
    { id: "evt_created", type: "customer.subscription.created", objectId: stripeSubscriptionId, statusCanary: "trialing" },
    { id: "evt_deleted", type: "customer.subscription.deleted", objectId: stripeSubscriptionId, statusCanary: "canceled" },
    { id: "evt_paused", type: "customer.subscription.paused", objectId: stripeSubscriptionId, statusCanary: "past_due" },
    { id: "evt_updated", type: "customer.subscription.updated", objectId: stripeSubscriptionId, statusCanary: "active" },
  ] as const;
  for (const order of permutations(events)) {
    const { handler, repository } = webhookHarness();
    for (const event of order) await post(handler, eventBody(event));
    const { service } = reconciliationHarness(repository);
    const result = await service.runOnce();
    assert.equal(result.status, "applied");
    const state = await repository.currentSubscription("workspace-a");
    assert.equal(state?.status, "active", order.map((event) => event.type).join(" -> "));
    assert.equal(state?.planKey, "professional-test");
    assert.equal(state?.generation, 4);
  }
});

test("valid ingestion remains durable during hosted freeze while entitlement application pauses visibly", async () => {
  const { handler, repository } = webhookHarness();
  assert.equal((await post(handler, eventBody({ id: "evt_freeze", type: "customer.subscription.updated" }))).statusCode, 200);
  const { service, gate, source } = reconciliationHarness(repository);
  gate.enabled = false;
  assert.deepEqual(await service.runOnce(), { status: "paused", reason: "hosted_operations_disabled" });
  assert.equal(source.calls, 0);
  assert.equal(repository.receipts.size, 1);
  assert.equal(repository.subscriptions.size, 0);
  gate.enabled = true;
  assert.equal((await service.runOnce()).status, "applied");
  assert.equal(repository.subscriptions.get("workspace-a")?.status, "active");
});

test("disable during authoritative fetch or completion CAS pauses application while ingestion remains durable", async () => {
  const duringFetch = webhookHarness();
  await post(duringFetch.handler, eventBody({ id: "evt_disable_fetch", type: "customer.subscription.updated" }));
  const fetchRun = reconciliationHarness(duringFetch.repository);
  fetchRun.source.onFetch = async () => {
    fetchRun.gate.enabled = false;
    fetchRun.gate.workspaceVersion += 1;
  };
  assert.deepEqual(await fetchRun.service.runOnce(), { status: "paused", reason: "hosted_operations_disabled" });
  assert.equal(duringFetch.repository.subscriptions.size, 0);
  assert.equal(duringFetch.repository.receipts.size, 1);

  const duringCas = webhookHarness();
  await post(duringCas.handler, eventBody({ id: "evt_disable_cas", type: "customer.subscription.updated" }));
  const casRun = reconciliationHarness(duringCas.repository);
  duringCas.repository.beforeComplete = () => {
    casRun.gate.enabled = false;
    casRun.gate.globalVersion += 1;
  };
  assert.deepEqual(await casRun.service.runOnce(), { status: "paused", reason: "hosted_operations_disabled" });
  assert.equal(duringCas.repository.subscriptions.size, 0);
});

test("disable then re-enable during fetch cannot replace the original hosted grant", async () => {
  const rotated = webhookHarness();
  await post(rotated.handler, eventBody({ id: "evt_disable_reenable", type: "customer.subscription.updated" }));
  const run = reconciliationHarness(rotated.repository);
  run.source.onFetch = async () => {
    run.gate.enabled = false;
    run.gate.workspaceVersion = 2;
    run.gate.enabled = true;
    run.gate.workspaceVersion = 3;
  };
  assert.deepEqual(await run.service.runOnce(), {
    status: "paused",
    reason: "hosted_operations_disabled",
  });
  assert.equal(rotated.repository.subscriptions.size, 0);

  const stable = webhookHarness();
  await post(stable.handler, eventBody({ id: "evt_stable_grant", type: "customer.subscription.updated" }));
  assert.equal((await reconciliationHarness(stable.repository).service.runOnce()).status, "applied");
  assert.equal(stable.repository.subscriptions.get("workspace-a")?.status, "active");
});

test("expired or lost reconciliation leases cannot complete or release another worker's claim", async () => {
  const { handler, repository } = webhookHarness();
  await post(handler, eventBody({ id: "evt_lease_loss", type: "customer.subscription.updated" }));
  const oldClaim = await repository.transaction((transaction) => transaction.claimReconciliation("lease-old", nowMs, nowMs + 10));
  assert.ok(oldClaim);
  const grant: HostedMutationGrant = {
    kind: "hosted-mutation-grant-v2",
    workspaceId: "workspace-a",
    action: "system.stripe.reconcile",
    hostedGlobalFlagVersion: repository.gate.globalVersion,
    hostedWorkspaceFlagVersion: repository.gate.workspaceVersion,
  };
  const snapshot: SubscriptionSnapshot = { observedAtMs: nowMs, status: "active", planKey: "professional-test" };
  assert.equal((await repository.transaction((transaction) => transaction.completeReconciliation({ claim: oldClaim, snapshot, appliedAtMs: nowMs + 10, hostedGrant: grant }))).status, "stale_claim");
  assert.equal(
    await repository.transaction((transaction) => transaction.releaseReconciliation(oldClaim, nowMs + 10)),
    false,
    "a still-current lease cannot be released at or after its expiry",
  );
  const replacement = await repository.transaction((transaction) => transaction.claimReconciliation("lease-new", nowMs + 11, nowMs + 1_000));
  assert.ok(replacement);
  assert.equal((await repository.transaction((transaction) => transaction.completeReconciliation({ claim: oldClaim, snapshot, appliedAtMs: nowMs + 12, hostedGrant: grant }))).status, "stale_claim");
  assert.equal(
    await repository.transaction((transaction) => transaction.releaseReconciliation(oldClaim, nowMs + 12)),
    false,
  );
  assert.equal((await repository.transaction((transaction) => transaction.completeReconciliation({ claim: replacement, snapshot, appliedAtMs: nowMs + 12, hostedGrant: grant }))).status, "applied");
});

function permutations<T>(values: readonly T[]): T[][] {
  if (values.length <= 1) return [values.slice()];
  const result: T[][] = [];
  for (let index = 0; index < values.length; index += 1) {
    const head = values[index];
    if (head === undefined) continue;
    const remainder = [...values.slice(0, index), ...values.slice(index + 1)];
    for (const tail of permutations(remainder)) result.push([head, ...tail]);
  }
  return result;
}
