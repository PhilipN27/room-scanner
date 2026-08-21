import { createDecipheriv, createHash, createHmac } from "node:crypto";

import type { DataApiClient } from "../adapters/data-api.js";
import type { AppleBridgeSessionIssuancePort } from "../adapters/cognito-custom-auth.js";
import type {
  BillingCompletionResult,
  BillingRepository,
  BillingTransaction,
  ReconciliationClaim,
  SubscriptionState,
  VerifiedWebhookAcceptance,
} from "../billing/stripe-billing.js";
import type { HostedMutationGrant } from "../operations/operational-flags.js";
import { DataApiAppleChallengeRepository } from "./auth-composites.js";
import {
  DataApiCapabilityTransactionRunner,
} from "./transaction-runner.js";
import {
  DataApiProviderAuditAcceptanceRepository,
  DataApiProviderAuditExportCapabilityRepository,
  DataApiStripeIngressCapabilityRepository,
  DataApiStripeReconciliationCapabilityRepository,
  type ProviderAuditEventLease,
  type StripeReconciliationClaim,
} from "./policy-composites.js";
import {
  DataApiMagicDeliveryCapabilityRepository,
  type MagicDeliveryLease,
} from "./email-delivery.js";

/** The only error exposed by role-specific adapters. It intentionally contains
 * no SQL, provider response, raw proof, workspace, or token material. */
export class RuntimeRepositoryError extends Error {
  constructor(readonly code: "invalid_input" | "unavailable") {
    super(code);
    this.name = "RuntimeRepositoryError";
  }
}

/**
 * Stripe ingress can persist only the verified durable receipt. The legacy
 * Task-5 `BillingRepository` shape is broader than this role's database ACL;
 * unsupported inherited methods reject before executing any SQL. This lets the
 * unmodified authoritative `StripeWebhookHandler` use the narrowed runtime
 * safely while making accidental cross-lane use visible.
 */
export class DataApiStripeIngressBillingRepository implements BillingRepository {
  readonly #transactions: DataApiCapabilityTransactionRunner<StripeIngressCapabilityBundle>;

  constructor(client: DataApiClient) {
    this.#transactions = new DataApiCapabilityTransactionRunner(
      client,
      (unit) => Object.freeze({
        ingress: new DataApiStripeIngressCapabilityRepository(unit),
        audits: new DataApiProviderAuditAcceptanceRepository(unit),
      }),
    );
  }

  async transaction<T>(work: (transaction: BillingTransaction) => Promise<T>): Promise<T> {
    if (typeof work !== "function") throw new RuntimeRepositoryError("invalid_input");
    return this.#transactions.run(async (repositories) => work(new StripeIngressBillingTransaction(repositories.ingress, repositories.audits)));
  }

  async acceptVerifiedWebhook(input: VerifiedWebhookAcceptance): Promise<{ readonly status: "accepted" | "duplicate"; readonly workspaceId: string; readonly generation: number }> {
    return this.transaction((transaction) => transaction.acceptVerifiedWebhook(input));
  }
  async claimReconciliation(_leaseId: string, _nowMs: number, _leaseExpiresAtMs: number): Promise<ReconciliationClaim | undefined> { return unsupported(); }
  async completeReconciliation(_input: Parameters<BillingTransaction["completeReconciliation"]>[0]): Promise<BillingCompletionResult> { return unsupported(); }
  async releaseReconciliation(_claim: ReconciliationClaim, _releasedAtMs: number): Promise<boolean> { return unsupported(); }
  async currentSubscription(_workspaceId: string): Promise<SubscriptionState | undefined> { return unsupported(); }
}

interface StripeIngressCapabilityBundle {
  readonly ingress: DataApiStripeIngressCapabilityRepository;
  readonly audits: DataApiProviderAuditAcceptanceRepository;
}

class StripeIngressBillingTransaction implements BillingTransaction {
  constructor(
    private readonly repository: DataApiStripeIngressCapabilityRepository,
    private readonly audits: DataApiProviderAuditAcceptanceRepository,
  ) {}
  async acceptVerifiedWebhook(input: VerifiedWebhookAcceptance): Promise<{ readonly status: "accepted" | "duplicate"; readonly workspaceId: string; readonly generation: number }> {
    const accepted = await this.repository.acceptVerifiedWebhook(input);
    // The Stripe ingress role has only these two capability functions. Keep
    // the receipt and bounded audit fact in the same Data API transaction so
    // a 200 can never represent a receipt without its durable audit evidence.
    await this.audits.accept(stripeIngressAudit(input, accepted.status));
    return accepted;
  }
  claimReconciliation(_leaseId: string, _nowMs: number, _leaseExpiresAtMs: number): Promise<ReconciliationClaim | undefined> { return unsupported(); }
  completeReconciliation(_input: Parameters<BillingTransaction["completeReconciliation"]>[0]): Promise<BillingCompletionResult> { return unsupported(); }
  releaseReconciliation(_claim: ReconciliationClaim, _releasedAtMs: number): Promise<boolean> { return unsupported(); }
  currentSubscription(_workspaceId: string): Promise<SubscriptionState | undefined> { return unsupported(); }
}

/** Stripe reconciliation gets only lease claim/complete/release. It cannot
 * ingest a webhook or look up a tenant subscription through API access. */
export class DataApiStripeReconciliationBillingRepository implements BillingRepository {
  readonly #transactions: DataApiCapabilityTransactionRunner<DataApiStripeReconciliationCapabilityRepository>;
  /** A claim is authority only for the short reconciliation turn that owns its
   * lease. This transient map is deliberately removed on every terminal
   * attempt; it is never a cache of tenant policy. */
  readonly #claimAuthorityByLease = new Map<string, StripeReconciliationClaim>();
  readonly #claimLeaseByWorkspace = new Map<string, string>();

  constructor(client: DataApiClient) {
    this.#transactions = new DataApiCapabilityTransactionRunner(
      client,
      (unit) => new DataApiStripeReconciliationCapabilityRepository(unit),
    );
  }

  async transaction<T>(work: (transaction: BillingTransaction) => Promise<T>): Promise<T> {
    if (typeof work !== "function") throw new RuntimeRepositoryError("invalid_input");
    return this.#transactions.run(async (repository) => work(new StripeReconciliationBillingTransaction(repository, this)));
  }

  async acceptVerifiedWebhook(_input: VerifiedWebhookAcceptance): Promise<{ readonly status: "accepted" | "duplicate"; readonly workspaceId: string; readonly generation: number }> { return unsupported(); }
  async claimReconciliation(leaseId: string, nowMs: number, leaseExpiresAtMs: number): Promise<ReconciliationClaim | undefined> { return this.transaction((transaction) => transaction.claimReconciliation(leaseId, nowMs, leaseExpiresAtMs)); }
  async completeReconciliation(input: Parameters<BillingTransaction["completeReconciliation"]>[0]): Promise<BillingCompletionResult> { return this.transaction((transaction) => transaction.completeReconciliation(input)); }
  async releaseReconciliation(claim: ReconciliationClaim, releasedAtMs: number): Promise<boolean> { return this.transaction((transaction) => transaction.releaseReconciliation(claim, releasedAtMs)); }
  async currentSubscription(_workspaceId: string): Promise<SubscriptionState | undefined> { return unsupported(); }

  /** Service-only bridge for the unmodified Task-5 reconciler. The versions
   * are captured by claim_stripe_reconciliation_v2 under literal-true flags;
   * infrastructure cannot provide or substitute them. */
  hostedGrantForClaimedWorkspace(workspaceId: string): HostedMutationGrant | undefined {
    if (!uuid(workspaceId)) return undefined;
    const leaseId = this.#claimLeaseByWorkspace.get(workspaceId);
    const claim = leaseId === undefined ? undefined : this.#claimAuthorityByLease.get(leaseId);
    if (claim === undefined || claim.workspaceInternalId !== workspaceId) return undefined;
    return Object.freeze({
      kind: "hosted-mutation-grant-v2",
      workspaceId,
      action: "system.stripe.reconcile",
      hostedGlobalFlagVersion: claim.hostedGlobalVersion,
      hostedWorkspaceFlagVersion: claim.hostedWorkspaceVersion,
    });
  }

  rememberClaimAuthority(claim: StripeReconciliationClaim): void {
    const previousLease = this.#claimLeaseByWorkspace.get(claim.workspaceInternalId);
    if (previousLease !== undefined && previousLease !== claim.leaseId) this.#claimAuthorityByLease.delete(previousLease);
    this.#claimAuthorityByLease.set(claim.leaseId, claim);
    this.#claimLeaseByWorkspace.set(claim.workspaceInternalId, claim.leaseId);
  }

  claimAuthority(claim: ReconciliationClaim): StripeReconciliationClaim | undefined {
    const authority = this.#claimAuthorityByLease.get(claim.leaseId);
    return authority !== undefined && authority.workspaceInternalId === claim.workspaceId
      && authority.accountMode === claim.accountMode && authority.accountId === claim.accountId
      && authority.customerId === claim.customerId && authority.subscriptionId === claim.subscriptionId
      && authority.generation === claim.generation ? authority : undefined;
  }

  forgetClaimAuthority(claim: ReconciliationClaim): void {
    const authority = this.#claimAuthorityByLease.get(claim.leaseId);
    if (authority !== undefined && authority.workspaceInternalId === claim.workspaceId) {
      this.#claimAuthorityByLease.delete(claim.leaseId);
      if (this.#claimLeaseByWorkspace.get(claim.workspaceId) === claim.leaseId) this.#claimLeaseByWorkspace.delete(claim.workspaceId);
    }
  }
}

class StripeReconciliationBillingTransaction implements BillingTransaction {
  constructor(
    private readonly repository: DataApiStripeReconciliationCapabilityRepository,
    private readonly owner: DataApiStripeReconciliationBillingRepository,
  ) {}
  acceptVerifiedWebhook(_input: VerifiedWebhookAcceptance): Promise<{ readonly status: "accepted" | "duplicate"; readonly workspaceId: string; readonly generation: number }> { return unsupported(); }
  async claimReconciliation(leaseId: string, nowMs: number, leaseExpiresAtMs: number): Promise<ReconciliationClaim | undefined> {
    const claim = await this.repository.claimReconciliation(leaseId, nowMs, leaseExpiresAtMs);
    if (claim === undefined) return undefined;
    this.owner.rememberClaimAuthority(claim);
    return billingClaim(claim);
  }
  async completeReconciliation(input: Parameters<BillingTransaction["completeReconciliation"]>[0]): Promise<BillingCompletionResult> {
    if (!validBillingClaim(input.claim) || !validHostedReconciliationGrant(input.hostedGrant)) throw new RuntimeRepositoryError("invalid_input");
    const claim = this.owner.claimAuthority(input.claim);
    if (claim === undefined) throw new RuntimeRepositoryError("invalid_input");
    try {
      return await this.repository.completeReconciliation({
        claim,
        snapshot: input.snapshot,
        appliedAtMs: input.appliedAtMs,
      });
    } finally {
      // Completion is terminal (applied, stale, or hosted gate rejected), and
      // no warm runtime should retain a past tenant grant.
      this.owner.forgetClaimAuthority(input.claim);
    }
  }
  async releaseReconciliation(claim: ReconciliationClaim, releasedAtMs: number): Promise<boolean> {
    if (!validBillingClaim(claim)) throw new RuntimeRepositoryError("invalid_input");
    const authority = this.owner.claimAuthority(claim);
    if (authority === undefined) throw new RuntimeRepositoryError("invalid_input");
    try {
      return await this.repository.releaseReconciliation(authority, releasedAtMs);
    } finally {
      this.owner.forgetClaimAuthority(claim);
    }
  }
  currentSubscription(_workspaceId: string): Promise<SubscriptionState | undefined> { return unsupported(); }
}

export interface ProviderAuditDeliveryPort {
  /** Delivers only bounded audit facts; implementations must not receive
   * arbitrary request/provider payloads, room bytes, tokens, or addresses. */
  deliver(event: Readonly<{
    readonly id: string;
    readonly lane: "apple" | "email" | "stripe";
    readonly eventCode: string;
    readonly boundedReference: string;
    readonly occurredAtMs: number;
    readonly deliveryAttempts: number;
  }>): Promise<void>;
}

/** Role-bound audit worker. It claims and commits, calls the provider after the
 * transaction closes, then atomically completes or releases the same lease. */
export class DataApiProviderAuditExportWorker {
  readonly #transactions: DataApiCapabilityTransactionRunner<DataApiProviderAuditExportCapabilityRepository>;
  readonly #clock: { nowMs(): number };
  readonly #random: { bytes(length: number): Uint8Array };
  readonly #delivery: ProviderAuditDeliveryPort;
  readonly #leaseMs: number;

  constructor(input: {
    readonly client: DataApiClient;
    readonly clock: { nowMs(): number };
    readonly random: { bytes(length: number): Uint8Array };
    readonly delivery: ProviderAuditDeliveryPort;
    readonly leaseMs: number;
  }) {
    if (input === null || typeof input !== "object" || input.client === null || typeof input.client !== "object"
      || input.clock === null || typeof input.clock.nowMs !== "function" || input.random === null || typeof input.random.bytes !== "function"
      || input.delivery === null || typeof input.delivery.deliver !== "function" || !Number.isSafeInteger(input.leaseMs) || input.leaseMs <= 0) {
      throw new RuntimeRepositoryError("invalid_input");
    }
    this.#transactions = new DataApiCapabilityTransactionRunner(
      input.client,
      (unit) => new DataApiProviderAuditExportCapabilityRepository(unit),
    );
    this.#clock = input.clock;
    this.#random = input.random;
    this.#delivery = input.delivery;
    this.#leaseMs = input.leaseMs;
  }

  async handleRecord(record: { readonly messageId: string }): Promise<boolean> {
    if (!validMessageId(record?.messageId)) return false;
    const claimedAt = this.#now();
    const leaseId = leaseIdFrom(this.#random.bytes(16));
    if (leaseId === undefined) return false;
    let lease: ProviderAuditEventLease | undefined;
    try {
      lease = await this.#transactions.run((repository) => repository.claim(leaseId, claimedAt, claimedAt + this.#leaseMs));
    } catch {
      return false;
    }
    if (lease === undefined) return true;
    try {
      await this.#delivery.deliver(Object.freeze({
        id: lease.id, lane: lease.lane, eventCode: lease.eventCode, boundedReference: lease.boundedReference,
        occurredAtMs: lease.occurredAtMs, deliveryAttempts: lease.deliveryAttempts,
      }));
    } catch {
      await this.#release(lease, this.#now());
      return false;
    }
    try {
      return await this.#transactions.run((repository) => repository.complete({ id: lease!.id, leaseId: lease!.leaseId, deliveredAtMs: this.#now() }));
    } catch {
      return false;
    }
  }

  async #release(lease: ProviderAuditEventLease, releasedAtMs: number): Promise<void> {
    try {
      await this.#transactions.run((repository) => repository.release({ id: lease.id, leaseId: lease.leaseId, releasedAtMs }));
    } catch { /* retry through the queue; a lease expiry can recover it */ }
  }

  #now(): number {
    const now = this.#clock.nowMs();
    if (!Number.isSafeInteger(now)) throw new RuntimeRepositoryError("unavailable");
    return now;
  }
}

export interface MagicDeliveryKeyringPort {
  /** Returns only the matching retained AES-256-GCM key. Unknown keys are a
   * terminal sealed-envelope condition, never a reason to ask the API lane
   * for raw secret material. */
  resolve(keyId: string): Promise<Uint8Array | undefined>;
}

export interface MagicDeliveryProviderPort {
  /** The provider sees the destination and one scanner-safe URL only. It is
   * never handed an access/session token, raw DB envelope, or arbitrary body.
   * `outboxId` is immutable app audit/correlation data—not a provider
   * idempotency assertion. SES may deliver the same single-use link more than
   * once after a post-send/pre-complete crash; the link itself remains
   * atomically single-use. */
  send(input: Readonly<{
    readonly destination: string;
    readonly magicLinkUrl: string;
    readonly outboxId: string;
    readonly purpose: "sign-in" | "reauthenticate" | "link-identity" | "unlink-identity";
  }>): Promise<void>;
}

/**
 * Email-runtime-only durable outbox worker. Queue records are merely wakes:
 * all target selection happens in `claim_next_magic_delivery`, so a lost wake
 * is recovered by a periodic tick and a caller cannot select another tenant's
 * delivery row. Provider calls are deliberately outside every DB transaction.
 */
export class DataApiMagicDeliveryWorker {
  readonly #transactions: DataApiCapabilityTransactionRunner<DataApiMagicDeliveryCapabilityRepository>;
  /** Same email-runtime role, but a separate bounded capability transaction:
   * the delivery outbox never gains generic audit SQL and audit export never
   * gains recipient/envelope access. */
  readonly #audits: DataApiCapabilityTransactionRunner<DataApiProviderAuditAcceptanceRepository>;
  readonly #clock: { nowMs(): number };
  readonly #random: { bytes(length: number): Uint8Array };
  readonly #decryptionKeys: MagicDeliveryKeyringPort;
  readonly #delivery: MagicDeliveryProviderPort;
  readonly #publicBaseUrl: URL;
  readonly #leaseMs: number;

  constructor(input: {
    readonly client: DataApiClient;
    readonly clock: { nowMs(): number };
    readonly random: { bytes(length: number): Uint8Array };
    readonly decryptionKeys: MagicDeliveryKeyringPort;
    readonly delivery: MagicDeliveryProviderPort;
    readonly publicBaseUrl: string;
    readonly leaseMs: number;
  }) {
    const base = parsePublicBaseUrl(input?.publicBaseUrl);
    if (input === null || typeof input !== "object" || input.client === null || typeof input.client !== "object"
      || input.clock === null || typeof input.clock.nowMs !== "function" || input.random === null || typeof input.random.bytes !== "function"
      || input.decryptionKeys === null || typeof input.decryptionKeys.resolve !== "function"
      || input.delivery === null || typeof input.delivery.send !== "function" || base === undefined
      || !Number.isSafeInteger(input.leaseMs) || input.leaseMs < 1_000 || input.leaseMs > 15 * 60_000) {
      throw new RuntimeRepositoryError("invalid_input");
    }
    this.#transactions = new DataApiCapabilityTransactionRunner(input.client, (unit) => new DataApiMagicDeliveryCapabilityRepository(unit));
    this.#audits = new DataApiCapabilityTransactionRunner(input.client, (unit) => new DataApiProviderAuditAcceptanceRepository(unit));
    this.#clock = input.clock;
    this.#random = input.random;
    this.#decryptionKeys = input.decryptionKeys;
    this.#delivery = input.delivery;
    this.#publicBaseUrl = base;
    this.#leaseMs = input.leaseMs;
  }

  async handleRecord(record: { readonly messageId: string }): Promise<boolean> {
    if (!validMessageId(record?.messageId)) return false;
    const claimedAt = this.#now();
    const leaseId = leaseIdFrom(this.#random.bytes(16));
    if (leaseId === undefined) return false;
    let claim: Awaited<ReturnType<DataApiMagicDeliveryCapabilityRepository["claimNext"]>>;
    try {
      claim = await this.#transactions.run((repository) => repository.claimNext({
        leaseId,
        claimedAtMs: claimedAt,
        leaseExpiresAtMs: boundedAdd(claimedAt, this.#leaseMs),
      }));
    } catch {
      return false;
    }
    if (claim === undefined || expiredMagicClaim(claim)) return true;
    const lease = claim;

    let key: Uint8Array | undefined;
    try {
      key = await this.#decryptionKeys.resolve(lease.keyId);
    } catch {
      if (!await this.#audit(lease, "email.delivery.failed", this.#now())) return false;
      await this.#release(lease, this.#now());
      return false;
    }
    if (!(key instanceof Uint8Array) || key.length !== 32) {
      if (!await this.#audit(lease, "email.delivery.failed", this.#now())) return false;
      await this.#cancel(lease, "unknown_key", this.#now());
      return true;
    }

    // Revalidate after asynchronous key lookup, then again immediately before
    // delivery. This prevents a stale lease or expiry race from decrypting or
    // sending a link after the database has withdrawn it.
    const first = await this.#validate(lease, this.#now());
    if (first === undefined || expiredMagicClaim(first)) return true;
    let secret: Uint8Array;
    try {
      secret = decryptMagicSecret(key, first);
    } catch {
      if (!await this.#audit(first, "email.delivery.failed", this.#now())) return false;
      await this.#cancel(first, "tampered_envelope", this.#now());
      return true;
    }
    const beforeSend = await this.#validate(first, this.#now());
    if (beforeSend === undefined || expiredMagicClaim(beforeSend)) return true;
    let magicLinkUrl: string;
    try {
      magicLinkUrl = magicLinkUrlFor(this.#publicBaseUrl, beforeSend.selector, secret, beforeSend.purpose);
    } catch {
      if (!await this.#audit(beforeSend, "email.delivery.failed", this.#now())) return false;
      await this.#cancel(beforeSend, "tampered_envelope", this.#now());
      return true;
    }
    try {
      await this.#delivery.send(Object.freeze({
        destination: beforeSend.deliveryIdentity,
        magicLinkUrl,
        outboxId: beforeSend.id,
        purpose: beforeSend.purpose,
      }));
    } catch {
      if (!await this.#audit(beforeSend, "email.delivery.failed", this.#now())) return false;
      await this.#release(beforeSend, this.#now());
      return false;
    }
    // SES does not offer a provider idempotency key. Record the bounded,
    // immutable outbox correlation fact after the provider accepts the send
    // and before final completion; if audit persistence fails we retain the
    // lease for recovery rather than falsely claiming a fully closed turn.
    if (!await this.#audit(beforeSend, "email.delivery.accepted", this.#now())) return false;
    try {
      // A post-send completion loss can yield a duplicate email on retry. The
      // immutable outbox ID is correlation only; no SES exactly-once claim is
      // made. The stored magic selector/secret remains atomically single-use.
      return await this.#transactions.run((repository) => repository.complete({
        id: beforeSend.id,
        leaseId: beforeSend.leaseId,
        deliveredAtMs: this.#now(),
      }));
    } catch {
      return false;
    }
  }

  async #validate(lease: MagicDeliveryLease, checkedAtMs: number) {
    try {
      return await this.#transactions.run((repository) => repository.validate({
        id: lease.id,
        leaseId: lease.leaseId,
        checkedAtMs,
      }));
    } catch {
      return undefined;
    }
  }

  async #cancel(lease: MagicDeliveryLease, reason: "unknown_key" | "tampered_envelope", cancelledAtMs: number): Promise<void> {
    try {
      await this.#transactions.run((repository) => repository.cancel({
        id: lease.id, leaseId: lease.leaseId, reason, cancelledAtMs,
      }));
    } catch { /* durable claim expiry provides the final recovery boundary */ }
  }

  async #release(lease: MagicDeliveryLease, releasedAtMs: number): Promise<void> {
    try {
      await this.#transactions.run((repository) => repository.release({
        id: lease.id, leaseId: lease.leaseId, releasedAtMs,
      }));
    } catch { /* retry via queue/tick after the existing lease expires */ }
  }

  async #audit(lease: MagicDeliveryLease, eventCode: "email.delivery.accepted" | "email.delivery.failed", occurredAtMs: number): Promise<boolean> {
    const id = auditIdForMagicDelivery(lease.id, eventCode, lease.deliveryAttempts);
    if (id === undefined) return false;
    try {
      // The frozen DB capability returns false only for an exact stable
      // metadata duplicate (id/lane/code/reference); a mismatched reuse
      // raises and stays fail-closed. The ID includes outcome and delivery
      // attempt, so a failed send and a later accepted retry are distinct
      // durable facts while a replay of the same attempt remains idempotent.
      await this.#audits.run((repository) => repository.accept({
        id, lane: "email", eventCode, boundedReference: lease.id, occurredAtMs,
      }));
      return true;
    } catch {
      return false;
    }
  }

  #now(): number {
    const now = this.#clock.nowMs();
    if (!Number.isSafeInteger(now) || now <= 0) throw new RuntimeRepositoryError("unavailable");
    return now;
  }
}

/** Challenge-only adapter around frozen `consume_apple_bridge_and_issue_session`.
 * It hashes raw proof material with an injected server secret before it crosses
 * the SQL boundary; the raw proof never becomes a database parameter. */
export class DataApiAppleChallengeSessionPort implements AppleBridgeSessionIssuancePort {
  readonly #transactions: DataApiCapabilityTransactionRunner<DataApiAppleChallengeRepository>;
  readonly #bridgeProofHmacKey: Uint8Array;

  constructor(input: { readonly client: DataApiClient; readonly bridgeProofHmacKey: Uint8Array }) {
    if (input === null || typeof input !== "object" || input.client === null || typeof input.client !== "object"
      || !(input.bridgeProofHmacKey instanceof Uint8Array) || input.bridgeProofHmacKey.length < 32) {
      throw new RuntimeRepositoryError("invalid_input");
    }
    this.#transactions = new DataApiCapabilityTransactionRunner(
      input.client,
      (unit) => new DataApiAppleChallengeRepository(unit),
    );
    this.#bridgeProofHmacKey = Uint8Array.from(input.bridgeProofHmacKey);
  }

  async consumeAppleBridgeAndIssueSession(input: Parameters<AppleBridgeSessionIssuancePort["consumeAppleBridgeAndIssueSession"]>[0]): Promise<Awaited<ReturnType<AppleBridgeSessionIssuancePort["consumeAppleBridgeAndIssueSession"]>>> {
    if (!canonicalOpaque(input.bridgeProof) || !(input.accessTokenHash instanceof Uint8Array) || input.accessTokenHash.length !== 32
      || !(input.refreshTokenHash instanceof Uint8Array) || input.refreshTokenHash.length !== 32 || !validDate(input.authenticatedAt)
      || !validDate(input.issuedAt) || !validDate(input.accessExpiresAt) || !validDate(input.inactivityExpiresAt) || !validDate(input.absoluteExpiresAt)) {
      throw new RuntimeRepositoryError("invalid_input");
    }
    const bridgeProofDigest = createHmac("sha256", this.#bridgeProofHmacKey).update(input.bridgeProof).digest("base64url");
    const result = await this.#transactions.run((repository) => repository.consumeAppleBridgeAndIssueSession({
      bridgeProofDigest,
      familyPublicId: input.familyPublicId,
      accessTokenDigest: Buffer.from(input.accessTokenHash).toString("base64url"),
      refreshTokenDigest: Buffer.from(input.refreshTokenHash).toString("base64url"),
      authenticatedAtMs: input.authenticatedAt.getTime(),
      issuedAtMs: input.issuedAt.getTime(),
      accessExpiresAtMs: input.accessExpiresAt.getTime(),
      inactivityExpiresAtMs: input.inactivityExpiresAt.getTime(),
      absoluteExpiresAtMs: input.absoluteExpiresAt.getTime(),
      policyVersion: input.policyVersion,
    }));
    if (result.status !== "issued") return result;
    return Object.freeze({
      status: "issued", principalInternalId: result.principalInternalId, principalCanonicalId: result.principalCanonicalId,
      familyInternalId: result.familyInternalId, familyPublicId: result.familyPublicId, authenticationEpoch: result.authenticationEpoch,
      authenticatedAt: new Date(result.authenticatedAtMs).toISOString(),
    });
  }
}

function billingClaim(claim: StripeReconciliationClaim): ReconciliationClaim {
  return Object.freeze({
    workspaceId: claim.workspaceInternalId, accountMode: claim.accountMode, accountId: claim.accountId, customerId: claim.customerId, subscriptionId: claim.subscriptionId, generation: claim.generation, leaseId: claim.leaseId,
    ...(claim.lastEventType === undefined ? {} : { lastEventType: claim.lastEventType }),
    ...(claim.lastObjectId === undefined ? {} : { lastObjectId: claim.lastObjectId }),
  });
}
function validBillingClaim(value: ReconciliationClaim): boolean {
  return typeof value.workspaceId === "string" && uuid(value.workspaceId) && (value.accountMode === "platform" || value.accountMode === "connected")
    && typeof value.accountId === "string" && /^acct_[A-Za-z0-9]{6,255}$/u.test(value.accountId)
    && typeof value.customerId === "string" && /^cus_[A-Za-z0-9]{6,255}$/u.test(value.customerId)
    && typeof value.subscriptionId === "string" && /^sub_[A-Za-z0-9]{6,255}$/u.test(value.subscriptionId)
    && Number.isSafeInteger(value.generation) && value.generation > 0 && typeof value.leaseId === "string" && /^[A-Za-z0-9_-]{1,128}$/u.test(value.leaseId);
}
function validHostedReconciliationGrant(value: HostedMutationGrant): boolean {
  return value.kind === "hosted-mutation-grant-v2" && value.action === "system.stripe.reconcile"
    && Number.isSafeInteger(value.hostedGlobalFlagVersion) && value.hostedGlobalFlagVersion > 0
    && Number.isSafeInteger(value.hostedWorkspaceFlagVersion) && value.hostedWorkspaceFlagVersion > 0;
}
function stripeIngressAudit(
  receipt: VerifiedWebhookAcceptance,
  outcome: "accepted" | "duplicate",
): Readonly<{
  readonly id: string;
  readonly lane: "stripe";
  readonly eventCode: "stripe.webhook.accepted" | "stripe.webhook.duplicate";
  readonly boundedReference: string;
  readonly occurredAtMs: number;
}> {
  const eventCode = outcome === "accepted" ? "stripe.webhook.accepted" : "stripe.webhook.duplicate";
  const identity = [
    receipt.accountMode,
    receipt.accountId,
    receipt.customerId,
    receipt.subscriptionId,
    receipt.eventId,
  ].join("\u0000");
  // Receipt outcome is a stable provider-owned discriminator. The frozen DB
  // accepts an exact retry of this id/lane/code/reference as false, but raises
  // on metadata mismatch; accepted and duplicate receipt outcomes therefore
  // must not share an audit ID.
  const auditDigest = createHash("sha256")
    .update("roomscan.slice4.stripe-ingress-audit.v2\u0000")
    .update(eventCode)
    .update("\u0000")
    .update(identity)
    .digest("base64url");
  const referenceDigest = createHash("sha256").update("roomscan.slice4.stripe-ingress-reference.v1\u0000").update(identity).digest("base64url");
  return Object.freeze({
    id: `paud_${auditDigest}`,
    lane: "stripe",
    eventCode,
    boundedReference: `stripe_evt_${referenceDigest}`,
    occurredAtMs: receipt.receivedAtMs,
  });
}
function validMessageId(value: unknown): value is string { return typeof value === "string" && /^[A-Za-z0-9._:-]{1,128}$/u.test(value); }
function auditIdForMagicDelivery(
  deliveryId: string,
  eventCode: "email.delivery.accepted" | "email.delivery.failed",
  deliveryAttempts: number,
): string | undefined {
  const match = /^mdl_([A-Za-z0-9_-]{12,124})$/u.exec(deliveryId);
  if (match === null || !Number.isSafeInteger(deliveryAttempts) || deliveryAttempts < 1) return undefined;
  const digest = createHash("sha256")
    .update("roomscan.slice4.email-delivery-audit.v2\u0000")
    .update(deliveryId)
    .update("\u0000")
    .update(eventCode)
    .update("\u0000")
    .update(String(deliveryAttempts))
    .digest("base64url");
  return `paud_${digest}`;
}
function expiredMagicClaim(value: Awaited<ReturnType<DataApiMagicDeliveryCapabilityRepository["claimNext"]>>): value is Readonly<{ readonly state: "expired"; readonly id: string }> {
  return value !== undefined && "state" in value && value.state === "expired";
}
function leaseIdFrom(bytes: Uint8Array): string | undefined { return bytes instanceof Uint8Array && bytes.length === 16 ? `lease_${Buffer.from(bytes).toString("base64url")}` : undefined; }
function boundedAdd(left: number, right: number): number {
  if (!Number.isSafeInteger(left) || !Number.isSafeInteger(right) || right <= 0 || left > Number.MAX_SAFE_INTEGER - right) {
    throw new RuntimeRepositoryError("unavailable");
  }
  return left + right;
}
function parsePublicBaseUrl(value: unknown): URL | undefined {
  if (typeof value !== "string" || value.length < 12 || value.length > 2_048) return undefined;
  try {
    const parsed = new URL(value);
    return parsed.protocol === "https:" && parsed.username === "" && parsed.password === "" && parsed.search === "" && parsed.hash === ""
      && (parsed.pathname === "" || parsed.pathname === "/") ? parsed : undefined;
  } catch { return undefined; }
}
function decryptMagicSecret(key: Uint8Array, lease: MagicDeliveryLease): Uint8Array {
  if (!(key instanceof Uint8Array) || key.length !== 32 || lease.iv.length !== 12 || lease.ciphertext.length !== 32 || lease.authenticationTag.length !== 16) {
    throw new RuntimeRepositoryError("invalid_input");
  }
  const decipher = createDecipheriv("aes-256-gcm", key, lease.iv);
  decipher.setAuthTag(Buffer.from(lease.authenticationTag));
  const secret = Buffer.concat([decipher.update(lease.ciphertext), decipher.final()]);
  if (secret.length !== 32) throw new RuntimeRepositoryError("unavailable");
  return Uint8Array.from(secret);
}
function magicLinkUrlFor(
  base: URL,
  selector: string,
  secret: Uint8Array,
  purpose: MagicDeliveryLease["purpose"],
): string {
  if (!/^[A-Za-z0-9_-]{22}$/u.test(selector) || Buffer.from(selector, "base64url").length !== 16
    || !(secret instanceof Uint8Array) || secret.length !== 32
    || (purpose !== "sign-in" && purpose !== "reauthenticate" && purpose !== "link-identity" && purpose !== "unlink-identity")) {
    throw new RuntimeRepositoryError("invalid_input");
  }
  const link = new URL(`/auth/magic-link/${selector}`, base);
  if (link.origin !== base.origin || link.search !== "") throw new RuntimeRepositoryError("unavailable");
  // Purpose is not an authorization decision: it remains fragment-only and
  // the API/DB bind it to the server-recorded link purpose. It is included so
  // candidate email links deliberately select the receipt branch instead of
  // failing or falling through to a session branch.
  link.hash = new URLSearchParams({ secret: Buffer.from(secret).toString("base64url"), purpose }).toString();
  return link.toString();
}
function canonicalOpaque(value: unknown): value is string { if (typeof value !== "string" || !/^[A-Za-z0-9_-]{43}$/u.test(value)) return false; const decoded = Buffer.from(value, "base64url"); return decoded.length === 32 && decoded.toString("base64url") === value; }
function validDate(value: unknown): value is Date { return value instanceof Date && Number.isSafeInteger(value.getTime()); }
function uuid(value: unknown): value is string { return typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu.test(value); }
async function unsupported<T>(): Promise<T> { throw new RuntimeRepositoryError("unavailable"); }
