import { createHmac } from "node:crypto";
import { isHostedMutationAction, isPublicationAction, permissionFor } from "../authorization/policy.js";
import type { RouteAuthorization } from "../contracts/route-manifest.js";
import type { TransactionBoundRepositoryBundle } from "../contracts/transaction-bound-repositories.js";
import { DataApiTransactionError, DataApiTransactionExecutor, type ResolvedAccessContext, type SqlResult, type SqlStatement } from "./data-api.js";
import { OperationDeniedError, type AuthorizedOperationContext, type SameTransactionOperationPort } from "../handlers/factory.js";

export interface TransactionRepositoryBundleFactory {
  bind(input: { readonly context: ResolvedAccessContext; readonly transactionMarker: symbol; readonly execute: (statement: SqlStatement) => Promise<SqlResult> }): TransactionBoundRepositoryBundle;
}

/** Concrete production wiring seam: context resolution, role/resource/flag
 * checks, and the handler's SQL mutation all share one Data API transaction. */
export class DataApiSameTransactionOperationPort implements SameTransactionOperationPort {
  constructor(private readonly d: { readonly transactions: DataApiTransactionExecutor; readonly clock: { now(): Date }; readonly accessTokenHmacKey: Uint8Array; readonly repositoryBundles: TransactionRepositoryBundleFactory }) { if (d.accessTokenHmacKey.length < 32 || typeof d.repositoryBundles?.bind !== "function") throw new Error("invalid_operation_configuration"); }
  async run<T>(input: { readonly accessToken: string; readonly authorization: Exclude<RouteAuthorization, { readonly kind: "public" }> }, operation: (context: AuthorizedOperationContext) => Promise<T>): Promise<T> {
    if (!canonicalOpaqueAccessToken(input.accessToken)) throw new OperationDeniedError();
    const digest = createHmac("sha256", this.d.accessTokenHmacKey).update(input.accessToken).digest();
    try {
      return await this.d.transactions.accessTransaction(digest, this.d.clock.now(), async (unit) => {
        const resolved = unit.context;
        if (input.authorization.kind === "workspace") {
          if (resolved.workspaceInternalId === undefined || resolved.role === undefined || resolved.authorizationVersion === undefined) throw new DataApiTransactionError("invalid_access");
          const permission = permissionFor(resolved.role, input.authorization.action); if (!permission.allowed || (permission.requiresRecentAuthentication && !resolved.recentAuthentication)) throw new DataApiTransactionError("invalid_access");
          if (input.authorization.resourceResolver === "current-membership" && resolved.workspaceInternalId === undefined) throw new DataApiTransactionError("invalid_access");
          // The sealed Slice 4 handler surface currently exposes reads only.
          // Mutation/publication routes cannot be registered until their
          // versioned persistence reducers exist; fail closed if that changes.
          if (isHostedMutationAction(input.authorization.action) || isPublicationAction(input.authorization.action)) throw new DataApiTransactionError("invalid_access");
        }
        if (input.authorization.kind === "session" && input.authorization.requiresRecentAuthentication && !resolved.recentAuthentication) throw new DataApiTransactionError("invalid_access");
        const transactionMarker = Symbol("roomscan-transaction");
        const repositories = this.d.repositoryBundles.bind({ context: resolved, transactionMarker, execute: unit.execute });
        if (repositories === null || typeof repositories !== "object" || repositories.contract !== "roomscan-transaction-repositories-v1" || repositories.transactionMarker !== transactionMarker) throw new DataApiTransactionError("invalid_access");
        const context: AuthorizedOperationContext = Object.freeze({ principalPublicId: resolved.principalPublicId, transactionMarker, repositories: Object.freeze(repositories) });
        return operation(context);
      });
    } catch (error) { if (error instanceof DataApiTransactionError && error.code === "invalid_access") throw new OperationDeniedError(); throw error; }
  }
}

function canonicalOpaqueAccessToken(token: string): boolean { if (!/^[A-Za-z0-9_-]{43}$/u.test(token)) return false; const decoded = Buffer.from(token, "base64url"); return decoded.length === 32 && decoded.toString("base64url") === token; }
