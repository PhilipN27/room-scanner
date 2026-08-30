import Foundation
import XCTest
@testable import RoomScanCore

final class RoomProfessionalWorkingSetArchiveTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_704_067_200)

    func testWorkingSetRedactsOnlyCopiedWorldMapAndRoundTripsExactAllowedClosure() async throws {
        let temporary = makeTemporaryDirectory("ProfessionalWorkingSet")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sourceRoot = temporary.appendingPathComponent("source", isDirectory: true)
        let workspace = temporary.appendingPathComponent("workspace", isDirectory: true)
        let archiveURL = temporary.appendingPathComponent("working-set.zip")
        let extraction = temporary.appendingPathComponent("extraction", isDirectory: true)
        let store = LocalRoomProjectStore(
            rootURL: sourceRoot,
            clock: FixedRoomProjectClock(date: date),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: ["project-001"],
                revisionIDs: ["revision-001"]
            )
        )
        let savedResult = try await store.saveDraft(makeDraft(), decision: .save)
        let saved = try XCTUnwrap(savedResult)
        try installProjectAssets(
            at: sourceRoot.appendingPathComponent(saved.projectID, isDirectory: true)
        )
        let sourceBytes = try fileSnapshot(at: sourceRoot.appendingPathComponent(saved.projectID))

        let materialization = try await store.materializeProfessionalWorkingCopy(
            projectID: saved.projectID,
            expectedHeadRevisionID: saved.headRevisionID,
            into: workspace
        )
        XCTAssertFalse(materialization.backupMaterialization.entries.contains {
            $0.packageRelativePath.value == "assets/world.map"
        })
        XCTAssertTrue(materialization.backupMaterialization.entries.contains {
            $0.packageRelativePath.value == "assets/native.usdz"
        })
        XCTAssertTrue(materialization.backupMaterialization.entries.contains {
            $0.packageRelativePath.value == "assets/raw.usdz"
        })
        XCTAssertTrue(materialization.backupMaterialization.entries.contains {
            $0.packageRelativePath.value == "revisions/revision-001/revision.json"
        })
        let copiedManifest = try copiedProjectManifest(from: materialization.backupMaterialization)
        XCTAssertNil(copiedManifest.assetPolicy?.worldMap)
        XCTAssertEqual(try fileSnapshot(at: sourceRoot.appendingPathComponent(saved.projectID)), sourceBytes)

        let snapshot = try await RoomProfessionalWorkingSetArchive.build(
            workingCopy: materialization,
            archiveURL: archiveURL
        )
        XCTAssertEqual(snapshot.descriptor.projectID, saved.projectID)
        XCTAssertEqual(snapshot.descriptor.headRevisionID, saved.headRevisionID)
        XCTAssertEqual(snapshot.manifest.entries.map(\.kind), [.packageBackup])

        try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: true)
        let recovered = try await RoomProfessionalWorkingSetArchive.extractAndVerify(
            archiveURL: archiveURL,
            expectedDescriptor: snapshot.descriptor,
            into: extraction
        )
        XCTAssertEqual(recovered.manifest, snapshot.manifest)
        XCTAssertEqual(recovered.packageDescriptor, snapshot.descriptor.packageDescriptor)
    }

    func testDownloadedArchiveInspectionDerivesDescriptorOnlyAfterOuterAndManifestDigestsMatch() async throws {
        let temporary = makeTemporaryDirectory("ProfessionalDownloadInspection")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sourceRoot = temporary.appendingPathComponent("source", isDirectory: true)
        let workspace = temporary.appendingPathComponent("workspace", isDirectory: true)
        let archiveURL = temporary.appendingPathComponent("working-set.zip")
        let store = LocalRoomProjectStore(
            rootURL: sourceRoot,
            clock: FixedRoomProjectClock(date: date),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: ["project-001"],
                revisionIDs: ["revision-001"]
            )
        )
        let savedResult = try await store.saveDraft(makeDraft(), decision: .save)
        let saved = try XCTUnwrap(savedResult)
        let workingCopy = try await store.materializeProfessionalWorkingCopy(
            projectID: saved.projectID,
            expectedHeadRevisionID: saved.headRevisionID,
            into: workspace
        )
        let snapshot = try await RoomProfessionalWorkingSetArchive.build(
            workingCopy: workingCopy,
            archiveURL: archiveURL
        )

        let validScratch = temporary.appendingPathComponent("valid-scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: validScratch, withIntermediateDirectories: true)
        let derived = try await RoomProfessionalWorkingSetArchive.inspectDownloadedArchive(
            archiveURL: archiveURL,
            expectedManifestSHA256: snapshot.descriptor.snapshotID,
            expectedArchiveSHA256: snapshot.descriptor.archiveSHA256,
            expectedArchiveByteCount: snapshot.descriptor.archiveByteCount,
            in: validScratch
        )
        XCTAssertEqual(derived, snapshot.descriptor)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: validScratch.path), [])

        let mismatchScratch = temporary.appendingPathComponent("mismatch-scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: mismatchScratch, withIntermediateDirectories: true)
        do {
            _ = try await RoomProfessionalWorkingSetArchive.inspectDownloadedArchive(
                archiveURL: archiveURL,
                expectedManifestSHA256: String(repeating: "0", count: 64),
                expectedArchiveSHA256: snapshot.descriptor.archiveSHA256,
                expectedArchiveByteCount: snapshot.descriptor.archiveByteCount,
                in: mismatchScratch
            )
            XCTFail("Expected a hosted manifest digest mismatch to fail closed.")
        } catch {
            XCTAssertEqual(
                error as? RoomProfessionalArchiveError,
                .descriptorMismatch("Working-set manifest digest differs from the hosted recovery binding.")
            )
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: mismatchScratch.path), [])
    }

    func testDefaultWorkingSetRejectsInjectedRawClassesWhileReviewedRawArchiveAcceptsBoundBytes() async throws {
        let temporary = makeTemporaryDirectory("ProfessionalRawDetector")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sourceRoot = temporary.appendingPathComponent("source", isDirectory: true)
        let workspace = temporary.appendingPathComponent("workspace", isDirectory: true)
        let archiveURL = temporary.appendingPathComponent("working-set.zip")
        let extraction = temporary.appendingPathComponent("extraction", isDirectory: true)
        let rawSource = temporary.appendingPathComponent("raw-rgb.bin")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try Data("raw fixture bytes".utf8).write(to: rawSource)
        let store = LocalRoomProjectStore(
            rootURL: sourceRoot,
            clock: FixedRoomProjectClock(date: date),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: ["project-001"],
                revisionIDs: ["revision-001"]
            )
        )
        let savedResult = try await store.saveDraft(makeDraft(), decision: .save)
        let saved = try XCTUnwrap(savedResult)
        let workingCopy = try await store.materializeProfessionalWorkingCopy(
            projectID: saved.projectID,
            expectedHeadRevisionID: saved.headRevisionID,
            into: workspace
        )
        let snapshot = try await RoomProfessionalWorkingSetArchive.build(
            workingCopy: workingCopy,
            archiveURL: archiveURL
        )

        for rawClass in RoomProfessionalRawAssetClass.allCases {
            let forgedArchive = temporary.appendingPathComponent("forged-\(rawClass.rawValue).zip")
            let forgedDescriptor = try await forgeWorkingSetWithRawEntry(
                snapshot: snapshot,
                archiveURL: archiveURL,
                destinationArchiveURL: forgedArchive,
                rawClass: rawClass,
                rawData: Data(rawClass.rawValue.utf8),
                workspace: temporary.appendingPathComponent("forge-\(rawClass.rawValue)", isDirectory: true)
            )
            try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: true)
            do {
                _ = try await RoomProfessionalWorkingSetArchive.extractAndVerify(
                    archiveURL: forgedArchive,
                    expectedDescriptor: forgedDescriptor,
                    into: extraction
                )
                XCTFail("Expected default working set to reject \(rawClass.rawValue).")
            } catch {
                XCTAssertEqual(
                    error as? RoomProfessionalArchiveError,
                    .forbiddenRawWorkingSetEntry(rawClass)
                )
            }
            try FileManager.default.removeItem(at: extraction)
        }

        let rawInput = try RoomProfessionalRawArchiveInput(
            assetID: "raw-rgb-001",
            assetClass: .rgb,
            sourceURL: rawSource,
            archivePath: "raw/rgb-001.bin",
            mediaType: "application/octet-stream"
        )
        let selectionSHA256 = try await RoomProfessionalRawArchive.selectionSHA256(
            sourceRevision: workingCopy.sourceRevision,
            inputs: [rawInput]
        )
        let review = try RoomRawDisclosureReview(
            reviewID: "raw-review-001",
            sourceRevision: workingCopy.sourceRevision,
            reviewedSelectionSHA256: selectionSHA256,
            reviewedAt: date,
            decision: .accepted
        )
        let rawArchiveURL = temporary.appendingPathComponent("raw.zip")
        let rawSnapshot = try await RoomProfessionalRawArchive.build(
            sourceRevision: workingCopy.sourceRevision,
            review: review,
            inputs: [rawInput],
            archiveURL: rawArchiveURL
        )
        try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: true)
        let extracted = try await RoomProfessionalRawArchive.extractAndVerify(
            archiveURL: rawArchiveURL,
            expectedDescriptor: rawSnapshot.descriptor,
            into: extraction
        )
        XCTAssertEqual(extracted.manifest.entries.map(\.assetClass), [.rgb])
    }

    func testStaleHeadLeavesProfessionalWorkspaceAbsent() async throws {
        let temporary = makeTemporaryDirectory("ProfessionalWorkingSetStaleHead")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sourceRoot = temporary.appendingPathComponent("source", isDirectory: true)
        let workspace = temporary.appendingPathComponent("workspace", isDirectory: true)
        let store = LocalRoomProjectStore(
            rootURL: sourceRoot,
            clock: FixedRoomProjectClock(date: date),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: ["project-001"],
                revisionIDs: ["revision-001"]
            )
        )
        let savedResult = try await store.saveDraft(makeDraft(), decision: .save)
        let saved = try XCTUnwrap(savedResult)

        do {
            _ = try await store.materializeProfessionalWorkingCopy(
                projectID: saved.projectID,
                expectedHeadRevisionID: "revision-stale",
                into: workspace
            )
            XCTFail("Expected stale-head professional materialization rejection.")
        } catch {
            XCTAssertEqual(
                error as? RoomBackupError,
                .staleHead(
                    projectID: saved.projectID,
                    expected: "revision-stale",
                    actual: saved.headRevisionID
                )
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
    }

    func testRawArchiveRequiresAcceptedReviewBoundToExactSourceAndSelection() async throws {
        let temporary = makeTemporaryDirectory("ProfessionalRawReviewBinding")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let rawSource = temporary.appendingPathComponent("raw-depth.bin")
        try Data("raw depth fixture".utf8).write(to: rawSource)
        let source = RoomRedesignSourceRevision(
            projectID: "project-001",
            revisionID: "revision-001",
            coordinateSpaceEpochID: "epoch-001",
            packageSchemaVersion: RoomProjectSchemaVersion.v2.rawValue,
            semanticSHA256: String(repeating: "a", count: 64),
            revisionManifestSHA256: String(repeating: "b", count: 64)
        )
        let input = try RoomProfessionalRawArchiveInput(
            assetID: "raw-depth-001",
            assetClass: .depth,
            sourceURL: rawSource,
            archivePath: "raw/depth-001.bin",
            mediaType: "application/octet-stream"
        )
        let selection = try await RoomProfessionalRawArchive.selectionSHA256(
            sourceRevision: source,
            inputs: [input]
        )

        let rejected = try RoomRawDisclosureReview(
            reviewID: "raw-review-rejected",
            sourceRevision: source,
            reviewedSelectionSHA256: selection,
            reviewedAt: date,
            decision: .rejected
        )
        let rejectedURL = temporary.appendingPathComponent("rejected.zip")
        do {
            _ = try await RoomProfessionalRawArchive.build(
                sourceRevision: source,
                review: rejected,
                inputs: [input],
                archiveURL: rejectedURL
            )
            XCTFail("Expected rejected raw disclosure review to block archive construction.")
        } catch {
            XCTAssertEqual(
                error as? RoomProfessionalSyncContractError,
                .invalidValue(
                    path: "decision",
                    reason: "Raw archive construction requires an accepted disclosure review."
                )
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: rejectedURL.path))
        }

        let otherSource = RoomRedesignSourceRevision(
            projectID: "project-001",
            revisionID: "revision-002",
            coordinateSpaceEpochID: "epoch-002",
            packageSchemaVersion: RoomProjectSchemaVersion.v2.rawValue,
            semanticSHA256: String(repeating: "c", count: 64),
            revisionManifestSHA256: String(repeating: "d", count: 64)
        )
        let otherSelection = try await RoomProfessionalRawArchive.selectionSHA256(
            sourceRevision: otherSource,
            inputs: [input]
        )
        let mismatchedSource = try RoomRawDisclosureReview(
            reviewID: "raw-review-other-source",
            sourceRevision: otherSource,
            reviewedSelectionSHA256: otherSelection,
            reviewedAt: date,
            decision: .accepted
        )
        let mismatchedSourceURL = temporary.appendingPathComponent("wrong-source.zip")
        do {
            _ = try await RoomProfessionalRawArchive.build(
                sourceRevision: source,
                review: mismatchedSource,
                inputs: [input],
                archiveURL: mismatchedSourceURL
            )
            XCTFail("Expected raw review source mismatch to block archive construction.")
        } catch {
            XCTAssertEqual(
                error as? RoomProfessionalArchiveError,
                .invalidValue(
                    path: "review.sourceRevision",
                    reason: "Raw archive review must bind the requested immutable source revision."
                )
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: mismatchedSourceURL.path))
        }

        let mismatchedSelection = try RoomRawDisclosureReview(
            reviewID: "raw-review-other-selection",
            sourceRevision: source,
            reviewedSelectionSHA256: String(repeating: "e", count: 64),
            reviewedAt: date,
            decision: .accepted
        )
        let mismatchedSelectionURL = temporary.appendingPathComponent("wrong-selection.zip")
        do {
            _ = try await RoomProfessionalRawArchive.build(
                sourceRevision: source,
                review: mismatchedSelection,
                inputs: [input],
                archiveURL: mismatchedSelectionURL
            )
            XCTFail("Expected raw review selection mismatch to block archive construction.")
        } catch {
            XCTAssertEqual(
                error as? RoomProfessionalArchiveError,
                .invalidValue(
                    path: "review.reviewedSelectionSHA256",
                    reason: "Raw archive inputs differ from the accepted reviewed selection."
                )
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: mismatchedSelectionURL.path))
        }
    }

    func testWorkingSetIsDeterministicAndRequiresAnOwnedEmptyExtractionDirectory() async throws {
        let temporary = makeTemporaryDirectory("ProfessionalWorkingSetDeterminism")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sourceRoot = temporary.appendingPathComponent("source", isDirectory: true)
        let firstWorkspace = temporary.appendingPathComponent("workspace-one", isDirectory: true)
        let secondWorkspace = temporary.appendingPathComponent("workspace-two", isDirectory: true)
        let firstArchive = temporary.appendingPathComponent("working-one.zip")
        let secondArchive = temporary.appendingPathComponent("working-two.zip")
        let extraction = temporary.appendingPathComponent("nonempty-extraction", isDirectory: true)
        let store = LocalRoomProjectStore(
            rootURL: sourceRoot,
            clock: FixedRoomProjectClock(date: date),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: ["project-001"],
                revisionIDs: ["revision-001"]
            )
        )
        let savedResult = try await store.saveDraft(makeDraft(), decision: .save)
        let saved = try XCTUnwrap(savedResult)
        let firstWorkingCopy = try await store.materializeProfessionalWorkingCopy(
            projectID: saved.projectID,
            expectedHeadRevisionID: saved.headRevisionID,
            into: firstWorkspace
        )
        let secondWorkingCopy = try await store.materializeProfessionalWorkingCopy(
            projectID: saved.projectID,
            expectedHeadRevisionID: saved.headRevisionID,
            into: secondWorkspace
        )
        let first = try await RoomProfessionalWorkingSetArchive.build(
            workingCopy: firstWorkingCopy,
            archiveURL: firstArchive
        )
        let second = try await RoomProfessionalWorkingSetArchive.build(
            workingCopy: secondWorkingCopy,
            archiveURL: secondArchive
        )

        XCTAssertEqual(first.descriptor, second.descriptor)
        XCTAssertEqual(try Data(contentsOf: firstArchive), try Data(contentsOf: secondArchive))

        try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: true)
        try Data("not empty".utf8).write(to: extraction.appendingPathComponent("existing.txt"))
        do {
            _ = try await RoomProfessionalWorkingSetArchive.extractAndVerify(
                archiveURL: firstArchive,
                expectedDescriptor: first.descriptor,
                into: extraction
            )
            XCTFail("Expected nonempty extraction directory rejection.")
        } catch {
            // Expected: extraction requires an already-owned empty directory.
        }
    }

    func testWorkingSetValidatesCompanionPayloadBytesBeforeBuildAndExtraction() async throws {
        let temporary = makeTemporaryDirectory("ProfessionalWorkingSetCompanions")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sourceRoot = temporary.appendingPathComponent("source", isDirectory: true)
        let workingArchive = temporary.appendingPathComponent("working-set.zip")
        let validExtraction = temporary.appendingPathComponent("valid-extraction", isDirectory: true)
        let store = LocalRoomProjectStore(
            rootURL: sourceRoot,
            clock: FixedRoomProjectClock(date: date),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: ["project-001"],
                revisionIDs: ["revision-001"]
            )
        )
        let savedResult = try await store.saveDraft(makeDraft(), decision: .save)
        let saved = try XCTUnwrap(savedResult)
        let projectURL = sourceRoot.appendingPathComponent(saved.projectID, isDirectory: true)
        try installProjectAssets(at: projectURL)
        let worldMapBytes = try Data(contentsOf: projectURL.appendingPathComponent("assets/world.map"))

        let workingCopy = try await store.materializeProfessionalWorkingCopy(
            projectID: saved.projectID,
            expectedHeadRevisionID: saved.headRevisionID,
            into: temporary.appendingPathComponent("workspace-valid", isDirectory: true)
        )
        let redesign = try makeCanonicalRedesignCompanion(sourceRevision: workingCopy.sourceRevision)
        let conceptCompanions = try makeCanonicalConceptSetCompanions(sourceRevision: workingCopy.sourceRevision)
        let validSnapshot = try await RoomProfessionalWorkingSetArchive.build(
            workingCopy: workingCopy,
            archiveURL: workingArchive,
            companions: [redesign] + conceptCompanions
        )
        try FileManager.default.createDirectory(at: validExtraction, withIntermediateDirectories: true)
        let extracted = try await RoomProfessionalWorkingSetArchive.extractAndVerify(
            archiveURL: workingArchive,
            expectedDescriptor: validSnapshot.descriptor,
            into: validExtraction
        )
        XCTAssertEqual(extracted.manifest, validSnapshot.manifest)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: validExtraction.appendingPathComponent(redesign.path).path
        ))

        let malformedBuildCopy = try await store.materializeProfessionalWorkingCopy(
            projectID: saved.projectID,
            expectedHeadRevisionID: saved.headRevisionID,
            into: temporary.appendingPathComponent("workspace-malformed-build", isDirectory: true)
        )
        let disguisedWorldMap = try RoomProfessionalWorkingSetCompanion(
            sourceRevision: malformedBuildCopy.sourceRevision,
            path: "companions/redesign.json",
            kind: .redesignCompanion,
            mediaType: "application/json",
            data: worldMapBytes
        )
        let malformedBuildArchive = temporary.appendingPathComponent("malformed-build.zip")
        do {
            _ = try await RoomProfessionalWorkingSetArchive.build(
                workingCopy: malformedBuildCopy,
                archiveURL: malformedBuildArchive,
                companions: [disguisedWorldMap]
            )
            XCTFail("Expected non-redesign bytes to be rejected before working-set construction.")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: malformedBuildArchive.path))

        let forgedArchive = temporary.appendingPathComponent("forged-redesign.zip")
        let forgedDescriptor = try await forgeWorkingSetReplacingCompanion(
            snapshot: validSnapshot,
            archiveURL: workingArchive,
            destinationArchiveURL: forgedArchive,
            replacementPath: "companions/redesign.json",
            replacementKind: .redesignCompanion,
            replacementMediaType: "application/json",
            replacementData: worldMapBytes,
            workspace: temporary.appendingPathComponent("forge-redesign", isDirectory: true)
        )
        let forgedExtraction = temporary.appendingPathComponent("forged-extraction", isDirectory: true)
        try FileManager.default.createDirectory(at: forgedExtraction, withIntermediateDirectories: true)
        do {
            _ = try await RoomProfessionalWorkingSetArchive.extractAndVerify(
                archiveURL: forgedArchive,
                expectedDescriptor: forgedDescriptor,
                into: forgedExtraction
            )
            XCTFail("Expected a descriptor-recomputed world map disguised as redesign JSON to be rejected.")
        } catch {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: forgedExtraction.path), [])
        }

        let forgedConceptArchive = temporary.appendingPathComponent("forged-concept.zip")
        let forgedConceptDescriptor = try await forgeWorkingSetReplacingCompanion(
            snapshot: validSnapshot,
            archiveURL: workingArchive,
            destinationArchiveURL: forgedConceptArchive,
            replacementPath: "companions/concept-sets/concept-set-001/manifest.json",
            replacementKind: .conceptSetManifest,
            replacementMediaType: "application/json",
            replacementData: worldMapBytes,
            workspace: temporary.appendingPathComponent("forge-concept", isDirectory: true)
        )
        let forgedConceptExtraction = temporary.appendingPathComponent("forged-concept-extraction", isDirectory: true)
        try FileManager.default.createDirectory(at: forgedConceptExtraction, withIntermediateDirectories: true)
        do {
            _ = try await RoomProfessionalWorkingSetArchive.extractAndVerify(
                archiveURL: forgedConceptArchive,
                expectedDescriptor: forgedConceptDescriptor,
                into: forgedConceptExtraction
            )
            XCTFail("Expected a descriptor-recomputed world map disguised as a Concept Set manifest to be rejected.")
        } catch {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: forgedConceptExtraction.path), [])
        }

        let malformedConceptCopy = try await store.materializeProfessionalWorkingCopy(
            projectID: saved.projectID,
            expectedHeadRevisionID: saved.headRevisionID,
            into: temporary.appendingPathComponent("workspace-malformed-concept", isDirectory: true)
        )
        let malformedConcept = try RoomProfessionalWorkingSetCompanion(
            sourceRevision: malformedConceptCopy.sourceRevision,
            path: "companions/concept-sets/concept-set-001/manifest.json",
            kind: .conceptSetManifest,
            mediaType: "application/json",
            data: worldMapBytes
        )
        do {
            _ = try await RoomProfessionalWorkingSetArchive.build(
                workingCopy: malformedConceptCopy,
                archiveURL: temporary.appendingPathComponent("malformed-concept.zip"),
                companions: [malformedConcept]
            )
            XCTFail("Expected arbitrary bytes to be rejected as a Concept Set manifest.")
        } catch {}
    }

    func testProfessionalWorkingCopyPostSnapshotFailureLeavesCallerWorkspaceAbsent() async throws {
        let temporary = makeTemporaryDirectory("ProfessionalWorkingSetRedactionFailure")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sourceRoot = temporary.appendingPathComponent("source", isDirectory: true)
        let workspace = temporary.appendingPathComponent("caller-workspace", isDirectory: true)
        let store = LocalRoomProjectStore(
            rootURL: sourceRoot,
            clock: FixedRoomProjectClock(date: date),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: ["project-001"],
                revisionIDs: ["revision-001"]
            )
        )
        let savedResult = try await store.saveDraft(makeDraft(), decision: .save)
        let saved = try XCTUnwrap(savedResult)
        let projectURL = sourceRoot.appendingPathComponent(saved.projectID, isDirectory: true)
        try installProjectAssets(at: projectURL, worldMapPolicyPath: "assets/native.usdz")
        let sourceBytes = try fileSnapshot(at: projectURL)

        do {
            _ = try await store.materializeProfessionalWorkingCopy(
                projectID: saved.projectID,
                expectedHeadRevisionID: saved.headRevisionID,
                into: workspace
            )
            XCTFail("Expected the distinct-world-map redaction guard to reject the copy after snapshotting.")
        } catch {
            XCTAssertEqual(
                error as? RoomBackupError,
                .invalidBackupManifest("World-map policy cannot share a retained native asset or be absent from the validated package snapshot.")
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: temporary.path).contains {
            $0.hasPrefix(".roomscan-professional-working-copy-stage-")
        })
        XCTAssertEqual(try fileSnapshot(at: projectURL), sourceBytes)
    }

    func testProfessionalWorkingCopyPreMarkerStageFailureDoesNotDeleteMarkerlessCandidate() async throws {
        let temporary = makeTemporaryDirectory("ProfessionalWorkingSetPreMarkerFailure")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

        let sourceRoot = temporary.appendingPathComponent("source", isDirectory: true)
        let workspace = temporary.appendingPathComponent("caller-workspace", isDirectory: true)
        let store = LocalRoomProjectStore(
            rootURL: sourceRoot,
            clock: FixedRoomProjectClock(date: date),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: ["project-001"],
                revisionIDs: ["revision-001"]
            ),
            faultInjector: FailingRoomProjectStoreFaultInjector(
                point: .afterProfessionalWorkingCopyStageDirectoryCreationBeforeMarker
            )
        )
        let savedResult = try await store.saveDraft(makeDraft(), decision: .save)
        let saved = try XCTUnwrap(savedResult)
        let projectURL = sourceRoot.appendingPathComponent(saved.projectID, isDirectory: true)
        let sourceBytes = try fileSnapshot(at: projectURL)

        do {
            _ = try await store.materializeProfessionalWorkingCopy(
                projectID: saved.projectID,
                expectedHeadRevisionID: saved.headRevisionID,
                into: workspace
            )
            XCTFail("Expected the pre-marker stage fault to stop materialization.")
        } catch {
            XCTAssertEqual(
                error as? RoomBackupError,
                .storageFailure("Unable to create a private professional working-copy stage.")
            )
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
        let privateStages = try FileManager.default.contentsOfDirectory(atPath: temporary.path)
            .filter { $0.hasPrefix(".roomscan-professional-working-copy-stage-") }
        XCTAssertEqual(privateStages.count, 1)
        let privateStage = try XCTUnwrap(privateStages.first)
        let privateStageURL = temporary.appendingPathComponent(privateStage, isDirectory: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: privateStageURL.path), [])
        XCTAssertEqual(try fileSnapshot(at: projectURL), sourceBytes)
    }

    func testBuildersRejectSymlinkedArchiveParentBeforeAnyCallerVisibleStaging() async throws {
        let temporary = makeTemporaryDirectory("ProfessionalWorkingSetSymlinkParent")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let realArchiveParent = temporary.appendingPathComponent("real-archive-parent", isDirectory: true)
        let symlinkArchiveParent = temporary.appendingPathComponent("symlink-archive-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: realArchiveParent, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: symlinkArchiveParent,
            withDestinationURL: realArchiveParent
        )

        let sourceRoot = temporary.appendingPathComponent("source", isDirectory: true)
        let store = LocalRoomProjectStore(
            rootURL: sourceRoot,
            clock: FixedRoomProjectClock(date: date),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: ["project-001"],
                revisionIDs: ["revision-001"]
            )
        )
        let savedResult = try await store.saveDraft(makeDraft(), decision: .save)
        let saved = try XCTUnwrap(savedResult)
        let workingCopy = try await store.materializeProfessionalWorkingCopy(
            projectID: saved.projectID,
            expectedHeadRevisionID: saved.headRevisionID,
            into: temporary.appendingPathComponent("workspace", isDirectory: true)
        )
        let workingArchiveURL = symlinkArchiveParent.appendingPathComponent("working-set.zip")
        do {
            _ = try await RoomProfessionalWorkingSetArchive.build(
                workingCopy: workingCopy,
                archiveURL: workingArchiveURL
            )
            XCTFail("Expected a symlinked working-set archive parent to be rejected before staging.")
        } catch {
            XCTAssertEqual(
                error as? RoomProfessionalArchiveError,
                .unsafeArchiveDestination(symlinkArchiveParent.standardizedFileURL.path)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workingArchiveURL.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: realArchiveParent.path), [])

        let rawSourceURL = temporary.appendingPathComponent("raw.bin")
        try Data("raw fixture".utf8).write(to: rawSourceURL)
        let rawInput = try RoomProfessionalRawArchiveInput(
            assetID: "raw-rgb-001",
            assetClass: .rgb,
            sourceURL: rawSourceURL,
            archivePath: "raw/rgb-001.bin",
            mediaType: "application/octet-stream"
        )
        let selection = try await RoomProfessionalRawArchive.selectionSHA256(
            sourceRevision: workingCopy.sourceRevision,
            inputs: [rawInput]
        )
        let review = try RoomRawDisclosureReview(
            reviewID: "raw-review-001",
            sourceRevision: workingCopy.sourceRevision,
            reviewedSelectionSHA256: selection,
            reviewedAt: date,
            decision: .accepted
        )
        let rawArchiveURL = symlinkArchiveParent.appendingPathComponent("raw.zip")
        do {
            _ = try await RoomProfessionalRawArchive.build(
                sourceRevision: workingCopy.sourceRevision,
                review: review,
                inputs: [rawInput],
                archiveURL: rawArchiveURL
            )
            XCTFail("Expected a symlinked raw archive parent to be rejected before manifest staging.")
        } catch {
            XCTAssertEqual(
                error as? RoomProfessionalArchiveError,
                .unsafeArchiveDestination(symlinkArchiveParent.standardizedFileURL.path)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: rawArchiveURL.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: realArchiveParent.path), [])
    }

    private func makeDraft() throws -> RoomDraft {
        let transform = RoomTransform4x4(columnMajorValues: [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        ])
        return RoomDraft(
            metadata: RoomMetadata(
                projectID: "pending-project",
                customName: "Professional room",
                captureDate: date,
                lastRevisedDate: date,
                manualLocation: "",
                optionalGPS: nil,
                notes: "",
                tags: [],
                thumbnailRelativePath: nil,
                archived: false
            ),
            revision: RoomRevisionPayload(
                semanticSnapshot: RoomSemanticSnapshot(
                    projectID: "pending-project",
                    revisionID: "pending-revision",
                    units: "meters",
                    accuracyDisclaimer: "Measurements are estimates, not survey-grade evidence.",
                    structuralElements: [
                        RoomSemanticElement(
                            id: "floor-001",
                            kind: "floor",
                            label: "Floor",
                            dimensionsMeters: .init(width: 4, height: 0.05, depth: 3),
                            transform: transform,
                            provenance: .init(
                                framework: "test",
                                sourceIdentifier: "floor",
                                captureAttemptID: "attempt-001",
                                coordinateSpaceEpochID: "epoch-001"
                            ),
                            mobility: .structural,
                            origin: .deterministicFixture
                        )
                    ],
                    objectElements: []
                ),
                annotations: [],
                measurements: [],
                photos: []
            )
        )
    }

    private func installProjectAssets(
        at projectURL: URL,
        worldMapPolicyPath: String = "assets/world.map"
    ) throws {
        let assets = projectURL.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: false)
        try Data("native usdz".utf8).write(to: assets.appendingPathComponent("native.usdz"))
        try Data("raw mesh".utf8).write(to: assets.appendingPathComponent("raw.usdz"))
        try Data("world map".utf8).write(to: assets.appendingPathComponent("world.map"))
        let manifestURL = projectURL.appendingPathComponent("manifest.json")
        var manifest = try RoomJSONCoding.makeDecoder().decode(RoomProjectManifest.self, from: Data(contentsOf: manifestURL))
        manifest.assetPolicy = RoomAssetPolicy(
            nativeUSDZ: try RoomRelativePath("assets/native.usdz"),
            rawMesh: try RoomRelativePath("assets/raw.usdz"),
            worldMap: try RoomRelativePath(worldMapPolicyPath)
        )
        try RoomJSONCoding.makeEncoder().encode(manifest).write(to: manifestURL)
    }

    private func makeCanonicalRedesignCompanion(
        sourceRevision: RoomRedesignSourceRevision
    ) throws -> RoomProfessionalWorkingSetCompanion {
        let orientation = try RoomCanonicalCameraGenerator.makeOrientation(
            sourceRevision: sourceRevision,
            input: RoomOrientationInput(
                source: .confirmed,
                confidence: 1,
                entryPositionMeters: .init(x: -1, y: 0, z: -1),
                inwardDirection: .init(x: 0, y: 0, z: 1),
                roomBounds: .init(
                    minimum: .init(x: -2, y: 0, z: -2),
                    maximum: .init(x: 2, y: 3, z: 2)
                ),
                referenceWallFeatureID: nil
            )
        )
        let redesign = RoomLocalRedesignExtensionV2(
            sourceRevision: sourceRevision,
            orientation: orientation,
            redesignIntent: nil,
            propertyMembership: nil,
            conceptMetadata: []
        )
        return try RoomProfessionalWorkingSetCompanion(
            sourceRevision: sourceRevision,
            path: "companions/redesign.json",
            kind: .redesignCompanion,
            mediaType: "application/json",
            data: RoomRedesignCanonicalJSON.encode(redesign)
        )
    }

    private func makeCanonicalConceptSetCompanions(
        sourceRevision: RoomRedesignSourceRevision
    ) throws -> [RoomProfessionalWorkingSetCompanion] {
        let image = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        let attachment = RoomConceptSetAttachment(
            attachmentID: "attachment-001",
            relativePath: "attachments/attachment-001.png",
            sha256: RoomSHA256.hexDigest(of: image),
            byteCount: UInt64(image.count),
            mediaType: "image/png",
            sanitizationProvenance: .appReencodedLooseFile,
            mapping: .unmatched
        )
        let conceptSet = RoomConceptSet(
            conceptSetID: "concept-set-001",
            sourceRevision: sourceRevision,
            request: "A lighter material direction.",
            scope: .stage,
            provider: nil,
            sourceAIRoomPackage: nil,
            importProvenance: .init(kind: .looseLocalFile, sourceFilename: "concept.png"),
            createdAt: date,
            importedAt: date,
            attachments: [attachment],
            comments: [],
            approvalState: .pending,
            archiveState: .active
        )
        return [
            try RoomProfessionalWorkingSetCompanion(
                sourceRevision: sourceRevision,
                path: "companions/concept-sets/concept-set-001/manifest.json",
                kind: .conceptSetManifest,
                mediaType: "application/json",
                data: RoomConceptSetCanonicalJSON.encode(conceptSet)
            ),
            try RoomProfessionalWorkingSetCompanion(
                sourceRevision: sourceRevision,
                path: "companions/concept-sets/concept-set-001/attachments/attachment-001.png",
                kind: .conceptSetAttachment,
                mediaType: "image/png",
                data: image
            ),
        ]
    }

    private func copiedProjectManifest(
        from materialization: RoomBackupMaterialization
    ) throws -> RoomProjectManifest {
        let manifest = try XCTUnwrap(materialization.entries.first {
            $0.packageRelativePath.value == "manifest.json"
        })
        return try RoomJSONCoding.makeDecoder().decode(
            RoomProjectManifest.self,
            from: Data(contentsOf: materialization.workspaceURL.appendingPathComponent(manifest.workspaceRelativePath.value))
        )
    }

    private func forgeWorkingSetWithRawEntry(
        snapshot: RoomProfessionalWorkingSetSnapshot,
        archiveURL: URL,
        destinationArchiveURL: URL,
        rawClass: RoomProfessionalRawAssetClass,
        rawData: Data,
        workspace: URL
    ) async throws -> RoomProfessionalWorkingSetDescriptor {
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let extracted = workspace.appendingPathComponent("original", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false)
        _ = try await RoomProfessionalWorkingSetArchive.extractAndVerify(
            archiveURL: archiveURL,
            expectedDescriptor: snapshot.descriptor,
            into: extracted
        )
        let rawPath = "raw/\(rawClass.rawValue)-001.bin"
        let rawURL = workspace.appendingPathComponent(rawPath)
        try FileManager.default.createDirectory(at: rawURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rawData.write(to: rawURL)
        var manifest = snapshot.manifest
        manifest.entries.append(try RoomProfessionalWorkingSetEntry(
            path: rawPath,
            kind: .raw(rawClass),
            mediaType: "application/octet-stream",
            byteCount: UInt64(rawData.count),
            sha256: RoomSHA256.hexDigest(of: rawData)
        ))
        manifest.entries.sort { $0.path < $1.path }
        let manifestData = try RoomProfessionalSyncCanonicalJSON.encode(manifest)
        let manifestURL = workspace.appendingPathComponent(RoomProfessionalWorkingSetArchive.manifestEntryPath)
        try manifestData.write(to: manifestURL)
        let inputs = try manifest.entries.map { entry -> RoomZIPInput in
            let sourceURL: URL
            if entry.path == "package-backup.zip" {
                sourceURL = extracted.appendingPathComponent(entry.path)
            } else if entry.path == rawPath {
                sourceURL = rawURL
            } else {
                sourceURL = extracted.appendingPathComponent(entry.path)
            }
            return RoomZIPInput(
                sourceURL: sourceURL,
                entryPath: try RoomExportEntryPath(entry.path),
                mediaType: entry.mediaType
            )
        } + [RoomZIPInput(
            sourceURL: manifestURL,
            entryPath: try RoomExportEntryPath(RoomProfessionalWorkingSetArchive.manifestEntryPath),
            mediaType: "application/json"
        )]
        let receipt = try await RoomDeterministicZIP.write(inputs: inputs, to: destinationArchiveURL)
        return try RoomProfessionalWorkingSetDescriptor(
            snapshotID: RoomSHA256.hexDigest(of: manifestData),
            projectID: manifest.projectID,
            headRevisionID: manifest.headRevisionID,
            packageDescriptor: manifest.packageDescriptor,
            archiveSHA256: receipt.archiveSHA256,
            archiveByteCount: receipt.archiveByteCount
        )
    }

    private func forgeWorkingSetReplacingCompanion(
        snapshot: RoomProfessionalWorkingSetSnapshot,
        archiveURL: URL,
        destinationArchiveURL: URL,
        replacementPath: String,
        replacementKind: RoomProfessionalWorkingSetEntryKind,
        replacementMediaType: String,
        replacementData: Data,
        workspace: URL
    ) async throws -> RoomProfessionalWorkingSetDescriptor {
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let extracted = workspace.appendingPathComponent("original", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false)
        _ = try await RoomProfessionalWorkingSetArchive.extractAndVerify(
            archiveURL: archiveURL,
            expectedDescriptor: snapshot.descriptor,
            into: extracted
        )
        let replacementURL = workspace.appendingPathComponent("replacement-companion.bin")
        try replacementData.write(to: replacementURL)
        var manifest = snapshot.manifest
        let index = try XCTUnwrap(manifest.entries.firstIndex { $0.path == replacementPath })
        manifest.entries[index] = try RoomProfessionalWorkingSetEntry(
            path: replacementPath,
            kind: replacementKind,
            mediaType: replacementMediaType,
            byteCount: UInt64(replacementData.count),
            sha256: RoomSHA256.hexDigest(of: replacementData)
        )
        manifest.entries.sort { $0.path < $1.path }
        let manifestData = try RoomProfessionalSyncCanonicalJSON.encode(manifest)
        let manifestURL = workspace.appendingPathComponent(RoomProfessionalWorkingSetArchive.manifestEntryPath)
        try manifestData.write(to: manifestURL)
        let inputs = try manifest.entries.map { entry -> RoomZIPInput in
            RoomZIPInput(
                sourceURL: entry.path == replacementPath
                    ? replacementURL
                    : extracted.appendingPathComponent(entry.path),
                entryPath: try RoomExportEntryPath(entry.path),
                mediaType: entry.mediaType
            )
        } + [RoomZIPInput(
            sourceURL: manifestURL,
            entryPath: try RoomExportEntryPath(RoomProfessionalWorkingSetArchive.manifestEntryPath),
            mediaType: "application/json"
        )]
        let receipt = try await RoomDeterministicZIP.write(inputs: inputs, to: destinationArchiveURL)
        return try RoomProfessionalWorkingSetDescriptor(
            snapshotID: RoomSHA256.hexDigest(of: manifestData),
            projectID: manifest.projectID,
            headRevisionID: manifest.headRevisionID,
            packageDescriptor: manifest.packageDescriptor,
            archiveSHA256: receipt.archiveSHA256,
            archiveByteCount: receipt.archiveByteCount
        )
    }

    private func makeTemporaryDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    private func fileSnapshot(at root: URL) throws -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return [:]
        }
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            result[relative] = try Data(contentsOf: url)
        }
        return result
    }
}
