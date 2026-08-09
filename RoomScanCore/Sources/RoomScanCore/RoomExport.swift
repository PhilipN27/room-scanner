import Foundation

/// Export is deliberately a frozen, head-revision handoff rather than a
/// backup or a copy of the authoritative room package/history.
public enum RoomExportError: Error, Sendable, Equatable {
    case invalidEntryPath(String)
    case duplicateEntryPath(String)
    case entryLimitExceeded
    case sizeLimitExceeded(String)
    case archiveLimitExceeded
    case destinationInsideProjectRoot
    case destinationAlreadyExists(String)
    case unsafeDestination(String)
    case staleHead(projectID: String, expected: String, actual: String)
    case legacyPlanlessEvidence(String)
    case missingRequiredArtifact(String)
    case sourceChangedAfterPreflight(String)
    case zipStructureInvalid(String)
    case cleanupFailed(String)
    case cancelled
}

/// A deliberately narrower path grammar than the package's relative paths.
/// ZIP entry names are app-owned ASCII names, never stored user paths.
public struct RoomExportEntryPath: Codable, Sendable, Equatable, Hashable, Comparable {
    public let value: String

    public init(_ value: String) throws {
        guard Self.isSafe(value) else {
            throw RoomExportError.invalidEntryPath(value)
        }
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    public static func < (lhs: RoomExportEntryPath, rhs: RoomExportEntryPath) -> Bool {
        lhs.value < rhs.value
    }

    public static func validateUnique(_ paths: [RoomExportEntryPath]) throws {
        var normalized = Set<String>()
        for path in paths {
            // ASCII-only input makes lowercasing a stable collision boundary
            // across default case-insensitive Apple filesystems.
            guard normalized.insert(path.value.lowercased()).inserted else {
                throw RoomExportError.duplicateEntryPath(path.value)
            }
        }
    }

    private static func isSafe(_ value: String) -> Bool {
        guard
            !value.isEmpty,
            value.utf8.count <= RoomExportLimits.maximumPathUTF8Bytes,
            !value.hasPrefix("/"),
            !value.hasPrefix("\\"),
            !value.contains("\\"),
            !value.contains(":"),
            value.unicodeScalars.allSatisfy({ scalar in
                switch scalar.value {
                case 48...57, 65...90, 97...122, 45, 46, 47, 95:
                    return true
                default:
                    return false
                }
            })
        else {
            return false
        }

        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }
}

public enum RoomExportLimits {
    /// The final ZIP may contain 4,096 entries, including two required derived
    /// files and the app-owned `manifest.json`.
    public static let maximumEntries = 4_096
    public static let manifestEntryCount = 1
    public static let mandatoryDerivedEntryCount = 2
    public static let maximumPreManifestEntries = maximumEntries - manifestEntryCount
    public static let maximumMaterializedEntries = maximumPreManifestEntries - mandatoryDerivedEntryCount
    public static let maximumPathUTF8Bytes = 255
    public static let maximumEntryBytes: UInt64 = 1_073_741_824
    public static let maximumArchiveBytes: UInt64 = 2_147_483_648
    public static let maximumDerivedBytes: UInt64 = 536_870_912
    public static let maximumPNGPixelDimension = 4_096
    public static let maximumPNGBytes: UInt64 = 67_108_864
    public static let maximumPDFPages = 32
    public static let maximumPDFBytes: UInt64 = 67_108_864

    /// Applies the final ZIP profile cap, not just the store snapshot cap.
    /// Keeping it here makes the manifest-slot reservation testable without
    /// allocating thousands of files.
    public static func finalArchiveEntryCount(
        forMaterializedEntries materializedEntryCount: Int,
        derivedEntryCount: Int
    ) throws -> Int {
        guard
            materializedEntryCount >= 0,
            derivedEntryCount == mandatoryDerivedEntryCount
        else {
            throw RoomExportError.entryLimitExceeded
        }
        let (preManifestCount, preManifestOverflow) = materializedEntryCount.addingReportingOverflow(derivedEntryCount)
        guard !preManifestOverflow, preManifestCount <= maximumPreManifestEntries else {
            throw RoomExportError.entryLimitExceeded
        }
        let (finalCount, finalOverflow) = preManifestCount.addingReportingOverflow(manifestEntryCount)
        guard !finalOverflow, finalCount <= maximumEntries else {
            throw RoomExportError.entryLimitExceeded
        }
        return finalCount
    }
}

/// Tests can lower these without allocating large fixtures. Production uses
/// the fixed product caps above.
public struct RoomZIPLimits: Sendable, Equatable {
    public var maxEntries: Int
    public var maxEntryBytes: UInt64
    public var maxArchiveBytes: UInt64

    public init(
        maxEntries: Int = RoomExportLimits.maximumEntries,
        maxEntryBytes: UInt64 = RoomExportLimits.maximumEntryBytes,
        maxArchiveBytes: UInt64 = RoomExportLimits.maximumArchiveBytes
    ) {
        self.maxEntries = maxEntries
        self.maxEntryBytes = maxEntryBytes
        self.maxArchiveBytes = maxArchiveBytes
    }
}

/// Limits applied before and during the store's external materialization. They
/// prevent a validated-but-huge attachment from exhausting scratch storage
/// before ZIP preflight begins. Tests may inject lower values.
public struct RoomExportMaterializationLimits: Sendable, Equatable {
    public var maxEntries: Int
    public var maxFileBytes: UInt64
    public var maxAggregateBytes: UInt64

    public init(
        maxEntries: Int = RoomExportLimits.maximumMaterializedEntries,
        maxFileBytes: UInt64 = RoomExportLimits.maximumEntryBytes,
        maxAggregateBytes: UInt64 = RoomExportLimits.maximumArchiveBytes
    ) {
        self.maxEntries = maxEntries
        self.maxFileBytes = maxFileBytes
        self.maxAggregateBytes = maxAggregateBytes
    }
}

public enum RoomExportOutput: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case metadataJSON
    case revisionJSON
    case semanticJSON
    case annotationsJSON
    case measurementsJSON
    case photosJSON
    case sourceMapJSON
    case thumbnailPNG
    case referencePhotos
    case capturedRoomDataJSON
    case capturedRoomJSON
    case nativeUSDZ
    case rawMesh
    case worldMap
    case provenance
    case floorPlanPNG
    case pdfSummary
    case glb
    case obj
    case ply
    case attachments
}

public enum RoomExportOutputStatus: String, Codable, Sendable, Equatable {
    case included
    case generated
    case skipped
    case failed
}

public enum RoomExportReasonCode: String, Codable, Sendable, Equatable {
    case noVerifiedConverter
    case deterministicFixture
    case noDeclaredNativeUSDZ
    case legacyPlanlessEvidence
    case noThumbnail
    case noReferencePhotos
    case noAttachments
    case evidenceUnavailable
    case notRequested
    case derivedGenerationFailed
}

public struct RoomExportOutputRecord: Codable, Sendable, Equatable {
    public var output: RoomExportOutput
    public var status: RoomExportOutputStatus
    public var reasonCode: RoomExportReasonCode?

    public init(
        output: RoomExportOutput,
        status: RoomExportOutputStatus,
        reasonCode: RoomExportReasonCode? = nil
    ) {
        self.output = output
        self.status = status
        self.reasonCode = reasonCode
    }
}

public struct RoomHeadExportDescriptor: Codable, Sendable, Equatable {
    public static let scope = "headRevisionOnly"
    public static let formatVersion = "roomscan-head-export-v1"

    public var projectID: String
    public var headRevisionID: String
    public var scope: String
    public var formatVersion: String

    public init(
        projectID: String,
        headRevisionID: String,
        scope: String = Self.scope,
        formatVersion: String = Self.formatVersion
    ) {
        self.projectID = projectID
        self.headRevisionID = headRevisionID
        self.scope = scope
        self.formatVersion = formatVersion
    }
}

/// The authority-relative scope of a package asset reference. A thumbnail is
/// project-root-relative, while photos and evidence are revision-relative;
/// keeping the scope makes the optional audit map unambiguous even when both
/// scopes happen to use the same relative spelling.
public enum RoomExportSourceReferenceScope: String, Codable, Sendable, Equatable {
    case project
    case revision
}

/// Maps validated package-relative references to app-owned export entry names.
/// Exported metadata, photos, and evidence JSON are rewritten to the outbound
/// names directly; this map is an unambiguous inspection aid, never a package
/// URL or a fallback resolver for a dangling exported reference.
public struct RoomExportSourceMapEntry: Codable, Sendable, Equatable {
    public var scope: RoomExportSourceReferenceScope
    public var sourceReference: String
    public var archivePath: String

    public init(
        scope: RoomExportSourceReferenceScope,
        sourceReference: String,
        archivePath: String
    ) {
        self.scope = scope
        self.sourceReference = sourceReference
        self.archivePath = archivePath
    }
}

public struct RoomExportSourceMap: Codable, Sendable, Equatable {
    public var projectID: String
    public var headRevisionID: String
    public var mappings: [RoomExportSourceMapEntry]

    public init(projectID: String, headRevisionID: String, mappings: [RoomExportSourceMapEntry]) {
        self.projectID = projectID
        self.headRevisionID = headRevisionID
        self.mappings = mappings
    }
}

/// A frozen source map from app-owned archive names to a fresh external
/// workspace. The source package URL is intentionally not represented here.
public struct RoomMaterializedExportEntry: Sendable, Equatable {
    public var entryPath: RoomExportEntryPath
    public var workspaceRelativePath: RoomRelativePath
    public var mediaType: String
    public var output: RoomExportOutput

    public init(
        entryPath: RoomExportEntryPath,
        workspaceRelativePath: RoomRelativePath,
        mediaType: String,
        output: RoomExportOutput
    ) {
        self.entryPath = entryPath
        self.workspaceRelativePath = workspaceRelativePath
        self.mediaType = mediaType
        self.output = output
    }
}

public struct RoomHeadExportMaterialization: Sendable, Equatable {
    public var workspaceURL: URL
    public var descriptor: RoomHeadExportDescriptor
    public var entries: [RoomMaterializedExportEntry]
    public var requestedOutputs: [RoomExportOutputRecord]
    public var sourceMap: [RoomExportSourceMapEntry]

    public init(
        workspaceURL: URL,
        descriptor: RoomHeadExportDescriptor,
        entries: [RoomMaterializedExportEntry],
        requestedOutputs: [RoomExportOutputRecord],
        sourceMap: [RoomExportSourceMapEntry] = []
    ) {
        self.workspaceURL = workspaceURL
        self.descriptor = descriptor
        self.entries = entries
        self.requestedOutputs = requestedOutputs
        self.sourceMap = sourceMap
    }
}

/// UIKit-derived providers write their bytes into the already materialized
/// external workspace. Core only validates and archives those supplied files.
public struct RoomDerivedExportArtifact: Sendable, Equatable {
    public var sourceURL: URL
    public var entryPath: RoomExportEntryPath
    public var mediaType: String
    public var output: RoomExportOutput
    /// PDF page count is supplied by the UIKit renderer rather than guessed
    /// from bytes. PNGs and other non-paged artifacts keep this nil.
    public var pageCount: Int?

    public init(
        sourceURL: URL,
        entryPath: RoomExportEntryPath,
        mediaType: String,
        output: RoomExportOutput,
        pageCount: Int? = nil
    ) {
        self.sourceURL = sourceURL
        self.entryPath = entryPath
        self.mediaType = mediaType
        self.output = output
        self.pageCount = pageCount
    }
}

public struct RoomExportManifestEntry: Codable, Sendable, Equatable {
    public var path: String
    public var mediaType: String
    public var byteCount: UInt64
    public var sha256Hex: String
    public var output: RoomExportOutput

    public init(
        path: String,
        mediaType: String,
        byteCount: UInt64,
        sha256Hex: String,
        output: RoomExportOutput
    ) {
        self.path = path
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.sha256Hex = sha256Hex
        self.output = output
    }
}

public struct RoomExportManifest: Codable, Sendable, Equatable {
    public static let integrityScope = "allEntriesExceptManifest"

    public var formatVersion: String
    public var scope: String
    public var integrityScope: String
    public var projectID: String
    public var headRevisionID: String
    public var zipProfileVersion: String
    public var entries: [RoomExportManifestEntry]
    public var requestedOutputs: [RoomExportOutputRecord]

    public init(
        formatVersion: String = RoomHeadExportDescriptor.formatVersion,
        scope: String = RoomHeadExportDescriptor.scope,
        integrityScope: String = Self.integrityScope,
        projectID: String,
        headRevisionID: String,
        zipProfileVersion: String,
        entries: [RoomExportManifestEntry],
        requestedOutputs: [RoomExportOutputRecord]
    ) {
        self.formatVersion = formatVersion
        self.scope = scope
        self.integrityScope = integrityScope
        self.projectID = projectID
        self.headRevisionID = headRevisionID
        self.zipProfileVersion = zipProfileVersion
        self.entries = entries
        self.requestedOutputs = requestedOutputs
    }
}

public struct RoomExportReceipt: Codable, Sendable, Equatable {
    public var projectID: String
    public var headRevisionID: String
    public var archiveSHA256: String
    public var archiveByteCount: UInt64
    public var manifestSHA256: String
    public var profileVersion: String

    public init(
        projectID: String,
        headRevisionID: String,
        archiveSHA256: String,
        archiveByteCount: UInt64,
        manifestSHA256: String,
        profileVersion: String
    ) {
        self.projectID = projectID
        self.headRevisionID = headRevisionID
        self.archiveSHA256 = archiveSHA256
        self.archiveByteCount = archiveByteCount
        self.manifestSHA256 = manifestSHA256
        self.profileVersion = profileVersion
    }
}

public struct RoomHeadExportResult: Sendable, Equatable {
    public var archiveURL: URL
    public var manifest: RoomExportManifest
    public var receipt: RoomExportReceipt

    public init(archiveURL: URL, manifest: RoomExportManifest, receipt: RoomExportReceipt) {
        self.archiveURL = archiveURL
        self.manifest = manifest
        self.receipt = receipt
    }
}
