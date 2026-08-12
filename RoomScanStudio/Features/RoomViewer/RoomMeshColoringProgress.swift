import Foundation
import SwiftUI

enum RoomMeshColoringAccessibility {
    static let progress = "meshViewer.progress"
    static let percent = "meshViewer.percent"
    static let phase = "meshViewer.phase"
    static let detail = "meshViewer.progressDetail"
    static let stall = "meshViewer.stall"
    static let cancel = "meshViewer.cancel"
    static let retry = "meshViewer.retry"
    static let error = "meshViewer.error"
    static let warning = "meshViewer.warning"
}

enum RoomMeshColoringPhase: Int, CaseIterable, Codable, Equatable, Sendable {
    case preparing
    case measuringSharpness
    case projectingColors
    case normalizingColors
    case assigningFaces
    case packingCharts
    case bakingAtlas
    case fillingPadding
    case publishingCache
    case preparingRenderer

    var range: ClosedRange<Double> {
        switch self {
        case .preparing: 0.00...0.03
        case .measuringSharpness: 0.03...0.13
        case .projectingColors: 0.13...0.53
        case .normalizingColors: 0.53...0.60
        case .assigningFaces: 0.60...0.70
        case .packingCharts: 0.70...0.78
        case .bakingAtlas: 0.78...0.94
        case .fillingPadding: 0.94...0.97
        case .publishingCache: 0.97...0.99
        case .preparingRenderer: 0.99...1.00
        }
    }

    var title: String {
        switch self {
        case .preparing: "Preparing the room"
        case .measuringSharpness: "Measuring photo sharpness"
        case .projectingColors: "Projecting photos onto the mesh"
        case .normalizingColors: "Balancing photo colors"
        case .assigningFaces: "Choosing photos for mesh faces"
        case .packingCharts: "Laying out the texture atlas"
        case .bakingAtlas: "Baking photo detail"
        case .fillingPadding: "Making texture edges mip-safe"
        case .publishingCache: "Saving the colored mesh"
        case .preparingRenderer: "Preparing the 3D viewer"
        }
    }
}

struct RoomMeshColoringProgress: Equatable, Sendable {
    let sequence: Int
    let phase: RoomMeshColoringPhase
    let completedUnits: Int
    let totalUnits: Int
    let fraction: Double
    let detail: String?

    var percent: Int { Int((fraction * 100).rounded()) }

    init(
        sequence: Int,
        phase: RoomMeshColoringPhase,
        completedUnits: Int,
        totalUnits: Int,
        detail: String?
    ) {
        self.init(
            sequence: sequence,
            phase: phase,
            completedUnits: completedUnits,
            totalUnits: totalUnits,
            detail: detail,
            minimumFraction: 0
        )
    }

    init(
        sequence: Int,
        phase: RoomMeshColoringPhase,
        completedUnits: Int,
        totalUnits: Int,
        detail: String?,
        minimumFraction: Double
    ) {
        let safeTotal = max(totalUnits, 1)
        let safeCompleted = min(max(completedUnits, 0), safeTotal)
        let phaseFraction = Double(safeCompleted) / Double(safeTotal)
        let range = phase.range
        let measured = range.lowerBound + (range.upperBound - range.lowerBound) * phaseFraction
        self.sequence = max(sequence, 0)
        self.phase = phase
        self.completedUnits = safeCompleted
        self.totalUnits = safeTotal
        self.fraction = min(max(max(measured, minimumFraction), 0), 1)
        self.detail = detail
    }

    static let initial = RoomMeshColoringProgress(
        sequence: 0,
        phase: .preparing,
        completedUnits: 0,
        totalUnits: 1,
        detail: "Starting"
    )
}

enum RoomMeshColoringWarning: Equatable, Sendable {
    case unreadableKeyframes(Int)
    case malformedDepthPayloads(Int)
    case unusableManifest
    case atlasFallback
    case cacheNotSaved

    var message: String {
        switch self {
        case let .unreadableKeyframes(count):
            "Skipped \(count) unreadable photo\(count == 1 ? "" : "s")."
        case let .malformedDepthPayloads(count):
            "Ignored invalid depth data for \(count) photo\(count == 1 ? "" : "s"); RGB fallback was used."
        case .unusableManifest:
            "No usable capture photos were available, so the neutral mesh fallback is shown."
        case .atlasFallback:
            "The photo texture could not be completed. The vertex-colored mesh is shown instead."
        case .cacheNotSaved:
            "The colored mesh is ready, but its cache could not be saved and will be rebuilt next time."
        }
    }
}

final class RoomMeshProgressReporter: @unchecked Sendable {
    typealias Sink = @Sendable (RoomMeshColoringProgress) -> Void

    private let lock = NSLock()
    private let sink: Sink?
    private var sequence = 0
    private var lastFraction = 0.0

    init(sink: Sink? = nil) {
        self.sink = sink
    }

    convenience init(_ sink: @escaping Sink) {
        self.init(sink: sink)
    }

    func report(
        phase: RoomMeshColoringPhase,
        completed: Int,
        total: Int,
        detail: String?
    ) {
        let progress: RoomMeshColoringProgress
        lock.lock()
        sequence += 1
        progress = RoomMeshColoringProgress(
            sequence: sequence,
            phase: phase,
            completedUnits: completed,
            totalUnits: total,
            detail: detail,
            minimumFraction: lastFraction
        )
        lastFraction = progress.fraction
        lock.unlock()
        sink?(progress)
    }
}

struct RoomMeshStallTracker: Equatable, Sendable {
    static let warningThreshold: TimeInterval = 30

    private(set) var lastSequence = 0
    private(set) var lastMeasuredWorkAt: TimeInterval

    init(startedAt: TimeInterval) {
        lastMeasuredWorkAt = startedAt
    }

    @discardableResult
    mutating func record(
        _ progress: RoomMeshColoringProgress,
        at time: TimeInterval
    ) -> Bool {
        guard progress.sequence > lastSequence else { return false }
        lastSequence = progress.sequence
        lastMeasuredWorkAt = time
        return true
    }

    func isStalled(
        at time: TimeInterval,
        threshold: TimeInterval = warningThreshold
    ) -> Bool {
        time - lastMeasuredWorkAt >= threshold
    }

    mutating func keepWaiting(at time: TimeInterval) {
        lastMeasuredWorkAt = time
    }
}

enum RoomMeshLoadFailure {
    static func message(for error: Error) -> String {
        switch error {
        case RoomMeshViewerError.bundleMissing:
            return "The original room scan is missing its scene mesh. Try again, or rescan the room if this keeps happening."
        case let RoomMeshViewerError.meshUnreadable(detail):
            return "The source mesh could not be read (“\(detail)”). Try again, or rescan the room if the error returns."
        case RoomMeshViewerError.metalUnavailable:
            return "This device cannot prepare the 3D renderer. Try again after closing other graphics-heavy apps."
        default:
            return "Coloring failed: \(error.localizedDescription) Try again; your original scan has not been changed."
        }
    }
}

@MainActor
final class RoomMeshLoadController: ObservableObject {
    typealias Worker = @Sendable (
        String,
        RoomMeshProgressReporter.Sink?
    ) throws -> RoomMeshColoredResult

    @Published private(set) var progress = RoomMeshColoringProgress.initial
    @Published private(set) var result: RoomMeshColoredResult?
    @Published private(set) var failureMessage: String?
    @Published private(set) var isCancelled = false
    @Published private(set) var isStalled = false
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var rendererReady = false

    private let worker: Worker
    private var projectID: String?
    private var generation = 0
    private var stallTracker = RoomMeshStallTracker(startedAt: 0)
    private var loadTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?

    init(worker: @escaping Worker = { projectID, progress in
        try RoomMeshBundleLoader.load(forProject: projectID, progress: progress)
    }) {
        self.worker = worker
    }

    var isLoading: Bool {
        failureMessage == nil && !isCancelled && !rendererReady
    }

    func start(projectID: String) {
        stopTasks()
        generation += 1
        let currentGeneration = generation
        self.projectID = projectID
        progress = .initial
        result = nil
        failureMessage = nil
        isCancelled = false
        isStalled = false
        rendererReady = false
        elapsedSeconds = 0
        stallTracker = RoomMeshStallTracker(startedAt: Self.uptime)

        let worker = worker
        let sink: RoomMeshProgressReporter.Sink = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.accept(event, generation: currentGeneration)
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
            self?.finish(outcome, generation: currentGeneration)
        }
        startMonitor(generation: currentGeneration)
    }

    func cancel() {
        generation += 1
        stopTasks()
        result = nil
        failureMessage = nil
        isCancelled = true
        isStalled = false
    }

    func retry() {
        guard let projectID else { return }
        start(projectID: projectID)
    }

    func keepWaiting() {
        stallTracker.keepWaiting(at: Self.uptime)
        elapsedSeconds = 0
        isStalled = false
    }

    func rendererDidFinish(error: Error?) {
        guard failureMessage == nil, !isCancelled else { return }
        if let error {
            result = nil
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

    func stop() {
        generation += 1
        stopTasks()
    }

    private func accept(_ event: RoomMeshColoringProgress, generation: Int) {
        guard generation == self.generation,
              result == nil,
              failureMessage == nil,
              !isCancelled else { return }
        guard stallTracker.record(event, at: Self.uptime) else { return }
        progress = event
        isStalled = false
    }

    private func finish(
        _ outcome: Result<RoomMeshColoredResult, Error>,
        generation: Int
    ) {
        guard generation == self.generation, !isCancelled else { return }
        switch outcome {
        case let .success(result):
            self.result = result
            progress = RoomMeshColoringProgress(
                sequence: progress.sequence + 1,
                phase: .preparingRenderer,
                completedUnits: 0,
                totalUnits: 1,
                detail: "Loading the GPU resources"
            )
            _ = stallTracker.record(progress, at: Self.uptime)
            isStalled = false
        case let .failure(error):
            guard !(error is CancellationError) else {
                isCancelled = true
                isStalled = false
                return
            }
            failureMessage = RoomMeshLoadFailure.message(for: error)
            isStalled = false
            monitorTask?.cancel()
            monitorTask = nil
        }
    }

    private func startMonitor(generation: Int) {
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

    private static var uptime: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}
