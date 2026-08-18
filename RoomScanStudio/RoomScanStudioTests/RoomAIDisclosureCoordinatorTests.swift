import XCTest
import RoomScanCore
@testable import RoomScanStudio

@MainActor
final class RoomAIDisclosureCoordinatorTests: XCTestCase {
    func testApprovalBindsExactSourcePlanSelectionAndRequiredNotices() throws {
        let reviewedAt = Date(timeIntervalSince1970: 1_704_067_200)
        let coordinator = RoomAIDisclosureCoordinator(
            clock: { reviewedAt },
            reviewID: { "review-001" }
        )
        let draft = makeDraft(profile: .aiReady)

        try coordinator.beginReview(draft)
        let review = try coordinator.approve(
            externalProviderNoticeAccepted: true,
            rawEvidenceDisclosureAccepted: false
        )

        XCTAssertEqual(coordinator.state, .approved)
        XCTAssertEqual(coordinator.distributableReview, review)
        XCTAssertEqual(review.reviewID, "review-001")
        XCTAssertEqual(review.reviewedAt, reviewedAt)
        XCTAssertEqual(review.sourceRevisionID, draft.sourceRevision.revisionID)
        XCTAssertEqual(
            review.sourceRevisionManifestSHA256,
            draft.sourceRevision.revisionManifestSHA256
        )
        XCTAssertEqual(review.reviewedArtifactPlanSHA256, draft.artifactPlanSHA256)
        XCTAssertEqual(review.reviewedSelectionSHA256, draft.selectionSHA256)
        XCTAssertTrue(review.preciseGPSExcluded)
        XCTAssertFalse(review.rawEvidenceDisclosureAccepted)
    }

    func testApprovalCanonicalizesSubsecondClockBeforePackageFinalization() throws {
        let coordinator = RoomAIDisclosureCoordinator(
            clock: { Date(timeIntervalSinceReferenceDate: 100.75) },
            reviewID: { "review-subsecond" }
        )
        let draft = makeDraft(profile: .aiReady)

        try coordinator.beginReview(draft)
        let review = try coordinator.approve(
            externalProviderNoticeAccepted: true,
            rawEvidenceDisclosureAccepted: false
        )

        XCTAssertEqual(
            review.reviewedAt,
            Date(timeIntervalSinceReferenceDate: 100)
        )
    }

    func testSelectionOrPlanChangeMakesPriorApprovalStale() throws {
        let coordinator = makeCoordinator()
        var draft = makeDraft(profile: .aiReady)
        try coordinator.beginReview(draft)
        _ = try coordinator.approve(
            externalProviderNoticeAccepted: true,
            rawEvidenceDisclosureAccepted: false
        )

        draft.selectionSHA256 = String(repeating: "9", count: 64)
        try coordinator.replaceDraft(draft)
        XCTAssertEqual(coordinator.state, .stale)
        XCTAssertNil(coordinator.distributableReview)

        try coordinator.beginReview(draft)
        _ = try coordinator.approve(
            externalProviderNoticeAccepted: true,
            rawEvidenceDisclosureAccepted: false
        )
        draft.artifactPlanSHA256 = String(repeating: "8", count: 64)
        try coordinator.replaceDraft(draft)
        XCTAssertEqual(coordinator.state, .stale)
        XCTAssertNil(coordinator.distributableReview)
    }

    func testCompleteRawRequiresExplicitConsentAndAIReadyCannotPlanRaw() throws {
        let coordinator = makeCoordinator()
        let complete = makeDraft(profile: .complete, includesRawEvidence: true)
        try coordinator.beginReview(complete)
        XCTAssertThrowsError(try coordinator.approve(
            externalProviderNoticeAccepted: true,
            rawEvidenceDisclosureAccepted: false
        )) { error in
            XCTAssertEqual(error as? RoomAIDisclosureError, .rawEvidenceConsentRequired)
        }
        XCTAssertNoThrow(try coordinator.approve(
            externalProviderNoticeAccepted: true,
            rawEvidenceDisclosureAccepted: true
        ))

        XCTAssertThrowsError(try makeCoordinator().beginReview(
            makeDraft(profile: .aiReady, includesRawEvidence: true)
        )) { error in
            XCTAssertEqual(error as? RoomAIDisclosureError, .aiReadyCannotIncludeRawEvidence)
        }
    }

    func testEveryIncludedCompleteRawRGBMustAppearInSelectedImageDisclosure() {
        var incomplete = makeDraft(profile: .complete, includesRawEvidence: true)
        incomplete.artifactInventory.append(.init(
            artifactID: "raw-rgb-0001",
            artifactClass: .rawRGB,
            disposition: .included,
            reasonCode: nil
        ))

        XCTAssertThrowsError(try makeCoordinator().beginReview(incomplete)) { error in
            guard case .invalidDraft = error as? RoomAIDisclosureError else {
                return XCTFail("Expected invalid raw-image disclosure, got \(error)")
            }
        }
    }

    func testProviderNoticeGPSAndDecisionGatesFailClosed() throws {
        let coordinator = makeCoordinator()
        try coordinator.beginReview(makeDraft(profile: .aiReady))
        XCTAssertThrowsError(try coordinator.approve(
            externalProviderNoticeAccepted: false,
            rawEvidenceDisclosureAccepted: false
        )) { error in
            XCTAssertEqual(error as? RoomAIDisclosureError, .externalProviderNoticeRequired)
        }
        coordinator.reject()
        XCTAssertEqual(coordinator.state, .rejected)
        XCTAssertNil(coordinator.distributableReview)

        var unsafe = makeDraft(profile: .complete)
        unsafe.preciseGPSExcluded = false
        XCTAssertThrowsError(try makeCoordinator().beginReview(unsafe)) { error in
            XCTAssertEqual(error as? RoomAIDisclosureError, .preciseGPSMustBeExcluded)
        }
    }

    func testApprovedReviewIsConsumedOnceAndWrongRevisionFailsClosed() throws {
        let coordinator = makeCoordinator()
        let draft = makeDraft(profile: .aiReady)
        try coordinator.beginReview(draft)
        let approved = try coordinator.approve(
            externalProviderNoticeAccepted: true,
            rawEvidenceDisclosureAccepted: false
        )

        var wrongSource = draft.sourceRevision
        wrongSource.revisionID = "revision-002"
        XCTAssertThrowsError(try coordinator.consumeApprovedReview(
            sourceRevision: wrongSource,
            artifactPlanSHA256: draft.artifactPlanSHA256,
            selectionSHA256: draft.selectionSHA256
        )) { error in
            XCTAssertEqual(error as? RoomAIDisclosureError, .staleReview)
        }
        XCTAssertEqual(coordinator.state, .stale)
        XCTAssertNil(coordinator.distributableReview)

        try coordinator.beginReview(draft)
        _ = try coordinator.approve(
            externalProviderNoticeAccepted: true,
            rawEvidenceDisclosureAccepted: false
        )
        XCTAssertEqual(try coordinator.consumeApprovedReview(
            sourceRevision: draft.sourceRevision,
            artifactPlanSHA256: draft.artifactPlanSHA256,
            selectionSHA256: draft.selectionSHA256
        ), approved)
        XCTAssertEqual(coordinator.state, .consumed)
        XCTAssertNil(coordinator.distributableReview)
        XCTAssertThrowsError(try coordinator.consumeApprovedReview(
            sourceRevision: draft.sourceRevision,
            artifactPlanSHA256: draft.artifactPlanSHA256,
            selectionSHA256: draft.selectionSHA256
        )) { error in
            XCTAssertEqual(error as? RoomAIDisclosureError, .replayedReview)
        }
    }

    private func makeCoordinator() -> RoomAIDisclosureCoordinator {
        RoomAIDisclosureCoordinator(
            clock: { Date(timeIntervalSince1970: 1_704_067_200) },
            reviewID: { "review-001" }
        )
    }

    private func makeDraft(
        profile: RoomAIRoomPackageProfile,
        includesRawEvidence: Bool = false
    ) -> RoomAIDisclosureDraft {
        RoomAIDisclosureDraft(
            sourceRevision: .init(
                projectID: "project-001",
                revisionID: "revision-001",
                coordinateSpaceEpochID: "epoch-001",
                packageSchemaVersion: RoomProjectSchemaVersion.v2.rawValue,
                semanticSHA256: String(repeating: "a", count: 64),
                revisionManifestSHA256: String(repeating: "b", count: 64)
            ),
            profile: profile,
            artifactPlanSHA256: String(repeating: "c", count: 64),
            selectionSHA256: String(repeating: "d", count: 64),
            selectedImages: [
                .init(
                    imageID: "reference-001",
                    displayName: "Entry reference",
                    mediaType: "image/jpeg",
                    byteCount: 1_024,
                    advisories: RoomAISensitiveContentAnalyzer.advisories(
                        faceCount: 0,
                        humanCount: 0,
                        recognizedText: []
                    ),
                    replacesImageID: nil
                ),
            ],
            artifactInventory: [
                .init(
                    artifactID: "semantic-normalized",
                    artifactClass: .normalizedSemantics,
                    disposition: .included,
                    reasonCode: nil
                ),
            ],
            estimatedPackageByteCount: 4_096,
            qualityWarnings: ["Coverage is advisory."],
            includesRawEvidence: includesRawEvidence,
            preciseGPSExcluded: true
        )
    }
}
