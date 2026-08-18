import Foundation
import XCTest
@testable import RoomScanCore

final class RoomConceptSetStoreTests: XCTestCase {
    func testImportListsAndReopensCanonicalConceptWithoutChangingSourceBytes() async throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sourceRoot = temporary.appendingPathComponent("source", isDirectory: true)
        let conceptRoot = temporary.appendingPathComponent("concepts", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
        let sourceMarker = sourceRoot.appendingPathComponent("immutable-source.bin")
        let originalSourceBytes = Data("immutable-captured-source".utf8)
        try originalSourceBytes.write(to: sourceMarker, options: .withoutOverwriting)
        let sourceDigest = try RoomSHA256.hexDigest(ofFile: sourceMarker)
        let context = makeContext()
        let materialization = makeImport(conceptSetID: "concept-set-001", context: context)

        let store = LocalRoomConceptStore(rootURL: conceptRoot, sourcePackageRootURL: sourceRoot)
        let imported = try await store.importConceptSet(materialization, context: context)
        XCTAssertEqual(imported, materialization.conceptSet)
        let listed = try await store.list(context: context)
        XCTAssertEqual(listed, [materialization.conceptSet])
        let attachmentData = try await store.attachmentData(
            conceptSetID: "concept-set-001",
            attachmentID: "attachment-001",
            context: context
        )
        XCTAssertEqual(attachmentData, Self.safePNG)

        let reopenedStore = LocalRoomConceptStore(rootURL: conceptRoot, sourcePackageRootURL: sourceRoot)
        let reopened = try await reopenedStore.load(conceptSetID: "concept-set-001", context: context)
        XCTAssertEqual(reopened, materialization.conceptSet)
        XCTAssertEqual(try RoomSHA256.hexDigest(ofFile: sourceMarker), sourceDigest)
        XCTAssertEqual(try Data(contentsOf: sourceMarker), originalSourceBytes)
    }

    func testWrongAttachmentIdentityAndWrongSourcePublishNothing() async throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sourceRoot = temporary.appendingPathComponent("source", isDirectory: true)
        let conceptRoot = temporary.appendingPathComponent("concepts", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
        let context = makeContext()
        let store = LocalRoomConceptStore(rootURL: conceptRoot, sourcePackageRootURL: sourceRoot)

        var wrongBytes = makeImport(conceptSetID: "concept-set-wrong-bytes", context: context)
        wrongBytes.attachments[0].data = Data("not-the-declared-image".utf8)
        await assertThrowsAsync {
            _ = try await store.importConceptSet(wrongBytes, context: context)
        }

        let rebound = RoomRedesignSourceRevision(
            projectID: context.expectedSourceRevision.projectID,
            revisionID: "revision-other",
            coordinateSpaceEpochID: context.expectedSourceRevision.coordinateSpaceEpochID,
            packageSchemaVersion: context.expectedSourceRevision.packageSchemaVersion,
            semanticSHA256: context.expectedSourceRevision.semanticSHA256,
            revisionManifestSHA256: context.expectedSourceRevision.revisionManifestSHA256
        )
        let wrongSource = makeImport(
            conceptSetID: "concept-set-wrong-source",
            context: .init(expectedSourceRevision: rebound, currentCanonicalCameraIDs: ["canonical-front"])
        )
        await assertThrowsAsync {
            _ = try await store.importConceptSet(wrongSource, context: context)
        }

        let listed = try await store.list(context: context)
        XCTAssertEqual(listed, [])
        XCTAssertFalse(containsVisibleConceptManifest(in: conceptRoot))
    }

    func testPromotionFaultsRollBackOwnedStageAndFinalWithoutPublication() async throws {
        for point in [RoomConceptStoreFaultPoint.beforePromotion, .afterPromotionBeforeCommit] {
            let temporary = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: temporary) }
            let sourceRoot = temporary.appendingPathComponent("source", isDirectory: true)
            let conceptRoot = temporary.appendingPathComponent("concepts", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
            let context = makeContext()
            let store = LocalRoomConceptStore(
                rootURL: conceptRoot,
                sourcePackageRootURL: sourceRoot,
                faultInjector: FailingFaultInjector(point: point)
            )

            await assertThrowsAsync(expected: .injectedFailure(point)) {
                _ = try await store.importConceptSet(
                    self.makeImport(conceptSetID: "concept-set-001", context: context),
                    context: context
                )
            }

            let reopened = LocalRoomConceptStore(rootURL: conceptRoot, sourcePackageRootURL: sourceRoot)
            let listed = try await reopened.list(context: context)
            XCTAssertEqual(listed, [])
            XCTAssertFalse(containsVisibleConceptManifest(in: conceptRoot))
            XCTAssertFalse(containsPendingOrStagingEntry(in: conceptRoot))
        }
    }

    func testPreCancelledImportPublishesNothing() async throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sourceRoot = temporary.appendingPathComponent("source", isDirectory: true)
        let conceptRoot = temporary.appendingPathComponent("concepts", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
        let context = makeContext()
        let store = LocalRoomConceptStore(rootURL: conceptRoot, sourcePackageRootURL: sourceRoot)
        let materialization = makeImport(conceptSetID: "concept-set-001", context: context)

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.importConceptSet(materialization, context: context)
        }
        do {
            _ = try await task.value
            XCTFail("Expected a cancelled import")
        } catch {
            XCTAssertEqual(error as? RoomConceptSetError, .cancelled)
        }

        let listed = try await store.list(context: context)
        XCTAssertEqual(listed, [])
        XCTAssertFalse(containsVisibleConceptManifest(in: conceptRoot))
    }

    func testArchiveUnarchiveAndDeleteAffectOnlySelectedConcept() async throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sourceRoot = temporary.appendingPathComponent("source", isDirectory: true)
        let conceptRoot = temporary.appendingPathComponent("concepts", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
        let context = makeContext()
        let first = makeImport(conceptSetID: "concept-set-001", context: context, importedOffset: 100)
        let second = makeImport(conceptSetID: "concept-set-002", context: context, importedOffset: 200)
        let store = LocalRoomConceptStore(rootURL: conceptRoot, sourcePackageRootURL: sourceRoot)
        _ = try await store.importConceptSet(first, context: context)
        _ = try await store.importConceptSet(second, context: context)

        let archived = try await store.archive(conceptSetID: "concept-set-001", context: context)
        XCTAssertEqual(archived.archiveState, .archived)
        let secondAfterArchive = try await store.load(conceptSetID: "concept-set-002", context: context)
        XCTAssertEqual(secondAfterArchive, second.conceptSet)
        let activeIDs = try await store.list(context: context, archiveState: .active).map(\.conceptSetID)
        XCTAssertEqual(activeIDs, ["concept-set-002"])
        let archivedIDs = try await store.list(context: context, archiveState: .archived).map(\.conceptSetID)
        XCTAssertEqual(archivedIDs, ["concept-set-001"])

        let activeAgain = try await store.unarchive(conceptSetID: "concept-set-001", context: context)
        XCTAssertEqual(activeAgain.archiveState, .active)
        try await store.delete(conceptSetID: "concept-set-001", context: context)
        await assertThrowsAsync(expected: .conceptNotFound("concept-set-001")) {
            _ = try await store.load(conceptSetID: "concept-set-001", context: context)
        }
        let secondAfterDelete = try await store.load(conceptSetID: "concept-set-002", context: context)
        XCTAssertEqual(secondAfterDelete, second.conceptSet)
    }

    func testReviewUpdatePersistsManualMappingApprovalAndCommentsExactly() async throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sourceRoot = temporary.appendingPathComponent("source", isDirectory: true)
        let conceptRoot = temporary.appendingPathComponent("concepts", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
        let sourceMarker = sourceRoot.appendingPathComponent("immutable-source.bin")
        let sourceBytes = Data("immutable-captured-source".utf8)
        try sourceBytes.write(to: sourceMarker, options: .withoutOverwriting)
        let context = makeContext()
        let original = makeImport(conceptSetID: "concept-set-001", context: context)
        let store = LocalRoomConceptStore(rootURL: conceptRoot, sourcePackageRootURL: sourceRoot)
        _ = try await store.importConceptSet(original, context: context)

        var reviewed = original.conceptSet
        reviewed.attachments[0].mapping = .manual(cameraID: "canonical-front")
        reviewed.approvalState = .approved
        reviewed.comments = ["Approved after matching the front canonical view."]
        let updated = try await store.updateReview(reviewed, context: context)

        XCTAssertEqual(updated, reviewed)
        let reopenedStore = LocalRoomConceptStore(rootURL: conceptRoot, sourcePackageRootURL: sourceRoot)
        let reopened = try await reopenedStore.load(conceptSetID: reviewed.conceptSetID, context: context)
        XCTAssertEqual(reopened, reviewed)
        XCTAssertEqual(try Data(contentsOf: sourceMarker), sourceBytes)
    }

    func testReviewUpdateRejectsNonCurrentMappingAndImmutableMutationsWithoutPublication() async throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sourceRoot = temporary.appendingPathComponent("source", isDirectory: true)
        let conceptRoot = temporary.appendingPathComponent("concepts", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
        let context = makeContext()
        let original = makeImport(conceptSetID: "concept-set-001", context: context)
        let store = LocalRoomConceptStore(rootURL: conceptRoot, sourcePackageRootURL: sourceRoot)
        _ = try await store.importConceptSet(original, context: context)

        var wrongCamera = original.conceptSet
        wrongCamera.attachments[0].mapping = .manual(cameraID: "canonical-no-longer-current")
        wrongCamera.approvalState = .approved
        await assertThrowsAsync {
            _ = try await store.updateReview(wrongCamera, context: context)
        }

        var changedRequest = original.conceptSet
        changedRequest.request = "A rewritten immutable request."
        changedRequest.attachments[0].mapping = .manual(cameraID: "canonical-front")
        await assertThrowsAsync {
            _ = try await store.updateReview(changedRequest, context: context)
        }

        var changedAttachment = original.conceptSet
        changedAttachment.attachments[0].sha256 = String(repeating: "f", count: 64)
        changedAttachment.attachments[0].mapping = .manual(cameraID: "canonical-front")
        await assertThrowsAsync {
            _ = try await store.updateReview(changedAttachment, context: context)
        }

        var changedSource = original.conceptSet
        changedSource.sourceRevision.revisionID = "revision-rebound"
        await assertThrowsAsync {
            _ = try await store.updateReview(changedSource, context: context)
        }

        let retained = try await store.load(
            conceptSetID: original.conceptSet.conceptSetID,
            context: context
        )
        XCTAssertEqual(retained, original.conceptSet)
    }

    func testTamperedAttachmentFailsExactReopenButOtherConceptRemainsIsolated() async throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sourceRoot = temporary.appendingPathComponent("source", isDirectory: true)
        let conceptRoot = temporary.appendingPathComponent("concepts", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
        let context = makeContext()
        let first = makeImport(conceptSetID: "concept-set-001", context: context, importedOffset: 100)
        let second = makeImport(conceptSetID: "concept-set-002", context: context, importedOffset: 200)
        let store = LocalRoomConceptStore(rootURL: conceptRoot, sourcePackageRootURL: sourceRoot)
        _ = try await store.importConceptSet(first, context: context)
        _ = try await store.importConceptSet(second, context: context)

        let attachmentURL = conceptDirectory(
            root: conceptRoot,
            context: context,
            conceptSetID: "concept-set-001"
        ).appendingPathComponent("attachments/attachment-001.png")
        try Data(repeating: 0x41, count: Self.safePNG.count).write(to: attachmentURL, options: .atomic)

        await assertThrowsAsync {
            _ = try await store.load(conceptSetID: "concept-set-001", context: context)
        }
        await assertThrowsAsync {
            _ = try await store.list(context: context)
        }
        let isolatedSecond = try await store.load(conceptSetID: "concept-set-002", context: context)
        XCTAssertEqual(isolatedSecond, second.conceptSet)
    }

    func testDeleteRequiresExactMarkerOwnedDirectory() async throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sourceRoot = temporary.appendingPathComponent("source", isDirectory: true)
        let conceptRoot = temporary.appendingPathComponent("concepts", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
        let context = makeContext()
        let store = LocalRoomConceptStore(rootURL: conceptRoot, sourcePackageRootURL: sourceRoot)
        _ = try await store.importConceptSet(
            makeImport(conceptSetID: "concept-set-001", context: context),
            context: context
        )
        let directory = conceptDirectory(root: conceptRoot, context: context, conceptSetID: "concept-set-001")
        let ownership = directory.appendingPathComponent(".roomscan-concept-ownership.json")
        try FileManager.default.removeItem(at: ownership)

        await assertThrowsAsync {
            try await store.delete(conceptSetID: "concept-set-001", context: context)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testReplacedIntermediateDirectorySymlinkCannotRedirectArchiveWrite() async throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sourceRoot = temporary.appendingPathComponent("source", isDirectory: true)
        let conceptRoot = temporary.appendingPathComponent("concepts", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
        let context = makeContext()
        let store = LocalRoomConceptStore(rootURL: conceptRoot, sourcePackageRootURL: sourceRoot)
        _ = try await store.importConceptSet(
            makeImport(conceptSetID: "concept-set-001", context: context),
            context: context
        )

        let projectDirectory = conceptRoot.appendingPathComponent("project-001", isDirectory: true)
        let externalProject = temporary.appendingPathComponent("external-project", isDirectory: true)
        let retainedProject = temporary.appendingPathComponent("retained-project", isDirectory: true)
        try FileManager.default.copyItem(at: projectDirectory, to: externalProject)
        try FileManager.default.moveItem(at: projectDirectory, to: retainedProject)
        try FileManager.default.createSymbolicLink(at: projectDirectory, withDestinationURL: externalProject)
        let externalManifest = externalProject
            .appendingPathComponent("revision-001", isDirectory: true)
            .appendingPathComponent(context.expectedSourceRevision.revisionManifestSHA256, isDirectory: true)
            .appendingPathComponent("concept-set-001", isDirectory: true)
            .appendingPathComponent("manifest.json")
        let beforeDigest = try RoomSHA256.hexDigest(ofFile: externalManifest)

        await assertThrowsAsync {
            _ = try await store.archive(conceptSetID: "concept-set-001", context: context)
        }
        XCTAssertEqual(try RoomSHA256.hexDigest(ofFile: externalManifest), beforeDigest)
    }

    func testSourceStoreOverlapIsRejectedBeforeAnyWrite() async throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sourceRoot = temporary.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
        let sourceMarker = sourceRoot.appendingPathComponent("manifest.json")
        let sourceBytes = Data("source-manifest".utf8)
        try sourceBytes.write(to: sourceMarker, options: .withoutOverwriting)
        let context = makeContext()
        let overlappingRoot = sourceRoot.appendingPathComponent("concepts", isDirectory: true)
        let store = LocalRoomConceptStore(rootURL: overlappingRoot, sourcePackageRootURL: sourceRoot)

        await assertThrowsAsync(expected: .sourceStoreOverlap) {
            _ = try await store.importConceptSet(
                self.makeImport(conceptSetID: "concept-set-001", context: context),
                context: context
            )
        }

        XCTAssertEqual(try Data(contentsOf: sourceMarker), sourceBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: overlappingRoot.path))
    }

    func testDuplicateImportNeverOverwritesExistingConcept() async throws {
        let temporary = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sourceRoot = temporary.appendingPathComponent("source", isDirectory: true)
        let conceptRoot = temporary.appendingPathComponent("concepts", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
        let context = makeContext()
        let original = makeImport(conceptSetID: "concept-set-001", context: context)
        let store = LocalRoomConceptStore(rootURL: conceptRoot, sourcePackageRootURL: sourceRoot)
        _ = try await store.importConceptSet(original, context: context)
        var replacement = original
        replacement.conceptSet.request = "Replacement that must not overwrite the original."

        await assertThrowsAsync(expected: .conceptAlreadyExists("concept-set-001")) {
            _ = try await store.importConceptSet(replacement, context: context)
        }
        let retained = try await store.load(conceptSetID: "concept-set-001", context: context)
        XCTAssertEqual(retained, original.conceptSet)
    }

    private func makeContext() -> RoomConceptSetValidationContext {
        .init(
            expectedSourceRevision: RoomRedesignSourceRevision(
                projectID: "project-001",
                revisionID: "revision-001",
                coordinateSpaceEpochID: "epoch-001",
                packageSchemaVersion: "room-scan-project-v2",
                semanticSHA256: String(repeating: "a", count: 64),
                revisionManifestSHA256: String(repeating: "b", count: 64)
            ),
            currentCanonicalCameraIDs: ["canonical-front"]
        )
    }

    private func makeImport(
        conceptSetID: String,
        context: RoomConceptSetValidationContext,
        importedOffset: TimeInterval = 100
    ) -> RoomConceptSetImport {
        let attachment = RoomConceptSetAttachment(
            attachmentID: "attachment-001",
            relativePath: "attachments/attachment-001.png",
            sha256: RoomSHA256.hexDigest(of: Self.safePNG),
            byteCount: UInt64(Self.safePNG.count),
            mediaType: "image/png",
            sanitizationProvenance: .appReencodedLooseFile,
            mapping: .unmatched
        )
        return RoomConceptSetImport(
            conceptSet: RoomConceptSet(
                conceptSetID: conceptSetID,
                sourceRevision: context.expectedSourceRevision,
                request: "A warmer concept for \(conceptSetID).",
                scope: .stage,
                provider: nil,
                sourceAIRoomPackage: nil,
                importProvenance: .init(kind: .looseLocalFile, sourceFilename: "\(conceptSetID).png"),
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                importedAt: Date(timeIntervalSince1970: 1_700_000_000 + importedOffset),
                attachments: [attachment],
                comments: [],
                approvalState: .pending,
                archiveState: .active
            ),
            attachments: [
                RoomConceptSetAttachmentBytes(attachmentID: attachment.attachmentID, data: Self.safePNG)
            ]
        )
    }

    private func conceptDirectory(
        root: URL,
        context: RoomConceptSetValidationContext,
        conceptSetID: String
    ) -> URL {
        root
            .appendingPathComponent(context.expectedSourceRevision.projectID, isDirectory: true)
            .appendingPathComponent(context.expectedSourceRevision.revisionID, isDirectory: true)
            .appendingPathComponent(context.expectedSourceRevision.revisionManifestSHA256, isDirectory: true)
            .appendingPathComponent(conceptSetID, isDirectory: true)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoomConceptSetStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func containsVisibleConceptManifest(in root: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return false
        }
        while let url = enumerator.nextObject() as? URL {
            if url.lastPathComponent == "manifest.json",
               !url.pathComponents.contains(where: { $0.hasPrefix(".roomscan-concept-stage-") }) {
                return true
            }
        }
        return false
    }

    private func containsPendingOrStagingEntry(in root: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return false
        }
        while let url = enumerator.nextObject() as? URL {
            if url.lastPathComponent == ".pending-concept.json"
                || url.lastPathComponent.hasPrefix(".roomscan-concept-stage-") {
                return true
            }
        }
        return false
    }

    private func assertThrowsAsync(
        expected: RoomConceptSetError? = nil,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected operation to throw", file: file, line: line)
        } catch {
            if let expected {
                XCTAssertEqual(error as? RoomConceptSetError, expected, file: file, line: line)
            }
        }
    }

    private struct FailingFaultInjector: RoomConceptStoreFaultInjecting {
        var point: RoomConceptStoreFaultPoint

        func throwIfNeeded(at point: RoomConceptStoreFaultPoint) throws {
            guard point == self.point else { return }
            throw RoomConceptSetError.injectedFailure(point)
        }
    }

    private static let safePNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!
}
