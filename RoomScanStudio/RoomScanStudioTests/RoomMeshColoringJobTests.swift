import RoomScanCore
import XCTest
@testable import RoomScanStudio

@MainActor
final class RoomMeshColoringJobTests: XCTestCase {
    func testCapabilityResolverUsesContinuedProcessingOnlyForAdmittedIOS26Request() {
        XCTAssertEqual(
            RoomMeshColoringCapability.resolve(
                apiAvailable: false,
                registration: .registered,
                submission: .accepted
            ),
            .foregroundOnly
        )
        XCTAssertEqual(
            RoomMeshColoringCapability.resolve(
                apiAvailable: true,
                registration: .failed,
                submission: .accepted
            ),
            .foregroundOnly
        )
        XCTAssertEqual(
            RoomMeshColoringCapability.resolve(
                apiAvailable: true,
                registration: .registered,
                submission: .rejected
            ),
            .foregroundOnly
        )
        XCTAssertEqual(
            RoomMeshColoringCapability.resolve(
                apiAvailable: true,
                registration: .registered,
                submission: .accepted
            ),
            .continuedBackground
        )
        XCTAssertEqual(
            RoomMeshColoringCapability.resolve(
                apiAvailable: true,
                registration: .registered,
                submission: .queued
            ),
            .continuedBackground
        )
    }

    func testBackgroundDeliveryIsRecognizedWhileRequestIsPendingOrTaskIsActive() {
        XCTAssertTrue(RoomMeshBackgroundDelivery.isDeliveredOrPending(
            requestIsPending: true,
            taskIsActive: false
        ))
        XCTAssertTrue(RoomMeshBackgroundDelivery.isDeliveredOrPending(
            requestIsPending: false,
            taskIsActive: true
        ))
        XCTAssertFalse(RoomMeshBackgroundDelivery.isDeliveredOrPending(
            requestIsPending: false,
            taskIsActive: false
        ))
    }

    func testHalfwayMilestoneIsConsumedOnceAndOnlySchedulesInBackground() {
        var milestones = RoomMeshColoringMilestones()
        XCTAssertNil(milestones.acceptProgress(previousFraction: 0.49, fraction: 0.50, isAppActive: true))
        XCTAssertTrue(milestones.halfwayHandled)
        XCTAssertNil(milestones.acceptProgress(previousFraction: 0.50, fraction: 0.80, isAppActive: false))

        var backgroundMilestones = RoomMeshColoringMilestones()
        XCTAssertEqual(
            backgroundMilestones.acceptProgress(previousFraction: 0.49, fraction: 0.50, isAppActive: false),
            .halfway
        )
        XCTAssertNil(backgroundMilestones.acceptProgress(previousFraction: 0.20, fraction: 0.90, isAppActive: false))
    }

    func testTerminalMilestonesScheduleOnceOnlyInBackground() {
        var milestones = RoomMeshColoringMilestones()
        XCTAssertEqual(milestones.complete(isAppActive: false), .complete)
        XCTAssertNil(milestones.complete(isAppActive: false))
        XCTAssertEqual(milestones.interrupt(isAppActive: false), .interrupted)
        XCTAssertNil(milestones.interrupt(isAppActive: false))

        var foreground = RoomMeshColoringMilestones()
        XCTAssertNil(foreground.complete(isAppActive: true))
        XCTAssertNil(foreground.interrupt(isAppActive: true))
        XCTAssertTrue(foreground.completionHandled)
        XCTAssertTrue(foreground.failureHandled)
    }

    func testGenerationGateRejectsStaleAndNonIncreasingProgress() {
        var gate = RoomMeshColoringGenerationGate(generation: UUID(), lastSequence: 3)
        XCTAssertFalse(gate.accept(sequence: 4, generation: UUID()))
        XCTAssertFalse(gate.accept(sequence: 3, generation: gate.generation))
        XCTAssertTrue(gate.accept(sequence: 4, generation: gate.generation))
        XCTAssertEqual(gate.lastSequence, 4)
    }

    func testVersionedJobRecordRoundTripsAndRejectsCorruptOrFutureSchema() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mesh-job-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RoomMeshColoringJobRecordStore(
            fileURL: directory.appendingPathComponent("active-job.json")
        )
        let generation = UUID()
        let record = RoomMeshColoringJobRecord(
            projectID: "room-1",
            roomName: "Kitchen",
            generation: generation,
            mode: .continuedBackground,
            state: .running,
            progressSequence: 7,
            phase: .projectingColors,
            fraction: 0.42,
            updatedAt: Date(timeIntervalSince1970: 123),
            halfwayHandled: false,
            completionHandled: false,
            failureHandled: false,
            failureCategory: nil
        )
        try store.save(record)
        XCTAssertEqual(try store.load(), record)

        try Data("not-json".utf8).write(to: store.fileURL, options: .atomic)
        XCTAssertNil(try store.load())

        var future = record
        future.schemaVersion = RoomMeshColoringJobRecord.currentSchemaVersion + 1
        let data = try JSONEncoder().encode(future)
        try data.write(to: store.fileURL, options: .atomic)
        XCTAssertNil(try store.load())
    }

    func testRecoveryTreatsValidCacheAsAuthoritativeAndStaleWorkAsInterrupted() {
        let record = RoomMeshColoringJobRecord(
            projectID: "room-1",
            roomName: "Kitchen",
            generation: UUID(),
            mode: .continuedBackground,
            state: .running,
            progressSequence: 5,
            phase: .bakingAtlas,
            fraction: 0.8,
            updatedAt: Date(),
            halfwayHandled: true,
            completionHandled: false,
            failureHandled: false,
            failureCategory: nil
        )
        XCTAssertEqual(RoomMeshColoringRecovery.reconcile(record, hasValidCache: true)?.state, .cacheReady)
        XCTAssertEqual(RoomMeshColoringRecovery.reconcile(record, hasValidCache: false)?.state, .interrupted)

        var failed = record
        failed.state = .failed
        failed.failureCategory = .processingFailed
        XCTAssertEqual(RoomMeshColoringRecovery.reconcile(failed, hasValidCache: false), failed)
    }

    func testCoordinatorStartsOneWorkerAcrossAttachmentAndViewDetachment() async {
        let count = LockedCount()
        let gate = DispatchSemaphore(value: 0)
        let store = temporaryStore()
        let coordinator = RoomMeshColoringJobCoordinator(
            worker: { _, _ in
                count.increment()
                gate.wait()
                throw CancellationError()
            },
            recordStore: store
        )

        XCTAssertEqual(coordinator.start(projectID: "room-1"), .started)
        XCTAssertEqual(coordinator.start(projectID: "room-1"), .attached)
        XCTAssertEqual(
            coordinator.start(projectID: "room-2"),
            .conflict(activeProjectID: "room-1")
        )
        await waitUntil { count.value == 1 }
        coordinator.detach(projectID: "room-1")
        XCTAssertEqual(coordinator.state, .running)
        XCTAssertEqual(count.value, 1)

        coordinator.cancel()
        gate.signal()
        XCTAssertTrue(coordinator.isCancelled)
        XCTAssertEqual(coordinator.state, .interrupted)
        try? store.remove()
    }

    func testBackgroundCompletionOccursAfterCacheReadyAndNotifiesOnlyInBackground() async {
        let background = FakeBackgroundAdapter()
        let notifications = FakeNotificationAdapter()
        let store = temporaryStore()
        let emptyResult = Self.makeEmptyResult()
        let coordinator = RoomMeshColoringJobCoordinator(
            worker: { _, sink in
                sink?(RoomMeshColoringProgress(
                    sequence: 1,
                    phase: .projectingColors,
                    completedUnits: 10,
                    totalUnits: 10,
                    detail: "Projected"
                ))
                return emptyResult
            },
            background: background,
            notifications: notifications,
            recordStore: store,
            isAppActive: { false }
        )

        XCTAssertEqual(coordinator.start(projectID: "room-1", roomName: "Kitchen"), .started)
        XCTAssertEqual(coordinator.state, .queued)
        XCTAssertNil(coordinator.result)
        let generation = try! XCTUnwrap(coordinator.generation)
        background.launch(generation)
        await waitUntil { coordinator.state == .cacheReady }

        XCTAssertNotNil(coordinator.result)
        XCTAssertFalse(coordinator.rendererReady)
        XCTAssertEqual(coordinator.progress.fraction, 0.99, accuracy: 0.000_001)
        XCTAssertEqual(background.completions, [true])
        XCTAssertEqual(notifications.milestones, [.halfway, .complete])
        try? store.remove()
    }

    func testExpirationCancelsGenerationAndReportsInterruptionOnce() async {
        let background = FakeBackgroundAdapter()
        let notifications = FakeNotificationAdapter()
        let workerGate = DispatchSemaphore(value: 0)
        let store = temporaryStore()
        let coordinator = RoomMeshColoringJobCoordinator(
            worker: { _, _ in
                workerGate.wait()
                throw CancellationError()
            },
            background: background,
            notifications: notifications,
            recordStore: store,
            isAppActive: { false }
        )
        _ = coordinator.start(projectID: "room-1")
        let generation = try! XCTUnwrap(coordinator.generation)
        background.launch(generation)
        background.expire(generation)
        background.expire(generation)
        workerGate.signal()

        XCTAssertEqual(coordinator.state, .interrupted)
        XCTAssertEqual(background.completions, [false])
        XCTAssertEqual(notifications.milestones, [.interrupted])
        try? store.remove()
    }

    func testCachePublicationWarningNeverClaimsBackgroundSuccess() async {
        let background = FakeBackgroundAdapter()
        let notifications = FakeNotificationAdapter()
        let store = temporaryStore()
        let result = Self.makeEmptyResult(warnings: [.cacheNotSaved])
        let coordinator = RoomMeshColoringJobCoordinator(
            worker: { _, _ in result },
            background: background,
            notifications: notifications,
            recordStore: store,
            isAppActive: { false }
        )
        _ = coordinator.start(projectID: "room-1")
        let generation = try! XCTUnwrap(coordinator.generation)
        background.launch(generation)
        await waitUntil { coordinator.state == .failed }

        XCTAssertNotNil(coordinator.result, "foreground viewer may use the in-memory fallback")
        XCTAssertEqual(background.completions, [false])
        XCTAssertEqual(notifications.milestones, [.interrupted])
        XCTAssertFalse(notifications.milestones.contains(.complete))
        try? store.remove()
    }

    func testPendingRelaunchRestartsWorkerWithoutRegressingStoredProgress() async throws {
        let background = FakeBackgroundAdapter()
        let store = temporaryStore()
        let generation = UUID()
        try store.save(RoomMeshColoringJobRecord(
            projectID: "room-1",
            roomName: "Kitchen",
            generation: generation,
            mode: .continuedBackground,
            state: .queued,
            progressSequence: 7,
            phase: .bakingAtlas,
            fraction: 0.80,
            updatedAt: Date(),
            halfwayHandled: true,
            completionHandled: false,
            failureHandled: false,
            failureCategory: nil
        ))
        let result = Self.makeEmptyResult()
        let coordinator = RoomMeshColoringJobCoordinator(
            worker: { _, sink in
                sink?(RoomMeshColoringProgress(
                    sequence: 1,
                    phase: .preparing,
                    completedUnits: 1,
                    totalUnits: 1,
                    detail: "Restarted safely"
                ))
                return result
            },
            background: background,
            recordStore: store
        )
        coordinator.reconcileStoredState(hasValidCache: { _ in false })
        background.launch(generation)
        await waitUntil { coordinator.state == .cacheReady }

        XCTAssertGreaterThanOrEqual(coordinator.progress.fraction, 0.80)
        XCTAssertEqual(background.completions, [true])
        try? store.remove()
    }

    func testRejectedBackgroundSubmissionFallsBackToExactlyOneForegroundWorker() async {
        let background = FakeBackgroundAdapter(submission: .rejected)
        let notifications = FakeNotificationAdapter()
        let count = LockedCount()
        let result = Self.makeEmptyResult()
        let store = temporaryStore()
        let coordinator = RoomMeshColoringJobCoordinator(
            worker: { _, _ in
                count.increment()
                return result
            },
            background: background,
            notifications: notifications,
            recordStore: store
        )
        XCTAssertEqual(coordinator.start(projectID: "room-1"), .started)
        XCTAssertEqual(coordinator.mode, .foregroundOnly)
        await waitUntil { coordinator.state == .cacheReady }
        XCTAssertEqual(count.value, 1)
        XCTAssertEqual(notifications.authorizationRequests, 0)
        try? store.remove()
    }

    func testOpeningRecoveredReadyCacheDoesNotSubmitAnotherBackgroundJob() async throws {
        let background = FakeBackgroundAdapter()
        let store = temporaryStore()
        let generation = UUID()
        try store.save(RoomMeshColoringJobRecord(
            projectID: "room-1",
            roomName: "Kitchen",
            generation: generation,
            mode: .continuedBackground,
            state: .cacheReady,
            progressSequence: 9,
            phase: .publishingCache,
            fraction: 0.99,
            updatedAt: Date(),
            halfwayHandled: true,
            completionHandled: true,
            failureHandled: false,
            failureCategory: nil
        ))
        let result = Self.makeEmptyResult()
        let coordinator = RoomMeshColoringJobCoordinator(
            worker: { _, _ in result },
            background: background,
            recordStore: store
        )
        coordinator.reconcileStoredState(hasValidCache: { _ in true })
        XCTAssertEqual(coordinator.start(projectID: "room-1"), .attached)
        await waitUntil { coordinator.result != nil }
        XCTAssertEqual(background.submissionCount, 0)
        try? store.remove()
    }

    private func temporaryStore() -> RoomMeshColoringJobRecordStore {
        RoomMeshColoringJobRecordStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("mesh-job-\(UUID().uuidString).json"))
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            await Task.yield()
        }
        XCTAssertTrue(predicate())
    }

    private static nonisolated func makeEmptyResult(
        warnings: [RoomMeshColoringWarning] = []
    ) -> RoomMeshColoredResult {
        RoomMeshColoredResult(
            mesh: RoomMeshPLYMesh(vertices: [.zero], normals: [], colors: [.zero], faces: []),
            photorealMesh: RoomMeshPhotorealMesh(
                vertices: [.zero],
                normals: [],
                fallbackColors: [.zero],
                uvs: [.zero],
                textureValid: [0],
                faces: []
            ),
            atlasPNG: nil,
            keyframeCount: 0,
            boundsMin: .zero,
            boundsMax: .zero,
            usedCachedColors: false,
            warnings: warnings
        )
    }
}

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

@MainActor
private final class FakeBackgroundAdapter: RoomMeshBackgroundTaskAdapting {
    let apiAvailable = true
    let submission: RoomMeshBackgroundSubmission
    var completions: [Bool] = []
    var submissionCount = 0
    private var launchHandler: (@MainActor (UUID) -> Void)?
    private var expirationHandler: (@MainActor (UUID) -> Void)?

    init(submission: RoomMeshBackgroundSubmission = .queued) {
        self.submission = submission
    }

    func register(
        onLaunch: @escaping @MainActor (UUID) -> Void,
        onExpiration: @escaping @MainActor (UUID) -> Void
    ) -> RoomMeshBackgroundRegistration {
        launchHandler = onLaunch
        expirationHandler = onExpiration
        return .registered
    }
    func submit(generation: UUID, roomName: String) -> RoomMeshBackgroundSubmission {
        submissionCount += 1
        return submission
    }
    func update(generation: UUID, progress: RoomMeshColoringProgress) {}
    func complete(generation: UUID, success: Bool) { completions.append(success) }
    func cancel(generation: UUID) {}
    func pending(generation: UUID, completion: @escaping @MainActor (Bool) -> Void) {
        completion(true)
    }
    func launch(_ generation: UUID) { launchHandler?(generation) }
    func expire(_ generation: UUID) { expirationHandler?(generation) }
}

@MainActor
private final class FakeNotificationAdapter: RoomMeshColoringNotificationAdapting {
    var milestones: [RoomMeshColoringNotificationMilestone] = []
    var authorizationRequests = 0
    func requestAuthorizationIfNeeded() { authorizationRequests += 1 }
    func schedule(
        _ milestone: RoomMeshColoringNotificationMilestone,
        projectID: String,
        roomName: String,
        generation: UUID,
        phaseTitle: String
    ) { milestones.append(milestone) }
    func removePending(generation: UUID) {}
}
