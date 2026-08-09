import Foundation
import RoomScanCore

/// UI-test and Simulator-only capture path. It writes attempt-local scratch
/// files and declares deterministic-fixture omissions; it never pretends to
/// contain RoomPlan JSON, native USDZ, raw mesh, or world-map bytes.
struct SimulatedRoomCaptureScenario: Sendable, Equatable {
    /// `Int.max` represents an intentionally persistent deterministic failure.
    var processingFailuresBeforeSuccess: Int
    var referencePhotoFails: Bool
    var suspendsProcessingUntilCancelled: Bool

    init(
        processingFails: Bool = false,
        processingFailuresBeforeSuccess: Int = 0,
        referencePhotoFails: Bool = false,
        suspendsProcessingUntilCancelled: Bool = false
    ) {
        self.processingFailuresBeforeSuccess = processingFails
            ? Int.max
            : max(0, processingFailuresBeforeSuccess)
        self.referencePhotoFails = referencePhotoFails
        self.suspendsProcessingUntilCancelled = suspendsProcessingUntilCancelled
    }
}

@MainActor
final class SimulatedRoomCaptureDriver: RoomCaptureDriving {
    var observationHandler: ((RoomCaptureDriverObservation) -> Void)?

    private let scenario: SimulatedRoomCaptureScenario
    private var activeAttempt: RoomCaptureAttemptToken?
    private var activeWorkspace: RoomCaptureScratchWorkspace?
    private var didStop = false
    private var photoAssets: [(photo: RoomPhoto, asset: RoomAssetInput)] = []
    private var processingAttemptCount = 0
    private var cancelledProcessingAttempts: Set<RoomCaptureAttemptToken> = []
    private var processingContinuation: CheckedContinuation<Void, Never>?

    init(scenario: SimulatedRoomCaptureScenario = .init()) {
        self.scenario = scenario
    }

    func start(
        attempt: RoomCaptureAttemptToken,
        workspace: RoomCaptureScratchWorkspace
    ) async throws {
        guard workspace.attempt == attempt else {
            throw RoomCaptureDriverError.invalidAttempt
        }
        activeAttempt = attempt
        activeWorkspace = workspace
        didStop = false
        photoAssets = []
        processingAttemptCount = 0
        cancelledProcessingAttempts.removeAll()
        processingContinuation = nil
        observationHandler?(.didStart(attempt: attempt))
        observationHandler?(.coaching(attempt: attempt, instruction: .normal))
        observationHandler?(
            .tracking(attempt: attempt, quality: .normal, limitedReason: nil)
        )
        observationHandler?(.operationalGuidance(attempt: attempt, values: []))
        observationHandler?(
            .liveSnapshot(attempt: attempt, snapshot: makeSnapshot(attempt: attempt))
        )
    }

    func stop(attempt: RoomCaptureAttemptToken) async throws {
        guard activeAttempt == attempt else {
            throw RoomCaptureDriverError.invalidAttempt
        }
        didStop = true
        observationHandler?(.didStop(attempt: attempt))
    }

    func terminate(attempt: RoomCaptureAttemptToken) async {
        guard activeAttempt == attempt else {
            return
        }
        activeAttempt = nil
        activeWorkspace = nil
        didStop = false
        photoAssets = []
    }

    func process(
        attempt: RoomCaptureAttemptToken,
        workspace: RoomCaptureScratchWorkspace
    ) async throws -> RoomCapturePreparedReview {
        guard activeAttempt == attempt, activeWorkspace == workspace, didStop else {
            throw RoomCaptureDriverError.noCapturedResult
        }
        processingAttemptCount += 1
        if Task.isCancelled || cancelledProcessingAttempts.contains(attempt) {
            throw CancellationError()
        }
        if scenario.suspendsProcessingUntilCancelled {
            await withCheckedContinuation { continuation in
                processingContinuation = continuation
            }
            if Task.isCancelled || cancelledProcessingAttempts.contains(attempt) {
                throw CancellationError()
            }
        }
        if processingAttemptCount <= scenario.processingFailuresBeforeSuccess {
            throw RoomCaptureDriverError.simulatedFailure(
                "The deterministic driver was configured to fail processing."
            )
        }

        let thumbnailRelativePath = try RoomRelativePath("thumbnails/thumbnail.png")
        let thumbnailSource = workspace.directoryURL.appendingPathComponent("thumbnail.png")
        try deterministicPNG.write(to: thumbnailSource, options: .atomic)

        let snapshot = makeSnapshot(attempt: attempt)
        let payload = RoomRevisionPayload(
            semanticSnapshot: snapshot,
            annotations: [],
            measurements: [],
            photos: photoAssets.map(\.photo)
        )
        let metadata = RoomMetadata(
            projectID: "pending-project",
            customName: "Simulated Room",
            captureDate: Self.fixtureDate,
            lastRevisedDate: Self.fixtureDate,
            manualLocation: "Simulator fixture lab",
            optionalGPS: nil,
            notes: "Deterministic capture driver output. No RoomPlan or device capture claim.",
            tags: ["simulated", "fixture"],
            thumbnailRelativePath: thumbnailRelativePath,
            archived: false
        )
        let thumbnailAsset = RoomAssetInput(
            sourceURL: thumbnailSource,
            destination: thumbnailRelativePath,
            scope: .project
        )
        let evidence = RoomRevisionEvidencePlan(
            source: .deterministicFixture,
            artifacts: RoomEvidenceArtifactKind.allCases.map { kind in
                RoomEvidenceArtifact(
                    kind: kind,
                    status: .unavailable,
                    relativePath: nil,
                    byteCount: nil,
                    mediaType: nil,
                    omissionReason: "The deterministic simulator driver has no Apple RoomPlan evidence.",
                    sha256Hex: nil
                )
            }
        )
        return RoomCapturePreparedReview(
            commit: RoomInitialCaptureCommit(
                draft: RoomDraft(metadata: metadata, revision: payload),
                evidence: evidence,
                assets: [thumbnailAsset] + photoAssets.map(\.asset)
            ),
            guidance: [.anotherPassHeuristic]
        )
    }

    func requestReferencePhoto(
        attempt: RoomCaptureAttemptToken,
        requestID: RoomReferencePhotoRequestID,
        workspace: RoomCaptureScratchWorkspace
    ) async throws {
        guard activeAttempt == attempt, activeWorkspace == workspace, !didStop else {
            throw RoomCaptureDriverError.noCapturedResult
        }
        if scenario.referencePhotoFails {
            throw RoomCaptureDriverError.simulatedFailure(
                "The deterministic driver was configured to fail the reference photo."
            )
        }
        let photoRelativePath = try RoomRelativePath(
            "photos/reference-\(requestID.value).png"
        )
        let photoURL = workspace.directoryURL.appendingPathComponent(
            photoRelativePath.value
        )
        try FileManager.default.createDirectory(
            at: photoURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try deterministicPNG.write(to: photoURL, options: .atomic)
        photoAssets.append((
            RoomPhoto(
                id: "photo-\(requestID.value)",
                createdAt: Self.fixtureDate,
                assetRelativePath: photoRelativePath,
                caption: "Deterministic simulated reference photo",
                cameraTransform: Self.identityTransform
            ),
            RoomAssetInput(
                sourceURL: photoURL,
                destination: photoRelativePath,
                scope: .revision
            )
        ))
    }

    func cancelProcessing(attempt: RoomCaptureAttemptToken) async {
        cancelledProcessingAttempts.insert(attempt)
        processingContinuation?.resume()
        processingContinuation = nil
    }

    func awaitScratchWriteBarrier(for attempt: RoomCaptureAttemptToken) async {}

    func cleanup(workspace: RoomCaptureScratchWorkspace) async throws {}

    private func makeSnapshot(
        attempt: RoomCaptureAttemptToken
    ) -> RoomSemanticSnapshot {
        let provenance = RoomElementProvenance(
            framework: "deterministic-simulator-driver",
            sourceIdentifier: "simulated-surface-001",
            classificationConfidence: .unknown,
            captureAttemptID: attempt.value,
            coordinateSpaceEpochID: "simulated-epoch-001"
        )
        let wall = RoomSemanticElement(
            id: "simulated-wall-001",
            kind: "wall",
            label: "Simulated wall",
            dimensionsMeters: RoomDimensions(width: 4.2, height: 2.7, depth: 0),
            transform: Self.identityTransform,
            polygonCorners: [
                RoomPoint3D(x: -2.1, y: 0, z: 0),
                RoomPoint3D(x: 2.1, y: 0, z: 0),
                RoomPoint3D(x: 2.1, y: 2.7, z: 0),
                RoomPoint3D(x: -2.1, y: 2.7, z: 0),
            ],
            provenance: provenance,
            mobility: .structural,
            origin: .deterministicFixture
        )
        let table = RoomSemanticElement(
            id: "simulated-table-001",
            kind: "table",
            label: "Simulated table",
            dimensionsMeters: RoomDimensions(width: 1.2, height: 0.74, depth: 0.8),
            transform: RoomTransform4x4(columnMajorValues: [
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                0.4, 0, -0.2, 1,
            ]),
            provenance: RoomElementProvenance(
                framework: "deterministic-simulator-driver",
                sourceIdentifier: "simulated-object-001",
                classificationConfidence: .unknown,
                captureAttemptID: attempt.value,
                coordinateSpaceEpochID: "simulated-epoch-001"
            ),
            mobility: .movable,
            origin: .deterministicFixture
        )
        return RoomSemanticSnapshot(
            projectID: "pending-project",
            revisionID: "pending-revision",
            units: "meters",
            accuracyDisclaimer: RoomCaptureState.nonSurveyAccuracyDisclaimer,
            structuralElements: [wall],
            objectElements: [table]
        )
    }

    private static let fixtureDate = Date(timeIntervalSince1970: 1_704_067_200)
    private static let identityTransform = RoomTransform4x4(columnMajorValues: [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    ])
    private let deterministicPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9JLC8AAAAASUVORK5CYII="
    ) ?? Data()
}

@MainActor
final class SimulatedRoomCaptureDriverFactory: RoomCaptureDriverFactory {
    private let scenario: SimulatedRoomCaptureScenario

    init(scenario: SimulatedRoomCaptureScenario = .init()) {
        self.scenario = scenario
    }

    func makeDriver() -> any RoomCaptureDriving {
        SimulatedRoomCaptureDriver(scenario: scenario)
    }
}
