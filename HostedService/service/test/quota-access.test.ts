import assert from "node:assert/strict";
import test from "node:test";

import {
  NON_PERIODIC_QUOTA_PERIOD_KEY,
  QUOTA_METRICS,
  TEST_ONLY_QUOTA_POLICY_V1,
  WORKSPACE_QUOTA_ALLOCATION_ACTIONS,
  QuotaError,
  SystemQuotaService,
  WorkspaceQuotaService,
  type QuotaMetric,
  type QuotaPolicy,
  type QuotaPolicyActivationResult,
  type QuotaReconciliation,
  type QuotaRepository,
  type QuotaReservation,
  type QuotaTransaction,
  type QuotaUsageRecord,
  type WorkspaceAllocatableQuotaMetric,
} from "../src/quota/quota-v2-service.js";
import { isPublicationAction, permissionFor, WORKSPACE_ROLES, type AuthorizationAction, type WorkspaceRole } from "../src/authorization/policy.js";
import type { AuthorizationResourceReference, AuthorizedWorkspaceContext } from "../src/authorization/authorizer.js";
import type { HostedMutationGrant } from "../src/operations/operational-flags.js";

interface RepositorySnapshot {
  readonly policies: Array<{ workspaceId: string; policy: QuotaPolicy }>;
  readonly usage: QuotaUsageRecord[];
  readonly reservations: QuotaReservation[];
  readonly reconciliations: QuotaReconciliation[];
  readonly ledger: string[];
  readonly activeMemberSlots: string[];
}

interface GateState {
  enabled: boolean;
  globalVersion: number;
  workspaceVersions: Map<string, number>;
  publicationGlobalEnabled: boolean;
  publicationWorkspaceEnabled: Map<string, boolean>;
  publicationGlobalVersion: number;
  publicationWorkspaceVersions: Map<string, number>;
}

class MemoryQuotaV2Repository implements QuotaRepository, QuotaTransaction {
  readonly policies = new Map<string, QuotaPolicy[]>();
  readonly usage = new Map<string, QuotaUsageRecord>();
  readonly reservations = new Map<string, QuotaReservation>();
  readonly reconciliations = new Map<string, QuotaReconciliation>();
  readonly ledger: string[] = [];
  readonly activeMemberSlots = new Set<string>();
  readonly retainedRecords = [{ id: "project-1", bytes: Uint8Array.from([1, 2, 3]) }];
  beforeConfirm: (() => void) | undefined;
  private tail: Promise<void> = Promise.resolve();

  constructor(readonly gate: GateState) {}

  usageKey(workspaceId: string, metric: QuotaMetric, periodKey: string): string {
    return `${workspaceId}\u0000${metric}\u0000${periodKey}`;
  }

  reservationKey(workspaceId: string, periodKey: string, idempotencyKey: string): string {
    return `${workspaceId}\u0000${periodKey}\u0000${idempotencyKey}`;
  }

  async transaction<T>(work: (transaction: QuotaTransaction) => Promise<T>): Promise<T> {
    let release!: () => void;
    const previous = this.tail;
    this.tail = new Promise<void>((resolve) => { release = resolve; });
    await previous;
    const snapshot = this.capture();
    try {
      return await work(this);
    } catch (error) {
      this.restore(snapshot);
      throw error;
    } finally {
      release();
    }
  }

  async confirmHostedMutation(grant: HostedMutationGrant): Promise<boolean> {
    if (this.beforeConfirm !== undefined) {
      const callback = this.beforeConfirm;
      this.beforeConfirm = undefined;
      callback();
    }
    return this.gate.enabled &&
      grant.workspaceId.length > 0 &&
      grant.hostedGlobalFlagVersion === this.gate.globalVersion &&
      grant.hostedWorkspaceFlagVersion === (this.gate.workspaceVersions.get(grant.workspaceId) ?? 0) &&
      (!isPublicationAction(grant.action) || (
        this.gate.publicationGlobalEnabled &&
        this.gate.publicationWorkspaceEnabled.get(grant.workspaceId) === true &&
        grant.publicationGlobalFlagVersion === this.gate.publicationGlobalVersion &&
        grant.publicationWorkspaceFlagVersion ===
          (this.gate.publicationWorkspaceVersions.get(grant.workspaceId) ?? 0)
      ));
  }

  async activePolicy(workspaceId: string): Promise<QuotaPolicy | undefined> {
    return clone(this.policies.get(workspaceId)?.at(-1));
  }

  async activatePolicy(
    workspaceId: string,
    policy: QuotaPolicy,
  ): Promise<QuotaPolicyActivationResult> {
    const policies = this.policies.get(workspaceId) ?? [];
    policies.push(structuredClone(policy));
    this.policies.set(workspaceId, policies);
    for (const metric of QUOTA_METRICS) {
      const periodKey = metric === "portal_bytes" ? policy.portalPeriodKey : NON_PERIODIC_QUOTA_PERIOD_KEY;
      const key = this.usageKey(workspaceId, metric, periodKey);
      const existing = this.usage.get(key);
      const authoritativeActiveMemberCount = [...this.activeMemberSlots].filter((slot) =>
        slot.startsWith(`${workspaceId}\u0000`)).length;
      this.usage.set(key, {
        workspaceId,
        metric,
        periodKey,
        policyVersion: policy.version,
        used: metric === "member_count" ? authoritativeActiveMemberCount : (existing?.used ?? 0),
        reserved: metric === "member_count" ? 0 : (existing?.reserved ?? 0),
        limit: policy.limits[metric],
        warningThresholdPercent: policy.warningThresholdPercent,
        reconciliationGeneration: existing?.reconciliationGeneration ?? 0,
      });
    }
    return {
      authoritativeActiveMemberCount: [...this.activeMemberSlots].filter((slot) =>
        slot.startsWith(`${workspaceId}\u0000`)).length,
    };
  }

  async quotaSnapshot(workspaceId: string, metric: QuotaMetric, periodKey: string): Promise<QuotaUsageRecord | undefined> {
    return clone(this.usage.get(this.usageKey(workspaceId, metric, periodKey)));
  }

  async reservation(workspaceId: string, periodKey: string, idempotencyKey: string): Promise<QuotaReservation | undefined> {
    return clone(this.reservations.get(this.reservationKey(workspaceId, periodKey, idempotencyKey)));
  }

  async reserve(input: Parameters<QuotaTransaction["reserve"]>[0]): Promise<QuotaReservation> {
    const key = this.reservationKey(input.workspaceId, input.periodKey, input.idempotencyKey);
    const existing = this.reservations.get(key);
    if (existing !== undefined) {
      if (existing.metric !== input.metric || existing.requestedAmount !== input.amount || existing.authorizationAction !== input.authorizationAction || JSON.stringify(existing.authorizationResource) !== JSON.stringify(input.authorizationResource)) {
        throw new QuotaError("idempotency_key_reused");
      }
      return structuredClone(existing);
    }
    const usageKey = this.usageKey(input.workspaceId, input.metric, input.periodKey);
    const usage = this.usage.get(usageKey);
    if (usage === undefined) throw new QuotaError("policy_missing");
    if (usage.used + usage.reserved + input.amount > usage.limit) throw new QuotaError("quota_exceeded");
    const reservation: QuotaReservation = {
      workspaceId: input.workspaceId,
      periodKey: input.periodKey,
      idempotencyKey: input.idempotencyKey,
      metric: input.metric,
      authorizationAction: input.authorizationAction,
      ...(input.authorizationResource === undefined ? {} : { authorizationResource: structuredClone(input.authorizationResource) }),
      requestedAmount: input.amount,
      policyVersion: input.policyVersion,
      expiresAtMs: input.expiresAtMs,
      state: "reserved",
      createdAtMs: input.nowMs,
    };
    this.reservations.set(key, reservation);
    this.usage.set(usageKey, { ...usage, reserved: usage.reserved + input.amount });
    this.ledger.push(`reserve:${key}`);
    return structuredClone(reservation);
  }

  async finalize(input: Parameters<QuotaTransaction["finalize"]>[0]): Promise<QuotaReservation> {
    const key = this.reservationKey(input.workspaceId, input.periodKey, input.idempotencyKey);
    const existing = this.reservations.get(key);
    if (existing === undefined) throw new QuotaError("reservation_not_found");
    if (existing.state === "finalized") {
      if (existing.finalizedAmount !== input.actualAmount) throw new QuotaError("idempotency_key_reused");
      return structuredClone(existing);
    }
    if (existing.state === "released") throw new QuotaError("reservation_released");
    if (input.actualAmount > existing.requestedAmount) throw new QuotaError("invalid_request");
    const usageKey = this.usageKey(input.workspaceId, existing.metric, input.periodKey);
    const usage = this.usage.get(usageKey);
    if (usage === undefined) throw new QuotaError("persistence_invariant");
    const updated: QuotaReservation = { ...existing, state: "finalized", finalizedAmount: input.actualAmount, finalizedAtMs: input.nowMs };
    this.reservations.set(key, updated);
    this.usage.set(usageKey, { ...usage, used: usage.used + input.actualAmount, reserved: usage.reserved - existing.requestedAmount });
    this.ledger.push(`finalize:${key}`);
    return structuredClone(updated);
  }

  async release(input: Parameters<QuotaTransaction["release"]>[0]): Promise<QuotaReservation> {
    const key = this.reservationKey(input.workspaceId, input.periodKey, input.idempotencyKey);
    const existing = this.reservations.get(key);
    if (existing === undefined) throw new QuotaError("reservation_not_found");
    if (existing.state === "released") return structuredClone(existing);
    if (existing.state === "finalized") {
      if (input.reason === "expired") return structuredClone(existing);
      throw new QuotaError("reservation_finalized");
    }
    const usageKey = this.usageKey(input.workspaceId, existing.metric, input.periodKey);
    const usage = this.usage.get(usageKey);
    if (usage === undefined) throw new QuotaError("persistence_invariant");
    const updated: QuotaReservation = { ...existing, state: "released", releasedAtMs: input.nowMs, releaseReason: input.reason };
    this.reservations.set(key, updated);
    this.usage.set(usageKey, { ...usage, reserved: usage.reserved - existing.requestedAmount });
    this.ledger.push(`${input.reason}:${key}`);
    return structuredClone(updated);
  }

  async reconcile(input: QuotaReconciliation): Promise<{ readonly applied: boolean; readonly snapshot: QuotaUsageRecord }> {
    const reconciliationKey = `${this.usageKey(input.workspaceId, input.metric, input.periodKey)}\u0000${input.generation}`;
    const existing = this.reconciliations.get(reconciliationKey);
    const usageKey = this.usageKey(input.workspaceId, input.metric, input.periodKey);
    const usage = this.usage.get(usageKey);
    if (usage === undefined) throw new QuotaError("policy_missing");
    if (existing !== undefined) {
      if (existing.authoritativeUsed !== input.authoritativeUsed) throw new QuotaError("idempotency_key_reused");
      return { applied: false, snapshot: structuredClone(usage) };
    }
    if (input.generation < usage.reconciliationGeneration) return { applied: false, snapshot: structuredClone(usage) };
    this.reconciliations.set(reconciliationKey, structuredClone(input));
    const updated = { ...usage, used: input.authoritativeUsed, reconciliationGeneration: input.generation };
    this.usage.set(usageKey, updated);
    this.ledger.push(`reconcile:${reconciliationKey}`);
    return { applied: true, snapshot: structuredClone(updated) };
  }

  private capture(): RepositorySnapshot {
    return {
      policies: [...this.policies.entries()].flatMap(([workspaceId, policies]) => policies.map((policy) => ({ workspaceId, policy: structuredClone(policy) }))),
      usage: structuredClone([...this.usage.values()]),
      reservations: structuredClone([...this.reservations.values()]),
      reconciliations: structuredClone([...this.reconciliations.values()]),
      ledger: structuredClone(this.ledger),
      activeMemberSlots: [...this.activeMemberSlots],
    };
  }

  private restore(snapshot: RepositorySnapshot): void {
    this.policies.clear();
    for (const entry of snapshot.policies) {
      const policies = this.policies.get(entry.workspaceId) ?? [];
      policies.push(structuredClone(entry.policy));
      this.policies.set(entry.workspaceId, policies);
    }
    this.usage.clear();
    for (const usage of snapshot.usage) this.usage.set(this.usageKey(usage.workspaceId, usage.metric, usage.periodKey), structuredClone(usage));
    this.reservations.clear();
    for (const reservation of snapshot.reservations) this.reservations.set(this.reservationKey(reservation.workspaceId, reservation.periodKey, reservation.idempotencyKey), structuredClone(reservation));
    this.reconciliations.clear();
    for (const reconciliation of snapshot.reconciliations) {
      this.reconciliations.set(`${this.usageKey(reconciliation.workspaceId, reconciliation.metric, reconciliation.periodKey)}\u0000${reconciliation.generation}`, structuredClone(reconciliation));
    }
    this.ledger.splice(0, this.ledger.length, ...snapshot.ledger);
    this.activeMemberSlots.clear();
    for (const slot of snapshot.activeMemberSlots) this.activeMemberSlots.add(slot);
  }
}

class SessionQuotaAuthorizer {
  readonly calls: Array<{ action: AuthorizationAction; token: string; resource?: AuthorizationResourceReference }> = [];
  readonly contexts = new Map<string, AuthorizedWorkspaceContext>();
  readonly resourceWorkspaces = new Map<string, string>([["project-a", "workspace-a"], ["project-b", "workspace-b"]]);

  constructor() {
    for (const role of WORKSPACE_ROLES) this.contexts.set(`${role}-a`, context(`principal-${role}`, "workspace-a", role));
    this.contexts.set("editor-b", context("principal-editor-b", "workspace-b", "editor"));
  }

  async authorize(input: { readonly accessToken: string; readonly action: AuthorizationAction; readonly resource?: AuthorizationResourceReference }): Promise<AuthorizedWorkspaceContext> {
    this.calls.push({ token: input.accessToken, action: input.action, ...(input.resource === undefined ? {} : { resource: structuredClone(input.resource) }) });
    const current = this.contexts.get(input.accessToken);
    if (current === undefined || !permissionFor(current.role, input.action).allowed) throw new QuotaError("operation_disabled");
    if (input.resource !== undefined && this.resourceWorkspaces.get(input.resource.id) !== current.workspaceId) throw new QuotaError("operation_disabled");
    return structuredClone(current);
  }
}

function context(principalId: string, workspaceId: string, role: WorkspaceRole): AuthorizedWorkspaceContext {
  return { principalId, familyId: `family-${principalId}`, workspaceId, role, authorizationVersion: 1 };
}

function clone<T>(value: T | undefined): T | undefined {
  return value === undefined ? undefined : structuredClone(value);
}

function policy(version: number, portalPeriodKey = TEST_ONLY_QUOTA_POLICY_V1.portalPeriodKey, limits = TEST_ONLY_QUOTA_POLICY_V1.limits): QuotaPolicy {
  return { ...TEST_ONLY_QUOTA_POLICY_V1, version, portalPeriodKey, limits: { ...limits } };
}

function harness(acceptedPolicyClassification: QuotaPolicy["classification"] = "test-only") {
  const gate: GateState = {
    enabled: true,
    globalVersion: 1,
    workspaceVersions: new Map([["workspace-a", 1], ["workspace-b", 1]]),
    publicationGlobalEnabled: true,
    publicationWorkspaceEnabled: new Map([["workspace-a", true], ["workspace-b", true]]),
    publicationGlobalVersion: 1,
    publicationWorkspaceVersions: new Map([["workspace-a", 1], ["workspace-b", 1]]),
  };
  const repository = new MemoryQuotaV2Repository(gate);
  repository.activeMemberSlots.add("workspace-a\u0000bootstrap-owner-a");
  repository.activeMemberSlots.add("workspace-b\u0000bootstrap-owner-b");
  const authorizer = new SessionQuotaAuthorizer();
  const clock = { now: 10_000 };
  const systemCapability = Symbol("system-quota-capability");
  const hostedGate = {
    hostedMutationGrant: async (workspaceId: string, action: AuthorizationAction): Promise<HostedMutationGrant> => {
      if (!gate.enabled) throw new Error("disabled");
      const base = {
        kind: "hosted-mutation-grant-v2" as const,
        workspaceId,
        action,
        hostedGlobalFlagVersion: gate.globalVersion,
        hostedWorkspaceFlagVersion: gate.workspaceVersions.get(workspaceId) ?? 0,
      };
      if (!isPublicationAction(action)) return base;
      if (
        !gate.publicationGlobalEnabled ||
        gate.publicationWorkspaceEnabled.get(workspaceId) !== true
      ) throw new Error("publication disabled");
      return {
        ...base,
        publicationGlobalFlagVersion: gate.publicationGlobalVersion,
        publicationWorkspaceFlagVersion: gate.publicationWorkspaceVersions.get(workspaceId) ?? 0,
      };
    },
  };
  const workspaceQuota = new WorkspaceQuotaService({
    clock: { nowMs: () => clock.now },
    repository,
    authorizer,
    hostedGate,
    reservationTtlMs: 5_000,
  });
  const systemQuota = new SystemQuotaService({
    clock: { nowMs: () => clock.now },
    repository,
    hostedGate,
    acceptedPolicyClassification,
    authorizer: { authorize: async ({ capability }) => capability === systemCapability },
  });
  return { authorizer, clock, gate, repository, systemCapability, systemQuota, workspaceQuota };
}

async function activate(instance: ReturnType<typeof harness>, nextPolicy = TEST_ONLY_QUOTA_POLICY_V1, workspaceId = "workspace-a"): Promise<void> {
  await instance.systemQuota.activatePolicy({ capability: instance.systemCapability, workspaceId, policy: nextPolicy });
}

function resourceFor(metric: WorkspaceAllocatableQuotaMetric): AuthorizationResourceReference | undefined {
  return metric === "project_count" ? undefined : { kind: "project", id: "project-a" };
}

test("workspace quota facade derives tenant, validates metric/action mapping, and rejects substitution", async () => {
  const instance = harness();
  await activate(instance);
  await activate(instance, TEST_ONLY_QUOTA_POLICY_V1, "workspace-b");
  assert.deepEqual(WORKSPACE_QUOTA_ALLOCATION_ACTIONS, {
    project_count: "project.create",
    working_bytes: "project.revise",
    raw_bytes: "raw_archive.allocate",
    portal_bytes: "publication.create",
  });
  assert.deepEqual(Object.getOwnPropertyNames(WorkspaceQuotaService.prototype).sort(), ["constructor", "finalize", "release", "reserve", "snapshot"]);
  const result = await instance.workspaceQuota.reserve({
    accessToken: "editor-a",
    metric: "project_count",
    amount: 1,
    idempotencyKey: "tenant-derived",
    workspaceId: "workspace-b",
  } as Parameters<WorkspaceQuotaService["reserve"]>[0] & { workspaceId: string });
  assert.equal(result.reservation.workspaceId, "workspace-a");
  assert.equal((await instance.repository.quotaSnapshot("workspace-b", "project_count", NON_PERIODIC_QUOTA_PERIOD_KEY))?.reserved, 0);

  await assert.rejects(
    instance.workspaceQuota.reserve({
      accessToken: "editor-a",
      metric: "working_bytes",
      amount: 1,
      idempotencyKey: "cross-tenant-resource",
      resource: { kind: "project", id: "project-b" },
    }),
    (error: unknown) => error instanceof QuotaError && error.code === "operation_disabled",
  );
  assert.equal((await instance.workspaceQuota.reserve({
    accessToken: "editor-a",
    metric: "working_bytes",
    amount: 1,
    idempotencyKey: "same-tenant-resource",
    resource: { kind: "project", id: "project-a" },
  })).reservation.workspaceId, "workspace-a");
  await assert.rejects(
    instance.workspaceQuota.reserve({ accessToken: "owner-a", metric: "member_count", amount: 1, idempotencyKey: "not-client" } as never),
    (error: unknown) => error instanceof QuotaError && error.code === "invalid_request",
  );
});

test("system quota operations reject every workspace role and accept only the explicit system capability", async () => {
  const instance = harness();
  const roleContexts = WORKSPACE_ROLES.map((role) => context(`principal-${role}`, "workspace-a", role));
  for (const capability of roleContexts) {
    for (const operation of [
      () => instance.systemQuota.activatePolicy({ capability, workspaceId: "workspace-a", policy: TEST_ONLY_QUOTA_POLICY_V1 }),
      () => instance.systemQuota.reconcile({ capability, workspaceId: "workspace-a", metric: "project_count", periodKey: NON_PERIODIC_QUOTA_PERIOD_KEY, generation: 1, authoritativeUsed: 0 }),
      () => instance.systemQuota.expire({ capability, workspaceId: "workspace-a", periodKey: NON_PERIODIC_QUOTA_PERIOD_KEY, idempotencyKey: "missing" }),
    ]) {
      await assert.rejects(operation, (error: unknown) => error instanceof QuotaError && error.code === "system_authorization_required");
    }
  }
  await activate(instance);
});

test("all client allocation metrics use their fixed action and remain idempotent", async () => {
  for (const metric of Object.keys(WORKSPACE_QUOTA_ALLOCATION_ACTIONS) as WorkspaceAllocatableQuotaMetric[]) {
    const instance = harness();
    await activate(instance);
    const resource = resourceFor(metric);
    const input: Parameters<WorkspaceQuotaService["reserve"]>[0] = {
      accessToken: "owner-a",
      metric,
      amount: 1,
      idempotencyKey: `fixed-${metric}`,
      ...(resource === undefined ? {} : { resource }),
    };
    const first = await instance.workspaceQuota.reserve(input);
    assert.equal(first.reservation.authorizationAction, WORKSPACE_QUOTA_ALLOCATION_ACTIONS[metric]);
    assert.deepEqual(await instance.workspaceQuota.reserve(input), first);
    const finalized = await instance.workspaceQuota.finalize({
      accessToken: "owner-a",
      reservationReference: first.reservationReference,
      actualAmount: 1,
    });
    assert.equal(finalized.usage.used, 1);
  }
});

test("portal usage, reservations, idempotency, and reconciliation are isolated by versioned periods without history deletion", async () => {
  const instance = harness();
  await activate(instance);
  const periodOne = TEST_ONLY_QUOTA_POLICY_V1.portalPeriodKey;
  const reserveInput = {
    accessToken: "owner-a",
    metric: "portal_bytes" as const,
    amount: 10,
    idempotencyKey: "same-across-periods",
    resource: { kind: "project", id: "project-a" },
  };
  const first = await instance.workspaceQuota.reserve(reserveInput);
  await instance.workspaceQuota.finalize({
    accessToken: "owner-a",
    reservationReference: first.reservationReference,
    actualAmount: 10,
  });
  assert.equal(first.reservation.periodKey, periodOne);

  const periodTwo = "roomscan-period-v1:test-period-2";
  await activate(instance, policy(2, periodTwo));
  const second = await instance.workspaceQuota.reserve(reserveInput);
  assert.equal(second.reservation.periodKey, periodTwo);
  assert.notDeepEqual(second.reservation, first.reservation);
  assert.equal((await instance.repository.quotaSnapshot("workspace-a", "portal_bytes", periodOne))?.used, 10);
  assert.equal((await instance.workspaceQuota.snapshot({ accessToken: "viewer-a", metric: "portal_bytes" })).used, 0);

  const decreased = await instance.systemQuota.reconcile({
    capability: instance.systemCapability,
    workspaceId: "workspace-a",
    metric: "portal_bytes",
    periodKey: periodOne,
    generation: 2,
    authoritativeUsed: 3,
  });
  assert.equal(decreased.applied, true);
  assert.equal(decreased.usage.used, 3);
  assert.equal((await instance.repository.quotaSnapshot("workspace-a", "portal_bytes", periodTwo))?.reserved, 10);
  assert.deepEqual(instance.repository.retainedRecords, [{ id: "project-1", bytes: Uint8Array.from([1, 2, 3]) }]);
});

test("a newer reconciliation generation may authoritatively decrease usage while stale/conflicting generations fail closed", async () => {
  const instance = harness();
  await activate(instance);
  const base = { capability: instance.systemCapability, workspaceId: "workspace-a", metric: "project_count" as const, periodKey: NON_PERIODIC_QUOTA_PERIOD_KEY };
  assert.equal((await instance.systemQuota.reconcile({ ...base, generation: 1, authoritativeUsed: 3 })).usage.used, 3);
  const decrease = await instance.systemQuota.reconcile({ ...base, generation: 2, authoritativeUsed: 1 });
  assert.equal(decrease.applied, true);
  assert.equal(decrease.usage.used, 1);
  assert.equal((await instance.systemQuota.reconcile({ ...base, generation: 1, authoritativeUsed: 3 })).applied, false);
  await assert.rejects(
    instance.systemQuota.reconcile({ ...base, generation: 2, authoritativeUsed: 2 }),
    (error: unknown) => error instanceof QuotaError && error.code === "idempotency_key_reused",
  );
});

test("quota persistence rejects a disable or stale grant between authorization and mutation", async () => {
  const instance = harness();
  await activate(instance);
  instance.repository.beforeConfirm = () => {
    instance.gate.enabled = false;
    instance.gate.workspaceVersions.set("workspace-a", 2);
  };
  await assert.rejects(
    instance.workspaceQuota.reserve({ accessToken: "owner-a", metric: "project_count", amount: 1, idempotencyKey: "freeze-race" }),
    (error: unknown) => error instanceof QuotaError && error.code === "operation_disabled",
  );
  assert.equal(await instance.repository.reservation("workspace-a", NON_PERIODIC_QUOTA_PERIOD_KEY, "freeze-race"), undefined);

  instance.gate.enabled = true;
  const reservation = await instance.workspaceQuota.reserve({ accessToken: "owner-a", metric: "project_count", amount: 1, idempotencyKey: "freeze-finalize" });
  assert.equal(reservation.reservation.state, "reserved");
  instance.repository.beforeConfirm = () => {
    instance.gate.globalVersion += 1;
  };
  await assert.rejects(
    instance.workspaceQuota.finalize({
      accessToken: "owner-a",
      reservationReference: reservation.reservationReference,
      actualAmount: 1,
    }),
    (error: unknown) => error instanceof QuotaError && error.code === "operation_disabled",
  );
  assert.equal((await instance.repository.reservation("workspace-a", NON_PERIODIC_QUOTA_PERIOD_KEY, "freeze-finalize"))?.state, "reserved");
});

test("terminal quota calls select the exact server-issued period reference across rollover", async () => {
  const instance = harness();
  await activate(instance);
  const sharedIdempotencyKey = "same-in-lifetime-old-and-current";
  const resource = { kind: "project", id: "project-a" } as const;
  const lifetime = await instance.workspaceQuota.reserve({
    accessToken: "owner-a",
    metric: "project_count",
    amount: 1,
    idempotencyKey: sharedIdempotencyKey,
  });
  const oldFinalize = await instance.workspaceQuota.reserve({
    accessToken: "owner-a",
    metric: "portal_bytes",
    amount: 4,
    idempotencyKey: sharedIdempotencyKey,
    resource,
  });
  const oldRelease = await instance.workspaceQuota.reserve({
    accessToken: "owner-a",
    metric: "portal_bytes",
    amount: 5,
    idempotencyKey: "release-after-rollover",
    resource,
  });

  const currentPeriod = "roomscan-period-v1:test-period-2";
  await activate(instance, policy(2, currentPeriod));
  const current = await instance.workspaceQuota.reserve({
    accessToken: "owner-a",
    metric: "portal_bytes",
    amount: 6,
    idempotencyKey: sharedIdempotencyKey,
    resource,
  });

  await assert.rejects(
    instance.workspaceQuota.finalize({
      accessToken: "editor-b",
      reservationReference: {
        ...oldFinalize.reservationReference,
        workspaceId: "workspace-a",
      } as typeof oldFinalize.reservationReference & { workspaceId: string },
      actualAmount: 3,
    }),
    (error: unknown) => error instanceof QuotaError && error.code === "reservation_not_found",
  );

  await instance.workspaceQuota.finalize({
    accessToken: "owner-a",
    reservationReference: oldFinalize.reservationReference,
    actualAmount: 3,
  });
  await instance.workspaceQuota.release({
    accessToken: "owner-a",
    reservationReference: oldRelease.reservationReference,
  });
  await instance.workspaceQuota.release({
    accessToken: "owner-a",
    reservationReference: lifetime.reservationReference,
  });

  assert.equal((await instance.repository.reservation("workspace-a", oldFinalize.reservation.periodKey, sharedIdempotencyKey))?.state, "finalized");
  assert.equal((await instance.repository.reservation("workspace-a", oldRelease.reservation.periodKey, "release-after-rollover"))?.state, "released");
  assert.equal((await instance.repository.reservation("workspace-a", lifetime.reservation.periodKey, sharedIdempotencyKey))?.state, "released");
  assert.equal((await instance.repository.reservation("workspace-a", current.reservation.periodKey, sharedIdempotencyKey))?.state, "reserved");
});

test("portal allocation binds publication versions at persistence while non-publication quota does not", async () => {
  const disabled = harness();
  await activate(disabled);
  disabled.repository.beforeConfirm = () => {
    disabled.gate.publicationGlobalEnabled = false;
    disabled.gate.publicationGlobalVersion = 2;
  };
  await assert.rejects(
    disabled.workspaceQuota.reserve({
      accessToken: "owner-a",
      metric: "portal_bytes",
      amount: 1,
      idempotencyKey: "publication-disabled-after-authorization",
      resource: { kind: "project", id: "project-a" },
    }),
    (error: unknown) => error instanceof QuotaError && error.code === "operation_disabled",
  );
  assert.equal(
    await disabled.repository.reservation(
      "workspace-a",
      TEST_ONLY_QUOTA_POLICY_V1.portalPeriodKey,
      "publication-disabled-after-authorization",
    ),
    undefined,
  );

  const reenabled = harness();
  await activate(reenabled);
  reenabled.repository.beforeConfirm = () => {
    reenabled.gate.publicationWorkspaceEnabled.set("workspace-a", false);
    reenabled.gate.publicationWorkspaceVersions.set("workspace-a", 2);
    reenabled.gate.publicationWorkspaceEnabled.set("workspace-a", true);
    reenabled.gate.publicationWorkspaceVersions.set("workspace-a", 3);
  };
  await assert.rejects(
    reenabled.workspaceQuota.reserve({
      accessToken: "owner-a",
      metric: "portal_bytes",
      amount: 1,
      idempotencyKey: "publication-reenabled-after-authorization",
      resource: { kind: "project", id: "project-a" },
    }),
    (error: unknown) => error instanceof QuotaError && error.code === "operation_disabled",
  );

  const nonPublication = harness();
  await activate(nonPublication);
  nonPublication.gate.publicationGlobalEnabled = false;
  nonPublication.gate.publicationGlobalVersion = 2;
  const project = await nonPublication.workspaceQuota.reserve({
    accessToken: "owner-a",
    metric: "project_count",
    amount: 1,
    idempotencyKey: "project-needs-hosted-only",
  });
  assert.equal(project.reservation.authorizationAction, "project.create");
});

test("policy activation seeds and reconciles member_count from the authoritative slot ledger", async () => {
  const instance = harness();
  await activate(instance);
  assert.equal(
    (await instance.repository.quotaSnapshot(
      "workspace-a",
      "member_count",
      NON_PERIODIC_QUOTA_PERIOD_KEY,
    ))?.used,
    1,
    "the first workspace Owner is never activated as zero members",
  );

  instance.repository.activeMemberSlots.add("workspace-a\u0000active-editor");
  await activate(instance, policy(2));
  assert.equal(
    (await instance.repository.quotaSnapshot(
      "workspace-a",
      "member_count",
      NON_PERIODIC_QUOTA_PERIOD_KEY,
    ))?.used,
    2,
    "later activation reconciles from current active slots",
  );
});

test("the only bundled quota policy is explicit test-only 3/2/10/20/30 MiB at 80 percent", () => {
  assert.deepEqual(TEST_ONLY_QUOTA_POLICY_V1, {
    schemaVersion: "roomscan-quota-policy-v1",
    classification: "test-only",
    version: 1,
    portalPeriodKey: "roomscan-period-v1:test-period",
    limits: {
      project_count: 3,
      member_count: 2,
      working_bytes: 10 * 1024 * 1024,
      raw_bytes: 20 * 1024 * 1024,
      portal_bytes: 30 * 1024 * 1024,
    },
    warningThresholdPercent: 80,
  });
});

test("test-only values cannot enter an operator-approved policy composition", async () => {
  const instance = harness("operator-approved");
  await assert.rejects(
    activate(instance),
    (error: unknown) => error instanceof QuotaError && error.code === "invalid_request",
  );
});

test("all five dimensions preserve exact limit and warning behavior", async () => {
  for (const metric of Object.keys(WORKSPACE_QUOTA_ALLOCATION_ACTIONS) as WorkspaceAllocatableQuotaMetric[]) {
    const instance = harness();
    await activate(instance);
    const limit = TEST_ONLY_QUOTA_POLICY_V1.limits[metric];
    const warningAmount = Math.ceil(limit * 0.8);
    const resource = resourceFor(metric);
    const first = await instance.workspaceQuota.reserve({
      accessToken: "owner-a",
      metric,
      amount: warningAmount,
      idempotencyKey: `${metric}-warning`,
      ...(resource === undefined ? {} : { resource }),
    });
    assert.equal(first.usage.warning, true, `${metric} warning`);
    await instance.workspaceQuota.finalize({
      accessToken: "owner-a",
      reservationReference: first.reservationReference,
      actualAmount: warningAmount,
    });
    const remaining = limit - warningAmount;
    if (remaining > 0) {
      await instance.workspaceQuota.reserve({
        accessToken: "owner-a",
        metric,
        amount: remaining,
        idempotencyKey: `${metric}-boundary`,
        ...(resource === undefined ? {} : { resource }),
      });
    }
    const atLimit = await instance.workspaceQuota.snapshot({ accessToken: "viewer-a", metric });
    assert.equal(atLimit.used + atLimit.reserved, limit, `${metric} exact limit`);
    await assert.rejects(
      instance.workspaceQuota.reserve({
        accessToken: "owner-a",
        metric,
        amount: 1,
        idempotencyKey: `${metric}-over`,
        ...(resource === undefined ? {} : { resource }),
      }),
      (error: unknown) => error instanceof QuotaError && error.code === "quota_exceeded",
      `${metric} over limit`,
    );
  }

  const members = harness();
  members.repository.activeMemberSlots.add("workspace-a\u0000active-editor");
  await activate(members);
  const memberAtLimit = await members.workspaceQuota.snapshot({
    accessToken: "viewer-a",
    metric: "member_count",
  });
  assert.equal(memberAtLimit.used, TEST_ONLY_QUOTA_POLICY_V1.limits.member_count);
  assert.equal(memberAtLimit.warning, true);
  assert.equal(memberAtLimit.overLimit, false);
});

test("warning arithmetic remains exact at safe-integer storage limits", async () => {
  const instance = harness();
  const limit = Number.MAX_SAFE_INTEGER;
  const justBelowEightyPercent = Number((BigInt(limit) * 80n - 1n) / 100n);
  await activate(instance, policy(1, TEST_ONLY_QUOTA_POLICY_V1.portalPeriodKey, {
    ...TEST_ONLY_QUOTA_POLICY_V1.limits,
    working_bytes: limit,
  }));
  const reservation = await instance.workspaceQuota.reserve({
    accessToken: "owner-a",
    metric: "working_bytes",
    amount: justBelowEightyPercent,
    idempotencyKey: "large-exact-warning",
    resource: { kind: "project", id: "project-a" },
  });
  assert.equal(reservation.usage.warning, false);
});

test("one remaining project slot admits one concurrent reservation", async () => {
  const instance = harness();
  await activate(instance);
  const used = await instance.workspaceQuota.reserve({
    accessToken: "owner-a",
    metric: "project_count",
    amount: 2,
    idempotencyKey: "used-two",
  });
  await instance.workspaceQuota.finalize({
    accessToken: "owner-a",
    reservationReference: used.reservationReference,
    actualAmount: 2,
  });
  const results = await Promise.allSettled([
    instance.workspaceQuota.reserve({ accessToken: "owner-a", metric: "project_count", amount: 1, idempotencyKey: "racer-a" }),
    instance.workspaceQuota.reserve({ accessToken: "owner-a", metric: "project_count", amount: 1, idempotencyKey: "racer-b" }),
  ]);
  assert.equal(results.filter((result) => result.status === "fulfilled").length, 1);
  assert.equal(results.filter((result) => result.status === "rejected").length, 1);
  assert.equal((await instance.workspaceQuota.snapshot({ accessToken: "viewer-a", metric: "project_count" })).reserved, 1);
});

test("v2 reserve/finalize/release retries are idempotent and terminal conflicts fail closed", async () => {
  const instance = harness();
  await activate(instance);
  const input = { accessToken: "owner-a", metric: "project_count" as const, amount: 2, idempotencyKey: "request-a" };
  const reserved = await instance.workspaceQuota.reserve(input);
  assert.deepEqual(await instance.workspaceQuota.reserve(input), reserved);
  await assert.rejects(
    instance.workspaceQuota.reserve({ ...input, amount: 1 }),
    (error: unknown) => error instanceof QuotaError && error.code === "idempotency_key_reused",
  );
  const finalized = await instance.workspaceQuota.finalize({
    accessToken: "owner-a",
    reservationReference: reserved.reservationReference,
    actualAmount: 1,
  });
  assert.deepEqual(await instance.workspaceQuota.finalize({
    accessToken: "owner-a",
    reservationReference: reserved.reservationReference,
    actualAmount: 1,
  }), finalized);
  await assert.rejects(
    instance.workspaceQuota.finalize({
      accessToken: "owner-a",
      reservationReference: reserved.reservationReference,
      actualAmount: 2,
    }),
    (error: unknown) => error instanceof QuotaError && error.code === "idempotency_key_reused",
  );
  await assert.rejects(
    instance.workspaceQuota.release({ accessToken: "owner-a", reservationReference: reserved.reservationReference }),
    (error: unknown) => error instanceof QuotaError && error.code === "reservation_finalized",
  );

  const crash = await instance.workspaceQuota.reserve({
    accessToken: "owner-a",
    metric: "project_count",
    amount: 1,
    idempotencyKey: "crash-release",
  });
  const released = await instance.workspaceQuota.release({
    accessToken: "owner-a",
    reservationReference: crash.reservationReference,
  });
  assert.equal(released.reservation.state, "released");
  assert.deepEqual(await instance.workspaceQuota.release({
    accessToken: "owner-a",
    reservationReference: crash.reservationReference,
  }), released);
  await assert.rejects(
    instance.workspaceQuota.finalize({
      accessToken: "owner-a",
      reservationReference: crash.reservationReference,
      actualAmount: 1,
    }),
    (error: unknown) => error instanceof QuotaError && error.code === "reservation_released",
  );
});

test("v2 expiry/finalize race has one durable terminal state", async () => {
  const instance = harness();
  await activate(instance);
  const reserved = await instance.workspaceQuota.reserve({
    accessToken: "owner-a",
    metric: "project_count",
    amount: 1,
    idempotencyKey: "race",
  });
  instance.clock.now = 15_000;
  await Promise.allSettled([
    instance.workspaceQuota.finalize({
      accessToken: "owner-a",
      reservationReference: reserved.reservationReference,
      actualAmount: 1,
    }),
    instance.systemQuota.expire({
      capability: instance.systemCapability,
      workspaceId: "workspace-a",
      periodKey: reserved.reservation.periodKey,
      idempotencyKey: reserved.reservation.idempotencyKey,
    }),
  ]);
  const reservation = await instance.repository.reservation(
    "workspace-a",
    reserved.reservation.periodKey,
    reserved.reservation.idempotencyKey,
  );
  assert.ok(reservation);
  assert.notEqual(reservation.state, "reserved");
  const usage = await instance.workspaceQuota.snapshot({ accessToken: "viewer-a", metric: "project_count" });
  assert.equal(usage.reserved, 0);
  assert.ok(usage.used === 0 || usage.used === 1);
});

test("v2 authoritative reconciliation remains isolated across all five dimensions", async () => {
  const instance = harness();
  await activate(instance);
  for (const [index, metric] of QUOTA_METRICS.entries()) {
    const periodKey = metric === "portal_bytes"
      ? TEST_ONLY_QUOTA_POLICY_V1.portalPeriodKey
      : NON_PERIODIC_QUOTA_PERIOD_KEY;
    const result = await instance.systemQuota.reconcile({
      capability: instance.systemCapability,
      workspaceId: "workspace-a",
      metric,
      periodKey,
      generation: index + 1,
      authoritativeUsed: index + 1,
    });
    assert.equal(result.applied, true, metric);
    assert.equal(result.usage.used, index + 1, metric);
  }
});

test("v2 downgrade warns without deleting records or weakening reads", async () => {
  const instance = harness();
  await activate(instance);
  const base = {
    capability: instance.systemCapability,
    workspaceId: "workspace-a",
    metric: "project_count" as const,
    periodKey: NON_PERIODIC_QUOTA_PERIOD_KEY,
  };
  await instance.systemQuota.reconcile({ ...base, generation: 2, authoritativeUsed: 2 });
  await activate(instance, policy(2, TEST_ONLY_QUOTA_POLICY_V1.portalPeriodKey, {
    ...TEST_ONLY_QUOTA_POLICY_V1.limits,
    project_count: 1,
  }));
  const overLimit = await instance.workspaceQuota.snapshot({ accessToken: "viewer-a", metric: "project_count" });
  assert.equal(overLimit.overLimit, true);
  assert.equal(overLimit.warning, true);
  assert.equal(overLimit.allocationsAllowed, false);
  instance.gate.enabled = false;
  assert.equal((await instance.workspaceQuota.snapshot({ accessToken: "viewer-a", metric: "project_count" })).used, 2);
  await assert.rejects(
    instance.workspaceQuota.reserve({ accessToken: "owner-a", metric: "project_count", amount: 1, idempotencyKey: "denied-new" }),
    (error: unknown) => error instanceof QuotaError && error.code === "operation_disabled",
  );
  assert.deepEqual(instance.repository.retainedRecords, [{ id: "project-1", bytes: Uint8Array.from([1, 2, 3]) }]);
});
