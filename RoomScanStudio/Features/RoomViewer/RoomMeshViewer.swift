import ImageIO
import MetalKit
import RoomScanCore
import SwiftUI

/// Photoreal roadmap sequencing step 3 (docs/PHOTOREAL_ROADMAP.md): render the
/// capture bundle's LiDAR scene mesh with per-vertex colors projected from the
/// bundle's posed keyframes. This is the visible photoreal payoff for rooms
/// that have a capture bundle but no trained splat yet; the semantic
/// bounding-box viewer remains the fallback for rooms without a bundle.

// MARK: - Bundle loading + colorization

struct RoomMeshColoredResult: @unchecked Sendable {
    var mesh: RoomMeshPLYMesh
    var photorealMesh: RoomMeshPhotorealMesh
    var atlasPNG: Data?
    var keyframeCount: Int
    var boundsMin: SIMD3<Float>
    var boundsMax: SIMD3<Float>
    var usedCachedColors: Bool
    var warnings: [RoomMeshColoringWarning]
}

enum RoomMeshViewerError: LocalizedError {
    case bundleMissing
    case meshUnreadable(String)
    case metalUnavailable

    var errorDescription: String? {
        switch self {
        case .bundleMissing:
            return "This room has no capture bundle with a scene mesh."
        case let .meshUnreadable(detail):
            return "The scene mesh could not be read: \(detail)"
        case .metalUnavailable:
            return "Metal rendering is unavailable on this device."
        }
    }
}

enum RoomMeshBundleLoader {
    /// Retained only as a legacy export/splat seed name; never accepted as v3 viewer cache.
    static let coloredMeshFileName = "scene-mesh-colored.ply"
    private static let analysisImageMaxPixelSize = 1_024
    private static let settings = RoomMeshPhotorealSettings()

    private struct FramePass {
        var frame: RoomCaptureBundleFrame
        var normalizedSharpness: Double
        var visibleVertices: [Bool]
        var vertexScores: [Double]
        var visibleFaceCentroids: [Bool]
        var projectedSensorPixels: [SIMD2<Double>?]
        var photometricLogGain: SIMD3<Double>
        var isPhotometricallyConnected: Bool
    }

    private struct FaceChart {
        struct Face {
            var faceIndex: Int
            var sourcePixels: [SIMD2<Double>]
        }
        var id: Int
        var frameIndex: Int
        var faces: [Face]
        var minX: Double
        var minY: Double
        var request: RoomMeshChartRequest
    }

    /// Cheap room-profile gate: a renderable bundle mesh exists.
    static func hasRenderableMesh(forProject projectID: String) -> Bool {
        guard let directory = RoomCaptureBundleLibrary.bundleDirectory(forProject: projectID) else {
            return false
        }
        let meshURL = directory.appendingPathComponent(RoomCaptureBundleLibrary.sceneMeshFileName)
        return FileManager.default.fileExists(atPath: meshURL.path)
    }

    /// Relaunch recovery oracle: validates the complete v3 cache against the
    /// immutable source evidence without decoding any capture image.
    static func hasValidPhotorealCache(forProject projectID: String) -> Bool {
        guard let directory = RoomCaptureBundleLibrary.bundleDirectory(forProject: projectID),
              let manifest = RoomCaptureBundleLibrary.manifest(forProject: projectID),
              let meshData = try? Data(contentsOf: directory.appendingPathComponent(
                RoomCaptureBundleLibrary.sceneMeshFileName
              )),
              let bundleManifestData = try? Data(contentsOf: directory.appendingPathComponent(
                RoomCaptureBundleLibrary.manifestFileName
              )),
              let cacheData = try? Data(contentsOf: directory.appendingPathComponent(
                RoomMeshPhotorealCache.manifestFileName
              )),
              let cacheManifest = try? RoomJSONCoding.makeDecoder().decode(
                RoomMeshPhotorealCacheManifest.self,
                from: cacheData
              ),
              RoomMeshPhotorealCache.isValid(
                cacheManifest,
                sourceMeshSHA256: RoomSHA256.hexDigest(of: meshData),
                bundleManifestSHA256: RoomSHA256.hexDigest(of: bundleManifestData),
                sourceFrames: frameFingerprints(manifest: manifest, bundleDirectory: directory),
                settings: settings,
                fileExists: { name in
                    FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
                }
              ),
              let cachedMeshData = try? Data(contentsOf: directory.appendingPathComponent(
                RoomMeshPhotorealCache.meshFileName
              )),
              let cachedMesh = try? RoomMeshPhotorealPLY.read(cachedMeshData),
              !cachedMesh.vertices.isEmpty else {
            return false
        }
        return true
    }

    /// Loads the bundle mesh with per-vertex colors, computing and caching the
    /// colorization on first open. CPU-heavy; call from a background task.
    static func load(
        forProject projectID: String,
        progress: RoomMeshProgressReporter.Sink? = nil
    ) throws -> RoomMeshColoredResult {
        let started = Date()
        let reporter = RoomMeshProgressReporter(sink: progress)
        let result = try loadUntimed(forProject: projectID, reporter: reporter)
        let coloredCount = result.mesh.colors.filter { $0 != RoomMeshKeyframeColorizer.uncoloredGray }.count
        print(String(
            format: "RoomScanStudio colored mesh: %d vertices, %d colored (%.0f%%), %d keyframes, cached=%@, %.1fs",
            result.mesh.vertices.count,
            coloredCount,
            result.mesh.vertices.isEmpty
                ? 0 : 100 * Double(coloredCount) / Double(result.mesh.vertices.count),
            result.keyframeCount,
            result.usedCachedColors ? "true" : "false",
            Date().timeIntervalSince(started)
        ))
        return result
    }

    private static func loadUntimed(
        forProject projectID: String,
        reporter: RoomMeshProgressReporter
    ) throws -> RoomMeshColoredResult {
        reporter.report(phase: .preparing, completed: 0, total: 4, detail: "Locating capture bundle")
        try Task.checkCancellation()
        guard let directory = RoomCaptureBundleLibrary.bundleDirectory(forProject: projectID) else {
            throw RoomMeshViewerError.bundleMissing
        }
        reporter.report(phase: .preparing, completed: 1, total: 4, detail: "Reading source mesh")

        let manifest = RoomCaptureBundleLibrary.manifest(forProject: projectID)
        let keyframeCount = manifest?.frames.count ?? 0
        let meshURL = directory.appendingPathComponent(RoomCaptureBundleLibrary.sceneMeshFileName)
        let bundleManifestURL = directory.appendingPathComponent(RoomCaptureBundleLibrary.manifestFileName)
        let meshData: Data
        do {
            meshData = try Data(contentsOf: meshURL)
        } catch {
            throw RoomMeshViewerError.bundleMissing
        }
        var mesh: RoomMeshPLYMesh
        do {
            mesh = try RoomMeshBinaryPLY.read(meshData)
        } catch {
            throw RoomMeshViewerError.meshUnreadable(String(describing: error))
        }
        guard !mesh.vertices.isEmpty else {
            throw RoomMeshViewerError.meshUnreadable("the scene mesh contains no vertices")
        }
        reporter.report(phase: .preparing, completed: 2, total: 4, detail: "Fingerprinting source evidence")
        try Task.checkCancellation()

        let sourceMeshHash = RoomSHA256.hexDigest(of: meshData)
        let bundleManifestData = (try? Data(contentsOf: bundleManifestURL)) ?? Data()
        let bundleManifestHash = RoomSHA256.hexDigest(of: bundleManifestData)
        let sourceFrames = frameFingerprints(manifest: manifest, bundleDirectory: directory)
        reporter.report(phase: .preparing, completed: 3, total: 4, detail: "Checking derived cache")
        let cacheManifestURL = directory.appendingPathComponent(RoomMeshPhotorealCache.manifestFileName)
        if let data = try? Data(contentsOf: cacheManifestURL),
           let cachedManifest = try? RoomJSONCoding.makeDecoder().decode(
               RoomMeshPhotorealCacheManifest.self,
               from: data
           ),
           RoomMeshPhotorealCache.isValid(
               cachedManifest,
               sourceMeshSHA256: sourceMeshHash,
               bundleManifestSHA256: bundleManifestHash,
               sourceFrames: sourceFrames,
               settings: settings,
               fileExists: { name in
                   FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
               }
           ),
           let cachedMeshData = try? Data(contentsOf: directory.appendingPathComponent(
               RoomMeshPhotorealCache.meshFileName
           )),
           let cachedMesh = try? RoomMeshPhotorealPLY.read(cachedMeshData),
           !cachedMesh.vertices.isEmpty {
            reporter.report(phase: .preparing, completed: 4, total: 4, detail: "Using cached colored mesh")
            completeSkippedDerivationPhases(reporter: reporter)
            let atlas = cachedManifest.coveredFaceCount > 0
                ? try? Data(contentsOf: directory.appendingPathComponent(RoomMeshPhotorealCache.atlasFileName))
                : nil
            return makeResult(
                photorealMesh: cachedMesh,
                atlasPNG: atlas,
                keyframeCount: keyframeCount,
                usedCachedColors: true,
                warnings: []
            )
        }

        reporter.report(phase: .preparing, completed: 4, total: 4, detail: "Building colored mesh")
        let built = try buildPhotoreal(
            mesh: mesh,
            manifest: manifest,
            bundleDirectory: directory,
            reporter: reporter
        )
        let cacheManifest = RoomMeshPhotorealCacheManifest(
            algorithmVersion: RoomMeshPhotorealCache.algorithmVersion,
            sourceMeshSHA256: sourceMeshHash,
            bundleManifestSHA256: bundleManifestHash,
            sourceFrames: sourceFrames,
            atlasSize: built.atlasSize,
            coveredFaceCount: built.coveredFaceCount,
            coveredAreaEstimate: mesh.faces.isEmpty
                ? 0 : Double(built.coveredFaceCount) / Double(mesh.faces.count / 3),
            colorSpaceTag: "sRGB",
            settings: settings
        )
        var warnings = built.warnings
        if try !publishCacheBestEffort(
            mesh: built.mesh,
            atlasPNG: built.atlasPNG,
            manifest: cacheManifest,
            directory: directory,
            reporter: reporter
        ) {
            warnings.append(.cacheNotSaved)
        }
        return makeResult(
            photorealMesh: built.mesh,
            atlasPNG: built.atlasPNG,
            keyframeCount: keyframeCount,
            usedCachedColors: false,
            warnings: warnings
        )
    }

    private static func makeResult(
        photorealMesh: RoomMeshPhotorealMesh,
        atlasPNG: Data?,
        keyframeCount: Int,
        usedCachedColors: Bool,
        warnings: [RoomMeshColoringWarning]
    ) -> RoomMeshColoredResult {
        let mesh = RoomMeshPLYMesh(
            vertices: photorealMesh.vertices,
            normals: photorealMesh.normals,
            colors: photorealMesh.fallbackColors,
            faces: photorealMesh.faces
        )
        var minBounds = mesh.vertices[0]
        var maxBounds = mesh.vertices[0]
        for vertex in mesh.vertices {
            minBounds = SIMD3<Float>(
                min(minBounds.x, vertex.x), min(minBounds.y, vertex.y), min(minBounds.z, vertex.z)
            )
            maxBounds = SIMD3<Float>(
                max(maxBounds.x, vertex.x), max(maxBounds.y, vertex.y), max(maxBounds.z, vertex.z)
            )
        }
        return RoomMeshColoredResult(
            mesh: mesh,
            photorealMesh: photorealMesh,
            atlasPNG: atlasPNG,
            keyframeCount: keyframeCount,
            boundsMin: minBounds,
            boundsMax: maxBounds,
            usedCachedColors: usedCachedColors,
            warnings: warnings
        )
    }

    private static func completeSkippedDerivationPhases(reporter: RoomMeshProgressReporter) {
        for phase in RoomMeshColoringPhase.allCases
            where phase != .preparing && phase != .preparingRenderer {
            reporter.report(phase: phase, completed: 1, total: 1, detail: "Already cached")
        }
    }

    private static func buildPhotoreal(
        mesh: RoomMeshPLYMesh,
        manifest: RoomCaptureBundleManifest?,
        bundleDirectory: URL,
        reporter: RoomMeshProgressReporter
    ) throws -> (
        mesh: RoomMeshPhotorealMesh,
        atlasPNG: Data?,
        atlasSize: Int,
        coveredFaceCount: Int,
        warnings: [RoomMeshColoringWarning]
    ) {
        guard let manifest, !manifest.frames.isEmpty else {
            for phase in [
                RoomMeshColoringPhase.measuringSharpness,
                .projectingColors,
                .normalizingColors,
                .assigningFaces,
                .packingCharts,
                .bakingAtlas,
                .fillingPadding,
            ] {
                reporter.report(phase: phase, completed: 1, total: 1, detail: "Using neutral fallback")
            }
            reporter.report(phase: .publishingCache, completed: 2, total: 4, detail: "No atlas to encode")
            var fallback = mesh
            fallback.colors = Array(repeating: RoomMeshKeyframeColorizer.uncoloredGray, count: mesh.vertices.count)
            return (
                RoomMeshTextureBaker.expandSeams(
                    mesh: fallback,
                    faceUVs: Array(repeating: nil, count: mesh.faces.count / 3)
                ),
                nil, 0, 0, [.unusableManifest]
            )
        }
        let framesDirectory = bundleDirectory.appendingPathComponent(
            RoomCaptureBundleLibrary.framesSubdirectoryName,
            isDirectory: true
        )
        var warnings: [RoomMeshColoringWarning] = []
        var unreadableFrameNames: Set<String> = []
        var malformedDepthCount = 0
        var rawSharpness: [Double] = []
        for (frameIndex, frame) in manifest.frames.enumerated() {
            try Task.checkCancellation()
            let imageURL = framesDirectory.appendingPathComponent(frame.fileName)
            guard let image = decodeRGBA(at: imageURL, maximumPixelSize: analysisImageMaxPixelSize) else {
                unreadableFrameNames.insert(frame.fileName)
                rawSharpness.append(0)
                reporter.report(
                    phase: .measuringSharpness,
                    completed: frameIndex + 1,
                    total: manifest.frames.count,
                    detail: "Photo \(frameIndex + 1) of \(manifest.frames.count)"
                )
                continue
            }
            rawSharpness.append(RoomMeshFrameAnalysis.luminanceSharpness(
                rgba: image.rgba,
                width: image.width,
                height: image.height
            ))
            reporter.report(
                phase: .measuringSharpness,
                completed: frameIndex + 1,
                total: manifest.frames.count,
                detail: "Photo \(frameIndex + 1) of \(manifest.frames.count)"
            )
        }
        while rawSharpness.count < manifest.frames.count { rawSharpness.append(0) }
        let sharpness = RoomMeshFrameAnalysis.normalizedSharpness(rawSharpness)
        var vertexCandidates = [[RoomMeshColorCandidate]](repeating: [], count: mesh.vertices.count)
        var passes: [FramePass] = []
        var photometricSamplesByPass: [[RoomMeshPhotometricSample]] = []
        let faceCount = mesh.faces.count / 3
        let faceCentroidsAndNormals: [(SIMD3<Float>, SIMD3<Float>)] = (0..<faceCount).map { faceIndex in
            let indices = (0..<3).map { Int(mesh.faces[faceIndex * 3 + $0]) }
            guard indices.allSatisfy(mesh.vertices.indices.contains) else { return (.zero, .zero) }
            let a = mesh.vertices[indices[0]], b = mesh.vertices[indices[1]], c = mesh.vertices[indices[2]]
            let centroid = (a + b + c) / 3
            let cross = simd_cross(b - a, c - a)
            let length = simd_length(cross)
            return (centroid, length > 1e-6 ? cross / length : .zero)
        }
        let analysisVertices = mesh.vertices + faceCentroidsAndNormals.map(\.0)
        let analysisNormals: [SIMD3<Float>]
        if mesh.normals.count == mesh.vertices.count {
            analysisNormals = mesh.normals + faceCentroidsAndNormals.map(\.1)
        } else {
            analysisNormals = []
        }

        for (frameIndex, frame) in manifest.frames.enumerated() {
            try Task.checkCancellation()
            let imageURL = framesDirectory.appendingPathComponent(frame.fileName)
            guard let image = decodeRGBA(at: imageURL, maximumPixelSize: analysisImageMaxPixelSize) else {
                unreadableFrameNames.insert(frame.fileName)
                reporter.report(
                    phase: .projectingColors,
                    completed: frameIndex + 1,
                    total: manifest.frames.count,
                    detail: "Photo \(frameIndex + 1) of \(manifest.frames.count)"
                )
                continue
            }
            let depth = decodeDepth(frame: frame, framesDirectory: framesDirectory)
            if frame.depth != nil, depth == nil { malformedDepthCount += 1 }
            let sample = RoomMeshKeyframeSample(
                cameraToWorldColumnMajor: frame.cameraTransform,
                intrinsicsColumnMajor: frame.intrinsics,
                sensorWidth: frame.imageWidth,
                sensorHeight: frame.imageHeight,
                imageWidth: image.width,
                imageHeight: image.height,
                imageRGBA: image.rgba,
                depthWidth: depth?.width ?? 0,
                depthHeight: depth?.height ?? 0,
                depthMeters: depth?.depthMeters ?? [],
                confidence: depth?.confidence ?? [],
                normalizedSharpness: sharpness[frameIndex]
            )
            let colored = RoomMeshKeyframeColorizer.colorize(
                vertices: analysisVertices,
                normals: analysisNormals,
                faces: mesh.faces,
                keyframes: [sample]
            )
            let passIndex = passes.count
            var calibrationSamples: [RoomMeshPhotometricSample] = []
            calibrationSamples.reserveCapacity(min(mesh.vertices.count, RoomMeshFrameAnalysis.maximumCalibrationSamplesPerFrame))
            for vertex in mesh.vertices.indices where colored.coloredVertices[vertex] {
                let color = colored.colors[vertex]
                guard let linear = colored.linearColors[vertex] else { continue }
                vertexCandidates[vertex].append(RoomMeshColorCandidate(
                    linearRGB: linear,
                    score: colored.selectedScores[vertex],
                    frameIndex: passIndex
                ))
                let saturated = color.x <= 1 || color.x >= 254
                    || color.y <= 1 || color.y >= 254
                    || color.z <= 1 || color.z >= 254
                if !saturated,
                   calibrationSamples.count < RoomMeshFrameAnalysis.maximumCalibrationSamplesPerFrame {
                    calibrationSamples.append(.init(sampleID: vertex, linearRGB: linear))
                }
            }
            var projections = [SIMD2<Double>?](repeating: nil, count: mesh.vertices.count)
            if let camera = RoomMeshProjection.Camera(
                cameraToWorldColumnMajor: frame.cameraTransform,
                intrinsicsColumnMajor: frame.intrinsics,
                sensorWidth: frame.imageWidth,
                sensorHeight: frame.imageHeight
            ) {
                for vertex in mesh.vertices.indices {
                    let world = SIMD3<Double>(
                        Double(mesh.vertices[vertex].x),
                        Double(mesh.vertices[vertex].y),
                        Double(mesh.vertices[vertex].z)
                    )
                    if let projected = camera.project(world: world), camera.containsSensorPixel(projected.pixel) {
                        projections[vertex] = projected.pixel
                    }
                }
            }
            passes.append(FramePass(
                frame: frame,
                normalizedSharpness: sharpness[frameIndex],
                visibleVertices: Array(colored.coloredVertices.prefix(mesh.vertices.count)),
                vertexScores: Array(colored.selectedScores.prefix(mesh.vertices.count)),
                visibleFaceCentroids: Array(colored.coloredVertices.dropFirst(mesh.vertices.count)),
                projectedSensorPixels: projections,
                photometricLogGain: .zero,
                isPhotometricallyConnected: false
            ))
            photometricSamplesByPass.append(calibrationSamples)
            reporter.report(
                phase: .projectingColors,
                completed: frameIndex + 1,
                total: manifest.frames.count,
                detail: "Photo \(frameIndex + 1) of \(manifest.frames.count)"
            )
        }

        if !unreadableFrameNames.isEmpty {
            warnings.append(.unreadableKeyframes(unreadableFrameNames.count))
        }
        if malformedDepthCount > 0 {
            warnings.append(.malformedDepthPayloads(malformedDepthCount))
        }
        if passes.isEmpty {
            warnings.append(.unusableManifest)
        }

        try Task.checkCancellation()
        let calibration = RoomMeshFrameAnalysis.solvePhotometricCalibration(
            samplesByFrame: photometricSamplesByPass,
            normalizedSharpness: passes.map(\.normalizedSharpness)
        )
        for passIndex in passes.indices where passIndex < calibration.frames.count {
            passes[passIndex].photometricLogGain = calibration.frames[passIndex].logGain
            passes[passIndex].isPhotometricallyConnected = calibration.frames[passIndex].isConnected
        }
        reporter.report(phase: .normalizingColors, completed: 1, total: 3, detail: "Solved photo overlap")
        for vertex in vertexCandidates.indices {
            if vertex.isMultiple(of: 4_096) { try Task.checkCancellation() }
            vertexCandidates[vertex] = vertexCandidates[vertex].map { candidate in
                guard passes.indices.contains(candidate.frameIndex) else { return candidate }
                let pass = passes[candidate.frameIndex]
                let gain = SIMD3<Double>(
                    exp(pass.photometricLogGain.x),
                    exp(pass.photometricLogGain.y),
                    exp(pass.photometricLogGain.z)
                )
                return RoomMeshColorCandidate(
                    linearRGB: candidate.linearRGB * gain,
                    score: candidate.score * (pass.isPhotometricallyConnected ? 1 : 0.75),
                    frameIndex: candidate.frameIndex
                )
            }
        }
        reporter.report(phase: .normalizingColors, completed: 2, total: 3, detail: "Balanced visible colors")

        var fallback = mesh
        let selectedLinear = vertexCandidates.map { candidates in
            RoomMeshFrameAnalysis.bestInlier(from: candidates)?.linearRGB
        }
        let filled = RoomMeshCoverageFiller.fill(
            positions: mesh.vertices,
            normals: mesh.normals,
            faces: mesh.faces,
            colors: selectedLinear
        )
        fallback.colors = selectedLinear.indices.map { index in
            let color = filled.indices.contains(index) ? filled[index].linearRGB : selectedLinear[index]
            return color.map(RoomMeshColor.encode) ?? RoomMeshKeyframeColorizer.uncoloredGray
        }
        reporter.report(phase: .normalizingColors, completed: 3, total: 3, detail: "Completed fallback colors")

        var candidatesByFace = [[RoomMeshFaceCandidate]](repeating: [], count: faceCount)
        var uvByFaceFrame = [[Int: [SIMD2<Double>]]](repeating: [:], count: faceCount)
        for faceIndex in 0..<faceCount {
            if faceIndex.isMultiple(of: 128) { try Task.checkCancellation() }
            defer {
                if (faceIndex + 1).isMultiple(of: 128) || faceIndex + 1 == faceCount {
                    reporter.report(
                        phase: .assigningFaces,
                        completed: faceIndex + 1,
                        total: max(faceCount, 1),
                        detail: "Face \(faceIndex + 1) of \(faceCount)"
                    )
                }
            }
            let indices = (0..<3).map { Int(mesh.faces[faceIndex * 3 + $0]) }
            guard indices.allSatisfy({ mesh.vertices.indices.contains($0) }) else { continue }
            for (passIndex, pass) in passes.enumerated() {
                let projected = indices.compactMap { pass.projectedSensorPixels[$0] }
                guard projected.count == 3 else { continue }
                let area = abs(edge(projected[0], projected[1], projected[2]))
                guard area >= 1 else { continue }
                let aggregateVertexScore = indices.reduce(0) { $0 + pass.vertexScores[$1] } / 3
                let score = aggregateVertexScore * sqrt(area)
                    * (pass.isPhotometricallyConnected ? 1 : 0.75)
                guard let candidate = RoomMeshTextureBaker.faceCandidate(
                    frameIndex: passIndex,
                    vertexVisibility: indices.map { pass.visibleVertices[$0] },
                    centroidVisible: pass.visibleFaceCentroids.indices.contains(faceIndex)
                        && pass.visibleFaceCentroids[faceIndex],
                    score: score
                ) else { continue }
                candidatesByFace[faceIndex].append(candidate)
                uvByFaceFrame[faceIndex][passIndex] = projected
            }
        }
        if faceCount == 0 {
            reporter.report(phase: .assigningFaces, completed: 1, total: 1, detail: "No mesh faces")
        }
        try Task.checkCancellation()
        let neighbors = faceNeighbors(faces: mesh.faces, faceCount: faceCount)
        reporter.report(phase: .packingCharts, completed: 1, total: 3, detail: "Built face neighborhoods")
        var assignments = RoomMeshTextureBaker.assignFrames(
            candidatesByFace: candidatesByFace,
            faceNeighbors: neighbors
        )
        let charts = makeCharts(
            assignments: assignments,
            uvByFaceFrame: uvByFaceFrame,
            meshFaces: mesh.faces
        )
        reporter.report(phase: .packingCharts, completed: 2, total: 3, detail: "Constructed coherent charts")
        guard !charts.isEmpty else {
            reporter.report(phase: .packingCharts, completed: 3, total: 3, detail: "No texture charts")
            reporter.report(phase: .bakingAtlas, completed: 1, total: 1, detail: "Using vertex colors")
            reporter.report(phase: .fillingPadding, completed: 1, total: 1, detail: "No atlas padding needed")
            reporter.report(phase: .publishingCache, completed: 2, total: 4, detail: "No atlas to encode")
            return (
                RoomMeshTextureBaker.expandSeams(
                    mesh: fallback,
                    faceUVs: Array(repeating: nil, count: faceCount)
                ),
                nil, 0, 0, warnings
            )
        }
        var atlasSize = 256
        var placements: [RoomMeshChartPlacement] = []
        var atlasScale = 1.0
        while atlasSize <= settings.atlasMaxDimension {
            placements = RoomMeshTextureBaker.pack(
                charts: charts.map(\.request),
                atlasSize: atlasSize,
                padding: settings.atlasPadding
            )
            if placements.count == charts.count { break }
            atlasSize *= 2
        }
        if atlasSize > settings.atlasMaxDimension {
            atlasSize = settings.atlasMaxDimension
            if let scaled = RoomMeshTextureBaker.packAtGreatestScale(
                charts: charts.map(\.request),
                atlasSize: atlasSize,
                padding: settings.atlasPadding
            ) {
                placements = scaled.placements
                atlasScale = scaled.scale
            } else {
                placements = RoomMeshTextureBaker.pack(
                    charts: charts.map(\.request), atlasSize: atlasSize, padding: settings.atlasPadding
                )
            }
        }
        if placements.count != charts.count {
            let placedIDs = Set(placements.map(\.id))
            for chart in charts where !placedIDs.contains(chart.id) {
                for face in chart.faces { assignments[face.faceIndex] = nil }
            }
            atlasSize = placements.isEmpty ? 0 : atlasSize
        }
        reporter.report(phase: .packingCharts, completed: 3, total: 3, detail: "Packed texture charts")
        let placementByID = Dictionary(uniqueKeysWithValues: placements.map { ($0.id, $0) })
        var faceUVs = [[SIMD2<Float>]?](repeating: nil, count: faceCount)
        for chart in charts {
            guard let placement = placementByID[chart.id], atlasSize > 0 else {
                continue
            }
            for face in chart.faces where assignments[face.faceIndex] != nil {
                faceUVs[face.faceIndex] = face.sourcePixels.map { point in
                    SIMD2<Float>(
                        Float((Double(placement.x) + (point.x - chart.minX) * atlasScale) / Double(atlasSize)),
                        Float((Double(placement.y) + (point.y - chart.minY) * atlasScale) / Double(atlasSize))
                    )
                }
            }
        }
        let atlasPNG = atlasSize > 0
            ? try bakeAtlas(
                atlasSize: atlasSize,
                charts: charts,
                placements: placementByID,
                atlasScale: atlasScale,
                passes: passes,
                framesDirectory: framesDirectory,
                reporter: reporter
            )
            : nil
        if atlasPNG == nil {
            faceUVs = Array(repeating: nil, count: faceCount)
            warnings.append(.atlasFallback)
            reporter.report(phase: .bakingAtlas, completed: 1, total: 1, detail: "Using vertex-color fallback")
            reporter.report(phase: .fillingPadding, completed: 1, total: 1, detail: "No atlas padding available")
            reporter.report(phase: .publishingCache, completed: 2, total: 4, detail: "No atlas to encode")
        }
        let expanded = RoomMeshTextureBaker.expandSeams(mesh: fallback, faceUVs: faceUVs)
        return (
            expanded,
            atlasPNG,
            atlasPNG == nil ? 0 : atlasSize,
            atlasPNG == nil ? 0 : faceUVs.compactMap { $0 }.count,
            warnings
        )
    }

    private static func decodeRGBA(
        at url: URL,
        maximumPixelSize: Int?
    ) -> (width: Int, height: Int, rgba: [UInt8])? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let cgImage: CGImage?
        if let maximumPixelSize {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: false,
            ]
            cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        } else {
            cgImage = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCache: false,
            ] as CFDictionary)
        }
        guard let cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return (width, height, rgba)
    }

    private static func decodeDepth(
        frame: RoomCaptureBundleFrame,
        framesDirectory: URL
    ) -> RoomMeshDepthPayload? {
        guard let depth = frame.depth,
              depth.compression == RoomCaptureBundleDepthCodec.compressionName,
              depth.pixelFormat == RoomCaptureBundleDepthCodec.depthPixelFormatName,
              depth.width > 0, depth.height > 0,
              depth.width <= Int.max / depth.height,
              depth.width * depth.height <= Int.max / 4,
              let compressed = try? Data(contentsOf: framesDirectory.appendingPathComponent(depth.fileName)),
              let bytes = RoomCaptureBundleDepthCodec.decompress(
                  compressed,
                  expectedByteCount: depth.width * depth.height * 4
              ) else { return nil }
        let raw = [UInt8](bytes)
        var values: [Float] = []
        values.reserveCapacity(depth.width * depth.height)
        for offset in stride(from: 0, to: raw.count, by: 4) {
            let bits = UInt32(raw[offset]) | UInt32(raw[offset + 1]) << 8
                | UInt32(raw[offset + 2]) << 16 | UInt32(raw[offset + 3]) << 24
            values.append(Float(bitPattern: bits))
        }
        var confidence: [UInt8]?
        if let name = depth.confidenceFileName,
           let compressedConfidence = try? Data(contentsOf: framesDirectory.appendingPathComponent(name)),
           let decoded = RoomCaptureBundleDepthCodec.decompress(
               compressedConfidence,
               expectedByteCount: depth.width * depth.height
           ) {
            confidence = [UInt8](decoded)
        }
        return RoomMeshDepthPayload(
            width: depth.width,
            height: depth.height,
            depthMeters: values,
            confidence: confidence
        )
    }

    private static func frameFingerprints(
        manifest: RoomCaptureBundleManifest?,
        bundleDirectory: URL
    ) -> [RoomMeshSourceFrameFingerprint] {
        guard let manifest else { return [] }
        let frames = bundleDirectory.appendingPathComponent(RoomCaptureBundleLibrary.framesSubdirectoryName)
        return manifest.frames.flatMap { frame -> [RoomMeshSourceFrameFingerprint] in
            let names = [frame.fileName, frame.depth?.fileName, frame.depth?.confidenceFileName].compactMap { $0 }
            return names.map { name in
                let url = frames.appendingPathComponent(name)
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                return RoomMeshSourceFrameFingerprint(
                    fileName: name,
                    byteSize: (attributes?[.size] as? NSNumber)?.int64Value ?? -1,
                    modificationTime: (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
                )
            }
        }
    }

    private static func faceNeighbors(faces: [UInt32], faceCount: Int) -> [[Int]] {
        struct Edge: Hashable { var a: UInt32; var b: UInt32 }
        var owners: [Edge: Int] = [:]
        var result = [[Int]](repeating: [], count: faceCount)
        for face in 0..<faceCount {
            let triangle = (0..<3).map { faces[face * 3 + $0] }
            for corner in 0..<3 {
                let x = triangle[corner], y = triangle[(corner + 1) % 3]
                let edge = Edge(a: min(x, y), b: max(x, y))
                if let other = owners[edge] {
                    result[face].append(other)
                    result[other].append(face)
                } else { owners[edge] = face }
            }
        }
        return result.map { $0.sorted() }
    }

    private static func makeCharts(
        assignments: [Int?],
        uvByFaceFrame: [[Int: [SIMD2<Double>]]],
        meshFaces: [UInt32]
    ) -> [FaceChart] {
        let projected: [RoomMeshProjectedFace] = assignments.indices.compactMap { faceIndex in
            guard let frame = assignments[faceIndex],
                  let pixels = uvByFaceFrame[faceIndex][frame], pixels.count == 3 else { return nil }
            return RoomMeshProjectedFace(
                faceIndex: faceIndex,
                frameIndex: frame,
                vertexIndices: Array(meshFaces[(faceIndex * 3)..<(faceIndex * 3 + 3)]),
                pixels: pixels
            )
        }
        let projectedByFace = Dictionary(uniqueKeysWithValues: projected.map { ($0.faceIndex, $0) })
        return RoomMeshTextureBaker.constructCharts(projectedFaces: projected).compactMap { chart in
            let faces = chart.faceIndices.compactMap { faceIndex -> FaceChart.Face? in
                projectedByFace[faceIndex].map { .init(faceIndex: faceIndex, sourcePixels: $0.pixels) }
            }
            let allPixels = faces.flatMap(\.sourcePixels)
            guard !faces.isEmpty, !allPixels.isEmpty else { return nil }
            let minX = floor(allPixels.map(\.x).min() ?? 0)
            let minY = floor(allPixels.map(\.y).min() ?? 0)
            let maxX = ceil(allPixels.map(\.x).max() ?? minX)
            let maxY = ceil(allPixels.map(\.y).max() ?? minY)
            let width = max(Int(maxX - minX) + 1, 2)
            let height = max(Int(maxY - minY) + 1, 2)
            return FaceChart(
                id: chart.id,
                frameIndex: chart.frameIndex,
                faces: faces,
                minX: minX,
                minY: minY,
                request: RoomMeshChartRequest(
                    id: chart.id,
                    width: width,
                    height: height,
                    frameIndex: chart.frameIndex,
                    firstFaceIndex: chart.faceIndices[0]
                )
            )
        }
    }

    private static func bakeAtlas(
        atlasSize: Int,
        charts: [FaceChart],
        placements: [Int: RoomMeshChartPlacement],
        atlasScale: Double,
        passes: [FramePass],
        framesDirectory: URL,
        reporter: RoomMeshProgressReporter
    ) throws -> Data? {
        guard atlasSize > 0, atlasSize <= settings.atlasMaxDimension else { return nil }
        let pixelCount = atlasSize * atlasSize
        var linearPixels = [UInt16](repeating: 0, count: pixelCount * 3)
        var owners = [Int32](repeating: -1, count: pixelCount)
        let totalRasterRows = max(atlasRasterRowCount(
            charts: charts,
            placements: placements,
            atlasScale: atlasScale,
            atlasSize: atlasSize
        ), 1)
        let reportingStride = max(totalRasterRows / 200, 1)
        var completedRasterRows = 0
        reporter.report(phase: .bakingAtlas, completed: 0, total: totalRasterRows, detail: "Decoding selected photos")
        for frameIndex in passes.indices {
            try Task.checkCancellation()
            let frameCharts = charts.filter { $0.frameIndex == frameIndex }
            guard !frameCharts.isEmpty else { continue }
            let url = framesDirectory.appendingPathComponent(passes[frameIndex].frame.fileName)
            guard let image = decodeRGBA(at: url, maximumPixelSize: nil) else { return nil }
            for chart in frameCharts {
                guard let placement = placements[chart.id] else { continue }
                for face in chart.faces {
                    try Task.checkCancellation()
                    let atlasPoints = face.sourcePixels.map { point in
                        SIMD2<Double>(
                            Double(placement.x) + (point.x - chart.minX) * atlasScale,
                            Double(placement.y) + (point.y - chart.minY) * atlasScale
                        )
                    }
                    let finished = rasterizeAtlasTriangle(
                        atlasPoints: atlasPoints,
                        sourcePoints: face.sourcePixels,
                        owner: chart.id,
                        image: image,
                        sensorWidth: passes[frameIndex].frame.imageWidth,
                        sensorHeight: passes[frameIndex].frame.imageHeight,
                        photometricLogGain: passes[frameIndex].photometricLogGain,
                        linearPixels: &linearPixels,
                        owners: &owners,
                        atlasSize: atlasSize,
                        onRow: {
                            completedRasterRows += 1
                            if completedRasterRows.isMultiple(of: reportingStride)
                                || completedRasterRows == totalRasterRows {
                                reporter.report(
                                    phase: .bakingAtlas,
                                    completed: min(completedRasterRows, totalRasterRows),
                                    total: totalRasterRows,
                                    detail: "Raster row \(min(completedRasterRows, totalRasterRows)) of \(totalRasterRows)"
                                )
                            }
                        }
                    )
                    if !finished { throw CancellationError() }
                }
            }
        }
        reporter.report(
            phase: .bakingAtlas,
            completed: totalRasterRows,
            total: totalRasterRows,
            detail: "Photo detail baked"
        )
        let paddingFinished = RoomMeshTextureBaker.dilateLinearUInt16(
            pixels: &linearPixels,
            owners: &owners,
            width: atlasSize,
            height: atlasSize,
            iterations: settings.atlasPadding,
            onProgress: { completed, total in
                let stride = max(total / 100, 1)
                if completed.isMultiple(of: stride) || completed == total {
                    reporter.report(
                        phase: .fillingPadding,
                        completed: completed,
                        total: total,
                        detail: "Padding work \(completed) of \(total)"
                    )
                }
            },
            isCancelled: { Task.isCancelled }
        )
        if !paddingFinished { throw CancellationError() }
        var rgba = [UInt8](repeating: 0, count: pixelCount * 4)
        let encodingReportingStride = max(atlasSize / 100, 1)
        for y in 0..<atlasSize {
            try Task.checkCancellation()
            for x in 0..<atlasSize {
                let index = y * atlasSize + x
                let linearOffset = index * 3
                let linear = SIMD3<Double>(
                    Double(linearPixels[linearOffset]) / 65_535,
                    Double(linearPixels[linearOffset + 1]) / 65_535,
                    Double(linearPixels[linearOffset + 2]) / 65_535
                )
                let color = owners[index] >= 0 ? RoomMeshColor.encode(linear) : .zero
                rgba[index * 4] = color.x
                rgba[index * 4 + 1] = color.y
                rgba[index * 4 + 2] = color.z
                rgba[index * 4 + 3] = 255
            }
            if (y + 1).isMultiple(of: encodingReportingStride) || y + 1 == atlasSize {
                reporter.report(
                    phase: .publishingCache,
                    completed: y + 1,
                    total: atlasSize * 4,
                    detail: "Encoding row \(y + 1) of \(atlasSize)"
                )
            }
        }
        try Task.checkCancellation()
        let png = encodePNG(rgba: rgba, width: atlasSize, height: atlasSize)
        reporter.report(
            phase: .publishingCache,
            completed: 2,
            total: 4,
            detail: png == nil ? "Texture encoding failed" : "Texture encoded"
        )
        return png
    }

    private static func atlasRasterRowCount(
        charts: [FaceChart],
        placements: [Int: RoomMeshChartPlacement],
        atlasScale: Double,
        atlasSize: Int
    ) -> Int {
        var total = 0
        for chart in charts {
            guard let placement = placements[chart.id] else { continue }
            for face in chart.faces {
                let points = face.sourcePixels.map { point in
                    SIMD2<Double>(
                        Double(placement.x) + (point.x - chart.minX) * atlasScale,
                        Double(placement.y) + (point.y - chart.minY) * atlasScale
                    )
                }
                let minY = max(Int(floor(points.map(\.y).min() ?? 0)), 0)
                let maxY = min(Int(ceil(points.map(\.y).max() ?? 0)), atlasSize - 1)
                guard minY <= maxY else { continue }
                let (next, overflow) = total.addingReportingOverflow(maxY - minY + 1)
                total = overflow ? Int.max : next
            }
        }
        return total
    }

    private static func rasterizeAtlasTriangle(
        atlasPoints: [SIMD2<Double>],
        sourcePoints: [SIMD2<Double>],
        owner: Int,
        image: (width: Int, height: Int, rgba: [UInt8]),
        sensorWidth: Int,
        sensorHeight: Int,
        photometricLogGain: SIMD3<Double>,
        linearPixels: inout [UInt16],
        owners: inout [Int32],
        atlasSize: Int,
        onRow: () -> Void
    ) -> Bool {
        guard atlasPoints.count == 3, sourcePoints.count == 3,
              let compactOwner = Int32(exactly: owner) else { return true }
        let area = edge(atlasPoints[0], atlasPoints[1], atlasPoints[2])
        guard abs(area) > 1e-12 else { return true }
        let minX = max(Int(floor(atlasPoints.map(\.x).min() ?? 0)), 0)
        let maxX = min(Int(ceil(atlasPoints.map(\.x).max() ?? 0)), atlasSize - 1)
        let minY = max(Int(floor(atlasPoints.map(\.y).min() ?? 0)), 0)
        let maxY = min(Int(ceil(atlasPoints.map(\.y).max() ?? 0)), atlasSize - 1)
        guard minX <= maxX, minY <= maxY else { return true }
        for y in minY...maxY {
            if Task.isCancelled { return false }
            for x in minX...maxX {
                let point = SIMD2<Double>(Double(x), Double(y))
                let w0 = edge(atlasPoints[1], atlasPoints[2], point) / area
                let w1 = edge(atlasPoints[2], atlasPoints[0], point) / area
                let w2 = 1 - w0 - w1
                guard w0 >= -1e-9, w1 >= -1e-9, w2 >= -1e-9 else { continue }
                let source = sourcePoints[0] * w0 + sourcePoints[1] * w1 + sourcePoints[2] * w2
                let imageX = RoomMeshProjection.resizedPixelCenter(
                    source.x, sourceSize: sensorWidth, destinationSize: image.width
                )
                let imageY = RoomMeshProjection.resizedPixelCenter(
                    source.y, sourceSize: sensorHeight, destinationSize: image.height
                )
                let index = y * atlasSize + x
                owners[index] = compactOwner
                let sampled = RoomMeshColor.bilinearSample(
                    rgba: image.rgba,
                    width: image.width,
                    height: image.height,
                    x: imageX,
                    y: imageY
                )
                let corrected = sampled * SIMD3<Double>(
                    exp(photometricLogGain.x),
                    exp(photometricLogGain.y),
                    exp(photometricLogGain.z)
                )
                let offset = index * 3
                linearPixels[offset] = linearUInt16(corrected.x)
                linearPixels[offset + 1] = linearUInt16(corrected.y)
                linearPixels[offset + 2] = linearUInt16(corrected.z)
            }
            onRow()
        }
        return true
    }

    private static func linearUInt16(_ value: Double) -> UInt16 {
        guard value.isFinite else { return 0 }
        return UInt16((min(max(value, 0), 1) * 65_535).rounded())
    }

    static func encodePNG(rgba: [UInt8], width: Int, height: Int) -> Data? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyColorModel: kCGImagePropertyColorModelRGB,
        ] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func publishCacheBestEffort(
        mesh: RoomMeshPhotorealMesh,
        atlasPNG: Data?,
        manifest: RoomMeshPhotorealCacheManifest,
        directory: URL,
        reporter: RoomMeshProgressReporter
    ) throws -> Bool {
        do {
            try Task.checkCancellation()
            try RoomMeshPhotorealPLY.write(mesh).write(
                to: directory.appendingPathComponent(RoomMeshPhotorealCache.meshFileName),
                options: .atomic
            )
            if let atlasPNG {
                try Task.checkCancellation()
                try atlasPNG.write(
                    to: directory.appendingPathComponent(RoomMeshPhotorealCache.atlasFileName),
                    options: .atomic
                )
            }
            reporter.report(phase: .publishingCache, completed: 3, total: 4, detail: "Saved derived assets")
            try Task.checkCancellation()
            try RoomJSONCoding.makeEncoder().encode(manifest).write(
                to: directory.appendingPathComponent(RoomMeshPhotorealCache.manifestFileName),
                options: .atomic
            )
            reporter.report(phase: .publishingCache, completed: 4, total: 4, detail: "Colored mesh saved")
            return true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            reporter.report(phase: .publishingCache, completed: 4, total: 4, detail: "Cache could not be saved")
            return false
        }
    }

    private static func edge(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ p: SIMD2<Double>) -> Double {
        (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
    }
}

// MARK: - Metal renderer

/// The mesh pipeline is small enough to compile from source at runtime, which
/// keeps the target free of a .metal build phase.
enum RoomMeshShaderSource {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
        float3 position [[attribute(0)]];
        float3 normal [[attribute(1)]];
        float4 fallbackColorSRGB [[attribute(2)]];
        float2 uv [[attribute(3)]];
        float textureValid [[attribute(4)]];
    };

    struct VertexOut {
        float4 position [[position]];
        float3 fallbackColorSRGB;
        float2 uv;
        float textureValid;
    };

    struct Uniforms {
        float4x4 modelViewProjection;
    };

    vertex VertexOut room_mesh_vertex(
        VertexIn in [[stage_in]],
        constant Uniforms &uniforms [[buffer(1)]]
    ) {
        VertexOut out;
        out.position = uniforms.modelViewProjection * float4(in.position, 1.0);
        out.fallbackColorSRGB = in.fallbackColorSRGB.rgb;
        out.uv = in.uv;
        out.textureValid = in.textureValid;
        return out;
    }

    float3 room_mesh_srgb_to_linear(float3 value) {
        return select(
            value / 12.92,
            pow((value + 0.055) / 1.055, float3(2.4)),
            value > 0.04045
        );
    }

    fragment float4 room_mesh_textured_fragment(
        VertexOut in [[stage_in]],
        texture2d<float> atlas [[texture(0)]],
        sampler atlasSampler [[sampler(0)]]
    ) {
        float3 linearColor = in.textureValid > 0.5
            ? atlas.sample(atlasSampler, in.uv).rgb
            : room_mesh_srgb_to_linear(in.fallbackColorSRGB);
        return float4(linearColor, 1.0);
    }
    """
}

@MainActor
final class RoomMeshRenderCoordinator: NSObject, MTKViewDelegate {
    private struct Uniforms {
        var modelViewProjection: simd_float4x4
    }

    private let camera: SplatCameraController
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private var vertexBuffer: MTLBuffer?
    private var indexBuffer: MTLBuffer?
    private var atlasTexture: MTLTexture?
    private var atlasSampler: MTLSamplerState?
    private var sampleCount = 1
    private var indexCount = 0
    private var drawableSize: CGSize = .zero
    private var lastFrameTimestamp: Date?

    init(camera: SplatCameraController) {
        self.camera = camera
    }

    nonisolated static func preferredSampleCount(
        supports: (Int) -> Bool
    ) -> Int {
        [4, 2, 1].first(where: supports) ?? 1
    }

    func attach(view: MTKView) {
        commandQueue = view.device?.makeCommandQueue()
        drawableSize = view.drawableSize
        if let device = view.device {
            sampleCount = Self.preferredSampleCount(supports: device.supportsTextureSampleCount)
            view.sampleCount = sampleCount
        }
    }

    func load(result: RoomMeshColoredResult) throws {
        guard let device = commandQueue?.device else {
            throw RoomMeshViewerError.metalUnavailable
        }

        let library = try device.makeLibrary(source: RoomMeshShaderSource.source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "room_mesh_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "room_mesh_textured_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        descriptor.depthAttachmentPixelFormat = .depth32Float
        descriptor.rasterSampleCount = sampleCount

        // float3 position + float3 normal + uchar4 sRGB fallback + float2 UV + float validity.
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float3
        vertexDescriptor.attributes[1].offset = 12
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.attributes[2].format = .uchar4Normalized
        vertexDescriptor.attributes[2].offset = 24
        vertexDescriptor.attributes[2].bufferIndex = 0
        vertexDescriptor.attributes[3].format = .float2
        vertexDescriptor.attributes[3].offset = 28
        vertexDescriptor.attributes[3].bufferIndex = 0
        vertexDescriptor.attributes[4].format = .float
        vertexDescriptor.attributes[4].offset = 36
        vertexDescriptor.attributes[4].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = 40
        descriptor.vertexDescriptor = vertexDescriptor
        pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: depthDescriptor)

        let mesh = result.photorealMesh
        var vertexBytes = [UInt8]()
        vertexBytes.reserveCapacity(mesh.vertices.count * 40)
        for index in mesh.vertices.indices {
            let vertex = mesh.vertices[index]
            withUnsafeBytes(of: vertex.x.bitPattern.littleEndian) { vertexBytes.append(contentsOf: $0) }
            withUnsafeBytes(of: vertex.y.bitPattern.littleEndian) { vertexBytes.append(contentsOf: $0) }
            withUnsafeBytes(of: vertex.z.bitPattern.littleEndian) { vertexBytes.append(contentsOf: $0) }
            let normal = index < mesh.normals.count ? mesh.normals[index] : SIMD3<Float>(0, 0, 0)
            withUnsafeBytes(of: normal.x.bitPattern.littleEndian) { vertexBytes.append(contentsOf: $0) }
            withUnsafeBytes(of: normal.y.bitPattern.littleEndian) { vertexBytes.append(contentsOf: $0) }
            withUnsafeBytes(of: normal.z.bitPattern.littleEndian) { vertexBytes.append(contentsOf: $0) }
            let color = index < mesh.fallbackColors.count
                ? mesh.fallbackColors[index]
                : RoomMeshKeyframeColorizer.uncoloredGray
            vertexBytes.append(contentsOf: [color.x, color.y, color.z, 255])
            let uv = index < mesh.uvs.count ? mesh.uvs[index] : .zero
            withUnsafeBytes(of: uv.x.bitPattern.littleEndian) { vertexBytes.append(contentsOf: $0) }
            withUnsafeBytes(of: uv.y.bitPattern.littleEndian) { vertexBytes.append(contentsOf: $0) }
            let valid: Float = index < mesh.textureValid.count && mesh.textureValid[index] > 0 ? 1 : 0
            withUnsafeBytes(of: valid.bitPattern.littleEndian) { vertexBytes.append(contentsOf: $0) }
        }
        guard
            let vertexBuffer = device.makeBuffer(bytes: vertexBytes, length: vertexBytes.count),
            let indexBuffer = device.makeBuffer(
                bytes: mesh.faces,
                length: mesh.faces.count * MemoryLayout<UInt32>.size
            )
        else {
            throw RoomMeshViewerError.metalUnavailable
        }
        self.vertexBuffer = vertexBuffer
        self.indexBuffer = indexBuffer
        indexCount = mesh.faces.count

        let textureLoader = MTKTextureLoader(device: device)
        if let atlasPNG = result.atlasPNG {
            atlasTexture = try textureLoader.newTexture(
                data: atlasPNG,
                options: [
                    .SRGB: true,
                    .origin: MTKTextureLoader.Origin.topLeft,
                    .generateMipmaps: true,
                    .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                    .textureStorageMode: MTLStorageMode.private.rawValue,
                ]
            )
        } else {
            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm_srgb,
                width: 1,
                height: 1,
                mipmapped: false
            )
            textureDescriptor.usage = .shaderRead
            atlasTexture = device.makeTexture(descriptor: textureDescriptor)
            var black: UInt32 = 0xff000000
            atlasTexture?.replace(
                region: MTLRegionMake2D(0, 0, 1, 1),
                mipmapLevel: 0,
                withBytes: &black,
                bytesPerRow: 4
            )
        }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.maxAnisotropy = 8
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        atlasSampler = device.makeSamplerState(descriptor: samplerDescriptor)
    }

    func installGestures(on view: MTKView) {
        let look = UIPanGestureRecognizer(target: self, action: #selector(handleOneFingerPan(_:)))
        look.maximumNumberOfTouches = 1
        view.addGestureRecognizer(look)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        view.addGestureRecognizer(pan)

        let zoom = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        view.addGestureRecognizer(zoom)
    }

    @objc private func handleOneFingerPan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: recognizer.view)
        recognizer.setTranslation(.zero, in: recognizer.view)
        switch camera.mode {
        case .orbit:
            camera.applyOrbitDrag(deltaX: Float(translation.x), deltaY: Float(translation.y))
        case .firstPerson:
            camera.applyLookDrag(deltaX: Float(translation.x), deltaY: Float(translation.y))
        }
    }

    @objc private func handleTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
        guard camera.mode == .orbit else { return }
        let translation = recognizer.translation(in: recognizer.view)
        recognizer.setTranslation(.zero, in: recognizer.view)
        camera.applyPan(deltaX: Float(translation.x), deltaY: Float(translation.y))
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard camera.mode == .orbit else { return }
        camera.applyZoom(scale: Float(recognizer.scale))
        recognizer.scale = 1
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        Task { @MainActor in
            self.drawableSize = size
        }
    }

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            drawMainActor(in: view)
        }
    }

    private func drawMainActor(in view: MTKView) {
        guard
            let pipelineState,
            let depthState,
            let vertexBuffer,
            let indexBuffer,
            let atlasTexture,
            let atlasSampler,
            indexCount > 0,
            let commandQueue,
            drawableSize.width > 0,
            drawableSize.height > 0,
            let drawable = view.currentDrawable,
            let renderPassDescriptor = view.currentRenderPassDescriptor
        else { return }

        let now = Date()
        if let lastFrameTimestamp {
            camera.tick(deltaTime: Float(now.timeIntervalSince(lastFrameTimestamp)))
        }
        lastFrameTimestamp = now

        guard
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else { return }

        let projection = SplatMatrices.perspective(
            fovyRadians: 65 * .pi / 180,
            aspectRatio: Float(drawableSize.width / drawableSize.height),
            nearZ: 0.05,
            farZ: 100
        )
        var uniforms = Uniforms(modelViewProjection: projection * camera.viewMatrix)

        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthState)
        // The scan is viewed from inside; both triangle sides stay visible.
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
        encoder.setFragmentTexture(atlasTexture, index: 0)
        encoder.setFragmentSamplerState(atlasSampler, index: 0)
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: indexCount,
            indexType: .uint32,
            indexBuffer: indexBuffer,
            indexBufferOffset: 0
        )
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

private struct RoomMeshMetalView: UIViewRepresentable {
    let result: RoomMeshColoredResult
    let camera: SplatCameraController
    let onLoadResult: (Error?) -> Void

    func makeCoordinator() -> RoomMeshRenderCoordinator {
        RoomMeshRenderCoordinator(camera: camera)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        // The coordinator selects the best supported 4x/2x/1x count in attach().
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.delegate = context.coordinator
        context.coordinator.attach(view: view)
        context.coordinator.installGestures(on: view)
        // Deferred so the load result never mutates SwiftUI state during the
        // view update that is creating this MTKView.
        let coordinator = context.coordinator
        let result = result
        let onLoadResult = onLoadResult
        Task { @MainActor in
            do {
                try coordinator.load(result: result)
                onLoadResult(nil)
            } catch {
                onLoadResult(error)
            }
        }
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}

// MARK: - Screen

struct RoomMeshViewerScreen: View {
    let projectID: String
    let roomName: String

    @StateObject private var camera = SplatCameraController(
        appliesSplatUpAxisCalibration: false
    )
    @ObservedObject private var loader: RoomMeshColoringJobCoordinator

    init(
        projectID: String,
        roomName: String = "Room",
        coordinator: RoomMeshColoringJobCoordinator
    ) {
        self.projectID = projectID
        self.roomName = roomName
        loader = coordinator
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if let message = loader.failureMessage {
                failureView(message: message)
            } else if loader.isCancelled {
                cancelledView
            } else if let result = loader.result {
                RoomMeshMetalView(result: result, camera: camera) { error in
                    if error == nil {
                        configureCamera(for: result)
                    }
                    loader.rendererDidFinish(error: error)
                }
                .ignoresSafeArea()

                if loader.rendererReady {
                    controls(result)
                } else {
                    coloringProgressView
                }
            } else {
                coloringProgressView
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if loader.rendererReady, camera.mode == .firstPerson {
                SplatWalkJoystick(camera: camera)
                    .padding(.trailing, 28)
                    .padding(.bottom, 170)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Colored mesh room")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            _ = loader.start(projectID: projectID, roomName: roomName)
        }
        .onDisappear {
            loader.detach(projectID: projectID)
        }
    }

    private var coloringProgressView: some View {
        VStack(spacing: 18) {
            VStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(loader.progress.phase.title)
                        .font(.headline)
                        .foregroundStyle(AppPalette.primaryOnDark)
                        .accessibilityIdentifier(RoomMeshColoringAccessibility.phase)
                    Spacer(minLength: 16)
                    Text("\(loader.progress.percent)%")
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(AppPalette.blueprintOnDark)
                        .accessibilityIdentifier(RoomMeshColoringAccessibility.percent)
                }

                ProgressView(value: loader.progress.fraction, total: 1)
                    .tint(AppPalette.blueprintOnDark)
                    .accessibilityLabel("Coloring progress")
                    .accessibilityValue("\(loader.progress.percent) percent")
                    .accessibilityIdentifier(RoomMeshColoringAccessibility.progress)

                if let detail = loader.progress.detail {
                    Text(detail)
                        .font(AppTypography.measurement)
                        .foregroundStyle(AppPalette.mutedOnDark)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier(RoomMeshColoringAccessibility.detail)
                }

                Text(loader.executionMessage)
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.mutedOnDark)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("meshViewer.executionMode")
            }

            if loader.isStalled {
                stallWarning
            } else {
                Text("Progress advances only when a measured coloring step finishes. The first open may take longer; later opens use the saved result.")
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.mutedOnDark)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Cancel coloring") {
                    loader.cancel()
                }
                .buttonStyle(.bordered)
                .tint(AppPalette.mutedOnDark)
                .accessibilityIdentifier(RoomMeshColoringAccessibility.cancel)
            }
        }
        .padding(24)
        .frame(maxWidth: 560)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(AppPalette.mutedOnDark.opacity(0.35), lineWidth: 1)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("meshViewer.loading")
    }

    private var stallWarning: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("This step has not reported new work for \(loader.elapsedSeconds) seconds. It may still be processing a large texture.", systemImage: "exclamationmark.triangle")
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.amberOnDark)

            AdaptiveActionRow(alignment: .leading, spacing: 10) {
                Button("Keep waiting") {
                    loader.keepWaiting()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppPalette.blueprintOnDark)

                Button("Retry") {
                    loader.retry()
                }
                .buttonStyle(.bordered)
                .tint(AppPalette.amberOnDark)
                .accessibilityIdentifier(RoomMeshColoringAccessibility.retry)

                Button("Cancel") {
                    loader.cancel()
                }
                .buttonStyle(.bordered)
                .tint(AppPalette.mutedOnDark)
                .accessibilityIdentifier(RoomMeshColoringAccessibility.cancel)
            }
        }
        .padding(14)
        .background(AppPalette.amberOnDark.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier(RoomMeshColoringAccessibility.stall)
    }

    private func failureView(message: String) -> some View {
        VStack(spacing: 18) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.amberOnDark)
                .multilineTextAlignment(.center)

            Button("Try again") {
                loader.retry()
            }
            .buttonStyle(.borderedProminent)
            .tint(AppPalette.blueprintOnDark)
            .accessibilityIdentifier(RoomMeshColoringAccessibility.retry)
        }
        .padding(24)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(RoomMeshColoringAccessibility.error)
    }

    private var cancelledView: some View {
        VStack(spacing: 18) {
            Label("Coloring was cancelled. Your original scan is unchanged.", systemImage: "xmark.circle")
                .font(AppTypography.measurement)
                .foregroundStyle(AppPalette.mutedOnDark)

            Button("Try again") {
                loader.retry()
            }
            .buttonStyle(.borderedProminent)
            .tint(AppPalette.blueprintOnDark)
            .accessibilityIdentifier(RoomMeshColoringAccessibility.retry)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("meshViewer.cancelled")
    }

    /// Start the orbit around the room center and first-person at standing
    /// eye height inside it. The mesh lives in ARKit world space (y up).
    private func configureCamera(for result: RoomMeshColoredResult) {
        let center = (result.boundsMin + result.boundsMax) * 0.5
        let extent = result.boundsMax - result.boundsMin
        let diagonal = (extent.x * extent.x + extent.y * extent.y + extent.z * extent.z).squareRoot()
        camera.orbitCenter = center
        camera.orbitDistance = min(max(diagonal * 0.75, 1.5), 20)
        camera.position = SIMD3<Float>(center.x, result.boundsMin.y + 1.6, center.z)
        camera.lookYaw = 0
        camera.lookPitch = 0
    }

    @ViewBuilder
    private func controls(_ result: RoomMeshColoredResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(result.warnings.enumerated()), id: \.offset) { _, warning in
                Label(warning.message, systemImage: "exclamationmark.triangle")
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.amberOnDark)
                    .accessibilityIdentifier(RoomMeshColoringAccessibility.warning)
            }

            Text("COLORED MESH / \(result.mesh.vertices.count) vertices / \(result.keyframeCount) keyframes")
                .font(AppTypography.measurement)
                .tracking(1.2)
                .foregroundStyle(AppPalette.mutedOnDark)
                .accessibilityIdentifier("meshViewer.status")

            AdaptiveActionRow(alignment: .leading, spacing: 10) {
                ForEach(SplatCameraController.Mode.allCases, id: \.rawValue) { mode in
                    Button(mode.rawValue) {
                        camera.mode = mode
                    }
                    .buttonStyle(.bordered)
                    .tint(
                        camera.mode == mode
                            ? AppPalette.blueprintOnDark
                            : AppPalette.mutedOnDark
                    )
                }
                Button("Reset") {
                    camera.reset()
                    configureCamera(for: result)
                }
                .buttonStyle(.bordered)
                .tint(AppPalette.mutedOnDark)
            }

            Text(
                camera.mode == .firstPerson
                    ? "Drag to look. Use the joystick to walk."
                    : "Drag to orbit, pinch to zoom, two-finger drag to pan."
            )
            .font(AppTypography.measurement)
            .foregroundStyle(AppPalette.mutedOnDark)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }
}
