import Combine
import Foundation
import RoomScanCore

/// The value the host supplies after it has persisted the user's local
/// redesign intent.  The source revision is intentionally carried through
/// every call; a view cannot switch a room or revision underneath a review.
struct RoomAIRedesignPackageRequest {
    let sourceRevision: RoomRedesignSourceRevision
    let profile: RoomAIRoomPackageProfile
    let brief: String
    let scope: RoomRedesignScope
    let featureChoices: [String: RoomAIChangeRequest]
}

/// A presentation request rather than a file URL. The host owns document
/// pickers and sends their selected URL back through `completeFileImport`.
/// Keeping that boundary explicit means this model never retains security
/// scoped URLs or creates a provider integration.
enum RoomAIConceptFileImportRequest: String, Identifiable {
    case looseConcept
    case conceptPackage
    case replacementImage

    var id: String { rawValue }
}

/// A one-shot host presentation request. The archive remains local until the
/// host observes this value and presents the platform-owned Share Sheet.
struct RoomAISharePresentationRequest: Identifiable, Equatable {
    let id: UUID
    let archiveURL: URL

    init(archiveURL: URL) {
        id = UUID()
        self.archiveURL = archiveURL
    }
}

/// Read-only bytes for the generic side-by-side comparison surface. Concept
/// media is loaded from the validated local Concept Set store; the optional
/// original preview is supplied by the host for this exact source revision.
struct RoomAIConceptComparisonPresentation: Identifiable, Equatable {
    let conceptID: String
    let conceptName: String
    let sourceRevisionID: String
    let mappingDetail: String
    let conceptAttachmentData: Data
    let originalPreviewData: Data?

    var id: String { conceptID }
}

/// Narrow, injectable app seams. The materialization closure is responsible
/// for loading the exact sealed package and companion for `sourceRevision`,
/// persisting this local request, and invoking the offline materializer.
@MainActor
struct RoomAIRedesignProductionDependencies {
    let materialize: (RoomAIRedesignPackageRequest) async throws -> RoomAIRoomPackageMaterialization
    let packageService: any RoomAIRoomPackageServicing
    let disclosure: RoomAIDisclosureCoordinator
    let concepts: RoomConceptImportCoordinator
    let conceptContext: RoomConceptSetValidationContext
    let canonicalViewChoices: [String]
    /// Generates a package capability for this exact source revision. The
    /// production factory reloads a previously finalized capability and only
    /// mints a new one before the first successful finalization.
    let packageIdentifier: (RoomAIRedesignPackageRequest) throws -> String
    /// Persists a package capability only after `finalize` has returned its
    /// independently validated archive result. `nil` keeps automatic Concept
    /// mapping fail-closed for fixture-only models.
    let persistValidatedSourcePackage: ((RoomAIRoomPackageArchiveResult) throws -> RoomConceptSetValidationContext)?
    /// Returns a local, display-only original-room preview for the supplied
    /// sealed revision. `nil` keeps comparison concept-only; no network or
    /// provider fallback is attempted.
    let originalComparisonImageData: ((RoomRedesignSourceRevision) async throws -> Data?)?
    /// Registers a newly selected local replacement as an exact candidate for
    /// this revision. It must sanitize and source-bind before returning its
    /// candidate ID; absent wiring fails closed.
    let registerReplacement: ((String, URL, RoomRedesignSourceRevision) async throws -> String)?

    init(
        materialize: @escaping (RoomAIRedesignPackageRequest) async throws -> RoomAIRoomPackageMaterialization,
        packageService: any RoomAIRoomPackageServicing,
        disclosure: RoomAIDisclosureCoordinator,
        concepts: RoomConceptImportCoordinator,
        conceptContext: RoomConceptSetValidationContext,
        canonicalViewChoices: [String],
        packageIdentifier: @escaping (RoomAIRedesignPackageRequest) throws -> String = {
            _ in "ai-room-\(UUID().uuidString.lowercased())"
        },
        persistValidatedSourcePackage: ((RoomAIRoomPackageArchiveResult) throws -> RoomConceptSetValidationContext)? = nil,
        originalComparisonImageData: ((RoomRedesignSourceRevision) async throws -> Data?)? = nil,
        registerReplacement: ((String, URL, RoomRedesignSourceRevision) async throws -> String)? = nil
    ) {
        self.materialize = materialize
        self.packageService = packageService
        self.disclosure = disclosure
        self.concepts = concepts
        self.conceptContext = conceptContext
        self.canonicalViewChoices = canonicalViewChoices.sorted()
        self.packageIdentifier = packageIdentifier
        self.persistValidatedSourcePackage = persistValidatedSourcePackage
        self.originalComparisonImageData = originalComparisonImageData
        self.registerReplacement = registerReplacement
    }
}

/// Production adapter for `RoomAIRedesignView`. It has no network or provider
/// implementation: it prepares a local archive and asks its host to present
/// the system share sheet only after an exact, single-use disclosure approval.
@MainActor
final class RoomAIRedesignProductionModel: RoomAIRedesignScreenModel {
    @Published var selectedProfile: RoomAIRedesignProfile = .aiReady {
        didSet { invalidateReviewIfNeeded() }
    }
    @Published var brief: String = "" {
        didSet { invalidateReviewIfNeeded() }
    }
    @Published var intent: String = "Stage" {
        didSet { invalidateReviewIfNeeded() }
    }
    @Published var featureChoices: [String: RoomAIChangeRequest] {
        didSet { invalidateReviewIfNeeded() }
    }
    @Published private(set) var readiness: [RoomAIReadinessItem] = []
    @Published private(set) var images: [RoomAIImageReviewItem] = []
    @Published private(set) var inventory: [RoomAIArtifactInventoryItem] = []
    @Published private(set) var qualityAdvisories: [String] = []
    @Published private(set) var estimatedSize: String = "—"
    @Published private(set) var reviewState: RoomAIReviewState = .drafting
    @Published private(set) var reviewInputsLocked = false
    @Published private(set) var includesRawEvidence = false
    @Published var externalProviderNoticeAccepted: Bool = false {
        didSet {
            guard oldValue != externalProviderNoticeAccepted,
                  reviewState == .readyForReview else { return }
            reviewMessage = externalProviderNoticeAccepted
                ? "External-provider terms acknowledgement recorded for this review."
                : "Acknowledge the external-provider boundary before approval."
        }
    }
    @Published var completeRawConsent: Bool = false {
        didSet {
            guard oldValue != completeRawConsent, reviewState == .readyForReview else { return }
            reviewMessage = "Raw-evidence consent changed. Approve only after reviewing the current inventory."
        }
    }
    @Published private(set) var reviewMessage: String?
    @Published private(set) var concepts: [RoomAIConceptItem] = []
    @Published var selectedConceptID: String?
    let canonicalViewChoices: [String]
    @Published var selectedCanonicalView: String

    /// The host observes this and presents `RoomExportView`/a system sheet,
    /// then calls `completeSystemShare(outcome:)` exactly once per dismissal.
    @Published private(set) var shareArchiveURL: URL?
    @Published private(set) var sharePresentationRequest: RoomAISharePresentationRequest?
    @Published private(set) var comparisonPresentation: RoomAIConceptComparisonPresentation?
    @Published private(set) var fileImportRequest: RoomAIConceptFileImportRequest?
    @Published private(set) var replacementImageRequestID: String?

    let sourceRevision: RoomRedesignSourceRevision
    private let dependencies: RoomAIRedesignProductionDependencies
    /// Updated only after an independently validated archive capability is
    /// atomically persisted. Every Concept operation reads this value so a
    /// recreated model and the live model enforce the same authority.
    private var conceptContext: RoomConceptSetValidationContext
    private var preparedDraft: RoomAIRoomPackagePreparedDraft?
    private var finalizedArchive: RoomAIRoomPackageArchiveResult?
    private var cleanupLeaseURL: URL?
    private var excludedReferenceIDs = Set<String>()
    private var replacementReferenceIDs = Set<String>()
    private var packageTask: Task<Void, Never>?
    private var packageOperationID: UUID?
    private var activeTask: Task<Void, Never>?
    private var comparisonTask: Task<Void, Never>?
    private var comparisonRequestID: UUID?

    init(
        sourceRevision: RoomRedesignSourceRevision,
        featureChoices: [String: RoomAIChangeRequest] = [:],
        dependencies: RoomAIRedesignProductionDependencies
    ) {
        self.sourceRevision = sourceRevision
        self.featureChoices = featureChoices
        self.dependencies = dependencies
        conceptContext = dependencies.conceptContext
        canonicalViewChoices = dependencies.canonicalViewChoices
        selectedCanonicalView = dependencies.canonicalViewChoices.first ?? ""
        refreshReadiness()
        activeTask = Task { [weak self] in await self?.reloadConcepts() }
    }

    deinit {
        packageTask?.cancel()
        activeTask?.cancel()
        comparisonTask?.cancel()
    }

    func prepareReview() {
        guard packageOperationID == nil, !reviewInputsLocked else {
            reviewMessage = "Wait for the current local package operation to finish cleaning up."
            return
        }
        guard cleanupLeaseURL == nil else {
            reviewState = .cleanupFailed
            reviewMessage = "Temporary archive cleanup needs another attempt before a new review can be prepared."
            return
        }
        guard !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            reviewMessage = "Describe the requested room direction before preparing review."
            return
        }
        let snapshot = currentReviewInputSnapshot
        let request = RoomAIRedesignPackageRequest(
            sourceRevision: sourceRevision,
            profile: snapshot.profile == .aiReady ? .aiReady : .complete,
            brief: snapshot.brief,
            scope: Self.coreScope(for: snapshot.intent),
            featureChoices: snapshot.featureChoices
        )
        let operationID = UUID()
        packageOperationID = operationID
        reviewInputsLocked = true
        reviewState = .drafting
        reviewMessage = "Preparing a local disclosure review. Nothing is uploaded."
        packageTask = Task { [weak self] in
            guard let self else { return }
            var stagingLease: URL?
            var unpublishedDraft: RoomAIRoomPackagePreparedDraft?
            do {
                let materialization = try await dependencies.materialize(request)
                guard materialization.context.sourceRevision == sourceRevision,
                      materialization.profile == request.profile else {
                    throw RoomAIRoomPackageAppServiceError.stalePreparation
                }
                stagingLease = materialization.sourceWorkspaceURL
                try Task.checkCancellation()
                guard isCurrentPackageOperation(operationID, snapshot: snapshot) else {
                    throw CancellationError()
                }
                // From this call until it returns, the service owns cleanup of
                // the materializer's source workspace on every exit path.
                stagingLease = nil
                let draft = try await dependencies.packageService.prepare(
                    materialization: materialization,
                    excludedReferenceIDs: snapshot.excludedReferenceIDs,
                    replacementReferenceIDs: snapshot.replacementReferenceIDs,
                    packageID: try dependencies.packageIdentifier(request)
                )
                unpublishedDraft = draft
                try Task.checkCancellation()
                guard isCurrentPackageOperation(operationID, snapshot: snapshot) else {
                    throw CancellationError()
                }
                try dependencies.disclosure.beginReview(draft.disclosureDraft)
                preparedDraft = draft
                unpublishedDraft = nil
                finalizedArchive = nil
                shareArchiveURL = nil
                sharePresentationRequest = nil
                apply(draft: draft)
                reviewState = .readyForReview
                reviewMessage = "Review the exact selected evidence and disclosure before approving."
                finishPackageOperation(operationID)
            } catch is CancellationError {
                cleanupUnpublishedPackageLease(
                    unpublishedDraft?.workspaceURL ?? stagingLease,
                    operationID: operationID
                )
                finishPackageOperation(operationID)
            } catch {
                cleanupUnpublishedPackageLease(
                    unpublishedDraft?.workspaceURL ?? stagingLease,
                    operationID: operationID
                )
                guard packageOperationID == operationID else {
                    finishPackageOperation(operationID)
                    return
                }
                preparedDraft = nil
                reviewState = .stale
                reviewMessage = actionableMessage(for: error)
                refreshReadiness()
                finishPackageOperation(operationID)
            }
        }
    }

    func excludeImage(_ id: String) {
        guard !reviewInputsLocked,
              images.contains(where: { $0.id == id && $0.allowsSelectionChanges }) else { return }
        if excludedReferenceIDs.contains(id) { excludedReferenceIDs.remove(id) } else { excludedReferenceIDs.insert(id) }
        replacementReferenceIDs.remove(id)
        invalidateReviewIfNeeded(message: "Selected reference evidence changed. Refresh review before approval.")
    }

    func replaceImage(_ id: String) {
        // The actual local file choice is host-owned. Marking a current image
        // as a replacement is deliberately rejected by service preparation
        // unless the host materializer supplies an exact bound candidate.
        guard !reviewInputsLocked,
              images.contains(where: { $0.id == id && $0.allowsSelectionChanges }) else { return }
        replacementImageRequestID = id
        fileImportRequest = .replacementImage
        reviewMessage = "Choose a local image. It will be sanitized and must bind to this sealed room revision before review can refresh."
    }

    func approveReview() {
        guard packageOperationID == nil,
              reviewState == .readyForReview,
              let draft = preparedDraft else {
            reviewMessage = "Prepare a fresh disclosure review before approving."
            return
        }
        guard externalProviderNoticeAccepted else {
            reviewMessage = "Acknowledge the external-provider privacy and account boundary before approving."
            return
        }
        guard !draft.disclosureDraft.includesRawEvidence || completeRawConsent else {
            reviewMessage = "Review and consent to the selected original capture media before approving."
            return
        }
        let snapshot = currentReviewInputSnapshot
        let operationID = UUID()
        packageOperationID = operationID
        reviewInputsLocked = true
        reviewState = .approved
        reviewMessage = "Finalizing the approved local archive."
        packageTask = Task { [weak self] in
            guard let self else { return }
            var producedArchive: RoomAIRoomPackageArchiveResult?
            do {
                _ = try dependencies.disclosure.approve(
                    externalProviderNoticeAccepted: externalProviderNoticeAccepted,
                    rawEvidenceDisclosureAccepted: draft.disclosureDraft.includesRawEvidence && completeRawConsent
                )
                let review = try dependencies.disclosure.consumeApprovedReview(
                    sourceRevision: sourceRevision,
                    artifactPlanSHA256: draft.preparation.artifactPlanSHA256,
                    selectionSHA256: draft.preparation.selectionSHA256
                )
                let archive = try await dependencies.packageService.finalize(draft, disclosureReview: review)
                producedArchive = archive
                try Task.checkCancellation()
                guard isCurrentPackageOperation(operationID, snapshot: snapshot),
                      preparedDraft == draft else {
                    throw CancellationError()
                }
                if let persistValidatedSourcePackage = dependencies.persistValidatedSourcePackage {
                    let updatedContext = try persistValidatedSourcePackage(archive)
                    guard updatedContext.expectedSourceRevision == sourceRevision else {
                        throw RoomAIRoomPackageAppServiceError.stalePreparation
                    }
                    conceptContext = updatedContext
                }
                finalizedArchive = archive
                producedArchive = nil
                shareArchiveURL = archive.archiveURL
                sharePresentationRequest = nil
                reviewState = .archiveReady
                reviewMessage = "Local archive is ready. Sharing remains an explicit system action."
                finishPackageOperation(operationID)
            } catch is CancellationError {
                cleanupUnpublishedPackageLease(
                    producedArchive == nil ? nil : draft.workspaceURL,
                    operationID: operationID
                )
                finishPackageOperation(operationID)
            } catch {
                cleanupUnpublishedPackageLease(
                    FileManager.default.fileExists(atPath: draft.workspaceURL.path)
                        ? draft.workspaceURL
                        : nil,
                    operationID: operationID
                )
                guard packageOperationID == operationID else {
                    finishPackageOperation(operationID)
                    return
                }
                preparedDraft = nil
                finalizedArchive = nil
                shareArchiveURL = nil
                reviewState = .stale
                reviewMessage = actionableMessage(for: error)
                finishPackageOperation(operationID)
            }
        }
    }

    func shareArchive() {
        guard reviewState == .archiveReady,
              let archiveURL = finalizedArchive?.archiveURL,
              sharePresentationRequest == nil else {
            reviewMessage = "Prepare and approve a current local archive before sharing."
            return
        }
        sharePresentationRequest = .init(archiveURL: archiveURL)
        reviewInputsLocked = true
    }

    func completeSystemShare(outcome: SystemShareSheetOutcome) {
        guard sharePresentationRequest != nil,
              let draft = preparedDraft,
              finalizedArchive != nil else { return }
        // UIKit may report terminal dismissal more than once. Clearing first
        // makes the exact lease cleanup below ownership of the first callback.
        sharePresentationRequest = nil
        do {
            try dependencies.packageService.cleanupLease(draft.workspaceURL)
            cleanupLeaseURL = nil
            preparedDraft = nil
            finalizedArchive = nil
            shareArchiveURL = nil
            reviewState = .drafting
            reviewInputsLocked = false
            externalProviderNoticeAccepted = false
            completeRawConsent = false
            includesRawEvidence = false
            reviewMessage = outcome == .failed
                ? "The Share Sheet could not complete the handoff. Its temporary archive was removed; prepare a new review to try again."
                : nil
        } catch {
            cleanupLeaseURL = draft.workspaceURL
            reviewState = .cleanupFailed
            reviewInputsLocked = true
            reviewMessage = "The Share Sheet closed, but temporary archive cleanup needs another attempt."
        }
    }

    /// Host close/dismiss path for an approved but unshared archive. It never
    /// deletes a broad scratch root; a failure remains available to retry.
    @discardableResult
    func discardPreparedArchive() async -> Bool {
        guard sharePresentationRequest == nil else {
            reviewMessage = "Close the system Share Sheet before discarding its local archive."
            return false
        }
        if let inFlight = packageTask {
            inFlight.cancel()
            await inFlight.value
        }
        guard let lease = preparedDraft?.workspaceURL ?? cleanupLeaseURL else {
            guard reviewState != .cleanupFailed else { return false }
            reviewState = .drafting
            reviewInputsLocked = false
            externalProviderNoticeAccepted = false
            completeRawConsent = false
            includesRawEvidence = false
            reviewMessage = nil
            return true
        }
        do {
            try dependencies.packageService.cleanupLease(lease)
            cleanupLeaseURL = nil
            preparedDraft = nil
            finalizedArchive = nil
            shareArchiveURL = nil
            sharePresentationRequest = nil
            reviewState = .drafting
            reviewInputsLocked = false
            externalProviderNoticeAccepted = false
            completeRawConsent = false
            includesRawEvidence = false
            reviewMessage = nil
            return true
        } catch {
            cleanupLeaseURL = lease
            reviewState = .cleanupFailed
            reviewInputsLocked = true
            reviewMessage = "The temporary archive could not be removed. Retry cleanup before closing."
            return false
        }
    }

    func retryCleanup() {
        guard let lease = preparedDraft?.workspaceURL ?? cleanupLeaseURL else { return }
        do {
            try dependencies.packageService.cleanupLease(lease)
            cleanupLeaseURL = nil
            preparedDraft = nil
            finalizedArchive = nil
            shareArchiveURL = nil
            sharePresentationRequest = nil
            reviewState = .drafting
            reviewInputsLocked = false
            externalProviderNoticeAccepted = false
            completeRawConsent = false
            includesRawEvidence = false
            reviewMessage = nil
        } catch {
            reviewState = .cleanupFailed
            reviewInputsLocked = true
            reviewMessage = "Temporary archive cleanup still needs attention. The room scan was not changed."
        }
    }

    func importLooseConcept() { fileImportRequest = .looseConcept }
    func importPackageConcept() { fileImportRequest = .conceptPackage }

    /// Called by the host after its file importer completes. The coordinator
    /// security-scopes, validates, sanitizes, and atomically persists input.
    func completeFileImport(url: URL, provider: String? = nil) {
        guard let request = fileImportRequest else { return }
        fileImportRequest = nil
        cancelActiveTask()
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                switch request {
                case .looseConcept:
                    _ = try await dependencies.concepts.importLoose(
                        from: url, request: brief, scope: coreScope,
                        provider: provider, context: conceptContext
                    )
                case .conceptPackage:
                    _ = try await dependencies.concepts.importPackage(
                        from: url, provider: provider,
                        requestOverride: brief.isEmpty ? nil : brief,
                        scopeOverride: coreScope, context: conceptContext
                    )
                case .replacementImage:
                    guard let target = replacementImageRequestID,
                          let register = dependencies.registerReplacement
                    else { throw RoomAIRoomPackageAppServiceError.stalePreparation }
                    let candidateID = try await register(target, url, sourceRevision)
                    replacementReferenceIDs.insert(candidateID)
                    excludedReferenceIDs.insert(target)
                    replacementImageRequestID = nil
                    invalidateReviewIfNeeded(message: "Replacement evidence was added locally. Refresh review before approval.")
                }
                try Task.checkCancellation()
                await reloadConcepts()
                reviewMessage = "Concept Set imported locally."
            } catch is CancellationError {
                return
            } catch {
                reviewMessage = actionableMessage(for: error)
            }
        }
    }

    func cancelFileImport() {
        fileImportRequest = nil
        replacementImageRequestID = nil
    }

    func applyManualMapping() {
        guard let selectedConceptID, !selectedCanonicalView.isEmpty else { return }
        let selectedCanonicalView = self.selectedCanonicalView
        updateConcept(selectedConceptID) { concept in
            var mappings = Dictionary(uniqueKeysWithValues: concept.attachments.map { ($0.attachmentID, $0.mapping) })
            mappings = mappings.mapValues { _ in .manual(cameraID: selectedCanonicalView) }
            return (mappings, concept.approvalState, concept.comments)
        }
    }

    func toggleConceptApproval(_ id: String) {
        updateConcept(id) { concept in
            let next: RoomConceptApprovalState = concept.approvalState == .approved ? .pending : .approved
            let mappings = Dictionary(uniqueKeysWithValues: concept.attachments.map { ($0.attachmentID, $0.mapping) })
            return (mappings, next, concept.comments)
        }
    }

    func archiveConcept(_ id: String) { changeArchive(id, archived: true) }
    func unarchiveConcept(_ id: String) { changeArchive(id, archived: false) }

    func deleteConcept(_ id: String) {
        cancelActiveTask()
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await dependencies.concepts.delete(id, context: conceptContext)
                try Task.checkCancellation()
                selectedConceptID = nil
                await reloadConcepts()
            } catch is CancellationError { return
            } catch { reviewMessage = actionableMessage(for: error) }
        }
    }

    /// Loads only the first sanitized attachment from the exact local Concept
    /// Set. A store/context mismatch is rejected rather than comparing a
    /// visually plausible Concept Set to another room revision.
    func compareConcept(_ id: String) {
        comparisonTask?.cancel()
        comparisonPresentation = nil
        let requestID = UUID()
        comparisonRequestID = requestID
        comparisonTask = Task { [weak self] in
            guard let self else { return }
            do {
                let concept = try await dependencies.concepts.load(id, context: conceptContext)
                guard concept.sourceRevision == sourceRevision,
                      let attachment = concept.attachments.first,
                      attachment.sanitizationProvenance == .appReencodedLooseFile || attachment.sanitizationProvenance == .appReencodedPackagedFile
                else { throw RoomConceptImportCoordinator.ImportError.unsafeInput }
                let conceptData = try await dependencies.concepts.attachmentData(
                    conceptSetID: concept.conceptSetID,
                    attachmentID: attachment.attachmentID,
                    context: conceptContext
                )
                let originalData: Data?
                if let originalProvider = dependencies.originalComparisonImageData {
                    originalData = try await originalProvider(sourceRevision)
                } else {
                    originalData = nil
                }
                try Task.checkCancellation()
                guard comparisonRequestID == requestID else { return }
                let item = makeConceptItem(concept)
                comparisonPresentation = .init(
                    conceptID: concept.conceptSetID,
                    conceptName: item.name,
                    sourceRevisionID: concept.sourceRevision.revisionID,
                    mappingDetail: item.mappingDetail,
                    conceptAttachmentData: conceptData,
                    originalPreviewData: originalData
                )
            } catch is CancellationError {
                return
            } catch {
                guard comparisonRequestID == requestID else { return }
                reviewMessage = "The Concept Set could not be loaded for comparison. It may no longer match this room revision."
            }
        }
    }

    func dismissComparison() {
        comparisonRequestID = nil
        comparisonTask?.cancel()
        comparisonTask = nil
        comparisonPresentation = nil
    }

    private struct ReviewInputSnapshot: Equatable {
        let profile: RoomAIRedesignProfile
        let brief: String
        let intent: String
        let featureChoices: [String: RoomAIChangeRequest]
        let excludedReferenceIDs: Set<String>
        let replacementReferenceIDs: Set<String>
    }

    private var currentReviewInputSnapshot: ReviewInputSnapshot {
        .init(
            profile: selectedProfile,
            brief: brief,
            intent: intent,
            featureChoices: featureChoices,
            excludedReferenceIDs: excludedReferenceIDs,
            replacementReferenceIDs: replacementReferenceIDs
        )
    }

    private func isCurrentPackageOperation(
        _ operationID: UUID,
        snapshot: ReviewInputSnapshot
    ) -> Bool {
        packageOperationID == operationID
            && currentReviewInputSnapshot == snapshot
    }

    private func finishPackageOperation(_ operationID: UUID) {
        guard packageOperationID == operationID else { return }
        packageOperationID = nil
        packageTask = nil
        reviewInputsLocked = reviewState == .cleanupFailed
    }

    /// Cleans only a factory/service-owned exact workspace. Missing paths are
    /// already-clean outcomes; a real failure retains that same URL for the
    /// existing actionable retry state.
    private func cleanupUnpublishedPackageLease(
        _ lease: URL?,
        operationID: UUID
    ) {
        guard let lease else { return }
        do {
            if FileManager.default.fileExists(atPath: lease.path) {
                try dependencies.packageService.cleanupLease(lease)
            }
            if preparedDraft?.workspaceURL == lease { preparedDraft = nil }
            if cleanupLeaseURL == lease { cleanupLeaseURL = nil }
            if finalizedArchive?.archiveURL.deletingLastPathComponent() == lease {
                finalizedArchive = nil
                shareArchiveURL = nil
                sharePresentationRequest = nil
            }
        } catch {
            guard packageOperationID == operationID else { return }
            cleanupLeaseURL = lease
            preparedDraft = nil
            finalizedArchive = nil
            shareArchiveURL = nil
            sharePresentationRequest = nil
            reviewState = .cleanupFailed
            reviewInputsLocked = true
            reviewMessage = "Temporary archive cleanup needs another attempt. The room scan was not changed."
        }
    }

    private var coreProfile: RoomAIRoomPackageProfile { selectedProfile == .aiReady ? .aiReady : .complete }
    private var coreScope: RoomRedesignScope {
        Self.coreScope(for: intent)
    }

    private static func coreScope(for intent: String) -> RoomRedesignScope {
        switch intent.lowercased() {
        case "renovate": .renovate
        case "reimagine": .reimagine
        default: .stage
        }
    }

    private func refreshReadiness() {
        readiness = [
            .init(id: "source", title: "Sealed source revision", detail: sourceRevision.revisionID, isReady: true),
            .init(id: "brief", title: "Redesign brief", detail: brief.isEmpty ? "Add a local request before review." : "Bound to this revision at preparation.", isReady: !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
            .init(id: "cameras", title: "Canonical camera set", detail: canonicalViewChoices.isEmpty ? "No confirmed canonical views are available." : "\(canonicalViewChoices.count) confirmed local view(s).", isReady: !canonicalViewChoices.isEmpty)
        ]
    }

    private func invalidateReviewIfNeeded(message: String = "Package inputs changed. Refresh review before approval.") {
        refreshReadiness()
        let operationOwnsLease = packageOperationID != nil
        guard operationOwnsLease
                || preparedDraft != nil
                || reviewState == .readyForReview
                || reviewState == .approved
                || reviewState == .archiveReady
        else { return }
        if sharePresentationRequest != nil {
            dependencies.disclosure.reject()
            reviewState = .stale
            reviewMessage = "Package inputs changed while the system Share Sheet was open. That exact reviewed archive will be cleaned when the sheet closes."
            return
        }
        let abandonedDraft = preparedDraft
        if operationOwnsLease {
            packageTask?.cancel()
        }
        preparedDraft = nil
        if !operationOwnsLease {
            cleanupLeaseURL = abandonedDraft?.workspaceURL
        }
        dependencies.disclosure.reject()
        reviewState = .stale
        externalProviderNoticeAccepted = false
        completeRawConsent = false
        includesRawEvidence = false
        reviewMessage = message
        shareArchiveURL = nil
        sharePresentationRequest = nil
        finalizedArchive = nil
        guard !operationOwnsLease else { return }
        // A stale review must not leave an unshared archive or frozen evidence
        // lease behind. This cleanup is scoped to the exact factory-owned URL.
        if let abandonedDraft {
            Task { [weak self] in
                do {
                    guard let self else { return }
                    try self.dependencies.packageService.cleanupLease(abandonedDraft.workspaceURL)
                    guard self.cleanupLeaseURL == abandonedDraft.workspaceURL else { return }
                    self.cleanupLeaseURL = nil
                } catch {
                    guard let self, self.cleanupLeaseURL == abandonedDraft.workspaceURL else { return }
                    self.reviewState = .cleanupFailed
                    self.reviewMessage = "Temporary archive cleanup needs another attempt. The room scan was not changed."
                }
            }
        }
    }

    private func apply(draft: RoomAIRoomPackagePreparedDraft) {
        images = draft.disclosureDraft.selectedImages.map {
            .init(
                id: $0.imageID,
                title: $0.displayName,
                metadata: "\($0.mediaType) · \($0.byteCount) bytes",
                advisory: $0.advisories.first?.message,
                previewData: draft.selectedImagePreviewData[$0.imageID],
                isIncluded: true,
                allowsSelectionChanges: !$0.isRawEvidence
            )
        }
        inventory = draft.disclosureDraft.artifactInventory.map {
            .init(id: $0.artifactID, title: String(describing: $0.artifactClass), detail: String(describing: $0.disposition), included: $0.disposition == .included, reason: $0.reasonCode ?? "included")
        }
        qualityAdvisories = draft.disclosureDraft.qualityWarnings
        estimatedSize = ByteCountFormatter.string(
            fromByteCount: Int64(draft.disclosureDraft.estimatedPackageByteCount),
            countStyle: .file
        )
        externalProviderNoticeAccepted = false
        completeRawConsent = false
        includesRawEvidence = draft.disclosureDraft.includesRawEvidence
    }

    private func reloadConcepts() async {
        do {
            let values = try await dependencies.concepts.list(context: conceptContext)
            concepts = values.map(makeConceptItem).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch is CancellationError { return
        } catch { reviewMessage = actionableMessage(for: error) }
    }

    private func makeConceptItem(_ concept: RoomConceptSet) -> RoomAIConceptItem {
        let mapping = concept.attachments.first?.mapping ?? .unmatched
        let displayMapping: RoomAIConceptMapping
        let detail: String
        switch mapping.status {
        case .automatic:
            displayMapping = .automatic
            detail = "Matched to canonical view \(mapping.cameraID ?? "unknown")."
        case .manual:
            displayMapping = .manual
            detail = "Manually mapped to canonical view \(mapping.cameraID ?? "unknown")."
        case .unmatched:
            displayMapping = .unmatched
            detail = "Choose a confirmed local canonical view to map this reference."
        }
        return .init(
            id: concept.conceptSetID,
            name: concept.importProvenance.sourceFilename,
            provenance: concept.importProvenance.kind.rawValue,
            sourceRevision: concept.sourceRevision.revisionID,
            providerDisclosure: concept.provider.map { "External provider named at local import: \($0)" },
            mapping: displayMapping, mappingDetail: detail,
            approved: concept.approvalState == .approved,
            archived: concept.archiveState == .archived
        )
    }

    private func updateConcept(
        _ id: String,
        change: @escaping (RoomConceptSet) -> ([String: RoomConceptAttachmentMapping], RoomConceptApprovalState, [String])
    ) {
        cancelActiveTask()
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let existing = try await dependencies.concepts.load(id, context: conceptContext)
                let update = change(existing)
                _ = try await dependencies.concepts.updateReview(
                    conceptSetID: id, attachmentMappings: update.0,
                    approvalState: update.1, comments: update.2,
                    context: conceptContext
                )
                try Task.checkCancellation()
                await reloadConcepts()
            } catch is CancellationError { return
            } catch { reviewMessage = actionableMessage(for: error) }
        }
    }

    private func changeArchive(_ id: String, archived: Bool) {
        cancelActiveTask()
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                if archived {
                    _ = try await dependencies.concepts.archive(id, context: conceptContext)
                } else {
                    _ = try await dependencies.concepts.unarchive(id, context: conceptContext)
                }
                try Task.checkCancellation()
                await reloadConcepts()
            } catch is CancellationError { return
            } catch { reviewMessage = actionableMessage(for: error) }
        }
    }

    private func cancelActiveTask() {
        activeTask?.cancel()
        activeTask = nil
    }

    private func actionableMessage(for error: Error) -> String {
        if error is CancellationError { return "The local operation was cancelled. You can try again." }
        if let localized = error as? LocalizedError, let description = localized.errorDescription { return description }
        if error is RoomAIRoomPackageAppServiceError { return "This room package no longer matches the sealed source or required evidence. Refresh and try again." }
        if error is RoomAIDisclosureError { return "Disclosure review is no longer current. Refresh review before approving." }
        return "The local operation could not finish. The room scan was not changed; try again."
    }
}
