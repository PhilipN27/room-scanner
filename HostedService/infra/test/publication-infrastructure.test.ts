import assert from "node:assert/strict";
import test from "node:test";

import { App } from "aws-cdk-lib";
import { Template } from "aws-cdk-lib/assertions";

import { cdkAvailabilityZonesContext } from "../src/config.js";
import { RoomScanPlatformStack } from "../src/stacks/platform-stack.js";
import { TEST_CONFIG } from "./support/test-config.js";

type Resource = Readonly<{
  readonly Type: string;
  readonly Properties?: Readonly<Record<string, unknown>>;
}>;

let cached: Readonly<Record<string, Resource>> | undefined;

function resources(): Readonly<Record<string, Resource>> {
  if (cached !== undefined) return cached;
  const app = new App({ context: cdkAvailabilityZonesContext(TEST_CONFIG) });
  const stack = new RoomScanPlatformStack(app, "Slice6PublicationInfrastructureFixture", {
    config: TEST_CONFIG,
    env: { account: TEST_CONFIG.accountId, region: TEST_CONFIG.region },
  });
  const template = Template.fromStack(stack).toJSON() as {
    readonly Resources: Readonly<Record<string, Resource>>;
  };
  cached = template.Resources;
  return cached;
}

function entries(type: string): readonly [string, Resource][] {
  return Object.entries(resources()).filter(([, resource]) => resource.Type === type);
}

function functionBySuffix(suffix: string): readonly [string, Resource] {
  const match = entries("AWS::Lambda::Function").find(([, resource]) =>
    typeof resource.Properties?.FunctionName === "string"
      && resource.Properties.FunctionName.endsWith(suffix));
  assert.notEqual(match, undefined, `missing Lambda ${suffix}`);
  return match!;
}

function policyByPrefix(prefix: string): Resource {
  const match = entries("AWS::IAM::Policy").find(([logicalID]) => logicalID.startsWith(prefix));
  assert.notEqual(match, undefined, `missing policy ${prefix}`);
  return match![1];
}

function environmentOf(resource: Resource): Readonly<Record<string, unknown>> {
  const environment = resource.Properties?.Environment as {
    readonly Variables?: Readonly<Record<string, unknown>>;
  } | undefined;
  return environment?.Variables ?? {};
}

test("Slice 6 synthesizes the exact additive runtime, credential, and queue topology", () => {
  assert.equal(entries("AWS::Lambda::Function").length, 12);
  assert.equal(entries("AWS::SQS::Queue").length, 10, "five primary/DLQ pairs only");

  const usernames = entries("AWS::SecretsManager::Secret").flatMap(([, resource]) => {
    const generated = resource.Properties?.GenerateSecretString as { readonly SecretStringTemplate?: string } | undefined;
    if (generated?.SecretStringTemplate === undefined) return [];
    const decoded = JSON.parse(generated.SecretStringTemplate) as { readonly username?: string };
    return decoded.username === undefined ? [] : [decoded.username];
  });
  assert.deepEqual(new Set(usernames), new Set([
    "roomscan_cluster_admin",
    "roomscan_api_runtime",
    "roomscan_authorizer_runtime",
    "roomscan_auth_challenge_runtime",
    "roomscan_stripe_ingress_runtime",
    "roomscan_stripe_reconciliation_runtime",
    "roomscan_audit_export_runtime",
    "roomscan_email_delivery_runtime",
    "roomscan_project_sync_runtime",
    "roomscan_publication_worker",
    "roomscan_portal_runtime",
  ]));

  const [, worker] = functionBySuffix("-publication-validation");
  const [, portal] = functionBySuffix("-portal-delivery");
  assert.equal(environmentOf(worker).ROOMSCAN_DB_RUNTIME_ROLE, "roomscan_publication_worker");
  assert.equal(environmentOf(portal).ROOMSCAN_DB_RUNTIME_ROLE, "roomscan_portal_runtime");
  assert.match(JSON.stringify(environmentOf(portal).PORTAL_ASSET_DIRECTORY), /portal-assets/u);
  assert.equal(worker.Properties?.ReservedConcurrentExecutions, 1);

  const publicationQueue = entries("AWS::SQS::Queue").find(([logicalID]) => logicalID.startsWith("PublicationValidationQueue"));
  const publicationDLQ = entries("AWS::SQS::Queue").find(([logicalID]) => logicalID.startsWith("PublicationValidationDlq"));
  assert.notEqual(publicationQueue, undefined);
  assert.notEqual(publicationDLQ, undefined);
  assert.ok(Number(publicationQueue![1].Properties?.VisibilityTimeout) > Number(worker.Properties?.Timeout));
  assert.match(JSON.stringify(publicationQueue![1].Properties?.RedrivePolicy), new RegExp(publicationDLQ![0], "u"));
});

test("Slice 6 routes exactly 45 private, 9 portal-delivery, and 1 Stripe route with no proxy", () => {
  const integrations = new Map(entries("AWS::ApiGatewayV2::Integration").map(([logicalID, resource]) => [logicalID, resource]));
  assert.equal(integrations.size, 3);
  const counts = { privateApi: 0, portalDelivery: 0, stripe: 0 };
  for (const [, route] of entries("AWS::ApiGatewayV2::Route")) {
    const routeKey = String(route.Properties?.RouteKey);
    assert.doesNotMatch(routeKey, /ANY|proxy/u);
    const target = JSON.stringify(route.Properties?.Target);
    const integrationID = [...integrations.keys()].find((logicalID) => target.includes(logicalID));
    assert.notEqual(integrationID, undefined, routeKey);
    const integration = integrations.get(integrationID!);
    assert.notEqual(integration, undefined, routeKey);
    const uri = JSON.stringify(integration!.Properties?.IntegrationUri);
    if (uri.includes("PrivateApiLiveAlias")) counts.privateApi += 1;
    else if (uri.includes("PortalDeliveryLiveAlias")) counts.portalDelivery += 1;
    else if (uri.includes("StripeIngressLiveAlias")) counts.stripe += 1;
    else assert.fail(`unrecognized integration for ${routeKey}`);
  }
  assert.deepEqual(counts, { privateApi: 45, portalDelivery: 9, stripe: 1 });
});

test("Slice 6 publication IAM is prefix-exact, non-destructive, and keeps API/portal/worker capabilities disjoint", () => {
  const api = JSON.stringify(policyByPrefix("PrivateApiPolicy").Properties?.PolicyDocument);
  const portal = JSON.stringify(policyByPrefix("PortalDeliveryPolicy").Properties?.PolicyDocument);
  const worker = JSON.stringify(policyByPrefix("PublicationValidationPolicy").Properties?.PolicyDocument);

  assert.match(api, /server\/published\/quarantine\/v1\/\*/u);
  assert.doesNotMatch(api, /server\/published\/active\/v1\/|s3:List|s3:Delete/u);

  assert.match(portal, /server\/published\/active\/v1\/\*/u);
  assert.match(portal, /s3:GetObjectVersion/u);
  assert.doesNotMatch(portal, /server\/published\/quarantine\/v1\/|s3:PutObject|s3:List|s3:Delete/u);

  assert.match(worker, /server\/published\/quarantine\/v1\/\*/u);
  assert.match(worker, /server\/published\/active\/v1\/\*/u);
  assert.match(worker, /s3:GetObjectVersion|s3:PutObject/u);
  assert.doesNotMatch(worker, /ProjectSyncBucket|ActiveBucket|BackupBucket|s3:List|s3:Delete/u);
});

test("Slice 6 remains one private origin with no CDN, public asset bucket, or browser identity pool", () => {
  assert.equal(entries("AWS::CloudFront::Distribution").length, 0);
  assert.equal(entries("AWS::Cognito::IdentityPool").length, 0);
  assert.equal(entries("AWS::ApiGatewayV2::Api").length, 1);
  assert.equal(entries("AWS::S3::Bucket").length, 6);
});
