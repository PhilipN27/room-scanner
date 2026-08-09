import Foundation
import SwiftData
import RoomScanCore

/// Pure policy seam for tests and review. The factory is intentionally limited
/// to local persistence; Apple configuration values are applied in one switch.
enum RoomProjectPersistencePolicy: Equatable {
    case localOnly
}

@Model
final class RoomProjectIndexRecord {
    @Attribute(.unique) var projectID: String
    var customName: String
    var captureDate: Date
    var lastRevisedDate: Date
    var manualLocation: String
    var tagsSearchText: String
    var thumbnailRelativePath: String?
    var archived: Bool
    var headRevisionID: String

    init(summary: RoomProjectSummary) {
        projectID = summary.projectID
        customName = summary.customName
        captureDate = summary.captureDate
        lastRevisedDate = summary.lastRevisedDate
        manualLocation = summary.manualLocation
        tagsSearchText = summary.tags.joined(separator: " ")
        thumbnailRelativePath = summary.thumbnailRelativePath?.value
        archived = summary.archived
        headRevisionID = summary.headRevisionID
    }

    func apply(_ summary: RoomProjectSummary) {
        customName = summary.customName
        captureDate = summary.captureDate
        lastRevisedDate = summary.lastRevisedDate
        manualLocation = summary.manualLocation
        tagsSearchText = summary.tags.joined(separator: " ")
        thumbnailRelativePath = summary.thumbnailRelativePath?.value
        archived = summary.archived
        headRevisionID = summary.headRevisionID
    }
}

enum RoomProjectIndexFactory {
    static let persistencePolicy: RoomProjectPersistencePolicy = .localOnly

    static func makeContainer(
        isStoredInMemoryOnly: Bool = false
    ) throws -> ModelContainer {
        let schema = Schema([RoomProjectIndexRecord.self])
        let configuration = makeConfiguration(
            schema: schema,
            isStoredInMemoryOnly: isStoredInMemoryOnly,
            policy: persistencePolicy
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }

    private static func makeConfiguration(
        schema: Schema,
        isStoredInMemoryOnly: Bool,
        policy: RoomProjectPersistencePolicy
    ) -> ModelConfiguration {
        switch policy {
        case .localOnly:
            return ModelConfiguration(
                "RoomScanStudioIndex",
                schema: schema,
                isStoredInMemoryOnly: isStoredInMemoryOnly,
                allowsSave: true,
                groupContainer: .none,
                cloudKitDatabase: .none
            )
        }
    }
}

@MainActor
enum RoomProjectIndexRebuilder {
    static func rebuild(
        listing: RoomProjectListing,
        in context: ModelContext
    ) throws {
        let existing = try context.fetch(FetchDescriptor<RoomProjectIndexRecord>())
        var recordsByProjectID: [String: RoomProjectIndexRecord] = [:]
        for record in existing {
            recordsByProjectID[record.projectID] = record
        }
        let authoritativeIDs = Set(listing.summaries.map(\.projectID))

        for summary in listing.summaries {
            if let record = recordsByProjectID.removeValue(forKey: summary.projectID) {
                record.apply(summary)
            } else {
                context.insert(RoomProjectIndexRecord(summary: summary))
            }
        }

        for staleRecord in recordsByProjectID.values where !authoritativeIDs.contains(staleRecord.projectID) {
            context.delete(staleRecord)
        }
        try context.save()
    }
}
