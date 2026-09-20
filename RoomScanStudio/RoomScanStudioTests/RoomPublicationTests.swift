import Foundation
import RoomScanCore
import UIKit
import XCTest
@testable import RoomScanStudio

/// Publication review is deliberately modeled separately from a private room
/// package. These focused tests establish the native safety oracle before the
/// publication model and service exist.
@MainActor
final class RoomPublicationTests: XCTestCase {
    func testApprovalIsInvalidatedWhenTheSelectedArtifactDigestChanges() async throws {
        let model = RoomPublicationReviewModel.fixture(mode: .room)

        try await model.prepareReview()
        try model.approveReview()
        XCTAssertNotNil(model.approval)

        model.setSelectedConceptIDs(["approved-concept-b"])

        XCTAssertNil(model.approval)
        XCTAssertEqual(model.reviewState, .approvalInvalidated)
    }

    func testPublicationControlsDefaultToThirtyDaysWithoutRetainingThePIN() {
        let controls = RoomPublicationLinkControls.default(now: Date(timeIntervalSince1970: 0))

        XCTAssertNil(controls.expiresAt, "Native omits expiry so the server applies its controlled-clock 30-day default.")
        XCTAssertFalse(controls.requiresPIN)
        XCTAssertFalse(controls.allowsAIReadyPackageDownload)
        XCTAssertFalse(controls.allowsFeedback)
        XCTAssertEqual(RoomPublicationStaticDownloadControls.none, .init(
            allowsFloorPlanPDF: false,
            allowsGalleryZIP: false
        ))
    }

    func testDisclosureIsRequiredAndEmptyTitleFallsBackToTheActualPresentationFact() async throws {
        let model = makeFixtureModel(
            transport: RoomPublicationFixtureTransport(),
            confirmSensitiveAction: { true }
        )
        try await model.prepareReview()
        XCTAssertThrowsError(try model.approveReview()) { error in
            XCTAssertEqual(error as? RoomPublicationReviewError, .disclosureRequired)
        }

        var options = fixtureOptions()
        options.title = ""
        let roomInput = try RoomPublicationFixtureFactory.makeInput(
            options: options,
            includeWarning: false
        )
        guard case let .room(room) = roomInput.draft else {
            return XCTFail("Fixture must exercise a room presentation.")
        }
        XCTAssertEqual(room.title, "North room")
        options.mode = .property
        let propertyInput = try RoomPublicationFixtureFactory.makeInput(
            options: options,
            includeWarning: false
        )
        guard case let .property(property) = propertyInput.draft else {
            return XCTFail("Fixture must exercise a property presentation.")
        }
        XCTAssertEqual(property.propertyTitle, "Harbor property")
    }

    func testPINIsExactlySixASCIIDigitsAndIsClearedAfterADeclinedPublish() async throws {
        let transport = RoomPublicationFixtureTransport()
        let model = makeFixtureModel(
            transport: transport,
            confirmSensitiveAction: { false }
        )
        try await model.prepareReview()
        model.setDisclosureConfirmed(true)
        try model.approveReview()
        XCTAssertThrowsError(try model.setPIN("12345"))
        XCTAssertThrowsError(try model.setPIN("1234567"))
        XCTAssertThrowsError(try model.setPIN("12345６"))
        try model.setPIN("123456")
        XCTAssertTrue(model.debugRetainsEphemeralPIN)
        XCTAssertThrowsError(try model.setPIN("1234567"))
        XCTAssertFalse(model.debugRetainsEphemeralPIN, "An invalid seventh character must clear an earlier valid ephemeral PIN candidate.")
        try model.setPIN("123456")

        var controls = model.options.linkControls
        controls.requiresPIN = true
        model.updateLinkControls(controls)
        try await model.prepareReview()
        try model.approveReview()
        try model.setPIN("123456")
        try await model.publish()

        XCTAssertEqual(transport.reservationCount, 0, "A declined sensitive action must precede transport allocation.")
        XCTAssertFalse(model.debugRetainsEphemeralPIN, "PIN material must be cleared after every publish attempt.")
    }

    func testSensitiveConfirmationGatesPublishAndPortalLinkRevocation() async throws {
        let transport = RoomPublicationFixtureTransport()
        var allowsSensitiveAction = false
        let model = makeFixtureModel(
            transport: transport,
            confirmSensitiveAction: { allowsSensitiveAction }
        )
        try await model.prepareReview()
        model.setDisclosureConfirmed(true)
        try model.approveReview()

        try await model.publish()
        XCTAssertEqual(transport.reservationCount, 0)

        allowsSensitiveAction = true
        try await model.publish()
        XCTAssertEqual(transport.reservationCount, 1)
        XCTAssertEqual(model.portalLinkStatus?.lifecycle, .active)

        allowsSensitiveAction = false
        try await model.revokePortalLink()
        XCTAssertEqual(transport.revokeCount, 0, "A portal link revoke requires a fresh sensitive-action confirmation.")
        XCTAssertEqual(model.portalLinkStatus?.lifecycle, .active)
    }

    func testConcurrentPublishIsSingleFlightBeforeAnyDuplicateAllocation() async throws {
        let transport = RoomPublicationFixtureTransport()
        let gate = PublicationSensitiveActionGate()
        let model = makeFixtureModel(
            transport: transport,
            confirmSensitiveAction: { await gate.confirm() }
        )
        try await model.prepareReview()
        model.setDisclosureConfirmed(true)
        try model.approveReview()

        let first = Task { @MainActor () throws -> Void in
            try await model.publish()
        }
        await gate.waitForConfirmation()
        do {
            try await model.publish()
            XCTFail("A second publish cannot run while the first sensitive confirmation is pending.")
        } catch let error as RoomPublicationReviewError {
            XCTAssertEqual(error, .publicationInProgress)
        }
        await gate.allow()
        try await first.value
        XCTAssertEqual(transport.reservationCount, 1)
    }

    func testPublicationSanitizerStripsActualJPEGAPPMarkersBeforeCorePreparation() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
        let encoded = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        let appCarrier = jpegWithAPP0(encoded)
        XCTAssertTrue(RoomPublicationImageSanitizer.containsJPEGApplicationMarker(appCarrier), "Positive control: the probe sees injected APP0 bytes.")

        let sanitized = try RoomPublicationImageSanitizer.sanitize(
            appCarrier,
            declaredFilename: "fixture.jpg"
        )
        XCTAssertFalse(RoomPublicationImageSanitizer.containsJPEGApplicationMarker(sanitized.data))

        let options = fixtureOptions()
        let input = try RoomPublicationFixtureFactory.makeInput(
            options: options,
            includeWarning: false
        )
        let floorPlanID = try XCTUnwrap(input.draft.publicRooms().first?.assets.floorPlanAssetID)
        let assets = input.assets.map { asset -> RoomPublishedAssetInput in
            guard asset.assetID == floorPlanID else { return asset }
            return .raster(
                assetID: floorPlanID,
                publicRoomKey: try! XCTUnwrap(asset.publicRoomKey),
                assetClass: .floorPlan,
                raster: sanitized
            )
        }
        let prepared = try await RoomPublishedSnapshotBuilder.prepare(
            draft: input.draft,
            sourceBindings: input.sourceBindings,
            assets: assets
        )
        XCTAssertEqual(prepared.draft.kind, .room)
    }

    func testPublicPresentationExcludesPrivateSourceCanariesWithPositiveControl() async throws {
        let input = try RoomPublicationFixtureFactory.makeInput(
            options: fixtureOptions(),
            includeWarning: false
        )
        let controlData = try JSONEncoder().encode(input.sourceBindings)
        let controlText = try XCTUnwrap(String(data: controlData, encoding: .utf8))
        XCTAssertTrue(
            controlText.contains("private-project-canary"),
            "Positive control: the test fixture places the private ID in source-control bytes."
        )
        XCTAssertTrue(controlText.contains("private-revision-canary"))

        let prepared = try await RoomPublishedSnapshotBuilder.prepare(
            draft: input.draft,
            sourceBindings: input.sourceBindings,
            assets: input.assets
        )
        let presentation = try XCTUnwrap(String(data: prepared.presentationData, encoding: .utf8))
        XCTAssertFalse(presentation.contains("private-project-canary"))
        XCTAssertFalse(presentation.contains("private-revision-canary"))
        XCTAssertFalse(presentation.contains("private-epoch-canary"))
        XCTAssertEqual(input.draft.orderedRoomKeys, ["room-001"])
        XCTAssertFalse(presentation.contains("room-private"))
    }

    func testFreshPublicRoomKeysAndGeometryUseRoomLocalProjectionBounds() {
        XCTAssertEqual(RoomPublicationInputFactory.publicRoomKey(ordinal: 1), "room-001")
        XCTAssertEqual(RoomPublicationInputFactory.publicRoomKey(ordinal: 12), "room-012")

        let projection = RoomFloorPlanProjection(
            items: [],
            bounds: .init(
                minimum: .init(x: -2.5, y: 4.0),
                maximum: .init(x: 7.25, y: 10.75)
            )
        )
        let geometry = RoomPublicationInputFactory.roomLocalFloorGeometry(from: projection)

        XCTAssertEqual(geometry.vertices.map(\.x).min(), -2.5)
        XCTAssertEqual(geometry.vertices.map(\.x).max(), 7.25)
        XCTAssertEqual(geometry.vertices.map(\.z).min(), 4.0)
        XCTAssertEqual(geometry.vertices.map(\.z).max(), 10.75)
        XCTAssertNotEqual(geometry.vertices.map(\.x).max(), 1, "The portal must not substitute a unit-square room for a measured local projection.")
    }

    func testControlledClockBoundsExpiryAndDefaultBrandingRemainOwnerIncomplete() {
        let fixedNow = Date(timeIntervalSince1970: 1_786_896_000)
        let model = RoomPublicationReviewModel(
            options: .default(now: fixedNow),
            inputProvider: { options in
                try RoomPublicationFixtureFactory.makeInput(options: options, includeWarning: false)
            },
            service: RoomPublicationService.fixture(transport: RoomPublicationFixtureTransport()),
            confirmSensitiveAction: { true },
            now: { fixedNow }
        )
        XCTAssertFalse(model.isBrandingComplete)
        model.setLinkExpiry(fixedNow.addingTimeInterval(9_999 * 24 * 60 * 60))
        XCTAssertEqual(model.options.linkControls.expiresAt, model.maximumLinkExpiry)
        model.setLinkExpiry(fixedNow)
        XCTAssertEqual(model.options.linkControls.expiresAt, model.minimumLinkExpiry)
    }

    func testSourceRevisionChangeIsRejectedBeforeSensitivePublishTransport() async throws {
        let transport = RoomPublicationFixtureTransport()
        var revisionChanged = false
        let model = RoomPublicationReviewModel(
            options: fixtureOptions(),
            inputProvider: { options in
                var input = try RoomPublicationFixtureFactory.makeInput(
                    options: options,
                    includeWarning: false
                )
                guard revisionChanged else { return input }
                var changed = input.sourceBindings[0].sourceRevision
                changed.revisionID = "private-revision-canary-changed"
                input = .init(
                    journalAnchorProjectID: input.journalAnchorProjectID,
                    draft: input.draft,
                    sourceBindings: [.init(
                        publicRoomKey: input.sourceBindings[0].publicRoomKey,
                        sourceRevision: changed
                    )],
                    hostedSourceBindings: [.init(
                        publicRoomKey: input.hostedSourceBindings[0].publicRoomKey,
                        projectPublicID: input.hostedSourceBindings[0].projectPublicID,
                        revisionPublicID: input.hostedSourceBindings[0].revisionPublicID,
                        sourceRevision: changed
                    )],
                    propertyCuration: nil,
                    assets: input.assets,
                    rasterChoices: input.rasterChoices,
                    conceptChoices: input.conceptChoices,
                    aiReadyPackageChoices: input.aiReadyPackageChoices,
                    qualityWarnings: input.qualityWarnings
                )
                return input
            },
            service: RoomPublicationService.fixture(transport: transport),
            confirmSensitiveAction: { true },
            now: { Date(timeIntervalSince1970: 1_786_896_000) },
            reviewID: { "publication-review-source-test" }
        )
        try await model.prepareReview()
        model.setDisclosureConfirmed(true)
        try model.approveReview()
        revisionChanged = true

        do {
            try await model.publish()
            XCTFail("A changed source revision must invalidate approval before publish.")
        } catch let error as RoomPublicationReviewError {
            XCTAssertEqual(error, .staleReview)
        }
        XCTAssertEqual(transport.reservationCount, 0)
        XCTAssertNil(model.approval)
    }

    func testLinkFailureRetainsSnapshotAndRetrySkipsSecondAllocation() async throws {
        let transport = RoomPublicationFixtureTransport(failuresBeforeLinkSuccess: 1)
        let model = makeFixtureModel(transport: transport, confirmSensitiveAction: { true })
        try await model.prepareReview()
        model.setDisclosureConfirmed(true)
        try model.approveReview()

        do {
            try await model.publish()
            XCTFail("The deterministic first link request should fail after snapshot completion.")
        } catch let error as RoomPublicationTransportError {
            XCTAssertEqual(error, .unavailable)
        }
        XCTAssertEqual(transport.reservationCount, 1)
        XCTAssertEqual(transport.linkRequestCount, 1)
        XCTAssertEqual(model.remoteStatus?.snapshotID, "snp_fixturepublication0001", "Snapshot status must be retained before link creation.")
        XCTAssertEqual(model.reviewState, .linkPending)

        try await model.publish()
        XCTAssertEqual(transport.reservationCount, 1, "Retry must resume the retained snapshot, not allocate another archive.")
        XCTAssertEqual(transport.linkRequestCount, 2)
        XCTAssertEqual(model.reviewState, .published)
    }

    func testChangedPreparedSelectionAfterLinkFailureCannotReuseStaleSnapshot() async throws {
        let transport = RoomPublicationFixtureTransport(failuresBeforeLinkSuccess: 1)
        let model = makeFixtureModel(transport: transport, confirmSensitiveAction: { true })
        try await model.prepareReview()
        model.setDisclosureConfirmed(true)
        try model.approveReview()
        do { try await model.publish() } catch { /* expected link failure */ }
        XCTAssertEqual(transport.reservationCount, 1)
        XCTAssertNotNil(model.pendingPortalLink)

        var branding = model.options.branding
        branding.businessName = "Test studio revised"
        model.updateBranding(branding)
        try await model.prepareReview()
        try model.approveReview()
        try await model.publish()
        XCTAssertEqual(transport.reservationCount, 2, "A changed selection manifest must allocate a new immutable snapshot rather than linking stale content.")
        XCTAssertEqual(model.reviewState, .published)
    }

    func testReviewedRasterCatalogBindsPublicAssetIDsToPreparedLedgerAndSurvivesExclusion() async throws {
        var options = fixtureOptions()
        options.selectedConceptIDs = ["approved-concept-a"]
        let model = RoomPublicationReviewModel(
            options: options,
            inputProvider: { options in
                try RoomPublicationFixtureFactory.makeInput(options: options, includeWarning: false)
            },
            service: RoomPublicationService.fixture(transport: RoomPublicationFixtureTransport()),
            confirmSensitiveAction: { true },
            now: { Date(timeIntervalSince1970: 1_786_896_000) },
            reviewID: { "publication-raster-review" }
        )
        try await model.prepareReview()
        let rasterClasses = model.reviewedRasters.map(\.assetClass)
        XCTAssertTrue(rasterClasses.contains(.floorPlan))
        XCTAssertTrue(rasterClasses.contains(.selectedImage))
        XCTAssertTrue(rasterClasses.contains(.approvedConcept))
        let selected = try XCTUnwrap(model.reviewedRasters.first { $0.assetClass == .selectedImage })
        let preparedLedger = try XCTUnwrap(model.preparation?.preparedAssets.first {
            $0.ledger.assetID == selected.assetID
        }?.ledger)
        XCTAssertEqual(selected.sealedSHA256, preparedLedger.sha256)
        XCTAssertEqual(selected.sealedByteCount, preparedLedger.byteCount)
        XCTAssertFalse(selected.data.isEmpty, "Positive control: the native review really has bounded pixel data to render.")

        model.setDisclosureConfirmed(true)
        try model.approveReview()
        model.setRasterIncluded(selected.assetID, included: false)
        XCTAssertNil(model.approval)
        XCTAssertEqual(model.reviewState, .approvalInvalidated)
        try await model.prepareReview()
        let excluded = try XCTUnwrap(model.reviewedRasters.first { $0.assetID == selected.assetID })
        XCTAssertFalse(excluded.isIncluded, "The catalog retains an excluded candidate so it can be re-included without private lookup.")
        XCTAssertFalse(model.input?.assets.contains(where: { $0.assetID == selected.assetID }) == true)
        XCTAssertFalse(model.input?.assets.contains(where: { $0.assetClass == .approvedConcept }) == true, "Concept bytes must not remain as unreferenced working material when original comparison evidence is excluded.")
    }

    func testAIReadyPortalDownloadFailsClosedWithoutAnExactPublishedAsset() async throws {
        let transport = RoomPublicationFixtureTransport()
        let service = RoomPublicationService.fixture(transport: transport)
        var controls = RoomPublicationLinkControls.default(
            now: Date(timeIntervalSince1970: 1_786_896_000)
        )
        controls.allowsAIReadyPackageDownload = true

        do {
            _ = try await service.createPortalLink(
                snapshotID: "snp_fixturepublication0001",
                linkControls: controls,
                aiReadyEntitlement: nil,
                pin: nil,
                operationID: "publication-ai-ready-test"
            )
            XCTFail("No AI-ready portal entitlement is valid without a matching sealed package asset.")
        } catch let error as RoomPublicationServiceError {
            XCTAssertEqual(error, .aiReadyPackageUnavailable)
        }
        XCTAssertEqual(transport.reservationCount, 0)
    }

    func testAIReadySnapshotSelectionIsPublicRoomScopedAndInvalidatesApproval() async throws {
        let model = RoomPublicationReviewModel(
            options: fixtureOptions(),
            inputProvider: { options in
                let input = try RoomPublicationFixtureFactory.makeInput(
                    options: options,
                    includeWarning: false
                )
                return .init(
                    journalAnchorProjectID: input.journalAnchorProjectID,
                    draft: input.draft,
                    sourceBindings: input.sourceBindings,
                    hostedSourceBindings: input.hostedSourceBindings,
                    propertyCuration: input.propertyCuration,
                    assets: input.assets,
                    rasterChoices: input.rasterChoices,
                    conceptChoices: input.conceptChoices,
                    aiReadyPackageChoices: [.init(
                        publicRoomKey: "room-001",
                        label: "Validated AI-ready package for North room"
                    )],
                    qualityWarnings: input.qualityWarnings
                )
            },
            service: RoomPublicationService.fixture(transport: RoomPublicationFixtureTransport()),
            confirmSensitiveAction: { true },
            now: { Date(timeIntervalSince1970: 1_786_896_000) },
            reviewID: { "publication-ai-selection-review" }
        )
        try await model.prepareReview()
        model.setDisclosureConfirmed(true)
        try model.approveReview()

        model.setSelectedAIReadyPackageRoomKey("room-001")
        XCTAssertEqual(model.options.selectedAIReadyPackageRoomKey, "room-001")
        XCTAssertNil(model.approval)
        XCTAssertEqual(model.reviewState, .approvalInvalidated)

        model.setSelectedAIReadyPackageRoomKey("room-private")
        XCTAssertNil(model.options.selectedAIReadyPackageRoomKey)
    }

    func testAIReadyPortalDownloadEnablesOnlyFromARealCorePreparedPackage() async throws {
        let fixture = try await fixtureAIReadyReviewInput()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let preparation = fixture.preparation
        let entitlement = try XCTUnwrap(
            RoomPublicationAIReadyLinkEntitlement(preparation: preparation),
            "Positive control: the real Core fixture carries one validated AI-ready ledger binding."
        )
        let transport = RoomPublicationFixtureTransport()
        let service = RoomPublicationService.fixture(transport: transport)
        let rebuilt = try await service.prepare(fixture.input)
        XCTAssertEqual(
            rebuilt.draft.downloads.aiReadyPackageAssetID,
            entitlement.assetID,
            "Positive control: the actual Core-validated package is sealed into the same snapshot intent that reaches allocation."
        )
        let approval = rebuilt.makeApproval(
            reviewID: "publication-ai-ready-enabled-test-review",
            reviewedAt: Date(timeIntervalSince1970: 1_786_896_000)
        )
        let allocation = try await service.publishSnapshot(
            input: fixture.input,
            preparation: rebuilt,
            approval: approval,
            operationID: "publication-ai-ready-enabled-test"
        )
        let snapshotID = try XCTUnwrap(allocation.snapshotID)
        var controls = RoomPublicationLinkControls.default(
            now: Date(timeIntervalSince1970: 1_786_896_000)
        )
        controls.allowsAIReadyPackageDownload = true

        let link = try await service.createPortalLink(
            snapshotID: snapshotID,
            linkControls: controls,
            aiReadyEntitlement: entitlement,
            pin: nil,
            operationID: "publication-ai-ready-enabled-test"
        )

        XCTAssertEqual(link.lifecycle, .active)
        XCTAssertEqual(transport.linkRequestCount, 1)
    }

    func testProductionAIReadySelectionIncludesOnlyAnExactValidatedArchive() async throws {
        let fixture = try await fixtureAIReadyPublicationCandidate()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let selected = await RoomPublicationInputFactory.selectedAIReadyPackage(
            selectedPublicRoomKey: fixture.sourceBinding.publicRoomKey,
            candidate: fixture.candidate,
            sourceBinding: fixture.sourceBinding
        )
        let selectedAsset = try XCTUnwrap(selected?.asset)
        XCTAssertEqual(selectedAsset.assetClass, .aiReadyPackage)
        XCTAssertEqual(selected?.assetID, selectedAsset.assetID)
        let downloads = RoomPublicationInputFactory.publicDownloadPolicy(
            staticDownloads: .none,
            aiReadySelection: selected
        )
        XCTAssertEqual(downloads.aiReadyPackageAssetID, selectedAsset.assetID)

        var wrongSource = fixture.candidate.sourceRevision
        wrongSource.revisionID = "private-revision-mismatch"
        let sourceMismatched = RoomPublicationAIReadyPackageCandidate(
            archiveURL: fixture.candidate.archiveURL,
            sourceRevision: wrongSource,
            expectedPackageID: fixture.candidate.expectedPackageID
        )
        let omitted = await RoomPublicationInputFactory.selectedAIReadyPackage(
            selectedPublicRoomKey: fixture.sourceBinding.publicRoomKey,
            candidate: sourceMismatched,
            sourceBinding: fixture.sourceBinding
        )
        XCTAssertNil(omitted, "A candidate with a source mismatch must be omitted before it can enter the public snapshot closure.")
        XCTAssertNil(
            RoomPublicationInputFactory.publicDownloadPolicy(
                staticDownloads: .none,
                aiReadySelection: omitted
            ).aiReadyPackageAssetID
        )
    }

    func testAIReadyProvenanceBackfillsLegacyBindingAndRejectsMismatchedSidecar() async throws {
        let fixture = try await fixtureAIReadyPublicationCandidate()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let archive = try await aiReadyArchiveResult(from: fixture.candidate)
        let provenanceRoot = fixture.root.appendingPathComponent("provenance", isDirectory: true)
        let sourceRoot = fixture.root.appendingPathComponent("private-source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let registry = RoomAIConceptPackageProvenanceRegistry(
            rootURL: provenanceRoot,
            sourcePackageRootURL: sourceRoot
        )

        // Positive control for a pre-Slice-6 canonical binding: it has the
        // exact validated manifest but no retained archive sidecar yet.
        try registry.installCanonical(.init(
            sourceRevision: fixture.sourceBinding.sourceRevision,
            canonicalManifestData: archive.manifestData
        ))
        let beforeBackfill = await registry.publicationAIReadyPackageCandidate(
            for: fixture.sourceBinding.sourceRevision
        )
        XCTAssertNil(beforeBackfill)

        _ = try registry.record(
            archive,
            expectedSourceRevision: fixture.sourceBinding.sourceRevision,
            currentCanonicalCameraIDs: try RoomConceptValidatedSourcePackage(
                validatedManifestData: archive.manifestData
            ).canonicalCameraIDs
        )
        let backfilled = await registry.publicationAIReadyPackageCandidate(
            for: fixture.sourceBinding.sourceRevision
        )
        XCTAssertEqual(backfilled?.expectedPackageID, fixture.candidate.expectedPackageID)

        var mismatchedReceipt = archive
        mismatchedReceipt.receipt.archiveSHA256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try registry.record(
            mismatchedReceipt,
            expectedSourceRevision: fixture.sourceBinding.sourceRevision,
            currentCanonicalCameraIDs: try RoomConceptValidatedSourcePackage(
                validatedManifestData: archive.manifestData
            ).canonicalCameraIDs
        ))
    }

    func testAIReadyProvenanceCopyFailureLeavesNoBindingAndExactRetryRepairsIt() async throws {
        let fixture = try await fixtureAIReadyPublicationCandidate()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let archive = try await aiReadyArchiveResult(from: fixture.candidate)
        let provenanceRoot = fixture.root.appendingPathComponent("retry-provenance", isDirectory: true)
        let sourceRoot = fixture.root.appendingPathComponent("retry-private-source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        var copyAttempts = 0
        let registry = RoomAIConceptPackageProvenanceRegistry(
            rootURL: provenanceRoot,
            sourcePackageRootURL: sourceRoot,
            copyAIReadyArchive: { source, destination in
                copyAttempts += 1
                if copyAttempts == 1 {
                    throw CocoaError(.fileWriteUnknown)
                }
                try FileManager.default.copyItem(at: source, to: destination)
            }
        )
        let cameraIDs = try RoomConceptValidatedSourcePackage(
            validatedManifestData: archive.manifestData
        ).canonicalCameraIDs

        XCTAssertThrowsError(try registry.record(
            archive,
            expectedSourceRevision: fixture.sourceBinding.sourceRevision,
            currentCanonicalCameraIDs: cameraIDs
        ))
        XCTAssertEqual(
            try registry.bindings(for: fixture.sourceBinding.sourceRevision),
            [],
            "A failed sidecar copy must not permanently commit a provenance binding that blocks a safe retry."
        )
        let afterFailedCopy = await registry.publicationAIReadyPackageCandidate(
            for: fixture.sourceBinding.sourceRevision
        )
        XCTAssertNil(afterFailedCopy)

        _ = try registry.record(
            archive,
            expectedSourceRevision: fixture.sourceBinding.sourceRevision,
            currentCanonicalCameraIDs: cameraIDs
        )
        XCTAssertEqual(copyAttempts, 2)
        let afterRetry = await registry.publicationAIReadyPackageCandidate(
            for: fixture.sourceBinding.sourceRevision
        )
        XCTAssertNotNil(afterRetry)
    }

    func testAIReadyProvenanceRecordWriteFailureRemovesOnlyNewSidecarForRetry() async throws {
        let fixture = try await fixtureAIReadyPublicationCandidate()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let archive = try await aiReadyArchiveResult(from: fixture.candidate)
        let provenanceRoot = fixture.root.appendingPathComponent("record-retry-provenance", isDirectory: true)
        let sourceRoot = fixture.root.appendingPathComponent("record-retry-private-source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        var writeAttempts = 0
        let registry = RoomAIConceptPackageProvenanceRegistry(
            rootURL: provenanceRoot,
            sourcePackageRootURL: sourceRoot,
            beforeRecordWrite: { _, _ in
                writeAttempts += 1
                if writeAttempts == 1 {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        )
        let cameraIDs = try RoomConceptValidatedSourcePackage(
            validatedManifestData: archive.manifestData
        ).canonicalCameraIDs

        XCTAssertThrowsError(try registry.record(
            archive,
            expectedSourceRevision: fixture.sourceBinding.sourceRevision,
            currentCanonicalCameraIDs: cameraIDs
        ))
        XCTAssertEqual(
            try registry.bindings(for: fixture.sourceBinding.sourceRevision),
            [],
            "A record-write failure must not leave an authority binding."
        )
        let afterWriteFailure = await registry.publicationAIReadyPackageCandidate(
            for: fixture.sourceBinding.sourceRevision
        )
        XCTAssertNil(afterWriteFailure, "The invocation-owned sidecar must be removed before a fresh package identity can be minted.")

        _ = try registry.record(
            archive,
            expectedSourceRevision: fixture.sourceBinding.sourceRevision,
            currentCanonicalCameraIDs: cameraIDs
        )
        XCTAssertEqual(writeAttempts, 2)
        let afterRetry = await registry.publicationAIReadyPackageCandidate(
            for: fixture.sourceBinding.sourceRevision
        )
        XCTAssertNotNil(afterRetry)
    }

    func testConfiguredTransportUsesTypedHTTPSRoutesAndKeepsSignedUploadPrivate() async throws {
        let now = Date(timeIntervalSince1970: 1_786_896_000)
        let executor = PublicationHTTPSExecutorSpy(responses: [
            .init(statusCode: 201, data: responseData([
                "status": "allocated",
                "allocationID": "pua_0000000000000001",
                "allocationExpiresAt": iso8601(now.addingTimeInterval(60)),
                "upload": [
                    "url": "https://objects.example.invalid/published/archive?signature=secret",
                    "headers": ["x-roomscan-upload": "scoped"]
                ]
            ])),
            .init(statusCode: 200, data: responseData([
                "status": "validation_pending",
                "allocationID": "pua_0000000000000001"
            ])),
            .init(statusCode: 201, data: responseData([
                "status": "created",
                "linkID": "lnk_0000000000000001",
                "generation": 1,
                "expiresAt": iso8601(now.addingTimeInterval(30 * 24 * 60 * 60)),
                "pinRequired": true
            ]))
        ])
        let transport = try FoundationRoomPublicationTransport(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.invalid/v1/")),
            authorization: { "Bearer \(String(repeating: "n", count: 32))" },
            executor: executor,
            now: { now }
        )
        let digest = String(repeating: "a", count: 64)
        let request = makeAllocationRequest(digest: digest, idempotencyKey: "publication-test-001")
        let allocation = try await transport.allocatePublication(request)
        XCTAssertEqual(allocation.allocationID, "pua_0000000000000001")
        XCTAssertEqual(executor.requests.count, 1)
        XCTAssertEqual(executor.requests[0].url.path, "/v1/publications/snapshots/allocate")
        XCTAssertEqual(executor.requests[0].headers["Authorization"], "Bearer \(String(repeating: "n", count: 32))")
        XCTAssertNil(executor.requests[0].headers["Cookie"])
        XCTAssertNil(executor.requests[0].headers["X-RoomScan-CSRF"])
        let allocationBody = try XCTUnwrap(executor.jsonBody(at: 0))
        XCTAssertEqual(allocationBody["archiveSHA256"] as? String, digest)
        XCTAssertNil(allocationBody["pin"])

        try await transport.uploadPublicationArchive(.init(
            archiveURL: URL(fileURLWithPath: "/private/tmp/publication-test.zip"),
            archiveSHA256: digest,
            archiveManifestSHA256: digest,
            byteCount: 42
        ), allocation: allocation)
        XCTAssertEqual(executor.uploads.count, 1)
        XCTAssertEqual(executor.uploads[0].url.host, "objects.example.invalid")
        XCTAssertNil(executor.uploads[0].headers["Authorization"], "Account auth must never cross a presigned upload request.")
        XCTAssertNil(executor.uploads[0].headers["Cookie"])

        let complete = try await transport.completePublication(
            allocationID: allocation.allocationID,
            archiveSHA256: digest,
            archiveManifestSHA256: digest,
            archiveByteCount: 42
        )
        XCTAssertEqual(complete.disposition, .validationPending)
        let link = try await transport.createPortalLink(
            snapshotID: "snp_0000000000000001",
            request: .init(
                idempotencyKey: "publication-link-test-001",
                expiresAt: now.addingTimeInterval(30 * 24 * 60 * 60),
                pinCandidate: "123456",
                aiPolicy: .disabled,
                feedbackPolicy: .enabled
            )
        )
        XCTAssertEqual(link.lifecycle, .active)
        XCTAssertEqual(executor.requests.map(\.url.path), [
            "/v1/publications/snapshots/allocate",
            "/v1/publications/snapshots/complete",
            "/v1/publications/links/create"
        ])
        let linkBody = try XCTUnwrap(executor.jsonBody(at: 2))
        XCTAssertEqual(linkBody["pin"] as? String, "123456", "The ephemeral PIN crosses only the configured TLS link-create route.")
    }

    func testConfiguredTransportRejectsUnknownDTOKeysAfterReachingTheRoute() async throws {
        let now = Date(timeIntervalSince1970: 1_786_896_000)
        let executor = PublicationHTTPSExecutorSpy(responses: [
            .init(statusCode: 201, data: responseData([
                "status": "allocated",
                "allocationID": "pua_0000000000000001",
                "allocationExpiresAt": iso8601(now.addingTimeInterval(60)),
                "upload": [
                    "url": "https://objects.example.invalid/published/archive?signature=secret",
                    "headers": ["x-roomscan-upload": "scoped"]
                ],
                "unexpected": "canary"
            ]))
        ])
        let transport = try FoundationRoomPublicationTransport(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.invalid/")),
            authorization: { "Bearer \(String(repeating: "t", count: 32))" },
            executor: executor,
            now: { now }
        )
        let digest = String(repeating: "b", count: 64)

        do {
            _ = try await transport.allocatePublication(
                makeAllocationRequest(digest: digest, idempotencyKey: "publication-test-002")
            )
            XCTFail("Unknown response fields must fail closed.")
        } catch let error as RoomPublicationTransportError {
            XCTAssertEqual(error, .invalidResponse)
        }
        XCTAssertEqual(executor.requests.count, 1, "Positive control: the malformed DTO came from the live typed route path.")
    }

    func testConfiguredTransportRejectsShortNativeBearerBeforeTheFirstPartyRoute() async throws {
        let executor = PublicationHTTPSExecutorSpy(responses: [])
        let transport = try FoundationRoomPublicationTransport(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.invalid/")),
            authorization: { "Bearer too-short" },
            executor: executor,
            now: { Date(timeIntervalSince1970: 1_786_896_000) }
        )

        do {
            _ = try await transport.allocatePublication(
                makeAllocationRequest(
                    digest: String(repeating: "c", count: 64),
                    idempotencyKey: "publication-short-bearer-001"
                )
            )
            XCTFail("Native publication must not send a short bearer token.")
        } catch let error as RoomPublicationTransportError {
            XCTAssertEqual(error, .unavailable)
        }
        XCTAssertTrue(executor.requests.isEmpty, "Positive control: rejection happens before any first-party request can serialize the token.")
    }

    func testConfiguredTransportUsesStatusDependentPortalLinkRevokeGeneration() async throws {
        let executor = PublicationHTTPSExecutorSpy(responses: [
            .init(statusCode: 200, data: responseData([
                "status": "revoked",
                "linkID": "lnk_0000000000000101",
                "generation": 2
            ])),
            .init(statusCode: 200, data: responseData([
                "status": "already_revoked",
                "linkID": "lnk_0000000000000101",
                "generation": 2
            ]))
        ])
        let transport = try FoundationRoomPublicationTransport(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.invalid/")),
            authorization: { "Bearer \(String(repeating: "r", count: 32))" },
            executor: executor,
            now: { Date(timeIntervalSince1970: 1_786_896_000) }
        )

        let first = try await transport.revokePortalLink(
            linkID: "lnk_0000000000000101",
            expectedGeneration: 1
        )
        XCTAssertEqual(first.generation, 2)
        XCTAssertEqual(first.disposition, "revoked")
        let retry = try await transport.revokePortalLink(
            linkID: "lnk_0000000000000101",
            expectedGeneration: 2
        )
        XCTAssertEqual(retry.generation, 2)
        XCTAssertEqual(retry.disposition, "already_revoked")
        XCTAssertEqual(executor.requests.map(\.url.path), [
            "/publications/links/revoke",
            "/publications/links/revoke"
        ])
    }

    func testGuestLaunchAndLocalFeatureCompositionDoNotConstructPublicationService() {
        let factory = ProfessionalEnvironmentFactory.defaultOff()
        let environment = AppEnvironment(
            arguments: ["--ui-testing", "--use-mock-fixture"],
            professionalEnvironmentFactory: factory
        )

        // The regular local library/export/AI composition is present, but it
        // cannot create a publication service or a hosted client on launch.
        XCTAssertNotNil(environment.libraryController)
        XCTAssertNotNil(environment.exportCoordinator)
        XCTAssertNotNil(environment.aiRedesignModelFactory)
        XCTAssertFalse(factory.hasConstructedEnvironment)
        XCTAssertFalse(factory.hasConstructedPublicationService)
    }

    func testConfiguredProfessionalPublicationServiceConstructsOnlyAfterEntrySignInAndUnlock() async throws {
        let construction = PublicationServiceConstructionCounter()
        let factory = ProfessionalEnvironmentFactory(
            localConfiguration: .enabled,
            makeEnvironment: {
                ProfessionalEnvironment(
                    availabilityClient: PublicationAvailabilityClient(),
                    sessionClient: PublicationSessionClient(),
                    deviceAuthentication: DeviceAuthenticationCoordinator(
                        contextFactory: PublicationAuthenticationContextFactory(),
                        now: { Date(timeIntervalSince1970: 1_786_896_000) }
                    ),
                    makePublicationService: { _, _ in
                        construction.count += 1
                        return RoomPublicationService.fixture(
                            transport: RoomPublicationFixtureTransport()
                        )
                    }
                )
            }
        )
        _ = AppEnvironment(
            arguments: ["--ui-testing", "--use-mock-fixture"],
            professionalEnvironmentFactory: factory
        )
        XCTAssertFalse(factory.hasConstructedPublicationService)
        do {
            _ = try await factory.makePublicationReviewModel(projectID: "local-project")
            XCTFail("Publication review must not construct before entry/sign-in/unlock.")
        } catch {
            XCTAssertEqual(error as? RoomPublicationTransportError, .unavailable)
        }
        XCTAssertEqual(construction.count, 0)

        await factory.enterProfessionalWorkspace()
        guard case .success = await factory.requestLocalUnlock() else {
            return XCTFail("The deterministic test authenticator should unlock the configured workspace.")
        }
        let signInResult = await factory.beginSignIn()
        XCTAssertEqual(signInResult, .started)
        _ = try await factory.makePublicationReviewModel(projectID: "local-project")
        _ = try await factory.makePublicationReviewModel(projectID: "local-project")
        XCTAssertTrue(factory.hasConstructedPublicationService)
        XCTAssertEqual(construction.count, 1, "The lazy configured builder must be memoized after explicit entry/sign-in/unlock.")
    }

    // MARK: - Slice 6 reconciliation RED contract

    /// The public `prj_`/`rev_` identity must come from the acknowledged Slice
    /// 5 journal entry, never from the local Core identifiers. This starts red
    /// against the pre-reconciliation implementation, which has no resolver.
    func testPublicationIdentityRequiresAnAcknowledgedCanonicalJournalHead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "publication-identity-red-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try ProfessionalProjectSyncJournal(rootURL: root)
        let source = RoomRedesignSourceRevision(
            projectID: "local-project-001",
            revisionID: "local-revision-001",
            coordinateSpaceEpochID: "epoch-001",
            packageSchemaVersion: "room-scan-project-v2",
            semanticSHA256: String(repeating: "a", count: 64),
            revisionManifestSHA256: String(repeating: "b", count: 64)
        )
        try journal.replace(.init(
            localProjectID: source.projectID,
            hostedProjectID: "prj_0000000000000001",
            acknowledgedLocalHeadRevisionID: source.revisionID,
            acknowledgedHostedHeadRevisionID: "rev_0000000000000001",
            status: .canonical,
            currentHostedHeadRevisionID: "rev_0000000000000001",
            canonicalRevisionID: "rev_0000000000000001"
        ))

        let resolver = PublicationSourceIdentityResolver(
            journal: journal,
            currentSource: { _ in source }
        )
        let identity = try await resolver.resolve(
            localProjectID: source.projectID,
            expectedSourceRevision: source
        )
        XCTAssertEqual(identity.projectPublicID, "prj_0000000000000001")
        XCTAssertEqual(identity.revisionPublicID, "rev_0000000000000001")
        XCTAssertEqual(identity.sourceRevision, source)
    }

    func testPublicationIdentityRejectsMissingDivergedAndStaleJournalHeads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "publication-identity-negative-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try ProfessionalProjectSyncJournal(rootURL: root)
        let source = RoomRedesignSourceRevision(
            projectID: "local-project-identity",
            revisionID: "local-revision-identity",
            coordinateSpaceEpochID: "epoch-identity",
            packageSchemaVersion: "room-scan-project-v2",
            semanticSHA256: String(repeating: "a", count: 64),
            revisionManifestSHA256: String(repeating: "b", count: 64)
        )
        let resolver = PublicationSourceIdentityResolver(
            journal: journal,
            currentSource: { _ in source }
        )

        do {
            _ = try await resolver.resolve(
                localProjectID: source.projectID,
                expectedSourceRevision: source
            )
            XCTFail("A missing Slice 5 acknowledgement cannot mint hosted publication identity.")
        } catch let error as RoomPublicationSourceIdentityError {
            XCTAssertEqual(error, .journalNotAcknowledged)
        }

        try journal.replace(canonicalJournalRecord(
            source: source,
            hostedProjectID: "prj_0000000000000101",
            hostedRevisionID: "rev_0000000000000101"
        ))
        var diverged = source
        diverged.revisionID = "local-revision-diverged"
        let divergedResolver = PublicationSourceIdentityResolver(
            journal: journal,
            currentSource: { _ in diverged }
        )
        do {
            _ = try await divergedResolver.resolve(
                localProjectID: source.projectID,
                expectedSourceRevision: source
            )
            XCTFail("A current local head mismatch must not reuse an acknowledged rev_.")
        } catch let error as RoomPublicationSourceIdentityError {
            XCTAssertEqual(error, .localHeadDiverged)
        }

        var stale = canonicalJournalRecord(
            source: source,
            hostedProjectID: "prj_0000000000000101",
            hostedRevisionID: "rev_0000000000000101"
        )
        stale.currentHostedHeadRevisionID = "rev_0000000000000102"
        try journal.replace(stale)
        do {
            _ = try await resolver.resolve(
                localProjectID: source.projectID,
                expectedSourceRevision: source
            )
            XCTFail("A stale hosted journal head cannot authorize publication.")
        } catch let error as RoomPublicationSourceIdentityError {
            XCTAssertEqual(error, .journalNotAcknowledged)
        }
    }

    func testLiteralPreSlice6ProfessionalJournalBytesDecodeAndRemainUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "slice5-literal-journal-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let localProjectID = "legacy-local-project-001"
        let localRevisionID = "legacy-local-revision-001"
        let journal = try ProfessionalProjectSyncJournal(rootURL: root)
        // This is a literal canonical v1 record created before Slice 6. The
        // additive publication sidecar must not add keys or rewrite it.
        let legacyBytes = Data(#"{"acknowledgedHostedHeadRevisionID":"rev_0000000000000001","acknowledgedLocalHeadRevisionID":"legacy-local-revision-001","canonicalRevisionID":"rev_0000000000000001","currentHostedHeadRevisionID":"rev_0000000000000001","hostedProjectID":"prj_0000000000000001","localProjectID":"legacy-local-project-001","recoveryPhase":"none","schemaVersion":"roomscan-professional-project-sync-journal-v1","status":"canonical"}"#.utf8)
        let recordURL = root
            .appendingPathComponent("records", isDirectory: true)
            .appendingPathComponent("\(localProjectID).json")
        try legacyBytes.write(to: recordURL, options: [.withoutOverwriting])

        let source = RoomRedesignSourceRevision(
            projectID: localProjectID,
            revisionID: localRevisionID,
            coordinateSpaceEpochID: "legacy-epoch-001",
            packageSchemaVersion: RoomProjectSchemaVersion.v2.rawValue,
            semanticSHA256: String(repeating: "a", count: 64),
            revisionManifestSHA256: String(repeating: "b", count: 64)
        )
        let resolver = PublicationSourceIdentityResolver(
            journal: journal,
            currentSource: { requestedProjectID in
                XCTAssertEqual(requestedProjectID, localProjectID)
                return source
            }
        )

        let decoded = try XCTUnwrap(try journal.load(localProjectID: localProjectID))
        XCTAssertEqual(decoded.acknowledgedLocalHeadRevisionID, localRevisionID)
        let identity = try await resolver.resolve(
            localProjectID: localProjectID,
            expectedSourceRevision: source
        )
        XCTAssertEqual(identity.projectPublicID, "prj_0000000000000001")
        XCTAssertEqual(identity.revisionPublicID, "rev_0000000000000001")
        XCTAssertEqual(
            try Data(contentsOf: recordURL),
            legacyBytes,
            "Positive control: resolving a real literal Slice 5 record does not rewrite its bytes."
        )

        _ = try PublicationOperationJournal(
            rootURL: root.appendingPathComponent("PublicationOperationJournal", isDirectory: true)
        )
        XCTAssertEqual(
            try Data(contentsOf: recordURL),
            legacyBytes,
            "The separate Slice 6 journal remains a sibling and cannot mutate frozen Slice 5 recovery bytes."
        )
    }

    func testJournaledPendingAllocationRequiresExactServerTTLAndReconcilesAfterExpiry() async throws {
        let now = Date(timeIntervalSince1970: 1_786_896_000)
        let context = try makeJournalPublicationContext(now: now)
        let preparation = try await context.service.prepare(context.input)
        let approval = preparation.makeApproval(
            reviewID: "publication-pending-ttl-review",
            reviewedAt: now
        )
        let operationID = "publication-pending-ttl-001"

        do {
            _ = try await context.service.publishSnapshot(
                input: context.input,
                preparation: preparation,
                approval: approval,
                operationID: operationID
            )
            XCTFail("The fixture must leave a pua_ record after its ambiguous completion failure.")
        } catch let error as RoomPublicationTransportError {
            XCTAssertEqual(error, .unavailable)
        }
        let pending = try XCTUnwrap(
            try context.operationJournal.load(operationID: operationID)
        )
        let allocation = try XCTUnwrap(pending.allocation)
        XCTAssertEqual(
            allocation.allocationExpiresAt,
            now.addingTimeInterval(3_600),
            "The separate publication sidecar retains the exact server allocation TTL."
        )
        XCTAssertEqual(context.transport.allocationCount, 1)
        XCTAssertEqual(context.transport.uploadCount, 1)

        context.transport.setStatus(
            state: .allocated,
            snapshotID: nil,
            expiresAt: now.addingTimeInterval(1)
        )
        do {
            _ = try await context.service.publishSnapshot(
                input: context.input,
                preparation: preparation,
                approval: approval,
                operationID: operationID
            )
            XCTFail("A server status with a different TTL cannot be attached to the retained pua_.")
        } catch let error as RoomPublicationServiceError {
            XCTAssertEqual(error, .invalidPublishedAllocation)
        }
        XCTAssertEqual(
            context.transport.statusCount,
            2,
            "Positive control: native checked the real status route once before upload and once before refusing the retained pua_ TTL mismatch."
        )
        XCTAssertEqual(context.transport.allocationCount, 1)

        context.transport.setStatus(
            state: .published,
            snapshotID: "snp_0000000000000101",
            expiresAt: allocation.allocationExpiresAt
        )
        let reconciled = try await context.service.publishSnapshot(
            input: context.input,
            preparation: preparation,
            approval: approval,
            operationID: operationID
        )
        XCTAssertEqual(reconciled.state, .published)
        XCTAssertEqual(reconciled.snapshotID, "snp_0000000000000101")
        XCTAssertEqual(context.transport.allocationCount, 1, "A terminal server result reconciles the old pua_ without allocating another archive.")
        XCTAssertEqual(
            try context.operationJournal.load(operationID: operationID)?.phase,
            .published,
            "The published snp_ remains recoverable in the additive sidecar; Slice 5 journal bytes remain untouched."
        )
    }

    func testPreparedOperationJournalWriteFailsBeforeAnyPropertyOrAllocationCall() async throws {
        let now = Date(timeIntervalSince1970: 1_786_896_000)
        let context = try makeJournalPublicationContext(now: now)
        defer { context.cleanup() }
        let preparation = try await context.service.prepare(context.input)
        let approval = preparation.makeApproval(
            reviewID: "publication-crash-prepared-review",
            reviewedAt: now
        )
        let faultingJournal = FaultingPublicationOperationJournal(
            base: context.operationJournal,
            failReplaceNumbers: [1]
        )
        let service = context.service(using: faultingJournal)

        do {
            _ = try await service.publishSnapshot(
                input: context.input,
                preparation: preparation,
                approval: approval,
                operationID: "publication-crash-prepared-001"
            )
            XCTFail("The durable prepared intent must be recorded before a property or allocation request.")
        } catch is PublicationOperationJournalFault {
            // Expected crash/write boundary.
        }
        XCTAssertEqual(context.transport.propertyRequestCount, 0)
        XCTAssertEqual(context.transport.allocationCount, 0)
        XCTAssertTrue(
            try context.operationJournal.operations(for: try .make(input: context.input)).isEmpty,
            "Positive control: the fault reached the first durable write rather than a later network path."
        )
    }

    func testPropertyCreateCrashRetainsIdempotentCurationIntentAndRetriesWithoutNewMapping() async throws {
        let now = Date(timeIntervalSince1970: 1_786_896_000)
        var options = fixtureOptions()
        options.mode = .property
        let context = try makeJournalPublicationContext(
            now: now,
            options: options,
            failFirstCompletion: false
        )
        defer { context.cleanup() }
        context.transport.setStatus(
            state: .published,
            snapshotID: "snp_0000000000000201",
            expiresAt: now.addingTimeInterval(3_600)
        )
        let preparation = try await context.service.prepare(context.input)
        let approval = preparation.makeApproval(
            reviewID: "publication-crash-property-review",
            reviewedAt: now
        )
        let operationID = "publication-crash-property-001"
        let faultingJournal = FaultingPublicationOperationJournal(
            base: context.operationJournal,
            failReplaceNumbers: [3]
        )

        do {
            _ = try await context.service(using: faultingJournal).publishSnapshot(
                input: context.input,
                preparation: preparation,
                approval: approval,
                operationID: operationID
            )
            XCTFail("A crash immediately after property create must surface before allocation.")
        } catch is PublicationOperationJournalFault {
            // The server-created property mapping was accepted, but only the
            // pre-call pending/idempotency record is durable locally.
        }
        XCTAssertEqual(context.transport.propertyRequestCount, 1)
        XCTAssertEqual(context.transport.uniquePropertyCurationCount, 1)
        XCTAssertEqual(try context.operationJournal.load(operationID: operationID)?.phase, .propertyPending)
        XCTAssertEqual(context.transport.allocationCount, 0)

        let resumed = try await context.service.publishSnapshot(
            input: context.input,
            preparation: preparation,
            approval: approval,
            operationID: operationID
        )
        XCTAssertEqual(resumed.snapshotID, "snp_0000000000000201")
        XCTAssertEqual(context.transport.propertyRequestCount, 2)
        XCTAssertEqual(
            context.transport.uniquePropertyCurationCount,
            1,
            "Positive control: the retry reached property upsert but reused its pre-network idempotency intent."
        )
        XCTAssertEqual(context.transport.uniqueAllocationCount, 1)
    }

    func testAllocationResponseCrashPersistsPreparedIntentAndRetriesTheSamePuaOperation() async throws {
        let now = Date(timeIntervalSince1970: 1_786_896_000)
        let context = try makeJournalPublicationContext(now: now, failFirstCompletion: false)
        defer { context.cleanup() }
        context.transport.setStatus(
            state: .published,
            snapshotID: "snp_0000000000000301",
            expiresAt: now.addingTimeInterval(3_600)
        )
        let preparation = try await context.service.prepare(context.input)
        let approval = preparation.makeApproval(
            reviewID: "publication-crash-allocation-review",
            reviewedAt: now
        )
        let operationID = "publication-crash-allocation-001"
        let faultingJournal = FaultingPublicationOperationJournal(
            base: context.operationJournal,
            failReplaceNumbers: [2]
        )

        do {
            _ = try await context.service(using: faultingJournal).publishSnapshot(
                input: context.input,
                preparation: preparation,
                approval: approval,
                operationID: operationID
            )
            XCTFail("A post-allocation journal failure must not proceed to upload.")
        } catch is PublicationOperationJournalFault {
            // Expected after the allocator accepts the idempotent operation.
        }
        XCTAssertEqual(context.transport.allocationCount, 1)
        XCTAssertEqual(context.transport.uploadCount, 0)
        XCTAssertEqual(try context.operationJournal.load(operationID: operationID)?.phase, .prepared)

        let resumed = try await context.service.publishSnapshot(
            input: context.input,
            preparation: preparation,
            approval: approval,
            operationID: operationID
        )
        XCTAssertEqual(resumed.snapshotID, "snp_0000000000000301")
        XCTAssertEqual(context.transport.allocationCount, 2)
        XCTAssertEqual(
            context.transport.uniqueAllocationCount,
            1,
            "Positive control: a lost allocation response was retried using the exact prepared operation, not a second immutable allocation."
        )
    }

    func testUploadAmbiguityAndPublishedStatusCrashReconcileWithoutReallocation() async throws {
        let now = Date(timeIntervalSince1970: 1_786_896_000)
        let context = try makeJournalPublicationContext(now: now)
        defer { context.cleanup() }
        let preparation = try await context.service.prepare(context.input)
        let approval = preparation.makeApproval(
            reviewID: "publication-crash-upload-review",
            reviewedAt: now
        )
        let operationID = "publication-crash-upload-001"

        do {
            _ = try await context.service.publishSnapshot(
                input: context.input,
                preparation: preparation,
                approval: approval,
                operationID: operationID
            )
            XCTFail("The fixture must create an ambiguous upload/complete outcome.")
        } catch let error as RoomPublicationTransportError {
            XCTAssertEqual(error, .unavailable)
        }
        XCTAssertEqual(try context.operationJournal.load(operationID: operationID)?.phase, .uploadedOrAmbiguous)
        XCTAssertEqual(context.transport.uniqueAllocationCount, 1)

        context.transport.setStatus(
            state: .published,
            snapshotID: "snp_0000000000000401",
            expiresAt: now.addingTimeInterval(3_600)
        )
        let faultingJournal = FaultingPublicationOperationJournal(
            base: context.operationJournal,
            failReplaceNumbers: [1]
        )
        do {
            _ = try await context.service(using: faultingJournal).publishSnapshot(
                input: context.input,
                preparation: preparation,
                approval: approval,
                operationID: operationID
            )
            XCTFail("A post-publication status journal failure must retain the old pua_ for reconciliation.")
        } catch is PublicationOperationJournalFault {
            // Server terminal status arrived before the client could retire it.
        }
        XCTAssertEqual(try context.operationJournal.load(operationID: operationID)?.phase, .uploadedOrAmbiguous)

        let recovered = try await context.service.publishSnapshot(
            input: context.input,
            preparation: preparation,
            approval: approval,
            operationID: operationID
        )
        XCTAssertEqual(recovered.snapshotID, "snp_0000000000000401")
        XCTAssertEqual(context.transport.uniqueAllocationCount, 1)
        XCTAssertEqual(context.transport.uploadCount, 1)
        XCTAssertEqual(try context.operationJournal.load(operationID: operationID)?.phase, .published)
    }

    func testLinkAndRevocationCrashesRetainExactIntentAndReconcileIdempotently() async throws {
        let now = Date(timeIntervalSince1970: 1_786_896_000)
        let context = try makeJournalPublicationContext(now: now, failFirstCompletion: false)
        defer { context.cleanup() }
        context.transport.setStatus(
            state: .published,
            snapshotID: "snp_0000000000000501",
            expiresAt: now.addingTimeInterval(3_600)
        )
        let preparation = try await context.service.prepare(context.input)
        let approval = preparation.makeApproval(
            reviewID: "publication-crash-link-review",
            reviewedAt: now
        )
        let operationID = "publication-crash-link-001"
        let allocation = try await context.service.publishSnapshot(
            input: context.input,
            preparation: preparation,
            approval: approval,
            operationID: operationID
        )
        let snapshotID = try XCTUnwrap(allocation.snapshotID)
        let controls = RoomPublicationLinkControls.default(now: now)
        let linkJournal = FaultingPublicationOperationJournal(
            base: context.operationJournal,
            failReplaceNumbers: [2]
        )
        do {
            _ = try await context.service(using: linkJournal).createPortalLink(
                snapshotID: snapshotID,
                linkControls: controls,
                aiReadyEntitlement: nil,
                pin: nil,
                operationID: operationID
            )
            XCTFail("A crash after link creation must retain linkPending before returning status.")
        } catch is PublicationOperationJournalFault {
            // Expected after server link creation and live aggregate lookup.
        }
        XCTAssertEqual(try context.operationJournal.load(operationID: operationID)?.phase, .linkPending)
        XCTAssertEqual(context.transport.uniquePortalLinkCount, 1)

        let linked = try await context.service.createPortalLink(
            snapshotID: snapshotID,
            linkControls: controls,
            aiReadyEntitlement: nil,
            pin: nil,
            operationID: operationID
        )
        XCTAssertEqual(linked.lifecycle, .active)
        XCTAssertEqual(context.transport.portalLinkRequestCount, 2)
        XCTAssertEqual(context.transport.uniquePortalLinkCount, 1)

        let revokeJournal = FaultingPublicationOperationJournal(
            base: context.operationJournal,
            failReplaceNumbers: [2]
        )
        do {
            _ = try await context.service(using: revokeJournal).revoke(
                linkID: linked.linkID,
                expectedGeneration: linked.generation,
                operationID: operationID
            )
            XCTFail("A crash after revocation must retain a revocation intent before returning.")
        } catch is PublicationOperationJournalFault {
            // Expected after the server has revoked the active link.
        }
        XCTAssertEqual(try context.operationJournal.load(operationID: operationID)?.phase, .revocationPending)
        XCTAssertEqual(context.transport.uniqueRevocationCount, 1)

        let revocation = try await context.service.revoke(
            linkID: linked.linkID,
            expectedGeneration: linked.generation,
            operationID: operationID
        )
        XCTAssertEqual(revocation.disposition, "already_revoked")
        XCTAssertEqual(context.transport.revokeRequestCount, 2)
        XCTAssertEqual(context.transport.uniqueRevocationCount, 1)
        XCTAssertEqual(try context.operationJournal.load(operationID: operationID)?.phase, .revoked)
    }

    func testActiveOperationRejectsChangedSelectionBeforeCoreFinalizationOrNewAllocation() async throws {
        let now = Date(timeIntervalSince1970: 1_786_896_000)
        let context = try makeJournalPublicationContext(now: now)
        defer { context.cleanup() }
        let preparation = try await context.service.prepare(context.input)
        let approval = preparation.makeApproval(
            reviewID: "publication-stale-intent-review",
            reviewedAt: now
        )
        let operationID = "publication-stale-intent-001"
        do {
            _ = try await context.service.publishSnapshot(
                input: context.input,
                preparation: preparation,
                approval: approval,
                operationID: operationID
            )
            XCTFail("The fixture must leave an active ambiguous pua_ operation.")
        } catch let error as RoomPublicationTransportError {
            XCTAssertEqual(error, .unavailable)
        }
        XCTAssertEqual(context.transport.uniqueAllocationCount, 1)

        guard case var .room(room) = context.input.draft else {
            return XCTFail("Fixture must provide a room presentation for selection mutation.")
        }
        room.title = "Changed public selection title"
        let changedInput = RoomPublicationReviewInput(
            journalAnchorProjectID: context.input.journalAnchorProjectID,
            draft: .room(room),
            sourceBindings: context.input.sourceBindings,
            hostedSourceBindings: context.input.hostedSourceBindings,
            propertyCuration: nil,
            assets: context.input.assets,
            rasterChoices: context.input.rasterChoices,
            conceptChoices: context.input.conceptChoices,
            aiReadyPackageChoices: context.input.aiReadyPackageChoices,
            qualityWarnings: context.input.qualityWarnings
        )
        let changedPreparation = try await context.service.prepare(changedInput)
        do {
            _ = try await context.service.publishSnapshot(
                input: changedInput,
                preparation: changedPreparation,
                approval: approval,
                operationID: operationID
            )
            XCTFail("A changed selection may not reinterpret the old durable approval.")
        } catch let error as RoomPublicationServiceError {
            XCTAssertEqual(error, .staleOperation)
        }
        XCTAssertEqual(
            context.transport.uniqueAllocationCount,
            1,
            "Positive control: the original pua_ was real, and the stale-intent guard stopped a second allocation before Core finalization."
        )
    }

    func testActiveOperationRejectsInvalidApprovalBeforeCoreFinalization() async throws {
        let now = Date(timeIntervalSince1970: 1_786_896_000)
        let context = try makeJournalPublicationContext(now: now)
        defer { context.cleanup() }
        let preparation = try await context.service.prepare(context.input)
        let approval = preparation.makeApproval(
            reviewID: "publication-invalid-approval-review",
            reviewedAt: now
        )
        let operationID = "publication-invalid-approval-001"
        do {
            _ = try await context.service.publishSnapshot(
                input: context.input,
                preparation: preparation,
                approval: approval,
                operationID: operationID
            )
            XCTFail("The fixture must leave a real active allocation before the stale approval probe.")
        } catch let error as RoomPublicationTransportError {
            XCTAssertEqual(error, .unavailable)
        }
        XCTAssertEqual(context.transport.uniqueAllocationCount, 1)

        var invalidApproval = approval
        invalidApproval.selectionManifestSHA256 = String(repeating: "0", count: 64)
        do {
            _ = try await context.service.publishSnapshot(
                input: context.input,
                preparation: preparation,
                approval: invalidApproval,
                operationID: operationID
            )
            XCTFail("An active operation may not ask Core to finalize an unreviewed approval.")
        } catch let error as RoomPublicationServiceError {
            XCTAssertEqual(error, .staleOperation)
        }
        XCTAssertEqual(
            context.transport.uniqueAllocationCount,
            1,
            "Positive control: a real pua_ allocation exists, but invalid approval input must stop before Core finalization and transport."
        )
    }

    func testPropertyReviewBindsDirectOrderedSourcesAndInvalidatesWhenOrderChanges() async throws {
        var options = fixtureOptions()
        options.mode = .property
        var reverseOrder = false
        let transport = RoomPublicationFixtureTransport()
        let model = RoomPublicationReviewModel(
            options: options,
            inputProvider: { options in
                var input = try RoomPublicationFixtureFactory.makeInput(
                    options: options,
                    includeWarning: false
                )
                guard reverseOrder else { return input }
                guard case var .property(presentation) = input.draft,
                      let curation = input.propertyCuration
                else { return input }
                presentation.rooms.reverse()
                let reversedBindings = input.sourceBindings.reversed()
                let reversedHosted = input.hostedSourceBindings.reversed()
                let reversedRooms = curation.rooms.reversed().enumerated().map { index, room in
                    RoomPublicationPropertyRoom(
                        publicRoomKey: room.publicRoomKey,
                        roomOrder: index + 1,
                        projectPublicID: room.projectPublicID
                    )
                }
                input = .init(
                    journalAnchorProjectID: input.journalAnchorProjectID,
                    draft: .property(presentation),
                    sourceBindings: Array(reversedBindings),
                    hostedSourceBindings: Array(reversedHosted),
                    propertyCuration: .init(
                        localPropertyID: curation.localPropertyID,
                        title: curation.title,
                        rooms: reversedRooms
                    ),
                    assets: input.assets,
                    rasterChoices: input.rasterChoices,
                    conceptChoices: input.conceptChoices,
                    aiReadyPackageChoices: input.aiReadyPackageChoices,
                    qualityWarnings: input.qualityWarnings
                )
                return input
            },
            service: RoomPublicationService.fixture(transport: transport),
            confirmSensitiveAction: { true },
            now: { Date(timeIntervalSince1970: 1_786_896_000) },
            reviewID: { "publication-property-order-review" }
        )
        try await model.prepareReview()
        let originalBindings = try XCTUnwrap(model.input?.hostedSourceBindings)
        XCTAssertEqual(originalBindings.map(\.publicRoomKey), ["room-001", "room-002"])
        XCTAssertTrue(originalBindings.allSatisfy { $0.projectPublicID.hasPrefix("prj_") })
        XCTAssertFalse(
            originalBindings.contains { $0.projectPublicID.hasPrefix("snp_") },
            "Property curation must name direct hosted room projects, never child snapshot IDs."
        )
        let presentationData = try XCTUnwrap(model.preparation?.presentationData)
        let presentation = try XCTUnwrap(String(data: presentationData, encoding: .utf8))
        XCTAssertTrue(presentation.contains(RoomPublishedPropertyPresentationV1.independentRoomNotice))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: presentationData) as? [String: Any]
        )
        // The fixed disclosure deliberately says that rooms do *not* share
        // alignment/connectivity/reconstruction. Assert the schema closure,
        // rather than treating the required denial wording as an unsafe claim.
        let forbiddenSpatialKeys = [
            "coordinateSpaceEpochID",
            "alignment",
            "connectivity",
            "reconstruction",
            "transform",
            "topology",
            "doorway"
        ]
        XCTAssertFalse(
            containsJSONKey(in: object, anyOf: forbiddenSpatialKeys),
            "A property snapshot may only contain independent room-local facts."
        )
        model.setDisclosureConfirmed(true)
        try model.approveReview()
        reverseOrder = true

        do {
            try await model.publish()
            XCTFail("Changing direct property source order must invalidate the exact reviewed approval.")
        } catch let error as RoomPublicationReviewError {
            XCTAssertEqual(error, .staleReview)
        }
        XCTAssertEqual(transport.reservationCount, 0)
    }

    /// Server time owns the default. Native can offer a bounded explicit
    /// override, but an untouched link request must omit expiry entirely.
    func testNativeLinkDefaultOmitsClientCalculatedExpiry() {
        let controls = RoomPublicationLinkControls.default(
            now: Date(timeIntervalSince1970: 1_786_896_000)
        )
        XCTAssertNil(controls.expiresAt)
    }

    /// Allocation is `pua_`-keyed; a snapshot is not a valid completion or
    /// recovery identifier before validation reaches `published`.
    func testPublicationAllocationUsesPUALifecycleRatherThanSnapshotReservation() async throws {
        let request = RoomPublicationAllocationRequest(
            publicationKind: .room,
            projectID: "prj_0000000000000001",
            sourceRevisionID: "rev_0000000000000001",
            sourceRevisionDigest: String(repeating: "a", count: 64),
            sourceManifestDigest: String(repeating: "b", count: 64),
            sourceBindings: [.init(
                publicRoomKey: "room-001",
                projectPublicID: "prj_0000000000000001",
                revisionPublicID: "rev_0000000000000001",
                sourceRevision: .init(
                    projectID: "local-project-001",
                    revisionID: "local-revision-001",
                    coordinateSpaceEpochID: "epoch-001",
                    packageSchemaVersion: "room-scan-project-v2",
                    semanticSHA256: String(repeating: "a", count: 64),
                    revisionManifestSHA256: String(repeating: "b", count: 64)
                )
            )],
            sourceBindingsSHA256: String(repeating: "c", count: 64),
            selectionManifestSHA256: String(repeating: "d", count: 64),
            approvalSHA256: String(repeating: "e", count: 64),
            propertyID: nil,
            archiveManifestSHA256: String(repeating: "f", count: 64),
            archiveSHA256: String(repeating: "0", count: 64),
            archiveByteCount: 1,
            idempotencyKey: "publication-allocation-red-001"
        )
        XCTAssertEqual(request.publicationKind, .room)
        XCTAssertEqual(request.sourceBindings.count, 1)
    }

    /// Browser-only one-time share capability is not a native response field.
    /// The transport must reject it rather than decoding, displaying, logging,
    /// or retaining the bearer value.
    func testAppBearerLinkResponseRejectsShareURLCanary() async throws {
        let now = Date(timeIntervalSince1970: 1_786_896_000)
        let executor = PublicationHTTPSExecutorSpy(responses: [
            .init(statusCode: 200, data: responseData([
                "status": "created",
                "linkID": "lnk_0000000000000001",
                "generation": 1,
                "expiresAt": iso8601(now.addingTimeInterval(60)),
                "pinRequired": false,
                "shareURL": "https://portal.example.invalid/p#bearer-canary"
            ]))
        ])
        let transport = try FoundationRoomPublicationTransport(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.invalid/v1/")),
            authorization: { "Bearer \(String(repeating: "n", count: 32))" },
            executor: executor,
            now: { now }
        )

        do {
            _ = try await transport.createPortalLink(
                snapshotID: "snp_0000000000000001",
                request: .init(
                    idempotencyKey: "portal-link-red-001",
                    expiresAt: nil,
                    pinCandidate: nil,
                    aiPolicy: .disabled,
                    feedbackPolicy: .disabled
                )
            )
            XCTFail("An app-bearer client must reject a browser share URL canary.")
        } catch let error as RoomPublicationTransportError {
            XCTAssertEqual(error, .invalidResponse)
        }
        XCTAssertEqual(executor.requests.count, 1, "Positive control: the live app-bearer route was reached before strict response rejection.")
        XCTAssertEqual(executor.requests[0].headers["Authorization"], "Bearer \(String(repeating: "n", count: 32))")
        XCTAssertNil(executor.requests[0].headers["Cookie"])
        XCTAssertNil(executor.requests[0].headers["X-RoomScan-CSRF"])
    }

    // MARK: - Durable publication-operation journal RED contract

    func testPublicationOperationJournalPersistsExactPreparedIntentWithoutPrivatePayloads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "publication-operation-journal-red-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let options = fixtureOptions()
        let input = try RoomPublicationFixtureFactory.makeInput(
            options: options,
            includeWarning: false
        )
        let preparation = try await RoomPublishedSnapshotBuilder.prepare(
            draft: input.draft,
            sourceBindings: input.sourceBindings,
            assets: input.assets
        )
        let approval = preparation.makeApproval(
            reviewID: "publication-operation-review-001",
            reviewedAt: Date(timeIntervalSince1970: 1_786_896_000)
        )
        let record = try PublicationOperationJournalRecord.prepared(
            operationID: "publication-operation-001",
            input: input,
            preparation: preparation,
            approval: approval,
            archiveManifestSHA256: String(repeating: "a", count: 64),
            archiveSHA256: String(repeating: "b", count: 64),
            archiveByteCount: 42
        )
        let journal = try PublicationOperationJournal(rootURL: root)

        try journal.replace(record)

        XCTAssertEqual(try journal.load(operationID: record.operationID), record)
        let persisted = try Data(contentsOf: root
            .appendingPathComponent("operations", isDirectory: true)
            .appendingPathComponent("\(record.operationID).json"))
        let text = String(decoding: persisted, as: UTF8.self)
        XCTAssertTrue(
            input.sourceBindings.map(\.sourceRevision.projectID).contains(where: {
                $0.hasPrefix("private-project-canary-")
            }),
            "Positive control: the rebuilt Core source has a private local project canary."
        )
        XCTAssertFalse(text.contains("private-project-canary"))
        XCTAssertFalse(text.contains("private-revision-canary"))
        XCTAssertFalse(text.contains("123456"))
        XCTAssertFalse(text.contains("https://"))
        XCTAssertFalse(text.contains("/private/"))
    }

    func testDisablingPINAndDismissingReviewClearTheEphemeralCandidate() async throws {
        let model = makeFixtureModel(
            transport: RoomPublicationFixtureTransport(),
            confirmSensitiveAction: { true }
        )
        var controls = model.options.linkControls
        controls.requiresPIN = true
        model.updateLinkControls(controls)
        try model.setPIN("123456")
        XCTAssertTrue(model.debugRetainsEphemeralPIN, "Positive control: the model retains a valid candidate only while PIN is enabled.")

        controls.requiresPIN = false
        model.updateLinkControls(controls)
        XCTAssertFalse(model.debugRetainsEphemeralPIN)

        controls.requiresPIN = true
        model.updateLinkControls(controls)
        try model.setPIN("123456")
        model.dismissReview()
        XCTAssertFalse(model.debugRetainsEphemeralPIN)
    }

    func testConfiguredTransportDecodesStrictLiveFeedbackAggregateWithoutFeedbackBodies() async throws {
        let now = Date(timeIntervalSince1970: 1_786_896_000)
        let executor = PublicationHTTPSExecutorSpy(responses: [
            .init(statusCode: 200, data: responseData([
                "items": [[
                    "linkID": "lnk_0000000000000001",
                    "snapshotID": "snp_0000000000000001",
                    "generation": 3,
                    "state": "active",
                    "expiresAt": iso8601(now.addingTimeInterval(3_600)),
                    "pinRequired": true,
                    "aiEnabled": true,
                    "feedbackEnabled": true,
                    "feedbackCount": 2,
                    "feedbackCountCapped": false,
                    "latestFeedbackAction": "approve",
                    "latestFeedbackAt": iso8601(now)
                ]]
            ]))
        ])
        let transport = try FoundationRoomPublicationTransport(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.invalid/")),
            authorization: { "Bearer \(String(repeating: "n", count: 32))" },
            executor: executor,
            now: { now }
        )

        let link = try await transport.portalLinkStatus(
            linkID: "lnk_0000000000000001",
            snapshotID: "snp_0000000000000001"
        )

        XCTAssertEqual(link?.feedbackSummary.recordCount, 2)
        XCTAssertEqual(link?.feedbackSummary.latestActionLabel, "Approve")
        XCTAssertEqual(executor.requests.first?.url.path, "/publications/links/list")
        XCTAssertNil(executor.requests.first?.headers["Cookie"])
        XCTAssertNil(executor.requests.first?.headers["X-RoomScan-CSRF"])
    }

    private func makeFixtureModel(
        transport: RoomPublicationFixtureTransport,
        confirmSensitiveAction: @escaping RoomPublicationReviewModel.SensitiveActionConfirmation
    ) -> RoomPublicationReviewModel {
        RoomPublicationReviewModel(
            options: fixtureOptions(),
            inputProvider: { options in
                try RoomPublicationFixtureFactory.makeInput(
                    options: options,
                    includeWarning: false
                )
            },
            service: RoomPublicationService.fixture(transport: transport),
            confirmSensitiveAction: confirmSensitiveAction,
            now: { Date(timeIntervalSince1970: 1_786_896_000) },
            // Production mints a new reviewed approval ID after any invalidated
            // review.  A fixed fixture ID would incorrectly turn a genuinely
            // new selected closure into a replay of the old operation.
            reviewID: { "publication-review-\(UUID().uuidString.lowercased())" }
        )
    }

    private func fixtureOptions() -> RoomPublicationReviewOptions {
        var options = RoomPublicationReviewOptions.default(
            now: Date(timeIntervalSince1970: 1_786_896_000)
        )
        options.title = "Native publication test"
        options.branding = .init(
            businessName: "Test studio",
            phone: "+1 555 0100",
            website: "https://example.invalid",
            accent: .blueprint,
            logo: nil
        )
        return options
    }

    private func jpegWithAPP0(_ data: Data) -> Data {
        guard data.count >= 2 else { return data }
        var carrier = Data([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x08])
        carrier.append(Data("CANARY".utf8))
        carrier.append(data.dropFirst(2))
        return carrier
    }

    private func responseData(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func makeAllocationRequest(
        digest: String,
        idempotencyKey: String
    ) -> RoomPublicationAllocationRequest {
        let source = RoomRedesignSourceRevision(
            projectID: "local-project-001",
            revisionID: "local-revision-001",
            coordinateSpaceEpochID: "local-epoch-001",
            packageSchemaVersion: "room-scan-project-v2",
            semanticSHA256: digest,
            revisionManifestSHA256: digest
        )
        return .init(
            publicationKind: .room,
            projectID: "prj_0000000000000001",
            sourceRevisionID: "rev_0000000000000001",
            sourceRevisionDigest: digest,
            sourceManifestDigest: digest,
            sourceBindings: [.init(
                publicRoomKey: "room-001",
                projectPublicID: "prj_0000000000000001",
                revisionPublicID: "rev_0000000000000001",
                sourceRevision: source
            )],
            sourceBindingsSHA256: digest,
            selectionManifestSHA256: digest,
            approvalSHA256: digest,
            propertyID: nil,
            archiveManifestSHA256: digest,
            archiveSHA256: digest,
            archiveByteCount: 42,
            idempotencyKey: idempotencyKey
        )
    }

    private func canonicalJournalRecord(
        source: RoomRedesignSourceRevision,
        hostedProjectID: String,
        hostedRevisionID: String
    ) -> ProfessionalProjectSyncJournalRecord {
        .init(
            localProjectID: source.projectID,
            hostedProjectID: hostedProjectID,
            acknowledgedLocalHeadRevisionID: source.revisionID,
            acknowledgedHostedHeadRevisionID: hostedRevisionID,
            status: .canonical,
            currentHostedHeadRevisionID: hostedRevisionID,
            canonicalRevisionID: hostedRevisionID
        )
    }

    private func makeJournalPublicationContext(
        now: Date,
        options: RoomPublicationReviewOptions? = nil,
        failFirstCompletion: Bool = true
    ) throws -> JournalPublicationContext {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "publication-pending-journal-\(UUID().uuidString)",
            isDirectory: true
        )
        let journal = try ProfessionalProjectSyncJournal(rootURL: root)
        let input = try RoomPublicationFixtureFactory.makeInput(
            options: options ?? fixtureOptions(),
            includeWarning: false
        )
        for binding in input.hostedSourceBindings {
            try journal.replace(canonicalJournalRecord(
                source: binding.sourceRevision,
                hostedProjectID: binding.projectPublicID,
                hostedRevisionID: binding.revisionPublicID
            ))
        }
        let sources = Dictionary(
            uniqueKeysWithValues: input.hostedSourceBindings.map {
                ($0.sourceRevision.projectID, $0.sourceRevision)
            }
        )
        let resolver = PublicationSourceIdentityResolver(
            journal: journal,
            currentSource: { projectID in
                guard let source = sources[projectID] else {
                    throw RoomPublicationSourceIdentityError.unavailable
                }
                return source
            }
        )
        let transport = PublicationLifecycleTransport(
            now: now,
            failFirstCompletion: failFirstCompletion
        )
        let operationJournal = try PublicationOperationJournal(
            rootURL: root.appendingPathComponent("PublicationOperationJournal", isDirectory: true)
        )
        let service = RoomPublicationService(
            transport: transport,
            workspaceFactory: RoomExportWorkspaceFactory(
                rootURL: root.appendingPathComponent("exports", isDirectory: true)
            ),
            identityResolver: resolver,
            operationJournal: operationJournal,
            pollLimit: 1,
            now: { now }
        )
        return .init(
            root: root,
            journal: journal,
            operationJournal: operationJournal,
            identityResolver: resolver,
            input: input,
            transport: transport,
            service: service,
            now: now
        )
    }

    private func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// Reuses the service/Core golden package rather than inventing an AI
    /// entitlement in the test. The retained fixture root keeps the real
    /// nested package available while the native service rebuilds the exact
    /// immutable publication intent and archive.
    private func fixtureAIReadyReviewInput() async throws -> (
        root: URL,
        input: RoomPublicationReviewInput,
        preparation: RoomPublishedSnapshotPreparation
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "publication-ai-ready-entitlement-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let encodedURL = repositoryRoot
                .appendingPathComponent("HostedService", isDirectory: true)
                .appendingPathComponent("fixtures", isDirectory: true)
                .appendingPathComponent("publication", isDirectory: true)
                .appendingPathComponent("room-v2-ai-ready.zip.base64")
            let encoded = try String(contentsOf: encodedURL, encoding: .utf8)
            let archiveData = try XCTUnwrap(
                Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
                "Positive control fixture must contain an actual encoded AI-ready archive."
            )
            let archiveURL = root.appendingPathComponent("fixture.zip")
            try archiveData.write(to: archiveURL, options: [.withoutOverwriting])
            let extracted = root.appendingPathComponent("extracted", isDirectory: true)
            try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
            let validation = try await RoomPublicationArchive.extractAndValidate(
                archiveURL: archiveURL,
                into: extracted
            )
            guard validation.draft.kind == .room,
                  let sourceBinding = validation.manifest.sourceBindings.first,
                  validation.manifest.sourceBindings.count == 1
            else { throw RoomPublicationTransportError.invalidResponse }
            let assets = try validation.manifest.assets.map { ledger -> RoomPublishedAssetInput in
                let assetURL = extracted.appendingPathComponent(ledger.relativePath)
                switch ledger.assetClass {
                case .webGeometry:
                    return .geometry(
                        assetID: ledger.assetID,
                        publicRoomKey: try XCTUnwrap(ledger.publicRoomKey),
                        geometry: try JSONDecoder().decode(
                            RoomPublishedWebGeometry.self,
                            from: Data(contentsOf: assetURL, options: [.mappedIfSafe])
                        )
                    )
                case .aiReadyPackage:
                    let binding = try XCTUnwrap(ledger.aiReadyPackageBinding)
                    return .aiReadyPackage(
                        assetID: ledger.assetID,
                        input: .init(
                            archiveURL: assetURL,
                            publicRoomKey: try XCTUnwrap(ledger.publicRoomKey),
                            expectedPackageID: binding.packageID
                        )
                    )
                case .webTexture, .selectedImage, .floorPlan, .approvedConcept, .brandingLogo:
                    return .raster(
                        assetID: ledger.assetID,
                        publicRoomKey: ledger.publicRoomKey,
                        assetClass: ledger.assetClass,
                        raster: .init(
                            data: try Data(contentsOf: assetURL, options: [.mappedIfSafe]),
                            mediaType: try XCTUnwrap(
                                RoomPublishedRasterMediaType(rawValue: ledger.mediaType)
                            )
                        )
                    )
                }
            }
            let preparation = try await RoomPublishedSnapshotBuilder.prepare(
                draft: validation.draft,
                sourceBindings: validation.manifest.sourceBindings,
                assets: assets
            )
            let input = RoomPublicationReviewInput(
                journalAnchorProjectID: sourceBinding.sourceRevision.projectID,
                draft: validation.draft,
                sourceBindings: validation.manifest.sourceBindings,
                hostedSourceBindings: [.init(
                    publicRoomKey: sourceBinding.publicRoomKey,
                    projectPublicID: "prj_0000000000000001",
                    revisionPublicID: "rev_0000000000000001",
                    sourceRevision: sourceBinding.sourceRevision
                )],
                propertyCuration: nil,
                assets: assets,
                rasterChoices: [],
                conceptChoices: [],
                aiReadyPackageChoices: [],
                qualityWarnings: validation.draft.publicRooms().flatMap(\.qualityWarnings)
            )
            return (root, input, preparation)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    /// Opens the committed service/Core publication fixture and returns the
    /// real nested AI-ready package candidate. The new native assembler must
    /// independently re-read this archive before it may add an immutable
    /// download asset; this helper does not manufacture package facts.
    private func fixtureAIReadyPublicationCandidate() async throws -> (
        root: URL,
        candidate: RoomPublicationAIReadyPackageCandidate,
        sourceBinding: RoomPublishedSourceBinding
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "publication-ai-ready-candidate-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let encodedURL = repositoryRoot
            .appendingPathComponent("HostedService", isDirectory: true)
            .appendingPathComponent("fixtures", isDirectory: true)
            .appendingPathComponent("publication", isDirectory: true)
            .appendingPathComponent("room-v2-ai-ready.zip.base64")
        let encoded = try String(contentsOf: encodedURL, encoding: .utf8)
        let archiveData = try XCTUnwrap(
            Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines))
        )
        let outerArchiveURL = root.appendingPathComponent("publication.zip")
        try archiveData.write(to: outerArchiveURL, options: [.withoutOverwriting])
        let extracted = root.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let publication = try await RoomPublicationArchive.extractAndValidate(
            archiveURL: outerArchiveURL,
            into: extracted
        )
        let ledger = try XCTUnwrap(publication.manifest.assets.first {
            $0.assetClass == .aiReadyPackage
        })
        let publicRoomKey = try XCTUnwrap(ledger.publicRoomKey)
        let sourceBinding = try XCTUnwrap(publication.manifest.sourceBindings.first {
            $0.publicRoomKey == publicRoomKey
        })
        let packageBinding = try XCTUnwrap(ledger.aiReadyPackageBinding)
        return (
            root,
            .init(
                archiveURL: extracted.appendingPathComponent(ledger.relativePath),
                sourceRevision: sourceBinding.sourceRevision,
                expectedPackageID: packageBinding.packageID
            ),
            sourceBinding
        )
    }

    private func aiReadyArchiveResult(
        from candidate: RoomPublicationAIReadyPackageCandidate
    ) async throws -> RoomAIRoomPackageArchiveResult {
        let validationRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "publication-ai-ready-result-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: validationRoot) }
        try FileManager.default.createDirectory(at: validationRoot, withIntermediateDirectories: true)
        let validation = try await RoomAIRoomPackageArchive.extractAndValidate(
            archiveURL: candidate.archiveURL,
            into: validationRoot,
            expectedSourceRevision: candidate.sourceRevision,
            expectedProfile: .aiReady
        )
        let values = try candidate.archiveURL.resourceValues(forKeys: [.fileSizeKey])
        return .init(
            archiveURL: candidate.archiveURL,
            package: validation.package,
            manifestData: validation.manifestData,
            receipt: .init(
                profileVersion: "test-roomscan-ai-ready",
                archiveSHA256: try RoomSHA256.hexDigest(ofFile: candidate.archiveURL),
                archiveByteCount: UInt64(try XCTUnwrap(values.fileSize)),
                entries: validation.entries
            )
        )
    }
}

private func containsJSONKey(
    in value: Any,
    anyOf forbiddenKeys: [String]
) -> Bool {
    let forbidden = Set(forbiddenKeys)
    if let object = value as? [String: Any] {
        if object.keys.contains(where: forbidden.contains) {
            return true
        }
        return object.values.contains { containsJSONKey(in: $0, anyOf: forbiddenKeys) }
    }
    if let array = value as? [Any] {
        return array.contains { containsJSONKey(in: $0, anyOf: forbiddenKeys) }
    }
    return false
}

@MainActor
private final class JournalPublicationContext {
    let root: URL
    let journal: ProfessionalProjectSyncJournal
    let operationJournal: PublicationOperationJournal
    let identityResolver: PublicationSourceIdentityResolver
    let input: RoomPublicationReviewInput
    let transport: PublicationLifecycleTransport
    let service: RoomPublicationService
    private let now: Date

    init(
        root: URL,
        journal: ProfessionalProjectSyncJournal,
        operationJournal: PublicationOperationJournal,
        identityResolver: PublicationSourceIdentityResolver,
        input: RoomPublicationReviewInput,
        transport: PublicationLifecycleTransport,
        service: RoomPublicationService,
        now: Date
    ) {
        self.root = root
        self.journal = journal
        self.operationJournal = operationJournal
        self.identityResolver = identityResolver
        self.input = input
        self.transport = transport
        self.service = service
        self.now = now
    }

    func service(
        using operationJournal: any PublicationOperationJournaling
    ) -> RoomPublicationService {
        RoomPublicationService(
            transport: transport,
            workspaceFactory: RoomExportWorkspaceFactory(
                rootURL: root.appendingPathComponent("exports", isDirectory: true)
            ),
            identityResolver: identityResolver,
            operationJournal: operationJournal,
            pollLimit: 1,
            now: { self.now }
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class PublicationLifecycleTransport: RoomPublicationTransport {
    private let now: Date
    private var latestRequest: RoomPublicationAllocationRequest?
    private var state: RoomPublicationRemoteAllocationState = .allocated
    private var publishedSnapshotID: String?
    private var statusExpiry: Date
    private var shouldFailFirstCompletion: Bool
    private var allocationIdempotencyKeys: Set<String> = []
    private var propertyIdempotencyKeys: Set<String> = []
    private var portalLinkIdempotencyKeys: Set<String> = []
    private var revocationLinkIDs: Set<String> = []
    private var portalLifecycle: RoomPublicationPortalLinkLifecycle = .active
    private var portalGeneration = 1
    private(set) var allocationCount = 0
    private(set) var uploadCount = 0
    private(set) var statusCount = 0
    private(set) var uniqueAllocationCount = 0
    private(set) var propertyRequestCount = 0
    private(set) var uniquePropertyCurationCount = 0
    private(set) var portalLinkRequestCount = 0
    private(set) var uniquePortalLinkCount = 0
    private(set) var revokeRequestCount = 0
    private(set) var uniqueRevocationCount = 0

    init(now: Date, failFirstCompletion: Bool = true) {
        self.now = now
        statusExpiry = now.addingTimeInterval(3_600)
        shouldFailFirstCompletion = failFirstCompletion
    }

    func setStatus(
        state: RoomPublicationRemoteAllocationState,
        snapshotID: String?,
        expiresAt: Date
    ) {
        self.state = state
        publishedSnapshotID = snapshotID
        statusExpiry = expiresAt
    }

    func allocatePublication(
        _ request: RoomPublicationAllocationRequest
    ) async throws -> RoomPublicationUploadAllocation {
        try request.validate()
        allocationCount += 1
        if allocationIdempotencyKeys.insert(request.idempotencyKey).inserted {
            uniqueAllocationCount += 1
        }
        latestRequest = request
        return .fixture(
            allocationID: "pua_0000000000000101",
            allocationExpiresAt: now.addingTimeInterval(3_600),
            uploadURL: try XCTUnwrap(
                URL(string: "https://objects.example.invalid/publications/quarantine?signature=test")
            ),
            uploadHeaders: ["x-roomscan-upload": "test"]
        )
    }

    func uploadPublicationArchive(
        _ archive: RoomPublicationArchiveUpload,
        allocation: RoomPublicationUploadAllocation
    ) async throws {
        guard allocation.allocationID == "pua_0000000000000101",
              archive.byteCount > 0
        else { throw RoomPublicationTransportError.invalidResponse }
        uploadCount += 1
    }

    func completePublication(
        allocationID: String,
        archiveSHA256: String,
        archiveManifestSHA256: String,
        archiveByteCount: UInt64
    ) async throws -> RoomPublicationCompletionStatus {
        guard allocationID == "pua_0000000000000101",
              !archiveSHA256.isEmpty,
              !archiveManifestSHA256.isEmpty,
              archiveByteCount > 0
        else { throw RoomPublicationTransportError.invalidResponse }
        if shouldFailFirstCompletion {
            shouldFailFirstCompletion = false
            throw RoomPublicationTransportError.unavailable
        }
        return .init(
            allocationID: allocationID,
            disposition: .validationPending
        )
    }

    func allocationStatus(
        allocationID: String
    ) async throws -> RoomPublicationRemoteAllocationStatus {
        guard allocationID == "pua_0000000000000101",
              let request = latestRequest
        else { throw RoomPublicationTransportError.invalidResponse }
        statusCount += 1
        return .init(
            allocationID: allocationID,
            state: state,
            kind: request.publicationKind,
            projectID: request.projectID,
            sourceRevisionID: request.sourceRevisionID,
            propertyID: request.propertyID,
            snapshotID: publishedSnapshotID,
            rejectionCode: nil,
            createdAt: now,
            updatedAt: now,
            expiresAt: statusExpiry
        )
    }

    func upsertPropertyCuration(
        _ request: RoomPublicationPropertyCurationRequest
    ) async throws -> RoomPublicationPropertyCurationStatus {
        try request.validate()
        propertyRequestCount += 1
        if propertyIdempotencyKeys.insert(request.createIdempotencyKey).inserted {
            uniquePropertyCurationCount += 1
        }
        return .init(propertyID: "prop_0000000000000101", version: 1)
    }

    func createPortalLink(
        snapshotID: String,
        request: RoomPublicationPortalLinkRequest
    ) async throws -> RoomPublicationPortalLinkStatus {
        guard snapshotID.hasPrefix("snp_") else {
            throw RoomPublicationTransportError.invalidResponse
        }
        portalLinkRequestCount += 1
        if portalLinkIdempotencyKeys.insert(request.idempotencyKey).inserted {
            uniquePortalLinkCount += 1
        }
        return .init(
            linkID: "lnk_0000000000000101",
            generation: portalGeneration,
            lifecycle: portalLifecycle,
            expiresAt: now.addingTimeInterval(3_600),
            pinRequired: false,
            feedbackSummary: .empty
        )
    }

    func portalLinkStatus(
        linkID: String,
        snapshotID: String
    ) async throws -> RoomPublicationPortalLinkStatus? {
        guard linkID == "lnk_0000000000000101", snapshotID.hasPrefix("snp_") else {
            throw RoomPublicationTransportError.invalidResponse
        }
        return .init(
            linkID: linkID,
            generation: portalGeneration,
            lifecycle: portalLifecycle,
            expiresAt: now.addingTimeInterval(3_600),
            pinRequired: false,
            aiEnabled: false,
            feedbackEnabled: true,
            feedbackSummary: .init(
                recordCount: 2,
                isCapped: false,
                latestActionLabel: "Approve",
                latestRecordedAt: now
            )
        )
    }

    func revokePortalLink(
        linkID: String,
        expectedGeneration: Int
    ) async throws -> RoomPublicationPortalLinkRevocation {
        guard linkID.hasPrefix("lnk_"), expectedGeneration > 0 else {
            throw RoomPublicationTransportError.invalidResponse
        }
        revokeRequestCount += 1
        if revocationLinkIDs.insert(linkID).inserted {
            uniqueRevocationCount += 1
            portalLifecycle = .revoked
            portalGeneration = expectedGeneration + 1
            return .init(
                linkID: linkID,
                generation: portalGeneration,
                disposition: "revoked"
            )
        }
        return .init(
            linkID: linkID,
            generation: expectedGeneration,
            disposition: "already_revoked"
        )
    }
}

private enum PublicationOperationJournalFault: Error, Equatable {
    case injected
}

/// Wraps the real marker-owned sidecar so crash-window tests exercise the same
/// serialization, validation, and immutable replacement rules as production.
@MainActor
private final class FaultingPublicationOperationJournal: PublicationOperationJournaling {
    private let base: PublicationOperationJournal
    private var remainingFaults: Set<Int>
    private(set) var replaceCount = 0

    init(base: PublicationOperationJournal, failReplaceNumbers: Set<Int>) {
        self.base = base
        remainingFaults = failReplaceNumbers
    }

    func load(operationID: String) throws -> PublicationOperationJournalRecord? {
        try base.load(operationID: operationID)
    }

    func operations(for route: PublicationOperationRoute) throws -> [PublicationOperationJournalRecord] {
        try base.operations(for: route)
    }

    func replace(_ record: PublicationOperationJournalRecord) throws {
        replaceCount += 1
        if remainingFaults.remove(replaceCount) != nil {
            throw PublicationOperationJournalFault.injected
        }
        try base.replace(record)
    }
}

@MainActor
private final class PublicationHTTPSExecutorSpy: RoomPublicationHTTPSExecuting {
    struct Upload: Equatable {
        let url: URL
        let headers: [String: String]
    }

    private var responses: [RoomPublicationHTTPSResponse]
    private(set) var requests: [RoomPublicationHTTPSRequest] = []
    private(set) var uploads: [Upload] = []

    init(responses: [RoomPublicationHTTPSResponse]) {
        self.responses = responses
    }

    func execute(_ request: RoomPublicationHTTPSRequest) async throws -> RoomPublicationHTTPSResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw RoomPublicationTransportError.invalidResponse }
        return responses.removeFirst()
    }

    func uploadFile(
        at fileURL: URL,
        to url: URL,
        method: String,
        headers: [String: String]
    ) async throws -> RoomPublicationHTTPSResponse {
        _ = fileURL
        guard method == "PUT" else { throw RoomPublicationTransportError.invalidResponse }
        uploads.append(.init(url: url, headers: headers))
        return .init(statusCode: 200, data: Data())
    }

    func jsonBody(at index: Int) -> [String: Any]? {
        guard let body = requests[index].body,
              let object = try? JSONSerialization.jsonObject(with: body),
              let dictionary = object as? [String: Any]
        else { return nil }
        return dictionary
    }
}

@MainActor
private final class PublicationServiceConstructionCounter {
    var count = 0
}

@MainActor
private final class PublicationAvailabilityClient: ProfessionalAvailabilityClient {
    func fetchAvailability() async throws -> ProfessionalAvailability { .enabled }
}

@MainActor
private final class PublicationSessionClient: ProfessionalSessionClient {
    func prepareSignIn(operationID: UUID) async throws -> ProfessionalPreparedSession {
        .init(operationID: operationID, plaintextMaterial: Data([1]), wrappedMaterial: nil)
    }
    func commitPreparedSession(_ preparedSession: ProfessionalPreparedSession) { _ = preparedSession }
    func discardPreparedSession(operationID: UUID) { _ = operationID }
    func clearCommittedSessionMaterial() {}
}

private struct PublicationAuthenticationContextFactory: DeviceAuthenticationContextFactory {
    func makeContext() -> any DeviceAuthenticationContext { PublicationAuthenticationContext() }
}

private final class PublicationAuthenticationContext: DeviceAuthenticationContext, @unchecked Sendable {
    let evaluatedDomainState: Data? = Data([1])
    func preflight() -> DeviceAuthenticationPreflight { .available }
    func evaluate(
        reason: String,
        completion: @escaping @Sendable (DeviceAuthenticationEvaluation) -> Void
    ) {
        _ = reason
        completion(.success)
    }
    func invalidate() {}
}

private actor PublicationSensitiveActionGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var confirmation: CheckedContinuation<Bool, Never>?

    func confirm() async -> Bool {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            confirmation = continuation
        }
    }

    func waitForConfirmation() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func allow() {
        confirmation?.resume(returning: true)
        confirmation = nil
    }
}
