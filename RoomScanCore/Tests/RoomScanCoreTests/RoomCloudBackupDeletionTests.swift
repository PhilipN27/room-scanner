import Foundation
import XCTest
@testable import RoomScanCore

final class RoomCloudBackupDeletionTests: XCTestCase {
    private let requestedAt = Date(timeIntervalSince1970: 1_790_000_000.25)
    private let recordA = "rssb1-" + String(repeating: "a", count: 64)
    private let recordB = "rssb1-" + String(repeating: "b", count: 64)
    private let recordC = "rssb1-" + String(repeating: "c", count: 64)

    private func request(
        knownRecordNames: [String] = [],
        attempts: Int = 0,
        lastAttemptAt: Date? = nil,
        lastErrorMessage: String? = nil
    ) -> RoomCloudBackupDeletionRequest {
        RoomCloudBackupDeletionRequest(
            projectID: "ui-project-001",
            containerIdentifier: "iCloud.org.roomscanstudio.ui-test",
            displayName: "UI Test Room",
            requestedAt: requestedAt,
            knownRecordNames: knownRecordNames,
            attempts: attempts,
            lastAttemptAt: lastAttemptAt,
            lastErrorMessage: lastErrorMessage
        )
    }

    func testRequestRoundTripsWithNilAndNonNilOptionals() throws {
        let withoutOptionals = request()
        let withOptionals = request(
            knownRecordNames: [recordA, recordB],
            attempts: 2,
            lastAttemptAt: requestedAt.addingTimeInterval(61.5),
            lastErrorMessage: "Injected network unavailable."
        )
        for value in [withoutOptionals, withOptionals] {
            try value.validate()
            let data = try JSONEncoder().encode(value)
            XCTAssertEqual(try JSONDecoder().decode(RoomCloudBackupDeletionRequest.self, from: data), value)
        }
        let outcome = RoomCloudBackupDeletionOutcome(
            deletedRecordNames: [recordB, recordA],
            remainingRecordNames: [recordC],
            failures: [recordC: "Network unavailable."]
        )
        XCTAssertEqual(outcome.deletedRecordNames, [recordA, recordB])
        XCTAssertFalse(outcome.isComplete)
        XCTAssertEqual(
            try JSONDecoder().decode(RoomCloudBackupDeletionOutcome.self, from: JSONEncoder().encode(outcome)),
            outcome
        )
    }

    func testRequestDecodesMissingOptionalFieldsAsNil() throws {
        let json = """
        {"attempts":0,"containerIdentifier":"iCloud.org.roomscanstudio.ui-test","displayName":"UI Test Room",\
        "knownRecordNames":[],"projectID":"ui-project-001","requestedAt":0,\
        "schemaVersion":"\(RoomCloudBackupDeletionRequest.currentSchemaVersion)"}
        """
        let decoded = try JSONDecoder().decode(RoomCloudBackupDeletionRequest.self, from: Data(json.utf8))
        XCTAssertNil(decoded.lastAttemptAt)
        XCTAssertNil(decoded.lastErrorMessage)
        XCTAssertEqual(decoded.attempts, 0)
        try decoded.validate()
    }

    func testValidationRejectsUnsafeOrNonCanonicalRequests() {
        var cases: [(String, RoomCloudBackupDeletionRequest)] = []
        var value = request(); value.projectID = "../escape"; cases.append(("traversal", value))
        value = request(); value.projectID = ""; cases.append(("empty project", value))
        value = request(); value.projectID = "a/b"; cases.append(("slash", value))
        value = request(); value.containerIdentifier = ""; cases.append(("empty container", value))
        value = request(); value.containerIdentifier = "$(ROOMSCAN_CONTAINER)"; cases.append(("unresolved container", value))
        value = request(); value.schemaVersion = "v0"; cases.append(("schema", value))
        value = request(); value.attempts = -1; cases.append(("attempts", value))
        value = request(knownRecordNames: ["rssb1-short"]); cases.append(("record name", value))
        value = request(knownRecordNames: [recordB, recordA]); cases.append(("unsorted names", value))
        value = request(knownRecordNames: [recordA, recordA]); cases.append(("duplicate names", value))
        for (label, candidate) in cases {
            XCTAssertThrowsError(try candidate.validate(), label)
        }
        XCTAssertTrue(RoomCloudBackupDeletionRequest.isRecordName(recordA))
        XCTAssertFalse(RoomCloudBackupDeletionRequest.isRecordName("rssb1-" + String(repeating: "A", count: 64)))
    }

    func testRecordingAttemptKeepsRemainingNamesAndClearsErrorOnlyWhenComplete() throws {
        let base = request(knownRecordNames: [recordA, recordB])
        let attemptDate = requestedAt.addingTimeInterval(30)
        let partial = base.recordingAttempt(
            at: attemptDate,
            outcome: .init(deletedRecordNames: [recordA], remainingRecordNames: [recordB, recordC],
                           failures: [recordB: "x", recordC: "y"])
        )
        XCTAssertEqual(partial.attempts, 1)
        XCTAssertEqual(partial.lastAttemptAt, attemptDate)
        XCTAssertEqual(partial.knownRecordNames, [recordB, recordC])
        XCTAssertEqual(partial.lastErrorMessage, "2 backup records could not be deleted yet.")
        try partial.validate()

        let complete = partial.recordingAttempt(
            at: attemptDate, outcome: .init(deletedRecordNames: [recordB, recordC])
        )
        XCTAssertEqual(complete.attempts, 2)
        XCTAssertEqual(complete.knownRecordNames, [])
        XCTAssertNil(complete.lastErrorMessage)

        let failed = base.recordingFailure(at: attemptDate, message: String(repeating: "é", count: 2_000))
        XCTAssertEqual(failed.attempts, 1)
        XCTAssertEqual(failed.knownRecordNames, base.knownRecordNames)
        XCTAssertLessThanOrEqual(
            failed.lastErrorMessage?.utf8.count ?? .max,
            RoomCloudBackupDeletionRequest.maximumErrorMessageUTF8Bytes
        )
        try failed.validate()
    }
}
