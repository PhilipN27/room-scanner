export interface HttpApiV2Envelope {
  readonly body?: string | null;
  readonly isBase64Encoded?: boolean;
  readonly headers?: Readonly<Record<string, string | undefined>>;
}

export interface HttpApiV2Response {
  readonly statusCode: number;
  readonly headers: Readonly<Record<string, string>>;
  readonly body: string;
}

const CANONICAL_BASE64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;

/**
 * Returns the bytes delivered by HTTP API v2 without normalizing whitespace or
 * parsing the payload. Non-canonical base64 is rejected so distinct ingress
 * strings cannot silently collapse to the same verified byte sequence.
 */
export function rawHttpApiV2Body(envelope: HttpApiV2Envelope): Uint8Array | undefined {
  if (typeof envelope.body !== "string") return undefined;
  if (envelope.isBase64Encoded !== true) return Buffer.from(envelope.body, "utf8");
  if (!CANONICAL_BASE64.test(envelope.body)) return undefined;
  const decoded = Buffer.from(envelope.body, "base64");
  if (decoded.toString("base64") !== envelope.body) return undefined;
  return decoded;
}

/** Finds one unambiguous, case-insensitive header value. */
export function singleHttpHeader(
  headers: HttpApiV2Envelope["headers"],
  requestedName: string,
): string | undefined {
  if (headers === undefined) return undefined;
  const matches = Object.entries(headers).filter(
    ([name, value]) => name.toLowerCase() === requestedName.toLowerCase() && value !== undefined,
  );
  if (matches.length !== 1) return undefined;
  const value = matches[0]?.[1];
  return typeof value === "string" && value.length > 0 ? value : undefined;
}
