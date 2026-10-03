import Foundation
import RoomScanCore

/// Professional-only orchestration for immutable working-set uploads. It has
/// no observer on local save, app launch, foregrounding, CloudKit, or guest
/// flows: network work starts only from an explicit professional action.
@MainActor
final class ProfessionalProjectSyncService {
    private static let scratchMarkerFilename = ".roomscan-professional-sync-scratch-v1"
    private static let stageMarkerFilename = ".roomscan-professional-sync-stage-v1"
    private static let stageMarkerData = Data("roomscan-professional-sync-stage-v1".utf8)
    private static let approvalLifetime: TimeInterval = 15 * 60
    private static let maximumStatusPolls = 8

    private let controller: RoomLibraryController
    private let modelFactory: RoomAIRedesignModelFactory?
    private let journal: ProfessionalProjectSyncJournal
    private let transport: any ProfessionalProjectSyncTransport
    private let scratchRootURL: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let makeIdentifier: @Sendable () -> String
    private let waitForPoll: @Sendable (UInt64) async -> Void
    private var recoveryCoordinator: ProfessionalProjectRecoveryCoordinator?
    private var hasRecoveredScratchOrphans = false
    /// Tokens are process-memory only; journal data must never contain them.
    private var heldLeaseTokens: [String: String] = [:]

    init(
        controller: RoomLibraryController,
        modelFactory: RoomAIRedesignModelFactory?,
        journal: ProfessionalProjectSyncJournal,
        transport: any ProfessionalProjectSyncTransport,
        scratchRootURL: URL,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        makeIdentifier: @escaping @Sendable () -> String = {
            "professional-copy-\(UUID().uuidString.lowercased())"
        },
        waitForPoll: @escaping @Sendable (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.controller = controller
        self.modelFactory = modelFactory
        self.journal = journal
        self.transport = transport
        self.scratchRootURL = scratchRootURL.standardizedFileURL
        self.fileManager = fileManager
        self.now = now
        self.makeIdentifier = makeIdentifier
        self.waitForPoll = waitForPoll
    }

    /// Local-only refresh. A different immutable local head is retained as a
    /// draft and does not make a hosted request or mutate the source package.
    func refresh(projectID: String) async throws -> ProfessionalProjectSyncPresentationState {
        let package = try await controller.loadPackage(projectID: projectID)
        let localHead = package.manifest.headRevisionID
        guard var record = try journal.load(localProjectID: projectID) else {
            return .idle
        }
        // A completed Core transaction is retained until both its provenance
        // acknowledgement and Core scratch discard are durable. It remains an
        // explicit resume/cleanup action after relaunch rather than being
        // silently treated as a normal canonical package.
        if record.recoveryTransactionID != nil,
           record.recoveryPhase != .none {
            return .recoveryReady
        }
        // A recovered canonical copy is intentionally not auto-uploaded. The
        // durable local marker survives relaunch until the user saves a child
        // revision and explicitly previews an append.
        if record.hostedProjectID == nil,
           record.status == .attached {
            return .awaitingUserEdit
        }
        // A persisted stale conflict is authoritative over the normal local
        // draft comparison. The local head is the preserved stale candidate;
        // presenting it as an ordinary draft would hide compare/rebase/copy.
        if record.status == .stale {
            return try conflictState(from: record)
        }
        if record.acknowledgedLocalHeadRevisionID != localHead {
            record.localDraftHeadRevisionID = localHead
            try journal.replace(record)
            return .localDraft
        }
        switch record.status {
        case .canonical, .attached: return .canonical
        case .stale: return try conflictState(from: record)
        case .allocated, .validationPending, .validating: return .awaitingValidation
        case .rejected: return .rejected
        }
    }

    /// Builds and validates a real Core raw-redacted working archive without
    /// requesting a provider URL or enumerating capture-bundle raw evidence.
    func previewMigration(projectID: String) async throws -> ProfessionalProjectSyncPreview {
        guard let modelFactory else { throw ProfessionalProjectSyncError.unavailable }
        let package = try await controller.loadPackage(projectID: projectID)
        let head = package.manifest.headRevisionID
        let sourceRevision = try await controller.redesignSourceBinding(
            projectID: projectID,
            revisionID: head
        )
        let stage = try makeOwnedStage(projectID: projectID)
        var retainStageForExplicitApproval = false
        defer {
            if !retainStageForExplicitApproval {
                try? cleanupOwnedStage(stage)
            }
        }
        let workingCopy = try await controller.materializeProfessionalWorkingCopy(
            projectID: projectID,
            expectedHeadRevisionID: head,
            into: stage.appendingPathComponent("working-copy", isDirectory: true)
        )
        let companionPreparation = try await modelFactory.professionalWorkingSetCompanionPreparation(
            sourceRevision: sourceRevision
        )
        let archiveURL = stage.appendingPathComponent("working-set.zip")
        let snapshot = try await RoomProfessionalWorkingSetArchive.build(
            workingCopy: workingCopy,
            archiveURL: archiveURL,
            companionPreparation: companionPreparation
        )
        let archive = try archiveDigest(of: archiveURL)
        guard archive.sha256 == snapshot.descriptor.archiveSHA256,
              archive.byteCount == snapshot.descriptor.archiveByteCount
        else { throw ProfessionalProjectSyncError.archiveChanged }
        let workingCategories = try workingCategorySummaries(
            from: snapshot.manifest.entries
        )

        let preview = ProfessionalProjectSyncPreview(
            localProjectID: projectID,
            localRoomDisplayName: package.metadata.customName,
            localHeadRevisionID: head,
            sourceRevision: sourceRevision,
            workingSetManifestSHA256: snapshot.descriptor.snapshotID,
            archiveSHA256: archive.sha256,
            archiveByteCount: archive.byteCount,
            workingCategories: workingCategories,
            rawExcludedClasses: RoomProfessionalRawAssetClass.allCases,
            conceptMappingAdjustments: snapshot.conceptMappingAdjustments,
            approval: .init(
                localProjectID: projectID,
                localHeadRevisionID: head,
                archiveSHA256: archive.sha256,
                archiveByteCount: archive.byteCount,
                issuedAt: now()
            ),
            stagedArchiveURL: archiveURL
        )
        retainStageForExplicitApproval = true
        return preview
    }

    /// The only automatic sequence is allocate -> signed PUT -> complete. No
    /// local source delete/archive/edit action is reachable from this method.
    func approveMigration(
        _ preview: ProfessionalProjectSyncPreview,
        sessionUnlocked: Bool,
        quotaPolicyVersion: Int,
        hostedGlobalVersion: Int,
        hostedWorkspaceVersion: Int
    ) async throws -> ProfessionalProjectSyncPresentationState {
        guard sessionUnlocked else { throw ProfessionalProjectSyncError.unavailable }
        try validate(preview: preview)
        guard case .uploadable = preview.uploadability else {
            throw ProfessionalProjectSyncError.archiveExceedsHostedLimit
        }
        let package = try await controller.loadPackage(projectID: preview.localProjectID)
        guard package.manifest.headRevisionID == preview.localHeadRevisionID else {
            throw ProfessionalProjectSyncError.approvalMismatch
        }
        let currentArchive = try archiveDigest(of: preview.stagedArchiveURL)
        guard currentArchive.sha256 == preview.archiveSHA256,
              currentArchive.byteCount == preview.archiveByteCount
        else { throw ProfessionalProjectSyncError.archiveChanged }

        var record = try journal.load(localProjectID: preview.localProjectID)
            ?? ProfessionalProjectSyncJournalRecord(localProjectID: preview.localProjectID)
        let idempotency = stableIdempotencyDigest(
            projectID: preview.localProjectID,
            headRevisionID: preview.localHeadRevisionID,
            archiveSHA256: preview.archiveSHA256
        )
        if let previousIdempotency = record.idempotencyDigest,
           previousIdempotency != idempotency {
            // A terminal canonical operation may advance to one newly
            // previewed immutable local child. Pending/rejected/stale state,
            // a changed archive for the same local head, or any other digest
            // drift remains an approval mismatch. The prior digest is left
            // durable unless allocation succeeds and the new operation is
            // journaled below, so an allocation failure cannot erase the
            // last acknowledged retry identity.
            guard record.status == .canonical,
                  let acknowledgedLocalHead = record.acknowledgedLocalHeadRevisionID,
                  acknowledgedLocalHead != preview.localHeadRevisionID
            else {
                throw ProfessionalProjectSyncError.approvalMismatch
            }
        }
        record.idempotencyDigest = idempotency

        let allocation: ProfessionalProjectSyncUploadAllocation
        if let hostedProjectID = record.hostedProjectID,
           let expectedHostedHead = record.acknowledgedHostedHeadRevisionID,
           let expectedLocalHead = record.acknowledgedLocalHeadRevisionID {
            // Appending the same local immutable head is not a new revision;
            // Core/service CAS requires parent and proposed heads to differ.
            guard expectedLocalHead != preview.localHeadRevisionID else {
                throw ProfessionalProjectSyncError.approvalMismatch
            }
            allocation = try await transport.allocateRevision(.init(
                projectID: hostedProjectID,
                expectedHostedHeadRevisionID: expectedHostedHead,
                expectedHeadRevisionID: expectedLocalHead,
                proposedRevisionID: preview.localHeadRevisionID,
                workingSetManifestSHA256: preview.workingSetManifestSHA256,
                archiveSHA256: preview.archiveSHA256,
                archiveByteCount: preview.archiveByteCount,
                idempotencyKey: idempotency,
                quotaPolicyVersion: quotaPolicyVersion,
                hostedGlobalVersion: hostedGlobalVersion,
                hostedWorkspaceVersion: hostedWorkspaceVersion
            ))
        } else {
            allocation = try await transport.allocateMigration(.init(
                sourceProjectID: preview.localProjectID,
                proposedRevisionID: preview.localHeadRevisionID,
                workingSetManifestSHA256: preview.workingSetManifestSHA256,
                archiveSHA256: preview.archiveSHA256,
                archiveByteCount: preview.archiveByteCount,
                idempotencyKey: idempotency,
                quotaPolicyVersion: quotaPolicyVersion,
                hostedGlobalVersion: hostedGlobalVersion,
                hostedWorkspaceVersion: hostedWorkspaceVersion
            ))
        }
        try validate(
            allocation: allocation,
            preview: preview,
            expectedHostedProjectID: record.hostedProjectID
        )
        record.hostedProjectID = allocation.projectID
        record.uploadID = allocation.uploadID
        record.candidateRevisionID = allocation.candidateRevisionID
        record.status = allocation.status
        try journal.replace(record)

        let expected = ExpectedUpload(allocation: allocation)
        // An exact idempotency retry can return a prior pending, validating,
        // canonical, stale, or rejected allocation. Allocation reducers do not
        // contain the authoritative current hosted head for stale, so obtain a
        // correlated status before applying any non-fresh result. Only a new
        // allocated response is allowed to use its transient signed URL.
        if allocation.status != .allocated {
            let observed = try await transport.uploadStatus(uploadID: allocation.uploadID)
            let reconciled = try await pollHostedStatus(
                initial: observed,
                expected: expected,
                localProjectID: preview.localProjectID,
                localHeadRevisionID: preview.localHeadRevisionID
            )
            return completeMigration(reconciled, preview: preview)
        }
        let state: ProfessionalProjectSyncPresentationState
        do {
            try await transport.upload(archiveURL: preview.stagedArchiveURL, allocation: allocation)
        } catch {
            // A signed PUT can fail after the immutable object was accepted
            // (for example a retry precondition response). Verify status then
            // complete against the first-party API; never assume that a PUT
            // failure means success.
            state = try await reconcileInterruptedUpload(
                originalError: error,
                expected: expected,
                localProjectID: preview.localProjectID,
                localHeadRevisionID: preview.localHeadRevisionID
            )
            return completeMigration(state, preview: preview)
        }
        let completion = try await transport.complete(uploadID: allocation.uploadID)
        state = try await pollHostedStatus(
            initial: completion,
            expected: expected,
            localProjectID: preview.localProjectID,
            localHeadRevisionID: preview.localHeadRevisionID
        )
        return completeMigration(state, preview: preview)
    }

    /// Exact retry deliberately recomputes the same immutable preview key;
    /// it never recovers or persists a signed URL.
    func retryMigration(
        _ preview: ProfessionalProjectSyncPreview,
        sessionUnlocked: Bool,
        quotaPolicyVersion: Int,
        hostedGlobalVersion: Int,
        hostedWorkspaceVersion: Int
    ) async throws -> ProfessionalProjectSyncPresentationState {
        try await approveMigration(
            preview,
            sessionUnlocked: sessionUnlocked,
            quotaPolicyVersion: quotaPolicyVersion,
            hostedGlobalVersion: hostedGlobalVersion,
            hostedWorkspaceVersion: hostedWorkspaceVersion
        )
    }

    /// Explicitly discards only the marker-owned staged working copy created
    /// for this preview. It never touches the authoritative local package,
    /// its revisions, capture evidence, CloudKit backup, or journal mapping.
    func discardMigrationPreview(_ preview: ProfessionalProjectSyncPreview) throws {
        try cleanupOwnedStage(preview.stagedArchiveURL.deletingLastPathComponent())
    }

    /// This is an explicit professional reconciliation action. If the journal
    /// was lost, callers recreate the preview and retry the stable idempotency
    /// key rather than guessing any server-side upload identifier.
    func reconcileUploadStatus(
        localProjectID: String
    ) async throws -> ProfessionalProjectSyncPresentationState {
        guard let record = try journal.load(localProjectID: localProjectID),
              let uploadID = record.uploadID
        else { return try await refresh(projectID: localProjectID) }
        let package = try await controller.loadPackage(projectID: localProjectID)
        let status = try await transport.uploadStatus(uploadID: uploadID)
        let expected = ExpectedUpload(
            projectID: record.hostedProjectID,
            uploadID: uploadID,
            candidateRevisionID: record.candidateRevisionID,
            archiveSHA256: nil,
            archiveByteCount: nil
        )
        return try await pollHostedStatus(
            initial: status,
            expected: expected,
            localProjectID: localProjectID,
            localHeadRevisionID: package.manifest.headRevisionID
        )
    }

    /// A stale branch exposes compare only as read-only staged inspection.
    /// There is no merge API or state case in the app layer.
    func compare(_ conflict: ProfessionalProjectSyncConflict) async throws -> ProfessionalProjectSyncComparison {
        let canonical = try await downloadAndExtract(
            projectID: conflict.hostedProjectID,
            revisionID: conflict.canonicalRevisionID
        )
        let stale = try await downloadAndExtract(
            projectID: conflict.hostedProjectID,
            revisionID: conflict.staleRevisionID
        )
        let canonicalPaths = canonical.extraction.manifest.entries
            .filter { $0.kind != .packageBackup }
            .map { "\($0.path):\($0.sha256)" }
            .sorted()
        let stalePaths = stale.extraction.manifest.entries
            .filter { $0.kind != .packageBackup }
            .map { "\($0.path):\($0.sha256)" }
            .sorted()
        return .init(
            canonicalManifestSHA256: canonical.manifestSHA256,
            staleManifestSHA256: stale.manifestSHA256,
            canonicalPackageManifestSHA256: canonical.packageManifestSHA256,
            stalePackageManifestSHA256: stale.packageManifestSHA256,
            canonicalHeadRevisionID: canonical.packageManifest.headRevisionID,
            staleHeadRevisionID: stale.packageManifest.headRevisionID,
            canonicalSourceSemanticSHA256: canonical.sourceSemanticSHA256,
            staleSourceSemanticSHA256: stale.sourceSemanticSHA256,
            canonicalRevisionCount: canonical.packageManifest.revisionCount,
            staleRevisionCount: stale.packageManifest.revisionCount,
            canonicalCompanionPaths: canonicalPaths,
            staleCompanionPaths: stalePaths,
            differs: canonical.manifestSHA256 != stale.manifestSHA256 || canonicalPaths != stalePaths
        )
    }

    /// Rebase means explicit canonical-head recovery-as-copy. Core retains the
    /// package-first promotion boundary and reports mapping downgrades.
    func startRebaseFromHostedHead(
        _ conflict: ProfessionalProjectSyncConflict
    ) async throws -> RoomProfessionalRecoveryResult {
        let result = try await recoverHosted(
            projectID: conflict.hostedProjectID,
            revisionID: conflict.canonicalRevisionID,
            target: .recoveredCopy(projectID: try copyIdentifier())
        )
        try markAwaitingUserEdit(result)
        return result
    }

    /// Duplicate means explicit stale-branch recovery-as-copy. A caller must
    /// later request a separate migration preview; no hosted project is made.
    func recoverBranchAsDuplicate(
        _ conflict: ProfessionalProjectSyncConflict
    ) async throws -> RoomProfessionalRecoveryResult {
        try await recoverHosted(
            projectID: conflict.hostedProjectID,
            revisionID: conflict.staleRevisionID,
            target: .recoveredCopy(projectID: try copyIdentifier())
        )
    }

    /// A duplicate branch becomes a wholly separate local migration candidate
    /// only after the user explicitly asks for this preview. It never creates
    /// a hosted project as part of recovery.
    func recoverBranchAsDuplicatePreview(
        _ conflict: ProfessionalProjectSyncConflict
    ) async throws -> ProfessionalProjectSyncPreview {
        let result = try await recoverBranchAsDuplicate(conflict)
        return try await previewMigration(projectID: result.projectSummary.projectID)
    }

    func recoverHosted(
        projectID: String,
        revisionID: String? = nil,
        target: RoomProfessionalRecoveryTarget
    ) async throws -> RoomProfessionalRecoveryResult {
        let download = try await transport.allocateRecovery(projectID: projectID, revisionID: revisionID)
        try validate(
            recovery: download.recovery,
            requestedProjectID: projectID,
            requestedRevisionID: revisionID
        )
        let stage = try makeOwnedStage(projectID: scratchIdentifier(namespace: "download", publicID: projectID))
        defer { try? cleanupOwnedStage(stage) }
        let archiveURL = stage.appendingPathComponent("downloaded-working-set.zip")
        try await transport.download(download, to: archiveURL)
        return try await makeRecoveryCoordinator().recoverDownloadedArchive(
            archiveURL: archiveURL,
            recovery: download.recovery,
            target: target
        )
    }

    func resumeRecovery(transactionID: String) async throws -> RoomProfessionalRecoveryResult {
        try await makeRecoveryCoordinator().resume(transactionID: transactionID)
    }

    /// Resolves the durable transaction from the validated public journal so
    /// the UI never invents or exposes a transaction identifier. Recovery
    /// still resumes through Core's package-first transaction boundary.
    func resumeRecovery(localProjectID: String) async throws -> RoomProfessionalRecoveryResult {
        guard let record = try journal.load(localProjectID: localProjectID),
              let transactionID = record.recoveryTransactionID,
              record.recoveryPhase != .none
        else { throw ProfessionalProjectSyncError.sourceUnavailable }
        return try await resumeRecovery(transactionID: transactionID)
    }

    /// Uploads an explicitly reviewed raw archive to its separate attachment
    /// tier. It cannot advance a hosted head. The hosted 64 MiB operational
    /// ceiling is enforced at allocation; the raw review remains exact by
    /// rejecting an over-limit archive whole rather than truncating evidence.
    func uploadRawArchive(
        _ snapshot: RoomProfessionalRawArchiveSnapshot,
        sessionUnlocked: Bool,
        quotaPolicyVersion: Int,
        hostedGlobalVersion: Int,
        hostedWorkspaceVersion: Int
    ) async throws -> ProfessionalProjectSyncStatus {
        guard sessionUnlocked else { throw ProfessionalProjectSyncError.unavailable }
        try snapshot.descriptor.validate()
        let localProjectID = snapshot.descriptor.projectID
        guard let record = try journal.load(localProjectID: localProjectID),
              let hostedProjectID = record.hostedProjectID,
              let hostedRevisionID = record.acknowledgedHostedHeadRevisionID,
              record.acknowledgedLocalHeadRevisionID == snapshot.descriptor.revisionID,
              record.status == .canonical
        else { throw ProfessionalProjectSyncError.approvalMismatch }
        let archive = try archiveDigest(of: snapshot.archiveURL)
        guard archive.sha256 == snapshot.descriptor.archiveSHA256,
              archive.byteCount == snapshot.descriptor.archiveByteCount
        else { throw ProfessionalProjectSyncError.archiveChanged }
        let reviewSHA256 = try RoomSHA256.hexDigest(of: RoomProfessionalSyncCanonicalJSON.encode(
            snapshot.descriptor.review
        ))
        let configuration = try await transport.configureRawArchive(
            projectID: hostedProjectID,
            reviewSHA256: reviewSHA256,
            hostedGlobalVersion: hostedGlobalVersion,
            hostedWorkspaceVersion: hostedWorkspaceVersion
        )
        guard configuration.projectID == hostedProjectID,
              configuration.rawArchiveEnabled,
              configuration.reviewedAt >= Date(timeIntervalSince1970: 0),
              configuration.reviewedAt <= now()
        else { throw ProfessionalProjectSyncError.invalidResponse }
        let allocation = try await transport.allocateRawArchive(.init(
            projectID: hostedProjectID,
            revisionID: hostedRevisionID,
            rawManifestSHA256: snapshot.descriptor.manifestSHA256,
            archiveSHA256: snapshot.descriptor.archiveSHA256,
            archiveByteCount: snapshot.descriptor.archiveByteCount,
            reviewSHA256: reviewSHA256,
            idempotencyKey: rawIdempotencyDigest(
                hostedProjectID: hostedProjectID,
                hostedRevisionID: hostedRevisionID,
                archiveSHA256: snapshot.descriptor.archiveSHA256,
                reviewSHA256: reviewSHA256
            ),
            quotaPolicyVersion: quotaPolicyVersion,
            hostedGlobalVersion: hostedGlobalVersion,
            hostedWorkspaceVersion: hostedWorkspaceVersion
        ))
        try validateRaw(
            allocation: allocation,
            expectedProjectID: hostedProjectID,
            expectedRevisionID: hostedRevisionID,
            archiveSHA256: snapshot.descriptor.archiveSHA256,
            archiveByteCount: snapshot.descriptor.archiveByteCount
        )
        // Raw exact retries are also status-first unless a fresh allocation
        // still needs its one immutable PUT. This avoids trying an expired
        // signed URL and correlates terminal attachment/rejection state.
        if allocation.status != .allocated {
            let observed = try await transport.uploadStatus(uploadID: allocation.uploadID)
            return try await pollRawStatus(
                initial: observed,
                allocation: allocation,
                expectedProjectID: hostedProjectID,
                expectedRevisionID: hostedRevisionID
            )
        }
        do {
            try await transport.upload(archiveURL: snapshot.archiveURL, allocation: allocation)
        } catch {
            // A signed immutable PUT can reach storage before reporting an
            // error. Reconcile through first-party status/complete; never
            // infer success from a 412 or other transport failure.
            return try await reconcileRawInterruptedUpload(
                originalError: error,
                allocation: allocation,
                expectedProjectID: hostedProjectID,
                expectedRevisionID: hostedRevisionID
            )
        }
        return try await pollRawStatus(
            initial: try await transport.complete(uploadID: allocation.uploadID),
            allocation: allocation,
            expectedProjectID: hostedProjectID,
            expectedRevisionID: hostedRevisionID
        )
    }

    /// Builds the disclosure ledger only after an explicit raw-review action.
    /// The default migration path cannot reach the capture-bundle materializer.
    func reviewRawArchive(
        localProjectID: String
    ) async throws -> ProfessionalProjectRawReview {
        let package = try await controller.loadPackage(projectID: localProjectID)
        let sourceRevision = try await controller.redesignSourceBinding(
            projectID: localProjectID,
            revisionID: package.manifest.headRevisionID
        )
        return try await ProfessionalRawArchiveMaterializer(
            fileManager: fileManager
        ).review(sourceRevision: sourceRevision)
    }

    /// Accepts the exact in-memory disclosure ledger, builds the separate raw
    /// archive inside marker-owned scratch, then uploads it without advancing
    /// the immutable hosted project head. No raw bytes or review URLs enter the
    /// durable sync journal.
    func acceptAndUploadRawArchive(
        _ review: ProfessionalProjectRawReview,
        sessionUnlocked: Bool,
        quotaPolicyVersion: Int,
        hostedGlobalVersion: Int,
        hostedWorkspaceVersion: Int
    ) async throws -> ProfessionalProjectSyncStatus {
        guard sessionUnlocked else { throw ProfessionalProjectSyncError.unavailable }
        let package = try await controller.loadPackage(projectID: review.sourceRevision.projectID)
        let currentSource = try await controller.redesignSourceBinding(
            projectID: review.sourceRevision.projectID,
            revisionID: package.manifest.headRevisionID
        )
        guard currentSource == review.sourceRevision else {
            throw ProfessionalProjectSyncError.invalidRawReview
        }
        let stage = try makeOwnedStage(projectID: scratchIdentifier(
            namespace: "raw",
            publicID: review.sourceRevision.projectID
        ))
        defer { try? cleanupOwnedStage(stage) }
        let materializer = ProfessionalRawArchiveMaterializer(fileManager: fileManager)
        let accepted = try materializer.accept(
            review,
            reviewID: "raw-review-\(UUID().uuidString.lowercased())",
            reviewedAt: Date(
                timeIntervalSince1970: floor(now().timeIntervalSince1970)
            )
        )
        let snapshot = try await materializer.build(
            review: review,
            acceptedDisclosure: accepted,
            archiveURL: stage.appendingPathComponent("reviewed-raw-archive.zip")
        )
        return try await uploadRawArchive(
            snapshot,
            sessionUnlocked: true,
            quotaPolicyVersion: quotaPolicyVersion,
            hostedGlobalVersion: hostedGlobalVersion,
            hostedWorkspaceVersion: hostedWorkspaceVersion
        )
    }

    /// Advisory only: an unavailable lease never prevents local saves or
    /// replaces an expected-head append check.
    func acquireLease(
        projectID: String,
        deviceID: String,
        hostedGlobalVersion: Int,
        hostedWorkspaceVersion: Int
    ) async throws -> ProfessionalProjectSyncLease {
        let token = makeLeaseToken()
        let lease = try await transport.acquireLease(.init(
            projectID: projectID,
            deviceID: deviceID,
            requestID: "lease-request-\(UUID().uuidString.lowercased())",
            leaseToken: token,
            hostedGlobalVersion: hostedGlobalVersion,
            hostedWorkspaceVersion: hostedWorkspaceVersion
        ))
        guard lease.status == "acquired" || lease.status == "renewed" else {
            throw ProfessionalProjectSyncError.leaseUnavailable
        }
        try validateLease(lease)
        heldLeaseTokens[projectID] = token
        return .init(status: lease.status, expiresAt: lease.expiresAt, plaintextToken: token)
    }

    func acquireLeaseForLocalProject(
        localProjectID: String,
        deviceID: String,
        hostedGlobalVersion: Int,
        hostedWorkspaceVersion: Int
    ) async throws -> ProfessionalProjectSyncLease {
        try await acquireLease(
            projectID: hostedProjectID(forLocalProjectID: localProjectID),
            deviceID: deviceID,
            hostedGlobalVersion: hostedGlobalVersion,
            hostedWorkspaceVersion: hostedWorkspaceVersion
        )
    }

    func renewLease(
        projectID: String,
        hostedGlobalVersion: Int,
        hostedWorkspaceVersion: Int
    ) async throws -> ProfessionalProjectSyncLease {
        guard let token = heldLeaseTokens[projectID] else {
            throw ProfessionalProjectSyncError.leaseUnavailable
        }
        let lease = try await transport.renewLease(
            projectID: projectID,
            leaseToken: token,
            hostedGlobalVersion: hostedGlobalVersion,
            hostedWorkspaceVersion: hostedWorkspaceVersion
        )
        guard lease.status == "renewed" || lease.status == "acquired" else {
            heldLeaseTokens.removeValue(forKey: projectID)
            throw ProfessionalProjectSyncError.leaseUnavailable
        }
        do {
            try validateLease(lease)
        } catch {
            heldLeaseTokens.removeValue(forKey: projectID)
            throw error
        }
        return .init(status: lease.status, expiresAt: lease.expiresAt, plaintextToken: token)
    }

    func renewLeaseForLocalProject(
        localProjectID: String,
        hostedGlobalVersion: Int,
        hostedWorkspaceVersion: Int
    ) async throws -> ProfessionalProjectSyncLease {
        try await renewLease(
            projectID: hostedProjectID(forLocalProjectID: localProjectID),
            hostedGlobalVersion: hostedGlobalVersion,
            hostedWorkspaceVersion: hostedWorkspaceVersion
        )
    }

    func releaseLease(
        projectID: String,
        hostedGlobalVersion: Int,
        hostedWorkspaceVersion: Int
    ) async throws {
        guard let token = heldLeaseTokens[projectID] else { return }
        let release = try await transport.releaseLease(
            projectID: projectID,
            leaseToken: token,
            hostedGlobalVersion: hostedGlobalVersion,
            hostedWorkspaceVersion: hostedWorkspaceVersion
        )
        // A transient response failure intentionally leaves the process token
        // available for an exact release retry. Explicit unavailability (or a
        // provider that reports expiry) means it is no longer held.
        switch release.status {
        case "released":
            heldLeaseTokens.removeValue(forKey: projectID)
        case "unavailable", "expired":
            heldLeaseTokens.removeValue(forKey: projectID)
            throw ProfessionalProjectSyncError.leaseUnavailable
        default:
            throw ProfessionalProjectSyncError.invalidResponse
        }
    }

    func releaseLeaseForLocalProject(
        localProjectID: String,
        hostedGlobalVersion: Int,
        hostedWorkspaceVersion: Int
    ) async throws {
        try await releaseLease(
            projectID: hostedProjectID(forLocalProjectID: localProjectID),
            hostedGlobalVersion: hostedGlobalVersion,
            hostedWorkspaceVersion: hostedWorkspaceVersion
        )
    }

    private func hostedProjectID(forLocalProjectID localProjectID: String) throws -> String {
        guard let record = try journal.load(localProjectID: localProjectID),
              let hostedProjectID = record.hostedProjectID,
              ProfessionalProjectSyncJournalRecord.isHostedProjectID(hostedProjectID)
        else { throw ProfessionalProjectSyncError.sourceUnavailable }
        return hostedProjectID
    }

    private struct ExpectedUpload {
        let projectID: String?
        let uploadID: String
        let candidateRevisionID: String?
        let archiveSHA256: String?
        let archiveByteCount: UInt64?

        init(allocation: ProfessionalProjectSyncUploadAllocation) {
            projectID = allocation.projectID
            uploadID = allocation.uploadID
            candidateRevisionID = allocation.candidateRevisionID
            archiveSHA256 = allocation.archiveSHA256
            archiveByteCount = allocation.archiveByteCount
        }

        init(
            projectID: String?,
            uploadID: String,
            candidateRevisionID: String?,
            archiveSHA256: String?,
            archiveByteCount: UInt64?
        ) {
            self.projectID = projectID
            self.uploadID = uploadID
            self.candidateRevisionID = candidateRevisionID
            self.archiveSHA256 = archiveSHA256
            self.archiveByteCount = archiveByteCount
        }
    }

    private func status(
        from allocation: ProfessionalProjectSyncUploadAllocation
    ) -> ProfessionalProjectSyncUploadStatus {
        .init(
            status: allocation.status,
            projectID: allocation.projectID,
            uploadID: allocation.uploadID,
            candidateRevisionID: allocation.candidateRevisionID,
            currentHostedHeadRevisionID: allocation.currentHostedHeadRevisionID,
            archiveSHA256: allocation.archiveSHA256,
            archiveByteCount: allocation.archiveByteCount,
            allocationExpiresAt: allocation.allocationExpiresAt
        )
    }

    private func reconcileInterruptedUpload(
        originalError: Error,
        expected: ExpectedUpload,
        localProjectID: String,
        localHeadRevisionID: String
    ) async throws -> ProfessionalProjectSyncPresentationState {
        do {
            let observed = try await transport.uploadStatus(uploadID: expected.uploadID)
            try validate(status: observed, expected: expected)
            switch observed.status {
            case .canonical, .stale, .rejected:
                return try await applyHostedStatus(
                    observed,
                    expected: expected,
                    localProjectID: localProjectID,
                    localHeadRevisionID: localHeadRevisionID
                )
            case .validationPending, .validating:
                return try await pollHostedStatus(
                    initial: observed,
                    expected: expected,
                    localProjectID: localProjectID,
                    localHeadRevisionID: localHeadRevisionID
                )
            case .allocated:
                guard (originalError as? ProfessionalProjectSyncError) == .signedUploadPreconditionFailed else {
                    throw originalError
                }
                let completion = try await transport.complete(uploadID: expected.uploadID)
                return try await pollHostedStatus(
                    initial: completion,
                    expected: expected,
                    localProjectID: localProjectID,
                    localHeadRevisionID: localHeadRevisionID
                )
            case .attached:
                throw ProfessionalProjectSyncError.invalidResponse
            }
        } catch {
            // Preserve the primary transfer failure and its resumable journal
            // record when first-party reconciliation cannot prove state.
            throw originalError
        }
    }

    private func reconcileRawInterruptedUpload(
        originalError: Error,
        allocation: ProfessionalProjectSyncUploadAllocation,
        expectedProjectID: String,
        expectedRevisionID: String
    ) async throws -> ProfessionalProjectSyncStatus {
        do {
            let observed = try await transport.uploadStatus(uploadID: allocation.uploadID)
            try validateRaw(
                status: observed,
                allocation: allocation,
                expectedProjectID: expectedProjectID,
                expectedRevisionID: expectedRevisionID
            )
            switch observed.status {
            case .attached, .rejected:
                return observed.status
            case .validationPending, .validating:
                return try await pollRawStatus(
                    initial: observed,
                    allocation: allocation,
                    expectedProjectID: expectedProjectID,
                    expectedRevisionID: expectedRevisionID
                )
            case .allocated:
                guard (originalError as? ProfessionalProjectSyncError) == .signedUploadPreconditionFailed else {
                    throw originalError
                }
                return try await pollRawStatus(
                    initial: try await transport.complete(uploadID: allocation.uploadID),
                    allocation: allocation,
                    expectedProjectID: expectedProjectID,
                    expectedRevisionID: expectedRevisionID
                )
            case .canonical, .stale:
                throw ProfessionalProjectSyncError.invalidResponse
            }
        } catch {
            throw originalError
        }
    }

    private func pollHostedStatus(
        initial: ProfessionalProjectSyncUploadStatus,
        expected: ExpectedUpload,
        localProjectID: String,
        localHeadRevisionID: String
    ) async throws -> ProfessionalProjectSyncPresentationState {
        var status = initial
        for attempt in 0..<Self.maximumStatusPolls {
            try validate(status: status, expected: expected)
            switch status.status {
            case .canonical, .stale, .rejected:
                return try await applyHostedStatus(
                    status,
                    expected: expected,
                    localProjectID: localProjectID,
                    localHeadRevisionID: localHeadRevisionID
                )
            case .allocated, .validationPending, .validating:
                if attempt == Self.maximumStatusPolls - 1 {
                    return try await applyHostedStatus(
                        status,
                        expected: expected,
                        localProjectID: localProjectID,
                        localHeadRevisionID: localHeadRevisionID
                    )
                }
                await waitForPoll(Self.pollDelayNanoseconds(afterAttempt: attempt))
                status = try await transport.uploadStatus(uploadID: expected.uploadID)
            case .attached:
                // `attached` is raw-archive-only vocabulary. A working set
                // must reach canonical, stale, or rejected.
                throw ProfessionalProjectSyncError.invalidResponse
            }
        }
        throw ProfessionalProjectSyncError.invalidResponse
    }

    private func pollRawStatus(
        initial: ProfessionalProjectSyncUploadStatus,
        allocation: ProfessionalProjectSyncUploadAllocation,
        expectedProjectID: String,
        expectedRevisionID: String
    ) async throws -> ProfessionalProjectSyncStatus {
        var status = initial
        for attempt in 0..<Self.maximumStatusPolls {
            try validateRaw(
                status: status,
                allocation: allocation,
                expectedProjectID: expectedProjectID,
                expectedRevisionID: expectedRevisionID
            )
            switch status.status {
            case .attached, .rejected:
                return status.status
            case .allocated, .validationPending, .validating:
                guard attempt < Self.maximumStatusPolls - 1 else { return status.status }
                await waitForPoll(Self.pollDelayNanoseconds(afterAttempt: attempt))
                status = try await transport.uploadStatus(uploadID: allocation.uploadID)
            case .canonical, .stale:
                throw ProfessionalProjectSyncError.invalidResponse
            }
        }
        throw ProfessionalProjectSyncError.invalidResponse
    }

    private func applyHostedStatus(
        _ status: ProfessionalProjectSyncUploadStatus,
        expected: ExpectedUpload,
        localProjectID: String,
        localHeadRevisionID: String
    ) async throws -> ProfessionalProjectSyncPresentationState {
        try validate(status: status, expected: expected)
        var record = try journal.load(localProjectID: localProjectID)
            ?? ProfessionalProjectSyncJournalRecord(localProjectID: localProjectID)
        record.hostedProjectID = status.projectID
        record.uploadID = status.uploadID
        record.candidateRevisionID = status.candidateRevisionID
        record.status = status.status
        switch status.status {
        case .canonical:
            guard let canonical = status.candidateRevisionID else {
                throw ProfessionalProjectSyncError.invalidResponse
            }
            record.acknowledgedLocalHeadRevisionID = localHeadRevisionID
            record.acknowledgedHostedHeadRevisionID = canonical
            record.localDraftHeadRevisionID = nil
            record.canonicalRevisionID = canonical
            record.currentHostedHeadRevisionID = canonical
            record.staleRevisionID = nil
            try journal.replace(record)
            return .canonical
        case .stale:
            guard let stale = status.candidateRevisionID,
                  let canonical = status.currentHostedHeadRevisionID
            else { throw ProfessionalProjectSyncError.invalidResponse }
            record.canonicalRevisionID = canonical
            record.currentHostedHeadRevisionID = canonical
            record.staleRevisionID = stale
            record.localDraftHeadRevisionID = localHeadRevisionID
            try journal.replace(record)
            return .conflict(.init(
                hostedProjectID: status.projectID,
                canonicalRevisionID: canonical,
                staleRevisionID: stale
            ))
        case .allocated, .validationPending, .validating:
            try journal.replace(record)
            return .awaitingValidation
        case .rejected:
            try journal.replace(record)
            return .rejected
        case .attached:
            throw ProfessionalProjectSyncError.invalidResponse
        }
    }

    private func conflictState(
        from record: ProfessionalProjectSyncJournalRecord
    ) throws -> ProfessionalProjectSyncPresentationState {
        guard let projectID = record.hostedProjectID,
              let canonical = record.currentHostedHeadRevisionID ?? record.canonicalRevisionID,
              let stale = record.staleRevisionID ?? record.candidateRevisionID
        else { throw ProfessionalProjectSyncError.invalidPublicState }
        return .conflict(.init(
            hostedProjectID: projectID,
            canonicalRevisionID: canonical,
            staleRevisionID: stale
        ))
    }

    private func validate(preview: ProfessionalProjectSyncPreview) throws {
        let age = now().timeIntervalSince(preview.approval.issuedAt)
        guard age >= 0, age <= Self.approvalLifetime else {
            throw ProfessionalProjectSyncError.approvalExpired
        }
        guard preview.approval.localProjectID == preview.localProjectID,
              preview.approval.localHeadRevisionID == preview.localHeadRevisionID,
              preview.approval.archiveSHA256 == preview.archiveSHA256,
              preview.approval.archiveByteCount == preview.archiveByteCount,
              ProfessionalProjectSyncJournalRecord.isSafeIdentifier(preview.localProjectID),
              ProfessionalProjectSyncJournalRecord.isSafeIdentifier(preview.localHeadRevisionID),
              ProfessionalProjectSyncJournalRecord.isSHA256(preview.archiveSHA256),
              preview.archiveByteCount > 0
        else { throw ProfessionalProjectSyncError.approvalMismatch }
    }

    private func validate(
        allocation: ProfessionalProjectSyncUploadAllocation,
        preview: ProfessionalProjectSyncPreview,
        expectedHostedProjectID: String?
    ) throws {
        guard ProfessionalProjectSyncJournalRecord.isHostedProjectID(allocation.projectID),
              ProfessionalProjectSyncJournalRecord.isHostedUploadID(allocation.uploadID),
              allocation.candidateRevisionID.map(ProfessionalProjectSyncJournalRecord.isHostedRevisionID) == true,
              allocation.currentHostedHeadRevisionID.map(ProfessionalProjectSyncJournalRecord.isHostedRevisionID) ?? true,
              allocation.archiveSHA256 == preview.archiveSHA256,
              allocation.archiveByteCount == preview.archiveByteCount,
              allocation.archiveByteCount > 0,
              allocation.archiveByteCount <= ProfessionalProjectSyncPreview.maximumHostedWorkingArchiveBytes,
              expectedHostedProjectID == nil || allocation.projectID == expectedHostedProjectID,
              allocation.status != .attached,
              allocation.status != .allocated || isFreshAllocation(allocation.allocationExpiresAt)
        else { throw ProfessionalProjectSyncError.invalidResponse }
    }

    private func validateRaw(
        allocation: ProfessionalProjectSyncUploadAllocation,
        expectedProjectID: String,
        expectedRevisionID: String,
        archiveSHA256: String,
        archiveByteCount: UInt64
    ) throws {
        guard ProfessionalProjectSyncJournalRecord.isHostedProjectID(allocation.projectID),
              ProfessionalProjectSyncJournalRecord.isHostedUploadID(allocation.uploadID),
              ProfessionalProjectSyncJournalRecord.isHostedProjectID(expectedProjectID),
              ProfessionalProjectSyncJournalRecord.isHostedRevisionID(expectedRevisionID),
              allocation.projectID == expectedProjectID,
              allocation.candidateRevisionID == expectedRevisionID,
              allocation.archiveSHA256 == archiveSHA256,
              allocation.archiveByteCount == archiveByteCount,
              allocation.archiveByteCount > 0,
              allocation.archiveByteCount <= ProfessionalProjectSyncPreview.maximumHostedWorkingArchiveBytes,
              allocation.status != .canonical,
              allocation.status != .stale,
              allocation.status != .allocated || isFreshAllocation(allocation.allocationExpiresAt)
        else { throw ProfessionalProjectSyncError.invalidResponse }
    }

    private func validateRaw(
        status: ProfessionalProjectSyncUploadStatus,
        allocation: ProfessionalProjectSyncUploadAllocation,
        expectedProjectID: String,
        expectedRevisionID: String
    ) throws {
        guard ProfessionalProjectSyncJournalRecord.isHostedProjectID(status.projectID),
              ProfessionalProjectSyncJournalRecord.isHostedUploadID(status.uploadID),
              ProfessionalProjectSyncJournalRecord.isHostedProjectID(expectedProjectID),
              ProfessionalProjectSyncJournalRecord.isHostedRevisionID(expectedRevisionID),
              status.projectID == expectedProjectID,
              status.uploadID == allocation.uploadID,
              status.candidateRevisionID == expectedRevisionID,
              status.archiveSHA256 == allocation.archiveSHA256,
              status.archiveByteCount == allocation.archiveByteCount,
              status.archiveByteCount > 0,
              status.archiveByteCount <= ProfessionalProjectSyncPreview.maximumHostedWorkingArchiveBytes,
              status.status != .canonical,
              status.status != .stale
        else { throw ProfessionalProjectSyncError.invalidResponse }
    }

    private func validate(
        status: ProfessionalProjectSyncUploadStatus,
        expected: ExpectedUpload
    ) throws {
        guard ProfessionalProjectSyncJournalRecord.isHostedProjectID(status.projectID),
              ProfessionalProjectSyncJournalRecord.isHostedUploadID(status.uploadID),
              ProfessionalProjectSyncJournalRecord.isSHA256(status.archiveSHA256),
              status.archiveByteCount > 0,
              status.archiveByteCount <= ProfessionalProjectSyncPreview.maximumHostedWorkingArchiveBytes,
              status.uploadID == expected.uploadID,
              expected.projectID == nil || status.projectID == expected.projectID,
              expected.archiveSHA256 == nil || status.archiveSHA256 == expected.archiveSHA256,
              expected.archiveByteCount == nil || status.archiveByteCount == expected.archiveByteCount,
              expected.candidateRevisionID == nil || status.candidateRevisionID == expected.candidateRevisionID,
              status.candidateRevisionID.map(ProfessionalProjectSyncJournalRecord.isHostedRevisionID) ?? true,
              status.currentHostedHeadRevisionID.map(ProfessionalProjectSyncJournalRecord.isHostedRevisionID) ?? true,
              status.status != .attached
        else { throw ProfessionalProjectSyncError.invalidResponse }
    }

    private func validate(
        recovery: ProfessionalProjectSyncRecovery,
        requestedProjectID: String,
        requestedRevisionID: String?
    ) throws {
        try recovery.validate()
        guard ProfessionalProjectSyncJournalRecord.isHostedProjectID(requestedProjectID),
              requestedRevisionID == nil || ProfessionalProjectSyncJournalRecord.isHostedRevisionID(requestedRevisionID!),
              recovery.projectID == requestedProjectID,
              requestedRevisionID == nil || recovery.revisionID == requestedRevisionID,
              recovery.archiveByteCount <= ProfessionalProjectSyncPreview.maximumHostedWorkingArchiveBytes
        else { throw ProfessionalProjectSyncError.invalidResponse }
    }

    private func stableIdempotencyDigest(
        projectID: String,
        headRevisionID: String,
        archiveSHA256: String
    ) -> String {
        RoomSHA256.hexDigest(of: Data(
            "roomscan-professional-working-set-v1\u{0}\(projectID)\u{0}\(headRevisionID)\u{0}\(archiveSHA256)".utf8
        ))
    }

    private func rawIdempotencyDigest(
        hostedProjectID: String,
        hostedRevisionID: String,
        archiveSHA256: String,
        reviewSHA256: String
    ) -> String {
        RoomSHA256.hexDigest(of: Data(
            "roomscan-professional-raw-archive-v1\u{0}\(hostedProjectID)\u{0}\(hostedRevisionID)\u{0}\(archiveSHA256)\u{0}\(reviewSHA256)".utf8
        ))
    }

    private func makeRecoveryCoordinator() throws -> ProfessionalProjectRecoveryCoordinator {
        if let recoveryCoordinator { return recoveryCoordinator }
        guard let modelFactory else { throw ProfessionalProjectSyncError.unavailable }
        let created = try modelFactory.makeProfessionalRecoveryCoordinator(
            scratchRootURL: scratchRootURL.appendingPathComponent("recovery", isDirectory: true),
            journal: journal
        )
        recoveryCoordinator = created
        return created
    }

    private func copyIdentifier() throws -> String {
        let identifier = makeIdentifier()
        guard ProfessionalProjectSyncJournalRecord.isSafeIdentifier(identifier) else {
            throw ProfessionalProjectSyncError.invalidPublicState
        }
        return identifier
    }

    private func markAwaitingUserEdit(
        _ result: RoomProfessionalRecoveryResult
    ) throws {
        guard result.recoveredAsCopy else { throw ProfessionalProjectSyncError.invalidResponse }
        var record = try journal.load(localProjectID: result.projectSummary.projectID)
            ?? ProfessionalProjectSyncJournalRecord(localProjectID: result.projectSummary.projectID)
        record.status = .attached
        record.localDraftHeadRevisionID = result.projectSummary.headRevisionID
        // The recovery coordinator has already acknowledged the resulting
        // package, journal, and Core scratch cleanup before it returns. A
        // recovered copy deliberately has no hosted mapping and no resumable
        // Core transaction; it is only an explicit local draft.
        record.recoveryTransactionID = nil
        record.recoveryPhase = .none
        try journal.replace(record)
    }

    private struct DownloadedEnvelope {
        let extraction: RoomProfessionalWorkingSetExtraction
        let manifestSHA256: String
        let packageManifest: RoomBackupManifest
        let packageManifestSHA256: String
        let sourceSemanticSHA256: String
    }

    private func downloadAndExtract(
        projectID: String,
        revisionID: String
    ) async throws -> DownloadedEnvelope {
        let download = try await transport.allocateRecovery(projectID: projectID, revisionID: revisionID)
        try validate(
            recovery: download.recovery,
            requestedProjectID: projectID,
            requestedRevisionID: revisionID
        )
        let stage = try makeOwnedStage(projectID: scratchIdentifier(namespace: "compare", publicID: projectID))
        defer { try? cleanupOwnedStage(stage) }
        let archiveURL = stage.appendingPathComponent("comparison-working-set.zip")
        try await transport.download(download, to: archiveURL)
        let inspection = stage.appendingPathComponent("inspection", isDirectory: true)
        try fileManager.createDirectory(at: inspection, withIntermediateDirectories: false)
        let descriptor = try await RoomProfessionalWorkingSetArchive.inspectDownloadedArchive(
            archiveURL: archiveURL,
            expectedManifestSHA256: download.recovery.workingSetManifestSHA256,
            expectedArchiveSHA256: download.recovery.archiveSHA256,
            expectedArchiveByteCount: download.recovery.archiveByteCount,
            in: inspection
        )
        let extractionDirectory = stage.appendingPathComponent("comparison-extraction", isDirectory: true)
        try fileManager.createDirectory(at: extractionDirectory, withIntermediateDirectories: false)
        let extraction = try await RoomProfessionalWorkingSetArchive.extractAndVerify(
            archiveURL: archiveURL,
            expectedDescriptor: descriptor,
            into: extractionDirectory
        )
        let innerVerification = stage.appendingPathComponent("inner-package", isDirectory: true)
        try fileManager.createDirectory(at: innerVerification, withIntermediateDirectories: false)
        let packageManifest = try await RoomProjectBackupArchive.extractAndVerify(
            archiveURL: extractionDirectory.appendingPathComponent(
                RoomProfessionalWorkingSetArchive.packageBackupEntryPath
            ),
            expectedDescriptor: descriptor.packageDescriptor,
            into: innerVerification
        )
        return .init(
            extraction: extraction,
            manifestSHA256: download.recovery.workingSetManifestSHA256,
            packageManifest: packageManifest,
            packageManifestSHA256: RoomSHA256.hexDigest(of: try RoomJSONCoding.makeEncoder().encode(packageManifest)),
            sourceSemanticSHA256: try sourceSemanticDigest(from: packageManifest)
        )
    }

    private func sourceSemanticDigest(from manifest: RoomBackupManifest) throws -> String {
        let path = "revisions/\(manifest.headRevisionID)/semantic-model.json"
        guard let entry = manifest.entries.first(where: { $0.packageRelativePath == path }),
              ProfessionalProjectSyncJournalRecord.isSHA256(entry.sha256Hex)
        else { throw ProfessionalProjectSyncError.invalidResponse }
        return entry.sha256Hex
    }

    private func workingCategorySummaries(
        from entries: [RoomProfessionalWorkingSetEntry]
    ) throws -> [ProfessionalProjectWorkingCategorySummary] {
        var counts = Dictionary(
            uniqueKeysWithValues: ProfessionalProjectWorkingCategory.allCases.map { ($0, 0) }
        )
        var bytes = Dictionary(
            uniqueKeysWithValues: ProfessionalProjectWorkingCategory.allCases.map { ($0, UInt64.zero) }
        )
        for entry in entries {
            let category: ProfessionalProjectWorkingCategory
            switch entry.kind {
            case .packageBackup: category = .packageBackup
            case .redesignCompanion: category = .redesignCompanion
            case .conceptSetManifest: category = .conceptSetManifest
            case .conceptSetAttachment: category = .conceptSetAttachment
            case .conceptSourcePackageProvenance: category = .conceptSourcePackageProvenance
            case .raw:
                // Core already rejects raw working-set entries. Keep a second
                // app boundary so UI can never accidentally describe one as
                // recoverable default data.
                throw ProfessionalProjectSyncError.invalidResponse
            }
            counts[category, default: 0] += 1
            bytes[category, default: 0] += entry.byteCount
        }
        return ProfessionalProjectWorkingCategory.allCases.compactMap { category in
            guard let itemCount = counts[category], itemCount > 0,
                  let byteCount = bytes[category]
            else { return nil }
            return .init(category: category, itemCount: itemCount, byteCount: byteCount)
        }
    }

    private func archiveDigest(of archiveURL: URL) throws -> (sha256: String, byteCount: UInt64) {
        let values = try archiveURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size > 0
        else { throw ProfessionalProjectSyncError.archiveChanged }
        return (try RoomSHA256.hexDigest(ofFile: archiveURL), UInt64(size))
    }

    private func makeLeaseToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private func validateLease(_ lease: ProfessionalProjectSyncLease) throws {
        guard let expiresAt = lease.expiresAt,
              expiresAt > now(),
              expiresAt.timeIntervalSince(now()) <= 900
        else { throw ProfessionalProjectSyncError.invalidResponse }
    }

    private func isFreshAllocation(_ expiresAt: Date) -> Bool {
        let current = now()
        return expiresAt > current
            && expiresAt.timeIntervalSince(current) <= 305
    }

    private static func pollDelayNanoseconds(afterAttempt attempt: Int) -> UInt64 {
        // 250 ms, 500 ms, … 1.75 s. Tests inject a no-op observer rather than
        // sleeping; production avoids a tight status-poll loop.
        UInt64(attempt + 1) * 250_000_000
    }

    private func completeMigration(
        _ state: ProfessionalProjectSyncPresentationState,
        preview: ProfessionalProjectSyncPreview
    ) -> ProfessionalProjectSyncPresentationState {
        switch state {
        case .canonical, .conflict, .rejected:
            try? cleanupOwnedStage(preview.stagedArchiveURL.deletingLastPathComponent())
        case .idle, .localDraft, .previewReady, .uploading, .awaitingValidation,
             .awaitingUserEdit, .recoveryReady:
            break
        }
        return state
    }

    /// Scratch identifiers are derived from public IDs rather than containing
    /// them. This keeps the marker-owned path within the journal identifier
    /// bounds even when a provider uses the full permitted 128-character ID.
    private func scratchIdentifier(namespace: String, publicID: String) -> String {
        let digest = RoomSHA256.hexDigest(of: Data(publicID.utf8))
        return "\(namespace)-\(digest.prefix(32))"
    }

    private func makeOwnedStage(projectID: String) throws -> URL {
        guard ProfessionalProjectSyncJournalRecord.isSafeIdentifier(projectID) else {
            throw ProfessionalProjectSyncError.invalidPublicState
        }
        try establishScratchRoot()
        let stage = scratchRootURL.appendingPathComponent(
            ".roomscan-professional-sync-stage-\(projectID)-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        guard !fileManager.fileExists(atPath: stage.path) else {
            throw ProfessionalProjectSyncError.unsafeScratch
        }
        do {
            try fileManager.createDirectory(at: stage, withIntermediateDirectories: false)
        } catch {
            throw ProfessionalProjectSyncError.unsafeScratch
        }
        try requireRealDirectory(stage)
        let marker = stage.appendingPathComponent(Self.stageMarkerFilename)
        do {
            try Self.stageMarkerData.write(to: marker, options: [.withoutOverwriting])
        } catch {
            throw ProfessionalProjectSyncError.unsafeScratch
        }
        try requireOwnedStage(stage)
        return stage
    }

    private func cleanupOwnedStage(_ stage: URL) throws {
        let root = scratchRootURL.standardizedFileURL
        let candidate = stage.standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? String(root.path.dropLast()) : root.path
        guard candidate.path.hasPrefix(rootPath + "/") else {
            throw ProfessionalProjectSyncError.unsafeScratch
        }
        try requireOwnedStage(candidate)
        try fileManager.removeItem(at: candidate)
    }

    private func establishScratchRoot() throws {
        try requireNoSymlinkInExistingAncestors(of: scratchRootURL)
        if pathExists(scratchRootURL) {
            try requireRealDirectory(scratchRootURL)
        } else {
            do {
                try fileManager.createDirectory(at: scratchRootURL, withIntermediateDirectories: true)
            } catch {
                throw ProfessionalProjectSyncError.unsafeScratch
            }
            try requireRealDirectory(scratchRootURL)
        }
        let marker = scratchRootURL.appendingPathComponent(Self.scratchMarkerFilename)
        let markerData = Data("roomscan-professional-sync-scratch-v1".utf8)
        if pathExists(marker) {
            try requireRealRegularFile(marker)
            guard fileManager.contents(atPath: marker.path) == markerData else {
                throw ProfessionalProjectSyncError.unsafeScratch
            }
        } else {
            do {
                try markerData.write(to: marker, options: .withoutOverwriting)
            } catch {
                throw ProfessionalProjectSyncError.unsafeScratch
            }
        }
        try recoverOwnedScratchOrphansIfNeeded()
    }

    private func recoverOwnedScratchOrphansIfNeeded() throws {
        guard !hasRecoveredScratchOrphans else { return }
        let entries = try fileManager.contentsOfDirectory(
            at: scratchRootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        for entry in entries where entry.lastPathComponent.hasPrefix(
            ".roomscan-professional-sync-stage-"
        ) {
            // The root marker and stage-looking name are not authority to
            // delete another process's directory. A private per-stage marker
            // must be present and exact; unsafe/unowned entries remain for
            // operator inspection and fail closed before new staging begins.
            try requireOwnedStage(entry)
            try fileManager.removeItem(at: entry)
        }
        hasRecoveredScratchOrphans = true
    }

    private func requireNoSymlinkInExistingAncestors(of url: URL) throws {
        guard RoomStorageAncestorSafety.existingAncestorsAreSafe(of: url, fileManager: fileManager) else {
            throw ProfessionalProjectSyncError.unsafeScratch
        }
    }

    private func requireOwnedStage(_ stage: URL) throws {
        guard stage.lastPathComponent.hasPrefix(".roomscan-professional-sync-stage-") else {
            throw ProfessionalProjectSyncError.unsafeScratch
        }
        try requireRealDirectory(stage)
        let marker = stage.appendingPathComponent(Self.stageMarkerFilename)
        try requireRealRegularFile(marker)
        guard fileManager.contents(atPath: marker.path) == Self.stageMarkerData else {
            throw ProfessionalProjectSyncError.unsafeScratch
        }
    }

    private func requireRealDirectory(_ url: URL) throws {
        try requireNoSymlinkInExistingAncestors(of: url)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch {
            throw ProfessionalProjectSyncError.unsafeScratch
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw ProfessionalProjectSyncError.unsafeScratch
        }
    }

    private func requireRealRegularFile(_ url: URL) throws {
        try requireNoSymlinkInExistingAncestors(of: url)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch {
            throw ProfessionalProjectSyncError.unsafeScratch
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ProfessionalProjectSyncError.unsafeScratch
        }
    }

    private func pathExists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
