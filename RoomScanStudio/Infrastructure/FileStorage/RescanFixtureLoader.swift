import Foundation
import RoomScanCore

enum RoomRescanUnavailableReason: String, Sendable, Equatable {
    case registrationEvidenceMissing
    case fixtureDoesNotMatchCurrentHead
    case fixtureInvalid

    var message: String {
        switch self {
        case .registrationEvidenceMissing:
            return "Live master rescan acceptance is unavailable: this project has no proven continuous session or recorded ARWorldMap relocalization evidence."
        case .fixtureDoesNotMatchCurrentHead:
            return "The deterministic rescan fixture applies only to its original fixture head revision."
        case .fixtureInvalid:
            return "The bundled deterministic rescan fixture could not be validated."
        }
    }
}

enum RoomRescanAvailability: Sendable, Equatable {
    case available(RoomFixtureRescanProposal)
    case unavailable(RoomRescanUnavailableReason)
}

/// Production is deliberately hard-unavailable in V1-A. This dependency has
/// no camera, ARSession, or RoomPlan work and cannot manufacture registration.
@MainActor
protocol RoomRescanProviding: AnyObject {
    func availability(for package: RoomProjectPackage) async -> RoomRescanAvailability
}

@MainActor
final class UnavailableRoomRescanProvider: RoomRescanProviding {
    func availability(for package: RoomProjectPackage) async -> RoomRescanAvailability {
        .unavailable(.registrationEvidenceMissing)
    }
}

@MainActor
final class DeterministicFixtureRoomRescanProvider: RoomRescanProviding {
    private let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func availability(for package: RoomProjectPackage) async -> RoomRescanAvailability {
        do {
            return .available(try RescanFixtureLoader.load(bundle: bundle).proposal(for: package))
        } catch let error as RescanFixtureLoaderError {
            switch error {
            case .headDoesNotMatchFixture:
                return .unavailable(.fixtureDoesNotMatchCurrentHead)
            case .missingResource, .inconsistentFixture, .proposalRejected:
                return .unavailable(.fixtureInvalid)
            }
        } catch {
            return .unavailable(.fixtureInvalid)
        }
    }
}

private struct RescanFixtureDocument: Codable, Sendable, Equatable {
    let fixtureID: String
    let simulated: Bool
    let sourceFixtureProjectID: String
    let sourceFixtureBaseRevisionID: String
    let registrationProof: RoomDeterministicRescanRegistrationProof
    let candidateSnapshot: RoomSemanticSnapshot
    let matches: [RoomRescanElementMatch]
}

enum RescanFixtureLoaderError: Error, Equatable {
    case missingResource
    case inconsistentFixture
    case headDoesNotMatchFixture
    case proposalRejected
}

/// Validates the bundled sidecar before retargeting only app-owned project IDs
/// for a deterministic MockRoom import. The source fixture's own IDs remain
/// fixed in JSON; the store-generated project ID is never persisted into it.
struct RescanFixtureLoader {
    static func load(bundle: Bundle = .main) throws -> RescanFixtureLoader {
        guard let url = bundle.url(forResource: "rescan-fixture-v1", withExtension: "json") else {
            throw RescanFixtureLoaderError.missingResource
        }
        let data = try Data(contentsOf: url)
        let document: RescanFixtureDocument
        do {
            document = try RoomJSONCoding.makeDecoder().decode(RescanFixtureDocument.self, from: data)
        } catch {
            throw RescanFixtureLoaderError.inconsistentFixture
        }
        try validate(document)
        return RescanFixtureLoader(document: document)
    }

    private let document: RescanFixtureDocument

    private init(document: RescanFixtureDocument) {
        self.document = document
    }

    func proposal(for package: RoomProjectPackage) throws -> RoomFixtureRescanProposal {
        guard
            package.manifest.headRevisionID == document.sourceFixtureBaseRevisionID,
            let base = package.revisions.last,
            base.manifest.revisionID == document.sourceFixtureBaseRevisionID,
            base.payload.semanticSnapshot.projectID == package.manifest.projectID,
            Set(base.payload.semanticSnapshot.structuralElements.map(\.id))
                == Set(document.matches.filter { $0.baseLayer == .structural }.map(\.baseElementID)),
            Set(base.payload.semanticSnapshot.objectElements.map(\.id))
                == Set(document.matches.filter { $0.baseLayer == .object }.map(\.baseElementID))
        else {
            throw RescanFixtureLoaderError.headDoesNotMatchFixture
        }

        var retargetedCandidate = document.candidateSnapshot
        retargetedCandidate.projectID = package.manifest.projectID
        let retargetedProof = RoomDeterministicRescanRegistrationProof(
            fixtureID: document.registrationProof.fixtureID,
            projectID: package.manifest.projectID,
            baseRevisionID: package.manifest.headRevisionID,
            coordinateFrameID: document.registrationProof.coordinateFrameID,
            proofToken: document.registrationProof.proofToken
        )
        do {
            return try RoomRescanEngine.makeFixtureProposal(
                basePayload: base.payload,
                expectedHeadRevisionID: package.manifest.headRevisionID,
                registrationProof: retargetedProof,
                candidateSnapshot: retargetedCandidate,
                matches: document.matches
            )
        } catch {
            throw RescanFixtureLoaderError.proposalRejected
        }
    }

    private static func validate(_ document: RescanFixtureDocument) throws {
        guard
            document.simulated,
            document.fixtureID == RoomDeterministicRescanRegistrationProof.fixtureV1ID,
            document.sourceFixtureProjectID == "mock-room-v1",
            document.sourceFixtureBaseRevisionID == "revision-001",
            document.registrationProof.fixtureID == document.fixtureID,
            document.registrationProof.projectID == document.sourceFixtureProjectID,
            document.registrationProof.baseRevisionID == document.sourceFixtureBaseRevisionID,
            document.registrationProof.coordinateFrameID == RoomDeterministicRescanRegistrationProof.fixtureV1FrameID,
            document.registrationProof.proofToken == RoomDeterministicRescanRegistrationProof.fixtureV1ProofToken,
            document.candidateSnapshot.projectID == document.sourceFixtureProjectID,
            !document.matches.isEmpty
        else {
            throw RescanFixtureLoaderError.inconsistentFixture
        }
    }
}
