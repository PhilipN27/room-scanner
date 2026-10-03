import Foundation
import RoomScanCore

enum RoomCloudBackupDeletionJournalError: Error, Equatable {
    case unsafeIdentifier
    case unsafeJournal
    case invalidRecord
}

/// Marker-owned local record of private backup deletions that are still
/// pending. It never contacts CloudKit. Reading an absent root creates nothing,
/// so default-off and guest launches leave no journal on disk.
final class RoomCloudBackupDeletionJournal: @unchecked Sendable {
    static let markerFilename = ".roomscan-cloud-backup-deletion-ownership.json"
    static let recordsDirectoryName = "records"
    static let schemaVersion = "roomscan-cloud-backup-deletion-journal-root-v1"
    private static let stagePrefix = ".roomscan-cloud-backup-deletion-stage-"

    struct Marker: Codable, Equatable {
        let schemaVersion: String
        let ownershipToken: String
    }

    let rootURL: URL
    private let fileManager: FileManager
    private let ownershipToken: String
    private let beforeRemove: (() throws -> Void)?
    private let lock = NSLock()

    /// `beforeRemove` is a test fault seam for an interrupted completion.
    init(
        rootURL: URL,
        fileManager: FileManager = .default,
        beforeRemove: (() throws -> Void)? = nil
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
        self.beforeRemove = beforeRemove
        ownershipToken = UUID().uuidString.lowercased()
    }

    static func canonicalData<T: Encodable>(for value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    func pendingRequests() throws -> [RoomCloudBackupDeletionRequest] {
        try lock.withLock {
            guard try existingRootIsPresent() else { return [] }
            try establishOwnedRoot()
            let records = rootURL.appendingPathComponent(Self.recordsDirectoryName, isDirectory: true)
            var requests: [RoomCloudBackupDeletionRequest] = []
            for entry in try fileManager.contentsOfDirectory(
                at: records,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ) where entry.pathExtension == "json" {
                let projectID = entry.deletingPathExtension().lastPathComponent
                try requireSafeIdentifier(projectID)
                requests.append(try decodeRecord(at: entry, projectID: projectID))
            }
            return requests.sorted {
                ($0.requestedAt, $0.projectID) < ($1.requestedAt, $1.projectID)
            }
        }
    }

    func load(projectID: String) throws -> RoomCloudBackupDeletionRequest? {
        try requireSafeIdentifier(projectID)
        return try lock.withLock {
            guard try existingRootIsPresent() else { return nil }
            try establishOwnedRoot()
            let url = try recordURL(projectID: projectID)
            guard try pathExists(url) else { return nil }
            return try decodeRecord(at: url, projectID: projectID)
        }
    }

    func replace(_ request: RoomCloudBackupDeletionRequest) throws {
        try requireSafeIdentifier(request.projectID)
        do { try request.validate() } catch { throw RoomCloudBackupDeletionJournalError.invalidRecord }
        try lock.withLock {
            try establishOwnedRoot()
            let destination = try recordURL(projectID: request.projectID)
            if try pathExists(destination) {
                try requireRegularFile(destination)
            }
            let directory = destination.deletingLastPathComponent()
            try requireDirectory(directory)
            let data = try Self.canonicalData(for: request)
            let stage = directory.appendingPathComponent(Self.stagePrefix + UUID().uuidString.lowercased())
            defer { try? removeOwnedStage(stage) }
            try data.write(to: stage, options: [.withoutOverwriting])
            try requireRegularFile(stage)
            guard try Data(contentsOf: stage, options: [.mappedIfSafe]) == data else {
                throw RoomCloudBackupDeletionJournalError.unsafeJournal
            }
            try data.write(to: destination, options: .atomic)
            try requireRegularFile(destination)
            guard try Data(contentsOf: destination, options: [.mappedIfSafe]) == data else {
                throw RoomCloudBackupDeletionJournalError.unsafeJournal
            }
        }
    }

    func remove(projectID: String) throws {
        try requireSafeIdentifier(projectID)
        try lock.withLock {
            guard try existingRootIsPresent() else { return }
            try establishOwnedRoot()
            let destination = try recordURL(projectID: projectID)
            guard try pathExists(destination) else { return }
            try requireRegularFile(destination)
            try beforeRemove?()
            try fileManager.removeItem(at: destination)
        }
    }

    private func decodeRecord(at url: URL, projectID: String) throws -> RoomCloudBackupDeletionRequest {
        try requireRegularFile(url)
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let request: RoomCloudBackupDeletionRequest
        do {
            request = try JSONDecoder().decode(RoomCloudBackupDeletionRequest.self, from: data)
            try request.validate()
        } catch {
            throw RoomCloudBackupDeletionJournalError.invalidRecord
        }
        guard request.projectID == projectID, try Self.canonicalData(for: request) == data else {
            throw RoomCloudBackupDeletionJournalError.invalidRecord
        }
        return request
    }

    /// lstat semantics: a dangling symlinked root is present and then rejected.
    private func existingRootIsPresent() throws -> Bool {
        try requireNoSymlinkInExistingAncestors(of: rootURL)
        return try pathExists(rootURL)
    }

    private func establishOwnedRoot() throws {
        try requireNoSymlinkInExistingAncestors(of: rootURL)
        if try pathExists(rootURL) {
            try requireDirectory(rootURL)
        } else {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try requireDirectory(rootURL)
        }
        let markerURL = rootURL.appendingPathComponent(Self.markerFilename)
        if try pathExists(markerURL) {
            try requireRegularFile(markerURL)
            let data = try Data(contentsOf: markerURL, options: [.mappedIfSafe])
            guard let marker = try? JSONDecoder().decode(Marker.self, from: data),
                  marker.schemaVersion == Self.schemaVersion,
                  marker.ownershipToken.range(of: "^[a-f0-9-]{36}$", options: .regularExpression) != nil,
                  try Self.canonicalData(for: marker) == data
            else { throw RoomCloudBackupDeletionJournalError.unsafeJournal }
        } else {
            let data = try Self.canonicalData(
                for: Marker(schemaVersion: Self.schemaVersion, ownershipToken: ownershipToken)
            )
            try data.write(to: markerURL, options: [.withoutOverwriting])
            try requireRegularFile(markerURL)
        }
        let records = rootURL.appendingPathComponent(Self.recordsDirectoryName, isDirectory: true)
        if try pathExists(records) {
            try requireDirectory(records)
        } else {
            try fileManager.createDirectory(at: records, withIntermediateDirectories: false)
            try requireDirectory(records)
        }
        for entry in try fileManager.contentsOfDirectory(
            at: records,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) {
            if entry.lastPathComponent.hasPrefix(Self.stagePrefix) {
                try removeOwnedStage(entry)
            } else if entry.pathExtension == "json" {
                try requireRegularFile(entry)
            } else {
                throw RoomCloudBackupDeletionJournalError.unsafeJournal
            }
        }
    }

    private func recordURL(projectID: String) throws -> URL {
        try requireSafeIdentifier(projectID)
        return rootURL
            .appendingPathComponent(Self.recordsDirectoryName, isDirectory: true)
            .appendingPathComponent("\(projectID).json")
    }

    private func requireSafeIdentifier(_ value: String) throws {
        guard value.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else {
            throw RoomCloudBackupDeletionJournalError.unsafeIdentifier
        }
    }

    private func removeOwnedStage(_ url: URL) throws {
        guard url.lastPathComponent.hasPrefix(Self.stagePrefix) else {
            throw RoomCloudBackupDeletionJournalError.unsafeJournal
        }
        guard try pathExists(url) else { return }
        try requireRegularFile(url)
        try fileManager.removeItem(at: url)
    }

    private func pathExists(_ url: URL) throws -> Bool {
        do {
            _ = try fileManager.attributesOfItem(atPath: url.path)
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return false
        }
    }

    private func requireDirectory(_ url: URL) throws {
        try requireNoSymlinkInExistingAncestors(of: url)
        let type = try fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        guard type == .typeDirectory else { throw RoomCloudBackupDeletionJournalError.unsafeJournal }
    }

    private func requireRegularFile(_ url: URL) throws {
        try requireNoSymlinkInExistingAncestors(of: url)
        let type = try fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        guard type == .typeRegular else { throw RoomCloudBackupDeletionJournalError.unsafeJournal }
    }

    private func requireNoSymlinkInExistingAncestors(of url: URL) throws {
        guard RoomStorageAncestorSafety.existingAncestorsAreSafe(of: url, fileManager: fileManager) else {
            throw RoomCloudBackupDeletionJournalError.unsafeJournal
        }
    }
}

enum RoomCloudBackupDeletionJournalRootResolver {
    static func resolve(arguments: [String], fileManager: FileManager) -> URL {
        if let root = IsolatedTestRoots.resolve(
            .cloudBackupDeletionJournal, arguments: arguments, fileManager: fileManager
        ) {
            return root
        }
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("RoomScanStudio", isDirectory: true)
            .appendingPathComponent("CloudBackupDeletionJournal", isDirectory: true)
    }
}
