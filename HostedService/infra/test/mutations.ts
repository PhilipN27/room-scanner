import assert from "node:assert/strict";

import { App } from "aws-cdk-lib";
import { Template } from "aws-cdk-lib/assertions";

import { cdkAvailabilityZonesContext } from "../src/config.js";
import { assertInfrastructurePolicy } from "../src/policy/template-policy.js";
import { RoomScanPlatformStack } from "../src/stacks/platform-stack.js";
import { TEST_CONFIG } from "./support/test-config.js";

type MutableResource = {
  Type: string;
  Properties?: Record<string, unknown>;
};

type MutableTemplate = {
  Resources: Record<string, MutableResource>;
  Outputs?: Record<string, unknown>;
};

const app = new App({ context: cdkAvailabilityZonesContext(TEST_CONFIG) });
const stack = new RoomScanPlatformStack(app, "RoomScanPlatform-MutationFixture", {
  config: TEST_CONFIG,
  env: { account: TEST_CONFIG.accountId, region: TEST_CONFIG.region }
});
const source = Template.fromStack(stack).toJSON() as MutableTemplate;

const mutations: readonly {
  readonly name: string;
  readonly expected: RegExp;
  readonly mutate: (template: MutableTemplate) => void;
}[] = [
  {
    name: "S3 Block Public Access removed",
    expected: /S3.*public access/u,
    mutate(template) {
      firstResource(template, "AWS::S3::Bucket").Properties!.PublicAccessBlockConfiguration = {
        BlockPublicAcls: false,
        BlockPublicPolicy: false,
        IgnorePublicAcls: false,
        RestrictPublicBuckets: false
      };
    }
  },
  {
    name: "S3 TLS-only deny removed",
    expected: /TLS-only/u,
    mutate(template) {
      const policy = firstResource(template, "AWS::S3::BucketPolicy");
      const document = policy.Properties!.PolicyDocument as { Statement: unknown[] };
      document.Statement = document.Statement.filter(
        (statement) => !JSON.stringify(statement).includes("aws:SecureTransport"),
      );
    }
  },
  {
    name: "us-east-1 region invariant neutralized",
    expected: /us-east-1/u,
    mutate(template) {
      const metadata = firstResource(template, "AWS::SSM::Parameter");
      metadata.Properties!.Value = "us-west-2";
    }
  },
  {
    name: "Stripe raw-envelope marker removed",
    expected: /raw Stripe envelope/u,
    mutate(template) {
      const parameter = resourcesOfType(template, "AWS::SSM::Parameter").find(
        (resource) => resource.Properties?.Name === "/roomscan/dev/stripe/raw-envelope-contract",
      );
      assert.ok(parameter !== undefined);
      parameter.Properties!.Value = "parsed-body";
    }
  },
  {
    name: "Lambda IAM wildcard resource introduced",
    expected: /wildcard-only IAM resource/u,
    mutate(template) {
      const policy = firstResource(template, "AWS::IAM::Policy");
      const document = policy.Properties!.PolicyDocument as {
        Statement: { Resource?: unknown }[];
      };
      const statement = document.Statement.find((candidate) => candidate.Resource !== undefined);
      assert.ok(statement !== undefined);
      statement.Resource = "*";
    }
  },
  {
    name: "Lambda role receives an unconditional SecretsKey decrypt grant",
    expected: /SecretsKey decrypt requires Secrets Manager/u,
    mutate(template) {
      const [, policy] = resourceEntry(template, "AWS::IAM::Policy", "PrivateApiPolicy");
      const document = policy.Properties!.PolicyDocument as { Statement: unknown[] };
      document.Statement.push({
        Action: "kms:Decrypt",
        Effect: "Allow",
        Resource: { "Fn::GetAtt": ["SecretsKeyMutant", "Arn"] }
      });
    }
  },
  {
    name: "forced log retention removed",
    expected: /log retention/u,
    mutate(template) {
      delete firstResource(template, "AWS::Logs::LogGroup").Properties!.RetentionInDays;
    }
  },
  {
    name: "Lambda log group changed from LogsKey to SecretsKey",
    expected: /Lambda log groups.*LogsKey/u,
    mutate(template) {
      const group = resourcesOfType(template, "AWS::Logs::LogGroup").find((resource) =>
        String(resource.Properties?.LogGroupName).startsWith("/aws/lambda/"),
      );
      assert.ok(group?.Properties !== undefined);
      group.Properties.KmsKeyId = { "Fn::GetAtt": ["SecretsKeyMutant", "Arn"] };
    }
  },
  {
    name: "CloudWatch Logs service KMS statement removed",
    expected: /LogsKey.*CloudWatch Logs/u,
    mutate(template) {
      const [, key] = resourceEntry(template, "AWS::KMS::Key", "LogsKey");
      const document = key.Properties!.KeyPolicy as { Statement: unknown[] };
      document.Statement = document.Statement.filter(
        (statement) => !JSON.stringify(statement).includes("logs.us-east-1.amazonaws.com"),
      );
    }
  },
  {
    name: "CloudWatch Logs GenerateDataKeyWithoutPlaintext permission removed",
    expected: /LogsKey requires/u,
    mutate(template) {
      const [, key] = resourceEntry(template, "AWS::KMS::Key", "LogsKey");
      const document = key.Properties!.KeyPolicy as {
        Statement: { Principal?: unknown; Action?: unknown }[];
      };
      const statement = document.Statement.find((candidate) =>
        JSON.stringify(candidate.Principal).includes("logs.us-east-1.amazonaws.com"),
      );
      assert.ok(statement !== undefined);
      assert.ok(Array.isArray(statement.Action));
      statement.Action = statement.Action.filter(
        (action) => action !== "kms:GenerateDataKeyWithoutPlaintext",
      );
    }
  },
  {
    name: "CloudWatch alarm topic publication removed",
    expected: /CloudWatch alarm.*topic policy/u,
    mutate(template) {
      const policy = firstResource(template, "AWS::SNS::TopicPolicy");
      const document = policy.Properties!.PolicyDocument as { Statement: unknown[] };
      document.Statement = document.Statement.filter(
        (statement) => !JSON.stringify(statement).includes("cloudwatch.amazonaws.com"),
      );
    }
  },
  {
    name: "CloudTrail status heartbeat alarm removed",
    expected: /CloudTrail status.*heartbeat/u,
    mutate(template) {
      const [logicalId] = resourceEntry(
        template,
        "AWS::CloudWatch::Alarm",
        "CloudTrailStatusHeartbeatAlarm",
      );
      delete template.Resources[logicalId];
    }
  },
  {
    name: "unsupported AWS CloudTrail DeliveryErrors metric introduced",
    expected: /unsupported CloudTrail metric/u,
    mutate(template) {
      const [, alarm] = resourceEntry(
        template,
        "AWS::CloudWatch::Alarm",
        "CloudTrailDeliveryHealthAlarm",
      );
      alarm.Properties!.Namespace = "AWS/CloudTrail";
      alarm.Properties!.MetricName = "DeliveryErrors";
    }
  },
  {
    name: "Cognito federation domain removed",
    expected: /Cognito federation domain/u,
    mutate(template) {
      const [logicalId] = resourceEntry(template, "AWS::Cognito::UserPoolDomain", "");
      delete template.Resources[logicalId];
    }
  },
  {
    name: "Cognito native local-user provider added to managed login",
    expected: /Apple-only/u,
    mutate(template) {
      const [, client] = resourceEntry(template, "AWS::Cognito::UserPoolClient", "AppleFederationClient");
      client.Properties!.SupportedIdentityProviders = ["COGNITO", "SignInWithApple"];
    }
  },
  {
    name: "audit version lifetime extended beyond 400 days",
    expected: /audit version lifetime/u,
    mutate(template) {
      const [, bucket] = resourceEntry(template, "AWS::S3::Bucket", "AuditBucket");
      const lifecycle = bucket.Properties!.LifecycleConfiguration as {
        Rules: { ExpirationInDays?: number; NoncurrentVersionExpiration?: { NoncurrentDays?: number } }[];
      };
      const rule = lifecycle.Rules.find((candidate) => candidate.ExpirationInDays !== undefined);
      assert.ok(rule?.NoncurrentVersionExpiration !== undefined);
      rule.ExpirationInDays = 400;
      rule.NoncurrentVersionExpiration.NoncurrentDays = 400;
    }
  },
  {
    name: "S3 CMK override denies removed",
    expected: /S3 encryption overrides/u,
    mutate(template) {
      const policy = firstResource(template, "AWS::S3::BucketPolicy");
      const document = policy.Properties!.PolicyDocument as { Statement: unknown[] };
      document.Statement = document.Statement.filter(
        (statement) => !JSON.stringify(statement).includes("s3:x-amz-server-side-encryption"),
      );
    }
  }
];

let detected = 0;
let restored = 0;
for (const mutation of mutations) {
  const template = structuredClone(source);
  mutation.mutate(template);
  try {
    assert.throws(() => assertInfrastructurePolicy(template), mutation.expected);
    detected += 1;
    console.log(`MUTATION_RED ${mutation.name}: focused infrastructure policy rejected mutant`);
  } catch {
    console.log(`MUTATION_ESCAPED ${mutation.name}: infrastructure policy accepted mutant`);
  }
  assert.doesNotThrow(() => assertInfrastructurePolicy(source));
  restored += 1;
  console.log(`RESTORE_GREEN ${mutation.name}`);
}

console.log(`MUTATION_SUMMARY detected=${detected} restored=${restored} total=${mutations.length}`);
assert.equal(detected, mutations.length, "every representative infrastructure mutant must be detected");

function resourcesOfType(template: MutableTemplate, type: string): MutableResource[] {
  return Object.values(template.Resources).filter((resource) => resource.Type === type);
}

function firstResource(template: MutableTemplate, type: string): MutableResource {
  const resource = resourcesOfType(template, type)[0];
  assert.ok(resource !== undefined, `expected ${type} mutation fixture`);
  assert.ok(resource.Properties !== undefined, `expected ${type} properties`);
  return resource;
}

function resourceEntry(
  template: MutableTemplate,
  type: string,
  logicalPrefix: string,
): [string, MutableResource] {
  const entry = Object.entries(template.Resources).find(
    ([logicalId, resource]) => resource.Type === type && logicalId.startsWith(logicalPrefix),
  );
  assert.ok(entry !== undefined, `expected ${type} ${logicalPrefix} mutation fixture`);
  assert.ok(entry[1].Properties !== undefined, `expected ${type} ${logicalPrefix} properties`);
  return entry;
}
