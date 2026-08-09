import Foundation
import XCTest
@testable import RoomScanCore

final class LocalRoomProjectStoreCaptureTests: XCTestCase {
    func testSHA256KnownVectorAndFileDigest() throws {
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let bytes = Data("abc".utf8)
        XCTAssertEqual(RoomSHA256.hexDigest(of: bytes), expected)

        let fileURL = temporaryURL(prefix: "RoomScanSHA256").appendingPathComponent("digest.bin")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try bytes.write(to: fileURL, options: .atomic)
        XCTAssertEqual(try RoomSHA256.hexDigest(ofFile: fileURL), expected)
    }

    func testSHA256HardcodedBoundaryVectorsAndFileChunking() throws {
        let expectedByLength = [
            0: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            55: "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318",
            56: "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a",
            63: "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34",
            64: "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb",
            65: "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0",
            129: "c12cb024a2e5551cca0e08fce8f1c5e314555cc3fef6329ee994a3db752166ae",
        ]

        for (count, expected) in expectedByLength {
            XCTAssertEqual(
                RoomSHA256.hexDigest(of: Data(repeating: 0x61, count: count)),
                expected,
                "repeated-a length \(count)"
            )
        }

        let directory = temporaryURL(prefix: "RoomScanSHA256Chunks")
        let fileURL = directory.appendingPathComponent("multiblock.bin")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: 129).write(to: fileURL, options: .atomic)
        let multiBlockExpected = try XCTUnwrap(expectedByLength[129])

        for chunkSize in [1, 63, 64, 65] {
            XCTAssertEqual(
                try RoomSHA256.hexDigest(ofFile: fileURL, chunkSize: chunkSize),
                multiBlockExpected,
                "chunk size \(chunkSize)"
            )
        }
        XCTAssertThrowsError(try RoomSHA256.hexDigest(ofFile: fileURL, chunkSize: 0))
    }

    func testRoomPlanInitialCommitPromotesDeclaredEvidenceByteForByte() async throws {
        let root = temporaryURL(prefix: "RoomScanEvidenceCommit")
        let prepared = try makePreparedRoomPlanCommit()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: prepared.sourceDirectory)
        }

        let store = makeStore(root: root)
        let savedResult = try await store.commitInitialCapture(
            prepared.commit,
            decision: .save
        )
        let saved = try XCTUnwrap(savedResult)
        let package = try await store.load(projectID: saved.projectID)
        let revision = try XCTUnwrap(package.revisions.first)
        let evidence = try XCTUnwrap(revision.manifest.captureEvidence)

        XCTAssertEqual(evidence.source, .roomPlan)
        XCTAssertEqual(
            evidence.artifacts.filter { $0.status == .present }.count,
            3
        )
        for artifact in evidence.artifacts where artifact.status == .present {
            let path = try XCTUnwrap(artifact.relativePath).value
            let expected = try XCTUnwrap(prepared.bytesByRevisionPath[path])
            let storedURL = root.appendingPathComponent(
                "\(saved.projectID)/revisions/revision-001/\(path)"
            )
            let stored = try Data(contentsOf: storedURL)
            XCTAssertEqual(stored, expected, "evidence path \(path)")
            XCTAssertEqual(artifact.byteCount, expected.count)
            XCTAssertEqual(artifact.sha256Hex, RoomSHA256.hexDigest(of: stored))
        }
    }

    func testDeterministicFixtureEvidenceUsesExplicitOmissionsWithoutBogusPaths() async throws {
        let root = temporaryURL(prefix: "RoomScanFixtureEvidence")
        defer { try? FileManager.default.removeItem(at: root) }

        let draft = try makeDraft()
        let plan = RoomRevisionEvidencePlan(
            source: .deterministicFixture,
            artifacts: RoomEvidenceArtifactKind.allCases.map {
                RoomEvidenceArtifact(
                    kind: $0,
                    status: .unavailable,
                    relativePath: nil,
                    byteCount: nil,
                    mediaType: nil,
                    omissionReason: "Deterministic fixture does not claim Apple capture evidence."
                )
            }
        )
        let commit = RoomInitialCaptureCommit(draft: draft, evidence: plan, assets: [])
        let store = makeStore(root: root)

        let savedResult = try await store.commitInitialCapture(commit, decision: .save)
        let saved = try XCTUnwrap(savedResult)
        let package = try await store.load(projectID: saved.projectID)
        let storedPlan = try XCTUnwrap(package.revisions.first?.manifest.captureEvidence)

        XCTAssertEqual(storedPlan, plan)
        for artifact in storedPlan.artifacts {
            XCTAssertNotEqual(artifact.status, .present)
            XCTAssertNil(artifact.relativePath)
            XCTAssertNil(artifact.byteCount)
            XCTAssertFalse((artifact.omissionReason ?? "").isEmpty)
        }
    }

    func testDiscardFullyFormedInitialCommitCreatesNoRootAndConsumesNoIdentifiers() async throws {
        let root = temporaryURL(prefix: "RoomScanDiscardCommit")
        let prepared = try makePreparedRoomPlanCommit()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: prepared.sourceDirectory)
        }

        let store = makeStore(root: root)
        let discarded = try await store.commitInitialCapture(
            prepared.commit,
            decision: .discard
        )

        XCTAssertNil(discarded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

        let savedResult = try await store.commitInitialCapture(
            prepared.commit,
            decision: .save
        )
        let saved = try XCTUnwrap(savedResult)
        XCTAssertEqual(saved.projectID, "capture-project-001")
    }

    func testEvidenceContractFailuresLeaveNoFinalPackageOrStagingResidue() async throws {
        let missingPrepared = try makePreparedRoomPlanCommit()
        defer { try? FileManager.default.removeItem(at: missingPrepared.sourceDirectory) }
        var missingCommit = missingPrepared.commit
        missingCommit.assets.removeAll {
            $0.destination.value == "evidence/roomplan/captured-room-data.json"
        }
        try await assertCommitRejected(missingCommit, label: "missing evidence")

        let duplicatePrepared = try makePreparedRoomPlanCommit()
        defer { try? FileManager.default.removeItem(at: duplicatePrepared.sourceDirectory) }
        var duplicateCommit = duplicatePrepared.commit
        var duplicatePlan = try XCTUnwrap(duplicateCommit.evidence)
        duplicatePlan.artifacts.append(try XCTUnwrap(duplicatePlan.artifacts.first))
        duplicateCommit.evidence = duplicatePlan
        try await assertCommitRejected(duplicateCommit, label: "duplicate evidence kind")

        let aliasPrepared = try makePreparedRoomPlanCommit()
        defer { try? FileManager.default.removeItem(at: aliasPrepared.sourceDirectory) }
        var aliasCommit = aliasPrepared.commit
        var aliasPlan = try XCTUnwrap(aliasCommit.evidence)
        let capturedDataPath = try XCTUnwrap(
            aliasPlan.artifacts.first { $0.kind == .capturedRoomDataJSON }?.relativePath
        )
        let processedIndex = try XCTUnwrap(
            aliasPlan.artifacts.firstIndex { $0.kind == .capturedRoomJSON }
        )
        aliasPlan.artifacts[processedIndex].relativePath = capturedDataPath
        aliasCommit.evidence = aliasPlan
        try await assertCommitRejected(aliasCommit, label: "aliased evidence paths")

        let unlistedPrepared = try makePreparedRoomPlanCommit()
        defer { try? FileManager.default.removeItem(at: unlistedPrepared.sourceDirectory) }
        let unlistedSource = unlistedPrepared.sourceDirectory.appendingPathComponent("unlisted.bin")
        try Data("undeclared-evidence".utf8).write(to: unlistedSource, options: .atomic)
        var unlistedCommit = unlistedPrepared.commit
        unlistedCommit.assets.append(
            RoomAssetInput(
                sourceURL: unlistedSource,
                destination: try RoomRelativePath("evidence/arkit/unlisted.bin"),
                scope: .revision
            )
        )
        try await assertCommitRejected(unlistedCommit, label: "undeclared evidence asset")

        let invalidPathPrepared = try makePreparedRoomPlanCommit()
        defer { try? FileManager.default.removeItem(at: invalidPathPrepared.sourceDirectory) }
        var invalidPathCommit = invalidPathPrepared.commit
        var invalidPathPlan = try XCTUnwrap(invalidPathCommit.evidence)
        invalidPathPlan.artifacts[0].relativePath = try RoomRelativePath("photos/not-evidence.json")
        invalidPathCommit.evidence = invalidPathPlan
        try await assertCommitRejected(invalidPathCommit, label: "evidence outside evidence scope")
        XCTAssertThrowsError(try RoomRelativePath("../evidence/escape.json"))

        let symlinkPrepared = try makePreparedRoomPlanCommit()
        defer { try? FileManager.default.removeItem(at: symlinkPrepared.sourceDirectory) }
        let symlinkURL = symlinkPrepared.sourceDirectory.appendingPathComponent("linked-data.json")
        let sourceURL = try XCTUnwrap(
            symlinkPrepared.commit.assets.first {
                $0.destination.value == "evidence/roomplan/captured-room-data.json"
            }
        ).sourceURL
        try FileManager.default.createSymbolicLink(
            atPath: symlinkURL.path,
            withDestinationPath: sourceURL.path
        )
        var symlinkCommit = symlinkPrepared.commit
        let sourceIndex = try XCTUnwrap(
            symlinkCommit.assets.firstIndex {
                $0.destination.value == "evidence/roomplan/captured-room-data.json"
            }
        )
        symlinkCommit.assets[sourceIndex] = RoomAssetInput(
            sourceURL: symlinkURL,
            destination: symlinkCommit.assets[sourceIndex].destination,
            scope: .revision
        )
        try await assertCommitRejected(symlinkCommit, label: "symbolic-link evidence source")

        let sizePrepared = try makePreparedRoomPlanCommit()
        defer { try? FileManager.default.removeItem(at: sizePrepared.sourceDirectory) }
        var sizeCommit = sizePrepared.commit
        var sizePlan = try XCTUnwrap(sizeCommit.evidence)
        sizePlan.artifacts[0].byteCount = (sizePlan.artifacts[0].byteCount ?? 0) + 1
        sizeCommit.evidence = sizePlan
        try await assertCommitRejected(sizeCommit, label: "declared evidence size mismatch")
    }

    func testInitialCaptureRejectsAssetInputFromConfiguredPackageRoot() async throws {
        let root = temporaryURL(prefix: "RoomScanInitialSourceBoundary")
        let prepared = try makePreparedRoomPlanCommit()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: prepared.sourceDirectory)
        }

        let rootScratch = root.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: rootScratch, withIntermediateDirectories: true)
        let rootSource = rootScratch.appendingPathComponent("captured-room-data.json")
        let expectedBytes = try XCTUnwrap(
            prepared.bytesByRevisionPath["evidence/roomplan/captured-room-data.json"]
        )
        try expectedBytes.write(to: rootSource, options: .atomic)

        var commit = prepared.commit
        let sourceIndex = try XCTUnwrap(
            commit.assets.firstIndex {
                $0.destination.value == "evidence/roomplan/captured-room-data.json"
            }
        )
        commit.assets[sourceIndex] = RoomAssetInput(
            sourceURL: rootSource,
            destination: commit.assets[sourceIndex].destination,
            scope: .revision
        )
        let store = makeStore(root: root)

        do {
            _ = try await store.commitInitialCapture(commit, decision: .save)
            XCTFail("Expected an initial capture to reject a configured-root source file.")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: root.appendingPathComponent("capture-project-001").path
            ))
        }
    }

    func testPublicInitialCaptureAndAppendRejectPlanlessEvidenceAssetInputs() async throws {
        let prepared = try makePreparedRoomPlanCommit()
        let root = temporaryURL(prefix: "RoomScanPlanlessEvidencePublicInput")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: prepared.sourceDirectory)
        }
        var planlessCommit = prepared.commit
        planlessCommit.evidence = nil

        try await assertCommitRejected(
            planlessCommit,
            label: "public initial capture with planless evidence assets"
        )

        let store = makeStore(root: root)
        let initialResult = try await store.commitInitialCapture(
            RoomInitialCaptureCommit(draft: try makeDraft()),
            decision: .save
        )
        let initial = try XCTUnwrap(initialResult)
        let package = try await store.load(projectID: initial.projectID)
        let planlessEvidenceAsset = try XCTUnwrap(
            planlessCommit.assets.first { $0.destination.value.hasPrefix("evidence/") }
        )

        do {
            _ = try await store.appendRevision(
                projectID: initial.projectID,
                revisionID: "revision-002",
                parentRevisionID: "revision-001",
                reason: .edit,
                payload: try XCTUnwrap(package.revisions.first).payload,
                restoredFromRevisionID: nil,
                assets: [planlessEvidenceAsset],
                captureEvidence: nil
            )
            XCTFail("Expected a public append to reject planless evidence assets.")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    "\(initial.projectID)/revisions/revision-002"
                ).path
            ))
        }
    }

    func testStrictV2AndNewV1AppendRejectInjectedCanonicalEvidence() async throws {
        let root = temporaryURL(prefix: "RoomScanStrictEvidenceCompatibility")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)

        let newProjectResult = try await store.commitInitialCapture(
            RoomInitialCaptureCommit(draft: try makeDraft()),
            decision: .save
        )
        let newProject = try XCTUnwrap(newProjectResult)
        let newPackage = try await store.load(projectID: newProject.projectID)
        XCTAssertEqual(
            newPackage.manifest.schemaVersion,
            RoomProjectSchemaVersion.v2.rawValue
        )
        XCTAssertEqual(
            newPackage.revisions.first?.manifest.evidenceCompatibility,
            .strict
        )

        let missingModeProjectResult = try await store.commitInitialCapture(
            RoomInitialCaptureCommit(draft: try makeDraft()),
            decision: .save
        )
        let missingModeProject = try XCTUnwrap(missingModeProjectResult)
        let missingModePackage = try await store.load(
            projectID: missingModeProject.projectID
        )
        let missingModeRevisionID = try XCTUnwrap(
            missingModePackage.revisions.first?.manifest.revisionID
        )
        try removeRevisionEvidenceCompatibility(
            root: root,
            projectID: missingModeProject.projectID,
            revisionID: missingModeRevisionID
        )
        await assertInvalidEvidencePlanOnLoad(
            store,
            projectID: missingModeProject.projectID,
            label: "v2 revision with a missing compatibility mode"
        )

        try writeCanonicalEvidenceInjection(
            root: root,
            projectID: newProject.projectID,
            revisionID: "revision-001"
        )
        await assertInvalidEvidencePlanOnLoad(
            store,
            projectID: newProject.projectID,
            label: "new v2 no-plan revision"
        )

        let legacy = try writeLegacyPlanlessEvidencePackage(at: root)
        let legacyPackage = try await store.load(projectID: legacy.projectID)
        let sourceRevision = try XCTUnwrap(legacyPackage.revisions.first)
        XCTAssertEqual(
            legacyPackage.manifest.schemaVersion,
            RoomProjectSchemaVersion.v1.rawValue
        )
        XCTAssertNil(sourceRevision.manifest.evidenceCompatibility)

        let appended = try await store.appendRevision(
            projectID: legacy.projectID,
            revisionID: "revision-002",
            parentRevisionID: legacy.revisionID,
            reason: .edit,
            payload: sourceRevision.payload,
            restoredFromRevisionID: nil
        )
        XCTAssertEqual(appended.evidenceCompatibility, .strict)
        try writeCanonicalEvidenceInjection(
            root: root,
            projectID: legacy.projectID,
            revisionID: "revision-002"
        )
        await assertInvalidEvidencePlanOnLoad(
            store,
            projectID: legacy.projectID,
            label: "new strict append in v1 project"
        )
    }

    func testEvidenceNamespaceCasingIsRejectedOnPublicWriteAndLoad() async throws {
        let prepared = try makePreparedRoomPlanCommit()
        defer { try? FileManager.default.removeItem(at: prepared.sourceDirectory) }

        let uppercaseSource = prepared.sourceDirectory.appendingPathComponent("case-alias.bin")
        try Data("case-alias".utf8).write(to: uppercaseSource, options: .atomic)

        // A new plan-less public write must not treat `Evidence/` as a
        // separate namespace on a case-sensitive host (or collide with the
        // reserved `evidence/` directory on a case-insensitive host).
        let planlessUppercaseCommit = RoomInitialCaptureCommit(
            draft: try makeDraft(),
            evidence: nil,
            assets: [
                RoomAssetInput(
                    sourceURL: uppercaseSource,
                    destination: try RoomRelativePath("Evidence/legacy.bin"),
                    scope: .revision
                ),
            ]
        )
        try await assertCommitRejected(
            planlessUppercaseCommit,
            label: "uppercase planless evidence namespace"
        )

        // A declared plan cannot smuggle a second case-aliased evidence tree
        // past the lowercase closure either.
        var declaredPlanCommit = prepared.commit
        declaredPlanCommit.assets.append(
            RoomAssetInput(
                sourceURL: uppercaseSource,
                destination: try RoomRelativePath("Evidence/unlisted.bin"),
                scope: .revision
            )
        )
        try await assertCommitRejected(
            declaredPlanCommit,
            label: "case-aliased unlisted evidence asset"
        )

        let root = temporaryURL(prefix: "RoomScanCaseAliasedEvidence")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let omissions = RoomRevisionEvidencePlan(
            source: .deterministicFixture,
            artifacts: RoomEvidenceArtifactKind.allCases.map {
                RoomEvidenceArtifact(
                    kind: $0,
                    status: .unavailable,
                    relativePath: nil,
                    byteCount: nil,
                    mediaType: nil,
                    omissionReason: "Fixture evidence is intentionally unavailable."
                )
            }
        )
        let savedResult = try await store.commitInitialCapture(
            RoomInitialCaptureCommit(draft: try makeDraft(), evidence: omissions),
            decision: .save
        )
        let saved = try XCTUnwrap(savedResult)
        let aliasURL = root.appendingPathComponent(
            "\(saved.projectID)/revisions/revision-001/Evidence/unlisted.bin"
        )
        try FileManager.default.createDirectory(
            at: aliasURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("case-aliased-on-disk".utf8).write(to: aliasURL, options: .atomic)

        do {
            _ = try await store.load(projectID: saved.projectID)
            XCTFail("Expected a case-aliased evidence directory to fail closed on load.")
        } catch let error as RoomProjectStoreError {
            guard case .invalidEvidencePlan = error else {
                return XCTFail("Expected invalid evidence plan, got \(error).")
            }
        }
    }

    func testLegacyPlanlessEvidencePackageLoadsAndPreservesBytesThroughRestoreAndDuplicate() async throws {
        let root = temporaryURL(prefix: "RoomScanLegacyPlanlessEvidence")
        defer { try? FileManager.default.removeItem(at: root) }

        let legacy = try writeLegacyPlanlessEvidencePackage(at: root)
        let store = makeStore(
            root: root,
            projectIDs: ["legacy-copy-001"],
            revisionIDs: ["duplicate-revision-001"]
        )

        let loaded = try await store.load(projectID: legacy.projectID)
        XCTAssertEqual(
            loaded.manifest.schemaVersion,
            RoomProjectSchemaVersion.v1.rawValue
        )
        XCTAssertNil(loaded.revisions.first?.manifest.captureEvidence)
        XCTAssertNil(loaded.revisions.first?.manifest.evidenceCompatibility)
        XCTAssertEqual(
            try Data(contentsOf: legacy.evidenceURL),
            legacy.evidenceBytes
        )

        let restored = try await store.restoreAsNewRevision(
            projectID: legacy.projectID,
            sourceRevisionID: legacy.revisionID,
            newRevisionID: "revision-002"
        )
        XCTAssertNil(restored.captureEvidence)
        XCTAssertEqual(restored.evidenceCompatibility, .legacyV1Planless)
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent(
                "\(legacy.projectID)/revisions/revision-002/evidence/native-room.usdz"
            )),
            legacy.evidenceBytes
        )

        let duplicate = try await store.duplicate(projectID: legacy.projectID)
        let duplicatePackage = try await store.load(projectID: duplicate.projectID)
        let duplicateHead = try XCTUnwrap(duplicatePackage.revisions.last)
        XCTAssertNil(duplicateHead.manifest.captureEvidence)
        XCTAssertEqual(
            duplicateHead.manifest.evidenceCompatibility,
            .legacyV1Planless
        )
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent(
                "\(duplicate.projectID)/revisions/\(duplicateHead.manifest.revisionID)/evidence/native-room.usdz"
            )),
            legacy.evidenceBytes
        )
    }

    func testRoomPlanProvenanceRejectsMissingOrMismatchedAttemptEpoch() async throws {
        let missingPrepared = try makePreparedRoomPlanCommit()
        defer { try? FileManager.default.removeItem(at: missingPrepared.sourceDirectory) }
        var missingCommit = missingPrepared.commit
        var missingEvidence = try XCTUnwrap(missingCommit.evidence)
        missingEvidence.captureAttemptID = nil
        missingCommit.evidence = missingEvidence
        try await assertCommitRejected(missingCommit, label: "missing RoomPlan capture attempt")

        let mismatchPrepared = try makePreparedRoomPlanCommit()
        defer { try? FileManager.default.removeItem(at: mismatchPrepared.sourceDirectory) }
        var mismatchCommit = mismatchPrepared.commit
        mismatchCommit.draft.revision.semanticSnapshot.structuralElements[0].provenance =
            RoomElementProvenance(
                framework: "RoomPlan",
                sourceIdentifier: "captured-wall-001",
                parentSourceIdentifier: "captured-room-001",
                classificationConfidence: .high,
                flattenedAttributeIdentifiers: ["wall"],
                captureAttemptID: "capture-attempt-other",
                coordinateSpaceEpochID: "coordinate-epoch-001"
            )
        try await assertCommitRejected(mismatchCommit, label: "mismatched RoomPlan provenance")
    }

    func testRoomPlanEvidenceRequiresCompleteCoordinateBoundElementOrigins() async throws {
        let missingOriginPrepared = try makePreparedRoomPlanCommit()
        defer { try? FileManager.default.removeItem(at: missingOriginPrepared.sourceDirectory) }
        var missingOrigin = missingOriginPrepared.commit
        missingOrigin.draft.revision.semanticSnapshot.structuralElements[0].origin = nil
        try await assertCommitRejected(missingOrigin, label: "missing RoomPlan element origin")

        let missingProvenancePrepared = try makePreparedRoomPlanCommit()
        defer { try? FileManager.default.removeItem(at: missingProvenancePrepared.sourceDirectory) }
        var missingProvenance = missingProvenancePrepared.commit
        missingProvenance.draft.revision.semanticSnapshot.structuralElements[0].provenance = nil
        try await assertCommitRejected(
            missingProvenance,
            label: "missing coordinate-bound RoomPlan provenance"
        )

        let partialProvenancePrepared = try makePreparedRoomPlanCommit()
        defer { try? FileManager.default.removeItem(at: partialProvenancePrepared.sourceDirectory) }
        var partialProvenance = partialProvenancePrepared.commit
        partialProvenance.draft.revision.semanticSnapshot.structuralElements[0].provenance =
            RoomElementProvenance(
                framework: "",
                sourceIdentifier: "captured-wall-001",
                parentSourceIdentifier: "captured-room-001",
                classificationConfidence: .high,
                flattenedAttributeIdentifiers: ["wall"],
                captureAttemptID: "capture-attempt-001",
                coordinateSpaceEpochID: "coordinate-epoch-001"
            )
        try await assertCommitRejected(
            partialProvenance,
            label: "empty RoomPlan provenance framework"
        )

        for invalidOrigin in [
            RoomElementOrigin.deterministicFixture,
            .legacyUnknown,
        ] {
            let invalidOriginPrepared = try makePreparedRoomPlanCommit()
            defer { try? FileManager.default.removeItem(at: invalidOriginPrepared.sourceDirectory) }
            var invalidOriginCommit = invalidOriginPrepared.commit
            invalidOriginCommit.draft.revision.semanticSnapshot.structuralElements[0].origin =
                invalidOrigin
            try await assertCommitRejected(
                invalidOriginCommit,
                label: "RoomPlan evidence origin \(invalidOrigin.rawValue)"
            )
        }

        let manualPrepared = try makePreparedRoomPlanCommit()
        defer { try? FileManager.default.removeItem(at: manualPrepared.sourceDirectory) }
        var manualCommit = manualPrepared.commit
        manualCommit.draft.revision.semanticSnapshot.structuralElements[0].origin = .manual
        manualCommit.draft.revision.semanticSnapshot.structuralElements[0].provenance =
            RoomElementProvenance(
                framework: "RoomScanStudio",
                sourceIdentifier: "manual-wall-001",
                parentSourceIdentifier: nil,
                classificationConfidence: .unknown,
                flattenedAttributeIdentifiers: ["manual.wall"],
                captureAttemptID: "capture-attempt-001",
                coordinateSpaceEpochID: "coordinate-epoch-001"
            )
        let manualRoot = temporaryURL(prefix: "RoomScanManualRoomPlanElement")
        defer { try? FileManager.default.removeItem(at: manualRoot) }
        let manualStore = makeStore(root: manualRoot)
        let savedResult = try await manualStore.commitInitialCapture(
            manualCommit,
            decision: .save
        )
        let saved = try XCTUnwrap(savedResult)
        let savedPackage = try await manualStore.load(projectID: saved.projectID)
        XCTAssertEqual(
            savedPackage.revisions.first?.payload.semanticSnapshot.structuralElements.first?.origin,
            .manual
        )
    }

    func testTamperedEvidenceFailsClosedOnLoad() async throws {
        let root = temporaryURL(prefix: "RoomScanTamperedEvidence")
        let prepared = try makePreparedRoomPlanCommit()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: prepared.sourceDirectory)
        }

        let store = makeStore(root: root)
        let savedResult = try await store.commitInitialCapture(prepared.commit, decision: .save)
        let saved = try XCTUnwrap(savedResult)
        let nativeURL = root.appendingPathComponent(
            "\(saved.projectID)/revisions/revision-001/evidence/native/RoomScan.usdz"
        )
        let originalNativeBytes = try Data(contentsOf: nativeURL)
        let sameLengthTamper = Data(
            originalNativeBytes.map { byte in byte == 0x5A ? 0xA5 : 0x5A }
        )
        XCTAssertEqual(sameLengthTamper.count, originalNativeBytes.count)
        XCTAssertNotEqual(sameLengthTamper, originalNativeBytes)
        try sameLengthTamper.write(to: nativeURL, options: .atomic)

        do {
            _ = try await store.load(projectID: saved.projectID)
            XCTFail("Expected evidence integrity validation to reject tampering.")
        } catch {
            // Expected: the same-length replacement no longer matches its digest.
        }
    }

    func testRestoreAndDuplicatePreserveHeadPhotosEvidenceAndThumbnailBytes() async throws {
        let root = temporaryURL(prefix: "RoomScanRestoreDuplicateEvidence")
        let prepared = try makePreparedRoomPlanCommit()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: prepared.sourceDirectory)
        }

        let store = makeStore(
            root: root,
            projectIDs: ["capture-project-001", "capture-project-002"],
            revisionIDs: ["revision-001", "revision-002", "revision-003"]
        )
        let initialResult = try await store.commitInitialCapture(prepared.commit, decision: .save)
        let initial = try XCTUnwrap(initialResult)
        let originalRevisionRoot = root.appendingPathComponent(
            "\(initial.projectID)/revisions/revision-001"
        )

        let restored = try await store.restoreAsNewRevision(
            projectID: initial.projectID,
            sourceRevisionID: "revision-001",
            newRevisionID: "revision-002"
        )
        XCTAssertEqual(restored.captureEvidence, prepared.commit.evidence)
        let restoredRevisionRoot = root.appendingPathComponent(
            "\(initial.projectID)/revisions/revision-002"
        )

        let duplicate = try await store.duplicate(projectID: initial.projectID)
        let duplicatePackage = try await store.load(projectID: duplicate.projectID)
        let duplicateHead = try XCTUnwrap(duplicatePackage.revisions.last)
        XCTAssertEqual(duplicateHead.manifest.reason, .duplicate)
        XCTAssertEqual(duplicateHead.manifest.captureEvidence, prepared.commit.evidence)
        XCTAssertEqual(duplicateHead.payload.photos.count, 1)
        let duplicateRevisionRoot = root.appendingPathComponent(
            "\(duplicate.projectID)/revisions/\(duplicateHead.manifest.revisionID)"
        )
        for artifact in try XCTUnwrap(prepared.commit.evidence).artifacts where artifact.status == .present {
            let path = try XCTUnwrap(artifact.relativePath).value
            let sourceBytes = try Data(contentsOf: originalRevisionRoot.appendingPathComponent(path))
            XCTAssertEqual(
                try Data(contentsOf: restoredRevisionRoot.appendingPathComponent(path)),
                sourceBytes,
                "restore should retain \(path)"
            )
            XCTAssertEqual(
                try Data(contentsOf: duplicateRevisionRoot.appendingPathComponent(path)),
                sourceBytes,
                "duplicate should retain \(path)"
            )
        }
        let duplicatePhotoURL = root.appendingPathComponent(
            "\(duplicate.projectID)/revisions/\(duplicateHead.manifest.revisionID)/photos/photo-001.jpg"
        )
        XCTAssertEqual(
            try Data(contentsOf: duplicatePhotoURL),
            try XCTUnwrap(prepared.bytesByRevisionPath["photos/photo-001.jpg"])
        )
        let duplicateThumbnail = try await store.thumbnailData(projectID: duplicate.projectID)
        XCTAssertEqual(duplicateThumbnail, prepared.thumbnailBytes)
    }

    func testStoreRejectsInvalidSpatialGPSAndMeasurementValues() async throws {
        let mutations: [(String, (inout RoomDraft) throws -> Void)] = [
            ("degenerate structural surface", { draft in
                draft.revision.semanticSnapshot.structuralElements[0].dimensionsMeters.width = 0
                draft.revision.semanticSnapshot.structuralElements[0].dimensionsMeters.depth = 0
            }),
            ("nonfinite point", { draft in
                draft.revision.semanticSnapshot.structuralElements[0].polygonCorners = [
                    RoomPoint3D(x: .nan, y: 0, z: 0),
                ]
            }),
            ("invalid transform count", { draft in
                draft.revision.semanticSnapshot.structuralElements[0].transform = RoomTransform4x4(
                    columnMajorValues: Array(repeating: 1, count: 15)
                )
            }),
            ("nonfinite transform", { draft in
                draft.revision.semanticSnapshot.structuralElements[0].transform = RoomTransform4x4(
                    columnMajorValues: [
                        .infinity, 0, 0, 0,
                        0, 1, 0, 0,
                        0, 0, 1, 0,
                        0, 0, 0, 1,
                    ]
                )
            }),
            ("invalid GPS", { draft in
                draft.metadata.optionalGPS = RoomGPSLocation(
                    latitude: 91,
                    longitude: 0,
                    horizontalAccuracyMeters: 1,
                    capturedAt: Date(timeIntervalSince1970: 1_704_067_200)
                )
            }),
            ("negative GPS accuracy", { draft in
                draft.metadata.optionalGPS = RoomGPSLocation(
                    latitude: 0,
                    longitude: 0,
                    horizontalAccuracyMeters: -1,
                    capturedAt: Date(timeIntervalSince1970: 1_704_067_200)
                )
            }),
            ("negative measurement", { draft in
                draft.revision.measurements[0].valueMeters = -0.01
            }),
        ]

        for (label, mutate) in mutations {
            let root = temporaryURL(prefix: "RoomScanInvalid-\(label.replacingOccurrences(of: " ", with: "-"))")
            defer { try? FileManager.default.removeItem(at: root) }
            var draft = try makeDraft()
            try mutate(&draft)
            let store = makeStore(root: root)

            do {
                _ = try await store.commitInitialCapture(
                    RoomInitialCaptureCommit(draft: draft, evidence: nil, assets: []),
                    decision: .save
                )
                XCTFail("Expected \(label) to be rejected.")
            } catch {
                XCTAssertFalse(FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("capture-project-001").path
                ))
            }
        }
    }

    func testStoreAcceptsZeroOutOfPlaneStructuralSurface() async throws {
        let root = temporaryURL(prefix: "RoomScanStructuralSurface")
        defer { try? FileManager.default.removeItem(at: root) }

        var draft = try makeDraft()
        draft.revision.semanticSnapshot.structuralElements[0].dimensionsMeters.depth = 0
        draft.revision.semanticSnapshot.structuralElements[0].mobility = .structural
        let store = makeStore(root: root)

        let saved = try await store.commitInitialCapture(
            RoomInitialCaptureCommit(draft: draft),
            decision: .save
        )
        let summary = try XCTUnwrap(saved)
        let loaded = try await store.load(projectID: summary.projectID)
        XCTAssertEqual(
            loaded.revisions[0].payload.semanticSnapshot.structuralElements[0].dimensionsMeters.depth,
            0
        )
    }

    func testStoreAllowsFixedAndUnknownObjectMobility() async throws {
        let root = temporaryURL(prefix: "RoomScanObjectMobility")
        defer { try? FileManager.default.removeItem(at: root) }

        var draft = try makeDraft()
        draft.revision.semanticSnapshot.objectElements = [
            RoomSemanticElement(
                id: "fixed-cabinet-001",
                kind: "cabinet",
                label: "Cabinet",
                dimensionsMeters: RoomDimensions(width: 1.2, height: 0.9, depth: 0.5),
                mobility: .fixed
            ),
            RoomSemanticElement(
                id: "unknown-object-001",
                kind: "object",
                label: "Unknown object",
                dimensionsMeters: RoomDimensions(width: 0.4, height: 0.4, depth: 0.4),
                mobility: .unknown
            ),
        ]
        let store = makeStore(root: root)

        let saved = try await store.commitInitialCapture(
            RoomInitialCaptureCommit(draft: draft),
            decision: .save
        )
        let summary = try XCTUnwrap(saved)
        let loaded = try await store.load(projectID: summary.projectID)
        XCTAssertEqual(loaded.revisions[0].payload.semanticSnapshot.objectElements.count, 2)
        XCTAssertEqual(
            loaded.revisions[0].payload.semanticSnapshot.objectElements.map { $0.mobility },
            [.fixed, .unknown]
        )
    }

    func testStoreRejectsMobilityContradictionsAcrossSemanticArrays() async throws {
        let mutations: [(String, (inout RoomDraft) -> Void)] = [
            ("structural marked movable", { draft in
                draft.revision.semanticSnapshot.structuralElements[0].mobility = .movable
            }),
            ("movable marked structural", { draft in
                draft.revision.semanticSnapshot.movableElements = [
                    RoomSemanticElement(
                        id: "movable-object-001",
                        kind: "chair",
                        label: "Chair",
                        dimensionsMeters: RoomDimensions(width: 0.6, height: 0.9, depth: 0.6),
                        mobility: .structural
                    ),
                ]
            }),
        ]

        for (label, mutate) in mutations {
            let root = temporaryURL(
                prefix: "RoomScanMobility-\(label.replacingOccurrences(of: " ", with: "-"))"
            )
            defer { try? FileManager.default.removeItem(at: root) }
            var draft = try makeDraft()
            mutate(&draft)
            let store = makeStore(root: root)

            do {
                _ = try await store.commitInitialCapture(
                    RoomInitialCaptureCommit(draft: draft),
                    decision: .save
                )
                XCTFail("Expected \(label) to be rejected.")
            } catch {
                XCTAssertFalse(FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("capture-project-001").path
                ))
            }
        }
    }

    func testLegacyFixtureStyleJSONDecodesWithNilSpatialAndEvidenceFields() throws {
        let elementData = Data(
            """
            {"id":"legacy-wall","kind":"wall","label":"Wall","dimensionsMeters":{"width":3,"height":2.4,"depth":0.1}}
            """.utf8
        )
        let photoData = Data(
            """
            {"id":"legacy-photo","createdAt":"2026-01-01T00:00:00Z","assetRelativePath":"photos/legacy.jpg","caption":"Legacy"}
            """.utf8
        )
        let revisionData = Data(
            """
            {"revisionID":"revision-001","projectID":"legacy-project","parentRevisionID":null,"reason":"initial","createdAt":"2026-01-01T00:00:00Z","immutable":true,"restoredFromRevisionID":null}
            """.utf8
        )

        let decoder = RoomJSONCoding.makeDecoder()
        let element = try decoder.decode(RoomSemanticElement.self, from: elementData)
        let photo = try decoder.decode(RoomPhoto.self, from: photoData)
        let revision = try decoder.decode(RoomRevisionManifest.self, from: revisionData)

        XCTAssertNil(element.transform)
        XCTAssertNil(element.polygonCorners)
        XCTAssertNil(element.provenance)
        XCTAssertNil(element.mobility)
        XCTAssertNil(element.origin)
        XCTAssertNil(photo.cameraTransform)
        XCTAssertNil(revision.captureEvidence)
    }

    func testLegacyMovableElementsDecodeIntoObjectElementsAndNewEncodingUsesObjectElements() throws {
        let legacySnapshotData = Data(
            """
            {"projectID":"legacy-project","revisionID":"revision-001","units":"meters","accuracyDisclaimer":"Measurements are estimates, not survey-grade evidence.","structuralElements":[],"movableElements":[{"id":"legacy-object-001","kind":"cabinet","label":"Cabinet","dimensionsMeters":{"width":1,"height":1,"depth":0.5},"mobility":"fixed"}]}
            """.utf8
        )
        let decoder = RoomJSONCoding.makeDecoder()
        let snapshot = try decoder.decode(RoomSemanticSnapshot.self, from: legacySnapshotData)

        XCTAssertEqual(snapshot.objectElements.count, 1)
        XCTAssertEqual(snapshot.movableElements, snapshot.objectElements)
        XCTAssertEqual(snapshot.objectElements[0].mobility, .fixed)

        let encoded = try RoomJSONCoding.makeEncoder().encode(snapshot)
        let encodedText = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(encodedText.contains("\"objectElements\""))
        XCTAssertFalse(encodedText.contains("\"movableElements\""))
    }

    func testSpatialProvenanceAndPhotoTransformRoundTrip() throws {
        let transform = RoomTransform4x4(
            columnMajorValues: [
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                1.2, 0.4, -0.8, 1,
            ]
        )
        let element = RoomSemanticElement(
            id: "provenance-wall",
            kind: "wall",
            label: "North wall",
            dimensionsMeters: RoomDimensions(width: 3, height: 2.4, depth: 0.1),
            transform: transform,
            polygonCorners: [
                RoomPoint3D(x: 0, y: 0, z: 0),
                RoomPoint3D(x: 3, y: 0, z: 0),
            ],
            provenance: RoomElementProvenance(
                framework: "RoomPlan",
                sourceIdentifier: "captured-wall-001",
                parentSourceIdentifier: "captured-room-001",
                classificationConfidence: .medium,
                flattenedAttributeIdentifiers: ["surface.wall", "semantic.structural"]
            ),
            mobility: .structural,
            origin: .roomPlan
        )
        let photo = RoomPhoto(
            id: "provenance-photo",
            createdAt: Date(timeIntervalSince1970: 1_704_067_200),
            assetRelativePath: try RoomRelativePath("photos/provenance.jpg"),
            caption: "Provenance image",
            cameraTransform: transform
        )

        let encoder = RoomJSONCoding.makeEncoder()
        let decoder = RoomJSONCoding.makeDecoder()
        XCTAssertEqual(try decoder.decode(RoomSemanticElement.self, from: encoder.encode(element)), element)
        XCTAssertEqual(try decoder.decode(RoomPhoto.self, from: encoder.encode(photo)), photo)
    }

    private func makeStore(
        root: URL,
        projectIDs: [String] = ["capture-project-001", "capture-project-002"],
        revisionIDs: [String] = ["revision-001", "revision-002", "revision-003"]
    ) -> LocalRoomProjectStore {
        LocalRoomProjectStore(
            rootURL: root,
            clock: FixedRoomProjectClock(
                date: Date(timeIntervalSince1970: 1_704_067_200)
            ),
            idGenerator: DeterministicRoomProjectIDGenerator(
                projectIDs: projectIDs,
                revisionIDs: revisionIDs
            )
        )
    }

    private func makeDraft() throws -> RoomDraft {
        let metadata = RoomMetadata(
            projectID: "draft-project",
            customName: "Evidence room",
            captureDate: Date(timeIntervalSince1970: 1_704_067_200),
            lastRevisedDate: Date(timeIntervalSince1970: 1_704_067_200),
            manualLocation: "Fixture lab",
            optionalGPS: nil,
            notes: "Foundation-only capture contract.",
            tags: ["evidence"],
            thumbnailRelativePath: nil,
            archived: false
        )
        let semantic = RoomSemanticSnapshot(
            projectID: "draft-project",
            revisionID: "draft-revision",
            units: "meters",
            accuracyDisclaimer: "Measurements are estimates, not survey-grade evidence.",
            structuralElements: [
                RoomSemanticElement(
                    id: "wall-001",
                    kind: "wall",
                    label: "North wall",
                    dimensionsMeters: RoomDimensions(width: 3, height: 2.4, depth: 0.1)
                ),
            ],
            movableElements: []
        )
        return RoomDraft(
            metadata: metadata,
            revision: RoomRevisionPayload(
                semanticSnapshot: semantic,
                annotations: [],
                measurements: [
                    RoomMeasurement(id: "measurement-001", label: "Wall width", valueMeters: 3),
                ],
                photos: []
            )
        )
    }

    private func writeLegacyPlanlessEvidencePackage(
        at root: URL
    ) throws -> LegacyPlanlessEvidenceFixture {
        let projectID = "legacy-project-001"
        let revisionID = "revision-001"
        let timestamp = Date(timeIntervalSince1970: 1_704_067_200)
        let projectURL = root.appendingPathComponent(projectID, isDirectory: true)
        let revisionURL = projectURL
            .appendingPathComponent("revisions", isDirectory: true)
            .appendingPathComponent(revisionID, isDirectory: true)
        let evidenceURL = revisionURL.appendingPathComponent(
            "evidence/native-room.usdz"
        )
        let evidenceBytes = Data("legacy-planless-native-usdz".utf8)

        var draft = try makeDraft()
        draft.metadata.projectID = projectID
        draft.metadata.captureDate = timestamp
        draft.metadata.lastRevisedDate = timestamp
        draft.revision.semanticSnapshot.projectID = projectID
        draft.revision.semanticSnapshot.revisionID = revisionID

        let manifest = RoomProjectManifest(
            schemaVersion: RoomProjectSchemaVersion.v1.rawValue,
            projectID: projectID,
            headRevisionID: revisionID,
            revisionIDs: [revisionID],
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let revisionManifest = RoomRevisionManifest(
            revisionID: revisionID,
            projectID: projectID,
            parentRevisionID: nil,
            reason: .initial,
            createdAt: timestamp,
            immutable: true,
            restoredFromRevisionID: nil,
            captureEvidence: nil,
            evidenceCompatibility: nil
        )

        try FileManager.default.createDirectory(
            at: revisionURL,
            withIntermediateDirectories: true
        )
        let encoder = RoomJSONCoding.makeEncoder()
        func writeJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
            try encoder.encode(value).write(to: url, options: .atomic)
        }

        try writeJSON(manifest, to: projectURL.appendingPathComponent("manifest.json"))
        try writeJSON(draft.metadata, to: projectURL.appendingPathComponent("metadata.json"))
        try writeJSON(revisionManifest, to: revisionURL.appendingPathComponent("revision.json"))
        try writeJSON(
            draft.revision.semanticSnapshot,
            to: revisionURL.appendingPathComponent("semantic-model.json")
        )
        try writeJSON(
            RoomAnnotationsDocument(
                projectID: projectID,
                revisionID: revisionID,
                annotations: draft.revision.annotations
            ),
            to: revisionURL.appendingPathComponent("annotations.json")
        )
        try writeJSON(
            RoomMeasurementsDocument(
                projectID: projectID,
                revisionID: revisionID,
                accuracyDisclaimer: draft.revision.semanticSnapshot.accuracyDisclaimer,
                measurements: draft.revision.measurements
            ),
            to: revisionURL.appendingPathComponent("measurements.json")
        )
        try writeJSON(
            RoomPhotosDocument(
                projectID: projectID,
                revisionID: revisionID,
                photos: draft.revision.photos
            ),
            to: revisionURL.appendingPathComponent("photos.json")
        )
        try FileManager.default.createDirectory(
            at: evidenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try evidenceBytes.write(to: evidenceURL, options: .atomic)

        return LegacyPlanlessEvidenceFixture(
            projectID: projectID,
            revisionID: revisionID,
            evidenceURL: evidenceURL,
            evidenceBytes: evidenceBytes
        )
    }

    private func makePreparedRoomPlanCommit() throws -> PreparedCapture {
        let sourceDirectory = temporaryURL(prefix: "RoomScanCaptureSources")
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )

        let thumbnailBytes = Data("thumbnail-bytes".utf8)
        let photoBytes = Data("photo-bytes".utf8)
        let capturedDataBytes = Data("captured-room-data".utf8)
        let capturedRoomBytes = Data("captured-room-processed".utf8)
        let nativeUSDZBytes = Data("native-usdz-binary".utf8)
        let thumbnailURL = sourceDirectory.appendingPathComponent("thumbnail.png")
        let photoURL = sourceDirectory.appendingPathComponent("photo-001.jpg")
        let capturedDataURL = sourceDirectory.appendingPathComponent("captured-room-data.json")
        let capturedRoomURL = sourceDirectory.appendingPathComponent("captured-room.json")
        let nativeUSDZURL = sourceDirectory.appendingPathComponent("RoomScan.usdz")
        try thumbnailBytes.write(to: thumbnailURL, options: .atomic)
        try photoBytes.write(to: photoURL, options: .atomic)
        try capturedDataBytes.write(to: capturedDataURL, options: .atomic)
        try capturedRoomBytes.write(to: capturedRoomURL, options: .atomic)
        try nativeUSDZBytes.write(to: nativeUSDZURL, options: .atomic)

        var draft = try makeDraft()
        draft.metadata.thumbnailRelativePath = try RoomRelativePath("thumbnails/thumbnail.png")
        draft.revision.semanticSnapshot.structuralElements[0].provenance = RoomElementProvenance(
            framework: "RoomPlan",
            sourceIdentifier: "captured-wall-001",
            parentSourceIdentifier: "captured-room-001",
            classificationConfidence: .high,
            flattenedAttributeIdentifiers: ["wall"],
            captureAttemptID: "capture-attempt-001",
            coordinateSpaceEpochID: "coordinate-epoch-001"
        )
        draft.revision.semanticSnapshot.structuralElements[0].origin = .roomPlan
        draft.revision.photos = [
            RoomPhoto(
                id: "photo-001",
                createdAt: Date(timeIntervalSince1970: 1_704_067_200),
                assetRelativePath: try RoomRelativePath("photos/photo-001.jpg"),
                caption: "Fixture photo"
            ),
        ]

        let capturedDataPath = try RoomRelativePath("evidence/roomplan/captured-room-data.json")
        let capturedRoomPath = try RoomRelativePath("evidence/roomplan/captured-room.json")
        let nativeUSDZPath = try RoomRelativePath("evidence/native/RoomScan.usdz")
        let evidence = RoomRevisionEvidencePlan(
            source: .roomPlan,
            artifacts: [
                RoomEvidenceArtifact(
                    kind: .capturedRoomDataJSON,
                    status: .present,
                    relativePath: capturedDataPath,
                    byteCount: capturedDataBytes.count,
                    mediaType: "application/json",
                    omissionReason: nil,
                    sha256Hex: RoomSHA256.hexDigest(of: capturedDataBytes)
                ),
                RoomEvidenceArtifact(
                    kind: .capturedRoomJSON,
                    status: .present,
                    relativePath: capturedRoomPath,
                    byteCount: capturedRoomBytes.count,
                    mediaType: "application/json",
                    omissionReason: nil,
                    sha256Hex: RoomSHA256.hexDigest(of: capturedRoomBytes)
                ),
                RoomEvidenceArtifact(
                    kind: .nativeUSDZ,
                    status: .present,
                    relativePath: nativeUSDZPath,
                    byteCount: nativeUSDZBytes.count,
                    mediaType: "model/vnd.usdz+zip",
                    omissionReason: nil,
                    sha256Hex: RoomSHA256.hexDigest(of: nativeUSDZBytes)
                ),
                RoomEvidenceArtifact(
                    kind: .rawMesh,
                    status: .unavailable,
                    relativePath: nil,
                    byteCount: nil,
                    mediaType: nil,
                    omissionReason: "Raw mesh requires a physical RoomPlan compatibility gate."
                ),
                RoomEvidenceArtifact(
                    kind: .worldMap,
                    status: .unavailable,
                    relativePath: nil,
                    byteCount: nil,
                    mediaType: nil,
                    omissionReason: "World-map preservation requires a physical ARKit gate."
                ),
                RoomEvidenceArtifact(
                    kind: .provenance,
                    status: .notRequested,
                    relativePath: nil,
                    byteCount: nil,
                    mediaType: nil,
                    omissionReason: "No additional provenance artifact was requested."
                ),
            ],
            captureAttemptID: "capture-attempt-001",
            coordinateSpaceEpochID: "coordinate-epoch-001"
        )
        let assets = [
            RoomAssetInput(
                sourceURL: thumbnailURL,
                destination: try RoomRelativePath("thumbnails/thumbnail.png"),
                scope: .project
            ),
            RoomAssetInput(
                sourceURL: photoURL,
                destination: try RoomRelativePath("photos/photo-001.jpg"),
                scope: .revision
            ),
            RoomAssetInput(sourceURL: capturedDataURL, destination: capturedDataPath, scope: .revision),
            RoomAssetInput(sourceURL: capturedRoomURL, destination: capturedRoomPath, scope: .revision),
            RoomAssetInput(sourceURL: nativeUSDZURL, destination: nativeUSDZPath, scope: .revision),
        ]
        return PreparedCapture(
            commit: RoomInitialCaptureCommit(draft: draft, evidence: evidence, assets: assets),
            sourceDirectory: sourceDirectory,
            thumbnailBytes: thumbnailBytes,
            bytesByRevisionPath: [
                "photos/photo-001.jpg": photoBytes,
                capturedDataPath.value: capturedDataBytes,
                capturedRoomPath.value: capturedRoomBytes,
                nativeUSDZPath.value: nativeUSDZBytes,
            ]
        )
    }

    private func assertCommitRejected(
        _ commit: RoomInitialCaptureCommit,
        label: String
    ) async throws {
        let root = temporaryURL(prefix: "RoomScanRejectedEvidence")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)

        do {
            _ = try await store.commitInitialCapture(commit, decision: .save)
            XCTFail("Expected \(label) to be rejected.")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: root.appendingPathComponent("capture-project-001").path
            ))
            if FileManager.default.fileExists(atPath: root.path) {
                let children = try FileManager.default.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: nil,
                    options: []
                )
                XCTAssertFalse(children.contains { $0.lastPathComponent.hasPrefix(".staging-") })
            }
        }
    }

    private func writeCanonicalEvidenceInjection(
        root: URL,
        projectID: String,
        revisionID: String
    ) throws {
        let injectedURL = root.appendingPathComponent(
            "\(projectID)/revisions/\(revisionID)/evidence/injected.bin"
        )
        try FileManager.default.createDirectory(
            at: injectedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("externally-injected-planless-evidence".utf8).write(
            to: injectedURL,
            options: .atomic
        )
    }

    private func removeRevisionEvidenceCompatibility(
        root: URL,
        projectID: String,
        revisionID: String
    ) throws {
        let manifestURL = root.appendingPathComponent(
            "\(projectID)/revisions/\(revisionID)/revision.json"
        )
        let serialized = try JSONSerialization.jsonObject(
            with: Data(contentsOf: manifestURL)
        )
        guard var object = serialized as? [String: Any] else {
            throw RoomProjectStoreError.invalidPackage(
                "Test revision manifest is not a JSON object."
            )
        }
        object.removeValue(forKey: "evidenceCompatibility")
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        try data.write(to: manifestURL, options: .atomic)
    }

    private func assertInvalidEvidencePlanOnLoad(
        _ store: LocalRoomProjectStore,
        projectID: String,
        label: String
    ) async {
        do {
            _ = try await store.load(projectID: projectID)
            XCTFail("Expected \(label) to fail closed.")
        } catch let error as RoomProjectStoreError {
            guard case .invalidEvidencePlan = error else {
                XCTFail("Expected invalid evidence plan, got \(error).")
                return
            }
        } catch {
            XCTFail("Expected a store validation error, got \(error).")
        }
    }

    private func temporaryURL(prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}

private struct PreparedCapture {
    let commit: RoomInitialCaptureCommit
    let sourceDirectory: URL
    let thumbnailBytes: Data
    let bytesByRevisionPath: [String: Data]
}

private struct LegacyPlanlessEvidenceFixture {
    let projectID: String
    let revisionID: String
    let evidenceURL: URL
    let evidenceBytes: Data
}
