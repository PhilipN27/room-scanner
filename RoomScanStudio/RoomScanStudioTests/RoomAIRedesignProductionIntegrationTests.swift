import Foundation
import RoomScanCore
import UIKit
import XCTest
@testable import RoomScanStudio

@MainActor
final class RoomAIRedesignProductionIntegrationTests: XCTestCase {
    func testCompleteWithoutRawDoesNotRequireMisleadingRawConsent() {
        XCTAssertFalse(RoomAIDisclosurePresentationPolicy.requiresRawEvidenceConsent(
            profile: .complete,
            includesRawEvidence: false
        ))
        XCTAssertTrue(RoomAIDisclosurePresentationPolicy.requiresRawEvidenceConsent(
            profile: .complete,
            includesRawEvidence: true
        ))
    }

    func testHostBlocksInteractiveDismissalWhileDraftingWorkOwnsAnExportLease() {
        XCTAssertFalse(RoomAIRedesignHostView.preventsInteractiveDismissal(
            reviewState: .drafting,
            reviewInputsLocked: false
        ))
        XCTAssertTrue(RoomAIRedesignHostView.preventsInteractiveDismissal(
            reviewState: .drafting,
            reviewInputsLocked: true
        ))
        XCTAssertTrue(RoomAIRedesignHostView.preventsInteractiveDismissal(
            reviewState: .archiveReady,
            reviewInputsLocked: true
        ))
    }

    func testEditingWhilePreparationIsSuspendedCannotPublishStaleDraftAndCleansLease() async throws {
        let harness = try makeLifecycleHarness(mode: .suspendPrepare)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        harness.model.brief = "Original request"

        harness.model.prepareReview()
        try await waitUntil(condition: { harness.service.prepareIsSuspended })
        harness.model.brief = "Changed while preparing"
        harness.service.resumePrepareSuccessfully()

        try await waitUntil(condition: {
            harness.service.cleanedLeaseURLs.contains(harness.workspaceURL)
        })
        XCTAssertEqual(harness.model.reviewState, .stale)
        XCTAssertNil(harness.model.shareArchiveURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.workspaceURL.path))
    }

    func testEditingWhileFinalizationIsSuspendedCannotPublishStaleArchive() async throws {
        let harness = try makeLifecycleHarness(mode: .suspendFinalize)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        harness.model.brief = "Original request"
        harness.model.prepareReview()
        try await waitUntil(condition: { harness.model.reviewState == .readyForReview })

        harness.model.externalProviderNoticeAccepted = true
        harness.model.approveReview()
        try await waitUntil(condition: { harness.service.finalizeIsSuspended })
        harness.model.brief = "Changed while finalizing"
        harness.service.resumeFinalizeSuccessfully()

        try await waitUntil(condition: {
            harness.service.cleanedLeaseURLs.contains(harness.workspaceURL)
        })
        XCTAssertEqual(harness.model.reviewState, .stale)
        XCTAssertNil(harness.model.shareArchiveURL)
        XCTAssertNil(harness.model.sharePresentationRequest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.workspaceURL.path))
    }

    func testDiscardDuringSuspendedPreparationWaitsForOwnedLeaseCleanup() async throws {
        let harness = try makeLifecycleHarness(mode: .suspendPrepare)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        harness.model.brief = "Original request"
        harness.model.prepareReview()
        try await waitUntil(condition: { harness.service.prepareIsSuspended })

        let discard = Task { @MainActor in
            await harness.model.discardPreparedArchive()
        }
        await Task.yield()
        harness.service.resumePrepareSuccessfully()

        let discarded = await discard.value
        XCTAssertTrue(discarded)
        XCTAssertEqual(harness.model.reviewState, .drafting)
        XCTAssertTrue(harness.service.cleanedLeaseURLs.contains(harness.workspaceURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.workspaceURL.path))
    }

    func testConceptPackageProvenanceRegistryRejectsSymlinkAndOversizeBinding() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RoomAIConceptProvenance-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)

        let sourcePackageRoot = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourcePackageRoot,
            withIntermediateDirectories: false
        )
        let source = RoomRedesignSourceRevision(
            projectID: "provenance-project",
            revisionID: "provenance-revision",
            coordinateSpaceEpochID: "provenance-epoch",
            packageSchemaVersion: RoomProjectSchemaVersion.v2.rawValue,
            semanticSHA256: String(repeating: "a", count: 64),
            revisionManifestSHA256: String(repeating: "b", count: 64)
        )

        // An extant ancestor can redirect the nominal app-owned root into the
        // immutable source tree even though the leaf does not yet exist.
        let escapedAncestor = root.appendingPathComponent("provenance-escape", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            atPath: escapedAncestor.path,
            withDestinationPath: sourcePackageRoot.path
        )
        let escapedRegistry = RoomAIConceptPackageProvenanceRegistry(
            rootURL: escapedAncestor.appendingPathComponent(
                "AIRedesignProvenance",
                isDirectory: true
            ),
            sourcePackageRootURL: sourcePackageRoot
        )
        XCTAssertThrowsError(try escapedRegistry.bindings(for: source))

        let provenanceRoot = root.appendingPathComponent(
            "AIRedesignProvenance",
            isDirectory: true
        )
        let recordDirectory = provenanceRoot
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent(source.projectID, isDirectory: true)
            .appendingPathComponent(source.revisionID, isDirectory: true)
            .appendingPathComponent(source.revisionManifestSHA256, isDirectory: true)
        try FileManager.default.createDirectory(
            at: recordDirectory,
            withIntermediateDirectories: true
        )
        try Data(repeating: 0, count: 16 * 1_024 * 1_024 + 1).write(
            to: recordDirectory.appendingPathComponent("binding.json"),
            options: .withoutOverwriting
        )
        let oversizedRegistry = RoomAIConceptPackageProvenanceRegistry(
            rootURL: provenanceRoot,
            sourcePackageRootURL: sourcePackageRoot
        )
        XCTAssertThrowsError(try oversizedRegistry.bindings(for: source))
    }

    func testGuestProductionFactoryBuildsValidAIReadyAndCompleteArchivesAndCleansShares() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RoomAIRedesignProduction-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appendingPathComponent("Projects", isDirectory: true)
        let store = LocalRoomProjectStore(
            rootURL: projectRoot,
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: ["production-ai-project"],
                revisionIDs: ["production-ai-revision"]
            )
        )
        let controller = RoomLibraryController(
            store: store,
            modelContainer: nil,
            redesignStore: LocalRoomRedesignStore(
                rootURL: root.appendingPathComponent("RedesignState", isDirectory: true)
            )
        )
        let fixture = try MockRoomFixtureLoader.load(bundle: Bundle(for: Self.self))
        let savedValue = try await controller.saveMockDraft(
            fixture.draft,
            assets: fixture.assets
        )
        let saved = try XCTUnwrap(savedValue)
        let package = try await controller.loadPackage(projectID: saved.projectID)
        let head = try XCTUnwrap(package.revisions.last)
        let source = try await controller.redesignSourceBinding(
            projectID: saved.projectID,
            revisionID: package.manifest.headRevisionID
        )
        let bounds = try RoomSpatialNormalization.bounds(
            of: head.payload.semanticSnapshot
        )
        let orientation = try RoomCanonicalCameraGenerator.makeOrientation(
            sourceRevision: source,
            input: .init(
                source: .manual,
                confidence: 1,
                entryPositionMeters: .init(
                    x: bounds.minimum.x,
                    y: bounds.minimum.y,
                    z: bounds.minimum.z
                ),
                inwardDirection: .init(x: 0, y: 0, z: 1),
                roomBounds: bounds,
                referenceWallFeatureID: head.payload.semanticSnapshot
                    .structuralElements.first?.id
            )
        )
        let companion = RoomLocalRedesignExtensionV2(
            sourceRevision: source,
            orientation: orientation,
            redesignIntent: nil,
            propertyMembership: nil,
            conceptMetadata: []
        )
        try await controller.saveRedesignState(
            companion,
            expectedSourceRevision: source
        )
        try? RoomCaptureBundleLibrary.removeBundle(forProject: saved.projectID)
        defer { try? RoomCaptureBundleLibrary.removeBundle(forProject: saved.projectID) }
        let captureScratch = root.appendingPathComponent("BoundCapture", isDirectory: true)
        let captureFrames = captureScratch.appendingPathComponent(
            RoomCaptureBundleLibrary.framesSubdirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: captureFrames,
            withIntermediateDirectories: true
        )
        let referenceImage = UIGraphicsImageRenderer(
            size: CGSize(width: 96, height: 72)
        ).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 72))
            UIColor.white.setFill()
            context.fill(CGRect(x: 18, y: 14, width: 60, height: 44))
        }
        let referenceBytes = try XCTUnwrap(
            referenceImage.jpegData(compressionQuality: 0.85)
        )
        try referenceBytes.write(
            to: captureFrames.appendingPathComponent("reference-1.jpg"),
            options: .withoutOverwriting
        )
        let captureManifest = RoomCaptureBundleManifest(
            schemaVersion: RoomCaptureBundleManifest.currentSchemaVersion,
            createdAt: Date(timeIntervalSinceReferenceDate: 80),
            frames: [
                .init(
                    fileName: "reference-1.jpg",
                    timestamp: 1,
                    cameraTransform: Array(repeating: 0, count: 16),
                    intrinsics: Array(repeating: 0, count: 9),
                    imageWidth: 96,
                    imageHeight: 72,
                    exposureDuration: 0
                ),
            ],
            meshAnchorCount: 0,
            meshVertexCount: 0,
            meshFaceCount: 0,
            notes: []
        )
        try RoomJSONCoding.makeEncoder().encode(captureManifest).write(
            to: captureScratch.appendingPathComponent(
                RoomCaptureBundleLibrary.manifestFileName
            ),
            options: .withoutOverwriting
        )
        try RoomCaptureBundleLibrary.adoptBoundBundle(
            at: captureScratch,
            forProject: saved.projectID,
            sourceRevision: source
        )

        let workspaceFactory = RoomExportWorkspaceFactory(
            rootURL: root.appendingPathComponent("ExportScratch", isDirectory: true)
        )
        let packageIdentifierSource = DeterministicPackageIdentifierSource()
        let factory = RoomAIRedesignModelFactory(
            controller: controller,
            workspaceFactory: workspaceFactory,
            projectRootURL: projectRoot,
            conceptRootURL: root.appendingPathComponent("ConceptSets", isDirectory: true),
            conceptImportScratchRootURL: root.appendingPathComponent(
                "ConceptImportScratch",
                isDirectory: true
            ),
            provenanceRootURL: root.appendingPathComponent(
                "AIRedesignProvenance",
                isDirectory: true
            ),
            mintPackageIdentifier: { packageIdentifierSource.next() }
        )
        let model = try await factory.makeModel(projectID: saved.projectID)
        XCTAssertEqual(model.sourceRevision, source)
        XCTAssertEqual(model.selectedProfile, .aiReady)

        // The model factory has not retained an independently validated AI
        // package identity at this point. A provider-controlled Concept
        // manifest that merely repeats the future package ID and a current
        // camera ID must therefore not gain automatic mapping authority.
        let canonicalCameraID = try XCTUnwrap(orientation.canonicalCameras.first?.cameraID)
        let forgedAutomaticConcept = try await writePackagedConceptArchive(
            root: root,
            archiveName: "forged-automatic-concept.zip",
            conceptSetID: "forged-automatic-concept",
            sourceRevision: source,
            sourceFilename: "forged-automatic-concept.zip",
            mapping: .automatic(cameraID: canonicalCameraID)
        )
        model.importPackageConcept()
        model.completeFileImport(url: forgedAutomaticConcept)
        try await waitUntil(condition: { model.reviewMessage != nil })
        XCTAssertTrue(
            model.concepts.isEmpty,
            "A self-asserted package/camera tuple must not create an automatic Concept mapping."
        )

        // Packaged output without automatic authority remains locally useful:
        // its untrusted manual claim is imported as unmatched so the user can
        // choose a confirmed local canonical view during review.
        let manualConcept = try await writePackagedConceptArchive(
            root: root,
            archiveName: "manual-concept.zip",
            conceptSetID: "manual-concept",
            sourceRevision: source,
            sourceFilename: "manual-concept.zip",
            mapping: .manual(cameraID: canonicalCameraID)
        )
        model.importPackageConcept()
        model.completeFileImport(url: manualConcept)
        try await waitUntil(
            diagnostics: {
                let message = model.reviewMessage ?? "nil"
                return "concepts=\(model.concepts.count), message=\(message)"
            },
            condition: { model.concepts.count == 1 }
        )
        XCTAssertEqual(model.concepts.first?.mapping.rawValue, RoomAIConceptMapping.unmatched.rawValue)

        model.brief = "Keep the walls and create a calm reading area."
        model.prepareReview()
        try await waitUntil(
            timeout: 40,
            diagnostics: {
                "state=\(model.reviewState), message=\(model.reviewMessage ?? "nil")"
            },
            condition: {
                model.reviewState == .readyForReview
                    || model.reviewState == .stale
            }
        )
        XCTAssertEqual(
            model.reviewState,
            .readyForReview,
            model.reviewMessage ?? "Preparation failed without a message."
        )
        guard model.reviewState == .readyForReview else { return }
        XCTAssertFalse(model.externalProviderNoticeAccepted)
        XCTAssertFalse(model.images.isEmpty)
        for image in model.images {
            let preview = try XCTUnwrap(image.previewData)
            XCTAssertLessThanOrEqual(preview.count, 1_000_000)
            let decoded = try XCTUnwrap(UIImage(data: preview))
            XCTAssertLessThanOrEqual(max(decoded.size.width, decoded.size.height), 960)
        }
        XCTAssertFalse(model.inventory.contains {
            $0.included && ["rawRGB", "rawDepth", "rawConfidence", "diagnostics"]
                .contains($0.title)
        })

        model.approveReview()
        XCTAssertEqual(model.reviewState, .readyForReview)
        model.externalProviderNoticeAccepted = true
        model.approveReview()
        try await waitUntil(
            diagnostics: {
                "state=\(model.reviewState), message=\(model.reviewMessage ?? "nil")"
            },
            condition: {
                model.reviewState == .archiveReady
                    || model.reviewState == .stale
            }
        )
        XCTAssertEqual(
            model.reviewState,
            .archiveReady,
            model.reviewMessage ?? "Finalization failed."
        )
        guard model.reviewState == .archiveReady else { return }
        model.shareArchive()
        let request = try XCTUnwrap(model.sharePresentationRequest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: request.archiveURL.path))
        let extraction = root.appendingPathComponent("IndependentExtraction", isDirectory: true)
        try FileManager.default.createDirectory(
            at: extraction,
            withIntermediateDirectories: false
        )
        let validation = try await RoomAIRoomPackageArchive.extractAndValidate(
            archiveURL: request.archiveURL,
            into: extraction,
            expectedSourceRevision: source,
            expectedProfile: .aiReady
        )
        XCTAssertEqual(validation.package.profile, .aiReady)
        XCTAssertEqual(validation.package.packageID, "ai-room-test-001")
        XCTAssertFalse(validation.package.artifacts.contains {
            $0.disposition == .included && $0.artifactClass.isAIRawEvidence
        })

        // A packaged Concept Set cannot create automatic authority merely by
        // naming a source package. Once this exact local package has been
        // finalized and independently validated, its manifest identity and
        // canonical-view ledger are the only authority that may allow an
        // automatic mapping.
        let conceptCountBeforeAutomaticImport = model.concepts.count
        let importModel = try await factory.makeModel(projectID: saved.projectID)
        try await waitUntil(
            timeout: 5,
            diagnostics: {
                "concepts=\(importModel.concepts.count), message=\(importModel.reviewMessage ?? "nil")"
            },
            condition: { importModel.concepts.count == conceptCountBeforeAutomaticImport }
        )
        let validatedAutomaticConcept = try await writePackagedConceptArchive(
            root: root,
            archiveName: "validated-automatic-concept.zip",
            conceptSetID: "validated-automatic-concept",
            sourceRevision: source,
            sourceFilename: "validated-automatic-concept.zip",
            sourcePackageID: validation.package.packageID,
            mapping: .automatic(cameraID: canonicalCameraID)
        )
        importModel.importPackageConcept()
        importModel.completeFileImport(url: validatedAutomaticConcept)
        try await waitUntil(
            timeout: 5,
            diagnostics: {
                "concepts=\(importModel.concepts.count), message=\(importModel.reviewMessage ?? "nil")"
            },
            condition: { importModel.reviewMessage != nil }
        )
        XCTAssertEqual(
            importModel.concepts.count,
            conceptCountBeforeAutomaticImport + 1,
            "The exact independently validated archive package must authorize automatic mapping."
        )
        XCTAssertEqual(
            importModel.concepts.last?.mapping.rawValue,
            RoomAIConceptMapping.automatic.rawValue
        )
        let workspace = request.archiveURL.deletingLastPathComponent()

        model.completeSystemShare(outcome: .cancelled)
        XCTAssertEqual(model.reviewState, .drafting)
        XCTAssertNil(model.sharePresentationRequest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))

        // Duplicate terminal callbacks are ignored and cannot target another
        // lease or repeat cleanup.
        model.completeSystemShare(outcome: .failed)
        XCTAssertEqual(model.reviewState, .drafting)

        // Recreating the model must reload persisted package provenance rather
        // than synthesizing it from the current room orientation. The stored
        // automatic mapping must remain readable after its source archive lease
        // has been released.
        let reloadedModel = try await factory.makeModel(projectID: saved.projectID)
        try await waitUntil(timeout: 5, condition: {
            reloadedModel.concepts.count == conceptCountBeforeAutomaticImport + 1
        })
        XCTAssertTrue(reloadedModel.concepts.contains {
            $0.mapping.rawValue == RoomAIConceptMapping.automatic.rawValue
        })

        // Run the production boundary independently for Complete. The first
        // approval attempt proves raw evidence cannot be finalized without the
        // exact expanded consent; the second produces a closure-validated ZIP.
        model.selectedProfile = .complete
        model.prepareReview()
        try await waitUntil(
            timeout: 40,
            diagnostics: {
                "complete state=\(model.reviewState), message=\(model.reviewMessage ?? "nil")"
            },
            condition: {
                model.reviewState == .readyForReview
                    || model.reviewState == .stale
            }
        )
        XCTAssertEqual(
            model.reviewState,
            .readyForReview,
            model.reviewMessage ?? "Complete preparation failed."
        )
        guard model.reviewState == .readyForReview else { return }
        XCTAssertTrue(model.includesRawEvidence)
        let reviewedRawImages = model.images.filter { !$0.allowsSelectionChanges }
        XCTAssertFalse(reviewedRawImages.isEmpty)
        XCTAssertTrue(reviewedRawImages.allSatisfy { $0.previewData != nil })
        XCTAssertTrue(reviewedRawImages.allSatisfy {
            $0.metadata.contains("image/jpeg") && $0.metadata.contains("bytes")
        })
        model.externalProviderNoticeAccepted = true
        model.approveReview()
        XCTAssertEqual(model.reviewState, .readyForReview)
        XCTAssertTrue(
            model.reviewMessage?.contains("consent") == true,
            model.reviewMessage ?? "Missing raw-evidence consent message."
        )

        model.completeRawConsent = true
        model.approveReview()
        try await waitUntil(
            timeout: 40,
            diagnostics: {
                "complete finalize state=\(model.reviewState), message=\(model.reviewMessage ?? "nil")"
            },
            condition: {
                model.reviewState == .archiveReady
                    || model.reviewState == .stale
            }
        )
        XCTAssertEqual(
            model.reviewState,
            .archiveReady,
            model.reviewMessage ?? "Complete finalization failed."
        )
        guard model.reviewState == .archiveReady else { return }
        model.shareArchive()
        let completeRequest = try XCTUnwrap(model.sharePresentationRequest)
        let completeExtraction = root.appendingPathComponent(
            "CompleteIndependentExtraction",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: completeExtraction,
            withIntermediateDirectories: false
        )
        let completeValidation = try await RoomAIRoomPackageArchive.extractAndValidate(
            archiveURL: completeRequest.archiveURL,
            into: completeExtraction,
            expectedSourceRevision: source,
            expectedProfile: .complete
        )
        XCTAssertEqual(completeValidation.package.profile, .complete)
        XCTAssertEqual(completeValidation.package.packageID, validation.package.packageID)
        XCTAssertEqual(packageIdentifierSource.mintCount, 1)
        XCTAssertTrue(completeValidation.package.artifacts.contains {
            $0.disposition == .included && $0.artifactClass.isAIRawEvidence
        })
        XCTAssertFalse(completeValidation.package.artifacts.contains {
            $0.artifactClass == .worldMap
        })
        let completeWorkspace = completeRequest.archiveURL.deletingLastPathComponent()
        model.completeSystemShare(outcome: .completed)
        XCTAssertEqual(model.reviewState, .drafting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: completeWorkspace.path))

        // A provenance root must not escape into the immutable source package
        // through a symlinked ancestor, and malformed local records fail
        // closed before a recreated model can claim automatic authority.
        let sourceEntriesBeforeProvenanceProbe = try FileManager.default
            .contentsOfDirectory(atPath: projectRoot.path)
            .sorted()
        let escapedAncestor = root.appendingPathComponent("provenance-escape", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            atPath: escapedAncestor.path,
            withDestinationPath: projectRoot.path
        )
        let escapedFactory = RoomAIRedesignModelFactory(
            controller: controller,
            workspaceFactory: workspaceFactory,
            projectRootURL: projectRoot,
            conceptRootURL: root.appendingPathComponent("ConceptSets", isDirectory: true),
            conceptImportScratchRootURL: root.appendingPathComponent(
                "ConceptImportScratch",
                isDirectory: true
            ),
            provenanceRootURL: escapedAncestor.appendingPathComponent(
                "AIRedesignProvenance",
                isDirectory: true
            ),
            mintPackageIdentifier: { "must-not-mint" }
        )
        do {
            _ = try await escapedFactory.makeModel(projectID: saved.projectID)
            XCTFail("A provenance ancestor symlink must fail closed.")
        } catch {}

        let corruptProvenanceRoot = root.appendingPathComponent(
            "CorruptAIRedesignProvenance",
            isDirectory: true
        )
        let corruptRecordDirectory = corruptProvenanceRoot
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent(source.projectID, isDirectory: true)
            .appendingPathComponent(source.revisionID, isDirectory: true)
            .appendingPathComponent(source.revisionManifestSHA256, isDirectory: true)
        try FileManager.default.createDirectory(
            at: corruptRecordDirectory,
            withIntermediateDirectories: true
        )
        try Data(repeating: 0, count: 16 * 1_024 * 1_024 + 1).write(
            to: corruptRecordDirectory.appendingPathComponent("binding.json"),
            options: .withoutOverwriting
        )
        let corruptFactory = RoomAIRedesignModelFactory(
            controller: controller,
            workspaceFactory: workspaceFactory,
            projectRootURL: projectRoot,
            conceptRootURL: root.appendingPathComponent("ConceptSets", isDirectory: true),
            conceptImportScratchRootURL: root.appendingPathComponent(
                "ConceptImportScratch",
                isDirectory: true
            ),
            provenanceRootURL: corruptProvenanceRoot,
            mintPackageIdentifier: { "must-not-mint" }
        )
        do {
            _ = try await corruptFactory.makeModel(projectID: saved.projectID)
            XCTFail("An oversized provenance record must fail closed.")
        } catch {}
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: projectRoot.path).sorted(),
            sourceEntriesBeforeProvenanceProbe
        )

        let conceptURL = root.appendingPathComponent("comparison-concept.png")
        let conceptBytes = UIGraphicsImageRenderer(
            size: CGSize(width: 80, height: 60)
        ).pngData { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        }
        try conceptBytes.write(to: conceptURL, options: .withoutOverwriting)
        model.importLooseConcept()
        model.completeFileImport(url: conceptURL)
        try await waitUntil(condition: { !model.concepts.isEmpty })
        let conceptID = try XCTUnwrap(model.concepts.first?.id)

        model.archiveConcept(conceptID)
        try await waitUntil(condition: {
            model.concepts.first(where: { $0.id == conceptID })?.archived == true
        })
        model.unarchiveConcept(conceptID)
        try await waitUntil(condition: {
            model.concepts.first(where: { $0.id == conceptID })?.archived == false
        })
        let deletableID = try XCTUnwrap(
            model.concepts.first(where: { $0.id != conceptID })?.id,
            "The earlier packaged Concept fixture must remain available for mandatory deletion."
        )
        let conceptCountBeforeDelete = model.concepts.count
        model.deleteConcept(deletableID)
        try await waitUntil(condition: {
            model.concepts.count == conceptCountBeforeDelete - 1
                && !model.concepts.contains(where: { $0.id == deletableID })
        })

        var editor = try RoomRevisionEditor(payload: head.payload)
        let editedElementID = try XCTUnwrap(
            head.payload.semanticSnapshot.objectElements.first?.id
                ?? head.payload.semanticSnapshot.structuralElements.first?.id
        )
        try editor.renameElement(id: editedElementID, label: "Changed after concept import")
        _ = try await controller.commitEditRevision(
            projectID: saved.projectID,
            expectedHeadRevisionID: package.manifest.headRevisionID,
            payload: editor.payload,
            newRevisionID: "production-ai-revision-2"
        )

        model.compareConcept(conceptID)
        try await waitUntil(condition: {
            model.reviewMessage?.contains("could not be loaded for comparison") == true
        })
        XCTAssertNil(model.comparisonPresentation)
    }

    private func writePackagedConceptArchive(
        root: URL,
        archiveName: String,
        conceptSetID: String,
        sourceRevision: RoomRedesignSourceRevision,
        sourceFilename: String,
        sourcePackageID: String = "ai-room-package",
        mapping: RoomConceptAttachmentMapping
    ) async throws -> URL {
        let unsafeImageData = UIGraphicsImageRenderer(
            size: CGSize(width: 48, height: 32)
        ).pngData { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
        }
        let sanitizedImage = try RoomAIImageSanitizer.sanitize(
            unsafeImageData,
            declaredFilename: "fixture.png"
        )
        let imageData = sanitizedImage.data
        let attachmentExtension = sanitizedImage.mediaType == "image/jpeg" ? "jpg" : "png"
        let attachment = RoomConceptSetAttachment(
            attachmentID: "attachment-0001",
            relativePath: "attachments/attachment-0001.\(attachmentExtension)",
            sha256: RoomSHA256.hexDigest(of: imageData),
            byteCount: UInt64(imageData.count),
            mediaType: sanitizedImage.mediaType,
            sanitizationProvenance: .appReencodedPackagedFile,
            mapping: mapping
        )
        let concept = RoomConceptSet(
            conceptSetID: conceptSetID,
            sourceRevision: sourceRevision,
            request: "A local Concept Set fixture.",
            scope: .stage,
            provider: nil,
            sourceAIRoomPackage: .init(
                schemaVersion: RoomRedesignContractKind.aiRoomPackage.supportedSchemaVersion,
                packageID: sourcePackageID
            ),
            importProvenance: .init(
                kind: .packagedOutput,
                sourceFilename: sourceFilename
            ),
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            importedAt: Date(timeIntervalSinceReferenceDate: 100),
            attachments: [attachment],
            comments: [],
            approvalState: .pending,
            archiveState: .active
        )
        let staging = root.appendingPathComponent(
            "concept-archive-\(conceptSetID)",
            isDirectory: true
        )
        let attachments = staging.appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(
            at: attachments,
            withIntermediateDirectories: true
        )
        let manifestURL = staging.appendingPathComponent("manifest.json")
        let attachmentURL = attachments.appendingPathComponent("attachment-0001.\(attachmentExtension)")
        try RoomConceptSetCanonicalJSON.encode(concept).write(
            to: manifestURL,
            options: .withoutOverwriting
        )
        try imageData.write(to: attachmentURL, options: .withoutOverwriting)
        let archiveURL = root.appendingPathComponent(archiveName)
        _ = try await RoomDeterministicZIP.write(
            inputs: [
                .init(
                    sourceURL: manifestURL,
                    entryPath: try RoomExportEntryPath("manifest.json"),
                    mediaType: "application/json"
                ),
                .init(
                    sourceURL: attachmentURL,
                    entryPath: try RoomExportEntryPath(attachment.relativePath),
                    mediaType: attachment.mediaType
                ),
            ],
            to: archiveURL
        )
        return archiveURL
    }

    private func makeLifecycleHarness(
        mode: SuspendedRoomAIRoomPackageService.Mode
    ) throws -> LifecycleHarness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RoomAIRedesignLifecycle-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let source = RoomRedesignSourceRevision(
            projectID: "lifecycle-project",
            revisionID: "lifecycle-revision",
            coordinateSpaceEpochID: "lifecycle-epoch",
            packageSchemaVersion: RoomProjectSchemaVersion.v2.rawValue,
            semanticSHA256: String(repeating: "a", count: 64),
            revisionManifestSHA256: String(repeating: "b", count: 64)
        )
        let orientation = try RoomCanonicalCameraGenerator.makeOrientation(
            sourceRevision: source,
            input: .init(
                source: .confirmed,
                confidence: 1,
                entryPositionMeters: .init(x: 0, y: 0, z: -1),
                inwardDirection: .init(x: 0, y: 0, z: 1),
                roomBounds: .init(
                    minimum: .init(x: -1, y: 0, z: -1),
                    maximum: .init(x: 1, y: 2, z: 1)
                ),
                referenceWallFeatureID: "wall-1"
            )
        )
        let companion = RoomLocalRedesignExtensionV2(
            sourceRevision: source,
            orientation: orientation,
            redesignIntent: .init(
                request: "Original request",
                scope: .stage,
                constraints: nil,
                permissions: []
            ),
            propertyMembership: nil,
            conceptMetadata: []
        )
        let context = try RoomAIRoomPackageReadiness.requireEligible(
            sourceRevision: source,
            companion: companion
        )
        let workspaceURL = root.appendingPathComponent("owned-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: false)
        let prepared = makeLifecycleDraft(
            source: source,
            workspaceURL: workspaceURL
        )
        let service = SuspendedRoomAIRoomPackageService(
            mode: mode,
            preparedDraft: prepared
        )
        let conceptRoot = root.appendingPathComponent("Concepts", isDirectory: true)
        let packageRoot = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: false)
        let concepts = RoomConceptImportCoordinator(
            store: LocalRoomConceptStore(
                rootURL: conceptRoot,
                sourcePackageRootURL: packageRoot
            ),
            scratchRootURL: root.appendingPathComponent("ConceptScratch", isDirectory: true)
        )
        let dependencies = RoomAIRedesignProductionDependencies(
            materialize: { request in
                RoomAIRoomPackageMaterialization(
                    context: context,
                    profile: request.profile,
                    artifacts: []
                )
            },
            packageService: service,
            disclosure: RoomAIDisclosureCoordinator(
                clock: { Date(timeIntervalSinceReferenceDate: 100) },
                reviewID: { "lifecycle-review" }
            ),
            concepts: concepts,
            conceptContext: .init(
                expectedSourceRevision: source,
                currentCanonicalCameraIDs: orientation.canonicalCameras.map(\.cameraID)
            ),
            canonicalViewChoices: orientation.canonicalCameras.map(\.cameraID)
        )
        return LifecycleHarness(
            root: root,
            workspaceURL: workspaceURL,
            model: RoomAIRedesignProductionModel(
                sourceRevision: source,
                dependencies: dependencies
            ),
            service: service
        )
    }

    private func makeLifecycleDraft(
        source: RoomRedesignSourceRevision,
        workspaceURL: URL
    ) -> RoomAIRoomPackagePreparedDraft {
        let planDigest = String(repeating: "c", count: 64)
        let selectionDigest = String(repeating: "d", count: 64)
        let preparation = RoomAIRoomPackagePreparation(
            packageID: "lifecycle-package",
            profile: .aiReady,
            sourceRevision: source,
            artifactPlan: [],
            artifactPlanSHA256: planDigest,
            selectionSHA256: selectionDigest,
            artifacts: [],
            includedSources: []
        )
        let disclosure = RoomAIDisclosureDraft(
            sourceRevision: source,
            profile: .aiReady,
            artifactPlanSHA256: planDigest,
            selectionSHA256: selectionDigest,
            selectedImages: [],
            artifactInventory: [
                .init(
                    artifactID: "semantic-model",
                    artifactClass: .normalizedSemantics,
                    disposition: .included,
                    reasonCode: nil
                ),
            ],
            estimatedPackageByteCount: 1,
            qualityWarnings: [],
            includesRawEvidence: false,
            preciseGPSExcluded: true
        )
        return .init(
            preparation: preparation,
            disclosureDraft: disclosure,
            selectedImagePreviewData: [:],
            workspaceURL: workspaceURL
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 20,
        diagnostics: @escaping @MainActor () -> String = { "No additional diagnostics." },
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail(
                    "Timed out waiting for the production AI redesign state: \(diagnostics())"
                )
                throw WaitError.timeout
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private enum WaitError: Error { case timeout }
}

private final class DeterministicPackageIdentifierSource {
    private(set) var mintCount = 0

    func next() -> String {
        mintCount += 1
        return String(format: "ai-room-test-%03d", mintCount)
    }
}

@MainActor
private struct LifecycleHarness {
    let root: URL
    let workspaceURL: URL
    let model: RoomAIRedesignProductionModel
    let service: SuspendedRoomAIRoomPackageService
}

@MainActor
private final class SuspendedRoomAIRoomPackageService: RoomAIRoomPackageServicing {
    enum Mode { case suspendPrepare, suspendFinalize }

    private let mode: Mode
    private let preparedDraft: RoomAIRoomPackagePreparedDraft
    private var prepareContinuation: CheckedContinuation<RoomAIRoomPackagePreparedDraft, Error>?
    private var finalizeContinuation: CheckedContinuation<RoomAIRoomPackageArchiveResult, Error>?
    private var pendingReview: RoomDisclosureReview?
    private(set) var cleanedLeaseURLs: [URL] = []

    var prepareIsSuspended: Bool { prepareContinuation != nil }
    var finalizeIsSuspended: Bool { finalizeContinuation != nil }

    init(mode: Mode, preparedDraft: RoomAIRoomPackagePreparedDraft) {
        self.mode = mode
        self.preparedDraft = preparedDraft
    }

    func prepare(
        materialization: RoomAIRoomPackageMaterialization,
        excludedReferenceIDs: Set<String>,
        replacementReferenceIDs: Set<String>,
        packageID: String
    ) async throws -> RoomAIRoomPackagePreparedDraft {
        guard mode == .suspendPrepare else { return preparedDraft }
        return try await withCheckedThrowingContinuation { continuation in
            prepareContinuation = continuation
        }
    }

    func finalize(
        _ draft: RoomAIRoomPackagePreparedDraft,
        disclosureReview: RoomDisclosureReview
    ) async throws -> RoomAIRoomPackageArchiveResult {
        pendingReview = disclosureReview
        guard mode == .suspendFinalize else {
            return try makeArchive(review: disclosureReview)
        }
        return try await withCheckedThrowingContinuation { continuation in
            finalizeContinuation = continuation
        }
    }

    func cleanupLease(_ lease: URL) throws {
        cleanedLeaseURLs.append(lease)
        if FileManager.default.fileExists(atPath: lease.path) {
            try FileManager.default.removeItem(at: lease)
        }
    }

    func resumePrepareSuccessfully() {
        let continuation = prepareContinuation
        prepareContinuation = nil
        continuation?.resume(returning: preparedDraft)
    }

    func resumeFinalizeSuccessfully() {
        let continuation = finalizeContinuation
        finalizeContinuation = nil
        guard let review = pendingReview else {
            continuation?.resume(throwing: WaitFailure.missingReview)
            return
        }
        do {
            continuation?.resume(returning: try makeArchive(review: review))
        } catch {
            continuation?.resume(throwing: error)
        }
    }

    private func makeArchive(
        review: RoomDisclosureReview
    ) throws -> RoomAIRoomPackageArchiveResult {
        if !FileManager.default.fileExists(atPath: preparedDraft.workspaceURL.path) {
            try FileManager.default.createDirectory(
                at: preparedDraft.workspaceURL,
                withIntermediateDirectories: false
            )
        }
        let archiveURL = preparedDraft.workspaceURL.appendingPathComponent("ai-room-package.zip")
        try Data("archive".utf8).write(to: archiveURL)
        let preparation = preparedDraft.preparation
        return .init(
            archiveURL: archiveURL,
            package: .init(
                packageID: preparation.packageID,
                profile: preparation.profile,
                sourceRevision: preparation.sourceRevision,
                artifactPlan: preparation.artifactPlan,
                artifactPlanSHA256: preparation.artifactPlanSHA256,
                selectionSHA256: preparation.selectionSHA256,
                disclosureReview: review,
                artifacts: preparation.artifacts
            ),
            manifestData: Data("{}".utf8),
            receipt: .init(
                profileVersion: RoomDeterministicZIP.profileVersion,
                archiveSHA256: String(repeating: "e", count: 64),
                archiveByteCount: 7,
                entries: []
            )
        )
    }

    private enum WaitFailure: Error { case missingReview }
}
