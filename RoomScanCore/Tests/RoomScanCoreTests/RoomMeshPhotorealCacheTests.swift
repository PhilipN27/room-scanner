import XCTest
@testable import RoomScanCore

final class RoomMeshPhotorealCacheTests: XCTestCase {
    func testPhotorealPLYRoundTripsUVAndMaterialValidity() throws {
        let mesh = RoomMeshPhotorealMesh(
            vertices: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0)],
            normals: Array(repeating: SIMD3<Float>(0, 0, 1), count: 3),
            fallbackColors: [SIMD3<UInt8>(1, 2, 3), SIMD3<UInt8>(4, 5, 6), SIMD3<UInt8>(7, 8, 9)],
            uvs: [SIMD2<Float>(0, 0), SIMD2<Float>(1, 0), SIMD2<Float>(0, 1)],
            textureValid: [1, 1, 1],
            faces: [0, 1, 2]
        )
        XCTAssertEqual(try RoomMeshPhotorealPLY.read(RoomMeshPhotorealPLY.write(mesh)), mesh)
        let header = String(decoding: RoomMeshPhotorealPLY.write(mesh).prefix(600), as: UTF8.self)
        XCTAssertTrue(header.contains("property float texture_u"))
        XCTAssertTrue(header.contains("property uchar texture_valid"))
    }

    func testCacheValidationCoversVersionSourcesFramesSettingsAndAssets() {
        let settings = RoomMeshPhotorealSettings()
        let frame = RoomMeshSourceFrameFingerprint(
            fileName: "frame.jpg",
            byteSize: 10,
            modificationTime: 20
        )
        let manifest = RoomMeshPhotorealCacheManifest(
            algorithmVersion: 3,
            sourceMeshSHA256: "mesh",
            bundleManifestSHA256: "bundle",
            sourceFrames: [frame],
            atlasSize: 64,
            coveredFaceCount: 1,
            coveredAreaEstimate: 0.5,
            colorSpaceTag: "sRGB",
            settings: settings
        )
        let existing: Set<String> = [
            RoomMeshPhotorealCache.meshFileName,
            RoomMeshPhotorealCache.atlasFileName,
        ]
        XCTAssertTrue(RoomMeshPhotorealCache.isValid(
            manifest,
            sourceMeshSHA256: "mesh",
            bundleManifestSHA256: "bundle",
            sourceFrames: [frame],
            settings: settings,
            fileExists: existing.contains
        ))
        XCTAssertFalse(RoomMeshPhotorealCache.isValid(
            manifest,
            sourceMeshSHA256: "changed",
            bundleManifestSHA256: "bundle",
            sourceFrames: [frame],
            settings: settings,
            fileExists: existing.contains
        ))
        var changedSettings = settings
        changedSettings.nearPlane = 0.1
        XCTAssertFalse(RoomMeshPhotorealCache.isValid(
            manifest,
            sourceMeshSHA256: "mesh",
            bundleManifestSHA256: "bundle",
            sourceFrames: [frame],
            settings: changedSettings,
            fileExists: existing.contains
        ))
        XCTAssertFalse(RoomMeshPhotorealCache.isValid(
            manifest,
            sourceMeshSHA256: "mesh",
            bundleManifestSHA256: "bundle",
            sourceFrames: [frame],
            settings: settings,
            fileExists: { $0 != RoomMeshPhotorealCache.atlasFileName }
        ))
    }
}
