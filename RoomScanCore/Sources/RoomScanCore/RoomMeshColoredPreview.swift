import Foundation

/// Colored scene-mesh preview support for the photoreal roadmap
/// (docs/PHOTOREAL_ROADMAP.md, Phase A slice 2 / sequencing step 3): a binary
/// PLY reader/writer for the capture bundle's scene mesh, and a pure
/// projection colorizer that paints mesh vertices from posed keyframe images.
/// Everything here is platform-independent and unit-tested off-device; JPEG
/// decoding and rendering stay in the app target.

// MARK: - Binary PLY mesh

public struct RoomMeshPLYMesh: Equatable, Sendable {
    public var vertices: [SIMD3<Float>]
    /// Empty when the file carries no normals; otherwise one per vertex.
    public var normals: [SIMD3<Float>]
    /// Empty when the file carries no colors; otherwise one per vertex.
    public var colors: [SIMD3<UInt8>]
    /// Triangle index triples.
    public var faces: [UInt32]

    public init(
        vertices: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        colors: [SIMD3<UInt8>],
        faces: [UInt32]
    ) {
        self.vertices = vertices
        self.normals = normals
        self.colors = colors
        self.faces = faces
    }
}

public enum RoomMeshPLYError: Error, Equatable {
    case malformedHeader
    case unsupportedFormat(String)
    case truncatedBody
}

/// Little-endian binary PLY, the exact family the on-device recorder writes:
/// float x/y/z, optional float nx/ny/nz, optional uchar red/green/blue
/// vertices and `list uchar uint` triangle faces. Unknown scalar properties
/// are skipped by size; anything else is rejected as unsupported.
public enum RoomMeshBinaryPLY {
    public static func write(_ mesh: RoomMeshPLYMesh) -> Data {
        let hasNormals = !mesh.normals.isEmpty
        let hasColors = !mesh.colors.isEmpty
        var header = "ply\n"
        header += "format binary_little_endian 1.0\n"
        header += "comment RoomScanStudio colored scene mesh\n"
        header += "element vertex \(mesh.vertices.count)\n"
        header += "property float x\nproperty float y\nproperty float z\n"
        if hasNormals {
            header += "property float nx\nproperty float ny\nproperty float nz\n"
        }
        if hasColors {
            header += "property uchar red\nproperty uchar green\nproperty uchar blue\n"
        }
        header += "element face \(mesh.faces.count / 3)\n"
        header += "property list uchar uint vertex_indices\n"
        header += "end_header\n"

        var data = Data(header.utf8)
        let vertexStride = 12 + (hasNormals ? 12 : 0) + (hasColors ? 3 : 0)
        data.reserveCapacity(data.count + mesh.vertices.count * vertexStride + (mesh.faces.count / 3) * 13)
        for index in mesh.vertices.indices {
            appendFloat(&data, mesh.vertices[index].x)
            appendFloat(&data, mesh.vertices[index].y)
            appendFloat(&data, mesh.vertices[index].z)
            if hasNormals {
                appendFloat(&data, mesh.normals[index].x)
                appendFloat(&data, mesh.normals[index].y)
                appendFloat(&data, mesh.normals[index].z)
            }
            if hasColors {
                data.append(mesh.colors[index].x)
                data.append(mesh.colors[index].y)
                data.append(mesh.colors[index].z)
            }
        }
        var faceIndex = 0
        while faceIndex + 2 < mesh.faces.count {
            data.append(3)
            appendUInt32(&data, mesh.faces[faceIndex])
            appendUInt32(&data, mesh.faces[faceIndex + 1])
            appendUInt32(&data, mesh.faces[faceIndex + 2])
            faceIndex += 3
        }
        return data
    }

    public static func read(_ data: Data) throws -> RoomMeshPLYMesh {
        guard let headerRange = data.range(of: Data("end_header\n".utf8)) else {
            throw RoomMeshPLYError.malformedHeader
        }
        guard let headerText = String(data: data.subdata(in: 0..<headerRange.lowerBound), encoding: .ascii) else {
            throw RoomMeshPLYError.malformedHeader
        }
        let lines = headerText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "ply" else { throw RoomMeshPLYError.malformedHeader }
        guard lines.contains("format binary_little_endian 1.0") else {
            throw RoomMeshPLYError.unsupportedFormat("only binary_little_endian 1.0 is supported")
        }

        struct VertexProperty {
            var name: String
            var byteSize: Int
            var isFloat: Bool
        }
        var vertexCount = 0
        var faceCount = 0
        var vertexProperties: [VertexProperty] = []
        var currentElement = ""
        var sawFaceListProperty = false

        for line in lines.dropFirst() {
            let parts = line.split(separator: " ").map(String.init)
            guard !parts.isEmpty else { continue }
            switch parts[0] {
            case "comment", "obj_info", "format":
                continue
            case "element":
                guard parts.count == 3, let count = Int(parts[2]), count >= 0 else {
                    throw RoomMeshPLYError.malformedHeader
                }
                currentElement = parts[1]
                if currentElement == "vertex" {
                    vertexCount = count
                } else if currentElement == "face" {
                    faceCount = count
                } else if count > 0 {
                    throw RoomMeshPLYError.unsupportedFormat("unsupported element \(currentElement)")
                }
            case "property":
                if currentElement == "vertex" {
                    guard parts.count == 3 else { throw RoomMeshPLYError.malformedHeader }
                    guard let size = scalarByteSize(parts[1]) else {
                        throw RoomMeshPLYError.unsupportedFormat("vertex property type \(parts[1])")
                    }
                    vertexProperties.append(
                        VertexProperty(name: parts[2], byteSize: size, isFloat: parts[1] == "float" || parts[1] == "float32")
                    )
                } else if currentElement == "face" {
                    guard
                        parts.count == 5,
                        parts[1] == "list",
                        parts[2] == "uchar" || parts[2] == "uint8",
                        parts[3] == "uint" || parts[3] == "uint32" || parts[3] == "int" || parts[3] == "int32"
                    else {
                        throw RoomMeshPLYError.unsupportedFormat("face property \(line)")
                    }
                    sawFaceListProperty = true
                }
            default:
                continue
            }
        }
        guard faceCount == 0 || sawFaceListProperty else { throw RoomMeshPLYError.malformedHeader }

        var cursor = headerRange.upperBound
        let bytes = [UInt8](data)

        func take(_ count: Int) throws -> Int {
            let start = cursor
            guard start + count <= bytes.count else { throw RoomMeshPLYError.truncatedBody }
            cursor += count
            return start
        }
        func readFloat(at offset: Int) -> Float {
            var bits: UInt32 = 0
            for byte in 0..<4 {
                bits |= UInt32(bytes[offset + byte]) << (8 * byte)
            }
            return Float(bitPattern: bits)
        }
        func readUInt32(at offset: Int) -> UInt32 {
            var value: UInt32 = 0
            for byte in 0..<4 {
                value |= UInt32(bytes[offset + byte]) << (8 * byte)
            }
            return value
        }

        var mesh = RoomMeshPLYMesh(vertices: [], normals: [], colors: [], faces: [])
        mesh.vertices.reserveCapacity(vertexCount)
        let propertyNames = Set(vertexProperties.map(\.name))
        let hasNormals = propertyNames.isSuperset(of: ["nx", "ny", "nz"])
        let hasColors = propertyNames.isSuperset(of: ["red", "green", "blue"])
        guard propertyNames.isSuperset(of: ["x", "y", "z"]) else {
            throw RoomMeshPLYError.unsupportedFormat("vertices without x/y/z positions")
        }

        for _ in 0..<vertexCount {
            var position = SIMD3<Float>()
            var normal = SIMD3<Float>()
            var color = SIMD3<UInt8>()
            for property in vertexProperties {
                let offset = try take(property.byteSize)
                switch property.name {
                case "x", "y", "z", "nx", "ny", "nz":
                    guard property.isFloat else {
                        throw RoomMeshPLYError.unsupportedFormat("non-float \(property.name)")
                    }
                    let value = readFloat(at: offset)
                    switch property.name {
                    case "x": position.x = value
                    case "y": position.y = value
                    case "z": position.z = value
                    case "nx": normal.x = value
                    case "ny": normal.y = value
                    default: normal.z = value
                    }
                case "red", "green", "blue":
                    guard property.byteSize == 1 else {
                        throw RoomMeshPLYError.unsupportedFormat("non-uchar \(property.name)")
                    }
                    let value = bytes[offset]
                    switch property.name {
                    case "red": color.x = value
                    case "green": color.y = value
                    default: color.z = value
                    }
                default:
                    continue
                }
            }
            mesh.vertices.append(position)
            if hasNormals { mesh.normals.append(normal) }
            if hasColors { mesh.colors.append(color) }
        }

        mesh.faces.reserveCapacity(faceCount * 3)
        for _ in 0..<faceCount {
            let countOffset = try take(1)
            let indexCount = Int(bytes[countOffset])
            guard indexCount == 3 else {
                throw RoomMeshPLYError.unsupportedFormat("non-triangle face with \(indexCount) indices")
            }
            for _ in 0..<3 {
                let offset = try take(4)
                mesh.faces.append(readUInt32(at: offset))
            }
        }
        return mesh
    }

    private static func scalarByteSize(_ type: String) -> Int? {
        switch type {
        case "char", "uchar", "int8", "uint8": return 1
        case "short", "ushort", "int16", "uint16": return 2
        case "int", "uint", "int32", "uint32", "float", "float32": return 4
        case "double", "float64": return 8
        default: return nil
        }
    }

    private static func appendFloat(_ data: inout Data, _ value: Float) {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}

// MARK: - Keyframe projection colorizer

/// One posed keyframe ready for color sampling. Transforms and intrinsics use
/// the capture-bundle manifest convention: ARKit camera-to-world (column-major
/// 16, camera x right / y up / -z forward) and sensor-pixel intrinsics
/// (column-major 9) for an image in raw sensor orientation. `imageRGBA` is a
/// downsampled copy of that image; sampling scales sensor coordinates into it.
public struct RoomMeshKeyframeSample: Sendable {
    public var cameraToWorldColumnMajor: [Double]
    public var intrinsicsColumnMajor: [Double]
    public var sensorWidth: Int
    public var sensorHeight: Int
    public var imageWidth: Int
    public var imageHeight: Int
    public var imageRGBA: [UInt8]
    public var depthWidth: Int
    public var depthHeight: Int
    public var depthMeters: [Float]
    public var confidence: [UInt8]
    public var normalizedSharpness: Double
    /// Per-channel natural-log gain, applied in linear sRGB.
    public var photometricLogGain: SIMD3<Double>
    public var isPhotometricallyConnected: Bool

    public init(
        cameraToWorldColumnMajor: [Double],
        intrinsicsColumnMajor: [Double],
        sensorWidth: Int,
        sensorHeight: Int,
        imageWidth: Int,
        imageHeight: Int,
        imageRGBA: [UInt8],
        depthWidth: Int = 0,
        depthHeight: Int = 0,
        depthMeters: [Float] = [],
        confidence: [UInt8] = [],
        normalizedSharpness: Double = 1,
        photometricLogGain: SIMD3<Double> = .zero,
        isPhotometricallyConnected: Bool = true
    ) {
        self.cameraToWorldColumnMajor = cameraToWorldColumnMajor
        self.intrinsicsColumnMajor = intrinsicsColumnMajor
        self.sensorWidth = sensorWidth
        self.sensorHeight = sensorHeight
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.imageRGBA = imageRGBA
        self.depthWidth = depthWidth
        self.depthHeight = depthHeight
        self.depthMeters = depthMeters
        self.confidence = confidence
        self.normalizedSharpness = normalizedSharpness
        self.photometricLogGain = photometricLogGain
        self.isPhotometricallyConnected = isPhotometricallyConnected
    }
}

public enum RoomMeshKeyframeColorizer {
    public struct Result: Sendable {
        public var colors: [SIMD3<UInt8>]
        public var coloredVertices: [Bool]
        public var linearColors: [SIMD3<Double>?]
        public var selectedScores: [Double]
        /// Vertices that received at least one keyframe sample.
        public var coloredVertexCount: Int
    }

    /// Vertices no keyframe could see keep this neutral gray.
    public static let uncoloredGray = SIMD3<UInt8>(128, 128, 128)

    private static let nearPlane = 0.05

    public static func colorize(
        vertices: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        faces: [UInt32],
        keyframes: [RoomMeshKeyframeSample],
        depthBufferWidth: Int = 160
    ) -> Result {
        var candidates = [[RoomMeshColorCandidate]](repeating: [], count: vertices.count)
        let hasNormals = normals.count == vertices.count

        for (frameIndex, keyframe) in keyframes.enumerated() {
            guard
                keyframe.imageWidth > 0,
                keyframe.imageHeight > 0,
                keyframe.imageRGBA.count == keyframe.imageWidth * keyframe.imageHeight * 4,
                let camera = RoomMeshProjection.Camera(
                    cameraToWorldColumnMajor: keyframe.cameraToWorldColumnMajor,
                    intrinsicsColumnMajor: keyframe.intrinsicsColumnMajor,
                    sensorWidth: keyframe.sensorWidth,
                    sensorHeight: keyframe.sensorHeight
                )
            else {
                continue
            }
            let depthPayload = RoomMeshDepthPayload(
                width: keyframe.depthWidth,
                height: keyframe.depthHeight,
                depthMeters: keyframe.depthMeters,
                confidence: keyframe.confidence.isEmpty ? nil : keyframe.confidence
            )

            // Pass 1: project every vertex into raw sensor pixel-center coordinates.
            var projected = [SIMD3<Double>](repeating: .init(), count: vertices.count)
            var cameraPoints = [SIMD3<Double>](repeating: .init(), count: vertices.count)
            var valid = [Bool](repeating: false, count: vertices.count)
            for index in vertices.indices {
                let world = SIMD3<Double>(
                    Double(vertices[index].x), Double(vertices[index].y), Double(vertices[index].z)
                )
                guard let cameraPoint = camera.cameraPoint(world: world) else { continue }
                cameraPoints[index] = cameraPoint
                guard let point = camera.project(camera: cameraPoint, nearPlane: nearPlane) else { continue }
                projected[index] = SIMD3<Double>(point.pixel.x, point.pixel.y, point.forward)
                valid[index] = camera.containsSensorPixel(point.pixel)
            }

            // Pass 2: clip at the near plane, then rasterize reciprocal depth.
            let bufferWidth = RoomMeshVisibility.meshBufferWidth(
                requested: depthBufferWidth,
                recordedDepthWidth: depthPayload?.width
            )
            let bufferHeight = max(
                Int((Double(bufferWidth) * Double(keyframe.sensorHeight) / Double(keyframe.sensorWidth)).rounded()),
                8
            )
            var depthBuffer = [Double](repeating: .infinity, count: bufferWidth * bufferHeight)
            var faceIndex = 0
            while faceIndex + 2 < faces.count {
                defer { faceIndex += 3 }
                let i0 = Int(faces[faceIndex])
                let i1 = Int(faces[faceIndex + 1])
                let i2 = Int(faces[faceIndex + 2])
                guard
                    i0 < vertices.count, i1 < vertices.count, i2 < vertices.count
                else { continue }
                let polygon = RoomMeshProjection.clipTriangleToNearPlane(
                    [cameraPoints[i0], cameraPoints[i1], cameraPoints[i2]],
                    nearPlane: nearPlane
                )
                guard polygon.count >= 3 else { continue }
                for triangleIndex in 1..<(polygon.count - 1) {
                    let triangle = [polygon[0], polygon[triangleIndex], polygon[triangleIndex + 1]]
                    let rasterPoints = triangle.compactMap { cameraPoint -> RoomMeshProjection.ProjectedPoint? in
                        guard let sensor = camera.project(camera: cameraPoint, nearPlane: nearPlane) else { return nil }
                        return RoomMeshProjection.ProjectedPoint(
                            pixel: SIMD2<Double>(
                                RoomMeshProjection.resizedPixelCenter(
                                    sensor.pixel.x,
                                    sourceSize: keyframe.sensorWidth,
                                    destinationSize: bufferWidth
                                ),
                                RoomMeshProjection.resizedPixelCenter(
                                    sensor.pixel.y,
                                    sourceSize: keyframe.sensorHeight,
                                    destinationSize: bufferHeight
                                )
                            ),
                            forward: sensor.forward
                        )
                    }
                    guard rasterPoints.count == 3 else { continue }
                    RoomMeshProjection.rasterizeDepthTriangle(
                        rasterPoints[0], rasterPoints[1], rasterPoints[2],
                        into: &depthBuffer,
                        width: bufferWidth,
                        height: bufferHeight
                    )
                }
            }

            // Pass 3: sample the image for every visible, front-facing vertex.
            for index in vertices.indices where valid[index] {
                let world = SIMD3<Double>(
                    Double(vertices[index].x), Double(vertices[index].y), Double(vertices[index].z)
                )
                let toCamera = camera.cameraPosition - world
                let distance = length(toCamera)
                guard distance > 0 else { continue }

                var facingCosine = 1.0
                if hasNormals {
                    let normal = SIMD3<Double>(
                        Double(normals[index].x), Double(normals[index].y), Double(normals[index].z)
                    )
                    let normalLength = length(normal)
                    guard normalLength > 0 else { continue }
                    let cosine = dot(normal, toCamera) / (normalLength * distance)
                    guard cosine > 0 else { continue }
                    facingCosine = cosine
                }

                let depth = projected[index].z
                let bufferPoint = SIMD2<Double>(
                    RoomMeshProjection.resizedPixelCenter(
                        projected[index].x,
                        sourceSize: keyframe.sensorWidth,
                        destinationSize: bufferWidth
                    ),
                    RoomMeshProjection.resizedPixelCenter(
                        projected[index].y,
                        sourceSize: keyframe.sensorHeight,
                        destinationSize: bufferHeight
                    )
                )
                let bufferX = min(max(Int(bufferPoint.x.rounded()), 0), bufferWidth - 1)
                let bufferY = min(max(Int(bufferPoint.y.rounded()), 0), bufferHeight - 1)
                let nearest = depthBuffer[bufferY * bufferWidth + bufferX]
                let lidar = depthPayload?.bilinearSample(
                    x: RoomMeshProjection.resizedPixelCenter(
                        projected[index].x,
                        sourceSize: keyframe.sensorWidth,
                        destinationSize: depthPayload?.width ?? 1
                    ),
                    y: RoomMeshProjection.resizedPixelCenter(
                        projected[index].y,
                        sourceSize: keyframe.sensorHeight,
                        destinationSize: depthPayload?.height ?? 1
                    )
                )
                let visibility = RoomMeshVisibility.evaluate(
                    sampleDepth: depth,
                    lidarDepth: lidar?.depth,
                    confidence: lidar?.confidence,
                    meshDepth: nearest.isFinite ? nearest : nil
                )
                guard visibility.isVisible else { continue }

                let imageX = RoomMeshProjection.resizedPixelCenter(
                    projected[index].x,
                    sourceSize: keyframe.sensorWidth,
                    destinationSize: keyframe.imageWidth
                )
                let imageY = RoomMeshProjection.resizedPixelCenter(
                    projected[index].y,
                    sourceSize: keyframe.sensorHeight,
                    destinationSize: keyframe.imageHeight
                )
                var sampled = RoomMeshColor.bilinearSample(
                    rgba: keyframe.imageRGBA,
                    width: keyframe.imageWidth,
                    height: keyframe.imageHeight,
                    x: imageX,
                    y: imageY
                )
                sampled *= SIMD3<Double>(
                    exp(keyframe.photometricLogGain.x),
                    exp(keyframe.photometricLogGain.y),
                    exp(keyframe.photometricLogGain.z)
                )
                let pixelX = min(max(Int(imageX.rounded()), 0), keyframe.imageWidth - 1)
                let pixelY = min(max(Int(imageY.rounded()), 0), keyframe.imageHeight - 1)
                let pixelOffset = (pixelY * keyframe.imageWidth + pixelX) * 4
                let saturated = (0..<3).contains { channel in
                    keyframe.imageRGBA[pixelOffset + channel] <= 1
                        || keyframe.imageRGBA[pixelOffset + channel] >= 254
                }
                let score = RoomMeshFrameAnalysis.sampleScore(
                    facingCosine: facingCosine,
                    euclideanDistance: distance,
                    normalizedSharpness: keyframe.normalizedSharpness,
                    visibilityFactor: visibility.qualityFactor,
                    isSaturated: saturated,
                    isPhotometricallyConnected: keyframe.isPhotometricallyConnected
                )
                if score > 0 {
                    candidates[index].append(RoomMeshColorCandidate(
                        linearRGB: sampled,
                        score: score,
                        frameIndex: frameIndex
                    ))
                }
            }
        }

        var colors = [SIMD3<UInt8>](repeating: uncoloredGray, count: vertices.count)
        var linearColors = [SIMD3<Double>?](repeating: nil, count: vertices.count)
        var selectedScores = [Double](repeating: 0, count: vertices.count)
        var coloredCount = 0
        for index in vertices.indices {
            guard let selected = RoomMeshFrameAnalysis.bestInlier(from: candidates[index]) else { continue }
            colors[index] = RoomMeshColor.encode(selected.linearRGB)
            linearColors[index] = selected.linearRGB
            selectedScores[index] = selected.score
            coloredCount += 1
        }
        return Result(
            colors: colors,
            coloredVertices: candidates.map { !$0.isEmpty },
            linearColors: linearColors,
            selectedScores: selectedScores,
            coloredVertexCount: coloredCount
        )
    }

    // MARK: Small math helpers (Core stays free of the simd module)

    private struct RigidTransform {
        var columns: (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)
        var translation: SIMD3<Double>

        func transformPoint(_ point: SIMD3<Double>) -> SIMD3<Double> {
            columns.0 * point.x + columns.1 * point.y + columns.2 * point.z + translation
        }
    }

    /// Inverse of a rigid (rotation + translation) column-major 4x4:
    /// transpose the rotation, negate the rotated translation.
    private static func rigidInverse(columnMajor4x4 m: [Double]) -> RigidTransform? {
        for value in m where !value.isFinite { return nil }
        let r0 = SIMD3<Double>(m[0], m[1], m[2])
        let r1 = SIMD3<Double>(m[4], m[5], m[6])
        let r2 = SIMD3<Double>(m[8], m[9], m[10])
        let t = SIMD3<Double>(m[12], m[13], m[14])
        let transposed0 = SIMD3<Double>(r0.x, r1.x, r2.x)
        let transposed1 = SIMD3<Double>(r0.y, r1.y, r2.y)
        let transposed2 = SIMD3<Double>(r0.z, r1.z, r2.z)
        let inverseTranslation = SIMD3<Double>(
            -(dot(r0, t)),
            -(dot(r1, t)),
            -(dot(r2, t))
        )
        return RigidTransform(
            columns: (transposed0, transposed1, transposed2),
            translation: inverseTranslation
        )
    }

    private static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    private static func length(_ v: SIMD3<Double>) -> Double {
        (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
    }

    /// Min-depth edge-function rasterizer over the coarse occlusion buffer.
    /// Depth is interpolated linearly in screen space, which is accurate
    /// enough for a tolerance-guarded visibility test at this resolution.
    private static func rasterizeTriangle(
        _ a: SIMD3<Double>,
        _ b: SIMD3<Double>,
        _ c: SIMD3<Double>,
        into depthBuffer: inout [Double],
        width: Int,
        height: Int
    ) {
        let area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        guard abs(area) > 1e-12 else { return }
        let minX = max(Int(min(a.x, b.x, c.x).rounded(.down)), 0)
        let maxX = min(Int(max(a.x, b.x, c.x).rounded(.up)), width - 1)
        let minY = max(Int(min(a.y, b.y, c.y).rounded(.down)), 0)
        let maxY = min(Int(max(a.y, b.y, c.y).rounded(.up)), height - 1)
        guard minX <= maxX, minY <= maxY else { return }

        for y in minY...maxY {
            let py = Double(y) + 0.5
            for x in minX...maxX {
                let px = Double(x) + 0.5
                let w0 = ((b.x - a.x) * (py - a.y) - (b.y - a.y) * (px - a.x)) / area
                let w1 = ((c.x - b.x) * (py - b.y) - (c.y - b.y) * (px - b.x)) / area
                let w2 = 1 - w0 - w1
                guard w0 >= 0, w1 >= 0, w2 >= 0 else { continue }
                // Edge weights: w opposite each vertex; barycentric for a is
                // the weight of the edge b->c, i.e. w1 here after division.
                let depth = a.z * w1 + b.z * w2 + c.z * w0
                let offset = y * width + x
                if depth < depthBuffer[offset] {
                    depthBuffer[offset] = depth
                }
            }
        }
    }

    private static func bilinearSample(
        rgba: [UInt8],
        width: Int,
        height: Int,
        x: Double,
        y: Double
    ) -> SIMD3<Double> {
        let clampedX = min(max(x, 0), Double(width - 1))
        let clampedY = min(max(y, 0), Double(height - 1))
        let x0 = Int(clampedX)
        let y0 = Int(clampedY)
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let fx = clampedX - Double(x0)
        let fy = clampedY - Double(y0)

        func pixel(_ px: Int, _ py: Int) -> SIMD3<Double> {
            let offset = (py * width + px) * 4
            return SIMD3<Double>(
                Double(rgba[offset]),
                Double(rgba[offset + 1]),
                Double(rgba[offset + 2])
            )
        }

        let top = pixel(x0, y0) * (1 - fx) + pixel(x1, y0) * fx
        let bottom = pixel(x0, y1) * (1 - fx) + pixel(x1, y1) * fx
        return top * (1 - fy) + bottom * fy
    }
}
