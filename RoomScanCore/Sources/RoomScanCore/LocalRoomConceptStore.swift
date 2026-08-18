import Foundation

public struct RoomConceptSetAttachmentBytes: Sendable, Equatable {
    public var attachmentID: String
    public var data: Data

    public init(attachmentID: String, data: Data) {
        self.attachmentID = attachmentID
        self.data = data
    }
}

public struct RoomConceptSetImport: Sendable, Equatable {
    public var conceptSet: RoomConceptSet
    public var attachments: [RoomConceptSetAttachmentBytes]

    public init(conceptSet: RoomConceptSet, attachments: [RoomConceptSetAttachmentBytes]) {
        self.conceptSet = conceptSet
        self.attachments = attachments
    }
}

public protocol RoomConceptStoreFaultInjecting: Sendable {
    func throwIfNeeded(at point: RoomConceptStoreFaultPoint) throws
}

public struct NoRoomConceptStoreFaultInjector: RoomConceptStoreFaultInjecting {
    public init() {}
    public func throwIfNeeded(at point: RoomConceptStoreFaultPoint) throws {}
}

private struct RoomConceptOwnershipRecord: Codable, Sendable, Equatable {
    static let formatVersionValue = "roomscan-concept-store-ownership-v1"

    var formatVersion: String
    var sourceRevision: RoomRedesignSourceRevision
    var conceptSetID: String
    var transactionID: String

    init(
        sourceRevision: RoomRedesignSourceRevision,
        conceptSetID: String,
        transactionID: String
    ) {
        formatVersion = Self.formatVersionValue
        self.sourceRevision = sourceRevision
        self.conceptSetID = conceptSetID
        self.transactionID = transactionID
    }
}

private struct PendingRoomConceptTransaction: Codable, Sendable, Equatable {
    static let formatVersionValue = "roomscan-pending-concept-v1"

    var formatVersion: String
    var sourceRevision: RoomRedesignSourceRevision
    var conceptSetID: String
    var stagingDirectoryName: String
    var transactionID: String

    init(
        sourceRevision: RoomRedesignSourceRevision,
        conceptSetID: String,
        stagingDirectoryName: String,
        transactionID: String
    ) {
        formatVersion = Self.formatVersionValue
        self.sourceRevision = sourceRevision
        self.conceptSetID = conceptSetID
        self.stagingDirectoryName = stagingDirectoryName
        self.transactionID = transactionID
    }
}

/// Serializes all store instances for one canonical source-bound companion
/// directory. The current app has one process writer; this intentionally does
/// not claim coordination with an app extension or another process.
private final class RoomConceptProcessLockRegistry: @unchecked Sendable {
    static let shared = RoomConceptProcessLockRegistry()

    private let registryLock = NSLock()
    private var locks: [String: NSLock] = [:]

    func withLock<Result>(key: String, operation: () throws -> Result) rethrows -> Result {
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

public actor LocalRoomConceptStore {
    private static let ownershipFilename = ".roomscan-concept-ownership.json"
    private static let manifestFilename = "manifest.json"
    private static let attachmentsDirectoryName = "attachments"
    private static let pendingFilename = ".pending-concept.json"

    private let rootURL: URL
    private let sourcePackageRootURL: URL
    private let faultInjector: any RoomConceptStoreFaultInjecting
    private let fileManager = FileManager.default

    public init(
        rootURL: URL,
        sourcePackageRootURL: URL,
        faultInjector: any RoomConceptStoreFaultInjecting = NoRoomConceptStoreFaultInjector()
    ) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.sourcePackageRootURL = sourcePackageRootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.faultInjector = faultInjector
    }

    public func importConceptSet(
        _ materialization: RoomConceptSetImport,
        context: RoomConceptSetValidationContext
    ) async throws -> RoomConceptSet {
        guard !Task.isCancelled else { throw RoomConceptSetError.cancelled }
        try validateConfiguration()
        let canonicalManifest = try RoomConceptSetCanonicalJSON.encode(materialization.conceptSet)
        let validatedConcept = try RoomConceptSetDecoder.decodeCanonical(canonicalManifest, context: context)
        guard validatedConcept == materialization.conceptSet,
              validatedConcept.approvalState == .pending,
              validatedConcept.archiveState == .active
        else {
            throw RoomConceptSetError.invalidValue(
                path: "conceptSet",
                reason: "A new import must begin pending and active without changing its canonical model."
            )
        }
        let attachmentBytes = try validatedAttachmentBytes(
            materialization.attachments,
            for: validatedConcept
        )
        let revisionRoot = try revisionDirectory(context: context)
        let lockKey = revisionRoot.path

        return try RoomConceptProcessLockRegistry.shared.withLock(key: lockKey) {
            guard !Task.isCancelled else { throw RoomConceptSetError.cancelled }
            try prepareRevisionDirectory(revisionRoot, context: context)
            try reconcilePendingLocked(revisionRoot: revisionRoot, context: context)

            let finalURL = revisionRoot.appendingPathComponent(
                validatedConcept.conceptSetID,
                isDirectory: true
            )
            guard !pathExists(finalURL) else {
                throw RoomConceptSetError.conceptAlreadyExists(validatedConcept.conceptSetID)
            }
            let transactionID = UUID().uuidString.lowercased()
            let stageName = ".roomscan-concept-stage-\(validatedConcept.conceptSetID)-\(transactionID)"
            let stageURL = revisionRoot.appendingPathComponent(stageName, isDirectory: true)
            let ownership = RoomConceptOwnershipRecord(
                sourceRevision: context.expectedSourceRevision,
                conceptSetID: validatedConcept.conceptSetID,
                transactionID: transactionID
            )
            let pending = PendingRoomConceptTransaction(
                sourceRevision: context.expectedSourceRevision,
                conceptSetID: validatedConcept.conceptSetID,
                stagingDirectoryName: stageName,
                transactionID: transactionID
            )
            let pendingURL = revisionRoot.appendingPathComponent(Self.pendingFilename)
            var stageCreated = false
            var markerWritten = false

            do {
                try fileManager.createDirectory(at: stageURL, withIntermediateDirectories: false)
                stageCreated = true
                try writeNewCanonical(ownership, to: stageURL.appendingPathComponent(Self.ownershipFilename))
                try canonicalManifest.write(
                    to: stageURL.appendingPathComponent(Self.manifestFilename),
                    options: .withoutOverwriting
                )
                let attachmentsURL = stageURL.appendingPathComponent(
                    Self.attachmentsDirectoryName,
                    isDirectory: true
                )
                try fileManager.createDirectory(at: attachmentsURL, withIntermediateDirectories: false)
                for attachment in validatedConcept.attachments {
                    guard let data = attachmentBytes[attachment.attachmentID] else {
                        throw RoomConceptSetError.invalidValue(
                            path: "attachments",
                            reason: "Every declared attachment must have exactly one input payload."
                        )
                    }
                    let destination = stageURL.appendingPathComponent(attachment.relativePath)
                    try data.write(to: destination, options: .withoutOverwriting)
                }
                _ = try loadConcept(
                    from: stageURL,
                    expectedConceptSetID: validatedConcept.conceptSetID,
                    context: context,
                    expectedOwnership: ownership
                )

                try writeNewCanonical(pending, to: pendingURL)
                markerWritten = true
                try faultInjector.throwIfNeeded(at: .beforePromotion)
                guard !Task.isCancelled else { throw RoomConceptSetError.cancelled }
                guard !pathExists(finalURL) else {
                    throw RoomConceptSetError.conceptAlreadyExists(validatedConcept.conceptSetID)
                }
                try fileManager.moveItem(at: stageURL, to: finalURL)
                stageCreated = false
                try faultInjector.throwIfNeeded(at: .afterPromotionBeforeCommit)
                guard !Task.isCancelled else { throw RoomConceptSetError.cancelled }
                try removeRegularFile(pendingURL)
                markerWritten = false
                return validatedConcept
            } catch {
                do {
                    if markerWritten {
                        try reconcilePendingLocked(revisionRoot: revisionRoot, context: context)
                    } else if stageCreated {
                        try removeOwnedDirectoryIfPresent(stageURL, expectedOwnership: ownership)
                    }
                } catch {
                    throw RoomConceptSetError.unsafeStore(
                        "A failed Concept Set transaction could not be safely reconciled."
                    )
                }
                if error is CancellationError || error as? RoomConceptSetError == .cancelled {
                    throw RoomConceptSetError.cancelled
                }
                if let conceptError = error as? RoomConceptSetError {
                    throw conceptError
                }
                throw RoomConceptSetError.unsafeStore("Unable to atomically import the Concept Set.")
            }
        }
    }

    public func list(
        context: RoomConceptSetValidationContext,
        archiveState: RoomConceptArchiveState? = nil
    ) async throws -> [RoomConceptSet] {
        try validateConfiguration()
        let revisionRoot = try revisionDirectory(context: context)
        return try RoomConceptProcessLockRegistry.shared.withLock(key: revisionRoot.path) {
            guard !Task.isCancelled else { throw RoomConceptSetError.cancelled }
            guard pathExists(revisionRoot) else { return [] }
            try requireDirectoryNonSymlink(revisionRoot)
            try reconcilePendingLocked(revisionRoot: revisionRoot, context: context)
            let entries = try fileManager.contentsOfDirectory(
                at: revisionRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            var concepts: [RoomConceptSet] = []
            for entry in entries {
                try requireDirectoryNonSymlink(entry)
                let concept = try loadConcept(
                    from: entry,
                    expectedConceptSetID: entry.lastPathComponent,
                    context: context
                )
                if archiveState == nil || concept.archiveState == archiveState {
                    concepts.append(concept)
                }
            }
            return concepts.sorted { lhs, rhs in
                if lhs.importedAt == rhs.importedAt { return lhs.conceptSetID < rhs.conceptSetID }
                return lhs.importedAt < rhs.importedAt
            }
        }
    }

    public func load(
        conceptSetID: String,
        context: RoomConceptSetValidationContext
    ) async throws -> RoomConceptSet {
        try validateConfiguration()
        try requireIdentifier(conceptSetID, at: "conceptSetID")
        let revisionRoot = try revisionDirectory(context: context)
        return try RoomConceptProcessLockRegistry.shared.withLock(key: revisionRoot.path) {
            try loadLocked(conceptSetID: conceptSetID, revisionRoot: revisionRoot, context: context)
        }
    }

    public func attachmentData(
        conceptSetID: String,
        attachmentID: String,
        context: RoomConceptSetValidationContext
    ) async throws -> Data {
        try validateConfiguration()
        try requireIdentifier(conceptSetID, at: "conceptSetID")
        try requireIdentifier(attachmentID, at: "attachmentID")
        let revisionRoot = try revisionDirectory(context: context)
        return try RoomConceptProcessLockRegistry.shared.withLock(key: revisionRoot.path) {
            let concept = try loadLocked(
                conceptSetID: conceptSetID,
                revisionRoot: revisionRoot,
                context: context
            )
            guard let attachment = concept.attachments.first(where: { $0.attachmentID == attachmentID }) else {
                throw RoomConceptSetError.invalidValue(
                    path: "attachmentID",
                    reason: "The selected attachment does not belong to this Concept Set."
                )
            }
            let fileURL = revisionRoot
                .appendingPathComponent(conceptSetID, isDirectory: true)
                .appendingPathComponent(attachment.relativePath)
            return try Data(contentsOf: fileURL)
        }
    }

    /// Persists the user-review fields of one existing Concept Set. The full
    /// proposed model is accepted so Core can prove that no source, import, or
    /// attachment identity field was changed at the review boundary.
    public func updateReview(
        _ proposedConceptSet: RoomConceptSet,
        context: RoomConceptSetValidationContext
    ) async throws -> RoomConceptSet {
        try validateConfiguration()
        try requireIdentifier(proposedConceptSet.conceptSetID, at: "conceptSetID")
        let canonicalBytes = try RoomConceptSetCanonicalJSON.encode(proposedConceptSet)
        let validatedProposal = try RoomConceptSetDecoder.decodeCanonical(
            canonicalBytes,
            context: context
        )
        guard validatedProposal == proposedConceptSet else {
            throw RoomConceptSetError.invalidValue(
                path: "reviewUpdate",
                reason: "The proposed review must preserve its canonical Concept Set model."
            )
        }
        let revisionRoot = try revisionDirectory(context: context)

        return try RoomConceptProcessLockRegistry.shared.withLock(key: revisionRoot.path) {
            guard !Task.isCancelled else { throw RoomConceptSetError.cancelled }
            let current = try loadLocked(
                conceptSetID: validatedProposal.conceptSetID,
                revisionRoot: revisionRoot,
                context: context
            )
            try validateReviewTransition(from: current, to: validatedProposal)
            guard current != validatedProposal else { return current }

            let manifestURL = revisionRoot
                .appendingPathComponent(validatedProposal.conceptSetID, isDirectory: true)
                .appendingPathComponent(Self.manifestFilename)
            try canonicalBytes.write(to: manifestURL, options: .atomic)
            let reopened = try loadConcept(
                from: manifestURL.deletingLastPathComponent(),
                expectedConceptSetID: validatedProposal.conceptSetID,
                context: context
            )
            guard reopened == validatedProposal else {
                throw RoomConceptSetError.unsafeStore("Reviewed Concept Set did not reopen exactly.")
            }
            return reopened
        }
    }

    public func archive(
        conceptSetID: String,
        context: RoomConceptSetValidationContext
    ) async throws -> RoomConceptSet {
        try await setArchiveState(.archived, conceptSetID: conceptSetID, context: context)
    }

    public func unarchive(
        conceptSetID: String,
        context: RoomConceptSetValidationContext
    ) async throws -> RoomConceptSet {
        try await setArchiveState(.active, conceptSetID: conceptSetID, context: context)
    }

    public func delete(
        conceptSetID: String,
        context: RoomConceptSetValidationContext
    ) async throws {
        try validateConfiguration()
        try requireIdentifier(conceptSetID, at: "conceptSetID")
        let revisionRoot = try revisionDirectory(context: context)
        try RoomConceptProcessLockRegistry.shared.withLock(key: revisionRoot.path) {
            guard !Task.isCancelled else { throw RoomConceptSetError.cancelled }
            _ = try loadLocked(conceptSetID: conceptSetID, revisionRoot: revisionRoot, context: context)
            let directory = revisionRoot.appendingPathComponent(conceptSetID, isDirectory: true)
            let ownership = try readOwnership(from: directory)
            guard ownership.sourceRevision == context.expectedSourceRevision,
                  ownership.conceptSetID == conceptSetID
            else {
                throw RoomConceptSetError.unsafeStore(
                    "Deletion requires the exact marker-owned Concept Set directory."
                )
            }
            try fileManager.removeItem(at: directory)
        }
    }

    private func setArchiveState(
        _ archiveState: RoomConceptArchiveState,
        conceptSetID: String,
        context: RoomConceptSetValidationContext
    ) async throws -> RoomConceptSet {
        try validateConfiguration()
        try requireIdentifier(conceptSetID, at: "conceptSetID")
        let revisionRoot = try revisionDirectory(context: context)
        return try RoomConceptProcessLockRegistry.shared.withLock(key: revisionRoot.path) {
            guard !Task.isCancelled else { throw RoomConceptSetError.cancelled }
            var concept = try loadLocked(
                conceptSetID: conceptSetID,
                revisionRoot: revisionRoot,
                context: context
            )
            guard concept.archiveState != archiveState else { return concept }
            concept.archiveState = archiveState
            let bytes = try RoomConceptSetCanonicalJSON.encode(concept)
            let validated = try RoomConceptSetDecoder.decodeCanonical(bytes, context: context)
            let manifestURL = revisionRoot
                .appendingPathComponent(conceptSetID, isDirectory: true)
                .appendingPathComponent(Self.manifestFilename)
            try bytes.write(to: manifestURL, options: .atomic)
            let reopened = try loadConcept(
                from: manifestURL.deletingLastPathComponent(),
                expectedConceptSetID: conceptSetID,
                context: context
            )
            guard reopened == validated else {
                throw RoomConceptSetError.unsafeStore("Archived Concept Set did not reopen exactly.")
            }
            return reopened
        }
    }

    private func loadLocked(
        conceptSetID: String,
        revisionRoot: URL,
        context: RoomConceptSetValidationContext
    ) throws -> RoomConceptSet {
        guard pathExists(revisionRoot) else {
            throw RoomConceptSetError.conceptNotFound(conceptSetID)
        }
        try requireDirectoryNonSymlink(revisionRoot)
        try reconcilePendingLocked(revisionRoot: revisionRoot, context: context)
        let directory = revisionRoot.appendingPathComponent(conceptSetID, isDirectory: true)
        guard pathExists(directory) else {
            throw RoomConceptSetError.conceptNotFound(conceptSetID)
        }
        return try loadConcept(
            from: directory,
            expectedConceptSetID: conceptSetID,
            context: context
        )
    }

    private func validatedAttachmentBytes(
        _ inputs: [RoomConceptSetAttachmentBytes],
        for concept: RoomConceptSet
    ) throws -> [String: Data] {
        guard inputs.count == concept.attachments.count,
              inputs.count <= 64,
              Set(inputs.map(\.attachmentID)).count == inputs.count
        else {
            throw RoomConceptSetError.invalidValue(
                path: "attachments",
                reason: "Attachment inputs must close exactly over unique manifest attachment IDs."
            )
        }
        var byID: [String: Data] = [:]
        for input in inputs {
            try requireIdentifier(input.attachmentID, at: "attachments.attachmentID")
            guard let declaration = concept.attachments.first(where: { $0.attachmentID == input.attachmentID }),
                  UInt64(input.data.count) == declaration.byteCount,
                  RoomSHA256.hexDigest(of: input.data) == declaration.sha256
            else {
                throw RoomConceptSetError.invalidValue(
                    path: "attachments",
                    reason: "Attachment bytes must match the exact declared ID, byte count, and SHA-256."
                )
            }
            _ = try RoomConceptImageValidator.validateSanitizedImage(
                input.data,
                mediaType: declaration.mediaType
            )
            byID[input.attachmentID] = input.data
        }
        guard Set(byID.keys) == Set(concept.attachments.map(\.attachmentID)) else {
            throw RoomConceptSetError.invalidValue(
                path: "attachments",
                reason: "Attachment inputs must close exactly over the manifest."
            )
        }
        return byID
    }

    private func validateReviewTransition(
        from current: RoomConceptSet,
        to proposed: RoomConceptSet
    ) throws {
        guard proposed.schemaVersion == current.schemaVersion,
              proposed.conceptSetID == current.conceptSetID,
              proposed.sourceRevision == current.sourceRevision,
              proposed.request == current.request,
              proposed.scope == current.scope,
              proposed.provider == current.provider,
              proposed.sourceAIRoomPackage == current.sourceAIRoomPackage,
              proposed.importProvenance == current.importProvenance,
              proposed.createdAt == current.createdAt,
              proposed.importedAt == current.importedAt,
              proposed.archiveState == current.archiveState,
              proposed.attachments.count == current.attachments.count
        else {
            throw RoomConceptSetError.invalidValue(
                path: "reviewUpdate",
                reason: "Review may change only mappings, approval state, and comments."
            )
        }

        for (stored, reviewed) in zip(current.attachments, proposed.attachments) {
            guard reviewed.attachmentID == stored.attachmentID,
                  reviewed.relativePath == stored.relativePath,
                  reviewed.sha256 == stored.sha256,
                  reviewed.byteCount == stored.byteCount,
                  reviewed.mediaType == stored.mediaType,
                  reviewed.sanitizationProvenance == stored.sanitizationProvenance
            else {
                throw RoomConceptSetError.invalidValue(
                    path: "reviewUpdate.attachments",
                    reason: "Review cannot change attachment identity or provenance."
                )
            }
            guard reviewed.mapping == stored.mapping
                    || reviewed.mapping.status == .manual
                    || reviewed.mapping.status == .unmatched
            else {
                throw RoomConceptSetError.invalidValue(
                    path: "reviewUpdate.attachments.mapping",
                    reason: "Review may retain automatic evidence or choose a manual/unmatched mapping."
                )
            }
        }
    }

    private func loadConcept(
        from directory: URL,
        expectedConceptSetID: String,
        context: RoomConceptSetValidationContext,
        expectedOwnership: RoomConceptOwnershipRecord? = nil
    ) throws -> RoomConceptSet {
        try requireDirectoryNonSymlink(directory)
        let rootChildren = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )
        let expectedRootChildren = Set([
            Self.ownershipFilename,
            Self.manifestFilename,
            Self.attachmentsDirectoryName,
        ])
        guard Set(rootChildren.map(\.lastPathComponent)) == expectedRootChildren else {
            throw RoomConceptSetError.unsafeStore("Concept Set directory contains an undeclared root entry.")
        }
        let ownership = try readOwnership(from: directory)
        guard ownership.sourceRevision == context.expectedSourceRevision,
              ownership.conceptSetID == expectedConceptSetID,
              expectedOwnership == nil || ownership == expectedOwnership
        else {
            throw RoomConceptSetError.unsafeStore("Concept Set ownership does not match its selected source and directory.")
        }
        let manifestURL = directory.appendingPathComponent(Self.manifestFilename)
        try requireRegularNonSymlink(manifestURL)
        let manifestValues = try manifestURL.resourceValues(forKeys: [.fileSizeKey])
        guard let manifestSize = manifestValues.fileSize,
              manifestSize > 0,
              manifestSize <= 1 * 1_024 * 1_024
        else {
            throw RoomConceptSetError.limitExceeded("Stored Concept Set manifest exceeds its v1 limit.")
        }
        let concept = try RoomConceptSetDecoder.decodeCanonical(
            Data(contentsOf: manifestURL),
            context: context
        )
        guard concept.conceptSetID == expectedConceptSetID,
              concept.sourceRevision == ownership.sourceRevision
        else {
            throw RoomConceptSetError.unsafeStore("Concept Set manifest is rebound from its marker-owned directory.")
        }
        let attachmentsURL = directory.appendingPathComponent(
            Self.attachmentsDirectoryName,
            isDirectory: true
        )
        try requireDirectoryNonSymlink(attachmentsURL)
        let attachmentFiles = try fileManager.contentsOfDirectory(
            at: attachmentsURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        )
        let expectedNames = Set(concept.attachments.map {
            String($0.relativePath.dropFirst("attachments/".count))
        })
        guard Set(attachmentFiles.map(\.lastPathComponent)) == expectedNames else {
            throw RoomConceptSetError.unsafeStore("Stored attachment closure differs from the Concept Set manifest.")
        }
        let declarationByName = Dictionary(uniqueKeysWithValues: concept.attachments.map {
            (String($0.relativePath.dropFirst("attachments/".count)), $0)
        })
        for file in attachmentFiles {
            guard let declaration = declarationByName[file.lastPathComponent] else {
                throw RoomConceptSetError.unsafeStore("Stored attachment is undeclared.")
            }
            try requireRegularNonSymlink(file)
            let values = try file.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize,
                  size > 0,
                  UInt64(size) == declaration.byteCount,
                  try RoomSHA256.hexDigest(ofFile: file) == declaration.sha256
            else {
                throw RoomConceptSetError.unsafeStore("Stored attachment identity differs from its manifest.")
            }
            _ = try RoomConceptImageValidator.validateSanitizedImage(
                Data(contentsOf: file),
                mediaType: declaration.mediaType
            )
        }
        return concept
    }

    private func reconcilePendingLocked(
        revisionRoot: URL,
        context: RoomConceptSetValidationContext
    ) throws {
        let markerURL = revisionRoot.appendingPathComponent(Self.pendingFilename)
        guard pathExists(markerURL) else { return }
        let pending: PendingRoomConceptTransaction = try readCanonical(PendingRoomConceptTransaction.self, from: markerURL)
        guard pending.formatVersion == PendingRoomConceptTransaction.formatVersionValue,
              pending.sourceRevision == context.expectedSourceRevision,
              RoomPathValidation.isSafeStableIdentifier(pending.conceptSetID),
              RoomPathValidation.isSafeStableIdentifier(pending.transactionID),
              pending.stagingDirectoryName == ".roomscan-concept-stage-\(pending.conceptSetID)-\(pending.transactionID)"
        else {
            throw RoomConceptSetError.unsafeStore("Pending Concept Set marker is invalid or rebound.")
        }
        let expectedOwnership = RoomConceptOwnershipRecord(
            sourceRevision: pending.sourceRevision,
            conceptSetID: pending.conceptSetID,
            transactionID: pending.transactionID
        )
        let stageURL = revisionRoot.appendingPathComponent(
            pending.stagingDirectoryName,
            isDirectory: true
        )
        let finalURL = revisionRoot.appendingPathComponent(
            pending.conceptSetID,
            isDirectory: true
        )
        try removeOwnedDirectoryIfPresent(finalURL, expectedOwnership: expectedOwnership)
        try removeOwnedDirectoryIfPresent(stageURL, expectedOwnership: expectedOwnership)
        try removeRegularFile(markerURL)
    }

    private func removeOwnedDirectoryIfPresent(
        _ directory: URL,
        expectedOwnership: RoomConceptOwnershipRecord
    ) throws {
        guard pathExists(directory) else { return }
        try requireDirectoryNonSymlink(directory)
        let ownership = try readOwnership(from: directory)
        guard ownership == expectedOwnership else {
            throw RoomConceptSetError.unsafeStore(
                "A pending marker cannot remove a directory it does not exactly own."
            )
        }
        try fileManager.removeItem(at: directory)
    }

    private func readOwnership(from directory: URL) throws -> RoomConceptOwnershipRecord {
        let url = directory.appendingPathComponent(Self.ownershipFilename)
        let ownership: RoomConceptOwnershipRecord = try readCanonical(RoomConceptOwnershipRecord.self, from: url)
        guard ownership.formatVersion == RoomConceptOwnershipRecord.formatVersionValue,
              RoomPathValidation.isSafeStableIdentifier(ownership.conceptSetID),
              RoomPathValidation.isSafeStableIdentifier(ownership.transactionID)
        else {
            throw RoomConceptSetError.unsafeStore("Concept Set ownership record is invalid.")
        }
        try ownership.sourceRevision.validate()
        return ownership
    }

    private func revisionDirectory(context: RoomConceptSetValidationContext) throws -> URL {
        try context.expectedSourceRevision.validate()
        try requireIdentifier(context.expectedSourceRevision.projectID, at: "sourceRevision.projectID")
        try requireIdentifier(context.expectedSourceRevision.revisionID, at: "sourceRevision.revisionID")
        let revisionRoot = rootURL
            .appendingPathComponent(context.expectedSourceRevision.projectID, isDirectory: true)
            .appendingPathComponent(context.expectedSourceRevision.revisionID, isDirectory: true)
            .appendingPathComponent(
                context.expectedSourceRevision.revisionManifestSHA256,
                isDirectory: true
            )
        try requireExistingStorePathComponentsNonSymlink(through: revisionRoot)
        return revisionRoot
    }

    private func prepareRevisionDirectory(
        _ revisionRoot: URL,
        context: RoomConceptSetValidationContext
    ) throws {
        try prepareDirectory(rootURL)
        let project = rootURL.appendingPathComponent(
            context.expectedSourceRevision.projectID,
            isDirectory: true
        )
        try prepareDirectory(project)
        let revision = project.appendingPathComponent(
            context.expectedSourceRevision.revisionID,
            isDirectory: true
        )
        try prepareDirectory(revision)
        try prepareDirectory(revisionRoot)
    }

    private func prepareDirectory(_ url: URL) throws {
        if pathExists(url) {
            try requireDirectoryNonSymlink(url)
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
            try requireDirectoryNonSymlink(url)
        }
    }

    private func validateConfiguration() throws {
        let rootComponents = rootURL.pathComponents
        let sourceComponents = sourcePackageRootURL.pathComponents
        let rootInsideSource = hasPathPrefix(rootComponents, prefix: sourceComponents)
        let sourceInsideRoot = hasPathPrefix(sourceComponents, prefix: rootComponents)
        guard !rootInsideSource, !sourceInsideRoot else {
            throw RoomConceptSetError.sourceStoreOverlap
        }
        guard pathExists(sourcePackageRootURL) else {
            throw RoomConceptSetError.unsafeStore("The immutable source package root does not exist.")
        }
        try requireDirectoryNonSymlink(sourcePackageRootURL)
    }

    private func hasPathPrefix(_ path: [String], prefix: [String]) -> Bool {
        path.count >= prefix.count && zip(prefix, path).allSatisfy { $0 == $1 }
    }

    private func requireExistingStorePathComponentsNonSymlink(through target: URL) throws {
        let rootComponents = rootURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents
        guard hasPathPrefix(targetComponents, prefix: rootComponents) else {
            throw RoomConceptSetError.unsafeStore("Concept Set path escapes its configured store root.")
        }

        guard pathExists(rootURL) else { return }
        try requireDirectoryNonSymlink(rootURL)

        var current = rootURL
        for component in targetComponents.dropFirst(rootComponents.count) {
            current.appendPathComponent(component, isDirectory: true)
            guard pathExists(current) else { break }
            try requireDirectoryNonSymlink(current)
        }
    }

    private func requireIdentifier(_ value: String, at path: String) throws {
        guard RoomPathValidation.isSafeStableIdentifier(value) else {
            throw RoomConceptSetError.invalidValue(path: path, reason: "Value must be a stable ASCII identifier.")
        }
    }

    private func requireDirectoryNonSymlink(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw RoomConceptSetError.unsafeStore("Store directory is missing, non-directory, or symbolic.")
        }
    }

    private func requireRegularNonSymlink(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw RoomConceptSetError.unsafeStore("Store file is missing, non-regular, or symbolic.")
        }
    }

    private func pathExists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func writeNewCanonical<T: Encodable>(_ value: T, to url: URL) throws {
        let bytes = try RoomConceptSetCanonicalJSON.encode(value)
        try bytes.write(to: url, options: .withoutOverwriting)
        try requireRegularNonSymlink(url)
    }

    private func readCanonical<T: Codable>(_ type: T.Type, from url: URL) throws -> T {
        try requireRegularNonSymlink(url)
        let data = try Data(contentsOf: url)
        let value: T
        do {
            value = try RoomJSONCoding.makeDecoder().decode(T.self, from: data)
        } catch {
            throw RoomConceptSetError.unsafeStore("Store transaction metadata is invalid.")
        }
        guard try RoomConceptSetCanonicalJSON.encode(value) == data else {
            throw RoomConceptSetError.unsafeStore("Store transaction metadata is noncanonical.")
        }
        return value
    }

    private func removeRegularFile(_ url: URL) throws {
        try requireRegularNonSymlink(url)
        try fileManager.removeItem(at: url)
    }
}
