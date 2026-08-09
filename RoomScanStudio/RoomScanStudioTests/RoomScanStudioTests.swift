import Foundation
import SwiftData
import XCTest
import RoomScanCore
@testable import RoomScanStudio

@MainActor
final class RoomScanStudioTests: XCTestCase {
    func testCapabilityMappingUsesFixtureModeWhenCaptureIsUnavailable() {
        let provider = FixtureDeviceCapabilityProvider(
            roomCaptureSupported: false,
            sceneMeshSupported: true
        )

        XCTAssertEqual(
            provider.supportStatus,
            .fixtureMode(missing: [.roomPlanCapture])
        )
    }

    func testRoomPlanCaptureGateIsIndependentFromOptionalSceneMesh() {
        let unsupported = FixtureDeviceCapabilityProvider(
            roomCaptureSupported: false,
            sceneMeshSupported: false
        )
        XCTAssertEqual(
            unsupported.supportStatus,
            .fixtureMode(missing: [.roomPlanCapture])
        )
        XCTAssertFalse(unsupported.supportStatus.canStartLiveCapture)

        let captureWithoutMesh = FixtureDeviceCapabilityProvider(
            roomCaptureSupported: true,
            sceneMeshSupported: false
        )
        XCTAssertEqual(
            captureWithoutMesh.supportStatus,
            .captureAvailable(sceneMeshAvailable: false)
        )
        XCTAssertTrue(captureWithoutMesh.supportStatus.canStartLiveCapture)
        XCTAssertFalse(captureWithoutMesh.supportStatus.sceneMeshAvailable)

        let captureWithMesh = FixtureDeviceCapabilityProvider(
            roomCaptureSupported: true,
            sceneMeshSupported: true
        )
        XCTAssertEqual(
            captureWithMesh.supportStatus,
            .captureAvailable(sceneMeshAvailable: true)
        )
        XCTAssertTrue(captureWithMesh.supportStatus.canStartLiveCapture)
        XCTAssertTrue(captureWithMesh.supportStatus.sceneMeshAvailable)
    }

    func testSimulatedCaptureDriverProducesAnExplicitSaveableFixtureCommit() async throws {
        let scratchContainer = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: scratchContainer) }
        let scratchRoot = scratchContainer.appendingPathComponent(
            "capture-scratch",
            isDirectory: true
        )
        let workspaceFactory = RoomCaptureScratchWorkspaceFactory(rootURL: scratchRoot)
        let attempt = RoomCaptureAttemptToken("simulated-attempt-001")
        let workspace = try workspaceFactory.makeWorkspace(for: attempt)
        defer { try? workspaceFactory.cleanup(workspace) }

        let driver = SimulatedRoomCaptureDriver()
        try await driver.start(attempt: attempt, workspace: workspace)
        try await driver.stop(attempt: attempt)
        let prepared = try await driver.process(attempt: attempt, workspace: workspace)

        XCTAssertEqual(prepared.commit.evidence?.source, .deterministicFixture)
        XCTAssertEqual(prepared.commit.assets.filter { $0.scope == .project }.count, 1)
        XCTAssertFalse(prepared.commit.assets.isEmpty)
        XCTAssertFalse(prepared.commit.draft.revision.semanticSnapshot.accuracyDisclaimer.isEmpty)

        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalRoomProjectStore(
            rootURL: root,
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: ["simulated-project-001"],
                revisionIDs: ["revision-001"]
            )
        )
        let controller = RoomLibraryController(store: store, modelContainer: nil)

        let discarded = try await controller.commitInitialCapture(
            prepared.commit,
            decision: .discard
        )
        XCTAssertNil(discarded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

        let saved = try await controller.commitInitialCapture(
            prepared.commit,
            decision: .save
        )
        XCTAssertEqual(saved?.projectID, "simulated-project-001")
        let summaries = try await store.listSummaries(includeArchived: true)
        XCTAssertEqual(summaries.count, 1)
    }

    func testMockRoomFixtureDecodesAllSevenDocumentsAndSpatialPhotoMarkerAssets() throws {
        let fixture = try MockRoomFixtureLoader.load(bundle: Bundle(for: Self.self))

        XCTAssertEqual(fixture.manifest.projectID, "mock-room-v1")
        XCTAssertEqual(fixture.manifest.headRevisionID, "revision-001")
        XCTAssertEqual(fixture.manifest.revisionIDs, ["revision-001"])
        XCTAssertEqual(fixture.draft.metadata.customName, "Mock Studio Room")
        XCTAssertEqual(fixture.draft.revision.photos.count, 1)
        XCTAssertEqual(
            fixture.draft.revision.photos.first?.assetRelativePath,
            try RoomRelativePath("photos/reference-001.png")
        )
        XCTAssertTrue(fixture.draft.revision.photos.first?.cameraTransform?.isValid == true)
        XCTAssertEqual(fixture.draft.revision.annotations.first?.attachedElementID, "movable-desk-001")
        XCTAssertNotNil(fixture.draft.revision.measurements.first?.startPoint)
        XCTAssertEqual(fixture.revisionAssets.count, 1)
        XCTAssertEqual(fixture.revisionAssets.first?.scope, .revision)
        XCTAssertFalse(fixture.draft.revision.semanticSnapshot.accuracyDisclaimer.isEmpty)
        XCTAssertEqual(fixture.thumbnailAsset.scope, .project)
        XCTAssertEqual(
            fixture.thumbnailAsset.destination,
            try RoomRelativePath("thumbnails/thumbnail.png")
        )
        let thumbnailData = try Data(contentsOf: fixture.thumbnailAsset.sourceURL)
        XCTAssertEqual(Array(thumbnailData.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
    }

    func testInMemoryLocalModelContainerCanBeCreated() throws {
        let container = try RoomProjectIndexFactory.makeContainer(
            isStoredInMemoryOnly: true
        )
        XCTAssertNotNil(container)
    }

    func testRoomProjectIndexFactoryUsesLocalOnlyPersistencePolicy() {
        XCTAssertEqual(
            RoomProjectIndexFactory.persistencePolicy,
            .localOnly
        )
    }

    func testIndexRebuildUsesListingAndRemovesStaleRecords() throws {
        let container = try RoomProjectIndexFactory.makeContainer(
            isStoredInMemoryOnly: true
        )
        let context = ModelContext(container)
        let summary = RoomProjectSummary(
            projectID: "project-index-001",
            customName: "Indexed room",
            captureDate: Date(timeIntervalSince1970: 1_704_067_200),
            lastRevisedDate: Date(timeIntervalSince1970: 1_704_067_201),
            manualLocation: "Fixture Lab",
            tags: ["fixture"],
            thumbnailRelativePath: nil,
            archived: false,
            headRevisionID: "revision-001"
        )

        try RoomProjectIndexRebuilder.rebuild(
            listing: RoomProjectListing(summaries: [summary], issues: []),
            in: context
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<RoomProjectIndexRecord>()).count,
            1
        )

        try RoomProjectIndexRebuilder.rebuild(
            listing: RoomProjectListing(summaries: [], issues: []),
            in: context
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<RoomProjectIndexRecord>()).count,
            0
        )
    }

    func testLibraryControllerRetainsValidPackagesAndPublishesThumbnailAndCorruptDiagnostics() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = LocalRoomProjectStore(
            rootURL: root,
            clock: FixedRoomProjectClock(date: Date(timeIntervalSince1970: 1_704_067_200)),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: ["app-project-001"],
                revisionIDs: ["revision-001"]
            )
        )
        let fixture = try MockRoomFixtureLoader.load(bundle: Bundle(for: Self.self))
        _ = try await store.saveDraft(
            fixture.draft,
            decision: .save,
            assets: fixture.assets
        )
        let corrupt = root.appendingPathComponent("project-corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("not json".utf8).write(
            to: corrupt.appendingPathComponent("manifest.json"),
            options: .atomic
        )

        let container = try RoomProjectIndexFactory.makeContainer(isStoredInMemoryOnly: true)
        let controller = RoomLibraryController(store: store, modelContainer: container)
        await controller.refreshLibrary()

        XCTAssertEqual(controller.summaries.map(\.projectID), ["app-project-001"])
        XCTAssertEqual(controller.listingIssues.count, 1)
        XCTAssertNil(controller.libraryErrorMessage)
        XCTAssertEqual(
            controller.thumbnailDataByProjectID["app-project-001"],
            try Data(contentsOf: fixture.thumbnailAsset.sourceURL)
        )
    }

    func testMockReviewSaveAndDiscardAreExplicit() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = LocalRoomProjectStore(
            rootURL: root,
            clock: FixedRoomProjectClock(date: Date(timeIntervalSince1970: 1_704_067_200)),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: ["app-project-001"],
                revisionIDs: ["revision-001"]
            )
        )
        let coordinator = MockRoomReviewPersistenceCoordinator(store: store)
        let fixture = try MockRoomFixtureLoader.load(bundle: Bundle(for: Self.self))

        let discarded = try await coordinator.resolve(
            fixture: fixture,
            disposition: .discard
        )
        XCTAssertNil(discarded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

        let savedResult = try await coordinator.resolve(
            fixture: fixture,
            disposition: .save
        )
        let saved = try XCTUnwrap(savedResult)
        XCTAssertEqual(saved.projectID, "app-project-001")
        let summaries = try await store.listSummaries(includeArchived: true)
        XCTAssertEqual(summaries.count, 1)
        let thumbnailData = try await store.thumbnailData(projectID: saved.projectID)
        XCTAssertEqual(thumbnailData, try Data(contentsOf: fixture.thumbnailAsset.sourceURL))
    }

    func testProductionRescanProviderIsHardUnavailableWithoutCaptureWork() async throws {
        let provider = UnavailableRoomRescanProvider()
        let package = try fixturePackageForRescanProvider()

        let availability = await provider.availability(for: package)
        XCTAssertEqual(
            availability,
            .unavailable(.registrationEvidenceMissing)
        )
    }

    func testRescanFlowPrioritizesAcceptanceErrorOverStaleProposal() {
        let state = RoomRescanFlowPresentation.state(
            acceptedRevisionID: nil,
            unavailableReason: nil,
            hasProposal: true,
            errorMessage: "Acceptance was rejected."
        )

        XCTAssertEqual(state, .error)
        XCTAssertEqual(
            RoomRescanFlowPresentation.statusText(for: state),
            "The fixture rescan could not be accepted."
        )
    }

    func testDeterministicRescanFixtureLoadsPreviewAndAcceptsOneChildRevision() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalRoomProjectStore(
            rootURL: root,
            clock: FixedRoomProjectClock(date: Date(timeIntervalSince1970: 1_704_067_200)),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: ["ui-project-001"],
                revisionIDs: ["revision-001", "revision-002"]
            )
        )
        let fixture = try MockRoomFixtureLoader.load(bundle: Bundle(for: Self.self))
        let saved = try await store.saveDraft(
            fixture.draft,
            decision: .save,
            assets: fixture.assets
        )
        let summary = try XCTUnwrap(saved)
        let package = try await store.load(projectID: summary.projectID)
        let provider = DeterministicFixtureRoomRescanProvider(
            bundle: Bundle(for: Self.self)
        )

        let availability = await provider.availability(for: package)
        guard case let .available(proposal) = availability else {
            return XCTFail("Expected the bundled deterministic fixture proposal.")
        }
        XCTAssertEqual(proposal.projectID, summary.projectID)
        XCTAssertEqual(proposal.baseRevisionID, "revision-001")
        XCTAssertFalse(proposal.preview.changes.isEmpty)
        XCTAssertTrue(proposal.preview.measurementsRemainUnrevalidated)

        let controller = RoomLibraryController(store: store, modelContainer: nil)
        let accepted = try await controller.acceptFixtureRescan(
            projectID: summary.projectID,
            expectedHeadRevisionID: package.manifest.headRevisionID,
            proposal: proposal
        )
        let reloaded = try await store.load(projectID: summary.projectID)
        XCTAssertEqual(accepted.reason, .rescan)
        XCTAssertEqual(reloaded.manifest.revisionIDs, ["revision-001", "revision-002"])
    }

    func testPrivacyPolicyURLResolverAcceptsOnlyConfiguredCredentialFreeHTTPSURLs() throws {
        XCTAssertNil(PrivacyPolicyURLResolver.resolve(rawValue: nil))
        XCTAssertNil(PrivacyPolicyURLResolver.resolve(rawValue: ""))
        XCTAssertNil(PrivacyPolicyURLResolver.resolve(rawValue: "   "))
        XCTAssertNil(PrivacyPolicyURLResolver.resolve(rawValue: "$(ROOMSCANSTUDIO_PRIVACY_POLICY_URL)"))
        XCTAssertNil(PrivacyPolicyURLResolver.resolve(rawValue: "http://privacy.example.com/policy"))
        XCTAssertNil(PrivacyPolicyURLResolver.resolve(rawValue: "https://operator:secret@privacy.example.com/policy"))
        XCTAssertNil(PrivacyPolicyURLResolver.resolve(rawValue: "https://privacy.example.com/policy#fragment"))
        XCTAssertNil(PrivacyPolicyURLResolver.resolve(rawValue: "https://privacy example.com/policy"))
        XCTAssertNil(PrivacyPolicyURLResolver.resolve(rawValue: "https://privacy.example.com/%0A"))
        XCTAssertNil(PrivacyPolicyURLResolver.resolve(rawValue: "https://privacy.example.com/%ZZ"))

        let resolved = try XCTUnwrap(
            PrivacyPolicyURLResolver.resolve(rawValue: "https://privacy.example.com/roomscan")
        )
        XCTAssertEqual(resolved.absoluteString, "https://privacy.example.com/roomscan")
    }

    private func fixturePackageForRescanProvider() throws -> RoomProjectPackage {
        let fixture = try MockRoomFixtureLoader.load(bundle: Bundle(for: Self.self))
        let revision = RoomRevisionPackage(
            manifest: RoomRevisionManifest(
                revisionID: fixture.manifest.headRevisionID,
                projectID: fixture.manifest.projectID,
                parentRevisionID: nil,
                reason: .initial,
                createdAt: fixture.manifest.createdAt,
                immutable: true,
                evidenceCompatibility: .legacyV1Planless
            ),
            payload: fixture.draft.revision
        )
        return RoomProjectPackage(
            manifest: fixture.manifest,
            metadata: fixture.draft.metadata,
            revisions: [revision]
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "RoomScanStudioTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}
