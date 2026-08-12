import Foundation

public struct RoomMeshFaceCandidate: Equatable, Sendable {
    public var frameIndex: Int
    public var score: Double

    public init(frameIndex: Int, score: Double) {
        self.frameIndex = frameIndex
        self.score = score
    }
}

public struct RoomMeshChartRequest: Equatable, Sendable {
    public var id: Int
    public var width: Int
    public var height: Int
    public var frameIndex: Int
    public var firstFaceIndex: Int

    public init(id: Int, width: Int, height: Int, frameIndex: Int, firstFaceIndex: Int) {
        self.id = id
        self.width = width
        self.height = height
        self.frameIndex = frameIndex
        self.firstFaceIndex = firstFaceIndex
    }
}

public struct RoomMeshChartPlacement: Equatable, Sendable {
    public var id: Int
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(id: Int, x: Int, y: Int, width: Int, height: Int) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct RoomMeshProjectedFace: Equatable, Sendable {
    public var faceIndex: Int
    public var frameIndex: Int
    public var vertexIndices: [UInt32]
    public var pixels: [SIMD2<Double>]

    public init(faceIndex: Int, frameIndex: Int, vertexIndices: [UInt32], pixels: [SIMD2<Double>]) {
        self.faceIndex = faceIndex
        self.frameIndex = frameIndex
        self.vertexIndices = vertexIndices
        self.pixels = pixels
    }
}

public struct RoomMeshChart: Equatable, Sendable {
    public var id: Int
    public var frameIndex: Int
    public var faceIndices: [Int]

    public init(id: Int, frameIndex: Int, faceIndices: [Int]) {
        self.id = id
        self.frameIndex = frameIndex
        self.faceIndices = faceIndices
    }
}

public struct RoomMeshScaledPacking: Equatable, Sendable {
    public var scale: Double
    public var placements: [RoomMeshChartPlacement]

    public init(scale: Double, placements: [RoomMeshChartPlacement]) {
        self.scale = scale
        self.placements = placements
    }
}

public struct RoomMeshPhotorealMesh: Equatable, Sendable {
    public var vertices: [SIMD3<Float>]
    public var normals: [SIMD3<Float>]
    public var fallbackColors: [SIMD3<UInt8>]
    public var uvs: [SIMD2<Float>]
    public var textureValid: [UInt8]
    public var faces: [UInt32]

    public init(
        vertices: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        fallbackColors: [SIMD3<UInt8>],
        uvs: [SIMD2<Float>],
        textureValid: [UInt8],
        faces: [UInt32]
    ) {
        self.vertices = vertices
        self.normals = normals
        self.fallbackColors = fallbackColors
        self.uvs = uvs
        self.textureValid = textureValid
        self.faces = faces
    }
}

public enum RoomMeshTextureBaker {
    public static let coherencePassCount = 3
    public static let coherencePenaltyScale = 0.15
    public static let atlasPadding = 8
    public static let maximumAtlasDimension = 4_096

    public static func faceCandidate(
        frameIndex: Int,
        vertexVisibility: [Bool],
        centroidVisible: Bool,
        score: Double
    ) -> RoomMeshFaceCandidate? {
        guard vertexVisibility.count == 3,
              vertexVisibility.allSatisfy({ $0 }),
              centroidVisible,
              score > 0,
              score.isFinite else { return nil }
        return RoomMeshFaceCandidate(frameIndex: frameIndex, score: score)
    }

    /// Builds deterministic connected components per source frame, splitting
    /// folds and projected overlaps at their shared mesh edge.
    public static func constructCharts(projectedFaces: [RoomMeshProjectedFace]) -> [RoomMeshChart] {
        struct Edge: Hashable {
            var frameIndex: Int
            var a: UInt32
            var b: UInt32
        }
        let faces = projectedFaces.filter {
            $0.vertexIndices.count == 3 && $0.pixels.count == 3
                && abs(signedArea($0.pixels)) > 1e-12
        }.sorted { $0.faceIndex < $1.faceIndex }

        var facesByEdge: [Edge: [Int]] = [:]
        facesByEdge.reserveCapacity(faces.count * 2)
        for faceIndex in faces.indices {
            let vertices = faces[faceIndex].vertexIndices
            var uniqueEdges: Set<Edge> = []
            for corner in 0..<3 {
                let first = vertices[corner]
                let second = vertices[(corner + 1) % 3]
                uniqueEdges.insert(Edge(
                    frameIndex: faces[faceIndex].frameIndex,
                    a: min(first, second),
                    b: max(first, second)
                ))
            }
            for edge in uniqueEdges {
                facesByEdge[edge, default: []].append(faceIndex)
            }
        }

        var adjacency = [Set<Int>](repeating: [], count: faces.count)
        for (edge, incidentFaces) in facesByEdge where incidentFaces.count > 1 {
            for lhsOffset in 0..<(incidentFaces.count - 1) {
                for rhsOffset in (lhsOffset + 1)..<incidentFaces.count {
                    let lhs = incidentFaces[lhsOffset]
                    let rhs = incidentFaces[rhsOffset]
                    guard compatibleAcrossSharedEdge(
                        faces[lhs],
                        faces[rhs],
                        shared: [edge.a, edge.b]
                    ) else { continue }
                    adjacency[lhs].insert(rhs)
                    adjacency[rhs].insert(lhs)
                }
            }
        }
        var visited = [Bool](repeating: false, count: faces.count)
        var charts: [RoomMeshChart] = []
        for start in faces.indices where !visited[start] {
            visited[start] = true
            var queue = [start]
            var cursor = 0
            var component: [Int] = []
            while cursor < queue.count {
                let current = queue[cursor]
                cursor += 1
                component.append(faces[current].faceIndex)
                for neighbor in adjacency[current].sorted(by: { faces[$0].faceIndex < faces[$1].faceIndex })
                    where !visited[neighbor] {
                    visited[neighbor] = true
                    queue.append(neighbor)
                }
            }
            component.sort()
            charts.append(.init(
                id: component[0],
                frameIndex: faces[start].frameIndex,
                faceIndices: component
            ))
        }
        return charts.sorted { $0.id < $1.id }
    }

    /// Finds the greatest common chart scale that the deterministic packer can
    /// place completely. The fixed iteration count makes output reproducible.
    public static func packAtGreatestScale(
        charts: [RoomMeshChartRequest],
        atlasSize: Int,
        padding: Int = atlasPadding
    ) -> RoomMeshScaledPacking? {
        guard !charts.isEmpty else { return .init(scale: 1, placements: []) }
        func attempt(_ scale: Double) -> [RoomMeshChartPlacement]? {
            let scaled = charts.map {
                RoomMeshChartRequest(
                    id: $0.id,
                    width: max(Int(floor(Double($0.width) * scale)), 2),
                    height: max(Int(floor(Double($0.height) * scale)), 2),
                    frameIndex: $0.frameIndex,
                    firstFaceIndex: $0.firstFaceIndex
                )
            }
            let placements = pack(charts: scaled, atlasSize: atlasSize, padding: padding)
            return placements.count == charts.count ? placements : nil
        }
        if let placements = attempt(1) { return .init(scale: 1, placements: placements) }
        guard attempt(0) != nil else { return nil }
        var lower = 0.0
        var upper = 1.0
        var best = attempt(0) ?? []
        for _ in 0..<32 {
            let middle = (lower + upper) / 2
            if let placements = attempt(middle) {
                lower = middle
                best = placements
            } else {
                upper = middle
            }
        }
        return .init(scale: lower, placements: best)
    }

    /// Assigns one frame per face. Updates are deliberately ordered from the
    /// highest face index down so ties and neighborhood propagation are stable.
    public static func assignFrames(
        candidatesByFace: [[RoomMeshFaceCandidate]],
        faceNeighbors: [[Int]]
    ) -> [Int?] {
        var assignments: [Int?] = candidatesByFace.map { candidates in
            bestCandidate(candidates)?.frameIndex
        }
        let positiveScores = candidatesByFace.flatMap { $0.map(\.score) }.filter { $0 > 0 }.sorted()
        let medianScore = median(positiveScores)
        guard medianScore > 0 else { return assignments }

        for _ in 0..<coherencePassCount {
            for faceIndex in candidatesByFace.indices.reversed() {
                let neighbors = faceIndex < faceNeighbors.count ? faceNeighbors[faceIndex] : []
                var best: RoomMeshFaceCandidate?
                var bestObjective = -Double.infinity
                for candidate in candidatesByFace[faceIndex] where candidate.score > 0 {
                    let changed = neighbors.reduce(into: 0) { count, neighbor in
                        guard assignments.indices.contains(neighbor) else { return }
                        if assignments[neighbor] != candidate.frameIndex { count += 1 }
                    }
                    let objective = candidate.score
                        - coherencePenaltyScale * medianScore * Double(changed)
                    if objective > bestObjective
                        || (objective == bestObjective && candidate.frameIndex < (best?.frameIndex ?? .max)) {
                        best = candidate
                        bestObjective = objective
                    }
                }
                assignments[faceIndex] = best?.frameIndex
            }
        }
        return assignments
    }

    /// Duplicates vertices only when original index, UV, or material validity differs.
    public static func expandSeams(
        mesh: RoomMeshPLYMesh,
        faceUVs: [[SIMD2<Float>]?]
    ) -> RoomMeshPhotorealMesh {
        struct Key: Hashable {
            var source: UInt32
            var uBits: UInt32
            var vBits: UInt32
            var valid: UInt8
        }
        var output = RoomMeshPhotorealMesh(
            vertices: [], normals: [], fallbackColors: [], uvs: [], textureValid: [], faces: []
        )
        var map: [Key: UInt32] = [:]
        let hasNormals = mesh.normals.count == mesh.vertices.count
        let hasColors = mesh.colors.count == mesh.vertices.count
        let faceCount = mesh.faces.count / 3
        output.faces.reserveCapacity(mesh.faces.count)

        for faceIndex in 0..<faceCount {
            let providedUVs = faceIndex < faceUVs.count ? faceUVs[faceIndex] : nil
            let valid: UInt8 = providedUVs?.count == 3 ? 1 : 0
            for corner in 0..<3 {
                let source = mesh.faces[faceIndex * 3 + corner]
                guard Int(source) < mesh.vertices.count else { continue }
                let uv = valid == 1 ? providedUVs![corner] : .zero
                let key = Key(source: source, uBits: uv.x.bitPattern, vBits: uv.y.bitPattern, valid: valid)
                let destination: UInt32
                if let existing = map[key] {
                    destination = existing
                } else {
                    destination = UInt32(output.vertices.count)
                    map[key] = destination
                    output.vertices.append(mesh.vertices[Int(source)])
                    if hasNormals { output.normals.append(mesh.normals[Int(source)]) }
                    output.fallbackColors.append(
                        hasColors ? mesh.colors[Int(source)] : RoomMeshKeyframeColorizer.uncoloredGray
                    )
                    output.uvs.append(uv)
                    output.textureValid.append(valid)
                }
                output.faces.append(destination)
            }
        }
        return output
    }

    /// Deterministic skyline/shelf packing. Returned x/y address chart content;
    /// each allocation reserves `padding` texels on all sides.
    public static func pack<S: Sequence>(
        charts: S,
        atlasSize: Int,
        padding: Int = atlasPadding
    ) -> [RoomMeshChartPlacement] where S.Element == RoomMeshChartRequest {
        guard atlasSize > 0, padding >= 0 else { return [] }
        let sorted = charts.sorted {
            let lhsArea = $0.width * $0.height
            let rhsArea = $1.width * $1.height
            if lhsArea != rhsArea { return lhsArea > rhsArea }
            if $0.frameIndex != $1.frameIndex { return $0.frameIndex < $1.frameIndex }
            if $0.firstFaceIndex != $1.firstFaceIndex { return $0.firstFaceIndex < $1.firstFaceIndex }
            return $0.id < $1.id
        }
        var x = 0, y = 0, rowHeight = 0
        var result: [RoomMeshChartPlacement] = []
        for chart in sorted {
            let allocatedWidth = chart.width + padding * 2
            let allocatedHeight = chart.height + padding * 2
            guard allocatedWidth <= atlasSize, allocatedHeight <= atlasSize else { continue }
            if x + allocatedWidth > atlasSize {
                x = 0
                y += rowHeight
                rowHeight = 0
            }
            guard y + allocatedHeight <= atlasSize else { continue }
            result.append(RoomMeshChartPlacement(
                id: chart.id,
                x: x + padding,
                y: y + padding,
                width: chart.width,
                height: chart.height
            ))
            x += allocatedWidth
            rowHeight = max(rowHeight, allocatedHeight)
        }
        return result.sorted { $0.id < $1.id }
    }

    /// Chart-aware nearest-neighbor dilation for mip-safe padding.
    public static func dilate(
        linearPixels: inout [SIMD3<Double>],
        owners: inout [Int],
        width: Int,
        height: Int,
        iterations: Int
    ) {
        guard width > 0, height > 0, linearPixels.count == width * height,
              owners.count == linearPixels.count, iterations > 0 else { return }
        let offsets = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        for _ in 0..<iterations {
            let sourcePixels = linearPixels
            let sourceOwners = owners
            var changed = false
            for y in 0..<height {
                for x in 0..<width {
                    let index = y * width + x
                    guard sourceOwners[index] < 0 else { continue }
                    var selected: (owner: Int, color: SIMD3<Double>)?
                    for (dx, dy) in offsets {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let neighbor = ny * width + nx
                        let owner = sourceOwners[neighbor]
                        guard owner >= 0 else { continue }
                        if selected == nil || owner < selected!.owner {
                            selected = (owner, sourcePixels[neighbor])
                        }
                    }
                    if let selected {
                        owners[index] = selected.owner
                        linearPixels[index] = selected.color
                        changed = true
                    }
                }
            }
            if !changed { break }
        }
    }

    /// Compact chart-aware dilation for production atlases. Linear channels
    /// are stored as normalized UInt16 values and only the active frontier is
    /// retained between passes, avoiding full-atlas snapshots per iteration.
    @discardableResult
    public static func dilateLinearUInt16(
        pixels: inout [UInt16],
        owners: inout [Int32],
        width: Int,
        height: Int,
        iterations: Int,
        onProgress: ((Int, Int) -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) -> Bool {
        guard width > 0, height > 0,
              width <= Int.max / height,
              owners.count == width * height,
              owners.count <= Int.max / 3,
              pixels.count == owners.count * 3,
              iterations > 0 else { return true }

        func neighbors(of index: Int, _ body: (Int) -> Void) {
            let x = index % width
            let y = index / width
            if x > 0 { body(index - 1) }
            if x + 1 < width { body(index + 1) }
            if y > 0 { body(index - width) }
            if y + 1 < height { body(index + width) }
        }

        var frontier: [Int] = []
        frontier.reserveCapacity(min(owners.count, 16_384))
        let totalWork = height + iterations
        for y in 0..<height {
            if isCancelled() { return false }
            for x in 0..<width {
                let index = y * width + x
                guard owners[index] >= 0 else { continue }
                var bordersEmpty = false
                neighbors(of: index) { neighbor in
                    if owners[neighbor] < 0 { bordersEmpty = true }
                }
                if bordersEmpty { frontier.append(index) }
            }
            onProgress?(y + 1, totalWork)
        }

        for iteration in 0..<iterations {
            if isCancelled() { return false }
            var pending: [Int: (owner: Int32, source: Int)] = [:]
            pending.reserveCapacity(frontier.count * 2)
            for (offset, source) in frontier.sorted().enumerated() {
                if offset.isMultiple(of: 1_024), isCancelled() { return false }
                let owner = owners[source]
                guard owner >= 0 else { continue }
                neighbors(of: source) { destination in
                    guard owners[destination] < 0 else { return }
                    if let current = pending[destination],
                       current.owner < owner || (current.owner == owner && current.source <= source) {
                        return
                    }
                    pending[destination] = (owner, source)
                }
            }
            if pending.isEmpty {
                onProgress?(totalWork, totalWork)
                return true
            }
            frontier = pending.keys.sorted()
            for (offset, destination) in frontier.enumerated() {
                if offset.isMultiple(of: 1_024), isCancelled() { return false }
                guard let selected = pending[destination] else { continue }
                owners[destination] = selected.owner
                let sourceOffset = selected.source * 3
                let destinationOffset = destination * 3
                pixels[destinationOffset] = pixels[sourceOffset]
                pixels[destinationOffset + 1] = pixels[sourceOffset + 1]
                pixels[destinationOffset + 2] = pixels[sourceOffset + 2]
            }
            onProgress?(height + iteration + 1, totalWork)
        }
        return true
    }

    private static func bestCandidate(_ candidates: [RoomMeshFaceCandidate]) -> RoomMeshFaceCandidate? {
        candidates.filter { $0.score > 0 && $0.score.isFinite }.max {
            if $0.score != $1.score { return $0.score < $1.score }
            return $0.frameIndex > $1.frameIndex
        }
    }

    private static func signedArea(_ points: [SIMD2<Double>]) -> Double {
        guard points.count == 3 else { return 0 }
        return (points[1].x - points[0].x) * (points[2].y - points[0].y)
            - (points[1].y - points[0].y) * (points[2].x - points[0].x)
    }

    private static func compatibleAcrossSharedEdge(
        _ lhs: RoomMeshProjectedFace,
        _ rhs: RoomMeshProjectedFace,
        shared: [UInt32]
    ) -> Bool {
        let lhsArea = signedArea(lhs.pixels)
        let rhsArea = signedArea(rhs.pixels)
        guard lhsArea * rhsArea > 0 else { return false }
        func point(_ vertex: UInt32, in face: RoomMeshProjectedFace) -> SIMD2<Double>? {
            face.vertexIndices.firstIndex(of: vertex).map { face.pixels[$0] }
        }
        guard let edgeA = point(shared[0], in: lhs),
              let edgeB = point(shared[1], in: lhs),
              let lhsOppositeIndex = lhs.vertexIndices.firstIndex(where: { !shared.contains($0) }),
              let rhsOppositeIndex = rhs.vertexIndices.firstIndex(where: { !shared.contains($0) }) else {
            return false
        }
        let lhsSide = edge(edgeA, edgeB, lhs.pixels[lhsOppositeIndex])
        let rhsSide = edge(edgeA, edgeB, rhs.pixels[rhsOppositeIndex])
        // Opposite vertices on the same side indicate interior overlap beyond
        // the shared edge and must start separate charts.
        return lhsSide * rhsSide < -1e-12
    }

    private static func edge(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ point: SIMD2<Double>) -> Double {
        (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
    }

    private static func median(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        if sorted.count.isMultiple(of: 2) {
            return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        return sorted[sorted.count / 2]
    }
}
