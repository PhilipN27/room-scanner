import { mapPublicationQuarantineStorageKey, PublicationObjectAdapter, PublicationStorageError } from "../adapters/s3-publication.js";
import {
  inspectPublicationArchiveForValidation,
  validatePublicationArchive,
  PublicationArchiveValidationError,
} from "./archive-validator.js";
import { derivePublicationAssets, PublicationDerivativeError } from "./derivatives.js";
import { PublicationWorkerStoreError, type PublicationWorkerClaim, type PublicationWorkerStore } from "../persistence/publication-worker-store.js";

export type PublicationWorkerOutcome =
  | Readonly<{ readonly status: "idle" }>
  | Readonly<{ readonly status: "published"; readonly allocationID: string; readonly snapshotID: string }>
  | Readonly<{ readonly status: "rejected"; readonly allocationID: string; readonly reason: "invalid_archive" | "source_changed" | "approval_changed" }>
  | Readonly<{ readonly status: "retry" }>;

/** Targetless one-job worker. Quarantine bytes are read by exact provider
 * version, revalidated from an empty allowlist, copied to unreferenced active
 * derivative objects, then and only then finalized under the lease-bound
 * reducer. No queue input can choose a tenant, source, key, or snapshot. */
export class PublicationValidationWorker {
  constructor(private readonly dependencies: { readonly clock: { now(): Date }; readonly store: PublicationWorkerStore; readonly objects: PublicationObjectAdapter }) {
    if (dependencies === null || typeof dependencies !== "object" || dependencies.clock === null || typeof dependencies.clock.now !== "function" || dependencies.store === null || typeof dependencies.store.claimNext !== "function" || typeof dependencies.store.bindQuarantineVersion !== "function" || typeof dependencies.store.reject !== "function" || typeof dependencies.store.finalize !== "function" || !(dependencies.objects instanceof PublicationObjectAdapter)) throw new Error("invalid_publication_worker");
  }
  async runOnce(): Promise<PublicationWorkerOutcome> {
    const now = this.#now(); const claim = await this.dependencies.store.claimNext(now); if (claim === undefined) return Object.freeze({ status: "idle" });
    try {
      if (claim.quarantineKey !== mapPublicationQuarantineStorageKey({ allocationPublicID: claim.allocationPublicID })) throw new PublicationArchiveValidationError("archive_digest");
      // The API never reads or supplies a provider version. Only after the
      // worker owns the targetless DB lease may it capture the immutable head,
      // bind it atomically through the worker-only reducer, then reopen the
      // resulting exact version for validation.
      const capturedVersion = await this.dependencies.objects.captureCurrentQuarantine({
        allocationPublicID: claim.allocationPublicID,
        expectedByteCount: claim.archiveByteCount,
        expectedSHA256: claim.archiveSHA256,
      });
      const bound = await this.dependencies.store.bindQuarantineVersion(claim, this.#now(), capturedVersion);
      if (bound.allocationPublicID !== claim.allocationPublicID
        || bound.quarantineKey !== claim.quarantineKey
        || bound.archiveSHA256 !== claim.archiveSHA256
        || bound.archiveManifestSHA256 !== claim.archiveManifestSHA256
        || bound.archiveByteCount !== claim.archiveByteCount) throw new PublicationArchiveValidationError("archive_digest");
      const quarantine = await this.dependencies.objects.openExactQuarantine({ allocationPublicID: claim.allocationPublicID, expectedVersion: bound.quarantineVersion, expectedByteCount: bound.archiveByteCount, expectedSHA256: bound.archiveSHA256 });
      const inspection = await inspectPublicationArchiveForValidation(quarantine.reader);
      const archive = await validatePublicationArchive({ reader: quarantine.reader, expected: {
        archive: { byteCount: claim.archiveByteCount, sha256: claim.archiveSHA256 },
        publicationManifest: inspection.publicationManifest,
        presentation: inspection.presentation,
        sourceBindingsSHA256: claim.sourceBindingsSHA256,
        selectionManifestSHA256: claim.selectionManifestSHA256,
        approvalSHA256: claim.approvalSHA256,
        ledger: inspection.ledger,
      } });
      if (archive.sourceBindingsSHA256 !== claim.sourceBindingsSHA256 || archive.selectionManifestSHA256 !== claim.selectionManifestSHA256 || archive.approvalSHA256 !== claim.approvalSHA256) throw new PublicationArchiveValidationError("approval");
      const derivatives = await derivePublicationAssets({ reader: quarantine.reader, archive, allocationPublicID: claim.allocationPublicID });
      const persisted = [] as Array<Readonly<{ readonly assetID: string; readonly kind: string; readonly objectKey: string; readonly objectVersion: string; readonly contentType: string; readonly sha256: string; readonly byteCount: number; readonly downloadKind?: string }>>;
      for (const derivative of derivatives) {
        const active = await this.dependencies.objects.putActiveDerivative({ allocationPublicID: claim.allocationPublicID, assetPublicID: derivative.assetPublicID, kind: derivative.kind, bytes: derivative.bytes, contentType: derivative.contentType });
        persisted.push(Object.freeze({ assetID: derivative.assetPublicID, kind: derivative.kind, objectKey: active.objectKey, objectVersion: active.objectVersion, contentType: derivative.contentType, sha256: derivative.sha256, byteCount: derivative.bytes.byteLength, ...(derivative.downloadKind === undefined ? {} : { downloadKind: derivative.downloadKind }) }));
      }
      const presentation = persisted.find((asset) => asset.kind === "presentation"); if (presentation === undefined) throw new PublicationDerivativeError("invalid_derivative");
      const finalized = await this.dependencies.store.finalize(claim, this.#now(), { activeObjectVersion: presentation.objectVersion, presentationSHA256: presentation.sha256, sourceBindingsSHA256: claim.sourceBindingsSHA256, presentationByteCount: presentation.byteCount, assets: persisted });
      return Object.freeze({ status: "published", allocationID: claim.allocationPublicID, snapshotID: finalized.snapshotID });
    } catch (error) {
      if (error instanceof PublicationArchiveValidationError || error instanceof PublicationDerivativeError) {
        await this.#reject(claim, error instanceof PublicationArchiveValidationError && (error.code === "approval" || error.code === "binding" || error.code === "selection") ? "approval_changed" : "invalid_archive");
        return Object.freeze({ status: "rejected", allocationID: claim.allocationPublicID, reason: error instanceof PublicationArchiveValidationError && (error.code === "approval" || error.code === "binding" || error.code === "selection") ? "approval_changed" : "invalid_archive" });
      }
      if (error instanceof PublicationStorageError || error instanceof PublicationWorkerStoreError && error.code === "unavailable") return Object.freeze({ status: "retry" });
      // The finalizer is the source-of-truth recheck of exact current heads,
      // curation, approval, quota and kill epochs. A normal rejection after
      // its lease-bound check is terminal; a transport failure remains retry.
      try { await this.#reject(claim, "source_changed"); return Object.freeze({ status: "rejected", allocationID: claim.allocationPublicID, reason: "source_changed" }); } catch { return Object.freeze({ status: "retry" }); }
    }
  }
  async #reject(claim: PublicationWorkerClaim, reason: "invalid_archive" | "source_changed" | "approval_changed"): Promise<void> { await this.dependencies.store.reject(claim, this.#now(), reason); }
  #now(): Date { const now = this.dependencies.clock.now(); if (!(now instanceof Date) || !Number.isFinite(now.getTime())) throw new Error("invalid_publication_worker_clock"); return new Date(now.getTime()); }
}
