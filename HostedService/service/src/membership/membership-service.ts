import { createHmac } from "node:crypto";

import type { AuthorizationAction, WorkspaceRole } from "../authorization/policy.js";
import type {
  AuthorizedWorkspaceContext,
  AuthorizationResourceReference,
} from "../authorization/authorizer.js";
import type { HostedMutationGrant } from "../operations/operational-flags.js";

export interface MembershipRecord {
  readonly workspaceId: string;
  readonly principalId: string;
  readonly role: WorkspaceRole;
  readonly state: "invited" | "active" | "removed";
  readonly authorizationVersion: number;
  readonly createdAtMs: number;
  readonly updatedAtMs: number;
}

export interface InvitationRecord {
  readonly id: string;
  readonly workspaceId: string;
  readonly tokenHash: string;
  readonly role: Exclude<WorkspaceRole, "owner">;
  readonly state: "active" | "consumed" | "revoked";
  readonly version: number;
  readonly expiresAtMs: number;
  readonly createdByPrincipalId: string;
  readonly createdAtMs: number;
  readonly consumedAtMs?: number;
  readonly consumedByPrincipalId?: string;
  readonly revokedAtMs?: number;
}

export interface MembershipAuditEvent {
  readonly id: string;
  readonly workspaceId: string;
  readonly actorPrincipalId: string;
  readonly eventCode:
    | "membership.invited"
    | "membership.invitation_revoked"
    | "membership.invitation_accepted"
    | "membership.role_changed"
    | "membership.removed";
  readonly subjectId: string;
  readonly authorizationVersion?: number;
  readonly createdAtMs: number;
}

export interface MembershipTransaction {
  /** Compare action and all required flag versions/enabled state in this transaction. */
  confirmHostedMutation(grant: HostedMutationGrant): Promise<boolean>;
  currentMembership(workspaceId: string, principalId: string): Promise<MembershipRecord | undefined>;
  currentInvitation(workspaceId: string, invitationId: string): Promise<InvitationRecord | undefined>;
  insertInvitation(record: InvitationRecord): Promise<void>;
  consumeInvitationIfActive(
    invitationId: string,
    expectedVersion: number,
    principalId: string,
    consumedAtMs: number,
  ): Promise<boolean>;
  revokeInvitationIfActive(
    workspaceId: string,
    invitationId: string,
    expectedVersion: number,
    revokedAtMs: number,
  ): Promise<boolean>;
  insertMembership(record: MembershipRecord): Promise<void>;
  updateMembershipIfCurrent(input: {
    readonly workspaceId: string;
    readonly principalId: string;
    readonly expectedAuthorizationVersion: number;
    readonly expectedRole: WorkspaceRole;
    readonly expectedState: MembershipRecord["state"];
    readonly role: WorkspaceRole;
    readonly state: MembershipRecord["state"];
    readonly updatedAtMs: number;
  }): Promise<MembershipRecord | undefined>;
  activeOwnerCount(workspaceId: string): Promise<number>;
  acquireMemberSlot(
    workspaceId: string,
    principalId: string,
  ): Promise<"acquired" | "already_held" | "quota_exceeded">;
  releaseMemberSlot(workspaceId: string, principalId: string): Promise<boolean>;
  revokeSessionFamiliesForMembership(
    principalId: string,
    workspaceId: string,
    reason: string,
  ): Promise<void>;
  insertAuditEvent(event: MembershipAuditEvent): Promise<void>;
}

export interface MembershipRepository {
  transaction<T>(work: (transaction: MembershipTransaction) => Promise<T>): Promise<T>;
  currentMembership(workspaceId: string, principalId: string): Promise<MembershipRecord | undefined>;
  currentInvitation(workspaceId: string, invitationId: string): Promise<InvitationRecord | undefined>;
  currentInvitationForTokenHash(tokenHash: string): Promise<InvitationRecord | undefined>;
}

export interface MembershipAuthorizer {
  authorize(input: {
    readonly accessToken: string;
    readonly action: AuthorizationAction;
    readonly resource?: AuthorizationResourceReference;
  }): Promise<AuthorizedWorkspaceContext>;
}

export type MembershipErrorCode =
  | "forbidden"
  | "invalid_request"
  | "invitation_unavailable"
  | "already_member"
  | "membership_not_found"
  | "stale_authorization"
  | "stale_membership"
  | "last_owner"
  | "quota_exceeded"
  | "persistence_invariant";

export class MembershipError extends Error {
  constructor(readonly code: MembershipErrorCode) {
    super(code);
    this.name = "MembershipError";
  }
}

export interface MembershipServiceDependencies {
  readonly clock: { nowMs(): number };
  readonly random: { bytes(length: number): Uint8Array };
  readonly repository: MembershipRepository;
  readonly authorizer: MembershipAuthorizer;
  readonly principalSessions: {
    currentPrincipal(accessToken: string): Promise<{
      readonly principalId: string;
      readonly familyId: string;
    } | undefined>;
  };
  readonly hostedGate: {
    hostedMutationGrant(workspaceId: string, action: AuthorizationAction): Promise<HostedMutationGrant>;
  };
  readonly invitationTokenHmacKey: Uint8Array;
  readonly invitationTtlMs: number;
}

export class MembershipService {
  constructor(private readonly dependencies: MembershipServiceDependencies) {}

  async invite(input: {
    readonly accessToken: string;
    readonly role: Exclude<WorkspaceRole, "owner">;
  }): Promise<{ readonly invitationId: string; readonly invitationToken: string; readonly expiresAtMs: number }> {
    if (!isInvitableRole(input.role)) throw new MembershipError("invalid_request");
    const action = inviteAction(input.role);
    const context = await this.dependencies.authorizer.authorize({
      accessToken: input.accessToken,
      action,
    });
    const nowMs = this.dependencies.clock.nowMs();
    if (
      !Number.isFinite(nowMs) ||
      !Number.isSafeInteger(this.dependencies.invitationTtlMs) ||
      this.dependencies.invitationTtlMs <= 0 ||
      this.dependencies.invitationTokenHmacKey.byteLength < 32
    ) {
      throw new MembershipError("invalid_request");
    }
    const invitationToken = randomSecret(this.dependencies.random, 32);
    const invitationId = `inv_${randomSecret(this.dependencies.random, 16)}`;
    const expiresAtMs = nowMs + this.dependencies.invitationTtlMs;
    const grant = await this.#hostedMutationGrant(context.workspaceId, action);
    await this.dependencies.repository.transaction(async (transaction) => {
      await confirmHostedMutation(transaction, grant);
      await requireCurrentActor(transaction, context);
      await transaction.insertInvitation({
        id: invitationId,
        workspaceId: context.workspaceId,
        tokenHash: invitationDigest(
          this.dependencies.invitationTokenHmacKey,
          invitationToken,
        ),
        role: input.role,
        state: "active",
        version: 1,
        expiresAtMs,
        createdByPrincipalId: context.principalId,
        createdAtMs: nowMs,
      });
      await transaction.insertAuditEvent({
        id: `aud_${randomSecret(this.dependencies.random, 16)}`,
        workspaceId: context.workspaceId,
        actorPrincipalId: context.principalId,
        eventCode: "membership.invited",
        subjectId: invitationId,
        createdAtMs: nowMs,
      });
    });
    return { invitationId, invitationToken, expiresAtMs };
  }

  async revokeInvitation(input: {
    readonly accessToken: string;
    readonly invitationId: string;
  }): Promise<void> {
    if (!validIdentifier(input.invitationId)) throw new MembershipError("invalid_request");
    const scope = await this.dependencies.authorizer.authorize({
      accessToken: input.accessToken,
      action: "member.read",
      resource: { kind: "invitation", id: input.invitationId },
    });
    const snapshot = await this.dependencies.repository.currentInvitation(
      scope.workspaceId,
      input.invitationId,
    );
    if (snapshot === undefined || snapshot.state !== "active") {
      throw new MembershipError("invitation_unavailable");
    }
    const action = revokeInvitationAction(snapshot.role);
    const context = await this.dependencies.authorizer.authorize({
      accessToken: input.accessToken,
      action,
    });
    const nowMs = this.dependencies.clock.nowMs();
    const grant = await this.#hostedMutationGrant(context.workspaceId, action);
    await this.dependencies.repository.transaction(async (transaction) => {
      await confirmHostedMutation(transaction, grant);
      await requireCurrentActor(transaction, context);
      const current = await transaction.currentInvitation(
        context.workspaceId,
        input.invitationId,
      );
      if (
        current === undefined ||
        current.state !== "active" ||
        current.version !== snapshot.version ||
        current.role !== snapshot.role ||
        !await transaction.revokeInvitationIfActive(
          context.workspaceId,
          current.id,
          current.version,
          nowMs,
        )
      ) {
        throw new MembershipError("invitation_unavailable");
      }
      await transaction.insertAuditEvent({
        id: `aud_${randomSecret(this.dependencies.random, 16)}`,
        workspaceId: context.workspaceId,
        actorPrincipalId: context.principalId,
        eventCode: "membership.invitation_revoked",
        subjectId: current.id,
        createdAtMs: nowMs,
      });
    });
  }

  async acceptInvitation(input: {
    readonly accessToken: string;
    readonly invitationToken: string;
  }): Promise<{
    readonly workspaceId: string;
    readonly role: WorkspaceRole;
    readonly authorizationVersion: number;
  }> {
    if (!isOpaqueSecret(input.invitationToken)) {
      throw new MembershipError("invitation_unavailable");
    }
    let principal: { readonly principalId: string; readonly familyId: string } | undefined;
    try {
      principal = await this.dependencies.principalSessions.currentPrincipal(input.accessToken);
    } catch {
      principal = undefined;
    }
    if (
      principal === undefined ||
      !validIdentifier(principal.principalId) ||
      !validIdentifier(principal.familyId)
    ) {
      throw new MembershipError("forbidden");
    }
    const tokenHash = invitationDigest(
      this.dependencies.invitationTokenHmacKey,
      input.invitationToken,
    );
    const snapshot = await this.dependencies.repository.currentInvitationForTokenHash(tokenHash);
    if (snapshot === undefined || snapshot.state !== "active") {
      throw new MembershipError("invitation_unavailable");
    }
    const grant = await this.#hostedMutationGrant(snapshot.workspaceId, inviteAction(snapshot.role));
    const nowMs = this.dependencies.clock.nowMs();
    return this.dependencies.repository.transaction(async (transaction) => {
      await confirmHostedMutation(transaction, grant);
      const currentInvitation = await transaction.currentInvitation(
        snapshot.workspaceId,
        snapshot.id,
      );
      if (
        currentInvitation === undefined ||
        currentInvitation.state !== "active" ||
        currentInvitation.tokenHash !== tokenHash ||
        currentInvitation.version !== snapshot.version ||
        currentInvitation.expiresAtMs <= nowMs
      ) {
        throw new MembershipError("invitation_unavailable");
      }
      const existing = await transaction.currentMembership(
        currentInvitation.workspaceId,
        principal.principalId,
      );
      if (existing?.state === "active") throw new MembershipError("already_member");

      const slot = await transaction.acquireMemberSlot(
        currentInvitation.workspaceId,
        principal.principalId,
      );
      if (slot === "quota_exceeded") throw new MembershipError("quota_exceeded");
      if (slot !== "acquired") throw new MembershipError("persistence_invariant");

      let acceptedMembership: MembershipRecord;
      if (existing === undefined) {
        acceptedMembership = {
          workspaceId: currentInvitation.workspaceId,
          principalId: principal.principalId,
          role: currentInvitation.role,
          state: "active",
          authorizationVersion: 1,
          createdAtMs: nowMs,
          updatedAtMs: nowMs,
        };
        await transaction.insertMembership(acceptedMembership);
      } else {
        const updated = await transaction.updateMembershipIfCurrent({
          workspaceId: existing.workspaceId,
          principalId: existing.principalId,
          expectedAuthorizationVersion: existing.authorizationVersion,
          expectedRole: existing.role,
          expectedState: existing.state,
          role: currentInvitation.role,
          state: "active",
          updatedAtMs: nowMs,
        });
        if (updated === undefined) throw new MembershipError("stale_membership");
        acceptedMembership = updated;
      }

      if (!await transaction.consumeInvitationIfActive(
        currentInvitation.id,
        currentInvitation.version,
        principal.principalId,
        nowMs,
      )) {
        throw new MembershipError("invitation_unavailable");
      }
      await transaction.revokeSessionFamiliesForMembership(
        principal.principalId,
        currentInvitation.workspaceId,
        "membership_accepted",
      );
      await transaction.insertAuditEvent({
        id: `aud_${randomSecret(this.dependencies.random, 16)}`,
        workspaceId: currentInvitation.workspaceId,
        actorPrincipalId: principal.principalId,
        eventCode: "membership.invitation_accepted",
        subjectId: principal.principalId,
        authorizationVersion: acceptedMembership.authorizationVersion,
        createdAtMs: nowMs,
      });
      return {
        workspaceId: acceptedMembership.workspaceId,
        role: acceptedMembership.role,
        authorizationVersion: acceptedMembership.authorizationVersion,
      };
    });
  }

  async changeRole(input: {
    readonly accessToken: string;
    readonly targetPrincipalId: string;
    readonly role: WorkspaceRole;
  }): Promise<MembershipRecord> {
    if (!validIdentifier(input.targetPrincipalId) || !isRole(input.role)) {
      throw new MembershipError("invalid_request");
    }
    const { context, target } = await this.#preflightTarget(
      input.accessToken,
      input.targetPrincipalId,
    );
    if (target.role === input.role) throw new MembershipError("invalid_request");
    const action = changeAction(target.role, input.role);
    const authorized = await this.dependencies.authorizer.authorize({
      accessToken: input.accessToken,
      action,
    });
    return this.#mutateMembership({
      context: authorized,
      action,
      targetSnapshot: target,
      role: input.role,
      state: "active",
      eventCode: "membership.role_changed",
      invalidationReason: "membership_role_changed",
    });
  }

  async removeMember(input: {
    readonly accessToken: string;
    readonly targetPrincipalId: string;
  }): Promise<MembershipRecord> {
    if (!validIdentifier(input.targetPrincipalId)) throw new MembershipError("invalid_request");
    const { target } = await this.#preflightTarget(input.accessToken, input.targetPrincipalId);
    const action = removeAction(target.role);
    const context = await this.dependencies.authorizer.authorize({
      accessToken: input.accessToken,
      action,
    });
    return this.#mutateMembership({
      context,
      action,
      targetSnapshot: target,
      role: target.role,
      state: "removed",
      eventCode: "membership.removed",
      invalidationReason: "membership_removed",
    });
  }

  async #preflightTarget(
    accessToken: string,
    targetPrincipalId: string,
  ): Promise<{ readonly context: AuthorizedWorkspaceContext; readonly target: MembershipRecord }> {
    const context = await this.dependencies.authorizer.authorize({
      accessToken,
      action: "member.read",
      resource: { kind: "member", id: targetPrincipalId },
    });
    const target = await this.dependencies.repository.currentMembership(
      context.workspaceId,
      targetPrincipalId,
    );
    if (target === undefined || target.state !== "active") {
      throw new MembershipError("membership_not_found");
    }
    return { context, target };
  }

  async #mutateMembership(input: {
    readonly context: AuthorizedWorkspaceContext;
    readonly action: AuthorizationAction;
    readonly targetSnapshot: MembershipRecord;
    readonly role: WorkspaceRole;
    readonly state: MembershipRecord["state"];
    readonly eventCode: "membership.role_changed" | "membership.removed";
    readonly invalidationReason: string;
  }): Promise<MembershipRecord> {
    const nowMs = this.dependencies.clock.nowMs();
    const grant = await this.#hostedMutationGrant(input.context.workspaceId, input.action);
    return this.dependencies.repository.transaction(async (transaction) => {
      await confirmHostedMutation(transaction, grant);
      await requireCurrentActor(transaction, input.context);
      const currentTarget = await transaction.currentMembership(
        input.context.workspaceId,
        input.targetSnapshot.principalId,
      );
      if (
        currentTarget === undefined ||
        currentTarget.state !== input.targetSnapshot.state ||
        currentTarget.role !== input.targetSnapshot.role ||
        currentTarget.authorizationVersion !== input.targetSnapshot.authorizationVersion
      ) {
        throw new MembershipError("stale_membership");
      }
      if (
        currentTarget.state === "active" &&
        currentTarget.role === "owner" &&
        (input.state !== "active" || input.role !== "owner") &&
        await transaction.activeOwnerCount(input.context.workspaceId) <= 1
      ) {
        throw new MembershipError("last_owner");
      }
      const updated = await transaction.updateMembershipIfCurrent({
        workspaceId: currentTarget.workspaceId,
        principalId: currentTarget.principalId,
        expectedAuthorizationVersion: currentTarget.authorizationVersion,
        expectedRole: currentTarget.role,
        expectedState: currentTarget.state,
        role: input.role,
        state: input.state,
        updatedAtMs: nowMs,
      });
      if (updated === undefined) throw new MembershipError("stale_membership");
      if (
        input.state === "removed" &&
        !await transaction.releaseMemberSlot(updated.workspaceId, updated.principalId)
      ) {
        throw new MembershipError("persistence_invariant");
      }
      await transaction.revokeSessionFamiliesForMembership(
        updated.principalId,
        updated.workspaceId,
        input.invalidationReason,
      );
      await transaction.insertAuditEvent({
        id: `aud_${randomSecret(this.dependencies.random, 16)}`,
        workspaceId: updated.workspaceId,
        actorPrincipalId: input.context.principalId,
        eventCode: input.eventCode,
        subjectId: updated.principalId,
        authorizationVersion: updated.authorizationVersion,
        createdAtMs: nowMs,
      });
      return updated;
    });
  }

  async #hostedMutationGrant(workspaceId: string, action: AuthorizationAction): Promise<HostedMutationGrant> {
    try {
      const grant = await this.dependencies.hostedGate.hostedMutationGrant(workspaceId, action);
      if (
        grant.kind !== "hosted-mutation-grant-v2" ||
        grant.workspaceId !== workspaceId ||
        grant.action !== action ||
        !Number.isSafeInteger(grant.hostedGlobalFlagVersion) ||
        grant.hostedGlobalFlagVersion <= 0 ||
        !Number.isSafeInteger(grant.hostedWorkspaceFlagVersion) ||
        grant.hostedWorkspaceFlagVersion <= 0
      ) throw new Error("invalid hosted grant");
      return grant;
    } catch {
      throw new MembershipError("forbidden");
    }
  }
}

async function confirmHostedMutation(
  transaction: MembershipTransaction,
  grant: HostedMutationGrant,
): Promise<void> {
  if (!await transaction.confirmHostedMutation(grant)) throw new MembershipError("forbidden");
}

async function requireCurrentActor(
  transaction: MembershipTransaction,
  context: AuthorizedWorkspaceContext,
): Promise<void> {
  const actor = await transaction.currentMembership(context.workspaceId, context.principalId);
  if (
    actor === undefined ||
    actor.state !== "active" ||
    actor.role !== context.role ||
    actor.authorizationVersion !== context.authorizationVersion
  ) {
    throw new MembershipError("stale_authorization");
  }
}

function inviteAction(role: Exclude<WorkspaceRole, "owner">): AuthorizationAction {
  if (role === "admin") return "member.invite.admin";
  return role === "editor" ? "member.invite.editor" : "member.invite.viewer";
}

function revokeInvitationAction(role: Exclude<WorkspaceRole, "owner">): AuthorizationAction {
  if (role === "admin") return "member.remove.admin";
  return role === "editor" ? "member.revoke.editor" : "member.revoke.viewer";
}

function changeAction(currentRole: WorkspaceRole, nextRole: WorkspaceRole): AuthorizationAction {
  const controllingRole = roleRank(currentRole) >= roleRank(nextRole) ? currentRole : nextRole;
  if (controllingRole === "owner") return "member.change.owner";
  if (controllingRole === "admin") return "member.change.admin";
  return currentRole === "editor" ? "member.change.editor" : "member.change.viewer";
}

function removeAction(role: WorkspaceRole): AuthorizationAction {
  if (role === "owner") return "member.remove.owner";
  if (role === "admin") return "member.remove.admin";
  if (role === "editor") return "member.remove.editor";
  return "member.remove.viewer";
}

function roleRank(role: WorkspaceRole): number {
  if (role === "owner") return 4;
  if (role === "admin") return 3;
  if (role === "editor") return 2;
  return 1;
}

function isInvitableRole(value: unknown): value is Exclude<WorkspaceRole, "owner"> {
  return value === "admin" || value === "editor" || value === "viewer";
}

function isRole(value: unknown): value is WorkspaceRole {
  return value === "owner" || isInvitableRole(value);
}

function validIdentifier(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= 256;
}

function randomSecret(random: { bytes(length: number): Uint8Array }, length: number): string {
  const bytes = random.bytes(length);
  if (bytes.byteLength !== length) throw new MembershipError("invalid_request");
  return Buffer.from(bytes).toString("base64url");
}

function isOpaqueSecret(value: string): boolean {
  return /^[A-Za-z0-9_-]+$/u.test(value) && Buffer.from(value, "base64url").byteLength === 32;
}

function invitationDigest(key: Uint8Array, token: string): string {
  return createHmac("sha256", key).update(`membership-invitation:${token}`).digest("base64url");
}
