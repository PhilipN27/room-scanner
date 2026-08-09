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

    func makeCoordinator() -> RoomViewerRealityCoordinator {
        RoomViewerRealityCoordinator()
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(
            frame: .zero,
            cameraMode: .nonAR,
            automaticallyConfigureSession: false
        )
        view.backgroundColor = .black
        context.coordinator.install(on: view)
        context.coordinator.render(
            scenePlan: scenePlan,
            camera: camera,
            visibility: visibility
        )
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.render(
            scenePlan: scenePlan,
            camera: camera,
            visibility: visibility
        )
    }
}

@MainActor
final class RoomViewerRealityCoordinator {
    private let anchor = AnchorEntity(world: .zero)
    private let perspectiveCamera = PerspectiveCamera()
    private let structuralRoot = Entity()
    private let objectRoot = Entity()
    private let measurementRoot = Entity()
    private let annotationRoot = Entity()
    private let photoRoot = Entity()
    private var installed = false
    private var lastScenePlan: RoomViewerScenePlan?

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

    func render(
        scenePlan: RoomViewerScenePlan,
        camera: RoomViewerCamera,
        visibility: RoomViewerVisibility
    ) {
        apply(camera: camera)
        structuralRoot.isEnabled = visibility.isVisible(.structural)
        objectRoot.isEnabled = visibility.isVisible(.objects)
        measurementRoot.isEnabled = visibility.isVisible(.measurements)
        annotationRoot.isEnabled = visibility.isVisible(.annotations)
        photoRoot.isEnabled = visibility.isVisible(.photos)

        guard lastScenePlan != scenePlan else { return }
        rebuild(
            root: structuralRoot,
            elements: scenePlan.structuralElements,
            color: UIColor(red: 0.19, green: 0.73, blue: 0.83, alpha: 0.72)
        )
        rebuild(
            root: objectRoot,
            elements: scenePlan.objectElements,
            color: UIColor(red: 0.95, green: 0.62, blue: 0.16, alpha: 0.78)
        )
        rebuildMeasurements(scenePlan.measurements)
        rebuildAnnotations(scenePlan.annotations)
        rebuildPhotos(scenePlan.photos)
        lastScenePlan = scenePlan
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
        color: UIColor
    ) {
        removeChildren(from: root)
        for element in elements {
            let size = boxSize(for: element.dimensionsMeters)
            let material = SimpleMaterial(color: color, isMetallic: false)
            let entity = ModelEntity(
                mesh: MeshResource.generateBox(size: size, cornerRadius: 0),
                materials: [material]
            )
            entity.name = element.id
            entity.transform = Transform(matrix: matrix(for: element.transform))
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

    private func boxSize(for dimensions: RoomDimensions) -> SIMD3<Float> {
        // RoomPlan surfaces can be effectively planar. Display thickness is a
        // viewer-only aid, never written back into semantic truth.
        SIMD3<Float>(
            max(Float(dimensions.width), 0.025),
            max(Float(dimensions.height), 0.025),
            max(Float(dimensions.depth), 0.025)
        )
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
