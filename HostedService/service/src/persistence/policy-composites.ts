import type { SqlResult, SqlStatement, SqlWireValue } from "../adapters/data-api.js";
import {
  PersistenceCodecError,
  decodeBillingPayloadSha256,
  decodeOpaqueDigest,
  epochMillisecondsToIsoTimestamp,
} from "./codecs.js";
import type { CapabilitySqlUnit } from "./capabilities.js";

/**
 * This module maps only frozen `0007` capability functions. It deliberately
 * has no generic query surface, no workspace argument on API methods, and no
 * runtime role-selection input. Infrastructure supplies an instance bound to
 * one already-selected database login lane.
 */
export class PolicyCapabilityError extends Error {
  constructor(readonly code: "invalid_input" | "invalid_result" | "unavailable") {
    super(code);
    this.name = "PolicyCapabilityError";
  }
}

export type OperationalFlagKey =
  | "professional_sign_in_enabled"
  | "hosted_operations_enabled"
  | "publication_enabled";
export type WorkspaceRole = "owner" | "admin" | "editor" | "viewer";
export type MembershipState = "invited" | "active" | "removed";
export type QuotaMetric = "project_count" | "member_count" | "working_bytes" | "raw_bytes" | "portal_bytes";
export type AllocatableQuotaMetric = Exclude<QuotaMetric, "member_count">;
export type QuotaAuthorizationAction = "project.create" | "project.revise" | "raw_archive.allocate" | "publication.create";
export type SubscriptionStatus = "inactive" | "trialing" | "active" | "past_due" | "canceled" | "read_only_grace";

/** A persisted exact-grant snapshot. No caller-supplied workspace appears: the
 * capability derives it from the bound app access hash. */
export interface VersionedHostedGrant {
  readonly hostedGlobalVersion: number;
  readonly hostedWorkspaceVersion: number;
  readonly publicationGlobalVersion?: number;
  readonly publicationWorkspaceVersion?: number;
}

export interface OperationalFlagValue {
  readonly enabled: boolean;
  readonly version: number;
}

export interface QuotaUsageCapability {
  readonly workspaceInternalId: string;
  readonly metric: QuotaMetric;
  readonly periodKey: string;
  readonly policyVersion: number;
  readonly used: number;
  readonly reserved: number;
  readonly limit: number;
  readonly warningThresholdPercent: number;
  readonly reconciliationGeneration: number;
  readonly updatedAtMs: number;
}

export interface QuotaReservationCapability {
  readonly workspaceInternalId: string;
  readonly periodKey: string;
  readonly idempotencyKey: string;
  readonly metric: AllocatableQuotaMetric;
  readonly authorizationAction: QuotaAuthorizationAction;
  readonly resourceKind?: string;
  readonly resourceId?: string;
  readonly requestedAmount: number;
  readonly policyVersion: number;
  readonly expiresAtMs: number;
  readonly state: "reserved" | "finalized" | "released";
  readonly createdAtMs: number;
  readonly finalizedAmount?: number;
  readonly finalizedAtMs?: number;
  readonly releasedAtMs?: number;
  readonly releaseReason?: "released" | "expired";
}

export interface InvitationCapability {
  readonly internalId: string;
  readonly workspaceInternalId: string;
  readonly publicId: string;
  readonly role: Exclude<WorkspaceRole, "owner">;
  readonly state: "active" | "consumed" | "revoked";
  readonly version: number;
  readonly expiresAtMs: number;
  readonly createdAtMs: number;
  readonly updatedAtMs: number;
  readonly consumedAtMs?: number;
  readonly revokedAtMs?: number;
}

export interface MembershipMutationCapability {
  readonly workspaceInternalId: string;
  readonly principalInternalId: string;
  readonly principalCanonicalId: string;
  readonly role: WorkspaceRole;
  readonly state: MembershipState;
  readonly authorizationVersion: number;
}

/** Result of the API-only, access-bound reducer that assigns exactly one
 * existing active workspace to an otherwise unscoped session family. Internal
 * IDs remain persistence/composition-only and must never be emitted by HTTP. */
export interface WorkspaceSessionScopeCapability {
  readonly workspaceInternalId: string;
  readonly workspaceSlug: string;
  readonly principalInternalId: string;
  readonly principalCanonicalId: string;
  readonly familyInternalId: string;
  readonly familyPublicId: string;
  readonly role: WorkspaceRole;
  readonly authorizationVersion: number;
}

export interface CandidateIdentityProofResult {
  readonly status: "minted" | "recent_auth_required" | "unavailable";
  readonly principalInternalId?: string;
  readonly principalCanonicalId?: string;
  readonly familyInternalId?: string;
  readonly familyPublicId?: string;
  readonly proofExpiresAtMs?: number;
}

export interface IdentityMutationResult {
  readonly status: "linked" | "unlinked" | "already_linked" | "candidate_owned" | "not_linked" | "proof_unavailable" | "recent_auth_required" | "principal_unavailable" | "final_auth_method";
  readonly principalInternalId?: string;
  readonly principalCanonicalId?: string;
  readonly familyInternalId?: string;
  readonly familyPublicId?: string;
  readonly authenticationEpoch?: number;
}

export interface CurrentSubscriptionCapability {
  readonly workspaceInternalId: string;
  readonly accountId: string;
  readonly generation: number;
  readonly status: SubscriptionStatus;
  readonly planKey: string;
  readonly currentPeriodEndMs?: number;
  readonly sourceObservedAtMs: number;
  readonly appliedAtMs: number;
}

const READ_GLOBAL_FLAG_SQL = "SELECT * FROM roomscan.read_global_operational_flag(:flag_key)";
const READ_WORKSPACE_FLAG_SQL = `SELECT * FROM roomscan.read_workspace_operational_flag(
  (:access_token_hash)::bytea,
  (:authoritative_now)::timestamptz,
  :flag_key
)`;
const BOOTSTRAP_WORKSPACE_SQL = `SELECT * FROM roomscan.bootstrap_workspace_v2(
  (:access_token_hash)::bytea,
  (:authoritative_now)::timestamptz,
  :slug,
  :display_name,
  :audit_event_id
)`;
const SCOPE_SESSION_WORKSPACE_SQL = `SELECT * FROM roomscan.scope_session_workspace_v2(
  (:access_token_hash)::bytea,
  (:authoritative_now)::timestamptz,
  :slug
)`;
const CREATE_INVITATION_SQL = `SELECT * FROM roomscan.create_invitation_v2(
  (:access_token_hash)::bytea,
  (:authoritative_now)::timestamptz,
  :public_id,
  (:token_hash)::bytea,
  :invited_email,
  :role,
  (:expires_at)::timestamptz,
  :hosted_global_version,
  :hosted_workspace_version,
  :audit_event_id
)`;
const READ_INVITATION_BY_TOKEN_SQL = `SELECT * FROM roomscan.read_invitation_by_token(
  (:access_token_hash)::bytea,
  (:authoritative_now)::timestamptz,
  (:token_hash)::bytea
)`;
const ACCEPT_INVITATION_SQL = `SELECT * FROM roomscan.accept_invitation_v2(
  (:access_token_hash)::bytea,
  (:authoritative_now)::timestamptz,
  (:token_hash)::bytea,
  :expected_version,
  :hosted_global_version,
  :hosted_workspace_version,
  :audit_event_id
)`;
const REVOKE_INVITATION_SQL = `SELECT * FROM roomscan.revoke_invitation_v2(
  (:access_token_hash)::bytea,
  (:authoritative_now)::timestamptz,
  :public_id,
  :expected_version,
  :hosted_global_version,
  :hosted_workspace_version,
  :audit_event_id
)`;
const MUTATE_MEMBERSHIP_SQL = `SELECT * FROM roomscan.mutate_membership_v2(
  (:access_token_hash)::bytea,
  (:authoritative_now)::timestamptz,
  :target_principal_canonical_id,
  :expected_authorization_version,
  :expected_role,
  :expected_state,
  :requested_role,
  :requested_state,
  :hosted_global_version,
  :hosted_workspace_version,
  :audit_event_id
)`;
const MINT_CANDIDATE_PROOF_SQL = `SELECT * FROM roomscan.mint_candidate_identity_proof_v2(
  (:access_token_hash)::bytea,
  (:authoritative_now)::timestamptz,
  (:verified_receipt_hash)::bytea,
  :expected_issuer,
  :expected_purpose,
  (:candidate_proof_hash)::bytea,
  (:expires_at)::timestamptz,
  :policy_version
)`;
const MUTATE_IDENTITY_SQL = `SELECT * FROM roomscan.mutate_identity_v2(
  (:access_token_hash)::bytea,
  (:authoritative_now)::timestamptz,
  (:candidate_proof_hash)::bytea,
  :purpose,
  :deliberate_confirmation,
  :audit_event_id,
  :notification_id,
  :identity_reference,
  :policy_version
)`;
const QUOTA_SNAPSHOT_SQL = `SELECT * FROM roomscan.quota_snapshot_v2(
  (:access_token_hash)::bytea,
  (:authoritative_now)::timestamptz,
  (:metric)::roomscan.quota_metric,
  :period_key
)`;
const RESERVE_QUOTA_SQL = `SELECT * FROM roomscan.reserve_quota_v2(
  (:access_token_hash)::bytea,
  (:authoritative_now)::timestamptz,
  (:metric)::roomscan.quota_metric,
  :period_key,
  :authorization_action,
  :resource_kind,
  :resource_id,
  :amount,
  :idempotency_key,
  :policy_version,
  (:expires_at)::timestamptz,
  :hosted_global_version,
  :hosted_workspace_version,
  :publication_global_version,
  :publication_workspace_version
)`;
const FINALIZE_QUOTA_SQL = `SELECT * FROM roomscan.finalize_quota_v2(
  (:access_token_hash)::bytea,
  (:authoritative_now)::timestamptz,
  :period_key,
  :idempotency_key,
  :actual_amount,
  :hosted_global_version,
  :hosted_workspace_version,
  :publication_global_version,
  :publication_workspace_version
)`;
const RELEASE_QUOTA_SQL = `SELECT * FROM roomscan.release_quota_v2(
  (:access_token_hash)::bytea,
  (:authoritative_now)::timestamptz,
  :period_key,
  :idempotency_key,
  :reason,
  :hosted_global_version,
  :hosted_workspace_version,
  :publication_global_version,
  :publication_workspace_version
)`;
const READ_CURRENT_SUBSCRIPTION_SQL = `SELECT * FROM roomscan.read_current_subscription_v2(
  (:access_token_hash)::bytea,
  (:authoritative_now)::timestamptz
)`;
const READ_QUOTA_OVERVIEW_SQL = `SELECT * FROM roomscan.read_quota_overview_v2(
  (:access_token_hash)::bytea,
  (:authoritative_now)::timestamptz
)`;
const ACCEPT_STRIPE_EVENT_SQL = `SELECT * FROM roomscan.accept_stripe_event_v2(
  :account_mode,
  :provider_account_id,
  :billing_customer_id,
  :subscription_id,
  :event_id,
  :event_type,
  :object_id,
  (:payload_sha256)::bytea,
  (:provider_occurred_at)::timestamptz,
  (:received_at)::timestamptz
)`;
const CLAIM_STRIPE_RECONCILIATION_SQL = `SELECT * FROM roomscan.claim_stripe_reconciliation_v2(
  :lease_id,
  (:claimed_at)::timestamptz,
  (:lease_expires_at)::timestamptz
)`;
const RELEASE_STRIPE_RECONCILIATION_SQL = `SELECT roomscan.release_stripe_reconciliation_v2(
  :lease_id,
  :account_mode,
  :provider_account_id,
  :billing_customer_id,
  :subscription_id,
  :generation,
  (:released_at)::timestamptz
) AS released`;
const COMPLETE_STRIPE_RECONCILIATION_SQL = `SELECT * FROM roomscan.complete_stripe_reconciliation_v2(
  :lease_id,
  :account_mode,
  :provider_account_id,
  :billing_customer_id,
  :subscription_id,
  :generation,
  (:source_observed_at)::timestamptz,
  :subscription_status,
  :plan_key,
  (:current_period_end)::timestamptz,
  (:applied_at)::timestamptz,
  :hosted_global_version,
  :hosted_workspace_version
)`;
const ACCEPT_PROVIDER_AUDIT_SQL = `SELECT roomscan.accept_provider_audit_event(
  :id,
  :provider_lane,
  :event_code,
  :bounded_reference,
  (:occurred_at)::timestamptz
) AS accepted`;
const CLAIM_PROVIDER_AUDIT_SQL = `SELECT * FROM roomscan.claim_provider_audit_event(
  :lease_id,
  (:claimed_at)::timestamptz,
  (:lease_expires_at)::timestamptz
)`;
const COMPLETE_PROVIDER_AUDIT_SQL = `SELECT roomscan.complete_provider_audit_event(
  :id,
  :lease_id,
  (:delivered_at)::timestamptz
) AS completed`;
const RELEASE_PROVIDER_AUDIT_SQL = `SELECT roomscan.release_provider_audit_event(
  :id,
  :lease_id,
  (:released_at)::timestamptz
) AS released`;

/** API-lane composite. It is constructed from a transaction-bound SQL-only
 * unit, and its tenant scope is always the HMAC digest retained by that unit. */
export class DataApiApiPolicyCapabilityRepository {
  readonly #access: Uint8Array;

  constructor(private readonly unit: CapabilitySqlUnit, input: { readonly boundAccessDigest: Uint8Array }) {
    if (!validUnit(unit) || input === null || typeof input !== "object" || !(input.boundAccessDigest instanceof Uint8Array)
      || input.boundAccessDigest.length !== 32) throw new PolicyCapabilityError("invalid_input");
    this.#access = Uint8Array.from(input.boundAccessDigest);
  }

  async transaction<T>(work: (repository: this) => Promise<T>): Promise<T> {
    if (typeof work !== "function") throw new PolicyCapabilityError("invalid_input");
    return work(this);
  }

  async readGlobalFlag(flag: OperationalFlagKey): Promise<OperationalFlagValue | undefined> {
    if (!flagKey(flag)) throw new PolicyCapabilityError("invalid_input");
    const result = await this.unit.execute({ sql: READ_GLOBAL_FLAG_SQL, parameters: [text("flag_key", flag)] });
    if (result.rows.length === 0) return undefined;
    return decodeFlag(exactlyOne(result));
  }

  async readWorkspaceFlag(input: { readonly flag: OperationalFlagKey; readonly authoritativeNowMs: number }): Promise<(OperationalFlagValue & { readonly workspaceInternalId: string }) | undefined> {
    const now = timestamp(input.authoritativeNowMs);
    if (!flagKey(input.flag) || now === undefined) throw new PolicyCapabilityError("invalid_input");
    const result = await this.unit.execute({ sql: READ_WORKSPACE_FLAG_SQL, parameters: [
      blob("access_token_hash", this.#access), timestampParameter("authoritative_now", now), text("flag_key", input.flag),
    ] });
    if (result.rows.length === 0) return undefined;
    const row = exactlyOne(result);
    const base = decodeFlag(row);
    if (!uuid(row.workspace_id)) throw new PolicyCapabilityError("invalid_result");
    return Object.freeze({ ...base, workspaceInternalId: row.workspace_id });
  }

  async bootstrapWorkspace(input: { readonly authoritativeNowMs: number; readonly slug: string; readonly displayName: string; readonly auditEventId: string }): Promise<MembershipMutationCapability & { readonly membershipInternalId: string; readonly familyInternalId: string; readonly familyPublicId: string }> {
    const now = timestamp(input.authoritativeNowMs);
    if (now === undefined || !slug(input.slug) || !bounded(input.displayName, 1, 160) || !auditId(input.auditEventId)) {
      throw new PolicyCapabilityError("invalid_input");
    }
    const row = exactlyOne(await this.unit.execute({ sql: BOOTSTRAP_WORKSPACE_SQL, parameters: [
      blob("access_token_hash", this.#access), timestampParameter("authoritative_now", now), text("slug", input.slug),
      text("display_name", input.displayName), text("audit_event_id", input.auditEventId),
    ] }));
    if (!uuid(row.workspace_id) || !uuid(row.membership_id) || !uuid(row.principal_id) || !canonicalPrincipal(row.principal_canonical_id)
      || !uuid(row.family_id) || !familyId(row.family_public_id) || !positive(row.authorization_version)) {
      throw new PolicyCapabilityError("invalid_result");
    }
    return Object.freeze({
      workspaceInternalId: row.workspace_id, membershipInternalId: row.membership_id, principalInternalId: row.principal_id,
      principalCanonicalId: row.principal_canonical_id, familyInternalId: row.family_id, familyPublicId: row.family_public_id,
      role: "owner", state: "active", authorizationVersion: row.authorization_version,
    });
  }

  /** No caller workspace UUID, role, or membership ID is accepted. The
   * SECURITY DEFINER capability derives an active membership from the bound
   * access hash, rechecks recent auth and literal hosted flags, then atomically
   * scopes the family and all active access rows. */
  async scopeSessionWorkspace(input: {
    readonly authoritativeNowMs: number;
    readonly slug: string;
  }): Promise<WorkspaceSessionScopeCapability> {
    const now = timestamp(input.authoritativeNowMs);
    if (now === undefined || !slug(input.slug)) throw new PolicyCapabilityError("invalid_input");
    const row = exactlyOne(await this.unit.execute({ sql: SCOPE_SESSION_WORKSPACE_SQL, parameters: [
      blob("access_token_hash", this.#access), timestampParameter("authoritative_now", now), text("slug", input.slug),
    ] }));
    if (!uuid(row.workspace_id) || !slug(row.workspace_slug) || !uuid(row.principal_id)
      || !canonicalPrincipal(row.principal_canonical_id) || !uuid(row.family_id)
      || !familyId(row.family_public_id) || !workspaceRole(row.role)
      || !positive(row.authorization_version)) {
      throw new PolicyCapabilityError("invalid_result");
    }
    return Object.freeze({
      workspaceInternalId: row.workspace_id,
      workspaceSlug: row.workspace_slug,
      principalInternalId: row.principal_id,
      principalCanonicalId: row.principal_canonical_id,
      familyInternalId: row.family_id,
      familyPublicId: row.family_public_id,
      role: row.role,
      authorizationVersion: row.authorization_version,
    });
  }

  async createInvitation(input: {
    readonly authoritativeNowMs: number; readonly publicId: string; readonly tokenDigest: string; readonly invitedEmail?: string;
    readonly role: Exclude<WorkspaceRole, "owner">; readonly expiresAtMs: number; readonly auditEventId: string; readonly hostedGrant: VersionedHostedGrant;
  }): Promise<InvitationCapability> {
    const now = timestamp(input.authoritativeNowMs); const expires = timestamp(input.expiresAtMs); const token = digest(input.tokenDigest);
    const grant = hostedGrant(input.hostedGrant);
    if (now === undefined || expires === undefined || expires <= now || !invitationId(input.publicId) || token === undefined
      || !invitableRole(input.role) || (input.invitedEmail !== undefined && !bounded(input.invitedEmail, 3, 320)) || !auditId(input.auditEventId) || grant === undefined) {
      throw new PolicyCapabilityError("invalid_input");
    }
    const result = await this.unit.execute({ sql: CREATE_INVITATION_SQL, parameters: [
      blob("access_token_hash", this.#access), timestampParameter("authoritative_now", now), text("public_id", input.publicId), blob("token_hash", token),
      input.invitedEmail === undefined ? nil("invited_email") : text("invited_email", input.invitedEmail), text("role", input.role), timestampParameter("expires_at", expires),
      long("hosted_global_version", grant.hostedGlobalVersion), long("hosted_workspace_version", grant.hostedWorkspaceVersion), text("audit_event_id", input.auditEventId),
    ] });
    return decodeInvitation(exactlyOne(result));
  }

  async readInvitationByToken(input: { readonly authoritativeNowMs: number; readonly tokenDigest: string }): Promise<InvitationCapability | undefined> {
    const now = timestamp(input.authoritativeNowMs); const token = digest(input.tokenDigest);
    if (now === undefined || token === undefined) throw new PolicyCapabilityError("invalid_input");
    const result = await this.unit.execute({ sql: READ_INVITATION_BY_TOKEN_SQL, parameters: [
      blob("access_token_hash", this.#access), timestampParameter("authoritative_now", now), blob("token_hash", token),
    ] });
    if (result.rows.length === 0) return undefined;
    return decodeInvitation(exactlyOne(result));
  }

  async acceptInvitation(input: { readonly authoritativeNowMs: number; readonly tokenDigest: string; readonly expectedVersion: number; readonly auditEventId: string; readonly hostedGrant: VersionedHostedGrant }): Promise<
    | Readonly<{ readonly status: "accepted" | "already_member"; readonly membership: MembershipMutationCapability; readonly invitationVersion: number }>
    | Readonly<{ readonly status: "unavailable" }>
  > {
    const now = timestamp(input.authoritativeNowMs); const token = digest(input.tokenDigest); const grant = hostedGrant(input.hostedGrant);
    if (now === undefined || token === undefined || !positive(input.expectedVersion) || !auditId(input.auditEventId) || grant === undefined) {
      throw new PolicyCapabilityError("invalid_input");
    }
    const row = exactlyOne(await this.unit.execute({ sql: ACCEPT_INVITATION_SQL, parameters: [
      blob("access_token_hash", this.#access), timestampParameter("authoritative_now", now), blob("token_hash", token), long("expected_version", input.expectedVersion),
      long("hosted_global_version", grant.hostedGlobalVersion), long("hosted_workspace_version", grant.hostedWorkspaceVersion), text("audit_event_id", input.auditEventId),
    ] }));
    if (row.status === "unavailable") {
      const nullable = ["workspace_id", "role", "authorization_version", "invitation_version"];
      if (nullable.some((name) => row[name] !== null) || !identityContext(row)) throw new PolicyCapabilityError("invalid_result");
      return Object.freeze({ status: "unavailable" });
    }
    if (row.status !== "accepted" && row.status !== "already_member") throw new PolicyCapabilityError("invalid_result");
    const membership = decodeMembership(row);
    if (!positive(row.invitation_version)) throw new PolicyCapabilityError("invalid_result");
    return Object.freeze({ status: row.status, membership, invitationVersion: row.invitation_version });
  }

  async revokeInvitation(input: { readonly authoritativeNowMs: number; readonly publicId: string; readonly expectedVersion: number; readonly auditEventId: string; readonly hostedGrant: VersionedHostedGrant }): Promise<Readonly<{ readonly status: "revoked" | "unavailable"; readonly publicId?: string; readonly version?: number }>> {
    const now = timestamp(input.authoritativeNowMs); const grant = hostedGrant(input.hostedGrant);
    if (now === undefined || !invitationId(input.publicId) || !positive(input.expectedVersion) || !auditId(input.auditEventId) || grant === undefined) {
      throw new PolicyCapabilityError("invalid_input");
    }
    const row = exactlyOne(await this.unit.execute({ sql: REVOKE_INVITATION_SQL, parameters: [
      blob("access_token_hash", this.#access), timestampParameter("authoritative_now", now), text("public_id", input.publicId), long("expected_version", input.expectedVersion),
      long("hosted_global_version", grant.hostedGlobalVersion), long("hosted_workspace_version", grant.hostedWorkspaceVersion), text("audit_event_id", input.auditEventId),
    ] }));
    if (row.status === "unavailable") {
      if (row.public_id !== null || row.state !== null || row.version !== null) throw new PolicyCapabilityError("invalid_result");
      return Object.freeze({ status: "unavailable" });
    }
    if (row.status !== "revoked" || row.public_id !== input.publicId || row.state !== "revoked" || !positive(row.version)) {
      throw new PolicyCapabilityError("invalid_result");
    }
    return Object.freeze({ status: "revoked", publicId: row.public_id, version: row.version });
  }

  async mutateMembership(input: {
    readonly authoritativeNowMs: number; readonly targetPrincipalCanonicalId: string; readonly expectedAuthorizationVersion: number;
    readonly expectedRole: WorkspaceRole; readonly expectedState: MembershipState; readonly requestedRole: WorkspaceRole;
    readonly requestedState: MembershipState; readonly auditEventId: string; readonly hostedGrant: VersionedHostedGrant;
  }): Promise<MembershipMutationCapability> {
    const now = timestamp(input.authoritativeNowMs); const grant = hostedGrant(input.hostedGrant);
    if (now === undefined || !canonicalPrincipal(input.targetPrincipalCanonicalId) || !positive(input.expectedAuthorizationVersion)
      || !workspaceRole(input.expectedRole) || !membershipState(input.expectedState) || !workspaceRole(input.requestedRole)
      || !membershipState(input.requestedState) || !auditId(input.auditEventId) || grant === undefined) throw new PolicyCapabilityError("invalid_input");
    return decodeMembership(exactlyOne(await this.unit.execute({ sql: MUTATE_MEMBERSHIP_SQL, parameters: [
      blob("access_token_hash", this.#access), timestampParameter("authoritative_now", now), text("target_principal_canonical_id", input.targetPrincipalCanonicalId),
      long("expected_authorization_version", input.expectedAuthorizationVersion), text("expected_role", input.expectedRole), text("expected_state", input.expectedState),
      text("requested_role", input.requestedRole), text("requested_state", input.requestedState), long("hosted_global_version", grant.hostedGlobalVersion),
      long("hosted_workspace_version", grant.hostedWorkspaceVersion), text("audit_event_id", input.auditEventId),
    ] })));
  }

  async mintCandidateIdentityProof(input: {
    readonly authoritativeNowMs: number; readonly verifiedReceiptDigest: string; readonly issuer: string; readonly purpose: "link-identity" | "unlink-identity";
    readonly candidateProofDigest: string; readonly expiresAtMs: number; readonly policyVersion: string;
  }): Promise<CandidateIdentityProofResult> {
    const now = timestamp(input.authoritativeNowMs); const receipt = digest(input.verifiedReceiptDigest); const candidate = digest(input.candidateProofDigest); const expires = timestamp(input.expiresAtMs);
    if (now === undefined || receipt === undefined || candidate === undefined || !bounded(input.issuer, 1, 512) || !identityPurpose(input.purpose)
      || expires === undefined || expires <= now || !Number.isSafeInteger(input.authoritativeNowMs) || !Number.isSafeInteger(input.expiresAtMs)
      || input.expiresAtMs > input.authoritativeNowMs + 300_000 || !bounded(input.policyVersion, 1, 64)) throw new PolicyCapabilityError("invalid_input");
    const row = exactlyOne(await this.unit.execute({ sql: MINT_CANDIDATE_PROOF_SQL, parameters: [
      blob("access_token_hash", this.#access), timestampParameter("authoritative_now", now), blob("verified_receipt_hash", receipt), text("expected_issuer", input.issuer),
      text("expected_purpose", input.purpose), blob("candidate_proof_hash", candidate), timestampParameter("expires_at", expires), text("policy_version", input.policyVersion),
    ] }));
    return decodeCandidateProof(row);
  }

  async mutateIdentity(input: {
    readonly authoritativeNowMs: number; readonly candidateProofDigest: string; readonly purpose: "link-identity" | "unlink-identity"; readonly deliberateConfirmation: true;
    readonly auditEventId: string; readonly notificationId: string; readonly identityReference: string; readonly policyVersion: string;
  }): Promise<IdentityMutationResult> {
    const now = timestamp(input.authoritativeNowMs); const proof = digest(input.candidateProofDigest);
    if (now === undefined || proof === undefined || !identityPurpose(input.purpose) || input.deliberateConfirmation !== true || !auditId(input.auditEventId)
      || !boundedIdentifier(input.notificationId, 16, 128) || !identityReference(input.identityReference) || !bounded(input.policyVersion, 1, 64)) {
      throw new PolicyCapabilityError("invalid_input");
    }
    const row = exactlyOne(await this.unit.execute({ sql: MUTATE_IDENTITY_SQL, parameters: [
      blob("access_token_hash", this.#access), timestampParameter("authoritative_now", now), blob("candidate_proof_hash", proof), text("purpose", input.purpose),
      boolean("deliberate_confirmation", true), text("audit_event_id", input.auditEventId), text("notification_id", input.notificationId),
      text("identity_reference", input.identityReference), text("policy_version", input.policyVersion),
    ] }));
    return decodeIdentityMutation(row);
  }

  async quotaSnapshot(input: { readonly authoritativeNowMs: number; readonly metric: QuotaMetric; readonly periodKey: string }): Promise<QuotaUsageCapability | undefined> {
    const now = timestamp(input.authoritativeNowMs);
    if (now === undefined || !quotaMetric(input.metric) || !periodKey(input.periodKey)) throw new PolicyCapabilityError("invalid_input");
    const result = await this.unit.execute({ sql: QUOTA_SNAPSHOT_SQL, parameters: [
      blob("access_token_hash", this.#access), timestampParameter("authoritative_now", now), text("metric", input.metric), text("period_key", input.periodKey),
    ] });
    if (result.rows.length === 0) return undefined;
    return decodeQuotaUsage(exactlyOne(result));
  }

  async reserveQuota(input: {
    readonly authoritativeNowMs: number; readonly metric: AllocatableQuotaMetric; readonly periodKey: string; readonly authorizationAction: QuotaAuthorizationAction;
    readonly resource?: Readonly<{ readonly kind: string; readonly id: string }>; readonly amount: number; readonly idempotencyKey: string; readonly policyVersion: number;
    readonly expiresAtMs: number; readonly hostedGrant: VersionedHostedGrant;
  }): Promise<QuotaReservationCapability> {
    const now = timestamp(input.authoritativeNowMs); const expires = timestamp(input.expiresAtMs); const grant = hostedGrant(input.hostedGrant);
    if (now === undefined || expires === undefined || expires <= now || !allocatableMetric(input.metric) || !periodKey(input.periodKey)
      || !matchesQuotaAction(input.metric, input.authorizationAction) || !positive(input.amount) || !bounded(input.idempotencyKey, 1, 200)
      || !positive(input.policyVersion) || grant === undefined || !resource(input.resource)) throw new PolicyCapabilityError("invalid_input");
    return decodeQuotaReservation(exactlyOne(await this.unit.execute({ sql: RESERVE_QUOTA_SQL, parameters: [
      blob("access_token_hash", this.#access), timestampParameter("authoritative_now", now), text("metric", input.metric), text("period_key", input.periodKey),
      text("authorization_action", input.authorizationAction), input.resource === undefined ? nil("resource_kind") : text("resource_kind", input.resource.kind),
      input.resource === undefined ? nil("resource_id") : text("resource_id", input.resource.id), long("amount", input.amount), text("idempotency_key", input.idempotencyKey),
      long("policy_version", input.policyVersion), timestampParameter("expires_at", expires), ...grantParameters(grant),
    ] })));
  }

  async finalizeQuota(input: { readonly authoritativeNowMs: number; readonly periodKey: string; readonly idempotencyKey: string; readonly actualAmount: number; readonly hostedGrant: VersionedHostedGrant }): Promise<QuotaReservationCapability> {
    const now = timestamp(input.authoritativeNowMs); const grant = hostedGrant(input.hostedGrant);
    if (now === undefined || !periodKey(input.periodKey) || !bounded(input.idempotencyKey, 1, 200) || !nonnegative(input.actualAmount) || grant === undefined) {
      throw new PolicyCapabilityError("invalid_input");
    }
    return decodeQuotaReservation(exactlyOne(await this.unit.execute({ sql: FINALIZE_QUOTA_SQL, parameters: [
      blob("access_token_hash", this.#access), timestampParameter("authoritative_now", now), text("period_key", input.periodKey), text("idempotency_key", input.idempotencyKey),
      long("actual_amount", input.actualAmount), ...grantParameters(grant),
    ] })));
  }

  async releaseQuota(input: { readonly authoritativeNowMs: number; readonly periodKey: string; readonly idempotencyKey: string; readonly reason: "released" | "expired"; readonly hostedGrant: VersionedHostedGrant }): Promise<QuotaReservationCapability> {
    const now = timestamp(input.authoritativeNowMs); const grant = hostedGrant(input.hostedGrant);
    if (now === undefined || !periodKey(input.periodKey) || !bounded(input.idempotencyKey, 1, 200) || (input.reason !== "released" && input.reason !== "expired") || grant === undefined) {
      throw new PolicyCapabilityError("invalid_input");
    }
    return decodeQuotaReservation(exactlyOne(await this.unit.execute({ sql: RELEASE_QUOTA_SQL, parameters: [
      blob("access_token_hash", this.#access), timestampParameter("authoritative_now", now), text("period_key", input.periodKey), text("idempotency_key", input.idempotencyKey),
      text("reason", input.reason), ...grantParameters(grant),
    ] })));
  }

  async readCurrentSubscription(input: { readonly authoritativeNowMs: number }): Promise<CurrentSubscriptionCapability | undefined> {
    const now = timestamp(input.authoritativeNowMs);
    if (now === undefined) throw new PolicyCapabilityError("invalid_input");
    const result = await this.unit.execute({ sql: READ_CURRENT_SUBSCRIPTION_SQL, parameters: [
      blob("access_token_hash", this.#access), timestampParameter("authoritative_now", now),
    ] });
    if (result.rows.length === 0) return undefined;
    return decodeSubscription(exactlyOne(result));
  }

  /** API-only, server-period-selected overview. The frozen capability returns
   * exactly the four lifetime dimensions plus the active portal period; no
   * caller can select a workspace, period, or subset of quota rows. */
  async readQuotaOverview(input: { readonly authoritativeNowMs: number }): Promise<readonly QuotaUsageCapability[]> {
    const now = timestamp(input.authoritativeNowMs);
    if (now === undefined) throw new PolicyCapabilityError("invalid_input");
    const result = await this.unit.execute({ sql: READ_QUOTA_OVERVIEW_SQL, parameters: [
      blob("access_token_hash", this.#access), timestampParameter("authoritative_now", now),
    ] });
    if (result.rows.length !== 5) throw new PolicyCapabilityError("invalid_result");
    const decoded = result.rows.map(decodeQuotaUsage);
    const workspace = decoded[0]?.workspaceInternalId;
    const policyVersion = decoded[0]?.policyVersion;
    if (workspace === undefined || policyVersion === undefined
      || decoded.some((entry) => entry.workspaceInternalId !== workspace || entry.policyVersion !== policyVersion)) {
      throw new PolicyCapabilityError("invalid_result");
    }
    const expected: readonly QuotaMetric[] = ["project_count", "member_count", "working_bytes", "raw_bytes", "portal_bytes"];
    const overview = expected.map((metric) => {
      const rows = decoded.filter((entry) => entry.metric === metric);
      if (rows.length !== 1) throw new PolicyCapabilityError("invalid_result");
      const row = rows[0]!;
      if ((metric === "portal_bytes" && row.periodKey === "roomscan-period-v1:lifetime")
        || (metric !== "portal_bytes" && row.periodKey !== "roomscan-period-v1:lifetime")) {
        throw new PolicyCapabilityError("invalid_result");
      }
      return row;
    });
    return Object.freeze(overview);
  }
}

/** Stripe ingress lane: durable receipt acceptance only. There is no read,
 * reconcile, membership, or API access surface on this class. */
export class DataApiStripeIngressCapabilityRepository {
  constructor(private readonly unit: CapabilitySqlUnit) {
    if (!validUnit(unit)) throw new PolicyCapabilityError("invalid_input");
  }

  async transaction<T>(work: (repository: this) => Promise<T>): Promise<T> {
    if (typeof work !== "function") throw new PolicyCapabilityError("invalid_input");
    return work(this);
  }

  async acceptVerifiedWebhook(input: {
    readonly accountMode: "platform" | "connected"; readonly accountId: string; readonly customerId: string; readonly subscriptionId: string;
    readonly eventId: string; readonly eventType: string; readonly objectId: string; readonly payloadSha256: string;
    readonly providerOccurredAtMs: number; readonly receivedAtMs: number;
  }): Promise<Readonly<{ readonly status: "accepted" | "duplicate"; readonly workspaceId: string; readonly generation: number }>> {
    const payload = billingDigest(input.payloadSha256); const occurred = timestamp(input.providerOccurredAtMs); const received = timestamp(input.receivedAtMs);
    if (!stripeAccountMode(input.accountMode) || !stripeAccountId(input.accountId) || !stripeCustomerId(input.customerId) || !stripeSubscriptionId(input.subscriptionId)
      || !stripeEventId(input.eventId) || !stripeSubscriptionEvent(input.eventType) || input.objectId !== input.subscriptionId
      || payload === undefined || occurred === undefined || received === undefined) throw new PolicyCapabilityError("invalid_input");
    const row = exactlyOne(await this.unit.execute({ sql: ACCEPT_STRIPE_EVENT_SQL, parameters: [
      text("account_mode", input.accountMode), text("provider_account_id", input.accountId), text("billing_customer_id", input.customerId), text("subscription_id", input.subscriptionId),
      text("event_id", input.eventId), text("event_type", input.eventType), text("object_id", input.objectId),
      blob("payload_sha256", payload), timestampParameter("provider_occurred_at", occurred), timestampParameter("received_at", received),
    ] }));
    if ((row.status !== "accepted" && row.status !== "duplicate") || !uuid(row.workspace_id) || !positive(row.generation)) {
      throw new PolicyCapabilityError("invalid_result");
    }
    return Object.freeze({ status: row.status, workspaceId: row.workspace_id, generation: row.generation });
  }
}

export interface StripeReconciliationClaim {
  readonly workspaceInternalId: string;
  readonly accountMode: "platform" | "connected";
  readonly accountId: string;
  readonly customerId: string;
  readonly subscriptionId: string;
  readonly generation: number;
  readonly leaseId: string;
  /** Immutable literal-true flag versions captured by the server-selected
   * claim. Completion must use these exact values, never an infrastructure or
   * caller supplied authority. */
  readonly hostedGlobalVersion: number;
  readonly hostedWorkspaceVersion: number;
  readonly lastEventType?: string;
  readonly lastObjectId?: string;
}

export class DataApiStripeReconciliationCapabilityRepository {
  constructor(private readonly unit: CapabilitySqlUnit) {
    if (!validUnit(unit)) throw new PolicyCapabilityError("invalid_input");
  }

  async transaction<T>(work: (repository: this) => Promise<T>): Promise<T> {
    if (typeof work !== "function") throw new PolicyCapabilityError("invalid_input");
    return work(this);
  }

  async claimReconciliation(leaseId: string, nowMs: number, leaseExpiresAtMs: number): Promise<StripeReconciliationClaim | undefined> {
    const now = timestamp(nowMs); const expires = timestamp(leaseExpiresAtMs);
    if (!leaseIdValue(leaseId) || now === undefined || expires === undefined || expires <= now) throw new PolicyCapabilityError("invalid_input");
    const result = await this.unit.execute({ sql: CLAIM_STRIPE_RECONCILIATION_SQL, parameters: [
      text("lease_id", leaseId), timestampParameter("claimed_at", now), timestampParameter("lease_expires_at", expires),
    ] });
    if (result.rows.length === 0) return undefined;
    const row = exactlyOne(result);
    if (!uuid(row.workspace_id) || !stripeAccountMode(row.account_mode) || !stripeAccountId(row.provider_account_id) || !stripeCustomerId(row.billing_customer_id) || !stripeSubscriptionId(row.subscription_id)
      || !positive(row.generation) || row.lease_id !== leaseId
      || !positive(row.hosted_global_version) || !positive(row.hosted_workspace_version)
      || ((row.last_event_type === null) !== (row.last_object_id === null))
      || (row.last_event_type !== null && (!stripeSubscriptionEvent(row.last_event_type) || !stripeSubscriptionId(row.last_object_id)))) {
      throw new PolicyCapabilityError("invalid_result");
    }
    return Object.freeze({
      workspaceInternalId: row.workspace_id, accountMode: row.account_mode, accountId: row.provider_account_id, customerId: row.billing_customer_id, subscriptionId: row.subscription_id, generation: row.generation, leaseId,
      hostedGlobalVersion: row.hosted_global_version, hostedWorkspaceVersion: row.hosted_workspace_version,
      ...(row.last_event_type === null ? {} : { lastEventType: row.last_event_type as string }), ...(row.last_object_id === null ? {} : { lastObjectId: row.last_object_id as string }),
    });
  }

  async releaseReconciliation(claim: StripeReconciliationClaim, releasedAtMs: number): Promise<boolean> {
    const released = timestamp(releasedAtMs);
    if (!validClaim(claim) || released === undefined) throw new PolicyCapabilityError("invalid_input");
    const row = exactlyOne(await this.unit.execute({ sql: RELEASE_STRIPE_RECONCILIATION_SQL, parameters: [
      text("lease_id", claim.leaseId), text("account_mode", claim.accountMode), text("provider_account_id", claim.accountId), text("billing_customer_id", claim.customerId), text("subscription_id", claim.subscriptionId), long("generation", claim.generation), timestampParameter("released_at", released),
    ] }));
    if (typeof row.released !== "boolean") throw new PolicyCapabilityError("invalid_result");
    return row.released;
  }

  async completeReconciliation(input: {
    readonly claim: StripeReconciliationClaim;
    readonly snapshot: Readonly<{ readonly observedAtMs: number; readonly status: SubscriptionStatus; readonly planKey: string; readonly currentPeriodEndMs?: number }>;
    readonly appliedAtMs: number;
  }): Promise<Readonly<{ readonly status: "applied" | "stale_claim" | "hosted_gate_rejected"; readonly needsAnotherGeneration: boolean }>> {
    const observed = timestamp(input.snapshot?.observedAtMs); const applied = timestamp(input.appliedAtMs); const periodEnd = input.snapshot?.currentPeriodEndMs === undefined ? undefined : timestamp(input.snapshot.currentPeriodEndMs);
    if (!validClaim(input.claim) || observed === undefined || applied === undefined || !subscriptionStatus(input.snapshot?.status) || !bounded(input.snapshot?.planKey, 1, 128)
      || (input.snapshot.currentPeriodEndMs !== undefined && periodEnd === undefined)) throw new PolicyCapabilityError("invalid_input");
    const row = exactlyOne(await this.unit.execute({ sql: COMPLETE_STRIPE_RECONCILIATION_SQL, parameters: [
      text("lease_id", input.claim.leaseId), text("account_mode", input.claim.accountMode), text("provider_account_id", input.claim.accountId), text("billing_customer_id", input.claim.customerId), text("subscription_id", input.claim.subscriptionId), long("generation", input.claim.generation),
      timestampParameter("source_observed_at", observed), text("subscription_status", input.snapshot.status), text("plan_key", input.snapshot.planKey),
      periodEnd === undefined ? nil("current_period_end") : timestampParameter("current_period_end", periodEnd), timestampParameter("applied_at", applied),
      long("hosted_global_version", input.claim.hostedGlobalVersion), long("hosted_workspace_version", input.claim.hostedWorkspaceVersion),
    ] }));
    if ((row.status !== "applied" && row.status !== "stale_claim" && row.status !== "hosted_gate_rejected") || typeof row.needs_another_generation !== "boolean") {
      throw new PolicyCapabilityError("invalid_result");
    }
    return Object.freeze({ status: row.status, needsAnotherGeneration: row.needs_another_generation });
  }
}

export type ProviderAuditLane = "apple" | "email" | "stripe";
export type ProviderAuditEventCode =
  | "apple.exchange.accepted" | "apple.exchange.rejected"
  | "email.challenge.accepted" | "email.challenge.rejected"
  | "email.delivery.accepted" | "email.delivery.failed"
  | "stripe.webhook.accepted" | "stripe.webhook.duplicate"
  | "stripe.reconciliation.applied" | "stripe.reconciliation.retried";

export class DataApiProviderAuditAcceptanceRepository {
  constructor(private readonly unit: CapabilitySqlUnit) {
    if (!validUnit(unit)) throw new PolicyCapabilityError("invalid_input");
  }

  async transaction<T>(work: (repository: this) => Promise<T>): Promise<T> {
    if (typeof work !== "function") throw new PolicyCapabilityError("invalid_input");
    return work(this);
  }

  async accept(input: { readonly id: string; readonly lane: ProviderAuditLane; readonly eventCode: ProviderAuditEventCode; readonly boundedReference: string; readonly occurredAtMs: number }): Promise<boolean> {
    const occurred = timestamp(input.occurredAtMs);
    if (!auditOutboxId(input.id) || !providerLane(input.lane) || !providerEventCode(input.eventCode)
      || !providerAuditLaneEvent(input.lane, input.eventCode) || !boundedReference(input.boundedReference) || occurred === undefined) {
      throw new PolicyCapabilityError("invalid_input");
    }
    const row = exactlyOne(await this.unit.execute({ sql: ACCEPT_PROVIDER_AUDIT_SQL, parameters: [
      text("id", input.id), text("provider_lane", input.lane), text("event_code", input.eventCode), text("bounded_reference", input.boundedReference), timestampParameter("occurred_at", occurred),
    ] }));
    if (typeof row.accepted !== "boolean") throw new PolicyCapabilityError("invalid_result");
    return row.accepted;
  }
}

export interface ProviderAuditEventLease {
  readonly id: string;
  readonly lane: ProviderAuditLane;
  readonly eventCode: ProviderAuditEventCode;
  readonly boundedReference: string;
  readonly occurredAtMs: number;
  readonly leaseId: string;
  readonly leaseExpiresAtMs: number;
  readonly deliveryAttempts: number;
}

/** Audit export lane only. It cannot accept ingress audits or access tenant API
 * data; its database role has claim/complete/release routines only. */
export class DataApiProviderAuditExportCapabilityRepository {
  constructor(private readonly unit: CapabilitySqlUnit) {
    if (!validUnit(unit)) throw new PolicyCapabilityError("invalid_input");
  }

  async transaction<T>(work: (repository: this) => Promise<T>): Promise<T> {
    if (typeof work !== "function") throw new PolicyCapabilityError("invalid_input");
    return work(this);
  }

  async claim(leaseId: string, nowMs: number, leaseExpiresAtMs: number): Promise<ProviderAuditEventLease | undefined> {
    const now = timestamp(nowMs); const expires = timestamp(leaseExpiresAtMs);
    if (!leaseIdValue(leaseId) || now === undefined || expires === undefined || expires <= now) throw new PolicyCapabilityError("invalid_input");
    const result = await this.unit.execute({ sql: CLAIM_PROVIDER_AUDIT_SQL, parameters: [
      text("lease_id", leaseId), timestampParameter("claimed_at", now), timestampParameter("lease_expires_at", expires),
    ] });
    if (result.rows.length === 0) return undefined;
    const row = exactlyOne(result);
    const occurred = canonicalTimestamp(row.occurred_at); const leaseExpiry = canonicalTimestamp(row.lease_expires_at);
    if (!auditOutboxId(row.id) || !providerLane(row.provider_lane) || !providerEventCode(row.event_code) || !boundedReference(row.bounded_reference)
      || row.state !== "leased" || row.lease_id !== leaseId || occurred === undefined || leaseExpiry === undefined || !nonnegative(row.delivery_attempts)
      || row.delivered_at !== null) throw new PolicyCapabilityError("invalid_result");
    return Object.freeze({ id: row.id, lane: row.provider_lane, eventCode: row.event_code, boundedReference: row.bounded_reference, occurredAtMs: occurred, leaseId, leaseExpiresAtMs: leaseExpiry, deliveryAttempts: row.delivery_attempts });
  }

  async complete(input: { readonly id: string; readonly leaseId: string; readonly deliveredAtMs: number }): Promise<boolean> {
    return this.#transition(COMPLETE_PROVIDER_AUDIT_SQL, input, "delivered_at", "completed");
  }

  async release(input: { readonly id: string; readonly leaseId: string; readonly releasedAtMs: number }): Promise<boolean> {
    return this.#transition(RELEASE_PROVIDER_AUDIT_SQL, input, "released_at", "released");
  }

  async #transition(
    sql: string,
    input: { readonly id: string; readonly leaseId: string; readonly deliveredAtMs?: number; readonly releasedAtMs?: number },
    atName: "delivered_at" | "released_at",
    resultName: "completed" | "released",
  ): Promise<boolean> {
    const atMs = atName === "delivered_at" ? input.deliveredAtMs : input.releasedAtMs;
    const at = timestamp(atMs);
    if (!auditOutboxId(input.id) || !leaseIdValue(input.leaseId) || at === undefined) throw new PolicyCapabilityError("invalid_input");
    const row = exactlyOne(await this.unit.execute({ sql, parameters: [text("id", input.id), text("lease_id", input.leaseId), timestampParameter(atName, at)] }));
    if (typeof row[resultName] !== "boolean") throw new PolicyCapabilityError("invalid_result");
    return row[resultName] as boolean;
  }
}

function validUnit(value: unknown): value is CapabilitySqlUnit {
  return value !== null && typeof value === "object" && typeof (value as CapabilitySqlUnit).execute === "function";
}
function exactlyOne(result: SqlResult): Readonly<Record<string, unknown>> {
  if (result.rows.length !== 1 || result.rows[0] === undefined) throw new PolicyCapabilityError("invalid_result");
  return result.rows[0];
}
function text(name: string, value: string): { readonly name: string; readonly value: SqlWireValue } { return { name, value: { kind: "string", value } }; }
function long(name: string, value: number): { readonly name: string; readonly value: SqlWireValue } { return { name, value: { kind: "long", value } }; }
function boolean(name: string, value: boolean): { readonly name: string; readonly value: SqlWireValue } { return { name, value: { kind: "boolean", value } }; }
function blob(name: string, value: Uint8Array): { readonly name: string; readonly value: SqlWireValue } { return { name, value: { kind: "blob", bytes: Uint8Array.from(value) } }; }
function nil(name: string): { readonly name: string; readonly value: SqlWireValue } { return { name, value: { kind: "null" } }; }
function timestampParameter(name: string, value: string): { readonly name: string; readonly value: SqlWireValue } { return text(name, value); }
function timestamp(value: unknown): string | undefined { try { return epochMillisecondsToIsoTimestamp(value as number); } catch (error) { if (error instanceof PersistenceCodecError) return undefined; throw error; } }
function canonicalTimestamp(value: unknown): number | undefined { if (typeof value !== "string") return undefined; const parsed = new Date(value); return Number.isSafeInteger(parsed.getTime()) && parsed.toISOString() === value ? parsed.getTime() : undefined; }
function digest(value: unknown): Uint8Array | undefined { try { return decodeOpaqueDigest(value as string); } catch (error) { if (error instanceof PersistenceCodecError) return undefined; throw error; } }
function billingDigest(value: unknown): Uint8Array | undefined { try { return decodeBillingPayloadSha256(value as string); } catch (error) { if (error instanceof PersistenceCodecError) return undefined; throw error; } }
function uuid(value: unknown): value is string { return typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu.test(value); }
function positive(value: unknown): value is number { return typeof value === "number" && Number.isSafeInteger(value) && value > 0; }
function nonnegative(value: unknown): value is number { return typeof value === "number" && Number.isSafeInteger(value) && value >= 0; }
function bounded(value: unknown, min: number, max: number): value is string { return typeof value === "string" && value.length >= min && value.length <= max; }
function boundedIdentifier(value: unknown, min: number, max: number): value is string { return bounded(value, min, max) && /^[A-Za-z0-9_-]+$/u.test(value); }
function flagKey(value: unknown): value is OperationalFlagKey { return value === "professional_sign_in_enabled" || value === "hosted_operations_enabled" || value === "publication_enabled"; }
function slug(value: unknown): value is string { return typeof value === "string" && /^[a-z0-9][a-z0-9-]{2,62}$/u.test(value); }
function canonicalPrincipal(value: unknown): value is string { return typeof value === "string" && /^prn_[A-Za-z0-9_-]{22,64}$/u.test(value); }
function familyId(value: unknown): value is string { return boundedIdentifier(value, 16, 128); }
function invitationId(value: unknown): value is string { return typeof value === "string" && /^inv_[A-Za-z0-9_-]{16,128}$/u.test(value); }
function auditId(value: unknown): value is string { return typeof value === "string" && /^aud_[A-Za-z0-9_-]{16,128}$/u.test(value); }
function identityReference(value: unknown): value is string { return typeof value === "string" && /^id_[A-Za-z0-9_-]{16,128}$/u.test(value); }
function invitableRole(value: unknown): value is Exclude<WorkspaceRole, "owner"> { return value === "admin" || value === "editor" || value === "viewer"; }
function workspaceRole(value: unknown): value is WorkspaceRole { return value === "owner" || invitableRole(value); }
function membershipState(value: unknown): value is MembershipState { return value === "invited" || value === "active" || value === "removed"; }
function identityPurpose(value: unknown): value is "link-identity" | "unlink-identity" { return value === "link-identity" || value === "unlink-identity"; }
function quotaMetric(value: unknown): value is QuotaMetric { return value === "project_count" || value === "member_count" || value === "working_bytes" || value === "raw_bytes" || value === "portal_bytes"; }
function allocatableMetric(value: unknown): value is AllocatableQuotaMetric { return value === "project_count" || value === "working_bytes" || value === "raw_bytes" || value === "portal_bytes"; }
function matchesQuotaAction(metric: AllocatableQuotaMetric, action: unknown): action is QuotaAuthorizationAction { return (metric === "project_count" && action === "project.create") || (metric === "working_bytes" && action === "project.revise") || (metric === "raw_bytes" && action === "raw_archive.allocate") || (metric === "portal_bytes" && action === "publication.create"); }
function periodKey(value: unknown): value is string { return typeof value === "string" && value.length >= 1 && value.length <= 128 && /^roomscan-period-v1:[A-Za-z0-9._:-]+$/u.test(value); }
function resource(value: unknown): value is Readonly<{ readonly kind: string; readonly id: string }> | undefined { return value === undefined || (value !== null && typeof value === "object" && bounded((value as { kind?: unknown }).kind, 1, 64) && /^[a-z][a-z0-9_.-]+$/u.test((value as { kind: string }).kind) && bounded((value as { id?: unknown }).id, 1, 512)); }
function hostedGrant(value: unknown): VersionedHostedGrant | undefined { if (value === null || typeof value !== "object" || !positive((value as VersionedHostedGrant).hostedGlobalVersion) || !positive((value as VersionedHostedGrant).hostedWorkspaceVersion)) return undefined; const global = (value as VersionedHostedGrant).publicationGlobalVersion; const workspace = (value as VersionedHostedGrant).publicationWorkspaceVersion; if ((global === undefined) !== (workspace === undefined) || (global !== undefined && (!positive(global) || !positive(workspace)))) return undefined; return value as VersionedHostedGrant; }
function grantParameters(grant: VersionedHostedGrant): readonly { readonly name: string; readonly value: SqlWireValue }[] { return [long("hosted_global_version", grant.hostedGlobalVersion), long("hosted_workspace_version", grant.hostedWorkspaceVersion), grant.publicationGlobalVersion === undefined ? nil("publication_global_version") : long("publication_global_version", grant.publicationGlobalVersion), grant.publicationWorkspaceVersion === undefined ? nil("publication_workspace_version") : long("publication_workspace_version", grant.publicationWorkspaceVersion)]; }
function subscriptionStatus(value: unknown): value is SubscriptionStatus { return value === "inactive" || value === "trialing" || value === "active" || value === "past_due" || value === "canceled" || value === "read_only_grace"; }
function leaseIdValue(value: unknown): value is string { return boundedIdentifier(value, 1, 128); }
function stripeAccountMode(value: unknown): value is "platform" | "connected" { return value === "platform" || value === "connected"; }
function stripeAccountId(value: unknown): value is string { return typeof value === "string" && /^acct_[A-Za-z0-9]{6,255}$/u.test(value); }
function stripeCustomerId(value: unknown): value is string { return typeof value === "string" && /^cus_[A-Za-z0-9]{6,255}$/u.test(value); }
function stripeSubscriptionId(value: unknown): value is string { return typeof value === "string" && /^sub_[A-Za-z0-9]{6,255}$/u.test(value); }
function stripeEventId(value: unknown): value is string { return typeof value === "string" && /^evt_[A-Za-z0-9]{6,255}$/u.test(value); }
function stripeSubscriptionEvent(value: unknown): value is string { return value === "customer.subscription.created" || value === "customer.subscription.deleted" || value === "customer.subscription.paused" || value === "customer.subscription.resumed" || value === "customer.subscription.trial_will_end" || value === "customer.subscription.updated"; }
function validClaim(value: unknown): value is StripeReconciliationClaim { return value !== null && typeof value === "object" && uuid((value as StripeReconciliationClaim).workspaceInternalId) && stripeAccountMode((value as StripeReconciliationClaim).accountMode) && stripeAccountId((value as StripeReconciliationClaim).accountId) && stripeCustomerId((value as StripeReconciliationClaim).customerId) && stripeSubscriptionId((value as StripeReconciliationClaim).subscriptionId) && positive((value as StripeReconciliationClaim).generation) && leaseIdValue((value as StripeReconciliationClaim).leaseId) && positive((value as StripeReconciliationClaim).hostedGlobalVersion) && positive((value as StripeReconciliationClaim).hostedWorkspaceVersion); }
function providerLane(value: unknown): value is ProviderAuditLane { return value === "apple" || value === "email" || value === "stripe"; }
function providerEventCode(value: unknown): value is ProviderAuditEventCode { return value === "apple.exchange.accepted" || value === "apple.exchange.rejected" || value === "email.challenge.accepted" || value === "email.challenge.rejected" || value === "email.delivery.accepted" || value === "email.delivery.failed" || value === "stripe.webhook.accepted" || value === "stripe.webhook.duplicate" || value === "stripe.reconciliation.applied" || value === "stripe.reconciliation.retried"; }
function providerAuditLaneEvent(lane: ProviderAuditLane, eventCode: ProviderAuditEventCode): boolean {
  return (lane === "apple" && (eventCode === "apple.exchange.accepted" || eventCode === "apple.exchange.rejected"))
    || (lane === "email" && (eventCode === "email.challenge.accepted" || eventCode === "email.challenge.rejected"
      || eventCode === "email.delivery.accepted" || eventCode === "email.delivery.failed"))
    || (lane === "stripe" && (eventCode === "stripe.webhook.accepted" || eventCode === "stripe.webhook.duplicate"
      || eventCode === "stripe.reconciliation.applied" || eventCode === "stripe.reconciliation.retried"));
}
function auditOutboxId(value: unknown): value is string { return typeof value === "string" && /^paud_[A-Za-z0-9_-]{12,124}$/u.test(value); }
function boundedReference(value: unknown): value is string { return typeof value === "string" && value.length >= 1 && value.length <= 128 && /^[A-Za-z0-9._:-]+$/u.test(value); }

function decodeFlag(row: Readonly<Record<string, unknown>>): OperationalFlagValue { if (typeof row.enabled !== "boolean" || !positive(row.version)) throw new PolicyCapabilityError("invalid_result"); return Object.freeze({ enabled: row.enabled, version: row.version }); }
function decodeInvitation(row: Readonly<Record<string, unknown>>): InvitationCapability {
  const expires = canonicalTimestamp(row.expires_at); const created = canonicalTimestamp(row.created_at); const updated = canonicalTimestamp(row.updated_at); const consumed = row.consumed_at === null ? undefined : canonicalTimestamp(row.consumed_at); const revoked = row.revoked_at === null ? undefined : canonicalTimestamp(row.revoked_at);
  if (!uuid(row.id) || !uuid(row.workspace_id) || !invitationId(row.public_id) || !invitableRole(row.invited_role) || (row.state !== "active" && row.state !== "consumed" && row.state !== "revoked") || !positive(row.version) || expires === undefined || created === undefined || updated === undefined || (row.consumed_at !== null && consumed === undefined) || (row.revoked_at !== null && revoked === undefined)) throw new PolicyCapabilityError("invalid_result");
  return Object.freeze({ internalId: row.id, workspaceInternalId: row.workspace_id, publicId: row.public_id, role: row.invited_role, state: row.state, version: row.version, expiresAtMs: expires, createdAtMs: created, updatedAtMs: updated, ...(consumed === undefined ? {} : { consumedAtMs: consumed }), ...(revoked === undefined ? {} : { revokedAtMs: revoked }) });
}
function identityContext(row: Readonly<Record<string, unknown>>): boolean { return uuid(row.principal_id) && canonicalPrincipal(row.principal_canonical_id) && uuid(row.family_id) && familyId(row.family_public_id); }
function decodeMembership(row: Readonly<Record<string, unknown>>): MembershipMutationCapability { if (!uuid(row.workspace_id) || !uuid(row.principal_id) || !canonicalPrincipal(row.principal_canonical_id) || !workspaceRole(row.role) || !membershipState(row.state) || !positive(row.authorization_version)) throw new PolicyCapabilityError("invalid_result"); return Object.freeze({ workspaceInternalId: row.workspace_id, principalInternalId: row.principal_id, principalCanonicalId: row.principal_canonical_id, role: row.role, state: row.state, authorizationVersion: row.authorization_version }); }
function decodeCandidateProof(row: Readonly<Record<string, unknown>>): CandidateIdentityProofResult {
  if (row.status === "recent_auth_required") { if (["principal_id", "principal_canonical_id", "family_id", "family_public_id", "proof_expires_at"].some((name) => row[name] !== null)) throw new PolicyCapabilityError("invalid_result"); return Object.freeze({ status: "recent_auth_required" }); }
  if (row.status === "unavailable") { if (!identityContext(row) || row.proof_expires_at !== null) throw new PolicyCapabilityError("invalid_result"); return Object.freeze({ status: "unavailable", principalInternalId: row.principal_id as string, principalCanonicalId: row.principal_canonical_id as string, familyInternalId: row.family_id as string, familyPublicId: row.family_public_id as string }); }
  const expires = canonicalTimestamp(row.proof_expires_at); if (row.status !== "minted" || !identityContext(row) || expires === undefined) throw new PolicyCapabilityError("invalid_result"); return Object.freeze({ status: "minted", principalInternalId: row.principal_id as string, principalCanonicalId: row.principal_canonical_id as string, familyInternalId: row.family_id as string, familyPublicId: row.family_public_id as string, proofExpiresAtMs: expires });
}
function decodeIdentityMutation(row: Readonly<Record<string, unknown>>): IdentityMutationResult {
  const noEpoch = row.authentication_epoch === null; const hasContext = identityContext(row); const epoch = nonnegative(row.authentication_epoch) ? row.authentication_epoch : undefined;
  if (row.status === "recent_auth_required") { if (hasContext || !noEpoch) throw new PolicyCapabilityError("invalid_result"); return Object.freeze({ status: "recent_auth_required" }); }
  if (row.status === "linked" || row.status === "unlinked") { if (!hasContext || epoch === undefined) throw new PolicyCapabilityError("invalid_result"); return Object.freeze({ status: row.status, principalInternalId: row.principal_id as string, principalCanonicalId: row.principal_canonical_id as string, familyInternalId: row.family_id as string, familyPublicId: row.family_public_id as string, authenticationEpoch: epoch }); }
  if (row.status === "already_linked" || row.status === "candidate_owned" || row.status === "not_linked" || row.status === "proof_unavailable" || row.status === "principal_unavailable" || row.status === "final_auth_method") { if (!hasContext || !noEpoch) throw new PolicyCapabilityError("invalid_result"); return Object.freeze({ status: row.status, principalInternalId: row.principal_id as string, principalCanonicalId: row.principal_canonical_id as string, familyInternalId: row.family_id as string, familyPublicId: row.family_public_id as string }); }
  throw new PolicyCapabilityError("invalid_result");
}
function decodeQuotaUsage(row: Readonly<Record<string, unknown>>): QuotaUsageCapability { const updated = canonicalTimestamp(row.updated_at); if (!uuid(row.workspace_id) || !quotaMetric(row.metric) || !periodKey(row.period_key) || !positive(row.policy_version) || !nonnegative(row.used) || !nonnegative(row.reserved) || !nonnegative(row.limit_value) || !positive(row.warning_threshold_percent) || row.warning_threshold_percent > 100 || !nonnegative(row.reconciliation_generation) || updated === undefined) throw new PolicyCapabilityError("invalid_result"); return Object.freeze({ workspaceInternalId: row.workspace_id, metric: row.metric, periodKey: row.period_key, policyVersion: row.policy_version, used: row.used, reserved: row.reserved, limit: row.limit_value, warningThresholdPercent: row.warning_threshold_percent, reconciliationGeneration: row.reconciliation_generation, updatedAtMs: updated }); }
function decodeQuotaReservation(row: Readonly<Record<string, unknown>>): QuotaReservationCapability { const expires = canonicalTimestamp(row.expires_at); const created = canonicalTimestamp(row.created_at); const finalized = row.finalized_at === null ? undefined : canonicalTimestamp(row.finalized_at); const released = row.released_at === null ? undefined : canonicalTimestamp(row.released_at); if (!uuid(row.workspace_id) || !periodKey(row.period_key) || !bounded(row.idempotency_key, 1, 200) || !allocatableMetric(row.metric) || !matchesQuotaAction(row.metric, row.authorization_action) || (row.resource_kind === null) !== (row.resource_id === null) || (row.resource_kind !== null && (!bounded(row.resource_kind, 1, 64) || !bounded(row.resource_id, 1, 512))) || !positive(row.requested_amount) || !positive(row.policy_version) || expires === undefined || created === undefined || (row.state !== "reserved" && row.state !== "finalized" && row.state !== "released")) throw new PolicyCapabilityError("invalid_result"); if ((row.finalized_amount !== null && !nonnegative(row.finalized_amount)) || (row.finalized_at !== null && finalized === undefined) || (row.released_at !== null && released === undefined) || (row.release_reason !== null && row.release_reason !== "released" && row.release_reason !== "expired")) throw new PolicyCapabilityError("invalid_result"); return Object.freeze({ workspaceInternalId: row.workspace_id, periodKey: row.period_key, idempotencyKey: row.idempotency_key, metric: row.metric, authorizationAction: row.authorization_action, ...(row.resource_kind === null ? {} : { resourceKind: row.resource_kind, resourceId: row.resource_id as string }), requestedAmount: row.requested_amount, policyVersion: row.policy_version, expiresAtMs: expires, state: row.state, createdAtMs: created, ...(row.finalized_amount === null ? {} : { finalizedAmount: row.finalized_amount as number }), ...(finalized === undefined ? {} : { finalizedAtMs: finalized }), ...(released === undefined ? {} : { releasedAtMs: released }), ...(row.release_reason === null ? {} : { releaseReason: row.release_reason as "released" | "expired" }) }); }
function decodeSubscription(row: Readonly<Record<string, unknown>>): CurrentSubscriptionCapability { const source = canonicalTimestamp(row.source_observed_at); const applied = canonicalTimestamp(row.applied_at); const end = row.current_period_end === null ? undefined : canonicalTimestamp(row.current_period_end); if (!uuid(row.workspace_id) || !bounded(row.provider_account_id, 1, 255) || !positive(row.reconciliation_generation) || !subscriptionStatus(row.status) || !bounded(row.plan_key, 1, 128) || source === undefined || applied === undefined || (row.current_period_end !== null && end === undefined)) throw new PolicyCapabilityError("invalid_result"); return Object.freeze({ workspaceInternalId: row.workspace_id, accountId: row.provider_account_id, generation: row.reconciliation_generation, status: row.status, planKey: row.plan_key, ...(end === undefined ? {} : { currentPeriodEndMs: end }), sourceObservedAtMs: source, appliedAtMs: applied }); }
