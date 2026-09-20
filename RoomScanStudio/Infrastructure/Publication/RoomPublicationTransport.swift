import Foundation
import RoomScanCore

/// Deliberately narrow hosted boundary for a Slice 6 publication archive. The
/// app cannot hand this transport a project package URL, revision payload,
/// feedback mutation capability, cookie, CSRF value, bearer link, or arbitrary
/// JSON document.
@MainActor
protocol RoomPublicationTransport: AnyObject {
    func allocatePublication(
        _ request: RoomPublicationAllocationRequest
    ) async throws -> RoomPublicationUploadAllocation

    func uploadPublicationArchive(
        _ archive: RoomPublicationArchiveUpload,
        allocation: RoomPublicationUploadAllocation
    ) async throws

    func completePublication(
        allocationID: String,
        archiveSHA256: String,
        archiveManifestSHA256: String,
        archiveByteCount: UInt64
    ) async throws -> RoomPublicationCompletionStatus

    /// A separate recovery/read route. `pua_` remains the only identifier
    /// until validation returns a published status with an optional `snp_`.
    func allocationStatus(
        allocationID: String
    ) async throws -> RoomPublicationRemoteAllocationStatus

    /// Curation is a distinct professional route. It accepts only freshly
    /// assigned public room keys and hosted `prj_` identities, never a local
    /// property ID, child snapshot ID, coordinate transform, or package path.
    func upsertPropertyCuration(
        _ request: RoomPublicationPropertyCurationRequest
    ) async throws -> RoomPublicationPropertyCurationStatus

    /// Link policy is a distinct authority from immutable snapshot allocation.
    /// The configured server derives/stores the PIN verifier; this protocol
    /// never receives feedback or project mutation capability.
    func createPortalLink(
        snapshotID: String,
        request: RoomPublicationPortalLinkRequest
    ) async throws -> RoomPublicationPortalLinkStatus

    /// Owner-authorized aggregate/status read. It returns no feedback body,
    /// email, token, link bearer, or share URL; native uses it to reconcile a
    /// durable link phase after a process interruption.
    func portalLinkStatus(
        linkID: String,
        snapshotID: String
    ) async throws -> RoomPublicationPortalLinkStatus?

    func revokePortalLink(
        linkID: String,
        expectedGeneration: Int
    ) async throws -> RoomPublicationPortalLinkRevocation
}

enum RoomPublicationTransportError: LocalizedError, Equatable {
    case unavailable
    case invalidResponse
    case insecureURL
    case forbiddenSignedRequestAuthorization

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Publication is not configured in this build. Local rooms and private exports remain available."
        case .invalidResponse:
            "The publication service returned an invalid response."
        case .insecureURL:
            "Publication requires a configured HTTPS service endpoint."
        case .forbiddenSignedRequestAuthorization:
            "Signed publication uploads cannot carry account authorization."
        }
    }
}

enum RoomPublicationTransportLimits {
    static let maximumArchiveBytes: UInt64 = 768 * 1_024 * 1_024
    static let maximumAIReadyPackageBytes: UInt64 = 512 * 1_024 * 1_024
    static let maximumOrdinaryAssetBytes: UInt64 = 32 * 1_024 * 1_024
    static let maximumPresentationOrGeometryBytes: UInt64 = 8 * 1_024 * 1_024
    /// Publication delivery is range-bounded by the hosted portal. Native
    /// archive upload stays file-streamed and does not buffer a 768 MiB archive.
    static let maximumProtectedChunkBytes: UInt64 = 4 * 1_024 * 1_024
}

/// Exact typed data accepted by the frozen `publication.snapshot.allocate`
/// route. No client flag/quota version, authoritative time, object key/version,
/// provider URL, or derived authorization fact can be represented here.
struct RoomPublicationAllocationRequest: Sendable, Equatable {
    let publicationKind: RoomPublishedSnapshotKind
    let projectID: String
    let sourceRevisionID: String
    let sourceRevisionDigest: String
    let sourceManifestDigest: String
    let sourceBindings: [RoomPublicationHostedSourceBinding]
    let sourceBindingsSHA256: String
    let selectionManifestSHA256: String
    let approvalSHA256: String
    let propertyID: String?
    let archiveManifestSHA256: String
    let archiveSHA256: String
    let archiveByteCount: UInt64
    let idempotencyKey: String

    init(
        publicationKind: RoomPublishedSnapshotKind,
        projectID: String,
        sourceRevisionID: String,
        sourceRevisionDigest: String,
        sourceManifestDigest: String,
        sourceBindings: [RoomPublicationHostedSourceBinding],
        sourceBindingsSHA256: String,
        selectionManifestSHA256: String,
        approvalSHA256: String,
        propertyID: String?,
        archiveManifestSHA256: String,
        archiveSHA256: String,
        archiveByteCount: UInt64,
        idempotencyKey: String
    ) {
        self.publicationKind = publicationKind
        self.projectID = projectID
        self.sourceRevisionID = sourceRevisionID
        self.sourceRevisionDigest = sourceRevisionDigest
        self.sourceManifestDigest = sourceManifestDigest
        self.sourceBindings = sourceBindings
        self.sourceBindingsSHA256 = sourceBindingsSHA256
        self.selectionManifestSHA256 = selectionManifestSHA256
        self.approvalSHA256 = approvalSHA256
        self.propertyID = propertyID
        self.archiveManifestSHA256 = archiveManifestSHA256
        self.archiveSHA256 = archiveSHA256
        self.archiveByteCount = archiveByteCount
        self.idempotencyKey = idempotencyKey
    }

    func validate() throws {
        guard RoomPublicationPublicIdentifier.project(projectID),
              RoomPublicationPublicIdentifier.revision(sourceRevisionID),
              RoomPublicationPublicIdentifier.sha256(sourceRevisionDigest),
              RoomPublicationPublicIdentifier.sha256(sourceManifestDigest),
              RoomPublicationPublicIdentifier.sha256(sourceBindingsSHA256),
              RoomPublicationPublicIdentifier.sha256(selectionManifestSHA256),
              RoomPublicationPublicIdentifier.sha256(approvalSHA256),
              RoomPublicationPublicIdentifier.sha256(archiveManifestSHA256),
              RoomPublicationPublicIdentifier.sha256(archiveSHA256),
              RoomPublicationPublicIdentifier.opaque(idempotencyKey),
              archiveByteCount > 0,
              archiveByteCount <= RoomPublicationTransportLimits.maximumArchiveBytes
        else { throw RoomPublicationTransportError.invalidResponse }
        for binding in sourceBindings { try binding.validate() }
        guard sourceBindings.first?.projectPublicID == projectID,
              sourceBindings.first?.revisionPublicID == sourceRevisionID
        else { throw RoomPublicationTransportError.invalidResponse }
        switch publicationKind {
        case .room:
            guard sourceBindings.count == 1, propertyID == nil else {
                throw RoomPublicationTransportError.invalidResponse
            }
        case .property:
            guard (2...64).contains(sourceBindings.count),
                  propertyID.map(RoomPublicationPublicIdentifier.property) == true
            else { throw RoomPublicationTransportError.invalidResponse }
        }
        let keys = Set(sourceBindings.map(\.publicRoomKey))
        let projects = Set(sourceBindings.map(\.projectPublicID))
        guard keys.count == sourceBindings.count,
              projects.count == sourceBindings.count
        else { throw RoomPublicationTransportError.invalidResponse }
    }
}

/// The archive remains in an app-owned, marker-owned temporary export lease.
/// This narrow object never carries a private project/package path or source
/// binding contents to the signed object-store request.
struct RoomPublicationArchiveUpload: Sendable, Equatable {
    let archiveURL: URL
    let archiveSHA256: String
    let archiveManifestSHA256: String
    let byteCount: UInt64
}

/// The signed upload grant is intentionally transient. `uploadURL` and its
/// query credential are fileprivate and live only in the transport's in-memory
/// map; no review model, journal, archive, feedback object, or status DTO can
/// access them.
struct RoomPublicationUploadAllocation: Sendable, Equatable {
    let allocationID: String
    let allocationExpiresAt: Date
    fileprivate let uploadURL: URL
    fileprivate let uploadHeaders: [String: String]
}

#if DEBUG
extension RoomPublicationUploadAllocation {
    /// Deterministic native UI/unit fixture construction. Production callers
    /// can only receive this transient grant from the strict allocator.
    static func fixture(
        allocationID: String,
        allocationExpiresAt: Date,
        uploadURL: URL,
        uploadHeaders: [String: String]
    ) -> Self {
        .init(
            allocationID: allocationID,
            allocationExpiresAt: allocationExpiresAt,
            uploadURL: uploadURL,
            uploadHeaders: uploadHeaders
        )
    }
}
#endif

enum RoomPublicationCompletionDisposition: String, Sendable, Equatable {
    case validationPending = "validation_pending"
    case existing
}

struct RoomPublicationCompletionStatus: Sendable, Equatable {
    let allocationID: String
    let disposition: RoomPublicationCompletionDisposition
}

enum RoomPublicationRemoteAllocationState: String, Codable, Sendable, Equatable {
    case allocated
    case validationPending = "validation_pending"
    case validating
    case published
    case rejected
}

/// Privacy-minimized allocation status for native review/recovery. A snapshot
/// ID is exposed only after `published`; all pre-publication states retain only
/// the `pua_` allocation identity.
struct RoomPublicationRemoteAllocationStatus: Sendable, Equatable {
    let allocationID: String
    let state: RoomPublicationRemoteAllocationState
    let kind: RoomPublishedSnapshotKind
    let projectID: String
    let sourceRevisionID: String
    let propertyID: String?
    let snapshotID: String?
    let rejectionCode: String?
    let createdAt: Date
    let updatedAt: Date
    let expiresAt: Date
}

struct RoomPublicationPropertyCurationRequest: Sendable, Equatable {
    let existingPropertyID: String?
    let expectedVersion: Int?
    /// Stable only for this operation-sidecar property mutation. It contains
    /// no local property ID/title and lets a post-response crash recover the
    /// exact server mapping without issuing a duplicate property create.
    let createIdempotencyKey: String
    let title: String
    let rooms: [RoomPublicationPropertyRoom]

    func validate() throws {
        guard (existingPropertyID == nil) == (expectedVersion == nil),
              existingPropertyID.map(RoomPublicationPublicIdentifier.property) ?? true,
              expectedVersion.map({ $0 > 0 }) ?? true,
              RoomPublicationPublicIdentifier.opaque(createIdempotencyKey),
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= 180,
              rooms.count <= 64
        else { throw RoomPublicationTransportError.invalidResponse }
        guard Set(rooms.map(\.publicRoomKey)).count == rooms.count,
              Set(rooms.map(\.projectPublicID)).count == rooms.count,
              rooms.enumerated().allSatisfy({ $0.element.roomOrder == $0.offset + 1 })
        else { throw RoomPublicationTransportError.invalidResponse }
        for room in rooms { try room.validate() }
    }
}

struct RoomPublicationPropertyRoom: Sendable, Equatable {
    let publicRoomKey: String
    let roomOrder: Int
    let projectPublicID: String

    func validate() throws {
        guard ProfessionalProjectSyncJournalRecord.isSafeIdentifier(publicRoomKey),
              roomOrder > 0 && roomOrder <= 64,
              RoomPublicationPublicIdentifier.project(projectPublicID)
        else { throw RoomPublicationTransportError.invalidResponse }
    }
}

struct RoomPublicationPropertyCurationStatus: Sendable, Equatable {
    let propertyID: String
    let version: Int
}

/// Privacy-minimized feedback status. Native receives only summary values;
/// it has no accountless feedback mutation operation.
struct RoomPublicationFeedbackSummary: Sendable, Equatable {
    let recordCount: Int
    /// The server may cap an aggregate count rather than revealing an
    /// unbounded activity total. Native displays this only as summary status.
    let isCapped: Bool
    let latestActionLabel: String?
    let latestRecordedAt: Date?

    init(
        recordCount: Int,
        isCapped: Bool = false,
        latestActionLabel: String?,
        latestRecordedAt: Date?
    ) {
        self.recordCount = recordCount
        self.isCapped = isCapped
        self.latestActionLabel = latestActionLabel
        self.latestRecordedAt = latestRecordedAt
    }

    static let empty = RoomPublicationFeedbackSummary(
        recordCount: 0,
        isCapped: false,
        latestActionLabel: nil,
        latestRecordedAt: nil
    )
}

enum RoomPublicationPortalLinkLifecycle: String, Codable, Sendable, Equatable {
    case active
    case revoked
}

enum RoomPublicationLinkPolicy: String, Codable, Sendable, Equatable {
    case enabled
    case disabled
}

/// The one-time six-digit PIN candidate stays in memory only through the TLS
/// JSON request. It is not serialized in a journal or snapshot archive.
struct RoomPublicationPortalLinkRequest: Sendable, Equatable {
    let idempotencyKey: String
    /// `nil` deliberately omits expiry so the server applies the authoritative
    /// 30-day default under its controlled clock.
    let expiresAt: Date?
    let pinCandidate: String?
    let aiPolicy: RoomPublicationLinkPolicy
    let feedbackPolicy: RoomPublicationLinkPolicy
}

struct RoomPublicationPortalLinkStatus: Sendable, Equatable {
    let linkID: String
    let generation: Int
    let lifecycle: RoomPublicationPortalLinkLifecycle
    let expiresAt: Date
    let pinRequired: Bool
    let aiEnabled: Bool
    let feedbackEnabled: Bool
    let feedbackSummary: RoomPublicationFeedbackSummary

    init(
        linkID: String,
        generation: Int,
        lifecycle: RoomPublicationPortalLinkLifecycle,
        expiresAt: Date,
        pinRequired: Bool,
        aiEnabled: Bool = false,
        feedbackEnabled: Bool = false,
        feedbackSummary: RoomPublicationFeedbackSummary
    ) {
        self.linkID = linkID
        self.generation = generation
        self.lifecycle = lifecycle
        self.expiresAt = expiresAt
        self.pinRequired = pinRequired
        self.aiEnabled = aiEnabled
        self.feedbackEnabled = feedbackEnabled
        self.feedbackSummary = feedbackSummary
    }
}

struct RoomPublicationPortalLinkRevocation: Sendable, Equatable {
    let linkID: String
    let generation: Int
    let disposition: String
}

@MainActor
final class UnavailableRoomPublicationTransport: RoomPublicationTransport {
    func allocatePublication(_ request: RoomPublicationAllocationRequest) async throws -> RoomPublicationUploadAllocation {
        _ = request
        throw RoomPublicationTransportError.unavailable
    }

    func uploadPublicationArchive(_ archive: RoomPublicationArchiveUpload, allocation: RoomPublicationUploadAllocation) async throws {
        _ = archive
        _ = allocation
        throw RoomPublicationTransportError.unavailable
    }

    func completePublication(allocationID: String, archiveSHA256: String, archiveManifestSHA256: String, archiveByteCount: UInt64) async throws -> RoomPublicationCompletionStatus {
        _ = allocationID
        _ = archiveSHA256
        _ = archiveManifestSHA256
        _ = archiveByteCount
        throw RoomPublicationTransportError.unavailable
    }

    func allocationStatus(allocationID: String) async throws -> RoomPublicationRemoteAllocationStatus {
        _ = allocationID
        throw RoomPublicationTransportError.unavailable
    }

    func upsertPropertyCuration(_ request: RoomPublicationPropertyCurationRequest) async throws -> RoomPublicationPropertyCurationStatus {
        _ = request
        throw RoomPublicationTransportError.unavailable
    }

    func createPortalLink(snapshotID: String, request: RoomPublicationPortalLinkRequest) async throws -> RoomPublicationPortalLinkStatus {
        _ = snapshotID
        _ = request
        throw RoomPublicationTransportError.unavailable
    }

    func portalLinkStatus(linkID: String, snapshotID: String) async throws -> RoomPublicationPortalLinkStatus? {
        _ = linkID
        _ = snapshotID
        throw RoomPublicationTransportError.unavailable
    }

    func revokePortalLink(linkID: String, expectedGeneration: Int) async throws -> RoomPublicationPortalLinkRevocation {
        _ = linkID
        _ = expectedGeneration
        throw RoomPublicationTransportError.unavailable
    }
}

// MARK: - Configured professional HTTPS transport

/// A tiny injected executor lets tests exercise the real request/response
/// shapes without a socket. Production receives only the existing audited
/// professional HTTP and file-transfer capabilities after explicit entry.
@MainActor
protocol RoomPublicationHTTPSExecuting: AnyObject {
    func execute(_ request: RoomPublicationHTTPSRequest) async throws -> RoomPublicationHTTPSResponse
    func uploadFile(
        at fileURL: URL,
        to url: URL,
        method: String,
        headers: [String: String]
    ) async throws -> RoomPublicationHTTPSResponse
}

struct RoomPublicationHTTPSRequest: Sendable, Equatable {
    let url: URL
    let method: String
    let headers: [String: String]
    let body: Data?
}

struct RoomPublicationHTTPSResponse: Sendable, Equatable {
    let statusCode: Int
    let data: Data
}

/// Publication adapter over the sole audited professional network boundary.
/// It never obtains URLSession, cookies, cache state, or a logging facility.
/// The shared file-transfer implementation strips signed query credentials
/// before reporting an attempt to its injected observer.
@MainActor
final class FoundationRoomPublicationHTTPSExecutor: RoomPublicationHTTPSExecuting {
    private let http: any ProfessionalHTTPTransport
    private let fileTransfer: any ProfessionalFileStreamingTransport

    init(
        http: any ProfessionalHTTPTransport,
        fileTransfer: any ProfessionalFileStreamingTransport
    ) {
        self.http = http
        self.fileTransfer = fileTransfer
    }

    func execute(_ request: RoomPublicationHTTPSRequest) async throws -> RoomPublicationHTTPSResponse {
        try requireHTTPS(request.url)
        guard !request.headers.keys.contains(where: {
            $0.caseInsensitiveCompare("Cookie") == .orderedSame
                || $0.caseInsensitiveCompare("X-RoomScan-CSRF") == .orderedSame
        }) else { throw RoomPublicationTransportError.invalidResponse }
        let result = try await http.send(.init(
            url: request.url,
            method: request.method,
            headers: request.headers,
            body: request.body
        ))
        return .init(statusCode: result.statusCode, data: result.data)
    }

    func uploadFile(
        at fileURL: URL,
        to url: URL,
        method: String,
        headers: [String: String]
    ) async throws -> RoomPublicationHTTPSResponse {
        try requireHTTPS(url)
        guard !headers.keys.contains(where: {
            $0.caseInsensitiveCompare("Authorization") == .orderedSame
                || $0.caseInsensitiveCompare("Cookie") == .orderedSame
                || $0.caseInsensitiveCompare("X-RoomScan-CSRF") == .orderedSame
        }) else { throw RoomPublicationTransportError.forbiddenSignedRequestAuthorization }
        let response = try await fileTransfer.uploadFile(
            at: fileURL,
            to: url,
            method: method,
            headers: headers
        )
        return .init(statusCode: response.statusCode, data: Data())
    }

    private func requireHTTPS(_ url: URL) throws {
        guard FoundationRoomPublicationTransport.isSecureHTTPSURL(url) else {
            throw RoomPublicationTransportError.insecureURL
        }
    }
}

/// Trusted composition supplies this value without opening a connection during
/// guest launch. The authorization closure is evaluated only for a signed-in
/// professional action and must return an app bearer, never a cookie or CSRF.
struct RoomPublicationHTTPSConfiguration: Sendable {
    let baseURL: URL
    let authorization: @Sendable () -> String
    let http: any ProfessionalHTTPTransport
    let fileTransfer: any ProfessionalFileStreamingTransport

    init(
        baseURL: URL,
        authorization: @escaping @Sendable () -> String,
        http: any ProfessionalHTTPTransport,
        fileTransfer: any ProfessionalFileStreamingTransport
    ) {
        self.baseURL = baseURL
        self.authorization = authorization
        self.http = http
        self.fileTransfer = fileTransfer
    }

    @MainActor
    func makeTransport() throws -> FoundationRoomPublicationTransport {
        try FoundationRoomPublicationTransport(
            baseURL: baseURL,
            authorization: authorization,
            executor: FoundationRoomPublicationHTTPSExecutor(
                http: http,
                fileTransfer: fileTransfer
            )
        )
    }
}

/// Strict native client for the frozen Slice 6 `pua_` allocation and link
/// routes. It keeps signed upload URL/query/header material only in-memory.
@MainActor
final class FoundationRoomPublicationTransport: RoomPublicationTransport {
    private let baseURL: URL
    private let authorization: @Sendable () -> String
    private let executor: any RoomPublicationHTTPSExecuting
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let now: @Sendable () -> Date
    private var uploads: [String: PendingUpload] = [:]

    init(
        baseURL: URL,
        authorization: @escaping @Sendable () -> String,
        executor: any RoomPublicationHTTPSExecuting,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard Self.isSecureHTTPSURL(baseURL), baseURL.query == nil, baseURL.fragment == nil else {
            throw RoomPublicationTransportError.insecureURL
        }
        self.baseURL = baseURL
        self.authorization = authorization
        self.executor = executor
        self.now = now
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
    }

    func allocatePublication(
        _ request: RoomPublicationAllocationRequest
    ) async throws -> RoomPublicationUploadAllocation {
        try request.validate()
        let response = try await json(
            path: "/publications/snapshots/allocate",
            body: AllocateSnapshotRequest(request),
            response: AllocateSnapshotResponse.self,
            allowedKeys: AllocateSnapshotResponse.allowedKeys
        )
        let allocation = try response.model(now: now())
        // Quarantine uploads use a storage grant, not an application route.
        // Keeping it on a distinct origin prevents a signed query secret from
        // accidentally reaching the first-party app observer/route stack.
        guard allocation.uploadURL.host != baseURL.host else {
            throw RoomPublicationTransportError.invalidResponse
        }
        guard uploads[allocation.allocationID] == nil else {
            throw RoomPublicationTransportError.invalidResponse
        }
        uploads[allocation.allocationID] = .init(
            uploadURL: allocation.uploadURL,
            uploadHeaders: allocation.uploadHeaders,
            archiveSHA256: request.archiveSHA256,
            archiveManifestSHA256: request.archiveManifestSHA256,
            archiveByteCount: request.archiveByteCount,
            uploaded: false
        )
        return allocation
    }

    func uploadPublicationArchive(
        _ archive: RoomPublicationArchiveUpload,
        allocation: RoomPublicationUploadAllocation
    ) async throws {
        guard var pending = uploads[allocation.allocationID],
              !pending.uploaded,
              archive.archiveSHA256 == pending.archiveSHA256,
              archive.archiveManifestSHA256 == pending.archiveManifestSHA256,
              archive.byteCount == pending.archiveByteCount,
              archive.byteCount > 0,
              archive.byteCount <= RoomPublicationTransportLimits.maximumArchiveBytes,
              RoomPublicationPublicIdentifier.sha256(archive.archiveSHA256),
              RoomPublicationPublicIdentifier.sha256(archive.archiveManifestSHA256),
              Self.isSecureHTTPSURL(pending.uploadURL)
        else { throw RoomPublicationTransportError.invalidResponse }
        let response = try await executor.uploadFile(
            at: archive.archiveURL,
            to: pending.uploadURL,
            method: "PUT",
            headers: pending.uploadHeaders
        )
        guard (200..<300).contains(response.statusCode) else {
            throw RoomPublicationTransportError.invalidResponse
        }
        pending.uploaded = true
        uploads[allocation.allocationID] = pending
    }

    func completePublication(
        allocationID: String,
        archiveSHA256: String,
        archiveManifestSHA256: String,
        archiveByteCount: UInt64
    ) async throws -> RoomPublicationCompletionStatus {
        guard let pending = uploads[allocationID],
              pending.uploaded,
              pending.archiveSHA256 == archiveSHA256,
              pending.archiveManifestSHA256 == archiveManifestSHA256,
              pending.archiveByteCount == archiveByteCount,
              RoomPublicationPublicIdentifier.allocation(allocationID),
              RoomPublicationPublicIdentifier.sha256(archiveSHA256),
              RoomPublicationPublicIdentifier.sha256(archiveManifestSHA256),
              archiveByteCount > 0
        else { throw RoomPublicationTransportError.invalidResponse }
        let result = try await json(
            path: "/publications/snapshots/complete",
            body: CompleteSnapshotRequest(
                allocationID: allocationID,
                archiveSHA256: archiveSHA256,
                archiveManifestSHA256: archiveManifestSHA256,
                archiveByteCount: archiveByteCount
            ),
            response: CompleteSnapshotResponse.self,
            allowedKeys: CompleteSnapshotResponse.allowedKeys
        )
        guard result.allocationID == allocationID,
              let disposition = RoomPublicationCompletionDisposition(rawValue: result.status)
        else { throw RoomPublicationTransportError.invalidResponse }
        // A confirmed complete response cannot use the presigned grant again.
        uploads.removeValue(forKey: allocationID)
        return .init(allocationID: allocationID, disposition: disposition)
    }

    func allocationStatus(
        allocationID: String
    ) async throws -> RoomPublicationRemoteAllocationStatus {
        guard RoomPublicationPublicIdentifier.allocation(allocationID) else {
            throw RoomPublicationTransportError.invalidResponse
        }
        let response = try await json(
            path: "/publications/snapshots/status",
            body: AllocationStatusRequest(allocationID: allocationID),
            response: AllocationStatusResponse.self,
            allowedKeys: AllocationStatusResponse.allAllowedKeys
        )
        let model = try response.model()
        guard model.allocationID == allocationID else {
            throw RoomPublicationTransportError.invalidResponse
        }
        return model
    }

    func upsertPropertyCuration(
        _ request: RoomPublicationPropertyCurationRequest
    ) async throws -> RoomPublicationPropertyCurationStatus {
        try request.validate()
        let response = try await json(
            path: "/professional/properties/upsert",
            body: UpsertPropertyRequest(request),
            response: UpsertPropertyResponse.self,
            allowedKeys: UpsertPropertyResponse.allowedKeys
        )
        guard response.status == "created" || response.status == "updated",
              RoomPublicationPublicIdentifier.property(response.propertyID),
              response.version > 0,
              response.roomCount == request.rooms.count
        else { throw RoomPublicationTransportError.invalidResponse }
        return .init(propertyID: response.propertyID, version: response.version)
    }

    func createPortalLink(
        snapshotID: String,
        request: RoomPublicationPortalLinkRequest
    ) async throws -> RoomPublicationPortalLinkStatus {
        guard RoomPublicationPublicIdentifier.snapshot(snapshotID),
              RoomPublicationPublicIdentifier.opaque(request.idempotencyKey),
              request.pinCandidate.map(Self.isExactlySixASCIIDigits) ?? true,
              request.expiresAt.map({ $0 > now() }) ?? true
        else { throw RoomPublicationTransportError.invalidResponse }
        // PIN is encoded only in this TLS first-party request. The strict app
        // response has no shareURL field; browser cookie management is separate.
        let response = try await json(
            path: "/publications/links/create",
            body: CreateLinkRequest(snapshotID: snapshotID, request: request),
            response: CreateLinkResponse.self,
            allowedKeys: CreateLinkResponse.allowedKeys
        )
        return try response.model()
    }

    func portalLinkStatus(
        linkID: String,
        snapshotID: String
    ) async throws -> RoomPublicationPortalLinkStatus? {
        guard RoomPublicationPublicIdentifier.link(linkID),
              RoomPublicationPublicIdentifier.snapshot(snapshotID)
        else { throw RoomPublicationTransportError.invalidResponse }
        let response = try await json(
            path: "/publications/links/list",
            body: ListLinksRequest(snapshotID: snapshotID, limit: 20),
            response: ListLinksResponse.self,
            allowedKeys: ListLinksResponse.allowedKeys
        )
        let entries = try response.models()
        let matching = entries.filter { $0.linkID == linkID }
        guard matching.count <= 1 else { throw RoomPublicationTransportError.invalidResponse }
        return matching.first
    }

    func revokePortalLink(
        linkID: String,
        expectedGeneration: Int
    ) async throws -> RoomPublicationPortalLinkRevocation {
        guard RoomPublicationPublicIdentifier.link(linkID), expectedGeneration > 0 else {
            throw RoomPublicationTransportError.invalidResponse
        }
        let response = try await json(
            path: "/publications/links/revoke",
            body: RevokeLinkRequest(linkID: linkID, expectedGeneration: expectedGeneration),
            response: RevokeLinkResponse.self,
            allowedKeys: RevokeLinkResponse.allowedKeys
        )
        guard response.linkID == linkID,
              (response.status == "revoked" && response.generation == expectedGeneration + 1)
                || (response.status == "already_revoked" && response.generation == expectedGeneration)
        else { throw RoomPublicationTransportError.invalidResponse }
        return .init(linkID: linkID, generation: response.generation, disposition: response.status)
    }

    private func json<Request: Encodable, Response: Decodable>(
        path: String,
        body: Request,
        response: Response.Type,
        allowedKeys: Set<String>
    ) async throws -> Response {
        let endpoint = try endpoint(for: path)
        let bearer = authorization()
        guard Self.isNativeAppBearer(bearer) else {
            throw RoomPublicationTransportError.unavailable
        }
        let result: RoomPublicationHTTPSResponse
        do {
            result = try await executor.execute(.init(
                url: endpoint,
                method: "POST",
                headers: [
                    "Authorization": bearer,
                    "Content-Type": "application/json",
                    "Accept": "application/json",
                ],
                body: try encoder.encode(body)
            ))
        } catch {
            // Raw bearer/PIN/URL details are deliberately not surfaced.
            throw RoomPublicationTransportError.unavailable
        }
        guard (200..<300).contains(result.statusCode) else {
            throw RoomPublicationTransportError.invalidResponse
        }
        return try decode(response, from: result.data, allowedKeys: allowedKeys)
    }

    private func endpoint(for path: String) throws -> URL {
        guard path.hasPrefix("/"),
              !path.contains("?"), !path.contains("#"), !path.contains(".."),
              let endpoint = URL(string: String(path.dropFirst()), relativeTo: baseURL)?.absoluteURL,
              endpoint.scheme == baseURL.scheme,
              endpoint.host == baseURL.host,
              endpoint.port == baseURL.port,
              Self.isSecureHTTPSURL(endpoint)
        else { throw RoomPublicationTransportError.insecureURL }
        return endpoint
    }

    private func decode<Response: Decodable>(
        _ type: Response.Type,
        from data: Data,
        allowedKeys: Set<String>
    ) throws -> Response {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys).isSubset(of: allowedKeys)
        else { throw RoomPublicationTransportError.invalidResponse }
        do { return try decoder.decode(Response.self, from: data) }
        catch { throw RoomPublicationTransportError.invalidResponse }
    }

    private static func isNativeAppBearer(_ value: String) -> Bool {
        guard value.hasPrefix("Bearer "), value.count <= 1_024 else { return false }
        let secret = String(value.dropFirst("Bearer ".count))
        return secret.count >= 32
            && !secret.contains(where: { $0.isWhitespace || $0 == ";" || $0 == "=" })
            && !value.contains("\r") && !value.contains("\n")
    }

    nonisolated static func isSecureHTTPSURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host != nil
            && url.user == nil
            && url.password == nil
    }

    private static func isExactlySixASCIIDigits(_ value: String) -> Bool {
        value.count == 6 && value.allSatisfy { ("0"..."9").contains($0) }
    }

    private struct PendingUpload {
        let uploadURL: URL
        let uploadHeaders: [String: String]
        let archiveSHA256: String
        let archiveManifestSHA256: String
        let archiveByteCount: UInt64
        var uploaded: Bool
    }
}

/// Configured composition creates a real native app-bearer transport only after
/// explicit entry/sign-in/unlock. A journal-backed resolver is supplied by the
/// professional environment and doubles as the bounded pending-store seam.
extension RoomPublicationService {
    static func configuredBuilder(
        transportConfiguration: RoomPublicationHTTPSConfiguration,
        workspaceFactory: RoomExportWorkspaceFactory
    ) -> ProfessionalPublicationServiceBuilder {
        { access, identityResolver in
            RoomPublicationService(
                transport: try transportConfiguration.makeTransport(),
                workspaceFactory: workspaceFactory,
                identityResolver: identityResolver,
                operationJournal: try PublicationOperationJournal(
                    rootURL: access.publicationOperationJournalRoot
                )
            )
        }
    }
}

// MARK: - Closed route DTOs

private struct AllocateSnapshotRequest: Encodable {
    let publicationKind: String
    let projectID: String
    let sourceRevisionID: String
    let sourceRevisionDigest: String
    let sourceManifestDigest: String
    private let sourceBindings: [SourceBinding]
    let sourceBindingsSHA256: String
    let selectionManifestSHA256: String
    let approvalSHA256: String
    let disclosureStatus = "approved"
    let propertyID: String?
    let archiveManifestSHA256: String
    let archiveSHA256: String
    let archiveByteCount: UInt64
    let idempotencyKey: String

    init(_ request: RoomPublicationAllocationRequest) {
        publicationKind = request.publicationKind.rawValue
        projectID = request.projectID
        sourceRevisionID = request.sourceRevisionID
        sourceRevisionDigest = request.sourceRevisionDigest
        sourceManifestDigest = request.sourceManifestDigest
        sourceBindings = request.sourceBindings.map(SourceBinding.init)
        sourceBindingsSHA256 = request.sourceBindingsSHA256
        selectionManifestSHA256 = request.selectionManifestSHA256
        approvalSHA256 = request.approvalSHA256
        propertyID = request.propertyID
        archiveManifestSHA256 = request.archiveManifestSHA256
        archiveSHA256 = request.archiveSHA256
        archiveByteCount = request.archiveByteCount
        idempotencyKey = request.idempotencyKey
    }

    private struct SourceBinding: Encodable {
        let publicRoomKey: String
        let projectPublicID: String
        let revisionPublicID: String
        let projectID: String
        let revisionID: String
        let coordinateSpaceEpochID: String
        let packageSchemaVersion: String
        let semanticSHA256: String
        let revisionManifestSHA256: String

        init(_ binding: RoomPublicationHostedSourceBinding) {
            publicRoomKey = binding.publicRoomKey
            projectPublicID = binding.projectPublicID
            revisionPublicID = binding.revisionPublicID
            projectID = binding.sourceRevision.projectID
            revisionID = binding.sourceRevision.revisionID
            coordinateSpaceEpochID = binding.sourceRevision.coordinateSpaceEpochID
            packageSchemaVersion = binding.sourceRevision.packageSchemaVersion
            semanticSHA256 = binding.sourceRevision.semanticSHA256
            revisionManifestSHA256 = binding.sourceRevision.revisionManifestSHA256
        }
    }
}

private struct AllocateSnapshotResponse: Decodable {
    static let allowedKeys: Set<String> = ["status", "allocationID", "allocationExpiresAt", "upload"]
    let status: String
    let allocationID: String
    let allocationExpiresAt: String
    let upload: Upload

    struct Upload: Decodable {
        let url: URL
        let headers: [String: String]
    }

    func model(now: Date) throws -> RoomPublicationUploadAllocation {
        guard status == "allocated" || status == "existing",
              RoomPublicationPublicIdentifier.allocation(allocationID),
              let expires = RoomPublicationTimestamp.parse(allocationExpiresAt),
              expires > now,
              FoundationRoomPublicationTransport.isSecureHTTPSURL(upload.url),
              upload.headers.allSatisfy(RoomPublicationPublicIdentifier.safeHeader),
              !upload.headers.keys.contains(where: {
                  $0.caseInsensitiveCompare("Authorization") == .orderedSame
                      || $0.caseInsensitiveCompare("Cookie") == .orderedSame
                      || $0.caseInsensitiveCompare("X-RoomScan-CSRF") == .orderedSame
              })
        else { throw RoomPublicationTransportError.invalidResponse }
        return .init(
            allocationID: allocationID,
            allocationExpiresAt: expires,
            uploadURL: upload.url,
            uploadHeaders: upload.headers
        )
    }
}

private struct CompleteSnapshotRequest: Encodable {
    let allocationID: String
    let archiveSHA256: String
    let archiveManifestSHA256: String
    let archiveByteCount: UInt64
}

private struct CompleteSnapshotResponse: Decodable {
    static let allowedKeys: Set<String> = ["status", "allocationID"]
    let status: String
    let allocationID: String
}

private struct AllocationStatusRequest: Encodable { let allocationID: String }

private struct UpsertPropertyRequest: Encodable {
    let propertyID: String?
    let expectedVersion: Int?
    let createIdempotencyKey: String
    let title: String
    private let rooms: [Room]

    init(_ request: RoomPublicationPropertyCurationRequest) {
        propertyID = request.existingPropertyID
        expectedVersion = request.expectedVersion
        createIdempotencyKey = request.createIdempotencyKey
        title = request.title
        rooms = request.rooms.map {
            .init(roomKey: $0.publicRoomKey, roomOrder: $0.roomOrder, projectID: $0.projectPublicID)
        }
    }

    private struct Room: Encodable {
        let roomKey: String
        let roomOrder: Int
        let projectID: String
    }
}

private struct UpsertPropertyResponse: Decodable {
    static let allowedKeys: Set<String> = ["status", "propertyID", "version", "roomCount"]
    let status: String
    let propertyID: String
    let version: Int
    let roomCount: Int
}

private struct AllocationStatusResponse: Decodable {
    static let allAllowedKeys: Set<String> = [
        "allocationID", "status", "kind", "projectID", "sourceRevisionID",
        "propertyID", "snapshotID", "rejectionCode", "createdAt", "updatedAt", "expiresAt",
    ]
    let allocationID: String
    let status: String
    let kind: String
    let projectID: String
    let sourceRevisionID: String
    let propertyID: String?
    let snapshotID: String?
    let rejectionCode: String?
    let createdAt: String
    let updatedAt: String
    let expiresAt: String

    func model() throws -> RoomPublicationRemoteAllocationStatus {
        guard let state = RoomPublicationRemoteAllocationState(rawValue: status),
              let kind = RoomPublishedSnapshotKind(rawValue: kind),
              RoomPublicationPublicIdentifier.allocation(allocationID),
              RoomPublicationPublicIdentifier.project(projectID),
              RoomPublicationPublicIdentifier.revision(sourceRevisionID),
              propertyID.map(RoomPublicationPublicIdentifier.property) ?? true,
              snapshotID.map(RoomPublicationPublicIdentifier.snapshot) ?? true,
              rejectionCode.map(RoomPublicationPublicIdentifier.rejectionCode) ?? true,
              let created = RoomPublicationTimestamp.parse(createdAt),
              let updated = RoomPublicationTimestamp.parse(updatedAt),
              let expires = RoomPublicationTimestamp.parse(expiresAt),
              created <= updated
        else { throw RoomPublicationTransportError.invalidResponse }
        switch state {
        case .published:
            guard snapshotID != nil, rejectionCode == nil else { throw RoomPublicationTransportError.invalidResponse }
        case .rejected:
            guard snapshotID == nil else { throw RoomPublicationTransportError.invalidResponse }
        case .allocated, .validationPending, .validating:
            guard snapshotID == nil, rejectionCode == nil else { throw RoomPublicationTransportError.invalidResponse }
        }
        switch kind {
        case .room:
            guard propertyID == nil else { throw RoomPublicationTransportError.invalidResponse }
        case .property:
            guard propertyID != nil else { throw RoomPublicationTransportError.invalidResponse }
        }
        return .init(
            allocationID: allocationID,
            state: state,
            kind: kind,
            projectID: projectID,
            sourceRevisionID: sourceRevisionID,
            propertyID: propertyID,
            snapshotID: snapshotID,
            rejectionCode: rejectionCode,
            createdAt: created,
            updatedAt: updated,
            expiresAt: expires
        )
    }
}

private struct CreateLinkRequest: Encodable {
    let snapshotID: String
    let expiresAt: String?
    let pin: String?
    let aiPolicy: String
    let feedbackPolicy: String
    let idempotencyKey: String

    init(snapshotID: String, request: RoomPublicationPortalLinkRequest) {
        self.snapshotID = snapshotID
        expiresAt = request.expiresAt.map(RoomPublicationTimestamp.encode)
        pin = request.pinCandidate
        aiPolicy = request.aiPolicy.rawValue
        feedbackPolicy = request.feedbackPolicy.rawValue
        idempotencyKey = request.idempotencyKey
    }
}

private struct CreateLinkResponse: Decodable {
    /// `shareURL` is intentionally absent. The browser cookie branch is the
    /// only service path that may receive it, and an extra canary key fails in
    /// the generic strict decoder before this model sees the payload.
    static let allowedKeys: Set<String> = ["status", "linkID", "generation", "expiresAt", "pinRequired"]
    let status: String
    let linkID: String
    let generation: Int
    let expiresAt: String
    let pinRequired: Bool

    func model() throws -> RoomPublicationPortalLinkStatus {
        guard status == "created" || status == "existing",
              RoomPublicationPublicIdentifier.link(linkID),
              generation > 0,
              let expiry = RoomPublicationTimestamp.parse(expiresAt)
        else { throw RoomPublicationTransportError.invalidResponse }
        return .init(
            linkID: linkID,
            generation: generation,
            lifecycle: .active,
            expiresAt: expiry,
            pinRequired: pinRequired,
            feedbackSummary: .empty
        )
    }
}

private struct ListLinksRequest: Encodable {
    let snapshotID: String
    let limit: Int
}

/// The service returns aggregate-only link state. Custom decoding rejects
/// unknown nested keys too, so a feedback comment/email/body canary cannot be
/// silently ignored by synthesized `Decodable` behavior.
private struct ListLinksResponse: Decodable {
    static let allowedKeys: Set<String> = ["items"]
    let items: [Item]

    init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: RoomPublicationDynamicCodingKey.self)
        guard Set(raw.allKeys.map(\.stringValue)).isSubset(of: Self.allowedKeys) else {
            throw RoomPublicationTransportError.invalidResponse
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([Item].self, forKey: .items)
    }

    func models() throws -> [RoomPublicationPortalLinkStatus] {
        let models = try items.map { try $0.model() }
        guard Set(models.map(\.linkID)).count == models.count else {
            throw RoomPublicationTransportError.invalidResponse
        }
        return models
    }

    private enum CodingKeys: String, CodingKey { case items }

    struct Item: Decodable {
        static let allowedKeys: Set<String> = [
            "linkID", "snapshotID", "generation", "state", "expiresAt",
            "pinRequired", "aiEnabled", "feedbackEnabled", "feedbackCount",
            "feedbackCountCapped", "latestFeedbackAction", "latestFeedbackAt",
        ]

        let linkID: String
        let snapshotID: String
        let generation: Int
        let state: String
        let expiresAt: String
        let pinRequired: Bool
        let aiEnabled: Bool
        let feedbackEnabled: Bool
        let feedbackCount: Int
        let feedbackCountCapped: Bool
        let latestFeedbackAction: String?
        let latestFeedbackAt: String?

        init(from decoder: Decoder) throws {
            let raw = try decoder.container(keyedBy: RoomPublicationDynamicCodingKey.self)
            guard Set(raw.allKeys.map(\.stringValue)).isSubset(of: Self.allowedKeys) else {
                throw RoomPublicationTransportError.invalidResponse
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            linkID = try container.decode(String.self, forKey: .linkID)
            snapshotID = try container.decode(String.self, forKey: .snapshotID)
            generation = try container.decode(Int.self, forKey: .generation)
            state = try container.decode(String.self, forKey: .state)
            expiresAt = try container.decode(String.self, forKey: .expiresAt)
            pinRequired = try container.decode(Bool.self, forKey: .pinRequired)
            aiEnabled = try container.decode(Bool.self, forKey: .aiEnabled)
            feedbackEnabled = try container.decode(Bool.self, forKey: .feedbackEnabled)
            feedbackCount = try container.decode(Int.self, forKey: .feedbackCount)
            feedbackCountCapped = try container.decode(Bool.self, forKey: .feedbackCountCapped)
            latestFeedbackAction = try container.decodeIfPresent(String.self, forKey: .latestFeedbackAction)
            latestFeedbackAt = try container.decodeIfPresent(String.self, forKey: .latestFeedbackAt)
        }

        func model() throws -> RoomPublicationPortalLinkStatus {
            guard RoomPublicationPublicIdentifier.link(linkID),
                  RoomPublicationPublicIdentifier.snapshot(snapshotID),
                  generation > 0,
                  let lifecycle = RoomPublicationPortalLinkLifecycle(rawValue: state),
                  let expiry = RoomPublicationTimestamp.parse(expiresAt),
                  feedbackCount >= 0,
                  (latestFeedbackAction == nil) == (latestFeedbackAt == nil)
            else { throw RoomPublicationTransportError.invalidResponse }
            let latest: (label: String, at: Date)?
            switch latestFeedbackAction {
            case nil:
                latest = nil
            case "comment":
                latest = ("Comment", try RoomPublicationTimestamp.require(latestFeedbackAt))
            case "approve":
                latest = ("Approve", try RoomPublicationTimestamp.require(latestFeedbackAt))
            case "request_changes":
                latest = ("Request changes", try RoomPublicationTimestamp.require(latestFeedbackAt))
            default:
                throw RoomPublicationTransportError.invalidResponse
            }
            return .init(
                linkID: linkID,
                generation: generation,
                lifecycle: lifecycle,
                expiresAt: expiry,
                pinRequired: pinRequired,
                aiEnabled: aiEnabled,
                feedbackEnabled: feedbackEnabled,
                feedbackSummary: .init(
                    recordCount: feedbackCount,
                    isCapped: feedbackCountCapped,
                    latestActionLabel: latest?.label,
                    latestRecordedAt: latest?.at
                )
            )
        }

        private enum CodingKeys: String, CodingKey {
            case linkID, snapshotID, generation, state, expiresAt, pinRequired
            case aiEnabled, feedbackEnabled, feedbackCount, feedbackCountCapped
            case latestFeedbackAction, latestFeedbackAt
        }
    }
}

private struct RoomPublicationDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private struct RevokeLinkRequest: Encodable {
    let linkID: String
    let expectedGeneration: Int
}

private struct RevokeLinkResponse: Decodable {
    static let allowedKeys: Set<String> = ["status", "linkID", "generation"]
    let status: String
    let linkID: String
    let generation: Int
}

private enum RoomPublicationPublicIdentifier {
    static func project(_ value: String) -> Bool { match(value, prefix: "prj_") }
    static func revision(_ value: String) -> Bool { match(value, prefix: "rev_") }
    static func property(_ value: String) -> Bool { match(value, prefix: "prop_") }
    static func allocation(_ value: String) -> Bool { match(value, prefix: "pua_") }
    static func snapshot(_ value: String) -> Bool { match(value, prefix: "snp_") }
    static func link(_ value: String) -> Bool { match(value, prefix: "lnk_") }
    static func sha256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
    static func opaque(_ value: String) -> Bool {
        (16...128).contains(value.count)
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
    }
    static func rejectionCode(_ value: String) -> Bool {
        (1...64).contains(value.count)
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
    static func safeHeader(_ pair: (key: String, value: String)) -> Bool {
        !pair.key.isEmpty && pair.key.count <= 96 && pair.value.count <= 8_192
            && !pair.key.contains("\r") && !pair.key.contains("\n")
            && !pair.value.contains("\r") && !pair.value.contains("\n")
    }
    private static func match(_ value: String, prefix: String) -> Bool {
        guard value.hasPrefix(prefix), (prefix.count + 16...prefix.count + 128).contains(value.count) else { return false }
        return value.dropFirst(prefix.count).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

private enum RoomPublicationTimestamp {
    static func encode(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func parse(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let ordinary = ISO8601DateFormatter()
        ordinary.formatOptions = [.withInternetDateTime]
        return ordinary.date(from: value)
    }

    static func require(_ value: String?) throws -> Date {
        guard let value, let date = parse(value) else {
            throw RoomPublicationTransportError.invalidResponse
        }
        return date
    }
}
