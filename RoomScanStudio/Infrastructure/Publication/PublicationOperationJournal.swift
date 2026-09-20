import Foundation
import RoomScanCore

/// Durable, publication-only recovery state.  This deliberately has a root,
/// schema, marker, and record type independent of the frozen Slice 5
/// professional-sync journal.  It stores only bounded control facts required
/// to reconcile an immutable hosted operation after an app/process failure;
/// it never stores credentials, PINs, share URLs, archive paths, package
/// bytes, free-form comments, titles, branding, or private local identifiers.
@MainActor
protocol PublicationOperationJournaling: AnyObject {
    func load(operationID: String) throws -> PublicationOperationJournalRecord?
    func operations(for route: PublicationOperationRoute) throws -> [PublicationOperationJournalRecord]
    func replace(_ record: PublicationOperationJournalRecord) throws
}

enum PublicationOperationJournalError: LocalizedError, Equatable {
    case invalidRecord
    case unsafeStorage

    var errorDescription: String? {
        switch self {
        case .invalidRecord:
            "The local publication recovery record is invalid. Private rooms and sync recovery remain available."
        case .unsafeStorage:
            "The local publication recovery location is not safe to use."
        }
    }
}

enum PublicationOperationPhase: String, Codable, Sendable, Equatable {
    case prepared
    case propertyPending = "property_pending"
    case allocated
    case uploadedOrAmbiguous = "uploaded_or_ambiguous"
    case validating
    case published
    case linkPending = "link_pending"
    case linked
    case revocationPending = "revocation_pending"
    case revoked
    case rejected
}

/// An opaque local routing digest is derived from the current room/property
/// selection at runtime.  Persisting the digest, rather than a raw local
/// project/property identifier, lets a subsequent review find its operation
/// without placing private identifiers into the sidecar.
struct PublicationOperationRoute: Codable, Equatable, Sendable {
    let kind: RoomPublishedSnapshotKind
    let routingSHA256: String

    static func make(input: RoomPublicationReviewInput) throws -> Self {
        let material: String
        switch input.draft.kind {
        case .room:
            material = "room-v1|\(input.journalAnchorProjectID)"
        case .property:
            guard let property = input.propertyCuration else {
                throw PublicationOperationJournalError.invalidRecord
            }
            material = "property-v1|\(property.localPropertyID)"
        }
        return .init(
            kind: input.draft.kind,
            routingSHA256: RoomSHA256.hexDigest(of: Data(material.utf8))
        )
    }

    func validate() throws {
        guard PublicationOperationJournalRules.sha256(routingSHA256) else {
            throw PublicationOperationJournalError.invalidRecord
        }
    }
}

/// A public/derived source control fact. Local IDs are intentionally absent;
/// the exact Core source-binding digest remains the proof over those values.
struct PublicationOperationSourceControl: Codable, Equatable, Sendable {
    let publicRoomKey: String
    let projectPublicID: String
    let revisionPublicID: String
    let semanticSHA256: String
    let revisionManifestSHA256: String

    init(_ binding: RoomPublicationHostedSourceBinding) {
        publicRoomKey = binding.publicRoomKey
        projectPublicID = binding.projectPublicID
        revisionPublicID = binding.revisionPublicID
        semanticSHA256 = binding.sourceRevision.semanticSHA256
        revisionManifestSHA256 = binding.sourceRevision.revisionManifestSHA256
    }

    func validate() throws {
        guard PublicationOperationJournalRules.identifier(publicRoomKey),
              PublicationOperationJournalRules.publicID(projectPublicID, prefix: "prj_"),
              PublicationOperationJournalRules.publicID(revisionPublicID, prefix: "rev_"),
              PublicationOperationJournalRules.sha256(semanticSHA256),
              PublicationOperationJournalRules.sha256(revisionManifestSHA256)
        else { throw PublicationOperationJournalError.invalidRecord }
    }
}

/// Property curation has a server-issued public mapping and a client-created,
/// opaque idempotency key. It carries no title, room-local transform, or raw
/// local property identifier.
struct PublicationOperationPropertyState: Codable, Equatable, Sendable {
    let createIdempotencyKey: String
    var propertyID: String?
    var version: Int?

    func validate() throws {
        guard PublicationOperationJournalRules.opaque(createIdempotencyKey),
              (propertyID == nil) == (version == nil),
              propertyID.map({ PublicationOperationJournalRules.publicID($0, prefix: "prop_") }) ?? true,
              version.map({ $0 > 0 }) ?? true
        else { throw PublicationOperationJournalError.invalidRecord }
    }
}

struct PublicationOperationAllocationState: Codable, Equatable, Sendable {
    let allocationID: String
    let allocationExpiresAt: Date

    func validate() throws {
        guard PublicationOperationJournalRules.publicID(allocationID, prefix: "pua_") else {
            throw PublicationOperationJournalError.invalidRecord
        }
    }
}

/// Link intent is persisted before link creation, but the raw PIN is never
/// represented. If a PIN-protected link needs a post-crash retry, the owner
/// re-enters a new ephemeral six-digit candidate.
struct PublicationOperationLinkIntent: Codable, Equatable, Sendable {
    let idempotencyKey: String
    let expiresAt: Date?
    let requiresPIN: Bool
    let aiPolicy: RoomPublicationLinkPolicy
    let feedbackPolicy: RoomPublicationLinkPolicy

    func validate() throws {
        guard PublicationOperationJournalRules.opaque(idempotencyKey) else {
            throw PublicationOperationJournalError.invalidRecord
        }
    }
}

struct PublicationOperationLinkState: Codable, Equatable, Sendable {
    let linkID: String
    let generation: Int
    let lifecycle: RoomPublicationPortalLinkLifecycle
    let expiresAt: Date
    let pinRequired: Bool
    let aiEnabled: Bool
    let feedbackEnabled: Bool
    let feedbackCount: Int
    let feedbackCountCapped: Bool
    let latestFeedbackAction: String?
    let latestFeedbackAt: Date?

    init(_ status: RoomPublicationPortalLinkStatus) {
        linkID = status.linkID
        generation = status.generation
        lifecycle = status.lifecycle
        expiresAt = status.expiresAt
        pinRequired = status.pinRequired
        aiEnabled = status.aiEnabled
        feedbackEnabled = status.feedbackEnabled
        feedbackCount = status.feedbackSummary.recordCount
        feedbackCountCapped = status.feedbackSummary.isCapped
        latestFeedbackAction = status.feedbackSummary.latestActionLabel
        latestFeedbackAt = status.feedbackSummary.latestRecordedAt
    }

    func status() -> RoomPublicationPortalLinkStatus {
        .init(
            linkID: linkID,
            generation: generation,
            lifecycle: lifecycle,
            expiresAt: expiresAt,
            pinRequired: pinRequired,
            aiEnabled: aiEnabled,
            feedbackEnabled: feedbackEnabled,
            feedbackSummary: .init(
                recordCount: feedbackCount,
                isCapped: feedbackCountCapped,
                latestActionLabel: latestFeedbackAction,
                latestRecordedAt: latestFeedbackAt
            )
        )
    }

    func validate() throws {
        guard PublicationOperationJournalRules.publicID(linkID, prefix: "lnk_"),
              generation > 0,
              feedbackCount >= 0,
              latestFeedbackAction.map(PublicationOperationJournalRules.feedbackAction) ?? true
        else { throw PublicationOperationJournalError.invalidRecord }
    }
}

struct PublicationOperationRevocationState: Codable, Equatable, Sendable {
    let linkID: String
    let expectedGeneration: Int

    func validate() throws {
        guard PublicationOperationJournalRules.publicID(linkID, prefix: "lnk_"), expectedGeneration > 0 else {
            throw PublicationOperationJournalError.invalidRecord
        }
    }
}

/// Versioned closed record for every immutable native publication operation.
/// The stored `approval` is a bounded Core control artifact, not a project
/// revision or public presentation. The service rebuilds the Core archive and
/// compares every exact digest before it resumes an allocation or link.
struct PublicationOperationJournalRecord: Codable, Equatable, Sendable {
    static let schemaVersion = "roomscan-publication-operation-v1"

    let schema: String
    let operationID: String
    let route: PublicationOperationRoute
    let sourceControls: [PublicationOperationSourceControl]
    let sourceBindingsSHA256: String
    let selectionManifestSHA256: String
    let approval: RoomPublishedPublicationApproval
    let approvalSHA256: String
    let archiveManifestSHA256: String
    let archiveSHA256: String
    let archiveByteCount: UInt64
    var phase: PublicationOperationPhase
    var property: PublicationOperationPropertyState?
    var allocation: PublicationOperationAllocationState?
    var snapshotID: String?
    var linkIntent: PublicationOperationLinkIntent?
    var link: PublicationOperationLinkState?
    var revocation: PublicationOperationRevocationState?
    var rejectionCode: String?

    static func prepared(
        operationID: String,
        input: RoomPublicationReviewInput,
        preparation: RoomPublishedSnapshotPreparation,
        approval: RoomPublishedPublicationApproval,
        archiveManifestSHA256: String,
        archiveSHA256: String,
        archiveByteCount: UInt64,
        priorProperty: PublicationOperationPropertyState? = nil
    ) throws -> Self {
        let approvalSHA256 = try RoomPublishedSnapshotDigests.approvalSHA256(
            approval,
            expectedSourceBindingsSHA256: preparation.sourceBindingsSHA256,
            expectedSelectionManifestSHA256: preparation.selectionManifestSHA256
        )
        let property: PublicationOperationPropertyState?
        switch input.draft.kind {
        case .room:
            property = nil
        case .property:
            guard input.propertyCuration != nil else { throw PublicationOperationJournalError.invalidRecord }
            property = .init(
                createIdempotencyKey: "property-\(operationID)",
                propertyID: priorProperty?.propertyID,
                version: priorProperty?.version
            )
        }
        let record = Self(
            schema: schemaVersion,
            operationID: operationID,
            route: try .make(input: input),
            sourceControls: input.hostedSourceBindings.map(PublicationOperationSourceControl.init),
            sourceBindingsSHA256: preparation.sourceBindingsSHA256,
            selectionManifestSHA256: preparation.selectionManifestSHA256,
            approval: approval,
            approvalSHA256: approvalSHA256,
            archiveManifestSHA256: archiveManifestSHA256,
            archiveSHA256: archiveSHA256,
            archiveByteCount: archiveByteCount,
            phase: .prepared,
            property: property,
            allocation: nil,
            snapshotID: nil,
            linkIntent: nil,
            link: nil,
            revocation: nil,
            rejectionCode: nil
        )
        try record.validate()
        return record
    }

    func matches(
        input: RoomPublicationReviewInput,
        preparation: RoomPublishedSnapshotPreparation,
        approval: RoomPublishedPublicationApproval,
        archiveManifestSHA256: String,
        archiveSHA256: String,
        archiveByteCount: UInt64
    ) throws -> Bool {
        guard try matchesReviewedIntent(
            input: input,
            preparation: preparation,
            approval: approval
        ) else { return false }
        return self.archiveManifestSHA256 == archiveManifestSHA256
            && self.archiveSHA256 == archiveSHA256
            && self.archiveByteCount == archiveByteCount
    }

    /// Tests the non-archive portion of an operation before Core is asked to
    /// finalize a new ZIP. This lets a stale source, selection, or approval
    /// fail closed without first attempting to finalize the old approval over
    /// changed public facts.
    func matchesReviewedIntent(
        input: RoomPublicationReviewInput,
        preparation: RoomPublishedSnapshotPreparation,
        approval: RoomPublishedPublicationApproval
    ) throws -> Bool {
        try validate()
        let expectedRoute = try PublicationOperationRoute.make(input: input)
        return route == expectedRoute
            && sourceControls == input.hostedSourceBindings.map(PublicationOperationSourceControl.init)
            && sourceBindingsSHA256 == preparation.sourceBindingsSHA256
            && selectionManifestSHA256 == preparation.selectionManifestSHA256
            && self.approval == approval
    }

    mutating func markPropertyPending() throws {
        try advance(to: .propertyPending)
    }

    mutating func markProperty(_ state: PublicationOperationPropertyState) throws {
        try state.validate()
        property = state
        try advance(to: .prepared)
    }

    mutating func markAllocated(_ state: PublicationOperationAllocationState) throws {
        try state.validate()
        allocation = state
        try advance(to: .allocated)
    }

    mutating func markUploadedOrAmbiguous() throws { try advance(to: .uploadedOrAmbiguous) }
    mutating func markValidating() throws { try advance(to: .validating) }

    mutating func markPublished(snapshotID: String) throws {
        guard PublicationOperationJournalRules.publicID(snapshotID, prefix: "snp_") else {
            throw PublicationOperationJournalError.invalidRecord
        }
        self.snapshotID = snapshotID
        try advance(to: .published)
    }

    mutating func markLinkPending(_ intent: PublicationOperationLinkIntent) throws {
        try intent.validate()
        linkIntent = intent
        try advance(to: .linkPending)
    }

    mutating func markLinked(_ status: RoomPublicationPortalLinkStatus) throws {
        let state = PublicationOperationLinkState(status)
        try state.validate()
        link = state
        try advance(to: status.lifecycle == .revoked ? .revoked : .linked)
    }

    mutating func markRevocationPending(_ state: PublicationOperationRevocationState) throws {
        try state.validate()
        revocation = state
        try advance(to: .revocationPending)
    }

    mutating func markRevoked(_ status: RoomPublicationPortalLinkStatus) throws {
        let state = PublicationOperationLinkState(status)
        try state.validate()
        link = state
        try advance(to: .revoked)
    }

    mutating func markRejected(_ code: String?) throws {
        guard code.map(PublicationOperationJournalRules.rejectionCode) ?? true else {
            throw PublicationOperationJournalError.invalidRecord
        }
        rejectionCode = code
        try advance(to: .rejected)
    }

    func validate() throws {
        guard schema == Self.schemaVersion,
              PublicationOperationJournalRules.opaque(operationID),
              (1...64).contains(sourceControls.count),
              Set(sourceControls.map(\.publicRoomKey)).count == sourceControls.count,
              PublicationOperationJournalRules.sha256(sourceBindingsSHA256),
              PublicationOperationJournalRules.sha256(selectionManifestSHA256),
              PublicationOperationJournalRules.sha256(approvalSHA256),
              PublicationOperationJournalRules.sha256(archiveManifestSHA256),
              PublicationOperationJournalRules.sha256(archiveSHA256),
              archiveByteCount > 0,
              archiveByteCount <= RoomPublicationTransportLimits.maximumArchiveBytes,
              rejectionCode.map(PublicationOperationJournalRules.rejectionCode) ?? true
        else { throw PublicationOperationJournalError.invalidRecord }
        try route.validate()
        for source in sourceControls { try source.validate() }
        try approval.validate(
            expectedSourceBindingsSHA256: sourceBindingsSHA256,
            expectedSelectionManifestSHA256: selectionManifestSHA256
        )
        let computedApproval = try RoomPublishedSnapshotDigests.approvalSHA256(
            approval,
            expectedSourceBindingsSHA256: sourceBindingsSHA256,
            expectedSelectionManifestSHA256: selectionManifestSHA256
        )
        guard computedApproval == approvalSHA256 else {
            throw PublicationOperationJournalError.invalidRecord
        }
        switch route.kind {
        case .room:
            guard sourceControls.count == 1, property == nil else {
                throw PublicationOperationJournalError.invalidRecord
            }
        case .property:
            guard sourceControls.count >= 2, property != nil else {
                throw PublicationOperationJournalError.invalidRecord
            }
        }
        try property?.validate()
        try allocation?.validate()
        try linkIntent?.validate()
        try link?.validate()
        try revocation?.validate()
        guard snapshotID.map({ PublicationOperationJournalRules.publicID($0, prefix: "snp_") }) ?? true else {
            throw PublicationOperationJournalError.invalidRecord
        }
        switch phase {
        case .prepared, .propertyPending:
            guard allocation == nil, snapshotID == nil, linkIntent == nil, link == nil, revocation == nil else {
                throw PublicationOperationJournalError.invalidRecord
            }
        case .allocated, .uploadedOrAmbiguous, .validating:
            guard allocation != nil, snapshotID == nil, linkIntent == nil, link == nil, revocation == nil else {
                throw PublicationOperationJournalError.invalidRecord
            }
        case .published:
            guard allocation != nil, snapshotID != nil, link == nil, revocation == nil else {
                throw PublicationOperationJournalError.invalidRecord
            }
        case .linkPending:
            guard allocation != nil, snapshotID != nil, linkIntent != nil, link == nil, revocation == nil else {
                throw PublicationOperationJournalError.invalidRecord
            }
        case .linked:
            guard allocation != nil, snapshotID != nil, linkIntent != nil, link?.lifecycle == .active, revocation == nil else {
                throw PublicationOperationJournalError.invalidRecord
            }
        case .revocationPending:
            guard allocation != nil, snapshotID != nil, linkIntent != nil, link?.lifecycle == .active, revocation != nil else {
                throw PublicationOperationJournalError.invalidRecord
            }
        case .revoked:
            guard allocation != nil, snapshotID != nil, linkIntent != nil, link?.lifecycle == .revoked else {
                throw PublicationOperationJournalError.invalidRecord
            }
        case .rejected:
            guard allocation != nil, snapshotID == nil, linkIntent == nil, link == nil else {
                throw PublicationOperationJournalError.invalidRecord
            }
        }
    }

    private mutating func advance(to next: PublicationOperationPhase) throws {
        guard Self.permits(from: phase, to: next) else {
            throw PublicationOperationJournalError.invalidRecord
        }
        phase = next
        try validate()
    }

    private static func permits(from current: PublicationOperationPhase, to next: PublicationOperationPhase) -> Bool {
        if current == next { return true }
        switch (current, next) {
        case (.prepared, .propertyPending), (.propertyPending, .prepared),
             (.prepared, .allocated), (.allocated, .uploadedOrAmbiguous),
             (.uploadedOrAmbiguous, .validating), (.allocated, .validating),
             (.validating, .published), (.uploadedOrAmbiguous, .published),
             (.allocated, .published), (.published, .linkPending),
             (.linkPending, .linked), (.linked, .revocationPending),
             (.revocationPending, .revoked), (.published, .rejected),
             (.allocated, .rejected), (.uploadedOrAmbiguous, .rejected),
             (.validating, .rejected):
            return true
        default:
            return false
        }
    }
}

/// Marker-owned canonical JSON store. The journal scans only its own
/// `operations` directory and rejects symlinks/noncanonical bytes so an
/// untrusted local file cannot become a recovery instruction.
@MainActor
final class PublicationOperationJournal: PublicationOperationJournaling {
    private static let markerFilename = ".roomscan-publication-operation-ownership.json"
    private static let recordsDirectoryName = "operations"
    private static let schemaVersion = "roomscan-publication-operation-journal-root-v1"
    private static let stagePrefix = ".roomscan-publication-operation-stage-"

    private struct Marker: Codable, Equatable {
        let schemaVersion: String
        let ownershipToken: String
    }

    private let rootURL: URL
    private let fileManager: FileManager
    private let ownershipToken: String
    private let lock = NSLock()

    init(rootURL: URL, fileManager: FileManager = .default) throws {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
        ownershipToken = UUID().uuidString.lowercased()
        try establishOwnedRoot()
    }

    func load(operationID: String) throws -> PublicationOperationJournalRecord? {
        guard PublicationOperationJournalRules.opaque(operationID) else {
            throw PublicationOperationJournalError.invalidRecord
        }
        return try lock.withLock {
            try establishOwnedRoot()
            let url = try recordURL(operationID: operationID)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return try decodeRecord(at: url, expectedOperationID: operationID)
        }
    }

    func operations(for route: PublicationOperationRoute) throws -> [PublicationOperationJournalRecord] {
        try route.validate()
        return try lock.withLock {
            try establishOwnedRoot()
            let directory = recordsDirectoryURL()
            var records: [PublicationOperationJournalRecord] = []
            for entry in try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ) where entry.pathExtension == "json" {
                let record = try decodeRecord(at: entry, expectedOperationID: nil)
                if record.route == route { records.append(record) }
            }
            return records.sorted { $0.operationID < $1.operationID }
        }
    }

    func replace(_ record: PublicationOperationJournalRecord) throws {
        try record.validate()
        try lock.withLock {
            try establishOwnedRoot()
            let destination = try recordURL(operationID: record.operationID)
            if fileManager.fileExists(atPath: destination.path) {
                let prior = try decodeRecord(at: destination, expectedOperationID: record.operationID)
                guard prior.route == record.route,
                      prior.sourceBindingsSHA256 == record.sourceBindingsSHA256,
                      prior.selectionManifestSHA256 == record.selectionManifestSHA256,
                      prior.approvalSHA256 == record.approvalSHA256,
                      prior.archiveManifestSHA256 == record.archiveManifestSHA256,
                      prior.archiveSHA256 == record.archiveSHA256,
                      prior.archiveByteCount == record.archiveByteCount,
                      permitsReplacement(from: prior.phase, to: record.phase)
                else { throw PublicationOperationJournalError.invalidRecord }
            }
            let data = try canonicalData(for: record)
            let directory = recordsDirectoryURL()
            let stage = directory.appendingPathComponent(Self.stagePrefix + UUID().uuidString.lowercased())
            defer { try? removeOwnedStage(stage) }
            try data.write(to: stage, options: [.withoutOverwriting])
            try requireRegularFile(stage)
            guard try Data(contentsOf: stage, options: [.mappedIfSafe]) == data else {
                throw PublicationOperationJournalError.unsafeStorage
            }
            try data.write(to: destination, options: .atomic)
            try requireRegularFile(destination)
            guard try Data(contentsOf: destination, options: [.mappedIfSafe]) == data else {
                throw PublicationOperationJournalError.unsafeStorage
            }
        }
    }

    private func decodeRecord(
        at url: URL,
        expectedOperationID: String?
    ) throws -> PublicationOperationJournalRecord {
        try requireRegularFile(url)
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let record = try JSONDecoder().decode(PublicationOperationJournalRecord.self, from: data)
        try record.validate()
        guard expectedOperationID.map({ $0 == record.operationID }) ?? true,
              try canonicalData(for: record) == data
        else { throw PublicationOperationJournalError.invalidRecord }
        return record
    }

    private func establishOwnedRoot() throws {
        try requireNoSymlinkInExistingAncestors(of: rootURL)
        if fileManager.fileExists(atPath: rootURL.path) {
            try requireDirectory(rootURL)
        } else {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try requireDirectory(rootURL)
        }
        let markerURL = rootURL.appendingPathComponent(Self.markerFilename)
        if fileManager.fileExists(atPath: markerURL.path) {
            try requireRegularFile(markerURL)
            let data = try Data(contentsOf: markerURL, options: [.mappedIfSafe])
            let marker = try JSONDecoder().decode(Marker.self, from: data)
            guard marker.schemaVersion == Self.schemaVersion,
                  marker.ownershipToken.range(of: "^[a-f0-9-]{36}$", options: .regularExpression) != nil,
                  try canonicalData(for: marker) == data
            else { throw PublicationOperationJournalError.unsafeStorage }
        } else {
            let marker = Marker(schemaVersion: Self.schemaVersion, ownershipToken: ownershipToken)
            try canonicalData(for: marker).write(to: markerURL, options: [.withoutOverwriting])
            try requireRegularFile(markerURL)
        }
        let records = recordsDirectoryURL()
        if fileManager.fileExists(atPath: records.path) {
            try requireDirectory(records)
        } else {
            try fileManager.createDirectory(at: records, withIntermediateDirectories: false)
            try requireDirectory(records)
        }
        for entry in try fileManager.contentsOfDirectory(at: records, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            if entry.lastPathComponent.hasPrefix(Self.stagePrefix) {
                try removeOwnedStage(entry)
            } else if entry.pathExtension == "json" {
                _ = try decodeRecord(at: entry, expectedOperationID: nil)
            } else {
                throw PublicationOperationJournalError.unsafeStorage
            }
        }
    }

    private func recordsDirectoryURL() -> URL {
        rootURL.appendingPathComponent(Self.recordsDirectoryName, isDirectory: true)
    }

    private func recordURL(operationID: String) throws -> URL {
        guard PublicationOperationJournalRules.opaque(operationID) else {
            throw PublicationOperationJournalError.invalidRecord
        }
        return recordsDirectoryURL().appendingPathComponent("\(operationID).json")
    }

    private func canonicalData<T: Encodable>(for value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func permitsReplacement(from previous: PublicationOperationPhase, to next: PublicationOperationPhase) -> Bool {
        previous == next || (previous == .prepared && (next == .propertyPending || next == .allocated))
            || (previous == .propertyPending && next == .prepared)
            || (previous == .allocated && ([.uploadedOrAmbiguous, .validating, .published, .rejected].contains(next)))
            || (previous == .uploadedOrAmbiguous && ([.validating, .published, .rejected].contains(next)))
            || (previous == .validating && ([.published, .rejected].contains(next)))
            || (previous == .published && ([.linkPending, .rejected].contains(next)))
            || (previous == .linkPending && next == .linked)
            || (previous == .linked && next == .revocationPending)
            || (previous == .revocationPending && next == .revoked)
    }

    private func removeOwnedStage(_ url: URL) throws {
        guard url.lastPathComponent.hasPrefix(Self.stagePrefix) else {
            throw PublicationOperationJournalError.unsafeStorage
        }
        guard fileManager.fileExists(atPath: url.path) else { return }
        try requireRegularFile(url)
        try fileManager.removeItem(at: url)
    }

    private func requireDirectory(_ url: URL) throws {
        try requireNoSymlinkInExistingAncestors(of: url)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw PublicationOperationJournalError.unsafeStorage
        }
    }

    private func requireRegularFile(_ url: URL) throws {
        try requireNoSymlinkInExistingAncestors(of: url)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw PublicationOperationJournalError.unsafeStorage
        }
    }

    private func requireNoSymlinkInExistingAncestors(of url: URL) throws {
        let standardized = url.standardizedFileURL
        guard standardized.path.hasPrefix("/") else { throw PublicationOperationJournalError.unsafeStorage }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in standardized.pathComponents.dropFirst() {
            current.appendPathComponent(component, isDirectory: false)
            if (try? fileManager.destinationOfSymbolicLink(atPath: current.path)) != nil {
                throw PublicationOperationJournalError.unsafeStorage
            }
            guard fileManager.fileExists(atPath: current.path) else { return }
        }
    }
}

private enum PublicationOperationJournalRules {
    static func sha256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    static func identifier(_ value: String) -> Bool {
        (1...128).contains(value.count)
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
    }

    static func opaque(_ value: String) -> Bool {
        (16...128).contains(value.count)
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func publicID(_ value: String, prefix: String) -> Bool {
        guard value.hasPrefix(prefix), (prefix.count + 16...prefix.count + 128).contains(value.count) else { return false }
        return value.dropFirst(prefix.count).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func rejectionCode(_ value: String) -> Bool {
        (1...64).contains(value.count)
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func feedbackAction(_ value: String) -> Bool {
        value == "Comment" || value == "Approve" || value == "Request changes"
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
