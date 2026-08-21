import assert from "node:assert/strict";
import test from "node:test";

import {
  AUTHORIZATION_ACTIONS,
  RESOURCE_SCOPED_ACTIONS,
  ROLE_ACTION_MATRIX,
  SYSTEM_ONLY_ACTIONS,
  permissionFor,
  type AuthorizationAction,
  type WorkspaceRole,
} from "../src/authorization/policy.js";
import {
  CentralAuthorizationService,
  AuthorizationError,
  type ActiveMembership,
  type AuthenticatedWorkspaceSession,
  type AuthorizationResourceReference,
} from "../src/authorization/authorizer.js";

const roles = ["owner", "admin", "editor", "viewer"] as const;

const expectedActions = [
  "workspace.read",
  "member.read",
  "project.read",
  "private.download",
  "quota.warning.read",
  "workspace.profile.update",
  "security.read",
  "access_history.read",
  "audit.read",
  "audit.export",
  "workspace.security.change",
  "ownership.transfer",
  "workspace.permanent_delete",
  "member.invite.viewer",
  "member.revoke.viewer",
  "member.change.viewer",
  "member.remove.viewer",
  "member.invite.editor",
  "member.revoke.editor",
  "member.change.editor",
  "member.remove.editor",
  "member.invite.admin",
  "member.change.admin",
  "member.remove.admin",
  "member.add.owner",
  "member.change.owner",
  "member.remove.owner",
  "subscription.read",
  "usage.read",
  "limit.read",
  "subscription.manage",
  "billing.manage",
  "project.create",
  "project.revise",
  "concept.import",
  "concept.edit",
  "concept.archive",
  "comment.create",
  "concept.approve",
  "project.archive",
  "project.restore",
  "project.permanent_delete",
  "raw_archive.configure",
  "raw_archive.allocate",
  "publication.record.read",
  "publication.policy.change",
  "publication.create",
  "publication.update",
  "publication.revoke",
  "system.quota_policy.change",
  "system.stripe.reconcile",
  "system.audit.write",
  "system.break_glass",
  "system.kill_switch.mutate",
] as const satisfies readonly AuthorizationAction[];

type ExpectedCell = "deny" | "allow" | "recent" | "recent+editor-publishing";

const expectedRows = new Map<AuthorizationAction, readonly [ExpectedCell, ExpectedCell, ExpectedCell, ExpectedCell]>();

function expectRows(
  actions: readonly AuthorizationAction[],
  row: readonly [ExpectedCell, ExpectedCell, ExpectedCell, ExpectedCell],
): void {
  for (const action of actions) expectedRows.set(action, row);
}

expectRows(
  ["workspace.read", "member.read", "project.read", "private.download", "quota.warning.read"],
  ["allow", "allow", "allow", "allow"],
);
expectRows(
  ["workspace.profile.update", "security.read", "access_history.read", "audit.read"],
  ["allow", "allow", "deny", "deny"],
);
expectRows(
  ["audit.export", "workspace.security.change", "ownership.transfer", "workspace.permanent_delete"],
  ["recent", "deny", "deny", "deny"],
);
expectRows(
  [
    "member.invite.viewer",
    "member.revoke.viewer",
    "member.change.viewer",
    "member.remove.viewer",
    "member.invite.editor",
    "member.revoke.editor",
    "member.change.editor",
    "member.remove.editor",
  ],
  ["recent", "recent", "deny", "deny"],
);
expectRows(
  ["member.invite.admin", "member.change.admin", "member.remove.admin"],
  ["recent", "deny", "deny", "deny"],
);
expectRows(
  ["member.add.owner", "member.change.owner", "member.remove.owner"],
  ["recent", "deny", "deny", "deny"],
);
expectRows(
  ["subscription.read", "usage.read", "limit.read"],
  ["allow", "allow", "deny", "deny"],
);
expectRows(
  ["subscription.manage", "billing.manage"],
  ["recent", "deny", "deny", "deny"],
);
expectRows(
  [
    "project.create",
    "project.revise",
    "concept.import",
    "concept.edit",
    "concept.archive",
    "comment.create",
    "concept.approve",
  ],
  ["allow", "allow", "allow", "deny"],
);
expectRows(
  ["project.archive", "project.restore"],
  ["allow", "allow", "deny", "deny"],
);
expectRows(
  ["project.permanent_delete", "raw_archive.configure"],
  ["recent", "deny", "deny", "deny"],
);
expectRows(
  ["raw_archive.allocate"],
  ["allow", "allow", "allow", "deny"],
);
expectRows(
  ["publication.record.read"],
  ["allow", "allow", "allow", "allow"],
);
expectRows(
  ["publication.policy.change"],
  ["recent", "recent", "deny", "deny"],
);
expectRows(
  ["publication.create", "publication.update", "publication.revoke"],
  ["recent", "recent", "recent+editor-publishing", "deny"],
);
expectRows(
  [
    "system.quota_policy.change",
    "system.stripe.reconcile",
    "system.audit.write",
    "system.break_glass",
    "system.kill_switch.mutate",
  ],
  ["deny", "deny", "deny", "deny"],
);

test("the role/action matrix is exhaustive, literal, and has no default allow", () => {
  assert.deepEqual([...AUTHORIZATION_ACTIONS].sort(), [...expectedActions].sort());
  assert.equal(expectedRows.size, expectedActions.length);

  for (const action of expectedActions) {
    const expected = expectedRows.get(action);
    assert.ok(expected, `missing independent expectation for ${action}`);
    for (const [roleIndex, role] of roles.entries()) {
      const actual = ROLE_ACTION_MATRIX[action][role];
      const expectedCell: ExpectedCell | undefined = expected[roleIndex];
      assert.notEqual(expectedCell, undefined);
      assert.deepEqual(actual, {
        allowed: expectedCell !== "deny",
        requiresRecentAuthentication:
          expectedCell === "recent" || expectedCell === "recent+editor-publishing",
        requiresEditorPublishingAllowed: expectedCell === "recent+editor-publishing",
      }, `${action} × ${role}`);
    }
  }

  for (const action of SYSTEM_ONLY_ACTIONS) {
    for (const role of roles) assert.equal(permissionFor(role, action).allowed, false);
  }
  assert.equal(permissionFor("owner", "unknown.action").allowed, false);
  assert.equal(permissionFor("root", "workspace.read").allowed, false);

  assert.deepEqual([...RESOURCE_SCOPED_ACTIONS].sort(), [
    "member.read",
    "project.read",
    "private.download",
    "project.revise",
    "concept.import",
    "concept.edit",
    "concept.archive",
    "comment.create",
    "concept.approve",
    "project.archive",
    "project.restore",
    "project.permanent_delete",
    "raw_archive.configure",
    "raw_archive.allocate",
    "publication.record.read",
    "publication.policy.change",
    "publication.create",
    "publication.update",
    "publication.revoke",
  ].sort());
});

class MutableAuthorizationState {
  nowMs = 10_000;
  session: AuthenticatedWorkspaceSession | undefined = {
    state: "active",
    principalId: "principal-a",
    familyId: "family-a",
    workspaceId: "workspace-a",
    role: "owner",
    authorizationVersion: 7,
    authenticatedAtMs: 9_000,
  };
  membership: ActiveMembership | undefined = {
    state: "active",
    role: "owner",
    authorizationVersion: 7,
  };
  resourceWorkspace = "workspace-a";
  editorPublishingAllowed = true;
  actionGateAllowed = true;
  readonly sessionCalls: string[] = [];
  readonly resourceCalls: AuthorizationResourceReference[] = [];

  service(): CentralAuthorizationService {
    return new CentralAuthorizationService({
      clock: { nowMs: () => this.nowMs },
      recentAuthenticationMs: 5_000,
      sessions: {
        currentForAccessToken: async (accessToken) => {
          this.sessionCalls.push(accessToken);
          return this.session === undefined ? undefined : structuredClone(this.session);
        },
      },
      memberships: {
        current: async () => this.membership === undefined
          ? undefined
          : structuredClone(this.membership),
      },
      resources: {
        workspaceFor: async (reference) => {
          this.resourceCalls.push(reference);
          return this.resourceWorkspace;
        },
      },
      publishingPolicy: {
        editorPublishingAllowed: async () => this.editorPublishingAllowed,
      },
      actionGate: {
        assertActionAllowed: async () => {
          if (!this.actionGateAllowed) throw new Error("gate denied");
        },
      },
    });
  }
}

const projectResource = {
  kind: "project",
  id: "project-1",
} as const;

test("central authorization derives workspace from the active session, rereads membership, and pairs every cross-tenant denial with success", async () => {
  for (const action of AUTHORIZATION_ACTIONS) {
    for (const role of roles) {
      const permission = permissionFor(role, action);
      if (!permission.allowed) continue;

      const state = new MutableAuthorizationState();
      state.session = { ...state.session!, role };
      state.membership = { ...state.membership!, role };
      state.editorPublishingAllowed = true;
      state.resourceWorkspace = "workspace-b";
      const service = state.service();
      await assert.rejects(
        service.authorize({
          accessToken: "opaque-access-token",
          action,
          resource: projectResource,
        }),
        (error: unknown) => error instanceof AuthorizationError && error.code === "forbidden",
        `${action} × ${role} cross-tenant denial`,
      );

      state.resourceWorkspace = "workspace-a";
      const context = await service.authorize({
        accessToken: "opaque-access-token",
        action,
        resource: projectResource,
      });
      assert.deepEqual(context, {
        principalId: "principal-a",
        familyId: "family-a",
        workspaceId: "workspace-a",
        role,
        authorizationVersion: 7,
      }, `${action} × ${role} same-tenant positive control`);
    }
  }
});

test("removed membership, stale cached role/version, disabled session, and forged active-workspace substitution fail closed", async (t) => {
  await t.test("removed membership", async () => {
    const state = new MutableAuthorizationState();
    state.membership = { ...state.membership!, state: "removed" };
    await assert.rejects(
      state.service().authorize({ accessToken: "token", action: "workspace.read" }),
      (error: unknown) => error instanceof AuthorizationError && error.code === "membership_inactive",
    );
  });

  await t.test("stale role", async () => {
    const state = new MutableAuthorizationState();
    state.membership = { ...state.membership!, role: "admin" };
    await assert.rejects(
      state.service().authorize({ accessToken: "token", action: "workspace.read" }),
      (error: unknown) => error instanceof AuthorizationError && error.code === "stale_authorization",
    );
  });

  await t.test("stale authorization version", async () => {
    const state = new MutableAuthorizationState();
    state.membership = { ...state.membership!, authorizationVersion: 8 };
    await assert.rejects(
      state.service().authorize({ accessToken: "token", action: "workspace.read" }),
      (error: unknown) => error instanceof AuthorizationError && error.code === "stale_authorization",
    );
  });

  await t.test("disabled session", async () => {
    const state = new MutableAuthorizationState();
    state.session = { ...state.session!, state: "disabled" };
    await assert.rejects(
      state.service().authorize({ accessToken: "token", action: "workspace.read" }),
      (error: unknown) => error instanceof AuthorizationError && error.code === "unauthenticated",
    );
  });

  await t.test("forged workspace field cannot replace server-owned scope", async () => {
    const state = new MutableAuthorizationState();
    state.resourceWorkspace = "workspace-b";
    const forged = {
      accessToken: "opaque-access-token",
      action: "project.read",
      resource: projectResource,
      workspaceId: "workspace-b",
    } as const;
    await assert.rejects(
      state.service().authorize(forged),
      (error: unknown) => error instanceof AuthorizationError && error.code === "forbidden",
    );
    assert.deepEqual(state.sessionCalls, ["opaque-access-token"]);

    state.resourceWorkspace = "workspace-a";
    const context = await state.service().authorize(forged);
    assert.equal(context.workspaceId, "workspace-a");
  });
});

test("recent-auth and Editor publishing conditions use only server-owned state", async (t) => {
  await t.test("R rejects stale server authentication and accepts the exact boundary", async () => {
    const state = new MutableAuthorizationState();
    state.session = { ...state.session!, authenticatedAtMs: 4_999 };
    await assert.rejects(
      state.service().authorize({ accessToken: "token", action: "billing.manage" }),
      (error: unknown) => error instanceof AuthorizationError && error.code === "recent_auth_required",
    );
    state.session = { ...state.session, authenticatedAtMs: 5_000 };
    await state.service().authorize({ accessToken: "token", action: "billing.manage" });
  });

  await t.test("C requires explicit current editorPublishingAllowed", async () => {
    const state = new MutableAuthorizationState();
    state.session = { ...state.session!, role: "editor" };
    state.membership = { ...state.membership!, role: "editor" };
    state.editorPublishingAllowed = false;
    await assert.rejects(
      state.service().authorize({
        accessToken: "token",
        action: "publication.create",
        resource: projectResource,
        editorPublishingAllowed: true,
      } as Parameters<CentralAuthorizationService["authorize"]>[0]),
      (error: unknown) => error instanceof AuthorizationError && error.code === "forbidden",
    );
    state.editorPublishingAllowed = true;
    await state.service().authorize({
      accessToken: "token",
      action: "publication.create",
      resource: projectResource,
    });
  });
});

test("unknown runtime actions, absent required resources, and unavailable policy/gate state never allow", async () => {
  const state = new MutableAuthorizationState();
  await assert.rejects(
    state.service().authorize({ accessToken: "token", action: "unknown.action" as AuthorizationAction }),
    (error: unknown) => error instanceof AuthorizationError && error.code === "forbidden",
  );
  await assert.rejects(
    state.service().authorize({ accessToken: "token", action: "project.read" }),
    (error: unknown) => error instanceof AuthorizationError && error.code === "forbidden",
  );

  const unavailablePublishingPolicy = new CentralAuthorizationService({
    clock: { nowMs: () => state.nowMs },
    recentAuthenticationMs: 5_000,
    sessions: { currentForAccessToken: async () => state.session },
    memberships: { current: async () => ({ ...state.membership!, role: "editor" }) },
    resources: { workspaceFor: async () => "workspace-a" },
    publishingPolicy: { editorPublishingAllowed: async () => { throw new Error("unavailable"); } },
    actionGate: { assertActionAllowed: async () => undefined },
  });
  state.session = { ...state.session!, role: "editor" };
  await assert.rejects(
    unavailablePublishingPolicy.authorize({
      accessToken: "token",
      action: "publication.create",
      resource: projectResource,
    }),
    (error: unknown) => error instanceof AuthorizationError && error.code === "forbidden",
  );

  state.session = { ...state.session, role: "owner" };
  state.actionGateAllowed = false;
  await assert.rejects(
    state.service().authorize({ accessToken: "token", action: "project.create" }),
    (error: unknown) => error instanceof AuthorizationError && error.code === "operation_disabled",
  );
});
