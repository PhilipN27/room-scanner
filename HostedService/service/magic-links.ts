import {
  createCipheriv,
  createDecipheriv,
  createHash,
  createHmac,
} from "node:crypto";

import type {
  IdentityMutationPurpose,
  RecentSessionVerifier,
  TrustedRecentSession,
  VerifiedAuthenticationReceipt,
} from "./identity-linking.js";

export interface Clock {
  nowMs(): number;
}

export interface RandomSource {
  bytes(length: number): Uint8Array;
}

export interface MagicLinkPolicy {
  readonly version: string;
  readonly ttlMs: number;
  readonly cooldownMs: number;
  readonly maxActive: number;
  readonly addressWindowMs: number;
  readonly maxAddressDeliveriesPerWindow: number;
  readonly addressDayMs: number;
  readonly maxAddressDeliveriesPerDay: number;
  readonly networkWindowMs: number;
  readonly maxNetworkRequestsPerWindow: number;
  readonly deliveryLeaseMs: number;
  readonly verifiedAuthReceiptTtlMs: number;
  readonly allowedPurposes: readonly MagicLinkPurpose[];
}

export type MagicLinkPurpose =
  | "sign-in"
  | "reauthenticate"
  | "link-identity"
  | "unlink-identity";

export const DEFAULT_MAGIC_LINK_POLICY: MagicLinkPolicy = {
  version: "magic-link-v1",
  ttlMs: 10 * 60_000,
  cooldownMs: 60_000,
  maxActive: 2,
  addressWindowMs: 15 * 60_000,
  maxAddressDeliveriesPerWindow: 3,
  addressDayMs: 24 * 60 * 60_000,
  maxAddressDeliveriesPerDay: 10,
  networkWindowMs: 15 * 60_000,
  maxNetworkRequestsPerWindow: 20,
  deliveryLeaseMs: 30_000,
  verifiedAuthReceiptTtlMs: 60_000,
  allowedPurposes: ["sign-in", "reauthenticate", "link-identity", "unlink-identity"],
};

export type MagicLinkState = "active" | "consumed" | "superseded";

export interface MagicLinkRecord {
  readonly selector: string;
  readonly secretDigest: string;
  readonly purpose: MagicLinkPurpose;
  readonly normalizedDeliveryIdentity: string;
  readonly addressHash: string;
  readonly networkHash: string;
  readonly issuedAtMs: number;
  readonly expiresAtMs: number;
  readonly policyVersion: string;
  readonly initiatingPrincipalId?: string;
  readonly initiatingFamilyId?: string;
  readonly initiatingAuthenticatedAtMs?: number;
  state: MagicLinkState;
  consumedAtMs?: number;
  supersededAtMs?: number;
}

export interface MagicLinkRateEvent {
  readonly kind: "request" | "delivery";
  readonly hash: string;
  readonly atMs: number;
}

export interface MagicLinkDeliveryOutboxRecord {
  readonly id: string;
  readonly selector: string;
  readonly normalizedDeliveryIdentity: string;
  readonly purpose: MagicLinkPurpose;
  readonly sealedSecret: MagicLinkSealedSecretEnvelope;
  readonly createdAtMs: number;
  readonly expiresAtMs: number;
  readonly policyVersion: string;
  state: "pending" | "leased" | "delivered" | "expired" | "cancelled";
  deliveryAttempts: number;
  leaseId?: string;
  leaseExpiresAtMs?: number;
  deliveredAtMs?: number;
  cancelledAtMs?: number;
  cancellationReason?: "expired" | "unknown_key" | "tampered_envelope";
}

export interface MagicLinkSealedSecretEnvelope {
  readonly version: "aes-256-gcm-v1";
  readonly keyId: string;
  readonly iv: string;
  ciphertext: string;
  readonly authenticationTag: string;
}

export interface MagicLinkSealingKeyring {
  activeKey(): Promise<{ readonly keyId: string; readonly key: Uint8Array }>;
  decryptionKey(keyId: string): Promise<Uint8Array | undefined>;
}

export type MagicLinkDeliveryAttemptResult =
  | { readonly status: "claimed"; readonly record: MagicLinkDeliveryOutboxRecord }
  | { readonly status: "expired" }
  | { readonly status: "unavailable" };

export type MagicLinkDeliveryPreSendResult =
  | { readonly status: "ready"; readonly record: MagicLinkDeliveryOutboxRecord }
  | { readonly status: "expired" }
  | { readonly status: "unavailable" };

export type MagicLinkDeliveryReleaseResult = "released" | "expired" | "unavailable";

export interface MagicLinkClaim {
  readonly selector: string;
  readonly secretDigest: string;
  readonly purpose?: MagicLinkPurpose;
  readonly nowMs: number;
}

export interface MagicLinkTransaction {
  activeFor(identity: string, purpose: string, atMs: number): Promise<MagicLinkRecord[]>;
  mostRecentDelivery(identity: string, purpose: string): Promise<MagicLinkRecord | undefined>;
  countRateEvents(kind: MagicLinkRateEvent["kind"], hash: string, sinceMs: number): Promise<number>;
  insert(record: MagicLinkRecord): Promise<void>;
  supersedeIfActive(selector: string, atMs: number): Promise<boolean>;
  claimActiveLink(claim: MagicLinkClaim): Promise<MagicLinkRecord | undefined>;
  supersedeActiveSiblings(
    identity: string,
    purpose: string,
    exceptSelector: string,
    atMs: number,
  ): Promise<number>;
  recordRateEvent(event: MagicLinkRateEvent): Promise<void>;
  insertDeliveryOutbox(record: MagicLinkDeliveryOutboxRecord): Promise<void>;
  insertVerifiedAuthenticationReceipt(
    receipt: VerifiedAuthenticationReceipt,
  ): Promise<void>;
  availableDeliveries(nowMs: number, limit: number): Promise<MagicLinkDeliveryOutboxRecord[]>;
  claimDeliveryAttempt(
    id: string,
    leaseId: string,
    nowMs: number,
    leaseExpiresAtMs: number,
  ): Promise<MagicLinkDeliveryAttemptResult>;
  validateDeliveryAttemptBeforeSend(
    id: string,
    leaseId: string,
    nowMs: number,
  ): Promise<MagicLinkDeliveryPreSendResult>;
  completeDeliveryAttempt(id: string, leaseId: string, deliveredAtMs: number): Promise<boolean>;
  cancelDeliveryAttempt(
    id: string,
    leaseId: string,
    reason: "unknown_key" | "tampered_envelope",
    cancelledAtMs: number,
  ): Promise<boolean>;
  releaseDeliveryAttempt(
    id: string,
    leaseId: string,
    nowMs: number,
  ): Promise<MagicLinkDeliveryReleaseResult>;
}

export interface MagicLinkStore {
  transaction<T>(work: (transaction: MagicLinkTransaction) => Promise<T>): Promise<T>;
}

export interface MagicLinkDirectoryPort {
  statusFor(identity: string): Promise<"new" | "enabled" | "disabled">;
}

export interface MagicLinkDeliveryPort {
  enqueue(message: {
    readonly normalizedDeliveryIdentity: string;
    readonly purpose: MagicLinkPurpose;
    readonly url: string;
    readonly idempotencyKey: string;
  }): Promise<void>;
}

export interface MagicLinkSessionIssuer {
  issueForVerifiedEmail(input: {
    readonly normalizedDeliveryIdentity: string;
    readonly purpose: MagicLinkPurpose;
    readonly clickingDeviceId: string;
    readonly authenticatedAtMs: number;
  }): Promise<{ readonly accessToken: string; readonly refreshToken: string }>;
}

export interface MagicLinkLogPort {
  write(
    eventCode: string,
    fields?: {
      readonly correlationId?: string;
      readonly result?: string;
      readonly counters?: Readonly<Record<string, number>>;
    },
  ): void;
}

export interface MagicLinkServiceDependencies {
  readonly clock: Clock;
  readonly random: RandomSource;
  readonly store: MagicLinkStore;
  readonly directory: MagicLinkDirectoryPort;
  readonly sessions: MagicLinkSessionIssuer;
  readonly recentSessions: RecentSessionVerifier;
  readonly logger: MagicLinkLogPort;
  readonly tokenHmacKey: Uint8Array;
  readonly verifiedAuthenticationReceiptHmacKey: Uint8Array;
  readonly addressHmacKey: Uint8Array;
  readonly networkHmacKey: Uint8Array;
  readonly keyring: MagicLinkSealingKeyring;
  readonly policy: MagicLinkPolicy;
}

export interface MagicLinkRequest {
  readonly email: string;
  readonly purpose: string;
  readonly networkAddress: string;
}

export type MagicLinkConsumeResult =
  | {
      readonly status: "authenticated";
      readonly session: { readonly accessToken: string; readonly refreshToken: string };
    }
  | {
      readonly status: "verified-auth-receipt";
      readonly verifiedAuthenticationReceiptToken: string;
      readonly expiresAtMs: number;
    }
  | { readonly status: "rejected" };

export type MagicLinkErrorCode =
  | "recent_auth_required"
  | "invalid_configuration"
  | "invalid_purpose";

export class MagicLinkError extends Error {
  constructor(readonly code: MagicLinkErrorCode) {
    super(code);
    this.name = "MagicLinkError";
  }
}

export const MAGIC_LINK_CONSUME_PATH = "/auth/magic-link/consume";

export function normalizeDeliveryIdentity(input: string): string | undefined {
  const trimmed = input.trim();
  if (trimmed.length > 320 || /\s/u.test(trimmed)) {
    return undefined;
  }
  const separator = trimmed.lastIndexOf("@");
  if (separator <= 0 || separator === trimmed.length - 1) {
    return undefined;
  }
  const localPart = trimmed.slice(0, separator);
  const domain = trimmed.slice(separator + 1);
  if (
    localPart.length > 64 ||
    domain.length > 255 ||
    !domain.includes(".") ||
    domain.startsWith(".") ||
    domain.endsWith(".") ||
    !/^[A-Za-z0-9.-]+$/u.test(domain)
  ) {
    return undefined;
  }
  return `${localPart}@${domain.toLowerCase()}`;
}

export class MagicLinkService {
  constructor(private readonly dependencies: MagicLinkServiceDependencies) {}

  async request(request: MagicLinkRequest): Promise<{ readonly accepted: true; readonly status: 202 }> {
    const purpose = request.purpose === "sign-in" || request.purpose === "reauthenticate"
      ? request.purpose
      : undefined;
    return this.requestInternal(request, purpose, undefined);
  }

  async requestCandidate(request: {
    readonly currentAccessToken: string;
    readonly email: string;
    readonly purpose: IdentityMutationPurpose;
    readonly networkAddress: string;
  }): Promise<{ readonly accepted: true; readonly status: 202 }> {
    if (request.purpose !== "link-identity" && request.purpose !== "unlink-identity") {
      throw new MagicLinkError("invalid_purpose");
    }
    let initiatingSession: TrustedRecentSession;
    try {
      initiatingSession = await this.dependencies.recentSessions.verifyRecentSession(
        request.currentAccessToken,
      );
    } catch {
      throw new MagicLinkError("recent_auth_required");
    }
    if (
      initiatingSession.principalId.length === 0 ||
      initiatingSession.familyId.length === 0 ||
      !Number.isFinite(initiatingSession.authenticatedAtMs)
    ) {
      throw new MagicLinkError("recent_auth_required");
    }
    return this.requestInternal(request, request.purpose, initiatingSession);
  }

  private async requestInternal(
    request: Pick<MagicLinkRequest, "email" | "networkAddress">,
    purpose: MagicLinkPurpose | undefined,
    initiatingSession: TrustedRecentSession | undefined,
  ): Promise<{ readonly accepted: true; readonly status: 202 }> {
    const outwardResult = { accepted: true, status: 202 } as const;
    const nowMs = this.dependencies.clock.nowMs();
    const normalizedIdentity = normalizeDeliveryIdentity(request.email);
    const networkHash = keyedDigest(
      this.dependencies.networkHmacKey,
      request.networkAddress,
    );

    let directoryStatus: "new" | "enabled" | "disabled" = "disabled";
    if (normalizedIdentity !== undefined) {
      try {
        directoryStatus = await this.dependencies.directory.statusFor(normalizedIdentity);
      } catch {
        this.dependencies.logger.write("auth.magic_link.request", {
          result: "directory_unavailable",
        });
        return outwardResult;
      }
    }

    try {
      const inserted = await this.dependencies.store.transaction(async (transaction) => {
        const recentNetworkRequests = await transaction.countRateEvents(
          "request",
          networkHash,
          nowMs - this.dependencies.policy.networkWindowMs,
        );
        await transaction.recordRateEvent({ kind: "request", hash: networkHash, atMs: nowMs });
        if (recentNetworkRequests >= this.dependencies.policy.maxNetworkRequestsPerWindow) {
          return undefined;
        }
        if (
          normalizedIdentity === undefined ||
          directoryStatus === "disabled" ||
          purpose === undefined
        ) {
          return undefined;
        }

        const addressHash = keyedDigest(
          this.dependencies.addressHmacKey,
          normalizedIdentity,
        );
        const recentAddressDeliveries = await transaction.countRateEvents(
          "delivery",
          addressHash,
          nowMs - this.dependencies.policy.addressWindowMs,
        );
        const dailyAddressDeliveries = await transaction.countRateEvents(
          "delivery",
          addressHash,
          nowMs - this.dependencies.policy.addressDayMs,
        );
        if (
          recentAddressDeliveries >=
            this.dependencies.policy.maxAddressDeliveriesPerWindow ||
          dailyAddressDeliveries >= this.dependencies.policy.maxAddressDeliveriesPerDay
        ) {
          return undefined;
        }

        const previous = await transaction.mostRecentDelivery(normalizedIdentity, purpose);
        if (
          previous !== undefined &&
          nowMs - previous.issuedAtMs < this.dependencies.policy.cooldownMs
        ) {
          return undefined;
        }

        const active = [...await transaction.activeFor(normalizedIdentity, purpose, nowMs)]
          .sort(compareMagicLinkCreationOrder);
        const selectorsToSupersede = active.slice(
          0,
          Math.max(0, active.length - this.dependencies.policy.maxActive + 1),
        );
        for (const record of selectorsToSupersede) {
          await transaction.supersedeIfActive(record.selector, nowMs);
        }

        const selector = Buffer.from(this.dependencies.random.bytes(16)).toString("base64url");
        const secret = Buffer.from(this.dependencies.random.bytes(32));
        const sealingKey = await this.dependencies.keyring.activeKey();
        const record: MagicLinkRecord = {
          selector,
          secretDigest: keyedDigest(this.dependencies.tokenHmacKey, secret),
          purpose,
          normalizedDeliveryIdentity: normalizedIdentity,
          addressHash,
          networkHash,
          issuedAtMs: nowMs,
          expiresAtMs: nowMs + this.dependencies.policy.ttlMs,
          policyVersion: this.dependencies.policy.version,
          state: "active",
          ...(initiatingSession === undefined
            ? {}
            : {
                initiatingPrincipalId: initiatingSession.principalId,
                initiatingFamilyId: initiatingSession.familyId,
                initiatingAuthenticatedAtMs: initiatingSession.authenticatedAtMs,
              }),
        };
        await transaction.insert(record);
        await transaction.recordRateEvent({ kind: "delivery", hash: addressHash, atMs: nowMs });
        await transaction.insertDeliveryOutbox({
          id: `mdl_${Buffer.from(this.dependencies.random.bytes(16)).toString("base64url")}`,
          selector,
          normalizedDeliveryIdentity: normalizedIdentity,
          purpose,
          sealedSecret: sealSecret(
            sealingKey,
            secret,
            this.dependencies.random.bytes(12),
          ),
          createdAtMs: nowMs,
          expiresAtMs: record.expiresAtMs,
          policyVersion: this.dependencies.policy.version,
          state: "pending",
          deliveryAttempts: 0,
        });
        return true;
      });
      this.dependencies.logger.write("auth.magic_link.request", {
        result: inserted === true ? "delivery_pending" : "accepted_no_delivery",
      });
    } catch {
      this.dependencies.logger.write("auth.magic_link.request", {
        result: "store_unavailable",
      });
    }
    return outwardResult;
  }

  async renderConfirmation(): Promise<{
    readonly status: 200;
    readonly headers: Readonly<Record<string, string>>;
    readonly body: string;
  }> {
    return {
      status: 200,
      headers: {
        "cache-control": "no-store",
        "content-security-policy": CONFIRMATION_CSP,
        "content-type": "text/html; charset=utf-8",
        "permissions-policy": "camera=(), microphone=(), geolocation=()",
        "referrer-policy": "no-referrer",
      },
      body: CONFIRMATION_HTML,
    };
  }

  async consume(input: {
    readonly selector: string;
    readonly secret: string;
    readonly purpose?: string;
    readonly clickingDeviceId: string;
  }): Promise<MagicLinkConsumeResult> {
    if (
      input.purpose !== undefined &&
      !this.dependencies.policy.allowedPurposes.includes(input.purpose as MagicLinkPurpose)
    ) {
      return { status: "rejected" };
    }
    if (!isSelector(input.selector) || !isEncodedSecret(input.secret)) {
      return { status: "rejected" };
    }
    const nowMs = this.dependencies.clock.nowMs();
    const consumed = await this.dependencies.store.transaction(async (transaction) => {
      const record = await transaction.claimActiveLink({
        selector: input.selector,
        secretDigest: keyedDigest(
          this.dependencies.tokenHmacKey,
          Buffer.from(input.secret, "base64url"),
        ),
        ...(input.purpose === undefined
          ? {}
          : { purpose: input.purpose as MagicLinkPurpose }),
        nowMs,
      });
      if (record === undefined) {
        return undefined;
      }
      await transaction.supersedeActiveSiblings(
        record.normalizedDeliveryIdentity,
        record.purpose,
        record.selector,
        nowMs,
      );
      if (record.purpose === "link-identity" || record.purpose === "unlink-identity") {
        if (
          record.initiatingPrincipalId === undefined ||
          record.initiatingFamilyId === undefined ||
          record.initiatingAuthenticatedAtMs === undefined
        ) {
          return undefined;
        }
        const verifiedAuthenticationReceiptToken = Buffer.from(
          this.dependencies.random.bytes(32),
        ).toString("base64url");
        const expiresAtMs = nowMs + this.dependencies.policy.verifiedAuthReceiptTtlMs;
        await transaction.insertVerifiedAuthenticationReceipt({
          tokenHash: keyedDigest(
            this.dependencies.verifiedAuthenticationReceiptHmacKey,
            `verified-auth-receipt:${verifiedAuthenticationReceiptToken}`,
          ),
          issuer: "email",
          subject: record.normalizedDeliveryIdentity,
          purpose: record.purpose,
          initiatingPrincipalId: record.initiatingPrincipalId,
          initiatingFamilyId: record.initiatingFamilyId,
          authenticatedAtMs: nowMs,
          issuedAtMs: nowMs,
          expiresAtMs,
          policyVersion: this.dependencies.policy.version,
          state: "active",
        });
        return {
          record,
          verifiedAuthenticationReceipt: {
            verifiedAuthenticationReceiptToken,
            expiresAtMs,
          },
        };
      }
      return { record };
    });

    if (consumed === undefined) {
      this.dependencies.logger.write("auth.magic_link.consume", { result: "rejected" });
      return { status: "rejected" };
    }
    if ("verifiedAuthenticationReceipt" in consumed) {
      this.dependencies.logger.write("auth.magic_link.consume", {
        result: "verified_auth_receipt",
      });
      return {
        status: "verified-auth-receipt",
        ...consumed.verifiedAuthenticationReceipt,
      };
    }
    const session = await this.dependencies.sessions.issueForVerifiedEmail({
      normalizedDeliveryIdentity: consumed.record.normalizedDeliveryIdentity,
      purpose: consumed.record.purpose,
      clickingDeviceId: input.clickingDeviceId,
      authenticatedAtMs: nowMs,
    });
    this.dependencies.logger.write("auth.magic_link.consume", { result: "authenticated" });
    return { status: "authenticated", session };
  }
}

export class MagicLinkDeliveryWorker {
  constructor(
    private readonly dependencies: {
      readonly clock: Clock;
      readonly random: RandomSource;
      readonly store: MagicLinkStore;
      readonly delivery: MagicLinkDeliveryPort;
      readonly logger: MagicLinkLogPort;
      readonly keyring: MagicLinkSealingKeyring;
      readonly policy: MagicLinkPolicy;
      readonly publicOrigin: string;
    },
  ) {}

  async runOnce(limit: number): Promise<{ readonly attempted: number; readonly delivered: number }> {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 100) {
      throw new RangeError("invalid delivery batch size");
    }
    const pending = await this.dependencies.store.transaction(async (transaction) =>
      await transaction.availableDeliveries(this.dependencies.clock.nowMs(), limit),
    );
    let attempted = 0;
    let delivered = 0;
    for (const record of pending) {
      const leaseId = `mdlease_${Buffer.from(this.dependencies.random.bytes(16)).toString("base64url")}`;
      const claimedAtMs = this.dependencies.clock.nowMs();
      const attempt = await this.dependencies.store.transaction(async (transaction) =>
        await transaction.claimDeliveryAttempt(
          record.id,
          leaseId,
          claimedAtMs,
          Math.min(
            claimedAtMs + this.dependencies.policy.deliveryLeaseMs,
            record.expiresAtMs,
          ),
        ),
      );
      if (attempt.status !== "claimed") continue;
      attempted += 1;
      const claimedRecord = attempt.record;
      const decryptionKey = await this.dependencies.keyring.decryptionKey(
        claimedRecord.sealedSecret.keyId,
      );
      const preSend = await this.dependencies.store.transaction(async (transaction) =>
        await transaction.validateDeliveryAttemptBeforeSend(
          claimedRecord.id,
          leaseId,
          this.dependencies.clock.nowMs(),
        ),
      );
      if (preSend.status !== "ready") continue;
      const readyRecord = preSend.record;
      if (decryptionKey === undefined) {
        await this.dependencies.store.transaction(async (transaction) =>
          await transaction.cancelDeliveryAttempt(
            readyRecord.id,
            leaseId,
            "unknown_key",
            this.dependencies.clock.nowMs(),
          ),
        );
        continue;
      }
      let secret: string;
      try {
        secret = openSecret(decryptionKey, readyRecord.sealedSecret).toString("base64url");
      } catch {
        await this.dependencies.store.transaction(async (transaction) =>
          await transaction.cancelDeliveryAttempt(
            readyRecord.id,
            leaseId,
            "tampered_envelope",
            this.dependencies.clock.nowMs(),
          ),
        );
        continue;
      }
      try {
        await this.dependencies.delivery.enqueue({
          normalizedDeliveryIdentity: readyRecord.normalizedDeliveryIdentity,
          purpose: readyRecord.purpose,
          url: `${publicOrigin(this.dependencies.publicOrigin)}/auth/magic-link/${readyRecord.selector}#${secret}`,
          idempotencyKey: readyRecord.id,
        });
      } catch {
        await this.dependencies.store.transaction(async (transaction) =>
          await transaction.releaseDeliveryAttempt(
            readyRecord.id,
            leaseId,
            this.dependencies.clock.nowMs(),
          ),
        );
        this.dependencies.logger.write("auth.magic_link.delivery", {
          result: "delivery_unavailable",
        });
        continue;
      }
      const marked = await this.dependencies.store.transaction(async (transaction) =>
        await transaction.completeDeliveryAttempt(
          readyRecord.id,
          leaseId,
          this.dependencies.clock.nowMs(),
        ),
      );
      if (marked) delivered += 1;
    }
    return { attempted, delivered };
  }
}

function compareMagicLinkCreationOrder(left: MagicLinkRecord, right: MagicLinkRecord): number {
  if (left.issuedAtMs !== right.issuedAtMs) {
    return left.issuedAtMs - right.issuedAtMs;
  }
  if (left.selector < right.selector) return -1;
  if (left.selector > right.selector) return 1;
  return 0;
}

function keyedDigest(key: Uint8Array, input: string | Uint8Array): string {
  return createHmac("sha256", key).update(input).digest("base64url");
}

function isSelector(value: string): boolean {
  return /^[A-Za-z0-9_-]+$/u.test(value) && Buffer.from(value, "base64url").length === 16;
}

function isEncodedSecret(value: string): boolean {
  return /^[A-Za-z0-9_-]+$/u.test(value) && Buffer.from(value, "base64url").length === 32;
}

function sealSecret(
  sealingKey: { readonly keyId: string; readonly key: Uint8Array },
  secret: Uint8Array,
  iv: Uint8Array,
): MagicLinkSealedSecretEnvelope {
  if (
    !validKeyId(sealingKey.keyId) ||
    sealingKey.key.byteLength !== 32 ||
    secret.byteLength !== 32 ||
    iv.byteLength !== 12
  ) {
    throw new MagicLinkError("invalid_configuration");
  }
  const cipher = createCipheriv("aes-256-gcm", sealingKey.key, iv);
  cipher.setAAD(Buffer.from(`roomscan-magic-link-delivery-v1:${sealingKey.keyId}`));
  const ciphertext = Buffer.concat([cipher.update(secret), cipher.final()]);
  return {
    version: "aes-256-gcm-v1",
    keyId: sealingKey.keyId,
    iv: Buffer.from(iv).toString("base64url"),
    ciphertext: ciphertext.toString("base64url"),
    authenticationTag: cipher.getAuthTag().toString("base64url"),
  };
}

function openSecret(key: Uint8Array, sealed: MagicLinkSealedSecretEnvelope): Buffer {
  if (
    key.byteLength !== 32 ||
    sealed.version !== "aes-256-gcm-v1" ||
    !validKeyId(sealed.keyId) ||
    !isBase64Url(sealed.iv) ||
    !isBase64Url(sealed.ciphertext) ||
    !isBase64Url(sealed.authenticationTag)
  ) {
    throw new MagicLinkError("invalid_configuration");
  }
  const iv = Buffer.from(sealed.iv, "base64url");
  const ciphertext = Buffer.from(sealed.ciphertext, "base64url");
  const tag = Buffer.from(sealed.authenticationTag, "base64url");
  if (iv.byteLength !== 12 || ciphertext.byteLength !== 32 || tag.byteLength !== 16) {
    throw new MagicLinkError("invalid_configuration");
  }
  const decipher = createDecipheriv("aes-256-gcm", key, iv);
  decipher.setAAD(Buffer.from(`roomscan-magic-link-delivery-v1:${sealed.keyId}`));
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(ciphertext), decipher.final()]);
}

function validKeyId(value: string): boolean {
  return /^[A-Za-z0-9._-]{1,64}$/u.test(value);
}

function isBase64Url(value: string): boolean {
  return /^[A-Za-z0-9_-]+$/u.test(value);
}

function publicOrigin(value: string): string {
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    throw new MagicLinkError("invalid_configuration");
  }
  if (
    parsed.protocol !== "https:" ||
    parsed.username.length > 0 ||
    parsed.password.length > 0 ||
    parsed.pathname !== "/" ||
    parsed.search.length > 0 ||
    parsed.hash.length > 0
  ) {
    throw new MagicLinkError("invalid_configuration");
  }
  return parsed.origin;
}

const CONFIRMATION_SCRIPT = `"use strict";
(() => {
  const fragmentSecret = window.location.hash.startsWith("#") ? window.location.hash.slice(1) : "";
  const selector = window.location.pathname.split("/").filter(Boolean).at(-1) ?? "";
  window.history.replaceState(null, "", "/auth/magic-link/confirm");
  const form = document.getElementById("magic-link-confirm");
  const button = document.getElementById("magic-link-submit");
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    button.disabled = true;
    await fetch("/auth/magic-link/consume", {
      method: "POST",
      credentials: "same-origin",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ selector, secret: fragmentSecret }),
    });
  });
})();`;

const CONFIRMATION_SCRIPT_HASH = createHash("sha256")
  .update(CONFIRMATION_SCRIPT)
  .digest("base64");

const CONFIRMATION_CSP =
  `default-src 'none'; script-src 'sha256-${CONFIRMATION_SCRIPT_HASH}'; connect-src 'self'; form-action 'none'; base-uri 'none'; frame-ancestors 'none'`;

const CONFIRMATION_HTML =
  `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="referrer" content="no-referrer"><title>Continue sign in</title></head><body><main><h1>Continue</h1><p>Confirm to continue in RoomScan Studio.</p><form id="magic-link-confirm"><button id="magic-link-submit" type="submit">Continue</button></form></main><script>${CONFIRMATION_SCRIPT}</script></body></html>`;
