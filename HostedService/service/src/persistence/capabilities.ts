import type { SqlResult, SqlStatement } from "../adapters/data-api.js";
import {
  PersistenceCodecError,
  decodeOpaqueDigest,
  epochMillisecondsToIsoTimestamp,
} from "./codecs.js";
import { DataApiApiAuthCompositeRepository } from "./auth-composites.js";
import { DataApiApiPolicyCapabilityRepository } from "./policy-composites.js";

/** A capability repository is bound to one already-open Data API transaction.
 * It deliberately has no public SQL method and `transaction()` therefore joins
 * the existing outer unit of work rather than opening a nested provider
 * transaction. */
export interface CapabilitySqlUnit {
  execute(statement: SqlStatement): Promise<SqlResult>;
}

export class CapabilityRepositoryError extends Error {
  constructor(readonly code: "invalid_input" | "invalid_result" | "unavailable") {
    super(code);
    this.name = "CapabilityRepositoryError";
  }
}

export type RefreshRotationResult =
  | Readonly<{
      readonly status: "rotated";
      readonly principalInternalId: string;
      readonly principalCanonicalId: string;
      readonly familyInternalId: string;
      readonly familyPublicId: string;
      readonly authenticationEpoch: number;
      readonly accessExpiresAtMs: number;
    }>
  | Readonly<{
      readonly status: "replay_revoked";
      readonly principalInternalId: string;
      readonly principalCanonicalId: string;
      readonly familyInternalId: string;
      readonly familyPublicId: string;
      readonly authenticationEpoch: number;
    }>
  | Readonly<{ readonly status: "unavailable" }>;

export interface WorkspaceAuthorizationState {
  /** Private UUID for use only inside the capability/repository layer. */
  readonly workspaceInternalId: string;
  /** Server-derived public presentation data. The internal UUID remains
   * capability-only and is never emitted by route composition. */
  readonly workspaceSlug: string;
  readonly workspaceDisplayName: string;
  /** These private IDs are compared only by trusted composition code against
   * the access resolver context; handlers receive the canonical principal ID
   * from AuthorizedOperationContext instead. */
  readonly principalInternalId: string;
  readonly principalCanonicalId: string;
  readonly familyInternalId: string;
  readonly familyPublicId: string;
  readonly role: "owner" | "admin" | "editor" | "viewer";
  readonly authorizationVersion: number;
  readonly authenticationEpoch: number;
  readonly authenticatedAtMs: number;
  readonly recentAuthentication: boolean;
  readonly professionalSignIn: Readonly<{ readonly enabled: boolean; readonly version: number }>;
  readonly hosted: Readonly<{
    readonly global: Readonly<{ readonly enabled: boolean; readonly version: number }>;
    readonly workspace: Readonly<{ readonly enabled: boolean; readonly version: number }>;
  }>;
  readonly publication: Readonly<{
    readonly global: Readonly<{ readonly enabled: boolean; readonly version: number }>;
    readonly workspace: Readonly<{ readonly enabled: boolean; readonly version: number }>;
    readonly editorPublishingAllowed: boolean;
    readonly editorPublishingPolicyVersion: number;
  }>;
}

const ROTATE_SESSION_FROM_REFRESH_SQL = `SELECT * FROM roomscan.rotate_session_from_refresh(
  :current_refresh_token_hash,
  :next_refresh_token_hash,
  :next_access_token_hash,
  (:rotated_at)::timestamptz,
  (:next_access_expires_at)::timestamptz,
  (:next_inactivity_expires_at)::timestamptz
)`;

const READ_WORKSPACE_AUTHORIZATION_STATE_SQL = `SELECT * FROM roomscan.read_workspace_authorization_state(
  (:access_token_hash)::bytea,
  (:authoritative_now)::timestamptz
)`;

export class DataApiCapabilityRepository {
  readonly #unit: CapabilitySqlUnit;
  readonly #accessTokenDigest: Uint8Array | undefined;

  constructor(unit: CapabilitySqlUnit, input: { readonly accessTokenDigest?: Uint8Array } = {}) {
    if (unit === null || typeof unit !== "object" || typeof unit.execute !== "function") {
      throw new CapabilityRepositoryError("invalid_input");
    }
    if (input.accessTokenDigest !== undefined && input.accessTokenDigest.length !== 32) {
      throw new CapabilityRepositoryError("invalid_input");
    }
    this.#unit = unit;
    this.#accessTokenDigest = input.accessTokenDigest === undefined
      ? undefined
      : Uint8Array.from(input.accessTokenDigest);
  }

  async transaction<T>(work: (repository: this) => Promise<T>): Promise<T> {
    if (typeof work !== "function") throw new CapabilityRepositoryError("invalid_input");
    return work(this);
  }

  async rotateSessionFromRefresh(input: {
    readonly currentRefreshDigest: string;
    readonly nextRefreshDigest: string;
    readonly nextAccessDigest: string;
    readonly rotatedAtMs: number;
    readonly nextAccessExpiresAtMs: number;
    readonly nextInactivityExpiresAtMs: number;
  }): Promise<RefreshRotationResult> {
    let current: Uint8Array;
    let nextRefresh: Uint8Array;
    let nextAccess: Uint8Array;
    let rotatedAt: string;
    let nextAccessExpiresAt: string;
    let nextInactivityExpiresAt: string;
    try {
      current = decodeOpaqueDigest(input.currentRefreshDigest);
      nextRefresh = decodeOpaqueDigest(input.nextRefreshDigest);
      nextAccess = decodeOpaqueDigest(input.nextAccessDigest);
      rotatedAt = epochMillisecondsToIsoTimestamp(input.rotatedAtMs);
      nextAccessExpiresAt = epochMillisecondsToIsoTimestamp(input.nextAccessExpiresAtMs);
      nextInactivityExpiresAt = epochMillisecondsToIsoTimestamp(input.nextInactivityExpiresAtMs);
    } catch (error) {
      if (error instanceof PersistenceCodecError) throw new CapabilityRepositoryError("invalid_input");
      throw error;
    }
    if (input.nextAccessExpiresAtMs <= input.rotatedAtMs || input.nextInactivityExpiresAtMs <= input.rotatedAtMs) {
      throw new CapabilityRepositoryError("invalid_input");
    }

    const result = await this.#unit.execute({
      sql: ROTATE_SESSION_FROM_REFRESH_SQL,
      parameters: [
        { name: "current_refresh_token_hash", value: { kind: "blob", bytes: Buffer.from(current) } },
        { name: "next_refresh_token_hash", value: { kind: "blob", bytes: Buffer.from(nextRefresh) } },
        { name: "next_access_token_hash", value: { kind: "blob", bytes: Buffer.from(nextAccess) } },
        { name: "rotated_at", value: { kind: "string", value: rotatedAt } },
        { name: "next_access_expires_at", value: { kind: "string", value: nextAccessExpiresAt } },
        { name: "next_inactivity_expires_at", value: { kind: "string", value: nextInactivityExpiresAt } },
      ],
    });
    return decodeRefreshRotation(result);
  }

  /** Reads server-derived current-workspace state. There is deliberately no
   * workspace parameter: the frozen function derives scope from the bound
   * access digest and returns no row for an unscoped/stale session. */
  async readWorkspaceAuthorizationState(input: {
    readonly authoritativeNowMs: number;
  }): Promise<WorkspaceAuthorizationState | undefined> {
    const access = this.#requireBoundAccessDigest();
    let authoritativeNow: string;
    try {
      authoritativeNow = epochMillisecondsToIsoTimestamp(input.authoritativeNowMs);
    } catch (error) {
      if (error instanceof PersistenceCodecError) throw new CapabilityRepositoryError("invalid_input");
      throw error;
    }
    const result = await this.#unit.execute({
      sql: READ_WORKSPACE_AUTHORIZATION_STATE_SQL,
      parameters: [
        { name: "access_token_hash", value: { kind: "blob", bytes: Buffer.from(access) } },
        { name: "authoritative_now", value: { kind: "string", value: authoritativeNow } },
      ],
    });
    if (result.rows.length === 0) return undefined;
    if (result.rows.length !== 1) throw new CapabilityRepositoryError("invalid_result");
    return decodeWorkspaceAuthorizationState(result.rows[0]);
  }

  /** Internal composition-only accessor. It is intentionally not an SQL
   * executor and returns a copy so a caller cannot mutate a shared digest. */
  boundAccessDigest(): Uint8Array {
    return Uint8Array.from(this.#requireBoundAccessDigest());
  }

  /** The API-only auth composites share this exact UoW and (when present)
   * server-derived access digest. The returned surface intentionally does not
   * contain the challenge-owned Apple bridge consumer. */
  auth(): DataApiApiAuthCompositeRepository {
    return new DataApiApiAuthCompositeRepository(
      this.#unit,
      this.#accessTokenDigest === undefined ? {} : { boundAccessDigest: this.#accessTokenDigest },
    );
  }

  /** API-only membership, quota, entitlement, flag, and identity reducers.
   * This shares the outer SQL-only unit and the same opaque access digest; it
   * cannot be constructed for an unscoped public route. */
  policy(): DataApiApiPolicyCapabilityRepository {
    return new DataApiApiPolicyCapabilityRepository(this.#unit, {
      boundAccessDigest: this.#requireBoundAccessDigest(),
    });
  }

  #requireBoundAccessDigest(): Uint8Array {
    if (this.#accessTokenDigest === undefined) throw new CapabilityRepositoryError("unavailable");
    return this.#accessTokenDigest;
  }
}

function decodeRefreshRotation(result: SqlResult): RefreshRotationResult {
  if (result.rows.length !== 1) throw new CapabilityRepositoryError("invalid_result");
  const row = result.rows[0];
  if (row === undefined || typeof row.status !== "string") throw new CapabilityRepositoryError("invalid_result");
  if (row.status === "unavailable") {
    requireNulls(row, [
      "principal_id", "principal_canonical_id", "family_id", "family_public_id",
      "authentication_epoch", "workspace_id", "role", "authorization_version", "access_expires_at",
    ]);
    return Object.freeze({ status: "unavailable" });
  }
  if (row.status !== "rotated" && row.status !== "replay_revoked") {
    throw new CapabilityRepositoryError("invalid_result");
  }
  if (!uuid(row.principal_id) || !identifier(row.principal_canonical_id) || !uuid(row.family_id)
    || !identifier(row.family_public_id) || !nonnegativeInteger(row.authentication_epoch)) {
    throw new CapabilityRepositoryError("invalid_result");
  }
  if (row.workspace_id !== null || row.role !== null || row.authorization_version !== null) {
    throw new CapabilityRepositoryError("invalid_result");
  }
  const base = {
    principalInternalId: row.principal_id,
    principalCanonicalId: row.principal_canonical_id,
    familyInternalId: row.family_id,
    familyPublicId: row.family_public_id,
    authenticationEpoch: row.authentication_epoch,
  } as const;
  if (row.status === "replay_revoked") {
    if (row.access_expires_at !== null) throw new CapabilityRepositoryError("invalid_result");
    return Object.freeze({ status: "replay_revoked", ...base });
  }
  const accessExpiresAtMs = parseCanonicalTimestamp(row.access_expires_at);
  return Object.freeze({ status: "rotated", ...base, accessExpiresAtMs });
}

function decodeWorkspaceAuthorizationState(row: Readonly<Record<string, unknown>> | undefined): WorkspaceAuthorizationState {
  if (row === undefined
    || !uuid(row.principal_id)
    || !identifier(row.principal_canonical_id)
    || !uuid(row.family_id)
    || !identifier(row.family_public_id)
    || !uuid(row.workspace_id)
    || !workspaceSlug(row.workspace_slug)
    || !workspaceDisplayName(row.workspace_display_name)
    || !workspaceRole(row.role)
    || !positiveInteger(row.authorization_version)
    || !nonnegativeInteger(row.authentication_epoch)
    || !boolean(row.recent_authentication)
    || !boolean(row.professional_sign_in_global_enabled)
    || !nonnegativeInteger(row.professional_sign_in_global_version)
    || !boolean(row.hosted_global_enabled)
    || !nonnegativeInteger(row.hosted_global_version)
    || !boolean(row.hosted_workspace_enabled)
    || !nonnegativeInteger(row.hosted_workspace_version)
    || !boolean(row.publication_global_enabled)
    || !nonnegativeInteger(row.publication_global_version)
    || !boolean(row.publication_workspace_enabled)
    || !nonnegativeInteger(row.publication_workspace_version)
    || !boolean(row.editor_publishing_allowed)
    || !nonnegativeInteger(row.editor_publishing_policy_version)) {
    throw new CapabilityRepositoryError("invalid_result");
  }
  let authenticatedAtMs: number;
  try {
    authenticatedAtMs = parseCanonicalTimestamp(row.authenticated_at);
  } catch (error) {
    if (error instanceof CapabilityRepositoryError) throw error;
    throw error;
  }
  return Object.freeze({
    workspaceInternalId: row.workspace_id,
    workspaceSlug: row.workspace_slug,
    workspaceDisplayName: row.workspace_display_name,
    principalInternalId: row.principal_id,
    principalCanonicalId: row.principal_canonical_id,
    familyInternalId: row.family_id,
    familyPublicId: row.family_public_id,
    role: row.role,
    authorizationVersion: row.authorization_version,
    authenticationEpoch: row.authentication_epoch,
    authenticatedAtMs,
    recentAuthentication: row.recent_authentication,
    professionalSignIn: Object.freeze({
      enabled: row.professional_sign_in_global_enabled,
      version: row.professional_sign_in_global_version,
    }),
    hosted: Object.freeze({
      global: Object.freeze({ enabled: row.hosted_global_enabled, version: row.hosted_global_version }),
      workspace: Object.freeze({ enabled: row.hosted_workspace_enabled, version: row.hosted_workspace_version }),
    }),
    publication: Object.freeze({
      global: Object.freeze({ enabled: row.publication_global_enabled, version: row.publication_global_version }),
      workspace: Object.freeze({ enabled: row.publication_workspace_enabled, version: row.publication_workspace_version }),
      editorPublishingAllowed: row.editor_publishing_allowed,
      editorPublishingPolicyVersion: row.editor_publishing_policy_version,
    }),
  });
}

function requireNulls(row: Readonly<Record<string, unknown>>, names: readonly string[]): void {
  if (names.some((name) => row[name] !== null)) throw new CapabilityRepositoryError("invalid_result");
}

function parseCanonicalTimestamp(value: unknown): number {
  if (typeof value !== "string") throw new CapabilityRepositoryError("invalid_result");
  const date = new Date(value);
  if (!Number.isSafeInteger(date.getTime()) || date.toISOString() !== value) throw new CapabilityRepositoryError("invalid_result");
  return date.getTime();
}

function uuid(value: unknown): value is string {
  return typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu.test(value);
}

function identifier(value: unknown): value is string {
  return typeof value === "string" && /^[A-Za-z0-9_-]{1,128}$/u.test(value);
}

function positiveInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0;
}

function nonnegativeInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

function boolean(value: unknown): value is boolean {
  return typeof value === "boolean";
}

function workspaceRole(value: unknown): value is WorkspaceAuthorizationState["role"] {
  return value === "owner" || value === "admin" || value === "editor" || value === "viewer";
}
function workspaceSlug(value: unknown): value is string { return typeof value === "string" && /^[a-z0-9][a-z0-9-]{2,62}$/u.test(value); }
function workspaceDisplayName(value: unknown): value is string { return typeof value === "string" && value.length >= 1 && value.length <= 160 && !/[\u0000-\u001f\u007f]/u.test(value); }
