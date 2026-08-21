import assert from "node:assert/strict";
import { test } from "node:test";

import {
  DEFAULT_MAGIC_LINK_POLICY,
  MAGIC_LINK_CONSUME_PATH,
  MagicLinkDeliveryWorker,
  MagicLinkError,
  MagicLinkService,
  normalizeDeliveryIdentity,
  type MagicLinkClaim,
  type MagicLinkDeliveryAttemptResult,
  type MagicLinkDeliveryOutboxRecord,
  type MagicLinkDeliveryPort,
  type MagicLinkDeliveryPreSendResult,
  type MagicLinkDeliveryReleaseResult,
  type MagicLinkDirectoryPort,
  type MagicLinkLogPort,
  type MagicLinkRateEvent,
  type MagicLinkRecord,
  type MagicLinkSessionIssuer,
  type MagicLinkSealingKeyring,
  type MagicLinkStore,
  type MagicLinkTransaction,
} from "../magic-links.js";
import {
  CandidateIdentityProofService,
  DEFAULT_IDENTITY_LINK_POLICY,
  IdentityLinkingService,
  type RecentSessionVerifier,
  type TrustedRecentSession,
  type VerifiedAuthenticationReceipt,
} from "../identity-linking.js";
import {
  FlowIdentityStore,
  seedFlowPrincipal,
} from "./support/identity-store.js";
import {
  AsyncOperationGate,
  observeSettlement,
} from "./support/async-operation-gate.js";

class ManualClock {
  constructor(private current = Date.UTC(2026, 7, 18, 10, 0, 0)) {}
  nowMs(): number { return this.current; }
  advance(milliseconds: number): void { this.current += milliseconds; }
}

class SequenceRandom {
  readonly requestedLengths: number[] = [];
  private nextByte = 1;
  bytes(length: number): Uint8Array {
    this.requestedLengths.push(length);
    const value = this.nextByte++;
    return Uint8Array.from({ length }, (_, index) => (value + index) & 0xff);
  }
}

class MemoryMagicLinkStore implements MagicLinkStore, MagicLinkTransaction {
  readonly records: MagicLinkRecord[] = [];
  readonly rateEvents: MagicLinkRateEvent[] = [];
  readonly outbox: MagicLinkDeliveryOutboxRecord[] = [];
  failNextOutboxInsert = false;
  loseNextConsumeClaim = false;
  reverseActiveResults = false;
  readonly operationGate = new AsyncOperationGate();
  private tail: Promise<void> = Promise.resolve();

  constructor(
    readonly verifiedAuthenticationReceipts: VerifiedAuthenticationReceipt[] = [],
  ) {}

  async transaction<T>(work: (transaction: MagicLinkTransaction) => Promise<T>): Promise<T> {
    const previous = this.tail;
    let release = (): void => undefined;
    this.tail = new Promise<void>((resolve) => { release = resolve; });
    await previous;
    const snapshot = {
      records: structuredClone(this.records),
      rateEvents: structuredClone(this.rateEvents),
      outbox: structuredClone(this.outbox),
      verifiedAuthenticationReceipts: structuredClone(this.verifiedAuthenticationReceipts),
    };
    try {
      return await work(this);
    } catch (error) {
      this.records.splice(0, this.records.length, ...snapshot.records);
      this.rateEvents.splice(0, this.rateEvents.length, ...snapshot.rateEvents);
      this.outbox.splice(0, this.outbox.length, ...snapshot.outbox);
      this.verifiedAuthenticationReceipts.splice(
        0,
        this.verifiedAuthenticationReceipts.length,
        ...snapshot.verifiedAuthenticationReceipts,
      );
      throw error;
    } finally {
      release();
    }
  }

  async activeFor(identity: string, purpose: string, atMs: number): Promise<MagicLinkRecord[]> {
    const records = this.records
      .filter((record) => record.normalizedDeliveryIdentity === identity && record.purpose === purpose && record.state === "active" && record.expiresAtMs > atMs)
      .sort((left, right) => left.issuedAtMs - right.issuedAtMs);
    return this.reverseActiveResults ? records.reverse() : records;
  }

  async mostRecentDelivery(identity: string, purpose: string): Promise<MagicLinkRecord | undefined> {
    return this.records
      .filter((record) => record.normalizedDeliveryIdentity === identity && record.purpose === purpose)
      .sort((left, right) => right.issuedAtMs - left.issuedAtMs)[0];
  }

  async countRateEvents(kind: MagicLinkRateEvent["kind"], hash: string, sinceMs: number): Promise<number> {
    await this.operationGate.before("countRateEvents");
    return this.rateEvents.filter((event) => event.kind === kind && event.hash === hash && event.atMs >= sinceMs).length;
  }

  async insert(record: MagicLinkRecord): Promise<void> { this.records.push(structuredClone(record)); }

  async supersedeIfActive(selector: string, atMs: number): Promise<boolean> {
    const record = this.records.find((candidate) => candidate.selector === selector && candidate.state === "active");
    if (record === undefined) return false;
    record.state = "superseded";
    record.supersededAtMs = atMs;
    return true;
  }

  async claimActiveLink(claim: MagicLinkClaim): Promise<MagicLinkRecord | undefined> {
    await this.operationGate.before("claimActiveLink");
    if (this.loseNextConsumeClaim) {
      this.loseNextConsumeClaim = false;
      return undefined;
    }
    const record = this.records.find((candidate) =>
      candidate.selector === claim.selector &&
      candidate.secretDigest === claim.secretDigest &&
      (claim.purpose === undefined || candidate.purpose === claim.purpose) &&
      candidate.state === "active" &&
      candidate.expiresAtMs > claim.nowMs,
    );
    if (record === undefined) return undefined;
    record.state = "consumed";
    record.consumedAtMs = claim.nowMs;
    return structuredClone(record);
  }

  async supersedeActiveSiblings(identity: string, purpose: string, exceptSelector: string, atMs: number): Promise<number> {
    let changed = 0;
    for (const record of this.records) {
      if (record.normalizedDeliveryIdentity === identity && record.purpose === purpose && record.selector !== exceptSelector && record.state === "active") {
        record.state = "superseded";
        record.supersededAtMs = atMs;
        changed += 1;
      }
    }
    return changed;
  }

  async recordRateEvent(event: MagicLinkRateEvent): Promise<void> { this.rateEvents.push(structuredClone(event)); }

  async insertDeliveryOutbox(record: MagicLinkDeliveryOutboxRecord): Promise<void> {
    await this.operationGate.before("insertDeliveryOutbox");
    if (this.failNextOutboxInsert) {
      this.failNextOutboxInsert = false;
      throw new Error("outbox insert failed");
    }
    this.outbox.push(structuredClone(record));
  }

  async insertVerifiedAuthenticationReceipt(
    receipt: VerifiedAuthenticationReceipt,
  ): Promise<void> {
    this.verifiedAuthenticationReceipts.push(structuredClone(receipt));
  }

  async availableDeliveries(nowMs: number, limit: number): Promise<MagicLinkDeliveryOutboxRecord[]> {
    return this.outbox
      .filter((record) =>
        record.state === "pending" ||
        (record.state === "leased" && (record.leaseExpiresAtMs ?? 0) <= nowMs),
      )
      .slice(0, limit)
      .map((record) => structuredClone(record));
  }

  async claimDeliveryAttempt(
    id: string,
    leaseId: string,
    nowMs: number,
    leaseExpiresAtMs: number,
  ): Promise<MagicLinkDeliveryAttemptResult> {
    await this.operationGate.before("claimDeliveryAttempt");
    const record = this.outbox.find((candidate) =>
      candidate.id === id &&
      (candidate.state === "pending" ||
        (candidate.state === "leased" && (candidate.leaseExpiresAtMs ?? 0) <= nowMs)),
    );
    if (record === undefined) return { status: "unavailable" };
    if (record.expiresAtMs <= nowMs) {
      record.state = "expired";
      record.cancelledAtMs = nowMs;
      record.cancellationReason = "expired";
      delete record.leaseId;
      delete record.leaseExpiresAtMs;
      return { status: "expired" };
    }
    record.state = "leased";
    record.leaseId = leaseId;
    record.leaseExpiresAtMs = leaseExpiresAtMs;
    record.deliveryAttempts += 1;
    return { status: "claimed", record: structuredClone(record) };
  }

  async validateDeliveryAttemptBeforeSend(
    id: string,
    leaseId: string,
    nowMs: number,
  ): Promise<MagicLinkDeliveryPreSendResult> {
    await this.operationGate.before("validateDeliveryAttemptBeforeSend");
    const record = this.outbox.find((candidate) =>
      candidate.id === id && candidate.state === "leased" && candidate.leaseId === leaseId,
    );
    if (record === undefined) return { status: "unavailable" };
    if (record.expiresAtMs <= nowMs) {
      record.state = "expired";
      record.cancelledAtMs = nowMs;
      record.cancellationReason = "expired";
      delete record.leaseId;
      delete record.leaseExpiresAtMs;
      return { status: "expired" };
    }
    if ((record.leaseExpiresAtMs ?? 0) <= nowMs) return { status: "unavailable" };
    return { status: "ready", record: structuredClone(record) };
  }

  async completeDeliveryAttempt(id: string, leaseId: string, deliveredAtMs: number): Promise<boolean> {
    const record = this.outbox.find((candidate) =>
      candidate.id === id && candidate.state === "leased" && candidate.leaseId === leaseId,
    );
    if (record === undefined) return false;
    record.state = "delivered";
    record.deliveredAtMs = deliveredAtMs;
    delete record.leaseId;
    delete record.leaseExpiresAtMs;
    return true;
  }

  async cancelDeliveryAttempt(
    id: string,
    leaseId: string,
    reason: "unknown_key" | "tampered_envelope",
    cancelledAtMs: number,
  ): Promise<boolean> {
    const record = this.outbox.find((candidate) =>
      candidate.id === id && candidate.state === "leased" && candidate.leaseId === leaseId,
    );
    if (record === undefined) return false;
    record.state = "cancelled";
    record.cancelledAtMs = cancelledAtMs;
    record.cancellationReason = reason;
    delete record.leaseId;
    delete record.leaseExpiresAtMs;
    return true;
  }

  async releaseDeliveryAttempt(
    id: string,
    leaseId: string,
    nowMs: number,
  ): Promise<MagicLinkDeliveryReleaseResult> {
    const record = this.outbox.find((candidate) =>
      candidate.id === id && candidate.state === "leased" && candidate.leaseId === leaseId,
    );
    if (record === undefined) return "unavailable";
    delete record.leaseId;
    delete record.leaseExpiresAtMs;
    if (record.expiresAtMs <= nowMs) {
      record.state = "expired";
      record.cancelledAtMs = nowMs;
      record.cancellationReason = "expired";
      return "expired";
    }
    record.state = "pending";
    return "released";
  }
}

class MemorySealingKeyring implements MagicLinkSealingKeyring {
  readonly keys = new Map<string, Uint8Array>([
    ["key-2026-08", Buffer.alloc(32, 0x44)],
  ]);
  activeKeyId = "key-2026-08";
  readonly decryptionLookups: string[] = [];
  afterDecryptionKeyLookup: (() => void | Promise<void>) | undefined;

  async activeKey(): Promise<{ readonly keyId: string; readonly key: Uint8Array }> {
    const key = this.keys.get(this.activeKeyId);
    if (key === undefined) throw new Error("active key unavailable");
    return { keyId: this.activeKeyId, key };
  }

  async decryptionKey(keyId: string): Promise<Uint8Array | undefined> {
    this.decryptionLookups.push(keyId);
    const hook = this.afterDecryptionKeyLookup;
    this.afterDecryptionKeyLookup = undefined;
    await hook?.();
    return this.keys.get(keyId);
  }
}

interface DeliveredLink {
  readonly normalizedDeliveryIdentity: string;
  readonly purpose: string;
  readonly url: string;
  readonly idempotencyKey: string;
}

interface Harness {
  readonly service: MagicLinkService;
  readonly worker: MagicLinkDeliveryWorker;
  readonly clock: ManualClock;
  readonly random: SequenceRandom;
  readonly store: MemoryMagicLinkStore;
  readonly deliveries: DeliveredLink[];
  readonly logs: ReadonlyArray<Record<string, unknown>>;
  readonly issuedDevices: string[];
  readonly directoryStates: Map<string, "enabled" | "disabled">;
  readonly deliveryControl: { failNext: boolean };
  readonly keyring: MemorySealingKeyring;
}

const CURRENT_ACCESS_TOKEN = Buffer.alloc(32, 0xa7).toString("base64url");

function makeHarness(overrides: {
  readonly recentSessions?: RecentSessionVerifier;
  readonly verifiedAuthenticationReceipts?: VerifiedAuthenticationReceipt[];
  readonly keyring?: MemorySealingKeyring;
} = {}): Harness {
  const clock = new ManualClock();
  const random = new SequenceRandom();
  const store = new MemoryMagicLinkStore(overrides.verifiedAuthenticationReceipts);
  const keyring = overrides.keyring ?? new MemorySealingKeyring();
  const deliveries: DeliveredLink[] = [];
  const logs: Record<string, unknown>[] = [];
  const issuedDevices: string[] = [];
  const directoryStates = new Map<string, "enabled" | "disabled">();
  const deliveryControl = { failNext: false };
  const directory: MagicLinkDirectoryPort = {
    async statusFor(identity) { return directoryStates.get(identity) ?? "new"; },
  };
  const delivery: MagicLinkDeliveryPort = {
    async enqueue(message) {
      if (deliveryControl.failNext) {
        deliveryControl.failNext = false;
        throw new Error("queue unavailable");
      }
      deliveries.push(structuredClone(message));
    },
  };
  const sessions: MagicLinkSessionIssuer = {
    async issueForVerifiedEmail(input) {
      issuedDevices.push(input.clickingDeviceId);
      return { accessToken: `access-${issuedDevices.length}`, refreshToken: `refresh-${issuedDevices.length}` };
    },
  };
  const recentSession: TrustedRecentSession = {
    principalId: "principal-a",
    familyId: "family-a",
    authenticatedAtMs: clock.nowMs(),
  };
  const defaultRecentSessions: RecentSessionVerifier = {
    async verifyRecentSession(accessToken) {
      if (accessToken !== CURRENT_ACCESS_TOKEN) throw new Error("invalid access");
      return structuredClone(recentSession);
    },
  };
  const logger: MagicLinkLogPort = {
    write(eventCode, fields) { logs.push({ eventCode, ...fields }); },
  };
  const common = {
    clock,
    random,
    store,
    delivery,
    logger,
    keyring,
    policy: DEFAULT_MAGIC_LINK_POLICY,
    publicOrigin: "https://rooms.example",
  };
  return {
    clock,
    random,
    store,
    deliveries,
    logs,
    issuedDevices,
    directoryStates,
    deliveryControl,
    keyring,
    service: new MagicLinkService({
      ...common,
      directory,
      sessions,
      recentSessions: overrides.recentSessions ?? defaultRecentSessions,
      verifiedAuthenticationReceiptHmacKey: Buffer.alloc(32, 0x40),
      tokenHmacKey: Buffer.alloc(32, 0x41),
      addressHmacKey: Buffer.alloc(32, 0x42),
      networkHmacKey: Buffer.alloc(32, 0x43),
      policy: DEFAULT_MAGIC_LINK_POLICY,
    }),
    worker: new MagicLinkDeliveryWorker(common),
  };
}

async function requestLink(harness: Harness, email = "Person@Example.COM", networkAddress = "203.0.113.4") {
  return harness.service.request({ email, purpose: "sign-in", networkAddress });
}

async function flushDeliveries(harness: Harness): Promise<void> {
  await harness.worker.runOnce(100);
}

function deliveredCredential(delivery: DeliveredLink): { selector: string; secret: string } {
  const url = new URL(delivery.url);
  const selector = url.pathname.split("/").at(-1);
  assert.ok(selector);
  assert.match(url.hash, /^#[A-Za-z0-9_-]+$/u);
  return { selector, secret: url.hash.slice(1) };
}

test("normalization is conservative and accepts Apple relay addresses", () => {
  assert.equal(normalizeDeliveryIdentity("  First.Last+tag@Example.COM  "), "First.Last+tag@example.com");
  assert.equal(normalizeDeliveryIdentity("relay_ABC@privaterelay.appleid.com"), "relay_ABC@privaterelay.appleid.com");
  assert.equal(normalizeDeliveryIdentity("first last@example.com"), undefined);
});

test("issuance atomically stores a hash-only link and sealed durable delivery outbox", async () => {
  const harness = makeHarness();
  assert.deepEqual(await requestLink(harness), { accepted: true, status: 202 });
  assert.equal(harness.deliveries.length, 0);
  assert.equal(harness.store.records.length, 1);
  assert.equal(harness.store.outbox.length, 1);
  assert.equal(harness.store.outbox[0]?.state, "pending");
  await flushDeliveries(harness);
  const delivery = harness.deliveries[0];
  assert.ok(delivery);
  const { selector, secret } = deliveredCredential(delivery);
  assert.equal(Buffer.from(secret, "base64url").length, 32);
  assert.equal(harness.store.records[0]?.selector, selector);
  assert.equal(harness.store.records[0]?.expiresAtMs - harness.store.records[0]!.issuedAtMs, 10 * 60_000);
  assert.equal(JSON.stringify({ records: harness.store.records, outbox: harness.store.outbox }).includes(secret), false);
  assert.equal(JSON.stringify(harness.logs).includes(secret), false);
  assert.equal(delivery.url.startsWith(`https://rooms.example/auth/magic-link/${selector}#`), true);
  const visibleUrl = new URL(delivery.url);
  assert.equal(visibleUrl.search, "");
  assert.equal(`${visibleUrl.origin}${visibleUrl.pathname}`.includes(secret), false);
  assert.equal(visibleUrl.pathname, `/auth/magic-link/${selector}`);
});

test("outbox failure rolls back policy use; queue failure leaves durable work for idempotent retry", async () => {
  const harness = makeHarness();
  harness.store.failNextOutboxInsert = true;
  assert.deepEqual(await requestLink(harness), { accepted: true, status: 202 });
  assert.equal(harness.store.records.length, 0);
  assert.equal(harness.store.rateEvents.length, 0);
  assert.equal(harness.store.outbox.length, 0);

  await requestLink(harness);
  harness.deliveryControl.failNext = true;
  assert.deepEqual(await harness.worker.runOnce(10), { attempted: 1, delivered: 0 });
  assert.equal(harness.store.outbox[0]?.state, "pending");
  assert.deepEqual(await harness.worker.runOnce(10), { attempted: 1, delivered: 1 });
  assert.equal(harness.deliveries.length, 1);
  assert.equal(harness.store.outbox[0]?.deliveryAttempts, 2);
  assert.equal(harness.store.outbox[0]?.state, "delivered");
});

test("delivery retries at and after the ten-minute TTL atomically expire without decrypting or sending", async (context) => {
  for (const delayAfterInitialFailure of [1, 2] as const) {
    await context.test(delayAfterInitialFailure === 1 ? "at TTL" : "after TTL", async () => {
      const harness = makeHarness();
      await requestLink(harness);
      harness.clock.advance(10 * 60_000 - 1);
      harness.deliveryControl.failNext = true;
      assert.deepEqual(await harness.worker.runOnce(10), { attempted: 1, delivered: 0 });
      assert.equal(harness.store.outbox[0]?.state, "pending");
      const lookupsBeforeExpiry = harness.keyring.decryptionLookups.length;

      harness.clock.advance(delayAfterInitialFailure);
      assert.deepEqual(await harness.worker.runOnce(10), { attempted: 0, delivered: 0 });
      assert.equal(harness.store.outbox[0]?.state, "expired");
      assert.equal(harness.store.outbox[0]?.cancellationReason, "expired");
      assert.equal(harness.keyring.decryptionLookups.length, lookupsBeforeExpiry);
      assert.equal(harness.deliveries.length, 0);
    });
  }
});

test("delivery revalidates expiry and ownership after asynchronous key lookup before decrypting or sending", async (context) => {
  await context.test("expiry reached during key lookup wins before envelope decryption", async () => {
    const harness = makeHarness();
    await requestLink(harness);
    const envelope = harness.store.outbox[0]?.sealedSecret;
    assert.ok(envelope);
    envelope.ciphertext = `${envelope.ciphertext.slice(0, -1)}A`;
    harness.clock.advance(DEFAULT_MAGIC_LINK_POLICY.ttlMs - 1);
    harness.keyring.afterDecryptionKeyLookup = () => {
      harness.clock.advance(1);
    };

    assert.deepEqual(await harness.worker.runOnce(10), { attempted: 1, delivered: 0 });
    assert.equal(harness.store.outbox[0]?.state, "expired");
    assert.equal(harness.store.outbox[0]?.cancellationReason, "expired");
    assert.equal(harness.deliveries.length, 0);
  });

  await context.test("a competing transition that takes ownership makes the stale worker stop", async () => {
    const harness = makeHarness();
    await requestLink(harness);
    harness.keyring.afterDecryptionKeyLookup = async () => {
      harness.clock.advance(DEFAULT_MAGIC_LINK_POLICY.deliveryLeaseMs);
      const record = harness.store.outbox[0];
      assert.ok(record);
      const competingClaim = await harness.store.transaction(async (transaction) =>
        await transaction.claimDeliveryAttempt(
          record.id,
          "lease-held-by-a-competing-worker",
          harness.clock.nowMs(),
          harness.clock.nowMs() + DEFAULT_MAGIC_LINK_POLICY.deliveryLeaseMs,
        ),
      );
      assert.equal(competingClaim.status, "claimed");
    };

    assert.deepEqual(await harness.worker.runOnce(10), { attempted: 1, delivered: 0 });
    assert.equal(harness.deliveries.length, 0);
    assert.equal(harness.store.outbox[0]?.state, "leased");
    harness.clock.advance(DEFAULT_MAGIC_LINK_POLICY.deliveryLeaseMs);
    assert.deepEqual(await harness.worker.runOnce(10), { attempted: 1, delivered: 1 });
    assert.equal(harness.deliveries.length, 1);
  });
});

test("sealed delivery envelopes reject tampering and unknown keys while retained keys survive rotation", async () => {
  const unknown = makeHarness();
  await requestLink(unknown, "unknown-key@example.com");
  const unknownKeyId = unknown.store.outbox[0]?.sealedSecret.keyId;
  assert.ok(unknownKeyId);
  unknown.keyring.keys.delete(unknownKeyId);
  assert.deepEqual(await unknown.worker.runOnce(10), { attempted: 1, delivered: 0 });
  assert.equal(unknown.store.outbox[0]?.state, "cancelled");
  assert.equal(unknown.store.outbox[0]?.cancellationReason, "unknown_key");
  assert.equal(unknown.deliveries.length, 0);

  const tampered = makeHarness();
  await requestLink(tampered, "tampered@example.com");
  const envelope = tampered.store.outbox[0]?.sealedSecret;
  assert.ok(envelope);
  envelope.ciphertext = `${envelope.ciphertext.slice(0, -1)}A`;
  assert.deepEqual(await tampered.worker.runOnce(10), { attempted: 1, delivered: 0 });
  assert.equal(tampered.store.outbox[0]?.state, "cancelled");
  assert.equal(tampered.store.outbox[0]?.cancellationReason, "tampered_envelope");
  assert.equal(tampered.deliveries.length, 0);

  const rotation = makeHarness();
  await requestLink(rotation, "before-rotation@example.com");
  rotation.keyring.keys.set("key-2026-09", Buffer.alloc(32, 0x45));
  rotation.keyring.activeKeyId = "key-2026-09";
  await requestLink(rotation, "after-rotation@example.com", "203.0.113.5");
  assert.deepEqual(
    rotation.store.outbox.map((record) => record.sealedSecret.keyId),
    ["key-2026-08", "key-2026-09"],
  );
  assert.deepEqual(await rotation.worker.runOnce(10), { attempted: 2, delivered: 2 });
  assert.deepEqual(rotation.keyring.decryptionLookups, ["key-2026-08", "key-2026-09"]);
});

test("anti-enumeration, cooldown, active-link supersession, and configured rate limits remain outwardly identical", async () => {
  const harness = makeHarness();
  harness.directoryStates.set("disabled@example.com", "disabled");
  const outcomes = [
    await requestLink(harness, "not an email", "198.51.100.1"),
    await requestLink(harness, "disabled@example.com", "198.51.100.2"),
  ];
  assert.ok(outcomes.every((result) => JSON.stringify(result) === '{"accepted":true,"status":202}'));
  assert.equal(harness.store.records.length, 0);

  await requestLink(harness);
  harness.clock.advance(59_999);
  await requestLink(harness);
  assert.equal(harness.store.records.length, 1);
  harness.clock.advance(1);
  await requestLink(harness);
  harness.clock.advance(60_000);
  await requestLink(harness);
  assert.deepEqual(harness.store.records.map((record) => record.state), ["superseded", "active", "active"]);

  const rateHarness = makeHarness();
  for (let index = 0; index < 4; index += 1) {
    await requestLink(rateHarness, "limited@example.com", `192.0.2.${index}`);
    rateHarness.clock.advance(61_000);
  }
  assert.equal(rateHarness.store.records.length, 3);
});

test("active-link supersession is deterministic for unordered repository results", async (context) => {
  await context.test("server creation time wins even when the repository reverses its rows", async () => {
    const harness = makeHarness();
    await requestLink(harness);
    const oldest = harness.store.records[0];
    assert.ok(oldest);
    harness.clock.advance(DEFAULT_MAGIC_LINK_POLICY.cooldownMs);
    await requestLink(harness);
    const newer = harness.store.records[1];
    assert.ok(newer);
    harness.store.reverseActiveResults = true;
    harness.clock.advance(DEFAULT_MAGIC_LINK_POLICY.cooldownMs);
    await requestLink(harness);

    assert.equal(oldest.state, "superseded");
    assert.equal(newer.state, "active");
  });

  await context.test("selector is a stable tie-breaker for equal server creation times", async () => {
    const harness = makeHarness();
    await requestLink(harness);
    harness.clock.advance(DEFAULT_MAGIC_LINK_POLICY.cooldownMs);
    await requestLink(harness);
    const first = harness.store.records[0];
    const second = harness.store.records[1];
    assert.ok(first);
    assert.ok(second);
    const equalIssuedAtMs = harness.clock.nowMs() - DEFAULT_MAGIC_LINK_POLICY.cooldownMs;
    Object.assign(first, { selector: "selector-z", issuedAtMs: equalIssuedAtMs });
    Object.assign(second, { selector: "selector-a", issuedAtMs: equalIssuedAtMs });

    await requestLink(harness);

    assert.equal(first.state, "active");
    assert.equal(second.state, "superseded");
  });
});

test("daily address and network limits remain 10/day and 20/15-minutes, including Apple relay delivery", async () => {
  const daily = makeHarness();
  for (let index = 0; index < 11; index += 1) {
    await requestLink(daily, "daily@example.com", `198.51.100.${index}`);
    daily.clock.advance(15 * 60_000 + 1);
  }
  assert.equal(daily.store.records.length, 10);

  const network = makeHarness();
  for (let index = 0; index < 21; index += 1) {
    await requestLink(network, `person-${index}@example.com`, "203.0.113.99");
  }
  assert.equal(network.store.records.length, 20);

  const relay = makeHarness();
  await requestLink(relay, "relay_ABC@privaterelay.appleid.com");
  assert.equal(relay.store.records[0]?.normalizedDeliveryIdentity, "relay_ABC@privaterelay.appleid.com");
});

test("scanner GET returns static strict first-party HTML that strips the fragment before deliberate POST", async () => {
  const harness = makeHarness();
  await requestLink(harness);
  const before = structuredClone(harness.store.records);
  const response = await harness.service.renderConfirmation();
  const again = await harness.service.renderConfirmation();
  assert.deepEqual(response, again);
  assert.equal(response.status, 200);
  assert.match(response.headers["content-security-policy"] ?? "", /^default-src 'none'; script-src 'sha256-/u);
  assert.equal(response.headers["referrer-policy"], "no-referrer");
  assert.equal(response.headers["cache-control"], "no-store");
  assert.equal(response.headers["permissions-policy"], "camera=(), microphone=(), geolocation=()");
  assert.equal(/https?:\/\//u.test(response.body), false);
  assert.equal(/<(img|iframe|link)\b/iu.test(response.body), false);
  assert.equal(response.body.includes("TOKEN_CANARY"), false);
  const replacement = response.body.indexOf("history.replaceState");
  const post = response.body.indexOf("fetch(");
  assert.ok(replacement >= 0 && post > replacement);
  assert.equal(response.body.includes(MAGIC_LINK_CONSUME_PATH), true);
  assert.equal(response.body.includes("purpose"), false);
  assert.equal(MAGIC_LINK_CONSUME_PATH.includes(":"), false);
  assert.equal(MAGIC_LINK_CONSUME_PATH.includes("{"), false);
  assert.deepEqual(harness.store.records, before);
  assert.equal(harness.issuedDevices.length, 0);
});

test("deliberate token-free POST consumes once, supersedes siblings, and authenticates the clicking device", async () => {
  const harness = makeHarness();
  await requestLink(harness);
  harness.clock.advance(60_000);
  await requestLink(harness);
  await flushDeliveries(harness);
  const first = deliveredCredential(harness.deliveries[0]!);
  const second = deliveredCredential(harness.deliveries[1]!);
  const accepted = await harness.service.consume({ ...second, clickingDeviceId: "clicking-device" });
  const replay = await harness.service.consume({ ...second, purpose: "sign-in", clickingDeviceId: "other-device" });
  const superseded = await harness.service.consume({ ...first, purpose: "sign-in", clickingDeviceId: "other-device" });
  assert.equal(accepted.status, "authenticated");
  assert.deepEqual(replay, { status: "rejected" });
  assert.deepEqual(superseded, { status: "rejected" });
  assert.deepEqual(harness.issuedDevices, ["clicking-device"]);
  assert.deepEqual(harness.store.records.map((record) => record.state), ["superseded", "consumed"]);
});

test("explicit consume CAS rejects a lost claim and concurrent consumption has one winner", async () => {
  const lostHarness = makeHarness();
  await requestLink(lostHarness);
  await flushDeliveries(lostHarness);
  const credential = deliveredCredential(lostHarness.deliveries[0]!);
  lostHarness.store.loseNextConsumeClaim = true;
  assert.deepEqual(await lostHarness.service.consume({ ...credential, purpose: "sign-in", clickingDeviceId: "device" }), { status: "rejected" });
  assert.equal(lostHarness.issuedDevices.length, 0);

  const harness = makeHarness();
  await requestLink(harness);
  await flushDeliveries(harness);
  const shared = deliveredCredential(harness.deliveries[0]!);
  const results = await Promise.all(Array.from({ length: 12 }, (_, index) => harness.service.consume({ ...shared, purpose: "sign-in", clickingDeviceId: `device-${index}` })));
  assert.equal(results.filter((result) => result.status === "authenticated").length, 1);
  assert.equal(results.filter((result) => result.status === "rejected").length, 11);
  assert.equal(harness.issuedDevices.length, 1);
});

test("magic request, consume, and delivery worker await delayed async reads, writes, and claims", async () => {
  const readHarness = makeHarness();
  readHarness.store.operationGate.arm("countRateEvents");
  const delayedRead = requestLink(readHarness);
  const readSettlement = observeSettlement(delayedRead);
  await readHarness.store.operationGate.waitUntilReached();
  assert.equal(readSettlement.settled(), false);
  assert.equal(readHarness.store.records.length, 0);
  readHarness.store.operationGate.release();
  await delayedRead;

  const writeHarness = makeHarness();
  writeHarness.store.operationGate.arm("insertDeliveryOutbox");
  const delayedWrite = requestLink(writeHarness);
  const writeSettlement = observeSettlement(delayedWrite);
  await writeHarness.store.operationGate.waitUntilReached();
  assert.equal(writeSettlement.settled(), false);
  assert.equal(writeHarness.store.outbox.length, 0);
  writeHarness.store.operationGate.release();
  await delayedWrite;

  const consumeHarness = makeHarness();
  await requestLink(consumeHarness);
  await flushDeliveries(consumeHarness);
  const credential = deliveredCredential(consumeHarness.deliveries[0]!);
  consumeHarness.store.operationGate.arm("claimActiveLink");
  const delayedConsume = consumeHarness.service.consume({
    ...credential,
    clickingDeviceId: "device",
  });
  const consumeSettlement = observeSettlement(delayedConsume);
  await consumeHarness.store.operationGate.waitUntilReached();
  assert.equal(consumeSettlement.settled(), false);
  assert.equal(consumeHarness.issuedDevices.length, 0);
  consumeHarness.store.operationGate.release();
  assert.equal((await delayedConsume).status, "authenticated");

  const workerHarness = makeHarness();
  await requestLink(workerHarness);
  workerHarness.store.operationGate.arm("claimDeliveryAttempt");
  const delayedWorker = workerHarness.worker.runOnce(10);
  const workerSettlement = observeSettlement(delayedWorker);
  await workerHarness.store.operationGate.waitUntilReached();
  assert.equal(workerSettlement.settled(), false);
  assert.equal(workerHarness.deliveries.length, 0);
  workerHarness.store.operationGate.release();
  assert.deepEqual(await delayedWorker, { attempted: 1, delivered: 1 });

  const preSendHarness = makeHarness();
  await requestLink(preSendHarness);
  preSendHarness.store.operationGate.arm("validateDeliveryAttemptBeforeSend");
  const delayedPreSend = preSendHarness.worker.runOnce(10);
  const preSendSettlement = observeSettlement(delayedPreSend);
  await preSendHarness.store.operationGate.waitUntilReached();
  assert.equal(preSendSettlement.settled(), false);
  assert.equal(preSendHarness.deliveries.length, 0);
  assert.equal(preSendHarness.store.outbox[0]?.state, "leased");
  preSendHarness.store.operationGate.release();
  assert.deepEqual(await delayedPreSend, { attempted: 1, delivered: 1 });
});

test("wrong secret, purpose, and expiry reject without locking an otherwise valid link", async () => {
  const harness = makeHarness();
  await requestLink(harness);
  await flushDeliveries(harness);
  const credential = deliveredCredential(harness.deliveries[0]!);
  assert.deepEqual(await harness.service.consume({ ...credential, purpose: "reauthenticate", clickingDeviceId: "device" }), { status: "rejected" });
  assert.deepEqual(await harness.service.consume({ selector: credential.selector, secret: Buffer.alloc(32, 0xee).toString("base64url"), purpose: "sign-in", clickingDeviceId: "device" }), { status: "rejected" });
  assert.equal(harness.store.records[0]?.state, "active");
  harness.clock.advance(10 * 60_000);
  assert.deepEqual(await harness.service.consume({ ...credential, purpose: "sign-in", clickingDeviceId: "device" }), { status: "rejected" });
});

test("server-owned email link/unlink purpose returns a bound verified-auth receipt and never a normal session", async () => {
  const harness = makeHarness();
  assert.deepEqual(await harness.service.request({ email: "candidate@example.com", purpose: "link-identity", networkAddress: "203.0.113.1" }), { accepted: true, status: 202 });
  assert.equal(harness.store.records.length, 0);
  await assert.rejects(
    harness.service.requestCandidate({
      currentAccessToken: CURRENT_ACCESS_TOKEN,
      email: "candidate@example.com",
      purpose: "sign-in",
      networkAddress: "203.0.113.1",
    } as never),
    (error: unknown) => error instanceof MagicLinkError && error.code === "invalid_purpose",
  );
  await harness.service.requestCandidate({
    currentAccessToken: CURRENT_ACCESS_TOKEN,
    email: "candidate@example.com",
    purpose: "link-identity",
    networkAddress: "203.0.113.1",
  });
  await flushDeliveries(harness);
  const credential = deliveredCredential(harness.deliveries[0]!);
  const result = await harness.service.consume({ ...credential, purpose: "link-identity", clickingDeviceId: "device" });
  assert.equal(result.status, "verified-auth-receipt");
  assert.equal(harness.issuedDevices.length, 0);
  assert.equal(harness.store.verifiedAuthenticationReceipts.length, 1);
  assert.deepEqual({
    issuer: harness.store.verifiedAuthenticationReceipts[0]?.issuer,
    subject: harness.store.verifiedAuthenticationReceipts[0]?.subject,
    purpose: harness.store.verifiedAuthenticationReceipts[0]?.purpose,
    principalId: harness.store.verifiedAuthenticationReceipts[0]?.initiatingPrincipalId,
    familyId: harness.store.verifiedAuthenticationReceipts[0]?.initiatingFamilyId,
  }, {
    issuer: "email",
    subject: "candidate@example.com",
    purpose: "link-identity",
    principalId: "principal-a",
    familyId: "family-a",
  });
  assert.ok(result.status === "verified-auth-receipt");
  assert.equal(
    JSON.stringify(harness.store.verifiedAuthenticationReceipts).includes(
      result.verifiedAuthenticationReceiptToken,
    ),
    false,
  );
});

test("verified-email candidate proof links and unlinks end to end through the trusted current session", async () => {
  const clock = new ManualClock();
  const verifiedAuthenticationReceipts: VerifiedAuthenticationReceipt[] = [];
  const identityStore = new FlowIdentityStore(verifiedAuthenticationReceipts);
  seedFlowPrincipal(identityStore, clock.nowMs(), [
    { issuer: "email", subject: "owner@example.com" },
  ]);
  const trustedSession: TrustedRecentSession = {
    principalId: "principal-a",
    familyId: "family-a",
    authenticatedAtMs: clock.nowMs(),
  };
  const recentSessions: RecentSessionVerifier = {
    async verifyRecentSession(accessToken) {
      if (accessToken !== CURRENT_ACCESS_TOKEN) throw new Error("invalid access");
      return structuredClone(trustedSession);
    },
  };
  const candidateProofs = new CandidateIdentityProofService({
    clock,
    random: new SequenceRandom(),
    store: identityStore,
    recentSessions,
    receiptHmacKey: Buffer.alloc(32, 0x40),
    proofHmacKey: Buffer.alloc(32, 0x81),
    policy: DEFAULT_IDENTITY_LINK_POLICY,
  });
  const linking = new IdentityLinkingService({
    clock,
    random: new SequenceRandom(),
    store: identityStore,
    recentSessions,
    proofHmacKey: Buffer.alloc(32, 0x81),
    auditHmacKey: Buffer.alloc(32, 0x82),
    policy: DEFAULT_IDENTITY_LINK_POLICY,
  });
  const harness = makeHarness({ recentSessions, verifiedAuthenticationReceipts });
  await harness.service.requestCandidate({
    currentAccessToken: CURRENT_ACCESS_TOKEN,
    email: "new-method@example.com",
    purpose: "link-identity",
    networkAddress: "203.0.113.8",
  });
  await flushDeliveries(harness);
  const credential = deliveredCredential(harness.deliveries[0]!);
  const candidate = await harness.service.consume({
    ...credential,
    purpose: "link-identity",
    clickingDeviceId: "device",
  });
  assert.equal(candidate.status, "verified-auth-receipt");
  assert.ok(candidate.status === "verified-auth-receipt");
  const proof = await candidateProofs.mintFromVerifiedAuthentication({
    currentAccessToken: CURRENT_ACCESS_TOKEN,
    verifiedAuthenticationReceiptToken: candidate.verifiedAuthenticationReceiptToken,
    expectedIssuer: "email",
    expectedPurpose: "link-identity",
  });
  assert.deepEqual(
    await linking.link({
      currentAccessToken: CURRENT_ACCESS_TOKEN,
      candidateProofToken: proof.candidateProofToken,
      confirmed: true,
    }),
    { status: "linked", authenticationEpoch: 1 },
  );
  assert.equal((await identityStore.findIdentity("email", "new-method@example.com"))?.principalId, "principal-a");

  await harness.service.requestCandidate({
    currentAccessToken: CURRENT_ACCESS_TOKEN,
    email: "new-method@example.com",
    purpose: "unlink-identity",
    networkAddress: "203.0.113.8",
  });
  await flushDeliveries(harness);
  const unlinkCredential = deliveredCredential(harness.deliveries[1]!);
  const unlinkReceipt = await harness.service.consume({
    ...unlinkCredential,
    purpose: "unlink-identity",
    clickingDeviceId: "device",
  });
  assert.ok(unlinkReceipt.status === "verified-auth-receipt");
  const unlinkProof = await candidateProofs.mintFromVerifiedAuthentication({
    currentAccessToken: CURRENT_ACCESS_TOKEN,
    verifiedAuthenticationReceiptToken:
      unlinkReceipt.verifiedAuthenticationReceiptToken,
    expectedIssuer: "email",
    expectedPurpose: "unlink-identity",
  });
  assert.deepEqual(
    await linking.unlink({
      currentAccessToken: CURRENT_ACCESS_TOKEN,
      candidateProofToken: unlinkProof.candidateProofToken,
      confirmed: true,
    }),
    { status: "unlinked", authenticationEpoch: 2 },
  );
  assert.equal(await identityStore.findIdentity("email", "new-method@example.com"), undefined);
  assert.equal(identityStore.auditEvents.length, 2);
  assert.equal(identityStore.notificationOutbox.length, 2);
});
