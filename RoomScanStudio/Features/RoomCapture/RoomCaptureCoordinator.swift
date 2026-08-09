import Combine
import Foundation
import RoomScanCore

/// Interprets the Foundation-only reducer for one UI-owned capture attempt.
/// Every asynchronous effect is owned by this coordinator and tracked until it
/// finishes. A discard waits for all scratch-writing work before deletion.
@MainActor
final class RoomCaptureCoordinator: ObservableObject {
    @Published private(set) var state = RoomCaptureState(attemptToken: nil)
    @Published private(set) var liveSnapshot: RoomSemanticSnapshot?
    @Published private(set) var capturedGPS: RoomGPSLocation?
    @Published private(set) var errorMessage: String?
    @Published private(set) var cleanupErrorMessage: String?
    @Published private(set) var qualitativeGuidance: [String] = []

    @Published var roomName = ""
    @Published var manualLocation = ""
    @Published var notes = ""
    @Published var tagsText = ""

    private enum EffectTaskKind: Hashable {
        case cameraAuthorization
        case gpsAuthorization
        case gpsCancellation
        case start
        case stop
        case processing
        case referencePhoto
        case persistence
        case cleanup
    }

    private let controller: RoomLibraryController
    private let cameraPermissionProvider: any RoomCameraPermissionProviding
    private let locationProvider: any RoomLocationProviding
    private let workspaceFactory: RoomCaptureScratchWorkspaceFactory
    private let driver: any RoomCaptureDriving
    private let savePolicy: any RoomCaptureSavePolicy
    private let attemptGenerator: any RoomCaptureAttemptIDGenerating

    private var effectTasks: [EffectTaskKind: Task<Void, Never>] = [:]
    private var workspace: RoomCaptureScratchWorkspace?
    private var preparedReview: RoomCapturePreparedReview?
    /// Snapshot-derived warnings and live operational warnings intentionally
    /// remain separate. A recovered tracking/light observation must not erase
    /// a semantic review warning, and an empty recovery must clear old
    /// operational text instead of leaving stale advice on the canvas.
    private var semanticGuidance: [RoomCaptureGuidance] = []
    private var operationalGuidance: [RoomCaptureGuidance] = []
    private var pendingSuccessfulSaveAttempt: RoomCaptureAttemptToken?
    private var referencePhotoSequence = 0

    init(
        controller: RoomLibraryController,
        cameraPermissionProvider: any RoomCameraPermissionProviding,
        locationProvider: any RoomLocationProviding,
        workspaceFactory: RoomCaptureScratchWorkspaceFactory,
        driver: any RoomCaptureDriving,
        savePolicy: any RoomCaptureSavePolicy,
        attemptGenerator: any RoomCaptureAttemptIDGenerating
    ) {
        self.controller = controller
        self.cameraPermissionProvider = cameraPermissionProvider
        self.locationProvider = locationProvider
        self.workspaceFactory = workspaceFactory
        self.driver = driver
        self.savePolicy = savePolicy
        self.attemptGenerator = attemptGenerator
        driver.observationHandler = { [weak self] observation in
            self?.receiveDriverObservation(observation)
        }
    }

    var canStart: Bool {
        state.phase == .ready && state.cameraPermission == .authorized
    }

    var canStop: Bool {
        state.phase == .scanning && state.referencePhotoRequestID == nil
    }

    var canSave: Bool {
        state.canSave && !roomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canRequestGPS: Bool {
        state.attemptToken != nil
            && state.gpsPermission == .unknown
            && !state.gpsRequestInFlight
    }

    var canRequestReferencePhoto: Bool {
        state.phase == .scanning && state.referencePhotoRequestID == nil
    }

    var showsDiscard: Bool {
        switch state.phase {
        case .requestingCamera, .ready, .starting, .scanning, .stopping,
             .processing, .review, .failed:
            return state.attemptToken != nil
        case .preflight, .saving, .saved, .discarding, .discarded, .cancelled:
            return false
        }
    }

    /// Back navigation and interactive dismissal must not bypass cleanup once
    /// a capture attempt exists. Terminal routing happens only after cleanup.
    var blocksNavigationExit: Bool {
        switch state.phase {
        case .preflight, .saved, .discarded, .cancelled:
            return false
        case .requestingCamera, .ready, .starting, .scanning, .stopping,
             .processing, .review, .saving, .failed, .discarding:
            return true
        }
    }

    var isSaving: Bool {
        state.phase == .saving
    }

    var canRetryCleanup: Bool {
        cleanupErrorMessage != nil
            && (state.phase == .discarding || pendingSuccessfulSaveAttempt != nil)
    }

    var isTerminal: Bool {
        switch state.phase {
        case .saved, .discarded, .cancelled:
            return true
        case .preflight, .requestingCamera, .ready, .starting, .scanning,
             .stopping, .processing, .review, .saving, .failed, .discarding:
            return false
        }
    }

    func prepare() {
        guard state.phase == .preflight else { return }
        let attempt = attemptGenerator.nextAttemptToken()
        do {
            workspace = try workspaceFactory.makeWorkspace(for: attempt)
            state = RoomCaptureState(attemptToken: attempt)
            errorMessage = nil
            cleanupErrorMessage = nil
            liveSnapshot = nil
            capturedGPS = nil
            preparedReview = nil
            semanticGuidance = []
            operationalGuidance = []
            dispatch(.requestCamera(attempt: attempt))
        } catch {
            state = RoomCaptureState(
                phase: .failed,
                attemptToken: attempt,
                failure: .startFailed
            )
            errorMessage = error.localizedDescription
        }
    }

    func start() {
        guard let attempt = state.attemptToken else { return }
        dispatch(.startRequested(attempt: attempt))
    }

    func stop() {
        guard let attempt = state.attemptToken else { return }
        dispatch(.stopRequested(attempt: attempt))
    }

    func requestGPS() {
        guard let attempt = state.attemptToken else { return }
        dispatch(.requestGPSAuthorization(attempt: attempt))
    }

    func requestReferencePhoto() {
        guard let attempt = state.attemptToken, canRequestReferencePhoto else { return }
        referencePhotoSequence += 1
        dispatch(
            .requestReferencePhoto(
                attempt: attempt,
                requestID: RoomReferencePhotoRequestID("photo-request-\(referencePhotoSequence)")
            )
        )
    }

    func retryProcessing() {
        guard let attempt = state.attemptToken else { return }
        dispatch(.retryRequested(attempt: attempt))
    }

    func save() {
        guard let attempt = state.attemptToken, state.canSave else { return }
        guard !roomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Enter a room name before saving."
            return
        }
        errorMessage = nil
        dispatch(.saveRequested(attempt: attempt))
    }

    func discard() {
        guard let attempt = state.attemptToken else { return }
        dispatch(.discardRequested(attempt: attempt))
    }

    func retryCleanup() {
        guard canRetryCleanup, let attempt = cleanupAttempt else { return }
        cleanupErrorMessage = nil
        launchCleanupRetry(for: attempt)
    }

    /// Kept internal for focused coordinator tests. Platform adapters call this
    /// on the main actor after translating their callbacks into Foundation DTOs.
    func receiveDriverObservation(_ observation: RoomCaptureDriverObservation) {
        switch observation {
        case let .didStart(attempt):
            dispatch(.didStart(attempt: attempt))
        case let .didStop(attempt):
            dispatch(.didStop(attempt: attempt))
        case let .coaching(attempt, instruction):
            guard state.attemptToken == attempt, acceptsOperationalObservation(in: state.phase) else {
                return
            }
            dispatch(.coachingInstructionUpdated(attempt: attempt, instruction: instruction))
        case let .tracking(attempt, quality, limitedReason):
            guard state.attemptToken == attempt, acceptsOperationalObservation(in: state.phase) else {
                return
            }
            dispatch(.trackingUpdated(attempt: attempt, quality: quality, limitedReason: limitedReason))
        case let .semanticGuidance(attempt, values):
            guard state.attemptToken == attempt, acceptsLiveSnapshot(in: state.phase) else {
                return
            }
            semanticGuidance = values
            dispatch(.guidanceUpdated(attempt: attempt, guidance: values))
        case let .operationalGuidance(attempt, values):
            guard state.attemptToken == attempt, acceptsOperationalObservation(in: state.phase) else {
                return
            }
            operationalGuidance = values
            updateGuidance()
        case let .liveSnapshot(attempt, snapshot):
            guard state.attemptToken == attempt, acceptsLiveSnapshot(in: state.phase) else {
                return
            }
            liveSnapshot = snapshot
        case let .terminated(attempt, reason):
            dispatch(.captureTerminated(attempt: attempt, reason: reason))
        }
    }

    private func dispatch(_ event: RoomCaptureEvent) {
        let transition = RoomCaptureReducer.reduce(state, event: event)
        state = transition.state
        updateGuidance()
        schedule(transition.effects)
    }

    private func schedule(_ effects: [RoomCaptureEffect]) {
        guard !effects.isEmpty else { return }
        if effects.contains(where: isCleanupEffect) {
            // Cancellation is applied synchronously while this MainActor turn
            // still owns the reducer transition. Queued effects therefore see
            // Task.isCancelled before they can request permission, start
            // capture, process scratch output, or request a reference photo.
            cancelQueuedAttemptEffects()
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                for effect in effects {
                    await self.perform(effect)
                }
                self.effectTasks[.cleanup] = nil
            }
            effectTasks[.cleanup] = task
            return
        }

        for effect in effects {
            let kind = effectTaskKind(for: effect)
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.perform(effect)
                self.effectTasks[kind] = nil
            }
            effectTasks[kind] = task
        }
    }

    private func launchCleanupRetry(for attempt: RoomCaptureAttemptToken) {
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            if await self.cleanupWorkspace(for: attempt) {
                self.finishCleanup(for: attempt)
            }
            self.effectTasks[.cleanup] = nil
        }
        effectTasks[.cleanup] = task
    }

    private func perform(_ effect: RoomCaptureEffect) async {
        switch effect {
        case let .requestCameraAuthorization(attempt):
            guard !Task.isCancelled, isActive(attempt, phase: .requestingCamera) else {
                return
            }
            let permission = await cameraPermissionProvider.requestCameraPermission(for: attempt)
            guard !Task.isCancelled, isActive(attempt, phase: .requestingCamera) else { return }
            dispatch(permission == .authorized ? .cameraAuthorized(attempt: attempt) : .cameraDenied(attempt: attempt))

        case let .requestGPSAuthorization(attempt):
            guard !Task.isCancelled, state.attemptToken == attempt, state.gpsRequestInFlight else {
                return
            }
            let result = await locationProvider.requestCurrentLocation(for: attempt)
            guard !Task.isCancelled, state.attemptToken == attempt, state.gpsRequestInFlight else { return }
            switch result {
            case let .authorized(location):
                capturedGPS = location
                dispatch(.gpsAuthorized(attempt: attempt))
            case .denied:
                dispatch(.gpsDenied(attempt: attempt))
            }

        case let .cancelGPSAuthorization(attempt):
            await cancelAndAwaitGPSAuthorization(for: attempt)

        case let .startCapture(attempt):
            guard
                !Task.isCancelled,
                isActive(attempt, phase: .starting),
                let workspace,
                workspace.attempt == attempt
            else {
                guard !Task.isCancelled else { return }
                dispatch(.startFailed(attempt: attempt))
                return
            }
            do {
                try await driver.start(attempt: attempt, workspace: workspace)
            } catch {
                guard !Task.isCancelled, isActive(attempt, phase: .starting) else { return }
                errorMessage = error.localizedDescription
                dispatch(.startFailed(attempt: attempt))
            }

        case let .stopCapture(attempt):
            guard !Task.isCancelled, isActive(attempt, phase: .stopping) else { return }
            do {
                try await driver.stop(attempt: attempt)
            } catch {
                guard !Task.isCancelled, isActive(attempt, phase: .stopping) else { return }
                errorMessage = error.localizedDescription
                dispatch(.captureTerminated(attempt: attempt, reason: .internalError))
            }

        case let .terminateCapture(attempt):
            await driver.terminate(attempt: attempt)

        case let .processCapture(attempt):
            guard
                !Task.isCancelled,
                isActive(attempt, phase: .processing),
                let workspace,
                workspace.attempt == attempt
            else {
                guard !Task.isCancelled else { return }
                dispatch(.processingFailed(attempt: attempt, retryable: false))
                return
            }
            do {
                let review = try await driver.process(attempt: attempt, workspace: workspace)
                guard !Task.isCancelled, isActive(attempt, phase: .processing) else { return }
                preparedReview = review
                // Processing output becomes the review truth. Later live
                // callbacks cannot overwrite it once review starts.
                liveSnapshot = review.commit.draft.revision.semanticSnapshot
                populateEditableMetadata(from: review.commit.draft.metadata)
                semanticGuidance = review.guidance
                dispatch(.guidanceUpdated(attempt: attempt, guidance: review.guidance))
                dispatch(.processingSucceeded(attempt: attempt))
            } catch {
                guard !Task.isCancelled, isActive(attempt, phase: .processing) else { return }
                errorMessage = error.localizedDescription
                dispatch(.processingFailed(attempt: attempt, retryable: true))
            }

        case let .cancelProcessing(attempt):
            await driver.cancelProcessing(attempt: attempt)

        case let .requestReferencePhoto(attempt, requestID):
            guard
                !Task.isCancelled,
                isActivePhotoRequest(attempt, requestID: requestID),
                let workspace,
                workspace.attempt == attempt
            else {
                guard !Task.isCancelled else { return }
                dispatch(.referencePhotoFailed(attempt: attempt, requestID: requestID))
                return
            }
            do {
                try await driver.requestReferencePhoto(
                    attempt: attempt,
                    requestID: requestID,
                    workspace: workspace
                )
                guard !Task.isCancelled, isActivePhotoRequest(attempt, requestID: requestID) else { return }
                dispatch(.referencePhotoSucceeded(attempt: attempt, requestID: requestID))
            } catch {
                guard !Task.isCancelled, isActivePhotoRequest(attempt, requestID: requestID) else { return }
                errorMessage = error.localizedDescription
                dispatch(.referencePhotoFailed(attempt: attempt, requestID: requestID))
            }

        case let .persistCapture(attempt):
            do {
                try savePolicy.validateSave(for: attempt)
                guard let commit = editedCommitForSaving(), isActive(attempt, phase: .saving) else {
                    throw RoomCaptureDriverError.noCapturedResult
                }
                _ = try await controller.commitInitialCapture(commit, decision: .save)
                guard isActive(attempt, phase: .saving) else { return }
                pendingSuccessfulSaveAttempt = attempt
                if await cleanupWorkspace(for: attempt) {
                    finishCleanup(for: attempt)
                }
            } catch {
                guard isActive(attempt, phase: .saving) else { return }
                errorMessage = error.localizedDescription
                dispatch(.saveFailed(attempt: attempt))
            }

        case let .cleanupScratch(attempt):
            if await cleanupWorkspace(for: attempt) {
                finishCleanup(for: attempt)
            }
        }
    }

    /// No destructive scratch cleanup begins until every task that can touch
    /// its files has been cancelled and awaited, plus the driver reports its
    /// own writer barrier clear.
    private func cleanupWorkspace(for attempt: RoomCaptureAttemptToken) async -> Bool {
        await cancelAndAwaitScratchWriters(for: attempt)
        guard let workspace, workspace.attempt == attempt else {
            cleanupErrorMessage = nil
            return true
        }
        do {
            try await driver.cleanup(workspace: workspace)
            try workspaceFactory.cleanup(workspace)
            self.workspace = nil
            cleanupErrorMessage = nil
            return true
        } catch {
            cleanupErrorMessage = error.localizedDescription
            return false
        }
    }

    private func cancelAndAwaitScratchWriters(for attempt: RoomCaptureAttemptToken) async {
        // GPS is a separate, attempt-scoped external request. Its task is
        // cancelled first, the provider is asked to resume and clear only the
        // matching continuation, and that task is awaited before terminal UI
        // routing can remove the scratch workspace or begin a new attempt.
        let cameraTask = effectTasks[.cameraAuthorization]
        cameraTask?.cancel()
        if let cameraTask {
            await cameraTask.value
        }

        await cancelAndAwaitGPSAuthorization(for: attempt)

        let writerTasks = [
            effectTasks[.start],
            effectTasks[.processing],
            effectTasks[.referencePhoto],
        ].compactMap { $0 }
        for task in writerTasks {
            task.cancel()
        }
        await driver.cancelProcessing(attempt: attempt)
        for task in writerTasks {
            await task.value
        }
        await driver.awaitScratchWriteBarrier(for: attempt)
    }

    private func cancelQueuedAttemptEffects() {
        for kind in [
            EffectTaskKind.cameraAuthorization,
            .gpsAuthorization,
            .start,
            .stop,
            .processing,
            .referencePhoto,
        ] {
            effectTasks[kind]?.cancel()
        }
    }

    private func cancelAndAwaitGPSAuthorization(for attempt: RoomCaptureAttemptToken) async {
        let gpsTask = effectTasks[.gpsAuthorization]
        gpsTask?.cancel()
        await locationProvider.cancelCurrentLocation(for: attempt)
        if let gpsTask {
            await gpsTask.value
        }
    }

    private func finishCleanup(for attempt: RoomCaptureAttemptToken) {
        if pendingSuccessfulSaveAttempt == attempt {
            pendingSuccessfulSaveAttempt = nil
            preparedReview = nil
            semanticGuidance = []
            operationalGuidance = []
            dispatch(.saveSucceeded(attempt: attempt))
            return
        }
        preparedReview = nil
        semanticGuidance = []
        operationalGuidance = []
        dispatch(.cleanupCompleted(attempt: attempt))
    }

    private var cleanupAttempt: RoomCaptureAttemptToken? {
        if let pendingSuccessfulSaveAttempt, state.phase == .saving {
            return pendingSuccessfulSaveAttempt
        }
        if state.phase == .discarding {
            return state.invalidatedAttemptToken
        }
        return nil
    }

    private func populateEditableMetadata(from metadata: RoomMetadata) {
        roomName = metadata.customName
        manualLocation = metadata.manualLocation
        notes = metadata.notes
        tagsText = metadata.tags.joined(separator: ", ")
    }

    private func editedCommitForSaving() -> RoomInitialCaptureCommit? {
        guard var review = preparedReview else { return nil }
        review.commit.draft.metadata.customName = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        review.commit.draft.metadata.manualLocation = manualLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        review.commit.draft.metadata.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        review.commit.draft.metadata.tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        review.commit.draft.metadata.optionalGPS = capturedGPS
        return review.commit
    }

    /// Pure, deterministic presentation seam covered by coordinator tests.
    /// It uses categorical guidance labels only; no numeric confidence or
    /// geometric-accuracy interpretation enters the UI.
    static func mergedGuidance(
        semantic: [RoomCaptureGuidance],
        operational: [RoomCaptureGuidance]
    ) -> [String] {
        Array(Set(semantic + operational))
            .sorted { $0.rawValue < $1.rawValue }
            .map(\.rawValue)
    }

    private func updateGuidance() {
        var derivedOperational: [RoomCaptureGuidance] = []
        switch state.coachingInstruction {
        case .normal, .unknown:
            break
        case .turnOnLight:
            derivedOperational.append(.poorLightingHeuristic)
        case .moveCloseToWall, .moveAwayFromWall, .slowDown, .lowTexture:
            derivedOperational.append(.roomPlanCoaching)
        }
        switch state.trackingQuality {
        case .limited:
            derivedOperational.append(.trackingLimited)
        case .notAvailable:
            derivedOperational.append(.trackingLost)
        case .normal, .unknown:
            break
        }
        qualitativeGuidance = Self.mergedGuidance(
            semantic: semanticGuidance,
            operational: operationalGuidance + derivedOperational
        )
    }

    private func isActive(
        _ attempt: RoomCaptureAttemptToken,
        phase: RoomCapturePhase
    ) -> Bool {
        state.attemptToken == attempt && state.phase == phase
    }

    private func isActivePhotoRequest(
        _ attempt: RoomCaptureAttemptToken,
        requestID: RoomReferencePhotoRequestID
    ) -> Bool {
        state.attemptToken == attempt
            && state.phase == .scanning
            && state.referencePhotoRequestID == requestID
    }

    private func acceptsLiveSnapshot(in phase: RoomCapturePhase) -> Bool {
        switch phase {
        case .starting, .scanning, .stopping, .processing:
            return true
        case .preflight, .requestingCamera, .ready, .review, .saving, .saved,
             .failed, .discarding, .discarded, .cancelled:
            return false
        }
    }

    private func acceptsOperationalObservation(in phase: RoomCapturePhase) -> Bool {
        switch phase {
        case .starting, .scanning, .stopping, .processing:
            return true
        case .preflight, .requestingCamera, .ready, .review, .saving, .saved,
             .failed, .discarding, .discarded, .cancelled:
            return false
        }
    }

    private func isCleanupEffect(_ effect: RoomCaptureEffect) -> Bool {
        if case .cleanupScratch = effect {
            return true
        }
        return false
    }

    private func effectTaskKind(for effect: RoomCaptureEffect) -> EffectTaskKind {
        switch effect {
        case .requestCameraAuthorization:
            return .cameraAuthorization
        case .requestGPSAuthorization:
            return .gpsAuthorization
        case .cancelGPSAuthorization:
            return .gpsCancellation
        case .startCapture:
            return .start
        case .stopCapture:
            return .stop
        case .terminateCapture:
            return .cleanup
        case .processCapture:
            return .processing
        case .cancelProcessing:
            return .cleanup
        case .requestReferencePhoto:
            return .referencePhoto
        case .persistCapture:
            return .persistence
        case .cleanupScratch:
            return .cleanup
        }
    }
}
