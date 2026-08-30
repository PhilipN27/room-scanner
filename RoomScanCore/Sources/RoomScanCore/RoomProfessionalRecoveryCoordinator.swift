import Foundation

/// Fail-closed coordinator errors for a durable local professional recovery
/// transaction. The journal deliberately stores only stable public recovery
/// identifiers and archive descriptors; it never records caller paths, URLs,
/// room bytes, or provider credentials.
public enum RoomProfessionalRecoveryCoordinatorError: Error, Sendable, Equatable {
    case invalidTransaction(String)
    case unsafeScratchState(String)
    case transactionNotFound(String)
    case transactionConflict(String)
    case packageRecoveryMismatch(String)
    case injectedFailure(RoomProfessionalRecoveryFaultPoint)
}

/// A stable caller-persistable handle returned by `prepare`. No live package
/// mutation can occur until a caller has this value and explicitly calls
/// `resume`.
public struct RoomProfessionalRecoveryTransaction: Sendable, Equatable {
    public let transactionID: String

    public init(transactionID: String) throws {
        guard RoomPathValidation.isSafeStableIdentifier(transactionID) else {
            throw RoomProfessionalRecoveryCoordinatorError.invalidTransaction(
                "Professional recovery transaction identifiers must be stable ASCII identifiers."
            )
        }
        self.transactionID = transactionID
    }
}

/// Original recovery preserves the archive project identifier. Recover-as-copy
/// requires a caller-held stable identifier so retries after package promotion
/// converge on one exact destination instead of allocating another copy.
public enum RoomProfessionalRecoveryTarget: Sendable, Equatable {
    case original
    case recoveredCopy(projectID: String)
}

public struct RoomProfessionalRecoveryResult: Sendable, Equatable {
    public let transaction: RoomProfessionalRecoveryTransaction
    public let projectSummary: RoomProjectSummary
    public let recoveredAsCopy: Bool
    /// Exact canonical AI-ready package provenance for same-ID recovery only.
    /// Task 5 persists these bytes through its app-owned provenance registry.
    public let conceptSourcePackageProvenance: [RoomProfessionalConceptSourcePackageProvenanceSnapshot]
    /// Never-silent transport/copy adjustments that callers present before
    /// treating a recovered Concept mapping as automatic.
    public let conceptMappingAdjustments: [RoomProfessionalConceptMappingAdjustment]

    public init(
        transaction: RoomProfessionalRecoveryTransaction,
        projectSummary: RoomProjectSummary,
        recoveredAsCopy: Bool,
        conceptSourcePackageProvenance: [RoomProfessionalConceptSourcePackageProvenanceSnapshot] = [],
        conceptMappingAdjustments: [RoomProfessionalConceptMappingAdjustment] = []
    ) {
        self.transaction = transaction
        self.projectSummary = projectSummary
        self.recoveredAsCopy = recoveredAsCopy
        self.conceptSourcePackageProvenance = conceptSourcePackageProvenance
        self.conceptMappingAdjustments = conceptMappingAdjustments
    }
}

/// Deterministic restart boundaries used only by Core tests. Each point is
/// deliberately after the named real operation and before the outer journal
/// phase moves forward, so a recreated coordinator must exercise idempotency.
public enum RoomProfessionalRecoveryFaultPoint: String, Sendable, Equatable, CaseIterable {
    case afterTransactionDirectoryCreationBeforeOwnershipMarker
    case beforePackageCommit
    case afterPackagePromotionBeforePhaseUpdate
    case afterDurablePackageCommitBeforeFirstCompanion
    case afterRedesignPromotionBeforePhaseUpdate
    case afterConceptPromotionBeforePhaseUpdate
}

public protocol RoomProfessionalRecoveryFaultInjecting: Sendable {
    func throwIfNeeded(at point: RoomProfessionalRecoveryFaultPoint) throws
}

public struct NoRoomProfessionalRecoveryFaultInjector: RoomProfessionalRecoveryFaultInjecting {
    public init() {}

    public func throwIfNeeded(at point: RoomProfessionalRecoveryFaultPoint) throws {}
}

public struct FailingRoomProfessionalRecoveryFaultInjector: RoomProfessionalRecoveryFaultInjecting {
    public let point: RoomProfessionalRecoveryFaultPoint

    public init(point: RoomProfessionalRecoveryFaultPoint) {
        self.point = point
    }

    public func throwIfNeeded(at point: RoomProfessionalRecoveryFaultPoint) throws {
        guard point == self.point else { return }
        throw RoomProfessionalRecoveryCoordinatorError.injectedFailure(point)
    }
}

/// Durable, package-first recovery for one strict professional working set.
/// It is intentionally a narrow Core primitive: it stages and revalidates the
/// outer archive every resume, promotes only through the existing package
/// recovery boundary, and then idempotently restores additive companions.
public actor RoomProfessionalRecoveryCoordinator {
    private static let transactionPrefix = ".roomscan-professional-recovery-"
    private static let stagedArchiveFilename = "working-set.zip"
    private static let journalFilename = "recovery-journal.json"
    private static let ownershipMarkerFilename = ".roomscan-professional-recovery-ownership.json"
    private static let verificationMarkerFilename = ".roomscan-professional-recovery-verification.json"
    private static let verificationEnvelopeDirectoryName = "envelope"

    private let projectStore: LocalRoomProjectStore
    private let redesignStore: LocalRoomRedesignStore
    private let conceptStore: LocalRoomConceptStore
    private let scratchRootURL: URL
    private let faultInjector: any RoomProfessionalRecoveryFaultInjecting
    private let fileManager = FileManager.default

    public init(
        projectStore: LocalRoomProjectStore,
        redesignStore: LocalRoomRedesignStore,
        conceptStore: LocalRoomConceptStore,
        scratchRootURL: URL,
        faultInjector: any RoomProfessionalRecoveryFaultInjecting = NoRoomProfessionalRecoveryFaultInjector()
    ) {
        self.projectStore = projectStore
        self.redesignStore = redesignStore
        self.conceptStore = conceptStore
        self.scratchRootURL = scratchRootURL.standardizedFileURL
        self.faultInjector = faultInjector
    }

    /// Copies and fully validates a caller-provided working set into a private
    /// transaction directory, writes its canonical marker, then returns the
    /// stable identifier. This method never mutates a live room package or a
    /// companion store.
    public func prepare(
        archiveURL: URL,
        expectedDescriptor: RoomProfessionalWorkingSetDescriptor,
        target: RoomProfessionalRecoveryTarget
    ) async throws -> RoomProfessionalRecoveryTransaction {
        try expectedDescriptor.validate()
        let transaction = try RoomProfessionalRecoveryTransaction(
            transactionID: "professional-recovery-\(UUID().uuidString.lowercased())"
        )
        let ownershipToken = UUID().uuidString.lowercased()
        let journal = try RoomProfessionalRecoveryJournal(
            transactionID: transaction.transactionID,
            ownershipToken: ownershipToken,
            descriptor: expectedDescriptor,
            target: target,
            phase: .prepared
        )
        let scratchRoot = try ensureScratchRoot()
        let transactionURL = try transactionURL(for: transaction, scratchRoot: scratchRoot)
        guard !pathExists(transactionURL), !isSymbolicLink(transactionURL) else {
            throw RoomProfessionalRecoveryCoordinatorError.transactionConflict(transaction.transactionID)
        }
        do {
            try fileManager.createDirectory(at: transactionURL, withIntermediateDirectories: false)
        } catch {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Unable to create the private professional recovery transaction directory."
            )
        }
        do {
            // A fault or crash before this marker is durable deliberately
            // leaves the empty generated candidate in place. It is unsafe to
            // delete a path that another process could have replaced.
            try faultInjector.throwIfNeeded(at: .afterTransactionDirectoryCreationBeforeOwnershipMarker)
            try writeNewOwnershipMarker(
                transaction: transaction,
                ownershipToken: ownershipToken,
                transactionURL: transactionURL
            )
            try stageArchive(
                archiveURL,
                expectedDescriptor: expectedDescriptor,
                transaction: transaction,
                ownershipToken: ownershipToken,
                into: transactionURL
            )
            let staged = try await revalidateStagedArchive(journal: journal, transactionURL: transactionURL)
            defer { cleanupVerificationStage(staged.verificationStage) }
            try writeNewJournal(journal, transactionURL: transactionURL)
            return transaction
        } catch {
            cleanupOwnedTransactionIfStillOwned(
                transaction: transaction,
                ownershipToken: ownershipToken,
                transactionURL: transactionURL
            )
            throw error
        }
    }

    /// Revalidates staged archive bytes and their complete package/companion
    /// closure before every phase. Package recovery always happens before any
    /// redesign or Concept Set write; each live companion write is idempotent.
    public func resume(
        _ transaction: RoomProfessionalRecoveryTransaction
    ) async throws -> RoomProfessionalRecoveryResult {
        let scratchRoot = try ensureScratchRoot()
        let transactionURL = try transactionURL(for: transaction, scratchRoot: scratchRoot)
        var journal = try readJournal(transaction: transaction, transactionURL: transactionURL)
        let staged = try await revalidateStagedArchive(journal: journal, transactionURL: transactionURL)
        defer { cleanupVerificationStage(staged.verificationStage) }
        let targetPlan = try targetPlan(
            for: journal,
            sourceRevision: staged.extraction.manifest.sourceRevision
        )

        if journal.phase == .prepared {
            let workspaceURL = try recoveryWorkspaceURL(in: transactionURL)
            let preparation = try await projectStore.prepareRecovery(
                archiveURL: staged.packageArchiveURL,
                expectedCloudDescriptor: staged.extraction.packageDescriptor,
                into: workspaceURL
            )
            try faultInjector.throwIfNeeded(at: .beforePackageCommit)
            _ = try await projectStore.commitPreparedRecovery(
                preparation,
                conflictPolicy: targetPlan.conflictPolicy,
                recoveredCopyProjectID: targetPlan.recoveredCopyProjectID
            )
            // This intentionally comes after the real package promotion. If
            // it throws, the journal remains `.prepared`; resume reconstructs
            // the staged package and reaches the package store's exact retry.
            try faultInjector.throwIfNeeded(at: .afterPackagePromotionBeforePhaseUpdate)
            journal.phase = .packageCommitted
            try replaceJournal(journal, transactionURL: transactionURL)
        }

        let target = try await resolvedTargetBinding(
            plan: targetPlan,
            sourceRevision: staged.extraction.manifest.sourceRevision
        )

        if journal.phase == .packageCommitted {
            try faultInjector.throwIfNeeded(at: .afterDurablePackageCommitBeforeFirstCompanion)
            if let redesignSnapshot = staged.redesignSnapshot {
                try await redesignStore.restoreSnapshot(
                    redesignSnapshot,
                    expectedSourceRevision: target.sourceRevision,
                    recoveredCopyMapping: target.mapping
                )
                try faultInjector.throwIfNeeded(at: .afterRedesignPromotionBeforePhaseUpdate)
            }
            journal.phase = .redesignCommitted
            try replaceJournal(journal, transactionURL: transactionURL)
        }

        if journal.phase == .redesignCommitted {
            let context = try conceptValidationContext(
                sourceRevision: target.sourceRevision,
                redesignSnapshot: staged.redesignSnapshot,
                recoveredCopyMapping: target.mapping,
                sourcePackageProvenance: target.mapping == nil
                    ? staged.conceptSourcePackageProvenance
                    : []
            )
            // A single complete snapshot keeps LocalRoomConceptStore's
            // process-wide revision lock across all existing-state preflight
            // and every missing-set promotion. Restoring one set at a time
            // would release the lock between A and B, allowing another store
            // to commit a conflicting B before this durable phase advances.
            _ = try await conceptStore.restoreSnapshot(
                staged.conceptSnapshot,
                context: context,
                recoveredCopyMapping: target.mapping
            )
            try faultInjector.throwIfNeeded(at: .afterConceptPromotionBeforePhaseUpdate)
            journal.phase = .conceptsCommitted
            try replaceJournal(journal, transactionURL: transactionURL)
        }

        let conceptMappingAdjustments = try recoveryResultMappingAdjustments(
            staged: staged,
            target: target
        )
        return try await makeResult(
            transaction: transaction,
            target: target,
            conceptSourcePackageProvenance: target.mapping == nil
                ? staged.conceptSourcePackageProvenance
                : [],
            conceptMappingAdjustments: conceptMappingAdjustments
        )
    }

    /// Deletes a completed transaction only after the caller has durably
    /// acknowledged the result. Until this succeeds, `resume` remains an
    /// exact retry path. Unknown, unmarked, and incomplete directories are
    /// intentionally never removed through this API.
    public func discardCompleted(
        _ transaction: RoomProfessionalRecoveryTransaction
    ) throws {
        let scratchRoot = try ensureScratchRoot()
        let transactionURL = try transactionURL(for: transaction, scratchRoot: scratchRoot)
        let journal = try readJournal(transaction: transaction, transactionURL: transactionURL)
        guard journal.phase == .conceptsCommitted else {
            throw RoomProfessionalRecoveryCoordinatorError.invalidTransaction(
                "Professional recovery transactions can be discarded only after all companions commit."
            )
        }
        try removeOwnedTransaction(
            transaction: transaction,
            ownershipToken: journal.ownershipToken,
            transactionURL: transactionURL
        )
    }

    private func ensureScratchRoot() throws -> URL {
        let root = scratchRootURL.standardizedFileURL
        guard root.isFileURL else {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "The configured recovery scratch root is not a local file URL."
            )
        }
        let parent = root.deletingLastPathComponent()
        try requireRealDirectory(parent, message: "The configured recovery scratch parent is unsafe.")
        if pathExists(root) || isSymbolicLink(root) {
            try requireRealDirectory(root, message: "The configured recovery scratch root is unsafe.")
        } else {
            do {
                try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
            } catch {
                throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                    "Unable to create the configured recovery scratch root."
                )
            }
            try requireRealDirectory(root, message: "The configured recovery scratch root is unsafe.")
        }
        return root
    }

    private func transactionURL(
        for transaction: RoomProfessionalRecoveryTransaction,
        scratchRoot: URL
    ) throws -> URL {
        let directoryName = Self.transactionPrefix + transaction.transactionID
        guard RoomPathValidation.isSafeStableIdentifier(transaction.transactionID),
              RoomPathValidation.isSafeRelativePath(directoryName)
        else {
            throw RoomProfessionalRecoveryCoordinatorError.invalidTransaction(transaction.transactionID)
        }
        return scratchRoot.appendingPathComponent(directoryName, isDirectory: true)
    }

    private func assertTransactionDirectoryShape(
        _ transactionURL: URL,
        transaction: RoomProfessionalRecoveryTransaction
    ) throws {
        guard transactionURL.deletingLastPathComponent().standardizedFileURL == scratchRootURL,
              transactionURL.lastPathComponent == Self.transactionPrefix + transaction.transactionID
        else {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Professional recovery transaction path escapes the configured scratch root."
            )
        }
        try requireRealDirectory(transactionURL, message: "Professional recovery transaction directory is unsafe.")
    }

    private func assertOwnedTransactionDirectory(
        _ transactionURL: URL,
        transaction: RoomProfessionalRecoveryTransaction,
        ownershipToken: String
    ) throws {
        try assertTransactionDirectoryShape(transactionURL, transaction: transaction)
        let marker = try readOwnershipMarker(transactionURL: transactionURL)
        guard marker.transactionID == transaction.transactionID,
              marker.ownershipToken == ownershipToken
        else {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Professional recovery ownership marker does not match this durable transaction."
            )
        }
    }

    private func stageArchive(
        _ archiveURL: URL,
        expectedDescriptor: RoomProfessionalWorkingSetDescriptor,
        transaction: RoomProfessionalRecoveryTransaction,
        ownershipToken: String,
        into transactionURL: URL
    ) throws {
        try assertOwnedTransactionDirectory(
            transactionURL,
            transaction: transaction,
            ownershipToken: ownershipToken
        )
        try RoomProfessionalArchiveSupport.verifyArchive(
            archiveURL,
            expectedSHA256: expectedDescriptor.archiveSHA256,
            expectedByteCount: expectedDescriptor.archiveByteCount
        )
        let destination = transactionURL.appendingPathComponent(Self.stagedArchiveFilename)
        guard !pathExists(destination), !isSymbolicLink(destination) else {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Professional recovery archive stage already exists."
            )
        }
        do {
            try fileManager.copyItem(at: archiveURL, to: destination)
        } catch {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Unable to stage the professional working set archive."
            )
        }
        try RoomProfessionalArchiveSupport.verifyArchive(
            destination,
            expectedSHA256: expectedDescriptor.archiveSHA256,
            expectedByteCount: expectedDescriptor.archiveByteCount
        )
    }

    private func revalidateStagedArchive(
        journal: RoomProfessionalRecoveryJournal,
        transactionURL: URL
    ) async throws -> StagedProfessionalRecovery {
        let transaction = try RoomProfessionalRecoveryTransaction(transactionID: journal.transactionID)
        try assertOwnedTransactionDirectory(
            transactionURL,
            transaction: transaction,
            ownershipToken: journal.ownershipToken
        )
        let stagedArchiveURL = transactionURL.appendingPathComponent(Self.stagedArchiveFilename)
        try RoomProfessionalArchiveSupport.verifyArchive(
            stagedArchiveURL,
            expectedSHA256: journal.descriptor.archiveSHA256,
            expectedByteCount: journal.descriptor.archiveByteCount
        )
        let verificationStage = try createVerificationStage(
            transaction: transaction,
            transactionURL: transactionURL
        )
        do {
            let extraction = try await RoomProfessionalWorkingSetArchive.extractAndVerify(
                archiveURL: stagedArchiveURL,
                expectedDescriptor: journal.descriptor,
                into: verificationStage.extractionURL
            )
            let snapshots = try companionSnapshots(
                from: extraction,
                extractionURL: verificationStage.extractionURL
            )
            let packageArchiveURL = verificationStage.extractionURL.appendingPathComponent(
                RoomProfessionalWorkingSetArchive.packageBackupEntryPath
            )
            try RoomProfessionalArchiveSupport.verifyArchive(
                packageArchiveURL,
                expectedSHA256: extraction.packageDescriptor.archiveSHA256,
                expectedByteCount: extraction.packageDescriptor.archiveByteCount
            )
            return StagedProfessionalRecovery(
                extraction: extraction,
                packageArchiveURL: packageArchiveURL,
                redesignSnapshot: snapshots.redesign,
                conceptSnapshot: snapshots.concepts,
                conceptSourcePackageProvenance: snapshots.sourcePackageProvenance,
                verificationStage: verificationStage
            )
        } catch {
            cleanupVerificationStage(verificationStage)
            throw error
        }
    }

    private func companionSnapshots(
        from extraction: RoomProfessionalWorkingSetExtraction,
        extractionURL: URL
    ) throws -> (
        redesign: RoomProfessionalRedesignSnapshot?,
        concepts: RoomProfessionalConceptSnapshot,
        sourcePackageProvenance: [RoomProfessionalConceptSourcePackageProvenanceSnapshot]
    ) {
        let manifest = extraction.manifest
        let redesignEntries = manifest.entries.filter {
            if case .redesignCompanion = $0.kind { return true }
            return false
        }
        guard redesignEntries.count <= 1 else {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Working-set companion closure contains multiple redesign entries."
            )
        }
        let redesign: RoomProfessionalRedesignSnapshot?
        if let entry = redesignEntries.first {
            let data = try RoomProfessionalArchiveSupport.readBoundedRegularFile(
                extractionURL.appendingPathComponent(entry.path),
                maximumBytes: RoomBackupLimits.maximumManifestBytes,
                at: entry.path
            )
            redesign = try RoomProfessionalRedesignSnapshot(
                sourceRevision: manifest.sourceRevision,
                canonicalDocumentData: data,
                documentSHA256: RoomSHA256.hexDigest(of: data)
            )
        } else {
            redesign = nil
        }

        let attachmentEntries = manifest.entries.filter {
            if case .conceptSetAttachment = $0.kind { return true }
            return false
        }
        let attachmentsByPath = Dictionary(
            uniqueKeysWithValues: attachmentEntries.map { ($0.path, $0) }
        )
        guard attachmentsByPath.count == attachmentEntries.count else {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Working-set Concept attachment paths collide."
            )
        }
        var conceptSets: [RoomProfessionalConceptSetSnapshot] = []
        let manifestEntries = manifest.entries.filter {
            if case .conceptSetManifest = $0.kind { return true }
            return false
        }
        for entry in manifestEntries.sorted(by: { $0.path < $1.path }) {
            let pathComponents = entry.path.split(separator: "/").map(String.init)
            guard pathComponents.count == 4 else {
                throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                    "Working-set Concept manifest path is malformed."
                )
            }
            let conceptSetID = pathComponents[2]
            let manifestData = try RoomProfessionalArchiveSupport.readBoundedRegularFile(
                extractionURL.appendingPathComponent(entry.path),
                maximumBytes: RoomBackupLimits.maximumManifestBytes,
                at: entry.path
            )
            let concept = try RoomConceptSetDecoder.decodeCanonicalIntrinsic(
                manifestData,
                expectedSourceRevision: manifest.sourceRevision
            )
            guard concept.conceptSetID == conceptSetID else {
                throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                    "Working-set Concept manifest does not match its reserved companion path."
                )
            }
            let attachments = try concept.attachments.map { declaration in
                let path = "companions/concept-sets/\(conceptSetID)/\(declaration.relativePath)"
                guard let entry = attachmentsByPath[path] else {
                    throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                        "Working-set Concept attachment closure is incomplete."
                    )
                }
                let data = try RoomProfessionalArchiveSupport.readBoundedRegularFile(
                    extractionURL.appendingPathComponent(path),
                    maximumBytes: RoomConceptImageLimits.v1MaximumBytes,
                    at: path
                )
                return try RoomProfessionalConceptAttachmentSnapshot(
                    attachmentID: declaration.attachmentID,
                    relativePath: declaration.relativePath,
                    mediaType: entry.mediaType,
                    data: data,
                    byteCount: UInt64(data.count),
                    sha256: RoomSHA256.hexDigest(of: data)
                )
            }
            conceptSets.append(try RoomProfessionalConceptSetSnapshot(
                sourceRevision: manifest.sourceRevision,
                conceptSetID: conceptSetID,
                canonicalManifestData: manifestData,
                manifestSHA256: RoomSHA256.hexDigest(of: manifestData),
                attachments: attachments
            ))
        }
        let concepts = try RoomProfessionalConceptSnapshot(
            sourceRevision: manifest.sourceRevision,
            conceptSets: conceptSets.sorted { $0.conceptSetID < $1.conceptSetID }
        )
        let provenanceEntries = manifest.entries.filter {
            if case .conceptSourcePackageProvenance = $0.kind { return true }
            return false
        }
        let sourcePackageProvenance = try provenanceEntries.sorted(by: { $0.path < $1.path }).map { entry in
            let data = try RoomProfessionalArchiveSupport.readBoundedRegularFile(
                extractionURL.appendingPathComponent(entry.path),
                maximumBytes: RoomBackupLimits.maximumManifestBytes,
                at: entry.path
            )
            return try RoomProfessionalConceptSourcePackageProvenanceSnapshot(
                sourceRevision: manifest.sourceRevision,
                canonicalManifestData: data
            )
        }
        return (redesign, concepts, sourcePackageProvenance)
    }

    private func recoveryWorkspaceURL(in transactionURL: URL) throws -> URL {
        let workspace = transactionURL.appendingPathComponent("package-recovery", isDirectory: true)
        if pathExists(workspace) || isSymbolicLink(workspace) {
            try requireRealDirectory(workspace, message: "Professional package recovery workspace is unsafe.")
            return workspace
        }
        do {
            try fileManager.createDirectory(at: workspace, withIntermediateDirectories: false)
        } catch {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Unable to create professional package recovery workspace."
            )
        }
        try requireRealDirectory(workspace, message: "Professional package recovery workspace is unsafe.")
        return workspace
    }

    private func targetPlan(
        for journal: RoomProfessionalRecoveryJournal,
        sourceRevision: RoomRedesignSourceRevision
    ) throws -> RecoveryTargetPlan {
        guard sourceRevision.projectID == journal.descriptor.projectID,
              sourceRevision.revisionID == journal.descriptor.headRevisionID
        else {
            throw RoomProfessionalRecoveryCoordinatorError.packageRecoveryMismatch(
                "Working-set source revision does not match its durable descriptor."
            )
        }
        switch journal.recoveryTarget {
        case .original:
            return RecoveryTargetPlan(
                projectID: sourceRevision.projectID,
                conflictPolicy: .failIfDivergent,
                recoveredCopyProjectID: nil
            )
        case let .recoveredCopy(projectID):
            return RecoveryTargetPlan(
                projectID: projectID,
                conflictPolicy: .recoverAsCopy,
                recoveredCopyProjectID: projectID
            )
        }
    }

    /// Reads the post-promotion package rather than reconstructing a copy
    /// source record from caller data. The package rewrite changes the two
    /// document digests, so only this store-derived binding may authorize
    /// redesign or Concept Set rebinding.
    private func resolvedTargetBinding(
        plan: RecoveryTargetPlan,
        sourceRevision: RoomRedesignSourceRevision
    ) async throws -> RecoveryTargetBinding {
        let package = try await projectStore.load(projectID: plan.projectID)
        guard package.manifest.projectID == plan.projectID,
              package.manifest.headRevisionID == sourceRevision.revisionID,
              package.manifest.schemaVersion == sourceRevision.packageSchemaVersion
        else {
            throw RoomProfessionalRecoveryCoordinatorError.packageRecoveryMismatch(
                "Recovered package identity or head does not match the staged working set."
            )
        }
        let liveBinding = try await projectStore.redesignSourceRevisionBinding(
            projectID: plan.projectID,
            revisionID: sourceRevision.revisionID
        )
        switch plan.conflictPolicy {
        case .failIfDivergent:
            guard liveBinding == sourceRevision else {
                throw RoomProfessionalRecoveryCoordinatorError.packageRecoveryMismatch(
                    "Recovered package revision bytes do not match the staged immutable source binding."
                )
            }
            return RecoveryTargetBinding(
                projectID: plan.projectID,
                sourceRevision: liveBinding,
                conflictPolicy: plan.conflictPolicy,
                recoveredCopyProjectID: nil,
                mapping: nil
            )
        case .recoverAsCopy:
            let mapping = try RoomProfessionalRecoveredCopyMapping.storeDerived(
                original: sourceRevision,
                recoveredCopy: liveBinding
            )
            return RecoveryTargetBinding(
                projectID: plan.projectID,
                sourceRevision: liveBinding,
                conflictPolicy: plan.conflictPolicy,
                recoveredCopyProjectID: plan.recoveredCopyProjectID,
                mapping: mapping
            )
        }
    }

    private func conceptValidationContext(
        sourceRevision: RoomRedesignSourceRevision,
        redesignSnapshot: RoomProfessionalRedesignSnapshot?,
        recoveredCopyMapping: RoomProfessionalRecoveredCopyMapping?,
        sourcePackageProvenance: [RoomProfessionalConceptSourcePackageProvenanceSnapshot]
    ) throws -> RoomConceptSetValidationContext {
        let cameraIDs: [String]
        if let redesignSnapshot {
            let original = try redesignSnapshot.validatedDocument()
            let target = try RoomProfessionalRecoveryRebinding.targetSourceRevision(
                original: redesignSnapshot.sourceRevision,
                expected: sourceRevision,
                mapping: recoveredCopyMapping
            )
            let document: RoomLocalRedesignExtensionV2
            if target == original.sourceRevision {
                document = original
            } else {
                guard let recoveredCopyMapping else {
                    throw RoomProfessionalRecoveryError.sourceRevisionMismatch(
                        "A recovered-copy Concept context requires the explicit copy mapping."
                    )
                }
                document = try RoomProfessionalRecoveryRebinding.rebind(
                    redesign: original,
                    targetSourceRevision: target,
                    mapping: recoveredCopyMapping
                )
            }
            cameraIDs = document.orientation.canonicalCameras.map(\.cameraID)
        } else {
            cameraIDs = []
        }
        return RoomConceptSetValidationContext(
            expectedSourceRevision: sourceRevision,
            currentCanonicalCameraIDs: cameraIDs,
            validatedSourceAIRoomPackages: try sourcePackageProvenance.map {
                try $0.validatedSourcePackage()
            }
        )
    }

    private func recoveryResultMappingAdjustments(
        staged: StagedProfessionalRecovery,
        target: RecoveryTargetBinding
    ) throws -> [RoomProfessionalConceptMappingAdjustment] {
        var adjustments = staged.extraction.manifest.conceptMappingAdjustments
        guard let mapping = target.mapping else {
            return adjustments
        }
        let context = try conceptValidationContext(
            sourceRevision: target.sourceRevision,
            redesignSnapshot: staged.redesignSnapshot,
            recoveredCopyMapping: mapping,
            sourcePackageProvenance: []
        )
        let copyPlan = try staged.conceptSnapshot.restoreImports(
            context: context,
            recoveredCopyMapping: mapping
        )
        adjustments.append(contentsOf: copyPlan.conceptMappingAdjustments)
        let sorted = adjustments.sorted {
            if $0.conceptSetID != $1.conceptSetID { return $0.conceptSetID < $1.conceptSetID }
            return $0.attachmentID < $1.attachmentID
        }
        var identifiers = Set<String>()
        for adjustment in sorted {
            guard identifiers.insert("\(adjustment.conceptSetID)/\(adjustment.attachmentID)/\(adjustment.to.status.rawValue)").inserted else {
                throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                    "Recovery adjustment ledger contains duplicate mapping entries."
                )
            }
        }
        return sorted
    }

    private func makeResult(
        transaction: RoomProfessionalRecoveryTransaction,
        target: RecoveryTargetBinding,
        conceptSourcePackageProvenance: [RoomProfessionalConceptSourcePackageProvenanceSnapshot],
        conceptMappingAdjustments: [RoomProfessionalConceptMappingAdjustment]
    ) async throws -> RoomProfessionalRecoveryResult {
        let projectSummary = try await projectStore.load(projectID: target.projectID)
        return RoomProfessionalRecoveryResult(
            transaction: transaction,
            projectSummary: RoomProjectSummary(
                projectID: projectSummary.manifest.projectID,
                customName: projectSummary.metadata.customName,
                captureDate: projectSummary.metadata.captureDate,
                lastRevisedDate: projectSummary.effectiveLastRevisedDate,
                manualLocation: projectSummary.metadata.manualLocation,
                tags: projectSummary.metadata.tags,
                thumbnailRelativePath: projectSummary.metadata.thumbnailRelativePath,
                archived: projectSummary.metadata.archived,
                headRevisionID: projectSummary.manifest.headRevisionID
            ),
            recoveredAsCopy: target.mapping != nil,
            conceptSourcePackageProvenance: conceptSourcePackageProvenance,
            conceptMappingAdjustments: conceptMappingAdjustments
        )
    }

    private func writeNewOwnershipMarker(
        transaction: RoomProfessionalRecoveryTransaction,
        ownershipToken: String,
        transactionURL: URL
    ) throws {
        try assertTransactionDirectoryShape(transactionURL, transaction: transaction)
        let marker = try RoomProfessionalRecoveryOwnershipMarker(
            transactionID: transaction.transactionID,
            ownershipToken: ownershipToken,
            directoryName: transactionURL.lastPathComponent
        )
        let markerURL = transactionURL.appendingPathComponent(Self.ownershipMarkerFilename)
        guard markerURL.deletingLastPathComponent().standardizedFileURL == transactionURL.standardizedFileURL,
              !pathExists(markerURL),
              !isSymbolicLink(markerURL)
        else {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Professional recovery ownership marker already exists or escapes its transaction directory."
            )
        }
        do {
            let data = try RoomProfessionalSyncCanonicalJSON.encode(marker)
            try RoomAtomicFileWriter.writeNewFile(data, to: markerURL, fileManager: fileManager)
        } catch {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Unable to write professional recovery ownership marker."
            )
        }
        guard try readOwnershipMarker(transactionURL: transactionURL) == marker else {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Professional recovery ownership marker did not reopen canonically."
            )
        }
    }

    private func readOwnershipMarker(
        transactionURL: URL
    ) throws -> RoomProfessionalRecoveryOwnershipMarker {
        let markerURL = transactionURL.appendingPathComponent(Self.ownershipMarkerFilename)
        guard markerURL.deletingLastPathComponent().standardizedFileURL == transactionURL.standardizedFileURL,
              !isSymbolicLink(markerURL)
        else {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Professional recovery ownership marker is unsafe."
            )
        }
        let data = try boundedRegularData(
            at: markerURL,
            label: "Professional recovery ownership marker"
        )
        let marker: RoomProfessionalRecoveryOwnershipMarker
        do {
            marker = try RoomProfessionalSyncCanonicalJSON.decodeStrict(
                data,
                as: RoomProfessionalRecoveryOwnershipMarker.self
            )
        } catch {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Professional recovery ownership marker is not strict canonical state."
            )
        }
        try marker.validate()
        guard marker.directoryName == transactionURL.lastPathComponent,
              marker.stagedArchiveFilename == Self.stagedArchiveFilename
        else {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Professional recovery ownership marker does not bind direct transaction children."
            )
        }
        return marker
    }

    private func cleanupOwnedTransactionIfStillOwned(
        transaction: RoomProfessionalRecoveryTransaction,
        ownershipToken: String,
        transactionURL: URL
    ) {
        guard let marker = try? readOwnershipMarker(transactionURL: transactionURL),
              marker.transactionID == transaction.transactionID,
              marker.ownershipToken == ownershipToken
        else {
            return
        }
        try? removeOwnedTransaction(
            transaction: transaction,
            ownershipToken: ownershipToken,
            transactionURL: transactionURL
        )
    }

    private func removeOwnedTransaction(
        transaction: RoomProfessionalRecoveryTransaction,
        ownershipToken: String,
        transactionURL: URL
    ) throws {
        try assertTransactionDirectoryShape(transactionURL, transaction: transaction)
        let expected = try readOwnershipMarker(transactionURL: transactionURL)
        guard expected.transactionID == transaction.transactionID,
              expected.ownershipToken == ownershipToken
        else {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Professional recovery transaction is not owned by this durable marker."
            )
        }
        // Re-read immediately before deletion. If a concurrent actor replaced
        // either the directory or marker, leave it for explicit safe recovery.
        guard try readOwnershipMarker(transactionURL: transactionURL) == expected else {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Professional recovery ownership changed before cleanup."
            )
        }
        do {
            try fileManager.removeItem(at: transactionURL)
        } catch {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Unable to remove the exact marker-owned professional recovery transaction."
            )
        }
    }

    private func createVerificationStage(
        transaction: RoomProfessionalRecoveryTransaction,
        transactionURL: URL
    ) throws -> RoomProfessionalRecoveryVerificationStage {
        let stageDirectoryName = ".verification-\(UUID().uuidString.lowercased())"
        guard RoomPathValidation.isSafeRelativePath(stageDirectoryName) else {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Professional recovery verification directory name is invalid."
            )
        }
        let parentURL = transactionURL.appendingPathComponent(stageDirectoryName, isDirectory: true)
        guard parentURL.deletingLastPathComponent().standardizedFileURL == transactionURL.standardizedFileURL,
              !pathExists(parentURL),
              !isSymbolicLink(parentURL)
        else {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Professional recovery verification stage collides with existing scratch state."
            )
        }
        do {
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: false)
        } catch {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Unable to create the professional recovery verification stage."
            )
        }

        let marker = try RoomProfessionalRecoveryVerificationMarker(
            transactionID: transaction.transactionID,
            verificationToken: UUID().uuidString.lowercased(),
            directoryName: stageDirectoryName,
            envelopeDirectoryName: Self.verificationEnvelopeDirectoryName
        )
        let stage = RoomProfessionalRecoveryVerificationStage(
            transactionURL: transactionURL,
            parentURL: parentURL,
            extractionURL: parentURL.appendingPathComponent(
                Self.verificationEnvelopeDirectoryName,
                isDirectory: true
            ),
            marker: marker
        )
        do {
            try writeNewVerificationMarker(marker, to: parentURL)
            guard !pathExists(stage.extractionURL), !isSymbolicLink(stage.extractionURL) else {
                throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                    "Professional recovery verification envelope already exists."
                )
            }
            try fileManager.createDirectory(at: stage.extractionURL, withIntermediateDirectories: false)
            try requireRealDirectory(
                stage.extractionURL,
                message: "Professional recovery verification envelope is unsafe."
            )
            return stage
        } catch {
            cleanupVerificationStage(stage)
            throw error
        }
    }

    private func writeNewVerificationMarker(
        _ marker: RoomProfessionalRecoveryVerificationMarker,
        to parentURL: URL
    ) throws {
        try requireRealDirectory(parentURL, message: "Professional recovery verification stage is unsafe.")
        let markerURL = parentURL.appendingPathComponent(Self.verificationMarkerFilename)
        guard markerURL.deletingLastPathComponent().standardizedFileURL == parentURL.standardizedFileURL,
              !pathExists(markerURL),
              !isSymbolicLink(markerURL)
        else {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Professional recovery verification marker already exists or escapes its stage."
            )
        }
        do {
            let data = try RoomProfessionalSyncCanonicalJSON.encode(marker)
            try RoomAtomicFileWriter.writeNewFile(data, to: markerURL, fileManager: fileManager)
        } catch {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Unable to write professional recovery verification marker."
            )
        }
        guard try readVerificationMarker(at: parentURL) == marker else {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Professional recovery verification marker did not reopen canonically."
            )
        }
    }

    private func readVerificationMarker(
        at parentURL: URL
    ) throws -> RoomProfessionalRecoveryVerificationMarker {
        let markerURL = parentURL.appendingPathComponent(Self.verificationMarkerFilename)
        guard markerURL.deletingLastPathComponent().standardizedFileURL == parentURL.standardizedFileURL,
              !isSymbolicLink(markerURL)
        else {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Professional recovery verification marker is unsafe."
            )
        }
        let data = try boundedRegularData(
            at: markerURL,
            label: "Professional recovery verification marker"
        )
        let marker: RoomProfessionalRecoveryVerificationMarker
        do {
            marker = try RoomProfessionalSyncCanonicalJSON.decodeStrict(
                data,
                as: RoomProfessionalRecoveryVerificationMarker.self
            )
        } catch {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Professional recovery verification marker is not strict canonical state."
            )
        }
        try marker.validate()
        guard marker.directoryName == parentURL.lastPathComponent,
              marker.envelopeDirectoryName == Self.verificationEnvelopeDirectoryName
        else {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Professional recovery verification marker does not bind direct stage children."
            )
        }
        return marker
    }

    private func cleanupVerificationStage(
        _ stage: RoomProfessionalRecoveryVerificationStage
    ) {
        guard stage.parentURL.deletingLastPathComponent().standardizedFileURL == stage.transactionURL.standardizedFileURL,
              !isSymbolicLink(stage.parentURL),
              let marker = try? readVerificationMarker(at: stage.parentURL),
              marker == stage.marker,
              !isSymbolicLink(stage.extractionURL)
        else {
            return
        }
        // Re-read the exact marker immediately before deletion. The stage is
        // ephemeral, so a failed cleanup is intentionally retained rather
        // than risking an unowned replacement.
        guard (try? readVerificationMarker(at: stage.parentURL)) == marker else {
            return
        }
        try? fileManager.removeItem(at: stage.parentURL)
    }

    private func boundedRegularData(at url: URL, label: String) throws -> Data {
        guard !isSymbolicLink(url) else {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState("\(label) is a symbolic link.")
        }
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber,
                  size.int64Value > 0,
                  UInt64(size.int64Value) <= RoomBackupLimits.maximumManifestBytes
            else {
                throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                    "\(label) is not a bounded regular file."
                )
            }
            return try Data(contentsOf: url)
        } catch let error as RoomProfessionalRecoveryCoordinatorError {
            throw error
        } catch {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState("\(label) is unavailable.")
        }
    }

    private func writeNewJournal(
        _ journal: RoomProfessionalRecoveryJournal,
        transactionURL: URL
    ) throws {
        let transaction = try RoomProfessionalRecoveryTransaction(transactionID: journal.transactionID)
        try assertOwnedTransactionDirectory(
            transactionURL,
            transaction: transaction,
            ownershipToken: journal.ownershipToken
        )
        let journalURL = transactionURL.appendingPathComponent(Self.journalFilename)
        guard !pathExists(journalURL), !isSymbolicLink(journalURL) else {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Professional recovery journal already exists."
            )
        }
        let data = try RoomProfessionalSyncCanonicalJSON.encode(journal)
        do {
            try RoomAtomicFileWriter.writeNewFile(data, to: journalURL, fileManager: fileManager)
        } catch {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Unable to write professional recovery journal."
            )
        }
        guard try decodeJournal(at: journalURL) == journal else {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Professional recovery journal did not reopen canonically."
            )
        }
    }

    private func replaceJournal(
        _ journal: RoomProfessionalRecoveryJournal,
        transactionURL: URL
    ) throws {
        let transaction = try RoomProfessionalRecoveryTransaction(transactionID: journal.transactionID)
        try assertOwnedTransactionDirectory(
            transactionURL,
            transaction: transaction,
            ownershipToken: journal.ownershipToken
        )
        let journalURL = transactionURL.appendingPathComponent(Self.journalFilename)
        _ = try decodeJournal(at: journalURL)
        let data = try RoomProfessionalSyncCanonicalJSON.encode(journal)
        do {
            try data.write(to: journalURL, options: .atomic)
        } catch {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Unable to update professional recovery journal."
            )
        }
        guard try decodeJournal(at: journalURL) == journal else {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Professional recovery journal update did not reopen canonically."
            )
        }
    }

    private func readJournal(
        transaction: RoomProfessionalRecoveryTransaction,
        transactionURL: URL
    ) throws -> RoomProfessionalRecoveryJournal {
        // A generated, exact transaction path that is simply absent is a
        // distinct terminal condition from malformed scratch state. App-side
        // recovery may use this only to clear a matching durable
        // `.companionsCommitted` acknowledgement after Core has already
        // removed the completed transaction. Broken/symlinked paths remain
        // unsafe and must never be treated as an acknowledged cleanup.
        guard pathExists(transactionURL) else {
            throw RoomProfessionalRecoveryCoordinatorError.transactionNotFound(
                transaction.transactionID
            )
        }
        guard !isSymbolicLink(transactionURL) else {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Professional recovery transaction directory is unsafe."
            )
        }
        try assertTransactionDirectoryShape(transactionURL, transaction: transaction)
        let journalURL = transactionURL.appendingPathComponent(Self.journalFilename)
        let journal = try decodeJournal(at: journalURL)
        let marker = try readOwnershipMarker(transactionURL: transactionURL)
        guard journal.transactionID == transaction.transactionID,
              marker.transactionID == transaction.transactionID,
              marker.ownershipToken == journal.ownershipToken
        else {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Professional recovery journal and ownership marker do not own the requested transaction directory."
            )
        }
        return journal
    }

    private func decodeJournal(at url: URL) throws -> RoomProfessionalRecoveryJournal {
        guard !isSymbolicLink(url) else {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Professional recovery journal is a symbolic link."
            )
        }
        let data: Data
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber,
                  size.int64Value > 0,
                  UInt64(size.int64Value) <= RoomBackupLimits.maximumManifestBytes
            else {
                throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                    "Professional recovery journal is not a bounded regular file."
                )
            }
            data = try Data(contentsOf: url)
        } catch let error as RoomProfessionalRecoveryCoordinatorError {
            throw error
        } catch {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Professional recovery journal is unavailable."
            )
        }
        do {
            return try RoomProfessionalSyncCanonicalJSON.decodeStrict(
                data,
                as: RoomProfessionalRecoveryJournal.self
            )
        } catch {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Professional recovery journal is not strict canonical recovery state."
            )
        }
    }

    private func requireRealDirectory(_ url: URL, message: String) throws {
        var isDirectory = ObjCBool(false)
        guard url.isFileURL,
              fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              !isSymbolicLink(url)
        else {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(message)
        }
    }

    private func pathExists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path) || isSymbolicLink(url)
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}

private struct StagedProfessionalRecovery {
    let extraction: RoomProfessionalWorkingSetExtraction
    let packageArchiveURL: URL
    let redesignSnapshot: RoomProfessionalRedesignSnapshot?
    let conceptSnapshot: RoomProfessionalConceptSnapshot
    let conceptSourcePackageProvenance: [RoomProfessionalConceptSourcePackageProvenanceSnapshot]
    let verificationStage: RoomProfessionalRecoveryVerificationStage
}

private struct RoomProfessionalRecoveryVerificationStage {
    let transactionURL: URL
    let parentURL: URL
    let extractionURL: URL
    let marker: RoomProfessionalRecoveryVerificationMarker
}

/// Minimal private ownership state for a transaction directory. Its random
/// token is generated by Core, duplicated in the durable journal, and never
/// comes from caller input.
private struct RoomProfessionalRecoveryOwnershipMarker: Codable, Sendable, Equatable {
    static let schemaVersion = "roomscan-professional-recovery-ownership-v1"

    let schemaVersion: String
    let transactionID: String
    let ownershipToken: String
    let directoryName: String
    let stagedArchiveFilename: String

    init(
        transactionID: String,
        ownershipToken: String,
        directoryName: String
    ) throws {
        self.schemaVersion = Self.schemaVersion
        self.transactionID = transactionID
        self.ownershipToken = ownershipToken
        self.directoryName = directoryName
        self.stagedArchiveFilename = "working-set.zip"
        try validate()
    }

    init(from decoder: Decoder) throws {
        try RoomProfessionalTrustedDecoding.requireTrusted(decoder)
        let container = try RoomProfessionalStrictCoding.container(
            decoder,
            allowed: ["schemaVersion", "transactionID", "ownershipToken", "directoryName", "stagedArchiveFilename"],
            required: ["schemaVersion", "transactionID", "ownershipToken", "directoryName", "stagedArchiveFilename"]
        )
        schemaVersion = try container.decode(String.self, forKey: .init("schemaVersion"))
        transactionID = try container.decode(String.self, forKey: .init("transactionID"))
        ownershipToken = try container.decode(String.self, forKey: .init("ownershipToken"))
        directoryName = try container.decode(String.self, forKey: .init("directoryName"))
        stagedArchiveFilename = try container.decode(String.self, forKey: .init("stagedArchiveFilename"))
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: RoomProfessionalDynamicCodingKey.self)
        try container.encode(schemaVersion, forKey: .init("schemaVersion"))
        try container.encode(transactionID, forKey: .init("transactionID"))
        try container.encode(ownershipToken, forKey: .init("ownershipToken"))
        try container.encode(directoryName, forKey: .init("directoryName"))
        try container.encode(stagedArchiveFilename, forKey: .init("stagedArchiveFilename"))
    }

    func validate() throws {
        guard schemaVersion == Self.schemaVersion,
              RoomPathValidation.isSafeStableIdentifier(transactionID),
              RoomPathValidation.isSafeStableIdentifier(ownershipToken),
              directoryName == ".roomscan-professional-recovery-\(transactionID)",
              RoomPathValidation.isSafeRelativePath(directoryName),
              stagedArchiveFilename == "working-set.zip"
        else {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Professional recovery ownership marker is invalid."
            )
        }
    }
}

/// Marker for an ephemeral validation extraction. It is intentionally
/// separate from the durable transaction marker so every cleanup has an exact
/// independently re-readable ownership proof.
private struct RoomProfessionalRecoveryVerificationMarker: Codable, Sendable, Equatable {
    static let schemaVersion = "roomscan-professional-recovery-verification-v1"

    let schemaVersion: String
    let transactionID: String
    let verificationToken: String
    let directoryName: String
    let envelopeDirectoryName: String

    init(
        transactionID: String,
        verificationToken: String,
        directoryName: String,
        envelopeDirectoryName: String
    ) throws {
        self.schemaVersion = Self.schemaVersion
        self.transactionID = transactionID
        self.verificationToken = verificationToken
        self.directoryName = directoryName
        self.envelopeDirectoryName = envelopeDirectoryName
        try validate()
    }

    init(from decoder: Decoder) throws {
        try RoomProfessionalTrustedDecoding.requireTrusted(decoder)
        let container = try RoomProfessionalStrictCoding.container(
            decoder,
            allowed: ["schemaVersion", "transactionID", "verificationToken", "directoryName", "envelopeDirectoryName"],
            required: ["schemaVersion", "transactionID", "verificationToken", "directoryName", "envelopeDirectoryName"]
        )
        schemaVersion = try container.decode(String.self, forKey: .init("schemaVersion"))
        transactionID = try container.decode(String.self, forKey: .init("transactionID"))
        verificationToken = try container.decode(String.self, forKey: .init("verificationToken"))
        directoryName = try container.decode(String.self, forKey: .init("directoryName"))
        envelopeDirectoryName = try container.decode(String.self, forKey: .init("envelopeDirectoryName"))
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: RoomProfessionalDynamicCodingKey.self)
        try container.encode(schemaVersion, forKey: .init("schemaVersion"))
        try container.encode(transactionID, forKey: .init("transactionID"))
        try container.encode(verificationToken, forKey: .init("verificationToken"))
        try container.encode(directoryName, forKey: .init("directoryName"))
        try container.encode(envelopeDirectoryName, forKey: .init("envelopeDirectoryName"))
    }

    func validate() throws {
        guard schemaVersion == Self.schemaVersion,
              RoomPathValidation.isSafeStableIdentifier(transactionID),
              RoomPathValidation.isSafeStableIdentifier(verificationToken),
              directoryName.hasPrefix(".verification-"),
              RoomPathValidation.isSafeRelativePath(directoryName),
              envelopeDirectoryName == "envelope"
        else {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Professional recovery verification marker is invalid."
            )
        }
    }
}

private struct RecoveryTargetPlan {
    let projectID: String
    let conflictPolicy: RoomBackupRecoveryConflictPolicy
    let recoveredCopyProjectID: String?
}

private struct RecoveryTargetBinding {
    let projectID: String
    let sourceRevision: RoomRedesignSourceRevision
    let conflictPolicy: RoomBackupRecoveryConflictPolicy
    let recoveredCopyProjectID: String?
    let mapping: RoomProfessionalRecoveredCopyMapping?
}

private enum RoomProfessionalRecoveryJournalTarget: String, Codable, Sendable, Equatable {
    case original
    case recoveredCopy
}

private enum RoomProfessionalRecoveryJournalPhase: String, Codable, Sendable, Equatable {
    case prepared
    case packageCommitted
    case redesignCommitted
    case conceptsCommitted
}

/// Canonical durable marker for one private transaction directory. This keeps
/// only the immutable descriptor, a safe target identity, and progress; no
/// caller path, archive URL, room byte payload, token, or provider object key
/// can enter this file.
private struct RoomProfessionalRecoveryJournal: Codable, Sendable, Equatable {
    static let schemaVersion = "roomscan-professional-recovery-journal-v1"

    var schemaVersion: String
    var transactionID: String
    var ownershipToken: String
    var descriptor: RoomProfessionalWorkingSetDescriptor
    var targetKind: RoomProfessionalRecoveryJournalTarget
    var recoveredCopyProjectID: String?
    var phase: RoomProfessionalRecoveryJournalPhase

    init(
        transactionID: String,
        ownershipToken: String,
        descriptor: RoomProfessionalWorkingSetDescriptor,
        target: RoomProfessionalRecoveryTarget,
        phase: RoomProfessionalRecoveryJournalPhase
    ) throws {
        schemaVersion = Self.schemaVersion
        self.transactionID = transactionID
        self.ownershipToken = ownershipToken
        self.descriptor = descriptor
        switch target {
        case .original:
            targetKind = .original
            recoveredCopyProjectID = nil
        case let .recoveredCopy(projectID):
            targetKind = .recoveredCopy
            recoveredCopyProjectID = projectID
        }
        self.phase = phase
        try validate()
    }

    init(from decoder: Decoder) throws {
        try RoomProfessionalTrustedDecoding.requireTrusted(decoder)
        let container = try RoomProfessionalStrictCoding.container(
            decoder,
            allowed: ["schemaVersion", "transactionID", "ownershipToken", "descriptor", "target", "recoveredCopyProjectID", "phase"],
            required: ["schemaVersion", "transactionID", "ownershipToken", "descriptor", "target", "phase"]
        )
        schemaVersion = try container.decode(String.self, forKey: .init("schemaVersion"))
        transactionID = try container.decode(String.self, forKey: .init("transactionID"))
        ownershipToken = try container.decode(String.self, forKey: .init("ownershipToken"))
        descriptor = try container.decode(RoomProfessionalWorkingSetDescriptor.self, forKey: .init("descriptor"))
        targetKind = try container.decode(RoomProfessionalRecoveryJournalTarget.self, forKey: .init("target"))
        recoveredCopyProjectID = try container.decodeIfPresent(
            String.self,
            forKey: .init("recoveredCopyProjectID")
        )
        phase = try container.decode(RoomProfessionalRecoveryJournalPhase.self, forKey: .init("phase"))
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: RoomProfessionalDynamicCodingKey.self)
        try container.encode(schemaVersion, forKey: .init("schemaVersion"))
        try container.encode(transactionID, forKey: .init("transactionID"))
        try container.encode(ownershipToken, forKey: .init("ownershipToken"))
        try container.encode(descriptor, forKey: .init("descriptor"))
        try container.encode(targetKind, forKey: .init("target"))
        try container.encodeIfPresent(recoveredCopyProjectID, forKey: .init("recoveredCopyProjectID"))
        try container.encode(phase, forKey: .init("phase"))
    }

    func validate() throws {
        guard schemaVersion == Self.schemaVersion,
              RoomPathValidation.isSafeStableIdentifier(transactionID),
              RoomPathValidation.isSafeStableIdentifier(ownershipToken)
        else {
            throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                "Professional recovery journal schema or transaction identifier is invalid."
            )
        }
        try descriptor.validate()
        switch targetKind {
        case .original:
            guard recoveredCopyProjectID == nil else {
                throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                    "Original recovery journal must not carry a recovered-copy identifier."
                )
            }
        case .recoveredCopy:
            guard let recoveredCopyProjectID,
                  RoomPathValidation.isSafeStableIdentifier(recoveredCopyProjectID),
                  recoveredCopyProjectID != descriptor.projectID
            else {
                throw RoomProfessionalRecoveryCoordinatorError.unsafeScratchState(
                    "Recovered-copy journal target is invalid."
                )
            }
        }
    }
}

private extension RoomProfessionalRecoveryJournal {
    var recoveryTarget: RoomProfessionalRecoveryTarget {
        switch targetKind {
        case .original:
            return .original
        case .recoveredCopy:
            // `validate()` guarantees this value is present and safe.
            return .recoveredCopy(projectID: recoveredCopyProjectID!)
        }
    }
}
