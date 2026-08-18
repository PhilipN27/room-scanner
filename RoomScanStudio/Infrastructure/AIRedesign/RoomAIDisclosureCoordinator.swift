import Combine
import Foundation
import RoomScanCore

enum RoomAIDisclosureState: Sendable, Equatable {
    case idle
    case reviewing
    case approved
    case rejected
    case stale
    case consumed
}

enum RoomAIDisclosureError: Error, Sendable, Equatable {
    case invalidState
    case invalidDraft(String)
    case externalProviderNoticeRequired
    case rawEvidenceConsentRequired
    case unexpectedRawEvidenceConsent
    case aiReadyCannotIncludeRawEvidence
    case preciseGPSMustBeExcluded
    case staleReview
    case replayedReview
}

extension RoomAIDisclosureError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidState:
            return "Start a fresh disclosure review before approving this package."
        case let .invalidDraft(reason):
            return "The disclosure review is incomplete: \(reason)."
        case .externalProviderNoticeRequired:
            return "Acknowledge the external provider privacy and account notice before sharing."
        case .rawEvidenceConsentRequired:
            return "Complete packages containing raw evidence require explicit approval for that exact selection."
        case .unexpectedRawEvidenceConsent:
            return "Raw-evidence approval must be off when the reviewed package does not contain raw evidence."
        case .aiReadyCannotIncludeRawEvidence:
            return "AI-ready packages cannot include raw capture evidence or diagnostics."
        case .preciseGPSMustBeExcluded:
            return "Precise GPS must be excluded from every AI Room Package."
        case .staleReview:
            return "The package plan or selected content changed. Review it again before sharing."
        case .replayedReview:
            return "This disclosure approval has already been consumed. Start a fresh review."
        }
    }
}

struct RoomAIDisclosureSelectedImage: Sendable, Equatable, Identifiable {
    var id: String { imageID }
    var imageID: String
    var displayName: String
    var mediaType: String
    var byteCount: UInt64
    var advisories: [RoomAISensitiveContentAdvisory]
    var replacesImageID: String?
    var isRawEvidence: Bool

    init(
        imageID: String,
        displayName: String,
        mediaType: String,
        byteCount: UInt64,
        advisories: [RoomAISensitiveContentAdvisory],
        replacesImageID: String?,
        isRawEvidence: Bool = false
    ) {
        self.imageID = imageID
        self.displayName = displayName
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.advisories = advisories
        self.replacesImageID = replacesImageID
        self.isRawEvidence = isRawEvidence
    }
}

struct RoomAIDisclosureArtifactSummary: Sendable, Equatable, Identifiable {
    var id: String { artifactID }
    var artifactID: String
    var artifactClass: RoomRedesignArtifactClass
    var disposition: RoomArtifactDisposition
    var reasonCode: String?

    init(
        artifactID: String,
        artifactClass: RoomRedesignArtifactClass,
        disposition: RoomArtifactDisposition,
        reasonCode: String?
    ) {
        self.artifactID = artifactID
        self.artifactClass = artifactClass
        self.disposition = disposition
        self.reasonCode = reasonCode
    }
}

struct RoomAIDisclosureDraft: Sendable, Equatable {
    var sourceRevision: RoomRedesignSourceRevision
    var profile: RoomAIRoomPackageProfile
    var artifactPlanSHA256: String
    var selectionSHA256: String
    var selectedImages: [RoomAIDisclosureSelectedImage]
    var artifactInventory: [RoomAIDisclosureArtifactSummary]
    var estimatedPackageByteCount: UInt64
    var qualityWarnings: [String]
    var includesRawEvidence: Bool
    var preciseGPSExcluded: Bool

    init(
        sourceRevision: RoomRedesignSourceRevision,
        profile: RoomAIRoomPackageProfile,
        artifactPlanSHA256: String,
        selectionSHA256: String,
        selectedImages: [RoomAIDisclosureSelectedImage],
        artifactInventory: [RoomAIDisclosureArtifactSummary],
        estimatedPackageByteCount: UInt64,
        qualityWarnings: [String],
        includesRawEvidence: Bool,
        preciseGPSExcluded: Bool
    ) {
        self.sourceRevision = sourceRevision
        self.profile = profile
        self.artifactPlanSHA256 = artifactPlanSHA256
        self.selectionSHA256 = selectionSHA256
        self.selectedImages = selectedImages
        self.artifactInventory = artifactInventory
        self.estimatedPackageByteCount = estimatedPackageByteCount
        self.qualityWarnings = qualityWarnings
        self.includesRawEvidence = includesRawEvidence
        self.preciseGPSExcluded = preciseGPSExcluded
    }
}

/// Owns the mandatory, exact outbound review boundary. Approval is useful
/// only while its immutable source, artifact plan, and selected bytes remain
/// unchanged; package construction consumes an approval at most once.
@MainActor
final class RoomAIDisclosureCoordinator: ObservableObject {
    @Published private(set) var state: RoomAIDisclosureState = .idle
    @Published private(set) var draft: RoomAIDisclosureDraft?

    var distributableReview: RoomDisclosureReview? {
        state == .approved ? approvedReview : nil
    }

    private let clock: () -> Date
    private let reviewID: () -> String
    private var approvedReview: RoomDisclosureReview?

    init(
        clock: @escaping () -> Date = Date.init,
        reviewID: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.clock = clock
        self.reviewID = reviewID
    }

    func beginReview(_ draft: RoomAIDisclosureDraft) throws {
        try Self.validate(draft)
        self.draft = draft
        approvedReview = nil
        state = .reviewing
    }

    func replaceDraft(_ replacement: RoomAIDisclosureDraft) throws {
        try Self.validate(replacement)
        let oldDraft = draft
        draft = replacement

        switch state {
        case .approved:
            if oldDraft != replacement {
                approvedReview = nil
                state = .stale
            }
        case .consumed:
            if oldDraft != replacement {
                approvedReview = nil
                state = .stale
            }
        case .reviewing:
            approvedReview = nil
        case .idle, .rejected, .stale:
            approvedReview = nil
            state = .reviewing
        }
    }

    @discardableResult
    func approve(
        externalProviderNoticeAccepted: Bool,
        rawEvidenceDisclosureAccepted: Bool
    ) throws -> RoomDisclosureReview {
        guard state == .reviewing, let draft else {
            if state == .consumed { throw RoomAIDisclosureError.replayedReview }
            throw RoomAIDisclosureError.invalidState
        }
        guard externalProviderNoticeAccepted else {
            throw RoomAIDisclosureError.externalProviderNoticeRequired
        }
        if draft.includesRawEvidence, !rawEvidenceDisclosureAccepted {
            throw RoomAIDisclosureError.rawEvidenceConsentRequired
        }
        if !draft.includesRawEvidence, rawEvidenceDisclosureAccepted {
            throw RoomAIDisclosureError.unexpectedRawEvidenceConsent
        }

        let review = RoomDisclosureReview(
            reviewID: reviewID(),
            reviewedAt: Self.canonicalTimestamp(clock()),
            decision: .approved,
            sourceRevisionID: draft.sourceRevision.revisionID,
            sourceRevisionManifestSHA256: draft.sourceRevision.revisionManifestSHA256,
            reviewedArtifactPlanSHA256: draft.artifactPlanSHA256,
            reviewedSelectionSHA256: draft.selectionSHA256,
            preciseGPSExcluded: true,
            rawEvidenceDisclosureAccepted: rawEvidenceDisclosureAccepted
        )
        try review.validate(
            boundTo: draft.sourceRevision,
            artifactPlanSHA256: draft.artifactPlanSHA256,
            selectionSHA256: draft.selectionSHA256,
            permitsRawEvidence: draft.profile == .complete,
            at: "disclosureReview"
        )
        approvedReview = review
        state = .approved
        return review
    }

    func reject() {
        approvedReview = nil
        state = .rejected
    }

    /// Returns an exact approval once. This is the only entry point package
    /// assembly should use; read-only UI may inspect `distributableReview`.
    func consumeApprovedReview(
        sourceRevision: RoomRedesignSourceRevision,
        artifactPlanSHA256: String,
        selectionSHA256: String
    ) throws -> RoomDisclosureReview {
        guard state != .consumed else {
            throw RoomAIDisclosureError.replayedReview
        }
        guard state == .approved,
              let draft,
              let approvedReview,
              draft.sourceRevision == sourceRevision,
              draft.artifactPlanSHA256 == artifactPlanSHA256,
              draft.selectionSHA256 == selectionSHA256
        else {
            self.approvedReview = nil
            state = .stale
            throw RoomAIDisclosureError.staleReview
        }
        try approvedReview.validate(
            boundTo: sourceRevision,
            artifactPlanSHA256: artifactPlanSHA256,
            selectionSHA256: selectionSHA256,
            permitsRawEvidence: draft.profile == .complete,
            at: "disclosureReview"
        )
        self.approvedReview = nil
        state = .consumed
        return approvedReview
    }

    private static func validate(_ draft: RoomAIDisclosureDraft) throws {
        do {
            try draft.sourceRevision.validate()
        } catch {
            throw RoomAIDisclosureError.invalidDraft("invalid source revision binding")
        }
        guard isSHA256(draft.artifactPlanSHA256), isSHA256(draft.selectionSHA256) else {
            throw RoomAIDisclosureError.invalidDraft("invalid artifact-plan or selection digest")
        }
        guard draft.preciseGPSExcluded else {
            throw RoomAIDisclosureError.preciseGPSMustBeExcluded
        }
        guard draft.profile != .aiReady || !draft.includesRawEvidence else {
            throw RoomAIDisclosureError.aiReadyCannotIncludeRawEvidence
        }
        guard !draft.artifactInventory.isEmpty,
              Set(draft.artifactInventory.map(\.artifactID)).count == draft.artifactInventory.count,
              Set(draft.selectedImages.map(\.imageID)).count == draft.selectedImages.count
        else {
            throw RoomAIDisclosureError.invalidDraft("artifact and image identifiers must be nonempty and unique")
        }
        let includedRawRGBIDs = Set(draft.artifactInventory.compactMap { artifact in
            artifact.artifactClass == .rawRGB && artifact.disposition == .included
                ? artifact.artifactID
                : nil
        })
        let disclosedRawRGBIDs = Set(draft.selectedImages.compactMap { image in
            image.isRawEvidence ? image.imageID : nil
        })
        guard includedRawRGBIDs == disclosedRawRGBIDs else {
            throw RoomAIDisclosureError.invalidDraft(
                "every included raw RGB artifact must have exact image metadata and a review preview"
            )
        }
        guard draft.estimatedPackageByteCount > 0 else {
            throw RoomAIDisclosureError.invalidDraft("package size estimate must be positive")
        }
        for image in draft.selectedImages {
            guard !image.imageID.isEmpty,
                  !image.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  image.byteCount > 0,
                  image.mediaType == "image/jpeg" || image.mediaType == "image/png"
            else {
                throw RoomAIDisclosureError.invalidDraft("selected image metadata is invalid")
            }
        }
        for artifact in draft.artifactInventory {
            guard !artifact.artifactID.isEmpty else {
                throw RoomAIDisclosureError.invalidDraft("artifact identifier is empty")
            }
            switch artifact.disposition {
            case .included:
                guard artifact.reasonCode == nil else {
                    throw RoomAIDisclosureError.invalidDraft("included artifacts cannot carry omission reasons")
                }
            case .excluded, .skipped, .unavailable, .failed:
                guard let reason = artifact.reasonCode,
                      !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    throw RoomAIDisclosureError.invalidDraft("omitted artifacts require stable reasons")
                }
            }
        }
    }

    /// `RoomJSONCoding` intentionally uses canonical ISO-8601 whole seconds.
    /// Normalize before identity is reviewed so a production `Date()` value
    /// survives strict encode/decode equality just like an injected fixture.
    private static func canonicalTimestamp(_ value: Date) -> Date {
        Date(
            timeIntervalSinceReferenceDate: floor(
                value.timeIntervalSinceReferenceDate
            )
        )
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            ("0"..."9").contains(Character(String($0)))
                || ("a"..."f").contains(Character(String($0)))
        }
    }
}
