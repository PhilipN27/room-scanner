import RoomScanCore
import UIKit
import XCTest
@testable import RoomScanStudio

/// End-to-end colored-mesh loading against a synthetic capture bundle: real
/// manifest JSON, real JPEG decode, real projection colorization, real color
/// cache. This is the simulator-side oracle for the colored mesh viewer; only
/// Metal drawing itself needs the physical-device gate.
@MainActor
final class RoomMeshViewerAppTests: XCTestCase {
    private var projectID = ""

    override func setUp() {
        super.setUp()
        projectID = "mesh-viewer-test-\(UUID().uuidString)"
    }

    override func tearDown() {
        try? RoomCaptureBundleLibrary.removeBundle(forProject: projectID)
        super.tearDown()
    }

    func testLoadColorsMeshFromSyntheticBundleAndCachesResult() throws {
        try adoptSyntheticBundle(imageColor: UIColor(red: 1, green: 0, blue: 0, alpha: 1))

        XCTAssertTrue(RoomMeshBundleLoader.hasRenderableMesh(forProject: projectID))

        let first = try RoomMeshBundleLoader.load(forProject: projectID)
        XCTAssertFalse(first.usedCachedColors)
        XCTAssertEqual(first.mesh.vertices.count, 4, "connected coplanar faces share one coherent chart")
        XCTAssertEqual(first.keyframeCount, 1)
        XCTAssertEqual(first.mesh.colors.count, 4)
        XCTAssertEqual(first.photorealMesh.textureValid, Array(repeating: 1, count: 4))
        XCTAssertNotNil(first.atlasPNG)
        for color in first.mesh.colors {
            XCTAssertGreaterThan(color.x, 200, "keyframe-facing vertices must take the red image color")
            XCTAssertLessThan(color.y, 60)
            XCTAssertLessThan(color.z, 60)
        }
        XCTAssertEqual(first.boundsMin.z, -1)
        XCTAssertEqual(first.boundsMax.z, -1)

        let bundle = try XCTUnwrap(RoomCaptureBundleLibrary.bundleDirectory(forProject: projectID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent(
            RoomMeshPhotorealCache.manifestFileName
        ).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent(
            RoomMeshPhotorealCache.meshFileName
        ).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent(
            RoomMeshPhotorealCache.atlasFileName
        ).path))

        let second = try RoomMeshBundleLoader.load(forProject: projectID)
        XCTAssertTrue(second.usedCachedColors, "second open must reuse the cached colored mesh")
        XCTAssertEqual(second.mesh.colors, first.mesh.colors)

        let frameURL = bundle
            .appendingPathComponent(RoomCaptureBundleLibrary.framesSubdirectoryName)
            .appendingPathComponent("frame-00001.jpg")
        var changedFrame = try Data(contentsOf: frameURL)
        changedFrame.append(0)
        try changedFrame.write(to: frameURL, options: .atomic)
        let invalidated = try RoomMeshBundleLoader.load(forProject: projectID)
        XCTAssertFalse(invalidated.usedCachedColors, "source frame fingerprint changes must invalidate v3")
    }

    func testUncachedLoadReportsMeasuredMonotonicProgressAndCacheHitCompletesSkippedPhases() throws {
        try adoptSyntheticBundle(imageColor: .red, drawCheckerboard: true)
        let lock = NSLock()
        var firstEvents: [RoomMeshColoringProgress] = []
        let first = try RoomMeshBundleLoader.load(forProject: projectID) { event in
            lock.lock()
            firstEvents.append(event)
            lock.unlock()
        }
        XCTAssertFalse(first.usedCachedColors)

        lock.lock()
        let uncached = firstEvents
        lock.unlock()
        XCTAssertFalse(uncached.isEmpty)
        XCTAssertTrue(zip(uncached, uncached.dropFirst()).allSatisfy { $0.sequence < $1.sequence })
        XCTAssertTrue(zip(uncached, uncached.dropFirst()).allSatisfy { $0.fraction <= $1.fraction })
        XCTAssertEqual(uncached.last?.phase, .publishingCache)
        XCTAssertEqual(uncached.last?.fraction ?? -1, 0.99, accuracy: 0.000_001)
        for phase in RoomMeshColoringPhase.allCases where phase != .preparingRenderer {
            XCTAssertTrue(uncached.contains { $0.phase == phase }, "missing measured phase \(phase)")
        }
        XCTAssertEqual(
            uncached.last(where: { $0.phase == .measuringSharpness })?.completedUnits,
            1
        )
        XCTAssertEqual(
            uncached.last(where: { $0.phase == .projectingColors })?.completedUnits,
            1
        )
        XCTAssertEqual(
            uncached.last(where: { $0.phase == .assigningFaces })?.completedUnits,
            2
        )

        var cachedEvents: [RoomMeshColoringProgress] = []
        let cached = try RoomMeshBundleLoader.load(forProject: projectID) { event in
            lock.lock()
            cachedEvents.append(event)
            lock.unlock()
        }
        XCTAssertTrue(cached.usedCachedColors)
        lock.lock()
        let cacheHit = cachedEvents
        lock.unlock()
        XCTAssertTrue(zip(cacheHit, cacheHit.dropFirst()).allSatisfy { $0.fraction <= $1.fraction })
        XCTAssertEqual(cacheHit.last?.fraction ?? -1, 0.99, accuracy: 0.000_001)
        for phase in RoomMeshColoringPhase.allCases where phase != .preparingRenderer {
            XCTAssertTrue(cacheHit.contains { $0.phase == phase }, "cache hit did not complete \(phase)")
        }
    }

    func testColoringCancellationStopsBeforePublishingCacheManifest() async throws {
        try adoptSyntheticBundle(imageColor: .red)
        let reachedBoundary = expectation(description: "sharpness phase completed")
        let gate = DispatchSemaphore(value: 0)
        let worker = Task.detached { [projectID] in
            try RoomMeshBundleLoader.load(forProject: projectID) { event in
                if event.phase == .measuringSharpness, event.completedUnits == event.totalUnits {
                    reachedBoundary.fulfill()
                    gate.wait()
                }
            }
        }

        await fulfillment(of: [reachedBoundary], timeout: 5)
        worker.cancel()
        gate.signal()
        do {
            _ = try await worker.value
            XCTFail("cancelled coloring unexpectedly produced a result")
        } catch is CancellationError {
            // Expected cooperative cancellation.
        }

        let bundle = try XCTUnwrap(RoomCaptureBundleLibrary.bundleDirectory(forProject: projectID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.appendingPathComponent(
            RoomMeshPhotorealCache.manifestFileName
        ).path))
    }

    func testMalformedDepthKeepsRGBAndMissingImageFallsBackToVertexOnly() throws {
        try adoptSyntheticBundle(
            imageColor: UIColor(red: 0, green: 1, blue: 0, alpha: 1),
            includeMalformedDepth: true
        )
        let malformedDepth = try RoomMeshBundleLoader.load(forProject: projectID)
        XCTAssertNotNil(malformedDepth.atlasPNG)
        XCTAssertTrue(malformedDepth.mesh.colors.allSatisfy { $0.y > 200 })

        try RoomCaptureBundleLibrary.removeBundle(forProject: projectID)
        projectID = "mesh-viewer-test-\(UUID().uuidString)"
        try adoptSyntheticBundle(imageColor: .red)
        let bundle = try XCTUnwrap(RoomCaptureBundleLibrary.bundleDirectory(forProject: projectID))
        try FileManager.default.removeItem(at: bundle
            .appendingPathComponent(RoomCaptureBundleLibrary.framesSubdirectoryName)
            .appendingPathComponent("frame-00001.jpg"))
        let fallback = try RoomMeshBundleLoader.load(forProject: projectID)
        XCTAssertNil(fallback.atlasPNG)
        XCTAssertTrue(fallback.photorealMesh.textureValid.allSatisfy { $0 == 0 })
        XCTAssertTrue(fallback.mesh.colors.allSatisfy { $0 == RoomMeshKeyframeColorizer.uncoloredGray })
        XCTAssertTrue(fallback.warnings.contains(.unreadableKeyframes(1)))
        XCTAssertTrue(fallback.warnings.contains(.unusableManifest))
    }

    func testAtlasPreservesCheckerboardDetailInsideLargeTriangles() throws {
        try adoptSyntheticBundle(imageColor: .black, drawCheckerboard: true)
        let result = try RoomMeshBundleLoader.load(forProject: projectID)
        let data = try XCTUnwrap(result.atlasPNG)
        let image = try XCTUnwrap(UIImage(data: data)?.cgImage)
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let drew = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(drew)
        let pixels = stride(from: 0, to: rgba.count, by: 4)
        XCTAssertGreaterThan(pixels.filter { rgba[$0] > 230 && rgba[$0 + 1] > 230 && rgba[$0 + 2] > 230 }.count, 100)
        XCTAssertGreaterThan(pixels.filter { rgba[$0] < 25 && rgba[$0 + 1] < 25 && rgba[$0 + 2] < 25 }.count, 100)
    }

    func testLoadWithoutBundleThrowsBundleMissing() {
        XCTAssertFalse(RoomMeshBundleLoader.hasRenderableMesh(forProject: projectID))
        XCTAssertThrowsError(try RoomMeshBundleLoader.load(forProject: projectID))
    }

    func testHeroSnapshotRendersMeshPixelsAtRequestedSizeDeterministically() throws {
        // A bright single-triangle mesh in front of the deterministic hero
        // camera: the render must produce a 800x600 PNG whose content is not
        // uniformly background, and identical bytes across two renders.
        var mesh = RoomMeshPhotorealMesh(
            vertices: [
                SIMD3<Float>(-1, 0, -1), SIMD3<Float>(1, 0, -1), SIMD3<Float>(0, 2, 1),
            ],
            normals: [],
            fallbackColors: [
                SIMD3<UInt8>(255, 40, 40), SIMD3<UInt8>(40, 255, 40), SIMD3<UInt8>(40, 40, 255),
            ],
            uvs: [.zero, .zero, .zero],
            textureValid: [0, 0, 0],
            faces: [0, 1, 2]
        )
        mesh.normals = []
        let result = RoomMeshColoredResult(
            mesh: RoomMeshPLYMesh(vertices: mesh.vertices, normals: [], colors: mesh.fallbackColors, faces: mesh.faces),
            photorealMesh: mesh,
            atlasPNG: nil,
            keyframeCount: 0,
            boundsMin: SIMD3<Float>(-1, 0, -1),
            boundsMax: SIMD3<Float>(1, 2, 1),
            usedCachedColors: false,
            warnings: []
        )

        let first = try RoomMeshHeroRenderer.renderPNG(result: result)
        let second = try RoomMeshHeroRenderer.renderPNG(result: result)
        XCTAssertEqual(first, second, "hero rendering must be deterministic")

        let image = try XCTUnwrap(UIImage(data: first))
        XCTAssertEqual(Int(image.size.width * image.scale), RoomMeshHeroRenderer.pixelWidth)
        XCTAssertEqual(Int(image.size.height * image.scale), RoomMeshHeroRenderer.pixelHeight)

        // Sample a grid of pixels; the triangle must contribute non-background
        // color somewhere near the center of frame.
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &rgba, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var foundForeground = false
        for y in stride(from: 0, to: height, by: 8) where !foundForeground {
            for x in stride(from: 0, to: width, by: 8) {
                let offset = (y * width + x) * 4
                if rgba[offset] > 24 || rgba[offset + 1] > 24 || rgba[offset + 2] > 24 {
                    foundForeground = true
                    break
                }
            }
        }
        XCTAssertTrue(foundForeground, "render must contain mesh pixels, not just background")
    }

    func testTexturedShaderAndMSAAFallbackContract() {
        XCTAssertTrue(RoomMeshShaderSource.source.contains("room_mesh_textured_fragment"))
        XCTAssertTrue(RoomMeshShaderSource.source.contains("room_mesh_srgb_to_linear"))
        XCTAssertTrue(RoomMeshShaderSource.source.contains("textureValid > 0.5"))
        XCTAssertEqual(RoomMeshRenderCoordinator.preferredSampleCount { [1, 2, 4].contains($0) }, 4)
        XCTAssertEqual(RoomMeshRenderCoordinator.preferredSampleCount { [1, 2].contains($0) }, 2)
        XCTAssertEqual(RoomMeshRenderCoordinator.preferredSampleCount { $0 == 1 }, 1)
    }

    func testColoringProgressMapsMeasuredUnitsIntoStablePhaseRanges() {
        XCTAssertEqual(RoomMeshColoringPhase.preparing.range, 0.00...0.03)
        XCTAssertEqual(RoomMeshColoringPhase.measuringSharpness.range, 0.03...0.13)
        XCTAssertEqual(RoomMeshColoringPhase.projectingColors.range, 0.13...0.53)
        XCTAssertEqual(RoomMeshColoringPhase.normalizingColors.range, 0.53...0.60)
        XCTAssertEqual(RoomMeshColoringPhase.assigningFaces.range, 0.60...0.70)
        XCTAssertEqual(RoomMeshColoringPhase.packingCharts.range, 0.70...0.78)
        XCTAssertEqual(RoomMeshColoringPhase.bakingAtlas.range, 0.78...0.94)
        XCTAssertEqual(RoomMeshColoringPhase.fillingPadding.range, 0.94...0.97)
        XCTAssertEqual(RoomMeshColoringPhase.publishingCache.range, 0.97...0.99)
        XCTAssertEqual(RoomMeshColoringPhase.preparingRenderer.range, 0.99...1.00)

        let halfway = RoomMeshColoringProgress(
            sequence: 4,
            phase: .projectingColors,
            completedUnits: 5,
            totalUnits: 10,
            detail: "Frame 5 of 10"
        )
        XCTAssertEqual(halfway.fraction, 0.33, accuracy: 0.000_001)
        XCTAssertEqual(halfway.percent, 33)
        XCTAssertEqual(halfway.detail, "Frame 5 of 10")

        let clamped = RoomMeshColoringProgress(
            sequence: 5,
            phase: .assigningFaces,
            completedUnits: 20,
            totalUnits: 10,
            detail: nil
        )
        XCTAssertEqual(clamped.completedUnits, 10)
        XCTAssertEqual(clamped.fraction, 0.70, accuracy: 0.000_001)
    }

    func testColoringProgressReporterNeverRegressesAndSequencesEvents() {
        let lock = NSLock()
        var events: [RoomMeshColoringProgress] = []
        let reporter = RoomMeshProgressReporter { progress in
            lock.lock()
            events.append(progress)
            lock.unlock()
        }

        reporter.report(phase: .projectingColors, completed: 8, total: 10, detail: nil)
        reporter.report(phase: .measuringSharpness, completed: 1, total: 10, detail: nil)
        reporter.report(phase: .projectingColors, completed: 10, total: 10, detail: nil)

        lock.lock()
        let captured = events
        lock.unlock()
        XCTAssertEqual(captured.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(captured.count, 3)
        XCTAssertTrue(zip(captured, captured.dropFirst()).allSatisfy { $0.fraction <= $1.fraction })
        XCTAssertEqual(captured[1].fraction, captured[0].fraction, accuracy: 0.000_001)
        XCTAssertEqual(captured.last?.fraction ?? -1, 0.53, accuracy: 0.000_001)
    }

    func testColoringStallTrackerWarnsOnlyAfterThirtySecondsWithoutNewWork() {
        var tracker = RoomMeshStallTracker(startedAt: 100)
        XCTAssertFalse(tracker.isStalled(at: 129.999))
        XCTAssertTrue(tracker.isStalled(at: 130))

        let progress = RoomMeshColoringProgress(
            sequence: 1,
            phase: .projectingColors,
            completedUnits: 1,
            totalUnits: 10,
            detail: "Frame 1 of 10"
        )
        XCTAssertTrue(tracker.record(progress, at: 131))
        XCTAssertFalse(tracker.isStalled(at: 160.999))
        XCTAssertTrue(tracker.isStalled(at: 161))

        tracker.keepWaiting(at: 162)
        XCTAssertFalse(tracker.isStalled(at: 191.999))
        XCTAssertTrue(tracker.isStalled(at: 192))
        XCTAssertFalse(tracker.record(progress, at: 193), "duplicate events are not measurable progress")
    }

    func testColoringFailuresProvideActionableRecoveryMessages() {
        let missing = RoomMeshLoadFailure.message(for: RoomMeshViewerError.bundleMissing)
        XCTAssertTrue(missing.contains("scan"))
        XCTAssertTrue(missing.contains("Try again"))

        let unreadable = RoomMeshLoadFailure.message(
            for: RoomMeshViewerError.meshUnreadable("bad face index")
        )
        XCTAssertTrue(unreadable.contains("source mesh"))
        XCTAssertTrue(unreadable.contains("Try again"))

        let unexpected = RoomMeshLoadFailure.message(for: CocoaError(.fileReadCorruptFile))
        XCTAssertTrue(unexpected.contains("Coloring failed"))
        XCTAssertTrue(unexpected.contains("Try again"))
    }

    func testColoringAccessibilityIdentifiersAreStable() {
        XCTAssertEqual(RoomMeshColoringAccessibility.progress, "meshViewer.progress")
        XCTAssertEqual(RoomMeshColoringAccessibility.percent, "meshViewer.percent")
        XCTAssertEqual(RoomMeshColoringAccessibility.phase, "meshViewer.phase")
        XCTAssertEqual(RoomMeshColoringAccessibility.detail, "meshViewer.progressDetail")
        XCTAssertEqual(RoomMeshColoringAccessibility.stall, "meshViewer.stall")
        XCTAssertEqual(RoomMeshColoringAccessibility.cancel, "meshViewer.cancel")
        XCTAssertEqual(RoomMeshColoringAccessibility.retry, "meshViewer.retry")
        XCTAssertEqual(RoomMeshColoringAccessibility.error, "meshViewer.error")
        XCTAssertEqual(RoomMeshColoringAccessibility.warning, "meshViewer.warning")
    }

    func testColoringControllerReservesOneHundredPercentForRendererReadiness() async throws {
        try adoptSyntheticBundle(imageColor: .red)
        let controller = RoomMeshLoadController()
        controller.start(projectID: projectID)
        defer { controller.stop() }

        for _ in 0..<200 where controller.result == nil && controller.failureMessage == nil {
            try await Task.sleep(for: .milliseconds(50))
        }

        _ = try XCTUnwrap(controller.result)
        XCTAssertNil(controller.failureMessage)
        XCTAssertEqual(controller.progress.phase, .preparingRenderer)
        XCTAssertEqual(controller.progress.percent, 99)
        XCTAssertFalse(controller.rendererReady)

        controller.rendererDidFinish(error: nil)
        XCTAssertEqual(controller.progress.percent, 100)
        XCTAssertTrue(controller.rendererReady)
        XCTAssertFalse(controller.isLoading)
    }

    /// A quad at z = -1 facing a camera at the origin that looks down -Z,
    /// photographed by one solid-color 640x480 keyframe.
    private func adoptSyntheticBundle(
        imageColor: UIColor,
        includeMalformedDepth: Bool = false,
        drawCheckerboard: Bool = false
    ) throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mesh-viewer-scratch-\(UUID().uuidString)", isDirectory: true)
        let framesURL = scratch.appendingPathComponent(
            RoomCaptureBundleLibrary.framesSubdirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: framesURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let mesh = RoomMeshPLYMesh(
            vertices: [
                SIMD3<Float>(-0.5, -0.5, -1),
                SIMD3<Float>(0.5, -0.5, -1),
                SIMD3<Float>(0.5, 0.5, -1),
                SIMD3<Float>(-0.5, 0.5, -1),
            ],
            normals: [
                SIMD3<Float>(0, 0, 1),
                SIMD3<Float>(0, 0, 1),
                SIMD3<Float>(0, 0, 1),
                SIMD3<Float>(0, 0, 1),
            ],
            colors: [],
            faces: [0, 1, 2, 0, 2, 3]
        )
        try RoomMeshBinaryPLY.write(mesh).write(
            to: scratch.appendingPathComponent(RoomCaptureBundleLibrary.sceneMeshFileName)
        )

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 480))
        let image = renderer.image { context in
            imageColor.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
            if drawCheckerboard {
                for row in 0..<12 {
                    for column in 0..<16 where (row + column).isMultiple(of: 2) {
                        UIColor.white.setFill()
                        context.fill(CGRect(x: column * 40, y: row * 40, width: 40, height: 40))
                    }
                }
            }
        }
        guard let jpeg = image.jpegData(compressionQuality: 0.9) else {
            XCTFail("synthetic keyframe JPEG could not be encoded")
            return
        }
        try jpeg.write(to: framesURL.appendingPathComponent("frame-00001.jpg"))
        if includeMalformedDepth {
            try Data([1, 2, 3]).write(to: framesURL.appendingPathComponent("frame-00001-depth.bin"))
        }

        let manifest = RoomCaptureBundleManifest(
            schemaVersion: 1,
            createdAt: Date(),
            frames: [
                RoomCaptureBundleFrame(
                    fileName: "frame-00001.jpg",
                    timestamp: 1,
                    cameraTransform: [
                        1, 0, 0, 0,
                        0, 1, 0, 0,
                        0, 0, 1, 0,
                        0, 0, 0, 1,
                    ],
                    intrinsics: [100, 0, 0, 0, 100, 0, 320, 240, 1],
                    imageWidth: 640,
                    imageHeight: 480,
                    exposureDuration: 0.008,
                    depth: includeMalformedDepth ? RoomCaptureBundleFrameDepth(
                        fileName: "frame-00001-depth.bin",
                        confidenceFileName: nil,
                        width: 8,
                        height: 8,
                        compression: RoomCaptureBundleDepthCodec.compressionName,
                        pixelFormat: RoomCaptureBundleDepthCodec.depthPixelFormatName
                    ) : nil
                )
            ],
            meshAnchorCount: 1,
            meshVertexCount: 4,
            meshFaceCount: 2,
            notes: []
        )
        try RoomJSONCoding.makeEncoder().encode(manifest).write(
            to: scratch.appendingPathComponent(RoomCaptureBundleLibrary.manifestFileName)
        )

        try RoomCaptureBundleLibrary.adoptBundle(at: scratch, forProject: projectID)
    }
}
