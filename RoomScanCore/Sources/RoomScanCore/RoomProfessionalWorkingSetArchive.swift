import Foundation

/// Fail-closed errors for the additive professional archive family. These are
/// deliberately distinct from the existing package-backup errors so a caller
/// cannot mistake a professional working set for a CloudKit backup.
public enum RoomProfessionalArchiveError: Error, Sendable, Equatable {
    case invalidValue(path: String, reason: String)
    case invalidManifest(String)
    case descriptorMismatch(String)
    case forbiddenRawWorkingSetEntry(RoomProfessionalRawAssetClass)
    case unsafeArchiveDestination(String)
    case unsafeExtractionDestination(String)
    case archiveStructureInvalid(String)
    case storageFailure(String)
}

/// The only high-volume raw classes that can appear in the separate reviewed
/// raw archive. A default working set rejects every one of these values.
public enum RoomProfessionalRawAssetClass: String, Codable, Sendable, Equatable, CaseIterable {
    case rgb
    case depth
    case confidence
    case diagnostics
    case worldMap
}

/// The external, raw-redacted byte copy used to build a professional working
/// set. It is intentionally a backup materialization, never a live package
/// URL, and binds the copied bytes to one immutable source revision.
public struct RoomProfessionalWorkingCopy: Sendable, Equatable {
    public let backupMaterialization: RoomBackupMaterialization
    public let sourceRevision: RoomRedesignSourceRevision
    /// The only asset intentionally omitted from the external copy. This
    /// capability is created by `LocalRoomProjectStore`, whose source package
    /// validation knows the original asset-policy path.
    public let redactedWorldMapPackagePath: String?

    init(
        backupMaterialization: RoomBackupMaterialization,
        sourceRevision: RoomRedesignSourceRevision,
        redactedWorldMapPackagePath: String?
    ) throws {
        self.backupMaterialization = backupMaterialization
        self.sourceRevision = sourceRevision
        self.redactedWorldMapPackagePath = redactedWorldMapPackagePath
        try validate()
    }

    func validate() throws {
        do {
            try sourceRevision.validate()
        } catch {
            throw RoomProfessionalArchiveError.invalidValue(
                path: "sourceRevision",
                reason: "Working copy must bind one valid immutable source revision."
            )
        }
        guard
            backupMaterialization.projectID == sourceRevision.projectID,
            backupMaterialization.headRevisionID == sourceRevision.revisionID,
            backupMaterialization.projectSchemaVersion == sourceRevision.packageSchemaVersion,
            !backupMaterialization.entries.contains(where: {
                $0.packageRelativePath.value == redactedWorldMapPackagePath
            })
        else {
            throw RoomProfessionalArchiveError.invalidValue(
                path: "backupMaterialization",
                reason: "Working copy must be raw-redacted and bind the same project, head, and schema."
            )
        }
    }
}

/// Inventory kinds for the strict outer archive ledger. `.raw` exists solely
/// so validators can positively detect and reject malicious raw injections.
public enum RoomProfessionalWorkingSetEntryKind: Codable, Sendable, Equatable {
    case packageBackup
    case redesignCompanion
    case conceptSetManifest
    case conceptSetAttachment
    case conceptSourcePackageProvenance
    case raw(RoomProfessionalRawAssetClass)

    private enum CodingKeys: String, CodingKey {
        case type
        case rawAssetClass
    }

    public init(from decoder: Decoder) throws {
        try RoomProfessionalTrustedDecoding.requireTrusted(decoder)
        let container = try RoomProfessionalStrictCoding.container(
            decoder,
            allowed: ["type", "rawAssetClass"],
            required: ["type"]
        )
        switch try container.decode(String.self, forKey: .init("type")) {
        case "packageBackup":
            guard !container.contains(.init("rawAssetClass")) else {
                throw RoomProfessionalArchiveError.invalidManifest("packageBackup cannot carry a raw asset class.")
            }
            self = .packageBackup
        case "redesignCompanion":
            guard !container.contains(.init("rawAssetClass")) else {
                throw RoomProfessionalArchiveError.invalidManifest("redesignCompanion cannot carry a raw asset class.")
            }
            self = .redesignCompanion
        case "conceptSetManifest":
            guard !container.contains(.init("rawAssetClass")) else {
                throw RoomProfessionalArchiveError.invalidManifest("conceptSetManifest cannot carry a raw asset class.")
            }
            self = .conceptSetManifest
        case "conceptSetAttachment":
            guard !container.contains(.init("rawAssetClass")) else {
                throw RoomProfessionalArchiveError.invalidManifest("conceptSetAttachment cannot carry a raw asset class.")
            }
            self = .conceptSetAttachment
        case "conceptSourcePackageProvenance":
            guard !container.contains(.init("rawAssetClass")) else {
                throw RoomProfessionalArchiveError.invalidManifest("conceptSourcePackageProvenance cannot carry a raw asset class.")
            }
            self = .conceptSourcePackageProvenance
        case "raw":
            self = .raw(try container.decode(RoomProfessionalRawAssetClass.self, forKey: .init("rawAssetClass")))
        default:
            throw RoomProfessionalArchiveError.invalidManifest("Working-set entry kind is unknown.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .packageBackup:
            try container.encode("packageBackup", forKey: .type)
        case .redesignCompanion:
            try container.encode("redesignCompanion", forKey: .type)
        case .conceptSetManifest:
            try container.encode("conceptSetManifest", forKey: .type)
        case .conceptSetAttachment:
            try container.encode("conceptSetAttachment", forKey: .type)
        case .conceptSourcePackageProvenance:
            try container.encode("conceptSourcePackageProvenance", forKey: .type)
        case let .raw(assetClass):
            try container.encode("raw", forKey: .type)
            try container.encode(assetClass, forKey: .rawAssetClass)
        }
    }
}

/// One exact outer working-set entry. Digest/size closure is independently
/// rechecked after ZIP extraction; the media type is an inventory claim used
/// by callers, not a ZIP metadata assertion.
public struct RoomProfessionalWorkingSetEntry: Codable, Sendable, Equatable {
    public let path: String
    public let kind: RoomProfessionalWorkingSetEntryKind
    public let mediaType: String
    public let byteCount: UInt64
    public let sha256: String

    public init(
        path: String,
        kind: RoomProfessionalWorkingSetEntryKind,
        mediaType: String,
        byteCount: UInt64,
        sha256: String
    ) throws {
        self.path = path
        self.kind = kind
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.sha256 = sha256
        try validate()
    }

    public func validate() throws {
        do {
            _ = try RoomExportEntryPath(path)
        } catch {
            throw RoomProfessionalArchiveError.invalidValue(path: "entries.path", reason: "Entry path must use the app-owned ZIP grammar.")
        }
        guard !mediaType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RoomProfessionalArchiveError.invalidValue(path: "entries.mediaType", reason: "Entry media type is required.")
        }
        try RoomProfessionalArchiveSupport.requireDigest(sha256, at: "entries.sha256")
        guard byteCount > 0 else {
            throw RoomProfessionalArchiveError.invalidValue(path: "entries.byteCount", reason: "Entry byte count must be positive.")
        }
        switch kind {
        case .packageBackup:
            guard path == RoomProfessionalWorkingSetArchive.packageBackupEntryPath else {
                throw RoomProfessionalArchiveError.invalidValue(path: "entries.path", reason: "Package backup has one reserved entry path.")
            }
        case .redesignCompanion:
            guard path == "companions/redesign.json" else {
                throw RoomProfessionalArchiveError.invalidValue(path: "entries.path", reason: "Redesign companion has one reserved entry path.")
            }
        case .conceptSetManifest:
            guard RoomProfessionalArchiveSupport.isConceptSetManifestPath(path) else {
                throw RoomProfessionalArchiveError.invalidValue(path: "entries.path", reason: "Concept Set manifest path is not in the reserved namespace.")
            }
        case .conceptSetAttachment:
            guard RoomProfessionalArchiveSupport.isConceptSetAttachmentPath(path) else {
                throw RoomProfessionalArchiveError.invalidValue(path: "entries.path", reason: "Concept Set attachment path is not in the reserved namespace.")
            }
        case .conceptSourcePackageProvenance:
            guard RoomProfessionalArchiveSupport.isConceptSourcePackageProvenancePath(path) else {
                throw RoomProfessionalArchiveError.invalidValue(path: "entries.path", reason: "Concept source-package provenance path is not in the reserved namespace.")
            }
        case let .raw(assetClass):
            guard path.hasPrefix("raw/\(assetClass.rawValue)-") else {
                throw RoomProfessionalArchiveError.invalidValue(path: "entries.path", reason: "Raw entry path must name its classified raw asset.")
            }
        }
    }

    public init(from decoder: Decoder) throws {
        try RoomProfessionalTrustedDecoding.requireTrusted(decoder)
        let container = try RoomProfessionalStrictCoding.container(
            decoder,
            allowed: ["path", "kind", "mediaType", "byteCount", "sha256"],
            required: ["path", "kind", "mediaType", "byteCount", "sha256"]
        )
        path = try container.decode(String.self, forKey: .init("path"))
        kind = try container.decode(RoomProfessionalWorkingSetEntryKind.self, forKey: .init("kind"))
        mediaType = try container.decode(String.self, forKey: .init("mediaType"))
        byteCount = try container.decode(UInt64.self, forKey: .init("byteCount"))
        sha256 = try container.decode(String.self, forKey: .init("sha256"))
        try validate()
    }
}

/// A companion is source-bound before it can enter the outer archive. Split 3
/// supplies canonical redesign/Concept Set bytes through this value; Split 2
/// owns the envelope and its closure rules.
public struct RoomProfessionalWorkingSetCompanion: Sendable, Equatable {
    public let sourceRevision: RoomRedesignSourceRevision
    public let path: String
    public let kind: RoomProfessionalWorkingSetEntryKind
    public let mediaType: String
    public let data: Data

    public init(
        sourceRevision: RoomRedesignSourceRevision,
        path: String,
        kind: RoomProfessionalWorkingSetEntryKind,
        mediaType: String,
        data: Data
    ) throws {
        self.sourceRevision = sourceRevision
        self.path = path
        self.kind = kind
        self.mediaType = mediaType
        self.data = data
        try validate()
    }

    public func validate() throws {
        try sourceRevision.validate()
        guard !data.isEmpty else {
            throw RoomProfessionalArchiveError.invalidValue(path: "companions.data", reason: "Companion bytes must be nonempty.")
        }
        switch kind {
        case .packageBackup, .raw:
            throw RoomProfessionalArchiveError.invalidValue(path: "companions.kind", reason: "Only redesign, Concept Set, and AI-ready provenance companions are allowed in a working set.")
        default:
            break
        }
        _ = try RoomProfessionalWorkingSetEntry(
            path: path,
            kind: kind,
            mediaType: mediaType,
            byteCount: UInt64(data.count),
            sha256: RoomSHA256.hexDigest(of: data)
        )
    }
}

/// Canonical closed ledger for one professional working set. The global source
/// binding applies to every listed entry, including the inner package backup.
public struct RoomProfessionalWorkingSetManifest: Codable, Sendable, Equatable {
    public static let schemaVersion = "roomscan-professional-working-set-manifest-v1"

    public var schemaVersion: String
    public var projectID: String
    public var headRevisionID: String
    public var sourceRevision: RoomRedesignSourceRevision
    public var packageDescriptor: RoomCloudBackupDescriptor
    public var entries: [RoomProfessionalWorkingSetEntry]
    public var conceptMappingAdjustments: [RoomProfessionalConceptMappingAdjustment]

    public init(
        schemaVersion: String = Self.schemaVersion,
        projectID: String,
        headRevisionID: String,
        sourceRevision: RoomRedesignSourceRevision,
        packageDescriptor: RoomCloudBackupDescriptor,
        entries: [RoomProfessionalWorkingSetEntry],
        conceptMappingAdjustments: [RoomProfessionalConceptMappingAdjustment] = []
    ) throws {
        self.schemaVersion = schemaVersion
        self.projectID = projectID
        self.headRevisionID = headRevisionID
        self.sourceRevision = sourceRevision
        self.packageDescriptor = packageDescriptor
        self.entries = entries
        self.conceptMappingAdjustments = conceptMappingAdjustments
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == Self.schemaVersion else {
            throw RoomProfessionalArchiveError.invalidManifest("Unsupported working-set manifest schema.")
        }
        try RoomProfessionalArchiveSupport.requireIdentifier(projectID, at: "projectID")
        try RoomProfessionalArchiveSupport.requireIdentifier(headRevisionID, at: "headRevisionID")
        try sourceRevision.validate()
        guard sourceRevision.projectID == projectID, sourceRevision.revisionID == headRevisionID else {
            throw RoomProfessionalArchiveError.invalidManifest("Manifest source revision must equal the project head binding.")
        }
        do {
            try RoomProjectBackupArchive.validate(descriptor: packageDescriptor)
        } catch {
            throw RoomProfessionalArchiveError.invalidManifest("Inner package descriptor is invalid.")
        }
        guard packageDescriptor.projectID == projectID, packageDescriptor.headRevisionID == headRevisionID else {
            throw RoomProfessionalArchiveError.invalidManifest("Inner package descriptor disagrees with the outer source binding.")
        }
        guard !entries.isEmpty, entries == entries.sorted(by: { $0.path < $1.path }) else {
            throw RoomProfessionalArchiveError.invalidManifest("Working-set entries must be nonempty and stably ordered.")
        }
        var paths = Set<String>()
        var packageBackupCount = 0
        for entry in entries {
            try entry.validate()
            guard paths.insert(entry.path.lowercased()).inserted else {
                throw RoomProfessionalArchiveError.invalidManifest("Working-set entry paths collide.")
            }
            switch entry.kind {
            case .packageBackup:
                packageBackupCount += 1
            case let .raw(assetClass):
                throw RoomProfessionalArchiveError.forbiddenRawWorkingSetEntry(assetClass)
            default:
                break
            }
        }
        guard packageBackupCount == 1 else {
            throw RoomProfessionalArchiveError.invalidManifest("Working set must contain exactly one package backup.")
        }
        guard conceptMappingAdjustments == conceptMappingAdjustments.sorted(by: {
            if $0.conceptSetID != $1.conceptSetID { return $0.conceptSetID < $1.conceptSetID }
            return $0.attachmentID < $1.attachmentID
        })
        else {
            throw RoomProfessionalArchiveError.invalidManifest("Concept mapping adjustments must be in stable Concept Set and attachment order.")
        }
        var adjustmentIDs = Set<String>()
        for adjustment in conceptMappingAdjustments {
            do {
                try adjustment.validate()
            } catch {
                throw RoomProfessionalArchiveError.invalidManifest("Concept mapping adjustment is invalid.")
            }
            guard adjustmentIDs.insert("\(adjustment.conceptSetID)/\(adjustment.attachmentID)").inserted else {
                throw RoomProfessionalArchiveError.invalidManifest("Concept mapping adjustments must be unique.")
            }
        }
    }

    public init(from decoder: Decoder) throws {
        try RoomProfessionalTrustedDecoding.requireTrusted(decoder)
        let container = try RoomProfessionalStrictCoding.container(
            decoder,
            allowed: ["schemaVersion", "projectID", "headRevisionID", "sourceRevision", "packageDescriptor", "entries", "conceptMappingAdjustments"],
            required: ["schemaVersion", "projectID", "headRevisionID", "sourceRevision", "packageDescriptor", "entries", "conceptMappingAdjustments"]
        )
        schemaVersion = try container.decode(String.self, forKey: .init("schemaVersion"))
        projectID = try container.decode(String.self, forKey: .init("projectID"))
        headRevisionID = try container.decode(String.self, forKey: .init("headRevisionID"))
        sourceRevision = try container.decode(RoomRedesignSourceRevision.self, forKey: .init("sourceRevision"))
        packageDescriptor = try container.decode(RoomCloudBackupDescriptor.self, forKey: .init("packageDescriptor"))
        entries = try container.decode([RoomProfessionalWorkingSetEntry].self, forKey: .init("entries"))
        conceptMappingAdjustments = try container.decode(
            [RoomProfessionalConceptMappingAdjustment].self,
            forKey: .init("conceptMappingAdjustments")
        )
        try validate()
    }
}

public struct RoomProfessionalWorkingSetSnapshot: Sendable, Equatable {
    public let archiveURL: URL
    public let manifest: RoomProfessionalWorkingSetManifest
    public let descriptor: RoomProfessionalWorkingSetDescriptor
    public let conceptMappingAdjustments: [RoomProfessionalConceptMappingAdjustment]

    public init(
        archiveURL: URL,
        manifest: RoomProfessionalWorkingSetManifest,
        descriptor: RoomProfessionalWorkingSetDescriptor,
        conceptMappingAdjustments: [RoomProfessionalConceptMappingAdjustment]? = nil
    ) {
        self.archiveURL = archiveURL
        self.manifest = manifest
        self.descriptor = descriptor
        self.conceptMappingAdjustments = conceptMappingAdjustments ?? manifest.conceptMappingAdjustments
    }
}

public struct RoomProfessionalWorkingSetExtraction: Sendable, Equatable {
    public let manifest: RoomProfessionalWorkingSetManifest
    public let packageDescriptor: RoomCloudBackupDescriptor

    public init(manifest: RoomProfessionalWorkingSetManifest, packageDescriptor: RoomCloudBackupDescriptor) {
        self.manifest = manifest
        self.packageDescriptor = packageDescriptor
    }
}

/// Deterministic outer envelope around the redacted inner package backup and
/// source-bound companion bytes. The only default package payload is the
/// inner backup; raw evidence has a separate reviewed archive type.
public enum RoomProfessionalWorkingSetArchive {
    public static let manifestEntryPath = "working-set-manifest.json"
    public static let packageBackupEntryPath = "package-backup.zip"

    public static func build(
        workingCopy: RoomProfessionalWorkingCopy,
        archiveURL: URL,
        companionPreparation: RoomProfessionalWorkingSetCompanionPreparation
    ) async throws -> RoomProfessionalWorkingSetSnapshot {
        try companionPreparation.validate()
        guard companionPreparation.sourceRevision == workingCopy.sourceRevision else {
            throw RoomProfessionalArchiveError.invalidValue(
                path: "companionPreparation.sourceRevision",
                reason: "Working-set companion preparation must bind the working copy's immutable source revision."
            )
        }
        return try await build(
            workingCopy: workingCopy,
            archiveURL: archiveURL,
            companions: companionPreparation.companions,
            conceptMappingAdjustments: companionPreparation.conceptMappingAdjustments
        )
    }

    public static func build(
        workingCopy: RoomProfessionalWorkingCopy,
        archiveURL: URL,
        companions: [RoomProfessionalWorkingSetCompanion] = [],
        conceptMappingAdjustments: [RoomProfessionalConceptMappingAdjustment] = []
    ) async throws -> RoomProfessionalWorkingSetSnapshot {
        try workingCopy.validate()
        try RoomProfessionalArchiveSupport.requireNewArchiveDestination(archiveURL)
        try RoomProfessionalArchiveSupport.validateRawRedactedMaterialization(workingCopy)
        try RoomProfessionalArchiveSupport.validateCompanionPayloads(
            companions,
            sourceRevision: workingCopy.sourceRevision,
            conceptMappingAdjustments: conceptMappingAdjustments
        )
        let workspace = workingCopy.backupMaterialization.workspaceURL.standardizedFileURL
        try RoomProfessionalArchiveSupport.requireDirectory(workspace, at: "workingCopy.workspaceURL")

        let packageArchiveURL = workspace.appendingPathComponent(packageBackupEntryPath)
        guard !RoomProfessionalArchiveSupport.pathExists(packageArchiveURL) else {
            throw RoomProfessionalArchiveError.storageFailure("Working copy already has a package backup entry.")
        }
        let packageSnapshot = try await RoomProjectBackupArchive.build(
            materialization: workingCopy.backupMaterialization,
            archiveURL: packageArchiveURL
        )

        let companionStage = workspace.appendingPathComponent(
            ".roomscan-professional-working-set-input-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: companionStage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: companionStage) }

        var entries: [RoomProfessionalWorkingSetEntry] = [try RoomProfessionalWorkingSetEntry(
            path: packageBackupEntryPath,
            kind: .packageBackup,
            mediaType: "application/zip",
            byteCount: packageSnapshot.descriptor.archiveByteCount,
            sha256: packageSnapshot.descriptor.archiveSHA256
        )]
        var inputs: [RoomZIPInput] = [RoomZIPInput(
            sourceURL: packageArchiveURL,
            entryPath: try RoomExportEntryPath(packageBackupEntryPath),
            mediaType: "application/zip"
        )]
        var companionPaths = Set<String>([packageBackupEntryPath])
        for companion in companions.sorted(by: { $0.path < $1.path }) {
            try companion.validate()
            guard companion.sourceRevision == workingCopy.sourceRevision else {
                throw RoomProfessionalArchiveError.invalidValue(
                    path: "companions.sourceRevision",
                    reason: "Every companion must bind the working copy's immutable source revision."
                )
            }
            guard companionPaths.insert(companion.path.lowercased()).inserted else {
                throw RoomProfessionalArchiveError.invalidManifest("Companion paths collide with the working-set ledger.")
            }
            let sourceURL = companionStage.appendingPathComponent(companion.path)
            try RoomProfessionalArchiveSupport.writeNewFile(companion.data, to: sourceURL)
            let entry = try RoomProfessionalWorkingSetEntry(
                path: companion.path,
                kind: companion.kind,
                mediaType: companion.mediaType,
                byteCount: UInt64(companion.data.count),
                sha256: RoomSHA256.hexDigest(of: companion.data)
            )
            entries.append(entry)
            inputs.append(RoomZIPInput(
                sourceURL: sourceURL,
                entryPath: try RoomExportEntryPath(companion.path),
                mediaType: companion.mediaType
            ))
        }
        entries.sort { $0.path < $1.path }
        let manifest = try RoomProfessionalWorkingSetManifest(
            projectID: workingCopy.backupMaterialization.projectID,
            headRevisionID: workingCopy.backupMaterialization.headRevisionID,
            sourceRevision: workingCopy.sourceRevision,
            packageDescriptor: packageSnapshot.descriptor,
            entries: entries,
            conceptMappingAdjustments: conceptMappingAdjustments
        )
        let manifestData = try RoomProfessionalSyncCanonicalJSON.encode(manifest)
        let manifestURL = companionStage.appendingPathComponent(manifestEntryPath)
        try RoomProfessionalArchiveSupport.writeNewFile(manifestData, to: manifestURL)
        inputs.append(RoomZIPInput(
            sourceURL: manifestURL,
            entryPath: try RoomExportEntryPath(manifestEntryPath),
            mediaType: "application/json"
        ))

        let receipt: RoomZIPArchiveReceipt
        do {
            let digests = try await RoomDeterministicZIP.preflight(
                inputs: inputs,
                limits: RoomProfessionalArchiveSupport.zipLimits
            )
            receipt = try await RoomDeterministicZIP.write(
                inputs: inputs,
                to: archiveURL,
                limits: RoomProfessionalArchiveSupport.zipLimits,
                expectedDigests: digests
            )
        } catch {
            throw RoomProfessionalArchiveError.archiveStructureInvalid("Unable to write deterministic working-set archive.")
        }
        let descriptor = try RoomProfessionalWorkingSetDescriptor(
            snapshotID: RoomSHA256.hexDigest(of: manifestData),
            projectID: manifest.projectID,
            headRevisionID: manifest.headRevisionID,
            packageDescriptor: packageSnapshot.descriptor,
            archiveSHA256: receipt.archiveSHA256,
            archiveByteCount: receipt.archiveByteCount
        )
        return RoomProfessionalWorkingSetSnapshot(
            archiveURL: archiveURL,
            manifest: manifest,
            descriptor: descriptor,
            conceptMappingAdjustments: conceptMappingAdjustments
        )
    }

    /// Derives the complete local descriptor from a downloaded hosted object
    /// without trusting identifiers or package metadata supplied by the
    /// service. The hosted response binds only the outer bytes and canonical
    /// manifest digest; every remaining descriptor field comes from that
    /// digest-bound, strict manifest. This inspection never promotes files and
    /// leaves the caller-owned scratch directory empty on success or failure.
    public static func inspectDownloadedArchive(
        archiveURL: URL,
        expectedManifestSHA256: String,
        expectedArchiveSHA256: String,
        expectedArchiveByteCount: UInt64,
        in scratchDirectoryURL: URL
    ) async throws -> RoomProfessionalWorkingSetDescriptor {
        try RoomProfessionalArchiveSupport.requireDigest(
            expectedManifestSHA256,
            at: "expectedManifestSHA256"
        )
        try RoomProfessionalArchiveSupport.requireDigest(
            expectedArchiveSHA256,
            at: "expectedArchiveSHA256"
        )
        guard expectedArchiveByteCount > 0,
              expectedArchiveByteCount <= RoomProfessionalArchiveSupport.zipLimits.maxArchiveBytes
        else {
            throw RoomProfessionalArchiveError.invalidValue(
                path: "expectedArchiveByteCount",
                reason: "Downloaded working set must have a positive bounded byte count."
            )
        }
        try RoomProfessionalArchiveSupport.requireOwnedEmptyExtractionDirectory(
            scratchDirectoryURL
        )
        try RoomProfessionalArchiveSupport.verifyArchive(
            archiveURL,
            expectedSHA256: expectedArchiveSHA256,
            expectedByteCount: expectedArchiveByteCount
        )

        let stage = try RoomProfessionalArchiveSupport.makeExtractionStage(
            in: scratchDirectoryURL,
            prefix: ".roomscan-professional-download-inspection-"
        )
        defer { try? FileManager.default.removeItem(at: stage) }

        let extracted: [RoomZIPEntryDigest]
        do {
            extracted = try await RoomDeterministicZIP.extractVerifiedStoreEntries(
                from: archiveURL,
                into: stage,
                limits: RoomProfessionalArchiveSupport.zipLimits,
                maximumByteCountByEntryPath: [manifestEntryPath: RoomBackupLimits.maximumManifestBytes]
            )
        } catch {
            throw RoomProfessionalArchiveError.archiveStructureInvalid(
                "Downloaded working-set ZIP structure failed validation."
            )
        }
        let manifestData = try RoomProfessionalArchiveSupport.readBoundedRegularFile(
            stage.appendingPathComponent(manifestEntryPath),
            maximumBytes: RoomBackupLimits.maximumManifestBytes,
            at: manifestEntryPath
        )
        guard RoomSHA256.hexDigest(of: manifestData) == expectedManifestSHA256 else {
            throw RoomProfessionalArchiveError.descriptorMismatch(
                "Working-set manifest digest differs from the hosted recovery binding."
            )
        }
        let manifest = try RoomProfessionalArchiveSupport.decodeWorkingSetManifest(manifestData)
        try manifest.validate()
        try RoomProfessionalArchiveSupport.validateOuterClosure(
            extracted: extracted,
            entries: manifest.entries,
            manifestEntryPath: manifestEntryPath
        )
        return try RoomProfessionalWorkingSetDescriptor(
            snapshotID: expectedManifestSHA256,
            projectID: manifest.projectID,
            headRevisionID: manifest.headRevisionID,
            packageDescriptor: manifest.packageDescriptor,
            archiveSHA256: expectedArchiveSHA256,
            archiveByteCount: expectedArchiveByteCount
        )
    }

    public static func extractAndVerify(
        archiveURL: URL,
        expectedDescriptor: RoomProfessionalWorkingSetDescriptor,
        into destinationURL: URL
    ) async throws -> RoomProfessionalWorkingSetExtraction {
        try expectedDescriptor.validate()
        try RoomProfessionalArchiveSupport.requireOwnedEmptyExtractionDirectory(destinationURL)
        try RoomProfessionalArchiveSupport.verifyArchive(
            archiveURL,
            expectedSHA256: expectedDescriptor.archiveSHA256,
            expectedByteCount: expectedDescriptor.archiveByteCount
        )
        let stage = try RoomProfessionalArchiveSupport.makeExtractionStage(
            in: destinationURL,
            prefix: ".roomscan-professional-working-set-stage-"
        )
        var stageExists = true
        defer {
            if stageExists { try? FileManager.default.removeItem(at: stage) }
        }

        let extracted: [RoomZIPEntryDigest]
        do {
            extracted = try await RoomDeterministicZIP.extractVerifiedStoreEntries(
                from: archiveURL,
                into: stage,
                limits: RoomProfessionalArchiveSupport.zipLimits,
                maximumByteCountByEntryPath: [manifestEntryPath: RoomBackupLimits.maximumManifestBytes]
            )
        } catch {
            throw RoomProfessionalArchiveError.archiveStructureInvalid("Working-set ZIP structure or extraction failed validation.")
        }
        let manifestURL = stage.appendingPathComponent(manifestEntryPath)
        let manifestData = try RoomProfessionalArchiveSupport.readBoundedRegularFile(
            manifestURL,
            maximumBytes: RoomBackupLimits.maximumManifestBytes,
            at: manifestEntryPath
        )
        guard RoomSHA256.hexDigest(of: manifestData) == expectedDescriptor.snapshotID else {
            throw RoomProfessionalArchiveError.descriptorMismatch("Working-set manifest digest differs from its descriptor.")
        }
        let manifest = try RoomProfessionalArchiveSupport.decodeWorkingSetManifest(manifestData)
        try manifest.validate()
        guard
            manifest.projectID == expectedDescriptor.projectID,
            manifest.headRevisionID == expectedDescriptor.headRevisionID,
            manifest.packageDescriptor == expectedDescriptor.packageDescriptor
        else {
            throw RoomProfessionalArchiveError.descriptorMismatch("Working-set manifest does not match its outer descriptor.")
        }
        try RoomProfessionalArchiveSupport.validateOuterClosure(
            extracted: extracted,
            entries: manifest.entries,
            manifestEntryPath: manifestEntryPath
        )
        let extractedCompanions = try manifest.entries.compactMap { entry -> RoomProfessionalWorkingSetCompanion? in
            guard entry.kind != .packageBackup else { return nil }
            let data = try RoomProfessionalArchiveSupport.readBoundedRegularFile(
                stage.appendingPathComponent(entry.path),
                maximumBytes: RoomProfessionalArchiveSupport.maximumCompanionBytes(for: entry.kind),
                at: entry.path
            )
            return try RoomProfessionalWorkingSetCompanion(
                sourceRevision: manifest.sourceRevision,
                path: entry.path,
                kind: entry.kind,
                mediaType: entry.mediaType,
                data: data
            )
        }
        try RoomProfessionalArchiveSupport.validateCompanionPayloads(
            extractedCompanions,
            sourceRevision: manifest.sourceRevision,
            conceptMappingAdjustments: manifest.conceptMappingAdjustments
        )

        let packageArchiveURL = stage.appendingPathComponent(packageBackupEntryPath)
        let innerVerification = stage.appendingPathComponent(".inner-package-verification", isDirectory: true)
        try FileManager.default.createDirectory(at: innerVerification, withIntermediateDirectories: false)
        do {
            _ = try await RoomProjectBackupArchive.extractAndVerify(
                archiveURL: packageArchiveURL,
                expectedDescriptor: manifest.packageDescriptor,
                into: innerVerification
            )
        } catch {
            throw RoomProfessionalArchiveError.archiveStructureInvalid("Inner package backup failed revalidation.")
        }

        try RoomProfessionalArchiveSupport.promote(
            paths: manifest.entries.map(\.path) + [manifestEntryPath],
            from: stage,
            to: destinationURL
        )
        try FileManager.default.removeItem(at: stage)
        stageExists = false
        return RoomProfessionalWorkingSetExtraction(
            manifest: manifest,
            packageDescriptor: manifest.packageDescriptor
        )
    }
}

enum RoomProfessionalArchiveSupport {
    static let zipLimits = RoomZIPLimits(
        maxEntries: RoomBackupLimits.maximumArchiveEntries,
        maxEntryBytes: RoomBackupLimits.maximumPackageFileBytes,
        maxArchiveBytes: RoomBackupLimits.maximumArchiveBytes
    )

    static func requireIdentifier(_ value: String, at path: String) throws {
        guard RoomPathValidation.isSafeStableIdentifier(value) else {
            throw RoomProfessionalArchiveError.invalidValue(path: path, reason: "Value must be a stable ASCII identifier.")
        }
    }

    static func requireDigest(_ value: String, at path: String) throws {
        guard value.count == 64,
              value.unicodeScalars.allSatisfy({ (48...57).contains($0.value) || (97...102).contains($0.value) })
        else {
            throw RoomProfessionalArchiveError.invalidValue(path: path, reason: "Value must be a lowercase SHA-256 digest.")
        }
    }

    static func isConceptSetManifestPath(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        return components.count == 4
            && components[0] == "companions"
            && components[1] == "concept-sets"
            && RoomPathValidation.isSafeStableIdentifier(components[2])
            && components[3] == "manifest.json"
    }

    static func isConceptSetAttachmentPath(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        return components.count == 5
            && components[0] == "companions"
            && components[1] == "concept-sets"
            && RoomPathValidation.isSafeStableIdentifier(components[2])
            && components[3] == "attachments"
    }

    static func isConceptSourcePackageProvenancePath(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        return components.count == 4
            && components[0] == "companions"
            && components[1] == "concept-source-packages"
            && RoomPathValidation.isSafeStableIdentifier(components[2])
            && components[3] == "manifest.json"
    }

    static func requireNewArchiveDestination(_ archiveURL: URL) throws {
        let destination = archiveURL.standardizedFileURL
        guard destination.isFileURL,
              !pathExists(destination),
              !isSymbolicLink(destination)
        else {
            throw RoomProfessionalArchiveError.unsafeArchiveDestination(destination.path)
        }
        try requireExistingRealDirectoryPath(destination.deletingLastPathComponent())
    }

    static func maximumCompanionBytes(
        for kind: RoomProfessionalWorkingSetEntryKind
    ) -> UInt64 {
        switch kind {
        case .redesignCompanion, .conceptSetManifest, .conceptSourcePackageProvenance:
            return RoomBackupLimits.maximumManifestBytes
        case .conceptSetAttachment:
            return RoomConceptImageLimits.v1MaximumBytes
        case .packageBackup, .raw:
            return 0
        }
    }

    /// Validates the only permitted companion byte families before any outer
    /// ZIP can describe or promote them. The generic companion wrapper is
    /// intentionally not a trust boundary: raw bytes become accepted only
    /// after this canonical/source-bound validation succeeds.
    static func validateCompanionPayloads(
        _ companions: [RoomProfessionalWorkingSetCompanion],
        sourceRevision: RoomRedesignSourceRevision,
        conceptMappingAdjustments: [RoomProfessionalConceptMappingAdjustment] = []
    ) throws {
        var paths = Set<String>()
        var redesignCompanion: RoomProfessionalWorkingSetCompanion?
        var conceptManifests: [String: RoomProfessionalWorkingSetCompanion] = [:]
        var conceptAttachments: [String: [RoomProfessionalWorkingSetCompanion]] = [:]
        var sourcePackageProvenance: [String: RoomProfessionalWorkingSetCompanion] = [:]

        for companion in companions {
            try companion.validate()
            guard companion.sourceRevision == sourceRevision else {
                throw RoomProfessionalArchiveError.invalidValue(
                    path: "companions.sourceRevision",
                    reason: "Every companion must bind the working copy's immutable source revision."
                )
            }
            guard paths.insert(companion.path.lowercased()).inserted else {
                throw RoomProfessionalArchiveError.invalidManifest("Companion paths collide with the working-set ledger.")
            }
            switch companion.kind {
            case .redesignCompanion:
                guard redesignCompanion == nil else {
                    throw RoomProfessionalArchiveError.invalidManifest("A working set can contain at most one redesign companion.")
                }
                redesignCompanion = companion
            case .conceptSetManifest:
                guard let conceptSetID = conceptSetID(fromManifestPath: companion.path),
                      conceptManifests[conceptSetID] == nil
                else {
                    throw RoomProfessionalArchiveError.invalidManifest("Concept Set manifest paths must be unique and reserved.")
                }
                conceptManifests[conceptSetID] = companion
            case .conceptSetAttachment:
                guard let conceptSetID = conceptSetID(fromAttachmentPath: companion.path) else {
                    throw RoomProfessionalArchiveError.invalidManifest("Concept Set attachment path is not in the reserved namespace.")
                }
                conceptAttachments[conceptSetID, default: []].append(companion)
            case .conceptSourcePackageProvenance:
                guard let packageID = sourcePackageID(fromProvenancePath: companion.path),
                      sourcePackageProvenance[packageID] == nil
                else {
                    throw RoomProfessionalArchiveError.invalidManifest("Concept source-package provenance paths must be unique and reserved.")
                }
                sourcePackageProvenance[packageID] = companion
            case .packageBackup, .raw:
                throw RoomProfessionalArchiveError.invalidManifest("Only redesign, Concept Set, and AI-ready provenance companions are permitted.")
            }
        }

        if let redesignCompanion {
            try validateRedesignCompanion(redesignCompanion, sourceRevision: sourceRevision)
        }
        for conceptSetID in conceptAttachments.keys where conceptManifests[conceptSetID] == nil {
            throw RoomProfessionalArchiveError.invalidManifest("Concept Set attachments require a matching canonical manifest.")
        }
        var conceptsByID: [String: RoomConceptSet] = [:]
        for (conceptSetID, manifest) in conceptManifests {
            conceptsByID[conceptSetID] = try validateConceptSetCompanionBundle(
                conceptSetID: conceptSetID,
                manifest: manifest,
                attachments: conceptAttachments[conceptSetID] ?? [],
                sourceRevision: sourceRevision
            )
        }
        let validatedProvenance = try validateSourcePackageProvenance(
            sourcePackageProvenance,
            sourceRevision: sourceRevision
        )
        try validateAutomaticConceptProvenanceClosure(
            conceptsByID: conceptsByID,
            validatedProvenance: validatedProvenance
        )
        try validateConceptMappingAdjustments(
            conceptMappingAdjustments,
            conceptsByID: conceptsByID
        )
    }

    private static func validateRedesignCompanion(
        _ companion: RoomProfessionalWorkingSetCompanion,
        sourceRevision: RoomRedesignSourceRevision
    ) throws {
        guard companion.mediaType == "application/json" else {
            throw RoomProfessionalArchiveError.invalidManifest("Redesign companion must declare application/json.")
        }
        do {
            guard case let .localRedesignExtensionV2(redesign) = try RoomRedesignContractValidator.validate(data: companion.data),
                  redesign.schemaVersion == RoomLocalRedesignExtensionV2.schemaVersionValue,
                  redesign.sourceRevision == sourceRevision,
                  try RoomRedesignCanonicalJSON.encode(redesign) == companion.data
            else {
                throw RoomProfessionalArchiveError.invalidManifest("Redesign companion is not a canonical local redesign extension v2 bound to the working source revision.")
            }
        } catch let error as RoomProfessionalArchiveError {
            throw error
        } catch {
            throw RoomProfessionalArchiveError.invalidManifest("Redesign companion is not a canonical local redesign extension v2 bound to the working source revision.")
        }
    }

    private static func validateConceptSetCompanionBundle(
        conceptSetID: String,
        manifest: RoomProfessionalWorkingSetCompanion,
        attachments: [RoomProfessionalWorkingSetCompanion],
        sourceRevision: RoomRedesignSourceRevision
    ) throws -> RoomConceptSet {
        guard manifest.mediaType == "application/json" else {
            throw RoomProfessionalArchiveError.invalidManifest("Concept Set manifest must declare application/json.")
        }
        let conceptSet: RoomConceptSet
        do {
            conceptSet = try RoomConceptSetDecoder.decodeCanonicalIntrinsic(
                manifest.data,
                expectedSourceRevision: sourceRevision
            )
        } catch {
            throw RoomProfessionalArchiveError.invalidManifest("Concept Set companion manifest is not duplicate-safe canonical source-bound JSON.")
        }
        guard conceptSet.conceptSetID == conceptSetID else {
            throw RoomProfessionalArchiveError.invalidManifest("Concept Set companion manifest ID does not match its reserved path.")
        }

        let expectedPaths = Set(conceptSet.attachments.map {
            "companions/concept-sets/\(conceptSetID)/\($0.relativePath)"
        })
        let actualPaths = Set(attachments.map(\.path))
        guard actualPaths.count == attachments.count, actualPaths == expectedPaths else {
            throw RoomProfessionalArchiveError.invalidManifest("Concept Set attachment declarations do not exactly close the companion ledger.")
        }
        let attachmentByPath = Dictionary(uniqueKeysWithValues: attachments.map { ($0.path, $0) })
        for attachment in conceptSet.attachments {
            let path = "companions/concept-sets/\(conceptSetID)/\(attachment.relativePath)"
            guard let payload = attachmentByPath[path],
                  payload.kind == .conceptSetAttachment,
                  payload.mediaType == attachment.mediaType,
                  UInt64(payload.data.count) == attachment.byteCount,
                  RoomSHA256.hexDigest(of: payload.data) == attachment.sha256
            else {
                throw RoomProfessionalArchiveError.invalidManifest("Concept Set attachment bytes disagree with their canonical manifest declaration.")
            }
            do {
                _ = try RoomConceptImageValidator.validateSanitizedImage(
                    payload.data,
                    mediaType: payload.mediaType
                )
            } catch {
                throw RoomProfessionalArchiveError.invalidManifest("Concept Set attachment is not a sanitized declared image.")
            }
        }
        return conceptSet
    }

    private static func validateSourcePackageProvenance(
        _ companionsByPackageID: [String: RoomProfessionalWorkingSetCompanion],
        sourceRevision: RoomRedesignSourceRevision
    ) throws -> [String: RoomConceptValidatedSourcePackage] {
        var validated: [String: RoomConceptValidatedSourcePackage] = [:]
        for (packageID, companion) in companionsByPackageID {
            guard companion.mediaType == "application/json" else {
                throw RoomProfessionalArchiveError.invalidManifest("Concept source-package provenance must declare application/json.")
            }
            let capability: RoomConceptValidatedSourcePackage
            do {
                capability = try RoomConceptValidatedSourcePackage(validatedManifestData: companion.data)
                guard capability.sourceRevision == sourceRevision,
                      capability.sourceAIRoomPackage.packageID == packageID,
                      try RoomProfessionalConceptSourcePackageProvenanceSnapshot.validatedPackage(
                          from: companion.data
                      ).package.profile == .aiReady
                else {
                    throw RoomProfessionalArchiveError.invalidManifest("Concept source-package provenance must be an exact AI-ready canonical manifest bound to the working source revision.")
                }
            } catch let error as RoomProfessionalArchiveError {
                throw error
            } catch {
                throw RoomProfessionalArchiveError.invalidManifest("Concept source-package provenance is not duplicate-safe canonical AI-ready package bytes.")
            }
            let key = packageID.lowercased()
            guard validated[key] == nil else {
                throw RoomProfessionalArchiveError.invalidManifest("Concept source-package provenance identifiers collide without case distinction.")
            }
            validated[key] = capability
        }
        return validated
    }

    private static func validateAutomaticConceptProvenanceClosure(
        conceptsByID: [String: RoomConceptSet],
        validatedProvenance: [String: RoomConceptValidatedSourcePackage]
    ) throws {
        var requiredPackageIDs = Set<String>()
        for concept in conceptsByID.values {
            let automaticAttachments = concept.attachments.filter { $0.mapping.status == .automatic }
            guard !automaticAttachments.isEmpty else { continue }
            guard let claimedPackage = concept.sourceAIRoomPackage,
                  let capability = validatedProvenance[claimedPackage.packageID.lowercased()],
                  capability.sourceAIRoomPackage == claimedPackage
            else {
                throw RoomProfessionalArchiveError.invalidManifest("Automatic Concept mappings require an exact included AI-ready source-package provenance manifest.")
            }
            for attachment in automaticAttachments {
                guard let cameraID = attachment.mapping.cameraID,
                      capability.canonicalCameraIDs.contains(cameraID)
                else {
                    throw RoomProfessionalArchiveError.invalidManifest("Automatic Concept mapping camera identifiers must be present in their included AI-ready provenance ledger.")
                }
            }
            requiredPackageIDs.insert(claimedPackage.packageID.lowercased())
        }
        guard requiredPackageIDs == Set(validatedProvenance.keys) else {
            throw RoomProfessionalArchiveError.invalidManifest("Concept source-package provenance must have exact closure over automatic Concept mappings with no missing or extra manifests.")
        }
    }

    private static func validateConceptMappingAdjustments(
        _ adjustments: [RoomProfessionalConceptMappingAdjustment],
        conceptsByID: [String: RoomConceptSet]
    ) throws {
        var identifiers = Set<String>()
        for adjustment in adjustments {
            do {
                try adjustment.validate()
            } catch {
                throw RoomProfessionalArchiveError.invalidManifest("Concept mapping adjustment is invalid.")
            }
            guard identifiers.insert("\(adjustment.conceptSetID)/\(adjustment.attachmentID)").inserted,
                  let concept = conceptsByID[adjustment.conceptSetID],
                  let attachment = concept.attachments.first(where: {
                      $0.attachmentID == adjustment.attachmentID
                  }),
                  attachment.mapping == adjustment.to
            else {
                throw RoomProfessionalArchiveError.invalidManifest("Concept mapping adjustment does not bind an exact transported Concept attachment.")
            }
        }
    }

    private static func conceptSetID(fromManifestPath path: String) -> String? {
        guard isConceptSetManifestPath(path) else { return nil }
        return path.split(separator: "/").map(String.init)[2]
    }

    private static func conceptSetID(fromAttachmentPath path: String) -> String? {
        guard isConceptSetAttachmentPath(path) else { return nil }
        return path.split(separator: "/").map(String.init)[2]
    }

    private static func sourcePackageID(fromProvenancePath path: String) -> String? {
        guard isConceptSourcePackageProvenancePath(path) else { return nil }
        return path.split(separator: "/").map(String.init)[2]
    }

    static func pathExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || isSymbolicLink(url)
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private static func requireExistingRealDirectoryPath(_ directory: URL) throws {
        let standardized = directory.standardizedFileURL
        var isDirectory = ObjCBool(false)
        // The immediate caller-controlled parent is the early trust boundary.
        // We deliberately do not reject macOS's legitimate /var -> /private
        // ancestor alias; `RoomDeterministicZIP` rechecks its full write path
        // immediately before archive creation.
        guard standardized.isFileURL,
              FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              !isSymbolicLink(standardized)
        else {
            throw RoomProfessionalArchiveError.unsafeArchiveDestination(standardized.path)
        }
    }

    static func requireDirectory(_ url: URL, at path: String) throws {
        var isDirectory = ObjCBool(false)
        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              !isSymbolicLink(url)
        else {
            throw RoomProfessionalArchiveError.invalidValue(path: path, reason: "Directory must be a real nonsymlink directory.")
        }
    }

    static func requireOwnedEmptyExtractionDirectory(_ url: URL) throws {
        do {
            try requireDirectory(url, at: "extraction")
            guard try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty else {
                throw RoomProfessionalArchiveError.unsafeExtractionDestination(url.path)
            }
        } catch let error as RoomProfessionalArchiveError {
            throw error
        } catch {
            throw RoomProfessionalArchiveError.unsafeExtractionDestination(url.path)
        }
    }

    static func verifyArchive(
        _ archiveURL: URL,
        expectedSHA256: String,
        expectedByteCount: UInt64
    ) throws {
        guard !isSymbolicLink(archiveURL) else {
            throw RoomProfessionalArchiveError.archiveStructureInvalid("Archive must be a regular nonsymlink file.")
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: archiveURL.path)
        } catch {
            throw RoomProfessionalArchiveError.archiveStructureInvalid("Archive is unavailable.")
        }
        guard
            attributes[.type] as? FileAttributeType == .typeRegular,
            let byteCount = attributes[.size] as? NSNumber,
            byteCount.int64Value >= 0,
            UInt64(byteCount.int64Value) == expectedByteCount,
            try RoomSHA256.hexDigest(ofFile: archiveURL) == expectedSHA256
        else {
            throw RoomProfessionalArchiveError.descriptorMismatch("Archive digest or byte count differs from its descriptor.")
        }
    }

    static func makeExtractionStage(in destinationURL: URL, prefix: String) throws -> URL {
        let stage = destinationURL.appendingPathComponent(
            "\(prefix)\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        guard !pathExists(stage), !isSymbolicLink(stage) else {
            throw RoomProfessionalArchiveError.unsafeExtractionDestination(stage.path)
        }
        do {
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
            return stage
        } catch {
            throw RoomProfessionalArchiveError.unsafeExtractionDestination(stage.path)
        }
    }

    static func writeNewFile(_ data: Data, to url: URL) throws {
        guard !pathExists(url), !isSymbolicLink(url) else {
            throw RoomProfessionalArchiveError.storageFailure("Destination file already exists.")
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.withoutOverwriting])
        } catch {
            throw RoomProfessionalArchiveError.storageFailure("Unable to stage archive bytes.")
        }
    }

    static func readBoundedRegularFile(
        _ url: URL,
        maximumBytes: UInt64,
        at path: String
    ) throws -> Data {
        guard !isSymbolicLink(url) else {
            throw RoomProfessionalArchiveError.archiveStructureInvalid("\(path) is a symbolic link.")
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw RoomProfessionalArchiveError.invalidManifest("\(path) is missing.")
        }
        guard
            attributes[.type] as? FileAttributeType == .typeRegular,
            let byteCount = attributes[.size] as? NSNumber,
            byteCount.int64Value >= 0,
            UInt64(byteCount.int64Value) <= maximumBytes
        else {
            throw RoomProfessionalArchiveError.invalidManifest("\(path) is not a bounded regular file.")
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw RoomProfessionalArchiveError.invalidManifest("\(path) cannot be read.")
        }
    }

    static func requireBoundedRegularFile(
        _ url: URL,
        maximumBytes: UInt64,
        at path: String
    ) throws {
        guard url.isFileURL, !isSymbolicLink(url) else {
            throw RoomProfessionalArchiveError.invalidValue(
                path: path,
                reason: "Archive source must be a regular nonsymlink file."
            )
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw RoomProfessionalArchiveError.invalidValue(
                path: path,
                reason: "Archive source is unavailable."
            )
        }
        guard
            attributes[.type] as? FileAttributeType == .typeRegular,
            let byteCount = attributes[.size] as? NSNumber,
            byteCount.int64Value > 0,
            UInt64(byteCount.int64Value) <= maximumBytes
        else {
            throw RoomProfessionalArchiveError.invalidValue(
                path: path,
                reason: "Archive source must be a bounded nonempty regular file."
            )
        }
    }

    /// Revalidates the one externally rewritten document before the existing
    /// full-package backup builder freezes it. The live package never enters
    /// this path: `RoomProfessionalWorkingCopy` is an internal proof made by
    /// the external-copy materializer.
    static func validateRawRedactedMaterialization(
        _ workingCopy: RoomProfessionalWorkingCopy
    ) throws {
        let materialization = workingCopy.backupMaterialization
        guard let manifestEntry = materialization.entries.first(where: {
            $0.packageRelativePath.value == "manifest.json"
        }) else {
            throw RoomProfessionalArchiveError.invalidManifest("Raw-redacted copy is missing manifest.json.")
        }
        let manifestURL = materialization.workspaceURL
            .appendingPathComponent(manifestEntry.workspaceRelativePath.value)
        let manifestData = try readBoundedRegularFile(
            manifestURL,
            maximumBytes: RoomBackupLimits.maximumManifestBytes,
            at: "manifest.json"
        )
        let manifest: RoomProjectManifest
        do {
            manifest = try RoomJSONCoding.makeDecoder().decode(RoomProjectManifest.self, from: manifestData)
        } catch {
            throw RoomProfessionalArchiveError.invalidManifest("Raw-redacted manifest.json is invalid.")
        }
        guard
            manifest.projectID == materialization.projectID,
            manifest.headRevisionID == materialization.headRevisionID,
            manifest.schemaVersion == materialization.projectSchemaVersion,
            manifest.assetPolicy?.worldMap == nil
        else {
            throw RoomProfessionalArchiveError.invalidManifest("Raw-redacted manifest retains an incompatible world-map reference.")
        }
        if let redactedPath = workingCopy.redactedWorldMapPackagePath {
            guard !materialization.entries.contains(where: {
                $0.packageRelativePath.value == redactedPath
            }) else {
                throw RoomProfessionalArchiveError.invalidManifest("Raw-redacted copy retains the disclosed world-map file.")
            }
        }
    }

    static func decodeWorkingSetManifest(_ data: Data) throws -> RoomProfessionalWorkingSetManifest {
        do {
            return try RoomProfessionalSyncCanonicalJSON.decodeStrict(
                data,
                as: RoomProfessionalWorkingSetManifest.self
            )
        } catch let error as RoomProfessionalArchiveError {
            throw error
        } catch {
            throw RoomProfessionalArchiveError.invalidManifest("working-set-manifest.json is not strict canonical JSON.")
        }
    }

    static func validateOuterClosure(
        extracted: [RoomZIPEntryDigest],
        entries: [RoomProfessionalWorkingSetEntry],
        manifestEntryPath: String
    ) throws {
        var extractedByPath: [String: RoomZIPEntryDigest] = [:]
        for digest in extracted {
            guard extractedByPath[digest.entryPath.value] == nil else {
                throw RoomProfessionalArchiveError.archiveStructureInvalid("Archive has duplicate entry names.")
            }
            extractedByPath[digest.entryPath.value] = digest
        }
        let expected = Set(entries.map(\.path)).union([manifestEntryPath])
        guard Set(extractedByPath.keys) == expected else {
            throw RoomProfessionalArchiveError.invalidManifest("Archive entry closure differs from the working-set ledger.")
        }
        for entry in entries {
            guard let actual = extractedByPath[entry.path],
                  actual.byteCount == entry.byteCount,
                  actual.sha256Hex == entry.sha256
            else {
                throw RoomProfessionalArchiveError.invalidManifest("Archive entry digest or byte count differs from the working-set ledger.")
            }
        }
    }

    static func promote(paths: [String], from stage: URL, to destination: URL) throws {
        for path in paths.sorted() {
            _ = try RoomExportEntryPath(path)
            let source = stage.appendingPathComponent(path)
            let target = destination.appendingPathComponent(path)
            guard !isSymbolicLink(source), !pathExists(target) else {
                throw RoomProfessionalArchiveError.unsafeExtractionDestination(target.path)
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: source, to: target)
        }
    }
}
