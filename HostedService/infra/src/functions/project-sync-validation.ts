import { S3Client } from "@aws-sdk/client-s3";

import {
  ProjectSyncObjectAdapter,
} from "roomscan-studio-hosted-service/adapters";
import {
  DataApiProjectSyncWorkerStore,
} from "roomscan-studio-hosted-service/persistence";
import {
  ProjectSyncValidationWorker,
} from "roomscan-studio-hosted-service/sync";

import { AwsProjectSyncObjectProvider } from "../aws/project-sync-object-provider.js";
import { PROJECT_SYNC_VALIDATION_WAKE_BODY } from "../aws/project-sync-wake.js";
import {
  LambdaRuntimeConfigurationError,
  lazyHandler,
  roleBoundDataApiClient,
  systemClock,
} from "./runtime-support.js";

export interface ProjectSyncSqsRecord {
  readonly messageId: string;
  readonly body?: string;
}

export interface ProjectSyncSqsEvent {
  readonly Records?: readonly ProjectSyncSqsRecord[];
}

export interface ProjectSyncSqsResponse {
  readonly batchItemFailures: readonly Readonly<{ readonly itemIdentifier: string }>[];
}

type Worker = Pick<ProjectSyncValidationWorker, "runOnce">;
type WorkerDataClient = ConstructorParameters<typeof DataApiProjectSyncWorkerStore>[0]["client"];
// EventBridge requires its target Input to be valid JSON. Its direct SQS
// target therefore carries this JSON-encoded scalar, while API-originated
// wakes carry the same canonical scalar unencoded.
const EVENTBRIDGE_ENCODED_WAKE_BODY = `"${PROJECT_SYNC_VALIDATION_WAKE_BODY}"`;

export interface ProjectSyncValidationRootDependencies {
  readonly dataClient?: () => WorkerDataClient;
  readonly worker?: (input: Readonly<{
    readonly client: WorkerDataClient;
    readonly bucketName: string;
  }>) => Worker;
}

const validation = lazyHandler(async () => createProjectSyncValidationRoot());

/** A generic queue wake cannot name a project, upload, object key, version,
 * raw archive, or candidate head. The database worker claim is the only
 * selector and all malformed/non-fixed queue messages fail closed. */
export async function handler(event: ProjectSyncSqsEvent): Promise<ProjectSyncSqsResponse> {
  try {
    return await validation(event);
  } catch {
    return batchFailures(event);
  }
}

export async function createProjectSyncValidationRoot(
  environment: NodeJS.ProcessEnv = process.env,
  dependencies: ProjectSyncValidationRootDependencies = {},
): Promise<(event: ProjectSyncSqsEvent) => Promise<ProjectSyncSqsResponse>> {
  const bucketName = requiredBucketName(environment, "PROJECT_SYNC_BUCKET_NAME");
  if (requiredEnvironment(environment, "ROOMSCAN_DB_RUNTIME_ROLE") !== "roomscan_project_sync_runtime") {
    throw invalidConfiguration();
  }
  const client = dependencies.dataClient?.() ?? roleBoundDataApiClient("roomscan_project_sync_runtime");
  const worker = dependencies.worker?.({ client, bucketName }) ?? new ProjectSyncValidationWorker({
    clock: Object.freeze({ now: () => new Date(systemClock.nowMs()) }),
    store: new DataApiProjectSyncWorkerStore({ client }),
    objects: new ProjectSyncObjectAdapter(new AwsProjectSyncObjectProvider({
      sender: new S3Client({ region: "us-east-1" }),
      bucketName,
    })),
  });
  if (worker === null || typeof worker !== "object" || typeof worker.runOnce !== "function") {
    throw invalidConfiguration();
  }
  return async (event) => {
    const failures: Array<Readonly<{ readonly itemIdentifier: string }>> = [];
    for (const record of records(event)) {
      if (!isFixedTargetlessWake(record.body)) {
        // Do not silently acknowledge a valid SQS record with an unexpected
        // body: preserving it through redrive/DLQ makes operator diagnosis
        // possible without ever allowing payload data to select work.
        failures.push(Object.freeze({ itemIdentifier: record.messageId }));
        continue;
      }
      try {
        const outcome = await worker.runOnce();
        if (outcome.status === "retry") failures.push(Object.freeze({ itemIdentifier: record.messageId }));
      } catch {
        failures.push(Object.freeze({ itemIdentifier: record.messageId }));
      }
    }
    return Object.freeze({ batchItemFailures: Object.freeze(failures) });
  };
}

function isFixedTargetlessWake(body: string | undefined): boolean {
  return body === PROJECT_SYNC_VALIDATION_WAKE_BODY || body === EVENTBRIDGE_ENCODED_WAKE_BODY;
}

function batchFailures(event: ProjectSyncSqsEvent): ProjectSyncSqsResponse {
  return Object.freeze({
    batchItemFailures: Object.freeze(records(event).map((record) => Object.freeze({ itemIdentifier: record.messageId }))),
  });
}

function records(event: ProjectSyncSqsEvent): readonly ProjectSyncSqsRecord[] {
  if (event === null || typeof event !== "object" || !Array.isArray(event.Records)) return [];
  return event.Records.filter((record): record is ProjectSyncSqsRecord =>
    record !== null && typeof record === "object"
    && typeof record.messageId === "string"
    && /^[A-Za-z0-9._:-]{1,128}$/u.test(record.messageId)
    && (record.body === undefined || typeof record.body === "string"),
  );
}

function requiredEnvironment(environment: NodeJS.ProcessEnv, name: string): string {
  const value = environment[name];
  if (typeof value !== "string" || value.length === 0 || value.length > 640 || value !== value.trim()) {
    throw new LambdaRuntimeConfigurationError("missing_configuration");
  }
  return value;
}

function requiredBucketName(environment: NodeJS.ProcessEnv, name: string): string {
  const value = requiredEnvironment(environment, name);
  if (!/^[a-z0-9](?:[a-z0-9.-]{1,61})[a-z0-9]$/u.test(value) || value.includes("..") || /^\d+\.\d+\.\d+\.\d+$/u.test(value)) {
    throw invalidConfiguration();
  }
  return value;
}

function invalidConfiguration(): LambdaRuntimeConfigurationError {
  return new LambdaRuntimeConfigurationError("invalid_configuration");
}
