import {
  createReconciliationRoot,
  lazyRoot,
  unavailableSqsResponse,
} from "./slice4-runtime-roots.js";

const reconciliation = lazyRoot(async () => createReconciliationRoot());

export async function handler(event: Parameters<typeof reconciliation>[0]) {
  try {
    return await reconciliation(event);
  } catch {
    return unavailableSqsResponse(event);
  }
}
