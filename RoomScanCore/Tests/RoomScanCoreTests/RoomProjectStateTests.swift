import Foundation
import XCTest
@testable import RoomScanCore

final class RoomProjectStateTests: XCTestCase {
    func testAtomicNewFileWriterDoesNotReplaceAnExistingDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RoomAtomicFileWriter-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destination = root.appendingPathComponent("manifest.json")
        let original = Data("original".utf8)
        try RoomAtomicFileWriter.writeNewFile(original, to: destination)

        XCTAssertThrowsError(
            try RoomAtomicFileWriter.writeNewFile(Data("replacement".utf8), to: destination)
        )
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path).contains {
                $0.hasPrefix(".roomscan-new-file-")
            }
        )

        let externalSentinel = root.appendingPathComponent("external-sentinel.json")
        let linkedDestination = root.appendingPathComponent("linked-manifest.json")
        try original.write(to: externalSentinel)
        try FileManager.default.createSymbolicLink(
            at: linkedDestination,
            withDestinationURL: externalSentinel
        )
        XCTAssertThrowsError(
            try RoomAtomicFileWriter.writeNewFile(Data("replacement".utf8), to: linkedDestination)
        )
        XCTAssertEqual(try Data(contentsOf: externalSentinel), original)

        let danglingDestination = root.appendingPathComponent("dangling-manifest.json")
        let missingTarget = root.appendingPathComponent("missing-target.json")
        try FileManager.default.createSymbolicLink(
            at: danglingDestination,
            withDestinationURL: missingTarget
        )
        XCTAssertThrowsError(
            try RoomAtomicFileWriter.writeNewFile(Data("replacement".utf8), to: danglingDestination)
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: danglingDestination.path),
            missingTarget.path
        )
    }

    func testSaveTransitionIsTerminalAndDeterministic() {
        let draft = RoomDraftState()

        XCTAssertEqual(draft.applying(.save).status, .saved)
        XCTAssertEqual(draft.applying(.discard).status, .discarded)
        XCTAssertEqual(
            draft.applying(.save).applying(.discard).status,
            .saved,
            "A saved draft must not be discarded by a later event."
        )
        XCTAssertEqual(
            draft.applying(.discard).applying(.save).status,
            .discarded,
            "A discarded draft must not become a saved project."
        )
    }

    func testAppendingRevisionReturnsNewLineageWithoutMutatingOriginal() throws {
        let originalRevision = RoomRevision(
            id: "revision-001",
            parentRevisionID: nil,
            createdAt: "2026-01-01T00:00:00Z"
        )
        let original = RoomProjectSnapshot(
            projectID: "mock-room-v1",
            headRevisionID: originalRevision.id,
            revisions: [originalRevision]
        )
        let acceptedRevision = RoomRevision(
            id: "revision-002",
            parentRevisionID: originalRevision.id,
            createdAt: "2026-01-02T00:00:00Z"
        )

        let updated = try RevisionLineageGuard.appending(acceptedRevision, to: original)

        XCTAssertEqual(original.headRevisionID, "revision-001")
        XCTAssertEqual(original.revisions, [originalRevision])
        XCTAssertEqual(updated.headRevisionID, "revision-002")
        XCTAssertEqual(updated.revisions, [originalRevision, acceptedRevision])
    }

    func testAppendingRevisionRejectsUnregisteredOrDuplicateLineage() {
        let root = RoomRevision(
            id: "revision-001",
            parentRevisionID: nil,
            createdAt: "2026-01-01T00:00:00Z"
        )
        let project = RoomProjectSnapshot(
            projectID: "mock-room-v1",
            headRevisionID: root.id,
            revisions: [root]
        )

        XCTAssertThrowsError(
            try RevisionLineageGuard.appending(
                RoomRevision(
                    id: "revision-002",
                    parentRevisionID: "revision-missing",
                    createdAt: "2026-01-02T00:00:00Z"
                ),
                to: project
            )
        ) { error in
            XCTAssertEqual(
                error as? RevisionLineageError,
                .parentMustMatchHead(expected: "revision-001", actual: "revision-missing")
            )
        }

        XCTAssertThrowsError(
            try RevisionLineageGuard.appending(root, to: project)
        ) { error in
            XCTAssertEqual(error as? RevisionLineageError, .duplicateRevisionID("revision-001"))
        }
    }
}
