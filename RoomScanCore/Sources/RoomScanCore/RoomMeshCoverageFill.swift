import Foundation

public struct RoomMeshCoverageSample: Equatable, Sendable {
    public var linearRGB: SIMD3<Double>?
    public var confidence: Double
    public var isCalibrationEvidence: Bool

    public init(linearRGB: SIMD3<Double>?, confidence: Double, isCalibrationEvidence: Bool) {
        self.linearRGB = linearRGB
        self.confidence = confidence
        self.isCalibrationEvidence = isCalibrationEvidence
    }
}

public enum RoomMeshCoverageFiller {
    public struct Settings: Equatable, Sendable {
        public var maximumHops: Int
        public var maximumEdgeLength: Float
        public var maximumNormalAngleDegrees: Float
        public var maximumDepthDiscontinuity: Float

        public init(
            maximumHops: Int = 2,
            maximumEdgeLength: Float = 0.20,
            maximumNormalAngleDegrees: Float = 30,
            maximumDepthDiscontinuity: Float = 0.04
        ) {
            self.maximumHops = maximumHops
            self.maximumEdgeLength = maximumEdgeLength
            self.maximumNormalAngleDegrees = maximumNormalAngleDegrees
            self.maximumDepthDiscontinuity = maximumDepthDiscontinuity
        }
    }

    /// Conservatively propagates only original colors across short, locally
    /// coplanar graph paths. Filled values are never calibration evidence.
    public static func fill(
        positions: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        faces: [UInt32],
        colors: [SIMD3<Double>?],
        settings: Settings = .init()
    ) -> [RoomMeshCoverageSample] {
        let count = positions.count
        guard colors.count == count else { return [] }
        var result = colors.map {
            RoomMeshCoverageSample(linearRGB: $0, confidence: $0 == nil ? 0 : 1, isCalibrationEvidence: $0 != nil)
        }
        guard count > 0, settings.maximumHops > 0 else { return result }
        var adjacency = [Set<Int>](repeating: [], count: count)
        for index in stride(from: 0, to: faces.count - faces.count % 3, by: 3) {
            let triangle = [Int(faces[index]), Int(faces[index + 1]), Int(faces[index + 2])]
            guard triangle.allSatisfy({ $0 >= 0 && $0 < count }) else { continue }
            for (a, b) in [(triangle[0], triangle[1]), (triangle[1], triangle[2]), (triangle[2], triangle[0])] {
                adjacency[a].insert(b)
                adjacency[b].insert(a)
            }
        }
        let cosineLimit = cos(settings.maximumNormalAngleDegrees * .pi / 180)
        func normalized(_ value: SIMD3<Float>) -> SIMD3<Float>? {
            let length = sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
            return length > 1e-6 && length.isFinite ? value / length : nil
        }
        func traversable(_ lhs: Int, _ rhs: Int) -> Bool {
            let delta = positions[rhs] - positions[lhs]
            let distance = sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
            guard distance <= settings.maximumEdgeLength, distance.isFinite else { return false }
            guard normals.count == count,
                  let a = normalized(normals[lhs]), let b = normalized(normals[rhs]) else { return false }
            let agreement = a.x * b.x + a.y * b.y + a.z * b.z
            guard agreement >= cosineLimit else { return false }
            let average = normalized(a + b) ?? a
            let depthStep = abs(delta.x * average.x + delta.y * average.y + delta.z * average.z)
            return depthStep <= settings.maximumDepthDiscontinuity
        }

        struct Frontier { var vertex: Int; var color: SIMD3<Double>; var hop: Int; var source: Int }
        var queue: [Frontier] = colors.indices.compactMap { index in
            colors[index].map { Frontier(vertex: index, color: $0, hop: 0, source: index) }
        }.sorted { $0.source < $1.source }
        var cursor = 0
        var visitedHop = colors.map { $0 == nil ? Int.max : 0 }
        while cursor < queue.count {
            let item = queue[cursor]
            cursor += 1
            guard item.hop < settings.maximumHops else { continue }
            for neighbor in adjacency[item.vertex].sorted() where traversable(item.vertex, neighbor) {
                let nextHop = item.hop + 1
                guard nextHop < visitedHop[neighbor] else { continue }
                visitedHop[neighbor] = nextHop
                if colors[neighbor] == nil {
                    result[neighbor] = .init(
                        linearRGB: item.color,
                        confidence: pow(0.5, Double(nextHop)),
                        isCalibrationEvidence: false
                    )
                }
                queue.append(.init(vertex: neighbor, color: item.color, hop: nextHop, source: item.source))
            }
        }
        return result
    }
}
