import Foundation
import XCTest
@testable import RoomScanCore

final class LocalRoomProjectStoreTransactionTests: XCTestCase {
    func testInitialSaveStagesWholePackageAndPromotesDeclaredRegularAssets() async throws {
        let root = makeRoot()
        let prepared = try makeAssetBackedDraft()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: prepared.sourceDirectory)
        }

        let store = makeStore(root: root)
        let result = try await store.saveDraft(
            prepared.draft,
            disposition: .save,
            assets: prepared.assets
        )
        let saved = try XCTUnwrap(result)
        let projectURL = root.appendingPathComponent(saved.projectID, isDirectory: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.appendingPathComponent("metadata.json").path))
        XCTAssertEqual(
            try Data(contentsOf: projectURL.appendingPathComponent("thumbnails/mock.png")),
            prepared.thumbnailBytes
        )
        XCTAssertEqual(
            try Data(
                contentsOf: projectURL.appendingPathComponent(
                    "revisions/revision-001/photos/reference-001.jpg"
                )
            ),
            prepared.photoBytes
        )
        XCTAssertEqual(
            try Data(
                contentsOf: projectURL.appendingPathComponent(
                    "revisions/revision-001/attachments/native-room.usdz"
                )
            ),
            prepared.attachmentBytes
        )
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains(where: { $0.hasPrefix(".staging-") })
        )
    }

    func testDeclaredAssetsRejectDanglingAndDuplicateDestinationsAndSemanticIDsAreGloballyUnique() async throws {
        let root = makeRoot()
        let prepared = try makeAssetBackedDraft()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: prepared.sourceDirectory)
        }

        let danglingStore = makeStore(root: root)
        let missingPhotoAssets = prepared.assets.filter { $0.scope != .revision }
        await assertStoreError(.assetReferenceNotStaged("photos/reference-001.jpg")) {
            _ = try await danglingStore.saveDraft(
                prepared.draft,
                disposition: .save,
                assets: missingPhotoAssets
            )
        }

        let duplicateStore = makeStore(root: root)
        await assertStoreError(.duplicateAssetDestination("thumbnails/mock.png")) {
            _ = try await duplicateStore.saveDraft(
                prepared.draft,
                disposition: .save,
                assets: prepared.assets + [prepared.assets[0]]
            )
        }

        var collisionDraft = prepared.draft
        collisionDraft.revision.semanticSnapshot.movableElements[0].id =
            collisionDraft.revision.semanticSnapshot.structuralElements[0].id
        let invalidCollisionDraft = collisionDraft
        let collisionStore = makeStore(root: root)
        await assertStoreError(.duplicateSemanticElementID("structure-floor-001")) {
            _ = try await collisionStore.saveDraft(
                invalidCollisionDraft,
                disposition: .save,
                assets: prepared.assets
            )
        }
    }

    func testInitialPromotionFailureLeavesNoVisiblePackageAndSameIDCanRetry() async throws {
        let root = makeRoot()
        let prepared = try makeAssetBackedDraft()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: prepared.sourceDirectory)
        }

        let failingStore = makeStore(
            root: root,
            faultInjector: FailingRoomProjectStoreFaultInjector(
                point: .beforeInitialPackagePromotion
            )
        )
        await assertStoreError(.injectedFailure(.beforeInitialPackagePromotion)) {
            _ = try await failingStore.saveDraft(
                prepared.draft,
                disposition: .save,
                assets: prepared.assets
            )
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("project-001").path
            )
        )

        let retryStore = makeStore(root: root)
        let result = try await retryStore.saveDraft(
            prepared.draft,
            disposition: .save,
            assets: prepared.assets
        )
        XCTAssertEqual(try XCTUnwrap(result).projectID, "project-001")
    }

    func testAppendFailureRollsBackMarkerOwnedPromotionAndSameRevisionIDCanRetry() async throws {
        let root = makeRoot()
        let prepared = try makeAssetBackedDraft()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: prepared.sourceDirectory)
        }

        let initialStore = makeStore(root: root)
        let result = try await initialStore.saveDraft(
            prepared.draft,
            disposition: .save,
            assets: prepared.assets
        )
        let saved = try XCTUnwrap(result)
        let package = try await initialStore.load(projectID: saved.projectID)
        let payload = try XCTUnwrap(package.revisions.first).payload

        let failingStore = makeStore(
            root: root,
            faultInjector: FailingRoomProjectStoreFaultInjector(
                point: .afterRevisionPromotionBeforeManifest
            )
        )
        await assertStoreError(.injectedFailure(.afterRevisionPromotionBeforeManifest)) {
            _ = try await failingStore.appendRevision(
                projectID: saved.projectID,
                revisionID: "revision-002",
                parentRevisionID: "revision-001",
                reason: .edit,
                payload: payload,
                restoredFromRevisionID: nil,
                assets: prepared.revisionAssets
            )
        }

        let revisionURL = root.appendingPathComponent(
            "\(saved.projectID)/revisions/revision-002"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: revisionURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    "\(saved.projectID)/.pending-revision.json"
                ).path
            )
        )

        let retryStore = makeStore(root: root)
        let retried = try await retryStore.appendRevision(
            projectID: saved.projectID,
            revisionID: "revision-002",
            parentRevisionID: "revision-001",
            reason: .edit,
            payload: payload,
            restoredFromRevisionID: nil,
            assets: prepared.revisionAssets
        )

        XCTAssertEqual(retried.revisionID, "revision-002")
        let retriedPackage = try await retryStore.load(projectID: saved.projectID)
        XCTAssertEqual(
            retriedPackage.manifest.headRevisionID,
            "revision-002"
        )
    }

    func testLockedLoadReconcilesOnlyMarkerOwnedInterruptedRevision() async throws {
        let root = makeRoot()
        let prepared = try makeAssetBackedDraft()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: prepared.sourceDirectory)
        }

        let store = makeStore(root: root)
        let result = try await store.saveDraft(
            prepared.draft,
            disposition: .save,
            assets: prepared.assets
        )
        let saved = try XCTUnwrap(result)
        let projectURL = root.appendingPathComponent(saved.projectID, isDirectory: true)
        let sourceRevisionURL = projectURL.appendingPathComponent("revisions/revision-001")
        let interruptedRevisionURL = projectURL.appendingPathComponent(
            "revisions/revision-owned-interrupted"
        )
        let externalRevisionURL = projectURL.appendingPathComponent(
            "revisions/revision-external"
        )
        try FileManager.default.copyItem(at: sourceRevisionURL, to: interruptedRevisionURL)
        try FileManager.default.createDirectory(at: externalRevisionURL, withIntermediateDirectories: true)

        let loaded = try await store.load(projectID: saved.projectID)
        let transactionID = "transaction-owned-interrupted"
        var updatedManifest = loaded.manifest
        updatedManifest.revisionIDs.append("revision-owned-interrupted")
        updatedManifest.headRevisionID = "revision-owned-interrupted"
        let pending = PendingRoomRevisionTransaction(
            projectID: saved.projectID,
            revisionID: "revision-owned-interrupted",
            previousHeadRevisionID: "revision-001",
            stagingDirectoryName: ".staging-revision-owned-interrupted-test",
            transactionID: transactionID,
            updatedManifest: updatedManifest,
            createdAt: Date(timeIntervalSince1970: 1_704_067_200),
            evidenceCompatibility: .strict
        )
        let ownership = RoomRevisionOwnershipRecord(
            projectID: saved.projectID,
            revisionID: "revision-owned-interrupted",
            transactionID: transactionID
        )
        try RoomJSONCoding.makeEncoder().encode(ownership).write(
            to: interruptedRevisionURL.appendingPathComponent(
                ".roomscan-ownership.json"
            ),
            options: .atomic
        )
        let markerData = try RoomJSONCoding.makeEncoder().encode(pending)
        try markerData.write(
            to: projectURL.appendingPathComponent(".pending-revision.json"),
            options: .atomic
        )

        _ = try await store.load(projectID: saved.projectID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: interruptedRevisionURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalRevisionURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: projectURL.appendingPathComponent(".pending-revision.json").path
            )
        )
    }

    func testProjectSymlinkIsNotFollowedAndExternalMarkerIsUntouched() async throws {
        let root = makeRoot()
        let prepared = try makeAssetBackedDraft()
        let externalDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoomScanExternal-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: prepared.sourceDirectory)
            try? FileManager.default.removeItem(at: externalDirectory)
        }

        let store = makeStore(root: root)
        _ = try await store.saveDraft(
            prepared.draft,
            disposition: .save,
            assets: prepared.assets
        )

        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
        let externalMarker = externalDirectory.appendingPathComponent("marker.txt")
        let originalMarker = Data("external-marker".utf8)
        try originalMarker.write(to: externalMarker, options: .atomic)
        let projectLink = root.appendingPathComponent("project-link-001")
        try FileManager.default.createSymbolicLink(
            atPath: projectLink.path,
            withDestinationPath: externalDirectory.path
        )

        let summaries = try await store.listSummaries(includeArchived: true)
        XCTAssertFalse(summaries.contains(where: { $0.projectID == "project-link-001" }))

        await assertStoreError(.symbolicLinkDetected("project-link-001")) {
            try await store.delete(projectID: "project-link-001")
        }
        XCTAssertEqual(try Data(contentsOf: externalMarker), originalMarker)
    }

    func testEffectiveFreshnessAdvancesAcrossAppendAndRestoreWithoutMutatingEvidence() async throws {
        let root = makeRoot()
        let prepared = try makeAssetBackedDraft()
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_704_067_200))
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: prepared.sourceDirectory)
        }

        let store = makeStore(root: root, clock: clock)
        let result = try await store.saveDraft(
            prepared.draft,
            disposition: .save,
            assets: prepared.assets
        )
        let saved = try XCTUnwrap(result)
        let initial = try await store.load(projectID: saved.projectID)
        let payload = try XCTUnwrap(initial.revisions.first).payload
        let revisionOneURL = root.appendingPathComponent(
            "\(saved.projectID)/revisions/revision-001"
        )
        let revisionOneBytes = try byteSnapshot(at: revisionOneURL)

        let appendedAt = Date(timeIntervalSince1970: 1_704_067_800)
        clock.set(appendedAt)
        _ = try await store.appendRevision(
            projectID: saved.projectID,
            revisionID: "revision-002",
            parentRevisionID: "revision-001",
            reason: .edit,
            payload: payload,
            restoredFromRevisionID: nil,
            assets: prepared.revisionAssets
        )
        let revisionTwoURL = root.appendingPathComponent(
            "\(saved.projectID)/revisions/revision-002"
        )
        let revisionTwoBytes = try byteSnapshot(at: revisionTwoURL)
        let afterAppend = try await store.load(projectID: saved.projectID)
        XCTAssertEqual(afterAppend.effectiveLastRevisedDate, appendedAt)

        let restoredAt = Date(timeIntervalSince1970: 1_704_067_900)
        clock.set(restoredAt)
        _ = try await store.restoreAsNewRevision(
            projectID: saved.projectID,
            sourceRevisionID: "revision-001",
            newRevisionID: "revision-003"
        )
        let afterRestore = try await store.load(projectID: saved.projectID)
        let summaries = try await store.listSummaries(includeArchived: true)

        XCTAssertEqual(afterRestore.effectiveLastRevisedDate, restoredAt)
        XCTAssertEqual(summaries.first?.lastRevisedDate, restoredAt)
        XCTAssertEqual(try byteSnapshot(at: revisionOneURL), revisionOneBytes)
        XCTAssertEqual(try byteSnapshot(at: revisionTwoURL), revisionTwoBytes)
    }

    func testThumbnailDataRoundTripsThroughNarrowStoreAPI() async throws {
        let root = makeRoot()
        let prepared = try makeAssetBackedDraft()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: prepared.sourceDirectory)
        }

        let store = makeStore(root: root)
        let result = try await store.saveDraft(
            prepared.draft,
            disposition: .save,
            assets: prepared.assets
        )
        let saved = try XCTUnwrap(result)

        let thumbnailData = try await store.thumbnailData(projectID: saved.projectID)

        XCTAssertEqual(thumbnailData, prepared.thumbnailBytes)
    }

    func testDuplicatePreservesHeadAssetReferencesAndCopiesOwnedAssets() async throws {
        let root = makeRoot()
        let prepared = try makeAssetBackedDraft()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: prepared.sourceDirectory)
        }

        let store = makeStore(root: root)
        let result = try await store.saveDraft(
            prepared.draft,
            disposition: .save,
            assets: prepared.assets
        )
        let saved = try XCTUnwrap(result)

        let duplicate = try await store.duplicate(projectID: saved.projectID)
        let duplicatePackage = try await store.load(projectID: duplicate.projectID)

        XCTAssertEqual(
            duplicatePackage.metadata.thumbnailRelativePath,
            prepared.draft.metadata.thumbnailRelativePath
        )
        XCTAssertEqual(duplicatePackage.revisions.last?.payload.photos, prepared.draft.revision.photos)
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent(
                "\(duplicate.projectID)/thumbnails/mock.png"
            )),
            prepared.thumbnailBytes
        )
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent(
                "\(duplicate.projectID)/revisions/revision-002/photos/reference-001.jpg"
            )),
            prepared.photoBytes
        )
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent(
                "\(duplicate.projectID)/revisions/revision-002/attachments/native-room.usdz"
            )),
            prepared.attachmentBytes
        )
    }

    func testRestoreCopiesNonPhotoRevisionAttachmentByteForByte() async throws {
        let root = makeRoot()
        let prepared = try makeAssetBackedDraft()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: prepared.sourceDirectory)
        }

        let store = makeStore(root: root)
        let result = try await store.saveDraft(
            prepared.draft,
            disposition: .save,
            assets: prepared.assets
        )
        let saved = try XCTUnwrap(result)

        _ = try await store.restoreAsNewRevision(
            projectID: saved.projectID,
            sourceRevisionID: "revision-001",
            newRevisionID: "revision-002"
        )

        let restoredAttachment = try Data(
            contentsOf: root.appendingPathComponent(
                "\(saved.projectID)/revisions/revision-002/attachments/native-room.usdz"
            )
        )
        XCTAssertEqual(restoredAttachment, prepared.attachmentBytes)
    }

    func testTwoStoreInstancesSerializeAppendTransactions() async throws {
        let root = makeRoot()
        let prepared = try makeAssetBackedDraft()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: prepared.sourceDirectory)
        }

        let setupStore = makeStore(root: root)
        let result = try await setupStore.saveDraft(
            prepared.draft,
            disposition: .save,
            assets: prepared.assets
        )
        let saved = try XCTUnwrap(result)
        let package = try await setupStore.load(projectID: saved.projectID)
        let payload = try XCTUnwrap(package.revisions.first).payload
        let firstStore = makeStore(root: root)
        let secondStore = makeStore(root: root)

        async let first = firstStore.appendEditRevision(
            projectID: saved.projectID,
            payload: payload,
            newRevisionID: "revision-002",
            assets: prepared.revisionAssets
        )
        async let second = secondStore.appendEditRevision(
            projectID: saved.projectID,
            payload: payload,
            newRevisionID: "revision-003",
            assets: prepared.revisionAssets
        )
        _ = try await first
        _ = try await second

        let reloaded = try await setupStore.load(projectID: saved.projectID)
        XCTAssertEqual(reloaded.manifest.revisionIDs.count, 3)
        XCTAssertEqual(reloaded.manifest.headRevisionID, reloaded.manifest.revisionIDs.last)
    }

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RoomScanCoreTxn-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeStore(
        root: URL,
        clock: any RoomProjectClock = FixedRoomProjectClock(
            date: Date(timeIntervalSince1970: 1_704_067_200)
        ),
        faultInjector: any RoomProjectStoreFaultInjecting = NoRoomProjectStoreFaultInjector()
    ) -> LocalRoomProjectStore {
        LocalRoomProjectStore(
            rootURL: root,
            clock: clock,
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: ["project-001"],
                revisionIDs: ["revision-001"]
            ),
            faultInjector: faultInjector
        )
    }

    private func makeAssetBackedDraft() throws -> PreparedDraft {
        let sourceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoomScanAssetSources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let thumbnailSource = sourceDirectory.appendingPathComponent("thumbnail-source.png")
        let photoSource = sourceDirectory.appendingPathComponent("photo-source.jpg")
        let attachmentSource = sourceDirectory.appendingPathComponent("native-room-source.usdz")
        let thumbnailBytes = Data("thumbnail-bytes".utf8)
        let photoBytes = Data("photo-bytes".utf8)
        let attachmentBytes = Data("native-usdz-attachment-bytes".utf8)
        try thumbnailBytes.write(to: thumbnailSource, options: .atomic)
        try photoBytes.write(to: photoSource, options: .atomic)
        try attachmentBytes.write(to: attachmentSource, options: .atomic)

        let timestamp = Date(timeIntervalSince1970: 1_704_067_200)
        let metadata = RoomMetadata(
            projectID: "draft",
            customName: "Asset-backed room",
            captureDate: timestamp,
            lastRevisedDate: timestamp,
            manualLocation: "Fixture Lab",
            optionalGPS: nil,
            notes: "",
            tags: ["fixture"],
            thumbnailRelativePath: try RoomRelativePath("thumbnails/mock.png"),
            archived: false
        )
        let payload = RoomRevisionPayload(
            semanticSnapshot: RoomSemanticSnapshot(
                projectID: "draft",
                revisionID: "draft",
                units: "meters",
                accuracyDisclaimer: "Measurements are estimates, not survey-grade.",
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
                        dimensionsMeters: RoomDimensions(width: 1, height: 0.7, depth: 0.6)
                    )
                ]
            ),
            annotations: [
                RoomAnnotation(id: "annotation-001", createdAt: timestamp, text: "Note")
            ],
            measurements: [
                RoomMeasurement(id: "measurement-001", label: "Width", valueMeters: 5)
            ],
            photos: [
                RoomPhoto(
                    id: "photo-001",
                    createdAt: timestamp,
                    assetRelativePath: try RoomRelativePath("photos/reference-001.jpg"),
                    caption: "Reference"
                )
            ]
        )
        let projectAsset = RoomAssetInput(
            sourceURL: thumbnailSource,
            destination: try RoomRelativePath("thumbnails/mock.png"),
            scope: .project
        )
        let revisionAsset = RoomAssetInput(
            sourceURL: photoSource,
            destination: try RoomRelativePath("photos/reference-001.jpg"),
            scope: .revision
        )
        let attachmentAsset = RoomAssetInput(
            sourceURL: attachmentSource,
            destination: try RoomRelativePath("attachments/native-room.usdz"),
            scope: .revision
        )

        return PreparedDraft(
            draft: RoomDraft(metadata: metadata, revision: payload),
            assets: [projectAsset, revisionAsset, attachmentAsset],
            sourceDirectory: sourceDirectory,
            thumbnailBytes: thumbnailBytes,
            photoBytes: photoBytes,
            attachmentBytes: attachmentBytes
        )
    }

    private func byteSnapshot(at directory: URL) throws -> [String: Data] {
        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        var snapshot: [String: Data] = [:]

        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                continue
            }
            let relative = url.path.replacingOccurrences(
                of: directory.path + "/",
                with: ""
            )
            snapshot[relative] = try Data(contentsOf: url)
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

private struct PreparedDraft {
    let draft: RoomDraft
    let assets: [RoomAssetInput]
    let sourceDirectory: URL
    let thumbnailBytes: Data
    let photoBytes: Data
    let attachmentBytes: Data

    var revisionAssets: [RoomAssetInput] {
        assets.filter { $0.scope == .revision }
    }
}

private final class TestClock: RoomProjectClock, @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(date: Date) {
        self.date = date
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func set(_ nextDate: Date) {
        lock.lock()
        date = nextDate
        lock.unlock()
    }
}
