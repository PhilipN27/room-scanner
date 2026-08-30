import Foundation

/// One caller-selected source file for the opt-in raw archive. Its archive
/// path is deliberately in a raw-only namespace and carries the classified
/// data type, so it cannot be confused with a default working-set entry.
public struct RoomProfessionalRawArchiveInput: Sendable, Equatable {
    public let assetID: String
    public let assetClass: RoomProfessionalRawAssetClass
    public let sourceURL: URL
    public let archivePath: String
    public let mediaType: String

    public init(
        assetID: String,
        assetClass: RoomProfessionalRawAssetClass,
        sourceURL: URL,
        archivePath: String,
        mediaType: String
    ) throws {
        self.assetID = assetID
        self.assetClass = assetClass
        self.sourceURL = sourceURL
        self.archivePath = archivePath
        self.mediaType = mediaType
        try validateStaticFields()
    }

    func validateStaticFields() throws {
        try RoomProfessionalArchiveSupport.requireIdentifier(assetID, at: "rawInputs.assetID")
        do {
            _ = try RoomExportEntryPath(archivePath)
        } catch {
            throw RoomProfessionalArchiveError.invalidValue(
                path: "rawInputs.archivePath",
                reason: "Raw archive paths must use the app-owned ASCII ZIP grammar."
            )
        }
        guard archivePath.hasPrefix("raw/\(assetClass.rawValue)-") else {
            throw RoomProfessionalArchiveError.invalidValue(
                path: "rawInputs.archivePath",
                reason: "Raw archive paths must name their selected raw class."
            )
        }
        guard !mediaType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RoomProfessionalArchiveError.invalidValue(
                path: "rawInputs.mediaType",
                reason: "Raw archive media type is required."
            )
        }
    }
}

/// One exact raw-archive ledger entry. The media type and class are explicit
/// review inputs; byte count and SHA-256 bind the selected source bytes.
public struct RoomProfessionalRawArchiveEntry: Codable, Sendable, Equatable {
    public let assetID: String
    public let assetClass: RoomProfessionalRawAssetClass
    public let path: String
    public let mediaType: String
    public let byteCount: UInt64
    public let sha256: String

    public init(
        assetID: String,
        assetClass: RoomProfessionalRawAssetClass,
        path: String,
        mediaType: String,
        byteCount: UInt64,
        sha256: String
    ) throws {
        self.assetID = assetID
        self.assetClass = assetClass
        self.path = path
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.sha256 = sha256
        try validate()
    }

    public func validate() throws {
        try RoomProfessionalArchiveSupport.requireIdentifier(assetID, at: "rawEntries.assetID")
        do {
            _ = try RoomExportEntryPath(path)
        } catch {
            throw RoomProfessionalArchiveError.invalidValue(
                path: "rawEntries.path",
                reason: "Raw entry paths must use the app-owned ASCII ZIP grammar."
            )
        }
        guard path.hasPrefix("raw/\(assetClass.rawValue)-") else {
            throw RoomProfessionalArchiveError.invalidValue(
                path: "rawEntries.path",
                reason: "Raw entry path must name its classified raw asset."
            )
        }
        guard !mediaType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RoomProfessionalArchiveError.invalidValue(
                path: "rawEntries.mediaType",
                reason: "Raw entry media type is required."
            )
        }
        guard byteCount > 0 else {
            throw RoomProfessionalArchiveError.invalidValue(
                path: "rawEntries.byteCount",
                reason: "Raw entry byte count must be positive."
            )
        }
        try RoomProfessionalArchiveSupport.requireDigest(sha256, at: "rawEntries.sha256")
    }

    public init(from decoder: Decoder) throws {
        try RoomProfessionalTrustedDecoding.requireTrusted(decoder)
        let container = try RoomProfessionalStrictCoding.container(
            decoder,
            allowed: ["assetID", "assetClass", "path", "mediaType", "byteCount", "sha256"],
            required: ["assetID", "assetClass", "path", "mediaType", "byteCount", "sha256"]
        )
        assetID = try container.decode(String.self, forKey: .init("assetID"))
        assetClass = try container.decode(RoomProfessionalRawAssetClass.self, forKey: .init("assetClass"))
        path = try container.decode(String.self, forKey: .init("path"))
        mediaType = try container.decode(String.self, forKey: .init("mediaType"))
        byteCount = try container.decode(UInt64.self, forKey: .init("byteCount"))
        sha256 = try container.decode(String.self, forKey: .init("sha256"))
        try validate()
    }
}

/// Canonical metadata for one separately reviewed raw archive. It intentionally
/// has no head-advance field: raw material is a source-bound attachment, never
/// an immutable project revision.
public struct RoomProfessionalRawArchiveManifest: Codable, Sendable, Equatable {
    public static let schemaVersion = "roomscan-professional-raw-archive-manifest-v1"

    public let schemaVersion: String
    public let sourceRevision: RoomRedesignSourceRevision
    public let review: RoomRawDisclosureReview
    public let entries: [RoomProfessionalRawArchiveEntry]

    public init(
        schemaVersion: String = Self.schemaVersion,
        sourceRevision: RoomRedesignSourceRevision,
        review: RoomRawDisclosureReview,
        entries: [RoomProfessionalRawArchiveEntry]
    ) throws {
        self.schemaVersion = schemaVersion
        self.sourceRevision = sourceRevision
        self.review = review
        self.entries = entries
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == Self.schemaVersion else {
            throw RoomProfessionalArchiveError.invalidManifest("Unsupported raw-archive manifest schema.")
        }
        do {
            try sourceRevision.validate()
            try review.validate(requireAccepted: true)
        } catch {
            throw RoomProfessionalArchiveError.invalidManifest("Raw archive requires an accepted valid source-bound review.")
        }
        guard review.sourceRevision == sourceRevision else {
            throw RoomProfessionalArchiveError.invalidManifest("Raw review must bind the exact raw archive source revision.")
        }
        guard !entries.isEmpty, entries == entries.sorted(by: { $0.path < $1.path }) else {
            throw RoomProfessionalArchiveError.invalidManifest("Raw archive entries must be nonempty and stably ordered.")
        }
        var assetIDs = Set<String>()
        var pathKeys = Set<String>()
        for entry in entries {
            try entry.validate()
            guard assetIDs.insert(entry.assetID).inserted else {
                throw RoomProfessionalArchiveError.invalidManifest("Raw archive asset identifiers must be unique.")
            }
            let normalizedPath = entry.path.precomposedStringWithCanonicalMapping.lowercased()
            guard pathKeys.insert(normalizedPath).inserted else {
                throw RoomProfessionalArchiveError.invalidManifest("Raw archive entry paths collide.")
            }
        }
        let selection = try RoomProfessionalRawArchive.selectionSHA256(
            sourceRevision: sourceRevision,
            entries: entries
        )
        guard selection == review.reviewedSelectionSHA256 else {
            throw RoomProfessionalArchiveError.invalidManifest("Raw archive ledger differs from the reviewed raw selection.")
        }
    }

    public init(from decoder: Decoder) throws {
        try RoomProfessionalTrustedDecoding.requireTrusted(decoder)
        let container = try RoomProfessionalStrictCoding.container(
            decoder,
            allowed: ["schemaVersion", "sourceRevision", "review", "entries"],
            required: ["schemaVersion", "sourceRevision", "review", "entries"]
        )
        schemaVersion = try container.decode(String.self, forKey: .init("schemaVersion"))
        sourceRevision = try container.decode(RoomRedesignSourceRevision.self, forKey: .init("sourceRevision"))
        review = try container.decode(RoomRawDisclosureReview.self, forKey: .init("review"))
        entries = try container.decode([RoomProfessionalRawArchiveEntry].self, forKey: .init("entries"))
    }
}

public struct RoomProfessionalRawArchiveSnapshot: Sendable, Equatable {
    public let archiveURL: URL
    public let manifest: RoomProfessionalRawArchiveManifest
    public let descriptor: RoomRawArchiveAttachmentV1

    public init(
        archiveURL: URL,
        manifest: RoomProfessionalRawArchiveManifest,
        descriptor: RoomRawArchiveAttachmentV1
    ) {
        self.archiveURL = archiveURL
        self.manifest = manifest
        self.descriptor = descriptor
    }
}

public struct RoomProfessionalRawArchiveExtraction: Sendable, Equatable {
    public let manifest: RoomProfessionalRawArchiveManifest

    public init(manifest: RoomProfessionalRawArchiveManifest) {
        self.manifest = manifest
    }
}

/// Deterministic archive for explicitly selected reviewed raw bytes. It shares
/// the app-owned ZIP profile and owned-stage extraction boundary with the
/// package backup, but has an entirely separate manifest and attachment
/// contract so it cannot advance a professional project head.
public enum RoomProfessionalRawArchive {
    public static let manifestEntryPath = "raw-archive-manifest.json"

    public static func selectionSHA256(
        sourceRevision: RoomRedesignSourceRevision,
        inputs: [RoomProfessionalRawArchiveInput]
    ) async throws -> String {
        try sourceRevision.validate()
        let prepared = try await prepareInputs(inputs)
        return try selectionSHA256(sourceRevision: sourceRevision, entries: prepared.entries)
    }

    public static func build(
        sourceRevision: RoomRedesignSourceRevision,
        review: RoomRawDisclosureReview,
        inputs: [RoomProfessionalRawArchiveInput],
        archiveURL: URL
    ) async throws -> RoomProfessionalRawArchiveSnapshot {
        try RoomProfessionalArchiveSupport.requireNewArchiveDestination(archiveURL)
        try sourceRevision.validate()
        try review.validate(requireAccepted: true)
        guard review.sourceRevision == sourceRevision else {
            throw RoomProfessionalArchiveError.invalidValue(
                path: "review.sourceRevision",
                reason: "Raw archive review must bind the requested immutable source revision."
            )
        }
        let prepared = try await prepareInputs(inputs)
        let selection = try selectionSHA256(sourceRevision: sourceRevision, entries: prepared.entries)
        guard selection == review.reviewedSelectionSHA256 else {
            throw RoomProfessionalArchiveError.invalidValue(
                path: "review.reviewedSelectionSHA256",
                reason: "Raw archive inputs differ from the accepted reviewed selection."
            )
        }
        let manifest = try RoomProfessionalRawArchiveManifest(
            sourceRevision: sourceRevision,
            review: review,
            entries: prepared.entries
        )
        let manifestData = try RoomProfessionalSyncCanonicalJSON.encode(manifest)
        let manifestURL = archiveURL.deletingLastPathComponent().appendingPathComponent(
            ".roomscan-raw-manifest-\(UUID().uuidString.lowercased()).json"
        )
        try RoomProfessionalArchiveSupport.writeNewFile(manifestData, to: manifestURL)
        defer { try? FileManager.default.removeItem(at: manifestURL) }

        var inputsForArchive = prepared.zipInputs
        inputsForArchive.append(RoomZIPInput(
            sourceURL: manifestURL,
            entryPath: try RoomExportEntryPath(manifestEntryPath),
            mediaType: "application/json"
        ))
        let finalDigests: [RoomZIPEntryDigest]
        do {
            finalDigests = try await RoomDeterministicZIP.preflight(
                inputs: inputsForArchive,
                limits: RoomProfessionalArchiveSupport.zipLimits
            )
        } catch {
            throw RoomProfessionalArchiveError.archiveStructureInvalid("Raw archive inputs failed deterministic ZIP validation.")
        }
        let finalRawEntries = try rawEntries(from: finalDigests, inputs: inputs)
        guard finalRawEntries == prepared.entries else {
            throw RoomProfessionalArchiveError.archiveStructureInvalid("Raw source bytes changed after disclosure selection.")
        }
        let receipt: RoomZIPArchiveReceipt
        do {
            receipt = try await RoomDeterministicZIP.write(
                inputs: inputsForArchive,
                to: archiveURL,
                limits: RoomProfessionalArchiveSupport.zipLimits,
                expectedDigests: finalDigests
            )
        } catch {
            throw RoomProfessionalArchiveError.archiveStructureInvalid("Unable to write deterministic raw archive.")
        }
        let descriptor = try RoomRawArchiveAttachmentV1(
            projectID: sourceRevision.projectID,
            revisionID: sourceRevision.revisionID,
            review: review,
            manifestSHA256: RoomSHA256.hexDigest(of: manifestData),
            archiveSHA256: receipt.archiveSHA256,
            archiveByteCount: receipt.archiveByteCount
        )
        return RoomProfessionalRawArchiveSnapshot(
            archiveURL: archiveURL,
            manifest: manifest,
            descriptor: descriptor
        )
    }

    public static func extractAndVerify(
        archiveURL: URL,
        expectedDescriptor: RoomRawArchiveAttachmentV1,
        into destinationURL: URL
    ) async throws -> RoomProfessionalRawArchiveExtraction {
        try expectedDescriptor.validate()
        try RoomProfessionalArchiveSupport.requireOwnedEmptyExtractionDirectory(destinationURL)
        try RoomProfessionalArchiveSupport.verifyArchive(
            archiveURL,
            expectedSHA256: expectedDescriptor.archiveSHA256,
            expectedByteCount: expectedDescriptor.archiveByteCount
        )
        let stage = try RoomProfessionalArchiveSupport.makeExtractionStage(
            in: destinationURL,
            prefix: ".roomscan-professional-raw-stage-"
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
            throw RoomProfessionalArchiveError.archiveStructureInvalid("Raw ZIP structure or extraction failed validation.")
        }
        let manifestData = try RoomProfessionalArchiveSupport.readBoundedRegularFile(
            stage.appendingPathComponent(manifestEntryPath),
            maximumBytes: RoomBackupLimits.maximumManifestBytes,
            at: manifestEntryPath
        )
        guard RoomSHA256.hexDigest(of: manifestData) == expectedDescriptor.manifestSHA256 else {
            throw RoomProfessionalArchiveError.descriptorMismatch("Raw manifest digest differs from its descriptor.")
        }
        let manifest = try decodeManifest(manifestData)
        try manifest.validate()
        guard
            manifest.sourceRevision.projectID == expectedDescriptor.projectID,
            manifest.sourceRevision.revisionID == expectedDescriptor.revisionID,
            manifest.review == expectedDescriptor.review
        else {
            throw RoomProfessionalArchiveError.descriptorMismatch("Raw manifest does not match its reviewed attachment descriptor.")
        }
        try validateClosure(extracted: extracted, entries: manifest.entries)
        try RoomProfessionalArchiveSupport.promote(
            paths: manifest.entries.map(\.path) + [manifestEntryPath],
            from: stage,
            to: destinationURL
        )
        try FileManager.default.removeItem(at: stage)
        stageExists = false
        return RoomProfessionalRawArchiveExtraction(manifest: manifest)
    }

    static func selectionSHA256(
        sourceRevision: RoomRedesignSourceRevision,
        entries: [RoomProfessionalRawArchiveEntry]
    ) throws -> String {
        try sourceRevision.validate()
        let selection = RoomProfessionalRawArchiveSelection(
            sourceRevision: sourceRevision,
            entries: entries.map { entry in
                RoomProfessionalRawArchiveSelection.Entry(
                    assetID: entry.assetID,
                    assetClass: entry.assetClass,
                    path: entry.path,
                    mediaType: entry.mediaType,
                    byteCount: entry.byteCount,
                    sha256: entry.sha256
                )
            }
        )
        return RoomSHA256.hexDigest(of: try RoomProfessionalSyncCanonicalJSON.encode(selection))
    }

    private struct PreparedInputs: Sendable {
        let entries: [RoomProfessionalRawArchiveEntry]
        let zipInputs: [RoomZIPInput]
    }

    private static func prepareInputs(
        _ inputs: [RoomProfessionalRawArchiveInput]
    ) async throws -> PreparedInputs {
        guard !inputs.isEmpty else {
            throw RoomProfessionalArchiveError.invalidValue(
                path: "rawInputs",
                reason: "At least one explicitly selected raw input is required."
            )
        }
        var assetIDs = Set<String>()
        var pathKeys = Set<String>()
        var zipInputs: [RoomZIPInput] = []
        for input in inputs.sorted(by: { $0.archivePath < $1.archivePath }) {
            try input.validateStaticFields()
            guard assetIDs.insert(input.assetID).inserted else {
                throw RoomProfessionalArchiveError.invalidValue(
                    path: "rawInputs.assetID",
                    reason: "Raw input asset identifiers must be unique."
                )
            }
            let normalizedPath = input.archivePath.precomposedStringWithCanonicalMapping.lowercased()
            guard pathKeys.insert(normalizedPath).inserted else {
                throw RoomProfessionalArchiveError.invalidValue(
                    path: "rawInputs.archivePath",
                    reason: "Raw input archive paths collide."
                )
            }
            try RoomProfessionalArchiveSupport.requireBoundedRegularFile(
                input.sourceURL,
                maximumBytes: RoomProfessionalArchiveSupport.zipLimits.maxEntryBytes,
                at: input.archivePath
            )
            zipInputs.append(RoomZIPInput(
                sourceURL: input.sourceURL,
                entryPath: try RoomExportEntryPath(input.archivePath),
                mediaType: input.mediaType
            ))
        }
        let digests: [RoomZIPEntryDigest]
        do {
            digests = try await RoomDeterministicZIP.preflight(
                inputs: zipInputs,
                limits: RoomProfessionalArchiveSupport.zipLimits
            )
        } catch {
            throw RoomProfessionalArchiveError.archiveStructureInvalid("Raw input cannot enter the deterministic ZIP profile.")
        }
        return PreparedInputs(
            entries: try rawEntries(from: digests, inputs: inputs),
            zipInputs: zipInputs
        )
    }

    private static func rawEntries(
        from digests: [RoomZIPEntryDigest],
        inputs: [RoomProfessionalRawArchiveInput]
    ) throws -> [RoomProfessionalRawArchiveEntry] {
        var inputByPath: [String: RoomProfessionalRawArchiveInput] = [:]
        for input in inputs {
            guard inputByPath[input.archivePath] == nil else {
                throw RoomProfessionalArchiveError.invalidManifest("Raw inputs have duplicate paths.")
            }
            inputByPath[input.archivePath] = input
        }
        var entries: [RoomProfessionalRawArchiveEntry] = []
        for digest in digests where digest.entryPath.value != manifestEntryPath {
            guard let input = inputByPath[digest.entryPath.value] else {
                throw RoomProfessionalArchiveError.archiveStructureInvalid("Raw ZIP preflight includes an unknown entry.")
            }
            entries.append(try RoomProfessionalRawArchiveEntry(
                assetID: input.assetID,
                assetClass: input.assetClass,
                path: input.archivePath,
                mediaType: input.mediaType,
                byteCount: digest.byteCount,
                sha256: digest.sha256Hex
            ))
        }
        guard entries.count == inputs.count else {
            throw RoomProfessionalArchiveError.archiveStructureInvalid("Raw ZIP preflight omitted a selected entry.")
        }
        return entries.sorted { $0.path < $1.path }
    }

    private static func decodeManifest(_ data: Data) throws -> RoomProfessionalRawArchiveManifest {
        do {
            return try RoomProfessionalSyncCanonicalJSON.decodeStrict(
                data,
                as: RoomProfessionalRawArchiveManifest.self
            )
        } catch let error as RoomProfessionalArchiveError {
            throw error
        } catch {
            throw RoomProfessionalArchiveError.invalidManifest("raw-archive-manifest.json is not strict canonical JSON.")
        }
    }

    private static func validateClosure(
        extracted: [RoomZIPEntryDigest],
        entries: [RoomProfessionalRawArchiveEntry]
    ) throws {
        var extractedByPath: [String: RoomZIPEntryDigest] = [:]
        for digest in extracted {
            guard extractedByPath[digest.entryPath.value] == nil else {
                throw RoomProfessionalArchiveError.archiveStructureInvalid("Raw archive has duplicate entry names.")
            }
            extractedByPath[digest.entryPath.value] = digest
        }
        let expected = Set(entries.map(\.path)).union([manifestEntryPath])
        guard Set(extractedByPath.keys) == expected else {
            throw RoomProfessionalArchiveError.invalidManifest("Raw archive entry closure differs from its review ledger.")
        }
        for entry in entries {
            guard let actual = extractedByPath[entry.path],
                  actual.byteCount == entry.byteCount,
                  actual.sha256Hex == entry.sha256
            else {
                throw RoomProfessionalArchiveError.invalidManifest("Raw archive entry digest or byte count differs from its review ledger.")
            }
        }
    }
}

private struct RoomProfessionalRawArchiveSelection: Encodable {
    static let schemaVersion = "roomscan-professional-raw-selection-v1"

    struct Entry: Encodable {
        let assetID: String
        let assetClass: RoomProfessionalRawAssetClass
        let path: String
        let mediaType: String
        let byteCount: UInt64
        let sha256: String
    }

    let schemaVersion: String = Self.schemaVersion
    let sourceRevision: RoomRedesignSourceRevision
    let entries: [Entry]
}
