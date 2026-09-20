import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { RDSDataClient } from "@aws-sdk/client-rds-data";
import { S3Client } from "@aws-sdk/client-s3";
import { SQSClient } from "@aws-sdk/client-sqs";
import { PublicationObjectAdapter } from "roomscan-studio-hosted-service/adapters";
import {
  createSlice6DataApiPortalDeliveryHandler,
} from "roomscan-studio-hosted-service/composition";
import {
  AesGcmPublicationFeedbackEnvelopeSealer,
} from "roomscan-studio-hosted-service/publication";

import { AwsPublicationObjectProvider } from "../aws/publication-object-provider.js";
import {
  AwsPublicationFeedbackWakePort,
} from "../aws/publication-runtime-clients.js";
import {
  AwsDataApiClient,
  AwsSqsWakePort,
} from "../aws/runtime-clients.js";
import {
  LambdaRuntimeConfigurationError,
  deriveKey,
  lazyHandler,
  readSecretValue,
  systemClock,
  systemRandom,
} from "./runtime-support.js";

type PortalDependencies = Parameters<typeof createSlice6DataApiPortalDeliveryHandler>[0];
type DataApiClient = PortalDependencies["client"];
type PortalDocument = PortalDependencies["portalDocument"];
type PortalHandler = ReturnType<typeof createSlice6DataApiPortalDeliveryHandler>;

export interface PortalDeliveryRootDependencies {
  readonly dataClient?: () => DataApiClient;
  readonly readSecret?: (arn: string, field: string) => Promise<string>;
  readonly storage?: (bucketName: string) => PublicationObjectAdapter;
  readonly feedbackWake?: (queueUrl: string) => PortalDependencies["feedbackDeliveryWake"];
  readonly portalDocument?: PortalDocument;
}

const portal = lazyHandler(async () => createPortalDeliveryRoot());

export async function handler(event: Parameters<typeof portal>[0]) {
  try { return await portal(event); } catch { return UNAVAILABLE_RESPONSE; }
}

/** PortalDelivery is a separate capability root. It has no legacy delegate,
 * project-sync credential, publication-worker wake, or generic object URL. */
export async function createPortalDeliveryRoot(
  environment: NodeJS.ProcessEnv = process.env,
  dependencies: PortalDeliveryRootDependencies = {},
): Promise<PortalHandler> {
  const config = laneConfiguration(environment, "roomscan_portal_runtime");
  const accessSecretArn = requiredSecretArn(environment, "ACCESS_TOKEN_HMAC_SECRET_ARN");
  const feedbackSecretArn = requiredSecretArn(environment, "PUBLICATION_FEEDBACK_ENVELOPE_SECRET_ARN");
  const feedbackKeyID = requiredIdentifier(environment, "PUBLICATION_FEEDBACK_KEY_ID", 3, 64, /^[A-Za-z0-9._-]+$/u);
  const publishedBucketName = requiredBucketName(environment, "PUBLISHED_BUCKET_NAME");
  const feedbackQueueURL = requiredQueueURL(environment, "MAGIC_DELIVERY_QUEUE_URL");
  const portalOrigin = requiredOrigin(environment, "PORTAL_ORIGIN");
  const portalDocument = dependencies.portalDocument ?? readPortalDocument(
    requiredIdentifier(environment, "PORTAL_ASSET_DIRECTORY", 1, 256, /^\/var\/task\/portal-assets$/u),
  );
  const [accessRoot, feedbackRoot] = await Promise.all([
    secret(dependencies, accessSecretArn, "key"),
    secret(dependencies, feedbackSecretArn, "key"),
  ]);
  const client = dependencies.dataClient?.() ?? new AwsDataApiClient({
    sender: new RDSDataClient({ region: "us-east-1" }),
    resourceArn: config.clusterArn,
    secretArn: config.roleSecretArn,
    database: "roomscan",
  });
  const storage = dependencies.storage?.(publishedBucketName) ?? new PublicationObjectAdapter(
    new AwsPublicationObjectProvider({
      sender: new S3Client({ region: "us-east-1" }),
      bucketName: publishedBucketName,
    }),
  );
  const feedbackWake = dependencies.feedbackWake?.(feedbackQueueURL)
    ?? new AwsPublicationFeedbackWakePort({
      wake: new AwsSqsWakePort({
        sender: new SQSClient({ region: "us-east-1" }),
        queueUrl: feedbackQueueURL,
        messageKind: "publication-feedback-delivery-wake-v1",
      }),
    });
  return createSlice6DataApiPortalDeliveryHandler({
    client,
    clock: Object.freeze({ now: () => new Date(systemClock.nowMs()) }),
    accessTokenHmacKey: deriveKey(accessRoot, "slice4.access-token-hmac.v1"),
    storage,
    // No portal route invokes publication allocation/completion. This
    // fail-closed stub intentionally has no publication queue authority.
    validationWake: Object.freeze({
      notifyPublicationValidationWake: async () => { throw new Error("unavailable_capability"); },
    }),
    feedbackEnvelopeSealer: new AesGcmPublicationFeedbackEnvelopeSealer({
      keyID: feedbackKeyID,
      key: deriveKey(feedbackRoot, "slice6.publication-feedback-envelope.aes-256-gcm.v1"),
      random: systemRandom,
    }),
    feedbackDeliveryWake: feedbackWake,
    portalDocument,
    portalOrigin,
  });
}

export function readPortalDocument(directory: string): PortalDocument {
  if (directory !== "/var/task/portal-assets" && !/^\/private\/tmp\/roomscan-[A-Za-z0-9._/-]{1,180}$/u.test(directory)) {
    throw invalidConfiguration();
  }
  let manifestBytes: Buffer;
  let stylesheet: Buffer;
  let script: Buffer;
  try {
    manifestBytes = readFileSync(resolve(directory, "asset-manifest.json"));
    stylesheet = readFileSync(resolve(directory, "portal.css"));
    script = readFileSync(resolve(directory, "portal.js"));
  } catch { throw invalidConfiguration(); }
  let decoded: unknown;
  try { decoded = JSON.parse(manifestBytes.toString("utf8")) as unknown; } catch { throw invalidConfiguration(); }
  if (decoded === null || typeof decoded !== "object" || Array.isArray(decoded)) throw invalidConfiguration();
  const manifest = decoded as Readonly<Record<string, unknown>>;
  if (Object.keys(manifest).sort().join(",") !== "assets,schemaVersion"
    || manifest.schemaVersion !== "roomscan-published-web-assets-v1"
    || !Array.isArray(manifest.assets) || manifest.assets.length !== 2) throw invalidConfiguration();
  const expected = new Map<string, Readonly<{ readonly bytes: Buffer; readonly mediaType: string }>>([
    ["portal.css", { bytes: stylesheet, mediaType: "text/css; charset=utf-8" }],
    ["portal.js", { bytes: script, mediaType: "text/javascript; charset=utf-8" }],
  ]);
  for (const value of manifest.assets) {
    if (value === null || typeof value !== "object" || Array.isArray(value)) throw invalidConfiguration();
    const asset = value as Readonly<Record<string, unknown>>;
    if (Object.keys(asset).sort().join(",") !== "byteCount,mediaType,path,sha256" || typeof asset.path !== "string") throw invalidConfiguration();
    const actual = expected.get(asset.path);
    if (actual === undefined || asset.byteCount !== actual.bytes.byteLength || asset.mediaType !== actual.mediaType
      || asset.sha256 !== createHash("sha256").update(actual.bytes).digest("hex")) throw invalidConfiguration();
    expected.delete(asset.path);
  }
  if (expected.size !== 0 || stylesheet.byteLength < 1 || stylesheet.byteLength > 262_144
    || script.byteLength < 1 || script.byteLength > 524_288) throw invalidConfiguration();
  return Object.freeze({ stylesheet: Uint8Array.from(stylesheet), script: Uint8Array.from(script) });
}

function laneConfiguration(environment: NodeJS.ProcessEnv, expectedRole: "roomscan_portal_runtime"): Readonly<{
  readonly clusterArn: string;
  readonly roleSecretArn: string;
}> {
  requiredIdentifier(environment, "ROOMSCAN_STAGE", 3, 10, /^(?:dev|staging|production)$/u);
  if (requiredIdentifier(environment, "ROOMSCAN_REGION", 9, 9, /^[a-z0-9-]+$/u) !== "us-east-1") throw invalidConfiguration();
  const clusterArn = requiredIdentifier(environment, "DB_CLUSTER_ARN", 1, 256, /^arn:aws:rds:us-east-1:\d{12}:cluster:[A-Za-z0-9-]{1,63}$/u);
  const roleSecretArn = requiredSecretArn(environment, "ROOMSCAN_DB_ROLE_SECRET_ARN");
  if (requiredIdentifier(environment, "ROOMSCAN_DB_RUNTIME_ROLE", 3, 64, /^[a-z][a-z0-9_]+$/u) !== expectedRole) throw invalidConfiguration();
  return Object.freeze({ clusterArn, roleSecretArn });
}

function secret(dependencies: PortalDeliveryRootDependencies, arn: string, field: string): Promise<string> {
  return dependencies.readSecret?.(arn, field) ?? readSecretValue(arn, field);
}

function requiredSecretArn(environment: NodeJS.ProcessEnv, name: string): string {
  return requiredIdentifier(environment, name, 1, 640, /^arn:aws:secretsmanager:us-east-1:\d{12}:secret:[A-Za-z0-9/_+=.@-]{1,512}$/u);
}

function requiredQueueURL(environment: NodeJS.ProcessEnv, name: string): string {
  return requiredIdentifier(environment, name, 1, 512, /^https:\/\/sqs\.us-east-1\.amazonaws\.com\/\d{12}\/[A-Za-z0-9_-]{1,80}$/u);
}

function requiredBucketName(environment: NodeJS.ProcessEnv, name: string): string {
  const value = requiredIdentifier(environment, name, 3, 63, /^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/u);
  if (value.includes("..") || /^\d+\.\d+\.\d+\.\d+$/u.test(value)) throw invalidConfiguration();
  return value;
}

function requiredOrigin(environment: NodeJS.ProcessEnv, name: string): string {
  const value = requiredIdentifier(environment, name, 12, 2_048, /^https:\/\/.+$/u);
  let url: URL;
  try { url = new URL(value); } catch { throw invalidConfiguration(); }
  if (url.protocol !== "https:" || url.username !== "" || url.password !== "" || url.pathname !== "/"
    || url.search !== "" || url.hash !== "") throw invalidConfiguration();
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

const UNAVAILABLE_RESPONSE = Object.freeze({
  statusCode: 500 as const,
  headers: Object.freeze({
    "cache-control": "no-store" as const,
    "content-type": "application/json" as const,
  }),
  body: "{\"error\":{\"code\":\"unavailable\"}}" as const,
});
