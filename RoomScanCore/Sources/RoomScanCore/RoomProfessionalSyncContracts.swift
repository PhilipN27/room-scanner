import Foundation

/// Errors for the additive professional-sync wire contracts. These contracts
/// are intentionally separate from the frozen working-sync v1 vocabulary.
public enum RoomProfessionalSyncContractError: Error, Sendable, Equatable {
    case invalidJSON
    case rootMustBeObject
    /// The public Codable conformances are for trusted typed composition only.
    /// Untrusted bytes must enter through `RoomProfessionalSyncCanonicalJSON`.
    case untrustedDecoding
    case duplicateKey(path: String, key: String)
    case missingKey(path: String, key: String)
    case unknownKey(path: String, key: String)
    case unsupportedSchemaVersion(String)
    case invalidValue(path: String, reason: String)
    case noncanonicalJSON
}

/// Professional operations are deliberately limited to initial creation,
/// expected-head append, and a separate raw attachment. There is no merge or
/// last-writer-wins operation in this vocabulary.
public enum RoomProfessionalSyncOperation: String, Codable, Sendable, Equatable, CaseIterable {
    case createInitialHead
    case appendRevision
    case attachRawArchive
}

/// Hosted professional-sync transport ceiling. This does not apply to local
/// packages, guest work, CloudKit backup, or any general archive facility.
public enum RoomProfessionalHostedSyncLimits {
    public static let maximumArchiveBytes: UInt64 = 67_108_864
}

/// A typed intent makes the initial nil-head and raw attachment no-head facts
/// explicit without relying on a sentinel revision identifier.
public enum RoomProfessionalSyncIntent: Sendable, Equatable {
    case createInitialHead(RoomInitialProjectSyncV1)
    case appendRevision(RoomProjectRevisionAppendV1)
    case attachRawArchive(RoomRawArchiveAttachmentV1)

    public var operation: RoomProfessionalSyncOperation {
        switch self {
        case .createInitialHead: return .createInitialHead
        case .appendRevision: return .appendRevision
        case .attachRawArchive: return .attachRawArchive
        }
    }

    /// Only an immutable append carries an expected hosted head. Initial
    /// creation and raw attachment are deliberately head-neutral.
    public var expectedHeadRevisionID: String? {
        switch self {
        case .createInitialHead, .attachRawArchive:
            return nil
        case let .appendRevision(append):
            return append.expectedHeadRevisionID
        }
    }
}

public struct RoomInitialProjectSyncV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "roomscan-initial-project-sync-v1"

    public let schemaVersion: String
    public let sourceProjectID: String
    public let proposedRevisionID: String
    public let workingSetManifestSHA256: String
    public let archiveSHA256: String
    public let archiveByteCount: UInt64

    public init(
        schemaVersion: String = Self.schemaVersion,
        sourceProjectID: String,
        proposedRevisionID: String,
        workingSetManifestSHA256: String,
        archiveSHA256: String,
        archiveByteCount: UInt64
    ) throws {
        self.schemaVersion = schemaVersion
        self.sourceProjectID = sourceProjectID
        self.proposedRevisionID = proposedRevisionID
        self.workingSetManifestSHA256 = workingSetManifestSHA256
        self.archiveSHA256 = archiveSHA256
        self.archiveByteCount = archiveByteCount
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == Self.schemaVersion else {
            throw RoomProfessionalSyncContractError.unsupportedSchemaVersion(schemaVersion)
        }
        try RoomProfessionalSyncContractRules.requireIdentifier(sourceProjectID, at: "sourceProjectID")
        try RoomProfessionalSyncContractRules.requireIdentifier(proposedRevisionID, at: "proposedRevisionID")
        try RoomProfessionalSyncContractRules.requireSHA256(
            workingSetManifestSHA256,
            at: "workingSetManifestSHA256"
        )
        try RoomProfessionalSyncContractRules.requireSHA256(archiveSHA256, at: "archiveSHA256")
        try RoomProfessionalSyncContractRules.requireHostedArchiveByteCount(archiveByteCount, at: "archiveByteCount")
    }

    public init(from decoder: Decoder) throws {
        try RoomProfessionalTrustedDecoding.requireTrusted(decoder)
        let container = try RoomProfessionalStrictCoding.container(
            decoder,
            allowed: ["schemaVersion", "sourceProjectID", "proposedRevisionID", "workingSetManifestSHA256", "archiveSHA256", "archiveByteCount"],
            required: ["schemaVersion", "sourceProjectID", "proposedRevisionID", "workingSetManifestSHA256", "archiveSHA256", "archiveByteCount"]
        )
        schemaVersion = try container.decode(String.self, forKey: .init("schemaVersion"))
        sourceProjectID = try container.decode(String.self, forKey: .init("sourceProjectID"))
        proposedRevisionID = try container.decode(String.self, forKey: .init("proposedRevisionID"))
        workingSetManifestSHA256 = try container.decode(String.self, forKey: .init("workingSetManifestSHA256"))
        archiveSHA256 = try container.decode(String.self, forKey: .init("archiveSHA256"))
        archiveByteCount = try container.decode(UInt64.self, forKey: .init("archiveByteCount"))
        try validate()
    }
}

/// The append contract has a non-null expected hosted head by construction.
/// Its proposed revision must be a distinct immutable candidate.
public struct RoomProjectRevisionAppendV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "roomscan-project-revision-append-v1"

    public let schemaVersion: String
    public let projectID: String
    public let expectedHeadRevisionID: String
    public let proposedRevisionID: String
    public let workingSetManifestSHA256: String
    public let archiveSHA256: String
    public let archiveByteCount: UInt64

    public init(
        schemaVersion: String = Self.schemaVersion,
        projectID: String,
        expectedHeadRevisionID: String,
        proposedRevisionID: String,
        workingSetManifestSHA256: String,
        archiveSHA256: String,
        archiveByteCount: UInt64
    ) throws {
        self.schemaVersion = schemaVersion
        self.projectID = projectID
        self.expectedHeadRevisionID = expectedHeadRevisionID
        self.proposedRevisionID = proposedRevisionID
        self.workingSetManifestSHA256 = workingSetManifestSHA256
        self.archiveSHA256 = archiveSHA256
        self.archiveByteCount = archiveByteCount
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == Self.schemaVersion else {
            throw RoomProfessionalSyncContractError.unsupportedSchemaVersion(schemaVersion)
        }
        try RoomProfessionalSyncContractRules.requireIdentifier(projectID, at: "projectID")
        try RoomProfessionalSyncContractRules.requireIdentifier(
            expectedHeadRevisionID,
            at: "expectedHeadRevisionID"
        )
        try RoomProfessionalSyncContractRules.requireIdentifier(proposedRevisionID, at: "proposedRevisionID")
        guard proposedRevisionID != expectedHeadRevisionID else {
            throw RoomProfessionalSyncContractError.invalidValue(
                path: "proposedRevisionID",
                reason: "An append must propose a new immutable revision beyond its expected head."
            )
        }
        try RoomProfessionalSyncContractRules.requireSHA256(
            workingSetManifestSHA256,
            at: "workingSetManifestSHA256"
        )
        try RoomProfessionalSyncContractRules.requireSHA256(archiveSHA256, at: "archiveSHA256")
        try RoomProfessionalSyncContractRules.requireHostedArchiveByteCount(archiveByteCount, at: "archiveByteCount")
    }

    public init(from decoder: Decoder) throws {
        try RoomProfessionalTrustedDecoding.requireTrusted(decoder)
        let container = try RoomProfessionalStrictCoding.container(
            decoder,
            allowed: ["schemaVersion", "projectID", "expectedHeadRevisionID", "proposedRevisionID", "workingSetManifestSHA256", "archiveSHA256", "archiveByteCount"],
            required: ["schemaVersion", "projectID", "expectedHeadRevisionID", "proposedRevisionID", "workingSetManifestSHA256", "archiveSHA256", "archiveByteCount"]
        )
        schemaVersion = try container.decode(String.self, forKey: .init("schemaVersion"))
        projectID = try container.decode(String.self, forKey: .init("projectID"))
        expectedHeadRevisionID = try container.decode(String.self, forKey: .init("expectedHeadRevisionID"))
        proposedRevisionID = try container.decode(String.self, forKey: .init("proposedRevisionID"))
        workingSetManifestSHA256 = try container.decode(String.self, forKey: .init("workingSetManifestSHA256"))
        archiveSHA256 = try container.decode(String.self, forKey: .init("archiveSHA256"))
        archiveByteCount = try container.decode(UInt64.self, forKey: .init("archiveByteCount"))
        try validate()
    }
}

public enum RoomRawDisclosureDecision: String, Codable, Sendable, Equatable {
    case accepted
    case rejected
}

/// A raw review is separately versioned and source-bound. Its reviewed
/// selection digest must describe exactly the raw ledger that will be built.
public struct RoomRawDisclosureReview: Codable, Sendable, Equatable {
    public static let schemaVersion = "roomscan-raw-disclosure-review-v1"

    public let schemaVersion: String
    public let reviewID: String
    public let sourceRevision: RoomRedesignSourceRevision
    public let reviewedSelectionSHA256: String
    public let reviewedAt: Date
    public let decision: RoomRawDisclosureDecision
    public let preciseGPSExcluded: Bool

    public init(
        schemaVersion: String = Self.schemaVersion,
        reviewID: String,
        sourceRevision: RoomRedesignSourceRevision,
        reviewedSelectionSHA256: String,
        reviewedAt: Date,
        decision: RoomRawDisclosureDecision,
        preciseGPSExcluded: Bool = true
    ) throws {
        self.schemaVersion = schemaVersion
        self.reviewID = reviewID
        self.sourceRevision = sourceRevision
        self.reviewedSelectionSHA256 = reviewedSelectionSHA256
        self.reviewedAt = reviewedAt
        self.decision = decision
        self.preciseGPSExcluded = preciseGPSExcluded
        try validate()
    }

    public func validate(requireAccepted: Bool = false) throws {
        guard schemaVersion == Self.schemaVersion else {
            throw RoomProfessionalSyncContractError.unsupportedSchemaVersion(schemaVersion)
        }
        try RoomProfessionalSyncContractRules.requireIdentifier(reviewID, at: "reviewID")
        do {
            try sourceRevision.validate()
        } catch {
            throw RoomProfessionalSyncContractError.invalidValue(
                path: "sourceRevision",
                reason: "Raw disclosure review must bind one valid immutable source revision."
            )
        }
        try RoomProfessionalSyncContractRules.requireSHA256(
            reviewedSelectionSHA256,
            at: "reviewedSelectionSHA256"
        )
        try RoomProfessionalSyncContractRules.requireDate(reviewedAt, at: "reviewedAt")
        guard preciseGPSExcluded else {
            throw RoomProfessionalSyncContractError.invalidValue(
                path: "preciseGPSExcluded",
                reason: "Raw archive review must explicitly exclude precise GPS."
            )
        }
        guard !requireAccepted || decision == .accepted else {
            throw RoomProfessionalSyncContractError.invalidValue(
                path: "decision",
                reason: "Raw archive construction requires an accepted disclosure review."
            )
        }
    }

    public init(from decoder: Decoder) throws {
        try RoomProfessionalTrustedDecoding.requireTrusted(decoder)
        let container = try RoomProfessionalStrictCoding.container(
            decoder,
            allowed: ["schemaVersion", "reviewID", "sourceRevision", "reviewedSelectionSHA256", "reviewedAt", "decision", "preciseGPSExcluded"],
            required: ["schemaVersion", "reviewID", "sourceRevision", "reviewedSelectionSHA256", "reviewedAt", "decision", "preciseGPSExcluded"]
        )
        schemaVersion = try container.decode(String.self, forKey: .init("schemaVersion"))
        reviewID = try container.decode(String.self, forKey: .init("reviewID"))
        sourceRevision = try container.decode(RoomProfessionalSourceRevisionWire.self, forKey: .init("sourceRevision")).model
        reviewedSelectionSHA256 = try container.decode(String.self, forKey: .init("reviewedSelectionSHA256"))
        reviewedAt = try container.decode(Date.self, forKey: .init("reviewedAt"))
        decision = try container.decode(RoomRawDisclosureDecision.self, forKey: .init("decision"))
        preciseGPSExcluded = try container.decode(Bool.self, forKey: .init("preciseGPSExcluded"))
        try validate()
    }
}

/// The separately uploaded raw archive binds to a reviewed immutable revision;
/// it has no expected-head field and cannot advance a project head.
public struct RoomRawArchiveAttachmentV1: Codable, Sendable, Equatable {
    public static let schemaVersion = "roomscan-raw-archive-attachment-v1"

    public let schemaVersion: String
    public let projectID: String
    public let revisionID: String
    public let review: RoomRawDisclosureReview
    public let manifestSHA256: String
    public let archiveSHA256: String
    public let archiveByteCount: UInt64

    public init(
        schemaVersion: String = Self.schemaVersion,
        projectID: String,
        revisionID: String,
        review: RoomRawDisclosureReview,
        manifestSHA256: String,
        archiveSHA256: String,
        archiveByteCount: UInt64
    ) throws {
        self.schemaVersion = schemaVersion
        self.projectID = projectID
        self.revisionID = revisionID
        self.review = review
        self.manifestSHA256 = manifestSHA256
        self.archiveSHA256 = archiveSHA256
        self.archiveByteCount = archiveByteCount
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == Self.schemaVersion else {
            throw RoomProfessionalSyncContractError.unsupportedSchemaVersion(schemaVersion)
        }
        try RoomProfessionalSyncContractRules.requireIdentifier(projectID, at: "projectID")
        try RoomProfessionalSyncContractRules.requireIdentifier(revisionID, at: "revisionID")
        try review.validate(requireAccepted: true)
        guard review.sourceRevision.projectID == projectID,
              review.sourceRevision.revisionID == revisionID
        else {
            throw RoomProfessionalSyncContractError.invalidValue(
                path: "review.sourceRevision",
                reason: "Raw archive attachment must match the reviewed project and immutable revision."
            )
        }
        try RoomProfessionalSyncContractRules.requireSHA256(manifestSHA256, at: "manifestSHA256")
        try RoomProfessionalSyncContractRules.requireSHA256(archiveSHA256, at: "archiveSHA256")
        try RoomProfessionalSyncContractRules.requireHostedArchiveByteCount(archiveByteCount, at: "archiveByteCount")
    }

    public init(from decoder: Decoder) throws {
        try RoomProfessionalTrustedDecoding.requireTrusted(decoder)
        let container = try RoomProfessionalStrictCoding.container(
            decoder,
            allowed: ["schemaVersion", "projectID", "revisionID", "review", "manifestSHA256", "archiveSHA256", "archiveByteCount"],
            required: ["schemaVersion", "projectID", "revisionID", "review", "manifestSHA256", "archiveSHA256", "archiveByteCount"]
        )
        schemaVersion = try container.decode(String.self, forKey: .init("schemaVersion"))
        projectID = try container.decode(String.self, forKey: .init("projectID"))
        revisionID = try container.decode(String.self, forKey: .init("revisionID"))
        review = try container.decode(RoomRawDisclosureReview.self, forKey: .init("review"))
        manifestSHA256 = try container.decode(String.self, forKey: .init("manifestSHA256"))
        archiveSHA256 = try container.decode(String.self, forKey: .init("archiveSHA256"))
        archiveByteCount = try container.decode(UInt64.self, forKey: .init("archiveByteCount"))
        try validate()
    }
}

/// Descriptor for the outer professional working-set archive. It is defined
/// here so future archive readers and transports share a single strict v1
/// vocabulary without changing the existing CloudKit backup descriptor.
public struct RoomProfessionalWorkingSetDescriptor: Codable, Sendable, Equatable {
    public static let schemaVersion = "roomscan-professional-working-set-v1"

    public let schemaVersion: String
    public let snapshotID: String
    public let projectID: String
    public let headRevisionID: String
    public let packageDescriptor: RoomCloudBackupDescriptor
    public let archiveSHA256: String
    public let archiveByteCount: UInt64

    public init(
        schemaVersion: String = Self.schemaVersion,
        snapshotID: String,
        projectID: String,
        headRevisionID: String,
        packageDescriptor: RoomCloudBackupDescriptor,
        archiveSHA256: String,
        archiveByteCount: UInt64
    ) throws {
        self.schemaVersion = schemaVersion
        self.snapshotID = snapshotID
        self.projectID = projectID
        self.headRevisionID = headRevisionID
        self.packageDescriptor = packageDescriptor
        self.archiveSHA256 = archiveSHA256
        self.archiveByteCount = archiveByteCount
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == Self.schemaVersion else {
            throw RoomProfessionalSyncContractError.unsupportedSchemaVersion(schemaVersion)
        }
        try RoomProfessionalSyncContractRules.requireSHA256(snapshotID, at: "snapshotID")
        try RoomProfessionalSyncContractRules.requireIdentifier(projectID, at: "projectID")
        try RoomProfessionalSyncContractRules.requireIdentifier(headRevisionID, at: "headRevisionID")
        do {
            try RoomProjectBackupArchive.validate(descriptor: packageDescriptor)
        } catch {
            throw RoomProfessionalSyncContractError.invalidValue(
                path: "packageDescriptor",
                reason: "Professional working sets require a complete validated package-backup descriptor."
            )
        }
        guard packageDescriptor.projectID == projectID,
              packageDescriptor.headRevisionID == headRevisionID
        else {
            throw RoomProfessionalSyncContractError.invalidValue(
                path: "packageDescriptor",
                reason: "Inner package backup must bind the same project and head as the outer working set."
            )
        }
        try RoomProfessionalSyncContractRules.requireSHA256(archiveSHA256, at: "archiveSHA256")
        try RoomProfessionalSyncContractRules.requireHostedArchiveByteCount(archiveByteCount, at: "archiveByteCount")
    }

    public init(from decoder: Decoder) throws {
        try RoomProfessionalTrustedDecoding.requireTrusted(decoder)
        let container = try RoomProfessionalStrictCoding.container(
            decoder,
            allowed: ["schemaVersion", "snapshotID", "projectID", "headRevisionID", "packageDescriptor", "archiveSHA256", "archiveByteCount"],
            required: ["schemaVersion", "snapshotID", "projectID", "headRevisionID", "packageDescriptor", "archiveSHA256", "archiveByteCount"]
        )
        schemaVersion = try container.decode(String.self, forKey: .init("schemaVersion"))
        snapshotID = try container.decode(String.self, forKey: .init("snapshotID"))
        projectID = try container.decode(String.self, forKey: .init("projectID"))
        headRevisionID = try container.decode(String.self, forKey: .init("headRevisionID"))
        packageDescriptor = try container.decode(RoomCloudBackupDescriptor.self, forKey: .init("packageDescriptor"))
        archiveSHA256 = try container.decode(String.self, forKey: .init("archiveSHA256"))
        archiveByteCount = try container.decode(UInt64.self, forKey: .init("archiveByteCount"))
        try validate()
    }
}

/// Public trust boundary for professional-only contract bytes. It rejects
/// duplicate and unknown JSON keys before accepting a canonical byte stream.
///
/// The public `Decodable` conformances exist for typed composition, but direct
/// `JSONDecoder` use is rejected: Foundation discards duplicate members before
/// it invokes `init(from:)`. Untrusted bytes must be decoded through this
/// scanner-backed boundary.
public enum RoomProfessionalSyncCanonicalJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try RoomRedesignCanonicalJSON.encode(value)
    }

    public static func decodeInitial(_ data: Data) throws -> RoomInitialProjectSyncV1 {
        try decodeCanonical(data, type: RoomInitialProjectSyncV1.self) { root in
            _ = try RoomProfessionalSyncJSONValidation.object(
                root,
                allowed: ["schemaVersion", "sourceProjectID", "proposedRevisionID", "workingSetManifestSHA256", "archiveSHA256", "archiveByteCount"],
                required: ["schemaVersion", "sourceProjectID", "proposedRevisionID", "workingSetManifestSHA256", "archiveSHA256", "archiveByteCount"],
                path: "$"
            )
        }
    }

    public static func decodeAppend(_ data: Data) throws -> RoomProjectRevisionAppendV1 {
        try decodeCanonical(data, type: RoomProjectRevisionAppendV1.self) { root in
            _ = try RoomProfessionalSyncJSONValidation.object(
                root,
                allowed: ["schemaVersion", "projectID", "expectedHeadRevisionID", "proposedRevisionID", "workingSetManifestSHA256", "archiveSHA256", "archiveByteCount"],
                required: ["schemaVersion", "projectID", "expectedHeadRevisionID", "proposedRevisionID", "workingSetManifestSHA256", "archiveSHA256", "archiveByteCount"],
                path: "$"
            )
        }
    }

    public static func decodeRawReview(_ data: Data) throws -> RoomRawDisclosureReview {
        try decodeCanonical(data, type: RoomRawDisclosureReview.self) { root in
            try RoomProfessionalSyncJSONValidation.validateRawReview(root, path: "$")
        }
    }

    public static func decodeRawAttachment(_ data: Data) throws -> RoomRawArchiveAttachmentV1 {
        try decodeCanonical(data, type: RoomRawArchiveAttachmentV1.self) { root in
            let root = try RoomProfessionalSyncJSONValidation.object(
                root,
                allowed: ["schemaVersion", "projectID", "revisionID", "review", "manifestSHA256", "archiveSHA256", "archiveByteCount"],
                required: ["schemaVersion", "projectID", "revisionID", "review", "manifestSHA256", "archiveSHA256", "archiveByteCount"],
                path: "$"
            )
            guard let review = root["review"] as? [String: Any] else {
                throw RoomProfessionalSyncContractError.invalidValue(path: "$.review", reason: "Value must be an object.")
            }
            try RoomProfessionalSyncJSONValidation.validateRawReview(review, path: "$.review")
        }
    }

    public static func decodeWorkingSetDescriptor(_ data: Data) throws -> RoomProfessionalWorkingSetDescriptor {
        try decodeCanonical(data, type: RoomProfessionalWorkingSetDescriptor.self) { root in
            _ = try RoomProfessionalSyncJSONValidation.object(
                root,
                allowed: ["schemaVersion", "snapshotID", "projectID", "headRevisionID", "packageDescriptor", "archiveSHA256", "archiveByteCount"],
                required: ["schemaVersion", "snapshotID", "projectID", "headRevisionID", "packageDescriptor", "archiveSHA256", "archiveByteCount"],
                path: "$"
            )
        }
    }

    /// Internal archive-manifest bridge. Archive values supply their own
    /// strict keyed decoding; this preserves the same duplicate-member scan,
    /// trusted decoder token, and exact canonical-byte check used by the
    /// public professional-sync trust boundary.
    static func decodeStrict<T: Decodable & Encodable>(
        _ data: Data,
        as type: T.Type
    ) throws -> T {
        try RoomProfessionalJSONMemberScanner.rejectDuplicateObjectMembers(in: data)
        do {
            guard try JSONSerialization.jsonObject(with: data) is [String: Any] else {
                throw RoomProfessionalSyncContractError.rootMustBeObject
            }
        } catch let error as RoomProfessionalSyncContractError {
            throw error
        } catch {
            throw RoomProfessionalSyncContractError.invalidJSON
        }
        let model = try RoomProfessionalTrustedDecoding.makeDecoder().decode(T.self, from: data)
        guard try encode(model) == data else {
            throw RoomProfessionalSyncContractError.noncanonicalJSON
        }
        return model
    }

    private static func decodeCanonical<T: Decodable & Encodable>(
        _ data: Data,
        type: T.Type,
        validateRoot: ([String: Any]) throws -> Void
    ) throws -> T {
        try RoomProfessionalJSONMemberScanner.rejectDuplicateObjectMembers(in: data)
        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw RoomProfessionalSyncContractError.rootMustBeObject
            }
            root = object
        } catch let error as RoomProfessionalSyncContractError {
            throw error
        } catch {
            throw RoomProfessionalSyncContractError.invalidJSON
        }
        try validateRoot(root)
        let model: T
        do {
            model = try RoomProfessionalTrustedDecoding.makeDecoder().decode(T.self, from: data)
        } catch let error as RoomProfessionalSyncContractError {
            throw error
        } catch {
            throw RoomProfessionalSyncContractError.invalidJSON
        }
        guard try encode(model) == data else {
            throw RoomProfessionalSyncContractError.noncanonicalJSON
        }
        return model
    }
}

struct RoomProfessionalDynamicCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        return nil
    }
}

enum RoomProfessionalStrictCoding {
    static func container(
        _ decoder: Decoder,
        allowed: Set<String>,
        required: Set<String>
    ) throws -> KeyedDecodingContainer<RoomProfessionalDynamicCodingKey> {
        let container = try decoder.container(keyedBy: RoomProfessionalDynamicCodingKey.self)
        let found = Set(container.allKeys.map(\.stringValue))
        for key in found.sorted() where !allowed.contains(key) {
            throw RoomProfessionalSyncContractError.unknownKey(path: "$", key: key)
        }
        for key in required.sorted() where !found.contains(key) {
            throw RoomProfessionalSyncContractError.missingKey(path: "$", key: key)
        }
        return container
    }
}

/// Keeps the scanner-backed canonical boundary as the only route that may
/// invoke these public `Decodable` conformances for external JSON. The private
/// identity token cannot be reproduced by an ordinary `JSONDecoder` caller.
enum RoomProfessionalTrustedDecoding {
    private final class Token {}

    private static let key = CodingUserInfoKey(rawValue: "RoomProfessionalSyncTrustedDecoding")!
    private static let token = Token()

    static func makeDecoder() -> JSONDecoder {
        let decoder = RoomJSONCoding.makeDecoder()
        decoder.userInfo[key] = token
        return decoder
    }

    static func requireTrusted(_ decoder: Decoder) throws {
        guard let suppliedToken = decoder.userInfo[key] as? Token,
              suppliedToken === token
        else {
            throw RoomProfessionalSyncContractError.untrustedDecoding
        }
    }
}

private struct RoomProfessionalSourceRevisionWire: Decodable {
    let projectID: String
    let revisionID: String
    let coordinateSpaceEpochID: String
    let packageSchemaVersion: String
    let semanticSHA256: String
    let revisionManifestSHA256: String

    var model: RoomRedesignSourceRevision {
        RoomRedesignSourceRevision(
            projectID: projectID,
            revisionID: revisionID,
            coordinateSpaceEpochID: coordinateSpaceEpochID,
            packageSchemaVersion: packageSchemaVersion,
            semanticSHA256: semanticSHA256,
            revisionManifestSHA256: revisionManifestSHA256
        )
    }

    init(from decoder: Decoder) throws {
        let container = try RoomProfessionalStrictCoding.container(
            decoder,
            allowed: ["projectID", "revisionID", "coordinateSpaceEpochID", "packageSchemaVersion", "semanticSHA256", "revisionManifestSHA256"],
            required: ["projectID", "revisionID", "coordinateSpaceEpochID", "packageSchemaVersion", "semanticSHA256", "revisionManifestSHA256"]
        )
        projectID = try container.decode(String.self, forKey: .init("projectID"))
        revisionID = try container.decode(String.self, forKey: .init("revisionID"))
        coordinateSpaceEpochID = try container.decode(String.self, forKey: .init("coordinateSpaceEpochID"))
        packageSchemaVersion = try container.decode(String.self, forKey: .init("packageSchemaVersion"))
        semanticSHA256 = try container.decode(String.self, forKey: .init("semanticSHA256"))
        revisionManifestSHA256 = try container.decode(String.self, forKey: .init("revisionManifestSHA256"))
    }
}

private enum RoomProfessionalSyncContractRules {
    static func requireIdentifier(_ value: String, at path: String) throws {
        guard RoomPathValidation.isSafeStableIdentifier(value) else {
            throw RoomProfessionalSyncContractError.invalidValue(
                path: path,
                reason: "Value must be a stable ASCII identifier."
            )
        }
    }

    static func requireSHA256(_ value: String, at path: String) throws {
        guard value.count == 64,
              value.unicodeScalars.allSatisfy({ (48...57).contains($0.value) || (97...102).contains($0.value) })
        else {
            throw RoomProfessionalSyncContractError.invalidValue(
                path: path,
                reason: "Value must be a lowercase SHA-256 digest."
            )
        }
    }

    static func requireHostedArchiveByteCount(_ value: UInt64, at path: String) throws {
        guard value > 0, value <= RoomProfessionalHostedSyncLimits.maximumArchiveBytes else {
            throw RoomProfessionalSyncContractError.invalidValue(
                path: path,
                reason: "Hosted professional archive byte count is outside the supported range."
            )
        }
    }

    static func requireDate(_ value: Date, at path: String) throws {
        let seconds = value.timeIntervalSince1970
        guard seconds.isFinite else {
            throw RoomProfessionalSyncContractError.invalidValue(
                path: path,
                reason: "Date must be finite."
            )
        }
        guard seconds.rounded(.towardZero) == seconds else {
            throw RoomProfessionalSyncContractError.invalidValue(
                path: path,
                reason: "Date must be an exact whole-second UTC timestamp."
            )
        }
    }
}

private enum RoomProfessionalSyncJSONValidation {
    static func object(
        _ object: [String: Any],
        allowed: Set<String>,
        required: Set<String>,
        path: String
    ) throws -> [String: Any] {
        for key in object.keys.sorted() where !allowed.contains(key) {
            throw RoomProfessionalSyncContractError.unknownKey(path: path, key: key)
        }
        for key in required.sorted() where object[key] == nil {
            throw RoomProfessionalSyncContractError.missingKey(path: path, key: key)
        }
        return object
    }

    static func validateRawReview(_ object: [String: Any], path: String) throws {
        let root = try self.object(
            object,
            allowed: ["schemaVersion", "reviewID", "sourceRevision", "reviewedSelectionSHA256", "reviewedAt", "decision", "preciseGPSExcluded"],
            required: ["schemaVersion", "reviewID", "sourceRevision", "reviewedSelectionSHA256", "reviewedAt", "decision", "preciseGPSExcluded"],
            path: path
        )
        guard let source = root["sourceRevision"] as? [String: Any] else {
            throw RoomProfessionalSyncContractError.invalidValue(
                path: "\(path).sourceRevision",
                reason: "Value must be an object."
            )
        }
        _ = try self.object(
            source,
            allowed: ["projectID", "revisionID", "coordinateSpaceEpochID", "packageSchemaVersion", "semanticSHA256", "revisionManifestSHA256"],
            required: ["projectID", "revisionID", "coordinateSpaceEpochID", "packageSchemaVersion", "semanticSHA256", "revisionManifestSHA256"],
            path: "\(path).sourceRevision"
        )
    }
}

/// Small JSON parser used only to reject duplicate object member names before
/// Foundation's dictionary-based JSON parser collapses them.
private struct RoomProfessionalJSONMemberScanner {
    private let scalars: [UnicodeScalar]
    private var index = 0

    private init(_ scalars: [UnicodeScalar]) {
        self.scalars = scalars
    }

    static func rejectDuplicateObjectMembers(in data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw RoomProfessionalSyncContractError.invalidJSON
        }
        var scanner = Self(Array(text.unicodeScalars))
        try scanner.parseValue(path: "$")
        scanner.skipWhitespace()
        guard scanner.index == scanner.scalars.count else {
            throw RoomProfessionalSyncContractError.invalidJSON
        }
    }

    private mutating func parseValue(path: String) throws {
        skipWhitespace()
        guard index < scalars.count else { throw RoomProfessionalSyncContractError.invalidJSON }
        switch scalars[index].value {
        case 0x7B: try parseObject(path: path) // {
        case 0x5B: try parseArray(path: path) // [
        case 0x22: _ = try parseString()
        case 0x74: try consumeLiteral("true")
        case 0x66: try consumeLiteral("false")
        case 0x6E: try consumeLiteral("null")
        case 0x2D, 0x30...0x39: try parseNumber()
        default: throw RoomProfessionalSyncContractError.invalidJSON
        }
    }

    private mutating func parseObject(path: String) throws {
        index += 1
        skipWhitespace()
        var keys = Set<String>()
        if consume(0x7D) { return } // }
        while true {
            skipWhitespace()
            guard index < scalars.count, scalars[index].value == 0x22 else {
                throw RoomProfessionalSyncContractError.invalidJSON
            }
            let key = try parseString()
            guard keys.insert(key).inserted else {
                throw RoomProfessionalSyncContractError.duplicateKey(path: path, key: key)
            }
            skipWhitespace()
            guard consume(0x3A) else { throw RoomProfessionalSyncContractError.invalidJSON } // :
            try parseValue(path: path)
            skipWhitespace()
            if consume(0x7D) { return }
            guard consume(0x2C) else { throw RoomProfessionalSyncContractError.invalidJSON } // ,
        }
    }

    private mutating func parseArray(path: String) throws {
        index += 1
        skipWhitespace()
        if consume(0x5D) { return } // ]
        while true {
            try parseValue(path: path)
            skipWhitespace()
            if consume(0x5D) { return }
            guard consume(0x2C) else { throw RoomProfessionalSyncContractError.invalidJSON }
        }
    }

    private mutating func parseString() throws -> String {
        guard consume(0x22) else { throw RoomProfessionalSyncContractError.invalidJSON }
        var value = String.UnicodeScalarView()
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            switch scalar.value {
            case 0x22:
                return String(value)
            case 0x5C:
                guard index < scalars.count else { throw RoomProfessionalSyncContractError.invalidJSON }
                let escaped = scalars[index]
                index += 1
                switch escaped.value {
                case 0x22, 0x5C, 0x2F: value.append(escaped)
                case 0x62: value.append("\u{0008}")
                case 0x66: value.append("\u{000C}")
                case 0x6E: value.append("\n")
                case 0x72: value.append("\r")
                case 0x74: value.append("\t")
                case 0x75:
                    let first = try parseHexQuad()
                    if (0xD800...0xDBFF).contains(first) {
                        guard consume(0x5C), consume(0x75) else {
                            throw RoomProfessionalSyncContractError.invalidJSON
                        }
                        let second = try parseHexQuad()
                        guard (0xDC00...0xDFFF).contains(second) else {
                            throw RoomProfessionalSyncContractError.invalidJSON
                        }
                        guard let decoded = UnicodeScalar(0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)) else {
                            throw RoomProfessionalSyncContractError.invalidJSON
                        }
                        value.append(decoded)
                    } else {
                        guard !(0xDC00...0xDFFF).contains(first), let decoded = UnicodeScalar(first) else {
                            throw RoomProfessionalSyncContractError.invalidJSON
                        }
                        value.append(decoded)
                    }
                default:
                    throw RoomProfessionalSyncContractError.invalidJSON
                }
            case 0x00...0x1F:
                throw RoomProfessionalSyncContractError.invalidJSON
            default:
                value.append(scalar)
            }
        }
        throw RoomProfessionalSyncContractError.invalidJSON
    }

    private mutating func parseNumber() throws {
        if consume(0x2D) { // -
            guard index < scalars.count else { throw RoomProfessionalSyncContractError.invalidJSON }
        }
        if consume(0x30) {
            // zero cannot be followed by another integer digit
            guard index >= scalars.count || !(0x30...0x39).contains(scalars[index].value) else {
                throw RoomProfessionalSyncContractError.invalidJSON
            }
        } else {
            guard index < scalars.count, (0x31...0x39).contains(scalars[index].value) else {
                throw RoomProfessionalSyncContractError.invalidJSON
            }
            index += 1
            while index < scalars.count, (0x30...0x39).contains(scalars[index].value) { index += 1 }
        }
        if consume(0x2E) { // .
            try consumeDigits()
        }
        if index < scalars.count, scalars[index].value == 0x65 || scalars[index].value == 0x45 {
            index += 1
            _ = consume(0x2B) || consume(0x2D)
            try consumeDigits()
        }
    }

    private mutating func consumeDigits() throws {
        guard index < scalars.count, (0x30...0x39).contains(scalars[index].value) else {
            throw RoomProfessionalSyncContractError.invalidJSON
        }
        repeat { index += 1 } while index < scalars.count && (0x30...0x39).contains(scalars[index].value)
    }

    private mutating func consumeLiteral(_ literal: String) throws {
        let literalScalars = Array(literal.unicodeScalars)
        guard index + literalScalars.count <= scalars.count,
              zip(scalars[index..<(index + literalScalars.count)], literalScalars).allSatisfy({ $0 == $1 })
        else {
            throw RoomProfessionalSyncContractError.invalidJSON
        }
        index += literalScalars.count
    }

    @discardableResult
    private mutating func consume(_ scalar: UInt32) -> Bool {
        guard index < scalars.count, scalars[index].value == scalar else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < scalars.count,
              [0x20, 0x09, 0x0A, 0x0D].contains(scalars[index].value) {
            index += 1
        }
    }

    private mutating func parseHexQuad() throws -> UInt32 {
        guard index + 4 <= scalars.count else { throw RoomProfessionalSyncContractError.invalidJSON }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let digit: UInt32
            switch scalars[index].value {
            case 0x30...0x39: digit = scalars[index].value - 0x30
            case 0x41...0x46: digit = scalars[index].value - 0x41 + 10
            case 0x61...0x66: digit = scalars[index].value - 0x61 + 10
            default: throw RoomProfessionalSyncContractError.invalidJSON
            }
            value = (value << 4) | digit
            index += 1
        }
        return value
    }
}
