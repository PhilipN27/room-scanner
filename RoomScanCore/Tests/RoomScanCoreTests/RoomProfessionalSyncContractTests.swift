import Foundation
import XCTest
@testable import RoomScanCore

final class RoomProfessionalSyncContractTests: XCTestCase {
    private let digestA = String(repeating: "a", count: 64)
    private let digestB = String(repeating: "b", count: 64)

    func testVersionedContractsAreCanonicalStrictAndExposeOnlyExplicitOperations() throws {
        let initial = try RoomInitialProjectSyncV1(
            sourceProjectID: "project-001",
            proposedRevisionID: "revision-001",
            workingSetManifestSHA256: digestA,
            archiveSHA256: digestB,
            archiveByteCount: 42
        )
        let encoded = try RoomProfessionalSyncCanonicalJSON.encode(initial)

        XCTAssertEqual(
            String(decoding: encoded, as: UTF8.self),
            "{\"archiveByteCount\":42,\"archiveSHA256\":\"\(digestB)\",\"proposedRevisionID\":\"revision-001\",\"schemaVersion\":\"roomscan-initial-project-sync-v1\",\"sourceProjectID\":\"project-001\",\"workingSetManifestSHA256\":\"\(digestA)\"}"
        )
        XCTAssertEqual(try RoomProfessionalSyncCanonicalJSON.decodeInitial(encoded), initial)

        let unknownKey = Data("{\"archiveByteCount\":42,\"archiveSHA256\":\"\(digestB)\",\"proposedRevisionID\":\"revision-001\",\"schemaVersion\":\"roomscan-initial-project-sync-v1\",\"sourceProjectID\":\"project-001\",\"unexpected\":true,\"workingSetManifestSHA256\":\"\(digestA)\"}".utf8)
        XCTAssertThrowsError(try RoomProfessionalSyncCanonicalJSON.decodeInitial(unknownKey)) { error in
            XCTAssertEqual(
                error as? RoomProfessionalSyncContractError,
                .unknownKey(path: "$", key: "unexpected")
            )
        }
        XCTAssertThrowsError(try RoomJSONCoding.makeDecoder().decode(
            RoomInitialProjectSyncV1.self,
            from: encoded
        )) { error in
            XCTAssertEqual(
                error as? RoomProfessionalSyncContractError,
                .untrustedDecoding
            )
        }

        let duplicateKey = Data("{\"archiveByteCount\":42,\"archiveSHA256\":\"\(digestB)\",\"proposedRevisionID\":\"revision-001\",\"schemaVersion\":\"roomscan-initial-project-sync-v1\",\"sourceProjectID\":\"project-001\",\"sourceProjectID\":\"project-002\",\"workingSetManifestSHA256\":\"\(digestA)\"}".utf8)
        XCTAssertThrowsError(try RoomProfessionalSyncCanonicalJSON.decodeInitial(duplicateKey)) { error in
            XCTAssertEqual(
                error as? RoomProfessionalSyncContractError,
                .duplicateKey(path: "$", key: "sourceProjectID")
            )
        }

        let append = try RoomProjectRevisionAppendV1(
            projectID: "project-001",
            expectedHeadRevisionID: "revision-001",
            proposedRevisionID: "revision-002",
            workingSetManifestSHA256: digestA,
            archiveSHA256: digestB,
            archiveByteCount: 43
        )
        XCTAssertNil(RoomProfessionalSyncIntent.createInitialHead(initial).expectedHeadRevisionID)
        XCTAssertEqual(
            RoomProfessionalSyncIntent.appendRevision(append).expectedHeadRevisionID,
            "revision-001"
        )
        XCTAssertThrowsError(try RoomProjectRevisionAppendV1(
            projectID: "project-001",
            expectedHeadRevisionID: "",
            proposedRevisionID: "revision-002",
            workingSetManifestSHA256: digestA,
            archiveSHA256: digestB,
            archiveByteCount: 43
        ))

        let source = RoomRedesignSourceRevision(
            projectID: "project-001",
            revisionID: "revision-002",
            coordinateSpaceEpochID: "epoch-001",
            packageSchemaVersion: RoomProjectSchemaVersion.v2.rawValue,
            semanticSHA256: digestA,
            revisionManifestSHA256: digestB
        )
        let review = try RoomRawDisclosureReview(
            reviewID: "raw-review-001",
            sourceRevision: source,
            reviewedSelectionSHA256: String(repeating: "c", count: 64),
            reviewedAt: Date(timeIntervalSince1970: 1_704_067_200),
            decision: .accepted
        )
        let rawAttachment = try RoomRawArchiveAttachmentV1(
            projectID: "project-001",
            revisionID: "revision-002",
            review: review,
            manifestSHA256: digestA,
            archiveSHA256: digestB,
            archiveByteCount: 44
        )
        XCTAssertNil(RoomProfessionalSyncIntent.attachRawArchive(rawAttachment).expectedHeadRevisionID)
        XCTAssertEqual(
            Set(RoomProfessionalSyncOperation.allCases),
            [.createInitialHead, .appendRevision, .attachRawArchive]
        )
    }

    func testRawReviewRejectsSubsecondDatesAndRoundTripsWholeSecondsExactly() throws {
        let source = RoomRedesignSourceRevision(
            projectID: "project-001",
            revisionID: "revision-002",
            coordinateSpaceEpochID: "epoch-001",
            packageSchemaVersion: RoomProjectSchemaVersion.v2.rawValue,
            semanticSHA256: digestA,
            revisionManifestSHA256: digestB
        )

        XCTAssertThrowsError(try RoomRawDisclosureReview(
            reviewID: "raw-review-fractional",
            sourceRevision: source,
            reviewedSelectionSHA256: String(repeating: "c", count: 64),
            reviewedAt: Date(timeIntervalSince1970: 1_704_067_200.875),
            decision: .accepted
        ))

        let review = try RoomRawDisclosureReview(
            reviewID: "raw-review-whole-second",
            sourceRevision: source,
            reviewedSelectionSHA256: String(repeating: "c", count: 64),
            reviewedAt: Date(timeIntervalSince1970: 1_704_067_200),
            decision: .accepted
        )
        let encoded = try RoomProfessionalSyncCanonicalJSON.encode(review)
        XCTAssertEqual(try RoomProfessionalSyncCanonicalJSON.decodeRawReview(encoded), review)
    }
}
