import { createHash, createHmac, timingSafeEqual } from "node:crypto";

import {
  rawHttpApiV2Body,
  singleHttpHeader,
  type HttpApiV2Envelope,
  type HttpApiV2Response,
} from "../http/http-api-v2.js";
import type { HostedMutationGrant } from "../operations/operational-flags.js";

export class BillingError extends Error {
  constructor(readonly code: string) {
    super(code);
    this.name = "BillingError";
  }
}

export interface Clock {
  nowMs(): number;
}

export interface StripeEventReceipt {
  readonly workspaceId: string;
  readonly accountMode: StripeAccountMode;
  readonly accountId: string;
  readonly customerId: string;
  readonly subscriptionId: string;
  readonly eventId: string;
  readonly eventType: string;
  readonly objectId: string;
  readonly payloadSha256: string;
  readonly providerOccurredAtMs: number;
  readonly receivedAtMs: number;
}

export interface VerifiedWebhookAcceptance {
  readonly accountMode: StripeAccountMode;
  readonly accountId: string;
  readonly customerId: string;
  readonly subscriptionId: string;
  readonly eventId: string;
  readonly eventType: string;
  readonly objectId: string;
  readonly payloadSha256: string;
  readonly providerOccurredAtMs: number;
  readonly receivedAtMs: number;
}

export interface ReconciliationClaim {
  readonly workspaceId: string;
  readonly accountMode: StripeAccountMode;
  readonly accountId: string;
  readonly customerId: string;
  readonly subscriptionId: string;
  readonly generation: number;
  readonly leaseId: string;
  /** Receipt metadata is diagnostic only; reconciliation must not derive state from it. */
  readonly lastEventType?: string;
  /** Receipt metadata is diagnostic only; reconciliation must not derive state from it. */
  readonly lastObjectId?: string;
}

/** An exact server-owned Stripe billing binding. Reconciliation never lists
 * a provider account: the claim constrains one customer/subscription pair. */
export type StripeAccountMode = "platform" | "connected";

export interface StripeSubscriptionScope {
  readonly accountMode: StripeAccountMode;
  readonly accountId: string;
  readonly customerId: string;
  readonly subscriptionId: string;
}

export type SubscriptionStatus =
  | "inactive"
  | "trialing"
  | "active"
  | "past_due"
  | "canceled"
  | "read_only_grace";

export interface SubscriptionSnapshot {
  readonly observedAtMs: number;
  readonly status: SubscriptionStatus;
  readonly planKey: string;
  readonly currentPeriodEndMs?: number;
}

export interface SubscriptionState {
  readonly workspaceId: string;
  readonly accountId: string;
  readonly generation: number;
  readonly status: SubscriptionStatus;
  readonly planKey: string;
  readonly currentPeriodEndMs?: number;
  readonly sourceObservedAtMs: number;
  readonly appliedAtMs: number;
}

export interface BillingTransaction {
  acceptVerifiedWebhook(input: VerifiedWebhookAcceptance): Promise<{
    readonly status: "accepted" | "duplicate";
    readonly workspaceId: string;
    readonly generation: number;
  }>;
  claimReconciliation(leaseId: string, nowMs: number, leaseExpiresAtMs: number): Promise<ReconciliationClaim | undefined>;
  completeReconciliation(input: {
    readonly claim: ReconciliationClaim;
    readonly snapshot: SubscriptionSnapshot;
    readonly appliedAtMs: number;
    readonly hostedGrant: HostedMutationGrant;
  }): Promise<BillingCompletionResult>;
  releaseReconciliation(claim: ReconciliationClaim, releasedAtMs: number): Promise<boolean>;
  currentSubscription(workspaceId: string): Promise<SubscriptionState | undefined>;
}

export type BillingCompletionResult =
  | { readonly status: "applied"; readonly needsAnotherGeneration: boolean }
  | { readonly status: "stale_claim"; readonly needsAnotherGeneration: boolean }
  | { readonly status: "hosted_gate_rejected"; readonly needsAnotherGeneration: boolean };

export interface BillingRepository extends BillingTransaction {
  transaction<T>(work: (transaction: BillingTransaction) => Promise<T>): Promise<T>;
}

export interface BillingAuditLogger {
  write(eventCode: string, fields: Readonly<{ result: string }>): void;
}

export class StripeWebhookSignatureVerifier {
  private readonly signingSecret: string;
  private readonly clock: Clock;
  private readonly toleranceMs: number;

  constructor(input: { readonly signingSecret: string; readonly clock: Clock; readonly toleranceMs: number }) {
    if (input.signingSecret.length === 0) throw new BillingError("invalid_signing_secret");
    if (!Number.isSafeInteger(input.toleranceMs) || input.toleranceMs < 0) {
      throw new BillingError("invalid_signature_tolerance");
    }
    this.signingSecret = input.signingSecret;
    this.clock = input.clock;
    this.toleranceMs = input.toleranceMs;
  }

  verify(rawBody: Uint8Array, signatureHeader: string): boolean {
    const parts = signatureHeader.split(",").map((part) => part.trim());
    const timestamps = parts
      .filter((part) => part.startsWith("t="))
      .map((part) => part.slice(2));
    if (timestamps.length !== 1 || !/^\d+$/.test(timestamps[0] ?? "")) return false;
    const timestampSeconds = Number(timestamps[0]);
    if (!Number.isSafeInteger(timestampSeconds)) return false;
    const signedAtMs = timestampSeconds * 1_000;
    if (!Number.isSafeInteger(signedAtMs)) return false;
    const nowMs = this.clock.nowMs();
    if (!Number.isSafeInteger(nowMs)) return false;
    if (Math.abs(nowMs - signedAtMs) > this.toleranceMs) return false;

    const expected = createHmac("sha256", this.signingSecret)
      .update(String(timestampSeconds))
      .update(".")
      .update(rawBody)
      .digest();
    const candidates = parts
      .filter((part) => part.startsWith("v1="))
      .map((part) => part.slice(3))
      .filter((value) => /^[a-fA-F0-9]{64}$/.test(value))
      .map((value) => Buffer.from(value, "hex"));
    let matched = false;
    for (const candidate of candidates) {
      matched = timingSafeEqual(expected, candidate) || matched;
    }
    return matched;
  }
}

interface StripeWebhookEvent {
  readonly accountMode: StripeAccountMode;
  readonly accountId?: string;
  readonly customerId: string;
  readonly subscriptionId: string;
  readonly id: string;
  readonly type: string;
  readonly created: number;
  readonly objectId: string;
}

interface IgnoredStripeWebhookEvent {
  readonly kind: "ignored";
}

interface AcceptedStripeWebhookEvent extends StripeWebhookEvent {
  readonly kind: "subscription";
}

const INVALID_WEBHOOK: HttpApiV2Response = Object.freeze({
  statusCode: 400,
  headers: Object.freeze({ "cache-control": "no-store", "content-type": "application/json" }),
  body: "{\"code\":\"invalid_webhook\"}",
});

const WEBHOOK_ACCEPTED: HttpApiV2Response = Object.freeze({
  statusCode: 200,
  headers: Object.freeze({ "cache-control": "no-store", "content-type": "application/json" }),
  body: "{\"received\":true}",
});

const WEBHOOK_RETRY: HttpApiV2Response = Object.freeze({
  statusCode: 500,
  headers: Object.freeze({ "cache-control": "no-store", "content-type": "application/json" }),
  body: "{\"code\":\"webhook_retry\"}",
});

export class StripeWebhookHandler {
  private readonly clock: Clock;
  private readonly signatureVerifier: StripeWebhookSignatureVerifier;
  private readonly repository: BillingRepository;
  private readonly defaultStripeAccountId: string;
  private readonly logger: BillingAuditLogger;

  constructor(input: {
    readonly clock: Clock;
    readonly signatureVerifier: StripeWebhookSignatureVerifier;
    readonly repository: BillingRepository;
    readonly defaultStripeAccountId: string;
    readonly logger: BillingAuditLogger;
  }) {
    if (!stripeAccountId(input.defaultStripeAccountId)) throw new BillingError("invalid_default_account");
    this.clock = input.clock;
    this.signatureVerifier = input.signatureVerifier;
    this.repository = input.repository;
    this.defaultStripeAccountId = input.defaultStripeAccountId;
    this.logger = input.logger;
  }

  async handle(envelope: HttpApiV2Envelope): Promise<HttpApiV2Response> {
    const rawBody = rawHttpApiV2Body(envelope);
    const signature = singleHttpHeader(envelope.headers, "stripe-signature");
    if (rawBody === undefined || signature === undefined || !this.safelyVerify(rawBody, signature)) {
      this.logger.write("stripe_webhook", { result: "rejected" });
      return INVALID_WEBHOOK;
    }

    const event = parseStripeWebhookEvent(rawBody);
    if (event === undefined) {
      this.logger.write("stripe_webhook", { result: "rejected" });
      return INVALID_WEBHOOK;
    }
    if (event.kind === "ignored") {
      this.logger.write("stripe_webhook", { result: "ignored" });
      return WEBHOOK_ACCEPTED;
    }

    try {
      await this.repository.transaction(async (transaction) => transaction.acceptVerifiedWebhook({
        accountMode: event.accountMode,
        accountId: event.accountId ?? this.defaultStripeAccountId,
        customerId: event.customerId,
        subscriptionId: event.subscriptionId,
        eventId: event.id,
        eventType: event.type,
        objectId: event.objectId,
        payloadSha256: createHash("sha256").update(rawBody).digest("hex"),
        providerOccurredAtMs: event.created * 1_000,
        receivedAtMs: this.clock.nowMs(),
      }));
      this.logger.write("stripe_webhook", { result: "accepted" });
      return WEBHOOK_ACCEPTED;
    } catch {
      this.logger.write("stripe_webhook", { result: "retry" });
      return WEBHOOK_RETRY;
    }
  }

  private safelyVerify(rawBody: Uint8Array, signature: string): boolean {
    try {
      return this.signatureVerifier.verify(rawBody, signature);
    } catch {
      return false;
    }
  }
}

function parseStripeWebhookEvent(rawBody: Uint8Array): AcceptedStripeWebhookEvent | IgnoredStripeWebhookEvent | undefined {
  let parsed: unknown;
  try {
    parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(rawBody)) as unknown;
  } catch {
    return undefined;
  }
  if (!isRecord(parsed) || parsed.object !== "event") return undefined;
  if (!stripeEventId(parsed.id) || !nonEmptyString(parsed.type)) return undefined;
  if (
    !Number.isSafeInteger(parsed.created) ||
    (parsed.created as number) < 0 ||
    (parsed.created as number) > Math.floor(Number.MAX_SAFE_INTEGER / 1_000)
  ) return undefined;
  if (parsed.account !== undefined && !stripeAccountId(parsed.account)) return undefined;
  if (!isRecord(parsed.data) || !isRecord(parsed.data.object)) return undefined;
  if (!STRIPE_SUBSCRIPTION_EVENTS.has(parsed.type)) return { kind: "ignored" };
  if (parsed.data.object.object !== "subscription" || !stripeSubscriptionId(parsed.data.object.id)
    || !stripeCustomerId(parsed.data.object.customer)) return undefined;
  return {
    kind: "subscription",
    accountMode: parsed.account === undefined ? "platform" : "connected",
    id: parsed.id,
    type: parsed.type,
    created: parsed.created as number,
    objectId: parsed.data.object.id,
    customerId: parsed.data.object.customer,
    subscriptionId: parsed.data.object.id,
    ...(parsed.account === undefined ? {} : { accountId: parsed.account }),
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function nonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}

export interface CurrentSubscriptionSource {
  fetchCurrent(scope: StripeSubscriptionScope): Promise<
    | { readonly status: "current"; readonly snapshot: SubscriptionSnapshot }
    | { readonly status: "ambiguous" }
  >;
}

export interface HostedOperationsGate {
  hostedMutationGrant(
    workspaceId: string,
    action: "system.stripe.reconcile",
  ): Promise<HostedMutationGrant>;
}

export interface BillingSystemAuthority {
  readonly capability: unknown;
  authorize(input: {
    readonly capability: unknown;
    readonly action: "system.stripe.reconcile";
  }): Promise<boolean>;
}

export interface RandomBytes {
  bytes(length: number): Uint8Array;
}

export type BillingReconciliationResult =
  | { readonly status: "idle" }
  | { readonly status: "paused"; readonly reason: "hosted_operations_disabled" }
  | { readonly status: "retry"; readonly reason: "ambiguous_current_state" | "current_state_unavailable" | "stale_claim" }
  | { readonly status: "applied"; readonly generation: number; readonly needsAnotherGeneration: boolean };

export class BillingReconciliationService {
  private readonly clock: Clock;
  private readonly random: RandomBytes;
  private readonly repository: BillingRepository;
  private readonly currentSubscriptions: CurrentSubscriptionSource;
  private readonly hostedGate: HostedOperationsGate;
  private readonly systemAuthority: BillingSystemAuthority;
  private readonly leaseMs: number;

  constructor(input: {
    readonly clock: Clock;
    readonly random: RandomBytes;
    readonly repository: BillingRepository;
    readonly currentSubscriptions: CurrentSubscriptionSource;
    readonly hostedGate: HostedOperationsGate;
    readonly systemAuthority: BillingSystemAuthority;
    readonly leaseMs: number;
  }) {
    if (!Number.isSafeInteger(input.leaseMs) || input.leaseMs <= 0) throw new BillingError("invalid_lease");
    this.clock = input.clock;
    this.random = input.random;
    this.repository = input.repository;
    this.currentSubscriptions = input.currentSubscriptions;
    this.hostedGate = input.hostedGate;
    this.systemAuthority = input.systemAuthority;
    this.leaseMs = input.leaseMs;
  }

  async runOnce(): Promise<BillingReconciliationResult> {
    await this.#assertSystemAuthority();
    const nowMs = this.clock.nowMs();
    const leaseId = Buffer.from(this.random.bytes(16)).toString("hex");
    const claim = await this.repository.transaction(async (transaction) =>
      transaction.claimReconciliation(leaseId, nowMs, nowMs + this.leaseMs));
    if (claim === undefined) return { status: "idle" };

    const initialHostedGrant = await this.#hostedGrant(claim.workspaceId);
    if (initialHostedGrant === undefined) {
      await this.repository.transaction(async (transaction) =>
        transaction.releaseReconciliation(claim, this.clock.nowMs()));
      return { status: "paused", reason: "hosted_operations_disabled" };
    }

    let authoritative: Awaited<ReturnType<CurrentSubscriptionSource["fetchCurrent"]>>;
    try {
      authoritative = await this.currentSubscriptions.fetchCurrent({
        accountMode: claim.accountMode,
        accountId: claim.accountId,
        customerId: claim.customerId,
        subscriptionId: claim.subscriptionId,
      });
    } catch {
      await this.repository.transaction(async (transaction) =>
        transaction.releaseReconciliation(claim, this.clock.nowMs()));
      return { status: "retry", reason: "current_state_unavailable" };
    }
    if (authoritative.status === "ambiguous" || !validSubscriptionSnapshot(authoritative.snapshot)) {
      await this.repository.transaction(async (transaction) =>
        transaction.releaseReconciliation(claim, this.clock.nowMs()));
      return { status: "retry", reason: "ambiguous_current_state" };
    }

    const completion = await this.repository.transaction(async (transaction) => transaction.completeReconciliation({
      claim,
      snapshot: authoritative.snapshot,
      appliedAtMs: this.clock.nowMs(),
      hostedGrant: initialHostedGrant,
    }));
    if (completion.status === "hosted_gate_rejected") {
      await this.repository.transaction(async (transaction) =>
        transaction.releaseReconciliation(claim, this.clock.nowMs()));
      return { status: "paused", reason: "hosted_operations_disabled" };
    }
    if (completion.status === "stale_claim") return { status: "retry", reason: "stale_claim" };
    return {
      status: "applied",
      generation: claim.generation,
      needsAnotherGeneration: completion.needsAnotherGeneration,
    };
  }

  async #assertSystemAuthority(): Promise<void> {
    let authorized = false;
    try {
      authorized = await this.systemAuthority.authorize({
        capability: this.systemAuthority.capability,
        action: "system.stripe.reconcile",
      }) === true;
    } catch {
      authorized = false;
    }
    if (!authorized) throw new BillingError("system_authorization_required");
  }

  async #hostedGrant(workspaceId: string): Promise<HostedMutationGrant | undefined> {
    try {
      const grant = await this.hostedGate.hostedMutationGrant(
        workspaceId,
        "system.stripe.reconcile",
      );
      if (
        grant.kind !== "hosted-mutation-grant-v2" ||
        grant.workspaceId !== workspaceId ||
        grant.action !== "system.stripe.reconcile" ||
        !Number.isSafeInteger(grant.hostedGlobalFlagVersion) ||
        grant.hostedGlobalFlagVersion <= 0 ||
        !Number.isSafeInteger(grant.hostedWorkspaceFlagVersion) ||
        grant.hostedWorkspaceFlagVersion <= 0
      ) return undefined;
      return grant;
    } catch {
      return undefined;
    }
  }
}

const SUBSCRIPTION_STATUSES = new Set<SubscriptionStatus>([
  "active",
  "inactive",
  "trialing",
  "past_due",
  "canceled",
  "read_only_grace",
]);

const STRIPE_SUBSCRIPTION_EVENTS: ReadonlySet<string> = new Set([
  "customer.subscription.created",
  "customer.subscription.deleted",
  "customer.subscription.paused",
  "customer.subscription.resumed",
  "customer.subscription.trial_will_end",
  "customer.subscription.updated",
] as const);

function stripeAccountId(value: unknown): value is string {
  return typeof value === "string" && /^acct_[A-Za-z0-9]{6,255}$/u.test(value);
}

function stripeCustomerId(value: unknown): value is string {
  return typeof value === "string" && /^cus_[A-Za-z0-9]{6,255}$/u.test(value);
}

function stripeSubscriptionId(value: unknown): value is string {
  return typeof value === "string" && /^sub_[A-Za-z0-9]{6,255}$/u.test(value);
}

function stripeEventId(value: unknown): value is string {
  return typeof value === "string" && /^evt_[A-Za-z0-9]{6,255}$/u.test(value);
}

function validSubscriptionSnapshot(value: unknown): value is SubscriptionSnapshot {
  if (!isRecord(value)) return false;
  if (!Number.isSafeInteger(value.observedAtMs) || (value.observedAtMs as number) < 0) return false;
  if (typeof value.status !== "string" || !SUBSCRIPTION_STATUSES.has(value.status as SubscriptionStatus)) {
    return false;
  }
  if (typeof value.planKey !== "string" || value.planKey.length < 1 || value.planKey.length > 128) return false;
  return value.currentPeriodEndMs === undefined ||
    (Number.isSafeInteger(value.currentPeriodEndMs) && (value.currentPeriodEndMs as number) >= 0);
}
