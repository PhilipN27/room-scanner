import XCTest
@testable import RoomScanCore

final class RoomMeshVisibilityTests: XCTestCase {
    func testHighAndMediumConfidenceUseDistinctRearTolerances() {
        XCTAssertFalse(RoomMeshVisibility.evaluate(
            sampleDepth: 2.041,
            lidarDepth: 2,
            confidence: 2,
            meshDepth: nil
        ).isVisible, "high limit is 2 + 0.02 + 1% = 2.04")
        XCTAssertTrue(RoomMeshVisibility.evaluate(
            sampleDepth: 2.041,
            lidarDepth: 2,
            confidence: 1,
            meshDepth: nil
        ).isVisible, "medium limit is 2 + 0.04 + 2% = 2.08")
        XCTAssertEqual(RoomMeshVisibility.evaluate(
            sampleDepth: 2,
            lidarDepth: 2,
            confidence: 2,
            meshDepth: nil
        ).qualityFactor, 1)
        XCTAssertEqual(RoomMeshVisibility.evaluate(
            sampleDepth: 2,
            lidarDepth: 2,
            confidence: 1,
            meshDepth: nil
        ).qualityFactor, 0.9)
    }

    func testLowConfidenceFallsBackToCorrectedMeshTolerance() {
        XCTAssertFalse(RoomMeshVisibility.evaluate(
            sampleDepth: 2.071,
            lidarDepth: 2,
            confidence: 0,
            meshDepth: 2
        ).isVisible, "mesh limit is 2 + 0.03 + 2% = 2.07")
        let visible = RoomMeshVisibility.evaluate(
            sampleDepth: 2.06,
            lidarDepth: 1,
            confidence: 0,
            meshDepth: 2
        )
        XCTAssertTrue(visible.isVisible, "low confidence must not hard-reject")
        XCTAssertEqual(visible.qualityFactor, 0.75)
    }

    func testDepthSamplingUsesOnlyFinitePositiveNeighborsAndMinimumConfidence() throws {
        let payload = try XCTUnwrap(RoomMeshDepthPayload(
            width: 2,
            height: 2,
            depthMeters: [1, .nan, 3, -1],
            confidence: [2, 2, 1, 2]
        ))
        let sample = try XCTUnwrap(payload.bilinearSample(x: 0.5, y: 0.5))
        XCTAssertEqual(sample.depth, 2, accuracy: 1e-6)
        XCTAssertEqual(sample.confidence, 1)
    }

    func testMalformedPayloadIsRejectedAndMeshBufferWidthIsBounded() {
        XCTAssertNil(RoomMeshDepthPayload(width: 2, height: 2, depthMeters: [1], confidence: nil))
        XCTAssertNil(RoomMeshDepthPayload(width: 2, height: 2, depthMeters: [1, 1, 1, 1], confidence: [2]))
        XCTAssertEqual(RoomMeshVisibility.meshBufferWidth(requested: 160, recordedDepthWidth: 256), 256)
        XCTAssertEqual(RoomMeshVisibility.meshBufferWidth(requested: 160, recordedDepthWidth: 1_024), 512)
        XCTAssertEqual(RoomMeshVisibility.meshBufferWidth(requested: 80, recordedDepthWidth: nil), 80)
    }
}
