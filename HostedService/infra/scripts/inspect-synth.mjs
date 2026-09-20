import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

import { assertInfrastructurePolicy } from "../dist/src/policy/template-policy.js";

const outputDirectory = resolve("cdk.out");
const templatePath = join(outputDirectory, "RoomScanPlatform-dev.template.json");
const assetsManifestPath = join(outputDirectory, "RoomScanPlatform-dev.assets.json");
const templateBytes = readFileSync(templatePath);
const template = JSON.parse(templateBytes.toString("utf8"));
assertInfrastructurePolicy(template);

const assetsManifestBytes = readFileSync(assetsManifestPath);
const assetsManifest = JSON.parse(assetsManifestBytes.toString("utf8"));
const lambdaAssets = Object.values(assetsManifest.files)
  .filter((file) => file.source.packaging === "zip")
  .sort((left, right) => left.displayName.localeCompare(right.displayName));
const expectedLambdaAssetNames = [
  "AppAuthorizationFunction/Code",
  "AuditExporterFunction/Code",
  "AuthChallengesFunction/Code",
  "CloudTrailStatusMonitorFunction/Code",
  "EmailDeliveryFunction/Code",
  "MigrationOperatorFunction/Code",
  "PortalDeliveryFunction/Code",
  "PrivateApiFunction/Code",
  "ProjectSyncValidationFunction/Code",
  "PublicationValidationFunction/Code",
  "StripeIngressFunction/Code",
  "StripeReconciliationFunction/Code"
];
const actualLambdaAssetNames = lambdaAssets.map((asset) => asset.displayName);
if (JSON.stringify(actualLambdaAssetNames) !== JSON.stringify(expectedLambdaAssetNames)) {
  throw new Error(
    `Lambda asset closure diverged: expected=${expectedLambdaAssetNames.join(",")}; `
      + `actual=${actualLambdaAssetNames.join(",") || "none"}`,
  );
}
const manifestAssetDirectories = lambdaAssets.map((asset) => asset.source.path).sort();
const outputAssetEntries = readdirSync(outputDirectory, { withFileTypes: true })
  .filter((entry) => entry.name.startsWith("asset."));
const outputAssetDirectories = outputAssetEntries
  .filter((entry) => entry.isDirectory())
  .map((entry) => entry.name)
  .sort();
if (
  outputAssetEntries.some((entry) => !entry.isDirectory())
  || JSON.stringify(outputAssetDirectories) !== JSON.stringify(manifestAssetDirectories)
) {
  const manifestSet = new Set(manifestAssetDirectories);
  const outputSet = new Set(outputAssetDirectories);
  const orphaned = outputAssetDirectories.filter((directory) => !manifestSet.has(directory));
  const missing = manifestAssetDirectories.filter((directory) => !outputSet.has(directory));
  const nonDirectories = outputAssetEntries.filter((entry) => !entry.isDirectory()).map((entry) => entry.name);
  throw new Error(
    `cdk.out assets diverge from the manifest: orphaned=${orphaned.join(",") || "none"}; `
      + `missing=${missing.join(",") || "none"}; nonDirectories=${nonDirectories.join(",") || "none"}`,
  );
}

const migrationNames = [
  "0001_roles_and_global.up.sql",
  "0002_tenant_core.up.sql",
  "0003_quota.up.sql",
  "0004_stripe.up.sql",
  "0005_hardened_reducers.up.sql",
  "0006_auth_persistence.up.sql",
  "0007_policy_billing_integration.up.sql",
  "0008_professional_project_sync.up.sql",
  "0009_publication_portal.up.sql"
];
const migrationAssetFiles = [
  "index.mjs",
  "index.mjs.map",
  "migration-assets/migrate.mjs",
  "migration-assets/migration-manifest.json",
  ...migrationNames.map((name) => `migration-assets/migrations/${name}`),
  "migration-assets/rds-global-bundle.pem"
].sort();
const portalAssetFiles = [
  "index.mjs",
  "index.mjs.map",
  "portal-assets/asset-manifest.json",
  "portal-assets/portal.css",
  "portal-assets/portal.js"
].sort();

const forbiddenPatterns = [
  /-----BEGIN (?:EC |RSA )?PRIVATE KEY-----/u,
  /\bAKIA[0-9A-Z]{16}\b/u,
  /\bASIA[0-9A-Z]{16}\b/u,
  /\bsk_(?:live|test)_[A-Za-z0-9]+\b/u,
  /\bwhsec_[A-Za-z0-9]+\b/u,
  /roomscan-(?:apple|stripe)-(?:reference|api|webhook)-000001/u,
  /TEST_CONFIG|VALID_ENV|DUMMY_ACCOUNT_ID/u
];
const forbiddenProductionMarkers = [
  /fail-closed until service integration/iu,
  /service_integration_not_configured|integration_not_configured|\bnot_configured\b/iu,
  /deny[-_ ]all/iu,
  /statusCode\s*[:=]\s*503/iu
];

const artifacts = [
  artifactRecord(templatePath, templateBytes),
  artifactRecord(assetsManifestPath, assetsManifestBytes)
];
let inspectedCloudTrailStatusMonitor = false;
let inspectedMigrationOperator = false;
let inspectedProjectSyncValidation = false;
let inspectedPublicationValidation = false;
let inspectedPortalDelivery = false;
let inspectedPrivateApi = false;
for (const asset of lambdaAssets) {
  const directory = join(outputDirectory, asset.source.path);
  const files = recursiveFiles(directory);
  const expectedFiles = asset.displayName === "MigrationOperatorFunction/Code"
    ? migrationAssetFiles
    : asset.displayName === "PortalDeliveryFunction/Code"
      ? portalAssetFiles
      : ["index.mjs", "index.mjs.map"];
  if (
    JSON.stringify(files) !== JSON.stringify(expectedFiles) ||
    files.some((file) => file.includes("test"))
  ) {
    throw new Error(`${asset.displayName} contains an unexpected production asset set: ${files.join(", ")}`);
  }
  let bundle = "";
  for (const file of files) {
    const assetFilePath = join(directory, file);
    const assetFileBytes = readFileSync(assetFilePath);
    const assetFileText = assetFileBytes.toString("utf8");
    for (const pattern of forbiddenPatterns) {
      if (pattern.test(assetFileText)) {
        throw new Error(`${asset.displayName}/${file} contains forbidden credential or test material: ${pattern}`);
      }
    }
    for (const pattern of forbiddenProductionMarkers) {
      if (pattern.test(assetFileText)) {
        throw new Error(`${asset.displayName}/${file} contains a forbidden production-entrypoint marker: ${pattern}`);
      }
    }
    artifacts.push({
      ...artifactRecord(assetFilePath, assetFileBytes),
      displayName: `${asset.displayName}/${file}`
    });
    if (file === "index.mjs") {
      bundle = assetFileText;
    }
  }
  if (asset.displayName === "StripeIngressFunction/Code") {
    if (!bundle.includes("isBase64Encoded") || !/\b(?:event|envelope)\.body\b/u.test(bundle)) {
      throw new Error("Stripe ingress bundle lost the raw body/base64 envelope");
    }
    const signatureVerification = bundle.indexOf("this.safelyVerify(rawBody, signature)");
    const webhookParsing = bundle.indexOf("parseStripeWebhookEvent(rawBody)");
    if (signatureVerification < 0 || webhookParsing <= signatureVerification) {
      throw new Error("Stripe ingress bundle must verify the raw body before parsing the webhook event");
    }
    if (/console\./u.test(bundle)) {
      throw new Error("Stripe ingress bundle must not generically log the webhook body");
    }
  }
  if (asset.displayName.includes("CloudTrailStatusMonitor")) {
    inspectedCloudTrailStatusMonitor = true;
    for (const symbol of [
      "GetTrailStatusCommand",
      "LatestDeliveryError",
      "LatestDigestDeliveryError",
      "TrailDeliveryHealthy",
      "TrailStatusHeartbeat",
      "PutMetricDataCommand"
    ]) {
      if (!bundle.includes(symbol)) {
        throw new Error(`CloudTrail status monitor bundle lost required behavior: ${symbol}`);
      }
    }
    if (bundle.includes('Namespace:"AWS/CloudTrail",MetricName:"DeliveryErrors"')) {
      throw new Error("CloudTrail status monitor bundle contains the unsupported DeliveryErrors metric tuple");
    }
  }
  if (asset.displayName === "MigrationOperatorFunction/Code") {
    inspectedMigrationOperator = true;
    verifyMigrationAssetBytes(directory, template);
    for (const symbol of [
      "MIGRATION_MANIFEST_SHA256",
      "MIGRATIONS_PATH",
      "SecretsManagerClient",
      "maxUses: 1",
      "rejectUnauthorized: true",
      "roomscan_project_sync_runtime",
      "roomscan_publication_worker",
      "roomscan_portal_runtime"
    ]) {
      if (!bundle.includes(symbol)) {
        throw new Error(`migration operator bundle lost required behavior: ${symbol}`);
      }
    }
  }
  if (asset.displayName === "PrivateApiFunction/Code") {
    inspectedPrivateApi = true;
    for (const symbol of [
      "createSlice5DataApiProjectSyncHandler",
      "slice5.project-sync-lease-hmac.v1",
      "PROJECT_SYNC_VALIDATION_QUEUE_URL",
      "roomscan-project-validation-wake-v1",
      "presignExactDownload",
      "createSlice6DataApiPublicationHandler",
      "publication-validation-wake-v1"
    ]) {
      if (!bundle.includes(symbol)) {
        throw new Error(`Slice 5/6 private API bundle lost required behavior: ${symbol}`);
      }
    }
  }
  if (asset.displayName === "ProjectSyncValidationFunction/Code") {
    inspectedProjectSyncValidation = true;
    for (const symbol of [
      "CopyObjectCommand",
      "ChecksumMode",
      "encodeURIComponent",
      "roomscan_project_sync_runtime",
      "roomscan-project-validation-wake-v1",
      "ProjectSyncValidationWorker"
    ]) {
      if (!bundle.includes(symbol)) {
        throw new Error(`project-sync validation bundle lost required behavior: ${symbol}`);
      }
    }
    const copyCommand = bundle.indexOf("CopyObjectCommand({");
    if (copyCommand < 0 || bundle.indexOf('IfNoneMatch: "*"', copyCommand) < copyCommand) {
      throw new Error("project-sync validation bundle lost destination conditional CopyObject");
    }
    if (bundle.includes("CopySourceIfNoneMatch")) {
      throw new Error("project-sync validation bundle incorrectly uses CopySourceIfNoneMatch");
    }
    if (/console\.(?:debug|error|info|log|warn)\(/u.test(bundle)) {
      throw new Error("project-sync validation bundle must not log object, version, or queue payload data");
    }
  }
  if (asset.displayName === "PublicationValidationFunction/Code") {
    inspectedPublicationValidation = true;
    for (const symbol of [
      "createSlice6PublicationWorker",
      "PublicationObjectAdapter",
      "roomscan_publication_worker",
      "roomscan-publication-validation-wake-v1"
    ]) {
      if (!bundle.includes(symbol)) {
        throw new Error(`publication validation bundle lost required behavior: ${symbol}`);
      }
    }
    if (/console\.(?:debug|error|info|log|warn)\(/u.test(bundle)) {
      throw new Error("publication validation bundle must not log object, version, or queue payload data");
    }
  }
  if (asset.displayName === "PortalDeliveryFunction/Code") {
    inspectedPortalDelivery = true;
    verifyPortalAssetBytes(directory);
    for (const symbol of [
      "createSlice6DataApiPortalDeliveryHandler",
      "PublicationObjectAdapter",
      "roomscan_portal_runtime",
      "publication-feedback-delivery-wake-v1"
    ]) {
      if (!bundle.includes(symbol)) {
        throw new Error(`portal delivery bundle lost required behavior: ${symbol}`);
      }
    }
    if (/console\.(?:debug|error|info|log|warn)\(/u.test(bundle)) {
      throw new Error("portal delivery bundle must not log link, session, feedback, or object data");
    }
  }
}
if (!inspectedCloudTrailStatusMonitor) {
  throw new Error("CloudTrail status monitor bundle was not present in the synthesized assets");
}
if (!inspectedMigrationOperator) {
  throw new Error("migration operator bundle was not present in the synthesized assets");
}
if (!inspectedProjectSyncValidation) {
  throw new Error("project-sync validation bundle was not present in the synthesized assets");
}
if (!inspectedPublicationValidation) {
  throw new Error("publication validation bundle was not present in the synthesized assets");
}
if (!inspectedPortalDelivery) {
  throw new Error("portal delivery bundle was not present in the synthesized assets");
}
if (!inspectedPrivateApi) {
  throw new Error("Slice 5/6 private API bundle was not present in the synthesized assets");
}

const templateText = templateBytes.toString("utf8");
for (const pattern of forbiddenProductionMarkers) {
  if (pattern.test(templateText)) {
    throw new Error(`synthesized template contains a forbidden production-entrypoint marker: ${pattern}`);
  }
}
for (const pattern of [
  /-----BEGIN (?:EC |RSA )?PRIVATE KEY-----/u,
  /\bAKIA[0-9A-Z]{16}\b/u,
  /\bASIA[0-9A-Z]{16}\b/u,
  /\bsk_(?:live|test)_[A-Za-z0-9]+\b/u,
  /\bwhsec_[A-Za-z0-9]+\b/u
]) {
  if (pattern.test(templateText)) {
    throw new Error(`synthesized template contains credential material: ${pattern}`);
  }
}
if (!templateText.includes("{{resolve:secretsmanager:")) {
  throw new Error("Apple provider must retain a Secrets Manager dynamic reference");
}
const outputText = JSON.stringify(template.Outputs ?? {});
for (const pattern of [
  /password|secretString|credentialValue/iu,
  /(?:physicalKey|VersionId)/u,
  /server\/(?:quarantine|active)\/v1\//u
]) {
  if (pattern.test(outputText)) {
    throw new Error(`synthesized outputs contain forbidden sensitive project-sync material: ${pattern}`);
  }
}
for (const file of recursiveFiles(outputDirectory)) {
  const contents = readFileSync(join(outputDirectory, file)).toString("utf8");
  for (const pattern of forbiddenProductionMarkers) {
    if (pattern.test(contents)) {
      throw new Error(`cdk.out/${file} contains a forbidden production-entrypoint marker: ${pattern}`);
    }
  }
}

const inspection = {
  generatedAt: new Date().toISOString(),
  status: "PASS",
  stack: "RoomScanPlatform-dev",
  templatePolicy: "PASS",
  lambdaAssets: lambdaAssets.length,
  lambdaAssetFiles: artifacts.length - 2,
  manifestAssetDirectoryEquality: "PASS",
  completeCdkOutputMarkerScan: "PASS",
  credentialAndFixtureScan: "PASS",
  stripeRawEnvelopeBundle: "PASS",
  cloudTrailStatusMonitorBundle: "PASS",
  migrationOperatorBundle: "PASS",
  migration0009AssetAndRuntimeRoles: "PASS",
  slice5And6PrivateApiBundle: "PASS",
  projectSyncValidationBundle: "PASS",
  publicationValidationBundle: "PASS",
  portalDeliveryBundle: "PASS",
  projectSyncOutputsNonSensitive: "PASS",
  artifacts
};
mkdirSync(resolve("evidence"), { recursive: true });
const evidencePath = resolve("evidence/artifact-inspection.json");
writeFileSync(evidencePath, `${JSON.stringify(inspection, null, 2)}\n`, { mode: 0o600 });
process.stdout.write(`${JSON.stringify(inspection, null, 2)}\n`);

function artifactRecord(path, bytes) {
  return {
    path,
    bytes: bytes.byteLength,
    sha256: createHash("sha256").update(bytes).digest("hex")
  };
}

function recursiveFiles(directory, prefix = "") {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const relative = prefix.length === 0 ? entry.name : `${prefix}/${entry.name}`;
    return entry.isDirectory()
      ? recursiveFiles(join(directory, entry.name), relative)
      : [relative];
  }).sort();
}

function verifyMigrationAssetBytes(directory, synthesizedTemplate) {
  const sourceRunner = readFileSync(resolve("../db/migrate.mjs"));
  const bundledRunner = readFileSync(join(directory, "migration-assets/migrate.mjs"));
  assertEqualBytes("migration runner", bundledRunner, sourceRunner);

  const sourceManifest = readFileSync(resolve("assets/migration-manifest.json"));
  const bundledManifest = readFileSync(join(directory, "migration-assets/migration-manifest.json"));
  assertEqualBytes("migration manifest", bundledManifest, sourceManifest);
  const manifestHash = createHash("sha256").update(sourceManifest).digest("hex");
  const migrationFunction = Object.values(synthesizedTemplate.Resources).find((resource) =>
    resource.Type === "AWS::Lambda::Function"
    && resource.Properties?.FunctionName === "roomscan-dev-migration-operator");
  if (migrationFunction?.Properties?.Environment?.Variables?.MIGRATION_MANIFEST_SHA256 !== manifestHash) {
    throw new Error("migration operator environment lost the exact manifest-byte hash");
  }

  const parsedManifest = JSON.parse(sourceManifest.toString("utf8"));
  if (parsedManifest.schema !== "roomscan-forward-migration-manifest-v1"
    || parsedManifest.migrationRunner?.name !== "migrate.mjs"
    || parsedManifest.migrationRunner?.checksumSha256 !== createHash("sha256").update(sourceRunner).digest("hex")
    || !Array.isArray(parsedManifest.migrations)
    || parsedManifest.migrations.length !== migrationNames.length) {
    throw new Error("migration manifest does not pin the exact runner and nine-file schema");
  }
  for (const [index, name] of migrationNames.entries()) {
    const source = readFileSync(resolve("../db/migrations", name));
    const bundled = readFileSync(join(directory, "migration-assets/migrations", name));
    assertEqualBytes(name, bundled, source);
    const row = parsedManifest.migrations[index];
    if (row?.version !== name.slice(0, 4) || row?.name !== name
      || row?.checksumSha256 !== createHash("sha256").update(source).digest("hex")) {
      throw new Error(`migration manifest lost exact bytes or order for ${name}`);
    }
  }

  const sourceCa = readFileSync(resolve("assets/rds-global-bundle-2026-08-19.pem"));
  const bundledCa = readFileSync(join(directory, "migration-assets/rds-global-bundle.pem"));
  assertEqualBytes("RDS CA bundle", bundledCa, sourceCa);
  if (createHash("sha256").update(sourceCa).digest("hex") !== "e5bb2084ccf45087bda1c9bffdea0eb15ee67f0b91646106e466714f9de3c7e3") {
    throw new Error("RDS CA bundle diverged from the pinned runtime hash");
  }
}

function verifyPortalAssetBytes(directory) {
  for (const name of ["asset-manifest.json", "portal.css", "portal.js"]) {
    const source = readFileSync(resolve("../web/dist", name));
    const bundled = readFileSync(join(directory, "portal-assets", name));
    assertEqualBytes(`portal asset ${name}`, bundled, source);
  }
}

function assertEqualBytes(label, actual, expected) {
  if (!actual.equals(expected)) throw new Error(`${label} was not bundled byte-for-byte`);
}
