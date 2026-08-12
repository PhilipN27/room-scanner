import Foundation
import XCTest
@testable import RoomScanCore

final class LocalRoomProjectStoreTests: XCTestCase {
    func testExplicitSaveCreatesExactlyOneProjectAndDiscardCreatesNone() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = makeStore(root: root)
        let draft = try makeDraft()

        let discarded = try await store.saveDraft(draft, disposition: .discard)

        XCTAssertNil(discarded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

        let savedResult = try await store.saveDraft(draft, disposition: .save)
        let saved = try XCTUnwrap(savedResult)
        let summaries = try await store.listSummaries(includeArchived: true)

        XCTAssertEqual(saved.projectID, "project-001")
        XCTAssertEqual(saved.headRevisionID, "revision-001")
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.projectID, "project-001")
    }

    func testMetadataDuplicateArchiveAndDeleteActionsRemainLocalToPackages() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = makeStore(
            root: root,
            projectIDs: ["project-001", "project-duplicate-001"],
            revisionIDs: ["revision-001", "revision-duplicate-001"]
        )
        let originalSaveResult = try await store.saveDraft(
            try makeDraft(),
            disposition: .save
        )
        let originalSummary = try XCTUnwrap(originalSaveResult)
        let originalPackage = try await store.load(projectID: originalSummary.projectID)
        var metadata = originalPackage.metadata
        metadata.customName = "Renamed library room"
        metadata.manualLocation = "North classroom"
        metadata.notes = "Keep the doorway clear."
        metadata.tags = ["training", "accessible"]
        metadata.optionalGPS = RoomGPSLocation(
            latitude: 41.117,
            longitude: -73.408,
            horizontalAccuracyMeters: 9,
            capturedAt: fixedDate
        )

        let edited = try await store.updateMetadata(projectID: originalSummary.projectID, metadata: metadata)
        let duplicated = try await store.duplicate(projectID: originalSummary.projectID)

        XCTAssertEqual(edited.customName, "Renamed library room")
        XCTAssertEqual(edited.manualLocation, "North classroom")
        XCTAssertNotEqual(duplicated.projectID, originalSummary.projectID)
        XCTAssertEqual(duplicated.headRevisionID, "revision-duplicate-001")

        try await store.archive(projectID: originalSummary.projectID)
        let activeSummaries = try await store.listSummaries()
        let archivedPackage = try await store.load(projectID: originalSummary.projectID)
        XCTAssertEqual(activeSummaries.map(\.projectID), [duplicated.projectID])
        XCTAssertTrue(archivedPackage.metadata.archived)

        try await store.unarchive(projectID: originalSummary.projectID)
        let unarchivedPackage = try await store.load(projectID: originalSummary.projectID)
        XCTAssertFalse(unarchivedPackage.metadata.archived)

        try await store.delete(projectID: duplicated.projectID)
        let remainingSummaries = try await store.listSummaries(includeArchived: true)
        XCTAssertEqual(remainingSummaries.count, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(duplicated.projectID).path
            )
        )
    }

    func testAppendAndRestoreNeverModifyRevisionOneBytes() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = makeStore(root: root)
        let savedResult = try await store.saveDraft(
            try makeDraft(),
            disposition: .save
        )
        let saved = try XCTUnwrap(savedResult)
        let sourceDirectory = revisionDirectory(
            root: root,
            projectID: saved.projectID,
            revisionID: "revision-001"
        )
        let originalBytes = try byteSnapshot(at: sourceDirectory)
        let originalPackage = try await store.load(projectID: saved.projectID)
        let payload = try XCTUnwrap(originalPackage.revisions.first).payload

        let edit = try await store.appendRevision(
            projectID: saved.projectID,
            revisionID: "revision-002",
            parentRevisionID: "revision-001",
            reason: .edit,
            payload: payload,
            restoredFromRevisionID: nil
        )
        let revert = try await store.restoreAsNewRevision(
            projectID: saved.projectID,
            sourceRevisionID: "revision-001",
            newRevisionID: "revision-003"
        )
        let reloaded = try await store.load(projectID: saved.projectID)

        XCTAssertEqual(edit.parentRevisionID, "revision-001")
        XCTAssertEqual(revert.reason, .revert)
        XCTAssertEqual(revert.parentRevisionID, "revision-002")
        XCTAssertEqual(revert.restoredFromRevisionID, "revision-001")
        XCTAssertEqual(reloaded.manifest.headRevisionID, "revision-003")
        XCTAssertEqual(reloaded.manifest.revisionIDs, ["revision-001", "revision-002", "revision-003"])
        XCTAssertEqual(try byteSnapshot(at: sourceDirectory), originalBytes)
    }

    func testRevisionValidationRejectsDuplicateWrongParentMissingSourceUnsafeIDsAndExistingDirectories() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = makeStore(root: root)
        let savedResult = try await store.saveDraft(
            try makeDraft(),
            disposition: .save
        )
        let saved = try XCTUnwrap(savedResult)
        let savedPackage = try await store.load(projectID: saved.projectID)
        let payload = try XCTUnwrap(savedPackage.revisions.first).payload

        await assertStoreError(
            .parentDoesNotMatchHead(
                projectID: saved.projectID,
                expected: "revision-001",
                actual: "revision-other"
            )
        ) {
            _ = try await store.appendRevision(
                projectID: saved.projectID,
                revisionID: "revision-002",
                parentRevisionID: "revision-other",
                reason: .edit,
                payload: payload,
                restoredFromRevisionID: nil
            )
        }

        await assertStoreError(.duplicateRevisionID("revision-001")) {
            _ = try await store.appendRevision(
                projectID: saved.projectID,
                revisionID: "revision-001",
                parentRevisionID: "revision-001",
                reason: .edit,
                payload: payload,
                restoredFromRevisionID: nil
            )
        }

        await assertStoreError(.revisionNotFound(projectID: saved.projectID, revisionID: "revision-missing")) {
            _ = try await store.restoreAsNewRevision(
                projectID: saved.projectID,
                sourceRevisionID: "revision-missing",
                newRevisionID: "revision-003"
            )
        }

        await assertStoreError(.invalidIdentifier("../revision-unsafe")) {
            _ = try await store.appendRevision(
                projectID: saved.projectID,
                revisionID: "../revision-unsafe",
                parentRevisionID: "revision-001",
                reason: .edit,
                payload: payload,
                restoredFromRevisionID: nil
            )
        }

        let occupied = revisionDirectory(
            root: root,
            projectID: saved.projectID,
            revisionID: "revision-occupied"
        )
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)

        await assertStoreError(.revisionAlreadyExists("revision-occupied")) {
            _ = try await store.appendRevision(
                projectID: saved.projectID,
                revisionID: "revision-occupied",
                parentRevisionID: "revision-001",
                reason: .edit,
                payload: payload,
                restoredFromRevisionID: nil
            )
        }

        XCTAssertThrowsError(try RoomRelativePath("../thumbnail.png"))
    }

    func testReloadPreservesPackageAndHiddenStagingArtifactsNeverAppearAsProjects() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = makeStore(root: root)
        let savedResult = try await store.saveDraft(
            try makeDraft(),
            disposition: .save
        )
        let saved = try XCTUnwrap(savedResult)
        let firstLoad = try await store.load(projectID: saved.projectID)
        let staging = root.appendingPathComponent(".staging-project-ignored", isDirectory: true)
        let incomplete = root.appendingPathComponent("project-incomplete", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)

        let secondLoad = try await store.load(projectID: saved.projectID)
        let summaries = try await store.listSummaries(includeArchived: true)

        XCTAssertEqual(firstLoad, secondLoad)
        XCTAssertEqual(summaries.map(\.projectID), [saved.projectID])
    }

    private let fixedDate = Date(timeIntervalSince1970: 1_704_067_200)

    func testHeroCachePublishReadInvalidateRoundTripsAsDerivedData() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let saveResult = try await store.saveDraft(try makeDraft(), disposition: .save)
        let saved = try XCTUnwrap(saveResult)

        let absent = try await store.heroCache(projectID: saved.projectID)
        XCTAssertNil(absent)
        // Invalidating an absent cache is a no-op, not an error.
        try await store.invalidateHeroCache(projectID: saved.projectID)

        let manifest = makeHeroManifest(pixelWidth: 800)
        let image = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        try await store.publishHeroCache(
            projectID: saved.projectID, manifest: manifest, imageData: image
        )
        let cachedResult = try await store.heroCache(projectID: saved.projectID)
        let cached = try XCTUnwrap(cachedResult)
        XCTAssertEqual(cached.manifest, manifest)
        XCTAssertEqual(cached.imageData, image)

        // Derived data is replaceable: a second publish overwrites in place.
        let replacement = makeHeroManifest(pixelWidth: 400)
        try await store.publishHeroCache(
            projectID: saved.projectID, manifest: replacement, imageData: Data([9])
        )
        let replacedResult = try await store.heroCache(projectID: saved.projectID)
        let replaced = try XCTUnwrap(replacedResult)
        XCTAssertEqual(replaced.manifest, replacement)
        XCTAssertEqual(replaced.imageData, Data([9]))

        try await store.invalidateHeroCache(projectID: saved.projectID)
        let invalidated = try await store.heroCache(projectID: saved.projectID)
        XCTAssertNil(invalidated)
    }

    func testHeroCacheRejectsUnsafeIdentifiersAndUnknownProjects() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        _ = try await store.saveDraft(try makeDraft(), disposition: .save)

        let manifest = makeHeroManifest(pixelWidth: 800)
        do {
            try await store.publishHeroCache(
                projectID: "../escape", manifest: manifest, imageData: Data([1])
            )
            XCTFail("unsafe identifier must be rejected")
        } catch {}
        do {
            try await store.publishHeroCache(
                projectID: "project-999", manifest: manifest, imageData: Data([1])
            )
            XCTFail("unknown project must be rejected")
        } catch {}
        do {
            _ = try await store.heroCache(projectID: "../escape")
            XCTFail("unsafe identifier must be rejected on read")
        } catch {}
        do {
            _ = try await store.heroCache(projectID: "project-999")
            XCTFail("unknown project must be rejected on read")
        } catch {}
    }

    private func makeHeroManifest(pixelWidth: Int) -> RoomMeshHeroCacheManifest {
        RoomMeshHeroCacheManifest(
            heroAlgorithmVersion: RoomMeshHeroCache.algorithmVersion,
            photorealManifest: RoomMeshPhotorealCacheManifest(
                algorithmVersion: RoomMeshPhotorealCache.algorithmVersion,
                sourceMeshSHA256: "mesh-hash",
                bundleManifestSHA256: "bundle-hash",
                sourceFrames: [],
                atlasSize: 1_024,
                coveredFaceCount: 3,
                coveredAreaEstimate: 1.5,
                colorSpaceTag: "sRGB",
                settings: RoomMeshPhotorealSettings()
            ),
            coloredMeshSHA256: "colored-hash",
            atlasSHA256: nil,
            pixelWidth: pixelWidth,
            pixelHeight: 600,
            colorSpaceTag: "sRGB"
        )
    }

    private func makeTemporaryRoot() throws -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RoomScanCoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeStore(
        root: URL,
        projectIDs: [String] = ["project-001"],
        revisionIDs: [String] = ["revision-001"]
    ) -> LocalRoomProjectStore {
        LocalRoomProjectStore(
            rootURL: root,
            clock: FixedRoomProjectClock(date: fixedDate),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: projectIDs,
                revisionIDs: revisionIDs
            )
        )
    }

    private func makeDraft() throws -> RoomDraft {
        let metadata = RoomMetadata(
            projectID: "draft",
            customName: "Mock Studio Room",
            captureDate: fixedDate,
            lastRevisedDate: fixedDate,
            manualLocation: "Fixture Lab",
            optionalGPS: nil,
            notes: "Initial fixture-backed draft.",
            tags: ["fixture"],
            thumbnailRelativePath: nil,
            archived: false
        )
        let semantic = RoomSemanticSnapshot(
            projectID: "draft",
            revisionID: "draft",
            units: "meters",
            accuracyDisclaimer: "Dimensions are estimates and are not survey-grade measurements.",
            structuralElements: [
                RoomSemanticElement(
                    id: "structure-floor-001",
                    kind: "floor",
                    label: "Floor",
                    dimensionsMeters: RoomDimensions(width: 5, height: 0.1, depth: 4)
                )
            ],
            movableElements: [
                RoomSemanticElement(
                    id: "movable-desk-001",
                    kind: "desk",
                    label: "Desk",
                    dimensionsMeters: RoomDimensions(width: 1.2, height: 0.75, depth: 0.6)
                )
            ]
        )
        let payload = RoomRevisionPayload(
            semanticSnapshot: semantic,
            annotations: [
                RoomAnnotation(
                    id: "annotation-001",
                    createdAt: fixedDate,
                    text: "Fixture note"
                )
            ],
            measurements: [
                RoomMeasurement(
                    id: "measurement-001",
                    label: "Room width",
                    valueMeters: 5
                )
            ],
            photos: []
        )
        return RoomDraft(metadata: metadata, revision: payload)
    }

    private func revisionDirectory(root: URL, projectID: String, revisionID: String) -> URL {
        root
            .appendingPathComponent(projectID, isDirectory: true)
            .appendingPathComponent("revisions", isDirectory: true)
            .appendingPathComponent(revisionID, isDirectory: true)
    }

    private func byteSnapshot(at directory: URL) throws -> [String: Data] {
        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        var snapshot: [String: Data] = [:]

        while let fileURL = enumerator?.nextObject() as? URL {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                continue
            }

            let relative = fileURL.path.replacingOccurrences(
                of: directory.path + "/",
                with: ""
            )
            snapshot[relative] = try Data(contentsOf: fileURL)
        }

        return snapshot
    }

    private func assertStoreError(
        _ expected: RoomProjectStoreError,
        operation: @escaping @Sendable () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected) to be thrown.")
        } catch {
            XCTAssertEqual(error as? RoomProjectStoreError, expected)
        }
    }
}
