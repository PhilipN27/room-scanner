import { createHmac } from "node:crypto";

import {
  DataApiTransactionExecutor,
  type DataApiClient,
} from "../adapters/data-api.js";
import { decodeOpaqueDigest } from "./codecs.js";

export interface DataApiAppAuthorizerDependencies {
  /** The authorizer runtime's role-bound client, never a caller-selected role. */
  readonly client?: DataApiClient;
  /** Infrastructure may instead inject its already role-bound executor. */
  readonly transactions?: DataApiTransactionExecutor;
  readonly accessTokenHmacKey: Uint8Array;
  readonly clock: { now(): Date };
}

/**
 * Early gateway preflight only. It proves an app-owned opaque access token is
 * presently resolvable using the authorizer role, but it intentionally returns
 * neither identity nor tenant data and makes no authorization decision. The
 * protected API operation repeats current authorization in its own UoW.
 */
export class DataApiAppAuthorizer {
  readonly #transactions: DataApiTransactionExecutor;
  readonly #accessTokenHmacKey: Uint8Array;
  readonly #clock: { now(): Date };

  constructor(input: DataApiAppAuthorizerDependencies) {
    if (input === null
      || typeof input !== "object"
      || !(input.accessTokenHmacKey instanceof Uint8Array)
      || input.accessTokenHmacKey.length < 32
      || input.clock === null
      || typeof input.clock !== "object"
      || typeof input.clock.now !== "function"
      || (input.client === undefined && input.transactions === undefined)
      || (input.client !== undefined && input.transactions !== undefined)) {
      throw new Error("invalid_app_authorizer_configuration");
    }
    this.#transactions = input.transactions ?? new DataApiTransactionExecutor(input.client!, {
      authorize: async () => false,
    });
    this.#accessTokenHmacKey = Uint8Array.from(input.accessTokenHmacKey);
    this.#clock = input.clock;
  }

  async authorizeBearer(accessToken: string): Promise<boolean> {
    if (!canonicalOpaqueAccessToken(accessToken)) return false;
    const now = this.#clock.now();
    if (!(now instanceof Date) || !Number.isFinite(now.getTime())) return false;
    const digest = createHmac("sha256", this.#accessTokenHmacKey).update(accessToken).digest();
    try {
      await this.#transactions.accessTransaction(digest, now, async () => undefined);
      return true;
    } catch {
      return false;
    }
  }
}

function canonicalOpaqueAccessToken(value: unknown): value is string {
  if (typeof value !== "string") return false;
  try {
    decodeOpaqueDigest(value);
    return true;
  } catch {
    return false;
  }
}
