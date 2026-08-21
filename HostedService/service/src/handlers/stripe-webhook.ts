import type { StripeWebhookHandler } from "../billing/stripe-billing.js";
import { singleHttpHeader, type HttpApiV2Envelope, type HttpApiV2Response } from "../http/http-api-v2.js";

/** Thin ingress bridge to the accepted Task 5 implementation. It deliberately
 * cannot parse, log, or persist the raw body itself. */
export class StripeWebhookHttpAdapter {
  constructor(private readonly acceptedHandler: Pick<StripeWebhookHandler, "handle">) {}
  handle(envelope: HttpApiV2Envelope): Promise<HttpApiV2Response> {
    if (singleHttpHeader(envelope.headers, "content-type") !== "application/json") {
      return Promise.resolve({ statusCode: 400, headers: { "content-type": "application/json", "cache-control": "no-store" }, body: JSON.stringify({ error: { code: "invalid_request" } }) });
    }
    return this.acceptedHandler.handle(envelope);
  }
}
