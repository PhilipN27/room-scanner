import Combine
import Foundation
import RoomScanCore

enum RoomPublicationReviewMode: String, CaseIterable, Identifiable, Sendable {
    case room
    case property

    var id: String { rawValue }
    var title: String { self == .room ? "Room portal" : "Property portal" }
}

/// Link policy is separate from the immutable portal document. It contains no
/// bearer link and no PIN bytes; a PIN is kept only ephemerally by the review
/// model until the configured TLS transport receives its one-time candidate.
struct RoomPublicationLinkControls: Equatable, Sendable {
    static let defaultLifetime: TimeInterval = 30 * 24 * 60 * 60
    static let minimumLifetime: TimeInterval = 60 * 60
    static let maximumLifetime: TimeInterval = 365 * 24 * 60 * 60

    /// `nil` deliberately omits expiry from the native request so the server
    /// applies its controlled-clock 30-day default. It is not a locally
    /// calculated timestamp retained as if it were authoritative.
    var expiresAt: Date?
    var requiresPIN: Bool
    var allowsAIReadyPackageDownload: Bool
    var allowsFeedback: Bool

    static func `default`(now: Date = Date()) -> RoomPublicationLinkControls {
        .init(
            expiresAt: nil,
            requiresPIN: false,
            allowsAIReadyPackageDownload: false,
            allowsFeedback: false
        )
    }

    mutating func setExpiration(_ proposed: Date?, now: Date = Date()) {
        expiresAt = proposed.map { Self.boundedExpiration($0, now: now) }
    }

    static func boundedExpiration(_ proposed: Date, now: Date = Date()) -> Date {
        let minimum = now.addingTimeInterval(minimumLifetime)
        let maximum = now.addingTimeInterval(maximumLifetime)
        return min(max(proposed, minimum), maximum)
    }
}

struct RoomPublicationBrandingDraft: Equatable, Sendable {
    var businessName: String
    var phone: String
    var website: String
    var accent: RoomPublishedSemanticAccent
    var logo: RoomPublicationLogoDraft?

    static let `default` = RoomPublicationBrandingDraft(
        businessName: "",
        phone: "",
        website: "",
        accent: .blueprint,
        logo: nil
    )

    var isOwnerComplete: Bool {
        !businessName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !website.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

/// A configured professional business-profile provider may supply one owner
/// selected raster. The raw value is fed through the publication-only fresh
/// encoder before it becomes a typed branding logo asset; no arbitrary logo
/// URL or HTML is accepted.
struct RoomPublicationLogoDraft: Equatable, Sendable {
    let data: Data
    let declaredFilename: String
}

struct RoomPublicationStaticDownloadControls: Equatable, Sendable {
    var allowsFloorPlanPDF: Bool
    var allowsGalleryZIP: Bool

    static let none = RoomPublicationStaticDownloadControls(
        allowsFloorPlanPDF: false,
        allowsGalleryZIP: false
    )
}

struct RoomPublicationReviewOptions: Equatable, Sendable {
    var mode: RoomPublicationReviewMode
    var title: String
    var branding: RoomPublicationBrandingDraft
    var selectedConceptIDs: Set<String>
    /// Only stable public asset IDs are represented here. The production input
    /// factory maps them to newly constructed allowlist candidates; private
    /// attachment/project identifiers never become selection controls.
    var excludedRasterAssetIDs: Set<String>
    /// A fresh public room key identifies the one exact locally validated
    /// AI-ready package to include. It is not a package ID or local file URL.
    var selectedAIReadyPackageRoomKey: String?
    var staticDownloads: RoomPublicationStaticDownloadControls
    var linkControls: RoomPublicationLinkControls
    var disclosureConfirmed: Bool

    static func `default`(now: Date = Date()) -> RoomPublicationReviewOptions {
        .init(
            mode: .room,
            // The actual room/property title is supplied by the typed local
            // input factory unless the owner deliberately enters an override.
            // Never mask a real presentation title with a generic default.
            title: "",
            branding: .default,
            selectedConceptIDs: [],
            excludedRasterAssetIDs: [],
            selectedAIReadyPackageRoomKey: nil,
            staticDownloads: .none,
            linkControls: .default(now: now),
            disclosureConfirmed: false
        )
    }
}

struct RoomPublicationConceptChoice: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
}

/// A safe selection label for a locally retained, already-finalized AI-ready
/// package. It carries only the fresh portal room key and display label; the
/// package identifier and private archive location never leave the provider.
struct RoomPublicationAIReadyPackageChoice: Identifiable, Equatable, Sendable {
    let publicRoomKey: String
    let label: String

    var id: String { publicRoomKey }
}

/// Safe pixel-preview candidate retained independently from the selected Core
/// closure. It carries only fresh publication-sanitized pixels and a public
/// asset ID; it cannot name a private attachment, project, or package.
struct RoomPublicationRasterChoice: Identifiable, Equatable, Sendable {
    let assetID: String
    let publicRoomKey: String?
    let assetClass: RoomPublishedAssetClass
    let raster: RoomPublishedRaster

    var id: String { assetID }
}

/// Native review combines a safe pixel preview with the Core ledger fact for
/// an included asset. Core fresh-reencodes rasters, so `data` is explicitly a
/// visual candidate preview, while `sealedSHA256`/`sealedByteCount` describe
/// the final archive bytes bound into the selection manifest.
struct RoomPublicationReviewedRaster: Identifiable, Equatable {
    let assetID: String
    let publicRoomKey: String?
    let assetClass: RoomPublishedAssetClass
    let mediaType: RoomPublishedRasterMediaType
    let data: Data
    let sealedSHA256: String?
    let sealedByteCount: UInt64?

    var id: String { assetID }
    var displayLabel: String {
        switch assetClass {
        case .floorPlan: "Floor plan"
        case .selectedImage: "Selected original"
        case .approvedConcept: "Approved concept"
        case .brandingLogo: "Business logo"
        case .webTexture: "Web texture"
        case .webGeometry, .aiReadyPackage: "Portal asset"
        }
    }
    var canBeExcluded: Bool { assetClass == .selectedImage }
    var isIncluded: Bool { sealedSHA256 != nil }
}

/// Typed public-only input to the Core allowlist builder. It deliberately has
/// no `RoomProjectPackage`, source URL, revision history, local notes, GPS, or
/// generic dictionary field.
struct RoomPublicationReviewInput: Sendable, Equatable {
    /// Local-only journal routing. This value is never emitted into Core's
    /// public presentation, the archive control manifest, or a hosted DTO.
    let journalAnchorProjectID: String
    let draft: RoomPublishedSnapshotDraft
    let sourceBindings: [RoomPublishedSourceBinding]
    /// Exact app-journal-resolved public identities for the corresponding
    /// Core bindings. They are ordered and direct; property portals do not
    /// compose prior child snapshot IDs.
    let hostedSourceBindings: [RoomPublicationHostedSourceBinding]
    let propertyCuration: RoomPublicationPropertyCuration?
    let assets: [RoomPublishedAssetInput]
    let rasterChoices: [RoomPublicationRasterChoice]
    let conceptChoices: [RoomPublicationConceptChoice]
    let aiReadyPackageChoices: [RoomPublicationAIReadyPackageChoice]
    let qualityWarnings: [RoomPublishedQualityWarning]
}

/// A private native bridge for server-owned property curation. Its local ID is
/// journal-only; the transport receives only public room keys and `prj_` IDs.
struct RoomPublicationPropertyCuration: Sendable, Equatable {
    let localPropertyID: String
    let title: String
    let rooms: [RoomPublicationPropertyRoom]
}

/// A local proof that the exact Core preparation includes one validated
/// AI-ready package asset selected by its immutable download policy. The
/// asset ID never crosses the link route: the service independently verifies
/// the published snapshot before it enables an AI download entitlement.
struct RoomPublicationAIReadyLinkEntitlement: Sendable, Equatable {
    let assetID: String

    init?(preparation: RoomPublishedSnapshotPreparation) {
        guard let assetID = preparation.draft.downloads.aiReadyPackageAssetID,
              preparation.preparedAssets.contains(where: {
                  $0.ledger.assetID == assetID
                      && $0.ledger.assetClass == .aiReadyPackage
                      && $0.ledger.aiReadyPackageBinding != nil
              })
        else { return nil }
        self.assetID = assetID
    }
}

enum RoomPublicationReviewState: Equatable {
    case drafting
    case preparing
    case readyForApproval
    case approvalInvalidated
    case publishing
    case allocationPending
    case linkPending
    case rejected(String?)
    case published
    case revoked
    case failed(String)
}

enum RoomPublicationReviewError: LocalizedError, Equatable {
    case disclosureRequired
    case missingPreparedReview
    case approvalRequired
    case staleReview
    case pinRequired
    case invalidPIN
    case revocationUnavailable
    case publicationInProgress
    case revocationInProgress

    var errorDescription: String? {
        switch self {
        case .disclosureRequired:
            "Confirm the publication disclosure before approving this snapshot."
        case .missingPreparedReview:
            "Prepare the current room revision and selected derivatives before approving."
        case .approvalRequired:
            "Approve this exact prepared snapshot before publishing."
        case .staleReview:
            "The room revision or selected public derivatives changed. Review and approve the current snapshot again."
        case .pinRequired:
            "Enter an exact 6 digit PIN before publishing this protected link."
        case .invalidPIN:
            "A publication PIN must contain exactly 6 ASCII digits."
        case .revocationUnavailable:
            "There is no active published snapshot to revoke."
        case .publicationInProgress:
            "This portal publication is already in progress."
        case .revocationInProgress:
            "This portal-link revocation is already in progress."
        }
    }
}

/// Native review state has no project-editing or feedback mutation method.
/// Feedback is rendered only as the immutable/audited remote summary returned
/// by the publication transport.
@MainActor
final class RoomPublicationReviewModel: ObservableObject {
    typealias InputProvider = @MainActor (RoomPublicationReviewOptions) async throws -> RoomPublicationReviewInput
    typealias SensitiveActionConfirmation = @MainActor () async -> Bool

    @Published private(set) var reviewState: RoomPublicationReviewState = .drafting
    @Published private(set) var preparation: RoomPublishedSnapshotPreparation?
    @Published private(set) var approval: RoomPublishedPublicationApproval?
    @Published private(set) var remoteStatus: RoomPublicationRemoteAllocationStatus?
    @Published private(set) var portalLinkStatus: RoomPublicationPortalLinkStatus?
    @Published private(set) var pendingPortalLink: RoomPublicationPendingPortalLink?
    @Published private(set) var feedbackSummary: RoomPublicationFeedbackSummary = .empty
    @Published private(set) var errorMessage: String?
    @Published var options: RoomPublicationReviewOptions
    @Published private(set) var input: RoomPublicationReviewInput?

    /// PIN stays in memory only for the one configured publish operation. It
    /// is neither encoded into the snapshot nor placed in the archive. It
    /// crosses the configured TLS transport only as an ephemeral candidate so
    /// the service can derive its bounded-scrypt verifier.
    private var ephemeralPIN = ""
    private let inputProvider: InputProvider
    private let service: any RoomPublicationServicing
    private let confirmSensitiveAction: SensitiveActionConfirmation
    private let now: () -> Date
    private let reviewID: () -> String
    private var isPublishing = false
    private var isRevokingPortalLink = false

    init(
        options: RoomPublicationReviewOptions = .default(),
        inputProvider: @escaping InputProvider,
        service: any RoomPublicationServicing,
        confirmSensitiveAction: @escaping SensitiveActionConfirmation,
        now: @escaping () -> Date = Date.init,
        reviewID: @escaping () -> String = { "publication-review-\(UUID().uuidString.lowercased())" }
    ) {
        self.options = options
        self.inputProvider = inputProvider
        self.service = service
        self.confirmSensitiveAction = confirmSensitiveAction
        self.now = now
        self.reviewID = reviewID
    }

    var sourceBindingsDigest: String? { preparation?.sourceBindingsSHA256 }
    var selectionManifestDigest: String? { preparation?.selectionManifestSHA256 }
    var selectedSourceRevisions: [RoomPublicationReviewedSource] {
        guard let preparation else { return [] }
        let labels = Dictionary(
            uniqueKeysWithValues: input?.draft.publicRooms().map {
                ($0.roomKey, $0.displayName)
            } ?? []
        )
        return preparation.sourceBindings.map {
            .init(
                roomKey: $0.publicRoomKey,
                roomLabel: labels[$0.publicRoomKey] ?? "Selected room",
                revisionID: $0.sourceRevision.revisionID
            )
        }
    }
    var reviewedRasters: [RoomPublicationReviewedRaster] {
        let ledgerByID = Dictionary(
            uniqueKeysWithValues: preparation?.preparedAssets.map {
                ($0.ledger.assetID, $0.ledger)
            } ?? []
        )
        return input?.rasterChoices.map { choice in
            let ledger = ledgerByID[choice.assetID]
            return .init(
                assetID: choice.assetID,
                publicRoomKey: choice.publicRoomKey,
                assetClass: choice.assetClass,
                mediaType: choice.raster.mediaType,
                data: choice.raster.data,
                sealedSHA256: ledger?.sha256,
                sealedByteCount: ledger?.byteCount
            )
        } ?? []
    }
    var minimumLinkExpiry: Date {
        now().addingTimeInterval(RoomPublicationLinkControls.minimumLifetime)
    }
    var maximumLinkExpiry: Date {
        now().addingTimeInterval(RoomPublicationLinkControls.maximumLifetime)
    }
    /// The injected model clock keeps DatePicker bounds deterministic for
    /// fixtures and controlled-clock unit tests.
    var clockNow: Date { now() }
    var isBrandingComplete: Bool { options.branding.isOwnerComplete }
    /// The toggle remains unavailable unless the currently prepared, exact
    /// immutable closure contains a Core-validated AI-ready package. This is
    /// intentionally separate from the per-link hosted policy.
    var hasValidatedAIReadyPackage: Bool {
        guard let preparation else { return false }
        return RoomPublicationAIReadyLinkEntitlement(preparation: preparation) != nil
    }
    var preparedPresentationTitle: String? {
        guard let draft = input?.draft else { return nil }
        return switch draft {
        case let .room(value): value.title
        case let .property(value): value.propertyTitle
        }
    }
    var independentRoomNotice: String? {
        guard options.mode == .property else { return nil }
        if case let .property(presentation)? = input?.draft {
            return presentation.independentRoomNotice
        }
        return RoomPublishedPropertyPresentationV1.independentRoomNotice
    }

    func prepareReview() async throws {
        reviewState = .preparing
        errorMessage = nil
        do {
            let current = try await inputProvider(options)
            let prepared = try await service.prepare(current)
            input = current
            preparation = prepared
            let recovered = try await service.recoverOperation(
                input: current,
                preparation: prepared
            )
            if let recovered {
                approval = recovered.approval
                remoteStatus = recovered.remoteStatus
                portalLinkStatus = recovered.portalLinkStatus
                feedbackSummary = recovered.portalLinkStatus?.feedbackSummary ?? .empty
                pendingPortalLink = recovered.remoteStatus?.snapshotID.map {
                    .init(
                        snapshotID: $0,
                        sourceBindingsSHA256: prepared.sourceBindingsSHA256,
                        selectionManifestSHA256: prepared.selectionManifestSHA256
                    )
                }
                reviewState = Self.reviewState(for: recovered)
            } else {
                approval = nil
                remoteStatus = nil
                portalLinkStatus = nil
                pendingPortalLink = nil
                feedbackSummary = .empty
                reviewState = .readyForApproval
            }
        } catch {
            reviewState = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func approveReview() throws {
        guard options.disclosureConfirmed else {
            throw RoomPublicationReviewError.disclosureRequired
        }
        guard let preparation else {
            throw RoomPublicationReviewError.missingPreparedReview
        }
        approval = preparation.makeApproval(reviewID: reviewID(), reviewedAt: now())
        reviewState = .readyForApproval
        errorMessage = nil
    }

    func setMode(_ mode: RoomPublicationReviewMode) {
        guard options.mode != mode else { return }
        options.mode = mode
        invalidateApproval()
    }

    func updateTitle(_ title: String) {
        guard options.title != title else { return }
        options.title = title
        invalidateApproval()
    }

    func setSelectedConceptIDs(_ ids: Set<String>) {
        guard options.selectedConceptIDs != ids else { return }
        options.selectedConceptIDs = ids
        invalidateApproval()
    }

    func setSelectedAIReadyPackageRoomKey(_ publicRoomKey: String?) {
        let allowed = Set(input?.aiReadyPackageChoices.map(\.publicRoomKey) ?? [])
        let normalized = publicRoomKey.flatMap { allowed.contains($0) ? $0 : nil }
        guard options.selectedAIReadyPackageRoomKey != normalized else { return }
        options.selectedAIReadyPackageRoomKey = normalized
        // The archive asset and immutable download policy are rebuilt from
        // scratch on the next review; a link cannot opt into a stale closure.
        invalidateApproval()
    }

    func setRasterIncluded(_ assetID: String, included: Bool) {
        guard let raster = reviewedRasters.first(where: { $0.assetID == assetID }),
              raster.canBeExcluded
        else { return }
        var excluded = options.excludedRasterAssetIDs
        if included {
            excluded.remove(assetID)
        } else {
            excluded.insert(assetID)
        }
        guard excluded != options.excludedRasterAssetIDs else { return }
        options.excludedRasterAssetIDs = excluded
        invalidateApproval()
    }

    func isRasterIncluded(_ assetID: String) -> Bool {
        !options.excludedRasterAssetIDs.contains(assetID)
    }

    func setDisclosureConfirmed(_ confirmed: Bool) {
        guard options.disclosureConfirmed != confirmed else { return }
        options.disclosureConfirmed = confirmed
        if !confirmed { invalidateApproval() }
    }

    func updateBranding(_ branding: RoomPublicationBrandingDraft) {
        guard options.branding != branding else { return }
        options.branding = branding
        invalidateApproval()
    }

    func updateLinkControls(_ controls: RoomPublicationLinkControls) {
        var bounded = controls
        bounded.setExpiration(bounded.expiresAt, now: now())
        // A link may opt in only after Core has prepared and sealed an exact
        // AI-ready package into this snapshot closure. When none is present,
        // the native control remains off rather than advertising a no-op.
        bounded.allowsAIReadyPackageDownload =
            bounded.allowsAIReadyPackageDownload && hasValidatedAIReadyPackage
        // Turning the PIN policy off is a security boundary, not merely a UI
        // preference. Do not leave a hidden valid candidate available for a
        // later re-enabled publish action.
        if !bounded.requiresPIN { clearPIN() }
        guard options.linkControls != bounded else { return }
        options.linkControls = bounded
        // Link policy is a separate hosted authorization fact, but requiring
        // a fresh local review for every policy change is the safer native UX.
        invalidateApproval()
    }

    func setLinkExpiry(_ proposed: Date) {
        var controls = options.linkControls
        controls.setExpiration(proposed, now: now())
        updateLinkControls(controls)
    }

    func updateStaticDownloads(_ downloads: RoomPublicationStaticDownloadControls) {
        guard options.staticDownloads != downloads else { return }
        options.staticDownloads = downloads
        invalidateApproval()
    }

    func setPIN(_ value: String) throws {
        guard value.isEmpty || Self.isValidPIN(value) else {
            ephemeralPIN = ""
            throw RoomPublicationReviewError.invalidPIN
        }
        ephemeralPIN = value
    }

    /// Retains no partial PIN candidate. The view uses this while a user is
    /// typing one through five digits, so incomplete local entry stays quiet
    /// while a formerly complete candidate cannot remain hidden in memory.
    func clearPIN() {
        ephemeralPIN = ""
    }

    /// The sheet can be dismissed while a six-digit field is still visually
    /// hidden by another control. Clearing at this lifecycle boundary keeps
    /// the PIN strictly in-memory and scoped to the visible review attempt.
    func dismissReview() {
        clearPIN()
    }

    func present(_ error: Error) {
        errorMessage = error.localizedDescription
        reviewState = .failed(error.localizedDescription)
    }

    func publish() async throws {
        guard !isPublishing else { throw RoomPublicationReviewError.publicationInProgress }
        isPublishing = true
        // A publish attempt never retains a PIN after it returns, regardless
        // of sensitive-auth cancellation, transport error, or success.
        defer {
            isPublishing = false
            ephemeralPIN = ""
        }
        guard let preparation, let approval else {
            throw RoomPublicationReviewError.approvalRequired
        }

        // Sensitive confirmation precedes the final source/selection rebuild.
        // Re-entry then observes the newest facts immediately before hosted
        // allocation, rather than authenticating an old locally cached review.
        guard await confirmSensitiveAction() else {
            return
        }

        let linkControls = options.linkControls
        let pinCandidate = ephemeralPIN
        guard !linkControls.requiresPIN || Self.isValidPIN(pinCandidate) else {
            throw RoomPublicationReviewError.pinRequired
        }
        let currentInput = try await inputProvider(options)
        let currentPreparation = try await service.prepare(currentInput)
        guard self.approval == approval,
              currentPreparation.sourceBindingsSHA256 == preparation.sourceBindingsSHA256,
              currentPreparation.selectionManifestSHA256 == preparation.selectionManifestSHA256
        else {
            self.input = currentInput
            self.preparation = currentPreparation
            invalidateApproval()
            throw RoomPublicationReviewError.staleReview
        }

        reviewState = .publishing
        errorMessage = nil
        do {
            let snapshotID: String
            if let pendingPortalLink, pendingPortalLink.matches(currentPreparation) {
                // A link failure occurs only after a published immutable
                // allocation. Retrying stays on that exact `snp_` and never
                // turns a pua reconciliation into a second allocation.
                snapshotID = pendingPortalLink.snapshotID
            } else {
                pendingPortalLink = nil
                let allocation = try await service.publishSnapshot(
                    input: currentInput,
                    preparation: currentPreparation,
                    approval: approval,
                    operationID: "publication-\(approval.reviewID)"
                )
                remoteStatus = allocation
                switch allocation.state {
                case .allocated, .validationPending, .validating:
                    reviewState = .allocationPending
                    return
                case .rejected:
                    reviewState = .rejected(allocation.rejectionCode)
                    errorMessage = RoomPublicationServiceError.rejectedAllocation(allocation.rejectionCode).localizedDescription
                    return
                case .published:
                    guard let publishedID = allocation.snapshotID else {
                        throw RoomPublicationServiceError.invalidPublishedAllocation
                    }
                    snapshotID = publishedID
                }
                pendingPortalLink = .init(
                    snapshotID: snapshotID,
                    sourceBindingsSHA256: currentPreparation.sourceBindingsSHA256,
                    selectionManifestSHA256: currentPreparation.selectionManifestSHA256
                )
            }
            let link = try await service.createPortalLink(
                snapshotID: snapshotID,
                linkControls: linkControls,
                aiReadyEntitlement: RoomPublicationAIReadyLinkEntitlement(
                    preparation: currentPreparation
                ),
                pin: linkControls.requiresPIN ? pinCandidate : nil,
                operationID: "publication-\(approval.reviewID)"
            )
            portalLinkStatus = link
            pendingPortalLink = nil
            feedbackSummary = link.feedbackSummary
            reviewState = link.lifecycle == .revoked ? .revoked : .published
        } catch {
            reviewState = pendingPortalLink == nil ? .failed(error.localizedDescription) : .linkPending
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func revokePortalLink() async throws {
        guard !isRevokingPortalLink else {
            throw RoomPublicationReviewError.revocationInProgress
        }
        guard let link = portalLinkStatus else {
            throw RoomPublicationReviewError.revocationUnavailable
        }
        isRevokingPortalLink = true
        defer { isRevokingPortalLink = false }
        guard await confirmSensitiveAction() else { return }
        guard let approval else {
            throw RoomPublicationReviewError.revocationUnavailable
        }
        let revocation = try await service.revoke(
            linkID: link.linkID,
            expectedGeneration: link.generation,
            operationID: "publication-\(approval.reviewID)"
        )
        portalLinkStatus = .init(
            linkID: revocation.linkID,
            generation: revocation.generation,
            lifecycle: .revoked,
            expiresAt: link.expiresAt,
            pinRequired: link.pinRequired,
            aiEnabled: link.aiEnabled,
            feedbackEnabled: link.feedbackEnabled,
            feedbackSummary: feedbackSummary
        )
        reviewState = .revoked
    }

    private func invalidateApproval() {
        clearPIN()
        approval = nil
        if preparation != nil {
            reviewState = .approvalInvalidated
        } else {
            reviewState = .drafting
        }
    }

    private static func isValidPIN(_ value: String) -> Bool {
        value.count == 6 && value.allSatisfy { ("0"..."9").contains($0) }
    }

    private static func reviewState(
        for recovered: RoomPublicationOperationRecovery
    ) -> RoomPublicationReviewState {
        switch recovered.phase {
        case .prepared, .propertyPending, .allocated, .uploadedOrAmbiguous, .validating:
            return .allocationPending
        case .published, .linkPending:
            return .linkPending
        case .linked:
            return .published
        case .revocationPending:
            return .published
        case .revoked:
            return .revoked
        case .rejected:
            return .rejected(recovered.remoteStatus?.rejectionCode)
        }
    }
}

struct RoomPublicationReviewedSource: Identifiable, Equatable {
    let roomKey: String
    let roomLabel: String
    let revisionID: String

    var id: String { roomKey }
}

/// State needed to resume only the separate link phase. It contains no bearer
/// URL, PIN, archive path, feedback body, or private project identifier.
struct RoomPublicationPendingPortalLink: Equatable {
    let snapshotID: String
    let sourceBindingsSHA256: String
    let selectionManifestSHA256: String

    func matches(_ preparation: RoomPublishedSnapshotPreparation) -> Bool {
        sourceBindingsSHA256 == preparation.sourceBindingsSHA256
            && selectionManifestSHA256 == preparation.selectionManifestSHA256
    }
}

#if DEBUG
extension RoomPublicationReviewModel {
    /// Test-only probe for the non-persistence guarantee. It intentionally
    /// exposes only presence, never the PIN value.
    var debugRetainsEphemeralPIN: Bool { !ephemeralPIN.isEmpty }
}
#endif

#if DEBUG
extension RoomPublicationReviewModel {
    static func fixture(
        mode: RoomPublicationReviewMode = .room,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> RoomPublicationReviewModel {
        var options = RoomPublicationReviewOptions.default(
            now: Date(timeIntervalSince1970: 1_786_896_000)
        )
        options.mode = mode
        options.title = mode == .property ? "Harbor property presentation" : "North room presentation"
        options.branding = .init(
            businessName: "Harbor Design Studio",
            phone: "+1 555 0100",
            website: "https://example.invalid",
            accent: .blueprint,
            logo: nil
        )
        options.disclosureConfirmed = arguments.contains("--slice6-publication-ui-pending") == false
        options.linkControls.allowsFeedback = true
        options.staticDownloads = .init(
            allowsFloorPlanPDF: true,
            allowsGalleryZIP: true
        )
        let fixtureTransport = RoomPublicationFixtureTransport(
            initiallyRevoked: arguments.contains("--slice6-publication-ui-revoked")
        )
        let model = RoomPublicationReviewModel(
            options: options,
            inputProvider: { currentOptions in
                try RoomPublicationFixtureFactory.makeInput(
                    options: currentOptions,
                    includeWarning: arguments.contains("--slice6-publication-ui-warning")
                )
            },
            service: RoomPublicationService.fixture(transport: fixtureTransport),
            confirmSensitiveAction: { true },
            now: { Date(timeIntervalSince1970: 1_786_896_100) },
            reviewID: { "fixture-publication-review" }
        )
        if arguments.contains("--slice6-publication-ui-link-pending") {
            model.remoteStatus = fixturePublishedAllocation()
            model.pendingPortalLink = .init(
                snapshotID: "snp_fixturepublication0001",
                sourceBindingsSHA256: String(repeating: "a", count: 64),
                selectionManifestSHA256: String(repeating: "b", count: 64)
            )
            model.reviewState = .linkPending
        } else if arguments.contains("--slice6-publication-ui-revoked") {
            model.remoteStatus = fixturePublishedAllocation()
            model.portalLinkStatus = .init(
                linkID: "lnk_fixtureportal0001",
                generation: 2,
                lifecycle: .revoked,
                expiresAt: options.linkControls.expiresAt ?? Date(timeIntervalSince1970: 1_789_488_000),
                pinRequired: false,
                feedbackSummary: .init(
                    recordCount: 1,
                    latestActionLabel: "Approve",
                    latestRecordedAt: Date(timeIntervalSince1970: 1_786_896_200)
                )
            )
            model.feedbackSummary = model.portalLinkStatus?.feedbackSummary ?? .empty
            model.reviewState = .revoked
        } else if arguments.contains("--slice6-publication-ui-failure") {
            model.reviewState = .failed("The configured publication service is unavailable. Local work remains intact.")
            model.errorMessage = "The configured publication service is unavailable. Local work remains intact."
        }
        return model
    }

    private static func fixturePublishedAllocation() -> RoomPublicationRemoteAllocationStatus {
        .init(
            allocationID: "pua_fixtureallocation0001",
            state: .published,
            kind: .room,
            projectID: "prj_0000000000000001",
            sourceRevisionID: "rev_0000000000000001",
            propertyID: nil,
            snapshotID: "snp_fixturepublication0001",
            rejectionCode: nil,
            createdAt: Date(timeIntervalSince1970: 1_786_896_000),
            updatedAt: Date(timeIntervalSince1970: 1_786_896_100),
            expiresAt: Date(timeIntervalSince1970: 1_786_899_600)
        )
    }
}
#endif
