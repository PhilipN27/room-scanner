import Foundation
import RoomScanCore

/// Creates and removes only direct, app-owned export lease directories. The
/// lease root is outside `Projects`, so Core can reject accidental package
/// exports even if a caller passes the wrong URL.
struct RoomExportWorkspaceRecovery: Equatable {
    let removedOwnedLeaseCount: Int
    let preservedUnownedOrUnsafeEntryCount: Int
}

@MainActor
final class RoomExportWorkspaceFactory: RoomExportWorkspaceCleaning {
    private let rootURL: URL
    private let fileManager: FileManager
    private static let leasePrefix = ".roomscan-head-export-"
    private static let markerFilename = "lease-ownership.json"

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
                try writeOwnershipMarker(for: lease)
                return lease
            } catch {
                // The directory has just been created by this call, so this
                // is the only failure path permitted to remove it.
                try? fileManager.removeItem(at: lease)
                throw error
            }
        }
        throw RoomExportError.unsafeDestination(rootURL.path)
    }

    func cleanup(workspaceURL: URL) throws {
        let workspace = workspaceURL.standardizedFileURL
        try validateOwnedLease(workspace)
        try fileManager.removeItem(at: workspace)
    }

    /// Reconciles only direct, marker-proven lease children after a crash.
    /// Prefix matches alone are intentionally preserved: the recovery path
    /// never follows links, recurses through the root, or clears a broad
    /// scratch directory.
    func recoverOwnedOrphans() throws -> RoomExportWorkspaceRecovery {
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
            else {
                continue
            }
            do {
                try validateOwnedLease(candidate)
                try fileManager.removeItem(at: candidate)
                removed += 1
            } catch {
                // A markerless lookalike, a link, malformed marker, or a
                // non-directory is not owned. Preserve it for manual review.
                preserved += 1
            }
        }
        return RoomExportWorkspaceRecovery(
            removedOwnedLeaseCount: removed,
            preservedUnownedOrUnsafeEntryCount: preserved
        )
    }

    private func ensureRoot() throws {
        if pathExists(rootURL) {
            guard directoryExists(rootURL), !isSymbolicLink(rootURL) else {
                throw RoomExportError.unsafeDestination(rootURL.path)
            }
            return
        }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    private func writeOwnershipMarker(for workspace: URL) throws {
        guard
            workspace.deletingLastPathComponent() == rootURL,
            workspace.lastPathComponent.hasPrefix(Self.leasePrefix),
            !isSymbolicLink(workspace),
            directoryExists(workspace)
        else {
            throw RoomExportError.unsafeDestination(workspace.path)
        }
        let markerURL = workspace.appendingPathComponent(Self.markerFilename)
        guard !pathExists(markerURL), !isSymbolicLink(markerURL) else {
            throw RoomExportError.unsafeDestination(markerURL.path)
        }
        let marker = OwnershipMarker(
            leaseDirectoryName: workspace.lastPathComponent,
            token: UUID().uuidString.lowercased()
        )
        let data = try RoomJSONCoding.makeEncoder().encode(marker)
        do {
            try data.write(to: markerURL, options: [.atomic, .withoutOverwriting])
        } catch {
            throw RoomExportError.unsafeDestination(markerURL.path)
        }
    }

    private func validateOwnedLease(_ workspace: URL) throws {
        guard
            workspace.deletingLastPathComponent() == rootURL,
            workspace.lastPathComponent.hasPrefix(Self.leasePrefix),
            pathExists(workspace),
            !isSymbolicLink(workspace),
            directoryExists(workspace)
        else {
            throw RoomExportError.cleanupFailed("Export workspace ownership could not be proven.")
        }
        let markerURL = workspace.appendingPathComponent(Self.markerFilename)
        guard
            pathExists(markerURL),
            !isSymbolicLink(markerURL),
            try isRegularFile(markerURL)
        else {
            throw RoomExportError.cleanupFailed("Export workspace ownership marker is missing or unsafe.")
        }
        let marker: OwnershipMarker
        do {
            marker = try RoomJSONCoding.makeDecoder().decode(
                OwnershipMarker.self,
                from: Data(contentsOf: markerURL)
            )
        } catch {
            throw RoomExportError.cleanupFailed("Export workspace ownership marker is malformed.")
        }
        guard
            marker.formatVersion == OwnershipMarker.currentFormatVersion,
            marker.leaseDirectoryName == workspace.lastPathComponent,
            UUID(uuidString: marker.token) != nil
        else {
            throw RoomExportError.cleanupFailed("Export workspace ownership marker does not match this lease.")
        }
    }

    private func isRegularFile(_ url: URL) throws -> Bool {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return attributes[.type] as? FileAttributeType == .typeRegular
    }

    private func pathExists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path) || isSymbolicLink(url)
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private struct OwnershipMarker: Codable {
        static let currentFormatVersion = "roomscan-head-export-lease-v1"

        let formatVersion: String
        let leaseDirectoryName: String
        let token: String

        init(leaseDirectoryName: String, token: String) {
            formatVersion = Self.currentFormatVersion
            self.leaseDirectoryName = leaseDirectoryName
            self.token = token
        }
    }
}

@MainActor
protocol RoomHeadExportDeriving {
    func makeDerivedArtifacts(
        from materialization: RoomHeadExportMaterialization
    ) throws -> [RoomDerivedExportArtifact]
}

/// The production provider has no package URL access. It asks the library
/// controller for a frozen head workspace, derives bounded visual summaries,
/// then invokes the Foundation-only manifest/ZIP builder.
@MainActor
final class RoomExportService: RoomExportProviding {
    private let controller: RoomLibraryController
    private let workspaceFactory: RoomExportWorkspaceFactory
    private let derivedProvider: any RoomHeadExportDeriving

    init(
        controller: RoomLibraryController,
        workspaceFactory: RoomExportWorkspaceFactory,
        derivedProvider: any RoomHeadExportDeriving
    ) {
        self.controller = controller
        self.workspaceFactory = workspaceFactory
        self.derivedProvider = derivedProvider
    }

    func exportHead(
        projectID: String,
        expectedHeadRevisionID: String
    ) async throws -> RoomExportResult {
        let lease = try workspaceFactory.makeLease()
        do {
            let materialization = try await controller.materializeHeadForExport(
                projectID: projectID,
                expectedHeadRevisionID: expectedHeadRevisionID,
                into: lease.appendingPathComponent("head", isDirectory: true)
            )
            let artifacts = try derivedProvider.makeDerivedArtifacts(from: materialization)
            let archiveURL = lease.appendingPathComponent(
                "roomscan-head-\(expectedHeadRevisionID).zip"
            )
            let result = try await RoomHeadExportBuilder.build(
                materialization: materialization,
                derivedArtifacts: artifacts,
                archiveURL: archiveURL
            )
            return RoomExportResult(
                archiveURL: result.archiveURL,
                workspaceURL: lease,
                receipt: result.receipt
            )
        } catch {
            do {
                try workspaceFactory.cleanup(workspaceURL: lease)
            } catch {
                throw RoomExportLeaseCleanupError(
                    workspaceURL: lease,
                    message: "Export preparation failed and its temporary workspace could not be removed. Retry cleanup."
                )
            }
            throw error
        }
    }
}

enum RoomExportScratchRootResolver {
    private static let isolatedTestingDirectoryName = "RoomScanStudio-UI-Testing-ExportScratch"

    static func resolve(arguments: [String], fileManager: FileManager) -> URL {
        let isIsolatedUIRun = arguments.contains("--ui-testing")
            && arguments.contains("--reset-local-store")
        if isIsolatedUIRun {
            let temporaryRoot = fileManager.temporaryDirectory
                .resolvingSymlinksInPath()
                .standardizedFileURL
            return temporaryRoot.appendingPathComponent(
                isolatedTestingDirectoryName,
                isDirectory: true
            )
        }
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("RoomScanStudio", isDirectory: true)
            .appendingPathComponent("ExportScratch", isDirectory: true)
    }
}
