import Foundation

/// Marker-owned, non-authoritative local recovery state. The remote service
/// remains the source of truth for hosted status; losing this journal is safe
/// because callers reconcile through the public upload status endpoint.
final class ProfessionalProjectSyncJournal: @unchecked Sendable {
    private static let markerFilename = ".roomscan-professional-sync-ownership.json"
    private static let recordsDirectoryName = "records"
    private static let schemaVersion = "roomscan-professional-sync-journal-root-v1"
    private static let stagePrefix = ".roomscan-professional-sync-stage-"

    private struct Marker: Codable, Equatable {
        let schemaVersion: String
        let ownershipToken: String
    }

    private let rootURL: URL
    private let fileManager: FileManager
    private let ownershipToken: String
    private let lock = NSLock()

    init(rootURL: URL, fileManager: FileManager = .default) throws {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
        ownershipToken = UUID().uuidString.lowercased()
        try establishOwnedRoot()
    }

    func load(localProjectID: String) throws -> ProfessionalProjectSyncJournalRecord? {
        try requireSafeIdentifier(localProjectID)
        return try lock.withLock {
            try establishOwnedRoot()
            let url = try recordURL(localProjectID: localProjectID)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            try requireRegularFile(url)
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let record = try JSONDecoder().decode(ProfessionalProjectSyncJournalRecord.self, from: data)
            try record.validate()
            guard record.localProjectID == localProjectID else {
                throw ProfessionalProjectSyncError.invalidPublicState
            }
            guard try canonicalData(for: record) == data else {
                throw ProfessionalProjectSyncError.invalidPublicState
            }
            return record
        }
    }

    func replace(_ record: ProfessionalProjectSyncJournalRecord) throws {
        try record.validate()
        try lock.withLock {
            try establishOwnedRoot()
            let destination = try recordURL(localProjectID: record.localProjectID)
            let directory = destination.deletingLastPathComponent()
            try requireDirectory(directory)
            let data = try canonicalData(for: record)
            let stage = directory.appendingPathComponent(
                Self.stagePrefix + UUID().uuidString.lowercased()
            )
            defer { try? removeOwnedStage(stage) }
            try data.write(to: stage, options: [.withoutOverwriting])
            try requireRegularFile(stage)
            guard try Data(contentsOf: stage, options: [.mappedIfSafe]) == data else {
                throw ProfessionalProjectSyncError.unsafeScratch
            }
            try data.write(to: destination, options: .atomic)
            try requireRegularFile(destination)
            guard try Data(contentsOf: destination, options: [.mappedIfSafe]) == data else {
                throw ProfessionalProjectSyncError.unsafeScratch
            }
        }
    }

    func remove(localProjectID: String) throws {
        try requireSafeIdentifier(localProjectID)
        try lock.withLock {
            try establishOwnedRoot()
            let destination = try recordURL(localProjectID: localProjectID)
            guard fileManager.fileExists(atPath: destination.path) else { return }
            try requireRegularFile(destination)
            try fileManager.removeItem(at: destination)
        }
    }

    /// Locates one durable Core recovery transaction without exposing any
    /// private package data. This is used only to finish app-journal cleanup
    /// after Core has already discarded a completed transaction but the app
    /// process stopped before clearing its acknowledgement.
    func recoveryRecord(
        transactionID: String
    ) throws -> ProfessionalProjectSyncJournalRecord? {
        try requireSafeIdentifier(transactionID)
        return try lock.withLock {
            try establishOwnedRoot()
            let records = rootURL.appendingPathComponent(Self.recordsDirectoryName, isDirectory: true)
            var found: ProfessionalProjectSyncJournalRecord?
            for entry in try fileManager.contentsOfDirectory(
                at: records,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ) where entry.pathExtension == "json" {
                try requireRegularFile(entry)
                let data = try Data(contentsOf: entry, options: [.mappedIfSafe])
                let record = try JSONDecoder().decode(ProfessionalProjectSyncJournalRecord.self, from: data)
                try record.validate()
                guard try canonicalData(for: record) == data else {
                    throw ProfessionalProjectSyncError.invalidPublicState
                }
                guard record.recoveryTransactionID == transactionID else { continue }
                guard found == nil else { throw ProfessionalProjectSyncError.invalidPublicState }
                found = record
            }
            return found
        }
    }

    private func establishOwnedRoot() throws {
        try requireNoSymlinkInExistingAncestors(of: rootURL)
        if fileManager.fileExists(atPath: rootURL.path) {
            try requireDirectory(rootURL)
        } else {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try requireDirectory(rootURL)
        }
        let markerURL = rootURL.appendingPathComponent(Self.markerFilename)
        if fileManager.fileExists(atPath: markerURL.path) {
            try requireRegularFile(markerURL)
            let data = try Data(contentsOf: markerURL, options: [.mappedIfSafe])
            let marker = try JSONDecoder().decode(Marker.self, from: data)
            guard marker.schemaVersion == Self.schemaVersion,
                  marker.ownershipToken.range(of: "^[a-f0-9-]{36}$", options: .regularExpression) != nil,
                  try canonicalData(for: marker) == data
            else { throw ProfessionalProjectSyncError.unsafeScratch }
        } else {
            let marker = Marker(schemaVersion: Self.schemaVersion, ownershipToken: ownershipToken)
            let data = try canonicalData(for: marker)
            try data.write(to: markerURL, options: [.withoutOverwriting])
            try requireRegularFile(markerURL)
        }
        let records = rootURL.appendingPathComponent(Self.recordsDirectoryName, isDirectory: true)
        if fileManager.fileExists(atPath: records.path) {
            try requireDirectory(records)
        } else {
            try fileManager.createDirectory(at: records, withIntermediateDirectories: false)
            try requireDirectory(records)
        }
        for entry in try fileManager.contentsOfDirectory(at: records, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            if entry.lastPathComponent.hasPrefix(Self.stagePrefix) {
                try removeOwnedStage(entry)
            } else if entry.pathExtension == "json" {
                try requireRegularFile(entry)
            } else {
                throw ProfessionalProjectSyncError.unsafeScratch
            }
        }
    }

    private func recordURL(localProjectID: String) throws -> URL {
        try requireSafeIdentifier(localProjectID)
        return rootURL
            .appendingPathComponent(Self.recordsDirectoryName, isDirectory: true)
            .appendingPathComponent("\(localProjectID).json")
    }

    private func canonicalData<T: Encodable>(for value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func requireSafeIdentifier(_ value: String) throws {
        guard ProfessionalProjectSyncJournalRecord.isSafeIdentifier(value) else {
            throw ProfessionalProjectSyncError.invalidPublicState
        }
    }

    private func removeOwnedStage(_ url: URL) throws {
        guard url.lastPathComponent.hasPrefix(Self.stagePrefix) else {
            throw ProfessionalProjectSyncError.unsafeScratch
        }
        guard fileManager.fileExists(atPath: url.path) else { return }
        try requireRegularFile(url)
        try fileManager.removeItem(at: url)
    }

    private func requireDirectory(_ url: URL) throws {
        try requireNoSymlinkInExistingAncestors(of: url)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ProfessionalProjectSyncError.unsafeScratch
        }
    }

    private func requireRegularFile(_ url: URL) throws {
        try requireNoSymlinkInExistingAncestors(of: url)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ProfessionalProjectSyncError.unsafeScratch
        }
    }

    private func requireNoSymlinkInExistingAncestors(of url: URL) throws {
        let standardized = url.standardizedFileURL
        guard standardized.path.hasPrefix("/") else {
            throw ProfessionalProjectSyncError.unsafeScratch
        }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in standardized.pathComponents.dropFirst() {
            current.appendPathComponent(component, isDirectory: false)
            if (try? fileManager.destinationOfSymbolicLink(atPath: current.path)) != nil {
                throw ProfessionalProjectSyncError.unsafeScratch
            }
            guard fileManager.fileExists(atPath: current.path) else { return }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
