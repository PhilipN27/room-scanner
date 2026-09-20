import { createHash } from "node:crypto";

import {
  GetObjectCommand,
  HeadObjectCommand,
  PutObjectCommand,
  type S3Client,
} from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import type {
  PublicationContentType,
  PublicationObjectProvider,
} from "roomscan-studio-hosted-service/adapters";
import {
  PUBLICATION_MAX_ARCHIVE_BYTES,
  PUBLICATION_MAX_NESTED_AI_READY_BYTES,
} from "roomscan-studio-hosted-service/publication";

import type { AwsCommandSender } from "./runtime-clients.js";

const QUARANTINE_KEY = /^server\/published\/quarantine\/v1\/pua_[A-Za-z0-9_-]{16,128}\.zip$/u;
const ACTIVE_KEY = /^server\/published\/active\/v1\/pua_[A-Za-z0-9_-]{16,128}\/ast_[A-Za-z0-9_-]{16,128}\.bin$/u;
const SHA256_BASE64 = /^[A-Za-z0-9+/]{43}=$/u;
const CONTENT_TYPES = new Set<PublicationContentType>([
  "application/json",
  "image/png",
  "image/jpeg",
  "application/pdf",
  "application/zip",
]);

export class PublicationObjectProviderError extends Error {
  constructor(readonly code:
    | "publication_object_provider_invalid_request"
    | "publication_object_provider_invalid_response") {
    super(code);
    this.name = "PublicationObjectProviderError";
  }
}

export type AwsPublicationPresign = (
  sender: AwsCommandSender,
  command: PutObjectCommand,
  options: Readonly<{ readonly expiresIn: number }>,
) => Promise<string>;

/**
 * Exact AWS implementation of the service's private publication object port.
 * It accepts only service-derived v1 publication keys. Portal reads always use
 * an already-authorized VersionId and byte range; this provider never creates
 * a browser-readable GET URL or lists a bucket/prefix.
 */
export class AwsPublicationObjectProvider implements PublicationObjectProvider {
  readonly #sender: AwsCommandSender;
  readonly #bucketName: string;
  readonly #presign: AwsPublicationPresign;

  constructor(input: Readonly<{
    readonly sender: AwsCommandSender;
    readonly bucketName: string;
    readonly presign?: AwsPublicationPresign;
  }>) {
    if (!sender(input?.sender) || !bucketName(input.bucketName)) throw invalidRequest();
    this.#sender = input.sender;
    this.#bucketName = input.bucketName;
    this.#presign = input.presign ?? (async (client, command, options) =>
      getSignedUrl(client as unknown as S3Client, command, options));
  }

  async presignImmutablePut(input: Readonly<{
    readonly physicalKey: string;
    readonly contentLength: number;
    readonly checksumSha256: string;
    readonly contentType: "application/zip";
    readonly expiresInSeconds: 300;
    readonly ifNoneMatch: "*";
  }>): Promise<Readonly<{ readonly url: string; readonly headers: Readonly<Record<string, string>> }>> {
    if (!quarantineKey(input?.physicalKey)
      || !positiveLength(input.contentLength, PUBLICATION_MAX_ARCHIVE_BYTES)
      || !checksum(input.checksumSha256)
      || input.contentType !== "application/zip"
      || input.expiresInSeconds !== 300
      || input.ifNoneMatch !== "*") throw invalidRequest();
    let url: string;
    try {
      url = await this.#presign(this.#sender, new PutObjectCommand({
        Bucket: this.#bucketName,
        Key: input.physicalKey,
        ContentLength: input.contentLength,
        ContentType: input.contentType,
        ChecksumSHA256: input.checksumSha256,
        IfNoneMatch: "*",
      }), { expiresIn: 300 });
    } catch { throw invalidResponse(); }
    if (!safeHttpsUrl(url)) throw invalidResponse();
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
    readonly contentType: PublicationContentType;
    readonly checksumSha256: string;
  }>> {
    if (!publicationKey(input?.physicalKey)) throw invalidRequest();
    let response: Readonly<Record<string, unknown>>;
    try {
      response = record(await this.#sender.send(new HeadObjectCommand({
        Bucket: this.#bucketName,
        Key: input.physicalKey,
        ChecksumMode: "ENABLED",
      })));
    } catch { throw invalidResponse(); }
    const versionId = response.VersionId;
    const contentLength = response.ContentLength;
    const contentType = response.ContentType;
    const checksumSha256 = response.ChecksumSHA256;
    const maximum = quarantineKey(input.physicalKey)
      ? PUBLICATION_MAX_ARCHIVE_BYTES
      : PUBLICATION_MAX_NESTED_AI_READY_BYTES;
    if (!version(versionId) || !positiveLength(contentLength, maximum)
      || !contentTypeValue(contentType) || !checksum(checksumSha256)) throw invalidResponse();
    return Object.freeze({ versionId, contentLength, contentType, checksumSha256 });
  }

  async readRangeExact(input: Readonly<{
    readonly physicalKey: string;
    readonly versionId: string;
    readonly offset: number;
    readonly length: number;
  }>): Promise<Uint8Array> {
    if (!publicationKey(input?.physicalKey) || !version(input.versionId)
      || !nonNegativeInteger(input.offset) || !nonNegativeInteger(input.length)
      || input.length > PUBLICATION_MAX_NESTED_AI_READY_BYTES
      || input.offset > Number.MAX_SAFE_INTEGER - input.length) throw invalidRequest();
    if (input.length === 0) return new Uint8Array();
    const end = input.offset + input.length - 1;
    let response: Readonly<Record<string, unknown>>;
    try {
      response = record(await this.#sender.send(new GetObjectCommand({
        Bucket: this.#bucketName,
        Key: input.physicalKey,
        VersionId: input.versionId,
        Range: `bytes=${input.offset}-${end}`,
      })));
    } catch { throw invalidResponse(); }
    if (response.VersionId !== input.versionId || response.ContentLength !== input.length
      || !exactContentRange(response.ContentRange, input.offset, end)) throw invalidResponse();
    const bytes = await responseBytes(response.Body, input.length);
    if (bytes.byteLength !== input.length) throw invalidResponse();
    return bytes;
  }

  async putImmutable(input: Readonly<{
    readonly physicalKey: string;
    readonly bytes: Uint8Array;
    readonly contentType: PublicationContentType;
    readonly ifNoneMatch: "*";
  }>): Promise<Readonly<{ readonly versionId: string }>> {
    if (!activeKey(input?.physicalKey) || !(input.bytes instanceof Uint8Array)
      || !positiveLength(input.bytes.byteLength, PUBLICATION_MAX_NESTED_AI_READY_BYTES)
      || !contentTypeValue(input.contentType) || input.ifNoneMatch !== "*") throw invalidRequest();
    const bytes = Uint8Array.from(input.bytes);
    let response: Readonly<Record<string, unknown>>;
    try {
      response = record(await this.#sender.send(new PutObjectCommand({
        Bucket: this.#bucketName,
        Key: input.physicalKey,
        Body: bytes,
        ContentLength: bytes.byteLength,
        ContentType: input.contentType,
        ChecksumSHA256: createHash("sha256").update(bytes).digest("base64"),
        IfNoneMatch: "*",
      })));
    } catch { throw invalidResponse(); }
    if (!version(response.VersionId)) throw invalidResponse();
    return Object.freeze({ versionId: response.VersionId });
  }
}

function sender(value: unknown): value is AwsCommandSender {
  return value !== null && typeof value === "object"
    && typeof (value as AwsCommandSender).send === "function";
}

function record(value: unknown): Readonly<Record<string, unknown>> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw invalidResponse();
  return value as Readonly<Record<string, unknown>>;
}

function bucketName(value: unknown): value is string {
  return typeof value === "string" && /^[a-z0-9](?:[a-z0-9.-]{1,61})[a-z0-9]$/u.test(value)
    && !value.includes("..") && !/^\d+\.\d+\.\d+\.\d+$/u.test(value);
}

function publicationKey(value: unknown): value is string {
  return quarantineKey(value) || activeKey(value);
}

function quarantineKey(value: unknown): value is string {
  return typeof value === "string" && QUARANTINE_KEY.test(value);
}

function activeKey(value: unknown): value is string {
  return typeof value === "string" && ACTIVE_KEY.test(value);
}

function checksum(value: unknown): value is string {
  return typeof value === "string" && SHA256_BASE64.test(value);
}

function contentTypeValue(value: unknown): value is PublicationContentType {
  return typeof value === "string" && CONTENT_TYPES.has(value as PublicationContentType);
}

function positiveLength(value: unknown, maximum: number): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 1 && value <= maximum;
}

function nonNegativeInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

function version(value: unknown): value is string {
  return typeof value === "string" && Buffer.byteLength(value, "utf8") >= 1
    && Buffer.byteLength(value, "utf8") <= 1_024
    && !/[\u0000-\u001f\u007f-\u009f]/u.test(value)
    && !/[\ud800-\udfff]/u.test(value);
}

function exactContentRange(value: unknown, offset: number, end: number): boolean {
  if (typeof value !== "string") return false;
  const match = /^bytes (0|[1-9][0-9]*)-(0|[1-9][0-9]*)\/(0|[1-9][0-9]*)$/u.exec(value);
  if (match?.[1] === undefined || match[2] === undefined || match[3] === undefined) return false;
  const start = Number(match[1]);
  const returnedEnd = Number(match[2]);
  const total = Number(match[3]);
  return Number.isSafeInteger(start) && Number.isSafeInteger(returnedEnd) && Number.isSafeInteger(total)
    && start === offset && returnedEnd === end && total > end;
}

async function responseBytes(value: unknown, maximum: number): Promise<Uint8Array> {
  if (value === null || typeof value !== "object"
    || typeof (value as { readonly transformToByteArray?: unknown }).transformToByteArray !== "function") throw invalidResponse();
  let bytes: unknown;
  try {
    bytes = await (value as { readonly transformToByteArray: () => Promise<unknown> }).transformToByteArray();
  } catch { throw invalidResponse(); }
  if (!(bytes instanceof Uint8Array) || bytes.byteLength > maximum) throw invalidResponse();
  return Uint8Array.from(bytes);
}

function safeHttpsUrl(value: string): boolean {
  try {
    const url = new URL(value);
    return url.protocol === "https:" && url.username === "" && url.password === "";
  } catch { return false; }
}

function invalidRequest(): PublicationObjectProviderError {
  return new PublicationObjectProviderError("publication_object_provider_invalid_request");
}

function invalidResponse(): PublicationObjectProviderError {
  return new PublicationObjectProviderError("publication_object_provider_invalid_response");
}
