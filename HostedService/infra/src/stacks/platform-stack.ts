import { createHash } from "node:crypto";
import { readFileSync, readdirSync } from "node:fs";
import { resolve } from "node:path";

import {
  ArnFormat,
  CfnOutput,
  Duration,
  RemovalPolicy,
  SecretValue,
  Stack,
  Tags,
  type StackProps
} from "aws-cdk-lib";
import * as apigatewayv2 from "aws-cdk-lib/aws-apigatewayv2";
import * as apigatewayv2Authorizers from "aws-cdk-lib/aws-apigatewayv2-authorizers";
import * as apigatewayv2Integrations from "aws-cdk-lib/aws-apigatewayv2-integrations";
import * as cloudtrail from "aws-cdk-lib/aws-cloudtrail";
import * as cloudwatch from "aws-cdk-lib/aws-cloudwatch";
import * as cloudwatchActions from "aws-cdk-lib/aws-cloudwatch-actions";
import * as cognito from "aws-cdk-lib/aws-cognito";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as events from "aws-cdk-lib/aws-events";
import * as eventsTargets from "aws-cdk-lib/aws-events-targets";
import * as iam from "aws-cdk-lib/aws-iam";
import * as kms from "aws-cdk-lib/aws-kms";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as lambdaEventSources from "aws-cdk-lib/aws-lambda-event-sources";
import {
  NodejsFunction,
  OutputFormat,
  type ICommandHooks,
} from "aws-cdk-lib/aws-lambda-nodejs";
import * as logs from "aws-cdk-lib/aws-logs";
import * as rds from "aws-cdk-lib/aws-rds";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as secretsmanager from "aws-cdk-lib/aws-secretsmanager";
import * as ses from "aws-cdk-lib/aws-ses";
import * as sns from "aws-cdk-lib/aws-sns";
import * as snsSubscriptions from "aws-cdk-lib/aws-sns-subscriptions";
import * as sqs from "aws-cdk-lib/aws-sqs";
import * as ssm from "aws-cdk-lib/aws-ssm";
import type { Construct } from "constructs";

import { assertPlatformConfigResourceArns, type PlatformConfig } from "../config.js";
import {
  SLICE4_ROUTE_MANIFEST,
  type SealedRoute,
} from "roomscan-studio-hosted-service/contracts";

export interface RoomScanPlatformStackProps extends StackProps {
  readonly config: PlatformConfig;
}

interface EncryptionKeys {
  readonly logs: kms.Key;
  readonly database: kms.Key;
  readonly assets: kms.Key;
  readonly audit: kms.Key;
  readonly queues: kms.Key;
  readonly secrets: kms.Key;
}

interface StorageBuckets {
  readonly quarantine: s3.Bucket;
  readonly active: s3.Bucket;
  readonly published: s3.Bucket;
  readonly backup: s3.Bucket;
  readonly audit: s3.Bucket;
}

interface QueueBoundary {
  readonly reconciliation: sqs.Queue;
  readonly reconciliationDlq: sqs.Queue;
  readonly auditOutbox: sqs.Queue;
  readonly auditOutboxDlq: sqs.Queue;
  readonly emailDelivery: sqs.Queue;
  readonly emailDeliveryDlq: sqs.Queue;
}

interface DatabaseBoundary {
  readonly vpc: ec2.Vpc;
  readonly securityGroup: ec2.SecurityGroup;
  readonly cluster: rds.DatabaseCluster;
  readonly ownerSecret: secretsmanager.ISecret;
  readonly runtimeSecrets: Readonly<{
    authorizer: secretsmanager.ISecret;
    api: secretsmanager.ISecret;
    authChallenge: secretsmanager.ISecret;
    stripeIngress: secretsmanager.ISecret;
    stripeReconciliation: secretsmanager.ISecret;
    auditExport: secretsmanager.ISecret;
    emailDelivery: secretsmanager.ISecret;
  }>;
  readonly applicationSecrets: Readonly<{
    accessTokenDigest: secretsmanager.Secret;
    apiTokenDerivation: secretsmanager.Secret;
    authChallengeProof: secretsmanager.Secret;
    magicDeliveryEnvelope: secretsmanager.Secret;
  }>;
}

interface IdentityBoundary {
  readonly userPool: cognito.UserPool;
  readonly federationClient: cognito.UserPoolClient;
  readonly customAuthClient: cognito.UserPoolClient;
}

interface FunctionUnit {
  readonly fn: NodejsFunction;
  readonly alias: lambda.Alias;
  readonly role: iam.Role;
  readonly policy: iam.Policy;
  readonly logGroup: logs.LogGroup;
  readonly errorAlarm: cloudwatch.Alarm;
  readonly throttleAlarm: cloudwatch.Alarm;
}

interface FunctionOptions {
  readonly timeout?: Duration;
  readonly memorySize?: number;
  readonly reservedConcurrentExecutions?: number;
  readonly vpc?: ec2.IVpc;
  readonly vpcSubnets?: ec2.SubnetSelection;
  readonly securityGroups?: readonly ec2.ISecurityGroup[];
  readonly commandHooks?: ICommandHooks;
}

export class RoomScanPlatformStack extends Stack {
  private readonly rollbackAlarms: cloudwatch.Alarm[] = [];

  constructor(scope: Construct, id: string, props: RoomScanPlatformStackProps) {
    super(scope, id, props);
    const { config } = props;
    assertPlatformConfigResourceArns(config);
    if (config.region !== "us-east-1" || this.region !== "us-east-1") {
      throw new Error("RoomScan infrastructure synthesis is restricted to us-east-1");
    }
    if (this.account !== config.accountId) {
      throw new Error("RoomScan stack account must match the explicit workload account");
    }

    this.applyOwnershipTags(config);
    this.defineConfigurationMarkers(config);

    const keys = this.createEncryptionKeys(config);
    const alarmTopic = this.createAlarmTopic(config, keys.audit);
    const buckets = this.createStorageBuckets(config, keys);
    const trail = this.createCloudTrail(config, keys, buckets);
    const database = this.createDatabaseBoundary(config, keys);
    const queues = this.createQueueBoundary(config, keys.queues);
    const sesConfigurationSet = this.createSesBoundary(config, alarmTopic);

    const authorizerUnit = this.createFunction(
      config,
      keys.logs,
      keys.secrets,
      alarmTopic,
      "AppAuthorization",
      "app-authorizer",
      "app-authorizer.ts",
      {
        DB_CLUSTER_ARN: database.cluster.clusterArn,
        ROOMSCAN_DB_ROLE_SECRET_ARN: database.runtimeSecrets.authorizer.secretArn,
        ROOMSCAN_DB_RUNTIME_ROLE: "roomscan_authorizer_runtime",
        ACCESS_TOKEN_HMAC_SECRET_ARN: database.applicationSecrets.accessTokenDigest.secretArn
      },
      [
        ...this.dataApiStatements(
          config,
          database.cluster,
          database.runtimeSecrets.authorizer,
          keys.secrets,
        ),
        ...this.secretReadStatements(
          config,
          database.applicationSecrets.accessTokenDigest.secretArn,
          keys.secrets.keyArn,
        )
      ],
    );

    const apiUnit = this.createFunction(
      config,
      keys.logs,
      keys.secrets,
      alarmTopic,
      "PrivateApi",
      "api",
      "api.ts",
      {
        DB_CLUSTER_ARN: database.cluster.clusterArn,
        ROOMSCAN_DB_ROLE_SECRET_ARN: database.runtimeSecrets.api.secretArn,
        ROOMSCAN_DB_RUNTIME_ROLE: "roomscan_api_runtime",
        ACCESS_TOKEN_HMAC_SECRET_ARN: database.applicationSecrets.accessTokenDigest.secretArn,
        API_TOKEN_DERIVATION_SECRET_ARN: database.applicationSecrets.apiTokenDerivation.secretArn,
        MAGIC_DELIVERY_ENVELOPE_SECRET_ARN: database.applicationSecrets.magicDeliveryEnvelope.secretArn,
        MAGIC_DELIVERY_QUEUE_URL: queues.emailDelivery.queueUrl,
        MAGIC_DELIVERY_KEY_ID: config.magicDeliveryKeyId,
        AUTH_CHALLENGE_SECRET_ARN: database.applicationSecrets.authChallengeProof.secretArn,
        APPLE_PRIVATE_KEY_SECRET_ARN: config.apple.privateKeySecretArn,
        APPLE_CLIENT_ID: config.apple.clientId,
        APPLE_TEAM_ID: config.apple.teamId,
        APPLE_KEY_ID: config.apple.keyId,
        APPLE_REDIRECT_URI: `https://${config.serviceDomain}/auth/apple/callback`,
        APPLE_CLIENT_SECRET_SIGNING_MODE: "runtime-es256-secretsmanager-v1",
        STRIPE_DEFAULT_ACCOUNT_ID: config.stripe.defaultAccountId,
        QUARANTINE_BUCKET_NAME: buckets.quarantine.bucketName,
        AUDIT_OUTBOX_QUEUE_URL: queues.auditOutbox.queueUrl,
        AUTH_POLICY_VERSION: "slice4-local-test-v1",
        MAGIC_POLICY_VERSION: "slice4-local-test-v1",
        SESSION_POLICY_VERSION: "slice4-local-test-v1"
      },
      [
        ...this.dataApiStatements(config, database.cluster, database.runtimeSecrets.api, keys.secrets),
        ...this.secretReadStatements(
          config,
          database.applicationSecrets.accessTokenDigest.secretArn,
          keys.secrets.keyArn,
        ),
        ...this.secretReadStatements(
          config,
          database.applicationSecrets.apiTokenDerivation.secretArn,
          keys.secrets.keyArn,
        ),
        ...this.secretReadStatements(
          config,
          database.applicationSecrets.magicDeliveryEnvelope.secretArn,
          keys.secrets.keyArn,
        ),
        ...this.secretReadStatements(
          config,
          database.applicationSecrets.authChallengeProof.secretArn,
          keys.secrets.keyArn,
        ),
        ...this.secretReadStatements(
          config,
          config.apple.privateKeySecretArn,
          config.providerSecretsKmsKeyArn,
        ),
        new iam.PolicyStatement({
          actions: ["s3:PutObject"],
          resources: [buckets.quarantine.arnForObjects("server/quarantine/*")]
        }),
        new iam.PolicyStatement({
          actions: ["sqs:SendMessage"],
          resources: [queues.auditOutbox.queueArn, queues.emailDelivery.queueArn]
        }),
        this.kmsUseStatement(keys.assets.keyArn, ["kms:Decrypt", "kms:GenerateDataKey"]),
        this.kmsUseStatement(keys.queues.keyArn, ["kms:Decrypt", "kms:GenerateDataKey"])
      ],
    );

    const authChallengeUnit = this.createFunction(
      config,
      keys.logs,
      keys.secrets,
      alarmTopic,
      "AuthChallenges",
      "auth-challenge",
      "auth-challenge.ts",
      {
        DB_CLUSTER_ARN: database.cluster.clusterArn,
        ROOMSCAN_DB_ROLE_SECRET_ARN: database.runtimeSecrets.authChallenge.secretArn,
        ROOMSCAN_DB_RUNTIME_ROLE: "roomscan_auth_challenge_runtime",
        AUTH_CHALLENGE_SECRET_ARN: database.applicationSecrets.authChallengeProof.secretArn,
        AUTH_CHALLENGE_POLICY_VERSION: "slice4-local-test-v1"
      },
      [
        ...this.dataApiStatements(
          config,
          database.cluster,
          database.runtimeSecrets.authChallenge,
          keys.secrets,
        ),
        ...this.secretReadStatements(
          config,
          database.applicationSecrets.authChallengeProof.secretArn,
          keys.secrets.keyArn,
        )
      ],
    );

    const stripeIngressUnit = this.createFunction(
      config,
      keys.logs,
      keys.secrets,
      alarmTopic,
      "StripeIngress",
      "stripe-ingress",
      "stripe-webhook.ts",
      {
        DB_CLUSTER_ARN: database.cluster.clusterArn,
        ROOMSCAN_DB_ROLE_SECRET_ARN: database.runtimeSecrets.stripeIngress.secretArn,
        ROOMSCAN_DB_RUNTIME_ROLE: "roomscan_stripe_ingress_runtime",
        STRIPE_WEBHOOK_SECRET_ARN: config.stripe.webhookSecretArn,
        STRIPE_DEFAULT_ACCOUNT_ID: config.stripe.defaultAccountId,
        STRIPE_RECONCILIATION_QUEUE_URL: queues.reconciliation.queueUrl,
        AUDIT_OUTBOX_QUEUE_URL: queues.auditOutbox.queueUrl,
        RAW_ENVELOPE_CONTRACT: "body+isBase64Encoded:unparsed-v1"
      },
      [
        ...this.dataApiStatements(
          config,
          database.cluster,
          database.runtimeSecrets.stripeIngress,
          keys.secrets,
        ),
        ...this.secretReadStatements(
          config,
          config.stripe.webhookSecretArn,
          config.providerSecretsKmsKeyArn,
        ),
        new iam.PolicyStatement({
          actions: ["sqs:SendMessage"],
          resources: [queues.reconciliation.queueArn, queues.auditOutbox.queueArn]
        }),
        this.kmsUseStatement(keys.queues.keyArn, ["kms:Decrypt", "kms:GenerateDataKey"])
      ],
    );

    const reconciliationUnit = this.createFunction(
      config,
      keys.logs,
      keys.secrets,
      alarmTopic,
      "StripeReconciliation",
      "stripe-reconciliation",
      "reconciliation-worker.ts",
      {
        DB_CLUSTER_ARN: database.cluster.clusterArn,
        ROOMSCAN_DB_ROLE_SECRET_ARN: database.runtimeSecrets.stripeReconciliation.secretArn,
        ROOMSCAN_DB_RUNTIME_ROLE: "roomscan_stripe_reconciliation_runtime",
        STRIPE_API_SECRET_ARN: config.stripe.apiSecretArn,
        STRIPE_API_VERSION: config.stripe.apiVersion,
        STRIPE_PRICE_PLAN_MAP_JSON: JSON.stringify(config.stripe.pricePlanMappings),
        ROOMSCAN_POLICY_VALUES_STATUS: config.stripe.policyValuesStatus,
        AUDIT_OUTBOX_QUEUE_URL: queues.auditOutbox.queueUrl
      },
      [
        ...this.dataApiStatements(
          config,
          database.cluster,
          database.runtimeSecrets.stripeReconciliation,
          keys.secrets,
        ),
        ...this.secretReadStatements(
          config,
          config.stripe.apiSecretArn,
          config.providerSecretsKmsKeyArn,
        ),
        new iam.PolicyStatement({
          actions: ["sqs:SendMessage"],
          resources: [queues.auditOutbox.queueArn]
        }),
        this.kmsUseStatement(keys.queues.keyArn, ["kms:Decrypt", "kms:GenerateDataKey"])
      ],
    );

    const auditExporterUnit = this.createFunction(
      config,
      keys.logs,
      keys.secrets,
      alarmTopic,
      "AuditExporter",
      "audit-exporter",
      "audit-exporter.ts",
      {
        DB_CLUSTER_ARN: database.cluster.clusterArn,
        ROOMSCAN_DB_ROLE_SECRET_ARN: database.runtimeSecrets.auditExport.secretArn,
        ROOMSCAN_DB_RUNTIME_ROLE: "roomscan_audit_export_runtime",
        AUDIT_BUCKET_NAME: buckets.audit.bucketName
      },
      [
        ...this.dataApiStatements(
          config,
          database.cluster,
          database.runtimeSecrets.auditExport,
          keys.secrets,
        ),
        new iam.PolicyStatement({
          actions: ["s3:PutObject"],
          resources: [buckets.audit.arnForObjects("server/audit/application/*")]
        }),
        this.kmsUseStatement(keys.audit.keyArn, ["kms:GenerateDataKey"])
      ],
    );

    const emailDeliveryUnit = this.createFunction(
      config,
      keys.logs,
      keys.secrets,
      alarmTopic,
      "EmailDelivery",
      "email-delivery",
      "email-delivery.ts",
      {
        DB_CLUSTER_ARN: database.cluster.clusterArn,
        ROOMSCAN_DB_ROLE_SECRET_ARN: database.runtimeSecrets.emailDelivery.secretArn,
        ROOMSCAN_DB_RUNTIME_ROLE: "roomscan_email_delivery_runtime",
        MAGIC_DELIVERY_ENVELOPE_SECRET_ARN: database.applicationSecrets.magicDeliveryEnvelope.secretArn,
        MAGIC_DELIVERY_KEY_ID: config.magicDeliveryKeyId,
        PUBLIC_BASE_URL: `https://${config.serviceDomain}`,
        SES_SENDER_ADDRESS: config.ses.senderAddress,
        SES_IDENTITY_ARN: config.ses.identityArn,
        SES_CONFIGURATION_SET_NAME: config.ses.configurationSetName,
        SES_MAGIC_LINK_TEMPLATE_NAME: `roomscan-${config.stage}-magic-link`
      },
      [
        ...this.dataApiStatements(
          config,
          database.cluster,
          database.runtimeSecrets.emailDelivery,
          keys.secrets,
        ),
        ...this.secretReadStatements(
          config,
          database.applicationSecrets.magicDeliveryEnvelope.secretArn,
          keys.secrets.keyArn,
        ),
        new iam.PolicyStatement({
          actions: ["ses:SendEmail"],
          resources: [config.ses.identityArn, this.sesConfigurationSetArn(config)]
        })
      ],
      "Dedicated targetless magic-link delivery worker",
    );
    emailDeliveryUnit.fn.node.addDependency(sesConfigurationSet);

    const migrationSecurityGroup = new ec2.SecurityGroup(this, "MigrationOperatorSecurityGroup", {
      vpc: database.vpc,
      description: "One-shot migration operator egress only to Aurora and the Secrets Manager endpoint",
      allowAllOutbound: false
    });
    const secretsEndpointSecurityGroup = new ec2.SecurityGroup(this, "SecretsManagerEndpointSecurityGroup", {
      vpc: database.vpc,
      description: "Private Secrets Manager endpoint ingress only from the migration operator",
      allowAllOutbound: false
    });
    database.securityGroup.addIngressRule(
      migrationSecurityGroup,
      ec2.Port.tcp(5432),
      "Direct TLS PostgreSQL only from the one-shot migration operator",
    );
    migrationSecurityGroup.addEgressRule(
      database.securityGroup,
      ec2.Port.tcp(5432),
      "Direct TLS PostgreSQL to Aurora",
    );
    secretsEndpointSecurityGroup.addIngressRule(
      migrationSecurityGroup,
      ec2.Port.tcp(443),
      "Secrets Manager TLS only from the migration operator",
    );
    migrationSecurityGroup.addEgressRule(
      secretsEndpointSecurityGroup,
      ec2.Port.tcp(443),
      "Secrets Manager TLS through the private endpoint",
    );
    const secretsEndpoint = new ec2.InterfaceVpcEndpoint(this, "SecretsManagerEndpoint", {
      vpc: database.vpc,
      service: ec2.InterfaceVpcEndpointAwsService.SECRETS_MANAGER,
      privateDnsEnabled: true,
      subnets: { subnetType: ec2.SubnetType.PRIVATE_ISOLATED },
      securityGroups: [secretsEndpointSecurityGroup],
      open: false
    });
    const migrationManifestSha256 = createHash("sha256")
      .update(readFileSync(resolve(process.cwd(), "assets/migration-manifest.json")))
      .digest("hex");
    const migrationUnit = this.createFunction(
      config,
      keys.logs,
      keys.secrets,
      alarmTopic,
      "MigrationOperator",
      "migration-operator",
      "migration-operator.ts",
      {
        DB_HOST: database.cluster.clusterEndpoint.hostname,
        DB_PORT: "5432",
        DB_NAME: "roomscan",
        DB_OWNER_SECRET_ARN: database.ownerSecret.secretArn,
        MIGRATIONS_PATH: "/var/task/migration-assets/migrations",
        MIGRATION_RUNNER_PATH: "/var/task/migration-assets/migrate.mjs",
        MIGRATION_MANIFEST_PATH: "/var/task/migration-assets/migration-manifest.json",
        MIGRATION_MANIFEST_SHA256: migrationManifestSha256,
        RDS_CA_BUNDLE_PATH: "/var/task/migration-assets/rds-global-bundle.pem",
        RUNTIME_ROLE_SECRET_ARNS_JSON: JSON.stringify({
          roomscan_api_runtime: database.runtimeSecrets.api.secretArn,
          roomscan_authorizer_runtime: database.runtimeSecrets.authorizer.secretArn,
          roomscan_auth_challenge_runtime: database.runtimeSecrets.authChallenge.secretArn,
          roomscan_stripe_ingress_runtime: database.runtimeSecrets.stripeIngress.secretArn,
          roomscan_stripe_reconciliation_runtime: database.runtimeSecrets.stripeReconciliation.secretArn,
          roomscan_audit_export_runtime: database.runtimeSecrets.auditExport.secretArn,
          roomscan_email_delivery_runtime: database.runtimeSecrets.emailDelivery.secretArn
        })
      },
      [
        ...this.secretReadStatements(
          config,
          database.ownerSecret.secretArn,
          keys.secrets.keyArn,
        ),
        ...Object.values(database.runtimeSecrets).flatMap((secret) =>
          this.secretReadStatements(config, secret.secretArn, keys.secrets.keyArn)),
        new iam.PolicyStatement({
          actions: [
            "ec2:AssignPrivateIpAddresses",
            "ec2:CreateNetworkInterface",
            "ec2:DeleteNetworkInterface",
            "ec2:DescribeNetworkInterfaces",
            "ec2:UnassignPrivateIpAddresses"
          ],
          resources: ["*"]
        })
      ],
      "Owner-only one-shot direct PostgreSQL migration and fixed-role credential initialization",
      {
        timeout: Duration.minutes(15),
        memorySize: 512,
        reservedConcurrentExecutions: 1,
        vpc: database.vpc,
        vpcSubnets: { subnetType: ec2.SubnetType.PRIVATE_ISOLATED },
        securityGroups: [migrationSecurityGroup],
        commandHooks: this.migrationBundleCommandHooks()
      },
    );
    migrationUnit.fn.node.addDependency(secretsEndpoint);

    const trailStatusMonitor = this.createFunction(
      config,
      keys.logs,
      keys.secrets,
      alarmTopic,
      "CloudTrailStatusMonitor",
      "cloudtrail-status-monitor",
      "cloudtrail-status-monitor.ts",
      {
        TRAIL_ARN: trail.trailArn,
        TRAIL_NAME: `roomscan-${config.stage}-platform`,
        METRIC_NAMESPACE: "RoomScan/CloudTrail",
        MAX_DELIVERY_AGE_SECONDS: "1800",
        MAX_DIGEST_AGE_SECONDS: "7200"
      },
      [
        new iam.PolicyStatement({
          actions: ["cloudtrail:GetTrailStatus"],
          resources: [trail.trailArn]
        }),
        new iam.PolicyStatement({
          actions: ["cloudwatch:PutMetricData"],
          resources: ["*"],
          conditions: {
            StringEquals: { "cloudwatch:namespace": "RoomScan/CloudTrail" }
          }
        })
      ],
      "Scheduled CloudTrail delivery and digest status monitor",
    );
    this.createCloudTrailStatusSchedule(config, trailStatusMonitor, alarmTopic);

    this.attachQueueConsumer(reconciliationUnit, queues.reconciliation);
    this.attachQueueConsumer(auditExporterUnit, queues.auditOutbox);
    this.attachQueueConsumer(emailDeliveryUnit, queues.emailDelivery);
    this.createQueueRecoverySchedules(config, queues);
    const identity = this.createIdentityBoundary(config, authChallengeUnit.alias);
    apiUnit.fn.addEnvironment("COGNITO_USER_POOL_ID", identity.userPool.userPoolId);
    apiUnit.fn.addEnvironment("COGNITO_SERVER_CLIENT_ID", identity.customAuthClient.userPoolClientId);
    apiUnit.policy.addStatements(new iam.PolicyStatement({
      actions: [
        "cognito-idp:AdminGetUser",
        "cognito-idp:AdminCreateUser",
        "cognito-idp:AdminLinkProviderForUser",
        "cognito-idp:AdminInitiateAuth",
        "cognito-idp:AdminRespondToAuthChallenge"
      ],
      resources: [identity.userPool.userPoolArn]
    }));
    this.createHttpApiBoundary(
      config,
      keys.logs,
      alarmTopic,
      authorizerUnit.alias,
      apiUnit.alias,
      stripeIngressUnit.alias,
    );

    this.createQueueAlarm("StripeReconciliationDlq", queues.reconciliationDlq, alarmTopic);
    this.createQueueAlarm("AuditOutboxDlq", queues.auditOutboxDlq, alarmTopic);
    this.createQueueAlarm("EmailDeliveryDlq", queues.emailDeliveryDlq, alarmTopic);
    this.createDatabaseAlarm(database.cluster, alarmTopic);
    this.createOutputs(config, buckets, database, queues);
  }

  private applyOwnershipTags(config: PlatformConfig): void {
    Tags.of(this).add("roomscan:system", "ai-redesign-platform");
    Tags.of(this).add("roomscan:stage", config.stage);
    Tags.of(this).add("roomscan:region", config.region);
    Tags.of(this).add("roomscan:operator-owner", config.operatorOwner);
    Tags.of(this).add("roomscan:managed-by", "aws-cdk");
  }

  private defineConfigurationMarkers(config: PlatformConfig): void {
    new ssm.StringParameter(this, "RegionInvariant", {
      parameterName: `/roomscan/${config.stage}/region-invariant`,
      stringValue: "us-east-1",
      description: "Fail-closed region invariant for the hosted platform"
    });
    new ssm.StringParameter(this, "StripeRawEnvelopeContract", {
      parameterName: `/roomscan/${config.stage}/stripe/raw-envelope-contract`,
      stringValue: "body+isBase64Encoded:unparsed-v1",
      description: "Stripe ingress receives the unparsed HTTP API v2 envelope"
    });
  }

  private createEncryptionKeys(config: PlatformConfig): EncryptionKeys {
    const create = (id: string, name: string): kms.Key => new kms.Key(this, id, {
      alias: `alias/roomscan/${config.stage}/${name}`,
      description: `RoomScan ${config.stage} ${name} customer-managed key`,
      enableKeyRotation: true,
      pendingWindow: Duration.days(30),
      removalPolicy: RemovalPolicy.RETAIN
    });
    const keys: EncryptionKeys = {
      logs: create("LogsKey", "logs"),
      database: create("DatabaseKey", "database"),
      assets: create("AssetsKey", "assets"),
      audit: create("AuditKey", "audit"),
      queues: create("QueuesKey", "queues"),
      secrets: create("SecretsKey", "secrets")
    };
    const trailArn = this.formatArn({
      service: "cloudtrail",
      resource: "trail",
      resourceName: `roomscan-${config.stage}-platform`,
      arnFormat: ArnFormat.SLASH_RESOURCE_NAME
    });
    keys.audit.addToResourcePolicy(new iam.PolicyStatement({
      sid: "AllowCloudTrailEncryption",
      principals: [new iam.ServicePrincipal("cloudtrail.amazonaws.com")],
      actions: ["kms:GenerateDataKey", "kms:GenerateDataKeyWithoutPlaintext"],
      resources: ["*"],
      conditions: {
        StringEquals: {
          "aws:SourceArn": trailArn,
          "kms:EncryptionContext:aws:cloudtrail:arn": trailArn
        }
      }
    }));
    keys.audit.addToResourcePolicy(new iam.PolicyStatement({
      sid: "AllowCloudTrailInspectionAndBucketKeyDecrypt",
      principals: [new iam.ServicePrincipal("cloudtrail.amazonaws.com")],
      actions: ["kms:Decrypt", "kms:DescribeKey"],
      resources: ["*"],
      conditions: { StringEquals: { "aws:SourceArn": trailArn } }
    }));
    for (const [sid, service, sourceArn] of [
      [
        "AllowCloudWatchAlarmEncryption",
        "cloudwatch.amazonaws.com",
        this.formatArn({
          service: "cloudwatch",
          resource: "alarm",
          resourceName: `roomscan-${config.stage}-*`,
          arnFormat: ArnFormat.COLON_RESOURCE_NAME
        })
      ],
      ["AllowSesEventEncryption", "ses.amazonaws.com", this.sesConfigurationSetArn(config)]
    ] as const) {
      keys.audit.addToResourcePolicy(new iam.PolicyStatement({
        sid,
        principals: [new iam.ServicePrincipal(service)],
        actions: ["kms:Decrypt", "kms:GenerateDataKey", "kms:GenerateDataKeyWithoutPlaintext"],
        resources: ["*"],
        conditions: {
          StringEquals: { "aws:SourceAccount": config.accountId },
          ArnLike: { "aws:SourceArn": sourceArn }
        }
      }));
    }
    keys.logs.addToResourcePolicy(new iam.PolicyStatement({
      sid: "AllowCloudWatchLogsEncryption",
      principals: [new iam.ServicePrincipal(`logs.${config.region}.amazonaws.com`)],
      actions: [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncryptFrom",
        "kms:ReEncryptTo",
        "kms:GenerateDataKey",
        "kms:GenerateDataKeyWithoutPlaintext",
        "kms:DescribeKey"
      ],
      resources: ["*"],
      conditions: {
        ArnLike: {
          "kms:EncryptionContext:aws:logs:arn": this.formatArn({
            service: "logs",
            resource: "log-group",
            resourceName: "/aws/*",
            arnFormat: ArnFormat.COLON_RESOURCE_NAME
          })
        }
      }
    }));
    return keys;
  }

  private createAlarmTopic(config: PlatformConfig, encryptionKey: kms.IKey): sns.Topic {
    const topic = new sns.Topic(this, "OperatorAlarmTopic", {
      displayName: `RoomScan ${config.stage} operator alarms`,
      masterKey: encryptionKey,
      topicName: `roomscan-${config.stage}-operator-alarms`
    });
    topic.addToResourcePolicy(new iam.PolicyStatement({
      sid: "AllowAccountCloudWatchAlarmPublication",
      principals: [new iam.ServicePrincipal("cloudwatch.amazonaws.com")],
      actions: ["sns:Publish"],
      resources: [topic.topicArn],
      conditions: {
        StringEquals: { "AWS:SourceAccount": config.accountId },
        ArnLike: {
          "AWS:SourceArn": this.formatArn({
            service: "cloudwatch",
            resource: "alarm",
            resourceName: `roomscan-${config.stage}-*`,
            arnFormat: ArnFormat.COLON_RESOURCE_NAME
          })
        }
      }
    }));
    topic.addSubscription(new snsSubscriptions.EmailSubscription(config.notificationEmail));
    return topic;
  }

  private createStorageBuckets(config: PlatformConfig, keys: EncryptionKeys): StorageBuckets {
    const create = (
      id: string,
      classification: string,
      prefix: string,
      encryptionKey: kms.IKey,
      lifecycleRules: s3.LifecycleRule[] = [{ abortIncompleteMultipartUploadAfter: Duration.days(7) }],
    ): s3.Bucket => {
      const bucket = new s3.Bucket(this, id, {
        versioned: true,
        objectOwnership: s3.ObjectOwnership.BUCKET_OWNER_ENFORCED,
        blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
        encryption: s3.BucketEncryption.KMS,
        encryptionKey,
        bucketKeyEnabled: true,
        enforceSSL: true,
        removalPolicy: RemovalPolicy.RETAIN,
        autoDeleteObjects: false,
        lifecycleRules
      });
      bucket.addToResourcePolicy(new iam.PolicyStatement({
        sid: "DenyWritesOutsideServerOwnedPrefix",
        effect: iam.Effect.DENY,
        principals: [new iam.AnyPrincipal()],
        actions: ["s3:PutObject"],
        notResources: [bucket.arnForObjects(`${prefix}*`)]
      }));
      bucket.addToResourcePolicy(new iam.PolicyStatement({
        sid: "DenyPresentNonKmsEncryptionOverride",
        effect: iam.Effect.DENY,
        principals: [new iam.AnyPrincipal()],
        actions: ["s3:PutObject"],
        resources: [bucket.arnForObjects("*")],
        conditions: {
          Null: { "s3:x-amz-server-side-encryption": "false" },
          StringNotEquals: { "s3:x-amz-server-side-encryption": "aws:kms" }
        }
      }));
      bucket.addToResourcePolicy(new iam.PolicyStatement({
        sid: "DenyKmsOverrideWithoutKeyId",
        effect: iam.Effect.DENY,
        principals: [new iam.AnyPrincipal()],
        actions: ["s3:PutObject"],
        resources: [bucket.arnForObjects("*")],
        conditions: {
          StringEquals: { "s3:x-amz-server-side-encryption": "aws:kms" },
          Null: { "s3:x-amz-server-side-encryption-aws-kms-key-id": "true" }
        }
      }));
      bucket.addToResourcePolicy(new iam.PolicyStatement({
        sid: "DenyPresentWrongKmsKeyOverride",
        effect: iam.Effect.DENY,
        principals: [new iam.AnyPrincipal()],
        actions: ["s3:PutObject"],
        resources: [bucket.arnForObjects("*")],
        conditions: {
          Null: { "s3:x-amz-server-side-encryption-aws-kms-key-id": "false" },
          StringNotEquals: {
            "s3:x-amz-server-side-encryption-aws-kms-key-id": encryptionKey.keyArn
          }
        }
      }));
      Tags.of(bucket).add("roomscan:data-class", classification);
      Tags.of(bucket).add("roomscan:server-owned-prefix", prefix);
      return bucket;
    };

    const quarantine = create("QuarantineBucket", "quarantine", "server/quarantine/", keys.assets);
    const active = create("ActiveBucket", "private-active", "server/active/", keys.assets);
    const published = create(
      "PublishedDerivativeBucket",
      "private-published-derivative",
      "server/published/",
      keys.assets,
    );
    const backup = create("BackupBucket", "backup", "server/backup/", keys.database);
    const audit = create(
      "AuditBucket",
      "protected-audit",
      "server/audit/",
      keys.audit,
      [{
        id: "BoundAuditRetention",
        enabled: true,
        abortIncompleteMultipartUploadAfter: Duration.days(7),
        expiration: Duration.days(200),
        noncurrentVersionExpiration: Duration.days(200)
      }],
    );
    audit.addToResourcePolicy(new iam.PolicyStatement({
      sid: "DenyCallerDrivenAuditDeletion",
      effect: iam.Effect.DENY,
      principals: [new iam.AnyPrincipal()],
      actions: ["s3:DeleteBucket", "s3:DeleteObject", "s3:DeleteObjectVersion"],
      resources: [audit.bucketArn, audit.arnForObjects("*")]
    }));
    return { quarantine, active, published, backup, audit };
  }

  private createCloudTrail(
    config: PlatformConfig,
    keys: EncryptionKeys,
    buckets: StorageBuckets,
  ): cloudtrail.Trail {
    const logGroup = this.createEncryptedLogGroup(
      "CloudTrailLogGroup",
      `/aws/cloudtrail/roomscan-${config.stage}`,
      keys.logs,
      logs.RetentionDays.THIRTEEN_MONTHS,
    );
    const trail = new cloudtrail.Trail(this, "PlatformTrail", {
      trailName: `roomscan-${config.stage}-platform`,
      bucket: buckets.audit,
      s3KeyPrefix: "server/audit/cloudtrail",
      encryptionKey: keys.audit,
      enableFileValidation: true,
      includeGlobalServiceEvents: true,
      isMultiRegionTrail: false,
      managementEvents: cloudtrail.ReadWriteType.ALL,
      sendToCloudWatchLogs: true,
      cloudWatchLogGroup: logGroup
    });
    trail.addS3EventSelector(
      [buckets.quarantine, buckets.active, buckets.published, buckets.backup]
        .map((bucket) => ({ bucket, objectPrefix: "server/" })),
      { readWriteType: cloudtrail.ReadWriteType.ALL },
    );
    return trail;
  }

  private createCloudTrailStatusSchedule(
    config: PlatformConfig,
    monitor: FunctionUnit,
    alarmTopic: sns.ITopic,
  ): void {
    const schedule = new events.Rule(this, "CloudTrailStatusSchedule", {
      ruleName: `roomscan-${config.stage}-cloudtrail-status-monitor`,
      description: "Poll CloudTrail delivery/digest status every five minutes",
      enabled: true,
      schedule: events.Schedule.rate(Duration.minutes(5))
    });
    schedule.addTarget(new eventsTargets.LambdaFunction(monitor.alias, {
      maxEventAge: Duration.minutes(10),
      retryAttempts: 2
    }));

    const dimensionsMap = {
      Stage: config.stage,
      TrailName: `roomscan-${config.stage}-platform`
    };
    for (const [id, metricName, description] of [
      [
        "CloudTrailDeliveryHealthAlarm",
        "TrailDeliveryHealthy",
        "CloudTrail reports disabled, errored, or stale log/digest delivery"
      ],
      [
        "CloudTrailStatusHeartbeatAlarm",
        "TrailStatusHeartbeat",
        "The scheduled CloudTrail status monitor stopped publishing its heartbeat"
      ]
    ] as const) {
      const alarm = new cloudwatch.Alarm(this, id, {
        alarmName: `roomscan-${config.stage}-${metricName === "TrailDeliveryHealthy" ? "cloudtrail-delivery-health" : "cloudtrail-status-heartbeat"}`,
        alarmDescription: description,
        metric: new cloudwatch.Metric({
          namespace: "RoomScan/CloudTrail",
          metricName,
          dimensionsMap,
          statistic: "Minimum",
          period: Duration.minutes(5)
        }),
        comparisonOperator: cloudwatch.ComparisonOperator.LESS_THAN_THRESHOLD,
        threshold: 1,
        evaluationPeriods: 1,
        treatMissingData: cloudwatch.TreatMissingData.BREACHING
      });
      alarm.addAlarmAction(new cloudwatchActions.SnsAction(alarmTopic));
      this.rollbackAlarms.push(alarm);
    }
  }

  private createDatabaseBoundary(config: PlatformConfig, keys: EncryptionKeys): DatabaseBoundary {
    const vpc = new ec2.Vpc(this, "DataVpc", {
      ipAddresses: ec2.IpAddresses.cidr("10.44.0.0/20"),
      maxAzs: 2,
      natGateways: 0,
      subnetConfiguration: [{
        name: "database-isolated",
        subnetType: ec2.SubnetType.PRIVATE_ISOLATED,
        cidrMask: 24
      }]
    });
    const databaseSecurityGroup = new ec2.SecurityGroup(this, "DatabaseSecurityGroup", {
      vpc,
      description: "Aurora has no public or client network ingress; runtime uses Data API",
      allowAllOutbound: false
    });
    const engine = rds.DatabaseClusterEngine.auroraPostgres({
      version: rds.AuroraPostgresEngineVersion.VER_16_8
    });
    const parameterGroup = new rds.ParameterGroup(this, "AuroraTlsParameterGroup", {
      engine,
      description: "Aurora PostgreSQL 16 TLS and privacy-aware audit posture",
      parameters: {
        "rds.force_ssl": "1",
        log_connections: "1",
        log_disconnections: "1",
        log_statement: "ddl",
        log_min_duration_statement: "1000"
      }
    });
    const ownerSecret = this.generatedDatabaseSecret(
      "DatabaseOwnerSecret", "roomscan_cluster_admin", config, keys.secrets,
    );
    const runtimeSecrets = {
      authorizer: this.generatedDatabaseSecret(
        "AuthorizerDatabaseSecret", "roomscan_authorizer_runtime", config, keys.secrets,
      ),
      api: this.generatedDatabaseSecret(
        "ApiDatabaseSecret", "roomscan_api_runtime", config, keys.secrets,
      ),
      authChallenge: this.generatedDatabaseSecret(
        "AuthChallengeDatabaseSecret", "roomscan_auth_challenge_runtime", config, keys.secrets,
      ),
      stripeIngress: this.generatedDatabaseSecret(
        "StripeIngressDatabaseSecret", "roomscan_stripe_ingress_runtime", config, keys.secrets,
      ),
      stripeReconciliation: this.generatedDatabaseSecret(
        "StripeReconciliationDatabaseSecret",
        "roomscan_stripe_reconciliation_runtime",
        config,
        keys.secrets,
      ),
      auditExport: this.generatedDatabaseSecret(
        "AuditExportDatabaseSecret", "roomscan_audit_export_runtime", config, keys.secrets,
      ),
      emailDelivery: this.generatedDatabaseSecret(
        "EmailDeliveryDatabaseSecret", "roomscan_email_delivery_runtime", config, keys.secrets,
      )
    } as const;
    const applicationSecrets = {
      accessTokenDigest: this.generatedApplicationSecret(
        "AccessTokenDigestSecret",
        "access-token-hmac-v1",
        config,
        keys.secrets,
      ),
      apiTokenDerivation: this.generatedApplicationSecret(
        "ApiTokenDerivationSecret",
        "api-token-domain-derivation-v1",
        config,
        keys.secrets,
      ),
      authChallengeProof: this.generatedApplicationSecret(
        "AuthChallengeProofSecret",
        "auth-challenge-proof-hmac-v1",
        config,
        keys.secrets,
      ),
      magicDeliveryEnvelope: this.generatedApplicationSecret(
        "MagicDeliveryEnvelopeSecret",
        "magic-delivery-aes-256-gcm-v1",
        config,
        keys.secrets,
      )
    } as const;

    const clusterIdentifier = `roomscan-${config.stage}`;
    const databaseLogGroup = this.createEncryptedLogGroup(
      "AuroraPostgresqlLogGroup",
      `/aws/rds/cluster/${clusterIdentifier}/postgresql`,
      keys.logs,
      logs.RetentionDays.THREE_MONTHS,
    );
    const cluster = new rds.DatabaseCluster(this, "AuroraCluster", {
      engine,
      credentials: rds.Credentials.fromSecret(ownerSecret),
      writer: rds.ClusterInstance.serverlessV2("Writer", {
        publiclyAccessible: false,
        enablePerformanceInsights: true,
        performanceInsightEncryptionKey: keys.database,
        performanceInsightRetention: rds.PerformanceInsightRetention.DEFAULT
      }),
      vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PRIVATE_ISOLATED },
      securityGroups: [databaseSecurityGroup],
      parameterGroup,
      clusterIdentifier,
      defaultDatabaseName: "roomscan",
      enableDataApi: true,
      iamAuthentication: true,
      storageEncrypted: true,
      storageEncryptionKey: keys.database,
      serverlessV2MinCapacity: config.aurora.minimumAcu,
      serverlessV2MaxCapacity: config.aurora.maximumAcu,
      backup: {
        retention: Duration.days(config.aurora.backupRetentionDays),
        preferredWindow: "03:00-04:00"
      },
      cloudwatchLogsExports: ["postgresql"],
      copyTagsToSnapshot: true,
      deletionProtection: config.stage === "production",
      removalPolicy: RemovalPolicy.RETAIN
    });
    cluster.node.addDependency(databaseLogGroup);
    const attachedRuntimeSecrets = {
      authorizer: runtimeSecrets.authorizer.attach(cluster),
      api: runtimeSecrets.api.attach(cluster),
      authChallenge: runtimeSecrets.authChallenge.attach(cluster),
      stripeIngress: runtimeSecrets.stripeIngress.attach(cluster),
      stripeReconciliation: runtimeSecrets.stripeReconciliation.attach(cluster),
      auditExport: runtimeSecrets.auditExport.attach(cluster),
      emailDelivery: runtimeSecrets.emailDelivery.attach(cluster)
    } as const;
    return {
      vpc,
      securityGroup: databaseSecurityGroup,
      cluster,
      ownerSecret,
      runtimeSecrets: attachedRuntimeSecrets,
      applicationSecrets
    };
  }

  private generatedDatabaseSecret(
    id: string,
    username: string,
    config: PlatformConfig,
    encryptionKey: kms.IKey,
  ): secretsmanager.Secret {
    const secret = new secretsmanager.Secret(this, id, {
      description: `Generated ${config.stage} database credential; initialization and rotation drills are release gates`,
      encryptionKey,
      generateSecretString: {
        secretStringTemplate: JSON.stringify({ username, rotationReady: true }),
        generateStringKey: "password",
        excludePunctuation: true,
        passwordLength: 48,
        requireEachIncludedType: true
      }
    });
    secret.applyRemovalPolicy(RemovalPolicy.RETAIN);
    Tags.of(secret).add("roomscan:rotation-ready", "true");
    return secret;
  }

  private generatedApplicationSecret(
    id: string,
    purpose: string,
    config: PlatformConfig,
    encryptionKey: kms.IKey,
  ): secretsmanager.Secret {
    const secret = new secretsmanager.Secret(this, id, {
      description: `Generated ${config.stage} ${purpose} material; rotation is an operator gate`,
      encryptionKey,
      generateSecretString: {
        secretStringTemplate: JSON.stringify({ purpose }),
        generateStringKey: "key",
        excludePunctuation: true,
        passwordLength: 64,
        requireEachIncludedType: true
      }
    });
    secret.applyRemovalPolicy(RemovalPolicy.RETAIN);
    Tags.of(secret).add("roomscan:rotation-ready", "true");
    Tags.of(secret).add("roomscan:cryptographic-purpose", purpose);
    return secret;
  }

  private createQueueBoundary(config: PlatformConfig, encryptionKey: kms.IKey): QueueBoundary {
    const reconciliationDlq = new sqs.Queue(this, "StripeReconciliationDlq", {
      queueName: `roomscan-${config.stage}-stripe-reconciliation-dlq`,
      encryption: sqs.QueueEncryption.KMS,
      encryptionMasterKey: encryptionKey,
      enforceSSL: true,
      retentionPeriod: Duration.days(14),
      removalPolicy: RemovalPolicy.RETAIN
    });
    const reconciliation = new sqs.Queue(this, "StripeReconciliationQueue", {
      queueName: `roomscan-${config.stage}-stripe-reconciliation`,
      encryption: sqs.QueueEncryption.KMS,
      encryptionMasterKey: encryptionKey,
      enforceSSL: true,
      retentionPeriod: Duration.days(4),
      visibilityTimeout: Duration.minutes(2),
      deadLetterQueue: { queue: reconciliationDlq, maxReceiveCount: 5 },
      removalPolicy: RemovalPolicy.RETAIN
    });
    const auditOutboxDlq = new sqs.Queue(this, "AuditOutboxDlq", {
      queueName: `roomscan-${config.stage}-audit-outbox-dlq`,
      encryption: sqs.QueueEncryption.KMS,
      encryptionMasterKey: encryptionKey,
      enforceSSL: true,
      retentionPeriod: Duration.days(14),
      removalPolicy: RemovalPolicy.RETAIN
    });
    const auditOutbox = new sqs.Queue(this, "AuditOutboxQueue", {
      queueName: `roomscan-${config.stage}-audit-outbox`,
      encryption: sqs.QueueEncryption.KMS,
      encryptionMasterKey: encryptionKey,
      enforceSSL: true,
      retentionPeriod: Duration.days(4),
      visibilityTimeout: Duration.minutes(2),
      deadLetterQueue: { queue: auditOutboxDlq, maxReceiveCount: 5 },
      removalPolicy: RemovalPolicy.RETAIN
    });
    const emailDeliveryDlq = new sqs.Queue(this, "EmailDeliveryDlq", {
      queueName: `roomscan-${config.stage}-email-delivery-dlq`,
      encryption: sqs.QueueEncryption.KMS,
      encryptionMasterKey: encryptionKey,
      enforceSSL: true,
      retentionPeriod: Duration.days(14),
      removalPolicy: RemovalPolicy.RETAIN
    });
    const emailDelivery = new sqs.Queue(this, "EmailDeliveryQueue", {
      queueName: `roomscan-${config.stage}-email-delivery`,
      encryption: sqs.QueueEncryption.KMS,
      encryptionMasterKey: encryptionKey,
      enforceSSL: true,
      retentionPeriod: Duration.days(4),
      visibilityTimeout: Duration.minutes(2),
      deadLetterQueue: { queue: emailDeliveryDlq, maxReceiveCount: 5 },
      removalPolicy: RemovalPolicy.RETAIN
    });
    return {
      reconciliation,
      reconciliationDlq,
      auditOutbox,
      auditOutboxDlq,
      emailDelivery,
      emailDeliveryDlq
    };
  }

  private createQueueRecoverySchedules(config: PlatformConfig, queues: QueueBoundary): void {
    for (const [id, name, queue, kind, rate] of [
      [
        "StripeReconciliationRecoverySchedule",
        `roomscan-${config.stage}-stripe-reconciliation-recovery`,
        queues.reconciliation,
        "stripe-reconciliation-recovery-v1",
        Duration.minutes(1)
      ],
      [
        "AuditOutboxRecoverySchedule",
        `roomscan-${config.stage}-audit-outbox-recovery`,
        queues.auditOutbox,
        "audit-outbox-recovery-v1",
        Duration.minutes(5)
      ],
      [
        "EmailDeliveryRecoverySchedule",
        `roomscan-${config.stage}-email-delivery-recovery`,
        queues.emailDelivery,
        "magic-delivery-recovery-v1",
        Duration.minutes(1)
      ]
    ] as const) {
      const rule = new events.Rule(this, id, {
        ruleName: name,
        description: `Durable ${kind} wake; the database lease remains authoritative`,
        enabled: true,
        schedule: events.Schedule.rate(rate)
      });
      rule.addTarget(new eventsTargets.SqsQueue(queue, {
        message: events.RuleTargetInput.fromObject({ kind })
      }));
    }
  }

  private createSesBoundary(config: PlatformConfig, notificationTopic: sns.Topic): ses.CfnConfigurationSet {
    const configurationSet = new ses.CfnConfigurationSet(this, "SesConfigurationSet", {
      name: config.ses.configurationSetName,
      reputationOptions: { reputationMetricsEnabled: true },
      sendingOptions: { sendingEnabled: true }
    });
    const destination = new ses.CfnConfigurationSetEventDestination(
      this,
      "SesBounceComplaintDestination",
      {
        configurationSetName: configurationSet.ref,
        eventDestination: {
          enabled: true,
          name: "security-events",
          matchingEventTypes: ["BOUNCE", "COMPLAINT", "REJECT"],
          snsDestination: { topicArn: notificationTopic.topicArn }
        }
      },
    );
    destination.addResourceDependency(configurationSet);
    notificationTopic.addToResourcePolicy(new iam.PolicyStatement({
      sid: "AllowSesEventPublication",
      principals: [new iam.ServicePrincipal("ses.amazonaws.com")],
      actions: ["sns:Publish"],
      resources: [notificationTopic.topicArn],
      conditions: {
        StringEquals: { "AWS:SourceAccount": config.accountId },
        ArnLike: { "AWS:SourceArn": this.sesConfigurationSetArn(config) }
      }
    }));
    return configurationSet;
  }

  private sesConfigurationSetArn(config: PlatformConfig): string {
    return this.formatArn({
      service: "ses",
      resource: "configuration-set",
      resourceName: config.ses.configurationSetName,
      arnFormat: ArnFormat.SLASH_RESOURCE_NAME
    });
  }

  private migrationBundleCommandHooks(): ICommandHooks {
    const runner = resolve(process.cwd(), "../db/migrate.mjs");
    const migrationsDirectory = resolve(process.cwd(), "../db/migrations");
    const manifest = resolve(process.cwd(), "assets/migration-manifest.json");
    const caBundle = resolve(process.cwd(), "assets/rds-global-bundle-2026-08-19.pem");
    const migrationNames = expectedMigrationLedger().map((migration) => migration.name);
    return {
      beforeInstall: () => [],
      beforeBundling: () => [],
      afterBundling: (_inputDirectory, outputDirectory) => {
        const assetDirectory = `${outputDirectory}/migration-assets`;
        const bundledMigrations = `${assetDirectory}/migrations`;
        return [
          `mkdir -p ${shellQuote(bundledMigrations)}`,
          `cp ${shellQuote(runner)} ${shellQuote(`${assetDirectory}/migrate.mjs`)}`,
          ...migrationNames.map((name) =>
            `cp ${shellQuote(resolve(migrationsDirectory, name))} ${shellQuote(`${bundledMigrations}/${name}`)}`),
          `cp ${shellQuote(manifest)} ${shellQuote(`${assetDirectory}/migration-manifest.json`)}`,
          `cp ${shellQuote(caBundle)} ${shellQuote(`${assetDirectory}/rds-global-bundle.pem`)}`
        ];
      }
    };
  }

  private createFunction(
    config: PlatformConfig,
    logKey: kms.IKey,
    environmentKey: kms.IKey,
    alarmTopic: sns.ITopic,
    id: string,
    functionSuffix: string,
    entryName: string,
    environment: Readonly<Record<string, string>>,
    statements: readonly iam.PolicyStatement[],
    description = "Concrete Slice 4 runtime with validated lane-specific configuration",
    options: FunctionOptions = {},
  ): FunctionUnit {
    const functionName = `roomscan-${config.stage}-${functionSuffix}`;
    const role = new iam.Role(this, `${id}Role`, {
      assumedBy: new iam.ServicePrincipal("lambda.amazonaws.com"),
      description: `Least-privilege execution role for ${functionName}`,
      maxSessionDuration: Duration.hours(1)
    });
    Tags.of(role).add("roomscan:role-boundary", functionSuffix);
    const logGroup = this.createEncryptedLogGroup(
      `${id}LogGroup`,
      `/aws/lambda/${functionName}`,
      logKey,
      logs.RetentionDays.THREE_MONTHS,
    );
    const policy = new iam.Policy(this, `${id}Policy`, {
      statements: [
        new iam.PolicyStatement({
          actions: ["logs:CreateLogStream", "logs:PutLogEvents"],
          resources: [logGroup.logGroupArn]
        }),
        ...statements
      ]
    });
    role.attachInlinePolicy(policy);
    const fn = new NodejsFunction(this, `${id}Function`, {
      functionName,
      description,
      entry: resolve(process.cwd(), "src/functions", entryName),
      depsLockFilePath: resolve(process.cwd(), "package-lock.json"),
      handler: "handler",
      runtime: lambda.Runtime.NODEJS_24_X,
      architecture: lambda.Architecture.ARM_64,
      memorySize: options.memorySize ?? 256,
      timeout: options.timeout ?? Duration.seconds(15),
      reservedConcurrentExecutions: options.reservedConcurrentExecutions,
      vpc: options.vpc,
      vpcSubnets: options.vpcSubnets,
      securityGroups: options.securityGroups === undefined ? undefined : [...options.securityGroups],
      role,
      logGroup,
      environmentEncryption: environmentKey,
      environment: {
        ROOMSCAN_STAGE: config.stage,
        ROOMSCAN_REGION: config.region,
        ...environment
      },
      bundling: {
        target: "node24",
        format: OutputFormat.ESM,
        minify: false,
        sourceMap: true,
        sourcesContent: false,
        esbuildArgs: { "--legal-comments": "none" },
        commandHooks: options.commandHooks
      }
    });
    const version = fn.currentVersion;
    version.applyRemovalPolicy(RemovalPolicy.RETAIN);
    const alias = new lambda.Alias(this, `${id}LiveAlias`, {
      aliasName: "live",
      version,
      description: `Immutable live alias for ${functionName}`
    });
    const errorAlarm = new cloudwatch.Alarm(this, `${id}ErrorAlarm`, {
      alarmName: `${functionName}-errors`,
      alarmDescription: `${functionName} reported one or more errors`,
      metric: alias.metricErrors({ period: Duration.minutes(5), statistic: "Sum" }),
      threshold: 1,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING
    });
    const throttleAlarm = new cloudwatch.Alarm(this, `${id}ThrottleAlarm`, {
      alarmName: `${functionName}-throttles`,
      alarmDescription: `${functionName} was throttled`,
      metric: alias.metricThrottles({ period: Duration.minutes(5), statistic: "Sum" }),
      threshold: 1,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING
    });
    for (const alarm of [errorAlarm, throttleAlarm]) {
      alarm.addAlarmAction(new cloudwatchActions.SnsAction(alarmTopic));
      this.rollbackAlarms.push(alarm);
    }
    new CfnOutput(this, `${id}AliasArn`, {
      description: `Rollback-safe live alias for ${functionName}`,
      value: alias.functionArn
    });
    return { fn, alias, role, policy, logGroup, errorAlarm, throttleAlarm };
  }

  private dataApiStatements(
    config: PlatformConfig,
    cluster: rds.IDatabaseCluster,
    secret: secretsmanager.ISecret,
    encryptionKey: kms.IKey,
  ): iam.PolicyStatement[] {
    return [
      new iam.PolicyStatement({
        actions: [
          "rds-data:BatchExecuteStatement",
          "rds-data:BeginTransaction",
          "rds-data:CommitTransaction",
          "rds-data:ExecuteStatement",
          "rds-data:RollbackTransaction"
        ],
        resources: [cluster.clusterArn]
      }),
      ...this.secretReadStatements(config, secret.secretArn, encryptionKey.keyArn)
    ];
  }

  private secretReadStatements(
    config: PlatformConfig,
    secretArn: string,
    encryptionKeyArn: string,
  ): iam.PolicyStatement[] {
    return [
      new iam.PolicyStatement({
        actions: ["secretsmanager:DescribeSecret", "secretsmanager:GetSecretValue"],
        resources: [secretArn]
      }),
      new iam.PolicyStatement({
        actions: ["kms:Decrypt"],
        resources: [encryptionKeyArn],
        conditions: {
          StringEquals: {
            "kms:ViaService": `secretsmanager.${config.region}.amazonaws.com`,
            "kms:EncryptionContext:SecretARN": secretArn
          }
        }
      })
    ];
  }

  private kmsUseStatement(
    keyArn: string,
    actions: readonly ("kms:Decrypt" | "kms:GenerateDataKey")[],
  ): iam.PolicyStatement {
    return new iam.PolicyStatement({ actions: [...actions], resources: [keyArn] });
  }

  private attachQueueConsumer(unit: FunctionUnit, queue: sqs.Queue): void {
    unit.alias.addEventSource(new lambdaEventSources.SqsEventSource(queue, {
      batchSize: 10,
      maxBatchingWindow: Duration.seconds(5),
      reportBatchItemFailures: true,
      enabled: true
    }));
  }

  private createIdentityBoundary(
    config: PlatformConfig,
    authChallengeAlias: lambda.IAlias,
  ): IdentityBoundary {
    const userPool = new cognito.UserPool(this, "ProfessionalUserPool", {
      userPoolName: `roomscan-${config.stage}-professional`,
      selfSignUpEnabled: false,
      signInAliases: { email: true },
      signInCaseSensitive: false,
      accountRecovery: cognito.AccountRecovery.NONE,
      deletionProtection: config.stage === "production",
      removalPolicy: RemovalPolicy.RETAIN
    });
    userPool.addTrigger(cognito.UserPoolOperation.DEFINE_AUTH_CHALLENGE, authChallengeAlias);
    userPool.addTrigger(cognito.UserPoolOperation.CREATE_AUTH_CHALLENGE, authChallengeAlias);
    userPool.addTrigger(cognito.UserPoolOperation.VERIFY_AUTH_CHALLENGE_RESPONSE, authChallengeAlias);

    const appleSecret = secretsmanager.Secret.fromSecretCompleteArn(
      this,
      "ApplePrivateKeyReference",
      config.apple.privateKeySecretArn,
    );
    const appleProvider = new cognito.UserPoolIdentityProviderApple(this, "AppleProvider", {
      userPool,
      clientId: config.apple.clientId,
      teamId: config.apple.teamId,
      keyId: config.apple.keyId,
      privateKeyValue: SecretValue.secretsManager(appleSecret.secretArn, { jsonField: "privateKey" }),
      scopes: ["email", "name"],
      attributeMapping: {
        email: cognito.ProviderAttribute.APPLE_EMAIL,
        fullname: cognito.ProviderAttribute.APPLE_NAME
      }
    });
    const federationDomain = userPool.addDomain("ProfessionalFederationDomain", {
      cognitoDomain: { domainPrefix: config.cognitoDomainPrefix },
      managedLoginVersion: cognito.ManagedLoginVersion.CLASSIC_HOSTED_UI
    });
    appleProvider.node.addDependency(federationDomain);
    const federationClient = new cognito.UserPoolClient(this, "AppleFederationClient", {
      userPool,
      userPoolClientName: `roomscan-${config.stage}-apple-federation`,
      generateSecret: true,
      preventUserExistenceErrors: true,
      authSessionValidity: Duration.minutes(3),
      authFlows: {
        custom: false,
        userPassword: false,
        userSrp: false,
        adminUserPassword: false
      },
      supportedIdentityProviders: [
        cognito.UserPoolClientIdentityProvider.APPLE
      ],
      oAuth: {
        flows: {
          authorizationCodeGrant: true,
          implicitCodeGrant: false,
          clientCredentials: false
        },
        callbackUrls: [`https://${config.serviceDomain}/auth/apple/callback`],
        logoutUrls: [`https://${config.serviceDomain}/auth/logout-complete`],
        scopes: [cognito.OAuthScope.OPENID, cognito.OAuthScope.EMAIL]
      },
      accessTokenValidity: Duration.minutes(5),
      idTokenValidity: Duration.minutes(5),
      refreshTokenValidity: Duration.days(30),
      enableTokenRevocation: true,
      refreshTokenRotationGracePeriod: Duration.seconds(0)
    });
    federationClient.node.addDependency(appleProvider);
    federationClient.node.addDependency(federationDomain);
    const customAuthClient = new cognito.UserPoolClient(this, "ServerCustomAuthClient", {
      userPool,
      userPoolClientName: `roomscan-${config.stage}-server-custom-auth`,
      generateSecret: false,
      preventUserExistenceErrors: true,
      authSessionValidity: Duration.minutes(3),
      authFlows: {
        custom: true,
        userPassword: false,
        userSrp: false,
        adminUserPassword: false
      },
      accessTokenValidity: Duration.minutes(5),
      idTokenValidity: Duration.minutes(5),
      refreshTokenValidity: Duration.days(1),
      enableTokenRevocation: true
    });
    const customAuthResource = customAuthClient.node.defaultChild as cognito.CfnUserPoolClient;
    // The L2 adds ALLOW_REFRESH_TOKEN_AUTH implicitly. This client is a
    // secretless, server-initiated custom-challenge client and must authorize
    // no flow other than the signed CUSTOM_AUTH exchange.
    customAuthResource.explicitAuthFlows = ["ALLOW_CUSTOM_AUTH"];
    customAuthResource.allowedOAuthFlows = undefined;
    customAuthResource.allowedOAuthFlowsUserPoolClient = undefined;
    customAuthResource.allowedOAuthScopes = undefined;
    customAuthResource.callbackUrLs = undefined;
    customAuthResource.logoutUrLs = undefined;
    customAuthResource.refreshTokenRotation = undefined;
    customAuthResource.refreshTokenValidity = undefined;
    customAuthResource.supportedIdentityProviders = ["COGNITO"];
    customAuthResource.tokenValidityUnits = {
      accessToken: "minutes",
      idToken: "minutes"
    };
    const federationBaseUrl = federationDomain.baseUrl();
    new CfnOutput(this, "ProfessionalUserPoolId", { value: userPool.userPoolId });
    new CfnOutput(this, "AppleFederationClientId", { value: federationClient.userPoolClientId });
    new CfnOutput(this, "ServerCustomAuthClientId", { value: customAuthClient.userPoolClientId });
    new CfnOutput(this, "AppleFederationAuthorizeEndpoint", {
      description: "Server federation/redirect substrate only; the app-owned API remains session authority",
      value: `${federationBaseUrl}/oauth2/authorize`
    });
    new CfnOutput(this, "AppleIdentityProviderCallbackUrl", {
      description: "Register this Cognito bridge callback with Apple; it is not the app callback",
      value: `${federationBaseUrl}/oauth2/idpresponse`
    });
    return { userPool, federationClient, customAuthClient };
  }

  private createHttpApiBoundary(
    config: PlatformConfig,
    logKey: kms.IKey,
    alarmTopic: sns.ITopic,
    authorizerAlias: lambda.IAlias,
    apiAlias: lambda.IAlias,
    stripeAlias: lambda.IAlias,
  ): void {
    const accessLogGroup = this.createEncryptedLogGroup(
      "HttpApiAccessLogGroup",
      `/aws/apigateway/roomscan-${config.stage}`,
      logKey,
      logs.RetentionDays.THREE_MONTHS,
    );
    const httpApi = new apigatewayv2.HttpApi(this, "PrivateControlPlane", {
      apiName: `roomscan-${config.stage}-control-plane`,
      description: "RoomScan app-owned control plane; protected routes use centralized authorization",
      createDefaultStage: false,
      disableExecuteApiEndpoint: false
    });
    const stage = new apigatewayv2.HttpStage(this, "ControlPlaneStage", {
      httpApi,
      stageName: "$default",
      autoDeploy: true
    });
    const cfnStage = stage.node.defaultChild as apigatewayv2.CfnStage;
    cfnStage.accessLogSettings = {
      destinationArn: accessLogGroup.logGroupArn,
      format: JSON.stringify({
        requestId: "$context.requestId",
        routeKey: "$context.routeKey",
        status: "$context.status",
        protocol: "$context.protocol",
        responseLength: "$context.responseLength",
        responseLatency: "$context.responseLatency"
      })
    };

    const authorizer = new apigatewayv2Authorizers.HttpLambdaAuthorizer(
      "CentralAppAuthorization",
      authorizerAlias,
      {
        authorizerName: "roomscan-central-app-authorization",
        identitySource: ["$request.header.Authorization"],
        resultsCacheTtl: Duration.seconds(0),
        responseTypes: [apigatewayv2Authorizers.HttpLambdaResponseType.SIMPLE]
      },
    );
    const apiIntegration = new apigatewayv2Integrations.HttpLambdaIntegration(
      "CanonicalApiIntegration",
      apiAlias,
      { payloadFormatVersion: apigatewayv2.PayloadFormatVersion.VERSION_2_0 },
    );
    const stripeIntegration = new apigatewayv2Integrations.HttpLambdaIntegration(
      "StripeRawWebhookIntegration",
      stripeAlias,
      {
        payloadFormatVersion: apigatewayv2.PayloadFormatVersion.VERSION_2_0,
        timeout: Duration.seconds(15)
      },
    );
    for (const route of SLICE4_ROUTE_MANIFEST) {
      const isStripe = route.id === "stripe.webhook";
      httpApi.addRoutes({
        path: this.httpApiPath(route),
        methods: [route.method === "GET" ? apigatewayv2.HttpMethod.GET : apigatewayv2.HttpMethod.POST],
        integration: isStripe ? stripeIntegration : apiIntegration,
        authorizer: route.authorization.kind === "public"
          ? new apigatewayv2.HttpNoneAuthorizer()
          : authorizer
      });
    }

    const apiAlarm = new cloudwatch.Alarm(this, "HttpApiServerErrorAlarm", {
      alarmName: `roomscan-${config.stage}-http-api-server-errors`,
      alarmDescription: "HTTP API reported server errors",
      metric: httpApi.metricServerError({ period: Duration.minutes(5), statistic: "Sum" }),
      threshold: 1,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING
    });
    apiAlarm.addAlarmAction(new cloudwatchActions.SnsAction(alarmTopic));
    this.rollbackAlarms.push(apiAlarm);
    new CfnOutput(this, "HttpApiEndpoint", {
      description: "Control-plane endpoint; deployment remains unauthorized by this template",
      value: httpApi.apiEndpoint
    });
  }

  private httpApiPath(route: SealedRoute): string {
    return route.pathTemplate.replace(/:([A-Za-z][A-Za-z0-9_]*)/gu, "{$1}");
  }

  private createQueueAlarm(id: string, queue: sqs.Queue, alarmTopic: sns.ITopic): void {
    const alarm = new cloudwatch.Alarm(this, `${id}VisibleMessagesAlarm`, {
      alarmName: `${queue.queueName}-visible-messages`,
      alarmDescription: `${queue.queueName} contains a dead-letter message`,
      metric: queue.metricApproximateNumberOfMessagesVisible({
        period: Duration.minutes(5),
        statistic: "Maximum"
      }),
      threshold: 1,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING
    });
    alarm.addAlarmAction(new cloudwatchActions.SnsAction(alarmTopic));
    this.rollbackAlarms.push(alarm);
  }

  private createDatabaseAlarm(cluster: rds.IDatabaseCluster, alarmTopic: sns.ITopic): void {
    const alarm = new cloudwatch.Alarm(this, "AuroraDeadlocksAlarm", {
      alarmName: `${cluster.clusterIdentifier}-deadlocks`,
      alarmDescription: "Aurora reported a database deadlock",
      metric: new cloudwatch.Metric({
        namespace: "AWS/RDS",
        metricName: "Deadlocks",
        dimensionsMap: { DBClusterIdentifier: cluster.clusterIdentifier },
        period: Duration.minutes(5),
        statistic: "Sum"
      }),
      threshold: 1,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING
    });
    alarm.addAlarmAction(new cloudwatchActions.SnsAction(alarmTopic));
    this.rollbackAlarms.push(alarm);
  }

  private createEncryptedLogGroup(
    id: string,
    logGroupName: string,
    encryptionKey: kms.IKey,
    retention: logs.RetentionDays,
  ): logs.LogGroup {
    return new logs.LogGroup(this, id, {
      logGroupName,
      encryptionKey,
      retention,
      removalPolicy: RemovalPolicy.RETAIN
    });
  }

  private createOutputs(
    config: PlatformConfig,
    buckets: StorageBuckets,
    database: DatabaseBoundary,
    queues: QueueBoundary,
  ): void {
    const topology = config.accountTopology;
    for (const [name, value] of [
      ["ManagementAccountId", topology.management],
      ["LogArchiveAccountId", topology.logArchive],
      ["SecurityAuditAccountId", topology.securityAudit],
      ["DevWorkloadAccountId", topology.dev],
      ["StagingWorkloadAccountId", topology.staging],
      ["ProductionWorkloadAccountId", topology.production]
    ] as const) {
      new CfnOutput(this, name, {
        description: "Consumed account-topology configuration; this stack creates no AWS account",
        value
      });
    }
    for (const [name, value] of [
      ["QuarantineBucketArn", buckets.quarantine.bucketArn],
      ["ActiveBucketArn", buckets.active.bucketArn],
      ["PublishedDerivativeBucketArn", buckets.published.bucketArn],
      ["BackupBucketArn", buckets.backup.bucketArn],
      ["AuditBucketArn", buckets.audit.bucketArn],
      ["AuroraClusterArn", database.cluster.clusterArn],
      ["DatabaseOwnerSecretArn", database.ownerSecret.secretArn],
      ["AuthorizerDatabaseSecretArn", database.runtimeSecrets.authorizer.secretArn],
      ["ApiDatabaseSecretArn", database.runtimeSecrets.api.secretArn],
      ["AuthChallengeDatabaseSecretArn", database.runtimeSecrets.authChallenge.secretArn],
      ["StripeIngressDatabaseSecretArn", database.runtimeSecrets.stripeIngress.secretArn],
      [
        "StripeReconciliationDatabaseSecretArn",
        database.runtimeSecrets.stripeReconciliation.secretArn
      ],
      ["AuditExportDatabaseSecretArn", database.runtimeSecrets.auditExport.secretArn],
      ["EmailDeliveryDatabaseSecretArn", database.runtimeSecrets.emailDelivery.secretArn],
      ["StripeReconciliationQueueArn", queues.reconciliation.queueArn],
      ["AuditOutboxQueueArn", queues.auditOutbox.queueArn],
      ["EmailDeliveryQueueArn", queues.emailDelivery.queueArn]
    ] as const) {
      new CfnOutput(this, name, { value });
    }
    new CfnOutput(this, "RollbackAlarmArns", {
      description: "Pass these alarms as CloudFormation rollback triggers during an authorized deployment",
      value: Stack.of(this).toJsonString(this.rollbackAlarms.map((alarm) => alarm.alarmArn))
    });
  }
}

function expectedMigrationLedger(): readonly Readonly<{
  readonly version: string;
  readonly name: string;
  readonly checksumSha256: string;
}>[] {
  const directory = resolve(process.cwd(), "../db/migrations");
  const names = readdirSync(directory)
    .filter((name) => /^\d{4}_[a-z0-9_]+\.up\.sql$/u.test(name))
    .sort();
  if (names.length !== 7 || names.some((name, index) => name.slice(0, 4) !== String(index + 1).padStart(4, "0"))) {
    throw new Error("expected the exact forward-only 0001-0007 migration set");
  }
  return Object.freeze(names.map((name) => Object.freeze({
    version: name.slice(0, 4),
    name,
    checksumSha256: createHash("sha256").update(readFileSync(resolve(directory, name))).digest("hex")
  })));
}

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", "'\\''")}'`;
}
