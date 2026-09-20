import CoreGraphics
import Foundation
import ImageIO
import RoomScanCore
import UniformTypeIdentifiers

/// A bounded, local sidecar recovery view. It exposes only the exact approval,
/// current server allocation status, and aggregate link status needed by the
/// native review UI; no credential, PIN, archive location, or share URL can be
/// represented here.
struct RoomPublicationOperationRecovery: Sendable, Equatable {
    let operationID: String
    let approval: RoomPublishedPublicationApproval
    let phase: PublicationOperationPhase
    let remoteStatus: RoomPublicationRemoteAllocationStatus?
    let portalLinkStatus: RoomPublicationPortalLinkStatus?
}

@MainActor
protocol RoomPublicationServicing: AnyObject {
    func prepare(
        _ input: RoomPublicationReviewInput
    ) async throws -> RoomPublishedSnapshotPreparation

    func recoverOperation(
        input: RoomPublicationReviewInput,
        preparation: RoomPublishedSnapshotPreparation
    ) async throws -> RoomPublicationOperationRecovery?

    /// Builds a fresh archive from explicit public-only input, reconciles a
    /// journaled `pua_` before any retry, and returns a server-authoritative
    /// allocation state. `snp_` is present only for `.published`.
    func publishSnapshot(
        input: RoomPublicationReviewInput,
        preparation: RoomPublishedSnapshotPreparation,
        approval: RoomPublishedPublicationApproval,
        operationID: String
    ) async throws -> RoomPublicationRemoteAllocationStatus

    func createPortalLink(
        snapshotID: String,
        linkControls: RoomPublicationLinkControls,
        aiReadyEntitlement: RoomPublicationAIReadyLinkEntitlement?,
        pin: String?,
        operationID: String
    ) async throws -> RoomPublicationPortalLinkStatus

    func allocationStatus(allocationID: String) async throws -> RoomPublicationRemoteAllocationStatus

    func revoke(
        linkID: String,
        expectedGeneration: Int,
        operationID: String
    ) async throws -> RoomPublicationPortalLinkRevocation
}

enum RoomPublicationServiceError: LocalizedError, Equatable {
    case archiveTooLarge
    case invalidPINRequest
    case aiReadyPackageUnavailable
    case invalidSourceBinding
    case pendingPublicationRequiresReconciliation
    case pendingAllocationExpired
    case rejectedAllocation(String?)
    case invalidPublishedAllocation
    case staleOperation

    var errorDescription: String? {
        switch self {
        case .archiveTooLarge:
            "The bounded publication archive exceeded the allowed upload size."
        case .invalidPINRequest:
            "A PIN request must carry only a short-lived numeric PIN candidate."
        case .aiReadyPackageUnavailable:
            "This snapshot does not include a verified AI-ready package, so that link download cannot be enabled."
        case .invalidSourceBinding:
            "The acknowledged professional source no longer matches this local revision. Synchronize and review again before publishing."
        case .pendingPublicationRequiresReconciliation:
            "An earlier publication allocation is still pending. Its hosted status must finish before this changed review can allocate another immutable snapshot."
        case .pendingAllocationExpired:
            "The earlier publication upload grant has expired. Its hosted status must be reconciled before retrying."
        case let .rejectedAllocation(code):
            code.map { "The hosted publication was rejected (\($0)). Local rooms and private recovery remain intact." }
                ?? "The hosted publication was rejected. Local rooms and private recovery remain intact."
        case .invalidPublishedAllocation:
            "The publication service returned an invalid published allocation."
        case .staleOperation:
            "The durable publication operation no longer matches this exact source, selected artifacts, approval, or rebuilt archive. Review and approve again."
        }
    }
}

/// A local-only capability for one already-finalized AI-ready package. It is
/// deliberately neither Codable nor part of a review option, journal, DTO,
/// diagnostic, or SwiftUI view. The archive location is consumed only while
/// Core reconstructs a fresh public allowlist archive.
struct RoomPublicationAIReadyPackageCandidate: Sendable, Equatable {
    let archiveURL: URL
    let sourceRevision: RoomRedesignSourceRevision
    let expectedPackageID: String
}

/// Production composition injects this narrow read-only capability from the
/// existing local AI package provenance seam. It has no project mutation,
/// hosted transport, upload, or feedback authority.
@MainActor
protocol RoomPublicationAIReadyPackageProviding: AnyObject {
    func validatedAIReadyPackage(
        for sourceRevision: RoomRedesignSourceRevision
    ) async -> RoomPublicationAIReadyPackageCandidate?
}

/// The selected AI-ready asset is an internal construction result rather than
/// a user-facing file reference. It can become part of the immutable Core
/// ledger only after a second exact archive/profile/source validation.
struct RoomPublicationAIReadyPackageSelection: Sendable, Equatable {
    let assetID: String
    let asset: RoomPublishedAssetInput
}

/// Stages the accepted Core publication archive inside an app-owned export
/// lease. No private package URL is accepted or exposed here: Core receives
/// only the already constructed empty-allowlist draft, source bindings, and
/// typed bounded assets from `RoomPublicationReviewInput`.
@MainActor
final class RoomPublicationService: RoomPublicationServicing {
    private let transport: any RoomPublicationTransport
    private let workspaceFactory: RoomExportWorkspaceFactory
    private let fileManager: FileManager
    private let identityResolver: any PublicationSourceIdentityResolving
    private let operationJournal: any PublicationOperationJournaling
    private let pollLimit: Int
    private let now: @Sendable () -> Date

    init(
        transport: any RoomPublicationTransport,
        workspaceFactory: RoomExportWorkspaceFactory,
        identityResolver: any PublicationSourceIdentityResolving,
        operationJournal: any PublicationOperationJournaling,
        fileManager: FileManager = .default,
        pollLimit: Int = 3,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.workspaceFactory = workspaceFactory
        self.identityResolver = identityResolver
        self.operationJournal = operationJournal
        self.fileManager = fileManager
        self.pollLimit = max(1, min(pollLimit, 8))
        self.now = now
    }

    func prepare(
        _ input: RoomPublicationReviewInput
    ) async throws -> RoomPublishedSnapshotPreparation {
        try validateHostedBindings(input)
        let preparation = try await RoomPublishedSnapshotBuilder.prepare(
            draft: input.draft,
            sourceBindings: input.sourceBindings,
            assets: input.assets
        )
        guard preparation.sourceBindings == input.sourceBindings else {
            throw RoomPublicationServiceError.invalidSourceBinding
        }
        return preparation
    }

    func publishSnapshot(
        input: RoomPublicationReviewInput,
        preparation: RoomPublishedSnapshotPreparation,
        approval: RoomPublishedPublicationApproval,
        operationID: String
    ) async throws -> RoomPublicationRemoteAllocationStatus {
        try validateHostedBindings(input)
        try await validateAcknowledgedHeads(input.hostedSourceBindings)
        let route = try PublicationOperationRoute.make(input: input)

        if let existing = try operationJournal.load(operationID: operationID) {
            // Resolve stale source/selection/approval before Core finalizes an
            // archive. The journal is a durable exact-intent boundary, not a
            // best-effort cache that may reinterpret an old approval.
            guard try existing.matchesReviewedIntent(
                input: input,
                preparation: preparation,
                approval: approval
            ) else { throw RoomPublicationServiceError.staleOperation }
            let stage = try await buildStage(
                input: input,
                preparation: preparation,
                approval: approval,
                operationID: operationID
            )
            defer { try? workspaceFactory.cleanup(workspaceURL: stage.leaseURL) }
            guard try existing.matches(
                input: input,
                preparation: preparation,
                approval: approval,
                archiveManifestSHA256: stage.archiveManifestSHA256,
                archiveSHA256: stage.archiveSHA256,
                archiveByteCount: stage.archiveByteCount
            ) else { throw RoomPublicationServiceError.staleOperation }
            var record = existing
            return try await resumePublication(
                record: &record,
                input: input,
                stage: stage
            )
        }

        let stage = try await buildStage(
            input: input,
            preparation: preparation,
            approval: approval,
            operationID: operationID
        )
        defer { try? workspaceFactory.cleanup(workspaceURL: stage.leaseURL) }

        let active = try operationJournal.operations(for: route).filter(Self.isAllocationActive)
        guard active.isEmpty else {
            throw RoomPublicationServiceError.pendingPublicationRequiresReconciliation
        }
        // This write is intentionally before property/create/allocate. A lost
        // response can therefore be retried using the same server idempotency
        // keys without a second immutable publication or property mapping.
        let priorProperty = try latestPropertyMapping(for: route)
        var record = try PublicationOperationJournalRecord.prepared(
            operationID: operationID,
            input: input,
            preparation: preparation,
            approval: approval,
            archiveManifestSHA256: stage.archiveManifestSHA256,
            archiveSHA256: stage.archiveSHA256,
            archiveByteCount: stage.archiveByteCount,
            priorProperty: priorProperty
        )
        try operationJournal.replace(record)
        return try await resumePublication(record: &record, input: input, stage: stage)
    }

    func recoverOperation(
        input: RoomPublicationReviewInput,
        preparation: RoomPublishedSnapshotPreparation
    ) async throws -> RoomPublicationOperationRecovery? {
        try validateHostedBindings(input)
        let route = try PublicationOperationRoute.make(input: input)
        let records = try operationJournal.operations(for: route)
        let active = records.filter(Self.isAllocationActive)
        guard active.count <= 1 else { throw RoomPublicationServiceError.pendingPublicationRequiresReconciliation }
        let candidates: [PublicationOperationJournalRecord]
        if let active = active.first {
            candidates = [active]
        } else {
            // Terminal records remain useful for status/feedback/revocation
            // presentation after process restart.  They never block a new
            // review, and each is still rebuilt before it is surfaced.
            candidates = records.sorted { $0.approval.reviewedAt > $1.approval.reviewedAt }
        }
        guard !candidates.isEmpty else { return nil }
        try await validateAcknowledgedHeads(input.hostedSourceBindings)
        for candidate in candidates {
            var record = candidate
            // A published/link-pending snapshot is immutable but does not
            // monopolize a later, newly reviewed selection for the same room
            // or property.  Check the prior approval before Core finalizes it;
            // this avoids presenting a Core validation failure for a stale
            // terminal record and leaves that record available if its exact
            // old review is reopened.
            let approvalMatchesCurrentPreparation: Bool
            do {
                try record.approval.validate(
                    expectedSourceBindingsSHA256: preparation.sourceBindingsSHA256,
                    expectedSelectionManifestSHA256: preparation.selectionManifestSHA256
                )
                approvalMatchesCurrentPreparation = record.sourceBindingsSHA256 == preparation.sourceBindingsSHA256
                    && record.selectionManifestSHA256 == preparation.selectionManifestSHA256
            } catch {
                approvalMatchesCurrentPreparation = false
            }
            guard approvalMatchesCurrentPreparation else {
                if active.contains(where: { $0.operationID == record.operationID }) {
                    throw RoomPublicationServiceError.staleOperation
                }
                continue
            }
            let stage = try await buildStage(
                input: input,
                preparation: preparation,
                approval: record.approval,
                operationID: record.operationID
            )
            defer { try? workspaceFactory.cleanup(workspaceURL: stage.leaseURL) }
            guard try record.matches(
                input: input,
                preparation: preparation,
                approval: record.approval,
                archiveManifestSHA256: stage.archiveManifestSHA256,
                archiveSHA256: stage.archiveSHA256,
                archiveByteCount: stage.archiveByteCount
            ) else {
                if active.contains(where: { $0.operationID == record.operationID }) {
                    throw RoomPublicationServiceError.staleOperation
                }
                continue
            }

            let remote: RoomPublicationRemoteAllocationStatus?
            switch record.phase {
            case .linked, .revoked:
                remote = nil
            default:
                remote = try await reconciledStatus(record: &record, input: input)
            }
            var link = record.link?.status()
            if let snapshotID = record.snapshotID,
               let prior = link,
               let current = try await transport.portalLinkStatus(linkID: prior.linkID, snapshotID: snapshotID) {
                link = current
                if current.lifecycle == .revoked {
                    try record.markRevoked(current)
                } else if record.phase != .revoked {
                    try record.markLinked(current)
                }
                try operationJournal.replace(record)
            }
            return .init(
                operationID: record.operationID,
                approval: record.approval,
                phase: record.phase,
                remoteStatus: remote,
                portalLinkStatus: link
            )
        }
        return nil
    }

    func createPortalLink(
        snapshotID: String,
        linkControls: RoomPublicationLinkControls,
        aiReadyEntitlement: RoomPublicationAIReadyLinkEntitlement?,
        pin: String?,
        operationID: String
    ) async throws -> RoomPublicationPortalLinkStatus {
        guard !linkControls.requiresPIN || Self.isValidPIN(pin) else {
            throw RoomPublicationServiceError.invalidPINRequest
        }
        // This local proof comes only from the exact Core-prepared closure.
        // It is not sent as an authorization claim; the hosted link reducer
        // independently binds AI entitlement to the immutable snapshot asset.
        guard !linkControls.allowsAIReadyPackageDownload || aiReadyEntitlement != nil else {
            throw RoomPublicationServiceError.aiReadyPackageUnavailable
        }
        guard var record = try operationJournal.load(operationID: operationID),
              record.snapshotID == snapshotID
        else { throw RoomPublicationServiceError.staleOperation }
        let intent = PublicationOperationLinkIntent(
            idempotencyKey: "portal-link-\(operationID)",
            expiresAt: linkControls.expiresAt,
            requiresPIN: linkControls.requiresPIN,
            aiPolicy: linkControls.allowsAIReadyPackageDownload ? .enabled : .disabled,
            feedbackPolicy: linkControls.allowsFeedback ? .enabled : .disabled
        )
        if let existing = record.linkIntent {
            guard existing == intent else { throw RoomPublicationServiceError.staleOperation }
        }
        if let link = record.link?.status() {
            guard link.lifecycle == .active else { return link }
            if let refreshed = try await transport.portalLinkStatus(linkID: link.linkID, snapshotID: snapshotID) {
                try record.markLinked(refreshed)
                try operationJournal.replace(record)
                return refreshed
            }
            return link
        }
        switch record.phase {
        case .published:
            try record.markLinkPending(intent)
            try operationJournal.replace(record)
        case .linkPending:
            break
        default:
            throw RoomPublicationServiceError.staleOperation
        }
        let created = try await transport.createPortalLink(
            snapshotID: snapshotID,
            request: .init(
                idempotencyKey: intent.idempotencyKey,
                expiresAt: intent.expiresAt,
                pinCandidate: intent.requiresPIN ? pin : nil,
                aiPolicy: intent.aiPolicy,
                feedbackPolicy: intent.feedbackPolicy
            )
        )
        // A create response intentionally has no feedback body. The separate
        // aggregate route is strict and returns only status/count facts. If it
        // is unavailable after a successful create, retain the link-pending
        // record and retry the same idempotency key rather than inventing data.
        guard let status = try await transport.portalLinkStatus(
            linkID: created.linkID,
            snapshotID: snapshotID
        ) else {
            // A create response is deliberately not a feedback/status source.
            // Keep the durable `linkPending` intent so a restart retries the
            // same idempotency key instead of surfacing fabricated aggregates.
            throw RoomPublicationTransportError.unavailable
        }
        try record.markLinked(status)
        try operationJournal.replace(record)
        return status
    }

    func allocationStatus(allocationID: String) async throws -> RoomPublicationRemoteAllocationStatus {
        try await transport.allocationStatus(allocationID: allocationID)
    }

    func revoke(
        linkID: String,
        expectedGeneration: Int,
        operationID: String
    ) async throws -> RoomPublicationPortalLinkRevocation {
        guard var record = try operationJournal.load(operationID: operationID),
              record.link?.linkID == linkID,
              let snapshotID = record.snapshotID
        else { throw RoomPublicationServiceError.staleOperation }
        if record.phase == .revoked, let link = record.link?.status() {
            return .init(linkID: link.linkID, generation: link.generation, disposition: "already_revoked")
        }
        let intent = PublicationOperationRevocationState(
            linkID: linkID,
            expectedGeneration: expectedGeneration
        )
        if let existing = record.revocation {
            guard existing == intent else { throw RoomPublicationServiceError.staleOperation }
        } else {
            try record.markRevocationPending(intent)
            try operationJournal.replace(record)
        }
        let revocation = try await transport.revokePortalLink(
            linkID: linkID,
            expectedGeneration: expectedGeneration
        )
        guard record.link != nil else { throw RoomPublicationServiceError.staleOperation }
        guard let current = try await transport.portalLinkStatus(
            linkID: linkID,
            snapshotID: snapshotID
        ) else {
            // Retain the durable revocation intent. A later retry uses the
            // server's idempotent already-revoked response and obtains a live
            // aggregate rather than inventing a local status.
            throw RoomPublicationTransportError.unavailable
        }
        try record.markRevoked(current)
        try operationJournal.replace(record)
        return revocation
    }

    private func fileSize(of url: URL) throws -> Int {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size >= 0
        else { throw RoomPublicationServiceError.archiveTooLarge }
        return size
    }

    private static func isValidPIN(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.count == 6 && value.allSatisfy { ("0"..."9").contains($0) }
    }

    private func validateHostedBindings(_ input: RoomPublicationReviewInput) throws {
        guard input.sourceBindings.count == input.hostedSourceBindings.count,
              input.sourceBindings.map(\.publicRoomKey) == input.hostedSourceBindings.map(\.publicRoomKey),
              input.sourceBindings.enumerated().allSatisfy({ index, source in
                  source.sourceRevision == input.hostedSourceBindings[index].sourceRevision
              })
        else { throw RoomPublicationServiceError.invalidSourceBinding }
        for binding in input.hostedSourceBindings { try binding.validate() }
        switch input.draft.kind {
        case .room:
            guard input.propertyCuration == nil, input.hostedSourceBindings.count == 1 else {
                throw RoomPublicationServiceError.invalidSourceBinding
            }
        case .property:
            guard input.propertyCuration != nil, (2...64).contains(input.hostedSourceBindings.count) else {
                throw RoomPublicationServiceError.invalidSourceBinding
            }
        }
    }

    /// Only pre-publication allocation work blocks a new reviewed immutable
    /// snapshot for the same local route.  A published snapshot awaiting a
    /// portal link stays durably recoverable by its exact review, but a later
    /// selection/approval must be allowed to create a distinct snapshot rather
    /// than silently attach a link to stale material.
    private static func isAllocationActive(_ record: PublicationOperationJournalRecord) -> Bool {
        switch record.phase {
        case .prepared, .propertyPending, .allocated, .uploadedOrAmbiguous, .validating:
            true
        case .published, .linkPending, .linked, .revocationPending, .revoked, .rejected:
            false
        }
    }

    private func validateAcknowledgedHeads(
        _ bindings: [RoomPublicationHostedSourceBinding]
    ) async throws {
        for binding in bindings {
            let resolved = try await identityResolver.resolve(
                localProjectID: binding.sourceRevision.projectID,
                expectedSourceRevision: binding.sourceRevision
            )
            guard resolved.projectPublicID == binding.projectPublicID,
                  resolved.revisionPublicID == binding.revisionPublicID,
                  resolved.sourceRevision == binding.sourceRevision
            else { throw RoomPublicationServiceError.invalidSourceBinding }
        }
    }

    /// A property is a mutable professional curation record, but the exact
    /// property ID/version that allocation binds is retained in this separate
    /// operation sidecar.  The frozen Slice 5 source journal stays read-only.
    private func ensurePropertyCuration(
        record: inout PublicationOperationJournalRecord,
        input: RoomPublicationReviewInput
    ) async throws {
        guard let curation = input.propertyCuration else { return }
        guard var property = record.property else {
            throw RoomPublicationServiceError.invalidSourceBinding
        }
        switch record.phase {
        case .prepared:
            try record.markPropertyPending()
            try operationJournal.replace(record)
        case .propertyPending:
            break
        default:
            // Allocation has already bound this exact curation. A retry must
            // not mutate it again before reconciling the existing pua_.
            return
        }
        let result = try await transport.upsertPropertyCuration(.init(
            existingPropertyID: property.propertyID,
            expectedVersion: property.version,
            createIdempotencyKey: property.createIdempotencyKey,
            title: curation.title,
            rooms: curation.rooms
        ))
        property.propertyID = result.propertyID
        property.version = result.version
        try record.markProperty(property)
        try operationJournal.replace(record)
    }

    private func latestPropertyMapping(
        for route: PublicationOperationRoute
    ) throws -> PublicationOperationPropertyState? {
        // Versions are server-owned and monotonic. This selects only an opaque
        // prop_/version mapping; it never reads a local property title or ID
        // from the frozen Slice 5 journal.
        try operationJournal.operations(for: route)
            .compactMap(\.property)
            .filter { $0.propertyID != nil && $0.version != nil }
            .max { ($0.version ?? 0) < ($1.version ?? 0) }
    }

    private func allocationRequest(
        input: RoomPublicationReviewInput,
        stage: PublicationArchiveStage,
        propertyID: String?
    ) throws -> RoomPublicationAllocationRequest {
        let source = input.hostedSourceBindings[0]
        let request = RoomPublicationAllocationRequest(
            publicationKind: stage.kind,
            projectID: source.projectPublicID,
            sourceRevisionID: source.revisionPublicID,
            sourceRevisionDigest: source.sourceRevision.semanticSHA256,
            sourceManifestDigest: source.sourceRevision.revisionManifestSHA256,
            sourceBindings: input.hostedSourceBindings,
            sourceBindingsSHA256: stage.sourceBindingsSHA256,
            selectionManifestSHA256: stage.selectionManifestSHA256,
            approvalSHA256: stage.approvalSHA256,
            propertyID: propertyID,
            archiveManifestSHA256: stage.archiveManifestSHA256,
            archiveSHA256: stage.archiveSHA256,
            archiveByteCount: stage.archiveByteCount,
            idempotencyKey: stage.idempotencyKey
        )
        try request.validate()
        return request
    }

    /// Resume uses the persisted pua_ before it ever asks the allocator for a
    /// fresh signed upload grant. The allocator's idempotency key is retained
    /// in the sidecar, while the secret grant itself is intentionally not.
    private func resumePublication(
        record: inout PublicationOperationJournalRecord,
        input: RoomPublicationReviewInput,
        stage: PublicationArchiveStage
    ) async throws -> RoomPublicationRemoteAllocationStatus {
        try await ensurePropertyCuration(record: &record, input: input)
        let request = try allocationRequest(
            input: input,
            stage: stage,
            propertyID: record.property?.propertyID
        )
        var grant: RoomPublicationUploadAllocation?
        if record.allocation == nil {
            let allocated = try await transport.allocatePublication(request)
            try persistAllocation(allocated, in: &record)
            grant = allocated
        }

        var status = try await reconciledStatus(record: &record, input: input)
        switch status.state {
        case .published, .rejected:
            return status
        case .allocated, .validationPending, .validating:
            break
        }
        guard let allocation = record.allocation else {
            throw RoomPublicationServiceError.invalidPublishedAllocation
        }
        guard allocation.allocationExpiresAt > now() else {
            throw RoomPublicationServiceError.pendingAllocationExpired
        }
        if status.state == .validationPending || status.state == .validating || record.phase == .validating {
            return try await poll(record: &record, input: input)
        }

        // A restarted process has no upload URL by design. Only after a live
        // status confirms this exact pua_ remains allocated do we repeat the
        // same allocator request to obtain a short-lived grant. The server
        // treats it as the same idempotent allocation, never a new snapshot.
        if grant == nil {
            let refreshed = try await transport.allocatePublication(request)
            try verifyAllocationGrant(refreshed, equals: allocation)
            grant = refreshed
        }
        guard let grant else { throw RoomPublicationServiceError.invalidPublishedAllocation }
        if record.phase == .allocated {
            try record.markUploadedOrAmbiguous()
            try operationJournal.replace(record)
        }
        try await transport.uploadPublicationArchive(.init(
            archiveURL: stage.archiveURL,
            archiveSHA256: stage.archiveSHA256,
            archiveManifestSHA256: stage.archiveManifestSHA256,
            byteCount: stage.archiveByteCount
        ), allocation: grant)
        _ = try await transport.completePublication(
            allocationID: allocation.allocationID,
            archiveSHA256: stage.archiveSHA256,
            archiveManifestSHA256: stage.archiveManifestSHA256,
            archiveByteCount: stage.archiveByteCount
        )
        if record.phase == .uploadedOrAmbiguous {
            try record.markValidating()
            try operationJournal.replace(record)
        }
        status = try await poll(record: &record, input: input)
        return status
    }

    private func persistAllocation(
        _ allocation: RoomPublicationUploadAllocation,
        in record: inout PublicationOperationJournalRecord
    ) throws {
        guard record.allocation == nil, allocation.allocationExpiresAt > now() else {
            throw RoomPublicationServiceError.invalidPublishedAllocation
        }
        try record.markAllocated(.init(
            allocationID: allocation.allocationID,
            allocationExpiresAt: allocation.allocationExpiresAt
        ))
        // This is deliberately after the server response and before any
        // upload. A crash here retries the same idempotency key; a crash after
        // it has a durable pua_ to reconcile before it can upload again.
        try operationJournal.replace(record)
    }

    private func verifyAllocationGrant(
        _ grant: RoomPublicationUploadAllocation,
        equals persisted: PublicationOperationAllocationState
    ) throws {
        guard grant.allocationID == persisted.allocationID,
              grant.allocationExpiresAt == persisted.allocationExpiresAt
        else { throw RoomPublicationServiceError.invalidPublishedAllocation }
    }

    private func poll(
        record: inout PublicationOperationJournalRecord,
        input: RoomPublicationReviewInput
    ) async throws -> RoomPublicationRemoteAllocationStatus {
        var last: RoomPublicationRemoteAllocationStatus?
        for _ in 0..<pollLimit {
            let status = try await reconciledStatus(record: &record, input: input)
            last = status
            switch status.state {
            case .published, .rejected:
                return status
            case .allocated, .validationPending, .validating:
                await Task.yield()
            }
        }
        guard let last else { throw RoomPublicationServiceError.invalidPublishedAllocation }
        return last
    }

    private func reconciledStatus(
        record: inout PublicationOperationJournalRecord,
        input: RoomPublicationReviewInput
    ) async throws -> RoomPublicationRemoteAllocationStatus {
        guard let allocation = record.allocation else {
            throw RoomPublicationServiceError.invalidPublishedAllocation
        }
        let status = try await transport.allocationStatus(allocationID: allocation.allocationID)
        try validate(status: status, record: record, input: input)
        switch status.state {
        case .published:
            guard let snapshotID = status.snapshotID else {
                throw RoomPublicationServiceError.invalidPublishedAllocation
            }
            if record.snapshotID == nil {
                try record.markPublished(snapshotID: snapshotID)
                try operationJournal.replace(record)
            } else if record.snapshotID != snapshotID {
                throw RoomPublicationServiceError.invalidPublishedAllocation
            }
        case .rejected:
            if record.phase != .rejected {
                try record.markRejected(status.rejectionCode)
                try operationJournal.replace(record)
            }
        case .validationPending, .validating:
            if record.phase == .allocated || record.phase == .uploadedOrAmbiguous {
                try record.markValidating()
                try operationJournal.replace(record)
            }
        case .allocated:
            break
        }
        return status
    }

    private func validate(
        status: RoomPublicationRemoteAllocationStatus,
        record: PublicationOperationJournalRecord,
        input: RoomPublicationReviewInput
    ) throws {
        guard let allocation = record.allocation,
              status.allocationID == allocation.allocationID,
              status.kind == input.draft.kind,
              status.projectID == input.hostedSourceBindings.first?.projectPublicID,
              status.sourceRevisionID == input.hostedSourceBindings.first?.revisionPublicID,
              status.propertyID == record.property?.propertyID,
              status.expiresAt == allocation.allocationExpiresAt,
              (status.state == .published) == (status.snapshotID != nil),
              status.state != .rejected || status.snapshotID == nil
        else { throw RoomPublicationServiceError.invalidPublishedAllocation }
    }

    private func buildStage(
        input: RoomPublicationReviewInput,
        preparation: RoomPublishedSnapshotPreparation,
        approval: RoomPublishedPublicationApproval,
        operationID: String
    ) async throws -> PublicationArchiveStage {
        let expectedSourceBindingsSHA256 = try RoomPublishedSnapshotDigests.sourceBindingsSHA256(input.sourceBindings)
        guard preparation.draft == input.draft,
              preparation.sourceBindings == input.sourceBindings,
              preparation.sourceBindingsSHA256 == expectedSourceBindingsSHA256
        else { throw RoomPublicationServiceError.invalidSourceBinding }
        let leaseURL = try workspaceFactory.makeLease()
        do {
            let archiveURL = leaseURL.appendingPathComponent("publication-archive.zip")
            // Core requires its assembly workspace to start empty. The final
            // immutable ZIP is a sibling in the same owned lease, so the
            // builder never mistakes its own destination for input material.
            let assemblyURL = leaseURL.appendingPathComponent("assembly", isDirectory: true)
            try fileManager.createDirectory(at: assemblyURL, withIntermediateDirectories: false)
            let ready = try preparation.finalize(approval: approval)
            let archive = try await RoomPublicationArchive.build(
                ready: ready,
                archiveURL: archiveURL,
                workspaceURL: assemblyURL
            )
            let manifestSHA256 = RoomSHA256.hexDigest(of: archive.manifestData)
            return .init(
                kind: input.draft.kind,
                sourceBindingsSHA256: preparation.sourceBindingsSHA256,
                selectionManifestSHA256: preparation.selectionManifestSHA256,
                approvalSHA256: try RoomPublishedSnapshotDigests.approvalSHA256(
                    approval,
                    expectedSourceBindingsSHA256: preparation.sourceBindingsSHA256,
                    expectedSelectionManifestSHA256: preparation.selectionManifestSHA256
                ),
                archiveManifestSHA256: manifestSHA256,
                archiveSHA256: archive.receipt.archiveSHA256,
                archiveByteCount: archive.receipt.archiveByteCount,
                archiveURL: archive.archiveURL,
                leaseURL: leaseURL,
                idempotencyKey: "publication-\(operationID)"
            )
        } catch {
            try? workspaceFactory.cleanup(workspaceURL: leaseURL)
            throw error
        }
    }

    private struct PublicationArchiveStage {
        let kind: RoomPublishedSnapshotKind
        let sourceBindingsSHA256: String
        let selectionManifestSHA256: String
        let approvalSHA256: String
        let archiveManifestSHA256: String
        let archiveSHA256: String
        let archiveByteCount: UInt64
        let archiveURL: URL
        let leaseURL: URL
        let idempotencyKey: String
    }
}

// MARK: - Publication-specific raster sanitizer

enum RoomPublicationImageSanitizationError: Error, Equatable {
    case freshEncodeFailed
    case malformedJPEG
    case unsafeOutput
}

/// Publication is stricter than the shared Concept Set image seam. It first
/// uses that seam for full input validation and a fresh decode, then creates a
/// new baseline JPEG and explicitly removes *every* APP0...APP15 segment
/// before Core's publication-only raster validator sees the candidate.
enum RoomPublicationImageSanitizer {
    static func sanitize(
        _ data: Data,
        declaredFilename: String
    ) throws -> RoomPublishedRaster {
        let shared = try RoomAIImageSanitizer.sanitize(
            data,
            declaredFilename: declaredFilename
        )
        guard let source = CGImageSourceCreateWithData(shared.data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw RoomPublicationImageSanitizationError.unsafeOutput }
        let encoded = try encodeJPEG(image)
        let stripped = try strippingAllJPEGApplicationSegments(encoded)
        guard !containsJPEGApplicationMarker(stripped) else {
            throw RoomPublicationImageSanitizationError.unsafeOutput
        }
        guard let verify = CGImageSourceCreateWithData(stripped as CFData, nil),
              CGImageSourceGetCount(verify) == 1,
              CGImageSourceGetStatus(verify) == .statusComplete,
              CGImageSourceCreateImageAtIndex(verify, 0, nil) != nil
        else { throw RoomPublicationImageSanitizationError.unsafeOutput }
        return .init(data: stripped, mediaType: .jpeg)
    }

    static func containsJPEGApplicationMarker(_ data: Data) -> Bool {
        guard data.count >= 4,
              data[0] == 0xff,
              data[1] == 0xd8
        else { return false }
        var offset = 2
        while offset + 1 < data.count {
            guard data[offset] == 0xff else { return false }
            while offset < data.count, data[offset] == 0xff { offset += 1 }
            guard offset < data.count else { return false }
            let marker = data[offset]
            offset += 1
            if marker == 0xda || marker == 0xd9 { return false }
            if (0xe0...0xef).contains(marker) { return true }
            if marker == 0x01 || (0xd0...0xd7).contains(marker) { continue }
            guard offset + 1 < data.count else { return false }
            let length = Int(data[offset]) << 8 | Int(data[offset + 1])
            guard length >= 2, offset + length <= data.count else { return false }
            offset += length
        }
        return false
    }

    private static func encodeJPEG(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { throw RoomPublicationImageSanitizationError.freshEncodeFailed }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw RoomPublicationImageSanitizationError.freshEncodeFailed
        }
        return output as Data
    }

    private static func strippingAllJPEGApplicationSegments(_ data: Data) throws -> Data {
        guard data.count >= 4, data[0] == 0xff, data[1] == 0xd8 else {
            throw RoomPublicationImageSanitizationError.malformedJPEG
        }
        var output = Data([0xff, 0xd8])
        var offset = 2
        while offset < data.count {
            guard data[offset] == 0xff else {
                throw RoomPublicationImageSanitizationError.malformedJPEG
            }
            let markerStart = offset
            while offset < data.count, data[offset] == 0xff { offset += 1 }
            guard offset < data.count else {
                throw RoomPublicationImageSanitizationError.malformedJPEG
            }
            let marker = data[offset]
            offset += 1
            if marker == 0xda {
                // The entropy-coded scan begins after the SOS segment length
                // and is copied unchanged through the exact encoder EOI.
                guard offset + 1 < data.count else {
                    throw RoomPublicationImageSanitizationError.malformedJPEG
                }
                let length = Int(data[offset]) << 8 | Int(data[offset + 1])
                guard length >= 2, offset + length <= data.count else {
                    throw RoomPublicationImageSanitizationError.malformedJPEG
                }
                output.append(data[markerStart...])
                return output
            }
            if marker == 0xd9 {
                output.append(0xff)
                output.append(marker)
                return output
            }
            if marker == 0x01 || (0xd0...0xd7).contains(marker) {
                output.append(0xff)
                output.append(marker)
                continue
            }
            guard offset + 1 < data.count else {
                throw RoomPublicationImageSanitizationError.malformedJPEG
            }
            let length = Int(data[offset]) << 8 | Int(data[offset + 1])
            guard length >= 2, offset + length <= data.count else {
                throw RoomPublicationImageSanitizationError.malformedJPEG
            }
            if !(0xe0...0xef).contains(marker) {
                output.append(0xff)
                output.append(marker)
                output.append(data[offset..<(offset + length)])
            }
            offset += length
        }
        throw RoomPublicationImageSanitizationError.malformedJPEG
    }
}

// MARK: - Production public-input mapping

struct RoomPublicationApprovedConceptAsset: Sendable, Equatable {
    let choice: RoomPublicationConceptChoice
    let data: Data
    let declaredFilename: String
}

enum RoomPublicationInputFactoryError: LocalizedError, Equatable {
    case missingHeadRevision
    case propertyRequiresAtLeastTwoRooms

    var errorDescription: String? {
        switch self {
        case .missingHeadRevision:
            "The room’s immutable head revision could not be loaded for publication review."
        case .propertyRequiresAtLeastTwoRooms:
            "A curated property portal needs at least two independently published rooms."
        }
    }
}

/// Maps real local room facts into an entirely new public allowlist input.
/// This is intentionally a native-only derivation seam: it reads the current
/// immutable revision through `RoomLibraryController`, invokes existing local
/// orientation/quality/Concept Set/floor-plan renderer boundaries, and passes
/// only typed public layout, geometry, raster, and selected-concept values to
/// `RoomPublishedSnapshotBuilder`.
@MainActor
final class RoomPublicationInputFactory {
    private let controller: RoomLibraryController
    private let aiRedesignModelFactory: RoomAIRedesignModelFactory
    private let aiReadyPackageProvider: any RoomPublicationAIReadyPackageProviding
    private let sourceIdentityResolver: any PublicationSourceIdentityResolving
    private let fileManager: FileManager

    init(
        controller: RoomLibraryController,
        aiRedesignModelFactory: RoomAIRedesignModelFactory,
        sourceIdentityResolver: any PublicationSourceIdentityResolving,
        aiReadyPackageProvider: (any RoomPublicationAIReadyPackageProviding)? = nil,
        fileManager: FileManager = .default
    ) {
        self.controller = controller
        self.aiRedesignModelFactory = aiRedesignModelFactory
        self.aiReadyPackageProvider = aiReadyPackageProvider ?? aiRedesignModelFactory
        self.sourceIdentityResolver = sourceIdentityResolver
        self.fileManager = fileManager
    }

    func makeInput(
        projectID: String,
        options: RoomPublicationReviewOptions
    ) async throws -> RoomPublicationReviewInput {
        let branding = try makeBranding(options.branding)
        switch options.mode {
        case .room:
            let room = try await makeRoom(
                projectID: projectID,
                publicRoomKey: Self.publicRoomKey(ordinal: 1),
                options: options
            )
            let downloads = Self.publicDownloadPolicy(
                staticDownloads: options.staticDownloads,
                aiReadySelection: room.aiReadySelection
            )
            return .init(
                journalAnchorProjectID: projectID,
                draft: .room(.init(
                    title: normalizedTitle(options.title, fallback: room.publicRoom.displayName),
                    room: room.publicRoom,
                    branding: branding.branding,
                    downloads: downloads
                )),
                sourceBindings: [room.sourceBinding],
                hostedSourceBindings: [room.hostedSourceBinding],
                propertyCuration: nil,
                assets: room.assets + branding.assets,
                rasterChoices: room.rasterChoices + branding.rasterChoices,
                conceptChoices: room.conceptChoices,
                aiReadyPackageChoices: room.aiReadyChoice.map { [$0] } ?? [],
                qualityWarnings: room.publicRoom.qualityWarnings
            )
        case .property:
            guard let property = try await controller.property(containing: projectID),
                  property.roomProjectIDs.count >= 2
            else { throw RoomPublicationInputFactoryError.propertyRequiresAtLeastTwoRooms }
            // Curated membership is ordered by its owner-maintained list. No
            // cross-room coordinates, transform, or connectivity is created.
            var rooms: [BuiltRoom] = []
            rooms.reserveCapacity(property.roomProjectIDs.count)
            for (index, roomProjectID) in property.roomProjectIDs.enumerated() {
                rooms.append(try await makeRoom(
                    projectID: roomProjectID,
                    publicRoomKey: Self.publicRoomKey(ordinal: index + 1),
                    options: options
                ))
            }
            let presentationTitle = normalizedTitle(options.title, fallback: property.displayName)
            let downloads = Self.publicDownloadPolicy(
                staticDownloads: options.staticDownloads,
                aiReadySelection: rooms.compactMap(\.aiReadySelection).first
            )
            let propertyCuration = RoomPublicationPropertyCuration(
                localPropertyID: property.propertyID,
                title: presentationTitle,
                rooms: rooms.enumerated().map { index, room in
                    .init(
                        publicRoomKey: room.publicRoom.roomKey,
                        roomOrder: index + 1,
                        projectPublicID: room.hostedSourceBinding.projectPublicID
                    )
                }
            )
            return .init(
                // Property recovery uses only its opaque local routing digest;
                // it never treats the first room as an identity or geometry
                // anchor for the independently published room revisions.
                journalAnchorProjectID: projectID,
                draft: .property(.init(
                    propertyTitle: presentationTitle,
                    rooms: rooms.map(\.publicRoom),
                    branding: branding.branding,
                    downloads: downloads
                )),
                sourceBindings: rooms.map(\.sourceBinding),
                hostedSourceBindings: rooms.map(\.hostedSourceBinding),
                propertyCuration: propertyCuration,
                assets: rooms.flatMap(\.assets) + branding.assets,
                rasterChoices: rooms.flatMap(\.rasterChoices) + branding.rasterChoices,
                conceptChoices: rooms.flatMap(\.conceptChoices),
                aiReadyPackageChoices: rooms.compactMap(\.aiReadyChoice),
                qualityWarnings: rooms.flatMap { $0.publicRoom.qualityWarnings }
            )
        }
    }

    /// Builds the immutable download fact only from a package selection that
    /// has just survived exact local archive/profile/source validation. The
    /// per-link AI policy is intentionally separate and remains disabled
    /// until Core seals this asset into a reviewed preparation.
    static func publicDownloadPolicy(
        staticDownloads: RoomPublicationStaticDownloadControls,
        aiReadySelection: RoomPublicationAIReadyPackageSelection?
    ) -> RoomPublishedDownloadPolicy {
        .init(
            floorPlanPDF: staticDownloads.allowsFloorPlanPDF,
            galleryZIP: staticDownloads.allowsGalleryZIP,
            aiReadyPackageAssetID: aiReadySelection?.assetID
        )
    }

    /// A retained AI-ready archive is not trusted merely because it exists in
    /// app-owned local storage. Re-read its ZIP closure and canonical manifest
    /// against the exact selected Core source before adding it to an empty
    /// publication allowlist. Invalid/missing/stale candidates are omitted;
    /// neither a URL nor a package identity is exposed to the review model.
    static func selectedAIReadyPackage(
        selectedPublicRoomKey: String?,
        candidate: RoomPublicationAIReadyPackageCandidate?,
        sourceBinding: RoomPublishedSourceBinding
    ) async -> RoomPublicationAIReadyPackageSelection? {
        guard selectedPublicRoomKey == sourceBinding.publicRoomKey,
              let candidate,
              candidate.sourceRevision == sourceBinding.sourceRevision,
              !candidate.expectedPackageID.isEmpty
        else { return nil }
        do {
            let values = try candidate.archiveURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let byteCount = values.fileSize,
                  byteCount > 0,
                  UInt64(byteCount) <= RoomPublicationTransportLimits.maximumAIReadyPackageBytes
            else { return nil }
            let verificationRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
                "RoomScanStudio-PublicationAIReady-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: verificationRoot,
                withIntermediateDirectories: false
            )
            defer { try? FileManager.default.removeItem(at: verificationRoot) }
            let validation = try await RoomAIRoomPackageArchive.extractAndValidate(
                archiveURL: candidate.archiveURL,
                into: verificationRoot,
                expectedSourceRevision: sourceBinding.sourceRevision,
                expectedProfile: .aiReady,
                limits: .init(
                    maxEntries: 4_096,
                    maxEntryBytes: RoomPublicationTransportLimits.maximumAIReadyPackageBytes,
                    maxArchiveBytes: RoomPublicationTransportLimits.maximumAIReadyPackageBytes
                )
            )
            guard validation.package.packageID == candidate.expectedPackageID,
                  validation.package.profile == RoomAIRoomPackageProfile.aiReady,
                  validation.package.sourceRevision == sourceBinding.sourceRevision
            else { return nil }
            let assetID = "ai-ready-\(sourceBinding.publicRoomKey)"
            return .init(
                assetID: assetID,
                asset: .aiReadyPackage(
                    assetID: assetID,
                    input: .init(
                        archiveURL: candidate.archiveURL,
                        publicRoomKey: sourceBinding.publicRoomKey,
                        expectedPackageID: candidate.expectedPackageID
                    )
                )
            )
        } catch {
            // Omission is fail-closed: an invalid/private/stale local archive
            // cannot become a public asset or per-link entitlement.
            return nil
        }
    }

    private func makeRoom(
        projectID: String,
        publicRoomKey: String,
        options: RoomPublicationReviewOptions
    ) async throws -> BuiltRoom {
        let package = try await controller.loadPackage(projectID: projectID)
        let revisionID = package.manifest.headRevisionID
        guard let revision = package.revisions.first(where: {
            $0.manifest.revisionID == revisionID
        }) else { throw RoomPublicationInputFactoryError.missingHeadRevision }
        let sourceRevision = try await controller.redesignSourceBinding(
            projectID: projectID,
            revisionID: revisionID
        )
        let sourceBinding = RoomPublishedSourceBinding(
            // This is a fresh public ordinal, never a private project or
            // revision identifier. The private mapping remains only in the
            // Core source binding control manifest.
            publicRoomKey: publicRoomKey,
            sourceRevision: sourceRevision
        )
        let hostedIdentity = try await sourceIdentityResolver.resolve(
            localProjectID: projectID,
            expectedSourceRevision: sourceRevision
        )
        let hostedSourceBinding = RoomPublicationHostedSourceBinding(
            publicRoomKey: publicRoomKey,
            identity: hostedIdentity
        )
        let aiReadyCandidate = await aiReadyPackageProvider.validatedAIReadyPackage(
            for: sourceRevision
        )
        let aiReadySelection = await Self.selectedAIReadyPackage(
            selectedPublicRoomKey: options.selectedAIReadyPackageRoomKey,
            candidate: aiReadyCandidate,
            sourceBinding: sourceBinding
        )
        let aiReadyChoice = aiReadyCandidate.map { _ in
            RoomPublicationAIReadyPackageChoice(
                publicRoomKey: publicRoomKey,
                label: "Validated AI-ready package for \(normalizedTitle(package.metadata.customName, fallback: "Room"))"
            )
        }
        let projection = try RoomFloorPlanProjection.make(
            from: revision.payload.semanticSnapshot
        )
        let floorPlan = try await renderPublicFloorPlan(
            snapshot: revision.payload.semanticSnapshot,
            sourceRevision: sourceRevision
        )
        let originalID = "selected-original-\(publicRoomKey)"
        let originalPreview: RoomPublishedRaster?
        if let thumbnail = try await controller.thumbnailData(
            for: projectID,
            expectedHeadRevisionID: revisionID
        ) {
            originalPreview = try RoomPublicationImageSanitizer.sanitize(
                thumbnail,
                declaredFilename: thumbnailFilename(thumbnail)
            )
        } else {
            // A floor plan is not photographic/original evidence. Without a
            // canonical selected image, comparison is omitted entirely.
            originalPreview = nil
        }
        let selectedOriginal = options.excludedRasterAssetIDs.contains(originalID)
            ? nil
            : originalPreview
        let sourceCompanion = try await controller.redesignState(
            sourceRevision: sourceRevision
        )
        let rawCandidates: [RoomPublicationApprovedConceptAsset]
        if originalPreview == nil {
            rawCandidates = []
        } else {
            rawCandidates = try await aiRedesignModelFactory
                .approvedPublicationConceptAssets(sourceRevision: sourceRevision)
        }
        let candidates: [(assetID: String, choice: RoomPublicationConceptChoice, raster: RoomPublishedRaster)] = try rawCandidates.enumerated().map { index, candidate in
            let ordinal = String(format: "%03d", index + 1)
            return (
                assetID: "\(publicRoomKey)-approved-concept-\(ordinal)",
                choice: .init(
                    id: "\(publicRoomKey)-concept-\(ordinal)",
                    label: "Approved concept \(index + 1)"
                ),
                raster: try RoomPublicationImageSanitizer.sanitize(
                    candidate.data,
                    declaredFilename: candidate.declaredFilename
                )
            )
        }
        // Concept bytes are allowed only as an approved original/concept
        // comparison. Retain safe preview choices for later re-inclusion, but
        // never leave unreferenced concept working material in the closure.
        let selectedConcepts = selectedOriginal == nil ? [] : candidates
            .filter { options.selectedConceptIDs.contains($0.choice.id) }
            .sorted { $0.choice.id < $1.choice.id }
        let roomKey = sourceBinding.publicRoomKey
        let geometryID = "geometry-\(roomKey)"
        let floorPlanID = "floor-plan-\(roomKey)"
        let conceptAssets = selectedConcepts
        let publicRoom = RoomPublishedPublicRoom(
            roomKey: roomKey,
            displayName: normalizedTitle(package.metadata.customName, fallback: "Room"),
            semanticLayout: .init(elements: publicLayout(projection)),
            orientation: .init(initialView: initialView(from: sourceCompanion)),
            dimensions: publicDimensions(projection),
            qualityWarnings: Self.publicQualityWarnings(revision.manifest.qualityReport),
            comparisons: selectedOriginal == nil ? [] : conceptAssets.map { asset in
                .init(
                    originalAssetID: originalID,
                    conceptAssetID: asset.assetID,
                    label: asset.choice.label,
                    disclaimer: "Original room evidence is authoritative. Concepts are visual references and do not change the room."
                )
            },
            assets: .init(
                webGeometryAssetID: geometryID,
                floorPlanAssetID: floorPlanID,
                selectedImageAssetIDs: selectedOriginal == nil ? [] : [originalID],
                webTextureAssetIDs: [],
                approvedConceptAssetIDs: conceptAssets.map(\.assetID)
            )
        )
        var assets: [RoomPublishedAssetInput] = [
            .geometry(
                assetID: geometryID,
                publicRoomKey: roomKey,
                geometry: Self.roomLocalFloorGeometry(from: projection)
            ),
            .raster(
                assetID: floorPlanID,
                publicRoomKey: roomKey,
                assetClass: .floorPlan,
                raster: floorPlan
            ),
        ]
        if let selectedOriginal {
            assets.append(.raster(
                assetID: originalID,
                publicRoomKey: roomKey,
                assetClass: .selectedImage,
                raster: selectedOriginal
            ))
        }
        assets += conceptAssets.map { asset in
            .raster(
                assetID: asset.assetID,
                publicRoomKey: roomKey,
                assetClass: .approvedConcept,
                raster: asset.raster
            )
        }
        if let aiReadySelection {
            assets.append(aiReadySelection.asset)
        }
        var rasterChoices: [RoomPublicationRasterChoice] = [
            .init(
                assetID: floorPlanID,
                publicRoomKey: roomKey,
                assetClass: .floorPlan,
                raster: floorPlan
            )
        ]
        if let originalPreview {
            rasterChoices.append(.init(
                assetID: originalID,
                publicRoomKey: roomKey,
                assetClass: .selectedImage,
                raster: originalPreview
            ))
        }
        rasterChoices += candidates.map { candidate in
            .init(
                assetID: candidate.assetID,
                publicRoomKey: roomKey,
                assetClass: .approvedConcept,
                raster: candidate.raster
            )
        }
        return .init(
            publicRoom: publicRoom,
            sourceBinding: sourceBinding,
            hostedSourceBinding: hostedSourceBinding,
            assets: assets,
            rasterChoices: rasterChoices,
            conceptChoices: candidates.map(\.choice),
            aiReadyChoice: aiReadyChoice,
            aiReadySelection: aiReadySelection
        )
    }

    private func renderPublicFloorPlan(
        snapshot: RoomSemanticSnapshot,
        sourceRevision: RoomRedesignSourceRevision
    ) async throws -> RoomPublishedRaster {
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "RoomScanStudio-PublicationFloorPlan-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }
        let artifact = try await UIKitRoomAIRoomPackageDerivativeRenderer(
            snapshot: snapshot,
            expectedSourceRevision: sourceRevision,
            canonicalViewSources: [:]
        ).renderFloorPlanPNG(sourceRevision: sourceRevision, into: root)
        let data = try Data(contentsOf: artifact.sourceURL, options: [.mappedIfSafe])
        return try RoomPublicationImageSanitizer.sanitize(
            data,
            declaredFilename: artifact.relativePath
        )
    }

    private func makeBranding(_ draft: RoomPublicationBrandingDraft) throws -> BuiltBranding {
        let phone = trimmedOrNil(draft.phone)
        let website = trimmedOrNil(draft.website)
        if let logo = draft.logo {
            let assetID = "branding-logo"
            let raster = try RoomPublicationImageSanitizer.sanitize(
                logo.data,
                declaredFilename: logo.declaredFilename
            )
            return .init(
                branding: .init(
                    businessName: draft.businessName.trimmingCharacters(in: .whitespacesAndNewlines),
                    logoAssetID: assetID,
                    contact: .init(phone: phone, website: website),
                    accent: draft.accent
                ),
                assets: [.raster(
                    assetID: assetID,
                    publicRoomKey: nil,
                    assetClass: .brandingLogo,
                    raster: raster
                )],
                rasterChoices: [.init(
                    assetID: assetID,
                    publicRoomKey: nil,
                    assetClass: .brandingLogo,
                    raster: raster
                )]
            )
        }
        return .init(
            branding: .init(
                businessName: draft.businessName.trimmingCharacters(in: .whitespacesAndNewlines),
                contact: .init(phone: phone, website: website),
                accent: draft.accent
            ),
            assets: [],
            rasterChoices: []
        )
    }

    private func publicLayout(_ projection: RoomFloorPlanProjection) -> [RoomPublishedLayoutElement] {
        let spanX = max(projection.bounds.width, 0.01)
        let spanY = max(projection.bounds.height, 0.01)
        return projection.items.prefix(1_000).map { item in
            let xs = item.corners.map(\.x)
            let ys = item.corners.map(\.y)
            let minimumX = xs.min() ?? item.center.x
            let maximumX = xs.max() ?? item.center.x
            let minimumY = ys.min() ?? item.center.y
            let maximumY = ys.max() ?? item.center.y
            let x = unit((minimumX - projection.bounds.minimum.x) / spanX)
            let y = unit((minimumY - projection.bounds.minimum.y) / spanY)
            let width = max(0.0001, min(1 - x, (maximumX - minimumX) / spanX))
            let height = max(0.0001, min(1 - y, (maximumY - minimumY) / spanY))
            return .init(
                kind: layoutKind(item.kind, structural: item.isStructural),
                label: normalizedTitle(item.label, fallback: item.kind),
                x: x,
                y: y,
                width: width,
                height: height
            )
        }
    }

    private func publicDimensions(_ projection: RoomFloorPlanProjection) -> [RoomPublishedDimension] {
        [
            .init(label: "Width", meters: max(0.001, projection.bounds.width)),
            .init(label: "Depth", meters: max(0.001, projection.bounds.height)),
        ]
    }

    /// An honest room-local floor rectangle derived from the real semantic
    /// projection bounds. It does not invent walls, joins, or any property
    /// transform; property viewers reset this geometry per selected room.
    static func roomLocalFloorGeometry(
        from projection: RoomFloorPlanProjection
    ) -> RoomPublishedWebGeometry {
        let minimumX = projection.bounds.minimum.x
        let maximumX = projection.bounds.maximum.x
        let minimumZ = projection.bounds.minimum.y
        let maximumZ = projection.bounds.maximum.y
        return .init(
            vertices: [
                .init(x: minimumX, y: 0, z: minimumZ),
                .init(x: maximumX, y: 0, z: minimumZ),
                .init(x: minimumX, y: 0, z: maximumZ),
                .init(x: maximumX, y: 0, z: maximumZ),
            ],
            triangles: [.init(a: 0, b: 1, c: 2), .init(a: 1, b: 3, c: 2)]
        )
    }

    static func publicRoomKey(ordinal: Int) -> String {
        "room-\(String(format: "%03d", max(1, ordinal)))"
    }

    private func initialView(
        from companion: RoomLocalRedesignExtensionV2?
    ) -> RoomPublishedInitialView {
        guard let role = companion?.orientation.canonicalCameras.first?.role else {
            return .topDown
        }
        switch role {
        case .entry: return .entry
        case .wall: return .wall
        case .corner, .orbit, .perspective: return .corner
        case .topDown: return .topDown
        }
    }

    static func publicQualityWarnings(
        _ report: RoomQualityReport?
    ) -> [RoomPublishedQualityWarning] {
        guard let report else { return [] }
        var emitted = Set<String>()
        return report.records.compactMap { record in
            guard record.state != .acceptable,
                  emitted.insert(record.dimension.rawValue).inserted
            else { return nil }
            return .init(
                code: publicQualityCode(record.dimension),
                severity: record.state == .insufficientEvidence ? .insufficientEvidence : .reviewRecommended,
                message: "\(qualityLabel(record.dimension)) may need review."
            )
        }
    }

    private func layoutKind(_ rawKind: String, structural: Bool) -> RoomPublishedLayoutKind {
        switch rawKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "wall": .wall
        case "door": .door
        case "window": .window
        case "opening": .opening
        case "floor": .floor
        default: structural ? .fixedObject : .movableObject
        }
    }

    private static func qualityLabel(_ dimension: RoomQualityDimension) -> String {
        switch dimension {
        case .visualSharpness: "Visual sharpness"
        case .spatialVisualCoverage: "Visual coverage"
        case .arTracking: "Tracking"
        case .semanticIdentificationConfidence: "Semantic identification"
        }
    }

    private static func publicQualityCode(_ dimension: RoomQualityDimension) -> String {
        switch dimension {
        case .visualSharpness: "visual-sharpness"
        case .spatialVisualCoverage: "visual-coverage"
        case .arTracking: "tracking"
        case .semanticIdentificationConfidence: "semantic-identification"
        }
    }

    private func thumbnailFilename(_ data: Data) -> String {
        let pngSignature = [UInt8](data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10]
        return pngSignature ? "thumbnail.png" : "thumbnail.jpg"
    }

    private func normalizedTitle(_ value: String, fallback: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? fallback : normalized
    }

    private func trimmedOrNil(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func unit(_ value: Double) -> Double { min(1, max(0, value)) }

    private struct BuiltRoom {
        let publicRoom: RoomPublishedPublicRoom
        let sourceBinding: RoomPublishedSourceBinding
        let hostedSourceBinding: RoomPublicationHostedSourceBinding
        let assets: [RoomPublishedAssetInput]
        let rasterChoices: [RoomPublicationRasterChoice]
        let conceptChoices: [RoomPublicationConceptChoice]
        let aiReadyChoice: RoomPublicationAIReadyPackageChoice?
        let aiReadySelection: RoomPublicationAIReadyPackageSelection?
    }

    private struct BuiltBranding {
        let branding: RoomPublishedBranding
        let assets: [RoomPublishedAssetInput]
        let rasterChoices: [RoomPublicationRasterChoice]
    }
}

// MARK: - Deterministic DEBUG fixture (no hosted client)

#if DEBUG
@MainActor
final class RoomPublicationFixtureTransport: RoomPublicationTransport {
    private let initiallyRevoked: Bool
    private var remainingLinkFailures: Int
    private(set) var allocationCount = 0
    private(set) var uploadCount = 0
    private(set) var linkRequestCount = 0
    private(set) var revokeCount = 0
    private var fixtureStatus: RoomPublicationRemoteAllocationStatus?

    /// Compatibility-only test spelling. It now measures `pua_` allocation,
    /// not a speculative snapshot reservation.
    var reservationCount: Int { allocationCount }

    init(
        initiallyRevoked: Bool = false,
        failuresBeforeLinkSuccess: Int = 0
    ) {
        self.initiallyRevoked = initiallyRevoked
        remainingLinkFailures = max(0, failuresBeforeLinkSuccess)
    }

    func allocatePublication(
        _ request: RoomPublicationAllocationRequest
    ) async throws -> RoomPublicationUploadAllocation {
        try request.validate()
        allocationCount += 1
        let allocationID = "pua_fixtureallocation0001"
        fixtureStatus = .init(
            allocationID: allocationID,
            state: .allocated,
            kind: request.publicationKind,
            projectID: request.projectID,
            sourceRevisionID: request.sourceRevisionID,
            propertyID: request.propertyID,
            snapshotID: nil,
            rejectionCode: nil,
            createdAt: Date(timeIntervalSince1970: 1_786_896_000),
            updatedAt: Date(timeIntervalSince1970: 1_786_896_000),
            expiresAt: Date(timeIntervalSince1970: 1_786_899_600)
        )
        return .fixture(
            allocationID: allocationID,
            allocationExpiresAt: Date(timeIntervalSince1970: 1_786_899_600),
            uploadURL: URL(string: "https://objects.example.invalid/publication/fixture?signature=fixture")!,
            uploadHeaders: ["x-roomscan-upload": "fixture"]
        )
    }

    func uploadPublicationArchive(
        _ archive: RoomPublicationArchiveUpload,
        allocation: RoomPublicationUploadAllocation
    ) async throws {
        guard allocation.allocationID == "pua_fixtureallocation0001",
              archive.byteCount > 0,
              !archive.archiveSHA256.isEmpty
        else { throw RoomPublicationTransportError.invalidResponse }
        uploadCount += 1
    }

    func completePublication(
        allocationID: String,
        archiveSHA256: String,
        archiveManifestSHA256: String,
        archiveByteCount: UInt64
    ) async throws -> RoomPublicationCompletionStatus {
        guard allocationID == "pua_fixtureallocation0001",
              !archiveSHA256.isEmpty,
              !archiveManifestSHA256.isEmpty,
              archiveByteCount > 0,
              var status = fixtureStatus
        else {
            throw RoomPublicationTransportError.invalidResponse
        }
        status = .init(
            allocationID: status.allocationID,
            state: .published,
            kind: status.kind,
            projectID: status.projectID,
            sourceRevisionID: status.sourceRevisionID,
            propertyID: status.propertyID,
            snapshotID: "snp_fixturepublication0001",
            rejectionCode: nil,
            createdAt: status.createdAt,
            updatedAt: Date(timeIntervalSince1970: 1_786_896_100),
            expiresAt: status.expiresAt
        )
        fixtureStatus = status
        return .init(allocationID: allocationID, disposition: .validationPending)
    }

    func allocationStatus(allocationID: String) async throws -> RoomPublicationRemoteAllocationStatus {
        guard allocationID == "pua_fixtureallocation0001", let status = fixtureStatus else {
            throw RoomPublicationTransportError.invalidResponse
        }
        return status
    }

    func upsertPropertyCuration(
        _ request: RoomPublicationPropertyCurationRequest
    ) async throws -> RoomPublicationPropertyCurationStatus {
        try request.validate()
        return .init(propertyID: "prop_fixtureproperty0001", version: (request.expectedVersion ?? 0) + 1)
    }

    func createPortalLink(
        snapshotID: String,
        request: RoomPublicationPortalLinkRequest
    ) async throws -> RoomPublicationPortalLinkStatus {
        guard snapshotID == "snp_fixturepublication0001" else {
            throw RoomPublicationTransportError.invalidResponse
        }
        linkRequestCount += 1
        if remainingLinkFailures > 0 {
            remainingLinkFailures -= 1
            throw RoomPublicationTransportError.unavailable
        }
        return .init(
            linkID: "lnk_fixtureportal0001",
            generation: 1,
            lifecycle: initiallyRevoked ? .revoked : .active,
            expiresAt: request.expiresAt ?? Date(timeIntervalSince1970: 1_789_488_000),
            pinRequired: request.pinCandidate != nil,
            aiEnabled: request.aiPolicy == .enabled,
            feedbackEnabled: request.feedbackPolicy == .enabled,
            feedbackSummary: .init(
                recordCount: 1,
                isCapped: false,
                latestActionLabel: "Approve",
                latestRecordedAt: Date(timeIntervalSince1970: 1_786_896_200)
            )
        )
    }

    func portalLinkStatus(
        linkID: String,
        snapshotID: String
    ) async throws -> RoomPublicationPortalLinkStatus? {
        guard linkID == "lnk_fixtureportal0001",
              snapshotID == "snp_fixturepublication0001"
        else { throw RoomPublicationTransportError.invalidResponse }
        return .init(
            linkID: linkID,
            generation: initiallyRevoked ? 2 : 1,
            lifecycle: initiallyRevoked ? .revoked : .active,
            expiresAt: Date(timeIntervalSince1970: 1_789_488_000),
            pinRequired: false,
            aiEnabled: false,
            feedbackEnabled: true,
            feedbackSummary: .init(
                recordCount: 1,
                isCapped: false,
                latestActionLabel: "Approve",
                latestRecordedAt: Date(timeIntervalSince1970: 1_786_896_200)
            )
        )
    }

    func revokePortalLink(
        linkID: String,
        expectedGeneration: Int
    ) async throws -> RoomPublicationPortalLinkRevocation {
        guard linkID == "lnk_fixtureportal0001", expectedGeneration == 1 else {
            throw RoomPublicationTransportError.invalidResponse
        }
        revokeCount += 1
        return .init(linkID: linkID, generation: 2, disposition: "revoked")
    }
}

@MainActor
private final class RoomPublicationFixtureIdentityResolver: PublicationSourceIdentityResolving {
    func resolve(localProjectID: String, expectedSourceRevision: RoomRedesignSourceRevision) async throws -> RoomPublicationHostedSourceIdentity {
        guard localProjectID == expectedSourceRevision.projectID else {
            throw RoomPublicationSourceIdentityError.localHeadDiverged
        }
        let suffix = expectedSourceRevision.projectID.contains("south") ? "0000000000000002" : "0000000000000001"
        return .init(
            projectPublicID: "prj_\(suffix)",
            revisionPublicID: "rev_\(suffix)",
            sourceRevision: expectedSourceRevision
        )
    }

}

extension RoomPublicationService {
    static func fixture(
        transport: any RoomPublicationTransport
    ) -> RoomPublicationService {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RoomScanStudio-PublicationFixtureJournal-\(UUID().uuidString)",
            isDirectory: true
        )
        let journal: PublicationOperationJournal
        do {
            journal = try PublicationOperationJournal(rootURL: root)
        } catch {
            preconditionFailure("Unable to create isolated publication fixture journal: \(error)")
        }
        return RoomPublicationService(
            transport: transport,
            workspaceFactory: RoomExportWorkspaceFactory(
                rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "RoomScanStudio-PublicationFixtureExport",
                    isDirectory: true
                )
            ),
            identityResolver: RoomPublicationFixtureIdentityResolver(),
            operationJournal: journal,
            now: { Date(timeIntervalSince1970: 1_786_896_000) }
        )
    }
}

enum RoomPublicationFixtureFactory {
    static func makeInput(
        options: RoomPublicationReviewOptions,
        includeWarning: Bool
    ) throws -> RoomPublicationReviewInput {
        let floorPlan = try RoomPublicationImageSanitizer.sanitize(
            fixtureRaster(red: 30, green: 102, blue: 122),
            declaredFilename: "floor-plan.jpg"
        )
        let original = try RoomPublicationImageSanitizer.sanitize(
            fixtureRaster(red: 138, green: 88, blue: 36),
            declaredFilename: "original.jpg"
        )
        let concept = try RoomPublicationImageSanitizer.sanitize(
            fixtureRaster(red: 79, green: 118, blue: 89),
            declaredFilename: "concept.jpg"
        )
        let includeConcept = options.selectedConceptIDs.contains("approved-concept-a")
        let includeNorthOriginal = !options.excludedRasterAssetIDs.contains("original-north")
        let includeSouthOriginal = !options.excludedRasterAssetIDs.contains("original-south")
        let warning = includeWarning ? [RoomPublishedQualityWarning(
            code: "limited-coverage",
            severity: .reviewRecommended,
            message: "One area has limited coverage. Review the room before relying on dimensions."
        )] : []
        let branding = RoomPublishedBranding(
            businessName: options.branding.businessName,
            contact: .init(
                phone: options.branding.phone,
                website: options.branding.website
            ),
            accent: options.branding.accent
        )
        let roomOne = makeRoom(
            key: "room-001",
            name: "North room",
            floorPlanAssetID: "floor-plan-north",
            originalAssetID: "original-north",
            conceptAssetID: "concept-north",
            includeOriginal: includeNorthOriginal,
            includeConcept: includeConcept && includeNorthOriginal,
            warning: warning
        )
        let roomTwo = makeRoom(
            key: "room-002",
            name: "South room",
            floorPlanAssetID: "floor-plan-south",
            originalAssetID: "original-south",
            conceptAssetID: "concept-south",
            includeOriginal: includeSouthOriginal,
            includeConcept: includeConcept && includeSouthOriginal,
            warning: []
        )
        let downloads = RoomPublishedDownloadPolicy(
            floorPlanPDF: options.staticDownloads.allowsFloorPlanPDF,
            galleryZIP: options.staticDownloads.allowsGalleryZIP,
            aiReadyPackageAssetID: nil
        )
        let draft: RoomPublishedSnapshotDraft
        let bindings: [RoomPublishedSourceBinding]
        var assets: [RoomPublishedAssetInput]
        switch options.mode {
        case .room:
            draft = .room(.init(
                title: options.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? roomOne.displayName
                    : options.title,
                room: roomOne,
                branding: branding,
                downloads: downloads
            ))
            bindings = [.init(publicRoomKey: roomOne.roomKey, sourceRevision: source("north"))]
            assets = makeAssets(
                room: roomOne,
                floorPlan: floorPlan,
                original: original,
                concept: concept,
                includeOriginal: includeNorthOriginal,
                includeConcept: includeConcept && includeNorthOriginal
            )
        case .property:
            draft = .property(.init(
                propertyTitle: options.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Harbor property"
                    : options.title,
                rooms: [roomOne, roomTwo],
                branding: branding,
                downloads: downloads
            ))
            bindings = [
                .init(publicRoomKey: roomOne.roomKey, sourceRevision: source("north")),
                .init(publicRoomKey: roomTwo.roomKey, sourceRevision: source("south")),
            ]
            assets = makeAssets(
                room: roomOne,
                floorPlan: floorPlan,
                original: original,
                concept: concept,
                includeOriginal: includeNorthOriginal,
                includeConcept: includeConcept && includeNorthOriginal
            ) + makeAssets(
                room: roomTwo,
                floorPlan: floorPlan,
                original: original,
                concept: concept,
                includeOriginal: includeSouthOriginal,
                includeConcept: includeConcept && includeSouthOriginal
            )
        }
        let hostedBindings = bindings.enumerated().map { index, binding in
            let suffix = index == 0 ? "0000000000000001" : "0000000000000002"
            return RoomPublicationHostedSourceBinding(
                publicRoomKey: binding.publicRoomKey,
                projectPublicID: "prj_\(suffix)",
                revisionPublicID: "rev_\(suffix)",
                sourceRevision: binding.sourceRevision
            )
        }
        let propertyCuration: RoomPublicationPropertyCuration? = options.mode == .property
            ? .init(
                localPropertyID: "fixture-property-001",
                title: options.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Harbor property" : options.title,
                rooms: hostedBindings.enumerated().map { index, binding in
                    .init(
                        publicRoomKey: binding.publicRoomKey,
                        roomOrder: index + 1,
                        projectPublicID: binding.projectPublicID
                    )
                }
            )
            : nil
        return .init(
            journalAnchorProjectID: bindings[0].sourceRevision.projectID,
            draft: draft,
            sourceBindings: bindings,
            hostedSourceBindings: hostedBindings,
            propertyCuration: propertyCuration,
            assets: assets,
            rasterChoices: rasterChoices(
                mode: options.mode,
                floorPlan: floorPlan,
                original: original,
                concept: concept
            ),
            conceptChoices: [.init(id: "approved-concept-a", label: "Approved garden concept")],
            aiReadyPackageChoices: [],
            qualityWarnings: warning
        )
    }

    private static func makeRoom(
        key: String,
        name: String,
        floorPlanAssetID: String,
        originalAssetID: String,
        conceptAssetID: String,
        includeOriginal: Bool,
        includeConcept: Bool,
        warning: [RoomPublishedQualityWarning]
    ) -> RoomPublishedPublicRoom {
        .init(
            roomKey: key,
            displayName: name,
            semanticLayout: .init(elements: [
                .init(kind: .wall, label: "North wall", x: 0, y: 0, width: 1, height: 0.04),
                .init(kind: .opening, label: "Entry", x: 0.42, y: 0, width: 0.16, height: 0.04),
            ]),
            orientation: .init(initialView: .entry),
            dimensions: [
                .init(label: "Width", meters: 4.2),
                .init(label: "Depth", meters: 3.6),
            ],
            qualityWarnings: warning,
            comparisons: includeOriginal && includeConcept ? [.init(
                originalAssetID: originalAssetID,
                conceptAssetID: conceptAssetID,
                label: "Approved concept comparison",
                disclaimer: "Original room evidence is authoritative. Concepts are visual references and do not change the room."
            )] : [],
            assets: .init(
                webGeometryAssetID: "geometry-\(key)",
                floorPlanAssetID: floorPlanAssetID,
                selectedImageAssetIDs: includeOriginal ? [originalAssetID] : [],
                webTextureAssetIDs: [],
                approvedConceptAssetIDs: includeConcept ? [conceptAssetID] : []
            )
        )
    }

    private static func rasterChoices(
        mode: RoomPublicationReviewMode,
        floorPlan: RoomPublishedRaster,
        original: RoomPublishedRaster,
        concept: RoomPublishedRaster
    ) -> [RoomPublicationRasterChoice] {
        func choices(
            roomKey: String,
            floorPlanID: String,
            originalID: String,
            conceptID: String
        ) -> [RoomPublicationRasterChoice] {
            [
                .init(assetID: floorPlanID, publicRoomKey: roomKey, assetClass: .floorPlan, raster: floorPlan),
                .init(assetID: originalID, publicRoomKey: roomKey, assetClass: .selectedImage, raster: original),
                .init(assetID: conceptID, publicRoomKey: roomKey, assetClass: .approvedConcept, raster: concept),
            ]
        }
        let north = choices(
            roomKey: "room-001",
            floorPlanID: "floor-plan-north",
            originalID: "original-north",
            conceptID: "concept-north"
        )
        guard mode == .property else { return north }
        return north + choices(
            roomKey: "room-002",
            floorPlanID: "floor-plan-south",
            originalID: "original-south",
            conceptID: "concept-south"
        )
    }

    private static func makeAssets(
        room: RoomPublishedPublicRoom,
        floorPlan: RoomPublishedRaster,
        original: RoomPublishedRaster,
        concept: RoomPublishedRaster,
        includeOriginal: Bool,
        includeConcept: Bool
    ) -> [RoomPublishedAssetInput] {
        var values: [RoomPublishedAssetInput] = [
            .geometry(
                assetID: room.assets.webGeometryAssetID,
                publicRoomKey: room.roomKey,
                geometry: .init(
                    vertices: [
                        .init(x: 0, y: 0, z: 0),
                        .init(x: 1, y: 0, z: 0),
                        .init(x: 0, y: 0, z: 1),
                        .init(x: 1, y: 0, z: 1),
                    ],
                    triangles: [.init(a: 0, b: 1, c: 2), .init(a: 1, b: 3, c: 2)]
                )
            ),
            .raster(
                assetID: room.assets.floorPlanAssetID,
                publicRoomKey: room.roomKey,
                assetClass: .floorPlan,
                raster: floorPlan
            ),
        ]
        if includeOriginal, let originalID = room.assets.selectedImageAssetIDs.first {
            values.append(.raster(
                assetID: originalID,
                publicRoomKey: room.roomKey,
                assetClass: .selectedImage,
                raster: original
            ))
        }
        if includeConcept, let conceptID = room.assets.approvedConceptAssetIDs.first {
            values.append(.raster(
                assetID: conceptID,
                publicRoomKey: room.roomKey,
                assetClass: .approvedConcept,
                raster: concept
            ))
        }
        return values
    }

    private static func source(_ suffix: String) -> RoomRedesignSourceRevision {
        .init(
            projectID: "private-project-canary-\(suffix)",
            revisionID: "private-revision-canary-\(suffix)",
            coordinateSpaceEpochID: "private-epoch-canary-\(suffix)",
            packageSchemaVersion: RoomProjectSchemaVersion.v2.rawValue,
            semanticSHA256: String(repeating: suffix == "north" ? "a" : "b", count: 64),
            revisionManifestSHA256: String(repeating: suffix == "north" ? "c" : "d", count: 64)
        )
    }

    private static func fixtureRaster(red: UInt8, green: UInt8, blue: UInt8) throws -> Data {
        let width = 24
        let height = 18
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = red
            pixels[index + 1] = green
            pixels[index + 2] = blue
            pixels[index + 3] = 255
        }
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage()
        else { throw RoomPublicationImageSanitizationError.freshEncodeFailed }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { throw RoomPublicationImageSanitizationError.freshEncodeFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RoomPublicationImageSanitizationError.freshEncodeFailed
        }
        return output as Data
    }
}
#endif
