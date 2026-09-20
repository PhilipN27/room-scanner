import type { DataApiClient } from "../adapters/data-api.js";
import { PublicationObjectAdapter } from "../adapters/s3-publication.js";
import type { ApiGatewayV2Request } from "../handlers/factory.js";
import type { HttpApiV2Response } from "../http/http-api-v2.js";
import { DataApiPublicationWorkerStore } from "../persistence/publication-worker-store.js";
import {
  DataApiPublicationCapabilityService,
  PublicationSecretHasher,
  type PublicationClock,
  type PublicationValidationWakePort,
} from "../publication/capabilities.js";
import type {
  PublicationFeedbackDeliveryWakePort,
  PublicationFeedbackEnvelopeSealer,
} from "../publication/feedback-service.js";
import type { PublicationPrivacyAuditPort } from "../publication/privacy-audit.js";
import {
  createSlice6PortalDeliveryPublicationHandler,
  createSlice6PrivateApiPublicationHandler,
} from "../publication/route-application.js";
import { createSlice6PortalDocument, type Slice6PortalDocumentAssets } from "../publication/portal-document.js";
import { PublicationValidationWorker } from "../publication/worker.js";

/** Additive Slice 6 composition. The caller injects only fixed, role-bound
 * runtime ports; no API request can select a database role, tenant, storage
 * prefix, worker target, publication flag, or clock value. The existing
 * Slice 4/5 entrypoint remains the sole owner of the inherited routes. */
interface Slice6DataApiPublicationCommonDependencies {
  readonly client: DataApiClient;
  readonly clock: PublicationClock;
  /** Existing app-token HMAC key. `PublicationSecretHasher` preserves its
   * frozen app-bearer digest and domain-separates every new portal secret. */
  readonly accessTokenHmacKey: Uint8Array;
  readonly storage: PublicationObjectAdapter;
  readonly validationWake: PublicationValidationWakePort;
  /** API-role-only sealer. It can encrypt a bounded feedback delivery payload
   * but cannot decrypt or send it. */
  readonly feedbackEnvelopeSealer: PublicationFeedbackEnvelopeSealer;
  /** Targetless queue/tick wake for the separately scoped email runtime. */
  readonly feedbackDeliveryWake: PublicationFeedbackDeliveryWakePort;
  readonly publicationAudit?: PublicationPrivacyAuditPort;
  /** First-party HTTPS origin only. No custom-domain support is implied. */
  readonly portalOrigin?: string;
}
export interface Slice6DataApiPublicationApplicationDependencies extends Slice6DataApiPublicationCommonDependencies {
  readonly legacy: (request: ApiGatewayV2Request) => Promise<HttpApiV2Response>;
}
/** PortalDelivery has no legacy handler seam and is the only production root
 * that receives built web bytes. */
export interface Slice6DataApiPortalDeliveryDependencies extends Slice6DataApiPublicationCommonDependencies {
  readonly portalDocument: Slice6PortalDocumentAssets;
}

export interface Slice6PublicationWorkerDependencies {
  readonly client: DataApiClient;
  readonly clock: PublicationClock;
  readonly storage: PublicationObjectAdapter;
}

export function createSlice6DataApiPublicationHandler(
  input: Slice6DataApiPublicationApplicationDependencies,
): (request: ApiGatewayV2Request) => Promise<HttpApiV2Response> {
  assertApplication(input);
  const { publication, secretHasher } = publicationCapabilities(input);
  return createSlice6PrivateApiPublicationHandler({
    legacy: input.legacy,
    publication,
    secretHasher,
    ...(input.portalOrigin === undefined ? {} : { portalOrigin: input.portalOrigin }),
  });
}

/** The only production portal/publication-byte composition. Its route factory
 * is disjoint from PrivateApi and receives no legacy delegate. */
export function createSlice6DataApiPortalDeliveryHandler(
  input: Slice6DataApiPortalDeliveryDependencies,
): (request: ApiGatewayV2Request) => Promise<HttpApiV2Response> {
  assertPortalDeliveryApplication(input);
  const { publication, secretHasher } = publicationCapabilities(input);
  return createSlice6PortalDeliveryPublicationHandler({
    publication,
    secretHasher,
    portalDocument: input.portalDocument,
    ...(input.portalOrigin === undefined ? {} : { portalOrigin: input.portalOrigin }),
  });
}

/** The targetless worker has a distinct, smaller composition: it deliberately
 * lacks HTTP routes, credentials, feedback delivery, portal origin, and audit
 * sinks. The DB claim reducer chooses the next allocation. */
export function createSlice6PublicationWorker(input: Slice6PublicationWorkerDependencies): PublicationValidationWorker {
  if (input === null || typeof input !== "object" || input.client === null || typeof input.client !== "object" || input.clock === null || typeof input.clock.now !== "function" || !(input.storage instanceof PublicationObjectAdapter)) {
    throw new Slice6PublicationCompositionError("invalid_composition");
  }
  return new PublicationValidationWorker({
    clock: input.clock,
    store: new DataApiPublicationWorkerStore({ client: input.client }),
    objects: input.storage,
  });
}

export class Slice6PublicationCompositionError extends Error {
  constructor(readonly code: "invalid_composition") {
    super(code);
    this.name = "Slice6PublicationCompositionError";
  }
}

function publicationCapabilities(input: Slice6DataApiPublicationCommonDependencies): Readonly<{ readonly publication: DataApiPublicationCapabilityService; readonly secretHasher: PublicationSecretHasher }> {
  const secretHasher = new PublicationSecretHasher(input.accessTokenHmacKey);
  const publication = new DataApiPublicationCapabilityService({
    client: input.client,
    clock: input.clock,
    hasher: secretHasher,
    storage: input.storage,
    validationWake: input.validationWake,
    feedbackEnvelopeSealer: input.feedbackEnvelopeSealer,
    feedbackDeliveryWake: input.feedbackDeliveryWake,
    ...(input.publicationAudit === undefined ? {} : { publicationAudit: input.publicationAudit }),
    ...(input.portalOrigin === undefined ? {} : { portalOrigin: input.portalOrigin }),
  });
  return Object.freeze({ publication, secretHasher });
}

function assertApplication(input: Slice6DataApiPublicationApplicationDependencies): void {
  if (input === null || typeof input !== "object" || typeof input.legacy !== "function") {
    throw new Slice6PublicationCompositionError("invalid_composition");
  }
  assertCommonApplication(input);
}
function assertPortalDeliveryApplication(input: Slice6DataApiPortalDeliveryDependencies): void {
  assertCommonApplication(input);
  try { createSlice6PortalDocument(input.portalDocument); } catch { throw new Slice6PublicationCompositionError("invalid_composition"); }
}
function assertCommonApplication(input: Slice6DataApiPublicationCommonDependencies): void {
  if (input === null || typeof input !== "object" || input.client === null || typeof input.client !== "object" || input.clock === null || typeof input.clock.now !== "function" || !(input.accessTokenHmacKey instanceof Uint8Array) || input.accessTokenHmacKey.byteLength < 32 || !(input.storage instanceof PublicationObjectAdapter) || input.validationWake === null || typeof input.validationWake.notifyPublicationValidationWake !== "function" || input.feedbackEnvelopeSealer === null || typeof input.feedbackEnvelopeSealer !== "object" || typeof input.feedbackEnvelopeSealer.seal !== "function" || input.feedbackDeliveryWake === null || typeof input.feedbackDeliveryWake !== "object" || typeof input.feedbackDeliveryWake.notifyFeedbackDeliveryWake !== "function") {
    throw new Slice6PublicationCompositionError("invalid_composition");
  }
}
