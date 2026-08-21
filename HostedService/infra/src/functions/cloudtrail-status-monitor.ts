import {
  CloudTrailClient,
  GetTrailStatusCommand
} from "@aws-sdk/client-cloudtrail";
import {
  CloudWatchClient,
  PutMetricDataCommand
} from "@aws-sdk/client-cloudwatch";

export interface TrailStatusSnapshot {
  readonly isLogging?: boolean;
  readonly latestDeliveryError?: string;
  readonly latestDigestDeliveryError?: string;
  readonly latestDeliveryTime?: Date;
  readonly latestDigestDeliveryTime?: Date;
}

export interface TrailStatusThresholds {
  readonly maximumDeliveryAgeSeconds: number;
  readonly maximumDigestAgeSeconds: number;
}

export interface TrailStatusResult {
  readonly healthy: boolean;
  readonly reasons: readonly string[];
}

interface MetricDimension {
  readonly name: string;
  readonly value: string;
}

interface MetricDatum {
  readonly metricName: "TrailDeliveryHealthy" | "TrailStatusHeartbeat";
  readonly value: number;
  readonly timestamp: Date;
  readonly dimensions: readonly MetricDimension[];
}

export interface MetricPublication {
  readonly namespace: string;
  readonly metricData: readonly MetricDatum[];
}

export interface TrailStatusMonitorDependencies {
  readonly getTrailStatus: (trailArn: string) => Promise<TrailStatusSnapshot>;
  readonly putMetricData: (publication: MetricPublication) => Promise<void>;
}

export interface TrailStatusMonitorConfig extends TrailStatusThresholds {
  readonly trailArn: string;
  readonly trailName: string;
  readonly stage: string;
  readonly metricNamespace: string;
}

export function evaluateTrailStatus(
  status: TrailStatusSnapshot,
  now: Date,
  thresholds: TrailStatusThresholds,
): TrailStatusResult {
  const reasons: string[] = [];
  if (status.isLogging !== true) {
    reasons.push("not-logging");
  }
  if (hasError(status.latestDeliveryError)) {
    reasons.push("delivery-error");
  }
  if (hasError(status.latestDigestDeliveryError)) {
    reasons.push("digest-delivery-error");
  }
  if (isStale(status.latestDeliveryTime, now, thresholds.maximumDeliveryAgeSeconds)) {
    reasons.push("delivery-stale");
  }
  if (isStale(status.latestDigestDeliveryTime, now, thresholds.maximumDigestAgeSeconds)) {
    reasons.push("digest-stale");
  }
  return { healthy: reasons.length === 0, reasons };
}

export async function runTrailStatusMonitor(
  dependencies: TrailStatusMonitorDependencies,
  config: TrailStatusMonitorConfig,
  now: Date,
): Promise<TrailStatusResult> {
  const status = await dependencies.getTrailStatus(config.trailArn);
  const result = evaluateTrailStatus(status, now, config);
  const dimensions = [
    { name: "Stage", value: config.stage },
    { name: "TrailName", value: config.trailName }
  ] as const;
  await dependencies.putMetricData({
    namespace: config.metricNamespace,
    metricData: [
      {
        metricName: "TrailDeliveryHealthy",
        value: result.healthy ? 1 : 0,
        timestamp: now,
        dimensions
      },
      {
        metricName: "TrailStatusHeartbeat",
        value: 1,
        timestamp: now,
        dimensions
      }
    ]
  });
  return result;
}

export async function handler(): Promise<void> {
  const config: TrailStatusMonitorConfig = {
    trailArn: requiredEnvironment("TRAIL_ARN"),
    trailName: requiredEnvironment("TRAIL_NAME"),
    stage: requiredEnvironment("ROOMSCAN_STAGE"),
    metricNamespace: requiredEnvironment("METRIC_NAMESPACE"),
    maximumDeliveryAgeSeconds: positiveIntegerEnvironment("MAX_DELIVERY_AGE_SECONDS"),
    maximumDigestAgeSeconds: positiveIntegerEnvironment("MAX_DIGEST_AGE_SECONDS")
  };
  const region = requiredEnvironment("ROOMSCAN_REGION");
  const cloudTrail = new CloudTrailClient({ region });
  const cloudWatch = new CloudWatchClient({ region });
  await runTrailStatusMonitor({
    async getTrailStatus(trailArn) {
      const status = await cloudTrail.send(new GetTrailStatusCommand({ Name: trailArn }));
      return {
        isLogging: status.IsLogging,
        latestDeliveryError: status.LatestDeliveryError,
        latestDigestDeliveryError: status.LatestDigestDeliveryError,
        latestDeliveryTime: status.LatestDeliveryTime,
        latestDigestDeliveryTime: status.LatestDigestDeliveryTime
      };
    },
    async putMetricData(publication) {
      await cloudWatch.send(new PutMetricDataCommand({
        Namespace: publication.namespace,
        MetricData: publication.metricData.map((datum) => ({
          MetricName: datum.metricName,
          Value: datum.value,
          Timestamp: datum.timestamp,
          Unit: "Count",
          Dimensions: datum.dimensions.map((dimension) => ({
            Name: dimension.name,
            Value: dimension.value
          }))
        }))
      }));
    }
  }, config, new Date());
}

function hasError(value: string | undefined): boolean {
  return value !== undefined && value.trim().length > 0;
}

function isStale(value: Date | undefined, now: Date, maximumAgeSeconds: number): boolean {
  return value === undefined ||
    !Number.isFinite(value.getTime()) ||
    now.getTime() - value.getTime() > maximumAgeSeconds * 1_000;
}

function requiredEnvironment(name: string): string {
  const value = process.env[name];
  if (value === undefined || value.length === 0) {
    throw new Error(`${name} is required`);
  }
  return value;
}

function positiveIntegerEnvironment(name: string): number {
  const value = Number(requiredEnvironment(name));
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`${name} must be a positive integer`);
  }
  return value;
}
