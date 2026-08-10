import Foundation
import XCTest
import RoomScanCore
@testable import RoomScanStudio

@MainActor
final class RoomViewerEditorAppTests: XCTestCase {
    func testViewerScenePlanSeparatesRootsAppliesVisibilityAndCamera() throws {
        let payload = try makePayload()
        let plan = RoomViewerScenePlan(payload: payload)
        let visibility = RoomViewerVisibility(
            structural: true,
            objects: false,
            measurements: true,
            annotations: true,
            photos: true
        )
        let camera = try RoomViewerCameraReducer.reduce(
            .defaultState,
            action: .side
        )

        XCTAssertEqual(plan.structuralElements.count, 1)
        XCTAssertEqual(plan.objectElements.count, 1)
        XCTAssertEqual(plan.measurements.count, 1)
        XCTAssertEqual(plan.annotations.count, 1)
        XCTAssertEqual(plan.photos.count, 1)
        XCTAssertEqual(plan.visibilityState(for: .objects, visibility: visibility), false)
        XCTAssertEqual(plan.visibilityState(for: .structural, visibility: visibility), true)
        XCTAssertEqual(plan.cameraState(camera).mode, .orbit)
        XCTAssertEqual(plan.cameraState(camera).preset, .side)
    }

    func testControllerOptimisticEditCreatesOneRevisionAndRefreshesPackageTruth() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RoomViewerEditorAppTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalRoomProjectStore(
            rootURL: root,
            clock: FixedRoomProjectClock(date: Date(timeIntervalSince1970: 1_704_067_200)),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: ["ui-project-001"],
                revisionIDs: ["revision-001", "revision-002"]
            )
        )
        let fixture = try MockRoomFixtureLoader.load(bundle: Bundle(for: Self.self))
        let savedResult = try await store.saveDraft(
            fixture.draft,
            decision: .save,
            assets: fixture.assets
        )
        let saved = try XCTUnwrap(savedResult)
        let package = try await store.load(projectID: saved.projectID)
        var editor = try RoomRevisionEditor(payload: try XCTUnwrap(package.revisions.last).payload)
        try editor.renameElement(id: "movable-desk-001", label: "Edited desk")
        let controller = RoomLibraryController(store: store, modelContainer: nil)

        let committed = try await controller.commitEditRevision(
            projectID: saved.projectID,
            expectedHeadRevisionID: package.manifest.headRevisionID,
            payload: editor.payload,
            newRevisionID: "revision-002"
        )
        let reloaded = try await store.load(projectID: saved.projectID)

        XCTAssertEqual(committed.reason, .edit)
        XCTAssertEqual(reloaded.manifest.revisionIDs, ["revision-001", "revision-002"])
        XCTAssertEqual(reloaded.revisions.last?.payload.semanticSnapshot.objectElements.first?.label, "Edited desk")
    }

    func testFixturePhotoMarkerAssetStagesOnlyAfterExplicitSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RoomViewerFixturePhoto-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalRoomProjectStore(
            rootURL: root,
            clock: FixedRoomProjectClock(date: Date(timeIntervalSince1970: 1_704_067_200)),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: ["fixture-photo-project"],
                revisionIDs: ["revision-001"]
            )
        )
        let fixture = try MockRoomFixtureLoader.load(bundle: Bundle(for: Self.self))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

        let savedResult = try await store.saveDraft(
            fixture.draft,
            decision: .save,
            assets: fixture.assets
        )
        let saved = try XCTUnwrap(savedResult)
        let copiedPhotoURL = root
            .appendingPathComponent(saved.projectID, isDirectory: true)
            .appendingPathComponent("revisions/revision-001/photos/reference-001.png")
        let sourcePhotoURL = try XCTUnwrap(fixture.revisionAssets.first?.sourceURL)

        XCTAssertEqual(try Data(contentsOf: copiedPhotoURL), try Data(contentsOf: sourcePhotoURL))
    }

    private func makePayload() throws -> RoomRevisionPayload {
        let transform = RoomTransform4x4(columnMajorValues: [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        ])
        return RoomRevisionPayload(
            semanticSnapshot: RoomSemanticSnapshot(
                projectID: "project-001",
                revisionID: "revision-001",
                units: "meters",
                accuracyDisclaimer: "Measurements are estimates, not survey-grade evidence.",
                structuralElements: [
                    RoomSemanticElement(
                        id: "floor-001",
                        kind: "floor",
                        label: "Floor",
                        dimensionsMeters: RoomDimensions(width: 5, height: 0, depth: 4),
                        transform: transform,
                        mobility: .structural
                    )
                ],
                objectElements: [
                    RoomSemanticElement(
                        id: "object-001",
                        kind: "desk",
                        label: "Desk",
                        dimensionsMeters: RoomDimensions(width: 1, height: 1, depth: 1),
                        transform: transform,
                        mobility: .fixed
                    )
                ]
            ),
            annotations: [
                RoomAnnotation(
                    id: "note-001",
                    createdAt: Date(timeIntervalSince1970: 1_704_067_200),
                    text: "Note",
                    point: RoomPoint3D(x: 0, y: 1, z: 0),
                    attachedElementID: "object-001"
                )
            ],
            measurements: [
                RoomMeasurement(
                    id: "measurement-001",
                    label: "Span",
                    valueMeters: 1,
                    startPoint: RoomPoint3D(x: 0, y: 0, z: 0),
                    endPoint: RoomPoint3D(x: 1, y: 0, z: 0)
                )
            ],
            photos: [
                RoomPhoto(
                    id: "photo-001",
                    createdAt: Date(timeIntervalSince1970: 1_704_067_200),
                    assetRelativePath: try RoomRelativePath("photos/reference-001.jpg"),
                    caption: "Reference",
                    cameraTransform: transform
                )
            ]
        )
    }
}
