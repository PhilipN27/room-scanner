import {
  createHmac,
  createPrivateKey,
  createPublicKey,
  sign,
  timingSafeEqual,
  verify,
  type JsonWebKey,
} from "node:crypto";
import { TextDecoder } from "node:util";

import { APPLE_ISSUER } from "../../apple-auth.js";
import { AppleCodeExchangeHttpAdapter } from "../adapters/apple-exchange.js";
import type { HttpTransport, SecretValuePort } from "../contracts/provider-ports.js";
import { hasDuplicateJsonObjectKeys } from "../handlers/factory.js";

/** One opaque provider error prevents JWT/key/secret material from escaping to
 * route callers or logs.  The cause must remain in a private error sink. */
export class AppleProviderError extends Error {
  constructor(readonly code: "invalid_apple_provider" = "invalid_apple_provider") {
    super(code);
    this.name = "AppleProviderError";
  }
}

export interface AppleJwksPort {
  /** The implementation is pinned to the configured Apple JWKS endpoint. It
   * has no caller-controlled URL and returns only a bounded parsed key set. */
  fetch(input: { readonly forceRefresh: boolean }): Promise<readonly unknown[]>;
}

export interface AppleStrictIdTokenVerifierDependencies {
  readonly jwks: AppleJwksPort;
  readonly nonceHmacKey: Uint8Array;
  /** The service-owned authoritative clock is read again after awaited JWKS
   * work. A token must not survive merely because the request began before it
   * expired. */
  readonly clock: { nowMs(): number };
  readonly clockSkewMs: number;
  readonly maxTokenAgeMs: number;
  readonly cacheTtlMs: number;
}

/**
 * Service-owned Apple ID-token verifier. It intentionally returns only the
 * immutable provider subject: email/relay claims are neither interpreted nor
 * used as identity-linking material.
 */
export class AppleStrictIdTokenVerifier {
  #cached: Readonly<{ readonly fetchedAtMs: number; readonly keys: readonly AppleJwk[] }> | undefined;

  constructor(private readonly dependencies: AppleStrictIdTokenVerifierDependencies) {
    if (dependencies === null || typeof dependencies !== "object"
      || dependencies.jwks === null || typeof dependencies.jwks.fetch !== "function"
      || !key(dependencies.nonceHmacKey)
      || dependencies.clock === null || typeof dependencies.clock.nowMs !== "function"
      || !boundedDuration(dependencies.clockSkewMs, 0, 5 * 60_000)
      || !boundedDuration(dependencies.maxTokenAgeMs, 1_000, 24 * 60 * 60_000)
      || !boundedDuration(dependencies.cacheTtlMs, 1_000, 24 * 60 * 60_000)) {
      throw new AppleProviderError();
    }
  }

  async verify(input: {
    readonly idToken: string;
    readonly expectedIssuer: "https://appleid.apple.com";
    readonly expectedAudience: string;
    readonly expectedNonceDigest: string;
    readonly authoritativeNowMs: number;
  }): Promise<Readonly<{ readonly issuer: "https://appleid.apple.com"; readonly subject: string }>> {
    if (input === null || typeof input !== "object" || input.expectedIssuer !== APPLE_ISSUER
      || !identifier(input.expectedAudience, 1, 256) || !digest(input.expectedNonceDigest)
      || !safeTimestamp(input.authoritativeNowMs)) {
      throw new AppleProviderError();
    }
    const token = parseCompactJwt(input.idToken);
    if (token === undefined || token.header.alg !== "RS256" || !identifier(token.header.kid, 1, 128)
      || "jku" in token.header || "x5u" in token.header || "jwk" in token.header || "crit" in token.header) {
      throw new AppleProviderError();
    }
    const expectedNonce = Buffer.from(input.expectedNonceDigest, "base64url");
    if (expectedNonce.length !== 32 || expectedNonce.toString("base64url") !== input.expectedNonceDigest) {
      throw new AppleProviderError();
    }

    let matching = (await this.#keys(input.authoritativeNowMs, false)).find((candidate) => candidate.kid === token.header.kid);
    if (matching === undefined) {
      // A single forced refresh handles normal Apple key rotation. A second
      // fetch would turn a bad token into an unbounded provider amplification.
      matching = (await this.#keys(input.authoritativeNowMs, true)).find((candidate) => candidate.kid === token.header.kid);
    }
    if (matching === undefined || !validAppleSigningKey(matching)) throw new AppleProviderError();

    let signatureValid = false;
    try {
      const publicKey = createPublicKey({ key: matching as JsonWebKey, format: "jwk" });
      signatureValid = verify("RSA-SHA256", Buffer.from(token.signingInput), publicKey, token.signature);
    } catch {
      throw new AppleProviderError();
    }
    if (!signatureValid) throw new AppleProviderError();

    // `input.authoritativeNowMs` is the request's initial server time, not a
    // timeless authorization. Re-read after the awaited JWKS boundary (and
    // never move time backwards) before validating iat/exp/max-age.
    const verifiedAtMs = this.#authoritativeNowAtOrAfter(input.authoritativeNowMs);
    const claims = token.payload;
    const issuedAtMs = secondsToMilliseconds(claims.iat);
    const expiryMs = secondsToMilliseconds(claims.exp);
    if (claims.iss !== APPLE_ISSUER || claims.aud !== input.expectedAudience
      || !subject(claims.sub) || !nonce(claims.nonce)
      || issuedAtMs === undefined || expiryMs === undefined || expiryMs < issuedAtMs
      || expiryMs < verifiedAtMs - this.dependencies.clockSkewMs
      || issuedAtMs > verifiedAtMs + this.dependencies.clockSkewMs
      || issuedAtMs < verifiedAtMs - this.dependencies.maxTokenAgeMs - this.dependencies.clockSkewMs) {
      throw new AppleProviderError();
    }
    const actualNonce = createHmac("sha256", this.dependencies.nonceHmacKey)
      .update(`nonce:${claims.nonce}`)
      .digest();
    if (actualNonce.length !== expectedNonce.length || !timingSafeEqual(actualNonce, expectedNonce)) {
      throw new AppleProviderError();
    }
    return Object.freeze({ issuer: APPLE_ISSUER, subject: claims.sub });
  }

  async #keys(authoritativeNowMs: number, forceRefresh: boolean): Promise<readonly AppleJwk[]> {
    const cached = this.#cached;
    if (!forceRefresh && cached !== undefined && authoritativeNowMs >= cached.fetchedAtMs
      && authoritativeNowMs - cached.fetchedAtMs <= this.dependencies.cacheTtlMs) {
      return cached.keys;
    }
    let raw: readonly unknown[];
    try {
      raw = await this.dependencies.jwks.fetch({ forceRefresh });
    } catch {
      throw new AppleProviderError();
    }
    if (!Array.isArray(raw) || raw.length < 1 || raw.length > 32) throw new AppleProviderError();
    const keys = raw.map(parseAppleJwk);
    if (keys.some((candidate) => candidate === undefined)) throw new AppleProviderError();
    const typed = keys as AppleJwk[];
    if (new Set(typed.map((candidate) => candidate.kid)).size !== typed.length) throw new AppleProviderError();
    this.#cached = Object.freeze({ fetchedAtMs: this.#authoritativeNowAtOrAfter(authoritativeNowMs), keys: Object.freeze(typed) });
    return this.#cached.keys;
  }

  #authoritativeNowAtOrAfter(initialNowMs: number): number {
    let recaptured: number;
    try {
      recaptured = this.dependencies.clock.nowMs();
    } catch {
      throw new AppleProviderError();
    }
    if (!safeTimestamp(recaptured) || recaptured < initialNowMs) throw new AppleProviderError();
    return recaptured;
  }
}

export interface GeneratedAppleClientSecretReaderDependencies {
  readonly privateKeySecrets: SecretValuePort;
  readonly privateKeySecretName: string;
  readonly teamId: string;
  readonly keyId: string;
  readonly clientId: string;
  /** Apple permits up to 180 days. Shorter runtime-configured lifetimes are
   * preferred so secret/key rotations take effect promptly. */
  readonly lifetimeSeconds: number;
  readonly clock: { nowMs(): number };
}

/** The generated value implements the existing narrow secret-reader contract
 * so the exchange adapter never receives or transmits the raw .p8 material. */
export class GeneratedAppleClientSecretReader implements SecretValuePort {
  constructor(private readonly dependencies: GeneratedAppleClientSecretReaderDependencies) {
    if (dependencies === null || typeof dependencies !== "object"
      || dependencies.privateKeySecrets === null || typeof dependencies.privateKeySecrets.read !== "function"
      || !secretName(dependencies.privateKeySecretName) || !appleIdentifier(dependencies.teamId, 1, 32)
      || !appleIdentifier(dependencies.keyId, 1, 32) || !identifier(dependencies.clientId, 1, 256)
      || !Number.isSafeInteger(dependencies.lifetimeSeconds) || dependencies.lifetimeSeconds < 60 || dependencies.lifetimeSeconds > 15_552_000
      || dependencies.clock === null || typeof dependencies.clock.nowMs !== "function") {
      throw new AppleProviderError();
    }
  }

  async read(name: string): Promise<string> {
    if (name !== GENERATED_APPLE_CLIENT_SECRET_NAME) throw new AppleProviderError();
    const nowMs = this.dependencies.clock.nowMs();
    if (!safeTimestamp(nowMs)) throw new AppleProviderError();
    let secret: string;
    try {
      secret = await this.dependencies.privateKeySecrets.read(this.dependencies.privateKeySecretName);
    } catch {
      throw new AppleProviderError();
    }
    if (typeof secret !== "string" || secret.length < 64 || secret.length > 16_384) throw new AppleProviderError();
    let privateKey: ReturnType<typeof createPrivateKey>;
    try {
      privateKey = createPrivateKey(secret);
      const details = privateKey.asymmetricKeyDetails;
      if (privateKey.asymmetricKeyType !== "ec" || details?.namedCurve !== "prime256v1") throw new AppleProviderError();
    } catch (error) {
      if (error instanceof AppleProviderError) throw error;
      throw new AppleProviderError();
    }
    const issuedAt = Math.floor(nowMs / 1_000);
    const expiresAt = issuedAt + this.dependencies.lifetimeSeconds;
    if (!Number.isSafeInteger(issuedAt) || !Number.isSafeInteger(expiresAt)) throw new AppleProviderError();
    const header = base64urlJson({ alg: "ES256", kid: this.dependencies.keyId, typ: "JWT" });
    const payload = base64urlJson({ iss: this.dependencies.teamId, iat: issuedAt, exp: expiresAt, aud: APPLE_ISSUER, sub: this.dependencies.clientId });
    const signingInput = `${header}.${payload}`;
    try {
      const signature = sign("sha256", Buffer.from(signingInput), { key: privateKey, dsaEncoding: "ieee-p1363" });
      if (signature.length !== 64) throw new AppleProviderError();
      return `${signingInput}.${signature.toString("base64url")}`;
    } catch (error) {
      if (error instanceof AppleProviderError) throw error;
      throw new AppleProviderError();
    }
  }
}

export const GENERATED_APPLE_CLIENT_SECRET_NAME = "roomscan-generated-apple-client-secret";

export interface Slice4AppleCodeExchangeDependencies extends GeneratedAppleClientSecretReaderDependencies {
  readonly transport: HttpTransport;
  readonly timeoutMs: number;
  readonly maxResponseBytes: number;
}

/** Concrete service construction used by the API composition. Infrastructure
 * can supply only a bounded transport and secret reader; JWT policy stays in
 * this module. */
export function createSlice4AppleCodeExchange(input: Slice4AppleCodeExchangeDependencies): AppleCodeExchangeHttpAdapter {
  const secrets = new GeneratedAppleClientSecretReader(input);
  try {
    return new AppleCodeExchangeHttpAdapter({
      transport: input.transport,
      secrets,
      clientSecretName: GENERATED_APPLE_CLIENT_SECRET_NAME,
      timeoutMs: input.timeoutMs,
      maxResponseBytes: input.maxResponseBytes,
    });
  } catch {
    throw new AppleProviderError();
  }
}

interface AppleJwk extends JsonWebKey {
  readonly kty: "RSA";
  readonly kid: string;
  readonly use: "sig";
  readonly alg: "RS256";
  readonly n: string;
  readonly e: string;
}

interface ParsedCompactJwt {
  readonly header: Readonly<Record<string, unknown>>;
  readonly payload: Readonly<Record<string, unknown>>;
  readonly signingInput: string;
  readonly signature: Uint8Array;
}

function parseCompactJwt(value: unknown): ParsedCompactJwt | undefined {
  if (typeof value !== "string" || value.length < 16 || value.length > 16_384) return undefined;
  const segments = value.split(".");
  if (segments.length !== 3) return undefined;
  const [encodedHeader, encodedPayload, encodedSignature] = segments;
  if (encodedHeader === undefined || encodedPayload === undefined || encodedSignature === undefined
    || !base64url(encodedHeader) || !base64url(encodedPayload) || !base64url(encodedSignature)
    || encodedHeader.length > 4_096 || encodedPayload.length > 8_192 || encodedSignature.length > 1_024) return undefined;
  const headerText = decodeUtf8(encodedHeader);
  const payloadText = decodeUtf8(encodedPayload);
  const signature = decodeBase64url(encodedSignature);
  if (headerText === undefined || payloadText === undefined || signature === undefined || signature.length < 128
    || hasDuplicateJsonObjectKeys(headerText) || hasDuplicateJsonObjectKeys(payloadText)) return undefined;
  try {
    const header: unknown = JSON.parse(headerText);
    const payload: unknown = JSON.parse(payloadText);
    if (!record(header) || !record(payload)) return undefined;
    return Object.freeze({ header, payload, signingInput: `${encodedHeader}.${encodedPayload}`, signature });
  } catch {
    return undefined;
  }
}

function parseAppleJwk(value: unknown): AppleJwk | undefined {
  if (!record(value) || value.kty !== "RSA" || value.use !== "sig" || value.alg !== "RS256"
    || !identifier(value.kid, 1, 128) || !base64urlText(value.n, 128, 1_024) || !base64urlText(value.e, 1, 16)
    || Object.keys(value).some((field) => !["kty", "kid", "use", "alg", "n", "e"].includes(field))) return undefined;
  return Object.freeze({ kty: "RSA", kid: value.kid, use: "sig", alg: "RS256", n: value.n, e: value.e });
}

function validAppleSigningKey(value: AppleJwk): boolean {
  return value.kty === "RSA" && value.use === "sig" && value.alg === "RS256"
    && identifier(value.kid, 1, 128) && base64urlText(value.n, 128, 1_024) && base64urlText(value.e, 1, 16);
}

function base64urlJson(value: Readonly<Record<string, string | number>>): string {
  return Buffer.from(JSON.stringify(value), "utf8").toString("base64url");
}

function decodeUtf8(encoded: string): string | undefined {
  const bytes = decodeBase64url(encoded);
  if (bytes === undefined) return undefined;
  try { return new TextDecoder("utf-8", { fatal: true }).decode(bytes); } catch { return undefined; }
}

function decodeBase64url(encoded: string): Uint8Array | undefined {
  if (!base64url(encoded)) return undefined;
  const bytes = Buffer.from(encoded, "base64url");
  return bytes.toString("base64url") === encoded ? Uint8Array.from(bytes) : undefined;
}

function base64url(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && /^[A-Za-z0-9_-]+$/u.test(value);
}

function base64urlText(value: unknown, minimum: number, maximum: number): value is string {
  return base64url(value) && value.length >= minimum && value.length <= maximum && decodeBase64url(value) !== undefined;
}

function secondsToMilliseconds(value: unknown): number | undefined {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 && value <= Math.floor(Number.MAX_SAFE_INTEGER / 1_000)
    ? value * 1_000
    : undefined;
}

function key(value: unknown): value is Uint8Array {
  return value instanceof Uint8Array && value.length >= 32 && value.length <= 4_096;
}

function digest(value: unknown): value is string {
  return typeof value === "string" && /^[A-Za-z0-9_-]{43}$/u.test(value)
    && Buffer.from(value, "base64url").length === 32 && Buffer.from(value, "base64url").toString("base64url") === value;
}

function nonce(value: unknown): value is string {
  return typeof value === "string" && value.length >= 16 && value.length <= 512 && !/[\u0000-\u001f\u007f]/u.test(value);
}

function subject(value: unknown): value is string {
  return typeof value === "string" && value.length >= 1 && value.length <= 512 && value.trim() === value && !/[\u0000-\u001f\u007f]/u.test(value);
}

function identifier(value: unknown, minimum: number, maximum: number): value is string {
  return typeof value === "string" && value.length >= minimum && value.length <= maximum && /^[A-Za-z0-9._-]+$/u.test(value);
}

function appleIdentifier(value: unknown, minimum: number, maximum: number): value is string {
  return typeof value === "string" && value.length >= minimum && value.length <= maximum && /^[A-Za-z0-9]+$/u.test(value);
}

function secretName(value: unknown): value is string {
  return typeof value === "string" && /^[A-Za-z0-9/_+=.@-]{1,256}$/u.test(value);
}

function boundedDuration(value: unknown, minimum: number, maximum: number): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= minimum && value <= maximum;
}

function safeTimestamp(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0 && value <= Number.MAX_SAFE_INTEGER - 15_552_000_000;
}

function record(value: unknown): value is Readonly<Record<string, unknown>> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
