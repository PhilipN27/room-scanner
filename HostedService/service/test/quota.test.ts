import assert from "node:assert/strict";
import test from "node:test";

import {
  SystemQuotaService,
  WorkspaceQuotaService,
  WORKSPACE_QUOTA_ALLOCATION_ACTIONS,
} from "../src/quota/quota-v2-service.js";
import * as quotaV2 from "../src/quota/quota-v2-service.js";

test("production quota exports contain only the tenant-derived client and explicit system compositions", () => {
  assert.deepEqual(WORKSPACE_QUOTA_ALLOCATION_ACTIONS, {
    project_count: "project.create",
    working_bytes: "project.revise",
    raw_bytes: "raw_archive.allocate",
    portal_bytes: "publication.create",
  });
  assert.deepEqual(
    Object.getOwnPropertyNames(WorkspaceQuotaService.prototype).sort(),
    ["constructor", "finalize", "release", "reserve", "snapshot"],
  );
  assert.deepEqual(
    Object.getOwnPropertyNames(SystemQuotaService.prototype).sort(),
    ["activatePolicy", "constructor", "expire", "reconcile"],
  );
  assert.equal("QuotaService" in quotaV2, false);
  assert.equal("SystemOnlyQuotaCompatibilityService" in quotaV2, false);
});
