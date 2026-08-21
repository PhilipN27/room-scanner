import { createHash } from "node:crypto";
import type { AuthorizationAction } from "../authorization/policy.js";

/** Provider-neutral subset of RDS Data API values. The adapter chooses each
 * wire representation explicitly; an SDK wrapper only translates this shape. */
export type SqlWireValue =
  | { readonly kind: "blob"; readonly bytes: Uint8Array }
  | { readonly kind: "string"; readonly value: string; readonly typeHint?: "TIMESTAMP" | "UUID" }
  | { readonly kind: "long"; readonly value: number }
  | { readonly kind: "boolean"; readonly value: boolean }
  | { readonly kind: "null" };
export interface SqlParameter { readonly name: string; readonly value: SqlWireValue; }
export type SqlCell = string | number | boolean | Uint8Array | null;
export interface SqlResult { readonly rows: readonly Readonly<Record<string, SqlCell>>[]; }
export interface DataApiClient {
  begin(): Promise<{ readonly transactionId: string }>;
  execute(input: { readonly transactionId: string; readonly sql: string; readonly parameters?: readonly SqlParameter[] }): Promise<SqlResult>;
  commit(transactionId: string): Promise<void>;
  rollback(transactionId: string): Promise<void>;
}
export interface ResolvedAccessContext {
  /** Private database UUID. Never expose this as the app-owned public principal identifier. */
  readonly principalInternalId: string;
  readonly principalPublicId: string;
  /** Private database UUID, distinct from the opaque public family identifier. */
  readonly familyInternalId: string;
  readonly familyPublicId: string;
  readonly workspaceInternalId?: string;
  readonly role?: "owner" | "admin" | "editor" | "viewer";
  readonly authorizationVersion?: number;
  readonly authenticationEpoch: number;
  readonly authenticatedAt: string;
  readonly recentAuthentication: boolean;
}
export interface SqlStatement { readonly sql: string; readonly parameters?: readonly SqlParameter[]; }
/** SQL-only callback. No provider client, HTTP transport, or transaction ID. */
export interface SqlUnitOfWork { readonly context: ResolvedAccessContext; execute(statement: SqlStatement): Promise<SqlResult>; }
export interface SystemSqlUnitOfWork { execute(statement: SqlStatement): Promise<SqlResult>; }
export interface SystemTransactionAuthorizer { authorize(input: { readonly capability: unknown; readonly action: Extract<AuthorizationAction, `system.${string}`> }): Promise<boolean>; }
export class DataApiTransactionError extends Error { constructor(readonly code: "invalid_access" | "invalid_system_capability" | "duplicate_transaction" | "transaction_failed") { super(code); this.name = "DataApiTransactionError"; } }

const RESOLVE_ACCESS_SQL = "SELECT principal_id, canonical_principal_id, family_id, family_public_id, workspace_id, role, authorization_version, authentication_epoch, authenticated_at, recent_authentication FROM roomscan.resolve_access_context(:access_token_hash, (:authoritative_now)::timestamptz)";
const CLEAR_REQUEST_CONTEXT_SQL = "SELECT set_config('app.principal_id', '', true), set_config('app.tenant_id', '', true), set_config('app.authorization_version', '', true)";
const TRANSACTION_ID_REUSE_LEDGER_BYTES = 1_048_576;
const TRANSACTION_ID_REUSE_HASHES = 7;

/** Fixed-memory, fail-closed replay memory for provider transaction IDs.
 *
 * A Bloom ledger can report a false positive as it fills, which rejects and
 * rolls back a fresh transaction. It cannot forget an inserted ID or report a
 * false negative during this executor's lifetime. That trade keeps replay
 * rejection fail closed without retaining an unbounded Set of provider IDs.
 */
class TransactionIdReuseLedger {
  private readonly bits = new Uint8Array(TRANSACTION_ID_REUSE_LEDGER_BYTES);
  readonly byteLength = this.bits.byteLength;

  seenOrRemember(transactionId: string): boolean {
    const digest = createHash("sha256").update(transactionId, "utf8").digest();
    const bitCount = this.bits.byteLength * 8;
    const indexes: number[] = [];
    let seen = true;
    for (let hash = 0; hash < TRANSACTION_ID_REUSE_HASHES; hash++) {
      const offset = hash * 4;
      const word = (
        (((digest[offset] ?? 0) << 24) >>> 0)
        + ((digest[offset + 1] ?? 0) << 16)
        + ((digest[offset + 2] ?? 0) << 8)
        + (digest[offset + 3] ?? 0)
      ) >>> 0;
      const bitIndex = word % bitCount;
      indexes.push(bitIndex);
      const byteIndex = Math.floor(bitIndex / 8);
      const mask = 1 << (bitIndex % 8);
      if (((this.bits[byteIndex] ?? 0) & mask) === 0) seen = false;
    }
    for (const bitIndex of indexes) {
      const byteIndex = Math.floor(bitIndex / 8);
      this.bits[byteIndex] = (this.bits[byteIndex] ?? 0) | (1 << (bitIndex % 8));
    }
    return seen;
  }
}

export class DataApiTransactionExecutor {
  private readonly transactionIdReuseLedger = new TransactionIdReuseLedger();
  private readonly activeTransactionIds = new Set<string>();
  constructor(private readonly client: DataApiClient, private readonly systemAuthorizer: SystemTransactionAuthorizer) {}

  async accessTransaction<T>(accessTokenDigest: Uint8Array, authoritativeNow: Date, work: (unit: SqlUnitOfWork) => Promise<T>): Promise<T> {
    if (accessTokenDigest.length !== 32 || !validDate(authoritativeNow)) throw new DataApiTransactionError("invalid_access");
    return this.run(async (transactionId) => {
      const serial = this.serializedExecutor(transactionId);
      const resolved = await serial.execute({ sql: RESOLVE_ACCESS_SQL, parameters: [
        { name: "access_token_hash", value: { kind: "blob", bytes: Uint8Array.from(accessTokenDigest) } },
        { name: "authoritative_now", value: { kind: "string", value: authoritativeNow.toISOString() } },
      ] });
      const context = decodeContext(resolved);
      await this.setContext(serial.execute, context);
      const result = await work(Object.freeze({ context: Object.freeze(context), execute: serial.execute }));
      await serial.drain();
      return result;
    });
  }

  async systemTransaction<T>(capability: unknown, action: Extract<AuthorizationAction, `system.${string}`>, work: (unit: SystemSqlUnitOfWork) => Promise<T>): Promise<T> {
    let allowed = false;
    try { allowed = await this.systemAuthorizer.authorize({ capability, action }); } catch { allowed = false; }
    if (!allowed) throw new DataApiTransactionError("invalid_system_capability");
    return this.run(async (transactionId) => {
      const serial = this.serializedExecutor(transactionId);
      const result = await work(Object.freeze({ execute: serial.execute }));
      await serial.drain();
      return result;
    });
  }

  private async run<T>(work: (transactionId: string) => Promise<T>): Promise<T> {
    let transactionId: string | undefined; let owns = false; let committed = false;
    try {
      transactionId = (await this.client.begin()).transactionId;
      if (!validIdentifier(transactionId)) {
        if (typeof transactionId === "string" && transactionId.length > 0) await this.client.rollback(transactionId).catch(() => undefined);
        throw new DataApiTransactionError("transaction_failed");
      }
      if (this.activeTransactionIds.has(transactionId)) throw new DataApiTransactionError("duplicate_transaction");
      if (this.transactionIdReuseLedger.seenOrRemember(transactionId)) {
        await this.client.rollback(transactionId).catch(() => undefined);
        throw new DataApiTransactionError("duplicate_transaction");
      }
      this.activeTransactionIds.add(transactionId); owns = true;
      await this.client.execute({ transactionId, sql: CLEAR_REQUEST_CONTEXT_SQL });
      const result = await work(transactionId);
      await this.client.commit(transactionId); committed = true; return result;
    } catch (error) {
      if (transactionId !== undefined && owns && !committed) { try { await this.client.rollback(transactionId); } catch { /* original wins */ } }
      if (error instanceof DataApiTransactionError) throw error;
      throw new DataApiTransactionError("transaction_failed");
    } finally {
      if (transactionId !== undefined && owns) this.activeTransactionIds.delete(transactionId);
    }
  }

  private async setContext(execute: (statement: SqlStatement) => Promise<SqlResult>, context: ResolvedAccessContext): Promise<void> {
    await execute({ sql: "SELECT set_config('app.principal_id', :principal_id, true)", parameters: [{ name: "principal_id", value: { kind: "string", value: context.principalInternalId, typeHint: "UUID" } }] });
    await execute({ sql: "SELECT set_config('app.tenant_id', :workspace_id, true)", parameters: [{ name: "workspace_id", value: context.workspaceInternalId === undefined ? { kind: "string", value: "" } : { kind: "string", value: context.workspaceInternalId, typeHint: "UUID" } }] });
    await execute({ sql: "SELECT set_config('app.authorization_version', :authorization_version, true)", parameters: [{ name: "authorization_version", value: context.authorizationVersion === undefined ? { kind: "string", value: "" } : { kind: "long", value: context.authorizationVersion } }] });
  }

  private serializedExecutor(transactionId: string): { readonly execute: (statement: SqlStatement) => Promise<SqlResult>; readonly drain: () => Promise<void> } {
    let tail: Promise<void> = Promise.resolve();
    let failure: unknown; let hasFailure = false;
    const execute = (statement: SqlStatement): Promise<SqlResult> => {
      const result = tail.then(async () => {
        if (hasFailure) throw failure;
        return this.client.execute({ transactionId, ...statement });
      });
      tail = result.then(() => undefined, (error: unknown) => { if (!hasFailure) { failure = error; hasFailure = true; } });
      return result;
    };
    return Object.freeze({ execute, drain: async () => { await tail; if (hasFailure) throw failure; } });
  }
}

function decodeContext(result: SqlResult): ResolvedAccessContext {
  if (result.rows.length !== 1) throw new DataApiTransactionError("invalid_access"); const row = result.rows[0];
  if (row === undefined || !uuid(row.principal_id) || !bounded(row.canonical_principal_id) || !uuid(row.family_id) || !bounded(row.family_public_id) || !nonNegative(row.authentication_epoch) || !timestamp(row.authenticated_at) || typeof row.recent_authentication !== "boolean") throw new DataApiTransactionError("invalid_access");
  const scoped = row.workspace_id !== null;
  if (scoped && (!uuid(row.workspace_id) || !role(row.role) || !positive(row.authorization_version))) throw new DataApiTransactionError("invalid_access");
  if (!scoped && (row.role !== null || row.authorization_version !== null)) throw new DataApiTransactionError("invalid_access");
  const base = { principalInternalId: row.principal_id, principalPublicId: row.canonical_principal_id, familyInternalId: row.family_id, familyPublicId: row.family_public_id, authenticationEpoch: row.authentication_epoch, authenticatedAt: row.authenticated_at, recentAuthentication: row.recent_authentication };
  return scoped ? { ...base, workspaceInternalId: row.workspace_id as string, role: row.role as NonNullable<ResolvedAccessContext["role"]>, authorizationVersion: row.authorization_version as number } : base;
}
function validDate(value: Date): boolean { return value instanceof Date && Number.isFinite(value.getTime()); }
function validIdentifier(value: unknown): boolean { return typeof value === "string" && /^[A-Za-z0-9._:-]{1,512}$/.test(value); }
function uuid(value: unknown): value is string { return typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value); }
function bounded(value: unknown): value is string { return typeof value === "string" && value.length >= 1 && value.length <= 256; }
function positive(value: unknown): value is number { return Number.isSafeInteger(value) && (value as number) > 0; }
function nonNegative(value: unknown): value is number { return Number.isSafeInteger(value) && (value as number) >= 0; }
function timestamp(value: unknown): value is string { return typeof value === "string" && Number.isFinite(Date.parse(value)); }
function role(value: unknown): value is NonNullable<ResolvedAccessContext["role"]> { return value === "owner" || value === "admin" || value === "editor" || value === "viewer"; }
