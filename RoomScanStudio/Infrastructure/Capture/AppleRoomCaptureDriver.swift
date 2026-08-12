@preconcurrency import ARKit
@preconcurrency import RoomPlan
import CoreImage
import Foundation
import simd
import UIKit
import RoomScanCore

/// RoomPlan documents add/remove/change callbacks as partial room deltas. V1
/// deliberately treats only `didUpdate` as a complete snapshot, avoiding a
/// lossy or incorrect delta accumulator until that behavior has device proof.
enum AppleRoomPlanDelegatePayloadKind: Sendable, Equatable {
    case didAdd
    case didRemove
    case didChange
    case didUpdate
}

/// iOS-17 production RoomPlan adapter. One instance owns exactly one
/// RoomCaptureView (and through it exactly one ARSession/RoomCaptureSession)
/// for one app-coordinated capture attempt. The view renders the live camera
/// feed with RoomPlan's in-progress model overlay; its built-in
/// post-processing presentation is suppressed so `process()` remains the only
/// RoomBuilder path.
@MainActor
final class AppleRoomCaptureDriver: RoomCaptureDriving {
    var observationHandler: ((RoomCaptureDriverObservation) -> Void)?

    private let fileManager = FileManager.default
    private let captureView: RoomCaptureView
    private let arSession: ARSession
    private let roomCaptureSession: RoomCaptureSession
    private let delegateProxy: AppleRoomCaptureSessionDelegateProxy

    var liveCaptureView: UIView? { captureView }

    private var activeAttempt: RoomCaptureAttemptToken?
    private var activeWorkspace: RoomCaptureScratchWorkspace?
    private var coordinateSpaceEpochID: String?
    private var didIssueFinalStop = false
    private var sessionEndObservationGate = RoomCaptureSessionEndObservationGate()
    private var rawCapturedRoomData: CapturedRoomData?
    private var latestSnapshot: RoomSemanticSnapshot?
    private var bundleRecorder: RoomCaptureBundleRecorder?
    private var referencePhotoAssets: [(photo: RoomPhoto, asset: RoomAssetInput)] = []
    private var processingTask: Task<RoomCapturePreparedReview, Error>?
    private var photoTask: Task<Void, Error>?
    private var trackingTask: Task<Void, Never>?

    /// Cleanup waits at most two seconds for RoomPlan's documented asynchronous
    /// `didEndWith` completion. A timeout is deliberately surfaced as a
    /// retryable scratch-cleanup error; no continuation is allocated or leaked.
    private static let sessionEndWaitPollNanoseconds: UInt64 = 50_000_000
    private static let sessionEndWaitAttempts = 40
    private static let windowAttachWaitPollNanoseconds: UInt64 = 50_000_000
    private static let windowAttachWaitAttempts = 40

    init() {
        let captureView = RoomCaptureView(frame: .zero)
        self.captureView = captureView
        roomCaptureSession = captureView.captureSession
        arSession = captureView.captureSession.arSession
        delegateProxy = AppleRoomCaptureSessionDelegateProxy()
        delegateProxy.owner = self
        roomCaptureSession.delegate = delegateProxy
        captureView.delegate = delegateProxy
    }

    func start(
        attempt: RoomCaptureAttemptToken,
        workspace: RoomCaptureScratchWorkspace
    ) async throws {
        guard activeAttempt == nil || activeAttempt == attempt else {
            throw RoomCaptureDriverError.invalidAttempt
        }
        guard workspace.attempt == attempt else {
            throw RoomCaptureDriverError.invalidAttempt
        }

        activeAttempt = attempt
        activeWorkspace = workspace
        coordinateSpaceEpochID = "roomplan-epoch-\(attempt.value)"
        didIssueFinalStop = false
        sessionEndObservationGate.reset()
        rawCapturedRoomData = nil
        latestSnapshot = nil
        referencePhotoAssets = []

        // RoomCaptureView's documented order is display first, then run its
        // captureSession; running before the view is in a window leaves the
        // camera surface black on device. The capture UI mounts the view
        // during `.starting`, so this normally resolves within a frame or
        // two. The timeout keeps start() from hanging if the view is never
        // mounted; run() then proceeds exactly as before.
        for _ in 0..<Self.windowAttachWaitAttempts where captureView.window == nil {
            try? await Task.sleep(nanoseconds: Self.windowAttachWaitPollNanoseconds)
        }
        guard activeAttempt == attempt, !didIssueFinalStop else {
            // The attempt was stopped or discarded before run() was issued.
            // A never-run session gets no didEndWith callback, so release the
            // ownership gate here or cleanup would wait on it forever.
            sessionEndObservationGate.recordDidEnd(for: attempt)
            return
        }

        var configuration = RoomCaptureSession.Configuration()
        configuration.isCoachingEnabled = true
        roomCaptureSession.run(configuration: configuration)
        beginTrackingPoll(for: attempt)

        // Photoreal capture bundle (roadmap Phase A): best-effort keyframe +
        // scene-mesh recording alongside the scan; never blocks the attempt.
        let recorder = RoomCaptureBundleRecorder(
            arSession: arSession,
            parentDirectoryURL: workspace.directoryURL
        )
        recorder.start()
        bundleRecorder = recorder
        beginSceneReconstructionEnablement(for: attempt)
    }

    /// V1 ends the single RoomPlan session when the user stops. It does not
    /// assert continuity for a later rescan: a future rescan flow must prove
    /// registration/relocalization before it can reuse a coordinate space.
    func stop(attempt: RoomCaptureAttemptToken) async throws {
        guard activeAttempt == attempt else {
            throw RoomCaptureDriverError.invalidAttempt
        }
        guard !didIssueFinalStop else { return }
        // The bundle harvests the scene mesh from the still-running session,
        // so it must finalize before the final RoomPlan stop pauses ARKit.
        await bundleRecorder?.finalize()
        guard activeAttempt == attempt, !didIssueFinalStop else { return }
        didIssueFinalStop = true
        trackingTask?.cancel()
        roomCaptureSession.stop(pauseARSession: true)
    }

    /// Stop is idempotent. The RoomPlan delegate's eventual completion remains
    /// token-gated by the coordinator, so a late callback cannot revive a
    /// discarded attempt.
    func terminate(attempt: RoomCaptureAttemptToken) async {
        guard activeAttempt == attempt else { return }
        bundleRecorder?.cancel()
        trackingTask?.cancel()
        guard !didIssueFinalStop else { return }
        didIssueFinalStop = true
        roomCaptureSession.stop(pauseARSession: true)
    }

    func process(
        attempt: RoomCaptureAttemptToken,
        workspace: RoomCaptureScratchWorkspace
    ) async throws -> RoomCapturePreparedReview {
        guard
            activeAttempt == attempt,
            activeWorkspace == workspace,
            rawCapturedRoomData != nil,
            processingTask == nil
        else {
            throw RoomCaptureDriverError.noCapturedResult
        }

        let task = Task { @MainActor [weak self] () throws -> RoomCapturePreparedReview in
            guard let self else { throw CancellationError() }
            return try await self.makePreparedReview(
                attempt: attempt,
                workspace: workspace
            )
        }
        processingTask = task
        do {
            let review = try await task.value
            processingTask = nil
            return review
        } catch {
            processingTask = nil
            throw error
        }
    }

    /// The only manual-photo path uses the same active ARSession as RoomPlan.
    /// It does not create an AVCaptureSession, picker, or second camera owner.
    func requestReferencePhoto(
        attempt: RoomCaptureAttemptToken,
        requestID: RoomReferencePhotoRequestID,
        workspace: RoomCaptureScratchWorkspace
    ) async throws {
        guard
            activeAttempt == attempt,
            activeWorkspace == workspace,
            !didIssueFinalStop,
            photoTask == nil
        else {
            throw RoomCaptureDriverError.noCapturedResult
        }

        let task = Task { @MainActor [weak self] () throws in
            guard let self else { throw CancellationError() }
            try await self.writeReferencePhoto(
                attempt: attempt,
                requestID: requestID,
                workspace: workspace
            )
        }
        photoTask = task
        do {
            try await task.value
            photoTask = nil
        } catch {
            photoTask = nil
            throw error
        }
    }

    /// RoomBuilder can be noncooperative. Cancellation is requested first,
    /// then the explicit writer barrier below waits for all tracked work before
    /// the coordinator asks the scratch factory to remove the directory.
    func cancelProcessing(attempt: RoomCaptureAttemptToken) async {
        guard activeAttempt == attempt else { return }
        processingTask?.cancel()
        photoTask?.cancel()
        trackingTask?.cancel()
        await awaitScratchWriteBarrier(for: attempt)
    }

    func awaitScratchWriteBarrier(for attempt: RoomCaptureAttemptToken) async {
        guard activeAttempt == attempt else { return }
        if let processingTask {
            _ = try? await processingTask.value
        }
        if let photoTask {
            _ = try? await photoTask.value
        }
        if let trackingTask {
            await trackingTask.value
        }
        await bundleRecorder?.waitForWrites()
    }

    func cleanup(workspace: RoomCaptureScratchWorkspace) async throws {
        guard activeWorkspace == workspace || activeWorkspace == nil else {
            throw RoomCaptureDriverError.invalidAttempt
        }
        if let attempt = activeAttempt {
            try await awaitFinalSessionEnd(for: attempt)
            await awaitScratchWriteBarrier(for: attempt)
        }
        rawCapturedRoomData = nil
        latestSnapshot = nil
        referencePhotoAssets = []
        bundleRecorder = nil
        activeWorkspace = nil
        activeAttempt = nil
        coordinateSpaceEpochID = nil
        didIssueFinalStop = false
        sessionEndObservationGate.reset()
        processingTask = nil
        photoTask = nil
        trackingTask = nil
    }

    // MARK: - RoomPlan delegate delivery

    fileprivate func didStartCapture() {
        guard let activeAttempt else { return }
        observationHandler?(.didStart(attempt: activeAttempt))
    }

    fileprivate func didReceiveFullRoomSnapshot(_ room: CapturedRoom) {
        guard
            let attempt = activeAttempt,
            let coordinateSpaceEpochID
        else { return }
        do {
            let snapshot = try AppleRoomPlanSnapshotAdapter.makeSnapshot(
                from: room,
                attempt: attempt,
                coordinateSpaceEpochID: coordinateSpaceEpochID
            )
            latestSnapshot = snapshot
            observationHandler?(.liveSnapshot(attempt: attempt, snapshot: snapshot))
            publishSemanticHeuristics(snapshot, for: attempt)
        } catch {
            // A malformed transient framework value is not persisted. Keep the
            // live UI honest with a qualitative request for another pass.
            observationHandler?(
                .semanticGuidance(
                    attempt: attempt,
                    values: [.anotherPassHeuristic]
                )
            )
        }
    }

    fileprivate func didReceiveRoomDelta(_ kind: AppleRoomPlanDelegatePayloadKind) {
        // The methods remain implemented to track the documented delegate
        // surface, but their partial rooms never overwrite a full canvas
        // snapshot. A future accumulator requires independent device proof.
        guard !Self.acceptsFullSnapshot(from: kind) else { return }
    }

    fileprivate func didProvideInstruction(_ instruction: RoomCaptureCoachingInstruction) {
        guard let activeAttempt else { return }
        observationHandler?(
            .coaching(
                attempt: activeAttempt,
                instruction: instruction
            )
        )
    }

    fileprivate func didEndCapture(
        data: CapturedRoomData,
        terminationReason: RoomCaptureTerminationReason?
    ) {
        guard let activeAttempt else { return }
        trackingTask?.cancel()
        sessionEndObservationGate.recordDidEnd(for: activeAttempt)
        if let terminationReason {
            observationHandler?(
                .terminated(attempt: activeAttempt, reason: terminationReason)
            )
            return
        }
        rawCapturedRoomData = data
        observationHandler?(.didStop(attempt: activeAttempt))
    }

    // MARK: - Processing and immutable evidence

    private func makePreparedReview(
        attempt: RoomCaptureAttemptToken,
        workspace: RoomCaptureScratchWorkspace
    ) async throws -> RoomCapturePreparedReview {
        guard
            activeAttempt == attempt,
            activeWorkspace == workspace,
            let data = rawCapturedRoomData,
            let coordinateSpaceEpochID
        else {
            throw RoomCaptureDriverError.noCapturedResult
        }
        try Task.checkCancellation()

        let builder = RoomBuilder(options: [])
        let room: CapturedRoom
        do {
            room = try await builder.capturedRoom(from: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.processingStepFailure("RoomBuilder post-processing", error)
        }
        try Task.checkCancellation()

        let snapshot: RoomSemanticSnapshot
        do {
            snapshot = try AppleRoomPlanSnapshotAdapter.makeSnapshot(
                from: room,
                attempt: attempt,
                coordinateSpaceEpochID: coordinateSpaceEpochID
            )
        } catch {
            throw Self.processingStepFailure("semantic snapshot mapping", error)
        }
        latestSnapshot = snapshot

        let rawRelativePath = try RoomRelativePath(
            "evidence/roomplan/captured-room-data.json"
        )
        let processedRelativePath = try RoomRelativePath(
            "evidence/roomplan/captured-room.json"
        )
        let usdzRelativePath = try RoomRelativePath("evidence/native/RoomScan.usdz")
        let rawURL = workspace.directoryURL.appendingPathComponent(rawRelativePath.value)
        let processedURL = workspace.directoryURL.appendingPathComponent(processedRelativePath.value)
        let usdzURL = workspace.directoryURL.appendingPathComponent(usdzRelativePath.value)

        // CapturedRoomData's Codable implementation is Apple-internal and can
        // refuse to serialize on device (EncodingError "Invalid data"). The
        // raw blob is archival-only with no read path, so its failure demotes
        // the artifact to explicitly-unavailable instead of failing the
        // entire capture attempt.
        let rawDataWriteError: Error?
        do {
            try writeScratchData(
                Self.makeEvidenceEncoder().encode(data),
                to: rawURL
            )
            rawDataWriteError = nil
        } catch {
            print("RoomScanStudio: raw CapturedRoomData evidence omitted: \(String(describing: error))")
            rawDataWriteError = error
        }
        do {
            try writeScratchData(
                Self.makeEvidenceEncoder().encode(room),
                to: processedURL
            )
        } catch {
            throw Self.processingStepFailure("processed CapturedRoom JSON evidence", error)
        }
        do {
            try fileManager.createDirectory(
                at: usdzURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try room.export(to: usdzURL, exportOptions: .mesh)
        } catch {
            throw Self.processingStepFailure("USDZ model export", error)
        }
        try Task.checkCancellation()

        let thumbnail: RoomAssetInput
        do {
            thumbnail = try writeProjectThumbnail(
                for: snapshot,
                workspace: workspace
            )
        } catch {
            throw Self.processingStepFailure("project thumbnail", error)
        }
        let rawArtifact: RoomEvidenceArtifact
        if rawDataWriteError == nil {
            rawArtifact = try presentEvidenceArtifact(
                kind: .capturedRoomDataJSON,
                path: rawRelativePath,
                url: rawURL,
                mediaType: "application/json"
            )
        } else {
            rawArtifact = unavailableEvidenceArtifact(
                kind: .capturedRoomDataJSON,
                reason: "RoomPlan's raw CapturedRoomData did not support serialization for this capture. The processed CapturedRoom JSON, USDZ model, and semantic snapshot remain the reviewed record.",
                status: .unavailable
            )
        }
        let processedArtifact = try presentEvidenceArtifact(
            kind: .capturedRoomJSON,
            path: processedRelativePath,
            url: processedURL,
            mediaType: "application/json"
        )
        let nativeArtifact = try presentEvidenceArtifact(
            kind: .nativeUSDZ,
            path: usdzRelativePath,
            url: usdzURL,
            mediaType: "model/vnd.usdz+zip"
        )
        let unavailableArtifacts = [
            unavailableEvidenceArtifact(
                kind: .rawMesh,
                reason: "Raw mesh evidence is not enabled until a physical device gate confirms RoomPlan preserves scene reconstruction."
            ),
            unavailableEvidenceArtifact(
                kind: .worldMap,
                reason: "World-map persistence is not requested for the single-room V1 capture flow."
            ),
            unavailableEvidenceArtifact(
                kind: .provenance,
                reason: "No additional framework provenance artifact was produced beyond normalized semantic provenance."
            ),
        ]
        let evidence = RoomRevisionEvidencePlan(
            source: .roomPlan,
            artifacts: [rawArtifact, processedArtifact, nativeArtifact] + unavailableArtifacts,
            captureAttemptID: attempt.value,
            coordinateSpaceEpochID: coordinateSpaceEpochID
        )

        let metadata = RoomMetadata(
            projectID: "pending-project",
            customName: "Room scan",
            captureDate: Date(),
            lastRevisedDate: Date(),
            manualLocation: "",
            optionalGPS: nil,
            notes: "Captured with RoomPlan. Measurements remain estimates, not survey-grade evidence.",
            tags: ["roomplan"],
            thumbnailRelativePath: thumbnail.destination,
            archived: false
        )
        let payload = RoomRevisionPayload(
            semanticSnapshot: snapshot,
            annotations: [],
            measurements: [],
            photos: referencePhotoAssets.map(\.photo)
        )
        var evidenceAssets: [RoomAssetInput] = []
        if rawDataWriteError == nil {
            evidenceAssets.append(
                RoomAssetInput(
                    sourceURL: rawURL,
                    destination: rawRelativePath,
                    scope: .revision
                )
            )
        }
        evidenceAssets.append(contentsOf: [
            RoomAssetInput(
                sourceURL: processedURL,
                destination: processedRelativePath,
                scope: .revision
            ),
            RoomAssetInput(
                sourceURL: usdzURL,
                destination: usdzRelativePath,
                scope: .revision
            ),
        ])
        return RoomCapturePreparedReview(
            commit: RoomInitialCaptureCommit(
                draft: RoomDraft(metadata: metadata, revision: payload),
                evidence: evidence,
                assets: [thumbnail] + evidenceAssets + referencePhotoAssets.map(\.asset)
            ),
            guidance: guidanceForCompletedSnapshot(snapshot)
        )
    }

    /// RoomPlan's CapturedRoomData/CapturedRoom can contain non-finite floats
    /// on real devices, which plain JSONEncoder rejects with "The data
    /// couldn't be written because it isn't in the correct format." Evidence
    /// files are archival, so non-finite values are preserved as strings
    /// instead of failing the whole capture attempt. App-owned models keep the
    /// strict `RoomJSONCoding` encoder.
    nonisolated static func makeEvidenceEncoder() -> JSONEncoder {
        let encoder = RoomJSONCoding.makeEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return encoder
    }

    /// Counterpart for reading evidence JSON back. No production path decodes
    /// these archival files today; this keeps the written format readable by
    /// construction rather than write-only.
    nonisolated static func makeEvidenceDecoder() -> JSONDecoder {
        let decoder = RoomJSONCoding.makeDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return decoder
    }

    /// Wraps a processing-step error with the step name and the error's full
    /// structural description (for EncodingError this includes the exact
    /// coding path), so a device-only failure identifies itself in one run
    /// instead of surfacing as a bare Cocoa message.
    private static func processingStepFailure(
        _ step: String,
        _ error: Error
    ) -> AppleRoomCaptureDriverError {
        let detail = String(describing: error)
        print("RoomScanStudio capture processing failed at step '\(step)': \(detail)")
        return .processingStepFailed(step: step, detail: detail)
    }

    private func writeScratchData(_ data: Data, to url: URL) throws {
        guard !data.isEmpty else {
            throw AppleRoomCaptureDriverError.requiredEvidenceWriteFailed
        }
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private func awaitFinalSessionEnd(
        for attempt: RoomCaptureAttemptToken
    ) async throws {
        if sessionEndObservationGate.allowsOwnershipRelease(for: attempt) {
            return
        }
        for _ in 0..<Self.sessionEndWaitAttempts {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: Self.sessionEndWaitPollNanoseconds)
            if sessionEndObservationGate.allowsOwnershipRelease(for: attempt) {
                return
            }
        }
        throw AppleRoomCaptureDriverError.sessionEndNotObserved
    }

    private func presentEvidenceArtifact(
        kind: RoomEvidenceArtifactKind,
        path: RoomRelativePath,
        url: URL,
        mediaType: String
    ) throws -> RoomEvidenceArtifact {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard byteCount > 0 else {
            throw AppleRoomCaptureDriverError.requiredEvidenceWriteFailed
        }
        return RoomEvidenceArtifact(
            kind: kind,
            status: .present,
            relativePath: path,
            byteCount: byteCount,
            mediaType: mediaType,
            omissionReason: nil,
            sha256Hex: try RoomSHA256.hexDigest(ofFile: url)
        )
    }

    private func unavailableEvidenceArtifact(
        kind: RoomEvidenceArtifactKind,
        reason: String,
        status: RoomEvidenceArtifactStatus = .notRequested
    ) -> RoomEvidenceArtifact {
        RoomEvidenceArtifact(
            kind: kind,
            status: status,
            relativePath: nil,
            byteCount: nil,
            mediaType: nil,
            omissionReason: reason,
            sha256Hex: nil
        )
    }

    /// Draws the real top-down `RoomFloorPlanProjection` of the reviewed
    /// semantic snapshot instead of a fake rectangle pattern, so a stored
    /// thumbnail always reflects actual captured geometry. Same 640x360 PNG
    /// output path/schema as before — only the drawing changed.
    private func writeProjectThumbnail(
        for snapshot: RoomSemanticSnapshot,
        workspace: RoomCaptureScratchWorkspace
    ) throws -> RoomAssetInput {
        let destination = try RoomRelativePath("thumbnails/thumbnail.png")
        let sourceURL = workspace.directoryURL.appendingPathComponent("roomplan-thumbnail.png")
        let png: Data
        do {
            png = try RoomThumbnailRenderer.pngData(
                for: snapshot,
                size: CGSize(width: 640, height: 360)
            )
        } catch {
            throw AppleRoomCaptureDriverError.thumbnailWriteFailed
        }
        try png.write(to: sourceURL, options: .atomic)
        return RoomAssetInput(sourceURL: sourceURL, destination: destination, scope: .project)
    }

    // MARK: - Reference photos

    private func writeReferencePhoto(
        attempt: RoomCaptureAttemptToken,
        requestID: RoomReferencePhotoRequestID,
        workspace: RoomCaptureScratchWorkspace
    ) async throws {
        try Task.checkCancellation()
        let frame = try await captureHighResolutionReferenceFrame()
        try Task.checkCancellation()
        guard activeAttempt == attempt, activeWorkspace == workspace, !didIssueFinalStop else {
            throw CancellationError()
        }

        let ciImage = CIImage(cvPixelBuffer: frame.capturedImage)
        let ciContext = CIContext(options: nil)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            throw AppleRoomCaptureDriverError.referencePhotoEncodingFailed
        }
        // AR frames are sensor-oriented. The resulting review image carries an
        // explicit UIKit orientation while the model preserves camera pose.
        let image = UIImage(cgImage: cgImage, scale: 1, orientation: .right)
        guard let jpeg = image.jpegData(compressionQuality: 0.9), !jpeg.isEmpty else {
            throw AppleRoomCaptureDriverError.referencePhotoEncodingFailed
        }

        let relativePath = try RoomRelativePath("photos/reference-\(requestID.value).jpg")
        let sourceURL = workspace.directoryURL.appendingPathComponent(relativePath.value)
        try fileManager.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try jpeg.write(to: sourceURL, options: .atomic)
        let photo = RoomPhoto(
            id: "reference-\(requestID.value)",
            createdAt: Date(),
            assetRelativePath: relativePath,
            caption: "ARKit high-resolution reference frame (sensor orientation: right).",
            cameraTransform: Self.roomTransform(from: frame.camera.transform)
        )
        referencePhotoAssets.append((
            photo: photo,
            asset: RoomAssetInput(
                sourceURL: sourceURL,
                destination: relativePath,
                scope: .revision
            )
        ))
    }

    /// This exact iOS-17 call is deliberately isolated. It must be compiled on
    /// the macOS/Xcode gate because Apple SDK availability annotations can vary
    /// between the documented async API and an installed SDK revision.
    private func captureHighResolutionReferenceFrame() async throws -> ARFrame {
        try await arSession.captureHighResolutionFrame()
    }

    // MARK: - Scene reconstruction for the capture bundle

    /// Device-proven 2026-08-10: RoomPlan's own configuration does not enable
    /// scene reconstruction, so ARMeshAnchors never appear. Re-running the
    /// shared session with RoomPlan's configuration plus mesh reconstruction
    /// keeps the scan working while exposing the LiDAR mesh the photoreal
    /// capture bundle harvests. The session configuration may not be
    /// readable immediately after run(), so phase 1 retries briefly.
    ///
    /// Device-observed 2026-08-10 (second gate): inserting sceneDepth frame
    /// semantics in the SAME re-run that enables mesh reconstruction produced
    /// per-keyframe depth but zero ARMeshAnchors for the whole scan. Phase 2
    /// therefore waits until mesh anchors actually exist before adding
    /// sceneDepth in a separate re-run, and phase 3 logs coarse status
    /// transitions so a reconstruction loss is visible in the device log.
    private func beginSceneReconstructionEnablement(
        for attempt: RoomCaptureAttemptToken
    ) {
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
            return
        }
        let wantsSceneDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        Task { @MainActor [weak self] in
            // Phase 1: enable mesh reconstruction exactly as device-proven.
            var meshRequested = false
            for _ in 0..<10 {
                guard let self, self.activeAttempt == attempt, !self.didIssueFinalStop else {
                    return
                }
                if let configuration = self.arSession.configuration as? ARWorldTrackingConfiguration {
                    if configuration.sceneReconstruction != .mesh {
                        configuration.sceneReconstruction = .mesh
                        self.arSession.run(configuration)
                    }
                    meshRequested = true
                    break
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            guard meshRequested else {
                print("RoomScanStudio capture bundle: session configuration never became readable; scene reconstruction stays off.")
                return
            }

            // Phase 2: only after reconstruction demonstrably produces
            // anchors is sceneDepth added, in its own re-run.
            if wantsSceneDepth {
                var sawAnchors = false
                for _ in 0..<60 {
                    guard let self, self.activeAttempt == attempt, !self.didIssueFinalStop else {
                        return
                    }
                    let anchorCount = (self.arSession.currentFrame?.anchors ?? [])
                        .filter { $0 is ARMeshAnchor }.count
                    if anchorCount > 0 {
                        sawAnchors = true
                        print("RoomScanStudio capture bundle: enabling sceneDepth after \(anchorCount) mesh anchors appeared.")
                        if let configuration = self.arSession.configuration as? ARWorldTrackingConfiguration,
                           !configuration.frameSemantics.contains(.sceneDepth) {
                            configuration.frameSemantics.insert(.sceneDepth)
                            self.arSession.run(configuration)
                        }
                        break
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                if !sawAnchors {
                    print("RoomScanStudio capture bundle: mesh anchors never appeared; sceneDepth stays off to protect reconstruction.")
                }
            }

            // Phase 3: coarse status telemetry, printed only on transitions.
            // Device-observed 2026-08-10: after the phase-2 re-run this
            // reported mesh=off while anchors kept growing (8 -> 28) and the
            // final harvest was healthy, so the configuration readback is not
            // a reliable witness for reconstruction; trust the anchors field.
            var lastStatus = ""
            while !Task.isCancelled {
                guard let self, self.activeAttempt == attempt, !self.didIssueFinalStop else {
                    return
                }
                let configuration = self.arSession.configuration as? ARWorldTrackingConfiguration
                let meshOn = configuration?.sceneReconstruction == .mesh
                let depthOn = configuration?.frameSemantics.contains(.sceneDepth) ?? false
                let hasAnchors = (self.arSession.currentFrame?.anchors ?? [])
                    .contains(where: { $0 is ARMeshAnchor })
                let status = "mesh=\(meshOn ? "on" : "off") depth=\(depthOn ? "on" : "off") anchors=\(hasAnchors ? "present" : "absent")"
                if status != lastStatus {
                    print("RoomScanStudio capture bundle status: \(status)")
                    lastStatus = status
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    // MARK: - Qualitative AR guidance

    private func beginTrackingPoll(for attempt: RoomCaptureAttemptToken) {
        trackingTask?.cancel()
        trackingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard self.activeAttempt == attempt, !self.didIssueFinalStop else {
                    return
                }
                self.publishTrackingObservation(for: attempt)
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
        }
    }

    /// This polling path is operational-only. It never supplies a photo and
    /// never describes `currentFrame` as a high-resolution capture fallback.
    private func publishTrackingObservation(for attempt: RoomCaptureAttemptToken) {
        guard let frame = arSession.currentFrame else {
            observationHandler?(
                .tracking(attempt: attempt, quality: .notAvailable, limitedReason: nil)
            )
            observationHandler?(
                .operationalGuidance(attempt: attempt, values: [.trackingLost])
            )
            return
        }
        let tracking = Self.trackingState(from: frame.camera.trackingState)
        observationHandler?(
            .tracking(
                attempt: attempt,
                quality: tracking.quality,
                limitedReason: tracking.reason
            )
        )

        var guidance: [RoomCaptureGuidance] = []
        if tracking.quality == .limited {
            guidance.append(.trackingLimited)
        } else if tracking.quality == .notAvailable {
            guidance.append(.trackingLost)
        }
        // This threshold is an intentionally qualitative poor-light heuristic;
        // it is not saved or displayed as an illumination/accuracy value.
        if let estimate = frame.lightEstimate, estimate.ambientIntensity < 250 {
            guidance.append(.poorLightingHeuristic)
        }
        // Empty recovery is meaningful: it clears former dark/limited guidance
        // rather than leaving stale operational advice on the canvas.
        observationHandler?(.operationalGuidance(attempt: attempt, values: guidance))
    }

    private func publishSemanticHeuristics(
        _ snapshot: RoomSemanticSnapshot,
        for attempt: RoomCaptureAttemptToken
    ) {
        let values = guidanceForCompletedSnapshot(snapshot)
        observationHandler?(.semanticGuidance(attempt: attempt, values: values))
    }

    private func guidanceForCompletedSnapshot(
        _ snapshot: RoomSemanticSnapshot
    ) -> [RoomCaptureGuidance] {
        let elements = snapshot.structuralElements + snapshot.objectElements
        var guidance: [RoomCaptureGuidance] = []
        if elements.contains(where: { $0.provenance?.classificationConfidence == .low }) {
            guidance.append(.lowClassificationConfidence)
        }
        if snapshot.structuralElements.count < 2 {
            guidance.append(.anotherPassHeuristic)
        }
        return guidance
    }

    // MARK: - Foundation mappings

    nonisolated fileprivate static func coachingInstruction(
        from instruction: RoomCaptureSession.Instruction
    ) -> RoomCaptureCoachingInstruction {
        switch instruction {
        case .normal:
            return .normal
        case .moveCloseToWall:
            return .moveCloseToWall
        case .moveAwayFromWall:
            return .moveAwayFromWall
        case .turnOnLight:
            return .turnOnLight
        case .slowDown:
            return .slowDown
        case .lowTexture:
            return .lowTexture
        @unknown default:
            return .unknown
        }
    }

    nonisolated static func acceptsFullSnapshot(
        from payloadKind: AppleRoomPlanDelegatePayloadKind
    ) -> Bool {
        payloadKind == .didUpdate
    }

    nonisolated fileprivate static func terminationReason(
        from error: Error?
    ) -> RoomCaptureTerminationReason? {
        guard let error else { return nil }
        guard let captureError = error as? RoomCaptureSession.CaptureError else {
            return .unknown
        }
        switch captureError {
        case .deviceNotSupported:
            return .deviceNotSupported
        case .deviceTooHot:
            return .deviceTooHot
        case .exceedSceneSizeLimit:
            return .exceedSceneSizeLimit
        case .invalidARConfiguration:
            return .invalidARConfiguration
        case .worldTrackingFailure:
            return .worldTrackingFailure
        case .internalError:
            return .internalError
        @unknown default:
            return .unknown
        }
    }

    private static func trackingState(
        from state: ARCamera.TrackingState
    ) -> (quality: RoomTrackingQuality, reason: RoomTrackingLimitedReason?) {
        switch state {
        case .notAvailable:
            return (.notAvailable, nil)
        case .normal:
            return (.normal, nil)
        case let .limited(reason):
            return (.limited, limitedTrackingReason(from: reason))
        @unknown default:
            return (.unknown, nil)
        }
    }

    private static func limitedTrackingReason(
        from reason: ARCamera.TrackingState.Reason
    ) -> RoomTrackingLimitedReason {
        switch reason {
        case .initializing:
            return .initializing
        case .relocalizing:
            return .relocalizing
        case .excessiveMotion:
            return .excessiveMotion
        case .insufficientFeatures:
            return .insufficientFeatures
        @unknown default:
            return .unknown
        }
    }

    fileprivate static func roomTransform(
        from value: simd_float4x4
    ) -> RoomTransform4x4 {
        RoomTransform4x4(columnMajorValues: [
            Double(value.columns.0.x), Double(value.columns.0.y),
            Double(value.columns.0.z), Double(value.columns.0.w),
            Double(value.columns.1.x), Double(value.columns.1.y),
            Double(value.columns.1.z), Double(value.columns.1.w),
            Double(value.columns.2.x), Double(value.columns.2.y),
            Double(value.columns.2.z), Double(value.columns.2.w),
            Double(value.columns.3.x), Double(value.columns.3.y),
            Double(value.columns.3.z), Double(value.columns.3.w),
        ])
    }
}

@MainActor
final class AppleRoomCaptureDriverFactory: RoomCaptureDriverFactory {
    /// Source-level test seams: hardware is not constructed by these checks.
    static let usesOneAppOwnedSessionPerDriver = true
    static let finalStopPausesARSession = true

    func makeDriver() -> any RoomCaptureDriving {
        AppleRoomCaptureDriver()
    }
}

/// Bridges RoomPlan's SDK-only values to portable DTOs. It is intentionally
/// kept in the app target; Core tests exercise the resulting Foundation mapper
/// without importing Apple frameworks.
@MainActor
private enum AppleRoomPlanSnapshotAdapter {
    static func makeSnapshot(
        from room: CapturedRoom,
        attempt: RoomCaptureAttemptToken,
        coordinateSpaceEpochID: String
    ) throws -> RoomSemanticSnapshot {
        let surfaces = room.walls.map { surfaceDescriptor($0, sourceKind: "wall", sourceLabel: "Wall") }
            + room.floors.map { surfaceDescriptor($0, sourceKind: "floor", sourceLabel: "Floor") }
            + room.doors.map { surfaceDescriptor($0, sourceKind: "door", sourceLabel: "Door") }
            + room.windows.map { surfaceDescriptor($0, sourceKind: "window", sourceLabel: "Window") }
            + room.openings.map { surfaceDescriptor($0, sourceKind: "opening", sourceLabel: "Opening") }
        let objects = room.objects.map(objectDescriptor)
        return try RoomPlanSemanticMapper.makeSnapshot(
            projectID: "pending-project",
            revisionID: "pending-revision",
            attempt: attempt,
            coordinateSpaceEpochID: coordinateSpaceEpochID,
            surfaces: surfaces,
            objects: objects
        )
    }

    private static func surfaceDescriptor(
        _ surface: CapturedRoom.Surface,
        sourceKind: String,
        sourceLabel: String
    ) -> RoomPlanSemanticSurfaceDescriptor {
        return RoomPlanSemanticSurfaceDescriptor(
            sourceIdentifier: surface.identifier.uuidString.lowercased(),
            parentSourceIdentifier: surface.parentIdentifier?.uuidString.lowercased(),
            kind: sourceKind,
            label: sourceLabel,
            dimensionsMeters: dimensions(from: surface.dimensions),
            transform: AppleRoomCaptureDriver.roomTransform(from: surface.transform),
            polygonCorners: surface.polygonCorners.map(point),
            flattenedAttributeShortIdentifiers: [],
            classificationConfidence: confidence(from: surface.confidence)
        )
    }

    private static func objectDescriptor(
        _ object: CapturedRoom.Object
    ) -> RoomPlanSemanticObjectDescriptor {
        let descriptor = objectCategoryDescriptor(object.category)
        return RoomPlanSemanticObjectDescriptor(
            sourceIdentifier: object.identifier.uuidString.lowercased(),
            parentSourceIdentifier: object.parentIdentifier?.uuidString.lowercased(),
            kind: descriptor.kind,
            label: descriptor.label,
            dimensionsMeters: dimensions(from: object.dimensions),
            transform: AppleRoomCaptureDriver.roomTransform(from: object.transform),
            polygonCorners: [],
            flattenedAttributeShortIdentifiers: object.attributes
                .compactMap { $0.shortIdentifier }
                .sorted(),
            classificationConfidence: confidence(from: object.confidence),
            mobility: descriptor.mobility
        )
    }

    private static func dimensions(from value: SIMD3<Float>) -> RoomDimensions {
        RoomDimensions(
            width: Double(value.x),
            height: Double(value.y),
            depth: Double(value.z)
        )
    }

    private static func point(_ value: SIMD3<Float>) -> RoomPoint3D {
        RoomPoint3D(x: Double(value.x), y: Double(value.y), z: Double(value.z))
    }

    private static func confidence(
        from value: CapturedRoom.Confidence
    ) -> RoomClassificationConfidence {
        switch value {
        case .low:
            return .low
        case .medium:
            return .medium
        case .high:
            return .high
        @unknown default:
            return .unknown
        }
    }

    private static func objectCategoryDescriptor(
        _ category: CapturedRoom.Object.Category
    ) -> (
        kind: String,
        label: String,
        mobility: RoomPlanSemanticObjectMobility
    ) {
        // These are the documented RoomPlan object categories. They map to
        // conservative app semantics only; neither a category nor confidence
        // is represented as a numeric geometric-accuracy claim.
        switch category {
        case .bathtub:
            return ("bathtub", "Bathtub", .fixed)
        case .bed:
            return ("bed", "Bed", .movable)
        case .chair:
            return ("chair", "Chair", .movable)
        case .dishwasher:
            return ("dishwasher", "Dishwasher", .fixed)
        case .fireplace:
            return ("fireplace", "Fireplace", .fixed)
        case .oven:
            return ("oven", "Oven", .fixed)
        case .refrigerator:
            return ("refrigerator", "Refrigerator", .fixed)
        case .sink:
            return ("sink", "Sink", .fixed)
        case .sofa:
            return ("sofa", "Sofa", .movable)
        case .stairs:
            return ("stairs", "Stairs", .unknown)
        case .storage:
            return ("storage", "Storage", .unknown)
        case .stove:
            return ("stove", "Stove", .fixed)
        case .table:
            return ("table", "Table", .movable)
        case .television:
            return ("television", "Television", .unknown)
        case .toilet:
            return ("toilet", "Toilet", .fixed)
        case .washerDryer:
            return ("washerDryer", "Washer / dryer", .fixed)
        @unknown default:
            return ("object", "Detected object", .unknown)
        }
    }
}

/// RoomPlan delegate values are not uniformly annotated Sendable across SDK
/// revisions. The proxy immediately transfers them to the app main actor and
/// never stores them off that actor.
private struct AppleRoomPlanUncheckedTransfer<Value>: @unchecked Sendable {
    let value: Value
}

/// The stable Objective-C name satisfies NSCoding (inherited through
/// RoomCaptureViewDelegate); the proxy itself is never archived.
@objc(RoomScanStudioAppleRoomCaptureSessionDelegateProxy)
private final class AppleRoomCaptureSessionDelegateProxy: NSObject, RoomCaptureSessionDelegate, RoomCaptureViewDelegate, @unchecked Sendable {
    weak var owner: AppleRoomCaptureDriver?

    override init() {
        super.init()
    }

    // RoomCaptureViewDelegate inherits NSCoding; this proxy is never archived.
    func encode(with coder: NSCoder) {}

    init?(coder: NSCoder) {
        return nil
    }

    /// The driver's `process()` is the single RoomBuilder path. Declining
    /// presentation keeps RoomCaptureView from running a second, redundant
    /// post-processing pass after stop.
    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        false
    }

    func captureSession(
        _ session: RoomCaptureSession,
        didStartWith configuration: RoomCaptureSession.Configuration
    ) {
        Task { @MainActor [weak owner] in
            owner?.didStartCapture()
        }
    }

    func captureSession(_ session: RoomCaptureSession, didAdd room: CapturedRoom) {
        Task { @MainActor [weak owner] in
            owner?.didReceiveRoomDelta(.didAdd)
        }
    }

    func captureSession(_ session: RoomCaptureSession, didRemove room: CapturedRoom) {
        Task { @MainActor [weak owner] in
            owner?.didReceiveRoomDelta(.didRemove)
        }
    }

    func captureSession(_ session: RoomCaptureSession, didChange room: CapturedRoom) {
        Task { @MainActor [weak owner] in
            owner?.didReceiveRoomDelta(.didChange)
        }
    }

    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        let transfer = AppleRoomPlanUncheckedTransfer(value: room)
        Task { @MainActor [weak owner] in
            owner?.didReceiveFullRoomSnapshot(transfer.value)
        }
    }

    func captureSession(
        _ session: RoomCaptureSession,
        didProvide instruction: RoomCaptureSession.Instruction
    ) {
        let mapped = AppleRoomCaptureDriver.coachingInstruction(from: instruction)
        Task { @MainActor [weak owner] in
            owner?.didProvideInstruction(mapped)
        }
    }

    func captureSession(
        _ session: RoomCaptureSession,
        didEndWith data: CapturedRoomData,
        error: Error?
    ) {
        let transfer = AppleRoomPlanUncheckedTransfer(value: data)
        let terminationReason = AppleRoomCaptureDriver.terminationReason(from: error)
        Task { @MainActor [weak owner] in
            owner?.didEndCapture(
                data: transfer.value,
                terminationReason: terminationReason
            )
        }
    }

}

private enum AppleRoomCaptureDriverError: LocalizedError {
    case requiredEvidenceWriteFailed
    case thumbnailWriteFailed
    case referencePhotoEncodingFailed
    case sessionEndNotObserved
    case processingStepFailed(step: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .requiredEvidenceWriteFailed:
            return "Required RoomPlan evidence could not be written to scratch storage."
        case .thumbnailWriteFailed:
            return "The reviewed project thumbnail could not be generated."
        case .referencePhotoEncodingFailed:
            return "The reference photo could not be encoded from the active AR session."
        case .sessionEndNotObserved:
            return "RoomPlan has not confirmed session termination yet. Keep this attempt open and retry cleanup after the final callback arrives."
        case let .processingStepFailed(step, detail):
            return "Processing failed at step '\(step)': \(detail)"
        }
    }
}

/// Draws the real top-down semantic-box projection with the fixed dark
/// field-instrument palette (captureBlack background, cyan structural
/// strokes, amber object fills). Shared by every site that must show a room
/// preview derived from real geometry instead of the retired fake rectangle
/// pattern: capture-time thumbnail generation (this driver and
/// `SimulatedRoomCaptureDriver`) and payload-derived library previews in
/// `ExistingRoomsView` for legacy packages whose stored thumbnail still
/// holds the old pattern.
enum RoomThumbnailRenderer {
    static let captureBlack = UIColor(red: 0.025, green: 0.03, blue: 0.03, alpha: 1)
    static let structuralStroke = UIColor(red: 0.35, green: 0.84, blue: 0.93, alpha: 1)
    static let objectFill = UIColor(red: 0.98, green: 0.69, blue: 0.27, alpha: 0.45)
    static let objectStroke = UIColor(red: 0.98, green: 0.69, blue: 0.27, alpha: 1)

    /// Builds the projection from a semantic snapshot and encodes it as PNG.
    /// Throws when the snapshot contains geometry `RoomFloorPlanProjection`
    /// cannot render (non-finite or out-of-range transforms) rather than
    /// silently falling back to the retired fake pattern.
    static func pngData(for snapshot: RoomSemanticSnapshot, size: CGSize) throws -> Data {
        let projection = try RoomFloorPlanProjection.make(from: snapshot)
        guard let png = projectionImage(from: projection, size: size).pngData(), !png.isEmpty else {
            throw RoomThumbnailRendererError.encodingFailed
        }
        return png
    }

    /// Pure drawing entry point: renders an already-computed projection. Used
    /// directly by display sites (e.g. a library row preview) that already
    /// hold a `RoomFloorPlanProjection` and only need a bitmap, not a PNG.
    static func projectionImage(from projection: RoomFloorPlanProjection, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { rendererContext in
            let context = rendererContext.cgContext
            captureBlack.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let inset = CGRect(origin: .zero, size: size)
                .insetBy(dx: size.width * 0.08, dy: size.height * 0.08)
            let boundsWidth = max(projection.bounds.width, 0.01)
            let boundsHeight = max(projection.bounds.height, 0.01)
            let scale = min(inset.width / boundsWidth, inset.height / boundsHeight)
            context.setLineWidth(max(1.5, size.width / 220))

            for item in projection.items {
                let path = polygonPath(for: item, projection: projection, inset: inset, scale: scale)
                context.addPath(path)
                if item.isStructural {
                    UIColor.clear.setFill()
                    structuralStroke.setStroke()
                    context.drawPath(using: .stroke)
                } else {
                    objectFill.setFill()
                    objectStroke.setStroke()
                    context.drawPath(using: .fillStroke)
                }
            }
        }
    }

    private static func polygonPath(
        for item: RoomFloorPlanItem,
        projection: RoomFloorPlanProjection,
        inset: CGRect,
        scale: CGFloat
    ) -> CGPath {
        let points = item.corners.map { point -> CGPoint in
            CGPoint(
                x: inset.minX + CGFloat(point.x - projection.bounds.minimum.x) * scale,
                y: inset.maxY - CGFloat(point.y - projection.bounds.minimum.y) * scale
            )
        }
        let path = CGMutablePath()
        if let first = points.first {
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            path.closeSubpath()
        }
        return path
    }
}

enum RoomThumbnailRendererError: Error, Sendable, Equatable {
    case encodingFailed
}
