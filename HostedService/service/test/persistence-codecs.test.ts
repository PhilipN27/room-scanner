import assert from "node:assert/strict";
import test from "node:test";

import {
  PersistenceCodecError,
  decodeBillingPayloadSha256,
  decodeOpaqueDigest,
  epochMillisecondsToIsoTimestamp,
} from "../src/persistence/codecs.js";

test("persistence codecs accept only canonical 32-byte opaque and billing digests", () => {
  const opaque = Buffer.alloc(32, 0x61).toString("base64url");
  const billing = "ab".repeat(32);

  assert.deepEqual(Buffer.from(decodeOpaqueDigest(opaque)), Buffer.alloc(32, 0x61));
  assert.deepEqual(Buffer.from(decodeBillingPayloadSha256(billing)), Buffer.from(billing, "hex"));
  assert.equal(epochMillisecondsToIsoTimestamp(Date.UTC(2030, 0, 1, 0, 0, 0)), "2030-01-01T00:00:00.000Z");

  for (const malformed of [opaque.slice(1), `${opaque}=`, Buffer.alloc(31, 0x61).toString("base64url")]) {
    assert.throws(() => decodeOpaqueDigest(malformed), PersistenceCodecError);
  }
  for (const malformed of [billing.slice(1), billing.toUpperCase(), "gg".repeat(32)]) {
    assert.throws(() => decodeBillingPayloadSha256(malformed), PersistenceCodecError);
  }
  assert.throws(() => epochMillisecondsToIsoTimestamp(Number.MAX_SAFE_INTEGER), PersistenceCodecError);
});
