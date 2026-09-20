import { createDecipheriv } from "node:crypto";

import type { DataApiClient, SqlCell, SqlParameter, SqlResult } from "../adapters/data-api.js";
import { PUBLICATION_FEEDBACK_ENVELOPE_AAD } from "../publication/feedback-service.js";
import type { CapabilitySqlUnit } from "./capabilities.js";
import { epochMillisecondsToIsoTimestamp } from "./codecs.js";
import { DataApiCapabilityTransactionRunner } from "./transaction-runner.js";

/** This separate capability lane deliberately has no portal/API handler,
 * project mutation repository, storage object, or audit sink. It can only
 * claim, revalidate, terminally transition, and decrypt one v3 delivery. */
export class PublicationFeedbackDeliveryError extends Error {
  constructor(readonly code: "invalid_input" | "invalid_result" | "unavailable") {
    super(code);
    this.name = "PublicationFeedbackDeliveryError";
  }
}

export interface PublicationFeedbackDeliveryKeyringPort {
  /** Unknown/retired keys are terminal envelope state, never a reason to ask
   * the portal/API role to recover plaintext. */
  resolve(keyID: string): Promise<Uint8Array | undefined>;
}

export interface PublicationFeedbackDeliveryProviderPort {
  /** The provider receives only one destination/code pair after both live
   * database checks. It never receives session/link/snapshot/tenant state or
   * a raw sealed envelope. */
  send(input: Readonly<{ readonly email: string; readonly verificationCode: string; readonly deliveryID: string }>): Promise<void>;
}

export interface PublicationFeedbackDeliveryLease {
  readonly deliveryID: string;
  readonly leaseID: string;
  readonly leaseExpiresAtMs: number;
  readonly keyID: string;
  readonly iv: Uint8Array;
  readonly ciphertext: Uint8Array;
  readonly authenticationTag: Uint8Array;
  readonly expiresAtMs: number;
  readonly deliveryAttempts: number;
}

type FeedbackDeliveryValidation = PublicationFeedbackDeliveryLease | Readonly<{ readonly status: "expired" | "cancelled" }>;

const CLAIM_SQL = "SELECT * FROM roomscan.claim_next_feedback_delivery_v3(:lease_id, (:claimed_at)::timestamptz, (:lease_expires_at)::timestamptz)";
const VALIDATE_SQL = "SELECT * FROM roomscan.validate_feedback_delivery_v3(:delivery_id, :lease_id, (:checked_at)::timestamptz)";
const COMPLETE_SQL = "SELECT roomscan.complete_feedback_delivery_v3(:delivery_id, :lease_id, (:delivered_at)::timestamptz) AS completed";
const CANCEL_SQL = "SELECT roomscan.cancel_feedback_delivery_v3(:delivery_id, :lease_id, :reason, (:cancelled_at)::timestamptz) AS cancelled";
const RELEASE_SQL = "SELECT * FROM roomscan.release_feedback_delivery_v3(:delivery_id, :lease_id, (:released_at)::timestamptz)";

/** A narrow SQL codec retains the encrypted-envelope boundary even if a
 * future email worker is composed alongside the existing magic worker. */
export class DataApiPublicationFeedbackDeliveryRepository {
  constructor(private readonly unit: CapabilitySqlUnit) {
    if (unit === null || typeof unit !== "object" || typeof unit.execute !== "function") {
      throw new PublicationFeedbackDeliveryError("invalid_input");
    }
  }

  async claimNext(input: { readonly leaseID: string; readonly claimedAtMs: number; readonly leaseExpiresAtMs: number }): Promise<PublicationFeedbackDeliveryLease | undefined> {
    const leaseID = leaseIdentifier(input.leaseID);
    const claimedAt = time(input.claimedAtMs);
    const leaseExpiresAt = time(input.leaseExpiresAtMs);
    if (leaseID === undefined || claimedAt === undefined || leaseExpiresAt === undefined || leaseExpiresAt <= claimedAt) throw new PublicationFeedbackDeliveryError("invalid_input");
    const result = await this.unit.execute({ sql: CLAIM_SQL, parameters: [text("lease_id", leaseID), timestamp("claimed_at", claimedAt), timestamp("lease_expires_at", leaseExpiresAt)] });
    if (result.rows.length === 0) return undefined;
    if (result.rows.length !== 1 || result.rows[0] === undefined) throw new PublicationFeedbackDeliveryError("invalid_result");
    return decodeLease(result.rows[0], leaseID, "leased");
  }

  async validate(input: { readonly deliveryID: string; readonly leaseID: string; readonly checkedAtMs: number }): Promise<FeedbackDeliveryValidation | undefined> {
    const deliveryID = deliveryIdentifier(input.deliveryID);
    const leaseID = leaseIdentifier(input.leaseID);
    const checkedAt = time(input.checkedAtMs);
    if (deliveryID === undefined || leaseID === undefined || checkedAt === undefined) throw new PublicationFeedbackDeliveryError("invalid_input");
    const result = await this.unit.execute({ sql: VALIDATE_SQL, parameters: [text("delivery_id", deliveryID), text("lease_id", leaseID), timestamp("checked_at", checkedAt)] });
    if (result.rows.length === 0) return undefined;
    if (result.rows.length !== 1 || result.rows[0] === undefined) throw new PublicationFeedbackDeliveryError("invalid_result");
    const row = result.rows[0];
    if (row.status === "send") return decodeLease(row, leaseID, "send");
    if ((row.status === "expired" || row.status === "cancelled") && deliveryIdentifier(row.delivery_id) === deliveryID) return Object.freeze({ status: row.status });
    throw new PublicationFeedbackDeliveryError("invalid_result");
  }

  async complete(input: { readonly deliveryID: string; readonly leaseID: string; readonly deliveredAtMs: number }): Promise<boolean> {
    const deliveryID = deliveryIdentifier(input.deliveryID);
    const leaseID = leaseIdentifier(input.leaseID);
    const deliveredAt = time(input.deliveredAtMs);
    if (deliveryID === undefined || leaseID === undefined || deliveredAt === undefined) throw new PublicationFeedbackDeliveryError("invalid_input");
    const result = await this.unit.execute({ sql: COMPLETE_SQL, parameters: [text("delivery_id", deliveryID), text("lease_id", leaseID), timestamp("delivered_at", deliveredAt)] });
    return booleanResult(result, "completed");
  }

  async cancel(input: { readonly deliveryID: string; readonly leaseID: string; readonly reason: "unknown_key" | "tampered_envelope"; readonly cancelledAtMs: number }): Promise<boolean> {
    const deliveryID = deliveryIdentifier(input.deliveryID);
    const leaseID = leaseIdentifier(input.leaseID);
    const cancelledAt = time(input.cancelledAtMs);
    if (deliveryID === undefined || leaseID === undefined || cancelledAt === undefined || (input.reason !== "unknown_key" && input.reason !== "tampered_envelope")) throw new PublicationFeedbackDeliveryError("invalid_input");
    const result = await this.unit.execute({ sql: CANCEL_SQL, parameters: [text("delivery_id", deliveryID), text("lease_id", leaseID), text("reason", input.reason), timestamp("cancelled_at", cancelledAt)] });
    return booleanResult(result, "cancelled");
  }

  async release(input: { readonly deliveryID: string; readonly leaseID: string; readonly releasedAtMs: number }): Promise<"released" | "expired" | "unavailable"> {
    const deliveryID = deliveryIdentifier(input.deliveryID);
    const leaseID = leaseIdentifier(input.leaseID);
    const releasedAt = time(input.releasedAtMs);
    if (deliveryID === undefined || leaseID === undefined || releasedAt === undefined) throw new PublicationFeedbackDeliveryError("invalid_input");
    const result = await this.unit.execute({ sql: RELEASE_SQL, parameters: [text("delivery_id", deliveryID), text("lease_id", leaseID), timestamp("released_at", releasedAt)] });
    if (result.rows.length !== 1) throw new PublicationFeedbackDeliveryError("invalid_result");
    const status = result.rows[0]?.status;
    if (status !== "released" && status !== "expired" && status !== "unavailable") throw new PublicationFeedbackDeliveryError("invalid_result");
    return status;
  }
}

/** Email-runtime-only targetless worker. Queue records are wakes, not delivery
 * selectors; a periodic tick can call this same method after a lost wake. */
export class DataApiPublicationFeedbackDeliveryWorker {
  readonly #transactions: DataApiCapabilityTransactionRunner<DataApiPublicationFeedbackDeliveryRepository>;
  readonly #clock: { nowMs(): number };
  readonly #random: { bytes(length: number): Uint8Array };
  readonly #decryptionKeys: PublicationFeedbackDeliveryKeyringPort;
  readonly #delivery: PublicationFeedbackDeliveryProviderPort;
  readonly #leaseMs: number;

  constructor(input: {
    readonly client: DataApiClient;
    readonly clock: { nowMs(): number };
    readonly random: { bytes(length: number): Uint8Array };
    readonly decryptionKeys: PublicationFeedbackDeliveryKeyringPort;
    readonly delivery: PublicationFeedbackDeliveryProviderPort;
    readonly leaseMs: number;
  }) {
    if (input === null || typeof input !== "object" || input.client === null || typeof input.client !== "object"
      || input.clock === null || typeof input.clock.nowMs !== "function" || input.random === null || typeof input.random.bytes !== "function"
      || input.decryptionKeys === null || typeof input.decryptionKeys.resolve !== "function"
      || input.delivery === null || typeof input.delivery.send !== "function"
      || !Number.isSafeInteger(input.leaseMs) || input.leaseMs < 1_000 || input.leaseMs > 15 * 60_000) {
      throw new PublicationFeedbackDeliveryError("invalid_input");
    }
    this.#transactions = new DataApiCapabilityTransactionRunner(input.client, (unit) => new DataApiPublicationFeedbackDeliveryRepository(unit));
    this.#clock = input.clock;
    this.#random = input.random;
    this.#decryptionKeys = input.decryptionKeys;
    this.#delivery = input.delivery;
    this.#leaseMs = input.leaseMs;
  }

  async handleRecord(record: { readonly messageId: string }): Promise<boolean> {
    if (!messageIdentifier(record?.messageId)) return false;
    const claimedAt = this.#now();
    const leaseID = leaseFrom(this.#random.bytes(16));
    if (leaseID === undefined) return false;
    let lease: PublicationFeedbackDeliveryLease | undefined;
    try {
      lease = await this.#transactions.run((repository) => repository.claimNext({
        leaseID,
        claimedAtMs: claimedAt,
        leaseExpiresAtMs: boundedAdd(claimedAt, this.#leaseMs),
      }));
    } catch { return false; }
    if (lease === undefined) return true;

    let key: Uint8Array | undefined;
    try { key = await this.#decryptionKeys.resolve(lease.keyID); } catch { await this.#release(lease, this.#now()); return false; }
    if (!(key instanceof Uint8Array) || key.byteLength !== 32) { await this.#cancel(lease, "unknown_key", this.#now()); return true; }

    const first = await this.#validate(lease, this.#now());
    if (first === undefined || "status" in first) return true;
    let message: Readonly<{ readonly email: string; readonly verificationCode: string }>;
    try { message = decryptEnvelope(key, first); } catch { await this.#cancel(first, "tampered_envelope", this.#now()); return true; }
    const beforeSend = await this.#validate(first, this.#now());
    if (beforeSend === undefined || "status" in beforeSend) return true;
    try { await this.#delivery.send(Object.freeze({ email: message.email, verificationCode: message.verificationCode, deliveryID: beforeSend.deliveryID })); } catch { await this.#release(beforeSend, this.#now()); return false; }
    try { return await this.#transactions.run((repository) => repository.complete({ deliveryID: beforeSend.deliveryID, leaseID: beforeSend.leaseID, deliveredAtMs: this.#now() })); } catch { return false; }
  }

  async #validate(lease: PublicationFeedbackDeliveryLease, checkedAtMs: number): Promise<FeedbackDeliveryValidation | undefined> {
    try { return await this.#transactions.run((repository) => repository.validate({ deliveryID: lease.deliveryID, leaseID: lease.leaseID, checkedAtMs })); } catch { return undefined; }
  }
  async #cancel(lease: PublicationFeedbackDeliveryLease, reason: "unknown_key" | "tampered_envelope", cancelledAtMs: number): Promise<void> {
    try { await this.#transactions.run((repository) => repository.cancel({ deliveryID: lease.deliveryID, leaseID: lease.leaseID, reason, cancelledAtMs })); } catch { /* lease expiry is the recovery boundary */ }
  }
  async #release(lease: PublicationFeedbackDeliveryLease, releasedAtMs: number): Promise<void> {
    try { await this.#transactions.run((repository) => repository.release({ deliveryID: lease.deliveryID, leaseID: lease.leaseID, releasedAtMs })); } catch { /* targetless retry/tick recovers the lease */ }
  }
  #now(): number {
    const now = this.#clock.nowMs();
    if (!Number.isSafeInteger(now) || now <= 0) throw new PublicationFeedbackDeliveryError("unavailable");
    return now;
  }
}

function decodeLease(row: Readonly<Record<string, SqlCell>>, expectedLeaseID: string, expectedStatus: "leased" | "send"): PublicationFeedbackDeliveryLease {
  const deliveryID = deliveryIdentifier(row.delivery_id);
  const leaseID = leaseIdentifier(row.lease_id);
  const leaseExpiresAtMs = timestampCell(row.lease_expires_at);
  const keyID = keyIdentifier(row.key_id);
  const iv = exactBytes(row.iv, 12);
  const ciphertext = ciphertextBytes(row.ciphertext);
  const authenticationTag = exactBytes(row.authentication_tag, 16);
  const expiresAtMs = timestampCell(row.expires_at);
  const deliveryAttempts = positiveInteger(row.delivery_attempts);
  if (row.status !== expectedStatus || row.envelope_version !== "aes-256-gcm-v1" || deliveryID === undefined || leaseID !== expectedLeaseID || leaseExpiresAtMs === undefined
    || keyID === undefined || iv === undefined || ciphertext === undefined || authenticationTag === undefined || expiresAtMs === undefined
    || deliveryAttempts === undefined || leaseExpiresAtMs > expiresAtMs) {
    throw new PublicationFeedbackDeliveryError("invalid_result");
  }
  return Object.freeze({ deliveryID, leaseID, leaseExpiresAtMs, keyID, iv, ciphertext, authenticationTag, expiresAtMs, deliveryAttempts });
}

function decryptEnvelope(key: Uint8Array, lease: PublicationFeedbackDeliveryLease): Readonly<{ readonly email: string; readonly verificationCode: string }> {
  if (!(key instanceof Uint8Array) || key.byteLength !== 32) throw new PublicationFeedbackDeliveryError("invalid_input");
  let first: Buffer | undefined;
  let last: Buffer | undefined;
  let plaintext: Buffer | undefined;
  try {
    const decipher = createDecipheriv("aes-256-gcm", key, lease.iv);
    decipher.setAAD(Buffer.from(PUBLICATION_FEEDBACK_ENVELOPE_AAD, "utf8"));
    decipher.setAuthTag(Buffer.from(lease.authenticationTag));
    first = decipher.update(lease.ciphertext);
    last = decipher.final();
    plaintext = Buffer.concat([first, last]);
    if (plaintext.byteLength < 1 || plaintext.byteLength > 1_024) throw new PublicationFeedbackDeliveryError("unavailable");
    const decoded: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(plaintext));
    if (decoded === null || typeof decoded !== "object" || Array.isArray(decoded) || Object.getPrototypeOf(decoded) !== Object.prototype) throw new PublicationFeedbackDeliveryError("unavailable");
    const payload = decoded as Record<string, unknown>;
    if (Object.keys(payload).length !== 2 || !validEmail(payload.email) || !verificationCode(payload.verificationCode)) throw new PublicationFeedbackDeliveryError("unavailable");
    return Object.freeze({ email: payload.email, verificationCode: payload.verificationCode });
  } catch (error) {
    if (error instanceof PublicationFeedbackDeliveryError) throw error;
    throw new PublicationFeedbackDeliveryError("unavailable");
  } finally {
    first?.fill(0);
    last?.fill(0);
    plaintext?.fill(0);
  }
}

function text(name: string, value: string): SqlParameter { return { name, value: { kind: "string", value } }; }
function timestamp(name: string, value: number): SqlParameter { const encoded = epochMillisecondsToIsoTimestamp(value); if (encoded === undefined) throw new PublicationFeedbackDeliveryError("invalid_input"); return { name, value: { kind: "string", value: encoded, typeHint: "TIMESTAMP" } }; }
function time(value: unknown): number | undefined { return typeof value === "number" && Number.isSafeInteger(value) && value > 0 && epochMillisecondsToIsoTimestamp(value) !== undefined ? value : undefined; }
function timestampCell(value: unknown): number | undefined { if (typeof value !== "string") return undefined; const parsed = new Date(value); return Number.isSafeInteger(parsed.getTime()) && parsed.toISOString() === value ? parsed.getTime() : undefined; }
function exactBytes(value: unknown, length: number): Uint8Array | undefined { return value instanceof Uint8Array && value.byteLength === length ? Uint8Array.from(value) : undefined; }
function ciphertextBytes(value: unknown): Uint8Array | undefined { return value instanceof Uint8Array && value.byteLength >= 1 && value.byteLength <= 4_096 ? Uint8Array.from(value) : undefined; }
function positiveInteger(value: unknown): number | undefined { return typeof value === "number" && Number.isSafeInteger(value) && value > 0 ? value : undefined; }
function keyIdentifier(value: unknown): string | undefined { return typeof value === "string" && value.length >= 1 && value.length <= 64 && /^[A-Za-z0-9._-]+$/u.test(value) ? value : undefined; }
function deliveryIdentifier(value: unknown): string | undefined { return typeof value === "string" && /^pfd_[A-Za-z0-9_-]{16,128}$/u.test(value) ? value : undefined; }
function leaseIdentifier(value: unknown): string | undefined { return typeof value === "string" && /^lease_[A-Za-z0-9_-]{22}$/u.test(value) && Buffer.from(value.slice(6), "base64url").byteLength === 16 && Buffer.from(value.slice(6), "base64url").toString("base64url") === value.slice(6) ? value : undefined; }
function messageIdentifier(value: unknown): value is string { return typeof value === "string" && /^[A-Za-z0-9._:-]{1,128}$/u.test(value); }
function validEmail(value: unknown): value is string { return typeof value === "string" && value.length >= 3 && value.length <= 320 && !/[\u0000-\u001f\u007f-\u009f]/u.test(value) && /^[^\s@]+@[^\s@]+\.[^\s@]+$/u.test(value); }
function verificationCode(value: unknown): value is string { const match = typeof value === "string" ? /^([A-Za-z0-9_-]{43})\.([A-Za-z0-9_-]{43})$/u.exec(value) : undefined; return match?.[1] !== undefined && match[2] !== undefined && opaqueSecret(match[1]) && opaqueSecret(match[2]); }
function opaqueSecret(value: string): boolean { const decoded = Buffer.from(value, "base64url"); return decoded.byteLength === 32 && decoded.toString("base64url") === value; }
function booleanResult(result: SqlResult, field: string): boolean { if (result.rows.length !== 1 || typeof result.rows[0]?.[field] !== "boolean") throw new PublicationFeedbackDeliveryError("invalid_result"); return result.rows[0]![field] as boolean; }
function leaseFrom(bytes: Uint8Array): string | undefined { return bytes instanceof Uint8Array && bytes.byteLength === 16 ? `lease_${Buffer.from(bytes).toString("base64url")}` : undefined; }
function boundedAdd(left: number, right: number): number { if (!Number.isSafeInteger(left) || !Number.isSafeInteger(right) || right < 1 || left > Number.MAX_SAFE_INTEGER - right) throw new PublicationFeedbackDeliveryError("unavailable"); return left + right; }
