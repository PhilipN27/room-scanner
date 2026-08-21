import assert from "node:assert/strict";
import test from "node:test";

import {
  MembershipError,
  MembershipService,
  type InvitationRecord,
  type MembershipAuditEvent,
  type MembershipRecord,
  type MembershipRepository,
  type MembershipTransaction,
} from "../src/membership/membership-service.js";
import {
  isHostedMutationAction,
  permissionFor,
  type AuthorizationAction,
  type WorkspaceRole,
} from "../src/authorization/policy.js";
import type {
  AuthorizedWorkspaceContext,
  AuthorizationResourceReference,
} from "../src/authorization/authorizer.js";
import type { HostedMutationGrant } from "../src/operations/operational-flags.js";

class SequenceRandom {
  private value = 1;

  bytes(length: number): Uint8Array {
    const bytes = new Uint8Array(length);
    bytes.fill(this.value++);
    return bytes;
  }
}

interface StoreSnapshot {
  readonly memberships: MembershipRecord[];
  readonly invitations: InvitationRecord[];
  readonly auditEvents: MembershipAuditEvent[];
  readonly invalidations: Array<{ principalId: string; workspaceId: string; reason: string }>;
  readonly memberSlots: string[];
}

interface MembershipGateState {
  enabled: boolean;
  globalVersion: number;
  workspaceVersion: number;
}

class MemoryMembershipStore implements MembershipRepository, MembershipTransaction {
  readonly memberships = new Map<string, MembershipRecord>();
  readonly invitations = new Map<string, InvitationRecord>();
  readonly auditEvents: MembershipAuditEvent[] = [];
  readonly invalidations: Array<{ principalId: string; workspaceId: string; reason: string }> = [];
  readonly memberSlots = new Set<string>();
  memberLimit = 100;
  gateState: MembershipGateState | undefined;
  failAudit = false;
  failInvalidation = false;
  beforeUpdate: (() => Promise<void>) | undefined;
  beforeTransaction: (() => void) | undefined;
  private tail: Promise<void> = Promise.resolve();

  key(workspaceId: string, principalId: string): string {
    return `${workspaceId}\u0000${principalId}`;
  }

  seedMembership(record: MembershipRecord): void {
    this.memberships.set(this.key(record.workspaceId, record.principalId), structuredClone(record));
    if (record.state === "active") this.memberSlots.add(this.key(record.workspaceId, record.principalId));
    else this.memberSlots.delete(this.key(record.workspaceId, record.principalId));
  }

  seedInvitation(record: InvitationRecord): void {
    this.invitations.set(record.id, structuredClone(record));
  }

  async transaction<T>(work: (transaction: MembershipTransaction) => Promise<T>): Promise<T> {
    let release!: () => void;
    const previous = this.tail;
    this.tail = new Promise<void>((resolve) => { release = resolve; });
    await previous;
    const snapshot = this.snapshot();
    try {
      if (this.beforeTransaction !== undefined) {
        const callback = this.beforeTransaction;
        this.beforeTransaction = undefined;
        callback();
      }
      return await work(this);
    } catch (error) {
      this.restore(snapshot);
      throw error;
    } finally {
      release();
    }
  }

  async currentMembership(workspaceId: string, principalId: string): Promise<MembershipRecord | undefined> {
    return clone(this.memberships.get(this.key(workspaceId, principalId)));
  }

  async confirmHostedMutation(grant: HostedMutationGrant): Promise<boolean> {
    const gate = this.gateState;
    return gate !== undefined && gate.enabled && grant.workspaceId === "workspace-a" &&
      isHostedMutationAction(grant.action) &&
      grant.hostedGlobalFlagVersion === gate.globalVersion &&
      grant.hostedWorkspaceFlagVersion === gate.workspaceVersion;
  }

  async acquireMemberSlot(workspaceId: string, principalId: string): Promise<"acquired" | "already_held" | "quota_exceeded"> {
    const key = this.key(workspaceId, principalId);
    if (this.memberSlots.has(key)) return "already_held";
    const used = [...this.memberSlots].filter((candidate) => candidate.startsWith(`${workspaceId}\u0000`)).length;
    if (used >= this.memberLimit) return "quota_exceeded";
    this.memberSlots.add(key);
    return "acquired";
  }

  async releaseMemberSlot(workspaceId: string, principalId: string): Promise<boolean> {
    return this.memberSlots.delete(this.key(workspaceId, principalId));
  }

  async currentInvitation(workspaceId: string, invitationId: string): Promise<InvitationRecord | undefined> {
    const invitation = this.invitations.get(invitationId);
    return invitation?.workspaceId === workspaceId ? structuredClone(invitation) : undefined;
  }

  async currentInvitationForTokenHash(tokenHash: string): Promise<InvitationRecord | undefined> {
    return clone([...this.invitations.values()].find((record) => record.tokenHash === tokenHash));
  }

  async insertInvitation(record: InvitationRecord): Promise<void> {
    if (
      this.invitations.has(record.id) ||
      [...this.invitations.values()].some((candidate) => candidate.tokenHash === record.tokenHash)
    ) {
      throw new Error("duplicate invitation");
    }
    this.invitations.set(record.id, structuredClone(record));
  }

  async consumeInvitationIfActive(
    invitationId: string,
    expectedVersion: number,
    principalId: string,
    consumedAtMs: number,
  ): Promise<boolean> {
    const invitation = this.invitations.get(invitationId);
    if (
      invitation === undefined ||
      invitation.state !== "active" ||
      invitation.version !== expectedVersion ||
      invitation.expiresAtMs <= consumedAtMs
    ) return false;
    this.invitations.set(invitationId, {
      ...invitation,
      state: "consumed",
      version: invitation.version + 1,
      consumedAtMs,
      consumedByPrincipalId: principalId,
    });
    return true;
  }

  async revokeInvitationIfActive(
    workspaceId: string,
    invitationId: string,
    expectedVersion: number,
    revokedAtMs: number,
  ): Promise<boolean> {
    const invitation = this.invitations.get(invitationId);
    if (
      invitation === undefined ||
      invitation.workspaceId !== workspaceId ||
      invitation.state !== "active" ||
      invitation.version !== expectedVersion
    ) return false;
    this.invitations.set(invitationId, {
      ...invitation,
      state: "revoked",
      version: invitation.version + 1,
      revokedAtMs,
    });
    return true;
  }

  async insertMembership(record: MembershipRecord): Promise<void> {
    const key = this.key(record.workspaceId, record.principalId);
    if (this.memberships.has(key)) throw new Error("duplicate membership");
    this.memberships.set(key, structuredClone(record));
  }

  async updateMembershipIfCurrent(input: {
    readonly workspaceId: string;
    readonly principalId: string;
    readonly expectedAuthorizationVersion: number;
    readonly expectedRole: WorkspaceRole;
    readonly expectedState: MembershipRecord["state"];
    readonly role: WorkspaceRole;
    readonly state: MembershipRecord["state"];
    readonly updatedAtMs: number;
  }): Promise<MembershipRecord | undefined> {
    if (this.beforeUpdate !== undefined) await this.beforeUpdate();
    const key = this.key(input.workspaceId, input.principalId);
    const existing = this.memberships.get(key);
    if (
      existing === undefined ||
      existing.authorizationVersion !== input.expectedAuthorizationVersion ||
      existing.role !== input.expectedRole ||
      existing.state !== input.expectedState
    ) return undefined;
    const updated: MembershipRecord = {
      ...existing,
      role: input.role,
      state: input.state,
      authorizationVersion: existing.authorizationVersion + 1,
      updatedAtMs: input.updatedAtMs,
    };
    this.memberships.set(key, updated);
    return structuredClone(updated);
  }

  async activeOwnerCount(workspaceId: string): Promise<number> {
    return [...this.memberships.values()].filter((record) =>
      record.workspaceId === workspaceId && record.state === "active" && record.role === "owner"
    ).length;
  }

  async revokeSessionFamiliesForMembership(
    principalId: string,
    workspaceId: string,
    reason: string,
  ): Promise<void> {
    if (this.failInvalidation) throw new Error("invalidation failure");
    this.invalidations.push({ principalId, workspaceId, reason });
  }

  async insertAuditEvent(event: MembershipAuditEvent): Promise<void> {
    if (this.failAudit) throw new Error("audit failure");
    this.auditEvents.push(structuredClone(event));
  }

  private snapshot(): StoreSnapshot {
    return {
      memberships: structuredClone([...this.memberships.values()]),
      invitations: structuredClone([...this.invitations.values()]),
      auditEvents: structuredClone(this.auditEvents),
      invalidations: structuredClone(this.invalidations),
      memberSlots: [...this.memberSlots],
    };
  }

  private restore(snapshot: StoreSnapshot): void {
    this.memberships.clear();
    for (const record of snapshot.memberships) this.seedMembership(record);
    this.invitations.clear();
    for (const record of snapshot.invitations) this.seedInvitation(record);
    this.auditEvents.splice(0, this.auditEvents.length, ...structuredClone(snapshot.auditEvents));
    this.invalidations.splice(0, this.invalidations.length, ...structuredClone(snapshot.invalidations));
    this.memberSlots.clear();
    for (const slot of snapshot.memberSlots) this.memberSlots.add(slot);
  }
}

class PolicyAuthorizer {
  readonly calls: Array<{ action: AuthorizationAction; resource?: AuthorizationResourceReference }> = [];
  readonly contexts = new Map<string, AuthorizedWorkspaceContext>();
  beforeAction: ((action: AuthorizationAction) => Promise<void>) | undefined;

  constructor() {
    this.contexts.set("owner-token", context("owner-a", "owner", 3));
    this.contexts.set("admin-token", context("admin-a", "admin", 2));
    this.contexts.set("viewer-token", context("viewer-a", "viewer", 1));
    this.contexts.set("owner-b-token", context("owner-b", "owner", 4));
  }

  async authorize(input: {
    readonly accessToken: string;
    readonly action: AuthorizationAction;
    readonly resource?: AuthorizationResourceReference;
  }): Promise<AuthorizedWorkspaceContext> {
    this.calls.push({ action: input.action, ...(input.resource === undefined ? {} : { resource: input.resource }) });
    if (this.beforeAction !== undefined) await this.beforeAction(input.action);
    const current = this.contexts.get(input.accessToken);
    if (current === undefined || !permissionFor(current.role, input.action).allowed) {
      throw new MembershipError("forbidden");
    }
    return structuredClone(current);
  }
}

function context(
  principalId: string,
  role: WorkspaceRole,
  authorizationVersion: number,
): AuthorizedWorkspaceContext {
  return {
    principalId,
    familyId: `family-${principalId}`,
    workspaceId: "workspace-a",
    role,
    authorizationVersion,
  };
}

function clone<T>(value: T | undefined): T | undefined {
  return value === undefined ? undefined : structuredClone(value);
}

function membership(
  principalId: string,
  role: WorkspaceRole,
  authorizationVersion: number,
  state: MembershipRecord["state"] = "active",
): MembershipRecord {
  return {
    workspaceId: "workspace-a",
    principalId,
    role,
    state,
    authorizationVersion,
    createdAtMs: 1,
    updatedAtMs: 1,
  };
}

function invitation(
  tokenHash: string,
  role: Exclude<WorkspaceRole, "owner"> = "editor",
): InvitationRecord {
  return {
    id: "invitation-1",
    workspaceId: "workspace-a",
    tokenHash,
    role,
    state: "active",
    version: 1,
    expiresAtMs: 20_000,
    createdByPrincipalId: "owner-a",
    createdAtMs: 1_000,
  };
}

function harness(): {
  readonly store: MemoryMembershipStore;
  readonly authorizer: PolicyAuthorizer;
  readonly service: MembershipService;
  readonly clock: { now: number };
  readonly gate: MembershipGateState;
  readonly gateCalls: string[];
} {
  const store = new MemoryMembershipStore();
  const authorizer = new PolicyAuthorizer();
  const clock = { now: 10_000 };
  const gate: MembershipGateState = { enabled: true, globalVersion: 1, workspaceVersion: 1 };
  const gateCalls: string[] = [];
  store.seedMembership(membership("owner-a", "owner", 3));
  store.seedMembership(membership("admin-a", "admin", 2));
  store.seedMembership(membership("viewer-a", "viewer", 1));
  store.seedMembership(membership("owner-b", "owner", 4));
  store.gateState = gate;
  const service = new MembershipService({
    clock: { nowMs: () => clock.now },
    random: new SequenceRandom(),
    repository: store,
    authorizer,
    principalSessions: {
      currentPrincipal: async (accessToken) => {
        if (accessToken === "accept-token") return { principalId: "candidate-a", familyId: "candidate-family" };
        if (accessToken === "removed-token") return { principalId: "removed-a", familyId: "removed-family" };
        if (accessToken === "accept-b-token") return { principalId: "candidate-b", familyId: "candidate-b-family" };
        if (accessToken === "viewer-reactivate") return { principalId: "viewer-a", familyId: "viewer-reactivate-family" };
        return undefined;
      },
    },
    hostedGate: {
      hostedMutationGrant: async (workspaceId, action) => {
        gateCalls.push(workspaceId);
        if (!gate.enabled) throw new Error("hosted disabled");
        return {
          kind: "hosted-mutation-grant-v2",
          workspaceId,
          action,
          hostedGlobalFlagVersion: gate.globalVersion,
          hostedWorkspaceFlagVersion: gate.workspaceVersion,
        } as const;
      },
    },
    invitationTokenHmacKey: new Uint8Array(32).fill(9),
    invitationTtlMs: 5_000,
  });
  return { store, authorizer, service, clock, gate, gateCalls };
}

test("invitation creation stores only a hash, derives the action from role, and revocation is atomic and audited", async () => {
  const { store, authorizer, service } = harness();
  const created = await service.invite({ accessToken: "owner-token", role: "admin" });
  assert.match(created.invitationToken, /^[A-Za-z0-9_-]+$/u);
  assert.equal(Buffer.from(created.invitationToken, "base64url").length, 32);
  const stored = store.invitations.get(created.invitationId);
  assert.ok(stored);
  assert.notEqual(stored.tokenHash, created.invitationToken);
  assert.equal(JSON.stringify(stored).includes(created.invitationToken), false);
  assert.deepEqual(authorizer.calls.map((call) => call.action), ["member.invite.admin"]);
  assert.equal(store.auditEvents.at(-1)?.eventCode, "membership.invited");

  await service.revokeInvitation({ accessToken: "owner-token", invitationId: created.invitationId });
  assert.equal(store.invitations.get(created.invitationId)?.state, "revoked");
  assert.equal(store.auditEvents.at(-1)?.eventCode, "membership.invitation_revoked");
});

test("invitation acceptance is single-use, caller-tenant-free, and reactivation bumps authorization and invalidates sessions", async () => {
  const { store, service, gateCalls } = harness();
  const created = await service.invite({ accessToken: "owner-token", role: "editor" });
  const accepted = await service.acceptInvitation({
    accessToken: "accept-token",
    invitationToken: created.invitationToken,
  });
  assert.deepEqual(accepted, {
    workspaceId: "workspace-a",
    role: "editor",
    authorizationVersion: 1,
  });
  assert.equal(store.invitations.get(created.invitationId)?.state, "consumed");
  assert.deepEqual(store.invalidations.at(-1), {
    principalId: "candidate-a",
    workspaceId: "workspace-a",
    reason: "membership_accepted",
  });
  assert.deepEqual(gateCalls, ["workspace-a", "workspace-a"]);
  await assert.rejects(
    service.acceptInvitation({ accessToken: "accept-token", invitationToken: created.invitationToken }),
    (error: unknown) => error instanceof MembershipError && error.code === "invitation_unavailable",
  );

  const reactivation = await service.invite({ accessToken: "owner-token", role: "viewer" });
  store.seedMembership(membership("removed-a", "editor", 9, "removed"));
  const reactivated = await service.acceptInvitation({
    accessToken: "removed-token",
    invitationToken: reactivation.invitationToken,
  });
  assert.deepEqual(reactivated, {
    workspaceId: "workspace-a",
    role: "viewer",
    authorizationVersion: 10,
  });
  assert.equal(store.currentMembership("workspace-a", "removed-a").then((record) => record?.state) instanceof Promise, true);
  assert.equal((await store.currentMembership("workspace-a", "removed-a"))?.state, "active");
});

test("concurrent invitation acceptance has one winner and an active member cannot burn the token", async () => {
  const { store, service } = harness();
  const created = await service.invite({ accessToken: "owner-token", role: "viewer" });
  const results = await Promise.allSettled([
    service.acceptInvitation({ accessToken: "accept-token", invitationToken: created.invitationToken }),
    service.acceptInvitation({ accessToken: "accept-token", invitationToken: created.invitationToken }),
  ]);
  assert.equal(results.filter((result) => result.status === "fulfilled").length, 1);
  assert.equal(results.filter((result) => result.status === "rejected").length, 1);

  const another = await service.invite({ accessToken: "owner-token", role: "viewer" });
  store.seedMembership(membership("candidate-a", "viewer", 3));
  await assert.rejects(
    service.acceptInvitation({ accessToken: "accept-token", invitationToken: another.invitationToken }),
    (error: unknown) => error instanceof MembershipError && error.code === "already_member",
  );
  assert.equal(store.invitations.get(another.invitationId)?.state, "active");
});

test("one remaining member slot admits one of two concurrent distinct invitation acceptances", async () => {
  const { store, service } = harness();
  store.memberLimit = store.memberSlots.size + 1;
  const first = await service.invite({ accessToken: "owner-token", role: "viewer" });
  const second = await service.invite({ accessToken: "owner-token", role: "viewer" });
  const results = await Promise.allSettled([
    service.acceptInvitation({ accessToken: "accept-token", invitationToken: first.invitationToken }),
    service.acceptInvitation({ accessToken: "accept-b-token", invitationToken: second.invitationToken }),
  ]);
  assert.equal(results.filter((result) => result.status === "fulfilled").length, 1);
  assert.equal(results.filter((result) => result.status === "rejected").length, 1);
  assert.equal(store.memberSlots.size, store.memberLimit);
  assert.equal([...store.invitations.values()].filter((record) => record.state === "consumed").length, 1);
});

test("member slots roll back, release on removal, and are reacquired on reactivation", async () => {
  const failed = harness();
  const created = await failed.service.invite({ accessToken: "owner-token", role: "viewer" });
  const before = failed.store.memberSlots.size;
  failed.store.failInvalidation = true;
  await assert.rejects(failed.service.acceptInvitation({ accessToken: "accept-token", invitationToken: created.invitationToken }), /invalidation failure/u);
  assert.equal(failed.store.memberSlots.size, before);
  assert.equal(failed.store.invitations.get(created.invitationId)?.state, "active");

  const lifecycle = harness();
  const beforeRemoval = lifecycle.store.memberSlots.size;
  await lifecycle.service.removeMember({ accessToken: "owner-token", targetPrincipalId: "viewer-a" });
  assert.equal(lifecycle.store.memberSlots.size, beforeRemoval - 1);
  const reactivation = await lifecycle.service.invite({ accessToken: "owner-token", role: "viewer" });
  const reactivated = await lifecycle.service.acceptInvitation({
    accessToken: "viewer-reactivate",
    invitationToken: reactivation.invitationToken,
  });
  assert.equal(reactivated.authorizationVersion, 3);
  assert.equal(lifecycle.store.memberSlots.size, beforeRemoval);
  assert.equal(lifecycle.store.memberSlots.has(lifecycle.store.key("workspace-a", "viewer-a")), true);
});

test("persistence rejects hosted disable after preflight without consuming an invitation or member slot", async () => {
  const { gate, store, service } = harness();
  const created = await service.invite({ accessToken: "owner-token", role: "viewer" });
  const before = store.memberSlots.size;
  store.beforeTransaction = () => {
    gate.enabled = false;
    gate.workspaceVersion += 1;
  };
  await assert.rejects(
    service.acceptInvitation({ accessToken: "accept-token", invitationToken: created.invitationToken }),
    (error: unknown) => error instanceof MembershipError && error.code === "forbidden",
  );
  assert.equal(store.invitations.get(created.invitationId)?.state, "active");
  assert.equal(store.memberSlots.size, before);
});

test("expired invitations and hosted rollback deny acceptance without consuming the token", async () => {
  const expired = harness();
  const created = await expired.service.invite({ accessToken: "owner-token", role: "viewer" });
  expired.clock.now = created.expiresAtMs;
  await assert.rejects(
    expired.service.acceptInvitation({ accessToken: "accept-token", invitationToken: created.invitationToken }),
    (error: unknown) => error instanceof MembershipError && error.code === "invitation_unavailable",
  );
  assert.equal(expired.store.invitations.get(created.invitationId)?.state, "active");
  assert.equal(await expired.store.currentMembership("workspace-a", "candidate-a"), undefined);

  const frozen = harness();
  const frozenInvitation = await frozen.service.invite({ accessToken: "owner-token", role: "viewer" });
  frozen.gate.enabled = false;
  await assert.rejects(
    frozen.service.acceptInvitation({ accessToken: "accept-token", invitationToken: frozenInvitation.invitationToken }),
    (error: unknown) => error instanceof MembershipError && error.code === "forbidden",
  );
  assert.equal(frozen.store.invitations.get(frozenInvitation.invitationId)?.state, "active");
  assert.equal(await frozen.store.currentMembership("workspace-a", "candidate-a"), undefined);
});

test("Admin can manage Viewer/Editor only while Owner paths cover Admin and Owner", async () => {
  const { store, service } = harness();
  store.seedMembership(membership("editor-a", "editor", 5));

  const changed = await service.changeRole({
    accessToken: "admin-token",
    targetPrincipalId: "viewer-a",
    role: "editor",
  });
  assert.equal(changed.role, "editor");
  assert.equal(changed.authorizationVersion, 2);

  await service.removeMember({ accessToken: "admin-token", targetPrincipalId: "editor-a" });
  assert.equal((await store.currentMembership("workspace-a", "editor-a"))?.state, "removed");

  await assert.rejects(
    service.changeRole({ accessToken: "admin-token", targetPrincipalId: "viewer-a", role: "admin" }),
    (error: unknown) => error instanceof MembershipError && error.code === "forbidden",
  );
  await assert.rejects(
    service.removeMember({ accessToken: "admin-token", targetPrincipalId: "owner-b" }),
    (error: unknown) => error instanceof MembershipError && error.code === "forbidden",
  );

  const promoted = await service.changeRole({
    accessToken: "owner-token",
    targetPrincipalId: "viewer-a",
    role: "admin",
  });
  assert.equal(promoted.role, "admin");
});

test("concurrent Owner removals preserve one active Owner", async () => {
  const { store, service } = harness();
  store.memberships.delete(store.key("workspace-a", "admin-a"));
  store.memberships.delete(store.key("workspace-a", "viewer-a"));
  store.memberSlots.delete(store.key("workspace-a", "admin-a"));
  store.memberSlots.delete(store.key("workspace-a", "viewer-a"));
  const results = await Promise.allSettled([
    service.removeMember({ accessToken: "owner-token", targetPrincipalId: "owner-a" }),
    service.removeMember({ accessToken: "owner-b-token", targetPrincipalId: "owner-b" }),
  ]);
  assert.equal(results.filter((result) => result.status === "fulfilled").length, 1);
  assert.equal(results.filter((result) => result.status === "rejected").length, 1);
  assert.equal(await store.activeOwnerCount("workspace-a"), 1);
  assert.equal(store.memberSlots.size, 1, "last-owner rejection cannot release the remaining owner slot");
  const rejection = results.find((result): result is PromiseRejectedResult => result.status === "rejected");
  assert.ok(rejection?.reason instanceof MembershipError);
  assert.equal(rejection.reason.code, "last_owner");
});

test("stale actor/target snapshots fail before mutation and every success bumps version, invalidates sessions, and audits", async (t) => {
  await t.test("stale actor", async () => {
    const { store, service } = harness();
    store.seedMembership(membership("owner-a", "owner", 4));
    await assert.rejects(
      service.changeRole({ accessToken: "owner-token", targetPrincipalId: "viewer-a", role: "editor" }),
      (error: unknown) => error instanceof MembershipError && error.code === "stale_authorization",
    );
    assert.equal((await store.currentMembership("workspace-a", "viewer-a"))?.role, "viewer");
  });

  await t.test("stale target", async () => {
    const { store, authorizer, service } = harness();
    let changed = false;
    authorizer.beforeAction = async (action) => {
      if (action === "member.change.viewer" && !changed) {
        changed = true;
        store.seedMembership(membership("viewer-a", "viewer", 2));
      }
    };
    await assert.rejects(
      service.changeRole({ accessToken: "owner-token", targetPrincipalId: "viewer-a", role: "editor" }),
      (error: unknown) => error instanceof MembershipError && error.code === "stale_membership",
    );
  });

  await t.test("success side effects", async () => {
    const { store, service } = harness();
    const updated = await service.changeRole({
      accessToken: "owner-token",
      targetPrincipalId: "viewer-a",
      role: "editor",
    });
    assert.equal(updated.authorizationVersion, 2);
    assert.deepEqual(store.invalidations, [{
      principalId: "viewer-a",
      workspaceId: "workspace-a",
      reason: "membership_role_changed",
    }]);
    assert.equal(store.auditEvents.at(-1)?.eventCode, "membership.role_changed");
  });
});

test("audit or session-invalidation failure rolls back membership and invitation changes", async (t) => {
  await t.test("membership audit rollback", async () => {
    const { store, service } = harness();
    store.failAudit = true;
    await assert.rejects(
      service.changeRole({ accessToken: "owner-token", targetPrincipalId: "viewer-a", role: "editor" }),
      /audit failure/u,
    );
    assert.deepEqual(await store.currentMembership("workspace-a", "viewer-a"), membership("viewer-a", "viewer", 1));
    assert.deepEqual(store.invalidations, []);
  });

  await t.test("accept invalidation rollback", async () => {
    const { store, service } = harness();
    const created = await service.invite({ accessToken: "owner-token", role: "viewer" });
    store.failInvalidation = true;
    await assert.rejects(
      service.acceptInvitation({ accessToken: "accept-token", invitationToken: created.invitationToken }),
      /invalidation failure/u,
    );
    assert.equal(store.invitations.get(created.invitationId)?.state, "active");
    assert.equal(await store.currentMembership("workspace-a", "candidate-a"), undefined);
  });
});

test("membership service awaits an asynchronous storage CAS before resolving", async () => {
  const { store, service } = harness();
  let release!: () => void;
  const gate = new Promise<void>((resolve) => { release = resolve; });
  store.beforeUpdate = async () => gate;
  let settled = false;
  const promise = service.changeRole({
    accessToken: "owner-token",
    targetPrincipalId: "viewer-a",
    role: "editor",
  }).finally(() => { settled = true; });
  await new Promise<void>((resolve) => setImmediate(resolve));
  assert.equal(settled, false);
  release();
  await promise;
  assert.equal(settled, true);
});
