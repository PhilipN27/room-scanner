import Foundation

/// The Slice 5 route client. Implementations may hold authorization only in
/// process memory; signed object URLs are passed through this protocol only
/// for the duration of a streaming request and never enter the app journal.
protocol ProfessionalProjectSyncTransport: Sendable {
    func allocateMigration(_ request: ProfessionalProjectSyncMigrationRequest) async throws -> ProfessionalProjectSyncUploadAllocation
    func allocateRevision(_ request: ProfessionalProjectSyncRevisionRequest) async throws -> ProfessionalProjectSyncUploadAllocation
    func upload(archiveURL: URL, allocation: ProfessionalProjectSyncUploadAllocation) async throws
    func complete(uploadID: String) async throws -> ProfessionalProjectSyncUploadStatus
    func uploadStatus(uploadID: String) async throws -> ProfessionalProjectSyncUploadStatus
    func allocateRecovery(projectID: String, revisionID: String?) async throws -> ProfessionalProjectSyncRecoveryDownload
    func download(_ recovery: ProfessionalProjectSyncRecoveryDownload, to destinationURL: URL) async throws
    func acquireLease(_ request: ProfessionalProjectSyncLeaseRequest) async throws -> ProfessionalProjectSyncLease
    func renewLease(projectID: String, leaseToken: String, hostedGlobalVersion: Int, hostedWorkspaceVersion: Int) async throws -> ProfessionalProjectSyncLease
    func releaseLease(projectID: String, leaseToken: String, hostedGlobalVersion: Int, hostedWorkspaceVersion: Int) async throws -> ProfessionalProjectSyncLease
    func configureRawArchive(projectID: String, reviewSHA256: String, hostedGlobalVersion: Int, hostedWorkspaceVersion: Int) async throws -> ProfessionalProjectSyncRawConfiguration
    func allocateRawArchive(_ request: ProfessionalProjectSyncRawArchiveRequest) async throws -> ProfessionalProjectSyncUploadAllocation
}

/// Provider-neutral implementation over the existing audited Foundation
/// boundary. It attaches bearer material only to first-party JSON requests;
/// the URLSession streaming calls receive no auth header at all.
final class FoundationProfessionalProjectSyncTransport: ProfessionalProjectSyncTransport, @unchecked Sendable {
    private let baseURL: URL
    private let authorization: @Sendable () -> String
    private let http: any ProfessionalHTTPTransport
    private let fileTransfer: any ProfessionalFileStreamingTransport
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        baseURL: URL,
        authorization: @escaping @Sendable () -> String,
        http: any ProfessionalHTTPTransport,
        fileTransfer: any ProfessionalFileStreamingTransport
    ) throws {
        guard Self.isSecureHTTPSURL(baseURL) else {
            throw ProfessionalProjectSyncError.insecureURL
        }
        self.baseURL = baseURL
        self.authorization = authorization
        self.http = http
        self.fileTransfer = fileTransfer
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func allocateMigration(_ request: ProfessionalProjectSyncMigrationRequest) async throws -> ProfessionalProjectSyncUploadAllocation {
        try validateWorkingArchive(sha256: request.archiveSHA256, byteCount: request.archiveByteCount)
        let allocation = try await json(path: "/projects/migration/allocate", body: request, response: AllocationWire.self).model
        try validate(
            allocation: allocation,
            projectID: nil,
            candidateRevisionID: nil,
            archiveSHA256: request.archiveSHA256,
            archiveByteCount: request.archiveByteCount,
            maximumByteCount: ProfessionalProjectSyncPreview.maximumHostedWorkingArchiveBytes,
            permitsRawAttachment: false
        )
        return allocation
    }

    func allocateRevision(_ request: ProfessionalProjectSyncRevisionRequest) async throws -> ProfessionalProjectSyncUploadAllocation {
        try validateWorkingArchive(sha256: request.archiveSHA256, byteCount: request.archiveByteCount)
        guard ProfessionalProjectSyncJournalRecord.isHostedProjectID(request.projectID),
              ProfessionalProjectSyncJournalRecord.isHostedRevisionID(request.expectedHostedHeadRevisionID),
              ProfessionalProjectSyncJournalRecord.isSafeIdentifier(request.expectedHeadRevisionID),
              ProfessionalProjectSyncJournalRecord.isSafeIdentifier(request.proposedRevisionID),
              request.expectedHeadRevisionID != request.proposedRevisionID
        else { throw ProfessionalProjectSyncError.invalidResponse }
        let allocation = try await json(path: "/projects/revisions/allocate", body: request, response: AllocationWire.self).model
        try validate(
            allocation: allocation,
            projectID: request.projectID,
            candidateRevisionID: nil,
            archiveSHA256: request.archiveSHA256,
            archiveByteCount: request.archiveByteCount,
            maximumByteCount: ProfessionalProjectSyncPreview.maximumHostedWorkingArchiveBytes,
            permitsRawAttachment: false
        )
        return allocation
    }

    func upload(archiveURL: URL, allocation: ProfessionalProjectSyncUploadAllocation) async throws {
        guard allocation.status == .allocated else {
            throw ProfessionalProjectSyncError.invalidResponse
        }
        guard Self.isSecureHTTPSURL(allocation.transientUploadURL) else {
            throw ProfessionalProjectSyncError.insecureURL
        }
        guard !allocation.transientUploadHeaders.keys.contains(where: {
            $0.caseInsensitiveCompare("Authorization") == .orderedSame
        }) else { throw ProfessionalProjectSyncError.forbiddenSignedRequestAuthorization }
        let result = try await fileTransfer.uploadFile(
            at: archiveURL,
            to: allocation.transientUploadURL,
            method: "PUT",
            headers: allocation.transientUploadHeaders
        )
        if result.statusCode == 412 {
            throw ProfessionalProjectSyncError.signedUploadPreconditionFailed
        }
        guard (200..<300).contains(result.statusCode) else {
            throw ProfessionalProjectSyncError.invalidResponse
        }
    }

    func complete(uploadID: String) async throws -> ProfessionalProjectSyncUploadStatus {
        guard ProfessionalProjectSyncJournalRecord.isHostedUploadID(uploadID) else {
            throw ProfessionalProjectSyncError.invalidResponse
        }
        return try await json(path: "/projects/uploads/complete", body: ["uploadID": uploadID], response: UploadStatusWire.self).model
    }

    func uploadStatus(uploadID: String) async throws -> ProfessionalProjectSyncUploadStatus {
        guard ProfessionalProjectSyncJournalRecord.isHostedUploadID(uploadID) else {
            throw ProfessionalProjectSyncError.invalidResponse
        }
        return try await json(path: "/projects/uploads/status", body: ["uploadID": uploadID], response: UploadStatusWire.self).model
    }

    func allocateRecovery(projectID: String, revisionID: String?) async throws -> ProfessionalProjectSyncRecoveryDownload {
        guard ProfessionalProjectSyncJournalRecord.isHostedProjectID(projectID),
              revisionID == nil || ProfessionalProjectSyncJournalRecord.isHostedRevisionID(revisionID!)
        else { throw ProfessionalProjectSyncError.invalidResponse }
        var body = ["projectID": projectID]
        if let revisionID { body["revisionID"] = revisionID }
        let recovery = try await json(path: "/projects/recovery/allocate", body: body, response: RecoveryWire.self).model
        try recovery.recovery.validate()
        guard recovery.recovery.projectID == projectID,
              revisionID == nil || recovery.recovery.revisionID == revisionID
        else { throw ProfessionalProjectSyncError.invalidResponse }
        try validateWorkingArchive(
            sha256: recovery.recovery.archiveSHA256,
            byteCount: recovery.recovery.archiveByteCount
        )
        guard Self.isSecureHTTPSURL(recovery.transientDownloadURL) else {
            throw ProfessionalProjectSyncError.insecureURL
        }
        return recovery
    }

    func download(_ recovery: ProfessionalProjectSyncRecoveryDownload, to destinationURL: URL) async throws {
        try recovery.recovery.validate()
        guard Self.isSecureHTTPSURL(recovery.transientDownloadURL) else {
            throw ProfessionalProjectSyncError.insecureURL
        }
        let result = try await fileTransfer.downloadFile(from: recovery.transientDownloadURL, to: destinationURL)
        guard (200..<300).contains(result.statusCode) else { throw ProfessionalProjectSyncError.invalidResponse }
    }

    func acquireLease(_ request: ProfessionalProjectSyncLeaseRequest) async throws -> ProfessionalProjectSyncLease {
        try await json(path: "/projects/edit-lease/acquire", body: request, response: LeaseWire.self).model
    }

    func renewLease(projectID: String, leaseToken: String, hostedGlobalVersion: Int, hostedWorkspaceVersion: Int) async throws -> ProfessionalProjectSyncLease {
        try await json(path: "/projects/edit-lease/renew", body: ProfessionalProjectSyncLeaseTokenRequest(
            projectID: projectID, leaseToken: leaseToken,
            hostedGlobalVersion: hostedGlobalVersion, hostedWorkspaceVersion: hostedWorkspaceVersion
        ), response: LeaseWire.self).model
    }

    func releaseLease(projectID: String, leaseToken: String, hostedGlobalVersion: Int, hostedWorkspaceVersion: Int) async throws -> ProfessionalProjectSyncLease {
        try await json(path: "/projects/edit-lease/release", body: ProfessionalProjectSyncLeaseTokenRequest(
            projectID: projectID, leaseToken: leaseToken,
            hostedGlobalVersion: hostedGlobalVersion, hostedWorkspaceVersion: hostedWorkspaceVersion
        ), response: LeaseWire.self).model
    }

    func configureRawArchive(projectID: String, reviewSHA256: String, hostedGlobalVersion: Int, hostedWorkspaceVersion: Int) async throws -> ProfessionalProjectSyncRawConfiguration {
        guard ProfessionalProjectSyncJournalRecord.isHostedProjectID(projectID),
              ProfessionalProjectSyncJournalRecord.isSHA256(reviewSHA256)
        else { throw ProfessionalProjectSyncError.invalidResponse }
        let configuration = try await json(
            path: "/projects/raw-archive/configure",
            body: ProfessionalProjectSyncRawConfigurationRequest(
                projectID: projectID,
                reviewSHA256: reviewSHA256,
                hostedGlobalVersion: hostedGlobalVersion,
                hostedWorkspaceVersion: hostedWorkspaceVersion
            ),
            response: RawConfigurationWire.self
        ).model
        let epoch = Date(timeIntervalSince1970: 0)
        guard configuration.projectID == projectID,
              configuration.rawArchiveEnabled,
              configuration.reviewedAt >= epoch,
              configuration.reviewedAt <= Date()
        else { throw ProfessionalProjectSyncError.invalidResponse }
        return configuration
    }

    func allocateRawArchive(_ request: ProfessionalProjectSyncRawArchiveRequest) async throws -> ProfessionalProjectSyncUploadAllocation {
        try validateRawArchive(sha256: request.archiveSHA256, byteCount: request.archiveByteCount)
        guard ProfessionalProjectSyncJournalRecord.isHostedProjectID(request.projectID),
              ProfessionalProjectSyncJournalRecord.isHostedRevisionID(request.revisionID),
              ProfessionalProjectSyncJournalRecord.isSHA256(request.rawManifestSHA256),
              ProfessionalProjectSyncJournalRecord.isSHA256(request.reviewSHA256)
        else { throw ProfessionalProjectSyncError.invalidResponse }
        let allocation = try await json(path: "/projects/raw-archive/allocate", body: request, response: AllocationWire.self).model
        try validate(
            allocation: allocation,
            projectID: request.projectID,
            candidateRevisionID: request.revisionID,
            archiveSHA256: request.archiveSHA256,
            archiveByteCount: request.archiveByteCount,
            maximumByteCount: ProfessionalProjectSyncPreview.maximumHostedWorkingArchiveBytes,
            permitsRawAttachment: true
        )
        return allocation
    }

    private func json<Request: Encodable, Response: Decodable>(
        path: String,
        body: Request,
        response: Response.Type
    ) async throws -> Response {
        let body = try encoder.encode(body)
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw ProfessionalProjectSyncError.invalidResponse
        }
        let authorization = authorization()
        guard !authorization.isEmpty else { throw ProfessionalProjectSyncError.unavailable }
        let result = try await http.send(ProfessionalHTTPRequest(
            url: url,
            method: "POST",
            headers: ["Authorization": authorization, "Content-Type": "application/json"],
            body: body
        ))
        guard (200..<300).contains(result.statusCode) else { throw ProfessionalProjectSyncError.invalidResponse }
        do {
            return try decoder.decode(Response.self, from: result.data)
        } catch {
            throw ProfessionalProjectSyncError.invalidResponse
        }
    }

    private func validateWorkingArchive(sha256: String, byteCount: UInt64) throws {
        guard ProfessionalProjectSyncJournalRecord.isSHA256(sha256),
              byteCount > 0,
              byteCount <= ProfessionalProjectSyncPreview.maximumHostedWorkingArchiveBytes
        else { throw ProfessionalProjectSyncError.invalidResponse }
    }

    /// The hosted operational ceiling applies to every professional allocation
    /// tier. The explicit raw review remains exact: an over-limit source is
    /// rejected whole, never truncated or silently reclassified.
    private func validateRawArchive(sha256: String, byteCount: UInt64) throws {
        guard ProfessionalProjectSyncJournalRecord.isSHA256(sha256),
              byteCount > 0,
              byteCount <= ProfessionalProjectSyncPreview.maximumHostedWorkingArchiveBytes
        else { throw ProfessionalProjectSyncError.invalidResponse }
    }

    private func validate(
        allocation: ProfessionalProjectSyncUploadAllocation,
        projectID: String?,
        candidateRevisionID: String?,
        archiveSHA256: String,
        archiveByteCount: UInt64,
        maximumByteCount: UInt64,
        permitsRawAttachment: Bool
    ) throws {
        guard ProfessionalProjectSyncJournalRecord.isHostedProjectID(allocation.projectID),
              ProfessionalProjectSyncJournalRecord.isHostedUploadID(allocation.uploadID),
              allocation.candidateRevisionID.map(ProfessionalProjectSyncJournalRecord.isHostedRevisionID) == true,
              allocation.currentHostedHeadRevisionID.map(ProfessionalProjectSyncJournalRecord.isHostedRevisionID) ?? true,
              candidateRevisionID == nil || allocation.candidateRevisionID == candidateRevisionID,
              allocation.archiveSHA256 == archiveSHA256,
              allocation.archiveByteCount == archiveByteCount,
              allocation.archiveByteCount > 0,
              allocation.archiveByteCount <= maximumByteCount,
              projectID == nil || allocation.projectID == projectID,
              (permitsRawAttachment || allocation.status != .attached),
              (!permitsRawAttachment || (allocation.status != .canonical && allocation.status != .stale)),
              allocation.status != .allocated || (
                  allocation.allocationExpiresAt > Date()
                      && allocation.allocationExpiresAt.timeIntervalSinceNow <= 305
                      && Self.isSecureHTTPSURL(allocation.transientUploadURL)
                      && !allocation.transientUploadHeaders.keys.contains(where: {
                          $0.caseInsensitiveCompare("Authorization") == .orderedSame
                      })
              )
        else { throw ProfessionalProjectSyncError.invalidResponse }
    }

    private static func isSecureHTTPSURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host != nil
            && url.user == nil
            && url.password == nil
    }
}

private struct AllocationWire: Decodable {
    let status: ProfessionalProjectSyncStatus
    let projectID: String
    let uploadID: String
    let candidateRevisionID: String?
    let currentHostedHeadRevisionID: String?
    let archiveSHA256: String
    let archiveByteCount: UInt64
    let allocationExpiresAt: Date
    let uploadURL: URL
    let uploadHeaders: [String: String]

    var model: ProfessionalProjectSyncUploadAllocation {
        ProfessionalProjectSyncUploadAllocation(
            status: status, projectID: projectID, uploadID: uploadID,
            candidateRevisionID: candidateRevisionID,
            currentHostedHeadRevisionID: currentHostedHeadRevisionID,
            archiveSHA256: archiveSHA256, archiveByteCount: archiveByteCount,
            allocationExpiresAt: allocationExpiresAt,
            transientUploadURL: uploadURL, transientUploadHeaders: uploadHeaders
        )
    }
}

private struct UploadStatusWire: Decodable {
    let status: ProfessionalProjectSyncStatus
    let projectID: String
    let uploadID: String
    let candidateRevisionID: String?
    let currentHostedHeadRevisionID: String?
    let archiveSHA256: String
    let archiveByteCount: UInt64
    let allocationExpiresAt: Date

    var model: ProfessionalProjectSyncUploadStatus {
        .init(status: status, projectID: projectID, uploadID: uploadID,
              candidateRevisionID: candidateRevisionID,
              currentHostedHeadRevisionID: currentHostedHeadRevisionID,
              archiveSHA256: archiveSHA256, archiveByteCount: archiveByteCount,
              allocationExpiresAt: allocationExpiresAt)
    }
}

private struct RecoveryWire: Decodable {
    let projectID: String
    let revisionID: String
    let branchState: ProfessionalProjectSyncBranchState
    let workingSetManifestSHA256: String
    let archiveSHA256: String
    let archiveByteCount: UInt64
    let downloadURL: URL

    var model: ProfessionalProjectSyncRecoveryDownload {
        .init(recovery: .init(projectID: projectID, revisionID: revisionID,
                              branchState: branchState,
                              workingSetManifestSHA256: workingSetManifestSHA256,
                              archiveSHA256: archiveSHA256,
                              archiveByteCount: archiveByteCount),
              transientDownloadURL: downloadURL)
    }
}

private struct LeaseWire: Decodable {
    let status: String
    let expiresAt: Date?

    var model: ProfessionalProjectSyncLease {
        .init(status: status, expiresAt: expiresAt, plaintextToken: nil)
    }
}

private struct RawConfigurationWire: Decodable {
    let projectID: String
    let rawArchiveEnabled: Bool
    let reviewedAt: Date

    var model: ProfessionalProjectSyncRawConfiguration {
        .init(
            projectID: projectID,
            rawArchiveEnabled: rawArchiveEnabled,
            reviewedAt: reviewedAt
        )
    }
}
