import Foundation

/// Platform-independent ARKit camera projection and visibility math.
public enum RoomMeshProjection {
    public static let defaultNearPlane = 0.05

    public struct ProjectedPoint: Equatable, Sendable {
        public var pixel: SIMD2<Double>
        public var forward: Double

        public init(pixel: SIMD2<Double>, forward: Double) {
            self.pixel = pixel
            self.forward = forward
        }
    }

    public struct Camera: Sendable {
        private var worldToCameraColumns: (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)
        private var worldToCameraTranslation: SIMD3<Double>
        public let cameraPosition: SIMD3<Double>
        public let fx: Double
        public let fy: Double
        public let cx: Double
        public let cy: Double
        public let sensorWidth: Int
        public let sensorHeight: Int

        public init?(
            cameraToWorldColumnMajor m: [Double],
            intrinsicsColumnMajor k: [Double],
            sensorWidth: Int,
            sensorHeight: Int
        ) {
            guard
                m.count == 16,
                k.count == 9,
                sensorWidth > 0,
                sensorHeight > 0,
                m.allSatisfy(\.isFinite),
                k.allSatisfy(\.isFinite),
                k[0] > 0,
                k[4] > 0
            else { return nil }

            let r0 = SIMD3<Double>(m[0], m[1], m[2])
            let r1 = SIMD3<Double>(m[4], m[5], m[6])
            let r2 = SIMD3<Double>(m[8], m[9], m[10])
            let t = SIMD3<Double>(m[12], m[13], m[14])
            worldToCameraColumns = (
                SIMD3<Double>(r0.x, r1.x, r2.x),
                SIMD3<Double>(r0.y, r1.y, r2.y),
                SIMD3<Double>(r0.z, r1.z, r2.z)
            )
            worldToCameraTranslation = SIMD3<Double>(
                -dot(r0, t),
                -dot(r1, t),
                -dot(r2, t)
            )
            cameraPosition = t
            fx = k[0]
            fy = k[4]
            cx = k[6]
            cy = k[7]
            self.sensorWidth = sensorWidth
            self.sensorHeight = sensorHeight
        }

        public func cameraPoint(world: SIMD3<Double>) -> SIMD3<Double>? {
            guard world.x.isFinite, world.y.isFinite, world.z.isFinite else { return nil }
            return worldToCameraColumns.0 * world.x
                + worldToCameraColumns.1 * world.y
                + worldToCameraColumns.2 * world.z
                + worldToCameraTranslation
        }

        public func project(
            world: SIMD3<Double>,
            nearPlane: Double = RoomMeshProjection.defaultNearPlane
        ) -> ProjectedPoint? {
            guard let camera = cameraPoint(world: world) else { return nil }
            return project(camera: camera, nearPlane: nearPlane)
        }

        public func project(
            camera: SIMD3<Double>,
            nearPlane: Double = RoomMeshProjection.defaultNearPlane
        ) -> ProjectedPoint? {
            let forward = -camera.z
            guard forward >= nearPlane, forward.isFinite else { return nil }
            let u = cx + fx * camera.x / forward
            let v = cy - fy * camera.y / forward
            guard u.isFinite, v.isFinite else { return nil }
            return ProjectedPoint(pixel: SIMD2<Double>(u, v), forward: forward)
        }

        public func containsSensorPixel(_ point: SIMD2<Double>) -> Bool {
            point.x >= -0.5 && point.x < Double(sensorWidth) - 0.5
                && point.y >= -0.5 && point.y < Double(sensorHeight) - 0.5
        }
    }

    /// Convert a source pixel-center coordinate through centered resize geometry.
    public static func resizedPixelCenter(
        _ source: Double,
        sourceSize: Int,
        destinationSize: Int
    ) -> Double {
        guard sourceSize > 0, destinationSize > 0 else { return .nan }
        return (source + 0.5) * Double(destinationSize) / Double(sourceSize) - 0.5
    }

    /// Clip a camera-space triangle to `forward >= nearPlane`. Camera forward is -Z.
    public static func clipTriangleToNearPlane(
        _ triangle: [SIMD3<Double>],
        nearPlane: Double = defaultNearPlane
    ) -> [SIMD3<Double>] {
        guard triangle.count == 3, nearPlane > 0, nearPlane.isFinite else { return [] }
        var output: [SIMD3<Double>] = []
        output.reserveCapacity(4)
        var previous = triangle[triangle.count - 1]
        var previousInside = previous.x.isFinite && previous.y.isFinite && previous.z.isFinite
            && -previous.z >= nearPlane

        for current in triangle {
            let currentInside = current.x.isFinite && current.y.isFinite && current.z.isFinite
                && -current.z >= nearPlane
            if currentInside != previousInside,
               let intersection = nearPlaneIntersection(
                   from: previous,
                   to: current,
                   nearPlane: nearPlane
               ) {
                output.append(intersection)
            }
            if currentInside {
                output.append(current)
            }
            previous = current
            previousInside = currentInside
        }
        return output
    }

    public static func perspectiveDepth(
        barycentric: SIMD3<Double>,
        vertexDepths: SIMD3<Double>
    ) -> Double {
        guard
            barycentric.x.isFinite,
            barycentric.y.isFinite,
            barycentric.z.isFinite,
            vertexDepths.x > 0,
            vertexDepths.y > 0,
            vertexDepths.z > 0
        else { return .infinity }
        let reciprocal = barycentric.x / vertexDepths.x
            + barycentric.y / vertexDepths.y
            + barycentric.z / vertexDepths.z
        return reciprocal > 0 && reciprocal.isFinite ? 1 / reciprocal : .infinity
    }

    /// Rasterizes already-projected pixel-center vertices using reciprocal camera-axis depth.
    public static func rasterizeDepthTriangle(
        _ a: ProjectedPoint,
        _ b: ProjectedPoint,
        _ c: ProjectedPoint,
        into depths: inout [Double],
        width: Int,
        height: Int
    ) {
        guard width > 0, height > 0, depths.count == width * height else { return }
        let area = edge(a.pixel, b.pixel, c.pixel)
        guard abs(area) > 1e-12 else { return }
        let minX = max(Int(floor(min(a.pixel.x, b.pixel.x, c.pixel.x) - 0.5)), 0)
        let maxX = min(Int(ceil(max(a.pixel.x, b.pixel.x, c.pixel.x) - 0.5)), width - 1)
        let minY = max(Int(floor(min(a.pixel.y, b.pixel.y, c.pixel.y) - 0.5)), 0)
        let maxY = min(Int(ceil(max(a.pixel.y, b.pixel.y, c.pixel.y) - 0.5)), height - 1)
        guard minX <= maxX, minY <= maxY else { return }

        for y in minY...maxY {
            for x in minX...maxX {
                let p = SIMD2<Double>(Double(x), Double(y))
                let w0 = edge(b.pixel, c.pixel, p) / area
                let w1 = edge(c.pixel, a.pixel, p) / area
                let w2 = 1 - w0 - w1
                guard w0 >= -1e-12, w1 >= -1e-12, w2 >= -1e-12 else { continue }
                let depth = perspectiveDepth(
                    barycentric: SIMD3<Double>(w0, w1, w2),
                    vertexDepths: SIMD3<Double>(a.forward, b.forward, c.forward)
                )
                let offset = y * width + x
                if depth < depths[offset] { depths[offset] = depth }
            }
        }
    }

    private static func nearPlaneIntersection(
        from a: SIMD3<Double>,
        to b: SIMD3<Double>,
        nearPlane: Double
    ) -> SIMD3<Double>? {
        let forwardA = -a.z
        let forwardB = -b.z
        let denominator = forwardB - forwardA
        guard denominator.isFinite, abs(denominator) > 1e-15 else { return nil }
        let t = (nearPlane - forwardA) / denominator
        guard t.isFinite else { return nil }
        var result = a + (b - a) * t
        result.z = -nearPlane
        return result
    }

    private static func edge(
        _ a: SIMD2<Double>,
        _ b: SIMD2<Double>,
        _ p: SIMD2<Double>
    ) -> Double {
        (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
    }

    private static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }
}

public struct RoomMeshDepthSample: Equatable, Sendable {
    public var depth: Double
    public var confidence: UInt8?

    public init(depth: Double, confidence: UInt8?) {
        self.depth = depth
        self.confidence = confidence
    }
}

/// Tightly packed LiDAR camera-axis depth and optional ARConfidenceLevel bytes.
public struct RoomMeshDepthPayload: Sendable {
    public let width: Int
    public let height: Int
    public let depthMeters: [Float]
    public let confidence: [UInt8]?

    public init?(
        width: Int,
        height: Int,
        depthMeters: [Float],
        confidence: [UInt8]?
    ) {
        guard width > 0, height > 0, width <= Int.max / height else { return nil }
        let count = width * height
        guard depthMeters.count == count, confidence == nil || confidence?.count == count else {
            return nil
        }
        self.width = width
        self.height = height
        self.depthMeters = depthMeters
        self.confidence = confidence
    }

    /// Samples only finite positive neighbors, renormalizing their bilinear weights.
    /// Confidence is the minimum level among contributing valid-depth texels.
    public func bilinearSample(x: Double, y: Double) -> RoomMeshDepthSample? {
        guard x.isFinite, y.isFinite else { return nil }
        let cx = min(max(x, 0), Double(width - 1))
        let cy = min(max(y, 0), Double(height - 1))
        let x0 = Int(floor(cx)), y0 = Int(floor(cy))
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = cx - Double(x0), fy = cy - Double(y0)
        let neighbors = [
            (x0, y0, (1 - fx) * (1 - fy)),
            (x1, y0, fx * (1 - fy)),
            (x0, y1, (1 - fx) * fy),
            (x1, y1, fx * fy),
        ]
        var weightedDepth = 0.0
        var totalWeight = 0.0
        var minimumConfidence: UInt8?
        for (px, py, weight) in neighbors where weight > 0 {
            let index = py * width + px
            let depth = Double(depthMeters[index])
            guard depth > 0, depth.isFinite else { continue }
            weightedDepth += depth * weight
            totalWeight += weight
            if let confidence {
                let level = confidence[index]
                minimumConfidence = minimumConfidence.map { min($0, level) } ?? level
            }
        }
        guard totalWeight > 0 else { return nil }
        return RoomMeshDepthSample(
            depth: weightedDepth / totalWeight,
            confidence: minimumConfidence
        )
    }
}

public struct RoomMeshVisibilityResult: Equatable, Sendable {
    public var isVisible: Bool
    public var qualityFactor: Double
    public var usedLiDAR: Bool

    public init(isVisible: Bool, qualityFactor: Double, usedLiDAR: Bool) {
        self.isVisible = isVisible
        self.qualityFactor = qualityFactor
        self.usedLiDAR = usedLiDAR
    }
}

public enum RoomMeshVisibility {
    public static let highConfidenceBias = 0.02
    public static let highConfidenceScale = 0.01
    public static let mediumConfidenceBias = 0.04
    public static let mediumConfidenceScale = 0.02
    public static let meshBias = 0.03
    public static let meshScale = 0.02

    public static func evaluate(
        sampleDepth: Double,
        lidarDepth: Double?,
        confidence: UInt8?,
        meshDepth: Double?
    ) -> RoomMeshVisibilityResult {
        guard sampleDepth > 0, sampleDepth.isFinite else {
            return RoomMeshVisibilityResult(isVisible: false, qualityFactor: 0, usedLiDAR: false)
        }
        if let lidarDepth, lidarDepth > 0, lidarDepth.isFinite, let confidence {
            if confidence >= 2 {
                let limit = lidarDepth + highConfidenceBias + highConfidenceScale * lidarDepth
                return RoomMeshVisibilityResult(
                    isVisible: sampleDepth <= limit,
                    qualityFactor: 1,
                    usedLiDAR: true
                )
            }
            if confidence == 1 {
                let limit = lidarDepth + mediumConfidenceBias + mediumConfidenceScale * lidarDepth
                return RoomMeshVisibilityResult(
                    isVisible: sampleDepth <= limit,
                    qualityFactor: 0.9,
                    usedLiDAR: true
                )
            }
        }
        if let meshDepth, meshDepth > 0, meshDepth.isFinite {
            let limit = meshDepth + meshBias + meshScale * meshDepth
            return RoomMeshVisibilityResult(
                isVisible: sampleDepth <= limit,
                qualityFactor: 0.75,
                usedLiDAR: false
            )
        }
        // Missing/low-confidence evidence must not turn a valid RGB projection
        // into a false hard rejection.
        return RoomMeshVisibilityResult(isVisible: true, qualityFactor: 0.75, usedLiDAR: false)
    }

    public static func meshBufferWidth(
        requested: Int,
        recordedDepthWidth: Int?
    ) -> Int {
        min(max(max(requested, 8), recordedDepthWidth ?? 0), 512)
    }
}
