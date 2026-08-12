import Foundation

public struct RoomMeshPhotorealSettings: Codable, Equatable, Sendable {
    public var nearPlane: Double
    public var highDepthBias: Double
    public var highDepthScale: Double
    public var mediumDepthBias: Double
    public var mediumDepthScale: Double
    public var meshDepthBias: Double
    public var meshDepthScale: Double
    public var analysisMaxPixelSize: Int
    public var atlasMaxDimension: Int
    public var atlasPadding: Int
    public var coherencePasses: Int
    public var coherencePenalty: Double
    public var maximumFallbackCandidates: Int
    public var maximumCalibrationSamplesPerFrame: Int
    public var minimumCalibrationOverlap: Int
    public var coverageMaximumHops: Int
    public var coverageMaximumEdgeLength: Float
    public var coverageMaximumNormalAngleDegrees: Float
    public var coverageMaximumDepthDiscontinuity: Float

    public init(
        nearPlane: Double = RoomMeshProjection.defaultNearPlane,
        highDepthBias: Double = RoomMeshVisibility.highConfidenceBias,
        highDepthScale: Double = RoomMeshVisibility.highConfidenceScale,
        mediumDepthBias: Double = RoomMeshVisibility.mediumConfidenceBias,
        mediumDepthScale: Double = RoomMeshVisibility.mediumConfidenceScale,
        meshDepthBias: Double = RoomMeshVisibility.meshBias,
        meshDepthScale: Double = RoomMeshVisibility.meshScale,
        analysisMaxPixelSize: Int = 1_024,
        atlasMaxDimension: Int = RoomMeshTextureBaker.maximumAtlasDimension,
        atlasPadding: Int = RoomMeshTextureBaker.atlasPadding,
        coherencePasses: Int = RoomMeshTextureBaker.coherencePassCount,
        coherencePenalty: Double = RoomMeshTextureBaker.coherencePenaltyScale,
        maximumFallbackCandidates: Int = RoomMeshFrameAnalysis.maximumFallbackCandidates,
        maximumCalibrationSamplesPerFrame: Int = RoomMeshFrameAnalysis.maximumCalibrationSamplesPerFrame,
        minimumCalibrationOverlap: Int = RoomMeshFrameAnalysis.minimumCalibrationOverlap,
        coverageMaximumHops: Int = RoomMeshCoverageFiller.Settings().maximumHops,
        coverageMaximumEdgeLength: Float = RoomMeshCoverageFiller.Settings().maximumEdgeLength,
        coverageMaximumNormalAngleDegrees: Float = RoomMeshCoverageFiller.Settings().maximumNormalAngleDegrees,
        coverageMaximumDepthDiscontinuity: Float = RoomMeshCoverageFiller.Settings().maximumDepthDiscontinuity
    ) {
        self.nearPlane = nearPlane
        self.highDepthBias = highDepthBias
        self.highDepthScale = highDepthScale
        self.mediumDepthBias = mediumDepthBias
        self.mediumDepthScale = mediumDepthScale
        self.meshDepthBias = meshDepthBias
        self.meshDepthScale = meshDepthScale
        self.analysisMaxPixelSize = analysisMaxPixelSize
        self.atlasMaxDimension = atlasMaxDimension
        self.atlasPadding = atlasPadding
        self.coherencePasses = coherencePasses
        self.coherencePenalty = coherencePenalty
        self.maximumFallbackCandidates = maximumFallbackCandidates
        self.maximumCalibrationSamplesPerFrame = maximumCalibrationSamplesPerFrame
        self.minimumCalibrationOverlap = minimumCalibrationOverlap
        self.coverageMaximumHops = coverageMaximumHops
        self.coverageMaximumEdgeLength = coverageMaximumEdgeLength
        self.coverageMaximumNormalAngleDegrees = coverageMaximumNormalAngleDegrees
        self.coverageMaximumDepthDiscontinuity = coverageMaximumDepthDiscontinuity
    }
}

public struct RoomMeshSourceFrameFingerprint: Codable, Equatable, Sendable {
    public var fileName: String
    public var byteSize: Int64
    public var modificationTime: Double

    public init(fileName: String, byteSize: Int64, modificationTime: Double) {
        self.fileName = fileName
        self.byteSize = byteSize
        self.modificationTime = modificationTime
    }
}

public struct RoomMeshPhotorealCacheManifest: Codable, Equatable, Sendable {
    public var algorithmVersion: Int
    public var sourceMeshSHA256: String
    public var bundleManifestSHA256: String
    public var sourceFrames: [RoomMeshSourceFrameFingerprint]
    public var atlasSize: Int
    public var coveredFaceCount: Int
    public var coveredAreaEstimate: Double
    public var colorSpaceTag: String
    public var settings: RoomMeshPhotorealSettings

    public init(
        algorithmVersion: Int,
        sourceMeshSHA256: String,
        bundleManifestSHA256: String,
        sourceFrames: [RoomMeshSourceFrameFingerprint],
        atlasSize: Int,
        coveredFaceCount: Int,
        coveredAreaEstimate: Double,
        colorSpaceTag: String,
        settings: RoomMeshPhotorealSettings
    ) {
        self.algorithmVersion = algorithmVersion
        self.sourceMeshSHA256 = sourceMeshSHA256
        self.bundleManifestSHA256 = bundleManifestSHA256
        self.sourceFrames = sourceFrames
        self.atlasSize = atlasSize
        self.coveredFaceCount = coveredFaceCount
        self.coveredAreaEstimate = coveredAreaEstimate
        self.colorSpaceTag = colorSpaceTag
        self.settings = settings
    }
}

public enum RoomMeshPhotorealCache {
    public static let algorithmVersion = 3
    public static let manifestFileName = "scene-mesh-photoreal-v3.json"
    public static let meshFileName = "scene-mesh-photoreal-v3.ply"
    public static let atlasFileName = "scene-mesh-photoreal-v3-atlas.png"

    public static func isValid(
        _ manifest: RoomMeshPhotorealCacheManifest,
        sourceMeshSHA256: String,
        bundleManifestSHA256: String,
        sourceFrames: [RoomMeshSourceFrameFingerprint],
        settings: RoomMeshPhotorealSettings,
        fileExists: (String) -> Bool
    ) -> Bool {
        guard
            manifest.algorithmVersion == algorithmVersion,
            manifest.sourceMeshSHA256 == sourceMeshSHA256,
            manifest.bundleManifestSHA256 == bundleManifestSHA256,
            manifest.sourceFrames == sourceFrames,
            manifest.settings == settings,
            manifest.colorSpaceTag == "sRGB",
            fileExists(meshFileName)
        else { return false }
        return manifest.coveredFaceCount == 0 || fileExists(atlasFileName)
    }
}

public enum RoomMeshPhotorealPLY {
    public static func write(_ mesh: RoomMeshPhotorealMesh) -> Data {
        let hasNormals = mesh.normals.count == mesh.vertices.count
        var header = "ply\nformat binary_little_endian 1.0\n"
        header += "comment RoomScanStudio photoreal mesh v3\n"
        header += "element vertex \(mesh.vertices.count)\n"
        header += "property float x\nproperty float y\nproperty float z\n"
        if hasNormals {
            header += "property float nx\nproperty float ny\nproperty float nz\n"
        }
        header += "property uchar red\nproperty uchar green\nproperty uchar blue\n"
        header += "property float texture_u\nproperty float texture_v\n"
        header += "property uchar texture_valid\n"
        header += "element face \(mesh.faces.count / 3)\n"
        header += "property list uchar uint vertex_indices\nend_header\n"
        var data = Data(header.utf8)
        for index in mesh.vertices.indices {
            appendFloat(&data, mesh.vertices[index].x)
            appendFloat(&data, mesh.vertices[index].y)
            appendFloat(&data, mesh.vertices[index].z)
            if hasNormals {
                appendFloat(&data, mesh.normals[index].x)
                appendFloat(&data, mesh.normals[index].y)
                appendFloat(&data, mesh.normals[index].z)
            }
            let color = index < mesh.fallbackColors.count
                ? mesh.fallbackColors[index] : RoomMeshKeyframeColorizer.uncoloredGray
            data.append(contentsOf: [color.x, color.y, color.z])
            let uv = index < mesh.uvs.count ? mesh.uvs[index] : .zero
            appendFloat(&data, uv.x)
            appendFloat(&data, uv.y)
            data.append(index < mesh.textureValid.count ? min(mesh.textureValid[index], 1) : 0)
        }
        for face in stride(from: 0, to: mesh.faces.count - mesh.faces.count % 3, by: 3) {
            data.append(3)
            appendUInt32(&data, mesh.faces[face])
            appendUInt32(&data, mesh.faces[face + 1])
            appendUInt32(&data, mesh.faces[face + 2])
        }
        return data
    }

    public static func read(_ data: Data) throws -> RoomMeshPhotorealMesh {
        guard let range = data.range(of: Data("end_header\n".utf8)),
              let header = String(data: data[..<range.upperBound], encoding: .ascii) else {
            throw RoomMeshPLYError.malformedHeader
        }
        let lines = header.split(separator: "\n").map(String.init)
        guard lines.contains("format binary_little_endian 1.0") else {
            throw RoomMeshPLYError.unsupportedFormat("photoreal PLY must be binary little endian")
        }
        func elementCount(_ name: String) -> Int? {
            lines.first { $0.hasPrefix("element \(name) ") }
                .flatMap { Int($0.split(separator: " ").last ?? "") }
        }
        guard let vertexCount = elementCount("vertex"), let faceCount = elementCount("face") else {
            throw RoomMeshPLYError.malformedHeader
        }
        let hasNormals = lines.contains("property float nx")
        let bytes = [UInt8](data)
        var cursor = range.upperBound
        func take(_ count: Int) throws -> Int {
            let start = cursor
            guard count >= 0, start <= bytes.count, count <= bytes.count - start else {
                throw RoomMeshPLYError.truncatedBody
            }
            cursor += count
            return start
        }
        func float(_ offset: Int) -> Float {
            var bits: UInt32 = 0
            for byte in 0..<4 { bits |= UInt32(bytes[offset + byte]) << (byte * 8) }
            return Float(bitPattern: bits)
        }
        func uint32(_ offset: Int) -> UInt32 {
            var value: UInt32 = 0
            for byte in 0..<4 { value |= UInt32(bytes[offset + byte]) << (byte * 8) }
            return value
        }
        var mesh = RoomMeshPhotorealMesh(
            vertices: [], normals: [], fallbackColors: [], uvs: [], textureValid: [], faces: []
        )
        for _ in 0..<vertexCount {
            let position = try take(12)
            mesh.vertices.append(SIMD3<Float>(float(position), float(position + 4), float(position + 8)))
            if hasNormals {
                let normal = try take(12)
                mesh.normals.append(SIMD3<Float>(float(normal), float(normal + 4), float(normal + 8)))
            }
            let color = try take(3)
            mesh.fallbackColors.append(SIMD3<UInt8>(bytes[color], bytes[color + 1], bytes[color + 2]))
            let uv = try take(8)
            mesh.uvs.append(SIMD2<Float>(float(uv), float(uv + 4)))
            let valid = try take(1)
            mesh.textureValid.append(min(bytes[valid], 1))
        }
        for _ in 0..<faceCount {
            let count = try take(1)
            guard bytes[count] == 3 else {
                throw RoomMeshPLYError.unsupportedFormat("photoreal PLY requires triangles")
            }
            for _ in 0..<3 { mesh.faces.append(uint32(try take(4))) }
        }
        return mesh
    }

    private static func appendFloat(_ data: inout Data, _ value: Float) {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
