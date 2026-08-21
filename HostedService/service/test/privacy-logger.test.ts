import assert from "node:assert/strict";
import { test } from "node:test";

import {
  PrivacyLogger,
  UnsafeLogEventError,
  findCanaryLeaks,
  type StructuredLogEvent,
  type StructuredLogSink,
} from "../privacy-logger.js";

class MemorySink implements StructuredLogSink {
  readonly events: StructuredLogEvent[] = [];
  write(event: StructuredLogEvent): void { this.events.push(structuredClone(event)); }
}

class SequenceRandom {
  private next = 1;
  bytes(length: number): Uint8Array {
    const value = this.next++;
    return Uint8Array.from({ length }, (_, index) => value + index);
  }
}

const ALLOWED_EVENTS = new Set(["auth.session.authorized", "auth.rejected", "auth.safe"]);
const ALLOWED_RESULTS = new Set(["allowed", "rejected", "dropped"]);

function makeHarness(extra?: { events?: readonly string[]; results?: readonly string[] }): {
  readonly logger: PrivacyLogger;
  readonly sink: MemorySink;
} {
  const sink = new MemorySink();
  return {
    sink,
    logger: new PrivacyLogger({
      sink,
      random: new SequenceRandom(),
      pseudonymHmacKey: Buffer.alloc(32, 0x71),
      identifierHmacKey: Buffer.alloc(32, 0x72),
      allowedEventCodes: new Set([...ALLOWED_EVENTS, ...(extra?.events ?? [])]),
      allowedResults: new Set([...ALLOWED_RESULTS, ...(extra?.results ?? [])]),
    }),
  };
}

const CANARIES = [
  Buffer.alloc(32, 0xa1).toString("base64url"),
  Buffer.alloc(32, 0xb2).toString("base64url"),
  `${Buffer.alloc(16, 0xc3).toString("base64url")}.${Buffer.alloc(32, 0xc4).toString("base64url")}`,
  "eyJhbGciOiJSUzI1NiIsImtpZCI6ImNhbmFyeSJ9.eyJzdWIiOiJwcm92aWRlci1jYW5hcnkifQ.c2lnbmF0dXJlLWNhbmFyeQ",
  "https://storage.example/room?X-Amz-Credential=PRESIGNED_CANARY&X-Amz-Signature=deadbeef",
  "person+EMAIL_CANARY@example.com",
  "51.501000,-0.141000",
  "biometric_face_template_CANARY",
  "t=1723975200,v1=STRIPE_SIGNATURE_CANARY",
  Buffer.from("ROOM_BYTES_CANARY\0binary-room-payload").toString("base64"),
] as const;

test("only server-generated signed request/correlation IDs and configured event/result codes reach the sink", () => {
  const harness = makeHarness();
  const correlationId = harness.logger.createCorrelationId();
  const requestId = harness.logger.createRequestId();
  const event = harness.logger.emit("auth.session.authorized", {
    correlationId,
    requestId,
    principalId: "principal-secret",
    workspaceId: "principal-secret",
    result: "allowed",
    durationMs: 12,
    counters: { attempts: 1, memberships_checked: 2 },
  });
  assert.deepEqual(event, harness.sink.events[0]);
  assert.match(event.correlationId ?? "", /^corr_[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{22}$/u);
  assert.match(event.requestId ?? "", /^req_[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{22}$/u);
  assert.match(event.principalId ?? "", /^p_[A-Za-z0-9_-]{43}$/u);
  assert.match(event.workspaceId ?? "", /^w_[A-Za-z0-9_-]{43}$/u);
  assert.notEqual(event.principalId, event.workspaceId);
  assert.equal(JSON.stringify(event).includes("principal-secret"), false);

  assert.throws(() => harness.logger.emit("auth.not_configured"), UnsafeLogEventError);
  assert.throws(() => harness.logger.emit("auth.safe", { result: "not_configured" }), UnsafeLogEventError);
  assert.throws(() => harness.logger.emit("auth.safe", { correlationId: "corr_forged" }), UnsafeLogEventError);
  assert.throws(() => harness.logger.emit("auth.safe", { requestId: "req_forged" }), UnsafeLogEventError);
});

test("every allowed raw string channel rejects every access, refresh, magic, provider, URL, email, GPS, biometric, Stripe, and room canary", () => {
  for (const [index, canary] of CANARIES.entries()) {
    const harness = makeHarness();
    const correlationId = harness.logger.createCorrelationId();
    const requestId = harness.logger.createRequestId();
    const attempts: Array<() => boolean> = [
      () => harness.logger.tryEmit(canary, {}),
      () => harness.logger.tryEmit("auth.safe", { correlationId: canary }),
      () => harness.logger.tryEmit("auth.safe", { requestId: canary }),
      () => harness.logger.tryEmit("auth.safe", { result: canary }),
      () => harness.logger.tryEmit("auth.safe", { counters: { [canary]: 1 } }),
    ];
    assert.deepEqual(attempts.map((attempt) => attempt()), [false, false, false, false, false], `canary ${index}`);

    harness.logger.emit("auth.safe", {
      correlationId,
      requestId,
      principalId: canary,
      workspaceId: canary,
      result: "rejected",
    });
    assert.deepEqual(findCanaryLeaks(harness.sink.events, [canary]), []);
  }
});

test("content screening still rejects canary-shaped values even when configuration mistakenly allowlists them", () => {
  const harness = makeHarness({
    events: ["auth.room_bytes_canary"],
    results: ["room_bytes_canary"],
  });
  assert.equal(harness.logger.tryEmit("auth.room_bytes_canary"), false);
  assert.equal(harness.logger.tryEmit("auth.safe", { result: "room_bytes_canary" }), false);
  assert.equal(harness.sink.events.length, 0);
});

test("unknown fields, free text, malformed numbers, and unbounded counters fail closed without echoing input", () => {
  const harness = makeHarness();
  const invalid: Array<{ eventCode: string; fields: Record<string, unknown> }> = [
    { eventCode: "auth.safe", fields: { message: "FREE_TEXT_CANARY" } },
    { eventCode: "auth.safe", fields: { durationMs: -1 } },
    { eventCode: "auth.safe", fields: { counters: { attempts: Number.POSITIVE_INFINITY } } },
    { eventCode: "auth.safe", fields: { counters: Object.fromEntries(Array.from({ length: 17 }, (_, index) => [`counter_${index}`, index])) } },
  ];
  for (const input of invalid) {
    let caught: unknown;
    try { harness.logger.emit(input.eventCode, input.fields as never); } catch (error) { caught = error; }
    assert.ok(caught instanceof UnsafeLogEventError);
    assert.equal(caught.message, "unsafe_log_event");
    assert.equal(caught.message.includes("CANARY"), false);
  }
  assert.equal(harness.sink.events.length, 0);
});

test("canary scanner positive control detects every intentionally unsafe fixture value", () => {
  const unsafeFixture = CANARIES.map((canary, index) => ({ index, nested: { value: canary } }));
  const leaks = findCanaryLeaks(unsafeFixture, CANARIES);
  assert.equal(leaks.length, CANARIES.length);
  assert.deepEqual(leaks, CANARIES.map((_, index) => `$[${index}].nested.value`));

  const harness = makeHarness();
  harness.logger.emit("auth.safe", {
    correlationId: harness.logger.createCorrelationId(),
    principalId: CANARIES[0],
    result: "allowed",
  });
  assert.deepEqual(findCanaryLeaks(harness.sink.events, CANARIES), []);
});
