import CoreGraphics
import Foundation
import RoomScanCore

enum SimulatedRoomQualityScenario: String, Sendable, Equatable {
    case good
    case blurred
    case uncovered
    case semanticLow
    case trackingLimited
    case combined
    case insufficient
}

/// UI-test and Simulator-only capture path. It writes attempt-local scratch
/// files and declares deterministic-fixture omissions; it never pretends to
/// contain RoomPlan JSON, native USDZ, raw mesh, or world-map bytes.
struct SimulatedRoomCaptureScenario: Sendable, Equatable {
    /// `Int.max` represents an intentionally persistent deterministic failure.
    var processingFailuresBeforeSuccess: Int
    var referencePhotoFails: Bool
    var suspendsProcessingUntilCancelled: Bool
    var quality: SimulatedRoomQualityScenario

    init(
        processingFails: Bool = false,
        processingFailuresBeforeSuccess: Int = 0,
        referencePhotoFails: Bool = false,
        suspendsProcessingUntilCancelled: Bool = false,
        quality: SimulatedRoomQualityScenario = .good
    ) {
        self.processingFailuresBeforeSuccess = processingFails
            ? Int.max
            : max(0, processingFailuresBeforeSuccess)
        self.referencePhotoFails = referencePhotoFails
        self.suspendsProcessingUntilCancelled = suspendsProcessingUntilCancelled
        self.quality = quality
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
        let snapshot = makeSnapshot(attempt: attempt)
        let liveCues = try Self.qualityAssessment(snapshot: snapshot, scenario: scenario.quality)
            .advisoryFindings
            .prefix(4)
            .map {
                RoomQualityCoachingCue(
                    dimension: $0.dimension,
                    reasonCode: $0.reasonCode,
                    affectedRegion: $0.affectedRegion,
                    disposition: $0.disposition
                )
            }
        observationHandler?(.qualityCoaching(attempt: attempt, values: Array(liveCues)))
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
        // The fixture geometry in `makeSnapshot` is fixed regardless of
        // attempt, so this remains byte-for-byte deterministic across runs
        // while drawing the same real floor-plan projection the real
        // RoomPlan-backed driver now draws (never the retired fake pattern).
        let snapshot = makeSnapshot(attempt: attempt)
        let thumbnailPNG = try RoomThumbnailRenderer.pngData(
            for: snapshot,
            size: CGSize(width: 640, height: 360)
        )
        try thumbnailPNG.write(to: thumbnailSource, options: .atomic)

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
        let qualityAssessment = try Self.qualityAssessment(
            snapshot: snapshot,
            scenario: scenario.quality
        )
        return RoomCapturePreparedReview(
            commit: RoomInitialCaptureCommit(
                draft: RoomDraft(metadata: metadata, revision: payload),
                evidence: evidence,
                assets: [thumbnailAsset] + photoAssets.map(\.asset),
                qualityAssessment: qualityAssessment
            ),
            guidance: [.anotherPassHeuristic],
            orientationSuggestion: try RoomOrientationSuggestionEngine.suggest(
                scanStartPose: RoomScanStartPose(
                    positionMeters: .init(x: -1.25, y: 1.55, z: -1.9),
                    forwardDirection: .init(x: 0, y: 0, z: 1),
                    coordinateSpaceEpochID: "simulated-epoch-001"
                ),
                candidates: [
                    .init(
                        featureID: "simulated-door-001",
                        semanticRole: .door,
                        positionMeters: .init(x: -1.25, y: 0, z: -2),
                        inwardDirection: .init(x: 0, y: 0, z: 1),
                        confidence: 0.9
                    ),
                    .init(
                        featureID: "simulated-opening-001",
                        semanticRole: .opening,
                        positionMeters: .init(x: 2, y: 0, z: 0.6),
                        inwardDirection: .init(x: -1, y: 0, z: 0),
                        confidence: 0.7
                    ),
                ]
            )
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
        func surface(
            id: String,
            kind: String,
            label: String,
            dimensions: RoomDimensions,
            x: Double,
            y: Double,
            z: Double
        ) -> RoomSemanticElement {
            RoomSemanticElement(
                id: id,
                kind: kind,
                label: label,
                dimensionsMeters: dimensions,
                transform: Self.translation(x: x, y: y, z: z),
                provenance: provenance,
                mobility: .structural,
                origin: .deterministicFixture
            )
        }
        let wall = RoomSemanticElement(
            id: "simulated-wall-001",
            kind: "wall",
            label: "Simulated wall",
            dimensionsMeters: RoomDimensions(width: 4.2, height: 2.7, depth: 0),
            transform: Self.translation(x: 0, y: 1.35, z: 2),
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
        let floor = surface(
            id: "simulated-floor-001", kind: "floor", label: "Simulated floor",
            dimensions: .init(width: 4.2, height: 0.05, depth: 4), x: 0, y: 0, z: 0
        )
        let ceiling = surface(
            id: "simulated-ceiling-001", kind: "ceiling", label: "Simulated ceiling",
            dimensions: .init(width: 4.2, height: 0.05, depth: 4), x: 0, y: 2.7, z: 0
        )
        let door = surface(
            id: "simulated-door-001", kind: "door", label: "Entry door",
            dimensions: .init(width: 0.9, height: 2, depth: 0.08), x: -1.25, y: 1, z: -2
        )
        let window = surface(
            id: "simulated-window-001", kind: "window", label: "East window",
            dimensions: .init(width: 1.4, height: 1.1, depth: 0.08), x: 2.05, y: 1.45, z: -0.4
        )
        let opening = surface(
            id: "simulated-opening-001", kind: "opening", label: "Side opening",
            dimensions: .init(width: 1.1, height: 2.2, depth: 0.08), x: 2.05, y: 1.1, z: 0.6
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
        let fixed = RoomSemanticElement(
            id: "simulated-fixed-001",
            kind: "cabinet",
            label: "Built-in cabinet",
            dimensionsMeters: .init(width: 1.1, height: 0.9, depth: 0.45),
            transform: Self.translation(x: -1.4, y: 0.45, z: 1.55),
            provenance: provenance,
            mobility: .fixed,
            origin: .deterministicFixture
        )
        let unknown = RoomSemanticElement(
            id: "simulated-unknown-001",
            kind: "unclassified",
            label: "Unclassified object",
            dimensionsMeters: .init(width: 0.5, height: 0.6, depth: 0.5),
            transform: Self.translation(x: 1.3, y: 0.3, z: 1.2),
            provenance: provenance,
            mobility: .unknown,
            origin: .deterministicFixture
        )
        return RoomSemanticSnapshot(
            projectID: "pending-project",
            revisionID: "pending-revision",
            units: "meters",
            accuracyDisclaimer: RoomCaptureState.nonSurveyAccuracyDisclaimer,
            structuralElements: [wall, door, window, opening, floor, ceiling],
            objectElements: [fixed, table, unknown]
        )
    }

    private static func qualityAssessment(
        snapshot: RoomSemanticSnapshot,
        scenario: SimulatedRoomQualityScenario
    ) throws -> RoomQualityAssessment {
        let regions = RoomCaptureQualityAnalyzer.makeRegions(snapshot: snapshot)
        func region(_ id: String) -> RoomQualityRegion? {
            regions.first { $0.regionID == id }
        }
        func evidence(_ id: String, _ kind: RoomQualityEvidenceKind) -> RoomQualityEvidenceReference {
            .init(evidenceID: id, kind: kind, sourceReference: "simulated-fixture/\(id)")
        }
        func finding(
            id: String,
            dimension: RoomQualityDimension,
            reason: RoomQualityReasonCode,
            regionID: String,
            kind: RoomQualityEvidenceKind,
            disposition: RoomQualityDisposition = .revisitRecommended
        ) -> RoomQualityFindingCandidate {
            .init(
                findingID: id,
                dimension: dimension,
                reasonCode: reason,
                evidenceReferences: [evidence("evidence-\(id)", kind)],
                affectedRegion: region(regionID),
                confidence: 0.82,
                disposition: disposition
            )
        }

        if scenario == .insufficient {
            return RoomQualityAssessment(
                coordinateSpaceEpochID: "simulated-epoch-001",
                records: RoomQualityDimension.allCases.map {
                    .init(dimension: $0, state: .insufficientEvidence, reasonCode: .insufficientEvidence, findings: [])
                }
            )
        }

        let sharpness = scenario == .blurred || scenario == .combined
            ? [finding(
                id: "sharpness-simulated-wall-001",
                dimension: .visualSharpness,
                reason: .blurredRegion,
                regionID: "simulated-wall-001",
                kind: .posedKeyframe
            )]
            : []
        let coverage = scenario == .uncovered || scenario == .combined
            ? [finding(
                id: "coverage-simulated-opening-001",
                dimension: .spatialVisualCoverage,
                reason: .uncoveredRegion,
                regionID: "simulated-opening-001",
                kind: .coverageProjection,
                disposition: .stronglyRecommendRevisit
            )]
            : []
        let tracking = scenario == .trackingLimited || scenario == .combined
            ? [finding(
                id: "tracking-simulated-door-001",
                dimension: .arTracking,
                reason: .trackingLimited,
                regionID: "simulated-door-001",
                kind: .trackingObservation
            )]
            : []
        let semantic = scenario == .semanticLow || scenario == .combined
            ? [finding(
                id: "semantic-simulated-unknown-001",
                dimension: .semanticIdentificationConfidence,
                reason: .semanticLowConfidence,
                regionID: "simulated-unknown-001",
                kind: .semanticElement
            )]
            : []
        return RoomQualityAssessment(
            coordinateSpaceEpochID: "simulated-epoch-001",
            records: [
                .init(
                    dimension: .visualSharpness,
                    state: sharpness.isEmpty ? .acceptable : .advisory,
                    reasonCode: sharpness.isEmpty ? .sharpnessAcceptable : .blurredRegion,
                    findings: sharpness
                ),
                .init(
                    dimension: .spatialVisualCoverage,
                    state: coverage.isEmpty ? .acceptable : .advisory,
                    reasonCode: coverage.isEmpty ? .coverageAcceptable : .uncoveredRegion,
                    findings: coverage
                ),
                .init(
                    dimension: .arTracking,
                    state: tracking.isEmpty ? .acceptable : .advisory,
                    reasonCode: tracking.isEmpty ? .trackingNormal : .trackingLimited,
                    findings: tracking
                ),
                .init(
                    dimension: .semanticIdentificationConfidence,
                    state: semantic.isEmpty ? .acceptable : .advisory,
                    reasonCode: semantic.isEmpty ? .semanticConfidenceAcceptable : .semanticLowConfidence,
                    findings: semantic
                ),
            ]
        )
    }

    private static let fixtureDate = Date(timeIntervalSince1970: 1_704_067_200)
    private static let identityTransform = RoomTransform4x4(columnMajorValues: [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    ])
    private static func translation(x: Double, y: Double, z: Double) -> RoomTransform4x4 {
        RoomTransform4x4(columnMajorValues: [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            x, y, z, 1,
        ])
    }
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
