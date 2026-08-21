/** Exact value codecs for the frozen 0007 capability boundary.
 *
 * Opaque session/proof values are canonical unpadded base64url encodings of
 * 32-byte keyed digests. Stripe's already-computed payload digest is canonical
 * lower-case hexadecimal. Keeping these conversions here prevents Data API
 * callers from silently sending text to a bytea capability argument. */
export class PersistenceCodecError extends Error {
  constructor(readonly code: "invalid_digest" | "invalid_timestamp") {
    super(code);
    this.name = "PersistenceCodecError";
  }
}

export function decodeOpaqueDigest(value: string): Uint8Array {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]{43}$/u.test(value)) {
    throw new PersistenceCodecError("invalid_digest");
  }
  const decoded = Buffer.from(value, "base64url");
  if (decoded.length !== 32 || decoded.toString("base64url") !== value) {
    throw new PersistenceCodecError("invalid_digest");
  }
  return Uint8Array.from(decoded);
}

export function decodeBillingPayloadSha256(value: string): Uint8Array {
  if (typeof value !== "string" || !/^[0-9a-f]{64}$/u.test(value)) {
    throw new PersistenceCodecError("invalid_digest");
  }
  const decoded = Buffer.from(value, "hex");
  if (decoded.length !== 32 || decoded.toString("hex") !== value) {
    throw new PersistenceCodecError("invalid_digest");
  }
  return Uint8Array.from(decoded);
}

export function epochMillisecondsToIsoTimestamp(value: number): string {
  if (!Number.isSafeInteger(value) || Math.abs(value) > 8_640_000_000_000_000) {
    throw new PersistenceCodecError("invalid_timestamp");
  }
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) {
    throw new PersistenceCodecError("invalid_timestamp");
  }
  return date.toISOString();
}
