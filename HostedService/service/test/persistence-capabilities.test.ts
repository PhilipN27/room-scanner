import assert from "node:assert/strict";
import test from "node:test";

import {
  CapabilityRepositoryError,
  DataApiCapabilityRepository,
} from "../src/persistence/capabilities.js";
import { DataApiApiPolicyCapabilityRepository } from "../src/persistence/policy-composites.js";
import type { SqlStatement } from "../src/adapters/data-api.js";

const digest = (byte: number) => Buffer.alloc(32, byte).toString("base64url");

test("refresh capability joins nested work, passes only digest blobs and explicit timestamptz values", async () => {
  const statements: SqlStatement[] = [];
  const repository = new DataApiCapabilityRepository({
    execute: async (statement) => {
      statements.push(statement);
      return {
        rows: [{
          status: "rotated",
          principal_id: "11111111-1111-4111-8111-111111111111",
          principal_canonical_id: "prn_app_owned",
          family_id: "22222222-2222-4222-8222-222222222222",
          family_public_id: "fam_server_generated_1",
          authentication_epoch: 3,
          workspace_id: null,
          role: null,
          authorization_version: null,
          access_expires_at: "2030-01-01T00:05:00.000Z",
        }],
      };
    },
  });

  const output = await repository.transaction((outer) => outer.transaction((inner) => inner.rotateSessionFromRefresh({
    currentRefreshDigest: digest(1),
    nextRefreshDigest: digest(2),
    nextAccessDigest: digest(3),
    rotatedAtMs: Date.UTC(2030, 0, 1),
    nextAccessExpiresAtMs: Date.UTC(2030, 0, 1, 0, 5),
    nextInactivityExpiresAtMs: Date.UTC(2030, 0, 8),
  })));

  assert.deepEqual(output, {
    status: "rotated",
    principalInternalId: "11111111-1111-4111-8111-111111111111",
    principalCanonicalId: "prn_app_owned",
    familyInternalId: "22222222-2222-4222-8222-222222222222",
    familyPublicId: "fam_server_generated_1",
    authenticationEpoch: 3,
    accessExpiresAtMs: Date.UTC(2030, 0, 1, 0, 5),
  });
  assert.equal(statements.length, 1);
  const statement = statements[0]!;
  assert.match(statement.sql, /roomscan\.rotate_session_from_refresh/u);
  assert.match(statement.sql, /\(:rotated_at\)::timestamptz/u);
  assert.equal(statement.sql.includes("workspace"), false);
  assert.deepEqual(statement.parameters?.slice(0, 3).map((parameter) => parameter.value), [
    { kind: "blob", bytes: Buffer.alloc(32, 1) },
    { kind: "blob", bytes: Buffer.alloc(32, 2) },
    { kind: "blob", bytes: Buffer.alloc(32, 3) },
  ]);
  assert.deepEqual(statement.parameters?.slice(3).map((parameter) => parameter.value), [
    { kind: "string", value: "2030-01-01T00:00:00.000Z" },
    { kind: "string", value: "2030-01-01T00:05:00.000Z" },
    { kind: "string", value: "2030-01-08T00:00:00.000Z" },
  ]);
  assert.equal("execute" in (repository as unknown as Record<string, unknown>), false);
});

test("refresh capability rejects unknown frozen result enums", async () => {
  const repository = new DataApiCapabilityRepository({
    execute: async () => ({ rows: [{ status: "forged" }] }),
  });
  await assert.rejects(
    repository.rotateSessionFromRefresh({
      currentRefreshDigest: digest(1), nextRefreshDigest: digest(2), nextAccessDigest: digest(3),
      rotatedAtMs: 0, nextAccessExpiresAtMs: 1, nextInactivityExpiresAtMs: 2,
    }),
    CapabilityRepositoryError,
  );
});

test("refresh capability preserves the valid epoch-zero first-session result", async () => {
  const repository = new DataApiCapabilityRepository({
    execute: async () => ({ rows: [{
      status: "rotated",
      principal_id: "11111111-1111-4111-8111-111111111111",
      principal_canonical_id: "prn_first_session",
      family_id: "22222222-2222-4222-8222-222222222222",
      family_public_id: "fam_first_session_0",
      authentication_epoch: 0,
      workspace_id: null,
      role: null,
      authorization_version: null,
      access_expires_at: "2030-01-01T00:05:00.000Z",
    }] }),
  });
  const output = await repository.rotateSessionFromRefresh({
    currentRefreshDigest: digest(1), nextRefreshDigest: digest(2), nextAccessDigest: digest(3),
    rotatedAtMs: Date.UTC(2030, 0, 1),
    nextAccessExpiresAtMs: Date.UTC(2030, 0, 1, 0, 5),
    nextInactivityExpiresAtMs: Date.UTC(2030, 0, 8),
  });
  assert.equal(output.status, "rotated");
  assert.equal(output.authenticationEpoch, 0);
});

test("the API capability bundle exposes the exact policy composite only when access scope is bound", () => {
  const unbound = new DataApiCapabilityRepository({ execute: async () => ({ rows: [] }) });
  assert.throws(() => unbound.policy(), CapabilityRepositoryError);
  const bound = new DataApiCapabilityRepository({ execute: async () => ({ rows: [] }) }, { accessTokenDigest: Buffer.alloc(32, 7) });
  assert.ok(bound.policy() instanceof DataApiApiPolicyCapabilityRepository);
});
