import Foundation
import XCTest
import RoomScanCore
@testable import RoomScanStudio

@MainActor
final class RoomCaptureCoordinatorTests: XCTestCase {
    func testWeakFinishIsAdvisoryAndRequiresExactExplicitSaveAnyway() async throws {
        let assessment = try makeWeakQualityAssessment()
        let driver = CoordinatorTestDriver(
            preparedReview: RoomCapturePreparedReview(
                commit: makeCommit(
                    snapshot: makeSnapshot(label: "Weak quality"),
                    qualityAssessment: assessment
                )
            )
        )
        let configured = makeCoordinator(driver: driver, locationProvider: StaticLocationProvider(result: .denied))
        defer { try? FileManager.default.removeItem(at: configured.root) }

        configured.coordinator.prepare()
        await eventually { configured.coordinator.state.phase == .ready }
        configured.coordinator.start()
        await eventually { configured.coordinator.state.phase == .scanning }
        configured.coordinator.stop()
        await eventually { configured.coordinator.state.phase == .review }

        configured.coordinator.finish()
        XCTAssertEqual(configured.coordinator.state.phase, .review)
        XCTAssertTrue(configured.coordinator.finishReviewPresented)
        var summaries = try await configured.store.listSummaries(includeArchived: true)
        XCTAssertTrue(summaries.isEmpty)

        configured.coordinator.cancelFinishReview()
        XCTAssertFalse(configured.coordinator.finishReviewPresented)
        configured.coordinator.save()
        XCTAssertEqual(configured.coordinator.state.phase, .review)
        XCTAssertTrue(configured.coordinator.finishReviewPresented)
        summaries = try await configured.store.listSummaries(includeArchived: true)
        XCTAssertTrue(summaries.isEmpty)

        configured.coordinator.saveAnyway()
        await eventually { configured.coordinator.state.phase == .saved }
        let package = try await configured.store.load(projectID: "coordinator-project-001")
        let report = try XCTUnwrap(package.revisions.last?.manifest.qualityReport)
        XCTAssertEqual(report.finishEligibility, .reviewRecommended)
        XCTAssertEqual(report.saveAcknowledgement?.acknowledgedFindingIDs, ["coverage-wall-001"])
        XCTAssertEqual(report.records[1].findings.first?.affectedRegion?.regionID, "wall-001")
    }

    func testRevisitFromWeakFinishPublishesNoPartialQualityReport() async throws {
        let driver = CoordinatorTestDriver(
            preparedReview: RoomCapturePreparedReview(
                commit: makeCommit(
                    snapshot: makeSnapshot(label: "Revisit quality"),
                    qualityAssessment: try makeWeakQualityAssessment()
                )
            )
        )
        let configured = makeCoordinator(driver: driver, locationProvider: StaticLocationProvider(result: .denied))
        defer { try? FileManager.default.removeItem(at: configured.root) }

        configured.coordinator.prepare()
        await eventually { configured.coordinator.state.phase == .ready }
        configured.coordinator.start()
        await eventually { configured.coordinator.state.phase == .scanning }
        configured.coordinator.stop()
        await eventually { configured.coordinator.state.phase == .review }
        configured.coordinator.finish()
        configured.coordinator.revisitScan()
        await eventually { configured.coordinator.state.phase == .discarded }

        let summaries = try await configured.store.listSummaries(includeArchived: true)
        XCTAssertTrue(summaries.isEmpty)
    }

    func testGoodFinishProceedsWithoutSaveAnywayAcknowledgement() async throws {
        let assessment = RoomQualityAssessment(
            coordinateSpaceEpochID: "epoch-001",
            records: [
                .init(dimension: .visualSharpness, state: .acceptable, reasonCode: .sharpnessAcceptable, findings: []),
                .init(dimension: .spatialVisualCoverage, state: .acceptable, reasonCode: .coverageAcceptable, findings: []),
                .init(dimension: .arTracking, state: .acceptable, reasonCode: .trackingNormal, findings: []),
                .init(dimension: .semanticIdentificationConfidence, state: .acceptable, reasonCode: .semanticConfidenceAcceptable, findings: []),
            ]
        )
        let driver = CoordinatorTestDriver(
            preparedReview: RoomCapturePreparedReview(
                commit: makeCommit(snapshot: makeSnapshot(label: "Good quality"), qualityAssessment: assessment)
            )
        )
        let configured = makeCoordinator(driver: driver, locationProvider: StaticLocationProvider(result: .denied))
        defer { try? FileManager.default.removeItem(at: configured.root) }

        configured.coordinator.prepare()
        await eventually { configured.coordinator.state.phase == .ready }
        configured.coordinator.start()
        await eventually { configured.coordinator.state.phase == .scanning }
        configured.coordinator.stop()
        await eventually { configured.coordinator.state.phase == .review }
        configured.coordinator.finish()
        await eventually { configured.coordinator.state.phase == .saved }

        let package = try await configured.store.load(projectID: "coordinator-project-001")
        let report = try XCTUnwrap(package.revisions.last?.manifest.qualityReport)
        XCTAssertEqual(report.finishEligibility, .proceedNormally)
        XCTAssertNil(report.saveAcknowledgement)
    }

    func testReviewSnapshotIsFrozenAgainstLateSameTokenLiveUpdatesAndPersistence() async throws {
        let reviewSnapshot = makeSnapshot(label: "Reviewed semantic truth")
        let driver = CoordinatorTestDriver(
            preparedReview: RoomCapturePreparedReview(
                commit: makeCommit(snapshot: reviewSnapshot)
            )
        )
        let configured = makeCoordinator(driver: driver, locationProvider: StaticLocationProvider(result: .denied))
        defer { try? FileManager.default.removeItem(at: configured.root) }

        configured.coordinator.prepare()
        await eventually { configured.coordinator.state.phase == .ready }
        configured.coordinator.start()
        await eventually { configured.coordinator.state.phase == .scanning }

        driver.emitLiveSnapshot(
            makeSnapshot(label: "Live preview before processing")
        )
        configured.coordinator.stop()
        await eventually { configured.coordinator.state.phase == .review }

        let frozenReviewSnapshot = try XCTUnwrap(configured.coordinator.liveSnapshot)
        XCTAssertEqual(frozenReviewSnapshot, reviewSnapshot)
        driver.emitLiveSnapshot(
            makeSnapshot(label: "Late same-token preview must be ignored")
        )
        XCTAssertEqual(configured.coordinator.liveSnapshot, frozenReviewSnapshot)

        configured.coordinator.save()
        await eventually { configured.coordinator.state.phase == .saved }
        let package = try await configured.store.load(projectID: "coordinator-project-001")
        let persistedSnapshot = try XCTUnwrap(package.revisions.last?.payload.semanticSnapshot)
        XCTAssertEqual(persistedSnapshot.structuralElements, frozenReviewSnapshot.structuralElements)
        XCTAssertEqual(persistedSnapshot.objectElements, frozenReviewSnapshot.objectElements)
        XCTAssertEqual(persistedSnapshot.accuracyDisclaimer, frozenReviewSnapshot.accuracyDisclaimer)
    }

    func testGuidanceSeparatesSemanticAndOperationalSignalsAndClearsRecoveredState() async throws {
        XCTAssertEqual(
            RoomCaptureCoordinator.mergedGuidance(
                semantic: [.lowClassificationConfidence],
                operational: [.trackingLimited, .poorLightingHeuristic]
            ),
            [
                "Show uncertain features clearly from another angle.",
                "Add more light before continuing.",
                "Move slowly until tracking stabilizes.",
            ]
        )

        let driver = CoordinatorTestDriver(
            preparedReview: RoomCapturePreparedReview(
                commit: makeCommit(snapshot: makeSnapshot(label: "Guidance"))
            )
        )
        let configured = makeCoordinator(
            driver: driver,
            locationProvider: StaticLocationProvider(result: .denied)
        )
        defer { try? FileManager.default.removeItem(at: configured.root) }

        configured.coordinator.prepare()
        await eventually { configured.coordinator.state.phase == .ready }
        configured.coordinator.start()
        await eventually { configured.coordinator.state.phase == .scanning }

        driver.emitSemanticGuidance([.lowClassificationConfidence])
        driver.emitTracking(quality: .limited, limitedReason: .insufficientFeatures)
        driver.emitOperationalGuidance([.poorLightingHeuristic])
        XCTAssertEqual(
            configured.coordinator.qualitativeGuidance,
            [
                "Show uncertain features clearly from another angle.",
                "Add more light before continuing.",
                "Move slowly until tracking stabilizes.",
            ]
        )

        // A normal tracking state and bright operational observation must clear
        // their former warnings while retaining an independent semantic warning.
        driver.emitTracking(quality: .normal, limitedReason: nil)
        driver.emitOperationalGuidance([])
        XCTAssertEqual(
            configured.coordinator.qualitativeGuidance,
            ["Show uncertain features clearly from another angle."]
        )

        driver.emitSemanticGuidance([])
        XCTAssertTrue(configured.coordinator.qualitativeGuidance.isEmpty)
    }

    func testSessionEndObservationGateBlocksOwnershipReleaseUntilMatchingEnd() {
        let attempt = RoomCaptureAttemptToken("end-observation-001")
        var gate = RoomCaptureSessionEndObservationGate()

        XCTAssertFalse(gate.allowsOwnershipRelease(for: attempt))
        gate.recordDidEnd(for: RoomCaptureAttemptToken("different-attempt"))
        XCTAssertFalse(gate.allowsOwnershipRelease(for: attempt))
        gate.recordDidEnd(for: attempt)
        XCTAssertTrue(gate.allowsOwnershipRelease(for: attempt))
    }

    func testCleanupWaitsForFakeFinalEndThenExplicitRetryReleasesWorkspace() async throws {
        let driver = CoordinatorTestDriver(
            preparedReview: RoomCapturePreparedReview(
                commit: makeCommit(snapshot: makeSnapshot(label: "Final end retry"))
            ),
            cleanupRequiresFinalEnd: true
        )
        let configured = makeCoordinator(driver: driver, locationProvider: StaticLocationProvider(result: .denied))
        defer { try? FileManager.default.removeItem(at: configured.root) }

        configured.coordinator.prepare()
        await eventually { configured.coordinator.state.phase == .ready }
        configured.coordinator.start()
        await eventually { configured.coordinator.state.phase == .scanning }

        let workspacePath = try XCTUnwrap(driver.workspaceURL)
        configured.coordinator.discard()
        await eventually { configured.coordinator.cleanupErrorMessage != nil }
        XCTAssertEqual(configured.coordinator.state.phase, .discarding)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspacePath.path))
        XCTAssertFalse(driver.didCleanup)

        driver.recordFinalEnd()
        configured.coordinator.retryCleanup()
        await eventually { configured.coordinator.state.phase == .discarded }
        XCTAssertTrue(driver.didCleanup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspacePath.path))
    }

    func testTerminationPresentationGivesActionableRecoveryCopy() {
        XCTAssertTrue(
            RoomCaptureTerminationPresentation.message(for: .deviceTooHot)
                .contains("cool")
        )
        XCTAssertTrue(
            RoomCaptureTerminationPresentation.message(for: .exceedSceneSizeLimit)
                .contains("smaller")
        )
        XCTAssertTrue(
            RoomCaptureTerminationPresentation.message(for: .worldTrackingFailure)
                .contains("lighting")
        )
    }

    func testDiscardAwaitsSuspendedScratchWriterBeforeCleanupAndCreatesNoProfile() async throws {
        let driver = CoordinatorTestDriver(
            preparedReview: RoomCapturePreparedReview(
                commit: makeCommit(snapshot: makeSnapshot(label: "Never persisted"))
            ),
            suspendsProcessing: true
        )
        let configured = makeCoordinator(driver: driver, locationProvider: StaticLocationProvider(result: .denied))
        defer { try? FileManager.default.removeItem(at: configured.root) }

        configured.coordinator.prepare()
        await eventually { configured.coordinator.state.phase == .ready }
        configured.coordinator.start()
        await eventually { configured.coordinator.state.phase == .scanning }
        configured.coordinator.stop()
        await eventually { driver.didEnterProcessing }

        configured.coordinator.discard()
        await eventually { configured.coordinator.state.phase == .discarded }

        XCTAssertTrue(driver.didCleanup)
        XCTAssertFalse(driver.didWriteAfterCleanup)
        let expectedMarker = try XCTUnwrap(driver.expectedMarkerURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedMarker.path))
        let summaries = try await configured.store.listSummaries(includeArchived: true)
        XCTAssertTrue(summaries.isEmpty)
    }

    func testCleanupFailureRetainsDiscardingStateUntilExplicitRetry() async throws {
        let driver = CoordinatorTestDriver(
            preparedReview: RoomCapturePreparedReview(
                commit: makeCommit(snapshot: makeSnapshot(label: "Cleanup retry"))
            ),
            cleanupFailuresBeforeSuccess: 1
        )
        let configured = makeCoordinator(driver: driver, locationProvider: StaticLocationProvider(result: .denied))
        defer { try? FileManager.default.removeItem(at: configured.root) }

        configured.coordinator.prepare()
        await eventually { configured.coordinator.state.phase == .ready }
        configured.coordinator.start()
        await eventually { configured.coordinator.state.phase == .scanning }

        configured.coordinator.discard()
        await eventually { configured.coordinator.cleanupErrorMessage != nil }
        XCTAssertEqual(configured.coordinator.state.phase, .discarding)
        XCTAssertTrue(configured.coordinator.canRetryCleanup)

        configured.coordinator.retryCleanup()
        await eventually { configured.coordinator.state.phase == .discarded }
        XCTAssertTrue(driver.didCleanup)
        let summaries = try await configured.store.listSummaries(includeArchived: true)
        XCTAssertTrue(summaries.isEmpty)
    }

    func testDelayedGPSBlocksSaveAndCannotAttachAfterDiscard() async throws {
        let locationProvider = DeferredLocationProvider()
        let driver = CoordinatorTestDriver(
            preparedReview: RoomCapturePreparedReview(
                commit: makeCommit(snapshot: makeSnapshot(label: "GPS race"))
            )
        )
        let configured = makeCoordinator(driver: driver, locationProvider: locationProvider)
        defer { try? FileManager.default.removeItem(at: configured.root) }

        configured.coordinator.prepare()
        await eventually { configured.coordinator.state.phase == .ready }
        configured.coordinator.start()
        await eventually { configured.coordinator.state.phase == .scanning }
        configured.coordinator.stop()
        await eventually { configured.coordinator.state.phase == .review }

        configured.coordinator.requestGPS()
        await eventually { locationProvider.didReceiveRequest }
        XCTAssertTrue(configured.coordinator.state.gpsRequestInFlight)
        XCTAssertFalse(configured.coordinator.canSave)
        configured.coordinator.save()
        XCTAssertEqual(configured.coordinator.state.phase, .review)

        configured.coordinator.discard()
        await eventually { configured.coordinator.state.phase == .discarded }
        XCTAssertEqual(
            locationProvider.cancelledAttempts,
            [RoomCaptureAttemptToken("coordinator-attempt-001")]
        )
        XCTAssertFalse(locationProvider.hasOutstandingRequest)
        locationProvider.resolve(
            .authorized(
                RoomGPSLocation(
                    latitude: 40.7128,
                    longitude: -74.0060,
                    horizontalAccuracyMeters: 10,
                    capturedAt: Date(timeIntervalSince1970: 1_704_067_200)
                )
            )
        )
        await Task.yield()
        await Task.yield()

        XCTAssertNil(configured.coordinator.capturedGPS)
        let summaries = try await configured.store.listSummaries(includeArchived: true)
        XCTAssertTrue(summaries.isEmpty)
    }

    func testCaptureTerminationCancelsDelayedGPSAndIgnoresLateLocation() async throws {
        let locationProvider = DeferredLocationProvider()
        let driver = CoordinatorTestDriver(
            preparedReview: RoomCapturePreparedReview(
                commit: makeCommit(snapshot: makeSnapshot(label: "Termination GPS"))
            )
        )
        let configured = makeCoordinator(driver: driver, locationProvider: locationProvider)
        defer { try? FileManager.default.removeItem(at: configured.root) }

        configured.coordinator.prepare()
        await eventually { configured.coordinator.state.phase == .ready }
        configured.coordinator.start()
        await eventually { configured.coordinator.state.phase == .scanning }
        configured.coordinator.requestGPS()
        await eventually { locationProvider.didReceiveRequest }

        configured.coordinator.receiveDriverObservation(
            .terminated(
                attempt: RoomCaptureAttemptToken("coordinator-attempt-001"),
                reason: .deviceTooHot
            )
        )
        await eventually { configured.coordinator.state.phase == .failed }
        await eventually { !locationProvider.hasOutstandingRequest }

        XCTAssertEqual(
            locationProvider.cancelledAttempts,
            [RoomCaptureAttemptToken("coordinator-attempt-001")]
        )
        XCTAssertEqual(configured.coordinator.state.failure, .captureTerminated)

        locationProvider.resolve(
            .authorized(
                RoomGPSLocation(
                    latitude: 40.7128,
                    longitude: -74.0060,
                    horizontalAccuracyMeters: 10,
                    capturedAt: Date(timeIntervalSince1970: 1_704_067_200)
                )
            )
        )
        await Task.yield()
        XCTAssertNil(configured.coordinator.capturedGPS)
        let summaries = try await configured.store.listSummaries(includeArchived: true)
        XCTAssertTrue(summaries.isEmpty)
    }

    func testImmediateDiscardCancelsEffectTasksBeforeCameraOrCaptureDependencyEntry() async throws {
        let camera = DeferredCameraPermissionProvider()
        let driver = CoordinatorTestDriver(
            preparedReview: RoomCapturePreparedReview(
                commit: makeCommit(snapshot: makeSnapshot(label: "Immediate discard"))
            )
        )
        let configured = makeCoordinator(
            driver: driver,
            cameraPermissionProvider: camera,
            locationProvider: StaticLocationProvider(result: .denied)
        )
        defer { try? FileManager.default.removeItem(at: configured.root) }

        configured.coordinator.prepare()
        configured.coordinator.discard()
        await eventually { configured.coordinator.state.phase == .discarded }

        XCTAssertEqual(camera.requestCount, 0)
        XCTAssertEqual(driver.startCount, 0)
        XCTAssertEqual(driver.processCount, 0)
        XCTAssertEqual(driver.referencePhotoCount, 0)
    }

    func testImmediateDiscardCancelsQueuedStartBeforeDriverEntry() async throws {
        let driver = CoordinatorTestDriver(
            preparedReview: RoomCapturePreparedReview(
                commit: makeCommit(snapshot: makeSnapshot(label: "Queued start"))
            )
        )
        let configured = makeCoordinator(driver: driver, locationProvider: StaticLocationProvider(result: .denied))
        defer { try? FileManager.default.removeItem(at: configured.root) }

        configured.coordinator.prepare()
        await eventually { configured.coordinator.state.phase == .ready }
        configured.coordinator.start()
        configured.coordinator.discard()
        await eventually { configured.coordinator.state.phase == .discarded }

        XCTAssertEqual(driver.startCount, 0)
    }

    func testImmediateDiscardCancelsQueuedGPSBeforeProviderEntry() async throws {
        let locationProvider = DeferredLocationProvider()
        let driver = CoordinatorTestDriver(
            preparedReview: RoomCapturePreparedReview(
                commit: makeCommit(snapshot: makeSnapshot(label: "Queued GPS"))
            )
        )
        let configured = makeCoordinator(driver: driver, locationProvider: locationProvider)
        defer { try? FileManager.default.removeItem(at: configured.root) }

        configured.coordinator.prepare()
        await eventually { configured.coordinator.state.phase == .ready }
        configured.coordinator.start()
        await eventually { configured.coordinator.state.phase == .scanning }
        configured.coordinator.requestGPS()
        configured.coordinator.discard()
        await eventually { configured.coordinator.state.phase == .discarded }

        XCTAssertFalse(locationProvider.didReceiveRequest)
        XCTAssertFalse(locationProvider.hasOutstandingRequest)
    }

    func testImmediateDiscardCancelsQueuedProcessingBeforeDriverEntry() async throws {
        let driver = CoordinatorTestDriver(
            preparedReview: RoomCapturePreparedReview(
                commit: makeCommit(snapshot: makeSnapshot(label: "Queued processing"))
            )
        )
        let configured = makeCoordinator(driver: driver, locationProvider: StaticLocationProvider(result: .denied))
        defer { try? FileManager.default.removeItem(at: configured.root) }

        configured.coordinator.prepare()
        await eventually { configured.coordinator.state.phase == .ready }
        configured.coordinator.start()
        await eventually { configured.coordinator.state.phase == .scanning }
        configured.coordinator.stop()
        configured.coordinator.receiveDriverObservation(
            .didStop(attempt: RoomCaptureAttemptToken("coordinator-attempt-001"))
        )
        XCTAssertEqual(configured.coordinator.state.phase, .processing)
        configured.coordinator.discard()
        await eventually { configured.coordinator.state.phase == .discarded }

        XCTAssertEqual(driver.processCount, 0)
    }

    func testImmediateDiscardCancelsQueuedReferencePhotoBeforeDriverEntry() async throws {
        let driver = CoordinatorTestDriver(
            preparedReview: RoomCapturePreparedReview(
                commit: makeCommit(snapshot: makeSnapshot(label: "Queued photo"))
            )
        )
        let configured = makeCoordinator(driver: driver, locationProvider: StaticLocationProvider(result: .denied))
        defer { try? FileManager.default.removeItem(at: configured.root) }

        configured.coordinator.prepare()
        await eventually { configured.coordinator.state.phase == .ready }
        configured.coordinator.start()
        await eventually { configured.coordinator.state.phase == .scanning }
        configured.coordinator.requestReferencePhoto()
        configured.coordinator.discard()
        await eventually { configured.coordinator.state.phase == .discarded }

        XCTAssertEqual(driver.referencePhotoCount, 0)
    }

    func testAuthorizedGPSAndReferencePhotoSavePersistMetadataPhotoDocumentAndBytes() async throws {
        let gps = RoomGPSLocation(
            latitude: 40.7128,
            longitude: -74.0060,
            horizontalAccuracyMeters: 9,
            capturedAt: Date(timeIntervalSince1970: 1_704_067_201)
        )
        let driver = SimulatedRoomCaptureDriver()
        let configured = makeCoordinator(
            driver: driver,
            locationProvider: StaticLocationProvider(result: .authorized(gps))
        )
        defer { try? FileManager.default.removeItem(at: configured.root) }

        configured.coordinator.prepare()
        await eventually { configured.coordinator.state.phase == .ready }
        configured.coordinator.requestGPS()
        await eventually {
            configured.coordinator.state.gpsPermission == .authorized
                && !configured.coordinator.state.gpsRequestInFlight
        }
        configured.coordinator.start()
        await eventually { configured.coordinator.state.phase == .scanning }
        configured.coordinator.requestReferencePhoto()
        await eventually { configured.coordinator.state.referencePhotoCount == 1 }
        configured.coordinator.stop()
        await eventually { configured.coordinator.state.phase == .review }
        configured.coordinator.save()
        await eventually { configured.coordinator.state.phase == .saved }

        let package = try await configured.store.load(projectID: "coordinator-project-001")
        XCTAssertEqual(package.metadata.optionalGPS, gps)
        let revision = try XCTUnwrap(package.revisions.last)
        let photo = try XCTUnwrap(revision.payload.photos.first)
        let expectedPhotoPath = try RoomRelativePath("photos/reference-photo-request-1.png")
        XCTAssertEqual(photo.assetRelativePath, expectedPhotoPath)

        let copiedPhotoURL = configured.root
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("coordinator-project-001", isDirectory: true)
            .appendingPathComponent("revisions", isDirectory: true)
            .appendingPathComponent("revision-001", isDirectory: true)
            .appendingPathComponent(photo.assetRelativePath.value)
        let expectedPhotoBytes = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9JLC8AAAAASUVORK5CYII="
        ))
        let copiedPhotoBytes = try Data(contentsOf: copiedPhotoURL)
        XCTAssertEqual(copiedPhotoBytes, expectedPhotoBytes)
    }

    func testCoordinatorLeaseReusesTheFirstDriverConstructionUntilTerminalRelease() {
        let lease = RoomCaptureCoordinatorLease()
        let leaseRoot = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: leaseRoot) }
        var constructionCount = 0
        let first = lease.acquire {
            constructionCount += 1
            return self.makeLeaseCoordinator(root: leaseRoot)
        }
        let second = lease.acquire {
            constructionCount += 1
            return self.makeLeaseCoordinator(root: leaseRoot)
        }

        XCTAssertTrue(first === second)
        XCTAssertEqual(constructionCount, 1)
        lease.release(first)
        let third = lease.acquire {
            constructionCount += 1
            return self.makeLeaseCoordinator(root: leaseRoot)
        }
        XCTAssertTrue(third === first)
        XCTAssertEqual(constructionCount, 1)
    }

    func testScratchFactoryRejectsLinkedRootAndUnsafeCleanupTargetWhenSupported() throws {
        let fileManager = FileManager.default
        let root = temporaryRoot()
        defer { try? fileManager.removeItem(at: root) }
        let external = root.appendingPathComponent("external", isDirectory: true)
        let linkedRoot = root.appendingPathComponent("linked-scratch", isDirectory: true)
        try fileManager.createDirectory(at: external, withIntermediateDirectories: true)
        do {
            try fileManager.createSymbolicLink(
                at: linkedRoot,
                withDestinationURL: external
            )
        } catch {
            throw XCTSkip("The host filesystem does not permit symbolic-link creation for this test.")
        }

        let linkedFactory = RoomCaptureScratchWorkspaceFactory(rootURL: linkedRoot)
        XCTAssertThrowsError(
            try linkedFactory.makeWorkspace(for: RoomCaptureAttemptToken("linked-root"))
        )

        let safeRoot = root.appendingPathComponent("safe-scratch", isDirectory: true)
        let safeFactory = RoomCaptureScratchWorkspaceFactory(rootURL: safeRoot)
        try fileManager.createDirectory(at: safeRoot, withIntermediateDirectories: true)
        let unsafeWorkspace = RoomCaptureScratchWorkspace(
            attempt: RoomCaptureAttemptToken("unsafe-cleanup"),
            directoryURL: external
        )
        XCTAssertThrowsError(try safeFactory.cleanup(unsafeWorkspace))
        XCTAssertTrue(fileManager.fileExists(atPath: external.path))

        let orphan = safeRoot.appendingPathComponent("attempt-orphan-001", isDirectory: true)
        try fileManager.createDirectory(at: orphan, withIntermediateDirectories: false)
        try safeFactory.recoverOwnedOrphans()
        XCTAssertFalse(fileManager.fileExists(atPath: orphan.path))
    }

    private func makeLeaseCoordinator(root: URL) -> RoomCaptureCoordinator {
        let store = LocalRoomProjectStore(rootURL: root)
        let controller = RoomLibraryController(store: store, modelContainer: nil)
        return RoomCaptureCoordinator(
            controller: controller,
            cameraPermissionProvider: StaticCameraPermissionProvider(permission: .authorized),
            locationProvider: StaticLocationProvider(result: .denied),
            workspaceFactory: RoomCaptureScratchWorkspaceFactory(
                rootURL: root.appendingPathComponent("scratch", isDirectory: true)
            ),
            driver: CoordinatorTestDriver(
                preparedReview: RoomCapturePreparedReview(
                    commit: makeCommit(snapshot: makeSnapshot(label: "Lease"))
                )
            ),
            savePolicy: AcceptingRoomCaptureSavePolicy(),
            attemptGenerator: DeterministicRoomCaptureAttemptIDGenerator(values: ["lease-attempt"])
        )
    }

    private func makeCoordinator(
        driver: any RoomCaptureDriving,
        cameraPermissionProvider: (any RoomCameraPermissionProviding)? = nil,
        locationProvider: any RoomLocationProviding
    ) -> (coordinator: RoomCaptureCoordinator, store: LocalRoomProjectStore, root: URL) {
        let root = temporaryRoot()
        let store = LocalRoomProjectStore(
            rootURL: root.appendingPathComponent("projects", isDirectory: true),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: ["coordinator-project-001"],
                revisionIDs: ["revision-001"]
            )
        )
        let controller = RoomLibraryController(store: store, modelContainer: nil)
        let coordinator = RoomCaptureCoordinator(
            controller: controller,
            cameraPermissionProvider: cameraPermissionProvider
                ?? StaticCameraPermissionProvider(permission: .authorized),
            locationProvider: locationProvider,
            workspaceFactory: RoomCaptureScratchWorkspaceFactory(
                rootURL: root.appendingPathComponent("scratch", isDirectory: true)
            ),
            driver: driver,
            savePolicy: AcceptingRoomCaptureSavePolicy(),
            attemptGenerator: DeterministicRoomCaptureAttemptIDGenerator(
                values: ["coordinator-attempt-001"]
            )
        )
        return (coordinator, store, root)
    }

    private func makeCommit(
        snapshot: RoomSemanticSnapshot,
        qualityAssessment: RoomQualityAssessment? = nil
    ) -> RoomInitialCaptureCommit {
        let date = Date(timeIntervalSince1970: 1_704_067_200)
        return RoomInitialCaptureCommit(
            draft: RoomDraft(
                metadata: RoomMetadata(
                    projectID: "pending-project",
                    customName: "Coordinator test room",
                    captureDate: date,
                    lastRevisedDate: date,
                    manualLocation: "Test lab",
                    optionalGPS: nil,
                    notes: "",
                    tags: [],
                    thumbnailRelativePath: nil,
                    archived: false
                ),
                revision: RoomRevisionPayload(
                    semanticSnapshot: snapshot,
                    annotations: [],
                    measurements: [],
                    photos: []
                )
            ),
            qualityAssessment: qualityAssessment
        )
    }

    private func makeWeakQualityAssessment() throws -> RoomQualityAssessment {
        let region = try RoomQualityRegion(
            regionID: "wall-001",
            label: "East wall",
            semanticElementID: "wall-001",
            dimensionsMeters: .init(width: 3, height: 2.4, depth: 0.08),
            roomTransform: .init(columnMajorValues: [
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                1.5, 1.2, 0, 1,
            ])
        )
        let finding = RoomQualityFindingCandidate(
            findingID: "coverage-wall-001",
            dimension: .spatialVisualCoverage,
            reasonCode: .uncoveredRegion,
            evidenceReferences: [
                .init(
                    evidenceID: "coverage-evidence-001",
                    kind: .coverageProjection,
                    sourceReference: "fixture/coverage-evidence-001"
                ),
            ],
            affectedRegion: region,
            confidence: 0.9,
            disposition: .stronglyRecommendRevisit
        )
        return .init(
            coordinateSpaceEpochID: "epoch-001",
            records: [
                .init(dimension: .visualSharpness, state: .acceptable, reasonCode: .sharpnessAcceptable, findings: []),
                .init(dimension: .spatialVisualCoverage, state: .advisory, reasonCode: .uncoveredRegion, findings: [finding]),
                .init(dimension: .arTracking, state: .acceptable, reasonCode: .trackingNormal, findings: []),
                .init(dimension: .semanticIdentificationConfidence, state: .acceptable, reasonCode: .semanticConfidenceAcceptable, findings: []),
            ]
        )
    }

    private func makeSnapshot(label: String) -> RoomSemanticSnapshot {
        RoomSemanticSnapshot(
            projectID: "pending-project",
            revisionID: "pending-revision",
            units: "meters",
            accuracyDisclaimer: RoomCaptureState.nonSurveyAccuracyDisclaimer,
            structuralElements: [
                RoomSemanticElement(
                    id: "wall-001",
                    kind: "wall",
                    label: label,
                    dimensionsMeters: RoomDimensions(width: 3, height: 2.4, depth: 0)
                )
            ],
            objectElements: []
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "RoomCaptureCoordinatorTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func eventually(
        _ condition: @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition did not become true.", file: file, line: line)
    }
}

@MainActor
private final class CoordinatorTestDriver: RoomCaptureDriving {
    var observationHandler: ((RoomCaptureDriverObservation) -> Void)?

    private let preparedReview: RoomCapturePreparedReview
    private let suspendsProcessing: Bool
    private let cleanupRequiresFinalEnd: Bool
    private var cleanupFailuresRemaining: Int
    private var activeAttempt: RoomCaptureAttemptToken?
    private var workspace: RoomCaptureScratchWorkspace?
    private var processingContinuation: CheckedContinuation<Void, Never>?
    private var finalEndObserved = false

    private(set) var didEnterProcessing = false
    private(set) var didCleanup = false
    private(set) var didWriteAfterCleanup = false
    private(set) var markerURL: URL?
    private(set) var expectedMarkerURL: URL?
    private(set) var startCount = 0
    private(set) var processCount = 0
    private(set) var referencePhotoCount = 0

    var workspaceURL: URL? {
        workspace?.directoryURL
    }

    init(
        preparedReview: RoomCapturePreparedReview,
        suspendsProcessing: Bool = false,
        cleanupFailuresBeforeSuccess: Int = 0,
        cleanupRequiresFinalEnd: Bool = false
    ) {
        self.preparedReview = preparedReview
        self.suspendsProcessing = suspendsProcessing
        self.cleanupFailuresRemaining = cleanupFailuresBeforeSuccess
        self.cleanupRequiresFinalEnd = cleanupRequiresFinalEnd
    }

    func start(
        attempt: RoomCaptureAttemptToken,
        workspace: RoomCaptureScratchWorkspace
    ) async throws {
        startCount += 1
        activeAttempt = attempt
        self.workspace = workspace
        observationHandler?(.didStart(attempt: attempt))
    }

    func stop(attempt: RoomCaptureAttemptToken) async throws {
        guard activeAttempt == attempt else {
            throw RoomCaptureDriverError.invalidAttempt
        }
        observationHandler?(.didStop(attempt: attempt))
    }

    func terminate(attempt: RoomCaptureAttemptToken) async {}

    func process(
        attempt: RoomCaptureAttemptToken,
        workspace: RoomCaptureScratchWorkspace
    ) async throws -> RoomCapturePreparedReview {
        processCount += 1
        guard activeAttempt == attempt, self.workspace == workspace else {
            throw RoomCaptureDriverError.noCapturedResult
        }
        if suspendsProcessing {
            didEnterProcessing = true
            expectedMarkerURL = workspace.directoryURL.appendingPathComponent(
                "late-writer-marker"
            )
            await withCheckedContinuation { continuation in
                processingContinuation = continuation
            }
            try Task.checkCancellation()
            guard let marker = expectedMarkerURL else {
                throw RoomCaptureDriverError.noScratchWorkspace
            }
            try Data("processed".utf8).write(to: marker, options: .atomic)
            markerURL = marker
            didWriteAfterCleanup = didCleanup
        }
        return preparedReview
    }

    func requestReferencePhoto(
        attempt: RoomCaptureAttemptToken,
        requestID: RoomReferencePhotoRequestID,
        workspace: RoomCaptureScratchWorkspace
    ) async throws {
        referencePhotoCount += 1
    }

    func cancelProcessing(attempt: RoomCaptureAttemptToken) async {
        processingContinuation?.resume()
        processingContinuation = nil
    }

    func awaitScratchWriteBarrier(for attempt: RoomCaptureAttemptToken) async {}

    func cleanup(workspace: RoomCaptureScratchWorkspace) async throws {
        guard !cleanupRequiresFinalEnd || finalEndObserved else {
            throw RoomCaptureScratchError.cleanupFailed(workspace.directoryURL.path)
        }
        if cleanupFailuresRemaining > 0 {
            cleanupFailuresRemaining -= 1
            throw RoomCaptureScratchError.cleanupFailed(workspace.directoryURL.path)
        }
        didCleanup = true
    }

    func recordFinalEnd() {
        finalEndObserved = true
    }

    func emitLiveSnapshot(_ snapshot: RoomSemanticSnapshot) {
        guard let activeAttempt else { return }
        observationHandler?(.liveSnapshot(attempt: activeAttempt, snapshot: snapshot))
    }

    func emitSemanticGuidance(_ values: [RoomCaptureGuidance]) {
        guard let activeAttempt else { return }
        observationHandler?(.semanticGuidance(attempt: activeAttempt, values: values))
    }

    func emitOperationalGuidance(_ values: [RoomCaptureGuidance]) {
        guard let activeAttempt else { return }
        observationHandler?(.operationalGuidance(attempt: activeAttempt, values: values))
    }

    func emitTracking(
        quality: RoomTrackingQuality,
        limitedReason: RoomTrackingLimitedReason?
    ) {
        guard let activeAttempt else { return }
        observationHandler?(
            .tracking(
                attempt: activeAttempt,
                quality: quality,
                limitedReason: limitedReason
            )
        )
    }
}

@MainActor
private final class DeferredLocationProvider: RoomLocationProviding {
    private var continuation: CheckedContinuation<RoomCaptureGPSResult, Never>?
    private var activeAttempt: RoomCaptureAttemptToken?
    private(set) var didReceiveRequest = false
    private(set) var cancelledAttempts: [RoomCaptureAttemptToken] = []

    var hasOutstandingRequest: Bool {
        continuation != nil
    }

    func requestCurrentLocation(
        for attempt: RoomCaptureAttemptToken
    ) async -> RoomCaptureGPSResult {
        didReceiveRequest = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            activeAttempt = attempt
        }
    }

    func cancelCurrentLocation(for attempt: RoomCaptureAttemptToken) async {
        guard activeAttempt == attempt else { return }
        cancelledAttempts.append(attempt)
        activeAttempt = nil
        let pending = continuation
        continuation = nil
        pending?.resume(returning: .denied)
    }

    func resolve(_ result: RoomCaptureGPSResult) {
        let pending = continuation
        continuation = nil
        activeAttempt = nil
        pending?.resume(returning: result)
    }
}

@MainActor
private final class DeferredCameraPermissionProvider: RoomCameraPermissionProviding {
    private(set) var requestCount = 0

    func requestCameraPermission(
        for attempt: RoomCaptureAttemptToken
    ) async -> RoomCapturePermission {
        requestCount += 1
        return .authorized
    }
}
