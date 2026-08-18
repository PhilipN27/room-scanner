import XCTest
@testable import RoomScanStudio
import RoomScanCore
import UIKit

@MainActor
final class RoomAIRoomPackageServiceTests: XCTestCase {
    func testAIReadyPlanNeverContainsRawSlots() throws {
        let plan = try RoomAIRoomPackageAppService.makePlanForTesting(profile: .aiReady)
        XCTAssertFalse(plan.slots.contains { [.rawRGB, .rawDepth, .rawConfidence, .diagnostics].contains($0.artifactClass) })
    }

    func testExcludedImageChangesSelectionAndCannotBeReused() throws {
        let result = try RoomAIRoomPackageAppService.selectionForTesting(
            candidates: ["frame-a", "frame-b"],
            excluded: ["frame-a"],
            replacement: "frame-c"
        )
        XCTAssertEqual(result, ["frame-b", "frame-c"])
        XCTAssertFalse(result.contains("frame-a"))
    }

    func testRequestedReplacementIsForcedIntoProductionSelection() throws {
        let source = makeSource(projectID: "replacement-selection")
        let candidates = [
            candidate("frame-a", sharpness: 100, source: source),
            candidate("frame-b", sharpness: 90, source: source),
            candidate("frame-c", sharpness: 80, source: source),
            candidate("frame-d", sharpness: 70, source: source),
            candidate("frame-e", sharpness: 60, source: source),
            candidate("replacement-low-rank", sharpness: 1, source: source),
        ]

        let selection = try RoomAIRoomPackageAppService.selectReferences(
            candidates,
            source: source,
            profile: .aiReady,
            excluded: ["frame-a"],
            replacements: ["replacement-low-rank"]
        )

        XCTAssertEqual(selection.selected.count, RoomAIReferenceImageSelector.aiReadyLimit)
        XCTAssertTrue(selection.selected.map(\.evidenceID).contains("replacement-low-rank"))
        XCTAssertFalse(selection.selected.map(\.evidenceID).contains("frame-a"))
    }

    func testMaterializerFailsClosedForMismatchedSemanticDigest() async throws {
        let fixture = try makeFixture()
        var invalid = fixture.source
        invalid.semanticSHA256 = String(repeating: "f", count: 64)
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        await XCTAssertThrowsErrorAsync {
            _ = try await RoomAIRoomPackageMaterializer().materialize(
                package: fixture.package, sourceRevision: invalid, companion: fixture.companion,
                boundEvidence: nil, derivativeRenderer: TestRenderer(), profile: .aiReady,
                into: root
            )
        }
    }

    func testMaterializerProducesExactlySixDerivativesAndOnlyExactBoundCaptureCandidates() async throws {
        let fixture = try makeFixture()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let evidence = try makeEvidence(boundTo: fixture.source, root: root)
        let before = try RoomJSONCoding.makeEncoder().encode(fixture.package.revisions[0].payload.semanticSnapshot)
        let materialization = try await RoomAIRoomPackageMaterializer().materialize(
            package: fixture.package, sourceRevision: fixture.source, companion: fixture.companion,
            boundEvidence: evidence, derivativeRenderer: TestRenderer(), profile: .aiReady, into: root
        )
        XCTAssertEqual(materialization.artifacts.filter { $0.artifactID.hasPrefix("canonical-view-") }.count, 6)
        XCTAssertEqual(materialization.artifacts.filter { $0.artifactID == "floor-plan" }.count, 1)
        XCTAssertEqual(materialization.referenceCandidates.count, 1)
        XCTAssertEqual(materialization.referenceCandidates.first?.sourceRevision, fixture.source)
        XCTAssertFalse(materialization.artifacts.contains { $0.relativePath.hasPrefix("raw/") })
        XCTAssertEqual(before, try RoomJSONCoding.makeEncoder().encode(fixture.package.revisions[0].payload.semanticSnapshot))

        let legacy = try await RoomAIRoomPackageMaterializer().materialize(
            package: fixture.package, sourceRevision: fixture.source, companion: fixture.companion,
            boundEvidence: nil, derivativeRenderer: TestRenderer(), profile: .aiReady,
            into: try temporaryDirectory()
        )
        XCTAssertTrue(legacy.referenceCandidates.isEmpty)
    }

    func testCompleteStagesBoundRawEvidenceForExactDisclosureWhileAIReadyHasNone() async throws {
        let fixture = try makeFixture()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let evidence = try makeEvidence(boundTo: fixture.source, root: root)
        let aiReady = try await RoomAIRoomPackageMaterializer().materialize(package: fixture.package, sourceRevision: fixture.source, companion: fixture.companion, boundEvidence: evidence, derivativeRenderer: TestRenderer(), profile: .aiReady, into: root.appendingPathComponent("ready", isDirectory: true))
        let complete = try await RoomAIRoomPackageMaterializer().materialize(package: fixture.package, sourceRevision: fixture.source, companion: fixture.companion, boundEvidence: evidence, derivativeRenderer: TestRenderer(), profile: .complete, into: root.appendingPathComponent("complete", isDirectory: true))
        XCTAssertTrue(aiReady.rawRGBIDs.isEmpty)
        XCTAssertFalse(complete.rawRGBIDs.isEmpty)
        XCTAssertFalse(aiReady.artifacts.contains { $0.relativePath.hasPrefix("raw/") || $0.relativePath.hasPrefix("diagnostics/") })
        XCTAssertEqual(
            complete.artifacts.filter { $0.relativePath.hasPrefix("raw/rgb/") }.count,
            complete.rawRGBIDs.count
        )
        XCTAssertEqual(
            complete.artifacts.filter { $0.relativePath.hasPrefix("diagnostics/") }.count,
            complete.diagnosticIDs.count
        )
    }

    func testCompleteDraftDisclosesEveryIncludedRawRGBWithPreviewAndMetadata() async throws {
        let fixture = try makeFixture()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceFactory = RoomExportWorkspaceFactory(
            rootURL: root.appendingPathComponent("ExportScratch", isDirectory: true)
        )
        let sourceLease = try workspaceFactory.makeLease()
        let evidence = try makeEvidence(boundTo: fixture.source, root: root)
        let materialization = try await RoomAIRoomPackageMaterializer().materialize(
            package: fixture.package,
            sourceRevision: fixture.source,
            companion: fixture.companion,
            boundEvidence: evidence,
            derivativeRenderer: TestRenderer(),
            profile: .complete,
            into: sourceLease
        )
        let service = RoomAIRoomPackageAppService(workspaceFactory: workspaceFactory)
        let draft = try await service.prepare(materialization: materialization)
        defer { try? service.cleanupLease(draft.workspaceURL) }

        let includedRawRGB = draft.preparation.artifacts.filter { artifact in
            artifact.artifactClass == .rawRGB && artifact.disposition == .included
        }
        let includedRawRGBIDs = Set(includedRawRGB.map(\.artifactID))
        XCTAssertFalse(includedRawRGBIDs.isEmpty)
        let disclosedByID = Dictionary(uniqueKeysWithValues: draft.disclosureDraft.selectedImages.map {
            ($0.imageID, $0)
        })
        XCTAssertEqual(includedRawRGBIDs, includedRawRGBIDs.intersection(disclosedByID.keys))
        for rawID in includedRawRGBIDs {
            XCTAssertEqual(disclosedByID[rawID]?.mediaType, "image/jpeg")
            XCTAssertEqual(
                disclosedByID[rawID]?.byteCount,
                includedRawRGB.first(where: { $0.artifactID == rawID })?.byteCount
            )
            XCTAssertNotNil(draft.selectedImagePreviewData[rawID])
        }
    }

    /// Break caught: a manifest-controlled `../` image name must never make
    /// the materializer read an otherwise-valid JPEG outside the frames root.
    func testMaterializerRejectsTraversalFrameLeafInsteadOfReadingOutsideFramesRoot() async throws {
        let fixture = try makeFixture()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let evidence = try makeEvidence(boundTo: fixture.source, root: root)
        let escapedImage = evidence.directoryURL.appendingPathComponent("outside.jpg")
        try makeJPEG().write(to: escapedImage)
        var manifest = evidence.manifest
        manifest.frames[0].fileName = "../outside.jpg"

        await assertUnsafeArtifactPath("../outside.jpg") {
            _ = try await RoomAIRoomPackageMaterializer().materialize(
                package: fixture.package,
                sourceRevision: fixture.source,
                companion: fixture.companion,
                boundEvidence: .init(
                    directoryURL: evidence.directoryURL,
                    manifest: manifest,
                    sourceBinding: evidence.sourceBinding
                ),
                derivativeRenderer: TestRenderer(),
                profile: .aiReady,
                into: root.appendingPathComponent("lease", isDirectory: true)
            )
        }
    }

    /// Break caught: a `frames` directory symlink must not make a bound
    /// bundle source content outside its owned capture directory.
    func testMaterializerRejectsIntermediateFramesDirectorySymlink() async throws {
        let fixture = try makeFixture()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let evidence = try makeEvidence(boundTo: fixture.source, root: root)
        let frames = evidence.directoryURL.appendingPathComponent(
            RoomCaptureBundleLibrary.framesSubdirectoryName,
            isDirectory: true
        )
        let escapedFrames = root.appendingPathComponent("escaped-frames", isDirectory: true)
        try FileManager.default.createDirectory(at: escapedFrames, withIntermediateDirectories: true)
        try makeJPEG().write(to: escapedFrames.appendingPathComponent("frame.jpg"))
        try FileManager.default.removeItem(at: frames)
        try FileManager.default.createSymbolicLink(at: frames, withDestinationURL: escapedFrames)

        await assertUnsafeArtifactPath(RoomCaptureBundleLibrary.framesSubdirectoryName) {
            _ = try await RoomAIRoomPackageMaterializer().materialize(
                package: fixture.package,
                sourceRevision: fixture.source,
                companion: fixture.companion,
                boundEvidence: evidence,
                derivativeRenderer: TestRenderer(),
                profile: .aiReady,
                into: root.appendingPathComponent("lease", isDirectory: true)
            )
        }
    }

    /// Break caught: candidate capture bytes must be rejected by the package
    /// file boundary before they are fully loaded for image analysis.
    func testMaterializerRejectsOversizedFrameBeforeImageAnalysis() async throws {
        let fixture = try makeFixture()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let evidence = try makeEvidence(boundTo: fixture.source, root: root)
        let frameURL = evidence.directoryURL
            .appendingPathComponent(RoomCaptureBundleLibrary.framesSubdirectoryName, isDirectory: true)
            .appendingPathComponent("frame.jpg")
        try Data(repeating: 0, count: 32 * 1_024 * 1_024 + 1).write(to: frameURL)

        await assertUnsafeArtifactPath("frame.jpg") {
            _ = try await RoomAIRoomPackageMaterializer().materialize(
                package: fixture.package,
                sourceRevision: fixture.source,
                companion: fixture.companion,
                boundEvidence: evidence,
                derivativeRenderer: TestRenderer(),
                profile: .aiReady,
                into: root.appendingPathComponent("lease", isDirectory: true)
            )
        }
    }

    /// Break caught: complete-package depth bytes must remain a leaf beneath
    /// the owned frames directory, rather than follow a manifest traversal.
    func testCompleteMaterializerRejectsTraversalDepthLeaf() async throws {
        let fixture = try makeFixture()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let evidence = try makeEvidence(boundTo: fixture.source, root: root)
        let escapedDepth = evidence.directoryURL.appendingPathComponent("outside.depth")
        try Data([0xD0]).write(to: escapedDepth)
        var manifest = evidence.manifest
        manifest.frames[0].depth = .init(
            fileName: "../outside.depth",
            confidenceFileName: nil,
            width: 1,
            height: 1,
            compression: "zlib",
            pixelFormat: "float32"
        )

        await assertUnsafeArtifactPath("../outside.depth") {
            _ = try await RoomAIRoomPackageMaterializer().materialize(
                package: fixture.package,
                sourceRevision: fixture.source,
                companion: fixture.companion,
                boundEvidence: .init(
                    directoryURL: evidence.directoryURL,
                    manifest: manifest,
                    sourceBinding: evidence.sourceBinding
                ),
                derivativeRenderer: TestRenderer(),
                profile: .complete,
                into: root.appendingPathComponent("lease", isDirectory: true)
            )
        }
    }

    /// Break caught: confidence bytes have the same containment requirement
    /// as depth bytes and cannot escape through a manifest-controlled leaf.
    func testCompleteMaterializerRejectsTraversalConfidenceLeaf() async throws {
        let fixture = try makeFixture()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let evidence = try makeEvidence(boundTo: fixture.source, root: root)
        let frames = evidence.directoryURL.appendingPathComponent(
            RoomCaptureBundleLibrary.framesSubdirectoryName,
            isDirectory: true
        )
        try Data([0xD0]).write(to: frames.appendingPathComponent("frame.depth"))
        try Data([0x01]).write(to: evidence.directoryURL.appendingPathComponent("outside.confidence"))
        var manifest = evidence.manifest
        manifest.frames[0].depth = .init(
            fileName: "frame.depth",
            confidenceFileName: "../outside.confidence",
            width: 1,
            height: 1,
            compression: "zlib",
            pixelFormat: "float32"
        )

        await assertUnsafeArtifactPath("../outside.confidence") {
            _ = try await RoomAIRoomPackageMaterializer().materialize(
                package: fixture.package,
                sourceRevision: fixture.source,
                companion: fixture.companion,
                boundEvidence: .init(
                    directoryURL: evidence.directoryURL,
                    manifest: manifest,
                    sourceBinding: evidence.sourceBinding
                ),
                derivativeRenderer: TestRenderer(),
                profile: .complete,
                into: root.appendingPathComponent("lease", isDirectory: true)
            )
        }
    }

    /// Break caught: a direct bundle-directory symlink must not be returned
    /// as trusted, sealed capture evidence by the library boundary.
    func testCaptureBundleLibraryRejectsSymlinkedBundleDirectory() throws {
        let projectID = "capture-symlink-\(UUID().uuidString.lowercased())"
        defer { try? RoomCaptureBundleLibrary.removeBundle(forProject: projectID) }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let source = makeSource(projectID: projectID)
        let manifest = RoomCaptureBundleManifest(
            schemaVersion: RoomCaptureBundleManifest.currentSchemaVersion,
            createdAt: Date(timeIntervalSince1970: 1),
            frames: [],
            meshAnchorCount: 0,
            meshVertexCount: 0,
            meshFaceCount: 0,
            notes: []
        )
        try RoomJSONCoding.makeEncoder().encode(manifest).write(
            to: scratch.appendingPathComponent(RoomCaptureBundleLibrary.manifestFileName)
        )
        try RoomCaptureBundleLibrary.adoptBoundBundle(
            at: scratch,
            forProject: projectID,
            sourceRevision: source
        )
        let adopted = try XCTUnwrap(RoomCaptureBundleLibrary.bundleDirectory(forProject: projectID))
        let externalBundle = root.appendingPathComponent("external-bundle", isDirectory: true)
        try FileManager.default.moveItem(at: adopted, to: externalBundle)
        try FileManager.default.createSymbolicLink(at: adopted, withDestinationURL: externalBundle)

        XCTAssertNil(RoomCaptureBundleLibrary.bundleDirectory(forProject: projectID))
        XCTAssertNil(RoomCaptureBundleLibrary.boundEvidence(
            forProject: projectID,
            expectedSourceRevision: source
        ))
    }

    func testProductionRendererDerivesSixSourceBoundSchematicViewsWithoutInventingPhotos() async throws {
        let fixture = try makeFixture()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let renderer = UIKitRoomAIRoomPackageDerivativeRenderer(
            snapshot: fixture.package.revisions[0].payload.semanticSnapshot,
            expectedSourceRevision: fixture.source,
            canonicalViewSources: [:]
        )

        let floorPlan = try await renderer.renderFloorPlanPNG(
            sourceRevision: fixture.source,
            into: root
        )
        let views = try await renderer.renderCanonicalViewPNGs(
            orientation: fixture.companion.orientation,
            sourceRevision: fixture.source,
            into: root
        )

        XCTAssertEqual(views.count, 6)
        XCTAssertNoThrow(try RoomAIRoomPackageDerivativeRenderer.validate(
            floorPlan: floorPlan,
            canonicalViews: views,
            orientation: fixture.companion.orientation
        ))
        for artifact in [floorPlan] + views {
            let data = try Data(contentsOf: artifact.sourceURL)
            XCTAssertNoThrow(try RoomConceptImageValidator.validateSanitizedImage(
                data,
                mediaType: "image/png"
            ))
        }
    }

    func testProductionRendererRejectsAnotherImmutableSourceRevision() async throws {
        let fixture = try makeFixture()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let renderer = UIKitRoomAIRoomPackageDerivativeRenderer(
            snapshot: fixture.package.revisions[0].payload.semanticSnapshot,
            expectedSourceRevision: fixture.source,
            canonicalViewSources: [:]
        )
        var other = fixture.source
        other.revisionID = "other-revision"
        await XCTAssertThrowsErrorAsync {
            _ = try await renderer.renderFloorPlanPNG(sourceRevision: other, into: root)
        }
    }

    private func makeFixture() throws -> (package: RoomProjectPackage, source: RoomRedesignSourceRevision, companion: RoomLocalRedesignExtensionV2) {
        let mock = try MockRoomFixtureLoader.load(bundle: Bundle(for: Self.self))
        let revision = RoomRevisionPackage(manifest: .init(revisionID: mock.manifest.headRevisionID, projectID: mock.manifest.projectID, parentRevisionID: nil, reason: .initial, createdAt: mock.manifest.createdAt, immutable: true, evidenceCompatibility: .legacyV1Planless), payload: mock.draft.revision)
        let package = RoomProjectPackage(manifest: mock.manifest, metadata: mock.draft.metadata, revisions: [revision])
        let semantic = try RoomJSONCoding.makeEncoder().encode(revision.payload.semanticSnapshot)
        let source = RoomRedesignSourceRevision(projectID: mock.manifest.projectID, revisionID: mock.manifest.headRevisionID, coordinateSpaceEpochID: "epoch-001", packageSchemaVersion: RoomProjectSchemaVersion.v2.rawValue, semanticSHA256: RoomSHA256.hexDigest(of: semantic), revisionManifestSHA256: String(repeating: "2", count: 64))
        let orientation = try RoomCanonicalCameraGenerator.makeOrientation(sourceRevision: source, input: .init(source: .confirmed, confidence: 1, entryPositionMeters: .init(x: 0, y: 0, z: -1), inwardDirection: .init(x: 0, y: 0, z: 1), roomBounds: .init(minimum: .init(x: -2, y: 0, z: -2), maximum: .init(x: 2, y: 3, z: 2)), referenceWallFeatureID: "wall-001"))
        let companion = RoomLocalRedesignExtensionV2(sourceRevision: source, orientation: orientation, redesignIntent: .init(request: "Make it calm.", scope: .stage, constraints: nil, permissions: []), propertyMembership: nil, conceptMetadata: [])
        return (package, source, companion)
    }

    private func makeEvidence(boundTo source: RoomRedesignSourceRevision, root: URL) throws -> RoomCaptureBundleBoundEvidence {
        let directory = root.appendingPathComponent("capture", isDirectory: true)
        let frames = directory.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let jpeg = try XCTUnwrap(UIImage(systemName: "square.fill")?.jpegData(compressionQuality: 0.8))
        try jpeg.write(to: frames.appendingPathComponent("frame.jpg"))
        let manifest = RoomCaptureBundleManifest(schemaVersion: RoomCaptureBundleManifest.currentSchemaVersion, createdAt: Date(timeIntervalSince1970: 100), frames: [.init(fileName: "frame.jpg", timestamp: 1, cameraTransform: Array(repeating: 0, count: 16), intrinsics: Array(repeating: 0, count: 9), imageWidth: 16, imageHeight: 16, exposureDuration: 0)], meshAnchorCount: 0, meshVertexCount: 0, meshFaceCount: 0, notes: [])
        return .init(directoryURL: directory, manifest: manifest, sourceBinding: .init(schemaVersion: RoomCaptureBundleSourceBinding.currentSchemaVersion, sourceRevision: source, bundleManifestSHA256: String(repeating: "3", count: 64)))
    }

    private func makeJPEG() throws -> Data {
        try XCTUnwrap(UIImage(systemName: "square.fill")?.jpegData(compressionQuality: 0.8))
    }

    private func makeSource(projectID: String) -> RoomRedesignSourceRevision {
        .init(
            projectID: projectID,
            revisionID: "revision-001",
            coordinateSpaceEpochID: "epoch-001",
            packageSchemaVersion: RoomProjectSchemaVersion.v2.rawValue,
            semanticSHA256: String(repeating: "a", count: 64),
            revisionManifestSHA256: String(repeating: "b", count: 64)
        )
    }

    private func candidate(
        _ id: String,
        sharpness: Double,
        source: RoomRedesignSourceRevision
    ) -> RoomAIReferenceImageCandidate {
        .init(
            evidenceID: id,
            sourceRevision: source,
            capturedAt: Date(timeIntervalSinceReferenceDate: sharpness),
            sharpness: sharpness
        )
    }

    private func assertUnsafeArtifactPath(
        _ expectedPath: String,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected unsafe artifact path \(expectedPath) to be rejected.")
        } catch let error as RoomAIRoomPackageAppServiceError {
            XCTAssertEqual(error, .unsafeArtifactPath(expectedPath))
        } catch {
            XCTFail("Expected unsafe artifact path \(expectedPath), got \(error).")
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct TestRenderer: RoomAIRoomPackageDerivativeRendering {
    func renderFloorPlanPNG(sourceRevision: RoomRedesignSourceRevision, into leaseURL: URL) async throws -> RoomAIRoomPackageAppArtifact {
        try imageArtifact(id: "floor-plan", path: "derivatives/floor-plan.png", root: leaseURL)
    }
    func renderCanonicalViewPNGs(orientation: RoomOrientationContractV2, sourceRevision: RoomRedesignSourceRevision, into leaseURL: URL) async throws -> [RoomAIRoomPackageAppArtifact] {
        try orientation.canonicalCameras.map { try imageArtifact(id: "canonical-view-\($0.cameraID)", path: "derivatives/canonical-views/\($0.cameraID).png", root: leaseURL) }
    }
    private func imageArtifact(id: String, path: String, root: URL) throws -> RoomAIRoomPackageAppArtifact {
        let image = UIGraphicsImageRenderer(size: .init(width: 2, height: 2)).pngData { context in UIColor.black.setFill(); context.fill(.init(x: 0, y: 0, width: 2, height: 2)) }
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try image.write(to: url)
        return .init(artifactID: id, sourceURL: url, relativePath: path, mediaType: "image/png")
    }
}
