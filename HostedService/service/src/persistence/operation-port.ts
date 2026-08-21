import { createHmac } from "node:crypto";

import { isHostedMutationAction, isPublicationAction, permissionFor } from "../authorization/policy.js";
import type { RouteAuthorization } from "../contracts/route-manifest.js";
import type { TransactionBoundRepositoryBundle } from "../contracts/transaction-bound-repositories.js";
import { OperationDeniedError, type AuthorizedOperationContext, type SameTransactionOperationPort } from "../handlers/factory.js";
import {
  DataApiTransactionError,
  DataApiTransactionExecutor,
  type DataApiClient,
  type ResolvedAccessContext,
} from "../adapters/data-api.js";
import { decodeOpaqueDigest } from "./codecs.js";
import {
  DataApiCapabilityRepository,
  type WorkspaceAuthorizationState,
} from "./capabilities.js";

/**
 * Narrow runtime bundle for protected API routes. It carries only frozen
 * capability methods bound to the operation's one Data API transaction; it
 * deliberately never exposes a transaction ID, an SQL executor, workspace
 * UUIDs, or a role-selection switch to route handlers.
 */
export interface CapabilityRepositoryBundle extends TransactionBoundRepositoryBundle {
  readonly api: DataApiCapabilityRepository;
}

export class CapabilityRepositoryBundleError extends Error {
  constructor() {
    super("invalid_capability_repository_bundle");
    this.name = "CapabilityRepositoryBundleError";
  }
}

/** Runtime validation keeps a later handler from accepting a lookalike bundle
 * supplied by a test, an adapter, or a future route registration. */
export function requireCapabilityRepositories(
  value: TransactionBoundRepositoryBundle,
  marker: symbol,
): CapabilityRepositoryBundle {
  if (value === null
    || typeof value !== "object"
    || value.contract !== "roomscan-transaction-repositories-v1"
    || value.transactionMarker !== marker
    || !("api" in value)
    || !(value.api instanceof DataApiCapabilityRepository)) {
    throw new CapabilityRepositoryBundleError();
  }
  return value as CapabilityRepositoryBundle;
}

export interface DataApiCapabilityOperationPortDependencies {
  /** A role-bound API Data API client. The caller cannot select this role. */
  readonly client?: DataApiClient;
  /** Prefer injecting the role-bound executor when infrastructure composes it. */
  readonly transactions?: DataApiTransactionExecutor;
  readonly accessTokenHmacKey: Uint8Array;
  readonly clock: { now(): Date };
}

/**
 * Production protected-route operation port. Unlike the legacy generic bundle
 * seam, this concrete port retains the server-derived access digest while the
 * transaction is open, so every frozen capability derives tenant scope from
 * it rather than accepting a caller workspace ID.
 */
export class DataApiCapabilityOperationPort implements SameTransactionOperationPort {
  readonly #transactions: DataApiTransactionExecutor;
  readonly #accessTokenHmacKey: Uint8Array;
  readonly #clock: { now(): Date };

  constructor(input: DataApiCapabilityOperationPortDependencies) {
    if (input === null
      || typeof input !== "object"
      || !(input.accessTokenHmacKey instanceof Uint8Array)
      || input.accessTokenHmacKey.length < 32
      || input.clock === null
      || typeof input.clock !== "object"
      || typeof input.clock.now !== "function"
      || (input.transactions === undefined && input.client === undefined)
      || (input.transactions !== undefined && input.client !== undefined)) {
      throw new DataApiTransactionError("invalid_access");
    }
    this.#transactions = input.transactions ?? new DataApiTransactionExecutor(input.client!, {
      // This operation port has no system lane. Supplying a permanently denied
      // authorizer makes accidental use fail closed rather than creating a
      // caller-selectable system identity.
      authorize: async () => false,
    });
    this.#accessTokenHmacKey = Uint8Array.from(input.accessTokenHmacKey);
    this.#clock = input.clock;
  }

  async run<T>(
    input: {
      readonly accessToken: string;
      readonly authorization: Exclude<RouteAuthorization, { readonly kind: "public" }>;
    },
    operation: (context: AuthorizedOperationContext) => Promise<T>,
  ): Promise<T> {
    if (!canonicalOpaqueToken(input.accessToken) || typeof operation !== "function") {
      throw new OperationDeniedError();
    }
    const now = this.#clock.now();
    if (!(now instanceof Date) || !Number.isFinite(now.getTime())) throw new OperationDeniedError();
    const digest = createHmac("sha256", this.#accessTokenHmacKey).update(input.accessToken).digest();
    try {
      return await this.#transactions.accessTransaction(digest, now, async (unit) => {
        assertRouteAuthorization(unit.context, input.authorization);
        const marker = Symbol("roomscan-capability-transaction");
        const repositories: CapabilityRepositoryBundle = Object.freeze({
          contract: "roomscan-transaction-repositories-v1",
          transactionMarker: marker,
          api: new DataApiCapabilityRepository({ execute: unit.execute }, { accessTokenDigest: digest }),
        });
        if (input.authorization.kind === "workspace") {
          // The first resolver establishes transaction-local RLS context. This
          // second frozen capability then rereads active membership, role,
          // authorization generation, session family, and operational flags
          // from that same UoW immediately before the handler can act.
          let currentState: WorkspaceAuthorizationState | undefined;
          try {
            currentState = await repositories.api.readWorkspaceAuthorizationState({ authoritativeNowMs: now.getTime() });
          } catch {
            throw new DataApiTransactionError("invalid_access");
          }
          assertCurrentWorkspaceAuthorization(unit.context, input.authorization, currentState);
        }
        const context: AuthorizedOperationContext = Object.freeze({
          principalPublicId: unit.context.principalPublicId,
          transactionMarker: marker,
          repositories,
        });
        return operation(context);
      });
    } catch (error) {
      if (error instanceof OperationDeniedError) throw error;
      if (error instanceof DataApiTransactionError && error.code === "invalid_access") {
        throw new OperationDeniedError();
      }
      throw error;
    }
  }
}

function assertRouteAuthorization(
  context: ResolvedAccessContext,
  authorization: Exclude<RouteAuthorization, { readonly kind: "public" }>,
): void {
  if (authorization.kind === "session") {
    if (authorization.requiresRecentAuthentication && !context.recentAuthentication) {
      throw new DataApiTransactionError("invalid_access");
    }
    return;
  }
  if (context.workspaceInternalId === undefined
    || context.role === undefined
    || context.authorizationVersion === undefined) {
    throw new DataApiTransactionError("invalid_access");
  }
  const permission = permissionFor(context.role, authorization.action);
  if (!permission.allowed || (permission.requiresRecentAuthentication && !context.recentAuthentication)) {
    throw new DataApiTransactionError("invalid_access");
  }
  if (authorization.resourceResolver === "current-membership" && context.workspaceInternalId === undefined) {
    throw new DataApiTransactionError("invalid_access");
  }
  // The sealed Slice 4 HTTP manifest has no hosted/publication mutation
  // routes. If a later slice adds one, its own reducer/contract must be wired
  // deliberately instead of inheriting this read-only boundary.
  if (isHostedMutationAction(authorization.action) || isPublicationAction(authorization.action)) {
    throw new DataApiTransactionError("invalid_access");
  }
}

function assertCurrentWorkspaceAuthorization(
  initial: ResolvedAccessContext,
  authorization: Extract<RouteAuthorization, { readonly kind: "workspace" }>,
  current: WorkspaceAuthorizationState | undefined,
): void {
  if (current === undefined
    || initial.workspaceInternalId === undefined
    || initial.role === undefined
    || initial.authorizationVersion === undefined
    || current.workspaceInternalId !== initial.workspaceInternalId
    || current.principalInternalId !== initial.principalInternalId
    || current.principalCanonicalId !== initial.principalPublicId
    || current.familyInternalId !== initial.familyInternalId
    || current.familyPublicId !== initial.familyPublicId
    || current.role !== initial.role
    || current.authorizationVersion !== initial.authorizationVersion
    || current.authenticationEpoch !== initial.authenticationEpoch
    || current.authenticatedAtMs !== parseTimestampMilliseconds(initial.authenticatedAt)
    || current.recentAuthentication !== initial.recentAuthentication) {
    throw new DataApiTransactionError("invalid_access");
  }
  // Hosted professional operations never fall through a missing, false, or
  // non-literal operational flag. The state function renders missing flags as
  // false; composition still requires literal true at both scopes here.
  if (current.hosted.global.enabled !== true || current.hosted.workspace.enabled !== true) {
    throw new DataApiTransactionError("invalid_access");
  }
  const permission = permissionFor(current.role, authorization.action);
  if (!permission.allowed || (permission.requiresRecentAuthentication && current.recentAuthentication !== true)) {
    throw new DataApiTransactionError("invalid_access");
  }
  if (isPublicationAction(authorization.action)) {
    if (current.publication.global.enabled !== true || current.publication.workspace.enabled !== true) {
      throw new DataApiTransactionError("invalid_access");
    }
    if (permission.requiresEditorPublishingAllowed && current.publication.editorPublishingAllowed !== true) {
      throw new DataApiTransactionError("invalid_access");
    }
  }
}

function parseTimestampMilliseconds(value: unknown): number {
  if (typeof value !== "string") throw new DataApiTransactionError("invalid_access");
  const milliseconds = Date.parse(value);
  if (!Number.isSafeInteger(milliseconds)) throw new DataApiTransactionError("invalid_access");
  return milliseconds;
}

function canonicalOpaqueToken(value: unknown): value is string {
  if (typeof value !== "string") return false;
  try {
    decodeOpaqueDigest(value);
    return true;
  } catch {
    return false;
  }
}
