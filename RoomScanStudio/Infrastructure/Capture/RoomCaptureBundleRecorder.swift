import ARKit
import CoreImage
import Foundation
import RoomScanCore
import UIKit

/// Phase A of the photoreal roadmap (docs/PHOTOREAL_ROADMAP.md): while
/// RoomPlan scans, record everything a later photoreal reconstruction needs —
/// posed camera keyframes plus the LiDAR scene mesh. Recording is strictly
/// best-effort: no bundle failure may ever fail or delay-block the capture
/// attempt itself; problems are recorded as manifest notes instead.

// MARK: - Bundle schema

/// Schema version 3: optional photometric metadata, retaining schema-v2 depth.
/// The payload files hold
/// tightly packed rows (no stride padding), zlib-compressed; depth is
/// float32 meters, confidence is uint8 ARConfidenceLevel raw values.
/// The whole block is optional so version-1 bundles keep decoding.
struct RoomCaptureBundleFrameDepth: Codable, Equatable, Sendable {
    var fileName: String
    var confidenceFileName: String?
    var width: Int
    var height: Int
    var compression: String
    var pixelFormat: String
}

struct RoomCaptureBundleFrame: Codable, Equatable, Sendable {
    var fileName: String
    /// ARKit session timestamp (seconds).
    var timestamp: Double
    /// Camera-to-world transform, column-major 16 values.
    var cameraTransform: [Double]
    /// Camera intrinsics, column-major 9 values, sensor-pixel units.
    var intrinsics: [Double]
    var imageWidth: Int
    var imageHeight: Int
    var exposureDuration: Double
    /// Optional diagnostics copied from ARFrame.exifData. Older bundles omit them.
    var iso: Double? = nil
    var exposureBias: Double? = nil
    /// Absent for schema-version-1 bundles and for keyframes whose depth
    /// map was unavailable or failed to encode (recording is best-effort).
    var depth: RoomCaptureBundleFrameDepth?
}

struct RoomCaptureBundleManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 3

    var schemaVersion: Int
    var createdAt: Date
    /// Images are stored in raw sensor orientation; the recorded transforms
    /// and intrinsics correspond to that orientation, which is what
    /// reconstruction pipelines expect.
    var frames: [RoomCaptureBundleFrame]
    var meshAnchorCount: Int
    var meshVertexCount: Int
    var meshFaceCount: Int
    var notes: [String]
}

/// Local capture bundles predate immutable revision bindings. Only bundles
/// adopted through the explicit Slice 3 path receive this sidecar; legacy
/// bundles remain viewable but cannot silently become AI-package evidence.
struct RoomCaptureBundleSourceBinding: Codable, Equatable, Sendable {
    static let currentSchemaVersion = "roomscan-capture-bundle-source-binding-v1"

    var schemaVersion: String
    var sourceRevision: RoomRedesignSourceRevision
    var bundleManifestSHA256: String
}

struct RoomCaptureBundleBoundEvidence: Sendable, Equatable {
    var directoryURL: URL
    var manifest: RoomCaptureBundleManifest
    var sourceBinding: RoomCaptureBundleSourceBinding
}

enum RoomCapturePoseSelection {
    static let minimumTranslationMeters = 0.05
    static let minimumRotationRadians = 3.0 * .pi / 180
    static let forcedIntervalSeconds = 2.0

    static func shouldAccept(
        previousTransform: [Double]?,
        previousTimestamp: Double?,
        candidateTransform: [Double],
        candidateTimestamp: Double
    ) -> Bool {
        guard
            let previousTransform,
            let previousTimestamp,
            previousTransform.count == 16,
            candidateTransform.count == 16,
            previousTransform.allSatisfy(\.isFinite),
            candidateTransform.allSatisfy(\.isFinite),
            candidateTimestamp.isFinite,
            previousTimestamp.isFinite
        else { return true }
        if candidateTimestamp - previousTimestamp >= forcedIntervalSeconds { return true }

        let dx = candidateTransform[12] - previousTransform[12]
        let dy = candidateTransform[13] - previousTransform[13]
        let dz = candidateTransform[14] - previousTransform[14]
        let translation = (dx * dx + dy * dy + dz * dz).squareRoot()
        if translation >= minimumTranslationMeters { return true }

        // trace(R_previous^T R_candidate) = sum of corresponding 3x3 entries.
        let rotationOffsets = [0, 1, 2, 4, 5, 6, 8, 9, 10]
        let trace = rotationOffsets.reduce(into: 0.0) { value, offset in
            value += previousTransform[offset] * candidateTransform[offset]
        }
        let cosine = min(max((trace - 1) / 2, -1), 1)
        return acos(cosine) >= minimumRotationRadians
    }
}

enum RoomCapturePhotometricMetadata {
    /// Reads only small scalar values. It is nonthrowing and performs no image work.
    static func numericValues(
        from exifData: [String: Any]
    ) -> (iso: Double?, exposureBias: Double?) {
        func number(for keys: [String]) -> Double? {
            for key in keys {
                if let value = exifData[key] as? NSNumber { return value.doubleValue }
                if let values = exifData[key] as? [NSNumber], let value = values.first {
                    return value.doubleValue
                }
            }
            return nil
        }
        return (
            number(for: ["PhotographicSensitivity", "ISOSpeedRatings", "ISO"]),
            number(for: ["ExposureBiasValue", "ExposureBias"])
        )
    }
}

// MARK: - Sidecar bundle storage

/// Adopted capture bundles live beside the immutable room packages, keyed by
/// project, like imported splats. Formalizing bundles as package evidence is
/// a later roadmap step.
enum RoomCaptureBundleLibrary {
    static let manifestFileName = "bundle-manifest.json"
    static let sourceBindingFileName = "source-revision-binding.json"
    static let sceneMeshFileName = "scene-mesh.ply"
    static let framesSubdirectoryName = "frames"
    private static let maximumManifestByteCount = 16 * 1_024 * 1_024
    private static let maximumBindingByteCount = 64 * 1_024

    /// Capture manifests are allowed to name only a single local file under
    /// `frames`. Treat those names as untrusted even though they originate
    /// from our recorder: a sealed bundle can still be damaged on disk.
    static func isSafeCaptureFileLeaf(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.count <= 255,
              value != ".",
              value != "..",
              !value.hasPrefix(".")
        else { return false }
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_."
        )
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func rootURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent(
            "RoomScanStudioCaptureBundles",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return try validatedOwnedDirectory(directory, within: directory)
    }

    static func bundleDirectory(forProject projectID: String) -> URL? {
        guard isSafeProjectIdentifier(projectID), let root = try? rootURL() else { return nil }
        let candidate = root.appendingPathComponent(projectID, isDirectory: true)
        return try? validatedOwnedDirectory(candidate, within: root)
    }

    static func manifest(forProject projectID: String) -> RoomCaptureBundleManifest? {
        guard let directory = bundleDirectory(forProject: projectID) else { return nil }
        let manifestURL = directory.appendingPathComponent(manifestFileName)
        guard let data = try? boundedRegularFileData(
            at: manifestURL,
            maximumByteCount: maximumManifestByteCount
        ) else { return nil }
        return try? RoomJSONCoding.makeDecoder().decode(
            RoomCaptureBundleManifest.self,
            from: data
        )
    }

    /// Moves a recorded scratch bundle into the per-project library slot,
    /// replacing any previous bundle for the project. This compatibility path
    /// deliberately strips any binding: callers must use `adoptBoundBundle`
    /// when they possess the authoritative immutable revision identity.
    static func adoptBundle(at sourceURL: URL, forProject projectID: String) throws {
        _ = try validatedOwnedDirectory(sourceURL, within: sourceURL)
        let staleBinding = sourceURL.appendingPathComponent(sourceBindingFileName)
        if pathEntryExists(at: staleBinding) {
            try FileManager.default.removeItem(at: staleBinding)
        }
        try moveBundle(at: sourceURL, forProject: projectID)
    }

    static func adoptBoundBundle(
        at sourceURL: URL,
        forProject projectID: String,
        sourceRevision: RoomRedesignSourceRevision
    ) throws {
        try sourceRevision.validate()
        guard isSafeProjectIdentifier(projectID),
              sourceRevision.projectID == projectID
        else {
            throw RoomProjectStoreError.invalidPackage(
                "Capture evidence must bind to the same safe project identifier."
            )
        }
        let sourceDirectory = try validatedOwnedDirectory(sourceURL, within: sourceURL)
        let manifestURL = sourceDirectory.appendingPathComponent(manifestFileName)
        let manifestData = try boundedRegularFileData(
            at: manifestURL,
            maximumByteCount: maximumManifestByteCount
        )
        let manifest = try RoomJSONCoding.makeDecoder().decode(
            RoomCaptureBundleManifest.self,
            from: manifestData
        )
        guard manifest.schemaVersion == RoomCaptureBundleManifest.currentSchemaVersion else {
            throw RoomProjectStoreError.invalidPackage(
                "New AI evidence requires the current capture-bundle manifest schema."
            )
        }
        try validateManifestArtifactLeaves(manifest)
        let binding = RoomCaptureBundleSourceBinding(
            schemaVersion: RoomCaptureBundleSourceBinding.currentSchemaVersion,
            sourceRevision: sourceRevision,
            bundleManifestSHA256: RoomSHA256.hexDigest(of: manifestData)
        )
        let bindingData = try RoomJSONCoding.makeEncoder().encode(binding)
        guard bindingData.count <= maximumBindingByteCount else {
            throw RoomProjectStoreError.invalidPackage("Capture source binding is unexpectedly large.")
        }
        let bindingURL = sourceDirectory.appendingPathComponent(sourceBindingFileName)
        if pathEntryExists(at: bindingURL) {
            try FileManager.default.removeItem(at: bindingURL)
        }
        try bindingData.write(
            to: bindingURL,
            options: .atomic
        )
        try moveBundle(at: sourceDirectory, forProject: projectID)
    }

    static func boundEvidence(
        forProject projectID: String,
        expectedSourceRevision: RoomRedesignSourceRevision
    ) -> RoomCaptureBundleBoundEvidence? {
        guard isSafeProjectIdentifier(projectID),
              expectedSourceRevision.projectID == projectID,
              (try? expectedSourceRevision.validate()) != nil,
              let directory = bundleDirectory(forProject: projectID)
        else { return nil }
        do {
            let bindingData = try boundedRegularFileData(
                at: directory.appendingPathComponent(sourceBindingFileName),
                maximumByteCount: maximumBindingByteCount
            )
            let binding = try RoomJSONCoding.makeDecoder().decode(
                RoomCaptureBundleSourceBinding.self,
                from: bindingData
            )
            guard binding.schemaVersion == RoomCaptureBundleSourceBinding.currentSchemaVersion,
                  binding.sourceRevision == expectedSourceRevision,
                  (try? binding.sourceRevision.validate()) != nil
            else { return nil }

            let manifestData = try boundedRegularFileData(
                at: directory.appendingPathComponent(manifestFileName),
                maximumByteCount: maximumManifestByteCount
            )
            guard RoomSHA256.hexDigest(of: manifestData) == binding.bundleManifestSHA256 else {
                return nil
            }
            let manifest = try RoomJSONCoding.makeDecoder().decode(
                RoomCaptureBundleManifest.self,
                from: manifestData
            )
            guard manifest.schemaVersion == RoomCaptureBundleManifest.currentSchemaVersion else {
                return nil
            }
            try validateManifestArtifactLeaves(manifest)
            return RoomCaptureBundleBoundEvidence(
                directoryURL: directory,
                manifest: manifest,
                sourceBinding: binding
            )
        } catch {
            return nil
        }
    }

    private static func moveBundle(at sourceURL: URL, forProject projectID: String) throws {
        guard isSafeProjectIdentifier(projectID) else {
            throw RoomProjectStoreError.invalidPackage("Unsafe capture-bundle project identifier.")
        }
        _ = try validatedOwnedDirectory(sourceURL, within: sourceURL)
        let root = try rootURL()
        let destination = root.appendingPathComponent(projectID, isDirectory: true)
        if pathEntryExists(at: destination) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: sourceURL, to: destination)
    }

    private static func boundedRegularFileData(
        at fileURL: URL,
        maximumByteCount: Int
    ) throws -> Data {
        let values = try fileURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= maximumByteCount
        else {
            throw RoomProjectStoreError.invalidPackage("Capture evidence sidecar is unsafe or out of bounds.")
        }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard data.count == fileSize else {
            throw RoomProjectStoreError.invalidPackage("Capture evidence sidecar changed while being read.")
        }
        return data
    }

    private static func validateManifestArtifactLeaves(
        _ manifest: RoomCaptureBundleManifest
    ) throws {
        for frame in manifest.frames {
            guard isSafeCaptureFileLeaf(frame.fileName) else {
                throw RoomProjectStoreError.invalidPackage("Capture frame name is not a safe file leaf.")
            }
            guard let depth = frame.depth else { continue }
            guard isSafeCaptureFileLeaf(depth.fileName) else {
                throw RoomProjectStoreError.invalidPackage("Capture depth name is not a safe file leaf.")
            }
            if let confidenceFileName = depth.confidenceFileName,
               !isSafeCaptureFileLeaf(confidenceFileName) {
                throw RoomProjectStoreError.invalidPackage("Capture confidence name is not a safe file leaf.")
            }
        }
    }

    private static func validatedOwnedDirectory(
        _ directory: URL,
        within root: URL
    ) throws -> URL {
        let normalizedRoot = root.standardizedFileURL
        let normalizedDirectory = directory.standardizedFileURL
        guard isSameOrDescendant(normalizedDirectory, of: normalizedRoot) else {
            throw RoomProjectStoreError.invalidPackage("Capture evidence directory escapes its owned root.")
        }
        try requireOwnedDirectory(normalizedRoot)
        guard normalizedDirectory != normalizedRoot else { return normalizedRoot }

        let rootPath = normalizedRoot.path
        let directoryPath = normalizedDirectory.path
        let separator = rootPath == "/" ? "" : "/"
        let suffix = directoryPath.dropFirst(rootPath.count + separator.count)
        var current = normalizedRoot
        for component in suffix.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: true)
            try requireOwnedDirectory(current)
        }
        return normalizedDirectory
    }

    private static func requireOwnedDirectory(_ url: URL) throws {
        do {
            let values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw RoomProjectStoreError.invalidPackage(
                    "Capture evidence directory must be owned and cannot be a symbolic link."
                )
            }
        } catch let error as RoomProjectStoreError {
            throw error
        } catch {
            throw RoomProjectStoreError.invalidPackage(
                "Capture evidence directory is unavailable or unsafe."
            )
        }
    }

    private static func isSameOrDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidatePath = candidate.path
        let rootPath = root.path
        return candidatePath == rootPath
            || candidatePath.hasPrefix(rootPath == "/" ? rootPath : rootPath + "/")
    }

    private static func pathEntryExists(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey])) != nil
    }

    private static func isSafeProjectIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128 else { return false }
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        )
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    static func removeBundle(forProject projectID: String) throws {
        guard isSafeProjectIdentifier(projectID) else {
            throw RoomProjectStoreError.invalidPackage("Unsafe capture-bundle project identifier.")
        }
        let root = try rootURL()
        let destination = root.appendingPathComponent(projectID, isDirectory: true)
        if pathEntryExists(at: destination) {
            try FileManager.default.removeItem(at: destination)
        }
    }
}

// MARK: - Binary PLY writing (pure, unit-testable)

enum RoomCaptureBundlePLYWriter {
    /// Little-endian binary PLY with position + normal vertices and
    /// triangular faces — the interchange format reconstruction tools and
    /// mesh viewers accept universally.
    static func makeBinaryPLY(
        vertices: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        faces: [UInt32]
    ) -> Data {
        precondition(normals.count == vertices.count, "one normal per vertex")
        precondition(faces.count % 3 == 0, "faces are triangle index triples")

        var header = "ply\n"
        header += "format binary_little_endian 1.0\n"
        header += "comment RoomScanStudio capture-bundle scene mesh\n"
        header += "element vertex \(vertices.count)\n"
        header += "property float x\nproperty float y\nproperty float z\n"
        header += "property float nx\nproperty float ny\nproperty float nz\n"
        header += "element face \(faces.count / 3)\n"
        header += "property list uchar uint vertex_indices\n"
        header += "end_header\n"

        var data = Data(header.utf8)
        data.reserveCapacity(data.count + vertices.count * 24 + (faces.count / 3) * 13)
        for index in vertices.indices {
            appendFloats(&data, [
                vertices[index].x, vertices[index].y, vertices[index].z,
                normals[index].x, normals[index].y, normals[index].z,
            ])
        }
        var faceIndex = 0
        while faceIndex < faces.count {
            data.append(3)
            appendUInt32s(&data, [
                faces[faceIndex], faces[faceIndex + 1], faces[faceIndex + 2],
            ])
            faceIndex += 3
        }
        return data
    }

    private static func appendFloats(_ data: inout Data, _ values: [Float]) {
        for value in values {
            withUnsafeBytes(of: value.bitPattern.littleEndian) {
                data.append(contentsOf: $0)
            }
        }
    }

    private static func appendUInt32s(_ data: inout Data, _ values: [UInt32]) {
        for value in values {
            withUnsafeBytes(of: value.littleEndian) {
                data.append(contentsOf: $0)
            }
        }
    }
}

// MARK: - Depth map packing (pure, unit-testable)

/// Bundle depth/confidence payload encoding: CVPixelBuffer rows are packed
/// tightly (dropping stride padding) and zlib-compressed. Kept free of ARKit
/// types so the byte layout is provable in simulator tests.
enum RoomCaptureBundleDepthCodec {
    static let compressionName = "zlib"
    static let depthPixelFormatName = "float32"
    static let confidencePixelFormatName = "uint8"

    static func packTightRows(
        base: UnsafeRawPointer,
        bytesPerRow: Int,
        width: Int,
        height: Int,
        bytesPerPixel: Int
    ) -> Data {
        let tightRowBytes = width * bytesPerPixel
        var data = Data(capacity: tightRowBytes * height)
        for row in 0..<height {
            data.append(
                Data(bytes: base.advanced(by: row * bytesPerRow), count: tightRowBytes)
            )
        }
        return data
    }

    static func compress(_ data: Data) -> Data? {
        try? (data as NSData).compressed(using: .zlib) as Data
    }

    static func decompress(_ data: Data, expectedByteCount: Int) -> Data? {
        guard
            let decompressed = try? (data as NSData).decompressed(using: .zlib) as Data,
            decompressed.count == expectedByteCount
        else {
            return nil
        }
        return decompressed
    }
}

// MARK: - Recorder

/// Values crossing from the main-actor poll into the background JPEG encoder.
private struct RoomCaptureBundleFrameCapture: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let depthPixelBuffer: CVPixelBuffer?
    let confidencePixelBuffer: CVPixelBuffer?
    let fileName: String
    let timestamp: Double
    let cameraTransform: [Double]
    let intrinsics: [Double]
    let imageWidth: Int
    let imageHeight: Int
    let exposureDuration: Double
    let iso: Double?
    let exposureBias: Double?
}

@MainActor
final class RoomCaptureBundleRecorder {
    static let bundleSubdirectoryName = "capture-bundle"
    private static let frameIntervalSeconds: Double = 0.7
    private nonisolated(unsafe) static let jpegQuality: CGFloat = 0.8
    private nonisolated(unsafe) static let sharedCIContext = CIContext(options: nil)

    private let arSession: ARSession
    private let directoryURL: URL
    private let framesURL: URL

    private var pollTask: Task<Void, Never>?
    private var encodeTask: Task<Void, Never>?
    private var frames: [RoomCaptureBundleFrame] = []
    private var lastCapturedTimestamp: TimeInterval = 0
    private var lastAcceptedTransform: [Double]?
    private var lastAcceptedTimestamp: TimeInterval?
    private var frameCounter = 0
    private var notes: [String] = []
    private var didFinish = false
    /// Latest non-empty mesh-anchor set seen while polling. Finalize falls
    /// back to it if the session loses its anchors before the scan stops
    /// (observed on device when reconfiguring the shared session mid-scan).
    private var latestMeshAnchors: [ARMeshAnchor] = []

    init(arSession: ARSession, parentDirectoryURL: URL) {
        self.arSession = arSession
        directoryURL = parentDirectoryURL.appendingPathComponent(
            Self.bundleSubdirectoryName,
            isDirectory: true
        )
        framesURL = directoryURL.appendingPathComponent(
            RoomCaptureBundleLibrary.framesSubdirectoryName,
            isDirectory: true
        )
    }

    func start() {
        do {
            try FileManager.default.createDirectory(
                at: framesURL,
                withIntermediateDirectories: true
            )
        } catch {
            notes.append("Frame directory could not be created: \(error.localizedDescription)")
            return
        }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.captureTickIfReady()
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.frameIntervalSeconds * 1_000_000_000)
                )
            }
        }
    }

    /// Harvests the scene mesh and writes the manifest while the AR session
    /// is still running; the driver calls this before issuing the final stop.
    func finalize() async {
        guard !didFinish else { return }
        didFinish = true
        pollTask?.cancel()
        pollTask = nil
        await waitForWrites()

        let meshCounts = writeSceneMesh()
        let manifest = RoomCaptureBundleManifest(
            schemaVersion: RoomCaptureBundleManifest.currentSchemaVersion,
            createdAt: Date(),
            frames: frames,
            meshAnchorCount: meshCounts.anchors,
            meshVertexCount: meshCounts.vertices,
            meshFaceCount: meshCounts.faces,
            notes: notes
        )
        do {
            let data = try RoomJSONCoding.makeEncoder().encode(manifest)
            try data.write(
                to: directoryURL.appendingPathComponent(
                    RoomCaptureBundleLibrary.manifestFileName
                ),
                options: .atomic
            )
        } catch {
            print("RoomScanStudio capture bundle: manifest write failed: \(error)")
        }
        let depthFrameCount = frames.filter { $0.depth != nil }.count
        print(
            "RoomScanStudio capture bundle: \(frames.count) keyframes "
                + "(\(depthFrameCount) with LiDAR depth), "
                + "\(meshCounts.anchors) mesh anchors, "
                + "\(meshCounts.vertices) vertices, \(meshCounts.faces) faces."
        )
    }

    /// Discard path: stop recording without harvesting; scratch cleanup
    /// removes anything already written.
    func cancel() {
        didFinish = true
        pollTask?.cancel()
        pollTask = nil
    }

    func waitForWrites() async {
        if let encodeTask {
            await encodeTask.value
        }
    }

    // MARK: Keyframes

    private func captureTickIfReady() {
        guard !didFinish else { return }
        guard let frame = arSession.currentFrame else { return }
        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        if !meshAnchors.isEmpty {
            latestMeshAnchors = meshAnchors
        }
        guard encodeTask == nil else { return }
        guard frame.timestamp > lastCapturedTimestamp else { return }
        guard case .normal = frame.camera.trackingState else { return }
        let cameraTransform = Self.columnMajor(frame.camera.transform)
        guard RoomCapturePoseSelection.shouldAccept(
            previousTransform: lastAcceptedTransform,
            previousTimestamp: lastAcceptedTimestamp,
            candidateTransform: cameraTransform,
            candidateTimestamp: frame.timestamp
        ) else { return }
        lastCapturedTimestamp = frame.timestamp

        let metadata = RoomCapturePhotometricMetadata.numericValues(from: frame.exifData)

        frameCounter += 1
        let capture = RoomCaptureBundleFrameCapture(
            pixelBuffer: frame.capturedImage,
            depthPixelBuffer: frame.sceneDepth?.depthMap,
            confidencePixelBuffer: frame.sceneDepth?.confidenceMap,
            fileName: String(format: "frame-%05d.jpg", frameCounter),
            timestamp: frame.timestamp,
            cameraTransform: cameraTransform,
            intrinsics: Self.columnMajor(frame.camera.intrinsics),
            imageWidth: Int(frame.camera.imageResolution.width),
            imageHeight: Int(frame.camera.imageResolution.height),
            exposureDuration: frame.camera.exposureDuration,
            iso: metadata.iso,
            exposureBias: metadata.exposureBias
        )
        let framesURL = framesURL
        encodeTask = Task.detached(priority: .utility) { [weak self] in
            let record = Self.encodeAndWriteFrame(capture, into: framesURL)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let record {
                    self.frames.append(record)
                    self.lastAcceptedTransform = record.cameraTransform
                    self.lastAcceptedTimestamp = record.timestamp
                } else if self.notes.last?.hasPrefix("Keyframe encode failed") != true {
                    self.notes.append("Keyframe encode failed for \(capture.fileName).")
                }
                self.encodeTask = nil
            }
        }
    }

    private nonisolated static func encodeAndWriteFrame(
        _ capture: RoomCaptureBundleFrameCapture,
        into framesURL: URL
    ) -> RoomCaptureBundleFrame? {
        let ciImage = CIImage(cvPixelBuffer: capture.pixelBuffer)
        guard
            let cgImage = sharedCIContext.createCGImage(ciImage, from: ciImage.extent),
            let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: jpegQuality),
            !jpeg.isEmpty
        else {
            return nil
        }
        do {
            try jpeg.write(
                to: framesURL.appendingPathComponent(capture.fileName),
                options: .atomic
            )
        } catch {
            return nil
        }
        return RoomCaptureBundleFrame(
            fileName: capture.fileName,
            timestamp: capture.timestamp,
            cameraTransform: capture.cameraTransform,
            intrinsics: capture.intrinsics,
            imageWidth: capture.imageWidth,
            imageHeight: capture.imageHeight,
            exposureDuration: capture.exposureDuration,
            iso: capture.iso,
            exposureBias: capture.exposureBias,
            depth: encodeAndWriteDepth(capture, into: framesURL)
        )
    }

    /// LiDAR depth is a per-frame bonus on top of the keyframe JPEG: any
    /// failure here returns nil and the keyframe stays valid without depth.
    private nonisolated static func encodeAndWriteDepth(
        _ capture: RoomCaptureBundleFrameCapture,
        into framesURL: URL
    ) -> RoomCaptureBundleFrameDepth? {
        guard let depthBuffer = capture.depthPixelBuffer else { return nil }
        guard
            CVPixelBufferGetPixelFormatType(depthBuffer) == kCVPixelFormatType_DepthFloat32,
            let depthPayload = packedCompressedPayload(from: depthBuffer, bytesPerPixel: 4)
        else {
            return nil
        }
        let baseName = (capture.fileName as NSString).deletingPathExtension
        let depthFileName = "\(baseName)-depth.bin"
        do {
            try depthPayload.data.write(
                to: framesURL.appendingPathComponent(depthFileName),
                options: .atomic
            )
        } catch {
            return nil
        }

        // Confidence is best-effort on top of best-effort: depth without a
        // confidence map is still worth keeping.
        var confidenceFileName: String?
        if let confidenceBuffer = capture.confidencePixelBuffer,
           CVPixelBufferGetPixelFormatType(confidenceBuffer) == kCVPixelFormatType_OneComponent8,
           CVPixelBufferGetWidth(confidenceBuffer) == depthPayload.width,
           CVPixelBufferGetHeight(confidenceBuffer) == depthPayload.height,
           let confidencePayload = packedCompressedPayload(from: confidenceBuffer, bytesPerPixel: 1) {
            let candidate = "\(baseName)-confidence.bin"
            if (try? confidencePayload.data.write(
                to: framesURL.appendingPathComponent(candidate),
                options: .atomic
            )) != nil {
                confidenceFileName = candidate
            }
        }

        return RoomCaptureBundleFrameDepth(
            fileName: depthFileName,
            confidenceFileName: confidenceFileName,
            width: depthPayload.width,
            height: depthPayload.height,
            compression: RoomCaptureBundleDepthCodec.compressionName,
            pixelFormat: RoomCaptureBundleDepthCodec.depthPixelFormatName
        )
    }

    private nonisolated static func packedCompressedPayload(
        from pixelBuffer: CVPixelBuffer,
        bytesPerPixel: Int
    ) -> (data: Data, width: Int, height: Int)? {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }
        let packed = RoomCaptureBundleDepthCodec.packTightRows(
            base: base,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            width: width,
            height: height,
            bytesPerPixel: bytesPerPixel
        )
        guard let compressed = RoomCaptureBundleDepthCodec.compress(packed) else { return nil }
        return (compressed, width, height)
    }

    // MARK: Scene mesh

    private func writeSceneMesh() -> (anchors: Int, vertices: Int, faces: Int) {
        var meshAnchors = (arSession.currentFrame?.anchors ?? [])
            .compactMap { $0 as? ARMeshAnchor }
        if meshAnchors.isEmpty, !latestMeshAnchors.isEmpty {
            meshAnchors = latestMeshAnchors
            notes.append(
                "Scene mesh harvested from the latest mid-scan anchor snapshot; "
                    + "the session had no ARMeshAnchors at stop."
            )
        }
        guard !meshAnchors.isEmpty else {
            notes.append(
                "No ARMeshAnchors were available at scan end; the RoomPlan session "
                    + "did not expose scene reconstruction on this device/OS."
            )
            return (0, 0, 0)
        }

        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var faces: [UInt32] = []
        for anchor in meshAnchors {
            let geometry = anchor.geometry
            let baseIndex = UInt32(vertices.count)
            let anchorTransform = anchor.transform
            for vertexIndex in 0..<geometry.vertices.count {
                let local = Self.vertex(at: vertexIndex, in: geometry.vertices)
                let world = anchorTransform * SIMD4<Float>(local.x, local.y, local.z, 1)
                vertices.append(SIMD3<Float>(world.x, world.y, world.z))
                let normal = Self.vertex(at: vertexIndex, in: geometry.normals)
                let worldNormal = anchorTransform * SIMD4<Float>(normal.x, normal.y, normal.z, 0)
                normals.append(SIMD3<Float>(worldNormal.x, worldNormal.y, worldNormal.z))
            }
            let indexBuffer = geometry.faces
            guard indexBuffer.bytesPerIndex == MemoryLayout<UInt32>.size else {
                notes.append("Unsupported mesh index size \(indexBuffer.bytesPerIndex); anchor skipped.")
                continue
            }
            let indexCount = indexBuffer.count * indexBuffer.indexCountPerPrimitive
            let pointer = indexBuffer.buffer.contents()
                .bindMemory(to: UInt32.self, capacity: indexCount)
            for index in 0..<indexCount {
                faces.append(baseIndex + pointer[index])
            }
        }

        let ply = RoomCaptureBundlePLYWriter.makeBinaryPLY(
            vertices: vertices,
            normals: normals,
            faces: faces
        )
        do {
            try ply.write(
                to: directoryURL.appendingPathComponent(
                    RoomCaptureBundleLibrary.sceneMeshFileName
                ),
                options: .atomic
            )
        } catch {
            notes.append("Scene mesh write failed: \(error.localizedDescription)")
            return (meshAnchors.count, 0, 0)
        }
        return (meshAnchors.count, vertices.count, faces.count / 3)
    }

    private nonisolated static func vertex(
        at index: Int,
        in source: ARGeometrySource
    ) -> SIMD3<Float> {
        let pointer = source.buffer.contents()
            .advanced(by: source.offset + source.stride * index)
        let values = pointer.bindMemory(to: Float.self, capacity: 3)
        return SIMD3<Float>(values[0], values[1], values[2])
    }

    private nonisolated static func columnMajor(_ matrix: simd_float4x4) -> [Double] {
        (0..<4).flatMap { column in
            (0..<4).map { row in Double(matrix[column][row]) }
        }
    }

    private nonisolated static func columnMajor(_ matrix: simd_float3x3) -> [Double] {
        (0..<3).flatMap { column in
            (0..<3).map { row in Double(matrix[column][row]) }
        }
    }
}
