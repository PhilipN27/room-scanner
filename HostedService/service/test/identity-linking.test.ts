import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { test } from "node:test";

import {
  CandidateIdentityProofService,
  CanonicalIdentityService,
  DEFAULT_IDENTITY_LINK_POLICY,
  IdentityLinkError,
  IdentityLinkingService,
  IdentityNotificationWorker,
  type CandidateIdentityProof,
  type CandidateProofClaim,
  type ExternalIdentityRecord,
  type IdentityAuditEvent,
  type IdentityNotificationDeliveryPort,
  type IdentityStore,
  type IdentityTransaction,
  type PrincipalRecord,
  type RecentSessionVerifier,
  type SecurityNotificationOutboxRecord,
  type TrustedRecentSession,
  type VerifiedAuthenticationReceipt,
  type VerifiedAuthenticationReceiptClaim,
} from "../identity-linking.js";
import {
  AsyncOperationGate,
  observeSettlement,
} from "./support/async-operation-gate.js";

class ManualClock {
  constructor(private current = Date.UTC(2026, 7, 18, 10, 0, 0)) {}

  nowMs(): number {
    return this.current;
  }

  advance(milliseconds: number): void {
    this.current += milliseconds;
  }
}

class SequenceRandom {
  readonly requestedLengths: number[] = [];
  private next = 1;

  bytes(length: number): Uint8Array {
    this.requestedLengths.push(length);
    const seed = this.next++;
    return Uint8Array.from({ length }, (_, index) => (seed * 23 + index) & 0xff);
  }
}

class MemoryIdentityStore implements IdentityStore, IdentityTransaction {
  readonly principals: PrincipalRecord[] = [];
  readonly identities: ExternalIdentityRecord[] = [];
  readonly proofs: CandidateIdentityProof[] = [];
  readonly verifiedAuthenticationReceipts: VerifiedAuthenticationReceipt[] = [];
  readonly revokedFamilies: Array<{ principalId: string; exceptFamilyId: string }> = [];
  readonly auditEvents: IdentityAuditEvent[] = [];
  readonly notificationOutbox: SecurityNotificationOutboxRecord[] = [];
  failNextAuditInsert = false;
  failNextOutboxInsert = false;
  loseNextCandidateClaim = false;
  loseNextReceiptClaim = false;
  stealNextNotificationLeaseBeforeCompletion = false;
  readonly operationGate = new AsyncOperationGate();
  private tail: Promise<void> = Promise.resolve();

  async transaction<T>(work: (transaction: IdentityTransaction) => Promise<T>): Promise<T> {
    const previous = this.tail;
    let release = (): void => undefined;
    this.tail = new Promise<void>((resolve) => {
      release = resolve;
    });
    await previous;
    const snapshot = {
      principals: structuredClone(this.principals),
      identities: structuredClone(this.identities),
      proofs: structuredClone(this.proofs),
      verifiedAuthenticationReceipts: structuredClone(this.verifiedAuthenticationReceipts),
      revokedFamilies: structuredClone(this.revokedFamilies),
      auditEvents: structuredClone(this.auditEvents),
      notificationOutbox: structuredClone(this.notificationOutbox),
    };
    try {
      return await work(this);
    } catch (error) {
      this.principals.splice(0, this.principals.length, ...snapshot.principals);
      this.identities.splice(0, this.identities.length, ...snapshot.identities);
      this.proofs.splice(0, this.proofs.length, ...snapshot.proofs);
      this.verifiedAuthenticationReceipts.splice(
        0,
        this.verifiedAuthenticationReceipts.length,
        ...snapshot.verifiedAuthenticationReceipts,
      );
      this.revokedFamilies.splice(
        0,
        this.revokedFamilies.length,
        ...snapshot.revokedFamilies,
      );
      this.auditEvents.splice(0, this.auditEvents.length, ...snapshot.auditEvents);
      this.notificationOutbox.splice(
        0,
        this.notificationOutbox.length,
        ...snapshot.notificationOutbox,
      );
      throw error;
    } finally {
      release();
    }
  }

  async findPrincipal(principalId: string): Promise<PrincipalRecord | undefined> {
    return this.principals.find((principal) => principal.id === principalId);
  }

  async insertPrincipal(principal: PrincipalRecord): Promise<void> {
    this.principals.push(structuredClone(principal));
  }

  async findIdentity(issuer: string, subject: string): Promise<ExternalIdentityRecord | undefined> {
    return this.identities.find(
      (identity) => identity.issuer === issuer && identity.subject === subject,
    );
  }

  async identitiesForPrincipal(principalId: string): Promise<ExternalIdentityRecord[]> {
    return this.identities.filter((identity) => identity.principalId === principalId);
  }

  async insertIdentity(identity: ExternalIdentityRecord): Promise<void> {
    if (await this.findIdentity(identity.issuer, identity.subject) !== undefined) {
      throw new Error("unique issuer/subject ownership violated");
    }
    this.identities.push(structuredClone(identity));
  }

  async removeIdentity(issuer: string, subject: string): Promise<void> {
    const index = this.identities.findIndex(
      (identity) => identity.issuer === issuer && identity.subject === subject,
    );
    if (index >= 0) {
      this.identities.splice(index, 1);
    }
  }

  async insertCandidateProof(proof: CandidateIdentityProof): Promise<void> {
    this.proofs.push(structuredClone(proof));
  }

  async insertVerifiedAuthenticationReceipt(
    receipt: VerifiedAuthenticationReceipt,
  ): Promise<void> {
    this.verifiedAuthenticationReceipts.push(structuredClone(receipt));
  }

  async claimVerifiedAuthenticationReceipt(
    claim: VerifiedAuthenticationReceiptClaim,
  ): Promise<VerifiedAuthenticationReceipt | undefined> {
    await this.operationGate.before("claimVerifiedAuthenticationReceipt");
    if (this.loseNextReceiptClaim) {
      this.loseNextReceiptClaim = false;
      return undefined;
    }
    const receipt = this.verifiedAuthenticationReceipts.find(
      (candidate) =>
        candidate.tokenHash === claim.tokenHash &&
        candidate.state === "active" &&
        candidate.issuer === claim.expectedIssuer &&
        candidate.purpose === claim.expectedPurpose &&
        candidate.initiatingPrincipalId === claim.initiatingPrincipalId &&
        candidate.initiatingFamilyId === claim.initiatingFamilyId &&
        candidate.expiresAtMs > claim.nowMs,
    );
    if (receipt === undefined) return undefined;
    receipt.state = "consumed";
    receipt.consumedAtMs = claim.nowMs;
    return structuredClone(receipt);
  }

  async claimCandidateProof(claim: CandidateProofClaim): Promise<CandidateIdentityProof | undefined> {
    await this.operationGate.before("claimCandidateProof");
    if (this.loseNextCandidateClaim) {
      this.loseNextCandidateClaim = false;
      return undefined;
    }
    const proof = this.proofs.find(
      (candidate) =>
        candidate.tokenHash === claim.tokenHash &&
        candidate.state === "active" &&
        candidate.purpose === claim.purpose &&
        candidate.initiatingPrincipalId === claim.initiatingPrincipalId &&
        candidate.initiatingFamilyId === claim.initiatingFamilyId &&
        candidate.expiresAtMs > claim.nowMs,
    );
    if (proof === undefined) {
      return undefined;
    }
    proof.state = "consumed";
    proof.consumedAtMs = claim.nowMs;
    return structuredClone(proof);
  }

  async bumpAuthenticationEpoch(principalId: string): Promise<number> {
    const principal = await this.findPrincipal(principalId);
    if (principal === undefined) {
      throw new Error("principal missing");
    }
    principal.authenticationEpoch += 1;
    return principal.authenticationEpoch;
  }

  async revokeOtherSessionFamilies(principalId: string, exceptFamilyId: string): Promise<void> {
    this.revokedFamilies.push({ principalId, exceptFamilyId });
  }

  async insertAuditEvent(event: IdentityAuditEvent): Promise<void> {
    if (this.failNextAuditInsert) {
      this.failNextAuditInsert = false;
      throw new Error("audit insert failed");
    }
    this.auditEvents.push(structuredClone(event));
  }

  async insertSecurityNotification(record: SecurityNotificationOutboxRecord): Promise<void> {
    await this.operationGate.before("insertSecurityNotification");
    if (this.failNextOutboxInsert) {
      this.failNextOutboxInsert = false;
      throw new Error("outbox insert failed");
    }
    this.notificationOutbox.push(structuredClone(record));
  }

  async availableSecurityNotifications(
    nowMs: number,
    limit: number,
  ): Promise<SecurityNotificationOutboxRecord[]> {
    return this.notificationOutbox
      .filter((record) =>
        record.state === "pending" ||
        (record.state === "leased" && (record.leaseExpiresAtMs ?? 0) <= nowMs),
      )
      .slice(0, limit)
      .map((record) => structuredClone(record));
  }

  async claimSecurityNotificationLease(
    id: string,
    leaseId: string,
    nowMs: number,
    leaseExpiresAtMs: number,
  ): Promise<SecurityNotificationOutboxRecord | undefined> {
    await this.operationGate.before("claimSecurityNotificationLease");
    const record = this.notificationOutbox.find(
      (candidate) =>
        candidate.id === id &&
        (candidate.state === "pending" ||
          (candidate.state === "leased" &&
            (candidate.leaseExpiresAtMs ?? 0) <= nowMs)),
    );
    if (record === undefined) return undefined;
    record.state = "leased";
    record.leaseId = leaseId;
    record.leaseExpiresAtMs = leaseExpiresAtMs;
    record.deliveryAttempts += 1;
    return structuredClone(record);
  }

  async completeSecurityNotificationLease(
    id: string,
    leaseId: string,
    deliveredAtMs: number,
  ): Promise<boolean> {
    const record = this.notificationOutbox.find(
      (candidate) => candidate.id === id && candidate.state === "leased",
    );
    if (record === undefined) return false;
    if (this.stealNextNotificationLeaseBeforeCompletion) {
      this.stealNextNotificationLeaseBeforeCompletion = false;
      record.leaseId = "lease-held-by-another-worker";
      return false;
    }
    if (record.leaseId !== leaseId) return false;
    record.state = "delivered";
    record.deliveredAtMs = deliveredAtMs;
    delete record.leaseId;
    delete record.leaseExpiresAtMs;
    return true;
  }

  async releaseSecurityNotificationLease(id: string, leaseId: string): Promise<boolean> {
    const record = this.notificationOutbox.find(
      (candidate) =>
        candidate.id === id &&
        candidate.state === "leased" &&
        candidate.leaseId === leaseId,
    );
    if (record === undefined) return false;
    record.state = "pending";
    delete record.leaseId;
    delete record.leaseExpiresAtMs;
    return true;
  }
}

interface Harness {
  readonly clock: ManualClock;
  readonly random: SequenceRandom;
  readonly store: MemoryIdentityStore;
  readonly sessions: Map<string, TrustedRecentSession>;
  readonly canonical: CanonicalIdentityService;
  readonly candidateProofs: CandidateIdentityProofService;
  readonly linking: IdentityLinkingService;
}

function makeHarness(): Harness {
  const clock = new ManualClock();
  const random = new SequenceRandom();
  const store = new MemoryIdentityStore();
  const sessions = new Map<string, TrustedRecentSession>();
  const recentSessions: RecentSessionVerifier = {
    async verifyRecentSession(accessToken) {
      const session = sessions.get(accessToken);
      if (session === undefined) {
        throw new Error("untrusted access token");
      }
      return structuredClone(session);
    },
  };
  return {
    clock,
    random,
    store,
    sessions,
    canonical: new CanonicalIdentityService({ clock, random, store }),
    candidateProofs: new CandidateIdentityProofService({
      clock,
      random,
      store,
      recentSessions,
      receiptHmacKey: Buffer.alloc(32, 0x50),
      proofHmacKey: Buffer.alloc(32, 0x51),
      policy: DEFAULT_IDENTITY_LINK_POLICY,
    }),
    linking: new IdentityLinkingService({
      clock,
      random,
      store,
      recentSessions,
      auditHmacKey: Buffer.alloc(32, 0x52),
      proofHmacKey: Buffer.alloc(32, 0x51),
      policy: DEFAULT_IDENTITY_LINK_POLICY,
    }),
  };
}

function seedPrincipal(
  harness: Harness,
  id: string,
  identities: Array<{ issuer: string; subject: string }>,
): void {
  harness.store.principals.push({
    id,
    authenticationEpoch: 0,
    createdAtMs: harness.clock.nowMs(),
  });
  harness.sessions.set(accessTokenFor(id), {
    principalId: id,
    familyId: `family-${id}`,
    authenticatedAtMs: harness.clock.nowMs(),
  });
  for (const identity of identities) {
    harness.store.identities.push({
      ...identity,
      principalId: id,
      linkedAtMs: harness.clock.nowMs(),
    });
  }
}

function accessTokenFor(principalId: string): string {
  return Buffer.alloc(32, principalId === "principal-a" ? 0xa1 : 0xb2).toString("base64url");
}

async function issueProof(
  harness: Harness,
  input: {
    issuer: string;
    subject: string;
    purpose: "link-identity" | "unlink-identity";
    principalId?: string;
  },
): Promise<string> {
  const principalId = input.principalId ?? "principal-a";
  const receiptToken = seedVerifiedReceipt(harness, input);
  const result = await harness.candidateProofs.mintFromVerifiedAuthentication({
    currentAccessToken: accessTokenFor(principalId),
    verifiedAuthenticationReceiptToken: receiptToken,
    expectedIssuer: input.issuer,
    expectedPurpose: input.purpose,
  });
  return result.candidateProofToken;
}

function seedVerifiedReceipt(
  harness: Harness,
  input: {
    issuer: string;
    subject: string;
    purpose: "link-identity" | "unlink-identity";
    principalId?: string;
    familyId?: string;
    authenticatedAtMs?: number;
    issuedAtMs?: number;
    expiresAtMs?: number;
  },
): string {
  const principalId = input.principalId ?? "principal-a";
  const receiptToken = Buffer.alloc(
    32,
    harness.store.verifiedAuthenticationReceipts.length + 0x71,
  ).toString("base64url");
  harness.store.verifiedAuthenticationReceipts.push({
    tokenHash: createHmac("sha256", Buffer.alloc(32, 0x50))
      .update(`verified-auth-receipt:${receiptToken}`)
      .digest("base64url"),
    issuer: input.issuer,
    subject: input.subject,
    purpose: input.purpose,
    authenticatedAtMs: input.authenticatedAtMs ?? harness.clock.nowMs(),
    initiatingPrincipalId: principalId,
    initiatingFamilyId: input.familyId ?? `family-${principalId}`,
    issuedAtMs: input.issuedAtMs ?? harness.clock.nowMs(),
    expiresAtMs: input.expiresAtMs ??
      harness.clock.nowMs() + DEFAULT_IDENTITY_LINK_POLICY.verifiedAuthReceiptTtlMs,
    policyVersion: DEFAULT_IDENTITY_LINK_POLICY.version,
    state: "active",
  });
  return receiptToken;
}

async function expectCode(promise: Promise<unknown>, code: string): Promise<void> {
  await assert.rejects(
    promise,
    (error: unknown) => error instanceof IdentityLinkError && error.code === code,
  );
}

test("canonical identity resolution creates stable app principals with unique issuer/subject ownership", async () => {
  const harness = makeHarness();
  const first = await harness.canonical.resolveOrCreate({ issuer: "https://appleid.apple.com", subject: "subject-1" });
  const second = await harness.canonical.resolveOrCreate({ issuer: "https://appleid.apple.com", subject: "subject-1" });
  assert.equal(first.principalId, second.principalId);
  assert.match(first.principalId, /^prn_[A-Za-z0-9_-]+$/u);
  assert.equal(harness.store.principals.length, 1);
  assert.equal(harness.store.identities.length, 1);
});

test("verified-auth receipts mint hash-only purpose/family-bound candidate proofs once", async () => {
  const harness = makeHarness();
  seedPrincipal(harness, "principal-a", [{ issuer: "email", subject: "owner@example.com" }]);
  const candidateProofToken = await issueProof(harness, {
    issuer: "https://appleid.apple.com",
    subject: "apple-subject",
    purpose: "link-identity",
  });
  assert.equal(Buffer.from(candidateProofToken, "base64url").length, 32);
  assert.equal(JSON.stringify(harness.store.proofs).includes(candidateProofToken), false);
  assert.deepEqual(
    {
      purpose: harness.store.proofs[0]?.purpose,
      principalId: harness.store.proofs[0]?.initiatingPrincipalId,
      familyId: harness.store.proofs[0]?.initiatingFamilyId,
      lifetime: (harness.store.proofs[0]?.expiresAtMs ?? 0) - (harness.store.proofs[0]?.issuedAtMs ?? 0),
    },
    { purpose: "link-identity", principalId: "principal-a", familyId: "family-principal-a", lifetime: 5 * 60_000 },
  );
  assert.equal(harness.store.verifiedAuthenticationReceipts[0]?.state, "consumed");
  assert.equal(
    "issueFromAuthenticatedIdentity" in harness.candidateProofs,
    false,
  );
});

test("verified-auth receipt theft, replay, expiry, issuer, purpose, family, lost claim, and raw fabrication fail closed", async () => {
  const harness = makeHarness();
  seedPrincipal(harness, "principal-a", [{ issuer: "email", subject: "a@example.com" }]);
  seedPrincipal(harness, "principal-b", [{ issuer: "email", subject: "b@example.com" }]);

  const stolen = seedVerifiedReceipt(harness, {
    issuer: "email",
    subject: "stolen@example.com",
    purpose: "link-identity",
  });
  await expectCode(
    harness.candidateProofs.mintFromVerifiedAuthentication({
      currentAccessToken: accessTokenFor("principal-b"),
      verifiedAuthenticationReceiptToken: stolen,
      expectedIssuer: "email",
      expectedPurpose: "link-identity",
    }),
    "candidate_proof_required",
  );

  const issuerMismatch = seedVerifiedReceipt(harness, {
    issuer: "email",
    subject: "issuer@example.com",
    purpose: "link-identity",
  });
  await expectCode(
    harness.candidateProofs.mintFromVerifiedAuthentication({
      currentAccessToken: accessTokenFor("principal-a"),
      verifiedAuthenticationReceiptToken: issuerMismatch,
      expectedIssuer: "https://appleid.apple.com",
      expectedPurpose: "link-identity",
    }),
    "candidate_proof_required",
  );

  const purposeMismatch = seedVerifiedReceipt(harness, {
    issuer: "email",
    subject: "purpose@example.com",
    purpose: "unlink-identity",
  });
  await expectCode(
    harness.candidateProofs.mintFromVerifiedAuthentication({
      currentAccessToken: accessTokenFor("principal-a"),
      verifiedAuthenticationReceiptToken: purposeMismatch,
      expectedIssuer: "email",
      expectedPurpose: "link-identity",
    }),
    "candidate_proof_required",
  );

  const familyMismatch = seedVerifiedReceipt(harness, {
    issuer: "email",
    subject: "family@example.com",
    purpose: "link-identity",
    familyId: "different-family",
  });
  await expectCode(
    harness.candidateProofs.mintFromVerifiedAuthentication({
      currentAccessToken: accessTokenFor("principal-a"),
      verifiedAuthenticationReceiptToken: familyMismatch,
      expectedIssuer: "email",
      expectedPurpose: "link-identity",
    }),
    "candidate_proof_required",
  );

  const expired = seedVerifiedReceipt(harness, {
    issuer: "email",
    subject: "expired@example.com",
    purpose: "link-identity",
    expiresAtMs: harness.clock.nowMs(),
  });
  await expectCode(
    harness.candidateProofs.mintFromVerifiedAuthentication({
      currentAccessToken: accessTokenFor("principal-a"),
      verifiedAuthenticationReceiptToken: expired,
      expectedIssuer: "email",
      expectedPurpose: "link-identity",
    }),
    "candidate_proof_required",
  );

  const replay = seedVerifiedReceipt(harness, {
    issuer: "email",
    subject: "replay@example.com",
    purpose: "link-identity",
  });
  const replayInput = {
    currentAccessToken: accessTokenFor("principal-a"),
    verifiedAuthenticationReceiptToken: replay,
    expectedIssuer: "email",
    expectedPurpose: "link-identity" as const,
  };
  await harness.candidateProofs.mintFromVerifiedAuthentication(replayInput);
  await expectCode(
    harness.candidateProofs.mintFromVerifiedAuthentication(replayInput),
    "candidate_proof_required",
  );

  const lost = seedVerifiedReceipt(harness, {
    issuer: "email",
    subject: "lost@example.com",
    purpose: "link-identity",
  });
  harness.store.loseNextReceiptClaim = true;
  await expectCode(
    harness.candidateProofs.mintFromVerifiedAuthentication({
      currentAccessToken: accessTokenFor("principal-a"),
      verifiedAuthenticationReceiptToken: lost,
      expectedIssuer: "email",
      expectedPurpose: "link-identity",
    }),
    "candidate_proof_required",
  );

  await expectCode(
    harness.candidateProofs.mintFromVerifiedAuthentication({
      currentAccessToken: accessTokenFor("principal-a"),
      verifiedAuthenticationReceiptToken: Buffer.alloc(32, 0xee).toString("base64url"),
      expectedIssuer: "email",
      expectedPurpose: "link-identity",
      issuer: "email",
      subject: "fabricated@example.com",
      initiatingPrincipalId: "principal-a",
      initiatingFamilyId: "family-principal-a",
      authenticatedAtMs: harness.clock.nowMs(),
    } as Parameters<CandidateIdentityProofService["mintFromVerifiedAuthentication"]>[0]),
    "candidate_proof_required",
  );
});

test("link trusts only the opaque current access token and atomically records mutation, epoch, audit, and outbox", async () => {
  const harness = makeHarness();
  seedPrincipal(harness, "principal-a", [{ issuer: "email", subject: "owner@example.com" }]);
  const proof = await issueProof(harness, {
    issuer: "https://appleid.apple.com",
    subject: "apple-subject",
    purpose: "link-identity",
  });
  const result = await harness.linking.link({
    currentAccessToken: accessTokenFor("principal-a"),
    candidateProofToken: proof,
    confirmed: true,
    principalId: "forged-principal",
    currentFamilyId: "forged-family",
    authenticatedAtMs: harness.clock.nowMs(),
  } as Parameters<IdentityLinkingService["link"]>[0]);
  assert.deepEqual(result, { authenticationEpoch: 1, status: "linked" });
  assert.equal((await harness.store.findIdentity("https://appleid.apple.com", "apple-subject"))?.principalId, "principal-a");
  assert.deepEqual(harness.store.revokedFamilies, [{ principalId: "principal-a", exceptFamilyId: "family-principal-a" }]);
  assert.equal(harness.store.auditEvents.length, 1);
  assert.equal(harness.store.auditEvents[0]?.eventCode, "identity.linked");
  assert.match(harness.store.auditEvents[0]?.identityReference ?? "", /^id_[A-Za-z0-9_-]+$/u);
  assert.equal(harness.store.notificationOutbox.length, 1);
  assert.equal(harness.store.notificationOutbox[0]?.state, "pending");
  assert.equal(JSON.stringify(harness.store).includes(proof), false);
});

test("candidate proof theft, replay, wrong purpose, stale proof, and a lost claim all fail closed", async () => {
  const harness = makeHarness();
  seedPrincipal(harness, "principal-a", [{ issuer: "email", subject: "a@example.com" }]);
  seedPrincipal(harness, "principal-b", [{ issuer: "email", subject: "b@example.com" }]);
  const stolen = await issueProof(harness, { issuer: "https://appleid.apple.com", subject: "candidate-stolen", purpose: "link-identity" });
  await expectCode(harness.linking.link({ currentAccessToken: accessTokenFor("principal-b"), candidateProofToken: stolen, confirmed: true }), "candidate_proof_required");
  const wrongPurpose = await issueProof(harness, { issuer: "https://appleid.apple.com", subject: "candidate-purpose", purpose: "unlink-identity" });
  await expectCode(harness.linking.link({ currentAccessToken: accessTokenFor("principal-a"), candidateProofToken: wrongPurpose, confirmed: true }), "candidate_proof_required");
  const stale = await issueProof(harness, { issuer: "https://appleid.apple.com", subject: "candidate-stale", purpose: "link-identity" });
  harness.clock.advance(5 * 60_000);
  await expectCode(harness.linking.link({ currentAccessToken: accessTokenFor("principal-a"), candidateProofToken: stale, confirmed: true }), "candidate_proof_required");
  harness.clock.advance(-(5 * 60_000));
  const replay = await issueProof(harness, { issuer: "https://appleid.apple.com", subject: "candidate-replay", purpose: "link-identity" });
  await harness.linking.link({ currentAccessToken: accessTokenFor("principal-a"), candidateProofToken: replay, confirmed: true });
  await expectCode(harness.linking.link({ currentAccessToken: accessTokenFor("principal-a"), candidateProofToken: replay, confirmed: true }), "candidate_proof_required");
  const lost = await issueProof(harness, { issuer: "https://appleid.apple.com", subject: "candidate-lost", purpose: "link-identity" });
  harness.store.loseNextCandidateClaim = true;
  await expectCode(harness.linking.link({ currentAccessToken: accessTokenFor("principal-a"), candidateProofToken: lost, confirmed: true }), "candidate_proof_required");
});

test("candidate mint and identity mutation await delayed receipt, proof, and outbox operations", async () => {
  const receiptHarness = makeHarness();
  seedPrincipal(receiptHarness, "principal-a", [
    { issuer: "email", subject: "owner@example.com" },
  ]);
  const receiptToken = seedVerifiedReceipt(receiptHarness, {
    issuer: "https://appleid.apple.com",
    subject: "delayed-receipt",
    purpose: "link-identity",
  });
  receiptHarness.store.operationGate.arm("claimVerifiedAuthenticationReceipt");
  const delayedMint = receiptHarness.candidateProofs.mintFromVerifiedAuthentication({
    currentAccessToken: accessTokenFor("principal-a"),
    verifiedAuthenticationReceiptToken: receiptToken,
    expectedIssuer: "https://appleid.apple.com",
    expectedPurpose: "link-identity",
  });
  const mintSettlement = observeSettlement(delayedMint);
  await receiptHarness.store.operationGate.waitUntilReached();
  assert.equal(mintSettlement.settled(), false);
  assert.equal(receiptHarness.store.proofs.length, 0);
  receiptHarness.store.operationGate.release();
  await delayedMint;

  const proofHarness = makeHarness();
  seedPrincipal(proofHarness, "principal-a", [
    { issuer: "email", subject: "owner@example.com" },
  ]);
  const candidateProofToken = await issueProof(proofHarness, {
    issuer: "https://appleid.apple.com",
    subject: "delayed-proof",
    purpose: "link-identity",
  });
  proofHarness.store.operationGate.arm("claimCandidateProof");
  const delayedLink = proofHarness.linking.link({
    currentAccessToken: accessTokenFor("principal-a"),
    candidateProofToken,
    confirmed: true,
  });
  const linkSettlement = observeSettlement(delayedLink);
  await proofHarness.store.operationGate.waitUntilReached();
  assert.equal(linkSettlement.settled(), false);
  assert.equal(
    await proofHarness.store.findIdentity("https://appleid.apple.com", "delayed-proof"),
    undefined,
  );
  proofHarness.store.operationGate.release();
  await delayedLink;

  const writeHarness = makeHarness();
  seedPrincipal(writeHarness, "principal-a", [
    { issuer: "email", subject: "owner@example.com" },
  ]);
  const writeProof = await issueProof(writeHarness, {
    issuer: "https://appleid.apple.com",
    subject: "delayed-outbox",
    purpose: "link-identity",
  });
  writeHarness.store.operationGate.arm("insertSecurityNotification");
  const delayedOutbox = writeHarness.linking.link({
    currentAccessToken: accessTokenFor("principal-a"),
    candidateProofToken: writeProof,
    confirmed: true,
  });
  const outboxSettlement = observeSettlement(delayedOutbox);
  await writeHarness.store.operationGate.waitUntilReached();
  assert.equal(outboxSettlement.settled(), false);
  assert.equal(writeHarness.store.notificationOutbox.length, 0);
  writeHarness.store.operationGate.release();
  await delayedOutbox;
});

test("two principals concurrently claiming the same candidate identity produce one owner", async () => {
  const harness = makeHarness();
  seedPrincipal(harness, "principal-a", [{ issuer: "email", subject: "a@example.com" }]);
  seedPrincipal(harness, "principal-b", [{ issuer: "email", subject: "b@example.com" }]);
  const proofA = await issueProof(harness, { issuer: "https://appleid.apple.com", subject: "single-owner", purpose: "link-identity" });
  const proofB = await issueProof(harness, { issuer: "https://appleid.apple.com", subject: "single-owner", purpose: "link-identity", principalId: "principal-b" });
  const results = await Promise.allSettled([
    harness.linking.link({ currentAccessToken: accessTokenFor("principal-a"), candidateProofToken: proofA, confirmed: true }),
    harness.linking.link({ currentAccessToken: accessTokenFor("principal-b"), candidateProofToken: proofB, confirmed: true }),
  ]);
  assert.equal(results.filter((result) => result.status === "fulfilled").length, 1);
  assert.equal(results.filter((result) => result.status === "rejected").length, 1);
  assert.equal(harness.store.identities.filter((identity) => identity.issuer === "https://appleid.apple.com" && identity.subject === "single-owner").length, 1);
});

test("unlink requires independent proof of the exact method and cannot remove the final method", async () => {
  const harness = makeHarness();
  seedPrincipal(harness, "principal-a", [
    { issuer: "email", subject: "a@example.com" },
    { issuer: "https://appleid.apple.com", subject: "apple-a" },
  ]);
  const proof = await issueProof(harness, { issuer: "https://appleid.apple.com", subject: "apple-a", purpose: "unlink-identity" });
  assert.deepEqual(
    await harness.linking.unlink({ currentAccessToken: accessTokenFor("principal-a"), candidateProofToken: proof, confirmed: true }),
    { authenticationEpoch: 1, status: "unlinked" },
  );
  assert.equal(await harness.store.findIdentity("https://appleid.apple.com", "apple-a"), undefined);
  const finalProof = await issueProof(harness, { issuer: "email", subject: "a@example.com", purpose: "unlink-identity" });
  await expectCode(harness.linking.unlink({ currentAccessToken: accessTokenFor("principal-a"), candidateProofToken: finalProof, confirmed: true }), "final_auth_method");
});

for (const failpoint of ["audit", "outbox"] as const) {
  test(`${failpoint} insertion failure rolls back the entire identity transaction`, async () => {
    const harness = makeHarness();
    seedPrincipal(harness, "principal-a", [{ issuer: "email", subject: "a@example.com" }]);
    const proof = await issueProof(harness, { issuer: "https://appleid.apple.com", subject: `rollback-${failpoint}`, purpose: "link-identity" });
    if (failpoint === "audit") harness.store.failNextAuditInsert = true;
    else harness.store.failNextOutboxInsert = true;
    await assert.rejects(
      harness.linking.link({ currentAccessToken: accessTokenFor("principal-a"), candidateProofToken: proof, confirmed: true }),
      /insert failed/u,
    );
    assert.equal(await harness.store.findIdentity("https://appleid.apple.com", `rollback-${failpoint}`), undefined);
    assert.equal(harness.store.principals[0]?.authenticationEpoch, 0);
    assert.equal(harness.store.proofs[0]?.state, "active");
    assert.equal(harness.store.revokedFamilies.length, 0);
    assert.equal(harness.store.auditEvents.length, 0);
    assert.equal(harness.store.notificationOutbox.length, 0);
  });
}

test("security notification delivery is at-least-once with a stable provider idempotency key", async () => {
  const harness = makeHarness();
  seedPrincipal(harness, "principal-a", [{ issuer: "email", subject: "a@example.com" }]);
  const proof = await issueProof(harness, { issuer: "https://appleid.apple.com", subject: "notify-retry", purpose: "link-identity" });
  await harness.linking.link({ currentAccessToken: accessTokenFor("principal-a"), candidateProofToken: proof, confirmed: true });
  const deliveryCalls: string[] = [];
  let crashAfterFirstDelivery = true;
  const delivery: IdentityNotificationDeliveryPort = {
    async deliver(message) {
      deliveryCalls.push(message.idempotencyKey);
      if (crashAfterFirstDelivery) {
        crashAfterFirstDelivery = false;
        throw new Error("worker crashed after provider accepted message");
      }
    },
  };
  const worker = new IdentityNotificationWorker({
    clock: harness.clock,
    random: new SequenceRandom(),
    store: harness.store,
    delivery,
    policy: DEFAULT_IDENTITY_LINK_POLICY,
  });
  assert.deepEqual(await worker.runOnce(10), { attempted: 1, delivered: 0 });
  assert.equal(harness.store.notificationOutbox[0]?.state, "pending");
  assert.deepEqual(await worker.runOnce(10), { attempted: 1, delivered: 1 });
  assert.equal(deliveryCalls.length, 2);
  assert.equal(deliveryCalls[0], deliveryCalls[1]);
  assert.equal(harness.store.notificationOutbox[0]?.state, "delivered");
  assert.equal(harness.store.notificationOutbox[0]?.deliveryAttempts, 2);
});

test("notification leases elect one concurrent worker and delayed lease CAS blocks delivery", async () => {
  const harness = makeHarness();
  seedPrincipal(harness, "principal-a", [{ issuer: "email", subject: "a@example.com" }]);
  const proof = await issueProof(harness, {
    issuer: "https://appleid.apple.com",
    subject: "notify-concurrent",
    purpose: "link-identity",
  });
  await harness.linking.link({
    currentAccessToken: accessTokenFor("principal-a"),
    candidateProofToken: proof,
    confirmed: true,
  });

  let signalEntered = (): void => undefined;
  const entered = new Promise<void>((resolve) => { signalEntered = resolve; });
  let signalRelease = (): void => undefined;
  const release = new Promise<void>((resolve) => { signalRelease = resolve; });
  const deliveryCalls: string[] = [];
  const delivery: IdentityNotificationDeliveryPort = {
    async deliver(message) {
      deliveryCalls.push(message.idempotencyKey);
      signalEntered();
      await release;
    },
  };
  const sharedRandom = new SequenceRandom();
  const first = new IdentityNotificationWorker({
    clock: harness.clock,
    random: sharedRandom,
    store: harness.store,
    delivery,
    policy: DEFAULT_IDENTITY_LINK_POLICY,
  });
  const second = new IdentityNotificationWorker({
    clock: harness.clock,
    random: sharedRandom,
    store: harness.store,
    delivery,
    policy: DEFAULT_IDENTITY_LINK_POLICY,
  });

  harness.store.operationGate.arm("claimSecurityNotificationLease");
  const delayed = first.runOnce(10);
  const delayedSettlement = observeSettlement(delayed);
  await harness.store.operationGate.waitUntilReached();
  assert.equal(delayedSettlement.settled(), false);
  assert.equal(deliveryCalls.length, 0);
  harness.store.operationGate.release();
  await entered;
  assert.deepEqual(await second.runOnce(10), { attempted: 0, delivered: 0 });
  assert.equal(deliveryCalls.length, 1);
  signalRelease();
  assert.deepEqual(await delayed, { attempted: 1, delivered: 1 });
});

test("a lost notification lease cannot complete and retries after expiry with the same idempotency key", async () => {
  const harness = makeHarness();
  seedPrincipal(harness, "principal-a", [{ issuer: "email", subject: "a@example.com" }]);
  const proof = await issueProof(harness, {
    issuer: "https://appleid.apple.com",
    subject: "notify-lost-lease",
    purpose: "link-identity",
  });
  await harness.linking.link({
    currentAccessToken: accessTokenFor("principal-a"),
    candidateProofToken: proof,
    confirmed: true,
  });
  const deliveryCalls: string[] = [];
  const delivery: IdentityNotificationDeliveryPort = {
    async deliver(message) { deliveryCalls.push(message.idempotencyKey); },
  };
  const worker = new IdentityNotificationWorker({
    clock: harness.clock,
    random: new SequenceRandom(),
    store: harness.store,
    delivery,
    policy: DEFAULT_IDENTITY_LINK_POLICY,
  });
  harness.store.stealNextNotificationLeaseBeforeCompletion = true;
  assert.deepEqual(await worker.runOnce(10), { attempted: 1, delivered: 0 });
  assert.equal(harness.store.notificationOutbox[0]?.state, "leased");
  harness.clock.advance(DEFAULT_IDENTITY_LINK_POLICY.notificationLeaseMs);
  assert.deepEqual(await worker.runOnce(10), { attempted: 1, delivered: 1 });
  assert.equal(deliveryCalls.length, 2);
  assert.equal(deliveryCalls[0], deliveryCalls[1]);
  assert.equal(harness.store.notificationOutbox[0]?.state, "delivered");
});

test("missing confirmation or an unverifiable/stale current token cannot mutate identity", async () => {
  const harness = makeHarness();
  seedPrincipal(harness, "principal-a", [{ issuer: "email", subject: "a@example.com" }]);
  const proof = await issueProof(harness, { issuer: "https://appleid.apple.com", subject: "blocked", purpose: "link-identity" });
  await expectCode(harness.linking.link({ currentAccessToken: accessTokenFor("principal-a"), candidateProofToken: proof, confirmed: false }), "confirmation_required");
  await expectCode(harness.linking.link({ currentAccessToken: "forged-access", candidateProofToken: proof, confirmed: true }), "recent_auth_required");
  harness.sessions.set(accessTokenFor("principal-a"), {
    principalId: "principal-a",
    familyId: "family-principal-a",
    authenticatedAtMs: harness.clock.nowMs() - (5 * 60_000 + 1),
  });
  await expectCode(harness.linking.link({ currentAccessToken: accessTokenFor("principal-a"), candidateProofToken: proof, confirmed: true }), "recent_auth_required");
  assert.equal(harness.store.identities.length, 1);
});

test("link and unlink require the literal runtime boolean true confirmation", async (context) => {
  for (const operation of ["link", "unlink"] as const) {
    for (const rawConfirmation of ["true", 1, null] as const) {
      await context.test(`${operation} rejects ${JSON.stringify(rawConfirmation)}`, async () => {
        const harness = makeHarness();
        seedPrincipal(
          harness,
          "principal-a",
          operation === "link"
            ? [{ issuer: "email", subject: "a@example.com" }]
            : [
                { issuer: "email", subject: "a@example.com" },
                { issuer: "https://appleid.apple.com", subject: "candidate" },
              ],
        );
        const proof = await issueProof(harness, {
          issuer: "https://appleid.apple.com",
          subject: "candidate",
          purpose: operation === "link" ? "link-identity" : "unlink-identity",
        });

        await expectCode(
          harness.linking[operation]({
            currentAccessToken: accessTokenFor("principal-a"),
            candidateProofToken: proof,
            confirmed: rawConfirmation as unknown as boolean,
          }),
          "confirmation_required",
        );
        assert.equal(
          harness.store.identities.some((identity) => identity.subject === "candidate"),
          operation === "unlink",
        );
      });
    }
  }
});
