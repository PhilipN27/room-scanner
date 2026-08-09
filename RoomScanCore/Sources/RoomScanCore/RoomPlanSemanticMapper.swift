import Foundation

/// Foundation-only representation of a RoomPlan surface. The iOS adapter owns
/// SDK translation; this descriptor keeps normalized semantic mapping portable
/// and unit-testable without RoomPlan or ARKit imports.
public struct RoomPlanSemanticSurfaceDescriptor: Codable, Sendable, Equatable {
    public var sourceIdentifier: String
    public var parentSourceIdentifier: String?
    public var kind: String
    public var label: String
    public var dimensionsMeters: RoomDimensions
    public var transform: RoomTransform4x4
    public var polygonCorners: [RoomPoint3D]
    public var flattenedAttributeShortIdentifiers: [String]
    public var classificationConfidence: RoomClassificationConfidence

    public init(
        sourceIdentifier: String,
        parentSourceIdentifier: String? = nil,
        kind: String,
        label: String,
        dimensionsMeters: RoomDimensions,
        transform: RoomTransform4x4,
        polygonCorners: [RoomPoint3D] = [],
        flattenedAttributeShortIdentifiers: [String] = [],
        classificationConfidence: RoomClassificationConfidence = .unknown
    ) {
        self.sourceIdentifier = sourceIdentifier
        self.parentSourceIdentifier = parentSourceIdentifier
        self.kind = kind
        self.label = label
        self.dimensionsMeters = dimensionsMeters
        self.transform = transform
        self.polygonCorners = polygonCorners
        self.flattenedAttributeShortIdentifiers = flattenedAttributeShortIdentifiers
        self.classificationConfidence = classificationConfidence
    }
}

/// Object mobility is deliberately conservative. The iOS adapter can map a
/// known fixture-like category to fixed/movable, but unknown remains honest.
public enum RoomPlanSemanticObjectMobility: String, Codable, Sendable, Equatable {
    case fixed
    case movable
    case unknown

    fileprivate var semanticMobility: RoomMobilityAssessment {
        switch self {
        case .fixed:
            return .fixed
        case .movable:
            return .movable
        case .unknown:
            return .unknown
        }
    }
}

/// Foundation-only representation of a RoomPlan object. It stays separate from
/// surfaces so a fixed object never becomes a claimed structural surface.
public struct RoomPlanSemanticObjectDescriptor: Codable, Sendable, Equatable {
    public var sourceIdentifier: String
    public var parentSourceIdentifier: String?
    public var kind: String
    public var label: String
    public var dimensionsMeters: RoomDimensions
    public var transform: RoomTransform4x4
    public var polygonCorners: [RoomPoint3D]
    public var flattenedAttributeShortIdentifiers: [String]
    public var classificationConfidence: RoomClassificationConfidence
    public var mobility: RoomPlanSemanticObjectMobility

    public init(
        sourceIdentifier: String,
        parentSourceIdentifier: String? = nil,
        kind: String,
        label: String,
        dimensionsMeters: RoomDimensions,
        transform: RoomTransform4x4,
        polygonCorners: [RoomPoint3D] = [],
        flattenedAttributeShortIdentifiers: [String] = [],
        classificationConfidence: RoomClassificationConfidence = .unknown,
        mobility: RoomPlanSemanticObjectMobility = .unknown
    ) {
        self.sourceIdentifier = sourceIdentifier
        self.parentSourceIdentifier = parentSourceIdentifier
        self.kind = kind
        self.label = label
        self.dimensionsMeters = dimensionsMeters
        self.transform = transform
        self.polygonCorners = polygonCorners
        self.flattenedAttributeShortIdentifiers = flattenedAttributeShortIdentifiers
        self.classificationConfidence = classificationConfidence
        self.mobility = mobility
    }
}

public enum RoomPlanSemanticMappingError: Error, Sendable, Equatable {
    case invalidAttemptIdentifier
    case invalidCoordinateSpaceEpochIdentifier
    case invalidDescriptor(String)
    case invalidSpatialValue(String)
}

/// Converts app-owned descriptors into a RoomPlan-provenanced normalized
/// snapshot. It deliberately does not expose RoomPlan's framework UUIDs as
/// durable app IDs or claim that confidence is geometric accuracy.
public enum RoomPlanSemanticMapper {
    public static func makeSnapshot(
        projectID: String,
        revisionID: String,
        attempt: RoomCaptureAttemptToken,
        coordinateSpaceEpochID: String,
        surfaces: [RoomPlanSemanticSurfaceDescriptor],
        objects: [RoomPlanSemanticObjectDescriptor]
    ) throws -> RoomSemanticSnapshot {
        guard RoomPathValidation.isSafeStableIdentifier(attempt.value) else {
            throw RoomPlanSemanticMappingError.invalidAttemptIdentifier
        }
        guard RoomPathValidation.isSafeStableIdentifier(coordinateSpaceEpochID) else {
            throw RoomPlanSemanticMappingError.invalidCoordinateSpaceEpochIdentifier
        }

        let structuralElements = try surfaces.map {
            try makeSurface(
                $0,
                attempt: attempt,
                coordinateSpaceEpochID: coordinateSpaceEpochID
            )
        }
        let objectElements = try objects.map {
            try makeObject(
                $0,
                attempt: attempt,
                coordinateSpaceEpochID: coordinateSpaceEpochID
            )
        }
        return RoomSemanticSnapshot(
            projectID: projectID,
            revisionID: revisionID,
            units: "meters",
            accuracyDisclaimer: RoomCaptureState.nonSurveyAccuracyDisclaimer,
            structuralElements: structuralElements,
            objectElements: objectElements
        )
    }

    private static func makeSurface(
        _ descriptor: RoomPlanSemanticSurfaceDescriptor,
        attempt: RoomCaptureAttemptToken,
        coordinateSpaceEpochID: String
    ) throws -> RoomSemanticElement {
        try validate(
            sourceIdentifier: descriptor.sourceIdentifier,
            kind: descriptor.kind,
            label: descriptor.label,
            dimensions: descriptor.dimensionsMeters,
            transform: descriptor.transform,
            polygonCorners: descriptor.polygonCorners,
            requiresThreePositiveDimensions: false
        )
        return makeElement(
            scope: "surface",
            sourceIdentifier: descriptor.sourceIdentifier,
            parentSourceIdentifier: descriptor.parentSourceIdentifier,
            kind: descriptor.kind,
            label: descriptor.label,
            dimensions: descriptor.dimensionsMeters,
            transform: descriptor.transform,
            polygonCorners: descriptor.polygonCorners,
            flattenedAttributeShortIdentifiers: descriptor.flattenedAttributeShortIdentifiers,
            classificationConfidence: descriptor.classificationConfidence,
            mobility: .structural,
            attempt: attempt,
            coordinateSpaceEpochID: coordinateSpaceEpochID
        )
    }

    private static func makeObject(
        _ descriptor: RoomPlanSemanticObjectDescriptor,
        attempt: RoomCaptureAttemptToken,
        coordinateSpaceEpochID: String
    ) throws -> RoomSemanticElement {
        try validate(
            sourceIdentifier: descriptor.sourceIdentifier,
            kind: descriptor.kind,
            label: descriptor.label,
            dimensions: descriptor.dimensionsMeters,
            transform: descriptor.transform,
            polygonCorners: descriptor.polygonCorners,
            requiresThreePositiveDimensions: true
        )
        return makeElement(
            scope: "object",
            sourceIdentifier: descriptor.sourceIdentifier,
            parentSourceIdentifier: descriptor.parentSourceIdentifier,
            kind: descriptor.kind,
            label: descriptor.label,
            dimensions: descriptor.dimensionsMeters,
            transform: descriptor.transform,
            polygonCorners: descriptor.polygonCorners,
            flattenedAttributeShortIdentifiers: descriptor.flattenedAttributeShortIdentifiers,
            classificationConfidence: descriptor.classificationConfidence,
            mobility: descriptor.mobility.semanticMobility,
            attempt: attempt,
            coordinateSpaceEpochID: coordinateSpaceEpochID
        )
    }

    private static func makeElement(
        scope: String,
        sourceIdentifier: String,
        parentSourceIdentifier: String?,
        kind: String,
        label: String,
        dimensions: RoomDimensions,
        transform: RoomTransform4x4,
        polygonCorners: [RoomPoint3D],
        flattenedAttributeShortIdentifiers: [String],
        classificationConfidence: RoomClassificationConfidence,
        mobility: RoomMobilityAssessment,
        attempt: RoomCaptureAttemptToken,
        coordinateSpaceEpochID: String
    ) -> RoomSemanticElement {
        RoomSemanticElement(
            id: stableAppIdentifier(
                scope: scope,
                sourceIdentifier: sourceIdentifier,
                attempt: attempt
            ),
            kind: kind,
            label: label,
            dimensionsMeters: dimensions,
            transform: transform,
            polygonCorners: polygonCorners.isEmpty ? nil : polygonCorners,
            provenance: RoomElementProvenance(
                framework: "RoomPlan",
                sourceIdentifier: sourceIdentifier,
                parentSourceIdentifier: parentSourceIdentifier,
                classificationConfidence: classificationConfidence,
                flattenedAttributeIdentifiers: flattenedAttributeShortIdentifiers
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .reduce(into: [String]()) { result, identifier in
                        if !result.contains(identifier) {
                            result.append(identifier)
                        }
                    },
                captureAttemptID: attempt.value,
                coordinateSpaceEpochID: coordinateSpaceEpochID
            ),
            mobility: mobility,
            origin: .roomPlan
        )
    }

    private static func validate(
        sourceIdentifier: String,
        kind: String,
        label: String,
        dimensions: RoomDimensions,
        transform: RoomTransform4x4,
        polygonCorners: [RoomPoint3D],
        requiresThreePositiveDimensions: Bool
    ) throws {
        guard !sourceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw RoomPlanSemanticMappingError.invalidDescriptor(
                "RoomPlan descriptors require source identifiers, kinds, and labels."
            )
        }
        let values = [dimensions.width, dimensions.height, dimensions.depth]
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw RoomPlanSemanticMappingError.invalidSpatialValue(
                "RoomPlan dimensions must be finite and nonnegative."
            )
        }
        if requiresThreePositiveDimensions {
            guard values.allSatisfy({ $0 > 0 }) else {
                throw RoomPlanSemanticMappingError.invalidSpatialValue(
                    "RoomPlan object dimensions require three positive values."
                )
            }
        } else {
            guard values.filter({ $0 > 0 }).count >= 2 else {
                throw RoomPlanSemanticMappingError.invalidSpatialValue(
                    "RoomPlan surfaces require at least two positive dimensions."
                )
            }
        }
        guard transform.isValid else {
            throw RoomPlanSemanticMappingError.invalidSpatialValue(
                "RoomPlan transforms require 16 finite column-major values."
            )
        }
        guard polygonCorners.allSatisfy(\.isFinite) else {
            throw RoomPlanSemanticMappingError.invalidSpatialValue(
                "RoomPlan polygon corners must be finite."
            )
        }
    }

    private static func stableAppIdentifier(
        scope: String,
        sourceIdentifier: String,
        attempt: RoomCaptureAttemptToken
    ) -> String {
        let seed = "roomplan|\(scope)|\(attempt.value)|\(sourceIdentifier)"
        let digest = RoomSHA256.hexDigest(of: Data(seed.utf8))
        return "roomplan-\(scope)-\(digest.prefix(24))"
    }
}
