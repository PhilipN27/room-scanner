import XCTest
@testable import RoomScanCore

final class CaptureReducerTests: XCTestCase {
    func testStaleCallbackIsIgnoredAndDoesNotAdvanceAttempt() {
        let active = RoomCaptureAttemptToken("attempt-active")
        let stale = RoomCaptureAttemptToken("attempt-stale")
        var state = RoomCaptureState(attemptToken: active)

        state = RoomCaptureReducer.reduce(
            state,
            event: .requestCamera(attempt: active)
        ).state
        state = RoomCaptureReducer.reduce(
            state,
            event: .cameraAuthorized(attempt: active)
        ).state

        let transition = RoomCaptureReducer.reduce(
            state,
            event: .startRequested(attempt: stale)
        )

        XCTAssertEqual(transition.state, state)
        XCTAssertTrue(transition.effects.isEmpty)
        XCTAssertEqual(transition.state.phase, .ready)
    }

    func testStartStopAndSaveAreIdempotentAndSaveIsLegalOnlyFromReview() {
        let token = RoomCaptureAttemptToken("attempt-idempotent")
        var state = RoomCaptureState(attemptToken: token)

        let illegalSave = RoomCaptureReducer.reduce(
            state,
            event: .saveRequested(attempt: token)
        )
        XCTAssertEqual(illegalSave.state, state)
        XCTAssertTrue(illegalSave.effects.isEmpty)

        state = RoomCaptureReducer.reduce(
            state,
            event: .requestCamera(attempt: token)
        ).state
        state = RoomCaptureReducer.reduce(
            state,
            event: .cameraAuthorized(attempt: token)
        ).state

        let start = RoomCaptureReducer.reduce(
            state,
            event: .startRequested(attempt: token)
        )
        XCTAssertEqual(start.effects, [.startCapture(attempt: token)])
        let duplicateStart = RoomCaptureReducer.reduce(
            start.state,
            event: .startRequested(attempt: token)
        )
        XCTAssertEqual(duplicateStart.state, start.state)
        XCTAssertTrue(duplicateStart.effects.isEmpty)

        state = RoomCaptureReducer.reduce(
            start.state,
            event: .didStart(attempt: token)
        ).state
        let stop = RoomCaptureReducer.reduce(
            state,
            event: .stopRequested(attempt: token)
        )
        XCTAssertEqual(stop.effects, [.stopCapture(attempt: token)])
        let duplicateStop = RoomCaptureReducer.reduce(
            stop.state,
            event: .stopRequested(attempt: token)
        )
        XCTAssertEqual(duplicateStop.state, stop.state)
        XCTAssertTrue(duplicateStop.effects.isEmpty)

        let processing = RoomCaptureReducer.reduce(
            stop.state,
            event: .didStop(attempt: token)
        )
        XCTAssertEqual(processing.effects, [.processCapture(attempt: token)])
        state = RoomCaptureReducer.reduce(
            processing.state,
            event: .processingSucceeded(attempt: token)
        ).state
        XCTAssertEqual(state.phase, .review)

        let save = RoomCaptureReducer.reduce(
            state,
            event: .saveRequested(attempt: token)
        )
        XCTAssertEqual(save.effects, [.persistCapture(attempt: token)])
        let duplicateSave = RoomCaptureReducer.reduce(
            save.state,
            event: .saveRequested(attempt: token)
        )
        XCTAssertEqual(duplicateSave.state, save.state)
        XCTAssertTrue(duplicateSave.effects.isEmpty)

        let saved = RoomCaptureReducer.reduce(
            save.state,
            event: .saveSucceeded(attempt: token)
        )
        XCTAssertEqual(saved.state.phase, .saved)
        let saveAfterCompletion = RoomCaptureReducer.reduce(
            saved.state,
            event: .saveRequested(attempt: token)
        )
        XCTAssertTrue(saveAfterCompletion.effects.isEmpty)

        let saveFailure = RoomCaptureReducer.reduce(
            save.state,
            event: .saveFailed(attempt: token)
        )
        XCTAssertEqual(saveFailure.state.phase, .review)
        XCTAssertTrue(saveFailure.state.hasStagedEvidence)
        let retrySave = RoomCaptureReducer.reduce(
            saveFailure.state,
            event: .saveRequested(attempt: token)
        )
        XCTAssertEqual(retrySave.effects, [.persistCapture(attempt: token)])
    }

    func testCameraDenialBlocksStartAndGPSDenialKeepsManualLocationAndSaveAvailable() {
        let deniedToken = RoomCaptureAttemptToken("attempt-camera-denied")
        var deniedState = RoomCaptureState(attemptToken: deniedToken)
        deniedState = RoomCaptureReducer.reduce(
            deniedState,
            event: .requestCamera(attempt: deniedToken)
        ).state
        deniedState = RoomCaptureReducer.reduce(
            deniedState,
            event: .cameraDenied(attempt: deniedToken)
        ).state

        XCTAssertEqual(deniedState.phase, .failed)
        XCTAssertEqual(deniedState.failure, .cameraDenied)
        let blockedStart = RoomCaptureReducer.reduce(
            deniedState,
            event: .startRequested(attempt: deniedToken)
        )
        XCTAssertTrue(blockedStart.effects.isEmpty)

        let token = RoomCaptureAttemptToken("attempt-gps-denied")
        var state = RoomCaptureState(attemptToken: token)
        state = RoomCaptureReducer.reduce(state, event: .requestCamera(attempt: token)).state
        state = RoomCaptureReducer.reduce(state, event: .cameraAuthorized(attempt: token)).state
        let gpsRequest = RoomCaptureReducer.reduce(
            state,
            event: .requestGPSAuthorization(attempt: token)
        )
        XCTAssertEqual(gpsRequest.effects, [.requestGPSAuthorization(attempt: token)])
        state = gpsRequest.state
        state = RoomCaptureReducer.reduce(state, event: .gpsDenied(attempt: token)).state
        state = RoomCaptureReducer.reduce(state, event: .startRequested(attempt: token)).state
        state = RoomCaptureReducer.reduce(state, event: .didStart(attempt: token)).state
        state = RoomCaptureReducer.reduce(state, event: .stopRequested(attempt: token)).state
        state = RoomCaptureReducer.reduce(state, event: .didStop(attempt: token)).state
        state = RoomCaptureReducer.reduce(state, event: .processingSucceeded(attempt: token)).state

        XCTAssertEqual(state.gpsPermission, .denied)
        XCTAssertTrue(state.manualLocationAvailable)
        XCTAssertTrue(state.canSave)
    }

    func testAppleMirrorStateCarriesQualitativeCoachingTerminationAndTracking() {
        let token = RoomCaptureAttemptToken("attempt-framework-mirrors")
        var state = RoomCaptureState(attemptToken: token)

        let coaching = RoomCaptureReducer.reduce(
            state,
            event: .coachingInstructionUpdated(attempt: token, instruction: .turnOnLight)
        )
        XCTAssertEqual(coaching.state.coachingInstruction, .turnOnLight)
        state = coaching.state

        let limited = RoomCaptureReducer.reduce(
            state,
            event: .trackingUpdated(
                attempt: token,
                quality: .limited,
                limitedReason: .insufficientFeatures
            )
        )
        XCTAssertEqual(limited.state.trackingQuality, .limited)
        XCTAssertEqual(limited.state.trackingLimitedReason, .insufficientFeatures)
        state = limited.state

        let normal = RoomCaptureReducer.reduce(
            state,
            event: .trackingUpdated(
                attempt: token,
                quality: .normal,
                limitedReason: .excessiveMotion
            )
        )
        XCTAssertEqual(normal.state.trackingQuality, .normal)
        XCTAssertNil(normal.state.trackingLimitedReason)

        let terminated = RoomCaptureReducer.reduce(
            RoomCaptureState(phase: .scanning, attemptToken: token),
            event: .captureTerminated(attempt: token, reason: .deviceTooHot)
        )
        XCTAssertEqual(terminated.state.phase, .failed)
        XCTAssertEqual(terminated.state.failure, .captureTerminated)
        XCTAssertEqual(terminated.state.captureTerminationReason, .deviceTooHot)
        XCTAssertTrue(terminated.effects.isEmpty)
    }

    func testCaptureTerminationIsAcceptedOnlyWhileCaptureIsLive() {
        let token = RoomCaptureAttemptToken("attempt-live-termination")
        for phase in [RoomCapturePhase.starting, .scanning, .stopping] {
            let live = RoomCaptureState(phase: phase, attemptToken: token)
            let transition = RoomCaptureReducer.reduce(
                live,
                event: .captureTerminated(attempt: token, reason: .worldTrackingFailure)
            )
            XCTAssertEqual(transition.state.phase, .failed, "phase \(phase)")
            XCTAssertEqual(transition.state.failure, .captureTerminated, "phase \(phase)")
            XCTAssertEqual(
                transition.state.captureTerminationReason,
                .worldTrackingFailure,
                "phase \(phase)"
            )
        }

        let review = RoomCaptureState(
            phase: .review,
            attemptToken: token,
            hasStagedEvidence: true
        )
        let lateTermination = RoomCaptureReducer.reduce(
            review,
            event: .captureTerminated(attempt: token, reason: .worldTrackingFailure)
        )
        XCTAssertEqual(lateTermination.state, review)
        XCTAssertTrue(lateTermination.effects.isEmpty)
    }

    func testCaptureTerminationCancelsPendingGPSBeforeShowingFailure() {
        let token = RoomCaptureAttemptToken("attempt-termination-gps")
        var scanning = RoomCaptureState(phase: .scanning, attemptToken: token)
        scanning.gpsRequestInFlight = true

        let terminated = RoomCaptureReducer.reduce(
            scanning,
            event: .captureTerminated(attempt: token, reason: .deviceTooHot)
        )

        XCTAssertEqual(terminated.state.phase, .failed)
        XCTAssertFalse(terminated.state.gpsRequestInFlight)
        XCTAssertEqual(
            terminated.effects,
            [.cancelGPSAuthorization(attempt: token)]
        )
    }

    func testGPSAndReferencePhotoRequestsAreTokenizedAndSingleInFlight() {
        let token = RoomCaptureAttemptToken("attempt-request-tokens")
        let stale = RoomCaptureAttemptToken("attempt-stale")
        var state = RoomCaptureState(phase: .review, attemptToken: token)

        let gpsRequest = RoomCaptureReducer.reduce(
            state,
            event: .requestGPSAuthorization(attempt: token)
        )
        XCTAssertEqual(gpsRequest.effects, [.requestGPSAuthorization(attempt: token)])
        XCTAssertTrue(gpsRequest.state.gpsRequestInFlight)
        let duplicateGPS = RoomCaptureReducer.reduce(
            gpsRequest.state,
            event: .requestGPSAuthorization(attempt: token)
        )
        XCTAssertEqual(duplicateGPS.state, gpsRequest.state)
        XCTAssertTrue(duplicateGPS.effects.isEmpty)
        let staleGPS = RoomCaptureReducer.reduce(
            gpsRequest.state,
            event: .gpsAuthorized(attempt: stale)
        )
        XCTAssertEqual(staleGPS.state, gpsRequest.state)
        state = RoomCaptureReducer.reduce(
            gpsRequest.state,
            event: .gpsAuthorized(attempt: token)
        ).state
        XCTAssertEqual(state.gpsPermission, .authorized)
        XCTAssertFalse(state.gpsRequestInFlight)

        let photoState = RoomCaptureState(phase: .scanning, attemptToken: token)
        let firstPhoto = RoomReferencePhotoRequestID("reference-photo-001")
        let secondPhoto = RoomReferencePhotoRequestID("reference-photo-002")
        let requestPhoto = RoomCaptureReducer.reduce(
            photoState,
            event: .requestReferencePhoto(attempt: token, requestID: firstPhoto)
        )
        XCTAssertEqual(
            requestPhoto.effects,
            [.requestReferencePhoto(attempt: token, requestID: firstPhoto)]
        )
        XCTAssertEqual(requestPhoto.state.referencePhotoRequestID, firstPhoto)
        let secondWhileBusy = RoomCaptureReducer.reduce(
            requestPhoto.state,
            event: .requestReferencePhoto(attempt: token, requestID: secondPhoto)
        )
        XCTAssertEqual(secondWhileBusy.state, requestPhoto.state)
        XCTAssertTrue(secondWhileBusy.effects.isEmpty)
        let stopWhileBusy = RoomCaptureReducer.reduce(
            requestPhoto.state,
            event: .stopRequested(attempt: token)
        )
        XCTAssertTrue(stopWhileBusy.effects.isEmpty)

        let discardedPhoto = RoomCaptureReducer.reduce(
            requestPhoto.state,
            event: .discardRequested(attempt: token)
        )
        XCTAssertEqual(
            discardedPhoto.effects,
            [.terminateCapture(attempt: token), .cleanupScratch(attempt: token)]
        )
        let staleAfterDiscard = RoomCaptureReducer.reduce(
            discardedPhoto.state,
            event: .referencePhotoSucceeded(attempt: token, requestID: firstPhoto)
        )
        XCTAssertEqual(staleAfterDiscard.state, discardedPhoto.state)

        let completedPhoto = RoomCaptureReducer.reduce(
            requestPhoto.state,
            event: .referencePhotoSucceeded(attempt: token, requestID: firstPhoto)
        )
        XCTAssertNil(completedPhoto.state.referencePhotoRequestID)
        XCTAssertEqual(completedPhoto.state.referencePhotoCount, 1)
        XCTAssertFalse(completedPhoto.state.referencePhotoLastRequestFailed)
        let stopAfterPhoto = RoomCaptureReducer.reduce(
            completedPhoto.state,
            event: .stopRequested(attempt: token)
        )
        XCTAssertEqual(stopAfterPhoto.effects, [.stopCapture(attempt: token)])
        let stalePhoto = RoomCaptureReducer.reduce(
            completedPhoto.state,
            event: .referencePhotoSucceeded(attempt: token, requestID: firstPhoto)
        )
        XCTAssertEqual(stalePhoto.state, completedPhoto.state)

        let retryPhoto = RoomCaptureReducer.reduce(
            completedPhoto.state,
            event: .requestReferencePhoto(attempt: token, requestID: secondPhoto)
        )
        let failedPhoto = RoomCaptureReducer.reduce(
            retryPhoto.state,
            event: .referencePhotoFailed(attempt: token, requestID: secondPhoto)
        )
        XCTAssertNil(failedPhoto.state.referencePhotoRequestID)
        XCTAssertTrue(failedPhoto.state.referencePhotoLastRequestFailed)
    }

    func testRetryIsAvailableOnlyForRetryableProcessingFailureAndRetainsDisclaimer() {
        let token = RoomCaptureAttemptToken("attempt-retry")
        var state = RoomCaptureState(
            attemptToken: token,
            guidance: [.poorLightingHeuristic, .trackingLimited]
        )
        state = RoomCaptureReducer.reduce(state, event: .requestCamera(attempt: token)).state
        state = RoomCaptureReducer.reduce(state, event: .cameraAuthorized(attempt: token)).state
        state = RoomCaptureReducer.reduce(state, event: .startRequested(attempt: token)).state
        state = RoomCaptureReducer.reduce(state, event: .didStart(attempt: token)).state
        state = RoomCaptureReducer.reduce(state, event: .stopRequested(attempt: token)).state
        state = RoomCaptureReducer.reduce(state, event: .didStop(attempt: token)).state
        state = RoomCaptureReducer.reduce(
            state,
            event: .processingFailed(attempt: token, retryable: true)
        ).state

        XCTAssertEqual(state.phase, .failed)
        XCTAssertTrue(state.retryable)
        XCTAssertFalse(state.accuracyDisclaimer.isEmpty)
        XCTAssertTrue(state.guidance.contains(.poorLightingHeuristic))

        let retry = RoomCaptureReducer.reduce(
            state,
            event: .retryRequested(attempt: token)
        )
        XCTAssertEqual(retry.effects, [.processCapture(attempt: token)])
        XCTAssertEqual(retry.state.phase, .processing)

        let nonRetryable = RoomCaptureState(
            phase: .failed,
            attemptToken: token,
            failure: .processingFailed,
            retryable: false
        )
        let blockedRetry = RoomCaptureReducer.reduce(
            nonRetryable,
            event: .retryRequested(attempt: token)
        )
        XCTAssertEqual(blockedRetry.state, nonRetryable)
        XCTAssertTrue(blockedRetry.effects.isEmpty)
    }

    func testDiscardAndCancelInvalidatePreCommitAttemptsAndRequestPhaseAppropriateTeardown() {
        let token = RoomCaptureAttemptToken("attempt-discard")
        let scenarios: [(RoomCapturePhase, [RoomCaptureEffect])] = [
            (.preflight, [.cleanupScratch(attempt: token)]),
            (.requestingCamera, [.cleanupScratch(attempt: token)]),
            (.ready, [.cleanupScratch(attempt: token)]),
            (
                .starting,
                [.terminateCapture(attempt: token), .cleanupScratch(attempt: token)]
            ),
            (
                .scanning,
                [.terminateCapture(attempt: token), .cleanupScratch(attempt: token)]
            ),
            (
                .stopping,
                [.terminateCapture(attempt: token), .cleanupScratch(attempt: token)]
            ),
            (
                .processing,
                [
                    .terminateCapture(attempt: token),
                    .cancelProcessing(attempt: token),
                    .cleanupScratch(attempt: token),
                ]
            ),
            (.review, [.cleanupScratch(attempt: token)]),
            (.failed, [.cleanupScratch(attempt: token)]),
        ]

        for (phase, expectedEffects) in scenarios {
            let state = RoomCaptureState(
                phase: phase,
                attemptToken: token,
                hasStagedEvidence: phase == .processing || phase == .review
            )
            let requests: [(RoomCaptureEvent, RoomCapturePhase)] = [
                (.discardRequested(attempt: token), .discarded),
                (.cancelRequested(attempt: token), .cancelled),
            ]
            for (event, terminalPhase) in requests {
                let transition = RoomCaptureReducer.reduce(state, event: event)

                XCTAssertEqual(transition.state.phase, .discarding, "phase \(phase)")
                XCTAssertNil(transition.state.attemptToken, "phase \(phase)")
                XCTAssertEqual(transition.state.invalidatedAttemptToken, token, "phase \(phase)")
                XCTAssertEqual(transition.effects, expectedEffects, "phase \(phase)")
                XCTAssertFalse(
                    transition.effects.contains(.persistCapture(attempt: token)),
                    "discard/cancel must not request persistence from \(phase)"
                )
                let lateSave = RoomCaptureReducer.reduce(
                    transition.state,
                    event: .saveSucceeded(attempt: token)
                )
                XCTAssertEqual(lateSave.state, transition.state, "phase \(phase)")
                XCTAssertTrue(lateSave.effects.isEmpty, "phase \(phase)")

                let completed = RoomCaptureReducer.reduce(
                    transition.state,
                    event: .cleanupCompleted(attempt: token)
                )
                XCTAssertEqual(completed.state.phase, terminalPhase, "phase \(phase)")
                XCTAssertTrue(completed.effects.isEmpty)
            }
        }
    }

    func testDiscardAndCancelDuringSavingAreIgnoredAfterExplicitSaveConfirmation() {
        let token = RoomCaptureAttemptToken("attempt-saving-boundary")
        let saving = RoomCaptureState(
            phase: .saving,
            attemptToken: token,
            hasStagedEvidence: true
        )

        for event in [
            RoomCaptureEvent.discardRequested(attempt: token),
            .cancelRequested(attempt: token),
        ] {
            let transition = RoomCaptureReducer.reduce(saving, event: event)
            XCTAssertEqual(transition.state, saving)
            XCTAssertTrue(transition.effects.isEmpty)
            XCTAssertFalse(transition.effects.contains(.cleanupScratch(attempt: token)))
        }

        let returnedToReview = RoomCaptureReducer.reduce(
            saving,
            event: .saveFailed(attempt: token)
        )
        let discardAfterFailure = RoomCaptureReducer.reduce(
            returnedToReview.state,
            event: .discardRequested(attempt: token)
        )
        XCTAssertEqual(discardAfterFailure.state.phase, .discarding)
        XCTAssertEqual(discardAfterFailure.effects, [.cleanupScratch(attempt: token)])
    }

    func testSaveIsBlockedWhileOptionalGPSRequestIsInFlight() {
        let token = RoomCaptureAttemptToken("attempt-gps-save-race")
        let review = RoomCaptureState(
            phase: .review,
            attemptToken: token,
            gpsRequestInFlight: true,
            hasStagedEvidence: true
        )

        XCTAssertFalse(review.canSave)
        let transition = RoomCaptureReducer.reduce(
            review,
            event: .saveRequested(attempt: token)
        )

        XCTAssertEqual(transition.state, review)
        XCTAssertTrue(transition.effects.isEmpty)
    }
}
