import Foundation
import ImageIO
import RoomScanCore
import UniformTypeIdentifiers

/// Roadmap Phase B1 (docs/PHOTOREAL_ROADMAP.md): package a room's capture
/// bundle as a single zip a Mac or cloud GPU can train a Gaussian splat from.
/// The zip contains the bundle verbatim plus two derived training artifacts:
/// a nerfstudio-compatible `transforms.json` (per-frame OPENCV intrinsics,
/// row-major camera-to-world matrices in the OpenGL convention ARKit already
/// uses, `ply_file_path` seed points, `depth_file_path` supervision) and
/// 16-bit grayscale millimeter PNGs converted from the recorded LiDAR depth
/// (zero = unknown), per the nerfstudio data conventions and OpenSplat's
/// nerfstudio parser (verified against both, 2026-08-10).
enum RoomCaptureBundleTrainingExport {
    static let transformsFileName = "transforms.json"
    static let depthSubdirectoryName = "depth"
    static let coloredMeshFileName = "scene-mesh-colored.ply"

    enum ExportError: LocalizedError {
        case bundleMissing
        case manifestMissing
        case noUsableFrames

        var errorDescription: String? {
            switch self {
            case .bundleMissing:
                return "This room has no capture bundle to export."
            case .manifestMissing:
                return "The capture bundle's manifest could not be read."
            case .noUsableFrames:
                return "The capture bundle contains no exportable keyframes."
            }
        }
    }

    // MARK: - transforms.json (pure, unit-testable)

    /// Builds the nerfstudio `transforms.json`. `depthPNGFrameFileNames` lists
    /// the keyframe JPEGs whose depth PNG actually materialized; only those
    /// frames get a `depth_file_path`.
    static func makeTransformsJSON(
        manifest: RoomCaptureBundleManifest,
        plyEntryPath: String?,
        depthPNGFrameFileNames: Set<String>
    ) throws -> Data {
        var frames: [[String: Any]] = []
        for frame in manifest.frames {
            guard
                frame.cameraTransform.count == 16,
                frame.intrinsics.count == 9,
                frame.cameraTransform.allSatisfy(\.isFinite),
                frame.intrinsics.allSatisfy(\.isFinite)
            else { continue }
            let m = frame.cameraTransform
            var entry: [String: Any] = [
                "file_path": "\(RoomCaptureBundleLibrary.framesSubdirectoryName)/\(frame.fileName)",
                "fl_x": frame.intrinsics[0],
                "fl_y": frame.intrinsics[4],
                "cx": frame.intrinsics[6],
                "cy": frame.intrinsics[7],
                "w": frame.imageWidth,
                "h": frame.imageHeight,
                // Stored column-major; nerfstudio wants nested rows of the
                // same camera-to-world matrix (ARKit is already OpenGL-style:
                // x right, y up, -z forward). The homogeneous last row is
                // emitted exactly — device captures carry float noise there
                // (e.g. 0.9999998) that a strict parser could reject.
                "transform_matrix": [
                    [m[0], m[4], m[8], m[12]],
                    [m[1], m[5], m[9], m[13]],
                    [m[2], m[6], m[10], m[14]],
                    [0, 0, 0, 1],
                ],
            ]
            if depthPNGFrameFileNames.contains(frame.fileName) {
                entry["depth_file_path"] = "\(depthSubdirectoryName)/\(Self.depthPNGFileName(forFrame: frame.fileName))"
            }
            frames.append(entry)
        }
        guard !frames.isEmpty else { throw ExportError.noUsableFrames }

        var root: [String: Any] = [
            "camera_model": "OPENCV",
            // ARKit color intrinsics are effectively undistorted pinhole.
            "k1": 0, "k2": 0, "p1": 0, "p2": 0,
            "w": manifest.frames[0].imageWidth,
            "h": manifest.frames[0].imageHeight,
            "frames": frames,
        ]
        if let plyEntryPath {
            root["ply_file_path"] = plyEntryPath
        }
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    static func depthPNGFileName(forFrame frameFileName: String) -> String {
        "\((frameFileName as NSString).deletingPathExtension)-depth.png"
    }

    // MARK: - Depth PNG conversion (pure, unit-testable)

    /// 16-bit grayscale PNG in millimeters, zero meaning unknown — the
    /// nerfstudio depth-supervision convention.
    static func makeDepthPNG16(
        depthMeters: [Float],
        width: Int,
        height: Int
    ) -> Data? {
        guard width > 0, height > 0, depthMeters.count == width * height else { return nil }
        var bigEndianPixels = [UInt8]()
        bigEndianPixels.reserveCapacity(depthMeters.count * 2)
        for value in depthMeters {
            let millimeters: UInt16
            if value.isFinite, value > 0 {
                millimeters = UInt16(min(max((value * 1000).rounded(), 0), 65535))
            } else {
                millimeters = 0
            }
            bigEndianPixels.append(UInt8(millimeters >> 8))
            bigEndianPixels.append(UInt8(millimeters & 0xFF))
        }
        guard
            let provider = CGDataProvider(data: Data(bigEndianPixels) as CFData),
            let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 16,
                bitsPerPixel: 16,
                bytesPerRow: width * 2,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
                    .union(.byteOrder16Big),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: - Zip assembly

    /// Builds the shareable zip in a temporary location. CPU/IO heavy; call
    /// from a background task. The caller owns (and later deletes) the file.
    static func buildExportZip(
        forProject projectID: String
    ) async throws -> (url: URL, receipt: RoomZIPArchiveReceipt) {
        guard let bundleDirectory = RoomCaptureBundleLibrary.bundleDirectory(forProject: projectID) else {
            throw ExportError.bundleMissing
        }
        guard let manifest = RoomCaptureBundleLibrary.manifest(forProject: projectID) else {
            throw ExportError.manifestMissing
        }
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appendingPathComponent(
            "capture-bundle-export-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: staging) }
        let depthStaging = staging.appendingPathComponent(depthSubdirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: depthStaging, withIntermediateDirectories: true)

        // Derived depth PNGs; a frame whose payload fails to convert simply
        // exports without depth supervision.
        var depthPNGFrames = Set<String>()
        var inputs: [RoomZIPInput] = []
        for frame in manifest.frames {
            guard let depth = frame.depth else { continue }
            let binURL = bundleDirectory
                .appendingPathComponent(RoomCaptureBundleLibrary.framesSubdirectoryName)
                .appendingPathComponent(depth.fileName)
            guard
                depth.compression == RoomCaptureBundleDepthCodec.compressionName,
                depth.pixelFormat == RoomCaptureBundleDepthCodec.depthPixelFormatName,
                let compressed = try? Data(contentsOf: binURL),
                let packed = RoomCaptureBundleDepthCodec.decompress(
                    compressed,
                    expectedByteCount: depth.width * depth.height * 4
                )
            else { continue }
            let meters = packed.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            guard let png = Self.makeDepthPNG16(
                depthMeters: meters,
                width: depth.width,
                height: depth.height
            ) else { continue }
            let pngName = Self.depthPNGFileName(forFrame: frame.fileName)
            let pngURL = depthStaging.appendingPathComponent(pngName)
            do {
                try png.write(to: pngURL, options: .atomic)
            } catch {
                continue
            }
            depthPNGFrames.insert(frame.fileName)
            inputs.append(
                RoomZIPInput(
                    sourceURL: pngURL,
                    entryPath: try RoomExportEntryPath("\(depthSubdirectoryName)/\(pngName)"),
                    mediaType: "image/png"
                )
            )
        }

        // The bundle itself, verbatim. Entry paths that cannot be represented
        // are skipped rather than failing the whole export.
        var plyEntryPath: String?
        if let enumerator = fileManager.enumerator(
            at: bundleDirectory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) {
            for case let fileURL as URL in enumerator {
                guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                    continue
                }
                guard
                    let relativePath = Self.relativeEntryPath(of: fileURL, within: bundleDirectory),
                    let entryPath = try? RoomExportEntryPath(relativePath)
                else { continue }
                inputs.append(
                    RoomZIPInput(
                        sourceURL: fileURL,
                        entryPath: entryPath,
                        mediaType: Self.mediaType(forPath: relativePath)
                    )
                )
                // Prefer the colored mesh as splat seed points; the plain
                // scene mesh is the fallback.
                if relativePath == coloredMeshFileName {
                    plyEntryPath = relativePath
                } else if relativePath == RoomCaptureBundleLibrary.sceneMeshFileName, plyEntryPath == nil {
                    plyEntryPath = relativePath
                }
            }
        }

        let transformsData = try makeTransformsJSON(
            manifest: manifest,
            plyEntryPath: plyEntryPath,
            depthPNGFrameFileNames: depthPNGFrames
        )
        let transformsURL = staging.appendingPathComponent(transformsFileName)
        try transformsData.write(to: transformsURL, options: .atomic)
        inputs.append(
            RoomZIPInput(
                sourceURL: transformsURL,
                entryPath: try RoomExportEntryPath(transformsFileName),
                mediaType: "application/json"
            )
        )

        let zipURL = fileManager.temporaryDirectory
            .appendingPathComponent("capture-bundle-\(projectID).zip")
        if fileManager.fileExists(atPath: zipURL.path) {
            try fileManager.removeItem(at: zipURL)
        }
        let receipt = try await RoomDeterministicZIP.write(inputs: inputs, to: zipURL)
        return (zipURL, receipt)
    }

    /// Relative path of `fileURL` inside `root`, with symlinks resolved on
    /// BOTH sides first: on device, /var is a symlink to /private/var and
    /// Foundation mixes the two representations between a directory URL and
    /// its enumerator's children, so naive prefix stripping produces an
    /// absolute (invalid) entry path. Device-observed 2026-08-10.
    static func relativeEntryPath(of fileURL: URL, within root: URL) -> String? {
        let resolvedRoot = root.resolvingSymlinksInPath().path
        let resolvedFile = fileURL.resolvingSymlinksInPath().path
        guard resolvedFile.hasPrefix(resolvedRoot + "/") else { return nil }
        return String(resolvedFile.dropFirst(resolvedRoot.count + 1))
    }

    private static func mediaType(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "json": return "application/json"
        case "png": return "image/png"
        case "ply": return "application/octet-stream"
        default: return "application/octet-stream"
        }
    }
}
