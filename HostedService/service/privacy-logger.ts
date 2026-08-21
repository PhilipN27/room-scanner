import { createHmac, timingSafeEqual } from "node:crypto";

export interface RandomSource {
  bytes(length: number): Uint8Array;
}

export interface StructuredLogEvent {
  readonly eventCode: string;
  readonly correlationId?: string;
  readonly requestId?: string;
  readonly principalId?: string;
  readonly workspaceId?: string;
  readonly result?: string;
  readonly durationMs?: number;
  readonly counters?: Readonly<Record<string, number>>;
}

export interface StructuredLogSink {
  write(event: StructuredLogEvent): void;
}

export interface SafeLogFields {
  readonly correlationId?: string;
  readonly requestId?: string;
  readonly principalId?: string;
  readonly workspaceId?: string;
  readonly result?: string;
  readonly durationMs?: number;
  readonly counters?: Readonly<Record<string, number>>;
}

export class UnsafeLogEventError extends Error {
  constructor() {
    super("unsafe_log_event");
    this.name = "UnsafeLogEventError";
  }
}

export class PrivacyLogger {
  constructor(
    private readonly dependencies: {
      readonly sink: StructuredLogSink;
      readonly random: RandomSource;
      readonly pseudonymHmacKey: Uint8Array;
      readonly identifierHmacKey: Uint8Array;
      readonly allowedEventCodes: ReadonlySet<string>;
      readonly allowedResults: ReadonlySet<string>;
    },
  ) {}

  createCorrelationId(): string {
    return createSignedIdentifier(
      "corr_",
      "correlation",
      this.dependencies.random,
      this.dependencies.identifierHmacKey,
    );
  }

  createRequestId(): string {
    return createSignedIdentifier(
      "req_",
      "request",
      this.dependencies.random,
      this.dependencies.identifierHmacKey,
    );
  }

  emit(eventCode: string, fields: SafeLogFields = {}): StructuredLogEvent {
    const rawFields = fields as Readonly<Record<string, unknown>>;
    if (
      !isEventCode(eventCode) ||
      isSensitiveString(eventCode) ||
      !this.dependencies.allowedEventCodes.has(eventCode) ||
      Object.getOwnPropertySymbols(rawFields).length > 0 ||
      Object.keys(rawFields).some((key) => !ALLOWED_FIELDS.has(key))
    ) {
      throw new UnsafeLogEventError();
    }

    const correlationId = optionalSignedIdentifier(
      rawFields.correlationId,
      "corr_",
      "correlation",
      this.dependencies.identifierHmacKey,
    );
    const requestId = optionalSignedIdentifier(
      rawFields.requestId,
      "req_",
      "request",
      this.dependencies.identifierHmacKey,
    );
    const principalId = optionalPseudonym(
      rawFields.principalId,
      "principal",
      "p_",
      this.dependencies.pseudonymHmacKey,
    );
    const workspaceId = optionalPseudonym(
      rawFields.workspaceId,
      "workspace",
      "w_",
      this.dependencies.pseudonymHmacKey,
    );
    const result = optionalResult(rawFields.result, this.dependencies.allowedResults);
    const durationMs = optionalDuration(rawFields.durationMs);
    const counters = optionalCounters(rawFields.counters);
    const event: StructuredLogEvent = {
      eventCode,
      ...(correlationId === undefined ? {} : { correlationId }),
      ...(requestId === undefined ? {} : { requestId }),
      ...(principalId === undefined ? {} : { principalId }),
      ...(workspaceId === undefined ? {} : { workspaceId }),
      ...(result === undefined ? {} : { result }),
      ...(durationMs === undefined ? {} : { durationMs }),
      ...(counters === undefined ? {} : { counters }),
    };
    this.dependencies.sink.write(event);
    return event;
  }

  tryEmit(eventCode: string, fields: SafeLogFields = {}): boolean {
    try {
      this.emit(eventCode, fields);
      return true;
    } catch (error) {
      if (error instanceof UnsafeLogEventError) {
        return false;
      }
      throw error;
    }
  }
}

export function findCanaryLeaks(
  values: unknown,
  canaries: readonly string[],
): string[] {
  const nonemptyCanaries = canaries.filter((canary) => canary.length > 0);
  const leaks: string[] = [];
  const visited = new WeakSet<object>();
  const visit = (value: unknown, path: string): void => {
    if (typeof value === "string") {
      if (nonemptyCanaries.some((canary) => value.includes(canary))) {
        leaks.push(path);
      }
      return;
    }
    if (ArrayBuffer.isView(value)) {
      const bytes = Buffer.from(value.buffer, value.byteOffset, value.byteLength);
      if (nonemptyCanaries.some((canary) => bytes.toString("utf8").includes(canary))) {
        leaks.push(path);
      }
      return;
    }
    if (typeof value !== "object" || value === null || visited.has(value)) {
      return;
    }
    visited.add(value);
    if (Array.isArray(value)) {
      value.forEach((item, index) => visit(item, `${path}[${index}]`));
      return;
    }
    for (const [key, item] of Object.entries(value)) {
      visit(item, `${path}.${key}`);
    }
  };
  visit(values, "$");
  return leaks;
}

const ALLOWED_FIELDS = new Set([
  "correlationId",
  "requestId",
  "principalId",
  "workspaceId",
  "result",
  "durationMs",
  "counters",
]);

function isEventCode(value: string): boolean {
  return value.length <= 80 && /^[a-z][a-z0-9]*(?:[._][a-z0-9]+)*$/u.test(value);
}

function createSignedIdentifier(
  prefix: "corr_" | "req_",
  domain: "correlation" | "request",
  random: RandomSource,
  key: Uint8Array,
): string {
  const payload = Buffer.from(random.bytes(16)).toString("base64url");
  const tag = identifierTag(domain, payload, key).toString("base64url");
  return `${prefix}${payload}.${tag}`;
}

function optionalSignedIdentifier(
  value: unknown,
  prefix: "corr_" | "req_",
  domain: "correlation" | "request",
  key: Uint8Array,
): string | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (typeof value !== "string" || value.length > 64) {
    throw new UnsafeLogEventError();
  }
  const match = new RegExp(`^${prefix}([A-Za-z0-9_-]{22})\\.([A-Za-z0-9_-]{22})$`, "u").exec(value);
  if (match === null) throw new UnsafeLogEventError();
  const payload = match[1];
  const encodedTag = match[2];
  if (payload === undefined || encodedTag === undefined) throw new UnsafeLogEventError();
  const suppliedTag = Buffer.from(encodedTag, "base64url");
  const expectedTag = identifierTag(domain, payload, key);
  if (suppliedTag.length !== expectedTag.length || !timingSafeEqual(suppliedTag, expectedTag)) {
    throw new UnsafeLogEventError();
  }
  return value;
}

function identifierTag(
  domain: "correlation" | "request",
  payload: string,
  key: Uint8Array,
): Buffer {
  return createHmac("sha256", key)
    .update(`log-${domain}-id:${payload}`)
    .digest()
    .subarray(0, 16);
}

function optionalPseudonym(
  value: unknown,
  domain: "principal" | "workspace",
  prefix: "p_" | "w_",
  key: Uint8Array,
): string | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (typeof value !== "string" || value.length === 0 || value.length > 256) {
    throw new UnsafeLogEventError();
  }
  return `${prefix}${createHmac("sha256", key).update(`${domain}:${value}`).digest("base64url")}`;
}

function optionalResult(value: unknown, allowedResults: ReadonlySet<string>): string | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (
    typeof value !== "string" ||
    !/^[a-z][a-z0-9_]{0,31}$/u.test(value) ||
    isSensitiveString(value) ||
    !allowedResults.has(value)
  ) {
    throw new UnsafeLogEventError();
  }
  return value;
}

function optionalDuration(value: unknown): number | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (!Number.isSafeInteger(value) || (value as number) < 0 || (value as number) > 86_400_000) {
    throw new UnsafeLogEventError();
  }
  return value as number;
}

function optionalCounters(value: unknown): Readonly<Record<string, number>> | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (!isPlainRecord(value)) {
    throw new UnsafeLogEventError();
  }
  const entries = Object.entries(value);
  if (entries.length > 16) {
    throw new UnsafeLogEventError();
  }
  const counters: Record<string, number> = {};
  for (const [key, count] of entries) {
    if (
      !/^[a-z][a-z0-9_]{0,31}$/u.test(key) ||
      isSensitiveString(key) ||
      !Number.isSafeInteger(count) ||
      (count as number) < 0
    ) {
      throw new UnsafeLogEventError();
    }
    counters[key] = count as number;
  }
  return counters;
}

function isPlainRecord(value: unknown): value is Readonly<Record<string, unknown>> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return false;
  }
  const prototype = Object.getPrototypeOf(value) as unknown;
  return prototype === Object.prototype || prototype === null;
}

function isSensitiveString(value: string): boolean {
  return (
    /canary/iu.test(value) ||
    /https?:\/\//iu.test(value) ||
    /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/iu.test(value) ||
    /^eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/u.test(value) ||
    /^[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{32,}$/u.test(value) ||
    /^-?\d{1,3}(?:\.\d+)?,\s*-?\d{1,3}(?:\.\d+)?$/u.test(value) ||
    /(?:x-amz-|stripe|whsec_|biometric|face[_-]?template|room[_-]?bytes)/iu.test(value) ||
    /^[A-Za-z0-9+/_-]{40,}={0,2}$/u.test(value)
  );
}
