import XCTest
@testable import RoomScanCore

final class RoomMeshCoverageFillTests: XCTestCase {
    func testFillsOnlyAcrossShortCoplanarMeshPaths() throws {
        let positions: [SIMD3<Float>] = [
            .init(0, 0, 0), .init(0.05, 0, 0), .init(0.10, 0, 0), .init(0.05, 0.05, 0),
        ]
        let normals = [SIMD3<Float>](repeating: .init(0, 0, 1), count: 4)
        let source = SIMD3<Double>(0.2, 0.4, 0.6)
        let result = RoomMeshCoverageFiller.fill(
            positions: positions,
            normals: normals,
            faces: [0, 1, 3, 1, 2, 3],
            colors: [source, nil, nil, nil]
        )

        XCTAssertEqual(try XCTUnwrap(result[1].linearRGB), source)
        XCTAssertEqual(try XCTUnwrap(result[2].linearRGB), source)
        XCTAssertTrue(result[0].isCalibrationEvidence)
        XCTAssertFalse(result[1].isCalibrationEvidence)
        XCTAssertLessThan(result[2].confidence, result[1].confidence)
    }

    func testStopsAtSharpNormalLongEdgeAndDepthDiscontinuity() {
        let source = SIMD3<Double>(0.8, 0.2, 0.1)
        let result = RoomMeshCoverageFiller.fill(
            positions: [
                .init(0, 0, 0), .init(0.05, 0, 0),
                .init(0.10, 0, 0), .init(0.60, 0, 0),
                .init(0.05, 0, 0.10),
            ],
            normals: [
                .init(0, 0, 1), .init(0, 0, 1),
                .init(0, 1, 0), .init(0, 0, 1),
                .init(0, 0, 1),
            ],
            faces: [0, 1, 2, 1, 3, 2, 0, 4, 1],
            colors: [source, nil, nil, nil, nil]
        )

        XCTAssertNotNil(result[1].linearRGB)
        XCTAssertNil(result[2].linearRGB, "sharp normal must stop propagation")
        XCTAssertNil(result[3].linearRGB, "long edge must stop propagation")
        XCTAssertNil(result[4].linearRGB, "depth discontinuity must stop propagation")
    }
}
