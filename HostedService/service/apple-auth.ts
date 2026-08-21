import {
  createHash,
  createHmac,
  createPublicKey,
  timingSafeEqual,
  verify,
  type JsonWebKey,
} from "node:crypto";

import type {
  IdentityMutationPurpose,
  RecentSessionVerifier,
  TrustedRecentSession,
  VerifiedAuthenticationReceipt,
} from "./identity-linking.js";

export const APPLE_ISSUER = "https://appleid.apple.com";

export interface AppleAuthPolicy {
  readonly version: string;
  readonly attemptTtlMs: number;
  readonly clockSkewMs: number;
  readonly maxTokenAgeMs: number;
  readonly bridgeProofTtlMs: number;
  readonly verifiedAuthReceiptTtlMs: number;
}

export const DEFAULT_APPLE_AUTH_POLICY: AppleAuthPolicy = {
  version: "apple-auth-v1",
  attemptTtlMs: 5 * 60_000,
  clockSkewMs: 30_000,
  maxTokenAgeMs: 5 * 60_000,
  bridgeProofTtlMs: 60_000,
  verifiedAuthReceiptTtlMs: 60_000,
};

export type AppleAuthPurpose = "sign-in" | IdentityMutationPurpose;

export interface Clock {
  nowMs(): number;
}

export interface RandomSource {
  bytes(length: number): Uint8Array;
}

export interface AppleAuthAttempt {
  readonly id: string;
  readonly stateHash: string;
  nonceHash: string;
  readonly codeChallenge: string;
  readonly expectedClientId: string;
  readonly redirectUri: string;
  readonly createdAtMs: number;
  readonly expiresAtMs: number;
  readonly policyVersion: string;
  readonly purpose: AppleAuthPurpose;
  readonly initiatingPrincipalId?: string;
  readonly initiatingFamilyId?: string;
  readonly initiatingAuthenticatedAtMs?: number;
  state: "pending" | "claimed";
  claimedAtMs?: number;
}

export interface AppleAttemptClaim {
  readonly attemptId: string;
  readonly stateHash: string;
  readonly codeChallenge: string;
  readonly codeHash: string;
  readonly nowMs: number;
}

export type AppleAttemptClaimResult =
  | { readonly status: "claimed"; readonly attempt: AppleAuthAttempt }
  | { readonly status: "invalid_attempt" }
  | { readonly status: "replayed_code" };

export interface AppleBridgeProofRecord {
  readonly tokenHash: string;
  readonly issuer: string;
  readonly subject: string;
  readonly attemptId: string;
  readonly purpose: AppleAuthPurpose;
  readonly issuedAtMs: number;
  readonly expiresAtMs: number;
  readonly policyVersion: string;
  state: "active" | "consumed";
  consumedAtMs?: number;
}

export interface AppleBridgeProofClaim {
  readonly tokenHash: string;
  readonly issuer: string;
  readonly subject: string;
  readonly attemptId: string;
  readonly purpose: AppleAuthPurpose;
  readonly nowMs: number;
}

export interface AppleAuthTransaction {
  insertAttempt(attempt: AppleAuthAttempt): Promise<void>;
  findAttempt(attemptId: string): Promise<AppleAuthAttempt | undefined>;
  claimPendingAttemptAndCode(claim: AppleAttemptClaim): Promise<AppleAttemptClaimResult>;
  claimNonceIfUnused(nonceHash: string): Promise<boolean>;
  insertVerifiedAuthenticationReceipt(
    receipt: VerifiedAuthenticationReceipt,
  ): Promise<void>;
  insertBridgeProof(proof: AppleBridgeProofRecord): Promise<void>;
  claimBridgeProof(claim: AppleBridgeProofClaim): Promise<AppleBridgeProofRecord | undefined>;
}

export interface AppleAuthStore {
  transaction<T>(work: (transaction: AppleAuthTransaction) => Promise<T>): Promise<T>;
}

export interface AppleCodeExchangePort {
  exchange(input: {
    readonly code: string;
    readonly codeVerifier: string;
    readonly clientId: string;
    readonly redirectUri: string;
  }): Promise<{ readonly idToken: string }>;
}

export interface AppleJwk {
  readonly kty?: string;
  readonly kid?: string;
  readonly use?: string;
  readonly alg?: string;
  readonly n?: string;
  readonly e?: string;
  readonly [field: string]: unknown;
}

export interface AppleJwksPort {
  trustedKeys(forceRefresh: boolean): Promise<readonly AppleJwk[]>;
}

export interface CognitoIdentityBridge {
  authenticate(input: {
    readonly issuer: string;
    readonly subject: string;
    readonly internalProof: string;
    readonly attemptId: string;
    readonly purpose: "sign-in";
  }): Promise<{ readonly principalId: string }>;
}

export type AppleAuthErrorCode =
  | "invalid_request"
  | "invalid_attempt"
  | "replayed_code"
  | "replayed_nonce"
  | "exchange_failed"
  | "invalid_token"
  | "unknown_key";

export class AppleAuthError extends Error {
  constructor(readonly code: AppleAuthErrorCode) {
    super(code);
    this.name = "AppleAuthError";
  }
}

export interface AppleAuthServiceDependencies {
  readonly clock: Clock;
  readonly random: RandomSource;
  readonly store: AppleAuthStore;
  readonly exchange: AppleCodeExchangePort;
  readonly jwks: AppleJwksPort;
  readonly bridge: CognitoIdentityBridge;
  readonly recentSessions: RecentSessionVerifier;
  readonly stateHmacKey: Uint8Array;
  readonly receiptHmacKey: Uint8Array;
  readonly proofHmacKey: Uint8Array;
  readonly verifiedAuthenticationReceiptHmacKey: Uint8Array;
  readonly policy: AppleAuthPolicy;
  readonly expectedClientId: string;
  readonly redirectUri: string;
}

export interface AppleBeginResult {
  readonly attemptId: string;
  readonly state: string;
  readonly nonce: string;
  readonly expiresAtMs: number;
}

export interface AppleFinishResult {
  readonly principalId?: string;
  readonly status?: "verified-auth-receipt";
  readonly verifiedAuthenticationReceiptToken?: string;
  readonly expiresAtMs?: number;
  readonly identity: {
    readonly issuer: string;
    readonly subject: string;
    readonly emailMetadata?: {
      readonly email: string;
      readonly verified: boolean;
      readonly isPrivateRelay: boolean;
    };
  };
}

export class AppleAuthService {
  constructor(private readonly dependencies: AppleAuthServiceDependencies) {}

  async begin(input: {
    readonly codeChallenge: string;
  }): Promise<AppleBeginResult> {
    return this.beginInternal(input.codeChallenge, "sign-in", undefined);
  }

  async beginCandidate(input: {
    readonly currentAccessToken: string;
    readonly codeChallenge: string;
    readonly purpose: IdentityMutationPurpose;
  }): Promise<AppleBeginResult> {
    if (input.purpose !== "link-identity" && input.purpose !== "unlink-identity") {
      throw new AppleAuthError("invalid_request");
    }
    let initiatingSession: TrustedRecentSession;
    try {
      initiatingSession = await this.dependencies.recentSessions.verifyRecentSession(
        input.currentAccessToken,
      );
    } catch {
      throw new AppleAuthError("invalid_attempt");
    }
    if (
      initiatingSession.principalId.length === 0 ||
      initiatingSession.familyId.length === 0 ||
      !Number.isFinite(initiatingSession.authenticatedAtMs)
    ) {
      throw new AppleAuthError("invalid_attempt");
    }
    return this.beginInternal(input.codeChallenge, input.purpose, initiatingSession);
  }

  private async beginInternal(
    codeChallenge: string,
    purpose: AppleAuthPurpose,
    initiatingSession: TrustedRecentSession | undefined,
  ): Promise<AppleBeginResult> {
    if (
      !/^[A-Za-z0-9_-]{43}$/u.test(codeChallenge) ||
      this.dependencies.expectedClientId.length === 0 ||
      this.dependencies.expectedClientId.length > 256 ||
      this.dependencies.redirectUri.length === 0 ||
      this.dependencies.redirectUri.length > 2_048 ||
      !this.dependencies.redirectUri.startsWith("https://")
    ) {
      throw new AppleAuthError("invalid_request");
    }
    const nowMs = this.dependencies.clock.nowMs();
    const attemptId = Buffer.from(this.dependencies.random.bytes(16)).toString("base64url");
    const state = Buffer.from(this.dependencies.random.bytes(32)).toString("base64url");
    const nonce = Buffer.from(this.dependencies.random.bytes(32)).toString("base64url");
    const attempt: AppleAuthAttempt = {
      id: attemptId,
      stateHash: keyedDigest(this.dependencies.stateHmacKey, `state:${state}`),
      nonceHash: keyedDigest(this.dependencies.stateHmacKey, `nonce:${nonce}`),
      codeChallenge,
      expectedClientId: this.dependencies.expectedClientId,
      redirectUri: this.dependencies.redirectUri,
      createdAtMs: nowMs,
      expiresAtMs: nowMs + this.dependencies.policy.attemptTtlMs,
      policyVersion: this.dependencies.policy.version,
      purpose,
      state: "pending",
      ...(initiatingSession === undefined
        ? {}
        : {
            initiatingPrincipalId: initiatingSession.principalId,
            initiatingFamilyId: initiatingSession.familyId,
            initiatingAuthenticatedAtMs: initiatingSession.authenticatedAtMs,
          }),
    };
    await this.dependencies.store.transaction(async (transaction) => {
      await transaction.insertAttempt(attempt);
    });
    return { attemptId, state, nonce, expiresAtMs: attempt.expiresAtMs };
  }

  async finish(input: {
    readonly attemptId: string;
    readonly state: string;
    readonly code: string;
    readonly codeVerifier: string;
    readonly clientClaims?: Readonly<Record<string, unknown>>;
  }): Promise<AppleFinishResult> {
    void input.clientClaims;
    if (
      input.attemptId.length === 0 ||
      input.state.length === 0 ||
      input.code.length === 0 ||
      input.code.length > 4_096 ||
      !/^[A-Za-z0-9\-._~]{43,128}$/u.test(input.codeVerifier)
    ) {
      throw new AppleAuthError("invalid_attempt");
    }
    const nowMs = this.dependencies.clock.nowMs();
    const stateHash = keyedDigest(this.dependencies.stateHmacKey, `state:${input.state}`);
    const codeHash = keyedDigest(this.dependencies.receiptHmacKey, `code:${input.code}`);
    const codeChallenge = createHash("sha256")
      .update(input.codeVerifier)
      .digest("base64url");
    const claim = await this.dependencies.store.transaction(async (transaction) => {
      return await transaction.claimPendingAttemptAndCode({
        attemptId: input.attemptId,
        stateHash,
        codeChallenge,
        codeHash,
        nowMs,
      });
    });
    if (claim.status !== "claimed") {
      throw new AppleAuthError(claim.status);
    }

    let idToken: string;
    try {
      const exchangeResult = await this.dependencies.exchange.exchange({
        code: input.code,
        codeVerifier: input.codeVerifier,
        clientId: claim.attempt.expectedClientId,
        redirectUri: claim.attempt.redirectUri,
      });
      idToken = exchangeResult.idToken;
    } catch {
      throw new AppleAuthError("exchange_failed");
    }

    const postExchangeNowMs = this.dependencies.clock.nowMs();
    if (claim.attempt.expiresAtMs <= postExchangeNowMs) {
      throw new AppleAuthError("invalid_attempt");
    }

    const identity = await this.verifyIdToken(
      idToken,
      claim.attempt.expectedClientId,
      claim.attempt.nonceHash,
    );
    if (claim.attempt.expiresAtMs <= this.dependencies.clock.nowMs()) {
      throw new AppleAuthError("invalid_attempt");
    }
    const credential = await this.dependencies.store.transaction(async (transaction) => {
      if (!await transaction.claimNonceIfUnused(claim.attempt.nonceHash)) {
        return { status: "replayed_nonce" as const };
      }
      const issuedAtMs = this.dependencies.clock.nowMs();
      if (claim.attempt.expiresAtMs <= issuedAtMs) {
        return { status: "invalid_attempt" as const };
      }
      if (claim.attempt.purpose !== "sign-in") {
        if (
          claim.attempt.initiatingPrincipalId === undefined ||
          claim.attempt.initiatingFamilyId === undefined ||
          claim.attempt.initiatingAuthenticatedAtMs === undefined
        ) {
          return { status: "invalid_attempt" as const };
        }
        const verifiedAuthenticationReceiptToken = Buffer.from(
          this.dependencies.random.bytes(32),
        ).toString("base64url");
        const expiresAtMs =
          issuedAtMs + this.dependencies.policy.verifiedAuthReceiptTtlMs;
        await transaction.insertVerifiedAuthenticationReceipt({
          tokenHash: keyedDigest(
            this.dependencies.verifiedAuthenticationReceiptHmacKey,
            `verified-auth-receipt:${verifiedAuthenticationReceiptToken}`,
          ),
          issuer: identity.issuer,
          subject: identity.subject,
          purpose: claim.attempt.purpose,
          initiatingPrincipalId: claim.attempt.initiatingPrincipalId,
          initiatingFamilyId: claim.attempt.initiatingFamilyId,
          authenticatedAtMs: issuedAtMs,
          issuedAtMs,
          expiresAtMs,
          policyVersion: this.dependencies.policy.version,
          state: "active",
        });
        return {
          status: "verified-auth-receipt" as const,
          verifiedAuthenticationReceiptToken,
          expiresAtMs,
        };
      }

      const internalProof = Buffer.from(this.dependencies.random.bytes(32)).toString(
        "base64url",
      );
      const expiresAtMs = issuedAtMs + this.dependencies.policy.bridgeProofTtlMs;
      await transaction.insertBridgeProof({
        tokenHash: bridgeProofDigest(this.dependencies.proofHmacKey, internalProof),
        issuer: identity.issuer,
        subject: identity.subject,
        attemptId: claim.attempt.id,
        purpose: "sign-in",
        issuedAtMs,
        expiresAtMs,
        policyVersion: this.dependencies.policy.version,
        state: "active",
      });
      const accepted = await transaction.claimBridgeProof({
        tokenHash: bridgeProofDigest(this.dependencies.proofHmacKey, internalProof),
        issuer: identity.issuer,
        subject: identity.subject,
        attemptId: claim.attempt.id,
        purpose: "sign-in",
        nowMs: this.dependencies.clock.nowMs(),
      });
      if (accepted === undefined) {
        return { status: "invalid_token" as const };
      }
      return {
        status: "bridge" as const,
        issuer: accepted.issuer,
        subject: accepted.subject,
        attemptId: accepted.attemptId,
        internalProof,
      };
    });
    if (credential.status === "replayed_nonce") {
      throw new AppleAuthError("replayed_nonce");
    }
    if (credential.status === "invalid_attempt") {
      throw new AppleAuthError("invalid_attempt");
    }
    if (credential.status === "invalid_token") {
      throw new AppleAuthError("invalid_token");
    }
    if (credential.status === "verified-auth-receipt") {
      return {
        status: "verified-auth-receipt",
        verifiedAuthenticationReceiptToken:
          credential.verifiedAuthenticationReceiptToken,
        expiresAtMs: credential.expiresAtMs,
        identity,
      };
    }
    const bridgeResult = await this.dependencies.bridge.authenticate({
      issuer: credential.issuer,
      subject: credential.subject,
      attemptId: credential.attemptId,
      purpose: "sign-in",
      internalProof: credential.internalProof,
    });
    return {
      principalId: bridgeResult.principalId,
      identity,
    };
  }

  private async verifyIdToken(
    token: string,
    expectedAudience: string,
    expectedNonceHash: string,
  ): Promise<AppleFinishResult["identity"]> {
    const parsed = parseJwt(token);
    if (
      parsed === undefined ||
      parsed.header.alg !== "RS256" ||
      typeof parsed.header.kid !== "string" ||
      parsed.header.kid.length === 0 ||
      "jku" in parsed.header ||
      "x5u" in parsed.header ||
      "jwk" in parsed.header
    ) {
      throw new AppleAuthError("invalid_token");
    }

    let keys: readonly AppleJwk[];
    try {
      keys = await this.dependencies.jwks.trustedKeys(false);
    } catch {
      throw new AppleAuthError("unknown_key");
    }
    let key = keys.find((candidate) => candidate.kid === parsed.header.kid);
    if (key === undefined) {
      try {
        keys = await this.dependencies.jwks.trustedKeys(true);
      } catch {
        throw new AppleAuthError("unknown_key");
      }
      key = keys.find((candidate) => candidate.kid === parsed.header.kid);
      if (key === undefined) {
        throw new AppleAuthError("unknown_key");
      }
    }
    if (
      key.kty !== "RSA" ||
      key.use !== "sig" ||
      key.alg !== "RS256" ||
      typeof key.n !== "string" ||
      typeof key.e !== "string"
    ) {
      throw new AppleAuthError("invalid_token");
    }

    let signatureValid = false;
    try {
      const publicKey = createPublicKey({ key: key as JsonWebKey, format: "jwk" });
      signatureValid = verify(
        "RSA-SHA256",
        Buffer.from(parsed.signingInput),
        publicKey,
        parsed.signature,
      );
    } catch {
      throw new AppleAuthError("invalid_token");
    }
    if (!signatureValid) {
      throw new AppleAuthError("invalid_token");
    }

    const nowMs = this.dependencies.clock.nowMs();
    const claims = parsed.payload;
    if (
      claims.iss !== APPLE_ISSUER ||
      claims.aud !== expectedAudience ||
      typeof claims.sub !== "string" ||
      claims.sub.trim().length === 0 ||
      typeof claims.nonce !== "string" ||
      typeof claims.exp !== "number" ||
      !Number.isFinite(claims.exp) ||
      typeof claims.iat !== "number" ||
      !Number.isFinite(claims.iat)
    ) {
      throw new AppleAuthError("invalid_token");
    }
    const expiryMs = claims.exp * 1_000;
    const issuedAtMs = claims.iat * 1_000;
    if (
      expiryMs < nowMs - this.dependencies.policy.clockSkewMs ||
      issuedAtMs > nowMs + this.dependencies.policy.clockSkewMs ||
      issuedAtMs <
        nowMs - this.dependencies.policy.maxTokenAgeMs - this.dependencies.policy.clockSkewMs
    ) {
      throw new AppleAuthError("invalid_token");
    }
    const nonceHash = keyedDigest(
      this.dependencies.stateHmacKey,
      `nonce:${claims.nonce}`,
    );
    if (!equalDigests(expectedNonceHash, nonceHash)) {
      throw new AppleAuthError("invalid_token");
    }

    const baseIdentity = { issuer: APPLE_ISSUER, subject: claims.sub };
    const verified = claims.email_verified === true || claims.email_verified === "true";
    if (typeof claims.email !== "string" || claims.email.length === 0 || !verified) {
      return baseIdentity;
    }
    return {
      ...baseIdentity,
      emailMetadata: {
        email: claims.email,
        verified: true,
        isPrivateRelay:
          claims.is_private_email === true || claims.is_private_email === "true",
      },
    };
  }
}

interface ParsedJwt {
  readonly header: Readonly<Record<string, unknown>>;
  readonly payload: Readonly<Record<string, unknown>>;
  readonly signingInput: string;
  readonly signature: Uint8Array;
}

function parseJwt(token: string): ParsedJwt | undefined {
  const parts = token.split(".");
  if (parts.length !== 3) {
    return undefined;
  }
  const [encodedHeader, encodedPayload, encodedSignature] = parts;
  if (
    encodedHeader === undefined ||
    encodedPayload === undefined ||
    encodedSignature === undefined ||
    !/^[A-Za-z0-9_-]+$/u.test(encodedHeader) ||
    !/^[A-Za-z0-9_-]+$/u.test(encodedPayload) ||
    !/^[A-Za-z0-9_-]+$/u.test(encodedSignature)
  ) {
    return undefined;
  }
  try {
    const header: unknown = JSON.parse(Buffer.from(encodedHeader, "base64url").toString("utf8"));
    const payload: unknown = JSON.parse(Buffer.from(encodedPayload, "base64url").toString("utf8"));
    if (!isRecord(header) || !isRecord(payload)) {
      return undefined;
    }
    return {
      header,
      payload,
      signingInput: `${encodedHeader}.${encodedPayload}`,
      signature: Buffer.from(encodedSignature, "base64url"),
    };
  } catch {
    return undefined;
  }
}

function isRecord(value: unknown): value is Readonly<Record<string, unknown>> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function keyedDigest(key: Uint8Array, value: string): string {
  return createHmac("sha256", key).update(value).digest("base64url");
}

function bridgeProofDigest(key: Uint8Array, proof: string): string {
  return keyedDigest(key, `apple-bridge-proof:${proof}`);
}

function equalDigests(left: string, right: string): boolean {
  const leftBytes = Buffer.from(left, "base64url");
  const rightBytes = Buffer.from(right, "base64url");
  return leftBytes.length === rightBytes.length && timingSafeEqual(leftBytes, rightBytes);
}
