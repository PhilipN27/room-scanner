import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";

import {
  GetObjectCommand,
  HeadObjectCommand,
  PutObjectCommand,
} from "@aws-sdk/client-s3";

import {
  AwsPublicationObjectProvider,
  PublicationObjectProviderError,
} from "../src/aws/publication-object-provider.js";

const BUCKET = "roomscan-dev-published-111111111111";
const QUARANTINE = `server/published/quarantine/v1/pua_${"a".repeat(16)}.zip`;
const ACTIVE = `server/published/active/v1/pua_${"a".repeat(16)}/ast_${"b".repeat(16)}.bin`;
const BYTES = Uint8Array.from([1, 2, 3, 4]);
const CHECKSUM = createHash("sha256").update(BYTES).digest("base64");

test("publication provider pins exact versions and bounded ranges without exposing a read URL", async () => {
  const commands: unknown[] = [];
  const provider = new AwsPublicationObjectProvider({
    bucketName: BUCKET,
    sender: {
      send: async (command) => {
        commands.push(command);
        if (command instanceof HeadObjectCommand) return {
          VersionId: "version/one+opaque",
          ContentLength: BYTES.byteLength,
          ContentType: "application/zip",
          ChecksumSHA256: CHECKSUM,
        };
        if (command instanceof GetObjectCommand) return {
          VersionId: "version/one+opaque",
          ContentLength: 2,
          ContentRange: "bytes 1-2/4",
          Body: { transformToByteArray: async () => Uint8Array.from([2, 3]) },
        };
        throw new Error("unexpected command");
      },
    },
    presign: async (_sender, command, options) => {
      commands.push(command);
      assert.equal(options.expiresIn, 300);
      return "https://s3.us-east-1.amazonaws.com/opaque-upload";
    },
  });

  const upload = await provider.presignImmutablePut({
    physicalKey: QUARANTINE,
    contentLength: BYTES.byteLength,
    checksumSha256: CHECKSUM,
    contentType: "application/zip",
    expiresInSeconds: 300,
    ifNoneMatch: "*",
  });
  assert.deepEqual(upload.headers, {
    "content-length": "4",
    "content-type": "application/zip",
    "x-amz-checksum-sha256": CHECKSUM,
    "if-none-match": "*",
  });
  assert.ok(commands[0] instanceof PutObjectCommand);

  assert.deepEqual(await provider.headCurrent({ physicalKey: QUARANTINE }), {
    versionId: "version/one+opaque",
    contentLength: 4,
    contentType: "application/zip",
    checksumSha256: CHECKSUM,
  });
  assert.deepEqual(await provider.readRangeExact({
    physicalKey: QUARANTINE,
    versionId: "version/one+opaque",
    offset: 1,
    length: 2,
  }), Uint8Array.from([2, 3]));
  const get = commands.find((command) => command instanceof GetObjectCommand) as GetObjectCommand;
  assert.equal(get.input.VersionId, "version/one+opaque");
  assert.equal(get.input.Range, "bytes=1-2");
});

test("publication provider rejects cross-prefix keys and mismatched range responses before returning bytes", async () => {
  const provider = new AwsPublicationObjectProvider({
    bucketName: BUCKET,
    sender: {
      send: async () => ({
        VersionId: "version-one",
        ContentLength: 1,
        ContentRange: "bytes 0-0/2",
        Body: { transformToByteArray: async () => Uint8Array.from([1, 2]) },
      }),
    },
    presign: async () => "https://s3.us-east-1.amazonaws.com/upload",
  });

  await assert.rejects(
    provider.presignImmutablePut({
      physicalKey: ACTIVE,
      contentLength: 1,
      checksumSha256: CHECKSUM,
      contentType: "application/zip",
      expiresInSeconds: 300,
      ifNoneMatch: "*",
    }),
    (error: unknown) => error instanceof PublicationObjectProviderError && error.code === "publication_object_provider_invalid_request",
  );
  await assert.rejects(
    provider.readRangeExact({ physicalKey: ACTIVE, versionId: "version-one", offset: 0, length: 1 }),
    (error: unknown) => error instanceof PublicationObjectProviderError && error.code === "publication_object_provider_invalid_response",
  );
});
