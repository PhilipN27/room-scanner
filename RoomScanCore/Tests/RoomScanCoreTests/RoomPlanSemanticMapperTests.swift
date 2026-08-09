import Foundation
import XCTest
@testable import RoomScanCore

final class RoomPlanSemanticMapperTests: XCTestCase {
    func testMapperPreservesSurfaceProvenanceAndAllowsZeroOutOfPlaneExtent() throws {
        let attempt = RoomCaptureAttemptToken("capture-mapper-001")
        let surface = RoomPlanSemanticSurfaceDescriptor(
            sourceIdentifier: "surface-wall-001",
            parentSourceIdentifier: "surface-floor-001",
            kind: "wall",
            label: "North wall",
            dimensionsMeters: RoomDimensions(width: 4.2, height: 2.7, depth: 0),
            transform: identityTransform,
            polygonCorners: [
                RoomPoint3D(x: -2.1, y: 0, z: 0),
                RoomPoint3D(x: 2.1, y: 0, z: 0),
                RoomPoint3D(x: 2.1, y: 2.7, z: 0),
            ],
            flattenedAttributeShortIdentifiers: ["fire-rated", "glass", "glass"],
            classificationConfidence: .high
        )

        let snapshot = try RoomPlanSemanticMapper.makeSnapshot(
            projectID: "pending-project",
            revisionID: "pending-revision",
            attempt: attempt,
            coordinateSpaceEpochID: "epoch-001",
            surfaces: [surface],
            objects: []
        )

        XCTAssertEqual(snapshot.structuralElements.count, 1)
        XCTAssertTrue(snapshot.objectElements.isEmpty)
        XCTAssertEqual(snapshot.accuracyDisclaimer, RoomCaptureState.nonSurveyAccuracyDisclaimer)
        XCTAssertFalse(snapshot.accuracyDisclaimer.contains("accuracy: "))

        let element = try XCTUnwrap(snapshot.structuralElements.first)
        XCTAssertEqual(element.kind, "wall")
        XCTAssertEqual(element.label, "North wall")
        XCTAssertEqual(element.dimensionsMeters.depth, 0)
        XCTAssertEqual(element.transform, identityTransform)
        XCTAssertEqual(element.polygonCorners, surface.polygonCorners)
        XCTAssertEqual(element.mobility, .structural)
        XCTAssertEqual(element.origin, .roomPlan)
        XCTAssertEqual(element.provenance?.framework, "RoomPlan")
        XCTAssertEqual(element.provenance?.sourceIdentifier, "surface-wall-001")
        XCTAssertEqual(element.provenance?.parentSourceIdentifier, "surface-floor-001")
        XCTAssertEqual(element.provenance?.classificationConfidence, .high)
        XCTAssertEqual(element.provenance?.flattenedAttributeIdentifiers, ["fire-rated", "glass"])
        XCTAssertEqual(element.provenance?.captureAttemptID, attempt.value)
        XCTAssertEqual(element.provenance?.coordinateSpaceEpochID, "epoch-001")
    }

    func testMapperKeepsObjectsSeparateAndMapsConservativeMobility() throws {
        let objects = [
            makeObject(sourceID: "object-fixed", mobility: .fixed),
            makeObject(sourceID: "object-movable", mobility: .movable),
            makeObject(sourceID: "object-unknown", mobility: .unknown),
        ]

        let snapshot = try RoomPlanSemanticMapper.makeSnapshot(
            projectID: "pending-project",
            revisionID: "pending-revision",
            attempt: RoomCaptureAttemptToken("capture-mapper-002"),
            coordinateSpaceEpochID: "epoch-002",
            surfaces: [],
            objects: objects
        )

        XCTAssertTrue(snapshot.structuralElements.isEmpty)
        XCTAssertEqual(snapshot.objectElements.map(\.mobility), [.fixed, .movable, .unknown])
        XCTAssertTrue(snapshot.objectElements.allSatisfy { $0.origin == .roomPlan })
        XCTAssertTrue(snapshot.objectElements.allSatisfy { $0.provenance?.framework == "RoomPlan" })
    }

    func testMapperUsesStableAppOwnedIDsForTheSameSourceWithinOneAttempt() throws {
        let attempt = RoomCaptureAttemptToken("capture-mapper-003")
        let surface = RoomPlanSemanticSurfaceDescriptor(
            sourceIdentifier: "surface-stable-001",
            parentSourceIdentifier: nil,
            kind: "floor",
            label: "Floor",
            dimensionsMeters: RoomDimensions(width: 4, height: 0, depth: 5),
            transform: identityTransform,
            polygonCorners: [],
            flattenedAttributeShortIdentifiers: [],
            classificationConfidence: .medium
        )

        let first = try RoomPlanSemanticMapper.makeSnapshot(
            projectID: "pending-project",
            revisionID: "pending-revision",
            attempt: attempt,
            coordinateSpaceEpochID: "epoch-003",
            surfaces: [surface],
            objects: []
        )
        let second = try RoomPlanSemanticMapper.makeSnapshot(
            projectID: "pending-project",
            revisionID: "pending-revision",
            attempt: attempt,
            coordinateSpaceEpochID: "epoch-003",
            surfaces: [surface],
            objects: []
        )

        XCTAssertEqual(first.structuralElements.first?.id, second.structuralElements.first?.id)
        XCTAssertNotEqual(first.structuralElements.first?.id, surface.sourceIdentifier)
        XCTAssertTrue(first.structuralElements.first?.id.hasPrefix("roomplan-surface-") == true)
    }

    func testMapperRejectsNonFiniteOrDegenerateGeometry() {
        let invalidSurface = RoomPlanSemanticSurfaceDescriptor(
            sourceIdentifier: "invalid-surface",
            parentSourceIdentifier: nil,
            kind: "wall",
            label: "Invalid wall",
            dimensionsMeters: RoomDimensions(width: .infinity, height: 2.4, depth: 0),
            transform: identityTransform,
            polygonCorners: [],
            flattenedAttributeShortIdentifiers: [],
            classificationConfidence: .unknown
        )
        let degenerateObject = RoomPlanSemanticObjectDescriptor(
            sourceIdentifier: "invalid-object",
            parentSourceIdentifier: nil,
            kind: "table",
            label: "Invalid table",
            dimensionsMeters: RoomDimensions(width: 1, height: 0, depth: 1),
            transform: identityTransform,
            polygonCorners: [],
            flattenedAttributeShortIdentifiers: [],
            classificationConfidence: .low,
            mobility: .movable
        )

        XCTAssertThrowsError(
            try RoomPlanSemanticMapper.makeSnapshot(
                projectID: "pending-project",
                revisionID: "pending-revision",
                attempt: RoomCaptureAttemptToken("capture-mapper-004"),
                coordinateSpaceEpochID: "epoch-004",
                surfaces: [invalidSurface],
                objects: []
            )
        )
        XCTAssertThrowsError(
            try RoomPlanSemanticMapper.makeSnapshot(
                projectID: "pending-project",
                revisionID: "pending-revision",
                attempt: RoomCaptureAttemptToken("capture-mapper-004"),
                coordinateSpaceEpochID: "epoch-004",
                surfaces: [],
                objects: [degenerateObject]
            )
        )
    }

    private func makeObject(
        sourceID: String,
        mobility: RoomPlanSemanticObjectMobility
    ) -> RoomPlanSemanticObjectDescriptor {
        RoomPlanSemanticObjectDescriptor(
            sourceIdentifier: sourceID,
            parentSourceIdentifier: "surface-floor-001",
            kind: "table",
            label: "Table",
            dimensionsMeters: RoomDimensions(width: 1.2, height: 0.75, depth: 0.8),
            transform: identityTransform,
            polygonCorners: [],
            flattenedAttributeShortIdentifiers: ["round"],
            classificationConfidence: .medium,
            mobility: mobility
        )
    }

    private var identityTransform: RoomTransform4x4 {
        RoomTransform4x4(columnMajorValues: [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        ])
    }
}
