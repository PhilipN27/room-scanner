import assert from "node:assert/strict";
import test from "node:test";

import { findCanaryLeaks, type StructuredLogEvent, type StructuredLogSink } from "../privacy-logger.js";
import { PublicationPrivacyAudit, PublicationPrivacyAuditError } from "../src/publication/privacy-audit.js";

class MemorySink implements StructuredLogSink {
  readonly events: StructuredLogEvent[] = [];
  write(event: StructuredLogEvent): void { this.events.push(structuredClone(event)); }
}

test("publication audit has an independent allowlist and cannot serialize publication authority or free-form data", () => {
  const sink = new MemorySink();
  const audit = new PublicationPrivacyAudit({
    sink,
    random: { bytes: (length) => Buffer.alloc(length, 0x71) },
    pseudonymHmacKey: Buffer.alloc(32, 0x72),
    identifierHmacKey: Buffer.alloc(32, 0x73),
  });
  audit.record({ action: "publication.portal.asset", result: "delivered", bytes: 1024 });
  assert.deepEqual(sink.events, [{ eventCode: "publication.portal.asset", result: "delivered", counters: { delivered_bytes: 1024 } }]);
  const canaries = [
    Buffer.alloc(32, 0x81).toString("base64url"), "123456", "person+portal@example.test", "comment-canary<script>alert(1)</script>",
    "server/published/active/v1/pua_canary/ast_canary.bin", "object-version-canary", "archive-digest-canary",
  ];
  for (const canary of canaries) {
    assert.throws(() => audit.record({ action: canary as never, result: "accepted" }), PublicationPrivacyAuditError);
    assert.throws(() => audit.record({ action: "publication.portal.asset", result: canary as never }), PublicationPrivacyAuditError);
    assert.throws(() => audit.record({ action: "publication.portal.asset", result: "delivered", bytes: canary as never }), PublicationPrivacyAuditError);
  }
  assert.deepEqual(findCanaryLeaks(sink.events, canaries), []);
  assert.deepEqual(findCanaryLeaks([{ unsafe: canaries[0] }], canaries), ["$[0].unsafe"], "positive control proves the leak probe is live");
});
