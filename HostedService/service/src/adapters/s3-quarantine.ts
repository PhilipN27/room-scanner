import { createHash } from "node:crypto";
import type { AuthorizedWorkspaceContext } from "../authorization/authorizer.js";
import type { RandomPort } from "../contracts/provider-ports.js";

const authenticScopes = new WeakSet<object>();
declare const quarantineScopeBrand: unique symbol;
export interface AuthorizedQuarantineScope { readonly workspaceId: string; readonly principalId: string; readonly authorizationVersion: number; readonly [quarantineScopeBrand]: true; }
/** Called only after centralized authorization, in the operation unit of work. */
export function deriveAuthorizedQuarantineScope(context: AuthorizedWorkspaceContext): AuthorizedQuarantineScope {
  if (!id(context.workspaceId) || !id(context.principalId) || !Number.isSafeInteger(context.authorizationVersion) || context.authorizationVersion <= 0) throw new Error("allocation_rejected");
  const scope = Object.freeze({ workspaceId: context.workspaceId, principalId: context.principalId, authorizationVersion: context.authorizationVersion }) as AuthorizedQuarantineScope; authenticScopes.add(scope); return scope;
}
export interface PresignPutPort { presignPut(input: { readonly key: string; readonly contentLength: number; readonly checksumSha256: string; readonly contentType: string; readonly expiresInSeconds: number; readonly metadata: Readonly<Record<string, string>>; readonly ifNoneMatch: "*"; readonly encryption: "bucket-default-kms" }): Promise<{ readonly url: string; readonly headers: Readonly<Record<string, string>> }>; }
export interface QuarantineAllocation { readonly key: string; readonly contentLength: number; readonly checksumSha256: string; readonly contentType: string; readonly expiresInSeconds: number; readonly put: { readonly url: string; readonly headers: Readonly<Record<string, string>> }; }
export class QuarantineAllocationService {
  private readonly issuedKeys = new Set<string>();
  constructor(private readonly d: { readonly random: RandomPort; readonly presigner: PresignPutPort; readonly maxBytes: number; readonly maxLifetimeSeconds: number }) { if (!Number.isSafeInteger(d.maxBytes) || d.maxBytes < 1 || !Number.isSafeInteger(d.maxLifetimeSeconds) || d.maxLifetimeSeconds < 1 || d.maxLifetimeSeconds > 300) throw new Error("allocation_rejected"); }
  async allocate(scope: AuthorizedQuarantineScope, input: { readonly contentLength: number; readonly checksumSha256: string; readonly contentType: "application/zip" | "application/octet-stream" }): Promise<QuarantineAllocation> {
    if (!authenticScopes.has(scope as object) || !Number.isSafeInteger(input.contentLength) || input.contentLength <= 0 || input.contentLength > this.d.maxBytes || !/^[A-Za-z0-9+/]{43}=$/.test(input.checksumSha256)) throw new Error("allocation_rejected");
    const bytes = this.d.random.bytes(32); if (bytes.length !== 32) throw new Error("allocation_rejected"); const randomKey = Buffer.from(bytes).toString("base64url");
    const tenantMarker = createHash("sha256").update(scope.workspaceId).digest("hex").slice(0, 24); const key = `server/quarantine/v1/${tenantMarker}/${randomKey}`;
    if (this.issuedKeys.has(key)) throw new Error("allocation_rejected"); this.issuedKeys.add(key);
    const metadata = { "roomscan-upload-kind": "quarantine-v1" } as const; const expiresInSeconds = this.d.maxLifetimeSeconds;
    const put = await this.d.presigner.presignPut({ key, contentLength: input.contentLength, checksumSha256: input.checksumSha256, contentType: input.contentType, expiresInSeconds, metadata, ifNoneMatch: "*", encryption: "bucket-default-kms" });
    validatePut(put, input, metadata); return Object.freeze({ key, contentLength: input.contentLength, checksumSha256: input.checksumSha256, contentType: input.contentType, expiresInSeconds, put: Object.freeze({ url: put.url, headers: Object.freeze({ ...put.headers }) }) });
  }
}
function validatePut(put: { readonly url: string; readonly headers: Readonly<Record<string, string>> }, input: { readonly contentLength: number; readonly checksumSha256: string; readonly contentType: string }, metadata: Readonly<Record<string, string>>): void {
  let url: URL; try { url = new URL(put.url); } catch { throw new Error("allocation_rejected"); } if (url.protocol !== "https:" || url.username || url.password) throw new Error("allocation_rejected");
  const normalized = new Map<string, string>(); for (const [name, value] of Object.entries(put.headers)) { const lower = name.toLowerCase(); if (normalized.has(lower)) throw new Error("allocation_rejected"); normalized.set(lower, value); }
  const expected = new Map<string, string>([["content-length", String(input.contentLength)], ["content-type", input.contentType], ["x-amz-checksum-sha256", input.checksumSha256], ["if-none-match", "*"], ["x-amz-meta-roomscan-upload-kind", metadata["roomscan-upload-kind"]!]]);
  if (normalized.size !== expected.size || [...expected].some(([name, value]) => normalized.get(name) !== value)) throw new Error("allocation_rejected");
}
function id(value: unknown): value is string { return typeof value === "string" && value.length >= 1 && value.length <= 256; }
