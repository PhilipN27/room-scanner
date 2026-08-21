import assert from "node:assert/strict";
import { test } from "node:test";

import {
  DEFAULT_SESSION_POLICY,
  SessionError,
  SessionService,
  type AccessTokenRecord,
  type MembershipAuthorizationPort,
  type MembershipSnapshot,
  type RefreshTokenRecord,
  type SessionFamilyRecord,
  type SessionStore,
  type SessionTransaction,
} from "../sessions.js";
import {
  AsyncOperationGate,
  observeSettlement,
} from "./support/async-operation-gate.js";

class ManualClock {
  constructor(private current = Date.UTC(2026, 7, 18, 10, 0, 0)) {}

  nowMs(): number {
    return this.current;
  }

  advance(milliseconds: number): void {
    this.current += milliseconds;
  }
}

class SequenceRandom {
  readonly requestedLengths: number[] = [];
  private next = 1;

  bytes(length: number): Uint8Array {
    this.requestedLengths.push(length);
    const seed = this.next++;
    return Uint8Array.from({ length }, (_, index) => (seed * 29 + index) & 0xff);
  }
}

class MemorySessionStore implements SessionStore, SessionTransaction {
  readonly principalEpochs = new Map<string, number>();
  readonly families: SessionFamilyRecord[] = [];
  readonly accessTokens: AccessTokenRecord[] = [];
  readonly refreshTokens: RefreshTokenRecord[] = [];
  loseNextRefreshRotation = false;
  readonly operationGate = new AsyncOperationGate();
  private tail: Promise<void> = Promise.resolve();

  async transaction<T>(work: (transaction: SessionTransaction) => Promise<T>): Promise<T> {
    const previous = this.tail;
    let release = (): void => undefined;
    this.tail = new Promise<void>((resolve) => {
      release = resolve;
    });
    await previous;
    const snapshot = {
      principalEpochs: structuredClone(this.principalEpochs),
      families: structuredClone(this.families),
      accessTokens: structuredClone(this.accessTokens),
      refreshTokens: structuredClone(this.refreshTokens),
    };
    try {
      return await work(this);
    } catch (error) {
      this.principalEpochs.clear();
      for (const [principalId, epoch] of snapshot.principalEpochs) {
        this.principalEpochs.set(principalId, epoch);
      }
      this.families.splice(0, this.families.length, ...snapshot.families);
      this.accessTokens.splice(0, this.accessTokens.length, ...snapshot.accessTokens);
      this.refreshTokens.splice(0, this.refreshTokens.length, ...snapshot.refreshTokens);
      throw error;
    } finally {
      release();
    }
  }

  async principalAuthenticationEpoch(principalId: string): Promise<number | undefined> {
    return this.principalEpochs.get(principalId);
  }

  async incrementPrincipalAuthenticationEpoch(principalId: string): Promise<number> {
    const next = (this.principalEpochs.get(principalId) ?? 0) + 1;
    this.principalEpochs.set(principalId, next);
    return next;
  }

  async insertFamily(family: SessionFamilyRecord): Promise<void> {
    this.families.push(structuredClone(family));
  }

  async findFamily(familyId: string): Promise<SessionFamilyRecord | undefined> {
    return this.families.find((family) => family.id === familyId);
  }

  async revokeFamily(familyId: string, revokedAtMs: number, reason: string): Promise<void> {
    const family = await this.findFamily(familyId);
    if (family !== undefined && family.state === "active") {
      family.state = "revoked";
      family.revokedAtMs = revokedAtMs;
      family.revocationReason = reason;
    }
  }

  async revokeFamiliesForPrincipal(principalId: string, revokedAtMs: number, reason: string): Promise<void> {
    for (const family of this.families.filter((candidate) => candidate.principalId === principalId)) {
      await this.revokeFamily(family.id, revokedAtMs, reason);
    }
  }

  async insertAccessToken(record: AccessTokenRecord): Promise<void> {
    this.accessTokens.push(structuredClone(record));
  }

  async findAccessToken(tokenHash: string): Promise<AccessTokenRecord | undefined> {
    return this.accessTokens.find((record) => record.tokenHash === tokenHash);
  }

  async revokeAccessToken(tokenHash: string, revokedAtMs: number): Promise<void> {
    const record = await this.findAccessToken(tokenHash);
    if (record !== undefined) {
      record.state = "revoked";
      record.revokedAtMs = revokedAtMs;
    }
  }

  async insertRefreshToken(record: RefreshTokenRecord): Promise<void> {
    await this.operationGate.before("insertRefreshToken");
    this.refreshTokens.push(structuredClone(record));
  }

  async findRefreshToken(tokenHash: string): Promise<RefreshTokenRecord | undefined> {
    await this.operationGate.before("findRefreshToken");
    return this.refreshTokens.find((record) => record.tokenHash === tokenHash);
  }

  async claimRefreshRotation(tokenHash: string, childTokenHash: string, rotatedAtMs: number): Promise<boolean> {
    await this.operationGate.before("claimRefreshRotation");
    const record = await this.findRefreshToken(tokenHash);
    if (record !== undefined && this.loseNextRefreshRotation) {
      this.loseNextRefreshRotation = false;
      record.state = "rotated";
      record.childTokenHash = "opponent_winner_hash";
      record.rotatedAtMs = rotatedAtMs;
      return false;
    }
    if (record === undefined || record.state !== "active") {
      return false;
    }
    record.state = "rotated";
    record.childTokenHash = childTokenHash;
    record.rotatedAtMs = rotatedAtMs;
    return true;
  }

  async updateFamilyActivity(familyId: string, lastUsedAtMs: number, inactivityExpiresAtMs: number): Promise<void> {
    const family = await this.findFamily(familyId);
    if (family !== undefined) {
      family.lastUsedAtMs = lastUsedAtMs;
      family.inactivityExpiresAtMs = inactivityExpiresAtMs;
    }
  }
}

interface Harness {
  readonly clock: ManualClock;
  readonly random: SequenceRandom;
  readonly store: MemorySessionStore;
  readonly memberships: Map<string, MembershipSnapshot>;
  readonly service: SessionService;
}

function membershipKey(principalId: string, workspaceId: string): string {
  return `${principalId}:${workspaceId}`;
}

function makeHarness(): Harness {
  const clock = new ManualClock();
  const random = new SequenceRandom();
  const store = new MemorySessionStore();
  store.principalEpochs.set("principal-a", 0);
  const memberships = new Map<string, MembershipSnapshot>();
  memberships.set(membershipKey("principal-a", "workspace-a"), {
    state: "active",
    role: "editor",
    authorizationVersion: 4,
  });
  const membership: MembershipAuthorizationPort = {
    async current(principalId, workspaceId) {
      return memberships.get(membershipKey(principalId, workspaceId));
    },
  };
  return {
    clock,
    random,
    store,
    memberships,
    service: new SessionService({
      clock,
      random,
      store,
      membership,
      accessTokenHmacKey: Buffer.alloc(32, 0x61),
      refreshTokenHmacKey: Buffer.alloc(32, 0x62),
      policy: DEFAULT_SESSION_POLICY,
    }),
  };
}

async function issue(harness: Harness, authenticatedAgeMs = 0) {
  return harness.service.issue({
    principalId: "principal-a",
    workspaceId: "workspace-a",
    authenticatedAtMs: harness.clock.nowMs() - authenticatedAgeMs,
  });
}

async function expectCode(promise: Promise<unknown>, code: string): Promise<void> {
  await assert.rejects(
    promise,
    (error: unknown) => error instanceof SessionError && error.code === code,
  );
}

test("issue creates five-minute opaque access and bounded refresh family while storing keyed hashes only", async () => {
  const harness = makeHarness();
  const issued = await issue(harness);

  assert.equal(Buffer.from(issued.accessToken, "base64url").length, 32);
  assert.equal(Buffer.from(issued.refreshToken, "base64url").length, 32);
  assert.equal(issued.accessExpiresAtMs - harness.clock.nowMs(), 5 * 60_000);
  assert.deepEqual(harness.random.requestedLengths, [16, 32, 32]);
  const family = harness.store.families[0];
  assert.ok(family);
  assert.equal(family.inactivityExpiresAtMs - family.createdAtMs, 7 * 24 * 60 * 60_000);
  assert.equal(family.absoluteExpiresAtMs - family.createdAtMs, 30 * 24 * 60 * 60_000);
  const persisted = JSON.stringify({
    families: harness.store.families,
    access: harness.store.accessTokens,
    refresh: harness.store.refreshTokens,
  });
  assert.equal(persisted.includes(issued.accessToken), false);
  assert.equal(persisted.includes(issued.refreshToken), false);
  assert.equal(harness.store.accessTokens[0]?.authenticationEpoch, 0);
  assert.equal(harness.store.accessTokens[0]?.authorizationVersion, 4);
});

test("valid authorization returns current context and access expires exactly at five minutes", async () => {
  const harness = makeHarness();
  const issued = await issue(harness);
  assert.deepEqual(
    await harness.service.authorize({
      accessToken: issued.accessToken,
      workspaceId: "workspace-a",
      requiredRoles: ["editor", "admin", "owner"],
    }),
    {
      authenticatedAtMs: harness.clock.nowMs(),
      authenticationEpoch: 0,
      familyId: harness.store.families[0]?.id,
      principalId: "principal-a",
      role: "editor",
      workspaceId: "workspace-a",
    },
  );
  harness.clock.advance(5 * 60_000);
  await expectCode(
    harness.service.authorize({ accessToken: issued.accessToken, workspaceId: "workspace-a" }),
    "expired",
  );
});

test("explicit access revocation, current-family logout, and logout-all invalidate unexpired access", async () => {
  const revokedHarness = makeHarness();
  const revoked = await issue(revokedHarness);
  await revokedHarness.service.revokeAccess(revoked.accessToken);
  await expectCode(
    revokedHarness.service.authorize({ accessToken: revoked.accessToken, workspaceId: "workspace-a" }),
    "revoked",
  );

  const logoutHarness = makeHarness();
  const loggedOut = await issue(logoutHarness);
  await logoutHarness.service.logoutCurrentFamily(loggedOut.accessToken);
  await expectCode(
    logoutHarness.service.authorize({ accessToken: loggedOut.accessToken, workspaceId: "workspace-a" }),
    "revoked",
  );
  await expectCode(logoutHarness.service.refresh(loggedOut.refreshToken), "revoked");

  const allHarness = makeHarness();
  const all = await issue(allHarness);
  const newEpoch = await allHarness.service.logoutAll("principal-a");
  assert.equal(newEpoch, 1);
  await expectCode(
    allHarness.service.authorize({ accessToken: all.accessToken, workspaceId: "workspace-a" }),
    "revoked",
  );
});

test("refresh rotates with zero grace and ancestor reuse revokes the family and active successor", async () => {
  const harness = makeHarness();
  const initial = await issue(harness);
  const rotated = await harness.service.refresh(initial.refreshToken);
  assert.notEqual(rotated.refreshToken, initial.refreshToken);
  assert.equal(harness.store.refreshTokens[0]?.state, "rotated");
  assert.equal(harness.store.refreshTokens.length, 2);

  await expectCode(harness.service.refresh(initial.refreshToken), "replayed_refresh");
  assert.equal(harness.store.families[0]?.state, "revoked");
  await expectCode(
    harness.service.authorize({ accessToken: rotated.accessToken, workspaceId: "workspace-a" }),
    "revoked",
  );
  await expectCode(harness.service.refresh(rotated.refreshToken), "revoked");
});

test("concurrent refresh cannot issue independent children and replay revokes the sole successor", async () => {
  const harness = makeHarness();
  const initial = await issue(harness);
  const results = await Promise.allSettled(
    Array.from({ length: 12 }, () => harness.service.refresh(initial.refreshToken)),
  );

  assert.equal(results.filter((result) => result.status === "fulfilled").length, 1);
  assert.equal(results.filter((result) => result.status === "rejected").length, 11);
  assert.equal(harness.store.refreshTokens.length, 2);
  assert.equal(harness.store.families[0]?.state, "revoked");
  const winner = results.find((result) => result.status === "fulfilled");
  assert.ok(winner?.status === "fulfilled");
  await expectCode(harness.service.refresh(winner.value.refreshToken), "revoked");
});

test("a refresh rotation that loses the storage claim is rejected and revokes the family", async () => {
  const harness = makeHarness();
  const initial = await issue(harness);
  harness.store.loseNextRefreshRotation = true;

  await expectCode(harness.service.refresh(initial.refreshToken), "replayed_refresh");

  assert.equal(harness.store.refreshTokens.length, 1);
  assert.equal(harness.store.refreshTokens[0]?.childTokenHash, "opponent_winner_hash");
  assert.equal(harness.store.families[0]?.state, "revoked");
  assert.equal(harness.store.families[0]?.revocationReason, "refresh_reuse");
});

test("refresh awaits delayed async reads, writes, and the losing rotation CAS before branching", async () => {
  const readHarness = makeHarness();
  const readInitial = await issue(readHarness);
  readHarness.store.operationGate.arm("findRefreshToken");
  const delayedRead = readHarness.service.refresh(readInitial.refreshToken);
  const readSettlement = observeSettlement(delayedRead);
  await readHarness.store.operationGate.waitUntilReached();
  assert.equal(readSettlement.settled(), false);
  assert.equal(readHarness.store.refreshTokens.length, 1);
  readHarness.store.operationGate.release();
  await delayedRead;

  const writeHarness = makeHarness();
  const writeInitial = await issue(writeHarness);
  writeHarness.store.operationGate.arm("insertRefreshToken");
  const delayedWrite = writeHarness.service.refresh(writeInitial.refreshToken);
  const writeSettlement = observeSettlement(delayedWrite);
  await writeHarness.store.operationGate.waitUntilReached();
  assert.equal(writeSettlement.settled(), false);
  assert.equal(writeHarness.store.refreshTokens.length, 1);
  writeHarness.store.operationGate.release();
  await delayedWrite;

  const casHarness = makeHarness();
  const casInitial = await issue(casHarness);
  casHarness.store.loseNextRefreshRotation = true;
  casHarness.store.operationGate.arm("claimRefreshRotation");
  const delayedLostClaim = casHarness.service.refresh(casInitial.refreshToken);
  const casSettlement = observeSettlement(delayedLostClaim);
  await casHarness.store.operationGate.waitUntilReached();
  assert.equal(casSettlement.settled(), false);
  assert.equal(casHarness.store.families[0]?.state, "active");
  casHarness.store.operationGate.release();
  await expectCode(delayedLostClaim, "replayed_refresh");
  assert.equal(casHarness.store.families[0]?.state, "revoked");
});

test("seven-day inactivity and thirty-day absolute expiry bound refresh families", async () => {
  const inactiveHarness = makeHarness();
  const inactive = await issue(inactiveHarness);
  inactiveHarness.clock.advance(7 * 24 * 60 * 60_000);
  await expectCode(inactiveHarness.service.refresh(inactive.refreshToken), "expired");
  assert.equal(inactiveHarness.store.families[0]?.state, "revoked");
  assert.equal(inactiveHarness.store.families[0]?.revocationReason, "expired");

  const absoluteHarness = makeHarness();
  let current = await issue(absoluteHarness);
  for (let index = 0; index < 4; index += 1) {
    absoluteHarness.clock.advance(6 * 24 * 60 * 60_000);
    current = await absoluteHarness.service.refresh(current.refreshToken);
  }
  absoluteHarness.clock.advance(6 * 24 * 60 * 60_000);
  await expectCode(absoluteHarness.service.refresh(current.refreshToken), "expired");
  assert.equal(absoluteHarness.store.families[0]?.absoluteExpiresAtMs, absoluteHarness.clock.nowMs());
  assert.equal(absoluteHarness.store.families[0]?.state, "revoked");
  assert.equal(absoluteHarness.store.families[0]?.revocationReason, "expired");
});

test("removed membership and stale role or authorization version invalidate access on the next check", async () => {
  const removedHarness = makeHarness();
  const removed = await issue(removedHarness);
  removedHarness.memberships.set(membershipKey("principal-a", "workspace-a"), {
    state: "removed",
    role: "editor",
    authorizationVersion: 5,
  });
  await expectCode(
    removedHarness.service.authorize({ accessToken: removed.accessToken, workspaceId: "workspace-a" }),
    "membership_inactive",
  );

  const roleHarness = makeHarness();
  const role = await issue(roleHarness);
  roleHarness.memberships.set(membershipKey("principal-a", "workspace-a"), {
    state: "active",
    role: "viewer",
    authorizationVersion: 4,
  });
  await expectCode(
    roleHarness.service.authorize({ accessToken: role.accessToken, workspaceId: "workspace-a" }),
    "stale_authorization",
  );

  const versionHarness = makeHarness();
  const versioned = await issue(versionHarness);
  versionHarness.memberships.set(membershipKey("principal-a", "workspace-a"), {
    state: "active",
    role: "editor",
    authorizationVersion: 5,
  });
  await expectCode(
    versionHarness.service.authorize({ accessToken: versioned.accessToken, workspaceId: "workspace-a" }),
    "stale_authorization",
  );
});

test("principal epoch changes invalidate access and refresh independently of token expiry", async () => {
  const harness = makeHarness();
  const issued = await issue(harness);
  await harness.store.incrementPrincipalAuthenticationEpoch("principal-a");

  await expectCode(
    harness.service.authorize({ accessToken: issued.accessToken, workspaceId: "workspace-a" }),
    "stale_principal",
  );
  await expectCode(harness.service.refresh(issued.refreshToken), "stale_principal");
  assert.equal(harness.store.families[0]?.state, "revoked");
  assert.equal(harness.store.families[0]?.revocationReason, "stale_principal");
});

test("recent-auth gates use server authentication time and ignore a local biometric assertion", async () => {
  const validHarness = makeHarness();
  const valid = await issue(validHarness, 4 * 60_000);
  assert.deepEqual(await validHarness.service.verifyRecentSession(valid.accessToken), {
    principalId: "principal-a",
    familyId: validHarness.store.families[0]?.id,
    authenticatedAtMs: validHarness.clock.nowMs() - 4 * 60_000,
  });
  assert.equal(
    (
      await validHarness.service.authorize({
        accessToken: valid.accessToken,
        workspaceId: "workspace-a",
        requireRecentAuthentication: true,
      })
    ).principalId,
    "principal-a",
  );

  const staleHarness = makeHarness();
  const stale = await issue(staleHarness, 5 * 60_000 + 1);
  await expectCode(
    staleHarness.service.authorize({
      accessToken: stale.accessToken,
      workspaceId: "workspace-a",
      requireRecentAuthentication: true,
      localBiometricAssertion: true,
    } as Parameters<SessionService["authorize"]>[0]),
    "recent_auth_required",
  );
  assert.equal(
    (
      await staleHarness.service.authorize({
        accessToken: stale.accessToken,
        workspaceId: "workspace-a",
      })
    ).principalId,
    "principal-a",
  );
});
