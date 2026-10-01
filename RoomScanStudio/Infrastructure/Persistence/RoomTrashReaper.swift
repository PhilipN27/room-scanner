import Foundation
import RoomScanCore

struct RoomTrashReaperReport: Equatable {
    var purgeReports: [RoomProjectPurgeReport] = []
    var listingErrorMessage: String?

    var purgedCount: Int { purgeReports.filter { $0.package == .removed }.count }
    var skippedCount: Int { purgeReports.filter { $0.package.skipped }.count }
    var failedCount: Int { purgeReports.filter(\.hasFailures).count }
}

@MainActor
protocol RoomTrashReaping {
    func purgeExpiredTrash() async -> RoomTrashReaperReport
}

/// Foreground local retention only. Automatic purges may journal an injected
/// deletion request, but never perform remote work or schedule background work.
@MainActor
final class RoomTrashReaper: RoomTrashReaping {
    private let store: LocalRoomProjectStore
    private let purgeCoordinator: any RoomProjectPurging
    let clock: any RoomProjectClock
    private let retentionPolicy: RoomTrashRetentionPolicy
    private var inFlight: Task<RoomTrashReaperReport, Never>?

    init(
        store: LocalRoomProjectStore,
        purgeCoordinator: any RoomProjectPurging,
        clock: any RoomProjectClock = SystemRoomProjectClock(),
        retentionPolicy: RoomTrashRetentionPolicy = .init()
    ) {
        self.store = store
        self.purgeCoordinator = purgeCoordinator
        self.clock = clock
        self.retentionPolicy = retentionPolicy
    }

    func purgeExpiredTrash() async -> RoomTrashReaperReport {
        // Home and scene activation can arrive together. Share their sweep
        // rather than enqueue duplicate durable requests for the same package.
        if let inFlight { return await inFlight.value }
        let task = Task(priority: .utility) { await self.reap() }
        inFlight = task
        let report = await task.value
        inFlight = nil
        return report
    }

    private func reap() async -> RoomTrashReaperReport {
        do {
            let listing = try await store.listProjectListing(includeArchived: true, includeTrashed: true)
            let expiredIDs = retentionPolicy.expiredProjectIDs(summaries: listing.summaries, now: clock.now())
            var reports: [RoomProjectPurgeReport] = []
            for projectID in expiredIDs {
                reports.append(await purgeCoordinator.purge(projectID: projectID, mode: .automatic))
            }
            return .init(purgeReports: reports)
        } catch {
            return .init(listingErrorMessage: "Trash could not be checked. Existing room packages remain available.")
        }
    }
}
