import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import test from "node:test";

test("infrastructure verification pins the explicitly approved Node 24.15.0 runtime", () => {
  const packageManifest = JSON.parse(readFileSync(resolve("package.json"), "utf8")) as {
    readonly engines?: Readonly<{ readonly node?: string }>;
  };
  const lockfile = JSON.parse(readFileSync(resolve("package-lock.json"), "utf8")) as {
    readonly packages?: Readonly<Record<string, { readonly engines?: Readonly<{ readonly node?: string }> }>>;
  };
  assert.equal(packageManifest.engines?.node, "24.15.0");
  assert.equal(lockfile.packages?.[""]?.engines?.node, "24.15.0");
  assert.equal(process.versions.node, "24.15.0");
});

test("offline verification replaces hostile ROOMSCAN/AWS/CDK state with deterministic local-only values", () => {
  const result = spawnSync(process.execPath, [resolve("scripts/run-offline-verify.mjs"), "--print-environment"], {
    cwd: process.cwd(),
    encoding: "utf8",
    env: {
      ...process.env,
      ROOMSCAN_ACCOUNT_ID: "999999999999",
      ROOMSCAN_STAGE: "production",
      ROOMSCAN_REGION: "us-west-2",
      AWS_ACCESS_KEY_ID: "HOSTILE_ACCESS_KEY",
      AWS_SECRET_ACCESS_KEY: "HOSTILE_SECRET_KEY",
      AWS_SESSION_TOKEN: "HOSTILE_SESSION_TOKEN",
      AWS_PROFILE: "hostile-profile",
      CDK_DEFAULT_ACCOUNT: "999999999999",
      CDK_DEFAULT_REGION: "us-west-2",
      CDK_OUTDIR: "/tmp/hostile-cdk-output",
    },
  });
  assert.equal(result.status, 0, result.stderr);
  const summary = JSON.parse(result.stdout) as {
    readonly roomscan: Readonly<Record<string, string>>;
    readonly retainedAwsOrCdk: readonly string[];
  };
  assert.equal(summary.roomscan.ROOMSCAN_ACCOUNT_ID, "444444444444");
  assert.equal(summary.roomscan.ROOMSCAN_STAGE, "dev");
  assert.equal(summary.roomscan.ROOMSCAN_REGION, "us-east-1");
  assert.deepEqual(summary.retainedAwsOrCdk, []);
  assert.doesNotMatch(result.stdout, /HOSTILE|999999999999|us-west-2/u);
});

test("standalone synthesis still fails closed without its explicit environment", () => {
  const environment = { ...process.env };
  for (const name of Object.keys(environment)) {
    if (name.startsWith("ROOMSCAN_") || name.startsWith("AWS_") || name.startsWith("CDK_")) {
      delete environment[name];
    }
  }
  const result = spawnSync(process.execPath, [resolve("dist/bin/app.js")], {
    cwd: process.cwd(),
    encoding: "utf8",
    env: environment,
  });
  assert.notEqual(result.status, 0);
  assert.match(`${result.stdout}\n${result.stderr}`, /ROOMSCAN_ACCOUNT_ID is required/u);
});
