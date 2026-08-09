import Foundation

public enum RoomDraftEvent: String, Codable, Sendable {
    case save
    case discard
}

public enum RoomDraftStatus: String, Codable, Sendable {
    case editing
    case saved
    case discarded
}

public struct RoomDraftState: Codable, Sendable, Equatable {
    public let status: RoomDraftStatus

    public init(status: RoomDraftStatus = .editing) {
        self.status = status
    }

    public func applying(_ event: RoomDraftEvent) -> RoomDraftState {
        guard status == .editing else {
            return self
        }

        switch event {
        case .save:
            return RoomDraftState(status: .saved)
        case .discard:
            return RoomDraftState(status: .discarded)
        }
    }
}
public struct RoomRevision: Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let parentRevisionID: String?
    public let createdAt: String

    public init(id: String, parentRevisionID: String?, createdAt: String) {
        self.id = id
        self.parentRevisionID = parentRevisionID
        self.createdAt = createdAt
    }
}

public struct RoomProjectSnapshot: Codable, Sendable, Equatable {
    public let projectID: String
    public let headRevisionID: String
    public let revisions: [RoomRevision]

    public init(projectID: String, headRevisionID: String, revisions: [RoomRevision]) {
        self.projectID = projectID
        self.headRevisionID = headRevisionID
        self.revisions = revisions
    }
}

public enum RevisionLineageError: Error, Sendable, Equatable {
    case emptyRevisionID
    case duplicateRevisionID(String)
    case parentMustMatchHead(expected: String, actual: String?)
}

public enum RevisionLineageGuard {
    public static func appending(
        _ candidate: RoomRevision,
        to project: RoomProjectSnapshot
    ) throws -> RoomProjectSnapshot {
        guard !candidate.id.isEmpty else {
            throw RevisionLineageError.emptyRevisionID
        }

        guard !project.revisions.contains(where: { $0.id == candidate.id }) else {
            throw RevisionLineageError.duplicateRevisionID(candidate.id)
        }

        guard candidate.parentRevisionID == project.headRevisionID else {
            throw RevisionLineageError.parentMustMatchHead(
                expected: project.headRevisionID,
                actual: candidate.parentRevisionID
            )
        }

        return RoomProjectSnapshot(
            projectID: project.projectID,
            headRevisionID: candidate.id,
            revisions: project.revisions + [candidate]
        )
    }
}

public enum SemanticElementCategory: String, Codable, Sendable {
    case structural
    case movable
    case manual
}

public struct SemanticElement: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let category: SemanticElementCategory
    public let kind: String
    public let label: String
    public let dimensionsMeters: Dimensions

    public init(
        id: String,
        category: SemanticElementCategory,
        kind: String,
        label: String,
        dimensionsMeters: Dimensions
    ) {
        self.id = id
        self.category = category
        self.kind = kind
        self.label = label
        self.dimensionsMeters = dimensionsMeters
    }
}

public struct Dimensions: Codable, Sendable, Equatable {
    public let width: Double
    public let height: Double
    public let depth: Double

    public init(width: Double, height: Double, depth: Double) {
        self.width = width
        self.height = height
        self.depth = depth
    }
}

public struct SemanticRoomSnapshot: Codable, Sendable, Equatable {
    public let projectID: String
    public let revisionID: String
    public let accuracyDisclaimer: String
    public let elements: [SemanticElement]

    public init(
        projectID: String,
        revisionID: String,
        accuracyDisclaimer: String,
        elements: [SemanticElement]
    ) {
        self.projectID = projectID
        self.revisionID = revisionID
        self.accuracyDisclaimer = accuracyDisclaimer
        self.elements = elements
    }
}
