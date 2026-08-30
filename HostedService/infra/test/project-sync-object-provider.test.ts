import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import { PROJECT_SYNC_MAX_ARCHIVE_BYTES } from "roomscan-studio-hosted-service/contracts";

import {
  AwsProjectSyncObjectProvider,
} from "../src/aws/project-sync-object-provider.js";
import {
  AwsProjectSyncValidationWakePort,
} from "../src/aws/project-sync-wake.js";
import type { AwsCommandSender } from "../src/aws/runtime-clients.js";

class RecordingSender implements AwsCommandSender {
  readonly commands: unknown[] = [];
  readonly responses: unknown[] = [];

  async send(command: unknown): Promise<unknown> {
    this.commands.push(command);
    const result = this.responses.shift();
    if (result === undefined) throw new Error("missing synthetic provider response");
    return result;
  }
}

const bytes = Uint8Array.of(1, 2, 3, 4);
const checksum = createHash("sha256").update(bytes).digest("base64");
const tenant = "a".repeat(24);
const quarantineKey = `server/quarantine/v1/${tenant}/professional-sync/quarantine/working/upl_abcdefghijklmnop.zip`;
const activeKey = `server/active/v1/${tenant}/professional-sync/active/working/rev_abcdefghijklmnop.zip`;
const bucketName = "roomscan-dev-project-sync-111111111111";

function commandName(command: unknown): string {
  return (command as { readonly constructor?: { readonly name?: string } }).constructor?.name ?? "unknown";
}

function commandInput(command: unknown): Readonly<Record<string, unknown>> {
  return (command as { readonly input: Readonly<Record<string, unknown>> }).input;
}

test("project-sync S3 provider preserves opaque version IDs and sends immutable exact-key requests", async () => {
  const sender = new RecordingSender();
  const observedPresigns: unknown[] = [];
  const provider = new AwsProjectSyncObjectProvider({
    sender,
    bucketName,
    presign: async (_sender: AwsCommandSender, command: unknown, options: Readonly<{ readonly expiresIn: number }>) => {
      observedPresigns.push(command, options);
      return `https://${bucketName}.s3.us-east-1.amazonaws.com/${quarantineKey}?signature=redacted`;
    },
  });

  const put = await provider.presignImmutablePut({
    physicalKey: quarantineKey,
    contentLength: bytes.byteLength,
    checksumSha256: checksum,
    contentType: "application/zip",
    expiresInSeconds: 300,
    ifNoneMatch: "*",
  });
  assert.equal(commandName(observedPresigns[0]), "PutObjectCommand");
  assert.deepEqual(commandInput(observedPresigns[0]!), {
    Bucket: bucketName,
    Key: quarantineKey,
    ContentLength: bytes.byteLength,
    ContentType: "application/zip",
    ChecksumSHA256: checksum,
    IfNoneMatch: "*",
  });
  assert.deepEqual(observedPresigns[1], { expiresIn: 300 });
  assert.deepEqual(put.headers, {
    "content-length": "4",
    "content-type": "application/zip",
    "x-amz-checksum-sha256": checksum,
    "if-none-match": "*",
  });

  const opaqueVersion = "opaque+/version-id";
  const exactBody = Uint8Array.from(bytes);
  sender.responses.push(
    {
      VersionId: opaqueVersion,
      ContentLength: bytes.byteLength,
      ContentType: "application/zip",
      ChecksumSHA256: checksum,
    },
    {
      VersionId: opaqueVersion,
      ContentLength: bytes.byteLength,
      ContentType: "application/zip",
      ChecksumSHA256: checksum,
      Body: { transformToByteArray: async () => exactBody },
    },
    { VersionId: "active+/version-id" },
  );
  assert.deepEqual(await provider.headCurrent({ physicalKey: quarantineKey }), {
    versionId: opaqueVersion,
    contentLength: bytes.byteLength,
    contentType: "application/zip",
    checksumSha256: checksum,
  });
  const exact = await provider.readExact({ physicalKey: quarantineKey, versionId: opaqueVersion });
  assert.deepEqual(exact, {
    versionId: opaqueVersion,
    bytes,
    contentType: "application/zip",
    checksumSha256: checksum,
  });
  assert.strictEqual(exact.bytes, exactBody,
    "the bounded provider body is retained rather than cloned before validation");
  assert.deepEqual(await provider.copyImmutable({
    sourcePhysicalKey: quarantineKey,
    sourceVersionId: opaqueVersion,
    destinationPhysicalKey: activeKey,
    ifNoneMatch: "*",
  }), { versionId: "active+/version-id" });
  await provider.presignExactDownload({
    physicalKey: activeKey,
    versionId: opaqueVersion,
    expiresInSeconds: 300,
  });

  assert.equal(commandName(sender.commands[0]), "HeadObjectCommand");
  assert.deepEqual(commandInput(sender.commands[0]!), {
    Bucket: bucketName,
    Key: quarantineKey,
    ChecksumMode: "ENABLED",
  });
  assert.equal(commandName(sender.commands[1]), "GetObjectCommand");
  assert.deepEqual(commandInput(sender.commands[1]!), {
    Bucket: bucketName,
    Key: quarantineKey,
    VersionId: opaqueVersion,
    ChecksumMode: "ENABLED",
  });
  assert.equal(commandName(sender.commands[2]), "CopyObjectCommand");
  assert.deepEqual(commandInput(sender.commands[2]!), {
    Bucket: bucketName,
    Key: activeKey,
    CopySource: `${bucketName}/${encodeURIComponent(quarantineKey)}?versionId=${encodeURIComponent(opaqueVersion)}`,
    IfNoneMatch: "*",
  });
  assert.equal(commandName(observedPresigns[2]), "GetObjectCommand");
  assert.deepEqual(commandInput(observedPresigns[2]!), {
    Bucket: bucketName,
    Key: activeKey,
    VersionId: opaqueVersion,
  }, "recovery signing forwards the exact opaque VersionId, including plus and slash");
});

test("project-sync S3 provider admits exactly 64 MiB without materializing an archive", async () => {
  const sender = new RecordingSender();
  const presigns: unknown[] = [];
  const provider = new AwsProjectSyncObjectProvider({
    sender,
    bucketName,
    presign: async (_sender, command) => {
      presigns.push(command);
      return "https://example.invalid/immutable-put";
    },
  });

  await assert.doesNotReject(provider.presignImmutablePut({
    physicalKey: quarantineKey,
    contentLength: PROJECT_SYNC_MAX_ARCHIVE_BYTES,
    checksumSha256: checksum,
    contentType: "application/zip",
    expiresInSeconds: 300,
    ifNoneMatch: "*",
  }));
  assert.equal(commandInput(presigns[0]!).ContentLength, PROJECT_SYNC_MAX_ARCHIVE_BYTES,
    "the exact operational ceiling is admitted before any body buffer exists");
});

test("project-sync S3 provider refuses malformed keys, unsafe opaque versions, and response substitution", async () => {
  const sender = new RecordingSender();
  const provider = new AwsProjectSyncObjectProvider({
    sender,
    bucketName,
    presign: async () => "https://example.invalid/put",
  });
  await assert.rejects(
    provider.readExact({ physicalKey: activeKey, versionId: "wrong\nversion" }),
    /project_sync_object_provider_invalid_request/u,
  );
  await assert.rejects(
    provider.presignImmutablePut({
      physicalKey: activeKey,
      contentLength: bytes.byteLength,
      checksumSha256: checksum,
      contentType: "application/zip",
      expiresInSeconds: 300,
      ifNoneMatch: "*",
    }),
    /project_sync_object_provider_invalid_request/u,
  );

  sender.responses.push({
    VersionId: "substituted+/version",
    ContentLength: bytes.byteLength,
    ContentType: "application/zip",
    ChecksumSHA256: checksum,
    Body: { transformToByteArray: async () => Uint8Array.from(bytes) },
  });
  await assert.rejects(
    provider.readExact({ physicalKey: activeKey, versionId: "expected+/version" }),
    /project_sync_object_provider_invalid_response/u,
  );
  await assert.rejects(
    provider.presignImmutablePut({
      physicalKey: quarantineKey,
      contentLength: PROJECT_SYNC_MAX_ARCHIVE_BYTES + 1,
      checksumSha256: checksum,
      contentType: "application/zip",
      expiresInSeconds: 300,
      ifNoneMatch: "*",
    }),
    /project_sync_object_provider_invalid_request/u,
  );
});

test("project-sync wake is targetless and always sends the single fixed body", async () => {
  const sender = new RecordingSender();
  sender.responses.push({ MessageId: "wake-1" });
  const wake = new AwsProjectSyncValidationWakePort({
    sender,
    queueUrl: "https://sqs.us-east-1.amazonaws.com/111111111111/roomscan-dev-project-sync-validation",
  });
  await wake.notifyValidationWake();
  assert.equal(commandName(sender.commands[0]), "SendMessageCommand");
  assert.deepEqual(commandInput(sender.commands[0]!), {
    QueueUrl: "https://sqs.us-east-1.amazonaws.com/111111111111/roomscan-dev-project-sync-validation",
    MessageBody: "roomscan-project-validation-wake-v1",
  });
});
