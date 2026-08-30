import Foundation
import RoomScanCore

/// App-visible state deliberately mirrors only public Slice 5 HTTP status.
/// There is no merge or last-writer-wins state in this vocabulary.
enum ProfessionalProjectSyncStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case allocated
    case validationPending
    case validating
    case canonical
    case stale
    case rejected
    case attached
}

enum ProfessionalProjectSyncBranchState: String, Codable, Equatable, Sendable {
    case canonical
    case stale
}

enum ProfessionalProjectSyncRecoveryPhase: String, Codable, Equatable, Sendable {
    case none
    case downloaded
    case inspected
    case prepared
    case packageCommitted
    case companionsCommitted
}

enum ProfessionalProjectSyncPresentationState: Equatable, Sendable {
    case idle
    case localDraft
    case previewReady
    case uploading
    case awaitingValidation
    case canonical
    case conflict(ProfessionalProjectSyncConflict)
    case awaitingUserEdit
    case rejected
    case recoveryReady
}

enum ProfessionalProjectSyncPreviewUploadability: Equatable, Sendable {
    case uploadable
    case exceedsHostedWorkingArchiveLimit(actualByteCount: UInt64, maximumByteCount: UInt64)
}

enum ProfessionalProjectSyncError: Error, Equatable, LocalizedError, Sendable {
    case invalidPublicState
    case unavailable
    case approvalExpired
    case approvalMismatch
    case archiveChanged
    case archiveExceedsHostedLimit
    case invalidResponse
    case insecureURL
    case forbiddenSignedRequestAuthorization
    /// A signed immutable PUT reported an object-store precondition failure.
    /// This is intentionally distinct from a transport failure: the service
    /// may query first-party upload state and, only when that state proves the
    /// object is present, safely complete the allocation.
    case signedUploadPreconditionFailed
    case sourceUnavailable
    case conflictRequired
    case leaseUnavailable
    case invalidRawReview
    case unsafeScratch

    var errorDescription: String? {
        switch self {
        case .invalidPublicState: "Professional synchronization state is invalid."
        case .unavailable: "Professional synchronization is unavailable."
        case .approvalExpired: "This migration preview is no longer current. Preview again before uploading."
        case .approvalMismatch: "The approved migration no longer matches the current local revision."
        case .archiveChanged: "The staged working archive changed before it could be uploaded."
        case .archiveExceedsHostedLimit: "This working archive exceeds the hosted professional synchronization limit."
        case .invalidResponse: "The hosted synchronization response was invalid."
        case .insecureURL: "Professional synchronization requires HTTPS."
        case .forbiddenSignedRequestAuthorization: "Signed object transfers cannot carry an authorization header."
        case .signedUploadPreconditionFailed: "The signed immutable upload was already accepted or changed state."
        case .sourceUnavailable: "The requested local revision is no longer available."
        case .conflictRequired: "Compare, rebase, or duplicate this preserved branch before continuing."
        case .leaseUnavailable: "Another editor currently holds the advisory project lease. Local work remains available."
        case .invalidRawReview: "The raw archive review no longer matches its selected source files."
        case .unsafeScratch: "Professional synchronization scratch storage is unsafe."
        }
    }
}

/// The only durable app-side record for a professional project. It contains
/// public IDs and digests, never credentials, URLs, object identifiers,
/// filesystem paths, room bytes, filenames, or free-form project content.
struct ProfessionalProjectSyncJournalRecord: Codable, Equatable, Sendable {
    static let schemaVersion = "roomscan-professional-project-sync-journal-v1"

    let schemaVersion: String
    let localProjectID: String
    var hostedProjectID: String?
    var acknowledgedLocalHeadRevisionID: String?
    var acknowledgedHostedHeadRevisionID: String?
    var localDraftHeadRevisionID: String?
    var idempotencyDigest: String?
    var status: ProfessionalProjectSyncStatus
    var uploadID: String?
    var candidateRevisionID: String?
    var currentHostedHeadRevisionID: String?
    var canonicalRevisionID: String?
    var staleRevisionID: String?
    var recoveryTransactionID: String?
    var recoveryPhase: ProfessionalProjectSyncRecoveryPhase

    init(
        localProjectID: String,
        hostedProjectID: String? = nil,
        acknowledgedLocalHeadRevisionID: String? = nil,
        acknowledgedHostedHeadRevisionID: String? = nil,
        localDraftHeadRevisionID: String? = nil,
        idempotencyDigest: String? = nil,
        status: ProfessionalProjectSyncStatus = .allocated,
        uploadID: String? = nil,
        candidateRevisionID: String? = nil,
        currentHostedHeadRevisionID: String? = nil,
        canonicalRevisionID: String? = nil,
        staleRevisionID: String? = nil,
        recoveryTransactionID: String? = nil,
        recoveryPhase: ProfessionalProjectSyncRecoveryPhase = .none
    ) {
        schemaVersion = Self.schemaVersion
        self.localProjectID = localProjectID
        self.hostedProjectID = hostedProjectID
        self.acknowledgedLocalHeadRevisionID = acknowledgedLocalHeadRevisionID
        self.acknowledgedHostedHeadRevisionID = acknowledgedHostedHeadRevisionID
        self.localDraftHeadRevisionID = localDraftHeadRevisionID
        self.idempotencyDigest = idempotencyDigest
        self.status = status
        self.uploadID = uploadID
        self.candidateRevisionID = candidateRevisionID
        self.currentHostedHeadRevisionID = currentHostedHeadRevisionID
        self.canonicalRevisionID = canonicalRevisionID
        self.staleRevisionID = staleRevisionID
        self.recoveryTransactionID = recoveryTransactionID
        self.recoveryPhase = recoveryPhase
    }

    func validate() throws {
        guard schemaVersion == Self.schemaVersion,
              Self.isSafeIdentifier(localProjectID),
              hostedProjectID == nil || Self.isHostedProjectID(hostedProjectID!),
              acknowledgedLocalHeadRevisionID == nil || Self.isSafeIdentifier(acknowledgedLocalHeadRevisionID!),
              acknowledgedHostedHeadRevisionID == nil || Self.isHostedRevisionID(acknowledgedHostedHeadRevisionID!),
              localDraftHeadRevisionID == nil || Self.isSafeIdentifier(localDraftHeadRevisionID!),
              uploadID == nil || Self.isHostedUploadID(uploadID!),
              candidateRevisionID == nil || Self.isHostedRevisionID(candidateRevisionID!),
              currentHostedHeadRevisionID == nil || Self.isHostedRevisionID(currentHostedHeadRevisionID!),
              canonicalRevisionID == nil || Self.isHostedRevisionID(canonicalRevisionID!),
              staleRevisionID == nil || Self.isHostedRevisionID(staleRevisionID!),
              recoveryTransactionID == nil || Self.isSafeIdentifier(recoveryTransactionID!),
              idempotencyDigest == nil || Self.isSHA256(idempotencyDigest!)
        else {
            throw ProfessionalProjectSyncError.invalidPublicState
        }
        if status == .stale {
            guard candidateRevisionID != nil, currentHostedHeadRevisionID != nil else {
                throw ProfessionalProjectSyncError.invalidPublicState
            }
        }
    }

    static func isSafeIdentifier(_ value: String) -> Bool {
        value.range(
            of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$",
            options: .regularExpression
        ) != nil
    }

    static func isSHA256(_ value: String) -> Bool {
        value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }

    static func isHostedProjectID(_ value: String) -> Bool {
        value.range(of: "^prj_[A-Za-z0-9_-]{16,128}$", options: .regularExpression) != nil
    }

    static func isHostedRevisionID(_ value: String) -> Bool {
        value.range(of: "^rev_[A-Za-z0-9_-]{16,128}$", options: .regularExpression) != nil
    }

    static func isHostedUploadID(_ value: String) -> Bool {
        value.range(of: "^upl_[A-Za-z0-9_-]{16,128}$", options: .regularExpression) != nil
    }
}

struct ProfessionalProjectSyncRecovery: Equatable, Sendable {
    let projectID: String
    let revisionID: String
    let branchState: ProfessionalProjectSyncBranchState
    let workingSetManifestSHA256: String
    let archiveSHA256: String
    let archiveByteCount: UInt64

    init(
        projectID: String,
        revisionID: String,
        branchState: ProfessionalProjectSyncBranchState,
        workingSetManifestSHA256: String,
        archiveSHA256: String,
        archiveByteCount: UInt64
    ) {
        self.projectID = projectID
        self.revisionID = revisionID
        self.branchState = branchState
        self.workingSetManifestSHA256 = workingSetManifestSHA256
        self.archiveSHA256 = archiveSHA256
        self.archiveByteCount = archiveByteCount
    }

    func validate() throws {
        guard ProfessionalProjectSyncJournalRecord.isHostedProjectID(projectID),
              ProfessionalProjectSyncJournalRecord.isHostedRevisionID(revisionID),
              ProfessionalProjectSyncJournalRecord.isSHA256(workingSetManifestSHA256),
              ProfessionalProjectSyncJournalRecord.isSHA256(archiveSHA256),
              archiveByteCount > 0
        else { throw ProfessionalProjectSyncError.invalidResponse }
    }
}

struct ProfessionalProjectSyncRecoveryDownload: Sendable {
    let recovery: ProfessionalProjectSyncRecovery
    /// This URL is intentionally in-memory only and is never represented by
    /// `ProfessionalProjectSyncJournalRecord`.
    let transientDownloadURL: URL
}

struct ProfessionalProjectSyncUploadAllocation: Sendable {
    let status: ProfessionalProjectSyncStatus
    let projectID: String
    let uploadID: String
    let candidateRevisionID: String?
    let currentHostedHeadRevisionID: String?
    let archiveSHA256: String
    let archiveByteCount: UInt64
    let allocationExpiresAt: Date
    /// Both values are transient, used only by a signed streaming upload.
    let transientUploadURL: URL
    let transientUploadHeaders: [String: String]
}

struct ProfessionalProjectSyncUploadStatus: Sendable, Equatable {
    let status: ProfessionalProjectSyncStatus
    let projectID: String
    let uploadID: String
    let candidateRevisionID: String?
    let currentHostedHeadRevisionID: String?
    let archiveSHA256: String
    let archiveByteCount: UInt64
    let allocationExpiresAt: Date
}

struct ProfessionalProjectSyncMigrationRequest: Codable, Sendable, Equatable {
    let sourceProjectID: String
    let proposedRevisionID: String
    let workingSetManifestSHA256: String
    let archiveSHA256: String
    let archiveByteCount: UInt64
    let idempotencyKey: String
    let quotaPolicyVersion: Int
    let hostedGlobalVersion: Int
    let hostedWorkspaceVersion: Int
}

struct ProfessionalProjectSyncRevisionRequest: Codable, Sendable, Equatable {
    let projectID: String
    let expectedHostedHeadRevisionID: String
    let expectedHeadRevisionID: String
    let proposedRevisionID: String
    let workingSetManifestSHA256: String
    let archiveSHA256: String
    let archiveByteCount: UInt64
    let idempotencyKey: String
    let quotaPolicyVersion: Int
    let hostedGlobalVersion: Int
    let hostedWorkspaceVersion: Int
}

struct ProfessionalProjectSyncRawArchiveRequest: Codable, Sendable, Equatable {
    let projectID: String
    let revisionID: String
    let rawManifestSHA256: String
    let archiveSHA256: String
    let archiveByteCount: UInt64
    let reviewSHA256: String
    let idempotencyKey: String
    let quotaPolicyVersion: Int
    let hostedGlobalVersion: Int
    let hostedWorkspaceVersion: Int
}

struct ProfessionalProjectSyncLeaseRequest: Codable, Sendable, Equatable {
    let projectID: String
    let deviceID: String
    let requestID: String
    let leaseToken: String
    let hostedGlobalVersion: Int
    let hostedWorkspaceVersion: Int
}

struct ProfessionalProjectSyncRawConfigurationRequest: Codable, Sendable, Equatable {
    let projectID: String
    let reviewSHA256: String
    let hostedGlobalVersion: Int
    let hostedWorkspaceVersion: Int
}

struct ProfessionalProjectSyncLeaseTokenRequest: Codable, Sendable, Equatable {
    let projectID: String
    let leaseToken: String
    let hostedGlobalVersion: Int
    let hostedWorkspaceVersion: Int
}

struct ProfessionalProjectSyncConflict: Equatable, Sendable {
    let hostedProjectID: String
    let canonicalRevisionID: String
    let staleRevisionID: String
}

struct ProfessionalProjectSyncLease: Sendable {
    let status: String
    let expiresAt: Date?
    /// A lease token is intentionally process-memory-only.
    let plaintextToken: String?
}

/// Version/device inputs come from the authenticated professional
/// configuration boundary. Views never invent provider policy versions or a
/// device identifier, and the service still validates every hosted response.
struct ProfessionalProjectSyncActionContext: Equatable, Sendable {
    let quotaPolicyVersion: Int
    let hostedGlobalVersion: Int
    let hostedWorkspaceVersion: Int
    let deviceID: String

    init(
        quotaPolicyVersion: Int,
        hostedGlobalVersion: Int,
        hostedWorkspaceVersion: Int,
        deviceID: String
    ) throws {
        guard quotaPolicyVersion > 0,
              hostedGlobalVersion > 0,
              hostedWorkspaceVersion > 0,
              ProfessionalProjectSyncJournalRecord.isSafeIdentifier(deviceID)
        else { throw ProfessionalProjectSyncError.invalidPublicState }
        self.quotaPolicyVersion = quotaPolicyVersion
        self.hostedGlobalVersion = hostedGlobalVersion
        self.hostedWorkspaceVersion = hostedWorkspaceVersion
        self.deviceID = deviceID
    }
}

/// The app-level, raw-free inventory shown to professional users before an
/// upload. These categories are derived from Core's validated outer manifest;
/// UI must never infer them from a static list or filesystem walk.
enum ProfessionalProjectWorkingCategory: String, CaseIterable, Equatable, Sendable {
    case packageBackup
    case redesignCompanion
    case conceptSetManifest
    case conceptSetAttachment
    case conceptSourcePackageProvenance
}

struct ProfessionalProjectWorkingCategorySummary: Equatable, Sendable {
    let category: ProfessionalProjectWorkingCategory
    let itemCount: Int
    let byteCount: UInt64
}

/// Public acknowledgement for the separately enabled raw-object tier. It is
/// intentionally not journaled: only the user-reviewed archive operation
/// keeps it in process memory.
struct ProfessionalProjectSyncRawConfiguration: Sendable, Equatable {
    let projectID: String
    let rawArchiveEnabled: Bool
    let reviewedAt: Date
}

struct ProfessionalProjectSyncPreview: Sendable {
    /// Slice 5 hosted operational ceiling for both default working-set and
    /// explicitly reviewed raw-archive uploads. It does not alter local raw
    /// construction, guest packages, private CloudKit backup, commercial
    /// quota, or retention policy.
    static let maximumHostedWorkingArchiveBytes = RoomProfessionalHostedSyncLimits.maximumArchiveBytes
    let localProjectID: String
    let localRoomDisplayName: String
    let localHeadRevisionID: String
    let sourceRevision: RoomRedesignSourceRevision
    let workingSetManifestSHA256: String
    let archiveSHA256: String
    let archiveByteCount: UInt64
    let workingCategories: [ProfessionalProjectWorkingCategorySummary]
    let rawExcludedClasses: [RoomProfessionalRawAssetClass]
    let conceptMappingAdjustments: [RoomProfessionalConceptMappingAdjustment]
    let approval: ProfessionalProjectSyncApproval
    /// Private marker-owned workspace, retained only in process memory for an
    /// explicit approved upload/retry. It is not journal data.
    let stagedArchiveURL: URL

    var uploadability: ProfessionalProjectSyncPreviewUploadability {
        archiveByteCount <= Self.maximumHostedWorkingArchiveBytes
            ? .uploadable
            : .exceedsHostedWorkingArchiveLimit(
                actualByteCount: archiveByteCount,
                maximumByteCount: Self.maximumHostedWorkingArchiveBytes
            )
    }
}

struct ProfessionalProjectSyncApproval: Equatable, Sendable {
    let localProjectID: String
    let localHeadRevisionID: String
    let archiveSHA256: String
    let archiveByteCount: UInt64
    let issuedAt: Date
}

struct ProfessionalProjectSyncComparison: Equatable, Sendable {
    let canonicalManifestSHA256: String
    let staleManifestSHA256: String
    let canonicalPackageManifestSHA256: String
    let stalePackageManifestSHA256: String
    let canonicalHeadRevisionID: String
    let staleHeadRevisionID: String
    let canonicalSourceSemanticSHA256: String
    let staleSourceSemanticSHA256: String
    let canonicalRevisionCount: Int
    let staleRevisionCount: Int
    let canonicalCompanionPaths: [String]
    let staleCompanionPaths: [String]
    let differs: Bool
}

struct ProfessionalProjectRawReview: Sendable {
    let sourceRevision: RoomRedesignSourceRevision
    let entries: [RoomProfessionalRawArchiveEntry]
    let byteCountByClass: [RoomProfessionalRawAssetClass: UInt64]
    let countByClass: [RoomProfessionalRawAssetClass: Int]
    let selectionSHA256: String
    /// These inputs stay in process memory until the user accepts the review.
    let inputs: [RoomProfessionalRawArchiveInput]
}
