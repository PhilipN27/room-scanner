import Foundation

/// App-owned attempt identity. Every reducer event and effect carries this
/// token so callbacks from an invalidated capture cannot advance a new state.
public struct RoomCaptureAttemptToken: Codable, Sendable, Equatable, Hashable {
    public var value: String

    public init(_ value: String) {
        self.value = value
    }
}

public enum RoomCapturePhase: String, Codable, Sendable, Equatable {
    case preflight
    case requestingCamera
    case ready
    case starting
    case scanning
    case stopping
    case processing
    case review
    case saving
    case saved
    case failed
    case discarding
    case discarded
    case cancelled
}

public enum RoomCapturePermission: String, Codable, Sendable, Equatable {
    case unknown
    case authorized
    case denied
}

public enum RoomCaptureFailure: String, Codable, Sendable, Equatable {
    case cameraDenied
    case startFailed
    case processingFailed
    case captureTerminated
    case saveFailed
}

/// Foundation mirror of `RoomCaptureSession.Instruction`. It is coaching only,
/// never a measurement-quality or geometric-accuracy value.
public enum RoomCaptureCoachingInstruction: String, Codable, Sendable, Equatable {
    case normal
    case moveCloseToWall
    case moveAwayFromWall
    case turnOnLight
    case slowDown
    case lowTexture
    case unknown
}

/// Foundation mirror of `RoomCaptureSession.CaptureError`. The `unknown` case
/// preserves forward-compatible adapter input without fabricating an SDK case.
public enum RoomCaptureTerminationReason: String, Codable, Sendable, Equatable {
    case deviceNotSupported
    case deviceTooHot
    case exceedSceneSizeLimit
    case invalidARConfiguration
    case worldTrackingFailure
    case internalError
    case unknown
}

/// Foundation mirror of the high-level `ARCamera.TrackingState` state. It is
/// operational state, not a claim about survey or geometric accuracy.
public enum RoomTrackingQuality: String, Codable, Sendable, Equatable {
    case notAvailable
    case limited
    case normal
    case unknown
}

/// Foundation mirror of `ARCamera.TrackingState.Reason` for a limited state.
public enum RoomTrackingLimitedReason: String, Codable, Sendable, Equatable {
    case initializing
    case relocalizing
    case excessiveMotion
    case insufficientFeatures
    case unknown
}

/// Per-attempt reference-photo correlation. A single request can be in flight
/// so an old callback cannot be mistaken for a newly requested photo.
public struct RoomReferencePhotoRequestID: Codable, Sendable, Equatable, Hashable {
    public var value: String

    public init(_ value: String) {
        self.value = value
    }
}

/// Qualitative capture guidance only. None of these categories is a geometric
/// accuracy measurement or a substitute for a permanent disclaimer.
public enum RoomCaptureGuidance: String, Codable, Sendable, Equatable, Hashable {
    case roomPlanCoaching
    case lowClassificationConfidence
    case poorLightingHeuristic
    case trackingLimited
    case trackingLost
    case anotherPassHeuristic
}

public enum RoomCaptureEvent: Sendable, Equatable {
    case requestCamera(attempt: RoomCaptureAttemptToken)
    case cameraAuthorized(attempt: RoomCaptureAttemptToken)
    case cameraDenied(attempt: RoomCaptureAttemptToken)
    case requestGPSAuthorization(attempt: RoomCaptureAttemptToken)
    case gpsAuthorized(attempt: RoomCaptureAttemptToken)
    case gpsDenied(attempt: RoomCaptureAttemptToken)
    case coachingInstructionUpdated(
        attempt: RoomCaptureAttemptToken,
        instruction: RoomCaptureCoachingInstruction
    )
    case trackingUpdated(
        attempt: RoomCaptureAttemptToken,
        quality: RoomTrackingQuality,
        limitedReason: RoomTrackingLimitedReason?
    )
    case captureTerminated(
        attempt: RoomCaptureAttemptToken,
        reason: RoomCaptureTerminationReason
    )
    case startRequested(attempt: RoomCaptureAttemptToken)
    case didStart(attempt: RoomCaptureAttemptToken)
    case startFailed(attempt: RoomCaptureAttemptToken)
    case stopRequested(attempt: RoomCaptureAttemptToken)
    case didStop(attempt: RoomCaptureAttemptToken)
    case processingSucceeded(attempt: RoomCaptureAttemptToken)
    case processingFailed(attempt: RoomCaptureAttemptToken, retryable: Bool)
    case retryRequested(attempt: RoomCaptureAttemptToken)
    case requestReferencePhoto(
        attempt: RoomCaptureAttemptToken,
        requestID: RoomReferencePhotoRequestID
    )
    case referencePhotoSucceeded(
        attempt: RoomCaptureAttemptToken,
        requestID: RoomReferencePhotoRequestID
    )
    case referencePhotoFailed(
        attempt: RoomCaptureAttemptToken,
        requestID: RoomReferencePhotoRequestID
    )
    case saveRequested(attempt: RoomCaptureAttemptToken)
    case saveSucceeded(attempt: RoomCaptureAttemptToken)
    case saveFailed(attempt: RoomCaptureAttemptToken)
    case discardRequested(attempt: RoomCaptureAttemptToken)
    case cancelRequested(attempt: RoomCaptureAttemptToken)
    case cleanupCompleted(attempt: RoomCaptureAttemptToken)
    case guidanceUpdated(attempt: RoomCaptureAttemptToken, guidance: [RoomCaptureGuidance])
}

public enum RoomCaptureEffect: Sendable, Equatable {
    case requestCameraAuthorization(attempt: RoomCaptureAttemptToken)
    case requestGPSAuthorization(attempt: RoomCaptureAttemptToken)
    /// Cancels only the matching one-shot location request. This is emitted
    /// when a live capture terminates as well as during terminal cleanup, so a
    /// stale GPS callback cannot keep a failed attempt alive.
    case cancelGPSAuthorization(attempt: RoomCaptureAttemptToken)
    case startCapture(attempt: RoomCaptureAttemptToken)
    case stopCapture(attempt: RoomCaptureAttemptToken)
    /// Idempotently pause/end the live capture session before scratch cleanup.
    case terminateCapture(attempt: RoomCaptureAttemptToken)
    case processCapture(attempt: RoomCaptureAttemptToken)
    /// Cancel post-stop processing; stale completion callbacks remain ignored.
    case cancelProcessing(attempt: RoomCaptureAttemptToken)
    case requestReferencePhoto(
        attempt: RoomCaptureAttemptToken,
        requestID: RoomReferencePhotoRequestID
    )
    case persistCapture(attempt: RoomCaptureAttemptToken)
    case cleanupScratch(attempt: RoomCaptureAttemptToken)
}

public struct RoomCaptureState: Sendable, Equatable {
    public static let nonSurveyAccuracyDisclaimer =
        "Measurements are estimates, not survey-grade evidence."

    public var phase: RoomCapturePhase
    public var attemptToken: RoomCaptureAttemptToken?
    public var invalidatedAttemptToken: RoomCaptureAttemptToken?
    public var cameraPermission: RoomCapturePermission
    public var gpsPermission: RoomCapturePermission
    public var gpsRequestInFlight: Bool
    public var failure: RoomCaptureFailure?
    public var retryable: Bool
    public var guidance: [RoomCaptureGuidance]
    public var coachingInstruction: RoomCaptureCoachingInstruction
    public var captureTerminationReason: RoomCaptureTerminationReason?
    public var trackingQuality: RoomTrackingQuality
    public var trackingLimitedReason: RoomTrackingLimitedReason?
    public var referencePhotoRequestID: RoomReferencePhotoRequestID?
    public var referencePhotoCount: Int
    public var referencePhotoLastRequestFailed: Bool
    public var hasStagedEvidence: Bool
    public var pendingTerminalPhase: RoomCapturePhase?
    public var accuracyDisclaimer: String

    public init(
        phase: RoomCapturePhase = .preflight,
        attemptToken: RoomCaptureAttemptToken?,
        invalidatedAttemptToken: RoomCaptureAttemptToken? = nil,
        cameraPermission: RoomCapturePermission = .unknown,
        gpsPermission: RoomCapturePermission = .unknown,
        gpsRequestInFlight: Bool = false,
        failure: RoomCaptureFailure? = nil,
        retryable: Bool = false,
        guidance: [RoomCaptureGuidance] = [],
        coachingInstruction: RoomCaptureCoachingInstruction = .unknown,
        captureTerminationReason: RoomCaptureTerminationReason? = nil,
        trackingQuality: RoomTrackingQuality = .unknown,
        trackingLimitedReason: RoomTrackingLimitedReason? = nil,
        referencePhotoRequestID: RoomReferencePhotoRequestID? = nil,
        referencePhotoCount: Int = 0,
        referencePhotoLastRequestFailed: Bool = false,
        hasStagedEvidence: Bool = false,
        pendingTerminalPhase: RoomCapturePhase? = nil,
        accuracyDisclaimer: String = RoomCaptureState.nonSurveyAccuracyDisclaimer
    ) {
        self.phase = phase
        self.attemptToken = attemptToken
        self.invalidatedAttemptToken = invalidatedAttemptToken
        self.cameraPermission = cameraPermission
        self.gpsPermission = gpsPermission
        self.gpsRequestInFlight = gpsRequestInFlight
        self.failure = failure
        self.retryable = retryable
        self.guidance = guidance
        self.coachingInstruction = coachingInstruction
        self.captureTerminationReason = captureTerminationReason
        self.trackingQuality = trackingQuality
        self.trackingLimitedReason = trackingLimitedReason
        self.referencePhotoRequestID = referencePhotoRequestID
        self.referencePhotoCount = referencePhotoCount
        self.referencePhotoLastRequestFailed = referencePhotoLastRequestFailed
        self.hasStagedEvidence = hasStagedEvidence
        self.pendingTerminalPhase = pendingTerminalPhase
        self.accuracyDisclaimer = accuracyDisclaimer
    }

    /// GPS permission is optional; manual location remains available even when
    /// it is denied so a reviewed capture can still be saved.
    public var manualLocationAvailable: Bool {
        true
    }

    public var canSave: Bool {
        phase == .review
            && attemptToken != nil
            && referencePhotoRequestID == nil
            && !gpsRequestInFlight
    }

    /// A Save accepted from review is deliberately an irrevocable transition.
    /// The persistence effect may already be promoting a package, so accepting
    /// Discard or Cancel during `.saving` would falsely imply that an
    /// in-flight filesystem transaction can be undone. Platform UI must hide
    /// or disable those actions while saving; a save failure returns to review,
    /// where cleanup is available again.
    fileprivate var acceptsUncommittedAttemptEvents: Bool {
        switch phase {
        case .preflight, .requestingCamera, .ready, .starting, .scanning,
             .stopping, .processing, .review, .failed:
            return true
        case .saving, .saved, .discarding, .discarded, .cancelled:
            return false
        }
    }
}

public struct RoomCaptureTransition: Sendable, Equatable {
    public var state: RoomCaptureState
    public var effects: [RoomCaptureEffect]

    public init(state: RoomCaptureState, effects: [RoomCaptureEffect] = []) {
        self.state = state
        self.effects = effects
    }
}

/// Pure capture flow reducer. It has no camera, RoomPlan, filesystem, or UI
/// dependency; platform adapters must execute effects only for the active token.
public enum RoomCaptureReducer {
    public static func reduce(
        _ state: RoomCaptureState,
        event: RoomCaptureEvent
    ) -> RoomCaptureTransition {
        switch event {
        case let .requestCamera(attempt):
            guard isActive(attempt, in: state), state.phase == .preflight else {
                return unchanged(state)
            }
            var next = state
            next.phase = .requestingCamera
            return RoomCaptureTransition(
                state: next,
                effects: [.requestCameraAuthorization(attempt: attempt)]
            )

        case let .cameraAuthorized(attempt):
            guard isActive(attempt, in: state), state.phase == .requestingCamera else {
                return unchanged(state)
            }
            var next = state
            next.phase = .ready
            next.cameraPermission = .authorized
            next.failure = nil
            return RoomCaptureTransition(state: next)

        case let .cameraDenied(attempt):
            guard isActive(attempt, in: state), state.phase == .requestingCamera else {
                return unchanged(state)
            }
            var next = state
            next.phase = .failed
            next.cameraPermission = .denied
            next.failure = .cameraDenied
            next.retryable = false
            return RoomCaptureTransition(state: next)

        case let .requestGPSAuthorization(attempt):
            guard
                isActive(attempt, in: state),
                state.acceptsUncommittedAttemptEvents,
                state.gpsPermission == .unknown,
                !state.gpsRequestInFlight
            else {
                return unchanged(state)
            }
            var next = state
            next.gpsRequestInFlight = true
            return RoomCaptureTransition(
                state: next,
                effects: [.requestGPSAuthorization(attempt: attempt)]
            )

        case let .gpsAuthorized(attempt):
            guard
                isActive(attempt, in: state),
                state.acceptsUncommittedAttemptEvents,
                state.gpsRequestInFlight
            else {
                return unchanged(state)
            }
            var next = state
            next.gpsPermission = .authorized
            next.gpsRequestInFlight = false
            return RoomCaptureTransition(state: next)

        case let .gpsDenied(attempt):
            guard
                isActive(attempt, in: state),
                state.acceptsUncommittedAttemptEvents,
                state.gpsRequestInFlight
            else {
                return unchanged(state)
            }
            var next = state
            next.gpsPermission = .denied
            next.gpsRequestInFlight = false
            return RoomCaptureTransition(state: next)

        case let .coachingInstructionUpdated(attempt, instruction):
            guard isActive(attempt, in: state), state.acceptsUncommittedAttemptEvents else {
                return unchanged(state)
            }
            var next = state
            next.coachingInstruction = instruction
            return RoomCaptureTransition(state: next)

        case let .trackingUpdated(attempt, quality, limitedReason):
            guard isActive(attempt, in: state), state.acceptsUncommittedAttemptEvents else {
                return unchanged(state)
            }
            var next = state
            next.trackingQuality = quality
            next.trackingLimitedReason = quality == .limited
                ? limitedReason ?? .unknown
                : nil
            return RoomCaptureTransition(state: next)

        case let .captureTerminated(attempt, reason):
            guard
                isActive(attempt, in: state),
                isLiveCapturePhase(state.phase)
            else {
                return unchanged(state)
            }
            let gpsWasPending = state.gpsRequestInFlight
            var next = state
            next.phase = .failed
            next.failure = .captureTerminated
            next.captureTerminationReason = reason
            next.retryable = false
            next.gpsRequestInFlight = false
            next.referencePhotoRequestID = nil
            return RoomCaptureTransition(
                state: next,
                effects: gpsWasPending ? [.cancelGPSAuthorization(attempt: attempt)] : []
            )

        case let .startRequested(attempt):
            guard
                isActive(attempt, in: state),
                state.phase == .ready,
                state.cameraPermission == .authorized
            else {
                return unchanged(state)
            }
            var next = state
            next.phase = .starting
            return RoomCaptureTransition(
                state: next,
                effects: [.startCapture(attempt: attempt)]
            )

        case let .didStart(attempt):
            guard isActive(attempt, in: state), state.phase == .starting else {
                return unchanged(state)
            }
            var next = state
            next.phase = .scanning
            return RoomCaptureTransition(state: next)

        case let .startFailed(attempt):
            guard isActive(attempt, in: state), state.phase == .starting else {
                return unchanged(state)
            }
            var next = state
            next.phase = .failed
            next.failure = .startFailed
            next.retryable = false
            return RoomCaptureTransition(state: next)

        case let .stopRequested(attempt):
            guard
                isActive(attempt, in: state),
                state.phase == .scanning,
                state.referencePhotoRequestID == nil
            else {
                return unchanged(state)
            }
            var next = state
            next.phase = .stopping
            return RoomCaptureTransition(
                state: next,
                effects: [.stopCapture(attempt: attempt)]
            )

        case let .didStop(attempt):
            guard isActive(attempt, in: state), state.phase == .stopping else {
                return unchanged(state)
            }
            var next = state
            next.phase = .processing
            next.hasStagedEvidence = true
            return RoomCaptureTransition(
                state: next,
                effects: [.processCapture(attempt: attempt)]
            )

        case let .processingSucceeded(attempt):
            guard isActive(attempt, in: state), state.phase == .processing else {
                return unchanged(state)
            }
            var next = state
            next.phase = .review
            next.failure = nil
            next.retryable = false
            next.hasStagedEvidence = true
            return RoomCaptureTransition(state: next)

        case let .processingFailed(attempt, retryable):
            guard isActive(attempt, in: state), state.phase == .processing else {
                return unchanged(state)
            }
            var next = state
            next.phase = .failed
            next.failure = .processingFailed
            next.retryable = retryable
            next.hasStagedEvidence = true
            return RoomCaptureTransition(state: next)

        case let .retryRequested(attempt):
            guard
                isActive(attempt, in: state),
                state.phase == .failed,
                state.failure == .processingFailed,
                state.retryable
            else {
                return unchanged(state)
            }
            var next = state
            next.phase = .processing
            next.failure = nil
            next.retryable = false
            return RoomCaptureTransition(
                state: next,
                effects: [.processCapture(attempt: attempt)]
            )

        case let .requestReferencePhoto(attempt, requestID):
            // Review follows a paused RoomPlan/AR session. A reference photo
            // therefore belongs only to the app-owned live scanning session;
            // the reducer never permits a review-time second camera session.
            guard
                isActive(attempt, in: state),
                state.phase == .scanning,
                state.referencePhotoRequestID == nil
            else {
                return unchanged(state)
            }
            var next = state
            next.referencePhotoRequestID = requestID
            next.referencePhotoLastRequestFailed = false
            return RoomCaptureTransition(
                state: next,
                effects: [.requestReferencePhoto(attempt: attempt, requestID: requestID)]
            )

        case let .referencePhotoSucceeded(attempt, requestID):
            guard
                isActive(attempt, in: state),
                state.phase == .scanning,
                state.referencePhotoRequestID == requestID
            else {
                return unchanged(state)
            }
            var next = state
            next.referencePhotoRequestID = nil
            next.referencePhotoCount += 1
            next.referencePhotoLastRequestFailed = false
            return RoomCaptureTransition(state: next)

        case let .referencePhotoFailed(attempt, requestID):
            guard
                isActive(attempt, in: state),
                state.phase == .scanning,
                state.referencePhotoRequestID == requestID
            else {
                return unchanged(state)
            }
            var next = state
            next.referencePhotoRequestID = nil
            next.referencePhotoLastRequestFailed = true
            return RoomCaptureTransition(state: next)

        case let .saveRequested(attempt):
            guard
                isActive(attempt, in: state),
                state.phase == .review,
                state.referencePhotoRequestID == nil,
                !state.gpsRequestInFlight
            else {
                return unchanged(state)
            }
            var next = state
            next.phase = .saving
            return RoomCaptureTransition(
                state: next,
                effects: [.persistCapture(attempt: attempt)]
            )

        case let .saveSucceeded(attempt):
            guard isActive(attempt, in: state), state.phase == .saving else {
                return unchanged(state)
            }
            var next = state
            next.phase = .saved
            next.hasStagedEvidence = false
            next.failure = nil
            next.retryable = false
            return RoomCaptureTransition(state: next)

        case let .saveFailed(attempt):
            guard isActive(attempt, in: state), state.phase == .saving else {
                return unchanged(state)
            }
            var next = state
            next.phase = .review
            next.failure = .saveFailed
            next.retryable = false
            // Scratch evidence remains available for another explicit Save.
            next.hasStagedEvidence = true
            return RoomCaptureTransition(state: next)

        case let .discardRequested(attempt):
            return discard(state, attempt: attempt, terminalPhase: .discarded)

        case let .cancelRequested(attempt):
            return discard(state, attempt: attempt, terminalPhase: .cancelled)

        case let .cleanupCompleted(attempt):
            guard
                state.phase == .discarding,
                state.invalidatedAttemptToken == attempt
            else {
                return unchanged(state)
            }
            var next = state
            next.phase = state.pendingTerminalPhase ?? .discarded
            next.pendingTerminalPhase = nil
            next.hasStagedEvidence = false
            return RoomCaptureTransition(state: next)

        case let .guidanceUpdated(attempt, guidance):
            guard isActive(attempt, in: state), state.acceptsUncommittedAttemptEvents else {
                return unchanged(state)
            }
            var next = state
            next.guidance = Array(Set(guidance)).sorted { $0.rawValue < $1.rawValue }
            return RoomCaptureTransition(state: next)
        }
    }

    private static func discard(
        _ state: RoomCaptureState,
        attempt: RoomCaptureAttemptToken,
        terminalPhase: RoomCapturePhase
    ) -> RoomCaptureTransition {
        guard isActive(attempt, in: state), state.acceptsUncommittedAttemptEvents else {
            return unchanged(state)
        }
        var next = state
        next.phase = .discarding
        next.invalidatedAttemptToken = attempt
        next.attemptToken = nil
        next.pendingTerminalPhase = terminalPhase
        next.retryable = false
        next.gpsRequestInFlight = false
        next.referencePhotoRequestID = nil

        var effects: [RoomCaptureEffect] = []
        if state.gpsRequestInFlight {
            effects.append(.cancelGPSAuthorization(attempt: attempt))
        }
        switch state.phase {
        case .starting, .scanning, .stopping:
            effects.append(.terminateCapture(attempt: attempt))
        case .processing:
            // Stopping is intentionally idempotent: adapters may already have
            // received `stopCapture`, but must not leave a session alive while
            // cancelling its processor.
            effects.append(.terminateCapture(attempt: attempt))
            effects.append(.cancelProcessing(attempt: attempt))
        case .preflight, .requestingCamera, .ready, .review, .failed:
            break
        case .saving, .saved, .discarding, .discarded, .cancelled:
            // The guard above excludes these phases. Keeping this exhaustive
            // documents that `.saving` remains intentionally non-cancelable.
            break
        }
        effects.append(.cleanupScratch(attempt: attempt))
        return RoomCaptureTransition(
            state: next,
            effects: effects
        )
    }

    private static func isActive(
        _ attempt: RoomCaptureAttemptToken,
        in state: RoomCaptureState
    ) -> Bool {
        state.attemptToken == attempt
    }

    private static func isLiveCapturePhase(_ phase: RoomCapturePhase) -> Bool {
        switch phase {
        case .starting, .scanning, .stopping:
            return true
        case .preflight, .requestingCamera, .ready, .processing, .review,
             .saving, .saved, .failed, .discarding, .discarded, .cancelled:
            return false
        }
    }

    private static func unchanged(_ state: RoomCaptureState) -> RoomCaptureTransition {
        RoomCaptureTransition(state: state)
    }
}
