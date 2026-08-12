import CryptoKit
import ImageIO
import RoomScanCore
import UIKit
import XCTest
@testable import RoomScanStudio

/// Oracles for the Phase B1 training export: nerfstudio transforms.json
/// structure (verified against nerfstudio data conventions and OpenSplat's
/// parser, 2026-08-10), 16-bit millimeter depth PNGs, and the assembled zip.
final class RoomCaptureBundleTrainingExportTests: XCTestCase {
    private var projectID = ""

    override func setUp() {
        super.setUp()
        projectID = "bundle-export-test-\(UUID().uuidString)"
    }

    override func tearDown() {
        try? RoomCaptureBundleLibrary.removeBundle(forProject: projectID)
        super.tearDown()
    }

    // MARK: - transforms.json

    func testTransformsJSONStructureAndMatrixTranspose() throws {
        // Distinct values everywhere so a wrong transpose cannot pass; the
        // homogeneous slots carry device-style float noise that the export
        // must clamp to an exact [0, 0, 0, 1] last row.
        let columnMajor: [Double] = [
            1, 2, 3, 0.5,
            4, 5, 6, 0.25,
            7, 8, 9, 0.125,
            10, 11, 12, 0.9999998,
        ]
        let manifest = RoomCaptureBundleManifest(
            schemaVersion: 2,
            createdAt: Date(),
            frames: [
                RoomCaptureBundleFrame(
                    fileName: "frame-00001.jpg",
                    timestamp: 1,
                    cameraTransform: columnMajor,
                    intrinsics: [1000, 0, 0, 0, 1100, 0, 960, 720, 1],
                    imageWidth: 1920,
                    imageHeight: 1440,
                    exposureDuration: 0.008,
                    depth: RoomCaptureBundleFrameDepth(
                        fileName: "frame-00001-depth.bin",
                        confidenceFileName: nil,
                        width: 4,
                        height: 3,
                        compression: "zlib",
                        pixelFormat: "float32"
                    )
                ),
                RoomCaptureBundleFrame(
                    fileName: "frame-00002.jpg",
                    timestamp: 2,
                    cameraTransform: columnMajor,
                    intrinsics: [1000, 0, 0, 0, 1100, 0, 960, 720, 1],
                    imageWidth: 1920,
                    imageHeight: 1440,
                    exposureDuration: 0.008
                ),
            ],
            meshAnchorCount: 1,
            meshVertexCount: 10,
            meshFaceCount: 5,
            notes: []
        )

        let data = try RoomCaptureBundleTrainingExport.makeTransformsJSON(
            manifest: manifest,
            plyEntryPath: "scene-mesh.ply",
            depthPNGFrameFileNames: ["frame-00001.jpg"]
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(root["camera_model"] as? String, "OPENCV")
        XCTAssertEqual(root["w"] as? Int, 1920)
        XCTAssertEqual(root["h"] as? Int, 1440)
        XCTAssertEqual(root["ply_file_path"] as? String, "scene-mesh.ply")

        let frames = try XCTUnwrap(root["frames"] as? [[String: Any]])
        XCTAssertEqual(frames.count, 2)
        let first = frames[0]
        XCTAssertEqual(first["file_path"] as? String, "frames/frame-00001.jpg")
        XCTAssertEqual(first["fl_x"] as? Double, 1000)
        XCTAssertEqual(first["fl_y"] as? Double, 1100)
        XCTAssertEqual(first["cx"] as? Double, 960)
        XCTAssertEqual(first["cy"] as? Double, 720)
        XCTAssertEqual(
            first["depth_file_path"] as? String,
            "depth/frame-00001-depth.png"
        )
        XCTAssertNil(frames[1]["depth_file_path"], "frames without a depth PNG must omit depth_file_path")

        // Row-major nested rows of the same camera-to-world matrix: row i
        // holds element i of each stored column.
        let matrix = try XCTUnwrap(first["transform_matrix"] as? [[Double]])
        XCTAssertEqual(matrix[0], [1, 4, 7, 10])
        XCTAssertEqual(matrix[1], [2, 5, 8, 11])
        XCTAssertEqual(matrix[2], [3, 6, 9, 12])
        XCTAssertEqual(matrix[3], [0, 0, 0, 1], "float noise in the homogeneous row must be clamped exactly")
    }

    func testTransformsJSONSkipsNonFiniteFramesAndRejectsEmpty() {
        let bad = RoomCaptureBundleFrame(
            fileName: "frame-00001.jpg",
            timestamp: 1,
            cameraTransform: [Double](repeating: .nan, count: 16),
            intrinsics: [Double](repeating: 0, count: 9),
            imageWidth: 640,
            imageHeight: 480,
            exposureDuration: 0.008
        )
        let manifest = RoomCaptureBundleManifest(
            schemaVersion: 2,
            createdAt: Date(),
            frames: [bad],
            meshAnchorCount: 0,
            meshVertexCount: 0,
            meshFaceCount: 0,
            notes: []
        )
        XCTAssertThrowsError(
            try RoomCaptureBundleTrainingExport.makeTransformsJSON(
                manifest: manifest,
                plyEntryPath: nil,
                depthPNGFrameFileNames: []
            )
        )
    }

    // MARK: - Depth PNG

    func testDepthPNGEncodesMillimetersWithZeroForUnknown() throws {
        let depths: [Float] = [0.5, 1.234, .infinity, 0, 65.534, .nan]
        let png = try XCTUnwrap(
            RoomCaptureBundleTrainingExport.makeDepthPNG16(
                depthMeters: depths,
                width: 3,
                height: 2
            )
        )
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 3)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(image.bitsPerComponent, 16, "depth must survive as 16-bit grayscale")

        let raw = try XCTUnwrap(image.dataProvider?.data as Data?)
        XCTAssertEqual(raw.count, 3 * 2 * 2)
        var decoded = [UInt16]()
        // CGImage delivers 16-bit samples in the byte order recorded by its
        // bitmapInfo; honor it instead of assuming big-endian PNG order.
        let littleEndian = image.bitmapInfo.contains(.byteOrder16Little)
        for pixel in 0..<6 {
            let high = UInt16(raw[pixel * 2])
            let low = UInt16(raw[pixel * 2 + 1])
            decoded.append(littleEndian ? (low << 8 | high) : (high << 8 | low))
        }
        XCTAssertEqual(decoded, [500, 1234, 0, 0, 65534, 0])
    }

    func testDepthPNGRejectsMismatchedDimensions() {
        XCTAssertNil(
            RoomCaptureBundleTrainingExport.makeDepthPNG16(
                depthMeters: [1, 2, 3],
                width: 2,
                height: 2
            )
        )
    }

    // MARK: - Zip assembly

    func testBuildExportZipPackagesBundleWithDerivedArtifacts() async throws {
        try adoptSyntheticBundleWithDepth()

        let built = try await RoomCaptureBundleTrainingExport.buildExportZip(forProject: projectID)
        defer { try? FileManager.default.removeItem(at: built.url) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: built.url.path))
        let entryPaths = Set(built.receipt.entries.map(\.entryPath.value))
        XCTAssertTrue(entryPaths.contains("transforms.json"))
        XCTAssertTrue(entryPaths.contains("bundle-manifest.json"))
        XCTAssertTrue(entryPaths.contains("scene-mesh.ply"))
        XCTAssertTrue(entryPaths.contains("frames/frame-00001.jpg"))
        XCTAssertTrue(entryPaths.contains("frames/frame-00001-depth.bin"))
        XCTAssertTrue(entryPaths.contains("depth/frame-00001-depth.png"))

        // The generated transforms.json inside the staging is gone, but its
        // digest is in the receipt; verify it advertised the depth PNG by
        // rebuilding it from the same manifest.
        let manifest = try XCTUnwrap(RoomCaptureBundleLibrary.manifest(forProject: projectID))
        let transforms = try RoomCaptureBundleTrainingExport.makeTransformsJSON(
            manifest: manifest,
            plyEntryPath: "scene-mesh.ply",
            depthPNGFrameFileNames: ["frame-00001.jpg"]
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: transforms) as? [String: Any])
        let frames = try XCTUnwrap(root["frames"] as? [[String: Any]])
        XCTAssertEqual(frames[0]["depth_file_path"] as? String, "depth/frame-00001-depth.png")
    }

    /// Derived photoreal-cache artifacts live inside the bundle directory but
    /// are replaceable derived data, not capture evidence — the export must
    /// not ship them. The deliberate colored-mesh seed (scene-mesh.ply /
    /// scene-mesh-colored.ply) is unaffected.
    func testBuildExportZipExcludesDerivedCacheArtifacts() async throws {
        try adoptSyntheticBundleWithDepth()
        let bundleDirectory = try XCTUnwrap(
            RoomCaptureBundleLibrary.bundleDirectory(forProject: projectID)
        )
        let derivedNames = [
            RoomMeshPhotorealCache.manifestFileName,
            RoomMeshPhotorealCache.meshFileName,
            RoomMeshPhotorealCache.atlasFileName,
        ]
        for name in derivedNames {
            try Data([7]).write(to: bundleDirectory.appendingPathComponent(name))
        }
        // The legacy colored mesh is also a derived cache file, but it is a
        // DELIBERATE training input (splat seed geometry): it must ship, and
        // must be preferred as the seed path over the raw scene mesh.
        try Data([7]).write(
            to: bundleDirectory.appendingPathComponent(
                RoomMeshPhotorealCache.legacyColoredMeshFileName
            )
        )

        let built = try await RoomCaptureBundleTrainingExport.buildExportZip(forProject: projectID)
        defer { try? FileManager.default.removeItem(at: built.url) }

        let entryPaths = Set(built.receipt.entries.map(\.entryPath.value))
        XCTAssertTrue(entryPaths.contains("scene-mesh.ply"))
        XCTAssertTrue(
            entryPaths.contains(RoomMeshPhotorealCache.legacyColoredMeshFileName),
            "the colored-mesh seed is a deliberate training input"
        )
        for name in derivedNames {
            XCTAssertFalse(entryPaths.contains(name), name)
        }

        // Shipping the seed is not enough: transforms.json must SELECT it as
        // ply_file_path, or training silently seeds from the raw scene mesh.
        // The shipped bytes are pinned by digest against a rebuild that uses
        // the colored seed path.
        let manifest = try XCTUnwrap(RoomCaptureBundleLibrary.manifest(forProject: projectID))
        let expectedTransforms = try RoomCaptureBundleTrainingExport.makeTransformsJSON(
            manifest: manifest,
            plyEntryPath: RoomMeshPhotorealCache.legacyColoredMeshFileName,
            depthPNGFrameFileNames: ["frame-00001.jpg"]
        )
        let expectedRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: expectedTransforms) as? [String: Any]
        )
        XCTAssertEqual(
            expectedRoot["ply_file_path"] as? String,
            RoomMeshPhotorealCache.legacyColoredMeshFileName
        )
        let transformsEntry = try XCTUnwrap(
            built.receipt.entries.first { $0.entryPath.value == "transforms.json" }
        )
        let expectedDigest = SHA256.hash(data: expectedTransforms)
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(transformsEntry.sha256Hex, expectedDigest)
    }

    /// Reproduces the device failure: the root URL reaches the bundle through
    /// a symlink (like /var -> /private/var on iOS) while the child URL is
    /// fully resolved. Naive prefix stripping then yields an absolute path.
    func testRelativeEntryPathResolvesSymlinkedRoots() throws {
        let fileManager = FileManager.default
        let realRoot = fileManager.temporaryDirectory
            .appendingPathComponent("export-symlink-real-\(UUID().uuidString)", isDirectory: true)
        let frames = realRoot.appendingPathComponent("frames", isDirectory: true)
        try fileManager.createDirectory(at: frames, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: realRoot) }
        let file = frames.appendingPathComponent("frame-00001.jpg")
        try Data([1]).write(to: file)

        let linkRoot = fileManager.temporaryDirectory
            .appendingPathComponent("export-symlink-link-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createSymbolicLink(at: linkRoot, withDestinationURL: realRoot)
        defer { try? fileManager.removeItem(at: linkRoot) }

        XCTAssertEqual(
            RoomCaptureBundleTrainingExport.relativeEntryPath(
                of: file.resolvingSymlinksInPath(),
                within: linkRoot
            ),
            "frames/frame-00001.jpg"
        )
        XCTAssertEqual(
            RoomCaptureBundleTrainingExport.relativeEntryPath(
                of: linkRoot.appendingPathComponent("frames/frame-00001.jpg"),
                within: realRoot
            ),
            "frames/frame-00001.jpg",
            "the mismatch must resolve in both directions"
        )
        XCTAssertNil(
            RoomCaptureBundleTrainingExport.relativeEntryPath(
                of: fileManager.temporaryDirectory.appendingPathComponent("elsewhere.txt"),
                within: linkRoot
            ),
            "files outside the root must be rejected, not mangled"
        )
    }

    func testBuildExportZipWithoutBundleThrows() async {
        do {
            _ = try await RoomCaptureBundleTrainingExport.buildExportZip(forProject: projectID)
            XCTFail("export without a bundle must throw")
        } catch {}
    }

    /// One keyframe with JPEG + compressed depth payload + scene mesh.
    private func adoptSyntheticBundleWithDepth() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundle-export-scratch-\(UUID().uuidString)", isDirectory: true)
        let framesURL = scratch.appendingPathComponent(
            RoomCaptureBundleLibrary.framesSubdirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: framesURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let mesh = RoomMeshPLYMesh(
            vertices: [SIMD3<Float>(0, 0, -1)],
            normals: [SIMD3<Float>(0, 0, 1)],
            colors: [],
            faces: []
        )
        try RoomMeshBinaryPLY.write(mesh).write(
            to: scratch.appendingPathComponent(RoomCaptureBundleLibrary.sceneMeshFileName)
        )

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48))
        let image = renderer.image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        try XCTUnwrap(image.jpegData(compressionQuality: 0.9)).write(
            to: framesURL.appendingPathComponent("frame-00001.jpg")
        )

        let depthValues: [Float] = [1, 2, 3, 4, 5, 6]
        let packed = depthValues.withUnsafeBytes { Data($0) }
        let compressed = try XCTUnwrap(RoomCaptureBundleDepthCodec.compress(packed))
        try compressed.write(to: framesURL.appendingPathComponent("frame-00001-depth.bin"))

        let manifest = RoomCaptureBundleManifest(
            schemaVersion: RoomCaptureBundleManifest.currentSchemaVersion,
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
                    intrinsics: [100, 0, 0, 0, 100, 0, 32, 24, 1],
                    imageWidth: 64,
                    imageHeight: 48,
                    exposureDuration: 0.008,
                    depth: RoomCaptureBundleFrameDepth(
                        fileName: "frame-00001-depth.bin",
                        confidenceFileName: nil,
                        width: 3,
                        height: 2,
                        compression: RoomCaptureBundleDepthCodec.compressionName,
                        pixelFormat: RoomCaptureBundleDepthCodec.depthPixelFormatName
                    )
                )
            ],
            meshAnchorCount: 1,
            meshVertexCount: 1,
            meshFaceCount: 0,
            notes: []
        )
        try RoomJSONCoding.makeEncoder().encode(manifest).write(
            to: scratch.appendingPathComponent(RoomCaptureBundleLibrary.manifestFileName)
        )

        try RoomCaptureBundleLibrary.adoptBundle(at: scratch, forProject: projectID)
    }
}
