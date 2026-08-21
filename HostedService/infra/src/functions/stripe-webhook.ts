import {
  createStripeWebhookRoot,
  lazyRoot,
  unavailableResponse,
} from "./slice4-runtime-roots.js";

// The unparsed HTTP API v2 envelope is passed through byte-for-byte. Signature
// verification and JSON parsing happen only in the Stripe ingress service.
const stripe = lazyRoot(async () => createStripeWebhookRoot());

export async function handler(event: Parameters<typeof stripe>[0]) {
  try {
    return await stripe(event);
  } catch {
    return unavailableResponse();
  }
}
