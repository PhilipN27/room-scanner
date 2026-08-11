import MetalKit
import MetalSplatter
import SplatIO
import SwiftUI
import UniformTypeIdentifiers

/// Phase C0 of the photoreal roadmap (docs/PHOTOREAL_ROADMAP.md): render a
/// Gaussian splat for a saved room with orbit and first-person cameras.
/// Splats are imported files for now (any external trainer); Phases A/B make
/// the app produce them from its own capture bundles.

// MARK: - Sidecar splat storage

/// Imported splats live beside, not inside, the immutable room packages: they
/// are a photoreal preview layer, not reviewed capture evidence. Phase B
/// formalizes trained splats as revision assets.
enum RoomSplatLibrary {
    static let supportedExtensions = ["ply", "splat", "spz"]

    static var importContentTypes: [UTType] {
        supportedExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    private static func directoryURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("RoomScanStudioSplats", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    static func splatURL(forProject projectID: String) -> URL? {
        guard let directory = try? directoryURL() else { return nil }
        for fileExtension in supportedExtensions {
            let candidate = directory.appendingPathComponent("\(projectID).\(fileExtension)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func importSplat(from sourceURL: URL, forProject projectID: String) throws -> URL {
        let fileExtension = sourceURL.pathExtension.lowercased()
        guard supportedExtensions.contains(fileExtension) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let directory = try directoryURL()
        try removeSplat(forProject: projectID)
        let destination = directory.appendingPathComponent("\(projectID).\(fileExtension)")
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    static func removeSplat(forProject projectID: String) throws {
        let directory = try directoryURL()
        for fileExtension in supportedExtensions {
            let candidate = directory.appendingPathComponent("\(projectID).\(fileExtension)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                try FileManager.default.removeItem(at: candidate)
            }
        }
    }
}

// MARK: - Camera

/// Shared camera state driven by gestures and read every frame by the
/// renderer. Orbit mode circles a focus point; first-person mode walks the
/// splat with a look-drag plus a virtual joystick.
@MainActor
final class SplatCameraController: ObservableObject {
    enum Mode: String, CaseIterable {
        case orbit = "Orbit"
        case firstPerson = "First person"
    }

    @Published var mode: Mode = .orbit

    // Orbit state.
    var orbitCenter = SIMD3<Float>(0, 0, 0)
    var orbitDistance: Float = 3
    var orbitYaw: Float = 0
    var orbitPitch: Float = -0.35

    // First-person state.
    var position = SIMD3<Float>(0, 0, 3)
    var lookYaw: Float = 0
    var lookPitch: Float = 0
    /// Joystick input, each axis in -1...1 (x = strafe, y = forward).
    var moveInput = SIMD2<Float>(0, 0)
    private let walkSpeedMetersPerSecond: Float = 1.6

    func reset() {
        orbitCenter = SIMD3<Float>(0, 0, 0)
        orbitDistance = 3
        orbitYaw = 0
        orbitPitch = -0.35
        position = SIMD3<Float>(0, 0, 3)
        lookYaw = 0
        lookPitch = 0
        moveInput = .zero
    }

    func applyOrbitDrag(deltaX: Float, deltaY: Float) {
        orbitYaw += deltaX * 0.008
        orbitPitch = min(max(orbitPitch + deltaY * 0.008, -1.5), 1.5)
    }

    func applyLookDrag(deltaX: Float, deltaY: Float) {
        lookYaw += deltaX * 0.005
        lookPitch = min(max(lookPitch + deltaY * 0.005, -1.5), 1.5)
    }

    func applyZoom(scale: Float) {
        orbitDistance = min(max(orbitDistance / scale, 0.3), 40)
    }

    func applyPan(deltaX: Float, deltaY: Float) {
        let right = SIMD3<Float>(cos(orbitYaw), 0, sin(orbitYaw))
        let up = SIMD3<Float>(0, 1, 0)
        let metersPerPoint = orbitDistance * 0.0015
        orbitCenter -= right * deltaX * metersPerPoint
        orbitCenter += up * deltaY * metersPerPoint
    }

    /// Advances first-person movement; called once per rendered frame.
    func tick(deltaTime: Float) {
        guard mode == .firstPerson, moveInput != .zero else { return }
        let forward = SIMD3<Float>(-sin(lookYaw), 0, -cos(lookYaw))
        let right = SIMD3<Float>(cos(lookYaw), 0, -sin(lookYaw))
        let velocity = (forward * moveInput.y + right * moveInput.x) * walkSpeedMetersPerSecond
        position += velocity * deltaTime
    }

    var viewMatrix: simd_float4x4 {
        // Most 3D GS PLY files are captured y-down; flipping around Z turns
        // them right-side-up (same calibration as MetalSplatter's sample).
        let upCalibration = SplatMatrices.rotation(radians: .pi, axis: SIMD3<Float>(0, 0, 1))
        switch mode {
        case .orbit:
            return SplatMatrices.translation(0, 0, -orbitDistance)
                * SplatMatrices.rotation(radians: orbitPitch, axis: SIMD3<Float>(1, 0, 0))
                * SplatMatrices.rotation(radians: orbitYaw, axis: SIMD3<Float>(0, 1, 0))
                * SplatMatrices.translation(-orbitCenter.x, -orbitCenter.y, -orbitCenter.z)
                * upCalibration
        case .firstPerson:
            return SplatMatrices.rotation(radians: -lookPitch, axis: SIMD3<Float>(1, 0, 0))
                * SplatMatrices.rotation(radians: -lookYaw, axis: SIMD3<Float>(0, 1, 0))
                * SplatMatrices.translation(-position.x, -position.y, -position.z)
                * upCalibration
        }
    }
}

enum SplatMatrices {
    static func rotation(radians: Float, axis: SIMD3<Float>) -> simd_float4x4 {
        let unitAxis = normalize(axis)
        let ct = cosf(radians)
        let st = sinf(radians)
        let ci = 1 - ct
        let x = unitAxis.x, y = unitAxis.y, z = unitAxis.z
        return simd_float4x4(columns: (
            SIMD4<Float>(ct + x * x * ci, y * x * ci + z * st, z * x * ci - y * st, 0),
            SIMD4<Float>(x * y * ci - z * st, ct + y * y * ci, z * y * ci + x * st, 0),
            SIMD4<Float>(x * z * ci + y * st, y * z * ci - x * st, ct + z * z * ci, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    static func translation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4<Float>(x, y, z, 1)
        return matrix
    }

    static func perspective(fovyRadians: Float, aspectRatio: Float, nearZ: Float, farZ: Float) -> simd_float4x4 {
        let ys = 1 / tanf(fovyRadians * 0.5)
        let xs = ys / aspectRatio
        let zs = farZ / (nearZ - farZ)
        return simd_float4x4(columns: (
            SIMD4<Float>(xs, 0, 0, 0),
            SIMD4<Float>(0, ys, 0, 0),
            SIMD4<Float>(0, 0, zs, -1),
            SIMD4<Float>(0, 0, zs * nearZ, 0)
        ))
    }
}

// MARK: - Metal view

private struct SplatMetalView: UIViewRepresentable {
    let splatURL: URL
    let camera: SplatCameraController
    let onLoadResult: (Result<Int, Error>) -> Void

    func makeCoordinator() -> SplatRenderCoordinator {
        SplatRenderCoordinator(camera: camera)
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
        let coordinator = context.coordinator
        let url = splatURL
        let onLoadResult = onLoadResult
        Task { @MainActor in
            do {
                let splatCount = try await coordinator.load(url: url)
                onLoadResult(.success(splatCount))
            } catch {
                onLoadResult(.failure(error))
            }
        }
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}

@MainActor
final class SplatRenderCoordinator: NSObject, MTKViewDelegate {
    private let camera: SplatCameraController
    private var commandQueue: MTLCommandQueue?
    private var renderer: SplatRenderer?
    private var drawableSize: CGSize = .zero
    private var lastFrameTimestamp: Date?
    private let inFlightSemaphore = DispatchSemaphore(value: 3)

    init(camera: SplatCameraController) {
        self.camera = camera
    }

    func attach(view: MTKView) {
        commandQueue = view.device?.makeCommandQueue()
        drawableSize = view.drawableSize
    }

    func load(url: URL) async throws -> Int {
        guard let device = commandQueue?.device else {
            throw RoomSplatViewerError.metalUnavailable
        }
        let renderer = try SplatRenderer(
            device: device,
            colorFormat: .bgra8Unorm_srgb,
            depthFormat: .depth32Float,
            sampleCount: 1,
            maxViewCount: 1,
            maxSimultaneousRenders: 3
        )
        let reader = try AutodetectSceneReader(url)
        let points = try await reader.readAll()
        guard !points.isEmpty else {
            throw RoomSplatViewerError.emptySplatFile
        }
        let chunk = try SplatChunk(device: device, from: points)
        await renderer.addChunk(chunk)
        self.renderer = renderer
        return points.count
    }

    func installGestures(on view: MTKView) {
        let orbit = UIPanGestureRecognizer(target: self, action: #selector(handleOneFingerPan(_:)))
        orbit.maximumNumberOfTouches = 1
        view.addGestureRecognizer(orbit)

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
            let renderer,
            renderer.isReadyToRender,
            let commandQueue,
            drawableSize.width > 0,
            drawableSize.height > 0,
            let drawable = view.currentDrawable
        else { return }

        let now = Date()
        if let lastFrameTimestamp {
            camera.tick(deltaTime: Float(now.timeIntervalSince(lastFrameTimestamp)))
        }
        lastFrameTimestamp = now

        _ = inFlightSemaphore.wait(timeout: .distantFuture)
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }
        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { _ in
            semaphore.signal()
        }

        let projection = SplatMatrices.perspective(
            fovyRadians: 65 * .pi / 180,
            aspectRatio: Float(drawableSize.width / drawableSize.height),
            nearZ: 0.05,
            farZ: 100
        )
        let viewport = SplatRenderer.ViewportDescriptor(
            viewport: MTLViewport(
                originX: 0,
                originY: 0,
                width: drawableSize.width,
                height: drawableSize.height,
                znear: 0,
                zfar: 1
            ),
            projectionMatrix: projection,
            viewMatrix: camera.viewMatrix,
            screenSize: SIMD2(x: Int(drawableSize.width), y: Int(drawableSize.height))
        )

        let didRender: Bool
        do {
            didRender = try renderer.render(
                viewports: [viewport],
                colorTexture: drawable.texture,
                colorStoreAction: .store,
                depthTexture: view.depthStencilTexture,
                rasterizationRateMap: nil,
                renderTargetArrayLength: 0,
                to: commandBuffer
            )
        } catch {
            didRender = false
        }
        if didRender {
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
    }
}

enum RoomSplatViewerError: LocalizedError {
    case metalUnavailable
    case emptySplatFile

    var errorDescription: String? {
        switch self {
        case .metalUnavailable:
            return "Metal rendering is unavailable on this device."
        case .emptySplatFile:
            return "The splat file contains no points."
        }
    }
}

// MARK: - Screen

struct RoomSplatViewerScreen: View {
    let projectID: String
    let splatURL: URL

    @StateObject private var camera = SplatCameraController()
    @State private var loadState: LoadState = .loading

    private enum LoadState {
        case loading
        case loaded(splatCount: Int)
        case failed(message: String)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            SplatMetalView(splatURL: splatURL, camera: camera) { result in
                switch result {
                case let .success(count):
                    loadState = .loaded(splatCount: count)
                case let .failure(error):
                    loadState = .failed(message: error.localizedDescription)
                }
            }
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                switch loadState {
                case .loading:
                    ProgressView("Loading photoreal room...")
                        .tint(AppPalette.blueprintOnDark)
                        .foregroundStyle(AppPalette.primaryOnDark)
                case let .failed(message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(AppTypography.measurement)
                        .foregroundStyle(AppPalette.amberOnDark)
                case let .loaded(splatCount):
                    Text("PHOTOREAL / \(splatCount) splats")
                        .font(AppTypography.measurement)
                        .tracking(1.2)
                        .foregroundStyle(AppPalette.mutedOnDark)
                }

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
                    }
                    .buttonStyle(.bordered)
                    .tint(AppPalette.mutedOnDark)
                }

                if camera.mode == .firstPerson {
                    Text("Drag to look. Use the joystick to walk.")
                        .font(AppTypography.measurement)
                        .foregroundStyle(AppPalette.mutedOnDark)
                } else {
                    Text("Drag to orbit, pinch to zoom, two-finger drag to pan.")
                        .font(AppTypography.measurement)
                        .foregroundStyle(AppPalette.mutedOnDark)
                }
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
        .overlay(alignment: .bottomTrailing) {
            if camera.mode == .firstPerson {
                SplatWalkJoystick(camera: camera)
                    .padding(.trailing, 28)
                    .padding(.bottom, 170)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Photoreal room")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Bottom-right virtual joystick: drag distance from center maps to walking
/// velocity in first-person mode.
private struct SplatWalkJoystick: View {
    @ObservedObject var camera: SplatCameraController
    @State private var thumbOffset: CGSize = .zero

    private let radius: CGFloat = 56

    var body: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.12))
                .frame(width: radius * 2, height: radius * 2)
            Circle()
                .fill(.white.opacity(0.35))
                .frame(width: 46, height: 46)
                .offset(thumbOffset)
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let clampedX = min(max(value.translation.width, -radius), radius)
                    let clampedY = min(max(value.translation.height, -radius), radius)
                    thumbOffset = CGSize(width: clampedX, height: clampedY)
                    camera.moveInput = SIMD2(
                        Float(clampedX / radius),
                        Float(-clampedY / radius)
                    )
                }
                .onEnded { _ in
                    thumbOffset = .zero
                    camera.moveInput = .zero
                }
        )
        .accessibilityLabel("Walk joystick")
        .accessibilityHint("Drag to walk through the room in first-person mode.")
    }
}
