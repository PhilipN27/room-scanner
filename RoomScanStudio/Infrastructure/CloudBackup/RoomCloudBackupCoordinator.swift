import Combine
import Foundation
import RoomScanCore

enum RoomCloudBackupCoordinatorState: Equatable {
    case idle
    case checking
    case listing
    case backingUp
    case preparingRecovery
    case recovering
    case deletingBackup
    case failed
    case cleanupFailed
}

/// The purge coordinator is composed before the backup service, so its
/// pre-delete hook binds the provider late. Journals only; never a network call.
@MainActor
final class RoomCloudBackupPurgeDeletionRequester {
    private let preferences: RoomCloudBackupPreferences
    private let displayName: @MainActor (String) async -> String
    var provider: (any RoomCloudBackupProviding)?

    init(
        preferences: RoomCloudBackupPreferences,
        provider: (any RoomCloudBackupProviding)? = nil,
        displayName: @escaping @MainActor (String) async -> String = { $0 }
    ) {
        self.preferences = preferences
        self.provider = provider
        self.displayName = displayName
    }

    /// Disabled or unconfigured backup journals nothing and lets the local
    /// purge proceed. Otherwise a failed journal write must stop the purge.
    func requestDeletion(projectID: String) async throws {
        guard preferences.isEnabled,
              let containerIdentifier = preferences.resolvedContainerIdentifier()
        else { return }
        guard let provider else { throw RoomCloudBackupDeletionServiceError.journalUnavailable }
        let name = await displayName(projectID)
        try provider.requestBackupDeletion(
            projectID: projectID,
            displayName: name,
            containerIdentifier: containerIdentifier
        )
    }
}

/// Serializes explicit user operations. It has no launch work and never calls
/// a transport merely because a user enables the local preference.
@MainActor
final class RoomCloudBackupCoordinator: ObservableObject {
    @Published private(set) var state: RoomCloudBackupCoordinatorState = .idle
    @Published private(set) var accountStatus: RoomCloudBackupAccountStatus?
    @Published private(set) var backups: [RoomCloudBackupRemoteRecord] = []
    @Published private(set) var backupsAreTruncated = false
    @Published private(set) var skippedMalformedBackupRecordCount = 0
    @Published private(set) var listStatusMessage: String?
    @Published private(set) var preparedRecovery: RoomCloudBackupPreparedRecovery?
    @Published private(set) var lastRecoveryResult: RoomBackupRecoveryResult?
    @Published private(set) var errorMessage: String?
    @Published private(set) var pendingDeletions: [RoomCloudBackupDeletionRequest] = []
    @Published private(set) var deletionOutcomeMessage: String?
    @Published private(set) var pendingDeletionsErrorMessage: String?

    static let deletionDisclosure = "Deletes the backup records from your private iCloud database. Apple completes erasure on its servers later; this app cannot verify physical erasure."

    let preferences: RoomCloudBackupPreferences
    private let provider: any RoomCloudBackupProviding
    private let sleeper: any RoomCloudBackupSleeping
    private var consentGeneration = 0
    private var lastRecoveryAction: RecoveryAction?

    private enum RecoveryAction {
        case commit(asCopy: Bool)
        case discard
    }

    init(
        provider: any RoomCloudBackupProviding,
        preferences: RoomCloudBackupPreferences? = nil,
        sleeper: (any RoomCloudBackupSleeping)? = nil
    ) {
        self.provider = provider
        self.preferences = preferences ?? RoomCloudBackupPreferences()
        self.sleeper = sleeper ?? SystemRoomCloudBackupSleeper()
        refreshPendingDeletions()
    }

    /// Reads only the local journal, so launch and sheet presentation can
    /// show pending deletions without any CloudKit call.
    func refreshPendingDeletions() {
        do {
            pendingDeletions = try provider.pendingBackupDeletions()
            pendingDeletionsErrorMessage = nil
        } catch {
            pendingDeletionsErrorMessage = "Pending backup deletions could not be read. No iCloud call was made."
        }
    }

    /// Journals a request for `projectID`, then deletes its backup records
    /// using the shared retry policy.
    func deleteBackups(projectID: String, displayName: String? = nil) async {
        guard let context = beginDeletion() else { return }
        defer { finishIfCurrent(.deletingBackup) }
        deletionOutcomeMessage = nil
        do {
            try provider.requestBackupDeletion(
                projectID: projectID,
                displayName: displayName ?? projectID,
                containerIdentifier: context.containerIdentifier
            )
            refreshPendingDeletions()
            let outcome = try await retrying {
                try await self.provider.performBackupDeletion(projectID: projectID)
            }
            finishDeletion(outcomes: [outcome])
        } catch {
            refreshPendingDeletions()
            fail(error)
        }
    }

    /// The local package is already gone and the request is journaled before
    /// this runs, so the immediate follow-up is one attempt. A failure stays
    /// visible as a pending deletion with explicit Retry and Run actions.
    func attemptRequestedDeletion(projectID: String) async {
        refreshPendingDeletions()
        guard pendingDeletions.contains(where: { $0.projectID == projectID }),
              let _ = beginDeletion()
        else { return }
        defer { finishIfCurrent(.deletingBackup) }
        deletionOutcomeMessage = nil
        do {
            let outcome = try await provider.performBackupDeletion(projectID: projectID)
            finishDeletion(outcomes: [outcome])
        } catch {
            refreshPendingDeletions()
            fail(error)
        }
    }

    func retryPendingDeletion(projectID: String) async {
        guard let _ = beginDeletion() else { return }
        defer { finishIfCurrent(.deletingBackup) }
        deletionOutcomeMessage = nil
        do {
            let outcome = try await retrying {
                try await self.provider.performBackupDeletion(projectID: projectID)
            }
            finishDeletion(outcomes: [outcome])
        } catch {
            refreshPendingDeletions()
            fail(error)
        }
    }

    func runPendingDeletions() async {
        refreshPendingDeletions()
        let projectIDs = pendingDeletions.map(\.projectID)
        guard !projectIDs.isEmpty, let _ = beginDeletion() else { return }
        defer { finishIfCurrent(.deletingBackup) }
        deletionOutcomeMessage = nil
        var outcomes: [RoomCloudBackupDeletionOutcome] = []
        var firstError: Error?
        for projectID in projectIDs {
            do {
                outcomes.append(try await retrying {
                    try await self.provider.performBackupDeletion(projectID: projectID)
                })
            } catch is CancellationError {
                firstError = firstError ?? CancellationError()
                break
            } catch {
                // One project's failure does not block the others; each
                // request keeps its own attempts and last error.
                firstError = firstError ?? error
            }
        }
        if let firstError {
            refreshPendingDeletions()
            if !outcomes.isEmpty { deletionOutcomeMessage = Self.outcomeMessage(outcomes) }
            fail(firstError)
        } else {
            finishDeletion(outcomes: outcomes)
        }
    }

    /// Deletes exactly this listed record; other records stay.
    func deleteBackupRecord(_ record: RoomCloudBackupRemoteRecord) async {
        guard let context = beginDeletion() else { return }
        defer { finishIfCurrent(.deletingBackup) }
        deletionOutcomeMessage = nil
        do {
            let outcome = try await retrying {
                try await self.provider.deleteBackupRecord(record, containerIdentifier: context.containerIdentifier)
            }
            guard isCurrentConsent(context) else { return }
            let deleted = Set(outcome.deletedRecordNames)
            backups.removeAll { deleted.contains($0.descriptor.recordName) }
            refreshListStatusMessage()
            deletionOutcomeMessage = Self.outcomeMessage([outcome])
            errorMessage = nil
        } catch {
            fail(error)
        }
    }

    private func finishDeletion(outcomes: [RoomCloudBackupDeletionOutcome]) {
        refreshPendingDeletions()
        let deleted = Set(outcomes.flatMap(\.deletedRecordNames))
        if !deleted.isEmpty {
            backups.removeAll { deleted.contains($0.descriptor.recordName) }
            if listStatusMessage != nil { refreshListStatusMessage() }
        }
        deletionOutcomeMessage = Self.outcomeMessage(outcomes)
        errorMessage = nil
    }

    static func outcomeMessage(_ outcomes: [RoomCloudBackupDeletionOutcome]) -> String {
        let deleted = Set(outcomes.flatMap(\.deletedRecordNames)).count
        let remaining = Set(outcomes.flatMap(\.remainingRecordNames)).count
        let noun = deleted == 1 ? "record" : "records"
        var message = "Deleted \(deleted) backup \(noun) from your private iCloud database."
        if remaining > 0 {
            message += " \(remaining) \(remaining == 1 ? "record is" : "records are") still in iCloud."
        }
        return message + " Apple completes erasure on its servers later; this app cannot verify physical erasure."
    }

    var availability: RoomCloudBackupAvailability {
        guard preferences.isEnabled else { return .disabled }
        guard let identifier = preferences.resolvedContainerIdentifier() else {
            return .notConfigured
        }
        return .ready(identifier)
    }

    func setEnabled(_ enabled: Bool) {
        guard state == .idle || state == .failed || state == .cleanupFailed else { return }
        consentGeneration &+= 1
        preferences.update(isEnabled: enabled)
        if !enabled {
            accountStatus = nil
            backups = []
            backupsAreTruncated = false
            skippedMalformedBackupRecordCount = 0
            listStatusMessage = nil
            errorMessage = nil
            deletionOutcomeMessage = nil
        }
    }

    func checkAccount() async {
        guard let context = begin(.checking) else { return }
        defer { finishIfCurrent(.checking) }
        do {
            let status = try await retrying {
                try await self.provider.checkAccount(containerIdentifier: context.containerIdentifier)
            }
            guard isCurrentConsent(context) else { return }
            accountStatus = status
            errorMessage = nil
        } catch {
            fail(error)
        }
    }

    func listBackups() async {
        guard let context = begin(.listing) else { return }
        listStatusMessage = nil
        defer { finishIfCurrent(.listing) }
        do {
            let result = try await retrying {
                try await self.provider.listBackups(containerIdentifier: context.containerIdentifier)
            }
            guard isCurrentConsent(context) else { return }
            switch result {
            case .zoneMissing:
                // Listing is intentionally read-only: do not create a zone.
                backups = []
                backupsAreTruncated = false
                skippedMalformedBackupRecordCount = 0
                refreshListStatusMessage()
            case let .backups(listing):
                backups = listing.records.sorted { $0.descriptor.sourceUpdatedAt > $1.descriptor.sourceUpdatedAt }
                backupsAreTruncated = listing.isTruncated
                skippedMalformedBackupRecordCount = listing.skippedMalformedRecordCount
                refreshListStatusMessage()
            }
            errorMessage = nil
        } catch {
            fail(error)
        }
    }

    func backUp(projectID: String, expectedHeadRevisionID: String) async {
        guard let context = begin(.backingUp) else { return }
        defer { finishIfCurrent(.backingUp) }
        do {
            let record = try await retrying {
                try await self.provider.backUp(
                    projectID: projectID,
                    expectedHeadRevisionID: expectedHeadRevisionID,
                    containerIdentifier: context.containerIdentifier
                )
            }
            guard isCurrentConsent(context) else { return }
            upsert(record)
            refreshListStatusMessage()
            errorMessage = nil
        } catch {
            fail(error)
        }
    }

    func prepareRecovery(record: RoomCloudBackupRemoteRecord) async {
        guard let context = begin(.preparingRecovery) else { return }
        defer { finishIfCurrent(.preparingRecovery) }
        do {
            let preparation = try await retrying {
                try await self.provider.prepareRecovery(
                    record: record,
                    containerIdentifier: context.containerIdentifier
                )
            }
            guard isCurrentConsent(context) else {
                try await provider.discardPreparedRecovery(preparation)
                return
            }
            preparedRecovery = preparation
            errorMessage = nil
        } catch {
            fail(error)
        }
    }

    func commitPreparedRecovery(asCopy: Bool) async {
        guard state == .idle, let preparation = preparedRecovery else { return }
        state = .recovering
        errorMessage = nil
        lastRecoveryAction = .commit(asCopy: asCopy)
        do {
            lastRecoveryResult = try await provider.commitPreparedRecovery(preparation, asCopy: asCopy)
            preparedRecovery = nil
            state = .idle
        } catch {
            fail(error)
        }
    }

    func cancelPreparedRecovery() async {
        guard state == .idle, let preparation = preparedRecovery else { return }
        state = .recovering
        lastRecoveryAction = .discard
        do {
            try await provider.discardPreparedRecovery(preparation)
            preparedRecovery = nil
            errorMessage = nil
            state = .idle
        } catch {
            fail(error)
        }
    }

    func clearError() {
        guard state == .failed else { return }
        state = .idle
        errorMessage = nil
    }

    /// A marker-owned app workspace can remain after a promotion or discard
    /// when only cleanup failed. This retry never starts another CloudKit call.
    func retryCleanup() async {
        guard state == .cleanupFailed else { return }
        do {
            let completed = try await provider.retryCleanup()
            guard completed else {
                errorMessage = "The exact cloud backup workspace still needs cleanup retry."
                return
            }
            errorMessage = nil
            state = .idle
            if preparedRecovery != nil {
                // A cleanup-failed commit/discard has already completed its
                // Core transition. The service removes its matching pending
                // token only after this exact lease cleanup succeeds, so the
                // UI must not retain a stale Recovery Ready action.
                preparedRecovery = nil
                lastRecoveryAction = nil
            }
        } catch {
            errorMessage = message(for: error)
        }
    }

    func retryPreparedRecoveryAction() async {
        guard state == .failed, let action = lastRecoveryAction else { return }
        state = .idle
        switch action {
        case let .commit(asCopy):
            await commitPreparedRecovery(asCopy: asCopy)
        case .discard:
            await cancelPreparedRecovery()
        }
    }

    private struct OperationContext {
        let containerIdentifier: String
        let consentGeneration: Int
    }

    private func begin(_ next: RoomCloudBackupCoordinatorState) -> OperationContext? {
        guard state == .idle else { return nil }
        guard case let .ready(identifier) = availability else {
            errorMessage = availability == .disabled
                ? "iCloud backup is disabled locally. Enable it before an explicit cloud action."
                : "Enter an operator-supplied iCloud container identifier before an explicit cloud action."
            state = .failed
            return nil
        }
        errorMessage = nil
        state = next
        return OperationContext(containerIdentifier: identifier, consentGeneration: consentGeneration)
    }

    /// A deletion is an explicit user action that supersedes an earlier
    /// acknowledged-or-not failure; it never starts while other work runs.
    private func beginDeletion() -> OperationContext? {
        if state == .failed {
            state = .idle
            errorMessage = nil
        }
        return begin(.deletingBackup)
    }

    private func finishIfCurrent(_ active: RoomCloudBackupCoordinatorState) {
        if state == active { state = .idle }
    }

    private func retrying<T>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch let error as RoomCloudBackupTransportError {
                attempt += 1
                guard error.isRetryable, attempt < 3 else { throw error }
                let retryAfter = max(0, min(error.retryAfterSeconds ?? 0, 60))
                try await sleeper.sleep(seconds: retryAfter)
                try Task.checkCancellation()
            }
        }
    }

    private func upsert(_ record: RoomCloudBackupRemoteRecord) {
        backups.removeAll { $0.descriptor.snapshotID == record.descriptor.snapshotID }
        backups.append(record)
        backups.sort { $0.descriptor.sourceUpdatedAt > $1.descriptor.sourceUpdatedAt }
        if backups.count > RoomCloudBackupListedRecords.maximumRecords {
            backups = Array(backups.prefix(RoomCloudBackupListedRecords.maximumRecords))
            backupsAreTruncated = true
        }
    }

    private func refreshListStatusMessage() {
        let recordCount = backups.count
        let recordNoun = recordCount == 1 ? "record" : "records"
        listStatusMessage = backups.isEmpty
            ? "No private backup records were found."
            : "Loaded \(recordCount) private backup \(recordNoun)."
    }

    private func fail(_ error: Error) {
        if error is RoomCloudBackupLeaseCleanupError {
            errorMessage = message(for: error)
            state = .cleanupFailed
            return
        }
        errorMessage = state == .deletingBackup ? deletionMessage(for: error) : message(for: error)
        state = .failed
    }

    private func deletionMessage(for error: Error) -> String {
        switch error {
        case RoomCloudBackupTransportError.accountUnavailable:
            return "The iCloud account is unavailable. Backup records not reported deleted are still in iCloud."
        case let transportError as RoomCloudBackupTransportError where transportError.isRetryable:
            return "iCloud could not be reached. Backup records not reported deleted are still in iCloud."
        case is RoomCloudBackupDeletionJournalError, RoomCloudBackupDeletionServiceError.journalUnavailable:
            return "The local deletion request could not be recorded or updated. No backup record was reported deleted."
        default:
            return "The iCloud backup deletion did not finish. Any records not reported deleted are still in iCloud."
        }
    }

    private func isCurrentConsent(_ context: OperationContext) -> Bool {
        context.consentGeneration == consentGeneration
            && (availability == .ready(context.containerIdentifier))
    }

    private func message(for error: Error) -> String {
        switch error {
        case RoomCloudBackupTransportError.limitExceeded:
            return "The private CloudKit service rejected this one-record backup for its size. Nothing was split or uploaded in the background."
        case RoomCloudBackupTransportError.accountUnavailable:
            return "The iCloud account is unavailable for private backup. Local room packages remain available."
        case RoomCloudBackupTransportError.recordConflict:
            return "A deterministic backup record exists with different integrity values. Recovery is blocked until this conflict is resolved."
        case RoomCloudBackupTransportError.cancellationOutcomeUnknown:
            return "The upload cancellation outcome is unknown. Check the deterministic backup record before trying again."
        case RoomBackupError.recoveryConflict:
            return "A local room with this project ID diverged. Choose Recover as Copy to preserve both packages."
        default:
            return "The explicit cloud backup action did not finish. Local room packages were not changed."
        }
    }
}
