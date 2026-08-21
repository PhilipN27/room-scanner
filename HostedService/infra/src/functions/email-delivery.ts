import {
  createEmailDeliveryRoot,
  lazyRoot,
  unavailableSqsResponse,
} from "./slice4-runtime-roots.js";

// SQS records are targetless wakes only. The worker claims its own encrypted
// outbox row, so an event can never supply an address, selector, or secret.
const delivery = lazyRoot(async () => createEmailDeliveryRoot());

export async function handler(event: Parameters<typeof delivery>[0]) {
  try {
    return await delivery(event);
  } catch {
    return unavailableSqsResponse(event);
  }
}
