import Foundation
import simd

/// Identity of a cached hero snapshot. The hero renders the DERIVED colored
/// mesh, so it embeds the entire upstream photoreal cache manifest and the
/// hashes of the rendered asset bytes: any upstream recolor, setting change,
/// or asset rewrite invalidates the hero even when the original capture
/// inputs are untouched.
public struct RoomMeshHeroCacheManifest: Codable, Equatable, Sendable {
    public var heroAlgorithmVersion: Int
    public var photorealManifest: RoomMeshPhotorealCacheManifest
    public var coloredMeshSHA256: String
    public var atlasSHA256: String?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var colorSpaceTag: String

    public init(
        heroAlgorithmVersion: Int,
        photorealManifest: RoomMeshPhotorealCacheManifest,
        coloredMeshSHA256: String,
        atlasSHA256: String?,
        pixelWidth: Int,
        pixelHeight: Int,
        colorSpaceTag: String
    ) {
        self.heroAlgorithmVersion = heroAlgorithmVersion
        self.photorealManifest = photorealManifest
        self.coloredMeshSHA256 = coloredMeshSHA256
        self.atlasSHA256 = atlasSHA256
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.colorSpaceTag = colorSpaceTag
    }
}

/// The hero cache is replaceable derived data. It lives in the package-root
/// `derived/` directory — outside the capture bundle — so bundle and training
/// exports, which enumerate the bundle directory verbatim, can never mistake
/// it for capture evidence.
public enum RoomMeshHeroCache {
    public static let algorithmVersion = 1
    public static let directoryName = "derived"
    public static let manifestFileName = "room-hero-v1.json"
    public static let imageFileName = "room-hero-v1.png"

    public static func isValid(
        _ manifest: RoomMeshHeroCacheManifest,
        photorealManifest: RoomMeshPhotorealCacheManifest,
        coloredMeshSHA256: String,
        atlasSHA256: String?,
        pixelWidth: Int,
        pixelHeight: Int,
        fileExists: (String) -> Bool
    ) -> Bool {
        manifest.heroAlgorithmVersion == algorithmVersion
            && manifest.photorealManifest == photorealManifest
            && manifest.coloredMeshSHA256 == coloredMeshSHA256
            && manifest.atlasSHA256 == atlasSHA256
            && manifest.pixelWidth == pixelWidth
            && manifest.pixelHeight == pixelHeight
            && manifest.colorSpaceTag == "sRGB"
            && fileExists(imageFileName)
    }
}

extension RoomMeshPhotorealCache {
    /// The legacy per-vertex colored mesh predating the v3 photoreal cache.
    /// Derived data like the rest — but the training export re-adds it
    /// EXPLICITLY as splat seed geometry, a deliberate training input, never
    /// via blanket directory enumeration.
    public static let legacyColoredMeshFileName = "scene-mesh-colored.ply"

    /// True for files that are derived, replaceable cache artifacts rather
    /// than capture evidence. Exports that enumerate the capture-bundle
    /// directory filter through this so derived data never ships as if it
    /// were recorded truth. Prefix-based so future cache versions stay
    /// covered without revisiting every export site.
    public static func isDerivedCacheFile(_ fileName: String) -> Bool {
        fileName.hasPrefix("scene-mesh-photoreal-")
            || fileName == legacyColoredMeshFileName
    }
}

/// A hero cache read result: manifest plus image bytes, never filesystem
/// URLs — the store owns all package paths.
public struct RoomMeshHeroCachePayload: Sendable, Equatable {
    public let manifest: RoomMeshHeroCacheManifest
    public let imageData: Data

    public init(manifest: RoomMeshHeroCacheManifest, imageData: Data) {
        self.manifest = manifest
        self.imageData = imageData
    }
}

/// Deterministic three-quarter hero framing computed purely from mesh bounds:
/// same mesh, same camera, same image — a cache key can rely on it.
public struct RoomMeshHeroFraming: Equatable, Sendable {
    public static let verticalFieldOfViewRadians = Float.pi / 4
    public static let azimuthRadians = Float.pi / 4
    public static let elevationRadians = Float(35.0 / 180.0) * .pi
    /// Keeps a degenerate (point or empty) mesh from collapsing the camera
    /// onto its target.
    public static let minimumRadiusMeters: Float = 0.5

    public let eye: SIMD3<Float>
    public let target: SIMD3<Float>

    public static func make(
        boundsMin: SIMD3<Float>,
        boundsMax: SIMD3<Float>,
        aspectRatio: Float
    ) -> RoomMeshHeroFraming {
        let center = (boundsMin + boundsMax) * 0.5
        let radius = max(simd_length(boundsMax - center), minimumRadiusMeters)
        let verticalFOV = verticalFieldOfViewRadians
        let horizontalFOV = 2 * atan(tan(verticalFOV / 2) * max(aspectRatio, 0.1))
        let limitingFOV = min(verticalFOV, horizontalFOV)
        let distance = radius / sin(limitingFOV / 2) * 1.05
        let eye = center + distance * SIMD3<Float>(
            cos(elevationRadians) * sin(azimuthRadians),
            sin(elevationRadians),
            cos(elevationRadians) * cos(azimuthRadians)
        )
        return RoomMeshHeroFraming(eye: eye, target: center)
    }
}
