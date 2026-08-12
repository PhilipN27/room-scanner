import Foundation
import simd
import XCTest
@testable import RoomScanCore

final class RoomMeshHeroPlanTests: XCTestCase {
    private func makePhotorealManifest(
        atlasSize: Int = 2_048
    ) -> RoomMeshPhotorealCacheManifest {
        RoomMeshPhotorealCacheManifest(
            algorithmVersion: RoomMeshPhotorealCache.algorithmVersion,
            sourceMeshSHA256: "mesh-hash",
            bundleManifestSHA256: "bundle-hash",
            sourceFrames: [
                RoomMeshSourceFrameFingerprint(
                    fileName: "frame-000.jpg", byteSize: 1_024, modificationTime: 7
                ),
            ],
            atlasSize: atlasSize,
            coveredFaceCount: 12,
            coveredAreaEstimate: 3.5,
            colorSpaceTag: "sRGB",
            settings: RoomMeshPhotorealSettings()
        )
    }

    private func makeHeroManifest(
        heroVersion: Int = RoomMeshHeroCache.algorithmVersion,
        photorealManifest: RoomMeshPhotorealCacheManifest? = nil,
        coloredMeshSHA256: String = "colored-ply-hash",
        atlasSHA256: String? = "atlas-hash",
        width: Int = 800,
        height: Int = 600,
        colorSpaceTag: String = "sRGB"
    ) -> RoomMeshHeroCacheManifest {
        RoomMeshHeroCacheManifest(
            heroAlgorithmVersion: heroVersion,
            photorealManifest: photorealManifest ?? makePhotorealManifest(),
            coloredMeshSHA256: coloredMeshSHA256,
            atlasSHA256: atlasSHA256,
            pixelWidth: width,
            pixelHeight: height,
            colorSpaceTag: colorSpaceTag
        )
    }

    /// The hero is derived from the DERIVED colored mesh, so its identity must
    /// change whenever the upstream photoreal cache manifest or the rendered
    /// asset bytes change — not merely the original capture inputs.
    func testHeroCacheValidatesOnlyExactUpstreamMatchAndExistingImage() {
        func validate(
            _ candidate: RoomMeshHeroCacheManifest,
            imageExists: Bool = true
        ) -> Bool {
            RoomMeshHeroCache.isValid(
                candidate,
                photorealManifest: makePhotorealManifest(),
                coloredMeshSHA256: "colored-ply-hash",
                atlasSHA256: "atlas-hash",
                pixelWidth: 800,
                pixelHeight: 600,
                fileExists: { name in
                    imageExists && name == RoomMeshHeroCache.imageFileName
                }
            )
        }
        XCTAssertTrue(validate(makeHeroManifest()))
        XCTAssertFalse(validate(makeHeroManifest(), imageExists: false))
        XCTAssertFalse(validate(makeHeroManifest(heroVersion: 999)))
        XCTAssertFalse(validate(
            makeHeroManifest(photorealManifest: makePhotorealManifest(atlasSize: 1_024))
        ))
        XCTAssertFalse(validate(makeHeroManifest(coloredMeshSHA256: "other")))
        XCTAssertFalse(validate(makeHeroManifest(atlasSHA256: nil)))
        XCTAssertFalse(validate(makeHeroManifest(width: 1_600)))
        XCTAssertFalse(validate(makeHeroManifest(colorSpaceTag: "displayP3")))
    }

    /// Derived cache files must never ride along in capture-bundle or
    /// training exports: the bundle directory is enumerated verbatim today,
    /// so exports filter through this predicate.
    func testDerivedCacheFilePredicateSeparatesEvidenceFromDerivedData() {
        for name in [
            RoomMeshPhotorealCache.manifestFileName,
            RoomMeshPhotorealCache.meshFileName,
            RoomMeshPhotorealCache.atlasFileName,
            RoomMeshPhotorealCache.legacyColoredMeshFileName,
        ] {
            XCTAssertTrue(RoomMeshPhotorealCache.isDerivedCacheFile(name), name)
        }
        for name in [
            "manifest.json", "scene-mesh.ply", "frame-000.jpg", "depth-000.bin",
            "thumbnail.png",
        ] {
            XCTAssertFalse(RoomMeshPhotorealCache.isDerivedCacheFile(name), name)
        }
    }

    func testHeroFramingCentersTargetAndFitsBoundingSphere() {
        let framing = RoomMeshHeroFraming.make(
            boundsMin: SIMD3<Float>(-2, 0, -3),
            boundsMax: SIMD3<Float>(2, 2.4, 3),
            aspectRatio: 4.0 / 3.0
        )
        XCTAssertEqual(framing.target, SIMD3<Float>(0, 1.2, 0))
        // The camera must sit at least a bounding-sphere fit distance away in
        // the narrower (vertical) field of view, or geometry clips the frame.
        let radius = simd_length(SIMD3<Float>(2, 1.2, 3))
        let verticalFOV = RoomMeshHeroFraming.verticalFieldOfViewRadians
        let minimumDistance = radius / sin(verticalFOV / 2)
        let actualDistance = simd_length(framing.eye - framing.target)
        XCTAssertGreaterThanOrEqual(actualDistance, minimumDistance * 0.999)
        // Three-quarter view: elevated and rotated off both axes.
        XCTAssertGreaterThan(framing.eye.y, framing.target.y)
        XCTAssertNotEqual(framing.eye.x, framing.target.x)
        XCTAssertNotEqual(framing.eye.z, framing.target.z)
    }

    func testHeroFramingIsDeterministicAndHandlesDegenerateBounds() {
        let a = RoomMeshHeroFraming.make(
            boundsMin: SIMD3<Float>(-1, -1, -1),
            boundsMax: SIMD3<Float>(1, 1, 1),
            aspectRatio: 4.0 / 3.0
        )
        let b = RoomMeshHeroFraming.make(
            boundsMin: SIMD3<Float>(-1, -1, -1),
            boundsMax: SIMD3<Float>(1, 1, 1),
            aspectRatio: 4.0 / 3.0
        )
        XCTAssertEqual(a.eye, b.eye)
        XCTAssertEqual(a.target, b.target)

        // A zero-size mesh (single point) must still produce a finite,
        // non-degenerate camera rather than NaN or eye == target.
        let point = RoomMeshHeroFraming.make(
            boundsMin: SIMD3<Float>(1, 1, 1),
            boundsMax: SIMD3<Float>(1, 1, 1),
            aspectRatio: 4.0 / 3.0
        )
        XCTAssertTrue(point.eye.x.isFinite && point.eye.y.isFinite && point.eye.z.isFinite)
        XCTAssertGreaterThan(simd_length(point.eye - point.target), 0.1)
    }
}
