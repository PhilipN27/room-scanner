import Combine
import Foundation
import RoomScanCore

/// The app stores only an explicit local preference. Changing it does not
/// contact iCloud; Check, List, Back up, and Recover are separate user actions.
@MainActor
final class RoomCloudBackupPreferences: ObservableObject {
    private static let enabledKey = "RoomScanStudio.CloudBackup.isEnabled"
    private let defaults: UserDefaults?
    @Published private(set) var isEnabled: Bool
    @Published private(set) var containerIdentifier: String

    init(
        isEnabled: Bool? = nil,
        containerIdentifier: String = "",
        defaults: UserDefaults? = .standard
    ) {
        self.defaults = defaults
        self.isEnabled = isEnabled
            ?? (defaults?.object(forKey: Self.enabledKey) as? Bool)
            ?? false
        self.containerIdentifier = containerIdentifier
    }

    func update(isEnabled: Bool) {
        self.isEnabled = isEnabled
        defaults?.set(isEnabled, forKey: Self.enabledKey)
    }

    func resolvedContainerIdentifier() -> String? {
        let trimmed = containerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("$("),
              !trimmed.contains("${"),
              !trimmed.contains("\n"),
              !trimmed.contains("\r")
        else {
            return nil
        }
        return trimmed
    }
}

enum RoomCloudBackupAvailability: Equatable {
    case disabled
    case notConfigured
    case ready(String)
}

enum RoomCloudBackupAccountStatus: Equatable {
    case available
    case noAccount
    case restricted
    case unavailable(String)
}

/// A deliberately bounded presentation payload. The CloudKit transport stops
/// paging once this cap is reached; the extra flag is truthful rather than
/// silently discarding older records.
struct RoomCloudBackupListedRecords: Equatable {
    static let maximumRecords = 200
    /// A malformed successful CloudKit record is not recoverable. Keep only a
    /// bounded count so a hostile or stale zone cannot create an unbounded UI
    /// payload or page through arbitrary records.
    static let maximumSkippedMalformedRecords = 200

    let records: [RoomCloudBackupRemoteRecord]
    let isTruncated: Bool
    let skippedMalformedRecordCount: Int

    init(
        records: [RoomCloudBackupRemoteRecord],
        isTruncated: Bool = false,
        skippedMalformedRecordCount: Int = 0
    ) {
        let sanitizedSkippedCount = max(0, skippedMalformedRecordCount)
        self.records = Array(records.prefix(Self.maximumRecords))
        self.skippedMalformedRecordCount = min(
            sanitizedSkippedCount,
            Self.maximumSkippedMalformedRecords
        )
        self.isTruncated = isTruncated
            || records.count > Self.maximumRecords
            || sanitizedSkippedCount > Self.maximumSkippedMalformedRecords
    }
}

/// Pure bounded pagination state shared by the CloudKit adapter and app tests.
/// It accepts only already-decoded valid descriptors; malformed successful
/// records are represented as a capped count rather than becoming recovery
/// candidates. A per-record CloudKit `Result.failure` is deliberately not fed
/// here: the transport maps and throws it to abort the explicit List action.
struct RoomCloudBackupListingAccumulator {
    private var records: [RoomCloudBackupRemoteRecord] = []
    private var skippedMalformedRecordCount = 0
    private var isTruncated = false

    mutating func append(
        records pageRecords: [RoomCloudBackupRemoteRecord],
        skippedMalformedRecordCount pageSkippedCount: Int,
        hasMorePages: Bool
    ) {
        let remainingRecords = RoomCloudBackupListedRecords.maximumRecords - records.count
        if pageRecords.count > remainingRecords {
            records.append(contentsOf: pageRecords.prefix(max(0, remainingRecords)))
            isTruncated = true
        } else {
            records.append(contentsOf: pageRecords)
        }

        let sanitizedSkippedCount = max(0, pageSkippedCount)
        let remainingSkipped = RoomCloudBackupListedRecords.maximumSkippedMalformedRecords
            - skippedMalformedRecordCount
        if sanitizedSkippedCount > remainingSkipped {
            skippedMalformedRecordCount += max(0, remainingSkipped)
            isTruncated = true
        } else {
            skippedMalformedRecordCount += sanitizedSkippedCount
        }

        if hasMorePages && (
            records.count >= RoomCloudBackupListedRecords.maximumRecords
                || skippedMalformedRecordCount >= RoomCloudBackupListedRecords.maximumSkippedMalformedRecords
        ) {
            // Do not request a third page after the bounded representation is
            // full. Tell the UI exactly that the returned subset is incomplete.
            isTruncated = true
        }
    }

    var shouldRequestNextPage: Bool {
        !isTruncated
            && records.count < RoomCloudBackupListedRecords.maximumRecords
            && skippedMalformedRecordCount < RoomCloudBackupListedRecords.maximumSkippedMalformedRecords
    }

    var listing: RoomCloudBackupListedRecords {
        RoomCloudBackupListedRecords(
            records: records,
            isTruncated: isTruncated,
            skippedMalformedRecordCount: skippedMalformedRecordCount
        )
    }
}

enum RoomCloudBackupListResult: Equatable {
    case zoneMissing
    case backups(RoomCloudBackupListedRecords)
}

struct RoomCloudBackupRemoteRecord: Identifiable, Equatable {
    let descriptor: RoomCloudBackupDescriptor

    var id: String { descriptor.snapshotID }
}

/// App-level transport errors deliberately abstract CloudKit. The Core module
/// has no CloudKit import and remains usable offline.
enum RoomCloudBackupTransportError: Error, Equatable {
    case notConfigured
    case accountUnavailable
    case zoneMissing
    case serviceUnavailable(retryAfterSeconds: Int?)
    case networkUnavailable(retryAfterSeconds: Int?)
    case rateLimited(retryAfterSeconds: Int?)
    case limitExceeded
    case recordConflict
    case cancellationOutcomeUnknown
    case malformedRemoteRecord
    case transportFailure(String)

    var retryAfterSeconds: Int? {
        switch self {
        case let .serviceUnavailable(value), let .networkUnavailable(value), let .rateLimited(value):
            return value
        default:
            return nil
        }
    }

    var isRetryable: Bool {
        switch self {
        case .serviceUnavailable, .networkUnavailable, .rateLimited:
            return true
        default:
            return false
        }
    }

    /// Vendor-neutral text safe to persist in the local deletion journal.
    var deletionFailureDescription: String {
        switch self {
        case .notConfigured: return "The iCloud container is not configured."
        case .accountUnavailable: return "The iCloud account is unavailable."
        case .zoneMissing: return "The private backup zone is missing."
        case .serviceUnavailable: return "The iCloud service is unavailable."
        case .networkUnavailable: return "The network is unavailable."
        case .rateLimited: return "iCloud asked the app to wait before retrying."
        case .limitExceeded: return "The request exceeded an iCloud limit."
        case .recordConflict: return "The backup record changed on the server."
        case .cancellationOutcomeUnknown: return "The outcome of a cancelled request is unknown."
        case .malformedRemoteRecord: return "The backup record is malformed."
        case .transportFailure: return "iCloud did not complete the request."
        }
    }
}

/// A prepared recovery keeps the underlying app-owned scratch lease opaque.
/// Neither the UI nor a transport can obtain an authoritative package URL.
struct RoomCloudBackupPreparedRecovery: Equatable {
    let token: String
    let record: RoomCloudBackupRemoteRecord
}

@MainActor
protocol RoomCloudBackupProviding {
    func checkAccount(containerIdentifier: String) async throws -> RoomCloudBackupAccountStatus
    func listBackups(containerIdentifier: String) async throws -> RoomCloudBackupListResult
    func backUp(
        projectID: String,
        expectedHeadRevisionID: String,
        containerIdentifier: String
    ) async throws -> RoomCloudBackupRemoteRecord
    func prepareRecovery(
        record: RoomCloudBackupRemoteRecord,
        containerIdentifier: String
    ) async throws -> RoomCloudBackupPreparedRecovery
    func commitPreparedRecovery(
        _ preparation: RoomCloudBackupPreparedRecovery,
        asCopy: Bool
    ) async throws -> RoomBackupRecoveryResult
    func discardPreparedRecovery(_ preparation: RoomCloudBackupPreparedRecovery) async throws
    func retryCleanup() async throws -> Bool
    /// Durable local journal write only; never a network call.
    func requestBackupDeletion(projectID: String, displayName: String, containerIdentifier: String) throws
    /// One transport attempt for a journaled request, then a journal update.
    func performBackupDeletion(projectID: String) async throws -> RoomCloudBackupDeletionOutcome
    /// Local journal read only; never a network call.
    func pendingBackupDeletions() throws -> [RoomCloudBackupDeletionRequest]
    /// Explicit single-record deletion. Not journaled: on failure the record
    /// simply remains listed.
    func deleteBackupRecord(
        _ record: RoomCloudBackupRemoteRecord,
        containerIdentifier: String
    ) async throws -> RoomCloudBackupDeletionOutcome
}

enum RoomCloudBackupDeletionServiceError: Error, Equatable {
    case journalUnavailable
    case requestNotFound(String)
}

@MainActor
protocol RoomCloudBackupSleeping {
    func sleep(seconds: Int) async throws
}

struct SystemRoomCloudBackupSleeper: RoomCloudBackupSleeping {
    func sleep(seconds: Int) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(for: .seconds(seconds))
    }
}

struct ImmediateCloudBackupSleeper: RoomCloudBackupSleeping {
    func sleep(seconds: Int) async throws {
        _ = seconds
    }
}

/// Simulator/UI-test-only transport. It is selected only by an explicit launch
/// argument and never substitutes for a production CloudKit container.
@MainActor
final class DeterministicCloudBackupTransport: RoomCloudBackupTransport {
    struct DeleteInvocation: Equatable {
        let projectID: String?
        let recordNames: [String]
    }

    private struct PersistedState: Codable {
        let zoneExists: Bool
        let descriptors: [RoomCloudBackupDescriptor]
    }

    private static let recordsFilename = "records.json"
    private static let archivesDirectoryName = "archives"

    private var records: [String: RoomCloudBackupRemoteRecord] = [:]
    private var archiveDataBySnapshotID: [String: Data] = [:]
    private var zoneExists = false
    private let accountStatus: RoomCloudBackupAccountStatus
    private let persistenceRootURL: URL?
    /// FIFO of whole-call failures; each delete call consumes at most one.
    var deleteErrors: [RoomCloudBackupTransportError]
    /// Partial-failure seam: this many existing targets (last in sorted
    /// order) stay remote and are reported as failures on every delete call.
    var partialDeleteFailureCount = 0
    private(set) var deleteInvocations: [DeleteInvocation] = []

    /// With `persistenceRootURL` (token-isolated UI runs only) records and
    /// archives survive a relaunch; without it the fake is purely in memory.
    init(
        accountStatus: RoomCloudBackupAccountStatus = .available,
        deleteErrors: [RoomCloudBackupTransportError] = [],
        persistenceRootURL: URL? = nil
    ) {
        self.accountStatus = accountStatus
        self.deleteErrors = deleteErrors
        self.persistenceRootURL = persistenceRootURL?.standardizedFileURL
        loadPersistedState()
    }

    var persistedRecordsURL: URL? {
        persistenceRootURL?.appendingPathComponent(Self.recordsFilename)
    }

    var storedRecordNames: [String] {
        records.values.map(\.descriptor.recordName).sorted()
    }

    func checkAccount(containerIdentifier: String) async throws -> RoomCloudBackupAccountStatus {
        _ = containerIdentifier
        return accountStatus
    }

    func listBackups(containerIdentifier: String) async throws -> RoomCloudBackupListResult {
        _ = containerIdentifier
        guard zoneExists else { return .zoneMissing }
        return .backups(RoomCloudBackupListedRecords(
            records: records.values.sorted { $0.descriptor.snapshotID < $1.descriptor.snapshotID }
        ))
    }

    func ensureBackupZone(containerIdentifier: String) async throws {
        _ = containerIdentifier
        zoneExists = true
        try persistState()
    }

    func save(snapshot: RoomBackupSnapshot, containerIdentifier: String) async throws -> RoomCloudBackupRemoteRecord {
        _ = containerIdentifier
        let key = snapshot.descriptor.snapshotID
        if let existing = records[key] {
            guard existing.descriptor.archiveSHA256 == snapshot.descriptor.archiveSHA256,
                  existing.descriptor.manifestSHA256 == snapshot.descriptor.manifestSHA256
            else { throw RoomCloudBackupTransportError.recordConflict }
            return existing
        }
        // This bounded test seam reads only its deterministic UI-test archive;
        // production CKAsset ownership remains in AppleCloudBackupTransport.
        archiveDataBySnapshotID[key] = try Data(contentsOf: snapshot.archiveURL)
        let record = RoomCloudBackupRemoteRecord(descriptor: snapshot.descriptor)
        records[key] = record
        try persistState()
        return record
    }

    func lookup(snapshotID: String, containerIdentifier: String) async throws -> RoomCloudBackupRemoteRecord? {
        _ = containerIdentifier
        return records[snapshotID]
    }

    func fetchArchive(record: RoomCloudBackupRemoteRecord, containerIdentifier: String, into destinationURL: URL) async throws {
        _ = containerIdentifier
        guard let data = archiveDataBySnapshotID[record.descriptor.snapshotID] else {
            throw RoomCloudBackupTransportError.malformedRemoteRecord
        }
        try data.write(to: destinationURL, options: [.withoutOverwriting])
    }

    func deleteBackups(
        projectID: String,
        knownRecordNames: [String],
        containerIdentifier: String
    ) async throws -> RoomCloudBackupDeletionOutcome {
        _ = containerIdentifier
        let known = RoomCloudBackupDeletionRequest.normalizedRecordNames(knownRecordNames)
        deleteInvocations.append(.init(projectID: projectID, recordNames: known))
        if !deleteErrors.isEmpty { throw deleteErrors.removeFirst() }
        let projectNames = records.values
            .filter { $0.descriptor.projectID == projectID }
            .map(\.descriptor.recordName)
        return try delete(targets: Set(known).union(projectNames))
    }

    func deleteBackupRecords(
        named recordNames: [String],
        containerIdentifier: String
    ) async throws -> RoomCloudBackupDeletionOutcome {
        _ = containerIdentifier
        let names = RoomCloudBackupDeletionRequest.normalizedRecordNames(recordNames)
        deleteInvocations.append(.init(projectID: nil, recordNames: names))
        if !deleteErrors.isEmpty { throw deleteErrors.removeFirst() }
        return try delete(targets: Set(names))
    }

    private func delete(targets: Set<String>) throws -> RoomCloudBackupDeletionOutcome {
        // A never-created zone has nothing to delete: the end state holds.
        guard zoneExists else {
            return RoomCloudBackupDeletionOutcome(deletedRecordNames: Array(targets))
        }
        let snapshotIDByName = Dictionary(
            uniqueKeysWithValues: records.values.map { ($0.descriptor.recordName, $0.descriptor.snapshotID) }
        )
        let existing = targets.filter { snapshotIDByName[$0] != nil }.sorted()
        let failing = Set(existing.suffix(max(0, partialDeleteFailureCount)))
        var deleted = targets.subtracting(existing)
        for name in existing where !failing.contains(name) {
            guard let snapshotID = snapshotIDByName[name] else { continue }
            records.removeValue(forKey: snapshotID)
            archiveDataBySnapshotID.removeValue(forKey: snapshotID)
            deleted.insert(name)
        }
        try persistState()
        return RoomCloudBackupDeletionOutcome(
            deletedRecordNames: Array(deleted),
            remainingRecordNames: Array(failing),
            failures: Dictionary(uniqueKeysWithValues: failing.map {
                ($0, RoomCloudBackupTransportError.networkUnavailable(retryAfterSeconds: nil).deletionFailureDescription)
            })
        )
    }

    private func loadPersistedState() {
        guard let persistenceRootURL, let recordsURL = persistedRecordsURL,
              let data = try? Data(contentsOf: recordsURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return }
        zoneExists = state.zoneExists
        let archives = persistenceRootURL.appendingPathComponent(Self.archivesDirectoryName, isDirectory: true)
        for descriptor in state.descriptors {
            guard (try? RoomProjectBackupArchive.validate(descriptor: descriptor)) != nil else { continue }
            records[descriptor.snapshotID] = RoomCloudBackupRemoteRecord(descriptor: descriptor)
            archiveDataBySnapshotID[descriptor.snapshotID] = try? Data(
                contentsOf: archives.appendingPathComponent("\(descriptor.snapshotID).zip")
            )
        }
    }

    private func persistState() throws {
        guard let persistenceRootURL, let recordsURL = persistedRecordsURL else { return }
        let manager = FileManager.default
        let archives = persistenceRootURL.appendingPathComponent(Self.archivesDirectoryName, isDirectory: true)
        try manager.createDirectory(at: archives, withIntermediateDirectories: true)
        let liveSnapshotIDs = Set(records.keys)
        for entry in try manager.contentsOfDirectory(atPath: archives.path)
        where entry.hasSuffix(".zip") && !liveSnapshotIDs.contains(String(entry.dropLast(4))) {
            try manager.removeItem(at: archives.appendingPathComponent(entry))
        }
        for (snapshotID, data) in archiveDataBySnapshotID {
            let url = archives.appendingPathComponent("\(snapshotID).zip")
            if !manager.fileExists(atPath: url.path) {
                try data.write(to: url, options: .atomic)
            }
        }
        let state = PersistedState(
            zoneExists: zoneExists,
            descriptors: records.values.map(\.descriptor).sorted { $0.snapshotID < $1.snapshotID }
        )
        try RoomCloudBackupDeletionJournal.canonicalData(for: state).write(to: recordsURL, options: .atomic)
    }
}
