import Foundation
import SwiftData
import UIKit
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
        XCTAssertEqual(prepared.orientationSuggestion?.source, .suggested)
        XCTAssertEqual(prepared.orientationSuggestion?.evidence.semanticRole, .door)
        XCTAssertEqual(
            Set(
                (prepared.commit.draft.revision.semanticSnapshot.structuralElements
                    + prepared.commit.draft.revision.semanticSnapshot.objectElements)
                    .map { RoomSemanticPresentation.role(for: $0) }
            ),
            Set(RoomSemanticRole.allCases)
        )

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

    func testSemanticVisualStylesRemainDistinctBeyondColorLabels() {
        let tokens = RoomSemanticRole.allCases.map(RoomSemanticPresentation.token(for:))
        XCTAssertEqual(Set(tokens.map(\.symbolName)).count, RoomSemanticRole.allCases.count)
        XCTAssertEqual(Set(tokens.map(\.materialPattern)).count, RoomSemanticRole.allCases.count)

        let colorDescriptions = RoomSemanticRole.allCases.map {
            RoomSemanticVisualStyle.color(for: $0).description
        }
        XCTAssertEqual(Set(colorDescriptions).count, RoomSemanticRole.allCases.count)
    }

    func testCoplanarEmbeddedFeaturesRenderOutsideTheirParentWallDepth() {
        let planar = RoomDimensions(width: 1, height: 2, depth: 0)
        let wall = RoomSemanticVisualStyle.displaySize(for: planar, role: .wall)

        for role in [RoomSemanticRole.door, .window, .opening] {
            let embeddedFeature = RoomSemanticVisualStyle.displaySize(for: planar, role: role)
            XCTAssertGreaterThan(
                embeddedFeature.z,
                wall.z,
                "\(role.rawValue) must project beyond both faces of a coplanar parent wall to avoid angle-dependent z-fighting."
            )
            XCTAssertEqual(
                RoomSemanticVisualStyle.color(for: role).cgColor.alpha,
                1,
                accuracy: 0.001,
                "\(role.rawValue) must use the opaque depth pass instead of angle-dependent transparent-entity sorting."
            )
        }
    }

    func testOrientationReviewPresentationNamesTwoDoorsAndSupportsDeterministicCorrection() throws {
        let snapshot = RoomSemanticSnapshot(
            projectID: "project-two-doors",
            revisionID: "revision-two-doors",
            units: "meters",
            accuracyDisclaimer: "Fixture geometry only.",
            structuralElements: [
                semanticElement(id: "wall-back", kind: "wall", x: 0, y: 1.2, z: 2, width: 4, height: 2.4),
                semanticElement(id: "wall-front", kind: "wall", x: 0, y: 1.2, z: -2, width: 4, height: 2.4),
                semanticElement(id: "closet-door", kind: "door", x: -0.9, y: 1, z: -2, width: 0.7, height: 2),
                semanticElement(id: "entrance-door", kind: "door", x: 0.4, y: 1, z: -2, width: 0.8, height: 2),
                semanticElement(id: "floor", kind: "floor", x: 0, y: 0, z: 0, width: 4, height: 0.01, depth: 4),
            ],
            objectElements: []
        )

        let presentation = try RoomOrientationReviewPresentation(snapshot: snapshot)

        XCTAssertEqual(presentation.entryOptions.map(\.title), ["Door 1 of 2", "Door 2 of 2"])
        XCTAssertEqual(presentation.entryOptions.map(\.featureID), ["closet-door", "entrance-door"])
        XCTAssertFalse(presentation.title(forEntryFeatureID: "entrance-door").contains("entrance-door"))
        XCTAssertEqual(presentation.title(forEntryFeatureID: "entrance-door"), "Door 2 of 2")

        let corrected = try presentation.entryReference(featureID: "entrance-door")
        XCTAssertEqual(corrected.positionMeters, .init(x: 0.4, y: -0.005, z: -2))
        XCTAssertGreaterThan(corrected.inwardDirection.z, 0)
        XCTAssertEqual(hypot(corrected.inwardDirection.x, corrected.inwardDirection.z), 1, accuracy: 0.000_001)
        XCTAssertThrowsError(try presentation.entryReference(featureID: "window-not-an-entry"))
    }

    func testOrientationPlanDisplayMatchesViewerAndTransformsEveryFeatureTogether() throws {
        let snapshot = RoomSemanticSnapshot(
            projectID: "project-plan-transform",
            revisionID: "revision-plan-transform",
            units: "meters",
            accuracyDisclaimer: "Fixture geometry only.",
            structuralElements: [
                semanticElement(id: "door", kind: "door", x: 1, y: 1, z: 2, width: 0.8, height: 2),
                semanticElement(id: "wall", kind: "wall", x: 0, y: 1, z: 0, width: 4, height: 2),
                semanticElement(id: "floor", kind: "floor", x: 0, y: 0, z: 0, width: 4, height: 0.01, depth: 6),
            ],
            objectElements: [
                semanticElement(id: "bed", kind: "bed", x: -1, y: 0.5, z: -2, width: 1.5, height: 1, depth: 2),
            ]
        )
        let presentation = try RoomOrientationReviewPresentation(snapshot: snapshot)
        let viewerAligned = RoomOrientationPlanDisplayTransform(
            projection: presentation.projection,
            presentation: .viewerAligned
        )
        let door = viewerAligned.point(.init(x: 1, y: 2))
        let bed = viewerAligned.point(.init(x: -1, y: -2))

        XCTAssertGreaterThan(door.y, bed.y, "+Z must render downward to match the semantic viewer.")
        XCTAssertGreaterThan(door.x, bed.x)

        let rotated = RoomOrientationPlanDisplayTransform(
            projection: presentation.projection,
            presentation: .init(quarterTurnsClockwise: 1, isMirroredHorizontally: false)
        )
        let rotatedDoor = rotated.point(.init(x: 1, y: 2))
        let rotatedBed = rotated.point(.init(x: -1, y: -2))
        XCTAssertLessThan(rotatedDoor.x, rotatedBed.x)
        XCTAssertGreaterThan(rotatedDoor.y, rotatedBed.y)

        let mirrored = RoomOrientationPlanDisplayTransform(
            projection: presentation.projection,
            presentation: .init(quarterTurnsClockwise: 0, isMirroredHorizontally: true)
        )
        let mirroredDoor = mirrored.point(.init(x: 1, y: 2))
        let mirroredBed = mirrored.point(.init(x: -1, y: -2))
        XCTAssertLessThan(mirroredDoor.x, mirroredBed.x)
        XCTAssertEqual(mirroredDoor.y, door.y, accuracy: 0.000_001)
        XCTAssertEqual(mirroredBed.y, bed.y, accuracy: 0.000_001)

        XCTAssertEqual(
            viewerAligned.worldDirection(fromDisplayed: .init(x: 0, y: -1)),
            .init(x: 0, y: 0, z: -1)
        )
        XCTAssertEqual(
            rotated.worldDirection(fromDisplayed: .init(x: 0, y: -1)),
            .init(x: -1, y: 0, z: 0)
        )

        XCTAssertEqual(presentation.entryOptions.map(\.featureID), ["door"])
    }

    func testRedesignRootsAreSeparateFromAuthoritativeProjects() {
        let projects = temporaryRoot().appendingPathComponent("Projects", isDirectory: true)
        let roots = RoomRedesignLocalRootResolver.resolve(
            arguments: [],
            projectRootURL: projects,
            fileManager: .default
        )
        XCTAssertNotEqual(roots.redesign, projects)
        XCTAssertNotEqual(roots.properties, projects)
        XCTAssertNotEqual(roots.redesign, roots.properties)
        XCTAssertEqual(roots.redesign.deletingLastPathComponent(), projects.deletingLastPathComponent())
        XCTAssertEqual(roots.properties.deletingLastPathComponent(), projects.deletingLastPathComponent())
    }

    /// Round-2 design finding: the fake rectangle-pattern thumbnail must die
    /// at both ends. `SimulatedRoomCaptureDriver` previously wrote a fixed
    /// 1x1 transparent pixel regardless of its fixture geometry; it must now
    /// draw the real `RoomFloorPlanProjection` of its own deterministic
    /// wall+table snapshot, and still be byte-for-byte deterministic since
    /// that snapshot's geometry never varies by attempt.
    func testSimulatedCaptureDriverThumbnailIsDeterministicRealFloorPlanGeometryNotOldFixedPixel() async throws {
        let oldFixedPixelPNG = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9JLC8AAAAASUVORK5CYII="
        ))

        func makeThumbnailPNG(attemptID: String) async throws -> Data {
            let scratchContainer = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: scratchContainer) }
            let workspaceFactory = RoomCaptureScratchWorkspaceFactory(
                rootURL: scratchContainer.appendingPathComponent("capture-scratch", isDirectory: true)
            )
            let attempt = RoomCaptureAttemptToken(attemptID)
            let workspace = try workspaceFactory.makeWorkspace(for: attempt)
            defer { try? workspaceFactory.cleanup(workspace) }

            let driver = SimulatedRoomCaptureDriver()
            try await driver.start(attempt: attempt, workspace: workspace)
            try await driver.stop(attempt: attempt)
            let prepared = try await driver.process(attempt: attempt, workspace: workspace)

            let thumbnailAsset = try XCTUnwrap(
                prepared.commit.assets.first { $0.scope == .project }
            )
            return try Data(contentsOf: thumbnailAsset.sourceURL)
        }

        let firstRunPNG = try await makeThumbnailPNG(attemptID: "thumbnail-determinism-attempt-a")
        let secondRunPNG = try await makeThumbnailPNG(attemptID: "thumbnail-determinism-attempt-b")

        // Real geometry, not the old fixed pixel.
        XCTAssertNotEqual(firstRunPNG, oldFixedPixelPNG)
        XCTAssertGreaterThan(firstRunPNG.count, oldFixedPixelPNG.count)
        let image = try XCTUnwrap(UIImage(data: firstRunPNG))
        XCTAssertEqual(image.size, CGSize(width: 640, height: 360))

        // Frame-rate/attempt independent: same fixed fixture geometry must
        // still produce byte-identical PNGs across separate runs.
        XCTAssertEqual(firstRunPNG, secondRunPNG)
    }

    /// Pure geometry oracle for the shared drawing routine both capture
    /// drivers and the library's payload-derived preview now use: a
    /// structural item's projected edge draws in the cyan instrument stroke,
    /// an object item's projected interior fills in amber, and untouched
    /// canvas stays the fixed captureBlack background — never the retired
    /// fake rectangle pattern.
    func testRoomThumbnailRendererDrawsStructuralAndObjectGeometryAtProjectedPositions() throws {
        let projection = RoomFloorPlanProjection(
            items: [
                RoomFloorPlanItem(
                    id: "wall-001",
                    kind: "wall",
                    label: "Wall",
                    center: RoomFloorPlanPoint(x: 2, y: 1.5),
                    widthMeters: 2,
                    depthMeters: 1,
                    isStructural: true,
                    corners: [
                        RoomFloorPlanPoint(x: 1, y: 1),
                        RoomFloorPlanPoint(x: 3, y: 1),
                        RoomFloorPlanPoint(x: 3, y: 2),
                        RoomFloorPlanPoint(x: 1, y: 2),
                    ]
                ),
                RoomFloorPlanItem(
                    id: "table-001",
                    kind: "table",
                    label: "Table",
                    center: RoomFloorPlanPoint(x: 7, y: 7),
                    widthMeters: 2,
                    depthMeters: 2,
                    isStructural: false,
                    corners: [
                        RoomFloorPlanPoint(x: 6, y: 6),
                        RoomFloorPlanPoint(x: 8, y: 6),
                        RoomFloorPlanPoint(x: 8, y: 8),
                        RoomFloorPlanPoint(x: 6, y: 8),
                    ]
                ),
            ],
            bounds: RoomFloorPlanBounds(
                minimum: RoomFloorPlanPoint(x: 0, y: 0),
                maximum: RoomFloorPlanPoint(x: 10, y: 10)
            )
        )
        let size = CGSize(width: 640, height: 360)
        let image = RoomThumbnailRenderer.projectionImage(from: projection, size: size)

        // Background sample, well outside the 8% inset margin: pure captureBlack.
        let background = try samplePixel(in: image, x: 10, y: 10)
        XCTAssertLessThan(background.r, 20)
        XCTAssertLessThan(background.g, 20)
        XCTAssertLessThan(background.b, 20)

        // Object fill sample: center of the table's projected rect (world
        // (7,7) -> canvas ~(263, 120) using the renderer's own inset/scale
        // math), well inside the fill so antialiasing at the edge can't
        // affect it. Amber fill/stroke: red channel clearly dominant.
        let objectFillSample = try samplePixel(in: image, x: 263, y: 120)
        XCTAssertGreaterThan(objectFillSample.r, background.r + 30)
        XCTAssertGreaterThan(objectFillSample.r, objectFillSample.b)

        // Structural stroke sample: on the wall's projected bottom edge
        // (world (2,1) -> canvas ~(112, 301)). Cyan stroke: blue/green
        // clearly dominant over red.
        let structuralStrokeSample = try samplePixel(in: image, x: 112, y: 301)
        XCTAssertGreaterThan(structuralStrokeSample.b, background.b + 30)
        XCTAssertGreaterThan(structuralStrokeSample.b, structuralStrokeSample.r)
    }

    /// Reads a single pixel's RGBA bytes from `image` at top-left-origin
    /// pixel coordinates `(x, y)`. `UIImage.draw(at:)` first crops/positions
    /// the source using UIKit's own (already-correct) top-left orientation
    /// convention, so this sidesteps CGContext's bottom-up flip; the final
    /// 1x1 read then uses an explicit RGBA byte order so the result doesn't
    /// depend on the platform's native pixel format.
    private func samplePixel(in image: UIImage, x: Int, y: Int) throws -> (r: Int, g: Int, b: Int, a: Int) {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        let cropped = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { _ in
            image.draw(at: CGPoint(x: -CGFloat(x), y: -CGFloat(y)))
        }
        let cgImage = try XCTUnwrap(cropped.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]), Int(pixel[3]))
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

    /// The Rooms surface counts only rooms the user actually captured:
    /// fixture-tagged packages (mock review, simulated capture) and archived
    /// rooms are excluded, real captures and manual saves count.
    func testHomeRoomCountExcludesFixtureTaggedAndArchivedRooms() {
        func summary(
            id: String,
            tags: [String],
            archived: Bool = false
        ) -> RoomProjectSummary {
            RoomProjectSummary(
                projectID: id,
                customName: id,
                captureDate: Date(timeIntervalSince1970: 1_704_067_200),
                lastRevisedDate: Date(timeIntervalSince1970: 1_704_067_200),
                manualLocation: "",
                tags: tags,
                thumbnailRelativePath: nil,
                archived: archived,
                headRevisionID: "revision-001"
            )
        }

        XCTAssertEqual(HomeRoomCount.userVisibleCount(of: []), 0)

        let mockRoom = summary(id: "mock", tags: ["fixture", "phase-0"])
        let simulatedRoom = summary(id: "sim", tags: ["simulated", "fixture"])
        let realCapture = summary(id: "real", tags: ["roomplan"])
        let untaggedRoom = summary(id: "untagged", tags: [])
        let archivedCapture = summary(id: "archived", tags: ["roomplan"], archived: true)

        XCTAssertEqual(
            HomeRoomCount.userVisibleCount(
                of: [mockRoom, simulatedRoom, realCapture, untaggedRoom, archivedCapture]
            ),
            2
        )
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

    private func semanticElement(
        id: String,
        kind: String,
        x: Double,
        y: Double,
        z: Double,
        width: Double,
        height: Double,
        depth: Double = 0
    ) -> RoomSemanticElement {
        RoomSemanticElement(
            id: id,
            kind: kind,
            label: kind.capitalized,
            dimensionsMeters: .init(width: width, height: height, depth: depth),
            transform: RoomTransform4x4(columnMajorValues: [
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                x, y, z, 1,
            ]),
            mobility: kind == "floor" || kind == "wall" || kind == "door" ? .structural : .unknown
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "RoomScanStudioTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}
