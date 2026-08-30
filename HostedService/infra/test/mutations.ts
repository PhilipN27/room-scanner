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
  },
  {
    name: "project-sync bucket public access block removed",
    expected: /S3 public access/u,
    mutate(template) {
      const [, bucket] = resourceEntry(template, "AWS::S3::Bucket", "ProjectSyncBucket");
      bucket.Properties!.PublicAccessBlockConfiguration = {
        BlockPublicAcls: false,
        BlockPublicPolicy: false,
        IgnorePublicAcls: false,
        RestrictPublicBuckets: false,
      };
    }
  },
  {
    name: "project-sync object deletion retention deny removed",
    expected: /project-sync retention or namespace deny/u,
    mutate(template) {
      const [, policy] = resourceEntry(template, "AWS::S3::BucketPolicy", "ProjectSyncBucketPolicy");
      const document = policy.Properties!.PolicyDocument as { Statement: unknown[] };
      document.Statement = document.Statement.filter(
        (statement) => !JSON.stringify(statement).includes("DenyProjectSyncObjectDeletion"),
      );
    }
  },
  {
    name: "project-sync validation queue encryption removed",
    expected: /project-sync validation queue requires KMS/u,
    mutate(template) {
      const [, queue] = resourceEntry(template, "AWS::SQS::Queue", "ProjectSyncValidationQueue");
      delete queue.Properties!.KmsMasterKeyId;
    }
  },
  {
    name: "project-sync validation queue falls back to the legacy CMK",
    expected: /dedicated CMK/u,
    mutate(template) {
      const [, queue] = resourceEntry(template, "AWS::SQS::Queue", "ProjectSyncValidationQueue");
      queue.Properties!.KmsMasterKeyId = { "Fn::GetAtt": ["QueuesKeyMutant", "Arn"] };
    }
  },
  {
    name: "project-sync EventBridge producer source binding removed",
    expected: /exact EventBridge SendMessage queue policy/u,
    mutate(template) {
      const [, policy] = resourceEntry(template, "AWS::SQS::QueuePolicy", "ProjectSyncValidationQueuePolicy");
      const document = policy.Properties!.PolicyDocument as { Statement: Array<Record<string, unknown>> };
      const producer = document.Statement.find((statement) => JSON.stringify(statement.Principal).includes("events.amazonaws.com"));
      assert.ok(producer !== undefined);
      delete producer.Condition;
    }
  },
  {
    name: "project-sync EventBridge producer source account is another workload",
    expected: /exact EventBridge SendMessage queue policy/u,
    mutate(template) {
      const [, policy] = resourceEntry(template, "AWS::SQS::QueuePolicy", "ProjectSyncValidationQueuePolicy");
      const document = policy.Properties!.PolicyDocument as { Statement: Array<Record<string, unknown>> };
      const producer = document.Statement.find((statement) => JSON.stringify(statement.Principal).includes("events.amazonaws.com"));
      assert.ok(producer !== undefined);
      const condition = producer.Condition as { StringEquals?: Record<string, unknown> };
      assert.ok(condition?.StringEquals !== undefined);
      condition.StringEquals["aws:SourceAccount"] = "999999999999";
    }
  },
  {
    name: "project-sync EventBridge producer broadens its exact rule ARN",
    expected: /exact EventBridge SendMessage queue policy/u,
    mutate(template) {
      const [, policy] = resourceEntry(template, "AWS::SQS::QueuePolicy", "ProjectSyncValidationQueuePolicy");
      const document = policy.Properties!.PolicyDocument as { Statement: Array<Record<string, unknown>> };
      const producer = document.Statement.find((statement) => JSON.stringify(statement.Principal).includes("events.amazonaws.com"));
      assert.ok(producer !== undefined);
      const condition = producer.Condition as Record<string, unknown>;
      const arnEquals = condition.ArnEquals as Record<string, unknown>;
      assert.ok(arnEquals !== undefined);
      const exactRuleArn = arnEquals["aws:SourceArn"];
      delete condition.ArnEquals;
      condition.ArnLike = {
        "aws:SourceArn": { "Fn::Join": ["", [exactRuleArn, "*"]] },
      };
    }
  },
  {
    name: "project-sync EventBridge producer gains queue discovery",
    expected: /exact EventBridge SendMessage queue policy/u,
    mutate(template) {
      const [, policy] = resourceEntry(template, "AWS::SQS::QueuePolicy", "ProjectSyncValidationQueuePolicy");
      const document = policy.Properties!.PolicyDocument as { Statement: Array<Record<string, unknown>> };
      const producer = document.Statement.find((statement) => JSON.stringify(statement.Principal).includes("events.amazonaws.com"));
      assert.ok(producer !== undefined);
      producer.Action = ["sqs:SendMessage", "sqs:GetQueueAttributes"];
    }
  },
  {
    name: "project-sync EventBridge KMS grant gains an unnecessary encrypt action",
    expected: /exact EventBridge source-account grant/u,
    mutate(template) {
      const [, key] = resourceEntry(template, "AWS::KMS::Key", "ProjectSyncQueuesKey");
      const document = key.Properties!.KeyPolicy as { Statement: Array<Record<string, unknown>> };
      const grant = document.Statement.find((statement) =>
        JSON.stringify(statement.Principal).includes("events.amazonaws.com"),
      );
      assert.ok(grant !== undefined);
      grant.Action = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey"];
    }
  },
  {
    name: "project-sync EventBridge KMS grant trusts another workload account",
    expected: /exact EventBridge source-account grant/u,
    mutate(template) {
      const [, key] = resourceEntry(template, "AWS::KMS::Key", "ProjectSyncQueuesKey");
      const document = key.Properties!.KeyPolicy as { Statement: Array<Record<string, unknown>> };
      const grant = document.Statement.find((statement) =>
        JSON.stringify(statement.Principal).includes("events.amazonaws.com"),
      );
      assert.ok(grant !== undefined);
      const condition = grant.Condition as { StringEquals?: Record<string, unknown> };
      assert.ok(condition?.StringEquals !== undefined);
      condition.StringEquals["aws:SourceAccount"] = "999999999999";
    }
  },
  {
    name: "project-sync validation queue redrive count weakened",
    expected: /five-attempt DLQ redrive/u,
    mutate(template) {
      const [, queue] = resourceEntry(template, "AWS::SQS::Queue", "ProjectSyncValidationQueue");
      const redrive = queue.Properties!.RedrivePolicy as Record<string, unknown>;
      assert.ok(redrive !== null && typeof redrive === "object");
      redrive.maxReceiveCount = 4;
    }
  },
  {
    name: "project-sync validation batch delivery broadened",
    expected: /one-record queue delivery/u,
    mutate(template) {
      const [, mapping] = resourceEntry(template, "AWS::Lambda::EventSourceMapping", "ProjectSyncValidation");
      mapping.Properties!.BatchSize = 2;
    }
  },
  {
    name: "project-sync CloudTrail quarantine data events removed",
    expected: /CloudTrail must record project-sync quarantine and active/u,
    mutate(template) {
      const trail = firstResource(template, "AWS::CloudTrail::Trail");
      const selectors = trail.Properties!.EventSelectors as unknown[];
      assert.ok(Array.isArray(selectors));
      const objectSelector = selectors.find((selector) =>
        JSON.stringify(selector).includes("AWS::S3::Object"),
      ) as { DataResources?: Array<{ Values?: unknown[] }> } | undefined;
      assert.ok(objectSelector?.DataResources !== undefined);
      const dataResource = objectSelector.DataResources.find((resource) =>
        JSON.stringify(resource).includes("AWS::S3::Object"),
      );
      assert.ok(dataResource?.Values !== undefined);
      dataResource.Values = dataResource.Values.filter(
        (value) => !JSON.stringify(value).includes("server/quarantine/v1/"),
      );
    }
  },
  {
    name: "API project-sync list authority introduced",
    expected: /API project-sync authority must be exact upload\/recovery only/u,
    mutate(template) {
      const [, policy] = resourceEntry(template, "AWS::IAM::Policy", "PrivateApiPolicy");
      const document = policy.Properties!.PolicyDocument as { Statement: unknown[] };
      document.Statement.push({
        Action: "s3:ListBucket",
        Effect: "Allow",
        Resource: { "Fn::GetAtt": ["ProjectSyncBucketMutant", "Arn"] },
      });
    }
  },
  {
    name: "API project-sync recovery broadens from exact-version read",
    expected: /API project-sync authority must be exact upload\/recovery only/u,
    mutate(template) {
      const [, policy] = resourceEntry(template, "AWS::IAM::Policy", "PrivateApiPolicy");
      const document = policy.Properties!.PolicyDocument as { Statement: Array<Record<string, unknown>> };
      const recovery = document.Statement.find((statement) =>
        JSON.stringify(statement.Resource).includes("professional-sync/active/working"),
      );
      assert.ok(recovery !== undefined);
      recovery.Action = ["s3:GetObject", "s3:GetObjectVersion"];
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
