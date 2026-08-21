import assert from "node:assert/strict";
import test from "node:test";

import {
  evaluateTrailStatus,
  runTrailStatusMonitor,
  type TrailStatusSnapshot
} from "../src/functions/cloudtrail-status-monitor.js";

const NOW = new Date("2026-08-19T12:00:00.000Z");
const FRESH_STATUS: TrailStatusSnapshot = {
  isLogging: true,
  latestDeliveryTime: new Date("2026-08-19T11:55:00.000Z"),
  latestDigestDeliveryTime: new Date("2026-08-19T11:00:00.000Z")
};

test("fresh, error-free CloudTrail delivery and digest status is healthy", () => {
  assert.deepEqual(evaluateTrailStatus(FRESH_STATUS, NOW, {
    maximumDeliveryAgeSeconds: 1_800,
    maximumDigestAgeSeconds: 7_200
  }), {
    healthy: true,
    reasons: []
  });
});

test("CloudTrail logging, delivery errors, digest errors, and stale timestamps each make status unhealthy", () => {
  const cases: readonly {
    readonly name: string;
    readonly status: TrailStatusSnapshot;
    readonly reason: string;
  }[] = [
    { name: "logging disabled", status: { ...FRESH_STATUS, isLogging: false }, reason: "not-logging" },
    {
      name: "delivery error",
      status: { ...FRESH_STATUS, latestDeliveryError: "AccessDenied" },
      reason: "delivery-error"
    },
    {
      name: "digest error",
      status: { ...FRESH_STATUS, latestDigestDeliveryError: "AccessDenied" },
      reason: "digest-delivery-error"
    },
    {
      name: "missing delivery timestamp",
      status: { ...FRESH_STATUS, latestDeliveryTime: undefined },
      reason: "delivery-stale"
    },
    {
      name: "stale digest timestamp",
      status: {
        ...FRESH_STATUS,
        latestDigestDeliveryTime: new Date("2026-08-19T09:59:59.000Z")
      },
      reason: "digest-stale"
    }
  ];
  for (const fixture of cases) {
    const result = evaluateTrailStatus(fixture.status, NOW, {
      maximumDeliveryAgeSeconds: 1_800,
      maximumDigestAgeSeconds: 7_200
    });
    assert.equal(result.healthy, false, fixture.name);
    assert.ok(result.reasons.includes(fixture.reason), fixture.name);
  }
});

test("the monitor checks the configured trail ARN and emits one bounded health metric plus heartbeat", async () => {
  const calls: string[] = [];
  const publications: unknown[] = [];
  const result = await runTrailStatusMonitor({
    async getTrailStatus(trailArn: string) {
      calls.push(trailArn);
      return FRESH_STATUS;
    },
    async putMetricData(publication: unknown) {
      publications.push(publication);
    }
  }, {
    trailArn: "arn:aws:cloudtrail:us-east-1:444444444444:trail/roomscan-dev-platform",
    trailName: "roomscan-dev-platform",
    stage: "dev",
    metricNamespace: "RoomScan/CloudTrail",
    maximumDeliveryAgeSeconds: 1_800,
    maximumDigestAgeSeconds: 7_200
  }, NOW);

  assert.deepEqual(calls, [
    "arn:aws:cloudtrail:us-east-1:444444444444:trail/roomscan-dev-platform"
  ]);
  assert.deepEqual(publications, [{
    namespace: "RoomScan/CloudTrail",
    metricData: [
      {
        metricName: "TrailDeliveryHealthy",
        value: 1,
        timestamp: NOW,
        dimensions: [
          { name: "Stage", value: "dev" },
          { name: "TrailName", value: "roomscan-dev-platform" }
        ]
      },
      {
        metricName: "TrailStatusHeartbeat",
        value: 1,
        timestamp: NOW,
        dimensions: [
          { name: "Stage", value: "dev" },
          { name: "TrailName", value: "roomscan-dev-platform" }
        ]
      }
    ]
  }]);
  assert.deepEqual(result, { healthy: true, reasons: [] });
});
