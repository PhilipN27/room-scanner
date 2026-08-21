import { TextDecoder } from "node:util";

import type { CurrentSubscriptionSource, StripeSubscriptionScope, SubscriptionSnapshot, SubscriptionStatus } from "../billing/stripe-billing.js";
import type { SecretValuePort } from "../contracts/provider-ports.js";
import { hasDuplicateJsonObjectKeys } from "../handlers/factory.js";

/** A deliberately narrow GET transport. The existing `HttpTransport` is
 * POST-only for Apple form exchange; making it accept Stripe GET requests
 * would broaden that provider-neutral contract unnecessarily. Infrastructure
 * supplies an implementation, but it cannot choose URL/method/headers. */
export interface StripeCurrentSubscriptionHttpPort {
  request(input: {
    readonly url: string;
    readonly method: "GET";
    readonly headers: Readonly<Record<string, string>>;
    readonly timeoutMs: number;
    readonly maxResponseBytes: number;
    readonly followRedirects: false;
  }): Promise<Readonly<{ readonly status: number; readonly headers: Readonly<Record<string, string>>; readonly body: Uint8Array }>>;
}

export interface StripePricePlanMapping {
  readonly priceId: string;
  /** This is a versioned application plan key, not a Stripe product/price
   * decision. Production mappings remain an operator configuration gate. */
  readonly planKey: string;
}

export interface StripeCurrentSubscriptionHttpAdapterDependencies {
  readonly transport: StripeCurrentSubscriptionHttpPort;
  readonly secrets: SecretValuePort;
  readonly secretName: string;
  /** Pin a Stripe API version explicitly; do not silently depend on an
   * account-default response schema. */
  readonly apiVersion: string;
  readonly timeoutMs: number;
  readonly maxResponseBytes: number;
  readonly pricePlanMappings: readonly StripePricePlanMapping[];
  readonly clock: { nowMs(): number };
}

/**
 * Strict, bounded Stripe subscription reader for the reconciliation worker.
 * The account ID arrives only from a server-selected DB claim. It deliberately
 * fetches exactly the claimed subscription ID—not a list endpoint—and verifies
 * the returned customer/subscription pair before mapping a configured price.
 * Any mismatch, malformed JSON, unexpected content type, or provider failure
 * is `ambiguous`; Stripe JSON never directly authorizes an operation.
 */
export class StripeCurrentSubscriptionHttpAdapter implements CurrentSubscriptionSource {
  constructor(private readonly dependencies: StripeCurrentSubscriptionHttpAdapterDependencies) {
    if (!validDependencies(dependencies)) throw new StripeCurrentSubscriptionError();
  }

  async fetchCurrent(scope: StripeSubscriptionScope): Promise<{ readonly status: "current"; readonly snapshot: SubscriptionSnapshot } | { readonly status: "ambiguous" }> {
    if (!validScope(scope)) return ambiguous();
    const observedAtMs = this.dependencies.clock.nowMs();
    if (!safeTimestamp(observedAtMs)) return ambiguous();
    let secret: string;
    try { secret = await this.dependencies.secrets.read(this.dependencies.secretName); } catch { return ambiguous(); }
    if (!stripeSecret(secret)) return ambiguous();
    let response: Awaited<ReturnType<StripeCurrentSubscriptionHttpPort["request"]>>;
    try {
      response = await this.dependencies.transport.request({
        url: subscriptionUrl(scope.subscriptionId),
        method: "GET",
        headers: Object.freeze({
          accept: "application/json",
          authorization: `Bearer ${secret}`,
          "stripe-version": this.dependencies.apiVersion,
          ...(scope.accountMode === "connected" ? { "Stripe-Account": scope.accountId } : {}),
        }),
        timeoutMs: this.dependencies.timeoutMs,
        maxResponseBytes: this.dependencies.maxResponseBytes,
        followRedirects: false,
      });
    } catch { return ambiguous(); }
    const payload = responsePayload(response, this.dependencies.maxResponseBytes);
    if (payload === undefined) return ambiguous();
    const subscription = parseSubscription(payload);
    if (subscription === undefined || subscription.id !== scope.subscriptionId || subscription.customerId !== scope.customerId) return ambiguous();
    const status = mapStatus(subscription.status);
    const mapping = this.dependencies.pricePlanMappings.find((candidate) => candidate.priceId === subscription.priceId);
    if (status === undefined || mapping === undefined) return ambiguous();
    return Object.freeze({ status: "current", snapshot: Object.freeze({
      observedAtMs, status, planKey: mapping.planKey, currentPeriodEndMs: subscription.currentPeriodEndMs,
    }) });
  }
}

export class StripeCurrentSubscriptionError extends Error {
  constructor() {
    super("invalid_stripe_subscription_composition");
    this.name = "StripeCurrentSubscriptionError";
  }
}

interface ParsedSubscription {
  readonly id: string;
  readonly customerId: string;
  readonly status: string;
  readonly priceId: string;
  readonly currentPeriodEndMs: number;
}

function validDependencies(value: unknown): value is StripeCurrentSubscriptionHttpAdapterDependencies {
  if (value === null || typeof value !== "object") return false;
  const input = value as StripeCurrentSubscriptionHttpAdapterDependencies;
  if (input.transport === null || typeof input.transport.request !== "function" || input.secrets === null || typeof input.secrets.read !== "function"
    || !identifier(input.secretName, 1, 256) || !stripeApiVersion(input.apiVersion) || !duration(input.timeoutMs, 1, 30_000)
    || !duration(input.maxResponseBytes, 256, 1_048_576)
    || input.clock === null || typeof input.clock.nowMs !== "function" || !Array.isArray(input.pricePlanMappings)
    || input.pricePlanMappings.length < 1 || input.pricePlanMappings.length > 64) return false;
  const prices = new Set<string>(); const plans = new Set<string>();
  for (const mapping of input.pricePlanMappings) {
    if (mapping === null || typeof mapping !== "object" || !stripePriceId(mapping.priceId) || !planKey(mapping.planKey)
      || prices.has(mapping.priceId) || plans.has(mapping.planKey)) return false;
    prices.add(mapping.priceId); plans.add(mapping.planKey);
  }
  return true;
}

function responsePayload(value: unknown, maximumBytes: number): string | undefined {
  if (value === null || typeof value !== "object") return undefined;
  const response = value as { status?: unknown; headers?: unknown; body?: unknown };
  if (response.status !== 200 || !headers(response.headers) || response.body === undefined || !(response.body instanceof Uint8Array)
    || response.body.length === 0 || response.body.length > maximumBytes) return undefined;
  if (contentType(response.headers) !== "application/json") return undefined;
  try { return new TextDecoder("utf-8", { fatal: true }).decode(response.body); } catch { return undefined; }
}

function parseSubscription(source: string): ParsedSubscription | undefined {
  if (source.length < 2 || source.length > 1_048_576 || hasDuplicateJsonObjectKeys(source)) return undefined;
  let parsed: unknown;
  try { parsed = JSON.parse(source); } catch { return undefined; }
  if (!record(parsed) || parsed.object !== "subscription" || !stripeSubscriptionId(parsed.id) || !stripeCustomerId(parsed.customer) || typeof parsed.status !== "string"
    || !record(parsed.items) || parsed.items.object !== "list" || !Array.isArray(parsed.items.data) || parsed.items.data.length !== 1) return undefined;
  const item = parsed.items.data[0];
  if (!record(item) || item.object !== "subscription_item" || !stripeItemId(item.id) || !record(item.price)
    || item.price.object !== "price" || !stripePriceId(item.price.id)) return undefined;
  const currentPeriodEndMs = secondsToMilliseconds(item.current_period_end);
  if (currentPeriodEndMs === undefined) return undefined;
  return Object.freeze({ id: parsed.id, customerId: parsed.customer, status: parsed.status, priceId: item.price.id, currentPeriodEndMs });
}

function mapStatus(value: string): SubscriptionStatus | undefined {
  // `unpaid`, `incomplete`, `incomplete_expired`, and `paused` require an
  // owner-approved entitlement policy. Treating them as a grace tier here
  // would silently invent commercial behavior, so they fail closed.
  return value === "active" || value === "trialing" || value === "past_due" || value === "canceled" ? value : undefined;
}

function contentType(value: Readonly<Record<string, string>>): string | undefined {
  const entries = Object.entries(value).filter(([name]) => name.toLowerCase() === "content-type");
  return entries.length === 1 && entries[0]?.[1] === "application/json" ? "application/json" : undefined;
}
function headers(value: unknown): value is Readonly<Record<string, string>> {
  return value !== null && typeof value === "object" && Object.entries(value).every(([name, header]) => /^[!#$%&'*+.^_`|~0-9A-Za-z-]{1,128}$/u.test(name) && typeof header === "string" && header.length <= 8_192);
}
function record(value: unknown): value is Record<string, unknown> { return value !== null && typeof value === "object" && !Array.isArray(value); }
function identifier(value: unknown, min: number, max: number): value is string { return typeof value === "string" && value.length >= min && value.length <= max && /^[A-Za-z0-9._:/-]+$/u.test(value); }
function stripeApiVersion(value: unknown): value is string { return typeof value === "string" && /^[0-9]{4}-[0-9]{2}-[0-9]{2}(?:\.[A-Za-z0-9_-]{1,64})?$/u.test(value); }
function duration(value: unknown, min: number, max: number): value is number { return typeof value === "number" && Number.isSafeInteger(value) && value >= min && value <= max; }
function planKey(value: unknown): value is string { return typeof value === "string" && /^[A-Za-z0-9._-]{1,128}$/u.test(value); }
function stripeAccountId(value: unknown): value is string { return typeof value === "string" && /^acct_[A-Za-z0-9]{6,255}$/u.test(value); }
function stripeCustomerId(value: unknown): value is string { return typeof value === "string" && /^cus_[A-Za-z0-9]{6,255}$/u.test(value); }
function stripePriceId(value: unknown): value is string { return typeof value === "string" && /^price_[A-Za-z0-9]{6,255}$/u.test(value); }
function stripeSubscriptionId(value: unknown): value is string { return typeof value === "string" && /^sub_[A-Za-z0-9]{6,255}$/u.test(value); }
function stripeItemId(value: unknown): value is string { return typeof value === "string" && /^si_[A-Za-z0-9]{6,255}$/u.test(value); }
function stripeSecret(value: unknown): value is string { return typeof value === "string" && value.length >= 16 && value.length <= 512 && !/[\u0000-\u001f\u007f\s]/u.test(value); }
function safeTimestamp(value: unknown): value is number { return typeof value === "number" && Number.isSafeInteger(value) && value >= 0; }
function secondsToMilliseconds(value: unknown): number | undefined { return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 && value <= Math.floor(Number.MAX_SAFE_INTEGER / 1_000) ? value * 1_000 : undefined; }
function ambiguous(): Readonly<{ readonly status: "ambiguous" }> { return Object.freeze({ status: "ambiguous" }); }
function validScope(value: unknown): value is StripeSubscriptionScope {
  return value !== null && typeof value === "object"
    && ((value as StripeSubscriptionScope).accountMode === "platform" || (value as StripeSubscriptionScope).accountMode === "connected")
    && stripeAccountId((value as StripeSubscriptionScope).accountId)
    && stripeCustomerId((value as StripeSubscriptionScope).customerId)
    && stripeSubscriptionId((value as StripeSubscriptionScope).subscriptionId);
}
function subscriptionUrl(subscriptionId: string): string { return `https://api.stripe.com/v1/subscriptions/${subscriptionId}`; }
