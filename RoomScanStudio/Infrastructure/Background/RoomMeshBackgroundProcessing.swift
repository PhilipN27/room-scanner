import BackgroundTasks
import Foundation

enum RoomMeshBackgroundDelivery {
    static func isDeliveredOrPending(requestIsPending: Bool, taskIsActive: Bool) -> Bool {
        requestIsPending || taskIsActive
    }
}

@MainActor
final class AppleRoomMeshBackgroundTaskAdapter: RoomMeshBackgroundTaskAdapting {
    static let permittedIdentifier = "org.roomscanstudio.app.mesh-coloring.*"
    private nonisolated static let identifierPrefix = "org.roomscanstudio.app.mesh-coloring."

    private var didRegister = false
    private var registrationSucceeded = false
    private var onLaunch: (@MainActor (UUID) -> Void)?
    private var onExpiration: (@MainActor (UUID) -> Void)?

    @available(iOS 26.0, *)
    private var tasks: [UUID: BGContinuedProcessingTask] {
        get { taskStorage as? [UUID: BGContinuedProcessingTask] ?? [:] }
        set { taskStorage = newValue }
    }
    private var taskStorage: Any = [UUID: Any]()

    var apiAvailable: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    func register(
        onLaunch: @escaping @MainActor (UUID) -> Void,
        onExpiration: @escaping @MainActor (UUID) -> Void
    ) -> RoomMeshBackgroundRegistration {
        self.onLaunch = onLaunch
        self.onExpiration = onExpiration
        guard apiAvailable else { return .failed }
        if didRegister { return registrationSucceeded ? .registered : .failed }
        didRegister = true
        if #available(iOS 26.0, *) {
            registrationSucceeded = BGTaskScheduler.shared.register(
                forTaskWithIdentifier: Self.permittedIdentifier,
                using: nil
            ) { [weak self] task in
                guard let continuedTask = task as? BGContinuedProcessingTask,
                      let generation = Self.generation(from: task.identifier) else {
                    task.setTaskCompleted(success: false)
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self else {
                        continuedTask.setTaskCompleted(success: false)
                        return
                    }
                    continuedTask.progress.totalUnitCount = 1_000
                    tasks[generation] = continuedTask
                    continuedTask.expirationHandler = { [weak self] in
                        Task { @MainActor [weak self] in
                            self?.onExpiration?(generation)
                        }
                    }
                    self.onLaunch?(generation)
                }
            }
        }
        return registrationSucceeded ? .registered : .failed
    }

    func submit(generation: UUID, roomName: String) -> RoomMeshBackgroundSubmission {
        guard registrationSucceeded else { return .rejected }
        if #available(iOS 26.0, *) {
            let request = BGContinuedProcessingTaskRequest(
                identifier: Self.identifier(for: generation),
                title: "Coloring \(roomName)",
                subtitle: "Preparing the room"
            )
            request.strategy = .queue
            request.requiredResources = []
            do {
                try BGTaskScheduler.shared.submit(request)
                return .queued
            } catch {
                return .rejected
            }
        }
        return .rejected
    }

    func update(generation: UUID, progress: RoomMeshColoringProgress) {
        guard #available(iOS 26.0, *), let task = tasks[generation] else { return }
        let completed = Int64((min(max(progress.fraction, 0), 0.99) * 1_000).rounded(.down))
        task.progress.completedUnitCount = max(task.progress.completedUnitCount, completed)
        task.updateTitle("Coloring your room", subtitle: "\(progress.phase.title) — \(progress.percent)%")
    }

    func complete(generation: UUID, success: Bool) {
        guard #available(iOS 26.0, *), let task = tasks.removeValue(forKey: generation) else { return }
        if success { task.progress.completedUnitCount = task.progress.totalUnitCount }
        task.setTaskCompleted(success: success)
    }

    func cancel(generation: UUID) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier(for: generation))
        if #available(iOS 26.0, *), let task = tasks.removeValue(forKey: generation) {
            task.setTaskCompleted(success: false)
        }
    }

    func pending(generation: UUID, completion: @escaping @MainActor (Bool) -> Void) {
        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            let identifier = Self.identifier(for: generation)
            let isPending = requests.contains { $0.identifier == identifier }
            Task { @MainActor [weak self] in
                var isActive = false
                if #available(iOS 26.0, *), let self {
                    isActive = tasks[generation] != nil
                }
                completion(RoomMeshBackgroundDelivery.isDeliveredOrPending(
                    requestIsPending: isPending,
                    taskIsActive: isActive
                ))
            }
        }
    }

    private nonisolated static func identifier(for generation: UUID) -> String {
        identifierPrefix + generation.uuidString.lowercased()
    }

    private nonisolated static func generation(from identifier: String) -> UUID? {
        guard identifier.hasPrefix(identifierPrefix) else { return nil }
        return UUID(uuidString: String(identifier.dropFirst(identifierPrefix.count)))
    }
}
