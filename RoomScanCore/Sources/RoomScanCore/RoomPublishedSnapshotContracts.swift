import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Public presentation contracts

/// Slice 6 carries a new publication family rather than changing the frozen
/// `roomscan-portal-snapshot-v1` shape. The public document is deliberately
/// separate from its internal source/approval control manifest.
public enum RoomPublishedSnapshotKind: String, Codable, Sendable, Equatable {
    case room
    case property
}

public enum RoomPublishedSemanticAccent: String, Codable, Sendable, Equatable, CaseIterable {
    case blueprint
    case forest
    case slate
    case terracotta
}

public struct RoomPublishedContactDetails: Codable, Sendable, Equatable {
    public var phone: String?
    public var website: String?

    public init(phone: String? = nil, website: String? = nil) {
        self.phone = phone
        self.website = website
    }

    public func validate(at path: String = "contact") throws {
        guard phone != nil || website != nil else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: path,
                reason: "Public branding needs at least one bounded contact method."
            )
        }
        if let phone {
            try RoomPublishedSnapshotRules.requirePhone(phone, at: "\(path).phone")
        }
        if let website {
            try RoomPublishedSnapshotRules.requireHTTPSURL(website, at: "\(path).website")
        }
    }
}

public struct RoomPublishedBranding: Codable, Sendable, Equatable {
    public var businessName: String
    public var logoAssetID: String?
    public var contact: RoomPublishedContactDetails
    public var accent: RoomPublishedSemanticAccent

    public init(
        businessName: String,
        logoAssetID: String? = nil,
        contact: RoomPublishedContactDetails,
        accent: RoomPublishedSemanticAccent
    ) {
        self.businessName = businessName
        self.logoAssetID = logoAssetID
        self.contact = contact
        self.accent = accent
    }

    public func validate() throws {
        try RoomPublishedSnapshotRules.requireText(
            businessName,
            minimum: 1,
            maximum: 120,
            at: "branding.businessName"
        )
        if let logoAssetID {
            try RoomPublishedSnapshotRules.requireIdentifier(logoAssetID, at: "branding.logoAssetID")
        }
        try contact.validate(at: "branding.contact")
    }
}

public enum RoomPublishedLayoutKind: String, Codable, Sendable, Equatable {
    case wall
    case door
    case window
    case opening
    case floor
    case fixedObject
    case movableObject
}

public struct RoomPublishedLayoutElement: Codable, Sendable, Equatable {
    public var kind: RoomPublishedLayoutKind
    public var label: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(
        kind: RoomPublishedLayoutKind,
        label: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) {
        self.kind = kind
        self.label = label
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public func validate(at path: String) throws {
        try RoomPublishedSnapshotRules.requireText(label, minimum: 1, maximum: 120, at: "\(path).label")
        try RoomPublishedSnapshotRules.requireUnitInterval(x, at: "\(path).x")
        try RoomPublishedSnapshotRules.requireUnitInterval(y, at: "\(path).y")
        try RoomPublishedSnapshotRules.requireFinite(width, minimum: 0.0001, maximum: 1, at: "\(path).width")
        try RoomPublishedSnapshotRules.requireFinite(height, minimum: 0.0001, maximum: 1, at: "\(path).height")
        guard x + width <= 1.000_001, y + height <= 1.000_001 else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: path,
                reason: "Semantic layout bounds must remain inside the room-local unit canvas."
            )
        }
    }
}

public struct RoomPublishedSemanticLayout: Codable, Sendable, Equatable {
    public var elements: [RoomPublishedLayoutElement]

    public init(elements: [RoomPublishedLayoutElement]) {
        self.elements = elements
    }

    public func validate(at path: String = "semanticLayout") throws {
        try RoomPublishedSnapshotRules.requireCount(
            elements.count,
            minimum: 1,
            maximum: RoomPublishedSnapshotRules.maximumLayoutElements,
            at: "\(path).elements"
        )
        for (index, element) in elements.enumerated() {
            try element.validate(at: "\(path).elements[\(index)]")
        }
    }
}

public enum RoomPublishedInitialView: String, Codable, Sendable, Equatable {
    case entry
    case wall
    case corner
    case topDown
}

/// This is an initial local view selector, not a cross-room transform. Room
/// geometry is always room-local and a property presentation resets it on
/// navigation.
public struct RoomPublishedOrientation: Codable, Sendable, Equatable {
    public var initialView: RoomPublishedInitialView

    public init(initialView: RoomPublishedInitialView) {
        self.initialView = initialView
    }
}

public struct RoomPublishedDimension: Codable, Sendable, Equatable {
    public var label: String
    public var meters: Double

    public init(label: String, meters: Double) {
        self.label = label
        self.meters = meters
    }

    public func validate(at path: String) throws {
        try RoomPublishedSnapshotRules.requireText(label, minimum: 1, maximum: 80, at: "\(path).label")
        try RoomPublishedSnapshotRules.requireFinite(meters, minimum: 0.001, maximum: 1_000, at: "\(path).meters")
    }
}

public enum RoomPublishedQualityWarningSeverity: String, Codable, Sendable, Equatable {
    case advisory
    case reviewRecommended
    case insufficientEvidence
}

public struct RoomPublishedQualityWarning: Codable, Sendable, Equatable {
    public var code: String
    public var severity: RoomPublishedQualityWarningSeverity
    public var message: String

    public init(code: String, severity: RoomPublishedQualityWarningSeverity, message: String) {
        self.code = code
        self.severity = severity
        self.message = message
    }

    public func validate(at path: String) throws {
        try RoomPublishedSnapshotRules.requireIdentifier(code, at: "\(path).code")
        try RoomPublishedSnapshotRules.requireText(message, minimum: 1, maximum: 500, at: "\(path).message")
    }
}

public struct RoomPublishedConceptComparison: Codable, Sendable, Equatable {
    public var originalAssetID: String
    public var conceptAssetID: String
    public var label: String
    public var disclaimer: String

    public init(
        originalAssetID: String,
        conceptAssetID: String,
        label: String,
        disclaimer: String
    ) {
        self.originalAssetID = originalAssetID
        self.conceptAssetID = conceptAssetID
        self.label = label
        self.disclaimer = disclaimer
    }

    public func validate(at path: String) throws {
        try RoomPublishedSnapshotRules.requireIdentifier(originalAssetID, at: "\(path).originalAssetID")
        try RoomPublishedSnapshotRules.requireIdentifier(conceptAssetID, at: "\(path).conceptAssetID")
        try RoomPublishedSnapshotRules.requireText(label, minimum: 1, maximum: 120, at: "\(path).label")
        try RoomPublishedSnapshotRules.requireText(disclaimer, minimum: 1, maximum: 500, at: "\(path).disclaimer")
    }
}

public struct RoomPublishedRoomAssets: Codable, Sendable, Equatable {
    public var webGeometryAssetID: String
    public var floorPlanAssetID: String
    public var selectedImageAssetIDs: [String]
    public var webTextureAssetIDs: [String]
    public var approvedConceptAssetIDs: [String]

    public init(
        webGeometryAssetID: String,
        floorPlanAssetID: String,
        selectedImageAssetIDs: [String],
        webTextureAssetIDs: [String],
        approvedConceptAssetIDs: [String]
    ) {
        self.webGeometryAssetID = webGeometryAssetID
        self.floorPlanAssetID = floorPlanAssetID
        self.selectedImageAssetIDs = selectedImageAssetIDs
        self.webTextureAssetIDs = webTextureAssetIDs
        self.approvedConceptAssetIDs = approvedConceptAssetIDs
    }

    public func validate(at path: String) throws {
        try RoomPublishedSnapshotRules.requireIdentifier(webGeometryAssetID, at: "\(path).webGeometryAssetID")
        try RoomPublishedSnapshotRules.requireIdentifier(floorPlanAssetID, at: "\(path).floorPlanAssetID")
        for (key, values) in [
            ("selectedImageAssetIDs", selectedImageAssetIDs),
            ("webTextureAssetIDs", webTextureAssetIDs),
            ("approvedConceptAssetIDs", approvedConceptAssetIDs),
        ] {
            try RoomPublishedSnapshotRules.requireCount(
                values.count,
                minimum: 0,
                maximum: RoomPublishedSnapshotRules.maximumAssetsPerRoom,
                at: "\(path).\(key)"
            )
            for value in values {
                try RoomPublishedSnapshotRules.requireIdentifier(value, at: "\(path).\(key)")
            }
            try RoomPublishedSnapshotRules.requireUnique(values, at: "\(path).\(key)")
        }
    }
}

public struct RoomPublishedPublicRoom: Codable, Sendable, Equatable {
    public var roomKey: String
    public var displayName: String
    public var semanticLayout: RoomPublishedSemanticLayout
    public var orientation: RoomPublishedOrientation
    public var dimensions: [RoomPublishedDimension]
    public var qualityWarnings: [RoomPublishedQualityWarning]
    public var comparisons: [RoomPublishedConceptComparison]
    public var assets: RoomPublishedRoomAssets

    public init(
        roomKey: String,
        displayName: String,
        semanticLayout: RoomPublishedSemanticLayout,
        orientation: RoomPublishedOrientation,
        dimensions: [RoomPublishedDimension],
        qualityWarnings: [RoomPublishedQualityWarning],
        comparisons: [RoomPublishedConceptComparison],
        assets: RoomPublishedRoomAssets
    ) {
        self.roomKey = roomKey
        self.displayName = displayName
        self.semanticLayout = semanticLayout
        self.orientation = orientation
        self.dimensions = dimensions
        self.qualityWarnings = qualityWarnings
        self.comparisons = comparisons
        self.assets = assets
    }

    public func validate(at path: String) throws {
        try RoomPublishedSnapshotRules.requireIdentifier(roomKey, at: "\(path).roomKey")
        try RoomPublishedSnapshotRules.requireText(displayName, minimum: 1, maximum: 120, at: "\(path).displayName")
        try semanticLayout.validate(at: "\(path).semanticLayout")
        try RoomPublishedSnapshotRules.requireCount(
            dimensions.count,
            minimum: 1,
            maximum: RoomPublishedSnapshotRules.maximumDimensions,
            at: "\(path).dimensions"
        )
        for (index, dimension) in dimensions.enumerated() {
            try dimension.validate(at: "\(path).dimensions[\(index)]")
        }
        try RoomPublishedSnapshotRules.requireCount(
            qualityWarnings.count,
            minimum: 0,
            maximum: RoomPublishedSnapshotRules.maximumWarnings,
            at: "\(path).qualityWarnings"
        )
        try RoomPublishedSnapshotRules.requireUnique(qualityWarnings.map(\.code), at: "\(path).qualityWarnings")
        for (index, warning) in qualityWarnings.enumerated() {
            try warning.validate(at: "\(path).qualityWarnings[\(index)]")
        }
        try RoomPublishedSnapshotRules.requireCount(
            comparisons.count,
            minimum: 0,
            maximum: RoomPublishedSnapshotRules.maximumComparisons,
            at: "\(path).comparisons"
        )
        for (index, comparison) in comparisons.enumerated() {
            try comparison.validate(at: "\(path).comparisons[\(index)]")
        }
        try assets.validate(at: "\(path).assets")
    }
}

public struct RoomPublishedDownloadPolicy: Codable, Sendable, Equatable {
    /// The service owns the passive PDF and gallery ZIP derivation. These flags
    /// authorize that bounded derivation; callers never provide those files.
    public var floorPlanPDF: Bool
    public var galleryZIP: Bool
    public var aiReadyPackageAssetID: String?

    public init(floorPlanPDF: Bool, galleryZIP: Bool, aiReadyPackageAssetID: String?) {
        self.floorPlanPDF = floorPlanPDF
        self.galleryZIP = galleryZIP
        self.aiReadyPackageAssetID = aiReadyPackageAssetID
    }

    public func validate() throws {
        if let aiReadyPackageAssetID {
            try RoomPublishedSnapshotRules.requireIdentifier(
                aiReadyPackageAssetID,
                at: "downloads.aiReadyPackageAssetID"
            )
        }
    }
}

/// Portal-safe room-v2 document. It intentionally contains no project or
/// revision identifier, source/selection digest, storage key, link state,
/// email address, or audit material.
public struct RoomPublishedRoomPresentationV2: Codable, Sendable, Equatable {
    public static let schemaVersionValue = "roomscan-published-room-snapshot-v2"

    public var schemaVersion: String
    public var contractKind: RoomRedesignContractKind
    public var title: String
    public var room: RoomPublishedPublicRoom
    public var branding: RoomPublishedBranding
    public var downloads: RoomPublishedDownloadPolicy

    public init(
        schemaVersion: String = Self.schemaVersionValue,
        contractKind: RoomRedesignContractKind = .publishedRoomSnapshot,
        title: String,
        room: RoomPublishedPublicRoom,
        branding: RoomPublishedBranding,
        downloads: RoomPublishedDownloadPolicy
    ) {
        self.schemaVersion = schemaVersion
        self.contractKind = contractKind
        self.title = title
        self.room = room
        self.branding = branding
        self.downloads = downloads
    }

    public func validate() throws {
        try RoomPublishedSnapshotRules.requireEnvelope(
            schemaVersion: schemaVersion,
            contractKind: contractKind,
            expected: .publishedRoomSnapshot
        )
        try RoomPublishedSnapshotRules.requireText(title, minimum: 1, maximum: 180, at: "title")
        try room.validate(at: "room")
        try branding.validate()
        try downloads.validate()
    }
}

/// Portal-safe property-v1 document. The ordered `rooms` collection is a set
/// of independent room presentations. Its only spatial language is local to
/// each room; no transform, alignment, connectivity, or reconstruction field
/// exists in this type.
public struct RoomPublishedPropertyPresentationV1: Codable, Sendable, Equatable {
    public static let schemaVersionValue = "roomscan-published-property-snapshot-v1"
    public static let independentRoomNotice = "Rooms are presented independently; they do not share coordinates, alignment, connectivity, or reconstruction."

    public var schemaVersion: String
    public var contractKind: RoomRedesignContractKind
    public var propertyTitle: String
    public var independentRoomNotice: String
    public var rooms: [RoomPublishedPublicRoom]
    public var branding: RoomPublishedBranding
    public var downloads: RoomPublishedDownloadPolicy

    public init(
        schemaVersion: String = Self.schemaVersionValue,
        contractKind: RoomRedesignContractKind = .publishedPropertySnapshot,
        propertyTitle: String,
        rooms: [RoomPublishedPublicRoom],
        branding: RoomPublishedBranding,
        downloads: RoomPublishedDownloadPolicy
    ) {
        self.schemaVersion = schemaVersion
        self.contractKind = contractKind
        self.propertyTitle = propertyTitle
        self.independentRoomNotice = Self.independentRoomNotice
        self.rooms = rooms
        self.branding = branding
        self.downloads = downloads
    }

    public func validate() throws {
        try RoomPublishedSnapshotRules.requireEnvelope(
            schemaVersion: schemaVersion,
            contractKind: contractKind,
            expected: .publishedPropertySnapshot
        )
        try RoomPublishedSnapshotRules.requireText(propertyTitle, minimum: 1, maximum: 180, at: "propertyTitle")
        guard independentRoomNotice == Self.independentRoomNotice else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "independentRoomNotice",
                reason: "Property presentations must retain the independent-room disclosure."
            )
        }
        try RoomPublishedSnapshotRules.requireCount(
            rooms.count,
            minimum: 2,
            maximum: RoomPublishedSnapshotRules.maximumRooms,
            at: "rooms"
        )
        try RoomPublishedSnapshotRules.requireUnique(rooms.map(\.roomKey), at: "rooms.roomKey")
        for (index, room) in rooms.enumerated() {
            try room.validate(at: "rooms[\(index)]")
        }
        try branding.validate()
        try downloads.validate()
    }
}

public enum RoomPublishedSnapshotDraft: Sendable, Equatable {
    case room(RoomPublishedRoomPresentationV2)
    case property(RoomPublishedPropertyPresentationV1)

    public var kind: RoomPublishedSnapshotKind {
        switch self {
        case .room: .room
        case .property: .property
        }
    }

    public var orderedRoomKeys: [String] {
        switch self {
        case let .room(value): [value.room.roomKey]
        case let .property(value): value.rooms.map(\.roomKey)
        }
    }

    public var branding: RoomPublishedBranding {
        switch self {
        case let .room(value): value.branding
        case let .property(value): value.branding
        }
    }

    public var downloads: RoomPublishedDownloadPolicy {
        switch self {
        case let .room(value): value.downloads
        case let .property(value): value.downloads
        }
    }

    public func publicRooms() -> [RoomPublishedPublicRoom] {
        switch self {
        case let .room(value): [value.room]
        case let .property(value): value.rooms
        }
    }

    public func canonicalPresentationData() throws -> Data {
        switch self {
        case let .room(value):
            try value.validate()
            return try RoomRedesignCanonicalJSON.encode(value)
        case let .property(value):
            try value.validate()
            return try RoomRedesignCanonicalJSON.encode(value)
        }
    }
}

// MARK: - Internal immutable control bindings

/// This is internal control data and is never encoded into `presentation.json`.
public struct RoomPublishedSourceBinding: Codable, Sendable, Equatable {
    public var publicRoomKey: String
    public var sourceRevision: RoomRedesignSourceRevision

    public init(publicRoomKey: String, sourceRevision: RoomRedesignSourceRevision) {
        self.publicRoomKey = publicRoomKey
        self.sourceRevision = sourceRevision
    }

    public func validate(at path: String) throws {
        try RoomPublishedSnapshotRules.requireIdentifier(publicRoomKey, at: "\(path).publicRoomKey")
        try sourceRevision.validate()
    }
}

public enum RoomPublishedApprovalDecision: String, Codable, Sendable, Equatable {
    case approved
    case rejected
}

/// Approval is valid only for the exact canonical source-binding and exact
/// canonical selection-manifest digests produced by the empty allowlist stage.
public struct RoomPublishedPublicationApproval: Codable, Sendable, Equatable {
    public var reviewID: String
    public var reviewedAt: Date
    public var decision: RoomPublishedApprovalDecision
    public var sourceBindingsSHA256: String
    public var selectionManifestSHA256: String

    public init(
        reviewID: String,
        reviewedAt: Date,
        decision: RoomPublishedApprovalDecision,
        sourceBindingsSHA256: String,
        selectionManifestSHA256: String
    ) {
        self.reviewID = reviewID
        self.reviewedAt = reviewedAt
        self.decision = decision
        self.sourceBindingsSHA256 = sourceBindingsSHA256
        self.selectionManifestSHA256 = selectionManifestSHA256
    }

    public func validate(
        expectedSourceBindingsSHA256: String,
        expectedSelectionManifestSHA256: String
    ) throws {
        try RoomPublishedSnapshotRules.requireIdentifier(reviewID, at: "approval.reviewID")
        try RoomPublishedSnapshotRules.requireDate(reviewedAt, at: "approval.reviewedAt")
        try RoomPublishedSnapshotRules.requireSHA256(sourceBindingsSHA256, at: "approval.sourceBindingsSHA256")
        try RoomPublishedSnapshotRules.requireSHA256(selectionManifestSHA256, at: "approval.selectionManifestSHA256")
        guard decision == .approved,
              sourceBindingsSHA256 == expectedSourceBindingsSHA256,
              selectionManifestSHA256 == expectedSelectionManifestSHA256
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "approval",
                reason: "Publication approval must match the exact reviewed source bindings and selection manifest."
            )
        }
    }
}

public enum RoomPublishedAssetClass: String, Codable, Sendable, Equatable {
    case webGeometry
    case webTexture
    case selectedImage
    case floorPlan
    case approvedConcept
    case brandingLogo
    case aiReadyPackage
}

public struct RoomPublishedVector3: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public func validate(at path: String) throws {
        try RoomPublishedSnapshotRules.requireFinite(x, minimum: -1_000, maximum: 1_000, at: "\(path).x")
        try RoomPublishedSnapshotRules.requireFinite(y, minimum: -1_000, maximum: 1_000, at: "\(path).y")
        try RoomPublishedSnapshotRules.requireFinite(z, minimum: -1_000, maximum: 1_000, at: "\(path).z")
    }
}

public struct RoomPublishedTriangle: Codable, Sendable, Equatable, Hashable {
    public var a: Int
    public var b: Int
    public var c: Int

    public init(a: Int, b: Int, c: Int) {
        self.a = a
        self.b = b
        self.c = c
    }
}

/// Typed local web geometry. The publication path cannot accept a generic
/// JSON object or a private mesh/package as a geometry replacement.
public struct RoomPublishedWebGeometry: Codable, Sendable, Equatable {
    public var vertices: [RoomPublishedVector3]
    public var triangles: [RoomPublishedTriangle]

    public init(vertices: [RoomPublishedVector3], triangles: [RoomPublishedTriangle]) {
        self.vertices = vertices
        self.triangles = triangles
    }

    public func validate() throws {
        try RoomPublishedSnapshotRules.requireCount(
            vertices.count,
            minimum: 3,
            maximum: RoomPublishedSnapshotRules.maximumGeometryVertices,
            at: "geometry.vertices"
        )
        try RoomPublishedSnapshotRules.requireCount(
            triangles.count,
            minimum: 1,
            maximum: RoomPublishedSnapshotRules.maximumGeometryTriangles,
            at: "geometry.triangles"
        )
        for (index, vertex) in vertices.enumerated() {
            try vertex.validate(at: "geometry.vertices[\(index)]")
        }
        for (index, triangle) in triangles.enumerated() {
            guard triangle.a >= 0, triangle.b >= 0, triangle.c >= 0,
                  triangle.a < vertices.count, triangle.b < vertices.count, triangle.c < vertices.count,
                  triangle.a != triangle.b, triangle.a != triangle.c, triangle.b != triangle.c
            else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: "geometry.triangles[\(index)]",
                    reason: "Geometry triangles must reference three distinct bounded local vertices."
                )
            }
        }
    }
}

public enum RoomPublishedRasterMediaType: String, Codable, Sendable, Equatable {
    case png = "image/png"
    case jpeg = "image/jpeg"

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        }
    }
}

/// This accepts only bytes that have already crossed the native fresh-encode
/// sanitizer. Publication independently forces a bounded pixel decode and
/// fresh re-encodes the asset before it enters the immutable ledger, so no
/// caller-provided image byte sequence is copied into an archive.
public struct RoomPublishedRaster: Sendable, Equatable {
    public var data: Data
    public var mediaType: RoomPublishedRasterMediaType

    public init(data: Data, mediaType: RoomPublishedRasterMediaType) {
        self.data = data
        self.mediaType = mediaType
    }
}

/// Publication is a stricter trust boundary than Concept Set import. It first
/// invokes the shared byte-level image validator, then permits only the
/// structural PNG/JPEG records needed to render pixels. It additionally forces
/// ImageIO/CoreGraphics pixel decoding and creates fresh output before a
/// caller image becomes a selected asset. In particular, a CRC-valid unknown
/// PNG ancillary chunk, JPEG APP segment, or recoverable malformed payload
/// cannot use the publication archive as a private-byte carrier.
///
/// The incoming JPEG profile deliberately still rejects every APP marker,
/// including APP0. Native Task 2 must hand Core a metadata-stripped candidate;
/// this boundary strips every APP marker again from its own fresh output.
enum RoomPublishedRasterValidator {
    private static let limits = RoomConceptImageLimits(
        maxBytes: RoomConceptImageLimits.v1MaximumBytes,
        maxPixelDimension: 8_192,
        maxPixelCount: 24_000_000
    )

    /// Produces the only raster bytes eligible for a publication ledger. The
    /// exact output bytes are then hashed into the selection manifest before
    /// any local approval is made.
    static func sanitize(
        _ data: Data,
        mediaType: RoomPublishedRasterMediaType
    ) throws -> Data {
        let inputInfo = try validateStructural(data, mediaType: mediaType)
        let decoded = try decodeFully(data, mediaType: mediaType, expectedInfo: inputInfo)
        let output = try freshEncode(decoded, mediaType: mediaType)
        // Validate both the closed byte profile and one more actual pixel
        // decode of the bytes that will be written to the archive.
        _ = try validate(output, mediaType: mediaType)
        return output
    }

    /// Archive revalidation cannot trust an earlier local preparation. It
    /// verifies the restrictive profile and forces a bounded full decode of
    /// the stored bytes, but does not re-encode so cross-runtime readers do
    /// not need to reproduce ImageIO's encoder bytes exactly.
    static func validate(
        _ data: Data,
        mediaType: RoomPublishedRasterMediaType
    ) throws -> RoomConceptImageInfo {
        let info = try validateStructural(data, mediaType: mediaType)
        _ = try decodeFully(data, mediaType: mediaType, expectedInfo: info)
        return info
    }

    static func validate(
        _ data: Data,
        mediaType: String
    ) throws -> RoomConceptImageInfo {
        guard let publishedType = RoomPublishedRasterMediaType(rawValue: mediaType) else {
            throw invalid("Published rasters must declare PNG or JPEG media.")
        }
        return try validate(data, mediaType: publishedType)
    }

    private static func validateStructural(
        _ data: Data,
        mediaType: RoomPublishedRasterMediaType
    ) throws -> RoomConceptImageInfo {
        // Preserve the mature shared parser's framing, CRC, dimensions, and
        // byte/pixel budget checks. This intentionally does not alter Concept
        // Set compatibility, which can accept a broader sanitized profile.
        let info = try RoomConceptImageValidator.validateSanitizedImage(
            data,
            mediaType: mediaType.rawValue,
            limits: limits
        )
        switch mediaType {
        case .png:
            try validatePNGStructuralProfile(data)
        case .jpeg:
            try validateJPEGStructuralProfile(data)
        }
        return info
    }

    private static func decodeFully(
        _ data: Data,
        mediaType: RoomPublishedRasterMediaType,
        expectedInfo: RoomConceptImageInfo
    ) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ),
            CGImageSourceGetCount(source) == 1,
            CGImageSourceGetStatus(source) == .statusComplete,
            CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
            let sourceType = CGImageSourceGetType(source) as String?,
            sourceType == imageTypeIdentifier(for: mediaType),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.uint64Value,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.uint64Value,
            width == expectedInfo.pixelWidth,
            height == expectedInfo.pixelHeight,
            let image = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            ),
            image.width == Int(expectedInfo.pixelWidth),
            image.height == Int(expectedInfo.pixelHeight)
        else {
            throw invalid("Published raster could not be decoded as one complete declared image.")
        }

        // Drawing into a full-size bitmap context is deliberately not
        // optional: a non-nil CGImage can still defer entropy/IDAT expansion.
        // The shared validator already bounds this allocation to 24M pixels
        // (at most 96,000,000 RGBA bytes, about 92 MiB); fail closed if the
        // arithmetic or allocation fails.
        let renderWidth = Int(expectedInfo.pixelWidth)
        let renderHeight = Int(expectedInfo.pixelHeight)
        let (bytesPerRow, rowOverflow) = renderWidth.multipliedReportingOverflow(by: 4)
        let (_, allocationOverflow) = bytesPerRow.multipliedReportingOverflow(by: renderHeight)
        guard renderWidth > 0,
              renderHeight > 0,
              !rowOverflow,
              !allocationOverflow,
              let context = CGContext(
                data: nil,
                width: renderWidth,
                height: renderHeight,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw invalid("Published raster could not allocate its bounded full decode surface.")
        }
        context.interpolationQuality = .none
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: renderWidth, height: renderHeight)
        )
        context.flush()
        guard
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
        else {
            throw invalid("Published raster failed during pixel decoding.")
        }
        return image
    }

    private static func freshEncode(
        _ image: CGImage,
        mediaType: RoomPublishedRasterMediaType
    ) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            imageTypeIdentifier(for: mediaType) as CFString,
            1,
            nil
        ) else {
            throw invalid("Published raster could not create a fresh encoder destination.")
        }
        let properties: [CFString: Any]
        switch mediaType {
        case .png:
            properties = [:]
        case .jpeg:
            properties = [kCGImageDestinationLossyCompressionQuality: 0.92]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw invalid("Published raster fresh encoding failed.")
        }
        let encoded = output as Data
        switch mediaType {
        case .png:
            return try stripPNGNonImageChunks(encoded)
        case .jpeg:
            return try stripJPEGAPPSegments(encoded)
        }
    }

    private static func imageTypeIdentifier(for mediaType: RoomPublishedRasterMediaType) -> String {
        switch mediaType {
        case .png: UTType.png.identifier
        case .jpeg: UTType.jpeg.identifier
        }
    }

    /// Fresh ImageIO PNG output can still carry color-profile/text chunks. A
    /// decoded CGImage has already supplied the rendered pixels, so retain
    /// only the three PNG records the public profile needs. If ImageIO ever
    /// produces an essential nonallowlisted record, the subsequent structural
    /// and pixel validation fails closed rather than copying it through.
    private static func stripPNGNonImageChunks(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        let signature: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
        guard bytes.count >= signature.count, Array(bytes[0..<signature.count]) == signature else {
            throw invalid("Fresh PNG output has an invalid signature.")
        }
        var result = Data(signature)
        var offset = signature.count
        var sawEnd = false
        while offset < bytes.count {
            guard !sawEnd, offset <= bytes.count - 12 else {
                throw invalid("Fresh PNG output framing is incomplete or has trailing bytes.")
            }
            let length = Int(readBigEndianUInt32(bytes, at: offset))
            guard length <= bytes.count - offset - 12 else {
                throw invalid("Fresh PNG chunk exceeds the output boundary.")
            }
            let typeStart = offset + 4
            let payloadEnd = typeStart + 4 + length
            let chunkEnd = payloadEnd + 4
            let type = String(decoding: bytes[typeStart..<(typeStart + 4)], as: UTF8.self)
            switch type {
            case "IHDR", "IDAT", "IEND":
                result.append(contentsOf: bytes[offset..<chunkEnd])
            default:
                // Intentionally do not copy fresh-output ancillary/color/text
                // records. A nonallowlisted critical record will make the
                // retained output fail full decode below.
                break
            }
            if type == "IEND" {
                guard length == 0 else {
                    throw invalid("Fresh PNG IEND payload is invalid.")
                }
                sawEnd = true
            }
            offset = chunkEnd
        }
        guard sawEnd, offset == bytes.count else {
            throw invalid("Fresh PNG output is missing IEND.")
        }
        return result
    }

    /// ImageIO may emit APP0/other APP records on a fresh JPEG. The public
    /// profile treats every APP record as a private carrier, so copy only the
    /// non-APP pre-scan records and the exact entropy/EOI suffix. The fresh
    /// result is subsequently validated by the closed JPEG parser and decoder.
    private static func stripJPEGAPPSegments(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xff, bytes[1] == 0xd8 else {
            throw invalid("Fresh JPEG output does not begin with SOI.")
        }
        var result: [UInt8] = [0xff, 0xd8]
        var offset = 2
        while offset <= bytes.count - 2 {
            guard bytes[offset] == 0xff else {
                throw invalid("Fresh JPEG marker framing is invalid.")
            }
            let markerStart = offset
            while offset < bytes.count, bytes[offset] == 0xff { offset += 1 }
            guard offset < bytes.count else {
                throw invalid("Fresh JPEG ended inside a marker.")
            }
            let marker = bytes[offset]
            offset += 1
            if marker == 0xda {
                result.append(contentsOf: bytes[markerStart...])
                return Data(result)
            }
            guard marker != 0xd9,
                  marker != 0xd8,
                  marker != 0x01,
                  !(0xd0...0xd7).contains(marker),
                  offset <= bytes.count - 2
            else {
                throw invalid("Fresh JPEG contains an unsupported standalone marker.")
            }
            let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            guard length >= 2, length <= bytes.count - offset else {
                throw invalid("Fresh JPEG segment exceeds the input boundary.")
            }
            let segmentEnd = offset + length
            if !(0xe0...0xef).contains(marker) {
                result.append(contentsOf: bytes[markerStart..<segmentEnd])
            }
            offset = segmentEnd
        }
        throw invalid("Fresh JPEG is missing its scan.")
    }

    private static func validatePNGStructuralProfile(_ data: Data) throws {
        let bytes = [UInt8](data)
        let signature: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
        guard bytes.count >= signature.count, Array(bytes[0..<signature.count]) == signature else {
            throw invalid("Published PNG signature is invalid.")
        }
        var offset = signature.count
        var sawIHDR = false
        var sawIDAT = false
        var sawIEND = false
        var chunkIndex = 0
        while offset < bytes.count {
            guard !sawIEND, offset <= bytes.count - 12 else {
                throw invalid("Published PNG framing is incomplete or has trailing bytes.")
            }
            let length = Int(readBigEndianUInt32(bytes, at: offset))
            guard length <= bytes.count - offset - 12 else {
                throw invalid("Published PNG chunk exceeds the input boundary.")
            }
            let typeStart = offset + 4
            let type = String(decoding: bytes[typeStart..<(typeStart + 4)], as: UTF8.self)
            let payloadStart = typeStart + 4
            let payloadEnd = payloadStart + length
            switch type {
            case "IHDR":
                guard chunkIndex == 0, !sawIHDR, length == 13 else {
                    throw invalid("Published PNG must have exactly one leading IHDR chunk.")
                }
                sawIHDR = true
            case "IDAT":
                guard sawIHDR, !sawIEND, length > 0 else {
                    throw invalid("Published PNG image data is absent or out of order.")
                }
                sawIDAT = true
            case "IEND":
                guard sawIHDR, sawIDAT, !sawIEND, length == 0 else {
                    throw invalid("Published PNG end marker is invalid.")
                }
                sawIEND = true
            default:
                // The shared validator has already verified this chunk's CRC.
                // A public derivative has a closed image profile, so even
                // safe-to-copy/ancillary data cannot survive publication.
                throw invalid("Published PNG permits only IHDR, IDAT, and IEND chunks; found \(type).")
            }
            offset = payloadEnd + 4 // CRC consumed by the shared validator.
            chunkIndex += 1
        }
        guard sawIHDR, sawIDAT, sawIEND, offset == bytes.count else {
            throw invalid("Published PNG is missing required structural chunks.")
        }
    }

    private static func validateJPEGStructuralProfile(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xff, bytes[1] == 0xd8 else {
            throw invalid("Published JPEG signature is invalid.")
        }
        var offset = 2
        var frameComponents: Int?
        var sawRestartInterval = false
        while offset < bytes.count {
            guard bytes[offset] == 0xff else {
                throw invalid("Published JPEG marker framing is invalid.")
            }
            while offset < bytes.count, bytes[offset] == 0xff { offset += 1 }
            guard offset < bytes.count else {
                throw invalid("Published JPEG ended inside a marker.")
            }
            let marker = bytes[offset]
            offset += 1
            if marker == 0xd9 {
                throw invalid("Published JPEG EOI is early or appears outside entropy-coded data.")
            }
            guard !(0xe0...0xef).contains(marker) else {
                throw invalid("Published JPEG must not contain APP metadata or private payload segments.")
            }
            let payload = try nextJPEGSegment(bytes, offset: &offset)
            switch marker {
            case 0xc0:
                guard frameComponents == nil else {
                    throw invalid("Published JPEG may contain one baseline frame.")
                }
                frameComponents = try validateBaselineFrame(payload)
            case 0xdb:
                try validateQuantizationTables(payload)
            case 0xc4:
                try validateHuffmanTables(payload)
            case 0xdd:
                guard !sawRestartInterval, payload.count == 2 else {
                    throw invalid("Published JPEG restart interval shape is invalid.")
                }
                sawRestartInterval = true
            case 0xda:
                guard let frameComponents else {
                    throw invalid("Published JPEG scan must follow one baseline frame.")
                }
                try validateStartOfScan(payload, components: frameComponents)
                try consumeJPEGEntropyAndEOI(bytes, offset: &offset)
                return
            default:
                throw invalid("Published JPEG contains a nonessential marker segment.")
            }
        }
        throw invalid("Published JPEG is missing EOI.")
    }

    private static func nextJPEGSegment(
        _ bytes: [UInt8],
        offset: inout Int
    ) throws -> ArraySlice<UInt8> {
        guard offset <= bytes.count - 2 else {
            throw invalid("Published JPEG segment is truncated.")
        }
        let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
        guard length >= 2, length <= bytes.count - offset else {
            throw invalid("Published JPEG segment exceeds the input boundary.")
        }
        let payloadStart = offset + 2
        let payloadEnd = offset + length
        offset = payloadEnd
        return bytes[payloadStart..<payloadEnd]
    }

    private static func validateBaselineFrame(_ payload: ArraySlice<UInt8>) throws -> Int {
        let bytes = Array(payload)
        guard bytes.count >= 9,
              bytes[0] == 8,
              bytes[1] != 0 || bytes[2] != 0,
              bytes[3] != 0 || bytes[4] != 0
        else {
            throw invalid("Published JPEG baseline frame shape is invalid.")
        }
        let components = Int(bytes[5])
        guard [1, 3].contains(components), bytes.count == 6 + components * 3 else {
            throw invalid("Published JPEG frame components are invalid.")
        }
        var identifiers = Set<UInt8>()
        for index in 0..<components {
            let start = 6 + index * 3
            let identifier = bytes[start]
            let sampling = bytes[start + 1]
            let quantizationTable = bytes[start + 2]
            guard identifier != 0,
                  identifiers.insert(identifier).inserted,
                  sampling != 0,
                  quantizationTable <= 3
            else {
                throw invalid("Published JPEG frame component declaration is invalid.")
            }
        }
        return components
    }

    private static func validateQuantizationTables(_ payload: ArraySlice<UInt8>) throws {
        let bytes = Array(payload)
        var index = 0
        var tables = Set<UInt8>()
        while index < bytes.count {
            let descriptor = bytes[index]
            index += 1
            let precision = descriptor >> 4
            let table = descriptor & 0x0f
            guard precision <= 1, table <= 3, tables.insert(table).inserted else {
                throw invalid("Published JPEG quantization table declaration is invalid.")
            }
            let byteCount = precision == 0 ? 64 : 128
            guard index <= bytes.count - byteCount else {
                throw invalid("Published JPEG quantization table is truncated.")
            }
            index += byteCount
        }
        guard !tables.isEmpty else {
            throw invalid("Published JPEG has no quantization table payload.")
        }
    }

    private static func validateHuffmanTables(_ payload: ArraySlice<UInt8>) throws {
        let bytes = Array(payload)
        var index = 0
        var tables = Set<UInt8>()
        while index < bytes.count {
            guard index <= bytes.count - 17 else {
                throw invalid("Published JPEG Huffman table is truncated.")
            }
            let descriptor = bytes[index]
            index += 1
            let tableClass = descriptor >> 4
            let table = descriptor & 0x0f
            guard tableClass <= 1, table <= 3,
                  tables.insert(descriptor).inserted
            else {
                throw invalid("Published JPEG Huffman table declaration is invalid.")
            }
            let symbolCount = bytes[index..<(index + 16)].reduce(0) { $0 + Int($1) }
            index += 16
            guard symbolCount > 0, symbolCount <= 256, index <= bytes.count - symbolCount else {
                throw invalid("Published JPEG Huffman table symbols are invalid.")
            }
            index += symbolCount
        }
        guard !tables.isEmpty else {
            throw invalid("Published JPEG has no Huffman table payload.")
        }
    }

    private static func validateStartOfScan(
        _ payload: ArraySlice<UInt8>,
        components: Int
    ) throws {
        let bytes = Array(payload)
        guard bytes.count == 4 + components * 2,
              Int(bytes[0]) == components,
              bytes[bytes.count - 3] == 0,
              bytes[bytes.count - 2] == 63,
              bytes[bytes.count - 1] == 0
        else {
            throw invalid("Published JPEG baseline scan shape is invalid.")
        }
        var identifiers = Set<UInt8>()
        for index in 0..<components {
            let start = 1 + index * 2
            guard bytes[start] != 0,
                  identifiers.insert(bytes[start]).inserted,
                  bytes[start + 1] >> 4 <= 3,
                  bytes[start + 1] & 0x0f <= 3
            else {
                throw invalid("Published JPEG scan component declaration is invalid.")
            }
        }
    }

    private static func consumeJPEGEntropyAndEOI(
        _ bytes: [UInt8],
        offset: inout Int
    ) throws {
        while offset < bytes.count {
            guard bytes[offset] == 0xff else {
                offset += 1
                continue
            }
            guard offset + 1 < bytes.count else {
                throw invalid("Published JPEG ended inside entropy-coded data.")
            }
            let marker = bytes[offset + 1]
            if marker == 0x00 || (0xd0...0xd7).contains(marker) {
                offset += 2
                continue
            }
            if marker == 0xff {
                offset += 1
                continue
            }
            guard marker == 0xd9, offset + 2 == bytes.count else {
                throw invalid("Published JPEG contains multiple scans or trailing marker data.")
            }
            offset += 2
            return
        }
        throw invalid("Published JPEG is missing final EOI.")
    }

    private static func readBigEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    private static func invalid(_ reason: String) -> RoomRedesignContractValidationError {
        .invalidValue(path: "publishedRaster", reason: reason)
    }
}

public struct RoomPublishedAIReadyArchiveInput: Sendable, Equatable {
    public var archiveURL: URL
    public var publicRoomKey: String
    public var expectedPackageID: String

    public init(archiveURL: URL, publicRoomKey: String, expectedPackageID: String) {
        self.archiveURL = archiveURL
        self.publicRoomKey = publicRoomKey
        self.expectedPackageID = expectedPackageID
    }
}

public enum RoomPublishedAssetPayload: Sendable, Equatable {
    case webGeometry(RoomPublishedWebGeometry)
    case raster(RoomPublishedRaster)
    case aiReadyPackage(RoomPublishedAIReadyArchiveInput)
}

/// The only asset input accepted by the publication builder. There is no
/// initializer accepting `RoomProject`, package URL, revision history, notes,
/// GPS, or `[String: Any]`.
public struct RoomPublishedAssetInput: Sendable, Equatable {
    public var assetID: String
    public var publicRoomKey: String?
    public var assetClass: RoomPublishedAssetClass
    public var payload: RoomPublishedAssetPayload

    public init(
        assetID: String,
        publicRoomKey: String?,
        assetClass: RoomPublishedAssetClass,
        payload: RoomPublishedAssetPayload
    ) {
        self.assetID = assetID
        self.publicRoomKey = publicRoomKey
        self.assetClass = assetClass
        self.payload = payload
    }

    public static func geometry(
        assetID: String,
        publicRoomKey: String,
        geometry: RoomPublishedWebGeometry
    ) -> Self {
        .init(
            assetID: assetID,
            publicRoomKey: publicRoomKey,
            assetClass: .webGeometry,
            payload: .webGeometry(geometry)
        )
    }

    public static func raster(
        assetID: String,
        publicRoomKey: String?,
        assetClass: RoomPublishedAssetClass,
        raster: RoomPublishedRaster
    ) -> Self {
        .init(
            assetID: assetID,
            publicRoomKey: publicRoomKey,
            assetClass: assetClass,
            payload: .raster(raster)
        )
    }

    public static func aiReadyPackage(
        assetID: String,
        input: RoomPublishedAIReadyArchiveInput
    ) -> Self {
        .init(
            assetID: assetID,
            publicRoomKey: input.publicRoomKey,
            assetClass: .aiReadyPackage,
            payload: .aiReadyPackage(input)
        )
    }
}

public struct RoomPublishedAIReadyPackageBinding: Codable, Sendable, Equatable {
    public var packageID: String
    public var manifestSHA256: String
    public var publicRoomKey: String
    public var artifactPlanSHA256: String
    public var selectionSHA256: String

    public init(
        packageID: String,
        manifestSHA256: String,
        publicRoomKey: String,
        artifactPlanSHA256: String,
        selectionSHA256: String
    ) {
        self.packageID = packageID
        self.manifestSHA256 = manifestSHA256
        self.publicRoomKey = publicRoomKey
        self.artifactPlanSHA256 = artifactPlanSHA256
        self.selectionSHA256 = selectionSHA256
    }

    public func validate(at path: String) throws {
        try RoomPublishedSnapshotRules.requireIdentifier(packageID, at: "\(path).packageID")
        try RoomPublishedSnapshotRules.requireSHA256(manifestSHA256, at: "\(path).manifestSHA256")
        try RoomPublishedSnapshotRules.requireIdentifier(publicRoomKey, at: "\(path).publicRoomKey")
        try RoomPublishedSnapshotRules.requireSHA256(artifactPlanSHA256, at: "\(path).artifactPlanSHA256")
        try RoomPublishedSnapshotRules.requireSHA256(selectionSHA256, at: "\(path).selectionSHA256")
    }
}

/// This inventory is private control data. It never appears in the public
/// presentation document and only app-owned paths are assigned by the builder.
public struct RoomPublishedAssetLedgerEntry: Codable, Sendable, Equatable {
    public var assetID: String
    public var publicRoomKey: String?
    public var assetClass: RoomPublishedAssetClass
    public var relativePath: String
    public var sha256: String
    public var byteCount: UInt64
    public var mediaType: String
    public var aiReadyPackageBinding: RoomPublishedAIReadyPackageBinding?

    public init(
        assetID: String,
        publicRoomKey: String?,
        assetClass: RoomPublishedAssetClass,
        relativePath: String,
        sha256: String,
        byteCount: UInt64,
        mediaType: String,
        aiReadyPackageBinding: RoomPublishedAIReadyPackageBinding? = nil
    ) {
        self.assetID = assetID
        self.publicRoomKey = publicRoomKey
        self.assetClass = assetClass
        self.relativePath = relativePath
        self.sha256 = sha256
        self.byteCount = byteCount
        self.mediaType = mediaType
        self.aiReadyPackageBinding = aiReadyPackageBinding
    }

    public func validate(at path: String) throws {
        try RoomPublishedSnapshotRules.requireIdentifier(assetID, at: "\(path).assetID")
        if let publicRoomKey {
            try RoomPublishedSnapshotRules.requireIdentifier(publicRoomKey, at: "\(path).publicRoomKey")
        }
        _ = try RoomExportEntryPath(relativePath)
        try RoomPublishedSnapshotRules.requireSHA256(sha256, at: "\(path).sha256")
        try RoomPublishedSnapshotRules.requireByteCount(
            byteCount,
            maximum: assetClass == .aiReadyPackage
                ? RoomPublishedSnapshotRules.maximumAIReadyArchiveBytes
                : RoomPublishedSnapshotRules.maximumAssetBytes,
            at: "\(path).byteCount"
        )
        guard mediaType.count <= 127, mediaType.contains("/") else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "\(path).mediaType",
                reason: "Published asset media types must be bounded MIME values."
            )
        }
        switch assetClass {
        case .webGeometry:
            guard publicRoomKey != nil, mediaType == "application/json", relativePath.hasSuffix(".geometry.json"), aiReadyPackageBinding == nil else {
                throw RoomRedesignContractValidationError.invalidValue(path: path, reason: "Web geometry must be one room-local canonical JSON asset.")
            }
        case .webTexture, .selectedImage, .floorPlan, .approvedConcept, .brandingLogo:
            guard mediaType == "image/png" || mediaType == "image/jpeg",
                  (relativePath.hasSuffix(".png") || relativePath.hasSuffix(".jpg")),
                  aiReadyPackageBinding == nil
            else {
                throw RoomRedesignContractValidationError.invalidValue(path: path, reason: "Published raster assets must be metadata-free PNG or JPEG bytes.")
            }
            if assetClass == .brandingLogo {
                guard publicRoomKey == nil else {
                    throw RoomRedesignContractValidationError.invalidValue(path: path, reason: "A branding logo is not a room asset.")
                }
            } else {
                guard publicRoomKey != nil else {
                    throw RoomRedesignContractValidationError.invalidValue(path: path, reason: "A room derivative must bind to one public room key.")
                }
            }
        case .aiReadyPackage:
            guard publicRoomKey != nil, mediaType == "application/zip", relativePath.hasSuffix(".zip"), let aiReadyPackageBinding else {
                throw RoomRedesignContractValidationError.invalidValue(path: path, reason: "AI-ready download bytes require their independently validated binding.")
            }
            try aiReadyPackageBinding.validate(at: "\(path).aiReadyPackageBinding")
        }
    }
}

public struct RoomPublishedSelectionManifest: Codable, Sendable, Equatable {
    public static let schemaVersionValue = "roomscan-publication-selection-manifest-v1"
    public var schemaVersion: String
    public var presentationSHA256: String
    public var assets: [RoomPublishedAssetLedgerEntry]

    public init(
        schemaVersion: String = Self.schemaVersionValue,
        presentationSHA256: String,
        assets: [RoomPublishedAssetLedgerEntry]
    ) {
        self.schemaVersion = schemaVersion
        self.presentationSHA256 = presentationSHA256
        self.assets = assets
    }

    public func validate() throws {
        guard schemaVersion == Self.schemaVersionValue else {
            throw RoomRedesignContractValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        try RoomPublishedSnapshotRules.requireSHA256(presentationSHA256, at: "selection.presentationSHA256")
        try RoomPublishedSnapshotRules.requireCount(
            assets.count,
            minimum: 1,
            maximum: RoomPublishedSnapshotRules.maximumAssets,
            at: "selection.assets"
        )
        try RoomPublishedSnapshotRules.requireUnique(assets.map(\.assetID), at: "selection.assets.assetID")
        let paths = assets.map(\.relativePath)
        try RoomPublishedSnapshotRules.requireUnique(paths.map { $0.lowercased() }, at: "selection.assets.relativePath")
        guard assets.map(\.assetID) == assets.map(\.assetID).sorted() else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "selection.assets",
                reason: "Published asset ledgers must use stable asset-ID order."
            )
        }
        for (index, asset) in assets.enumerated() {
            try asset.validate(at: "selection.assets[\(index)]")
        }
    }
}

/// Internal control manifest written as `publication-manifest.json` beside a
/// portal-safe `presentation.json`. Its source bindings and digests are never
/// an authorized portal DTO.
public struct RoomPublishedPublicationManifest: Codable, Sendable, Equatable {
    public static let schemaVersionValue = "roomscan-publication-archive-v1"

    public var schemaVersion: String
    public var contractKind: RoomRedesignContractKind
    public var snapshotKind: RoomPublishedSnapshotKind
    public var sourceBindings: [RoomPublishedSourceBinding]
    public var sourceBindingsSHA256: String
    public var selectionManifestSHA256: String
    public var approval: RoomPublishedPublicationApproval
    public var presentationSHA256: String
    public var assets: [RoomPublishedAssetLedgerEntry]

    public init(
        schemaVersion: String = Self.schemaVersionValue,
        contractKind: RoomRedesignContractKind = .publicationArchive,
        snapshotKind: RoomPublishedSnapshotKind,
        sourceBindings: [RoomPublishedSourceBinding],
        sourceBindingsSHA256: String,
        selectionManifestSHA256: String,
        approval: RoomPublishedPublicationApproval,
        presentationSHA256: String,
        assets: [RoomPublishedAssetLedgerEntry]
    ) {
        self.schemaVersion = schemaVersion
        self.contractKind = contractKind
        self.snapshotKind = snapshotKind
        self.sourceBindings = sourceBindings
        self.sourceBindingsSHA256 = sourceBindingsSHA256
        self.selectionManifestSHA256 = selectionManifestSHA256
        self.approval = approval
        self.presentationSHA256 = presentationSHA256
        self.assets = assets
    }

    public func validate() throws {
        try RoomPublishedSnapshotRules.requireEnvelope(
            schemaVersion: schemaVersion,
            contractKind: contractKind,
            expected: .publicationArchive
        )
        try RoomPublishedSnapshotRules.validateSourceBindings(sourceBindings, expectedRoomKeys: nil)
        let sourceDigest = try RoomPublishedSnapshotDigests.sourceBindingsSHA256(sourceBindings)
        guard sourceBindingsSHA256 == sourceDigest else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "sourceBindingsSHA256",
                reason: "Publication source bindings must retain their exact canonical digest."
            )
        }
        try RoomPublishedSnapshotRules.requireSHA256(selectionManifestSHA256, at: "selectionManifestSHA256")
        try RoomPublishedSnapshotRules.requireSHA256(presentationSHA256, at: "presentationSHA256")
        let selectionDigest = try RoomPublishedSnapshotDigests.selectionManifestSHA256(
            presentationSHA256: presentationSHA256,
            assets: assets
        )
        guard selectionManifestSHA256 == selectionDigest else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "selectionManifestSHA256",
                reason: "Publication selection must retain its exact canonical manifest digest."
            )
        }
        try approval.validate(
            expectedSourceBindingsSHA256: sourceBindingsSHA256,
            expectedSelectionManifestSHA256: selectionManifestSHA256
        )
    }
}

public enum RoomPublishedSnapshotDigests {
    /// Stable identity for one well-formed, approved review decision. This
    /// digest is an immutable review record, not publication authority: a
    /// caller that has a prepared candidate must use the contextual overload
    /// below so the decision is proven to bind that candidate's exact source
    /// and selection digests before it can be treated as valid.
    public static func approvalSHA256(_ approval: RoomPublishedPublicationApproval) throws -> String {
        try approval.validate(
            expectedSourceBindingsSHA256: approval.sourceBindingsSHA256,
            expectedSelectionManifestSHA256: approval.selectionManifestSHA256
        )
        return try RoomRedesignCanonicalJSON.sha256(approval)
    }

    /// Stable approval identity after validating the decision against the
    /// precise source and selection that it is meant to authorize.
    public static func approvalSHA256(
        _ approval: RoomPublishedPublicationApproval,
        expectedSourceBindingsSHA256: String,
        expectedSelectionManifestSHA256: String
    ) throws -> String {
        try approval.validate(
            expectedSourceBindingsSHA256: expectedSourceBindingsSHA256,
            expectedSelectionManifestSHA256: expectedSelectionManifestSHA256
        )
        return try approvalSHA256(approval)
    }

    public static func sourceBindingsSHA256(_ bindings: [RoomPublishedSourceBinding]) throws -> String {
        try RoomPublishedSnapshotRules.validateSourceBindings(bindings, expectedRoomKeys: nil)
        return try RoomRedesignCanonicalJSON.sha256(bindings)
    }

    public static func selectionManifestSHA256(
        presentationSHA256: String,
        assets: [RoomPublishedAssetLedgerEntry]
    ) throws -> String {
        let manifest = RoomPublishedSelectionManifest(
            presentationSHA256: presentationSHA256,
            assets: assets
        )
        try manifest.validate()
        return try RoomRedesignCanonicalJSON.sha256(manifest)
    }
}

public struct RoomPublishedPreparedAsset: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case data(Data)
        case file(URL)
    }

    public let ledger: RoomPublishedAssetLedgerEntry
    let source: Source

    init(ledger: RoomPublishedAssetLedgerEntry, source: Source) {
        self.ledger = ledger
        self.source = source
    }
}

/// A prepared review has no approval yet. It is made exclusively from the
/// typed public draft and typed bounded asset inputs, never from a project or
/// private package decoder.
public struct RoomPublishedSnapshotPreparation: Sendable, Equatable {
    public let draft: RoomPublishedSnapshotDraft
    public let sourceBindings: [RoomPublishedSourceBinding]
    public let presentationData: Data
    public let preparedAssets: [RoomPublishedPreparedAsset]
    public let sourceBindingsSHA256: String
    public let selectionManifestSHA256: String

    /// Creates a local review candidate bound to this exact preparation. It is
    /// not hosted publication authority: the service must independently
    /// authorize the actor, persist its review decision, and revalidate every
    /// source/selection/flag/quota fact before it promotes an archive.
    public func makeApproval(reviewID: String, reviewedAt: Date) -> RoomPublishedPublicationApproval {
        .init(
            reviewID: reviewID,
            reviewedAt: reviewedAt,
            decision: .approved,
            sourceBindingsSHA256: sourceBindingsSHA256,
            selectionManifestSHA256: selectionManifestSHA256
        )
    }

    /// Produces an immutable local upload candidate after exact digest checks.
    /// This has no capability to publish without the hosted authorization and
    /// persistence boundary described by the Slice 6 service contract.
    public func finalize(approval: RoomPublishedPublicationApproval) throws -> RoomPublishedSnapshotReady {
        _ = try RoomPublishedSnapshotDigests.approvalSHA256(
            approval,
            expectedSourceBindingsSHA256: sourceBindingsSHA256,
            expectedSelectionManifestSHA256: selectionManifestSHA256
        )
        return RoomPublishedSnapshotReady(preparation: self, approval: approval)
    }
}

public struct RoomPublishedSnapshotReady: Sendable, Equatable {
    public let preparation: RoomPublishedSnapshotPreparation
    public let approval: RoomPublishedPublicationApproval

    init(preparation: RoomPublishedSnapshotPreparation, approval: RoomPublishedPublicationApproval) {
        self.preparation = preparation
        self.approval = approval
    }
}

/// Starts with a typed empty public draft. The API intentionally has no
/// overload accepting a private `RoomProject`, project URL, package URL,
/// revision history, raw archive, or untyped JSON dictionary.
public enum RoomPublishedSnapshotBuilder {
    public static func prepare(
        draft: RoomPublishedSnapshotDraft,
        sourceBindings: [RoomPublishedSourceBinding],
        assets: [RoomPublishedAssetInput]
    ) async throws -> RoomPublishedSnapshotPreparation {
        _ = try draft.canonicalPresentationData()
        try RoomPublishedSnapshotRules.validateSourceBindings(
            sourceBindings,
            expectedRoomKeys: draft.orderedRoomKeys
        )
        try RoomPublishedSnapshotRules.requireCount(
            assets.count,
            minimum: 1,
            maximum: RoomPublishedSnapshotRules.maximumAssets,
            at: "assets"
        )
        try RoomPublishedSnapshotRules.requireUnique(assets.map(\.assetID), at: "assets.assetID")

        var preparedAssets: [RoomPublishedPreparedAsset] = []
        for asset in assets {
            preparedAssets.append(try await RoomPublishedSnapshotRules.prepare(asset: asset, sourceBindings: sourceBindings))
        }
        preparedAssets.sort { $0.ledger.assetID < $1.ledger.assetID }
        let ledger = preparedAssets.map(\.ledger)
        let presentationData = try draft.canonicalPresentationData()
        try RoomPublishedSnapshotRules.validatePresentationReferences(draft: draft, ledger: ledger)
        let sourceDigest = try RoomPublishedSnapshotDigests.sourceBindingsSHA256(sourceBindings)
        let selectionDigest = try RoomPublishedSnapshotDigests.selectionManifestSHA256(
            presentationSHA256: RoomSHA256.hexDigest(of: presentationData),
            assets: ledger
        )
        return RoomPublishedSnapshotPreparation(
            draft: draft,
            sourceBindings: sourceBindings,
            presentationData: presentationData,
            preparedAssets: preparedAssets,
            sourceBindingsSHA256: sourceDigest,
            selectionManifestSHA256: selectionDigest
        )
    }
}

// MARK: - Shared contract rules

enum RoomPublishedSnapshotRules {
    static let maximumRooms = 64
    static let maximumAssets = 512
    static let maximumAssetsPerRoom = 128
    static let maximumLayoutElements = 1_000
    static let maximumDimensions = 64
    static let maximumWarnings = 128
    static let maximumComparisons = 64
    static let maximumGeometryVertices = 25_000
    static let maximumGeometryTriangles = 50_000
    static let maximumGeometryBytes: UInt64 = 8 * 1_024 * 1_024
    static let maximumAssetBytes: UInt64 = 32 * 1_024 * 1_024
    static let maximumAIReadyArchiveBytes: UInt64 = 512 * 1_024 * 1_024
    private static let identifierCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    private static let lowercaseHexCharacters = CharacterSet(charactersIn: "0123456789abcdef")
    private static let phoneCharacters = CharacterSet(charactersIn: "+0123456789 -()")

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
        guard value.utf8.count >= 1, value.utf8.count <= 128,
              value.unicodeScalars.allSatisfy({ $0.isASCII && identifierCharacters.contains($0) })
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: path,
                reason: "Value must be a stable ASCII identifier."
            )
        }
    }

    static func requireSHA256(_ value: String, at path: String) throws {
        guard value.count == 64,
              value.unicodeScalars.allSatisfy(lowercaseHexCharacters.contains)
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: path,
                reason: "Value must be one lowercase SHA-256 digest."
            )
        }
    }

    static func requireText(_ value: String, minimum: Int, maximum: Int, at path: String) throws {
        guard value.count >= minimum, value.count <= maximum,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: path,
                reason: "Text must be bounded and contain no control characters."
            )
        }
    }

    static func requirePhone(_ value: String, at path: String) throws {
        guard value.count >= 3, value.count <= 64,
              value.unicodeScalars.allSatisfy(phoneCharacters.contains),
              value.contains(where: { $0.isNumber })
        else {
            throw RoomRedesignContractValidationError.invalidValue(path: path, reason: "Phone details must be bounded display text.")
        }
    }

    static func requireHTTPSURL(_ value: String, at path: String) throws {
        guard value.count <= 2_048,
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host != nil,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw RoomRedesignContractValidationError.invalidValue(path: path, reason: "Website details must be one bounded HTTPS URL.")
        }
    }

    static func requireFinite(_ value: Double, minimum: Double, maximum: Double, at path: String) throws {
        guard value.isFinite, value >= minimum, value <= maximum else {
            throw RoomRedesignContractValidationError.invalidValue(path: path, reason: "Numeric values must be finite and within their public bound.")
        }
    }

    static func requireUnitInterval(_ value: Double, at path: String) throws {
        try requireFinite(value, minimum: 0, maximum: 1, at: path)
    }

    static func requireDate(_ value: Date, at path: String) throws {
        guard value.timeIntervalSinceReferenceDate.isFinite else {
            throw RoomRedesignContractValidationError.invalidValue(path: path, reason: "Dates must be finite.")
        }
    }

    static func requireByteCount(_ value: UInt64, maximum: UInt64, at path: String) throws {
        guard value > 0, value <= maximum else {
            throw RoomRedesignContractValidationError.invalidValue(path: path, reason: "Published assets must remain within the bounded derivative budget.")
        }
    }

    static func requireCount(_ value: Int, minimum: Int, maximum: Int, at path: String) throws {
        guard value >= minimum, value <= maximum else {
            throw RoomRedesignContractValidationError.invalidValue(path: path, reason: "Collection count is outside its contract bound.")
        }
    }

    static func requireUnique<T: Hashable>(_ values: [T], at path: String) throws {
        guard Set(values).count == values.count else {
            throw RoomRedesignContractValidationError.invalidValue(path: path, reason: "Values must be unique.")
        }
    }

    static func validateSourceBindings(
        _ bindings: [RoomPublishedSourceBinding],
        expectedRoomKeys: [String]?
    ) throws {
        try requireCount(bindings.count, minimum: 1, maximum: maximumRooms, at: "sourceBindings")
        try requireUnique(bindings.map(\.publicRoomKey), at: "sourceBindings.publicRoomKey")
        for (index, binding) in bindings.enumerated() {
            try binding.validate(at: "sourceBindings[\(index)]")
        }
        if let expectedRoomKeys {
            guard bindings.map(\.publicRoomKey) == expectedRoomKeys else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: "sourceBindings",
                    reason: "Source bindings must exactly preserve the reviewed room order."
                )
            }
        }
    }

    static func prepare(
        asset: RoomPublishedAssetInput,
        sourceBindings: [RoomPublishedSourceBinding]
    ) async throws -> RoomPublishedPreparedAsset {
        try requireIdentifier(asset.assetID, at: "assets.assetID")
        if let publicRoomKey = asset.publicRoomKey {
            try requireIdentifier(publicRoomKey, at: "assets.publicRoomKey")
            guard sourceBindings.contains(where: { $0.publicRoomKey == publicRoomKey }) else {
                throw RoomRedesignContractValidationError.invalidValue(path: "assets.publicRoomKey", reason: "A published derivative must bind to one reviewed source room.")
            }
        }
        switch asset.payload {
        case let .webGeometry(geometry):
            guard asset.assetClass == .webGeometry, let publicRoomKey = asset.publicRoomKey else {
                throw RoomRedesignContractValidationError.invalidValue(path: "assets", reason: "Only a room-local webGeometry input may carry typed geometry.")
            }
            try geometry.validate()
            let data = try RoomRedesignCanonicalJSON.encode(geometry)
            guard UInt64(data.count) <= maximumGeometryBytes else {
                throw RoomRedesignContractValidationError.invalidValue(path: "assets", reason: "Web geometry exceeds its bounded public byte budget.")
            }
            let ledger = RoomPublishedAssetLedgerEntry(
                assetID: asset.assetID,
                publicRoomKey: publicRoomKey,
                assetClass: .webGeometry,
                relativePath: "assets/\(asset.assetID).geometry.json",
                sha256: RoomSHA256.hexDigest(of: data),
                byteCount: UInt64(data.count),
                mediaType: "application/json"
            )
            try ledger.validate(at: "assets.\(asset.assetID)")
            return .init(ledger: ledger, source: .data(data))

        case let .raster(raster):
            guard [.webTexture, .selectedImage, .floorPlan, .approvedConcept, .brandingLogo].contains(asset.assetClass) else {
                throw RoomRedesignContractValidationError.invalidValue(path: "assets", reason: "Only approved raster derivative classes may carry raster bytes.")
            }
            let sanitizedData = try RoomPublishedRasterValidator.sanitize(
                raster.data,
                mediaType: raster.mediaType
            )
            let expectsRoom = asset.assetClass != .brandingLogo
            guard (expectsRoom && asset.publicRoomKey != nil) || (!expectsRoom && asset.publicRoomKey == nil) else {
                throw RoomRedesignContractValidationError.invalidValue(path: "assets.publicRoomKey", reason: "Room derivatives and branding logos have distinct scopes.")
            }
            let ledger = RoomPublishedAssetLedgerEntry(
                assetID: asset.assetID,
                publicRoomKey: asset.publicRoomKey,
                assetClass: asset.assetClass,
                relativePath: "assets/\(asset.assetID).\(raster.mediaType.fileExtension)",
                sha256: RoomSHA256.hexDigest(of: sanitizedData),
                byteCount: UInt64(sanitizedData.count),
                mediaType: raster.mediaType.rawValue
            )
            try ledger.validate(at: "assets.\(asset.assetID)")
            return .init(ledger: ledger, source: .data(sanitizedData))

        case .aiReadyPackage:
            // The archive implementation owns actual ZIP extraction and binds
            // the returned manifest facts before it becomes a prepared asset.
            return try await RoomPublicationArchive.prepareAIReadyAsset(
                asset: asset,
                sourceBindings: sourceBindings
            )
        }
    }

    static func validatePresentationReferences(
        draft: RoomPublishedSnapshotDraft,
        ledger: [RoomPublishedAssetLedgerEntry]
    ) throws {
        let byID = Dictionary(uniqueKeysWithValues: ledger.map { ($0.assetID, $0) })
        guard byID.count == ledger.count else {
            throw RoomRedesignContractValidationError.invalidValue(path: "assets", reason: "Published assets must be unique.")
        }
        if let logoID = draft.branding.logoAssetID {
            guard byID[logoID]?.assetClass == .brandingLogo else {
                throw RoomRedesignContractValidationError.invalidValue(path: "branding.logoAssetID", reason: "Branding can reference only its explicit logo derivative.")
            }
        }
        if let aiReadyID = draft.downloads.aiReadyPackageAssetID {
            guard byID[aiReadyID]?.assetClass == .aiReadyPackage else {
                throw RoomRedesignContractValidationError.invalidValue(path: "downloads.aiReadyPackageAssetID", reason: "AI download policy must bind one validated AI-ready package asset.")
            }
        }
        for room in draft.publicRooms() {
            func require(_ assetID: String, _ assetClass: RoomPublishedAssetClass, _ path: String) throws {
                guard let asset = byID[assetID], asset.assetClass == assetClass, asset.publicRoomKey == room.roomKey else {
                    throw RoomRedesignContractValidationError.invalidValue(path: path, reason: "Presentation asset references must resolve to the exact reviewed room-local derivative class.")
                }
            }
            try require(room.assets.webGeometryAssetID, .webGeometry, "room.assets.webGeometryAssetID")
            try require(room.assets.floorPlanAssetID, .floorPlan, "room.assets.floorPlanAssetID")
            for assetID in room.assets.selectedImageAssetIDs {
                try require(assetID, .selectedImage, "room.assets.selectedImageAssetIDs")
            }
            for assetID in room.assets.webTextureAssetIDs {
                try require(assetID, .webTexture, "room.assets.webTextureAssetIDs")
            }
            for assetID in room.assets.approvedConceptAssetIDs {
                try require(assetID, .approvedConcept, "room.assets.approvedConceptAssetIDs")
            }
            for comparison in room.comparisons {
                try require(comparison.originalAssetID, .selectedImage, "room.comparisons.originalAssetID")
                try require(comparison.conceptAssetID, .approvedConcept, "room.comparisons.conceptAssetID")
            }
        }
    }
}
