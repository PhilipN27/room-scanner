#!/usr/bin/env node

import { App } from "aws-cdk-lib";

import { cdkAvailabilityZonesContext, loadPlatformConfig } from "../src/config.js";
import { assertInfrastructurePolicy } from "../src/policy/template-policy.js";
import { RoomScanPlatformStack } from "../src/stacks/platform-stack.js";

const config = loadPlatformConfig(process.env);
const app = new App({ context: cdkAvailabilityZonesContext(config) });
const stack = new RoomScanPlatformStack(app, `RoomScanPlatform-${config.stage}`, {
  config,
  env: {
    account: config.accountId,
    region: config.region
  }
});

const assembly = app.synth();
const stackArtifact = assembly.getStackArtifact(stack.artifactId);
assertInfrastructurePolicy(stackArtifact.template);
