import {
  createAuthChallengeRoot,
  lazyRoot,
} from "./slice4-runtime-roots.js";

const challenge = lazyRoot(async () => createAuthChallengeRoot());

/** An unavailable bridge never issues Cognito tokens. The opaque rejection
 * keeps configuration/provider details out of the event/error surface. */
export async function handler(event: Parameters<typeof challenge>[0]) {
  try {
    return await challenge(event);
  } catch {
    throw new Error("unavailable");
  }
}
