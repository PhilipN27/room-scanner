import Foundation
import RoomScanCore

/// The only failure vocabulary exposed by the native publication identity
/// bridge. It deliberately carries no local package path, hosted token, or
/// provider error detail.
enum RoomPublicationSourceIdentityError: LocalizedError, Equatable {
    case unavailable
    case localHeadDiverged
    case journalNotAcknowledged
    case invalidHostedIdentity

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Professional publication identity is unavailable. Local rooms and private recovery remain available."
        case .localHeadDiverged:
            "The local room head changed after hosted synchronization. Synchronize the current revision before publishing."
        case .journalNotAcknowledged:
            "This room revision has not been acknowledged as the current hosted professional head."
        case .invalidHostedIdentity:
            "The hosted publication identity is invalid."
        }
    }
}

/// A typed bridge between one fresh Core source binding and its acknowledged
/// hosted professional identity. It is never encoded into a public portal
/// presentation; the transport flattens only the frozen service DTO fields.
struct RoomPublicationHostedSourceIdentity: Sendable, Equatable {
    let projectPublicID: String
    let revisionPublicID: String
    let sourceRevision: RoomRedesignSourceRevision

    func validate(expectedLocalProjectID: String) throws {
        try sourceRevision.validate()
        guard sourceRevision.projectID == expectedLocalProjectID,
              ProfessionalProjectSyncJournalRecord.isHostedProjectID(projectPublicID),
              ProfessionalProjectSyncJournalRecord.isHostedRevisionID(revisionPublicID)
        else { throw RoomPublicationSourceIdentityError.invalidHostedIdentity }
    }
}

/// The exact ordered source binding accepted by the Slice 6 allocation DTO.
/// Public room keys are fresh ordinals and are never derived from private IDs.
struct RoomPublicationHostedSourceBinding: Sendable, Equatable {
    let publicRoomKey: String
    let projectPublicID: String
    let revisionPublicID: String
    let sourceRevision: RoomRedesignSourceRevision

    init(
        publicRoomKey: String,
        projectPublicID: String,
        revisionPublicID: String,
        sourceRevision: RoomRedesignSourceRevision
    ) {
        self.publicRoomKey = publicRoomKey
        self.projectPublicID = projectPublicID
        self.revisionPublicID = revisionPublicID
        self.sourceRevision = sourceRevision
    }

    init(
        publicRoomKey: String,
        identity: RoomPublicationHostedSourceIdentity
    ) {
        self.init(
            publicRoomKey: publicRoomKey,
            projectPublicID: identity.projectPublicID,
            revisionPublicID: identity.revisionPublicID,
            sourceRevision: identity.sourceRevision
        )
    }

    func validate() throws {
        guard ProfessionalProjectSyncJournalRecord.isSafeIdentifier(publicRoomKey),
              ProfessionalProjectSyncJournalRecord.isHostedProjectID(projectPublicID),
              ProfessionalProjectSyncJournalRecord.isHostedRevisionID(revisionPublicID)
        else { throw RoomPublicationSourceIdentityError.invalidHostedIdentity }
        try sourceRevision.validate()
    }
}

/// Read-only authority over the frozen Slice 5 sync journal. Publication
/// allocation/link recovery is deliberately stored in `PublicationOperationJournal`
/// instead, so this resolver cannot mutate Slice 5 bytes or project truth.
@MainActor
protocol PublicationSourceIdentityResolving: AnyObject {
    func resolve(
        localProjectID: String,
        expectedSourceRevision: RoomRedesignSourceRevision
    ) async throws -> RoomPublicationHostedSourceIdentity
}

/// Production implementation backed by the same canonical journal that Slice
/// 5 uses for immutable professional sync/recovery. The current local source
/// is fetched again just before identity resolution so a private local draft
/// cannot be labelled with an older acknowledged hosted `rev_` value.
@MainActor
final class PublicationSourceIdentityResolver: PublicationSourceIdentityResolving {
    typealias CurrentSource = @MainActor (String) async throws -> RoomRedesignSourceRevision

    private let journal: ProfessionalProjectSyncJournal
    private let currentSource: CurrentSource

    init(
        journal: ProfessionalProjectSyncJournal,
        currentSource: @escaping CurrentSource
    ) {
        self.journal = journal
        self.currentSource = currentSource
    }

    func resolve(
        localProjectID: String,
        expectedSourceRevision: RoomRedesignSourceRevision
    ) async throws -> RoomPublicationHostedSourceIdentity {
        try expectedSourceRevision.validate()
        guard expectedSourceRevision.projectID == localProjectID else {
            throw RoomPublicationSourceIdentityError.localHeadDiverged
        }
        let current = try await currentSource(localProjectID)
        guard current == expectedSourceRevision else {
            throw RoomPublicationSourceIdentityError.localHeadDiverged
        }
        guard let record = try journal.load(localProjectID: localProjectID),
              record.status == .canonical,
              record.localDraftHeadRevisionID == nil,
              record.acknowledgedLocalHeadRevisionID == expectedSourceRevision.revisionID,
              let hostedProjectID = record.hostedProjectID,
              let hostedRevisionID = record.acknowledgedHostedHeadRevisionID,
              record.canonicalRevisionID == hostedRevisionID,
              record.currentHostedHeadRevisionID == hostedRevisionID
        else { throw RoomPublicationSourceIdentityError.journalNotAcknowledged }

        let identity = RoomPublicationHostedSourceIdentity(
            projectPublicID: hostedProjectID,
            revisionPublicID: hostedRevisionID,
            sourceRevision: expectedSourceRevision
        )
        try identity.validate(expectedLocalProjectID: localProjectID)
        return identity
    }

}
