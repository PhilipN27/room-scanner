import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import test from "node:test";

import { App } from "aws-cdk-lib";
import { Template } from "aws-cdk-lib/assertions";

import { cdkAvailabilityZonesContext } from "../src/config.js";
import { RoomScanPlatformStack } from "../src/stacks/platform-stack.js";
import { TEST_CONFIG } from "./support/test-config.js";

type Resource = {
  readonly Type: string;
  readonly Properties?: Readonly<Record<string, unknown>>;
};

const EXPECTED_ROUTES = new Map<string, "NONE" | "CUSTOM">([
  ["GET /health", "NONE"],
  ["POST /auth/magic-link/request", "NONE"],
  ["POST /auth/magic-link/candidate/request", "CUSTOM"],
  ["GET /auth/magic-link/{selector}", "NONE"],
  ["POST /auth/magic-link/consume", "NONE"],
  ["POST /auth/magic-link/completion/redeem", "NONE"],
  ["POST /auth/apple/begin", "NONE"],
  ["POST /auth/apple/finish", "NONE"],
  ["POST /auth/session/refresh", "NONE"],
  ["POST /billing/stripe/webhook", "NONE"],
  ["POST /auth/apple/candidate/begin", "CUSTOM"],
  ["POST /auth/session/logout", "CUSTOM"],
  ["POST /workspace/bootstrap", "CUSTOM"],
  ["POST /workspace/activate", "CUSTOM"],
  ["GET /workspace", "CUSTOM"],
  ["GET /membership", "CUSTOM"],
  ["GET /subscription", "CUSTOM"],
  ["GET /quota", "CUSTOM"],
  ["POST /identity/mutate", "CUSTOM"],
]);

const EXPECTED_RUNTIME_SECRETS = new Map<string, string>([
  ["roomscan-dev-app-authorizer", "roomscan_authorizer_runtime"],
  ["roomscan-dev-api", "roomscan_api_runtime"],
  ["roomscan-dev-auth-challenge", "roomscan_auth_challenge_runtime"],
  ["roomscan-dev-stripe-ingress", "roomscan_stripe_ingress_runtime"],
  ["roomscan-dev-stripe-reconciliation", "roomscan_stripe_reconciliation_runtime"],
  ["roomscan-dev-audit-exporter", "roomscan_audit_export_runtime"],
  ["roomscan-dev-email-delivery", "roomscan_email_delivery_runtime"],
]);

let cached: Readonly<Record<string, Resource>> | undefined;

function resources(): Readonly<Record<string, Resource>> {
  if (cached !== undefined) return cached;
  const app = new App({ context: cdkAvailabilityZonesContext(TEST_CONFIG) });
  const stack = new RoomScanPlatformStack(app, "Task6dCompositionFixture", {
    config: TEST_CONFIG,
    env: { account: TEST_CONFIG.accountId, region: TEST_CONFIG.region },
  });
  const template = Template.fromStack(stack).toJSON() as {
    readonly Resources: Readonly<Record<string, Resource>>;
  };
  cached = template.Resources;
  return cached;
}

function ofType(type: string): readonly [string, Resource][] {
  return Object.entries(resources()).filter(([, resource]) => resource.Type === type);
}

function functionByName(name: string): Resource {
  const entry = ofType("AWS::Lambda::Function").find(
    ([, resource]) => resource.Properties?.FunctionName === name,
  );
  assert.ok(entry !== undefined, `missing Lambda ${name}`);
  return entry[1];
}

function policyByPrefix(prefix: string): Resource {
  const entry = ofType("AWS::IAM::Policy").find(([logicalId]) => logicalId.startsWith(prefix));
  assert.ok(entry !== undefined, `missing policy ${prefix}`);
  return entry[1];
}

function environmentOf(resource: Resource): Readonly<Record<string, unknown>> {
  const environment = resource.Properties?.Environment as {
    readonly Variables?: Readonly<Record<string, unknown>>;
  } | undefined;
  return environment?.Variables ?? {};
}

test("Task 6D synthesizes exactly the canonical 19 public/protected routes with no proxy", () => {
  const routes = ofType("AWS::ApiGatewayV2::Route").map(([, resource]) => resource);
  assert.equal(routes.length, EXPECTED_ROUTES.size);
  const actual = new Map(
    routes.map((route) => [
      String(route.Properties?.RouteKey),
      String(route.Properties?.AuthorizationType),
    ]),
  );
  assert.deepEqual(actual, EXPECTED_ROUTES);
  assert.equal([...actual.keys()].some((key) => key.includes("ANY") || key.includes("proxy")), false);
  for (const [routeKey, authorization] of actual) {
    const route = routes.find((candidate) => candidate.Properties?.RouteKey === routeKey)!;
    if (authorization === "CUSTOM") assert.ok(route.Properties?.AuthorizerId !== undefined);
    else assert.equal(route.Properties?.AuthorizerId, undefined);
  }
});

test("Task 6D splits confidential Apple federation from secretless IAM custom auth", () => {
  const clients = ofType("AWS::Cognito::UserPoolClient").map(([, resource]) => resource.Properties ?? {});
  assert.equal(clients.length, 2);
  const federation = clients.find((client) => client.GenerateSecret === true);
  const custom = clients.find((client) => client.GenerateSecret === false);
  assert.ok(federation !== undefined);
  assert.ok(custom !== undefined);
  assert.deepEqual(federation.AllowedOAuthFlows, ["code"]);
  assert.deepEqual(federation.SupportedIdentityProviders, ["SignInWithApple"]);
  assert.deepEqual(custom.ExplicitAuthFlows, ["ALLOW_CUSTOM_AUTH"]);
  assert.equal("AllowedOAuthFlows" in custom, false);
  assert.equal("CallbackURLs" in custom, false);
  assert.doesNotMatch(JSON.stringify(custom), /PASSWORD|SRP|ALLOW_REFRESH_TOKEN_AUTH/u);

  const apiPolicy = JSON.stringify(policyByPrefix("PrivateApiPolicy").Properties?.PolicyDocument);
  for (const action of [
    "cognito-idp:AdminGetUser",
    "cognito-idp:AdminCreateUser",
    "cognito-idp:AdminLinkProviderForUser",
    "cognito-idp:AdminInitiateAuth",
    "cognito-idp:AdminRespondToAuthChallenge",
  ]) assert.match(apiPolicy, new RegExp(action, "u"));
  assert.doesNotMatch(apiPolicy, /ListUsers|AdminSetUserPassword/u);
  const apiEnvironment = environmentOf(functionByName("roomscan-dev-api"));
  assert.ok(apiEnvironment.COGNITO_SERVER_CLIENT_ID !== undefined);
  assert.equal("COGNITO_CLIENT_SECRET" in apiEnvironment, false);
  assert.equal("COGNITO_SECRET_HASH" in apiEnvironment, false);
});

test("Task 6D contains no Slice 7 backup/restore parameter or runtime placeholder marker", () => {
  const serialized = JSON.stringify(resources());
  assert.doesNotMatch(serialized, /slice7-backup-restore|Slice7BackupRestoreGate/u);
  assert.doesNotMatch(serialized, /integration_not_configured|not_configured|service_integration_not_configured/u);
});

test("Task 6D generates one attached database secret per runtime lane and isolates every Lambda", () => {
  const secretEntries = ofType("AWS::SecretsManager::Secret");
  const databaseUsernames = secretEntries.flatMap(([, secret]) => {
    const generated = secret.Properties?.GenerateSecretString as {
      readonly SecretStringTemplate?: string;
    } | undefined;
    if (generated?.SecretStringTemplate === undefined) return [];
    const template = JSON.parse(generated.SecretStringTemplate) as { readonly username?: string };
    return template.username === undefined ? [] : [template.username];
  });
  assert.deepEqual(new Set(databaseUsernames), new Set([
    "roomscan_cluster_admin",
    ...EXPECTED_RUNTIME_SECRETS.values(),
  ]));
  assert.equal(databaseUsernames.length, 8);

  for (const [functionName, username] of EXPECTED_RUNTIME_SECRETS) {
    const variables = environmentOf(functionByName(functionName));
    assert.ok(variables.ROOMSCAN_DB_ROLE_SECRET_ARN !== undefined, functionName);
    assert.equal(variables.ROOMSCAN_DB_RUNTIME_ROLE, username, functionName);
    assert.ok(variables.DB_CLUSTER_ARN !== undefined, functionName);
    assert.equal("DB_RUNTIME_SECRET_ARN" in variables, false, functionName);
    assert.equal("DB_OWNER_SECRET_ARN" in variables, false, functionName);
  }

  const migrationVariables = environmentOf(functionByName("roomscan-dev-migration-operator"));
  assert.ok(migrationVariables.DB_OWNER_SECRET_ARN !== undefined);
  assert.equal("ROOMSCAN_DB_ROLE_SECRET_ARN" in migrationVariables, false);
  assert.equal("DB_RUNTIME_SECRET_ARN" in migrationVariables, false);

  const serialized = JSON.stringify(resources());
  assert.doesNotMatch(serialized, /DB_RUNTIME_SECRET_ARN|"username":"roomscan_app"/u);
});

test("Task 6D gives Stripe ingress durable Data API authority and removes active/published reads from API", () => {
  const stripePolicy = JSON.stringify(policyByPrefix("StripeIngressPolicy").Properties?.PolicyDocument);
  for (const action of [
    "rds-data:BeginTransaction",
    "rds-data:ExecuteStatement",
    "rds-data:CommitTransaction",
    "rds-data:RollbackTransaction",
  ]) assert.match(stripePolicy, new RegExp(action, "u"));
  assert.match(stripePolicy, /StripeIngressDatabaseSecret/u);

  const apiPolicy = JSON.stringify(policyByPrefix("PrivateApiPolicy").Properties?.PolicyDocument);
  assert.match(apiPolicy, /s3:PutObject/u);
  assert.match(apiPolicy, /QuarantineBucket/u);
  assert.doesNotMatch(apiPolicy, /s3:GetObject|ActiveBucket|PublishedDerivativeBucket/u);
});

test("Task 6D keeps refresh on API, Apple session issuance on challenge, and credential bootstrap owner-only", () => {
  const apiEnvironment = JSON.stringify(environmentOf(functionByName("roomscan-dev-api")));
  const challengeEnvironment = JSON.stringify(environmentOf(functionByName("roomscan-dev-auth-challenge")));
  assert.match(apiEnvironment, /ApiDatabaseSecret/u);
  assert.doesNotMatch(apiEnvironment, /AuthChallengeDatabaseSecret/u);
  assert.match(challengeEnvironment, /AuthChallengeDatabaseSecret/u);
  assert.doesNotMatch(challengeEnvironment, /ApiDatabaseSecret/u);

  const migrationPolicy = JSON.stringify(policyByPrefix("MigrationOperatorPolicy").Properties?.PolicyDocument);
  assert.match(migrationPolicy, /DatabaseOwnerSecret/u);
  for (const runtimePrefix of [
    "ApiDatabaseSecret",
    "AuthorizerDatabaseSecret",
    "AuthChallengeDatabaseSecret",
    "StripeIngressDatabaseSecret",
    "StripeReconciliationDatabaseSecret",
    "AuditExportDatabaseSecret",
    "EmailDeliveryDatabaseSecret",
  ]) assert.match(migrationPolicy, new RegExp(runtimePrefix, "u"));

  const migrationEnvironment = JSON.stringify(environmentOf(functionByName("roomscan-dev-migration-operator")));
  assert.match(migrationEnvironment, /MIGRATION_MANIFEST_SHA256/u);
  assert.match(migrationEnvironment, /RUNTIME_ROLE_SECRET_ARNS_JSON/u);
  assert.match(migrationEnvironment, /roomscan_email_delivery_runtime/u);
  assert.doesNotMatch(migrationEnvironment, /password|secretString|credentialValue/ui);
});

test("Task 6D migration operator is one-shot direct PostgreSQL in isolated subnets with pinned real assets", () => {
  const migration = functionByName("roomscan-dev-migration-operator");
  const variables = environmentOf(migration);
  const manifestHash = createHash("sha256")
    .update(readFileSync(resolve("assets/migration-manifest.json")))
    .digest("hex");

  assert.equal(migration.Properties?.Runtime, "nodejs24.x");
  assert.equal(migration.Properties?.Timeout, 900);
  assert.equal(migration.Properties?.ReservedConcurrentExecutions, 1);
  const vpcConfig = migration.Properties?.VpcConfig as {
    readonly SecurityGroupIds?: readonly unknown[];
    readonly SubnetIds?: readonly unknown[];
  } | undefined;
  assert.equal(vpcConfig?.SecurityGroupIds?.length, 1);
  assert.equal(vpcConfig?.SubnetIds?.length, 2);

  assert.ok(variables.DB_HOST !== undefined);
  assert.equal(variables.DB_PORT, "5432");
  assert.equal(variables.DB_NAME, "roomscan");
  assert.equal(variables.MIGRATIONS_PATH, "/var/task/migration-assets/migrations");
  assert.equal(variables.MIGRATION_RUNNER_PATH, "/var/task/migration-assets/migrate.mjs");
  assert.equal(variables.MIGRATION_MANIFEST_PATH, "/var/task/migration-assets/migration-manifest.json");
  assert.equal(variables.RDS_CA_BUNDLE_PATH, "/var/task/migration-assets/rds-global-bundle.pem");
  assert.equal(variables.MIGRATION_MANIFEST_SHA256, manifestHash);
  assert.equal("DB_CLUSTER_ARN" in variables, false);
  assert.equal("EXPECTED_MIGRATION_LEDGER_JSON" in variables, false);

  const migrationPolicy = JSON.stringify(policyByPrefix("MigrationOperatorPolicy").Properties?.PolicyDocument);
  assert.doesNotMatch(migrationPolicy, /rds-data:/u);
  for (const action of [
    "ec2:CreateNetworkInterface",
    "ec2:DescribeNetworkInterfaces",
    "ec2:DeleteNetworkInterface",
    "secretsmanager:GetSecretValue",
  ]) assert.match(migrationPolicy, new RegExp(action, "u"));

  const endpoints = ofType("AWS::EC2::VPCEndpoint").map(([, resource]) => resource.Properties ?? {});
  assert.equal(endpoints.some((endpoint) =>
    endpoint.VpcEndpointType === "Interface"
    && endpoint.PrivateDnsEnabled === true
    && JSON.stringify(endpoint.ServiceName).includes("secretsmanager")), true);
});

test("Task 6D wires every validated API and reconciliation input with only the approved application-secret shares", () => {
  const api = environmentOf(functionByName("roomscan-dev-api"));
  const challenge = environmentOf(functionByName("roomscan-dev-auth-challenge"));
  const authorizer = environmentOf(functionByName("roomscan-dev-app-authorizer"));
  const reconciliation = environmentOf(functionByName("roomscan-dev-stripe-reconciliation"));
  const email = environmentOf(functionByName("roomscan-dev-email-delivery"));

  assert.match(JSON.stringify(api.AUTH_CHALLENGE_SECRET_ARN), /AuthChallengeProofSecret/u);
  assert.match(JSON.stringify(challenge.AUTH_CHALLENGE_SECRET_ARN), /AuthChallengeProofSecret/u);
  assert.equal("AUTH_CHALLENGE_SECRET_ARN" in authorizer, false);
  assert.equal("AUTH_CHALLENGE_SECRET_ARN" in reconciliation, false);
  assert.equal("AUTH_CHALLENGE_SECRET_ARN" in email, false);

  assert.match(JSON.stringify(api.MAGIC_DELIVERY_ENVELOPE_SECRET_ARN), /MagicDeliveryEnvelopeSecret/u);
  assert.match(JSON.stringify(email.MAGIC_DELIVERY_ENVELOPE_SECRET_ARN), /MagicDeliveryEnvelopeSecret/u);
  assert.equal(api.MAGIC_DELIVERY_KEY_ID, TEST_CONFIG.magicDeliveryKeyId);
  assert.equal(email.MAGIC_DELIVERY_KEY_ID, TEST_CONFIG.magicDeliveryKeyId);
  assert.equal("MAGIC_DELIVERY_ENVELOPE_SECRET_ARN" in challenge, false);
  assert.equal("MAGIC_DELIVERY_ENVELOPE_SECRET_ARN" in authorizer, false);
  assert.equal("MAGIC_DELIVERY_ENVELOPE_SECRET_ARN" in reconciliation, false);

  assert.equal(reconciliation.STRIPE_API_VERSION, TEST_CONFIG.stripe.apiVersion);
  assert.equal(
    reconciliation.STRIPE_PRICE_PLAN_MAP_JSON,
    JSON.stringify(TEST_CONFIG.stripe.pricePlanMappings),
  );
  assert.equal(reconciliation.ROOMSCAN_POLICY_VALUES_STATUS, "local-test-values-v1");
});

test("Task 6D gives email delivery only its DB lane, envelope key, SES, and wake queue", () => {
  const environment = JSON.stringify(environmentOf(functionByName("roomscan-dev-email-delivery")));
  assert.match(environment, /EmailDeliveryDatabaseSecret/u);
  assert.match(environment, /MagicDeliveryEnvelopeSecret/u);
  assert.doesNotMatch(environment, /ApiDatabaseSecret|AuthChallengeDatabaseSecret|StripeIngressDatabaseSecret/u);
  const policy = JSON.stringify(policyByPrefix("EmailDeliveryPolicy").Properties?.PolicyDocument);
  assert.match(policy, /EmailDeliveryDatabaseSecret/u);
  assert.match(policy, /MagicDeliveryEnvelopeSecret/u);
  assert.match(policy, /ses:SendEmail/u);
  assert.doesNotMatch(policy, /s3:GetObject|ActiveBucket|PublishedDerivativeBucket|ApiDatabaseSecret/u);
});

test("Task 6D schedules durable reconciliation, audit, and email recovery in addition to CloudTrail monitoring", () => {
  const rules = ofType("AWS::Events::Rule").map(([, resource]) => resource);
  assert.equal(rules.length, 4);
  const names = rules.map((rule) => String(rule.Properties?.Name));
  assert.ok(names.includes("roomscan-dev-stripe-reconciliation-recovery"));
  assert.ok(names.includes("roomscan-dev-audit-outbox-recovery"));
  assert.ok(names.includes("roomscan-dev-email-delivery-recovery"));
  const recoveryRules = rules.filter((rule) => String(rule.Properties?.Name).includes("recovery"));
  assert.equal(recoveryRules.every((rule) => JSON.stringify(rule.Properties?.Targets).includes("Queue")), true);
});
