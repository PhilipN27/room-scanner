import { createHmac } from "node:crypto";

export interface Clock {
  nowMs(): number;
}

export interface RandomSource {
  bytes(length: number): Uint8Array;
}

export type WorkspaceRole = "owner" | "admin" | "editor" | "viewer";

export interface SessionPolicy {
  readonly version: string;
  readonly accessTtlMs: number;
  readonly refreshInactivityMs: number;
  readonly refreshAbsoluteMs: number;
  readonly recentAuthenticationMs: number;
}

export const DEFAULT_SESSION_POLICY: SessionPolicy = {
  version: "session-v1",
  accessTtlMs: 5 * 60_000,
  refreshInactivityMs: 7 * 24 * 60 * 60_000,
  refreshAbsoluteMs: 30 * 24 * 60 * 60_000,
  recentAuthenticationMs: 5 * 60_000,
};

export interface MembershipSnapshot {
  readonly state: "active" | "removed" | "suspended";
  readonly role: WorkspaceRole;
  readonly authorizationVersion: number;
}

export interface MembershipAuthorizationPort {
  current(principalId: string, workspaceId: string): Promise<MembershipSnapshot | undefined>;
}

export interface SessionFamilyRecord {
  readonly id: string;
  readonly principalId: string;
  readonly authenticationEpoch: number;
  readonly authenticatedAtMs: number;
  readonly createdAtMs: number;
  lastUsedAtMs: number;
  inactivityExpiresAtMs: number;
  readonly absoluteExpiresAtMs: number;
  readonly policyVersion: string;
  readonly workspaceId?: string;
  readonly role?: WorkspaceRole;
  readonly authorizationVersion?: number;
  state: "active" | "revoked";
  revokedAtMs?: number;
  revocationReason?: string;
}

export interface AccessTokenRecord {
  readonly tokenHash: string;
  readonly familyId: string;
  readonly principalId: string;
  readonly authenticationEpoch: number;
  readonly authenticatedAtMs: number;
  readonly issuedAtMs: number;
  readonly expiresAtMs: number;
  readonly workspaceId?: string;
  readonly role?: WorkspaceRole;
  readonly authorizationVersion?: number;
  state: "active" | "revoked";
  revokedAtMs?: number;
}

export interface RefreshTokenRecord {
  readonly tokenHash: string;
  readonly familyId: string;
  readonly issuedAtMs: number;
  state: "active" | "rotated";
  childTokenHash?: string;
  rotatedAtMs?: number;
}

export interface SessionTransaction {
  principalAuthenticationEpoch(principalId: string): Promise<number | undefined>;
  incrementPrincipalAuthenticationEpoch(principalId: string): Promise<number>;
  insertFamily(family: SessionFamilyRecord): Promise<void>;
  findFamily(familyId: string): Promise<SessionFamilyRecord | undefined>;
  revokeFamily(familyId: string, revokedAtMs: number, reason: string): Promise<void>;
  revokeFamiliesForPrincipal(principalId: string, revokedAtMs: number, reason: string): Promise<void>;
  insertAccessToken(record: AccessTokenRecord): Promise<void>;
  findAccessToken(tokenHash: string): Promise<AccessTokenRecord | undefined>;
  revokeAccessToken(tokenHash: string, revokedAtMs: number): Promise<void>;
  insertRefreshToken(record: RefreshTokenRecord): Promise<void>;
  findRefreshToken(tokenHash: string): Promise<RefreshTokenRecord | undefined>;
  claimRefreshRotation(
    tokenHash: string,
    childTokenHash: string,
    rotatedAtMs: number,
  ): Promise<boolean>;
  updateFamilyActivity(familyId: string, lastUsedAtMs: number, inactivityExpiresAtMs: number): Promise<void>;
}

export interface SessionStore {
  transaction<T>(work: (transaction: SessionTransaction) => Promise<T>): Promise<T>;
}

export type SessionErrorCode =
  | "invalid_principal"
  | "invalid_token"
  | "expired"
  | "revoked"
  | "replayed_refresh"
  | "membership_inactive"
  | "stale_authorization"
  | "stale_principal"
  | "recent_auth_required"
  | "forbidden";

export class SessionError extends Error {
  constructor(readonly code: SessionErrorCode) {
    super(code);
    this.name = "SessionError";
  }
}

export interface IssuedSession {
  readonly accessToken: string;
  readonly refreshToken: string;
  readonly accessExpiresAtMs: number;
  readonly refreshInactivityExpiresAtMs: number;
  readonly refreshAbsoluteExpiresAtMs: number;
}

export interface AuthorizationContext {
  readonly principalId: string;
  readonly familyId: string;
  readonly authenticationEpoch: number;
  readonly authenticatedAtMs: number;
  readonly workspaceId?: string;
  readonly role?: WorkspaceRole;
}

type RefreshOutcome =
  | { readonly status: "issued"; readonly session: IssuedSession }
  | { readonly status: "error"; readonly code: SessionErrorCode };

export class SessionService {
  constructor(
    private readonly dependencies: {
      readonly clock: Clock;
      readonly random: RandomSource;
      readonly store: SessionStore;
      readonly membership: MembershipAuthorizationPort;
      readonly accessTokenHmacKey: Uint8Array;
      readonly refreshTokenHmacKey: Uint8Array;
      readonly policy: SessionPolicy;
    },
  ) {}

  async issue(input: {
    readonly principalId: string;
    readonly authenticatedAtMs: number;
    readonly workspaceId?: string;
  }): Promise<IssuedSession> {
    const nowMs = this.dependencies.clock.nowMs();
    if (
      input.principalId.length === 0 ||
      !Number.isFinite(input.authenticatedAtMs) ||
      input.authenticatedAtMs > nowMs
    ) {
      throw new SessionError("invalid_principal");
    }
    let membership: MembershipSnapshot | undefined;
    if (input.workspaceId !== undefined) {
      membership = await this.dependencies.membership.current(
        input.principalId,
        input.workspaceId,
      );
      if (membership === undefined || membership.state !== "active") {
        throw new SessionError("membership_inactive");
      }
    }

    const familyId = Buffer.from(this.dependencies.random.bytes(16)).toString("base64url");
    const accessToken = Buffer.from(this.dependencies.random.bytes(32)).toString("base64url");
    const refreshToken = Buffer.from(this.dependencies.random.bytes(32)).toString("base64url");
    const accessExpiresAtMs = nowMs + this.dependencies.policy.accessTtlMs;
    const refreshAbsoluteExpiresAtMs = nowMs + this.dependencies.policy.refreshAbsoluteMs;
    const refreshInactivityExpiresAtMs = Math.min(
      nowMs + this.dependencies.policy.refreshInactivityMs,
      refreshAbsoluteExpiresAtMs,
    );
    await this.dependencies.store.transaction(async (transaction) => {
      const authenticationEpoch = await transaction.principalAuthenticationEpoch(input.principalId);
      if (authenticationEpoch === undefined) {
        throw new SessionError("invalid_principal");
      }
      const scope = sessionScope(input.workspaceId, membership);
      await transaction.insertFamily({
        id: familyId,
        principalId: input.principalId,
        authenticationEpoch,
        authenticatedAtMs: input.authenticatedAtMs,
        createdAtMs: nowMs,
        lastUsedAtMs: nowMs,
        inactivityExpiresAtMs: refreshInactivityExpiresAtMs,
        absoluteExpiresAtMs: refreshAbsoluteExpiresAtMs,
        policyVersion: this.dependencies.policy.version,
        state: "active",
        ...scope,
      });
      await transaction.insertAccessToken({
        tokenHash: keyedDigest(this.dependencies.accessTokenHmacKey, accessToken),
        familyId,
        principalId: input.principalId,
        authenticationEpoch,
        authenticatedAtMs: input.authenticatedAtMs,
        issuedAtMs: nowMs,
        expiresAtMs: accessExpiresAtMs,
        state: "active",
        ...scope,
      });
      await transaction.insertRefreshToken({
        tokenHash: keyedDigest(this.dependencies.refreshTokenHmacKey, refreshToken),
        familyId,
        issuedAtMs: nowMs,
        state: "active",
      });
    });
    return {
      accessToken,
      refreshToken,
      accessExpiresAtMs,
      refreshInactivityExpiresAtMs,
      refreshAbsoluteExpiresAtMs,
    };
  }

  async refresh(refreshToken: string): Promise<IssuedSession> {
    if (!isOpaqueToken(refreshToken)) {
      throw new SessionError("invalid_token");
    }
    const nowMs = this.dependencies.clock.nowMs();
    const tokenHash = keyedDigest(this.dependencies.refreshTokenHmacKey, refreshToken);
    const outcome: RefreshOutcome = await this.dependencies.store.transaction(async (transaction) => {
      const record = await transaction.findRefreshToken(tokenHash);
      if (record === undefined) {
        return { status: "error", code: "invalid_token" };
      }
      const family = await transaction.findFamily(record.familyId);
      if (family === undefined) {
        return { status: "error", code: "invalid_token" };
      }
      if (record.state === "rotated") {
        await transaction.revokeFamily(family.id, nowMs, "refresh_reuse");
        return { status: "error", code: "replayed_refresh" };
      }
      if (family.state !== "active") {
        return { status: "error", code: "revoked" };
      }
      if (
        family.inactivityExpiresAtMs <= nowMs ||
        family.absoluteExpiresAtMs <= nowMs
      ) {
        await transaction.revokeFamily(family.id, nowMs, "expired");
        return { status: "error", code: "expired" };
      }
      const currentEpoch = await transaction.principalAuthenticationEpoch(family.principalId);
      if (currentEpoch === undefined || currentEpoch !== family.authenticationEpoch) {
        await transaction.revokeFamily(family.id, nowMs, "stale_principal");
        return { status: "error", code: "stale_principal" };
      }

      const accessToken = Buffer.from(this.dependencies.random.bytes(32)).toString("base64url");
      const nextRefreshToken = Buffer.from(this.dependencies.random.bytes(32)).toString("base64url");
      const nextRefreshHash = keyedDigest(
        this.dependencies.refreshTokenHmacKey,
        nextRefreshToken,
      );
      const accessExpiresAtMs = Math.min(
        nowMs + this.dependencies.policy.accessTtlMs,
        family.absoluteExpiresAtMs,
      );
      const refreshInactivityExpiresAtMs = Math.min(
        nowMs + this.dependencies.policy.refreshInactivityMs,
        family.absoluteExpiresAtMs,
      );
      if (!await transaction.claimRefreshRotation(record.tokenHash, nextRefreshHash, nowMs)) {
        await transaction.revokeFamily(family.id, nowMs, "refresh_reuse");
        return { status: "error", code: "replayed_refresh" };
      }
      await transaction.insertRefreshToken({
        tokenHash: nextRefreshHash,
        familyId: family.id,
        issuedAtMs: nowMs,
        state: "active",
      });
      await transaction.insertAccessToken({
        tokenHash: keyedDigest(this.dependencies.accessTokenHmacKey, accessToken),
        familyId: family.id,
        principalId: family.principalId,
        authenticationEpoch: family.authenticationEpoch,
        authenticatedAtMs: family.authenticatedAtMs,
        issuedAtMs: nowMs,
        expiresAtMs: accessExpiresAtMs,
        state: "active",
        ...familyScope(family),
      });
      await transaction.updateFamilyActivity(
        family.id,
        nowMs,
        refreshInactivityExpiresAtMs,
      );
      return {
        status: "issued",
        session: {
          accessToken,
          refreshToken: nextRefreshToken,
          accessExpiresAtMs,
          refreshInactivityExpiresAtMs,
          refreshAbsoluteExpiresAtMs: family.absoluteExpiresAtMs,
        },
      };
    });
    if (outcome.status === "error") {
      throw new SessionError(outcome.code);
    }
    return outcome.session;
  }

  async authorize(input: {
    readonly accessToken: string;
    readonly workspaceId?: string;
    readonly requiredRoles?: readonly WorkspaceRole[];
    readonly requireRecentAuthentication?: boolean;
  }): Promise<AuthorizationContext> {
    if (!isOpaqueToken(input.accessToken)) {
      throw new SessionError("invalid_token");
    }
    const nowMs = this.dependencies.clock.nowMs();
    const tokenHash = keyedDigest(this.dependencies.accessTokenHmacKey, input.accessToken);
    const session = await this.dependencies.store.transaction(async (transaction) => {
      const access = await transaction.findAccessToken(tokenHash);
      if (access === undefined) {
        throw new SessionError("invalid_token");
      }
      if (access.state !== "active") {
        throw new SessionError("revoked");
      }
      if (access.expiresAtMs <= nowMs) {
        throw new SessionError("expired");
      }
      const family = await transaction.findFamily(access.familyId);
      if (family === undefined) {
        throw new SessionError("invalid_token");
      }
      if (family.state !== "active") {
        throw new SessionError("revoked");
      }
      if (
        family.inactivityExpiresAtMs <= nowMs ||
        family.absoluteExpiresAtMs <= nowMs
      ) {
        throw new SessionError("expired");
      }
      const currentEpoch = await transaction.principalAuthenticationEpoch(access.principalId);
      if (
        currentEpoch === undefined ||
        currentEpoch !== access.authenticationEpoch ||
        currentEpoch !== family.authenticationEpoch
      ) {
        throw new SessionError("stale_principal");
      }
      if (input.workspaceId !== undefined && input.workspaceId !== access.workspaceId) {
        throw new SessionError("forbidden");
      }
      return { access: structuredClone(access), family: structuredClone(family) };
    });

    if (session.access.workspaceId !== undefined) {
      const currentMembership = await this.dependencies.membership.current(
        session.access.principalId,
        session.access.workspaceId,
      );
      if (currentMembership === undefined || currentMembership.state !== "active") {
        throw new SessionError("membership_inactive");
      }
      if (
        currentMembership.role !== session.access.role ||
        currentMembership.authorizationVersion !== session.access.authorizationVersion
      ) {
        throw new SessionError("stale_authorization");
      }
      if (
        input.requiredRoles !== undefined &&
        !input.requiredRoles.includes(currentMembership.role)
      ) {
        throw new SessionError("forbidden");
      }
    } else if (input.workspaceId !== undefined || input.requiredRoles !== undefined) {
      throw new SessionError("forbidden");
    }
    if (
      input.requireRecentAuthentication === true &&
      !isRecent(
        session.access.authenticatedAtMs,
        nowMs,
        this.dependencies.policy.recentAuthenticationMs,
      )
    ) {
      throw new SessionError("recent_auth_required");
    }
    return {
      principalId: session.access.principalId,
      familyId: session.access.familyId,
      authenticationEpoch: session.access.authenticationEpoch,
      authenticatedAtMs: session.access.authenticatedAtMs,
      ...authorizationScope(session.access),
    };
  }

  async verifyRecentSession(accessToken: string): Promise<{
    readonly principalId: string;
    readonly familyId: string;
    readonly authenticatedAtMs: number;
  }> {
    const context = await this.authorize({
      accessToken,
      requireRecentAuthentication: true,
    });
    return {
      principalId: context.principalId,
      familyId: context.familyId,
      authenticatedAtMs: context.authenticatedAtMs,
    };
  }

  async revokeAccess(accessToken: string): Promise<void> {
    if (!isOpaqueToken(accessToken)) {
      throw new SessionError("invalid_token");
    }
    const tokenHash = keyedDigest(this.dependencies.accessTokenHmacKey, accessToken);
    await this.dependencies.store.transaction(async (transaction) => {
      if (await transaction.findAccessToken(tokenHash) === undefined) {
        throw new SessionError("invalid_token");
      }
      await transaction.revokeAccessToken(tokenHash, this.dependencies.clock.nowMs());
    });
  }

  async logoutCurrentFamily(accessToken: string): Promise<void> {
    if (!isOpaqueToken(accessToken)) {
      throw new SessionError("invalid_token");
    }
    const tokenHash = keyedDigest(this.dependencies.accessTokenHmacKey, accessToken);
    await this.dependencies.store.transaction(async (transaction) => {
      const record = await transaction.findAccessToken(tokenHash);
      if (record === undefined) {
        throw new SessionError("invalid_token");
      }
      await transaction.revokeFamily(record.familyId, this.dependencies.clock.nowMs(), "logout");
    });
  }

  async logoutAll(principalId: string): Promise<number> {
    return this.dependencies.store.transaction(async (transaction) => {
      if (await transaction.principalAuthenticationEpoch(principalId) === undefined) {
        throw new SessionError("invalid_principal");
      }
      const nowMs = this.dependencies.clock.nowMs();
      const epoch = await transaction.incrementPrincipalAuthenticationEpoch(principalId);
      await transaction.revokeFamiliesForPrincipal(principalId, nowMs, "logout_all");
      return epoch;
    });
  }
}

function keyedDigest(key: Uint8Array, token: string): string {
  return createHmac("sha256", key).update(token).digest("base64url");
}

function isOpaqueToken(token: string): boolean {
  return /^[A-Za-z0-9_-]+$/u.test(token) && Buffer.from(token, "base64url").length === 32;
}

function isRecent(authenticatedAtMs: number, nowMs: number, maximumAgeMs: number): boolean {
  return (
    Number.isFinite(authenticatedAtMs) &&
    authenticatedAtMs <= nowMs &&
    nowMs - authenticatedAtMs <= maximumAgeMs
  );
}

function sessionScope(
  workspaceId: string | undefined,
  membership: MembershipSnapshot | undefined,
): Pick<SessionFamilyRecord, "workspaceId" | "role" | "authorizationVersion"> {
  if (workspaceId === undefined || membership === undefined) {
    return {};
  }
  return {
    workspaceId,
    role: membership.role,
    authorizationVersion: membership.authorizationVersion,
  };
}

function familyScope(
  family: SessionFamilyRecord,
): Pick<AccessTokenRecord, "workspaceId" | "role" | "authorizationVersion"> {
  if (
    family.workspaceId === undefined ||
    family.role === undefined ||
    family.authorizationVersion === undefined
  ) {
    return {};
  }
  return {
    workspaceId: family.workspaceId,
    role: family.role,
    authorizationVersion: family.authorizationVersion,
  };
}

function authorizationScope(
  access: AccessTokenRecord,
): Pick<AuthorizationContext, "workspaceId" | "role"> {
  if (access.workspaceId === undefined || access.role === undefined) {
    return {};
  }
  return { workspaceId: access.workspaceId, role: access.role };
}
