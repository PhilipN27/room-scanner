import XCTest
@testable import RoomScanCore

final class RoomMeshColoredPreviewTests: XCTestCase {
    // MARK: - Binary PLY reader/writer

    func testBinaryPLYRoundTripWithNormalsAndColors() throws {
        let mesh = RoomMeshPLYMesh(
            vertices: [
                SIMD3<Float>(0, 0, 0),
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(0, 1, 0),
            ],
            normals: [
                SIMD3<Float>(0, 0, 1),
                SIMD3<Float>(0, 0, 1),
                SIMD3<Float>(0, 0, 1),
            ],
            colors: [
                SIMD3<UInt8>(255, 0, 0),
                SIMD3<UInt8>(0, 255, 0),
                SIMD3<UInt8>(0, 0, 255),
            ],
            faces: [0, 1, 2]
        )
        let decoded = try RoomMeshBinaryPLY.read(RoomMeshBinaryPLY.write(mesh))
        XCTAssertEqual(decoded, mesh)
    }

    func testReaderAcceptsCaptureRecorderLayout() throws {
        // The on-device recorder writes position + normal only, no colors,
        // with its own comment line. The reader must accept that layout.
        var header = "ply\n"
        header += "format binary_little_endian 1.0\n"
        header += "comment RoomScanStudio capture-bundle scene mesh\n"
        header += "element vertex 2\n"
        header += "property float x\nproperty float y\nproperty float z\n"
        header += "property float nx\nproperty float ny\nproperty float nz\n"
        header += "element face 0\n"
        header += "property list uchar uint vertex_indices\n"
        header += "end_header\n"
        var data = Data(header.utf8)
        let floats: [Float] = [1, 2, 3, 0, 1, 0, 4, 5, 6, 0, 0, 1]
        for value in floats {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }

        let mesh = try RoomMeshBinaryPLY.read(data)
        XCTAssertEqual(mesh.vertices, [SIMD3<Float>(1, 2, 3), SIMD3<Float>(4, 5, 6)])
        XCTAssertEqual(mesh.normals, [SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)])
        XCTAssertTrue(mesh.colors.isEmpty)
        XCTAssertTrue(mesh.faces.isEmpty)
    }

    func testReaderRejectsTruncatedBody() {
        let mesh = RoomMeshPLYMesh(
            vertices: [SIMD3<Float>(0, 0, 0)],
            normals: [SIMD3<Float>(0, 0, 1)],
            colors: [],
            faces: []
        )
        let full = RoomMeshBinaryPLY.write(mesh)
        let truncated = full.prefix(full.count - 2)
        XCTAssertThrowsError(try RoomMeshBinaryPLY.read(Data(truncated)))
    }

    func testReaderRejectsASCIIFormat() {
        let header = "ply\nformat ascii 1.0\nelement vertex 0\nend_header\n"
        XCTAssertThrowsError(try RoomMeshBinaryPLY.read(Data(header.utf8)))
    }

    // MARK: - Keyframe projection colorizer

    /// Camera at the origin looking down -Z (identity camera-to-world),
    /// pinhole fx = fy = 100, principal point at the sensor center.
    private func makeKeyframe(imageRGBA: [UInt8], imageWidth: Int, imageHeight: Int) -> RoomMeshKeyframeSample {
        RoomMeshKeyframeSample(
            cameraToWorldColumnMajor: [
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                0, 0, 0, 1,
            ],
            intrinsicsColumnMajor: [100, 0, 0, 0, 100, 0, 320, 240, 1],
            sensorWidth: 640,
            sensorHeight: 480,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            imageRGBA: imageRGBA
        )
    }

    private func solidImage(_ color: SIMD3<UInt8>, width: Int, height: Int) -> [UInt8] {
        var pixels: [UInt8] = []
        pixels.reserveCapacity(width * height * 4)
        for _ in 0..<(width * height) {
            pixels.append(contentsOf: [color.x, color.y, color.z, 255])
        }
        return pixels
    }

    func testFacingVertexTakesImageColor() {
        let keyframe = makeKeyframe(
            imageRGBA: solidImage(SIMD3<UInt8>(255, 0, 0), width: 4, height: 4),
            imageWidth: 4,
            imageHeight: 4
        )
        let result = RoomMeshKeyframeColorizer.colorize(
            vertices: [SIMD3<Float>(0.5, 0, -1)],
            normals: [SIMD3<Float>(0, 0, 1)],
            faces: [],
            keyframes: [keyframe]
        )
        XCTAssertEqual(result.coloredVertexCount, 1)
        XCTAssertEqual(result.colors[0], SIMD3<UInt8>(255, 0, 0))
    }

    /// A vertex above the camera axis must sample the UPPER half of the
    /// sensor-oriented image (image v runs downward from the top-left).
    func testProjectionVerticalOrientation() {
        let width = 4, height = 4
        var pixels: [UInt8] = []
        for y in 0..<height {
            for _ in 0..<width {
                // Top half red, bottom half blue.
                pixels.append(contentsOf: y < height / 2 ? [255, 0, 0, 255] : [0, 0, 255, 255])
            }
        }
        let keyframe = makeKeyframe(imageRGBA: pixels, imageWidth: width, imageHeight: height)
        let result = RoomMeshKeyframeColorizer.colorize(
            vertices: [SIMD3<Float>(0, 0.5, -1)],
            normals: [SIMD3<Float>(0, 0, 1)],
            faces: [],
            keyframes: [keyframe]
        )
        XCTAssertEqual(result.coloredVertexCount, 1)
        XCTAssertGreaterThan(result.colors[0].x, 200, "vertex above the axis should sample the top (red) rows")
        XCTAssertLessThan(result.colors[0].z, 60)
    }

    func testOccludedVertexStaysUncolored() {
        let keyframe = makeKeyframe(
            imageRGBA: solidImage(SIMD3<UInt8>(0, 255, 0), width: 4, height: 4),
            imageWidth: 4,
            imageHeight: 4
        )
        // A large triangle at z = -1 spans the image center; a vertex at
        // z = -2 projects behind it and must not receive the green color.
        let vertices = [
            SIMD3<Float>(-0.5, -0.5, -1),
            SIMD3<Float>(0.5, -0.5, -1),
            SIMD3<Float>(0, 0.5, -1),
            SIMD3<Float>(0, 0, -2),
        ]
        let normals = [
            SIMD3<Float>(0, 0, 1),
            SIMD3<Float>(0, 0, 1),
            SIMD3<Float>(0, 0, 1),
            SIMD3<Float>(0, 0, 1),
        ]
        let result = RoomMeshKeyframeColorizer.colorize(
            vertices: vertices,
            normals: normals,
            faces: [0, 1, 2],
            keyframes: [keyframe]
        )
        XCTAssertEqual(result.colors[0], SIMD3<UInt8>(0, 255, 0), "front triangle vertex is visible")
        XCTAssertEqual(
            result.colors[3],
            RoomMeshKeyframeColorizer.uncoloredGray,
            "vertex hidden behind the front triangle must stay uncolored"
        )
        XCTAssertEqual(result.coloredVertexCount, 3)
    }

    func testBackfacingVertexStaysUncolored() {
        let keyframe = makeKeyframe(
            imageRGBA: solidImage(SIMD3<UInt8>(255, 255, 255), width: 4, height: 4),
            imageWidth: 4,
            imageHeight: 4
        )
        let result = RoomMeshKeyframeColorizer.colorize(
            vertices: [SIMD3<Float>(0, 0, -1)],
            normals: [SIMD3<Float>(0, 0, -1)],
            faces: [],
            keyframes: [keyframe]
        )
        XCTAssertEqual(result.coloredVertexCount, 0)
        XCTAssertEqual(result.colors[0], RoomMeshKeyframeColorizer.uncoloredGray)
    }

    func testVertexBehindCameraStaysUncolored() {
        let keyframe = makeKeyframe(
            imageRGBA: solidImage(SIMD3<UInt8>(255, 255, 255), width: 4, height: 4),
            imageWidth: 4,
            imageHeight: 4
        )
        let result = RoomMeshKeyframeColorizer.colorize(
            vertices: [SIMD3<Float>(0, 0, 1)],
            normals: [SIMD3<Float>(0, 0, 1)],
            faces: [],
            keyframes: [keyframe]
        )
        XCTAssertEqual(result.coloredVertexCount, 0)
    }

    func testVertexOutsideImageStaysUncolored() {
        let keyframe = makeKeyframe(
            imageRGBA: solidImage(SIMD3<UInt8>(255, 255, 255), width: 4, height: 4),
            imageWidth: 4,
            imageHeight: 4
        )
        // u = 320 + 100 * (10 / 1) far exceeds the 640-pixel sensor width.
        let result = RoomMeshKeyframeColorizer.colorize(
            vertices: [SIMD3<Float>(10, 0, -1)],
            normals: [SIMD3<Float>(0, 0, 1)],
            faces: [],
            keyframes: [keyframe]
        )
        XCTAssertEqual(result.coloredVertexCount, 0)
    }

    func testMalformedKeyframeIsSkippedNotFatal() {
        let bad = RoomMeshKeyframeSample(
            cameraToWorldColumnMajor: [1, 0, 0],
            intrinsicsColumnMajor: [],
            sensorWidth: 0,
            sensorHeight: 0,
            imageWidth: 0,
            imageHeight: 0,
            imageRGBA: []
        )
        let result = RoomMeshKeyframeColorizer.colorize(
            vertices: [SIMD3<Float>(0, 0, -1)],
            normals: [SIMD3<Float>(0, 0, 1)],
            faces: [],
            keyframes: [bad]
        )
        XCTAssertEqual(result.coloredVertexCount, 0)
        XCTAssertEqual(result.colors.count, 1)
    }

    /// A posed (non-identity) camera: moved to x = +2, still looking down -Z.
    /// A vertex at (2, 0, -1) sits on its axis and must take the image color.
    func testTranslatedCameraProjectsThroughItsOwnAxis() {
        var keyframe = makeKeyframe(
            imageRGBA: solidImage(SIMD3<UInt8>(10, 200, 30), width: 4, height: 4),
            imageWidth: 4,
            imageHeight: 4
        )
        keyframe.cameraToWorldColumnMajor = [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            2, 0, 0, 1,
        ]
        let result = RoomMeshKeyframeColorizer.colorize(
            vertices: [SIMD3<Float>(2, 0, -1)],
            normals: [SIMD3<Float>(0, 0, 1)],
            faces: [],
            keyframes: [keyframe]
        )
        XCTAssertEqual(result.coloredVertexCount, 1)
        XCTAssertEqual(result.colors[0], SIMD3<UInt8>(10, 200, 30))
    }
}
