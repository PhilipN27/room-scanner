import CoreGraphics
import Foundation
import ImageIO
import RoomScanCore

/// Converts an already-loaded immutable room package into only the bounded,
/// provider-neutral files an AI package can consider.  It neither loads from
/// the library nor writes to Projects, which keeps the capture/UI hot paths
/// and source package outside the outbound boundary.
final class RoomAIRoomPackageMaterializer {
    private let fileManager: FileManager
    private let now: () -> Date

    init(fileManager: FileManager = .default, now: @escaping () -> Date = Date.init) {
        self.fileManager = fileManager
        self.now = now
    }

    func materialize(
        package: RoomProjectPackage,
        sourceRevision: RoomRedesignSourceRevision,
        companion: RoomLocalRedesignExtensionV2,
        boundEvidence: RoomCaptureBundleBoundEvidence?,
        derivativeRenderer: any RoomAIRoomPackageDerivativeRendering,
        profile: RoomAIRoomPackageProfile,
        into leaseURL: URL
    ) async throws -> RoomAIRoomPackageMaterialization {
        let context = try RoomAIRoomPackageReadiness.requireEligible(sourceRevision: sourceRevision, companion: companion)
        guard package.manifest.projectID == sourceRevision.projectID,
              let revision = package.revisions.first(where: { $0.manifest.revisionID == sourceRevision.revisionID }),
              revision.manifest.immutable,
              revision.manifest.projectID == sourceRevision.projectID
        else { throw RoomAIRoomPackageAppServiceError.stalePreparation }

        let semanticData = try RoomJSONCoding.makeEncoder().encode(revision.payload.semanticSnapshot)
        guard RoomSHA256.hexDigest(of: semanticData) == sourceRevision.semanticSHA256 else {
            throw RoomAIRoomPackageAppServiceError.stalePreparation
        }
        if let boundEvidence,
           boundEvidence.sourceBinding.sourceRevision == sourceRevision {
            try validateEvidenceEnvelope(boundEvidence)
        }
        let lineageData = try RoomRedesignCanonicalJSON.encode(sourceRevision)
        let orientationData = try RoomRedesignCanonicalJSON.encode(companion.orientation)
        let intent = try requiredIntent(companion)
        let intentData = try RoomRedesignCanonicalJSON.encode(intent)
        let brief = makeBrief(intent: intent, sourceRevision: sourceRevision)

        let floorPlan = try await derivativeRenderer.renderFloorPlanPNG(sourceRevision: sourceRevision, into: leaseURL)
        let views = try await derivativeRenderer.renderCanonicalViewPNGs(orientation: companion.orientation, sourceRevision: sourceRevision, into: leaseURL)
        try RoomAIRoomPackageDerivativeRenderer.validate(floorPlan: floorPlan, canonicalViews: views, orientation: companion.orientation)

        var artifacts: [RoomAIRoomPackageAppArtifact] = [
            try write(semanticData, id: "semantic-model", path: "truth/semantic-model.json", mediaType: "application/json", lease: leaseURL),
            try write(lineageData, id: "revision-lineage", path: "truth/revision-lineage.json", mediaType: "application/json", lease: leaseURL),
            try write(orientationData, id: "orientation", path: "truth/orientation.json", mediaType: "application/json", lease: leaseURL),
            floorPlan,
            try write(Data(brief.utf8), id: "room-brief", path: "brief/room-brief.txt", mediaType: "text/plain", lease: leaseURL),
            try write(intentData, id: "redesign-intent", path: "intent/redesign-intent.json", mediaType: "application/json", lease: leaseURL),
        ]
        artifacts.append(contentsOf: views)

        if let mesh = try boundSceneMesh(
            boundEvidence,
            sourceRevision: sourceRevision,
            into: leaseURL
        ) {
            artifacts.append(mesh)
        }

        let candidates = try captureCandidates(boundEvidence, sourceRevision: sourceRevision, into: leaseURL, artifacts: &artifacts)
        var disclosure: [String: RoomAIReferenceImageDisclosure] = [:]
        for candidate in candidates {
            guard let artifact = artifacts.first(where: { $0.artifactID == candidate.evidenceID }) else { continue }
            disclosure[candidate.evidenceID] = try await imageDisclosure(for: artifact)
        }
        let quality = try qualityCarrier(revision: revision, source: sourceRevision)
        // Raw capture evidence is frozen only for the explicit Complete plan.
        // It remains inside owned staging until the exact disclosure review is
        // approved; AI-ready never creates these artifacts at all.
        let raw = profile == .complete
            ? try appendCompleteRawArtifacts(
                from: boundEvidence,
                sourceRevision: sourceRevision,
                into: leaseURL,
                artifacts: &artifacts
            )
            : ([], [], [], [])
        var rawImageDisclosure: [String: RoomAIReferenceImageDisclosure] = [:]
        for stableID in raw.0 {
            let artifactID = "raw-rgb-\(stableID)"
            guard let artifact = artifacts.first(where: { $0.artifactID == artifactID })
            else { throw RoomAIRoomPackageAppServiceError.missingRequiredArtifact(artifactID) }
            rawImageDisclosure[artifactID] = try await imageDisclosure(for: artifact)
        }
        return .init(
            context: context,
            profile: profile,
            artifacts: artifacts,
            referenceCandidates: candidates,
            qualityCarrier: quality,
            rawRGBIDs: raw.0,
            rawDepthIDs: raw.1,
            rawConfidenceIDs: raw.2,
            diagnosticIDs: raw.3,
            referenceDisclosure: disclosure,
            rawImageDisclosure: rawImageDisclosure,
            sourceWorkspaceURL: leaseURL
        )
    }

    private func imageDisclosure(
        for artifact: RoomAIRoomPackageAppArtifact
    ) async throws -> RoomAIReferenceImageDisclosure {
        let bytes = try Data(contentsOf: artifact.sourceURL, options: [.mappedIfSafe])
        try RoomAIImageSanitizer.validateSanitizedBytes(
            bytes,
            mediaType: artifact.mediaType
        )
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { throw RoomAIImageSanitizationError.malformedImage }
        let sanitized = RoomAISanitizedImage(
            data: bytes,
            mediaType: artifact.mediaType,
            pixelWidth: width,
            pixelHeight: height
        )
        let advisories = (try? await RoomAISensitiveContentAnalyzer.analyze(sanitized)) ?? [
            .init(
                kind: .reviewScreenOrDocumentExposure,
                basis: .userReviewRequired,
                message: "Automatic sensitive-content analysis was unavailable; inspect this image manually. \(RoomAISensitiveContentAnalyzer.disclaimer)"
            ),
        ]
        return .init(
            byteCount: UInt64(bytes.count),
            mediaType: artifact.mediaType,
            advisories: advisories
        )
    }

    private func captureCandidates(_ evidence: RoomCaptureBundleBoundEvidence?, sourceRevision: RoomRedesignSourceRevision, into lease: URL, artifacts: inout [RoomAIRoomPackageAppArtifact]) throws -> [RoomAIReferenceImageCandidate] {
        guard let evidence, evidence.sourceBinding.sourceRevision == sourceRevision else { return [] }
        guard !evidence.manifest.frames.isEmpty else { return [] }
        let framesDirectory = try ownedFramesDirectory(for: evidence)
        return try evidence.manifest.frames.prefix(RoomAIReferenceImageSelector.maximumCandidateCount).enumerated().compactMap { index, frame in
            let data = try boundedEvidenceFileData(
                named: frame.fileName,
                beneath: framesDirectory,
                ownedRoot: evidence.directoryURL,
                maximumBytes: 32 * 1_024 * 1_024
            )
            guard
                  let sharpness = try? imageSharpness(data) else { return nil }
            let imageID = String(format: "capture-%04d", index + 1)
            let sanitized = try RoomAIImageSanitizer.sanitize(data, declaredFilename: frame.fileName)
            guard sanitized.mediaType == "image/jpeg" else { return nil }
            let artifact = try write(sanitized.data, id: imageID, path: "staged-references/\(imageID).jpg", mediaType: "image/jpeg", lease: lease)
            artifacts.append(artifact)
            return RoomAIReferenceImageCandidate(evidenceID: imageID, sourceRevision: sourceRevision, capturedAt: evidence.manifest.createdAt.addingTimeInterval(frame.timestamp), sharpness: sharpness)
        }
    }

    private func imageSharpness(_ data: Data) throws -> Double {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw RoomAIImageSanitizationError.malformedImage }
        let width = min(image.width, 512), height = min(image.height, 512)
        guard width > 0, height > 0 else { throw RoomAIImageSanitizationError.malformedImage }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw RoomAIImageSanitizationError.malformedImage }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return RoomMeshFrameAnalysis.luminanceSharpness(rgba: rgba, width: width, height: height)
    }

    private func qualityCarrier(revision: RoomRevisionPackage, source: RoomRedesignSourceRevision) throws -> RoomQualityReportCarrierV1? {
        guard let report = revision.manifest.qualityReport else { return nil }
        return .init(sourceRevision: source, qualityReport: report, qualityReportSHA256: try RoomRedesignCanonicalJSON.sha256(report))
    }

    private func appendCompleteRawArtifacts(
        from evidence: RoomCaptureBundleBoundEvidence?,
        sourceRevision: RoomRedesignSourceRevision,
        into lease: URL,
        artifacts: inout [RoomAIRoomPackageAppArtifact]
    ) throws -> ([String], [String], [String], [String]) {
        guard let evidence, evidence.sourceBinding.sourceRevision == sourceRevision else {
            return ([], [], [], [])
        }
        var rgbIDs: [String] = []
        var depthIDs: [String] = []
        var confidenceIDs: [String] = []
        let frames = evidence.manifest.frames.prefix(64)
        if !frames.isEmpty {
            let framesDirectory = try ownedFramesDirectory(for: evidence)
            for (index, frame) in frames.enumerated() {
                let stableID = String(format: "%04d", index + 1)
                let rgbBytes = try boundedEvidenceFileData(
                    named: frame.fileName,
                    beneath: framesDirectory,
                    ownedRoot: evidence.directoryURL,
                    maximumBytes: 32 * 1_024 * 1_024
                )
                let sanitized = try RoomAIImageSanitizer.sanitize(
                    rgbBytes,
                    declaredFilename: frame.fileName
                )
                guard sanitized.mediaType == "image/jpeg" else {
                    throw RoomAIRoomPackageAppServiceError.unsafeArtifactPath(frame.fileName)
                }
                artifacts.append(try write(
                    sanitized.data,
                    id: "raw-rgb-\(stableID)",
                    path: "raw/rgb/\(stableID).jpg",
                    mediaType: "image/jpeg",
                    lease: lease
                ))
                rgbIDs.append(stableID)

                if let depth = frame.depth {
                    let depthBytes = try boundedEvidenceFileData(
                        named: depth.fileName,
                        beneath: framesDirectory,
                        ownedRoot: evidence.directoryURL,
                        maximumBytes: 64 * 1_024 * 1_024
                    )
                    artifacts.append(try write(
                        depthBytes,
                        id: "raw-depth-\(stableID)",
                        path: "raw/depth/\(stableID).bin",
                        mediaType: "application/octet-stream",
                        lease: lease
                    ))
                    depthIDs.append(stableID)
                    if let confidenceFileName = depth.confidenceFileName {
                        let confidenceBytes = try boundedEvidenceFileData(
                            named: confidenceFileName,
                            beneath: framesDirectory,
                            ownedRoot: evidence.directoryURL,
                            maximumBytes: 16 * 1_024 * 1_024
                        )
                        artifacts.append(try write(
                            confidenceBytes,
                            id: "raw-confidence-\(stableID)",
                            path: "raw/confidence/\(stableID).bin",
                            mediaType: "application/octet-stream",
                            lease: lease
                        ))
                        confidenceIDs.append(stableID)
                    }
                }
            }
        }
        let diagnosticsData = try RoomJSONCoding.makeEncoder().encode(evidence.manifest)
        artifacts.append(try write(
            diagnosticsData,
            id: "diagnostics-capture-manifest",
            path: "diagnostics/capture-manifest.json",
            mediaType: "application/json",
            lease: lease
        ))
        return (rgbIDs, depthIDs, confidenceIDs, ["capture-manifest"])
    }

    private func boundSceneMesh(
        _ evidence: RoomCaptureBundleBoundEvidence?,
        sourceRevision: RoomRedesignSourceRevision,
        into lease: URL
    ) throws -> RoomAIRoomPackageAppArtifact? {
        guard let evidence, evidence.sourceBinding.sourceRevision == sourceRevision else {
            return nil
        }
        guard let data = try optionalBoundedEvidenceFileData(
            named: RoomCaptureBundleLibrary.sceneMeshFileName,
            beneath: evidence.directoryURL,
            ownedRoot: evidence.directoryURL,
            maximumBytes: 128 * 1_024 * 1_024
        ) else { return nil }
        return try write(
            data,
            id: "mesh-capture-scene",
            path: "geometry/capture-scene.ply",
            mediaType: "application/octet-stream",
            lease: lease
        )
    }

    private func validateEvidenceEnvelope(
        _ evidence: RoomCaptureBundleBoundEvidence
    ) throws {
        _ = try ownedDirectory(
            evidence.directoryURL,
            within: evidence.directoryURL,
            rejectedPath: evidence.directoryURL.lastPathComponent
        )
        for frame in evidence.manifest.frames {
            try requireSafeCaptureLeaf(frame.fileName)
            if let depth = frame.depth {
                try requireSafeCaptureLeaf(depth.fileName)
                if let confidenceFileName = depth.confidenceFileName {
                    try requireSafeCaptureLeaf(confidenceFileName)
                }
            }
        }
    }

    private func ownedFramesDirectory(
        for evidence: RoomCaptureBundleBoundEvidence
    ) throws -> URL {
        let root = try ownedDirectory(
            evidence.directoryURL,
            within: evidence.directoryURL,
            rejectedPath: evidence.directoryURL.lastPathComponent
        )
        let frames = root.appendingPathComponent(
            RoomCaptureBundleLibrary.framesSubdirectoryName,
            isDirectory: true
        )
        return try ownedDirectory(
            frames,
            within: root,
            rejectedPath: RoomCaptureBundleLibrary.framesSubdirectoryName
        )
    }

    private func boundedEvidenceFileData(
        named fileName: String,
        beneath directory: URL,
        ownedRoot: URL,
        maximumBytes: Int
    ) throws -> Data {
        try requireSafeCaptureLeaf(fileName)
        let directory = try ownedDirectory(
            directory,
            within: ownedRoot,
            rejectedPath: directory.lastPathComponent
        )
        let source = directory.appendingPathComponent(fileName).standardizedFileURL
        guard isSameOrDescendant(source, of: directory) else {
            throw RoomAIRoomPackageAppServiceError.unsafeArtifactPath(fileName)
        }
        return try boundedRegularData(
            at: source,
            maximumBytes: maximumBytes,
            rejectedPath: fileName
        )
    }

    private func optionalBoundedEvidenceFileData(
        named fileName: String,
        beneath directory: URL,
        ownedRoot: URL,
        maximumBytes: Int
    ) throws -> Data? {
        try requireSafeCaptureLeaf(fileName)
        let directory = try ownedDirectory(
            directory,
            within: ownedRoot,
            rejectedPath: directory.lastPathComponent
        )
        let source = directory.appendingPathComponent(fileName).standardizedFileURL
        guard isSameOrDescendant(source, of: directory) else {
            throw RoomAIRoomPackageAppServiceError.unsafeArtifactPath(fileName)
        }
        guard pathEntryExists(at: source) else { return nil }
        return try boundedRegularData(
            at: source,
            maximumBytes: maximumBytes,
            rejectedPath: fileName
        )
    }

    private func boundedRegularData(
        at url: URL,
        maximumBytes: Int,
        rejectedPath: String
    ) throws -> Data {
        do {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let fileSize = values.fileSize,
                  fileSize > 0,
                  fileSize <= maximumBytes
            else { throw RoomAIRoomPackageAppServiceError.unsafeArtifactPath(rejectedPath) }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count == fileSize else {
                throw RoomAIRoomPackageAppServiceError.unsafeArtifactPath(rejectedPath)
            }
            return data
        } catch let error as RoomAIRoomPackageAppServiceError {
            throw error
        } catch {
            throw RoomAIRoomPackageAppServiceError.unsafeArtifactPath(rejectedPath)
        }
    }

    private func ownedDirectory(
        _ directory: URL,
        within root: URL,
        rejectedPath: String
    ) throws -> URL {
        let normalizedRoot = root.standardizedFileURL
        let normalizedDirectory = directory.standardizedFileURL
        guard isSameOrDescendant(normalizedDirectory, of: normalizedRoot) else {
            throw RoomAIRoomPackageAppServiceError.unsafeArtifactPath(rejectedPath)
        }
        try requireOwnedDirectory(normalizedRoot, rejectedPath: rejectedPath)
        guard normalizedDirectory != normalizedRoot else { return normalizedRoot }

        let rootPath = normalizedRoot.path
        let directoryPath = normalizedDirectory.path
        let separator = rootPath == "/" ? "" : "/"
        let suffix = directoryPath.dropFirst(rootPath.count + separator.count)
        var current = normalizedRoot
        for component in suffix.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: true)
            try requireOwnedDirectory(current, rejectedPath: rejectedPath)
        }
        return normalizedDirectory
    }

    private func requireSafeCaptureLeaf(_ fileName: String) throws {
        guard RoomCaptureBundleLibrary.isSafeCaptureFileLeaf(fileName) else {
            throw RoomAIRoomPackageAppServiceError.unsafeArtifactPath(fileName)
        }
    }

    private func requireOwnedDirectory(
        _ url: URL,
        rejectedPath: String
    ) throws {
        do {
            let values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw RoomAIRoomPackageAppServiceError.unsafeArtifactPath(rejectedPath)
            }
        } catch let error as RoomAIRoomPackageAppServiceError {
            throw error
        } catch {
            throw RoomAIRoomPackageAppServiceError.unsafeArtifactPath(rejectedPath)
        }
    }

    private func isSameOrDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidatePath = candidate.path
        let rootPath = root.path
        return candidatePath == rootPath
            || candidatePath.hasPrefix(rootPath == "/" ? rootPath : rootPath + "/")
    }

    private func pathEntryExists(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey])) != nil
    }

    private func requiredIntent(_ companion: RoomLocalRedesignExtensionV2) throws -> RoomRedesignIntentV2 {
        guard let intent = companion.redesignIntent else { throw RoomAIRoomPackageAppServiceError.stalePreparation }
        return intent
    }
    private func makeBrief(intent: RoomRedesignIntentV2, sourceRevision: RoomRedesignSourceRevision) -> String {
        "Room redesign brief\nSource revision: \(sourceRevision.revisionID)\nScope: \(intent.scope.rawValue)\nRequest: \(intent.request)\n"
    }
    private func write(_ data: Data, id: String, path: String, mediaType: String, lease: URL) throws -> RoomAIRoomPackageAppArtifact {
        let url = lease.appendingPathComponent(path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.withoutOverwriting])
        return .init(artifactID: id, sourceURL: url, relativePath: path, mediaType: mediaType)
    }
}
