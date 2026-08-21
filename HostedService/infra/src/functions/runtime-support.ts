import { createHmac, randomBytes } from "node:crypto";

import { RDSDataClient } from "@aws-sdk/client-rds-data";
import { SecretsManagerClient } from "@aws-sdk/client-secrets-manager";

import {
  AwsDataApiClient,
  AwsSecretValuePort,
  type DataApiClientPort,
  type SecretValuePort,
} from "../aws/runtime-clients.js";

export const REGION = "us-east-1" as const;
export const DATABASE = "roomscan" as const;

export class LambdaRuntimeConfigurationError extends Error {
  constructor(readonly code: "missing_configuration" | "invalid_configuration") {
    super(code);
    this.name = "LambdaRuntimeConfigurationError";
  }
}

export function roleBoundDataApiClient(expectedRole: string): DataApiClientPort {
  const actualRole = requiredEnvironment("ROOMSCAN_DB_RUNTIME_ROLE", /^[a-z][a-z0-9_]{2,63}$/u, 64);
  if (actualRole !== expectedRole) throw new LambdaRuntimeConfigurationError("invalid_configuration");
  return new AwsDataApiClient({
    sender: new RDSDataClient({ region: REGION }),
    resourceArn: requiredEnvironment(
      "DB_CLUSTER_ARN",
      /^arn:aws:rds:us-east-1:\d{12}:cluster:[A-Za-z0-9-]{1,63}$/u,
      256,
    ),
    secretArn: requiredEnvironment(
      "ROOMSCAN_DB_ROLE_SECRET_ARN",
      /^arn:aws:secretsmanager:us-east-1:\d{12}:secret:[A-Za-z0-9/_+=.@-]{1,512}$/u,
      640,
    ),
    database: DATABASE,
  });
}

export function secretValuePort(secretArn: string, jsonField: string): SecretValuePort {
  return new AwsSecretValuePort({
    sender: new SecretsManagerClient({ region: REGION }),
    secretArn,
    jsonField,
  });
}

export async function readSecretValue(secretArn: string, jsonField: string): Promise<string> {
  return secretValuePort(secretArn, jsonField).read(secretArn);
}

export function requiredSecretArn(name: string): string {
  return requiredEnvironment(
    name,
    /^arn:aws:secretsmanager:us-east-1:\d{12}:secret:[A-Za-z0-9/_+=.@-]{1,512}$/u,
    640,
  );
}

export function requiredEnvironment(name: string, pattern: RegExp, maximum: number): string {
  const value = process.env[name];
  if (value === undefined || value.length === 0) {
    throw new LambdaRuntimeConfigurationError("missing_configuration");
  }
  if (value.length > maximum || value !== value.trim() || !pattern.test(value)) {
    throw new LambdaRuntimeConfigurationError("invalid_configuration");
  }
  return value;
}

export function requiredInteger(name: string, minimum: number, maximum: number): number {
  const value = requiredEnvironment(name, /^(?:0|[1-9][0-9]{0,15})$/u, 16);
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < minimum || parsed > maximum) {
    throw new LambdaRuntimeConfigurationError("invalid_configuration");
  }
  return parsed;
}

/** Every application key stays purpose-specific even when a generated root is
 * shared by the two exact runtimes that must interoperate. */
export function deriveKey(root: string, purpose: string): Uint8Array {
  if (root.length < 32 || root.length > 4_096 || !/^[\x21-\x7e]+$/u.test(root)
    || !/^[a-z0-9.-]{3,128}$/u.test(purpose)) {
    throw new LambdaRuntimeConfigurationError("invalid_configuration");
  }
  return Uint8Array.from(createHmac("sha256", Buffer.from(root, "utf8"))
    .update(`roomscan.slice4.key.v1\u0000${purpose}`)
    .digest());
}

export const systemClock = Object.freeze({ nowMs: (): number => Date.now() });
export const systemRandom = Object.freeze({ bytes: (length: number): Uint8Array => {
  if (!Number.isSafeInteger(length) || length < 1 || length > 4_096) {
    throw new LambdaRuntimeConfigurationError("invalid_configuration");
  }
  return Uint8Array.from(randomBytes(length));
} });

/**
 * Temporary commercial-policy gate. It deliberately receives the root's
 * environment rather than reading process state, so a staged runtime cannot
 * accidentally inherit a developer machine's approval marker.
 */
export function localPolicyValuesEnabled(environment: NodeJS.ProcessEnv): void {
  const stage = environment.ROOMSCAN_STAGE;
  const status = environment.ROOMSCAN_POLICY_VALUES_STATUS;
  if (stage === undefined || stage.length === 0 || status === undefined || status.length === 0) {
    throw new LambdaRuntimeConfigurationError("missing_configuration");
  }
  if (stage !== "dev" || status !== "local-test-values-v1") {
    // Staging/production synthesize so operators can review the template, but
    // runtime remains disabled until the owner supplies measured values.
    throw new LambdaRuntimeConfigurationError("invalid_configuration");
  }
}

export function parseExactJsonArray<T>(name: string, validate: (value: unknown) => value is T): readonly T[] {
  const source = requiredEnvironment(name, /^\[[\s\S]*\]$/u, 16_384);
  let parsed: unknown;
  try { parsed = JSON.parse(source) as unknown; } catch {
    throw new LambdaRuntimeConfigurationError("invalid_configuration");
  }
  if (!Array.isArray(parsed) || parsed.length < 1 || parsed.length > 64 || !parsed.every(validate)) {
    throw new LambdaRuntimeConfigurationError("invalid_configuration");
  }
  return Object.freeze([...parsed]);
}

export function lazyHandler<Event, Result>(
  initialize: () => Promise<(event: Event) => Promise<Result>>,
): (event: Event) => Promise<Result> {
  let ready: ((event: Event) => Promise<Result>) | undefined;
  let initializing: Promise<(event: Event) => Promise<Result>> | undefined;
  return async (event) => {
    if (ready === undefined) {
      initializing ??= initialize();
      try { ready = await initializing; } finally {
        if (ready === undefined) initializing = undefined;
      }
    }
    return ready(event);
  };
}
