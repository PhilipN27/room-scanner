import Foundation
import SwiftData
import RoomScanCore

enum RoomProjectPurgeResult: Equatable {
    case removed
    case alreadyAbsent
    case skippedNotTrashed
    case skippedNotExpired
    case failed(String)

    var skipped: Bool {
        self == .skippedNotTrashed || self == .skippedNotExpired
    }

    var failed: Bool {
        if case .failed = self { return true }
        return false
    }
}

struct RoomProjectPurgeCompanionResult: Equatable {
    enum Companion: String {
        case redesignState = "redesign state"
        case conceptSets = "Concept Sets"
        case propertyMembership = "property membership"
        case professionalSyncJournal = "professional sync journal"
        case index = "local search index"
    }

    let companion: Companion
    let result: RoomProjectPurgeResult
}

struct RoomProjectPurgeReport: Equatable {
    let projectID: String
    let package: RoomProjectPurgeResult
    var companions: [RoomProjectPurgeCompanionResult] = []

    var packageDeleted: Bool { package == .removed || package == .alreadyAbsent }
    var hasFailures: Bool { package.failed || companions.contains { $0.result.failed } }

    var companionFailureMessage: String? {
        let names = companions.filter { $0.result.failed }.map { $0.companion.rawValue }
        guard !names.isEmpty else { return nil }
        return "The room package was deleted. Cleanup needs attention for: \(names.joined(separator: ", ")). Unsafe or unowned companion files were preserved."
    }
}

@MainActor
protocol RoomProjectPurging {
    func purge(
        projectID: String,
        mode: RoomProjectPurgeMode,
        backup: RoomProjectBackupDisposition
    ) async -> RoomProjectPurgeReport
}

enum RoomProjectPurgeMode {
    case manual
    case automatic
}

/// Whether the pre-delete hook may journal a private backup deletion request.
/// `.keep` never invokes it; `.requestDeletion` still journals nothing while
/// backup is disabled or unconfigured (the hook decides).
enum RoomProjectBackupDisposition: Equatable {
    case keep
    case requestDeletion
}

extension RoomProjectPurging {
    func purge(projectID: String, mode: RoomProjectPurgeMode) async -> RoomProjectPurgeReport {
        await purge(projectID: projectID, mode: mode, backup: .requestDeletion)
    }

    func purge(projectID: String) async -> RoomProjectPurgeReport {
        await purge(projectID: projectID, mode: .manual, backup: .requestDeletion)
    }
}

/// Local package truth is removed before independently guarded companions.
/// A pre-delete request hook is durable-local work only; it must succeed before
/// deletion. Publication operation audit records intentionally have no input here.
@MainActor
final class RoomProjectPurgeCoordinator: RoomProjectPurging {
    private let store: LocalRoomProjectStore
    private let redesignStore: LocalRoomRedesignStore?
    private let conceptStore: LocalRoomConceptStore?
    private let propertyStore: LocalRoomPropertyStore?
    private let syncJournal: ProfessionalProjectSyncJournal?
    private let syncJournalRootURL: URL?
    private let indexContext: ModelContext?
    private let deletionRequest: (@MainActor (String) async throws -> Void)?
    private let clock: any RoomProjectClock
    private let retentionPolicy: RoomTrashRetentionPolicy

    init(
        store: LocalRoomProjectStore,
        redesignStore: LocalRoomRedesignStore? = nil,
        conceptStore: LocalRoomConceptStore? = nil,
        propertyStore: LocalRoomPropertyStore? = nil,
        syncJournal: ProfessionalProjectSyncJournal? = nil,
        syncJournalRootURL: URL? = nil,
        modelContainer: ModelContainer? = nil,
        clock: any RoomProjectClock = SystemRoomProjectClock(),
        retentionPolicy: RoomTrashRetentionPolicy = .init(),
        deletionRequest: (@MainActor (String) async throws -> Void)? = nil
    ) {
        self.store = store
        self.redesignStore = redesignStore
        self.conceptStore = conceptStore
        self.propertyStore = propertyStore
        self.syncJournal = syncJournal
        self.syncJournalRootURL = syncJournalRootURL
        indexContext = modelContainer.map(ModelContext.init)
        self.deletionRequest = deletionRequest
        self.clock = clock
        self.retentionPolicy = retentionPolicy
    }

    func purge(
        projectID: String,
        mode: RoomProjectPurgeMode,
        backup: RoomProjectBackupDisposition
    ) async -> RoomProjectPurgeReport {
        // Validate/load first, so an invalid ID or unsafe package never reaches
        // the request hook. A repeated purge still retries companion cleanup.
        var packageExists = true
        do {
            if let skip = try await skipReason(projectID: projectID, mode: mode) {
                return .init(projectID: projectID, package: skip)
            }
        } catch RoomProjectStoreError.projectNotFound(_) {
            packageExists = false
        } catch {
            return .init(projectID: projectID, package: .failed(error.localizedDescription))
        }
        if packageExists, backup == .requestDeletion, let deletionRequest {
            do {
                try await deletionRequest(projectID)
            } catch {
                return .init(projectID: projectID, package: .failed(error.localizedDescription))
            }
        }

        let packageResult: RoomProjectPurgeResult
        do {
            // The request hook can suspend. Re-read disk truth after it and
            // directly before deletion, never rely on the reaper's old listing.
            if packageExists, let skip = try await skipReason(projectID: projectID, mode: mode) {
                return .init(projectID: projectID, package: skip)
            }
            try await store.permanentlyDelete(projectID: projectID)
            packageResult = .removed
        } catch RoomProjectStoreError.projectNotFound(_) {
            packageResult = .alreadyAbsent
        } catch {
            return .init(projectID: projectID, package: .failed(error.localizedDescription))
        }

        var report = RoomProjectPurgeReport(projectID: projectID, package: packageResult)
        report.companions.append(await remove(.redesignState) {
            guard let redesignStore = self.redesignStore else { return false }
            return try await redesignStore.removeAll(projectID: projectID)
        })
        report.companions.append(await remove(.conceptSets) {
            guard let conceptStore = self.conceptStore else { return false }
            return try await conceptStore.removeAll(projectID: projectID)
        })
        report.companions.append(await remove(.propertyMembership) {
            guard let propertyStore = self.propertyStore else { return false }
            return try await !propertyStore.detach(projectID: projectID).isEmpty
        })
        report.companions.append(await remove(.professionalSyncJournal) {
            let journal: ProfessionalProjectSyncJournal
            if let existing = self.syncJournal {
                journal = existing
            } else if let root = self.syncJournalRootURL {
                // Do not initialize an absent optional journal during cleanup.
                // lstat-style attributes see dangling symlinks; the journal's
                // existing ownership/ancestor guards reject unsafe roots.
                do {
                    _ = try FileManager.default.attributesOfItem(atPath: root.path)
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                    return false
                }
                journal = try ProfessionalProjectSyncJournal(rootURL: root)
            } else {
                return false
            }
            let existed = try journal.load(localProjectID: projectID) != nil
            try journal.remove(localProjectID: projectID)
            return existed
        })
        report.companions.append(await remove(.index) {
            guard let context = self.indexContext else { return false }
            let records = try context.fetch(FetchDescriptor<RoomProjectIndexRecord>())
                .filter { $0.projectID == projectID }
            for record in records { context.delete(record) }
            if !records.isEmpty { try context.save() }
            return !records.isEmpty
        })
        return report
    }

    private func skipReason(projectID: String, mode: RoomProjectPurgeMode) async throws -> RoomProjectPurgeResult? {
        let package = try await store.load(projectID: projectID)
        guard let trashedAt = package.metadata.trashedAt else { return .skippedNotTrashed }
        if mode == .automatic, retentionPolicy.purgeDate(trashedAt: trashedAt) > clock.now() {
            return .skippedNotExpired
        }
        return nil
    }

    private func remove(
        _ companion: RoomProjectPurgeCompanionResult.Companion,
        operation: () async throws -> Bool
    ) async -> RoomProjectPurgeCompanionResult {
        do {
            return .init(companion: companion, result: try await operation() ? .removed : .alreadyAbsent)
        } catch {
            return .init(companion: companion, result: .failed(error.localizedDescription))
        }
    }
}
