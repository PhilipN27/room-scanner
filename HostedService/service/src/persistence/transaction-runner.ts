import { createHash } from "node:crypto";

import type { DataApiClient, SqlResult, SqlStatement } from "../adapters/data-api.js";
import type { CapabilitySqlUnit } from "./capabilities.js";

/** Failure categories deliberately mirror the provider transaction boundary
 * without exposing a provider transaction ID to any caller. */
export class CapabilityTransactionError extends Error {
  constructor(readonly code: "duplicate_transaction" | "transaction_failed") {
    super(code);
    this.name = "CapabilityTransactionError";
  }
}

const TRANSACTION_ID_REUSE_LEDGER_BYTES = 1_048_576;
const TRANSACTION_ID_REUSE_HASHES = 7;

/**
 * Fixed-memory, fail-closed replay memory for public provider transaction
 * identifiers. It deliberately matches the Data API executor's semantics:
 * an inserted ID can never become a false negative during this warm runtime;
 * a saturated Bloom ledger can only reject a fresh ID (false positive).
 */
class TransactionIdReuseLedger {
  readonly #bits = new Uint8Array(TRANSACTION_ID_REUSE_LEDGER_BYTES);

  seenOrRemember(transactionId: string): boolean {
    const digest = createHash("sha256").update(transactionId, "utf8").digest();
    const bitCount = this.#bits.byteLength * 8;
    const indexes: number[] = [];
    let seen = true;
    for (let hash = 0; hash < TRANSACTION_ID_REUSE_HASHES; hash += 1) {
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
      if (((this.#bits[byteIndex] ?? 0) & mask) === 0) seen = false;
    }
    for (const bitIndex of indexes) {
      const byteIndex = Math.floor(bitIndex / 8);
      this.#bits[byteIndex] = (this.#bits[byteIndex] ?? 0) | (1 << (bitIndex % 8));
    }
    return seen;
  }
}

/**
 * One role-bound, unscoped transaction runner for public/server workflows.
 * Infrastructure constructs a separate instance for every runtime credential;
 * handlers choose neither role nor transaction ID. The work callback receives
 * only the repository constructed by the fixed factory, never a client or SQL
 * executor.
 */
export class DataApiCapabilityTransactionRunner<TRepository> {
  readonly #transactionIdReuseLedger = new TransactionIdReuseLedger();
  readonly #activeTransactionIds = new Set<string>();

  constructor(
    private readonly client: DataApiClient,
    private readonly repositoryFactory: (unit: CapabilitySqlUnit) => TRepository,
  ) {
    if (client === null
      || typeof client !== "object"
      || typeof client.begin !== "function"
      || typeof client.execute !== "function"
      || typeof client.commit !== "function"
      || typeof client.rollback !== "function"
      || typeof repositoryFactory !== "function") {
      throw new CapabilityTransactionError("transaction_failed");
    }
  }

  async run<T>(work: (repository: TRepository) => Promise<T>): Promise<T> {
    if (typeof work !== "function") throw new CapabilityTransactionError("transaction_failed");
    let transactionId: string | undefined;
    let ownsTransaction = false;
    let committed = false;
    try {
      const started = await this.client.begin();
      const candidateTransactionId: unknown = started.transactionId;
      if (!validTransactionId(candidateTransactionId)) {
        if (typeof candidateTransactionId === "string" && candidateTransactionId.length > 0) {
          await this.client.rollback(candidateTransactionId).catch(() => undefined);
        }
        throw new CapabilityTransactionError("transaction_failed");
      }
      transactionId = candidateTransactionId;
      // A concurrently active provider ID may name the owner transaction.
      // Never roll it back from this contender; doing so could abort the
      // legitimate request. A completed/replayed (or Bloom-positive) ID is a
      // separately created candidate and is safely rolled back fail closed.
      if (this.#activeTransactionIds.has(transactionId)) {
        throw new CapabilityTransactionError("duplicate_transaction");
      }
      if (this.#transactionIdReuseLedger.seenOrRemember(transactionId)) {
        await this.client.rollback(transactionId).catch(() => undefined);
        throw new CapabilityTransactionError("duplicate_transaction");
      }
      this.#activeTransactionIds.add(transactionId);
      ownsTransaction = true;

      const serial = serializedExecutor(this.client, transactionId);
      const repository = this.repositoryFactory(Object.freeze({ execute: serial.execute }));
      const result = await work(repository);
      await serial.drain();
      await this.client.commit(transactionId);
      committed = true;
      return result;
    } catch (error) {
      if (transactionId !== undefined && ownsTransaction && !committed) {
        try { await this.client.rollback(transactionId); } catch { /* preserve the original error */ }
      }
      if (error instanceof CapabilityTransactionError) throw error;
      throw new CapabilityTransactionError("transaction_failed");
    } finally {
      if (transactionId !== undefined && ownsTransaction) {
        this.#activeTransactionIds.delete(transactionId);
      }
    }
  }
}

function serializedExecutor(
  client: DataApiClient,
  transactionId: string,
): { readonly execute: (statement: SqlStatement) => Promise<SqlResult>; readonly drain: () => Promise<void> } {
  let tail: Promise<void> = Promise.resolve();
  let failure: unknown;
  let hasFailure = false;
  const execute = (statement: SqlStatement): Promise<SqlResult> => {
    const result = tail.then(async () => {
      if (hasFailure) throw failure;
      return client.execute({ transactionId, ...statement });
    });
    tail = result.then(
      () => undefined,
      (error: unknown) => {
        if (!hasFailure) {
          hasFailure = true;
          failure = error;
        }
      },
    );
    return result;
  };
  return Object.freeze({
    execute,
    drain: async () => {
      await tail;
      if (hasFailure) throw failure;
    },
  });
}

function validTransactionId(value: unknown): value is string {
  return typeof value === "string" && /^[A-Za-z0-9._:-]{1,512}$/u.test(value);
}
