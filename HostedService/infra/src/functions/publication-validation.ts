import { RDSDataClient } from "@aws-sdk/client-rds-data";
import { S3Client } from "@aws-sdk/client-s3";
import { PublicationObjectAdapter } from "roomscan-studio-hosted-service/adapters";
import { createSlice6PublicationWorker } from "roomscan-studio-hosted-service/composition";

import { AwsPublicationObjectProvider } from "../aws/publication-object-provider.js";
import { AwsDataApiClient } from "../aws/runtime-clients.js";
import {
  LambdaRuntimeConfigurationError,
  lazyHandler,
  systemClock,
} from "./runtime-support.js";

export const PUBLICATION_VALIDATION_WAKE_KIND = "publication-validation-wake-v1" as const;
export const PUBLICATION_VALIDATION_RECOVERY_BODY = "roomscan-publication-validation-wake-v1" as const;
const API_WAKE_BODY = JSON.stringify({ kind: PUBLICATION_VALIDATION_WAKE_KIND });
const EVENTBRIDGE_ENCODED_BODY = JSON.stringify(PUBLICATION_VALIDATION_RECOVERY_BODY);

export interface PublicationValidationRecord {
  readonly messageId: string;
  readonly body?: string;
}
export interface PublicationValidationEvent { readonly Records?: readonly PublicationValidationRecord[]; }
export interface PublicationValidationResponse {
  readonly batchItemFailures: readonly Readonly<{ readonly itemIdentifier: string }>[];
}

type Worker = ReturnType<typeof createSlice6PublicationWorker>;
type DataApiClient = Parameters<typeof createSlice6PublicationWorker>[0]["client"];

export interface PublicationValidationRootDependencies {
  readonly dataClient?: () => DataApiClient;
  readonly worker?: (input: Readonly<{ readonly client: DataApiClient; readonly bucketName: string }>) => Pick<Worker, "runOnce">;
}

const validation = lazyHandler(async () => createPublicationValidationRoot());

export async function handler(event: PublicationValidationEvent): Promise<PublicationValidationResponse> {
  try { return await validation(event); } catch { return allFailures(event); }
}

/** Queue bodies are fixed wakes only. The worker's PostgreSQL claim is the
 * sole selector for allocation, tenant, object version, and retry state. */
export async function createPublicationValidationRoot(
  environment: NodeJS.ProcessEnv = process.env,
  dependencies: PublicationValidationRootDependencies = {},
): Promise<(event: PublicationValidationEvent) => Promise<PublicationValidationResponse>> {
  const config = laneConfiguration(environment);
  const bucketName = requiredBucketName(environment, "PUBLISHED_BUCKET_NAME");
  const client = dependencies.dataClient?.() ?? new AwsDataApiClient({
    sender: new RDSDataClient({ region: "us-east-1" }),
    resourceArn: config.clusterArn,
    secretArn: config.roleSecretArn,
    database: "roomscan",
  });
  const worker = dependencies.worker?.({ client, bucketName }) ?? createSlice6PublicationWorker({
    client,
    clock: Object.freeze({ now: () => new Date(systemClock.nowMs()) }),
    storage: new PublicationObjectAdapter(new AwsPublicationObjectProvider({
      sender: new S3Client({ region: "us-east-1" }),
      bucketName,
    })),
  });
  if (worker === null || typeof worker !== "object" || typeof worker.runOnce !== "function") throw invalidConfiguration();
  return async (event) => {
    const failures: Array<Readonly<{ readonly itemIdentifier: string }>> = [];
    for (const record of records(event)) {
      if (!fixedWake(record.body)) {
        failures.push(Object.freeze({ itemIdentifier: record.messageId }));
        continue;
      }
      try {
        const outcome = await worker.runOnce();
        if (outcome.status === "retry") failures.push(Object.freeze({ itemIdentifier: record.messageId }));
      } catch { failures.push(Object.freeze({ itemIdentifier: record.messageId })); }
    }
    return Object.freeze({ batchItemFailures: Object.freeze(failures) });
  };
}

function fixedWake(body: string | undefined): boolean {
  return body === API_WAKE_BODY || body === PUBLICATION_VALIDATION_RECOVERY_BODY || body === EVENTBRIDGE_ENCODED_BODY;
}

function allFailures(event: PublicationValidationEvent): PublicationValidationResponse {
  return Object.freeze({
    batchItemFailures: Object.freeze(records(event).map((record) => Object.freeze({ itemIdentifier: record.messageId }))),
  });
}

function records(event: PublicationValidationEvent): readonly PublicationValidationRecord[] {
  if (event === null || typeof event !== "object" || !Array.isArray(event.Records)) return [];
  return event.Records.filter((record): record is PublicationValidationRecord =>
    record !== null && typeof record === "object"
      && typeof record.messageId === "string" && /^[A-Za-z0-9._:-]{1,128}$/u.test(record.messageId)
      && (record.body === undefined || typeof record.body === "string"));
}

function laneConfiguration(environment: NodeJS.ProcessEnv): Readonly<{ readonly clusterArn: string; readonly roleSecretArn: string }> {
  requiredIdentifier(environment, "ROOMSCAN_STAGE", 3, 10, /^(?:dev|staging|production)$/u);
  if (requiredIdentifier(environment, "ROOMSCAN_REGION", 9, 9, /^[a-z0-9-]+$/u) !== "us-east-1") throw invalidConfiguration();
  const clusterArn = requiredIdentifier(environment, "DB_CLUSTER_ARN", 1, 256, /^arn:aws:rds:us-east-1:\d{12}:cluster:[A-Za-z0-9-]{1,63}$/u);
  const roleSecretArn = requiredIdentifier(environment, "ROOMSCAN_DB_ROLE_SECRET_ARN", 1, 640, /^arn:aws:secretsmanager:us-east-1:\d{12}:secret:[A-Za-z0-9/_+=.@-]{1,512}$/u);
  if (requiredIdentifier(environment, "ROOMSCAN_DB_RUNTIME_ROLE", 3, 64, /^[a-z][a-z0-9_]+$/u) !== "roomscan_publication_worker") throw invalidConfiguration();
  return Object.freeze({ clusterArn, roleSecretArn });
}

function requiredBucketName(environment: NodeJS.ProcessEnv, name: string): string {
  const value = requiredIdentifier(environment, name, 3, 63, /^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/u);
  if (value.includes("..") || /^\d+\.\d+\.\d+\.\d+$/u.test(value)) throw invalidConfiguration();
  return value;
}

function requiredIdentifier(environment: NodeJS.ProcessEnv, name: string, minimum: number, maximum: number, pattern: RegExp): string {
  const value = environment[name];
  if (value === undefined || value.length === 0) throw new LambdaRuntimeConfigurationError("missing_configuration");
  if (value.length < minimum || value.length > maximum || value !== value.trim() || !pattern.test(value)) throw invalidConfiguration();
  return value;
}

function invalidConfiguration(): LambdaRuntimeConfigurationError {
  return new LambdaRuntimeConfigurationError("invalid_configuration");
}
