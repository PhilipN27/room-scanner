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
    var keyframeCount: Int
    var boundsMin: SIMD3<Float>
    var boundsMax: SIMD3<Float>
    var usedCachedColors: Bool
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
    static let coloredMeshFileName = "scene-mesh-colored.ply"
    /// Keyframe JPEGs are downsampled to this bound before color sampling;
    /// full-resolution decoding of every keyframe would cost hundreds of MB.
    private static let sampleImageMaxPixelSize = 512

    /// Cheap room-profile gate: a renderable bundle mesh exists.
    static func hasRenderableMesh(forProject projectID: String) -> Bool {
        guard let directory = RoomCaptureBundleLibrary.bundleDirectory(forProject: projectID) else {
            return false
        }
        let meshURL = directory.appendingPathComponent(RoomCaptureBundleLibrary.sceneMeshFileName)
        return FileManager.default.fileExists(atPath: meshURL.path)
    }

    /// Loads the bundle mesh with per-vertex colors, computing and caching the
    /// colorization on first open. CPU-heavy; call from a background task.
    static func load(forProject projectID: String) throws -> RoomMeshColoredResult {
        let started = Date()
        let result = try loadUntimed(forProject: projectID)
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

    private static func loadUntimed(forProject projectID: String) throws -> RoomMeshColoredResult {
        guard let directory = RoomCaptureBundleLibrary.bundleDirectory(forProject: projectID) else {
            throw RoomMeshViewerError.bundleMissing
        }

        // Cached colored mesh: adopted bundles replace the whole directory,
        // so a stale cache cannot outlive the bundle it was derived from.
        let coloredURL = directory.appendingPathComponent(coloredMeshFileName)
        let manifest = RoomCaptureBundleLibrary.manifest(forProject: projectID)
        let keyframeCount = manifest?.frames.count ?? 0
        if let cachedData = try? Data(contentsOf: coloredURL),
           let cached = try? RoomMeshBinaryPLY.read(cachedData),
           cached.colors.count == cached.vertices.count,
           !cached.vertices.isEmpty {
            return makeResult(mesh: cached, keyframeCount: keyframeCount, usedCachedColors: true)
        }

        let meshURL = directory.appendingPathComponent(RoomCaptureBundleLibrary.sceneMeshFileName)
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

        let keyframes = loadKeyframeSamples(manifest: manifest, bundleDirectory: directory)
        let colorized = RoomMeshKeyframeColorizer.colorize(
            vertices: mesh.vertices,
            normals: mesh.normals,
            faces: mesh.faces,
            keyframes: keyframes
        )
        mesh.colors = colorized.colors

        // Cache write is best-effort; the in-memory result is already usable.
        try? RoomMeshBinaryPLY.write(mesh).write(to: coloredURL, options: .atomic)
        return makeResult(mesh: mesh, keyframeCount: keyframes.count, usedCachedColors: false)
    }

    private static func makeResult(
        mesh: RoomMeshPLYMesh,
        keyframeCount: Int,
        usedCachedColors: Bool
    ) -> RoomMeshColoredResult {
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
            keyframeCount: keyframeCount,
            boundsMin: minBounds,
            boundsMax: maxBounds,
            usedCachedColors: usedCachedColors
        )
    }

    private static func loadKeyframeSamples(
        manifest: RoomCaptureBundleManifest?,
        bundleDirectory: URL
    ) -> [RoomMeshKeyframeSample] {
        guard let manifest else { return [] }
        let framesDirectory = bundleDirectory.appendingPathComponent(
            RoomCaptureBundleLibrary.framesSubdirectoryName,
            isDirectory: true
        )
        var samples: [RoomMeshKeyframeSample] = []
        samples.reserveCapacity(manifest.frames.count)
        for frame in manifest.frames {
            let imageURL = framesDirectory.appendingPathComponent(frame.fileName)
            guard let image = decodeDownsampledRGBA(at: imageURL) else { continue }
            samples.append(
                RoomMeshKeyframeSample(
                    cameraToWorldColumnMajor: frame.cameraTransform,
                    intrinsicsColumnMajor: frame.intrinsics,
                    sensorWidth: frame.imageWidth,
                    sensorHeight: frame.imageHeight,
                    imageWidth: image.width,
                    imageHeight: image.height,
                    imageRGBA: image.rgba
                )
            )
        }
        return samples
    }

    /// Decodes a keyframe JPEG downsampled and returns tightly packed RGBA
    /// bytes in the stored (sensor) orientation, matching the intrinsics.
    private static func decodeDownsampledRGBA(
        at url: URL
    ) -> (width: Int, height: Int, rgba: [UInt8])? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: sampleImageMaxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: false,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
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
}

// MARK: - Metal renderer

/// The mesh pipeline is small enough to compile from source at runtime, which
/// keeps the target free of a .metal build phase.
private enum RoomMeshShaderSource {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
        float3 position [[attribute(0)]];
        float4 color [[attribute(1)]];
    };

    struct VertexOut {
        float4 position [[position]];
        float4 color;
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
        out.color = in.color;
        return out;
    }

    fragment float4 room_mesh_fragment(VertexOut in [[stage_in]]) {
        return in.color;
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
    private var indexCount = 0
    private var drawableSize: CGSize = .zero
    private var lastFrameTimestamp: Date?

    init(camera: SplatCameraController) {
        self.camera = camera
    }

    func attach(view: MTKView) {
        commandQueue = view.device?.makeCommandQueue()
        drawableSize = view.drawableSize
    }

    func load(result: RoomMeshColoredResult) throws {
        guard let device = commandQueue?.device else {
            throw RoomMeshViewerError.metalUnavailable
        }

        let library = try device.makeLibrary(source: RoomMeshShaderSource.source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "room_mesh_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "room_mesh_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        descriptor.depthAttachmentPixelFormat = .depth32Float

        // Interleaved layout: float3 position + uchar4 color, 16-byte stride.
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .uchar4Normalized
        vertexDescriptor.attributes[1].offset = 12
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = 16
        descriptor.vertexDescriptor = vertexDescriptor
        pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: depthDescriptor)

        var vertexBytes = [UInt8]()
        vertexBytes.reserveCapacity(result.mesh.vertices.count * 16)
        for index in result.mesh.vertices.indices {
            let vertex = result.mesh.vertices[index]
            withUnsafeBytes(of: vertex.x.bitPattern.littleEndian) { vertexBytes.append(contentsOf: $0) }
            withUnsafeBytes(of: vertex.y.bitPattern.littleEndian) { vertexBytes.append(contentsOf: $0) }
            withUnsafeBytes(of: vertex.z.bitPattern.littleEndian) { vertexBytes.append(contentsOf: $0) }
            let color = index < result.mesh.colors.count
                ? result.mesh.colors[index]
                : RoomMeshKeyframeColorizer.uncoloredGray
            vertexBytes.append(contentsOf: [color.x, color.y, color.z, 255])
        }
        guard
            let vertexBuffer = device.makeBuffer(bytes: vertexBytes, length: vertexBytes.count),
            let indexBuffer = device.makeBuffer(
                bytes: result.mesh.faces,
                length: result.mesh.faces.count * MemoryLayout<UInt32>.size
            )
        else {
            throw RoomMeshViewerError.metalUnavailable
        }
        self.vertexBuffer = vertexBuffer
        self.indexBuffer = indexBuffer
        indexCount = result.mesh.faces.count
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
        view.sampleCount = 1
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

    @StateObject private var camera = SplatCameraController(
        appliesSplatUpAxisCalibration: false
    )
    @State private var loadState: LoadState = .loading

    private enum LoadState {
        case loading
        case ready(RoomMeshColoredResult)
        case failed(message: String)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            switch loadState {
            case .loading:
                VStack(spacing: 14) {
                    ProgressView("Coloring the scanned mesh from keyframes...")
                        .tint(AppPalette.blueprintOnDark)
                        .foregroundStyle(AppPalette.primaryOnDark)
                    Text("First open computes vertex colors once, then caches them.")
                        .font(AppTypography.measurement)
                        .foregroundStyle(AppPalette.mutedOnDark)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(AppTypography.measurement)
                    .foregroundStyle(AppPalette.amberOnDark)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("meshViewer.error")
            case let .ready(result):
                RoomMeshMetalView(result: result, camera: camera) { error in
                    if let error {
                        loadState = .failed(message: error.localizedDescription)
                    }
                }
                .ignoresSafeArea()

                controls(result)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if case .ready = loadState, camera.mode == .firstPerson {
                SplatWalkJoystick(camera: camera)
                    .padding(.trailing, 28)
                    .padding(.bottom, 170)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Colored mesh room")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: projectID) {
            guard case .loading = loadState else { return }
            let projectID = projectID
            let loaded: Result<RoomMeshColoredResult, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try RoomMeshBundleLoader.load(forProject: projectID))
                } catch {
                    return .failure(error)
                }
            }.value
            switch loaded {
            case let .success(result):
                configureCamera(for: result)
                loadState = .ready(result)
            case let .failure(error):
                loadState = .failed(message: error.localizedDescription)
            }
        }
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
