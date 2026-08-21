import {
  createApiRoot,
  lazyRoot,
  unavailableResponse,
} from "./slice4-runtime-roots.js";

// Construction is lazy so guest/local paths never initialize an SDK client or
// request a secret merely by loading the deployed Lambda bundle.
const api = lazyRoot(async () => createApiRoot());

export async function handler(event: Parameters<typeof api>[0]) {
  try {
    return await api(event);
  } catch {
    return unavailableResponse();
  }
}
