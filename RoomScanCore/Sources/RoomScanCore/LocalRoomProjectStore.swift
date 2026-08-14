import Foundation

public protocol RoomProjectClock: Sendable {
    func now() -> Date
}

public struct SystemRoomProjectClock: RoomProjectClock {
    public init() {}

    public func now() -> Date {
        Date()
    }
}

public struct FixedRoomProjectClock: RoomProjectClock {
    public let date: Date

    public init(date: Date) {
        self.date = date
    }

    public func now() -> Date {
        date
    }
}

public protocol RoomProjectIDGenerating: Sendable {
    func nextProjectID() async -> String
    func nextRevisionID() async -> String
}

public struct UUIDRoomProjectIDGenerator: RoomProjectIDGenerating {
    public init() {}

    public func nextProjectID() async -> String {
        "project-\(UUID().uuidString.lowercased())"
    }

    public func nextRevisionID() async -> String {
        "revision-\(UUID().uuidString.lowercased())"
    }
}

public actor DeterministicRoomProjectIDGenerator: RoomProjectIDGenerating {
    private var projectIDs: [String]
    private var revisionIDs: [String]

    public init(projectIDs: [String], revisionIDs: [String]) {
        self.projectIDs = projectIDs
        self.revisionIDs = revisionIDs
    }

    public func nextProjectID() -> String {
        guard !projectIDs.isEmpty else {
            return "project-\(UUID().uuidString.lowercased())"
        }

        return projectIDs.removeFirst()
    }

    public func nextRevisionID() -> String {
        guard !revisionIDs.isEmpty else {
            return "revision-\(UUID().uuidString.lowercased())"
        }

        return revisionIDs.removeFirst()
    }
}

public enum RoomProjectStoreFaultPoint: String, Sendable, Equatable {
    case beforeInitialPackagePromotion
    case afterRevisionPromotionBeforeManifest
}

/// Test-only seam for deterministic failure at the narrow commit boundary.
public protocol RoomProjectStoreFaultInjecting: Sendable {
    func throwIfNeeded(at point: RoomProjectStoreFaultPoint) throws
}

public struct NoRoomProjectStoreFaultInjector: RoomProjectStoreFaultInjecting {
    public init() {}

    public func throwIfNeeded(at point: RoomProjectStoreFaultPoint) throws {}
}

public struct FailingRoomProjectStoreFaultInjector: RoomProjectStoreFaultInjecting {
    public let point: RoomProjectStoreFaultPoint

    public init(point: RoomProjectStoreFaultPoint) {
        self.point = point
    }

    public func throwIfNeeded(at point: RoomProjectStoreFaultPoint) throws {
        guard point == self.point else {
            return
        }

        throw RoomProjectStoreError.injectedFailure(point)
    }
}

/// A marker is written before a staged revision is promoted. It is deliberately
/// internal: only an ownership record in the staged or promoted revision grants
/// the recovery code authority to remove that directory.
struct PendingRoomRevisionTransaction: Codable, Sendable, Equatable {
    let projectID: String
    let revisionID: String
    let previousHeadRevisionID: String
    let stagingDirectoryName: String
    let transactionID: String
    let updatedManifest: RoomProjectManifest
    let createdAt: Date
    /// New transactions record the immutable revision's mode. An absent field
    /// is readable only for a historical v1 marker whose revision JSON itself
    /// still satisfies the v1 compatibility rule.
    let evidenceCompatibility: RoomRevisionEvidenceCompatibility?
}

/// Stored inside each staged and committed revision so recovery never deletes a
/// merely unreferenced directory that it cannot prove belongs to its marker.
struct RoomRevisionOwnershipRecord: Codable, Sendable, Equatable {
    let projectID: String
    let revisionID: String
    let transactionID: String
}

/// Workspace-only backup ownership. It is never a live package document: the
/// backup manifest binds the package closure, while this marker merely proves
/// authority to remove a temporary backup/recovery stage.
private struct RoomBackupWorkspaceOwnershipRecord: Codable, Sendable, Equatable {
    static let currentFormatVersion = "roomscan-backup-workspace-v1"

    let formatVersion: String
    let directoryName: String
    let token: String

    init(directoryName: String, token: String) {
        formatVersion = Self.currentFormatVersion
        self.directoryName = directoryName
        self.token = token
    }
}

private struct PreparedRoomBackupRecovery: Sendable {
    let token: String
    let workspaceRootURL: URL
    let stageURL: URL
    let packageURL: URL
    let manifest: RoomBackupManifest
    let descriptor: RoomCloudBackupDescriptor
}

/// Foundation does not provide a process-wide file lock suitable for the app's
/// present deployment. This registry serializes all LocalRoomProjectStore
/// instances in this process for a canonical root. It intentionally does not
/// claim cross-process or app-extension coordination.
private final class RoomProjectProcessLockRegistry: @unchecked Sendable {
    static let shared = RoomProjectProcessLockRegistry()

    private let registryLock = NSLock()
    private var locks: [String: NSLock] = [:]

    func withLock<Result>(
        key: String,
        operation: () throws -> Result
    ) rethrows -> Result {
        registryLock.lock()
        let lock: NSLock
        if let existing = locks[key] {
            lock = existing
        } else {
            let created = NSLock()
            locks[key] = created
            lock = created
        }
        registryLock.unlock()

        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

/// File packages are the authoritative library. Each operation uses a hidden
/// staging directory and validates it before promotion. The in-memory lock is a
/// single-process boundary only; an external process is not a supported writer.
public actor LocalRoomProjectStore {
    private static let canonicalRevisionDocumentPaths: Set<String> = [
        "revision.json",
        "semantic-model.json",
        "annotations.json",
        "measurements.json",
        "photos.json",
        ".roomscan-ownership.json",
    ]

    private let configuredRootURL: URL
    private let clock: any RoomProjectClock
    private let idGenerator: any RoomProjectIDGenerating
    private let faultInjector: any RoomProjectStoreFaultInjecting
    private let exportMaterializationLimits: RoomExportMaterializationLimits
    private let backupLimits: RoomBackupLimits
    private let fileManager = FileManager.default
    private var preparedBackupRecoveries: [String: PreparedRoomBackupRecovery] = [:]

    public init(
        rootURL: URL,
        clock: any RoomProjectClock = SystemRoomProjectClock(),
        idGenerator: any RoomProjectIDGenerating = UUIDRoomProjectIDGenerator(),
        faultInjector: any RoomProjectStoreFaultInjecting = NoRoomProjectStoreFaultInjector(),
        exportMaterializationLimits: RoomExportMaterializationLimits = RoomExportMaterializationLimits(),
        backupLimits: RoomBackupLimits = RoomBackupLimits()
    ) {
        configuredRootURL = rootURL.standardizedFileURL
        self.clock = clock
        self.idGenerator = idGenerator
        self.faultInjector = faultInjector
        self.exportMaterializationLimits = exportMaterializationLimits
        self.backupLimits = backupLimits
    }

    public func saveDraft(
        _ draft: RoomDraft,
        decision: RoomDraftDecision,
        assets: [RoomAssetInput] = []
    ) async throws -> RoomProjectSummary? {
        return try await commitInitialCapture(
            RoomInitialCaptureCommit(draft: draft, evidence: nil, assets: assets),
            decision: decision
        )
    }

    /// Commits one reviewed capture as a complete staged package. A discard
    /// returns before identifier generation, root creation, or asset reads.
    public func commitInitialCapture(
        _ commit: RoomInitialCaptureCommit,
        decision: RoomDraftDecision
    ) async throws -> RoomProjectSummary? {
        guard decision == .save else {
            return nil
        }

        try validateEvidenceAssetInputs(
            commit.assets,
            captureEvidence: commit.evidence,
            evidenceCompatibility: .strict
        )

        let root = try canonicalRootURL()
        // Initial capture inputs are scratch files. Restore and duplicate have
        // separate paths because they intentionally read already-committed
        // package files under the store's ownership checks.
        try validateInitialCaptureScratchAssets(commit.assets, root: root)

        // Awaiting ID generation happens before the blocking process lock.
        let projectID = await idGenerator.nextProjectID()
        let revisionID = await idGenerator.nextRevisionID()
        let createdAt = clock.now()
        let qualityReport: RoomQualityReport?
        if let assessment = commit.qualityAssessment {
            qualityReport = try assessment.bind(
                projectID: projectID,
                revisionID: revisionID,
                generatedAt: createdAt,
                acknowledgement: commit.qualityAcknowledgement
            )
        } else {
            guard commit.qualityAcknowledgement == nil else {
                throw RoomProjectStoreError.invalidPackage(
                    "A Save Anyway acknowledgement cannot be persisted without its exact quality assessment."
                )
            }
            qualityReport = nil
        }

        return try withRootLock(root) {
            try writeNewProjectLocked(
                root: root,
                projectID: projectID,
                revisionID: revisionID,
                metadata: commit.draft.metadata,
                payload: commit.draft.revision,
                reason: .initial,
                createdAt: createdAt,
                assets: commit.assets,
                captureEvidence: commit.evidence,
                evidenceCompatibility: .strict,
                qualityReport: qualityReport
            )
        }
    }

    public func saveDraft(
        _ draft: RoomDraft,
        disposition: RoomDraftEvent,
        assets: [RoomAssetInput] = []
    ) async throws -> RoomProjectSummary? {
        let decision: RoomDraftDecision = disposition == .save ? .save : .discard
        return try await saveDraft(draft, decision: decision, assets: assets)
    }

    public func listSummaries(
        includeArchived: Bool = false
    ) throws -> [RoomProjectSummary] {
        try listProjectListing(includeArchived: includeArchived).summaries
    }

    /// Lists valid authoritative packages without allowing one malformed sibling
    /// to hide the rest of the library. Root enumeration failures still throw.
    public func listProjectListing(
        includeArchived: Bool = true
    ) throws -> RoomProjectListing {
        let root = try canonicalRootURL()
        guard pathExists(root) else {
            return RoomProjectListing(summaries: [], issues: [])
        }

        return try withRootLock(root) {
            guard directoryExists(root) else {
                throw RoomProjectStoreError.storageFailure("Room storage is not a directory.")
            }

            let candidates: [URL]
            do {
                candidates = try fileManager.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                throw RoomProjectStoreError.storageFailure("Unable to list room packages.")
            }

            var summaries: [RoomProjectSummary] = []
            var issues: [RoomProjectListingIssue] = []
            for candidate in candidates {
                let projectID = candidate.lastPathComponent
                guard
                    !projectID.hasPrefix("."),
                    RoomPathValidation.isSafeStableIdentifier(projectID)
                else {
                    continue
                }

                do {
                    // Never follow a candidate project-directory link while listing.
                    if isSymbolicLink(candidate) {
                        throw RoomProjectStoreError.symbolicLinkDetected(projectID)
                    }
                    guard directoryExists(candidate) else {
                        continue
                    }

                    let manifestURL = candidate.appendingPathComponent("manifest.json")
                    try assertNoSymbolicLinks(root: root, through: manifestURL)
                    guard pathExists(manifestURL) else {
                        throw RoomProjectStoreError.invalidPackage(
                            "Room package has no manifest."
                        )
                    }

                    try reconcilePendingRevisionLocked(root: root, projectID: projectID)
                    let package = try loadProjectPackageLocked(root: root, projectID: projectID)
                    let summary = makeSummary(package)
                    if includeArchived || !summary.archived {
                        summaries.append(summary)
                    }
                } catch {
                    issues.append(listingIssue(projectID: projectID, error: error))
                }
            }

            let sortedSummaries = summaries.sorted {
                if $0.lastRevisedDate == $1.lastRevisedDate {
                    return $0.projectID < $1.projectID
                }
                return $0.lastRevisedDate > $1.lastRevisedDate
            }
            return RoomProjectListing(
                summaries: sortedSummaries,
                issues: issues.sorted { $0.projectID < $1.projectID }
            )
        }
    }

    public func load(projectID: String) throws -> RoomProjectPackage {
        try validateIdentifier(projectID)
        let root = try canonicalRootURL()
        return try withRootLock(root) {
            try loadLocked(root: root, projectID: projectID)
        }
    }

    /// Returns an immutable byte binding for additive redesign state. This
    /// reads the package's exact revision documents and never re-encodes or
    /// mutates them. Legacy revisions without an app-owned epoch receive a
    /// stable local fallback scoped to that immutable revision.
    public func redesignSourceRevisionBinding(
        projectID: String,
        revisionID: String
    ) throws -> RoomRedesignSourceRevision {
        try validateIdentifier(projectID)
        try validateIdentifier(revisionID)
        let root = try canonicalRootURL()
        return try withRootLock(root) {
            let package = try loadLocked(root: root, projectID: projectID)
            guard let revision = package.revisions.first(where: { $0.manifest.revisionID == revisionID }) else {
                throw RoomProjectStoreError.revisionNotFound(projectID: projectID, revisionID: revisionID)
            }
            let revisionURL = try revisionDirectory(
                root: root,
                projectID: projectID,
                revisionID: revisionID
            )
            try assertNoSymbolicLinks(root: root, through: revisionURL)
            let semanticURL = revisionURL.appendingPathComponent("semantic-model.json")
            let manifestURL = revisionURL.appendingPathComponent("revision.json")
            guard try isRegularFile(semanticURL), try isRegularFile(manifestURL) else {
                throw RoomProjectStoreError.invalidPackage("Revision binding documents must be regular files.")
            }

            let provenanceEpochs = Set(
                (revision.payload.semanticSnapshot.structuralElements + revision.payload.semanticSnapshot.objectElements)
                    .compactMap { $0.provenance?.coordinateSpaceEpochID }
                    .filter { !$0.isEmpty }
            )
            if provenanceEpochs.count > 1 {
                throw RoomProjectStoreError.invalidPackage(
                    "A revision cannot bind redesign state across inconsistent coordinate-space epochs."
                )
            }
            if let evidenceEpoch = revision.manifest.captureEvidence?.coordinateSpaceEpochID,
               let provenanceEpoch = provenanceEpochs.first,
               evidenceEpoch != provenanceEpoch {
                throw RoomProjectStoreError.invalidPackage(
                    "Revision evidence and semantic provenance disagree about the coordinate-space epoch."
                )
            }
            let coordinateSpaceEpochID = revision.manifest.captureEvidence?.coordinateSpaceEpochID
                ?? provenanceEpochs.first
                ?? revision.manifest.qualityReport?.coordinateSpaceEpochID
                ?? "legacy-\(revisionID)"
            if let qualityEpoch = revision.manifest.qualityReport?.coordinateSpaceEpochID,
               qualityEpoch != coordinateSpaceEpochID {
                throw RoomProjectStoreError.invalidPackage(
                    "Revision quality and source evidence disagree about the coordinate-space epoch."
                )
            }
            try validateIdentifier(coordinateSpaceEpochID)

            return RoomRedesignSourceRevision(
                projectID: projectID,
                revisionID: revisionID,
                coordinateSpaceEpochID: coordinateSpaceEpochID,
                packageSchemaVersion: package.manifest.schemaVersion,
                semanticSHA256: try RoomSHA256.hexDigest(ofFile: semanticURL),
                revisionManifestSHA256: try RoomSHA256.hexDigest(ofFile: manifestURL)
            )
        }
    }

    /// Freezes only the current head revision into a fresh external workspace.
    /// It deliberately excludes the project manifest/history, pending markers,
    /// ownership records, and prior revisions. The returned workspace is a
    /// byte-copy handoff for derived export work, never a package URL.
    public func materializeHeadForExport(
        projectID: String,
        expectedHeadRevisionID: String,
        into requestedDestinationURL: URL
    ) throws -> RoomHeadExportMaterialization {
        try validateIdentifier(projectID)
        try validateIdentifier(expectedHeadRevisionID)
        let root = try canonicalRootURL()

        return try withRootLock(root) {
            let destinationURL = try validatedExportDestination(
                requestedDestinationURL,
                root: root
            )
            let package = try loadLocked(root: root, projectID: projectID)
            guard package.manifest.headRevisionID == expectedHeadRevisionID else {
                throw RoomExportError.staleHead(
                    projectID: projectID,
                    expected: expectedHeadRevisionID,
                    actual: package.manifest.headRevisionID
                )
            }
            guard let head = package.revisions.last else {
                throw RoomProjectStoreError.invalidPackage("Project package has no head revision.")
            }
            let projectURL = try projectDirectory(root: root, projectID: projectID)
            let headURL = try revisionDirectory(
                root: root,
                projectID: projectID,
                revisionID: expectedHeadRevisionID
            )
            let stagingURL = try makeExportStagingURL(
                parent: destinationURL.deletingLastPathComponent()
            )
            var stagingCreated = false

            do {
                try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
                stagingCreated = true
                var entries: [RoomMaterializedExportEntry] = []
                var outputs = Self.baseExportOutputRecords
                var budget = ExportMaterializationBudget(limits: exportMaterializationLimits)
                // Package references are scoped: metadata thumbnails resolve
                // from the project root, while photos/evidence resolve from
                // the head revision. Equal relative spellings can name
                // different bytes, so never merge these dictionaries.
                var projectOutboundReferences: [String: String] = [:]
                var revisionOutboundReferences: [String: String] = [:]
                for document in Self.exportRevisionDocuments {
                    try materializeExportFile(
                        from: headURL.appendingPathComponent(document.sourceName),
                        stage: stagingURL,
                        workspacePath: document.workspacePath,
                        entryPath: document.entryPath,
                        mediaType: "application/json",
                        output: document.output,
                        entries: &entries,
                        budget: &budget
                    )
                }

                if let thumbnail = package.metadata.thumbnailRelativePath {
                    let extensionName = exportExtension(for: thumbnail.value, default: "bin")
                    try materializeExportFile(
                        from: projectURL.appendingPathComponent(thumbnail.value),
                        stage: stagingURL,
                        workspacePath: "assets/thumbnail.\(extensionName)",
                        entryPath: "assets/thumbnail.\(extensionName)",
                        mediaType: exportMediaType(forExtension: extensionName),
                        output: .thumbnailPNG,
                        entries: &entries,
                        budget: &budget
                    )
                    projectOutboundReferences[thumbnail.value] = "assets/thumbnail.\(extensionName)"
                    setExportOutput(&outputs, output: .thumbnailPNG, status: .included)
                } else {
                    setExportOutput(&outputs, output: .thumbnailPNG, status: .skipped, reason: .noThumbnail)
                }

                var copiedPhotoPaths = Set<String>()
                for (index, photo) in head.payload.photos.enumerated() {
                    guard copiedPhotoPaths.insert(photo.assetRelativePath.value).inserted else {
                        continue
                    }
                    let extensionName = exportExtension(for: photo.assetRelativePath.value, default: "bin")
                    let destination = String(
                        format: "assets/photos/photo-%04d-%@.%@",
                        index + 1,
                        photo.id,
                        extensionName
                    )
                    try materializeExportFile(
                        from: headURL.appendingPathComponent(photo.assetRelativePath.value),
                        stage: stagingURL,
                        workspacePath: destination,
                        entryPath: destination,
                        mediaType: exportMediaType(forExtension: extensionName),
                        output: .referencePhotos,
                        entries: &entries,
                        budget: &budget
                    )
                    revisionOutboundReferences[photo.assetRelativePath.value] = destination
                }
                if copiedPhotoPaths.isEmpty {
                    setExportOutput(&outputs, output: .referencePhotos, status: .skipped, reason: .noReferencePhotos)
                } else {
                    setExportOutput(&outputs, output: .referencePhotos, status: .included)
                }

                let evidenceCompatibility = try validatedEvidenceCompatibility(
                    head.manifest,
                    projectSchemaVersion: try validatedProjectSchemaVersion(package.manifest)
                )
                try materializeExportEvidence(
                    manifest: head.manifest,
                    compatibility: evidenceCompatibility,
                    sourceRevisionURL: headURL,
                    stage: stagingURL,
                    entries: &entries,
                    outputs: &outputs,
                    outboundReferences: &revisionOutboundReferences,
                    budget: &budget
                )
                let attachmentCount = try materializeExportAttachments(
                    from: headURL,
                    excludingPhotoPaths: copiedPhotoPaths,
                    evidence: head.manifest.captureEvidence,
                    stage: stagingURL,
                    entries: &entries,
                    budget: &budget
                )
                setExportOutput(
                    &outputs,
                    output: .attachments,
                    status: attachmentCount > 0 ? .included : .skipped,
                    reason: attachmentCount > 0 ? nil : .noAttachments
                )

                var exportMetadata = package.metadata
                if let thumbnail = exportMetadata.thumbnailRelativePath,
                   let mapped = projectOutboundReferences[thumbnail.value] {
                    exportMetadata.thumbnailRelativePath = try RoomRelativePath(mapped)
                }
                var exportRevisionManifest = head.manifest
                if var evidence = exportRevisionManifest.captureEvidence {
                    for index in evidence.artifacts.indices {
                        guard let sourcePath = evidence.artifacts[index].relativePath?.value,
                              let mapped = revisionOutboundReferences[sourcePath]
                        else {
                            continue
                        }
                        evidence.artifacts[index].relativePath = try RoomRelativePath(mapped)
                    }
                    exportRevisionManifest.captureEvidence = evidence
                }
                var exportPhotos = head.payload.photos
                for index in exportPhotos.indices {
                    let sourcePath = exportPhotos[index].assetRelativePath.value
                    if let mapped = revisionOutboundReferences[sourcePath] {
                        exportPhotos[index].assetRelativePath = try RoomRelativePath(mapped)
                    }
                }
                try materializeExportJSON(
                    exportMetadata,
                    stage: stagingURL,
                    workspacePath: "metadata.json",
                    entryPath: "metadata.json",
                    output: .metadataJSON,
                    entries: &entries,
                    budget: &budget
                )
                try materializeExportJSON(
                    exportRevisionManifest,
                    stage: stagingURL,
                    workspacePath: "revision/revision.json",
                    entryPath: "revision/revision.json",
                    output: .revisionJSON,
                    entries: &entries,
                    budget: &budget
                )
                try materializeExportJSON(
                    RoomPhotosDocument(
                        projectID: projectID,
                        revisionID: expectedHeadRevisionID,
                        photos: exportPhotos
                    ),
                    stage: stagingURL,
                    workspacePath: "revision/photos.json",
                    entryPath: "revision/photos.json",
                    output: .photosJSON,
                    entries: &entries,
                    budget: &budget
                )
                let sourceMapEntries = projectOutboundReferences.map {
                    RoomExportSourceMapEntry(
                        scope: .project,
                        sourceReference: $0.key,
                        archivePath: $0.value
                    )
                } + revisionOutboundReferences.map {
                    RoomExportSourceMapEntry(
                        scope: .revision,
                        sourceReference: $0.key,
                        archivePath: $0.value
                    )
                }
                let sortedSourceMapEntries = sourceMapEntries.sorted {
                    if $0.scope != $1.scope {
                        return $0.scope.rawValue < $1.scope.rawValue
                    }
                    return $0.sourceReference < $1.sourceReference
                }
                try materializeExportJSON(
                    RoomExportSourceMap(
                        projectID: projectID,
                        headRevisionID: expectedHeadRevisionID,
                        mappings: sortedSourceMapEntries
                    ),
                    stage: stagingURL,
                    workspacePath: "source-map.json",
                    entryPath: "source-map.json",
                    output: .sourceMapJSON,
                    entries: &entries,
                    budget: &budget
                )

                try RoomExportEntryPath.validateUnique(entries.map(\.entryPath))
                guard !pathExists(destinationURL), !isSymbolicLink(destinationURL) else {
                    throw RoomExportError.destinationAlreadyExists(destinationURL.path)
                }
                try fileManager.moveItem(at: stagingURL, to: destinationURL)
                stagingCreated = false
                return RoomHeadExportMaterialization(
                    workspaceURL: destinationURL,
                    descriptor: RoomHeadExportDescriptor(
                        projectID: projectID,
                        headRevisionID: expectedHeadRevisionID
                    ),
                    entries: entries.sorted { $0.entryPath < $1.entryPath },
                    requestedOutputs: outputs.sorted { $0.output.rawValue < $1.output.rawValue },
                    sourceMap: sortedSourceMapEntries
                )
            } catch {
                if stagingCreated {
                    try? removeOwnedExportStaging(stagingURL, parent: destinationURL.deletingLastPathComponent())
                }
                throw error
            }
        }
    }

    /// Freezes the entire authoritative package—manifest, metadata, every
    /// immutable revision, declared assets, and revision ownership records—
    /// into a fresh external workspace. This is deliberately distinct from a
    /// head-revision export and never changes the source package.
    public func materializeBackupSnapshot(
        projectID: String,
        expectedHeadRevisionID: String,
        into requestedDestinationURL: URL
    ) throws -> RoomBackupMaterialization {
        try validateIdentifier(projectID)
        try validateIdentifier(expectedHeadRevisionID)
        _ = try backupLimits.validatedZIPLimits()
        let root = try canonicalRootURL()

        return try withRootLock(root) {
            let destinationURL = try validatedBackupWorkspaceDestination(
                requestedDestinationURL,
                root: root
            )
            let package = try loadLocked(root: root, projectID: projectID)
            guard package.manifest.headRevisionID == expectedHeadRevisionID else {
                throw RoomBackupError.staleHead(
                    projectID: projectID,
                    expected: expectedHeadRevisionID,
                    actual: package.manifest.headRevisionID
                )
            }
            let projectURL = try projectDirectory(root: root, projectID: projectID)
            let sources = try backupSourceFiles(
                root: root,
                projectID: projectID,
                projectURL: projectURL,
                package: package
            )
            guard sources.count <= backupLimits.maxPackageEntries else {
                throw RoomBackupError.entryLimitExceeded
            }
            let stagingURL = try makeBackupWorkspaceStagingURL(
                parent: destinationURL.deletingLastPathComponent()
            )
            let token = UUID().uuidString.lowercased()
            var stagingCreated = false

            do {
                try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
                stagingCreated = true
                try writeBackupWorkspaceOwnership(
                    RoomBackupWorkspaceOwnershipRecord(
                        directoryName: stagingURL.lastPathComponent,
                        token: token
                    ),
                    to: stagingURL
                )
                var entries: [RoomBackupMaterializationEntry] = []
                var aggregateBytes: UInt64 = 0
                for (index, source) in sources.enumerated() {
                    let extensionName = backupArchiveExtension(for: source.packagePath.value)
                    let archiveName = String(
                        format: "package/files/file-%04d.%@",
                        index + 1,
                        extensionName
                    )
                    let archivePath = try RoomBackupArchivePath(archiveName)
                    let workspacePath = try RoomRelativePath(archiveName)
                    let destination = stagingURL.appendingPathComponent(workspacePath.value)
                    let copiedBytes = try copyBackupFile(
                        from: source.sourceURL,
                        to: destination,
                        maximumBytes: backupLimits.maxFileBytes,
                        root: stagingURL
                    )
                    let (nextAggregate, overflow) = aggregateBytes.addingReportingOverflow(copiedBytes)
                    guard !overflow, nextAggregate <= backupLimits.maxArchiveBytes else {
                        throw RoomBackupError.archiveLimitExceeded
                    }
                    aggregateBytes = nextAggregate
                    entries.append(RoomBackupMaterializationEntry(
                        entryPath: archivePath,
                        workspaceRelativePath: workspacePath,
                        packageRelativePath: source.packagePath,
                        mediaType: backupMediaType(for: source.packagePath.value)
                    ))
                }
                try validateBackupMaterializationClosure(entries)
                guard !pathExists(destinationURL), !isSymbolicLink(destinationURL) else {
                    throw RoomBackupError.destinationAlreadyExists(destinationURL.path)
                }
                try fileManager.moveItem(at: stagingURL, to: destinationURL)
                stagingCreated = false
                return RoomBackupMaterialization(
                    workspaceURL: destinationURL,
                    projectID: package.manifest.projectID,
                    headRevisionID: package.manifest.headRevisionID,
                    projectSchemaVersion: package.manifest.schemaVersion,
                    displayName: package.metadata.customName,
                    sourceUpdatedAt: package.effectiveLastRevisedDate,
                    revisionCount: package.revisions.count,
                    entries: entries.sorted { $0.entryPath < $1.entryPath }
                )
            } catch {
                if stagingCreated {
                    try? removeOwnedBackupWorkspace(stagingURL, token: token)
                }
                if let backupError = error as? RoomBackupError {
                    throw backupError
                }
                if let storeError = error as? RoomProjectStoreError {
                    throw RoomBackupError.storageFailure("Unable to materialize a validated package: \(storeError)")
                }
                throw RoomBackupError.storageFailure("Unable to materialize a full-project backup workspace.")
            }
        }
    }

    /// Parses an untrusted backup archive into an isolated, marker-owned stage
    /// and validates both its backup envelope and authoritative package before
    /// it becomes eligible for a separate explicit recovery decision.
    public func prepareRecovery(
        archiveURL: URL,
        expectedCloudDescriptor: RoomCloudBackupDescriptor,
        into requestedWorkspaceURL: URL
    ) async throws -> RoomBackupRecoveryPreparation {
        _ = try backupLimits.validatedZIPLimits()
        let root = try canonicalRootURL()
        let workspaceURL = try validatedRecoveryWorkspace(
            requestedWorkspaceURL,
            root: root
        )
        let token = UUID().uuidString.lowercased()
        let stageURL = workspaceURL.appendingPathComponent(
            ".roomscan-backup-recovery-stage-\(token)",
            isDirectory: true
        )
        let extractionURL = stageURL.appendingPathComponent("zip", isDirectory: true)
        let packageURL = stageURL.appendingPathComponent("package", isDirectory: true)
        var stageCreated = false
        do {
            try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
            try assertExternalBackupWorkspaceSafe(workspaceURL, root: root)
            guard !pathExists(stageURL), !isSymbolicLink(stageURL) else {
                throw RoomBackupError.destinationAlreadyExists(stageURL.path)
            }
            try fileManager.createDirectory(at: stageURL, withIntermediateDirectories: false)
            stageCreated = true
            try writeBackupWorkspaceOwnership(
                RoomBackupWorkspaceOwnershipRecord(
                    directoryName: stageURL.lastPathComponent,
                    token: token
                ),
                to: stageURL
            )
            try fileManager.createDirectory(at: extractionURL, withIntermediateDirectories: false)
            let manifest = try await RoomProjectBackupArchive.extractAndVerify(
                archiveURL: archiveURL,
                expectedDescriptor: expectedCloudDescriptor,
                into: extractionURL,
                limits: backupLimits
            )
            try reconstructBackupPackage(
                manifest: manifest,
                from: extractionURL,
                to: packageURL,
                maximumBytes: backupLimits.maxFileBytes,
                root: stageURL
            )
            _ = try withRootLock(root) {
                let package = try loadProjectPackageLocked(
                    root: stageURL,
                    projectID: manifest.projectID,
                    projectURL: packageURL
                )
                try validateBackupRevisionOwnership(
                    package: package,
                    projectURL: packageURL,
                    root: stageURL
                )
                guard
                    package.manifest.headRevisionID == manifest.headRevisionID,
                    package.manifest.schemaVersion == manifest.projectSchemaVersion,
                    package.metadata.customName == manifest.displayName,
                    package.revisions.count == manifest.revisionCount
                else {
                    throw RoomBackupError.invalidBackupManifest("Recovered package does not match its backup manifest.")
                }
            }
            let preparation = RoomBackupRecoveryPreparation(
                token: token,
                descriptor: expectedCloudDescriptor
            )
            preparedBackupRecoveries[token] = PreparedRoomBackupRecovery(
                token: token,
                workspaceRootURL: workspaceURL,
                stageURL: stageURL,
                packageURL: packageURL,
                manifest: manifest,
                descriptor: expectedCloudDescriptor
            )
            return preparation
        } catch {
            if stageCreated {
                try? removeOwnedBackupWorkspace(stageURL, token: token)
            }
            if let backupError = error as? RoomBackupError {
                throw backupError
            }
            throw RoomBackupError.storageFailure("Unable to prepare the backup recovery stage.")
        }
    }

    /// Noncancelable promotion of a previously isolated and fully validated
    /// stage. A divergent live package is never overwritten: the user must
    /// explicitly choose a recover-as-copy policy.
    public func commitPreparedRecovery(
        _ preparation: RoomBackupRecoveryPreparation,
        conflictPolicy: RoomBackupRecoveryConflictPolicy
    ) async throws -> RoomBackupRecoveryResult {
        guard let prepared = preparedBackupRecoveries[preparation.token],
              prepared.descriptor == preparation.descriptor
        else {
            throw RoomBackupError.preparedRecoveryNotFound(preparation.token)
        }
        let copyProjectID: String?
        switch conflictPolicy {
        case .failIfDivergent:
            copyProjectID = nil
        case .recoverAsCopy:
            copyProjectID = await idGenerator.nextProjectID()
            if let copyProjectID {
                try validateIdentifier(copyProjectID)
            }
        }
        let root = try canonicalRootURL()
        return try withRootLock(root) {
            let result = try promotePreparedBackupRecovery(
                prepared,
                root: root,
                conflictPolicy: conflictPolicy,
                copyProjectID: copyProjectID
            )
            preparedBackupRecoveries.removeValue(forKey: preparation.token)
            // The outer app backup lease owns the enclosing workspace and must
            // clean/retry it after successful promotion. This best-effort
            // inner-stage removal never changes a promoted local package.
            try? removeOwnedBackupWorkspace(prepared.stageURL, token: prepared.token)
            return result
        }
    }

    /// Cancels a prepared (but unpromoted) recovery stage. The token and its
    /// marker must match exactly; a cleanup failure leaves the token retained
    /// so the caller can retry the same narrowly scoped cleanup.
    public func discardPreparedRecovery(
        _ preparation: RoomBackupRecoveryPreparation
    ) throws {
        guard let prepared = preparedBackupRecoveries[preparation.token],
              prepared.descriptor == preparation.descriptor
        else {
            throw RoomBackupError.preparedRecoveryNotFound(preparation.token)
        }
        try removeOwnedBackupWorkspace(prepared.stageURL, token: prepared.token)
        preparedBackupRecoveries.removeValue(forKey: preparation.token)
    }

    /// Reads only the declared project thumbnail bytes. This API never exposes
    /// package filesystem URLs to callers and rechecks containment, link, and
    /// regular-file requirements before returning data.
    public func thumbnailData(projectID: String) throws -> Data {
        try validateIdentifier(projectID)
        let root = try canonicalRootURL()
        return try withRootLock(root) {
            let package = try loadLocked(root: root, projectID: projectID)
            guard let thumbnail = package.metadata.thumbnailRelativePath else {
                throw RoomProjectStoreError.assetReferenceNotStaged(
                    "thumbnails/thumbnail.png"
                )
            }
            let projectURL = try projectDirectory(root: root, projectID: projectID)
            let thumbnailURL = projectURL.appendingPathComponent(thumbnail.value)
            try assertNoSymbolicLinks(root: root, through: thumbnailURL)
            guard try isRegularFile(thumbnailURL) else {
                throw RoomProjectStoreError.assetReferenceNotStaged(thumbnail.value)
            }
            do {
                return try Data(contentsOf: thumbnailURL)
            } catch {
                throw RoomProjectStoreError.storageFailure(
                    "Unable to read the room thumbnail."
                )
            }
        }
    }

    // MARK: - Hero cache (derived data)

    /// Reads the store-owned derived hero snapshot, or nil when absent or
    /// unreadable — a corrupt or stale hero cache is simply regenerated, never
    /// an error. Like `thumbnailData`, this API exposes bytes, not URLs.
    public func heroCache(projectID: String) throws -> RoomMeshHeroCachePayload? {
        try validateIdentifier(projectID)
        let root = try canonicalRootURL()
        return try withRootLock(root) {
            _ = try loadLocked(root: root, projectID: projectID)
            let projectURL = try projectDirectory(root: root, projectID: projectID)
            let directory = projectURL.appendingPathComponent(
                RoomMeshHeroCache.directoryName, isDirectory: true
            )
            let manifestURL = directory.appendingPathComponent(RoomMeshHeroCache.manifestFileName)
            let imageURL = directory.appendingPathComponent(RoomMeshHeroCache.imageFileName)
            guard
                (try? isRegularFile(manifestURL)) == true,
                (try? isRegularFile(imageURL)) == true,
                let manifest = try? readJSON(
                    RoomMeshHeroCacheManifest.self, from: manifestURL, root: root
                ),
                let imageData = try? Data(contentsOf: imageURL)
            else {
                return nil
            }
            return RoomMeshHeroCachePayload(manifest: manifest, imageData: imageData)
        }
    }

    /// Publishes a regenerated hero snapshot. The image is written before the
    /// manifest so a crash between the two leaves a cache that fails
    /// validation and regenerates, never a manifest describing missing bytes.
    public func publishHeroCache(
        projectID: String,
        manifest: RoomMeshHeroCacheManifest,
        imageData: Data
    ) throws {
        try validateIdentifier(projectID)
        let root = try canonicalRootURL()
        try withRootLock(root) {
            _ = try loadLocked(root: root, projectID: projectID)
            let projectURL = try projectDirectory(root: root, projectID: projectID)
            let directory = projectURL.appendingPathComponent(
                RoomMeshHeroCache.directoryName, isDirectory: true
            )
            try assertNoSymbolicLinks(root: root, through: directory)
            do {
                try fileManager.createDirectory(
                    at: directory, withIntermediateDirectories: true
                )
                try imageData.write(
                    to: directory.appendingPathComponent(RoomMeshHeroCache.imageFileName),
                    options: .atomic
                )
            } catch {
                throw RoomProjectStoreError.storageFailure(
                    "Unable to write the room hero snapshot."
                )
            }
            try writeJSON(
                manifest,
                to: directory.appendingPathComponent(RoomMeshHeroCache.manifestFileName),
                root: root
            )
        }
    }

    /// Removes the derived hero cache; absent is success, not failure.
    public func invalidateHeroCache(projectID: String) throws {
        try validateIdentifier(projectID)
        let root = try canonicalRootURL()
        try withRootLock(root) {
            _ = try loadLocked(root: root, projectID: projectID)
            let projectURL = try projectDirectory(root: root, projectID: projectID)
            let directory = projectURL.appendingPathComponent(
                RoomMeshHeroCache.directoryName, isDirectory: true
            )
            guard pathExists(directory) else { return }
            try assertNoSymbolicLinks(root: root, through: directory)
            do {
                try fileManager.removeItem(at: directory)
            } catch {
                throw RoomProjectStoreError.storageFailure(
                    "Unable to remove the room hero cache."
                )
            }
        }
    }

    @discardableResult
    public func updateMetadata(
        projectID: String,
        metadata: RoomMetadata
    ) throws -> RoomProjectSummary {
        try validateIdentifier(projectID)
        let root = try canonicalRootURL()
        return try withRootLock(root) {
            var package = try loadLocked(root: root, projectID: projectID)
            guard metadata.projectID == projectID else {
                throw RoomProjectStoreError.invalidPackage("Metadata project identifier does not match.")
            }

            var updatedMetadata = metadata
            updatedMetadata.lastRevisedDate = clock.now()
            try validate(metadata: updatedMetadata)
            let projectURL = try projectDirectory(root: root, projectID: projectID)
            try validateProjectAssetReference(
                metadata: updatedMetadata,
                projectURL: projectURL,
                root: root
            )
            try writeJSON(
                updatedMetadata,
                to: projectURL.appendingPathComponent("metadata.json"),
                root: root
            )
            package.metadata = updatedMetadata
            return makeSummary(package)
        }
    }

    public func archive(projectID: String) throws {
        try setArchiveState(projectID: projectID, archived: true)
    }

    public func unarchive(projectID: String) throws {
        try setArchiveState(projectID: projectID, archived: false)
    }

    @discardableResult
    public func duplicate(projectID: String) async throws -> RoomProjectSummary {
        // Awaiting IDs happens before the lock; source is reloaded under it.
        let duplicateProjectID = await idGenerator.nextProjectID()
        let duplicateRevisionID = await idGenerator.nextRevisionID()
        let root = try canonicalRootURL()

        return try withRootLock(root) {
            let source = try loadLocked(root: root, projectID: projectID)
            guard let sourceHead = source.revisions.last else {
                throw RoomProjectStoreError.invalidPackage("Source package has no revisions.")
            }

            var duplicateMetadata = source.metadata
            duplicateMetadata.projectID = duplicateProjectID
            duplicateMetadata.customName = "\(source.metadata.customName) copy"
            duplicateMetadata.archived = false

            let sourceProjectURL = try projectDirectory(
                root: root,
                projectID: projectID
            )
            let sourceRevisionURL = try revisionDirectory(
                root: root,
                projectID: projectID,
                revisionID: sourceHead.manifest.revisionID
            )
            var duplicateAssets = try restoredRevisionAssets(
                from: sourceRevisionURL,
                root: root
            )
            let evidenceCompatibility = try internalCopyEvidenceCompatibility(
                sourceProjectManifest: source.manifest,
                sourceRevisionManifest: sourceHead.manifest,
                copiedRevisionAssets: duplicateAssets
            )
            if let thumbnail = source.metadata.thumbnailRelativePath {
                let sourceThumbnailURL = sourceProjectURL.appendingPathComponent(
                    thumbnail.value
                )
                try assertNoSymbolicLinks(root: root, through: sourceThumbnailURL)
                guard try isRegularFile(sourceThumbnailURL) else {
                    throw RoomProjectStoreError.assetReferenceNotStaged(thumbnail.value)
                }
                duplicateAssets.append(
                    RoomAssetInput(
                        sourceURL: sourceThumbnailURL,
                        destination: thumbnail,
                        scope: .project
                    )
                )
            }

            return try writeNewProjectLocked(
                root: root,
                projectID: duplicateProjectID,
                revisionID: duplicateRevisionID,
                metadata: duplicateMetadata,
                payload: sourceHead.payload,
                reason: .duplicate,
                createdAt: clock.now(),
                assets: duplicateAssets,
                captureEvidence: sourceHead.manifest.captureEvidence,
                evidenceCompatibility: evidenceCompatibility
            )
        }
    }

    /// A deletion primitive only. UI confirmation is intentionally outside this
    /// Foundation store.
    public func delete(projectID: String) throws {
        try validateIdentifier(projectID)
        let root = try canonicalRootURL()
        try withRootLock(root) {
            let projectURL = try projectDirectory(root: root, projectID: projectID)
            try assertNoSymbolicLinks(root: root, through: projectURL)
            guard pathExists(projectURL) else {
                throw RoomProjectStoreError.projectNotFound(projectID)
            }
            guard directoryExists(projectURL) else {
                throw RoomProjectStoreError.invalidPackage("Room package is not a directory.")
            }
            try fileManager.removeItem(at: projectURL)
        }
    }

    @discardableResult
    public func appendRevision(
        projectID: String,
        revisionID: String,
        parentRevisionID: String?,
        reason: RoomRevisionReason,
        payload: RoomRevisionPayload,
        restoredFromRevisionID: String?,
        assets: [RoomAssetInput] = [],
        captureEvidence: RoomRevisionEvidencePlan? = nil
    ) throws -> RoomRevisionManifest {
        try validateIdentifier(projectID)
        try validateIdentifier(revisionID)
        // A rescan is never a generic caller-supplied append. It must be
        // recomputed under the store lock by acceptFixtureRescan so stale,
        // unregistered, and tampered proposals cannot mutate lineage.
        try validateAppendReason(
            reason: reason,
            restoredFromRevisionID: restoredFromRevisionID,
            allowsFixtureRescan: false
        )
        try validateEvidenceAssetInputs(
            assets,
            captureEvidence: captureEvidence,
            evidenceCompatibility: .strict
        )
        let root = try canonicalRootURL()
        return try withRootLock(root) {
            try appendRevisionLocked(
                root: root,
                projectID: projectID,
                revisionID: revisionID,
                parentRevisionID: parentRevisionID,
                reason: reason,
                payload: payload,
                restoredFromRevisionID: restoredFromRevisionID,
                assets: assets,
                createdAt: clock.now(),
                captureEvidence: captureEvidence,
                evidenceCompatibility: .strict,
                allowsFixtureRescan: false
            )
        }
    }

    @discardableResult
    public func appendEditRevision(
        projectID: String,
        payload: RoomRevisionPayload,
        newRevisionID: String? = nil,
        assets: [RoomAssetInput] = [],
        captureEvidence: RoomRevisionEvidencePlan? = nil
    ) async throws -> RoomRevisionManifest {
        try validateEvidenceAssetInputs(
            assets,
            captureEvidence: captureEvidence,
            evidenceCompatibility: .strict
        )
        let revisionID: String
        if let newRevisionID {
            revisionID = newRevisionID
        } else {
            revisionID = await idGenerator.nextRevisionID()
        }
        let root = try canonicalRootURL()
        return try withRootLock(root) {
            let package = try loadLocked(root: root, projectID: projectID)
            return try appendRevisionLocked(
                root: root,
                projectID: projectID,
                revisionID: revisionID,
                parentRevisionID: package.manifest.headRevisionID,
                reason: .edit,
                payload: payload,
                restoredFromRevisionID: nil,
                assets: assets,
                createdAt: clock.now(),
                captureEvidence: captureEvidence,
                evidenceCompatibility: .strict,
                allowsFixtureRescan: false
            )
        }
    }

    /// The editor's only durable write path. It reloads the authoritative
    /// package under the process-wide root lock, requires the caller's visible
    /// head to remain current, and internally carries every regular
    /// noncanonical parent revision asset into one immutable `.edit` child.
    /// UI code receives no package URLs and cannot choose evidence compatibility.
    @discardableResult
    public func commitEditRevision(
        projectID: String,
        expectedHeadRevisionID: String,
        payload: RoomRevisionPayload,
        newRevisionID: String? = nil
    ) async throws -> RoomRevisionManifest {
        try validateIdentifier(projectID)
        try validateIdentifier(expectedHeadRevisionID)
        let revisionID: String
        if let newRevisionID {
            revisionID = newRevisionID
        } else {
            revisionID = await idGenerator.nextRevisionID()
        }
        try validateIdentifier(revisionID)
        let root = try canonicalRootURL()

        return try withRootLock(root) {
            let package = try loadLocked(root: root, projectID: projectID)
            guard package.manifest.headRevisionID == expectedHeadRevisionID else {
                throw RoomProjectStoreError.parentDoesNotMatchHead(
                    projectID: projectID,
                    expected: package.manifest.headRevisionID,
                    actual: expectedHeadRevisionID
                )
            }
            guard let source = package.revisions.last,
                  source.manifest.revisionID == expectedHeadRevisionID else {
                throw RoomProjectStoreError.invalidPackage(
                    "The package head does not resolve to a committed revision."
                )
            }

            let sourceRevisionURL = try revisionDirectory(
                root: root,
                projectID: projectID,
                revisionID: expectedHeadRevisionID
            )
            // This includes photos, declared evidence, and future regular
            // attachments while excluding regenerated canonical JSON files.
            let sourceAssets = try restoredRevisionAssets(
                from: sourceRevisionURL,
                root: root
            )
            let evidenceCompatibility = try internalCopyEvidenceCompatibility(
                sourceProjectManifest: package.manifest,
                sourceRevisionManifest: source.manifest,
                copiedRevisionAssets: sourceAssets
            )
            return try appendRevisionLocked(
                root: root,
                projectID: projectID,
                revisionID: revisionID,
                parentRevisionID: expectedHeadRevisionID,
                reason: .edit,
                payload: payload,
                restoredFromRevisionID: nil,
                assets: sourceAssets,
                createdAt: clock.now(),
                captureEvidence: source.manifest.captureEvidence,
                evidenceCompatibility: evidenceCompatibility,
                allowsFixtureRescan: false
            )
        }
    }

    /// The only V1-A rescan write path. It reloads and recomputes the complete
    /// deterministic proposal while holding the process-wide root lock before
    /// adding exactly one immutable `.rescan` child revision.
    @discardableResult
    public func acceptFixtureRescan(
        projectID: String,
        expectedHeadRevisionID: String,
        proposal: RoomFixtureRescanProposal,
        newRevisionID: String? = nil
    ) async throws -> RoomRevisionManifest {
        try validateIdentifier(projectID)
        try validateIdentifier(expectedHeadRevisionID)
        let revisionID: String
        if let newRevisionID {
            revisionID = newRevisionID
        } else {
            revisionID = await idGenerator.nextRevisionID()
        }
        try validateIdentifier(revisionID)
        let root = try canonicalRootURL()

        return try withRootLock(root) {
            let package = try loadLocked(root: root, projectID: projectID)
            guard package.manifest.headRevisionID == expectedHeadRevisionID else {
                throw RoomProjectStoreError.parentDoesNotMatchHead(
                    projectID: projectID,
                    expected: package.manifest.headRevisionID,
                    actual: expectedHeadRevisionID
                )
            }
            guard
                proposal.projectID == projectID,
                proposal.baseRevisionID == expectedHeadRevisionID,
                proposal.expectedHeadRevisionID == expectedHeadRevisionID,
                let base = package.revisions.first(where: {
                    $0.manifest.revisionID == expectedHeadRevisionID
                })
            else {
                throw RoomProjectStoreError.invalidRescanProposal(
                    "The fixture rescan proposal does not target the current immutable head."
                )
            }

            let verified: RoomFixtureRescanProposal
            do {
                verified = try RoomRescanEngine.verifyFixtureProposal(
                    proposal,
                    against: base.payload
                )
            } catch let error as RoomRescanError {
                throw RoomProjectStoreError.invalidRescanProposal(error.message)
            }

            let sourceRevisionURL = try revisionDirectory(
                root: root,
                projectID: projectID,
                revisionID: expectedHeadRevisionID
            )
            let photoAssets = try rescanPhotoAssets(
                from: base.payload,
                sourceRevisionURL: sourceRevisionURL,
                root: root
            )
            return try appendRevisionLocked(
                root: root,
                projectID: projectID,
                revisionID: revisionID,
                parentRevisionID: expectedHeadRevisionID,
                reason: .rescan,
                payload: verified.resultPayload,
                restoredFromRevisionID: nil,
                assets: photoAssets,
                createdAt: clock.now(),
                captureEvidence: RoomRescanEngine.deterministicFixtureEvidencePlan(),
                evidenceCompatibility: .strict,
                allowsFixtureRescan: true
            )
        }
    }

    @discardableResult
    public func restoreAsNewRevision(
        projectID: String,
        sourceRevisionID: String,
        newRevisionID: String? = nil
    ) async throws -> RoomRevisionManifest {
        try validateIdentifier(sourceRevisionID)
        let revisionID: String
        if let newRevisionID {
            revisionID = newRevisionID
        } else {
            revisionID = await idGenerator.nextRevisionID()
        }
        let root = try canonicalRootURL()

        return try withRootLock(root) {
            let package = try loadLocked(root: root, projectID: projectID)
            guard let source = package.revisions.first(where: {
                $0.manifest.revisionID == sourceRevisionID
            }) else {
                throw RoomProjectStoreError.revisionNotFound(
                    projectID: projectID,
                    revisionID: sourceRevisionID
                )
            }

            let sourceRevisionURL = try revisionDirectory(
                root: root,
                projectID: projectID,
                revisionID: sourceRevisionID
            )
            // Preserve all owned revision evidence, not only declared photos.
            // Canonical JSON documents are regenerated for the new revision.
            let sourceAssets = try restoredRevisionAssets(
                from: sourceRevisionURL,
                root: root
            )
            let evidenceCompatibility = try internalCopyEvidenceCompatibility(
                sourceProjectManifest: package.manifest,
                sourceRevisionManifest: source.manifest,
                copiedRevisionAssets: sourceAssets
            )

            return try appendRevisionLocked(
                root: root,
                projectID: projectID,
                revisionID: revisionID,
                parentRevisionID: package.manifest.headRevisionID,
                reason: .revert,
                payload: source.payload,
                restoredFromRevisionID: sourceRevisionID,
                assets: sourceAssets,
                createdAt: clock.now(),
                captureEvidence: source.manifest.captureEvidence,
                evidenceCompatibility: evidenceCompatibility,
                allowsFixtureRescan: false
            )
        }
    }

    private func setArchiveState(projectID: String, archived: Bool) throws {
        try validateIdentifier(projectID)
        let root = try canonicalRootURL()
        try withRootLock(root) {
            var package = try loadLocked(root: root, projectID: projectID)
            var metadata = package.metadata
            metadata.archived = archived
            metadata.lastRevisedDate = clock.now()
            try validate(metadata: metadata)

            let projectURL = try projectDirectory(root: root, projectID: projectID)
            try validateProjectAssetReference(
                metadata: metadata,
                projectURL: projectURL,
                root: root
            )
            try writeJSON(
                metadata,
                to: projectURL.appendingPathComponent("metadata.json"),
                root: root
            )
            package.metadata = metadata
        }
    }

    private struct ExportRevisionDocument {
        let sourceName: String
        let workspacePath: String
        let entryPath: String
        let output: RoomExportOutput
    }

    private struct ExportMaterializationBudget {
        let limits: RoomExportMaterializationLimits
        private(set) var entryCount = 0
        private(set) var aggregateBytes: UInt64 = 0
        private var reservedByteCount: UInt64?

        init(limits: RoomExportMaterializationLimits) {
            self.limits = limits
        }

        var remainingAggregateBytes: UInt64 {
            limits.maxAggregateBytes >= aggregateBytes
                ? limits.maxAggregateBytes - aggregateBytes
                : 0
        }

        mutating func reserve(_ byteCount: UInt64, entryPath: String) throws {
            guard reservedByteCount == nil else {
                throw RoomExportError.archiveLimitExceeded
            }
            guard entryCount < limits.maxEntries else {
                throw RoomExportError.entryLimitExceeded
            }
            guard byteCount <= limits.maxFileBytes else {
                throw RoomExportError.sizeLimitExceeded(entryPath)
            }
            let (nextAggregate, overflow) = aggregateBytes.addingReportingOverflow(byteCount)
            guard !overflow, nextAggregate <= limits.maxAggregateBytes else {
                throw RoomExportError.archiveLimitExceeded
            }
            reservedByteCount = byteCount
        }

        mutating func commitReservedEntry() {
            guard let reservedByteCount else { return }
            aggregateBytes += reservedByteCount
            entryCount += 1
            self.reservedByteCount = nil
        }
    }

    private static let exportRevisionDocuments: [ExportRevisionDocument] = [
        ExportRevisionDocument(
            sourceName: "semantic-model.json",
            workspacePath: "revision/semantic-model.json",
            entryPath: "revision/semantic-model.json",
            output: .semanticJSON
        ),
        ExportRevisionDocument(
            sourceName: "annotations.json",
            workspacePath: "revision/annotations.json",
            entryPath: "revision/annotations.json",
            output: .annotationsJSON
        ),
        ExportRevisionDocument(
            sourceName: "measurements.json",
            workspacePath: "revision/measurements.json",
            entryPath: "revision/measurements.json",
            output: .measurementsJSON
        ),
    ]

    private static let baseExportOutputRecords: [RoomExportOutputRecord] = [
        RoomExportOutputRecord(output: .metadataJSON, status: .included),
        RoomExportOutputRecord(output: .revisionJSON, status: .included),
        RoomExportOutputRecord(output: .semanticJSON, status: .included),
        RoomExportOutputRecord(output: .annotationsJSON, status: .included),
        RoomExportOutputRecord(output: .measurementsJSON, status: .included),
        RoomExportOutputRecord(output: .photosJSON, status: .included),
        RoomExportOutputRecord(output: .sourceMapJSON, status: .included),
        RoomExportOutputRecord(output: .thumbnailPNG, status: .skipped, reasonCode: .noThumbnail),
        RoomExportOutputRecord(output: .referencePhotos, status: .skipped, reasonCode: .noReferencePhotos),
        RoomExportOutputRecord(output: .capturedRoomDataJSON, status: .skipped, reasonCode: .notRequested),
        RoomExportOutputRecord(output: .capturedRoomJSON, status: .skipped, reasonCode: .notRequested),
        RoomExportOutputRecord(output: .nativeUSDZ, status: .skipped, reasonCode: .noDeclaredNativeUSDZ),
        RoomExportOutputRecord(output: .rawMesh, status: .skipped, reasonCode: .notRequested),
        RoomExportOutputRecord(output: .worldMap, status: .skipped, reasonCode: .notRequested),
        RoomExportOutputRecord(output: .provenance, status: .skipped, reasonCode: .notRequested),
        RoomExportOutputRecord(output: .floorPlanPNG, status: .skipped, reasonCode: .notRequested),
        RoomExportOutputRecord(output: .pdfSummary, status: .skipped, reasonCode: .notRequested),
        RoomExportOutputRecord(output: .glb, status: .skipped, reasonCode: .noVerifiedConverter),
        RoomExportOutputRecord(output: .obj, status: .skipped, reasonCode: .noVerifiedConverter),
        RoomExportOutputRecord(output: .ply, status: .skipped, reasonCode: .noVerifiedConverter),
        RoomExportOutputRecord(output: .attachments, status: .skipped, reasonCode: .noAttachments),
    ]

    private func materializeExportEvidence(
        manifest: RoomRevisionManifest,
        compatibility: RoomRevisionEvidenceCompatibility,
        sourceRevisionURL: URL,
        stage: URL,
        entries: inout [RoomMaterializedExportEntry],
        outputs: inout [RoomExportOutputRecord],
        outboundReferences: inout [String: String],
        budget: inout ExportMaterializationBudget
    ) throws {
        guard let evidence = manifest.captureEvidence else {
            let evidenceDirectory = sourceRevisionURL.appendingPathComponent("evidence", isDirectory: true)
            if compatibility == .legacyV1Planless, pathExists(evidenceDirectory) {
                throw RoomExportError.legacyPlanlessEvidence(
                    "Historical plan-less evidence cannot be exported as complete evidence."
                )
            }
            setExportOutput(
                &outputs,
                output: .nativeUSDZ,
                status: .skipped,
                reason: compatibility == .legacyV1Planless
                    ? .legacyPlanlessEvidence
                    : .noDeclaredNativeUSDZ
            )
            return
        }

        let sourceMap: [RoomEvidenceArtifactKind: (workspace: String, output: RoomExportOutput, mediaType: String)] = [
            .capturedRoomDataJSON: (
                "evidence/roomplan/captured-room-data.json",
                .capturedRoomDataJSON,
                "application/json"
            ),
            .capturedRoomJSON: (
                "evidence/roomplan/captured-room.json",
                .capturedRoomJSON,
                "application/json"
            ),
            .nativeUSDZ: ("native/RoomScan.usdz", .nativeUSDZ, "model/vnd.usdz+zip"),
            .rawMesh: ("evidence/arkit/raw-mesh.bin", .rawMesh, "application/octet-stream"),
            .worldMap: ("evidence/arkit/world-map.bin", .worldMap, "application/octet-stream"),
            .provenance: ("evidence/provenance.json", .provenance, "application/json"),
        ]
        for artifact in evidence.artifacts {
            guard let map = sourceMap[artifact.kind] else { continue }
            switch artifact.status {
            case .present:
                guard let path = artifact.relativePath else {
                    throw RoomExportError.missingRequiredArtifact(artifact.kind.rawValue)
                }
                try materializeExportFile(
                    from: sourceRevisionURL.appendingPathComponent(path.value),
                    stage: stage,
                    workspacePath: map.workspace,
                    entryPath: map.workspace,
                    mediaType: artifact.mediaType ?? map.mediaType,
                    output: map.output,
                    entries: &entries,
                    budget: &budget
                )
                outboundReferences[path.value] = map.workspace
                setExportOutput(&outputs, output: map.output, status: .included)
            case .unavailable, .notRequested:
                let reason: RoomExportReasonCode
                if evidence.source == .deterministicFixture {
                    reason = .deterministicFixture
                } else if artifact.status == .unavailable {
                    reason = .evidenceUnavailable
                } else if artifact.kind == .nativeUSDZ {
                    reason = .noDeclaredNativeUSDZ
                } else {
                    reason = .notRequested
                }
                setExportOutput(
                    &outputs,
                    output: map.output,
                    status: .skipped,
                    reason: reason
                )
            }
        }
        guard entries.contains(where: { $0.output == .nativeUSDZ }) else {
            setExportOutput(
                &outputs,
                output: .nativeUSDZ,
                status: .skipped,
                reason: evidence.source == .deterministicFixture
                    ? .deterministicFixture
                    : .noDeclaredNativeUSDZ
            )
            return
        }
    }

    private func materializeExportAttachments(
        from sourceRevisionURL: URL,
        excludingPhotoPaths photoPaths: Set<String>,
        evidence: RoomRevisionEvidencePlan?,
        stage: URL,
        entries: inout [RoomMaterializedExportEntry],
        budget: inout ExportMaterializationBudget
    ) throws -> Int {
        let evidencePaths = Set(
            evidence?.artifacts.compactMap { artifact in
                artifact.status == .present ? artifact.relativePath?.value : nil
            } ?? []
        )
        let candidates = try regularRevisionAssets(
            in: sourceRevisionURL,
            relativeDirectory: "",
            root: try canonicalRootURL()
        ).sorted { $0.1 < $1.1 }
        var outputIndex = 0
        for (sourceURL, relativePath) in candidates {
            guard
                relativePath.hasPrefix("attachments/"),
                !photoPaths.contains(relativePath),
                !evidencePaths.contains(relativePath),
                !relativePath.hasPrefix("exports/")
            else {
                continue
            }
            outputIndex += 1
            let extensionName = exportExtension(for: relativePath, default: "bin")
            let destination = String(format: "attachments/attachment-%04d.%@", outputIndex, extensionName)
            try materializeExportFile(
                from: sourceURL,
                stage: stage,
                workspacePath: destination,
                entryPath: destination,
                mediaType: exportMediaType(forExtension: extensionName),
                output: .attachments,
                entries: &entries,
                budget: &budget
            )
        }
        return outputIndex
    }

    private func materializeExportFile(
        from sourceURL: URL,
        stage: URL,
        workspacePath: String,
        entryPath: String,
        mediaType: String,
        output: RoomExportOutput,
        entries: inout [RoomMaterializedExportEntry],
        budget: inout ExportMaterializationBudget
    ) throws {
        let workspaceRelativePath = try RoomRelativePath(workspacePath)
        let archivePath = try RoomExportEntryPath(entryPath)
        let destinationURL = stage.appendingPathComponent(workspaceRelativePath.value)
        guard isContained(destinationURL, within: stage), !pathExists(destinationURL), !isSymbolicLink(destinationURL) else {
            throw RoomExportError.unsafeDestination(destinationURL.path)
        }
        guard try isRegularFile(sourceURL), !isSymbolicLink(sourceURL) else {
            throw RoomExportError.missingRequiredArtifact(sourceURL.lastPathComponent)
        }
        let expectedByteCount = try exportFileByteCount(sourceURL)
        try budget.reserve(expectedByteCount, entryPath: entryPath)
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let copiedByteCount = try deepCopyRegularFile(
            from: sourceURL,
            to: destinationURL,
            maximumByteCount: expectedByteCount
        )
        guard copiedByteCount == expectedByteCount else {
            throw RoomExportError.sourceChangedAfterPreflight(entryPath)
        }
        budget.commitReservedEntry()
        entries.append(
            RoomMaterializedExportEntry(
                entryPath: archivePath,
                workspaceRelativePath: workspaceRelativePath,
                mediaType: mediaType,
                output: output
            )
        )
    }

    private func materializeExportJSON<Value: Encodable>(
        _ value: Value,
        stage: URL,
        workspacePath: String,
        entryPath: String,
        output: RoomExportOutput,
        entries: inout [RoomMaterializedExportEntry],
        budget: inout ExportMaterializationBudget
    ) throws {
        let workspaceRelativePath = try RoomRelativePath(workspacePath)
        let archivePath = try RoomExportEntryPath(entryPath)
        let destinationURL = stage.appendingPathComponent(workspaceRelativePath.value)
        guard isContained(destinationURL, within: stage), !pathExists(destinationURL), !isSymbolicLink(destinationURL) else {
            throw RoomExportError.unsafeDestination(destinationURL.path)
        }
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            let data = try RoomJSONCoding.makeEncoder().encode(value)
            try budget.reserve(UInt64(data.count), entryPath: entryPath)
            try RoomAtomicFileWriter.writeNewFile(
                data,
                to: destinationURL,
                fileManager: fileManager
            )
            budget.commitReservedEntry()
        } catch let error as RoomExportError {
            throw error
        } catch {
            throw RoomExportError.unsafeDestination(destinationURL.path)
        }
        entries.append(
            RoomMaterializedExportEntry(
                entryPath: archivePath,
                workspaceRelativePath: workspaceRelativePath,
                mediaType: "application/json",
                output: output
            )
        )
    }

    private func deepCopyRegularFile(
        from sourceURL: URL,
        to destinationURL: URL,
        maximumByteCount: UInt64
    ) throws -> UInt64 {
        guard !pathExists(destinationURL), !isSymbolicLink(destinationURL) else {
            throw RoomExportError.destinationAlreadyExists(destinationURL.path)
        }
        guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
            throw RoomExportError.unsafeDestination(destinationURL.path)
        }
        let sourceHandle: FileHandle
        let destinationHandle: FileHandle
        do {
            sourceHandle = try FileHandle(forReadingFrom: sourceURL)
            destinationHandle = try FileHandle(forWritingTo: destinationURL)
        } catch {
            throw RoomExportError.unsafeDestination(destinationURL.path)
        }
        defer {
            try? sourceHandle.close()
            try? destinationHandle.close()
        }
        var copiedByteCount: UInt64 = 0
        do {
            while let chunk = try sourceHandle.read(upToCount: RoomDeterministicZIP.defaultChunkSize), !chunk.isEmpty {
                let (nextByteCount, overflow) = copiedByteCount.addingReportingOverflow(UInt64(chunk.count))
                guard !overflow, nextByteCount <= maximumByteCount else {
                    throw RoomExportError.sizeLimitExceeded(sourceURL.lastPathComponent)
                }
                try destinationHandle.write(contentsOf: chunk)
                copiedByteCount = nextByteCount
            }
            try destinationHandle.synchronize()
        } catch {
            if let exportError = error as? RoomExportError {
                throw exportError
            }
            throw RoomExportError.unsafeDestination(destinationURL.path)
        }
        return copiedByteCount
    }

    private func exportFileByteCount(_ url: URL) throws -> UInt64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value >= 0 else {
            throw RoomExportError.missingRequiredArtifact(url.lastPathComponent)
        }
        return UInt64(size.int64Value)
    }

    private func validatedExportDestination(_ requestedDestinationURL: URL, root: URL) throws -> URL {
        guard requestedDestinationURL.isFileURL else {
            throw RoomExportError.unsafeDestination(requestedDestinationURL.path)
        }
        let requested = requestedDestinationURL.standardizedFileURL
        let requestedParent = requested.deletingLastPathComponent()
        guard
            !requested.lastPathComponent.isEmpty,
            pathExists(requestedParent),
            directoryExists(requestedParent),
            !isSymbolicLink(requested),
            !pathExists(requested)
        else {
            throw RoomExportError.destinationAlreadyExists(requested.path)
        }
        let canonicalParent = requestedParent.resolvingSymlinksInPath().standardizedFileURL
        let destination = canonicalParent.appendingPathComponent(requested.lastPathComponent, isDirectory: true)
        guard !isContained(destination, within: root) else {
            throw RoomExportError.destinationInsideProjectRoot
        }
        guard !pathExists(destination), !isSymbolicLink(destination) else {
            throw RoomExportError.destinationAlreadyExists(destination.path)
        }
        return destination
    }

    private func makeExportStagingURL(parent: URL) throws -> URL {
        guard directoryExists(parent), !isSymbolicLink(parent) else {
            throw RoomExportError.unsafeDestination(parent.path)
        }
        for _ in 0..<16 {
            let candidate = parent.appendingPathComponent(
                ".roomscan-export-stage-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
            if !pathExists(candidate), !isSymbolicLink(candidate) {
                return candidate
            }
        }
        throw RoomExportError.unsafeDestination(parent.path)
    }

    private func removeOwnedExportStaging(_ stagingURL: URL, parent: URL) throws {
        guard
            stagingURL.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL,
            stagingURL.lastPathComponent.hasPrefix(".roomscan-export-stage-"),
            pathExists(stagingURL),
            directoryExists(stagingURL),
            !isSymbolicLink(stagingURL)
        else {
            return
        }
        try fileManager.removeItem(at: stagingURL)
    }

    private func setExportOutput(
        _ records: inout [RoomExportOutputRecord],
        output: RoomExportOutput,
        status: RoomExportOutputStatus,
        reason: RoomExportReasonCode? = nil
    ) {
        let record = RoomExportOutputRecord(output: output, status: status, reasonCode: reason)
        if let index = records.firstIndex(where: { $0.output == output }) {
            records[index] = record
        } else {
            records.append(record)
        }
    }

    private func exportExtension(for path: String, default fallback: String) -> String {
        let extensionName = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard
            !extensionName.isEmpty,
            extensionName.count <= 10,
            extensionName.unicodeScalars.allSatisfy({ scalar in
                (48...57).contains(scalar.value)
                    || (97...122).contains(scalar.value)
            })
        else {
            return fallback
        }
        return extensionName
    }

    private func exportMediaType(forExtension extensionName: String) -> String {
        switch extensionName.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "heic": "image/heic"
        case "pdf": "application/pdf"
        case "json": "application/json"
        default: "application/octet-stream"
        }
    }

    private func loadLocked(root: URL, projectID: String) throws -> RoomProjectPackage {
        let projectURL = try projectDirectory(root: root, projectID: projectID)
        try assertNoSymbolicLinks(root: root, through: projectURL)
        guard pathExists(projectURL) else {
            throw RoomProjectStoreError.projectNotFound(projectID)
        }
        guard directoryExists(projectURL) else {
            throw RoomProjectStoreError.invalidPackage("Room package is not a directory.")
        }

        try reconcilePendingRevisionLocked(root: root, projectID: projectID)
        return try loadProjectPackageLocked(root: root, projectID: projectID)
    }

    private func writeNewProjectLocked(
        root: URL,
        projectID: String,
        revisionID: String,
        metadata: RoomMetadata,
        payload: RoomRevisionPayload,
        reason: RoomRevisionReason,
        createdAt: Date,
        assets: [RoomAssetInput],
        captureEvidence: RoomRevisionEvidencePlan?,
        evidenceCompatibility: RoomRevisionEvidenceCompatibility,
        qualityReport: RoomQualityReport? = nil
    ) throws -> RoomProjectSummary {
        try validateIdentifier(projectID)
        try validateIdentifier(revisionID)
        guard reason == .initial || reason == .duplicate else {
            throw RoomProjectStoreError.invalidRevisionReason(
                reason: reason,
                restoredFromRevisionID: nil
            )
        }
        try validateEvidenceAssetInputs(
            assets,
            captureEvidence: captureEvidence,
            evidenceCompatibility: evidenceCompatibility
        )
        try ensureRootExists(root)

        let finalProjectURL = try projectDirectory(root: root, projectID: projectID)
        try assertNoSymbolicLinks(root: root, through: finalProjectURL)
        guard !pathExists(finalProjectURL) else {
            throw RoomProjectStoreError.projectAlreadyExists(projectID)
        }

        let normalizedMetadata = try normalized(
            metadata: metadata,
            projectID: projectID,
            lastRevisedDate: createdAt
        )
        let normalizedPayload = try normalized(
            payload: payload,
            projectID: projectID,
            revisionID: revisionID
        )
        let revisionManifest = RoomRevisionManifest(
            revisionID: revisionID,
            projectID: projectID,
            parentRevisionID: nil,
            reason: reason,
            createdAt: createdAt,
            immutable: true,
            captureEvidence: captureEvidence,
            evidenceCompatibility: evidenceCompatibility,
            qualityReport: qualityReport
        )
        let revision = RoomRevisionPackage(
            manifest: revisionManifest,
            payload: normalizedPayload
        )
        let manifest = RoomProjectManifest(
            schemaVersion: RoomProjectSchemaVersion.v2.rawValue,
            projectID: projectID,
            headRevisionID: revisionID,
            revisionIDs: [revisionID],
            createdAt: createdAt,
            updatedAt: createdAt
        )
        let package = RoomProjectPackage(
            manifest: manifest,
            metadata: normalizedMetadata,
            revisions: [revision]
        )
        try validate(package: package, expectedProjectID: projectID)

        let stagingURL = try makeUniqueStagingURL(
            parent: root,
            prefix: ".staging-\(projectID)-\(revisionID)-",
            root: root
        )
        let stagedRevisionURL = stagingURL
            .appendingPathComponent("revisions", isDirectory: true)
            .appendingPathComponent(revisionID, isDirectory: true)
        let ownership = RoomRevisionOwnershipRecord(
            projectID: projectID,
            revisionID: revisionID,
            transactionID: UUID().uuidString.lowercased()
        )

        do {
            try assertNoSymbolicLinks(root: root, through: stagingURL)
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
            try writeRevision(
                revision,
                to: stagedRevisionURL,
                ownership: ownership,
                root: root
            )
            try copyAssets(
                assets,
                projectRoot: stagingURL,
                revisionRoot: stagedRevisionURL,
                allowedScopes: [.project, .revision],
                root: root
            )
            try writeJSON(
                normalizedMetadata,
                to: stagingURL.appendingPathComponent("metadata.json"),
                root: root
            )
            try writeJSON(
                manifest,
                to: stagingURL.appendingPathComponent("manifest.json"),
                root: root
            )

            let stagedPackage = try loadProjectPackageLocked(
                root: root,
                projectID: projectID,
                projectURL: stagingURL
            )
            try validate(package: stagedPackage, expectedProjectID: projectID)
            try faultInjector.throwIfNeeded(at: .beforeInitialPackagePromotion)

            try assertNoSymbolicLinks(root: root, through: stagingURL)
            try assertNoSymbolicLinks(root: root, through: finalProjectURL)
            guard !pathExists(finalProjectURL) else {
                throw RoomProjectStoreError.projectAlreadyExists(projectID)
            }
            // Same-root rename promotes the fully validated package as one unit.
            try fileManager.moveItem(at: stagingURL, to: finalProjectURL)
            return makeSummary(stagedPackage)
        } catch let error as RoomProjectStoreError {
            try? removeInitialStagingIfPresent(stagingURL, root: root)
            throw error
        } catch {
            try? removeInitialStagingIfPresent(stagingURL, root: root)
            throw RoomProjectStoreError.storageFailure("Unable to save room package.")
        }
    }

    private func appendRevisionLocked(
        root: URL,
        projectID: String,
        revisionID: String,
        parentRevisionID: String?,
        reason: RoomRevisionReason,
        payload: RoomRevisionPayload,
        restoredFromRevisionID: String?,
        assets: [RoomAssetInput],
        createdAt: Date,
        captureEvidence: RoomRevisionEvidencePlan?,
        evidenceCompatibility: RoomRevisionEvidenceCompatibility,
        allowsFixtureRescan: Bool
    ) throws -> RoomRevisionManifest {
        try validateIdentifier(projectID)
        try validateIdentifier(revisionID)
        try validateAppendReason(
            reason: reason,
            restoredFromRevisionID: restoredFromRevisionID,
            allowsFixtureRescan: allowsFixtureRescan
        )
        try validateEvidenceAssetInputs(
            assets,
            captureEvidence: captureEvidence,
            evidenceCompatibility: evidenceCompatibility
        )
        let package = try loadLocked(root: root, projectID: projectID)
        let projectSchemaVersion = try validatedProjectSchemaVersion(
            package.manifest
        )

        guard !package.manifest.revisionIDs.contains(revisionID) else {
            throw RoomProjectStoreError.duplicateRevisionID(revisionID)
        }
        guard parentRevisionID == package.manifest.headRevisionID else {
            throw RoomProjectStoreError.parentDoesNotMatchHead(
                projectID: projectID,
                expected: package.manifest.headRevisionID,
                actual: parentRevisionID
            )
        }
        if let restoredFromRevisionID {
            try validateIdentifier(restoredFromRevisionID)
            guard package.manifest.revisionIDs.contains(restoredFromRevisionID) else {
                throw RoomProjectStoreError.revisionNotFound(
                    projectID: projectID,
                    revisionID: restoredFromRevisionID
                )
            }
        }

        let projectURL = try projectDirectory(root: root, projectID: projectID)
        let revisionsURL = projectURL.appendingPathComponent("revisions", isDirectory: true)
        let finalRevisionURL = try revisionDirectory(
            root: root,
            projectID: projectID,
            revisionID: revisionID
        )
        try assertNoSymbolicLinks(root: root, through: revisionsURL)
        try assertNoSymbolicLinks(root: root, through: finalRevisionURL)
        guard !pathExists(finalRevisionURL) else {
            throw RoomProjectStoreError.revisionAlreadyExists(revisionID)
        }

        let normalizedPayload = try normalized(
            payload: payload,
            projectID: projectID,
            revisionID: revisionID
        )
        let revisionManifest = RoomRevisionManifest(
            revisionID: revisionID,
            projectID: projectID,
            parentRevisionID: parentRevisionID,
            reason: reason,
            createdAt: createdAt,
            immutable: true,
            restoredFromRevisionID: restoredFromRevisionID,
            captureEvidence: captureEvidence,
            evidenceCompatibility: evidenceCompatibility
        )
        let revision = RoomRevisionPackage(
            manifest: revisionManifest,
            payload: normalizedPayload
        )
        try validate(
            revision: revision,
            expectedProjectID: projectID,
            expectedRevisionID: revisionID,
            projectSchemaVersion: projectSchemaVersion
        )

        var updatedManifest = package.manifest
        updatedManifest.revisionIDs.append(revisionID)
        updatedManifest.headRevisionID = revisionID
        updatedManifest.updatedAt = createdAt
        try validate(manifest: updatedManifest, expectedProjectID: projectID)

        let transactionID = UUID().uuidString.lowercased()
        let stagingURL = try makeUniqueStagingURL(
            parent: projectURL,
            prefix: ".staging-\(revisionID)-",
            root: root
        )
        let ownership = RoomRevisionOwnershipRecord(
            projectID: projectID,
            revisionID: revisionID,
            transactionID: transactionID
        )
        let pending = PendingRoomRevisionTransaction(
            projectID: projectID,
            revisionID: revisionID,
            previousHeadRevisionID: package.manifest.headRevisionID,
            stagingDirectoryName: stagingURL.lastPathComponent,
            transactionID: transactionID,
            updatedManifest: updatedManifest,
            createdAt: createdAt,
            evidenceCompatibility: evidenceCompatibility
        )
        let markerURL = projectURL.appendingPathComponent(".pending-revision.json")
        var markerWritten = false

        do {
            try writeRevision(
                revision,
                to: stagingURL,
                ownership: ownership,
                root: root
            )
            try copyAssets(
                assets,
                projectRoot: projectURL,
                revisionRoot: stagingURL,
                allowedScopes: [.revision],
                root: root
            )
            _ = try loadRevision(
                projectID: projectID,
                revisionID: revisionID,
                from: stagingURL,
                root: root,
                projectSchemaVersion: projectSchemaVersion
            )

            // The marker is the durable ownership proof before the promotion.
            try writeJSON(pending, to: markerURL, root: root)
            markerWritten = true
            try assertNoSymbolicLinks(root: root, through: stagingURL)
            try assertNoSymbolicLinks(root: root, through: finalRevisionURL)
            guard !pathExists(finalRevisionURL) else {
                throw RoomProjectStoreError.revisionAlreadyExists(revisionID)
            }
            try fileManager.moveItem(at: stagingURL, to: finalRevisionURL)
            try faultInjector.throwIfNeeded(at: .afterRevisionPromotionBeforeManifest)

            // The new immutable revision exists before the head changes.
            try writeJSON(
                updatedManifest,
                to: projectURL.appendingPathComponent("manifest.json"),
                root: root
            )
            try removePendingMarker(markerURL, root: root)
            return revisionManifest
        } catch let error as RoomProjectStoreError {
            if markerWritten {
                try? reconcilePendingRevisionLocked(root: root, projectID: projectID)
            } else {
                try? removeOwnedStagingIfPresent(
                    stagingURL,
                    ownership: ownership,
                    root: root
                )
            }
            throw error
        } catch {
            if markerWritten {
                try? reconcilePendingRevisionLocked(root: root, projectID: projectID)
            } else {
                try? removeOwnedStagingIfPresent(
                    stagingURL,
                    ownership: ownership,
                    root: root
                )
            }
            throw RoomProjectStoreError.storageFailure("Unable to append room revision.")
        }
    }

    private func reconcilePendingRevisionLocked(
        root: URL,
        projectID: String
    ) throws {
        let projectURL = try projectDirectory(root: root, projectID: projectID)
        try assertNoSymbolicLinks(root: root, through: projectURL)
        let markerURL = projectURL.appendingPathComponent(".pending-revision.json")
        try assertNoSymbolicLinks(root: root, through: markerURL)
        guard pathExists(markerURL) else {
            return
        }

        let pending = try readJSON(
            PendingRoomRevisionTransaction.self,
            from: markerURL,
            root: root
        )
        try validate(pending: pending, expectedProjectID: projectID)

        let stagingURL = projectURL.appendingPathComponent(
            pending.stagingDirectoryName,
            isDirectory: true
        )
        let finalRevisionURL = try revisionDirectory(
            root: root,
            projectID: projectID,
            revisionID: pending.revisionID
        )
        try assertNoSymbolicLinks(root: root, through: stagingURL)
        try assertNoSymbolicLinks(root: root, through: finalRevisionURL)

        let expectedOwnership = RoomRevisionOwnershipRecord(
            projectID: pending.projectID,
            revisionID: pending.revisionID,
            transactionID: pending.transactionID
        )
        let finalExists = pathExists(finalRevisionURL)
        if finalExists {
            guard try revisionDirectory(finalRevisionURL, hasOwnership: expectedOwnership, root: root) else {
                throw RoomProjectStoreError.invalidPackage(
                    "Pending marker does not own its promoted revision."
                )
            }

            let manifestURL = projectURL.appendingPathComponent("manifest.json")
            let currentManifest = try readJSON(
                RoomProjectManifest.self,
                from: manifestURL,
                root: root
            )
            try validate(manifest: currentManifest, expectedProjectID: projectID)
            let projectSchemaVersion = try validatedProjectSchemaVersion(
                currentManifest
            )

            if currentManifest.revisionIDs.contains(pending.revisionID) {
                guard currentManifest.headRevisionID == pending.revisionID else {
                    throw RoomProjectStoreError.invalidPackage(
                        "A pending revision is not the manifest head."
                    )
                }
                let recoveredRevision = try loadRevision(
                    projectID: projectID,
                    revisionID: pending.revisionID,
                    from: finalRevisionURL,
                    root: root,
                    projectSchemaVersion: projectSchemaVersion
                )
                if let expectedCompatibility = pending.evidenceCompatibility,
                   recoveredRevision.manifest.evidenceCompatibility != expectedCompatibility {
                    throw RoomProjectStoreError.invalidPackage(
                        "Pending revision evidence compatibility does not match its immutable manifest."
                    )
                }
                // A manifest write may have completed before interruption. Rewrite
                // the marker's complete intended manifest, then clear the marker.
                try writeJSON(pending.updatedManifest, to: manifestURL, root: root)
                try removeOwnedStagingIfPresent(
                    stagingURL,
                    ownership: expectedOwnership,
                    root: root
                )
                try removePendingMarker(markerURL, root: root)
                return
            }

            guard currentManifest.headRevisionID == pending.previousHeadRevisionID else {
                throw RoomProjectStoreError.invalidPackage(
                    "Pending rollback would overwrite a different manifest head."
                )
            }
            // Only the marker-owned promoted directory can be removed.
            try fileManager.removeItem(at: finalRevisionURL)
            try removeOwnedStagingIfPresent(
                stagingURL,
                ownership: expectedOwnership,
                root: root
            )
            try removePendingMarker(markerURL, root: root)
            return
        }

        // Before promotion, a staged directory is removable only when its own
        // ownership file matches the marker. An absent stage needs no cleanup.
        try removeOwnedStagingIfPresent(
            stagingURL,
            ownership: expectedOwnership,
            root: root
        )
        try removePendingMarker(markerURL, root: root)
    }

    private func loadProjectPackageLocked(
        root: URL,
        projectID: String,
        projectURL: URL? = nil
    ) throws -> RoomProjectPackage {
        let resolvedProjectURL: URL
        if let projectURL {
            resolvedProjectURL = projectURL
        } else {
            resolvedProjectURL = try self.projectDirectory(
                root: root,
                projectID: projectID
            )
        }
        try assertNoSymbolicLinks(root: root, through: resolvedProjectURL)
        guard directoryExists(resolvedProjectURL) else {
            throw RoomProjectStoreError.projectNotFound(projectID)
        }

        let manifest = try readJSON(
            RoomProjectManifest.self,
            from: resolvedProjectURL.appendingPathComponent("manifest.json"),
            root: root
        )
        let metadata = try readJSON(
            RoomMetadata.self,
            from: resolvedProjectURL.appendingPathComponent("metadata.json"),
            root: root
        )
        try validate(manifest: manifest, expectedProjectID: projectID)
        let projectSchemaVersion = try validatedProjectSchemaVersion(manifest)

        var revisions: [RoomRevisionPackage] = []
        for revisionID in manifest.revisionIDs {
            try validateIdentifier(revisionID)
            let revisionURL = resolvedProjectURL
                .appendingPathComponent("revisions", isDirectory: true)
                .appendingPathComponent(revisionID, isDirectory: true)
            revisions.append(
                try loadRevision(
                    projectID: projectID,
                    revisionID: revisionID,
                    from: revisionURL,
                    root: root,
                    projectSchemaVersion: projectSchemaVersion
                )
            )
        }

        let package = RoomProjectPackage(
            manifest: manifest,
            metadata: metadata,
            revisions: revisions
        )
        try validate(package: package, expectedProjectID: projectID)
        try validateProjectAssetReference(
            metadata: metadata,
            projectURL: resolvedProjectURL,
            root: root
        )
        try validateProjectAssetPolicyReferences(
            manifest.assetPolicy,
            projectURL: resolvedProjectURL,
            root: root
        )
        return package
    }

    private func loadRevision(
        projectID: String,
        revisionID: String,
        from revisionURL: URL,
        root: URL,
        projectSchemaVersion: RoomProjectSchemaVersion
    ) throws -> RoomRevisionPackage {
        try assertNoSymbolicLinks(root: root, through: revisionURL)
        guard directoryExists(revisionURL) else {
            throw RoomProjectStoreError.revisionNotFound(
                projectID: projectID,
                revisionID: revisionID
            )
        }

        let manifest = try readJSON(
            RoomRevisionManifest.self,
            from: revisionURL.appendingPathComponent("revision.json"),
            root: root
        )
        let semanticSnapshot = try readJSON(
            RoomSemanticSnapshot.self,
            from: revisionURL.appendingPathComponent("semantic-model.json"),
            root: root
        )
        let annotationsDocument = try readJSON(
            RoomAnnotationsDocument.self,
            from: revisionURL.appendingPathComponent("annotations.json"),
            root: root
        )
        let measurementsDocument = try readJSON(
            RoomMeasurementsDocument.self,
            from: revisionURL.appendingPathComponent("measurements.json"),
            root: root
        )
        let photosDocument = try readJSON(
            RoomPhotosDocument.self,
            from: revisionURL.appendingPathComponent("photos.json"),
            root: root
        )

        guard
            annotationsDocument.projectID == projectID,
            annotationsDocument.revisionID == revisionID,
            measurementsDocument.projectID == projectID,
            measurementsDocument.revisionID == revisionID,
            photosDocument.projectID == projectID,
            photosDocument.revisionID == revisionID
        else {
            throw RoomProjectStoreError.invalidPackage("Revision document identifiers do not match.")
        }

        let revision = RoomRevisionPackage(
            manifest: manifest,
            payload: RoomRevisionPayload(
                semanticSnapshot: semanticSnapshot,
                annotations: annotationsDocument.annotations,
                measurements: measurementsDocument.measurements,
                photos: photosDocument.photos
            )
        )
        try validate(
            revision: revision,
            expectedProjectID: projectID,
            expectedRevisionID: revisionID,
            projectSchemaVersion: projectSchemaVersion
        )
        try validateRevisionAssetReferences(
            revision.payload,
            revisionURL: revisionURL,
            root: root
        )
        try validateRevisionEvidence(
            revision.manifest.captureEvidence,
            revisionURL: revisionURL,
            root: root,
            evidenceCompatibility: try validatedEvidenceCompatibility(
                revision.manifest,
                projectSchemaVersion: projectSchemaVersion
            )
        )
        return revision
    }

    private func writeRevision(
        _ revision: RoomRevisionPackage,
        to revisionURL: URL,
        ownership: RoomRevisionOwnershipRecord,
        root: URL
    ) throws {
        try assertNoSymbolicLinks(root: root, through: revisionURL)
        guard !pathExists(revisionURL) else {
            throw RoomProjectStoreError.revisionAlreadyExists(revision.manifest.revisionID)
        }

        do {
            try fileManager.createDirectory(at: revisionURL, withIntermediateDirectories: true)
            try writeJSON(
                revision.manifest,
                to: revisionURL.appendingPathComponent("revision.json"),
                root: root
            )
            try writeJSON(
                revision.payload.semanticSnapshot,
                to: revisionURL.appendingPathComponent("semantic-model.json"),
                root: root
            )
            try writeJSON(
                RoomAnnotationsDocument(
                    projectID: revision.manifest.projectID,
                    revisionID: revision.manifest.revisionID,
                    annotations: revision.payload.annotations
                ),
                to: revisionURL.appendingPathComponent("annotations.json"),
                root: root
            )
            try writeJSON(
                RoomMeasurementsDocument(
                    projectID: revision.manifest.projectID,
                    revisionID: revision.manifest.revisionID,
                    accuracyDisclaimer: revision.payload.semanticSnapshot.accuracyDisclaimer,
                    measurements: revision.payload.measurements
                ),
                to: revisionURL.appendingPathComponent("measurements.json"),
                root: root
            )
            try writeJSON(
                RoomPhotosDocument(
                    projectID: revision.manifest.projectID,
                    revisionID: revision.manifest.revisionID,
                    photos: revision.payload.photos
                ),
                to: revisionURL.appendingPathComponent("photos.json"),
                root: root
            )
            try writeJSON(
                ownership,
                to: revisionURL.appendingPathComponent(".roomscan-ownership.json"),
                root: root
            )
        } catch let error as RoomProjectStoreError {
            throw error
        } catch {
            throw RoomProjectStoreError.storageFailure("Unable to write staged room revision.")
        }
    }

    private func copyAssets(
        _ assets: [RoomAssetInput],
        projectRoot: URL,
        revisionRoot: URL,
        allowedScopes: Set<RoomAssetScope>,
        root: URL
    ) throws {
        var destinations = Set<String>()
        for asset in assets {
            guard allowedScopes.contains(asset.scope) else {
                throw RoomProjectStoreError.invalidRelativePath(asset.destination.value)
            }
            try validate(asset: asset)
            let destinationKey = "\(asset.scope.rawValue):\(asset.destination.value)"
            guard destinations.insert(destinationKey).inserted else {
                throw RoomProjectStoreError.duplicateAssetDestination(asset.destination.value)
            }

            let destinationRoot: URL
            switch asset.scope {
            case .project:
                destinationRoot = projectRoot
            case .revision:
                destinationRoot = revisionRoot
            }
            let destinationURL = destinationRoot.appendingPathComponent(
                asset.destination.value,
                isDirectory: false
            )
            try assertNoSymbolicLinks(root: root, through: destinationURL)
            guard !pathExists(destinationURL) else {
                throw RoomProjectStoreError.duplicateAssetDestination(asset.destination.value)
            }

            let parentURL = destinationURL.deletingLastPathComponent()
            try assertNoSymbolicLinks(root: root, through: parentURL)
            do {
                try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
                try assertNoSymbolicLinks(root: root, through: destinationURL)
                try fileManager.copyItem(at: asset.sourceURL, to: destinationURL)
            } catch let error as RoomProjectStoreError {
                throw error
            } catch {
                throw RoomProjectStoreError.storageFailure("Unable to copy a staged room asset.")
            }
            guard try isRegularFile(destinationURL) else {
                throw RoomProjectStoreError.invalidAssetSource(asset.sourceURL.path)
            }
        }
    }

    private func validate(asset: RoomAssetInput) throws {
        guard RoomPathValidation.isSafeRelativePath(asset.destination.value) else {
            throw RoomProjectStoreError.invalidRelativePath(asset.destination.value)
        }
        switch asset.scope {
        case .project:
            guard asset.destination.value.hasPrefix("thumbnails/") else {
                throw RoomProjectStoreError.invalidRelativePath(asset.destination.value)
            }
        case .revision:
            // Evidence may gain new kinds (native USD/USDZ, raw mesh, or world
            // data) without changing this Foundation store. Canonical documents
            // are generated by writeRevision and may never be asset destinations.
            guard !Self.canonicalRevisionDocumentPaths.contains(asset.destination.value) else {
                throw RoomProjectStoreError.invalidRelativePath(asset.destination.value)
            }
        }

        guard
            asset.sourceURL.isFileURL,
            !isSymbolicLink(asset.sourceURL),
            try isRegularFile(asset.sourceURL)
        else {
            throw RoomProjectStoreError.invalidAssetSource(asset.sourceURL.path)
        }
    }

    /// An initial capture may copy only from caller-owned scratch locations,
    /// never from a final package path under this store root. This keeps the
    /// initial transaction's trust boundary distinct from restore/duplicate.
    private func validateInitialCaptureScratchAssets(
        _ assets: [RoomAssetInput],
        root: URL
    ) throws {
        for asset in assets {
            let resolvedSource = asset.sourceURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard !isContained(resolvedSource, within: root) else {
                throw RoomProjectStoreError.invalidAssetSource(asset.sourceURL.path)
            }
        }
    }

    /// `evidence/` is reserved for a declared, digest-checked Phase-2 plan.
    /// Public initial/append writes always pass `.strict`; only an internal
    /// copy from a previously loaded historical-v1 evidence revision can pass
    /// `.legacyV1Planless`.
    private func validateEvidenceAssetInputs(
        _ assets: [RoomAssetInput],
        captureEvidence: RoomRevisionEvidencePlan?,
        evidenceCompatibility: RoomRevisionEvidenceCompatibility
    ) throws {
        for asset in assets where asset.scope == .revision {
            let path = asset.destination.value
            let isEvidenceNamespace = asset.destination.value.lowercased() == "evidence"
                || asset.destination.value.lowercased().hasPrefix("evidence/")
            guard isEvidenceNamespace else {
                continue
            }

            // Apple filesystems commonly use case-insensitive volumes. A
            // case-aliased sibling would bypass the canonical evidence closure
            // on a case-sensitive host and collide with it on a default Apple
            // host, so new inputs must spell the namespace exactly.
            guard path.hasPrefix("evidence/") else {
                throw RoomProjectStoreError.invalidEvidencePlan(
                    "Revision evidence must use the canonical lowercase evidence/ namespace."
                )
            }
            guard captureEvidence != nil || evidenceCompatibility == .legacyV1Planless else {
                throw RoomProjectStoreError.invalidEvidencePlan(
                    "New evidence assets require a capture evidence plan."
                )
            }
        }
    }

    private func validateProjectAssetReference(
        metadata: RoomMetadata,
        projectURL: URL,
        root: URL
    ) throws {
        guard let thumbnail = metadata.thumbnailRelativePath else {
            return
        }
        guard thumbnail.value.hasPrefix("thumbnails/") else {
            throw RoomProjectStoreError.invalidRelativePath(thumbnail.value)
        }
        let thumbnailURL = projectURL.appendingPathComponent(thumbnail.value)
        try assertNoSymbolicLinks(root: root, through: thumbnailURL)
        guard try isRegularFile(thumbnailURL) else {
            throw RoomProjectStoreError.assetReferenceNotStaged(thumbnail.value)
        }
    }

    private func validateProjectAssetPolicyReferences(
        _ policy: RoomAssetPolicy?,
        projectURL: URL,
        root: URL
    ) throws {
        guard let policy else {
            return
        }
        for reference in [policy.nativeUSDZ, policy.rawMesh, policy.worldMap] {
            guard let reference else {
                continue
            }
            let path = reference.value
            guard RoomPathValidation.isSafeRelativePath(path) else {
                throw RoomProjectStoreError.invalidRelativePath(path)
            }
            let assetURL = projectURL.appendingPathComponent(path)
            try assertNoSymbolicLinks(root: root, through: assetURL)
            guard try isRegularFile(assetURL) else {
                throw RoomProjectStoreError.assetReferenceNotStaged(path)
            }
        }
    }

    private func validateRevisionAssetReferences(
        _ payload: RoomRevisionPayload,
        revisionURL: URL,
        root: URL
    ) throws {
        for photo in payload.photos {
            let path = photo.assetRelativePath.value
            guard path.hasPrefix("photos/") else {
                throw RoomProjectStoreError.invalidRelativePath(path)
            }
            let photoURL = revisionURL.appendingPathComponent(path)
            try assertNoSymbolicLinks(root: root, through: photoURL)
            guard try isRegularFile(photoURL) else {
                throw RoomProjectStoreError.assetReferenceNotStaged(path)
            }
        }
    }

    /// Evidence is revision-relative and immutable. This check is deliberately
    /// separate from the generated canonical JSON document checks above.
    private func validateRevisionEvidence(
        _ evidence: RoomRevisionEvidencePlan?,
        revisionURL: URL,
        root: URL,
        evidenceCompatibility: RoomRevisionEvidenceCompatibility
    ) throws {
        try validateCanonicalEvidenceNamespace(revisionURL: revisionURL, root: root)
        guard let evidence else {
            let evidenceURL = revisionURL.appendingPathComponent("evidence", isDirectory: true)
            try assertNoSymbolicLinks(root: root, through: evidenceURL)
            guard pathExists(evidenceURL) else {
                return
            }
            guard evidenceCompatibility == .legacyV1Planless else {
                throw RoomProjectStoreError.invalidEvidencePlan(
                    "Strict revisions require a capture evidence plan for evidence files."
                )
            }
            guard directoryExists(evidenceURL) else {
                throw RoomProjectStoreError.invalidEvidencePlan(
                    "Legacy revision evidence must be a directory."
                )
            }
            // Historical v1 files have no declared byte count or digest.
            // Preserve them only after link-free regular-file traversal;
            // callers cannot create this form through a public new-write API.
            _ = try regularRevisionAssets(
                in: evidenceURL,
                relativeDirectory: "evidence",
                root: root
            )
            return
        }
        try validate(evidencePlan: evidence)
        for artifact in evidence.artifacts where artifact.status == .present {
            guard
                let relativePath = artifact.relativePath,
                let declaredByteCount = artifact.byteCount,
                let declaredDigest = artifact.sha256Hex
            else {
                throw RoomProjectStoreError.invalidEvidencePlan(
                    "A present evidence artifact is incomplete."
                )
            }
            let artifactURL = revisionURL.appendingPathComponent(relativePath.value)
            try assertNoSymbolicLinks(root: root, through: artifactURL)
            guard try isRegularFile(artifactURL) else {
                throw RoomProjectStoreError.assetReferenceNotStaged(relativePath.value)
            }
            let actualByteCount = try fileByteCount(of: artifactURL)
            guard actualByteCount == declaredByteCount else {
                throw RoomProjectStoreError.assetReferenceNotStaged(relativePath.value)
            }
            guard try RoomSHA256.hexDigest(ofFile: artifactURL) == declaredDigest else {
                throw RoomProjectStoreError.assetReferenceNotStaged(relativePath.value)
            }
        }
        try validateEvidenceDirectoryClosure(evidence, revisionURL: revisionURL, root: root)
    }

    /// Selects the only compatibility mode an internal duplicate/restore may
    /// persist. The source package was already loaded and validated under its
    /// own project schema before this helper sees its regular revision assets.
    private func internalCopyEvidenceCompatibility(
        sourceProjectManifest: RoomProjectManifest,
        sourceRevisionManifest: RoomRevisionManifest,
        copiedRevisionAssets: [RoomAssetInput]
    ) throws -> RoomRevisionEvidenceCompatibility {
        guard sourceRevisionManifest.captureEvidence == nil else {
            return .strict
        }
        let sourceSchemaVersion = try validatedProjectSchemaVersion(
            sourceProjectManifest
        )
        let sourceCompatibility = try validatedEvidenceCompatibility(
            sourceRevisionManifest,
            projectSchemaVersion: sourceSchemaVersion
        )
        let hasCopiedEvidence = copiedRevisionAssets.contains { asset in
            asset.scope == .revision && asset.destination.value.hasPrefix("evidence/")
        }
        guard hasCopiedEvidence else {
            return .strict
        }
        guard sourceCompatibility == .legacyV1Planless else {
            throw RoomProjectStoreError.invalidEvidencePlan(
                "Only validated historical-v1 evidence may be copied without a plan."
            )
        }
        return .legacyV1Planless
    }

    /// Detect case-aliased `Evidence` siblings before looking up the canonical
    /// lowercase directory. This is a load-time trust boundary as external
    /// tampering on a case-sensitive filesystem could otherwise evade the
    /// declared evidence closure.
    private func validateCanonicalEvidenceNamespace(
        revisionURL: URL,
        root: URL
    ) throws {
        try assertNoSymbolicLinks(root: root, through: revisionURL)
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: revisionURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
        } catch {
            throw RoomProjectStoreError.storageFailure(
                "Unable to enumerate a revision evidence namespace."
            )
        }

        for child in children {
            let name = child.lastPathComponent
            guard name.lowercased() == "evidence", name != "evidence" else {
                continue
            }
            try assertNoSymbolicLinks(root: root, through: child)
            throw RoomProjectStoreError.invalidEvidencePlan(
                "Revision evidence must use the canonical lowercase evidence/ namespace."
            )
        }
    }

    /// An evidence plan is closed over its revision directory: every regular
    /// file below `evidence/` is declared exactly once, and no declared path is
    /// allowed to alias another artifact.
    private func validateEvidenceDirectoryClosure(
        _ evidence: RoomRevisionEvidencePlan,
        revisionURL: URL,
        root: URL
    ) throws {
        let declaredPaths = Set(
            evidence.artifacts.compactMap { artifact in
                artifact.status == .present ? artifact.relativePath?.value : nil
            }
        )
        let evidenceURL = revisionURL.appendingPathComponent("evidence", isDirectory: true)
        try assertNoSymbolicLinks(root: root, through: evidenceURL)
        guard pathExists(evidenceURL) else {
            guard declaredPaths.isEmpty else {
                throw RoomProjectStoreError.assetReferenceNotStaged("evidence")
            }
            return
        }
        guard directoryExists(evidenceURL) else {
            throw RoomProjectStoreError.invalidEvidencePlan(
                "The evidence path must be a directory."
            )
        }

        let discoveredPaths = Set(
            try regularRevisionAssets(
                in: evidenceURL,
                relativeDirectory: "evidence",
                root: root
            ).map { $0.1 }
        )
        guard discoveredPaths == declaredPaths else {
            throw RoomProjectStoreError.invalidEvidencePlan(
                "Revision evidence files must match the declared evidence plan exactly."
            )
        }
    }

    private func restoredRevisionAssets(
        from sourceRevisionURL: URL,
        root: URL
    ) throws -> [RoomAssetInput] {
        let assets = try regularRevisionAssets(
            in: sourceRevisionURL,
            relativeDirectory: "",
            root: root
        )
        return try assets.map { asset in
            RoomAssetInput(
                sourceURL: asset.0,
                destination: try RoomRelativePath(asset.1),
                scope: .revision
            )
        }
    }

    /// A fixture rescan retains only the source revision's declared reference
    /// photos. It does not copy arbitrary evidence, derived exports, or mesh
    /// files into deterministic-fixture evidence.
    private func rescanPhotoAssets(
        from payload: RoomRevisionPayload,
        sourceRevisionURL: URL,
        root: URL
    ) throws -> [RoomAssetInput] {
        try assertNoSymbolicLinks(root: root, through: sourceRevisionURL)
        var copiedPaths = Set<String>()
        var assets: [RoomAssetInput] = []
        for photo in payload.photos {
            let relativePath = photo.assetRelativePath
            guard copiedPaths.insert(relativePath.value).inserted else {
                continue
            }
            guard relativePath.value.hasPrefix("photos/") else {
                throw RoomProjectStoreError.invalidRelativePath(relativePath.value)
            }
            let sourceURL = sourceRevisionURL.appendingPathComponent(relativePath.value)
            try assertNoSymbolicLinks(root: root, through: sourceURL)
            guard try isRegularFile(sourceURL) else {
                throw RoomProjectStoreError.assetReferenceNotStaged(relativePath.value)
            }
            assets.append(
                RoomAssetInput(
                    sourceURL: sourceURL,
                    destination: relativePath,
                    scope: .revision
                )
            )
        }
        return assets
    }

    private func regularRevisionAssets(
        in directory: URL,
        relativeDirectory: String,
        root: URL
    ) throws -> [(URL, String)] {
        try assertNoSymbolicLinks(root: root, through: directory)
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
        } catch {
            throw RoomProjectStoreError.storageFailure(
                "Unable to enumerate revision evidence for restore."
            )
        }

        var result: [(URL, String)] = []
        for child in children {
            let name = child.lastPathComponent
            let relativePath = relativeDirectory.isEmpty
                ? name
                : "\(relativeDirectory)/\(name)"
            guard RoomPathValidation.isSafeRelativePath(relativePath) else {
                throw RoomProjectStoreError.invalidRelativePath(relativePath)
            }
            try assertNoSymbolicLinks(root: root, through: child)

            if directoryExists(child) {
                let nested = try regularRevisionAssets(
                    in: child,
                    relativeDirectory: relativePath,
                    root: root
                )
                result.append(contentsOf: nested)
                continue
            }
            guard try isRegularFile(child) else {
                throw RoomProjectStoreError.invalidPackage(
                    "Revision evidence is not a regular file."
                )
            }
            if relativeDirectory.isEmpty,
               Self.canonicalRevisionDocumentPaths.contains(relativePath) {
                continue
            }
            result.append((child, relativePath))
        }
        return result
    }

    private func revisionDirectory(
        _ revisionURL: URL,
        hasOwnership ownership: RoomRevisionOwnershipRecord,
        root: URL
    ) throws -> Bool {
        try assertNoSymbolicLinks(root: root, through: revisionURL)
        guard directoryExists(revisionURL) else {
            return false
        }
        let ownershipURL = revisionURL.appendingPathComponent(".roomscan-ownership.json")
        guard pathExists(ownershipURL) else {
            return false
        }
        let stored = try readJSON(
            RoomRevisionOwnershipRecord.self,
            from: ownershipURL,
            root: root
        )
        return stored == ownership
    }

    private func removeInitialStagingIfPresent(_ stagingURL: URL, root: URL) throws {
        try assertNoSymbolicLinks(root: root, through: stagingURL)
        guard pathExists(stagingURL) else {
            return
        }
        guard stagingURL.lastPathComponent.hasPrefix(".staging-") else {
            throw RoomProjectStoreError.invalidPackage("Unsafe initial staging directory.")
        }
        try fileManager.removeItem(at: stagingURL)
    }

    private func removeOwnedStagingIfPresent(
        _ stagingURL: URL,
        ownership: RoomRevisionOwnershipRecord,
        root: URL
    ) throws {
        try assertNoSymbolicLinks(root: root, through: stagingURL)
        guard pathExists(stagingURL) else {
            return
        }
        guard stagingURL.lastPathComponent.hasPrefix(".staging-") else {
            throw RoomProjectStoreError.invalidPackage("Unsafe revision staging directory.")
        }
        guard try revisionDirectory(stagingURL, hasOwnership: ownership, root: root) else {
            throw RoomProjectStoreError.invalidPackage(
                "Pending marker does not own its staged revision."
            )
        }
        try fileManager.removeItem(at: stagingURL)
    }

    private func removePendingMarker(_ markerURL: URL, root: URL) throws {
        try assertNoSymbolicLinks(root: root, through: markerURL)
        guard pathExists(markerURL) else {
            return
        }
        try fileManager.removeItem(at: markerURL)
    }

    private func makeUniqueStagingURL(
        parent: URL,
        prefix: String,
        root: URL
    ) throws -> URL {
        for _ in 0..<16 {
            let candidate = parent.appendingPathComponent(
                "\(prefix)\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
            try assertNoSymbolicLinks(root: root, through: candidate)
            if !pathExists(candidate) {
                return candidate
            }
        }
        throw RoomProjectStoreError.storageFailure("Unable to reserve a staging directory.")
    }

    private func readJSON<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        root: URL
    ) throws -> T {
        try assertNoSymbolicLinks(root: root, through: url)
        do {
            let data = try Data(contentsOf: url)
            return try RoomJSONCoding.makeDecoder().decode(T.self, from: data)
        } catch let error as RoomProjectStoreError {
            throw error
        } catch {
            throw RoomProjectStoreError.storageFailure(
                "Unable to read \(url.lastPathComponent)."
            )
        }
    }

    private func writeJSON<T: Encodable>(
        _ value: T,
        to url: URL,
        root: URL
    ) throws {
        try assertNoSymbolicLinks(root: root, through: url)
        do {
            let data = try RoomJSONCoding.makeEncoder().encode(value)
            try data.write(to: url, options: .atomic)
        } catch let error as RoomProjectStoreError {
            throw error
        } catch {
            throw RoomProjectStoreError.storageFailure(
                "Unable to write \(url.lastPathComponent)."
            )
        }
    }

    private func normalized(
        metadata: RoomMetadata,
        projectID: String,
        lastRevisedDate: Date
    ) throws -> RoomMetadata {
        var normalized = metadata
        normalized.projectID = projectID
        normalized.lastRevisedDate = lastRevisedDate
        try validate(metadata: normalized)
        return normalized
    }

    private func normalized(
        payload: RoomRevisionPayload,
        projectID: String,
        revisionID: String
    ) throws -> RoomRevisionPayload {
        var normalized = payload
        normalized.semanticSnapshot.projectID = projectID
        normalized.semanticSnapshot.revisionID = revisionID
        try validate(payload: normalized, projectID: projectID, revisionID: revisionID)
        return normalized
    }

    private func validate(package: RoomProjectPackage, expectedProjectID: String) throws {
        try validate(manifest: package.manifest, expectedProjectID: expectedProjectID)
        let projectSchemaVersion = try validatedProjectSchemaVersion(
            package.manifest
        )
        guard
            package.metadata.projectID == expectedProjectID,
            package.manifest.revisionIDs.count == package.revisions.count
        else {
            throw RoomProjectStoreError.invalidPackage("Project package manifest is inconsistent.")
        }

        var seenRevisionIDs = Set<String>()
        for (index, revision) in package.revisions.enumerated() {
            let expectedRevisionID = package.manifest.revisionIDs[index]
            guard seenRevisionIDs.insert(expectedRevisionID).inserted else {
                throw RoomProjectStoreError.duplicateRevisionID(expectedRevisionID)
            }
            try validate(
                revision: revision,
                expectedProjectID: expectedProjectID,
                expectedRevisionID: expectedRevisionID,
                projectSchemaVersion: projectSchemaVersion
            )
            try validateStoredRevisionReason(
                revision.manifest,
                index: index,
                revisionIDs: package.manifest.revisionIDs
            )
            let expectedParent = index == 0
                ? nil
                : package.manifest.revisionIDs[index - 1]
            guard revision.manifest.parentRevisionID == expectedParent else {
                throw RoomProjectStoreError.parentDoesNotMatchHead(
                    projectID: expectedProjectID,
                    expected: expectedParent ?? "none",
                    actual: revision.manifest.parentRevisionID
                )
            }
        }

        try validate(metadata: package.metadata)
    }

    private func validate(
        manifest: RoomProjectManifest,
        expectedProjectID: String
    ) throws {
        guard
            manifest.projectID == expectedProjectID,
            !manifest.revisionIDs.isEmpty,
            manifest.headRevisionID == manifest.revisionIDs.last
        else {
            throw RoomProjectStoreError.invalidPackage("Project package manifest is inconsistent.")
        }
        _ = try validatedProjectSchemaVersion(manifest)
        try validateIdentifier(expectedProjectID)
        try validateIdentifier(manifest.headRevisionID)
        var seen = Set<String>()
        for revisionID in manifest.revisionIDs {
            try validateIdentifier(revisionID)
            guard seen.insert(revisionID).inserted else {
                throw RoomProjectStoreError.duplicateRevisionID(revisionID)
            }
        }
        if let policy = manifest.assetPolicy {
            for path in [policy.nativeUSDZ, policy.rawMesh, policy.worldMap] {
                if let path, !RoomPathValidation.isSafeRelativePath(path.value) {
                    throw RoomProjectStoreError.invalidRelativePath(path.value)
                }
            }
        }
    }

    private func validate(
        revision: RoomRevisionPackage,
        expectedProjectID: String,
        expectedRevisionID: String,
        projectSchemaVersion: RoomProjectSchemaVersion
    ) throws {
        guard
            revision.manifest.projectID == expectedProjectID,
            revision.manifest.revisionID == expectedRevisionID,
            revision.manifest.immutable
        else {
            throw RoomProjectStoreError.invalidPackage("Revision manifest is inconsistent.")
        }
        try validateIdentifier(expectedProjectID)
        try validateIdentifier(expectedRevisionID)
        if let parentRevisionID = revision.manifest.parentRevisionID {
            try validateIdentifier(parentRevisionID)
        }
        if let restoredFromRevisionID = revision.manifest.restoredFromRevisionID {
            try validateIdentifier(restoredFromRevisionID)
        }
        if let captureEvidence = revision.manifest.captureEvidence {
            try validate(evidencePlan: captureEvidence)
        }
        if let qualityReport = revision.manifest.qualityReport {
            let evidenceEpoch = revision.manifest.captureEvidence?.coordinateSpaceEpochID
            let provenanceEpochs = Set(
                (revision.payload.semanticSnapshot.structuralElements + revision.payload.semanticSnapshot.objectElements)
                    .compactMap { $0.provenance?.coordinateSpaceEpochID }
                    .filter { !$0.isEmpty }
            )
            guard provenanceEpochs.count <= 1 else {
                throw RoomProjectStoreError.invalidPackage(
                    "A revision cannot bind quality across inconsistent semantic coordinate-space epochs."
                )
            }
            let expectedEpoch = evidenceEpoch ?? provenanceEpochs.first ?? qualityReport.coordinateSpaceEpochID
            do {
                try qualityReport.validate(
                    expectedProjectID: expectedProjectID,
                    expectedRevisionID: expectedRevisionID,
                    expectedCoordinateSpaceEpochID: expectedEpoch
                )
            } catch {
                throw RoomProjectStoreError.invalidPackage(
                    "Revision quality report is malformed or rebound."
                )
            }
        }
        _ = try validatedEvidenceCompatibility(
            revision.manifest,
            projectSchemaVersion: projectSchemaVersion
        )
        try validate(
            payload: revision.payload,
            projectID: expectedProjectID,
            revisionID: expectedRevisionID
        )
        try validateRoomPlanProvenance(
            revision.payload,
            evidence: revision.manifest.captureEvidence
        )
        try validateFixtureRescanProvenance(
            revision.payload,
            manifest: revision.manifest
        )
    }

    private func validatedProjectSchemaVersion(
        _ manifest: RoomProjectManifest
    ) throws -> RoomProjectSchemaVersion {
        guard let schemaVersion = RoomProjectSchemaVersion(
            rawValue: manifest.schemaVersion
        ) else {
            throw RoomProjectStoreError.invalidPackage(
                "Unsupported room package schema version."
            )
        }
        return schemaVersion
    }

    /// Missing revision compatibility is readable only from a historical v1
    /// manifest. New v2 revisions must write `.strict` or an explicit
    /// internally-created `.legacyV1Planless` copy mode.
    private func validatedEvidenceCompatibility(
        _ revisionManifest: RoomRevisionManifest,
        projectSchemaVersion: RoomProjectSchemaVersion
    ) throws -> RoomRevisionEvidenceCompatibility {
        guard let compatibility = revisionManifest.evidenceCompatibility else {
            guard projectSchemaVersion == .v1 else {
                throw RoomProjectStoreError.invalidEvidencePlan(
                    "A v2 revision must declare its evidence compatibility mode."
                )
            }
            return revisionManifest.captureEvidence == nil
                ? .legacyV1Planless
                : .strict
        }

        switch compatibility {
        case .strict:
            return .strict
        case .legacyV1Planless:
            guard revisionManifest.captureEvidence == nil else {
                throw RoomProjectStoreError.invalidEvidencePlan(
                    "Legacy plan-less compatibility cannot carry a capture evidence plan."
                )
            }
            guard
                revisionManifest.reason == .duplicate
                    || revisionManifest.reason == .revert
                    || revisionManifest.reason == .edit
            else {
                throw RoomProjectStoreError.invalidEvidencePlan(
                    "Legacy plan-less compatibility is reserved for an internal duplicate, restore, or optimistic edit copy."
                )
            }
            return .legacyV1Planless
        }
    }

    private func validate(evidencePlan: RoomRevisionEvidencePlan) throws {
        let expectedKinds = Set(RoomEvidenceArtifactKind.allCases)
        var seenKinds = Set<RoomEvidenceArtifactKind>()
        var seenPresentPaths = Set<String>()
        for artifact in evidencePlan.artifacts {
            guard seenKinds.insert(artifact.kind).inserted else {
                throw RoomProjectStoreError.invalidEvidencePlan(
                    "Evidence artifact kinds must be unique."
                )
            }

            switch artifact.status {
            case .present:
                guard
                    let relativePath = artifact.relativePath,
                    relativePath.value.hasPrefix("evidence/"),
                    artifact.byteCount != nil,
                    (artifact.byteCount ?? 0) > 0,
                    let mediaType = artifact.mediaType,
                    !mediaType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    artifact.omissionReason == nil,
                    let sha256Hex = artifact.sha256Hex,
                    isValidSHA256Hex(sha256Hex),
                    seenPresentPaths.insert(relativePath.value.lowercased()).inserted
                else {
                    throw RoomProjectStoreError.invalidEvidencePlan(
                        "Present evidence must declare one evidence-relative path, positive byte count, media type, and SHA-256 digest."
                    )
                }
            case .unavailable, .notRequested:
                guard
                    artifact.relativePath == nil,
                    artifact.byteCount == nil,
                    artifact.mediaType == nil,
                    artifact.sha256Hex == nil,
                    let omissionReason = artifact.omissionReason,
                    !omissionReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    throw RoomProjectStoreError.invalidEvidencePlan(
                        "Unavailable evidence must omit file data and explain the omission."
                    )
                }
            }
        }

        guard seenKinds == expectedKinds else {
            throw RoomProjectStoreError.invalidEvidencePlan(
                "Every known evidence artifact kind requires an explicit status."
            )
        }

        let hasCaptureAttemptID = evidencePlan.captureAttemptID != nil
        let hasCoordinateSpaceEpochID = evidencePlan.coordinateSpaceEpochID != nil
        guard hasCaptureAttemptID == hasCoordinateSpaceEpochID else {
            throw RoomProjectStoreError.invalidEvidencePlan(
                "Capture attempt and coordinate-space epoch provenance must be supplied together."
            )
        }
        if let captureAttemptID = evidencePlan.captureAttemptID {
            try validateIdentifier(captureAttemptID)
        }
        if let coordinateSpaceEpochID = evidencePlan.coordinateSpaceEpochID {
            try validateIdentifier(coordinateSpaceEpochID)
        }

        switch evidencePlan.source {
        case .roomPlan:
            guard
                evidencePlan.captureAttemptID != nil,
                evidencePlan.coordinateSpaceEpochID != nil
            else {
                throw RoomProjectStoreError.invalidEvidencePlan(
                    "RoomPlan evidence requires capture-attempt and coordinate-space epoch provenance."
                )
            }
            let requiredPaths: [(RoomEvidenceArtifactKind, String)] = [
                (.capturedRoomJSON, "evidence/roomplan/captured-room.json"),
                (.nativeUSDZ, "evidence/native/RoomScan.usdz"),
            ]
            for (kind, expectedPath) in requiredPaths {
                guard
                    let artifact = evidencePlan.artifacts.first(where: { $0.kind == kind }),
                    artifact.status == .present,
                    artifact.relativePath?.value == expectedPath
                else {
                    throw RoomProjectStoreError.invalidEvidencePlan(
                        "RoomPlan evidence requires \(expectedPath)."
                    )
                }
            }
            // Raw CapturedRoomData is archival-only and Apple's Codable
            // implementation for it can refuse to serialize on device
            // ("Invalid data"). It may therefore be explicitly unavailable
            // with a reason; the reviewed capture record remains the
            // processed CapturedRoom JSON, the USDZ model, and the semantic
            // snapshot. The general artifact validation above already
            // enforces the reason for non-present statuses.
            guard
                let rawDataArtifact = evidencePlan.artifacts.first(
                    where: { $0.kind == .capturedRoomDataJSON }
                ),
                rawDataArtifact.status == .present
                    ? rawDataArtifact.relativePath?.value == "evidence/roomplan/captured-room-data.json"
                    : rawDataArtifact.status == .unavailable
            else {
                throw RoomProjectStoreError.invalidEvidencePlan(
                    "RoomPlan raw capture data must be present at evidence/roomplan/captured-room-data.json or explicitly unavailable with a reason."
                )
            }
        case .deterministicFixture:
            guard evidencePlan.artifacts.allSatisfy({ $0.status != .present }) else {
                throw RoomProjectStoreError.invalidEvidencePlan(
                    "A deterministic fixture must not claim Apple capture evidence."
                )
            }
        }
    }

    private func isValidSHA256Hex(_ value: String) -> Bool {
        guard value.count == 64 else {
            return false
        }
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdef")
        return value.unicodeScalars.allSatisfy(hexadecimal.contains)
    }

    private func validate(metadata: RoomMetadata) throws {
        try validateIdentifier(metadata.projectID)
        if let gps = metadata.optionalGPS {
            guard
                gps.latitude.isFinite,
                gps.longitude.isFinite,
                gps.horizontalAccuracyMeters.isFinite,
                (-90.0...90.0).contains(gps.latitude),
                (-180.0...180.0).contains(gps.longitude),
                gps.horizontalAccuracyMeters >= 0,
                gps.capturedAt.timeIntervalSinceReferenceDate.isFinite
            else {
                throw RoomProjectStoreError.invalidSpatialValue(
                    "GPS coordinates or horizontal accuracy are invalid."
                )
            }
        }
        if let thumbnail = metadata.thumbnailRelativePath {
            guard
                RoomPathValidation.isSafeRelativePath(thumbnail.value),
                thumbnail.value.hasPrefix("thumbnails/")
            else {
                throw RoomProjectStoreError.invalidRelativePath(thumbnail.value)
            }
        }
    }

    private func validate(
        payload: RoomRevisionPayload,
        projectID: String,
        revisionID: String
    ) throws {
        guard
            payload.semanticSnapshot.projectID == projectID,
            payload.semanticSnapshot.revisionID == revisionID,
            !payload.semanticSnapshot.accuracyDisclaimer.isEmpty
        else {
            throw RoomProjectStoreError.invalidPackage(
                "Semantic snapshot identifiers are inconsistent."
            )
        }

        var semanticElementIDs = Set<String>()
        for element in payload.semanticSnapshot.structuralElements {
            try validateSemanticElement(
                element,
                isStructuralElement: true,
                seenIDs: &semanticElementIDs
            )
        }
        for element in payload.semanticSnapshot.objectElements {
            try validateSemanticElement(
                element,
                isStructuralElement: false,
                seenIDs: &semanticElementIDs
            )
        }

        var annotationIDs = Set<String>()
        for annotation in payload.annotations {
            try validateIdentifier(annotation.id)
            guard annotationIDs.insert(annotation.id).inserted else {
                throw RoomProjectStoreError.duplicateAnnotationID(annotation.id)
            }
            if let point = annotation.point, !point.isFinite {
                throw RoomProjectStoreError.invalidSpatialValue(
                    "Annotation points must be finite."
                )
            }
            if let attachedElementID = annotation.attachedElementID {
                try validateIdentifier(attachedElementID)
                guard semanticElementIDs.contains(attachedElementID) else {
                    throw RoomProjectStoreError.invalidSpatialValue(
                        "Annotation attachments must reference a semantic element in the same revision."
                    )
                }
            }
        }

        var measurementIDs = Set<String>()
        for measurement in payload.measurements {
            try validateIdentifier(measurement.id)
            guard measurementIDs.insert(measurement.id).inserted else {
                throw RoomProjectStoreError.duplicateMeasurementID(measurement.id)
            }
            guard measurement.valueMeters.isFinite, measurement.valueMeters >= 0 else {
                throw RoomProjectStoreError.invalidSpatialValue(
                    "Measurements must be finite and nonnegative."
                )
            }
            let hasStartPoint = measurement.startPoint != nil
            guard hasStartPoint == (measurement.endPoint != nil) else {
                throw RoomProjectStoreError.invalidSpatialValue(
                    "Anchored measurements require both start and end points."
                )
            }
            if let startPoint = measurement.startPoint,
               let endPoint = measurement.endPoint {
                guard startPoint.isFinite, endPoint.isFinite else {
                    throw RoomProjectStoreError.invalidSpatialValue(
                        "Anchored measurement points must be finite."
                    )
                }
                let expectedDistance = spatialDistance(from: startPoint, to: endPoint)
                let tolerance = max(0.000_001, expectedDistance * 0.000_001)
                guard abs(measurement.valueMeters - expectedDistance) <= tolerance else {
                    throw RoomProjectStoreError.invalidSpatialValue(
                        "Anchored measurement value must match its point-to-point distance."
                    )
                }
            }
        }

        var photoIDs = Set<String>()
        for photo in payload.photos {
            try validateIdentifier(photo.id)
            guard photoIDs.insert(photo.id).inserted else {
                throw RoomProjectStoreError.duplicatePhotoID(photo.id)
            }
            guard
                RoomPathValidation.isSafeRelativePath(photo.assetRelativePath.value),
                photo.assetRelativePath.value.hasPrefix("photos/")
            else {
                throw RoomProjectStoreError.invalidRelativePath(photo.assetRelativePath.value)
            }
            if let cameraTransform = photo.cameraTransform, !cameraTransform.isValid {
                throw RoomProjectStoreError.invalidSpatialValue(
                    "Photo camera transform must contain 16 finite column-major values."
                )
            }
        }
    }

    private func spatialDistance(
        from start: RoomPoint3D,
        to end: RoomPoint3D
    ) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let dz = end.z - start.z
        return sqrt(dx * dx + dy * dy + dz * dz)
    }

    private func validateSemanticElement(
        _ element: RoomSemanticElement,
        isStructuralElement: Bool,
        seenIDs: inout Set<String>
    ) throws {
        try validateIdentifier(element.id)
        guard seenIDs.insert(element.id).inserted else {
            throw RoomProjectStoreError.duplicateSemanticElementID(element.id)
        }
        if isStructuralElement, element.mobility == .movable {
            throw RoomProjectStoreError.invalidSpatialValue(
                "A structural semantic element cannot be marked movable."
            )
        }
        if !isStructuralElement, element.mobility == .structural {
            throw RoomProjectStoreError.invalidSpatialValue(
                "A movable semantic element cannot be marked structural."
            )
        }
        let dimensions = [
            element.dimensionsMeters.width,
            element.dimensionsMeters.height,
            element.dimensionsMeters.depth,
        ]
        guard dimensions.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw RoomProjectStoreError.invalidSpatialValue(
                "Element dimensions must be finite and nonnegative."
            )
        }
        if isStructuralElement {
            guard dimensions.filter({ $0 > 0 }).count >= 2 else {
                throw RoomProjectStoreError.invalidSpatialValue(
                    "A structural surface requires at least two positive dimensions."
                )
            }
        } else {
            guard dimensions.allSatisfy({ $0 > 0 }) else {
                throw RoomProjectStoreError.invalidSpatialValue(
                    "An object requires three positive dimensions."
                )
            }
        }
        if let transform = element.transform, !transform.isValid {
            throw RoomProjectStoreError.invalidSpatialValue(
                "Element transform must contain 16 finite column-major values."
            )
        }
        if let polygonCorners = element.polygonCorners,
           !polygonCorners.allSatisfy({ $0.isFinite }) {
            throw RoomProjectStoreError.invalidSpatialValue(
                "Element polygon corners must be finite."
            )
        }
        if let provenance = element.provenance {
            let hasCaptureAttemptID = provenance.captureAttemptID != nil
            let hasCoordinateSpaceEpochID = provenance.coordinateSpaceEpochID != nil
            guard hasCaptureAttemptID == hasCoordinateSpaceEpochID else {
                throw RoomProjectStoreError.invalidPackage(
                    "Element capture attempt and coordinate-space epoch provenance must be supplied together."
                )
            }
            if let captureAttemptID = provenance.captureAttemptID {
                try validateIdentifier(captureAttemptID)
            }
            if let coordinateSpaceEpochID = provenance.coordinateSpaceEpochID {
                try validateIdentifier(coordinateSpaceEpochID)
            }
        }
    }

    private func validateRoomPlanProvenance(
        _ payload: RoomRevisionPayload,
        evidence: RoomRevisionEvidencePlan?
    ) throws {
        guard let evidence, evidence.source == .roomPlan else {
            return
        }
        guard
            let captureAttemptID = evidence.captureAttemptID,
            let coordinateSpaceEpochID = evidence.coordinateSpaceEpochID
        else {
            throw RoomProjectStoreError.invalidEvidencePlan(
                "RoomPlan evidence requires capture provenance."
            )
        }

        for element in payload.semanticSnapshot.structuralElements
            + payload.semanticSnapshot.objectElements {
            guard let origin = element.origin else {
                throw RoomProjectStoreError.invalidPackage(
                    "RoomPlan evidence requires every semantic element to declare an origin."
                )
            }
            guard origin == .roomPlan || origin == .manual else {
                throw RoomProjectStoreError.invalidPackage(
                    "RoomPlan evidence permits only RoomPlan or coordinate-bound manual elements."
                )
            }
            guard let provenance = element.provenance else {
                throw RoomProjectStoreError.invalidPackage(
                    "RoomPlan evidence requires coordinate-bound element provenance."
                )
            }
            guard
                !provenance.framework.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !provenance.sourceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                provenance.captureAttemptID == captureAttemptID,
                provenance.coordinateSpaceEpochID == coordinateSpaceEpochID
            else {
                throw RoomProjectStoreError.invalidPackage(
                    "RoomPlan element provenance does not match the revision coordinate space."
                )
            }
        }
    }

    private func validateFixtureRescanProvenance(
        _ payload: RoomRevisionPayload,
        manifest: RoomRevisionManifest
    ) throws {
        guard manifest.reason == .rescan else {
            return
        }
        guard
            let evidence = manifest.captureEvidence,
            evidence.source == .deterministicFixture,
            evidence.captureAttemptID == nil,
            evidence.coordinateSpaceEpochID == nil,
            evidence.artifacts.allSatisfy({ $0.status != .present })
        else {
            throw RoomProjectStoreError.invalidRescanProposal(
                "A fixture rescan must retain deterministic omission evidence only."
            )
        }
        for element in payload.semanticSnapshot.structuralElements
            + payload.semanticSnapshot.objectElements {
            guard
                element.origin == .deterministicFixture,
                let provenance = element.provenance,
                !provenance.framework.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !provenance.sourceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                provenance.captureAttemptID == nil,
                provenance.coordinateSpaceEpochID == nil
            else {
                throw RoomProjectStoreError.invalidRescanProposal(
                    "A fixture rescan must use deterministic candidate provenance for every semantic element."
                )
            }
        }
    }

    private func validate(
        pending: PendingRoomRevisionTransaction,
        expectedProjectID: String
    ) throws {
        guard
            pending.projectID == expectedProjectID,
            RoomPathValidation.isSafeStableIdentifier(pending.revisionID),
            RoomPathValidation.isSafeStableIdentifier(pending.previousHeadRevisionID),
            RoomPathValidation.isSafeStableIdentifier(pending.transactionID),
            pending.stagingDirectoryName.hasPrefix(".staging-"),
            RoomPathValidation.isSafeRelativePath(pending.stagingDirectoryName),
            pending.updatedManifest.projectID == expectedProjectID,
            pending.updatedManifest.headRevisionID == pending.revisionID,
            pending.updatedManifest.revisionIDs.last == pending.revisionID,
            pending.updatedManifest.revisionIDs.dropLast().last == pending.previousHeadRevisionID
        else {
            throw RoomProjectStoreError.invalidPackage("Pending revision marker is inconsistent.")
        }
        try validate(manifest: pending.updatedManifest, expectedProjectID: expectedProjectID)
    }

    private func validateAppendReason(
        reason: RoomRevisionReason,
        restoredFromRevisionID: String?,
        allowsFixtureRescan: Bool
    ) throws {
        switch reason {
        case .initial, .duplicate:
            throw RoomProjectStoreError.invalidRevisionReason(
                reason: reason,
                restoredFromRevisionID: restoredFromRevisionID
            )
        case .revert:
            guard restoredFromRevisionID != nil else {
                throw RoomProjectStoreError.invalidRevisionReason(
                    reason: reason,
                    restoredFromRevisionID: nil
                )
            }
        case .edit:
            guard restoredFromRevisionID == nil else {
                throw RoomProjectStoreError.invalidRevisionReason(
                    reason: reason,
                    restoredFromRevisionID: restoredFromRevisionID
                )
            }
        case .rescan:
            guard allowsFixtureRescan, restoredFromRevisionID == nil else {
                throw RoomProjectStoreError.invalidRevisionReason(
                    reason: reason,
                    restoredFromRevisionID: restoredFromRevisionID
                )
            }
        }
    }

    private func validateStoredRevisionReason(
        _ revision: RoomRevisionManifest,
        index: Int,
        revisionIDs: [String]
    ) throws {
        if index == 0 {
            guard
                revision.reason == .initial || revision.reason == .duplicate,
                revision.parentRevisionID == nil,
                revision.restoredFromRevisionID == nil
            else {
                throw RoomProjectStoreError.invalidRevisionReason(
                    reason: revision.reason,
                    restoredFromRevisionID: revision.restoredFromRevisionID
                )
            }
            return
        }

        try validateAppendReason(
            reason: revision.reason,
            restoredFromRevisionID: revision.restoredFromRevisionID,
            allowsFixtureRescan: revision.reason == .rescan
        )
        guard revision.reason == .revert else {
            return
        }
        guard let restoredFromRevisionID = revision.restoredFromRevisionID else {
            throw RoomProjectStoreError.invalidRevisionReason(
                reason: .revert,
                restoredFromRevisionID: nil
            )
        }
        guard let restoredIndex = revisionIDs.firstIndex(of: restoredFromRevisionID) else {
            throw RoomProjectStoreError.revisionNotFound(
                projectID: revision.projectID,
                revisionID: restoredFromRevisionID
            )
        }
        guard restoredIndex < index else {
            throw RoomProjectStoreError.invalidRevisionReason(
                reason: .revert,
                restoredFromRevisionID: restoredFromRevisionID
            )
        }
    }

    private func validateIdentifier(_ value: String) throws {
        guard RoomPathValidation.isSafeStableIdentifier(value) else {
            throw RoomProjectStoreError.invalidIdentifier(value)
        }
    }

    private func makeSummary(_ package: RoomProjectPackage) -> RoomProjectSummary {
        return RoomProjectSummary(
            projectID: package.manifest.projectID,
            customName: package.metadata.customName,
            captureDate: package.metadata.captureDate,
            lastRevisedDate: package.effectiveLastRevisedDate,
            manualLocation: package.metadata.manualLocation,
            tags: package.metadata.tags,
            thumbnailRelativePath: package.metadata.thumbnailRelativePath,
            archived: package.metadata.archived,
            headRevisionID: package.manifest.headRevisionID
        )
    }

    private func listingIssue(
        projectID: String,
        error: Error
    ) -> RoomProjectListingIssue {
        if let storeError = error as? RoomProjectStoreError,
           case .symbolicLinkDetected(_) = storeError {
            return RoomProjectListingIssue(
                projectID: projectID,
                kind: .symbolicLink,
                message: "Package access was blocked because a symbolic link was found."
            )
        }
        return RoomProjectListingIssue(
            projectID: projectID,
            kind: .corruptPackage,
            message: "Package is malformed or cannot be read; valid room packages remain available."
        )
    }

    // MARK: - Phase-6 full-project backup and recovery

    private struct BackupSourceFile {
        let sourceURL: URL
        let packagePath: RoomBackupPackagePath
    }

    private func validatedBackupWorkspaceDestination(
        _ requestedURL: URL,
        root: URL
    ) throws -> URL {
        let destination = requestedURL.standardizedFileURL
        guard destination.isFileURL,
              !isContained(destination.resolvingSymlinksInPath().standardizedFileURL, within: root),
              !pathExists(destination),
              !isSymbolicLink(destination)
        else {
            if isContained(destination, within: root) {
                throw RoomBackupError.destinationInsideProjectRoot
            }
            throw RoomBackupError.unsafeDestination(destination.path)
        }
        let parent = destination.deletingLastPathComponent()
        guard directoryExists(parent), !isSymbolicLink(parent) else {
            throw RoomBackupError.unsafeDestination(parent.path)
        }
        return destination
    }

    private func validatedRecoveryWorkspace(
        _ requestedURL: URL,
        root: URL
    ) throws -> URL {
        let workspace = requestedURL.standardizedFileURL
        guard workspace.isFileURL,
              !isContained(workspace.resolvingSymlinksInPath().standardizedFileURL, within: root),
              !isSymbolicLink(workspace)
        else {
            throw RoomBackupError.unsafeDestination(workspace.path)
        }
        let parent = workspace.deletingLastPathComponent()
        guard directoryExists(parent), !isSymbolicLink(parent) else {
            throw RoomBackupError.unsafeDestination(parent.path)
        }
        return workspace
    }

    private func assertExternalBackupWorkspaceSafe(
        _ workspaceURL: URL,
        root: URL
    ) throws {
        let resolved = workspaceURL.resolvingSymlinksInPath().standardizedFileURL
        guard
            workspaceURL.isFileURL,
            !isContained(resolved, within: root),
            directoryExists(workspaceURL),
            !isSymbolicLink(workspaceURL)
        else {
            throw RoomBackupError.unsafeDestination(workspaceURL.path)
        }
    }

    private func makeBackupWorkspaceStagingURL(parent: URL) throws -> URL {
        guard directoryExists(parent), !isSymbolicLink(parent) else {
            throw RoomBackupError.unsafeDestination(parent.path)
        }
        for _ in 0..<16 {
            let candidate = parent.appendingPathComponent(
                ".roomscan-backup-stage-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
            if !pathExists(candidate), !isSymbolicLink(candidate) {
                return candidate
            }
        }
        throw RoomBackupError.unsafeDestination(parent.path)
    }

    private func writeBackupWorkspaceOwnership(
        _ marker: RoomBackupWorkspaceOwnershipRecord,
        to workspaceURL: URL
    ) throws {
        let markerURL = workspaceURL.appendingPathComponent(".roomscan-backup-workspace.json")
        guard !pathExists(markerURL), !isSymbolicLink(markerURL) else {
            throw RoomBackupError.destinationAlreadyExists(markerURL.path)
        }
        do {
            let data = try RoomJSONCoding.makeEncoder().encode(marker)
            try RoomAtomicFileWriter.writeNewFile(
                data,
                to: markerURL,
                fileManager: fileManager
            )
        } catch {
            throw RoomBackupError.storageFailure("Unable to write backup workspace ownership marker.")
        }
    }

    private func removeOwnedBackupWorkspace(_ workspaceURL: URL, token: String) throws {
        guard
            workspaceURL.lastPathComponent.hasPrefix(".roomscan-backup-"),
            directoryExists(workspaceURL),
            !isSymbolicLink(workspaceURL)
        else {
            return
        }
        let markerURL = workspaceURL.appendingPathComponent(".roomscan-backup-workspace.json")
        guard pathExists(markerURL), !isSymbolicLink(markerURL), try isRegularFile(markerURL) else {
            throw RoomBackupError.invalidOwnershipMarker("Backup workspace marker is missing or unsafe.")
        }
        let marker: RoomBackupWorkspaceOwnershipRecord
        do {
            marker = try RoomJSONCoding.makeDecoder().decode(
                RoomBackupWorkspaceOwnershipRecord.self,
                from: Data(contentsOf: markerURL)
            )
        } catch {
            throw RoomBackupError.invalidOwnershipMarker("Backup workspace marker is malformed.")
        }
        guard
            marker.formatVersion == RoomBackupWorkspaceOwnershipRecord.currentFormatVersion,
            marker.directoryName == workspaceURL.lastPathComponent,
            marker.token == token
        else {
            throw RoomBackupError.invalidOwnershipMarker("Backup workspace marker does not own this stage.")
        }
        try fileManager.removeItem(at: workspaceURL)
    }

    private func backupSourceFiles(
        root: URL,
        projectID: String,
        projectURL: URL,
        package: RoomProjectPackage
    ) throws -> [BackupSourceFile] {
        try validateBackupRevisionOwnership(package: package, projectURL: projectURL, root: root)
        var sources: [BackupSourceFile] = []
        var seen = Set<String>()
        func append(_ sourceURL: URL, packageRelativePath: String) throws {
            let packagePath = try RoomBackupPackagePath(packageRelativePath)
            let key = packagePath.value.precomposedStringWithCanonicalMapping.lowercased()
            guard seen.insert(key).inserted else {
                throw RoomBackupError.duplicatePath(packagePath.value)
            }
            try assertNoSymbolicLinks(root: root, through: sourceURL)
            guard try isRegularFile(sourceURL) else {
                throw RoomBackupError.unsafeDestination(sourceURL.path)
            }
            sources.append(BackupSourceFile(sourceURL: sourceURL, packagePath: packagePath))
        }

        try append(projectURL.appendingPathComponent("manifest.json"), packageRelativePath: "manifest.json")
        try append(projectURL.appendingPathComponent("metadata.json"), packageRelativePath: "metadata.json")

        var projectAssetPaths = Set<String>()
        if let thumbnail = package.metadata.thumbnailRelativePath {
            projectAssetPaths.insert(thumbnail.value)
        }
        if let policy = package.manifest.assetPolicy {
            for path in [policy.nativeUSDZ, policy.rawMesh, policy.worldMap] {
                if let path {
                    projectAssetPaths.insert(path.value)
                }
            }
        }
        for path in projectAssetPaths.sorted() {
            try append(projectURL.appendingPathComponent(path), packageRelativePath: path)
        }

        for revision in package.revisions {
            let revisionID = revision.manifest.revisionID
            let revisionURL = try revisionDirectory(
                root: root,
                projectID: projectID,
                revisionID: revisionID
            )
            let prefix = "revisions/\(revisionID)"
            for document in [
                "revision.json",
                "semantic-model.json",
                "annotations.json",
                "measurements.json",
                "photos.json",
            ] {
                try append(
                    revisionURL.appendingPathComponent(document),
                    packageRelativePath: "\(prefix)/\(document)"
                )
            }
            let ownershipURL = revisionURL.appendingPathComponent(".roomscan-ownership.json")
            if pathExists(ownershipURL) {
                try append(
                    ownershipURL,
                    packageRelativePath: "\(prefix)/.roomscan-ownership.json"
                )
            }
            for (assetURL, relativePath) in try regularRevisionAssets(
                in: revisionURL,
                relativeDirectory: "",
                root: root
            ) {
                if try isBackupExcludedRevisionAsset(relativePath) {
                    continue
                }
                try append(
                    assetURL,
                    packageRelativePath: "\(prefix)/\(relativePath)"
                )
            }
        }
        return sources.sorted { $0.packagePath < $1.packagePath }
    }

    private func validateBackupRevisionOwnership(
        package: RoomProjectPackage,
        projectURL: URL,
        root: URL
    ) throws {
        let schema = try validatedProjectSchemaVersion(package.manifest)
        for revision in package.revisions {
            let revisionURL = projectURL
                .appendingPathComponent("revisions", isDirectory: true)
                .appendingPathComponent(revision.manifest.revisionID, isDirectory: true)
            let ownershipURL = revisionURL.appendingPathComponent(".roomscan-ownership.json")
            guard pathExists(ownershipURL) else {
                guard schema == .v1 else {
                    throw RoomBackupError.missingOwnershipMarker(
                        "revisions/\(revision.manifest.revisionID)/.roomscan-ownership.json"
                    )
                }
                continue
            }
            try assertNoSymbolicLinks(root: root, through: ownershipURL)
            guard try isRegularFile(ownershipURL) else {
                throw RoomBackupError.invalidOwnershipMarker(ownershipURL.lastPathComponent)
            }
            let ownership = try readJSON(
                RoomRevisionOwnershipRecord.self,
                from: ownershipURL,
                root: root
            )
            guard
                ownership.projectID == package.manifest.projectID,
                ownership.revisionID == revision.manifest.revisionID,
                RoomPathValidation.isSafeStableIdentifier(ownership.transactionID)
            else {
                throw RoomBackupError.invalidOwnershipMarker(ownershipURL.lastPathComponent)
            }
        }
    }

    /// Reserved revision children are excluded only with their exact canonical
    /// spelling. Case/NFC aliases are rejected rather than copied as ordinary
    /// attachments, because the default Apple filesystem can alias them to an
    /// excluded export or staging namespace.
    private func isBackupExcludedRevisionAsset(_ relativePath: String) throws -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        for component in components {
            let folded = component.precomposedStringWithCanonicalMapping.lowercased()
            if folded == "exports" {
                guard component == "exports" else {
                    throw RoomBackupError.invalidPackagePath(relativePath)
                }
                return true
            }
            if folded == ".pending-revision.json" {
                guard component == ".pending-revision.json" else {
                    throw RoomBackupError.invalidPackagePath(relativePath)
                }
                return true
            }
            if folded.hasPrefix(".staging-") || folded.hasPrefix(".recovery-") {
                guard component.hasPrefix(".staging-") || component.hasPrefix(".recovery-") else {
                    throw RoomBackupError.invalidPackagePath(relativePath)
                }
                return true
            }
        }
        return false
    }

    private func backupArchiveExtension(for packagePath: String) -> String {
        let value = URL(fileURLWithPath: packagePath).pathExtension.lowercased()
        guard !value.isEmpty,
              value.count <= 10,
              value.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) || (97...122).contains($0.value)
              })
        else {
            return "bin"
        }
        return value
    }

    private func backupMediaType(for packagePath: String) -> String {
        switch backupArchiveExtension(for: packagePath) {
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "usdz": return "model/vnd.usdz+zip"
        default: return "application/octet-stream"
        }
    }

    private func copyBackupFile(
        from sourceURL: URL,
        to destinationURL: URL,
        maximumBytes: UInt64,
        root: URL
    ) throws -> UInt64 {
        guard !isSymbolicLink(sourceURL), try isRegularFile(sourceURL) else {
            throw RoomBackupError.unsafeDestination(sourceURL.path)
        }
        try assertNoSymbolicLinks(root: root, through: destinationURL)
        guard !pathExists(destinationURL), !isSymbolicLink(destinationURL) else {
            throw RoomBackupError.destinationAlreadyExists(destinationURL.path)
        }
        let parent = destinationURL.deletingLastPathComponent()
        try assertNoSymbolicLinks(root: root, through: parent)
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let source = try FileHandle(forReadingFrom: sourceURL)
        defer { try? source.close() }
        try Data().write(to: destinationURL, options: [.withoutOverwriting])
        let destination = try FileHandle(forWritingTo: destinationURL)
        var removeDestination = true
        do {
            var byteCount: UInt64 = 0
            while let chunk = try source.read(upToCount: 64 * 1024), !chunk.isEmpty {
                let (nextCount, overflow) = byteCount.addingReportingOverflow(UInt64(chunk.count))
                guard !overflow, nextCount <= maximumBytes else {
                    throw RoomBackupError.sizeLimitExceeded(sourceURL.lastPathComponent)
                }
                try destination.write(contentsOf: chunk)
                byteCount = nextCount
            }
            try destination.synchronize()
            try destination.close()
            guard try isRegularFile(destinationURL) else {
                throw RoomBackupError.unsafeDestination(destinationURL.path)
            }
            removeDestination = false
            return byteCount
        } catch {
            try? destination.close()
            if removeDestination, pathExists(destinationURL), !isSymbolicLink(destinationURL) {
                try? fileManager.removeItem(at: destinationURL)
            }
            if let backupError = error as? RoomBackupError {
                throw backupError
            }
            throw RoomBackupError.storageFailure("Unable to copy a backup file.")
        }
    }

    private func validateBackupMaterializationClosure(
        _ entries: [RoomBackupMaterializationEntry]
    ) throws {
        var archivePaths = Set<String>()
        var packagePaths = Set<String>()
        for entry in entries {
            guard archivePaths.insert(entry.entryPath.value.lowercased()).inserted else {
                throw RoomBackupError.duplicatePath(entry.entryPath.value)
            }
            let packageKey = entry.packageRelativePath.value
                .precomposedStringWithCanonicalMapping
                .lowercased()
            guard packagePaths.insert(packageKey).inserted else {
                throw RoomBackupError.duplicatePath(entry.packageRelativePath.value)
            }
        }
    }

    private func reconstructBackupPackage(
        manifest: RoomBackupManifest,
        from extractionURL: URL,
        to packageURL: URL,
        maximumBytes: UInt64,
        root: URL
    ) throws {
        guard !pathExists(packageURL), !isSymbolicLink(packageURL) else {
            throw RoomBackupError.destinationAlreadyExists(packageURL.path)
        }
        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: false)
        for entry in manifest.entries.sorted(by: { $0.archivePath < $1.archivePath }) {
            let archivePath = try RoomBackupArchivePath(entry.archivePath)
            let packagePath = try RoomBackupPackagePath(entry.packageRelativePath)
            let source = extractionURL.appendingPathComponent(archivePath.value)
            let destination = packageURL.appendingPathComponent(packagePath.value)
            let byteCount = try copyBackupFile(
                from: source,
                to: destination,
                maximumBytes: maximumBytes,
                root: root
            )
            guard byteCount == entry.byteCount,
                  try RoomSHA256.hexDigest(ofFile: destination) == entry.sha256Hex
            else {
                throw RoomBackupError.invalidBackupManifest("Reconstructed package bytes differ from its backup manifest.")
            }
        }
    }

    private func promotePreparedBackupRecovery(
        _ prepared: PreparedRoomBackupRecovery,
        root: URL,
        conflictPolicy: RoomBackupRecoveryConflictPolicy,
        copyProjectID: String?
    ) throws -> RoomBackupRecoveryResult {
        try ensureRootExists(root)
        let originalProjectID = prepared.manifest.projectID
        let originalDestination = try projectDirectory(root: root, projectID: originalProjectID)
        let originalExists = pathExists(originalDestination)
        if originalExists {
            let existing = try loadLocked(root: root, projectID: originalProjectID)
            if try backupPackageMatches(prepared, package: existing, root: root, projectURL: originalDestination) {
                return .noOp
            }
            guard conflictPolicy == .recoverAsCopy,
                  let copyProjectID
            else {
                throw RoomBackupError.recoveryConflict(originalProjectID)
            }
            return try promotePreparedBackupCopy(
                prepared,
                root: root,
                newProjectID: copyProjectID
            )
        }
        let package = try promotePreparedBackupPackage(
            prepared,
            root: root,
            destinationProjectID: originalProjectID,
            rewriteAsCopy: false
        )
        return .restored(makeSummary(package))
    }

    private func promotePreparedBackupCopy(
        _ prepared: PreparedRoomBackupRecovery,
        root: URL,
        newProjectID: String
    ) throws -> RoomBackupRecoveryResult {
        let destination = try projectDirectory(root: root, projectID: newProjectID)
        guard !pathExists(destination), !isSymbolicLink(destination) else {
            throw RoomBackupError.recoveryConflict(newProjectID)
        }
        let package = try promotePreparedBackupPackage(
            prepared,
            root: root,
            destinationProjectID: newProjectID,
            rewriteAsCopy: true
        )
        return .recoveredCopy(makeSummary(package))
    }

    private func promotePreparedBackupPackage(
        _ prepared: PreparedRoomBackupRecovery,
        root: URL,
        destinationProjectID: String,
        rewriteAsCopy: Bool
    ) throws -> RoomProjectPackage {
        let finalURL = try projectDirectory(root: root, projectID: destinationProjectID)
        guard !pathExists(finalURL), !isSymbolicLink(finalURL) else {
            throw RoomBackupError.destinationAlreadyExists(finalURL.path)
        }
        let stagingURL = try makeUniqueStagingURL(
            parent: root,
            prefix: ".recovery-\(destinationProjectID)-",
            root: root
        )
        var stagingCreated = false
        do {
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
            stagingCreated = true
            try copyPreparedBackupPackage(
                prepared,
                to: stagingURL,
                root: root
            )
            if rewriteAsCopy {
                try rewriteRecoveredCopyProjectIdentifiers(
                    at: stagingURL,
                    originalProjectID: prepared.manifest.projectID,
                    newProjectID: destinationProjectID,
                    root: root
                )
            }
            let validated = try loadProjectPackageLocked(
                root: root,
                projectID: destinationProjectID,
                projectURL: stagingURL
            )
            try validateBackupRevisionOwnership(
                package: validated,
                projectURL: stagingURL,
                root: root
            )
            guard !pathExists(finalURL), !isSymbolicLink(finalURL) else {
                throw RoomBackupError.destinationAlreadyExists(finalURL.path)
            }
            try fileManager.moveItem(at: stagingURL, to: finalURL)
            stagingCreated = false
            return validated
        } catch {
            if stagingCreated {
                try? removeRecoveryPromotionStaging(stagingURL, root: root)
            }
            if let backupError = error as? RoomBackupError {
                throw backupError
            }
            if let storeError = error as? RoomProjectStoreError {
                throw RoomBackupError.storageFailure("Recovered package validation failed: \(storeError)")
            }
            throw RoomBackupError.storageFailure("Unable to promote the prepared backup recovery.")
        }
    }

    private func copyPreparedBackupPackage(
        _ prepared: PreparedRoomBackupRecovery,
        to destinationURL: URL,
        root: URL
    ) throws {
        for entry in prepared.manifest.entries.sorted(by: { $0.packageRelativePath < $1.packageRelativePath }) {
            let packagePath = try RoomBackupPackagePath(entry.packageRelativePath)
            let source = prepared.packageURL.appendingPathComponent(packagePath.value)
            let destination = destinationURL.appendingPathComponent(packagePath.value)
            let copiedBytes = try copyBackupFile(
                from: source,
                to: destination,
                maximumBytes: backupLimits.maxFileBytes,
                root: root
            )
            guard copiedBytes == entry.byteCount,
                  try RoomSHA256.hexDigest(ofFile: destination) == entry.sha256Hex
            else {
                throw RoomBackupError.invalidBackupManifest("Prepared backup stage changed before recovery promotion.")
            }
        }
    }

    /// This staging directory is created synchronously by this recovery
    /// transaction. Unlike an initial-save staging directory, it uses the
    /// `.recovery-` prefix and has no workspace marker, so remove only this
    /// proven direct child on a failed promotion.
    private func removeRecoveryPromotionStaging(_ stagingURL: URL, root: URL) throws {
        guard stagingURL.deletingLastPathComponent() == root,
              stagingURL.lastPathComponent.hasPrefix(".recovery-")
        else {
            throw RoomBackupError.unsafeDestination(stagingURL.path)
        }
        try assertNoSymbolicLinks(root: root, through: stagingURL)
        guard pathExists(stagingURL) else { return }
        try fileManager.removeItem(at: stagingURL)
    }

    private func backupPackageMatches(
        _ prepared: PreparedRoomBackupRecovery,
        package: RoomProjectPackage,
        root: URL,
        projectURL: URL
    ) throws -> Bool {
        let localSources = try backupSourceFiles(
            root: root,
            projectID: package.manifest.projectID,
            projectURL: projectURL,
            package: package
        )
        guard localSources.count == prepared.manifest.entries.count else {
            return false
        }
        var localByPath: [String: URL] = [:]
        for source in localSources {
            guard localByPath[source.packagePath.value] == nil else {
                return false
            }
            localByPath[source.packagePath.value] = source.sourceURL
        }
        for entry in prepared.manifest.entries {
            guard let localURL = localByPath[entry.packageRelativePath],
                  try fileByteCount(of: localURL) == Int(entry.byteCount),
                  try RoomSHA256.hexDigest(ofFile: localURL) == entry.sha256Hex
            else {
                return false
            }
        }
        return true
    }

    private func rewriteRecoveredCopyProjectIdentifiers(
        at projectURL: URL,
        originalProjectID: String,
        newProjectID: String,
        root: URL
    ) throws {
        var manifest = try readJSON(
            RoomProjectManifest.self,
            from: projectURL.appendingPathComponent("manifest.json"),
            root: root
        )
        guard manifest.projectID == originalProjectID else {
            throw RoomBackupError.invalidBackupManifest("Recovered manifest project ID changed unexpectedly.")
        }
        manifest.projectID = newProjectID
        var metadata = try readJSON(
            RoomMetadata.self,
            from: projectURL.appendingPathComponent("metadata.json"),
            root: root
        )
        guard metadata.projectID == originalProjectID else {
            throw RoomBackupError.invalidBackupManifest("Recovered metadata project ID changed unexpectedly.")
        }
        metadata.projectID = newProjectID
        metadata.customName += " (Recovered Copy)"
        try writeJSON(manifest, to: projectURL.appendingPathComponent("manifest.json"), root: root)
        try writeJSON(metadata, to: projectURL.appendingPathComponent("metadata.json"), root: root)

        for revisionID in manifest.revisionIDs {
            let revisionURL = projectURL
                .appendingPathComponent("revisions", isDirectory: true)
                .appendingPathComponent(revisionID, isDirectory: true)
            var revisionManifest = try readJSON(
                RoomRevisionManifest.self,
                from: revisionURL.appendingPathComponent("revision.json"),
                root: root
            )
            var semantic = try readJSON(
                RoomSemanticSnapshot.self,
                from: revisionURL.appendingPathComponent("semantic-model.json"),
                root: root
            )
            var annotations = try readJSON(
                RoomAnnotationsDocument.self,
                from: revisionURL.appendingPathComponent("annotations.json"),
                root: root
            )
            var measurements = try readJSON(
                RoomMeasurementsDocument.self,
                from: revisionURL.appendingPathComponent("measurements.json"),
                root: root
            )
            var photos = try readJSON(
                RoomPhotosDocument.self,
                from: revisionURL.appendingPathComponent("photos.json"),
                root: root
            )
            guard
                revisionManifest.projectID == originalProjectID,
                semantic.projectID == originalProjectID,
                annotations.projectID == originalProjectID,
                measurements.projectID == originalProjectID,
                photos.projectID == originalProjectID
            else {
                throw RoomBackupError.invalidBackupManifest("Recovered revision documents disagree on project ID.")
            }
            revisionManifest.projectID = newProjectID
            semantic.projectID = newProjectID
            annotations.projectID = newProjectID
            measurements.projectID = newProjectID
            photos.projectID = newProjectID
            try writeJSON(revisionManifest, to: revisionURL.appendingPathComponent("revision.json"), root: root)
            try writeJSON(semantic, to: revisionURL.appendingPathComponent("semantic-model.json"), root: root)
            try writeJSON(annotations, to: revisionURL.appendingPathComponent("annotations.json"), root: root)
            try writeJSON(measurements, to: revisionURL.appendingPathComponent("measurements.json"), root: root)
            try writeJSON(photos, to: revisionURL.appendingPathComponent("photos.json"), root: root)
            let ownershipURL = revisionURL.appendingPathComponent(".roomscan-ownership.json")
            if pathExists(ownershipURL) {
                var ownership = try readJSON(
                    RoomRevisionOwnershipRecord.self,
                    from: ownershipURL,
                    root: root
                )
                guard ownership.projectID == originalProjectID, ownership.revisionID == revisionID else {
                    throw RoomBackupError.invalidOwnershipMarker(ownershipURL.lastPathComponent)
                }
                ownership = RoomRevisionOwnershipRecord(
                    projectID: newProjectID,
                    revisionID: revisionID,
                    transactionID: ownership.transactionID
                )
                try writeJSON(ownership, to: ownershipURL, root: root)
            }
        }
    }

    private func withRootLock<Result>(
        _ root: URL,
        operation: () throws -> Result
    ) rethrows -> Result {
        try RoomProjectProcessLockRegistry.shared.withLock(
            key: root.path,
            operation: operation
        )
    }

    private func canonicalRootURL() throws -> URL {
        let requestedRoot = configuredRootURL.standardizedFileURL
        // A configured package root is a controlled boundary. Reject a link at
        // that leaf, while still resolving any existing parent aliases such as
        // /var -> /private/var during the ancestor walk below.
        if pathExists(requestedRoot), isSymbolicLink(requestedRoot) {
            throw RoomProjectStoreError.symbolicLinkDetected(
                requestedRoot.lastPathComponent
            )
        }

        var existingAncestor = requestedRoot
        var missingComponents: [String] = []

        while !pathExists(existingAncestor) {
            let parent = existingAncestor.deletingLastPathComponent()
            guard parent.path != existingAncestor.path else {
                throw RoomProjectStoreError.storageFailure("Unable to resolve room storage root.")
            }
            let component = existingAncestor.lastPathComponent
            guard !component.isEmpty else {
                throw RoomProjectStoreError.storageFailure("Unable to resolve room storage root.")
            }
            missingComponents.insert(component, at: 0)
            existingAncestor = parent
        }

        let resolvedAncestor = existingAncestor
            .resolvingSymlinksInPath()
            .standardizedFileURL
        return missingComponents.reduce(resolvedAncestor) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }
    }

    private func ensureRootExists(_ root: URL) throws {
        if pathExists(root) {
            guard directoryExists(root) else {
                throw RoomProjectStoreError.storageFailure("Room storage is not a directory.")
            }
            return
        }
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw RoomProjectStoreError.storageFailure("Unable to prepare room storage.")
        }
    }

    private func projectDirectory(root: URL, projectID: String) throws -> URL {
        try validateIdentifier(projectID)
        return root.appendingPathComponent(projectID, isDirectory: true)
    }

    private func revisionDirectory(
        root: URL,
        projectID: String,
        revisionID: String
    ) throws -> URL {
        try validateIdentifier(projectID)
        try validateIdentifier(revisionID)
        return try projectDirectory(root: root, projectID: projectID)
            .appendingPathComponent("revisions", isDirectory: true)
            .appendingPathComponent(revisionID, isDirectory: true)
    }

    private func assertNoSymbolicLinks(root: URL, through target: URL) throws {
        let rootComponents = root.standardizedFileURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents
        guard
            targetComponents.count >= rootComponents.count,
            zip(rootComponents, targetComponents).allSatisfy({ pair in
                pair.0 == pair.1
            })
        else {
            throw RoomProjectStoreError.invalidPackage("Package path escaped its configured root.")
        }

        var current = root
        for component in targetComponents.dropFirst(rootComponents.count) {
            current = current.appendingPathComponent(component, isDirectory: true)
            if isSymbolicLink(current) {
                throw RoomProjectStoreError.symbolicLinkDetected(component)
            }
        }
    }

    private func isContained(_ candidate: URL, within root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        return candidateComponents.count >= rootComponents.count
            && zip(rootComponents, candidateComponents).allSatisfy { pair in
                pair.0 == pair.1
            }
    }

    private func pathExists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path) || isSymbolicLink(url)
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && !isSymbolicLink(url)
    }

    private func isRegularFile(_ url: URL) throws -> Bool {
        guard pathExists(url), !isSymbolicLink(url) else {
            return false
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let type = attributes[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeRegular
    }

    private func fileByteCount(of url: URL) throws -> Int {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let byteCount = attributes[.size] as? NSNumber else {
            throw RoomProjectStoreError.storageFailure(
                "Unable to determine evidence file size."
            )
        }
        let value = byteCount.int64Value
        guard value >= 0, value <= Int64(Int.max) else {
            throw RoomProjectStoreError.storageFailure(
                "Evidence file size is not representable."
            )
        }
        return Int(value)
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
