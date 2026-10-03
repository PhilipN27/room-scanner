import Foundation
import RoomScanCore

/// App orchestration around the Core package-first recovery primitive. This
/// layer is deliberately unable to create a local descriptor from hosted
/// public identifiers: descriptor derivation happens only through the Core
/// downloaded-archive inspection boundary.
@MainActor
final class ProfessionalProjectRecoveryCoordinator {
    typealias CanonicalProvenanceInstaller = (
        RoomProfessionalConceptSourcePackageProvenanceSnapshot
    ) throws -> Void

    struct Dependencies {
        let coreRecoveryCoordinator: RoomProfessionalRecoveryCoordinator
        let scratchRootURL: URL
        let journal: ProfessionalProjectSyncJournal?
        let installCanonicalProvenance: CanonicalProvenanceInstaller
    }

    private let dependencies: Dependencies?
    private let fileManager: FileManager

    init(
        dependencies: Dependencies? = nil,
        fileManager: FileManager = .default
    ) {
        self.dependencies = dependencies
        self.fileManager = fileManager
    }

    /// Downloads are already complete when this entry point runs. It first
    /// performs the non-mutating descriptor inspection in a new empty scratch
    /// directory, then delegates all package/companion promotion to Core.
    func recoverDownloadedArchive(
        archiveURL: URL,
        recovery: ProfessionalProjectSyncRecovery,
        target: RoomProfessionalRecoveryTarget
    ) async throws -> RoomProfessionalRecoveryResult {
        try recovery.validate()
        if case .original = target, recovery.branchState != .canonical {
            // A stale hosted branch is preserved only through explicit
            // recovery-as-copy/duplicate actions. It can never become this
            // device's acknowledged hosted head.
            throw ProfessionalProjectSyncError.conflictRequired
        }
        try requireRegularFile(archiveURL)
        guard let dependencies else {
            throw ProfessionalProjectSyncError.sourceUnavailable
        }
        let inspection = try makeOwnedInspectionDirectory(in: dependencies.scratchRootURL)
        defer { try? fileManager.removeItem(at: inspection) }

        let descriptor = try await RoomProfessionalWorkingSetArchive.inspectDownloadedArchive(
            archiveURL: archiveURL,
            expectedManifestSHA256: recovery.workingSetManifestSHA256,
            expectedArchiveSHA256: recovery.archiveSHA256,
            expectedArchiveByteCount: recovery.archiveByteCount,
            in: inspection
        )
        let transaction = try await dependencies.coreRecoveryCoordinator.prepare(
            archiveURL: archiveURL,
            expectedDescriptor: descriptor,
            target: target
        )
        // Inspection alone is deliberately not a resumable app state: a
        // prepare failure/crash must not leave a hosted binding that claims a
        // nonexistent Core transaction. Once Core has returned the durable
        // transaction, write the original mapping and transaction together
        // before any live package promotion can begin.
        if case .original = target {
            try bindOriginalRecoveryIfNeeded(
                target: target,
                descriptorProjectID: descriptor.projectID,
                descriptorHeadRevisionID: descriptor.headRevisionID,
                recovery: recovery,
                transaction: transaction,
                journal: dependencies.journal
            )
        } else {
            try updateJournal(
                projectID: try journalProjectID(target: target, descriptorProjectID: descriptor.projectID),
                transaction: transaction,
                phase: .prepared,
                journal: dependencies.journal
            )
        }
        let result = try await dependencies.coreRecoveryCoordinator.resume(transaction)
        if !result.recoveredAsCopy {
            for provenance in result.conceptSourcePackageProvenance {
                try dependencies.installCanonicalProvenance(provenance)
            }
        }
        try updateJournal(
            projectID: result.projectSummary.projectID,
            transaction: transaction,
            phase: .companionsCommitted,
            journal: dependencies.journal
        )
        try await dependencies.coreRecoveryCoordinator.discardCompleted(transaction)
        try clearCompletedTransaction(
            projectID: result.projectSummary.projectID,
            transaction: transaction,
            journal: dependencies.journal
        )
        return result
    }

    func resume(transactionID: String) async throws -> RoomProfessionalRecoveryResult {
        guard let dependencies,
              ProfessionalProjectSyncJournalRecord.isSafeIdentifier(transactionID)
        else { throw ProfessionalProjectSyncError.sourceUnavailable }
        let transaction = try RoomProfessionalRecoveryTransaction(transactionID: transactionID)
        let result: RoomProfessionalRecoveryResult
        do {
            result = try await dependencies.coreRecoveryCoordinator.resume(transaction)
        } catch let error as RoomProfessionalRecoveryCoordinatorError {
            // If Core already removed its fully completed marked transaction,
            // the only safe app-side recovery is to clear a matching durable
            // `.companionsCommitted` acknowledgement. Do not clear records
            // for any other Core error or phase.
            if case .transactionNotFound = error,
               let journal = dependencies.journal,
               let record = try journal.recoveryRecord(transactionID: transactionID),
               record.recoveryPhase == .companionsCommitted {
                try clearCompletedTransaction(
                    projectID: record.localProjectID,
                    transaction: transaction,
                    journal: journal
                )
            }
            throw error
        }
        if !result.recoveredAsCopy {
            for provenance in result.conceptSourcePackageProvenance {
                try dependencies.installCanonicalProvenance(provenance)
            }
        }
        try updateJournal(
            projectID: result.projectSummary.projectID,
            transaction: transaction,
            phase: .companionsCommitted,
            journal: dependencies.journal
        )
        try await dependencies.coreRecoveryCoordinator.discardCompleted(transaction)
        try clearCompletedTransaction(
            projectID: result.projectSummary.projectID,
            transaction: transaction,
            journal: dependencies.journal
        )
        return result
    }

    private func journalProjectID(
        target: RoomProfessionalRecoveryTarget,
        descriptorProjectID: String
    ) throws -> String {
        switch target {
        case .original:
            guard ProfessionalProjectSyncJournalRecord.isSafeIdentifier(descriptorProjectID) else {
                throw ProfessionalProjectSyncError.invalidPublicState
            }
            return descriptorProjectID
        case let .recoveredCopy(projectID):
            guard ProfessionalProjectSyncJournalRecord.isSafeIdentifier(projectID) else {
                throw ProfessionalProjectSyncError.invalidPublicState
            }
            return projectID
        }
    }

    private func updateJournal(
        projectID: String,
        transaction: RoomProfessionalRecoveryTransaction,
        phase: ProfessionalProjectSyncRecoveryPhase,
        journal: ProfessionalProjectSyncJournal?
    ) throws {
        guard let journal else { return }
        var record = try journal.load(localProjectID: projectID)
            ?? ProfessionalProjectSyncJournalRecord(localProjectID: projectID)
        if let existingTransaction = record.recoveryTransactionID,
           existingTransaction != transaction.transactionID {
            throw ProfessionalProjectSyncError.invalidPublicState
        }
        record.recoveryTransactionID = transaction.transactionID
        record.recoveryPhase = phase
        try journal.replace(record)
    }

    /// Hosted recovery fields are public identifiers/digests only. For
    /// same-ID recovery they must be durable before Core resumes so an app
    /// restart can continue the exact transaction and later append against the
    /// correct hosted head. Recover-as-copy deliberately does not call this.
    private func bindOriginalRecoveryIfNeeded(
        target: RoomProfessionalRecoveryTarget,
        descriptorProjectID: String,
        descriptorHeadRevisionID: String,
        recovery: ProfessionalProjectSyncRecovery,
        transaction: RoomProfessionalRecoveryTransaction,
        journal: ProfessionalProjectSyncJournal?
    ) throws {
        guard case .original = target, let journal else { return }
        guard ProfessionalProjectSyncJournalRecord.isSafeIdentifier(descriptorProjectID),
              ProfessionalProjectSyncJournalRecord.isSafeIdentifier(descriptorHeadRevisionID),
              ProfessionalProjectSyncJournalRecord.isHostedProjectID(recovery.projectID),
              ProfessionalProjectSyncJournalRecord.isHostedRevisionID(recovery.revisionID)
        else { throw ProfessionalProjectSyncError.invalidPublicState }
        var record = try journal.load(localProjectID: descriptorProjectID)
            ?? ProfessionalProjectSyncJournalRecord(localProjectID: descriptorProjectID)
        // A record already bound to another hosted public project/revision is
        // never silently repointed by a downloaded archive response.
        guard record.hostedProjectID == nil || record.hostedProjectID == recovery.projectID,
              record.acknowledgedHostedHeadRevisionID == nil
                || record.acknowledgedHostedHeadRevisionID == recovery.revisionID
        else { throw ProfessionalProjectSyncError.invalidPublicState }
        record.hostedProjectID = recovery.projectID
        record.acknowledgedLocalHeadRevisionID = descriptorHeadRevisionID
        record.acknowledgedHostedHeadRevisionID = recovery.revisionID
        record.localDraftHeadRevisionID = nil
        record.status = recovery.branchState == .canonical ? .canonical : .attached
        record.recoveryTransactionID = transaction.transactionID
        record.recoveryPhase = .prepared
        try journal.replace(record)
    }

    private func clearCompletedTransaction(
        projectID: String,
        transaction: RoomProfessionalRecoveryTransaction,
        journal: ProfessionalProjectSyncJournal?
    ) throws {
        guard let journal else { return }
        guard var record = try journal.load(localProjectID: projectID),
              record.recoveryTransactionID == transaction.transactionID,
              record.recoveryPhase == .companionsCommitted
        else { throw ProfessionalProjectSyncError.invalidPublicState }
        record.recoveryTransactionID = nil
        record.recoveryPhase = .none
        try journal.replace(record)
    }

    private func makeOwnedInspectionDirectory(in root: URL) throws -> URL {
        let standardizedRoot = root.standardizedFileURL
        try requireNoSymlinkInExistingAncestors(of: standardizedRoot)
        if fileManager.fileExists(atPath: standardizedRoot.path) {
            try requireDirectory(standardizedRoot)
        } else {
            try fileManager.createDirectory(at: standardizedRoot, withIntermediateDirectories: true)
            try requireDirectory(standardizedRoot)
        }
        let directory = standardizedRoot.appendingPathComponent(
            ".roomscan-professional-download-inspection-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        try requireDirectory(directory)
        return directory
    }

    private func requireRegularFile(_ url: URL) throws {
        try requireNoSymlinkInExistingAncestors(of: url)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ProfessionalProjectSyncError.unsafeScratch
        }
    }

    private func requireDirectory(_ url: URL) throws {
        try requireNoSymlinkInExistingAncestors(of: url)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ProfessionalProjectSyncError.unsafeScratch
        }
    }

    private func requireNoSymlinkInExistingAncestors(of url: URL) throws {
        guard RoomStorageAncestorSafety.existingAncestorsAreSafe(of: url, fileManager: fileManager) else {
            throw ProfessionalProjectSyncError.unsafeScratch
        }
    }
}
