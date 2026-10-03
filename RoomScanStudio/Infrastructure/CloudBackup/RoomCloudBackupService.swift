import Foundation
import RoomScanCore

struct RoomCloudBackupWorkspaceRecovery: Equatable {
    let removedOwnedLeaseCount: Int
    let preservedUnownedOrUnsafeEntryCount: Int
}

struct RoomCloudBackupLeaseCleanupError: Error {
    let workspaceURL: URL
    let message: String
}

/// Direct-child, marker-proven workspace leases for upload/download scratch.
/// The marker is deliberately outside the live package and is never archived
/// or restored. Crash recovery never broad-cleans this root.
@MainActor
final class RoomCloudBackupWorkspaceFactory {
    private static let leasePrefix = ".roomscan-cloud-backup-"
    private static let markerFilename = "backup-workspace-ownership.json"
    private static let markerVersion = "roomscan-cloud-backup-workspace-v1"

    private let rootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
    }

    func makeLease() throws -> URL {
        try ensureRoot()
        for _ in 0..<16 {
            let lease = rootURL.appendingPathComponent(
                Self.leasePrefix + UUID().uuidString.lowercased(),
                isDirectory: true
            )
            guard !pathExists(lease), !isSymbolicLink(lease) else { continue }
            try fileManager.createDirectory(at: lease, withIntermediateDirectories: false)
            do {
                try writeMarker(for: lease)
                return lease
            } catch {
                try? fileManager.removeItem(at: lease)
                throw error
            }
        }
        throw RoomBackupError.unsafeDestination(rootURL.path)
    }

    func cleanup(workspaceURL: URL) throws {
        let lease = workspaceURL.standardizedFileURL
        try validateOwnedLease(lease)
        try fileManager.removeItem(at: lease)
    }

    func recoverOwnedOrphans() throws -> RoomCloudBackupWorkspaceRecovery {
        try ensureRoot()
        let children = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        var removed = 0
        var preserved = 0
        for child in children {
            let candidate = child.standardizedFileURL
            guard candidate.deletingLastPathComponent() == rootURL,
                  candidate.lastPathComponent.hasPrefix(Self.leasePrefix)
            else { continue }
            do {
                try validateOwnedLease(candidate)
                try fileManager.removeItem(at: candidate)
                removed += 1
            } catch {
                preserved += 1
            }
        }
        return RoomCloudBackupWorkspaceRecovery(
            removedOwnedLeaseCount: removed,
            preservedUnownedOrUnsafeEntryCount: preserved
        )
    }

    private func ensureRoot() throws {
        if pathExists(rootURL) {
            guard directoryExists(rootURL), !isSymbolicLink(rootURL) else {
                throw RoomBackupError.unsafeDestination(rootURL.path)
            }
            return
        }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    private func writeMarker(for lease: URL) throws {
        guard lease.deletingLastPathComponent() == rootURL,
              lease.lastPathComponent.hasPrefix(Self.leasePrefix),
              !isSymbolicLink(lease), directoryExists(lease)
        else {
            throw RoomBackupError.unsafeDestination(lease.path)
        }
        let markerURL = lease.appendingPathComponent(Self.markerFilename)
        guard !pathExists(markerURL), !isSymbolicLink(markerURL) else {
            throw RoomBackupError.unsafeDestination(markerURL.path)
        }
        let marker = OwnershipMarker(
            formatVersion: Self.markerVersion,
            directoryName: lease.lastPathComponent,
            token: UUID().uuidString.lowercased()
        )
        let data = try RoomJSONCoding.makeEncoder().encode(marker)
        try RoomAtomicFileWriter.writeNewFile(
            data,
            to: markerURL,
            fileManager: fileManager
        )
    }

    private func validateOwnedLease(_ lease: URL) throws {
        guard lease.deletingLastPathComponent() == rootURL,
              lease.lastPathComponent.hasPrefix(Self.leasePrefix),
              pathExists(lease), !isSymbolicLink(lease), directoryExists(lease)
        else {
            throw RoomBackupError.unsafeDestination(lease.path)
        }
        let markerURL = lease.appendingPathComponent(Self.markerFilename)
        guard pathExists(markerURL), !isSymbolicLink(markerURL), try isRegularFile(markerURL) else {
            throw RoomBackupError.unsafeDestination(markerURL.path)
        }
        let marker = try RoomJSONCoding.makeDecoder().decode(
            OwnershipMarker.self,
            from: Data(contentsOf: markerURL)
        )
        guard marker.formatVersion == Self.markerVersion,
              marker.directoryName == lease.lastPathComponent,
              UUID(uuidString: marker.token) != nil
        else {
            throw RoomBackupError.unsafeDestination(markerURL.path)
        }
    }

    private func pathExists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path) || isSymbolicLink(url)
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func isRegularFile(_ url: URL) throws -> Bool {
        let values = try fileManager.attributesOfItem(atPath: url.path)
        return values[.type] as? FileAttributeType == .typeRegular
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private struct OwnershipMarker: Codable {
        let formatVersion: String
        let directoryName: String
        let token: String
    }
}

/// A narrow CloudKit-shaped boundary. Only the production transport imports
/// CloudKit; test fakes and the local-first UI depend on this neutral surface.
@MainActor
protocol RoomCloudBackupTransport {
    func checkAccount(containerIdentifier: String) async throws -> RoomCloudBackupAccountStatus
    func listBackups(containerIdentifier: String) async throws -> RoomCloudBackupListResult
    func ensureBackupZone(containerIdentifier: String) async throws
    func save(
        snapshot: RoomBackupSnapshot,
        containerIdentifier: String
    ) async throws -> RoomCloudBackupRemoteRecord
    func lookup(
        snapshotID: String,
        containerIdentifier: String
    ) async throws -> RoomCloudBackupRemoteRecord?
    func fetchArchive(
        record: RoomCloudBackupRemoteRecord,
        containerIdentifier: String,
        into destinationURL: URL
    ) async throws
    /// Deletes every record for `projectID` found by an uncapped zone listing,
    /// plus `knownRecordNames`. Missing records and a missing zone count as
    /// deleted; per-record failures are reported, not hidden.
    func deleteBackups(
        projectID: String,
        knownRecordNames: [String],
        containerIdentifier: String
    ) async throws -> RoomCloudBackupDeletionOutcome
    /// Deletes exactly the named records and never widens to the project.
    func deleteBackupRecords(
        named recordNames: [String],
        containerIdentifier: String
    ) async throws -> RoomCloudBackupDeletionOutcome
}

@MainActor
final class RoomCloudBackupService: RoomCloudBackupProviding {
    private struct PendingRecovery {
        let preparation: RoomBackupRecoveryPreparation
        let workspaceURL: URL
        var completedResult: RoomBackupRecoveryResult?
        var didDiscard = false
    }

    private let controller: RoomLibraryController
    private let workspaceFactory: RoomCloudBackupWorkspaceFactory
    private let transport: any RoomCloudBackupTransport
    private let deletionJournal: RoomCloudBackupDeletionJournal?
    private let clock: any RoomProjectClock
    private var pendingRecoveries: [String: PendingRecovery] = [:]
    private var cleanupLeases: Set<URL> = []

    init(
        controller: RoomLibraryController,
        workspaceFactory: RoomCloudBackupWorkspaceFactory,
        transport: any RoomCloudBackupTransport,
        deletionJournal: RoomCloudBackupDeletionJournal? = nil,
        clock: any RoomProjectClock = SystemRoomProjectClock()
    ) {
        self.controller = controller
        self.workspaceFactory = workspaceFactory
        self.transport = transport
        self.deletionJournal = deletionJournal
        self.clock = clock
    }

    func requestBackupDeletion(projectID: String, displayName: String, containerIdentifier: String) throws {
        guard let deletionJournal else { throw RoomCloudBackupDeletionServiceError.journalUnavailable }
        if var existing = try deletionJournal.load(projectID: projectID) {
            // A repeated request keeps its attempt history but follows the
            // latest container and name the user confirmed against.
            existing.containerIdentifier = containerIdentifier
            existing.displayName = Self.boundedDisplayName(displayName, fallback: existing.displayName)
            try deletionJournal.replace(existing)
            return
        }
        try deletionJournal.replace(RoomCloudBackupDeletionRequest(
            projectID: projectID,
            containerIdentifier: containerIdentifier,
            displayName: Self.boundedDisplayName(displayName, fallback: projectID),
            requestedAt: clock.now()
        ))
    }

    func performBackupDeletion(projectID: String) async throws -> RoomCloudBackupDeletionOutcome {
        guard let deletionJournal else { throw RoomCloudBackupDeletionServiceError.journalUnavailable }
        guard let request = try deletionJournal.load(projectID: projectID) else {
            throw RoomCloudBackupDeletionServiceError.requestNotFound(projectID)
        }
        let outcome: RoomCloudBackupDeletionOutcome
        do {
            outcome = try await transport.deleteBackups(
                projectID: request.projectID,
                knownRecordNames: request.knownRecordNames,
                containerIdentifier: request.containerIdentifier
            )
        } catch {
            let message = (error as? RoomCloudBackupTransportError)?.deletionFailureDescription
                ?? "The deletion attempt did not finish."
            try deletionJournal.replace(request.recordingFailure(at: clock.now(), message: message))
            throw error
        }
        if outcome.isComplete {
            // If this removal is interrupted, the next attempt finds nothing
            // remote, reports zero remaining, and removes the record then.
            try deletionJournal.remove(projectID: projectID)
        } else {
            try deletionJournal.replace(request.recordingAttempt(at: clock.now(), outcome: outcome))
        }
        return outcome
    }

    func pendingBackupDeletions() throws -> [RoomCloudBackupDeletionRequest] {
        try deletionJournal?.pendingRequests() ?? []
    }

    func deleteBackupRecord(
        _ record: RoomCloudBackupRemoteRecord,
        containerIdentifier: String
    ) async throws -> RoomCloudBackupDeletionOutcome {
        try await transport.deleteBackupRecords(
            named: [record.descriptor.recordName],
            containerIdentifier: containerIdentifier
        )
    }

    private static func boundedDisplayName(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? fallback : trimmed
        var result = ""
        for character in candidate {
            guard result.utf8.count + String(character).utf8.count
                <= RoomCloudBackupDeletionRequest.maximumDisplayNameUTF8Bytes else { break }
            result.append(character)
        }
        return result
    }

    func checkAccount(containerIdentifier: String) async throws -> RoomCloudBackupAccountStatus {
        try await transport.checkAccount(containerIdentifier: containerIdentifier)
    }

    func listBackups(containerIdentifier: String) async throws -> RoomCloudBackupListResult {
        try await transport.listBackups(containerIdentifier: containerIdentifier)
    }

    func backUp(
        projectID: String,
        expectedHeadRevisionID: String,
        containerIdentifier: String
    ) async throws -> RoomCloudBackupRemoteRecord {
        let lease = try workspaceFactory.makeLease()
        do {
            try Task.checkCancellation()
            let materialization = try await controller.materializeBackupSnapshot(
                projectID: projectID,
                expectedHeadRevisionID: expectedHeadRevisionID,
                into: lease.appendingPathComponent("package", isDirectory: true)
            )
            try Task.checkCancellation()
            let archiveURL = lease.appendingPathComponent("roomscan-project-backup.zip")
            let snapshot = try await RoomProjectBackupArchive.build(
                materialization: materialization,
                archiveURL: archiveURL
            )
            try Task.checkCancellation()
            try await transport.ensureBackupZone(containerIdentifier: containerIdentifier)
            // A cancelled explicit action must not begin a new upload after a
            // zone check merely because that check returned late.
            try Task.checkCancellation()
            let record: RoomCloudBackupRemoteRecord
            do {
                record = try await transport.save(snapshot: snapshot, containerIdentifier: containerIdentifier)
            } catch is CancellationError {
                if let existing = try await transport.lookup(
                    snapshotID: snapshot.descriptor.snapshotID,
                    containerIdentifier: containerIdentifier
                ), existing.descriptor.archiveSHA256 == snapshot.descriptor.archiveSHA256,
                   existing.descriptor.manifestSHA256 == snapshot.descriptor.manifestSHA256 {
                    record = existing
                } else {
                    throw RoomCloudBackupTransportError.cancellationOutcomeUnknown
                }
            }
            do {
                try workspaceFactory.cleanup(workspaceURL: lease)
            } catch {
                cleanupLeases.insert(lease)
                throw RoomCloudBackupLeaseCleanupError(
                    workspaceURL: lease,
                    message: "Backup uploaded, but its exact marker-owned workspace needs cleanup retry."
                )
            }
            return record
        } catch let error as RoomCloudBackupLeaseCleanupError {
            // Preserve the exact marker-owned lease for the coordinator's
            // explicit retry path; do not swallow or broad-clean it here.
            throw error
        } catch {
            do {
                try workspaceFactory.cleanup(workspaceURL: lease)
            } catch {
                cleanupLeases.insert(lease)
                throw RoomCloudBackupLeaseCleanupError(
                    workspaceURL: lease,
                    message: "Backup work stopped, but its exact marker-owned workspace needs cleanup retry."
                )
            }
            throw error
        }
    }

    func prepareRecovery(
        record: RoomCloudBackupRemoteRecord,
        containerIdentifier: String
    ) async throws -> RoomCloudBackupPreparedRecovery {
        let lease = try workspaceFactory.makeLease()
        do {
            try Task.checkCancellation()
            let archiveURL = lease.appendingPathComponent("downloaded-backup.zip")
            try await transport.fetchArchive(
                record: record,
                containerIdentifier: containerIdentifier,
                into: archiveURL
            )
            try Task.checkCancellation()
            let preparation = try await controller.prepareBackupRecovery(
                archiveURL: archiveURL,
                expectedCloudDescriptor: record.descriptor,
                into: lease.appendingPathComponent("recovery", isDirectory: true)
            )
            let publicPreparation = RoomCloudBackupPreparedRecovery(
                token: preparation.token,
                record: record
            )
            pendingRecoveries[publicPreparation.token] = PendingRecovery(
                preparation: preparation,
                workspaceURL: lease,
                completedResult: nil,
                didDiscard: false
            )
            return publicPreparation
        } catch {
            do {
                try workspaceFactory.cleanup(workspaceURL: lease)
            } catch {
                cleanupLeases.insert(lease)
                throw RoomCloudBackupLeaseCleanupError(
                    workspaceURL: lease,
                    message: "Recovery preparation stopped, but its exact marker-owned workspace needs cleanup retry."
                )
            }
            throw error
        }
    }

    func commitPreparedRecovery(
        _ preparation: RoomCloudBackupPreparedRecovery,
        asCopy: Bool
    ) async throws -> RoomBackupRecoveryResult {
        guard var pending = pendingRecoveries[preparation.token] else {
            throw RoomBackupError.preparedRecoveryNotFound(preparation.token)
        }
        let result: RoomBackupRecoveryResult
        if let completed = pending.completedResult {
            result = completed
        } else {
            result = try await controller.commitPreparedBackupRecovery(
                pending.preparation,
                conflictPolicy: asCopy ? .recoverAsCopy : .failIfDivergent
            )
            pending.completedResult = result
            pendingRecoveries[preparation.token] = pending
        }
        do {
            try workspaceFactory.cleanup(workspaceURL: pending.workspaceURL)
            pendingRecoveries.removeValue(forKey: preparation.token)
            return result
        } catch {
            cleanupLeases.insert(pending.workspaceURL)
            throw RoomCloudBackupLeaseCleanupError(
                workspaceURL: pending.workspaceURL,
                message: "Recovery promoted local package truth, but its exact marker-owned workspace needs cleanup retry."
            )
        }
    }

    func discardPreparedRecovery(_ preparation: RoomCloudBackupPreparedRecovery) async throws {
        guard var pending = pendingRecoveries[preparation.token] else {
            throw RoomBackupError.preparedRecoveryNotFound(preparation.token)
        }
        if pending.completedResult == nil {
            try await controller.discardPreparedBackupRecovery(pending.preparation)
            pending.didDiscard = true
            pendingRecoveries[preparation.token] = pending
        }
        do {
            try workspaceFactory.cleanup(workspaceURL: pending.workspaceURL)
            pendingRecoveries.removeValue(forKey: preparation.token)
        } catch {
            cleanupLeases.insert(pending.workspaceURL)
            throw RoomCloudBackupLeaseCleanupError(
                workspaceURL: pending.workspaceURL,
                message: "The exact marker-owned recovery workspace needs cleanup retry."
            )
        }
    }

    func retryCleanup() async throws -> Bool {
        let leases = cleanupLeases
        for lease in leases {
            try workspaceFactory.cleanup(workspaceURL: lease)
            cleanupLeases.remove(lease)
            let completedTokens = pendingRecoveries.compactMap { token, pending -> String? in
                guard pending.workspaceURL == lease,
                      pending.completedResult != nil || pending.didDiscard
                else { return nil }
                return token
            }
            for token in completedTokens {
                pendingRecoveries.removeValue(forKey: token)
            }
        }
        return cleanupLeases.isEmpty
    }
}

enum RoomCloudBackupScratchRootResolver {
    static func resolve(arguments: [String], fileManager: FileManager) -> URL {
        // Preserve marker-only lease recovery, including on reset launches.
        if let root = IsolatedTestRoots.resolve(
            .cloudBackupScratch, arguments: arguments, fileManager: fileManager, wipeOnReset: false
        ) {
            return root
        }
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("RoomScanStudio", isDirectory: true)
            .appendingPathComponent("CloudBackupScratch", isDirectory: true)
    }
}
