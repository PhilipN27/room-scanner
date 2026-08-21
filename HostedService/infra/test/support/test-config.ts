import { resolve } from "node:path";

import type { PlatformConfig } from "../../src/config.js";

export const DUMMY_ACCOUNT_ID = "444444444444";
export const DUMMY_PRODUCTION_ACCOUNT_ID = "666666666666";
export const TEST_TOPOLOGY_PATH = resolve("test/fixtures/account-topology.json");

export const VALID_ENV: Readonly<NodeJS.ProcessEnv> = {
  ROOMSCAN_ACCOUNT_ID: DUMMY_ACCOUNT_ID,
  ROOMSCAN_STAGE: "dev",
  ROOMSCAN_REGION: "us-east-1",
  ROOMSCAN_AVAILABILITY_ZONES: "us-east-1a,us-east-1b",
  ROOMSCAN_ACCOUNT_TOPOLOGY_FILE: TEST_TOPOLOGY_PATH,
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
  ROOMSCAN_AURORA_BACKUP_RETENTION_DAYS: "7"
};

export const TEST_CONFIG: PlatformConfig = {
  accountId: DUMMY_ACCOUNT_ID,
  stage: "dev",
  region: "us-east-1",
  availabilityZones: ["us-east-1a", "us-east-1b"],
  accountTopology: {
    management: "111111111111",
    logArchive: "222222222222",
    securityAudit: "333333333333",
    dev: DUMMY_ACCOUNT_ID,
    staging: "555555555555",
    production: DUMMY_PRODUCTION_ACCOUNT_ID
  },
  operatorOwner: "roomscan-platform-owner",
  notificationEmail: "platform-alerts@example.invalid",
  serviceDomain: "api.example.invalid",
  cognitoDomainPrefix: "roomscan-dev-professional-auth",
  magicDeliveryKeyId: "magic-envelope-local-test-v1",
  providerSecretsKmsKeyArn:
    "arn:aws:kms:us-east-1:444444444444:key/00000000-0000-4000-8000-000000000001",
  apple: {
    clientId: "invalid.example.roomscan.service",
    teamId: "TESTTEAM01",
    keyId: "TESTKEY001",
    privateKeySecretArn:
      "arn:aws:secretsmanager:us-east-1:444444444444:secret:roomscan-apple-reference-000001"
  },
  stripe: {
    webhookSecretArn:
      "arn:aws:secretsmanager:us-east-1:444444444444:secret:roomscan-stripe-webhook-reference-000001",
    apiSecretArn:
      "arn:aws:secretsmanager:us-east-1:444444444444:secret:roomscan-stripe-api-reference-000001",
    defaultAccountId: "acct_0000000000000000",
    apiVersion: "2025-06-30.basil",
    pricePlanMappings: [{ priceId: "price_test0001", planKey: "professional-test-only" }],
    policyValuesStatus: "local-test-values-v1"
  },
  ses: {
    identityArn: "arn:aws:ses:us-east-1:444444444444:identity/example.invalid",
    configurationSetName: "roomscan-transactional-dev",
    senderAddress: "professional@example.invalid"
  },
  aurora: {
    minimumAcu: 0.5,
    maximumAcu: 2,
    backupRetentionDays: 7
  }
};

export function productionTestConfig(): PlatformConfig {
  return {
    ...TEST_CONFIG,
    accountId: DUMMY_PRODUCTION_ACCOUNT_ID,
    stage: "production",
    cognitoDomainPrefix: "roomscan-production-professional-auth",
    apple: {
      ...TEST_CONFIG.apple,
      privateKeySecretArn:
        "arn:aws:secretsmanager:us-east-1:666666666666:secret:roomscan-apple-reference-000001"
    },
    stripe: {
      webhookSecretArn:
        "arn:aws:secretsmanager:us-east-1:666666666666:secret:roomscan-stripe-webhook-reference-000001",
      apiSecretArn:
        "arn:aws:secretsmanager:us-east-1:666666666666:secret:roomscan-stripe-api-reference-000001",
      defaultAccountId: TEST_CONFIG.stripe.defaultAccountId,
      apiVersion: TEST_CONFIG.stripe.apiVersion,
      pricePlanMappings: [],
      policyValuesStatus: "owner-policy-unconfigured-v1"
    },
    providerSecretsKmsKeyArn:
      "arn:aws:kms:us-east-1:666666666666:key/00000000-0000-4000-8000-000000000006",
    ses: {
      ...TEST_CONFIG.ses,
      identityArn: "arn:aws:ses:us-east-1:666666666666:identity/example.invalid",
      configurationSetName: "roomscan-transactional-production",
      senderAddress: TEST_CONFIG.ses.senderAddress
    }
  };
}
