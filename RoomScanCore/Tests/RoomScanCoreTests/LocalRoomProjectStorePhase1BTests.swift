import Foundation
import XCTest
@testable import RoomScanCore

final class LocalRoomProjectStorePhase1BTests: XCTestCase {
    func testConfiguredRootLeafSymlinkIsRejectedWithoutTouchingExternalDirectory() async throws {
        let rootLink = temporaryURL(prefix: "RoomScanRootLink")
        let externalDirectory = temporaryURL(prefix: "RoomScanExternalRoot")
        defer {
            try? FileManager.default.removeItem(at: rootLink)
            try? FileManager.default.removeItem(at: externalDirectory)
        }

        try FileManager.default.createDirectory(
            at: externalDirectory,
            withIntermediateDirectories: true
        )
        let markerURL = externalDirectory.appendingPathComponent("marker.txt")
        let marker = Data("external-root-marker".utf8)
        try marker.write(to: markerURL, options: .atomic)
        try FileManager.default.createSymbolicLink(
            atPath: rootLink.path,
            withDestinationPath: externalDirectory.path
        )

        let store = makeStore(root: rootLink)
        let draft = try makeDraft()
        await assertStoreError(.symbolicLinkDetected(rootLink.lastPathComponent)) {
            _ = try await store.saveDraft(draft, disposition: .save)
        }

        XCTAssertEqual(try Data(contentsOf: markerURL), marker)
    }

    func testAppendRejectsInitialDuplicateAndInconsistentRevertReasons() async throws {
        let root = temporaryURL(prefix: "RoomScanReason")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = makeStore(root: root)
        let savedResult = try await store.saveDraft(
            try makeDraft(),
            disposition: .save
        )
        let saved = try XCTUnwrap(savedResult)
        let package = try await store.load(projectID: saved.projectID)
        let payload = try XCTUnwrap(package.revisions.first).payload

        await assertStoreError(
            .invalidRevisionReason(reason: .initial, restoredFromRevisionID: nil)
        ) {
            _ = try await store.appendRevision(
                projectID: saved.projectID,
                revisionID: "revision-002",
                parentRevisionID: "revision-001",
                reason: .initial,
                payload: payload,
                restoredFromRevisionID: nil
            )
        }
        await assertStoreError(
            .invalidRevisionReason(reason: .duplicate, restoredFromRevisionID: nil)
        ) {
            _ = try await store.appendRevision(
                projectID: saved.projectID,
                revisionID: "revision-002",
                parentRevisionID: "revision-001",
                reason: .duplicate,
                payload: payload,
                restoredFromRevisionID: nil
            )
        }
        await assertStoreError(
            .invalidRevisionReason(reason: .revert, restoredFromRevisionID: nil)
        ) {
            _ = try await store.appendRevision(
                projectID: saved.projectID,
                revisionID: "revision-002",
                parentRevisionID: "revision-001",
                reason: .revert,
                payload: payload,
                restoredFromRevisionID: nil
            )
        }
        await assertStoreError(
            .invalidRevisionReason(
                reason: .edit,
                restoredFromRevisionID: "revision-001"
            )
        ) {
            _ = try await store.appendRevision(
                projectID: saved.projectID,
                revisionID: "revision-002",
                parentRevisionID: "revision-001",
                reason: .edit,
                payload: payload,
                restoredFromRevisionID: "revision-001"
            )
        }
    }

    func testListingIsolatesMalformedManifestAndKeepsValidSiblingVisible() async throws {
        let root = temporaryURL(prefix: "RoomScanListing")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = makeStore(root: root)
        let savedResult = try await store.saveDraft(
            try makeDraft(),
            disposition: .save
        )
        let saved = try XCTUnwrap(savedResult)
        let corruptProjectURL = root.appendingPathComponent("project-corrupt", isDirectory: true)
        try FileManager.default.createDirectory(
            at: corruptProjectURL,
            withIntermediateDirectories: true
        )
        try Data("{ not-json".utf8).write(
            to: corruptProjectURL.appendingPathComponent("manifest.json"),
            options: .atomic
        )

        let listing = try await store.listProjectListing(includeArchived: true)

        XCTAssertEqual(listing.summaries.map(\.projectID), [saved.projectID])
        XCTAssertEqual(listing.issues.count, 1)
        XCTAssertEqual(listing.issues.first?.projectID, "project-corrupt")
        XCTAssertEqual(listing.issues.first?.kind, .corruptPackage)
    }

    func testListingIsolatesSymlinkedManifestAndLeavesExternalMarkerUntouched() async throws {
        let root = temporaryURL(prefix: "RoomScanListingLink")
        let externalDirectory = temporaryURL(prefix: "RoomScanExternalManifest")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalDirectory)
        }

        let store = makeStore(root: root)
        let savedResult = try await store.saveDraft(
            try makeDraft(),
            disposition: .save
        )
        let saved = try XCTUnwrap(savedResult)
        try FileManager.default.createDirectory(
            at: externalDirectory,
            withIntermediateDirectories: true
        )
        let markerURL = externalDirectory.appendingPathComponent("marker.json")
        let marker = Data("external-manifest-marker".utf8)
        try marker.write(to: markerURL, options: .atomic)

        let linkedProjectURL = root.appendingPathComponent(
            "project-manifest-link",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: linkedProjectURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: linkedProjectURL.appendingPathComponent("manifest.json").path,
            withDestinationPath: markerURL.path
        )

        let listing = try await store.listProjectListing(includeArchived: true)

        XCTAssertEqual(listing.summaries.map(\.projectID), [saved.projectID])
        XCTAssertEqual(listing.issues.count, 1)
        XCTAssertEqual(listing.issues.first?.projectID, "project-manifest-link")
        XCTAssertEqual(listing.issues.first?.kind, .symbolicLink)
        XCTAssertEqual(try Data(contentsOf: markerURL), marker)
    }

    func testProjectRootAssetPolicyRequiresContainedRegularFiles() async throws {
        let root = temporaryURL(prefix: "RoomScanAssetPolicy")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = makeStore(root: root)
        let savedResult = try await store.saveDraft(
            try makeDraft(),
            disposition: .save
        )
        let saved = try XCTUnwrap(savedResult)
        var package = try await store.load(projectID: saved.projectID)
        package.manifest.assetPolicy = RoomAssetPolicy(
            nativeUSDZ: try RoomRelativePath("exports/missing.usdz")
        )
        try RoomJSONCoding.makeEncoder().encode(package.manifest).write(
            to: root.appendingPathComponent("\(saved.projectID)/manifest.json"),
            options: .atomic
        )

        await assertStoreError(.assetReferenceNotStaged("exports/missing.usdz")) {
            _ = try await store.load(projectID: saved.projectID)
        }
    }

    func testStoredLineageRejectsLaterInitialMissingRevertSourceAndTemporalRevertSources() async throws {
        let root = temporaryURL(prefix: "RoomScanStoredLineage")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = makeStore(
            root: root,
            revisionIDs: ["revision-001", "revision-002", "revision-003"]
        )
        let savedResult = try await store.saveDraft(
            try makeDraft(),
            disposition: .save
        )
        let saved = try XCTUnwrap(savedResult)
        let initialPackage = try await store.load(projectID: saved.projectID)
        let payload = try XCTUnwrap(initialPackage.revisions.first).payload

        _ = try await store.appendEditRevision(
            projectID: saved.projectID,
            payload: payload,
            newRevisionID: "revision-002"
        )
        _ = try await store.appendEditRevision(
            projectID: saved.projectID,
            payload: payload,
            newRevisionID: "revision-003"
        )

        let revisionManifestURL = root.appendingPathComponent(
            "\(saved.projectID)/revisions/revision-002/revision.json"
        )
        let original = try RoomJSONCoding.makeDecoder().decode(
            RoomRevisionManifest.self,
            from: Data(contentsOf: revisionManifestURL)
        )

        var laterInitial = original
        laterInitial.reason = .initial
        try write(laterInitial, to: revisionManifestURL)
        await assertStoreError(
            .invalidRevisionReason(reason: .initial, restoredFromRevisionID: nil)
        ) {
            _ = try await store.load(projectID: saved.projectID)
        }

        var missingRevertSource = original
        missingRevertSource.reason = .revert
        missingRevertSource.restoredFromRevisionID = nil
        try write(missingRevertSource, to: revisionManifestURL)
        await assertStoreError(
            .invalidRevisionReason(reason: .revert, restoredFromRevisionID: nil)
        ) {
            _ = try await store.load(projectID: saved.projectID)
        }

        var selfRevertSource = original
        selfRevertSource.reason = .revert
        selfRevertSource.restoredFromRevisionID = "revision-002"
        try write(selfRevertSource, to: revisionManifestURL)
        await assertStoreError(
            .invalidRevisionReason(
                reason: .revert,
                restoredFromRevisionID: "revision-002"
            )
        ) {
            _ = try await store.load(projectID: saved.projectID)
        }

        var futureRevertSource = original
        futureRevertSource.reason = .revert
        futureRevertSource.restoredFromRevisionID = "revision-003"
        try write(futureRevertSource, to: revisionManifestURL)
        await assertStoreError(
            .invalidRevisionReason(
                reason: .revert,
                restoredFromRevisionID: "revision-003"
            )
        ) {
            _ = try await store.load(projectID: saved.projectID)
        }
    }

    func testStoredDuplicateRootRevisionRemainsValid() async throws {
        let root = temporaryURL(prefix: "RoomScanDuplicateRoot")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = makeStore(
            root: root,
            projectIDs: ["project-001", "project-002"],
            revisionIDs: ["revision-001", "revision-002"]
        )
        let savedResult = try await store.saveDraft(
            try makeDraft(),
            disposition: .save
        )
        let saved = try XCTUnwrap(savedResult)

        let duplicate = try await store.duplicate(projectID: saved.projectID)
        let duplicatePackage = try await store.load(projectID: duplicate.projectID)

        XCTAssertEqual(duplicatePackage.revisions.first?.manifest.reason, .duplicate)
        XCTAssertNil(duplicatePackage.revisions.first?.manifest.parentRevisionID)
        XCTAssertNil(duplicatePackage.revisions.first?.manifest.restoredFromRevisionID)
    }

    private func makeStore(
        root: URL,
        projectIDs: [String] = ["project-001"],
        revisionIDs: [String] = ["revision-001"]
    ) -> LocalRoomProjectStore {
        LocalRoomProjectStore(
            rootURL: root,
            clock: FixedRoomProjectClock(date: Date(timeIntervalSince1970: 1_704_067_200)),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: projectIDs,
                revisionIDs: revisionIDs
            )
        )
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try RoomJSONCoding.makeEncoder().encode(value).write(to: url, options: .atomic)
    }

    private func makeDraft() throws -> RoomDraft {
        let date = Date(timeIntervalSince1970: 1_704_067_200)
        return RoomDraft(
            metadata: RoomMetadata(
                projectID: "draft",
                customName: "Phase 1B room",
                captureDate: date,
                lastRevisedDate: date,
                manualLocation: "Fixture Lab",
                optionalGPS: nil,
                notes: "",
                tags: [],
                thumbnailRelativePath: nil,
                archived: false
            ),
            revision: RoomRevisionPayload(
                semanticSnapshot: RoomSemanticSnapshot(
                    projectID: "draft",
                    revisionID: "draft",
                    units: "meters",
                    accuracyDisclaimer: "Estimates only, not survey-grade.",
                    structuralElements: [
                        RoomSemanticElement(
                            id: "structure-floor-001",
                            kind: "floor",
                            label: "Floor",
                            dimensionsMeters: RoomDimensions(width: 4, height: 0.1, depth: 3)
                        )
                    ],
                    movableElements: []
                ),
                annotations: [],
                measurements: [],
                photos: []
            )
        )
    }

    private func temporaryURL(prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)",
            isDirectory: true
        )
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
