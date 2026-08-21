import assert from "node:assert/strict";
import test from "node:test";
import { resolve } from "node:path";

import { cdkAvailabilityZonesContext, loadPlatformConfig } from "../src/config.js";
import {
  DUMMY_ACCOUNT_ID,
  TEST_TOPOLOGY_PATH,
  VALID_ENV
} from "./support/test-config.js";

test("configuration accepts one explicit dummy account and maps it to the selected topology stage", () => {
  const config = loadPlatformConfig({ ...VALID_ENV });
  assert.equal(config.accountId, DUMMY_ACCOUNT_ID);
  assert.equal(config.accountTopology.dev, DUMMY_ACCOUNT_ID);
  assert.equal(config.region, "us-east-1");
  assert.deepEqual(config.availabilityZones, ["us-east-1a", "us-east-1b"]);
  assert.deepEqual(cdkAvailabilityZonesContext(config), {
    "availability-zones:account=444444444444:region=us-east-1": [
      "us-east-1a",
      "us-east-1b"
    ]
  });
  assert.equal(config.aurora.minimumAcu, 0.5);
  assert.equal(config.aurora.maximumAcu, 2);
  assert.equal(config.aurora.backupRetentionDays, 7);
  assert.equal(config.stripe.defaultAccountId, "acct_0000000000000000");
  assert.equal(config.stripe.apiVersion, "2025-06-30.basil");
  assert.deepEqual(config.stripe.pricePlanMappings, [
    { priceId: "price_test0001", planKey: "professional-test-only" },
  ]);
  assert.equal(config.stripe.policyValuesStatus, "local-test-values-v1");
  assert.equal(config.magicDeliveryKeyId, "magic-envelope-local-test-v1");
  assert.equal(config.ses.senderAddress, "professional@example.invalid");
  assert.equal(
    (config as unknown as { readonly cognitoDomainPrefix?: string }).cognitoDomainPrefix,
    "roomscan-dev-professional-auth",
  );
  assert.equal(
    (config as unknown as { readonly providerSecretsKmsKeyArn?: string })
      .providerSecretsKmsKeyArn,
    VALID_ENV.ROOMSCAN_PROVIDER_SECRETS_KMS_KEY_ARN,
  );
});

for (const missing of [
  "ROOMSCAN_ACCOUNT_ID",
  "ROOMSCAN_STAGE",
  "ROOMSCAN_REGION",
  "ROOMSCAN_AVAILABILITY_ZONES",
  "ROOMSCAN_ACCOUNT_TOPOLOGY_FILE",
  "ROOMSCAN_OPERATOR_OWNER",
  "ROOMSCAN_NOTIFICATION_EMAIL",
  "ROOMSCAN_SERVICE_DOMAIN",
  "ROOMSCAN_COGNITO_DOMAIN_PREFIX",
  "ROOMSCAN_APPLE_CLIENT_ID",
  "ROOMSCAN_APPLE_TEAM_ID",
  "ROOMSCAN_APPLE_KEY_ID",
  "ROOMSCAN_APPLE_PRIVATE_KEY_SECRET_ARN",
  "ROOMSCAN_PROVIDER_SECRETS_KMS_KEY_ARN",
  "ROOMSCAN_STRIPE_WEBHOOK_SECRET_ARN",
  "ROOMSCAN_STRIPE_API_SECRET_ARN",
  "ROOMSCAN_STRIPE_DEFAULT_ACCOUNT_ID",
  "ROOMSCAN_STRIPE_API_VERSION",
  "ROOMSCAN_STRIPE_PRICE_PLAN_MAP_JSON",
  "ROOMSCAN_MAGIC_DELIVERY_KEY_ID",
  "ROOMSCAN_POLICY_VALUES_STATUS",
  "ROOMSCAN_SES_IDENTITY_ARN",
  "ROOMSCAN_SES_CONFIGURATION_SET_NAME",
  "ROOMSCAN_SES_SENDER_ADDRESS",
  "ROOMSCAN_AURORA_MIN_ACU",
  "ROOMSCAN_AURORA_MAX_ACU",
  "ROOMSCAN_AURORA_BACKUP_RETENTION_DAYS"
] as const) {
  test(`configuration fails closed when ${missing} is absent`, () => {
    const environment = { ...VALID_ENV };
    delete environment[missing];
    assert.throws(() => loadPlatformConfig(environment), new RegExp(missing, "u"));
  });
}

test("configuration rejects every region other than us-east-1", () => {
  assert.throws(
    () => loadPlatformConfig({ ...VALID_ENV, ROOMSCAN_REGION: "us-west-2" }),
    /us-east-1/u,
  );
});

test("configuration rejects unavailable, duplicate, or malformed availability zones", () => {
  for (const value of ["us-east-1a", "us-east-1a,us-east-1a", "us-west-2a,us-west-2b"]) {
    assert.throws(
      () => loadPlatformConfig({ ...VALID_ENV, ROOMSCAN_AVAILABILITY_ZONES: value }),
      /two distinct.*us-east-1/u,
    );
  }
});

test("configuration rejects an account that does not match the selected topology stage", () => {
  assert.throws(
    () => loadPlatformConfig({ ...VALID_ENV, ROOMSCAN_ACCOUNT_ID: "777777777777" }),
    /selected stage account/u,
  );
});

test("configuration rejects an unavailable account topology file", () => {
  assert.throws(
    () => loadPlatformConfig({ ...VALID_ENV, ROOMSCAN_ACCOUNT_TOPOLOGY_FILE: `${TEST_TOPOLOGY_PATH}.missing` }),
    /account topology/u,
  );
});

test("configuration rejects concrete malformed, extra-key, duplicate-account, and stage-mismatch topology fixtures", () => {
  for (const [fixture, expected] of [
    ["account-topology-malformed.json", /readable account topology JSON/u],
    ["account-topology-extra-key.json", /must contain exactly/u],
    ["account-topology-duplicate-account.json", /account IDs must be distinct/u],
    ["account-topology-stage-mismatch.json", /selected stage account/u]
  ] as const) {
    assert.throws(
      () => loadPlatformConfig({
        ...VALID_ENV,
        ROOMSCAN_ACCOUNT_TOPOLOGY_FILE: resolve("test/fixtures", fixture)
      }),
      expected,
      fixture,
    );
  }
});

test("configuration rejects invalid Aurora capacity increments and backup retention", () => {
  assert.throws(
    () => loadPlatformConfig({ ...VALID_ENV, ROOMSCAN_AURORA_MIN_ACU: "0.6" }),
    /0.5 ACU increments/u,
  );
  assert.throws(
    () => loadPlatformConfig({ ...VALID_ENV, ROOMSCAN_AURORA_BACKUP_RETENTION_DAYS: "36" }),
    /1 and 35/u,
  );
});

test("configuration rejects malformed Stripe default accounts and SES sender addresses", () => {
  for (const value of ["", "cus_12345678", "acct_short", "acct_contains-dash"]) {
    assert.throws(
      () => loadPlatformConfig({ ...VALID_ENV, ROOMSCAN_STRIPE_DEFAULT_ACCOUNT_ID: value }),
      /ROOMSCAN_STRIPE_DEFAULT_ACCOUNT_ID/u,
    );
  }
  for (const value of ["", "not-an-address", "sender@invalid", `${"a".repeat(255)}@example.invalid`]) {
    assert.throws(
      () => loadPlatformConfig({ ...VALID_ENV, ROOMSCAN_SES_SENDER_ADDRESS: value }),
      /ROOMSCAN_SES_SENDER_ADDRESS/u,
    );
  }
});

test("configuration validates an explicit Stripe schema and dev-only synthetic plan mapping", () => {
  for (const value of ["", "latest", "2025-06-30/basil", "2025-6-30.basil"]) {
    assert.throws(
      () => loadPlatformConfig({ ...VALID_ENV, ROOMSCAN_STRIPE_API_VERSION: value }),
      /ROOMSCAN_STRIPE_API_VERSION/u,
      value,
    );
  }
  for (const value of [
    "[]",
    "not-json",
    "[{\"priceId\":\"price_test0001\",\"planKey\":\"professional-test-only\",\"extra\":true}]",
    "[{\"priceId\":\"price_test0001\",\"planKey\":\"one\"},{\"priceId\":\"price_test0001\",\"planKey\":\"two\"}]",
  ]) {
    assert.throws(
      () => loadPlatformConfig({ ...VALID_ENV, ROOMSCAN_STRIPE_PRICE_PLAN_MAP_JSON: value }),
      /ROOMSCAN_STRIPE_PRICE_PLAN_MAP_JSON/u,
      value,
    );
  }
  assert.throws(
    () => loadPlatformConfig({ ...VALID_ENV, ROOMSCAN_POLICY_VALUES_STATUS: "owner-policy-unconfigured-v1" }),
    /ROOMSCAN_POLICY_VALUES_STATUS/u,
  );
});

test("staging and production accept only an empty Stripe mapping with owner policy values unconfigured", () => {
  for (const [stage, accountId] of [
    ["staging", "555555555555"],
    ["production", "666666666666"],
  ] as const) {
    const environment = {
      ...VALID_ENV,
      ROOMSCAN_ACCOUNT_ID: accountId,
      ROOMSCAN_STAGE: stage,
      ROOMSCAN_COGNITO_DOMAIN_PREFIX: `roomscan-${stage}-professional-auth`,
      ROOMSCAN_APPLE_PRIVATE_KEY_SECRET_ARN:
        `arn:aws:secretsmanager:us-east-1:${accountId}:secret:roomscan-apple-reference-000001`,
      ROOMSCAN_PROVIDER_SECRETS_KMS_KEY_ARN:
        `arn:aws:kms:us-east-1:${accountId}:key/00000000-0000-4000-8000-000000000001`,
      ROOMSCAN_STRIPE_WEBHOOK_SECRET_ARN:
        `arn:aws:secretsmanager:us-east-1:${accountId}:secret:roomscan-stripe-webhook-reference-000001`,
      ROOMSCAN_STRIPE_API_SECRET_ARN:
        `arn:aws:secretsmanager:us-east-1:${accountId}:secret:roomscan-stripe-api-reference-000001`,
      ROOMSCAN_SES_IDENTITY_ARN:
        `arn:aws:ses:us-east-1:${accountId}:identity/example.invalid`,
      ROOMSCAN_STRIPE_PRICE_PLAN_MAP_JSON: "[]",
      ROOMSCAN_POLICY_VALUES_STATUS: "owner-policy-unconfigured-v1",
    };
    const config = loadPlatformConfig(environment);
    assert.deepEqual(config.stripe.pricePlanMappings, [], stage);
    assert.equal(config.stripe.policyValuesStatus, "owner-policy-unconfigured-v1", stage);

    assert.throws(
      () => loadPlatformConfig({
        ...environment,
        ROOMSCAN_STRIPE_PRICE_PLAN_MAP_JSON:
          '[{"priceId":"price_live000001","planKey":"professional-live"}]',
      }),
      /ROOMSCAN_STRIPE_PRICE_PLAN_MAP_JSON/u,
      `${stage} must reject non-empty plan mappings`,
    );
    assert.throws(
      () => loadPlatformConfig({
        ...environment,
        ROOMSCAN_POLICY_VALUES_STATUS: "local-test-values-v1",
      }),
      /ROOMSCAN_POLICY_VALUES_STATUS/u,
      `${stage} must reject local synthetic policy status`,
    );
  }
});

test("configuration rejects identity and provider references outside the workload account and region", () => {
  assert.throws(
    () => loadPlatformConfig({
      ...VALID_ENV,
      ROOMSCAN_APPLE_PRIVATE_KEY_SECRET_ARN:
        "arn:aws:secretsmanager:us-west-2:444444444444:secret:wrong-region"
    }),
    /same workload account and us-east-1/u,
  );
  assert.throws(
    () => loadPlatformConfig({
      ...VALID_ENV,
      ROOMSCAN_SES_IDENTITY_ARN:
        "arn:aws:ses:us-east-1:777777777777:identity/example.invalid"
    }),
    /same workload account and us-east-1/u,
  );
  assert.throws(
    () => loadPlatformConfig({
      ...VALID_ENV,
      ROOMSCAN_PROVIDER_SECRETS_KMS_KEY_ARN:
        "arn:aws:kms:us-west-2:444444444444:key/00000000-0000-4000-8000-000000000001"
    }),
    /same workload account and us-east-1/u,
  );
});

test("configuration rejects empty, trailing, wrong-resource, and unbounded SES identity ARNs", () => {
  for (const value of [
    "arn:aws:ses:us-east-1:444444444444:identity/",
    "arn:aws:ses:us-east-1:444444444444:identity/example.invalid:trailing",
    "arn:aws:ses:us-east-1:444444444444:configuration-set/roomscan-transactional-dev",
    `arn:aws:ses:us-east-1:444444444444:identity/${"a".repeat(321)}`,
    "arn:aws-cn:ses:us-east-1:444444444444:identity/example.invalid"
  ]) {
    assert.throws(
      () => loadPlatformConfig({ ...VALID_ENV, ROOMSCAN_SES_IDENTITY_ARN: value }),
      /ROOMSCAN_SES_IDENTITY_ARN/u,
      value,
    );
  }
});

test("configuration requires complete Secrets Manager ARNs with a name and six-character suffix", () => {
  for (const [name, value] of [
    [
      "ROOMSCAN_APPLE_PRIVATE_KEY_SECRET_ARN",
      "arn:aws:secretsmanager:us-east-1:444444444444:secret:"
    ],
    [
      "ROOMSCAN_APPLE_PRIVATE_KEY_SECRET_ARN",
      "arn:aws:secretsmanager:us-east-1:444444444444:secret:roomscan-apple-reference"
    ],
    [
      "ROOMSCAN_STRIPE_WEBHOOK_SECRET_ARN",
      "arn:aws:secretsmanager:us-east-1:444444444444:parameter/roomscan-stripe-webhook-reference-000001"
    ],
    [
      "ROOMSCAN_STRIPE_API_SECRET_ARN",
      "arn:aws:secretsmanager:us-east-1:444444444444:secret:roomscan-stripe-api-reference-000001:AWSCURRENT"
    ],
    [
      "ROOMSCAN_STRIPE_API_SECRET_ARN",
      "arn:aws:secretsmanager:us-west-2:444444444444:secret:roomscan-stripe-api-reference-000001"
    ],
    [
      "ROOMSCAN_STRIPE_API_SECRET_ARN",
      "arn:aws:secretsmanager:us-east-1:777777777777:secret:roomscan-stripe-api-reference-000001"
    ]
  ] as const) {
    assert.throws(
      () => loadPlatformConfig({ ...VALID_ENV, [name]: value }),
      new RegExp(name, "u"),
      `${name}: ${value}`,
    );
  }
});

test("configuration accepts only an exact KMS key UUID ARN and rejects aliases or trailing resources", () => {
  for (const value of [
    "arn:aws:kms:us-east-1:444444444444:key/",
    "arn:aws:kms:us-east-1:444444444444:key/not-a-uuid",
    "arn:aws:kms:us-east-1:444444444444:alias/roomscan-provider-secrets",
    "arn:aws:kms:us-east-1:444444444444:key/00000000-0000-4000-8000-000000000001:trailing",
    "arn:aws-cn:kms:us-east-1:444444444444:key/00000000-0000-4000-8000-000000000001",
    "arn:aws:s3:us-east-1:444444444444:key/00000000-0000-4000-8000-000000000001"
  ]) {
    assert.throws(
      () => loadPlatformConfig({ ...VALID_ENV, ROOMSCAN_PROVIDER_SECRETS_KMS_KEY_ARN: value }),
      /ROOMSCAN_PROVIDER_SECRETS_KMS_KEY_ARN/u,
      value,
    );
  }
});

test("configuration rejects malformed AWS-managed Cognito domain prefixes", () => {
  for (const value of [
    "Uppercase",
    "-leading-hyphen",
    "trailing-hyphen-",
    "contains.dot",
    "a".repeat(64)
  ]) {
    assert.throws(
      () => loadPlatformConfig({ ...VALID_ENV, ROOMSCAN_COGNITO_DOMAIN_PREFIX: value }),
      /ROOMSCAN_COGNITO_DOMAIN_PREFIX/u,
    );
  }
});
