import RoomScanCore
import UIKit
import XCTest
@testable import RoomScanStudio

/// End-to-end colored-mesh loading against a synthetic capture bundle: real
/// manifest JSON, real JPEG decode, real projection colorization, real color
/// cache. This is the simulator-side oracle for the colored mesh viewer; only
/// Metal drawing itself needs the physical-device gate.
@MainActor
final class RoomMeshViewerAppTests: XCTestCase {
    private var projectID = ""

    override func setUp() {
        super.setUp()
        projectID = "mesh-viewer-test-\(UUID().uuidString)"
    }

    override func tearDown() {
        try? RoomCaptureBundleLibrary.removeBundle(forProject: projectID)
        super.tearDown()
    }

    func testLoadColorsMeshFromSyntheticBundleAndCachesResult() throws {
        try adoptSyntheticBundle(imageColor: UIColor(red: 1, green: 0, blue: 0, alpha: 1))

        XCTAssertTrue(RoomMeshBundleLoader.hasRenderableMesh(forProject: projectID))

        let first = try RoomMeshBundleLoader.load(forProject: projectID)
        XCTAssertFalse(first.usedCachedColors)
        XCTAssertEqual(first.mesh.vertices.count, 4)
        XCTAssertEqual(first.keyframeCount, 1)
        XCTAssertEqual(first.mesh.colors.count, 4)
        for color in first.mesh.colors {
            XCTAssertGreaterThan(color.x, 200, "keyframe-facing vertices must take the red image color")
            XCTAssertLessThan(color.y, 60)
            XCTAssertLessThan(color.z, 60)
        }
        XCTAssertEqual(first.boundsMin.z, -1)
        XCTAssertEqual(first.boundsMax.z, -1)

        let second = try RoomMeshBundleLoader.load(forProject: projectID)
        XCTAssertTrue(second.usedCachedColors, "second open must reuse the cached colored mesh")
        XCTAssertEqual(second.mesh.colors, first.mesh.colors)
    }

    func testLoadWithoutBundleThrowsBundleMissing() {
        XCTAssertFalse(RoomMeshBundleLoader.hasRenderableMesh(forProject: projectID))
        XCTAssertThrowsError(try RoomMeshBundleLoader.load(forProject: projectID))
    }

    /// A quad at z = -1 facing a camera at the origin that looks down -Z,
    /// photographed by one solid-color 640x480 keyframe.
    private func adoptSyntheticBundle(imageColor: UIColor) throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mesh-viewer-scratch-\(UUID().uuidString)", isDirectory: true)
        let framesURL = scratch.appendingPathComponent(
            RoomCaptureBundleLibrary.framesSubdirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: framesURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let mesh = RoomMeshPLYMesh(
            vertices: [
                SIMD3<Float>(-0.5, -0.5, -1),
                SIMD3<Float>(0.5, -0.5, -1),
                SIMD3<Float>(0.5, 0.5, -1),
                SIMD3<Float>(-0.5, 0.5, -1),
            ],
            normals: [
                SIMD3<Float>(0, 0, 1),
                SIMD3<Float>(0, 0, 1),
                SIMD3<Float>(0, 0, 1),
                SIMD3<Float>(0, 0, 1),
            ],
            colors: [],
            faces: [0, 1, 2, 0, 2, 3]
        )
        try RoomMeshBinaryPLY.write(mesh).write(
            to: scratch.appendingPathComponent(RoomCaptureBundleLibrary.sceneMeshFileName)
        )

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 480))
        let image = renderer.image { context in
            imageColor.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        }
        guard let jpeg = image.jpegData(compressionQuality: 0.9) else {
            XCTFail("synthetic keyframe JPEG could not be encoded")
            return
        }
        try jpeg.write(to: framesURL.appendingPathComponent("frame-00001.jpg"))

        let manifest = RoomCaptureBundleManifest(
            schemaVersion: 1,
            createdAt: Date(),
            frames: [
                RoomCaptureBundleFrame(
                    fileName: "frame-00001.jpg",
                    timestamp: 1,
                    cameraTransform: [
                        1, 0, 0, 0,
                        0, 1, 0, 0,
                        0, 0, 1, 0,
                        0, 0, 0, 1,
                    ],
                    intrinsics: [100, 0, 0, 0, 100, 0, 320, 240, 1],
                    imageWidth: 640,
                    imageHeight: 480,
                    exposureDuration: 0.008
                )
            ],
            meshAnchorCount: 1,
            meshVertexCount: 4,
            meshFaceCount: 2,
            notes: []
        )
        try RoomJSONCoding.makeEncoder().encode(manifest).write(
            to: scratch.appendingPathComponent(RoomCaptureBundleLibrary.manifestFileName)
        )

        try RoomCaptureBundleLibrary.adoptBundle(at: scratch, forProject: projectID)
    }
}
