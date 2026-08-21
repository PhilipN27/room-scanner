import {
  permissionFor,
  requiresResourceTenant,
  type AuthorizationAction,
  type WorkspaceRole,
} from "./policy.js";

export interface AuthenticatedWorkspaceSession {
  readonly state: "active" | "disabled";
  readonly principalId: string;
  readonly familyId: string;
  readonly workspaceId?: string;
  readonly role?: WorkspaceRole;
  readonly authorizationVersion?: number;
  readonly authenticatedAtMs: number;
}

export interface ActiveMembership {
  readonly state: "active" | "removed" | "suspended";
  readonly role: WorkspaceRole;
  readonly authorizationVersion: number;
}

export interface AuthorizationResourceReference {
  readonly kind: string;
  readonly id: string;
}

export interface AuthorizedWorkspaceContext {
  readonly principalId: string;
  readonly familyId: string;
  readonly workspaceId: string;
  readonly role: WorkspaceRole;
  readonly authorizationVersion: number;
}

export type AuthorizationErrorCode =
  | "unauthenticated"
  | "membership_inactive"
  | "stale_authorization"
  | "recent_auth_required"
  | "forbidden"
  | "operation_disabled";

export class AuthorizationError extends Error {
  constructor(readonly code: AuthorizationErrorCode) {
    super(code);
    this.name = "AuthorizationError";
  }
}

export interface CentralAuthorizationDependencies {
  readonly clock: { nowMs(): number };
  readonly recentAuthenticationMs: number;
  readonly sessions: {
    currentForAccessToken(accessToken: string): Promise<AuthenticatedWorkspaceSession | undefined>;
  };
  readonly memberships: {
    current(principalId: string, workspaceId: string): Promise<ActiveMembership | undefined>;
  };
  readonly resources: {
    workspaceFor(reference: AuthorizationResourceReference): Promise<string | undefined>;
  };
  readonly publishingPolicy: {
    editorPublishingAllowed(workspaceId: string): Promise<boolean | undefined>;
  };
  readonly actionGate: {
    assertActionAllowed(workspaceId: string, action: AuthorizationAction): Promise<void>;
  };
}

export class CentralAuthorizationService {
  constructor(private readonly dependencies: CentralAuthorizationDependencies) {}

  async authorize(input: {
    readonly accessToken: string;
    readonly action: AuthorizationAction;
    readonly resource?: AuthorizationResourceReference;
  }): Promise<AuthorizedWorkspaceContext> {
    if (typeof input.accessToken !== "string" || input.accessToken.length === 0) {
      throw new AuthorizationError("unauthenticated");
    }

    let session: AuthenticatedWorkspaceSession | undefined;
    try {
      session = await this.dependencies.sessions.currentForAccessToken(input.accessToken);
    } catch {
      throw new AuthorizationError("unauthenticated");
    }
    if (
      session === undefined ||
      session.state !== "active" ||
      !validIdentifier(session.principalId) ||
      !validIdentifier(session.familyId)
    ) {
      throw new AuthorizationError("unauthenticated");
    }
    if (
      !validIdentifier(session.workspaceId) ||
      session.role === undefined ||
      !validAuthorizationVersion(session.authorizationVersion)
    ) {
      throw new AuthorizationError("forbidden");
    }

    let membership: ActiveMembership | undefined;
    try {
      membership = await this.dependencies.memberships.current(
        session.principalId,
        session.workspaceId,
      );
    } catch {
      throw new AuthorizationError("membership_inactive");
    }
    if (membership === undefined || membership.state !== "active") {
      throw new AuthorizationError("membership_inactive");
    }
    if (
      membership.role !== session.role ||
      membership.authorizationVersion !== session.authorizationVersion
    ) {
      throw new AuthorizationError("stale_authorization");
    }

    const permission = permissionFor(membership.role, input.action);
    if (!permission.allowed) throw new AuthorizationError("forbidden");

    if (requiresResourceTenant(input.action) && input.resource === undefined) {
      throw new AuthorizationError("forbidden");
    }
    if (input.resource !== undefined) {
      if (!validIdentifier(input.resource.kind) || !validIdentifier(input.resource.id)) {
        throw new AuthorizationError("forbidden");
      }
      let resourceWorkspace: string | undefined;
      try {
        resourceWorkspace = await this.dependencies.resources.workspaceFor(input.resource);
      } catch {
        throw new AuthorizationError("forbidden");
      }
      if (resourceWorkspace !== session.workspaceId) {
        throw new AuthorizationError("forbidden");
      }
    }

    if (
      permission.requiresRecentAuthentication &&
      !isRecent(
        session.authenticatedAtMs,
        this.dependencies.clock.nowMs(),
        this.dependencies.recentAuthenticationMs,
      )
    ) {
      throw new AuthorizationError("recent_auth_required");
    }

    if (permission.requiresEditorPublishingAllowed) {
      let editorPublishingAllowed = false;
      try {
        editorPublishingAllowed =
          await this.dependencies.publishingPolicy.editorPublishingAllowed(
            session.workspaceId,
          ) === true;
      } catch {
        editorPublishingAllowed = false;
      }
      if (!editorPublishingAllowed) throw new AuthorizationError("forbidden");
    }

    try {
      await this.dependencies.actionGate.assertActionAllowed(session.workspaceId, input.action);
    } catch {
      throw new AuthorizationError("operation_disabled");
    }

    return {
      principalId: session.principalId,
      familyId: session.familyId,
      workspaceId: session.workspaceId,
      role: membership.role,
      authorizationVersion: membership.authorizationVersion,
    };
  }
}

function validIdentifier(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= 256;
}

function validAuthorizationVersion(value: unknown): value is number {
  return Number.isSafeInteger(value) && (value as number) > 0;
}

function isRecent(authenticatedAtMs: number, nowMs: number, maximumAgeMs: number): boolean {
  return (
    Number.isFinite(authenticatedAtMs) &&
    Number.isFinite(nowMs) &&
    Number.isFinite(maximumAgeMs) &&
    maximumAgeMs >= 0 &&
    authenticatedAtMs <= nowMs &&
    nowMs - authenticatedAtMs <= maximumAgeMs
  );
}
