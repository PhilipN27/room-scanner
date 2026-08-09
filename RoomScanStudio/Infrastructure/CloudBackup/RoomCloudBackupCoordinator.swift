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
    case failed
    case cleanupFailed
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
    @Published private(set) var preparedRecovery: RoomCloudBackupPreparedRecovery?
    @Published private(set) var lastRecoveryResult: RoomBackupRecoveryResult?
    @Published private(set) var errorMessage: String?

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
        preferences: RoomCloudBackupPreferences = RoomCloudBackupPreferences(),
        sleeper: any RoomCloudBackupSleeping = SystemRoomCloudBackupSleeper()
    ) {
        self.provider = provider
        self.preferences = preferences
        self.sleeper = sleeper
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
            errorMessage = nil
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
            case let .backups(listing):
                backups = listing.records.sorted { $0.descriptor.sourceUpdatedAt > $1.descriptor.sourceUpdatedAt }
                backupsAreTruncated = listing.isTruncated
                skippedMalformedBackupRecordCount = listing.skippedMalformedRecordCount
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

    private func fail(_ error: Error) {
        if error is RoomCloudBackupLeaseCleanupError {
            errorMessage = message(for: error)
            state = .cleanupFailed
            return
        }
        errorMessage = message(for: error)
        state = .failed
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
