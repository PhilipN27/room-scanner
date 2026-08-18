import Foundation
import RoomScanCore

/// App-layer, offline-only boundary for untrusted Concept Set input. The Core
/// store owns promotion; this type owns the short-lived external-input lease.
@MainActor
final class RoomConceptImportCoordinator {
    enum ImportError: Error, Equatable {
        case unsafeInput
        case unsupportedInput
        case invalidIdentifier
        case cancelled
    }

    private static let ownershipFilename = ".roomscan-concept-import-ownership"
    private static let maximumLooseBytes = 32 * 1_024 * 1_024
    private static let maximumPackageBytes = 512 * 1_024 * 1_024

    private let store: LocalRoomConceptStore
    private let scratchRootURL: URL
    private let now: @Sendable () -> Date
    private let makeIdentifier: @Sendable () -> String
    private let fileManager: FileManager

    init(
        store: LocalRoomConceptStore,
        scratchRootURL: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        makeIdentifier: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        fileManager: FileManager = .default
    ) {
        self.store = store
        self.scratchRootURL = scratchRootURL.standardizedFileURL
        self.now = now
        self.makeIdentifier = makeIdentifier
        self.fileManager = fileManager
    }

    func importLoose(
        from sourceURL: URL,
        request: String,
        scope: RoomRedesignScope,
        provider: String? = nil,
        context: RoomConceptSetValidationContext
    ) async throws -> RoomConceptSet {
        try checkCancellation()
        let didAccessSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope { sourceURL.stopAccessingSecurityScopedResource() }
        }
        try validateRegularInput(sourceURL, maximumBytes: Self.maximumLooseBytes)
        let sourceBytes = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        try checkCancellation()
        let sanitized = try RoomAIImageSanitizer.sanitize(
            sourceBytes,
            declaredFilename: sourceURL.lastPathComponent
        )
        let conceptImage = try canonicalConceptImage(from: sanitized)
        let attachmentID = "attachment-0001"
        let attachment = RoomConceptSetAttachment(
            attachmentID: attachmentID,
            relativePath: "attachments/\(attachmentID).\(fileExtension(for: conceptImage.mediaType))",
            sha256: RoomSHA256.hexDigest(of: conceptImage.data),
            byteCount: UInt64(conceptImage.data.count),
            mediaType: conceptImage.mediaType,
            sanitizationProvenance: .appReencodedLooseFile,
            mapping: .unmatched
        )
        let timestamp = canonicalTimestamp(now())
        let concept = RoomConceptSet(
            conceptSetID: try nextIdentifier(),
            sourceRevision: context.expectedSourceRevision,
            request: request,
            scope: scope,
            provider: normalizedProvider(provider),
            sourceAIRoomPackage: nil,
            importProvenance: .init(kind: .looseLocalFile, sourceFilename: sourceURL.lastPathComponent),
            createdAt: timestamp,
            importedAt: timestamp,
            attachments: [attachment],
            comments: [],
            approvalState: .pending,
            archiveState: .active
        )
        return try await promote(
            concept: concept,
            attachments: [.init(attachmentID: attachmentID, data: conceptImage.data)],
            context: context
        )
    }

    func importPackage(
        from archiveURL: URL,
        provider: String? = nil,
        requestOverride: String? = nil,
        scopeOverride: RoomRedesignScope? = nil,
        context: RoomConceptSetValidationContext
    ) async throws -> RoomConceptSet {
        try checkCancellation()
        let didAccessSecurityScope = archiveURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope { archiveURL.stopAccessingSecurityScopedResource() }
        }
        try validateRegularInput(archiveURL, maximumBytes: Self.maximumPackageBytes)
        // This digest is deliberately only an observation. The package remains
        // immutable input and Core validates its strict STORE closure separately.
        let beforeDigest = try RoomSHA256.hexDigest(ofFile: archiveURL)
        let importedPayload = try await withScratchLease { [self] scratchURL in
            let extraction = scratchURL.appendingPathComponent("extracted", isDirectory: true)
            try self.fileManager.createDirectory(at: extraction, withIntermediateDirectories: false)
            let result = try await RoomConceptSetArchive.validateImport(
                archiveURL: archiveURL,
                extractionDirectoryURL: extraction,
                context: context
            )
            var rewritten: [(RoomConceptSetAttachment, Data)] = []
            for original in result.conceptSet.attachments.sorted(by: { $0.attachmentID < $1.attachmentID }) {
                try self.checkCancellation()
                guard let attachmentURL = result.attachmentURLs[original.attachmentID] else {
                    throw ImportError.unsafeInput
                }
                try self.validateRegularInput(attachmentURL, maximumBytes: Self.maximumLooseBytes)
                let sanitized = try RoomAIImageSanitizer.sanitize(
                    Data(contentsOf: attachmentURL, options: [.mappedIfSafe]),
                    declaredFilename: attachmentURL.lastPathComponent
                )
                let conceptImage = try self.canonicalConceptImage(from: sanitized)
                let mapping = self.validatedAutomaticMapping(
                    original.mapping,
                    sourcePackage: result.conceptSet.sourceAIRoomPackage,
                    context: context
                )
                rewritten.append((
                    .init(
                        attachmentID: original.attachmentID,
                        relativePath: "attachments/\(original.attachmentID).\(self.fileExtension(for: conceptImage.mediaType))",
                        sha256: RoomSHA256.hexDigest(of: conceptImage.data),
                        byteCount: UInt64(conceptImage.data.count),
                        mediaType: conceptImage.mediaType,
                        sanitizationProvenance: .appReencodedPackagedFile,
                        mapping: mapping
                    ),
                    conceptImage.data
                ))
            }
            return (result.conceptSet, rewritten)
        }
        guard try RoomSHA256.hexDigest(ofFile: archiveURL) == beforeDigest else {
            throw ImportError.unsafeInput
        }
        try checkCancellation()

        // validateImport has already bound source/package provenance to context.
        // Imported provider identity is never trusted from a package; only a
        // value supplied by this local user action may be retained.
        let timestamp = canonicalTimestamp(now())
        let rewrittenAttachments = importedPayload.1.map { $0.0 }
        let bytes: [RoomConceptSetAttachmentBytes] = importedPayload.1.map {
            RoomConceptSetAttachmentBytes(attachmentID: $0.0.attachmentID, data: $0.1)
        }
        let imported = RoomConceptSet(
            conceptSetID: try nextIdentifier(),
            sourceRevision: context.expectedSourceRevision,
            request: requestOverride ?? importedPayload.0.request,
            scope: scopeOverride ?? importedPayload.0.scope,
            provider: normalizedProvider(provider),
            sourceAIRoomPackage: importedPayload.0.sourceAIRoomPackage,
            importProvenance: .init(kind: .packagedOutput, sourceFilename: archiveURL.lastPathComponent),
            createdAt: importedPayload.0.createdAt,
            importedAt: timestamp,
            attachments: rewrittenAttachments,
            comments: [],
            approvalState: .pending,
            archiveState: .active
        )
        return try await promote(concept: imported, attachments: bytes, context: context)
    }

    func list(context: RoomConceptSetValidationContext, archiveState: RoomConceptArchiveState? = nil) async throws -> [RoomConceptSet] {
        try await store.list(context: context, archiveState: archiveState)
    }

    func load(_ conceptSetID: String, context: RoomConceptSetValidationContext) async throws -> RoomConceptSet {
        try await store.load(conceptSetID: conceptSetID, context: context)
    }

    func attachmentData(conceptSetID: String, attachmentID: String, context: RoomConceptSetValidationContext) async throws -> Data {
        try await store.attachmentData(conceptSetID: conceptSetID, attachmentID: attachmentID, context: context)
    }

    func updateReview(
        conceptSetID: String,
        attachmentMappings: [String: RoomConceptAttachmentMapping],
        approvalState: RoomConceptApprovalState,
        comments: [String],
        context: RoomConceptSetValidationContext
    ) async throws -> RoomConceptSet {
        var proposed = try await store.load(conceptSetID: conceptSetID, context: context)
        proposed.attachments = proposed.attachments.map { attachment in
            var changed = attachment
            if let mapping = attachmentMappings[attachment.attachmentID] {
                changed.mapping = mapping
            }
            return changed
        }
        proposed.approvalState = approvalState
        proposed.comments = comments
        return try await store.updateReview(proposed, context: context)
    }

    func archive(_ conceptSetID: String, context: RoomConceptSetValidationContext) async throws -> RoomConceptSet {
        try await store.archive(conceptSetID: conceptSetID, context: context)
    }

    func unarchive(_ conceptSetID: String, context: RoomConceptSetValidationContext) async throws -> RoomConceptSet {
        try await store.unarchive(conceptSetID: conceptSetID, context: context)
    }

    func delete(_ conceptSetID: String, context: RoomConceptSetValidationContext) async throws {
        try await store.delete(conceptSetID: conceptSetID, context: context)
    }

    static func uiFixtureContext() -> RoomConceptSetValidationContext {
        .init(
            expectedSourceRevision: .init(
                projectID: "fixture-project",
                revisionID: "fixture-revision",
                coordinateSpaceEpochID: "fixture-epoch",
                packageSchemaVersion: "room-scan-project-v2",
                semanticSHA256: String(repeating: "0", count: 64),
                revisionManifestSHA256: String(repeating: "1", count: 64)
            ),
            currentCanonicalCameraIDs: ["fixture-camera-1"]
        )
    }

    private func promote(
        concept: RoomConceptSet,
        attachments: [RoomConceptSetAttachmentBytes],
        context: RoomConceptSetValidationContext
    ) async throws -> RoomConceptSet {
        try await withScratchLease { [self] _ in
            try self.checkCancellation()
            return try await self.store.importConceptSet(
                .init(conceptSet: concept, attachments: attachments),
                context: context
            )
        }
    }

    private func validatedAutomaticMapping(
        _ sourceMapping: RoomConceptAttachmentMapping,
        sourcePackage: RoomConceptSourceAIRoomPackage?,
        context: RoomConceptSetValidationContext
    ) -> RoomConceptAttachmentMapping {
        guard let validatedPackage = context.validatedSourceAIRoomPackage(
                matching: sourcePackage
              ),
              sourceMapping.status == .automatic,
              let cameraID = sourceMapping.cameraID,
              context.currentCanonicalCameraIDs.contains(cameraID),
              validatedPackage.canonicalCameraIDs.contains(cameraID)
        else {
            return .unmatched
        }
        return .automatic(cameraID: cameraID)
    }

    private func withScratchLease<Result>(
        operation: @escaping (URL) async throws -> Result
    ) async throws -> Result {
        try checkCancellation()
        try prepareScratchRoot()
        let lease = scratchRootURL.appendingPathComponent(".roomscan-concept-import-\(UUID().uuidString.lowercased())", isDirectory: true)
        try fileManager.createDirectory(at: lease, withIntermediateDirectories: false)
        let marker = lease.appendingPathComponent(Self.ownershipFilename)
        try Data("roomscan-concept-import-v1".utf8).write(to: marker, options: .withoutOverwriting)
        defer { removeOwnedScratchLease(lease) }
        do {
            let result = try await operation(lease)
            try checkCancellation()
            return result
        } catch is CancellationError {
            throw ImportError.cancelled
        } catch let error as RoomConceptSetError where error == .cancelled {
            throw ImportError.cancelled
        }
    }

    private func prepareScratchRoot() throws {
        if fileManager.fileExists(atPath: scratchRootURL.path) {
            let values = try scratchRootURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw ImportError.unsafeInput }
        } else {
            try fileManager.createDirectory(at: scratchRootURL, withIntermediateDirectories: true)
        }
    }

    private func removeOwnedScratchLease(_ lease: URL) {
        guard let values = try? lease.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true
        else { return }
        let marker = lease.appendingPathComponent(Self.ownershipFilename)
        guard let markerValues = try? marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              markerValues.isRegularFile == true,
              markerValues.isSymbolicLink != true
        else { return }
        try? fileManager.removeItem(at: lease)
        if (try? fileManager.contentsOfDirectory(at: scratchRootURL, includingPropertiesForKeys: nil).isEmpty) == true {
            try? fileManager.removeItem(at: scratchRootURL)
        }
    }

    private func validateRegularInput(_ url: URL, maximumBytes: Int) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let byteCount = values.fileSize,
              byteCount > 0,
              byteCount <= maximumBytes
        else { throw ImportError.unsafeInput }
    }

    private func nextIdentifier() throws -> String {
        let identifier = makeIdentifier()
        guard identifier.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil else {
            throw ImportError.invalidIdentifier
        }
        return identifier
    }

    private func normalizedProvider(_ provider: String?) -> String? {
        guard let provider else { return nil }
        let trimmed = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func fileExtension(for mediaType: String) -> String {
        mediaType == "image/png" ? "png" : "jpg"
    }

    /// The shared sanitizer already applies orientation, fresh-encodes, strips
    /// JPEG/PNG metadata containers, and passes the Core positive-list media
    /// validator. Concept persistence revalidates the exact returned bytes.
    private func canonicalConceptImage(
        from sanitized: RoomAISanitizedImage
    ) throws -> (data: Data, mediaType: String) {
        _ = try RoomConceptImageValidator.validateSanitizedImage(
            sanitized.data,
            mediaType: sanitized.mediaType
        )
        return (sanitized.data, sanitized.mediaType)
    }

    private func checkCancellation() throws {
        if Task.isCancelled { throw ImportError.cancelled }
    }

    private func canonicalTimestamp(_ value: Date) -> Date {
        Date(
            timeIntervalSinceReferenceDate: floor(
                value.timeIntervalSinceReferenceDate
            )
        )
    }
}
