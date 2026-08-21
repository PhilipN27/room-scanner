import {
  createAuthorizerRoot,
  lazyRoot,
  unavailableAuthorizerResponse,
} from "./slice4-runtime-roots.js";

const authorizer = lazyRoot(async () => createAuthorizerRoot());

/** Gateway preflight only: protected API operations still resolve current
 * membership and role in their own same-transaction authorization boundary. */
export async function handler(event: Parameters<typeof authorizer>[0]) {
  try {
    return await authorizer(event);
  } catch {
    return unavailableAuthorizerResponse();
  }
}
