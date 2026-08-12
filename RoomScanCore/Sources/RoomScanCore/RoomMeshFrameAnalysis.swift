import Foundation

public enum RoomMeshColor {
    private static let byteToLinear: [Double] = (0...255).map { byte in
        let encoded = Double(byte) / 255
        if encoded <= 0.04045 { return encoded / 12.92 }
        return pow((encoded + 0.055) / 1.055, 2.4)
    }

    public static func sRGBToLinear(_ encoded: UInt8) -> Double {
        byteToLinear[Int(encoded)]
    }

    public static func sRGBUnitToLinear(_ encoded: Double) -> Double {
        let value = min(max(encoded, 0), 1)
        if value <= 0.04045 { return value / 12.92 }
        return pow((value + 0.055) / 1.055, 2.4)
    }

    public static func linearToSRGBUnit(_ linear: Double) -> Double {
        let value = min(max(linear, 0), 1)
        if value <= 0.0031308 { return value * 12.92 }
        return 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    public static func linearToSRGB(_ linear: Double) -> UInt8 {
        UInt8(min(max((linearToSRGBUnit(linear) * 255).rounded(), 0), 255))
    }

    public static func encode(_ linear: SIMD3<Double>) -> SIMD3<UInt8> {
        SIMD3<UInt8>(
            linearToSRGB(linear.x),
            linearToSRGB(linear.y),
            linearToSRGB(linear.z)
        )
    }

    /// Bilinear interpolation after decoding each contributing sRGB texel.
    public static func bilinearSample(
        rgba: [UInt8],
        width: Int,
        height: Int,
        x: Double,
        y: Double
    ) -> SIMD3<Double> {
        guard width > 0, height > 0, rgba.count == width * height * 4 else {
            return .zero
        }
        let clampedX = min(max(x, 0), Double(width - 1))
        let clampedY = min(max(y, 0), Double(height - 1))
        let x0 = Int(floor(clampedX))
        let y0 = Int(floor(clampedY))
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let fx = clampedX - Double(x0)
        let fy = clampedY - Double(y0)

        func pixel(_ px: Int, _ py: Int) -> SIMD3<Double> {
            let offset = (py * width + px) * 4
            return SIMD3<Double>(
                sRGBToLinear(rgba[offset]),
                sRGBToLinear(rgba[offset + 1]),
                sRGBToLinear(rgba[offset + 2])
            )
        }
        let top = pixel(x0, y0) * (1 - fx) + pixel(x1, y0) * fx
        let bottom = pixel(x0, y1) * (1 - fx) + pixel(x1, y1) * fx
        return top * (1 - fy) + bottom * fy
    }
}

public struct RoomMeshColorCandidate: Equatable, Sendable {
    public var linearRGB: SIMD3<Double>
    public var score: Double
    public var frameIndex: Int

    public init(linearRGB: SIMD3<Double>, score: Double, frameIndex: Int) {
        self.linearRGB = linearRGB
        self.score = score
        self.frameIndex = frameIndex
    }
}

public struct RoomMeshPhotometricSample: Equatable, Sendable {
    public var sampleID: Int
    public var linearRGB: SIMD3<Double>

    public init(sampleID: Int, linearRGB: SIMD3<Double>) {
        self.sampleID = sampleID
        self.linearRGB = linearRGB
    }
}

public struct RoomMeshPhotometricCalibration: Equatable, Sendable {
    public var logGain: SIMD3<Double>
    public var isConnected: Bool

    public init(logGain: SIMD3<Double> = .zero, isConnected: Bool = false) {
        self.logGain = logGain
        self.isConnected = isConnected
    }
}

public struct RoomMeshPhotometricCalibrationResult: Equatable, Sendable {
    public var frames: [RoomMeshPhotometricCalibration]
    public var anchorFrameIndex: Int?

    public init(frames: [RoomMeshPhotometricCalibration], anchorFrameIndex: Int?) {
        self.frames = frames
        self.anchorFrameIndex = anchorFrameIndex
    }
}

public enum RoomMeshFrameAnalysis {
    public static let maximumFallbackCandidates = 5
    public static let maximumCalibrationSamplesPerFrame = 4_096
    public static let minimumCalibrationOverlap = 128

    public static func sampleScore(
        facingCosine: Double,
        euclideanDistance: Double,
        normalizedSharpness: Double,
        visibilityFactor: Double,
        isSaturated: Bool,
        isPhotometricallyConnected: Bool
    ) -> Double {
        guard
            facingCosine > 0,
            euclideanDistance > 0,
            facingCosine.isFinite,
            euclideanDistance.isFinite,
            normalizedSharpness.isFinite,
            visibilityFactor.isFinite
        else { return 0 }
        var score = facingCosine * facingCosine
            * min(max(normalizedSharpness, 0.5), 2)
            / (euclideanDistance * euclideanDistance)
        score *= visibilityFactor
        if isSaturated { score *= 0.25 }
        if !isPhotometricallyConnected { score *= 0.75 }
        return score.isFinite ? score : 0
    }

    public static func normalizedSharpness(_ rawScores: [Double]) -> [Double] {
        let nonzero = rawScores.filter { $0 > 0 && $0.isFinite }.sorted()
        guard !nonzero.isEmpty else {
            return [Double](repeating: 0.5, count: rawScores.count)
        }
        let median: Double
        if nonzero.count.isMultiple(of: 2) {
            median = (nonzero[nonzero.count / 2 - 1] + nonzero[nonzero.count / 2]) / 2
        } else {
            median = nonzero[nonzero.count / 2]
        }
        return rawScores.map { score in
            guard score > 0, score.isFinite else { return 0.5 }
            return min(max(score / median, 0.5), 2)
        }
    }

    /// Normalized variance of a 3x3 discrete Laplacian over linear luminance.
    public static func luminanceSharpness(
        rgba: [UInt8],
        width: Int,
        height: Int
    ) -> Double {
        guard width >= 3, height >= 3, rgba.count == width * height * 4 else { return 0 }
        var luminance = [Double](repeating: 0, count: width * height)
        for index in luminance.indices {
            let offset = index * 4
            luminance[index] = 0.2126 * RoomMeshColor.sRGBToLinear(rgba[offset])
                + 0.7152 * RoomMeshColor.sRGBToLinear(rgba[offset + 1])
                + 0.0722 * RoomMeshColor.sRGBToLinear(rgba[offset + 2])
        }
        var count = 0
        var mean = 0.0
        var m2 = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let center = y * width + x
                let value = -8 * luminance[center]
                    + luminance[center - width - 1]
                    + luminance[center - width]
                    + luminance[center - width + 1]
                    + luminance[center - 1]
                    + luminance[center + 1]
                    + luminance[center + width - 1]
                    + luminance[center + width]
                    + luminance[center + width + 1]
                count += 1
                let delta = value - mean
                mean += delta / Double(count)
                m2 += delta * (value - mean)
            }
        }
        guard count > 1 else { return 0 }
        return max(m2 / Double(count - 1), 0)
    }

    /// Retain the five strongest samples, find their dominant linear-color cluster,
    /// then choose the highest-quality member rather than averaging all frames.
    public static func bestInlier(
        from candidates: [RoomMeshColorCandidate]
    ) -> RoomMeshColorCandidate? {
        let finite = candidates.filter {
            $0.score > 0 && $0.score.isFinite
                && $0.linearRGB.x.isFinite && $0.linearRGB.y.isFinite && $0.linearRGB.z.isFinite
        }
        let best = finite.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.frameIndex < $1.frameIndex
        }.prefix(maximumFallbackCandidates)
        guard !best.isEmpty else { return nil }
        let retained = Array(best)
        let thresholdSquared = 0.15 * 0.15
        let support = retained.map { candidate in
            retained.reduce(into: 0) { count, other in
                let delta = candidate.linearRGB - other.linearRGB
                if dot(delta, delta) <= thresholdSquared { count += 1 }
            }
        }
        let maximumSupport = support.max() ?? 1
        let supportedIndices = retained.indices.filter { support[$0] == maximumSupport }
        let centerIndex = supportedIndices.min { lhs, rhs in
            if retained[lhs].score != retained[rhs].score {
                return retained[lhs].score > retained[rhs].score
            }
            return retained[lhs].frameIndex < retained[rhs].frameIndex
        } ?? 0
        let center = retained[centerIndex].linearRGB
        return retained.filter { candidate in
            let delta = candidate.linearRGB - center
            return dot(delta, delta) <= thresholdSquared
        }.max {
            if $0.score != $1.score { return $0.score < $1.score }
            return $0.frameIndex > $1.frameIndex
        }
    }

    /// Solves multiplicative RGB exposure differences in log space. Samples are
    /// addressed by stable mesh IDs so only mutually observed surface points form
    /// graph edges. Underconstrained components deliberately keep identity gains.
    public static func solvePhotometricCalibration(
        samplesByFrame: [[RoomMeshPhotometricSample]],
        normalizedSharpness: [Double]
    ) -> RoomMeshPhotometricCalibrationResult {
        struct FramePair: Hashable {
            var lhs: Int
            var rhs: Int
        }
        struct Edge {
            var lhs: Int
            var rhs: Int
            var target: SIMD3<Double> // gain(lhs) - gain(rhs)
            var weight: Double
        }

        let frameCount = samplesByFrame.count
        guard frameCount > 0 else {
            return .init(frames: [], anchorFrameIndex: nil)
        }
        let bounded: [[Int: SIMD3<Double>]] = samplesByFrame.map { samples in
            Dictionary(uniqueKeysWithValues: samples
                .filter { finitePositive($0.linearRGB) }
                .sorted { $0.sampleID < $1.sampleID }
                .prefix(maximumCalibrationSamplesPerFrame)
                .map { ($0.sampleID, $0.linearRGB) })
        }
        let sampleRanges: [(minimum: Int, maximum: Int)?] = bounded.map { frame in
            guard frame.count >= minimumCalibrationOverlap,
                  let minimum = frame.keys.min(),
                  let maximum = frame.keys.max() else { return nil }
            return (minimum, maximum)
        }
        var participatesInPossibleOverlap = [Bool](repeating: false, count: frameCount)
        if frameCount > 1 {
            for lhs in 0..<(frameCount - 1) {
                guard let lhsRange = sampleRanges[lhs] else { continue }
                for rhs in (lhs + 1)..<frameCount {
                    guard let rhsRange = sampleRanges[rhs],
                          max(lhsRange.minimum, rhsRange.minimum)
                            <= min(lhsRange.maximum, rhsRange.maximum) else { continue }
                    participatesInPossibleOverlap[lhs] = true
                    participatesInPossibleOverlap[rhs] = true
                }
            }
        }
        var occurrences: [(sampleID: Int, frame: Int)] = []
        occurrences.reserveCapacity(bounded.indices.reduce(into: 0) { count, frame in
            if participatesInPossibleOverlap[frame] { count += bounded[frame].count }
        })
        for frame in bounded.indices where participatesInPossibleOverlap[frame] {
            for sampleID in bounded[frame].keys {
                occurrences.append((sampleID, frame))
            }
        }
        occurrences.sort {
            if $0.sampleID != $1.sampleID { return $0.sampleID < $1.sampleID }
            return $0.frame < $1.frame
        }
        var overlapCounts: [FramePair: Int] = [:]
        var groupStart = 0
        while groupStart < occurrences.count {
            var groupEnd = groupStart + 1
            while groupEnd < occurrences.count,
                  occurrences[groupEnd].sampleID == occurrences[groupStart].sampleID {
                groupEnd += 1
            }
            if groupEnd - groupStart > 1 {
                for lhsOffset in groupStart..<(groupEnd - 1) {
                    for rhsOffset in (lhsOffset + 1)..<groupEnd {
                        let pair = FramePair(
                            lhs: occurrences[lhsOffset].frame,
                            rhs: occurrences[rhsOffset].frame
                        )
                        let count = overlapCounts[pair, default: 0]
                        if count < minimumCalibrationOverlap {
                            overlapCounts[pair] = count + 1
                        }
                    }
                }
            }
            groupStart = groupEnd
        }
        let candidatePairs = overlapCounts.compactMap { pair, count in
            count >= minimumCalibrationOverlap ? pair : nil
        }.sorted {
            if $0.lhs != $1.lhs { return $0.lhs < $1.lhs }
            return $0.rhs < $1.rhs
        }
        var edges: [Edge] = []
        var overlapWeight = [Double](repeating: 0, count: frameCount)
        for pair in candidatePairs {
            let shared = bounded[pair.lhs].keys.filter { bounded[pair.rhs][$0] != nil }.sorted()
            var ratios = [SIMD3<Double>]()
            ratios.reserveCapacity(shared.count)
            for sampleID in shared {
                guard let a = bounded[pair.lhs][sampleID], let b = bounded[pair.rhs][sampleID] else { continue }
                ratios.append(SIMD3(log(b.x / a.x), log(b.y / a.y), log(b.z / a.z)))
            }
            guard ratios.count >= minimumCalibrationOverlap else { continue }
            let center = componentMedian(ratios)
            let distances = ratios.map { value -> Double in
                let delta = value - center
                return sqrt(dot(delta, delta))
            }
            let mad = median(distances)
            let limit = max(3 * mad, 0.03)
            let inliers = zip(ratios, distances).compactMap { value, distance in
                distance <= limit ? value : nil
            }
            guard inliers.count >= minimumCalibrationOverlap - 1 else { continue }
            let target = componentMedian(inliers)
            let weight = Double(inliers.count)
            edges.append(.init(lhs: pair.lhs, rhs: pair.rhs, target: target, weight: weight))
            overlapWeight[pair.lhs] += weight
            overlapWeight[pair.rhs] += weight
        }

        guard let anchor = (0..<frameCount).filter({ overlapWeight[$0] > 0 }).max(by: { lhs, rhs in
            if overlapWeight[lhs] != overlapWeight[rhs] { return overlapWeight[lhs] < overlapWeight[rhs] }
            let lhsSharpness = lhs < normalizedSharpness.count ? normalizedSharpness[lhs] : 0
            let rhsSharpness = rhs < normalizedSharpness.count ? normalizedSharpness[rhs] : 0
            if lhsSharpness != rhsSharpness { return lhsSharpness < rhsSharpness }
            return lhs > rhs
        }) else {
            return .init(
                frames: [RoomMeshPhotometricCalibration](repeating: .init(), count: frameCount),
                anchorFrameIndex: nil
            )
        }

        var connected = Set([anchor])
        var changed = true
        while changed {
            changed = false
            for edge in edges where connected.contains(edge.lhs) || connected.contains(edge.rhs) {
                if connected.insert(edge.lhs).inserted { changed = true }
                if connected.insert(edge.rhs).inserted { changed = true }
            }
        }
        let unknowns = connected.filter { $0 != anchor }.sorted()
        let indexByFrame = Dictionary(uniqueKeysWithValues: unknowns.enumerated().map { ($1, $0) })
        var solved = [SIMD3<Double>](repeating: .zero, count: frameCount)
        if !unknowns.isEmpty {
            for channel in 0..<3 {
                var matrix = [[Double]](repeating: [Double](repeating: 0, count: unknowns.count), count: unknowns.count)
                var rhsVector = [Double](repeating: 0, count: unknowns.count)
                for edge in edges where connected.contains(edge.lhs) && connected.contains(edge.rhs) {
                    let target = edge.target[channel]
                    let coefficients = [(edge.lhs, 1.0), (edge.rhs, -1.0)]
                    for (frame, coefficient) in coefficients {
                        guard let row = indexByFrame[frame] else { continue }
                        rhsVector[row] += edge.weight * coefficient * target
                        for (otherFrame, otherCoefficient) in coefficients {
                            guard let column = indexByFrame[otherFrame] else { continue }
                            matrix[row][column] += edge.weight * coefficient * otherCoefficient
                        }
                    }
                }
                let values = solveLinearSystem(matrix: matrix, rhs: rhsVector)
                for (offset, frame) in unknowns.enumerated() {
                    solved[frame][channel] = values[offset]
                }
            }
        }

        let maximumLuminance = log(2.0)
        let frames = (0..<frameCount).map { frame -> RoomMeshPhotometricCalibration in
            guard connected.contains(frame) else { return .init() }
            let raw = solved[frame]
            let luminance = min(max((raw.x + raw.y + raw.z) / 3, -maximumLuminance), maximumLuminance)
            let chroma = raw - SIMD3(repeating: (raw.x + raw.y + raw.z) / 3)
            let clamped = SIMD3<Double>(
                luminance + min(max(chroma.x, -0.25), 0.25),
                luminance + min(max(chroma.y, -0.25), 0.25),
                luminance + min(max(chroma.z, -0.25), 0.25)
            )
            return .init(logGain: clamped, isConnected: true)
        }
        return .init(frames: frames, anchorFrameIndex: anchor)
    }

    private static func finitePositive(_ value: SIMD3<Double>) -> Bool {
        value.x > 0 && value.y > 0 && value.z > 0
            && value.x.isFinite && value.y.isFinite && value.z.isFinite
    }

    private static func componentMedian(_ values: [SIMD3<Double>]) -> SIMD3<Double> {
        SIMD3(
            median(values.map(\.x)),
            median(values.map(\.y)),
            median(values.map(\.z))
        )
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    private static func solveLinearSystem(matrix: [[Double]], rhs: [Double]) -> [Double] {
        let count = rhs.count
        guard count > 0 else { return [] }
        var augmented = zip(matrix, rhs).map { $0 + [$1] }
        for column in 0..<count {
            let pivot = (column..<count).max { abs(augmented[$0][column]) < abs(augmented[$1][column]) } ?? column
            if pivot != column { augmented.swapAt(pivot, column) }
            let divisor = augmented[column][column]
            guard abs(divisor) > 1e-12 else { continue }
            for entry in column...count { augmented[column][entry] /= divisor }
            for row in 0..<count where row != column {
                let factor = augmented[row][column]
                guard factor != 0 else { continue }
                for entry in column...count {
                    augmented[row][entry] -= factor * augmented[column][entry]
                }
            }
        }
        return augmented.map { $0[count].isFinite ? $0[count] : 0 }
    }

    private static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }
}
