import assert from "node:assert/strict";
import test from "node:test";

import {
  AUTHORIZATION_ACTIONS,
  HOSTED_MUTATION_ACTIONS,
  PUBLICATION_ACTIONS,
  type AuthorizationAction,
} from "../src/authorization/policy.js";
import {
  OPERATIONAL_FLAGS,
  FlagGatedProfessionalSessionIssuer,
  OperationalFlagError,
  OperationalFlagService,
  type OperationalFlagName,
  type OperationalFlagPort,
  type OperationalFlagScope,
} from "../src/operations/operational-flags.js";

class MemoryOperationalFlags implements OperationalFlagPort {
  readonly values = new Map<string, { enabled: boolean; version: number }>();
  readonly unavailable = new Set<string>();
  readonly calls: Array<{ flag: OperationalFlagName; scope: OperationalFlagScope }> = [];

  key(flag: OperationalFlagName, scope: OperationalFlagScope): string {
    return scope.kind === "global" ? `${flag}:global` : `${flag}:workspace:${scope.workspaceId}`;
  }

  set(flag: OperationalFlagName, scope: OperationalFlagScope, value: boolean): void {
    const key = this.key(flag, scope);
    this.values.set(key, {
      enabled: value,
      version: (this.values.get(key)?.version ?? 0) + 1,
    });
  }

  async read(flag: OperationalFlagName, scope: OperationalFlagScope) {
    this.calls.push({ flag, scope: structuredClone(scope) });
    const key = this.key(flag, scope);
    if (this.unavailable.has(key)) throw new Error("flag store unavailable");
    return this.values.get(key);
  }
}

const globalScope = { kind: "global" } as const;
const workspaceScope = { kind: "workspace", workspaceId: "workspace-a" } as const;

const expectedHostedMutationActions = [
  "workspace.profile.update",
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
  "publication.policy.change",
  "publication.create",
  "publication.update",
  "publication.revoke",
] as const satisfies readonly AuthorizationAction[];

const expectedPublicationActions = [
  "publication.record.read",
  "publication.policy.change",
  "publication.create",
  "publication.update",
  "publication.revoke",
] as const satisfies readonly AuthorizationAction[];

function enabledHarness() {
  const flags = new MemoryOperationalFlags();
  for (const flag of OPERATIONAL_FLAGS) {
    flags.set(flag, globalScope, true);
    if (flag !== "professional_sign_in_enabled") flags.set(flag, workspaceScope, true);
  }
  return { flags, service: new OperationalFlagService(flags) };
}

async function rejectsFlag(
  operation: () => Promise<unknown>,
  code: OperationalFlagError["code"],
): Promise<void> {
  await assert.rejects(operation, (error: unknown) =>
    error instanceof OperationalFlagError && error.code === code);
}

test("the three central operational flags are exact and missing, false, or unavailable values fail closed", async () => {
  assert.deepEqual(OPERATIONAL_FLAGS, [
    "professional_sign_in_enabled",
    "hosted_operations_enabled",
    "publication_enabled",
  ]);

  for (const flag of OPERATIONAL_FLAGS) {
    const store = new MemoryOperationalFlags();
    const service = new OperationalFlagService(store);
    const read = flag === "professional_sign_in_enabled"
      ? () => service.professionalSignInEnabled()
      : flag === "hosted_operations_enabled"
        ? () => service.hostedOperationsEnabled("workspace-a")
        : () => service.publicationEnabled("workspace-a");
    assert.equal(await read(), false, `${flag} missing`);
    store.set(flag, globalScope, true);
    if (flag !== "professional_sign_in_enabled") {
      assert.equal(await read(), false, `${flag} workspace scope missing`);
      store.set(flag, workspaceScope, true);
    }
    assert.equal(await read(), true, `${flag} explicitly enabled`);
    store.unavailable.add(store.key(flag, globalScope));
    assert.equal(await read(), false, `${flag} unavailable`);
  }
});

test("mutation grants bind their action plus hosted and required publication versions", async () => {
  const { flags, service } = enabledHarness();
  const grant = await service.hostedMutationGrant("workspace-a", "publication.create");
  assert.deepEqual(grant, {
    kind: "hosted-mutation-grant-v2",
    workspaceId: "workspace-a",
    action: "publication.create",
    hostedGlobalFlagVersion: 1,
    hostedWorkspaceFlagVersion: 1,
    publicationGlobalFlagVersion: 1,
    publicationWorkspaceFlagVersion: 1,
  });

  flags.set("publication_enabled", workspaceScope, false);
  flags.set("publication_enabled", workspaceScope, true);
  const replacement = await service.hostedMutationGrant("workspace-a", "publication.create");
  assert.notEqual(replacement.publicationWorkspaceFlagVersion, grant.publicationWorkspaceFlagVersion);

  const nonPublication = await service.hostedMutationGrant("workspace-a", "project.create");
  assert.equal(nonPublication.action, "project.create");
  assert.equal("publicationGlobalFlagVersion" in nonPublication, false);
});

test("hosted rollback denies every hosted mutation/allocation while reads and neutral local work remain independent", async () => {
  const { flags, service } = enabledHarness();
  assert.deepEqual([...HOSTED_MUTATION_ACTIONS].sort(), [...expectedHostedMutationActions].sort());
  flags.set("hosted_operations_enabled", globalScope, false);
  let neutralLocalCalls = 0;
  const neutralLocalContract = async () => {
    neutralLocalCalls += 1;
    return Uint8Array.from([0x52, 0x53]);
  };
  const callsBeforeLocal = flags.calls.length;
  assert.deepEqual(await neutralLocalContract(), Uint8Array.from([0x52, 0x53]));
  assert.equal(neutralLocalCalls, 1);
  assert.equal(flags.calls.length, callsBeforeLocal, "neutral local contract has no hosted flag dependency");

  for (const action of expectedHostedMutationActions) {
    await rejectsFlag(
      () => service.assertActionAllowed("workspace-a", action),
      "hosted_operations_disabled",
    );
  }
  await rejectsFlag(
    () => service.assertHostedMutationAllowed("workspace-a", "project.create"),
    "hosted_operations_disabled",
  );

  const neutralReads = AUTHORIZATION_ACTIONS.filter((action) =>
    !expectedHostedMutationActions.includes(action as (typeof expectedHostedMutationActions)[number]) &&
    !expectedPublicationActions.includes(action as (typeof expectedPublicationActions)[number]));
  for (const action of neutralReads) {
    await service.assertActionAllowed("workspace-a", action);
  }
});

test("publication rollback denies every reserved publication action and protected asset grant", async () => {
  const { flags, service } = enabledHarness();
  assert.deepEqual([...PUBLICATION_ACTIONS].sort(), [...expectedPublicationActions].sort());
  flags.set("publication_enabled", workspaceScope, false);
  for (const action of expectedPublicationActions) {
    await rejectsFlag(
      () => service.assertActionAllowed("workspace-a", action),
      "publication_disabled",
    );
  }
  await rejectsFlag(
    () => service.assertProtectedPublicationAssetAllowed("workspace-a"),
    "publication_disabled",
  );

  flags.set("publication_enabled", workspaceScope, true);
  for (const action of expectedPublicationActions) {
    await service.assertActionAllowed("workspace-a", action);
  }
  await service.assertProtectedPublicationAssetAllowed("workspace-a");
});

test("publication reads need the publication flag but remain available during a hosted mutation freeze", async () => {
  const { flags, service } = enabledHarness();
  flags.set("hosted_operations_enabled", workspaceScope, false);
  await service.assertActionAllowed("workspace-a", "publication.record.read");
  await rejectsFlag(
    () => service.assertActionAllowed("workspace-a", "publication.create"),
    "hosted_operations_disabled",
  );
});

test("professional sign-in is checked before session issuance and cannot fall through on unavailable state", async () => {
  const flags = new MemoryOperationalFlags();
  const operational = new OperationalFlagService(flags);
  const issuanceCalls: Array<{ principalId: string }> = [];
  const issuer = new FlagGatedProfessionalSessionIssuer({
    operationalFlags: operational,
    sessions: {
      issue: async (request: { readonly principalId: string }) => {
        issuanceCalls.push(request);
        return { accessToken: "access", refreshToken: "refresh" };
      },
    },
  });

  await rejectsFlag(
    () => issuer.issue({ principalId: "principal-a" }),
    "professional_sign_in_disabled",
  );
  assert.equal(issuanceCalls.length, 0);
  flags.set("professional_sign_in_enabled", globalScope, true);
  assert.deepEqual(await issuer.issue({ principalId: "principal-a" }), {
    accessToken: "access",
    refreshToken: "refresh",
  });
  assert.equal(issuanceCalls.length, 1);
  flags.unavailable.add(flags.key("professional_sign_in_enabled", globalScope));
  await rejectsFlag(
    () => issuer.issue({ principalId: "principal-a" }),
    "professional_sign_in_disabled",
  );
  assert.equal(issuanceCalls.length, 1);
});

test("unknown actions do not pass the operational gate through a default-allow path", async () => {
  const { service } = enabledHarness();
  await rejectsFlag(
    () => service.assertActionAllowed("workspace-a", "unknown.action" as AuthorizationAction),
    "unknown_action",
  );
});
