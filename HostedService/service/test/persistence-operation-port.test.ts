import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import test from "node:test";

import {
  DataApiCapabilityOperationPort,
  requireCapabilityRepositories,
} from "../src/persistence/operation-port.js";
import type { DataApiClient, SqlCell } from "../src/adapters/data-api.js";

const token = Buffer.alloc(32, 0x61).toString("base64url");
const key = Buffer.alloc(32, 7);

test("capability operation port rereads same-tenant authorization and literal hosted flags before the workspace handler", async () => {
  const calls: Array<{ readonly kind: string; readonly sql?: string }> = [];
  const client: DataApiClient = {
    begin: async () => {
      calls.push({ kind: "begin" });
      return { transactionId: "capability-uow-1" };
    },
    execute: async (input) => {
      calls.push({ kind: "execute", sql: input.sql });
      if (input.sql.includes("resolve_access_context")) {
        const digest = input.parameters?.find((parameter) => parameter.name === "access_token_hash")?.value;
        assert.equal(digest?.kind, "blob");
        assert.deepEqual(Buffer.from(digest?.kind === "blob" ? digest.bytes : []), createHmac("sha256", key).update(token).digest());
        return {
          rows: [{
            principal_id: "11111111-1111-4111-8111-111111111111",
            canonical_principal_id: "prn_current_principal",
            family_id: "22222222-2222-4222-8222-222222222222",
            family_public_id: "fam_current_session",
            workspace_id: "33333333-3333-4333-8333-333333333333",
            workspace_slug: "current-room",
            workspace_display_name: "Current room",
            role: "viewer",
            authorization_version: 4,
            authentication_epoch: 2,
            authenticated_at: "2030-01-01T00:00:00.000Z",
            recent_authentication: false,
          }],
        };
      }
      if (input.sql.includes("read_workspace_authorization_state")) {
        const digest = input.parameters?.find((parameter) => parameter.name === "access_token_hash")?.value;
        assert.equal(digest?.kind, "blob");
        assert.deepEqual(Buffer.from(digest?.kind === "blob" ? digest.bytes : []), createHmac("sha256", key).update(token).digest());
        return {
          rows: [{
            principal_id: "11111111-1111-4111-8111-111111111111",
            principal_canonical_id: "prn_current_principal",
            family_id: "22222222-2222-4222-8222-222222222222",
            family_public_id: "fam_current_session",
            workspace_id: "33333333-3333-4333-8333-333333333333",
            workspace_slug: "current-room",
            workspace_display_name: "Current room",
            role: "viewer",
            authorization_version: 4,
            authentication_epoch: 2,
            authenticated_at: "2030-01-01T00:00:00.000Z",
            recent_authentication: false,
            professional_sign_in_global_enabled: false,
            professional_sign_in_global_version: 1,
            hosted_global_enabled: true,
            hosted_global_version: 5,
            hosted_workspace_enabled: true,
            hosted_workspace_version: 6,
            publication_global_enabled: false,
            publication_global_version: 7,
            publication_workspace_enabled: false,
            publication_workspace_version: 8,
            editor_publishing_allowed: false,
            editor_publishing_policy_version: 0,
          }],
        };
      }
      return { rows: [] };
    },
    commit: async () => { calls.push({ kind: "commit" }); },
    rollback: async () => { calls.push({ kind: "rollback" }); },
  };
  const port = new DataApiCapabilityOperationPort({
    client,
    accessTokenHmacKey: key,
    clock: { now: () => new Date("2030-01-01T00:01:00.000Z") },
  });

  const outcome = await port.run(
    { accessToken: token, authorization: { kind: "workspace", action: "workspace.read", resourceResolver: "none" } },
    async (context) => {
      const repositories = requireCapabilityRepositories(context.repositories, context.transactionMarker);
      assert.equal("execute" in (repositories as unknown as Record<string, unknown>), false);
      assert.equal("consumeAppleBridgeAndIssueSession" in (repositories.api as unknown as Record<string, unknown>), false);
      return context.principalPublicId;
    },
  );

  assert.equal(outcome, "prn_current_principal");
  assert.equal(calls.filter((call) => call.kind === "begin").length, 1);
  assert.equal(calls.filter((call) => call.kind === "commit").length, 1);
  assert.equal(calls.filter((call) => call.kind === "rollback").length, 0);
  const capabilityStatement = calls.find((call) => call.sql?.includes("read_workspace_authorization_state"))?.sql;
  assert.match(capabilityStatement ?? "", /\(:authoritative_now\)::timestamptz/u);
  assert.equal(calls.filter((call) => call.sql?.includes("read_workspace_authorization_state")).length, 1);
  assert.equal(calls.at(-1)?.kind, "commit");
});

test("capability operation port rejects removed membership, stale role, and a disable after resolver authorization", async (t) => {
  const scenarios: readonly {
    readonly name: string;
    readonly state: readonly Readonly<Record<string, SqlCell>>[];
  }[] = [
    { name: "removed membership", state: [] },
    { name: "stale role", state: [currentState({ role: "admin" })] },
    { name: "hosted global disabled after resolver", state: [currentState({ hosted_global_enabled: false })] },
    { name: "hosted workspace disabled after resolver", state: [currentState({ hosted_workspace_enabled: false })] },
  ];
  for (const scenario of scenarios) {
    await t.test(scenario.name, async () => {
      let handlerCalls = 0;
      const events: string[] = [];
      const client = authorizationClient(events, scenario.state);
      const port = new DataApiCapabilityOperationPort({
        client,
        accessTokenHmacKey: key,
        clock: { now: () => new Date("2030-01-01T00:01:00.000Z") },
      });
      await assert.rejects(
        port.run(
          { accessToken: token, authorization: { kind: "workspace", action: "workspace.read", resourceResolver: "none" } },
          async () => { handlerCalls += 1; },
        ),
        /operation_denied/u,
      );
      assert.equal(handlerCalls, 0);
      assert.equal(events.at(-1), "rollback");
      assert.equal(events.filter((event) => event === "read-current-state").length, 1);
    });
  }
});

test("capability operation port rejects stale recent-authentication requests before any capability SQL", async () => {
  const queries: string[] = [];
  const client: DataApiClient = {
    begin: async () => ({ transactionId: "capability-uow-2" }),
    execute: async (input) => {
      queries.push(input.sql);
      if (input.sql.includes("resolve_access_context")) {
        return { rows: [{
          principal_id: "11111111-1111-4111-8111-111111111111",
          canonical_principal_id: "prn_current_principal",
          family_id: "22222222-2222-4222-8222-222222222222",
          family_public_id: "fam_current_session",
          workspace_id: null,
          role: null,
          authorization_version: null,
          authentication_epoch: 2,
          authenticated_at: "2030-01-01T00:00:00.000Z",
          recent_authentication: false,
        }] };
      }
      return { rows: [] };
    },
    commit: async () => undefined,
    rollback: async () => undefined,
  };
  const port = new DataApiCapabilityOperationPort({ client, accessTokenHmacKey: key, clock: { now: () => new Date("2030-01-01T00:01:00.000Z") } });
  await assert.rejects(
    port.run({ accessToken: token, authorization: { kind: "session", requiresRecentAuthentication: true } }, async () => undefined),
    /operation_denied/u,
  );
  assert.equal(queries.some((query) => query.includes("roomscan.")), true);
  assert.equal(queries.some((query) => query.includes("read_workspace_authorization_state")), false);
});

function authorizationClient(
  events: string[],
  state: readonly Readonly<Record<string, SqlCell>>[],
): DataApiClient {
  return {
    begin: async () => { events.push("begin"); return { transactionId: "capability-uow-revalidation" }; },
    execute: async (input) => {
      if (input.sql.includes("resolve_access_context")) {
        events.push("resolve");
        return { rows: [resolvedAccess()] };
      }
      if (input.sql.includes("read_workspace_authorization_state")) {
        events.push("read-current-state");
        return { rows: state };
      }
      events.push("context");
      return { rows: [] };
    },
    commit: async () => { events.push("commit"); },
    rollback: async () => { events.push("rollback"); },
  };
}

function resolvedAccess(): Readonly<Record<string, SqlCell>> {
  return {
    principal_id: "11111111-1111-4111-8111-111111111111",
    canonical_principal_id: "prn_current_principal",
    family_id: "22222222-2222-4222-8222-222222222222",
    family_public_id: "fam_current_session",
    workspace_id: "33333333-3333-4333-8333-333333333333",
    workspace_slug: "current-room",
    workspace_display_name: "Current room",
    role: "viewer",
    authorization_version: 4,
    authentication_epoch: 2,
    authenticated_at: "2030-01-01T00:00:00.000Z",
    recent_authentication: false,
  };
}

function currentState(overrides: Readonly<Record<string, SqlCell>> = {}): Readonly<Record<string, SqlCell>> {
  return {
    principal_id: "11111111-1111-4111-8111-111111111111",
    principal_canonical_id: "prn_current_principal",
    family_id: "22222222-2222-4222-8222-222222222222",
    family_public_id: "fam_current_session",
    workspace_id: "33333333-3333-4333-8333-333333333333",
    workspace_slug: "current-room",
    workspace_display_name: "Current room",
    role: "viewer",
    authorization_version: 4,
    authentication_epoch: 2,
    authenticated_at: "2030-01-01T00:00:00.000Z",
    recent_authentication: false,
    professional_sign_in_global_enabled: false,
    professional_sign_in_global_version: 1,
    hosted_global_enabled: true,
    hosted_global_version: 5,
    hosted_workspace_enabled: true,
    hosted_workspace_version: 6,
    publication_global_enabled: false,
    publication_global_version: 7,
    publication_workspace_enabled: false,
    publication_workspace_version: 8,
    editor_publishing_allowed: false,
    editor_publishing_policy_version: 0,
    ...overrides,
  };
}
