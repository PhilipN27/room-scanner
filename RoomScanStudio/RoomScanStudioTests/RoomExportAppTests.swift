import Foundation
import XCTest
import RoomScanCore
@testable import RoomScanStudio

@MainActor
final class RoomExportAppTests: XCTestCase {
    func testCoordinatorPublishesPreparedArchiveAndRetainsLeaseUntilShareCompletion() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RoomExportAppLease-\(UUID().uuidString)",
            isDirectory: true
        )
        let archive = workspace.appendingPathComponent("head-revision-export.zip")
        let provider = FakeRoomExportProvider(
            result: RoomExportResult(
                archiveURL: archive,
                workspaceURL: workspace,
                receipt: RoomExportReceipt(
                    projectID: "project-001",
                    headRevisionID: "revision-001",
                    archiveSHA256: String(repeating: "a", count: 64),
                    archiveByteCount: 12,
                    manifestSHA256: String(repeating: "b", count: 64),
                    profileVersion: RoomDeterministicZIP.profileVersion
                )
            )
        )
        let cleaner = FakeRoomExportWorkspaceCleaner()
        let coordinator = RoomExportCoordinator(provider: provider, cleaner: cleaner)

        await coordinator.prepare(projectID: "project-001", expectedHeadRevisionID: "revision-001")

        XCTAssertEqual(coordinator.state, .ready)
        XCTAssertEqual(coordinator.readyResult?.archiveURL, archive)
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(provider.requests.first?.projectID, "project-001")
        XCTAssertEqual(provider.requests.first?.headRevisionID, "revision-001")
        XCTAssertTrue(cleaner.cleanedWorkspaces.isEmpty)

        await coordinator.completeShare(completed: true)

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(cleaner.cleanedWorkspaces, [workspace])
    }

    func testCoordinatorExposesFailureAndStaleHeadWithoutInvokingShare() async throws {
        let provider = FakeRoomExportProvider(error: RoomExportError.staleHead(
            projectID: "project-001",
            expected: "revision-001",
            actual: "revision-002"
        ))
        let cleaner = FakeRoomExportWorkspaceCleaner()
        let coordinator = RoomExportCoordinator(provider: provider, cleaner: cleaner)

        await coordinator.prepare(projectID: "project-001", expectedHeadRevisionID: "revision-001")

        XCTAssertEqual(coordinator.state, .failed)
        XCTAssertNotNil(coordinator.errorMessage)
        XCTAssertNil(coordinator.readyResult)
        XCTAssertTrue(cleaner.cleanedWorkspaces.isEmpty)
    }

    func testShareCompletionCleansOnlyTheFinalizedWorkspaceAndCanRetryCleanup() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RoomExportAppCleanup-\(UUID().uuidString)",
            isDirectory: true
        )
        let archive = workspace.appendingPathComponent("head-revision-export.zip")
        let provider = FakeRoomExportProvider(
            result: RoomExportResult(
                archiveURL: archive,
                workspaceURL: workspace,
                receipt: RoomExportReceipt(
                    projectID: "project-001",
                    headRevisionID: "revision-001",
                    archiveSHA256: String(repeating: "c", count: 64),
                    archiveByteCount: 12,
                    manifestSHA256: String(repeating: "d", count: 64),
                    profileVersion: RoomDeterministicZIP.profileVersion
                )
            )
        )
        let cleaner = FakeRoomExportWorkspaceCleaner(failuresBeforeSuccess: 1)
        let coordinator = RoomExportCoordinator(provider: provider, cleaner: cleaner)

        await coordinator.prepare(projectID: "project-001", expectedHeadRevisionID: "revision-001")
        await coordinator.completeShare(completed: false)

        XCTAssertEqual(coordinator.state, .cleanupFailed)
        XCTAssertEqual(cleaner.cleanedWorkspaces, [])
        await coordinator.retryCleanup()
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(cleaner.cleanedWorkspaces, [workspace])
    }

    func testSystemShareOutcomeTreatsAnActualErrorAsFailureRegardlessOfCompletionFlag() {
        XCTAssertEqual(
            SystemShareSheetOutcome(completed: true, error: InjectedShareError.failed),
            .failed
        )
        XCTAssertEqual(
            SystemShareSheetOutcome(completed: false, error: InjectedShareError.failed),
            .failed
        )
        XCTAssertEqual(SystemShareSheetOutcome(completed: true, error: nil), .completed)
        XCTAssertEqual(SystemShareSheetOutcome(completed: false, error: nil), .cancelled)
    }

    func testShareErrorIsSurfacedOnlyAfterItsExactLeaseIsCleaned() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RoomExportShareError-\(UUID().uuidString)",
            isDirectory: true
        )
        let provider = FakeRoomExportProvider(result: makeResult(workspace: workspace))
        var stateDuringCleanup: RoomExportCoordinatorState?
        var errorDuringCleanup: String?
        var coordinator: RoomExportCoordinator!
        let cleaner = FakeRoomExportWorkspaceCleaner(onCleanupAttempt: {
            stateDuringCleanup = coordinator.state
            errorDuringCleanup = coordinator.errorMessage
        })
        coordinator = RoomExportCoordinator(provider: provider, cleaner: cleaner)

        await coordinator.prepare(projectID: "project-001", expectedHeadRevisionID: "revision-001")
        await coordinator.completeShare(outcome: .failed)

        XCTAssertEqual(cleaner.cleanupAttempts, [workspace])
        XCTAssertEqual(cleaner.cleanedWorkspaces, [workspace])
        XCTAssertEqual(stateDuringCleanup, .ready)
        XCTAssertNil(errorDuringCleanup)
        XCTAssertEqual(coordinator.state, .failed)
        XCTAssertNil(coordinator.readyResult)
        XCTAssertTrue(coordinator.errorMessage?.contains("Share Sheet could not complete") == true)
    }

    func testDuplicateShareOutcomesDoNotRetryCleanupAndDeferredErrorSurfacesAfterExplicitRetry() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RoomExportShareIdempotence-\(UUID().uuidString)",
            isDirectory: true
        )
        let provider = FakeRoomExportProvider(result: makeResult(workspace: workspace))
        let cleaner = FakeRoomExportWorkspaceCleaner(failuresBeforeSuccess: 1)
        let coordinator = RoomExportCoordinator(provider: provider, cleaner: cleaner)

        await coordinator.prepare(projectID: "project-001", expectedHeadRevisionID: "revision-001")
        await coordinator.completeShare(outcome: .failed)
        await coordinator.completeShare(outcome: .cancelled)

        XCTAssertEqual(coordinator.state, .cleanupFailed)
        XCTAssertEqual(cleaner.cleanupAttempts, [workspace])
        XCTAssertTrue(cleaner.cleanedWorkspaces.isEmpty)
        XCTAssertTrue(coordinator.errorMessage?.contains("Retry cleanup") == true)

        await coordinator.retryCleanup()

        XCTAssertEqual(cleaner.cleanupAttempts, [workspace, workspace])
        XCTAssertEqual(cleaner.cleanedWorkspaces, [workspace])
        XCTAssertEqual(coordinator.state, .failed)
        XCTAssertNil(coordinator.readyResult)
        XCTAssertTrue(coordinator.errorMessage?.contains("Share Sheet could not complete") == true)
    }

    /// This is an in-process `AppEnvironment` bootstrap/integration oracle,
    /// not an XCUITest app-process launch or a physical Share Sheet proof.
    /// It covers the current local-only route through simulated capture, save,
    /// package view/edit, and legacy head-export preparation. Future AI package
    /// and concept-import routes are deliberately outside this Slice 0 oracle.
    func testGuestSimulatedCaptureEditAndLegacyExportStayOffline() async throws {
        let arguments = [
            "--ui-testing",
            "--reset-local-store",
            "--use-simulated-capture",
            "--use-mock-fixture",
        ]
        defer { cleanupGuestOfflineProjectAndCaptureScratch(arguments: arguments) }

        let environment = AppEnvironment(arguments: arguments)
        XCTAssertFalse(environment.professionalEnvironmentFactory.hasConstructedEnvironment)
        let capture = environment.acquireCaptureCoordinator()
        capture.prepare()
        try await awaitCapturePhase(capture, .ready)
        capture.start()
        try await awaitCapturePhase(capture, .scanning)
        capture.stop()
        try await awaitCapturePhase(capture, .review)
        capture.roomName = "Offline guest capture"
        capture.save()
        try await awaitCapturePhase(capture, .saved)
        environment.releaseCaptureCoordinator(capture)

        await environment.libraryController.refreshLibrary()
        XCTAssertEqual(environment.libraryController.summaries.count, 1)
        let summary = try XCTUnwrap(environment.libraryController.summaries.first)
        let initialPackage = try await environment.libraryController.loadPackage(
            projectID: summary.projectID
        )
        let initialRevision = try XCTUnwrap(initialPackage.revisions.last)
        var editor = try RoomRevisionEditor(payload: initialRevision.payload)
        try editor.renameElement(
            id: "simulated-table-001",
            label: "Offline edited table"
        )
        let editedRevision = try await environment.libraryController.commitEditRevision(
            projectID: summary.projectID,
            expectedHeadRevisionID: initialPackage.manifest.headRevisionID,
            payload: editor.payload
        )
        XCTAssertEqual(editedRevision.reason, RoomRevisionReason.edit)

        await environment.exportCoordinator.prepare(
            projectID: summary.projectID,
            expectedHeadRevisionID: editedRevision.revisionID
        )
        XCTAssertEqual(environment.exportCoordinator.state, .ready)
        let preparedExport = try XCTUnwrap(environment.exportCoordinator.readyResult)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preparedExport.archiveURL.path))
        await environment.exportCoordinator.completeShare(completed: false)
        XCTAssertEqual(environment.exportCoordinator.state, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preparedExport.workspaceURL.path))

        XCTAssertFalse(environment.professionalEnvironmentFactory.hasConstructedEnvironment)
        XCTAssertEqual(environment.professionalEnvironmentFactory.state, .notEntered)
    }

    func testControllerMaterializesFixtureHeadWithCanonicalJSONThumbnailAndReferencePhoto() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RoomExportControllerFixture-\(UUID().uuidString)",
            isDirectory: true
        )
        let workspace = root.deletingLastPathComponent().appendingPathComponent(
            "RoomExportControllerWorkspace-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: workspace)
        }
        let store = LocalRoomProjectStore(
            rootURL: root,
            clock: FixedRoomProjectClock(date: Date(timeIntervalSince1970: 1_704_067_200)),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: ["export-fixture-project"],
                revisionIDs: ["revision-001"]
            )
        )
        let fixture = try MockRoomFixtureLoader.load(bundle: Bundle(for: Self.self))
        let savedResult = try await store.saveDraft(
            fixture.draft,
            decision: .save,
            assets: fixture.assets
        )
        let saved = try XCTUnwrap(savedResult)
        let controller = RoomLibraryController(store: store, modelContainer: nil)
        let materialization = try await controller.materializeHeadForExport(
            projectID: saved.projectID,
            expectedHeadRevisionID: saved.headRevisionID,
            into: workspace
        )
        let paths = Set(materialization.entries.map { $0.entryPath.value })

        XCTAssertTrue(paths.isSuperset(of: [
            "metadata.json",
            "revision/revision.json",
            "revision/semantic-model.json",
            "revision/annotations.json",
            "revision/measurements.json",
            "revision/photos.json",
        ]))
        XCTAssertTrue(paths.contains { $0.hasPrefix("assets/thumbnail.") })
        XCTAssertTrue(paths.contains { $0.hasPrefix("assets/photos/photo-") })

        let exportedMetadata = try RoomJSONCoding.makeDecoder().decode(
            RoomMetadata.self,
            from: Data(contentsOf: workspace.appendingPathComponent("metadata.json"))
        )
        let exportedPhotos = try RoomJSONCoding.makeDecoder().decode(
            RoomPhotosDocument.self,
            from: Data(contentsOf: workspace.appendingPathComponent("revision/photos.json"))
        )
        let sourceMap = try RoomJSONCoding.makeDecoder().decode(
            RoomExportSourceMap.self,
            from: Data(contentsOf: workspace.appendingPathComponent("source-map.json"))
        )
        let thumbnailPath = try XCTUnwrap(exportedMetadata.thumbnailRelativePath).value
        let firstPhoto = try XCTUnwrap(exportedPhotos.photos.first)
        XCTAssertTrue(paths.contains(thumbnailPath))
        for photo in exportedPhotos.photos {
            XCTAssertTrue(paths.contains(photo.assetRelativePath.value))
        }
        XCTAssertEqual(
            sourceMap.mappings.first {
                $0.scope == .project && $0.sourceReference == "thumbnails/thumbnail.png"
            }?.archivePath,
            thumbnailPath
        )
        XCTAssertEqual(
            sourceMap.mappings.first {
                $0.scope == .revision && $0.sourceReference == "photos/reference-001.png"
            }?.archivePath,
            firstPhoto.assetRelativePath.value
        )
    }

    func testPreparationAndCleanupFailureRetainsOnlyExactLeaseForRetry() async throws {
        let lease = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RoomExportPreparationCleanup-\(UUID().uuidString)",
            isDirectory: true
        )
        let provider = FakeRoomExportProvider(error: RoomExportLeaseCleanupError(
            workspaceURL: lease,
            message: "Injected preparation plus cleanup failure."
        ))
        let cleaner = FakeRoomExportWorkspaceCleaner()
        let coordinator = RoomExportCoordinator(provider: provider, cleaner: cleaner)

        await coordinator.prepare(projectID: "project-001", expectedHeadRevisionID: "revision-001")

        XCTAssertEqual(coordinator.state, .cleanupFailed)
        XCTAssertNil(coordinator.readyResult)
        XCTAssertNotNil(coordinator.errorMessage)
        await coordinator.retryCleanup()
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(cleaner.cleanedWorkspaces, [lease])
    }

    func testUnsharedReadyArchiveIsExplicitlyDiscardedBeforeClose() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RoomExportDiscard-\(UUID().uuidString)",
            isDirectory: true
        )
        let provider = FakeRoomExportProvider(result: makeResult(workspace: workspace))
        let cleaner = FakeRoomExportWorkspaceCleaner()
        let coordinator = RoomExportCoordinator(provider: provider, cleaner: cleaner)

        await coordinator.prepare(projectID: "project-001", expectedHeadRevisionID: "revision-001")
        let didClose = await coordinator.discardPreparedExport()

        XCTAssertTrue(didClose)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(cleaner.cleanedWorkspaces, [workspace])
    }

    func testUnsharedDiscardCleanupFailureStaysNonterminalUntilRetry() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RoomExportDiscardRetry-\(UUID().uuidString)",
            isDirectory: true
        )
        let provider = FakeRoomExportProvider(result: makeResult(workspace: workspace))
        let cleaner = FakeRoomExportWorkspaceCleaner(failuresBeforeSuccess: 1)
        let coordinator = RoomExportCoordinator(provider: provider, cleaner: cleaner)

        await coordinator.prepare(projectID: "project-001", expectedHeadRevisionID: "revision-001")
        let didClose = await coordinator.discardPreparedExport()

        XCTAssertFalse(didClose)
        XCTAssertEqual(coordinator.state, .cleanupFailed)
        XCTAssertNotNil(coordinator.readyResult)
        await coordinator.retryCleanup()
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(cleaner.cleanedWorkspaces, [workspace])
    }

    func testLeaseRecoveryRemovesOnlyDirectMarkerProvenLeaseAndPreservesLookalikes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RoomExportLeaseRecovery-\(UUID().uuidString)",
            isDirectory: true
        )
        let external = root.deletingLastPathComponent().appendingPathComponent(
            "RoomExportLeaseExternal-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        let factory = RoomExportWorkspaceFactory(rootURL: root)
        let markedLease = try factory.makeLease()
        let marker = markedLease.appendingPathComponent("lease-ownership.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        let lookalike = root.appendingPathComponent(
            ".roomscan-head-export-unmarked-lookalike",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: lookalike, withIntermediateDirectories: false)
        let recovery = try factory.recoverOwnedOrphans()

        XCTAssertEqual(recovery.removedOwnedLeaseCount, 1)
        XCTAssertGreaterThanOrEqual(recovery.preservedUnownedOrUnsafeEntryCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markedLease.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lookalike.path))
        XCTAssertThrowsError(try factory.cleanup(workspaceURL: lookalike))

        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let linkedLookalike = root.appendingPathComponent(".roomscan-head-export-linked")
        do {
            try FileManager.default.createSymbolicLink(
                at: linkedLookalike,
                withDestinationURL: external
            )
        } catch {
            // Some Windows test hosts cannot create links without a developer
            // privilege. The unmarked direct-child control above still proves
            // recovery does not broad-delete lookalikes on those hosts.
            return
        }
        let linkedRecovery = try factory.recoverOwnedOrphans()
        XCTAssertGreaterThanOrEqual(linkedRecovery.preservedUnownedOrUnsafeEntryCount, 2)
        let linkDestination = try FileManager.default.destinationOfSymbolicLink(
            atPath: linkedLookalike.path
        )
        XCTAssertFalse(linkDestination.isEmpty)
        XCTAssertThrowsError(try factory.cleanup(workspaceURL: linkedLookalike))
    }

    private func makeResult(workspace: URL) -> RoomExportResult {
        RoomExportResult(
            archiveURL: workspace.appendingPathComponent("head-revision-export.zip"),
            workspaceURL: workspace,
            receipt: RoomExportReceipt(
                projectID: "project-001",
                headRevisionID: "revision-001",
                archiveSHA256: String(repeating: "e", count: 64),
                archiveByteCount: 12,
                manifestSHA256: String(repeating: "f", count: 64),
                profileVersion: RoomDeterministicZIP.profileVersion
            )
        )
    }
}

@MainActor
private final class FakeRoomExportProvider: RoomExportProviding {
    struct Request: Equatable {
        let projectID: String
        let headRevisionID: String
    }

    private let result: RoomExportResult?
    private let error: Error?
    private(set) var requests: [Request] = []

    init(result: RoomExportResult) {
        self.result = result
        error = nil
    }

    init(error: Error) {
        result = nil
        self.error = error
    }

    func exportHead(projectID: String, expectedHeadRevisionID: String) async throws -> RoomExportResult {
        requests.append(Request(projectID: projectID, headRevisionID: expectedHeadRevisionID))
        if let error { throw error }
        return try XCTUnwrap(result)
    }
}

@MainActor
private final class FakeRoomExportWorkspaceCleaner: RoomExportWorkspaceCleaning {
    private var failuresRemaining: Int
    private let onCleanupAttempt: (() -> Void)?
    private(set) var cleanupAttempts: [URL] = []
    private(set) var cleanedWorkspaces: [URL] = []

    init(
        failuresBeforeSuccess: Int = 0,
        onCleanupAttempt: (() -> Void)? = nil
    ) {
        failuresRemaining = failuresBeforeSuccess
        self.onCleanupAttempt = onCleanupAttempt
    }

    func cleanup(workspaceURL: URL) throws {
        cleanupAttempts.append(workspaceURL)
        onCleanupAttempt?()
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw RoomExportError.cleanupFailed("Injected cleanup failure.")
        }
        cleanedWorkspaces.append(workspaceURL)
    }
}

private enum InjectedShareError: Error {
    case failed
}

@MainActor
private func awaitCapturePhase(
    _ coordinator: RoomCaptureCoordinator,
    _ expected: RoomCapturePhase
) async throws {
    for _ in 0..<250 {
        if coordinator.state.phase == expected {
            return
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw GuestOfflineRouteTestError.captureDidNotReachPhase(
        expected: expected,
        actual: coordinator.state.phase
    )
}

private enum GuestOfflineRouteTestError: LocalizedError {
    case captureDidNotReachPhase(expected: RoomCapturePhase, actual: RoomCapturePhase)

    var errorDescription: String? {
        switch self {
        case let .captureDidNotReachPhase(expected, actual):
            return "Expected simulated capture phase \(expected.rawValue), reached \(actual.rawValue)."
        }
    }
}

/// `--reset-local-store` deliberately isolates these two roots by test-host
/// process ID. Re-resolving them after the route reaches its terminal save and
/// export-cleanup states removes only this test's local project/scratch state.
@MainActor
private func cleanupGuestOfflineProjectAndCaptureScratch(arguments: [String]) {
    let fileManager = FileManager.default
    _ = RoomProjectRootResolver.resolve(arguments: arguments, fileManager: fileManager)
    _ = RoomCaptureScratchRootResolver.resolve(arguments: arguments, fileManager: fileManager)
}
