import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import test from "node:test";

import { DataApiAppAuthorizer } from "../src/persistence/app-authorizer.js";
import type { DataApiClient } from "../src/adapters/data-api.js";

const token = Buffer.alloc(32, 0x3c).toString("base64url");
const key = Buffer.alloc(32, 0x5d);

test("app authorizer performs only a role-bound access preflight and fails closed before an invalid token starts a transaction", async () => {
  const statements: string[] = [];
  let beginCount = 0;
  const client: DataApiClient = {
    begin: async () => { beginCount += 1; return { transactionId: "authorizer-transaction" }; },
    execute: async (input) => {
      statements.push(input.sql);
      if (input.sql.includes("resolve_access_context")) {
        const digest = input.parameters?.find((parameter) => parameter.name === "access_token_hash")?.value;
        assert.equal(digest?.kind, "blob");
        assert.deepEqual(Buffer.from(digest?.kind === "blob" ? digest.bytes : []), createHmac("sha256", key).update(token).digest());
        return { rows: [{
          principal_id: "11111111-1111-4111-8111-111111111111",
          canonical_principal_id: "prn_authorizer",
          family_id: "22222222-2222-4222-8222-222222222222",
          family_public_id: "fam_authorizer_001",
          workspace_id: null,
          role: null,
          authorization_version: null,
          authentication_epoch: 0,
          authenticated_at: "2030-01-01T00:00:00.000Z",
          recent_authentication: false,
        }] };
      }
      return { rows: [] };
    },
    commit: async () => undefined,
    rollback: async () => undefined,
  };
  const authorizer = new DataApiAppAuthorizer({
    client,
    accessTokenHmacKey: key,
    clock: { now: () => new Date("2030-01-01T00:01:00.000Z") },
  });

  assert.equal(await authorizer.authorizeBearer(token), true);
  assert.equal(await authorizer.authorizeBearer("not-a-canonical-access-token"), false);
  assert.equal(beginCount, 1);
  assert.equal(statements.filter((statement) => statement.includes("resolve_access_context")).length, 1);
  assert.equal(statements.some((statement) => statement.includes("read_workspace_authorization_state")), false);
});
