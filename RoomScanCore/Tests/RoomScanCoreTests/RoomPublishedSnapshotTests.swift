import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import RoomScanCore

final class RoomPublishedSnapshotTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_786_896_000)

    /// This catches an approval digest that omits any reviewed decision field,
    /// which would allow a changed review, source binding, or selection to
    /// retain the same purported publication approval identity.
    func testCanonicalApprovalSHA256BindsEveryApprovalFieldAndRejectsInvalidCandidates() async throws {
        let sourceBinding = RoomPublishedSourceBinding(
            publicRoomKey: "room-living",
            sourceRevision: sourceRevision()
        )
        let preparation = try await RoomPublishedSnapshotBuilder.prepare(
            draft: .room(roomPresentation()),
            sourceBindings: [sourceBinding],
            assets: publishedAssets()
        )
        let approval = preparation.makeApproval(
            reviewID: "approval-digest-review-001",
            reviewedAt: fixedDate
        )
        let digest = try RoomPublishedSnapshotDigests.approvalSHA256(approval)

        var changedReviewID = approval
        changedReviewID.reviewID = "approval-digest-review-002"
        XCTAssertNotEqual(try RoomPublishedSnapshotDigests.approvalSHA256(changedReviewID), digest)

        var changedReviewedAt = approval
        changedReviewedAt.reviewedAt = fixedDate.addingTimeInterval(1)
        XCTAssertNotEqual(try RoomPublishedSnapshotDigests.approvalSHA256(changedReviewedAt), digest)

        var changedSource = approval
        changedSource.sourceBindingsSHA256 = String(repeating: "a", count: 64)
        XCTAssertNotEqual(try RoomPublishedSnapshotDigests.approvalSHA256(changedSource), digest)

        var changedSelection = approval
        changedSelection.selectionManifestSHA256 = String(repeating: "b", count: 64)
        XCTAssertNotEqual(try RoomPublishedSnapshotDigests.approvalSHA256(changedSelection), digest)

        var rejected = approval
        rejected.decision = .rejected
        XCTAssertThrowsError(try RoomPublishedSnapshotDigests.approvalSHA256(rejected))

        var invalid = approval
        invalid.reviewID = ""
        XCTAssertThrowsError(try RoomPublishedSnapshotDigests.approvalSHA256(invalid))

        var mismatched = approval
        mismatched.selectionManifestSHA256 = String(repeating: "c", count: 64)
        XCTAssertThrowsError(
            try RoomPublishedSnapshotDigests.approvalSHA256(
                mismatched,
                expectedSourceBindingsSHA256: preparation.sourceBindingsSHA256,
                expectedSelectionManifestSHA256: preparation.selectionManifestSHA256
            )
        )
    }

    /// This catches a publication approval that is replayed after either its
    /// exact source binding or reviewed presentation/asset selection changed.
    func testApprovalRequiresExactSourceAndSelectionBindings() async throws {
        let presentation = roomPresentation()
        let assets = publishedAssets()
        let sourceBinding = RoomPublishedSourceBinding(
            publicRoomKey: "room-living",
            sourceRevision: sourceRevision()
        )

        let prepared = try await RoomPublishedSnapshotBuilder.prepare(
            draft: .room(presentation),
            sourceBindings: [sourceBinding],
            assets: assets
        )
        let approval = prepared.makeApproval(
            reviewID: "review-001",
            reviewedAt: fixedDate
        )
        XCTAssertNoThrow(try prepared.finalize(approval: approval))

        var changedSource = sourceBinding
        changedSource.sourceRevision.revisionID = "revision-002"
        let rebound = try await RoomPublishedSnapshotBuilder.prepare(
            draft: .room(presentation),
            sourceBindings: [changedSource],
            assets: assets
        )
        XCTAssertThrowsError(try rebound.finalize(approval: approval))

        var changedPresentation = presentation
        changedPresentation.room.qualityWarnings[0].message = "A different reviewed warning"
        let reselected = try await RoomPublishedSnapshotBuilder.prepare(
            draft: .room(changedPresentation),
            sourceBindings: [sourceBinding],
            assets: assets
        )
        XCTAssertThrowsError(try reselected.finalize(approval: approval))

        var changedConcept = presentation
        changedConcept.room.comparisons[0].label = "A different reviewed concept comparison"
        let reconcepted = try await RoomPublishedSnapshotBuilder.prepare(
            draft: .room(changedConcept),
            sourceBindings: [sourceBinding],
            assets: assets
        )
        XCTAssertThrowsError(try reconcepted.finalize(approval: approval))

        var changedBrand = presentation
        changedBrand.branding.businessName = "Northstar Design Group"
        let rebranded = try await RoomPublishedSnapshotBuilder.prepare(
            draft: .room(changedBrand),
            sourceBindings: [sourceBinding],
            assets: assets
        )
        XCTAssertThrowsError(try rebranded.finalize(approval: approval))

        var changedDownloads = presentation
        changedDownloads.downloads.galleryZIP = false
        let redownloaded = try await RoomPublishedSnapshotBuilder.prepare(
            draft: .room(changedDownloads),
            sourceBindings: [sourceBinding],
            assets: assets
        )
        XCTAssertThrowsError(try redownloaded.finalize(approval: approval))

        var changedAssets = assets
        changedAssets[2] = .raster(
            assetID: "image-original",
            publicRoomKey: "room-living",
            assetClass: .selectedImage,
            raster: .init(data: Self.safeJPEG, mediaType: .jpeg)
        )
        let reselectedBytes = try await RoomPublishedSnapshotBuilder.prepare(
            draft: .room(presentation),
            sourceBindings: [sourceBinding],
            assets: changedAssets
        )
        XCTAssertThrowsError(try reselectedBytes.finalize(approval: approval))

        let property = propertyPresentation()
        let propertyBindings = [
            sourceBinding,
            RoomPublishedSourceBinding(
                publicRoomKey: "room-kitchen",
                sourceRevision: secondSourceRevision()
            ),
        ]
        let propertyPrepared = try await RoomPublishedSnapshotBuilder.prepare(
            draft: .property(property),
            sourceBindings: propertyBindings,
            assets: propertyAssets()
        )
        let propertyApproval = propertyPrepared.makeApproval(
            reviewID: "review-property-001",
            reviewedAt: fixedDate
        )
        XCTAssertNoThrow(try propertyPrepared.finalize(approval: propertyApproval))
        var reordered = property
        reordered.rooms.reverse()
        let reorderedPrepared = try await RoomPublishedSnapshotBuilder.prepare(
            draft: .property(reordered),
            sourceBindings: Array(propertyBindings.reversed()),
            assets: propertyAssets()
        )
        XCTAssertThrowsError(try reorderedPrepared.finalize(approval: propertyApproval))
    }

    /// This catches a builder that copies a private package and merely removes
    /// known fields: the real archive must be exactly its allowlisted ledger.
    func testArchiveClosureKeepsPortalPresentationPrivateFieldFree() async throws {
        let root = temporaryDirectory("RoomPublishedArchive")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let archiveURL = root.appendingPathComponent("published.zip")
        let sourceBinding = RoomPublishedSourceBinding(
            publicRoomKey: "room-living",
            sourceRevision: sourceRevision()
        )
        let prepared = try await RoomPublishedSnapshotBuilder.prepare(
            draft: .room(roomPresentation()),
            sourceBindings: [sourceBinding],
            assets: publishedAssets()
        )
        let ready = try prepared.finalize(
            approval: prepared.makeApproval(reviewID: "review-001", reviewedAt: fixedDate)
        )

        let built = try await RoomPublicationArchive.build(
            ready: ready,
            archiveURL: archiveURL,
            workspaceURL: workspace
        )
        XCTAssertEqual(
            Set(built.receipt.entries.map(\.entryPath.value)),
            Set(["publication-manifest.json", "presentation.json"] + ready.preparation.preparedAssets.map(\.ledger.relativePath))
        )
        XCTAssertFalse(built.receipt.entries.contains { $0.entryPath.value.hasSuffix(".pdf") })
        XCTAssertFalse(built.receipt.entries.contains { $0.entryPath.value.hasSuffix(".zip") })

        let extraction = root.appendingPathComponent("extraction", isDirectory: true)
        try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: true)
        let validated = try await RoomPublicationArchive.extractAndValidate(
            archiveURL: archiveURL,
            into: extraction
        )
        XCTAssertEqual(validated.manifest, built.manifest)
        let presentation = String(decoding: validated.presentationData, as: UTF8.self)
        for privateCanary in [
            "project-001", "revision-001", "epoch-001",
            sourceBinding.sourceRevision.semanticSHA256,
            sourceBinding.sourceRevision.revisionManifestSHA256,
        ] {
            XCTAssertFalse(presentation.contains(privateCanary), privateCanary)
        }

        let rebuiltSource = root.appendingPathComponent("rebuilt-source", isDirectory: true)
        try FileManager.default.createDirectory(at: rebuiltSource, withIntermediateDirectories: true)
        _ = try await RoomDeterministicZIP.extractVerifiedStoreEntries(
            from: archiveURL,
            into: rebuiltSource
        )
        var inputs: [RoomZIPInput] = built.receipt.entries.map { entry in
            RoomZIPInput(
                sourceURL: rebuiltSource.appendingPathComponent(entry.entryPath.value),
                entryPath: entry.entryPath,
                mediaType: entry.entryPath.value.hasSuffix(".json") ? "application/json" : "application/octet-stream"
            )
        }
        let injectedURL = rebuiltSource.appendingPathComponent("raw/raw-rgb.bin")
        try FileManager.default.createDirectory(at: injectedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("raw-frame-positive-control".utf8).write(to: injectedURL, options: .withoutOverwriting)
        inputs.append(.init(
            sourceURL: injectedURL,
            entryPath: try RoomExportEntryPath("raw/raw-rgb.bin"),
            mediaType: "application/octet-stream"
        ))
        let injectedArchive = root.appendingPathComponent("injected.zip")
        _ = try await RoomDeterministicZIP.write(inputs: inputs, to: injectedArchive)
        let injectedExtraction = root.appendingPathComponent("injected-extraction", isDirectory: true)
        try FileManager.default.createDirectory(at: injectedExtraction, withIntermediateDirectories: true)
        do {
            _ = try await RoomPublicationArchive.extractAndValidate(
                archiveURL: injectedArchive,
                into: injectedExtraction
            )
            XCTFail("An unledgered raw archive entry must fail closure validation.")
        } catch {
            // The valid archive above is the positive control proving this
            // negative probe reaches the real extractor and ledger boundary.
        }
    }

    /// This catches permissive Codable decoding that silently drops an injected
    /// private field or cross-room spatial claim from a portal-safe document.
    func testPublishedDocumentsRejectPrivateFieldsAndPropertySpatialClaims() throws {
        let room = roomPresentation()
        let roomData = try RoomRedesignCanonicalJSON.encode(room)
        guard case let .publishedRoomSnapshot(decoded) = try RoomRedesignContractValidator.validate(data: roomData) else {
            return XCTFail("Expected the additive room-v2 registry document.")
        }
        XCTAssertEqual(decoded, room)

        for forbidden in [
            "rawRGB", "rawDepth", "rawConfidence", "diagnostics", "worldMap",
            "privateNotes", "revisionHistory", "preciseGPS", "gps", "latitude",
            "longitude", "horizontalAccuracyMeters", "projectID", "revisionID",
            "workspaceID", "snapshotID", "sourceRevision", "sourceDigest",
            "sourceBindings", "sourceBindingsSHA256", "selectionManifestSHA256",
            "presentationSHA256", "approval", "reviewID", "objectKey", "storageKey",
            "linkToken", "accessToken", "audit", "email",
        ] {
            XCTAssertThrowsError(
                try RoomRedesignContractValidator.validate(
                    data: injectingJSONMember(forbidden, into: roomData, at: "room")
                ),
                forbidden
            )
        }

        var secondRoom = room.room
        secondRoom.roomKey = "room-kitchen"
        secondRoom.displayName = "Kitchen"
        let property = RoomPublishedPropertyPresentationV1(
            propertyTitle: "Sample property",
            rooms: [room.room, secondRoom],
            branding: room.branding,
            downloads: room.downloads
        )
        let propertyData = try RoomRedesignCanonicalJSON.encode(property)
        guard case let .publishedPropertySnapshot(decodedProperty) = try RoomRedesignContractValidator.validate(data: propertyData) else {
            return XCTFail("Expected the additive property-v1 registry document.")
        }
        XCTAssertEqual(decodedProperty.independentRoomNotice, RoomPublishedPropertyPresentationV1.independentRoomNotice)
        XCTAssertThrowsError(
            try RoomRedesignContractValidator.validate(
                data: injectingJSONMember("alignment", into: propertyData, at: "$")
            )
        )
        for spatialClaim in [
            "transform", "coordinates", "connectivity", "reconstruction",
            "adjacency", "sharedOrigin",
        ] {
            XCTAssertThrowsError(
                try RoomRedesignContractValidator.validate(
                    data: injectingJSONMember(spatialClaim, into: propertyData, at: "$")
                ),
                spatialClaim
            )
        }
    }

    /// The builder delegates image byte classification to the actual Core image
    /// validator instead of trusting names, extensions, or test-only parsers.
    func testBuilderRejectsUnsafeRasterPayloadsWithRealImageValidator() async throws {
        let binding = RoomPublishedSourceBinding(
            publicRoomKey: "room-living",
            sourceRevision: sourceRevision()
        )
        _ = try await RoomPublishedSnapshotBuilder.prepare(
            draft: .room(roomPresentation()),
            sourceBindings: [binding],
            assets: publishedAssets()
        )

        let metadataPNG = try pngWithMetadataChunk(type: "tEXt", payload: Data("Private XMP-like payload".utf8))
        let unsafePayloads: [(String, Data, RoomPublishedRasterMediaType)] = [
            ("svg", Data("<svg onload=alert(1)></svg>".utf8), .png),
            ("html", Data("<html><script>alert(1)</script></html>".utf8), .png),
            ("png polyglot trailing ZIP", Self.safePNG + Data([0x50, 0x4b, 0x03, 0x04]), .png),
            ("jpeg EXIF GPS", jpegWithMetadata("Exif\\0\\0GPS=42.0000"), .jpeg),
            ("jpeg private XMP", jpegWithMetadata("http://ns.adobe.com/xap/1.0/ private"), .jpeg),
            ("png auxiliary metadata", metadataPNG, .png),
            ("renamed PNG as JPEG", Self.safePNG, .jpeg),
        ]
        for (label, data, mediaType) in unsafePayloads {
            var assets = publishedAssets()
            assets[1] = .raster(
                assetID: "floor-plan-001",
                publicRoomKey: "room-living",
                assetClass: .floorPlan,
                raster: .init(data: data, mediaType: mediaType)
            )
            await assertThrowsAsync(label) {
                _ = try await RoomPublishedSnapshotBuilder.prepare(
                    draft: .room(self.roomPresentation()),
                    sourceBindings: [binding],
                    assets: assets
                )
            }
        }
    }

    /// `RoomConceptImageValidator` intentionally permits unknown safe-to-copy
    /// PNG ancillary chunks and some JPEG APP markers for Concept Set
    /// compatibility. Publications have a narrower privacy boundary: prove
    /// both accepted source-validator controls reach the builder before the
    /// publication profile rejects them.
    func testBuilderRejectsCRCValidPNGAncillaryAndEveryJPEGAPPMarker() async throws {
        let binding = RoomPublishedSourceBinding(
            publicRoomKey: "room-living",
            sourceRevision: sourceRevision()
        )
        let privatePNG = try pngWithMetadataChunk(
            type: "prIV",
            payload: Data("private ancillary bytes positive-control".utf8)
        )
        let app3 = jpegWithAPP(
            marker: 0xe3,
            payload: Data("private APP3 bytes positive-control".utf8)
        )
        XCTAssertNoThrow(
            try RoomConceptImageValidator.validateSanitizedImage(privatePNG, mediaType: "image/png"),
            "Control: the shared Concept Set validator permits this CRC-valid ancillary chunk."
        )
        XCTAssertNoThrow(
            try RoomConceptImageValidator.validateSanitizedImage(app3, mediaType: "image/jpeg"),
            "Control: the shared Concept Set validator permits APP3 framing."
        )

        await assertBuilderRejectsFloorPlan(
            privatePNG,
            mediaType: .png,
            binding: binding,
            label: "CRC-valid private PNG ancillary chunk"
        )
        await assertBuilderRejectsFloorPlan(
            app3,
            mediaType: .jpeg,
            binding: binding,
            label: "JPEG APP3 payload"
        )
        for marker in UInt8(0xe0)...UInt8(0xef) {
            await assertBuilderRejectsFloorPlan(
                jpegWithAPP(marker: marker, payload: Data([marker, 0x41, 0x49])),
                mediaType: .jpeg,
                binding: binding,
                label: String(format: "JPEG APP%02X payload", marker)
            )
        }
        _ = try await RoomPublishedSnapshotBuilder.prepare(
            draft: .room(roomPresentation()),
            sourceBindings: [binding],
            assets: publishedAssets()
        )
        var jpegAssets = publishedAssets()
        jpegAssets[1] = .raster(
            assetID: "floor-plan-001",
            publicRoomKey: "room-living",
            assetClass: .floorPlan,
            raster: .init(data: Self.safeJPEG, mediaType: .jpeg)
        )
        _ = try await RoomPublishedSnapshotBuilder.prepare(
            draft: .room(roomPresentation()),
            sourceBindings: [binding],
            assets: jpegAssets
        )
    }

    /// A PNG can remain recoverable to ImageIO while carrying extra malformed
    /// IDAT bytes. The builder must decode and fresh-encode it, never copy the
    /// original byte carrier into its ledger or publication ZIP.
    func testBuilderFreshReencodesRecoverableMalformedPNGByteCarrier() async throws {
        let binding = RoomPublishedSourceBinding(
            publicRoomKey: "room-living",
            sourceRevision: sourceRevision()
        )
        let recoverablePNG = try Self.pngWithRecoverableIDATCanary()

        XCTAssertNoThrow(
            try RoomConceptImageValidator.validateSanitizedImage(recoverablePNG, mediaType: "image/png"),
            "Control: the shared parser intentionally checks framing/CRC, not pixel decode."
        )
        XCTAssertNoThrow(try Self.forceImageIODecode(Self.safePNG, type: .png))
        XCTAssertNoThrow(try Self.forceImageIODecode(Self.safeJPEG, type: .jpeg))
        XCTAssertNoThrow(try Self.forceImageIODecode(recoverablePNG, type: .png))

        var assets = publishedAssets()
        assets[1] = .raster(
            assetID: "floor-plan-001",
            publicRoomKey: "room-living",
            assetClass: .floorPlan,
            raster: .init(data: recoverablePNG, mediaType: .png)
        )
        let prepared = try await RoomPublishedSnapshotBuilder.prepare(
            draft: .room(roomPresentation()),
            sourceBindings: [binding],
            assets: assets
        )
        let preparedPNG = try preparedData(assetID: "floor-plan-001", from: prepared)
        XCTAssertNotEqual(preparedPNG, recoverablePNG)
        XCTAssertNil(preparedPNG.range(of: Self.malformedIDATCanary))

        let root = temporaryDirectory("RoomPublishedDecodedRaster")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let ready = try prepared.finalize(
            approval: prepared.makeApproval(reviewID: "decoded-raster-review", reviewedAt: fixedDate)
        )
        let built = try await RoomPublicationArchive.build(
            ready: ready,
            archiveURL: root.appendingPathComponent("published.zip"),
            workspaceURL: workspace
        )
        let archiveBytes = try Data(contentsOf: built.archiveURL)
        XCTAssertNil(archiveBytes.range(of: Self.malformedIDATCanary))
        let extraction = root.appendingPathComponent("extraction", isDirectory: true)
        try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: true)
        let validated = try await RoomPublicationArchive.extractAndValidate(
            archiveURL: built.archiveURL,
            into: extraction
        )
        XCTAssertEqual(validated.manifest, built.manifest)
    }

    /// ImageIO can recover a late malformed scanline. The whole image is still
    /// decoded into a full-size surface, then only fresh encoder bytes may
    /// enter a publication ledger or archive.
    func testBuilderFreshReencodesLateRecoveredPNGByteCarrier() async throws {
        let binding = RoomPublishedSourceBinding(
            publicRoomKey: "room-living",
            sourceRevision: sourceRevision()
        )
        let recoverablePNG = try Self.pngWithLateRecoverableIDATCanary()
        XCTAssertNoThrow(
            try RoomConceptImageValidator.validateSanitizedImage(recoverablePNG, mediaType: "image/png")
        )
        XCTAssertNoThrow(
            try Self.forceImageIODecode(recoverablePNG, type: .png),
            "Control: full-size ImageIO rendering recovers this malformed late scanline."
        )
        var assets = publishedAssets()
        assets[1] = .raster(
            assetID: "floor-plan-001",
            publicRoomKey: "room-living",
            assetClass: .floorPlan,
            raster: .init(data: recoverablePNG, mediaType: .png)
        )
        let prepared = try await RoomPublishedSnapshotBuilder.prepare(
            draft: .room(roomPresentation()),
            sourceBindings: [binding],
            assets: assets
        )
        let publishedPNG = try preparedData(assetID: "floor-plan-001", from: prepared)
        XCTAssertNotEqual(publishedPNG, recoverablePNG)
        XCTAssertNil(publishedPNG.range(of: Self.lateMalformedIDATCanary))
        let publishedInfo = try RoomConceptImageValidator.validateSanitizedImage(
            publishedPNG,
            mediaType: "image/png"
        )
        XCTAssertEqual(publishedInfo.pixelWidth, 1)
        XCTAssertEqual(publishedInfo.pixelHeight, 2)
    }

    /// This IDAT decompresses to an invalid PNG filter byte. It is CRC-valid
    /// and passes the shared framing parser, but the complete production
    /// raster path must reject it before selection.
    func testBuilderRejectsStructurallyValidPNGWithUndecodableIDAT() async throws {
        let binding = RoomPublishedSourceBinding(
            publicRoomKey: "room-living",
            sourceRevision: sourceRevision()
        )
        let invalidPNG = try Self.pngWithInvalidIDATPayload()
        XCTAssertNoThrow(
            try RoomConceptImageValidator.validateSanitizedImage(invalidPNG, mediaType: "image/png")
        )
        await assertBuilderRejectsFloorPlan(
            invalidPNG,
            mediaType: .png,
            binding: binding,
            label: "CRC-valid PNG with undecodable IDAT payload"
        )
    }

    /// This JPEG keeps valid SOF/SOS framing but asks for a Huffman table that
    /// does not exist, so entropy decoding must reject it before selection.
    func testBuilderRejectsStructurallyValidJPEGWithInvalidEntropy() async throws {
        let binding = RoomPublishedSourceBinding(
            publicRoomKey: "room-living",
            sourceRevision: sourceRevision()
        )
        let invalidJPEG = try Self.jpegWithInvalidEntropy(Self.safeJPEG)
        XCTAssertNoThrow(
            try RoomConceptImageValidator.validateSanitizedImage(invalidJPEG, mediaType: "image/jpeg")
        )
        await assertBuilderRejectsFloorPlan(
            invalidJPEG,
            mediaType: .jpeg,
            binding: binding,
            label: "structurally valid JPEG with invalid entropy table binding"
        )
    }

    /// The publication path must not trust a caller's filename, package ID, or
    /// prior local parse. This uses the real fixture-derived AI package
    /// builder, its archive builder, the generic deterministic ZIP writer, and
    /// the production `.aiReadyPackage` input path end-to-end.
    func testAIReadyPackageInputRevalidatesRealArchiveBindingsAndClosure() async throws {
        let root = temporaryDirectory("RoomPublishedAIReady")
        defer { try? FileManager.default.removeItem(at: root) }

        let safeRoot = root.appendingPathComponent("safe", isDirectory: true)
        try FileManager.default.createDirectory(at: safeRoot, withIntermediateDirectories: true)
        let safeArchive = try await buildFixtureAIArchive(
            named: "valid-ai-ready-v1.json",
            in: safeRoot,
            archiveName: "ai-ready-download.zip"
        )
        XCTAssertEqual(safeArchive.package.profile, .aiReady)
        XCTAssertFalse(safeArchive.package.artifacts.contains {
            $0.artifactClass.isAIRawEvidence && $0.disposition == .included
        })

        let sourceBinding = RoomPublishedSourceBinding(
            publicRoomKey: "room-living",
            sourceRevision: safeArchive.package.sourceRevision
        )
        let safePrepared = try await RoomPublishedSnapshotBuilder.prepare(
            draft: .room(roomPresentationWithAIReadyDownload()),
            sourceBindings: [sourceBinding],
            assets: aiReadyPublishedAssets(
                archiveURL: safeArchive.archiveURL,
                expectedPackageID: safeArchive.package.packageID
            )
        )
        let safeLedger = try XCTUnwrap(safePrepared.preparedAssets.first {
            $0.ledger.assetClass == .aiReadyPackage
        }?.ledger)
        XCTAssertEqual(safeLedger.aiReadyPackageBinding?.packageID, safeArchive.package.packageID)
        XCTAssertEqual(safeLedger.aiReadyPackageBinding?.artifactPlanSHA256, safeArchive.package.artifactPlanSHA256)
        XCTAssertEqual(safeLedger.aiReadyPackageBinding?.selectionSHA256, safeArchive.package.selectionSHA256)

        // Building performs a post-build extraction revalidation. Repeat the
        // extractor explicitly as the safe control for the embedded AI ZIP
        // branch that every actual portal archive will take.
        let publishedWorkspace = safeRoot.appendingPathComponent("publication-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: publishedWorkspace, withIntermediateDirectories: true)
        let safeReady = try safePrepared.finalize(
            approval: safePrepared.makeApproval(
                reviewID: "ai-ready-publication-review",
                reviewedAt: fixedDate
            )
        )
        let published = try await RoomPublicationArchive.build(
            ready: safeReady,
            archiveURL: safeRoot.appendingPathComponent("published-with-ai-ready.zip"),
            workspaceURL: publishedWorkspace
        )
        let safeExtraction = safeRoot.appendingPathComponent("published-extraction", isDirectory: true)
        try FileManager.default.createDirectory(at: safeExtraction, withIntermediateDirectories: true)
        let safeValidation = try await RoomPublicationArchive.extractAndValidate(
            archiveURL: published.archiveURL,
            into: safeExtraction
        )
        XCTAssertEqual(safeValidation.manifest, published.manifest)

        // A generic ZIP writer can construct an extra nested entry. Forge a
        // self-consistent *outer* ledger/control digest around it so outer
        // identity checks pass and the test reaches the production nested AI
        // extraction branch instead of stopping at a simple outer hash error.
        let tamperRoot = root.appendingPathComponent("outer-tamper", isDirectory: true)
        try FileManager.default.createDirectory(at: tamperRoot, withIntermediateDirectories: true)
        let tamperedAIArchive = try await archiveWithUnledgeredAIEntry(
            from: safeArchive.archiveURL,
            in: tamperRoot
        )
        let forgedOuterArchive = try await forgePublicationArchive(
            from: published,
            replacingAIArchiveWith: tamperedAIArchive,
            in: tamperRoot
        )
        let forgedExtraction = tamperRoot.appendingPathComponent("forged-extraction", isDirectory: true)
        try FileManager.default.createDirectory(at: forgedExtraction, withIntermediateDirectories: true)
        do {
            _ = try await RoomPublicationArchive.extractAndValidate(
                archiveURL: forgedOuterArchive,
                into: forgedExtraction
            )
            XCTFail("A self-consistent outer control must still reject the tampered embedded AI ZIP.")
        } catch let error as RoomAIRoomPackageError {
            XCTAssertEqual(error, .archiveClosureMismatch("entry-paths"))
        }

        await assertAIReadyPublicationRejects(
            archiveURL: safeArchive.archiveURL,
            expectedPackageID: "wrong-package-binding",
            sourceBinding: sourceBinding,
            label: "wrong package binding"
        )

        var wrongSource = safeArchive.package.sourceRevision
        wrongSource.revisionID = "revision-other"
        await assertAIReadyPublicationRejects(
            archiveURL: safeArchive.archiveURL,
            expectedPackageID: safeArchive.package.packageID,
            sourceBinding: .init(publicRoomKey: "room-living", sourceRevision: wrongSource),
            label: "wrong exact source revision binding"
        )

        // This archive is genuinely Complete and carries raw evidence, but it
        // wears an AI-ready-looking filename. The publication profile check
        // must reject the bytes rather than trusting the name or extension.
        let completeRoot = root.appendingPathComponent("complete", isDirectory: true)
        try FileManager.default.createDirectory(at: completeRoot, withIntermediateDirectories: true)
        let renamedComplete = try await buildFixtureAIArchive(
            named: "valid-ai-complete-v1.json",
            in: completeRoot,
            archiveName: "ai-ready-download.zip"
        )
        XCTAssertEqual(renamedComplete.package.profile, .complete)
        XCTAssertTrue(renamedComplete.package.artifacts.contains {
            $0.artifactClass.isAIRawEvidence && $0.disposition == .included
        })
        await assertAIReadyPublicationRejects(
            archiveURL: renamedComplete.archiveURL,
            expectedPackageID: renamedComplete.package.packageID,
            sourceBinding: .init(
                publicRoomKey: "room-living",
                sourceRevision: renamedComplete.package.sourceRevision
            ),
            label: "renamed Complete raw/private archive"
        )

        // The generic deterministic ZIP writer intentionally permits another
        // entry; the AI archive validator is the ledger-closure boundary that
        // must reject it when publication prepares the download.
        let unledgeredRoot = root.appendingPathComponent("unledgered", isDirectory: true)
        try FileManager.default.createDirectory(at: unledgeredRoot, withIntermediateDirectories: true)
        let unledgeredArchive = try await archiveWithUnledgeredAIEntry(
            from: safeArchive.archiveURL,
            in: unledgeredRoot
        )
        await assertAIReadyPublicationRejects(
            archiveURL: unledgeredArchive,
            expectedPackageID: safeArchive.package.packageID,
            sourceBinding: sourceBinding,
            label: "unledgered nested raw archive entry"
        )
    }

    /// The Core candidate only proves exact local digest binding. It does not
    /// contain a hosted identity, role, tenant, flag, quota, or persistence
    /// authority; service publication must independently authorize and record
    /// approval before promoting an upload candidate.
    func testLocalApprovalCandidateRetainsExactImmutablePreparationOnly() async throws {
        let binding = RoomPublishedSourceBinding(
            publicRoomKey: "room-living",
            sourceRevision: sourceRevision()
        )
        let preparation = try await RoomPublishedSnapshotBuilder.prepare(
            draft: .room(roomPresentation()),
            sourceBindings: [binding],
            assets: publishedAssets()
        )
        let localApproval = preparation.makeApproval(
            reviewID: "local-review-candidate",
            reviewedAt: fixedDate
        )
        let ready = try preparation.finalize(approval: localApproval)
        XCTAssertEqual(ready.preparation, preparation)
        XCTAssertEqual(ready.approval, localApproval)

        var forgedApproval = localApproval
        forgedApproval.selectionManifestSHA256 = String(repeating: "f", count: 64)
        XCTAssertThrowsError(try preparation.finalize(approval: forgedApproval))
    }

    func testPublishedDocumentsRequireCanonicalBytesAndArchiveControlClosure() async throws {
        let roomData = try RoomRedesignCanonicalJSON.encode(roomPresentation())
        XCTAssertThrowsError(
            try RoomRedesignContractValidator.validate(data: Data(" ".utf8) + roomData),
            "Whitespace is noncanonical even though normal JSON decoding would accept it."
        )

        let root = temporaryDirectory("RoomPublishedCanonical")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let binding = RoomPublishedSourceBinding(
            publicRoomKey: "room-living",
            sourceRevision: sourceRevision()
        )
        let prepared = try await RoomPublishedSnapshotBuilder.prepare(
            draft: .room(roomPresentation()),
            sourceBindings: [binding],
            assets: publishedAssets()
        )
        let ready = try prepared.finalize(
            approval: prepared.makeApproval(reviewID: "review-canonical-001", reviewedAt: fixedDate)
        )
        let built = try await RoomPublicationArchive.build(
            ready: ready,
            archiveURL: root.appendingPathComponent("published.zip"),
            workspaceURL: workspace
        )
        guard case let .publicationArchive(manifest) = try RoomRedesignContractValidator.validate(data: built.manifestData) else {
            return XCTFail("Expected the additive publication archive control document.")
        }
        XCTAssertEqual(manifest, built.manifest)
        XCTAssertThrowsError(
            try RoomRedesignContractValidator.validate(
                data: injectingJSONMember("rawRGB", into: built.manifestData, at: "$")
            ),
            "The private control manifest must also be a closed document."
        )
    }

    /// This catches a Core/service fixture drift where an archive remains
    /// individually valid but no longer has the exact byte, ledger, approval,
    /// or public-presentation identity that the TypeScript validator must
    /// consume. The checked fixture bytes are never generated by a test-only
    /// ZIP encoder: both candidates flow through the production builder,
    /// approval, archive builder, and archive extractor.
    func testPublicationGoldenFixturesMatchExactProductionArchivesAndRelationships() async throws {
        let builtSet = try await buildPublicationGoldenFixtureSet()
        defer { try? FileManager.default.removeItem(at: builtSet.rootURL) }

        let fixtureDirectory = publicationFixtureDirectory()
        guard FileManager.default.fileExists(atPath: fixtureDirectory.path) else {
            try printPublicationGoldenFixtureCapture(for: builtSet.fixtures)
            XCTFail("Publication golden fixtures are absent. Deliberate capture values were printed; add them without rewriting fixtures in the test.")
            return
        }

        let expectedFileNames: Set<String> = [
            "expectations.json",
            "room-v2-ai-ready.zip.base64",
            "property-v1.zip.base64",
        ]
        let actualFileNames = Set(try FileManager.default.contentsOfDirectory(atPath: fixtureDirectory.path))
        XCTAssertEqual(actualFileNames, expectedFileNames, "The cross-runtime fixture directory is closed.")

        let expectationsURL = fixtureDirectory.appendingPathComponent("expectations.json")
        guard FileManager.default.fileExists(atPath: expectationsURL.path) else {
            try printPublicationGoldenFixtureCapture(for: builtSet.fixtures)
            XCTFail("Publication golden expectations are absent. Deliberate capture values were printed.")
            return
        }
        let expectations = try decodePublicationGoldenExpectations(
            from: Data(contentsOf: expectationsURL)
        )
        XCTAssertEqual(expectations.schemaVersion, PublicationGoldenExpectationDocument.schemaVersionValue)
        XCTAssertEqual(
            expectations.fixtures.map(\.name),
            ["room-v2-ai-ready", "property-v1"],
            "Fixture order is part of the deterministic cross-runtime contract."
        )
        XCTAssertEqual(
            builtSet.fixtures.map(\.name),
            expectations.fixtures.map(\.name),
            "The production builder must produce exactly the checked fixture set."
        )

        for built in builtSet.fixtures {
            let expected = try XCTUnwrap(expectations.fixtures.first { $0.name == built.name })
            let fixtureURL = fixtureDirectory.appendingPathComponent("\(built.name).zip.base64")
            guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
                try printPublicationGoldenFixtureCapture(for: builtSet.fixtures)
                XCTFail("Missing base64 fixture for \(built.name).")
                continue
            }
            let fixtureArchiveData = try decodePublicationGoldenArchive(
                from: Data(contentsOf: fixtureURL)
            )
            let failures = try publicationGoldenComparisonFailures(
                built: built,
                fixtureArchiveData: fixtureArchiveData,
                expected: expected
            )
            if !failures.isEmpty {
                try printPublicationGoldenFixtureCapture(for: builtSet.fixtures)
                XCTFail("Golden fixture \(built.name) drifted: \(failures.joined(separator: "; "))")
                continue
            }

            let extraction = builtSet.rootURL.appendingPathComponent(
                "extract-\(built.name)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: true)
            let validation = try await RoomPublicationArchive.extractAndValidate(
                archiveURL: built.result.archiveURL,
                into: extraction
            )
            XCTAssertEqual(validation.manifest, built.result.manifest)
            XCTAssertEqual(validation.presentationData, built.result.presentationData)
            let extractedEntryByPath = Dictionary(uniqueKeysWithValues: validation.entries.map {
                ($0.entryPath.value, $0)
            })
            let extractedLedger: [PublicationGoldenLedgerEntry] = try validation.manifest.assets.map { asset in
                guard let entry = extractedEntryByPath[asset.relativePath] else {
                    throw RoomRedesignContractValidationError.invalidValue(
                        path: "archive.entries",
                        reason: "The production extractor omitted one allowlisted publication asset."
                    )
                }
                return .init(
                    path: asset.relativePath,
                    byteCount: entry.byteCount,
                    sha256: entry.sha256Hex,
                    mediaType: asset.mediaType
                )
            }
            XCTAssertEqual(
                extractedLedger,
                expected.ledger,
                "The production extractor must reproduce the exact checked allowlist ledger."
            )
            try assertPublicGoldenPresentation(
                validation.presentationData,
                expectedKind: built.result.manifest.snapshotKind
            )

            let expectedApprovalDigest = try RoomPublishedSnapshotDigests.approvalSHA256(
                validation.manifest.approval,
                expectedSourceBindingsSHA256: validation.manifest.sourceBindingsSHA256,
                expectedSelectionManifestSHA256: validation.manifest.selectionManifestSHA256
            )
            XCTAssertEqual(expectedApprovalDigest, expected.approvalSHA256)

            switch built.name {
            case "room-v2-ai-ready":
                XCTAssertEqual(validation.manifest.snapshotKind, .room)
                XCTAssertEqual(validation.manifest.sourceBindings.count, 1)
                XCTAssertEqual(validation.manifest.assets.filter { $0.assetClass == .webGeometry }.count, 1)
                XCTAssertTrue(validation.manifest.assets.contains { $0.mediaType == "image/png" })
                XCTAssertTrue(validation.manifest.assets.contains { $0.mediaType == "image/jpeg" })
                XCTAssertEqual(validation.manifest.assets.filter { $0.assetClass == .aiReadyPackage }.count, 1)
            case "property-v1":
                XCTAssertEqual(validation.manifest.snapshotKind, .property)
                XCTAssertEqual(
                    validation.manifest.sourceBindings.map(\.publicRoomKey),
                    ["room-living", "room-kitchen"],
                    "Property source bindings are independently ordered room bindings, not a shared reconstruction."
                )
                XCTAssertEqual(validation.manifest.assets.filter { $0.assetClass == .webGeometry }.count, 2)
            default:
                XCTFail("Unexpected fixture name \(built.name).")
            }
        }

        // Positive control: mutate a real checked archive byte. The exact-byte
        // and SHA-256 comparison must report the drift instead of merely
        // exercising a dormant test branch.
        let roomBuilt = try XCTUnwrap(builtSet.fixtures.first { $0.name == "room-v2-ai-ready" })
        let roomExpected = try XCTUnwrap(expectations.fixtures.first { $0.name == "room-v2-ai-ready" })
        var oneByteMutatedArchive = roomBuilt.archiveData
        let firstByte = oneByteMutatedArchive.startIndex
        oneByteMutatedArchive[firstByte] = oneByteMutatedArchive[firstByte] ^ 0x01
        let positiveControlFailures = try publicationGoldenComparisonFailures(
            built: roomBuilt,
            fixtureArchiveData: oneByteMutatedArchive,
            expected: roomExpected
        )
        XCTAssertTrue(positiveControlFailures.contains("archive exact bytes"))
        XCTAssertTrue(positiveControlFailures.contains("archive SHA-256"))
    }

    private func buildPublicationGoldenFixtureSet() async throws -> PublicationGoldenFixtureSet {
        let rootURL = temporaryDirectory("RoomPublicationGoldenFixture")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        do {
            let aiRoot = rootURL.appendingPathComponent("room-ai", isDirectory: true)
            try FileManager.default.createDirectory(at: aiRoot, withIntermediateDirectories: true)
            let aiReady = try await buildFixtureAIArchive(
                named: "valid-ai-ready-v1.json",
                in: aiRoot,
                archiveName: "golden-ai-ready.zip"
            )

            let roomBinding = RoomPublishedSourceBinding(
                publicRoomKey: "room-living",
                sourceRevision: aiReady.package.sourceRevision
            )
            let roomPreparation = try await RoomPublishedSnapshotBuilder.prepare(
                draft: .room(roomPresentationWithAIReadyDownload()),
                sourceBindings: [roomBinding],
                assets: goldenRoomAssets(
                    aiReadyArchiveURL: aiReady.archiveURL,
                    expectedPackageID: aiReady.package.packageID
                )
            )
            let roomReady = try roomPreparation.finalize(
                approval: roomPreparation.makeApproval(
                    reviewID: "golden-room-review-001",
                    reviewedAt: fixedDate
                )
            )
            let roomWorkspace = rootURL.appendingPathComponent("room-workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: roomWorkspace, withIntermediateDirectories: true)
            let roomResult = try await RoomPublicationArchive.build(
                ready: roomReady,
                archiveURL: rootURL.appendingPathComponent("room-v2-ai-ready.zip"),
                workspaceURL: roomWorkspace
            )

            let propertyBindings = [
                RoomPublishedSourceBinding(
                    publicRoomKey: "room-living",
                    sourceRevision: sourceRevision()
                ),
                RoomPublishedSourceBinding(
                    publicRoomKey: "room-kitchen",
                    sourceRevision: secondSourceRevision()
                ),
            ]
            let propertyPreparation = try await RoomPublishedSnapshotBuilder.prepare(
                draft: .property(propertyPresentation()),
                sourceBindings: propertyBindings,
                assets: propertyAssets()
            )
            let propertyReady = try propertyPreparation.finalize(
                approval: propertyPreparation.makeApproval(
                    reviewID: "golden-property-review-001",
                    reviewedAt: fixedDate
                )
            )
            let propertyWorkspace = rootURL.appendingPathComponent("property-workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: propertyWorkspace, withIntermediateDirectories: true)
            let propertyResult = try await RoomPublicationArchive.build(
                ready: propertyReady,
                archiveURL: rootURL.appendingPathComponent("property-v1.zip"),
                workspaceURL: propertyWorkspace
            )

            return .init(
                rootURL: rootURL,
                fixtures: [
                    try PublicationGoldenFixtureBuilt(
                        name: "room-v2-ai-ready",
                        result: roomResult
                    ),
                    try PublicationGoldenFixtureBuilt(
                        name: "property-v1",
                        result: propertyResult
                    ),
                ]
            )
        } catch {
            try? FileManager.default.removeItem(at: rootURL)
            throw error
        }
    }

    private func goldenRoomAssets(
        aiReadyArchiveURL: URL,
        expectedPackageID: String
    ) -> [RoomPublishedAssetInput] {
        var assets = publishedAssets()
        assets[2] = .raster(
            assetID: "image-original",
            publicRoomKey: "room-living",
            assetClass: .selectedImage,
            raster: .init(data: Self.safeJPEG, mediaType: .jpeg)
        )
        assets.append(.aiReadyPackage(
            assetID: "ai-ready-001",
            input: .init(
                archiveURL: aiReadyArchiveURL,
                publicRoomKey: "room-living",
                expectedPackageID: expectedPackageID
            )
        ))
        return assets
    }

    private func publicationFixtureDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HostedService", isDirectory: true)
            .appendingPathComponent("fixtures", isDirectory: true)
            .appendingPathComponent("publication", isDirectory: true)
    }

    private func decodePublicationGoldenExpectations(
        from data: Data
    ) throws -> PublicationGoldenExpectationDocument {
        let rootObject: Any
        do {
            rootObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw RoomRedesignContractValidationError.invalidJSON
        }
        guard let root = rootObject as? [String: Any] else {
            throw RoomRedesignContractValidationError.rootMustBeObject
        }
        try requireGoldenKeys(root, exact: ["schemaVersion", "fixtures"], at: "$")
        guard let fixtures = root["fixtures"] as? [[String: Any]] else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "$.fixtures",
                reason: "Golden fixture expectations need an ordered fixture object list."
            )
        }
        for (index, fixture) in fixtures.enumerated() {
            try requireGoldenKeys(
                fixture,
                exact: [
                    "name", "archive", "publicationManifest", "presentation",
                    "sourceBindingsSHA256", "selectionManifestSHA256", "approvalSHA256", "ledger",
                ],
                at: "$.fixtures[\(index)]"
            )
            for key in ["archive", "publicationManifest", "presentation"] {
                guard let digest = fixture[key] as? [String: Any] else {
                    throw RoomRedesignContractValidationError.invalidValue(
                        path: "$.fixtures[\(index)].\(key)",
                        reason: "Fixture identities must be objects."
                    )
                }
                try requireGoldenKeys(digest, exact: ["byteCount", "sha256"], at: "$.fixtures[\(index)].\(key)")
            }
            guard let ledger = fixture["ledger"] as? [[String: Any]] else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: "$.fixtures[\(index)].ledger",
                    reason: "Fixture ledger must be an ordered object list."
                )
            }
            for (ledgerIndex, entry) in ledger.enumerated() {
                try requireGoldenKeys(
                    entry,
                    exact: ["path", "byteCount", "sha256", "mediaType"],
                    at: "$.fixtures[\(index)].ledger[\(ledgerIndex)]"
                )
            }
        }

        let decoded: PublicationGoldenExpectationDocument
        do {
            decoded = try RoomJSONCoding.makeDecoder().decode(PublicationGoldenExpectationDocument.self, from: data)
        } catch {
            throw RoomRedesignContractValidationError.invalidJSON
        }
        guard decoded.schemaVersion == PublicationGoldenExpectationDocument.schemaVersionValue,
              decoded.fixtures.map(\.name) == ["room-v2-ai-ready", "property-v1"],
              Set(decoded.fixtures.map(\.name)).count == decoded.fixtures.count,
              try RoomRedesignCanonicalJSON.encode(decoded) == trimmingTrailingWhitespaceAndNewlines(from: data)
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "expectations.json",
                reason: "Golden fixture expectations must be complete, canonical, and use the fixed fixture order."
            )
        }
        return decoded
    }

    private func trimmingTrailingWhitespaceAndNewlines(from data: Data) -> Data {
        var bytes = Array(data)
        while let last = bytes.last,
              last == 0x20 || last == 0x09 || last == 0x0a || last == 0x0d {
            bytes.removeLast()
        }
        return Data(bytes)
    }

    private func requireGoldenKeys(
        _ object: [String: Any],
        exact expected: Set<String>,
        at path: String
    ) throws {
        guard Set(object.keys) == expected else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: path,
                reason: "Golden fixture expectations are closed objects."
            )
        }
    }

    private func decodePublicationGoldenArchive(from base64Data: Data) throws -> Data {
        let source = String(decoding: base64Data, as: UTF8.self)
        let normalized = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let archive = Data(base64Encoded: normalized),
              normalized == archive.base64EncodedString()
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "publication fixture",
                reason: "Fixture archives must be one canonical base64 payload."
            )
        }
        return archive
    }

    private func publicationGoldenComparisonFailures(
        built: PublicationGoldenFixtureBuilt,
        fixtureArchiveData: Data,
        expected: PublicationGoldenFixtureExpectation
    ) throws -> [String] {
        let actual = try PublicationGoldenFixtureExpectation(built: built)
        var failures: [String] = []
        if fixtureArchiveData != built.archiveData {
            failures.append("archive exact bytes")
        }
        let fixtureArchiveDigest = PublicationGoldenDigest(
            byteCount: UInt64(fixtureArchiveData.count),
            sha256: RoomSHA256.hexDigest(of: fixtureArchiveData)
        )
        if fixtureArchiveDigest != expected.archive {
            failures.append("archive SHA-256")
        }
        if actual.publicationManifest != expected.publicationManifest {
            failures.append("publication-manifest.json identity")
        }
        if actual.presentation != expected.presentation {
            failures.append("presentation.json identity")
        }
        if actual.sourceBindingsSHA256 != expected.sourceBindingsSHA256 {
            failures.append("source-binding SHA-256")
        }
        if actual.selectionManifestSHA256 != expected.selectionManifestSHA256 {
            failures.append("selection-manifest SHA-256")
        }
        if actual.approvalSHA256 != expected.approvalSHA256 {
            failures.append("approval SHA-256")
        }
        if actual.ledger != expected.ledger {
            failures.append("ordered allowlist ledger")
        }
        return failures
    }

    private func assertPublicGoldenPresentation(
        _ data: Data,
        expectedKind: RoomPublishedSnapshotKind
    ) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RoomRedesignContractValidationError.rootMustBeObject
        }
        let text = String(decoding: data, as: UTF8.self)
        for privateCanary in [
            "project-001", "project-002", "revision-001", "revision-002", "epoch-001", "epoch-002",
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210",
        ] {
            XCTAssertFalse(text.contains(privateCanary), "presentation.json leaked \(privateCanary)")
        }

        switch expectedKind {
        case .room:
            XCTAssertEqual(
                Set(root.keys),
                ["schemaVersion", "contractKind", "title", "room", "branding", "downloads"]
            )
        case .property:
            XCTAssertEqual(
                Set(root.keys),
                ["schemaVersion", "contractKind", "propertyTitle", "independentRoomNotice", "rooms", "branding", "downloads"]
            )
            XCTAssertEqual(
                root["independentRoomNotice"] as? String,
                RoomPublishedPropertyPresentationV1.independentRoomNotice
            )
            for spatialClaim in ["coordinates", "alignment", "connectivity", "reconstruction", "transform", "sharedOrigin"] {
                XCTAssertNil(root[spatialClaim], "Property presentation must not claim \(spatialClaim).")
            }
        }
    }

    private func printPublicationGoldenFixtureCapture(
        for fixtures: [PublicationGoldenFixtureBuilt]
    ) throws {
        let expectations = PublicationGoldenExpectationDocument(
            schemaVersion: PublicationGoldenExpectationDocument.schemaVersionValue,
            fixtures: try fixtures.map(PublicationGoldenFixtureExpectation.init(built:))
        )
        var output = ""
        for fixture in fixtures {
            let fixtureName = fixture.name.uppercased().replacingOccurrences(of: "-", with: "_")
            output += "PUBLICATION_GOLDEN_\(fixtureName)_BASE64_BEGIN\n"
            output += fixture.archiveData.base64EncodedString()
            output += "\nPUBLICATION_GOLDEN_\(fixtureName)_BASE64_END\n"
        }
        output += "PUBLICATION_GOLDEN_EXPECTATIONS_BEGIN\n"
        output += String(decoding: try RoomRedesignCanonicalJSON.encode(expectations), as: UTF8.self)
        output += "\nPUBLICATION_GOLDEN_EXPECTATIONS_END\n"
        FileHandle.standardOutput.write(Data(output.utf8))
    }

    private struct PublicationGoldenFixtureSet {
        var rootURL: URL
        var fixtures: [PublicationGoldenFixtureBuilt]
    }

    private struct PublicationGoldenFixtureBuilt {
        var name: String
        var archiveData: Data
        var result: RoomPublicationArchiveResult

        init(name: String, result: RoomPublicationArchiveResult) throws {
            self.name = name
            self.result = result
            archiveData = try Data(contentsOf: result.archiveURL)
            let actualArchive = PublicationGoldenDigest(
                byteCount: UInt64(archiveData.count),
                sha256: RoomSHA256.hexDigest(of: archiveData)
            )
            guard actualArchive.byteCount == result.receipt.archiveByteCount,
                  actualArchive.sha256 == result.receipt.archiveSHA256
            else {
                throw RoomRedesignContractValidationError.invalidValue(
                    path: "archive",
                    reason: "Production publication archive receipt did not match its exact file bytes."
                )
            }
        }
    }

    private struct PublicationGoldenExpectationDocument: Codable, Equatable {
        static let schemaVersionValue = "roomscan-publication-golden-fixtures-v1"

        var schemaVersion: String
        var fixtures: [PublicationGoldenFixtureExpectation]
    }

    private struct PublicationGoldenFixtureExpectation: Codable, Equatable {
        var name: String
        var archive: PublicationGoldenDigest
        var publicationManifest: PublicationGoldenDigest
        var presentation: PublicationGoldenDigest
        var sourceBindingsSHA256: String
        var selectionManifestSHA256: String
        var approvalSHA256: String
        var ledger: [PublicationGoldenLedgerEntry]

        init(built: PublicationGoldenFixtureBuilt) throws {
            name = built.name
            archive = .init(
                byteCount: UInt64(built.archiveData.count),
                sha256: RoomSHA256.hexDigest(of: built.archiveData)
            )
            publicationManifest = .init(
                byteCount: UInt64(built.result.manifestData.count),
                sha256: RoomSHA256.hexDigest(of: built.result.manifestData)
            )
            presentation = .init(
                byteCount: UInt64(built.result.presentationData.count),
                sha256: RoomSHA256.hexDigest(of: built.result.presentationData)
            )
            sourceBindingsSHA256 = built.result.manifest.sourceBindingsSHA256
            selectionManifestSHA256 = built.result.manifest.selectionManifestSHA256
            approvalSHA256 = try RoomPublishedSnapshotDigests.approvalSHA256(
                built.result.manifest.approval,
                expectedSourceBindingsSHA256: sourceBindingsSHA256,
                expectedSelectionManifestSHA256: selectionManifestSHA256
            )
            ledger = built.result.manifest.assets.map(PublicationGoldenLedgerEntry.init)
        }
    }

    private struct PublicationGoldenDigest: Codable, Equatable {
        var byteCount: UInt64
        var sha256: String
    }

    private struct PublicationGoldenLedgerEntry: Codable, Equatable {
        var path: String
        var byteCount: UInt64
        var sha256: String
        var mediaType: String

        init(path: String, byteCount: UInt64, sha256: String, mediaType: String) {
            self.path = path
            self.byteCount = byteCount
            self.sha256 = sha256
            self.mediaType = mediaType
        }

        init(_ entry: RoomPublishedAssetLedgerEntry) {
            path = entry.relativePath
            byteCount = entry.byteCount
            sha256 = entry.sha256
            mediaType = entry.mediaType
        }
    }

    private func roomPresentation() -> RoomPublishedRoomPresentationV2 {
        RoomPublishedRoomPresentationV2(
            title: "Living room presentation",
            room: .init(
                roomKey: "room-living",
                displayName: "Living room",
                semanticLayout: .init(elements: [
                    .init(
                        kind: .wall,
                        label: "North wall",
                        x: 0,
                        y: 0,
                        width: 1,
                        height: 0.05
                    )
                ]),
                orientation: .init(initialView: .entry),
                dimensions: [.init(label: "Width", meters: 4.2)],
                qualityWarnings: [
                    .init(
                        code: "low-light",
                        severity: .advisory,
                        message: "One corner has limited visual detail."
                    )
                ],
                comparisons: [
                    .init(
                        originalAssetID: "image-original",
                        conceptAssetID: "concept-001",
                        label: "Concept comparison",
                        disclaimer: "Concept imagery is illustrative and does not alter the measured room."
                    )
                ],
                assets: .init(
                    webGeometryAssetID: "geometry-001",
                    floorPlanAssetID: "floor-plan-001",
                    selectedImageAssetIDs: ["image-original"],
                    webTextureAssetIDs: [],
                    approvedConceptAssetIDs: ["concept-001"]
                )
            ),
            branding: .init(
                businessName: "Northstar Interiors",
                logoAssetID: "logo-001",
                contact: .init(phone: "+1 555 0100", website: "https://example.invalid"),
                accent: .blueprint
            ),
            downloads: .init(
                floorPlanPDF: true,
                galleryZIP: true,
                aiReadyPackageAssetID: nil
            )
        )
    }

    private func propertyPresentation() -> RoomPublishedPropertyPresentationV1 {
        let room = roomPresentation()
        var kitchen = room.room
        kitchen.roomKey = "room-kitchen"
        kitchen.displayName = "Kitchen"
        kitchen.comparisons = [
            .init(
                originalAssetID: "image-kitchen",
                conceptAssetID: "concept-kitchen",
                label: "Kitchen concept comparison",
                disclaimer: "Concept imagery is illustrative and does not alter the measured room."
            )
        ]
        kitchen.assets = .init(
            webGeometryAssetID: "geometry-kitchen",
            floorPlanAssetID: "floor-plan-kitchen",
            selectedImageAssetIDs: ["image-kitchen"],
            webTextureAssetIDs: [],
            approvedConceptAssetIDs: ["concept-kitchen"]
        )
        return .init(
            propertyTitle: "Sample property",
            rooms: [room.room, kitchen],
            branding: room.branding,
            downloads: room.downloads
        )
    }

    private func roomPresentationWithAIReadyDownload() -> RoomPublishedRoomPresentationV2 {
        var presentation = roomPresentation()
        presentation.downloads.aiReadyPackageAssetID = "ai-ready-001"
        return presentation
    }

    private func publishedAssets() -> [RoomPublishedAssetInput] {
        [
            .geometry(
                assetID: "geometry-001",
                publicRoomKey: "room-living",
                geometry: .init(
                    vertices: [
                        .init(x: 0, y: 0, z: 0),
                        .init(x: 1, y: 0, z: 0),
                        .init(x: 0, y: 1, z: 0),
                    ],
                    triangles: [.init(a: 0, b: 1, c: 2)]
                )
            ),
            .raster(
                assetID: "floor-plan-001",
                publicRoomKey: "room-living",
                assetClass: .floorPlan,
                raster: .init(data: Self.safePNG, mediaType: .png)
            ),
            .raster(
                assetID: "image-original",
                publicRoomKey: "room-living",
                assetClass: .selectedImage,
                raster: .init(data: Self.safePNG, mediaType: .png)
            ),
            .raster(
                assetID: "concept-001",
                publicRoomKey: "room-living",
                assetClass: .approvedConcept,
                raster: .init(data: Self.safePNG, mediaType: .png)
            ),
            .raster(
                assetID: "logo-001",
                publicRoomKey: nil,
                assetClass: .brandingLogo,
                raster: .init(data: Self.safePNG, mediaType: .png)
            ),
        ]
    }

    private func propertyAssets() -> [RoomPublishedAssetInput] {
        publishedAssets() + [
            .geometry(
                assetID: "geometry-kitchen",
                publicRoomKey: "room-kitchen",
                geometry: .init(
                    vertices: [
                        .init(x: 0, y: 0, z: 0),
                        .init(x: 1, y: 0, z: 0),
                        .init(x: 0, y: 1, z: 0),
                    ],
                    triangles: [.init(a: 0, b: 1, c: 2)]
                )
            ),
            .raster(
                assetID: "floor-plan-kitchen",
                publicRoomKey: "room-kitchen",
                assetClass: .floorPlan,
                raster: .init(data: Self.safePNG, mediaType: .png)
            ),
            .raster(
                assetID: "image-kitchen",
                publicRoomKey: "room-kitchen",
                assetClass: .selectedImage,
                raster: .init(data: Self.safePNG, mediaType: .png)
            ),
            .raster(
                assetID: "concept-kitchen",
                publicRoomKey: "room-kitchen",
                assetClass: .approvedConcept,
                raster: .init(data: Self.safePNG, mediaType: .png)
            ),
        ]
    }

    private func aiReadyPublishedAssets(
        archiveURL: URL,
        expectedPackageID: String
    ) -> [RoomPublishedAssetInput] {
        publishedAssets() + [
            .aiReadyPackage(
                assetID: "ai-ready-001",
                input: .init(
                    archiveURL: archiveURL,
                    publicRoomKey: "room-living",
                    expectedPackageID: expectedPackageID
                )
            ),
        ]
    }

    private func sourceRevision() -> RoomRedesignSourceRevision {
        .init(
            projectID: "project-001",
            revisionID: "revision-001",
            coordinateSpaceEpochID: "epoch-001",
            packageSchemaVersion: "room-scan-project-v2",
            semanticSHA256: String(repeating: "1", count: 64),
            revisionManifestSHA256: String(repeating: "2", count: 64)
        )
    }

    private func secondSourceRevision() -> RoomRedesignSourceRevision {
        .init(
            projectID: "project-002",
            revisionID: "revision-002",
            coordinateSpaceEpochID: "epoch-002",
            packageSchemaVersion: "room-scan-project-v2",
            semanticSHA256: String(repeating: "3", count: 64),
            revisionManifestSHA256: String(repeating: "4", count: 64)
        )
    }

    private func temporaryDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func aiPackageFixture(named name: String) throws -> RoomAIRoomPackage {
        let data = try fixtureData(named: name)
        guard case let .aiRoomPackage(package) = try RoomRedesignContractValidator.validate(data: data) else {
            throw RoomRedesignContractValidationError.invalidJSON
        }
        return package
    }

    private func fixtureData(named name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/RedesignContracts")
            .appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    private func buildFixtureAIArchive(
        named fixtureName: String,
        in root: URL,
        archiveName: String
    ) async throws -> RoomAIRoomPackageArchiveResult {
        let fixture = try aiPackageFixture(named: fixtureName)
        let plan = try RoomAIArtifactPlan.make(
            sourceRevision: fixture.sourceRevision,
            profile: fixture.profile,
            slots: fixture.artifactPlan
        )
        XCTAssertEqual(plan.artifactPlanSHA256, fixture.artifactPlanSHA256, fixtureName)

        let sources = root.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        var inputs: [RoomAIArtifactBuildInput] = []
        for artifact in fixture.artifacts {
            switch artifact.disposition {
            case .included:
                let relativePath = try XCTUnwrap(artifact.relativePath)
                let mediaType = try XCTUnwrap(artifact.mediaType)
                let sourceURL = sources.appendingPathComponent(relativePath)
                try FileManager.default.createDirectory(
                    at: sourceURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let bytes = Data("fixture-publication-ai-\(fixtureName)-\(artifact.artifactID)".utf8)
                try bytes.write(to: sourceURL, options: [.withoutOverwriting])
                inputs.append(.included(
                    slot: artifact.slot,
                    sourceURL: sourceURL,
                    relativePath: relativePath,
                    mediaType: mediaType
                ))
            case .unavailable:
                inputs.append(.unavailable(
                    slot: artifact.slot,
                    reasonCode: try XCTUnwrap(artifact.reasonCode)
                ))
            case .excluded:
                inputs.append(.excluded(
                    slot: artifact.slot,
                    reasonCode: try XCTUnwrap(artifact.reasonCode)
                ))
            case .skipped:
                inputs.append(.skipped(
                    slot: artifact.slot,
                    reasonCode: try XCTUnwrap(artifact.reasonCode)
                ))
            case .failed:
                inputs.append(.failed(
                    slot: artifact.slot,
                    reasonCode: try XCTUnwrap(artifact.reasonCode)
                ))
            }
        }
        let preparation = try await RoomAIRoomPackageBuilder.prepare(
            packageID: fixture.packageID,
            plan: plan,
            inputs: inputs
        )
        XCTAssertEqual(preparation.artifactPlan, fixture.artifactPlan, fixtureName)
        let includesRawEvidence = preparation.artifacts.contains {
            $0.artifactClass.isAIRawEvidence && $0.disposition == .included
        }
        let review = RoomDisclosureReview(
            reviewID: "publication-\(fixture.packageID)",
            reviewedAt: fixedDate,
            decision: .approved,
            sourceRevisionID: preparation.sourceRevision.revisionID,
            sourceRevisionManifestSHA256: preparation.sourceRevision.revisionManifestSHA256,
            reviewedArtifactPlanSHA256: preparation.artifactPlanSHA256,
            reviewedSelectionSHA256: preparation.selectionSHA256,
            preciseGPSExcluded: true,
            rawEvidenceDisclosureAccepted: preparation.profile == .complete && includesRawEvidence
        )
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return try await RoomAIRoomPackageArchive.build(
            preparation: preparation,
            disclosureReview: review,
            archiveURL: root.appendingPathComponent(archiveName),
            workspaceURL: workspace
        )
    }

    private func archiveWithUnledgeredAIEntry(
        from archiveURL: URL,
        in root: URL
    ) async throws -> URL {
        let extraction = root.appendingPathComponent("extraction", isDirectory: true)
        try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: true)
        let entries = try await RoomDeterministicZIP.extractVerifiedStoreEntries(
            from: archiveURL,
            into: extraction
        )
        var inputs = entries.map { entry in
            RoomZIPInput(
                sourceURL: extraction.appendingPathComponent(entry.entryPath.value),
                entryPath: entry.entryPath,
                mediaType: entry.entryPath.value == RoomAIRoomPackageArchive.manifestEntryPath
                    ? "application/json"
                    : "application/octet-stream"
            )
        }
        let privateURL = extraction.appendingPathComponent("raw/private-frame.bin")
        try FileManager.default.createDirectory(
            at: privateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("unledgered-private-raw-entry".utf8).write(to: privateURL, options: [.withoutOverwriting])
        inputs.append(.init(
            sourceURL: privateURL,
            entryPath: try RoomExportEntryPath("raw/private-frame.bin"),
            mediaType: "application/octet-stream"
        ))
        let alteredURL = root.appendingPathComponent("ai-ready-with-private-entry.zip")
        _ = try await RoomDeterministicZIP.write(inputs: inputs, to: alteredURL)
        return alteredURL
    }

    private func forgePublicationArchive(
        from published: RoomPublicationArchiveResult,
        replacingAIArchiveWith tamperedAIArchive: URL,
        in root: URL
    ) async throws -> URL {
        let source = root.appendingPathComponent("forged-source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let entries = try await RoomDeterministicZIP.extractVerifiedStoreEntries(
            from: published.archiveURL,
            into: source
        )
        var manifest = published.manifest
        let assetIndex = try XCTUnwrap(manifest.assets.firstIndex {
            $0.assetClass == .aiReadyPackage
        })
        let embeddedPath = manifest.assets[assetIndex].relativePath
        let replacementValues = try tamperedAIArchive.resourceValues(forKeys: [.fileSizeKey])
        let replacementSize = try XCTUnwrap(replacementValues.fileSize)
        manifest.assets[assetIndex].sha256 = try RoomSHA256.hexDigest(ofFile: tamperedAIArchive)
        manifest.assets[assetIndex].byteCount = UInt64(replacementSize)
        let selectionDigest = try RoomPublishedSnapshotDigests.selectionManifestSHA256(
            presentationSHA256: manifest.presentationSHA256,
            assets: manifest.assets
        )
        manifest.selectionManifestSHA256 = selectionDigest
        manifest.approval.selectionManifestSHA256 = selectionDigest
        try manifest.validate()

        let embeddedURL = source.appendingPathComponent(embeddedPath)
        try FileManager.default.removeItem(at: embeddedURL)
        try FileManager.default.copyItem(at: tamperedAIArchive, to: embeddedURL)
        let manifestURL = source.appendingPathComponent(RoomPublicationArchive.manifestEntryPath)
        try FileManager.default.removeItem(at: manifestURL)
        try RoomRedesignCanonicalJSON.encode(manifest).write(to: manifestURL, options: [.withoutOverwriting])

        let inputs = entries.map { entry in
            RoomZIPInput(
                sourceURL: source.appendingPathComponent(entry.entryPath.value),
                entryPath: entry.entryPath,
                mediaType: entry.entryPath.value.hasSuffix(".json")
                    ? "application/json"
                    : "application/octet-stream"
            )
        }
        let forgedURL = root.appendingPathComponent("forged-published-with-tampered-ai.zip")
        _ = try await RoomDeterministicZIP.write(inputs: inputs, to: forgedURL)
        return forgedURL
    }

    private func injectingJSONMember(_ key: String, into data: Data, at path: String) -> Data {
        var root = (try! JSONSerialization.jsonObject(with: data)) as! [String: Any]
        if path == "room" {
            var room = root["room"] as! [String: Any]
            room[key] = "probe"
            root["room"] = room
        } else {
            root[key] = "probe"
        }
        return try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private func jpegWithMetadata(_ payload: String) -> Data {
        jpegWithAPP(marker: 0xe1, payload: Data(payload.utf8))
    }

    private func jpegWithAPP(marker: UInt8, payload: Data) -> Data {
        let length = UInt16(payload.count + 2)
        return Data([
            0xff, 0xd8, 0xff, marker,
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: length),
        ])
            + payload
            + Self.safeJPEG.dropFirst(2)
    }

    private func pngWithMetadataChunk(type: String, payload: Data) throws -> Data {
        let typeData = Data(type.utf8)
        guard typeData.count == 4,
              let iendRange = Self.safePNG.range(of: Data([0, 0, 0, 0, 73, 69, 78, 68]))
        else {
            throw RoomRedesignContractValidationError.invalidJSON
        }
        let length = UInt32(payload.count)
        var chunk = Data([
            UInt8(truncatingIfNeeded: length >> 24),
            UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: length),
        ])
        chunk.append(typeData)
        chunk.append(payload)
        var crc = RoomCRC32.Stream()
        crc.update(typeData)
        crc.update(payload)
        let value = crc.finalizedValue
        chunk.append(contentsOf: [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ])
        return Self.safePNG[..<iendRange.lowerBound] + chunk + Self.safePNG[iendRange.lowerBound...]
    }

    private static func pngWithInvalidIDATPayload() throws -> Data {
        var checksumInvalidIDAT = zlibStoredBlock(scanlines: Data([0x05, 0x00, 0x00]))
        // The PNG chunk CRC will be recomputed below, but this is not a valid
        // zlib stream: alter Adler-32 after creating correct DEFLATE framing.
        checksumInvalidIDAT[checksumInvalidIDAT.index(before: checksumInvalidIDAT.endIndex)] ^= 0x01
        return try rewritingSafePNG(height: nil, idatPayload: checksumInvalidIDAT)
    }

    private static func pngWithLateRecoverableIDATCanary() throws -> Data {
        // A valid first scanline followed by the invalid second-row filter
        // and a trailing private canary. ImageIO recovers this particular
        // input, which makes it a direct provenance-sanitization control.
        let idatPayload = zlibStoredBlock(
            scanlines: Data([0x00, 0x00, 0x00, 0x05, 0x00, 0x00])
        ) + lateMalformedIDATCanary
        return try rewritingSafePNG(height: 2, idatPayload: idatPayload)
    }

    private static func rewritingSafePNG(
        height: UInt32?,
        idatPayload: Data
    ) throws -> Data {
        let bytes = [UInt8](safePNG)
        let signatureLength = 8
        guard bytes.count >= signatureLength else {
            throw RoomRedesignContractValidationError.invalidJSON
        }
        var result = Data(bytes[0..<signatureLength])
        var replacedHeader = false
        var replacedImageData = false
        var offset = 8
        while offset <= bytes.count - 12 {
            let length = Int(readBigEndianUInt32(bytes, at: offset))
            let typeStart = offset + 4
            let payloadStart = typeStart + 4
            let payloadEnd = payloadStart + length
            guard payloadEnd <= bytes.count - 4 else {
                throw RoomRedesignContractValidationError.invalidJSON
            }
            let type = String(decoding: bytes[typeStart..<(typeStart + 4)], as: UTF8.self)
            let originalPayload = Data(bytes[payloadStart..<payloadEnd])
            switch type {
            case "IHDR":
                guard originalPayload.count == 13 else {
                    throw RoomRedesignContractValidationError.invalidJSON
                }
                var header = originalPayload
                if let height {
                    header.replaceSubrange(4..<8, with: [
                        UInt8(truncatingIfNeeded: height >> 24),
                        UInt8(truncatingIfNeeded: height >> 16),
                        UInt8(truncatingIfNeeded: height >> 8),
                        UInt8(truncatingIfNeeded: height),
                    ])
                }
                result.append(pngChunk(type: type, payload: header))
                replacedHeader = true
            case "IDAT":
                guard !replacedImageData else {
                    throw RoomRedesignContractValidationError.invalidJSON
                }
                result.append(pngChunk(type: type, payload: idatPayload))
                replacedImageData = true
            default:
                result.append(contentsOf: bytes[offset...(payloadEnd + 3)])
            }
            offset = payloadEnd + 4
        }
        guard replacedHeader, replacedImageData, offset == bytes.count else {
            throw RoomRedesignContractValidationError.invalidJSON
        }
        return result
    }

    private static func pngChunk(type: String, payload: Data) -> Data {
        let typeData = Data(type.utf8)
        var chunk = Data()
        let length = UInt32(payload.count)
        chunk.append(contentsOf: [
            UInt8(truncatingIfNeeded: length >> 24),
            UInt8(truncatingIfNeeded: length >> 16),
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: length),
        ])
        chunk.append(typeData)
        chunk.append(payload)
        var crc = RoomCRC32.Stream()
        crc.update(typeData)
        crc.update(payload)
        let value = crc.finalizedValue
        chunk.append(contentsOf: [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ])
        return chunk
    }

    private static func zlibStoredBlock(scanlines: Data) -> Data {
        let length = UInt16(scanlines.count)
        let complement = ~length
        var result = Data([
            0x78, 0x01, // zlib header
            0x01, // BFINAL=1, stored DEFLATE block
            UInt8(truncatingIfNeeded: length),
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: complement),
            UInt8(truncatingIfNeeded: complement >> 8),
        ])
        result.append(scanlines)
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in scanlines {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        let adler32 = (b << 16) | a
        result.append(contentsOf: [
            UInt8(truncatingIfNeeded: adler32 >> 24),
            UInt8(truncatingIfNeeded: adler32 >> 16),
            UInt8(truncatingIfNeeded: adler32 >> 8),
            UInt8(truncatingIfNeeded: adler32),
        ])
        return result
    }

    private static func pngWithRecoverableIDATCanary() throws -> Data {
        let bytes = [UInt8](safePNG)
        var offset = 8
        while offset <= bytes.count - 12 {
            let length = Int(readBigEndianUInt32(bytes, at: offset))
            let typeStart = offset + 4
            let payloadStart = typeStart + 4
            let payloadEnd = payloadStart + length
            guard payloadEnd <= bytes.count - 4 else {
                throw RoomRedesignContractValidationError.invalidJSON
            }
            if String(decoding: bytes[typeStart..<(typeStart + 4)], as: UTF8.self) == "IDAT" {
                let payload = Data(bytes[payloadStart..<payloadEnd]) + malformedIDATCanary
                var result = Data(bytes[0..<offset])
                let length = UInt32(payload.count)
                result.append(contentsOf: [
                    UInt8(truncatingIfNeeded: length >> 24),
                    UInt8(truncatingIfNeeded: length >> 16),
                    UInt8(truncatingIfNeeded: length >> 8),
                    UInt8(truncatingIfNeeded: length),
                ])
                let type = Data(bytes[typeStart..<(typeStart + 4)])
                result.append(type)
                result.append(payload)
                var crc = RoomCRC32.Stream()
                crc.update(type)
                crc.update(payload)
                let value = crc.finalizedValue
                result.append(contentsOf: [
                    UInt8(truncatingIfNeeded: value >> 24),
                    UInt8(truncatingIfNeeded: value >> 16),
                    UInt8(truncatingIfNeeded: value >> 8),
                    UInt8(truncatingIfNeeded: value),
                ])
                result.append(contentsOf: bytes[(payloadEnd + 4)...])
                return result
            }
            offset = payloadEnd + 4
        }
        throw RoomRedesignContractValidationError.invalidJSON
    }

    private static func jpegWithInvalidEntropy(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xff, bytes[1] == 0xd8 else {
            throw RoomRedesignContractValidationError.invalidJSON
        }
        var offset = 2
        while offset <= bytes.count - 2 {
            guard bytes[offset] == 0xff else {
                throw RoomRedesignContractValidationError.invalidJSON
            }
            let markerStart = offset
            while offset < bytes.count, bytes[offset] == 0xff { offset += 1 }
            guard offset < bytes.count else { throw RoomRedesignContractValidationError.invalidJSON }
            let marker = bytes[offset]
            offset += 1
            guard marker != 0xd9, offset <= bytes.count - 2 else {
                throw RoomRedesignContractValidationError.invalidJSON
            }
            let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            guard length >= 2, length <= bytes.count - offset else {
                throw RoomRedesignContractValidationError.invalidJSON
            }
            let payloadEnd = offset + length
            if marker == 0xda {
                // Referencing DC/AC table 3 is legal SOS framing and passes
                // the bounded marker parser, but the generated JPEG contains
                // no table 3. Pixel entropy decoding must reject it.
                var invalid = bytes
                let payloadStart = offset + 2
                guard payloadStart + 2 < payloadEnd else {
                    throw RoomRedesignContractValidationError.invalidJSON
                }
                invalid[payloadStart + 2] = 0x33
                return Data(invalid)
            }
            guard markerStart < payloadEnd else { throw RoomRedesignContractValidationError.invalidJSON }
            offset = payloadEnd
        }
        throw RoomRedesignContractValidationError.invalidJSON
    }

    private static func forceImageIODecode(_ data: Data, type: UTType) throws {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ),
            CGImageSourceGetCount(source) == 1,
            CGImageSourceGetStatus(source) == .statusComplete,
            CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
            CGImageSourceGetType(source).map({ $0 as String }) == type.identifier,
            let image = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            )
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "test.image",
                reason: "ImageIO rejected the image before pixel decoding."
            )
        }
        let (bytesPerRow, rowOverflow) = image.width.multipliedReportingOverflow(by: 4)
        let (_, allocationOverflow) = bytesPerRow.multipliedReportingOverflow(by: image.height)
        guard image.width > 0,
              image.height > 0,
              !rowOverflow,
              !allocationOverflow,
              let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "test.image",
                reason: "Unable to allocate a full image decode surface."
            )
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.flush()
        guard
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
        else {
            throw RoomRedesignContractValidationError.invalidValue(
                path: "test.image",
                reason: "ImageIO failed while decoding image pixels."
            )
        }
    }

    private static func metadataFreeJPEG() throws -> Data {
        guard let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw RoomRedesignContractValidationError.invalidJSON
        }
        context.setFillColor(CGColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let image = context.makeImage() else {
            throw RoomRedesignContractValidationError.invalidJSON
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw RoomRedesignContractValidationError.invalidJSON
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw RoomRedesignContractValidationError.invalidJSON
        }
        return try strippingJPEGAPPMarkers(output as Data)
    }

    private static func strippingJPEGAPPMarkers(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xff, bytes[1] == 0xd8 else {
            throw RoomRedesignContractValidationError.invalidJSON
        }
        var result: [UInt8] = [0xff, 0xd8]
        var offset = 2
        while offset <= bytes.count - 2 {
            guard bytes[offset] == 0xff else {
                throw RoomRedesignContractValidationError.invalidJSON
            }
            let markerStart = offset
            while offset < bytes.count, bytes[offset] == 0xff { offset += 1 }
            guard offset < bytes.count else { throw RoomRedesignContractValidationError.invalidJSON }
            let marker = bytes[offset]
            offset += 1
            if marker == 0xda {
                result.append(contentsOf: bytes[markerStart...])
                return Data(result)
            }
            guard marker != 0xd9, offset <= bytes.count - 2 else {
                throw RoomRedesignContractValidationError.invalidJSON
            }
            let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            guard length >= 2, length <= bytes.count - offset else {
                throw RoomRedesignContractValidationError.invalidJSON
            }
            let segmentEnd = offset + length
            if !(0xe0...0xef).contains(marker) {
                result.append(contentsOf: bytes[markerStart..<segmentEnd])
            }
            offset = segmentEnd
        }
        throw RoomRedesignContractValidationError.invalidJSON
    }

    private static func readBigEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    private func assertThrowsAsync(
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected failure for \(label)", file: file, line: line)
        } catch {
            // The safe control at the beginning of the test proves the same
            // builder and real byte validator accept a valid derivative.
        }
    }

    private func assertBuilderRejectsFloorPlan(
        _ data: Data,
        mediaType: RoomPublishedRasterMediaType,
        binding: RoomPublishedSourceBinding,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        var assets = publishedAssets()
        assets[1] = .raster(
            assetID: "floor-plan-001",
            publicRoomKey: "room-living",
            assetClass: .floorPlan,
            raster: .init(data: data, mediaType: mediaType)
        )
        await assertThrowsAsync(label, file: file, line: line) {
            _ = try await RoomPublishedSnapshotBuilder.prepare(
                draft: .room(self.roomPresentation()),
                sourceBindings: [binding],
                assets: assets
            )
        }
    }

    private func assertAIReadyPublicationRejects(
        archiveURL: URL,
        expectedPackageID: String,
        sourceBinding: RoomPublishedSourceBinding,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await assertThrowsAsync(label, file: file, line: line) {
            _ = try await RoomPublishedSnapshotBuilder.prepare(
                draft: .room(self.roomPresentationWithAIReadyDownload()),
                sourceBindings: [sourceBinding],
                assets: self.aiReadyPublishedAssets(
                    archiveURL: archiveURL,
                    expectedPackageID: expectedPackageID
                )
            )
        }
    }

    private func preparedData(
        assetID: String,
        from preparation: RoomPublishedSnapshotPreparation
    ) throws -> Data {
        let asset = try XCTUnwrap(preparation.preparedAssets.first { $0.ledger.assetID == assetID })
        guard case let .data(data) = asset.source else {
            throw RoomRedesignContractValidationError.invalidJSON
        }
        return data
    }

    private static let safePNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!

    private static let malformedIDATCanary = Data("private-idat-decode-canary".utf8)

    private static let lateMalformedIDATCanary = Data("private-late-scanline-canary".utf8)

    private static let safeJPEG: Data = {
        do {
            return try metadataFreeJPEG()
        } catch {
            fatalError("Unable to construct a metadata-free decodable JPEG test control: \(error)")
        }
    }()
}
