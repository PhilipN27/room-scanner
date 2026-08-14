import RealityKit
import SwiftUI
import UIKit
import simd
import RoomScanCore

/// RealityKit is used only as a disposable non-AR semantic-box renderer. This
/// adapter never owns, runs, configures, or delegates an ARSession; `.nonAR`
/// keeps the saved-room viewer fully virtual and camera-free.
@MainActor
struct RoomViewerRealityView: UIViewRepresentable {
    let scenePlan: RoomViewerScenePlan
    let camera: RoomViewerCamera
    let visibility: RoomViewerVisibility
    let selectedElementID: String?
    /// Real UIKit gesture recognizers (installed below) translate touches
    /// into pure camera actions dispatched back to the owning view's
    /// reducer call — the same one-finger/two-finger/pinch split used by
    /// `SplatCameraController`'s installGestures, so orbit-only pan/zoom is
    /// enforced by disabling the recognizer, not by hoping every call site
    /// remembers to guard.
    let onCameraAction: (RoomViewerCameraAction) -> Void

    func makeCoordinator() -> RoomViewerRealityCoordinator {
        RoomViewerRealityCoordinator(onCameraAction: onCameraAction)
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(
            frame: .zero,
            cameraMode: .nonAR,
            automaticallyConfigureSession: false
        )
        view.backgroundColor = .black
        context.coordinator.install(on: view)
        context.coordinator.installGestures(on: view)
        context.coordinator.render(
            scenePlan: scenePlan,
            camera: camera,
            visibility: visibility,
            selectedElementID: selectedElementID
        )
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.updateCameraMode(camera.mode)
        context.coordinator.render(
            scenePlan: scenePlan,
            camera: camera,
            visibility: visibility,
            selectedElementID: selectedElementID
        )
    }
}

@MainActor
final class RoomViewerRealityCoordinator: NSObject {
    private let anchor = AnchorEntity(world: .zero)
    private let perspectiveCamera = PerspectiveCamera()
    private let structuralRoot = Entity()
    private let objectRoot = Entity()
    private let measurementRoot = Entity()
    private let annotationRoot = Entity()
    private let photoRoot = Entity()
    private var installed = false
    private var lastScenePlan: RoomViewerScenePlan?
    private var lastSelectedElementID: String?
    private let onCameraAction: (RoomViewerCameraAction) -> Void
    private var cameraMode: RoomViewerCameraMode = .orbit
    private weak var twoFingerPanRecognizer: UIPanGestureRecognizer?
    private weak var pinchRecognizer: UIPinchGestureRecognizer?

    init(onCameraAction: @escaping (RoomViewerCameraAction) -> Void) {
        self.onCameraAction = onCameraAction
    }

    func install(on view: ARView) {
        guard !installed else { return }
        anchor.addChild(perspectiveCamera)
        anchor.addChild(structuralRoot)
        anchor.addChild(objectRoot)
        anchor.addChild(measurementRoot)
        anchor.addChild(annotationRoot)
        anchor.addChild(photoRoot)
        view.scene.addAnchor(anchor)
        installed = true
    }

    /// One-finger drag always dispatches `.orbit`: in orbit mode the
    /// reducer both turns and recomputes the orbit position, and in walk
    /// mode the same action turns the head (yaw/pitch) in place without
    /// moving — a look-drag, not a fly. Two-finger pan and pinch are
    /// orbit-only and are disabled entirely (not merely no-op'd) in walk
    /// mode via `updateCameraMode`, so they never contend with the walk
    /// joystick or look-drag for touches.
    func installGestures(on view: ARView) {
        let look = UIPanGestureRecognizer(target: self, action: #selector(handleOneFingerPan(_:)))
        look.maximumNumberOfTouches = 1
        view.addGestureRecognizer(look)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        view.addGestureRecognizer(pan)
        twoFingerPanRecognizer = pan

        let zoom = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        view.addGestureRecognizer(zoom)
        pinchRecognizer = zoom
    }

    func updateCameraMode(_ mode: RoomViewerCameraMode) {
        cameraMode = mode
        let orbitOnly = mode == .orbit
        twoFingerPanRecognizer?.isEnabled = orbitOnly
        pinchRecognizer?.isEnabled = orbitOnly
    }

    @objc private func handleOneFingerPan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: recognizer.view)
        recognizer.setTranslation(.zero, in: recognizer.view)
        onCameraAction(.orbit(
            yawDeltaRadians: Double(translation.x) * 0.003,
            pitchDeltaRadians: Double(translation.y) * 0.003
        ))
    }

    @objc private func handleTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
        guard cameraMode == .orbit else { return }
        let translation = recognizer.translation(in: recognizer.view)
        recognizer.setTranslation(.zero, in: recognizer.view)
        onCameraAction(.pan(delta: RoomPoint3D(
            x: Double(translation.x) * 0.004,
            y: 0,
            z: Double(translation.y) * 0.004
        )))
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard cameraMode == .orbit else { return }
        let incrementalScale = recognizer.scale
        recognizer.scale = 1
        onCameraAction(.zoom(deltaMeters: Double(1 - incrementalScale) * 0.4))
    }

    func render(
        scenePlan: RoomViewerScenePlan,
        camera: RoomViewerCamera,
        visibility: RoomViewerVisibility,
        selectedElementID: String?
    ) {
        apply(camera: camera)
        structuralRoot.isEnabled = visibility.isVisible(.structural)
        objectRoot.isEnabled = visibility.isVisible(.objects)
        measurementRoot.isEnabled = visibility.isVisible(.measurements)
        annotationRoot.isEnabled = visibility.isVisible(.annotations)
        photoRoot.isEnabled = visibility.isVisible(.photos)

        guard lastScenePlan != scenePlan || lastSelectedElementID != selectedElementID else { return }
        rebuild(
            root: structuralRoot,
            elements: scenePlan.structuralElements,
            selectedElementID: selectedElementID
        )
        rebuild(
            root: objectRoot,
            elements: scenePlan.objectElements,
            selectedElementID: selectedElementID
        )
        rebuildMeasurements(scenePlan.measurements)
        rebuildAnnotations(scenePlan.annotations)
        rebuildPhotos(scenePlan.photos)
        lastScenePlan = scenePlan
        lastSelectedElementID = selectedElementID
    }

    private func apply(camera: RoomViewerCamera) {
        // The orientation is derived exclusively from current yaw/pitch. In
        // first-person mode it deliberately does not reuse the prior orbit
        // target, keeping the no-clip look direction explicit and current.
        perspectiveCamera.transform = Transform(
            matrix: cameraMatrix(
                position: camera.position,
                yawRadians: camera.yawRadians,
                pitchRadians: camera.pitchRadians
            )
        )
    }

    private func rebuild(
        root: Entity,
        elements: [RoomSemanticElement],
        selectedElementID: String?
    ) {
        removeChildren(from: root)
        for element in elements {
            let role = RoomSemanticPresentation.role(for: element)
            let size = RoomSemanticVisualStyle.displaySize(
                for: element.dimensionsMeters,
                role: role
            )
            let style = RoomSemanticVisualStyle.style(for: role)
            let material = SimpleMaterial(
                color: style.color,
                roughness: MaterialScalarParameter(floatLiteral: style.roughness),
                isMetallic: style.isMetallic
            )
            let entity = ModelEntity(
                mesh: MeshResource.generateBox(size: size, cornerRadius: 0),
                materials: [material]
            )
            entity.name = element.id
            entity.transform = Transform(matrix: matrix(for: element.transform))
            if element.id == selectedElementID {
                entity.scale *= SIMD3<Float>(repeating: 1.06)
                let marker = ModelEntity(
                    mesh: MeshResource.generateSphere(radius: 0.07),
                    materials: [SimpleMaterial(color: .white, isMetallic: true)]
                )
                marker.name = "selection-marker-\(element.id)"
                marker.position = SIMD3<Float>(0, max(size.y / 2 + 0.12, 0.12), 0)
                entity.addChild(marker)
            }
            root.addChild(entity)
        }
    }

    private func rebuildMeasurements(_ measurements: [RoomMeasurement]) {
        removeChildren(from: measurementRoot)
        let material = SimpleMaterial(
            color: UIColor(red: 0.95, green: 0.62, blue: 0.16, alpha: 0.95),
            isMetallic: false
        )
        for measurement in measurements {
            let point: RoomPoint3D
            if let start = measurement.startPoint, let end = measurement.endPoint {
                point = RoomPoint3D(
                    x: (start.x + end.x) / 2,
                    y: (start.y + end.y) / 2,
                    z: (start.z + end.z) / 2
                )
            } else {
                point = RoomPoint3D(x: 0, y: 0.02, z: 0)
            }
            measurementRoot.addChild(markerEntity(
                name: measurement.id,
                point: point,
                material: material,
                size: 0.06
            ))
        }
    }

    private func rebuildAnnotations(_ annotations: [RoomAnnotation]) {
        removeChildren(from: annotationRoot)
        let material = SimpleMaterial(
            color: UIColor(red: 0.94, green: 0.91, blue: 0.84, alpha: 0.95),
            isMetallic: false
        )
        for annotation in annotations {
            annotationRoot.addChild(markerEntity(
                name: annotation.id,
                point: annotation.point ?? RoomPoint3D(x: 0, y: 0.12, z: 0),
                material: material,
                size: 0.09
            ))
        }
    }

    private func rebuildPhotos(_ photos: [RoomPhoto]) {
        removeChildren(from: photoRoot)
        let material = SimpleMaterial(
            color: UIColor(red: 0.19, green: 0.73, blue: 0.83, alpha: 0.95),
            isMetallic: true
        )
        for photo in photos {
            // A marker uses only the persisted camera-pose translation. It is
            // not a rendered image plane and makes no camera/AR request.
            let point = translation(of: photo.cameraTransform)
                ?? RoomPoint3D(x: 0, y: 0.16, z: 0)
            photoRoot.addChild(markerEntity(
                name: photo.id,
                point: point,
                material: material,
                size: 0.1
            ))
        }
    }

    private func markerEntity(
        name: String,
        point: RoomPoint3D,
        material: SimpleMaterial,
        size: Float
    ) -> ModelEntity {
        let entity = ModelEntity(
            mesh: MeshResource.generateBox(
                size: SIMD3<Float>(repeating: size),
                cornerRadius: 0
            ),
            materials: [material]
        )
        entity.name = name
        entity.position = SIMD3<Float>(Float(point.x), Float(point.y), Float(point.z))
        return entity
    }

    private func matrix(for transform: RoomTransform4x4?) -> simd_float4x4 {
        guard let transform, transform.isValid else {
            return matrix_identity_float4x4
        }
        let values = transform.columnMajorValues.map(Float.init)
        return simd_float4x4(columns: (
            SIMD4(values[0], values[1], values[2], values[3]),
            SIMD4(values[4], values[5], values[6], values[7]),
            SIMD4(values[8], values[9], values[10], values[11]),
            SIMD4(values[12], values[13], values[14], values[15])
        ))
    }

    private func cameraMatrix(
        position: RoomPoint3D,
        yawRadians: Double,
        pitchRadians: Double
    ) -> simd_float4x4 {
        let yaw = simd_quatf(
            angle: Float(yawRadians),
            axis: SIMD3<Float>(0, 1, 0)
        )
        let pitch = simd_quatf(
            angle: Float(pitchRadians),
            axis: SIMD3<Float>(1, 0, 0)
        )
        var matrix = simd_float4x4(yaw * pitch)
        matrix.columns.3 = SIMD4<Float>(
            Float(position.x),
            Float(position.y),
            Float(position.z),
            1
        )
        return matrix
    }

    private func translation(of transform: RoomTransform4x4?) -> RoomPoint3D? {
        guard let transform, transform.isValid else { return nil }
        let values = transform.columnMajorValues
        return RoomPoint3D(x: values[12], y: values[13], z: values[14])
    }

    private func removeChildren(from root: Entity) {
        root.children.removeAll()
    }
}

enum RoomSemanticVisualStyle {
    private static let planarSurfaceDisplayDepth: Float = 0.025
    /// Doors, windows, and openings arrive from RoomPlan at zero depth and
    /// share their parent wall's plane. A symmetric viewer-only projection
    /// beyond both wall faces prevents depth fighting from either side. These
    /// values never enter the saved semantic snapshot or any measurement.
    private static let embeddedFeatureDisplayDepth: Float = 0.06

    struct Style {
        let color: UIColor
        let roughness: Float
        let isMetallic: Bool
    }

    static func color(for role: RoomSemanticRole) -> UIColor {
        style(for: role).color
    }

    static func displaySize(
        for dimensions: RoomDimensions,
        role: RoomSemanticRole
    ) -> SIMD3<Float> {
        let minimumDepth: Float
        switch role {
        case .door, .window, .opening:
            minimumDepth = embeddedFeatureDisplayDepth
        case .wall, .floor, .ceiling, .fixedObject, .movableObject, .unknownObject:
            minimumDepth = planarSurfaceDisplayDepth
        }
        return SIMD3<Float>(
            max(Float(dimensions.width), planarSurfaceDisplayDepth),
            max(Float(dimensions.height), planarSurfaceDisplayDepth),
            max(Float(dimensions.depth), minimumDepth)
        )
    }

    static func style(for role: RoomSemanticRole) -> Style {
        switch role {
        case .wall:
            return Style(color: UIColor(red: 0.22, green: 0.75, blue: 0.84, alpha: 0.72), roughness: 0.75, isMetallic: false)
        case .door:
            return Style(color: UIColor(red: 0.98, green: 0.67, blue: 0.22, alpha: 1), roughness: 0.35, isMetallic: false)
        case .window:
            return Style(color: UIColor(red: 0.42, green: 0.78, blue: 1, alpha: 1), roughness: 0.08, isMetallic: true)
        case .opening:
            return Style(color: UIColor(red: 0.94, green: 0.9, blue: 0.76, alpha: 1), roughness: 1, isMetallic: false)
        case .floor:
            return Style(color: UIColor(red: 0.44, green: 0.68, blue: 0.48, alpha: 0.65), roughness: 0.95, isMetallic: false)
        case .ceiling:
            return Style(color: UIColor(red: 0.75, green: 0.73, blue: 0.92, alpha: 0.48), roughness: 0.6, isMetallic: false)
        case .fixedObject:
            return Style(color: UIColor(red: 0.94, green: 0.4, blue: 0.3, alpha: 0.82), roughness: 0.48, isMetallic: false)
        case .movableObject:
            return Style(color: UIColor(red: 0.9, green: 0.62, blue: 0.2, alpha: 0.8), roughness: 0.82, isMetallic: false)
        case .unknownObject:
            return Style(color: UIColor(red: 0.72, green: 0.72, blue: 0.72, alpha: 0.66), roughness: 0.25, isMetallic: true)
        }
    }
}
