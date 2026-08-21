import assert from "node:assert/strict";
import {
  createHash,
  generateKeyPairSync,
  sign,
  type KeyObject,
} from "node:crypto";
import { test } from "node:test";

import {
  APPLE_ISSUER,
  AppleAuthError,
  AppleAuthService,
  DEFAULT_APPLE_AUTH_POLICY,
  type AppleAttemptClaim,
  type AppleAttemptClaimResult,
  type AppleAuthAttempt,
  type AppleBridgeProofClaim,
  type AppleBridgeProofRecord,
  type AppleAuthStore,
  type AppleAuthTransaction,
  type AppleCodeExchangePort,
  type AppleJwk,
  type AppleJwksPort,
  type CognitoIdentityBridge,
} from "../apple-auth.js";
import {
  CandidateIdentityProofService,
  DEFAULT_IDENTITY_LINK_POLICY,
  IdentityLinkingService,
  type RecentSessionVerifier,
  type TrustedRecentSession,
  type VerifiedAuthenticationReceipt,
} from "../identity-linking.js";
import {
  FlowIdentityStore,
  seedFlowPrincipal,
} from "./support/identity-store.js";
import {
  AsyncOperationGate,
  observeSettlement,
} from "./support/async-operation-gate.js";

const CLIENT_ID = "com.roomscan.studio";
const REDIRECT_URI = "https://auth.roomscan.example/apple/callback";
const VERIFIER = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~abcd";
const CURRENT_ACCESS_TOKEN = Buffer.alloc(32, 0xa8).toString("base64url");

function challengeFor(verifier: string): string {
  return createHash("sha256").update(verifier).digest("base64url");
}

class ManualClock {
  constructor(private current = Date.UTC(2026, 7, 18, 10, 0, 0)) {}

  nowMs(): number {
    return this.current;
  }

  advance(milliseconds: number): void {
    this.current += milliseconds;
  }
}

class SequenceRandom {
  readonly requestedLengths: number[] = [];
  private next = 1;

  bytes(length: number): Uint8Array {
    this.requestedLengths.push(length);
    const seed = this.next++;
    return Uint8Array.from({ length }, (_, index) => (seed * 17 + index) & 0xff);
  }
}

class MemoryAppleStore implements AppleAuthStore, AppleAuthTransaction {
  readonly attempts: AppleAuthAttempt[] = [];
  readonly codeHashes = new Set<string>();
  readonly nonceHashes = new Set<string>();
  readonly bridgeProofs: AppleBridgeProofRecord[] = [];
  readonly verifiedAuthenticationReceipts: VerifiedAuthenticationReceipt[];
  loseNextAttemptClaim = false;
  loseNextNonceClaim = false;
  loseNextBridgeProofClaim = false;
  bridgeProofOverride: Partial<AppleBridgeProofRecord> | undefined;
  afterBridgeProofInsert: (() => void | Promise<void>) | undefined;
  readonly operationGate = new AsyncOperationGate();
  private tail: Promise<void> = Promise.resolve();

  constructor(verifiedAuthenticationReceipts: VerifiedAuthenticationReceipt[] = []) {
    this.verifiedAuthenticationReceipts = verifiedAuthenticationReceipts;
  }

  async transaction<T>(work: (transaction: AppleAuthTransaction) => Promise<T>): Promise<T> {
    const previous = this.tail;
    let release = (): void => undefined;
    this.tail = new Promise<void>((resolve) => {
      release = resolve;
    });
    await previous;
    const snapshot = {
      attempts: structuredClone(this.attempts),
      codeHashes: structuredClone(this.codeHashes),
      nonceHashes: structuredClone(this.nonceHashes),
      bridgeProofs: structuredClone(this.bridgeProofs),
      verifiedAuthenticationReceipts: structuredClone(this.verifiedAuthenticationReceipts),
    };
    try {
      return await work(this);
    } catch (error) {
      this.attempts.splice(0, this.attempts.length, ...snapshot.attempts);
      this.codeHashes.clear();
      for (const value of snapshot.codeHashes) this.codeHashes.add(value);
      this.nonceHashes.clear();
      for (const value of snapshot.nonceHashes) this.nonceHashes.add(value);
      this.bridgeProofs.splice(0, this.bridgeProofs.length, ...snapshot.bridgeProofs);
      this.verifiedAuthenticationReceipts.splice(
        0,
        this.verifiedAuthenticationReceipts.length,
        ...snapshot.verifiedAuthenticationReceipts,
      );
      throw error;
    } finally {
      release();
    }
  }

  async insertAttempt(attempt: AppleAuthAttempt): Promise<void> {
    await this.operationGate.before("insertAttempt");
    this.attempts.push(structuredClone(attempt));
  }

  async findAttempt(attemptId: string): Promise<AppleAuthAttempt | undefined> {
    return this.attempts.find((attempt) => attempt.id === attemptId);
  }

  async claimPendingAttemptAndCode(claim: AppleAttemptClaim): Promise<AppleAttemptClaimResult> {
    await this.operationGate.before("claimPendingAttemptAndCode");
    if (this.loseNextAttemptClaim) {
      this.loseNextAttemptClaim = false;
      return { status: "invalid_attempt" };
    }
    const attempt = await this.findAttempt(claim.attemptId);
    if (
      attempt === undefined ||
      attempt.state !== "pending" ||
      attempt.expiresAtMs <= claim.nowMs ||
      attempt.stateHash !== claim.stateHash ||
      attempt.codeChallenge !== claim.codeChallenge
    ) {
      return { status: "invalid_attempt" };
    }
    if (this.codeHashes.has(claim.codeHash)) {
      return { status: "replayed_code" };
    }
    attempt.state = "claimed";
    attempt.claimedAtMs = claim.nowMs;
    this.codeHashes.add(claim.codeHash);
    return { status: "claimed", attempt: structuredClone(attempt) };
  }

  async claimNonceIfUnused(nonceHash: string): Promise<boolean> {
    await this.operationGate.before("claimNonceIfUnused");
    if (this.loseNextNonceClaim || this.nonceHashes.has(nonceHash)) {
      this.loseNextNonceClaim = false;
      return false;
    }
    this.nonceHashes.add(nonceHash);
    return true;
  }

  async insertBridgeProof(proof: AppleBridgeProofRecord): Promise<void> {
    await this.operationGate.before("insertBridgeProof");
    this.bridgeProofs.push(structuredClone({ ...proof, ...this.bridgeProofOverride }));
    await this.afterBridgeProofInsert?.();
  }

  async claimBridgeProof(claim: AppleBridgeProofClaim): Promise<AppleBridgeProofRecord | undefined> {
    await this.operationGate.before("claimBridgeProof");
    if (this.loseNextBridgeProofClaim) {
      this.loseNextBridgeProofClaim = false;
      return undefined;
    }
    const proof = this.bridgeProofs.find((candidate) =>
      candidate.tokenHash === claim.tokenHash &&
      candidate.state === "active" &&
      candidate.issuer === claim.issuer &&
      candidate.subject === claim.subject &&
      candidate.attemptId === claim.attemptId &&
      candidate.purpose === claim.purpose &&
      candidate.expiresAtMs > claim.nowMs,
    );
    if (proof === undefined) return undefined;
    proof.state = "consumed";
    proof.consumedAtMs = claim.nowMs;
    return structuredClone(proof);
  }

  async insertVerifiedAuthenticationReceipt(
    receipt: VerifiedAuthenticationReceipt,
  ): Promise<void> {
    this.verifiedAuthenticationReceipts.push(structuredClone(receipt));
  }
}

const primaryKeys = generateKeyPairSync("rsa", { modulusLength: 2048 });
const rotatedKeys = generateKeyPairSync("rsa", { modulusLength: 2048 });
const attackerKeys = generateKeyPairSync("rsa", { modulusLength: 2048 });

function publicJwk(publicKey: KeyObject, kid: string): AppleJwk {
  return {
    ...(publicKey.export({ format: "jwk" }) as AppleJwk),
    alg: "RS256",
    kid,
    use: "sig",
  };
}

const primaryJwk = publicJwk(primaryKeys.publicKey, "primary-key");
const rotatedJwk = publicJwk(rotatedKeys.publicKey, "rotated-key");

function jwt(
  payload: Readonly<Record<string, unknown>>,
  options: {
    readonly alg?: string;
    readonly kid?: string;
    readonly privateKey?: KeyObject;
    readonly extraHeader?: Readonly<Record<string, unknown>>;
  } = {},
): string {
  const header = {
    alg: options.alg ?? "RS256",
    kid: options.kid ?? "primary-key",
    typ: "JWT",
    ...options.extraHeader,
  };
  const encodedHeader = Buffer.from(JSON.stringify(header)).toString("base64url");
  const encodedPayload = Buffer.from(JSON.stringify(payload)).toString("base64url");
  const signingInput = `${encodedHeader}.${encodedPayload}`;
  const signature = sign("RSA-SHA256", Buffer.from(signingInput), options.privateKey ?? primaryKeys.privateKey);
  return `${signingInput}.${signature.toString("base64url")}`;
}

interface Harness {
  service: AppleAuthService;
  readonly clock: ManualClock;
  readonly random: SequenceRandom;
  readonly store: MemoryAppleStore;
  readonly exchangeCalls: Array<Record<string, unknown>>;
  readonly bridgeCalls: Array<Record<string, unknown>>;
  readonly jwksCalls: boolean[];
  exchangeDelayMs: number;
  jwksDelayMs: number;
  exchangeResult: string | Error;
  normalKeys: AppleJwk[];
  forcedKeys: AppleJwk[];
}

function makeHarness(overrides: {
  readonly recentSessions?: RecentSessionVerifier;
  readonly verifiedAuthenticationReceipts?: VerifiedAuthenticationReceipt[];
} = {}): Harness {
  const clock = new ManualClock();
  const random = new SequenceRandom();
  const store = new MemoryAppleStore(overrides.verifiedAuthenticationReceipts);
  const exchangeCalls: Array<Record<string, unknown>> = [];
  const bridgeCalls: Array<Record<string, unknown>> = [];
  const jwksCalls: boolean[] = [];
  const harness = {
    clock,
    random,
    store,
    exchangeCalls,
    bridgeCalls,
    jwksCalls,
    exchangeDelayMs: 0,
    jwksDelayMs: 0,
    exchangeResult: new Error("ID token not configured") as string | Error,
    normalKeys: [primaryJwk],
    forcedKeys: [primaryJwk],
  } as Harness;
  const exchange: AppleCodeExchangePort = {
    async exchange(input) {
      exchangeCalls.push(structuredClone(input));
      clock.advance(harness.exchangeDelayMs);
      if (harness.exchangeResult instanceof Error) {
        throw harness.exchangeResult;
      }
      return { idToken: harness.exchangeResult };
    },
  };
  const jwks: AppleJwksPort = {
    async trustedKeys(forceRefresh) {
      jwksCalls.push(forceRefresh);
      clock.advance(harness.jwksDelayMs);
      return forceRefresh ? harness.forcedKeys : harness.normalKeys;
    },
  };
  const bridge: CognitoIdentityBridge = {
    async authenticate(input) {
      bridgeCalls.push(structuredClone(input));
      return { principalId: "prn_stable", accessToken: "COGNITO_ACCESS_CANARY" } as never;
    },
  };
  const recentSession: TrustedRecentSession = {
    principalId: "principal-a",
    familyId: "family-a",
    authenticatedAtMs: clock.nowMs(),
  };
  const defaultRecentSessions: RecentSessionVerifier = {
    async verifyRecentSession(accessToken) {
      if (accessToken !== CURRENT_ACCESS_TOKEN) throw new Error("invalid access");
      return structuredClone(recentSession);
    },
  };
  harness.service = new AppleAuthService({
    clock,
    random,
    store,
    exchange,
    jwks,
    bridge,
    recentSessions: overrides.recentSessions ?? defaultRecentSessions,
    stateHmacKey: Buffer.alloc(32, 0x51),
    receiptHmacKey: Buffer.alloc(32, 0x52),
    proofHmacKey: Buffer.alloc(32, 0x53),
    verifiedAuthenticationReceiptHmacKey: Buffer.alloc(32, 0x54),
    policy: DEFAULT_APPLE_AUTH_POLICY,
    expectedClientId: CLIENT_ID,
    redirectUri: REDIRECT_URI,
  } as ConstructorParameters<typeof AppleAuthService>[0]);
  return harness;
}

async function begin(harness: Harness) {
  return harness.service.begin({
    codeChallenge: challengeFor(VERIFIER),
  } as never);
}

function validClaims(harness: Harness, nonce: string, overrides: Record<string, unknown> = {}) {
  const nowSeconds = Math.floor(harness.clock.nowMs() / 1000);
  return {
    iss: APPLE_ISSUER,
    aud: CLIENT_ID,
    sub: "apple-subject-123",
    nonce,
    exp: nowSeconds + 300,
    iat: nowSeconds,
    email: "relay@privaterelay.appleid.com",
    email_verified: true,
    is_private_email: true,
    ...overrides,
  };
}

async function configureValidToken(harness: Harness, nonce: string): Promise<void> {
  harness.exchangeResult = jwt(validClaims(harness, nonce));
}

async function finish(harness: Harness, attempt: Awaited<ReturnType<typeof begin>>, overrides: Record<string, unknown> = {}) {
  return harness.service.finish({
    attemptId: attempt.attemptId,
    state: attempt.state,
    code: "apple-code-one",
    codeVerifier: VERIFIER,
    clientClaims: {
      email: "attacker@example.com",
      name: "Forged Name",
      subject: "forged-subject",
    },
    ...overrides,
  });
}

async function expectCode(promise: Promise<unknown>, code: string): Promise<void> {
  await assert.rejects(
    promise,
    (error: unknown) => error instanceof AppleAuthError && error.code === code,
  );
}

test("begin stores only hashes, binds S256 to server-owned client/redirect, and expires in five minutes", async () => {
  const harness = makeHarness();
  const result = await begin(harness);

  assert.equal(Buffer.from(result.state, "base64url").length, 32);
  assert.equal(Buffer.from(result.nonce, "base64url").length, 32);
  assert.deepEqual(harness.random.requestedLengths, [16, 32, 32]);
  const stored = harness.store.attempts[0];
  assert.ok(stored);
  assert.equal(stored.codeChallenge, challengeFor(VERIFIER));
  assert.equal(stored.expectedClientId, CLIENT_ID);
  assert.equal(stored.redirectUri, REDIRECT_URI);
  assert.equal(stored.purpose, "sign-in");
  assert.equal(stored.expiresAtMs - stored.createdAtMs, 5 * 60_000);
  assert.equal(JSON.stringify(stored).includes(result.state), false);
  assert.equal(JSON.stringify(stored).includes(result.nonce), false);
  await expectCode(
    harness.service.begin({
      codeChallenge: "plain-verifier",
    } as never),
    "invalid_request",
  );
});

test("caller-supplied provider coordinates cannot replace server-owned Apple configuration", async () => {
  const harness = makeHarness();
  const result = await harness.service.begin({
    codeChallenge: challengeFor(VERIFIER),
    expectedClientId: "com.attacker.app",
    redirectUri: "https://evil.example/callback",
  } as never);
  const stored = await harness.store.findAttempt(result.attemptId);
  assert.equal(stored?.expectedClientId, CLIENT_ID);
  assert.equal(stored?.redirectUri, REDIRECT_URI);
  await expectCode(
    harness.service.beginCandidate({
      currentAccessToken: CURRENT_ACCESS_TOKEN,
      codeChallenge: challengeFor(VERIFIER),
      purpose: "sign-in",
    } as never),
    "invalid_request",
  );
});

test("valid RS256 control authenticates validated issuer/subject through only an internal proof", async () => {
  const harness = makeHarness();
  const attempt = await begin(harness);
  await configureValidToken(harness, attempt.nonce);

  const result = await finish(harness, attempt);

  assert.deepEqual(result, {
    principalId: "prn_stable",
    identity: {
      issuer: APPLE_ISSUER,
      subject: "apple-subject-123",
      emailMetadata: {
        email: "relay@privaterelay.appleid.com",
        isPrivateRelay: true,
        verified: true,
      },
    },
  });
  assert.deepEqual(harness.jwksCalls, [false]);
  assert.equal(harness.exchangeCalls.length, 1);
  assert.deepEqual(Object.keys(harness.bridgeCalls[0] ?? {}).sort(), ["attemptId", "internalProof", "issuer", "purpose", "subject"]);
  assert.equal(harness.bridgeCalls[0]?.issuer, APPLE_ISSUER);
  assert.equal(harness.bridgeCalls[0]?.subject, "apple-subject-123");
  assert.notEqual(harness.bridgeCalls[0]?.internalProof, undefined);
  assert.equal(harness.bridgeCalls[0]?.attemptId, attempt.attemptId);
  assert.equal(harness.bridgeCalls[0]?.purpose, "sign-in");
  assert.equal(JSON.stringify(harness.store.bridgeProofs).includes(String(harness.bridgeCalls[0]?.internalProof)), false);
  assert.equal(JSON.stringify(result).includes("attacker@example.com"), false);
  assert.equal(JSON.stringify(result).includes(String(harness.exchangeResult)), false);
  assert.equal(JSON.stringify(result).includes("COGNITO_ACCESS_CANARY"), false);
  assert.equal("internalProof" in result, false);
});

test("issuer, exact audience, signature, algorithm, and token-controlled key URLs fail closed", async (context) => {
  const cases: Array<{
    readonly name: string;
    readonly claims?: Record<string, unknown>;
    readonly tokenOptions?: Parameters<typeof jwt>[1];
    readonly expected: string;
  }> = [
    { name: "issuer", claims: { iss: "https://evil.example" }, expected: "invalid_token" },
    { name: "audience", claims: { aud: "com.other.app" }, expected: "invalid_token" },
    {
      name: "signature",
      tokenOptions: { privateKey: attackerKeys.privateKey },
      expected: "invalid_token",
    },
    { name: "algorithm", tokenOptions: { alg: "HS256" }, expected: "invalid_token" },
    {
      name: "remote jku",
      tokenOptions: { extraHeader: { jku: "https://evil.example/keys" } },
      expected: "invalid_token",
    },
    {
      name: "remote x5u",
      tokenOptions: { extraHeader: { x5u: "https://evil.example/cert" } },
      expected: "invalid_token",
    },
  ];

  for (const item of cases) {
    await context.test(item.name, async () => {
      const harness = makeHarness();
      const attempt = await begin(harness);
      harness.exchangeResult = jwt(validClaims(harness, attempt.nonce, item.claims), item.tokenOptions);
      await expectCode(finish(harness, attempt), item.expected);
      assert.equal(harness.bridgeCalls.length, 0);
    });
  }
});

test("unknown kid forces exactly one refresh, accepts rotation, and otherwise fails closed", async () => {
  const rotatedHarness = makeHarness();
  const rotatedAttempt = await begin(rotatedHarness);
  rotatedHarness.normalKeys = [primaryJwk];
  rotatedHarness.forcedKeys = [primaryJwk, rotatedJwk];
  rotatedHarness.exchangeResult = jwt(validClaims(rotatedHarness, rotatedAttempt.nonce), {
    kid: "rotated-key",
    privateKey: rotatedKeys.privateKey,
  });
  assert.equal((await finish(rotatedHarness, rotatedAttempt)).principalId, "prn_stable");
  assert.deepEqual(rotatedHarness.jwksCalls, [false, true]);

  const unknownHarness = makeHarness();
  const unknownAttempt = await begin(unknownHarness);
  unknownHarness.normalKeys = [primaryJwk];
  unknownHarness.forcedKeys = [primaryJwk];
  unknownHarness.exchangeResult = jwt(validClaims(unknownHarness, unknownAttempt.nonce), {
    kid: "never-trusted",
  });
  await expectCode(finish(unknownHarness, unknownAttempt), "unknown_key");
  assert.deepEqual(unknownHarness.jwksCalls, [false, true]);
});

test("expired, future, stale, missing-subject, and wrong-nonce tokens fail bounded time validation", async (context) => {
  const cases: Array<{ readonly name: string; readonly claims: (h: Harness) => Record<string, unknown> }> = [
    { name: "expired", claims: (h) => ({ exp: Math.floor(h.clock.nowMs() / 1000) - 31 }) },
    { name: "future iat", claims: (h) => ({ iat: Math.floor(h.clock.nowMs() / 1000) + 31 }) },
    { name: "stale iat", claims: (h) => ({ iat: Math.floor(h.clock.nowMs() / 1000) - 331 }) },
    { name: "empty subject", claims: () => ({ sub: "" }) },
    { name: "wrong nonce", claims: () => ({ nonce: "different-nonce" }) },
  ];
  for (const item of cases) {
    await context.test(item.name, async () => {
      const harness = makeHarness();
      const attempt = await begin(harness);
      harness.exchangeResult = jwt(validClaims(harness, attempt.nonce, item.claims(harness)));
      await expectCode(finish(harness, attempt), "invalid_token");
      assert.equal(harness.bridgeCalls.length, 0);
    });
  }
});

test("state, PKCE, expiry, missing code, and code replay fail before a second exchange", async () => {
  const stateHarness = makeHarness();
  const stateAttempt = await begin(stateHarness);
  await configureValidToken(stateHarness, stateAttempt.nonce);
  await expectCode(finish(stateHarness, stateAttempt, { state: "wrong-state" }), "invalid_attempt");
  assert.equal(stateHarness.exchangeCalls.length, 0);

  const pkceHarness = makeHarness();
  const pkceAttempt = await begin(pkceHarness);
  await configureValidToken(pkceHarness, pkceAttempt.nonce);
  await expectCode(finish(pkceHarness, pkceAttempt, { codeVerifier: "" }), "invalid_attempt");
  await expectCode(finish(pkceHarness, pkceAttempt, { codeVerifier: `${VERIFIER}x` }), "invalid_attempt");
  assert.equal(pkceHarness.exchangeCalls.length, 0);

  const expiredHarness = makeHarness();
  const expiredAttempt = await begin(expiredHarness);
  await configureValidToken(expiredHarness, expiredAttempt.nonce);
  expiredHarness.clock.advance(5 * 60_000);
  await expectCode(finish(expiredHarness, expiredAttempt), "invalid_attempt");

  const codeHarness = makeHarness();
  const first = await begin(codeHarness);
  await configureValidToken(codeHarness, first.nonce);
  await finish(codeHarness, first);
  const second = await begin(codeHarness);
  await configureValidToken(codeHarness, second.nonce);
  await expectCode(finish(codeHarness, second), "replayed_code");
  await expectCode(finish(codeHarness, first), "invalid_attempt");
  assert.equal(codeHarness.exchangeCalls.length, 1);

  const missingCodeHarness = makeHarness();
  const missingCodeAttempt = await begin(missingCodeHarness);
  await expectCode(finish(missingCodeHarness, missingCodeAttempt, { code: "" }), "invalid_attempt");
});

test("nonce receipt prevents replay across attempts even when storage receives a repeated nonce hash", async () => {
  const harness = makeHarness();
  const first = await begin(harness);
  await configureValidToken(harness, first.nonce);
  await finish(harness, first, { code: "first-code" });

  const second = await begin(harness);
  const firstStored = harness.store.attempts[0];
  const secondStored = harness.store.attempts[1];
  assert.ok(firstStored);
  assert.ok(secondStored);
  secondStored.nonceHash = firstStored.nonceHash;
  harness.exchangeResult = jwt(validClaims(harness, first.nonce));
  await expectCode(finish(harness, second, { code: "second-code" }), "replayed_nonce");
  assert.equal(harness.bridgeCalls.length, 1);
});

test("concurrent finish claims attempt/code once and cannot mint two bridge identities", async () => {
  const harness = makeHarness();
  const attempt = await begin(harness);
  await configureValidToken(harness, attempt.nonce);

  const results = await Promise.allSettled(
    Array.from({ length: 12 }, () => finish(harness, attempt)),
  );

  assert.equal(results.filter((result) => result.status === "fulfilled").length, 1);
  assert.equal(results.filter((result) => result.status === "rejected").length, 11);
  assert.equal(harness.exchangeCalls.length, 1);
  assert.equal(harness.bridgeCalls.length, 1);
});

test("exchange errors consume the attempt and client claims never alter identity", async () => {
  const errorHarness = makeHarness();
  const errorAttempt = await begin(errorHarness);
  errorHarness.exchangeResult = new Error("provider unavailable with token-like secret");
  await expectCode(finish(errorHarness, errorAttempt), "exchange_failed");
  await expectCode(finish(errorHarness, errorAttempt), "invalid_attempt");
  assert.equal(errorHarness.exchangeCalls.length, 1);
  assert.equal(errorHarness.bridgeCalls.length, 0);

  const claimHarness = makeHarness();
  const claimAttempt = await begin(claimHarness);
  claimHarness.exchangeResult = jwt(
    validClaims(claimHarness, claimAttempt.nonce, {
      email: "validated@example.com",
      email_verified: true,
      is_private_email: false,
    }),
  );
  const result = await finish(claimHarness, claimAttempt, {
    clientClaims: {
      email: "owner@example.com",
      name: "Owner",
      subject: "different-subject",
    },
  });
  assert.equal(result.identity.subject, "apple-subject-123");
  assert.equal(result.identity.emailMetadata?.email, "validated@example.com");
  assert.equal(claimHarness.bridgeCalls[0]?.subject, "apple-subject-123");
  assert.equal(JSON.stringify(claimHarness.bridgeCalls[0]).includes("validated@example.com"), false);
});

test("attempt/code and nonce claims reject an adversarially lost storage transition", async () => {
  const attemptHarness = makeHarness();
  const attempt = await begin(attemptHarness);
  await configureValidToken(attemptHarness, attempt.nonce);
  attemptHarness.store.loseNextAttemptClaim = true;
  await expectCode(finish(attemptHarness, attempt), "invalid_attempt");
  assert.equal(attemptHarness.exchangeCalls.length, 0);

  const nonceHarness = makeHarness();
  const nonceAttempt = await begin(nonceHarness);
  await configureValidToken(nonceHarness, nonceAttempt.nonce);
  nonceHarness.store.loseNextNonceClaim = true;
  await expectCode(finish(nonceHarness, nonceAttempt), "replayed_nonce");
  assert.equal(nonceHarness.bridgeCalls.length, 0);
});

test("Apple begin and finish await delayed async writes and attempt, nonce, and bridge claims", async () => {
  const beginHarness = makeHarness();
  beginHarness.store.operationGate.arm("insertAttempt");
  const delayedBegin = begin(beginHarness);
  const beginSettlement = observeSettlement(delayedBegin);
  await beginHarness.store.operationGate.waitUntilReached();
  assert.equal(beginSettlement.settled(), false);
  assert.equal(beginHarness.store.attempts.length, 0);
  beginHarness.store.operationGate.release();
  await delayedBegin;

  const attemptHarness = makeHarness();
  const attempt = await begin(attemptHarness);
  await configureValidToken(attemptHarness, attempt.nonce);
  attemptHarness.store.loseNextAttemptClaim = true;
  attemptHarness.store.operationGate.arm("claimPendingAttemptAndCode");
  const delayedLostAttempt = finish(attemptHarness, attempt);
  const attemptSettlement = observeSettlement(delayedLostAttempt);
  await attemptHarness.store.operationGate.waitUntilReached();
  assert.equal(attemptSettlement.settled(), false);
  assert.equal(attemptHarness.exchangeCalls.length, 0);
  attemptHarness.store.operationGate.release();
  await expectCode(delayedLostAttempt, "invalid_attempt");

  const nonceHarness = makeHarness();
  const nonceAttempt = await begin(nonceHarness);
  await configureValidToken(nonceHarness, nonceAttempt.nonce);
  nonceHarness.store.operationGate.arm("claimNonceIfUnused");
  const delayedNonce = finish(nonceHarness, nonceAttempt);
  const nonceSettlement = observeSettlement(delayedNonce);
  await nonceHarness.store.operationGate.waitUntilReached();
  assert.equal(nonceSettlement.settled(), false);
  assert.equal(nonceHarness.bridgeCalls.length, 0);
  nonceHarness.store.operationGate.release();
  await delayedNonce;

  const bridgeHarness = makeHarness();
  const bridgeAttempt = await begin(bridgeHarness);
  await configureValidToken(bridgeHarness, bridgeAttempt.nonce);
  bridgeHarness.store.operationGate.arm("claimBridgeProof");
  const delayedBridge = finish(bridgeHarness, bridgeAttempt);
  const bridgeSettlement = observeSettlement(delayedBridge);
  await bridgeHarness.store.operationGate.waitUntilReached();
  assert.equal(bridgeSettlement.settled(), false);
  assert.equal(bridgeHarness.bridgeCalls.length, 0);
  bridgeHarness.store.operationGate.release();
  await delayedBridge;
  assert.equal(bridgeHarness.bridgeCalls.length, 1);
});

test("time is recaptured after slow provider exchange and trusted JWKS retrieval", async () => {
  const exchangeHarness = makeHarness();
  const exchangeAttempt = await begin(exchangeHarness);
  await configureValidToken(exchangeHarness, exchangeAttempt.nonce);
  exchangeHarness.exchangeDelayMs = 5 * 60_000;
  await expectCode(finish(exchangeHarness, exchangeAttempt), "invalid_attempt");
  assert.equal(exchangeHarness.jwksCalls.length, 0);

  const jwksHarness = makeHarness();
  const jwksAttempt = await begin(jwksHarness);
  await configureValidToken(jwksHarness, jwksAttempt.nonce);
  jwksHarness.jwksDelayMs = 5 * 60_000;
  await expectCode(finish(jwksHarness, jwksAttempt), "invalid_attempt");
  assert.deepEqual(jwksHarness.jwksCalls, [false]);
  assert.equal(jwksHarness.bridgeCalls.length, 0);
});

test("validated finish internally creates a hash-only fully bound bridge proof and consumes it once", async () => {
  const harness = makeHarness();
  const attempt = await begin(harness);
  await configureValidToken(harness, attempt.nonce);
  await finish(harness, attempt);
  const internalProof = harness.bridgeCalls[0]?.internalProof;
  assert.equal(typeof internalProof, "string");
  assert.equal(Buffer.from(String(internalProof), "base64url").length, 32);
  assert.equal(JSON.stringify(harness.store.bridgeProofs).includes(String(internalProof)), false);
  assert.deepEqual(
    {
      issuer: harness.store.bridgeProofs[0]?.issuer,
      subject: harness.store.bridgeProofs[0]?.subject,
      attemptId: harness.store.bridgeProofs[0]?.attemptId,
      purpose: harness.store.bridgeProofs[0]?.purpose,
      lifetime: (harness.store.bridgeProofs[0]?.expiresAtMs ?? 0) - (harness.store.bridgeProofs[0]?.issuedAtMs ?? 0),
      state: harness.store.bridgeProofs[0]?.state,
    },
    {
      issuer: APPLE_ISSUER,
      subject: "apple-subject-123",
      attemptId: attempt.attemptId,
      purpose: "sign-in",
      lifetime: 60_000,
      state: "consumed",
    },
  );
});

test("bridge proof mismatch, expiry, and a lost consume CAS all fail before Cognito", async (context) => {
  const mismatches: ReadonlyArray<{
    readonly name: string;
    readonly override: Partial<AppleBridgeProofRecord>;
  }> = [
    { name: "issuer", override: { issuer: "https://evil.example" } },
    { name: "subject", override: { subject: "wrong-subject" } },
    { name: "attempt", override: { attemptId: "wrong-attempt" } },
    { name: "purpose", override: { purpose: "link-identity" } },
  ];
  for (const mismatch of mismatches) {
    await context.test(mismatch.name, async () => {
      const harness = makeHarness();
      const attempt = await begin(harness);
      await configureValidToken(harness, attempt.nonce);
      harness.store.bridgeProofOverride = mismatch.override;
      await expectCode(finish(harness, attempt), "invalid_token");
      assert.equal(harness.bridgeCalls.length, 0);
    });
  }

  await context.test("expiry", async () => {
    const harness = makeHarness();
    const attempt = await begin(harness);
    await configureValidToken(harness, attempt.nonce);
    harness.store.afterBridgeProofInsert = () => {
      harness.clock.advance(DEFAULT_APPLE_AUTH_POLICY.bridgeProofTtlMs);
    };
    await expectCode(finish(harness, attempt), "invalid_token");
    assert.equal(harness.bridgeCalls.length, 0);
  });

  await context.test("lost CAS", async () => {
    const harness = makeHarness();
    const attempt = await begin(harness);
    await configureValidToken(harness, attempt.nonce);
    harness.store.loseNextBridgeProofClaim = true;
    await expectCode(finish(harness, attempt), "invalid_token");
    assert.equal(harness.bridgeCalls.length, 0);
  });
});

test("server-owned Apple link and unlink attempts issue bound verified-auth receipts without Cognito", async (context) => {
  for (const purpose of ["link-identity", "unlink-identity"] as const) {
    await context.test(purpose, async () => {
      const harness = makeHarness();
      const callerControlled = await harness.service.begin({ codeChallenge: challengeFor(VERIFIER), purpose } as never);
      assert.equal((await harness.store.findAttempt(callerControlled.attemptId))?.purpose, "sign-in");
      const attempt = await harness.service.beginCandidate({
        currentAccessToken: CURRENT_ACCESS_TOKEN,
        codeChallenge: challengeFor(VERIFIER),
        purpose,
      });
      assert.equal((await harness.store.findAttempt(attempt.attemptId))?.purpose, purpose);
      await configureValidToken(harness, attempt.nonce);
      const result = await finish(harness, attempt, { code: `${purpose}-code` });
      assert.equal(result.status, "verified-auth-receipt");
      assert.equal(harness.bridgeCalls.length, 0);
      assert.ok(result.verifiedAuthenticationReceiptToken);
      assert.equal(
        JSON.stringify(harness.store.verifiedAuthenticationReceipts).includes(
          result.verifiedAuthenticationReceiptToken,
        ),
        false,
      );
      assert.deepEqual({
        issuer: harness.store.verifiedAuthenticationReceipts[0]?.issuer,
        subject: harness.store.verifiedAuthenticationReceipts[0]?.subject,
        purpose: harness.store.verifiedAuthenticationReceipts[0]?.purpose,
        principalId: harness.store.verifiedAuthenticationReceipts[0]?.initiatingPrincipalId,
        familyId: harness.store.verifiedAuthenticationReceipts[0]?.initiatingFamilyId,
      }, {
        issuer: APPLE_ISSUER,
        subject: "apple-subject-123",
        purpose,
        principalId: "principal-a",
        familyId: "family-a",
      });
    });
  }
});

test("validated Apple identity links and unlinks end to end through bound candidate proofs", async () => {
  const identityClock = new ManualClock();
  const verifiedAuthenticationReceipts: VerifiedAuthenticationReceipt[] = [];
  const identityStore = new FlowIdentityStore(verifiedAuthenticationReceipts);
  seedFlowPrincipal(identityStore, identityClock.nowMs(), [
    { issuer: "email", subject: "owner@example.com" },
  ]);
  const trustedSession: TrustedRecentSession = {
    principalId: "principal-a",
    familyId: "family-a",
    authenticatedAtMs: identityClock.nowMs(),
  };
  const recentSessions: RecentSessionVerifier = {
    async verifyRecentSession(accessToken) {
      if (accessToken !== CURRENT_ACCESS_TOKEN) throw new Error("invalid access");
      return structuredClone(trustedSession);
    },
  };
  const candidateProofs = new CandidateIdentityProofService({
    clock: identityClock,
    random: new SequenceRandom(),
    store: identityStore,
    recentSessions,
    receiptHmacKey: Buffer.alloc(32, 0x54),
    proofHmacKey: Buffer.alloc(32, 0x91),
    policy: DEFAULT_IDENTITY_LINK_POLICY,
  });
  const linking = new IdentityLinkingService({
    clock: identityClock,
    random: new SequenceRandom(),
    store: identityStore,
    recentSessions,
    proofHmacKey: Buffer.alloc(32, 0x91),
    auditHmacKey: Buffer.alloc(32, 0x92),
    policy: DEFAULT_IDENTITY_LINK_POLICY,
  });
  const harness = makeHarness({ recentSessions, verifiedAuthenticationReceipts });
  const attempt = await harness.service.beginCandidate({
    currentAccessToken: CURRENT_ACCESS_TOKEN,
    codeChallenge: challengeFor(VERIFIER),
    purpose: "link-identity",
  });
  await configureValidToken(harness, attempt.nonce);
  const candidate = await finish(harness, attempt, { code: "apple-e2e-link-code" });
  assert.equal(candidate.status, "verified-auth-receipt");
  assert.ok(candidate.verifiedAuthenticationReceiptToken);
  const proof = await candidateProofs.mintFromVerifiedAuthentication({
    currentAccessToken: CURRENT_ACCESS_TOKEN,
    verifiedAuthenticationReceiptToken: candidate.verifiedAuthenticationReceiptToken,
    expectedIssuer: APPLE_ISSUER,
    expectedPurpose: "link-identity",
  });
  assert.deepEqual(
    await linking.link({
      currentAccessToken: CURRENT_ACCESS_TOKEN,
      candidateProofToken: proof.candidateProofToken,
      confirmed: true,
    }),
    { status: "linked", authenticationEpoch: 1 },
  );
  assert.equal((await identityStore.findIdentity(APPLE_ISSUER, "apple-subject-123"))?.principalId, "principal-a");
  assert.equal(harness.bridgeCalls.length, 0);

  const unlinkAttempt = await harness.service.beginCandidate({
    currentAccessToken: CURRENT_ACCESS_TOKEN,
    codeChallenge: challengeFor(VERIFIER),
    purpose: "unlink-identity",
  });
  await configureValidToken(harness, unlinkAttempt.nonce);
  const unlinkReceipt = await finish(harness, unlinkAttempt, {
    code: "apple-e2e-unlink-code",
  });
  assert.ok(unlinkReceipt.verifiedAuthenticationReceiptToken);
  const unlinkProof = await candidateProofs.mintFromVerifiedAuthentication({
    currentAccessToken: CURRENT_ACCESS_TOKEN,
    verifiedAuthenticationReceiptToken:
      unlinkReceipt.verifiedAuthenticationReceiptToken,
    expectedIssuer: APPLE_ISSUER,
    expectedPurpose: "unlink-identity",
  });
  assert.deepEqual(
    await linking.unlink({
      currentAccessToken: CURRENT_ACCESS_TOKEN,
      candidateProofToken: unlinkProof.candidateProofToken,
      confirmed: true,
    }),
    { status: "unlinked", authenticationEpoch: 2 },
  );
  assert.equal(await identityStore.findIdentity(APPLE_ISSUER, "apple-subject-123"), undefined);
  assert.equal(harness.bridgeCalls.length, 0);
});
