import type { SqlResult, SqlStatement } from "../adapters/data-api.js";
import type { CapabilitySqlUnit } from "./capabilities.js";
import {
  PersistenceCodecError,
  decodeOpaqueDigest,
  epochMillisecondsToIsoTimestamp,
} from "./codecs.js";

/** Capability result parsing failures are deliberately indistinguishable from
 * unavailable server state at the outer HTTP boundary. A changed DB enum or
 * malformed Data API row must never be interpreted as an allow. */
export class AuthCapabilityError extends Error {
  constructor(readonly code: "invalid_input" | "invalid_result" | "unavailable") {
    super(code);
    this.name = "AuthCapabilityError";
  }
}

export type MagicPurpose = "sign-in" | "reauthenticate" | "link-identity" | "unlink-identity";
export type IdentityPurpose = "link-identity" | "unlink-identity";

export interface SealedMagicSecret {
  readonly iv: Uint8Array;
  readonly ciphertext: Uint8Array;
  readonly authenticationTag: Uint8Array;
}

export interface MagicRatePolicy {
  readonly cooldownSeconds: number;
  readonly maxActiveLinks: number;
  readonly addressWindowSeconds: number;
  readonly maxAddressWindow: number;
  readonly addressDaySeconds: number;
  readonly maxAddressDay: number;
  readonly networkWindowSeconds: number;
  readonly maxNetworkWindow: number;
}

export interface MagicChallengeInput {
  readonly selector: string;
  readonly secretDigest: string;
  readonly purpose: MagicPurpose;
  readonly deliveryIdentity: string;
  readonly addressDigest: string;
  readonly networkDigest: string;
  readonly authoritativeNowMs: number;
  readonly expiresAtMs: number;
  readonly policyVersion: string;
  readonly outboxId: string;
  readonly keyId: string;
  readonly sealedSecret: SealedMagicSecret;
  readonly ratePolicy: MagicRatePolicy;
}

/** v3 keeps the browser out of the session/receipt issuance path. The app
 * supplies only its RFC7636 S256 challenge; the server stores HMAC digests of
 * the app-held completion ID and eventual transfer code. */
export interface MagicCompletionChallengeInput extends MagicChallengeInput {
  readonly completionDigest: string;
  readonly codeChallenge: string;
  readonly maxCompletionFailures: number;
  readonly redeemNetworkWindowSeconds: number;
  readonly maxRedeemNetworkFailures: number;
}

export type MagicCompletionIssueResult =
  | Readonly<{ readonly status: "issued"; readonly selector: string; readonly expiresAtMs: number }>
  | Readonly<{ readonly status: "professional_sign_in_disabled" | "recent_auth_required" | "network_rate_limited" | "address_rate_limited" | "cooldown" }>;

export type MagicCompletionConsumeResult =
  | Readonly<{ readonly status: "confirmed" | "already_confirmed"; readonly purpose: MagicPurpose; readonly confirmedAtMs: number; readonly expiresAtMs: number }>
  | Readonly<{ readonly status: "unavailable" | "professional_sign_in_disabled" }>;

export interface MagicCompletionRedeemInput {
  readonly completionDigest: string;
  readonly codeChallenge: string;
  readonly transferCodeDigest: string;
  readonly expectedPurpose: MagicPurpose;
  readonly networkDigest: string;
  readonly authoritativeNowMs: number;
  /** Present only for link/unlink receipt issuance. */
  readonly receiptDigest?: string;
  readonly receiptExpiresAtMs?: number;
  /** Present only for sign-in/reauth session issuance. */
  readonly familyPublicId?: string;
  readonly accessTokenDigest?: string;
  readonly refreshTokenDigest?: string;
  readonly accessExpiresAtMs?: number;
  readonly inactivityExpiresAtMs?: number;
  readonly absoluteExpiresAtMs?: number;
  readonly sessionPolicyVersion?: string;
}

export type MagicCompletionRedeemResult =
  | Readonly<{ readonly status: "pending_confirmation" }>
  | Readonly<{
      readonly status: "session_issued" | "session_replayed";
      readonly purpose: "sign-in" | "reauthenticate";
      readonly principalInternalId: string;
      readonly principalCanonicalId: string;
      readonly familyInternalId: string;
      readonly familyPublicId: string;
      readonly authenticationEpoch: number;
      readonly workspaceInternalId?: string;
      readonly role?: "owner" | "admin" | "editor" | "viewer";
      readonly authorizationVersion?: number;
      readonly accessExpiresAtMs: number;
    }>
  | Readonly<{
      readonly status: "receipt_issued" | "receipt_replayed";
      readonly purpose: IdentityPurpose;
      readonly principalInternalId: string;
      readonly principalCanonicalId: string;
      readonly familyInternalId: string;
      readonly familyPublicId: string;
      readonly authenticationEpoch: number;
      readonly workspaceInternalId?: string;
      readonly role?: "owner" | "admin" | "editor" | "viewer";
      readonly authorizationVersion?: number;
      readonly receiptExpiresAtMs: number;
    }>
  | Readonly<{ readonly status: "unavailable" | "rate_limited" | "professional_sign_in_disabled" }>;

export interface AppleAttemptClaimed {
  readonly status: "claimed";
  readonly attemptId: string;
  readonly nonceDigest: string;
  readonly codeChallenge: string;
  readonly clientId: string;
  readonly redirectUri: string;
  readonly expiresAtMs: number;
  readonly policyVersion: string;
  readonly purpose: MagicPurpose;
}
export type AppleAttemptClaimResult = AppleAttemptClaimed | Readonly<{ readonly status: "invalid_attempt" | "replayed_code" }>;

export type AppleResultAcceptance =
  | Readonly<{ readonly status: "bridge_created"; readonly attemptId: string; readonly expiresAtMs: number }>
  | Readonly<{ readonly status: "receipt_created"; readonly attemptId: string; readonly purpose: IdentityPurpose; readonly expiresAtMs: number }>
  | Readonly<{ readonly status: "unavailable" }>;

export type AppleChallengeSessionResult =
  | Readonly<{
      readonly status: "issued";
      readonly principalInternalId: string;
      readonly principalCanonicalId: string;
      readonly familyInternalId: string;
      readonly familyPublicId: string;
      readonly authenticationEpoch: number;
      readonly authenticatedAtMs: number;
    }>
  | Readonly<{ readonly status: "unavailable" | "professional_sign_in_disabled" }>;

export interface AppleAttemptInput {
  readonly attemptId: string;
  readonly stateDigest: string;
  readonly nonceDigest: string;
  readonly codeChallenge: string;
  readonly clientId: string;
  readonly redirectUri: string;
  readonly authoritativeNowMs: number;
  readonly expiresAtMs: number;
  readonly policyVersion: string;
}
export type AppleAttemptCreateResult =
  | Readonly<{ readonly status: "created"; readonly attemptId: string; readonly purpose: MagicPurpose }>
  | Readonly<{ readonly status: "professional_sign_in_disabled" | "recent_auth_required" }>;

export type SessionLogoutResult =
  | Readonly<{
      readonly status: "revoked" | "already_revoked";
      readonly principalInternalId: string;
      readonly principalCanonicalId: string;
      readonly familyInternalId: string;
      readonly familyPublicId: string;
    }>
  | Readonly<{ readonly status: "unavailable" }>;
export type LogoutAllResult =
  | Readonly<{
      readonly status: "revoked";
      readonly principalInternalId: string;
      readonly principalCanonicalId: string;
      readonly authenticationEpoch: number;
      readonly revokedFamilyCount: number;
    }>
  | Readonly<{ readonly status: "unavailable" }>;
export type SessionTouchResult =
  | Readonly<{
      readonly status: "updated";
      readonly principalInternalId: string;
      readonly principalCanonicalId: string;
      readonly familyInternalId: string;
      readonly familyPublicId: string;
      readonly lastUsedAtMs: number;
      readonly inactivityExpiresAtMs: number;
    }>
  | Readonly<{ readonly status: "stale" | "unavailable" }>;

const ISSUE_MAGIC_COMPLETION_SQL = `SELECT * FROM roomscan.issue_magic_challenge_v3(
  (:initiating_access_token_hash)::bytea,
  (:authoritative_now)::timestamptz,
  :selector,
  (:secret_digest)::bytea,
  (:completion_hmac)::bytea,
  :code_challenge,
  :purpose,
  :delivery_identity,
  (:address_hash)::bytea,
  (:network_hash)::bytea,
  (:expires_at)::timestamptz,
  :policy_version,
  :outbox_id,
  :key_id,
  (:iv)::bytea,
  (:ciphertext)::bytea,
  (:authentication_tag)::bytea,
  (:cooldown_seconds)::integer,
  (:max_active_links)::integer,
  (:address_window_seconds)::integer,
  (:max_address_window)::integer,
  (:address_day_seconds)::integer,
  (:max_address_day)::integer,
  (:network_window_seconds)::integer,
  (:max_network_window)::integer,
  (:max_completion_failures)::integer,
  (:redeem_network_window_seconds)::integer,
  (:max_redeem_network_failures)::integer
)`;

const CONSUME_MAGIC_COMPLETION_SQL = `SELECT * FROM roomscan.consume_magic_challenge_v3(
  :selector,
  (:secret_digest)::bytea,
  :expected_purpose,
  (:authoritative_now)::timestamptz,
  (:transfer_code_digest)::bytea
)`;

const REDEEM_MAGIC_COMPLETION_SQL = `SELECT * FROM roomscan.redeem_magic_completion_v3(
  (:completion_hmac)::bytea,
  :code_challenge,
  (:transfer_code_digest)::bytea,
  :expected_purpose,
  (:network_hash)::bytea,
  (:authoritative_now)::timestamptz,
  (:receipt_hash)::bytea,
  (:receipt_expires_at)::timestamptz,
  :family_public_id,
  (:access_token_hash)::bytea,
  (:refresh_token_hash)::bytea,
  (:access_expires_at)::timestamptz,
  (:inactivity_expires_at)::timestamptz,
  (:absolute_expires_at)::timestamptz,
  :session_policy_version
)`;

const CREATE_APPLE_ATTEMPT_SQL = `SELECT * FROM roomscan.create_apple_attempt_v2(
  (:initiating_access_token_hash)::bytea,
  (:authoritative_now)::timestamptz,
  :attempt_id,
  (:state_hash)::bytea,
  (:nonce_hash)::bytea,
  :code_challenge,
  :client_id,
  :redirect_uri,
  (:expires_at)::timestamptz,
  :policy_version,
  :purpose
)`;

const CLAIM_APPLE_ATTEMPT_SQL = `SELECT * FROM roomscan.claim_apple_attempt_and_code(
  :attempt_id,
  (:state_hash)::bytea,
  :code_challenge,
  (:code_hash)::bytea,
  (:claimed_at)::timestamptz
)`;

const CLAIM_APPLE_NONCE_SQL = `SELECT roomscan.claim_apple_nonce(
  (:nonce_hash)::bytea,
  (:claimed_at)::timestamptz
) AS claimed`;

const ACCEPT_APPLE_RESULT_SQL = `SELECT * FROM roomscan.accept_apple_verified_result_v2(
  :attempt_id,
  :verified_issuer,
  :verified_subject,
  (:bridge_proof_hash)::bytea,
  (:receipt_hash)::bytea,
  (:authoritative_now)::timestamptz,
  (:expires_at)::timestamptz,
  :policy_version
)`;

const CONSUME_APPLE_BRIDGE_SQL = `SELECT * FROM roomscan.consume_apple_bridge_and_issue_session(
  (:bridge_proof_hash)::bytea,
  :family_public_id,
  (:access_token_hash)::bytea,
  (:refresh_token_hash)::bytea,
  (:authenticated_at)::timestamptz,
  (:issued_at)::timestamptz,
  (:access_expires_at)::timestamptz,
  (:inactivity_expires_at)::timestamptz,
  (:absolute_expires_at)::timestamptz,
  :policy_version
)`;

const LOGOUT_FROM_ACCESS_SQL = `SELECT * FROM roomscan.logout_from_access(
  (:access_token_hash)::bytea,
  (:revoked_at)::timestamptz,
  :reason_code
)`;
const LOGOUT_ALL_FROM_ACCESS_SQL = `SELECT * FROM roomscan.logout_all_from_access(
  (:access_token_hash)::bytea,
  (:authoritative_now)::timestamptz
)`;
const TOUCH_SESSION_FROM_ACCESS_SQL = `SELECT * FROM roomscan.touch_session_from_access(
  (:access_token_hash)::bytea,
  (:authoritative_now)::timestamptz,
  (:last_used_at)::timestamptz,
  (:inactivity_expires_at)::timestamptz
)`;

/**
 * API-lane auth capability surface. It deliberately excludes the Apple bridge
 * consumer; the auth-challenge runtime owns that separate class below.
 */
export class DataApiApiAuthCompositeRepository {
  readonly #boundAccessDigest: Uint8Array | undefined;

  constructor(
    private readonly unit: CapabilitySqlUnit,
    input: { readonly boundAccessDigest?: Uint8Array } = {},
  ) {
    if (unit === null || typeof unit !== "object" || typeof unit.execute !== "function"
      || (input.boundAccessDigest !== undefined && input.boundAccessDigest.length !== 32)) {
      throw new AuthCapabilityError("invalid_input");
    }
    this.#boundAccessDigest = input.boundAccessDigest === undefined
      ? undefined
      : Uint8Array.from(input.boundAccessDigest);
  }

  async transaction<T>(work: (repository: this) => Promise<T>): Promise<T> {
    if (typeof work !== "function") throw new AuthCapabilityError("invalid_input");
    return work(this);
  }

  async issuePublicMagicCompletionChallenge(input: MagicCompletionChallengeInput): Promise<MagicCompletionIssueResult> {
    if (input.purpose !== "sign-in" && input.purpose !== "reauthenticate") {
      throw new AuthCapabilityError("invalid_input");
    }
    return this.#issueMagicCompletion(undefined, input);
  }

  async issueBoundMagicCompletionChallenge(input: MagicCompletionChallengeInput): Promise<MagicCompletionIssueResult> {
    if (input.purpose !== "link-identity" && input.purpose !== "unlink-identity") {
      throw new AuthCapabilityError("invalid_input");
    }
    return this.#issueMagicCompletion(this.#requireBoundAccess(), input);
  }

  /** Browser confirmation only records a one-time handoff. It cannot mint a
   * session or receipt because it never sees the app-held verifier. */
  async consumeMagicCompletionChallenge(input: {
    readonly selector: string;
    readonly secretDigest: string;
    readonly expectedPurpose: MagicPurpose;
    readonly authoritativeNowMs: number;
    readonly transferCodeDigest: string;
  }): Promise<MagicCompletionConsumeResult> {
    const selector = exact(input.selector, 22, 22, /^[A-Za-z0-9_-]+$/u);
    const secret = digest(input.secretDigest);
    const purpose = magicPurpose(input.expectedPurpose) ? input.expectedPurpose : undefined;
    const now = timestamp(input.authoritativeNowMs);
    const transfer = digest(input.transferCodeDigest);
    if (selector === undefined || secret === undefined || purpose === undefined || now === undefined || transfer === undefined) {
      throw new AuthCapabilityError("invalid_input");
    }
    return decodeMagicCompletionConsume(await this.unit.execute({ sql: CONSUME_MAGIC_COMPLETION_SQL, parameters: [
      text("selector", selector), blob("secret_digest", secret), text("expected_purpose", purpose),
      timestampParameter("authoritative_now", now), blob("transfer_code_digest", transfer),
    ] }));
  }

  /** The DB reducer atomically enforces confirmed handoff, PKCE challenge,
   * transfer-code digest, rate limits, replay identity, session epoch, and
   * hosted kill switch. All material remains keyed hashes. */
  async redeemMagicCompletion(input: MagicCompletionRedeemInput): Promise<MagicCompletionRedeemResult> {
    const completion = digest(input.completionDigest);
    const challenge = s256(input.codeChallenge);
    const transfer = digest(input.transferCodeDigest);
    const purpose = magicPurpose(input.expectedPurpose) ? input.expectedPurpose : undefined;
    const network = digest(input.networkDigest);
    const now = timestamp(input.authoritativeNowMs);
    const receipt = input.receiptDigest === undefined ? undefined : digest(input.receiptDigest);
    const receiptExpiry = input.receiptExpiresAtMs === undefined ? undefined : timestamp(input.receiptExpiresAtMs);
    const family = input.familyPublicId === undefined ? undefined : identifier(input.familyPublicId, 16, 128);
    const access = input.accessTokenDigest === undefined ? undefined : digest(input.accessTokenDigest);
    const refresh = input.refreshTokenDigest === undefined ? undefined : digest(input.refreshTokenDigest);
    const accessExpiry = input.accessExpiresAtMs === undefined ? undefined : timestamp(input.accessExpiresAtMs);
    const inactivityExpiry = input.inactivityExpiresAtMs === undefined ? undefined : timestamp(input.inactivityExpiresAtMs);
    const absoluteExpiry = input.absoluteExpiresAtMs === undefined ? undefined : timestamp(input.absoluteExpiresAtMs);
    const policy = input.sessionPolicyVersion === undefined ? undefined : identifier(input.sessionPolicyVersion, 1, 64);
    const receiptBranch = identityPurpose(purpose);
    const sessionBranch = publicMagicPurpose(purpose) !== undefined;
    const receiptValid = receipt !== undefined && receiptExpiry !== undefined && receiptExpiry > now!;
    const sessionValid = family !== undefined && access !== undefined && refresh !== undefined && accessExpiry !== undefined
      && inactivityExpiry !== undefined && absoluteExpiry !== undefined && policy !== undefined && accessExpiry > now!
      && inactivityExpiry > now! && absoluteExpiry >= inactivityExpiry && accessExpiry <= absoluteExpiry
      && !Buffer.from(access).equals(Buffer.from(refresh));
    if (completion === undefined || challenge === undefined || transfer === undefined || purpose === undefined || network === undefined || now === undefined
      || (receiptBranch && (!receiptValid || family !== undefined || access !== undefined || refresh !== undefined || accessExpiry !== undefined || inactivityExpiry !== undefined || absoluteExpiry !== undefined || policy !== undefined))
      || (sessionBranch && (!sessionValid || receipt !== undefined || receiptExpiry !== undefined))
      || (!receiptBranch && !sessionBranch)) {
      throw new AuthCapabilityError("invalid_input");
    }
    return decodeMagicCompletionRedeem(await this.unit.execute({ sql: REDEEM_MAGIC_COMPLETION_SQL, parameters: [
      blob("completion_hmac", completion), text("code_challenge", challenge), blob("transfer_code_digest", transfer), text("expected_purpose", purpose),
      blob("network_hash", network), timestampParameter("authoritative_now", now),
      receipt === undefined ? nil("receipt_hash") : blob("receipt_hash", receipt), receiptExpiry === undefined ? nil("receipt_expires_at") : timestampParameter("receipt_expires_at", receiptExpiry),
      family === undefined ? nil("family_public_id") : text("family_public_id", family), access === undefined ? nil("access_token_hash") : blob("access_token_hash", access),
      refresh === undefined ? nil("refresh_token_hash") : blob("refresh_token_hash", refresh), accessExpiry === undefined ? nil("access_expires_at") : timestampParameter("access_expires_at", accessExpiry),
      inactivityExpiry === undefined ? nil("inactivity_expires_at") : timestampParameter("inactivity_expires_at", inactivityExpiry),
      absoluteExpiry === undefined ? nil("absolute_expires_at") : timestampParameter("absolute_expires_at", absoluteExpiry), policy === undefined ? nil("session_policy_version") : text("session_policy_version", policy),
    ] }));
  }

  async createPublicAppleAttempt(input: AppleAttemptInput): Promise<AppleAttemptCreateResult> {
    return this.#createAppleAttempt(undefined, input, "sign-in");
  }

  async createBoundAppleAttempt(
    input: AppleAttemptInput,
    purpose: IdentityPurpose,
  ): Promise<AppleAttemptCreateResult> {
    return this.#createAppleAttempt(this.#requireBoundAccess(), input, purpose);
  }

  async logoutCurrentSession(input: {
    readonly revokedAtMs: number;
    readonly reason: "logout" | "membership_changed" | "identity_changed";
  }): Promise<SessionLogoutResult> {
    const access = this.#requireBoundAccess();
    const revokedAt = timestamp(input.revokedAtMs);
    if (revokedAt === undefined || (input.reason !== "logout" && input.reason !== "membership_changed" && input.reason !== "identity_changed")) {
      throw new AuthCapabilityError("invalid_input");
    }
    const result = await this.unit.execute({
      sql: LOGOUT_FROM_ACCESS_SQL,
      parameters: [blob("access_token_hash", access), timestampParameter("revoked_at", revokedAt), text("reason_code", input.reason)],
    });
    return decodeSessionLogout(result);
  }

  async logoutAllCurrentSessions(input: { readonly authoritativeNowMs: number }): Promise<LogoutAllResult> {
    const access = this.#requireBoundAccess();
    const now = timestamp(input.authoritativeNowMs);
    if (now === undefined) throw new AuthCapabilityError("invalid_input");
    const result = await this.unit.execute({
      sql: LOGOUT_ALL_FROM_ACCESS_SQL,
      parameters: [blob("access_token_hash", access), timestampParameter("authoritative_now", now)],
    });
    return decodeLogoutAll(result);
  }

  async touchCurrentSession(input: {
    readonly authoritativeNowMs: number;
    readonly lastUsedAtMs: number;
    readonly inactivityExpiresAtMs: number;
  }): Promise<SessionTouchResult> {
    const access = this.#requireBoundAccess();
    const now = timestamp(input.authoritativeNowMs);
    const lastUsed = timestamp(input.lastUsedAtMs);
    const inactivity = timestamp(input.inactivityExpiresAtMs);
    if (now === undefined || lastUsed === undefined || inactivity === undefined || lastUsed > now || lastUsed >= inactivity) {
      throw new AuthCapabilityError("invalid_input");
    }
    const result = await this.unit.execute({
      sql: TOUCH_SESSION_FROM_ACCESS_SQL,
      parameters: [
        blob("access_token_hash", access), timestampParameter("authoritative_now", now),
        timestampParameter("last_used_at", lastUsed), timestampParameter("inactivity_expires_at", inactivity),
      ],
    });
    return decodeSessionTouch(result);
  }

  async claimAppleAttemptAndCode(input: {
    readonly attemptId: string;
    readonly stateDigest: string;
    readonly codeChallenge: string;
    readonly codeDigest: string;
    readonly claimedAtMs: number;
  }): Promise<AppleAttemptClaimResult> {
    const attemptId = identifier(input.attemptId, 16, 128);
    const codeChallenge = s256(input.codeChallenge);
    const state = digest(input.stateDigest);
    const code = digest(input.codeDigest);
    const claimedAt = timestamp(input.claimedAtMs);
    if (attemptId === undefined || codeChallenge === undefined || state === undefined || code === undefined || claimedAt === undefined) {
      throw new AuthCapabilityError("invalid_input");
    }
    const result = await this.unit.execute({
      sql: CLAIM_APPLE_ATTEMPT_SQL,
      parameters: [
        text("attempt_id", attemptId), blob("state_hash", state), text("code_challenge", codeChallenge),
        blob("code_hash", code), timestampParameter("claimed_at", claimedAt),
      ],
    });
    return decodeAppleAttemptClaim(result);
  }

  async claimAppleNonce(input: {
    readonly nonceDigest: string;
    readonly claimedAtMs: number;
  }): Promise<boolean> {
    const nonce = digest(input.nonceDigest);
    const claimedAt = timestamp(input.claimedAtMs);
    if (nonce === undefined || claimedAt === undefined) throw new AuthCapabilityError("invalid_input");
    const result = await this.unit.execute({
      sql: CLAIM_APPLE_NONCE_SQL,
      parameters: [blob("nonce_hash", nonce), timestampParameter("claimed_at", claimedAt)],
    });
    if (result.rows.length !== 1 || typeof result.rows[0]?.claimed !== "boolean") {
      throw new AuthCapabilityError("invalid_result");
    }
    return result.rows[0].claimed;
  }

  async acceptAppleSignInResult(input: {
    readonly attemptId: string;
    readonly issuer: "https://appleid.apple.com";
    readonly subject: string;
    readonly bridgeProofDigest: string;
    readonly authoritativeNowMs: number;
    readonly expiresAtMs: number;
    readonly policyVersion: string;
  }): Promise<AppleResultAcceptance> {
    return this.#acceptAppleResult({
      ...input,
      bridgeProofDigest: input.bridgeProofDigest,
      receiptDigest: undefined,
    });
  }

  async acceptAppleCandidateResult(input: {
    readonly attemptId: string;
    readonly issuer: "https://appleid.apple.com";
    readonly subject: string;
    readonly receiptDigest: string;
    readonly authoritativeNowMs: number;
    readonly expiresAtMs: number;
    readonly policyVersion: string;
  }): Promise<AppleResultAcceptance> {
    return this.#acceptAppleResult({
      ...input,
      bridgeProofDigest: undefined,
      receiptDigest: input.receiptDigest,
    });
  }

  async #issueMagicCompletion(
    initiatingAccess: Uint8Array | undefined,
    input: MagicCompletionChallengeInput,
  ): Promise<MagicCompletionIssueResult> {
    const selector = exact(input.selector, 22, 22, /^[A-Za-z0-9_-]+$/u);
    const secret = digest(input.secretDigest);
    const completion = digest(input.completionDigest);
    const challenge = s256(input.codeChallenge);
    const deliveryIdentity = exact(input.deliveryIdentity, 3, 320, /^[^\s]+$/u);
    const address = digest(input.addressDigest);
    const network = digest(input.networkDigest);
    const now = timestamp(input.authoritativeNowMs);
    const expires = timestamp(input.expiresAtMs);
    const policy = identifier(input.policyVersion, 1, 64);
    const outbox = identifier(input.outboxId, 16, 128);
    const key = exact(input.keyId, 1, 64, /^[A-Za-z0-9._-]+$/u);
    const iv = exactBytes(input.sealedSecret?.iv, 12);
    const ciphertext = exactBytes(input.sealedSecret?.ciphertext, 32);
    const tag = exactBytes(input.sealedSecret?.authenticationTag, 16);
    const rates = ratePolicy(input.ratePolicy);
    if (selector === undefined || secret === undefined || completion === undefined || challenge === undefined || deliveryIdentity === undefined
      || address === undefined || network === undefined || now === undefined || expires === undefined || expires <= now || policy === undefined
      || outbox === undefined || key === undefined || iv === undefined || ciphertext === undefined || tag === undefined || rates === undefined
      || !integerRange(input.maxCompletionFailures, 1, 10) || !integerRange(input.redeemNetworkWindowSeconds, 1, 86_400)
      || !integerRange(input.maxRedeemNetworkFailures, 1, 100)) {
      throw new AuthCapabilityError("invalid_input");
    }
    return decodeMagicCompletionIssue(await this.unit.execute({ sql: ISSUE_MAGIC_COMPLETION_SQL, parameters: [
      initiatingAccess === undefined ? nil("initiating_access_token_hash") : blob("initiating_access_token_hash", initiatingAccess),
      timestampParameter("authoritative_now", now), text("selector", selector), blob("secret_digest", secret), blob("completion_hmac", completion),
      text("code_challenge", challenge), text("purpose", input.purpose), text("delivery_identity", deliveryIdentity), blob("address_hash", address), blob("network_hash", network),
      timestampParameter("expires_at", expires), text("policy_version", policy), text("outbox_id", outbox), text("key_id", key),
      blob("iv", iv), blob("ciphertext", ciphertext), blob("authentication_tag", tag),
      integer("cooldown_seconds", rates.cooldownSeconds), integer("max_active_links", rates.maxActiveLinks),
      integer("address_window_seconds", rates.addressWindowSeconds), integer("max_address_window", rates.maxAddressWindow),
      integer("address_day_seconds", rates.addressDaySeconds), integer("max_address_day", rates.maxAddressDay),
      integer("network_window_seconds", rates.networkWindowSeconds), integer("max_network_window", rates.maxNetworkWindow),
      integer("max_completion_failures", input.maxCompletionFailures), integer("redeem_network_window_seconds", input.redeemNetworkWindowSeconds),
      integer("max_redeem_network_failures", input.maxRedeemNetworkFailures),
    ] }));
  }

  async #acceptAppleResult(input: {
    readonly attemptId: string;
    readonly issuer: "https://appleid.apple.com";
    readonly subject: string;
    readonly bridgeProofDigest: string | undefined;
    readonly receiptDigest: string | undefined;
    readonly authoritativeNowMs: number;
    readonly expiresAtMs: number;
    readonly policyVersion: string;
  }): Promise<AppleResultAcceptance> {
    const attemptId = identifier(input.attemptId, 16, 128);
    const subject = exact(input.subject, 1, 512, /^[^\s]+$/u);
    const bridge = input.bridgeProofDigest === undefined ? undefined : digest(input.bridgeProofDigest);
    const receipt = input.receiptDigest === undefined ? undefined : digest(input.receiptDigest);
    const now = timestamp(input.authoritativeNowMs);
    const expires = timestamp(input.expiresAtMs);
    const policy = identifier(input.policyVersion, 1, 64);
    if (attemptId === undefined || input.issuer !== "https://appleid.apple.com" || subject === undefined
      || (bridge === undefined) === (receipt === undefined) || now === undefined || expires === undefined || expires <= now || policy === undefined) {
      throw new AuthCapabilityError("invalid_input");
    }
    const result = await this.unit.execute({
      sql: ACCEPT_APPLE_RESULT_SQL,
      parameters: [
        text("attempt_id", attemptId), text("verified_issuer", input.issuer), text("verified_subject", subject),
        bridge === undefined ? nil("bridge_proof_hash") : blob("bridge_proof_hash", bridge),
        receipt === undefined ? nil("receipt_hash") : blob("receipt_hash", receipt),
        timestampParameter("authoritative_now", now), timestampParameter("expires_at", expires), text("policy_version", policy),
      ],
    });
    return decodeAppleResult(result);
  }

  async #createAppleAttempt(
    initiatingAccess: Uint8Array | undefined,
    input: AppleAttemptInput,
    purpose: MagicPurpose,
  ): Promise<AppleAttemptCreateResult> {
    const attemptId = identifier(input.attemptId, 16, 128);
    const state = digest(input.stateDigest);
    const nonce = digest(input.nonceDigest);
    const challenge = s256(input.codeChallenge);
    const client = exact(input.clientId, 1, 256, /^[A-Za-z0-9._-]+$/u);
    const redirect = exact(input.redirectUri, 1, 2048, /^https:\/\//u);
    const now = timestamp(input.authoritativeNowMs);
    const expires = timestamp(input.expiresAtMs);
    const policy = identifier(input.policyVersion, 1, 64);
    if (attemptId === undefined || state === undefined || nonce === undefined || challenge === undefined || client === undefined
      || redirect === undefined || now === undefined || expires === undefined || expires <= now || policy === undefined) {
      throw new AuthCapabilityError("invalid_input");
    }
    const result = await this.unit.execute({
      sql: CREATE_APPLE_ATTEMPT_SQL,
      parameters: [
        initiatingAccess === undefined ? nil("initiating_access_token_hash") : blob("initiating_access_token_hash", initiatingAccess),
        timestampParameter("authoritative_now", now), text("attempt_id", attemptId), blob("state_hash", state), blob("nonce_hash", nonce),
        text("code_challenge", challenge), text("client_id", client), text("redirect_uri", redirect),
        timestampParameter("expires_at", expires), text("policy_version", policy), text("purpose", purpose),
      ],
    });
    const row = exactlyOne(result);
    if (row.status === "created") {
      if (row.attempt_id !== attemptId || row.purpose !== purpose) throw new AuthCapabilityError("invalid_result");
      return Object.freeze({ status: "created", attemptId, purpose });
    }
    if (row.status === "professional_sign_in_disabled" || row.status === "recent_auth_required") {
      const nullable = ["attempt_id", "purpose", "principal_id", "principal_canonical_id", "family_id", "family_public_id"];
      if (nullable.some((name) => row[name] !== null)) throw new AuthCapabilityError("invalid_result");
      return Object.freeze({ status: row.status });
    }
    throw new AuthCapabilityError("invalid_result");
  }

  #requireBoundAccess(): Uint8Array {
    if (this.#boundAccessDigest === undefined) throw new AuthCapabilityError("unavailable");
    return Uint8Array.from(this.#boundAccessDigest);
  }
}

/** Challenge-lane-only bridge consumer. It is intentionally a different
 * concrete class so the API composition cannot acquire this method through a
 * type-compatible repository bundle. */
export class DataApiAppleChallengeRepository {
  constructor(private readonly unit: CapabilitySqlUnit) {
    if (unit === null || typeof unit !== "object" || typeof unit.execute !== "function") {
      throw new AuthCapabilityError("invalid_input");
    }
  }

  async transaction<T>(work: (repository: this) => Promise<T>): Promise<T> {
    if (typeof work !== "function") throw new AuthCapabilityError("invalid_input");
    return work(this);
  }

  async consumeAppleBridgeAndIssueSession(input: {
    readonly bridgeProofDigest: string;
    readonly familyPublicId: string;
    readonly accessTokenDigest: string;
    readonly refreshTokenDigest: string;
    readonly authenticatedAtMs: number;
    readonly issuedAtMs: number;
    readonly accessExpiresAtMs: number;
    readonly inactivityExpiresAtMs: number;
    readonly absoluteExpiresAtMs: number;
    readonly policyVersion: string;
  }): Promise<AppleChallengeSessionResult> {
    const bridge = digest(input.bridgeProofDigest);
    const family = identifier(input.familyPublicId, 16, 128);
    const access = digest(input.accessTokenDigest);
    const refresh = digest(input.refreshTokenDigest);
    const authenticatedAt = timestamp(input.authenticatedAtMs);
    const issuedAt = timestamp(input.issuedAtMs);
    const accessExpiry = timestamp(input.accessExpiresAtMs);
    const inactivityExpiry = timestamp(input.inactivityExpiresAtMs);
    const absoluteExpiry = timestamp(input.absoluteExpiresAtMs);
    const policy = identifier(input.policyVersion, 1, 64);
    if (bridge === undefined || family === undefined || access === undefined || refresh === undefined || authenticatedAt === undefined
      || issuedAt === undefined || accessExpiry === undefined || inactivityExpiry === undefined || absoluteExpiry === undefined || policy === undefined
      || authenticatedAt > issuedAt || issuedAt >= accessExpiry || issuedAt >= inactivityExpiry || inactivityExpiry > absoluteExpiry
      || Buffer.from(access).equals(Buffer.from(refresh))) {
      throw new AuthCapabilityError("invalid_input");
    }
    const result = await this.unit.execute({
      sql: CONSUME_APPLE_BRIDGE_SQL,
      parameters: [
        blob("bridge_proof_hash", bridge), text("family_public_id", family), blob("access_token_hash", access), blob("refresh_token_hash", refresh),
        timestampParameter("authenticated_at", authenticatedAt), timestampParameter("issued_at", issuedAt),
        timestampParameter("access_expires_at", accessExpiry), timestampParameter("inactivity_expires_at", inactivityExpiry),
        timestampParameter("absolute_expires_at", absoluteExpiry), text("policy_version", policy),
      ],
    });
    return decodeAppleChallengeSession(result);
  }
}

function decodeMagicCompletionIssue(result: SqlResult): MagicCompletionIssueResult {
  const row = exactlyOne(result);
  if (row.status === "issued") {
    const selector = exact(row.selector, 22, 22, /^[A-Za-z0-9_-]+$/u);
    const expiresAt = canonicalTimestamp(row.expires_at);
    if (selector === undefined || expiresAt === undefined) throw new AuthCapabilityError("invalid_result");
    return Object.freeze({ status: "issued", selector, expiresAtMs: expiresAt });
  }
  if (row.status === "professional_sign_in_disabled" || row.status === "recent_auth_required"
    || row.status === "network_rate_limited" || row.status === "address_rate_limited" || row.status === "cooldown") {
    if (row.selector !== null || row.expires_at !== null) throw new AuthCapabilityError("invalid_result");
    return Object.freeze({ status: row.status });
  }
  throw new AuthCapabilityError("invalid_result");
}

function decodeMagicCompletionConsume(result: SqlResult): MagicCompletionConsumeResult {
  const row = exactlyOne(result);
  if (row.status === "confirmed" || row.status === "already_confirmed") {
    const purpose = magicPurpose(row.purpose) ? row.purpose : undefined;
    const confirmedAt = canonicalTimestamp(row.confirmed_at);
    const expiresAt = canonicalTimestamp(row.expires_at);
    if (purpose === undefined || confirmedAt === undefined || expiresAt === undefined || confirmedAt > expiresAt) {
      throw new AuthCapabilityError("invalid_result");
    }
    return Object.freeze({ status: row.status, purpose, confirmedAtMs: confirmedAt, expiresAtMs: expiresAt });
  }
  if (row.status === "unavailable" || row.status === "professional_sign_in_disabled") {
    if (row.purpose !== null || row.confirmed_at !== null || row.expires_at !== null) throw new AuthCapabilityError("invalid_result");
    return Object.freeze({ status: row.status });
  }
  throw new AuthCapabilityError("invalid_result");
}

function decodeMagicCompletionRedeem(result: SqlResult): MagicCompletionRedeemResult {
  const row = exactlyOne(result);
  const nullContext = ["purpose", "principal_id", "principal_canonical_id", "family_id", "family_public_id", "authentication_epoch", "workspace_id", "role", "authorization_version", "access_expires_at", "receipt_expires_at"];
  if (row.status === "pending_confirmation") {
    if (nullContext.some((name) => row[name] !== null)) throw new AuthCapabilityError("invalid_result");
    return Object.freeze({ status: "pending_confirmation" });
  }
  if (row.status === "unavailable" || row.status === "rate_limited" || row.status === "professional_sign_in_disabled") {
    if (nullContext.some((name) => row[name] !== null)) throw new AuthCapabilityError("invalid_result");
    return Object.freeze({ status: row.status });
  }
  const principalInternalId = uuid(row.principal_id) ? row.principal_id : undefined;
  const principalCanonicalId = identifier(row.principal_canonical_id, 1, 128);
  const familyInternalId = uuid(row.family_id) ? row.family_id : undefined;
  const familyPublicId = identifier(row.family_public_id, 16, 128);
  const authenticationEpoch = nonnegativeInteger(row.authentication_epoch);
  const scope = decodeOptionalMagicScope(row);
  if (principalInternalId === undefined || principalCanonicalId === undefined || familyInternalId === undefined
    || familyPublicId === undefined || authenticationEpoch === undefined || scope === undefined) {
    throw new AuthCapabilityError("invalid_result");
  }
  if (row.status === "session_issued" || row.status === "session_replayed") {
    const purpose = publicMagicPurpose(row.purpose);
    const accessExpiresAt = canonicalTimestamp(row.access_expires_at);
    if (purpose === undefined || accessExpiresAt === undefined || row.receipt_expires_at !== null) throw new AuthCapabilityError("invalid_result");
    return Object.freeze({
      status: row.status, purpose, principalInternalId, principalCanonicalId, familyInternalId, familyPublicId,
      authenticationEpoch, ...scope, accessExpiresAtMs: accessExpiresAt,
    });
  }
  if (row.status === "receipt_issued" || row.status === "receipt_replayed") {
    const purpose = identityPurpose(row.purpose) ? row.purpose : undefined;
    const receiptExpiresAt = canonicalTimestamp(row.receipt_expires_at);
    if (purpose === undefined || receiptExpiresAt === undefined || row.access_expires_at !== null) throw new AuthCapabilityError("invalid_result");
    return Object.freeze({
      status: row.status, purpose, principalInternalId, principalCanonicalId, familyInternalId, familyPublicId,
      authenticationEpoch, ...scope, receiptExpiresAtMs: receiptExpiresAt,
    });
  }
  throw new AuthCapabilityError("invalid_result");
}

function decodeOptionalMagicScope(row: Readonly<Record<string, unknown>>):
  | Readonly<{ readonly workspaceInternalId?: string; readonly role?: "owner" | "admin" | "editor" | "viewer"; readonly authorizationVersion?: number }>
  | undefined {
  if (row.workspace_id === null && row.role === null && row.authorization_version === null) return Object.freeze({});
  const workspaceInternalId = uuid(row.workspace_id) ? row.workspace_id : undefined;
  const role = workspaceRole(row.role) ? row.role : undefined;
  const authorizationVersion = positiveInteger(row.authorization_version);
  if (workspaceInternalId === undefined || role === undefined || authorizationVersion === undefined) return undefined;
  return Object.freeze({ workspaceInternalId, role, authorizationVersion });
}

function decodeAppleAttemptClaim(result: SqlResult): AppleAttemptClaimResult {
  const row = exactlyOne(result);
  if (row.status === "invalid_attempt" || row.status === "replayed_code") {
    const nullable = ["attempt_id", "attempt_state_hash", "attempt_nonce_hash", "attempt_code_challenge", "expected_client_id", "redirect_uri", "created_at", "expires_at", "policy_version", "purpose", "initiating_principal_id", "initiating_family_id", "initiating_authenticated_at", "claimed_at"];
    if (nullable.some((name) => row[name] !== null)) throw new AuthCapabilityError("invalid_result");
    return Object.freeze({ status: row.status });
  }
  const attemptId = identifier(row.attempt_id, 16, 128);
  const nonce = exactBytes(row.attempt_nonce_hash, 32);
  const challenge = s256(row.attempt_code_challenge);
  const clientId = exact(row.expected_client_id, 1, 256, /^[A-Za-z0-9._-]+$/u);
  const redirectUri = exact(row.redirect_uri, 1, 2048, /^https:\/\//u);
  const expiresAt = canonicalTimestamp(row.expires_at);
  const policy = identifier(row.policy_version, 1, 64);
  if (row.status !== "claimed" || attemptId === undefined || nonce === undefined || challenge === undefined || clientId === undefined
    || redirectUri === undefined || expiresAt === undefined || policy === undefined || !magicPurpose(row.purpose)
    || !exactBytes(row.attempt_state_hash, 32) || canonicalTimestamp(row.created_at) === undefined || canonicalTimestamp(row.claimed_at) === undefined) {
    throw new AuthCapabilityError("invalid_result");
  }
  if (row.purpose === "sign-in") {
    if (row.initiating_principal_id !== null || row.initiating_family_id !== null || row.initiating_authenticated_at !== null) {
      throw new AuthCapabilityError("invalid_result");
    }
  } else if (!uuid(row.initiating_principal_id) || !uuid(row.initiating_family_id) || canonicalTimestamp(row.initiating_authenticated_at) === undefined) {
    throw new AuthCapabilityError("invalid_result");
  }
  return Object.freeze({
    status: "claimed",
    attemptId,
    nonceDigest: Buffer.from(nonce).toString("base64url"),
    codeChallenge: challenge,
    clientId,
    redirectUri,
    expiresAtMs: expiresAt,
    policyVersion: policy,
    purpose: row.purpose,
  });
}

function decodeSessionLogout(result: SqlResult): SessionLogoutResult {
  const row = exactlyOne(result);
  if (row.status === "unavailable") {
    if (["principal_id", "principal_canonical_id", "family_id", "family_public_id"].some((name) => row[name] !== null)) {
      throw new AuthCapabilityError("invalid_result");
    }
    return Object.freeze({ status: "unavailable" });
  }
  const principalInternalId = uuid(row.principal_id) ? row.principal_id : undefined;
  const principalCanonicalId = identifier(row.principal_canonical_id, 1, 128);
  const familyInternalId = uuid(row.family_id) ? row.family_id : undefined;
  const familyPublicId = identifier(row.family_public_id, 16, 128);
  if ((row.status !== "revoked" && row.status !== "already_revoked") || principalInternalId === undefined || principalCanonicalId === undefined
    || familyInternalId === undefined || familyPublicId === undefined) throw new AuthCapabilityError("invalid_result");
  return Object.freeze({ status: row.status, principalInternalId, principalCanonicalId, familyInternalId, familyPublicId });
}

function decodeLogoutAll(result: SqlResult): LogoutAllResult {
  const row = exactlyOne(result);
  if (row.status === "unavailable") {
    if (row.principal_id !== null || row.principal_canonical_id !== null || row.authentication_epoch !== null || row.revoked_family_count !== 0) {
      throw new AuthCapabilityError("invalid_result");
    }
    return Object.freeze({ status: "unavailable" });
  }
  const principalInternalId = uuid(row.principal_id) ? row.principal_id : undefined;
  const principalCanonicalId = identifier(row.principal_canonical_id, 1, 128);
  const epoch = nonnegativeInteger(row.authentication_epoch);
  const revokedFamilyCount = nonnegativeInteger(row.revoked_family_count);
  if (row.status !== "revoked" || principalInternalId === undefined || principalCanonicalId === undefined || epoch === undefined || revokedFamilyCount === undefined) {
    throw new AuthCapabilityError("invalid_result");
  }
  return Object.freeze({ status: "revoked", principalInternalId, principalCanonicalId, authenticationEpoch: epoch, revokedFamilyCount });
}

function decodeSessionTouch(result: SqlResult): SessionTouchResult {
  const row = exactlyOne(result);
  if (row.status === "unavailable") {
    const nullable = ["principal_id", "principal_canonical_id", "family_id", "family_public_id", "last_used_at", "inactivity_expires_at"];
    if (nullable.some((name) => row[name] !== null)) throw new AuthCapabilityError("invalid_result");
    return Object.freeze({ status: "unavailable" });
  }
  const principalInternalId = uuid(row.principal_id) ? row.principal_id : undefined;
  const principalCanonicalId = identifier(row.principal_canonical_id, 1, 128);
  const familyInternalId = uuid(row.family_id) ? row.family_id : undefined;
  const familyPublicId = identifier(row.family_public_id, 16, 128);
  if (row.status === "stale") {
    if (principalInternalId === undefined || principalCanonicalId === undefined || familyInternalId === undefined || familyPublicId === undefined
      || row.last_used_at !== null || row.inactivity_expires_at !== null) throw new AuthCapabilityError("invalid_result");
    return Object.freeze({ status: "stale" });
  }
  const lastUsedAt = canonicalTimestamp(row.last_used_at);
  const inactivityExpiresAt = canonicalTimestamp(row.inactivity_expires_at);
  if (row.status !== "updated" || principalInternalId === undefined || principalCanonicalId === undefined || familyInternalId === undefined
    || familyPublicId === undefined || lastUsedAt === undefined || inactivityExpiresAt === undefined || lastUsedAt >= inactivityExpiresAt) {
    throw new AuthCapabilityError("invalid_result");
  }
  return Object.freeze({ status: "updated", principalInternalId, principalCanonicalId, familyInternalId, familyPublicId, lastUsedAtMs: lastUsedAt, inactivityExpiresAtMs: inactivityExpiresAt });
}

function decodeAppleResult(result: SqlResult): AppleResultAcceptance {
  const row = exactlyOne(result);
  const attemptId = identifier(row.attempt_id, 16, 128);
  const expiresAt = canonicalTimestamp(row.expires_at);
  if (attemptId === undefined) throw new AuthCapabilityError("invalid_result");
  if (row.status === "unavailable") {
    if (row.purpose !== null || row.principal_id !== null || row.family_id !== null || row.expires_at !== null) {
      throw new AuthCapabilityError("invalid_result");
    }
    return Object.freeze({ status: "unavailable" });
  }
  if (row.status === "bridge_created") {
    if (row.purpose !== "sign-in" || row.principal_id !== null || row.family_id !== null || expiresAt === undefined) {
      throw new AuthCapabilityError("invalid_result");
    }
    return Object.freeze({ status: "bridge_created", attemptId, expiresAtMs: expiresAt });
  }
  if (row.status === "receipt_created") {
    if (!identityPurpose(row.purpose) || !uuid(row.principal_id) || !uuid(row.family_id) || expiresAt === undefined) {
      throw new AuthCapabilityError("invalid_result");
    }
    return Object.freeze({ status: "receipt_created", attemptId, purpose: row.purpose, expiresAtMs: expiresAt });
  }
  throw new AuthCapabilityError("invalid_result");
}

function decodeAppleChallengeSession(result: SqlResult): AppleChallengeSessionResult {
  const row = exactlyOne(result);
  if (row.status === "unavailable" || row.status === "professional_sign_in_disabled") {
    const nullable = ["principal_id", "principal_canonical_id", "family_id", "family_public_id", "authentication_epoch", "authenticated_at"];
    if (nullable.some((name) => row[name] !== null)) throw new AuthCapabilityError("invalid_result");
    return Object.freeze({ status: row.status });
  }
  const principalInternalId = uuid(row.principal_id) ? row.principal_id : undefined;
  const principalCanonicalId = identifier(row.principal_canonical_id, 1, 128);
  const familyInternalId = uuid(row.family_id) ? row.family_id : undefined;
  const familyPublicId = identifier(row.family_public_id, 16, 128);
  const epoch = nonnegativeInteger(row.authentication_epoch);
  const authenticatedAt = canonicalTimestamp(row.authenticated_at);
  if (row.status !== "issued" || principalInternalId === undefined || principalCanonicalId === undefined || familyInternalId === undefined
    || familyPublicId === undefined || epoch === undefined || authenticatedAt === undefined) {
    throw new AuthCapabilityError("invalid_result");
  }
  return Object.freeze({
    status: "issued", principalInternalId, principalCanonicalId, familyInternalId, familyPublicId,
    authenticationEpoch: epoch, authenticatedAtMs: authenticatedAt,
  });
}

function exactlyOne(result: SqlResult): Readonly<Record<string, unknown>> {
  if (result.rows.length !== 1 || result.rows[0] === undefined || typeof result.rows[0].status !== "string") {
    throw new AuthCapabilityError("invalid_result");
  }
  return result.rows[0];
}

function digest(value: unknown): Uint8Array | undefined {
  try { return typeof value === "string" ? decodeOpaqueDigest(value) : undefined; } catch { return undefined; }
}

function timestamp(value: unknown): string | undefined {
  try { return typeof value === "number" ? epochMillisecondsToIsoTimestamp(value) : undefined; } catch (error) {
    if (error instanceof PersistenceCodecError) return undefined;
    throw error;
  }
}

function canonicalTimestamp(value: unknown): number | undefined {
  if (typeof value !== "string") return undefined;
  const date = new Date(value);
  return Number.isSafeInteger(date.getTime()) && date.toISOString() === value ? date.getTime() : undefined;
}

function exact(value: unknown, min: number, max: number, pattern: RegExp): string | undefined {
  return typeof value === "string" && value.length >= min && value.length <= max && pattern.test(value) ? value : undefined;
}

function identifier(value: unknown, min: number, max: number): string | undefined {
  return exact(value, min, max, /^[A-Za-z0-9_-]+$/u);
}

function s256(value: unknown): string | undefined {
  return exact(value, 43, 43, /^[A-Za-z0-9_-]+$/u);
}

function exactBytes(value: unknown, length: number): Uint8Array | undefined {
  return value instanceof Uint8Array && value.length === length ? Uint8Array.from(value) : undefined;
}

function magicPurpose(value: unknown): value is MagicPurpose {
  return value === "sign-in" || value === "reauthenticate" || value === "link-identity" || value === "unlink-identity";
}

function identityPurpose(value: unknown): value is IdentityPurpose {
  return value === "link-identity" || value === "unlink-identity";
}

function publicMagicPurpose(value: unknown): "sign-in" | "reauthenticate" | undefined {
  return value === "sign-in" || value === "reauthenticate" ? value : undefined;
}

function uuid(value: unknown): value is string {
  return typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu.test(value);
}

function nonnegativeInteger(value: unknown): number | undefined {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : undefined;
}

function positiveInteger(value: unknown): number | undefined {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0 ? value : undefined;
}

function workspaceRole(value: unknown): value is "owner" | "admin" | "editor" | "viewer" {
  return value === "owner" || value === "admin" || value === "editor" || value === "viewer";
}

function ratePolicy(value: MagicRatePolicy | undefined): MagicRatePolicy | undefined {
  if (value === undefined || !integerRange(value.cooldownSeconds, 0, 3600) || !integerRange(value.maxActiveLinks, 1, 10)
    || !integerRange(value.addressWindowSeconds, 1, 86_400) || !integerRange(value.maxAddressWindow, 1, 100)
    || !integerRange(value.addressDaySeconds, 1, 172_800) || !integerRange(value.maxAddressDay, 1, 1_000)
    || !integerRange(value.networkWindowSeconds, 1, 86_400) || !integerRange(value.maxNetworkWindow, 1, 1_000)) return undefined;
  return value;
}

function integerRange(value: unknown, min: number, max: number): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= min && value <= max;
}

function text(name: string, value: string): SqlStatement["parameters"] extends readonly (infer T)[] | undefined ? T : never {
  return { name, value: { kind: "string", value } } as never;
}

function blob(name: string, value: Uint8Array): SqlStatement["parameters"] extends readonly (infer T)[] | undefined ? T : never {
  return { name, value: { kind: "blob", bytes: Uint8Array.from(value) } } as never;
}

function nil(name: string): SqlStatement["parameters"] extends readonly (infer T)[] | undefined ? T : never {
  return { name, value: { kind: "null" } } as never;
}

function timestampParameter(name: string, value: string): SqlStatement["parameters"] extends readonly (infer T)[] | undefined ? T : never {
  return { name, value: { kind: "string", value } } as never;
}

function integer(name: string, value: number): SqlStatement["parameters"] extends readonly (infer T)[] | undefined ? T : never {
  return { name, value: { kind: "long", value } } as never;
}
