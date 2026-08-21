import type { SqlCell, SqlParameter } from "../adapters/data-api.js";
import type { CapabilitySqlUnit } from "./capabilities.js";
import { epochMillisecondsToIsoTimestamp } from "./codecs.js";

/** Exact sealed-outbox capability lane. The email runtime receives neither a
 * caller-selected delivery target nor any direct table privilege. */
export class MagicDeliveryCapabilityError extends Error {
  constructor(readonly code: "invalid_input" | "invalid_result") {
    super(code);
    this.name = "MagicDeliveryCapabilityError";
  }
}

export type MagicDeliveryPurpose = "sign-in" | "reauthenticate" | "link-identity" | "unlink-identity";

export interface MagicDeliveryLease {
  readonly id: string;
  readonly selector: string;
  readonly deliveryIdentity: string;
  readonly purpose: MagicDeliveryPurpose;
  readonly keyId: string;
  readonly iv: Uint8Array;
  readonly ciphertext: Uint8Array;
  readonly authenticationTag: Uint8Array;
  readonly createdAtMs: number;
  readonly expiresAtMs: number;
  readonly policyVersion: string;
  readonly deliveryAttempts: number;
  readonly leaseId: string;
  readonly leaseExpiresAtMs: number;
}

export type MagicDeliveryClaim = MagicDeliveryLease | Readonly<{ readonly state: "expired"; readonly id: string }>;

const CLAIM_NEXT_SQL = `SELECT * FROM roomscan.claim_next_magic_delivery(
  :lease_id,
  (:claimed_at)::timestamptz,
  (:lease_expires_at)::timestamptz
)`;
const VALIDATE_SQL = `SELECT * FROM roomscan.validate_magic_delivery(
  :id,
  :lease_id,
  (:checked_at)::timestamptz
)`;
const COMPLETE_SQL = `SELECT roomscan.complete_magic_delivery(
  :id,
  :lease_id,
  (:delivered_at)::timestamptz
) AS completed`;
const CANCEL_SQL = `SELECT roomscan.cancel_magic_delivery(
  :id,
  :lease_id,
  :reason_code,
  (:cancelled_at)::timestamptz
) AS cancelled`;
const RELEASE_SQL = `SELECT roomscan.release_magic_delivery(
  :id,
  :lease_id,
  (:released_at)::timestamptz
) AS status`;

export class DataApiMagicDeliveryCapabilityRepository {
  constructor(private readonly unit: CapabilitySqlUnit) {
    if (unit === null || typeof unit !== "object" || typeof unit.execute !== "function") {
      throw new MagicDeliveryCapabilityError("invalid_input");
    }
  }

  async claimNext(input: { readonly leaseId: string; readonly claimedAtMs: number; readonly leaseExpiresAtMs: number }): Promise<MagicDeliveryClaim | undefined> {
    const lease = validLeaseId(input.leaseId);
    const claimedAt = timestamp(input.claimedAtMs);
    const leaseExpiresAt = timestamp(input.leaseExpiresAtMs);
    if (lease === undefined || claimedAt === undefined || leaseExpiresAt === undefined || leaseExpiresAt <= claimedAt) {
      throw new MagicDeliveryCapabilityError("invalid_input");
    }
    const result = await this.unit.execute({
      sql: CLAIM_NEXT_SQL,
      parameters: [text("lease_id", lease), time("claimed_at", claimedAt), time("lease_expires_at", leaseExpiresAt)],
    });
    if (result.rows.length === 0) return undefined;
    if (result.rows.length !== 1) throw new MagicDeliveryCapabilityError("invalid_result");
    return decodeClaim(result.rows[0]!, lease);
  }

  async validate(input: { readonly id: string; readonly leaseId: string; readonly checkedAtMs: number }): Promise<MagicDeliveryClaim | undefined> {
    const id = deliveryId(input.id);
    const lease = validLeaseId(input.leaseId);
    const checkedAt = timestamp(input.checkedAtMs);
    if (id === undefined || lease === undefined || checkedAt === undefined) throw new MagicDeliveryCapabilityError("invalid_input");
    const result = await this.unit.execute({
      sql: VALIDATE_SQL,
      parameters: [text("id", id), text("lease_id", lease), time("checked_at", checkedAt)],
    });
    if (result.rows.length === 0) return undefined;
    if (result.rows.length !== 1) throw new MagicDeliveryCapabilityError("invalid_result");
    return decodeClaim(result.rows[0]!, lease);
  }

  async complete(input: { readonly id: string; readonly leaseId: string; readonly deliveredAtMs: number }): Promise<boolean> {
    return this.#boolean(COMPLETE_SQL, "completed", input, "delivered_at");
  }

  async cancel(input: { readonly id: string; readonly leaseId: string; readonly reason: "unknown_key" | "tampered_envelope"; readonly cancelledAtMs: number }): Promise<boolean> {
    const id = deliveryId(input.id);
    const lease = validLeaseId(input.leaseId);
    const cancelledAt = timestamp(input.cancelledAtMs);
    if (id === undefined || lease === undefined || (input.reason !== "unknown_key" && input.reason !== "tampered_envelope") || cancelledAt === undefined) {
      throw new MagicDeliveryCapabilityError("invalid_input");
    }
    const result = await this.unit.execute({
      sql: CANCEL_SQL,
      parameters: [text("id", id), text("lease_id", lease), text("reason_code", input.reason), time("cancelled_at", cancelledAt)],
    });
    return oneBoolean(result.rows, "cancelled");
  }

  async release(input: { readonly id: string; readonly leaseId: string; readonly releasedAtMs: number }): Promise<"released" | "expired" | "unavailable"> {
    const id = deliveryId(input.id);
    const lease = validLeaseId(input.leaseId);
    const releasedAt = timestamp(input.releasedAtMs);
    if (id === undefined || lease === undefined || releasedAt === undefined) throw new MagicDeliveryCapabilityError("invalid_input");
    const result = await this.unit.execute({
      sql: RELEASE_SQL,
      parameters: [text("id", id), text("lease_id", lease), time("released_at", releasedAt)],
    });
    if (result.rows.length !== 1) throw new MagicDeliveryCapabilityError("invalid_result");
    const status = result.rows[0]?.status;
    if (status !== "released" && status !== "expired" && status !== "unavailable") throw new MagicDeliveryCapabilityError("invalid_result");
    return status;
  }

  async #boolean(
    sql: string,
    name: "completed",
    input: { readonly id: string; readonly leaseId: string; readonly deliveredAtMs: number },
    timestampName: "delivered_at",
  ): Promise<boolean> {
    const id = deliveryId(input.id);
    const lease = validLeaseId(input.leaseId);
    const deliveredAt = timestamp(input.deliveredAtMs);
    if (id === undefined || lease === undefined || deliveredAt === undefined) throw new MagicDeliveryCapabilityError("invalid_input");
    const result = await this.unit.execute({
      sql,
      parameters: [text("id", id), text("lease_id", lease), time(timestampName, deliveredAt)],
    });
    return oneBoolean(result.rows, name);
  }
}

function decodeClaim(row: Readonly<Record<string, SqlCell>>, expectedLeaseId: string): MagicDeliveryClaim {
  const id = deliveryId(row.id);
  if (id === undefined) throw new MagicDeliveryCapabilityError("invalid_result");
  if (row.state === "expired") {
    if (row.lease_id !== null || row.lease_expires_at !== null || row.delivered_at !== null
      || !timestampString(row.cancelled_at) || row.cancellation_reason !== "expired") {
      throw new MagicDeliveryCapabilityError("invalid_result");
    }
    return Object.freeze({ state: "expired", id });
  }
  if (row.state !== "leased") throw new MagicDeliveryCapabilityError("invalid_result");
  const selector = selectorValue(row.selector);
  const recipient = deliveryIdentity(row.normalized_delivery_identity);
  const purpose = purposeValue(row.purpose);
  const keyId = identifier(row.key_id, 1, 64);
  const iv = bytes(row.iv, 12);
  const ciphertext = bytes(row.ciphertext, 32);
  const authenticationTag = bytes(row.authentication_tag, 16);
  const createdAtMs = timestampString(row.created_at);
  const expiresAtMs = timestampString(row.expires_at);
  const policyVersion = identifier(row.policy_version, 1, 64);
  const deliveryAttempts = positive(row.delivery_attempts);
  const leaseId = validLeaseId(row.lease_id);
  const leaseExpiresAtMs = timestampString(row.lease_expires_at);
  if (selector === undefined || recipient === undefined || purpose === undefined || row.envelope_version !== "aes-256-gcm-v1"
    || keyId === undefined || iv === undefined || ciphertext === undefined || authenticationTag === undefined || createdAtMs === undefined
    || expiresAtMs === undefined || policyVersion === undefined || deliveryAttempts === undefined || leaseId !== expectedLeaseId
    || leaseExpiresAtMs === undefined || createdAtMs >= expiresAtMs || leaseExpiresAtMs > expiresAtMs
    || row.delivered_at !== null || row.cancelled_at !== null || row.cancellation_reason !== null) {
    throw new MagicDeliveryCapabilityError("invalid_result");
  }
  return Object.freeze({
    id, selector, deliveryIdentity: recipient, purpose, keyId, iv, ciphertext, authenticationTag,
    createdAtMs, expiresAtMs, policyVersion, deliveryAttempts, leaseId, leaseExpiresAtMs,
  });
}

function oneBoolean(rows: readonly Readonly<Record<string, SqlCell>>[], field: string): boolean {
  if (rows.length !== 1 || typeof rows[0]?.[field] !== "boolean") throw new MagicDeliveryCapabilityError("invalid_result");
  return rows[0]![field] as boolean;
}

function text(name: string, value: string): SqlParameter { return { name, value: { kind: "string", value } }; }
function time(name: string, value: number): SqlParameter { return { name, value: { kind: "string", value: epochMillisecondsToIsoTimestamp(value), typeHint: "TIMESTAMP" } }; }
function timestamp(value: unknown): number | undefined {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0 && epochMillisecondsToIsoTimestamp(value) !== undefined ? value : undefined;
}
function timestampString(value: unknown): number | undefined {
  if (typeof value !== "string") return undefined;
  const parsed = new Date(value);
  return Number.isSafeInteger(parsed.getTime()) && parsed.toISOString() === value ? parsed.getTime() : undefined;
}
function bytes(value: unknown, length: number): Uint8Array | undefined { return value instanceof Uint8Array && value.length === length ? Uint8Array.from(value) : undefined; }
function deliveryId(value: unknown): string | undefined { return identifier(value, 16, 128); }
function validLeaseId(value: unknown): string | undefined { return identifier(value, 1, 128); }
function selectorValue(value: unknown): string | undefined {
  return typeof value === "string" && /^[A-Za-z0-9_-]{22}$/u.test(value) && Buffer.from(value, "base64url").length === 16
    && Buffer.from(value, "base64url").toString("base64url") === value ? value : undefined;
}
function deliveryIdentity(value: unknown): string | undefined { return typeof value === "string" && value.length >= 3 && value.length <= 320 && !/[\u0000-\u001f\u007f]/u.test(value) ? value : undefined; }
function purposeValue(value: unknown): MagicDeliveryPurpose | undefined { return value === "sign-in" || value === "reauthenticate" || value === "link-identity" || value === "unlink-identity" ? value : undefined; }
function identifier(value: unknown, min: number, max: number): string | undefined { return typeof value === "string" && value.length >= min && value.length <= max && /^[A-Za-z0-9._-]+$/u.test(value) ? value : undefined; }
function positive(value: unknown): number | undefined { return typeof value === "number" && Number.isSafeInteger(value) && value > 0 ? value : undefined; }
