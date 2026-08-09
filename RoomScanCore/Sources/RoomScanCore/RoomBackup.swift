import Foundation

/// Errors for the deliberately separate Phase-6 full-project backup format.
/// A backup is never the source of truth: authoritative packages remain local
/// and these errors fail closed before a recovery can promote any directory.
public enum RoomBackupError: Error, Sendable, Equatable {
    case invalidArchivePath(String)
    case invalidPackagePath(String)
    case duplicatePath(String)
    case entryLimitExceeded
    case sizeLimitExceeded(String)
    case archiveLimitExceeded
    case destinationInsideProjectRoot
    case destinationAlreadyExists(String)
    case unsafeDestination(String)
    case staleHead(projectID: String, expected: String, actual: String)
    case missingOwnershipMarker(String)
    case invalidOwnershipMarker(String)
    case invalidBackupManifest(String)
    case descriptorMismatch(String)
    case recoveryConflict(String)
    case preparedRecoveryNotFound(String)
    case sourceChangedAfterPreflight(String)
    case zipStructureInvalid(String)
    case cancelled
    case storageFailure(String)
}

/// Product caps for a whole-project immutable snapshot. The final archive has
/// one app-owned manifest, leaving 4,095 package entries at most.
public struct RoomBackupLimits: Sendable, Equatable {
    public static let maximumArchiveEntries = 4_096
    public static let maximumPackageEntries = 4_095
    public static let maximumPathUTF8Bytes = 255
    public static let maximumPackageFileBytes: UInt64 = 256 * 1_024 * 1_024
    public static let maximumArchiveBytes: UInt64 = 512 * 1_024 * 1_024
    /// Manifest data is decoded in memory only after the ZIP reader has
    /// bounded it. 8 MiB is ample for 4,095 compact mapped entries.
    public static let maximumManifestBytes: UInt64 = 8 * 1_024 * 1_024

    public var maxPackageEntries: Int
    public var maxFileBytes: UInt64
    public var maxArchiveBytes: UInt64

    public init(
        maxPackageEntries: Int = RoomBackupLimits.maximumPackageEntries,
        maxFileBytes: UInt64 = RoomBackupLimits.maximumPackageFileBytes,
        maxArchiveBytes: UInt64 = RoomBackupLimits.maximumArchiveBytes
    ) {
        self.maxPackageEntries = maxPackageEntries
        self.maxFileBytes = maxFileBytes
        self.maxArchiveBytes = maxArchiveBytes
    }

    public func validatedZIPLimits() throws -> RoomZIPLimits {
        guard
            maxPackageEntries >= 0,
            maxPackageEntries <= Self.maximumPackageEntries,
            maxFileBytes > 0,
            maxFileBytes <= Self.maximumPackageFileBytes,
            maxArchiveBytes > 0,
            maxArchiveBytes <= Self.maximumArchiveBytes
        else {
            throw RoomBackupError.archiveLimitExceeded
        }
        let (archiveEntries, overflow) = maxPackageEntries.addingReportingOverflow(1)
        guard !overflow, archiveEntries <= Self.maximumArchiveEntries else {
            throw RoomBackupError.entryLimitExceeded
        }
        return RoomZIPLimits(
            maxEntries: archiveEntries,
            maxEntryBytes: maxFileBytes,
            maxArchiveBytes: maxArchiveBytes
        )
    }
}

/// Archive names are entirely app-owned ASCII, separate from valid package
/// paths that may contain Unicode or spaces. This keeps stored package paths
/// out of the ZIP trust boundary.
public struct RoomBackupArchivePath: Codable, Sendable, Equatable, Hashable, Comparable {
    public let value: String

    public init(_ value: String) throws {
        do {
            _ = try RoomExportEntryPath(value)
        } catch {
            throw RoomBackupError.invalidArchivePath(value)
        }
        self.value = value
    }

    public static func < (lhs: RoomBackupArchivePath, rhs: RoomBackupArchivePath) -> Bool {
        lhs.value < rhs.value
    }

    public func zipEntryPath() throws -> RoomExportEntryPath {
        // Construction above validated this grammar; retain the throwing bridge
        // so a future grammar change cannot turn this trust boundary into a
        // forced crash.
        try RoomExportEntryPath(value)
    }
}

/// A relative path inside an authoritative project package. It is carried in
/// the backup manifest so recovery can restore it only after the archive's
/// app-owned path and digest are independently verified.
public struct RoomBackupPackagePath: Codable, Sendable, Equatable, Hashable, Comparable {
    public let value: String

    public init(_ value: String) throws {
        guard RoomPathValidation.isSafeRelativePath(value) else {
            throw RoomBackupError.invalidPackagePath(value)
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else {
            throw RoomBackupError.invalidPackagePath(value)
        }
        if let first = components.first.map(String.init) {
            let normalizedFirst = first.precomposedStringWithCanonicalMapping.lowercased()
            guard normalizedFirst != "exports",
                  normalizedFirst != ".pending-revision.json",
                  !normalizedFirst.hasPrefix(".staging-"),
                  !normalizedFirst.hasPrefix(".recovery-")
            else {
                throw RoomBackupError.invalidPackagePath(value)
            }
        }
        // Revision-local exports and transaction artifacts are likewise never
        // part of a full-project backup, while ordinary attachment components
        // named `tmp` or `scratch` remain valid package data.
        if components.count >= 3,
           components[0] == "revisions" {
            let revisionChild = String(components[2])
            let normalizedChild = revisionChild.precomposedStringWithCanonicalMapping.lowercased()
            guard normalizedChild != "exports",
                  normalizedChild != ".pending-revision.json",
                  !normalizedChild.hasPrefix(".staging-"),
                  !normalizedChild.hasPrefix(".recovery-")
            else {
                throw RoomBackupError.invalidPackagePath(value)
            }
        }
        self.value = value
    }

    public static func < (lhs: RoomBackupPackagePath, rhs: RoomBackupPackagePath) -> Bool {
        lhs.value < rhs.value
    }
}

public struct RoomBackupMaterializationEntry: Sendable, Equatable {
    public var entryPath: RoomBackupArchivePath
    public var workspaceRelativePath: RoomRelativePath
    public var packageRelativePath: RoomBackupPackagePath
    public var mediaType: String

    public init(
        entryPath: RoomBackupArchivePath,
        workspaceRelativePath: RoomRelativePath,
        packageRelativePath: RoomBackupPackagePath,
        mediaType: String
    ) {
        self.entryPath = entryPath
        self.workspaceRelativePath = workspaceRelativePath
        self.packageRelativePath = packageRelativePath
        self.mediaType = mediaType
    }
}

/// A frozen, external byte-copy workspace. It deliberately contains all
/// immutable revision history, unlike the head-only export materialization.
public struct RoomBackupMaterialization: Sendable, Equatable {
    public var workspaceURL: URL
    public var projectID: String
    public var headRevisionID: String
    public var projectSchemaVersion: String
    public var displayName: String
    public var sourceUpdatedAt: Date
    public var revisionCount: Int
    public var entries: [RoomBackupMaterializationEntry]

    public init(
        workspaceURL: URL,
        projectID: String,
        headRevisionID: String,
        projectSchemaVersion: String,
        displayName: String,
        sourceUpdatedAt: Date,
        revisionCount: Int,
        entries: [RoomBackupMaterializationEntry]
    ) {
        self.workspaceURL = workspaceURL
        self.projectID = projectID
        self.headRevisionID = headRevisionID
        self.projectSchemaVersion = projectSchemaVersion
        self.displayName = displayName
        self.sourceUpdatedAt = sourceUpdatedAt
        self.revisionCount = revisionCount
        self.entries = entries
    }
}

public struct RoomBackupManifestEntry: Codable, Sendable, Equatable {
    public var archivePath: String
    public var packageRelativePath: String
    public var mediaType: String
    public var byteCount: UInt64
    public var sha256Hex: String

    public init(
        archivePath: String,
        packageRelativePath: String,
        mediaType: String,
        byteCount: UInt64,
        sha256Hex: String
    ) {
        self.archivePath = archivePath
        self.packageRelativePath = packageRelativePath
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.sha256Hex = sha256Hex
    }
}

/// `backup-manifest.json` is deliberately not in `entries`; its exact encoded
/// bytes become the content-addressed snapshot ID and avoid a self-hash loop.
public struct RoomBackupManifest: Codable, Sendable, Equatable {
    public static let formatVersion = "roomscan-project-backup-v1"
    public static let integrityScope = "allPackageEntriesExceptBackupManifest"

    public var formatVersion: String
    public var integrityScope: String
    public var projectID: String
    public var headRevisionID: String
    public var projectSchemaVersion: String
    public var displayName: String
    public var sourceUpdatedAt: Date
    public var revisionCount: Int
    public var entries: [RoomBackupManifestEntry]

    public init(
        formatVersion: String = Self.formatVersion,
        integrityScope: String = Self.integrityScope,
        projectID: String,
        headRevisionID: String,
        projectSchemaVersion: String,
        displayName: String,
        sourceUpdatedAt: Date,
        revisionCount: Int,
        entries: [RoomBackupManifestEntry]
    ) {
        self.formatVersion = formatVersion
        self.integrityScope = integrityScope
        self.projectID = projectID
        self.headRevisionID = headRevisionID
        self.projectSchemaVersion = projectSchemaVersion
        self.displayName = displayName
        self.sourceUpdatedAt = sourceUpdatedAt
        self.revisionCount = revisionCount
        self.entries = entries
    }
}

/// Foundation-only descriptor transported by the app's CloudKit boundary.
/// It never contains a CKRecord, an entitlement, or a filesystem URL.
public struct RoomCloudBackupDescriptor: Codable, Sendable, Equatable, Identifiable {
    public static let schemaVersion = "rssb1"
    public static let archiveFormat = RoomDeterministicZIP.profileVersion

    public var schemaVersion: String
    public var snapshotID: String
    public var projectID: String
    public var headRevisionID: String
    public var projectSchemaVersion: String
    public var displayName: String
    public var sourceUpdatedAt: Date
    public var revisionCount: Int
    public var fileCount: Int
    public var uncompressedByteCount: UInt64
    public var manifestSHA256: String
    public var archiveSHA256: String
    public var archiveByteCount: UInt64
    public var archiveFormat: String
    public var complete: Bool

    public var id: String { snapshotID }
    public var recordName: String { "rssb1-\(snapshotID)" }

    public init(
        schemaVersion: String = Self.schemaVersion,
        snapshotID: String,
        projectID: String,
        headRevisionID: String,
        projectSchemaVersion: String,
        displayName: String,
        sourceUpdatedAt: Date,
        revisionCount: Int,
        fileCount: Int,
        uncompressedByteCount: UInt64,
        manifestSHA256: String,
        archiveSHA256: String,
        archiveByteCount: UInt64,
        archiveFormat: String = Self.archiveFormat,
        complete: Bool = true
    ) {
        self.schemaVersion = schemaVersion
        self.snapshotID = snapshotID
        self.projectID = projectID
        self.headRevisionID = headRevisionID
        self.projectSchemaVersion = projectSchemaVersion
        self.displayName = displayName
        self.sourceUpdatedAt = sourceUpdatedAt
        self.revisionCount = revisionCount
        self.fileCount = fileCount
        self.uncompressedByteCount = uncompressedByteCount
        self.manifestSHA256 = manifestSHA256
        self.archiveSHA256 = archiveSHA256
        self.archiveByteCount = archiveByteCount
        self.archiveFormat = archiveFormat
        self.complete = complete
    }
}

public struct RoomBackupSnapshot: Sendable, Equatable {
    public var archiveURL: URL
    public var manifest: RoomBackupManifest
    public var descriptor: RoomCloudBackupDescriptor

    public init(
        archiveURL: URL,
        manifest: RoomBackupManifest,
        descriptor: RoomCloudBackupDescriptor
    ) {
        self.archiveURL = archiveURL
        self.manifest = manifest
        self.descriptor = descriptor
    }
}

/// Opaque handle to an already strict-validated isolated package stage. The
/// application cannot derive a package URL from it.
public struct RoomBackupRecoveryPreparation: Sendable, Equatable {
    public var token: String
    public var descriptor: RoomCloudBackupDescriptor

    public init(token: String, descriptor: RoomCloudBackupDescriptor) {
        self.token = token
        self.descriptor = descriptor
    }
}

public enum RoomBackupRecoveryConflictPolicy: String, Codable, Sendable, Equatable {
    case failIfDivergent
    case recoverAsCopy
}

public enum RoomBackupRecoveryResult: Sendable, Equatable {
    case restored(RoomProjectSummary)
    case noOp
    case recoveredCopy(RoomProjectSummary)
}
