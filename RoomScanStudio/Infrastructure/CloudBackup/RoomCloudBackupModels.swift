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
    private var records: [String: RoomCloudBackupRemoteRecord] = [:]
    private var archiveDataBySnapshotID: [String: Data] = [:]
    private var zoneExists = false
    private let accountStatus: RoomCloudBackupAccountStatus

    init(accountStatus: RoomCloudBackupAccountStatus = .available) {
        self.accountStatus = accountStatus
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
}
