import XCTest
@testable import RoomScanCore

final class RoomMeshProjectionTests: XCTestCase {
    func testPixelCenterResizeMapsCentersAndBorders() {
        XCTAssertEqual(
            RoomMeshProjection.resizedPixelCenter(0, sourceSize: 4, destinationSize: 2),
            -0.25,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            RoomMeshProjection.resizedPixelCenter(3, sourceSize: 4, destinationSize: 2),
            1.25,
            accuracy: 1e-12
        )
        XCTAssertEqual(
            RoomMeshProjection.resizedPixelCenter(1.5, sourceSize: 4, destinationSize: 8),
            3.5,
            accuracy: 1e-12
        )
    }

    func testTranslatedAndRotatedCameraProjectionUsesRigidInverseAndVerticalConvention() throws {
        let translated = try XCTUnwrap(RoomMeshProjection.Camera(
            cameraToWorldColumnMajor: [
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                2, 0, 0, 1,
            ],
            intrinsicsColumnMajor: [100, 0, 0, 0, 100, 0, 320, 240, 1],
            sensorWidth: 640,
            sensorHeight: 480
        ))
        let translatedPoint = try XCTUnwrap(translated.project(world: SIMD3<Double>(2, 0.5, -1)))
        XCTAssertEqual(translatedPoint.pixel.x, 320, accuracy: 1e-12)
        XCTAssertEqual(translatedPoint.pixel.y, 190, accuracy: 1e-12)
        XCTAssertEqual(translatedPoint.forward, 1, accuracy: 1e-12)

        // Camera local -Z points along world -X (a +90 degree yaw about Y).
        let rotated = try XCTUnwrap(RoomMeshProjection.Camera(
            cameraToWorldColumnMajor: [
                0, 0, -1, 0,
                0, 1, 0, 0,
                1, 0, 0, 0,
                0, 0, 0, 1,
            ],
            intrinsicsColumnMajor: [100, 0, 0, 0, 100, 0, 320, 240, 1],
            sensorWidth: 640,
            sensorHeight: 480
        ))
        let rotatedPoint = try XCTUnwrap(rotated.project(world: SIMD3<Double>(-2, 0, 0)))
        XCTAssertEqual(rotatedPoint.pixel.x, 320, accuracy: 1e-12)
        XCTAssertEqual(rotatedPoint.pixel.y, 240, accuracy: 1e-12)
        XCTAssertEqual(rotatedPoint.forward, 2, accuracy: 1e-12)
    }

    func testNearPlaneClippingRetainsCrossingTriangle() {
        let clipped = RoomMeshProjection.clipTriangleToNearPlane(
            [
                SIMD3<Double>(0, 0, -0.01),
                SIMD3<Double>(-0.2, -0.2, -1),
                SIMD3<Double>(0.2, -0.2, -1),
            ],
            nearPlane: 0.05
        )
        XCTAssertEqual(clipped.count, 4)
        XCTAssertTrue(clipped.allSatisfy { -$0.z >= 0.05 - 1e-12 })
    }

    func testReciprocalDepthRejectsAffineDepthForSlantedTriangle() {
        let barycentric = SIMD3<Double>(0.5, 0.25, 0.25)
        let depth = RoomMeshProjection.perspectiveDepth(
            barycentric: barycentric,
            vertexDepths: SIMD3<Double>(1, 4, 4)
        )
        XCTAssertEqual(depth, 1.6, accuracy: 1e-12)
        XCTAssertLessThan(depth, 2.5, "a vertex at 2.5m is hidden by the slanted surface")
        XCTAssertNotEqual(depth, 2.5, "affine screen-space depth would be incorrect")
    }
}
