import {
  CognitoIdentityProviderClient,
} from "@aws-sdk/client-cognito-identity-provider";
import { S3Client } from "@aws-sdk/client-s3";
import { SESv2Client } from "@aws-sdk/client-sesv2";
import { SQSClient } from "@aws-sdk/client-sqs";

import {
  CognitoAppleCustomAuthAdminAdapter,
  StatelessAppleCustomChallengePort,
  StripeCurrentSubscriptionHttpAdapter,
  createSlice4AuditExporterSqsHandler,
  createSlice4AppAuthorizer,
  createSlice4CognitoAppleChallengeBridge,
  createSlice4CognitoCustomChallengeAdapter,
  createSlice4CognitoChallengeHandler,
  createSlice4DataApiApiHandler,
  createSlice4MagicDeliveryWorker,
  createSlice4MagicDeliverySqsHandler,
  createSlice4ProviderAuditExporterWorker,
  createSlice4ReconciliationSqsHandler,
  createSlice4StripeIngressApplication,
  createSlice4StripeIngressHandler,
  createSlice4StripeReconciliationWorker,
} from "roomscan-studio-hosted-service/composition";
import { DataApiAppAuthorizer } from "roomscan-studio-hosted-service/persistence";

import {
  AwsAppleJwksPort,
  AwsCognitoAppleCustomAuthTransport,
  AwsMagicDeliveryProviderPort,
  AwsProviderAuditDeliveryPort,
  AwsSesV2Port,
  AwsSqsWakePort,
  BoundedGetHttpTransport,
  BoundedHttpTransport,
} from "../aws/runtime-clients.js";
import {
  LambdaRuntimeConfigurationError,
  deriveKey,
  lazyHandler,
  localPolicyValuesEnabled,
  readSecretValue,
  roleBoundDataApiClient,
  systemClock,
  systemRandom,
} from "./runtime-support.js";

type DataApiClient = Parameters<typeof createSlice4DataApiApiHandler>[0]["apiClient"];
type ApiHandler = ReturnType<typeof createSlice4DataApiApiHandler>;
type AuthorizerHandler = ReturnType<typeof createSlice4AppAuthorizer>;
type CognitoHandler = ReturnType<typeof createSlice4CognitoChallengeHandler>;
type StripeHandler = ReturnType<typeof createSlice4StripeIngressHandler>;
type ReconciliationHandler = ReturnType<typeof createSlice4ReconciliationSqsHandler>;
type AuditExporterHandler = ReturnType<typeof createSlice4AuditExporterSqsHandler>;
type MagicDeliveryHandler = ReturnType<typeof createSlice4MagicDeliverySqsHandler>;
type CognitoTransport = ConstructorParameters<typeof CognitoAppleCustomAuthAdminAdapter>[0]["transport"];
type StripeIngressPort = Parameters<typeof createSlice4StripeIngressHandler>[0]["ingress"];
type StripeWakePort = NonNullable<Parameters<typeof createSlice4StripeIngressHandler>[0]["wake"]>;
type ReconciliationWorker = Parameters<typeof createSlice4ReconciliationSqsHandler>[0]["worker"];
type CurrentSubscriptions = Parameters<typeof createSlice4StripeReconciliationWorker>[0]["currentSubscriptions"];
type AuditExporterWorker = Parameters<typeof createSlice4AuditExporterSqsHandler>[0]["worker"];
type MagicDeliveryWorker = Parameters<typeof createSlice4MagicDeliverySqsHandler>[0]["worker"];

export type Slice4RuntimeRole =
  | "roomscan_api_runtime"
  | "roomscan_authorizer_runtime"
  | "roomscan_auth_challenge_runtime"
  | "roomscan_stripe_ingress_runtime"
  | "roomscan_stripe_reconciliation_runtime"
  | "roomscan_audit_export_runtime"
  | "roomscan_email_delivery_runtime";

/**
 * Test-only construction seams. Production roots never pass this object: they
 * use exact, lane-bound AWS clients inside the lazy initializer below. Keeping
 * the seams at root construction lets tests prove lane and handler behavior
 * without an AWS account or an ambient credential chain.
 */
export interface Slice4RootRuntimeDependencies {
  readonly dataClient?: (role: Slice4RuntimeRole) => DataApiClient;
  readonly readSecret?: (arn: string, field: string) => Promise<string>;
  readonly cognitoTransport?: (input: Readonly<{ readonly userPoolId: string; readonly clientId: string }>) => CognitoTransport;
  readonly stripeIngress?: (input: Readonly<{
    readonly client: DataApiClient;
    readonly signingSecret: string;
    readonly defaultAccountId: string;
  }>) => StripeIngressPort;
  readonly reconciliationWorker?: (input: Readonly<{
    readonly client: DataApiClient;
    readonly stripeApiSecretArn: string;
  }>) => ReconciliationWorker;
  readonly currentSubscriptions?: (input: Readonly<{
    readonly stripeApiSecretArn: string;
    readonly apiVersion: string;
    readonly pricePlanMappings: readonly Readonly<{ readonly priceId: string; readonly planKey: string }>[];
  }>) => CurrentSubscriptions;
  readonly auditExporterWorker?: (input: Readonly<{
    readonly client: DataApiClient;
    readonly auditBucketName: string;
  }>) => AuditExporterWorker;
  readonly magicDeliveryWorker?: (input: Readonly<{
    readonly client: DataApiClient;
    readonly keyId: string;
    readonly envelopeKey: Uint8Array;
    readonly publicBaseUrl: string;
    readonly senderAddress: string;
    readonly identityArn: string;
    readonly configurationSetName: string;
    readonly templateName: string;
  }>) => MagicDeliveryWorker;
  readonly wake?: (input: Readonly<{ readonly queueUrl: string; readonly messageKind: string }>) => StripeWakePort;
}

export async function createApiRoot(
  environment: NodeJS.ProcessEnv = process.env,
  dependencies: Slice4RootRuntimeDependencies = {},
): Promise<ApiHandler> {
  const lane = laneConfiguration(environment, "roomscan_api_runtime");
  const accessSecretArn = requiredSecretArn(environment, "ACCESS_TOKEN_HMAC_SECRET_ARN");
  const derivationSecretArn = requiredSecretArn(environment, "API_TOKEN_DERIVATION_SECRET_ARN");
  const envelopeSecretArn = requiredSecretArn(environment, "MAGIC_DELIVERY_ENVELOPE_SECRET_ARN");
  // The API custom-auth adapter and Cognito challenge Lambda verify the same
  // signed answer. This is the one deliberately shared application secret;
  // it is not a challenge database credential and carries no tenant scope.
  const challengeSecretArn = requiredSecretArn(environment, "AUTH_CHALLENGE_SECRET_ARN");
  const appleSecretArn = requiredSecretArn(environment, "APPLE_PRIVATE_KEY_SECRET_ARN");
  const clientId = requiredIdentifier(environment, "APPLE_CLIENT_ID", 1, 256, /^[A-Za-z0-9._-]+$/u);
  const teamId = requiredIdentifier(environment, "APPLE_TEAM_ID", 1, 32, /^[A-Za-z0-9]+$/u);
  const keyId = requiredIdentifier(environment, "APPLE_KEY_ID", 1, 32, /^[A-Za-z0-9]+$/u);
  const redirectUri = requiredHttpsUrl(environment, "APPLE_REDIRECT_URI");
  if (requiredVersion(environment, "APPLE_CLIENT_SECRET_SIGNING_MODE") !== "runtime-es256-secretsmanager-v1") {
    throw invalidConfiguration();
  }
  const userPoolId = requiredIdentifier(environment, "COGNITO_USER_POOL_ID", 1, 55, /^[A-Za-z0-9_-]+$/u);
  const cognitoClientId = requiredIdentifier(environment, "COGNITO_SERVER_CLIENT_ID", 3, 128, /^[A-Za-z0-9]+$/u);
  const magicDeliveryQueueUrl = requiredQueueUrl(environment, "MAGIC_DELIVERY_QUEUE_URL");
  const magicDeliveryKeyId = requiredIdentifier(environment, "MAGIC_DELIVERY_KEY_ID", 3, 64, /^[A-Za-z0-9._-]+$/u);
  const authVersion = requiredVersion(environment, "AUTH_POLICY_VERSION");
  const magicVersion = requiredVersion(environment, "MAGIC_POLICY_VERSION");
  const sessionVersion = requiredVersion(environment, "SESSION_POLICY_VERSION");

  const [accessRoot, derivationRoot, envelopeRoot, challengeRoot] = await Promise.all([
    secret(dependencies, accessSecretArn, "key"),
    secret(dependencies, derivationSecretArn, "key"),
    secret(dependencies, envelopeSecretArn, "key"),
    secret(dependencies, challengeSecretArn, "key"),
  ]);
  const client = dataClient(dependencies, lane.role);
  // API, authorizer, and challenge use only the key material they need. The
  // two cross-root protocols share exactly these derived domains: opaque
  // access-token lookup, Apple bridge-proof persistence, and Cognito's signed
  // custom challenge. No database credential or tenant context crosses lanes.
  const accessTokenHmacKey = key(accessRoot, "slice4.access-token-hmac.v1");
  const apiKeys = routeKeys(
    derivationRoot,
    accessTokenHmacKey,
    key(challengeRoot, "slice4.apple.bridge-proof-hmac.v1"),
  );
  const envelopeKey = key(envelopeRoot, "slice4.magic-delivery-envelope.aes-256-gcm.v1");
  const cognito = dependencies.cognitoTransport?.({ userPoolId, clientId: cognitoClientId })
    ?? new AwsCognitoAppleCustomAuthTransport({
      sender: new CognitoIdentityProviderClient({ region: "us-east-1" }),
      userPoolId,
      clientId: cognitoClientId,
    });
  const magicWake = wake(dependencies, magicDeliveryQueueUrl, "magic-delivery-wake-v1");

  return createSlice4DataApiApiHandler({
    apiClient: client,
    clock: systemClock,
    random: systemRandom,
    keys: apiKeys,
    magic: Object.freeze({
      version: magicVersion,
      ttlMs: 10 * 60_000,
      verifiedAuthenticationReceiptTtlMs: 5 * 60_000,
      ratePolicy: Object.freeze({
        cooldownSeconds: 60,
        maxActiveLinks: 2,
        addressWindowSeconds: 15 * 60,
        maxAddressWindow: 3,
        addressDaySeconds: 24 * 60 * 60,
        maxAddressDay: 10,
        networkWindowSeconds: 15 * 60,
        maxNetworkWindow: 20,
      }),
      maxCompletionFailures: 5,
      redeemNetworkWindowSeconds: 60,
      maxRedeemNetworkFailures: 10,
      keyId: magicDeliveryKeyId,
      sealingKey: envelopeKey,
    }),
    sessions: Object.freeze({
      version: sessionVersion,
      accessTtlMs: 5 * 60_000,
      refreshInactivityTtlMs: 7 * 24 * 60 * 60_000,
      refreshAbsoluteTtlMs: 30 * 24 * 60 * 60_000,
    }),
    identity: Object.freeze({ version: authVersion, candidateProofTtlMs: 5 * 60_000 }),
    apple: Object.freeze({
      version: authVersion,
      clientId,
      redirectUri,
      attemptTtlMs: 5 * 60_000,
      bridgeProofTtlMs: 5 * 60_000,
      verifiedAuthenticationReceiptTtlMs: 5 * 60_000,
      transport: new BoundedHttpTransport(),
      privateKeySecrets: fixedSecretReader(dependencies, "apple-private-key", appleSecretArn, "privateKey"),
      privateKeySecretName: "apple-private-key",
      teamId,
      keyId,
      clientSecretLifetimeSeconds: 5 * 60,
      exchangeTimeoutMs: 5_000,
      exchangeMaxResponseBytes: 65_536,
      jwks: new AwsAppleJwksPort(),
      jwksCacheTtlMs: 60 * 60_000,
      clockSkewMs: 30_000,
      maxTokenAgeMs: 5 * 60_000,
      cognito: new CognitoAppleCustomAuthAdminAdapter({
        transport: cognito,
        clientId: cognitoClientId,
        sharedHmacKey: key(challengeRoot, "slice4.cognito.custom-auth-shared-hmac.v1"),
      }),
    }),
    // API Gateway maps this route to the distinct Stripe ingress Lambda. The
    // sealed application still contains all nineteen route IDs, but this API
    // role receives neither a Stripe secret nor a Stripe provider port.
    stripe: Object.freeze({
      handle: async () => unavailableResponse(),
    }),
    magicDeliveryWake: magicWake,
  });
}

export async function createAuthorizerRoot(
  environment: NodeJS.ProcessEnv = process.env,
  dependencies: Slice4RootRuntimeDependencies = {},
): Promise<AuthorizerHandler> {
  const lane = laneConfiguration(environment, "roomscan_authorizer_runtime");
  const accessSecretArn = requiredSecretArn(environment, "ACCESS_TOKEN_HMAC_SECRET_ARN");
  const accessRoot = await secret(dependencies, accessSecretArn, "key");
  const preflight = new DataApiAppAuthorizer({
    client: dataClient(dependencies, lane.role),
    accessTokenHmacKey: key(accessRoot, "slice4.access-token-hmac.v1"),
    clock: Object.freeze({ now: () => new Date(systemClock.nowMs()) }),
  });
  return createSlice4AppAuthorizer({ preflight });
}

export async function createAuthChallengeRoot(
  environment: NodeJS.ProcessEnv = process.env,
  dependencies: Slice4RootRuntimeDependencies = {},
): Promise<CognitoHandler> {
  const lane = laneConfiguration(environment, "roomscan_auth_challenge_runtime");
  const secretArn = requiredSecretArn(environment, "AUTH_CHALLENGE_SECRET_ARN");
  requiredVersion(environment, "AUTH_CHALLENGE_POLICY_VERSION");
  const root = await secret(dependencies, secretArn, "key");
  const bridgeKey = key(root, "slice4.apple.bridge-proof-hmac.v1");
  const sharedKey = key(root, "slice4.cognito.custom-auth-shared-hmac.v1");
  const bridge = createSlice4CognitoAppleChallengeBridge({
    client: dataClient(dependencies, lane.role),
    bridgeProofHmacKey: bridgeKey,
  });
  const challenges = new StatelessAppleCustomChallengePort({
    bridge,
    sharedHmacKey: sharedKey,
    random: systemRandom,
  });
  return createSlice4CognitoChallengeHandler({
    customChallenge: createSlice4CognitoCustomChallengeAdapter({ challenges }),
  });
}

export async function createStripeWebhookRoot(
  environment: NodeJS.ProcessEnv = process.env,
  dependencies: Slice4RootRuntimeDependencies = {},
): Promise<StripeHandler> {
  const lane = laneConfiguration(environment, "roomscan_stripe_ingress_runtime");
  const webhookSecretArn = requiredSecretArn(environment, "STRIPE_WEBHOOK_SECRET_ARN");
  const defaultAccountId = requiredStripeAccountId(environment, "STRIPE_DEFAULT_ACCOUNT_ID");
  requiredLiteral(environment, "RAW_ENVELOPE_CONTRACT", "body+isBase64Encoded:unparsed-v1");
  const reconciliationQueueUrl = requiredQueueUrl(environment, "STRIPE_RECONCILIATION_QUEUE_URL");
  const auditQueueUrl = requiredQueueUrl(environment, "AUDIT_OUTBOX_QUEUE_URL");
  const signingSecret = providerSecret(await secret(dependencies, webhookSecretArn, "key"));
  const ingress = dependencies.stripeIngress?.({
    client: dataClient(dependencies, lane.role),
    signingSecret,
    defaultAccountId,
  }) ?? createSlice4StripeIngressApplication({
    client: dataClient(dependencies, lane.role),
    clock: systemClock,
    signingSecret,
    toleranceMs: 5 * 60_000,
    defaultStripeAccountId: defaultAccountId,
    logger: NOOP_BILLING_LOGGER,
  });
  return createSlice4StripeIngressHandler({
    ingress,
    wake: fanoutWake(
      wake(dependencies, reconciliationQueueUrl, "stripe-reconciliation-wake-v1"),
      wake(dependencies, auditQueueUrl, "provider-audit-export-wake-v1"),
    ),
  });
}

export async function createReconciliationRoot(
  environment: NodeJS.ProcessEnv = process.env,
  dependencies: Slice4RootRuntimeDependencies = {},
): Promise<ReconciliationHandler> {
  const lane = laneConfiguration(environment, "roomscan_stripe_reconciliation_runtime");
  const stripeApiSecretArn = requiredSecretArn(environment, "STRIPE_API_SECRET_ARN");
  const stripeApiVersion = requiredStripeApiVersion(environment, "STRIPE_API_VERSION");
  // Production pricing has not been owner-approved. Only explicit synthetic
  // values in the dev lane can construct this adapter; auth/session policies
  // are intentionally not coupled to this temporary commercial-policy gate.
  localPolicyValuesEnabled(environment);
  const pricePlanMappings = requiredStripePricePlanMappings(environment, "STRIPE_PRICE_PLAN_MAP_JSON");
  const client = dataClient(dependencies, lane.role);
  const worker = dependencies.reconciliationWorker?.({ client, stripeApiSecretArn }) ?? createSlice4StripeReconciliationWorker({
    client,
    clock: systemClock,
    random: systemRandom,
    currentSubscriptions: dependencies.currentSubscriptions?.({
      stripeApiSecretArn,
      apiVersion: stripeApiVersion,
      pricePlanMappings,
    }) ?? new StripeCurrentSubscriptionHttpAdapter({
      transport: new BoundedGetHttpTransport(),
      secrets: fixedSecretReader(dependencies, stripeApiSecretArn, stripeApiSecretArn, "key"),
      secretName: stripeApiSecretArn,
      apiVersion: stripeApiVersion,
      clock: systemClock,
      timeoutMs: 5_000,
      maxResponseBytes: 65_536,
      // This is never a source-embedded commercial mapping. An absent, stale,
      // malformed, or unapproved environment map prevents worker construction
      // rather than silently assigning an entitlement.
      pricePlanMappings,
    }),
    leaseMs: 60_000,
  });
  return createSlice4ReconciliationSqsHandler({ worker });
}

export async function createAuditExporterRoot(
  environment: NodeJS.ProcessEnv = process.env,
  dependencies: Slice4RootRuntimeDependencies = {},
): Promise<AuditExporterHandler> {
  const lane = laneConfiguration(environment, "roomscan_audit_export_runtime");
  const auditBucketName = requiredBucketName(environment, "AUDIT_BUCKET_NAME");
  const client = dataClient(dependencies, lane.role);
  const worker = dependencies.auditExporterWorker?.({ client, auditBucketName }) ?? createSlice4ProviderAuditExporterWorker({
    client,
    clock: systemClock,
    random: systemRandom,
    delivery: new AwsProviderAuditDeliveryPort({
      sender: new S3Client({ region: "us-east-1" }),
      bucketName: auditBucketName,
    }),
    leaseMs: 60_000,
  });
  return createSlice4AuditExporterSqsHandler({ worker });
}

export async function createEmailDeliveryRoot(
  environment: NodeJS.ProcessEnv = process.env,
  dependencies: Slice4RootRuntimeDependencies = {},
): Promise<MagicDeliveryHandler> {
  const lane = laneConfiguration(environment, "roomscan_email_delivery_runtime");
  const envelopeSecretArn = requiredSecretArn(environment, "MAGIC_DELIVERY_ENVELOPE_SECRET_ARN");
  const keyId = requiredIdentifier(environment, "MAGIC_DELIVERY_KEY_ID", 3, 64, /^[A-Za-z0-9._-]+$/u);
  const publicBaseUrl = requiredHttpsUrl(environment, "PUBLIC_BASE_URL");
  const senderAddress = requiredEmail(environment, "SES_SENDER_ADDRESS");
  const identityArn = requiredSesIdentityArn(environment, "SES_IDENTITY_ARN");
  const configurationSetName = requiredIdentifier(environment, "SES_CONFIGURATION_SET_NAME", 1, 64, /^[A-Za-z0-9_-]+$/u);
  const templateName = requiredIdentifier(environment, "SES_MAGIC_LINK_TEMPLATE_NAME", 1, 128, /^[A-Za-z0-9_-]+$/u);
  const envelopeKey = key(await secret(dependencies, envelopeSecretArn, "key"), "slice4.magic-delivery-envelope.aes-256-gcm.v1");
  const client = dataClient(dependencies, lane.role);
  const worker = dependencies.magicDeliveryWorker?.({
    client,
    keyId,
    envelopeKey,
    publicBaseUrl,
    senderAddress,
    identityArn,
    configurationSetName,
    templateName,
  }) ?? createSlice4MagicDeliveryWorker({
    client,
    clock: systemClock,
    random: systemRandom,
    decryptionKeys: Object.freeze({
      resolve: async (requestedKeyId: string) => requestedKeyId === keyId ? Uint8Array.from(envelopeKey) : undefined,
    }),
    delivery: new AwsMagicDeliveryProviderPort({
      ses: new AwsSesV2Port(new SESv2Client({ region: "us-east-1" })),
      fromEmailAddress: senderAddress,
      identityArn,
      configurationSetName,
      templateName,
    }),
    publicBaseUrl,
    leaseMs: 60_000,
  });
  return createSlice4MagicDeliverySqsHandler({ worker });
}

/** No provider client, secret reader, or database client is constructed at
 * module import. Each Lambda root wraps one of these factories with this
 * lazy initializer. */
export function lazyRoot<Event, Result>(
  initialize: () => Promise<(event: Event) => Promise<Result>>,
): (event: Event) => Promise<Result> {
  return lazyHandler(initialize);
}

export function unavailableResponse(): Readonly<{
  readonly statusCode: 500;
  readonly headers: Readonly<{ readonly "cache-control": "no-store"; readonly "content-type": "application/json" }>;
  readonly body: "{\"error\":{\"code\":\"unavailable\"}}";
}> {
  return UNAVAILABLE_RESPONSE;
}

export function unavailableSqsResponse(event: unknown): Readonly<{
  readonly batchItemFailures: readonly Readonly<{ readonly itemIdentifier: string }>[];
}> {
  const records = event !== null && typeof event === "object" && Array.isArray((event as { readonly Records?: unknown }).Records)
    ? (event as { readonly Records: readonly unknown[] }).Records
    : [];
  return Object.freeze({
    batchItemFailures: Object.freeze(records.flatMap((record) => {
      const messageId = record !== null && typeof record === "object" ? (record as { readonly messageId?: unknown }).messageId : undefined;
      return typeof messageId === "string" && /^[A-Za-z0-9._:-]{1,128}$/u.test(messageId)
        ? [Object.freeze({ itemIdentifier: messageId })]
        : [];
    })),
  });
}

export function unavailableAuthorizerResponse(): Readonly<{
  readonly isAuthorized: false;
  readonly context: Readonly<{ readonly decision: "deny" }>;
}> {
  return Object.freeze({ isAuthorized: false, context: Object.freeze({ decision: "deny" }) });
}

const UNAVAILABLE_RESPONSE = Object.freeze({
  statusCode: 500 as const,
  headers: Object.freeze({ "cache-control": "no-store" as const, "content-type": "application/json" as const }),
  body: "{\"error\":{\"code\":\"unavailable\"}}" as const,
});

const NOOP_BILLING_LOGGER = Object.freeze({ write: (_eventCode: string, _fields: Readonly<{ readonly result: string }>) => undefined });

function laneConfiguration(environment: NodeJS.ProcessEnv, expectedRole: Slice4RuntimeRole): Readonly<{ readonly role: Slice4RuntimeRole }> {
  requiredIdentifier(environment, "ROOMSCAN_STAGE", 3, 16, /^(?:dev|staging|production)$/u);
  if (requiredIdentifier(environment, "ROOMSCAN_REGION", 9, 9, /^[a-z0-9-]+$/u) !== "us-east-1") {
    throw invalidConfiguration();
  }
  requiredClusterArn(environment, "DB_CLUSTER_ARN");
  requiredSecretArn(environment, "ROOMSCAN_DB_ROLE_SECRET_ARN");
  const role = requiredIdentifier(environment, "ROOMSCAN_DB_RUNTIME_ROLE", 3, 64, /^[a-z][a-z0-9_]+$/u);
  if (role !== expectedRole) throw invalidConfiguration();
  return Object.freeze({ role: expectedRole });
}

function dataClient(dependencies: Slice4RootRuntimeDependencies, role: Slice4RuntimeRole): DataApiClient {
  return dependencies.dataClient?.(role) ?? roleBoundDataApiClient(role);
}

function secret(dependencies: Slice4RootRuntimeDependencies, arn: string, field: string): Promise<string> {
  return dependencies.readSecret?.(arn, field) ?? readSecretValue(arn, field);
}

function fixedSecretReader(
  dependencies: Slice4RootRuntimeDependencies,
  expectedName: string,
  arn: string,
  field: string,
): Readonly<{ readonly read: (name: string) => Promise<string> }> {
  return Object.freeze({
    read: async (name: string) => {
      if (name !== expectedName) throw invalidConfiguration();
      return secret(dependencies, arn, field);
    },
  });
}

function wake(dependencies: Slice4RootRuntimeDependencies, queueUrl: string, messageKind: string): StripeWakePort {
  return dependencies.wake?.({ queueUrl, messageKind }) ?? new AwsSqsWakePort({
    sender: new SQSClient({ region: "us-east-1" }),
    queueUrl,
    messageKind,
  });
}

function fanoutWake(...ports: readonly StripeWakePort[]): StripeWakePort {
  return Object.freeze({
    notify: async () => {
      const results = await Promise.allSettled(ports.map(async (port) => port.notify()));
      if (results.some((result) => result.status === "rejected")) throw new Error("wake_failed");
    },
  });
}

function routeKeys(root: string, accessTokenHmacKey: Uint8Array, appleBridgeProofHmacKey: Uint8Array) {
  return Object.freeze({
    accessTokenHmacKey,
    refreshTokenHmacKey: key(root, "slice4.api.refresh-token-hmac.v1"),
    magicTokenHmacKey: key(root, "slice4.api.magic-token-hmac.v1"),
    magicAddressHmacKey: key(root, "slice4.api.magic-address-hmac.v1"),
    magicNetworkHmacKey: key(root, "slice4.api.magic-network-hmac.v1"),
    appleStateHmacKey: key(root, "slice4.api.apple-state-hmac.v1"),
    appleCodeHmacKey: key(root, "slice4.api.apple-code-hmac.v1"),
    appleBridgeProofHmacKey,
    verifiedAuthenticationReceiptHmacKey: key(root, "slice4.api.verified-authentication-receipt-hmac.v1"),
  });
}

function key(root: string, purpose: string): Uint8Array {
  return deriveKey(root, purpose);
}

function requiredSecretArn(environment: NodeJS.ProcessEnv, name: string): string {
  return requiredIdentifier(environment, name, 1, 640, /^arn:aws:secretsmanager:us-east-1:\d{12}:secret:[A-Za-z0-9/_+=.@-]{1,512}$/u);
}

function requiredClusterArn(environment: NodeJS.ProcessEnv, name: string): string {
  return requiredIdentifier(environment, name, 1, 256, /^arn:aws:rds:us-east-1:\d{12}:cluster:[A-Za-z0-9-]{1,63}$/u);
}

function requiredQueueUrl(environment: NodeJS.ProcessEnv, name: string): string {
  return requiredIdentifier(environment, name, 1, 512, /^https:\/\/sqs\.us-east-1\.amazonaws\.com\/\d{12}\/[A-Za-z0-9_-]{1,80}$/u);
}

function requiredBucketName(environment: NodeJS.ProcessEnv, name: string): string {
  return requiredIdentifier(environment, name, 3, 63, /^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/u);
}

function requiredStripeAccountId(environment: NodeJS.ProcessEnv, name: string): string {
  return requiredIdentifier(environment, name, 12, 261, /^acct_[A-Za-z0-9]{6,255}$/u);
}

function requiredStripeApiVersion(environment: NodeJS.ProcessEnv, name: string): string {
  // Keep this validation exactly aligned with the frozen provider-neutral
  // adapter contract. The root never silently inherits Stripe's account
  // default schema.
  return requiredIdentifier(environment, name, 10, 75, /^[0-9]{4}-[0-9]{2}-[0-9]{2}(?:\.[A-Za-z0-9_-]{1,64})?$/u);
}

function requiredStripePricePlanMappings(
  environment: NodeJS.ProcessEnv,
  name: string,
): readonly Readonly<{ readonly priceId: string; readonly planKey: string }>[] {
  const source = environment[name];
  if (source === undefined || source.length === 0) throw new LambdaRuntimeConfigurationError("missing_configuration");
  if (source.length > 16_384 || source !== source.trim() || !/^\[[\s\S]*\]$/u.test(source)) throw invalidConfiguration();
  let parsed: unknown;
  try { parsed = JSON.parse(source) as unknown; } catch { throw invalidConfiguration(); }
  if (!Array.isArray(parsed) || parsed.length < 1 || parsed.length > 64) throw invalidConfiguration();
  const priceIds = new Set<string>();
  const planKeys = new Set<string>();
  const mappings = parsed.map((value) => {
    if (value === null || typeof value !== "object" || Array.isArray(value)) throw invalidConfiguration();
    const record = value as Readonly<Record<string, unknown>>;
    if (Object.keys(record).sort().join(",") !== "planKey,priceId") throw invalidConfiguration();
    const priceId = record.priceId;
    const planKey = record.planKey;
    if (typeof priceId !== "string" || !/^price_[A-Za-z0-9]{6,255}$/u.test(priceId)
      || typeof planKey !== "string" || !/^[A-Za-z0-9._-]{1,128}$/u.test(planKey)
      || priceIds.has(priceId) || planKeys.has(planKey)) throw invalidConfiguration();
    priceIds.add(priceId);
    planKeys.add(planKey);
    return Object.freeze({ priceId, planKey });
  });
  return Object.freeze(mappings);
}

function requiredSesIdentityArn(environment: NodeJS.ProcessEnv, name: string): string {
  return requiredIdentifier(environment, name, 1, 512, /^arn:aws:ses:us-east-1:\d{12}:identity\/.{1,256}$/u);
}

function requiredEmail(environment: NodeJS.ProcessEnv, name: string): string {
  return requiredIdentifier(environment, name, 3, 320, /^[^\s@]+@[^\s@]+\.[^\s@]+$/u);
}

function requiredHttpsUrl(environment: NodeJS.ProcessEnv, name: string): string {
  const value = requiredIdentifier(environment, name, 12, 2_048, /^https:\/\/.+$/u);
  let url: URL;
  try { url = new URL(value); } catch { throw invalidConfiguration(); }
  if (url.protocol !== "https:" || url.username !== "" || url.password !== "" || url.hash !== "" || url.search !== "" || url.hostname.length === 0) {
    throw invalidConfiguration();
  }
  return value;
}

function requiredVersion(environment: NodeJS.ProcessEnv, name: string): string {
  return requiredIdentifier(environment, name, 3, 64, /^[a-z0-9][a-z0-9._-]{2,63}$/u);
}

function requiredLiteral(environment: NodeJS.ProcessEnv, name: string, expected: string): string {
  const value = environment[name];
  if (value === undefined || value.length === 0) throw new LambdaRuntimeConfigurationError("missing_configuration");
  if (value !== expected || value !== value.trim()) throw invalidConfiguration();
  return value;
}

function requiredIdentifier(environment: NodeJS.ProcessEnv, name: string, minimum: number, maximum: number, pattern: RegExp): string {
  const value = environment[name];
  if (value === undefined || value.length === 0) throw new LambdaRuntimeConfigurationError("missing_configuration");
  if (value.length < minimum || value.length > maximum || value !== value.trim() || !pattern.test(value)) throw invalidConfiguration();
  return value;
}

function providerSecret(value: string): string {
  if (value.length < 16 || value.length > 512 || /[\u0000-\u001f\u007f\s]/u.test(value)) throw invalidConfiguration();
  return value;
}

function invalidConfiguration(): LambdaRuntimeConfigurationError {
  return new LambdaRuntimeConfigurationError("invalid_configuration");
}
