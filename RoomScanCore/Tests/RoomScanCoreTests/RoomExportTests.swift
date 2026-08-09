import Foundation
import XCTest
@testable import RoomScanCore

final class RoomExportTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_704_067_200)

    func testCRC32KnownVectorAndStreamingSHA256AreIncremental() throws {
        var crc = RoomCRC32.Stream()
        crc.update(Data("1234".utf8))
        crc.update(Data("56789".utf8))
        XCTAssertEqual(crc.finalizedValue, 0xcbf4_3926)

        var hash = RoomSHA256.Stream()
        hash.update(Data("a".utf8))
        hash.update(Data("bc".utf8))
        XCTAssertEqual(
            hash.finalizedHexDigest(),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testExportEntryPathRejectsUnsafeAndCollidingNames() throws {
        XCTAssertNoThrow(try RoomExportEntryPath("revision/semantic-model.json"))
        for unsafe in [
            "../escape.json", "/absolute.json", "back\\slash.json", "./dot.json",
            "folder/../escape.json", "contains space.json", "control\n.json", "caf\u{00e9}.json"
        ] {
            XCTAssertThrowsError(try RoomExportEntryPath(unsafe), "Expected \(unsafe) to be rejected.")
        }
        XCTAssertThrowsError(
            try RoomExportEntryPath.validateUnique([
                RoomExportEntryPath("assets/Photo.PNG"),
                RoomExportEntryPath("assets/photo.png"),
            ])
        )
    }

    func testFinalArchiveEntryBudgetReservesManifestAndDerivedSlots() throws {
        XCTAssertEqual(RoomExportLimits.maximumEntries, 4_096)
        XCTAssertEqual(RoomExportLimits.maximumPreManifestEntries, 4_095)
        XCTAssertEqual(RoomExportLimits.maximumMaterializedEntries, 4_093)
        XCTAssertEqual(
            try RoomExportLimits.finalArchiveEntryCount(
                forMaterializedEntries: RoomExportLimits.maximumMaterializedEntries,
                derivedEntryCount: RoomExportLimits.mandatoryDerivedEntryCount
            ),
            RoomExportLimits.maximumEntries
        )
        XCTAssertThrowsError(
            try RoomExportLimits.finalArchiveEntryCount(
                forMaterializedEntries: RoomExportLimits.maximumMaterializedEntries + 1,
                derivedEntryCount: RoomExportLimits.mandatoryDerivedEntryCount
            )
        )
        XCTAssertThrowsError(
            try RoomExportLimits.finalArchiveEntryCount(
                forMaterializedEntries: RoomExportLimits.maximumMaterializedEntries,
                derivedEntryCount: RoomExportLimits.mandatoryDerivedEntryCount - 1
            )
        )
        XCTAssertEqual(
            RoomExportMaterializationLimits().maxEntries,
            RoomExportLimits.maximumMaterializedEntries
        )
        XCTAssertEqual(RoomZIPLimits().maxEntries, RoomExportLimits.maximumEntries)
    }

    func testZIPInjectedEntryLimitAllowsBoundaryAndRejectsOneMore() async throws {
        let root = temporaryRoot("RoomZIPInjectedEntryLimit")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("one-byte.bin")
        try Data([0x01]).write(to: source)
        let limits = RoomZIPLimits(
            maxEntries: 1,
            maxEntryBytes: RoomExportLimits.maximumEntryBytes,
            maxArchiveBytes: RoomExportLimits.maximumArchiveBytes
        )
        let input = RoomZIPInput(
            sourceURL: source,
            entryPath: try RoomExportEntryPath("entries/one.bin"),
            mediaType: "application/octet-stream"
        )
        let digests = try await RoomDeterministicZIP.preflight(inputs: [input], limits: limits)
        XCTAssertEqual(digests.count, 1)

        let oneTooMany = RoomZIPInput(
            sourceURL: source,
            entryPath: try RoomExportEntryPath("entries/two.bin"),
            mediaType: "application/octet-stream"
        )
        do {
            _ = try await RoomDeterministicZIP.preflight(inputs: [input, oneTooMany], limits: limits)
            XCTFail("Expected an injected archive entry-cap rejection.")
        } catch let error as RoomExportError {
            XCTAssertEqual(error, .entryLimitExceeded)
        }
    }

    func testDeterministicZipUsesSortedStoreProfileAndStableBytes() async throws {
        let root = temporaryRoot("RoomDeterministicZIP")
        defer { try? FileManager.default.removeItem(at: root) }
        let alpha = root.appendingPathComponent("alpha.bin")
        let beta = root.appendingPathComponent("beta.txt")
        try Data("alpha".utf8).write(to: alpha)
        try Data("beta".utf8).write(to: beta)

        let archiveOne = root.appendingPathComponent("one.zip")
        let archiveTwo = root.appendingPathComponent("two.zip")
        let inputs = [
            RoomZIPInput(sourceURL: beta, entryPath: try RoomExportEntryPath("b/beta.txt"), mediaType: "text/plain"),
            RoomZIPInput(sourceURL: alpha, entryPath: try RoomExportEntryPath("a/alpha.bin"), mediaType: "application/octet-stream"),
        ]

        let one = try await RoomDeterministicZIP.write(inputs: inputs, to: archiveOne)
        let two = try await RoomDeterministicZIP.write(inputs: Array(inputs.reversed()), to: archiveTwo)

        XCTAssertEqual(one.profileVersion, RoomDeterministicZIP.profileVersion)
        XCTAssertEqual(two.profileVersion, RoomDeterministicZIP.profileVersion)
        XCTAssertEqual(try Data(contentsOf: archiveOne), try Data(contentsOf: archiveTwo))
        let bytes = try Data(contentsOf: archiveOne)
        XCTAssertEqual(Array(bytes.prefix(4)), [0x50, 0x4b, 0x03, 0x04])
        XCTAssertFalse(bytes.windows(ofCount: 4).contains([0x50, 0x4b, 0x07, 0x08]))
        XCTAssertFalse(bytes.windows(ofCount: 4).contains([0x50, 0x4b, 0x06, 0x06]))
    }

    func testZipInspectorRejectsCentralDirectoryGap() async throws {
        let root = temporaryRoot("RoomZIPGap")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        let archive = root.appendingPathComponent("head-export.zip")
        try Data("gap-control".utf8).write(to: source)
        _ = try await RoomDeterministicZIP.write(
            inputs: [RoomZIPInput(
                sourceURL: source,
                entryPath: try RoomExportEntryPath("semantic/source.txt"),
                mediaType: "text/plain"
            )],
            to: archive
        )
        var bytes = try Data(contentsOf: archive)
        let centralSignature = Data([0x50, 0x4b, 0x01, 0x02])
        let centralOffset = try XCTUnwrap(bytes.range(of: centralSignature)?.lowerBound)
        bytes[centralOffset + 42] = 1 // First local record must begin at offset zero.
        try bytes.write(to: archive, options: .atomic)
        XCTAssertThrowsError(try RoomDeterministicZIP.inspect(url: archive))
    }

    func testZipPreflightUsesBoundedChunksAndRejectsSimulatedLimits() async throws {
        let root = temporaryRoot("RoomZIPLimits")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.bin")
        let archive = root.appendingPathComponent("head-export.zip")
        try Data(repeating: 0x61, count: 257).write(to: source)
        let observer = BoundedReadObserver()

        _ = try await RoomDeterministicZIP.write(
            inputs: [RoomZIPInput(
                sourceURL: source,
                entryPath: try RoomExportEntryPath("semantic/source.bin"),
                mediaType: "application/octet-stream"
            )],
            to: archive,
            chunkSize: 64,
            readObserver: observer
        )
        XCTAssertEqual(observer.maximumObservedRead, 64)

        do {
            _ = try await RoomDeterministicZIP.write(
                inputs: [RoomZIPInput(
                    sourceURL: source,
                    entryPath: try RoomExportEntryPath("semantic/source.bin"),
                    mediaType: "application/octet-stream"
                )],
                to: root.appendingPathComponent("too-small.zip"),
                limits: RoomZIPLimits(maxEntries: 1, maxEntryBytes: 128, maxArchiveBytes: 512)
            )
            XCTFail("Expected a simulated entry-size limit failure.")
        } catch let error as RoomExportError {
            XCTAssertEqual(error, .sizeLimitExceeded("semantic/source.bin"))
        }
    }

    func testZipRejectsSimulatedArchiveOffsetLimitBeforeWriting() async throws {
        let root = temporaryRoot("RoomZIPArchiveLimit")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.bin")
        try Data(repeating: 0x62, count: 20).write(to: source)
        do {
            _ = try await RoomDeterministicZIP.write(
                inputs: [RoomZIPInput(
                    sourceURL: source,
                    entryPath: try RoomExportEntryPath("long-name/source.bin"),
                    mediaType: "application/octet-stream"
                )],
                to: root.appendingPathComponent("limited.zip"),
                limits: RoomZIPLimits(maxEntries: 1, maxEntryBytes: 100, maxArchiveBytes: 100)
            )
            XCTFail("Expected an archive offset/central-directory cap failure.")
        } catch let error as RoomExportError {
            XCTAssertEqual(error, .archiveLimitExceeded)
        }
    }

    func testZipDetectsPostPreflightMutationAndCleansOnlyOwnedPartial() async throws {
        let root = temporaryRoot("RoomZIPMutation")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        let archive = root.appendingPathComponent("export.zip")
        try Data("before".utf8).write(to: source)
        let injector = ExportMutationFaultInjector(sourceURL: source)

        do {
            _ = try await RoomDeterministicZIP.write(
                inputs: [RoomZIPInput(
                    sourceURL: source,
                    entryPath: try RoomExportEntryPath("semantic/source.txt"),
                    mediaType: "text/plain"
                )],
                to: archive,
                faultInjector: injector
            )
            XCTFail("Expected a post-preflight mutation to fail closed.")
        } catch let error as RoomExportError {
            XCTAssertEqual(error, .sourceChangedAfterPreflight("semantic/source.txt"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.appendingPathExtension("partial").path))
    }

    func testMaterializeHeadIsHeadOnlyDeepCopiedAndLeavesSourceBytesUntouched() async throws {
        let root = temporaryRoot("RoomExportStore")
        let destination = root.deletingLastPathComponent().appendingPathComponent("RoomExportWorkspace-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: destination)
        }
        let store = makeStore(root: root, revisionIDs: ["revision-001", "revision-002"])
        let savedResult = try await store.saveDraft(makeDraft(), decision: .save)
        let initial = try XCTUnwrap(savedResult)
        let revisionOneBytes = try regularFileSnapshot(
            root.appendingPathComponent(initial.projectID).appendingPathComponent("revisions/revision-001")
        )
        let loaded = try await store.load(projectID: initial.projectID)
        var payload = try XCTUnwrap(loaded.revisions.last).payload
        payload.semanticSnapshot.objectElements[0].label = "Edited export object"
        _ = try await store.commitEditRevision(
            projectID: initial.projectID,
            expectedHeadRevisionID: "revision-001",
            payload: payload,
            newRevisionID: "revision-002"
        )
        let sourceBytesBeforeExport = try regularFileSnapshot(root.appendingPathComponent(initial.projectID))

        let materialization = try await store.materializeHeadForExport(
            projectID: initial.projectID,
            expectedHeadRevisionID: "revision-002",
            into: destination
        )

        XCTAssertEqual(materialization.descriptor.headRevisionID, "revision-002")
        XCTAssertFalse(materialization.entries.contains { $0.entryPath.value.contains("revision-001") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try regularFileSnapshot(root.appendingPathComponent(initial.projectID)), sourceBytesBeforeExport)
        XCTAssertEqual(
            try regularFileSnapshot(
                root.appendingPathComponent(initial.projectID).appendingPathComponent("revisions/revision-001")
            ),
            revisionOneBytes
        )
        let materializedSemantic = destination.appendingPathComponent("revision/semantic-model.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: materializedSemantic.path))
        XCTAssertFalse(try isHardLinked(source: root.appendingPathComponent(initial.projectID).appendingPathComponent("revisions/revision-002/semantic-model.json"), copy: materializedSemantic))
    }

    func testMaterializationRejectsStaleHeadAndUnsafeDestinationBeforeCopy() async throws {
        let root = temporaryRoot("RoomExportUnsafe")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let savedResult = try await store.saveDraft(makeDraft(), decision: .save)
        let saved = try XCTUnwrap(savedResult)
        let insideRoot = root.appendingPathComponent("unsafe-export")

        do {
            _ = try await store.materializeHeadForExport(
                projectID: saved.projectID,
                expectedHeadRevisionID: "revision-stale",
                into: root.deletingLastPathComponent().appendingPathComponent("stale-workspace")
            )
            XCTFail("Expected stale head rejection.")
        } catch {
            // Expected.
        }
        do {
            _ = try await store.materializeHeadForExport(
                projectID: saved.projectID,
                expectedHeadRevisionID: "revision-001",
                into: insideRoot
            )
            XCTFail("Expected an inside-root destination rejection.")
        } catch {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: insideRoot.path))
    }

    func testMaterializationRejectsPreexistingDestinationAndLeavesSourceTreeUntouched() async throws {
        let root = temporaryRoot("RoomExportPreexisting")
        let destination = root.deletingLastPathComponent().appendingPathComponent("RoomExportPreexistingDestination-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: destination)
        }
        let store = makeStore(root: root)
        let savedResult = try await store.saveDraft(makeDraft(), decision: .save)
        let saved = try XCTUnwrap(savedResult)
        let sourceBytes = try regularFileSnapshot(root.appendingPathComponent(saved.projectID))
        let parent = destination.deletingLastPathComponent()
        let beforeNames = Set(
            try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
                .map(\.lastPathComponent)
        )
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        do {
            _ = try await store.materializeHeadForExport(
                projectID: saved.projectID,
                expectedHeadRevisionID: saved.headRevisionID,
                into: destination
            )
            XCTFail("Expected a preexisting export destination rejection.")
        } catch {
            // Expected.
        }
        XCTAssertEqual(try regularFileSnapshot(root.appendingPathComponent(saved.projectID)), sourceBytes)
        let afterNames = Set(
            try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
                .map(\.lastPathComponent)
        )
        XCTAssertEqual(afterNames.subtracting(Set([destination.lastPathComponent])), beforeNames)
    }

    func testMaterializationRewritesScopedReferencesWithoutCrossScopeAlias() async throws {
        let root = temporaryRoot("RoomExportScopedReferences")
        let source = root.deletingLastPathComponent().appendingPathComponent(
            "RoomExportScopedReferenceSource-\(UUID().uuidString)",
            isDirectory: true
        )
        let workspace = root.deletingLastPathComponent().appendingPathComponent(
            "RoomExportScopedReferenceWorkspace-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: workspace)
        }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let thumbnailSource = source.appendingPathComponent("project-thumbnail.png")
        let photoSource = source.appendingPathComponent("revision-photo.png")
        let thumbnailBytes = Data("project-thumbnail".utf8)
        let photoBytes = Data("revision-photo".utf8)
        try thumbnailBytes.write(to: thumbnailSource)
        try photoBytes.write(to: photoSource)

        let sharedReference = try RoomRelativePath("assets/shared.png")
        var draft = makeDraft()
        draft.metadata.thumbnailRelativePath = sharedReference
        draft.revision.photos = [
            RoomPhoto(
                id: "photo-shared-001",
                createdAt: date,
                assetRelativePath: sharedReference,
                caption: "Revision-scoped photo"
            )
        ]
        let store = makeStore(root: root)
        let savedResult = try await store.saveDraft(
            draft,
            decision: .save,
            assets: [
                RoomAssetInput(sourceURL: thumbnailSource, destination: sharedReference, scope: .project),
                RoomAssetInput(sourceURL: photoSource, destination: sharedReference, scope: .revision),
            ]
        )
        let saved = try XCTUnwrap(savedResult)

        let materialization = try await store.materializeHeadForExport(
            projectID: saved.projectID,
            expectedHeadRevisionID: saved.headRevisionID,
            into: workspace
        )
        let metadata = try RoomJSONCoding.makeDecoder().decode(
            RoomMetadata.self,
            from: Data(contentsOf: workspace.appendingPathComponent("metadata.json"))
        )
        let photos = try RoomJSONCoding.makeDecoder().decode(
            RoomPhotosDocument.self,
            from: Data(contentsOf: workspace.appendingPathComponent("revision/photos.json"))
        )
        let sourceMap = try RoomJSONCoding.makeDecoder().decode(
            RoomExportSourceMap.self,
            from: Data(contentsOf: workspace.appendingPathComponent("source-map.json"))
        )
        let exportedThumbnail = try XCTUnwrap(metadata.thumbnailRelativePath).value
        let exportedPhoto = try XCTUnwrap(photos.photos.first).assetRelativePath.value
        XCTAssertNotEqual(exportedThumbnail, exportedPhoto)
        XCTAssertEqual(try Data(contentsOf: workspace.appendingPathComponent(exportedThumbnail)), thumbnailBytes)
        XCTAssertEqual(try Data(contentsOf: workspace.appendingPathComponent(exportedPhoto)), photoBytes)
        XCTAssertEqual(
            sourceMap.mappings.first {
                $0.scope == .project && $0.sourceReference == sharedReference.value
            }?.archivePath,
            exportedThumbnail
        )
        XCTAssertEqual(
            sourceMap.mappings.first {
                $0.scope == .revision && $0.sourceReference == sharedReference.value
            }?.archivePath,
            exportedPhoto
        )
        XCTAssertTrue(materialization.entries.contains { $0.entryPath.value == exportedThumbnail })
        XCTAssertTrue(materialization.entries.contains { $0.entryPath.value == exportedPhoto })
    }

    func testProjectionRejectsExtremeFiniteValuesBeforeUIKitRendering() throws {
        var draft = makeDraft()
        draft.revision.semanticSnapshot.objectElements[0].dimensionsMeters.width = Double.greatestFiniteMagnitude
        XCTAssertThrowsError(try RoomFloorPlanProjection.make(from: draft.revision.semanticSnapshot))
    }

    func testMaterializationAppliesInjectedEntryLimitBeforePromotingWorkspace() async throws {
        let root = temporaryRoot("RoomExportMaterializationLimit")
        let destination = root.deletingLastPathComponent().appendingPathComponent("RoomExportMaterializationLimitDestination-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: destination)
        }
        let store = LocalRoomProjectStore(
            rootURL: root,
            clock: FixedRoomProjectClock(date: date),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: ["project-export-limit"],
                revisionIDs: ["revision-001"]
            ),
            exportMaterializationLimits: RoomExportMaterializationLimits(
                maxEntries: 1,
                maxFileBytes: RoomExportLimits.maximumEntryBytes,
                maxAggregateBytes: RoomExportLimits.maximumArchiveBytes
            )
        )
        let savedResult = try await store.saveDraft(makeDraft(), decision: .save)
        let saved = try XCTUnwrap(savedResult)

        do {
            _ = try await store.materializeHeadForExport(
                projectID: saved.projectID,
                expectedHeadRevisionID: saved.headRevisionID,
                into: destination
            )
            XCTFail("Expected an injected materialization entry-limit failure.")
        } catch let error as RoomExportError {
            XCTAssertEqual(error, .entryLimitExceeded)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testFloorPlanProjectionPreservesNinetyDegreeSemanticBoxOrientation() throws {
        var draft = makeDraft()
        // Column-major +90° yaw: local X projects along global -Z and local Z
        // projects along global X. A 4×1 semantic wall should not render as an
        // axis-aligned 4×1 rectangle in the wrong direction.
        draft.revision.semanticSnapshot.structuralElements[0].dimensionsMeters = RoomDimensions(width: 4, height: 0, depth: 1)
        draft.revision.semanticSnapshot.structuralElements[0].transform = RoomTransform4x4(columnMajorValues: [
            0, 0, -1, 0,
            0, 1, 0, 0,
            1, 0, 0, 0,
            2, 0, 3, 1,
        ])

        let projection = try RoomFloorPlanProjection.make(from: draft.revision.semanticSnapshot)
        let wall = try XCTUnwrap(projection.items.first { $0.id == "floor-001" })
        let xSpan = (wall.corners.map(\.x).max() ?? 0) - (wall.corners.map(\.x).min() ?? 0)
        let zSpan = (wall.corners.map(\.y).max() ?? 0) - (wall.corners.map(\.y).min() ?? 0)

        XCTAssertEqual(xSpan, 1, accuracy: 0.000_1)
        XCTAssertEqual(zSpan, 4, accuracy: 0.000_1)
    }

    func testHeadExportManifestHasFixtureSkipsAndNativeUSDZByteEqualityWhenDeclared() async throws {
        let root = temporaryRoot("RoomExportEvidence")
        let source = root.deletingLastPathComponent().appendingPathComponent("RoomExportEvidenceSource-\(UUID().uuidString)")
        let workspace = root.deletingLastPathComponent().appendingPathComponent("RoomExportEvidenceWorkspace-\(UUID().uuidString)")
        let archive = root.deletingLastPathComponent().appendingPathComponent("RoomExportEvidence-\(UUID().uuidString).zip")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: archive)
        }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let nativeBytes = Data("native-usdz-byte-proof".utf8)
        let nativeSource = source.appendingPathComponent("RoomScan.usdz")
        try nativeBytes.write(to: nativeSource)
        let rawBytes = Data("captured-room-data".utf8)
        let processedBytes = Data("captured-room".utf8)
        let rawSource = source.appendingPathComponent("captured-room-data.json")
        let processedSource = source.appendingPathComponent("captured-room.json")
        try rawBytes.write(to: rawSource)
        try processedBytes.write(to: processedSource)
        var evidence = makeRoomPlanEvidence(
            rawBytes: rawBytes,
            processedBytes: processedBytes,
            nativeBytes: nativeBytes
        )
        let rawMeshIndex = try XCTUnwrap(evidence.artifacts.firstIndex { $0.kind == .rawMesh })
        evidence.artifacts[rawMeshIndex] = RoomEvidenceArtifact(
            kind: .rawMesh,
            status: .unavailable,
            relativePath: nil,
            byteCount: nil,
            mediaType: nil,
            omissionReason: "Raw mesh is not collected in V1.",
            sha256Hex: nil
        )
        let attachmentBytes = Data("generic-future-attachment".utf8)
        let attachmentSource = source.appendingPathComponent("future-attachment.bin")
        try attachmentBytes.write(to: attachmentSource)
        let store = makeStore(root: root)
        let savedResult = try await store.commitInitialCapture(
            RoomInitialCaptureCommit(
                draft: makeRoomPlanDraft(),
                evidence: evidence,
                assets: [
                    RoomAssetInput(
                        sourceURL: rawSource,
                        destination: try RoomRelativePath("evidence/roomplan/captured-room-data.json"),
                        scope: .revision
                    ),
                    RoomAssetInput(
                        sourceURL: processedSource,
                        destination: try RoomRelativePath("evidence/roomplan/captured-room.json"),
                        scope: .revision
                    ),
                    RoomAssetInput(
                        sourceURL: nativeSource,
                        destination: try RoomRelativePath("evidence/native/RoomScan.usdz"),
                        scope: .revision
                    ),
                    RoomAssetInput(
                        sourceURL: attachmentSource,
                        destination: try RoomRelativePath("attachments/future-attachment.bin"),
                        scope: .revision
                    ),
                ]
            ),
            decision: .save
        )
        let saved = try XCTUnwrap(savedResult)

        let materialized = try await store.materializeHeadForExport(
            projectID: saved.projectID,
            expectedHeadRevisionID: saved.headRevisionID,
            into: workspace
        )
        let native = try XCTUnwrap(materialized.entries.first { $0.entryPath.value == "native/RoomScan.usdz" })
        XCTAssertEqual(try Data(contentsOf: materialized.workspaceURL.appendingPathComponent(native.workspaceRelativePath.value)), nativeBytes)
        let exportedRevision = try RoomJSONCoding.makeDecoder().decode(
            RoomRevisionManifest.self,
            from: Data(contentsOf: workspace.appendingPathComponent("revision/revision.json"))
        )
        let exportedPhotos = try RoomJSONCoding.makeDecoder().decode(
            RoomPhotosDocument.self,
            from: Data(contentsOf: workspace.appendingPathComponent("revision/photos.json"))
        )
        let exportedMetadata = try RoomJSONCoding.makeDecoder().decode(
            RoomMetadata.self,
            from: Data(contentsOf: workspace.appendingPathComponent("metadata.json"))
        )
        let exportedPaths = Set(materialized.entries.map { $0.entryPath.value })
        for artifact in exportedRevision.captureEvidence?.artifacts ?? [] where artifact.status == .present {
            XCTAssertTrue(exportedPaths.contains(try XCTUnwrap(artifact.relativePath).value))
        }
        for photo in exportedPhotos.photos {
            XCTAssertTrue(exportedPaths.contains(photo.assetRelativePath.value))
        }
        if let thumbnail = exportedMetadata.thumbnailRelativePath {
            XCTAssertTrue(exportedPaths.contains(thumbnail.value))
        }
        XCTAssertTrue(exportedPaths.contains("source-map.json"))
        XCTAssertTrue(materialized.sourceMap.allSatisfy { exportedPaths.contains($0.archivePath) })

        let result = try await RoomHeadExportBuilder.build(
            materialization: materialized,
            derivedArtifacts: [
                try makeDerivedArtifact(root: workspace, path: "derived/floor-plan.png", bytes: minimalPNGHeader(), mediaType: "image/png", output: .floorPlanPNG),
                try makeDerivedArtifact(root: workspace, path: "derived/summary.pdf", bytes: Data("%PDF-1.4\n".utf8), mediaType: "application/pdf", output: .pdfSummary, pageCount: 1),
            ],
            archiveURL: archive
        )
        XCTAssertEqual(result.receipt.headRevisionID, saved.headRevisionID)
        XCTAssertTrue(result.manifest.entries.contains { $0.path == "native/RoomScan.usdz" })
        XCTAssertTrue(result.manifest.entries.contains { $0.path == "derived/floor-plan.png" && $0.output == .floorPlanPNG })
        XCTAssertTrue(result.manifest.entries.contains { $0.path == "derived/summary.pdf" && $0.output == .pdfSummary })
        XCTAssertTrue(result.manifest.requestedOutputs.contains { $0.output == .floorPlanPNG && $0.status == .generated })
        XCTAssertTrue(result.manifest.requestedOutputs.contains { $0.output == .pdfSummary && $0.status == .generated })
        XCTAssertTrue(result.manifest.requestedOutputs.contains { $0.output == .glb && $0.status == .skipped && $0.reasonCode == .noVerifiedConverter })
        XCTAssertTrue(result.manifest.entries.contains { $0.output == .attachments })
        XCTAssertTrue(result.manifest.requestedOutputs.contains {
            $0.output == .attachments && $0.status == .included
        })
        XCTAssertTrue(result.manifest.requestedOutputs.contains {
            $0.output == .rawMesh && $0.status == .skipped && $0.reasonCode == .evidenceUnavailable
        })
        XCTAssertTrue(result.manifest.requestedOutputs.contains {
            $0.output == .worldMap && $0.status == .skipped && $0.reasonCode == .notRequested
        })
        XCTAssertTrue(result.manifest.requestedOutputs.contains {
            $0.output == .provenance && $0.status == .skipped && $0.reasonCode == .notRequested
        })
        XCTAssertTrue(result.manifest.requestedOutputs.contains {
            $0.output == .nativeUSDZ && $0.status == .included
        })
        XCTAssertEqual(
            Set(result.manifest.requestedOutputs.map(\.output)),
            Set(RoomExportOutput.allCases)
        )
        XCTAssertEqual(result.manifest.requestedOutputs.count, RoomExportOutput.allCases.count)
    }

    private func makeStore(root: URL, revisionIDs: [String] = ["revision-001"]) -> LocalRoomProjectStore {
        LocalRoomProjectStore(
            rootURL: root,
            clock: FixedRoomProjectClock(date: date),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: ["project-export-001"],
                revisionIDs: revisionIDs
            )
        )
    }

    private func makeDraft() -> RoomDraft {
        RoomDraft(
            metadata: RoomMetadata(
                projectID: "draft-project",
                customName: "Export test room",
                captureDate: date,
                lastRevisedDate: date,
                manualLocation: "Fixture Lab",
                optionalGPS: nil,
                notes: "",
                tags: ["export"],
                thumbnailRelativePath: nil,
                archived: false
            ),
            revision: RoomRevisionPayload(
                semanticSnapshot: RoomSemanticSnapshot(
                    projectID: "draft-project",
                    revisionID: "draft-revision",
                    units: "meters",
                    accuracyDisclaimer: "Measurements are estimates, not survey-grade evidence.",
                    structuralElements: [
                        RoomSemanticElement(
                            id: "floor-001",
                            kind: "floor",
                            label: "Floor",
                            dimensionsMeters: RoomDimensions(width: 5, height: 0, depth: 4),
                            transform: identityTransform(),
                            mobility: .structural
                        )
                    ],
                    objectElements: [
                        RoomSemanticElement(
                            id: "object-001",
                            kind: "desk",
                            label: "Desk",
                            dimensionsMeters: RoomDimensions(width: 1, height: 1, depth: 1),
                            transform: identityTransform(),
                            mobility: .fixed
                        )
                    ]
                ),
                annotations: [],
                measurements: [],
                photos: []
            )
        )
    }

    private func makeRoomPlanDraft() -> RoomDraft {
        var draft = makeDraft()
        let provenance = RoomElementProvenance(
            framework: "RoomPlan",
            sourceIdentifier: "source-001",
            classificationConfidence: .medium,
            captureAttemptID: "attempt-001",
            coordinateSpaceEpochID: "epoch-001"
        )
        draft.revision.semanticSnapshot.structuralElements[0].origin = .roomPlan
        draft.revision.semanticSnapshot.structuralElements[0].provenance = provenance
        draft.revision.semanticSnapshot.objectElements[0].origin = .roomPlan
        draft.revision.semanticSnapshot.objectElements[0].provenance = RoomElementProvenance(
            framework: "RoomPlan",
            sourceIdentifier: "source-002",
            classificationConfidence: .medium,
            captureAttemptID: "attempt-001",
            coordinateSpaceEpochID: "epoch-001"
        )
        return draft
    }

    private func makeRoomPlanEvidence(
        rawBytes: Data,
        processedBytes: Data,
        nativeBytes: Data
    ) -> RoomRevisionEvidencePlan {
        let unavailable: [RoomEvidenceArtifact] = [
            .init(kind: .rawMesh, status: .notRequested, relativePath: nil, byteCount: nil, mediaType: nil, omissionReason: "Not requested.", sha256Hex: nil),
            .init(kind: .worldMap, status: .notRequested, relativePath: nil, byteCount: nil, mediaType: nil, omissionReason: "Not requested.", sha256Hex: nil),
            .init(kind: .provenance, status: .notRequested, relativePath: nil, byteCount: nil, mediaType: nil, omissionReason: "Not requested.", sha256Hex: nil),
        ]
        return RoomRevisionEvidencePlan(
            source: .roomPlan,
            artifacts: unavailable + [
                RoomEvidenceArtifact(
                    kind: .capturedRoomDataJSON,
                    status: .present,
                    relativePath: try! RoomRelativePath("evidence/roomplan/captured-room-data.json"),
                    byteCount: rawBytes.count,
                    mediaType: "application/json",
                    omissionReason: nil,
                    sha256Hex: RoomSHA256.hexDigest(of: rawBytes)
                ),
                RoomEvidenceArtifact(
                    kind: .capturedRoomJSON,
                    status: .present,
                    relativePath: try! RoomRelativePath("evidence/roomplan/captured-room.json"),
                    byteCount: processedBytes.count,
                    mediaType: "application/json",
                    omissionReason: nil,
                    sha256Hex: RoomSHA256.hexDigest(of: processedBytes)
                ),
                RoomEvidenceArtifact(
                    kind: .nativeUSDZ,
                    status: .present,
                    relativePath: try! RoomRelativePath("evidence/native/RoomScan.usdz"),
                    byteCount: nativeBytes.count,
                    mediaType: "model/vnd.usdz+zip",
                    omissionReason: nil,
                    sha256Hex: RoomSHA256.hexDigest(of: nativeBytes)
                )
            ],
            captureAttemptID: "attempt-001",
            coordinateSpaceEpochID: "epoch-001"
        )
    }

    private func makeDerivedArtifact(root: URL, path: String, bytes: Data, mediaType: String, output: RoomExportOutput, pageCount: Int? = nil) throws -> RoomDerivedExportArtifact {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return RoomDerivedExportArtifact(sourceURL: url, entryPath: try RoomExportEntryPath(path), mediaType: mediaType, output: output, pageCount: pageCount)
    }

    private func identityTransform() -> RoomTransform4x4 {
        RoomTransform4x4(columnMajorValues: [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        ])
    }

    private func minimalPNGHeader() -> Data {
        Data([
            137, 80, 78, 71, 13, 10, 26, 10,
            0, 0, 0, 13, 73, 72, 68, 82,
            0, 0, 0, 1, 0, 0, 0, 1,
        ])
    }

    private func temporaryRoot(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }

    private func regularFileSnapshot(_ root: URL) throws -> [String: Data] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [:] }
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys))
        var result: [String: Data] = [:]
        while let url = enumerator?.nextObject() as? URL {
            if try url.resourceValues(forKeys: keys).isRegularFile == true {
                result[url.path.replacingOccurrences(of: root.path + "/", with: "")] = try Data(contentsOf: url)
            }
        }
        return result
    }

    private func isHardLinked(source: URL, copy: URL) throws -> Bool {
        let sourceAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let copyAttributes = try FileManager.default.attributesOfItem(atPath: copy.path)
        guard
            let sourceFileNumber = sourceAttributes[.systemFileNumber] as? NSNumber,
            let copyFileNumber = copyAttributes[.systemFileNumber] as? NSNumber,
            let sourceSystemNumber = sourceAttributes[.systemNumber] as? NSNumber,
            let copySystemNumber = copyAttributes[.systemNumber] as? NSNumber
        else {
            return false
        }
        return sourceFileNumber == copyFileNumber && sourceSystemNumber == copySystemNumber
    }
}

private final class ExportMutationFaultInjector: RoomZIPFaultInjecting, @unchecked Sendable {
    private let sourceURL: URL

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    func throwIfNeeded(at point: RoomZIPWritingFaultPoint) throws {
        if point == .afterPreflight {
            try Data("after".utf8).write(to: sourceURL)
        }
    }
}

private final class BoundedReadObserver: RoomZIPReadObserving, @unchecked Sendable {
    private(set) var maximumObservedRead = 0

    func didRead(byteCount: Int, from entryPath: RoomExportEntryPath) {
        maximumObservedRead = max(maximumObservedRead, byteCount)
    }
}

private extension Data {
    func windows(ofCount count: Int) -> [[UInt8]] {
        let bytes = [UInt8](self)
        guard bytes.count >= count else { return [] }
        return (0...(bytes.count - count)).map { Array(bytes[$0..<($0 + count)]) }
    }
}
