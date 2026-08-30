import type {
  ProjectSyncMigrationAllocateInput,
  ProjectSyncRawArchiveAllocateInput,
  ProjectSyncRawArchiveConfigureInput,
  ProjectSyncRevisionAllocateInput,
} from "../contracts/project-sync.js";
import type { HttpApiV2Response } from "../http/http-api-v2.js";
import {
  createSlice5HandlerEntrypoint,
  createSlice5PostCommitResult,
  requireSlice5PostCommitEffect,
  type AuthorizedOperationContext,
  type ApiGatewayV2Request,
  type Slice4HandlerDependencies,
  type Slice5HandlerDependencies,
  type Slice5PostCommitResult,
  type Slice5RouteHandler,
  type Slice5SameTransactionOperationPort,
} from "../handlers/factory.js";
import {
  requireProjectSyncRepositories,
  DataApiProjectSyncOperationPort,
  type ProjectSyncValidationWakePort,
  type ProjectSyncPreparedResponse,
} from "../persistence/project-sync-capabilities.js";
import type { DataApiClient } from "../adapters/data-api.js";
import { ProjectSyncObjectAdapter } from "../adapters/s3-project-sync.js";

export class ProjectSyncRouteApplicationError extends Error {
  constructor(readonly code: "invalid_composition" | "invalid_request") {
    super(code);
    this.name = "ProjectSyncRouteApplicationError";
  }
}

export interface Slice5ProjectSyncApplicationDependencies {
  readonly legacy: Slice4HandlerDependencies;
  readonly operations: Slice5SameTransactionOperationPort;
}

/** Concrete API-role composition. Infrastructure supplies a role-bound Data
 * API client plus narrow storage/wake adapters; it cannot inject a route,
 * SQL capability, provider credential, worker target, or database role name.
 * The separate Slice 4 handler bundle remains the only implementation of its
 * legacy routes. */
export interface Slice5DataApiProjectSyncApplicationDependencies {
  readonly legacy: Slice4HandlerDependencies;
  readonly apiClient: DataApiClient;
  readonly clock: { now(): Date };
  readonly accessTokenHmacKey: Uint8Array;
  readonly leaseHmacKey: Uint8Array;
  readonly storage: ProjectSyncObjectAdapter;
  readonly validationWake: ProjectSyncValidationWakePort;
}

/** Builds only the ten Slice 5 route handlers. The outer entrypoint delegates
 * all original routes to `legacy`, so no Slice 4 public/auth/read behavior is
 * reimplemented or changed by project synchronization. */
export function createSlice5ProjectSyncHandler(input: Slice5ProjectSyncApplicationDependencies): (request: ApiGatewayV2Request) => Promise<HttpApiV2Response> {
  if (input === null || typeof input !== "object" || input.legacy === null || typeof input.legacy !== "object"
    || input.operations === null || typeof input.operations !== "object" || typeof input.operations.run !== "function") {
    throw new ProjectSyncRouteApplicationError("invalid_composition");
  }
  const dependencies: Slice5HandlerDependencies = {
    legacy: input.legacy,
    operations: input.operations,
    handlers: Object.freeze({
      "project.migration.allocate": migrationAllocate,
      "project.revision.allocate": revisionAllocate,
      "project.upload.complete": uploadComplete,
      "project.upload.status": uploadStatus,
      "project.recovery.allocate": recoveryAllocate,
      "project.edit-lease.acquire": leaseAcquire,
      "project.edit-lease.renew": leaseRenew,
      "project.edit-lease.release": leaseRelease,
      "project.raw-archive.configure": rawConfigure,
      "project.raw-archive.allocate": rawAllocate,
    } satisfies Readonly<Record<string, Slice5RouteHandler>>),
  };
  return createSlice5HandlerEntrypoint(dependencies);
}

export function createSlice5DataApiProjectSyncHandler(input: Slice5DataApiProjectSyncApplicationDependencies): (request: ApiGatewayV2Request) => Promise<HttpApiV2Response> {
  if (input === null || typeof input !== "object" || input.legacy === null || typeof input.legacy !== "object"
    || input.apiClient === null || typeof input.apiClient !== "object" || input.clock === null || typeof input.clock !== "object") {
    throw new ProjectSyncRouteApplicationError("invalid_composition");
  }
  return createSlice5ProjectSyncHandler({
    legacy: input.legacy,
    operations: new DataApiProjectSyncOperationPort({
      client: input.apiClient,
      clock: input.clock,
      accessTokenHmacKey: input.accessTokenHmacKey,
      leaseHmacKey: input.leaseHmacKey,
      storage: input.storage,
      validationWake: input.validationWake,
    }),
  });
}

const migrationAllocate: Slice5RouteHandler = async (request, context) => {
  const body = bodyRecord(request); const repository = repositoryFor(context);
  return responseFrom(await repository.allocateMigration({
    sourceProjectID: requiredString(body, "sourceProjectID"), proposedRevisionID: requiredString(body, "proposedRevisionID"),
    workingSetManifestSHA256: requiredString(body, "workingSetManifestSHA256"), archiveSHA256: requiredString(body, "archiveSHA256"), archiveByteCount: requiredInteger(body, "archiveByteCount"),
    idempotencyKey: requiredString(body, "idempotencyKey"), quotaPolicyVersion: requiredInteger(body, "quotaPolicyVersion"), hostedGlobalVersion: requiredInteger(body, "hostedGlobalVersion"), hostedWorkspaceVersion: requiredInteger(body, "hostedWorkspaceVersion"),
  } satisfies ProjectSyncMigrationAllocateInput), allocationBody);
};

const revisionAllocate: Slice5RouteHandler = async (request, context) => {
  const body = bodyRecord(request); const repository = repositoryFor(context);
  return responseFrom(await repository.allocateRevision({
    projectID: requiredString(body, "projectID"), expectedHostedHeadRevisionID: requiredString(body, "expectedHostedHeadRevisionID"), expectedHeadRevisionID: requiredString(body, "expectedHeadRevisionID"), proposedRevisionID: requiredString(body, "proposedRevisionID"),
    workingSetManifestSHA256: requiredString(body, "workingSetManifestSHA256"), archiveSHA256: requiredString(body, "archiveSHA256"), archiveByteCount: requiredInteger(body, "archiveByteCount"),
    idempotencyKey: requiredString(body, "idempotencyKey"), quotaPolicyVersion: requiredInteger(body, "quotaPolicyVersion"), hostedGlobalVersion: requiredInteger(body, "hostedGlobalVersion"), hostedWorkspaceVersion: requiredInteger(body, "hostedWorkspaceVersion"),
  } satisfies ProjectSyncRevisionAllocateInput), allocationBody);
};

const uploadComplete: Slice5RouteHandler = async (request, context) => responseFrom(
  await repositoryFor(context).completeUpload(requiredString(bodyRecord(request), "uploadID")),
  uploadStatusBody,
  202,
);
const uploadStatus: Slice5RouteHandler = async (request, context) => responseFrom(
  await repositoryFor(context).uploadStatus(requiredString(bodyRecord(request), "uploadID")), uploadStatusBody,
);
const recoveryAllocate: Slice5RouteHandler = async (request, context) => {
  const body = bodyRecord(request); const revision = optionalString(body, "revisionID");
  return responseFrom(await repositoryFor(context).allocateRecovery({ projectID: requiredString(body, "projectID"), ...(revision === undefined ? {} : { revisionID: revision }) }), recoveryBody);
};
const leaseAcquire: Slice5RouteHandler = async (request, context) => {
  const body = bodyRecord(request);
  return responseFrom(await repositoryFor(context).acquireLease({ projectID: requiredString(body, "projectID"), deviceID: requiredString(body, "deviceID"), requestID: requiredString(body, "requestID"), leaseToken: requiredString(body, "leaseToken"), hostedGlobalVersion: requiredInteger(body, "hostedGlobalVersion"), hostedWorkspaceVersion: requiredInteger(body, "hostedWorkspaceVersion") }), leaseBody);
};
const leaseRenew: Slice5RouteHandler = async (request, context) => {
  const body = bodyRecord(request);
  return responseFrom(await repositoryFor(context).renewLease({ projectID: requiredString(body, "projectID"), leaseToken: requiredString(body, "leaseToken"), hostedGlobalVersion: requiredInteger(body, "hostedGlobalVersion"), hostedWorkspaceVersion: requiredInteger(body, "hostedWorkspaceVersion") }), leaseBody);
};
const leaseRelease: Slice5RouteHandler = async (request, context) => {
  const body = bodyRecord(request);
  return responseFrom(await repositoryFor(context).releaseLease({ projectID: requiredString(body, "projectID"), leaseToken: requiredString(body, "leaseToken"), hostedGlobalVersion: requiredInteger(body, "hostedGlobalVersion"), hostedWorkspaceVersion: requiredInteger(body, "hostedWorkspaceVersion") }), leaseBody);
};
const rawConfigure: Slice5RouteHandler = async (request, context) => {
  const body = bodyRecord(request);
  return responseFrom(await repositoryFor(context).configureRawArchive({ projectID: requiredString(body, "projectID"), reviewSHA256: requiredString(body, "reviewSHA256"), hostedGlobalVersion: requiredInteger(body, "hostedGlobalVersion"), hostedWorkspaceVersion: requiredInteger(body, "hostedWorkspaceVersion") } satisfies ProjectSyncRawArchiveConfigureInput), rawConfigurationBody);
};
const rawAllocate: Slice5RouteHandler = async (request, context) => {
  const body = bodyRecord(request);
  return responseFrom(await repositoryFor(context).allocateRawArchive({ projectID: requiredString(body, "projectID"), revisionID: requiredString(body, "revisionID"), rawManifestSHA256: requiredString(body, "rawManifestSHA256"), archiveSHA256: requiredString(body, "archiveSHA256"), archiveByteCount: requiredInteger(body, "archiveByteCount"), reviewSHA256: requiredString(body, "reviewSHA256"), idempotencyKey: requiredString(body, "idempotencyKey"), quotaPolicyVersion: requiredInteger(body, "quotaPolicyVersion"), hostedGlobalVersion: requiredInteger(body, "hostedGlobalVersion"), hostedWorkspaceVersion: requiredInteger(body, "hostedWorkspaceVersion") } satisfies ProjectSyncRawArchiveAllocateInput), allocationBody);
};

function repositoryFor(context: AuthorizedOperationContext | undefined) {
  if (context === undefined) throw new ProjectSyncRouteApplicationError("invalid_request");
  return requireProjectSyncRepositories(context.repositories, context.transactionMarker).projectSync;
}

/** Maps a prepared typed result to an HTTP response without exposing the
 * effect's captured storage binding. The effect runs only in the operation
 * port after the Data API transaction commits. */
function responseFrom<T>(prepared: ProjectSyncPreparedResponse<T>, body: (value: T) => unknown, statusCode = 200): Slice5PostCommitResult<HttpApiV2Response> {
  const result = prepared.toPostCommitResult();
  return createSlice5PostCommitResult(
    () => json(statusCode, body(result.publicResult())),
    requireSlice5PostCommitEffect(result),
  );
}

function allocationBody(value: unknown): unknown { return value; }
function uploadStatusBody(value: unknown): unknown { return value; }
function recoveryBody(value: unknown): unknown { return value; }
function leaseBody(value: unknown): unknown { return value; }
function rawConfigurationBody(value: unknown): unknown { return value; }

function json(statusCode: number, value: unknown): HttpApiV2Response { return Object.freeze({ statusCode, headers: Object.freeze({ "cache-control": "no-store", "content-type": "application/json" }), body: JSON.stringify(value) }); }
function bodyRecord(request: Parameters<Slice5RouteHandler>[0]): Readonly<Record<string, unknown>> { if (request.body === null || typeof request.body !== "object" || Array.isArray(request.body)) throw new ProjectSyncRouteApplicationError("invalid_request"); return request.body as Readonly<Record<string, unknown>>; }
function requiredString(record: Readonly<Record<string, unknown>>, name: string): string { const value = record[name]; if (typeof value !== "string") throw new ProjectSyncRouteApplicationError("invalid_request"); return value; }
function optionalString(record: Readonly<Record<string, unknown>>, name: string): string | undefined { const value = record[name]; if (value === undefined) return undefined; if (typeof value !== "string") throw new ProjectSyncRouteApplicationError("invalid_request"); return value; }
function requiredInteger(record: Readonly<Record<string, unknown>>, name: string): number { const value = record[name]; if (typeof value !== "number" || !Number.isSafeInteger(value)) throw new ProjectSyncRouteApplicationError("invalid_request"); return value; }
