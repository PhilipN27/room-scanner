namespace RoomScanWeb {
  export type ApprovedAssetContentType = "application/json" | "image/png" | "image/jpeg" | "application/pdf" | "application/zip";
  export type PortalDownloadKind = "floor_plan_pdf" | "gallery_zip" | "ai_ready_package";
  export type DownloadedPortalAsset = Readonly<{ readonly blob: Blob; readonly contentType: ApprovedAssetContentType; readonly byteCount: number }>;
  export type Slice6Fetch = (path: string, init: RequestInit) => Promise<Response>;

  export class WebServiceError extends Error {
    constructor(readonly code: "unavailable" | "invalid_response" | "invalid_asset") {
      super(code);
      this.name = "WebServiceError";
    }
  }

  export interface Slice6ServiceClient {
    exchangePortalLink(secret: string): Promise<Readonly<{ readonly status: "active" | "pin_required" | "unavailable" }>>;
    verifyPIN(pin: string): Promise<Readonly<{ readonly status: "active" | "unavailable" }>>;
    portalSnapshot(): Promise<PortalSnapshotResponse>;
    downloadPortalAsset(input: Readonly<{ readonly assetID?: string; readonly downloadKind?: PortalDownloadKind; readonly expectedByteCount?: number }>): Promise<DownloadedPortalAsset>;
    requestFeedbackVerification(email: string): Promise<Readonly<{ readonly status: "accepted" }>>;
    consumeFeedbackVerification(verificationCode: string): Promise<Readonly<{ readonly status: "verified" | "unavailable" }>>;
    createFeedback(action: "comment" | "approve" | "request_changes", comment?: string): Promise<Readonly<{ readonly status: "recorded"; readonly feedbackID: string; readonly displayName: string }>>;
  }

  export function createServiceClient(input: Readonly<{ readonly fetch: Slice6Fetch; readonly requestID?: () => string | undefined }>): Slice6ServiceClient {
    if (input === null || typeof input !== "object" || typeof input.fetch !== "function") throw new WebServiceError("unavailable");
    const nextRequestID = input.requestID ?? randomRequestID;
    return Object.freeze({
      exchangePortalLink: async (inputSecret: string): Promise<Readonly<{ readonly status: "active" | "pin_required" | "unavailable" }>> => {
        let secret: string | undefined = canonicalOpaqueSecret(inputSecret) ? inputSecret : undefined;
        if (secret === undefined) throw new WebServiceError("unavailable");
        try {
          const response = await send(input.fetch, "/portal/link/exchange", undefined, Object.freeze({ authorization: `RoomScan-Link ${secret}` }));
          const value = await jsonResponse(response);
          const record = responseRecord(value, ["status"], []);
          return Object.freeze({ status: responseEnum(record.status, ["active", "pin_required", "unavailable"] as const) });
        } finally {
          secret = undefined;
        }
      },
      verifyPIN: async (pin: string): Promise<Readonly<{ readonly status: "active" | "unavailable" }>> => {
        if (!/^[0-9]{6}$/u.test(pin)) throw new WebServiceError("unavailable");
        const record = responseRecord(await jsonResponse(await send(input.fetch, "/portal/pin/verify", Object.freeze({ pin }))), ["status"], []);
        return Object.freeze({ status: responseEnum(record.status, ["active", "unavailable"] as const) });
      },
      portalSnapshot: async (): Promise<PortalSnapshotResponse> => parsePortalSnapshot(await jsonResponse(await send(input.fetch, "/portal/snapshot"))),
      downloadPortalAsset: async (request: Readonly<{ readonly assetID?: string; readonly downloadKind?: PortalDownloadKind; readonly expectedByteCount?: number }>): Promise<DownloadedPortalAsset> => downloadPortalAsset(input.fetch, nextRequestID, request),
      requestFeedbackVerification: async (email: string): Promise<Readonly<{ readonly status: "accepted" }>> => {
        if (!validEmail(email)) throw new WebServiceError("unavailable");
        const requestID = requireRequestID(nextRequestID());
        const record = responseRecord(await jsonResponse(await send(input.fetch, "/portal/feedback/verification/request", Object.freeze({ email, requestID }))), ["status"], []);
        if (responseEnum(record.status, ["accepted"] as const) !== "accepted") throw new WebServiceError("invalid_response");
        return Object.freeze({ status: "accepted" as const });
      },
      consumeFeedbackVerification: async (verificationCode: string): Promise<Readonly<{ readonly status: "verified" | "unavailable" }>> => {
        if (!/^[A-Za-z0-9_-]{43}\.[A-Za-z0-9_-]{43}$/u.test(verificationCode)) throw new WebServiceError("unavailable");
        const record = responseRecord(await jsonResponse(await send(input.fetch, "/portal/feedback/verification/consume", Object.freeze({ verificationCode }))), ["status"], []);
        return Object.freeze({ status: responseEnum(record.status, ["verified", "unavailable"] as const) });
      },
      createFeedback: async (action: "comment" | "approve" | "request_changes", comment?: string): Promise<Readonly<{ readonly status: "recorded"; readonly feedbackID: string; readonly displayName: string }>> => {
        if (!(action === "comment" || action === "approve" || action === "request_changes") || (comment !== undefined && (comment.length < 1 || Array.from(comment).length > 4_000))) throw new WebServiceError("unavailable");
        const requestID = requireRequestID(nextRequestID());
        const record = responseRecord(await jsonResponse(await send(input.fetch, "/portal/feedback", Object.freeze({ action, ...(comment === undefined ? {} : { comment }), requestID }))), ["status", "feedbackID", "displayName"], []);
        if (responseEnum(record.status, ["recorded"] as const) !== "recorded" || typeof record.feedbackID !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu.test(record.feedbackID) || typeof record.displayName !== "string" || record.displayName.length < 1 || Array.from(record.displayName).length > 120) throw new WebServiceError("invalid_response");
        return Object.freeze({ status: "recorded" as const, feedbackID: record.feedbackID, displayName: record.displayName });
      },
    });
  }

  async function downloadPortalAsset(fetchImpl: Slice6Fetch, nextRequestID: () => string | undefined, input: Readonly<{ readonly assetID?: string; readonly downloadKind?: PortalDownloadKind; readonly expectedByteCount?: number }>): Promise<DownloadedPortalAsset> {
    const assetID = input.assetID;
    const downloadKind = input.downloadKind;
    if ((assetID === undefined) === (downloadKind === undefined) || (assetID !== undefined && !isPublicID(assetID, "ast_")) || (downloadKind !== undefined && !(["floor_plan_pdf", "gallery_zip", "ai_ready_package"] as const).includes(downloadKind))) throw new WebServiceError("invalid_asset");
    if (input.expectedByteCount !== undefined && (!Number.isSafeInteger(input.expectedByteCount) || input.expectedByteCount < 1 || input.expectedByteCount > MAX_PROTECTED_ASSET_BYTES)) throw new WebServiceError("invalid_asset");
    const chunks: BlobPart[] = [];
    let offset = 0;
    let total: number | undefined;
    let contentType: ApprovedAssetContentType | undefined;
    while (total === undefined || offset < total) {
      const requestID = nextRequestID();
      if (typeof requestID !== "string" || !/^[A-Za-z0-9_-]{16,128}$/u.test(requestID)) throw new WebServiceError("invalid_asset");
      const remaining = total === undefined ? input.expectedByteCount : total - offset;
      const requestedByteCount = remaining === undefined ? 1 : Math.min(MAX_PROTECTED_CHUNK_BYTES, remaining);
      const body = Object.freeze({
        ...(assetID === undefined ? { downloadKind } : { assetID }),
        offset,
        byteCount: requestedByteCount,
        requestID,
      });
      const response = await send(fetchImpl, "/portal/asset", body);
      const range = parseAssetRange(response, offset, requestedByteCount);
      if (total !== undefined && range.total !== total) throw new WebServiceError("invalid_asset");
      total = range.total;
      if (input.expectedByteCount !== undefined && total !== input.expectedByteCount) throw new WebServiceError("invalid_asset");
      const type = approvedContentType(response.headers.get("content-type"));
      if (contentType !== undefined && contentType !== type) throw new WebServiceError("invalid_asset");
      contentType = type;
      const bytes = new Uint8Array(await response.arrayBuffer());
      if (bytes.byteLength !== range.end - range.start + 1 || range.end >= total || range.start !== offset) throw new WebServiceError("invalid_asset");
      chunks.push(bytes);
      offset = range.end + 1;
      if (offset > total || chunks.length > MAX_PROTECTED_REQUESTS) throw new WebServiceError("invalid_asset");
    }
    if (total === undefined || contentType === undefined || offset !== total) throw new WebServiceError("invalid_asset");
    return Object.freeze({ blob: new Blob(chunks, { type: contentType }), contentType, byteCount: total });
  }

  const MAX_PROTECTED_CHUNK_BYTES = 4_194_304;
  const MAX_PROTECTED_ASSET_BYTES = 536_870_912;
  const MAX_PROTECTED_REQUESTS = 1 + Math.ceil((MAX_PROTECTED_ASSET_BYTES - 1) / MAX_PROTECTED_CHUNK_BYTES);

  async function send(fetchImpl: Slice6Fetch, path: "/portal/link/exchange" | "/portal/pin/verify" | "/portal/snapshot" | "/portal/asset" | "/portal/feedback/verification/request" | "/portal/feedback/verification/consume" | "/portal/feedback", body?: unknown, extraHeaders: Readonly<Record<string, string>> = Object.freeze({})): Promise<Response> {
    let response: Response;
    try {
      response = await fetchImpl(path, Object.freeze({
        method: "POST",
        credentials: "include",
        cache: "no-store",
        referrerPolicy: "no-referrer",
        headers: Object.freeze({ ...(body === undefined ? {} : { "content-type": "application/json" }), ...extraHeaders }),
        ...(body === undefined ? {} : { body: canonicalJSON(body) }),
      }));
    } catch {
      throw new WebServiceError("unavailable");
    }
    if (!(response instanceof Response) || !response.ok) throw new WebServiceError("unavailable");
    return response;
  }

  async function jsonResponse(response: Response): Promise<unknown> {
    if (!isJSONContentType(response.headers.get("content-type"))) throw new WebServiceError("invalid_response");
    let source: string;
    try { source = await response.text(); } catch { throw new WebServiceError("invalid_response"); }
    if (source.length === 0 || source.length > 262_144) throw new WebServiceError("invalid_response");
    try { return JSON.parse(source); } catch { throw new WebServiceError("invalid_response"); }
  }

  function parseAssetRange(response: Response, expectedStart: number, expectedLength: number): Readonly<{ readonly start: number; readonly end: number; readonly total: number }> {
    if (response.headers.get("cache-control") !== "no-store" || response.headers.get("accept-ranges") !== "bytes") throw new WebServiceError("invalid_asset");
    const range = /^bytes ([0-9]+)-([0-9]+)\/([0-9]+)$/u.exec(response.headers.get("content-range") ?? "");
    if (range?.[1] === undefined || range[2] === undefined || range[3] === undefined) throw new WebServiceError("invalid_asset");
    const start = Number(range[1]); const end = Number(range[2]); const total = Number(range[3]);
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || !Number.isSafeInteger(total) || start !== expectedStart || end < start || total < 1 || total > MAX_PROTECTED_ASSET_BYTES || end - start + 1 !== expectedLength) throw new WebServiceError("invalid_asset");
    return Object.freeze({ start, end, total });
  }

  function approvedContentType(value: string | null): ApprovedAssetContentType {
    if (value === "application/json" || value === "image/png" || value === "image/jpeg" || value === "application/pdf" || value === "application/zip") return value;
    throw new WebServiceError("invalid_asset");
  }
  function isJSONContentType(value: string | null): boolean { return value === "application/json"; }
  function responseRecord(value: unknown, requiredKeys: readonly string[], optionalKeys: readonly string[]): Readonly<Record<string, unknown>> {
    if (value === null || typeof value !== "object" || Array.isArray(value) || Object.getPrototypeOf(value) !== Object.prototype) throw new WebServiceError("invalid_response");
    const record = value as Readonly<Record<string, unknown>>; const allowed = new Set([...requiredKeys, ...optionalKeys]);
    if (Object.keys(record).some((key) => !allowed.has(key)) || requiredKeys.some((key) => !(key in record))) throw new WebServiceError("invalid_response");
    return record;
  }
  function responseEnum<T extends readonly string[]>(value: unknown, allowed: T): T[number] { if (typeof value !== "string" || !allowed.includes(value)) throw new WebServiceError("invalid_response"); return value as T[number]; }
  function requireRequestID(value: string | undefined): string { if (typeof value !== "string" || !/^[A-Za-z0-9_-]{16,128}$/u.test(value)) throw new WebServiceError("unavailable"); return value; }
  function validEmail(value: string): boolean { return typeof value === "string" && value.length >= 3 && value.length <= 320 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/u.test(value); }
  function isPublicID(value: string, prefix: string): boolean { return value.length >= 20 && value.length <= 132 && value.startsWith(prefix) && /^[A-Za-z0-9_-]+$/u.test(value); }
  function randomRequestID(): string | undefined { try { const bytes = new Uint8Array(16); crypto.getRandomValues(bytes); return toBase64URL(bytes); } catch { return undefined; } }
}
