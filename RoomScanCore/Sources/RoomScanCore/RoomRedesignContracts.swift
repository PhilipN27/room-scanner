import Foundation

/// The only schema versions accepted by the Slice 0 interchange boundary.
///
/// The local package remains the capture authority. These contracts describe
/// additive metadata and explicitly selected derivatives; they never provide a
/// route for a hosted service to rewrite a captured room revision.
public enum RoomRedesignContractKind: String, Codable, Sendable, Equatable, CaseIterable {
    case localRedesignExtension
    case hostedAPIResource
    case aiRoomPackage
    case workingProjectSync
    case portalSnapshot

    public var supportedSchemaVersion: String {
        switch self {
        case .localRedesignExtension:
            return "roomscan-local-redesign-extension-v1"
        case .hostedAPIResource:
            return "roomscan-hosted-api-resource-v1"
        case .aiRoomPackage:
            return "roomscan-ai-room-package-v1"
        case .workingProjectSync:
            return "roomscan-working-project-sync-v1"
        case .portalSnapshot:
            return "roomscan-portal-snapshot-v1"
        }
    }
}

/// A fully decoded v1 contract. Consumers of untrusted JSON must use
/// `RoomRedesignContractValidator` rather than decoding individual models
/// directly so unknown keys and cross-kind documents fail closed.
public enum RoomRedesignContractDocument: Sendable, Equatable {
    case localRedesignExtension(RoomLocalRedesignExtension)
    case localRedesignExtensionV2(RoomLocalRedesignExtensionV2)
    case hostedAPIResource(RoomHostedAPIResource)
    case aiRoomPackage(RoomAIRoomPackage)
    case workingProjectSync(RoomWorkingProjectSync)
    case portalSnapshot(RoomPortalSnapshot)

    public var kind: RoomRedesignContractKind {
        switch self {
        case .localRedesignExtension, .localRedesignExtensionV2:
            return .localRedesignExtension
        case .hostedAPIResource:
            return .hostedAPIResource
        case .aiRoomPackage:
            return .aiRoomPackage
        case .workingProjectSync:
            return .workingProjectSync
        case .portalSnapshot:
            return .portalSnapshot
        }
    }

    public var schemaVersion: String {
        switch self {
        case let .localRedesignExtension(value):
            return value.schemaVersion
        case let .localRedesignExtensionV2(value):
            return value.schemaVersion
        case let .hostedAPIResource(value):
            return value.schemaVersion
        case let .aiRoomPackage(value):
            return value.schemaVersion
        case let .workingProjectSync(value):
            return value.schemaVersion
        case let .portalSnapshot(value):
            return value.schemaVersion
        }
    }
}

public enum RoomRedesignContractValidationError: Error, Sendable, Equatable {
    case invalidJSON
    case rootMustBeObject
    case duplicateKey(path: String, key: String)
    case missingKey(path: String, key: String)
    case unknownKey(path: String, key: String)
    case invalidType(path: String)
    case unsupportedSchemaVersion(String)
    case unknownContractKind(String)
    case mismatchedDiscriminant(schemaVersion: String, contractKind: String)
    case invalidValue(path: String, reason: String)
}

/// A project/revision/coordinate-space binding carried by every derivative.
/// The semantic digest makes a derivative identify immutable source truth
/// without making the derivative itself authoritative truth.
public struct RoomRedesignSourceRevision: Codable, Sendable, Equatable {
    public var projectID: String
    public var revisionID: String
    public var coordinateSpaceEpochID: String
    public var packageSchemaVersion: String
    public var semanticSHA256: String
    /// Digest of the immutable local revision manifest. This prevents a
    /// derivative from being bound only to semantic content while silently
    /// referring to a different captured revision lineage.
    public var revisionManifestSHA256: String

    public init(
        projectID: String,
        revisionID: String,
        coordinateSpaceEpochID: String,
        packageSchemaVersion: String,
        semanticSHA256: String,
        revisionManifestSHA256: String
    ) {
        self.projectID = projectID
        self.revisionID = revisionID
        self.coordinateSpaceEpochID = coordinateSpaceEpochID
        self.packageSchemaVersion = packageSchemaVersion
        self.semanticSHA256 = semanticSHA256
        self.revisionManifestSHA256 = revisionManifestSHA256
    }

    public func validate() throws {
        try RoomRedesignContractRules.requireIdentifier(projectID, at: "sourceRevision.projectID")
        try RoomRedesignContractRules.requireIdentifier(revisionID, at: "sourceRevision.revisionID")
        try RoomRedesignContractRules.requireIdentifier(coordinateSpaceEpochID, at: "sourceRevision.coordinateSpaceEpochID")
        guard RoomProjectSchemaVersion(rawValue: packageSchemaVersion) != nil else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "sourceRevision.packageSchemaVersion",
                reason: "Source revisions must reference a supported immutable room package schema."
            )
        }
        try RoomRedesignContractRules.requireSHA256(semanticSHA256, at: "sourceRevision.semanticSHA256")
        try RoomRedesignContractRules.requireSHA256(
            revisionManifestSHA256,
            at: "sourceRevision.revisionManifestSHA256"
        )
    }
}

public struct RoomRedesignVector3: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

// MARK: - Additive local redesign extension

public struct RoomLocalRedesignExtension: Encodable, Sendable, Equatable {
    public var schemaVersion: String
    public var contractKind: RoomRedesignContractKind
    public var sourceRevision: RoomRedesignSourceRevision
    public var orientation: RoomOrientationContract
    public var redesignIntent: RoomRedesignIntentContract
    public var propertyMembership: RoomPropertyMembershipContract
    public var conceptMetadata: [RoomConceptMetadataContract]

    public init(
        schemaVersion: String = RoomRedesignContractKind.localRedesignExtension.supportedSchemaVersion,
        contractKind: RoomRedesignContractKind = .localRedesignExtension,
        sourceRevision: RoomRedesignSourceRevision,
        orientation: RoomOrientationContract,
        redesignIntent: RoomRedesignIntentContract,
        propertyMembership: RoomPropertyMembershipContract,
        conceptMetadata: [RoomConceptMetadataContract]
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
        try RoomRedesignContractRules.requireEnvelope(
            schemaVersion: schemaVersion,
            contractKind: contractKind,
            expected: .localRedesignExtension
        )
        try sourceRevision.validate()
        try orientation.validate(boundTo: sourceRevision)
        try redesignIntent.validate()
        try propertyMembership.validate(containing: sourceRevision.projectID)
        try RoomRedesignContractRules.requireCount(
            conceptMetadata.count,
            maximum: RoomRedesignContractRules.maximumCollectionCount,
            at: "conceptMetadata"
        )
        try RoomRedesignContractRules.requireUnique(
            conceptMetadata.map(\.conceptSetID),
            at: "conceptMetadata.conceptSetID"
        )
        for (index, concept) in conceptMetadata.enumerated() {
            try concept.validate(boundTo: sourceRevision, at: "conceptMetadata[\(index)]")
        }
    }
}

public enum RoomOrientationSource: String, Codable, Sendable, Equatable {
    case suggested
    case confirmed
    case manual
}

public struct RoomOrientationContract: Codable, Sendable, Equatable {
    public var source: RoomOrientationSource
    public var confidence: Double
    public var coordinateSpaceEpochID: String
    public var entryPositionMeters: RoomRedesignVector3
    public var inwardDirection: RoomRedesignVector3
    public var canonicalAxes: RoomCanonicalAxesContract
    public var canonicalCameras: [RoomCanonicalCameraContract]

    public init(
        source: RoomOrientationSource,
        confidence: Double,
        coordinateSpaceEpochID: String,
        entryPositionMeters: RoomRedesignVector3,
        inwardDirection: RoomRedesignVector3,
        canonicalAxes: RoomCanonicalAxesContract,
        canonicalCameras: [RoomCanonicalCameraContract]
    ) {
        self.source = source
        self.confidence = confidence
        self.coordinateSpaceEpochID = coordinateSpaceEpochID
        self.entryPositionMeters = entryPositionMeters
        self.inwardDirection = inwardDirection
        self.canonicalAxes = canonicalAxes
        self.canonicalCameras = canonicalCameras
    }

    public func validate(boundTo sourceRevision: RoomRedesignSourceRevision) throws {
        guard coordinateSpaceEpochID == sourceRevision.coordinateSpaceEpochID else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "orientation.coordinateSpaceEpochID",
                reason: "Orientation must bind to the source revision coordinate-space epoch."
            )
        }
        try RoomRedesignContractRules.requireIdentifier(
            coordinateSpaceEpochID,
            at: "orientation.coordinateSpaceEpochID"
        )
        try RoomRedesignContractRules.requireUnitInterval(confidence, at: "orientation.confidence")
        try RoomRedesignContractRules.requirePoint(entryPositionMeters, at: "orientation.entryPositionMeters")
        try RoomRedesignContractRules.requireUnitVector(inwardDirection, at: "orientation.inwardDirection")
        try canonicalAxes.validate()
        try RoomRedesignContractRules.requireCount(
            canonicalCameras.count,
            maximum: RoomRedesignContractRules.maximumCollectionCount,
            at: "orientation.canonicalCameras"
        )
        try RoomRedesignContractRules.requireUnique(
            canonicalCameras.map(\.cameraID),
            at: "orientation.canonicalCameras.cameraID"
        )
        for (index, camera) in canonicalCameras.enumerated() {
            try camera.validate(at: "orientation.canonicalCameras[\(index)]")
        }
    }
}

public struct RoomCanonicalAxesContract: Codable, Sendable, Equatable {
    public var right: RoomRedesignVector3
    public var up: RoomRedesignVector3
    public var forward: RoomRedesignVector3

    public init(right: RoomRedesignVector3, up: RoomRedesignVector3, forward: RoomRedesignVector3) {
        self.right = right
        self.up = up
        self.forward = forward
    }

    public func validate() throws {
        try RoomRedesignContractRules.requireUnitVector(right, at: "orientation.canonicalAxes.right")
        try RoomRedesignContractRules.requireUnitVector(up, at: "orientation.canonicalAxes.up")
        try RoomRedesignContractRules.requireUnitVector(forward, at: "orientation.canonicalAxes.forward")

        let pairs = [
            (right, up, "right/up"),
            (right, forward, "right/forward"),
            (up, forward, "up/forward")
        ]
        for (first, second, name) in pairs {
            guard abs(RoomRedesignContractRules.dot(first, second)) <= 0.05 else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: "orientation.canonicalAxes",
                    reason: "Canonical axes \(name) must be orthogonal."
                )
            }
        }
    }
}

public enum RoomCanonicalCameraRole: String, Codable, Sendable, Equatable {
    case entry
    case wall
    case corner
    case orbit
    case perspective
    case topDown
}

public struct RoomCanonicalCameraContract: Codable, Sendable, Equatable {
    public var cameraID: String
    public var role: RoomCanonicalCameraRole
    public var positionMeters: RoomRedesignVector3
    public var targetMeters: RoomRedesignVector3
    public var fieldOfViewDegrees: Double

    public init(
        cameraID: String,
        role: RoomCanonicalCameraRole,
        positionMeters: RoomRedesignVector3,
        targetMeters: RoomRedesignVector3,
        fieldOfViewDegrees: Double
    ) {
        self.cameraID = cameraID
        self.role = role
        self.positionMeters = positionMeters
        self.targetMeters = targetMeters
        self.fieldOfViewDegrees = fieldOfViewDegrees
    }

    public func validate(at path: String) throws {
        try RoomRedesignContractRules.requireIdentifier(cameraID, at: "\(path).cameraID")
        try RoomRedesignContractRules.requirePoint(positionMeters, at: "\(path).positionMeters")
        try RoomRedesignContractRules.requirePoint(targetMeters, at: "\(path).targetMeters")
        try RoomRedesignContractRules.requireFinite(
            fieldOfViewDegrees,
            minimum: 1,
            maximum: 179,
            at: "\(path).fieldOfViewDegrees"
        )
        let delta = RoomRedesignVector3(
            x: targetMeters.x - positionMeters.x,
            y: targetMeters.y - positionMeters.y,
            z: targetMeters.z - positionMeters.z
        )
        guard RoomRedesignContractRules.length(delta) > 0.001 else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: path,
                reason: "A canonical camera position and target must differ."
            )
        }
    }
}

public enum RoomRedesignScope: String, Codable, Sendable, Equatable {
    case stage
    case renovate
    case reimagine
}

public enum RoomFeatureRedesignPermission: String, Codable, Sendable, Equatable {
    case preserve
    case mayChange
    case requestedChange
}

public struct RoomFeaturePermissionContract: Codable, Sendable, Equatable {
    public var featureID: String
    public var permission: RoomFeatureRedesignPermission

    public init(featureID: String, permission: RoomFeatureRedesignPermission) {
        self.featureID = featureID
        self.permission = permission
    }
}

/// Redesign permissions deliberately contain no captured geometry. They are
/// an additive request layer and cannot mutate room evidence or measurements.
public struct RoomRedesignIntentContract: Codable, Sendable, Equatable {
    public var request: String
    public var scope: RoomRedesignScope
    public var permissions: [RoomFeaturePermissionContract]

    public init(
        request: String,
        scope: RoomRedesignScope,
        permissions: [RoomFeaturePermissionContract]
    ) {
        self.request = request
        self.scope = scope
        self.permissions = permissions
    }

    public func validate() throws {
        try RoomRedesignContractRules.requireText(
            request,
            minimum: 1,
            maximum: 8_000,
            at: "redesignIntent.request"
        )
        try RoomRedesignContractRules.requireCount(
            permissions.count,
            maximum: RoomRedesignContractRules.maximumCollectionCount,
            at: "redesignIntent.permissions"
        )
        try RoomRedesignContractRules.requireUnique(
            permissions.map(\.featureID),
            at: "redesignIntent.permissions.featureID"
        )
        for (index, permission) in permissions.enumerated() {
            try RoomRedesignContractRules.requireIdentifier(
                permission.featureID,
                at: "redesignIntent.permissions[\(index)].featureID"
            )
        }
    }
}

/// A property is only a group of independent room projects in v1. The schema
/// intentionally has no coordinate transform, doorway, or connectivity field.
public struct RoomPropertyMembershipContract: Codable, Sendable, Equatable {
    public var propertyID: String
    public var roomProjectIDs: [String]

    public init(propertyID: String, roomProjectIDs: [String]) {
        self.propertyID = propertyID
        self.roomProjectIDs = roomProjectIDs
    }

    public func validate(containing projectID: String) throws {
        try RoomRedesignContractRules.requireIdentifier(propertyID, at: "propertyMembership.propertyID")
        guard !roomProjectIDs.isEmpty else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "propertyMembership.roomProjectIDs",
                reason: "Property membership must include the local project."
            )
        }
        try RoomRedesignContractRules.requireCount(
            roomProjectIDs.count,
            maximum: RoomRedesignContractRules.maximumCollectionCount,
            at: "propertyMembership.roomProjectIDs"
        )
        try RoomRedesignContractRules.requireUnique(
            roomProjectIDs,
            at: "propertyMembership.roomProjectIDs"
        )
        for (index, roomProjectID) in roomProjectIDs.enumerated() {
            try RoomRedesignContractRules.requireIdentifier(
                roomProjectID,
                at: "propertyMembership.roomProjectIDs[\(index)]"
            )
        }
        guard roomProjectIDs.contains(projectID) else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "propertyMembership.roomProjectIDs",
                reason: "Property membership must include the source project."
            )
        }
    }
}

public enum RoomConceptMappingStatus: String, Codable, Sendable, Equatable {
    case automatic
    case manual
    case unmatched
}

public struct RoomConceptAttachmentContract: Codable, Sendable, Equatable {
    public var relativePath: String
    public var sha256: String
    public var byteCount: UInt64
    public var mediaType: String

    public init(relativePath: String, sha256: String, byteCount: UInt64, mediaType: String) {
        self.relativePath = relativePath
        self.sha256 = sha256
        self.byteCount = byteCount
        self.mediaType = mediaType
    }

    public func validate(at path: String) throws {
        try RoomRedesignContractRules.requireRelativePath(relativePath, at: "\(path).relativePath")
        try RoomRedesignContractRules.requireSHA256(sha256, at: "\(path).sha256")
        try RoomRedesignContractRules.requireByteCount(byteCount, at: "\(path).byteCount")
        try RoomRedesignContractRules.requireMediaType(mediaType, at: "\(path).mediaType")
    }
}

/// Revision-bound provenance only. Concept metadata has no geometry,
/// measurement, or revision-mutating field by construction.
public struct RoomConceptMetadataContract: Codable, Sendable, Equatable {
    public var conceptSetID: String
    public var sourceRevisionID: String
    public var sourceSemanticSHA256: String
    public var sourceRevisionManifestSHA256: String
    public var scope: RoomRedesignScope
    public var mappingStatus: RoomConceptMappingStatus
    public var attachments: [RoomConceptAttachmentContract]

    public init(
        conceptSetID: String,
        sourceRevisionID: String,
        sourceSemanticSHA256: String,
        sourceRevisionManifestSHA256: String,
        scope: RoomRedesignScope,
        mappingStatus: RoomConceptMappingStatus,
        attachments: [RoomConceptAttachmentContract]
    ) {
        self.conceptSetID = conceptSetID
        self.sourceRevisionID = sourceRevisionID
        self.sourceSemanticSHA256 = sourceSemanticSHA256
        self.sourceRevisionManifestSHA256 = sourceRevisionManifestSHA256
        self.scope = scope
        self.mappingStatus = mappingStatus
        self.attachments = attachments
    }

    public func validate(boundTo sourceRevision: RoomRedesignSourceRevision, at path: String) throws {
        try RoomRedesignContractRules.requireIdentifier(conceptSetID, at: "\(path).conceptSetID")
        guard sourceRevisionID == sourceRevision.revisionID else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "\(path).sourceRevisionID",
                reason: "Concept metadata must bind to the immutable source revision."
            )
        }
        guard sourceSemanticSHA256 == sourceRevision.semanticSHA256 else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "\(path).sourceSemanticSHA256",
                reason: "Concept metadata must bind to the source semantic digest."
            )
        }
        guard sourceRevisionManifestSHA256 == sourceRevision.revisionManifestSHA256 else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "\(path).sourceRevisionManifestSHA256",
                reason: "Concept metadata must bind to the source revision manifest."
            )
        }
        try RoomRedesignContractRules.requireIdentifier(sourceRevisionID, at: "\(path).sourceRevisionID")
        try RoomRedesignContractRules.requireSHA256(sourceSemanticSHA256, at: "\(path).sourceSemanticSHA256")
        try RoomRedesignContractRules.requireSHA256(
            sourceRevisionManifestSHA256,
            at: "\(path).sourceRevisionManifestSHA256"
        )
        try RoomRedesignContractRules.requireCount(
            attachments.count,
            maximum: RoomRedesignContractRules.maximumCollectionCount,
            at: "\(path).attachments"
        )
        for (index, attachment) in attachments.enumerated() {
            try attachment.validate(at: "\(path).attachments[\(index)]")
        }
        try RoomRedesignContractRules.requireUniqueRelativePaths(
            attachments.map(\.relativePath),
            at: "\(path).attachments.relativePath"
        )
    }
}

// MARK: - Hosted API resource envelope

public enum RoomHostedResourceType: String, Codable, Sendable, Equatable {
    case workspace
    case member
    case property
    case project
    case revision
    case asset
    case conceptSet
    case editLease
    case subscription
    case portalSnapshot
    case portalLink
    case comment
    case feedback
    case auditEvent
    case deletionJob
}

public enum RoomHostedResourceLifecycleState: String, Codable, Sendable, Equatable {
    case active
    case trashed
    case purging
    case deleted
}

/// Provider-neutral resource metadata. A later hosted adapter may map this
/// envelope to a vendor database, but no vendor or network dependency belongs
/// in RoomScanCore.
public struct RoomHostedAPIResource: Encodable, Sendable, Equatable {
    public var schemaVersion: String
    public var contractKind: RoomRedesignContractKind
    public var resourceType: RoomHostedResourceType
    public var resourceID: String
    public var workspaceID: String
    public var projectID: String?
    public var revisionID: String?
    public var version: UInt64
    public var lifecycleState: RoomHostedResourceLifecycleState
    public var sourceRevision: RoomRedesignSourceRevision?
    public var expectedHeadRevisionID: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        schemaVersion: String = RoomRedesignContractKind.hostedAPIResource.supportedSchemaVersion,
        contractKind: RoomRedesignContractKind = .hostedAPIResource,
        resourceType: RoomHostedResourceType,
        resourceID: String,
        workspaceID: String,
        projectID: String? = nil,
        revisionID: String? = nil,
        version: UInt64,
        lifecycleState: RoomHostedResourceLifecycleState,
        sourceRevision: RoomRedesignSourceRevision? = nil,
        expectedHeadRevisionID: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.contractKind = contractKind
        self.resourceType = resourceType
        self.resourceID = resourceID
        self.workspaceID = workspaceID
        self.projectID = projectID
        self.revisionID = revisionID
        self.version = version
        self.lifecycleState = lifecycleState
        self.sourceRevision = sourceRevision
        self.expectedHeadRevisionID = expectedHeadRevisionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func validate() throws {
        try RoomRedesignContractRules.requireEnvelope(
            schemaVersion: schemaVersion,
            contractKind: contractKind,
            expected: .hostedAPIResource
        )
        try RoomRedesignContractRules.requireIdentifier(resourceID, at: "resourceID")
        try RoomRedesignContractRules.requireIdentifier(workspaceID, at: "workspaceID")
        guard version > 0 && version <= RoomRedesignContractRules.maximumResourceVersion else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "version",
                reason: "Resource versions must be positive and bounded."
            )
        }
        try RoomRedesignContractRules.requireDate(createdAt, at: "createdAt")
        try RoomRedesignContractRules.requireDate(updatedAt, at: "updatedAt")
        guard updatedAt >= createdAt else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "updatedAt",
                reason: "A resource cannot update before it is created."
            )
        }

        if let projectID {
            try RoomRedesignContractRules.requireIdentifier(projectID, at: "projectID")
        }
        if let revisionID {
            try RoomRedesignContractRules.requireIdentifier(revisionID, at: "revisionID")
            guard projectID != nil else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: "revisionID",
                    reason: "A revision resource must identify its project."
                )
            }
        }
        if let expectedHeadRevisionID {
            try RoomRedesignContractRules.requireIdentifier(expectedHeadRevisionID, at: "expectedHeadRevisionID")
            guard projectID != nil else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: "expectedHeadRevisionID",
                    reason: "An expected head is meaningful only for a project."
                )
            }
        }
        if let sourceRevision {
            try sourceRevision.validate()
            guard projectID == sourceRevision.projectID, revisionID == sourceRevision.revisionID else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: "sourceRevision",
                    reason: "Source revision must match the resource project and revision IDs."
                )
            }
        }

        switch resourceType {
        case .workspace, .member, .property, .subscription:
            guard projectID == nil, revisionID == nil, sourceRevision == nil, expectedHeadRevisionID == nil else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: "resourceType",
                    reason: "Workspace-scoped resources cannot carry project lineage."
                )
            }
        case .project:
            guard projectID != nil else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: "projectID",
                    reason: "A project resource must identify its project."
                )
            }
        case .revision:
            guard projectID != nil, revisionID != nil, sourceRevision != nil else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: "resourceType",
                    reason: "A revision resource must bind to immutable source lineage."
                )
            }
        case .conceptSet:
            guard projectID != nil, revisionID != nil, sourceRevision != nil else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: "resourceType",
                    reason: "Concept Sets must bind to one immutable source revision."
                )
            }
        case .asset, .editLease, .portalSnapshot, .portalLink, .comment, .feedback:
            guard projectID != nil else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: "projectID",
                    reason: "Project-scoped resources must identify their project."
                )
            }
        case .auditEvent, .deletionJob:
            // These resources can be workspace-wide or project-scoped. If
            // supplied, the optional project/revision/source fields above are
            // already constrained to a coherent lineage.
            break
        }
    }
}

// MARK: - AI Room Package

public enum RoomAIRoomPackageProfile: String, Codable, Sendable, Equatable {
    case aiReady
    case complete
}

public enum RoomDisclosureDecision: String, Codable, Sendable, Equatable {
    case approved
    case rejected
}

/// A disclosure review is a manifest fact, not a claim that automated
/// detection has perfectly found or redacted sensitive content.
public struct RoomDisclosureReview: Codable, Sendable, Equatable {
    public var reviewID: String
    public var reviewedAt: Date
    public var decision: RoomDisclosureDecision
    /// The immutable revision manifest explicitly reviewed by the user.
    public var sourceRevisionID: String
    public var sourceRevisionManifestSHA256: String
    /// AI-package and raw-archive reviews additionally bind the immutable
    /// requested plan. Portal snapshots leave this nil because their
    /// allowlisted projection digest is the complete reviewed selection.
    public var reviewedArtifactPlanSHA256: String?
    /// SHA-256 of the canonical, selected ledger projection. A selection
    /// change invalidates a prior approval rather than silently reusing it.
    public var reviewedSelectionSHA256: String
    public var preciseGPSExcluded: Bool
    public var rawEvidenceDisclosureAccepted: Bool

    public init(
        reviewID: String,
        reviewedAt: Date,
        decision: RoomDisclosureDecision,
        sourceRevisionID: String,
        sourceRevisionManifestSHA256: String,
        reviewedArtifactPlanSHA256: String? = nil,
        reviewedSelectionSHA256: String,
        preciseGPSExcluded: Bool,
        rawEvidenceDisclosureAccepted: Bool
    ) {
        self.reviewID = reviewID
        self.reviewedAt = reviewedAt
        self.decision = decision
        self.sourceRevisionID = sourceRevisionID
        self.sourceRevisionManifestSHA256 = sourceRevisionManifestSHA256
        self.reviewedArtifactPlanSHA256 = reviewedArtifactPlanSHA256
        self.reviewedSelectionSHA256 = reviewedSelectionSHA256
        self.preciseGPSExcluded = preciseGPSExcluded
        self.rawEvidenceDisclosureAccepted = rawEvidenceDisclosureAccepted
    }

    public func validate(
        boundTo sourceRevision: RoomRedesignSourceRevision,
        artifactPlanSHA256: String? = nil,
        selectionSHA256: String,
        permitsRawEvidence: Bool,
        at path: String
    ) throws {
        try RoomRedesignContractRules.requireIdentifier(reviewID, at: "\(path).reviewID")
        try RoomRedesignContractRules.requireDate(reviewedAt, at: "\(path).reviewedAt")
        try RoomRedesignContractRules.requireIdentifier(
            sourceRevisionID,
            at: "\(path).sourceRevisionID"
        )
        try RoomRedesignContractRules.requireSHA256(
            sourceRevisionManifestSHA256,
            at: "\(path).sourceRevisionManifestSHA256"
        )
        if let reviewedArtifactPlanSHA256 {
            try RoomRedesignContractRules.requireSHA256(
                reviewedArtifactPlanSHA256,
                at: "\(path).reviewedArtifactPlanSHA256"
            )
        }
        try RoomRedesignContractRules.requireSHA256(
            reviewedSelectionSHA256,
            at: "\(path).reviewedSelectionSHA256"
        )
        guard decision == .approved else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "\(path).decision",
                reason: "A distributable package or archive requires approved disclosure review."
            )
        }
        guard preciseGPSExcluded else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "\(path).preciseGPSExcluded",
                reason: "Precise GPS is structurally excluded from this contract."
            )
        }
        guard sourceRevisionID == sourceRevision.revisionID else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "\(path).sourceRevisionID",
                reason: "Disclosure approval must bind to the source revision being distributed."
            )
        }
        guard sourceRevisionManifestSHA256 == sourceRevision.revisionManifestSHA256 else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "\(path).sourceRevisionManifestSHA256",
                reason: "Disclosure approval must bind to the source revision manifest."
            )
        }
        guard reviewedSelectionSHA256 == selectionSHA256 else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "\(path).reviewedSelectionSHA256",
                reason: "Disclosure approval is stale because the selected content changed."
            )
        }
        guard reviewedArtifactPlanSHA256 == artifactPlanSHA256 else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "\(path).reviewedArtifactPlanSHA256",
                reason: "Disclosure approval must bind to the exact requested artifact plan."
            )
        }
        guard permitsRawEvidence || !rawEvidenceDisclosureAccepted else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "\(path).rawEvidenceDisclosureAccepted",
                reason: "This contract cannot approve raw capture evidence."
            )
        }
    }
}

/// Only classes explicitly modeled here may cross the package/sync boundary.
/// There is intentionally no precise-GPS class.
public enum RoomRedesignArtifactClass: String, Codable, Sendable, Equatable, CaseIterable {
    case normalizedSemantics
    case revisionLineage
    case orientation
    case floorPlan
    case canonicalView
    case selectedReferenceImage
    case materials
    case qualityReport
    case roomBrief
    case redesignIntent
    case providerInstructions
    case mesh
    case texture
    case conceptAttachment
    case comments
    case rawRGB
    case rawDepth
    case rawConfidence
    case diagnostics
    case worldMap

    fileprivate var isRawCaptureEvidence: Bool {
        switch self {
        case .rawRGB, .rawDepth, .rawConfidence, .diagnostics, .worldMap:
            return true
        default:
            return false
        }
    }
}

public enum RoomArtifactDisposition: String, Codable, Sendable, Equatable {
    case included
    case excluded
    case skipped
    case unavailable
    case failed
}

public struct RoomAIRoomPackageArtifact: Codable, Sendable, Equatable {
    public var artifactID: String
    public var artifactClass: RoomRedesignArtifactClass
    public var disposition: RoomArtifactDisposition
    public var relativePath: String?
    public var sha256: String?
    public var byteCount: UInt64?
    public var mediaType: String?
    public var reasonCode: String?

    public init(
        artifactID: String,
        artifactClass: RoomRedesignArtifactClass,
        disposition: RoomArtifactDisposition,
        relativePath: String? = nil,
        sha256: String? = nil,
        byteCount: UInt64? = nil,
        mediaType: String? = nil,
        reasonCode: String? = nil
    ) {
        self.artifactID = artifactID
        self.artifactClass = artifactClass
        self.disposition = disposition
        self.relativePath = relativePath
        self.sha256 = sha256
        self.byteCount = byteCount
        self.mediaType = mediaType
        self.reasonCode = reasonCode
    }

    public func validate(at path: String) throws {
        try RoomRedesignContractRules.requireIdentifier(artifactID, at: "\(path).artifactID")
        try RoomRedesignContractRules.validateAssetState(
            disposition: disposition,
            relativePath: relativePath,
            sha256: sha256,
            byteCount: byteCount,
            mediaType: mediaType,
            reasonCode: reasonCode,
            at: path
        )
    }
}

public struct RoomAIRoomPackage: Encodable, Sendable, Equatable {
    public var schemaVersion: String
    public var contractKind: RoomRedesignContractKind
    public var packageID: String
    public var profile: RoomAIRoomPackageProfile
    public var sourceRevision: RoomRedesignSourceRevision
    /// Deterministic v1 plan derived from the immutable source, profile, and
    /// contract. It fixes the complete ledger slots before any bytes are
    /// selected, preventing silent omission of a requested record.
    public var artifactPlanSHA256: String
    public var selectionSHA256: String
    public var disclosureReview: RoomDisclosureReview
    public var artifacts: [RoomAIRoomPackageArtifact]

    public init(
        schemaVersion: String = RoomRedesignContractKind.aiRoomPackage.supportedSchemaVersion,
        contractKind: RoomRedesignContractKind = .aiRoomPackage,
        packageID: String,
        profile: RoomAIRoomPackageProfile,
        sourceRevision: RoomRedesignSourceRevision,
        artifactPlanSHA256: String,
        selectionSHA256: String,
        disclosureReview: RoomDisclosureReview,
        artifacts: [RoomAIRoomPackageArtifact]
    ) {
        self.schemaVersion = schemaVersion
        self.contractKind = contractKind
        self.packageID = packageID
        self.profile = profile
        self.sourceRevision = sourceRevision
        self.artifactPlanSHA256 = artifactPlanSHA256
        self.selectionSHA256 = selectionSHA256
        self.disclosureReview = disclosureReview
        self.artifacts = artifacts
    }

    public func validate() throws {
        try RoomRedesignContractRules.requireEnvelope(
            schemaVersion: schemaVersion,
            contractKind: contractKind,
            expected: .aiRoomPackage
        )
        try RoomRedesignContractRules.requireIdentifier(packageID, at: "packageID")
        try sourceRevision.validate()
        try RoomRedesignContractRules.requireSHA256(
            artifactPlanSHA256,
            at: "artifactPlanSHA256"
        )
        try RoomRedesignContractRules.requireSHA256(selectionSHA256, at: "selectionSHA256")
        try RoomRedesignContractRules.requireNonemptyCount(
            artifacts.count,
            maximum: RoomRedesignContractRules.maximumCollectionCount,
            at: "artifacts"
        )
        try RoomRedesignContractRules.requireUnique(artifacts.map(\.artifactID), at: "artifacts.artifactID")
        try RoomRedesignContractRules.requireUnique(
            artifacts.map(\.artifactClass),
            at: "artifacts.artifactClass"
        )
        for (index, artifact) in artifacts.enumerated() {
            try artifact.validate(at: "artifacts[\(index)]")
        }
        try RoomRedesignContractRules.requireUniqueRelativePaths(
            artifacts.compactMap { $0.disposition == .included ? $0.relativePath : nil },
            at: "artifacts.included.relativePath"
        )

        let computedSelectionSHA256 = try RoomRedesignContractRules.selectionDigest(
            artifacts: artifacts
        )
        guard selectionSHA256 == computedSelectionSHA256 else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "selectionSHA256",
                reason: "AI package selection digest must match its exact artifact ledger."
            )
        }
        let computedArtifactPlanSHA256 = try RoomRedesignContractRules.aiArtifactPlanDigest(
            sourceRevision: sourceRevision,
            profile: profile
        )
        guard artifactPlanSHA256 == computedArtifactPlanSHA256 else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "artifactPlanSHA256",
                reason: "AI package artifact plan digest must match the source-bound v1 profile plan."
            )
        }
        try disclosureReview.validate(
            boundTo: sourceRevision,
            artifactPlanSHA256: artifactPlanSHA256,
            selectionSHA256: selectionSHA256,
            permitsRawEvidence: profile == .complete,
            at: "disclosureReview"
        )

        let expectedArtifactClasses = RoomRedesignContractRules.aiArtifactPlanSlots(profile: profile)
        guard Set(artifacts.map(\.artifactClass)) == Set(expectedArtifactClasses),
              artifacts.count == expectedArtifactClasses.count
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "artifacts",
                reason: "The AI artifact ledger must contain exactly one record for every source-bound v1 plan slot."
            )
        }
        guard !artifacts.contains(where: { $0.artifactClass == .worldMap }) else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "artifacts",
                reason: "World maps are private capture state and are not permitted in either AI Room Package profile."
            )
        }

        let includesRawEvidence = artifacts.contains {
            $0.artifactClass.isRawCaptureEvidence && $0.disposition == .included
        }
        switch profile {
        case .aiReady:
            guard !includesRawEvidence else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: "artifacts",
                    reason: "AI-ready packages must not include raw RGB, depth, confidence, diagnostics, or world-map evidence."
                )
            }
            guard !disclosureReview.rawEvidenceDisclosureAccepted else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: "disclosureReview.rawEvidenceDisclosureAccepted",
                    reason: "AI-ready packages cannot opt in to raw capture evidence."
                )
            }
        case .complete:
            if includesRawEvidence && !disclosureReview.rawEvidenceDisclosureAccepted {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: "disclosureReview.rawEvidenceDisclosureAccepted",
                    reason: "Complete packages require explicit disclosure review for raw capture evidence."
                )
            }
        }
    }
}

// MARK: - Working-project sync

public enum RoomWorkingProjectSyncOperation: String, Codable, Sendable, Equatable {
    case appendRevision
}

public enum RoomWorkingProjectAssetPolicy: String, Codable, Sendable, Equatable {
    case workingSet
    case rawArchiveOptIn
}

/// The only v1 conflict behavior. A server adapter must preserve the stale
/// branch and require a user decision; it must never synthesize a geometry
/// merge from this contract.
public enum RoomSyncConflictPolicy: String, Codable, Sendable, Equatable {
    case preserveBranchesRequireUserResolution
}

public struct RoomWorkingProjectSyncAsset: Codable, Sendable, Equatable {
    public var assetID: String
    public var assetClass: RoomRedesignArtifactClass
    public var disposition: RoomArtifactDisposition
    public var relativePath: String?
    public var sha256: String?
    public var byteCount: UInt64?
    public var mediaType: String?
    public var reasonCode: String?

    public init(
        assetID: String,
        assetClass: RoomRedesignArtifactClass,
        disposition: RoomArtifactDisposition,
        relativePath: String? = nil,
        sha256: String? = nil,
        byteCount: UInt64? = nil,
        mediaType: String? = nil,
        reasonCode: String? = nil
    ) {
        self.assetID = assetID
        self.assetClass = assetClass
        self.disposition = disposition
        self.relativePath = relativePath
        self.sha256 = sha256
        self.byteCount = byteCount
        self.mediaType = mediaType
        self.reasonCode = reasonCode
    }

    public func validate(at path: String) throws {
        try RoomRedesignContractRules.requireIdentifier(assetID, at: "\(path).assetID")
        try RoomRedesignContractRules.validateAssetState(
            disposition: disposition,
            relativePath: relativePath,
            sha256: sha256,
            byteCount: byteCount,
            mediaType: mediaType,
            reasonCode: reasonCode,
            at: path
        )
    }
}

public struct RoomWorkingProjectSync: Encodable, Sendable, Equatable {
    public var schemaVersion: String
    public var contractKind: RoomRedesignContractKind
    public var operation: RoomWorkingProjectSyncOperation
    public var workspaceID: String
    public var projectID: String
    public var expectedHostedHeadRevisionID: String
    public var proposedRevision: RoomRedesignSourceRevision
    public var assetPolicy: RoomWorkingProjectAssetPolicy
    /// Deterministic plan derived from proposed revision, policy, and v1
    /// contract. Raw opt-in review binds this plan as well as the actual asset
    /// selection so a review cannot be replayed after a policy change.
    public var assetPlanSHA256: String
    public var selectionSHA256: String
    public var rawArchiveDisclosureReview: RoomDisclosureReview?
    public var conflictPolicy: RoomSyncConflictPolicy
    public var assets: [RoomWorkingProjectSyncAsset]

    public init(
        schemaVersion: String = RoomRedesignContractKind.workingProjectSync.supportedSchemaVersion,
        contractKind: RoomRedesignContractKind = .workingProjectSync,
        operation: RoomWorkingProjectSyncOperation = .appendRevision,
        workspaceID: String,
        projectID: String,
        expectedHostedHeadRevisionID: String,
        proposedRevision: RoomRedesignSourceRevision,
        assetPolicy: RoomWorkingProjectAssetPolicy,
        assetPlanSHA256: String,
        selectionSHA256: String,
        rawArchiveDisclosureReview: RoomDisclosureReview? = nil,
        conflictPolicy: RoomSyncConflictPolicy = .preserveBranchesRequireUserResolution,
        assets: [RoomWorkingProjectSyncAsset]
    ) {
        self.schemaVersion = schemaVersion
        self.contractKind = contractKind
        self.operation = operation
        self.workspaceID = workspaceID
        self.projectID = projectID
        self.expectedHostedHeadRevisionID = expectedHostedHeadRevisionID
        self.proposedRevision = proposedRevision
        self.assetPolicy = assetPolicy
        self.assetPlanSHA256 = assetPlanSHA256
        self.selectionSHA256 = selectionSHA256
        self.rawArchiveDisclosureReview = rawArchiveDisclosureReview
        self.conflictPolicy = conflictPolicy
        self.assets = assets
    }

    public func validate() throws {
        try RoomRedesignContractRules.requireEnvelope(
            schemaVersion: schemaVersion,
            contractKind: contractKind,
            expected: .workingProjectSync
        )
        try RoomRedesignContractRules.requireIdentifier(workspaceID, at: "workspaceID")
        try RoomRedesignContractRules.requireIdentifier(projectID, at: "projectID")
        try RoomRedesignContractRules.requireIdentifier(
            expectedHostedHeadRevisionID,
            at: "expectedHostedHeadRevisionID"
        )
        try proposedRevision.validate()
        try RoomRedesignContractRules.requireSHA256(assetPlanSHA256, at: "assetPlanSHA256")
        try RoomRedesignContractRules.requireSHA256(selectionSHA256, at: "selectionSHA256")
        guard proposedRevision.projectID == projectID else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "proposedRevision.projectID",
                reason: "A sync append must target the proposed revision's project."
            )
        }
        guard proposedRevision.revisionID != expectedHostedHeadRevisionID else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "proposedRevision.revisionID",
                reason: "An append must propose a new revision beyond the expected hosted head."
            )
        }
        try RoomRedesignContractRules.requireNonemptyCount(
            assets.count,
            maximum: RoomRedesignContractRules.maximumCollectionCount,
            at: "assets"
        )
        try RoomRedesignContractRules.requireUnique(assets.map(\.assetID), at: "assets.assetID")
        try RoomRedesignContractRules.requireUnique(
            assets.map(\.assetClass),
            at: "assets.assetClass"
        )
        for (index, asset) in assets.enumerated() {
            try asset.validate(at: "assets[\(index)]")
        }
        try RoomRedesignContractRules.requireUniqueRelativePaths(
            assets.compactMap { $0.disposition == .included ? $0.relativePath : nil },
            at: "assets.included.relativePath"
        )
        let computedSelectionSHA256 = try RoomRedesignContractRules.selectionDigest(assets: assets)
        guard selectionSHA256 == computedSelectionSHA256 else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "selectionSHA256",
                reason: "Working sync selection digest must match its exact asset ledger."
            )
        }
        let computedAssetPlanSHA256 = try RoomRedesignContractRules.workingSyncAssetPlanDigest(
            proposedRevision: proposedRevision,
            assetPolicy: assetPolicy
        )
        guard assetPlanSHA256 == computedAssetPlanSHA256 else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "assetPlanSHA256",
                reason: "Working sync asset plan digest must match the proposed revision and policy."
            )
        }
        switch assetPolicy {
        case .workingSet:
            guard rawArchiveDisclosureReview == nil else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: "rawArchiveDisclosureReview",
                    reason: "Default working sync must not carry a raw archive disclosure review."
                )
            }
        case .rawArchiveOptIn:
            guard let rawArchiveDisclosureReview else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: "rawArchiveDisclosureReview",
                    reason: "Raw archive upload requires explicit approved disclosure review."
                )
            }
            try rawArchiveDisclosureReview.validate(
                boundTo: proposedRevision,
                artifactPlanSHA256: assetPlanSHA256,
                selectionSHA256: selectionSHA256,
                permitsRawEvidence: true,
                at: "rawArchiveDisclosureReview"
            )
            guard rawArchiveDisclosureReview.rawEvidenceDisclosureAccepted else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: "rawArchiveDisclosureReview.rawEvidenceDisclosureAccepted",
                    reason: "Raw archive upload requires explicit raw evidence acceptance."
                )
            }
        }

        // The policy-bound exact-slot check is the structural raw-default
        // guard: `workingSet` has no raw class that can be marked included.
        let expectedAssetClasses = RoomRedesignContractRules.workingSyncAssetPlanSlots(
            assetPolicy: assetPolicy
        )
        guard Set(assets.map(\.assetClass)) == Set(expectedAssetClasses),
              assets.count == expectedAssetClasses.count
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "assets",
                reason: "The working sync ledger must contain exactly one record for every source-bound policy plan slot."
            )
        }
    }
}

// MARK: - Immutable portal snapshot

/// The portal snapshot is a new allowlisted projection, never a complete
/// private package with a denylist deletion pass.
public enum RoomPortalSnapshotSection: String, Codable, Sendable, Equatable {
    case semanticLayout
    case webGeometry
    case textures
    case selectedImages
    case floorPlan
    case dimensions
    case qualityWarnings
    case approvedConcepts
    case branding
    case enabledDownloads
}

/// There is intentionally no raw, world-map, diagnostics, private-notes,
/// revision-history, or location asset class.
public enum RoomPortalSnapshotAssetClass: String, Codable, Sendable, Equatable {
    case webGeometry
    case webTexture
    case selectedImage
    case floorPlan
    case approvedConcept
    case floorPlanPDF
    case approvedGalleryZIP
    case aiReadyPackage

    fileprivate var requiredSection: RoomPortalSnapshotSection {
        switch self {
        case .webGeometry:
            return .webGeometry
        case .webTexture:
            return .textures
        case .selectedImage:
            return .selectedImages
        case .floorPlan:
            return .floorPlan
        case .approvedConcept:
            return .approvedConcepts
        case .floorPlanPDF, .approvedGalleryZIP, .aiReadyPackage:
            return .enabledDownloads
        }
    }
}

/// Content identity recorded only after a bounded archive reader has parsed
/// the AI package manifest and the strict AI-package validator has accepted
/// it. The portal document binds this evidence into its reviewed selection;
/// publication code must still use the byte-aware validation entry point
/// below before serving the archive.
public struct RoomPortalAIReadyPackageBinding: Codable, Sendable, Equatable {
    public var packageID: String
    public var profile: RoomAIRoomPackageProfile
    public var manifestEntryPath: String
    public var manifestSHA256: String
    public var sourceRevisionID: String
    public var sourceRevisionManifestSHA256: String
    public var artifactPlanSHA256: String
    public var selectionSHA256: String

    public init(
        packageID: String,
        profile: RoomAIRoomPackageProfile,
        manifestEntryPath: String,
        manifestSHA256: String,
        sourceRevisionID: String,
        sourceRevisionManifestSHA256: String,
        artifactPlanSHA256: String,
        selectionSHA256: String
    ) {
        self.packageID = packageID
        self.profile = profile
        self.manifestEntryPath = manifestEntryPath
        self.manifestSHA256 = manifestSHA256
        self.sourceRevisionID = sourceRevisionID
        self.sourceRevisionManifestSHA256 = sourceRevisionManifestSHA256
        self.artifactPlanSHA256 = artifactPlanSHA256
        self.selectionSHA256 = selectionSHA256
    }

    public func validate(boundTo sourceRevision: RoomRedesignSourceRevision, at path: String) throws {
        try RoomRedesignContractRules.requireIdentifier(packageID, at: "\(path).packageID")
        guard profile == .aiReady else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "\(path).profile",
                reason: "Portal downloads may bind only a validated AI-ready package manifest."
            )
        }
        guard manifestEntryPath == "ai-room-package.json" else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "\(path).manifestEntryPath",
                reason: "V1 AI-ready downloads use one unambiguous manifest entry path."
            )
        }
        try RoomRedesignContractRules.requireRelativePath(
            manifestEntryPath,
            at: "\(path).manifestEntryPath"
        )
        try RoomRedesignContractRules.requireSHA256(manifestSHA256, at: "\(path).manifestSHA256")
        try RoomRedesignContractRules.requireIdentifier(sourceRevisionID, at: "\(path).sourceRevisionID")
        try RoomRedesignContractRules.requireSHA256(
            sourceRevisionManifestSHA256,
            at: "\(path).sourceRevisionManifestSHA256"
        )
        try RoomRedesignContractRules.requireSHA256(
            artifactPlanSHA256,
            at: "\(path).artifactPlanSHA256"
        )
        try RoomRedesignContractRules.requireSHA256(selectionSHA256, at: "\(path).selectionSHA256")
        guard sourceRevisionID == sourceRevision.revisionID,
              sourceRevisionManifestSHA256 == sourceRevision.revisionManifestSHA256
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: path,
                reason: "The validated AI-ready manifest must bind to the portal source revision."
            )
        }
        let expectedPlan = try RoomRedesignContractRules.aiArtifactPlanDigest(
            sourceRevision: sourceRevision,
            profile: .aiReady
        )
        guard artifactPlanSHA256 == expectedPlan else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "\(path).artifactPlanSHA256",
                reason: "The portal download must use the source-bound AI-ready artifact plan."
            )
        }
    }
}

public struct RoomPortalSnapshotAsset: Codable, Sendable, Equatable {
    public var assetID: String
    public var assetClass: RoomPortalSnapshotAssetClass
    public var relativePath: String
    public var sha256: String
    public var byteCount: UInt64
    public var mediaType: String
    public var aiReadyPackageBinding: RoomPortalAIReadyPackageBinding?

    public init(
        assetID: String,
        assetClass: RoomPortalSnapshotAssetClass,
        relativePath: String,
        sha256: String,
        byteCount: UInt64,
        mediaType: String,
        aiReadyPackageBinding: RoomPortalAIReadyPackageBinding? = nil
    ) {
        self.assetID = assetID
        self.assetClass = assetClass
        self.relativePath = relativePath
        self.sha256 = sha256
        self.byteCount = byteCount
        self.mediaType = mediaType
        self.aiReadyPackageBinding = aiReadyPackageBinding
    }

    public func validate(boundTo sourceRevision: RoomRedesignSourceRevision, at path: String) throws {
        try RoomRedesignContractRules.requireIdentifier(assetID, at: "\(path).assetID")
        try RoomRedesignContractRules.requireRelativePath(relativePath, at: "\(path).relativePath")
        try RoomRedesignContractRules.requireSHA256(sha256, at: "\(path).sha256")
        try RoomRedesignContractRules.requireByteCount(byteCount, at: "\(path).byteCount")
        try RoomRedesignContractRules.requireMediaType(mediaType, at: "\(path).mediaType")
        switch assetClass {
        case .floorPlanPDF:
            guard aiReadyPackageBinding == nil,
                  mediaType == "application/pdf", relativePath.hasSuffix(".pdf")
            else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: path,
                    reason: "A floor-plan download must be a PDF derivative."
                )
            }
        case .approvedGalleryZIP:
            guard aiReadyPackageBinding == nil,
                  mediaType == "application/zip", relativePath.hasSuffix(".zip")
            else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: path,
                    reason: "An approved-gallery download must be a separately built ZIP derivative."
                )
            }
        case .aiReadyPackage:
            guard mediaType == "application/zip", relativePath.hasSuffix(".zip"),
                  let aiReadyPackageBinding
            else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: "\(path).aiReadyPackageBinding",
                    reason: "An AI-ready download requires a separately parsed and validated manifest binding."
                )
            }
            try aiReadyPackageBinding.validate(
                boundTo: sourceRevision,
                at: "\(path).aiReadyPackageBinding"
            )
        case .webGeometry, .webTexture, .selectedImage, .floorPlan, .approvedConcept:
            guard aiReadyPackageBinding == nil else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: "\(path).aiReadyPackageBinding",
                    reason: "Only an AI-ready package download may carry an AI-package manifest binding."
                )
            }
        }
    }
}

public struct RoomPortalBranding: Codable, Sendable, Equatable {
    public var displayName: String
    public var accentColorHex: String?

    public init(displayName: String, accentColorHex: String? = nil) {
        self.displayName = displayName
        self.accentColorHex = accentColorHex
    }

    public func validate() throws {
        try RoomRedesignContractRules.requireText(
            displayName,
            minimum: 1,
            maximum: 200,
            at: "branding.displayName"
        )
        if let accentColorHex {
            guard accentColorHex.count == 6,
                  accentColorHex.unicodeScalars.allSatisfy(RoomRedesignContractRules.hexadecimalScalars.contains)
            else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: "branding.accentColorHex",
                    reason: "A portal accent must be a six-digit hexadecimal color without a prefix."
                )
            }
        }
    }
}

public struct RoomPortalSnapshot: Encodable, Sendable, Equatable {
    public var schemaVersion: String
    public var contractKind: RoomRedesignContractKind
    public var snapshotID: String
    public var workspaceID: String
    public var projectID: String
    public var sourceRevision: RoomRedesignSourceRevision
    public var publishedAt: Date
    public var selectionSHA256: String
    public var disclosureReview: RoomDisclosureReview
    public var allowlistedSections: [RoomPortalSnapshotSection]
    public var assets: [RoomPortalSnapshotAsset]
    public var branding: RoomPortalBranding

    public init(
        schemaVersion: String = RoomRedesignContractKind.portalSnapshot.supportedSchemaVersion,
        contractKind: RoomRedesignContractKind = .portalSnapshot,
        snapshotID: String,
        workspaceID: String,
        projectID: String,
        sourceRevision: RoomRedesignSourceRevision,
        publishedAt: Date,
        selectionSHA256: String,
        disclosureReview: RoomDisclosureReview,
        allowlistedSections: [RoomPortalSnapshotSection],
        assets: [RoomPortalSnapshotAsset],
        branding: RoomPortalBranding
    ) {
        self.schemaVersion = schemaVersion
        self.contractKind = contractKind
        self.snapshotID = snapshotID
        self.workspaceID = workspaceID
        self.projectID = projectID
        self.sourceRevision = sourceRevision
        self.publishedAt = publishedAt
        self.selectionSHA256 = selectionSHA256
        self.disclosureReview = disclosureReview
        self.allowlistedSections = allowlistedSections
        self.assets = assets
        self.branding = branding
    }

    public func validate() throws {
        try RoomRedesignContractRules.requireEnvelope(
            schemaVersion: schemaVersion,
            contractKind: contractKind,
            expected: .portalSnapshot
        )
        try RoomRedesignContractRules.requireIdentifier(snapshotID, at: "snapshotID")
        try RoomRedesignContractRules.requireIdentifier(workspaceID, at: "workspaceID")
        try RoomRedesignContractRules.requireIdentifier(projectID, at: "projectID")
        try sourceRevision.validate()
        guard sourceRevision.projectID == projectID else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "sourceRevision.projectID",
                reason: "A portal snapshot must bind to the selected project source revision."
            )
        }
        try RoomRedesignContractRules.requireDate(publishedAt, at: "publishedAt")
        try RoomRedesignContractRules.requireSHA256(selectionSHA256, at: "selectionSHA256")
        try RoomRedesignContractRules.requireNonemptyCount(
            allowlistedSections.count,
            maximum: RoomRedesignContractRules.maximumCollectionCount,
            at: "allowlistedSections"
        )
        try RoomRedesignContractRules.requireUnique(
            allowlistedSections,
            at: "allowlistedSections"
        )
        try RoomRedesignContractRules.requireCount(
            assets.count,
            maximum: RoomRedesignContractRules.maximumCollectionCount,
            at: "assets"
        )
        try RoomRedesignContractRules.requireUnique(assets.map(\.assetID), at: "assets.assetID")
        for (index, asset) in assets.enumerated() {
            try asset.validate(boundTo: sourceRevision, at: "assets[\(index)]")
            guard allowlistedSections.contains(asset.assetClass.requiredSection) else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: "assets[\(index)].assetClass",
                    reason: "Every portal asset must be covered by an explicit snapshot allowlist section."
                )
            }
        }
        try RoomRedesignContractRules.requireUniqueRelativePaths(
            assets.map(\.relativePath),
            at: "assets.relativePath"
        )
        try branding.validate()
        let computedSelectionSHA256 = try RoomRedesignContractRules.selectionDigest(
            portalSections: allowlistedSections,
            portalAssets: assets,
            branding: branding
        )
        guard selectionSHA256 == computedSelectionSHA256 else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "selectionSHA256",
                reason: "Portal snapshot selection digest must match its allowlisted projection."
            )
        }
        try disclosureReview.validate(
            boundTo: sourceRevision,
            selectionSHA256: selectionSHA256,
            permitsRawEvidence: false,
            at: "disclosureReview"
        )
    }
}

// MARK: - Fail-closed JSON validator

// Top-level documents intentionally do not conform to `Decodable`. These
// private wire shapes are reachable only after the raw JSON tree has passed
// strict recursive key validation. This prevents a caller from accidentally
// using synthesized Codable behavior that silently discards a new/private key.
private struct RoomLocalRedesignExtensionWire: Decodable {
    var schemaVersion: String
    var contractKind: RoomRedesignContractKind
    var sourceRevision: RoomRedesignSourceRevision
    var orientation: RoomOrientationContract
    var redesignIntent: RoomRedesignIntentContract
    var propertyMembership: RoomPropertyMembershipContract
    var conceptMetadata: [RoomConceptMetadataContract]

    var model: RoomLocalRedesignExtension {
        RoomLocalRedesignExtension(
            schemaVersion: schemaVersion,
            contractKind: contractKind,
            sourceRevision: sourceRevision,
            orientation: orientation,
            redesignIntent: redesignIntent,
            propertyMembership: propertyMembership,
            conceptMetadata: conceptMetadata
        )
    }
}

private struct RoomHostedAPIResourceWire: Decodable {
    var schemaVersion: String
    var contractKind: RoomRedesignContractKind
    var resourceType: RoomHostedResourceType
    var resourceID: String
    var workspaceID: String
    var projectID: String?
    var revisionID: String?
    var version: UInt64
    var lifecycleState: RoomHostedResourceLifecycleState
    var sourceRevision: RoomRedesignSourceRevision?
    var expectedHeadRevisionID: String?
    var createdAt: Date
    var updatedAt: Date

    var model: RoomHostedAPIResource {
        RoomHostedAPIResource(
            schemaVersion: schemaVersion,
            contractKind: contractKind,
            resourceType: resourceType,
            resourceID: resourceID,
            workspaceID: workspaceID,
            projectID: projectID,
            revisionID: revisionID,
            version: version,
            lifecycleState: lifecycleState,
            sourceRevision: sourceRevision,
            expectedHeadRevisionID: expectedHeadRevisionID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private struct RoomAIRoomPackageWire: Decodable {
    var schemaVersion: String
    var contractKind: RoomRedesignContractKind
    var packageID: String
    var profile: RoomAIRoomPackageProfile
    var sourceRevision: RoomRedesignSourceRevision
    var artifactPlanSHA256: String
    var selectionSHA256: String
    var disclosureReview: RoomDisclosureReview
    var artifacts: [RoomAIRoomPackageArtifact]

    var model: RoomAIRoomPackage {
        RoomAIRoomPackage(
            schemaVersion: schemaVersion,
            contractKind: contractKind,
            packageID: packageID,
            profile: profile,
            sourceRevision: sourceRevision,
            artifactPlanSHA256: artifactPlanSHA256,
            selectionSHA256: selectionSHA256,
            disclosureReview: disclosureReview,
            artifacts: artifacts
        )
    }
}

private struct RoomWorkingProjectSyncWire: Decodable {
    var schemaVersion: String
    var contractKind: RoomRedesignContractKind
    var operation: RoomWorkingProjectSyncOperation
    var workspaceID: String
    var projectID: String
    var expectedHostedHeadRevisionID: String
    var proposedRevision: RoomRedesignSourceRevision
    var assetPolicy: RoomWorkingProjectAssetPolicy
    var assetPlanSHA256: String
    var selectionSHA256: String
    var rawArchiveDisclosureReview: RoomDisclosureReview?
    var conflictPolicy: RoomSyncConflictPolicy
    var assets: [RoomWorkingProjectSyncAsset]

    var model: RoomWorkingProjectSync {
        RoomWorkingProjectSync(
            schemaVersion: schemaVersion,
            contractKind: contractKind,
            operation: operation,
            workspaceID: workspaceID,
            projectID: projectID,
            expectedHostedHeadRevisionID: expectedHostedHeadRevisionID,
            proposedRevision: proposedRevision,
            assetPolicy: assetPolicy,
            assetPlanSHA256: assetPlanSHA256,
            selectionSHA256: selectionSHA256,
            rawArchiveDisclosureReview: rawArchiveDisclosureReview,
            conflictPolicy: conflictPolicy,
            assets: assets
        )
    }
}

private struct RoomPortalSnapshotWire: Decodable {
    var schemaVersion: String
    var contractKind: RoomRedesignContractKind
    var snapshotID: String
    var workspaceID: String
    var projectID: String
    var sourceRevision: RoomRedesignSourceRevision
    var publishedAt: Date
    var selectionSHA256: String
    var disclosureReview: RoomDisclosureReview
    var allowlistedSections: [RoomPortalSnapshotSection]
    var assets: [RoomPortalSnapshotAsset]
    var branding: RoomPortalBranding

    var model: RoomPortalSnapshot {
        RoomPortalSnapshot(
            schemaVersion: schemaVersion,
            contractKind: contractKind,
            snapshotID: snapshotID,
            workspaceID: workspaceID,
            projectID: projectID,
            sourceRevision: sourceRevision,
            publishedAt: publishedAt,
            selectionSHA256: selectionSHA256,
            disclosureReview: disclosureReview,
            allowlistedSections: allowlistedSections,
            assets: assets,
            branding: branding
        )
    }
}

public enum RoomRedesignContractValidator {
    /// Decodes exactly one supported v1 document. It first validates the raw
    /// JSON key tree, so Codable's normal forward-compatible unknown-key
    /// behavior cannot admit private or unsupported data into these contracts.
    public static func validate(data: Data) throws -> RoomRedesignContractDocument {
        try RoomRedesignJSONMemberScanner.rejectDuplicateObjectMembers(in: data)

        let root: [String: Any]
        do {
            let value = try JSONSerialization.jsonObject(with: data)
            guard let object = value as? [String: Any] else {
                throw RoomRedesignContractValidationError.rootMustBeObject
            }
            root = object
        } catch let error as RoomRedesignContractValidationError {
            throw error
        } catch {
            throw RoomRedesignContractValidationError.invalidJSON
        }

        let schemaVersion = try RoomRedesignStrictJSON.requiredString(
            root,
            key: "schemaVersion",
            path: "$"
        )
        let rawKind = try RoomRedesignStrictJSON.requiredString(
            root,
            key: "contractKind",
            path: "$"
        )
        guard let kind = RoomRedesignContractKind(rawValue: rawKind) else {
            throw RoomRedesignContractValidationError.unknownContractKind(rawKind)
        }
        let isSlice1LocalExtension = kind == .localRedesignExtension
            && schemaVersion == RoomLocalRedesignExtensionV2.schemaVersionValue
        guard schemaVersion == kind.supportedSchemaVersion || isSlice1LocalExtension else {
            if RoomRedesignContractKind.allCases.contains(where: { $0.supportedSchemaVersion == schemaVersion }) {
                throw RoomRedesignContractValidationError.mismatchedDiscriminant(
                    schemaVersion: schemaVersion,
                    contractKind: rawKind
                )
            }
            throw RoomRedesignContractValidationError.unsupportedSchemaVersion(schemaVersion)
        }

        // Typed decoding consumes the same validated tree, not the original
        // byte stream. This avoids policy decisions being made by one parser
        // and model values being selected independently by another.
        let validatedData: Data
        do {
            validatedData = try JSONSerialization.data(
                withJSONObject: root,
                options: [.withoutEscapingSlashes]
            )
        } catch {
            throw RoomRedesignContractValidationError.invalidJSON
        }
        let decoder = RoomJSONCoding.makeDecoder()
        do {
            switch kind {
            case .localRedesignExtension:
                if isSlice1LocalExtension {
                    try RoomRedesignStrictJSON.validateLocalExtensionV2(root)
                    let model = try decoder.decode(RoomLocalRedesignExtensionV2.self, from: validatedData)
                    try model.validate()
                    return .localRedesignExtensionV2(model)
                }
                try RoomRedesignStrictJSON.validateLocalExtension(root)
                let model = try decoder.decode(RoomLocalRedesignExtensionWire.self, from: validatedData).model
                try model.validate()
                return .localRedesignExtension(model)
            case .hostedAPIResource:
                try RoomRedesignStrictJSON.validateHostedResource(root)
                let model = try decoder.decode(RoomHostedAPIResourceWire.self, from: validatedData).model
                try model.validate()
                return .hostedAPIResource(model)
            case .aiRoomPackage:
                try RoomRedesignStrictJSON.rejectPrivacyKeys(in: root, path: "$")
                try RoomRedesignStrictJSON.validateAIRoomPackage(root)
                let model = try decoder.decode(RoomAIRoomPackageWire.self, from: validatedData).model
                try model.validate()
                return .aiRoomPackage(model)
            case .workingProjectSync:
                try RoomRedesignStrictJSON.validateWorkingProjectSync(root)
                let model = try decoder.decode(RoomWorkingProjectSyncWire.self, from: validatedData).model
                try model.validate()
                return .workingProjectSync(model)
            case .portalSnapshot:
                try RoomRedesignStrictJSON.rejectPortalForbiddenKeys(in: root, path: "$")
                try RoomRedesignStrictJSON.validatePortalSnapshot(root)
                let model = try decoder.decode(RoomPortalSnapshotWire.self, from: validatedData).model
                try model.validate()
                return .portalSnapshot(model)
            }
        } catch let error as RoomRedesignContractValidationError {
            throw error
        } catch {
            throw RoomRedesignContractValidationError.invalidJSON
        }
    }

    /// Verifies one actual ZIP32 STORE archive with the existing bounded
    /// archive reader. The caller supplies an already-owned empty staging
    /// directory and remains responsible for removing it. Validation covers
    /// the outer archive identity, the exact in-archive manifest bytes, the
    /// manifest's AI-ready profile/source/plan/selection binding, and closure
    /// between every extracted entry and every included artifact ledger item.
    @discardableResult
    public static func validatePortalAIReadyDownload(
        snapshot: RoomPortalSnapshot,
        assetID: String,
        archiveURL: URL,
        extractionDirectoryURL: URL,
        limits: RoomZIPLimits = RoomZIPLimits()
    ) async throws -> RoomAIRoomPackage {
        try snapshot.validate()
        guard let asset = snapshot.assets.first(where: { $0.assetID == assetID }),
              asset.assetClass == .aiReadyPackage,
              let binding = asset.aiReadyPackageBinding
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "assetID",
                reason: "The requested portal asset is not a bound AI-ready package download."
            )
        }
        let values = try archiveURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize >= 0,
              UInt64(fileSize) == asset.byteCount,
              try RoomSHA256.hexDigest(ofFile: archiveURL) == asset.sha256
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "assets.\(assetID).sha256",
                reason: "The portal asset digest and byte count must match the validated archive bytes."
            )
        }

        let entries = try await RoomDeterministicZIP.extractVerifiedStoreEntries(
            from: archiveURL,
            into: extractionDirectoryURL,
            limits: limits,
            maximumByteCountByEntryPath: [
                binding.manifestEntryPath: UInt64(8 * 1_024 * 1_024)
            ]
        )
        guard let manifestEntry = entries.first(where: {
            $0.entryPath.value == binding.manifestEntryPath
        }) else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "assets.\(assetID).aiReadyPackageBinding.manifestEntryPath",
                reason: "The bound manifest entry is absent from the validated archive."
            )
        }
        let manifestURL = extractionDirectoryURL.appendingPathComponent(
            binding.manifestEntryPath
        )
        let extractedManifestData = try Data(contentsOf: manifestURL)
        guard RoomSHA256.hexDigest(of: extractedManifestData) == binding.manifestSHA256 else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "assets.\(assetID).aiReadyPackageBinding.manifestSHA256",
                reason: "The manifest binding must match the exact manifest bytes extracted from the archive."
            )
        }
        guard manifestEntry.sha256Hex == binding.manifestSHA256,
              manifestEntry.byteCount == UInt64(extractedManifestData.count)
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "assets.\(assetID).aiReadyPackageBinding.manifestSHA256",
                reason: "The streaming archive inspection and extracted manifest identity must agree."
            )
        }
        guard case let .aiRoomPackage(package) = try validate(data: extractedManifestData) else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "assets.\(assetID).aiReadyPackageBinding",
                reason: "The bound archive manifest must be an AI Room Package."
            )
        }
        guard package.profile == .aiReady,
              package.packageID == binding.packageID,
              package.sourceRevision == snapshot.sourceRevision,
              package.sourceRevision.revisionID == binding.sourceRevisionID,
              package.sourceRevision.revisionManifestSHA256 == binding.sourceRevisionManifestSHA256,
              package.artifactPlanSHA256 == binding.artifactPlanSHA256,
              package.selectionSHA256 == binding.selectionSHA256
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "assets.\(assetID).aiReadyPackageBinding",
                reason: "The extracted package manifest must be AI-ready and match every reviewed source and selection binding."
            )
        }

        let includedArtifacts = package.artifacts.filter { $0.disposition == .included }
        let expectedEntryPaths = Set(
            [binding.manifestEntryPath] + includedArtifacts.compactMap(\.relativePath)
        )
        let actualEntryPaths = Set(entries.map { $0.entryPath.value })
        guard expectedEntryPaths == actualEntryPaths,
              expectedEntryPaths.count == includedArtifacts.count + 1
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "assets.\(assetID).aiReadyPackageBinding",
                reason: "The AI-ready archive must contain exactly its manifest and included artifact ledger, with no hidden or missing entries."
            )
        }
        let entriesByPath: [String: RoomZIPEntryDigest] = Dictionary(uniqueKeysWithValues: entries.map {
            ($0.entryPath.value, $0)
        })
        for artifact in includedArtifacts {
            guard let relativePath = artifact.relativePath,
                  let expectedSHA256 = artifact.sha256,
                  let expectedByteCount = artifact.byteCount,
                  let entry = entriesByPath[relativePath],
                  entry.sha256Hex == expectedSHA256,
                  entry.byteCount == expectedByteCount
            else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: "assets.\(assetID).aiReadyPackageBinding",
                    reason: "Every included AI-ready artifact must match its extracted path, SHA-256, and byte count."
                )
            }
        }
        return package
    }
}

/// Canonical digest helpers for v1 producers. These values are manifest facts:
/// a review is valid only for the exact source-bound plan and selected ledger
/// that produced the digest.
public enum RoomRedesignContractDigests {
    public static func aiArtifactPlanSHA256(
        sourceRevision: RoomRedesignSourceRevision,
        profile: RoomAIRoomPackageProfile
    ) throws -> String {
        try RoomRedesignContractRules.aiArtifactPlanDigest(
            sourceRevision: sourceRevision,
            profile: profile
        )
    }

    public static func aiSelectionSHA256(
        artifacts: [RoomAIRoomPackageArtifact]
    ) throws -> String {
        try RoomRedesignContractRules.selectionDigest(artifacts: artifacts)
    }

    public static func workingSyncAssetPlanSHA256(
        proposedRevision: RoomRedesignSourceRevision,
        assetPolicy: RoomWorkingProjectAssetPolicy
    ) throws -> String {
        try RoomRedesignContractRules.workingSyncAssetPlanDigest(
            proposedRevision: proposedRevision,
            assetPolicy: assetPolicy
        )
    }

    public static func workingSyncSelectionSHA256(
        assets: [RoomWorkingProjectSyncAsset]
    ) throws -> String {
        try RoomRedesignContractRules.selectionDigest(assets: assets)
    }

    public static func portalSnapshotSelectionSHA256(
        allowlistedSections: [RoomPortalSnapshotSection],
        assets: [RoomPortalSnapshotAsset],
        branding: RoomPortalBranding
    ) throws -> String {
        try RoomRedesignContractRules.selectionDigest(
            portalSections: allowlistedSections,
            portalAssets: assets,
            branding: branding
        )
    }

    /// Computes a portal projection digest without requiring an already valid
    /// inbound snapshot. This is intended for producers constructing a new
    /// reviewed snapshot and for cross-language golden fixtures.
    public static func portalSnapshotSelectionSHA256(
        allowlistedSections: [RoomPortalSnapshotSection],
        assets: [RoomPortalSnapshotAsset],
        displayName: String,
        accentColorHex: String?
    ) throws -> String {
        try RoomRedesignContractRules.selectionDigest(
            portalSections: allowlistedSections,
            portalAssets: assets,
            branding: RoomPortalBranding(
                displayName: displayName,
                accentColorHex: accentColorHex
            )
        )
    }
}

/// A small validating JSON lexer used only to reject duplicate object member
/// names before Foundation materializes an object dictionary. It decodes JSON
/// string escapes (including surrogate pairs) so `"kind"` and
/// `"k\u0069nd"` have the same identity. Syntax and scalar validity remain
/// the responsibility of `JSONSerialization` immediately afterward.
private enum RoomRedesignJSONMemberScanner {
    private enum Container {
        case object(keys: Set<String>, expectsKey: Bool)
        case array
    }

    static func rejectDuplicateObjectMembers(in data: Data) throws {
        guard let source = String(data: data, encoding: .utf8) else {
            throw RoomRedesignContractValidationError.invalidJSON
        }
        let scalars = Array(source.unicodeScalars)
        var stack: [Container] = []
        var index = 0

        while index < scalars.count {
            switch scalars[index].value {
            case 0x22: // quotation mark
                let start = index
                let value = try parseString(scalars, index: &index)
                if case let .object(keys, expectsKey)? = stack.last, expectsKey {
                    var lookahead = index
                    skipWhitespace(scalars, index: &lookahead)
                    guard lookahead < scalars.count, scalars[lookahead].value == 0x3A else {
                        // Foundation will report malformed JSON. This string
                        // is a value, or the document is invalid syntax.
                        index = max(index, start + 1)
                        continue
                    }
                    guard !keys.contains(value) else {
                        throw RoomRedesignContractValidationError.duplicateKey(
                            path: objectPath(depth: stack.count),
                            key: value
                        )
                    }
                    var updated = keys
                    updated.insert(value)
                    stack[stack.count - 1] = .object(keys: updated, expectsKey: false)
                }
            case 0x7B: // {
                stack.append(.object(keys: [], expectsKey: true))
                index += 1
            case 0x7D: // }
                if !stack.isEmpty { stack.removeLast() }
                index += 1
            case 0x5B: // [
                stack.append(.array)
                index += 1
            case 0x5D: // ]
                if !stack.isEmpty { stack.removeLast() }
                index += 1
            case 0x2C: // ,
                if case let .object(keys, _)? = stack.last {
                    stack[stack.count - 1] = .object(keys: keys, expectsKey: true)
                }
                index += 1
            default:
                index += 1
            }
        }
    }

    private static func parseString(
        _ scalars: [UnicodeScalar],
        index: inout Int
    ) throws -> String {
        index += 1 // opening quote
        var output = ""
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar.value == 0x22 {
                index += 1
                return output
            }
            if scalar.value != 0x5C {
                output.unicodeScalars.append(scalar)
                index += 1
                continue
            }

            index += 1
            guard index < scalars.count else {
                throw RoomRedesignContractValidationError.invalidJSON
            }
            let escaped = scalars[index]
            switch escaped.value {
            case 0x22, 0x5C, 0x2F:
                output.unicodeScalars.append(escaped)
                index += 1
            case 0x62:
                output.unicodeScalars.append("\u{8}")
                index += 1
            case 0x66:
                output.unicodeScalars.append("\u{C}")
                index += 1
            case 0x6E:
                output.unicodeScalars.append("\n")
                index += 1
            case 0x72:
                output.unicodeScalars.append("\r")
                index += 1
            case 0x74:
                output.unicodeScalars.append("\t")
                index += 1
            case 0x75:
                index += 1
                let first = try parseHexQuad(scalars, index: &index)
                if (0xD800...0xDBFF).contains(first) {
                    guard index + 1 < scalars.count,
                          scalars[index].value == 0x5C,
                          scalars[index + 1].value == 0x75
                    else {
                        throw RoomRedesignContractValidationError.invalidJSON
                    }
                    index += 2
                    let second = try parseHexQuad(scalars, index: &index)
                    guard (0xDC00...0xDFFF).contains(second) else {
                        throw RoomRedesignContractValidationError.invalidJSON
                    }
                    let value = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                    guard let decoded = UnicodeScalar(value) else {
                        throw RoomRedesignContractValidationError.invalidJSON
                    }
                    output.unicodeScalars.append(decoded)
                } else {
                    guard !(0xDC00...0xDFFF).contains(first),
                          let decoded = UnicodeScalar(first)
                    else {
                        throw RoomRedesignContractValidationError.invalidJSON
                    }
                    output.unicodeScalars.append(decoded)
                }
            default:
                throw RoomRedesignContractValidationError.invalidJSON
            }
        }
        throw RoomRedesignContractValidationError.invalidJSON
    }

    private static func parseHexQuad(
        _ scalars: [UnicodeScalar],
        index: inout Int
    ) throws -> UInt32 {
        guard index + 4 <= scalars.count else {
            throw RoomRedesignContractValidationError.invalidJSON
        }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let digit: UInt32
            switch scalars[index].value {
            case 0x30...0x39: digit = scalars[index].value - 0x30
            case 0x41...0x46: digit = scalars[index].value - 0x41 + 10
            case 0x61...0x66: digit = scalars[index].value - 0x61 + 10
            default: throw RoomRedesignContractValidationError.invalidJSON
            }
            value = (value << 4) | digit
            index += 1
        }
        return value
    }

    private static func skipWhitespace(_ scalars: [UnicodeScalar], index: inout Int) {
        while index < scalars.count,
              [0x20, 0x09, 0x0A, 0x0D].contains(scalars[index].value) {
            index += 1
        }
    }

    private static func objectPath(depth: Int) -> String {
        depth <= 1 ? "$" : "$<object-depth-\(depth)>"
    }
}

private enum RoomRedesignContractRules {
    static let maximumCollectionCount = 1_000
    static let maximumCoordinateMagnitudeMeters = 10_000.0
    static let maximumResourceVersion: UInt64 = 1_000_000_000
    static let maximumAssetByteCount: UInt64 = 1_099_511_627_776
    static let hexadecimalScalars = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
    private static let lowercaseHexadecimalScalars = CharacterSet(charactersIn: "0123456789abcdef")
    static func aiArtifactPlanSlots(profile: RoomAIRoomPackageProfile) -> [RoomRedesignArtifactClass] {
        let common: [RoomRedesignArtifactClass] = [
            .normalizedSemantics,
            .orientation,
            .floorPlan,
            .canonicalView,
            .selectedReferenceImage,
            .materials,
            .qualityReport,
            .roomBrief,
            .redesignIntent,
            .providerInstructions,
            .mesh,
            .texture,
            .conceptAttachment
        ]
        // Both profiles have an honest ledger slot for raw evidence. AI-ready
        // must explicitly mark those slots non-included; Complete may include
        // them after review. This lets a raw-default guard be exercised rather
        // than hidden behind an omitted-slot failure.
        return common + [.rawRGB, .rawDepth, .rawConfidence, .diagnostics]
    }

    static func workingSyncAssetPlanSlots(
        assetPolicy: RoomWorkingProjectAssetPolicy
    ) -> [RoomRedesignArtifactClass] {
        // A policy alters permissions and the source-bound plan digest, not
        // whether the ledger admits silent omission. World maps remain private
        // to AI and portals but may be represented only as an explicitly
        // reviewed raw-archive sync asset.
        let workingSet = [
            RoomRedesignArtifactClass.normalizedSemantics,
            .revisionLineage,
            .selectedReferenceImage,
            .mesh,
            .texture,
            .conceptAttachment,
            .comments
        ]
        switch assetPolicy {
        case .workingSet:
            return workingSet
        case .rawArchiveOptIn:
            return workingSet + [.rawRGB, .rawDepth, .rawConfidence, .diagnostics, .worldMap]
        }
    }

    static func requireEnvelope(
        schemaVersion: String,
        contractKind: RoomRedesignContractKind,
        expected: RoomRedesignContractKind
    ) throws {
        guard contractKind == expected, schemaVersion == expected.supportedSchemaVersion else {
            throw RoomRedesignContractValidationError.mismatchedDiscriminant(
                schemaVersion: schemaVersion,
                contractKind: contractKind.rawValue
            )
        }
    }

    static func requireIdentifier(_ value: String, at path: String) throws {
        guard RoomPathValidation.isSafeStableIdentifier(value) else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: path,
                reason: "Value must be a stable identifier using only ASCII letters, numbers, hyphens, or underscores."
            )
        }
    }

    static func requireRelativePath(_ value: String, at path: String) throws {
        guard RoomPathValidation.isSafeRelativePath(value),
              value.unicodeScalars.allSatisfy({
                  $0.isASCII && !CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: path,
                reason: "Value must be a safe non-empty portable-ASCII relative path."
            )
        }
    }

    static func requireUniqueRelativePaths(_ values: [String], at path: String) throws {
        // V1 paths are portable ASCII. ASCII case folding is therefore a
        // stable cross-language identity and avoids both case-insensitive file
        // aliases and Unicode-normalization aliases at materialization time.
        let identities = values.map { $0.lowercased() }
        try requireUnique(identities, at: path)
    }

    static func requireSHA256(_ value: String, at path: String) throws {
        guard value.count == 64, value.unicodeScalars.allSatisfy(lowercaseHexadecimalScalars.contains) else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: path,
                reason: "Value must be a lowercase 64-character SHA-256 digest."
            )
        }
    }

    static func requireText(_ value: String, minimum: Int, maximum: Int, at path: String) throws {
        guard value.count >= minimum, value.count <= maximum,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: path,
                reason: "Text must be bounded and must not contain control characters."
            )
        }
    }

    static func requireFinite(_ value: Double, minimum: Double, maximum: Double, at path: String) throws {
        guard value.isFinite, value >= minimum, value <= maximum else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: path,
                reason: "Numeric values must be finite and within contract bounds."
            )
        }
    }

    static func requireUnitInterval(_ value: Double, at path: String) throws {
        try requireFinite(value, minimum: 0, maximum: 1, at: path)
    }

    static func requirePoint(_ value: RoomRedesignVector3, at path: String) throws {
        try requireFinite(value.x, minimum: -maximumCoordinateMagnitudeMeters, maximum: maximumCoordinateMagnitudeMeters, at: "\(path).x")
        try requireFinite(value.y, minimum: -maximumCoordinateMagnitudeMeters, maximum: maximumCoordinateMagnitudeMeters, at: "\(path).y")
        try requireFinite(value.z, minimum: -maximumCoordinateMagnitudeMeters, maximum: maximumCoordinateMagnitudeMeters, at: "\(path).z")
    }

    static func requireUnitVector(_ value: RoomRedesignVector3, at path: String) throws {
        try requirePoint(value, at: path)
        let vectorLength = length(value)
        guard vectorLength >= 0.95, vectorLength <= 1.05 else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: path,
                reason: "Direction vectors must be normalized within tolerance."
            )
        }
    }

    static func length(_ value: RoomRedesignVector3) -> Double {
        sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
    }

    static func dot(_ first: RoomRedesignVector3, _ second: RoomRedesignVector3) -> Double {
        first.x * second.x + first.y * second.y + first.z * second.z
    }

    static func requireDate(_ value: Date, at path: String) throws {
        guard value.timeIntervalSinceReferenceDate.isFinite else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: path,
                reason: "Dates must be finite."
            )
        }
    }

    static func requireCount(_ value: Int, maximum: Int, at path: String) throws {
        guard value >= 0, value <= maximum else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: path,
                reason: "Collection count exceeds the contract bound."
            )
        }
    }

    static func requireNonemptyCount(_ value: Int, maximum: Int, at path: String) throws {
        guard value > 0 else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: path,
                reason: "Collection must not be empty."
            )
        }
        try requireCount(value, maximum: maximum, at: path)
    }

    static func requireUnique<T: Hashable>(_ values: [T], at path: String) throws {
        guard Set(values).count == values.count else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: path,
                reason: "Identifiers must be unique."
            )
        }
    }

    static func requireByteCount(_ value: UInt64, at path: String) throws {
        guard value > 0, value <= maximumAssetByteCount else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: path,
                reason: "Byte counts must be positive and bounded."
            )
        }
    }

    static func requireMediaType(_ value: String, at path: String) throws {
        guard value.count <= 127,
              value.contains("/"),
              value.unicodeScalars.allSatisfy({
                  $0.isASCII && !CharacterSet.controlCharacters.contains($0) && $0 != " "
              })
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: path,
                reason: "Media types must be bounded printable ASCII type/subtype values."
            )
        }
    }

    static func validateAssetState(
        disposition: RoomArtifactDisposition,
        relativePath: String?,
        sha256: String?,
        byteCount: UInt64?,
        mediaType: String?,
        reasonCode: String?,
        at path: String
    ) throws {
        switch disposition {
        case .included:
            guard let relativePath, let sha256, let byteCount, let mediaType else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: path,
                    reason: "Included artifacts require path, SHA-256, byte count, and media type."
                )
            }
            guard reasonCode == nil else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: "\(path).reasonCode",
                    reason: "Included artifacts cannot claim an exclusion reason."
                )
            }
            try requireRelativePath(relativePath, at: "\(path).relativePath")
            try requireSHA256(sha256, at: "\(path).sha256")
            try requireByteCount(byteCount, at: "\(path).byteCount")
            try requireMediaType(mediaType, at: "\(path).mediaType")
        case .excluded, .skipped, .unavailable, .failed:
            guard relativePath == nil, sha256 == nil, byteCount == nil, mediaType == nil,
                  let reasonCode
            else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: path,
                    reason: "Non-included artifacts require a reason and cannot carry transferable asset bytes."
                )
            }
            try requireIdentifier(reasonCode, at: "\(path).reasonCode")
        }
    }

    static func selectionDigest(artifacts: [RoomAIRoomPackageArtifact]) throws -> String {
        let ledger: [[String: Any]] = artifacts.sorted { $0.artifactID < $1.artifactID }.map { artifact in
            var object: [String: Any] = [
                "artifactID": artifact.artifactID,
                "artifactClass": artifact.artifactClass.rawValue,
                "disposition": artifact.disposition.rawValue
            ]
            if let relativePath = artifact.relativePath { object["relativePath"] = relativePath }
            if let sha256 = artifact.sha256 { object["sha256"] = sha256 }
            if let byteCount = artifact.byteCount { object["byteCount"] = NSNumber(value: byteCount) }
            if let mediaType = artifact.mediaType { object["mediaType"] = mediaType }
            if let reasonCode = artifact.reasonCode { object["reasonCode"] = reasonCode }
            return object
        }
        return try canonicalDigest(ledger)
    }

    static func selectionDigest(assets: [RoomWorkingProjectSyncAsset]) throws -> String {
        let ledger: [[String: Any]] = assets.sorted { $0.assetID < $1.assetID }.map { asset in
            var object: [String: Any] = [
                "assetID": asset.assetID,
                "assetClass": asset.assetClass.rawValue,
                "disposition": asset.disposition.rawValue
            ]
            if let relativePath = asset.relativePath { object["relativePath"] = relativePath }
            if let sha256 = asset.sha256 { object["sha256"] = sha256 }
            if let byteCount = asset.byteCount { object["byteCount"] = NSNumber(value: byteCount) }
            if let mediaType = asset.mediaType { object["mediaType"] = mediaType }
            if let reasonCode = asset.reasonCode { object["reasonCode"] = reasonCode }
            return object
        }
        return try canonicalDigest(ledger)
    }

    static func selectionDigest(
        portalSections: [RoomPortalSnapshotSection],
        portalAssets: [RoomPortalSnapshotAsset],
        branding: RoomPortalBranding
    ) throws -> String {
        let sections = portalSections.map(\.rawValue).sorted()
        let assets = portalAssets.sorted { $0.assetID < $1.assetID }.map { asset in
            var object = [
                "assetID": asset.assetID,
                "assetClass": asset.assetClass.rawValue,
                "relativePath": asset.relativePath,
                "sha256": asset.sha256,
                "byteCount": NSNumber(value: asset.byteCount),
                "mediaType": asset.mediaType
            ] as [String: Any]
            if let binding = asset.aiReadyPackageBinding {
                object["aiReadyPackageBinding"] = [
                    "packageID": binding.packageID,
                    "profile": binding.profile.rawValue,
                    "manifestEntryPath": binding.manifestEntryPath,
                    "manifestSHA256": binding.manifestSHA256,
                    "sourceRevisionID": binding.sourceRevisionID,
                    "sourceRevisionManifestSHA256": binding.sourceRevisionManifestSHA256,
                    "artifactPlanSHA256": binding.artifactPlanSHA256,
                    "selectionSHA256": binding.selectionSHA256
                ]
            }
            return object
        }
        var brandingObject: [String: Any] = ["displayName": branding.displayName]
        if let accentColorHex = branding.accentColorHex {
            brandingObject["accentColorHex"] = accentColorHex
        }
        return try canonicalDigest([
            "allowlistedSections": sections,
            "assets": assets,
            "branding": brandingObject
        ])
    }

    static func aiArtifactPlanDigest(
        sourceRevision: RoomRedesignSourceRevision,
        profile: RoomAIRoomPackageProfile
    ) throws -> String {
        try canonicalDigest([
            "schemaVersion": RoomRedesignContractKind.aiRoomPackage.supportedSchemaVersion,
            "contractKind": RoomRedesignContractKind.aiRoomPackage.rawValue,
            "profile": profile.rawValue,
            "sourceRevision": sourceRevisionObject(sourceRevision),
            "artifactClasses": aiArtifactPlanSlots(profile: profile).map(\.rawValue).sorted()
        ])
    }

    static func workingSyncAssetPlanDigest(
        proposedRevision: RoomRedesignSourceRevision,
        assetPolicy: RoomWorkingProjectAssetPolicy
    ) throws -> String {
        try canonicalDigest([
            "schemaVersion": RoomRedesignContractKind.workingProjectSync.supportedSchemaVersion,
            "contractKind": RoomRedesignContractKind.workingProjectSync.rawValue,
            "assetPolicy": assetPolicy.rawValue,
            "proposedRevision": sourceRevisionObject(proposedRevision),
            "assetClasses": workingSyncAssetPlanSlots(assetPolicy: assetPolicy).map(\.rawValue).sorted()
        ])
    }

    private static func sourceRevisionObject(_ sourceRevision: RoomRedesignSourceRevision) -> [String: Any] {
        [
            "projectID": sourceRevision.projectID,
            "revisionID": sourceRevision.revisionID,
            "coordinateSpaceEpochID": sourceRevision.coordinateSpaceEpochID,
            "packageSchemaVersion": sourceRevision.packageSchemaVersion,
            "semanticSHA256": sourceRevision.semanticSHA256,
            "revisionManifestSHA256": sourceRevision.revisionManifestSHA256
        ]
    }

    private static func canonicalDigest(_ object: Any) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw RoomRedesignContractValidationError.invalidJSON
        }
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return RoomSHA256.hexDigest(of: data)
    }
}

private enum RoomRedesignStrictJSON {
    private static let sourceRevisionKeys: Set<String> = [
        "projectID", "revisionID", "coordinateSpaceEpochID", "packageSchemaVersion", "semanticSHA256", "revisionManifestSHA256"
    ]
    private static let vectorKeys: Set<String> = ["x", "y", "z"]
    private static let disclosureReviewKeys: Set<String> = [
        "reviewID", "reviewedAt", "decision", "sourceRevisionID", "sourceRevisionManifestSHA256", "reviewedArtifactPlanSHA256", "reviewedSelectionSHA256", "preciseGPSExcluded", "rawEvidenceDisclosureAccepted"
    ]
    private static let artifactKeys: Set<String> = [
        "artifactID", "artifactClass", "disposition", "relativePath", "sha256", "byteCount", "mediaType", "reasonCode"
    ]
    private static let syncAssetKeys: Set<String> = [
        "assetID", "assetClass", "disposition", "relativePath", "sha256", "byteCount", "mediaType", "reasonCode"
    ]

    static func validateLocalExtension(_ root: [String: Any]) throws {
        let root = try object(
            root,
            allowed: [
                "schemaVersion", "contractKind", "sourceRevision", "orientation", "redesignIntent", "propertyMembership", "conceptMetadata"
            ],
            required: [
                "schemaVersion", "contractKind", "sourceRevision", "orientation", "redesignIntent", "propertyMembership", "conceptMetadata"
            ],
            path: "$"
        )
        try validateSourceRevision(try requiredObject(root, key: "sourceRevision", path: "$"), path: "$.sourceRevision")

        let orientation = try object(
            try requiredObject(root, key: "orientation", path: "$"),
            allowed: [
                "source", "confidence", "coordinateSpaceEpochID", "entryPositionMeters", "inwardDirection", "canonicalAxes", "canonicalCameras"
            ],
            required: [
                "source", "confidence", "coordinateSpaceEpochID", "entryPositionMeters", "inwardDirection", "canonicalAxes", "canonicalCameras"
            ],
            path: "$.orientation"
        )
        try validateVector(try requiredObject(orientation, key: "entryPositionMeters", path: "$.orientation"), path: "$.orientation.entryPositionMeters")
        try validateVector(try requiredObject(orientation, key: "inwardDirection", path: "$.orientation"), path: "$.orientation.inwardDirection")
        let axes = try object(
            try requiredObject(orientation, key: "canonicalAxes", path: "$.orientation"),
            allowed: ["right", "up", "forward"],
            required: ["right", "up", "forward"],
            path: "$.orientation.canonicalAxes"
        )
        for key in ["right", "up", "forward"] {
            try validateVector(
                try requiredObject(axes, key: key, path: "$.orientation.canonicalAxes"),
                path: "$.orientation.canonicalAxes.\(key)"
            )
        }
        let cameras = try requiredArray(orientation, key: "canonicalCameras", path: "$.orientation")
        for (index, value) in cameras.enumerated() {
            let camera = try object(
                value,
                allowed: ["cameraID", "role", "positionMeters", "targetMeters", "fieldOfViewDegrees"],
                required: ["cameraID", "role", "positionMeters", "targetMeters", "fieldOfViewDegrees"],
                path: "$.orientation.canonicalCameras[\(index)]"
            )
            try validateVector(
                try requiredObject(camera, key: "positionMeters", path: "$.orientation.canonicalCameras[\(index)]"),
                path: "$.orientation.canonicalCameras[\(index)].positionMeters"
            )
            try validateVector(
                try requiredObject(camera, key: "targetMeters", path: "$.orientation.canonicalCameras[\(index)]"),
                path: "$.orientation.canonicalCameras[\(index)].targetMeters"
            )
        }

        let intent = try object(
            try requiredObject(root, key: "redesignIntent", path: "$"),
            allowed: ["request", "scope", "permissions"],
            required: ["request", "scope", "permissions"],
            path: "$.redesignIntent"
        )
        let permissions = try requiredArray(intent, key: "permissions", path: "$.redesignIntent")
        for (index, value) in permissions.enumerated() {
            _ = try object(
                value,
                allowed: ["featureID", "permission"],
                required: ["featureID", "permission"],
                path: "$.redesignIntent.permissions[\(index)]"
            )
        }

        _ = try object(
            try requiredObject(root, key: "propertyMembership", path: "$"),
            allowed: ["propertyID", "roomProjectIDs"],
            required: ["propertyID", "roomProjectIDs"],
            path: "$.propertyMembership"
        )
        _ = try requiredArray(
            try requiredObject(root, key: "propertyMembership", path: "$"),
            key: "roomProjectIDs",
            path: "$.propertyMembership"
        )

        let concepts = try requiredArray(root, key: "conceptMetadata", path: "$")
        for (index, value) in concepts.enumerated() {
            let concept = try object(
                value,
                allowed: [
                    "conceptSetID", "sourceRevisionID", "sourceSemanticSHA256", "sourceRevisionManifestSHA256", "scope", "mappingStatus", "attachments"
                ],
                required: [
                    "conceptSetID", "sourceRevisionID", "sourceSemanticSHA256", "sourceRevisionManifestSHA256", "scope", "mappingStatus", "attachments"
                ],
                path: "$.conceptMetadata[\(index)]"
            )
            let attachments = try requiredArray(concept, key: "attachments", path: "$.conceptMetadata[\(index)]")
            for (attachmentIndex, attachment) in attachments.enumerated() {
                _ = try object(
                    attachment,
                    allowed: ["relativePath", "sha256", "byteCount", "mediaType"],
                    required: ["relativePath", "sha256", "byteCount", "mediaType"],
                    path: "$.conceptMetadata[\(index)].attachments[\(attachmentIndex)]"
                )
            }
        }
    }

    static func validateLocalExtensionV2(_ root: [String: Any]) throws {
        let root = try object(
            root,
            allowed: [
                "schemaVersion", "contractKind", "sourceRevision", "orientation",
                "redesignIntent", "propertyMembership", "conceptMetadata",
            ],
            required: ["schemaVersion", "contractKind", "sourceRevision", "orientation", "conceptMetadata"],
            path: "$"
        )
        try validateSourceRevision(
            try requiredObject(root, key: "sourceRevision", path: "$"),
            path: "$.sourceRevision"
        )

        let orientation = try object(
            try requiredObject(root, key: "orientation", path: "$"),
            allowed: [
                "source", "confidence", "coordinateSpaceEpochID", "entryPositionMeters",
                "inwardDirection", "canonicalAxes", "topDownOrientation", "canonicalCameras",
                "entryFeatureID", "referenceWallFeatureID", "suggestionEvidence",
            ],
            required: [
                "source", "confidence", "coordinateSpaceEpochID", "entryPositionMeters",
                "inwardDirection", "canonicalAxes", "topDownOrientation", "canonicalCameras",
            ],
            path: "$.orientation"
        )
        try validateVector(
            try requiredObject(orientation, key: "entryPositionMeters", path: "$.orientation"),
            path: "$.orientation.entryPositionMeters"
        )
        try validateVector(
            try requiredObject(orientation, key: "inwardDirection", path: "$.orientation"),
            path: "$.orientation.inwardDirection"
        )
        let axes = try object(
            try requiredObject(orientation, key: "canonicalAxes", path: "$.orientation"),
            allowed: ["right", "up", "forward"],
            required: ["right", "up", "forward"],
            path: "$.orientation.canonicalAxes"
        )
        for key in ["right", "up", "forward"] {
            try validateVector(
                try requiredObject(axes, key: key, path: "$.orientation.canonicalAxes"),
                path: "$.orientation.canonicalAxes.\(key)"
            )
        }
        let topDown = try object(
            try requiredObject(orientation, key: "topDownOrientation", path: "$.orientation"),
            allowed: ["upAxis", "screenUp", "presentationTransform"],
            required: ["upAxis", "screenUp"],
            path: "$.orientation.topDownOrientation"
        )
        try validateVector(
            try requiredObject(topDown, key: "screenUp", path: "$.orientation.topDownOrientation"),
            path: "$.orientation.topDownOrientation.screenUp"
        )
        if let presentation = try optionalObject(
            topDown,
            key: "presentationTransform",
            path: "$.orientation.topDownOrientation"
        ) {
            _ = try object(
                presentation,
                allowed: ["quarterTurnsClockwise", "isMirroredHorizontally"],
                required: ["quarterTurnsClockwise", "isMirroredHorizontally"],
                path: "$.orientation.topDownOrientation.presentationTransform"
            )
        }
        let cameras = try requiredArray(orientation, key: "canonicalCameras", path: "$.orientation")
        for (index, value) in cameras.enumerated() {
            let path = "$.orientation.canonicalCameras[\(index)]"
            let camera = try object(
                value,
                allowed: ["cameraID", "role", "positionMeters", "targetMeters", "fieldOfViewDegrees"],
                required: ["cameraID", "role", "positionMeters", "targetMeters", "fieldOfViewDegrees"],
                path: path
            )
            try validateVector(try requiredObject(camera, key: "positionMeters", path: path), path: "\(path).positionMeters")
            try validateVector(try requiredObject(camera, key: "targetMeters", path: path), path: "\(path).targetMeters")
        }
        if let evidence = try optionalObject(orientation, key: "suggestionEvidence", path: "$.orientation") {
            _ = try object(
                evidence,
                allowed: ["featureID", "semanticRole", "usedScanStartPose", "usedDoorOrOpening", "scanStartPose"],
                required: ["featureID", "semanticRole", "usedScanStartPose", "usedDoorOrOpening"],
                path: "$.orientation.suggestionEvidence"
            )
            if let scanStartPose = try optionalObject(
                evidence,
                key: "scanStartPose",
                path: "$.orientation.suggestionEvidence"
            ) {
                let path = "$.orientation.suggestionEvidence.scanStartPose"
                let pose = try object(
                    scanStartPose,
                    allowed: ["positionMeters", "forwardDirection", "coordinateSpaceEpochID"],
                    required: ["positionMeters", "forwardDirection", "coordinateSpaceEpochID"],
                    path: path
                )
                try validateVector(try requiredObject(pose, key: "positionMeters", path: path), path: "\(path).positionMeters")
                try validateVector(try requiredObject(pose, key: "forwardDirection", path: path), path: "\(path).forwardDirection")
            }
        }

        if let intent = try optionalObject(root, key: "redesignIntent", path: "$") {
            let intent = try object(
                intent,
                allowed: ["request", "scope", "constraints", "permissions"],
                required: ["request", "scope", "permissions"],
                path: "$.redesignIntent"
            )
            if let constraints = try optionalObject(intent, key: "constraints", path: "$.redesignIntent") {
                let constraints = try object(
                    constraints,
                    allowed: [
                        "purpose", "style", "budget", "householdNeeds", "accessibility",
                        "circulation", "materials", "colors", "referenceImageIDs", "desiredObjects",
                    ],
                    required: [
                        "purpose", "style", "householdNeeds", "accessibility", "circulation",
                        "materials", "colors", "referenceImageIDs", "desiredObjects",
                    ],
                    path: "$.redesignIntent.constraints"
                )
                for key in [
                    "purpose", "style", "householdNeeds", "accessibility", "circulation",
                    "materials", "colors", "referenceImageIDs", "desiredObjects",
                ] {
                    _ = try requiredArray(constraints, key: key, path: "$.redesignIntent.constraints")
                }
            }
            let permissions = try requiredArray(intent, key: "permissions", path: "$.redesignIntent")
            for (index, value) in permissions.enumerated() {
                _ = try object(
                    value,
                    allowed: ["featureID", "permission"],
                    required: ["featureID", "permission"],
                    path: "$.redesignIntent.permissions[\(index)]"
                )
            }
        }

        if let membership = try optionalObject(root, key: "propertyMembership", path: "$") {
            let membership = try object(
                membership,
                allowed: ["propertyID", "roomProjectIDs"],
                required: ["propertyID", "roomProjectIDs"],
                path: "$.propertyMembership"
            )
            _ = try requiredArray(membership, key: "roomProjectIDs", path: "$.propertyMembership")
        }

        let concepts = try requiredArray(root, key: "conceptMetadata", path: "$")
        for (index, value) in concepts.enumerated() {
            let path = "$.conceptMetadata[\(index)]"
            let concept = try object(
                value,
                allowed: [
                    "conceptSetID", "sourceRevision", "request", "scope", "provider",
                    "sourceAIRoomPackageSchemaVersion", "sourceAIRoomPackageID", "createdAt",
                    "importedAt", "mappingStatus", "attachments", "comments", "approvalState",
                    "archiveState",
                ],
                required: [
                    "conceptSetID", "sourceRevision", "request", "scope", "provider",
                    "sourceAIRoomPackageSchemaVersion", "sourceAIRoomPackageID", "createdAt",
                    "importedAt", "mappingStatus", "attachments", "comments", "approvalState",
                    "archiveState",
                ],
                path: path
            )
            try validateSourceRevision(try requiredObject(concept, key: "sourceRevision", path: path), path: "\(path).sourceRevision")
            try requireUTCTimestamp(concept, key: "createdAt", path: path)
            try requireUTCTimestamp(concept, key: "importedAt", path: path)
            let attachments = try requiredArray(concept, key: "attachments", path: path)
            for (attachmentIndex, attachment) in attachments.enumerated() {
                _ = try object(
                    attachment,
                    allowed: ["relativePath", "sha256", "byteCount", "mediaType"],
                    required: ["relativePath", "sha256", "byteCount", "mediaType"],
                    path: "\(path).attachments[\(attachmentIndex)]"
                )
            }
            _ = try requiredArray(concept, key: "comments", path: path)
        }
    }

    static func validateHostedResource(_ root: [String: Any]) throws {
        let root = try object(
            root,
            allowed: [
                "schemaVersion", "contractKind", "resourceType", "resourceID", "workspaceID", "projectID", "revisionID", "version", "lifecycleState", "sourceRevision", "expectedHeadRevisionID", "createdAt", "updatedAt"
            ],
            required: [
                "schemaVersion", "contractKind", "resourceType", "resourceID", "workspaceID", "version", "lifecycleState", "createdAt", "updatedAt"
            ],
            path: "$"
        )
        try requireUTCTimestamp(root, key: "createdAt", path: "$")
        try requireUTCTimestamp(root, key: "updatedAt", path: "$")
        if let source = try optionalObject(root, key: "sourceRevision", path: "$") {
            try validateSourceRevision(source, path: "$.sourceRevision")
        }
    }

    static func validateAIRoomPackage(_ root: [String: Any]) throws {
        let root = try object(
            root,
            allowed: ["schemaVersion", "contractKind", "packageID", "profile", "sourceRevision", "artifactPlanSHA256", "selectionSHA256", "disclosureReview", "artifacts"],
            required: ["schemaVersion", "contractKind", "packageID", "profile", "sourceRevision", "artifactPlanSHA256", "selectionSHA256", "disclosureReview", "artifacts"],
            path: "$"
        )
        try validateSourceRevision(try requiredObject(root, key: "sourceRevision", path: "$"), path: "$.sourceRevision")
        try validateDisclosureReview(
            try requiredObject(root, key: "disclosureReview", path: "$"),
            path: "$.disclosureReview"
        )
        let artifacts = try requiredArray(root, key: "artifacts", path: "$")
        for (index, value) in artifacts.enumerated() {
            _ = try object(
                value,
                allowed: artifactKeys,
                required: ["artifactID", "artifactClass", "disposition"],
                path: "$.artifacts[\(index)]"
            )
        }
    }

    static func validateWorkingProjectSync(_ root: [String: Any]) throws {
        let root = try object(
            root,
            allowed: [
                "schemaVersion", "contractKind", "operation", "workspaceID", "projectID", "expectedHostedHeadRevisionID", "proposedRevision", "assetPolicy", "assetPlanSHA256", "selectionSHA256", "rawArchiveDisclosureReview", "conflictPolicy", "assets"
            ],
            required: [
                "schemaVersion", "contractKind", "operation", "workspaceID", "projectID", "expectedHostedHeadRevisionID", "proposedRevision", "assetPolicy", "assetPlanSHA256", "selectionSHA256", "conflictPolicy", "assets"
            ],
            path: "$"
        )
        try validateSourceRevision(try requiredObject(root, key: "proposedRevision", path: "$"), path: "$.proposedRevision")
        if let review = try optionalObject(root, key: "rawArchiveDisclosureReview", path: "$") {
            try validateDisclosureReview(review, path: "$.rawArchiveDisclosureReview")
        }
        let assets = try requiredArray(root, key: "assets", path: "$")
        for (index, value) in assets.enumerated() {
            _ = try object(
                value,
                allowed: syncAssetKeys,
                required: ["assetID", "assetClass", "disposition"],
                path: "$.assets[\(index)]"
            )
        }
    }

    static func validatePortalSnapshot(_ root: [String: Any]) throws {
        let root = try object(
            root,
            allowed: [
                "schemaVersion", "contractKind", "snapshotID", "workspaceID", "projectID", "sourceRevision", "publishedAt", "selectionSHA256", "disclosureReview", "allowlistedSections", "assets", "branding"
            ],
            required: [
                "schemaVersion", "contractKind", "snapshotID", "workspaceID", "projectID", "sourceRevision", "publishedAt", "selectionSHA256", "disclosureReview", "allowlistedSections", "assets", "branding"
            ],
            path: "$"
        )
        try requireUTCTimestamp(root, key: "publishedAt", path: "$")
        try validateSourceRevision(try requiredObject(root, key: "sourceRevision", path: "$"), path: "$.sourceRevision")
        try validateDisclosureReview(
            try requiredObject(root, key: "disclosureReview", path: "$"),
            path: "$.disclosureReview"
        )
        _ = try requiredArray(root, key: "allowlistedSections", path: "$")
        let assets = try requiredArray(root, key: "assets", path: "$")
        for (index, value) in assets.enumerated() {
            let asset = try object(
                value,
                allowed: ["assetID", "assetClass", "relativePath", "sha256", "byteCount", "mediaType", "aiReadyPackageBinding"],
                required: ["assetID", "assetClass", "relativePath", "sha256", "byteCount", "mediaType"],
                path: "$.assets[\(index)]"
            )
            if let binding = try optionalObject(
                asset,
                key: "aiReadyPackageBinding",
                path: "$.assets[\(index)]"
            ) {
                _ = try object(
                    binding,
                    allowed: [
                        "packageID", "profile", "manifestEntryPath", "manifestSHA256", "sourceRevisionID",
                        "sourceRevisionManifestSHA256", "artifactPlanSHA256", "selectionSHA256"
                    ],
                    required: [
                        "packageID", "profile", "manifestEntryPath", "manifestSHA256", "sourceRevisionID",
                        "sourceRevisionManifestSHA256", "artifactPlanSHA256", "selectionSHA256"
                    ],
                    path: "$.assets[\(index)].aiReadyPackageBinding"
                )
            }
        }
        _ = try object(
            try requiredObject(root, key: "branding", path: "$"),
            allowed: ["displayName", "accentColorHex"],
            required: ["displayName"],
            path: "$.branding"
        )
    }

    static func rejectPrivacyKeys(in value: Any, path: String) throws {
        try rejectKeys(
            in: value,
            forbidden: ["precisegps", "gps", "latitude", "longitude", "horizontalaccuracymeters"],
            path: path,
            reason: "Precise GPS fields are not part of AI Room Package schemas."
        )
    }

    static func rejectPortalForbiddenKeys(in value: Any, path: String) throws {
        try rejectKeys(
            in: value,
            forbidden: [
                "rawrgb", "rawdepth", "rawconfidence", "diagnostics", "worldmap", "privatenotes", "revisionhistory", "precisegps", "gps", "latitude", "longitude", "horizontalaccuracymeters"
            ],
            path: path,
            reason: "Private/raw/location fields are not part of allowlisted portal snapshots."
        )
    }

    private static func validateSourceRevision(_ value: [String: Any], path: String) throws {
        _ = try object(value, allowed: sourceRevisionKeys, required: sourceRevisionKeys, path: path)
    }

    private static func validateVector(_ value: [String: Any], path: String) throws {
        _ = try object(value, allowed: vectorKeys, required: vectorKeys, path: path)
    }

    private static func validateDisclosureReview(_ value: [String: Any], path: String) throws {
        let review = try object(
            value,
            allowed: disclosureReviewKeys,
            required: [
                "reviewID", "reviewedAt", "decision", "sourceRevisionID", "sourceRevisionManifestSHA256", "reviewedSelectionSHA256", "preciseGPSExcluded", "rawEvidenceDisclosureAccepted"
            ],
            path: path
        )
        try requireUTCTimestamp(review, key: "reviewedAt", path: path)
    }

    private static func rejectKeys(
        in value: Any,
        forbidden: Set<String>,
        path: String,
        reason: String
    ) throws {
        if let object = value as? [String: Any] {
            for (key, nested) in object {
                if forbidden.contains(key.lowercased()) {
                    throw RoomRedesignContractValidationError.invalidValue(
                        path: "\(path).\(key)",
                        reason: reason
                    )
                }
                try rejectKeys(in: nested, forbidden: forbidden, path: "\(path).\(key)", reason: reason)
            }
        } else if let array = value as? [Any] {
            for (index, nested) in array.enumerated() {
                try rejectKeys(in: nested, forbidden: forbidden, path: "\(path)[\(index)]", reason: reason)
            }
        }
    }

    private static func object(
        _ value: Any,
        allowed: Set<String>,
        required: Set<String>,
        path: String
    ) throws -> [String: Any] {
        guard let object = value as? [String: Any] else {
            throw RoomRedesignContractValidationError.invalidType(path: path)
        }
        for key in object.keys where !allowed.contains(key) {
            throw RoomRedesignContractValidationError.unknownKey(path: path, key: key)
        }
        for key in required where object[key] == nil {
            throw RoomRedesignContractValidationError.missingKey(path: path, key: key)
        }
        return object
    }

    static func requiredString(_ object: [String: Any], key: String, path: String) throws -> String {
        guard let value = object[key] else {
            throw RoomRedesignContractValidationError.missingKey(path: path, key: key)
        }
        guard let string = value as? String else {
            throw RoomRedesignContractValidationError.invalidType(path: "\(path).\(key)")
        }
        return string
    }

    private static func requiredObject(_ object: [String: Any], key: String, path: String) throws -> [String: Any] {
        guard let value = object[key] else {
            throw RoomRedesignContractValidationError.missingKey(path: path, key: key)
        }
        guard let nested = value as? [String: Any] else {
            throw RoomRedesignContractValidationError.invalidType(path: "\(path).\(key)")
        }
        return nested
    }

    private static func optionalObject(_ object: [String: Any], key: String, path: String) throws -> [String: Any]? {
        guard let value = object[key] else { return nil }
        guard let nested = value as? [String: Any] else {
            throw RoomRedesignContractValidationError.invalidType(path: "\(path).\(key)")
        }
        return nested
    }

    private static func requiredArray(_ object: [String: Any], key: String, path: String) throws -> [Any] {
        guard let value = object[key] else {
            throw RoomRedesignContractValidationError.missingKey(path: path, key: key)
        }
        guard let array = value as? [Any] else {
            throw RoomRedesignContractValidationError.invalidType(path: "\(path).\(key)")
        }
        return array
    }

    private static func requireUTCTimestamp(
        _ object: [String: Any],
        key: String,
        path: String
    ) throws {
        let value = try requiredString(object, key: key, path: path)
        guard value.contains("T"), value.hasSuffix("Z") else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "\(path).\(key)",
                reason: "Timestamps must use UTC ISO-8601 text ending in Z."
            )
        }
    }
}
