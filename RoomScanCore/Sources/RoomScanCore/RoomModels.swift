import Foundation

public enum RoomDraftDecision: String, Codable, Sendable, Equatable {
    case save
    case discard
}

public enum RoomRevisionReason: String, Codable, Sendable, Equatable {
    case initial
    case edit
    case rescan
    case revert
    case duplicate
}

public enum RoomProjectStoreError: Error, Sendable, Equatable {
    case invalidIdentifier(String)
    case invalidRelativePath(String)
    case symbolicLinkDetected(String)
    case invalidAssetSource(String)
    case duplicateAssetDestination(String)
    case assetReferenceNotStaged(String)
    case projectAlreadyExists(String)
    case projectNotFound(String)
    case revisionNotFound(projectID: String, revisionID: String)
    case duplicateRevisionID(String)
    case revisionAlreadyExists(String)
    case invalidRevisionReason(
        reason: RoomRevisionReason,
        restoredFromRevisionID: String?
    )
    case duplicateSemanticElementID(String)
    case duplicateAnnotationID(String)
    case duplicateMeasurementID(String)
    case duplicatePhotoID(String)
    case invalidSpatialValue(String)
    case invalidEvidencePlan(String)
    case invalidRescanProposal(String)
    case parentDoesNotMatchHead(projectID: String, expected: String, actual: String?)
    case invalidPackage(String)
    case injectedFailure(RoomProjectStoreFaultPoint)
    case storageFailure(String)
}

public enum RoomAssetScope: String, Codable, Sendable, Equatable, Hashable {
    case project
    case revision
}

/// File-backed input only. The source URL is never persisted into a room package.
public struct RoomAssetInput: Sendable, Equatable {
    public let sourceURL: URL
    public let destination: RoomRelativePath
    public let scope: RoomAssetScope

    public init(
        sourceURL: URL,
        destination: RoomRelativePath,
        scope: RoomAssetScope
    ) {
        self.sourceURL = sourceURL
        self.destination = destination
        self.scope = scope
    }
}

public struct RoomRelativePath: Codable, Sendable, Equatable, Hashable {
    public let value: String

    public init(_ value: String) throws {
        guard RoomPathValidation.isSafeRelativePath(value) else {
            throw RoomProjectStoreError.invalidRelativePath(value)
        }
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct RoomGPSLocation: Codable, Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var horizontalAccuracyMeters: Double
    public var capturedAt: Date

    public init(
        latitude: Double,
        longitude: Double,
        horizontalAccuracyMeters: Double,
        capturedAt: Date
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.capturedAt = capturedAt
    }
}

/// A Foundation-only spatial point. The store validates finiteness before a
/// value is committed so untrusted decoded data cannot become durable truth.
public struct RoomPoint3D: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public var isFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}

/// A column-major 4x4 transform. Construction stays permissive so the store
/// can fail closed for malformed decoded/scratch input before any write.
public struct RoomTransform4x4: Codable, Sendable, Equatable {
    public var columnMajorValues: [Double]

    public init(columnMajorValues: [Double]) {
        self.columnMajorValues = columnMajorValues
    }

    public var isValid: Bool {
        columnMajorValues.count == 16 && columnMajorValues.allSatisfy { $0.isFinite }
    }
}

public enum RoomClassificationConfidence: String, Codable, Sendable, Equatable {
    case low
    case medium
    case high
    case unknown
}

/// Framework-origin metadata is descriptive provenance only. It is never
/// treated as stable cross-session identity or geometric-accuracy proof.
public struct RoomElementProvenance: Codable, Sendable, Equatable {
    public var framework: String
    public var sourceIdentifier: String
    public var parentSourceIdentifier: String?
    public var classificationConfidence: RoomClassificationConfidence
    public var flattenedAttributeIdentifiers: [String]
    /// Optional app-owned capture provenance. These strings are not framework
    /// IDs and never imply cross-session stability or geometric accuracy.
    public var captureAttemptID: String?
    public var coordinateSpaceEpochID: String?

    public init(
        framework: String,
        sourceIdentifier: String,
        parentSourceIdentifier: String? = nil,
        classificationConfidence: RoomClassificationConfidence = .unknown,
        flattenedAttributeIdentifiers: [String] = [],
        captureAttemptID: String? = nil,
        coordinateSpaceEpochID: String? = nil
    ) {
        self.framework = framework
        self.sourceIdentifier = sourceIdentifier
        self.parentSourceIdentifier = parentSourceIdentifier
        self.classificationConfidence = classificationConfidence
        self.flattenedAttributeIdentifiers = flattenedAttributeIdentifiers
        self.captureAttemptID = captureAttemptID
        self.coordinateSpaceEpochID = coordinateSpaceEpochID
    }
}

public enum RoomMobilityAssessment: String, Codable, Sendable, Equatable {
    case structural
    case fixed
    case movable
    case unknown
}

/// Declares how a semantic element entered the normalized snapshot. It is
/// intentionally distinct from mobility: a manually entered fixed object and
/// a RoomPlan-classified fixed object remain distinguishable provenance.
public enum RoomElementOrigin: String, Codable, Sendable, Equatable {
    case roomPlan
    case manual
    case deterministicFixture
    case legacyUnknown
}

public struct RoomMetadata: Codable, Sendable, Equatable {
    public var projectID: String
    public var customName: String
    public var captureDate: Date
    public var lastRevisedDate: Date
    public var manualLocation: String
    public var optionalGPS: RoomGPSLocation?
    public var notes: String
    public var tags: [String]
    public var thumbnailRelativePath: RoomRelativePath?
    public var archived: Bool

    public init(
        projectID: String,
        customName: String,
        captureDate: Date,
        lastRevisedDate: Date,
        manualLocation: String,
        optionalGPS: RoomGPSLocation?,
        notes: String,
        tags: [String],
        thumbnailRelativePath: RoomRelativePath?,
        archived: Bool
    ) {
        self.projectID = projectID
        self.customName = customName
        self.captureDate = captureDate
        self.lastRevisedDate = lastRevisedDate
        self.manualLocation = manualLocation
        self.optionalGPS = optionalGPS
        self.notes = notes
        self.tags = tags
        self.thumbnailRelativePath = thumbnailRelativePath
        self.archived = archived
    }

    private enum CodingKeys: String, CodingKey {
        case projectID
        case customName
        case roomName
        case captureDate
        case lastRevisedDate
        case manualLocation
        case optionalGPS
        case notes
        case tags
        case thumbnailRelativePath
        case archived
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try container.decode(String.self, forKey: .projectID)
        if let encodedName = try container.decodeIfPresent(String.self, forKey: .customName) {
            customName = encodedName
        } else {
            customName = try container.decode(String.self, forKey: .roomName)
        }
        captureDate = try container.decode(Date.self, forKey: .captureDate)
        lastRevisedDate = try container.decode(Date.self, forKey: .lastRevisedDate)
        manualLocation = try container.decode(String.self, forKey: .manualLocation)
        optionalGPS = try container.decodeIfPresent(RoomGPSLocation.self, forKey: .optionalGPS)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        thumbnailRelativePath = try container.decodeIfPresent(RoomRelativePath.self, forKey: .thumbnailRelativePath)
        archived = try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(projectID, forKey: .projectID)
        try container.encode(customName, forKey: .customName)
        try container.encode(captureDate, forKey: .captureDate)
        try container.encode(lastRevisedDate, forKey: .lastRevisedDate)
        try container.encode(manualLocation, forKey: .manualLocation)
        try container.encodeIfPresent(optionalGPS, forKey: .optionalGPS)
        try container.encode(notes, forKey: .notes)
        try container.encode(tags, forKey: .tags)
        try container.encodeIfPresent(thumbnailRelativePath, forKey: .thumbnailRelativePath)
        try container.encode(archived, forKey: .archived)
    }
}

/// Project-root-relative persisted artifact references. A non-nil path is
/// authoritative only when it resolves to a contained, regular package file.
public struct RoomAssetPolicy: Codable, Sendable, Equatable {
    public var nativeUSDZ: RoomRelativePath?
    public var rawMesh: RoomRelativePath?
    public var worldMap: RoomRelativePath?

    public init(
        nativeUSDZ: RoomRelativePath? = nil,
        rawMesh: RoomRelativePath? = nil,
        worldMap: RoomRelativePath? = nil
    ) {
        self.nativeUSDZ = nativeUSDZ
        self.rawMesh = rawMesh
        self.worldMap = worldMap
    }
}

/// Package schema versions are intentionally explicit: v1 remains readable as
/// a historical package format, while every package newly written by this store
/// is v2.
public enum RoomProjectSchemaVersion: String, Codable, Sendable, Equatable {
    case v1 = "room-scan-project-v1"
    case v2 = "room-scan-project-v2"
}

public struct RoomProjectManifest: Codable, Sendable, Equatable {
    public var schemaVersion: String
    public var projectID: String
    public var headRevisionID: String
    public var revisionIDs: [String]
    public var createdAt: Date
    public var updatedAt: Date?
    public var assetPolicy: RoomAssetPolicy?

    public init(
        schemaVersion: String = RoomProjectSchemaVersion.v2.rawValue,
        projectID: String,
        headRevisionID: String,
        revisionIDs: [String],
        createdAt: Date,
        updatedAt: Date?,
        assetPolicy: RoomAssetPolicy? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.projectID = projectID
        self.headRevisionID = headRevisionID
        self.revisionIDs = revisionIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.assetPolicy = assetPolicy
    }
}

/// An absent value is reserved for a decoded historical v1 revision. New
/// revisions write an explicit mode, so a plan-less evidence tree cannot become
/// permissible merely because a modern revision document omitted a field.
public enum RoomRevisionEvidenceCompatibility: String, Codable, Sendable, Equatable {
    case strict
    case legacyV1Planless
}

public struct RoomRevisionManifest: Codable, Sendable, Equatable {
    public var revisionID: String
    public var projectID: String
    public var parentRevisionID: String?
    public var reason: RoomRevisionReason
    public var createdAt: Date
    public var immutable: Bool
    public var restoredFromRevisionID: String?
    public var captureEvidence: RoomRevisionEvidencePlan?
    public var evidenceCompatibility: RoomRevisionEvidenceCompatibility?
    /// Optional for backward decoding. When present, the report is immutable,
    /// revision-bound capture provenance rather than editable project metadata.
    public var qualityReport: RoomQualityReport?

    public init(
        revisionID: String,
        projectID: String,
        parentRevisionID: String?,
        reason: RoomRevisionReason,
        createdAt: Date,
        immutable: Bool = true,
        restoredFromRevisionID: String? = nil,
        captureEvidence: RoomRevisionEvidencePlan? = nil,
        evidenceCompatibility: RoomRevisionEvidenceCompatibility? = .strict,
        qualityReport: RoomQualityReport? = nil
    ) {
        self.revisionID = revisionID
        self.projectID = projectID
        self.parentRevisionID = parentRevisionID
        self.reason = reason
        self.createdAt = createdAt
        self.immutable = immutable
        self.restoredFromRevisionID = restoredFromRevisionID
        self.captureEvidence = captureEvidence
        self.evidenceCompatibility = evidenceCompatibility
        self.qualityReport = qualityReport
    }

    private enum CodingKeys: String, CodingKey {
        case revisionID
        case projectID
        case parentRevisionID
        case reason
        case createdAt
        case immutable
        case restoredFromRevisionID
        case captureEvidence
        case evidenceCompatibility
        case qualityReport
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revisionID = try container.decode(String.self, forKey: .revisionID)
        projectID = try container.decode(String.self, forKey: .projectID)
        parentRevisionID = try container.decodeIfPresent(String.self, forKey: .parentRevisionID)
        reason = try container.decodeIfPresent(RoomRevisionReason.self, forKey: .reason) ?? .initial
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        immutable = try container.decodeIfPresent(Bool.self, forKey: .immutable) ?? true
        restoredFromRevisionID = try container.decodeIfPresent(String.self, forKey: .restoredFromRevisionID)
        captureEvidence = try container.decodeIfPresent(RoomRevisionEvidencePlan.self, forKey: .captureEvidence)
        evidenceCompatibility = try container.decodeIfPresent(
            RoomRevisionEvidenceCompatibility.self,
            forKey: .evidenceCompatibility
        )
        qualityReport = try container.decodeIfPresent(RoomQualityReport.self, forKey: .qualityReport)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(revisionID, forKey: .revisionID)
        try container.encode(projectID, forKey: .projectID)
        try container.encodeIfPresent(parentRevisionID, forKey: .parentRevisionID)
        try container.encode(reason, forKey: .reason)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(immutable, forKey: .immutable)
        try container.encodeIfPresent(restoredFromRevisionID, forKey: .restoredFromRevisionID)
        try container.encodeIfPresent(captureEvidence, forKey: .captureEvidence)
        try container.encodeIfPresent(evidenceCompatibility, forKey: .evidenceCompatibility)
        try container.encodeIfPresent(qualityReport, forKey: .qualityReport)
    }
}

public enum RoomCaptureEvidenceSource: String, Codable, Sendable, Equatable {
    case roomPlan
    case deterministicFixture
}

public enum RoomEvidenceArtifactKind: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case capturedRoomDataJSON
    case capturedRoomJSON
    case nativeUSDZ
    case rawMesh
    case worldMap
    case provenance
}

public enum RoomEvidenceArtifactStatus: String, Codable, Sendable, Equatable {
    case present
    case unavailable
    case notRequested
}

/// Per-revision immutable evidence declaration. File bytes remain in the
/// revision directory; this plan only declares their contract and omissions.
public struct RoomEvidenceArtifact: Codable, Sendable, Equatable {
    public var kind: RoomEvidenceArtifactKind
    public var status: RoomEvidenceArtifactStatus
    public var relativePath: RoomRelativePath?
    public var byteCount: Int?
    public var mediaType: String?
    public var omissionReason: String?
    /// Lowercase SHA-256 of the declared file bytes. Present evidence requires
    /// this value; omission states deliberately carry no digest.
    public var sha256Hex: String?

    public init(
        kind: RoomEvidenceArtifactKind,
        status: RoomEvidenceArtifactStatus,
        relativePath: RoomRelativePath?,
        byteCount: Int?,
        mediaType: String?,
        omissionReason: String?,
        sha256Hex: String? = nil
    ) {
        self.kind = kind
        self.status = status
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.mediaType = mediaType
        self.omissionReason = omissionReason
        self.sha256Hex = sha256Hex
    }
}

public struct RoomRevisionEvidencePlan: Codable, Sendable, Equatable {
    public var source: RoomCaptureEvidenceSource
    public var artifacts: [RoomEvidenceArtifact]
    /// App-owned values that identify one capture attempt and the coordinate
    /// space in which its RoomPlan evidence was produced. They are optional for
    /// legacy and deterministic-fixture revisions.
    public var captureAttemptID: String?
    public var coordinateSpaceEpochID: String?

    public init(
        source: RoomCaptureEvidenceSource,
        artifacts: [RoomEvidenceArtifact],
        captureAttemptID: String? = nil,
        coordinateSpaceEpochID: String? = nil
    ) {
        self.source = source
        self.artifacts = artifacts
        self.captureAttemptID = captureAttemptID
        self.coordinateSpaceEpochID = coordinateSpaceEpochID
    }
}

public struct RoomDimensions: Codable, Sendable, Equatable {
    public var width: Double
    public var height: Double
    public var depth: Double

    public init(width: Double, height: Double, depth: Double) {
        self.width = width
        self.height = height
        self.depth = depth
    }
}

public struct RoomSemanticElement: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: String
    public var label: String
    public var dimensionsMeters: RoomDimensions
    public var transform: RoomTransform4x4?
    public var polygonCorners: [RoomPoint3D]?
    public var provenance: RoomElementProvenance?
    public var mobility: RoomMobilityAssessment?
    /// Absent in pre-Phase-2 documents. RoomPlan-evidence revisions validate
    /// this explicitly; legacy/no-plan packages preserve a missing value.
    public var origin: RoomElementOrigin?

    public init(
        id: String,
        kind: String,
        label: String,
        dimensionsMeters: RoomDimensions,
        transform: RoomTransform4x4? = nil,
        polygonCorners: [RoomPoint3D]? = nil,
        provenance: RoomElementProvenance? = nil,
        mobility: RoomMobilityAssessment? = nil,
        origin: RoomElementOrigin? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.dimensionsMeters = dimensionsMeters
        self.transform = transform
        self.polygonCorners = polygonCorners
        self.provenance = provenance
        self.mobility = mobility
        self.origin = origin
    }
}

public struct RoomSemanticSnapshot: Codable, Sendable, Equatable {
    public var projectID: String
    public var revisionID: String
    public var units: String
    public var accuracyDisclaimer: String
    public var structuralElements: [RoomSemanticElement]
    /// Canonical JSON key for detected or app-authored objects. It intentionally
    /// does not assert that a fixed or unknown object is structurally part of a
    /// room surface.
    public var objectElements: [RoomSemanticElement]

    /// Source-compatible accessor for Phase-1 callers and fixture JSON. New
    /// encodes use `objectElements`; decoding accepts this old key.
    public var movableElements: [RoomSemanticElement] {
        get { objectElements }
        set { objectElements = newValue }
    }

    public init(
        projectID: String,
        revisionID: String,
        units: String,
        accuracyDisclaimer: String,
        structuralElements: [RoomSemanticElement],
        objectElements: [RoomSemanticElement]
    ) {
        self.projectID = projectID
        self.revisionID = revisionID
        self.units = units
        self.accuracyDisclaimer = accuracyDisclaimer
        self.structuralElements = structuralElements
        self.objectElements = objectElements
    }

    public init(
        projectID: String,
        revisionID: String,
        units: String,
        accuracyDisclaimer: String,
        structuralElements: [RoomSemanticElement],
        movableElements: [RoomSemanticElement]
    ) {
        self.init(
            projectID: projectID,
            revisionID: revisionID,
            units: units,
            accuracyDisclaimer: accuracyDisclaimer,
            structuralElements: structuralElements,
            objectElements: movableElements
        )
    }

    private enum CodingKeys: String, CodingKey {
        case projectID
        case revisionID
        case units
        case accuracyDisclaimer
        case structuralElements
        case objectElements
        case movableElements
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try container.decode(String.self, forKey: .projectID)
        revisionID = try container.decode(String.self, forKey: .revisionID)
        units = try container.decode(String.self, forKey: .units)
        accuracyDisclaimer = try container.decode(String.self, forKey: .accuracyDisclaimer)
        structuralElements = try container.decodeIfPresent(
            [RoomSemanticElement].self,
            forKey: .structuralElements
        ) ?? []
        if let canonicalObjects = try container.decodeIfPresent(
            [RoomSemanticElement].self,
            forKey: .objectElements
        ) {
            objectElements = canonicalObjects
        } else {
            objectElements = try container.decodeIfPresent(
                [RoomSemanticElement].self,
                forKey: .movableElements
            ) ?? []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(projectID, forKey: .projectID)
        try container.encode(revisionID, forKey: .revisionID)
        try container.encode(units, forKey: .units)
        try container.encode(accuracyDisclaimer, forKey: .accuracyDisclaimer)
        try container.encode(structuralElements, forKey: .structuralElements)
        try container.encode(objectElements, forKey: .objectElements)
    }
}

public struct RoomAnnotation: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var createdAt: Date
    public var text: String
    /// Optional room-coordinate pin. Historical note documents intentionally
    /// decode without it.
    public var point: RoomPoint3D?
    /// Optional semantic attachment. The store validates that it references a
    /// live element in the same immutable payload before committing.
    public var attachedElementID: String?

    public init(
        id: String,
        createdAt: Date,
        text: String,
        point: RoomPoint3D? = nil,
        attachedElementID: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.point = point
        self.attachedElementID = attachedElementID
    }
}

public struct RoomMeasurement: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var valueMeters: Double
    /// Point-to-point measurements carry both endpoints. Scalar-only legacy
    /// measurements remain readable with both values absent.
    public var startPoint: RoomPoint3D?
    public var endPoint: RoomPoint3D?

    public init(
        id: String,
        label: String,
        valueMeters: Double,
        startPoint: RoomPoint3D? = nil,
        endPoint: RoomPoint3D? = nil
    ) {
        self.id = id
        self.label = label
        self.valueMeters = valueMeters
        self.startPoint = startPoint
        self.endPoint = endPoint
    }
}

public struct RoomPhoto: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var createdAt: Date
    public var assetRelativePath: RoomRelativePath
    public var caption: String
    public var cameraTransform: RoomTransform4x4?

    public init(
        id: String,
        createdAt: Date,
        assetRelativePath: RoomRelativePath,
        caption: String,
        cameraTransform: RoomTransform4x4? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.assetRelativePath = assetRelativePath
        self.caption = caption
        self.cameraTransform = cameraTransform
    }
}

public struct RoomRevisionPayload: Codable, Sendable, Equatable {
    public var semanticSnapshot: RoomSemanticSnapshot
    public var annotations: [RoomAnnotation]
    public var measurements: [RoomMeasurement]
    public var photos: [RoomPhoto]

    public init(
        semanticSnapshot: RoomSemanticSnapshot,
        annotations: [RoomAnnotation],
        measurements: [RoomMeasurement],
        photos: [RoomPhoto]
    ) {
        self.semanticSnapshot = semanticSnapshot
        self.annotations = annotations
        self.measurements = measurements
        self.photos = photos
    }
}

public struct RoomAnnotationsDocument: Codable, Sendable, Equatable {
    public var projectID: String
    public var revisionID: String
    public var annotations: [RoomAnnotation]

    public init(projectID: String, revisionID: String, annotations: [RoomAnnotation]) {
        self.projectID = projectID
        self.revisionID = revisionID
        self.annotations = annotations
    }
}

public struct RoomMeasurementsDocument: Codable, Sendable, Equatable {
    public var projectID: String
    public var revisionID: String
    public var accuracyDisclaimer: String
    public var measurements: [RoomMeasurement]

    public init(
        projectID: String,
        revisionID: String,
        accuracyDisclaimer: String,
        measurements: [RoomMeasurement]
    ) {
        self.projectID = projectID
        self.revisionID = revisionID
        self.accuracyDisclaimer = accuracyDisclaimer
        self.measurements = measurements
    }
}

public struct RoomPhotosDocument: Codable, Sendable, Equatable {
    public var projectID: String
    public var revisionID: String
    public var photos: [RoomPhoto]

    public init(projectID: String, revisionID: String, photos: [RoomPhoto]) {
        self.projectID = projectID
        self.revisionID = revisionID
        self.photos = photos
    }
}

public struct RoomRevisionPackage: Codable, Sendable, Equatable {
    public var manifest: RoomRevisionManifest
    public var payload: RoomRevisionPayload

    public init(manifest: RoomRevisionManifest, payload: RoomRevisionPayload) {
        self.manifest = manifest
        self.payload = payload
    }
}

public struct RoomProjectPackage: Codable, Sendable, Equatable {
    public var manifest: RoomProjectManifest
    public var metadata: RoomMetadata
    public var revisions: [RoomRevisionPackage]

    public init(
        manifest: RoomProjectManifest,
        metadata: RoomMetadata,
        revisions: [RoomRevisionPackage]
    ) {
        self.manifest = manifest
        self.metadata = metadata
        self.revisions = revisions
    }

    /// The canonical library/display freshness. An append changes the manifest
    /// head timestamp without requiring a second metadata write.
    public var effectiveLastRevisedDate: Date {
        max(
            metadata.lastRevisedDate,
            manifest.updatedAt ?? metadata.lastRevisedDate
        )
    }
}

public struct RoomProjectSummary: Codable, Sendable, Equatable, Identifiable {
    public var projectID: String
    public var customName: String
    public var captureDate: Date
    public var lastRevisedDate: Date
    public var manualLocation: String
    public var tags: [String]
    public var thumbnailRelativePath: RoomRelativePath?
    public var archived: Bool
    public var headRevisionID: String

    public var id: String {
        projectID
    }

    public init(
        projectID: String,
        customName: String,
        captureDate: Date,
        lastRevisedDate: Date,
        manualLocation: String,
        tags: [String],
        thumbnailRelativePath: RoomRelativePath?,
        archived: Bool,
        headRevisionID: String
    ) {
        self.projectID = projectID
        self.customName = customName
        self.captureDate = captureDate
        self.lastRevisedDate = lastRevisedDate
        self.manualLocation = manualLocation
        self.tags = tags
        self.thumbnailRelativePath = thumbnailRelativePath
        self.archived = archived
        self.headRevisionID = headRevisionID
    }
}

public enum RoomProjectListingIssueKind: String, Codable, Sendable, Equatable {
    case corruptPackage
    case symbolicLink
}

/// A best-effort library enumeration. Invalid sibling packages are isolated so
/// valid authoritative packages remain visible to the caller.
public struct RoomProjectListingIssue: Codable, Sendable, Equatable, Identifiable {
    public var projectID: String
    public var kind: RoomProjectListingIssueKind
    public var message: String

    public var id: String {
        projectID
    }

    public init(
        projectID: String,
        kind: RoomProjectListingIssueKind,
        message: String
    ) {
        self.projectID = projectID
        self.kind = kind
        self.message = message
    }
}

public struct RoomProjectListing: Codable, Sendable, Equatable {
    public var summaries: [RoomProjectSummary]
    public var issues: [RoomProjectListingIssue]

    public init(
        summaries: [RoomProjectSummary],
        issues: [RoomProjectListingIssue]
    ) {
        self.summaries = summaries
        self.issues = issues
    }
}

public struct RoomDraft: Codable, Sendable, Equatable {
    public var metadata: RoomMetadata
    public var revision: RoomRevisionPayload

    public init(metadata: RoomMetadata, revision: RoomRevisionPayload) {
        self.metadata = metadata
        self.revision = revision
    }
}

/// Scratch-only initial capture input. Its source URLs are copied into a new
/// staged package only when the caller explicitly chooses `.save`.
public struct RoomInitialCaptureCommit: Sendable, Equatable {
    public var draft: RoomDraft
    public var evidence: RoomRevisionEvidencePlan?
    public var assets: [RoomAssetInput]
    /// Unbound analysis is accepted at the scratch boundary. Only the store,
    /// after allocating a fresh immutable revision ID, may bind and persist it.
    public var qualityAssessment: RoomQualityAssessment?
    public var qualityAcknowledgement: RoomQualitySaveAnywayAcknowledgementRequest?

    public init(
        draft: RoomDraft,
        evidence: RoomRevisionEvidencePlan? = nil,
        assets: [RoomAssetInput] = [],
        qualityAssessment: RoomQualityAssessment? = nil,
        qualityAcknowledgement: RoomQualitySaveAnywayAcknowledgementRequest? = nil
    ) {
        self.draft = draft
        self.evidence = evidence
        self.assets = assets
        self.qualityAssessment = qualityAssessment
        self.qualityAcknowledgement = qualityAcknowledgement
    }
}

public enum RoomJSONCoding {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum RoomPathValidation {
    private static let allowedIdentifierScalars = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )

    static func isSafeStableIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128 else {
            return false
        }

        return value.unicodeScalars.allSatisfy(allowedIdentifierScalars.contains)
    }

    static func isSafeRelativePath(_ value: String) -> Bool {
        guard
            !value.isEmpty,
            !value.hasPrefix("/"),
            !value.hasPrefix("\\"),
            !value.contains("\\"),
            !value.contains(":")
        else {
            return false
        }

        let components = value.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }
}
