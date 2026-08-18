import XCTest
@testable import RoomScanStudio

final class RoomAISensitiveContentAnalyzerTests: XCTestCase {
    func testAutomaticEvidenceAndManualReviewPromptsUseCanonicalNonDuplicateOrder() {
        let advisories = RoomAISensitiveContentAnalyzer.advisories(
            faceCount: 1,
            humanCount: 1,
            recognizedText: [
                "42 Example Street London SW1A 1AA",
                "Household calendar",
            ]
        )

        XCTAssertEqual(advisories.map(\.kind), [
            .possiblePersonOrFace,
            .possibleDocumentOrScreen,
            .possibleAddressOrLocationText,
            .reviewFamilyPhotographs,
            .reviewReflectiveSurfaces,
            .reviewScreenOrDocumentExposure,
            .reviewPreciseLocationExposure,
        ])
        XCTAssertEqual(Set(advisories.map(\.kind)).count, advisories.count)
        XCTAssertEqual(advisories.first?.basis, .automaticSignal)
        XCTAssertEqual(advisories.last?.basis, .userReviewRequired)
    }

    func testAbsenceOfMachineSignalNeverClaimsSensitiveContentIsAbsent() {
        let advisories = RoomAISensitiveContentAnalyzer.advisories(
            faceCount: 0,
            humanCount: 0,
            recognizedText: []
        )

        XCTAssertEqual(advisories.map(\.kind), [
            .reviewFamilyPhotographs,
            .reviewReflectiveSurfaces,
            .reviewScreenOrDocumentExposure,
            .reviewPreciseLocationExposure,
        ])
        XCTAssertTrue(RoomAISensitiveContentAnalyzer.disclaimer.contains("may miss"))
        XCTAssertTrue(RoomAISensitiveContentAnalyzer.disclaimer.contains("does not redact"))
    }

    func testTextWithoutAddressGetsDocumentSignalButNotLocationSignal() {
        let advisories = RoomAISensitiveContentAnalyzer.advisories(
            faceCount: 0,
            humanCount: 0,
            recognizedText: ["Quarterly project notes"]
        )

        XCTAssertTrue(advisories.contains { $0.kind == .possibleDocumentOrScreen })
        XCTAssertFalse(advisories.contains { $0.kind == .possibleAddressOrLocationText })
    }
}
