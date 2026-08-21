import {
  createCipheriv,
  createHash,
  createHmac,
  hkdfSync,
} from "node:crypto";

import type {
  AppOwnedSessionMaterial,
  AppOwnedSessionMaterialPort,
  CognitoAdminPort,
  IssuedAppSessionResolverPort,
} from "../adapters/cognito-custom-auth.js";
import {
  CognitoServerBridge,
} from "../adapters/cognito-custom-auth.js";
import {
  DataApiTransactionExecutor,
  type DataApiClient,
} from "../adapters/data-api.js";
import type { HttpTransport, SecretValuePort } from "../contracts/provider-ports.js";
import {
  createSlice4HandlerEntrypoint,
  type ApiGatewayV2Request,
  type AuthorizedOperationContext,
  type RouteHandler,
} from "../handlers/factory.js";
import {
  DataApiCapabilityRepository,
  type WorkspaceAuthorizationState,
} from "../persistence/capabilities.js";
import { requireCapabilityRepositories } from "../persistence/operation-port.js";
import { DataApiCapabilityOperationPort } from "../persistence/operation-port.js";
import { DataApiCapabilityTransactionRunner } from "../persistence/transaction-runner.js";
import type { MagicRatePolicy } from "../persistence/auth-composites.js";
import {
  createSlice4RouteApplications,
  type AppleBeginHttpResult,
  type Slice4AppleRoutePort,
  type Slice4IdentityRoutePort,
  type Slice4MagicRoutePort,
  type Slice4SessionRoutePort,
  type Slice4StripeRoutePort,
  type Slice4WorkspaceReadRoutePort,
} from "./route-application.js";
import {
  AppleStrictIdTokenVerifier,
  createSlice4AppleCodeExchange,
  type AppleJwksPort,
} from "./apple-provider.js";

/** The concrete composition has no dynamic database role or workspace input.
 * Infrastructure supplies an already API-role-bound Data API client and
 * narrow provider transports only. */
export class DataApiRouteApplicationError extends Error {
  constructor(readonly code: "invalid_composition" | "unavailable") {
    super(code);
    this.name = "DataApiRouteApplicationError";
  }
}

export interface Slice4RouteClock {
  nowMs(): number;
}

export interface Slice4RouteRandom {
  bytes(length: number): Uint8Array;
}

interface Slice4AppleCodeExchangePort {
  exchange(input: {
    readonly code: string;
    readonly codeVerifier: string;
    readonly clientId: string;
    readonly redirectUri: string;
  }): Promise<{ readonly idToken: string }>;
}

/** This narrow provider port is where strict Apple issuer, audience,
 * signature/JWKS rotation, timestamps and nonce validation live. The service
 * still supplies every expected server-owned value and rejects any malformed
 * output before it reaches an app-owned capability. */
interface Slice4AppleIdTokenVerifier {
  verify(input: {
    readonly idToken: string;
    readonly expectedIssuer: "https://appleid.apple.com";
    readonly expectedAudience: string;
    readonly expectedNonceDigest: string;
    readonly authoritativeNowMs: number;
  }): Promise<Readonly<{
    readonly issuer: "https://appleid.apple.com";
    readonly subject: string;
  }>>;
}

export interface Slice4MagicRoutePolicy {
  readonly version: string;
  readonly ttlMs: number;
  /** Identity-link/unlink receipts are deliberately shorter than a link. */
  readonly verifiedAuthenticationReceiptTtlMs: number;
  readonly ratePolicy: MagicRatePolicy;
  /** Persisted by the v3 reducer; values are configuration, not prices. */
  readonly maxCompletionFailures: number;
  readonly redeemNetworkWindowSeconds: number;
  readonly maxRedeemNetworkFailures: number;
  readonly keyId: string;
  /** Active AES-256-GCM data key. It is an API runtime secret, never emitted
   * in an HTTP response, DB parameter, audit event, or structured log. */
  readonly sealingKey: Uint8Array;
}

export interface Slice4SessionRoutePolicy {
  readonly version: string;
  readonly accessTtlMs: number;
  readonly refreshInactivityTtlMs: number;
  readonly refreshAbsoluteTtlMs: number;
}

export interface Slice4IdentityRoutePolicy {
  readonly version: string;
  /** DB caps candidate proof validity at five minutes; configuration may only
   * choose a shorter value. */
  readonly candidateProofTtlMs: number;
}

export interface Slice4AppleRoutePolicy {
  readonly version: string;
  readonly clientId: string;
  readonly redirectUri: string;
  readonly attemptTtlMs: number;
  readonly bridgeProofTtlMs: number;
  readonly verifiedAuthenticationReceiptTtlMs: number;
}

export interface Slice4RouteHashKeys {
  readonly accessTokenHmacKey: Uint8Array;
  readonly refreshTokenHmacKey: Uint8Array;
  readonly magicTokenHmacKey: Uint8Array;
  readonly magicAddressHmacKey: Uint8Array;
  readonly magicNetworkHmacKey: Uint8Array;
  readonly appleStateHmacKey: Uint8Array;
  readonly appleCodeHmacKey: Uint8Array;
  readonly appleBridgeProofHmacKey: Uint8Array;
  readonly verifiedAuthenticationReceiptHmacKey: Uint8Array;
}

export interface Slice4MagicDeliveryWakePort {
  /** A wake carries no selector, address, token, or tenant identifier. The
   * email worker recovers a target with `claim_next_magic_delivery`; a
   * periodic tick makes a lost best-effort wake harmless. */
  notify(): Promise<void>;
}

export interface Slice4DataApiRouteApplicationDependencies {
  /** Bound by infrastructure to `roomscan_api_runtime`; this factory exposes
   * no role selector and never accepts caller database credentials. */
  readonly apiClient: DataApiClient;
  readonly clock: Slice4RouteClock;
  readonly random: Slice4RouteRandom;
  readonly keys: Slice4RouteHashKeys;
  readonly magic: Slice4MagicRoutePolicy;
  readonly sessions: Slice4SessionRoutePolicy;
  readonly identity: Slice4IdentityRoutePolicy;
  readonly apple: Slice4AppleRoutePolicy & {
    /** Infrastructure supplies a bounded transport and secret-reader only.
     * This factory constructs both the Apple client-secret JWT and strict ID
     * token verifier; callers cannot inject a security decision. */
    readonly transport: HttpTransport;
    readonly privateKeySecrets: SecretValuePort;
    readonly privateKeySecretName: string;
    readonly teamId: string;
    readonly keyId: string;
    readonly clientSecretLifetimeSeconds: number;
    readonly exchangeTimeoutMs: number;
    readonly exchangeMaxResponseBytes: number;
    readonly jwks: AppleJwksPort;
    readonly jwksCacheTtlMs: number;
    readonly clockSkewMs: number;
    readonly maxTokenAgeMs: number;
    readonly cognito: CognitoAdminPort;
  };
  /** Stripe itself remains a separate durable ingress root. The API route
   * application owns the sealed route but does not receive Stripe authority. */
  readonly stripe: Slice4StripeRoutePort;
  /** Optional only because periodic delivery ticks recover a failed wake.
   * Public issuance invokes it after every syntactically valid attempt has
   * settled, not only a real issuance, so request timing does not reveal
   * directory or rate-policy state. Its record remains targetless. */
  readonly magicDeliveryWake?: Slice4MagicDeliveryWakePort;
}

/**
 * Production HTTP application for all nineteen sealed Slice 4 routes. It
 * creates public capability transactions for magic/Apple/refresh and derives
 * protected scope only from the operation's same-UoW access bundle. No caller
 * supplies a workspace ID, internal principal ID, period, DB role or SQL.
 */
export function createSlice4DataApiRouteApplications(
  input: Slice4DataApiRouteApplicationDependencies,
): Readonly<Record<string, RouteHandler>> {
  assertDependencies(input);
  const publicTransactions = new DataApiCapabilityTransactionRunner(
    input.apiClient,
    (unit) => new DataApiCapabilityRepository(unit),
  );
  const sessionMaterials = new AppOwnedSessionMaterials(input.clock, input.random, input.keys, input.sessions);
  const issuedSessions = new DataApiIssuedAccessResolver(input.apiClient);
  let appleExchange: Slice4AppleCodeExchangePort;
  let appleIdentityVerifier: Slice4AppleIdTokenVerifier;
  try {
    appleExchange = createSlice4AppleCodeExchange({
      transport: input.apple.transport,
      privateKeySecrets: input.apple.privateKeySecrets,
      privateKeySecretName: input.apple.privateKeySecretName,
      teamId: input.apple.teamId,
      keyId: input.apple.keyId,
      clientId: input.apple.clientId,
      lifetimeSeconds: input.apple.clientSecretLifetimeSeconds,
      clock: input.clock,
      timeoutMs: input.apple.exchangeTimeoutMs,
      maxResponseBytes: input.apple.exchangeMaxResponseBytes,
    });
    appleIdentityVerifier = new AppleStrictIdTokenVerifier({
      jwks: input.apple.jwks,
      nonceHmacKey: input.keys.appleStateHmacKey,
      clock: input.clock,
      clockSkewMs: input.apple.clockSkewMs,
      maxTokenAgeMs: input.apple.maxTokenAgeMs,
      cacheTtlMs: input.apple.jwksCacheTtlMs,
    });
  } catch {
    throw new DataApiRouteApplicationError("invalid_composition");
  }
  const appleBridge = new CognitoServerBridge({
    admin: input.apple.cognito,
    sessionMaterials,
    issuedSessions,
    clock: { now: () => new Date(requireNow(input.clock)) },
  });

  return createSlice4RouteApplications({
    magic: new DataApiMagicRoutePort(publicTransactions, input.clock, input.random, input.keys, input.magic, input.sessions, input.magicDeliveryWake),
    apple: new DataApiAppleRoutePort(publicTransactions, input.clock, input.random, input.keys, {
      ...input.apple,
      exchange: appleExchange,
      verifyIdentity: appleIdentityVerifier,
    }, appleBridge),
    sessions: new DataApiSessionRoutePort(publicTransactions, input.clock, input.random, input.keys, input.sessions),
    workspace: new DataApiWorkspaceReadRoutePort(input.clock, input.keys),
    identity: new DataApiIdentityRoutePort(input.clock, input.random, input.keys, input.identity),
    stripe: input.stripe,
  });
}

/** Concrete API-Gateway entrypoint: handler map and protected-operation port
 * are both service-owned and share the API-role-bound client. Infrastructure
 * cannot inject individual HTTP applications or select a database role. */
export function createSlice4DataApiApiHandler(
  input: Slice4DataApiRouteApplicationDependencies,
): (event: ApiGatewayV2Request) => Promise<import("../http/http-api-v2.js").HttpApiV2Response> {
  const handlers = createSlice4DataApiRouteApplications(input);
  return createSlice4HandlerEntrypoint({
    handlers,
    operations: new DataApiCapabilityOperationPort({
      client: input.apiClient,
      accessTokenHmacKey: input.keys.accessTokenHmacKey,
      clock: { now: () => new Date(requireNow(input.clock)) },
    }),
  });
}

class DataApiMagicRoutePort implements Slice4MagicRoutePort {
  constructor(
    private readonly transactions: DataApiCapabilityTransactionRunner<DataApiCapabilityRepository>,
    private readonly clock: Slice4RouteClock,
    private readonly random: Slice4RouteRandom,
    private readonly keys: Slice4RouteHashKeys,
    private readonly policy: Slice4MagicRoutePolicy,
    private readonly sessionPolicy: Slice4SessionRoutePolicy,
    private readonly wake: Slice4MagicDeliveryWakePort | undefined,
  ) {}

  /** Public issue is deliberately shape-uniform. We mint a fresh app-held
   * completion ID before the database call and return it even for unknown,
   * throttled, disabled, or transient-failure paths. Only an `issued` row can
   * later redeem; synthetic IDs simply fail closed. */
  async request(input: { readonly email: string; readonly purpose: "sign-in" | "reauthenticate"; readonly codeChallenge: string; readonly sourceIp: string }): Promise<Readonly<{ readonly completionId: string; readonly expiresAt: string }>> {
    const artifact = this.#artifact(input.codeChallenge);
    const deliveryIdentity = normalizeDeliveryIdentity(input.email);
    if (deliveryIdentity === undefined || !validSourceIp(input.sourceIp)) return artifact.publicResponse;
    try {
      await this.transactions.run((repository) => repository.auth().issuePublicMagicCompletionChallenge(
        this.#issueInput(artifact, input.purpose, deliveryIdentity, input.sourceIp),
      ));
    } catch { /* public anti-enumeration contract returns the same artifact */ }
    if (this.wake !== undefined) {
      // `run` has committed or failed before this point. A targetless wake is
      // harmless for synthetic/limited requests, while equal invocation hides
      // the durable issue outcome; periodic recovery covers a lost wake.
      try { await this.wake.notify(); } catch { /* durable outbox remains pending */ }
    }
    return artifact.publicResponse;
  }

  async requestCandidate(input: { readonly context: AuthorizedOperationContext; readonly email: string; readonly purpose: "link-identity" | "unlink-identity"; readonly codeChallenge: string; readonly sourceIp: string }): Promise<Readonly<{ readonly completionId: string; readonly expiresAt: string }>> {
    const artifact = this.#artifact(input.codeChallenge);
    const deliveryIdentity = normalizeDeliveryIdentity(input.email);
    if (deliveryIdentity === undefined || !validSourceIp(input.sourceIp)) throw new DataApiRouteApplicationError("unavailable");
    const repositories = requireCapabilityRepositories(input.context.repositories, input.context.transactionMarker);
    const result = await repositories.api.auth().issueBoundMagicCompletionChallenge(
      this.#issueInput(artifact, input.purpose, deliveryIdentity, input.sourceIp),
    );
    if (result.status !== "issued") throw new DataApiRouteApplicationError("unavailable");
    if (this.wake !== undefined) {
      // Protected requests occur inside the authorizer's outer UoW. Do not
      // wake before that UoW commits; periodic tick still recovers this row.
    }
    return artifact.publicResponse;
  }

  async consume(input: { readonly selector: string; readonly secret: string; readonly purpose: "sign-in" | "reauthenticate" | "link-identity" | "unlink-identity"; readonly clickingDeviceId: string }): Promise<
    | Readonly<{ readonly status: "confirmed"; readonly transferCode: string; readonly expiresAt: string }>
    | Readonly<{ readonly status: "rejected" }>
  > {
    if (!selectorValue(input.selector) || !opaque(input.secret) || !validClickingDevice(input.clickingDeviceId)) {
      return Object.freeze({ status: "rejected" });
    }
    const now = requireNow(this.clock);
    const secretBytes = Buffer.from(input.secret, "base64url");
    const transferCode = magicTransferCode(this.keys.magicTokenHmacKey, input.selector, secretBytes);
    try {
      const result = await this.transactions.run((repository) => repository.auth().consumeMagicCompletionChallenge({
        selector: input.selector,
        secretDigest: digest(this.keys.magicTokenHmacKey, secretBytes),
        expectedPurpose: input.purpose,
        authoritativeNowMs: now,
        transferCodeDigest: domainDigest(this.keys.magicTokenHmacKey, "roomscan.slice4.magic-completion.v3/transfer-code", transferCode),
      }));
      if ((result.status === "confirmed" || result.status === "already_confirmed") && result.purpose === input.purpose) {
        return Object.freeze({ status: "confirmed", transferCode, expiresAt: new Date(result.expiresAtMs).toISOString() });
      }
    } catch { /* one-time confirmation is deliberately indistinguishable */ }
    return Object.freeze({ status: "rejected" });
  }

  async redeem(input: { readonly completionId: string; readonly codeVerifier: string; readonly purpose: "sign-in" | "reauthenticate" | "link-identity" | "unlink-identity"; readonly transferCode: string; readonly sourceIp: string }): Promise<
    | Readonly<{ readonly status: "pending" }>
    | Readonly<{ readonly status: "authenticated"; readonly principalCanonicalId: string; readonly familyPublicId: string; readonly accessToken: string; readonly refreshToken: string; readonly accessExpiresAt: string }>
    | Readonly<{ readonly status: "verified-auth-receipt"; readonly principalCanonicalId: string; readonly verifiedAuthenticationReceiptToken: string; readonly receiptExpiresAt: string }>
    | Readonly<{ readonly status: "rejected" }>
  > {
    if (!opaque(input.completionId) || !opaque(input.codeVerifier) || !transferCodeValue(input.transferCode) || !validSourceIp(input.sourceIp)) {
      return Object.freeze({ status: "rejected" });
    }
    const now = requireNow(this.clock);
    const completion = Buffer.from(input.completionId, "base64url");
    const verifier = Buffer.from(input.codeVerifier, "base64url");
    const codeChallenge = createHash("sha256").update(verifier).digest("base64url");
    const common = {
      completionDigest: domainDigest(this.keys.magicTokenHmacKey, "roomscan.slice4.magic-completion.v3/completion-id", completion),
      codeChallenge,
      transferCodeDigest: domainDigest(this.keys.magicTokenHmacKey, "roomscan.slice4.magic-completion.v3/transfer-code", input.transferCode),
      expectedPurpose: input.purpose,
      networkDigest: digest(this.keys.magicNetworkHmacKey, input.sourceIp),
      authoritativeNowMs: now,
    } as const;
    try {
      if (input.purpose === "link-identity" || input.purpose === "unlink-identity") {
        const receipt = magicCompletionMaterial(verifier, completion, "roomscan.slice4.magic-completion.v3/receipt");
        const result = await this.transactions.run((repository) => repository.auth().redeemMagicCompletion({
          ...common,
          receiptDigest: digest(this.keys.verifiedAuthenticationReceiptHmacKey, receipt),
          receiptExpiresAtMs: checkedAdd(now, this.policy.verifiedAuthenticationReceiptTtlMs),
        }));
        if (result.status === "pending_confirmation") return Object.freeze({ status: "pending" });
        if ((result.status === "receipt_issued" || result.status === "receipt_replayed") && result.purpose === input.purpose) {
          return Object.freeze({
            status: "verified-auth-receipt", principalCanonicalId: result.principalCanonicalId,
            verifiedAuthenticationReceiptToken: Buffer.from(receipt).toString("base64url"), receiptExpiresAt: new Date(result.receiptExpiresAtMs).toISOString(),
          });
        }
        return Object.freeze({ status: "rejected" });
      }
      const access = magicCompletionMaterial(verifier, completion, "roomscan.slice4.magic-completion.v3/access");
      const refresh = magicCompletionMaterial(verifier, completion, "roomscan.slice4.magic-completion.v3/refresh");
      const family = `fam_${Buffer.from(magicCompletionMaterial(verifier, completion, "roomscan.slice4.magic-completion.v3/family-public-id")).subarray(0, 16).toString("base64url")}`;
      const result = await this.transactions.run((repository) => repository.auth().redeemMagicCompletion({
        ...common,
        familyPublicId: family,
        accessTokenDigest: digest(this.keys.accessTokenHmacKey, access),
        refreshTokenDigest: digest(this.keys.refreshTokenHmacKey, refresh),
        accessExpiresAtMs: checkedAdd(now, this.sessionPolicy.accessTtlMs),
        inactivityExpiresAtMs: checkedAdd(now, this.sessionPolicy.refreshInactivityTtlMs),
        absoluteExpiresAtMs: checkedAdd(now, this.sessionPolicy.refreshAbsoluteTtlMs),
        sessionPolicyVersion: this.sessionPolicy.version,
      }));
      if (result.status === "pending_confirmation") return Object.freeze({ status: "pending" });
      if ((result.status === "session_issued" || result.status === "session_replayed") && result.purpose === input.purpose) {
        return Object.freeze({
          status: "authenticated", principalCanonicalId: result.principalCanonicalId, familyPublicId: result.familyPublicId,
          accessToken: Buffer.from(access).toString("base64url"), refreshToken: Buffer.from(refresh).toString("base64url"),
          accessExpiresAt: new Date(result.accessExpiresAtMs).toISOString(),
        });
      }
    } catch { /* invalid/replayed/disabled material remains fail closed */ }
    return Object.freeze({ status: "rejected" });
  }

  #artifact(codeChallenge: string): MagicCompletionArtifact {
    if (!codeChallengeValue(codeChallenge)) throw new DataApiRouteApplicationError("unavailable");
    const now = requireNow(this.clock);
    const completionId = opaqueFrom(this.random, 32);
    const selector = opaqueFrom(this.random, 16);
    const secret = randomBytes(this.random, 32);
    const expiresAtMs = checkedAdd(now, this.policy.ttlMs);
    return Object.freeze({
      completionId, selector, secret, codeChallenge, expiresAtMs,
      publicResponse: Object.freeze({ completionId, expiresAt: new Date(expiresAtMs).toISOString() }),
    });
  }

  #issueInput(
    artifact: MagicCompletionArtifact,
    purpose: "sign-in" | "reauthenticate" | "link-identity" | "unlink-identity",
    deliveryIdentity: string,
    sourceIp: string,
  ) {
    return {
      selector: artifact.selector,
      secretDigest: digest(this.keys.magicTokenHmacKey, artifact.secret),
      completionDigest: domainDigest(this.keys.magicTokenHmacKey, "roomscan.slice4.magic-completion.v3/completion-id", Buffer.from(artifact.completionId, "base64url")),
      codeChallenge: artifact.codeChallenge,
      purpose,
      deliveryIdentity,
      addressDigest: digest(this.keys.magicAddressHmacKey, deliveryIdentity),
      networkDigest: digest(this.keys.magicNetworkHmacKey, sourceIp),
      authoritativeNowMs: artifact.expiresAtMs - this.policy.ttlMs,
      expiresAtMs: artifact.expiresAtMs,
      policyVersion: this.policy.version,
      outboxId: `mdl_${opaqueFrom(this.random, 16)}`,
      keyId: this.policy.keyId,
      sealedSecret: sealMagicSecret(this.policy.sealingKey, artifact.secret, randomBytes(this.random, 12)),
      ratePolicy: this.policy.ratePolicy,
      maxCompletionFailures: this.policy.maxCompletionFailures,
      redeemNetworkWindowSeconds: this.policy.redeemNetworkWindowSeconds,
      maxRedeemNetworkFailures: this.policy.maxRedeemNetworkFailures,
    } as const;
  }
}

interface MagicCompletionArtifact {
  readonly completionId: string;
  readonly selector: string;
  readonly secret: Uint8Array;
  readonly codeChallenge: string;
  readonly expiresAtMs: number;
  readonly publicResponse: Readonly<{ readonly completionId: string; readonly expiresAt: string }>;
}

class DataApiSessionRoutePort implements Slice4SessionRoutePort {
  constructor(
    private readonly transactions: DataApiCapabilityTransactionRunner<DataApiCapabilityRepository>,
    private readonly clock: Slice4RouteClock,
    private readonly random: Slice4RouteRandom,
    private readonly keys: Slice4RouteHashKeys,
    private readonly policy: Slice4SessionRoutePolicy,
  ) {}

  async refresh(input: { readonly refreshToken: string }): Promise<{ readonly accessToken: string; readonly refreshToken: string; readonly accessExpiresAtMs: number }> {
    if (!opaque(input.refreshToken)) throw new DataApiRouteApplicationError("unavailable");
    const now = requireNow(this.clock);
    const material = mintSessionMaterial(this.clock, this.random, this.keys, this.policy, now);
    const result = await this.transactions.run((repository) => repository.rotateSessionFromRefresh({
      currentRefreshDigest: digest(this.keys.refreshTokenHmacKey, input.refreshToken),
      nextRefreshDigest: Buffer.from(material.refreshTokenHash).toString("base64url"),
      nextAccessDigest: Buffer.from(material.accessTokenHash).toString("base64url"),
      rotatedAtMs: now,
      nextAccessExpiresAtMs: material.accessExpiresAt.getTime(),
      nextInactivityExpiresAtMs: material.inactivityExpiresAt.getTime(),
    }));
    if (result.status !== "rotated") throw new DataApiRouteApplicationError("unavailable");
    return Object.freeze({ accessToken: material.accessToken, refreshToken: material.refreshToken, accessExpiresAtMs: result.accessExpiresAtMs });
  }

  async logout(input: { readonly context: AuthorizedOperationContext }): Promise<void> {
    const repositories = requireCapabilityRepositories(input.context.repositories, input.context.transactionMarker);
    const result = await repositories.api.auth().logoutCurrentSession({ revokedAtMs: requireNow(this.clock), reason: "logout" });
    if (result.status !== "revoked" && result.status !== "already_revoked") throw new DataApiRouteApplicationError("unavailable");
  }
}

class DataApiAppleRoutePort implements Slice4AppleRoutePort {
  constructor(
    private readonly transactions: DataApiCapabilityTransactionRunner<DataApiCapabilityRepository>,
    private readonly clock: Slice4RouteClock,
    private readonly random: Slice4RouteRandom,
    private readonly keys: Slice4RouteHashKeys,
    private readonly policy: Slice4AppleRoutePolicy & {
      readonly exchange: Slice4AppleCodeExchangePort;
      readonly verifyIdentity: Slice4AppleIdTokenVerifier;
      readonly cognito: CognitoAdminPort;
    },
    private readonly bridge: CognitoServerBridge,
  ) {}

  async begin(input: { readonly codeChallenge: string }): Promise<AppleBeginHttpResult> {
    return this.#begin(input.codeChallenge, undefined, "sign-in");
  }

  async beginCandidate(input: { readonly context: AuthorizedOperationContext; readonly codeChallenge: string; readonly purpose: "link-identity" | "unlink-identity" }): Promise<AppleBeginHttpResult> {
    const repositories = requireCapabilityRepositories(input.context.repositories, input.context.transactionMarker);
    const now = requireNow(this.clock);
    const publicValues = applePublicValues(this.random);
    const result = await repositories.api.auth().createBoundAppleAttempt({
      attemptId: publicValues.attemptId,
      stateDigest: digest(this.keys.appleStateHmacKey, `state:${publicValues.state}`),
      nonceDigest: digest(this.keys.appleStateHmacKey, `nonce:${publicValues.nonce}`),
      codeChallenge: input.codeChallenge,
      clientId: this.policy.clientId,
      redirectUri: this.policy.redirectUri,
      authoritativeNowMs: now,
      expiresAtMs: checkedAdd(now, this.policy.attemptTtlMs),
      policyVersion: this.policy.version,
    }, input.purpose);
    if (result.status !== "created") throw new DataApiRouteApplicationError("unavailable");
    return Object.freeze({ ...publicValues, expiresAtMs: checkedAdd(now, this.policy.attemptTtlMs) });
  }

  async finish(input: { readonly attemptId: string; readonly state: string; readonly code: string; readonly codeVerifier: string }): Promise<
    | Readonly<{ readonly status: "authenticated"; readonly principalCanonicalId: string; readonly familyPublicId: string; readonly accessToken: string; readonly refreshToken: string; readonly accessExpiresAtMs: number }>
    | Readonly<{ readonly status: "verified-auth-receipt"; readonly receiptToken: string; readonly expiresAtMs: number }>
  > {
    if (!attemptIdValue(input.attemptId) || !opaque(input.state) || !boundedText(input.code, 1, 4096) || !codeVerifier(input.codeVerifier)) {
      throw new DataApiRouteApplicationError("unavailable");
    }
    const claimedAt = requireNow(this.clock);
    const claimed = await this.transactions.run((repository) => repository.auth().claimAppleAttemptAndCode({
      attemptId: input.attemptId,
      stateDigest: digest(this.keys.appleStateHmacKey, `state:${input.state}`),
      codeChallenge: createHash("sha256").update(input.codeVerifier).digest("base64url"),
      codeDigest: digest(this.keys.appleCodeHmacKey, `code:${input.code}`),
      claimedAtMs: claimedAt,
    }));
    if (claimed.status !== "claimed" || claimed.expiresAtMs <= claimedAt) throw new DataApiRouteApplicationError("unavailable");

    const exchanged = await this.policy.exchange.exchange({
      code: input.code,
      codeVerifier: input.codeVerifier,
      clientId: claimed.clientId,
      redirectUri: claimed.redirectUri,
    });
    const postExchangeNow = requireNow(this.clock);
    if (claimed.expiresAtMs <= postExchangeNow || !boundedText(exchanged?.idToken, 16, 16_384)) {
      throw new DataApiRouteApplicationError("unavailable");
    }
    const identity = await this.policy.verifyIdentity.verify({
      idToken: exchanged.idToken,
      expectedIssuer: "https://appleid.apple.com",
      expectedAudience: claimed.clientId,
      expectedNonceDigest: claimed.nonceDigest,
      authoritativeNowMs: postExchangeNow,
    });
    if (identity?.issuer !== "https://appleid.apple.com" || !boundedText(identity.subject, 1, 512)) {
      throw new DataApiRouteApplicationError("unavailable");
    }
    const acceptedAt = requireNow(this.clock);
    if (claimed.expiresAtMs <= acceptedAt) throw new DataApiRouteApplicationError("unavailable");
    if (claimed.purpose === "sign-in") {
      const bridgeProof = opaqueFrom(this.random, 32);
      const accepted = await this.transactions.run(async (repository) => {
        if (!await repository.auth().claimAppleNonce({ nonceDigest: claimed.nonceDigest, claimedAtMs: acceptedAt })) {
          return undefined;
        }
        return repository.auth().acceptAppleSignInResult({
          attemptId: claimed.attemptId,
          issuer: identity.issuer,
          subject: identity.subject,
          bridgeProofDigest: digest(this.keys.appleBridgeProofHmacKey, bridgeProof),
          authoritativeNowMs: acceptedAt,
          expiresAtMs: checkedAdd(acceptedAt, this.policy.bridgeProofTtlMs),
          policyVersion: claimed.policyVersion,
        });
      });
      if (accepted?.status !== "bridge_created") throw new DataApiRouteApplicationError("unavailable");
      const session = await this.bridge.authenticate({
        issuer: identity.issuer,
        subject: identity.subject,
        internalProof: bridgeProof,
        attemptId: claimed.attemptId,
        purpose: "sign-in",
      });
      return Object.freeze({
        status: "authenticated",
        principalCanonicalId: session.principalCanonicalId,
        familyPublicId: session.familyPublicId,
        accessToken: session.accessToken,
        refreshToken: session.refreshToken,
        accessExpiresAtMs: canonicalDateMilliseconds(session.accessExpiresAt),
      });
    }

    const receiptToken = opaqueFrom(this.random, 32);
    const accepted = await this.transactions.run(async (repository) => {
      if (!await repository.auth().claimAppleNonce({ nonceDigest: claimed.nonceDigest, claimedAtMs: acceptedAt })) {
        return undefined;
      }
      return repository.auth().acceptAppleCandidateResult({
        attemptId: claimed.attemptId,
        issuer: identity.issuer,
        subject: identity.subject,
        receiptDigest: digest(this.keys.verifiedAuthenticationReceiptHmacKey, receiptToken),
        authoritativeNowMs: acceptedAt,
        expiresAtMs: checkedAdd(acceptedAt, this.policy.verifiedAuthenticationReceiptTtlMs),
        policyVersion: claimed.policyVersion,
      });
    });
    if (accepted?.status !== "receipt_created") throw new DataApiRouteApplicationError("unavailable");
    return Object.freeze({ status: "verified-auth-receipt", receiptToken, expiresAtMs: accepted.expiresAtMs });
  }

  async #begin(codeChallenge: string, _context: undefined, purpose: "sign-in"): Promise<AppleBeginHttpResult> {
    const now = requireNow(this.clock);
    const publicValues = applePublicValues(this.random);
    const result = await this.transactions.run((repository) => repository.auth().createPublicAppleAttempt({
      attemptId: publicValues.attemptId,
      stateDigest: digest(this.keys.appleStateHmacKey, `state:${publicValues.state}`),
      nonceDigest: digest(this.keys.appleStateHmacKey, `nonce:${publicValues.nonce}`),
      codeChallenge,
      clientId: this.policy.clientId,
      redirectUri: this.policy.redirectUri,
      authoritativeNowMs: now,
      expiresAtMs: checkedAdd(now, this.policy.attemptTtlMs),
      policyVersion: this.policy.version,
    }));
    if (result.status !== "created" || result.purpose !== purpose) throw new DataApiRouteApplicationError("unavailable");
    return Object.freeze({ ...publicValues, expiresAtMs: checkedAdd(now, this.policy.attemptTtlMs) });
  }
}

class DataApiWorkspaceReadRoutePort implements Slice4WorkspaceReadRoutePort {
  constructor(
    private readonly clock: Slice4RouteClock,
    private readonly keys: Slice4RouteHashKeys,
  ) {}

  async bootstrap(input: { readonly context: AuthorizedOperationContext; readonly slug: string; readonly displayName: string }): Promise<Readonly<{ readonly slug: string; readonly displayName: string; readonly principalCanonicalId: string; readonly familyPublicId: string; readonly role: "owner"; readonly authorizationVersion: number }>> {
    const slug = workspaceSlug(input.slug);
    const displayName = workspaceDisplayName(input.displayName);
    if (slug === undefined || displayName === undefined) throw new DataApiRouteApplicationError("unavailable");
    const repositories = requireCapabilityRepositories(input.context.repositories, input.context.transactionMarker);
    const access = repositories.api.boundAccessDigest();
    const result = await repositories.api.policy().bootstrapWorkspace({
      authoritativeNowMs: requireNow(this.clock), slug, displayName,
      // This binds identical retry material to the access family + normalized
      // public body, without accepting an audit ID from a caller.
      auditEventId: deterministicAuditId(this.keys.accessTokenHmacKey, "roomscan.slice4.workspace-bootstrap.v2", access, slug, displayName),
    });
    if (result.principalCanonicalId !== input.context.principalPublicId || result.role !== "owner" || result.state !== "active") {
      throw new DataApiRouteApplicationError("unavailable");
    }
    return Object.freeze({ slug, displayName, principalCanonicalId: result.principalCanonicalId, familyPublicId: result.familyPublicId, role: "owner", authorizationVersion: result.authorizationVersion });
  }

  async activate(input: { readonly context: AuthorizedOperationContext; readonly slug: string }): Promise<Readonly<{ readonly slug: string; readonly principalCanonicalId: string; readonly familyPublicId: string; readonly role: "owner" | "admin" | "editor" | "viewer"; readonly authorizationVersion: number }>> {
    const slug = workspaceSlug(input.slug);
    if (slug === undefined) throw new DataApiRouteApplicationError("unavailable");
    const repositories = requireCapabilityRepositories(input.context.repositories, input.context.transactionMarker);
    const result = await repositories.api.policy().scopeSessionWorkspace({ authoritativeNowMs: requireNow(this.clock), slug });
    if (result.principalCanonicalId !== input.context.principalPublicId) throw new DataApiRouteApplicationError("unavailable");
    return Object.freeze({ slug: result.workspaceSlug, principalCanonicalId: result.principalCanonicalId, familyPublicId: result.familyPublicId, role: result.role, authorizationVersion: result.authorizationVersion });
  }

  async read(input: { readonly context: AuthorizedOperationContext }): Promise<Readonly<{ readonly slug: string; readonly displayName: string; readonly principalCanonicalId: string; readonly role: "owner" | "admin" | "editor" | "viewer"; readonly authorizationVersion: number }>> {
    const state = await this.#state(input.context);
    return Object.freeze({ slug: state.workspaceSlug, displayName: state.workspaceDisplayName, principalCanonicalId: state.principalCanonicalId, role: state.role, authorizationVersion: state.authorizationVersion });
  }

  async membership(input: { readonly context: AuthorizedOperationContext }): Promise<readonly Readonly<{ readonly principalCanonicalId: string; readonly role: "owner" | "admin" | "editor" | "viewer"; readonly state: "active"; readonly authorizationVersion: number }>[] > {
    const state = await this.#state(input.context);
    // `/membership` is intentionally current-member-only in the approved
    // contract. No directory/list function is reachable from this route.
    return Object.freeze([Object.freeze({ principalCanonicalId: state.principalCanonicalId, role: state.role, state: "active" as const, authorizationVersion: state.authorizationVersion })]);
  }

  async subscription(input: { readonly context: AuthorizedOperationContext }): Promise<Readonly<{ readonly status: "inactive" | "trialing" | "active" | "past_due" | "canceled" | "read_only_grace"; readonly planKey: string; readonly generation: number; readonly currentPeriodEndMs?: number }> | undefined> {
    const repositories = requireCapabilityRepositories(input.context.repositories, input.context.transactionMarker);
    await this.#state(input.context);
    const subscription = await repositories.api.policy().readCurrentSubscription({ authoritativeNowMs: requireNow(this.clock) });
    return subscription === undefined ? undefined : Object.freeze({
      status: subscription.status,
      planKey: subscription.planKey,
      generation: subscription.generation,
      ...(subscription.currentPeriodEndMs === undefined ? {} : { currentPeriodEndMs: subscription.currentPeriodEndMs }),
    });
  }

  async quota(input: { readonly context: AuthorizedOperationContext; readonly metrics: readonly ("project_count" | "member_count" | "working_bytes" | "raw_bytes" | "portal_bytes")[] }): Promise<readonly Readonly<{ readonly metric: "project_count" | "member_count" | "working_bytes" | "raw_bytes" | "portal_bytes"; readonly used: number; readonly reserved: number; readonly limit: number; readonly warning: boolean; readonly overLimit: boolean }>[] > {
    const repositories = requireCapabilityRepositories(input.context.repositories, input.context.transactionMarker);
    await this.#state(input.context);
    const overview = await repositories.api.policy().readQuotaOverview({ authoritativeNowMs: requireNow(this.clock) });
    const requested = new Set(input.metrics);
    if (requested.size !== 5 || overview.length !== 5 || overview.some((entry) => !requested.has(entry.metric))) {
      throw new DataApiRouteApplicationError("unavailable");
    }
    return Object.freeze(overview.map((entry) => quotaHttpValue(entry)));
  }

  async #state(context: AuthorizedOperationContext): Promise<WorkspaceAuthorizationState> {
    const repositories = requireCapabilityRepositories(context.repositories, context.transactionMarker);
    const state = await repositories.api.readWorkspaceAuthorizationState({ authoritativeNowMs: requireNow(this.clock) });
    if (state === undefined || state.principalCanonicalId !== context.principalPublicId
      || state.hosted.global.enabled !== true || state.hosted.workspace.enabled !== true) {
      throw new DataApiRouteApplicationError("unavailable");
    }
    return state;
  }
}

/** Identity linking is intentionally a single access-bound UoW: the receipt
 * is checked and converted to an ephemeral hash-only proof, then consumed by
 * the deliberate mutation. No email, principal UUID, candidate proof, or
 * workspace selection comes from the route body. */
class DataApiIdentityRoutePort implements Slice4IdentityRoutePort {
  constructor(
    private readonly clock: Slice4RouteClock,
    private readonly random: Slice4RouteRandom,
    private readonly keys: Slice4RouteHashKeys,
    private readonly policy: Slice4IdentityRoutePolicy,
  ) {}

  async mutate(input: {
    readonly context: AuthorizedOperationContext;
    readonly purpose: "link-identity" | "unlink-identity";
    readonly candidateIssuer: "apple" | "email";
    readonly verifiedAuthenticationReceiptToken: string;
    readonly confirmed: true;
  }): Promise<Readonly<{ readonly status: "linked" | "unlinked"; readonly authenticationEpoch: number }>> {
    if (input.confirmed !== true || !opaque(input.verifiedAuthenticationReceiptToken)) throw new DataApiRouteApplicationError("unavailable");
    const repositories = requireCapabilityRepositories(input.context.repositories, input.context.transactionMarker);
    const now = requireNow(this.clock);
    const receiptDigest = digest(this.keys.verifiedAuthenticationReceiptHmacKey, input.verifiedAuthenticationReceiptToken);
    const rawProof = randomBytes(this.random, 32);
    const proofDigest = domainDigest(this.keys.verifiedAuthenticationReceiptHmacKey, "roomscan.slice4.identity.candidate-proof.v1", rawProof);
    const accessDigest = repositories.api.boundAccessDigest();
    const auditEventId = deterministicAuditId(this.keys.accessTokenHmacKey, "roomscan.slice4.identity-mutation.v1", accessDigest, receiptDigest, input.purpose);
    const notificationId = `notify_${domainDigest(this.keys.accessTokenHmacKey, "roomscan.slice4.identity-notification.v1", `${receiptDigest}\0${input.purpose}`).slice(0, 43)}`;
    const identityReference = `id_${domainDigest(this.keys.accessTokenHmacKey, "roomscan.slice4.identity-reference.v1", `${receiptDigest}\0${input.purpose}`).slice(0, 43)}`;
    const minted = await repositories.api.policy().mintCandidateIdentityProof({
      authoritativeNowMs: now,
      verifiedReceiptDigest: receiptDigest,
      issuer: input.candidateIssuer === "apple" ? "https://appleid.apple.com" : "email",
      purpose: input.purpose,
      candidateProofDigest: proofDigest,
      expiresAtMs: checkedAdd(now, this.policy.candidateProofTtlMs),
      policyVersion: this.policy.version,
    });
    if (minted.status !== "minted" || minted.principalCanonicalId !== input.context.principalPublicId) {
      throw new DataApiRouteApplicationError("unavailable");
    }
    const result = await repositories.api.policy().mutateIdentity({
      authoritativeNowMs: now, candidateProofDigest: proofDigest, purpose: input.purpose, deliberateConfirmation: true,
      auditEventId, notificationId, identityReference, policyVersion: this.policy.version,
    });
    if ((result.status !== "linked" && result.status !== "unlinked") || result.principalCanonicalId !== input.context.principalPublicId
      || result.authenticationEpoch === undefined) {
      throw new DataApiRouteApplicationError("unavailable");
    }
    return Object.freeze({ status: result.status, authenticationEpoch: result.authenticationEpoch });
  }
}

class AppOwnedSessionMaterials implements AppOwnedSessionMaterialPort {
  constructor(
    private readonly clock: Slice4RouteClock,
    private readonly random: Slice4RouteRandom,
    private readonly keys: Slice4RouteHashKeys,
    private readonly policy: Slice4SessionRoutePolicy,
  ) {}

  async mint(): Promise<AppOwnedSessionMaterial> {
    return mintSessionMaterial(this.clock, this.random, this.keys, this.policy, requireNow(this.clock));
  }
}

class DataApiIssuedAccessResolver implements IssuedAppSessionResolverPort {
  readonly #transactions: DataApiTransactionExecutor;

  constructor(client: DataApiClient) {
    this.#transactions = new DataApiTransactionExecutor(client, { authorize: async () => false });
  }

  async resolveIssuedAccess(input: { readonly accessTokenHash: Uint8Array; readonly authoritativeNow: Date }): Promise<{ readonly principalCanonicalId: string; readonly familyPublicId: string } | undefined> {
    if (!(input.accessTokenHash instanceof Uint8Array) || input.accessTokenHash.length !== 32
      || !(input.authoritativeNow instanceof Date) || !Number.isSafeInteger(input.authoritativeNow.getTime())) {
      throw new DataApiRouteApplicationError("unavailable");
    }
    try {
      return await this.#transactions.accessTransaction(input.accessTokenHash, input.authoritativeNow, async (unit) => Object.freeze({
        principalCanonicalId: unit.context.principalPublicId,
        familyPublicId: unit.context.familyPublicId,
      }));
    } catch {
      return undefined;
    }
  }
}

function assertDependencies(input: Slice4DataApiRouteApplicationDependencies): void {
  if (input === null || typeof input !== "object" || input.apiClient === null || typeof input.apiClient !== "object"
    || typeof input.apiClient.begin !== "function" || typeof input.apiClient.execute !== "function" || typeof input.apiClient.commit !== "function" || typeof input.apiClient.rollback !== "function"
    || input.clock === null || typeof input.clock.nowMs !== "function" || input.random === null || typeof input.random.bytes !== "function"
    || input.keys === null || typeof input.keys !== "object" || !allKeys(input.keys)
    || input.magic === null || typeof input.magic !== "object" || !validMagicPolicy(input.magic)
    || input.sessions === null || typeof input.sessions !== "object" || !validSessionPolicy(input.sessions)
    || input.identity === null || typeof input.identity !== "object" || !validIdentityPolicy(input.identity)
    || input.apple === null || typeof input.apple !== "object" || !validApplePolicy(input.apple)
    || input.stripe === null || typeof input.stripe !== "object" || typeof input.stripe.handle !== "function"
    || (input.magicDeliveryWake !== undefined && (input.magicDeliveryWake === null || typeof input.magicDeliveryWake !== "object" || typeof input.magicDeliveryWake.notify !== "function"))) {
    throw new DataApiRouteApplicationError("invalid_composition");
  }
}

function allKeys(keys: Slice4RouteHashKeys): boolean {
  return [keys.accessTokenHmacKey, keys.refreshTokenHmacKey, keys.magicTokenHmacKey, keys.magicAddressHmacKey,
    keys.magicNetworkHmacKey, keys.appleStateHmacKey, keys.appleCodeHmacKey, keys.appleBridgeProofHmacKey,
    keys.verifiedAuthenticationReceiptHmacKey].every((key) => key instanceof Uint8Array && key.length >= 32);
}

function validMagicPolicy(policy: Slice4MagicRoutePolicy): boolean {
  const rate = policy.ratePolicy;
  return validIdentifier(policy.version, 1, 64) && positive(policy.ttlMs) && positive(policy.verifiedAuthenticationReceiptTtlMs)
    && policy.verifiedAuthenticationReceiptTtlMs <= policy.ttlMs && validIdentifier(policy.keyId, 1, 64)
    && policy.sealingKey instanceof Uint8Array && policy.sealingKey.length === 32
    && Number.isSafeInteger(policy.maxCompletionFailures) && policy.maxCompletionFailures >= 1 && policy.maxCompletionFailures <= 10
    && Number.isSafeInteger(policy.redeemNetworkWindowSeconds) && policy.redeemNetworkWindowSeconds >= 1 && policy.redeemNetworkWindowSeconds <= 86_400
    && Number.isSafeInteger(policy.maxRedeemNetworkFailures) && policy.maxRedeemNetworkFailures >= 1 && policy.maxRedeemNetworkFailures <= 100
    && rate !== null && typeof rate === "object"
    && [rate.cooldownSeconds, rate.maxActiveLinks, rate.addressWindowSeconds, rate.maxAddressWindow,
      rate.addressDaySeconds, rate.maxAddressDay, rate.networkWindowSeconds, rate.maxNetworkWindow]
      .every((value) => positive(value));
}

function validSessionPolicy(policy: Slice4SessionRoutePolicy): boolean {
  return validIdentifier(policy.version, 1, 64) && positive(policy.accessTtlMs)
    && positive(policy.refreshInactivityTtlMs) && positive(policy.refreshAbsoluteTtlMs)
    && policy.accessTtlMs <= policy.refreshAbsoluteTtlMs && policy.refreshInactivityTtlMs <= policy.refreshAbsoluteTtlMs;
}

function validIdentityPolicy(policy: Slice4IdentityRoutePolicy): boolean {
  return validIdentifier(policy.version, 1, 64) && positive(policy.candidateProofTtlMs) && policy.candidateProofTtlMs <= 300_000;
}

function validApplePolicy(policy: Slice4DataApiRouteApplicationDependencies["apple"]): boolean {
  return validIdentifier(policy.version, 1, 64) && /^[A-Za-z0-9._-]{1,256}$/u.test(policy.clientId)
    && /^https:\/\//u.test(policy.redirectUri) && policy.redirectUri.length <= 2_048
    && positive(policy.attemptTtlMs) && positive(policy.bridgeProofTtlMs) && positive(policy.verifiedAuthenticationReceiptTtlMs)
    && policy.transport !== null && typeof policy.transport.request === "function"
    && policy.privateKeySecrets !== null && typeof policy.privateKeySecrets.read === "function"
    && validIdentifier(policy.privateKeySecretName, 1, 256) && /^[A-Za-z0-9]+$/u.test(policy.teamId)
    && /^[A-Za-z0-9]+$/u.test(policy.keyId) && positive(policy.clientSecretLifetimeSeconds)
    && positive(policy.exchangeTimeoutMs) && positive(policy.exchangeMaxResponseBytes)
    && policy.jwks !== null && typeof policy.jwks.fetch === "function"
    && positive(policy.jwksCacheTtlMs) && Number.isSafeInteger(policy.clockSkewMs) && policy.clockSkewMs >= 0
    && positive(policy.maxTokenAgeMs)
    && policy.cognito !== null && typeof policy.cognito.adminAuthenticate === "function" && typeof policy.cognito.adminLink === "function";
}

function mintSessionMaterial(clock: Slice4RouteClock, random: Slice4RouteRandom, keys: Slice4RouteHashKeys, policy: Slice4SessionRoutePolicy, now: number): AppOwnedSessionMaterial {
  const issuedAt = new Date(now);
  const accessToken = opaqueFrom(random, 32);
  const refreshToken = opaqueFrom(random, 32);
  if (accessToken === refreshToken) throw new DataApiRouteApplicationError("unavailable");
  const accessExpiresAt = new Date(checkedAdd(now, policy.accessTtlMs));
  const absoluteExpiresAt = new Date(checkedAdd(now, policy.refreshAbsoluteTtlMs));
  const inactivityExpiresAt = new Date(Math.min(checkedAdd(now, policy.refreshInactivityTtlMs), absoluteExpiresAt.getTime()));
  return Object.freeze({
    familyPublicId: `fam_${opaqueFrom(random, 16)}`,
    accessToken,
    accessTokenHash: createHmac("sha256", keys.accessTokenHmacKey).update(accessToken).digest(),
    refreshToken,
    refreshTokenHash: createHmac("sha256", keys.refreshTokenHmacKey).update(refreshToken).digest(),
    authenticatedAt: new Date(now),
    issuedAt,
    accessExpiresAt,
    inactivityExpiresAt,
    absoluteExpiresAt,
    policyVersion: policy.version,
  });
}

function applePublicValues(random: Slice4RouteRandom): Readonly<{ readonly attemptId: string; readonly state: string; readonly nonce: string }> {
  return Object.freeze({ attemptId: `att_${opaqueFrom(random, 16)}`, state: opaqueFrom(random, 32), nonce: opaqueFrom(random, 32) });
}

function sealMagicSecret(key: Uint8Array, secret: Uint8Array, iv: Uint8Array): Readonly<{ readonly iv: Uint8Array; readonly ciphertext: Uint8Array; readonly authenticationTag: Uint8Array }> {
  try {
    const cipher = createCipheriv("aes-256-gcm", key, iv);
    const ciphertext = Buffer.concat([cipher.update(secret), cipher.final()]);
    const authenticationTag = cipher.getAuthTag();
    if (ciphertext.length !== 32 || authenticationTag.length !== 16) throw new Error("invalid");
    return Object.freeze({ iv: Uint8Array.from(iv), ciphertext: Uint8Array.from(ciphertext), authenticationTag: Uint8Array.from(authenticationTag) });
  } catch {
    throw new DataApiRouteApplicationError("unavailable");
  }
}

function quotaHttpValue(entry: Readonly<{ readonly metric: "project_count" | "member_count" | "working_bytes" | "raw_bytes" | "portal_bytes"; readonly used: number; readonly reserved: number; readonly limit: number; readonly warningThresholdPercent: number }>): Readonly<{ readonly metric: "project_count" | "member_count" | "working_bytes" | "raw_bytes" | "portal_bytes"; readonly used: number; readonly reserved: number; readonly limit: number; readonly warning: boolean; readonly overLimit: boolean }> {
  const allocated = BigInt(entry.used) + BigInt(entry.reserved);
  const limit = BigInt(entry.limit);
  return Object.freeze({
    metric: entry.metric,
    used: entry.used,
    reserved: entry.reserved,
    limit: entry.limit,
    warning: entry.limit === 0 || allocated * 100n >= limit * BigInt(entry.warningThresholdPercent),
    overLimit: allocated > limit,
  });
}

function digest(key: Uint8Array, value: string | Uint8Array): string {
  return createHmac("sha256", key).update(value).digest("base64url");
}

function domainDigest(key: Uint8Array, label: string, value: string | Uint8Array): string {
  return createHmac("sha256", key).update(label, "utf8").update("\0", "utf8").update(value).digest("base64url");
}

function deterministicAuditId(key: Uint8Array, label: string, accessDigest: Uint8Array, ...parts: readonly string[]): string {
  const mac = createHmac("sha256", key).update(label, "utf8").update("\0", "utf8").update(accessDigest);
  for (const part of parts) mac.update("\0", "utf8").update(part, "utf8");
  return `aud_${mac.digest("base64url")}`;
}

function magicCompletionMaterial(verifier: Uint8Array, completionId: Uint8Array, label: string): Uint8Array {
  try {
    const material = Buffer.from(hkdfSync("sha256", verifier, completionId, Buffer.from(label, "utf8"), 32));
    if (material.length !== 32) throw new Error("invalid");
    return Uint8Array.from(material);
  } catch {
    throw new DataApiRouteApplicationError("unavailable");
  }
}

function magicTransferCode(key: Uint8Array, selector: string, secret: Uint8Array): string {
  const bytes = createHmac("sha256", key)
    .update("roomscan.slice4.magic-completion.v3/transfer-code", "utf8")
    .update("\0", "utf8").update(selector, "utf8").update("\0", "utf8").update(secret).digest().subarray(0, 5);
  const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
  let value = 0n;
  for (const byte of bytes) value = (value << 8n) | BigInt(byte);
  let encoded = "";
  for (let shift = 35n; shift >= 0n; shift -= 5n) encoded += alphabet[Number((value >> shift) & 31n)]!;
  return encoded;
}

function requireNow(clock: Slice4RouteClock): number {
  const now = clock.nowMs();
  if (!Number.isSafeInteger(now) || now <= 0) throw new DataApiRouteApplicationError("unavailable");
  return now;
}

function checkedAdd(left: number, right: number): number {
  if (!positive(right) || !Number.isSafeInteger(left) || left > Number.MAX_SAFE_INTEGER - right) {
    throw new DataApiRouteApplicationError("unavailable");
  }
  return left + right;
}

function randomBytes(random: Slice4RouteRandom, length: number): Uint8Array {
  const bytes = random.bytes(length);
  if (!(bytes instanceof Uint8Array) || bytes.length !== length) throw new DataApiRouteApplicationError("unavailable");
  return Uint8Array.from(bytes);
}

function opaqueFrom(random: Slice4RouteRandom, bytes: number): string {
  return Buffer.from(randomBytes(random, bytes)).toString("base64url");
}

function opaque(value: unknown): value is string {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]{43}$/u.test(value)) return false;
  const bytes = Buffer.from(value, "base64url");
  return bytes.length === 32 && bytes.toString("base64url") === value;
}

function codeChallengeValue(value: unknown): value is string {
  return typeof value === "string" && /^[A-Za-z0-9_-]{43}$/u.test(value)
    && Buffer.from(value, "base64url").length === 32 && Buffer.from(value, "base64url").toString("base64url") === value;
}

function transferCodeValue(value: unknown): value is string {
  return typeof value === "string" && /^[0-9A-HJKMNP-TV-Z]{8}$/u.test(value);
}

function selectorValue(value: unknown): value is string {
  return typeof value === "string" && /^[A-Za-z0-9_-]{22}$/u.test(value)
    && Buffer.from(value, "base64url").length === 16;
}

function attemptIdValue(value: unknown): value is string {
  return typeof value === "string" && /^att_[A-Za-z0-9_-]{22}$/u.test(value);
}

function codeVerifier(value: unknown): value is string {
  return typeof value === "string" && /^[A-Za-z0-9._~-]{43,128}$/u.test(value);
}

function validClickingDevice(value: unknown): value is string {
  return typeof value === "string" && /^apigw:[A-Za-z0-9._~=-]{1,128}$/u.test(value);
}

function validSourceIp(value: unknown): value is string {
  return typeof value === "string" && value.length >= 3 && value.length <= 64;
}

function validIdentifier(value: unknown, minimum: number, maximum: number): value is string {
  return typeof value === "string" && value.length >= minimum && value.length <= maximum && /^[A-Za-z0-9._-]+$/u.test(value);
}

function boundedText(value: unknown, minimum: number, maximum: number): value is string {
  return typeof value === "string" && value.length >= minimum && value.length <= maximum;
}

function canonicalDateMilliseconds(value: string): number {
  const parsed = new Date(value);
  if (!Number.isSafeInteger(parsed.getTime()) || parsed.toISOString() !== value) throw new DataApiRouteApplicationError("unavailable");
  return parsed.getTime();
}

function positive(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0;
}

function normalizeDeliveryIdentity(input: string): string | undefined {
  const trimmed = input.trim();
  if (trimmed.length > 320 || /\s/u.test(trimmed)) return undefined;
  const separator = trimmed.lastIndexOf("@");
  if (separator <= 0 || separator === trimmed.length - 1) return undefined;
  const local = trimmed.slice(0, separator); const domain = trimmed.slice(separator + 1);
  if (local.length > 64 || domain.length > 255 || !domain.includes(".") || domain.startsWith(".") || domain.endsWith(".") || !/^[A-Za-z0-9.-]+$/u.test(domain)) return undefined;
  return `${local}@${domain.toLowerCase()}`;
}

function workspaceSlug(input: string): string | undefined {
  return /^[a-z0-9][a-z0-9-]{2,62}$/u.test(input) ? input : undefined;
}

function workspaceDisplayName(input: string): string | undefined {
  const normalized = input.normalize("NFC");
  return normalized.length >= 1 && normalized.length <= 160 && !/[\u0000-\u001f\u007f-\u009f]/u.test(normalized) ? normalized : undefined;
}
