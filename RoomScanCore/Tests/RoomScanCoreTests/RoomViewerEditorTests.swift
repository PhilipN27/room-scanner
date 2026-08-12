import Foundation
import XCTest
@testable import RoomScanCore

final class RoomViewerEditorTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_704_067_200)

    func testLegacySpatialDocumentsDecodeWithoutNewSpatialFields() throws {
        let annotationData = Data("""
        {"projectID":"project-001","revisionID":"revision-001","annotations":[{"id":"note-001","createdAt":"2024-01-01T00:00:00Z","text":"Legacy note"}]}
        """.utf8)
        let measurementData = Data("""
        {"projectID":"project-001","revisionID":"revision-001","accuracyDisclaimer":"Not survey-grade.","measurements":[{"id":"measure-001","label":"Legacy span","valueMeters":1.2}]}
        """.utf8)

        let annotations = try RoomJSONCoding.makeDecoder().decode(
            RoomAnnotationsDocument.self,
            from: annotationData
        )
        let measurements = try RoomJSONCoding.makeDecoder().decode(
            RoomMeasurementsDocument.self,
            from: measurementData
        )

        XCTAssertNil(annotations.annotations[0].point)
        XCTAssertNil(annotations.annotations[0].attachedElementID)
        XCTAssertNil(measurements.measurements[0].startPoint)
        XCTAssertNil(measurements.measurements[0].endPoint)
    }

    func testSpatialAnnotationsAndMeasurementsRoundTrip() throws {
        let annotation = RoomAnnotation(
            id: "note-001",
            createdAt: date,
            text: "Door clearance",
            point: RoomPoint3D(x: 1, y: 0.5, z: -2),
            attachedElementID: "object-001"
        )
        let measurement = RoomMeasurement(
            id: "measure-001",
            label: "Clearance",
            valueMeters: 5,
            startPoint: RoomPoint3D(x: 0, y: 0, z: 0),
            endPoint: RoomPoint3D(x: 3, y: 4, z: 0)
        )
        let document = RoomMeasurementsDocument(
            projectID: "project-001",
            revisionID: "revision-001",
            accuracyDisclaimer: "Not survey-grade.",
            measurements: [measurement]
        )
        let annotationsDocument = RoomAnnotationsDocument(
            projectID: "project-001",
            revisionID: "revision-001",
            annotations: [annotation]
        )

        let encoded = try RoomJSONCoding.makeEncoder().encode(document)
        let encodedAnnotations = try RoomJSONCoding.makeEncoder().encode(annotationsDocument)
        let decoded = try RoomJSONCoding.makeDecoder().decode(
            RoomMeasurementsDocument.self,
            from: encoded
        )
        let decodedAnnotations = try RoomJSONCoding.makeDecoder().decode(
            RoomAnnotationsDocument.self,
            from: encodedAnnotations
        )

        XCTAssertEqual(decoded.measurements, [measurement])
        XCTAssertEqual(decodedAnnotations.annotations, [annotation])
    }

    func testViewerCameraPresetsModesClampsAndRejectsNonFiniteInput() throws {
        var camera = RoomViewerCamera.defaultState
        XCTAssertGreaterThan(camera.position.y, camera.target.y)
        let resetCamera = try RoomViewerCameraReducer.reduce(camera, action: .reset)
        XCTAssertEqual(resetCamera.position, RoomViewerCamera.defaultState.position)
        camera = try RoomViewerCameraReducer.reduce(
            camera,
            action: .orbit(yawDeltaRadians: 100, pitchDeltaRadians: 100)
        )
        XCTAssertLessThanOrEqual(camera.pitchRadians, RoomViewerCamera.pitchLimitRadians)
        XCTAssertGreaterThanOrEqual(camera.pitchRadians, -RoomViewerCamera.pitchLimitRadians)

        camera = try RoomViewerCameraReducer.reduce(camera, action: .zoom(deltaMeters: -100))
        XCTAssertEqual(camera.distanceMeters, RoomViewerCamera.minimumDistanceMeters)

        camera = try RoomViewerCameraReducer.reduce(camera, action: .firstPerson)
        XCTAssertEqual(camera.mode, .firstPerson)
        XCTAssertTrue(camera.isNoClip)
        // Walk mode moves only through .move: pan and zoom are orbit-only
        // no-ops so nothing can violate constant eye height.
        let firstPersonCamera = camera
        XCTAssertEqual(
            try RoomViewerCameraReducer.reduce(
                camera,
                action: .pan(delta: RoomPoint3D(x: 1, y: 2, z: 0))
            ),
            firstPersonCamera
        )
        XCTAssertEqual(
            try RoomViewerCameraReducer.reduce(camera, action: .zoom(deltaMeters: -0.5)),
            firstPersonCamera
        )

        let topCamera = try RoomViewerCameraReducer.reduce(camera, action: .top)
        XCTAssertEqual(topCamera.preset, .top)
        XCTAssertGreaterThan(topCamera.position.y, topCamera.target.y)
        XCTAssertEqual(
            try RoomViewerCameraReducer.reduce(camera, action: .front).preset,
            .front
        )
        XCTAssertEqual(
            try RoomViewerCameraReducer.reduce(camera, action: .side).preset,
            .side
        )
        XCTAssertThrowsError(
            try RoomViewerCameraReducer.reduce(
                camera,
                action: .orbit(yawDeltaRadians: .infinity, pitchDeltaRadians: 0)
            )
        )
    }

    func testIncrementalViewerOrbitDeltasMatchOneTotalGestureDelta() throws {
        let start = RoomViewerCamera.defaultState
        let firstIncrement = try RoomViewerCameraReducer.reduce(
            start,
            action: .orbit(yawDeltaRadians: 0.08, pitchDeltaRadians: -0.03)
        )
        let incremental = try RoomViewerCameraReducer.reduce(
            firstIncrement,
            action: .orbit(yawDeltaRadians: 0.12, pitchDeltaRadians: -0.02)
        )
        let total = try RoomViewerCameraReducer.reduce(
            start,
            action: .orbit(yawDeltaRadians: 0.20, pitchDeltaRadians: -0.05)
        )
        XCTAssertEqual(incremental.yawRadians, total.yawRadians, accuracy: 0.000_000_1)
        XCTAssertEqual(incremental.pitchRadians, total.pitchRadians, accuracy: 0.000_000_1)
        XCTAssertEqual(incremental.position.x, total.position.x, accuracy: 0.000_000_1)
        XCTAssertEqual(incremental.position.y, total.position.y, accuracy: 0.000_000_1)
        XCTAssertEqual(incremental.position.z, total.position.z, accuracy: 0.000_000_1)
    }

    func testWalkMoveIntegratesYawOnlyMovementAtConstantEyeHeight() throws {
        var camera = try RoomViewerCameraReducer.reduce(
            RoomViewerCamera.defaultState,
            action: .firstPerson
        )
        // Look steeply downward: walking must still travel horizontally.
        camera = try RoomViewerCameraReducer.reduce(
            camera,
            action: .orbit(yawDeltaRadians: 0, pitchDeltaRadians: -1.2)
        )
        let start = camera
        let moved = try RoomViewerCameraReducer.reduce(
            camera,
            action: .move(localX: 0, localZ: 1, deltaTime: 0.1)
        )
        XCTAssertEqual(moved.position.y, start.position.y, accuracy: 0.000_001)
        let dx = moved.position.x - start.position.x
        let dz = moved.position.z - start.position.z
        let distance = (dx * dx + dz * dz).squareRoot()
        XCTAssertEqual(
            distance,
            RoomViewerCameraReducer.walkSpeedMetersPerSecond * 0.1,
            accuracy: 0.000_001
        )
        // Movement follows the look yaw: forward is (-sin(yaw), -cos(yaw)).
        XCTAssertEqual(dx, -sin(start.yawRadians) * distance, accuracy: 0.000_001)
        XCTAssertEqual(dz, -cos(start.yawRadians) * distance, accuracy: 0.000_001)
        XCTAssertEqual(moved.preset, .custom)
    }

    func testWalkMoveIsFrameRateIndependent() throws {
        let camera = try RoomViewerCameraReducer.reduce(
            RoomViewerCamera.defaultState,
            action: .firstPerson
        )
        var manySmallTicks = camera
        for _ in 0..<10 {
            manySmallTicks = try RoomViewerCameraReducer.reduce(
                manySmallTicks,
                action: .move(localX: 0.5, localZ: 0.5, deltaTime: 0.008)
            )
        }
        let oneBigTick = try RoomViewerCameraReducer.reduce(
            camera,
            action: .move(localX: 0.5, localZ: 0.5, deltaTime: 0.08)
        )
        XCTAssertEqual(manySmallTicks.position.x, oneBigTick.position.x, accuracy: 0.000_001)
        XCTAssertEqual(manySmallTicks.position.y, oneBigTick.position.y, accuracy: 0.000_001)
        XCTAssertEqual(manySmallTicks.position.z, oneBigTick.position.z, accuracy: 0.000_001)
    }

    func testWalkMoveClampsDiagonalInputRadially() throws {
        let camera = try RoomViewerCameraReducer.reduce(
            RoomViewerCamera.defaultState,
            action: .firstPerson
        )
        // A full-diagonal thumb (1, 1) has magnitude sqrt(2); it must be
        // clamped to unit magnitude, not per-axis, so diagonal walking is no
        // faster than straight-line walking.
        let diagonal = try RoomViewerCameraReducer.reduce(
            camera,
            action: .move(localX: 1, localZ: 1, deltaTime: 0.1)
        )
        let dx = diagonal.position.x - camera.position.x
        let dy = diagonal.position.y - camera.position.y
        let dz = diagonal.position.z - camera.position.z
        let distance = (dx * dx + dy * dy + dz * dz).squareRoot()
        XCTAssertEqual(
            distance,
            RoomViewerCameraReducer.walkSpeedMetersPerSecond * 0.1,
            accuracy: 0.000_001
        )
    }

    func testWalkMoveAppliesDeadZoneAndDeltaTimeCap() throws {
        let camera = try RoomViewerCameraReducer.reduce(
            RoomViewerCamera.defaultState,
            action: .firstPerson
        )
        let deadZone = try RoomViewerCameraReducer.reduce(
            camera,
            action: .move(localX: 0.03, localZ: 0.03, deltaTime: 0.1)
        )
        XCTAssertEqual(deadZone, camera)

        // A stalled frame (huge deltaTime) must not teleport the camera past
        // the capped per-tick distance.
        let stalled = try RoomViewerCameraReducer.reduce(
            camera,
            action: .move(localX: 0, localZ: 1, deltaTime: 10)
        )
        let capped = try RoomViewerCameraReducer.reduce(
            camera,
            action: .move(
                localX: 0,
                localZ: 1,
                deltaTime: RoomViewerCameraReducer.maximumMoveDeltaTime
            )
        )
        XCTAssertEqual(stalled.position, capped.position)
    }

    func testWalkMoveIgnoredInOrbitModeAndRejectsInvalidInput() throws {
        let orbitCamera = RoomViewerCamera.defaultState
        XCTAssertEqual(orbitCamera.mode, .orbit)
        let unchanged = try RoomViewerCameraReducer.reduce(
            orbitCamera,
            action: .move(localX: 0, localZ: 1, deltaTime: 0.1)
        )
        XCTAssertEqual(unchanged, orbitCamera)

        let walkCamera = try RoomViewerCameraReducer.reduce(orbitCamera, action: .firstPerson)
        XCTAssertThrowsError(
            try RoomViewerCameraReducer.reduce(
                walkCamera,
                action: .move(localX: .nan, localZ: 0, deltaTime: 0.1)
            )
        )
        XCTAssertThrowsError(
            try RoomViewerCameraReducer.reduce(
                walkCamera,
                action: .move(localX: 0, localZ: 1, deltaTime: .infinity)
            )
        )
        XCTAssertThrowsError(
            try RoomViewerCameraReducer.reduce(
                walkCamera,
                action: .move(localX: 0, localZ: 1, deltaTime: -0.1)
            )
        )
    }

    func testRevisionEditorUsesCopyOnWriteForSemanticSpatialAndPhotoEdits() throws {
        let base = try makePayload()
        var editor = try RoomRevisionEditor(payload: base)

        try editor.renameElement(id: "object-001", label: "Reading table")
        try editor.updateCategory(id: "object-001", kind: "table")
        try editor.updateDimensions(
            id: "object-001",
            dimensions: RoomDimensions(width: 1.4, height: 0.8, depth: 0.7)
        )
        try editor.updatePose(
            id: "object-001",
            transform: identityTransform(translationX: 2)
        )
        try editor.addManualObject(
            id: "manual-001",
            kind: "cabinet",
            label: "Manual cabinet",
            dimensions: RoomDimensions(width: 1, height: 1, depth: 0.5),
            transform: identityTransform(translationX: 3)
        )
        try editor.addSpatialAnnotation(
            id: "note-001",
            text: "Keep clear",
            createdAt: date,
            point: RoomPoint3D(x: 1, y: 0, z: 0),
            attachedElementID: "manual-001"
        )
        try editor.addPointToPointMeasurement(
            id: "measure-001",
            label: "Clearance",
            startPoint: RoomPoint3D(x: 0, y: 0, z: 0),
            endPoint: RoomPoint3D(x: 0, y: 3, z: 4)
        )
        try editor.updatePhotoCaption(id: "photo-001", caption: "Updated reference")

        XCTAssertEqual(base.semanticSnapshot.objectElements[0].label, "Desk")
        XCTAssertEqual(editor.payload.semanticSnapshot.objectElements.count, 2)
        XCTAssertEqual(editor.payload.annotations[0].attachedElementID, "manual-001")
        XCTAssertEqual(editor.payload.measurements[0].valueMeters, 5)
        XCTAssertEqual(editor.payload.photos[0].caption, "Updated reference")
        XCTAssertEqual(editor.payload.semanticSnapshot.objectElements[1].origin, .manual)
        XCTAssertEqual(editor.payload.semanticSnapshot.objectElements[1].provenance?.framework, "RoomScanStudio.manual")
    }

    func testRevisionEditorPoseAdjustmentPreservesNonYawCapturedBasis() throws {
        var payload = try makePayload()
        let pitchedRolled = RoomTransform4x4(columnMajorValues: [
            0.8, 0.3, -0.5, 0,
            -0.2, 0.9, 0.4, 0,
            0.55, -0.25, 0.79, 0,
            1, 2, 3, 1,
        ])
        payload.semanticSnapshot.objectElements[0].transform = pitchedRolled
        var editor = try RoomRevisionEditor(payload: payload)

        try editor.adjustPose(
            id: "object-001",
            translation: RoomPoint3D(x: 4, y: 5, z: 6),
            yawDeltaRadians: 0
        )

        let adjusted = try XCTUnwrap(editor.payload.semanticSnapshot.objectElements[0].transform)
        XCTAssertEqual(
            Array(adjusted.columnMajorValues.prefix(12)),
            Array(pitchedRolled.columnMajorValues.prefix(12))
        )
        XCTAssertEqual(Array(adjusted.columnMajorValues.suffix(4)), [4, 5, 6, 1])
    }

    func testRevisionEditorRejectsDanglingAttachmentsInvalidMeasurementAndStructuralLayerViolation() throws {
        let payload = try makePayload()
        var editor = try RoomRevisionEditor(payload: payload)

        XCTAssertThrowsError(
            try editor.addSpatialAnnotation(
                id: "note-001",
                text: "Dangling",
                createdAt: date,
                point: RoomPoint3D(x: 0, y: 0, z: 0),
                attachedElementID: "missing-element"
            )
        )
        XCTAssertThrowsError(
            try editor.addPointToPointMeasurement(
                id: "measure-001",
                label: "Bad",
                startPoint: RoomPoint3D(x: 0, y: 0, z: 0),
                endPoint: RoomPoint3D(x: .infinity, y: 0, z: 0)
            )
        )
        XCTAssertThrowsError(
            try editor.updateMobility(id: "floor-001", mobility: .movable)
        )
        XCTAssertThrowsError(
            try editor.updateCategory(id: "floor-001", kind: "chair")
        )
        XCTAssertThrowsError(
            try editor.updateCategory(id: "object-001", kind: "wall")
        )
        XCTAssertThrowsError(
            try editor.addManualObject(
                id: "manual-001",
                kind: "cabinet",
                label: "Missing pose",
                dimensions: RoomDimensions(width: 1, height: 1, depth: 1),
                transform: nil
            )
        )
    }

    private func makePayload() throws -> RoomRevisionPayload {
        RoomRevisionPayload(
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
                        transform: identityTransform(),
                        polygonCorners: [
                            RoomPoint3D(x: -2.5, y: 0, z: -2),
                            RoomPoint3D(x: 2.5, y: 0, z: -2),
                            RoomPoint3D(x: 2.5, y: 0, z: 2),
                        ],
                        mobility: .structural
                    )
                ],
                objectElements: [
                    RoomSemanticElement(
                        id: "object-001",
                        kind: "desk",
                        label: "Desk",
                        dimensionsMeters: RoomDimensions(width: 1.2, height: 0.75, depth: 0.6),
                        transform: identityTransform(),
                        mobility: .fixed
                    )
                ]
            ),
            annotations: [],
            measurements: [],
            photos: [
                RoomPhoto(
                    id: "photo-001",
                    createdAt: date,
                    assetRelativePath: try RoomRelativePath("photos/reference-001.jpg"),
                    caption: "Reference"
                )
            ]
        )
    }

    private func identityTransform(translationX: Double = 0) -> RoomTransform4x4 {
        RoomTransform4x4(columnMajorValues: [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            translationX, 0, 0, 1,
        ])
    }
}
