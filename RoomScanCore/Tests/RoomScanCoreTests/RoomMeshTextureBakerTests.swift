import XCTest
@testable import RoomScanCore

final class RoomMeshTextureBakerTests: XCTestCase {
    func testFaceCandidateRequiresThreeVerticesAndCentroidVisibility() {
        XCTAssertNotNil(RoomMeshTextureBaker.faceCandidate(
            frameIndex: 2,
            vertexVisibility: [true, true, true],
            centroidVisible: true,
            score: 4
        ))
        XCTAssertNil(RoomMeshTextureBaker.faceCandidate(
            frameIndex: 2,
            vertexVisibility: [true, false, true],
            centroidVisible: true,
            score: 4
        ))
        XCTAssertNil(RoomMeshTextureBaker.faceCandidate(
            frameIndex: 2,
            vertexVisibility: [true, true, true],
            centroidVisible: false,
            score: 4
        ))
    }

    func testCoherentAssignmentRunsThreeDeterministicPassesAndBreaksTiesByFrame() {
        let scores = [
            [RoomMeshFaceCandidate(frameIndex: 0, score: 10), RoomMeshFaceCandidate(frameIndex: 1, score: 9.9)],
            [RoomMeshFaceCandidate(frameIndex: 0, score: 9.9), RoomMeshFaceCandidate(frameIndex: 1, score: 10)],
        ]
        let assignments = RoomMeshTextureBaker.assignFrames(
            candidatesByFace: scores,
            faceNeighbors: [[1], [0]]
        )
        XCTAssertEqual(assignments, [0, 0], "coherence penalty should avoid an unnecessary seam")
        XCTAssertEqual(
            RoomMeshTextureBaker.assignFrames(
                candidatesByFace: [[
                    RoomMeshFaceCandidate(frameIndex: 1, score: 2),
                    RoomMeshFaceCandidate(frameIndex: 0, score: 2),
                ]],
                faceNeighbors: [[]]
            ),
            [0],
            "ties resolve by frame order"
        )
    }

    func testSeamExpansionMakesTriangleValidityUniformAndPreservesOrder() {
        let mesh = RoomMeshPLYMesh(
            vertices: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(1, 1, 0)],
            normals: Array(repeating: SIMD3<Float>(0, 0, 1), count: 4),
            colors: Array(repeating: SIMD3<UInt8>(128, 128, 128), count: 4),
            faces: [0, 1, 2, 1, 3, 2]
        )
        let expanded = RoomMeshTextureBaker.expandSeams(
            mesh: mesh,
            faceUVs: [
                [SIMD2<Float>(0, 0), SIMD2<Float>(1, 0), SIMD2<Float>(0, 1)],
                nil,
            ]
        )
        XCTAssertEqual(expanded.faces.count, mesh.faces.count)
        XCTAssertEqual(Array(expanded.textureValid.prefix(3)), [1, 1, 1])
        XCTAssertEqual(Array(expanded.textureValid.suffix(3)), [0, 0, 0])
        XCTAssertEqual(Array(expanded.uvs.suffix(3)), Array(repeating: .zero, count: 3))
        XCTAssertEqual(expanded.faces, [0, 1, 2, 3, 4, 5])
    }

    func testSkylinePackingIsDeterministicAndIncludesEightPixelPadding() {
        let charts = [
            RoomMeshChartRequest(id: 2, width: 16, height: 8, frameIndex: 1, firstFaceIndex: 4),
            RoomMeshChartRequest(id: 1, width: 8, height: 8, frameIndex: 0, firstFaceIndex: 0),
        ]
        let first = RoomMeshTextureBaker.pack(charts: charts, atlasSize: 64, padding: 8)
        let second = RoomMeshTextureBaker.pack(charts: charts.reversed(), atlasSize: 64, padding: 8)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 2)
        XCTAssertTrue(first.allSatisfy { $0.x >= 8 && $0.y >= 8 })
    }

    func testChartConstructionGroupsConnectedFacesAndSplitsOppositeWinding() {
        let faces = [
            RoomMeshProjectedFace(
                faceIndex: 0, frameIndex: 1, vertexIndices: [0, 1, 2],
                pixels: [.init(0, 0), .init(1, 0), .init(0, 1)]
            ),
            RoomMeshProjectedFace(
                faceIndex: 1, frameIndex: 1, vertexIndices: [1, 3, 2],
                pixels: [.init(1, 0), .init(1, 1), .init(0, 1)]
            ),
            RoomMeshProjectedFace(
                faceIndex: 2, frameIndex: 1, vertexIndices: [1, 2, 4],
                pixels: [.init(1, 0), .init(0, 1), .init(1, 1)]
            ),
        ]
        let charts = RoomMeshTextureBaker.constructCharts(projectedFaces: faces)
        XCTAssertEqual(charts.map(\.faceIndices), [[0, 1], [2]])
        XCTAssertEqual(charts.map(\.id), [0, 2])
    }

    func testChartConstructionFinishesForRoomSizedDisconnectedMesh() {
        let faceCount = 6_000
        let faces = (0..<faceCount).map { faceIndex in
            let vertex = UInt32(faceIndex * 3)
            return RoomMeshProjectedFace(
                faceIndex: faceIndex,
                frameIndex: faceIndex % 8,
                vertexIndices: [vertex, vertex + 1, vertex + 2],
                pixels: [.init(0, 0), .init(1, 0), .init(0, 1)]
            )
        }

        let started = ContinuousClock.now
        let charts = RoomMeshTextureBaker.constructCharts(projectedFaces: faces)
        let elapsed = started.duration(to: .now)

        XCTAssertEqual(charts.count, faceCount)
        XCTAssertLessThan(
            elapsed,
            .seconds(2),
            "chart construction must be edge-indexed rather than comparing every face pair"
        )
    }

    func testGlobalScalePackingBinarySearchesGreatestDeterministicFit() throws {
        let charts = [
            RoomMeshChartRequest(id: 0, width: 80, height: 80, frameIndex: 0, firstFaceIndex: 0),
            RoomMeshChartRequest(id: 1, width: 80, height: 80, frameIndex: 0, firstFaceIndex: 1),
        ]
        let first = try XCTUnwrap(RoomMeshTextureBaker.packAtGreatestScale(
            charts: charts, atlasSize: 128, padding: 8
        ))
        let second = try XCTUnwrap(RoomMeshTextureBaker.packAtGreatestScale(
            charts: charts, atlasSize: 128, padding: 8
        ))
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.placements.count, 2)
        XCTAssertLessThan(first.scale, 1)
        XCTAssertGreaterThan(first.scale, 0.61)
        XCTAssertLessThanOrEqual(first.scale, 0.613)
    }

    func testChartAwareDilationDoesNotCrossChartOwnership() {
        var pixels = [SIMD3<Double>](repeating: .zero, count: 5)
        pixels[1] = SIMD3<Double>(1, 0, 0)
        pixels[3] = SIMD3<Double>(0, 0, 1)
        var owners = [-1, 0, -1, 1, -1]
        RoomMeshTextureBaker.dilate(
            linearPixels: &pixels,
            owners: &owners,
            width: 5,
            height: 1,
            iterations: 1
        )
        XCTAssertEqual(pixels[0], SIMD3<Double>(1, 0, 0))
        XCTAssertEqual(pixels[4], SIMD3<Double>(0, 0, 1))
        XCTAssertNotEqual(owners[2], -1)
        XCTAssertNotEqual(pixels[2], SIMD3<Double>(0.5, 0, 0.5), "dilation copies one chart; it never blends charts")
    }

    func testCompactDilationCopiesLinearPixelsWithoutFullAtlasSnapshots() {
        var pixels: [UInt16] = [
            0, 0, 0,
            65_535, 0, 0,
            0, 0, 0,
            0, 0, 65_535,
            0, 0, 0,
        ]
        var owners: [Int32] = [-1, 0, -1, 1, -1]

        RoomMeshTextureBaker.dilateLinearUInt16(
            pixels: &pixels,
            owners: &owners,
            width: 5,
            height: 1,
            iterations: 1
        )

        XCTAssertEqual(Array(pixels[0..<3]), [65_535, 0, 0])
        XCTAssertEqual(Array(pixels[12..<15]), [0, 0, 65_535])
        XCTAssertEqual(owners, [0, 0, 0, 1, 1])
        XCTAssertEqual(Array(pixels[6..<9]), [65_535, 0, 0], "lower chart owner wins deterministic ties")
    }

    func testCompactDilationReportsMeasuredWorkAndCanCancel() {
        var pixels = [UInt16](repeating: 0, count: 7 * 3)
        pixels[3 * 3] = 65_535
        var owners = [Int32](repeating: -1, count: 7)
        owners[3] = 0
        var completed: [Int] = []
        var totals: [Int] = []

        let finished = RoomMeshTextureBaker.dilateLinearUInt16(
            pixels: &pixels,
            owners: &owners,
            width: 7,
            height: 1,
            iterations: 2,
            onProgress: { done, total in
                completed.append(done)
                totals.append(total)
            },
            isCancelled: { false }
        )

        XCTAssertTrue(finished)
        XCTAssertEqual(completed, [1, 2, 3])
        XCTAssertEqual(totals, [3, 3, 3])

        var cancelledPixels = [UInt16](repeating: 0, count: 9)
        var cancelledOwners: [Int32] = [0, -1, -1]
        let originalOwners = cancelledOwners
        XCTAssertFalse(RoomMeshTextureBaker.dilateLinearUInt16(
            pixels: &cancelledPixels,
            owners: &cancelledOwners,
            width: 3,
            height: 1,
            iterations: 2,
            onProgress: nil,
            isCancelled: { true }
        ))
        XCTAssertEqual(cancelledOwners, originalOwners)
    }
}
