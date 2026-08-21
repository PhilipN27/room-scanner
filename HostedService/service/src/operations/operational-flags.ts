import {
  AUTHORIZATION_ACTIONS,
  isHostedMutationAction,
  isPublicationAction,
  type AuthorizationAction,
} from "../authorization/policy.js";

export const OPERATIONAL_FLAGS = [
  "professional_sign_in_enabled",
  "hosted_operations_enabled",
  "publication_enabled",
] as const;

export type OperationalFlagName = (typeof OPERATIONAL_FLAGS)[number];

export type OperationalFlagScope =
  | { readonly kind: "global" }
  | { readonly kind: "workspace"; readonly workspaceId: string };

export interface OperationalFlagValue {
  readonly enabled: boolean;
  readonly version: number;
}

export interface OperationalFlagPort {
  read(flag: OperationalFlagName, scope: OperationalFlagScope): Promise<OperationalFlagValue | undefined>;
}

/**
 * A version-bound grant is a precondition, not an authorization decision. The
 * persistence adapter must compare the action and all required hosted and
 * publication versions/enabled values atomically with the mutation.
 */
export interface HostedMutationGrant {
  readonly kind: "hosted-mutation-grant-v2";
  readonly workspaceId: string;
  readonly action: AuthorizationAction;
  readonly hostedGlobalFlagVersion: number;
  readonly hostedWorkspaceFlagVersion: number;
  readonly publicationGlobalFlagVersion?: number;
  readonly publicationWorkspaceFlagVersion?: number;
}

export type OperationalFlagErrorCode =
  | "professional_sign_in_disabled"
  | "hosted_operations_disabled"
  | "publication_disabled"
  | "unknown_action";

export class OperationalFlagError extends Error {
  constructor(readonly code: OperationalFlagErrorCode) {
    super(code);
    this.name = "OperationalFlagError";
  }
}

const GLOBAL_SCOPE = Object.freeze({ kind: "global" } as const);

/**
 * Central fail-closed resolver. Workspace capabilities require an explicit true
 * at both global and tenant scope so either scope can revoke independently.
 */
export class OperationalFlagService {
  constructor(private readonly flags: OperationalFlagPort) {}

  async professionalSignInEnabled(): Promise<boolean> {
    return this.explicitlyEnabled("professional_sign_in_enabled", GLOBAL_SCOPE);
  }

  async hostedOperationsEnabled(workspaceId: string): Promise<boolean> {
    return this.workspaceFlagEnabled("hosted_operations_enabled", workspaceId);
  }

  async publicationEnabled(workspaceId: string): Promise<boolean> {
    return this.workspaceFlagEnabled("publication_enabled", workspaceId);
  }

  async assertProfessionalSignInEnabled(): Promise<void> {
    if (!await this.professionalSignInEnabled()) {
      throw new OperationalFlagError("professional_sign_in_disabled");
    }
  }

  async assertHostedMutationAllowed(workspaceId: string, action: AuthorizationAction): Promise<void> {
    await this.hostedMutationGrant(workspaceId, action);
  }

  async hostedMutationGrant(workspaceId: string, action: AuthorizationAction): Promise<HostedMutationGrant> {
    if (!validWorkspaceId(workspaceId) || !grantableHostedAction(action)) {
      throw new OperationalFlagError("hosted_operations_disabled");
    }
    const [hostedGlobal, hostedWorkspace] = await Promise.all([
      this.safelyRead("hosted_operations_enabled", GLOBAL_SCOPE),
      this.safelyRead("hosted_operations_enabled", { kind: "workspace", workspaceId }),
    ]);
    if (!explicitlyEnabledVersion(hostedGlobal) || !explicitlyEnabledVersion(hostedWorkspace)) {
      throw new OperationalFlagError("hosted_operations_disabled");
    }
    const base = {
      kind: "hosted-mutation-grant-v2" as const,
      workspaceId,
      action,
      hostedGlobalFlagVersion: hostedGlobal.version,
      hostedWorkspaceFlagVersion: hostedWorkspace.version,
    };
    if (!isPublicationAction(action)) return base;
    const [publicationGlobal, publicationWorkspace] = await Promise.all([
      this.safelyRead("publication_enabled", GLOBAL_SCOPE),
      this.safelyRead("publication_enabled", { kind: "workspace", workspaceId }),
    ]);
    if (!explicitlyEnabledVersion(publicationGlobal) || !explicitlyEnabledVersion(publicationWorkspace)) {
      throw new OperationalFlagError("publication_disabled");
    }
    return {
      ...base,
      publicationGlobalFlagVersion: publicationGlobal.version,
      publicationWorkspaceFlagVersion: publicationWorkspace.version,
    };
  }

  async assertProtectedPublicationAssetAllowed(workspaceId: string): Promise<void> {
    if (!await this.publicationEnabled(workspaceId)) {
      throw new OperationalFlagError("publication_disabled");
    }
  }

  async assertActionAllowed(workspaceId: string, action: AuthorizationAction): Promise<void> {
    if (!AUTHORIZATION_ACTIONS.includes(action)) {
      throw new OperationalFlagError("unknown_action");
    }
    if (isHostedMutationAction(action)) {
      await this.assertHostedMutationAllowed(workspaceId, action);
    } else if (isPublicationAction(action)) {
      await this.assertProtectedPublicationAssetAllowed(workspaceId);
    }
  }

  private async workspaceFlagEnabled(flag: OperationalFlagName, workspaceId: string): Promise<boolean> {
    if (!validWorkspaceId(workspaceId)) return false;
    if (!await this.explicitlyEnabled(flag, GLOBAL_SCOPE)) return false;
    return this.explicitlyEnabled(flag, { kind: "workspace", workspaceId });
  }

  private async explicitlyEnabled(flag: OperationalFlagName, scope: OperationalFlagScope): Promise<boolean> {
    return explicitlyEnabledVersion(await this.safelyRead(flag, scope));
  }

  private async safelyRead(
    flag: OperationalFlagName,
    scope: OperationalFlagScope,
  ): Promise<OperationalFlagValue | undefined> {
    try {
      return await this.flags.read(flag, scope);
    } catch {
      return undefined;
    }
  }
}

export interface ProfessionalSessionIssuerPort<Request, Session> {
  issue(request: Request): Promise<Session>;
}

/** The only professional-session issuance adapter exposed by this slice. */
export class FlagGatedProfessionalSessionIssuer<Request, Session>
implements ProfessionalSessionIssuerPort<Request, Session> {
  constructor(private readonly dependencies: {
    readonly operationalFlags: Pick<OperationalFlagService, "assertProfessionalSignInEnabled">;
    readonly sessions: ProfessionalSessionIssuerPort<Request, Session>;
  }) {}

  async issue(request: Request): Promise<Session> {
    await this.dependencies.operationalFlags.assertProfessionalSignInEnabled();
    return this.dependencies.sessions.issue(request);
  }
}

function validWorkspaceId(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= 256;
}

function explicitlyEnabledVersion(value: OperationalFlagValue | undefined): value is OperationalFlagValue {
  return value?.enabled === true && Number.isSafeInteger(value.version) && value.version > 0;
}

function grantableHostedAction(action: unknown): action is AuthorizationAction {
  return isHostedMutationAction(action) ||
    action === "system.quota_policy.change" ||
    action === "system.stripe.reconcile";
}
