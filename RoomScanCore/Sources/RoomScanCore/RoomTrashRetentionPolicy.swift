import Foundation

/// Local trash retention is an inclusive, fixed-duration boundary, independent
/// of time zones and calendar daylight-saving changes.
public struct RoomTrashRetentionPolicy: Sendable {
    public static let retention: TimeInterval = 30 * 24 * 60 * 60

    public init() {}

    public func purgeDate(trashedAt: Date) -> Date {
        trashedAt.addingTimeInterval(Self.retention)
    }

    public func expiredProjectIDs(summaries: [RoomProjectSummary], now: Date) -> [String] {
        summaries.compactMap { summary in
            guard let trashedAt = summary.trashedAt, purgeDate(trashedAt: trashedAt) <= now else {
                return nil
            }
            return summary.projectID
        }.sorted()
    }
}
