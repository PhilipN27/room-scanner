import { isPublicationAction, type AuthorizationAction } from "../authorization/policy.js";
import type {
  AuthorizationResourceReference,
  AuthorizedWorkspaceContext,
} from "../authorization/authorizer.js";
import type { HostedMutationGrant } from "../operations/operational-flags.js";

export const QUOTA_METRICS = [
  "project_count",
  "member_count",
  "working_bytes",
  "raw_bytes",
  "portal_bytes",
] as const;
export type QuotaMetric = (typeof QUOTA_METRICS)[number];
export type WorkspaceAllocatableQuotaMetric = Exclude<QuotaMetric, "member_count">;

export const WORKSPACE_QUOTA_ALLOCATION_ACTIONS = Object.freeze({
  project_count: "project.create",
  working_bytes: "project.revise",
  raw_bytes: "raw_archive.allocate",
  portal_bytes: "publication.create",
} as const satisfies Readonly<Record<WorkspaceAllocatableQuotaMetric, AuthorizationAction>>);
export type WorkspaceQuotaAllocationAction =
  (typeof WORKSPACE_QUOTA_ALLOCATION_ACTIONS)[WorkspaceAllocatableQuotaMetric];

export const NON_PERIODIC_QUOTA_PERIOD_KEY = "roomscan-period-v1:lifetime" as const;

export interface QuotaPolicy {
  readonly schemaVersion: "roomscan-quota-policy-v1";
  readonly classification: "test-only" | "operator-approved";
  readonly version: number;
  readonly portalPeriodKey: string;
  readonly limits: Readonly<Record<QuotaMetric, number>>;
  readonly warningThresholdPercent: number;
}

export const TEST_ONLY_QUOTA_POLICY_V1: QuotaPolicy = Object.freeze({
  schemaVersion: "roomscan-quota-policy-v1",
  classification: "test-only",
  version: 1,
  portalPeriodKey: "roomscan-period-v1:test-period",
  limits: Object.freeze({
    project_count: 3,
    member_count: 2,
    working_bytes: 10 * 1024 * 1024,
    raw_bytes: 20 * 1024 * 1024,
    portal_bytes: 30 * 1024 * 1024,
  }),
  warningThresholdPercent: 80,
});

export interface QuotaUsageRecord {
  readonly workspaceId: string;
  readonly metric: QuotaMetric;
  readonly periodKey: string;
  readonly policyVersion: number;
  readonly used: number;
  readonly reserved: number;
  readonly limit: number;
  readonly warningThresholdPercent: number;
  readonly reconciliationGeneration: number;
}

export interface QuotaSnapshot extends QuotaUsageRecord {
  readonly warning: boolean;
  readonly overLimit: boolean;
  readonly remaining: number;
  readonly allocationsAllowed: boolean;
}

export interface QuotaReservation {
  readonly workspaceId: string;
  readonly periodKey: string;
  readonly idempotencyKey: string;
  readonly metric: WorkspaceAllocatableQuotaMetric;
  readonly authorizationAction: WorkspaceQuotaAllocationAction;
  readonly authorizationResource?: AuthorizationResourceReference;
  readonly requestedAmount: number;
  readonly policyVersion: number;
  readonly expiresAtMs: number;
  readonly state: "reserved" | "finalized" | "released";
  readonly createdAtMs: number;
  readonly finalizedAmount?: number;
  readonly finalizedAtMs?: number;
  readonly releasedAtMs?: number;
  readonly releaseReason?: "released" | "expired";
}

/** Opaque-to-clients routing data returned by reserve; never contains tenant scope. */
export interface QuotaReservationReference {
  readonly kind: "quota-reservation-reference-v1";
  readonly periodKey: string;
  readonly idempotencyKey: string;
}

export interface QuotaMutationResult {
  readonly reservationReference: QuotaReservationReference;
  readonly reservation: QuotaReservation;
  readonly usage: QuotaSnapshot;
}

export interface QuotaReconciliation {
  readonly workspaceId: string;
  readonly metric: QuotaMetric;
  readonly periodKey: string;
  readonly generation: number;
  readonly authoritativeUsed: number;
}

export interface QuotaPolicyActivationResult {
  /** Counted from the authoritative active-membership slot ledger in this transaction. */
  readonly authoritativeActiveMemberCount: number;
}

export interface QuotaTransaction {
  /** Compare action and all required flag versions/enabled state in this transaction. */
  confirmHostedMutation(grant: HostedMutationGrant): Promise<boolean>;
  activePolicy(workspaceId: string): Promise<QuotaPolicy | undefined>;
  /** Atomically activates policy and seeds/reconciles member_count from active slots. */
  activatePolicy(workspaceId: string, policy: QuotaPolicy): Promise<QuotaPolicyActivationResult>;
  quotaSnapshot(workspaceId: string, metric: QuotaMetric, periodKey: string): Promise<QuotaUsageRecord | undefined>;
  reservation(workspaceId: string, periodKey: string, idempotencyKey: string): Promise<QuotaReservation | undefined>;
  reserve(input: {
    readonly workspaceId: string;
    readonly metric: WorkspaceAllocatableQuotaMetric;
    readonly periodKey: string;
    readonly authorizationAction: WorkspaceQuotaAllocationAction;
    readonly authorizationResource?: AuthorizationResourceReference;
    readonly amount: number;
    readonly idempotencyKey: string;
    readonly policyVersion: number;
    readonly expiresAtMs: number;
    readonly nowMs: number;
  }): Promise<QuotaReservation>;
  finalize(input: {
    readonly workspaceId: string;
    readonly periodKey: string;
    readonly idempotencyKey: string;
    readonly actualAmount: number;
    readonly nowMs: number;
  }): Promise<QuotaReservation>;
  release(input: {
    readonly workspaceId: string;
    readonly periodKey: string;
    readonly idempotencyKey: string;
    readonly nowMs: number;
    readonly reason: "released" | "expired";
  }): Promise<QuotaReservation>;
  reconcile(input: QuotaReconciliation): Promise<{ readonly applied: boolean; readonly snapshot: QuotaUsageRecord }>;
}

export interface QuotaRepository {
  transaction<T>(work: (transaction: QuotaTransaction) => Promise<T>): Promise<T>;
}

export interface WorkspaceQuotaAuthorizer {
  authorize(input: {
    readonly accessToken: string;
    readonly action: AuthorizationAction;
    readonly resource?: AuthorizationResourceReference;
  }): Promise<AuthorizedWorkspaceContext>;
}

export type SystemQuotaOperation = "policy.activate" | "reservation.expire" | "usage.reconcile";
export interface SystemQuotaAuthorizer {
  authorize(input: {
    readonly capability: unknown;
    readonly action: "system.quota_policy.change";
    readonly operation: SystemQuotaOperation;
  }): Promise<boolean>;
}

export interface QuotaHostedGate {
  hostedMutationGrant(workspaceId: string, action: AuthorizationAction): Promise<HostedMutationGrant>;
}

export type QuotaErrorCode =
  | "invalid_request"
  | "operation_disabled"
  | "policy_missing"
  | "policy_not_forward"
  | "quota_exceeded"
  | "idempotency_key_reused"
  | "reservation_not_found"
  | "reservation_released"
  | "reservation_finalized"
  | "not_expired"
  | "persistence_invariant"
  | "system_authorization_required";

export class QuotaError extends Error {
  constructor(readonly code: QuotaErrorCode) {
    super(code);
    this.name = "QuotaError";
  }
}

interface WorkspaceQuotaDependencies {
  readonly clock: { nowMs(): number };
  readonly repository: QuotaRepository;
  readonly authorizer: WorkspaceQuotaAuthorizer;
  readonly hostedGate: QuotaHostedGate;
  readonly reservationTtlMs: number;
}

/** Client-reachable quota operations. Workspace scope is always session-derived. */
export class WorkspaceQuotaService {
  constructor(private readonly dependencies: WorkspaceQuotaDependencies) {}

  async snapshot(input: { readonly accessToken: string; readonly metric: QuotaMetric }): Promise<QuotaSnapshot> {
    requireMetric(input.metric);
    const context = await this.dependencies.authorizer.authorize({
      accessToken: input.accessToken,
      action: "quota.warning.read",
    });
    return this.dependencies.repository.transaction(async (transaction) => {
      const policy = await requireActivePolicy(transaction, context.workspaceId);
      return snapshotFor(transaction, context.workspaceId, input.metric, periodFor(policy, input.metric));
    });
  }

  async reserve(input: {
    readonly accessToken: string;
    readonly metric: WorkspaceAllocatableQuotaMetric;
    readonly amount: number;
    readonly idempotencyKey: string;
    readonly resource?: AuthorizationResourceReference;
  }): Promise<QuotaMutationResult> {
    requireWorkspaceAllocatableMetric(input.metric);
    requirePositiveInteger(input.amount);
    requireIdempotencyKey(input.idempotencyKey);
    const action = WORKSPACE_QUOTA_ALLOCATION_ACTIONS[input.metric];
    const context = await this.dependencies.authorizer.authorize({
      accessToken: input.accessToken,
      action,
      ...(input.resource === undefined ? {} : { resource: input.resource }),
    });
    const grant = await mutationGrant(this.dependencies.hostedGate, context.workspaceId, action);
    const nowMs = this.dependencies.clock.nowMs();
    if (!Number.isSafeInteger(nowMs) || !Number.isSafeInteger(this.dependencies.reservationTtlMs) || this.dependencies.reservationTtlMs <= 0) {
      throw new QuotaError("invalid_request");
    }

    return this.dependencies.repository.transaction(async (transaction) => {
      await confirmMutation(transaction, grant);
      const policy = await requireActivePolicy(transaction, context.workspaceId);
      const periodKey = periodFor(policy, input.metric);
      const reservation = await transaction.reserve({
        workspaceId: context.workspaceId,
        metric: input.metric,
        periodKey,
        authorizationAction: action,
        ...(input.resource === undefined ? {} : { authorizationResource: structuredClone(input.resource) }),
        amount: input.amount,
        idempotencyKey: input.idempotencyKey,
        policyVersion: policy.version,
        expiresAtMs: nowMs + this.dependencies.reservationTtlMs,
        nowMs,
      });
      validateReservation(reservation, context.workspaceId, periodKey, input.idempotencyKey);
      return {
        reservationReference: reservationReferenceFor(reservation),
        reservation,
        usage: await snapshotFor(transaction, context.workspaceId, reservation.metric, periodKey),
      };
    });
  }

  async finalize(input: {
    readonly accessToken: string;
    readonly reservationReference: QuotaReservationReference;
    readonly actualAmount: number;
  }): Promise<QuotaMutationResult> {
    requireNonnegativeAmount(input.actualAmount);
    return this.#mutateReservation(input, async (transaction, reservation, nowMs) => transaction.finalize({
      workspaceId: reservation.workspaceId,
      periodKey: reservation.periodKey,
      idempotencyKey: reservation.idempotencyKey,
      actualAmount: input.actualAmount,
      nowMs,
    }));
  }

  async release(input: {
    readonly accessToken: string;
    readonly reservationReference: QuotaReservationReference;
  }): Promise<QuotaMutationResult> {
    return this.#mutateReservation(input, async (transaction, reservation, nowMs) => transaction.release({
      workspaceId: reservation.workspaceId,
      periodKey: reservation.periodKey,
      idempotencyKey: reservation.idempotencyKey,
      nowMs,
      reason: "released",
    }));
  }

  async #mutateReservation(
    input: { readonly accessToken: string; readonly reservationReference: QuotaReservationReference },
    mutate: (transaction: QuotaTransaction, reservation: QuotaReservation, nowMs: number) => Promise<QuotaReservation>,
  ): Promise<QuotaMutationResult> {
    requireReservationReference(input.reservationReference);
    const scope = await this.dependencies.authorizer.authorize({
      accessToken: input.accessToken,
      action: "quota.warning.read",
    });
    const before = await this.dependencies.repository.transaction(async (transaction) => {
      const reservation = await transaction.reservation(
        scope.workspaceId,
        input.reservationReference.periodKey,
        input.reservationReference.idempotencyKey,
      );
      if (reservation === undefined) throw new QuotaError("reservation_not_found");
      return reservation;
    });
    validateReservation(
      before,
      scope.workspaceId,
      input.reservationReference.periodKey,
      input.reservationReference.idempotencyKey,
    );
    const context = await this.dependencies.authorizer.authorize({
      accessToken: input.accessToken,
      action: before.authorizationAction,
      ...(before.authorizationResource === undefined ? {} : { resource: before.authorizationResource }),
    });
    if (context.workspaceId !== scope.workspaceId) throw new QuotaError("operation_disabled");
    const grant = await mutationGrant(
      this.dependencies.hostedGate,
      context.workspaceId,
      before.authorizationAction,
    );
    const nowMs = this.dependencies.clock.nowMs();
    if (!Number.isSafeInteger(nowMs)) throw new QuotaError("invalid_request");
    return this.dependencies.repository.transaction(async (transaction) => {
      await confirmMutation(transaction, grant);
      const current = await transaction.reservation(
        context.workspaceId,
        input.reservationReference.periodKey,
        input.reservationReference.idempotencyKey,
      );
      if (current === undefined || !sameReservationAuthority(current, before)) throw new QuotaError("persistence_invariant");
      const reservation = await mutate(transaction, current, nowMs);
      validateReservation(
        reservation,
        context.workspaceId,
        input.reservationReference.periodKey,
        input.reservationReference.idempotencyKey,
      );
      return {
        reservationReference: reservationReferenceFor(reservation),
        reservation,
        usage: await snapshotFor(transaction, context.workspaceId, reservation.metric, reservation.periodKey),
      };
    });
  }
}

interface SystemQuotaDependencies {
  readonly clock: { nowMs(): number };
  readonly repository: QuotaRepository;
  readonly authorizer: SystemQuotaAuthorizer;
  readonly hostedGate: QuotaHostedGate;
  readonly acceptedPolicyClassification: QuotaPolicy["classification"];
}

/** Operator-only quota operations. This class is deliberately absent from client composition. */
export class SystemQuotaService {
  constructor(private readonly dependencies: SystemQuotaDependencies) {}

  async activatePolicy(input: { readonly capability: unknown; readonly workspaceId: string; readonly policy: QuotaPolicy }): Promise<void> {
    requireWorkspace(input.workspaceId);
    validatePolicy(input.policy);
    await this.#authorize(input.capability, "policy.activate");
    if (input.policy.classification !== this.dependencies.acceptedPolicyClassification) throw new QuotaError("invalid_request");
    const grant = await mutationGrant(
      this.dependencies.hostedGate,
      input.workspaceId,
      "system.quota_policy.change",
    );
    await this.dependencies.repository.transaction(async (transaction) => {
      await confirmMutation(transaction, grant);
      const current = await transaction.activePolicy(input.workspaceId);
      if (current !== undefined && input.policy.version <= current.version) throw new QuotaError("policy_not_forward");
      const activation = await transaction.activatePolicy(
        input.workspaceId,
        structuredClone(input.policy),
      );
      if (
        !Number.isSafeInteger(activation.authoritativeActiveMemberCount) ||
        activation.authoritativeActiveMemberCount <= 0
      ) throw new QuotaError("persistence_invariant");
      for (const metric of QUOTA_METRICS) {
        const periodKey = periodFor(input.policy, metric);
        const usage = await transaction.quotaSnapshot(input.workspaceId, metric, periodKey);
        if (usage === undefined || usage.periodKey !== periodKey || usage.policyVersion !== input.policy.version || usage.limit !== input.policy.limits[metric] || usage.warningThresholdPercent !== input.policy.warningThresholdPercent) {
          throw new QuotaError("persistence_invariant");
        }
        if (
          metric === "member_count" &&
          (usage.used !== activation.authoritativeActiveMemberCount || usage.reserved !== 0)
        ) throw new QuotaError("persistence_invariant");
        evaluateUsage(usage);
      }
    });
  }

  async expire(input: { readonly capability: unknown; readonly workspaceId: string; readonly periodKey: string; readonly idempotencyKey: string }): Promise<{ readonly reservation: QuotaReservation; readonly usage: QuotaSnapshot }> {
    requireWorkspace(input.workspaceId);
    requirePeriodKey(input.periodKey);
    requireIdempotencyKey(input.idempotencyKey);
    await this.#authorize(input.capability, "reservation.expire");
    const grant = await mutationGrant(
      this.dependencies.hostedGate,
      input.workspaceId,
      "system.quota_policy.change",
    );
    const nowMs = this.dependencies.clock.nowMs();
    if (!Number.isSafeInteger(nowMs)) throw new QuotaError("invalid_request");
    return this.dependencies.repository.transaction(async (transaction) => {
      await confirmMutation(transaction, grant);
      const before = await transaction.reservation(input.workspaceId, input.periodKey, input.idempotencyKey);
      if (before === undefined) throw new QuotaError("reservation_not_found");
      if (before.state === "reserved" && before.expiresAtMs > nowMs) throw new QuotaError("not_expired");
      const reservation = await transaction.release({
        workspaceId: input.workspaceId,
        periodKey: input.periodKey,
        idempotencyKey: input.idempotencyKey,
        nowMs,
        reason: "expired",
      });
      validateReservation(reservation, input.workspaceId, input.periodKey, input.idempotencyKey);
      return { reservation, usage: await snapshotFor(transaction, input.workspaceId, reservation.metric, input.periodKey) };
    });
  }

  async reconcile(input: {
    readonly capability: unknown;
    readonly workspaceId: string;
    readonly metric: QuotaMetric;
    readonly periodKey: string;
    readonly generation: number;
    readonly authoritativeUsed: number;
  }): Promise<{ readonly applied: boolean; readonly usage: QuotaSnapshot }> {
    requireWorkspace(input.workspaceId);
    requireMetric(input.metric);
    requirePeriodKey(input.periodKey);
    requirePositiveInteger(input.generation);
    requireNonnegativeAmount(input.authoritativeUsed);
    await this.#authorize(input.capability, "usage.reconcile");
    const grant = await mutationGrant(
      this.dependencies.hostedGate,
      input.workspaceId,
      "system.quota_policy.change",
    );
    return this.dependencies.repository.transaction(async (transaction) => {
      await confirmMutation(transaction, grant);
      if (await transaction.activePolicy(input.workspaceId) === undefined) throw new QuotaError("policy_missing");
      const result = await transaction.reconcile({
        workspaceId: input.workspaceId,
        metric: input.metric,
        periodKey: input.periodKey,
        generation: input.generation,
        authoritativeUsed: input.authoritativeUsed,
      });
      return { applied: result.applied, usage: evaluateUsage(result.snapshot) };
    });
  }

  async #authorize(capability: unknown, operation: SystemQuotaOperation): Promise<void> {
    let authorized = false;
    try {
      authorized = await this.dependencies.authorizer.authorize({
        capability,
        action: "system.quota_policy.change",
        operation,
      }) === true;
    } catch {
      authorized = false;
    }
    if (!authorized) throw new QuotaError("system_authorization_required");
  }
}

async function requireActivePolicy(transaction: QuotaTransaction, workspaceId: string): Promise<QuotaPolicy> {
  const policy = await transaction.activePolicy(workspaceId);
  if (policy === undefined) throw new QuotaError("policy_missing");
  validatePolicy(policy);
  return policy;
}

async function snapshotFor(transaction: QuotaTransaction, workspaceId: string, metric: QuotaMetric, periodKey: string): Promise<QuotaSnapshot> {
  const usage = await transaction.quotaSnapshot(workspaceId, metric, periodKey);
  if (usage === undefined) throw new QuotaError("policy_missing");
  return evaluateUsage(usage);
}

async function mutationGrant(
  gate: QuotaHostedGate,
  workspaceId: string,
  action: AuthorizationAction,
): Promise<HostedMutationGrant> {
  try {
    const grant = await gate.hostedMutationGrant(workspaceId, action);
    if (!validGrant(grant, workspaceId, action)) throw new Error("invalid grant");
    return grant;
  } catch {
    throw new QuotaError("operation_disabled");
  }
}

async function confirmMutation(transaction: QuotaTransaction, grant: HostedMutationGrant): Promise<void> {
  if (!await transaction.confirmHostedMutation(grant)) throw new QuotaError("operation_disabled");
}

function periodFor(policy: QuotaPolicy, metric: QuotaMetric): string {
  return metric === "portal_bytes" ? policy.portalPeriodKey : NON_PERIODIC_QUOTA_PERIOD_KEY;
}

function validatePolicy(policy: QuotaPolicy): void {
  if (policy.schemaVersion !== "roomscan-quota-policy-v1" || (policy.classification !== "test-only" && policy.classification !== "operator-approved") || !Number.isSafeInteger(policy.version) || policy.version < 1 || !validPeriodKey(policy.portalPeriodKey) || !Number.isSafeInteger(policy.warningThresholdPercent) || policy.warningThresholdPercent < 1 || policy.warningThresholdPercent > 100) {
    throw new QuotaError("invalid_request");
  }
  for (const metric of QUOTA_METRICS) requireNonnegativeAmount(policy.limits[metric]);
}

function evaluateUsage(usage: QuotaUsageRecord): QuotaSnapshot {
  requireWorkspace(usage.workspaceId);
  requireMetric(usage.metric);
  requirePeriodKey(usage.periodKey);
  requirePositiveInteger(usage.policyVersion);
  requireNonnegativeAmount(usage.used);
  requireNonnegativeAmount(usage.reserved);
  requireNonnegativeAmount(usage.limit);
  requireNonnegativeAmount(usage.reconciliationGeneration);
  if (!Number.isSafeInteger(usage.warningThresholdPercent) || usage.warningThresholdPercent < 1 || usage.warningThresholdPercent > 100 || !Number.isSafeInteger(usage.used + usage.reserved)) {
    throw new QuotaError("persistence_invariant");
  }
  const allocated = usage.used + usage.reserved;
  const warning = usage.limit === 0 || BigInt(allocated) * 100n >= BigInt(usage.limit) * BigInt(usage.warningThresholdPercent);
  const overLimit = allocated > usage.limit;
  const remaining = Math.max(0, usage.limit - allocated);
  return { ...structuredClone(usage), warning, overLimit, remaining, allocationsAllowed: !overLimit && remaining > 0 };
}

function validateReservation(reservation: QuotaReservation, workspaceId: string, periodKey: string, idempotencyKey: string): void {
  if (reservation.workspaceId !== workspaceId || reservation.periodKey !== periodKey || reservation.idempotencyKey !== idempotencyKey || !isWorkspaceAllocatableMetric(reservation.metric) || reservation.authorizationAction !== WORKSPACE_QUOTA_ALLOCATION_ACTIONS[reservation.metric] || !Number.isSafeInteger(reservation.requestedAmount) || reservation.requestedAmount <= 0 || !Number.isSafeInteger(reservation.policyVersion) || reservation.policyVersion <= 0 || !Number.isSafeInteger(reservation.expiresAtMs) || !Number.isSafeInteger(reservation.createdAtMs) || (reservation.state !== "reserved" && reservation.state !== "finalized" && reservation.state !== "released")) {
    throw new QuotaError("persistence_invariant");
  }
  requirePeriodKey(reservation.periodKey);
}

function sameReservationAuthority(left: QuotaReservation, right: QuotaReservation): boolean {
  return left.workspaceId === right.workspaceId && left.periodKey === right.periodKey && left.metric === right.metric && left.authorizationAction === right.authorizationAction && JSON.stringify(left.authorizationResource) === JSON.stringify(right.authorizationResource);
}

function validGrant(value: HostedMutationGrant, workspaceId: string, action: AuthorizationAction): boolean {
  if (
    value.kind !== "hosted-mutation-grant-v2" ||
    value.workspaceId !== workspaceId ||
    value.action !== action ||
    !Number.isSafeInteger(value.hostedGlobalFlagVersion) ||
    value.hostedGlobalFlagVersion <= 0 ||
    !Number.isSafeInteger(value.hostedWorkspaceFlagVersion) ||
    value.hostedWorkspaceFlagVersion <= 0
  ) return false;
  if (!isPublicationAction(action)) return true;
  return Number.isSafeInteger(value.publicationGlobalFlagVersion) &&
    (value.publicationGlobalFlagVersion ?? 0) > 0 &&
    Number.isSafeInteger(value.publicationWorkspaceFlagVersion) &&
    (value.publicationWorkspaceFlagVersion ?? 0) > 0;
}

function requireWorkspace(value: unknown): asserts value is string {
  if (typeof value !== "string" || value.length < 1 || value.length > 256) throw new QuotaError("invalid_request");
}

function requireMetric(value: unknown): asserts value is QuotaMetric {
  if (!QUOTA_METRICS.includes(value as QuotaMetric)) throw new QuotaError("invalid_request");
}

function isWorkspaceAllocatableMetric(value: unknown): value is WorkspaceAllocatableQuotaMetric {
  return typeof value === "string" && Object.hasOwn(WORKSPACE_QUOTA_ALLOCATION_ACTIONS, value);
}

function requireWorkspaceAllocatableMetric(value: unknown): asserts value is WorkspaceAllocatableQuotaMetric {
  if (!isWorkspaceAllocatableMetric(value)) throw new QuotaError("invalid_request");
}

function validPeriodKey(value: unknown): value is string {
  return typeof value === "string" && /^roomscan-period-v1:[A-Za-z0-9][A-Za-z0-9._:-]{0,95}$/u.test(value);
}

function requirePeriodKey(value: unknown): asserts value is string {
  if (!validPeriodKey(value)) throw new QuotaError("invalid_request");
}

function requireIdempotencyKey(value: unknown): asserts value is string {
  if (typeof value !== "string" || value.length < 1 || value.length > 200) throw new QuotaError("invalid_request");
}

function requireReservationReference(value: unknown): asserts value is QuotaReservationReference {
  if (
    typeof value !== "object" ||
    value === null ||
    (value as Partial<QuotaReservationReference>).kind !== "quota-reservation-reference-v1"
  ) throw new QuotaError("invalid_request");
  requirePeriodKey((value as Partial<QuotaReservationReference>).periodKey);
  requireIdempotencyKey((value as Partial<QuotaReservationReference>).idempotencyKey);
}

function reservationReferenceFor(reservation: QuotaReservation): QuotaReservationReference {
  return Object.freeze({
    kind: "quota-reservation-reference-v1",
    periodKey: reservation.periodKey,
    idempotencyKey: reservation.idempotencyKey,
  });
}

function requirePositiveInteger(value: unknown): asserts value is number {
  if (!Number.isSafeInteger(value) || (value as number) <= 0) throw new QuotaError("invalid_request");
}

function requireNonnegativeAmount(value: unknown): asserts value is number {
  if (!Number.isSafeInteger(value) || (value as number) < 0) throw new QuotaError("invalid_request");
}
