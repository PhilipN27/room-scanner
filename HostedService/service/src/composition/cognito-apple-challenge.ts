import { createHmac, timingSafeEqual } from "node:crypto";

import type {
  BoundCustomChallenge,
  CognitoAdminPort,
  CognitoAppleSessionChallenge,
  CustomChallengePort,
} from "../adapters/cognito-custom-auth.js";

/** The auth-challenge Lambda is allowed to consume an Apple bridge proof, but
 * the API Lambda is not. Keeping this tiny interface separate prevents an API
 * composition from accidentally acquiring the consumer capability. */
export interface AppleBridgeConsumer {
  consumeAndIssue(input: CognitoAppleSessionChallenge): Promise<Readonly<{
    readonly principalCanonicalId: string;
    readonly familyPublicId: string;
  }>>;
}

export interface StatelessAppleCustomChallengePortDependencies {
  readonly bridge: AppleBridgeConsumer;
  /** Shared only by the API custom-auth adapter and auth-challenge Lambda.
   * Every use below is domain-separated; it is never sent to Cognito. */
  readonly sharedHmacKey: Uint8Array;
  readonly random: { bytes(length: number): Uint8Array };
}

/**
 * Cognito's Create trigger has no safe private channel from AdminInitiateAuth.
 * This stateless port therefore emits only a random public selector and an
 * HMAC private proof. The API obtains that selector, puts a canonical,
 * HMAC-authenticated Apple-session challenge in the server-side
 * CUSTOM_CHALLENGE answer, and Verify performs the one-time DB bridge consume.
 * No raw app token, bridge proof, or selector secret is placed in
 * ClientMetadata or returned to an iOS/web caller.
 */
export class StatelessAppleCustomChallengePort implements CustomChallengePort {
  constructor(private readonly dependencies: StatelessAppleCustomChallengePortDependencies) {
    if (!validDependencies(dependencies)) throw new CognitoAppleChallengeCompositionError();
  }

  async createKnown(): Promise<BoundCustomChallenge> { return this.#create(false); }
  async createSyntheticWithoutDelivery(): Promise<BoundCustomChallenge> { return this.#create(true); }

  async verify(input: {
    readonly attemptId: string;
    readonly purpose: BoundCustomChallenge["purpose"];
    readonly selector: string;
    readonly proof: string;
    readonly answer: string;
    readonly synthetic: boolean;
  }): Promise<boolean> {
    if (!validBoundInput(input) || input.synthetic !== false || input.purpose !== "sign-in" || input.attemptId !== challengeAttemptId(input.selector)) return false;
    const expectedProof = privateProof(this.dependencies.sharedHmacKey, input.selector, input.purpose);
    if (!constantEqual(input.proof, expectedProof)) return false;
    const challenge = decodeAppleSessionChallengeAnswer({ selector: input.selector, answer: input.answer, sharedHmacKey: this.dependencies.sharedHmacKey });
    // The stateless Cognito attempt and the Apple attempt are distinct: the
    // selector/private proof binds the custom-auth exchange, while the signed
    // answer binds it to a specific Apple bridge attempt that the DB consumes.
    if (challenge === undefined || challenge.purpose !== input.purpose) return false;
    try {
      const result = await this.dependencies.bridge.consumeAndIssue(challenge);
      return canonicalPrincipal(result?.principalCanonicalId) && familyPublicId(result.familyPublicId) && result.familyPublicId === challenge.familyPublicId;
    } catch {
      return false;
    }
  }

  #create(synthetic: boolean): BoundCustomChallenge {
    let random: Uint8Array;
    try { random = this.dependencies.random.bytes(16); } catch { throw new CognitoAppleChallengeCompositionError(); }
    if (!(random instanceof Uint8Array) || random.length !== 16) throw new CognitoAppleChallengeCompositionError();
    const selector = Buffer.from(random).toString("base64url");
    const proof = privateProof(this.dependencies.sharedHmacKey, selector, "sign-in");
    return Object.freeze({ attemptId: challengeAttemptId(selector), purpose: "sign-in", selector, proof, synthetic });
  }
}

export class CognitoAppleChallengeCompositionError extends Error {
  constructor() {
    super("invalid_cognito_apple_challenge_composition");
    this.name = "CognitoAppleChallengeCompositionError";
  }
}

/** Narrow, SDK-neutral server CUSTOM_AUTH transport. It intentionally has no
 * `clientMetadata`, client secret, secret-hash, token, password, or refresh
 * field. The approved infrastructure split uses a distinct secretless,
 * IAM-admin-only custom-auth client; the confidential Apple federation client
 * is not accepted by this composition. */
export interface CognitoAppleCustomAuthTransport {
  ensureExistingUser(input: { readonly username: string; readonly clientId: string }): Promise<void>;
  initiateCustomAuth(input: { readonly username: string; readonly clientId: string }): Promise<Readonly<{
    readonly session: string;
    readonly selector: string;
  }>>;
  respondToCustomAuthChallenge(input: {
    readonly username: string;
    readonly clientId: string;
    readonly session: string;
    readonly answer: string;
  }): Promise<Readonly<{ readonly outcome: "authenticated" }>>;
  linkFederatedIdentity(input: {
    readonly sourceUsername: string;
    readonly sourceIssuer: "https://appleid.apple.com";
    readonly sourceSubject: string;
    readonly destinationPrincipalId: string;
    readonly attemptId: string;
  }): Promise<void>;
}

export interface CognitoAppleCustomAuthAdminAdapterDependencies {
  readonly transport: CognitoAppleCustomAuthTransport;
  /** ID of the dedicated secretless server CUSTOM_AUTH client. */
  readonly clientId: string;
  readonly sharedHmacKey: Uint8Array;
}

/**
 * API-side narrow Cognito adapter. It only authenticates already validated
 * Apple issuer/subject data, turns it into a deterministic opaque username,
 * and drives a custom challenge. The adapter receives no Cognito tokens and
 * emits only `authenticated`, allowing the API to resolve its own app access
 * digest afterwards.
 */
export class CognitoAppleCustomAuthAdminAdapter implements CognitoAdminPort {
  constructor(private readonly dependencies: CognitoAppleCustomAuthAdminAdapterDependencies) {
    if (!validAdminDependencies(dependencies)) throw new CognitoAppleChallengeCompositionError();
  }

  async adminAuthenticate(input: {
    readonly issuer: string;
    readonly subject: string;
    readonly attemptId: string;
    readonly purpose: "sign-in";
    readonly challenge: CognitoAppleSessionChallenge;
  }): Promise<{ readonly outcome: "authenticated" }> {
    if (input.issuer !== "https://appleid.apple.com" || !appleSubject(input.subject) || !identifier(input.attemptId, 16, 128)
      || input.purpose !== "sign-in" || !validAppleSessionChallenge(input.challenge) || input.challenge.attemptId !== input.attemptId) {
      throw new CognitoAppleChallengeCompositionError();
    }
    const username = opaqueUsername(this.dependencies.sharedHmacKey, input.issuer, input.subject);
    try {
      await this.dependencies.transport.ensureExistingUser({ username, clientId: this.dependencies.clientId });
      const initiated = await this.dependencies.transport.initiateCustomAuth({ username, clientId: this.dependencies.clientId });
      if (!validInitiatedChallenge(initiated)) throw new CognitoAppleChallengeCompositionError();
      const answer = encodeAppleSessionChallengeAnswer({ selector: initiated.selector, challenge: input.challenge, sharedHmacKey: this.dependencies.sharedHmacKey });
      const response = await this.dependencies.transport.respondToCustomAuthChallenge({ username, clientId: this.dependencies.clientId, session: initiated.session, answer });
      if (response?.outcome !== "authenticated") throw new CognitoAppleChallengeCompositionError();
      return Object.freeze({ outcome: "authenticated" });
    } catch (error) {
      if (error instanceof CognitoAppleChallengeCompositionError) throw error;
      throw new CognitoAppleChallengeCompositionError();
    }
  }

  async adminLink(input: {
    readonly sourceIssuer: string;
    readonly sourceSubject: string;
    readonly destinationPrincipalId: string;
    readonly attemptId: string;
    readonly purpose: "link-identity";
  }): Promise<void> {
    if (input.sourceIssuer !== "https://appleid.apple.com" || !appleSubject(input.sourceSubject)
      || !canonicalPrincipal(input.destinationPrincipalId) || !identifier(input.attemptId, 16, 128) || input.purpose !== "link-identity") {
      throw new CognitoAppleChallengeCompositionError();
    }
    try {
      await this.dependencies.transport.linkFederatedIdentity({
        sourceUsername: opaqueUsername(this.dependencies.sharedHmacKey, input.sourceIssuer, input.sourceSubject),
        sourceIssuer: "https://appleid.apple.com", sourceSubject: input.sourceSubject,
        destinationPrincipalId: input.destinationPrincipalId, attemptId: input.attemptId,
      });
    } catch { throw new CognitoAppleChallengeCompositionError(); }
  }
}

/** Constructs the only accepted server-side CUSTOM_CHALLENGE answer. It is a
 * compact field grammar rather than JSON so it stays below Cognito's bounded
 * answer limit while still carrying all DB bridge/session fields. */
export function encodeAppleSessionChallengeAnswer(input: {
  readonly selector: string;
  readonly challenge: CognitoAppleSessionChallenge;
  readonly sharedHmacKey: Uint8Array;
}): string {
  if (!selector(input.selector) || !validAppleSessionChallenge(input.challenge) || !hmacKey(input.sharedHmacKey)) {
    throw new CognitoAppleChallengeCompositionError();
  }
  const parts = answerParts(input.selector, input.challenge);
  if (parts === undefined) throw new CognitoAppleChallengeCompositionError();
  const tag = answerTag(input.sharedHmacKey, parts);
  const answer = [...parts, tag].join(".");
  if (answer.length > 512) throw new CognitoAppleChallengeCompositionError();
  return answer;
}

export function decodeAppleSessionChallengeAnswer(input: {
  readonly selector: string;
  readonly answer: string;
  readonly sharedHmacKey: Uint8Array;
}): CognitoAppleSessionChallenge | undefined {
  if (!selector(input.selector) || !hmacKey(input.sharedHmacKey) || typeof input.answer !== "string" || input.answer.length < 64 || input.answer.length > 512) return undefined;
  const fields = input.answer.split(".");
  if (fields.length !== 14) return undefined;
  const tag = fields.at(-1);
  const parts = fields.slice(0, -1);
  if (tag === undefined || !digest(tag) || !constantEqual(tag, answerTag(input.sharedHmacKey, parts))) return undefined;
  const [version, selected, attemptId, bridgeProof, family, accessHash, refreshHash, authenticatedAt, issuedAt, accessExpiresAt, inactivityExpiresAt, absoluteExpiresAt, encodedPolicy] = parts;
  if (version !== ANSWER_VERSION || selected !== input.selector || attemptId === undefined || bridgeProof === undefined || family === undefined
    || accessHash === undefined || refreshHash === undefined || authenticatedAt === undefined || issuedAt === undefined || accessExpiresAt === undefined
    || inactivityExpiresAt === undefined || absoluteExpiresAt === undefined || encodedPolicy === undefined) return undefined;
  const policy = decodeBase64urlText(encodedPolicy);
  const challenge: CognitoAppleSessionChallenge = {
    kind: "roomscan-apple-session-v1", attemptId, purpose: "sign-in", bridgeProof, familyPublicId: family,
    accessTokenHash: accessHash, refreshTokenHash: refreshHash,
    authenticatedAt: dateFromMilliseconds(authenticatedAt), issuedAt: dateFromMilliseconds(issuedAt),
    accessExpiresAt: dateFromMilliseconds(accessExpiresAt), inactivityExpiresAt: dateFromMilliseconds(inactivityExpiresAt),
    absoluteExpiresAt: dateFromMilliseconds(absoluteExpiresAt), policyVersion: policy ?? "",
  };
  if (!validAppleSessionChallenge(challenge)) return undefined;
  const canonical = answerParts(input.selector, challenge);
  return canonical !== undefined && constantEqual(input.answer, [...canonical, tag].join(".")) ? Object.freeze(challenge) : undefined;
}

const ANSWER_VERSION = "roomscan-apple-answer-v1";

function answerParts(selectorValue: string, challenge: CognitoAppleSessionChallenge): readonly string[] | undefined {
  const authenticatedAt = milliseconds(challenge.authenticatedAt); const issuedAt = milliseconds(challenge.issuedAt); const accessExpiresAt = milliseconds(challenge.accessExpiresAt);
  const inactivityExpiresAt = milliseconds(challenge.inactivityExpiresAt); const absoluteExpiresAt = milliseconds(challenge.absoluteExpiresAt);
  const policy = Buffer.from(challenge.policyVersion, "utf8").toString("base64url");
  if (authenticatedAt === undefined || issuedAt === undefined || accessExpiresAt === undefined || inactivityExpiresAt === undefined || absoluteExpiresAt === undefined || policy.length === 0) return undefined;
  return Object.freeze([ANSWER_VERSION, selectorValue, challenge.attemptId, challenge.bridgeProof, challenge.familyPublicId, challenge.accessTokenHash, challenge.refreshTokenHash, authenticatedAt, issuedAt, accessExpiresAt, inactivityExpiresAt, absoluteExpiresAt, policy]);
}

function privateProof(key: Uint8Array, selectorValue: string, purpose: "sign-in"): string {
  return createHmac("sha256", key).update(`roomscan-cognito-private-v1:${selectorValue}:${purpose}`).digest("base64url");
}
function answerTag(key: Uint8Array, parts: readonly string[]): string {
  return createHmac("sha256", key).update(`roomscan-cognito-answer-v1:${parts.join(".")}`).digest("base64url");
}
function challengeAttemptId(selectorValue: string): string { return `cga_${selectorValue}`; }
function validDependencies(value: unknown): value is StatelessAppleCustomChallengePortDependencies {
  return value !== null && typeof value === "object" && (value as StatelessAppleCustomChallengePortDependencies).bridge !== null
    && typeof (value as StatelessAppleCustomChallengePortDependencies).bridge.consumeAndIssue === "function"
    && hmacKey((value as StatelessAppleCustomChallengePortDependencies).sharedHmacKey)
    && (value as StatelessAppleCustomChallengePortDependencies).random !== null
    && typeof (value as StatelessAppleCustomChallengePortDependencies).random.bytes === "function";
}
function validAdminDependencies(value: unknown): value is CognitoAppleCustomAuthAdminAdapterDependencies {
  if (value === null || typeof value !== "object") return false;
  const input = value as CognitoAppleCustomAuthAdminAdapterDependencies & Record<string, unknown>;
  // An accidental confidential-client secret or legacy SECRET_HASH setting is
  // a hard configuration failure, never an implicit alternate auth path.
  if ("clientSecret" in input || "clientSecretName" in input || "secretHash" in input || "secretHashSecret" in input) return false;
  return input.transport !== null && typeof input.transport === "object"
    && typeof input.transport.ensureExistingUser === "function" && typeof input.transport.initiateCustomAuth === "function"
    && typeof input.transport.respondToCustomAuthChallenge === "function" && typeof input.transport.linkFederatedIdentity === "function"
    && identifier(input.clientId, 3, 128) && hmacKey(input.sharedHmacKey);
}
function validInitiatedChallenge(value: unknown): value is Readonly<{ readonly session: string; readonly selector: string }> {
  return value !== null && typeof value === "object" && session((value as { session?: unknown }).session) && selector((value as { selector?: unknown }).selector);
}
function validBoundInput(value: unknown): value is Parameters<CustomChallengePort["verify"]>[0] {
  return value !== null && typeof value === "object" && identifier((value as BoundCustomChallenge).attemptId, 16, 128)
    && ((value as BoundCustomChallenge).purpose === "sign-in" || (value as BoundCustomChallenge).purpose === "link-identity" || (value as BoundCustomChallenge).purpose === "unlink-identity" || (value as BoundCustomChallenge).purpose === "reauthenticate")
    && selector((value as BoundCustomChallenge).selector) && digest((value as BoundCustomChallenge).proof)
    && typeof (value as { answer?: unknown }).answer === "string" && typeof (value as { synthetic?: unknown }).synthetic === "boolean";
}
function validAppleSessionChallenge(value: unknown): value is CognitoAppleSessionChallenge {
  if (value === null || typeof value !== "object") return false;
  const challenge = value as CognitoAppleSessionChallenge;
  const authenticatedAt = milliseconds(challenge.authenticatedAt); const issuedAt = milliseconds(challenge.issuedAt); const accessExpiresAt = milliseconds(challenge.accessExpiresAt);
  const inactivityExpiresAt = milliseconds(challenge.inactivityExpiresAt); const absoluteExpiresAt = milliseconds(challenge.absoluteExpiresAt);
  return challenge.kind === "roomscan-apple-session-v1" && challenge.purpose === "sign-in" && identifier(challenge.attemptId, 16, 128)
    && digest(challenge.bridgeProof) && familyPublicId(challenge.familyPublicId) && digest(challenge.accessTokenHash) && digest(challenge.refreshTokenHash)
    && authenticatedAt !== undefined && issuedAt !== undefined && accessExpiresAt !== undefined && inactivityExpiresAt !== undefined && absoluteExpiresAt !== undefined
    && authenticatedAt <= issuedAt && issuedAt < accessExpiresAt && issuedAt < inactivityExpiresAt && inactivityExpiresAt <= absoluteExpiresAt && identifier(challenge.policyVersion, 1, 64);
}
function milliseconds(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const parsed = new Date(value); const ms = parsed.getTime();
  return Number.isSafeInteger(ms) && ms >= 0 && parsed.toISOString() === value ? String(ms) : undefined;
}
function dateFromMilliseconds(value: string): string {
  if (!/^(?:0|[1-9][0-9]{0,15})$/u.test(value)) return "";
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed >= 0 ? new Date(parsed).toISOString() : "";
}
function decodeBase64urlText(value: unknown): string | undefined {
  if (typeof value !== "string" || value.length < 1 || value.length > 128 || !/^[A-Za-z0-9_-]+$/u.test(value)) return undefined;
  const bytes = Buffer.from(value, "base64url");
  if (bytes.toString("base64url") !== value) return undefined;
  try {
    const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    return identifier(text, 1, 64) ? text : undefined;
  } catch { return undefined; }
}
function hmacKey(value: unknown): value is Uint8Array { return value instanceof Uint8Array && value.length >= 32 && value.length <= 4_096; }
function selector(value: unknown): value is string { return typeof value === "string" && /^[A-Za-z0-9_-]{22}$/.test(value) && Buffer.from(value, "base64url").length === 16; }
function digest(value: unknown): value is string { return typeof value === "string" && /^[A-Za-z0-9_-]{43}$/u.test(value) && Buffer.from(value, "base64url").length === 32 && Buffer.from(value, "base64url").toString("base64url") === value; }
function identifier(value: unknown, minimum: number, maximum: number): value is string { return typeof value === "string" && value.length >= minimum && value.length <= maximum && /^[A-Za-z0-9_-]+$/u.test(value); }
function canonicalPrincipal(value: unknown): value is string { return typeof value === "string" && /^prn_[A-Za-z0-9_-]{22,64}$/u.test(value); }
function familyPublicId(value: unknown): value is string { return identifier(value, 16, 128); }
function constantEqual(actual: string, expected: string): boolean { const left = Buffer.from(actual); const right = Buffer.from(expected); return left.length === right.length && timingSafeEqual(left, right); }
function opaqueUsername(key: Uint8Array, issuer: string, subject: string): string { return `rsc_${createHmac("sha256", key).update(`roomscan-cognito-username-v1:${issuer}:${subject}`).digest("base64url")}`; }
function appleSubject(value: unknown): value is string { return typeof value === "string" && value.length >= 1 && value.length <= 512 && !/[\u0000-\u001f\u007f]/u.test(value); }
function session(value: unknown): value is string { return typeof value === "string" && value.length >= 1 && value.length <= 2_048 && !/[\u0000-\u001f\u007f]/u.test(value); }
