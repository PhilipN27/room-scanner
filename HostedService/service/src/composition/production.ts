import type {
  CognitoCustomChallengeAdapter,
  CreateAuthChallengeEvent,
  DefineAuthChallengeEvent,
  VerifyAuthChallengeEvent,
} from "../adapters/cognito-custom-auth.js";
import type { HttpApiV2Response } from "../http/http-api-v2.js";
import {
  createSlice4HandlerEntrypoint,
  type ApiGatewayV2Request,
  type RouteHandler,
  type SameTransactionOperationPort,
} from "../handlers/factory.js";

/** Composition failures are deliberately configuration-only: no request body,
 * access token, provider response, or tenant identifier is included. */
export class Slice4CompositionError extends Error {
  constructor(readonly code: "invalid_composition" | "unsupported_cognito_trigger") {
    super(code);
    this.name = "Slice4CompositionError";
  }
}

export interface Slice4ApiCompositionDependencies {
  /** Complete, sealed `SLICE4_ROUTE_MANIFEST` handler map; the factory rejects
   * both missing and extra route IDs before it accepts traffic. */
  readonly handlers: Readonly<Record<string, RouteHandler>>;
  readonly operations: SameTransactionOperationPort;
}

/** Early API Gateway authorizer only. Protected handlers repeat current
 * membership/kill-switch authorization in their own API-role transaction. */
export interface Slice4AppAuthorizerPreflightPort {
  authorizeBearer(accessToken: string): Promise<boolean>;
}

export interface Slice4AppAuthorizerCompositionDependencies {
  readonly preflight: Slice4AppAuthorizerPreflightPort;
}

export interface Slice4AppAuthorizerRequest {
  readonly headers?: Readonly<Record<string, string | undefined>>;
}

export interface Slice4AppAuthorizerResponse {
  readonly isAuthorized: boolean;
  /** Never put principal, tenant, role, or session data into gateway context. */
  readonly context: Readonly<{ readonly decision: "allow" | "deny" }>;
}

export type Slice4CognitoCustomChallengeEvent =
  | DefineAuthChallengeEvent
  | CreateAuthChallengeEvent
  | VerifyAuthChallengeEvent;

export interface Slice4CognitoCompositionDependencies {
  /** Challenge runtime only: its implementation owns proof consumption and
   * app-session issuance, and the API runtime must never receive that port. */
  readonly customChallenge: Pick<CognitoCustomChallengeAdapter, "define" | "create" | "verify">;
}

export interface Slice4StripeIngressPort {
  handle(envelope: ApiGatewayV2Request): Promise<HttpApiV2Response>;
}

export interface Slice4StripeWakePort {
  /** Optional best-effort wake after the durable Stripe receipt has already
   * committed. Failure must not convert a committed webhook into a retry. */
  notify(): Promise<void>;
}

export interface Slice4StripeCompositionDependencies {
  readonly ingress: Slice4StripeIngressPort;
  readonly wake?: Slice4StripeWakePort;
}

export interface Slice4SqsRecord {
  readonly messageId: string;
  readonly body?: string;
}

export interface Slice4SqsEvent {
  readonly Records: readonly Slice4SqsRecord[];
}

export interface Slice4SqsBatchResponse {
  readonly batchItemFailures: readonly Readonly<{ readonly itemIdentifier: string }>[];
}

export type Slice4ReconciliationOutcome =
  | Readonly<{ readonly status: "idle" }>
  | Readonly<{ readonly status: "paused"; readonly reason: "hosted_operations_disabled" }>
  | Readonly<{ readonly status: "retry"; readonly reason: "ambiguous_current_state" | "current_state_unavailable" | "stale_claim" }>
  | Readonly<{ readonly status: "applied"; readonly generation: number; readonly needsAnotherGeneration: boolean }>;

export interface Slice4ReconciliationWorkerPort {
  runOnce(): Promise<Slice4ReconciliationOutcome>;
}

export interface Slice4ReconciliationCompositionDependencies {
  readonly worker: Slice4ReconciliationWorkerPort;
}

export interface Slice4AuditExporterWorkerPort {
  /** The worker carries only a queue record; its own repository maps the
   * server-owned audit record and lease. `false` means retry the same record. */
  handleRecord(record: Slice4SqsRecord): Promise<boolean>;
}

export interface Slice4AuditExporterCompositionDependencies {
  readonly worker: Slice4AuditExporterWorkerPort;
}

/** The email role's worker takes only a wake/tick record. It selects the
 * server-owned delivery row through claim_next_magic_delivery. */
export interface Slice4MagicDeliveryWorkerPort {
  handleRecord(record: Slice4SqsRecord): Promise<boolean>;
}

export interface Slice4MagicDeliveryCompositionDependencies {
  readonly worker: Slice4MagicDeliveryWorkerPort;
}

export interface Slice4LambdaCompositionDependencies {
  readonly api: Slice4ApiCompositionDependencies;
  readonly authorizer: Slice4AppAuthorizerCompositionDependencies;
  readonly cognito: Slice4CognitoCompositionDependencies;
  readonly stripe: Slice4StripeCompositionDependencies;
  readonly reconciliation: Slice4ReconciliationCompositionDependencies;
  readonly auditExporter: Slice4AuditExporterCompositionDependencies;
  readonly magicDelivery: Slice4MagicDeliveryCompositionDependencies;
}

export interface Slice4LambdaComposition {
  /** Exact sealed route map retained for infrastructure route inspection. */
  readonly apiRouteHandlers: Readonly<Record<string, RouteHandler>>;
  readonly api: (event: ApiGatewayV2Request) => Promise<HttpApiV2Response>;
  readonly authorizer: (event: Slice4AppAuthorizerRequest) => Promise<Slice4AppAuthorizerResponse>;
  readonly cognito: (event: Slice4CognitoCustomChallengeEvent) => Promise<Slice4CognitoCustomChallengeEvent>;
  readonly stripe: (event: ApiGatewayV2Request) => Promise<HttpApiV2Response>;
  readonly reconciliation: (event: Slice4SqsEvent) => Promise<Slice4SqsBatchResponse>;
  readonly auditExporter: (event: Slice4SqsEvent) => Promise<Slice4SqsBatchResponse>;
  readonly magicDelivery: (event: Slice4SqsEvent) => Promise<Slice4SqsBatchResponse>;
}

/**
 * The only service-side Lambda composition. It is provider-SDK-neutral: CDK
 * entrypoints construct role-bound Data API/provider adapters and pass these
 * narrow ports in; this module never reads environment variables or selects a
 * database role from input.
 */
export function createSlice4LambdaComposition(input: Slice4LambdaCompositionDependencies): Slice4LambdaComposition {
  assertComposition(input);
  const api = createSlice4ApiHandler(input.api);
  const authorizer = createSlice4AppAuthorizer(input.authorizer);
  const cognito = createSlice4CognitoChallengeHandler(input.cognito);
  const stripe = createSlice4StripeIngressHandler(input.stripe);
  const reconciliation = createSlice4ReconciliationSqsHandler(input.reconciliation);
  const auditExporter = createSlice4AuditExporterSqsHandler(input.auditExporter);
  const magicDelivery = createSlice4MagicDeliverySqsHandler(input.magicDelivery);
  return Object.freeze({
    apiRouteHandlers: Object.freeze({ ...input.api.handlers }),
    api,
    authorizer,
    cognito,
    stripe,
    reconciliation,
    auditExporter,
    magicDelivery,
  });
}

export function createSlice4ApiHandler(input: Slice4ApiCompositionDependencies): (event: ApiGatewayV2Request) => Promise<HttpApiV2Response> {
  if (input === null || typeof input !== "object" || input.handlers === null || typeof input.handlers !== "object"
    || input.operations === null || typeof input.operations !== "object" || typeof input.operations.run !== "function") {
    throw new Slice4CompositionError("invalid_composition");
  }
  return createSlice4HandlerEntrypoint({ handlers: input.handlers, operations: input.operations });
}

export function createSlice4AppAuthorizer(
  input: Slice4AppAuthorizerCompositionDependencies,
): (event: Slice4AppAuthorizerRequest) => Promise<Slice4AppAuthorizerResponse> {
  if (input === null || typeof input !== "object" || input.preflight === null
    || typeof input.preflight !== "object" || typeof input.preflight.authorizeBearer !== "function") {
    throw new Slice4CompositionError("invalid_composition");
  }
  return async (event) => {
    const accessToken = bearerFromHeaders(event?.headers);
    if (accessToken === undefined) return authorizerDecision(false);
    try {
      return authorizerDecision(await input.preflight.authorizeBearer(accessToken) === true);
    } catch {
      return authorizerDecision(false);
    }
  };
}

export function createSlice4CognitoChallengeHandler(
  input: Slice4CognitoCompositionDependencies,
): (event: Slice4CognitoCustomChallengeEvent) => Promise<Slice4CognitoCustomChallengeEvent> {
  if (input === null || typeof input !== "object" || input.customChallenge === null || typeof input.customChallenge !== "object"
    || typeof input.customChallenge.define !== "function" || typeof input.customChallenge.create !== "function"
    || typeof input.customChallenge.verify !== "function") {
    throw new Slice4CompositionError("invalid_composition");
  }
  return async (event) => {
    if (event.triggerSource === "DefineAuthChallenge_Authentication") return input.customChallenge.define(event);
    if (event.triggerSource === "CreateAuthChallenge_Authentication") return input.customChallenge.create(event);
    if (event.triggerSource === "VerifyAuthChallengeResponse_Authentication") return input.customChallenge.verify(event);
    throw new Slice4CompositionError("unsupported_cognito_trigger");
  };
}

export function createSlice4StripeIngressHandler(
  input: Slice4StripeCompositionDependencies,
): (event: ApiGatewayV2Request) => Promise<HttpApiV2Response> {
  if (input === null || typeof input !== "object" || input.ingress === null || typeof input.ingress !== "object"
    || typeof input.ingress.handle !== "function" || (input.wake !== undefined && (input.wake === null || typeof input.wake !== "object" || typeof input.wake.notify !== "function"))) {
    throw new Slice4CompositionError("invalid_composition");
  }
  return async (event) => {
    const response = await input.ingress.handle(event);
    if (response.statusCode === 200 && input.wake !== undefined) {
      try { await input.wake.notify(); } catch { /* durable receipt already committed */ }
    }
    return response;
  };
}

export function createSlice4ReconciliationSqsHandler(
  input: Slice4ReconciliationCompositionDependencies,
): (event: Slice4SqsEvent) => Promise<Slice4SqsBatchResponse> {
  if (input === null || typeof input !== "object" || input.worker === null
    || typeof input.worker !== "object" || typeof input.worker.runOnce !== "function") {
    throw new Slice4CompositionError("invalid_composition");
  }
  return async (event) => {
    const failures: Array<Readonly<{ readonly itemIdentifier: string }>> = [];
    for (const record of validRecords(event)) {
      try {
        const result = await input.worker.runOnce();
        if (result.status === "retry") failures.push(Object.freeze({ itemIdentifier: record.messageId }));
      } catch {
        failures.push(Object.freeze({ itemIdentifier: record.messageId }));
      }
    }
    return Object.freeze({ batchItemFailures: Object.freeze(failures) });
  };
}

export function createSlice4AuditExporterSqsHandler(
  input: Slice4AuditExporterCompositionDependencies,
): (event: Slice4SqsEvent) => Promise<Slice4SqsBatchResponse> {
  if (input === null || typeof input !== "object" || input.worker === null
    || typeof input.worker !== "object" || typeof input.worker.handleRecord !== "function") {
    throw new Slice4CompositionError("invalid_composition");
  }
  return async (event) => {
    const failures: Array<Readonly<{ readonly itemIdentifier: string }>> = [];
    for (const record of validRecords(event)) {
      try {
        if (await input.worker.handleRecord(record) !== true) {
          failures.push(Object.freeze({ itemIdentifier: record.messageId }));
        }
      } catch {
        failures.push(Object.freeze({ itemIdentifier: record.messageId }));
      }
    }
    return Object.freeze({ batchItemFailures: Object.freeze(failures) });
  };
}

/** Email delivery is targetless at the queue boundary. The worker claims its
 * own server-owned outbox record so a queue payload can never select an
 * address, selector, workspace, or sealed secret. */
export function createSlice4MagicDeliverySqsHandler(
  input: Slice4MagicDeliveryCompositionDependencies,
): (event: Slice4SqsEvent) => Promise<Slice4SqsBatchResponse> {
  if (input === null || typeof input !== "object" || input.worker === null
    || typeof input.worker !== "object" || typeof input.worker.handleRecord !== "function") {
    throw new Slice4CompositionError("invalid_composition");
  }
  return async (event) => {
    const failures: Array<Readonly<{ readonly itemIdentifier: string }>> = [];
    for (const record of validRecords(event)) {
      try {
        if (await input.worker.handleRecord(record) !== true) {
          failures.push(Object.freeze({ itemIdentifier: record.messageId }));
        }
      } catch {
        failures.push(Object.freeze({ itemIdentifier: record.messageId }));
      }
    }
    return Object.freeze({ batchItemFailures: Object.freeze(failures) });
  };
}

function assertComposition(input: Slice4LambdaCompositionDependencies): void {
  if (input === null || typeof input !== "object" || input.api === undefined || input.authorizer === undefined
    || input.cognito === undefined || input.stripe === undefined || input.reconciliation === undefined
    || input.auditExporter === undefined || input.magicDelivery === undefined) {
    throw new Slice4CompositionError("invalid_composition");
  }
}

function authorizerDecision(isAuthorized: boolean): Slice4AppAuthorizerResponse {
  return Object.freeze({
    isAuthorized,
    context: Object.freeze({ decision: isAuthorized ? "allow" : "deny" }),
  });
}

function bearerFromHeaders(headers: Slice4AppAuthorizerRequest["headers"]): string | undefined {
  if (headers === undefined || headers === null || typeof headers !== "object") return undefined;
  const values = Object.entries(headers)
    .filter(([name, value]) => name.toLowerCase() === "authorization" && typeof value === "string")
    .map(([, value]) => value!);
  if (values.length !== 1) return undefined;
  const match = /^Bearer ([A-Za-z0-9_-]{43})$/u.exec(values[0]!);
  if (match?.[1] === undefined) return undefined;
  const decoded = Buffer.from(match[1], "base64url");
  return decoded.length === 32 && decoded.toString("base64url") === match[1] ? match[1] : undefined;
}

function validRecords(event: Slice4SqsEvent): readonly Slice4SqsRecord[] {
  if (event === null || typeof event !== "object" || !Array.isArray(event.Records)) return [];
  return event.Records.filter((record): record is Slice4SqsRecord =>
    record !== null
    && typeof record === "object"
    && typeof record.messageId === "string"
    && /^[A-Za-z0-9._:-]{1,128}$/u.test(record.messageId)
    && (record.body === undefined || typeof record.body === "string"),
  );
}
