import { spawnSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const infrastructureRoot = resolve(scriptDirectory, "..");

const OFFLINE_ROOMSCAN_ENVIRONMENT = Object.freeze({
  ROOMSCAN_ACCOUNT_ID: "444444444444",
  ROOMSCAN_STAGE: "dev",
  ROOMSCAN_REGION: "us-east-1",
  ROOMSCAN_AVAILABILITY_ZONES: "us-east-1a,us-east-1b",
  ROOMSCAN_ACCOUNT_TOPOLOGY_FILE: resolve(infrastructureRoot, "test/fixtures/account-topology.json"),
  ROOMSCAN_OPERATOR_OWNER: "roomscan-platform-owner",
  ROOMSCAN_NOTIFICATION_EMAIL: "platform-alerts@example.invalid",
  ROOMSCAN_SERVICE_DOMAIN: "api.example.invalid",
  ROOMSCAN_COGNITO_DOMAIN_PREFIX: "roomscan-dev-professional-auth",
  ROOMSCAN_APPLE_CLIENT_ID: "invalid.example.roomscan.service",
  ROOMSCAN_APPLE_TEAM_ID: "TESTTEAM01",
  ROOMSCAN_APPLE_KEY_ID: "TESTKEY001",
  ROOMSCAN_APPLE_PRIVATE_KEY_SECRET_ARN:
    "arn:aws:secretsmanager:us-east-1:444444444444:secret:roomscan-apple-reference-000001",
  ROOMSCAN_PROVIDER_SECRETS_KMS_KEY_ARN:
    "arn:aws:kms:us-east-1:444444444444:key/00000000-0000-4000-8000-000000000001",
  ROOMSCAN_STRIPE_WEBHOOK_SECRET_ARN:
    "arn:aws:secretsmanager:us-east-1:444444444444:secret:roomscan-stripe-webhook-reference-000001",
  ROOMSCAN_STRIPE_API_SECRET_ARN:
    "arn:aws:secretsmanager:us-east-1:444444444444:secret:roomscan-stripe-api-reference-000001",
  ROOMSCAN_STRIPE_DEFAULT_ACCOUNT_ID: "acct_0000000000000000",
  ROOMSCAN_STRIPE_API_VERSION: "2025-06-30.basil",
  ROOMSCAN_STRIPE_PRICE_PLAN_MAP_JSON:
    "[{\"priceId\":\"price_test0001\",\"planKey\":\"professional-test-only\"}]",
  ROOMSCAN_MAGIC_DELIVERY_KEY_ID: "magic-envelope-local-test-v1",
  ROOMSCAN_POLICY_VALUES_STATUS: "local-test-values-v1",
  ROOMSCAN_SES_IDENTITY_ARN:
    "arn:aws:ses:us-east-1:444444444444:identity/example.invalid",
  ROOMSCAN_SES_CONFIGURATION_SET_NAME: "roomscan-transactional-dev",
  ROOMSCAN_SES_SENDER_ADDRESS: "professional@example.invalid",
  ROOMSCAN_AURORA_MIN_ACU: "0.5",
  ROOMSCAN_AURORA_MAX_ACU: "2",
  ROOMSCAN_AURORA_BACKUP_RETENTION_DAYS: "7",
});

export function createOfflineEnvironment(source) {
  const sanitized = {};
  for (const [name, value] of Object.entries(source)) {
    if (value === undefined
      || name.startsWith("ROOMSCAN_")
      || name.startsWith("AWS_")
      || name.startsWith("CDK_")) continue;
    sanitized[name] = value;
  }
  return Object.freeze({
    ...sanitized,
    ...OFFLINE_ROOMSCAN_ENVIRONMENT,
    AWS_EC2_METADATA_DISABLED: "true",
    AWS_REGION: "us-east-1",
    AWS_DEFAULT_REGION: "us-east-1",
    CDK_DEFAULT_ACCOUNT: "444444444444",
    CDK_DEFAULT_REGION: "us-east-1",
    CDK_DISABLE_VERSION_CHECK: "1",
    npm_config_offline: "true",
    npm_config_audit: "false",
    npm_config_fund: "false",
  });
}

function environmentSummary(environment) {
  const roomscan = {};
  for (const name of Object.keys(OFFLINE_ROOMSCAN_ENVIRONMENT).sort()) {
    roomscan[name] = environment[name];
  }
  const retainedAwsOrCdk = Object.keys(environment)
    .filter((name) => (name.startsWith("AWS_") || name.startsWith("CDK_"))
      && ![
        "AWS_DEFAULT_REGION",
        "AWS_EC2_METADATA_DISABLED",
        "AWS_REGION",
        "CDK_DEFAULT_ACCOUNT",
        "CDK_DEFAULT_REGION",
        "CDK_DISABLE_VERSION_CHECK",
      ].includes(name))
    .sort();
  return Object.freeze({ roomscan, retainedAwsOrCdk });
}

function runNpm(script, environment) {
  const result = spawnSync("npm", ["run", script], {
    cwd: infrastructureRoot,
    env: environment,
    stdio: "inherit",
  });
  if (result.error !== undefined) throw result.error;
  if (result.signal !== null || result.status !== 0) {
    throw new Error(`offline verification step failed: ${script}`);
  }
}

if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const environment = createOfflineEnvironment(process.env);
  if (process.argv[2] === "--print-environment") {
    process.stdout.write(`${JSON.stringify(environmentSummary(environment))}\n`);
  } else {
    for (const script of [
      "build:service",
      "typecheck",
      "test:local",
      "test:mutations",
      "synth:local",
      "inspect:synth",
    ]) runNpm(script, environment);
  }
}
