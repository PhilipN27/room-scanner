import Foundation

/// The five disposable RealityKit root groups represented by the saved-room
/// viewer. This Foundation-only state lets tests exercise visibility without
/// constructing an ARView or requesting camera access.
public enum RoomViewerRoot: String, Codable, Sendable, Equatable, CaseIterable {
    case structural
    case objects
    case measurements
    case annotations
    case photos
}

public struct RoomViewerVisibility: Codable, Sendable, Equatable {
    public var structural: Bool
    public var objects: Bool
    public var measurements: Bool
    public var annotations: Bool
    public var photos: Bool

    public init(
        structural: Bool = true,
        objects: Bool = true,
        measurements: Bool = true,
        annotations: Bool = true,
        photos: Bool = true
    ) {
        self.structural = structural
        self.objects = objects
        self.measurements = measurements
        self.annotations = annotations
        self.photos = photos
    }

    public func isVisible(_ root: RoomViewerRoot) -> Bool {
        switch root {
        case .structural: structural
        case .objects: objects
        case .measurements: measurements
        case .annotations: annotations
        case .photos: photos
        }
    }

    public mutating func setVisible(_ visible: Bool, for root: RoomViewerRoot) {
        switch root {
        case .structural: structural = visible
        case .objects: objects = visible
        case .measurements: measurements = visible
        case .annotations: annotations = visible
        case .photos: photos = visible
        }
    }
}

public enum RoomViewerCameraMode: String, Codable, Sendable, Equatable {
    case orbit
    /// Deliberately collision-free: saved semantic boxes are not collision or
    /// survey geometry, so this mode is an honest no-clip inspection camera.
    case firstPerson
}

public enum RoomViewerCameraPreset: String, Codable, Sendable, Equatable {
    case reset
    case top
    case front
    case side
    case custom
}

public enum RoomViewerCameraAction: Sendable, Equatable {
    case orbit(yawDeltaRadians: Double, pitchDeltaRadians: Double)
    case zoom(deltaMeters: Double)
    case pan(delta: RoomPoint3D)
    /// One display-linked walk tick. `localX`/`localZ` are the transient
    /// joystick axes (right/forward, radially clamped to unit magnitude);
    /// they are dispatched per frame and never stored in the camera state.
    case move(localX: Double, localZ: Double, deltaTime: Double)
    case orbitMode
    case firstPerson
    case reset
    case top
    case front
    case side
}

public enum RoomViewerCameraError: Error, Sendable, Equatable {
    case nonFiniteInput
}

/// Serializable, renderer-independent camera state. `position` is always the
/// pose sent to the renderer; `target`, `distanceMeters`, and `pan` retain the
/// orbit controls so a view can rebuild without keeping RealityKit entities.
public struct RoomViewerCamera: Codable, Sendable, Equatable {
    public static let minimumDistanceMeters = 0.25
    public static let maximumDistanceMeters = 50.0
    public static let pitchLimitRadians = 1.48

    public var mode: RoomViewerCameraMode
    public var target: RoomPoint3D
    public var position: RoomPoint3D
    public var yawRadians: Double
    public var pitchRadians: Double
    public var distanceMeters: Double
    public var pan: RoomPoint3D
    public var preset: RoomViewerCameraPreset

    public init(
        mode: RoomViewerCameraMode,
        target: RoomPoint3D,
        position: RoomPoint3D,
        yawRadians: Double,
        pitchRadians: Double,
        distanceMeters: Double,
        pan: RoomPoint3D,
        preset: RoomViewerCameraPreset = .custom
    ) {
        self.mode = mode
        self.target = target
        self.position = position
        self.yawRadians = yawRadians
        self.pitchRadians = pitchRadians
        self.distanceMeters = distanceMeters
        self.pan = pan
        self.preset = preset
    }

    /// The reset pose is calculated from the same orbit geometry used by the
    /// reducer, rather than retaining an independently tuned position that
    /// can drift away from yaw, pitch, target, or distance.
    public static var defaultState: RoomViewerCamera {
        let target = RoomPoint3D(x: 0, y: 1, z: 0)
        let yaw = Double.pi / 4
        let pitch = -0.35
        let distance = 6.4
        let horizontal = distance * cos(pitch)
        return RoomViewerCamera(
            mode: .orbit,
            target: target,
            position: RoomPoint3D(
                x: target.x + horizontal * sin(yaw),
                y: target.y - distance * sin(pitch),
                z: target.z + horizontal * cos(yaw)
            ),
            yawRadians: yaw,
            pitchRadians: pitch,
            distanceMeters: distance,
            pan: RoomPoint3D(x: 0, y: 0, z: 0),
            preset: .reset
        )
    }

    public var isNoClip: Bool {
        mode == .firstPerson
    }
}

public enum RoomViewerCameraReducer {
    /// Matches SplatCameraController so semantic walk and photoreal walk
    /// cover ground at the same rate.
    public static let walkSpeedMetersPerSecond = 1.6
    /// A stalled or backgrounded frame reports a huge delta; capping it keeps
    /// the camera from teleporting on resume.
    public static let maximumMoveDeltaTime = 0.1
    /// Joystick magnitudes at or below this are treated as a resting thumb.
    public static let moveDeadZone = 0.1

    public static func reduce(
        _ camera: RoomViewerCamera,
        action: RoomViewerCameraAction
    ) throws -> RoomViewerCamera {
        try validate(camera)
        var next = camera
        switch action {
        case let .orbit(yawDeltaRadians, pitchDeltaRadians):
            guard yawDeltaRadians.isFinite, pitchDeltaRadians.isFinite else {
                throw RoomViewerCameraError.nonFiniteInput
            }
            next.yawRadians = normalizedYaw(camera.yawRadians + yawDeltaRadians)
            next.pitchRadians = clampedPitch(camera.pitchRadians + pitchDeltaRadians)
            next.preset = .custom
            if next.mode == .orbit {
                next.position = orbitPosition(for: next)
            }
        case let .zoom(deltaMeters):
            guard deltaMeters.isFinite else {
                throw RoomViewerCameraError.nonFiniteInput
            }
            // Walk mode moves only through .move (yaw-only, constant eye
            // height); a pitch-following zoom would let the camera dive or
            // climb, so zoom is orbit-only.
            guard camera.mode == .orbit else {
                return camera
            }
            next.distanceMeters = min(
                RoomViewerCamera.maximumDistanceMeters,
                max(RoomViewerCamera.minimumDistanceMeters, camera.distanceMeters + deltaMeters)
            )
            next.position = orbitPosition(for: next)
            next.preset = .custom
        case let .pan(delta):
            guard delta.isFinite else {
                throw RoomViewerCameraError.nonFiniteInput
            }
            guard camera.mode == .orbit else {
                return camera
            }
            next.pan = adding(camera.pan, delta)
            next.position = adding(camera.position, delta)
            next.preset = .custom
        case let .move(localX, localZ, deltaTime):
            guard
                localX.isFinite, localZ.isFinite,
                deltaTime.isFinite, deltaTime >= 0
            else {
                throw RoomViewerCameraError.nonFiniteInput
            }
            guard camera.mode == .firstPerson else {
                return camera
            }
            let magnitude = (localX * localX + localZ * localZ).squareRoot()
            guard magnitude > moveDeadZone else {
                return camera
            }
            let scale = magnitude > 1 ? 1 / magnitude : 1
            let dt = min(deltaTime, maximumMoveDeltaTime)
            // Walking is yaw-only and holds eye height: looking down while
            // moving must not descend, because this is a walk, not a fly.
            let forwardX = -sin(camera.yawRadians)
            let forwardZ = -cos(camera.yawRadians)
            let rightX = cos(camera.yawRadians)
            let rightZ = -sin(camera.yawRadians)
            let step = walkSpeedMetersPerSecond * dt * scale
            next.position = RoomPoint3D(
                x: camera.position.x + (rightX * localX + forwardX * localZ) * step,
                y: camera.position.y,
                z: camera.position.z + (rightZ * localX + forwardZ * localZ) * step
            )
            next.preset = .custom
        case .orbitMode:
            next.mode = .orbit
            next.position = orbitPosition(for: next)
        case .firstPerson:
            next.mode = .firstPerson
        case .reset:
            return RoomViewerCamera.defaultState
        case .top:
            next.mode = .orbit
            next.yawRadians = 0
            next.pitchRadians = -RoomViewerCamera.pitchLimitRadians
            next.preset = .top
            next.position = orbitPosition(for: next)
        case .front:
            next.mode = .orbit
            next.yawRadians = 0
            next.pitchRadians = 0
            next.preset = .front
            next.position = orbitPosition(for: next)
        case .side:
            next.mode = .orbit
            next.yawRadians = .pi / 2
            next.pitchRadians = 0
            next.preset = .side
            next.position = orbitPosition(for: next)
        }
        try validate(next)
        return next
    }

    private static func validate(_ camera: RoomViewerCamera) throws {
        guard
            camera.target.isFinite,
            camera.position.isFinite,
            camera.pan.isFinite,
            camera.yawRadians.isFinite,
            camera.pitchRadians.isFinite,
            camera.distanceMeters.isFinite
        else {
            throw RoomViewerCameraError.nonFiniteInput
        }
    }

    private static func clampedPitch(_ value: Double) -> Double {
        min(RoomViewerCamera.pitchLimitRadians, max(-RoomViewerCamera.pitchLimitRadians, value))
    }

    private static func normalizedYaw(_ value: Double) -> Double {
        var normalized = value.truncatingRemainder(dividingBy: 2 * .pi)
        if normalized > .pi { normalized -= 2 * .pi }
        if normalized < -.pi { normalized += 2 * .pi }
        return normalized
    }

    private static func orbitPosition(for camera: RoomViewerCamera) -> RoomPoint3D {
        let horizontal = camera.distanceMeters * cos(camera.pitchRadians)
        return RoomPoint3D(
            x: camera.target.x + camera.pan.x + horizontal * sin(camera.yawRadians),
            // Negative pitch is the conventional elevated orbit/top view in
            // this editor; subtracting keeps the default and top presets above
            // the room instead of reflecting them below the floor.
            y: camera.target.y + camera.pan.y - camera.distanceMeters * sin(camera.pitchRadians),
            z: camera.target.z + camera.pan.z + horizontal * cos(camera.yawRadians)
        )
    }

    private static func adding(_ lhs: RoomPoint3D, _ rhs: RoomPoint3D) -> RoomPoint3D {
        RoomPoint3D(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

}

/// A pure description of the semantic renderer inputs. It contains no meshes,
/// native USDZ, or AR state: the iOS adapter renders disposable bounding boxes
/// from this plan and can discard/rebuild them at any time.
public struct RoomViewerScenePlan: Sendable, Equatable {
    public let structuralElements: [RoomSemanticElement]
    public let objectElements: [RoomSemanticElement]
    public let measurements: [RoomMeasurement]
    public let annotations: [RoomAnnotation]
    public let photos: [RoomPhoto]

    public init(payload: RoomRevisionPayload) {
        structuralElements = payload.semanticSnapshot.structuralElements
        objectElements = payload.semanticSnapshot.objectElements
        measurements = payload.measurements
        annotations = payload.annotations
        photos = payload.photos
    }

    public func visibilityState(
        for root: RoomViewerRoot,
        visibility: RoomViewerVisibility
    ) -> Bool {
        visibility.isVisible(root)
    }

    public func cameraState(_ camera: RoomViewerCamera) -> RoomViewerCamera {
        camera
    }
}

public enum RoomRevisionEditorError: Error, Sendable, Equatable {
    case invalidIdentifier(String)
    case duplicateElementID(String)
    case duplicateAnnotationID(String)
    case duplicateMeasurementID(String)
    case elementNotFound(String)
    case photoNotFound(String)
    case invalidText(String)
    case invalidDimensions
    case invalidTransform
    case invalidSpatialPoint
    case danglingAttachment(String)
    case invalidMeasurement
    case layerInvariant
    case invalidManualProvenance
}

/// A value-type copy-on-write editor. It never holds a package URL and never
/// writes a revision itself; callers must explicitly hand `payload` to the
/// store-owned optimistic commit transaction.
public struct RoomRevisionEditor: Sendable, Equatable {
    public private(set) var payload: RoomRevisionPayload
    private let manualCaptureAttemptID: String?
    private let manualCoordinateSpaceEpochID: String?
    private static let structuralCategories: Set<String> = [
        "ceiling", "column", "door", "floor", "opening", "stairs", "wall", "window",
    ]
    private static let objectCategories: Set<String> = [
        "bathtub", "bed", "cabinet", "chair", "desk", "fireplace", "refrigerator",
        "sink", "sofa", "stove", "storage", "table", "television", "toilet",
        "vanity", "washerdryer",
    ]

    public init(
        payload: RoomRevisionPayload,
        captureEvidence: RoomRevisionEvidencePlan? = nil
    ) throws {
        self.payload = payload
        if captureEvidence?.source == .roomPlan {
            guard
                let captureAttemptID = captureEvidence?.captureAttemptID,
                let coordinateSpaceEpochID = captureEvidence?.coordinateSpaceEpochID
            else {
                throw RoomRevisionEditorError.invalidManualProvenance
            }
            manualCaptureAttemptID = captureAttemptID
            manualCoordinateSpaceEpochID = coordinateSpaceEpochID
        } else {
            manualCaptureAttemptID = nil
            manualCoordinateSpaceEpochID = nil
        }
        try validatePayload()
    }

    public mutating func renameElement(id: String, label: String) throws {
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RoomRevisionEditorError.invalidText(label)
        }
        try mutateElement(id: id) { element, _ in element.label = label }
    }

    public mutating func updateCategory(id: String, kind: String) throws {
        guard !kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RoomRevisionEditorError.invalidText(kind)
        }
        try mutateElement(id: id) { element, isStructural in
            try Self.validateCategory(kind, isStructural: isStructural)
            element.kind = kind
        }
    }

    public mutating func updateDimensions(
        id: String,
        dimensions: RoomDimensions
    ) throws {
        try mutateElement(id: id) { element, isStructural in
            try Self.validateDimensions(dimensions, isStructural: isStructural)
            element.dimensionsMeters = dimensions
        }
    }

    public mutating func updatePose(
        id: String,
        transform: RoomTransform4x4?
    ) throws {
        guard transform?.isValid != false else {
            throw RoomRevisionEditorError.invalidTransform
        }
        try mutateElement(id: id) { element, _ in element.transform = transform }
    }

    /// Applies a user-entered yaw adjustment without discarding an existing
    /// captured pitch, roll, or scale basis. Translation is edited separately
    /// in column-major coordinates. A transform-less legacy element begins
    /// from identity so it can be deliberately positioned.
    public mutating func adjustPose(
        id: String,
        translation: RoomPoint3D,
        yawDeltaRadians: Double
    ) throws {
        guard translation.isFinite, yawDeltaRadians.isFinite else {
            throw RoomRevisionEditorError.invalidTransform
        }
        try mutateElement(id: id) { element, _ in
            let source = element.transform?.columnMajorValues ?? [
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                0, 0, 0, 1,
            ]
            guard source.count == 16, source.allSatisfy(\.isFinite) else {
                throw RoomRevisionEditorError.invalidTransform
            }
            let cosine = cos(yawDeltaRadians)
            let sine = sin(yawDeltaRadians)
            var values = source
            for column in 0..<3 {
                let offset = column * 4
                let x = source[offset]
                let y = source[offset + 1]
                let z = source[offset + 2]
                values[offset] = cosine * x + sine * z
                values[offset + 1] = y
                values[offset + 2] = -sine * x + cosine * z
            }
            values[12] = translation.x
            values[13] = translation.y
            values[14] = translation.z
            values[3] = 0
            values[7] = 0
            values[11] = 0
            values[15] = 1
            element.transform = RoomTransform4x4(columnMajorValues: values)
        }
    }

    public mutating func updateMobility(
        id: String,
        mobility: RoomMobilityAssessment?
    ) throws {
        try mutateElement(id: id) { element, isStructural in
            if isStructural, mobility == .movable {
                throw RoomRevisionEditorError.layerInvariant
            }
            if !isStructural, mobility == .structural {
                throw RoomRevisionEditorError.layerInvariant
            }
            element.mobility = mobility
        }
    }

    public mutating func deleteElement(id: String) throws {
        if let index = payload.semanticSnapshot.structuralElements.firstIndex(where: { $0.id == id }) {
            payload.semanticSnapshot.structuralElements.remove(at: index)
        } else if let index = payload.semanticSnapshot.objectElements.firstIndex(where: { $0.id == id }) {
            payload.semanticSnapshot.objectElements.remove(at: index)
        } else {
            throw RoomRevisionEditorError.elementNotFound(id)
        }
        // Retain a note's text/pin but remove the attachment rather than
        // leaving a dangling durable element ID.
        for index in payload.annotations.indices where payload.annotations[index].attachedElementID == id {
            payload.annotations[index].attachedElementID = nil
        }
        try validatePayload()
    }

    public mutating func addManualObject(
        id: String,
        kind: String,
        label: String,
        dimensions: RoomDimensions,
        transform: RoomTransform4x4?
    ) throws {
        guard RoomPathValidation.isSafeStableIdentifier(id) else {
            throw RoomRevisionEditorError.invalidIdentifier(id)
        }
        guard !kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RoomRevisionEditorError.invalidText(label)
        }
        guard let transform, Self.isUsableManualTransform(transform) else {
            throw RoomRevisionEditorError.invalidTransform
        }
        try Self.validateDimensions(dimensions, isStructural: false)
        try Self.validateCategory(kind, isStructural: false)
        guard !allElementIDs.contains(id) else {
            throw RoomRevisionEditorError.duplicateElementID(id)
        }
        payload.semanticSnapshot.objectElements.append(RoomSemanticElement(
            id: id,
            kind: kind,
            label: label,
            dimensionsMeters: dimensions,
            transform: transform,
            provenance: RoomElementProvenance(
                framework: "RoomScanStudio.manual",
                sourceIdentifier: "manual-\(id)",
                classificationConfidence: .unknown,
                flattenedAttributeIdentifiers: [],
                captureAttemptID: manualCaptureAttemptID,
                coordinateSpaceEpochID: manualCoordinateSpaceEpochID
            ),
            mobility: .unknown,
            origin: .manual
        ))
        try validatePayload()
    }

    public mutating func addSpatialAnnotation(
        id: String,
        text: String,
        createdAt: Date,
        point: RoomPoint3D?,
        attachedElementID: String?
    ) throws {
        guard RoomPathValidation.isSafeStableIdentifier(id) else {
            throw RoomRevisionEditorError.invalidIdentifier(id)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RoomRevisionEditorError.invalidText(text)
        }
        guard point?.isFinite != false else {
            throw RoomRevisionEditorError.invalidSpatialPoint
        }
        if let attachedElementID, !allElementIDs.contains(attachedElementID) {
            throw RoomRevisionEditorError.danglingAttachment(attachedElementID)
        }
        guard !payload.annotations.contains(where: { $0.id == id }) else {
            throw RoomRevisionEditorError.duplicateAnnotationID(id)
        }
        payload.annotations.append(RoomAnnotation(
            id: id,
            createdAt: createdAt,
            text: text,
            point: point,
            attachedElementID: attachedElementID
        ))
        try validatePayload()
    }

    public mutating func addPointToPointMeasurement(
        id: String,
        label: String,
        startPoint: RoomPoint3D,
        endPoint: RoomPoint3D
    ) throws {
        guard RoomPathValidation.isSafeStableIdentifier(id) else {
            throw RoomRevisionEditorError.invalidIdentifier(id)
        }
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RoomRevisionEditorError.invalidText(label)
        }
        guard startPoint.isFinite, endPoint.isFinite else {
            throw RoomRevisionEditorError.invalidSpatialPoint
        }
        guard !payload.measurements.contains(where: { $0.id == id }) else {
            throw RoomRevisionEditorError.duplicateMeasurementID(id)
        }
        payload.measurements.append(RoomMeasurement(
            id: id,
            label: label,
            valueMeters: Self.distance(from: startPoint, to: endPoint),
            startPoint: startPoint,
            endPoint: endPoint
        ))
        try validatePayload()
    }

    public mutating func updatePhotoCaption(id: String, caption: String) throws {
        guard let index = payload.photos.firstIndex(where: { $0.id == id }) else {
            throw RoomRevisionEditorError.photoNotFound(id)
        }
        payload.photos[index].caption = caption
        try validatePayload()
    }

    private var allElementIDs: Set<String> {
        Set(
            (payload.semanticSnapshot.structuralElements + payload.semanticSnapshot.objectElements)
                .map(\.id)
        )
    }

    private mutating func mutateElement(
        id: String,
        operation: (inout RoomSemanticElement, Bool) throws -> Void
    ) throws {
        if let index = payload.semanticSnapshot.structuralElements.firstIndex(where: { $0.id == id }) {
            try operation(&payload.semanticSnapshot.structuralElements[index], true)
        } else if let index = payload.semanticSnapshot.objectElements.firstIndex(where: { $0.id == id }) {
            try operation(&payload.semanticSnapshot.objectElements[index], false)
        } else {
            throw RoomRevisionEditorError.elementNotFound(id)
        }
        try validatePayload()
    }

    private func validatePayload() throws {
        var semanticIDs = Set<String>()
        for element in payload.semanticSnapshot.structuralElements {
            try Self.validate(element: element, isStructural: true, seenIDs: &semanticIDs)
        }
        for element in payload.semanticSnapshot.objectElements {
            try Self.validate(element: element, isStructural: false, seenIDs: &semanticIDs)
        }

        var annotationIDs = Set<String>()
        for annotation in payload.annotations {
            guard RoomPathValidation.isSafeStableIdentifier(annotation.id) else {
                throw RoomRevisionEditorError.invalidIdentifier(annotation.id)
            }
            guard annotationIDs.insert(annotation.id).inserted else {
                throw RoomRevisionEditorError.duplicateAnnotationID(annotation.id)
            }
            guard annotation.point?.isFinite != false else {
                throw RoomRevisionEditorError.invalidSpatialPoint
            }
            if let attachment = annotation.attachedElementID {
                guard allElementIDs.contains(attachment) else {
                    throw RoomRevisionEditorError.danglingAttachment(attachment)
                }
            }
        }

        var measurementIDs = Set<String>()
        for measurement in payload.measurements {
            guard RoomPathValidation.isSafeStableIdentifier(measurement.id) else {
                throw RoomRevisionEditorError.invalidIdentifier(measurement.id)
            }
            guard measurementIDs.insert(measurement.id).inserted else {
                throw RoomRevisionEditorError.duplicateMeasurementID(measurement.id)
            }
            try Self.validate(measurement: measurement)
        }
    }

    private static func validate(
        element: RoomSemanticElement,
        isStructural: Bool,
        seenIDs: inout Set<String>
    ) throws {
        guard RoomPathValidation.isSafeStableIdentifier(element.id) else {
            throw RoomRevisionEditorError.invalidIdentifier(element.id)
        }
        guard seenIDs.insert(element.id).inserted else {
            throw RoomRevisionEditorError.duplicateElementID(element.id)
        }
        guard !element.kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !element.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RoomRevisionEditorError.invalidText(element.label)
        }
        try validateDimensions(element.dimensionsMeters, isStructural: isStructural)
        guard element.transform?.isValid != false else {
            throw RoomRevisionEditorError.invalidTransform
        }
        guard element.polygonCorners?.allSatisfy(\.isFinite) != false else {
            throw RoomRevisionEditorError.invalidSpatialPoint
        }
        if isStructural, element.mobility == .movable {
            throw RoomRevisionEditorError.layerInvariant
        }
        if !isStructural, element.mobility == .structural {
            throw RoomRevisionEditorError.layerInvariant
        }
    }

    private static func validateDimensions(
        _ dimensions: RoomDimensions,
        isStructural: Bool
    ) throws {
        let values = [dimensions.width, dimensions.height, dimensions.depth]
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw RoomRevisionEditorError.invalidDimensions
        }
        if isStructural {
            guard values.filter({ $0 > 0 }).count >= 2 else {
                throw RoomRevisionEditorError.invalidDimensions
            }
        } else {
            guard values.allSatisfy({ $0 > 0 }) else {
                throw RoomRevisionEditorError.invalidDimensions
            }
        }
    }

    private static func validateCategory(_ kind: String, isStructural: Bool) throws {
        let normalized = kind
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if isStructural, Self.objectCategories.contains(normalized) {
            throw RoomRevisionEditorError.layerInvariant
        }
        if !isStructural, Self.structuralCategories.contains(normalized) {
            throw RoomRevisionEditorError.layerInvariant
        }
    }

    /// Manual objects must enter a revision with a real affine pose. Existing
    /// legacy elements may remain transform-less until edited, but a newly
    /// authored object must not create an unplaceable semantic box.
    private static func isUsableManualTransform(_ transform: RoomTransform4x4) -> Bool {
        guard transform.isValid else {
            return false
        }
        let values = transform.columnMajorValues
        let affineTolerance = 1e-9
        guard
            abs(values[3]) <= affineTolerance,
            abs(values[7]) <= affineTolerance,
            abs(values[11]) <= affineTolerance,
            abs(values[15] - 1) <= affineTolerance
        else {
            return false
        }
        let determinant =
            values[0] * (values[5] * values[10] - values[9] * values[6])
            - values[4] * (values[1] * values[10] - values[9] * values[2])
            + values[8] * (values[1] * values[6] - values[5] * values[2])
        return determinant.isFinite && abs(determinant) > 1e-10
    }

    private static func validate(measurement: RoomMeasurement) throws {
        guard measurement.valueMeters.isFinite, measurement.valueMeters >= 0 else {
            throw RoomRevisionEditorError.invalidMeasurement
        }
        let endpointsPresent = measurement.startPoint != nil
        guard endpointsPresent == (measurement.endPoint != nil) else {
            throw RoomRevisionEditorError.invalidMeasurement
        }
        guard let start = measurement.startPoint, let end = measurement.endPoint else {
            return
        }
        guard start.isFinite, end.isFinite else {
            throw RoomRevisionEditorError.invalidSpatialPoint
        }
        let expected = distance(from: start, to: end)
        let tolerance = max(0.000_001, expected * 0.000_001)
        guard abs(measurement.valueMeters - expected) <= tolerance else {
            throw RoomRevisionEditorError.invalidMeasurement
        }
    }

    private static func distance(from start: RoomPoint3D, to end: RoomPoint3D) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let dz = end.z - start.z
        return sqrt(dx * dx + dy * dy + dz * dz)
    }
}
