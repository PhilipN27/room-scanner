interface CloudFormationResource {
  readonly Type: string;
  readonly Properties?: Readonly<Record<string, unknown>>;
  readonly DeletionPolicy?: string;
  readonly UpdateReplacePolicy?: string;
}

export class InfrastructurePolicyError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "InfrastructurePolicyError";
  }
}

export function assertInfrastructurePolicy(template: Readonly<Record<string, unknown>>): void {
  const resources = readResources(template);
  assertRegionInvariant(resources);
  assertStripeEnvelopeContract(resources);
  assertNoLaterSliceResources(resources);
  assertS3Boundaries(resources);
  assertLogBoundaries(resources);
  assertAuroraBoundary(resources);
  assertRuntimeDatabaseLanes(resources);
  assertLambdaBoundary(resources);
  assertIamPolicies(resources);
  assertSecretsKeyDecryptBoundary(resources);
  assertKmsUsageBoundary(resources);
  assertAlarmTopicBoundary(resources);
  assertCloudTrail(resources);
  assertCloudTrailStatusMonitoring(resources);
  assertCognitoFederationBoundary(resources);
  assertHttpApi(resources);
  assertRecoverySchedules(resources);
}

function assertNoLaterSliceResources(resources: Readonly<Record<string, CloudFormationResource>>): void {
  if (/slice7-backup-restore|Slice7BackupRestoreGate/u.test(serialized(resources))) {
    throw new InfrastructurePolicyError("Slice 7 backup/restore resources are outside the Slice 4 template");
  }
}

function readResources(
  template: Readonly<Record<string, unknown>>,
): Readonly<Record<string, CloudFormationResource>> {
  const resources = template.Resources;
  if (!isRecord(resources)) {
    throw new InfrastructurePolicyError("CloudFormation Resources must be present");
  }
  for (const resource of Object.values(resources)) {
    if (!isRecord(resource) || typeof resource.Type !== "string") {
      throw new InfrastructurePolicyError("every CloudFormation resource must declare a type");
    }
  }
  return resources as Readonly<Record<string, CloudFormationResource>>;
}

function assertRegionInvariant(resources: Readonly<Record<string, CloudFormationResource>>): void {
  const regionParameter = ofType(resources, "AWS::SSM::Parameter").find(
    (resource) => resource.Properties?.Name === "/roomscan/dev/region-invariant" ||
      resource.Properties?.Name === "/roomscan/staging/region-invariant" ||
      resource.Properties?.Name === "/roomscan/production/region-invariant",
  );
  if (regionParameter?.Properties?.Value !== "us-east-1") {
    throw new InfrastructurePolicyError("the synthesized region invariant must remain us-east-1");
  }
}

function assertStripeEnvelopeContract(
  resources: Readonly<Record<string, CloudFormationResource>>,
): void {
  const marker = ofType(resources, "AWS::SSM::Parameter").find((resource) =>
    typeof resource.Properties?.Name === "string" &&
    resource.Properties.Name.endsWith("/stripe/raw-envelope-contract")
  );
  if (marker?.Properties?.Value !== "body+isBase64Encoded:unparsed-v1") {
    throw new InfrastructurePolicyError("the raw Stripe envelope contract must remain unparsed");
  }
}

function assertS3Boundaries(resources: Readonly<Record<string, CloudFormationResource>>): void {
  const buckets = Object.entries(resources).filter(([, resource]) => resource.Type === "AWS::S3::Bucket");
  if (buckets.length !== 5) {
    throw new InfrastructurePolicyError("exactly five private S3 data boundaries are required");
  }
  for (const [logicalId, bucket] of buckets) {
    const properties = bucket.Properties ?? {};
    const publicAccess = properties.PublicAccessBlockConfiguration;
    if (
      !isRecord(publicAccess) ||
      publicAccess.BlockPublicAcls !== true ||
      publicAccess.BlockPublicPolicy !== true ||
      publicAccess.IgnorePublicAcls !== true ||
      publicAccess.RestrictPublicBuckets !== true
    ) {
      throw new InfrastructurePolicyError("S3 public access must remain fully blocked");
    }
    if (JSON.stringify(properties.VersioningConfiguration) !== "{\"Status\":\"Enabled\"}") {
      throw new InfrastructurePolicyError("every S3 boundary must remain versioned");
    }
    if (!serialized(properties.BucketEncryption).includes("aws:kms")) {
      throw new InfrastructurePolicyError("every S3 boundary must remain SSE-KMS encrypted");
    }
    if (!serialized(properties.OwnershipControls).includes("BucketOwnerEnforced")) {
      throw new InfrastructurePolicyError("every S3 boundary must remain bucket-owner enforced");
    }
    if (bucket.DeletionPolicy !== "Retain" || bucket.UpdateReplacePolicy !== "Retain") {
      throw new InfrastructurePolicyError("S3 boundaries must be retained and never auto-destroyed");
    }
    const policy = Object.values(resources).find(
      (resource) => resource.Type === "AWS::S3::BucketPolicy" &&
        serialized(resource.Properties?.Bucket).includes(logicalId),
    );
    if (policy === undefined || !hasExactCmkOverrideDenies(policy, properties.BucketEncryption)) {
      throw new InfrastructurePolicyError(
        "S3 encryption overrides must deny AES256, aws-managed KMS, and wrong CMKs while allowing defaults",
      );
    }
  }

  const policies = ofType(resources, "AWS::S3::BucketPolicy");
  if (policies.length !== 5) {
    throw new InfrastructurePolicyError("every S3 boundary requires an explicit bucket policy");
  }
  for (const policy of policies) {
    const statements = policyStatements(policy);
    const tlsDeny = statements.some((statement) =>
      statement.Effect === "Deny" &&
      serialized(statement.Condition).includes("aws:SecureTransport") &&
      serialized(statement.Condition).includes("false")
    );
    if (!tlsDeny) {
      throw new InfrastructurePolicyError("every S3 bucket policy must retain its TLS-only deny");
    }
    const prefixDeny = statements.some((statement) =>
      statement.Effect === "Deny" &&
      serialized(statement.Action).includes("s3:PutObject") &&
      serialized(statement.NotResource).includes("server/")
    );
    if (!prefixDeny) {
      throw new InfrastructurePolicyError("S3 writes must remain inside server-owned prefixes");
    }
    for (const statement of statements) {
      if (
        statement.Effect === "Allow" &&
        JSON.stringify(statement.Principal) === "{\"AWS\":\"*\"}"
      ) {
        throw new InfrastructurePolicyError("public S3 allow statements are forbidden");
      }
    }
  }

  const auditEntry = buckets.find(([logicalId]) => logicalId.startsWith("AuditBucket"));
  if (auditEntry === undefined) {
    throw new InfrastructurePolicyError("the protected audit bucket is required");
  }
  const lifecycle = auditEntry[1].Properties?.LifecycleConfiguration;
  if (!isRecord(lifecycle) || !Array.isArray(lifecycle.Rules)) {
    throw new InfrastructurePolicyError("audit version lifetime requires a lifecycle rule");
  }
  const retention = lifecycle.Rules.find((rule) => isRecord(rule) && rule.ExpirationInDays !== undefined);
  if (!isRecord(retention) || !isRecord(retention.NoncurrentVersionExpiration)) {
    throw new InfrastructurePolicyError("audit version lifetime requires current and noncurrent expiry");
  }
  const currentDays = retention.ExpirationInDays;
  const noncurrentDays = retention.NoncurrentVersionExpiration.NoncurrentDays;
  if (
    typeof currentDays !== "number" ||
    typeof noncurrentDays !== "number" ||
    currentDays <= 0 ||
    noncurrentDays <= 0 ||
    currentDays + noncurrentDays > 400
  ) {
    throw new InfrastructurePolicyError("audit version lifetime must remain bounded to at most 400 days");
  }
  const auditPolicy = Object.values(resources).find(
    (resource) => resource.Type === "AWS::S3::BucketPolicy" &&
      serialized(resource.Properties?.Bucket).includes(auditEntry[0]),
  );
  const deleteDeny = auditPolicy === undefined ? undefined : policyStatements(auditPolicy).find(
    (statement) => statement.Effect === "Deny" &&
      strings(statement.Action).includes("s3:DeleteBucket") &&
      strings(statement.Action).includes("s3:DeleteObject") &&
      strings(statement.Action).includes("s3:DeleteObjectVersion"),
  );
  if (deleteDeny === undefined) {
    throw new InfrastructurePolicyError("audit bucket requires caller-driven object and bucket deletion denies");
  }
}

function hasExactCmkOverrideDenies(policy: CloudFormationResource, bucketEncryption: unknown): boolean {
  const encryption = serialized(bucketEncryption);
  const statements = policyStatements(policy);
  const bySid = (sid: string): Readonly<Record<string, unknown>> | undefined =>
    statements.find((statement) => statement.Sid === sid && statement.Effect === "Deny");
  const wrongAlgorithm = bySid("DenyPresentNonKmsEncryptionOverride");
  const missingKey = bySid("DenyKmsOverrideWithoutKeyId");
  const wrongKey = bySid("DenyPresentWrongKmsKeyOverride");
  if (wrongAlgorithm === undefined || missingKey === undefined || wrongKey === undefined) {
    return false;
  }
  const algorithmCondition = serialized(wrongAlgorithm.Condition);
  const missingKeyCondition = serialized(missingKey.Condition);
  const wrongKeyCondition = serialized(wrongKey.Condition);
  const keyReference = readConditionValue(
    wrongKey.Condition,
    "StringNotEquals",
    "s3:x-amz-server-side-encryption-aws-kms-key-id",
  );
  return algorithmCondition.includes('"s3:x-amz-server-side-encryption":"false"') &&
    algorithmCondition.includes('"s3:x-amz-server-side-encryption":"aws:kms"') &&
    missingKeyCondition.includes('"s3:x-amz-server-side-encryption":"aws:kms"') &&
    missingKeyCondition.includes('"s3:x-amz-server-side-encryption-aws-kms-key-id":"true"') &&
    wrongKeyCondition.includes('"s3:x-amz-server-side-encryption-aws-kms-key-id":"false"') &&
    keyReference !== undefined &&
    encryption.includes(serialized(keyReference));
}

function readConditionValue(
  condition: unknown,
  operator: string,
  key: string,
): unknown {
  if (!isRecord(condition) || !isRecord(condition[operator])) {
    return undefined;
  }
  return condition[operator][key];
}

function assertLogBoundaries(resources: Readonly<Record<string, CloudFormationResource>>): void {
  const groups = ofType(resources, "AWS::Logs::LogGroup");
  if (groups.length < 11) {
    throw new InfrastructurePolicyError("explicit log groups are required for every runtime boundary");
  }
  for (const group of groups) {
    if (typeof group.Properties?.RetentionInDays !== "number") {
      throw new InfrastructurePolicyError("forced log retention must be present on every log group");
    }
    if (group.Properties.KmsKeyId === undefined) {
      throw new InfrastructurePolicyError("every log group must use a customer-managed KMS key");
    }
    const keyReference = serialized(group.Properties.KmsKeyId);
    if (!keyReference.includes("LogsKey") || keyReference.includes("SecretsKey")) {
      throw new InfrastructurePolicyError("all Lambda log groups and service logs must use LogsKey, never SecretsKey");
    }
  }
  const logsKey = Object.entries(resources).find(
    ([logicalId, resource]) => logicalId.startsWith("LogsKey") && resource.Type === "AWS::KMS::Key",
  );
  if (logsKey === undefined) {
    throw new InfrastructurePolicyError("LogsKey is required for CloudWatch Logs");
  }
  const statements = keyPolicyStatements(logsKey[1]);
  const serviceStatement = statements.find((statement) =>
    serialized(statement.Principal).includes("logs.us-east-1.amazonaws.com"),
  );
  const requiredActions = new Set([
    "kms:Encrypt",
    "kms:Decrypt",
    "kms:ReEncryptFrom",
    "kms:ReEncryptTo",
    "kms:GenerateDataKey",
    "kms:GenerateDataKeyWithoutPlaintext",
    "kms:DescribeKey"
  ]);
  if (
    serviceStatement === undefined ||
    !sameStrings(strings(serviceStatement.Action), requiredActions) ||
    !serialized(serviceStatement.Condition).includes("kms:EncryptionContext:aws:logs:arn") ||
    !serialized(serviceStatement.Condition).includes(":logs:us-east-1:") ||
    !serialized(serviceStatement.Condition).includes(":log-group:/aws/*")
  ) {
    throw new InfrastructurePolicyError(
      "LogsKey requires the regional CloudWatch Logs principal, exact actions, and an account-bounded log ARN",
    );
  }
}

function assertAuroraBoundary(resources: Readonly<Record<string, CloudFormationResource>>): void {
  const clusters = ofType(resources, "AWS::RDS::DBCluster");
  if (clusters.length !== 1) {
    throw new InfrastructurePolicyError("exactly one Aurora boundary is required");
  }
  const cluster = clusters[0];
  if (cluster === undefined) {
    throw new InfrastructurePolicyError("Aurora boundary is absent");
  }
  const properties = cluster.Properties ?? {};
  if (
    properties.Engine !== "aurora-postgresql" ||
    properties.EngineVersion !== "16.8" ||
    properties.EnableHttpEndpoint !== true ||
    properties.StorageEncrypted !== true
  ) {
    throw new InfrastructurePolicyError(
      "Aurora must remain PostgreSQL 16.8, encrypted, and Data API enabled",
    );
  }
  const instances = ofType(resources, "AWS::RDS::DBInstance");
  if (instances.length !== 1 || instances[0]?.Properties?.PubliclyAccessible !== false) {
    throw new InfrastructurePolicyError("Aurora must not expose a public database instance");
  }
  if (
    ofType(resources, "AWS::EC2::NatGateway").length !== 0 ||
    ofType(resources, "AWS::EC2::InternetGateway").length !== 0
  ) {
    throw new InfrastructurePolicyError("Aurora VPC must contain isolated subnets only");
  }
  const parameterGroups = ofType(resources, "AWS::RDS::DBClusterParameterGroup");
  if (!parameterGroups.some((group) => serialized(group.Properties).includes("rds.force_ssl"))) {
    throw new InfrastructurePolicyError("Aurora must retain forced TLS parameter policy");
  }
}

function assertRuntimeDatabaseLanes(
  resources: Readonly<Record<string, CloudFormationResource>>,
): void {
  const expectedUsernames = new Set([
    "roomscan_cluster_admin",
    "roomscan_api_runtime",
    "roomscan_authorizer_runtime",
    "roomscan_auth_challenge_runtime",
    "roomscan_stripe_ingress_runtime",
    "roomscan_stripe_reconciliation_runtime",
    "roomscan_audit_export_runtime",
    "roomscan_email_delivery_runtime"
  ]);
  const usernames = ofType(resources, "AWS::SecretsManager::Secret").flatMap((secret) => {
    const generated = secret.Properties?.GenerateSecretString;
    if (!isRecord(generated) || typeof generated.SecretStringTemplate !== "string") return [];
    try {
      const template = JSON.parse(generated.SecretStringTemplate) as unknown;
      return isRecord(template) && typeof template.username === "string" ? [template.username] : [];
    } catch {
      return [];
    }
  });
  if (!sameStrings(usernames, expectedUsernames) || usernames.includes("roomscan_app")) {
    throw new InfrastructurePolicyError(
      "database credentials require exactly seven separated runtime roles plus the owner",
    );
  }

  const expectedLanes = new Map([
    ["-app-authorizer", ["roomscan_authorizer_runtime", "AuthorizerDatabaseSecret"]],
    ["-api", ["roomscan_api_runtime", "ApiDatabaseSecret"]],
    ["-auth-challenge", ["roomscan_auth_challenge_runtime", "AuthChallengeDatabaseSecret"]],
    ["-stripe-ingress", ["roomscan_stripe_ingress_runtime", "StripeIngressDatabaseSecret"]],
    ["-stripe-reconciliation", ["roomscan_stripe_reconciliation_runtime", "StripeReconciliationDatabaseSecret"]],
    ["-audit-exporter", ["roomscan_audit_export_runtime", "AuditExportDatabaseSecret"]],
    ["-email-delivery", ["roomscan_email_delivery_runtime", "EmailDeliveryDatabaseSecret"]]
  ] as const);
  const functions = ofType(resources, "AWS::Lambda::Function");
  for (const [functionSuffix, [runtimeRole, secretMarker]] of expectedLanes) {
    const fn = functions.find((candidate) =>
      typeof candidate.Properties?.FunctionName === "string"
      && candidate.Properties.FunctionName.endsWith(functionSuffix));
    const variables = isRecord(fn?.Properties?.Environment)
      && isRecord(fn.Properties.Environment.Variables)
      ? fn.Properties.Environment.Variables
      : undefined;
    if (
      variables === undefined ||
      variables.ROOMSCAN_DB_RUNTIME_ROLE !== runtimeRole ||
      !serialized(variables.ROOMSCAN_DB_ROLE_SECRET_ARN).includes(secretMarker) ||
      variables.DB_CLUSTER_ARN === undefined ||
      variables.DB_RUNTIME_SECRET_ARN !== undefined ||
      variables.DB_OWNER_SECRET_ARN !== undefined
    ) {
      throw new InfrastructurePolicyError(`${functionSuffix} must receive only its fixed database lane`);
    }
  }

  const migration = functions.find(
    (candidate) => typeof candidate.Properties?.FunctionName === "string"
      && candidate.Properties.FunctionName.endsWith("-migration-operator"),
  );
  const migrationVariables = isRecord(migration?.Properties?.Environment)
    && isRecord(migration.Properties.Environment.Variables)
    ? migration.Properties.Environment.Variables
    : undefined;
  if (
    migrationVariables === undefined ||
    !serialized(migrationVariables.DB_OWNER_SECRET_ARN).includes("DatabaseOwnerSecret") ||
    migrationVariables.DB_HOST === undefined ||
    migrationVariables.DB_PORT !== "5432" ||
    migrationVariables.DB_NAME !== "roomscan" ||
    migrationVariables.MIGRATION_MANIFEST_SHA256 === undefined ||
    migrationVariables.DB_CLUSTER_ARN !== undefined ||
    migrationVariables.ROOMSCAN_DB_ROLE_SECRET_ARN !== undefined ||
    migrationVariables.DB_RUNTIME_SECRET_ARN !== undefined
  ) {
    throw new InfrastructurePolicyError("migration operator must remain owner-secret only");
  }
  const migrationPolicy = policyByPrefix(resources, "MigrationOperatorPolicy");
  if (serialized(migrationPolicy.Properties?.PolicyDocument).includes("rds-data:")) {
    throw new InfrastructurePolicyError("migration operator must use only direct PostgreSQL, never Data API");
  }

  const apiPolicy = policyByPrefix(resources, "PrivateApiPolicy");
  const stripePolicy = policyByPrefix(resources, "StripeIngressPolicy");
  const apiSerialized = serialized(apiPolicy.Properties?.PolicyDocument);
  const stripeSerialized = serialized(stripePolicy.Properties?.PolicyDocument);
  if (/s3:GetObject|ActiveBucket|PublishedDerivativeBucket/u.test(apiSerialized)) {
    throw new InfrastructurePolicyError("API must not read active or published object storage");
  }
  for (const marker of [
    "rds-data:BeginTransaction",
    "rds-data:ExecuteStatement",
    "rds-data:CommitTransaction",
    "rds-data:RollbackTransaction",
    "StripeIngressDatabaseSecret"
  ]) {
    if (!stripeSerialized.includes(marker)) {
      throw new InfrastructurePolicyError("Stripe ingress requires its durable role-bound Data API lane");
    }
  }
}

function assertLambdaBoundary(resources: Readonly<Record<string, CloudFormationResource>>): void {
  const functions = ofType(resources, "AWS::Lambda::Function");
  if (functions.length !== 9) {
    throw new InfrastructurePolicyError("exactly nine separated application Lambda functions are required");
  }
  if (functions.some((fn) => fn.Properties?.Runtime !== "nodejs24.x")) {
    throw new InfrastructurePolicyError("every application Lambda must target nodejs24.x");
  }
  if (
    ofType(resources, "AWS::Lambda::Version").length !== functions.length ||
    ofType(resources, "AWS::Lambda::Alias").length !== functions.length
  ) {
    throw new InfrastructurePolicyError("every application Lambda requires an immutable version and alias");
  }
}

function assertIamPolicies(resources: Readonly<Record<string, CloudFormationResource>>): void {
  for (const policy of ofType(resources, "AWS::IAM::Policy")) {
    for (const statement of policyStatements(policy)) {
      for (const action of strings(statement.Action)) {
        if (action.includes("*")) {
          throw new InfrastructurePolicyError("wildcard IAM actions are forbidden");
        }
      }
      if (strings(statement.Resource).includes("*")
        && !isBoundedMetricPublication(statement)
        && !isExactLambdaVpcNetworkAccess(statement)) {
        throw new InfrastructurePolicyError("wildcard-only IAM resource is forbidden");
      }
    }
  }
}

function isExactLambdaVpcNetworkAccess(statement: Readonly<Record<string, unknown>>): boolean {
  return sameStrings(strings(statement.Action), new Set([
    "ec2:AssignPrivateIpAddresses",
    "ec2:CreateNetworkInterface",
    "ec2:DeleteNetworkInterface",
    "ec2:DescribeNetworkInterfaces",
    "ec2:UnassignPrivateIpAddresses"
  ])) && JSON.stringify(strings(statement.Resource)) === "[\"*\"]" && statement.Condition === undefined;
}

function isBoundedMetricPublication(statement: Readonly<Record<string, unknown>>): boolean {
  const condition = statement.Condition;
  return JSON.stringify(strings(statement.Action)) === "[\"cloudwatch:PutMetricData\"]" &&
    isRecord(condition) &&
    Object.keys(condition).length === 1 &&
    isRecord(condition.StringEquals) &&
    Object.keys(condition.StringEquals).length === 1 &&
    condition.StringEquals["cloudwatch:namespace"] === "RoomScan/CloudTrail";
}

function assertSecretsKeyDecryptBoundary(
  resources: Readonly<Record<string, CloudFormationResource>>,
): void {
  let constrainedDecrypts = 0;
  for (const policy of ofType(resources, "AWS::IAM::Policy")) {
    for (const statement of policyStatements(policy)) {
      if (
        !strings(statement.Action).includes("kms:Decrypt") ||
        !serialized(statement.Resource).includes("SecretsKey")
      ) {
        continue;
      }
      const condition = statement.Condition;
      const stringEquals = isRecord(condition) ? condition.StringEquals : undefined;
      if (
        !isRecord(condition) ||
        Object.keys(condition).length !== 1 ||
        !isRecord(stringEquals) ||
        Object.keys(stringEquals).length !== 2 ||
        stringEquals["kms:ViaService"] !== "secretsmanager.us-east-1.amazonaws.com" ||
        stringEquals["kms:EncryptionContext:SecretARN"] === undefined
      ) {
        throw new InfrastructurePolicyError(
          "SecretsKey decrypt requires Secrets Manager and one exact secret encryption context",
        );
      }
      constrainedDecrypts += 1;
    }
  }
  if (constrainedDecrypts === 0) {
    throw new InfrastructurePolicyError("SecretsKey requires context-bound runtime decrypt grants");
  }
}

function assertKmsUsageBoundary(
  resources: Readonly<Record<string, CloudFormationResource>>,
): void {
  const requiredPolicyReferences = [
    ["PrivateApiPolicy", ["AssetsKey", "QueuesKey"]],
    ["StripeIngressPolicy", ["QueuesKey", "arn:aws:kms:us-east-1:"]],
    ["StripeReconciliationPolicy", ["QueuesKey", "arn:aws:kms:us-east-1:"]],
    ["AuditExporterPolicy", ["AuditKey"]]
  ] as const;
  for (const [logicalPrefix, keyReferences] of requiredPolicyReferences) {
    const entry = Object.entries(resources).find(
      ([logicalId, resource]) =>
        logicalId.startsWith(logicalPrefix) && resource.Type === "AWS::IAM::Policy",
    );
    if (entry === undefined) {
      throw new InfrastructurePolicyError(`${logicalPrefix} KMS policy is required`);
    }
    const policy = serialized(entry[1]);
    if (keyReferences.some((reference) => !policy.includes(reference))) {
      throw new InfrastructurePolicyError(`${logicalPrefix} lacks a required concrete KMS key grant`);
    }
  }

  const auditKey = Object.entries(resources).find(
    ([logicalId, resource]) => logicalId.startsWith("AuditKey") && resource.Type === "AWS::KMS::Key",
  );
  if (auditKey === undefined) {
    throw new InfrastructurePolicyError("the audit KMS key is required");
  }
  const keyPolicy = serialized(auditKey[1].Properties?.KeyPolicy);
  for (const service of [
    "cloudtrail.amazonaws.com",
    "cloudwatch.amazonaws.com",
    "ses.amazonaws.com"
  ]) {
    if (!keyPolicy.includes(service)) {
      throw new InfrastructurePolicyError(`audit KMS delivery policy is missing ${service}`);
    }
  }
}

function assertAlarmTopicBoundary(
  resources: Readonly<Record<string, CloudFormationResource>>,
): void {
  const topicPolicies = ofType(resources, "AWS::SNS::TopicPolicy");
  if (topicPolicies.length !== 1) {
    throw new InfrastructurePolicyError("one operator SNS topic policy is required");
  }
  const statements = policyStatements(topicPolicies[0]!);
  for (const [service, sourceMarker, label] of [
    ["cloudwatch.amazonaws.com", ":cloudwatch:us-east-1:", "CloudWatch alarm"],
    ["ses.amazonaws.com", ":ses:us-east-1:", "SES configuration-set"]
  ] as const) {
    const statement = statements.find((candidate) =>
      serialized(candidate.Principal).includes(service),
    );
    if (
      statement === undefined ||
      statement.Effect !== "Allow" ||
      !sameStrings(strings(statement.Action), new Set(["sns:Publish"])) ||
      !serialized(statement.Resource).includes("OperatorAlarmTopic") ||
      !serialized(statement.Condition).includes("SourceAccount") ||
      !serialized(statement.Condition).includes(sourceMarker)
    ) {
      throw new InfrastructurePolicyError(`${label} publication requires an account-bounded topic policy`);
    }
  }

  const auditKey = Object.entries(resources).find(
    ([logicalId, resource]) => logicalId.startsWith("AuditKey") && resource.Type === "AWS::KMS::Key",
  );
  if (auditKey === undefined) {
    throw new InfrastructurePolicyError("AuditKey is required for the encrypted operator topic");
  }
  const keyStatements = keyPolicyStatements(auditKey[1]);
  for (const [service, sourceMarker] of [
    ["cloudwatch.amazonaws.com", ":cloudwatch:us-east-1:"],
    ["ses.amazonaws.com", ":ses:us-east-1:"]
  ] as const) {
    const statement = keyStatements.find((candidate) =>
      serialized(candidate.Principal).includes(service),
    );
    if (
      statement === undefined ||
      !sameStrings(strings(statement.Action), new Set([
        "kms:Decrypt",
        "kms:GenerateDataKey",
        "kms:GenerateDataKeyWithoutPlaintext"
      ])) ||
      !serialized(statement.Condition).includes("SourceAccount") ||
      !serialized(statement.Condition).includes(sourceMarker)
    ) {
      throw new InfrastructurePolicyError(
        `encrypted SNS publication lacks exact KMS publisher support for ${service}`,
      );
    }
  }
}

function assertCloudTrail(resources: Readonly<Record<string, CloudFormationResource>>): void {
  const trails = ofType(resources, "AWS::CloudTrail::Trail");
  if (trails.length !== 1) {
    throw new InfrastructurePolicyError("one CloudTrail audit boundary is required");
  }
  const properties = trails[0]?.Properties ?? {};
  const eventSelectors = serialized(properties.EventSelectors);
  if (properties.EnableLogFileValidation !== true || !eventSelectors.includes("AWS::S3::Object")) {
    throw new InfrastructurePolicyError("CloudTrail requires digest validation and S3 data events");
  }
  for (const logicalPrefix of [
    "QuarantineBucket",
    "ActiveBucket",
    "PublishedDerivativeBucket",
    "BackupBucket"
  ]) {
    if (!eventSelectors.includes(logicalPrefix)) {
      throw new InfrastructurePolicyError(`CloudTrail is missing ${logicalPrefix} S3 data events`);
    }
  }
  if (eventSelectors.includes("AuditBucket")) {
    throw new InfrastructurePolicyError(
      "CloudTrail must not recursively select its own S3 delivery bucket",
    );
  }
}

function assertCloudTrailStatusMonitoring(
  resources: Readonly<Record<string, CloudFormationResource>>,
): void {
  const alarms = ofType(resources, "AWS::CloudWatch::Alarm");
  if (alarms.some((alarm) =>
    alarm.Properties?.Namespace === "AWS/CloudTrail" &&
    alarm.Properties?.MetricName === "DeliveryErrors"
  )) {
    throw new InfrastructurePolicyError("unsupported CloudTrail metric AWS/CloudTrail DeliveryErrors is forbidden");
  }
  const statusAlarms = alarms.filter((alarm) => alarm.Properties?.Namespace === "RoomScan/CloudTrail");
  const health = statusAlarms.find((alarm) => alarm.Properties?.MetricName === "TrailDeliveryHealthy");
  const heartbeat = statusAlarms.find((alarm) => alarm.Properties?.MetricName === "TrailStatusHeartbeat");
  if (
    health === undefined ||
    heartbeat === undefined ||
    statusAlarms.length !== 2 ||
    statusAlarms.some((alarm) => alarm.Properties?.TreatMissingData !== "breaching")
  ) {
    throw new InfrastructurePolicyError(
      "CloudTrail status requires bounded delivery-health and heartbeat alarms with missing data breaching",
    );
  }

  const rules = ofType(resources, "AWS::Events::Rule");
  const schedule = rules.find((rule) =>
    rule.Properties?.ScheduleExpression === "rate(5 minutes)" && rule.Properties?.State === "ENABLED",
  );
  if (schedule === undefined || !serialized(schedule.Properties?.Targets).includes("CloudTrailStatusMonitor")) {
    throw new InfrastructurePolicyError("CloudTrail status monitor requires an enabled five-minute schedule");
  }
  const monitor = Object.entries(resources).find(
    ([logicalId, resource]) => logicalId.startsWith("CloudTrailStatusMonitorFunction") &&
      resource.Type === "AWS::Lambda::Function",
  );
  if (monitor?.[1].Properties?.Runtime !== "nodejs24.x") {
    throw new InfrastructurePolicyError("CloudTrail status monitor must use Node.js 24");
  }
  const monitorPolicy = Object.entries(resources).find(
    ([logicalId, resource]) => logicalId.startsWith("CloudTrailStatusMonitorPolicy") &&
      resource.Type === "AWS::IAM::Policy",
  );
  if (monitorPolicy === undefined) {
    throw new InfrastructurePolicyError("CloudTrail status monitor requires a separate execution policy");
  }
  const statements = policyStatements(monitorPolicy[1]);
  const getStatus = statements.find((statement) =>
    strings(statement.Action).includes("cloudtrail:GetTrailStatus"),
  );
  const publishMetric = statements.find((statement) =>
    strings(statement.Action).includes("cloudwatch:PutMetricData"),
  );
  if (
    getStatus === undefined ||
    strings(getStatus.Resource).includes("*") ||
    !serialized(getStatus.Resource).includes("PlatformTrail") ||
    publishMetric === undefined ||
    !strings(publishMetric.Resource).includes("*") ||
    !isBoundedMetricPublication(publishMetric)
  ) {
    throw new InfrastructurePolicyError(
      "CloudTrail status monitor requires exact GetTrailStatus and namespace-bounded PutMetricData permissions",
    );
  }
  const invoke = ofType(resources, "AWS::Lambda::Permission").find((permission) =>
    permission.Properties?.Principal === "events.amazonaws.com" &&
    permission.Properties?.Action === "lambda:InvokeFunction" &&
    serialized(permission.Properties?.SourceArn).includes("CloudTrailStatusSchedule"),
  );
  if (invoke === undefined) {
    throw new InfrastructurePolicyError("EventBridge requires a source-rule-bounded monitor invoke permission");
  }
}

function assertCognitoFederationBoundary(
  resources: Readonly<Record<string, CloudFormationResource>>,
): void {
  const domains = ofType(resources, "AWS::Cognito::UserPoolDomain");
  if (domains.length !== 1) {
    throw new InfrastructurePolicyError("exactly one AWS-managed Cognito federation domain is required");
  }
  const domain = domains[0]!.Properties ?? {};
  if (
    typeof domain.Domain !== "string" ||
    !/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/u.test(domain.Domain) ||
    domain.CustomDomainConfig !== undefined ||
    !serialized(domain.UserPoolId).includes("ProfessionalUserPool")
  ) {
    throw new InfrastructurePolicyError("Cognito federation domain must be a validated AWS-managed prefix");
  }
  const providers = ofType(resources, "AWS::Cognito::UserPoolIdentityProvider");
  const clients = ofType(resources, "AWS::Cognito::UserPoolClient");
  const provider = providers.find((candidate) => candidate.Properties?.ProviderName === "SignInWithApple");
  const federationClient = clients.find((candidate) => candidate.Properties?.GenerateSecret === true)?.Properties ?? {};
  const customAuthClient = clients.find((candidate) => candidate.Properties?.GenerateSecret === false)?.Properties ?? {};
  if (
    provider === undefined ||
    clients.length !== 2 ||
    serialized(federationClient.AllowedOAuthFlows) !== "[\"code\"]" ||
    !serialized(federationClient.CallbackURLs).includes("/auth/apple/callback") ||
    !sameStrings(strings(federationClient.SupportedIdentityProviders), new Set(["SignInWithApple"])) ||
    /implicit|PASSWORD|SRP/u.test(serialized(federationClient)) ||
    serialized(customAuthClient.ExplicitAuthFlows) !== "[\"ALLOW_CUSTOM_AUTH\"]" ||
    customAuthClient.AllowedOAuthFlows !== undefined ||
    customAuthClient.CallbackURLs !== undefined ||
    /ALLOW_REFRESH_TOKEN_AUTH|PASSWORD|SRP/u.test(serialized(customAuthClient))
  ) {
    throw new InfrastructurePolicyError(
      "Cognito Apple bridge requires Apple-only code flow to the app-owned API with no native local-user, password, or implicit path",
    );
  }
}

function assertHttpApi(resources: Readonly<Record<string, CloudFormationResource>>): void {
  const integrations = ofType(resources, "AWS::ApiGatewayV2::Integration");
  if (
    integrations.length !== 2 ||
    integrations.some((integration) => integration.Properties?.PayloadFormatVersion !== "2.0")
  ) {
    throw new InfrastructurePolicyError("HTTP API integrations must use payload format 2.0");
  }
  for (const integration of integrations) {
    if (integration.Properties?.RequestParameters !== undefined) {
      throw new InfrastructurePolicyError("HTTP API integrations must not transform request bodies");
    }
  }
  const routes = ofType(resources, "AWS::ApiGatewayV2::Route");
  const expected = new Map<string, "NONE" | "CUSTOM">([
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
    ["POST /identity/mutate", "CUSTOM"]
  ]);
  if (routes.length !== expected.size) {
    throw new InfrastructurePolicyError("HTTP API requires exactly the canonical 19 routes");
  }
  for (const route of routes) {
    const properties = route.Properties ?? {};
    const routeKey = properties.RouteKey;
    if (typeof routeKey !== "string" || expected.get(routeKey) !== properties.AuthorizationType) {
      throw new InfrastructurePolicyError("HTTP API route or visibility diverged from the canonical manifest");
    }
    if (/ANY|proxy/u.test(routeKey)) {
      throw new InfrastructurePolicyError("generic HTTP API proxy routes are forbidden");
    }
    const isProtected = expected.get(routeKey) === "CUSTOM";
    if (isProtected !== (properties.AuthorizerId !== undefined)) {
      throw new InfrastructurePolicyError("authorizer must be early-only on protected routes");
    }
  }
}

function assertRecoverySchedules(resources: Readonly<Record<string, CloudFormationResource>>): void {
  const rules = ofType(resources, "AWS::Events::Rule");
  for (const suffix of [
    "stripe-reconciliation-recovery",
    "audit-outbox-recovery",
    "email-delivery-recovery"
  ] as const) {
    const rule = rules.find((candidate) =>
      typeof candidate.Properties?.Name === "string" && candidate.Properties.Name.endsWith(suffix));
    if (
      rule === undefined ||
      typeof rule.Properties?.ScheduleExpression !== "string" ||
      !serialized(rule.Properties.Targets).includes("Queue")
    ) {
      throw new InfrastructurePolicyError(`${suffix} requires a periodic durable queue wake`);
    }
  }
}

function ofType(
  resources: Readonly<Record<string, CloudFormationResource>>,
  type: string,
): CloudFormationResource[] {
  return Object.values(resources).filter((resource) => resource.Type === type);
}

function policyByPrefix(
  resources: Readonly<Record<string, CloudFormationResource>>,
  logicalPrefix: string,
): CloudFormationResource {
  const entry = Object.entries(resources).find(
    ([logicalId, resource]) => logicalId.startsWith(logicalPrefix)
      && resource.Type === "AWS::IAM::Policy",
  );
  if (entry === undefined) {
    throw new InfrastructurePolicyError(`${logicalPrefix} policy is required`);
  }
  return entry[1];
}

function policyStatements(resource: CloudFormationResource): Readonly<Record<string, unknown>>[] {
  const document = resource.Properties?.PolicyDocument;
  if (!isRecord(document) || !Array.isArray(document.Statement)) {
    throw new InfrastructurePolicyError(`${resource.Type} must contain a statement array`);
  }
  return document.Statement.map((statement) => {
    if (!isRecord(statement)) {
      throw new InfrastructurePolicyError(`${resource.Type} contains a malformed policy statement`);
    }
    return statement;
  });
}

function keyPolicyStatements(resource: CloudFormationResource): Readonly<Record<string, unknown>>[] {
  const document = resource.Properties?.KeyPolicy;
  if (!isRecord(document) || !Array.isArray(document.Statement)) {
    throw new InfrastructurePolicyError(`${resource.Type} must contain a KMS key-policy statement array`);
  }
  return document.Statement.map((statement) => {
    if (!isRecord(statement)) {
      throw new InfrastructurePolicyError(`${resource.Type} contains a malformed KMS policy statement`);
    }
    return statement;
  });
}

function sameStrings(actual: readonly string[], expected: ReadonlySet<string>): boolean {
  return actual.length === expected.size && actual.every((value) => expected.has(value));
}

function strings(value: unknown): string[] {
  if (typeof value === "string") {
    return [value];
  }
  if (Array.isArray(value)) {
    return value.filter((item): item is string => typeof item === "string");
  }
  return [];
}

function serialized(value: unknown): string {
  return JSON.stringify(value) ?? "";
}

function isRecord(value: unknown): value is Readonly<Record<string, unknown>> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
