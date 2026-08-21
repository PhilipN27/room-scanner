import assert from "node:assert/strict";
import test from "node:test";

import { App } from "aws-cdk-lib";
import { Template } from "aws-cdk-lib/assertions";

import { cdkAvailabilityZonesContext } from "../src/config.js";
import { assertInfrastructurePolicy } from "../src/policy/template-policy.js";
import { RoomScanPlatformStack } from "../src/stacks/platform-stack.js";
import { productionTestConfig, TEST_CONFIG } from "./support/test-config.js";

type CloudFormationResource = Readonly<{
  Type: string;
  Properties?: Readonly<Record<string, unknown>>;
  DeletionPolicy?: string;
  UpdateReplacePolicy?: string;
}>;

const synthesisCache = new Map<
  string,
  {
    readonly template: Readonly<Record<string, unknown>>;
    readonly resources: Readonly<Record<string, CloudFormationResource>>;
  }
>();

function synthesize(config = TEST_CONFIG): {
  readonly template: Readonly<Record<string, unknown>>;
  readonly resources: Readonly<Record<string, CloudFormationResource>>;
} {
  const cacheKey = JSON.stringify(config);
  const cached = synthesisCache.get(cacheKey);
  if (cached !== undefined) {
    return cached;
  }
  const app = new App({ context: cdkAvailabilityZonesContext(config) });
  const stack = new RoomScanPlatformStack(app, `RoomScanPlatform-${config.stage}`, {
    config,
    env: { account: config.accountId, region: config.region }
  });
  const template = Template.fromStack(stack).toJSON() as Readonly<Record<string, unknown>>;
  const resources = template.Resources as Readonly<Record<string, CloudFormationResource>>;
  const synthesized = { template, resources };
  synthesisCache.set(cacheKey, synthesized);
  return synthesized;
}

function resourcesOfType(
  resources: Readonly<Record<string, CloudFormationResource>>,
  type: string,
): readonly CloudFormationResource[] {
  return Object.values(resources).filter((resource) => resource.Type === type);
}

function policyDocumentStatements(
  resource: CloudFormationResource,
): readonly Readonly<Record<string, unknown>>[] {
  const document = resource.Properties?.PolicyDocument as {
    readonly Statement?: readonly Readonly<Record<string, unknown>>[];
  };
  return document.Statement ?? [];
}

function isEncryptionOverrideDenied(
  policy: CloudFormationResource,
  headers: Readonly<Record<string, unknown>>,
): boolean {
  return policyDocumentStatements(policy).some((statement) => {
    if (
      statement.Effect !== "Deny" ||
      !(JSON.stringify(statement.Action) ?? "").includes("s3:PutObject") ||
      !(JSON.stringify(statement.Condition) ?? "").includes("s3:x-amz-server-side-encryption")
    ) {
      return false;
    }
    const condition = statement.Condition as Readonly<Record<string, unknown>>;
    return Object.entries(condition).every(([operator, rawOperands]) => {
      const operands = rawOperands as Readonly<Record<string, unknown>>;
      return Object.entries(operands).every(([key, expected]) => {
        const present = Object.hasOwn(headers, key);
        const actual = headers[key];
        if (operator === "Null") {
          return String(expected) === String(!present);
        }
        if (operator === "StringEquals") {
          return present && JSON.stringify(actual) === JSON.stringify(expected);
        }
        if (operator === "StringNotEquals") {
          return !present || JSON.stringify(actual) !== JSON.stringify(expected);
        }
        return false;
      });
    });
  });
}

test("security and observability synthesize rotating KMS keys, encrypted retained logs, CloudTrail data events, digest validation, and notifications", () => {
  const { template, resources } = synthesize();
  const keys = resourcesOfType(resources, "AWS::KMS::Key");
  assert.equal(keys.length, 6);
  assert.equal(keys.every((key) => key.Properties?.EnableKeyRotation === true), true);
  assert.equal(keys.every((key) => key.DeletionPolicy === "Retain"), true);
  const logGroups = resourcesOfType(resources, "AWS::Logs::LogGroup");
  assert.equal(logGroups.length, 12);
  assert.equal(
    logGroups.every((group) =>
      typeof group.Properties?.RetentionInDays === "number" &&
      group.Properties.KmsKeyId !== undefined &&
      group.DeletionPolicy === "Retain"
    ),
    true,
  );
  const trails = resourcesOfType(resources, "AWS::CloudTrail::Trail");
  assert.equal(trails.length, 1);
  assert.equal(trails[0]?.Properties?.EnableLogFileValidation, true);
  assert.equal(resourcesOfType(resources, "AWS::SNS::Subscription").length, 1);
  assert.ok(resourcesOfType(resources, "AWS::CloudWatch::Alarm").length >= 19);
  assert.match(JSON.stringify(template), /AWS::S3::Object/u);
  assert.match(JSON.stringify(template), /EnableLogFileValidation/u);
});

test("every Lambda log group uses LogsKey and the regional Logs service has the complete account-bounded KMS policy", () => {
  const { resources } = synthesize();
  const lambdaLogGroups = resourcesOfType(resources, "AWS::Logs::LogGroup").filter((group) =>
    typeof group.Properties?.LogGroupName === "string" &&
    group.Properties.LogGroupName.startsWith("/aws/lambda/")
  );
  assert.equal(lambdaLogGroups.length, 9);
  for (const group of lambdaLogGroups) {
    const keyReference = JSON.stringify(group.Properties?.KmsKeyId);
    assert.match(keyReference, /LogsKey/u);
    assert.doesNotMatch(keyReference, /SecretsKey/u);
  }

  const logsKey = Object.entries(resources).find(
    ([logicalId, resource]) => resource.Type === "AWS::KMS::Key" && logicalId.startsWith("LogsKey"),
  );
  assert.ok(logsKey !== undefined);
  const statements = ((logsKey[1].Properties?.KeyPolicy as {
    readonly Statement?: readonly Readonly<Record<string, unknown>>[];
  }).Statement ?? []);
  const logsServiceStatement = statements.find((statement) =>
    JSON.stringify(statement.Principal).includes("logs.us-east-1.amazonaws.com"),
  );
  assert.ok(logsServiceStatement !== undefined);
  const actions = [...(logsServiceStatement.Action as readonly string[])].sort();
  assert.deepEqual(actions, [
    "kms:Decrypt",
    "kms:DescribeKey",
    "kms:Encrypt",
    "kms:GenerateDataKey",
    "kms:GenerateDataKeyWithoutPlaintext",
    "kms:ReEncryptFrom",
    "kms:ReEncryptTo"
  ]);
  const condition = JSON.stringify(logsServiceStatement.Condition);
  assert.match(condition, /kms:EncryptionContext:aws:logs:arn/u);
  assert.match(condition, /:logs:us-east-1:444444444444:log-group:\/aws\/\*/u);
});

test("five S3 boundaries are private, versioned, bucket-owner enforced, KMS encrypted, TLS-only, server-prefixed, and retained", () => {
  const { template, resources } = synthesize(productionTestConfig());
  const buckets = resourcesOfType(resources, "AWS::S3::Bucket");
  assert.equal(buckets.length, 5);
  for (const bucket of buckets) {
    assert.equal(bucket.DeletionPolicy, "Retain");
    assert.equal(bucket.UpdateReplacePolicy, "Retain");
    const properties = bucket.Properties ?? {};
    assert.deepEqual(properties.VersioningConfiguration, { Status: "Enabled" });
    assert.deepEqual(properties.OwnershipControls, {
      Rules: [{ ObjectOwnership: "BucketOwnerEnforced" }]
    });
    assert.deepEqual(properties.PublicAccessBlockConfiguration, {
      BlockPublicAcls: true,
      BlockPublicPolicy: true,
      IgnorePublicAcls: true,
      RestrictPublicBuckets: true
    });
    assert.match(JSON.stringify(properties.BucketEncryption), /aws:kms/u);
  }
  assert.ok(resourcesOfType(resources, "AWS::S3::BucketPolicy").length >= 5);
  assert.equal(resourcesOfType(resources, "Custom::S3AutoDeleteObjects").length, 0);
  const cluster = resourcesOfType(resources, "AWS::RDS::DBCluster")[0];
  assert.equal(cluster?.Properties?.DeletionProtection, true);
  assert.equal(cluster?.DeletionPolicy, "Retain");
  assert.doesNotThrow(() => assertInfrastructurePolicy(template));
});

test("the audit lifecycle bounds each version to at most 400 days and denies caller-driven deletion", () => {
  const { resources } = synthesize(productionTestConfig());
  const auditEntry = Object.entries(resources).find(
    ([logicalId, resource]) => resource.Type === "AWS::S3::Bucket" && logicalId.startsWith("AuditBucket"),
  );
  assert.ok(auditEntry !== undefined);
  const lifecycle = auditEntry[1].Properties?.LifecycleConfiguration as {
    readonly Rules?: readonly {
      readonly ExpirationInDays?: number;
      readonly NoncurrentVersionExpiration?: { readonly NoncurrentDays?: number };
    }[];
  };
  const retention = lifecycle.Rules?.find((rule) => rule.ExpirationInDays !== undefined);
  assert.ok(retention?.ExpirationInDays !== undefined);
  assert.ok(retention.NoncurrentVersionExpiration?.NoncurrentDays !== undefined);
  assert.ok(retention.ExpirationInDays > 0);
  assert.ok(retention.NoncurrentVersionExpiration.NoncurrentDays > 0);
  assert.ok(
    retention.ExpirationInDays + retention.NoncurrentVersionExpiration.NoncurrentDays <= 400,
  );

  const auditPolicy = Object.values(resources).find(
    (resource) => resource.Type === "AWS::S3::BucketPolicy" &&
      JSON.stringify(resource.Properties?.Bucket).includes(auditEntry[0]),
  );
  assert.ok(auditPolicy !== undefined);
  const deleteDeny = policyDocumentStatements(auditPolicy).find((statement) =>
    statement.Effect === "Deny" &&
    JSON.stringify(statement.Principal) === "{\"AWS\":\"*\"}" &&
    JSON.stringify(statement.Action).includes("s3:DeleteObjectVersion"),
  );
  assert.ok(deleteDeny !== undefined);
  assert.match(JSON.stringify(deleteDeny.Action), /s3:DeleteObject/u);
  assert.match(JSON.stringify(deleteDeny.Action), /s3:DeleteBucket/u);
});

test("every bucket allows default or its exact CMK headers and denies AES256, aws-managed KMS, and wrong-CMK overrides", () => {
  const { resources } = synthesize();
  for (const [logicalId, bucket] of Object.entries(resources).filter(
    ([, resource]) => resource.Type === "AWS::S3::Bucket",
  )) {
    const policy = Object.values(resources).find(
      (resource) => resource.Type === "AWS::S3::BucketPolicy" &&
        JSON.stringify(resource.Properties?.Bucket).includes(logicalId),
    );
    assert.ok(policy !== undefined, logicalId);
    const kmsKey = (bucket.Properties?.BucketEncryption as {
      readonly ServerSideEncryptionConfiguration?: readonly {
        readonly ServerSideEncryptionByDefault?: { readonly KMSMasterKeyID?: unknown };
      }[];
    }).ServerSideEncryptionConfiguration?.[0]?.ServerSideEncryptionByDefault?.KMSMasterKeyID;
    assert.ok(kmsKey !== undefined, logicalId);
    assert.equal(isEncryptionOverrideDenied(policy, {}), false, `${logicalId}: default encryption`);
    assert.equal(isEncryptionOverrideDenied(policy, {
      "s3:x-amz-server-side-encryption": "aws:kms",
      "s3:x-amz-server-side-encryption-aws-kms-key-id": kmsKey
    }), false, `${logicalId}: exact CMK`);
    assert.equal(isEncryptionOverrideDenied(policy, {
      "s3:x-amz-server-side-encryption": "AES256"
    }), true, `${logicalId}: AES256`);
    assert.equal(isEncryptionOverrideDenied(policy, {
      "s3:x-amz-server-side-encryption": "aws:kms"
    }), true, `${logicalId}: aws-managed KMS fallback`);
    assert.equal(isEncryptionOverrideDenied(policy, {
      "s3:x-amz-server-side-encryption": "aws:kms",
      "s3:x-amz-server-side-encryption-aws-kms-key-id":
        "arn:aws:kms:us-east-1:444444444444:key/99999999-9999-4999-8999-999999999999"
    }), true, `${logicalId}: wrong CMK`);
  }
});

test("Aurora is PostgreSQL 16.8 Serverless v2 with Data API, private networking, KMS, TLS enforcement, and seven separated runtime secrets", () => {
  const { template, resources } = synthesize();
  const clusters = resourcesOfType(resources, "AWS::RDS::DBCluster");
  assert.equal(clusters.length, 1);
  const cluster = clusters[0];
  assert.ok(cluster !== undefined);
  assert.equal(cluster.Properties?.Engine, "aurora-postgresql");
  assert.equal(cluster.Properties?.EngineVersion, "16.8");
  assert.equal(cluster.Properties?.EnableHttpEndpoint, true);
  assert.equal(cluster.Properties?.StorageEncrypted, true);
  assert.deepEqual(cluster.Properties?.ServerlessV2ScalingConfiguration, {
    MinCapacity: 0.5,
    MaxCapacity: 2
  });
  assert.equal(resourcesOfType(resources, "AWS::RDS::DBInstance")[0]?.Properties?.PubliclyAccessible, false);
  assert.equal(resourcesOfType(resources, "AWS::EC2::NatGateway").length, 0);
  assert.equal(resourcesOfType(resources, "AWS::EC2::InternetGateway").length, 0);
  assert.equal(resourcesOfType(resources, "AWS::SecretsManager::Secret").length, 12);
  assert.match(JSON.stringify(template), /rds\.force_ssl/u);
  assert.match(JSON.stringify(template), /roomscan_cluster_admin/u);
  for (const username of [
    "roomscan_api_runtime",
    "roomscan_authorizer_runtime",
    "roomscan_auth_challenge_runtime",
    "roomscan_stripe_ingress_runtime",
    "roomscan_stripe_reconciliation_runtime",
    "roomscan_audit_export_runtime",
    "roomscan_email_delivery_runtime"
  ]) assert.match(JSON.stringify(template), new RegExp(username, "u"));
  assert.doesNotMatch(JSON.stringify(template), /"username":"roomscan_app"/u);
  assert.doesNotMatch(JSON.stringify(template), /"username":"roomscan_owner"/u);
  assert.doesNotMatch(JSON.stringify(template), /Slice7BackupRestoreGate|slice7-backup-restore/u);
  assert.equal(resourcesOfType(resources, "AWS::EC2::VPCEndpoint").length, 1);
});

test("Cognito exposes custom auth only, prevents enumeration, uses a short session, disables password and implicit fallback, and resolves Apple secret by reference", () => {
  const { template, resources } = synthesize();
  const clients = resourcesOfType(resources, "AWS::Cognito::UserPoolClient");
  assert.equal(clients.length, 2);
  const custom = clients.find((client) => client.Properties?.GenerateSecret === false)?.Properties ?? {};
  const federation = clients.find((client) => client.Properties?.GenerateSecret === true)?.Properties ?? {};
  assert.equal(custom.PreventUserExistenceErrors, "ENABLED");
  assert.equal(custom.AuthSessionValidity, 3);
  assert.deepEqual(custom.ExplicitAuthFlows, ["ALLOW_CUSTOM_AUTH"]);
  assert.equal("AllowedOAuthFlows" in custom, false);
  assert.equal("CallbackURLs" in custom, false);
  assert.equal("RefreshTokenValidity" in custom, false);
  assert.equal(custom.GenerateSecret, false);
  assert.deepEqual(federation.RefreshTokenRotation, {
    Feature: "ENABLED",
    RetryGracePeriodSeconds: 0
  });
  assert.equal(federation.GenerateSecret, true);
  assert.deepEqual(federation.AllowedOAuthFlows, ["code"]);
  assert.doesNotMatch(JSON.stringify(clients), /ALLOW_REFRESH_TOKEN_AUTH|PASSWORD|SRP/u);
  const serialized = JSON.stringify(template);
  assert.match(serialized, /DefineAuthChallenge/u);
  assert.match(serialized, /CreateAuthChallenge/u);
  assert.match(serialized, /VerifyAuthChallengeResponse/u);
  assert.match(serialized, /resolve:secretsmanager/u);
  assert.doesNotMatch(serialized, /-----BEGIN (?:EC |RSA )?PRIVATE KEY-----/u);
});

test("Cognito Apple federation has one AWS-managed bridge domain and returns only to the app-owned API callback", () => {
  const { template, resources } = synthesize();
  const domains = resourcesOfType(resources, "AWS::Cognito::UserPoolDomain");
  assert.equal(domains.length, 1);
  assert.equal(domains[0]?.Properties?.Domain, "roomscan-dev-professional-auth");
  assert.match(JSON.stringify(domains[0]?.Properties?.UserPoolId), /ProfessionalUserPool/u);
  assert.equal("CustomDomainConfig" in (domains[0]?.Properties ?? {}), false);

  const providers = resourcesOfType(resources, "AWS::Cognito::UserPoolIdentityProvider");
  assert.equal(providers.length, 1);
  assert.equal(providers[0]?.Properties?.ProviderName, "SignInWithApple");
  const clients = resourcesOfType(resources, "AWS::Cognito::UserPoolClient");
  assert.equal(clients.length, 2);
  const client = clients.find((candidate) => candidate.Properties?.GenerateSecret === true)?.Properties ?? {};
  assert.deepEqual(client.AllowedOAuthFlows, ["code"]);
  assert.deepEqual(client.CallbackURLs, ["https://api.example.invalid/auth/apple/callback"]);
  assert.deepEqual(client.SupportedIdentityProviders, ["SignInWithApple"]);
  assert.doesNotMatch(JSON.stringify(client), /implicit|PASSWORD|SRP/u);

  const outputs = template.Outputs as Readonly<Record<string, unknown>>;
  assert.match(JSON.stringify(outputs.AppleFederationAuthorizeEndpoint), /oauth2\/authorize/u);
  assert.match(JSON.stringify(outputs.AppleIdentityProviderCallbackUrl), /oauth2\/idpresponse/u);
  assert.match(
    JSON.stringify(outputs.AppleIdentityProviderCallbackUrl),
    /ProfessionalUserPoolProfessionalFederationDomain.*\.auth\.us-east-1\.amazoncognito\.com/u,
  );
});

test("full synthesis rejects invalid external resource ARN grammar even when callers bypass the environment loader", () => {
  const cases = [
    {
      name: "empty SES identity resource",
      config: {
        ...TEST_CONFIG,
        ses: {
          ...TEST_CONFIG.ses,
          identityArn: "arn:aws:ses:us-east-1:444444444444:identity/"
        }
      },
      expected: /ROOMSCAN_SES_IDENTITY_ARN/u
    },
    {
      name: "trailing secret qualifier",
      config: {
        ...TEST_CONFIG,
        apple: {
          ...TEST_CONFIG.apple,
          privateKeySecretArn:
            "arn:aws:secretsmanager:us-east-1:444444444444:secret:roomscan-apple-reference-000001:AWSCURRENT"
        }
      },
      expected: /ROOMSCAN_APPLE_PRIVATE_KEY_SECRET_ARN/u
    },
    {
      name: "wrong Secrets Manager resource",
      config: {
        ...TEST_CONFIG,
        stripe: {
          ...TEST_CONFIG.stripe,
          webhookSecretArn:
            "arn:aws:secretsmanager:us-east-1:444444444444:parameter/roomscan-stripe-webhook-reference-000001"
        }
      },
      expected: /ROOMSCAN_STRIPE_WEBHOOK_SECRET_ARN/u
    },
    {
      name: "KMS alias instead of immutable key UUID",
      config: {
        ...TEST_CONFIG,
        providerSecretsKmsKeyArn:
          "arn:aws:kms:us-east-1:444444444444:alias/roomscan-provider-secrets"
      },
      expected: /ROOMSCAN_PROVIDER_SECRETS_KMS_KEY_ARN/u
    }
  ] as const;

  for (const fixture of cases) {
    assert.throws(() => synthesize(fixture.config), fixture.expected, fixture.name);
  }
});

test("HTTP API v2 exposes the exact 19-route manifest, authorizes ten protected routes, and keeps Stripe dedicated and unmapped", () => {
  const { resources } = synthesize();
  const integrations = resourcesOfType(resources, "AWS::ApiGatewayV2::Integration");
  assert.equal(integrations.length, 2);
  for (const integration of integrations) {
    assert.equal(integration.Properties?.PayloadFormatVersion, "2.0");
    assert.equal("RequestParameters" in (integration.Properties ?? {}), false);
  }
  const routes = resourcesOfType(resources, "AWS::ApiGatewayV2::Route");
  assert.equal(routes.length, 19);
  assert.equal(routes.filter((route) => route.Properties?.AuthorizationType === "CUSTOM").length, 10);
  assert.equal(routes.filter((route) => route.Properties?.AuthorizationType === "NONE").length, 9);
  assert.equal(routes.some((route) => /ANY|proxy/u.test(String(route.Properties?.RouteKey))), false);
  const stripeRoute = routes.find(
    (route) => route.Properties?.RouteKey === "POST /billing/stripe/webhook",
  );
  assert.equal(stripeRoute?.Properties?.AuthorizationType, "NONE");
  assert.equal("AuthorizerId" in (stripeRoute?.Properties ?? {}), false);
});

test("Stripe reconciliation, audit outbox, and email queues have KMS, bounded retention, retry/DLQ controls, consumers, and alarms", () => {
  const { resources } = synthesize();
  const queues = resourcesOfType(resources, "AWS::SQS::Queue");
  assert.equal(queues.length, 6);
  assert.equal(queues.filter((queue) => queue.Properties?.RedrivePolicy !== undefined).length, 3);
  for (const queue of queues) {
    assert.ok(queue.Properties?.KmsMasterKeyId !== undefined);
    assert.ok(Number(queue.Properties?.MessageRetentionPeriod) <= 1_209_600);
    assert.equal(queue.DeletionPolicy, "Retain");
  }
  assert.equal(resourcesOfType(resources, "AWS::Lambda::EventSourceMapping").length, 3);
  assert.ok(resourcesOfType(resources, "AWS::CloudWatch::Alarm").length >= 17);
});

test("SES uses the explicit identity/configuration set and publishes bounce and complaint events without creating a domain identity", () => {
  const { template, resources } = synthesize();
  assert.equal(resourcesOfType(resources, "AWS::SES::ConfigurationSet").length, 1);
  assert.equal(resourcesOfType(resources, "AWS::SES::ConfigurationSetEventDestination").length, 1);
  assert.equal(resourcesOfType(resources, "AWS::SES::EmailIdentity").length, 0);
  const serialized = JSON.stringify(template);
  assert.match(serialized, /BOUNCE/u);
  assert.match(serialized, /COMPLAINT/u);
  assert.match(serialized, /roomscan-transactional-dev/u);
});

test("operator topic admits only account-bounded CloudWatch alarms and the configured SES set, with KMS publisher support", () => {
  const { resources } = synthesize();
  const topicPolicies = resourcesOfType(resources, "AWS::SNS::TopicPolicy");
  assert.equal(topicPolicies.length, 1);
  const statements = ((topicPolicies[0]?.Properties?.PolicyDocument as {
    readonly Statement?: readonly Readonly<Record<string, unknown>>[];
  }).Statement ?? []);
  const serviceStatement = (service: string): Readonly<Record<string, unknown>> | undefined =>
    statements.find((statement) => JSON.stringify(statement.Principal).includes(service));
  const cloudWatchPublish = serviceStatement("cloudwatch.amazonaws.com");
  const sesPublish = serviceStatement("ses.amazonaws.com");
  assert.ok(cloudWatchPublish !== undefined);
  assert.equal(cloudWatchPublish.Action, "sns:Publish");
  assert.match(JSON.stringify(cloudWatchPublish.Resource), /OperatorAlarmTopic/u);
  const cloudWatchCondition = JSON.stringify(cloudWatchPublish.Condition);
  assert.match(cloudWatchCondition, /AWS:SourceAccount.*444444444444/u);
  assert.match(
    cloudWatchCondition,
    /AWS:SourceArn.*:cloudwatch:us-east-1:444444444444:alarm:roomscan-dev-\*/u,
  );
  assert.ok(sesPublish !== undefined);
  assert.equal(sesPublish.Action, "sns:Publish");
  assert.match(JSON.stringify(sesPublish.Condition), /configuration-set\/roomscan-transactional-dev/u);

  const auditKey = Object.entries(resources).find(
    ([logicalId, resource]) => resource.Type === "AWS::KMS::Key" && logicalId.startsWith("AuditKey"),
  );
  assert.ok(auditKey !== undefined);
  const keyStatements = ((auditKey[1].Properties?.KeyPolicy as {
    readonly Statement?: readonly Readonly<Record<string, unknown>>[];
  }).Statement ?? []);
  for (const [service, sourceArn] of [
    ["cloudwatch.amazonaws.com", ":cloudwatch:us-east-1:444444444444:alarm:roomscan-dev-*"],
    ["ses.amazonaws.com", ":ses:us-east-1:444444444444:configuration-set/roomscan-transactional-dev"]
  ] as const) {
    const statement = keyStatements.find((candidate) =>
      JSON.stringify(candidate.Principal).includes(service),
    );
    assert.ok(statement !== undefined);
    assert.deepEqual(new Set(statement.Action as readonly string[]), new Set([
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:GenerateDataKeyWithoutPlaintext"
    ]));
    const condition = JSON.stringify(statement.Condition);
    assert.match(condition, /aws:SourceAccount.*444444444444/u);
    assert.ok(condition.includes(sourceArn));
  }
});

test("function roles are separated and wildcard resources are limited to metrics and exact Lambda VPC interface actions", () => {
  const { resources } = synthesize();
  const functions = resourcesOfType(resources, "AWS::Lambda::Function");
  assert.equal(functions.length, 9);
  const roleReferences = functions.map((fn) => JSON.stringify(fn.Properties?.Role));
  assert.equal(new Set(roleReferences).size, functions.length);
  const policies = resourcesOfType(resources, "AWS::IAM::Policy");
  assert.ok(policies.length >= 7);
  for (const policy of policies) {
    const serialized = JSON.stringify(policy.Properties?.PolicyDocument);
    assert.doesNotMatch(serialized, /"Action":"[^"]*\*"/u);
    if (/"Resource":"\*"/u.test(serialized)) {
      assert.equal(
        /cloudwatch:PutMetricData/u.test(serialized)
          ? /cloudwatch:namespace.*RoomScan\/CloudTrail/u.test(serialized)
          : /ec2:CreateNetworkInterface.*ec2:DeleteNetworkInterface.*ec2:DescribeNetworkInterfaces/u.test(serialized),
        true,
      );
    }
  }
});

test("function roles can decrypt SecretsKey only through Secrets Manager for one exact secret", () => {
  const { resources } = synthesize();
  const policies = resourcesOfType(resources, "AWS::IAM::Policy");
  let secretsKeyDecryptStatements = 0;
  for (const policy of policies) {
    for (const statement of policyDocumentStatements(policy)) {
      const actions = Array.isArray(statement.Action) ? statement.Action : [statement.Action];
      if (
        !actions.includes("kms:Decrypt") ||
        !JSON.stringify(statement.Resource).includes("SecretsKey")
      ) {
        continue;
      }
      secretsKeyDecryptStatements += 1;
      const condition = statement.Condition as Readonly<Record<string, unknown>> | undefined;
      const stringEquals = condition?.StringEquals as Readonly<Record<string, unknown>> | undefined;
      assert.deepEqual(Object.keys(condition ?? {}), ["StringEquals"]);
      assert.deepEqual(
        Object.keys(stringEquals ?? {}).sort(),
        ["kms:EncryptionContext:SecretARN", "kms:ViaService"],
      );
      assert.equal(
        stringEquals?.["kms:ViaService"],
        "secretsmanager.us-east-1.amazonaws.com",
      );
      assert.ok(stringEquals?.["kms:EncryptionContext:SecretARN"] !== undefined);
    }
  }
  assert.ok(secretsKeyDecryptStatements > 0);
});

test("service and function KMS grants cover encrypted CloudTrail, alarm delivery, provider secrets, queues, and object paths", () => {
  const { resources } = synthesize();
  const policies = resourcesOfType(resources, "AWS::IAM::Policy");
  const byLogicalPrefix = (prefix: string): string => {
    const entry = Object.entries(resources).find(
      ([logicalId, resource]) => resource.Type === "AWS::IAM::Policy" && logicalId.startsWith(prefix),
    );
    assert.ok(entry !== undefined, `expected ${prefix} policy`);
    return JSON.stringify(entry[1]);
  };
  assert.match(byLogicalPrefix("PrivateApiPolicy"), /AssetsKey/u);
  assert.match(byLogicalPrefix("PrivateApiPolicy"), /QueuesKey/u);
  assert.match(byLogicalPrefix("StripeIngressPolicy"), /QueuesKey/u);
  assert.match(byLogicalPrefix("StripeIngressPolicy"), /00000000-0000-4000-8000-000000000001/u);
  assert.match(byLogicalPrefix("StripeReconciliationPolicy"), /QueuesKey/u);
  assert.match(byLogicalPrefix("AuditExporterPolicy"), /AuditKey/u);
  assert.ok(policies.length >= 10);

  const auditKey = Object.entries(resources).find(
    ([logicalId, resource]) => resource.Type === "AWS::KMS::Key" && logicalId.startsWith("AuditKey"),
  );
  assert.ok(auditKey !== undefined);
  const keyPolicy = JSON.stringify(auditKey[1].Properties?.KeyPolicy);
  assert.match(keyPolicy, /cloudtrail\.amazonaws\.com/u);
  assert.match(keyPolicy, /cloudwatch\.amazonaws\.com/u);
  assert.match(keyPolicy, /ses\.amazonaws\.com/u);
});

test("CloudTrail KMS policy separates context-bound data-key generation from context-free key inspection and permits bucket-key decrypt", () => {
  const { resources } = synthesize();
  const auditKey = Object.entries(resources).find(
    ([logicalId, resource]) => resource.Type === "AWS::KMS::Key" && logicalId.startsWith("AuditKey"),
  );
  assert.ok(auditKey !== undefined);
  const policy = auditKey[1].Properties?.KeyPolicy as {
    readonly Statement?: readonly Readonly<Record<string, unknown>>[];
  };
  const statements = policy.Statement ?? [];
  const cloudTrailStatements = statements.filter((statement) =>
    JSON.stringify(statement.Principal).includes("cloudtrail.amazonaws.com"),
  );
  const encrypt = cloudTrailStatements.find((statement) =>
    JSON.stringify(statement.Action).includes("kms:GenerateDataKey"),
  );
  const inspectAndDecrypt = cloudTrailStatements.find((statement) =>
    JSON.stringify(statement.Action).includes("kms:DescribeKey") &&
    JSON.stringify(statement.Action).includes("kms:Decrypt"),
  );
  assert.ok(encrypt !== undefined);
  assert.match(JSON.stringify(encrypt.Condition), /kms:EncryptionContext:aws:cloudtrail:arn/u);
  assert.ok(inspectAndDecrypt !== undefined);
  assert.doesNotMatch(
    JSON.stringify(inspectAndDecrypt.Condition),
    /kms:EncryptionContext:aws:cloudtrail:arn/u,
  );
});

test("CloudTrail records four workload S3 boundaries without recursively selecting its own delivery bucket", () => {
  const { resources } = synthesize();
  const trail = resourcesOfType(resources, "AWS::CloudTrail::Trail")[0];
  assert.ok(trail !== undefined);
  const selectors = JSON.stringify(trail.Properties?.EventSelectors);
  for (const logicalPrefix of [
    "QuarantineBucket",
    "ActiveBucket",
    "PublishedDerivativeBucket",
    "BackupBucket"
  ]) {
    assert.match(selectors, new RegExp(logicalPrefix, "u"));
  }
  assert.doesNotMatch(selectors, /AuditBucket/u);
});

test("a scheduled Node.js 24 monitor converts GetTrailStatus into bounded health and heartbeat alarms", () => {
  const { template, resources } = synthesize();
  const serialized = JSON.stringify(template);
  assert.doesNotMatch(serialized, /"Namespace":"AWS\/CloudTrail".*"MetricName":"DeliveryErrors"/u);

  const monitor = resourcesOfType(resources, "AWS::Lambda::Function").find(
    (fn) => fn.Properties?.FunctionName === "roomscan-dev-cloudtrail-status-monitor",
  );
  assert.ok(monitor !== undefined);
  assert.equal(monitor.Properties?.Runtime, "nodejs24.x");

  const rules = resourcesOfType(resources, "AWS::Events::Rule");
  const statusRule = rules.find(
    (rule) => rule.Properties?.Name === "roomscan-dev-cloudtrail-status-monitor",
  );
  assert.ok(statusRule !== undefined);
  assert.equal(statusRule.Properties?.ScheduleExpression, "rate(5 minutes)");
  assert.equal(statusRule.Properties?.State, "ENABLED");
  const permissions = resourcesOfType(resources, "AWS::Lambda::Permission");
  const eventInvoke = permissions.find((permission) =>
    permission.Properties?.Principal === "events.amazonaws.com",
  );
  assert.ok(eventInvoke !== undefined);
  assert.equal(eventInvoke.Properties?.Action, "lambda:InvokeFunction");
  assert.match(JSON.stringify(eventInvoke.Properties?.SourceArn), /CloudTrailStatusSchedule/u);

  const monitorPolicy = Object.entries(resources).find(
    ([logicalId, resource]) =>
      resource.Type === "AWS::IAM::Policy" && logicalId.startsWith("CloudTrailStatusMonitorPolicy"),
  );
  assert.ok(monitorPolicy !== undefined);
  const policy = JSON.stringify(monitorPolicy[1].Properties?.PolicyDocument);
  assert.match(policy, /cloudtrail:GetTrailStatus/u);
  assert.match(policy, /PlatformTrail/u);
  assert.match(policy, /cloudwatch:PutMetricData/u);
  assert.match(policy, /cloudwatch:namespace.*RoomScan\/CloudTrail/u);

  const statusAlarms = resourcesOfType(resources, "AWS::CloudWatch::Alarm").filter(
    (alarm) => alarm.Properties?.Namespace === "RoomScan/CloudTrail",
  );
  assert.equal(statusAlarms.length, 2);
  assert.deepEqual(
    new Set(statusAlarms.map((alarm) => alarm.Properties?.MetricName)),
    new Set(["TrailDeliveryHealthy", "TrailStatusHeartbeat"]),
  );
  assert.equal(statusAlarms.every((alarm) => alarm.Properties?.TreatMissingData === "breaching"), true);
});

test("every application Lambda is Node.js 24 with an immutable version, live alias, retained encrypted log group, error/throttle alarms, and rollback outputs", () => {
  const { template, resources } = synthesize();
  const functions = resourcesOfType(resources, "AWS::Lambda::Function");
  assert.equal(functions.length, 9);
  assert.equal(functions.every((fn) => fn.Properties?.Runtime === "nodejs24.x"), true);
  assert.equal(resourcesOfType(resources, "AWS::Lambda::Version").length, functions.length);
  assert.equal(resourcesOfType(resources, "AWS::Lambda::Alias").length, functions.length);
  assert.match(JSON.stringify(template), /RollbackAlarmArns/u);
  assert.match(JSON.stringify(template), /AliasArn/u);
});

test("the configured magic-delivery key ID reaches exactly API and email and production entrypoints contain no stub markers", () => {
  const magicDeliveryKeyId = "magic-envelope-rotated-v2";
  const { template, resources } = synthesize({ ...TEST_CONFIG, magicDeliveryKeyId });
  const functions = resourcesOfType(resources, "AWS::Lambda::Function");
  const byName = new Map(functions.map((fn) => [
    String(fn.Properties?.FunctionName),
    ((fn.Properties?.Environment as {
      readonly Variables?: Readonly<Record<string, unknown>>;
    } | undefined)?.Variables ?? {}),
  ]));

  assert.equal(byName.get("roomscan-dev-api")?.MAGIC_DELIVERY_KEY_ID, magicDeliveryKeyId);
  assert.equal(byName.get("roomscan-dev-email-delivery")?.MAGIC_DELIVERY_KEY_ID, magicDeliveryKeyId);
  assert.deepEqual(
    [...byName.entries()]
      .filter(([, environment]) => "MAGIC_DELIVERY_KEY_ID" in environment)
      .map(([name]) => name)
      .sort(),
    ["roomscan-dev-api", "roomscan-dev-email-delivery"],
  );

  const serialized = JSON.stringify(template);
  assert.doesNotMatch(
    serialized,
    /fail-closed until service integration|service_integration_not_configured|integration_not_configured|\bnot_configured\b|deny[-_ ]all|statusCode\s*[:=]\s*503/iu,
  );
});

test("the template records account topology ownership and contains no portal, CDN, public identity pool, or production commercial policy", () => {
  const { template, resources } = synthesize();
  const serialized = JSON.stringify(template);
  assert.match(serialized, /roomscan-platform-owner/u);
  assert.equal(resourcesOfType(resources, "AWS::CloudFront::Distribution").length, 0);
  assert.equal(resourcesOfType(resources, "AWS::Amplify::App").length, 0);
  assert.equal(resourcesOfType(resources, "AWS::Cognito::IdentityPool").length, 0);
  assert.match(serialized, /local-test-values-v1/u);
  assert.doesNotMatch(serialized, /price_live|monthlyQuota|productionQuota/iu);
});
