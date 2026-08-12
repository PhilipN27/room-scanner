import Foundation
import SwiftUI

enum RoomMeshColoringExecutionMode: String, Codable, Equatable, Sendable {
    case continuedBackground
    case foregroundOnly

    var guidance: String {
        switch self {
        case .continuedBackground:
            "You can use other apps while RoomScanStudio colors this room."
        case .foregroundOnly:
            "Keep RoomScanStudio open to finish coloring this room."
        }
    }
}

enum RoomMeshBackgroundRegistration: Equatable, Sendable {
    case registered
    case failed
}

enum RoomMeshBackgroundSubmission: Equatable, Sendable {
    case accepted
    case queued
    case rejected
}

enum RoomMeshColoringCapability {
    static func resolve(
        apiAvailable: Bool,
        registration: RoomMeshBackgroundRegistration,
        submission: RoomMeshBackgroundSubmission
    ) -> RoomMeshColoringExecutionMode {
        guard apiAvailable,
              registration == .registered,
              submission != .rejected else {
            return .foregroundOnly
        }
        return .continuedBackground
    }
}

enum RoomMeshColoringNotificationMilestone: String, Equatable, Sendable {
    case halfway
    case complete
    case interrupted
}

struct RoomMeshColoringMilestones: Equatable, Sendable {
    private(set) var halfwayHandled = false
    private(set) var completionHandled = false
    private(set) var failureHandled = false

    init(
        halfwayHandled: Bool = false,
        completionHandled: Bool = false,
        failureHandled: Bool = false
    ) {
        self.halfwayHandled = halfwayHandled
        self.completionHandled = completionHandled
        self.failureHandled = failureHandled
    }

    mutating func acceptProgress(
        previousFraction: Double,
        fraction: Double,
        isAppActive: Bool
    ) -> RoomMeshColoringNotificationMilestone? {
        guard !halfwayHandled, previousFraction < 0.5, fraction >= 0.5 else {
            return nil
        }
        halfwayHandled = true
        return isAppActive ? nil : .halfway
    }

    mutating func complete(isAppActive: Bool) -> RoomMeshColoringNotificationMilestone? {
        guard !completionHandled else { return nil }
        completionHandled = true
        return isAppActive ? nil : .complete
    }

    mutating func interrupt(isAppActive: Bool) -> RoomMeshColoringNotificationMilestone? {
        guard !failureHandled else { return nil }
        failureHandled = true
        return isAppActive ? nil : .interrupted
    }
}

struct RoomMeshColoringGenerationGate: Equatable, Sendable {
    let generation: UUID
    private(set) var lastSequence: Int

    init(generation: UUID, lastSequence: Int = 0) {
        self.generation = generation
        self.lastSequence = lastSequence
    }

    mutating func accept(sequence: Int, generation: UUID) -> Bool {
        guard generation == self.generation, sequence > lastSequence else { return false }
        lastSequence = sequence
        return true
    }
}

enum RoomMeshColoringJobState: String, Codable, Equatable, Sendable {
    case queued
    case running
    case interrupted
    case failed
    case cacheReady
}

enum RoomMeshColoringFailureCategory: String, Codable, Equatable, Sendable {
    case expired
    case processingFailed
    case cachePublicationFailed
}

struct RoomMeshColoringJobRecord: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion = Self.currentSchemaVersion
    var projectID: String
    var roomName: String
    var generation: UUID
    var mode: RoomMeshColoringExecutionMode
    var state: RoomMeshColoringJobState
    var progressSequence: Int
    var phase: RoomMeshColoringPhase
    var fraction: Double
    var updatedAt: Date
    var halfwayHandled: Bool
    var completionHandled: Bool
    var failureHandled: Bool
    var failureCategory: RoomMeshColoringFailureCategory?
}

struct RoomMeshColoringJobRecordStore: Sendable {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static func applicationSupport(fileManager: FileManager = .default) -> Self {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return Self(fileURL: root
            .appendingPathComponent("RoomScanStudio", isDirectory: true)
            .appendingPathComponent("mesh-coloring-job-v1.json"))
    }

    func load() throws -> RoomMeshColoringJobRecord? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        guard let data = try? Data(contentsOf: fileURL),
              let record = try? JSONDecoder().decode(RoomMeshColoringJobRecord.self, from: data),
              record.schemaVersion == RoomMeshColoringJobRecord.currentSchemaVersion else {
            return nil
        }
        return record
    }

    func save(_ record: RoomMeshColoringJobRecord) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func remove() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

enum RoomMeshColoringRecovery {
    static func reconcile(
        _ record: RoomMeshColoringJobRecord?,
        hasValidCache: Bool
    ) -> RoomMeshColoringJobRecord? {
        guard var record else { return nil }
        if hasValidCache {
            record.state = .cacheReady
            record.fraction = 0.99
            record.failureCategory = nil
            return record
        }
        if record.state == .queued || record.state == .running {
            record.state = .interrupted
            record.failureCategory = .expired
        }
        return record
    }
}

@MainActor
protocol RoomMeshBackgroundTaskAdapting: AnyObject {
    var apiAvailable: Bool { get }
    func register(
        onLaunch: @escaping @MainActor (UUID) -> Void,
        onExpiration: @escaping @MainActor (UUID) -> Void
    ) -> RoomMeshBackgroundRegistration
    func submit(generation: UUID, roomName: String) -> RoomMeshBackgroundSubmission
    func update(generation: UUID, progress: RoomMeshColoringProgress)
    func complete(generation: UUID, success: Bool)
    func cancel(generation: UUID)
    func pending(generation: UUID, completion: @escaping @MainActor (Bool) -> Void)
}

@MainActor
protocol RoomMeshColoringNotificationAdapting: AnyObject {
    func requestAuthorizationIfNeeded()
    func schedule(
        _ milestone: RoomMeshColoringNotificationMilestone,
        projectID: String,
        roomName: String,
        generation: UUID,
        phaseTitle: String
    )
    func removePending(generation: UUID)
}

@MainActor
final class ForegroundOnlyRoomMeshBackgroundTaskAdapter: RoomMeshBackgroundTaskAdapting {
    let apiAvailable = false

    func register(
        onLaunch: @escaping @MainActor (UUID) -> Void,
        onExpiration: @escaping @MainActor (UUID) -> Void
    ) -> RoomMeshBackgroundRegistration { .failed }

    func submit(generation: UUID, roomName: String) -> RoomMeshBackgroundSubmission { .rejected }
    func update(generation: UUID, progress: RoomMeshColoringProgress) {}
    func complete(generation: UUID, success: Bool) {}
    func cancel(generation: UUID) {}
    func pending(generation: UUID, completion: @escaping @MainActor (Bool) -> Void) {
        completion(false)
    }
}

@MainActor
final class NoopRoomMeshColoringNotificationAdapter: RoomMeshColoringNotificationAdapting {
    func requestAuthorizationIfNeeded() {}
    func schedule(
        _ milestone: RoomMeshColoringNotificationMilestone,
        projectID: String,
        roomName: String,
        generation: UUID,
        phaseTitle: String
    ) {}
    func removePending(generation: UUID) {}
}

enum RoomMeshColoringStartResult: Equatable, Sendable {
    case started
    case attached
    case conflict(activeProjectID: String)
}

@MainActor
final class RoomMeshColoringJobCoordinator: ObservableObject {
    typealias Worker = @Sendable (
        String,
        RoomMeshProgressReporter.Sink?
    ) throws -> RoomMeshColoredResult

    @Published private(set) var projectID: String?
    @Published private(set) var roomName = "Room"
    @Published private(set) var generation: UUID?
    @Published private(set) var mode: RoomMeshColoringExecutionMode = .foregroundOnly
    @Published private(set) var state: RoomMeshColoringJobState?
    @Published private(set) var progress = RoomMeshColoringProgress.initial
    @Published private(set) var result: RoomMeshColoredResult?
    @Published private(set) var failureMessage: String?
    @Published private(set) var isCancelled = false
    @Published private(set) var isStalled = false
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var rendererReady = false
    @Published private(set) var conflictProjectID: String?

    private let worker: Worker
    private let background: any RoomMeshBackgroundTaskAdapting
    private let notifications: any RoomMeshColoringNotificationAdapting
    private let recordStore: RoomMeshColoringJobRecordStore
    private let isAppActive: @MainActor () -> Bool
    private var gate: RoomMeshColoringGenerationGate?
    private var milestones = RoomMeshColoringMilestones()
    private var stallTracker = RoomMeshStallTracker(startedAt: 0)
    private var loadTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?

    init(
        worker: @escaping Worker = { projectID, progress in
            try RoomMeshBundleLoader.load(forProject: projectID, progress: progress)
        },
        background: (any RoomMeshBackgroundTaskAdapting)? = nil,
        notifications: (any RoomMeshColoringNotificationAdapting)? = nil,
        recordStore: RoomMeshColoringJobRecordStore = .applicationSupport(),
        isAppActive: @escaping @MainActor () -> Bool = { true }
    ) {
        self.worker = worker
        self.background = background ?? ForegroundOnlyRoomMeshBackgroundTaskAdapter()
        self.notifications = notifications ?? NoopRoomMeshColoringNotificationAdapter()
        self.recordStore = recordStore
        self.isAppActive = isAppActive
    }

    var isLoading: Bool {
        failureMessage == nil && !isCancelled && !rendererReady && state != .cacheReady
    }

    var executionMessage: String {
        if state == .queued { return "Waiting for iPhone to begin background processing." }
        if state == .cacheReady && !rendererReady { return "Colored mesh is ready. Preparing the 3D viewer." }
        return mode.guidance
    }

    var isActiveJob: Bool {
        state == .queued || state == .running
    }

    @discardableResult
    func start(projectID: String, roomName: String = "Room") -> RoomMeshColoringStartResult {
        if self.projectID == projectID, result != nil { return .attached }
        if self.projectID == projectID,
           state == .cacheReady,
           let generation {
            gate = RoomMeshColoringGenerationGate(generation: generation)
            state = .running
            launchWorker(generation: generation)
            return .attached
        }
        if isActiveJob, let activeProjectID = self.projectID {
            if activeProjectID == projectID { return .attached }
            conflictProjectID = activeProjectID
            return .conflict(activeProjectID: activeProjectID)
        }

        stopTasks()
        let generation = UUID()
        self.projectID = projectID
        self.roomName = roomName
        self.generation = generation
        gate = RoomMeshColoringGenerationGate(generation: generation)
        milestones = RoomMeshColoringMilestones()
        progress = .initial
        result = nil
        failureMessage = nil
        isCancelled = false
        isStalled = false
        rendererReady = false
        elapsedSeconds = 0
        conflictProjectID = nil
        stallTracker = RoomMeshStallTracker(startedAt: Self.uptime)

        let registration = background.register(
            onLaunch: { [weak self] launchedGeneration in
                self?.launchWorker(generation: launchedGeneration)
            },
            onExpiration: { [weak self] expiredGeneration in
                self?.expire(generation: expiredGeneration)
            }
        )
        let submission = registration == .registered
            ? background.submit(generation: generation, roomName: roomName)
            : .rejected
        mode = RoomMeshColoringCapability.resolve(
            apiAvailable: background.apiAvailable,
            registration: registration,
            submission: submission
        )

        if mode == .continuedBackground {
            state = .queued
            notifications.requestAuthorizationIfNeeded()
            persist()
        } else {
            state = .running
            persist()
            launchWorker(generation: generation)
        }
        return .started
    }

    func attach(projectID: String) -> Bool {
        self.projectID == projectID
    }

    func detach(projectID: String) {
        // App-level ownership is intentional: navigation never owns cancellation.
    }

    func cancel() {
        guard let generation else { return }
        gate = nil
        stopTasks()
        background.cancel(generation: generation)
        notifications.removePending(generation: generation)
        result = nil
        failureMessage = nil
        state = .interrupted
        isCancelled = true
        isStalled = false
        persist(failureCategory: .expired)
    }

    func retry() {
        guard let projectID else { return }
        start(projectID: projectID, roomName: roomName)
    }

    func keepWaiting() {
        stallTracker.keepWaiting(at: Self.uptime)
        elapsedSeconds = 0
        isStalled = false
    }

    func rendererDidFinish(error: Error?) {
        guard failureMessage == nil, !isCancelled, result != nil else { return }
        if let error {
            failureMessage = RoomMeshLoadFailure.message(for: error)
            isStalled = false
        } else {
            progress = RoomMeshColoringProgress(
                sequence: progress.sequence + 1,
                phase: .preparingRenderer,
                completedUnits: 1,
                totalUnits: 1,
                detail: "Ready"
            )
            rendererReady = true
            isStalled = false
        }
        monitorTask?.cancel()
        monitorTask = nil
    }

    func reconcileStoredState(hasValidCache: (String) -> Bool) {
        guard let stored = try? recordStore.load() else { return }
        if hasValidCache(stored.projectID) {
            if let recovered = RoomMeshColoringRecovery.reconcile(stored, hasValidCache: true) {
                applyRecovered(recovered)
                try? recordStore.save(recovered)
            }
            return
        }
        if (stored.state == .queued || stored.state == .running),
           stored.mode == .continuedBackground,
           background.apiAvailable {
            applyRecovered(stored)
            gate = RoomMeshColoringGenerationGate(
                generation: stored.generation,
                lastSequence: 0
            )
            let registration = background.register(
                onLaunch: { [weak self] generation in self?.launchWorker(generation: generation) },
                onExpiration: { [weak self] generation in self?.expire(generation: generation) }
            )
            guard registration == .registered else {
                interruptRecovered(stored)
                return
            }
            background.pending(generation: stored.generation) { [weak self] isPending in
                guard let self,
                      self.generation == stored.generation,
                      self.loadTask == nil,
                      self.state == .queued || self.state == .running,
                      !isPending else { return }
                self.interruptRecovered(stored)
            }
            return
        }
        interruptRecovered(stored)
    }

    private func applyRecovered(_ recovered: RoomMeshColoringJobRecord) {
        projectID = recovered.projectID
        roomName = recovered.roomName
        generation = recovered.generation
        mode = recovered.mode
        state = recovered.state
        progress = RoomMeshColoringProgress(
            sequence: recovered.progressSequence,
            phase: recovered.phase,
            completedUnits: 0,
            totalUnits: 1,
            detail: recovered.state == .interrupted ? "Reopen the room to retry." : nil,
            minimumFraction: recovered.fraction
        )
        milestones = RoomMeshColoringMilestones(
            halfwayHandled: recovered.halfwayHandled,
            completionHandled: recovered.completionHandled,
            failureHandled: recovered.failureHandled
        )
        if recovered.state == .interrupted || recovered.state == .failed {
            failureMessage = "Room coloring was interrupted. Try again; your original scan is safe."
        }
    }

    private func interruptRecovered(_ stored: RoomMeshColoringJobRecord) {
        guard let recovered = RoomMeshColoringRecovery.reconcile(stored, hasValidCache: false) else { return }
        applyRecovered(recovered)
        try? recordStore.save(recovered)
    }

    private func launchWorker(generation: UUID) {
        guard generation == self.generation, loadTask == nil, state == .queued || state == .running else { return }
        state = .running
        persist()
        let worker = worker
        let projectID = self.projectID ?? ""
        let sink: RoomMeshProgressReporter.Sink = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.accept(event, generation: generation)
            }
        }
        let workerTask = Task.detached(priority: .userInitiated) {
            try worker(projectID, sink)
        }
        loadTask = Task { [weak self] in
            let outcome = await withTaskCancellationHandler {
                await workerTask.result
            } onCancel: {
                workerTask.cancel()
            }
            guard !Task.isCancelled else { return }
            self?.finish(outcome, generation: generation)
        }
        startMonitor(generation: generation)
    }

    private func accept(_ event: RoomMeshColoringProgress, generation: UUID) {
        guard var gate, gate.accept(sequence: event.sequence, generation: generation),
              result == nil, failureMessage == nil, !isCancelled else { return }
        self.gate = gate
        let previous = progress.fraction
        let acceptedEvent = RoomMeshColoringProgress(
            sequence: event.sequence,
            phase: event.phase,
            completedUnits: event.completedUnits,
            totalUnits: event.totalUnits,
            detail: event.detail,
            minimumFraction: previous
        )
        progress = acceptedEvent
        _ = stallTracker.record(acceptedEvent, at: Self.uptime)
        isStalled = false
        background.update(generation: generation, progress: acceptedEvent)
        if let milestone = milestones.acceptProgress(
            previousFraction: previous,
            fraction: acceptedEvent.fraction,
            isAppActive: isAppActive()
        ) {
            persist()
            schedule(milestone, generation: generation)
        }
        persist()
    }

    private func finish(_ outcome: Result<RoomMeshColoredResult, Error>, generation: UUID) {
        guard generation == self.generation, gate != nil, !isCancelled else { return }
        loadTask = nil
        switch outcome {
        case let .success(result):
            self.result = result
            if result.warnings.contains(.cacheNotSaved) {
                state = .failed
                persist(failureCategory: .cachePublicationFailed)
                background.complete(generation: generation, success: false)
                if let milestone = milestones.interrupt(isAppActive: isAppActive()) {
                    persist(failureCategory: .cachePublicationFailed)
                    schedule(milestone, generation: generation)
                }
                monitorTask?.cancel()
                monitorTask = nil
                return
            }
            state = .cacheReady
            progress = RoomMeshColoringProgress(
                sequence: progress.sequence + 1,
                phase: .publishingCache,
                completedUnits: 1,
                totalUnits: 1,
                detail: "Colored mesh is ready"
            )
            if let milestone = milestones.complete(isAppActive: isAppActive()) {
                persist()
                schedule(milestone, generation: generation)
            }
            persist()
            background.update(generation: generation, progress: progress)
            background.complete(generation: generation, success: true)
            monitorTask?.cancel()
            monitorTask = nil
        case let .failure(error):
            if error is CancellationError {
                expire(generation: generation)
                return
            }
            state = .failed
            failureMessage = RoomMeshLoadFailure.message(for: error)
            background.complete(generation: generation, success: false)
            if let milestone = milestones.interrupt(isAppActive: isAppActive()) {
                persist(failureCategory: .processingFailed)
                schedule(milestone, generation: generation)
            }
            persist(failureCategory: .processingFailed)
            monitorTask?.cancel()
            monitorTask = nil
        }
    }

    private func expire(generation: UUID) {
        guard generation == self.generation, state == .queued || state == .running else { return }
        gate = nil
        stopTasks()
        state = .interrupted
        failureMessage = "Room coloring was interrupted. Try again; your original scan is safe."
        background.complete(generation: generation, success: false)
        if let milestone = milestones.interrupt(isAppActive: isAppActive()) {
            persist(failureCategory: .expired)
            schedule(milestone, generation: generation)
        }
        persist(failureCategory: .expired)
    }

    private func schedule(_ milestone: RoomMeshColoringNotificationMilestone, generation: UUID) {
        guard let projectID else { return }
        notifications.schedule(
            milestone,
            projectID: projectID,
            roomName: roomName,
            generation: generation,
            phaseTitle: progress.phase.title
        )
    }

    private func persist(failureCategory: RoomMeshColoringFailureCategory? = nil) {
        guard let projectID, let generation, let state else { return }
        let record = RoomMeshColoringJobRecord(
            projectID: projectID,
            roomName: roomName,
            generation: generation,
            mode: mode,
            state: state,
            progressSequence: progress.sequence,
            phase: progress.phase,
            fraction: progress.fraction,
            updatedAt: Date(),
            halfwayHandled: milestones.halfwayHandled,
            completionHandled: milestones.completionHandled,
            failureHandled: milestones.failureHandled,
            failureCategory: failureCategory
        )
        try? recordStore.save(record)
    }

    private func startMonitor(generation: UUID) {
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, generation == self.generation else { return }
                elapsedSeconds = max(Int(Self.uptime - stallTracker.lastMeasuredWorkAt), 0)
                isStalled = stallTracker.isStalled(at: Self.uptime)
            }
        }
    }

    private func stopTasks() {
        loadTask?.cancel()
        monitorTask?.cancel()
        loadTask = nil
        monitorTask = nil
    }

    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
