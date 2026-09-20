import { createCipheriv } from "node:crypto";

/** Fixed authenticated context prevents this envelope from being accepted as a
 * ciphertext for a different protocol if a deployment ever rotates through
 * shared KMS material. The matching worker imports this exact literal. */
export const PUBLICATION_FEEDBACK_ENVELOPE_AAD = "roomscan-publication-feedback-envelope-v1";

/** The API role can seal one verified-feedback delivery envelope but can never
 * decrypt it. The matching email-runtime keyring is intentionally a distinct
 * capability in the delivery worker. */
export interface PublicationFeedbackEnvelope {
  readonly keyID: string;
  readonly iv: Uint8Array;
  readonly ciphertext: Uint8Array;
  readonly authenticationTag: Uint8Array;
}

export interface PublicationFeedbackEnvelopeSealer {
  seal(input: Readonly<{ readonly email: string; readonly verificationCode: string }>): PublicationFeedbackEnvelope;
}

/** A wake is targetless: a queue record never carries an address, challenge,
 * link, tenant, or ciphertext. A periodic email-lane tick safely recovers a
 * lost wake after the already-durable outbox insert. */
export interface PublicationFeedbackDeliveryWakePort {
  notifyFeedbackDeliveryWake(): Promise<void>;
}

export class PublicationFeedbackEnvelopeError extends Error {
  constructor(readonly code: "invalid_input" | "unavailable") {
    super(code);
    this.name = "PublicationFeedbackEnvelopeError";
  }
}

/** A narrow AES-256-GCM sealer for the request role. It retains plaintext only
 * for the synchronous cipher call, returns one bounded envelope, and never
 * writes, logs, or exposes a raw email/code. */
export class AesGcmPublicationFeedbackEnvelopeSealer implements PublicationFeedbackEnvelopeSealer {
  readonly #keyID: string;
  readonly #key: Uint8Array;
  readonly #random: { bytes(length: number): Uint8Array };

  constructor(input: { readonly keyID: string; readonly key: Uint8Array; readonly random: { bytes(length: number): Uint8Array } }) {
    if (input === null || typeof input !== "object" || !identifier(input.keyID)
      || !(input.key instanceof Uint8Array) || input.key.byteLength !== 32
      || input.random === null || typeof input.random !== "object" || typeof input.random.bytes !== "function") {
      throw new PublicationFeedbackEnvelopeError("invalid_input");
    }
    this.#keyID = input.keyID;
    this.#key = Uint8Array.from(input.key);
    this.#random = input.random;
  }

  seal(input: Readonly<{ readonly email: string; readonly verificationCode: string }>): PublicationFeedbackEnvelope {
    if (!validEmail(input?.email) || !verificationCode(input?.verificationCode)) throw new PublicationFeedbackEnvelopeError("invalid_input");
    let iv: Uint8Array;
    try { iv = this.#random.bytes(12); } catch { throw new PublicationFeedbackEnvelopeError("unavailable"); }
    if (!(iv instanceof Uint8Array) || iv.byteLength !== 12) throw new PublicationFeedbackEnvelopeError("unavailable");
    const plaintext = Buffer.from(JSON.stringify({ email: input.email, verificationCode: input.verificationCode }), "utf8");
    if (plaintext.byteLength < 1 || plaintext.byteLength > 1_024) throw new PublicationFeedbackEnvelopeError("invalid_input");
    try {
      const cipher = createCipheriv("aes-256-gcm", this.#key, iv);
      cipher.setAAD(Buffer.from(PUBLICATION_FEEDBACK_ENVELOPE_AAD, "utf8"));
      const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
      const authenticationTag = cipher.getAuthTag();
      if (ciphertext.byteLength < 1 || ciphertext.byteLength > 4_096 || authenticationTag.byteLength !== 16) {
        throw new PublicationFeedbackEnvelopeError("unavailable");
      }
      return Object.freeze({
        keyID: this.#keyID,
        iv: Uint8Array.from(iv),
        ciphertext: Uint8Array.from(ciphertext),
        authenticationTag: Uint8Array.from(authenticationTag),
      });
    } catch (error) {
      if (error instanceof PublicationFeedbackEnvelopeError) throw error;
      throw new PublicationFeedbackEnvelopeError("unavailable");
    } finally {
      plaintext.fill(0);
    }
  }
}

function identifier(value: unknown): value is string {
  return typeof value === "string" && value.length >= 1 && value.length <= 64 && /^[A-Za-z0-9._-]+$/u.test(value);
}

function validEmail(value: unknown): value is string {
  return typeof value === "string" && value.length >= 3 && value.length <= 320
    && !/[\u0000-\u001f\u007f-\u009f]/u.test(value) && /^[^\s@]+@[^\s@]+\.[^\s@]+$/u.test(value);
}

function verificationCode(value: unknown): value is string {
  const match = typeof value === "string" ? /^([A-Za-z0-9_-]{43})\.([A-Za-z0-9_-]{43})$/u.exec(value) : undefined;
  return match?.[1] !== undefined && match[2] !== undefined && opaqueSecret(match[1]) && opaqueSecret(match[2]);
}

function opaqueSecret(value: string): boolean {
  const decoded = Buffer.from(value, "base64url");
  return decoded.byteLength === 32 && decoded.toString("base64url") === value;
}
