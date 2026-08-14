import Foundation

// MARK: - Canonical spatial orientation

public struct RoomNormalizedBounds: Codable, Sendable, Equatable {
    public var minimum: RoomRedesignVector3
    public var maximum: RoomRedesignVector3

    public init(minimum: RoomRedesignVector3, maximum: RoomRedesignVector3) {
        self.minimum = minimum
        self.maximum = maximum
    }

    public func validate() throws {
        try RoomSpatialValidation.point(minimum, at: "roomBounds.minimum")
        try RoomSpatialValidation.point(maximum, at: "roomBounds.maximum")
        guard maximum.x - minimum.x > 0.01,
              maximum.y - minimum.y > 0.01,
              maximum.z - minimum.z > 0.01
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "roomBounds",
                reason: "Normalized room bounds must be finite and non-degenerate on every axis."
            )
        }
    }

    public var center: RoomRedesignVector3 {
        .init(
            x: (minimum.x + maximum.x) / 2,
            y: (minimum.y + maximum.y) / 2,
            z: (minimum.z + maximum.z) / 2
        )
    }
}

public struct RoomOrientationInput: Sendable, Equatable {
    public var source: RoomOrientationSource
    public var confidence: Double
    public var entryPositionMeters: RoomRedesignVector3
    public var inwardDirection: RoomRedesignVector3
    public var roomBounds: RoomNormalizedBounds
    public var topDownPresentation: RoomTopDownPresentationTransform?
    public var entryFeatureID: String?
    public var referenceWallFeatureID: String?
    public var suggestionEvidence: RoomOrientationSuggestionEvidence?

    public init(
        source: RoomOrientationSource,
        confidence: Double,
        entryPositionMeters: RoomRedesignVector3,
        inwardDirection: RoomRedesignVector3,
        roomBounds: RoomNormalizedBounds,
        topDownPresentation: RoomTopDownPresentationTransform? = nil,
        entryFeatureID: String? = nil,
        referenceWallFeatureID: String?,
        suggestionEvidence: RoomOrientationSuggestionEvidence? = nil
    ) {
        self.source = source
        self.confidence = confidence
        self.entryPositionMeters = entryPositionMeters
        self.inwardDirection = inwardDirection
        self.roomBounds = roomBounds
        self.topDownPresentation = topDownPresentation
        self.entryFeatureID = entryFeatureID
        self.referenceWallFeatureID = referenceWallFeatureID
        self.suggestionEvidence = suggestionEvidence
    }
}

public enum RoomTopDownAxis: String, Codable, Sendable, Equatable {
    case positiveY
}

/// A local display preference for the derived top-down drawing. It never
/// transforms captured semantic coordinates, orientation axes, or cameras.
/// Rotation is applied first; horizontal mirroring is applied afterward in
/// the displayed plan's coordinate system.
public struct RoomTopDownPresentationTransform: Codable, Sendable, Equatable {
    public var quarterTurnsClockwise: Int
    public var isMirroredHorizontally: Bool

    public init(quarterTurnsClockwise: Int, isMirroredHorizontally: Bool) {
        self.quarterTurnsClockwise = quarterTurnsClockwise
        self.isMirroredHorizontally = isMirroredHorizontally
    }

    public static let viewerAligned = RoomTopDownPresentationTransform(
        quarterTurnsClockwise: 0,
        isMirroredHorizontally: false
    )

    public func rotatedClockwise() -> Self {
        .init(
            quarterTurnsClockwise: (quarterTurnsClockwise + 1) % 4,
            isMirroredHorizontally: isMirroredHorizontally
        )
    }

    public func togglingHorizontalMirror() -> Self {
        .init(
            quarterTurnsClockwise: quarterTurnsClockwise,
            isMirroredHorizontally: !isMirroredHorizontally
        )
    }

    public func validate(at path: String = "orientation.topDownOrientation.presentationTransform") throws {
        guard (0...3).contains(quarterTurnsClockwise) else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "\(path).quarterTurnsClockwise",
                reason: "Top-down presentation rotation must be 0, 1, 2, or 3 clockwise quarter turns."
            )
        }
    }
}

public struct RoomTopDownOrientation: Codable, Sendable, Equatable {
    public var upAxis: RoomTopDownAxis
    public var screenUp: RoomRedesignVector3
    /// Optional for backward decoding of Slice 1 companions written before
    /// user-controlled top-down presentation was introduced.
    public var presentationTransform: RoomTopDownPresentationTransform?

    public init(
        upAxis: RoomTopDownAxis = .positiveY,
        screenUp: RoomRedesignVector3,
        presentationTransform: RoomTopDownPresentationTransform? = nil
    ) {
        self.upAxis = upAxis
        self.screenUp = screenUp
        self.presentationTransform = presentationTransform
    }
}

public struct RoomOrientationSuggestionEvidence: Codable, Sendable, Equatable {
    public var featureID: String
    public var semanticRole: RoomSemanticRole
    public var usedScanStartPose: Bool
    public var usedDoorOrOpening: Bool
    /// Exact first finite app-owned AR camera pose used by the suggestion.
    /// Optional so already-written Slice 1 companions remain decodable.
    public var scanStartPose: RoomScanStartPose?

    public init(
        featureID: String,
        semanticRole: RoomSemanticRole,
        usedScanStartPose: Bool,
        usedDoorOrOpening: Bool,
        scanStartPose: RoomScanStartPose? = nil
    ) {
        self.featureID = featureID
        self.semanticRole = semanticRole
        self.usedScanStartPose = usedScanStartPose
        self.usedDoorOrOpening = usedDoorOrOpening
        self.scanStartPose = scanStartPose
    }
}

/// Slice 1 orientation is a strict, revision-bound extension of the retained
/// v1 contract. It does not alter any package or revision document.
public struct RoomOrientationContractV2: Codable, Sendable, Equatable {
    public var source: RoomOrientationSource
    public var confidence: Double
    public var coordinateSpaceEpochID: String
    public var entryPositionMeters: RoomRedesignVector3
    public var inwardDirection: RoomRedesignVector3
    public var canonicalAxes: RoomCanonicalAxesContract
    public var topDownOrientation: RoomTopDownOrientation
    public var canonicalCameras: [RoomCanonicalCameraContract]
    /// Door/opening whose floor point defines the entry reference. Suggested
    /// documents contain the proposed feature; confirmed documents contain the
    /// feature the user actually selected. Optional for older Slice 1 bytes.
    public var entryFeatureID: String?
    public var referenceWallFeatureID: String?
    public var suggestionEvidence: RoomOrientationSuggestionEvidence?

    public init(
        source: RoomOrientationSource,
        confidence: Double,
        coordinateSpaceEpochID: String,
        entryPositionMeters: RoomRedesignVector3,
        inwardDirection: RoomRedesignVector3,
        canonicalAxes: RoomCanonicalAxesContract,
        topDownOrientation: RoomTopDownOrientation,
        canonicalCameras: [RoomCanonicalCameraContract],
        entryFeatureID: String? = nil,
        referenceWallFeatureID: String?,
        suggestionEvidence: RoomOrientationSuggestionEvidence?
    ) {
        self.source = source
        self.confidence = confidence
        self.coordinateSpaceEpochID = coordinateSpaceEpochID
        self.entryPositionMeters = entryPositionMeters
        self.inwardDirection = inwardDirection
        self.canonicalAxes = canonicalAxes
        self.topDownOrientation = topDownOrientation
        self.canonicalCameras = canonicalCameras
        self.entryFeatureID = entryFeatureID
        self.referenceWallFeatureID = referenceWallFeatureID
        self.suggestionEvidence = suggestionEvidence
    }

    public func validate(boundTo sourceRevision: RoomRedesignSourceRevision) throws {
        try sourceRevision.validate()
        guard coordinateSpaceEpochID == sourceRevision.coordinateSpaceEpochID else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "orientation.coordinateSpaceEpochID",
                reason: "Orientation cannot be rebound to another coordinate-space epoch."
            )
        }
        try RoomSpatialValidation.identifier(coordinateSpaceEpochID, at: "orientation.coordinateSpaceEpochID")
        try RoomSpatialValidation.unitInterval(confidence, at: "orientation.confidence")
        try RoomSpatialValidation.point(entryPositionMeters, at: "orientation.entryPositionMeters")
        try RoomSpatialValidation.horizontalUnit(inwardDirection, at: "orientation.inwardDirection")
        try canonicalAxes.validate()
        try RoomSpatialValidation.horizontalUnit(canonicalAxes.forward, at: "orientation.canonicalAxes.forward")
        try RoomSpatialValidation.unit(canonicalAxes.up, at: "orientation.canonicalAxes.up")
        try RoomSpatialValidation.unit(canonicalAxes.right, at: "orientation.canonicalAxes.right")

        guard RoomSpatialValidation.approximatelyEqual(canonicalAxes.forward, inwardDirection),
              RoomSpatialValidation.approximatelyEqual(canonicalAxes.up, .init(x: 0, y: 1, z: 0))
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "orientation.canonicalAxes",
                reason: "Canonical axes must agree with the confirmed inward direction and positive-Y up axis."
            )
        }
        let expectedRight = RoomSpatialValidation.cross(canonicalAxes.up, canonicalAxes.forward)
        guard RoomSpatialValidation.approximatelyEqual(canonicalAxes.right, expectedRight) else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "orientation.canonicalAxes",
                reason: "Canonical axes must form a consistent right-handed basis."
            )
        }
        guard topDownOrientation.upAxis == .positiveY,
              RoomSpatialValidation.approximatelyEqual(topDownOrientation.screenUp, canonicalAxes.forward)
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "orientation.topDownOrientation",
                reason: "Top-down orientation must use positive Y with canonical forward at screen-up."
            )
        }
        try topDownOrientation.presentationTransform?.validate()

        let requiredRoles = RoomCanonicalCameraRole.allSlice1Roles
        guard canonicalCameras.map(\.role) == requiredRoles else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "orientation.canonicalCameras",
                reason: "Canonical cameras must contain the six Slice 1 roles in deterministic order."
            )
        }
        guard Set(canonicalCameras.map(\.cameraID)).count == canonicalCameras.count else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "orientation.canonicalCameras.cameraID",
                reason: "Canonical camera identifiers must be unique."
            )
        }
        for (index, camera) in canonicalCameras.enumerated() {
            try camera.validate(at: "orientation.canonicalCameras[\(index)]")
        }
        if let entryFeatureID {
            try RoomSpatialValidation.identifier(entryFeatureID, at: "orientation.entryFeatureID")
        }

        switch source {
        case .manual:
            guard entryFeatureID == nil else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: "orientation.entryFeatureID",
                    reason: "Manual reference-wall orientation cannot claim a detected entry feature."
                )
            }
            guard let referenceWallFeatureID else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: "orientation.referenceWallFeatureID",
                    reason: "Manual orientation requires a user-selected reference wall."
                )
            }
            try RoomSpatialValidation.identifier(referenceWallFeatureID, at: "orientation.referenceWallFeatureID")
        case .suggested:
            if let suggestionEvidence {
                try suggestionEvidence.validate(coordinateSpaceEpochID: coordinateSpaceEpochID)
                if let entryFeatureID, entryFeatureID != suggestionEvidence.featureID {
                    throw RoomRedesignContractValidationError.invalidValue(
                        path: "orientation.entryFeatureID",
                        reason: "A suggested entry feature must match its app-owned evidence."
                    )
                }
            }
        case .confirmed:
            if let referenceWallFeatureID {
                try RoomSpatialValidation.identifier(referenceWallFeatureID, at: "orientation.referenceWallFeatureID")
            }
            if let suggestionEvidence {
                try suggestionEvidence.validate(coordinateSpaceEpochID: coordinateSpaceEpochID)
            }
        }
    }
}

private extension RoomOrientationSuggestionEvidence {
    func validate(coordinateSpaceEpochID: String) throws {
        try RoomSpatialValidation.identifier(featureID, at: "orientation.suggestionEvidence.featureID")
        guard semanticRole == .door || semanticRole == .opening,
              usedScanStartPose,
              usedDoorOrOpening
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "orientation.suggestionEvidence",
                reason: "Suggestions may use only app-owned scan-start and door/opening evidence."
            )
        }
        if let scanStartPose {
            try scanStartPose.validate(at: "orientation.suggestionEvidence.scanStartPose")
            guard scanStartPose.coordinateSpaceEpochID == coordinateSpaceEpochID else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: "orientation.suggestionEvidence.scanStartPose.coordinateSpaceEpochID",
                    reason: "Scan-start evidence cannot be rebound to another coordinate-space epoch."
                )
            }
        }
    }
}

public extension RoomCanonicalCameraRole {
    static let allSlice1Roles: [RoomCanonicalCameraRole] = [
        .entry, .wall, .corner, .orbit, .perspective, .topDown,
    ]
}

public enum RoomCanonicalCameraGenerator {
    public static func makeOrientation(
        sourceRevision: RoomRedesignSourceRevision,
        input: RoomOrientationInput
    ) throws -> RoomOrientationContractV2 {
        try sourceRevision.validate()
        try input.roomBounds.validate()
        try RoomSpatialValidation.unitInterval(input.confidence, at: "orientation.confidence")
        try RoomSpatialValidation.point(input.entryPositionMeters, at: "orientation.entryPositionMeters")
        guard RoomSpatialValidation.contains(input.roomBounds, input.entryPositionMeters, tolerance: 0.25) else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "orientation.entryPositionMeters",
                reason: "Entry position must be consistent with normalized room bounds."
            )
        }

        let forward = try RoomSpatialValidation.normalizedHorizontal(
            input.inwardDirection,
            at: "orientation.inwardDirection"
        )
        let up = RoomRedesignVector3(x: 0, y: 1, z: 0)
        let right = RoomSpatialValidation.cross(up, forward)
        try RoomSpatialValidation.unit(right, at: "orientation.canonicalAxes.right")
        let axes = RoomCanonicalAxesContract(right: right, up: up, forward: forward)
        let cameras = makeCameras(bounds: input.roomBounds, entry: input.entryPositionMeters, axes: axes)

        let result = RoomOrientationContractV2(
            source: input.source,
            confidence: input.confidence,
            coordinateSpaceEpochID: sourceRevision.coordinateSpaceEpochID,
            entryPositionMeters: input.entryPositionMeters,
            inwardDirection: forward,
            canonicalAxes: axes,
            topDownOrientation: .init(
                screenUp: forward,
                presentationTransform: input.topDownPresentation
            ),
            canonicalCameras: cameras,
            entryFeatureID: input.entryFeatureID,
            referenceWallFeatureID: input.referenceWallFeatureID,
            suggestionEvidence: input.suggestionEvidence
        )
        try result.validate(boundTo: sourceRevision)
        return result
    }

    private static func makeCameras(
        bounds: RoomNormalizedBounds,
        entry: RoomRedesignVector3,
        axes: RoomCanonicalAxesContract
    ) -> [RoomCanonicalCameraContract] {
        let center = bounds.center
        let width = bounds.maximum.x - bounds.minimum.x
        let depth = bounds.maximum.z - bounds.minimum.z
        let height = bounds.maximum.y - bounds.minimum.y
        let span = max(width, depth)
        let eyeY = min(bounds.maximum.y - 0.15, max(bounds.minimum.y + 1.2, center.y))
        let targetY = min(bounds.maximum.y - 0.1, max(bounds.minimum.y + 0.8, center.y))
        let target = RoomRedesignVector3(x: center.x, y: targetY, z: center.z)
        let entryEye = RoomRedesignVector3(x: entry.x, y: eyeY, z: entry.z)
        let wallEye = target + axes.forward * (-(span * 0.48 + 0.6))
        let cornerEye = target + axes.forward * (-(span * 0.55 + 0.6)) + axes.right * (span * 0.45)
        let orbitEye = target + axes.forward * (-(span * 0.7 + 0.8)) + axes.right * (span * 0.7)
        let perspectiveEye = target + axes.forward * (-(span * 0.5 + 0.5)) - axes.right * (span * 0.35)
        let topEye = RoomRedesignVector3(
            x: center.x,
            y: bounds.maximum.y + max(span, height) + 0.75,
            z: center.z
        )
        return [
            .init(cameraID: "canonical-entry", role: .entry, positionMeters: entryEye, targetMeters: target, fieldOfViewDegrees: 62),
            .init(cameraID: "canonical-wall", role: .wall, positionMeters: wallEye.withY(eyeY), targetMeters: target, fieldOfViewDegrees: 58),
            .init(cameraID: "canonical-corner", role: .corner, positionMeters: cornerEye.withY(eyeY), targetMeters: target, fieldOfViewDegrees: 64),
            .init(cameraID: "canonical-orbit", role: .orbit, positionMeters: orbitEye.withY(eyeY + 0.25), targetMeters: target, fieldOfViewDegrees: 68),
            .init(cameraID: "canonical-perspective", role: .perspective, positionMeters: perspectiveEye.withY(eyeY + 0.35), targetMeters: target, fieldOfViewDegrees: 55),
            .init(cameraID: "canonical-top-down", role: .topDown, positionMeters: topEye, targetMeters: center, fieldOfViewDegrees: 50),
        ]
    }
}

// MARK: - App-owned suggestion seam

public struct RoomScanStartPose: Codable, Sendable, Equatable {
    public var positionMeters: RoomRedesignVector3
    public var forwardDirection: RoomRedesignVector3
    public var coordinateSpaceEpochID: String

    public init(
        positionMeters: RoomRedesignVector3,
        forwardDirection: RoomRedesignVector3,
        coordinateSpaceEpochID: String
    ) {
        self.positionMeters = positionMeters
        self.forwardDirection = forwardDirection
        self.coordinateSpaceEpochID = coordinateSpaceEpochID
    }
}

private extension RoomScanStartPose {
    func validate(at path: String) throws {
        try RoomSpatialValidation.point(positionMeters, at: "\(path).positionMeters")
        _ = try RoomSpatialValidation.normalizedHorizontal(
            forwardDirection,
            at: "\(path).forwardDirection"
        )
        try RoomSpatialValidation.identifier(coordinateSpaceEpochID, at: "\(path).coordinateSpaceEpochID")
    }
}

public struct RoomEntryCandidate: Codable, Sendable, Equatable {
    public var featureID: String
    public var semanticRole: RoomSemanticRole
    public var positionMeters: RoomRedesignVector3
    public var inwardDirection: RoomRedesignVector3
    public var confidence: Double

    public init(
        featureID: String,
        semanticRole: RoomSemanticRole,
        positionMeters: RoomRedesignVector3,
        inwardDirection: RoomRedesignVector3,
        confidence: Double
    ) {
        self.featureID = featureID
        self.semanticRole = semanticRole
        self.positionMeters = positionMeters
        self.inwardDirection = inwardDirection
        self.confidence = confidence
    }
}

public struct RoomOrientationSuggestion: Codable, Sendable, Equatable {
    public var source: RoomOrientationSource
    public var confidence: Double
    public var coordinateSpaceEpochID: String
    public var entryPositionMeters: RoomRedesignVector3
    public var inwardDirection: RoomRedesignVector3
    public var evidence: RoomOrientationSuggestionEvidence
}

public enum RoomOrientationSuggestionEngine {
    /// This deterministic helper is app-owned. It makes no claim that RoomPlan
    /// exposes a canonical entry and never admits windows or other categories.
    public static func suggest(
        scanStartPose: RoomScanStartPose,
        candidates: [RoomEntryCandidate]
    ) throws -> RoomOrientationSuggestion? {
        try RoomSpatialValidation.point(scanStartPose.positionMeters, at: "scanStartPose.positionMeters")
        let startForward = try RoomSpatialValidation.normalizedHorizontal(
            scanStartPose.forwardDirection,
            at: "scanStartPose.forwardDirection"
        )
        try RoomSpatialValidation.identifier(scanStartPose.coordinateSpaceEpochID, at: "scanStartPose.coordinateSpaceEpochID")

        let admissible = try candidates.compactMap { candidate -> (RoomEntryCandidate, RoomRedesignVector3, Double)? in
            guard candidate.semanticRole == .door || candidate.semanticRole == .opening else { return nil }
            try RoomSpatialValidation.identifier(candidate.featureID, at: "entryCandidate.featureID")
            try RoomSpatialValidation.point(candidate.positionMeters, at: "entryCandidate.positionMeters")
            try RoomSpatialValidation.unitInterval(candidate.confidence, at: "entryCandidate.confidence")
            let inward = try RoomSpatialValidation.normalizedHorizontal(
                candidate.inwardDirection,
                at: "entryCandidate.inwardDirection"
            )
            let distance = RoomSpatialValidation.distanceXZ(scanStartPose.positionMeters, candidate.positionMeters)
            guard distance.isFinite else { return nil }
            let alignment = max(0, RoomSpatialValidation.dot(startForward, inward))
            let proximity = 1 / (1 + distance)
            return (candidate, inward, candidate.confidence * 0.6 + alignment * 0.25 + proximity * 0.15)
        }
        guard let selected = admissible.sorted(by: {
            if abs($0.2 - $1.2) > 0.000_001 { return $0.2 > $1.2 }
            return $0.0.featureID < $1.0.featureID
        }).first else {
            return nil
        }
        return RoomOrientationSuggestion(
            source: .suggested,
            confidence: min(1, max(0, selected.2)),
            coordinateSpaceEpochID: scanStartPose.coordinateSpaceEpochID,
            entryPositionMeters: selected.0.positionMeters,
            inwardDirection: selected.1,
            evidence: .init(
                featureID: selected.0.featureID,
                semanticRole: selected.0.semanticRole,
                usedScanStartPose: true,
                usedDoorOrOpening: true,
                scanStartPose: scanStartPose
            )
        )
    }
}

// MARK: - Redesign intent, concepts, and property containers

public struct RoomRedesignStructuredConstraints: Codable, Sendable, Equatable {
    public var purpose: [String]
    public var style: [String]
    public var budget: String?
    public var householdNeeds: [String]
    public var accessibility: [String]
    public var circulation: [String]
    public var materials: [String]
    public var colors: [String]
    public var referenceImageIDs: [String]
    public var desiredObjects: [String]

    public init(
        purpose: [String] = [],
        style: [String] = [],
        budget: String? = nil,
        householdNeeds: [String] = [],
        accessibility: [String] = [],
        circulation: [String] = [],
        materials: [String] = [],
        colors: [String] = [],
        referenceImageIDs: [String] = [],
        desiredObjects: [String] = []
    ) {
        self.purpose = purpose
        self.style = style
        self.budget = budget
        self.householdNeeds = householdNeeds
        self.accessibility = accessibility
        self.circulation = circulation
        self.materials = materials
        self.colors = colors
        self.referenceImageIDs = referenceImageIDs
        self.desiredObjects = desiredObjects
    }

    public func validate() throws {
        let groups = [purpose, style, householdNeeds, accessibility, circulation, materials, colors, desiredObjects]
        for (groupIndex, group) in groups.enumerated() {
            guard group.count <= 100, Set(group).count == group.count else {
                throw RoomRedesignContractValidationError.invalidValue(path: "redesignIntent.constraints[\(groupIndex)]", reason: "Constraint values must be unique and bounded.")
            }
            for value in group { try RoomSpatialValidation.text(value, maximum: 500, at: "redesignIntent.constraints") }
        }
        if let budget { try RoomSpatialValidation.text(budget, maximum: 500, at: "redesignIntent.constraints.budget") }
        guard referenceImageIDs.count <= 100, Set(referenceImageIDs).count == referenceImageIDs.count else {
            throw RoomRedesignContractValidationError.invalidValue(path: "redesignIntent.constraints.referenceImageIDs", reason: "Reference image IDs must be unique and bounded.")
        }
        for value in referenceImageIDs { try RoomSpatialValidation.identifier(value, at: "redesignIntent.constraints.referenceImageIDs") }
    }
}

public struct RoomRedesignIntentV2: Codable, Sendable, Equatable {
    public var request: String
    public var scope: RoomRedesignScope
    public var constraints: RoomRedesignStructuredConstraints?
    public var permissions: [RoomFeaturePermissionContract]

    public init(
        request: String,
        scope: RoomRedesignScope,
        constraints: RoomRedesignStructuredConstraints?,
        permissions: [RoomFeaturePermissionContract]
    ) {
        self.request = request
        self.scope = scope
        self.constraints = constraints
        self.permissions = permissions
    }

    public func validate() throws {
        try RoomSpatialValidation.text(request, maximum: 8_000, at: "redesignIntent.request")
        try constraints?.validate()
        guard permissions.count <= 1_000,
              Set(permissions.map(\.featureID)).count == permissions.count
        else {
            throw RoomRedesignContractValidationError.invalidValue(path: "redesignIntent.permissions", reason: "Feature permissions must be unique and bounded.")
        }
        for permission in permissions {
            try RoomSpatialValidation.identifier(permission.featureID, at: "redesignIntent.permissions.featureID")
        }
    }
}

public enum RoomConceptApprovalState: String, Codable, Sendable, Equatable {
    case pending
    case approved
    case rejected
}

public enum RoomConceptArchiveState: String, Codable, Sendable, Equatable {
    case active
    case archived
}

public struct RoomConceptMetadataV2: Codable, Sendable, Equatable {
    public var conceptSetID: String
    public var sourceRevision: RoomRedesignSourceRevision
    public var request: String
    public var scope: RoomRedesignScope
    public var provider: String
    public var sourceAIRoomPackageSchemaVersion: String
    public var sourceAIRoomPackageID: String
    public var createdAt: Date
    public var importedAt: Date
    public var mappingStatus: RoomConceptMappingStatus
    public var attachments: [RoomConceptAttachmentContract]
    public var comments: [String]
    public var approvalState: RoomConceptApprovalState
    public var archiveState: RoomConceptArchiveState

    public init(
        conceptSetID: String,
        sourceRevision: RoomRedesignSourceRevision,
        request: String,
        scope: RoomRedesignScope,
        provider: String,
        sourceAIRoomPackageSchemaVersion: String,
        sourceAIRoomPackageID: String,
        createdAt: Date,
        importedAt: Date,
        mappingStatus: RoomConceptMappingStatus,
        attachments: [RoomConceptAttachmentContract],
        comments: [String],
        approvalState: RoomConceptApprovalState,
        archiveState: RoomConceptArchiveState
    ) {
        self.conceptSetID = conceptSetID
        self.sourceRevision = sourceRevision
        self.request = request
        self.scope = scope
        self.provider = provider
        self.sourceAIRoomPackageSchemaVersion = sourceAIRoomPackageSchemaVersion
        self.sourceAIRoomPackageID = sourceAIRoomPackageID
        self.createdAt = createdAt
        self.importedAt = importedAt
        self.mappingStatus = mappingStatus
        self.attachments = attachments
        self.comments = comments
        self.approvalState = approvalState
        self.archiveState = archiveState
    }

    public func validate(boundTo expectedSource: RoomRedesignSourceRevision) throws {
        try RoomSpatialValidation.identifier(conceptSetID, at: "conceptMetadata.conceptSetID")
        try sourceRevision.validate()
        guard sourceRevision == expectedSource else {
            throw RoomRedesignContractValidationError.invalidValue(path: "conceptMetadata.sourceRevision", reason: "Concept Sets cannot be rebound to another revision or coordinate-space epoch.")
        }
        try RoomSpatialValidation.text(request, maximum: 8_000, at: "conceptMetadata.request")
        try RoomSpatialValidation.text(provider, maximum: 500, at: "conceptMetadata.provider")
        try RoomSpatialValidation.identifier(sourceAIRoomPackageSchemaVersion, at: "conceptMetadata.sourceAIRoomPackageSchemaVersion")
        try RoomSpatialValidation.identifier(sourceAIRoomPackageID, at: "conceptMetadata.sourceAIRoomPackageID")
        guard createdAt.timeIntervalSinceReferenceDate.isFinite,
              importedAt.timeIntervalSinceReferenceDate.isFinite,
              importedAt >= createdAt,
              attachments.count <= 1_000,
              comments.count <= 1_000
        else {
            throw RoomRedesignContractValidationError.invalidValue(path: "conceptMetadata", reason: "Concept provenance dates and collections must be finite, ordered, and bounded.")
        }
        for (index, attachment) in attachments.enumerated() { try attachment.validate(at: "conceptMetadata.attachments[\(index)]") }
        for comment in comments { try RoomSpatialValidation.text(comment, maximum: 2_000, at: "conceptMetadata.comments") }
    }
}

public struct RoomPropertyContainerV1: Codable, Sendable, Equatable {
    public static let schemaVersionValue = "roomscan-property-container-v1"

    public var schemaVersion: String
    public var propertyID: String
    public var displayName: String
    public var roomProjectIDs: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        schemaVersion: String = Self.schemaVersionValue,
        propertyID: String,
        displayName: String,
        roomProjectIDs: [String],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.propertyID = propertyID
        self.displayName = displayName
        self.roomProjectIDs = roomProjectIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func validate() throws {
        guard schemaVersion == Self.schemaVersionValue else {
            throw RoomRedesignContractValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        try RoomSpatialValidation.identifier(propertyID, at: "propertyID")
        try RoomSpatialValidation.text(displayName, maximum: 500, at: "displayName")
        guard roomProjectIDs.count <= 1_000,
              Set(roomProjectIDs).count == roomProjectIDs.count
        else {
            throw RoomRedesignContractValidationError.invalidValue(path: "roomProjectIDs", reason: "Room project IDs must be unique and bounded.")
        }
        for id in roomProjectIDs { try RoomSpatialValidation.identifier(id, at: "roomProjectIDs") }
        guard createdAt.timeIntervalSinceReferenceDate.isFinite,
              updatedAt.timeIntervalSinceReferenceDate.isFinite,
              updatedAt >= createdAt
        else {
            throw RoomRedesignContractValidationError.invalidValue(path: "updatedAt", reason: "Property dates must be finite and ordered.")
        }
    }
}

public struct RoomLocalRedesignExtensionV2: Codable, Sendable, Equatable {
    public static let schemaVersionValue = "roomscan-local-redesign-extension-v2"

    public var schemaVersion: String
    public var contractKind: RoomRedesignContractKind
    public var sourceRevision: RoomRedesignSourceRevision
    public var orientation: RoomOrientationContractV2
    /// Absent while an app-owned suggestion awaits review. Once present, the
    /// free-form request is required and cannot be empty.
    public var redesignIntent: RoomRedesignIntentV2?
    public var propertyMembership: RoomPropertyMembershipContract?
    public var conceptMetadata: [RoomConceptMetadataV2]

    public init(
        schemaVersion: String = Self.schemaVersionValue,
        contractKind: RoomRedesignContractKind = .localRedesignExtension,
        sourceRevision: RoomRedesignSourceRevision,
        orientation: RoomOrientationContractV2,
        redesignIntent: RoomRedesignIntentV2?,
        propertyMembership: RoomPropertyMembershipContract?,
        conceptMetadata: [RoomConceptMetadataV2]
    ) {
        self.schemaVersion = schemaVersion
        self.contractKind = contractKind
        self.sourceRevision = sourceRevision
        self.orientation = orientation
        self.redesignIntent = redesignIntent
        self.propertyMembership = propertyMembership
        self.conceptMetadata = conceptMetadata
    }

    public func validate() throws {
        guard schemaVersion == Self.schemaVersionValue, contractKind == .localRedesignExtension else {
            throw RoomRedesignContractValidationError.mismatchedDiscriminant(schemaVersion: schemaVersion, contractKind: contractKind.rawValue)
        }
        try sourceRevision.validate()
        try orientation.validate(boundTo: sourceRevision)
        try redesignIntent?.validate()
        try propertyMembership?.validate(containing: sourceRevision.projectID)
        guard conceptMetadata.count <= 1_000,
              Set(conceptMetadata.map(\.conceptSetID)).count == conceptMetadata.count
        else {
            throw RoomRedesignContractValidationError.invalidValue(path: "conceptMetadata", reason: "Concept Set IDs must be unique and bounded.")
        }
        for concept in conceptMetadata { try concept.validate(boundTo: sourceRevision) }
    }
}

// MARK: - Provider-neutral readiness guard

public enum RoomOrientationReadinessOperation: String, Sendable, Equatable {
    case aiExport
    case publication
}

public enum RoomOrientationReadinessError: Error, Sendable, Equatable {
    case userConfirmationRequired
    case sourceRevisionMismatch
    case redesignRequestRequired
    case invalidOrientation
}

public enum RoomOrientationReadiness {
    public static func requireEligible(
        _ document: RoomLocalRedesignExtensionV2,
        expectedSourceRevision: RoomRedesignSourceRevision? = nil,
        operation: RoomOrientationReadinessOperation
    ) throws {
        do { try document.validate() } catch {
            throw RoomOrientationReadinessError.invalidOrientation
        }
        if let expectedSourceRevision, document.sourceRevision != expectedSourceRevision {
            throw RoomOrientationReadinessError.sourceRevisionMismatch
        }
        // This exact guard is intentionally simple so its negative test can be
        // mutation-proven without constructing any Slice 3 export workflow.
        guard document.orientation.source != .suggested else {
            throw RoomOrientationReadinessError.userConfirmationRequired
        }
        guard let request = document.redesignIntent?.request,
              !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw RoomOrientationReadinessError.redesignRequestRequired
        }
        _ = operation
    }
}

// MARK: - Semantic presentation tokens

public enum RoomSemanticRole: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case wall
    case door
    case window
    case opening
    case floor
    case ceiling
    case fixedObject
    case movableObject
    case unknownObject
}

public enum RoomSemanticMaterialPattern: String, Codable, Sendable, Equatable, Hashable {
    case solid
    case doubleLine
    case diagonalStripe
    case dashed
    case dotGrid
    case crosshatch
    case denseFill
    case sparseFill
    case questionMark
}

public struct RoomSemanticPresentationToken: Codable, Sendable, Equatable {
    public var role: RoomSemanticRole
    public var displayName: String
    public var symbolName: String
    public var materialPattern: RoomSemanticMaterialPattern

    public func accessibilityDescription(for element: RoomSemanticElement) -> String {
        let dimensions = element.dimensionsMeters
        return "\(displayName): \(element.label). \(String(format: "%.2f by %.2f by %.2f meters", dimensions.width, dimensions.height, dimensions.depth))."
    }
}

public enum RoomSemanticPresentation {
    public static func role(for element: RoomSemanticElement) -> RoomSemanticRole {
        switch element.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "wall": return .wall
        case "door": return .door
        case "window": return .window
        case "opening": return .opening
        case "floor": return .floor
        case "ceiling": return .ceiling
        default:
            switch element.mobility ?? .unknown {
            case .structural, .unknown: return .unknownObject
            case .fixed: return .fixedObject
            case .movable: return .movableObject
            }
        }
    }

    public static func token(for element: RoomSemanticElement) -> RoomSemanticPresentationToken {
        token(for: role(for: element))
    }

    public static func token(for role: RoomSemanticRole) -> RoomSemanticPresentationToken {
        switch role {
        case .wall: return .init(role: role, displayName: "Wall", symbolName: "rectangle.portrait", materialPattern: .solid)
        case .door: return .init(role: role, displayName: "Door", symbolName: "door.left.hand.open", materialPattern: .doubleLine)
        case .window: return .init(role: role, displayName: "Window", symbolName: "window.vertical.open", materialPattern: .diagonalStripe)
        case .opening: return .init(role: role, displayName: "Opening", symbolName: "rectangle.dashed", materialPattern: .dashed)
        case .floor: return .init(role: role, displayName: "Floor", symbolName: "square.grid.3x3", materialPattern: .dotGrid)
        case .ceiling: return .init(role: role, displayName: "Ceiling", symbolName: "square.grid.2x2", materialPattern: .crosshatch)
        case .fixedObject: return .init(role: role, displayName: "Fixed object", symbolName: "shippingbox.fill", materialPattern: .denseFill)
        case .movableObject: return .init(role: role, displayName: "Movable object", symbolName: "move.3d", materialPattern: .sparseFill)
        case .unknownObject: return .init(role: role, displayName: "Unknown object", symbolName: "questionmark.diamond", materialPattern: .questionMark)
        }
    }
}

public enum RoomRedesignCanonicalJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = RoomJSONCoding.makeEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func sha256<T: Encodable>(_ value: T) throws -> String {
        RoomSHA256.hexDigest(of: try encode(value))
    }
}

// MARK: - Spatial utilities

public enum RoomSpatialNormalization {
    public static func bounds(of snapshot: RoomSemanticSnapshot) throws -> RoomNormalizedBounds {
        var minimum = RoomRedesignVector3(x: .infinity, y: .infinity, z: .infinity)
        var maximum = RoomRedesignVector3(x: -.infinity, y: -.infinity, z: -.infinity)
        let elements = snapshot.structuralElements + snapshot.objectElements
        guard !elements.isEmpty else {
            throw RoomRedesignContractValidationError.invalidValue(path: "semanticSnapshot", reason: "A room needs finite semantic elements for orientation.")
        }
        for element in elements {
            guard element.dimensionsMeters.width.isFinite,
                  element.dimensionsMeters.height.isFinite,
                  element.dimensionsMeters.depth.isFinite,
                  element.dimensionsMeters.width >= 0,
                  element.dimensionsMeters.height >= 0,
                  element.dimensionsMeters.depth >= 0
            else {
                throw RoomRedesignContractValidationError.invalidValue(path: "semanticSnapshot.elements", reason: "Element dimensions must be finite and non-negative.")
            }
            let center = try position(of: element)
            let half = RoomRedesignVector3(
                x: max(0.005, element.dimensionsMeters.width / 2),
                y: max(0.005, element.dimensionsMeters.height / 2),
                z: max(0.005, element.dimensionsMeters.depth / 2)
            )
            minimum = .init(x: min(minimum.x, center.x - half.x), y: min(minimum.y, center.y - half.y), z: min(minimum.z, center.z - half.z))
            maximum = .init(x: max(maximum.x, center.x + half.x), y: max(maximum.y, center.y + half.y), z: max(maximum.z, center.z + half.z))
        }
        let result = RoomNormalizedBounds(minimum: minimum, maximum: maximum)
        try result.validate()
        return result
    }

    public static func position(of element: RoomSemanticElement) throws -> RoomRedesignVector3 {
        if let transform = element.transform {
            guard transform.isValid else {
                throw RoomRedesignContractValidationError.invalidValue(path: "semanticElement.transform", reason: "Element transforms must be finite 4x4 matrices.")
            }
            return .init(
                x: transform.columnMajorValues[12],
                y: transform.columnMajorValues[13],
                z: transform.columnMajorValues[14]
            )
        }
        if let corners = element.polygonCorners, !corners.isEmpty {
            guard corners.allSatisfy(\.isFinite) else {
                throw RoomRedesignContractValidationError.invalidValue(path: "semanticElement.polygonCorners", reason: "Polygon corners must be finite.")
            }
            let divisor = Double(corners.count)
            return .init(
                x: corners.reduce(0) { $0 + $1.x } / divisor,
                y: corners.reduce(0) { $0 + $1.y } / divisor,
                z: corners.reduce(0) { $0 + $1.z } / divisor
            )
        }
        return .init(x: 0, y: element.dimensionsMeters.height / 2, z: 0)
    }
}

private enum RoomSpatialValidation {
    static func identifier(_ value: String, at path: String) throws {
        guard RoomPathValidation.isSafeStableIdentifier(value) else {
            throw RoomRedesignContractValidationError.invalidValue(path: path, reason: "Value must be a stable identifier.")
        }
    }

    static func text(_ value: String, maximum: Int, at path: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.count <= maximum,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw RoomRedesignContractValidationError.invalidValue(path: path, reason: "Text must be non-empty, bounded, and contain no control characters.")
        }
    }

    static func point(_ value: RoomRedesignVector3, at path: String) throws {
        guard value.x.isFinite, value.y.isFinite, value.z.isFinite,
              abs(value.x) <= 10_000, abs(value.y) <= 10_000, abs(value.z) <= 10_000
        else {
            throw RoomRedesignContractValidationError.invalidValue(path: path, reason: "Coordinates must be finite and bounded.")
        }
    }

    static func unitInterval(_ value: Double, at path: String) throws {
        guard value.isFinite, (0...1).contains(value) else {
            throw RoomRedesignContractValidationError.invalidValue(path: path, reason: "Confidence must be finite and between zero and one.")
        }
    }

    static func unit(_ value: RoomRedesignVector3, at path: String) throws {
        try point(value, at: path)
        guard abs(length(value) - 1) <= 0.000_1 else {
            throw RoomRedesignContractValidationError.invalidValue(path: path, reason: "Direction must be a unit vector.")
        }
    }

    static func horizontalUnit(_ value: RoomRedesignVector3, at path: String) throws {
        try unit(value, at: path)
        guard abs(value.y) <= 0.000_1 else {
            throw RoomRedesignContractValidationError.invalidValue(path: path, reason: "Canonical inward directions must be horizontal.")
        }
    }

    static func normalizedHorizontal(_ value: RoomRedesignVector3, at path: String) throws -> RoomRedesignVector3 {
        try point(value, at: path)
        let horizontal = RoomRedesignVector3(x: value.x, y: 0, z: value.z)
        let magnitude = length(horizontal)
        guard magnitude.isFinite, magnitude > 0.001 else {
            throw RoomRedesignContractValidationError.invalidValue(path: path, reason: "Inward direction must have a non-degenerate horizontal component.")
        }
        return .init(x: horizontal.x / magnitude, y: 0, z: horizontal.z / magnitude)
    }

    static func length(_ value: RoomRedesignVector3) -> Double {
        sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
    }

    static func dot(_ lhs: RoomRedesignVector3, _ rhs: RoomRedesignVector3) -> Double {
        lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
    }

    static func cross(_ lhs: RoomRedesignVector3, _ rhs: RoomRedesignVector3) -> RoomRedesignVector3 {
        .init(
            x: lhs.y * rhs.z - lhs.z * rhs.y,
            y: lhs.z * rhs.x - lhs.x * rhs.z,
            z: lhs.x * rhs.y - lhs.y * rhs.x
        )
    }

    static func approximatelyEqual(_ lhs: RoomRedesignVector3, _ rhs: RoomRedesignVector3) -> Bool {
        abs(lhs.x - rhs.x) <= 0.000_1 && abs(lhs.y - rhs.y) <= 0.000_1 && abs(lhs.z - rhs.z) <= 0.000_1
    }

    static func contains(_ bounds: RoomNormalizedBounds, _ point: RoomRedesignVector3, tolerance: Double) -> Bool {
        point.x >= bounds.minimum.x - tolerance && point.x <= bounds.maximum.x + tolerance
            && point.y >= bounds.minimum.y - tolerance && point.y <= bounds.maximum.y + tolerance
            && point.z >= bounds.minimum.z - tolerance && point.z <= bounds.maximum.z + tolerance
    }

    static func distanceXZ(_ lhs: RoomRedesignVector3, _ rhs: RoomRedesignVector3) -> Double {
        hypot(lhs.x - rhs.x, lhs.z - rhs.z)
    }
}

private func + (lhs: RoomRedesignVector3, rhs: RoomRedesignVector3) -> RoomRedesignVector3 {
    .init(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
}

private func - (lhs: RoomRedesignVector3, rhs: RoomRedesignVector3) -> RoomRedesignVector3 {
    .init(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
}

private func * (lhs: RoomRedesignVector3, rhs: Double) -> RoomRedesignVector3 {
    .init(x: lhs.x * rhs, y: lhs.y * rhs, z: lhs.z * rhs)
}

private extension RoomRedesignVector3 {
    func withY(_ value: Double) -> RoomRedesignVector3 {
        .init(x: x, y: value, z: z)
    }
}
