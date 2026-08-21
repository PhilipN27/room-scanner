import { createHmac } from "node:crypto";

export interface Clock {
  nowMs(): number;
}

export interface RandomSource {
  bytes(length: number): Uint8Array;
}

export type IdentityMutationPurpose = "link-identity" | "unlink-identity";

export interface IdentityLinkPolicy {
  readonly version: string;
  readonly recentAuthenticationMs: number;
  readonly verifiedAuthReceiptTtlMs: number;
  readonly candidateProofTtlMs: number;
  readonly notificationLeaseMs: number;
}

export const DEFAULT_IDENTITY_LINK_POLICY: IdentityLinkPolicy = {
  version: "identity-link-v2",
  recentAuthenticationMs: 5 * 60_000,
  verifiedAuthReceiptTtlMs: 60_000,
  candidateProofTtlMs: 5 * 60_000,
  notificationLeaseMs: 30_000,
};

export interface PrincipalRecord {
  readonly id: string;
  authenticationEpoch: number;
  readonly createdAtMs: number;
}

export interface ExternalIdentityRecord {
  readonly issuer: string;
  readonly subject: string;
  readonly principalId: string;
  readonly linkedAtMs: number;
}

export interface TrustedRecentSession {
  readonly principalId: string;
  readonly familyId: string;
  readonly authenticatedAtMs: number;
}

export interface RecentSessionVerifier {
  verifyRecentSession(accessToken: string): Promise<TrustedRecentSession>;
}

export interface VerifiedAuthenticationReceipt {
  readonly tokenHash: string;
  readonly issuer: string;
  readonly subject: string;
  readonly purpose: IdentityMutationPurpose;
  readonly initiatingPrincipalId: string;
  readonly initiatingFamilyId: string;
  readonly authenticatedAtMs: number;
  readonly issuedAtMs: number;
  readonly expiresAtMs: number;
  readonly policyVersion: string;
  state: "active" | "consumed";
  consumedAtMs?: number;
}

export interface VerifiedAuthenticationReceiptClaim {
  readonly tokenHash: string;
  readonly expectedIssuer: string;
  readonly expectedPurpose: IdentityMutationPurpose;
  readonly initiatingPrincipalId: string;
  readonly initiatingFamilyId: string;
  readonly nowMs: number;
}

export interface CandidateIdentityProof {
  readonly tokenHash: string;
  readonly issuer: string;
  readonly subject: string;
  readonly purpose: IdentityMutationPurpose;
  readonly initiatingPrincipalId: string;
  readonly initiatingFamilyId: string;
  readonly authenticatedAtMs: number;
  readonly issuedAtMs: number;
  readonly expiresAtMs: number;
  readonly policyVersion: string;
  state: "active" | "consumed";
  consumedAtMs?: number;
}

export interface CandidateProofClaim {
  readonly tokenHash: string;
  readonly purpose: IdentityMutationPurpose;
  readonly initiatingPrincipalId: string;
  readonly initiatingFamilyId: string;
  readonly nowMs: number;
}

export interface IdentityAuditEvent {
  readonly id: string;
  readonly eventCode: "identity.linked" | "identity.unlinked";
  readonly principalId: string;
  readonly authenticationEpoch: number;
  readonly identityReference: string;
  readonly createdAtMs: number;
  readonly policyVersion: string;
}

export interface SecurityNotificationOutboxRecord {
  readonly id: string;
  readonly eventCode: "identity.linked" | "identity.unlinked";
  readonly principalId: string;
  readonly identityReference: string;
  readonly createdAtMs: number;
  readonly policyVersion: string;
  state: "pending" | "leased" | "delivered";
  deliveryAttempts: number;
  leaseId?: string;
  leaseExpiresAtMs?: number;
  deliveredAtMs?: number;
}

export interface IdentityTransaction {
  findPrincipal(principalId: string): Promise<PrincipalRecord | undefined>;
  insertPrincipal(principal: PrincipalRecord): Promise<void>;
  findIdentity(issuer: string, subject: string): Promise<ExternalIdentityRecord | undefined>;
  identitiesForPrincipal(principalId: string): Promise<ExternalIdentityRecord[]>;
  insertIdentity(identity: ExternalIdentityRecord): Promise<void>;
  removeIdentity(issuer: string, subject: string): Promise<void>;
  insertVerifiedAuthenticationReceipt(receipt: VerifiedAuthenticationReceipt): Promise<void>;
  claimVerifiedAuthenticationReceipt(
    claim: VerifiedAuthenticationReceiptClaim,
  ): Promise<VerifiedAuthenticationReceipt | undefined>;
  insertCandidateProof(proof: CandidateIdentityProof): Promise<void>;
  claimCandidateProof(claim: CandidateProofClaim): Promise<CandidateIdentityProof | undefined>;
  bumpAuthenticationEpoch(principalId: string): Promise<number>;
  revokeOtherSessionFamilies(principalId: string, exceptFamilyId: string): Promise<void>;
  insertAuditEvent(event: IdentityAuditEvent): Promise<void>;
  insertSecurityNotification(record: SecurityNotificationOutboxRecord): Promise<void>;
  availableSecurityNotifications(
    nowMs: number,
    limit: number,
  ): Promise<SecurityNotificationOutboxRecord[]>;
  claimSecurityNotificationLease(
    id: string,
    leaseId: string,
    nowMs: number,
    leaseExpiresAtMs: number,
  ): Promise<SecurityNotificationOutboxRecord | undefined>;
  completeSecurityNotificationLease(
    id: string,
    leaseId: string,
    deliveredAtMs: number,
  ): Promise<boolean>;
  releaseSecurityNotificationLease(id: string, leaseId: string): Promise<boolean>;
}

export interface IdentityStore {
  transaction<T>(work: (transaction: IdentityTransaction) => Promise<T>): Promise<T>;
}

export interface CandidateIdentityProofMinter {
  mintFromVerifiedAuthentication(input: {
    readonly currentAccessToken: string;
    readonly verifiedAuthenticationReceiptToken: string;
    readonly expectedIssuer: string;
    readonly expectedPurpose: IdentityMutationPurpose;
  }): Promise<{ readonly candidateProofToken: string; readonly expiresAtMs: number }>;
}

export interface IdentityNotificationDeliveryPort {
  deliver(message: {
    readonly idempotencyKey: string;
    readonly eventCode: "identity.linked" | "identity.unlinked";
    readonly principalId: string;
  }): Promise<void>;
}

export type IdentityLinkErrorCode =
  | "invalid_identity"
  | "principal_not_found"
  | "confirmation_required"
  | "recent_auth_required"
  | "candidate_proof_required"
  | "candidate_owned"
  | "already_linked"
  | "final_auth_method"
  | "not_linked";

export class IdentityLinkError extends Error {
  constructor(readonly code: IdentityLinkErrorCode) {
    super(code);
    this.name = "IdentityLinkError";
  }
}

export class CanonicalIdentityService {
  constructor(
    private readonly dependencies: {
      readonly clock: Clock;
      readonly random: RandomSource;
      readonly store: IdentityStore;
    },
  ) {}

  async resolveOrCreate(identity: {
    readonly issuer: string;
    readonly subject: string;
  }): Promise<{ readonly principalId: string }> {
    if (!validIdentityPart(identity.issuer, 512) || !validIdentityPart(identity.subject, 512)) {
      throw new IdentityLinkError("invalid_identity");
    }
    return this.dependencies.store.transaction(async (transaction) => {
      const existing = await transaction.findIdentity(identity.issuer, identity.subject);
      if (existing !== undefined) {
        return { principalId: existing.principalId };
      }
      const nowMs = this.dependencies.clock.nowMs();
      const principalId = `prn_${Buffer.from(this.dependencies.random.bytes(16)).toString("base64url")}`;
      await transaction.insertPrincipal({
        id: principalId,
        authenticationEpoch: 0,
        createdAtMs: nowMs,
      });
      await transaction.insertIdentity({
        issuer: identity.issuer,
        subject: identity.subject,
        principalId,
        linkedAtMs: nowMs,
      });
      return { principalId };
    });
  }
}

export class CandidateIdentityProofService implements CandidateIdentityProofMinter {
  constructor(
    private readonly dependencies: {
      readonly clock: Clock;
      readonly random: RandomSource;
      readonly store: IdentityStore;
      readonly recentSessions: RecentSessionVerifier;
      readonly receiptHmacKey: Uint8Array;
      readonly proofHmacKey: Uint8Array;
      readonly policy: IdentityLinkPolicy;
    },
  ) {}

  async mintFromVerifiedAuthentication(input: {
    readonly currentAccessToken: string;
    readonly verifiedAuthenticationReceiptToken: string;
    readonly expectedIssuer: string;
    readonly expectedPurpose: IdentityMutationPurpose;
  }): Promise<{ readonly candidateProofToken: string; readonly expiresAtMs: number }> {
    if (
      !isOpaqueSecret(input.currentAccessToken) ||
      !isOpaqueSecret(input.verifiedAuthenticationReceiptToken) ||
      !validIdentityPart(input.expectedIssuer, 512) ||
      (input.expectedPurpose !== "link-identity" &&
        input.expectedPurpose !== "unlink-identity")
    ) {
      throw new IdentityLinkError("candidate_proof_required");
    }
    let initiatingSession: TrustedRecentSession;
    try {
      initiatingSession = await this.dependencies.recentSessions.verifyRecentSession(
        input.currentAccessToken,
      );
    } catch {
      throw new IdentityLinkError("recent_auth_required");
    }
    const nowMs = this.dependencies.clock.nowMs();
    if (
      !isTrustedRecentSession(
        initiatingSession,
        nowMs,
        this.dependencies.policy.recentAuthenticationMs,
      )
    ) {
      throw new IdentityLinkError("recent_auth_required");
    }
    const candidateProofToken = Buffer.from(
      this.dependencies.random.bytes(32),
    ).toString("base64url");
    const expiresAtMs = nowMs + this.dependencies.policy.candidateProofTtlMs;
    await this.dependencies.store.transaction(async (transaction) => {
      const receipt = await transaction.claimVerifiedAuthenticationReceipt({
        tokenHash: verifiedAuthenticationReceiptDigest(
          this.dependencies.receiptHmacKey,
          input.verifiedAuthenticationReceiptToken,
        ),
        expectedIssuer: input.expectedIssuer,
        expectedPurpose: input.expectedPurpose,
        initiatingPrincipalId: initiatingSession.principalId,
        initiatingFamilyId: initiatingSession.familyId,
        nowMs,
      });
      if (
        receipt === undefined ||
        !isRecent(
          receipt.authenticatedAtMs,
          nowMs,
          this.dependencies.policy.recentAuthenticationMs,
        ) ||
        receipt.expiresAtMs - receipt.issuedAtMs >
          this.dependencies.policy.verifiedAuthReceiptTtlMs
      ) {
        throw new IdentityLinkError("candidate_proof_required");
      }
      await transaction.insertCandidateProof({
        tokenHash: candidateProofDigest(
          this.dependencies.proofHmacKey,
          candidateProofToken,
        ),
        issuer: receipt.issuer,
        subject: receipt.subject,
        purpose: receipt.purpose,
        initiatingPrincipalId: initiatingSession.principalId,
        initiatingFamilyId: initiatingSession.familyId,
        authenticatedAtMs: receipt.authenticatedAtMs,
        issuedAtMs: nowMs,
        expiresAtMs,
        policyVersion: this.dependencies.policy.version,
        state: "active",
      });
    });
    return { candidateProofToken, expiresAtMs };
  }
}

export interface IdentityMutationInput {
  readonly currentAccessToken: string;
  readonly candidateProofToken: string;
  readonly confirmed: boolean;
}

export type LinkIdentityInput = IdentityMutationInput;
export type UnlinkIdentityInput = IdentityMutationInput;

export class IdentityLinkingService {
  constructor(
    private readonly dependencies: {
      readonly clock: Clock;
      readonly random: RandomSource;
      readonly store: IdentityStore;
      readonly recentSessions: RecentSessionVerifier;
      readonly proofHmacKey: Uint8Array;
      readonly auditHmacKey: Uint8Array;
      readonly policy: IdentityLinkPolicy;
    },
  ) {}

  async link(input: LinkIdentityInput): Promise<{
    readonly status: "linked";
    readonly authenticationEpoch: number;
  }> {
    const current = await this.verifyCurrentSession(input);
    const result = await this.mutate("link-identity", current, input.candidateProofToken);
    if (result.status !== "linked") {
      throw new Error("identity mutation result mismatch");
    }
    return result;
  }

  async unlink(input: UnlinkIdentityInput): Promise<{
    readonly status: "unlinked";
    readonly authenticationEpoch: number;
  }> {
    const current = await this.verifyCurrentSession(input);
    const result = await this.mutate("unlink-identity", current, input.candidateProofToken);
    if (result.status !== "unlinked") {
      throw new Error("identity mutation result mismatch");
    }
    return result;
  }

  private async verifyCurrentSession(
    input: IdentityMutationInput,
  ): Promise<TrustedRecentSession> {
    if (input.confirmed !== true) {
      throw new IdentityLinkError("confirmation_required");
    }
    if (!isOpaqueSecret(input.currentAccessToken) || !isOpaqueSecret(input.candidateProofToken)) {
      throw new IdentityLinkError("recent_auth_required");
    }
    let current: TrustedRecentSession;
    try {
      current = await this.dependencies.recentSessions.verifyRecentSession(
        input.currentAccessToken,
      );
    } catch {
      throw new IdentityLinkError("recent_auth_required");
    }
    if (
      !isTrustedRecentSession(
        current,
        this.dependencies.clock.nowMs(),
        this.dependencies.policy.recentAuthenticationMs,
      )
    ) {
      throw new IdentityLinkError("recent_auth_required");
    }
    return current;
  }

  private async mutate(
    purpose: IdentityMutationPurpose,
    current: TrustedRecentSession,
    candidateProofToken: string,
  ): Promise<
    | { readonly status: "linked"; readonly authenticationEpoch: number }
    | { readonly status: "unlinked"; readonly authenticationEpoch: number }
  > {
    const nowMs = this.dependencies.clock.nowMs();
    const proofHash = candidateProofDigest(
      this.dependencies.proofHmacKey,
      candidateProofToken,
    );
    return this.dependencies.store.transaction(async (transaction) => {
      if (await transaction.findPrincipal(current.principalId) === undefined) {
        throw new IdentityLinkError("principal_not_found");
      }
      const proof = await transaction.claimCandidateProof({
        tokenHash: proofHash,
        purpose,
        initiatingPrincipalId: current.principalId,
        initiatingFamilyId: current.familyId,
        nowMs,
      });
      if (
        proof === undefined ||
        !isRecent(
          proof.authenticatedAtMs,
          nowMs,
          this.dependencies.policy.recentAuthenticationMs,
        )
      ) {
        throw new IdentityLinkError("candidate_proof_required");
      }

      const owner = await transaction.findIdentity(proof.issuer, proof.subject);
      if (purpose === "link-identity") {
        if (owner?.principalId === current.principalId) {
          throw new IdentityLinkError("already_linked");
        }
        if (owner !== undefined) {
          throw new IdentityLinkError("candidate_owned");
        }
        await transaction.insertIdentity({
          issuer: proof.issuer,
          subject: proof.subject,
          principalId: current.principalId,
          linkedAtMs: nowMs,
        });
      } else {
        if (owner === undefined) {
          throw new IdentityLinkError("not_linked");
        }
        if (owner.principalId !== current.principalId) {
          throw new IdentityLinkError("candidate_owned");
        }
        if ((await transaction.identitiesForPrincipal(current.principalId)).length <= 1) {
          throw new IdentityLinkError("final_auth_method");
        }
        await transaction.removeIdentity(proof.issuer, proof.subject);
      }

      const authenticationEpoch = await transaction.bumpAuthenticationEpoch(current.principalId);
      await transaction.revokeOtherSessionFamilies(current.principalId, current.familyId);
      const eventCode = purpose === "link-identity" ? "identity.linked" : "identity.unlinked";
      const identityReference = `id_${keyedDigest(
        this.dependencies.auditHmacKey,
        `identity:${proof.issuer}\u0000${proof.subject}`,
      )}`;
      await transaction.insertAuditEvent({
        id: `aud_${randomId(this.dependencies.random, 16)}`,
        eventCode,
        principalId: current.principalId,
        authenticationEpoch,
        identityReference,
        createdAtMs: nowMs,
        policyVersion: this.dependencies.policy.version,
      });
      await transaction.insertSecurityNotification({
        id: `ntf_${randomId(this.dependencies.random, 16)}`,
        eventCode,
        principalId: current.principalId,
        identityReference,
        createdAtMs: nowMs,
        policyVersion: this.dependencies.policy.version,
        state: "pending",
        deliveryAttempts: 0,
      });
      return purpose === "link-identity"
        ? { authenticationEpoch, status: "linked" as const }
        : { authenticationEpoch, status: "unlinked" as const };
    });
  }
}

export class IdentityNotificationWorker {
  constructor(
    private readonly dependencies: {
      readonly clock: Clock;
      readonly random: RandomSource;
      readonly store: IdentityStore;
      readonly delivery: IdentityNotificationDeliveryPort;
      readonly policy: IdentityLinkPolicy;
    },
  ) {}

  async runOnce(limit: number): Promise<{ readonly attempted: number; readonly delivered: number }> {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 100) {
      throw new RangeError("invalid notification batch size");
    }
    const nowMs = this.dependencies.clock.nowMs();
    const pending = await this.dependencies.store.transaction(async (transaction) =>
      await transaction.availableSecurityNotifications(nowMs, limit),
    );
    let attempted = 0;
    let delivered = 0;
    for (const record of pending) {
      const leaseId = `nls_${randomId(this.dependencies.random, 16)}`;
      const leased = await this.dependencies.store.transaction(async (transaction) =>
        await transaction.claimSecurityNotificationLease(
          record.id,
          leaseId,
          this.dependencies.clock.nowMs(),
          this.dependencies.clock.nowMs() + this.dependencies.policy.notificationLeaseMs,
        ),
      );
      if (leased === undefined) {
        continue;
      }
      attempted += 1;
      try {
        await this.dependencies.delivery.deliver({
          idempotencyKey: leased.id,
          eventCode: leased.eventCode,
          principalId: leased.principalId,
        });
      } catch {
        await this.dependencies.store.transaction(async (transaction) =>
          await transaction.releaseSecurityNotificationLease(leased.id, leaseId),
        );
        continue;
      }
      const marked = await this.dependencies.store.transaction(async (transaction) =>
        await transaction.completeSecurityNotificationLease(
          leased.id,
          leaseId,
          this.dependencies.clock.nowMs(),
        ),
      );
      if (marked) {
        delivered += 1;
      }
    }
    return { attempted, delivered };
  }
}

function validIdentityPart(value: string, maximumLength: number): boolean {
  return value.trim().length > 0 && value.length <= maximumLength;
}

function randomId(random: RandomSource, length: number): string {
  return Buffer.from(random.bytes(length)).toString("base64url");
}

function keyedDigest(key: Uint8Array, value: string): string {
  return createHmac("sha256", key).update(value).digest("base64url");
}

function candidateProofDigest(key: Uint8Array, token: string): string {
  return keyedDigest(key, `candidate-proof:${token}`);
}

function verifiedAuthenticationReceiptDigest(key: Uint8Array, token: string): string {
  return keyedDigest(key, `verified-auth-receipt:${token}`);
}

function isOpaqueSecret(value: string): boolean {
  return /^[A-Za-z0-9_-]+$/u.test(value) && Buffer.from(value, "base64url").length === 32;
}

function isTrustedRecentSession(
  session: TrustedRecentSession,
  nowMs: number,
  maximumAgeMs: number,
): boolean {
  return (
    validIdentityPart(session.principalId, 256) &&
    validIdentityPart(session.familyId, 256) &&
    isRecent(session.authenticatedAtMs, nowMs, maximumAgeMs)
  );
}

function isRecent(authenticatedAtMs: number, nowMs: number, maximumAgeMs: number): boolean {
  return (
    Number.isFinite(authenticatedAtMs) &&
    authenticatedAtMs <= nowMs &&
    nowMs - authenticatedAtMs <= maximumAgeMs
  );
}
