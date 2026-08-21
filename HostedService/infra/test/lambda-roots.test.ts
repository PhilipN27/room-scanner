import assert from "node:assert/strict";
import test from "node:test";

import {
  LambdaRuntimeConfigurationError,
} from "../src/functions/runtime-support.js";
import {
  createApiRoot,
  createAuditExporterRoot,
  createAuthChallengeRoot,
  createAuthorizerRoot,
  createEmailDeliveryRoot,
  createReconciliationRoot,
  createStripeWebhookRoot,
  type Slice4RootRuntimeDependencies,
} from "../src/functions/slice4-runtime-roots.js";

const account = "111111111111";
const secret = (name: string) => `arn:aws:secretsmanager:us-east-1:${account}:secret:${name}-AbCdEf`;

function environment(role: string, extra: Readonly<NodeJS.ProcessEnv> = {}): NodeJS.ProcessEnv {
  return {
    ROOMSCAN_STAGE: "dev",
    ROOMSCAN_REGION: "us-east-1",
    DB_CLUSTER_ARN: `arn:aws:rds:us-east-1:${account}:cluster:roomscan-dev`,
    ROOMSCAN_DB_ROLE_SECRET_ARN: secret(`roomscan-${role}`),
    ROOMSCAN_DB_RUNTIME_ROLE: role,
    ACCESS_TOKEN_HMAC_SECRET_ARN: secret("roomscan-access-token"),
    API_TOKEN_DERIVATION_SECRET_ARN: secret("roomscan-api-derivation"),
    MAGIC_DELIVERY_ENVELOPE_SECRET_ARN: secret("roomscan-magic-envelope"),
    APPLE_PRIVATE_KEY_SECRET_ARN: secret("roomscan-apple-private-key"),
    APPLE_CLIENT_ID: "com.example.roomscan",
    APPLE_TEAM_ID: "TEAM123456",
    APPLE_KEY_ID: "KEY1234567",
    APPLE_REDIRECT_URI: "https://api.example.invalid/auth/apple/callback",
    APPLE_CLIENT_SECRET_SIGNING_MODE: "runtime-es256-secretsmanager-v1",
    COGNITO_USER_POOL_ID: "us-east-1_TestPool",
    COGNITO_SERVER_CLIENT_ID: "abc123",
    AUTH_POLICY_VERSION: "slice4-local-test-v1",
    MAGIC_POLICY_VERSION: "slice4-local-test-v1",
    SESSION_POLICY_VERSION: "slice4-local-test-v1",
    AUTH_CHALLENGE_SECRET_ARN: secret("roomscan-auth-challenge"),
    AUTH_CHALLENGE_POLICY_VERSION: "slice4-local-test-v1",
    STRIPE_WEBHOOK_SECRET_ARN: secret("roomscan-stripe-webhook"),
    STRIPE_API_SECRET_ARN: secret("roomscan-stripe-api"),
    STRIPE_API_VERSION: "2025-06-30.basil",
    STRIPE_DEFAULT_ACCOUNT_ID: "acct_0000000000000000",
    STRIPE_PRICE_PLAN_MAP_JSON: "[{\"priceId\":\"price_test0001\",\"planKey\":\"professional-test-only\"}]",
    ROOMSCAN_POLICY_VALUES_STATUS: "local-test-values-v1",
    RAW_ENVELOPE_CONTRACT: "body+isBase64Encoded:unparsed-v1",
    STRIPE_RECONCILIATION_QUEUE_URL: `https://sqs.us-east-1.amazonaws.com/${account}/roomscan-dev-stripe-reconciliation`,
    AUDIT_OUTBOX_QUEUE_URL: `https://sqs.us-east-1.amazonaws.com/${account}/roomscan-dev-audit-outbox`,
    MAGIC_DELIVERY_QUEUE_URL: `https://sqs.us-east-1.amazonaws.com/${account}/roomscan-dev-email-delivery`,
    AUDIT_BUCKET_NAME: "roomscan-dev-audit-111111111111",
    MAGIC_DELIVERY_KEY_ID: "magic-envelope-local-test-v1",
    PUBLIC_BASE_URL: "https://api.example.invalid",
    SES_SENDER_ADDRESS: "professional@example.invalid",
    SES_IDENTITY_ARN: `arn:aws:ses:us-east-1:${account}:identity/example.invalid`,
    SES_CONFIGURATION_SET_NAME: "roomscan-transactional-dev",
    SES_MAGIC_LINK_TEMPLATE_NAME: "roomscan-dev-magic-link",
    QUARANTINE_BUCKET_NAME: "roomscan-dev-quarantine-111111111111",
    ...extra,
  };
}

function fakeRuntime(observed: { readonly roles: string[]; readonly secrets: Array<readonly [string, string]> }): Slice4RootRuntimeDependencies {
  return {
    dataClient: (role) => {
      observed.roles.push(role);
      return {
        begin: async () => ({ transactionId: "tx_1" }),
        execute: async () => ({ rows: [] }),
        commit: async () => undefined,
        rollback: async () => undefined,
      };
    },
    readSecret: async (arn, field) => {
      observed.secrets.push([arn, field]);
      return "k".repeat(64);
    },
    cognitoTransport: () => ({
      ensureExistingUser: async () => undefined,
      initiateCustomAuth: async () => ({ session: "session", selector: "A".repeat(22) }),
      respondToCustomAuthChallenge: async () => ({ outcome: "authenticated" as const }),
      linkFederatedIdentity: async () => undefined,
    }),
    stripeIngress: () => ({
      handle: async () => ({ statusCode: 200, headers: { "cache-control": "no-store", "content-type": "application/json" }, body: "{}" }),
    }),
    reconciliationWorker: () => ({ runOnce: async () => ({ status: "retry" as const, reason: "ambiguous_current_state" as const }) }),
    auditExporterWorker: () => ({ handleRecord: async (record) => record.messageId !== "audit-fail" }),
    magicDeliveryWorker: () => ({ handleRecord: async (record) => record.messageId !== "email-fail" }),
    wake: () => ({ notify: async () => undefined }),
  };
}

test("all concrete roots reject missing lane configuration before an SDK factory can run", async () => {
  const observed = { roles: [] as string[], secrets: [] as Array<readonly [string, string]> };
  await assert.rejects(
    createApiRoot({}, fakeRuntime(observed)),
    (error: unknown) => error instanceof LambdaRuntimeConfigurationError && error.code === "missing_configuration",
  );
  assert.deepEqual(observed, { roles: [], secrets: [] });

  await assert.rejects(
    createApiRoot(environment("roomscan_api_runtime", { MAGIC_DELIVERY_KEY_ID: "" }), fakeRuntime(observed)),
    (error: unknown) => error instanceof LambdaRuntimeConfigurationError && error.code === "missing_configuration",
  );
  assert.deepEqual(observed, { roles: [], secrets: [] });

  await assert.rejects(
    createReconciliationRoot(environment("roomscan_stripe_reconciliation_runtime", { STRIPE_PRICE_PLAN_MAP_JSON: "" }), fakeRuntime(observed)),
    (error: unknown) => error instanceof LambdaRuntimeConfigurationError && error.code === "missing_configuration",
  );
  assert.deepEqual(observed, { roles: [], secrets: [] });
});

test("reconciliation accepts synthetic price plans only for dev and validates the explicit Stripe API version", async () => {
  const observed = { roles: [] as string[], secrets: [] as Array<readonly [string, string]> };
  const root = (extra: Readonly<NodeJS.ProcessEnv>) => createReconciliationRoot(
    environment("roomscan_stripe_reconciliation_runtime", extra),
    fakeRuntime(observed),
  );

  await assert.rejects(
    root({ STRIPE_API_VERSION: "" }),
    (error: unknown) => error instanceof LambdaRuntimeConfigurationError && error.code === "missing_configuration",
  );
  await assert.rejects(
    root({ STRIPE_API_VERSION: "2025-06-30/basil" }),
    (error: unknown) => error instanceof LambdaRuntimeConfigurationError && error.code === "invalid_configuration",
  );
  await assert.rejects(
    root({ ROOMSCAN_POLICY_VALUES_STATUS: "" }),
    (error: unknown) => error instanceof LambdaRuntimeConfigurationError && error.code === "missing_configuration",
  );
  for (const stage of ["staging", "production"] as const) {
    await assert.rejects(
      root({ ROOMSCAN_STAGE: stage }),
      (error: unknown) => error instanceof LambdaRuntimeConfigurationError && error.code === "invalid_configuration",
    );
  }
  assert.deepEqual(observed, { roles: [], secrets: [] });

  await createReconciliationRoot(
    environment("roomscan_stripe_reconciliation_runtime"),
    fakeRuntime(observed),
  );
  assert.deepEqual(observed.roles, ["roomscan_stripe_reconciliation_runtime"]);

  const adapterObserved = { roles: [] as string[], secrets: [] as Array<readonly [string, string]> };
  const { reconciliationWorker: _ignoredWorker, ...withoutReconciliationWorker } = fakeRuntime(adapterObserved);
  const adapterInputs: Array<Parameters<NonNullable<Slice4RootRuntimeDependencies["currentSubscriptions"]>>[0]> = [];
  const handler = await createReconciliationRoot(environment("roomscan_stripe_reconciliation_runtime"), {
    ...withoutReconciliationWorker,
    currentSubscriptions: (input) => {
      adapterInputs.push(input);
      return { fetchCurrent: async () => ({ status: "ambiguous" as const }) };
    },
  });
  assert.equal(typeof handler, "function");
  assert.deepEqual(adapterInputs, [{
    stripeApiSecretArn: secret("roomscan-stripe-api"),
    apiVersion: "2025-06-30.basil",
    pricePlanMappings: [{ priceId: "price_test0001", planKey: "professional-test-only" }],
  }]);
  assert.deepEqual(adapterObserved.roles, ["roomscan_stripe_reconciliation_runtime"]);
});

test("API root builds the sealed nineteen-route service with the API lane and no Stripe secret", async () => {
  const observed = { roles: [] as string[], secrets: [] as Array<readonly [string, string]> };
  const handler = await createApiRoot(environment("roomscan_api_runtime"), fakeRuntime(observed));
  const response = await handler({
    version: "2.0",
    rawPath: "/health",
    rawQueryString: "",
    headers: {},
    requestContext: { http: { method: "GET" } },
  });
  assert.equal(response.statusCode, 200);
  assert.deepEqual(observed.roles, ["roomscan_api_runtime"]);
  assert.deepEqual(observed.secrets, [
    [secret("roomscan-access-token"), "key"],
    [secret("roomscan-api-derivation"), "key"],
    [secret("roomscan-magic-envelope"), "key"],
    [secret("roomscan-auth-challenge"), "key"],
  ]);
  assert.equal(observed.secrets.some(([arn]) => arn.includes("stripe")), false);
});

test("role-bound authorizer and Cognito roots route safe decisions instead of default placeholders", async () => {
  const authorizerObserved = { roles: [] as string[], secrets: [] as Array<readonly [string, string]> };
  const authorizer = await createAuthorizerRoot(environment("roomscan_authorizer_runtime"), fakeRuntime(authorizerObserved));
  assert.deepEqual(await authorizer({ headers: { authorization: "Bearer malformed" } }), {
    isAuthorized: false,
    context: { decision: "deny" },
  });
  assert.deepEqual(authorizerObserved.roles, ["roomscan_authorizer_runtime"]);

  const challengeObserved = { roles: [] as string[], secrets: [] as Array<readonly [string, string]> };
  const challenge = await createAuthChallengeRoot(environment("roomscan_auth_challenge_runtime"), fakeRuntime(challengeObserved));
  const event = await challenge({
    triggerSource: "DefineAuthChallenge_Authentication",
    request: { session: [] },
    response: { issueTokens: false, failAuthentication: false },
  });
  assert.deepEqual(event.response, { challengeName: "CUSTOM_CHALLENGE", issueTokens: false, failAuthentication: false });
  assert.deepEqual(challengeObserved.roles, ["roomscan_auth_challenge_runtime"]);
});

test("Stripe, reconciliation, audit, and email roots use their exact lanes and preserve SQS partial failures", async () => {
  const stripeObserved = { roles: [] as string[], secrets: [] as Array<readonly [string, string]> };
  const stripe = await createStripeWebhookRoot(environment("roomscan_stripe_ingress_runtime"), fakeRuntime(stripeObserved));
  assert.equal((await stripe({ body: "{}", isBase64Encoded: false, headers: {}, requestContext: { http: { method: "POST" } } })).statusCode, 200);
  assert.deepEqual(stripeObserved.roles, ["roomscan_stripe_ingress_runtime"]);
  assert.deepEqual(stripeObserved.secrets, [[secret("roomscan-stripe-webhook"), "key"]]);

  const reconciliationObserved = { roles: [] as string[], secrets: [] as Array<readonly [string, string]> };
  const reconciliation = await createReconciliationRoot(environment("roomscan_stripe_reconciliation_runtime"), fakeRuntime(reconciliationObserved));
  assert.deepEqual(await reconciliation({ Records: [{ messageId: "reconcile-1" }] }), {
    batchItemFailures: [{ itemIdentifier: "reconcile-1" }],
  });
  assert.deepEqual(reconciliationObserved.roles, ["roomscan_stripe_reconciliation_runtime"]);
  // The exact Stripe API secret ARN is required before construction, but the
  // injected worker deliberately avoids reading provider material in this
  // deterministic lane test.
  assert.deepEqual(reconciliationObserved.secrets, []);

  const auditObserved = { roles: [] as string[], secrets: [] as Array<readonly [string, string]> };
  const audit = await createAuditExporterRoot(environment("roomscan_audit_export_runtime"), fakeRuntime(auditObserved));
  assert.deepEqual(await audit({ Records: [{ messageId: "audit-ok" }, { messageId: "audit-fail" }] }), {
    batchItemFailures: [{ itemIdentifier: "audit-fail" }],
  });
  assert.deepEqual(auditObserved.roles, ["roomscan_audit_export_runtime"]);

  const emailObserved = { roles: [] as string[], secrets: [] as Array<readonly [string, string]> };
  const email = await createEmailDeliveryRoot(environment("roomscan_email_delivery_runtime"), fakeRuntime(emailObserved));
  assert.deepEqual(await email({ Records: [{ messageId: "email-ok" }, { messageId: "email-fail" }] }), {
    batchItemFailures: [{ itemIdentifier: "email-fail" }],
  });
  assert.deepEqual(emailObserved.roles, ["roomscan_email_delivery_runtime"]);
  assert.deepEqual(emailObserved.secrets, [[secret("roomscan-magic-envelope"), "key"]]);
});
