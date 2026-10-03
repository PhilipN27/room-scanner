import Foundation

public enum RoomCloudBackupDeletionError: Error, Equatable, Sendable {
    case invalidRequest(String)
}

/// A durable, local-only request to remove one project's private backup
/// records. It exists only while remote deletion is pending; it is not a
/// claim that any remote bytes were erased.
public struct RoomCloudBackupDeletionRequest: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = "roomscan-cloud-backup-deletion-request-v1"
    /// A hostile or stale outcome cannot grow a journal record without bound.
    public static let maximumKnownRecordNames = 2_000
    public static let maximumDisplayNameUTF8Bytes = 512
    public static let maximumErrorMessageUTF8Bytes = 1_024

    public var schemaVersion: String
    public var projectID: String
    public var containerIdentifier: String
    public var displayName: String
    public var requestedAt: Date
    public var knownRecordNames: [String]
    public var attempts: Int
    public var lastAttemptAt: Date?
    public var lastErrorMessage: String?

    public var id: String { projectID }

    public init(
        schemaVersion: String = RoomCloudBackupDeletionRequest.currentSchemaVersion,
        projectID: String,
        containerIdentifier: String,
        displayName: String,
        requestedAt: Date,
        knownRecordNames: [String] = [],
        attempts: Int = 0,
        lastAttemptAt: Date? = nil,
        lastErrorMessage: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.projectID = projectID
        self.containerIdentifier = containerIdentifier
        self.displayName = displayName
        self.requestedAt = requestedAt
        self.knownRecordNames = knownRecordNames
        self.attempts = attempts
        self.lastAttemptAt = lastAttemptAt
        self.lastErrorMessage = lastErrorMessage
    }

    public static func isRecordName(_ value: String) -> Bool {
        let prefix = "rssb1-"
        guard value.hasPrefix(prefix) else { return false }
        let digest = value.dropFirst(prefix.count)
        return digest.utf8.count == 64
            && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw RoomCloudBackupDeletionError.invalidRequest("Unsupported deletion request schema.")
        }
        guard RoomPathValidation.isSafeStableIdentifier(projectID) else {
            throw RoomCloudBackupDeletionError.invalidRequest("Unsafe project identifier.")
        }
        let container = containerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !container.isEmpty, container == containerIdentifier,
              container.utf8.count <= 255,
              !container.contains("$("), !container.contains("${")
        else {
            throw RoomCloudBackupDeletionError.invalidRequest("Missing or unresolved container identifier.")
        }
        guard displayName.utf8.count <= Self.maximumDisplayNameUTF8Bytes else {
            throw RoomCloudBackupDeletionError.invalidRequest("Display name is too long.")
        }
        guard knownRecordNames.count <= Self.maximumKnownRecordNames,
              knownRecordNames.allSatisfy(Self.isRecordName),
              knownRecordNames == Self.normalizedRecordNames(knownRecordNames)
        else {
            throw RoomCloudBackupDeletionError.invalidRequest("Known record names are not canonical backup record names.")
        }
        guard attempts >= 0 else {
            throw RoomCloudBackupDeletionError.invalidRequest("Attempt count cannot be negative.")
        }
        if let lastErrorMessage, lastErrorMessage.utf8.count > Self.maximumErrorMessageUTF8Bytes {
            throw RoomCloudBackupDeletionError.invalidRequest("Last error message is too long.")
        }
        guard requestedAt.timeIntervalSince1970.isFinite,
              lastAttemptAt?.timeIntervalSince1970.isFinite ?? true
        else {
            throw RoomCloudBackupDeletionError.invalidRequest("Request dates must be finite.")
        }
    }

    /// Records one finished transport attempt. Remaining names are retained so
    /// the next attempt targets them even if a later zone listing omits them.
    public func recordingAttempt(
        at date: Date,
        outcome: RoomCloudBackupDeletionOutcome
    ) -> RoomCloudBackupDeletionRequest {
        var next = self
        next.attempts = attempts + 1
        next.lastAttemptAt = date
        let deleted = Set(outcome.deletedRecordNames)
        next.knownRecordNames = Self.normalizedRecordNames(
            knownRecordNames.filter { !deleted.contains($0) } + outcome.remainingRecordNames
        )
        if outcome.remainingRecordNames.isEmpty {
            next.lastErrorMessage = nil
        } else {
            let count = outcome.remainingRecordNames.count
            next.lastErrorMessage = Self.bounded(
                "\(count) backup \(count == 1 ? "record" : "records") could not be deleted yet."
            )
        }
        return next
    }

    public func recordingFailure(at date: Date, message: String) -> RoomCloudBackupDeletionRequest {
        var next = self
        next.attempts = attempts + 1
        next.lastAttemptAt = date
        next.lastErrorMessage = Self.bounded(message)
        return next
    }

    /// Sorted, unique, and limited to canonical record names.
    public static func normalizedRecordNames(_ names: [String]) -> [String] {
        Array(Set(names.filter(isRecordName)).sorted().prefix(maximumKnownRecordNames))
    }

    private static func bounded(_ message: String) -> String {
        var result = ""
        for character in message {
            guard result.utf8.count + String(character).utf8.count <= maximumErrorMessageUTF8Bytes else { break }
            result.append(character)
        }
        return result
    }
}

/// The result of one explicit remote deletion attempt. Missing records are
/// reported as deleted because the requested end state already holds.
public struct RoomCloudBackupDeletionOutcome: Codable, Sendable, Equatable {
    public var deletedRecordNames: [String]
    public var remainingRecordNames: [String]
    /// Record name to a sanitized, vendor-neutral failure description.
    public var failures: [String: String]

    public init(
        deletedRecordNames: [String] = [],
        remainingRecordNames: [String] = [],
        failures: [String: String] = [:]
    ) {
        self.deletedRecordNames = Array(Set(deletedRecordNames)).sorted()
        self.remainingRecordNames = Array(Set(remainingRecordNames)).sorted()
        self.failures = failures
    }

    public var isComplete: Bool { remainingRecordNames.isEmpty }
}
