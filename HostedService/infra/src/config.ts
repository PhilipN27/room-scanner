import { readFileSync } from "node:fs";

export type DeploymentStage = "dev" | "staging" | "production";

export interface AccountTopology {
  readonly management: string;
  readonly logArchive: string;
  readonly securityAudit: string;
  readonly dev: string;
  readonly staging: string;
  readonly production: string;
}

export interface PlatformConfig {
  readonly accountId: string;
  readonly stage: DeploymentStage;
  readonly region: "us-east-1";
  readonly availabilityZones: readonly [string, string];
  readonly accountTopology: AccountTopology;
  readonly operatorOwner: string;
  readonly notificationEmail: string;
  readonly serviceDomain: string;
  readonly cognitoDomainPrefix: string;
  readonly magicDeliveryKeyId: string;
  readonly providerSecretsKmsKeyArn: string;
  readonly apple: {
    readonly clientId: string;
    readonly teamId: string;
    readonly keyId: string;
    readonly privateKeySecretArn: string;
  };
  readonly stripe: {
    readonly webhookSecretArn: string;
    readonly apiSecretArn: string;
    readonly defaultAccountId: string;
    readonly apiVersion: string;
    readonly pricePlanMappings: readonly Readonly<{
      readonly priceId: string;
      readonly planKey: string;
    }>[];
    readonly policyValuesStatus: "local-test-values-v1" | "owner-policy-unconfigured-v1";
  };
  readonly ses: {
    readonly identityArn: string;
    readonly configurationSetName: string;
    readonly senderAddress: string;
  };
  readonly aurora: {
    readonly minimumAcu: number;
    readonly maximumAcu: number;
    readonly backupRetentionDays: number;
  };
}

const TOPOLOGY_KEYS = [
  "management",
  "logArchive",
  "securityAudit",
  "dev",
  "staging",
  "production"
] as const satisfies readonly (keyof AccountTopology)[];

export class ConfigurationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ConfigurationError";
  }
}

export function loadPlatformConfig(environment: Readonly<NodeJS.ProcessEnv>): PlatformConfig {
  const accountId = required(environment, "ROOMSCAN_ACCOUNT_ID");
  assertAccountId(accountId, "ROOMSCAN_ACCOUNT_ID");

  const stageValue = required(environment, "ROOMSCAN_STAGE");
  if (stageValue !== "dev" && stageValue !== "staging" && stageValue !== "production") {
    throw new ConfigurationError("ROOMSCAN_STAGE must be dev, staging, or production");
  }
  const stage: DeploymentStage = stageValue;

  const region = required(environment, "ROOMSCAN_REGION");
  if (region !== "us-east-1") {
    throw new ConfigurationError("ROOMSCAN_REGION must be the approved us-east-1 region");
  }

  const availabilityZones = availabilityZonePair(
    required(environment, "ROOMSCAN_AVAILABILITY_ZONES"),
  );

  const topologyPath = required(environment, "ROOMSCAN_ACCOUNT_TOPOLOGY_FILE");
  const accountTopology = loadAccountTopology(topologyPath);
  if (accountTopology[stage] !== accountId) {
    throw new ConfigurationError(
      "ROOMSCAN_ACCOUNT_ID must equal the selected stage account in the account topology",
    );
  }

  const operatorOwner = required(environment, "ROOMSCAN_OPERATOR_OWNER");
  if (!/^[A-Za-z0-9][A-Za-z0-9._:@/-]{2,127}$/u.test(operatorOwner)) {
    throw new ConfigurationError("ROOMSCAN_OPERATOR_OWNER must be a bounded operator identifier");
  }

  const notificationEmail = required(environment, "ROOMSCAN_NOTIFICATION_EMAIL");
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/u.test(notificationEmail) || notificationEmail.length > 254) {
    throw new ConfigurationError("ROOMSCAN_NOTIFICATION_EMAIL must be one explicit email destination");
  }

  const serviceDomain = required(environment, "ROOMSCAN_SERVICE_DOMAIN");
  if (
    serviceDomain.length > 253 ||
    !/^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/u.test(
      serviceDomain,
    )
  ) {
    throw new ConfigurationError("ROOMSCAN_SERVICE_DOMAIN must be a lowercase fully qualified domain reference");
  }

  const cognitoDomainPrefix = required(environment, "ROOMSCAN_COGNITO_DOMAIN_PREFIX");
  if (!/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/u.test(cognitoDomainPrefix)) {
    throw new ConfigurationError(
      "ROOMSCAN_COGNITO_DOMAIN_PREFIX must be a 1-63 character lowercase AWS-managed domain prefix",
    );
  }

  const appleClientId = boundedIdentifier(
    required(environment, "ROOMSCAN_APPLE_CLIENT_ID"),
    "ROOMSCAN_APPLE_CLIENT_ID",
    256,
  );
  const appleTeamId = boundedIdentifier(
    required(environment, "ROOMSCAN_APPLE_TEAM_ID"),
    "ROOMSCAN_APPLE_TEAM_ID",
    64,
  );
  const appleKeyId = boundedIdentifier(
    required(environment, "ROOMSCAN_APPLE_KEY_ID"),
    "ROOMSCAN_APPLE_KEY_ID",
    64,
  );
  const applePrivateKeySecretArn = required(
    environment,
    "ROOMSCAN_APPLE_PRIVATE_KEY_SECRET_ARN",
  );
  const providerSecretsKmsKeyArn = required(
    environment,
    "ROOMSCAN_PROVIDER_SECRETS_KMS_KEY_ARN",
  );
  const stripeWebhookSecretArn = required(
    environment,
    "ROOMSCAN_STRIPE_WEBHOOK_SECRET_ARN",
  );
  const stripeApiSecretArn = required(environment, "ROOMSCAN_STRIPE_API_SECRET_ARN");
  const stripeDefaultAccountId = required(environment, "ROOMSCAN_STRIPE_DEFAULT_ACCOUNT_ID");
  if (!/^acct_[A-Za-z0-9]{8,64}$/u.test(stripeDefaultAccountId)) {
    throw new ConfigurationError(
      "ROOMSCAN_STRIPE_DEFAULT_ACCOUNT_ID must be one bounded Stripe account reference",
    );
  }
  const stripeApiVersion = required(environment, "ROOMSCAN_STRIPE_API_VERSION");
  if (!/^[0-9]{4}-[0-9]{2}-[0-9]{2}(?:\.[A-Za-z0-9_-]{1,64})?$/u.test(stripeApiVersion)) {
    throw new ConfigurationError("ROOMSCAN_STRIPE_API_VERSION must be one explicit supported Stripe API version");
  }
  const policyValuesStatus = required(environment, "ROOMSCAN_POLICY_VALUES_STATUS");
  const expectedPolicyStatus = stage === "dev"
    ? "local-test-values-v1"
    : "owner-policy-unconfigured-v1";
  if (policyValuesStatus !== expectedPolicyStatus) {
    throw new ConfigurationError(
      `ROOMSCAN_POLICY_VALUES_STATUS must be ${expectedPolicyStatus} for ${stage}`,
    );
  }
  const pricePlanMappings = stripePricePlanMappings(
    required(environment, "ROOMSCAN_STRIPE_PRICE_PLAN_MAP_JSON"),
    stage === "dev",
  );
  const magicDeliveryKeyId = required(environment, "ROOMSCAN_MAGIC_DELIVERY_KEY_ID");
  if (!/^[A-Za-z0-9._-]{3,64}$/u.test(magicDeliveryKeyId)) {
    throw new ConfigurationError("ROOMSCAN_MAGIC_DELIVERY_KEY_ID must be one bounded envelope key identifier");
  }

  const sesIdentityArn = required(environment, "ROOMSCAN_SES_IDENTITY_ARN");
  const sesConfigurationSetName = required(
    environment,
    "ROOMSCAN_SES_CONFIGURATION_SET_NAME",
  );
  if (!/^[A-Za-z0-9_-]{1,64}$/u.test(sesConfigurationSetName)) {
    throw new ConfigurationError(
      "ROOMSCAN_SES_CONFIGURATION_SET_NAME must be an explicit bounded configuration-set name",
    );
  }
  const sesSenderAddress = required(environment, "ROOMSCAN_SES_SENDER_ADDRESS");
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/u.test(sesSenderAddress) || sesSenderAddress.length > 254) {
    throw new ConfigurationError("ROOMSCAN_SES_SENDER_ADDRESS must be one explicit sender address");
  }

  const minimumAcu = acu(environment, "ROOMSCAN_AURORA_MIN_ACU");
  const maximumAcu = acu(environment, "ROOMSCAN_AURORA_MAX_ACU");
  if (maximumAcu < minimumAcu) {
    throw new ConfigurationError("ROOMSCAN_AURORA_MAX_ACU must be greater than or equal to the minimum");
  }
  const backupRetentionDays = integer(
    environment,
    "ROOMSCAN_AURORA_BACKUP_RETENTION_DAYS",
    1,
    35,
  );

  const config: PlatformConfig = {
    accountId,
    stage,
    region,
    availabilityZones,
    accountTopology,
    operatorOwner,
    notificationEmail,
    serviceDomain,
    cognitoDomainPrefix,
    magicDeliveryKeyId,
    providerSecretsKmsKeyArn,
    apple: {
      clientId: appleClientId,
      teamId: appleTeamId,
      keyId: appleKeyId,
      privateKeySecretArn: applePrivateKeySecretArn
    },
    stripe: {
      webhookSecretArn: stripeWebhookSecretArn,
      apiSecretArn: stripeApiSecretArn,
      defaultAccountId: stripeDefaultAccountId,
      apiVersion: stripeApiVersion,
      pricePlanMappings,
      policyValuesStatus: expectedPolicyStatus
    },
    ses: {
      identityArn: sesIdentityArn,
      configurationSetName: sesConfigurationSetName,
      senderAddress: sesSenderAddress
    },
    aurora: {
      minimumAcu,
      maximumAcu,
      backupRetentionDays
    }
  };
  assertPlatformConfigResourceArns(config);
  return config;
}

function stripePricePlanMappings(
  source: string,
  requireSyntheticValues: boolean,
): readonly Readonly<{ readonly priceId: string; readonly planKey: string }>[] {
  if (source.length > 16_384 || !/^\[[\s\S]*\]$/u.test(source)) {
    throw new ConfigurationError("ROOMSCAN_STRIPE_PRICE_PLAN_MAP_JSON must be a bounded JSON array");
  }
  let parsed: unknown;
  try { parsed = JSON.parse(source) as unknown; } catch {
    throw new ConfigurationError("ROOMSCAN_STRIPE_PRICE_PLAN_MAP_JSON must be valid JSON");
  }
  if (!Array.isArray(parsed) || parsed.length > 64 || (requireSyntheticValues ? parsed.length < 1 : parsed.length !== 0)) {
    throw new ConfigurationError(
      "ROOMSCAN_STRIPE_PRICE_PLAN_MAP_JSON must contain dev-only synthetic mappings and remain empty elsewhere",
    );
  }
  const prices = new Set<string>();
  const plans = new Set<string>();
  return Object.freeze(parsed.map((entry) => {
    if (!isRecord(entry) || Object.keys(entry).sort().join(",") !== "planKey,priceId"
      || typeof entry.priceId !== "string" || !/^price_[A-Za-z0-9]{6,255}$/u.test(entry.priceId)
      || typeof entry.planKey !== "string" || !/^[A-Za-z0-9._-]{1,128}$/u.test(entry.planKey)
      || prices.has(entry.priceId) || plans.has(entry.planKey)) {
      throw new ConfigurationError("ROOMSCAN_STRIPE_PRICE_PLAN_MAP_JSON contains an invalid or duplicate mapping");
    }
    prices.add(entry.priceId);
    plans.add(entry.planKey);
    return Object.freeze({ priceId: entry.priceId, planKey: entry.planKey });
  }));
}

export function assertPlatformConfigResourceArns(config: PlatformConfig): void {
  for (const [name, arn] of [
    ["ROOMSCAN_APPLE_PRIVATE_KEY_SECRET_ARN", config.apple.privateKeySecretArn],
    ["ROOMSCAN_STRIPE_WEBHOOK_SECRET_ARN", config.stripe.webhookSecretArn],
    ["ROOMSCAN_STRIPE_API_SECRET_ARN", config.stripe.apiSecretArn]
  ] as const) {
    assertSecretsManagerSecretArn(arn, config.region, config.accountId, name);
  }
  assertKmsKeyArn(
    config.providerSecretsKmsKeyArn,
    config.region,
    config.accountId,
    "ROOMSCAN_PROVIDER_SECRETS_KMS_KEY_ARN",
  );
  assertSesIdentityArn(
    config.ses.identityArn,
    config.region,
    config.accountId,
    "ROOMSCAN_SES_IDENTITY_ARN",
  );
}

export function cdkAvailabilityZonesContext(config: PlatformConfig): Readonly<Record<string, unknown>> {
  return {
    [`availability-zones:account=${config.accountId}:region=${config.region}`]: [
      ...config.availabilityZones
    ]
  };
}

function required(environment: Readonly<NodeJS.ProcessEnv>, name: string): string {
  const value = environment[name];
  if (value === undefined || value.trim().length === 0) {
    throw new ConfigurationError(`${name} is required for offline synthesis`);
  }
  if (value !== value.trim()) {
    throw new ConfigurationError(`${name} must not contain leading or trailing whitespace`);
  }
  return value;
}

function loadAccountTopology(path: string): AccountTopology {
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(path, "utf8")) as unknown;
  } catch {
    throw new ConfigurationError("ROOMSCAN_ACCOUNT_TOPOLOGY_FILE must reference readable account topology JSON");
  }
  if (!isRecord(parsed)) {
    throw new ConfigurationError("account topology must be a JSON object");
  }
  const keys = Object.keys(parsed).sort();
  const expected = [...TOPOLOGY_KEYS].sort();
  if (keys.length !== expected.length || keys.some((key, index) => key !== expected[index])) {
    throw new ConfigurationError(`account topology must contain exactly ${expected.join(", ")}`);
  }
  const values: Record<string, string> = {};
  for (const key of TOPOLOGY_KEYS) {
    const value = parsed[key];
    if (typeof value !== "string") {
      throw new ConfigurationError(`account topology ${key} must be a 12-digit account ID`);
    }
    assertAccountId(value, `account topology ${key}`);
    values[key] = value;
  }
  if (new Set(Object.values(values)).size !== TOPOLOGY_KEYS.length) {
    throw new ConfigurationError("account topology account IDs must be distinct");
  }
  return values as unknown as AccountTopology;
}

function isRecord(value: unknown): value is Readonly<Record<string, unknown>> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function assertAccountId(value: string, name: string): void {
  if (!/^\d{12}$/u.test(value)) {
    throw new ConfigurationError(`${name} must be a 12-digit account ID`);
  }
}

function assertSecretsManagerSecretArn(
  arn: string,
  region: string,
  accountId: string,
  name: string,
): void {
  const prefix = `arn:aws:secretsmanager:${region}:${accountId}:secret:`;
  const resource = arn.startsWith(prefix) ? arn.slice(prefix.length) : "";
  if (
    arn.length > 2_048 ||
    !/^[A-Za-z0-9/_+=.@-]{1,512}-[A-Za-z0-9]{6}$/u.test(resource)
  ) {
    throw new ConfigurationError(
      `${name} must be a complete Secrets Manager secret ARN in the same workload account and us-east-1 region`,
    );
  }
}

function assertKmsKeyArn(
  arn: string,
  region: string,
  accountId: string,
  name: string,
): void {
  const prefix = `arn:aws:kms:${region}:${accountId}:key/`;
  const resource = arn.startsWith(prefix) ? arn.slice(prefix.length) : "";
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu.test(resource)) {
    throw new ConfigurationError(
      `${name} must be an exact customer-managed KMS key UUID ARN in the same workload account and us-east-1 region`,
    );
  }
}

function assertSesIdentityArn(
  arn: string,
  region: string,
  accountId: string,
  name: string,
): void {
  const prefix = `arn:aws:ses:${region}:${accountId}:identity/`;
  const resource = arn.startsWith(prefix) ? arn.slice(prefix.length) : "";
  if (resource.length > 320 || !isSesIdentityResource(resource)) {
    throw new ConfigurationError(
      `${name} must be an exact non-empty bounded SES identity ARN in the same workload account and us-east-1 region`,
    );
  }
}

function isSesIdentityResource(resource: string): boolean {
  const domain = "(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\\.)+[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?";
  const emailLocal = "[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]{1,64}";
  const email = `${emailLocal}@${domain}`;
  return new RegExp(`^(?:${domain}|${email})$`, "u").test(resource);
}

function boundedIdentifier(value: string, name: string, maximumLength: number): string {
  if (value.length > maximumLength || !/^[A-Za-z0-9._-]+$/u.test(value)) {
    throw new ConfigurationError(`${name} must be a bounded non-secret identifier`);
  }
  return value;
}

function acu(environment: Readonly<NodeJS.ProcessEnv>, name: string): number {
  const value = Number(required(environment, name));
  if (!Number.isFinite(value) || value < 0.5 || value > 128 || value * 2 !== Math.trunc(value * 2)) {
    throw new ConfigurationError(`${name} must be between 0.5 and 128 in 0.5 ACU increments`);
  }
  return value;
}

function availabilityZonePair(value: string): readonly [string, string] {
  const zones = value.split(",");
  if (
    zones.length !== 2 ||
    zones[0] === undefined ||
    zones[1] === undefined ||
    zones[0] === zones[1] ||
    zones.some((zone) => !/^us-east-1[a-z]$/u.test(zone))
  ) {
    throw new ConfigurationError(
      "ROOMSCAN_AVAILABILITY_ZONES must contain two distinct comma-separated us-east-1 zones",
    );
  }
  return [zones[0], zones[1]];
}

function integer(
  environment: Readonly<NodeJS.ProcessEnv>,
  name: string,
  minimum: number,
  maximum: number,
): number {
  const value = Number(required(environment, name));
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new ConfigurationError(`${name} must be an integer between ${minimum} and ${maximum}`);
  }
  return value;
}
