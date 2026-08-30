import { createHash } from "node:crypto";

import {
  CopyObjectCommand,
  GetObjectCommand,
  HeadObjectCommand,
  PutObjectCommand,
  type S3Client,
} from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { PROJECT_SYNC_MAX_ARCHIVE_BYTES } from "roomscan-studio-hosted-service/contracts";

import type { AwsCommandSender } from "./runtime-clients.js";

const QUARANTINE_KEY = /^server\/quarantine\/v1\/[a-f0-9]{24}\/professional-sync\/quarantine\/(?:working|raw)\/upl_[A-Za-z0-9_-]{16,128}\.zip$/u;
const ACTIVE_KEY = /^server\/active\/v1\/[a-f0-9]{24}\/professional-sync\/active\/(?:working\/rev_|raw\/upl_)[A-Za-z0-9_-]{16,128}\.zip$/u;
const SHA256_BASE64 = /^[A-Za-z0-9+/]{43}=$/u;
/** The service's public archive ceiling. `readExact` buffers ZIP data for the
 * package validator, so accepting S3's five-gigabyte single-PUT ceiling here
 * would turn a provider object into an unbounded Lambda memory claim. */
const MAX_OBJECT_BYTES = PROJECT_SYNC_MAX_ARCHIVE_BYTES;

/** Generic provider failure only. Object keys, opaque versions, bucket names,
 * SDK errors, and object bytes never appear in its message. */
export class ProjectSyncObjectProviderError extends Error {
  constructor(readonly code: "project_sync_object_provider_invalid_request" | "project_sync_object_provider_invalid_response") {
    super(code);
    this.name = "ProjectSyncObjectProviderError";
  }
}

export type AwsProjectSyncPresign = (
  sender: AwsCommandSender,
  command: PutObjectCommand | GetObjectCommand,
  options: Readonly<{ readonly expiresIn: number }>,
) => Promise<string>;

/**
 * The concrete AWS boundary for the service's `ProjectSyncObjectProvider`.
 * It takes only physical keys already derived by the service adapter. S3
 * VersionIds are opaque UTF-8 data: we forward them verbatim as VersionId or
 * query values and never interpret them as a path segment or identifier.
 */
export class AwsProjectSyncObjectProvider {
  readonly #sender: AwsCommandSender;
  readonly #bucketName: string;
  readonly #presign: AwsProjectSyncPresign;

  constructor(input: Readonly<{
    readonly sender: AwsCommandSender;
    readonly bucketName: string;
    readonly presign?: AwsProjectSyncPresign;
  }>) {
    if (!sender(input?.sender) || !bucketName(input.bucketName)) {
      throw fail("project_sync_object_provider_invalid_request");
    }
    this.#sender = input.sender;
    this.#bucketName = input.bucketName;
    this.#presign = input.presign ?? (async (sender, command, options) =>
      getSignedUrl(sender as unknown as S3Client, command, options));
  }

  async presignImmutablePut(input: Readonly<{
    readonly physicalKey: string;
    readonly contentLength: number;
    readonly checksumSha256: string;
    readonly contentType: "application/zip";
    readonly expiresInSeconds: 300;
    readonly ifNoneMatch: "*";
  }>): Promise<Readonly<{ readonly url: string; readonly headers: Readonly<Record<string, string>> }>> {
    if (!quarantineKey(input?.physicalKey) || !positiveObjectLength(input.contentLength)
      || !checksum(input.checksumSha256) || input.contentType !== "application/zip"
      || input.expiresInSeconds !== 300 || input.ifNoneMatch !== "*") {
      throw fail("project_sync_object_provider_invalid_request");
    }
    const url = await this.#presign(this.#sender, new PutObjectCommand({
      Bucket: this.#bucketName,
      Key: input.physicalKey,
      ContentLength: input.contentLength,
      ContentType: input.contentType,
      ChecksumSHA256: input.checksumSha256,
      // First writer wins. We intentionally do not put a bucket-policy
      // condition on CopyObject because AWS documents that such enforcement
      // makes conditional copies return 501; the adapter always sets this.
      IfNoneMatch: "*",
    }), { expiresIn: 300 });
    if (!safeHttpsUrl(url)) throw fail("project_sync_object_provider_invalid_response");
    return Object.freeze({
      url,
      headers: Object.freeze({
        "content-length": String(input.contentLength),
        "content-type": "application/zip",
        "x-amz-checksum-sha256": input.checksumSha256,
        "if-none-match": "*",
      }),
    });
  }

  async headCurrent(input: Readonly<{ readonly physicalKey: string }>): Promise<Readonly<{
    readonly versionId: string;
    readonly contentLength: number;
    readonly contentType: "application/zip";
    readonly checksumSha256: string;
  }>> {
    if (!projectSyncKey(input?.physicalKey)) throw fail("project_sync_object_provider_invalid_request");
    const response = record(await this.#sender.send(new HeadObjectCommand({
      Bucket: this.#bucketName,
      Key: input.physicalKey,
      ChecksumMode: "ENABLED",
    })));
    const versionId = response?.VersionId;
    const contentLength = response?.ContentLength;
    const contentType = response?.ContentType;
    const checksumSha256 = response?.ChecksumSHA256;
    if (!versionIdValue(versionId) || !positiveObjectLength(contentLength)
      || contentType !== "application/zip" || !checksum(checksumSha256)) {
      throw fail("project_sync_object_provider_invalid_response");
    }
    return Object.freeze({ versionId, contentLength, contentType, checksumSha256 });
  }

  async readExact(input: Readonly<{ readonly physicalKey: string; readonly versionId: string }>): Promise<Readonly<{
    readonly versionId: string;
    readonly bytes: Uint8Array;
    readonly contentType: "application/zip";
    readonly checksumSha256: string;
  }>> {
    if (!projectSyncKey(input?.physicalKey) || !versionIdValue(input.versionId)) {
      throw fail("project_sync_object_provider_invalid_request");
    }
    const response = record(await this.#sender.send(new GetObjectCommand({
      Bucket: this.#bucketName,
      Key: input.physicalKey,
      VersionId: input.versionId,
      ChecksumMode: "ENABLED",
    })));
    const responseVersionId = response?.VersionId;
    const contentLength = response?.ContentLength;
    const contentType = response?.ContentType;
    const checksumSha256 = response?.ChecksumSHA256;
    if (responseVersionId !== input.versionId || !positiveObjectLength(contentLength)
      || contentType !== "application/zip" || !checksum(checksumSha256)) {
      throw fail("project_sync_object_provider_invalid_response");
    }
    const bytes = await byteArray(response?.Body);
    if (bytes.byteLength !== contentLength
      || createHash("sha256").update(bytes).digest("base64") !== checksumSha256) {
      throw fail("project_sync_object_provider_invalid_response");
    }
    return Object.freeze({
      versionId: responseVersionId,
      bytes,
      contentType,
      checksumSha256,
    });
  }

  async copyImmutable(input: Readonly<{
    readonly sourcePhysicalKey: string;
    readonly sourceVersionId: string;
    readonly destinationPhysicalKey: string;
    readonly ifNoneMatch: "*";
  }>): Promise<Readonly<{ readonly versionId: string }>> {
    if (!quarantineKey(input?.sourcePhysicalKey) || !activeKey(input.destinationPhysicalKey)
      || !matchingTier(input.sourcePhysicalKey, input.destinationPhysicalKey)
      || !versionIdValue(input.sourceVersionId) || input.ifNoneMatch !== "*") {
      throw fail("project_sync_object_provider_invalid_request");
    }
    const response = record(await this.#sender.send(new CopyObjectCommand({
      Bucket: this.#bucketName,
      Key: input.destinationPhysicalKey,
      // Query encoding is deliberately separate from storage-key derivation;
      // it preserves opaque S3 IDs such as `+` and `/` exactly on the wire.
      CopySource: `${this.#bucketName}/${encodeURIComponent(input.sourcePhysicalKey)}?versionId=${encodeURIComponent(input.sourceVersionId)}`,
      IfNoneMatch: "*",
    })));
    if (!versionIdValue(response?.VersionId)) throw fail("project_sync_object_provider_invalid_response");
    return Object.freeze({ versionId: response.VersionId });
  }

  async presignExactDownload(input: Readonly<{
    readonly physicalKey: string;
    readonly versionId: string;
    readonly expiresInSeconds: 300;
  }>): Promise<Readonly<{ readonly url: string }>> {
    if (!activeKey(input?.physicalKey) || !versionIdValue(input.versionId) || input.expiresInSeconds !== 300) {
      throw fail("project_sync_object_provider_invalid_request");
    }
    const url = await this.#presign(this.#sender, new GetObjectCommand({
      Bucket: this.#bucketName,
      Key: input.physicalKey,
      VersionId: input.versionId,
    }), { expiresIn: 300 });
    if (!safeHttpsUrl(url)) throw fail("project_sync_object_provider_invalid_response");
    return Object.freeze({ url });
  }
}

function sender(value: unknown): value is AwsCommandSender {
  return value !== null && typeof value === "object" && typeof (value as AwsCommandSender).send === "function";
}

function bucketName(value: unknown): value is string {
  return typeof value === "string" && /^[a-z0-9](?:[a-z0-9.-]{1,61})[a-z0-9]$/u.test(value)
    && !value.includes("..") && !/^\d+\.\d+\.\d+\.\d+$/u.test(value);
}

function projectSyncKey(value: unknown): value is string {
  return quarantineKey(value) || activeKey(value);
}

function quarantineKey(value: unknown): value is string {
  return typeof value === "string" && QUARANTINE_KEY.test(value);
}

function activeKey(value: unknown): value is string {
  return typeof value === "string" && ACTIVE_KEY.test(value);
}

function matchingTier(source: string, destination: string): boolean {
  return (source.includes("/quarantine/working/") && destination.includes("/active/working/"))
    || (source.includes("/quarantine/raw/") && destination.includes("/active/raw/"));
}

function positiveObjectLength(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 1 && value <= MAX_OBJECT_BYTES;
}

function checksum(value: unknown): value is string {
  return typeof value === "string" && SHA256_BASE64.test(value);
}

function versionIdValue(value: unknown): value is string {
  return typeof value === "string" && Buffer.byteLength(value, "utf8") >= 1
    && Buffer.byteLength(value, "utf8") <= 1_024
    && !/[\u0000-\u001f\u007f-\u009f]/u.test(value)
    && !/[\ud800-\udfff]/u.test(value);
}

async function byteArray(value: unknown): Promise<Uint8Array> {
  if (value === null || typeof value !== "object" || typeof (value as { readonly transformToByteArray?: unknown }).transformToByteArray !== "function") {
    throw fail("project_sync_object_provider_invalid_response");
  }
  let result: unknown;
  try {
    result = await (value as { transformToByteArray(): Promise<Uint8Array> }).transformToByteArray();
  } catch {
    throw fail("project_sync_object_provider_invalid_response");
  }
  if (!(result instanceof Uint8Array) || result.byteLength === 0 || result.byteLength > MAX_OBJECT_BYTES) {
    throw fail("project_sync_object_provider_invalid_response");
  }
  // `transformToByteArray` already returns the bounded complete response.
  // Returning it intact avoids a second full archive allocation in the Lambda.
  return result;
}

function safeHttpsUrl(value: unknown): value is string {
  try {
    const url = new URL(typeof value === "string" ? value : "");
    return url.protocol === "https:" && url.username === "" && url.password === "" && url.hostname.length > 0;
  } catch {
    return false;
  }
}

function record(value: unknown): Readonly<Record<string, unknown>> | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Readonly<Record<string, unknown>>
    : undefined;
}

function fail(code: ProjectSyncObjectProviderError["code"]): ProjectSyncObjectProviderError {
  return new ProjectSyncObjectProviderError(code);
}
