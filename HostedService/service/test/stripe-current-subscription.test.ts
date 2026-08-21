import assert from "node:assert/strict";
import test from "node:test";

import { StripeCurrentSubscriptionHttpAdapter } from "../src/composition/stripe-current-subscription.js";

const platformScope = Object.freeze({
  accountMode: "platform",
  accountId: "acct_1234567890",
  customerId: "cus_1234567890",
  subscriptionId: "sub_1234567890",
});

test("Stripe current-subscription adapter fetches the exact server-bound subscription and omits Stripe-Account for a platform scope", async () => {
  const calls: unknown[] = [];
  const source = adapter({
    request: async (input) => {
      calls.push(input);
      return json(subscription({ status: "active", priceId: "price_1234567890", customerId: platformScope.customerId }));
    },
  });

  assert.deepEqual(await source.fetchCurrent(platformScope as never), {
    status: "current",
    snapshot: {
      observedAtMs: Date.UTC(2030, 0, 1), status: "active", planKey: "professional-test", currentPeriodEndMs: 1_893_456_600_000,
    },
  });
  assert.deepEqual(calls, [{
    url: "https://api.stripe.com/v1/subscriptions/sub_1234567890",
    method: "GET",
    headers: {
      accept: "application/json",
      authorization: "Bearer rk_test_server_only_abcdefghijklmnop",
      "stripe-version": "2025-06-30.basil",
    },
    timeoutMs: 1_000,
    maxResponseBytes: 8_192,
    followRedirects: false,
  }]);
});

test("Stripe current-subscription adapter adds Stripe-Account only for a connected server-bound scope", async () => {
  const calls: unknown[] = [];
  const source = adapter({
    request: async (input) => {
      calls.push(input);
      return json(subscription({ status: "active", priceId: "price_1234567890", customerId: platformScope.customerId }));
    },
  });
  await source.fetchCurrent({ ...platformScope, accountMode: "connected" } as never);
  assert.equal((calls[0] as { readonly headers: Readonly<Record<string, string>> }).headers["Stripe-Account"], platformScope.accountId);
});

test("Stripe current-subscription adapter fails closed for a scope mismatch, malformed subscription, unconfigured price, or non-JSON provider state", async () => {
  const scenarios: readonly Uint8Array[] = [
    Buffer.from(JSON.stringify(subscription({ status: "active", priceId: "price_1234567890", customerId: "cus_other" }))),
    Buffer.from(JSON.stringify({ object: "subscription", id: "sub_other", customer: platformScope.customerId, status: "active", items: { object: "list", data: [] } })),
    Buffer.from(JSON.stringify(subscription({ status: "active", priceId: "price_unknown", customerId: platformScope.customerId }))),
    Buffer.from('{"object":"subscription","object":"subscription"}'),
  ];
  for (const body of scenarios) {
    const source = adapter({ request: async () => json(body) });
    assert.deepEqual(await source.fetchCurrent(platformScope as never), { status: "ambiguous" });
  }
  const wrongMedia = adapter({ request: async () => ({ status: 200, headers: { "content-type": "text/plain" }, body: Buffer.from("no") }) });
  assert.deepEqual(await wrongMedia.fetchCurrent(platformScope as never), { status: "ambiguous" });
});

function adapter(transport: { readonly request: (input: unknown) => Promise<Readonly<{ readonly status: number; readonly headers: Readonly<Record<string, string>>; readonly body: Uint8Array }>> }) {
  return new StripeCurrentSubscriptionHttpAdapter({
    transport: transport as never,
    secrets: { read: async () => "rk_test_server_only_abcdefghijklmnop" },
    secretName: "stripe-server-key",
    apiVersion: "2025-06-30.basil",
    timeoutMs: 1_000,
    maxResponseBytes: 8_192,
    pricePlanMappings: [{ priceId: "price_1234567890", planKey: "professional-test" }],
    clock: { nowMs: () => Date.UTC(2030, 0, 1) },
  });
}

function json(body: unknown) {
  return { status: 200, headers: { "content-type": "application/json" }, body: body instanceof Uint8Array ? body : Buffer.from(JSON.stringify(body)) };
}
function subscription(input: { readonly status: string; readonly priceId: string; readonly customerId: string }) {
  return {
    id: "sub_1234567890", object: "subscription", customer: input.customerId, status: input.status,
    items: { object: "list", data: [{ id: "si_1234567890", object: "subscription_item", current_period_end: 1_893_456_600, price: { id: input.priceId, object: "price" } }] },
  };
}
