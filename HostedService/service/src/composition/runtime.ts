import {
  CognitoAuthChallengeBridge,
  CognitoCustomChallengeAdapter,
  type CustomChallengePort,
} from "../adapters/cognito-custom-auth.js";
import type { DataApiClient } from "../adapters/data-api.js";
import { StripeWebhookHttpAdapter } from "../handlers/stripe-webhook.js";
import type { RouteHandler } from "../handlers/factory.js";
import {
  BillingReconciliationService,
  StripeWebhookHandler,
  StripeWebhookSignatureVerifier,
  type BillingAuditLogger,
  type Clock as BillingClock,
  type CurrentSubscriptionSource,
  type RandomBytes,
} from "../billing/stripe-billing.js";
import { SLICE4_ROUTE_MANIFEST } from "../contracts/route-manifest.js";
import {
  DataApiAppleChallengeSessionPort,
  DataApiMagicDeliveryWorker,
  DataApiProviderAuditExportWorker,
  DataApiStripeIngressBillingRepository,
  DataApiStripeReconciliationBillingRepository,
  type ProviderAuditDeliveryPort,
  type MagicDeliveryKeyringPort,
  type MagicDeliveryProviderPort,
} from "../persistence/runtime-repositories.js";
export { createSlice4RouteApplications } from "./route-application.js";

/** Complete service-domain handler application. Infrastructure never supplies
 * individual routes or replaces path/action policy; it receives this sealed
 * map after service composition validates it against the canonical manifest. */
export type Slice4RouteApplications = Readonly<Record<string, RouteHandler>>;

export function createSlice4RouteHandlers(applications: Slice4RouteApplications): Readonly<Record<string, RouteHandler>> {
  if (applications === null || typeof applications !== "object") throw new Error("invalid_slice4_route_application");
  const expected = new Set(SLICE4_ROUTE_MANIFEST.map((route) => route.id));
  const ids = Object.keys(applications);
  if (ids.length !== expected.size || ids.some((id) => !expected.has(id)) || ids.some((id) => typeof applications[id] !== "function")) {
    throw new Error("invalid_slice4_route_application");
  }
  return Object.freeze({ ...applications });
}

export function createSlice4StripeIngressApplication(input: {
  readonly client: DataApiClient;
  readonly clock: BillingClock;
  readonly signingSecret: string;
  readonly toleranceMs: number;
  readonly defaultStripeAccountId: string;
  readonly logger: BillingAuditLogger;
}): StripeWebhookHttpAdapter {
  const repository = new DataApiStripeIngressBillingRepository(input.client);
  const verifier = new StripeWebhookSignatureVerifier({
    signingSecret: input.signingSecret,
    clock: input.clock,
    toleranceMs: input.toleranceMs,
  });
  return new StripeWebhookHttpAdapter(new StripeWebhookHandler({
    clock: input.clock,
    signatureVerifier: verifier,
    repository,
    defaultStripeAccountId: input.defaultStripeAccountId,
    logger: input.logger,
  }));
}

/** The Stripe fetch port is invoked by `BillingReconciliationService` only
 * after the claim transaction commits and before completion begins. */
export function createSlice4StripeReconciliationWorker(input: {
  readonly client: DataApiClient;
  readonly clock: BillingClock;
  readonly random: RandomBytes;
  readonly currentSubscriptions: CurrentSubscriptionSource;
  readonly leaseMs: number;
}): BillingReconciliationService {
  const repository = new DataApiStripeReconciliationBillingRepository(input.client);
  const systemCapability = Object.freeze({ kind: "roomscan-stripe-reconciliation-v1" });
  return new BillingReconciliationService({
    clock: input.clock,
    random: input.random,
    repository,
    currentSubscriptions: input.currentSubscriptions,
    // The only hosted grant is derived from the exact frozen DB claim. Both
    // the gate and system capability are service-owned closures; IaC gets no
    // domain authority or grant mapping input.
    hostedGate: {
      hostedMutationGrant: async (workspaceId, action) => {
        if (action !== "system.stripe.reconcile") throw new Error("invalid_stripe_action");
        const grant = repository.hostedGrantForClaimedWorkspace(workspaceId);
        if (grant === undefined) throw new Error("stripe_claim_authority_unavailable");
        return grant;
      },
    },
    systemAuthority: {
      capability: systemCapability,
      authorize: async (attempt) => attempt.action === "system.stripe.reconcile" && attempt.capability === systemCapability,
    },
    leaseMs: input.leaseMs,
  });
}

export function createSlice4ProviderAuditExporterWorker(input: {
  readonly client: DataApiClient;
  readonly clock: { nowMs(): number };
  readonly random: { bytes(length: number): Uint8Array };
  readonly delivery: ProviderAuditDeliveryPort;
  readonly leaseMs: number;
}): DataApiProviderAuditExportWorker {
  return new DataApiProviderAuditExportWorker(input);
}

/** Email-runtime worker factory. SQS messages are wake/tick records only: the
 * target is selected by the email role's targetless claim capability. */
export function createSlice4MagicDeliveryWorker(input: {
  readonly client: DataApiClient;
  readonly clock: { nowMs(): number };
  readonly random: { bytes(length: number): Uint8Array };
  readonly decryptionKeys: MagicDeliveryKeyringPort;
  readonly delivery: MagicDeliveryProviderPort;
  readonly publicBaseUrl: string;
  readonly leaseMs: number;
}): DataApiMagicDeliveryWorker {
  return new DataApiMagicDeliveryWorker(input);
}

/** This bridge owns the auth-challenge DB role and is deliberately separate
 * from the API role's Apple exchange/Cognito-admin composition. */
export function createSlice4CognitoAppleChallengeBridge(input: {
  readonly client: DataApiClient;
  readonly bridgeProofHmacKey: Uint8Array;
}): CognitoAuthChallengeBridge {
  return new CognitoAuthChallengeBridge(new DataApiAppleChallengeSessionPort(input));
}

/** Generic Cognito Define/Create/Verify response shaping stays provider-neutral.
 * The supplied port must in turn use the challenge-only bridge above for the
 * Apple app-session exchange; the API runtime cannot obtain that bridge. */
export function createSlice4CognitoCustomChallengeAdapter(input: {
  readonly challenges: CustomChallengePort;
}): CognitoCustomChallengeAdapter {
  if (input === null || typeof input !== "object" || input.challenges === null || typeof input.challenges !== "object") {
    throw new Error("invalid_slice4_cognito_challenge");
  }
  return new CognitoCustomChallengeAdapter(input.challenges);
}
